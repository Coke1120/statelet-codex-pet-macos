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
    fileprivate let map: ManagedMediaMapSnapshot

    public var targetURLs: [URL] { targets.map(\.url) }
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

private struct ManagedMediaMapSnapshot: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    let data: Data
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
            decoded = try JSONDecoder.codexPet.decode(MediaMap.self, from: map.data)
        } catch {
            throw ManagedMediaTrashRevalidationError.mediaMapUnreadable
        }
        guard decoded == plannedMediaMap else {
            throw ManagedMediaTrashRevalidationError.mediaMapChangedBeforePublish
        }
        return ManagedMediaTrashSnapshot(targets: targets, map: map)
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
        guard current == snapshot.map else {
            throw ManagedMediaTrashRevalidationError.mediaMapChangedBeforePublish
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
            let data = try Data(contentsOf: layout.map)
            map = try JSONDecoder.codexPet.decode(MediaMap.self, from: data)
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
        var before = stat()
        guard lstat(url.path, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG else {
            throw ManagedMediaTrashRevalidationError.mediaMapUnreadable
        }
        let data = try Data(contentsOf: url)
        var after = stat()
        guard lstat(url.path, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw ManagedMediaTrashRevalidationError.mediaMapUnreadable
        }
        return ManagedMediaMapSnapshot(
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
}
