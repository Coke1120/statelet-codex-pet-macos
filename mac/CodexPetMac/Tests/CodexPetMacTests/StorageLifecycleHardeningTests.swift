import AppKit
import CodexPetCore
import Darwin
import XCTest
@testable import Statelet

final class StorageLifecycleHardeningTests: XCTestCase {
    private final class LockedState: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var results: [LifecycleStateReadResult] = []

        func nextCall() -> Int {
            lock.withLock {
                calls += 1
                return calls
            }
        }

        func append(_ result: LifecycleStateReadResult) {
            lock.withLock { results.append(result) }
        }

        var snapshot: [LifecycleStateReadResult] {
            lock.withLock { results }
        }
    }

    func testPosterInstallerRejectsSymlinkOversizeMalformedAndLowDisk() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real.png")
        try Data("not an image".utf8).write(to: real)
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try SecurePosterInstaller().install(source: link, destination: root.appendingPathComponent("link-copy.png"))) {
            XCTAssertEqual($0 as? SecurePosterInstallerError, .invalidSource)
        }

        let oversized = root.appendingPathComponent("large.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: nil))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: SecurePosterInstaller.maximumBytes + 1)
        try handle.close()
        XCTAssertThrowsError(try SecurePosterInstaller().install(source: oversized, destination: root.appendingPathComponent("large-copy.png"))) {
            XCTAssertEqual($0 as? SecurePosterInstallerError, .tooLarge)
        }

        XCTAssertThrowsError(try SecurePosterInstaller().install(source: real, destination: root.appendingPathComponent("bad-copy.png"))) {
            XCTAssertEqual($0 as? SecurePosterInstallerError, .invalidImage)
        }
        let lowDisk = SecurePosterInstaller(availableDiskBytes: { _ in 0 })
        XCTAssertThrowsError(try lowDisk.install(source: real, destination: root.appendingPathComponent("no-space.png"))) {
            XCTAssertEqual($0 as? SecurePosterInstallerError, .insufficientDiskSpace)
        }
    }

    func testPosterInstallerPublishesDecodedImage() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png")
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("fixture image encoding failed")
        }
        try png.write(to: source)
        let destination = root.appendingPathComponent("installed.png")
        try SecurePosterInstaller().install(source: source, destination: destination)
        XCTAssertNotNil(NSImage(contentsOf: destination))
    }

    func testPosterInstallerDoesNotOverwriteExistingDestination() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png")
        let destination = root.appendingPathComponent("installed.png")
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("fixture image encoding failed")
        }
        try png.write(to: source)
        try Data("keep".utf8).write(to: destination)
        XCTAssertThrowsError(try SecurePosterInstaller().install(source: source, destination: destination)) {
            XCTAssertEqual($0 as? SecurePosterInstallerError, .publicationFailed)
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("keep".utf8))
    }

    func testPosterInstallerRollsBackDestinationWhenPostRenameSyncFails() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png")
        let destination = root.appendingPathComponent("installed.png")
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.systemPurple.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("fixture image encoding failed")
        }
        try png.write(to: source)

        var syncCalls = 0
        let installer = SecurePosterInstaller(syncDirectory: { descriptor in
            syncCalls += 1
            return syncCalls == 1 ? -1 : Darwin.fsync(descriptor)
        })

        XCTAssertThrowsError(try installer.install(source: source, destination: destination)) {
            XCTAssertEqual($0 as? SecurePosterInstallerError, .publicationFailed)
        }
        XCTAssertEqual(syncCalls, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source.png"])
    }

    func testLifecycleReaderRejectsSymlinkAndOversizedFile() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("state.json")
        try Data("{}".utf8).write(to: real)
        let link = root.appendingPathComponent("state-link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(LifecycleStateFileReader.load(link), .corrupt)

        let oversized = root.appendingPathComponent("oversized.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: nil))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: LifecycleStateFileReader.maximumBytes + 1)
        try handle.close()
        XCTAssertEqual(LifecycleStateFileReader.load(oversized), .corrupt)
    }

    func testSessionActivityReaderRejectsSymlinkAndOversizedFile() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("activity.json")
        let payload = """
        {"version":1,"schema_version":1,"emitted_at":10,"active":[],"completed":[]}
        """
        try Data(payload.utf8).write(to: real)
        let link = root.appendingPathComponent("activity-link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(SessionActivityFileReader.load(link), .corrupt)

        let oversized = root.appendingPathComponent("activity-oversized.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: nil))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: SessionActivityFileReader.maximumBytes + 1)
        try handle.close()
        XCTAssertEqual(SessionActivityFileReader.load(oversized), .corrupt)
    }

    func testSessionActivityTargetReaderAcceptsMatchingOwnerFileAndRejectsSymlink() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let activityURL = root.appendingPathComponent("activity-v1.json")
        let id = String(repeating: "a", count: 24)
        let item = try SessionActivityItem(
            id: id,
            state: .running,
            event: .userPromptSubmit,
            eventAt: 10,
            terminal: false
        )
        let snapshot = try SessionActivitySnapshot(emittedAt: 11, active: [item])
        let targetURL = root.appendingPathComponent("activity-targets-v1.json")
        let payload = #"{"version":1,"schema_version":1,"emitted_at":11,"targets":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","thread_id":"thread-1"}]}"#
        try Data(payload.utf8).write(to: targetURL)
        XCTAssertEqual(
            SessionActivityFileReader.loadTargets(for: activityURL, activity: snapshot),
            [id: "thread-1"]
        )

        let realURL = root.appendingPathComponent("targets-real.json")
        try FileManager.default.moveItem(at: targetURL, to: realURL)
        try FileManager.default.createSymbolicLink(at: targetURL, withDestinationURL: realURL)
        XCTAssertTrue(
            SessionActivityFileReader.loadTargets(for: activityURL, activity: snapshot).isEmpty
        )
    }

    func testSessionActivityTitleReaderAcceptsMatchingOwnerFileAndRejectsSymlink() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let activityURL = root.appendingPathComponent("activity-v1.json")
        let id = String(repeating: "a", count: 24)
        let item = try SessionActivityItem(
            id: id,
            state: .running,
            event: .userPromptSubmit,
            eventAt: 10,
            terminal: false
        )
        let snapshot = try SessionActivitySnapshot(emittedAt: 11, active: [item])
        let titleURL = root.appendingPathComponent("activity-titles-v1.json")
        let payload = #"{"version":1,"schema_version":1,"emitted_at":11,"titles":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","title":"Repair tool execution"}]}"#
        try Data(payload.utf8).write(to: titleURL)
        XCTAssertEqual(
            SessionActivityFileReader.loadTitles(for: activityURL, activity: snapshot),
            [id: "Repair tool execution"]
        )

        let realURL = root.appendingPathComponent("titles-real.json")
        try FileManager.default.moveItem(at: titleURL, to: realURL)
        try FileManager.default.createSymbolicLink(at: titleURL, withDestinationURL: realURL)
        XCTAssertTrue(
            SessionActivityFileReader.loadTitles(for: activityURL, activity: snapshot).isEmpty
        )
    }

    func testSessionActivityTargetReaderDegradesInvalidTargetsWithoutRejectingActivity() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let activityURL = root.appendingPathComponent("activity-v1.json")
        let activityPayload = #"{"version":1,"schema_version":1,"emitted_at":11,"active":[],"completed":[]}"#
        try Data(activityPayload.utf8).write(to: activityURL)
        guard case let .snapshot(snapshot) = SessionActivityFileReader.load(activityURL) else {
            return XCTFail("valid activity did not load")
        }

        XCTAssertTrue(
            SessionActivityFileReader.loadTargets(for: activityURL, activity: snapshot).isEmpty
        )
        try Data("not json".utf8).write(
            to: root.appendingPathComponent("activity-targets-v1.json")
        )
        XCTAssertTrue(
            SessionActivityFileReader.loadTargets(for: activityURL, activity: snapshot).isEmpty
        )
        XCTAssertEqual(SessionActivityFileReader.load(activityURL), .snapshot(snapshot))
    }

    func testInvalidTitleSidecarDoesNotBreakTargetsOrActivity() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let activityURL = root.appendingPathComponent("activity-v1.json")
        let id = String(repeating: "a", count: 24)
        let activityPayload = #"{"version":1,"schema_version":1,"emitted_at":11,"active":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","state":"running","event":"UserPromptSubmit","event_at":10,"started_at":10,"completed_at":null,"category":"codex","terminal":false}],"completed":[]}"#
        let targetPayload = #"{"version":1,"schema_version":1,"emitted_at":11,"targets":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","thread_id":"thread-1"}]}"#
        try Data(activityPayload.utf8).write(to: activityURL)
        try Data(targetPayload.utf8).write(
            to: root.appendingPathComponent("activity-targets-v1.json")
        )
        try Data("not json".utf8).write(
            to: root.appendingPathComponent("activity-titles-v1.json")
        )
        guard case let .snapshot(snapshot) = SessionActivityFileReader.load(activityURL) else {
            return XCTFail("valid activity did not load")
        }

        XCTAssertEqual(
            SessionActivityFileReader.loadTargets(for: activityURL, activity: snapshot),
            [id: "thread-1"]
        )
        XCTAssertTrue(
            SessionActivityFileReader.loadTitles(for: activityURL, activity: snapshot).isEmpty
        )
        XCTAssertEqual(SessionActivityFileReader.load(activityURL), .snapshot(snapshot))
    }

    func testSessionActivityReaderRejectsSymlinkedContainingDirectory() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let activity = target.appendingPathComponent("activity.json")
        try Data(#"{"version":1,"schema_version":1,"emitted_at":10,"active":[],"completed":[]}"#.utf8).write(to: activity)
        let linked = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)

        XCTAssertEqual(
            SessionActivityFileReader.load(linked.appendingPathComponent("activity.json")),
            .corrupt
        )
        XCTAssertEqual(try Data(contentsOf: activity), Data(#"{"version":1,"schema_version":1,"emitted_at":10,"active":[],"completed":[]}"#.utf8))
    }

    func testSessionActivityReaderParentSwapUsesValidatedDirectoryDescriptor() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: false)
        let activity = sessions.appendingPathComponent("activity.json")
        let valid = #"{"version":1,"schema_version":1,"emitted_at":10,"active":[],"completed":[]}"#
        try Data(valid.utf8).write(to: activity)
        let oldSessions = root.appendingPathComponent("old-sessions", isDirectory: true)

        let result = SessionActivityFileReader.load(activity) {
            try! FileManager.default.moveItem(at: sessions, to: oldSessions)
            try! FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: false)
            try! Data("keep".utf8).write(to: sessions.appendingPathComponent("activity.json"))
        }

        guard case let .snapshot(snapshot) = result else {
            return XCTFail("validated directory snapshot was not read")
        }
        XCTAssertEqual(snapshot.emittedAt, 10)
        XCTAssertEqual(
            try Data(contentsOf: sessions.appendingPathComponent("activity.json")),
            Data("keep".utf8)
        )
    }

    func testLifecycleReaderOnlyDeliversNewestGeneration() {
        let firstStarted = expectation(description: "first started")
        let releaseFirst = DispatchSemaphore(value: 0)
        let newestDelivered = expectation(description: "newest delivered")
        let state = LockedState()
        let reader = LifecycleStateFileReader { _ in
            if state.nextCall() == 1 {
                firstStarted.fulfill()
                releaseFirst.wait()
                return .missing
            }
            return .corrupt
        }
        reader.read(URL(fileURLWithPath: "/tmp/one")) { state.append($0) }
        wait(for: [firstStarted], timeout: 1)
        reader.read(URL(fileURLWithPath: "/tmp/two")) {
            state.append($0)
            newestDelivered.fulfill()
        }
        releaseFirst.signal()
        wait(for: [newestDelivered], timeout: 1)
        XCTAssertEqual(state.snapshot, [.corrupt])
    }

    func testClickThroughRollsRuntimeBackWhenSaveFails() {
        enum Failure: Error { case forced }
        var runtimeValues: [Bool] = []
        XCTAssertThrowsError(
            try ClickThroughPersistenceTransaction.apply(
                current: false,
                updateRuntime: { runtimeValues.append($0) },
                persist: { _ in throw Failure.forced }
            )
        )
        XCTAssertEqual(runtimeValues, [true, false])
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-storage-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
