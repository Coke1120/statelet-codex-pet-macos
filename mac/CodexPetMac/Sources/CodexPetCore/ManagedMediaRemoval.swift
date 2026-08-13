import Foundation
import Darwin

public enum ManagedMediaRemovalMode: Equatable, Sendable {
    case libraryOnly
    case moveManagedFilesToTrash
}

public enum ManagedMediaRemovalError: Error, Equatable, LocalizedError {
    case nonCanonicalMediaMap
    case entryNotFound
    case movieMissing
    case unmanagedMovie
    case unsafeTarget
    case stillReferenced

    public var errorDescription: String? {
        switch self {
        case .nonCanonicalMediaMap:
            return "File removal requires Statelet's canonical managed Media folder."
        case .entryNotFound:
            return "The selected clip is no longer in this state."
        case .movieMissing:
            return "The selected movie is already missing from disk."
        case .unmanagedMovie:
            return "Only movies inside Statelet's managed Media folder can be moved to Trash."
        case .unsafeTarget:
            return "Statelet refused to move a symbolic link or unsafe media target."
        case .stillReferenced:
            return "The movie is still used by another Statelet mapping. Remove those references first."
        }
    }
}

public struct ManagedMediaRemovalPlan: Equatable, Sendable {
    public let updatedMap: MediaMap
    public let trashURLs: [URL]

    public init(updatedMap: MediaMap, trashURLs: [URL]) {
        self.updatedMap = updatedMap
        self.trashURLs = trashURLs
    }
}

/// Produces a fail-closed plan for removing one library entry and moving its
/// managed movie plus sibling verification report to the user's Trash.
/// Posters are intentionally excluded because they may be shared or supplied
/// independently; the existing unused-media cleanup can handle them safely.
public enum ManagedMediaRemovalPlanner {
    public static func plan(
        mediaMap: MediaMap,
        mapURL: URL,
        state: PetState,
        path: String,
        canonicalRoot: URL,
        fileManager: FileManager = .default
    ) throws -> ManagedMediaRemovalPlan {
        let context = try validateContext(mapURL: mapURL, canonicalRoot: canonicalRoot)
        guard let entry = mediaMap.playlist(for: state)?.entry(path: path) else {
            throw ManagedMediaRemovalError.entryNotFound
        }
        return try plan(
            mediaMap: mediaMap,
            updatedMap: mediaMap.removingEntry(for: state, path: path),
            entry: entry,
            context: context,
            fileManager: fileManager
        )
    }

    public static func plan(
        mediaMap: MediaMap,
        mapURL: URL,
        inStateTransition state: PetState,
        canonicalRoot: URL,
        fileManager: FileManager = .default
    ) throws -> ManagedMediaRemovalPlan {
        let context = try validateContext(mapURL: mapURL, canonicalRoot: canonicalRoot)
        guard let entry = mediaMap.inStateTransition(for: state) else {
            throw ManagedMediaRemovalError.entryNotFound
        }
        return try plan(
            mediaMap: mediaMap,
            updatedMap: mediaMap.removingInStateTransition(for: state),
            entry: entry,
            context: context,
            fileManager: fileManager
        )
    }

    public static func plan(
        mediaMap: MediaMap,
        mapURL: URL,
        transitionFrom: PetState,
        transitionTo: PetState,
        path: String? = nil,
        canonicalRoot: URL,
        fileManager: FileManager = .default
    ) throws -> ManagedMediaRemovalPlan {
        let context = try validateContext(mapURL: mapURL, canonicalRoot: canonicalRoot)
        guard let playlist = mediaMap.transitionPlaylist(from: transitionFrom, to: transitionTo) else {
            throw ManagedMediaRemovalError.entryNotFound
        }
        let entry: MediaEntry
        if let path {
            guard let selected = playlist.entry(path: path) else {
                throw ManagedMediaRemovalError.entryNotFound
            }
            entry = selected
        } else {
            entry = playlist.fixedEntry
        }
        return try plan(
            mediaMap: mediaMap,
            updatedMap: path == nil
                ? mediaMap.removingTransition(from: transitionFrom, to: transitionTo)
                : mediaMap.removingTransitionEntry(from: transitionFrom, to: transitionTo, path: entry.path),
            entry: entry,
            context: context,
            fileManager: fileManager
        )
    }

    private static func validateContext(
        mapURL: URL,
        canonicalRoot: URL
    ) throws -> (root: URL, configuredMap: URL) {
        let root = canonicalRoot.standardizedFileURL
        let configuredMap = mapURL.standardizedFileURL
        guard configuredMap.deletingLastPathComponent().path == root.path,
              isManagedMapBasename(configuredMap.lastPathComponent) else {
            throw ManagedMediaRemovalError.nonCanonicalMediaMap
        }
        let rootValues: URLResourceValues
        let mapValues: URLResourceValues
        do {
            rootValues = try root.resourceValues(forKeys: [.isSymbolicLinkKey])
            mapValues = try configuredMap.resourceValues(forKeys: [.isSymbolicLinkKey])
        } catch {
            throw ManagedMediaRemovalError.nonCanonicalMediaMap
        }
        guard configuredMap.resolvingSymlinksInPath().standardizedFileURL.path == configuredMap.path,
              mapValues.isSymbolicLink != true,
              rootValues.isSymbolicLink != true,
              root.resolvingSymlinksInPath().standardizedFileURL.path == root.path else {
            throw ManagedMediaRemovalError.nonCanonicalMediaMap
        }
        return (root, configuredMap)
    }

    private static func isManagedMapBasename(_ basename: String) -> Bool {
        if basename == CharacterLibrary.defaultMapPath { return true }
        let prefix = ".character-"
        let suffix = ".media-map.json"
        guard basename.hasPrefix(prefix), basename.hasSuffix(suffix) else { return false }
        let id = String(basename.dropFirst(prefix.count).dropLast(suffix.count))
        return (try? CharacterLibraryEntry(id: id, name: "Managed removal"))?.mapPath == basename
    }

    private static func plan(
        mediaMap: MediaMap,
        updatedMap updated: MediaMap,
        entry: MediaEntry,
        context: (root: URL, configuredMap: URL),
        fileManager: FileManager
    ) throws -> ManagedMediaRemovalPlan {
        let root = context.root
        let configuredMap = context.configuredMap
        let mapURL = configuredMap
        let expectedMap = configuredMap

        let rawMovie = mediaMap.resolvedURL(for: entry, relativeTo: mapURL).standardizedFileURL
        guard rawMovie.path != configuredMap.path,
              rawMovie.pathExtension.caseInsensitiveCompare("mov") == .orderedSame else {
            throw ManagedMediaRemovalError.unsafeTarget
        }
        guard fileManager.fileExists(atPath: rawMovie.path) else {
            throw ManagedMediaRemovalError.movieMissing
        }
        let movieValues: URLResourceValues
        do {
            movieValues = try rawMovie.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
        } catch {
            throw ManagedMediaRemovalError.unsafeTarget
        }
        let movie = rawMovie.resolvingSymlinksInPath().standardizedFileURL
        guard movieValues.isRegularFile == true, movieValues.isSymbolicLink != true else {
            throw ManagedMediaRemovalError.unsafeTarget
        }
        guard movie.path != configuredMap.path,
              movie.path != expectedMap.path,
              movie.pathExtension.caseInsensitiveCompare("mov") == .orderedSame else {
            throw ManagedMediaRemovalError.unsafeTarget
        }
        guard isInside(movie, root: root) else {
            throw ManagedMediaRemovalError.unmanagedMovie
        }

        for playlist in updated.states.values {
            for remaining in playlist.entries {
                let remainingURL = updated.resolvedURL(for: remaining, relativeTo: mapURL)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                if remainingURL.path == movie.path {
                    throw ManagedMediaRemovalError.stillReferenced
                }
            }
        }
        for playlist in updated.transitions.values {
            for transition in playlist.entries {
                let remainingURL = updated.resolvedURL(for: transition, relativeTo: mapURL)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                if remainingURL.path == movie.path {
                    throw ManagedMediaRemovalError.stillReferenced
                }
            }
        }
        for transition in updated.inStateTransitions.values {
            let remainingURL = updated.resolvedURL(for: transition, relativeTo: mapURL)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            if remainingURL.path == movie.path { throw ManagedMediaRemovalError.stillReferenced }
        }

        var targets = [movie]
        let rawReport = rawMovie.deletingPathExtension().appendingPathExtension("report.json")
        if try itemExistsWithoutFollowingSymlinks(at: rawReport) {
            let reportValues: URLResourceValues
            do {
                reportValues = try rawReport.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
            } catch {
                throw ManagedMediaRemovalError.unsafeTarget
            }
            let report = rawReport.resolvingSymlinksInPath().standardizedFileURL
            guard reportValues.isRegularFile == true,
                  reportValues.isSymbolicLink != true,
                  isInside(report, root: root) else {
                throw ManagedMediaRemovalError.unsafeTarget
            }
            targets.append(report)
        }
        return ManagedMediaRemovalPlan(updatedMap: updated, trashURLs: targets)
    }

    private static func itemExistsWithoutFollowingSymlinks(at url: URL) throws -> Bool {
        var information = stat()
        let result = url.path.withCString { path in
            lstat(path, &information)
        }
        if result == 0 {
            return true
        }
        if errno == ENOENT {
            return false
        }
        throw ManagedMediaRemovalError.unsafeTarget
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        url.path.hasPrefix(root.path + "/")
    }
}
