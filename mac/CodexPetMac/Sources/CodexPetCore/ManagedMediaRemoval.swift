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
            return "The movie is still used by another Statelet state. Remove those references first."
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
        let root = canonicalRoot.standardizedFileURL
        let expectedMap = root.appendingPathComponent("media-map.json").standardizedFileURL
        let configuredMap = mapURL.standardizedFileURL
        guard configuredMap.path == expectedMap.path else {
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
        guard configuredMap.resolvingSymlinksInPath().standardizedFileURL.path == expectedMap.path,
              mapValues.isSymbolicLink != true,
              rootValues.isSymbolicLink != true,
              root.resolvingSymlinksInPath().standardizedFileURL.path == root.path else {
            throw ManagedMediaRemovalError.nonCanonicalMediaMap
        }
        guard let entry = mediaMap.playlist(for: state)?.entry(path: path) else {
            throw ManagedMediaRemovalError.entryNotFound
        }

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

        let updated = try mediaMap.removingEntry(for: state, path: path)
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
