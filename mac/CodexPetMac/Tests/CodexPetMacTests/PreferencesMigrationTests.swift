import Foundation
import CoreFoundation
import XCTest
@testable import Statelet

final class PreferencesMigrationTests: XCTestCase {
    func testMigrationPreservesUnknownKeysAndDestinationWins() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let legacy = preferencesURL(home: home, identifier: StateletIdentity.Legacy.bundleIdentifier)
        let current = preferencesURL(home: home, identifier: StateletIdentity.bundleIdentifier)
        try write([
            "legacy-only": "kept",
            "shared": "old",
            "CodexPetMac.windowFrames.v2": ["display": ["x": 3.0]],
            "CodexPetAlphaConversionProfile": "fit",
            "CodexPetAlphaPythonPath": "/private/interpreter",
        ], to: legacy)
        try write(["shared": "new"], to: current)

        let migration = PreferencesMigration(homeURL: home)
        XCTAssertEqual(migration.migrate(), .migrated)
        let result = try read(current)
        XCTAssertEqual(result["legacy-only"] as? String, "kept")
        XCTAssertEqual(result["shared"] as? String, "new")
        XCTAssertNil(result["CodexPetMac.windowFrames.v2"])
        XCTAssertNotNil(result["Statelet.windowFrames.v2"])
        XCTAssertEqual(result["StateletAlphaConversionProfile"] as? String, "fit")
        XCTAssertEqual(result["StateletAlphaPythonPath"] as? String, "/private/interpreter")
        XCTAssertNil(result["CodexPetAlphaConversionProfile"])
        XCTAssertNil(result["CodexPetAlphaPythonPath"])
        XCTAssertEqual(migration.migrate(), .alreadyCurrent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testConcurrentDestinationCreationFailsClosed() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let legacy = preferencesURL(home: home, identifier: StateletIdentity.Legacy.bundleIdentifier)
        let current = preferencesURL(home: home, identifier: StateletIdentity.bundleIdentifier)
        try write(["legacy": true], to: legacy)
        let migration = PreferencesMigration(homeURL: home) {
            try? self.write(["concurrent": true], to: current)
        }

        XCTAssertEqual(migration.migrate(), .failed)
        XCTAssertEqual(try read(current)["concurrent"] as? Bool, true)
    }

    func testDestinationOldKeysWinWhenRenamedToCanonicalKeys() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let legacy = preferencesURL(home: home, identifier: StateletIdentity.Legacy.bundleIdentifier)
        let current = preferencesURL(home: home, identifier: StateletIdentity.bundleIdentifier)
        try write([
            "CodexPetMac.windowFrames.v2": ["owner": "legacy"],
            "CodexPetAlphaConversionProfile": "legacy-profile",
        ], to: legacy)
        try write([
            "CodexPetMac.windowFrames.v2": ["owner": "destination"],
            "CodexPetAlphaConversionProfile": "destination-profile",
        ], to: current)

        XCTAssertEqual(PreferencesMigration(homeURL: home).migrate(), .migrated)
        let result = try read(current)
        XCTAssertEqual(
            (result["Statelet.windowFrames.v2"] as? [String: String])?["owner"],
            "destination"
        )
        XCTAssertEqual(
            result["StateletAlphaConversionProfile"] as? String,
            "destination-profile"
        )
        XCTAssertNil(result["CodexPetMac.windowFrames.v2"])
        XCTAssertNil(result["CodexPetAlphaConversionProfile"])
    }

    func testSymlinkSourceFailsClosed() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let outside = home.appendingPathComponent("outside.plist")
        try write(["private": "never-read"], to: outside)
        let legacy = preferencesURL(home: home, identifier: StateletIdentity.Legacy.bundleIdentifier)
        try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: outside)

        XCTAssertEqual(
            PreferencesMigration(homeURL: home).migrate(),
            .failed
        )
    }

    func testNativeBackendPublishesThroughCoreFoundation() throws {
        let suffix = UUID().uuidString
        let legacyIdentifier = "com.coke1120.StateletTests.Legacy.\(suffix)"
        let destinationIdentifier = "com.coke1120.StateletTests.Current.\(suffix)"
        let home = try makeHome()
        defer {
            clearDomain(legacyIdentifier)
            clearDomain(destinationIdentifier)
            try? FileManager.default.removeItem(at: home)
        }
        CFPreferencesSetValue(
            "native-key" as CFString,
            "published" as CFString,
            legacyIdentifier as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        XCTAssertTrue(CFPreferencesSynchronize(
            legacyIdentifier as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ))

        let migration = PreferencesMigration(
            homeURL: home,
            legacyIdentifier: legacyIdentifier,
            destinationIdentifier: destinationIdentifier,
            useNativePreferences: true
        )
        XCTAssertEqual(migration.migrate(), .migrated)
        XCTAssertEqual(nativeDomain(destinationIdentifier)["native-key"] as? String, "published")
        XCTAssertTrue(CFPreferencesSynchronize(
            destinationIdentifier as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ))
        XCTAssertEqual(migration.migrate(), .alreadyCurrent)
    }

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-preferences-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Preferences", isDirectory: true),
            withIntermediateDirectories: true
        )
        return home
    }

    private func preferencesURL(home: URL, identifier: String) -> URL {
        home.appendingPathComponent("Library/Preferences/\(identifier).plist")
    }

    private func write(_ payload: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .binary,
            options: 0
        )
        try data.write(to: url)
    }

    private func read(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any]
        )
    }

    private func clearDomain(_ identifier: String) {
        let applicationID = identifier as CFString
        for key in nativeDomain(identifier).keys {
            CFPreferencesSetValue(
                key as CFString,
                nil,
                applicationID,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        }
        CFPreferencesSynchronize(
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }

    private func nativeDomain(_ identifier: String) -> [String: Any] {
        CFPreferencesCopyMultiple(
            nil,
            identifier as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String: Any] ?? [:]
    }
}
