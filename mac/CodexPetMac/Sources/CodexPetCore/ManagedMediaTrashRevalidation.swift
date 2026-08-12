import Darwin
import Foundation

public enum ManagedMediaTrashRevalidationError: Error, Equatable, LocalizedError {
    case unsafeConfiguration
    case mediaMapUnreadable
    case mediaMapChangedBeforePublish
    case stillReferenced
    case targetChanged

    public var errorDescription: String? {
        switch self {
        case .unsafeConfiguration:
            return "Statelet could not safely revalidate the managed Media folder; files were kept on disk."
        case .mediaMapUnreadable:
            return "The media library changed or became unreadable; files were kept on disk."
        case .mediaMapChangedBeforePublish:
            return "The media library changed before removal could be saved; no files were moved."
        case .stillReferenced:
            return "The movie was added back to the media library; files were kept on disk."
        case .targetChanged:
            return "A managed media file changed during removal; files were kept on disk."
        }
    }
}

public struct ManagedMediaTrashSnapshot: Equatable, Sendable {
    fileprivate let targets: [ManagedMediaTrashTarget]
    fileprivate let maps: [ManagedMediaMapSnapshot]
    fileprivate let catalog: ManagedMediaCatalogSnapshot?

    public var targetURLs: [URL] { targets.map(\.url) }
}

public struct ManagedMediaTrashQuarantine: Equatable, Sendable {
    public let directoryURL: URL
    public let itemCount: Int

    fileprivate init(directoryURL: URL, itemCount: Int) {
        self.directoryURL = directoryURL
        self.itemCount = itemCount
    }
}

private struct ManagedMediaTrashTarget: Equatable, Sendable {
    let url: URL
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
}

public struct ManagedMediaTrashMap: Sendable {
    public let url: URL
    public let map: MediaMap

    public init(url: URL, map: MediaMap) {
        self.url = url
        self.map = map
    }
}

private struct ManagedMediaMapSnapshot: Equatable, Sendable {
    let url: URL
    let map: MediaMap
    let file: ManagedMediaFileSnapshot
}

private struct ManagedMediaFileSnapshot: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let data: Data
}

private struct ManagedMediaCatalogSnapshot: Equatable, Sendable {
    let url: URL
    let file: ManagedMediaFileSnapshot?
}

/// Captures the identity of an already-approved managed-removal plan, then
/// fail-closed revalidates the canonical on-disk map and target identities
/// immediately before callers move those files to Trash.
public enum ManagedMediaTrashRevalidator {
    public static func capture(
        targetURLs: [URL],
        plannedMediaMap: MediaMap,
        mapURL: URL,
        canonicalRoot: URL
    ) throws -> ManagedMediaTrashSnapshot {
        let layout = try validateLayout(mapURL: mapURL, canonicalRoot: canonicalRoot)
        guard !targetURLs.isEmpty else {
            throw ManagedMediaTrashRevalidationError.unsafeConfiguration
        }
        let targets = try targetURLs.map { url in
            try inspectTarget(url, root: layout.root)
        }
        let map = try inspectMap(layout.map)
        let decoded: MediaMap
        do {
            decoded = try JSONDecoder.codexPet.decode(MediaMap.self, from: map.file.data)
        } catch {
            throw ManagedMediaTrashRevalidationError.mediaMapUnreadable
        }
        guard decoded == plannedMediaMap else {
            throw ManagedMediaTrashRevalidationError.mediaMapChangedBeforePublish
        }
        return ManagedMediaTrashSnapshot(targets: targets, maps: [map], catalog: nil)
    }

    /// Captures the catalog and every character map as one removal CAS domain.
    /// All files must live directly under the canonical managed-media root.
    public static func captureLibrary(
        targetURLs: [URL],
        maps: [ManagedMediaTrashMap],
        catalogURL: URL?,
        canonicalRoot: URL
    ) throws -> ManagedMediaTrashSnapshot {
        guard !targetURLs.isEmpty, !maps.isEmpty else {
            throw ManagedMediaTrashRevalidationError.unsafeConfiguration
        }
        let root = try validateRoot(canonicalRoot)
        let targets = try targetURLs.map { try inspectTarget($0, root: root) }
        let capturedMaps = try maps.map { planned -> ManagedMediaMapSnapshot in
            let url = try validateManagedFile(planned.url, root: root)
            let snapshot = try inspectMap(url)
            guard snapshot.map == planned.map else {
                throw ManagedMediaTrashRevalidationError.mediaMapChangedBeforePublish
            }
            return snapshot
        }
        let catalog = try catalogURL.map { rawURL in
            let url = try validateManagedFile(rawURL, root: root)
            var info = stat()
            if lstat(url.path, &info) != 0 {
                guard errno == ENOENT else {
                    throw ManagedMediaTrashRevalidationError.mediaMapUnreadable
                }
                return ManagedMediaCatalogSnapshot(url: url, file: nil)
            }
            return ManagedMediaCatalogSnapshot(url: url, file: try inspectFile(url, maximumBytes: 1_048_576))
        }
        return ManagedMediaTrashSnapshot(targets: targets, maps: capturedMaps, catalog: catalog)
    }

    /// Compare-and-swap guard for the map used to create the removal plan.
    /// Call immediately before publishing the plan's updated map.
    public static func validateMapUnchanged(
        snapshot: ManagedMediaTrashSnapshot,
        mapURL: URL,
        canonicalRoot: URL
    ) throws {
        let layout = try validateLayout(mapURL: mapURL, canonicalRoot: canonicalRoot)
        let current: ManagedMediaMapSnapshot
        do {
            current = try inspectMap(layout.map)
        } catch {
            throw ManagedMediaTrashRevalidationError.mediaMapUnreadable
        }
        guard current == snapshot.maps.first else {
            throw ManagedMediaTrashRevalidationError.mediaMapChangedBeforePublish
        }
    }

    public static func validateLibraryUnchanged(
        snapshot: ManagedMediaTrashSnapshot,
        canonicalRoot: URL
    ) throws {
        let root = try validateRoot(canonicalRoot)
        try validateCatalog(snapshot.catalog, root: root)
        for expected in snapshot.maps {
            let current = try inspectMap(try validateManagedFile(expected.url, root: root))
            guard current == expected else {
                throw ManagedMediaTrashRevalidationError.mediaMapChangedBeforePublish
            }
        }
    }

    public static func revalidate(
        snapshot: ManagedMediaTrashSnapshot,
        mapURL: URL,
        canonicalRoot: URL
    ) throws -> [URL] {
        let layout = try validateLayout(mapURL: mapURL, canonicalRoot: canonicalRoot)
        let map: MediaMap
        do {
            map = try inspectMap(layout.map).map
        } catch {
            throw ManagedMediaTrashRevalidationError.mediaMapUnreadable
        }

        let targetPaths = Set(snapshot.targets.map { $0.url.path })
        for playlist in map.states.values {
            for entry in playlist.entries {
                let referenced = map.resolvedURL(for: entry, relativeTo: layout.map)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                if targetPaths.contains(referenced.path) {
                    throw ManagedMediaTrashRevalidationError.stillReferenced
                }
            }
        }

        for expected in snapshot.targets {
            let current: ManagedMediaTrashTarget
            do {
                current = try inspectTarget(expected.url, root: layout.root)
            } catch {
                throw ManagedMediaTrashRevalidationError.targetChanged
            }
            guard current == expected else {
                throw ManagedMediaTrashRevalidationError.targetChanged
            }
        }
        return snapshot.targetURLs
    }

    /// Revalidates the library and atomically removes every verified target
    /// from its public managed-media name into one private quarantine. Callers
    /// may then move the quarantine directory to Trash without resolving the
    /// original target paths again.
    public static func quarantineLibraryAfterPublish(
        snapshot: ManagedMediaTrashSnapshot,
        publishedMap: ManagedMediaTrashMap,
        canonicalRoot: URL
    ) throws -> ManagedMediaTrashQuarantine {
        try quarantineLibraryAfterPublish(
            snapshot: snapshot,
            publishedMap: publishedMap,
            canonicalRoot: canonicalRoot,
            beforeStagingTarget: nil
        )
    }

    static func quarantineLibraryAfterPublish(
        snapshot: ManagedMediaTrashSnapshot,
        publishedMap: ManagedMediaTrashMap,
        canonicalRoot: URL,
        beforeStagingTarget: ((Int, URL) throws -> Void)?
    ) throws -> ManagedMediaTrashQuarantine {
        let root = try validateLibraryAfterPublish(
            snapshot: snapshot,
            publishedMap: publishedMap,
            canonicalRoot: canonicalRoot
        )
        let rootDescriptor = Darwin.open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw ManagedMediaTrashRevalidationError.unsafeConfiguration
        }
        defer { Darwin.close(rootDescriptor) }

        var rootInfo = stat()
        guard Darwin.fstat(rootDescriptor, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw ManagedMediaTrashRevalidationError.unsafeConfiguration
        }

        let quarantineName = "Statelet Removed Media \(UUID().uuidString.lowercased())"
        guard quarantineName.withCString({ Darwin.mkdirat(rootDescriptor, $0, 0o700) }) == 0 else {
            throw ManagedMediaTrashRevalidationError.targetChanged
        }
        let quarantineURL = root.appendingPathComponent(quarantineName, isDirectory: true)
        let quarantineDescriptor = quarantineName.withCString {
            Darwin.openat(rootDescriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard quarantineDescriptor >= 0 else {
            quarantineName.withCString { _ = Darwin.unlinkat(rootDescriptor, $0, AT_REMOVEDIR) }
            throw ManagedMediaTrashRevalidationError.targetChanged
        }
        defer { Darwin.close(quarantineDescriptor) }

        struct StagedTarget {
            let sourceParentDescriptor: Int32
            let sourceName: String
            let quarantineName: String
        }
        var staged: [StagedTarget] = []
        var ownedParentDescriptors: [Int32] = []
        defer { ownedParentDescriptors.forEach { Darwin.close($0) } }

        func rollback() throws {
            for item in staged.reversed() {
                let restoreResult = item.quarantineName.withCString { quarantineNamePointer in
                    item.sourceName.withCString { sourceNamePointer in
                        Darwin.renameatx_np(
                            quarantineDescriptor,
                            quarantineNamePointer,
                            item.sourceParentDescriptor,
                            sourceNamePointer,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
                if restoreResult == 0 { continue }
                guard errno == EEXIST else {
                    throw ManagedMediaTrashRevalidationError.targetChanged
                }

                // Preserve a concurrently created replacement while restoring
                // the identity-bound original. The atomic swap guarantees the
                // original name is never left empty during rollback.
                let swapResult = item.quarantineName.withCString { quarantineNamePointer in
                    item.sourceName.withCString { sourceNamePointer in
                        Darwin.renameatx_np(
                            quarantineDescriptor,
                            quarantineNamePointer,
                            item.sourceParentDescriptor,
                            sourceNamePointer,
                            UInt32(RENAME_SWAP)
                        )
                    }
                }
                guard swapResult == 0 else {
                    throw ManagedMediaTrashRevalidationError.targetChanged
                }
                let preservedName = "Statelet Preserved Replacement \(UUID().uuidString.lowercased())-\(item.sourceName)"
                let preserveResult = item.quarantineName.withCString { quarantineNamePointer in
                    preservedName.withCString { preservedNamePointer in
                        Darwin.renameatx_np(
                            quarantineDescriptor,
                            quarantineNamePointer,
                            item.sourceParentDescriptor,
                            preservedNamePointer,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
                guard preserveResult == 0,
                      Darwin.fsync(item.sourceParentDescriptor) == 0 else {
                    throw ManagedMediaTrashRevalidationError.targetChanged
                }
            }
            guard Darwin.fsync(quarantineDescriptor) == 0,
                  quarantineName.withCString({
                      Darwin.unlinkat(rootDescriptor, $0, AT_REMOVEDIR)
                  }) == 0,
                  Darwin.fsync(rootDescriptor) == 0 else {
                throw ManagedMediaTrashRevalidationError.targetChanged
            }
        }

        do {
            for (index, expected) in snapshot.targets.enumerated() {
                try beforeStagingTarget?(index, expected.url)
                let source = try openParentDirectory(
                    for: expected.url,
                    root: root,
                    rootDescriptor: rootDescriptor
                )
                ownedParentDescriptors.append(source.descriptor)
                var before = stat()
                guard source.name.withCString({
                    Darwin.fstatat(source.descriptor, $0, &before, AT_SYMLINK_NOFOLLOW)
                }) == 0,
                    target(before, matches: expected) else {
                    throw ManagedMediaTrashRevalidationError.targetChanged
                }

                let stagedName = String(format: "%04d-%@", index, source.name)
                let renameResult = source.name.withCString { sourceNamePointer in
                    stagedName.withCString { stagedNamePointer in
                        Darwin.renameatx_np(
                            source.descriptor,
                            sourceNamePointer,
                            quarantineDescriptor,
                            stagedNamePointer,
                            UInt32(RENAME_EXCL)
                        )
                    }
                }
                guard renameResult == 0 else {
                    throw ManagedMediaTrashRevalidationError.targetChanged
                }
                staged.append(
                    StagedTarget(
                        sourceParentDescriptor: source.descriptor,
                        sourceName: source.name,
                        quarantineName: stagedName
                    )
                )

                var after = stat()
                guard stagedName.withCString({
                    Darwin.fstatat(quarantineDescriptor, $0, &after, AT_SYMLINK_NOFOLLOW)
                }) == 0,
                    target(after, matches: expected) else {
                    throw ManagedMediaTrashRevalidationError.targetChanged
                }
            }
        } catch {
            let originalError = error
            do {
                try rollback()
            } catch {
                throw error
            }
            throw originalError
        }

        guard Darwin.fsync(quarantineDescriptor) == 0,
              Darwin.fsync(rootDescriptor) == 0 else {
            try rollback()
            throw ManagedMediaTrashRevalidationError.targetChanged
        }
        return ManagedMediaTrashQuarantine(
            directoryURL: quarantineURL,
            itemCount: staged.count
        )
    }

    @discardableResult
    private static func validateLibraryAfterPublish(
        snapshot: ManagedMediaTrashSnapshot,
        publishedMap: ManagedMediaTrashMap,
        canonicalRoot: URL
    ) throws -> URL {
        let root = try validateRoot(canonicalRoot)
        try validateCatalog(snapshot.catalog, root: root)
        let publishedURL = try validateManagedFile(publishedMap.url, root: root)
        for expected in snapshot.maps {
            let current = try inspectMap(try validateManagedFile(expected.url, root: root))
            if expected.url.standardizedFileURL == publishedURL {
                guard current.map == publishedMap.map else {
                    throw ManagedMediaTrashRevalidationError.mediaMapChangedBeforePublish
                }
            } else {
                guard current == expected else {
                    throw ManagedMediaTrashRevalidationError.mediaMapChangedBeforePublish
                }
            }
            try rejectReferences(in: current.map, mapURL: current.url, targets: snapshot.targets)
        }
        try validateTargets(snapshot.targets, root: root)
        return root
    }

    private static func openParentDirectory(
        for targetURL: URL,
        root: URL,
        rootDescriptor: Int32
    ) throws -> (descriptor: Int32, name: String) {
        let target = targetURL.standardizedFileURL
        let relative = String(target.path.dropFirst(root.path.count + 1))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw ManagedMediaTrashRevalidationError.targetChanged
        }

        var descriptor = Darwin.dup(rootDescriptor)
        guard descriptor >= 0 else {
            throw ManagedMediaTrashRevalidationError.targetChanged
        }
        for component in components.dropLast() {
            let next = component.withCString {
                Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            Darwin.close(descriptor)
            guard next >= 0 else {
                throw ManagedMediaTrashRevalidationError.targetChanged
            }
            descriptor = next
        }
        return (descriptor, components.last!)
    }

    private static func target(_ information: stat, matches expected: ManagedMediaTrashTarget) -> Bool {
        (information.st_mode & S_IFMT) == S_IFREG
            && UInt64(information.st_dev) == expected.device
            && UInt64(information.st_ino) == expected.inode
            && Int64(information.st_size) == expected.size
            && Int64(information.st_mtimespec.tv_sec) == expected.modifiedSeconds
            && Int64(information.st_mtimespec.tv_nsec) == expected.modifiedNanoseconds
            && Int64(information.st_ctimespec.tv_sec) == expected.changedSeconds
            && Int64(information.st_ctimespec.tv_nsec) == expected.changedNanoseconds
    }

    private static func validateLayout(
        mapURL: URL,
        canonicalRoot: URL
    ) throws -> (root: URL, map: URL) {
        let root = canonicalRoot.standardizedFileURL
        let map = mapURL.standardizedFileURL
        let expectedMap = root.appendingPathComponent("media-map.json").standardizedFileURL
        guard map.path == expectedMap.path,
              root.resolvingSymlinksInPath().standardizedFileURL.path == root.path,
              map.resolvingSymlinksInPath().standardizedFileURL.path == expectedMap.path else {
            throw ManagedMediaTrashRevalidationError.unsafeConfiguration
        }

        var rootInfo = stat()
        var mapInfo = stat()
        guard lstat(root.path, &rootInfo) == 0,
              lstat(map.path, &mapInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              (mapInfo.st_mode & S_IFMT) == S_IFREG else {
            throw ManagedMediaTrashRevalidationError.unsafeConfiguration
        }
        return (root, map)
    }

    private static func validateRoot(_ canonicalRoot: URL) throws -> URL {
        let root = canonicalRoot.standardizedFileURL
        var info = stat()
        guard root.resolvingSymlinksInPath().standardizedFileURL.path == root.path,
              lstat(root.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR else {
            throw ManagedMediaTrashRevalidationError.unsafeConfiguration
        }
        return root
    }

    private static func validateManagedFile(_ url: URL, root: URL) throws -> URL {
        let file = url.standardizedFileURL
        guard file.deletingLastPathComponent().path == root.path,
              file.resolvingSymlinksInPath().standardizedFileURL.path == file.path else {
            throw ManagedMediaTrashRevalidationError.unsafeConfiguration
        }
        return file
    }

    private static func inspectTarget(
        _ url: URL,
        root: URL
    ) throws -> ManagedMediaTrashTarget {
        let target = url.standardizedFileURL
        var information = stat()
        guard target.path.hasPrefix(root.path + "/"),
              target.resolvingSymlinksInPath().standardizedFileURL.path == target.path,
              lstat(target.path, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG else {
            throw ManagedMediaTrashRevalidationError.targetChanged
        }
        return ManagedMediaTrashTarget(
            url: target,
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            size: Int64(information.st_size),
            modifiedSeconds: Int64(information.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(information.st_mtimespec.tv_nsec),
            changedSeconds: Int64(information.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(information.st_ctimespec.tv_nsec)
        )
    }

    private static func inspectMap(_ url: URL) throws -> ManagedMediaMapSnapshot {
        let file = try inspectFile(url, maximumBytes: 1_048_576)
        let map: MediaMap
        do {
            map = try JSONDecoder.codexPet.decode(MediaMap.self, from: file.data)
        } catch {
            throw ManagedMediaTrashRevalidationError.mediaMapUnreadable
        }
        return ManagedMediaMapSnapshot(url: url.standardizedFileURL, map: map, file: file)
    }

    private static func inspectFile(_ url: URL, maximumBytes: Int64) throws -> ManagedMediaFileSnapshot {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ManagedMediaTrashRevalidationError.mediaMapUnreadable
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size >= 0,
              before.st_size <= maximumBytes else {
            throw ManagedMediaTrashRevalidationError.mediaMapUnreadable
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while data.count < Int(before.st_size) {
            let wanted = min(buffer.count, Int(before.st_size) - data.count)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, wanted)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw ManagedMediaTrashRevalidationError.mediaMapUnreadable
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              data.count == Int(before.st_size) else {
            throw ManagedMediaTrashRevalidationError.mediaMapUnreadable
        }
        return ManagedMediaFileSnapshot(
            device: UInt64(after.st_dev),
            inode: UInt64(after.st_ino),
            size: Int64(after.st_size),
            modifiedSeconds: Int64(after.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(after.st_mtimespec.tv_nsec),
            changedSeconds: Int64(after.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(after.st_ctimespec.tv_nsec),
            data: data
        )
    }

    private static func validateCatalog(_ expected: ManagedMediaCatalogSnapshot?, root: URL) throws {
        guard let expected else { return }
        let url = try validateManagedFile(expected.url, root: root)
        var info = stat()
        let current: ManagedMediaFileSnapshot?
        if lstat(url.path, &info) == 0 {
            current = try inspectFile(url, maximumBytes: 1_048_576)
        } else if errno == ENOENT {
            current = nil
        } else {
            throw ManagedMediaTrashRevalidationError.mediaMapUnreadable
        }
        guard current == expected.file else {
            throw ManagedMediaTrashRevalidationError.mediaMapChangedBeforePublish
        }
    }

    private static func rejectReferences(
        in map: MediaMap,
        mapURL: URL,
        targets: [ManagedMediaTrashTarget]
    ) throws {
        let targetPaths = Set(targets.map { $0.url.path })
        for playlist in map.states.values {
            for entry in playlist.entries {
                let movie = map.resolvedURL(for: entry, relativeTo: mapURL)
                    .resolvingSymlinksInPath().standardizedFileURL
                let report = movie.deletingPathExtension().appendingPathExtension("report.json")
                let poster = map.resolvedPosterURL(for: entry, relativeTo: mapURL)?
                    .resolvingSymlinksInPath().standardizedFileURL
                if targetPaths.contains(movie.path)
                    || targetPaths.contains(report.path)
                    || poster.map({ targetPaths.contains($0.path) }) == true {
                    throw ManagedMediaTrashRevalidationError.stillReferenced
                }
            }
        }
    }

    private static func validateTargets(_ targets: [ManagedMediaTrashTarget], root: URL) throws {
        for expected in targets {
            guard (try? inspectTarget(expected.url, root: root)) == expected else {
                throw ManagedMediaTrashRevalidationError.targetChanged
            }
        }
    }
}
