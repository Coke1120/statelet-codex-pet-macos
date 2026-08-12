import Darwin
import CoreFoundation
import Foundation

/// Migrates the legacy preferences domain before the app reads UserDefaults.
///
/// Production writes go through CFPreferences so cfprefsd and the on-disk
/// domain remain coherent. Tests that supply a custom home use an isolated,
/// safely-published file backend instead of changing the process preference
/// home.
struct PreferencesMigration {
    enum Status: Equatable {
        case notRun
        case notNeeded
        case alreadyCurrent
        case migrated
        case failed

        var diagnosticLabel: String {
            switch self {
            case .notRun: return "not-run"
            case .notNeeded: return "not-needed"
            case .alreadyCurrent: return "already-current"
            case .migrated: return "migrated"
            case .failed: return "failed"
            }
        }
    }

    private enum Failure: Error {
        case unsafe
        case invalid
        case publish
    }

    private static let maximumPreferencesBytes = 4 * 1_024 * 1_024
    private static let renamedKeys = [
        "CodexPetMac.windowFrames.v2": "Statelet.windowFrames.v2",
        "CodexPetMac.lastWindowFrame.v2": "Statelet.lastWindowFrame.v2",
        "CodexPetAlphaConversionProfile": "StateletAlphaConversionProfile",
        "CodexPetAlphaPythonPath": "StateletAlphaPythonPath",
    ]

    private let fileManager: FileManager
    private let homeURL: URL
    private let usesNativePreferences: Bool
    private let legacyIdentifier: String
    private let destinationIdentifier: String
    private let beforePublish: (() -> Void)?

    init(
        fileManager: FileManager = .default,
        homeURL: URL? = nil,
        legacyIdentifier: String = StateletIdentity.Legacy.bundleIdentifier,
        destinationIdentifier: String = StateletIdentity.bundleIdentifier,
        useNativePreferences: Bool? = nil,
        beforePublish: (() -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.homeURL = (homeURL ?? fileManager.homeDirectoryForCurrentUser).standardizedFileURL
        usesNativePreferences = useNativePreferences ?? (homeURL == nil)
        self.legacyIdentifier = legacyIdentifier
        self.destinationIdentifier = destinationIdentifier
        self.beforePublish = beforePublish
    }

    @discardableResult
    func migrate() -> Status {
        if usesNativePreferences { return migrateNativePreferences() }

        let legacyURL = preferencesURL(bundleIdentifier: legacyIdentifier)
        let destinationURL = preferencesURL(bundleIdentifier: destinationIdentifier)
        guard fileManager.fileExists(atPath: legacyURL.path) else { return .notNeeded }

        do {
            let legacySnapshot = try safeData(at: legacyURL)
            let legacy = try decode(legacySnapshot)
            let destinationExisted = fileManager.fileExists(atPath: destinationURL.path)
            let destinationSnapshot = destinationExisted ? try safeData(at: destinationURL) : nil
            let destination = try destinationSnapshot.map { try decode($0) } ?? [:]
            let merged = mergedPreferences(legacy: legacy, destination: destination)
            guard !NSDictionary(dictionary: merged).isEqual(to: destination) else {
                return .alreadyCurrent
            }

            beforePublish?()
            try publishFile(
                merged,
                to: destinationURL,
                destinationSnapshot: destinationSnapshot
            )
            return .migrated
        } catch {
            return .failed
        }
    }

    private func migrateNativePreferences() -> Status {
        do {
            let legacy = nativePreferences(identifier: legacyIdentifier)
            guard !legacy.isEmpty else { return .notNeeded }
            let destination = nativePreferences(identifier: destinationIdentifier)
            let merged = mergedPreferences(legacy: legacy, destination: destination)
            guard !NSDictionary(dictionary: merged).isEqual(to: destination) else {
                return .alreadyCurrent
            }
            beforePublish?()
            guard NSDictionary(dictionary: nativePreferences(identifier: legacyIdentifier))
                .isEqual(to: legacy),
                  NSDictionary(dictionary: nativePreferences(identifier: destinationIdentifier))
                .isEqual(to: destination) else {
                throw Failure.unsafe
            }
            try publishWithCoreFoundation(merged, destination: destination)
            return .migrated
        } catch {
            return .failed
        }
    }

    private func mergedPreferences(
        legacy: [String: Any],
        destination: [String: Any]
    ) -> [String: Any] {
        var merged = legacy
        for (key, value) in destination { merged[key] = value }
        for (oldKey, newKey) in Self.renamedKeys {
            if merged[newKey] == nil, let value = merged[oldKey] { merged[newKey] = value }
            merged.removeValue(forKey: oldKey)
        }
        return merged
    }

    private func publishWithCoreFoundation(
        _ merged: [String: Any],
        destination: [String: Any]
    ) throws {
        let applicationID = destinationIdentifier as CFString
        for key in destination.keys where merged[key] == nil {
            CFPreferencesSetValue(
                key as CFString,
                nil,
                applicationID,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        }
        for (key, value) in merged {
            CFPreferencesSetValue(
                key as CFString,
                value as CFPropertyList,
                applicationID,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        }
        guard CFPreferencesSynchronize(
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) else { throw Failure.publish }
        let stored = nativePreferences(identifier: destinationIdentifier)
        guard NSDictionary(dictionary: stored).isEqual(to: merged) else {
            throw Failure.publish
        }
    }

    private func nativePreferences(identifier: String) -> [String: Any] {
        CFPreferencesCopyMultiple(
            nil,
            identifier as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String: Any] ?? [:]
    }

    private func publishFile(
        _ merged: [String: Any],
        to destinationURL: URL,
        destinationSnapshot: Data?
    ) throws {
        let encoded = try PropertyListSerialization.data(
            fromPropertyList: merged,
            format: .binary,
            options: 0
        )
        guard encoded.count <= Self.maximumPreferencesBytes else { throw Failure.invalid }
        let directory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporaryURL = directory.appendingPathComponent(".statelet-preferences-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try encoded.write(to: temporaryURL, options: .withoutOverwriting)
        guard chmod(temporaryURL.path, 0o600) == 0 else { throw Failure.publish }
        if let destinationSnapshot {
            // The destination was validated above. Exchange keeps replacement
            // atomic and lets us verify that the displaced inode is regular.
            guard renamex_np(temporaryURL.path, destinationURL.path, UInt32(RENAME_SWAP)) == 0 else {
                throw Failure.publish
            }
            do {
                guard try safeData(at: temporaryURL) == destinationSnapshot else {
                    throw Failure.unsafe
                }
            } catch {
                _ = renamex_np(temporaryURL.path, destinationURL.path, UInt32(RENAME_SWAP))
                throw Failure.unsafe
            }
        } else {
            guard renamex_np(temporaryURL.path, destinationURL.path, UInt32(RENAME_EXCL)) == 0 else {
                throw Failure.unsafe
            }
        }
    }

    private func preferencesURL(bundleIdentifier: String) -> URL {
        homeURL.appendingPathComponent("Library/Preferences/\(bundleIdentifier).plist")
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        guard let object = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ), let dictionary = object as? [String: Any] else { throw Failure.invalid }
        return dictionary
    }

    private func safeData(at url: URL) throws -> Data {
        let parent = url.deletingLastPathComponent()
        let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw Failure.unsafe }
        defer { close(directory) }
        let descriptor = openat(directory, url.lastPathComponent, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.unsafe }
        defer { close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_size >= 0,
              information.st_size <= Self.maximumPreferencesBytes else {
            throw Failure.unsafe
        }
        let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
        guard data.count == information.st_size else { throw Failure.unsafe }
        return data
    }
}
