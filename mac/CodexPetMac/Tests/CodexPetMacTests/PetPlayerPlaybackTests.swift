import AVFoundation
import AppKit
import CodexPetCore
import CoreVideo
import XCTest
@testable import CodexPetMac

final class PetPlayerPlaybackTests: XCTestCase {
    private enum TestFailure: Error {
        case assetWriter(String)
        case timedOut(String)
    }

    func testResumeIntentSurvivesUntilLooperProvidesCurrentItem() {
        var deferred = DeferredPlaybackResume()

        XCTAssertNil(deferred.prepare(rate: 0.75, currentItemAvailable: false))
        XCTAssertEqual(deferred.rate, 0.75)
        XCTAssertEqual(deferred.consumeWhenCurrentItemBecomesAvailable(), 0.75)
        XCTAssertNil(deferred.rate)
    }

    func testSuspensionCancelsDeferredResumeIntent() {
        var deferred = DeferredPlaybackResume()

        XCTAssertNil(deferred.prepare(rate: 1.25, currentItemAvailable: false))
        deferred.cancel()

        XCTAssertNil(deferred.consumeWhenCurrentItemBecomesAvailable())
    }

    @MainActor
    func testLoopingMovieStartsAfterAVPlayerLooperPopulatesQueue() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-looper-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movieURL = directory.appendingPathComponent("multi-frame.mov", isDirectory: false)
        try await Self.writeTestMovie(to: movieURL)

        let view = PetPlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let controller = PetPlayerController(view: view)
        let entry = try MediaEntry(path: movieURL.lastPathComponent, loop: true)
        let disposition = controller.show(
            state: .idle,
            entry: entry,
            url: movieURL,
            posterURL: nil,
            transitionID: 1,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
        XCTAssertEqual(disposition, .preparing)

        let player = try XCTUnwrap(view.playerLayer.player as? AVQueuePlayer)
        try await Self.waitUntil("AVPlayerLooper did not populate the queue") {
            player.currentItem != nil
        }
        let initialTime = player.currentTime().seconds
        try await Self.waitUntil("looping playback did not start advancing") {
            player.rate > 0
                && player.currentTime().seconds.isFinite
                && player.currentTime().seconds > initialTime + 0.03
        }

        XCTAssertGreaterThan(player.rate, 0)
        XCTAssertGreaterThan(player.currentTime().seconds, initialTime)
        controller.clearTransientPresentation()
    }

    @MainActor
    func testDialogueMessageTrimsTextAndHidesForBlankInput() throws {
        let view = PetPlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))

        view.showDialogueMessage("  Hello from Statelet  \n")
        view.layoutSubtreeIfNeeded()
        let bubble = try XCTUnwrap(
            view.subviews.first { $0.accessibilityLabel() == "Statelet message" }
        )
        XCTAssertFalse(bubble.isHidden)
        XCTAssertEqual(bubble.accessibilityValue() as? String, "Hello from Statelet")
        let quickControls = try XCTUnwrap(
            view.subviews.first { $0.accessibilityLabel() == "Pet quick controls" }
        )
        XCTAssertFalse(bubble.frame.intersects(quickControls.frame))

        view.showDialogueMessage(" \n\t ")
        XCTAssertTrue(bubble.isHidden)
        XCTAssertNil(bubble.accessibilityValue())
    }

    private static func writeTestMovie(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let width = 32
        let height = 32
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else {
            throw TestFailure.assetWriter("video input is unsupported")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw TestFailure.assetWriter(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        for frameIndex in 0..<30 {
            try await waitUntil("asset writer input did not become ready") {
                input.isReadyForMoreMediaData
            }
            var optionalBuffer: CVPixelBuffer?
            let result = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                nil,
                &optionalBuffer
            )
            guard result == kCVReturnSuccess, let buffer = optionalBuffer else {
                throw TestFailure.assetWriter("pixel buffer allocation failed: \(result)")
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
                baseAddress.assumingMemoryBound(to: UInt8.self).initialize(
                    repeating: UInt8((frameIndex * 7) % 255),
                    count: CVPixelBufferGetBytesPerRow(buffer) * height
                )
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(
                buffer,
                withPresentationTime: CMTime(value: Int64(frameIndex), timescale: 30)
            ) else {
                throw TestFailure.assetWriter(writer.error?.localizedDescription ?? "append failed")
            }
        }

        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw TestFailure.assetWriter(writer.error?.localizedDescription ?? "finishWriting failed")
        }
    }

    private static func waitUntil(
        _ timeoutMessage: String,
        timeout: Duration = .seconds(5),
        condition: @escaping () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                throw TestFailure.timedOut(timeoutMessage)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
