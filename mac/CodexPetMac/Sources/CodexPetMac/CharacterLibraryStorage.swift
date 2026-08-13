import CodexPetCore
import CryptoKit
import Darwin
import Foundation

typealias CharacterPlaybackVerifier = (_ movieURL: URL, _ reportData: Data?) throws -> Void
typealias CharacterTransitionPlaybackVerifier = (_ movieURL: URL, _ reportData: Data) throws -> Void
typealias CharacterTransitionDurationVerifier = (_ movieURL: URL) throws -> Void
typealias CharacterAvailableDiskBytes = (_ destination: URL) throws -> UInt64
typealias CharacterOperationCheck = () throws -> Void

struct CharacterLibraryCatalogSnapshot {
    let library: CharacterLibrary
    /// Nil means the catalog was absent and `library` is the legacy bootstrap.
    let encodedData: Data?
}

/// The exact file identities covered by a synchronous runtime transition
/// attestation. Any cache keyed by this value must miss when either sibling is
/// replaced; callers should re-attest immediately before accepting playback.
struct CharacterTransitionRuntimeAttestation: Equatable {
    let movieRevision: LocalFileRevision
    let reportRevision: LocalFileRevision
    let movieSHA256: String
    let reportSHA256: String

    func requireUnchanged(movieURL: URL) throws {
        try requireUnchanged(movieURL: movieURL, operationCheck: {})
    }

    func requireUnchanged(
        movieURL: URL,
        operationCheck: @escaping CharacterOperationCheck
    ) throws {
        try operationCheck()
        let reportURL = movieURL.deletingPathExtension().appendingPathExtension("report.json")
        guard LocalFileRevision(url: movieURL) == movieRevision,
              LocalFileRevision(url: reportURL) == reportRevision else {
            throw CharacterLibraryStorageError.sourceChanged
        }
        let movie = try CharacterStorageFiles.hashRegularFile(
            movieURL,
            maximumBytes: CharacterBundleManifest.maximumMovieSize,
            rejectHardLinks: true,
            operationCheck: operationCheck
        )
        let report = try CharacterStorageFiles.hashRegularFile(
            reportURL,
            maximumBytes: CharacterBundleManifest.maximumReportSize,
            rejectHardLinks: true,
            operationCheck: operationCheck
        )
        guard movie.sha256 == movieSHA256,
              report.sha256 == reportSHA256 else {
            throw CharacterLibraryStorageError.sourceChanged
        }
    }
}

enum CharacterLibraryStorageError: LocalizedError {
    case nonLocalURL
    case unsafePath
    case invalidFile
    case fileTooLarge
    case insufficientDiskSpace
    case sourceChanged
    case catalogConflict
    case destinationExists
    case undeclaredReport
    case legacyTrustRequired
    case transitionAlphaReportRequired
    case characterLimitReached
    case invalidPlayback
    case commitFailed

    var errorDescription: String? {
        switch self {
        case .nonLocalURL: return "Only local character files are supported."
        case .unsafePath: return "The character package contains an unsafe path."
        case .invalidFile: return "The character package contains an invalid file."
        case .fileTooLarge: return "The character package exceeds Statelet's safe size limit."
        case .insufficientDiskSpace: return "There is not enough free disk space for this character."
        case .sourceChanged: return "A character file changed while it was being verified."
        case .catalogConflict: return "The character library changed before it could be saved."
        case .destinationExists: return "The character destination already exists."
        case .undeclaredReport: return "The character package declares conflicting reports."
        case .legacyTrustRequired: return "Reportless movies require explicit legacy trust."
        case .transitionAlphaReportRequired: return "Transition movies require a current validated alpha report."
        case .characterLimitReached: return "The character library has reached its 256-character limit."
        case .invalidPlayback: return "A character movie failed the playback safety checks."
        case .commitFailed: return "The character could not be committed atomically."
        }
    }
}

final class StagedCharacterImport {
    let entry: CharacterLibraryEntry
    let mediaMap: MediaMap
    let stagingURL: URL

    private let stagedMapURL: URL
    private let stagedAssetsURL: URL
    private let finalMapURL: URL
    private let finalAssetsURL: URL
    private let parentURL: URL
    private let lock = NSLock()
    private enum State { case staged, committed, finalized }
    private var state: State = .staged

    fileprivate init(
        entry: CharacterLibraryEntry,
        mediaMap: MediaMap,
        stagingURL: URL,
        stagedMapURL: URL,
        stagedAssetsURL: URL,
        finalMapURL: URL,
        finalAssetsURL: URL,
        parentURL: URL
    ) {
        self.entry = entry
        self.mediaMap = mediaMap
        self.stagingURL = stagingURL
        self.stagedMapURL = stagedMapURL
        self.stagedAssetsURL = stagedAssetsURL
        self.finalMapURL = finalMapURL
        self.finalAssetsURL = finalAssetsURL
        self.parentURL = parentURL
    }

    deinit { discard() }

    @discardableResult
    func commit() throws -> CharacterLibraryEntry {
        lock.lock()
        defer { lock.unlock() }
        guard state == .staged else { throw CharacterLibraryStorageError.commitFailed }
        guard !CharacterStorageFiles.pathExistsNoFollow(finalMapURL),
              !CharacterStorageFiles.pathExistsNoFollow(finalAssetsURL) else {
            throw CharacterLibraryStorageError.destinationExists
        }
        do {
            try FileManager.default.moveItem(at: stagedAssetsURL, to: finalAssetsURL)
            do {
                try FileManager.default.moveItem(at: stagedMapURL, to: finalMapURL)
            } catch {
                try? FileManager.default.moveItem(at: finalAssetsURL, to: stagedAssetsURL)
                throw error
            }
            try CharacterStorageFiles.syncDirectory(parentURL)
            try? FileManager.default.removeItem(at: stagingURL)
            state = .committed
            return entry
        } catch let error as CharacterLibraryStorageError {
            throw error
        } catch {
            throw CharacterLibraryStorageError.commitFailed
        }
    }

    /// Marks a committed import durable after the caller's catalog CAS succeeds.
    func finalize() {
        lock.lock()
        defer { lock.unlock() }
        if state == .committed { state = .finalized }
    }

    /// Removes either the private staging tree or committed map/assets. Call
    /// this when the catalog CAS fails after `commit()`.
    func rollback() {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .staged:
            try? FileManager.default.removeItem(at: stagingURL)
        case .committed:
            try? FileManager.default.removeItem(at: finalMapURL)
            try? FileManager.default.removeItem(at: finalAssetsURL)
            try? CharacterStorageFiles.syncDirectory(parentURL)
        case .finalized:
            return
        }
        state = .finalized
    }

    func discard() {
        rollback()
    }
}

final class CharacterLibraryStorage {
    static let maximumCatalogBytes: UInt64 = 1_048_576
    static let maximumMediaMapBytes: UInt64 = 1_048_576
    static let minimumFreeSpaceReserveBytes: UInt64 = 67_108_864

    let rootMediaMapURL: URL
    var mediaMapURL: URL { rootMediaMapURL }
    let catalogURL: URL
    private let rootURL: URL
    private let playbackVerifier: CharacterPlaybackVerifier
    private let transitionPlaybackVerifier: CharacterTransitionPlaybackVerifier
    private let transitionDurationVerifier: CharacterTransitionDurationVerifier
    private let availableDiskBytes: CharacterAvailableDiskBytes

    init(
        mediaMapURL: URL,
        catalogURL: URL? = nil,
        playbackVerifier: @escaping CharacterPlaybackVerifier = CharacterLibraryStorage.defaultPlaybackVerifier,
        transitionPlaybackVerifier: @escaping CharacterTransitionPlaybackVerifier = CharacterLibraryStorage.defaultTransitionPlaybackVerifier,
        transitionDurationVerifier: @escaping CharacterTransitionDurationVerifier = CharacterLibraryStorage.defaultTransitionDurationVerifier,
        availableDiskBytes: @escaping CharacterAvailableDiskBytes = CharacterStorageFiles.systemAvailableDiskBytes
    ) {
        rootMediaMapURL = mediaMapURL
        rootURL = rootMediaMapURL.deletingLastPathComponent()
        self.catalogURL = catalogURL ?? rootURL.appendingPathComponent("character-library.json")
        self.playbackVerifier = playbackVerifier
        self.transitionPlaybackVerifier = transitionPlaybackVerifier
        self.transitionDurationVerifier = transitionDurationVerifier
        self.availableDiskBytes = availableDiskBytes
    }

    func loadCatalog() throws -> CharacterLibraryCatalogSnapshot {
        try requireSameRootBasename(catalogURL)
        guard CharacterStorageFiles.pathExistsNoFollow(catalogURL) else {
            return CharacterLibraryCatalogSnapshot(
                library: try CharacterLibrary.legacy(mapPath: rootMediaMapURL.lastPathComponent),
                encodedData: nil
            )
        }
        let data = try CharacterStorageFiles.readRegularFile(
            catalogURL,
            maximumBytes: Self.maximumCatalogBytes
        )
        return CharacterLibraryCatalogSnapshot(
            library: try JSONDecoder.codexPet.decode(CharacterLibrary.self, from: data),
            encodedData: data
        )
    }

    /// Re-attests a configured transition at its runtime location. This is
    /// intentionally synchronous and uncached: validation binds a current
    /// sibling report to the exact movie basename and bytes, exercises the
    /// AVFoundation playback gate and duration limit, then proves neither file
    /// changed during validation. The returned revisions are safe cache keys
    /// only when both still match at the next use.
    static func attestRuntimeTransition(
        movieURL: URL,
        transitionPlaybackVerifier: CharacterTransitionPlaybackVerifier = CharacterLibraryStorage.defaultTransitionPlaybackVerifier,
        transitionDurationVerifier: CharacterTransitionDurationVerifier = CharacterLibraryStorage.defaultTransitionDurationVerifier,
        operationCheck: @escaping CharacterOperationCheck = { try Task.checkCancellation() }
    ) throws -> CharacterTransitionRuntimeAttestation {
        try operationCheck()
        guard movieURL.isFileURL,
              movieURL.host.map({ $0.isEmpty || $0 == "localhost" }) ?? true else {
            throw CharacterLibraryStorageError.nonLocalURL
        }
        let reportURL = movieURL.deletingPathExtension().appendingPathExtension("report.json")
        guard CharacterStorageFiles.pathExistsNoFollow(reportURL) else {
            throw CharacterLibraryStorageError.transitionAlphaReportRequired
        }
        guard let movieRevisionBefore = LocalFileRevision(url: movieURL),
              let reportRevisionBefore = LocalFileRevision(url: reportURL) else {
            throw CharacterLibraryStorageError.invalidFile
        }
        let movieBefore = try CharacterStorageFiles.hashRegularFile(
            movieURL,
            maximumBytes: CharacterBundleManifest.maximumMovieSize,
            rejectHardLinks: true,
            operationCheck: operationCheck
        )
        let reportBefore = try CharacterStorageFiles.hashRegularFile(
            reportURL,
            maximumBytes: CharacterBundleManifest.maximumReportSize,
            rejectHardLinks: true
        )
        let reportData = try CharacterStorageFiles.readRegularFile(
            reportURL,
            maximumBytes: CharacterBundleManifest.maximumReportSize,
            rejectHardLinks: true
        )

        try operationCheck()
        try transitionPlaybackVerifier(movieURL, reportData)
        try operationCheck()
        try transitionDurationVerifier(movieURL)

        try operationCheck()
        let movieAfter = try CharacterStorageFiles.hashRegularFile(
            movieURL,
            maximumBytes: CharacterBundleManifest.maximumMovieSize,
            rejectHardLinks: true,
            operationCheck: operationCheck
        )
        let reportAfter = try CharacterStorageFiles.hashRegularFile(
            reportURL,
            maximumBytes: CharacterBundleManifest.maximumReportSize,
            rejectHardLinks: true
        )
        guard let movieRevisionAfter = LocalFileRevision(url: movieURL),
              let reportRevisionAfter = LocalFileRevision(url: reportURL),
              movieRevisionAfter == movieRevisionBefore,
              reportRevisionAfter == reportRevisionBefore,
              movieAfter.size == movieBefore.size,
              movieAfter.sha256 == movieBefore.sha256,
              reportAfter.size == reportBefore.size,
              reportAfter.sha256 == reportBefore.sha256 else {
            throw CharacterLibraryStorageError.sourceChanged
        }
        return CharacterTransitionRuntimeAttestation(
            movieRevision: movieRevisionAfter,
            reportRevision: reportRevisionAfter,
            movieSHA256: movieAfter.sha256,
            reportSHA256: reportAfter.sha256
        )
    }

    @discardableResult
    func saveCatalog(_ library: CharacterLibrary, expectedData: Data?) throws -> Data {
        try requireSameRootBasename(catalogURL)
        let data = try Self.encoder.encode(library)
        guard UInt64(data.count) <= Self.maximumCatalogBytes else {
            throw CharacterLibraryStorageError.fileTooLarge
        }
        try CharacterStorageFiles.withExclusiveLock(in: rootURL, name: ".character-library.lock") {
            let current: Data?
            if CharacterStorageFiles.pathExistsNoFollow(catalogURL) {
                current = try CharacterStorageFiles.readRegularFile(
                    catalogURL,
                    maximumBytes: Self.maximumCatalogBytes
                )
            } else {
                current = nil
            }
            guard current == expectedData else { throw CharacterLibraryStorageError.catalogConflict }
            try CharacterStorageFiles.atomicWrite(data, to: catalogURL, expectedData: expectedData)
        }
        return data
    }

    func loadMediaMap(for entry: CharacterLibraryEntry) throws -> (map: MediaMap, encodedData: Data) {
        let url = try mapURL(for: entry)
        let data = try CharacterStorageFiles.readRegularFile(url, maximumBytes: Self.maximumMediaMapBytes)
        return (try JSONDecoder.codexPet.decode(MediaMap.self, from: data), data)
    }

    @discardableResult
    func saveMediaMap(_ map: MediaMap, for entry: CharacterLibraryEntry, expectedData: Data?) throws -> Data {
        let url = try mapURL(for: entry)
        let data = try Self.encoder.encode(map)
        guard UInt64(data.count) <= Self.maximumMediaMapBytes else {
            throw CharacterLibraryStorageError.fileTooLarge
        }
        try CharacterStorageFiles.withExclusiveLock(in: rootURL, name: ".character-map-write.lock") {
            try CharacterStorageFiles.atomicWrite(data, to: url, expectedData: expectedData)
        }
        return data
    }

    @discardableResult
    func saveRecoveredMediaMap(
        _ map: MediaMap,
        for entry: CharacterLibraryEntry,
        expectedData: Data,
        expectedCatalogData: Data?
    ) throws -> Data {
        let url = try mapURL(for: entry)
        let data = try Self.encoder.encode(map)
        guard UInt64(data.count) <= Self.maximumMediaMapBytes else {
            throw CharacterLibraryStorageError.fileTooLarge
        }
        return try CharacterStorageFiles.withExclusiveLock(
            in: rootURL,
            name: ".character-library.lock"
        ) {
            let currentCatalog: Data?
            if CharacterStorageFiles.pathExistsNoFollow(catalogURL) {
                currentCatalog = try CharacterStorageFiles.readRegularFile(
                    catalogURL,
                    maximumBytes: Self.maximumCatalogBytes
                )
            } else {
                currentCatalog = nil
            }
            guard currentCatalog == expectedCatalogData else {
                throw CharacterLibraryStorageError.catalogConflict
            }
            return try CharacterStorageFiles.withExclusiveLock(
                in: rootURL,
                name: ".character-map-write.lock"
            ) {
                try CharacterStorageFiles.atomicWrite(data, to: url, expectedData: expectedData)
                return data
            }
        }
    }

    func exportCharacter(_ entry: CharacterLibraryEntry, to packageURL: URL) throws {
        try requireLocal(packageURL)
        guard packageURL.pathExtension == "statelet-character" else {
            throw CharacterLibraryStorageError.unsafePath
        }
        let parent = packageURL.deletingLastPathComponent()
        try CharacterStorageFiles.requireNoFollowDirectoryPath(parent)
        guard !CharacterStorageFiles.pathExistsNoFollow(packageURL) else {
            throw CharacterLibraryStorageError.destinationExists
        }
        let loaded = try loadMediaMap(for: entry)
        let sourceMapDirectory = try mapURL(for: entry).deletingLastPathComponent()
        var bundlePathByOriginal: [String: String] = [:]
        var bundlePathBySource: [String: String] = [:]
        var sourceByBundlePath: [(role: CharacterBundleAssetRole, source: URL, path: String, moviePath: String?)] = []
        var nextIndex = 0

        func register(_ original: String, role: CharacterBundleAssetRole) throws -> String {
            if let existing = bundlePathByOriginal[original] { return existing }
            let source = CharacterLibraryStorage.resolvedMediaURL(original, relativeTo: sourceMapDirectory)
            let sourceKey = "\(role.rawValue):\(source.standardizedFileURL.path)"
            if let existing = bundlePathBySource[sourceKey] {
                bundlePathByOriginal[original] = existing
                return existing
            }
            let basename = try CharacterStorageFiles.contractAssetBasename(source.lastPathComponent)
            let directory = role == .movie ? "movies" : "posters"
            let bundled = "media/\(directory)/\(String(format: "%03d", nextIndex))/\(basename)"
            nextIndex += 1
            bundlePathByOriginal[original] = bundled
            bundlePathBySource[sourceKey] = bundled
            sourceByBundlePath.append((role, source, bundled, nil))
            return bundled
        }

        for playlist in loaded.map.states.values {
            for media in playlist.entries {
                _ = try register(media.path, role: .movie)
                if let poster = media.posterPath { _ = try register(poster, role: .poster) }
            }
        }
        for playlist in loaded.map.transitions.values {
            for transition in playlist.entries {
                _ = try register(transition.path, role: .movie)
                if let poster = transition.posterPath { _ = try register(poster, role: .poster) }
            }
        }

        var reports: [(source: URL, path: String, moviePath: String)] = []
        for item in sourceByBundlePath where item.role == .movie {
            let reportURL = item.source.deletingPathExtension().appendingPathExtension("report.json")
            var status = stat()
            if Darwin.lstat(reportURL.path, &status) == 0 {
                guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                    throw CharacterLibraryStorageError.invalidFile
                }
                reports.append((
                    reportURL,
                    "media/reports/\(String(format: "%03d", reports.count))/\(try CharacterStorageFiles.contractAssetBasename(reportURL.lastPathComponent))",
                    item.path
                ))
            } else if errno != ENOENT {
                throw CharacterLibraryStorageError.invalidFile
            }
        }

        let rewrittenMap = try loaded.map.rewritingMediaPaths { original in
            guard let bundled = bundlePathByOriginal[original] else {
                throw CharacterLibraryStorageError.unsafePath
            }
            return bundled
        }
        let transitionMoviePaths = Set(rewrittenMap.allTransitionEntries.map(\.path))

        var expectedAggregate: UInt64 = 0
        for item in sourceByBundlePath {
            let size = try CharacterStorageFiles.regularFileSize(
                item.source,
                maximumBytes: Self.maximumBytes(for: item.role),
                rejectHardLinks: false
            )
            expectedAggregate = try Self.addToAggregate(size, expectedAggregate)
        }
        for report in reports {
            let size = try CharacterStorageFiles.regularFileSize(
                report.source,
                maximumBytes: CharacterBundleManifest.maximumReportSize,
                rejectHardLinks: false
            )
            expectedAggregate = try Self.addToAggregate(size, expectedAggregate)
        }
        try requireDiskSpace(for: expectedAggregate, at: parent)

        let staging = parent.appendingPathComponent(
            ".\(packageURL.lastPathComponent).\(UUID().uuidString.lowercased()).tmp"
        )
        try CharacterStorageFiles.createPrivateDirectory(staging)
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: staging) } }

        var assets: [CharacterBundleAsset] = []
        var aggregate: UInt64 = 0
        for item in sourceByBundlePath {
            let destination = staging.appendingPathComponent(item.path)
            let copied = try CharacterStorageFiles.copyRegularFile(
                from: item.source,
                to: destination,
                maximumBytes: Self.maximumBytes(for: item.role),
                rejectHardLinks: false
            )
            aggregate = try Self.addToAggregate(copied.size, aggregate)
            assets.append(CharacterBundleAsset(role: item.role, path: item.path, size: copied.size, sha256: copied.sha256))
        }
        for report in reports {
            let destination = staging.appendingPathComponent(report.path)
            let copied = try CharacterStorageFiles.copyRegularFile(
                from: report.source,
                to: destination,
                maximumBytes: CharacterBundleManifest.maximumReportSize,
                rejectHardLinks: false
            )
            aggregate = try Self.addToAggregate(copied.size, aggregate)
            assets.append(CharacterBundleAsset(
                role: .report,
                path: report.path,
                size: copied.size,
                sha256: copied.sha256,
                moviePath: report.moviePath
            ))
        }
        guard aggregate == expectedAggregate else { throw CharacterLibraryStorageError.sourceChanged }

        let assetsByPath = Dictionary(uniqueKeysWithValues: assets.map { ($0.path, $0) })
        let reportsByMovie = Dictionary(grouping: assets.filter { $0.role == .report }) { $0.moviePath! }
        for movie in assets where movie.role == .movie {
            let report: CharacterBundleAsset?
            if let reportsForMovie = reportsByMovie[movie.path] {
                guard reportsForMovie.count == 1, let onlyReport = reportsForMovie.first else {
                    throw CharacterLibraryStorageError.undeclaredReport
                }
                report = onlyReport
            } else {
                report = nil
            }
            let movieURL = staging.appendingPathComponent(movie.path)
            let reportURL = report.map { staging.appendingPathComponent($0.path) }
            let reportData = try reportURL.map {
                try CharacterStorageFiles.readRegularFile(
                    $0,
                    maximumBytes: CharacterBundleManifest.maximumReportSize
                )
            }
            if transitionMoviePaths.contains(movie.path) {
                guard let reportData else {
                    throw CharacterLibraryStorageError.transitionAlphaReportRequired
                }
                try transitionPlaybackVerifier(movieURL, reportData)
                try transitionDurationVerifier(movieURL)
            } else {
                try playbackVerifier(movieURL, reportData)
            }
            let movieAfter = try CharacterStorageFiles.hashRegularFile(
                movieURL,
                maximumBytes: CharacterBundleManifest.maximumMovieSize,
                rejectHardLinks: false
            )
            guard movieAfter.size == movie.size, movieAfter.sha256 == movie.sha256 else {
                throw CharacterLibraryStorageError.sourceChanged
            }
            if let report, let reportURL {
                let reportAfter = try CharacterStorageFiles.hashRegularFile(
                    reportURL,
                    maximumBytes: CharacterBundleManifest.maximumReportSize,
                    rejectHardLinks: false
                )
                guard reportAfter.size == report.size,
                      reportAfter.sha256 == report.sha256,
                      assetsByPath[report.path] != nil else {
                    throw CharacterLibraryStorageError.sourceChanged
                }
            }
        }
        let manifest = try CharacterBundleManifest(
            characterID: entry.id,
            characterName: entry.name,
            mediaMap: rewrittenMap,
            assets: assets
        )
        let manifestData = try Self.encoder.encode(manifest)
        guard UInt64(manifestData.count) <= CharacterBundleManifest.maximumManifestSize else {
            throw CharacterLibraryStorageError.fileTooLarge
        }
        try CharacterStorageFiles.atomicWrite(
            manifestData,
            to: staging.appendingPathComponent("manifest.json"),
            expectedData: nil
        )
        try CharacterStorageFiles.syncDirectoryTree(staging)
        try FileManager.default.moveItem(at: staging, to: packageURL)
        try CharacterStorageFiles.syncDirectory(parent)
        succeeded = true
    }

    func stageImport(
        from packageURL: URL,
        against library: CharacterLibrary,
        allowLegacyTrust: Bool
    ) throws -> StagedCharacterImport {
        try requireLocal(packageURL)
        guard library.characters.count < CharacterLibrary.maximumCharacterCount else {
            throw CharacterLibraryStorageError.characterLimitReached
        }
        guard packageURL.pathExtension == "statelet-character" else {
            throw CharacterLibraryStorageError.unsafePath
        }
        let packageDescriptor = try CharacterStorageFiles.openDirectoryPathNoFollow(packageURL)
        defer { Darwin.close(packageDescriptor) }
        let manifestData = try CharacterStorageFiles.readRegularFile(
            relativePath: "manifest.json",
            rootDescriptor: packageDescriptor,
            maximumBytes: CharacterBundleManifest.maximumManifestSize,
            rejectHardLinks: true
        )
        let manifest = try CharacterBundleManifest.decode(manifestData)

        let expectedAggregate = try manifest.assets.reduce(UInt64(0)) { aggregate, asset in
            try Self.addToAggregate(asset.size, aggregate)
        }
        try requireDiskSpace(for: expectedAggregate, at: rootURL)

        let newID = UUID().uuidString.lowercased()
        let uniqueName = Self.uniqueName(manifest.characterName, in: library)
        let entry = try CharacterLibraryEntry(id: newID, name: uniqueName)
        let assetsBasename = ".character-\(newID).assets"
        let finalAssetsURL = rootURL.appendingPathComponent(assetsBasename, isDirectory: true)
        let finalMapURL = try mapURL(for: entry)
        guard !CharacterStorageFiles.pathExistsNoFollow(finalAssetsURL),
              !CharacterStorageFiles.pathExistsNoFollow(finalMapURL) else {
            throw CharacterLibraryStorageError.destinationExists
        }

        let staging = rootURL.appendingPathComponent(".character-import-\(UUID().uuidString.lowercased())", isDirectory: true)
        try CharacterStorageFiles.createPrivateDirectory(staging)
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: staging) } }
        let stagedAssets = staging.appendingPathComponent("assets", isDirectory: true)
        try CharacterStorageFiles.createPrivateDirectory(stagedAssets)

        var installedByBundlePath: [String: URL] = [:]
        var installedCollisionKeys = Set<String>()
        for asset in manifest.assets where asset.role != .report {
            let destination = stagedAssets.appendingPathComponent(asset.path)
            let collisionKey = destination.path.precomposedStringWithCanonicalMapping.lowercased()
            guard installedCollisionKeys.insert(collisionKey).inserted else {
                throw CharacterLibraryStorageError.unsafePath
            }
            installedByBundlePath[asset.path] = destination
        }
        for report in manifest.assets where report.role == .report {
            guard let moviePath = report.moviePath,
                  let movieURL = installedByBundlePath[moviePath] else {
                throw CharacterLibraryStorageError.unsafePath
            }
            let destination = movieURL.deletingPathExtension().appendingPathExtension("report.json")
            let collisionKey = destination.path.precomposedStringWithCanonicalMapping.lowercased()
            guard installedCollisionKeys.insert(collisionKey).inserted else {
                throw CharacterLibraryStorageError.undeclaredReport
            }
            installedByBundlePath[report.path] = destination
        }
        var aggregate: UInt64 = 0
        for asset in manifest.assets {
            guard let destination = installedByBundlePath[asset.path] else {
                throw CharacterLibraryStorageError.unsafePath
            }
            let copied = try CharacterStorageFiles.copyRegularFile(
                relativePath: asset.path,
                rootDescriptor: packageDescriptor,
                to: destination,
                maximumBytes: Self.maximumBytes(for: asset.role),
                rejectHardLinks: true
            )
            guard copied.size == asset.size, copied.sha256 == asset.sha256 else {
                throw CharacterLibraryStorageError.sourceChanged
            }
            aggregate = try Self.addToAggregate(copied.size, aggregate)
        }

        let reportsByMovie = try Dictionary(grouping: manifest.assets.filter { $0.role == .report }) { $0.moviePath! }
            .mapValues { reports -> CharacterBundleAsset in
                guard reports.count == 1, let report = reports.first else {
                    throw CharacterLibraryStorageError.undeclaredReport
                }
                return report
            }
        let transitionMoviePaths = Set(manifest.mediaMap.allTransitionEntries.map(\.path))
        for movie in manifest.assets where movie.role == .movie {
            guard let movieURL = installedByBundlePath[movie.path] else {
                throw CharacterLibraryStorageError.invalidFile
            }
            let reportData: Data?
            if let report = reportsByMovie[movie.path], let reportURL = installedByBundlePath[report.path] {
                reportData = try CharacterStorageFiles.readRegularFile(
                    reportURL,
                    maximumBytes: CharacterBundleManifest.maximumReportSize,
                    rejectHardLinks: true
                )
            } else if transitionMoviePaths.contains(movie.path) {
                throw CharacterLibraryStorageError.transitionAlphaReportRequired
            } else {
                guard allowLegacyTrust else { throw CharacterLibraryStorageError.legacyTrustRequired }
                reportData = nil
            }
            if transitionMoviePaths.contains(movie.path) {
                guard let reportData else {
                    throw CharacterLibraryStorageError.transitionAlphaReportRequired
                }
                try transitionPlaybackVerifier(movieURL, reportData)
                try transitionDurationVerifier(movieURL)
            } else {
                try playbackVerifier(movieURL, reportData)
            }
            let after = try CharacterStorageFiles.hashRegularFile(
                movieURL,
                maximumBytes: CharacterBundleManifest.maximumMovieSize,
                rejectHardLinks: true
            )
            guard after.size == movie.size, after.sha256 == movie.sha256 else {
                throw CharacterLibraryStorageError.sourceChanged
            }
            if let report = reportsByMovie[movie.path], let reportURL = installedByBundlePath[report.path] {
                let reportAfter = try CharacterStorageFiles.hashRegularFile(
                    reportURL,
                    maximumBytes: CharacterBundleManifest.maximumReportSize,
                    rejectHardLinks: true
                )
                guard reportAfter.size == report.size, reportAfter.sha256 == report.sha256 else {
                    throw CharacterLibraryStorageError.sourceChanged
                }
            }
        }

        let installedMap = try manifest.mediaMap(rewritingPaths: { path in
            guard installedByBundlePath[path] != nil else { throw CharacterLibraryStorageError.unsafePath }
            return "\(assetsBasename)/\(path)"
        })
        let stagedMap = staging.appendingPathComponent("media-map.json")
        let mapData = try Self.encoder.encode(installedMap)
        guard UInt64(mapData.count) <= Self.maximumMediaMapBytes else {
            throw CharacterLibraryStorageError.fileTooLarge
        }
        try CharacterStorageFiles.atomicWrite(mapData, to: stagedMap, expectedData: nil)
        try CharacterStorageFiles.syncDirectoryTree(staging)

        succeeded = true
        return StagedCharacterImport(
            entry: entry,
            mediaMap: installedMap,
            stagingURL: staging,
            stagedMapURL: stagedMap,
            stagedAssetsURL: stagedAssets,
            finalMapURL: finalMapURL,
            finalAssetsURL: finalAssetsURL,
            parentURL: rootURL
        )
    }

    static func defaultPlaybackVerifier(movieURL: URL, reportData: Data?) throws {
        if let reportData {
            let digest = try CharacterStorageFiles.hashRegularFile(
                movieURL,
                maximumBytes: CharacterBundleManifest.maximumMovieSize,
                rejectHardLinks: true
            ).sha256
            let report = try AlphaConversionReportValidator.validate(
                data: reportData,
                expectedOutputBasename: movieURL.lastPathComponent,
                actualOutputSHA256: digest
            )
            guard report.trust != .legacyPortableClaim else {
                throw CharacterLibraryStorageError.invalidPlayback
            }
            _ = try AlphaPlaybackProcessValidator.validate(url: movieURL, expected: report)
        } else {
            let probe = try AlphaPlaybackProcessValidator.probe(url: movieURL)
            guard probe.isPlayable,
                  probe.videoTrackCount == 1,
                  probe.audioTrackCount == 0,
                  probe.codec.caseInsensitiveCompare("hevc") == .orderedSame,
                  probe.decodedFirstFrame else {
                throw CharacterLibraryStorageError.invalidPlayback
            }
        }
    }

    static func defaultTransitionPlaybackVerifier(movieURL: URL, reportData: Data) throws {
        try defaultPlaybackVerifier(movieURL: movieURL, reportData: reportData)
    }

    static func defaultTransitionDurationVerifier(movieURL: URL) throws {
        let duration = try AlphaPlaybackProcessValidator.probe(url: movieURL).durationSeconds
        guard duration.isFinite,
              duration > 0,
              duration <= LifecycleTransitionMediaPolicy.maximumDuration else {
            throw CharacterLibraryStorageError.invalidPlayback
        }
    }

    private func mapURL(for entry: CharacterLibraryEntry) throws -> URL {
        let url = rootURL.appendingPathComponent(entry.mapPath)
        try requireSameRootBasename(url)
        return url
    }

    private func requireSameRootBasename(_ url: URL) throws {
        try requireLocal(url)
        guard url.deletingLastPathComponent().path == rootURL.path,
              url.lastPathComponent != ".",
              url.lastPathComponent != "..",
              !url.lastPathComponent.contains("/") else {
            throw CharacterLibraryStorageError.unsafePath
        }
    }

    private func requireLocal(_ url: URL) throws {
        guard url.isFileURL, url.host.map({ $0.isEmpty || $0 == "localhost" }) ?? true else {
            throw CharacterLibraryStorageError.nonLocalURL
        }
    }

    private static func resolvedMediaURL(_ path: String, relativeTo directory: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path).standardizedFileURL
    }

    private static func maximumBytes(for role: CharacterBundleAssetRole) -> UInt64 {
        switch role {
        case .movie: return CharacterBundleManifest.maximumMovieSize
        case .poster: return CharacterBundleManifest.maximumPosterSize
        case .report: return CharacterBundleManifest.maximumReportSize
        }
    }

    private static func addToAggregate(_ size: UInt64, _ aggregate: UInt64) throws -> UInt64 {
        let (sum, overflow) = aggregate.addingReportingOverflow(size)
        guard !overflow, sum <= CharacterBundleManifest.maximumAggregateSize else {
            throw CharacterLibraryStorageError.fileTooLarge
        }
        return sum
    }

    private func requireDiskSpace(for contentBytes: UInt64, at destination: URL) throws {
        let (required, overflow) = contentBytes.addingReportingOverflow(Self.minimumFreeSpaceReserveBytes)
        guard !overflow, try availableDiskBytes(destination) >= required else {
            throw CharacterLibraryStorageError.insufficientDiskSpace
        }
    }

    private static func uniqueName(_ requested: String, in library: CharacterLibrary) -> String {
        let existing = Set(library.characters.map { $0.name.precomposedStringWithCanonicalMapping.lowercased() })
        if !existing.contains(requested.precomposedStringWithCanonicalMapping.lowercased()) { return requested }
        for suffix in 2...CharacterLibrary.maximumCharacterCount + 1 {
            let suffixText = " \(suffix)"
            let available = max(1, CharacterLibraryEntry.maximumNameLength - suffixText.count)
            let prefix = String(requested.prefix(available)).trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = (prefix + suffixText).precomposedStringWithCanonicalMapping
            if !existing.contains(candidate.lowercased()) { return candidate }
        }
        return UUID().uuidString.lowercased()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

private extension MediaMap {
    func rewritingMediaPaths(_ transform: (String) throws -> String) throws -> MediaMap {
        var states: [PetState: StateMediaPlaylist] = [:]
        for (state, playlist) in self.states {
            let entries = try playlist.entries.map {
                try MediaEntry(
                    path: transform($0.path),
                    posterPath: try $0.posterPath.map(transform),
                    loop: $0.loop,
                    playbackRate: $0.playbackRate.value
                )
            }
            states[state] = try StateMediaPlaylist(
                mode: playlist.mode,
                advanceOn: playlist.advanceOn,
                fixedPath: transform(playlist.fixedPath),
                entries: entries
            )
        }
        let transitions = try Dictionary(uniqueKeysWithValues: self.transitions.map { key, playlist in
            (
                key,
                try StateMediaPlaylist(
                    mode: playlist.mode,
                    advanceOn: .stateEntry,
                    fixedPath: transform(playlist.fixedPath),
                    entries: playlist.entries.map { entry in
                        try MediaEntry(
                            path: transform(entry.path),
                            posterPath: try entry.posterPath.map(transform),
                            loop: false,
                            playbackRate: entry.playbackRate.value
                        )
                    }
                )
            )
        })
        return try MediaMap(
            version: version,
            defaultFormat: defaultFormat,
            window: window,
            states: states,
            transitions: transitions
        )
    }
}

private enum CharacterStorageFiles {
    struct Digest {
        let size: UInt64
        let sha256: String
    }

    static func pathExistsNoFollow(_ url: URL) -> Bool {
        var status = stat()
        return Darwin.lstat(url.path, &status) == 0
    }

    static func createPrivateDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw CharacterLibraryStorageError.destinationExists
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CharacterLibraryStorageError.unsafePath }
        defer { Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, mode_t(S_IRWXU)) == 0 else {
            throw CharacterLibraryStorageError.invalidFile
        }
    }

    static func requireNoFollowDirectoryPath(_ url: URL) throws {
        let descriptor = try openDirectoryPathNoFollow(url)
        Darwin.close(descriptor)
    }

    static func openDirectoryPathNoFollow(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw CharacterLibraryStorageError.nonLocalURL }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw CharacterLibraryStorageError.unsafePath }
        for component in url.pathComponents.dropFirst() {
            guard component != ".", component != "..", !component.contains("/") else {
                Darwin.close(descriptor)
                throw CharacterLibraryStorageError.unsafePath
            }
            let next = Darwin.openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(descriptor)
            guard next >= 0 else { throw CharacterLibraryStorageError.unsafePath }
            descriptor = next
        }
        return descriptor
    }

    static func readRegularFile(
        _ url: URL,
        maximumBytes: UInt64,
        rejectHardLinks: Bool = false
    ) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CharacterLibraryStorageError.invalidFile }
        defer { Darwin.close(descriptor) }
        return try readRegularFile(descriptor: descriptor, maximumBytes: maximumBytes, rejectHardLinks: rejectHardLinks)
    }

    static func readRegularFile(
        relativePath: String,
        rootDescriptor: Int32,
        maximumBytes: UInt64,
        rejectHardLinks: Bool
    ) throws -> Data {
        let descriptor = try openRegularFile(relativePath: relativePath, rootDescriptor: rootDescriptor)
        defer { Darwin.close(descriptor) }
        return try readRegularFile(descriptor: descriptor, maximumBytes: maximumBytes, rejectHardLinks: rejectHardLinks)
    }

    private static func readRegularFile(descriptor: Int32, maximumBytes: UInt64, rejectHardLinks: Bool) throws -> Data {
        let before = try validatedStatus(descriptor, maximumBytes: maximumBytes, rejectHardLinks: rejectHardLinks, allowEmpty: true)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            data.append(chunk)
            guard UInt64(data.count) <= maximumBytes else { throw CharacterLibraryStorageError.fileTooLarge }
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              sameIdentity(before, after),
              UInt64(data.count) == UInt64(before.st_size) else {
            throw CharacterLibraryStorageError.sourceChanged
        }
        return data
    }

    static func hashRegularFile(
        _ url: URL,
        maximumBytes: UInt64,
        rejectHardLinks: Bool,
        operationCheck: CharacterOperationCheck = {}
    ) throws -> Digest {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CharacterLibraryStorageError.invalidFile }
        defer { Darwin.close(descriptor) }
        return try hashDescriptor(
            descriptor,
            maximumBytes: maximumBytes,
            rejectHardLinks: rejectHardLinks,
            operationCheck: operationCheck
        )
    }

    static func regularFileSize(_ url: URL, maximumBytes: UInt64, rejectHardLinks: Bool) throws -> UInt64 {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CharacterLibraryStorageError.invalidFile }
        defer { Darwin.close(descriptor) }
        let status = try validatedStatus(
            descriptor,
            maximumBytes: maximumBytes,
            rejectHardLinks: rejectHardLinks,
            allowEmpty: false
        )
        return UInt64(status.st_size)
    }

    static func copyRegularFile(
        from source: URL,
        to destination: URL,
        maximumBytes: UInt64,
        rejectHardLinks: Bool
    ) throws -> Digest {
        let sourceDescriptor = Darwin.open(source.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard sourceDescriptor >= 0 else { throw CharacterLibraryStorageError.invalidFile }
        defer { Darwin.close(sourceDescriptor) }
        return try copyDescriptor(sourceDescriptor, to: destination, maximumBytes: maximumBytes, rejectHardLinks: rejectHardLinks)
    }

    static func copyRegularFile(
        relativePath: String,
        rootDescriptor: Int32,
        to destination: URL,
        maximumBytes: UInt64,
        rejectHardLinks: Bool
    ) throws -> Digest {
        let sourceDescriptor = try openRegularFile(relativePath: relativePath, rootDescriptor: rootDescriptor)
        defer { Darwin.close(sourceDescriptor) }
        return try copyDescriptor(sourceDescriptor, to: destination, maximumBytes: maximumBytes, rejectHardLinks: rejectHardLinks)
    }

    private static func copyDescriptor(
        _ source: Int32,
        to destination: URL,
        maximumBytes: UInt64,
        rejectHardLinks: Bool
    ) throws -> Digest {
        let before = try validatedStatus(source, maximumBytes: maximumBytes, rejectHardLinks: rejectHardLinks, allowEmpty: false)
        try createPrivateAncestors(destination.deletingLastPathComponent())
        let destinationDescriptor = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard destinationDescriptor >= 0 else { throw CharacterLibraryStorageError.destinationExists }
        var completed = false
        defer {
            Darwin.close(destinationDescriptor)
            if !completed { try? FileManager.default.removeItem(at: destination) }
        }
        guard Darwin.fchmod(destinationDescriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw CharacterLibraryStorageError.invalidFile
        }
        var hasher = SHA256()
        var copied: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while copied < UInt64(before.st_size) {
            let wanted = min(buffer.count, Int(UInt64(before.st_size) - copied))
            let count = Darwin.read(source, &buffer, wanted)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw CharacterLibraryStorageError.sourceChanged }
            hasher.update(data: Data(buffer[0..<count]))
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes {
                    Darwin.write(destinationDescriptor, $0.baseAddress!.advanced(by: offset), count - offset)
                }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw CharacterLibraryStorageError.invalidFile }
                offset += written
            }
            copied += UInt64(count)
        }
        var after = stat()
        guard Darwin.fstat(source, &after) == 0, sameIdentity(before, after),
              Darwin.fsync(destinationDescriptor) == 0 else {
            throw CharacterLibraryStorageError.sourceChanged
        }
        completed = true
        return Digest(size: copied, sha256: hex(hasher.finalize()))
    }

    private static func hashDescriptor(
        _ descriptor: Int32,
        maximumBytes: UInt64,
        rejectHardLinks: Bool,
        operationCheck: CharacterOperationCheck = {}
    ) throws -> Digest {
        try operationCheck()
        let before = try validatedStatus(descriptor, maximumBytes: maximumBytes, rejectHardLinks: rejectHardLinks, allowEmpty: false)
        var hasher = SHA256()
        var count: UInt64 = 0
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try operationCheck()
            count += UInt64(chunk.count)
            guard count <= maximumBytes else { throw CharacterLibraryStorageError.fileTooLarge }
            hasher.update(data: chunk)
        }
        try operationCheck()
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0, sameIdentity(before, after), count == UInt64(before.st_size) else {
            throw CharacterLibraryStorageError.sourceChanged
        }
        return Digest(size: count, sha256: hex(hasher.finalize()))
    }

    private static func openRegularFile(relativePath: String, rootDescriptor: Int32) throws -> Int32 {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") }) else {
            throw CharacterLibraryStorageError.unsafePath
        }
        var directory = Darwin.dup(rootDescriptor)
        guard directory >= 0 else { throw CharacterLibraryStorageError.invalidFile }
        for component in components.dropLast() {
            let next = Darwin.openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(directory)
            guard next >= 0 else { throw CharacterLibraryStorageError.unsafePath }
            directory = next
        }
        let result = Darwin.openat(directory, components.last!, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        Darwin.close(directory)
        guard result >= 0 else { throw CharacterLibraryStorageError.invalidFile }
        return result
    }

    static func atomicWrite(_ data: Data, to destination: URL, expectedData: Data?) throws {
        try createPrivateAncestors(destination.deletingLastPathComponent())
        let current: Data?
        if pathExistsNoFollow(destination) {
            current = try readRegularFile(destination, maximumBytes: UInt64(max(data.count, Int(CharacterLibraryStorage.maximumCatalogBytes))))
        } else {
            current = nil
        }
        guard current == expectedData else { throw CharacterLibraryStorageError.catalogConflict }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString.lowercased()).tmp")
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { throw CharacterLibraryStorageError.destinationExists }
        var published = false
        defer {
            Darwin.close(descriptor)
            if !published { try? FileManager.default.removeItem(at: temporary) }
        }
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw CharacterLibraryStorageError.invalidFile
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw CharacterLibraryStorageError.invalidFile }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw CharacterLibraryStorageError.invalidFile }
        if Darwin.rename(temporary.path, destination.path) != 0 {
            throw CharacterLibraryStorageError.commitFailed
        }
        published = true
        try syncDirectory(destination.deletingLastPathComponent())
    }

    static func withExclusiveLock<T>(in directory: URL, name: String, _ body: () throws -> T) throws -> T {
        try createPrivateAncestors(directory)
        let url = directory.appendingPathComponent(name)
        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw CharacterLibraryStorageError.invalidFile }
        defer { Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0,
              Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
            throw CharacterLibraryStorageError.invalidFile
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try body()
    }

    static func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CharacterLibraryStorageError.invalidFile }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw CharacterLibraryStorageError.invalidFile }
    }

    static func syncDirectoryTree(_ root: URL) throws {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        var directories = [root]
        while let url = enumerator?.nextObject() as? URL {
            if (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true { directories.append(url) }
        }
        for directory in directories.reversed() { try syncDirectory(directory) }
    }

    static func systemAvailableDiskBytes(at url: URL) throws -> UInt64 {
        var candidate = url
        while !pathExistsNoFollow(candidate), candidate.path != "/" {
            candidate.deleteLastPathComponent()
        }
        let values = try candidate.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage, available >= 0 else {
            throw CharacterLibraryStorageError.insufficientDiskSpace
        }
        return UInt64(available)
    }

    static func contractAssetBasename(_ value: String) throws -> String {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              value.utf8.count <= 255,
              value == value.precomposedStringWithCanonicalMapping,
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("\0"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CharacterLibraryStorageError.unsafePath
        }
        return value
    }

    private static func createPrivateAncestors(_ url: URL) throws {
        if pathExistsNoFollow(url) {
            let descriptor = try openDirectoryPathNoFollow(url)
            Darwin.close(descriptor)
            return
        }
        try createPrivateAncestors(url.deletingLastPathComponent())
        try createPrivateDirectory(url)
    }

    private static func validatedStatus(
        _ descriptor: Int32,
        maximumBytes: UInt64,
        rejectHardLinks: Bool,
        allowEmpty: Bool
    ) throws -> stat {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_size >= (allowEmpty ? 0 : 1),
              UInt64(status.st_size) <= maximumBytes,
              !rejectHardLinks || status.st_nlink == 1 else {
            throw CharacterLibraryStorageError.invalidFile
        }
        return status
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
