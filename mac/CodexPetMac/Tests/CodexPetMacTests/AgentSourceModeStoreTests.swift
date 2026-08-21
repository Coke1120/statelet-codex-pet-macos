import CodexPetCore
import Darwin
import Foundation
import XCTest
@testable import Statelet

final class AgentSourceModeStoreTests: XCTestCase {
    func testMissingAndInvalidRecordsDefaultToCombined() throws {
        let root = privateTemporaryDirectory
            .appendingPathComponent("statelet-agent-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentSourceModeStore(
            sessionActivityURL: root.appendingPathComponent("activity-v1.json")
        )
        XCTAssertEqual(store.load(), .combined)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"version":1,"mode":"invalid"}"#.utf8).write(to: store.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.url.path)
        XCTAssertEqual(store.load(), .combined)
        try Data(#"{"version":2,"mode":"grok"}"#.utf8).write(to: store.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.url.path)
        XCTAssertEqual(store.load(), .combined)
        try Data(#"{"version":1,"mode":"grok","extra":true}"#.utf8).write(to: store.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.url.path)
        XCTAssertEqual(store.load(), .combined)
        try Data(#"{"version":1.5,"mode":"grok"}"#.utf8).write(to: store.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.url.path)
        XCTAssertEqual(store.load(), .combined)
    }

    func testSaveRoundTripsAndUsesPrivatePermissions() throws {
        let root = privateTemporaryDirectory
            .appendingPathComponent("statelet-agent-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentSourceModeStore(
            sessionActivityURL: root.appendingPathComponent("activity-v1.json")
        )
        do {
            try store.save(.grok)
        } catch {
            return XCTFail("save failed with \(String(reflecting: error))")
        }
        XCTAssertEqual(store.load(), .grok)
        var fileStatus = stat()
        XCTAssertEqual(lstat(store.url.path, &fileStatus), 0)
        XCTAssertEqual(fileStatus.st_mode & 0o777, 0o600)
        var directoryStatus = stat()
        XCTAssertEqual(lstat(root.path, &directoryStatus), 0)
        XCTAssertEqual(directoryStatus.st_mode & 0o777, 0o700)
        XCTAssertEqual(chmod(root.path, 0o755), 0)
        XCTAssertEqual(store.load(), .combined)
        XCTAssertThrowsError(try store.save(.codex))
        XCTAssertEqual(lstat(root.path, &directoryStatus), 0)
        XCTAssertEqual(directoryStatus.st_mode & 0o777, 0o755)
    }

    func testLoadRejectsSymlinkOversizedAndSpecialFiles() throws {
        let root = privateTemporaryDirectory
            .appendingPathComponent("statelet-agent-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AgentSourceModeStore(
            sessionActivityURL: root.appendingPathComponent("activity-v1.json")
        )
        let real = root.appendingPathComponent("real.json")
        try Data(#"{"version":1,"mode":"grok"}"#.utf8).write(to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: real)
        XCTAssertEqual(store.load(), .combined)
        XCTAssertThrowsError(try store.save(.codex))

        try FileManager.default.removeItem(at: store.url)
        try Data(repeating: 0, count: AgentSourceModeStore.maximumBytes + 1).write(to: store.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.url.path)
        XCTAssertEqual(store.load(), .combined)

        try FileManager.default.removeItem(at: store.url)
        XCTAssertEqual(mkfifo(store.url.path, 0o600), 0)
        XCTAssertEqual(store.load(), .combined)
        XCTAssertThrowsError(try store.save(.grok))
    }

    func testRejectsSymlinkedSessionsDirectoryWithoutChangingTarget() throws {
        let root = privateTemporaryDirectory
            .appendingPathComponent("statelet-agent-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: sessions, withDestinationURL: target)
        let store = AgentSourceModeStore(
            sessionActivityURL: sessions.appendingPathComponent("activity-v1.json")
        )
        XCTAssertEqual(store.load(), .combined)
        XCTAssertThrowsError(try store.save(.grok))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: target.appendingPathComponent(AgentSourceModeStore.filename).path
        ))
    }

    private var privateTemporaryDirectory: URL {
        let path = FileManager.default.temporaryDirectory.path
        return URL(fileURLWithPath: path.hasPrefix("/var/") ? "/private\(path)" : path)
    }
}
