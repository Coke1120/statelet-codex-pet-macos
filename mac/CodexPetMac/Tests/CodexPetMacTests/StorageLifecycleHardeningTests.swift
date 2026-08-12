import AppKit
import CodexPetCore
import XCTest
@testable import CodexPetMac

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
