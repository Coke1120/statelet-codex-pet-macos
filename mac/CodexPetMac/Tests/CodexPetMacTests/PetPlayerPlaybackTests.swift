import AVFoundation
import AppKit
import CodexPetCore
import CoreVideo
import CryptoKit
import XCTest
@testable import Statelet

final class PetPlayerPlaybackIntegrationTests: XCTestCase {
    private enum TestFailure: Error {
        case assetWriter(String)
        case timedOut(String)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["STATELET_RUN_AVPLAYER_INTEGRATION"] == "1" else {
            throw XCTSkip(
                "AVPlayer integration tests require a logged-in, GUI-capable Mac; "
                    + "set STATELET_RUN_AVPLAYER_INTEGRATION=1 to opt in"
            )
        }
    }

    @MainActor
    func testLifecycleTransitionRetainsOutgoingThenPrerollsAndPromotesDestination() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-transition-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movieURL = directory.appendingPathComponent("transition.mov")
        try Self.writeTestMovie(to: movieURL)

        let view = PetPlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let controller = PetPlayerController(view: view)
        let entry = try MediaEntry(path: movieURL.lastPathComponent)
        XCTAssertEqual(
            controller.show(
                state: .idle,
                entry: entry,
                url: movieURL,
                posterURL: nil,
                transitionID: 43,
                startedAt: DispatchTime.now().uptimeNanoseconds
            ),
            .preparing
        )
        try Self.waitUntil("outgoing presentation did not become ready") {
            controller.currentURL == movieURL
        }
        let outgoingPlayer = try XCTUnwrap(view.playerLayer.player)
        var endedIDs: [UInt64] = []
        controller.onLifecycleTransitionEnded = { endedIDs.append($0) }

        XCTAssertEqual(
            controller.showLifecycleTransition(
                sourceState: .idle,
                destinationState: .running,
                transitionEntry: entry,
                transitionURL: movieURL,
                transitionAttestation: try Self.testTransitionAttestation(for: movieURL),
                destinationEntry: entry,
                destinationURL: movieURL,
                transitionID: 44,
                startedAt: DispatchTime.now().uptimeNanoseconds
            ),
            .preparing
        )
        XCTAssertTrue(view.playerLayer.player === outgoingPlayer)
        XCTAssertTrue(view.destinationPlayerLayer.player is AVQueuePlayer)
        XCTAssertNotNil(view.lifecycleTransitionPlayerLayer.player)
        XCTAssertTrue(view.destinationPlayerLayer.isHidden)
        XCTAssertTrue(view.lifecycleTransitionPlayerLayer.isHidden)
        XCTAssertLessThan(view.playerLayer.zPosition, view.destinationPlayerLayer.zPosition)
        XCTAssertLessThan(
            view.destinationPlayerLayer.zPosition,
            view.lifecycleTransitionPlayerLayer.zPosition
        )

        try Self.waitUntil("transition foreground never became visible") {
            !view.lifecycleTransitionPlayerLayer.isHidden
        }
        XCTAssertTrue(view.playerLayer.player === outgoingPlayer)
        try Self.waitUntil("destination did not begin underneath transition") {
            !view.destinationPlayerLayer.isHidden
                && (view.destinationPlayerLayer.player?.currentTime().seconds ?? 0) > 0
        }
        XCTAssertFalse(view.lifecycleTransitionPlayerLayer.isHidden)
        try Self.waitUntil("transition did not end exactly once") {
            endedIDs == [44]
        }
        Self.pumpMainRunLoop(for: 0.15)
        XCTAssertEqual(endedIDs, [44])
        XCTAssertFalse(view.playerLayer.isHidden)
        XCTAssertNil(view.lifecycleTransitionPlayerLayer.player)
        XCTAssertTrue(view.destinationPlayerLayer.isHidden)
        XCTAssertFalse(view.playerLayer.player === outgoingPlayer)
        XCTAssertEqual(controller.currentState, .running)
        XCTAssertEqual(controller.currentURL, movieURL)
        XCTAssertNotNil(view.playerLayer.superlayer)
        XCTAssertEqual(view.playerLayer.zPosition, 0)
        XCTAssertEqual(view.destinationPlayerLayer.zPosition, 1)
        XCTAssertEqual(view.lifecycleTransitionPlayerLayer.zPosition, 2)
        controller.clearTransientPresentation()
    }

    @MainActor
    func testNewPresentationSuppressesStaleTransitionCompletion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-transition-cancel-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movieURL = directory.appendingPathComponent("transition.mov")
        try Self.writeTestMovie(to: movieURL)

        let view = PetPlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let controller = PetPlayerController(view: view)
        let entry = try MediaEntry(path: movieURL.lastPathComponent)
        _ = controller.show(
            state: .idle,
            entry: entry,
            url: movieURL,
            posterURL: nil,
            transitionID: 50,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
        try Self.waitUntil("outgoing presentation did not become ready") {
            controller.currentURL == movieURL
        }
        let outgoingPlayer = view.playerLayer.player
        var endedIDs: [UInt64] = []
        controller.onLifecycleTransitionEnded = { endedIDs.append($0) }
        let attestation = try Self.testTransitionAttestation(for: movieURL)
        var mutatedMovie = try Data(contentsOf: movieURL)
        mutatedMovie.append(0x00)
        try mutatedMovie.write(to: movieURL, options: [.atomic])
        _ = controller.showLifecycleTransition(
            sourceState: .idle,
            destinationState: .running,
            transitionEntry: entry,
            transitionURL: movieURL,
            transitionAttestation: attestation,
            destinationEntry: entry,
            destinationURL: movieURL,
            transitionID: 51,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
        _ = controller.show(
            state: .review,
            entry: entry,
            url: movieURL,
            posterURL: nil,
            transitionID: 52,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
        Self.pumpMainRunLoop(for: 1.3)
        XCTAssertTrue(endedIDs.isEmpty)
        XCTAssertTrue(view.lifecycleTransitionPlayerLayer.isHidden)
        XCTAssertNil(view.lifecycleTransitionPlayerLayer.player)
        XCTAssertFalse(view.playerLayer.player === outgoingPlayer)
        controller.clearTransientPresentation()
    }

    @MainActor
    func testLifecycleTransitionCancellationRetainsOutgoingWithoutBlanking() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-transition-retain-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movieURL = directory.appendingPathComponent("transition.mov")
        try Self.writeTestMovie(to: movieURL)
        let view = PetPlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let controller = PetPlayerController(view: view)
        let entry = try MediaEntry(path: movieURL.lastPathComponent)
        _ = controller.show(
            state: .idle,
            entry: entry,
            url: movieURL,
            posterURL: nil,
            transitionID: 60,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
        try Self.waitUntil("outgoing presentation did not become ready") {
            controller.currentURL == movieURL
        }
        let outgoingPlayer = view.playerLayer.player
        _ = controller.showLifecycleTransition(
            sourceState: .idle,
            destinationState: .running,
            transitionEntry: entry,
            transitionURL: movieURL,
            transitionAttestation: try Self.testTransitionAttestation(for: movieURL),
            destinationEntry: entry,
            destinationURL: movieURL,
            transitionID: 61,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
        controller.cancelLifecycleTransition()

        XCTAssertTrue(view.playerLayer.player === outgoingPlayer)
        XCTAssertFalse(view.playerLayer.isHidden)
        XCTAssertNil(view.destinationPlayerLayer.player)
        XCTAssertNil(view.lifecycleTransitionPlayerLayer.player)
        XCTAssertEqual(controller.currentURL, movieURL)
        controller.clearTransientPresentation()
    }

    @MainActor
    func testReduceMotionBypassesLayeredLifecycleVideoWithoutClearingPoster() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-transition-reduce-motion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movieURL = directory.appendingPathComponent("unreadable.mov")
        try Data("not a playable movie".utf8).write(to: movieURL)
        let reportURL = directory.appendingPathComponent("transition.report.json")
        try Data("{}".utf8).write(to: reportURL)
        let view = PetPlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let controller = PetPlayerController(view: view)
        controller.setReduceMotion(true)
        let entry = try MediaEntry(path: movieURL.lastPathComponent)

        XCTAssertEqual(
            controller.showLifecycleTransition(
                sourceState: .idle,
                destinationState: .running,
                transitionEntry: entry,
                transitionURL: movieURL,
                transitionAttestation: CharacterTransitionRuntimeAttestation(
                    movieRevision: try XCTUnwrap(LocalFileRevision(url: movieURL)),
                    reportRevision: try XCTUnwrap(LocalFileRevision(url: reportURL)),
                    movieSHA256: "",
                    reportSHA256: ""
                ),
                destinationEntry: entry,
                destinationURL: movieURL,
                transitionID: 70,
                startedAt: DispatchTime.now().uptimeNanoseconds
            ),
            .failed
        )
        XCTAssertNil(view.destinationPlayerLayer.player)
        XCTAssertNil(view.lifecycleTransitionPlayerLayer.player)
    }

    @MainActor
    func testDirectReplacementRetainsVisibleBaseUntilStandbyIsReady() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-direct-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movieURL = directory.appendingPathComponent("movie.mov")
        try Self.writeTestMovie(to: movieURL)
        let view = PetPlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let controller = PetPlayerController(view: view)
        let entry = try MediaEntry(path: movieURL.lastPathComponent)
        _ = controller.show(
            state: .idle,
            entry: entry,
            url: movieURL,
            posterURL: nil,
            transitionID: 71,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
        try Self.waitUntil("initial direct presentation did not become ready") {
            controller.currentURL == movieURL
        }
        let outgoingPlayer = view.playerLayer.player
        _ = controller.show(
            state: .running,
            entry: entry,
            url: movieURL,
            posterURL: nil,
            transitionID: 72,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
        XCTAssertTrue(view.playerLayer.player === outgoingPlayer)
        XCTAssertFalse(view.playerLayer.isHidden)
        XCTAssertTrue(view.destinationPlayerLayer.isHidden)
        let standbyPlayer = try XCTUnwrap(view.destinationPlayerLayer.player)
        XCTAssertEqual(standbyPlayer.rate, 0, "hidden standby playback must not start before promotion")
        try Self.waitUntil("direct replacement was not atomically promoted") {
            controller.currentState == .running
                && view.playerLayer.player === standbyPlayer
                && standbyPlayer.rate > 0
        }
        XCTAssertGreaterThan(standbyPlayer.rate, 0)
        XCTAssertNil(view.destinationPlayerLayer.player)
    }

    @MainActor
    func testReduceMotionWithoutPosterRetainsExistingPresentation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-reduce-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movieURL = directory.appendingPathComponent("movie.mov")
        try Self.writeTestMovie(to: movieURL)
        let view = PetPlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let controller = PetPlayerController(view: view)
        let entry = try MediaEntry(path: movieURL.lastPathComponent)
        _ = controller.show(
            state: .idle,
            entry: entry,
            url: movieURL,
            posterURL: nil,
            transitionID: 73,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
        try Self.waitUntil("initial presentation did not become ready") {
            controller.currentURL == movieURL
        }
        let player = view.playerLayer.player
        controller.setReduceMotion(true)
        XCTAssertEqual(
            controller.show(
                state: .running,
                entry: entry,
                url: movieURL,
                posterURL: nil,
                transitionID: 74,
                startedAt: DispatchTime.now().uptimeNanoseconds
            ),
            .failed
        )
        XCTAssertTrue(view.playerLayer.player === player)
        XCTAssertFalse(view.playerLayer.isHidden)
        XCTAssertEqual(controller.currentState, .idle)
    }

    @MainActor
    func testRapidLifecycleHandoffCancelsObsoleteLayersBeforePreparingNewestDestination() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-transition-rapid-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movieURL = directory.appendingPathComponent("transition.mov")
        try Self.writeTestMovie(to: movieURL)
        let view = PetPlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let controller = PetPlayerController(view: view)
        let entry = try MediaEntry(path: movieURL.lastPathComponent)
        _ = controller.show(
            state: .idle,
            entry: entry,
            url: movieURL,
            posterURL: nil,
            transitionID: 80,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
        try Self.waitUntil("outgoing presentation did not become ready") {
            controller.currentURL == movieURL
        }
        var endedIDs: [UInt64] = []
        controller.onLifecycleTransitionEnded = { endedIDs.append($0) }
        _ = controller.showLifecycleTransition(
            sourceState: .idle,
            destinationState: .running,
            transitionEntry: entry,
            transitionURL: movieURL,
            transitionAttestation: try Self.testTransitionAttestation(for: movieURL),
            destinationEntry: entry,
            destinationURL: movieURL,
            transitionID: 81,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
        let obsoleteDestinationPlayer = view.destinationPlayerLayer.player
        let obsoleteTransitionPlayer = view.lifecycleTransitionPlayerLayer.player

        _ = controller.showLifecycleTransition(
            sourceState: .idle,
            destinationState: .review,
            transitionEntry: entry,
            transitionURL: movieURL,
            transitionAttestation: try Self.testTransitionAttestation(for: movieURL),
            destinationEntry: entry,
            destinationURL: movieURL,
            transitionID: 82,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )

        XCTAssertFalse(view.destinationPlayerLayer.player === obsoleteDestinationPlayer)
        XCTAssertFalse(view.lifecycleTransitionPlayerLayer.player === obsoleteTransitionPlayer)
        XCTAssertTrue(endedIDs.isEmpty)
        controller.cancelLifecycleTransition()
        Self.pumpMainRunLoop(for: 1.3)
        XCTAssertTrue(endedIDs.isEmpty)
        XCTAssertNil(view.destinationPlayerLayer.player)
        XCTAssertNil(view.lifecycleTransitionPlayerLayer.player)
        XCTAssertFalse(view.playerLayer.isHidden)
        controller.clearTransientPresentation()
    }

    @MainActor
    func testLifecycleHandoffCancelsPendingDirectReplacementBeforeReusingStandbyLayer() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-transition-pending-direct-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movieURL = directory.appendingPathComponent("transition.mov")
        try Self.writeTestMovie(to: movieURL)
        let view = PetPlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let controller = PetPlayerController(view: view)
        let entry = try MediaEntry(path: movieURL.lastPathComponent)
        _ = controller.show(
            state: .idle,
            entry: entry,
            url: movieURL,
            posterURL: nil,
            transitionID: 83,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
        try Self.waitUntil("outgoing presentation did not become ready") {
            controller.currentURL == movieURL
        }
        let outgoing = view.playerLayer.player
        _ = controller.show(
            state: .running,
            entry: entry,
            url: movieURL,
            posterURL: nil,
            transitionID: 84,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
        let obsoleteDirectPlayer = view.destinationPlayerLayer.player

        _ = controller.showLifecycleTransition(
            sourceState: .idle,
            destinationState: .review,
            transitionEntry: entry,
            transitionURL: movieURL,
            transitionAttestation: try Self.testTransitionAttestation(for: movieURL),
            destinationEntry: entry,
            destinationURL: movieURL,
            transitionID: 85,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )

        XCTAssertTrue(view.playerLayer.player === outgoing)
        XCTAssertFalse(view.destinationPlayerLayer.player === obsoleteDirectPlayer)
        try Self.waitUntil("new lifecycle handoff did not commit") {
            controller.currentState == .review
        }
        Self.pumpMainRunLoop(for: 0.15)
        XCTAssertEqual(controller.currentState, .review)
        XCTAssertNil(view.destinationPlayerLayer.player)
        XCTAssertNil(view.lifecycleTransitionPlayerLayer.player)
        XCTAssertFalse(view.playerLayer.isHidden)
        controller.clearTransientPresentation()
    }

    @MainActor
    func testSuspensionCancelsLifecycleReadinessDeadlineUntilResume() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-transition-suspend-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movieURL = directory.appendingPathComponent("transition.mov")
        try Self.writeTestMovie(to: movieURL)
        let view = PetPlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let controller = PetPlayerController(view: view)
        let entry = try MediaEntry(path: movieURL.lastPathComponent)
        var endedIDs: [UInt64] = []
        var failedIDs: [UInt64] = []
        controller.onLifecycleTransitionEnded = { endedIDs.append($0) }
        controller.onLifecycleTransitionFailed = { failedIDs.append($0) }
        _ = controller.show(
            state: .idle,
            entry: entry,
            url: movieURL,
            posterURL: nil,
            transitionID: 90,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
        try Self.waitUntil("outgoing presentation did not become ready") {
            controller.currentURL == movieURL
        }
        controller.setSuspended(true, for: .windowOccluded)
        _ = controller.showLifecycleTransition(
            sourceState: .idle,
            destinationState: .running,
            transitionEntry: entry,
            transitionURL: movieURL,
            transitionAttestation: try Self.testTransitionAttestation(for: movieURL),
            destinationEntry: entry,
            destinationURL: movieURL,
            transitionID: 91,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
        XCTAssertFalse(controller.hasPendingLifecycleReadinessTimeoutForTesting)
        Self.pumpMainRunLoop(for: 4.1)
        XCTAssertNotNil(view.playerLayer.player)
        XCTAssertFalse(view.playerLayer.isHidden)
        XCTAssertTrue(view.destinationPlayerLayer.isHidden)
        XCTAssertTrue(view.lifecycleTransitionPlayerLayer.isHidden)
        XCTAssertTrue(endedIDs.isEmpty)
        XCTAssertTrue(failedIDs.isEmpty)
        XCTAssertFalse(controller.hasPendingLifecyclePlaybackStallTimeoutForTesting)

        controller.setSuspended(false, for: .windowOccluded)
        try Self.waitUntil("resumed handoff did not commit its destination") {
            endedIDs == [91] && controller.currentState == .running
        }
        XCTAssertTrue(failedIDs.isEmpty)
        XCTAssertFalse(view.playerLayer.isHidden)
        XCTAssertNil(view.destinationPlayerLayer.player)
        XCTAssertNil(view.lifecycleTransitionPlayerLayer.player)
        controller.clearTransientPresentation()
    }

    @MainActor
    func testInitialDirectPresentationPreparedWhileSuspendedCommitsAfterResume() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-initial-suspended-direct-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movieURL = directory.appendingPathComponent("movie.mov")
        try Self.writeTestMovie(to: movieURL)
        let view = PetPlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let controller = PetPlayerController(view: view)
        let entry = try MediaEntry(path: movieURL.lastPathComponent)
        controller.setSuspended(true, for: .windowOccluded)
        _ = controller.show(
            state: .idle,
            entry: entry,
            url: movieURL,
            posterURL: nil,
            transitionID: 96,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
        Self.pumpMainRunLoop(for: 0.15)
        XCTAssertNil(controller.currentURL)
        XCTAssertTrue(view.destinationPlayerLayer.isHidden)

        controller.setSuspended(false, for: .windowOccluded)
        try Self.waitUntil("initial suspended presentation did not commit after resume") {
            controller.currentURL == movieURL && controller.currentState == .idle
        }
        XCTAssertFalse(view.playerLayer.isHidden)
        XCTAssertNil(view.destinationPlayerLayer.player)
        controller.clearTransientPresentation()
    }

    @MainActor
    func testLifecycleReadinessTimeoutRetainsOutgoingWhenNeitherOverlayIsVisible() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-transition-timeout-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movieURL = directory.appendingPathComponent("transition.mov")
        try Self.writeTestMovie(to: movieURL)
        let view = PetPlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let controller = PetPlayerController(view: view)
        let entry = try MediaEntry(path: movieURL.lastPathComponent)
        _ = controller.show(
            state: .idle,
            entry: entry,
            url: movieURL,
            posterURL: nil,
            transitionID: 92,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
        try Self.waitUntil("outgoing presentation did not become ready") {
            controller.currentURL == movieURL
        }
        let outgoing = view.playerLayer.player
        var failedIDs: [UInt64] = []
        var endedIDs: [UInt64] = []
        controller.onLifecycleTransitionEnded = { endedIDs.append($0) }
        controller.onLifecycleTransitionFailed = { failedIDs.append($0) }
        _ = controller.showLifecycleTransition(
            sourceState: .idle,
            destinationState: .running,
            transitionEntry: entry,
            transitionURL: movieURL,
            transitionAttestation: try Self.testTransitionAttestation(for: movieURL),
            destinationEntry: entry,
            destinationURL: movieURL,
            transitionID: 93,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
        controller.fireLifecycleReadinessTimeoutForTesting(transitionID: 93)

        XCTAssertEqual(failedIDs, [93])
        XCTAssertTrue(endedIDs.isEmpty)
        XCTAssertTrue(view.playerLayer.player === outgoing)
        XCTAssertFalse(view.playerLayer.isHidden)
        XCTAssertNil(view.destinationPlayerLayer.player)
        XCTAssertNil(view.lifecycleTransitionPlayerLayer.player)
        controller.clearTransientPresentation()
    }

    @MainActor
    func testLifecyclePlaybackStallReportsFailureAndRetainsOutgoingWithoutBlanking() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-transition-stall-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movieURL = directory.appendingPathComponent("transition.mov")
        try Self.writeTestMovie(to: movieURL)
        let view = PetPlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let controller = PetPlayerController(view: view)
        let entry = try MediaEntry(path: movieURL.lastPathComponent)
        _ = controller.show(
            state: .idle,
            entry: entry,
            url: movieURL,
            posterURL: nil,
            transitionID: 94,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
        try Self.waitUntil("outgoing presentation did not become ready") {
            controller.currentURL == movieURL
        }
        let outgoing = view.playerLayer.player
        var endedIDs: [UInt64] = []
        var failedIDs: [UInt64] = []
        controller.onLifecycleTransitionEnded = { endedIDs.append($0) }
        controller.onLifecycleTransitionFailed = { failedIDs.append($0) }
        _ = controller.showLifecycleTransition(
            sourceState: .idle,
            destinationState: .running,
            transitionEntry: entry,
            transitionURL: movieURL,
            transitionAttestation: try Self.testTransitionAttestation(for: movieURL),
            destinationEntry: entry,
            destinationURL: movieURL,
            transitionID: 95,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
        try Self.waitUntil("transition foreground did not become visible") {
            !view.lifecycleTransitionPlayerLayer.isHidden
                && controller.hasPendingLifecyclePlaybackStallTimeoutForTesting
        }
        view.lifecycleTransitionPlayerLayer.player?.pause()
        Self.pumpMainRunLoop(for: 0.05)
        controller.fireLifecyclePlaybackStallTimeoutForTesting(transitionID: 95)

        XCTAssertEqual(failedIDs, [95])
        XCTAssertTrue(endedIDs.isEmpty)
        XCTAssertEqual(controller.currentState, .idle)
        XCTAssertEqual(controller.currentURL, movieURL)
        XCTAssertTrue(view.playerLayer.player === outgoing)
        XCTAssertFalse(view.playerLayer.isHidden)
        XCTAssertNil(view.destinationPlayerLayer.player)
        XCTAssertNil(view.lifecycleTransitionPlayerLayer.player)
        controller.clearTransientPresentation()
    }

    @MainActor
    func testLoopingMovieStartsAfterAVPlayerLooperPopulatesQueue() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-looper-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movieURL = directory.appendingPathComponent("multi-frame.mov", isDirectory: false)
        try Self.writeTestMovie(to: movieURL)

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

        try Self.waitUntil("AVPlayerLooper did not populate the queue") {
            guard let player = view.playerLayer.player as? AVQueuePlayer else {
                return false
            }
            return controller.currentURL == movieURL && player.currentItem != nil
        }
        let player = try XCTUnwrap(view.playerLayer.player as? AVQueuePlayer)
        let initialTime = player.currentTime().seconds
        try Self.waitUntil("looping playback did not start advancing") {
            player.rate > 0
                && player.currentTime().seconds.isFinite
                && player.currentTime().seconds > initialTime + 0.03
        }

        XCTAssertGreaterThan(player.rate, 0)
        XCTAssertGreaterThan(player.currentTime().seconds, initialTime)
        controller.clearTransientPresentation()
    }

    @MainActor
    private static func writeTestMovie(to url: URL) throws {
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
            try waitUntil("asset writer input did not become ready") {
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
        var didFinishWriting = false
        writer.finishWriting {
            didFinishWriting = true
        }
        try waitUntil("asset writer did not finish writing") {
            didFinishWriting
        }
        guard writer.status == .completed else {
            throw TestFailure.assetWriter(writer.error?.localizedDescription ?? "finishWriting failed")
        }
    }

    private static func testTransitionAttestation(
        for movieURL: URL
    ) throws -> CharacterTransitionRuntimeAttestation {
        let reportURL = movieURL.deletingPathExtension().appendingPathExtension("report.json")
        if !FileManager.default.fileExists(atPath: reportURL.path) {
            try Data("test transition attestation".utf8).write(to: reportURL)
        }
        return CharacterTransitionRuntimeAttestation(
            movieRevision: try XCTUnwrap(LocalFileRevision(url: movieURL)),
            reportRevision: try XCTUnwrap(LocalFileRevision(url: reportURL)),
            movieSHA256: SHA256.hash(data: try Data(contentsOf: movieURL))
                .map { String(format: "%02x", $0) }
                .joined(),
            reportSHA256: SHA256.hash(data: try Data(contentsOf: reportURL))
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }

    @MainActor
    private static func waitUntil(
        _ timeoutMessage: String,
        timeout: TimeInterval = 5,
        condition: @escaping () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                throw TestFailure.timedOut(timeoutMessage)
            }
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        }
    }

    @MainActor
    private static func pumpMainRunLoop(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        }
    }
}
