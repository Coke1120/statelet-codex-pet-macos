import CodexPetCore
import Darwin
import Foundation
import XCTest
@testable import Statelet

final class GlobalTransitionLibraryStorageTests: XCTestCase {
    func testMissingLibraryLoadsAsEmptyThenSavesPrivateFile() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = CharacterLibraryStorage(mediaMapURL: root.appendingPathComponent("media-map.json"))

        let missing = try storage.loadGlobalTransitionLibrary()
        XCTAssertNil(missing.encodedData)
        XCTAssertTrue(missing.library.transitions.isEmpty)
        XCTAssertEqual(storage.globalTransitionLibraryURL.lastPathComponent, "global-transitions.json")

        let entry = try MediaEntry(path: "transition.mov")
        let library = try missing.library.settingTransition(from: .idle, to: .running, entry: entry)
        let saved = try storage.saveGlobalTransitionLibrary(library, expectedData: nil)
        let loaded = try storage.loadGlobalTransitionLibrary()
        XCTAssertEqual(loaded.encodedData, saved)
        XCTAssertEqual(loaded.library, library)

        var status = stat()
        XCTAssertEqual(lstat(storage.globalTransitionLibraryURL.path, &status), 0)
        XCTAssertEqual(status.st_mode & mode_t(0o777), mode_t(0o600))
    }

    func testSaveUsesCompareAndSwap() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = CharacterLibraryStorage(mediaMapURL: root.appendingPathComponent("media-map.json"))
        let first = try storage.saveGlobalTransitionLibrary(try GlobalTransitionLibrary(), expectedData: nil)
        let changed = try GlobalTransitionLibrary().settingTransition(
            from: .idle,
            to: .running,
            entry: try MediaEntry(path: "changed.mov")
        )
        _ = try storage.saveGlobalTransitionLibrary(changed, expectedData: first)

        XCTAssertThrowsError(try storage.saveGlobalTransitionLibrary(try GlobalTransitionLibrary(), expectedData: first)) {
            XCTAssertEqual($0 as? CharacterLibraryStorageError, .catalogConflict)
        }
        XCTAssertEqual(try storage.loadGlobalTransitionLibrary().library, changed)
    }

    func testLoadRejectsSymlink() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target.json")
        try Data("{\"schema_version\":1,\"transitions\":{}}".utf8).write(to: target)
        let storage = CharacterLibraryStorage(mediaMapURL: root.appendingPathComponent("media-map.json"))
        try FileManager.default.createSymbolicLink(at: storage.globalTransitionLibraryURL, withDestinationURL: target)

        XCTAssertThrowsError(try storage.loadGlobalTransitionLibrary())
    }

    private func temporaryDirectory() -> URL {
        let temporaryPath = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let noFollowSafePath = temporaryPath.hasPrefix("/var/")
            ? "/private\(temporaryPath)"
            : temporaryPath
        return URL(fileURLWithPath: noFollowSafePath, isDirectory: true)
            .appendingPathComponent("statelet-global-transition-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
