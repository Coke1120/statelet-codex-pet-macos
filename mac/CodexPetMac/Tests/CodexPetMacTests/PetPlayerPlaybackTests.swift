import AVFoundation
import AppKit
import CodexPetCore
import CoreVideo
import XCTest
@testable import Statelet

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

    func testLifecycleTransitionPolicyOnlyUsesCommittedStateForAuthoritativeChange() {
        XCTAssertEqual(
            LifecycleTransitionPolicy.trigger(
                previousLifecycleState: nil,
                incomingState: .running,
                forceRefresh: false
            ),
            .initialPresentation
        )
        XCTAssertEqual(
            LifecycleTransitionPolicy.trigger(
                previousLifecycleState: .running,
                incomingState: .running,
                forceRefresh: false
            ),
            .sameStateHeartbeat
        )
        XCTAssertEqual(
            LifecycleTransitionPolicy.trigger(
                previousLifecycleState: .idle,
                incomingState: .running,
                forceRefresh: false
            ),
            .authoritativeChange
        )
        XCTAssertEqual(
            LifecycleTransitionPolicy.trigger(
                previousLifecycleState: .idle,
                incomingState: .running,
                forceRefresh: true
            ),
            .forcedRefresh
        )
        XCTAssertEqual(
            LifecycleTransitionPolicy.source(
                lastCommittedState: .idle,
                incomingState: .running,
                trigger: .authoritativeChange,
                reduceMotion: false,
                hasConfiguredMedia: true
            ),
            .idle
        )

        for trigger in [
            LifecyclePresentationTrigger.initialPresentation,
            .sameStateHeartbeat,
            .forcedRefresh,
            .playlistRotation,
            .nextClip,
            .playOnce,
            .temporaryState,
        ] {
            XCTAssertNil(
                LifecycleTransitionPolicy.source(
                    lastCommittedState: .idle,
                    incomingState: .running,
                    trigger: trigger,
                    reduceMotion: false,
                    hasConfiguredMedia: true
                )
            )
        }
    }

    func testLifecycleTransitionPolicySkipsInitialSameStateMissingAndReduceMotion() {
        XCTAssertNil(LifecycleTransitionPolicy.source(
            lastCommittedState: nil,
            incomingState: .running,
            trigger: .authoritativeChange,
            reduceMotion: false,
            hasConfiguredMedia: true
        ))
        XCTAssertNil(LifecycleTransitionPolicy.source(
            lastCommittedState: .running,
            incomingState: .running,
            trigger: .authoritativeChange,
            reduceMotion: false,
            hasConfiguredMedia: true
        ))
        XCTAssertNil(LifecycleTransitionPolicy.source(
            lastCommittedState: .idle,
            incomingState: .running,
            trigger: .authoritativeChange,
            reduceMotion: false,
            hasConfiguredMedia: false
        ))
        XCTAssertNil(LifecycleTransitionPolicy.source(
            lastCommittedState: .idle,
            incomingState: .running,
            trigger: .authoritativeChange,
            reduceMotion: true,
            hasConfiguredMedia: true
        ))
    }

    func testTransitionSourceDurationRemainsFourSecondsWhilePlaybackRateControlsVisibleTime() {
        XCTAssertEqual(LifecycleTransitionMediaPolicy.maximumDuration, 4)
        XCTAssertEqual(4 / 0.5, 8)
    }

    func testSlowTransitionCueUsesMediaTimeScaledByPlaybackRate() {
        let sourceDuration = 4.0
        let playbackRate = 0.5
        let visibleDuration = sourceDuration / playbackRate
        let cueWallTime = LayeredLifecycleHandoffPolicy.destinationPrerollTime(
            duration: visibleDuration
        )
        let cueMediaTime = cueWallTime * playbackRate

        XCTAssertEqual(cueWallTime, 7.65, accuracy: 0.001)
        XCTAssertEqual(cueMediaTime, 3.825, accuracy: 0.001)
        XCTAssertLessThan(cueMediaTime, sourceDuration)
    }

    func testRapidLifecycleTransitionOnlyCommitsNewestAuthoritativeDestination() {
        XCTAssertEqual(
            LifecycleTransitionCompletionDecision.decide(
                callbackID: 10,
                currentSequence: 11,
                activeID: 11,
                activeDestination: .review,
                authoritativeState: .review,
                temporaryPreviewActive: false
            ),
            .ignore
        )
        XCTAssertEqual(
            LifecycleTransitionCompletionDecision.decide(
                callbackID: 11,
                currentSequence: 11,
                activeID: 11,
                activeDestination: .review,
                authoritativeState: .review,
                temporaryPreviewActive: false
            ),
            .commit(.review)
        )
        XCTAssertEqual(
            LifecycleTransitionCompletionDecision.decide(
                callbackID: 11,
                currentSequence: 11,
                activeID: 11,
                activeDestination: .review,
                authoritativeState: .running,
                temporaryPreviewActive: false
            ),
            .ignore
        )
        XCTAssertEqual(
            LifecycleTransitionCompletionDecision.decide(
                callbackID: 11,
                currentSequence: 11,
                activeID: 11,
                activeDestination: .review,
                authoritativeState: .review,
                temporaryPreviewActive: true
            ),
            .ignore
        )
    }

    func testRapidThreeStateTransitionIgnoresBothSupersededCallbacks() {
        for staleID in [UInt64(1), UInt64(2)] {
            XCTAssertEqual(
                LifecycleTransitionCompletionDecision.decide(
                    callbackID: staleID,
                    currentSequence: 3,
                    activeID: 3,
                    activeDestination: .review,
                    authoritativeState: .review,
                    temporaryPreviewActive: false
                ),
                .ignore
            )
        }

        XCTAssertEqual(
            LifecycleTransitionCompletionDecision.decide(
                callbackID: 3,
                currentSequence: 3,
                activeID: 3,
                activeDestination: .review,
                authoritativeState: .review,
                temporaryPreviewActive: false
            ),
            .commit(.review)
        )
    }

    @MainActor
    func testLifecycleTransitionRetainsOutgoingThenPrerollsAndPromotesDestination() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-transition-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movieURL = directory.appendingPathComponent("transition.mov")
        try await Self.writeTestMovie(to: movieURL)

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
        try await Self.waitUntil("outgoing presentation did not become ready") {
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

        try await Self.waitUntil("transition foreground never became visible") {
            !view.lifecycleTransitionPlayerLayer.isHidden
        }
        XCTAssertTrue(view.playerLayer.player === outgoingPlayer)
        try await Self.waitUntil("destination did not begin underneath transition") {
            !view.destinationPlayerLayer.isHidden
                && (view.destinationPlayerLayer.player?.currentTime().seconds ?? 0) > 0
        }
        XCTAssertFalse(view.lifecycleTransitionPlayerLayer.isHidden)
        try await Self.waitUntil("transition did not end exactly once") {
            endedIDs == [44]
        }
        try await Task.sleep(nanoseconds: 150_000_000)
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
    func testNewPresentationSuppressesStaleTransitionCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-transition-cancel-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movieURL = directory.appendingPathComponent("transition.mov")
        try await Self.writeTestMovie(to: movieURL)

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
        try await Self.waitUntil("outgoing presentation did not become ready") {
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
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertTrue(endedIDs.isEmpty)
        XCTAssertTrue(view.lifecycleTransitionPlayerLayer.isHidden)
        XCTAssertNil(view.lifecycleTransitionPlayerLayer.player)
        XCTAssertFalse(view.playerLayer.player === outgoingPlayer)
        controller.clearTransientPresentation()
    }

    @MainActor
    func testLifecycleTransitionCancellationRetainsOutgoingWithoutBlanking() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-transition-retain-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movieURL = directory.appendingPathComponent("transition.mov")
        try await Self.writeTestMovie(to: movieURL)
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
        try await Self.waitUntil("outgoing presentation did not become ready") {
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
                    movieRevision: LocalFileRevision(url: movieURL)!,
                    reportRevision: LocalFileRevision(url: movieURL)!
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
    func testDirectReplacementRetainsVisibleBaseUntilStandbyIsReady() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-direct-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movieURL = directory.appendingPathComponent("movie.mov")
        try await Self.writeTestMovie(to: movieURL)
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
        try await Self.waitUntil("initial direct presentation did not become ready") {
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
        try await Self.waitUntil("direct replacement was not atomically promoted") {
            controller.currentState == .running
                && view.playerLayer.player !== outgoingPlayer
        }
        XCTAssertNil(view.destinationPlayerLayer.player)
    }

    @MainActor
    func testReduceMotionWithoutPosterRetainsExistingPresentation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-reduce-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movieURL = directory.appendingPathComponent("movie.mov")
        try await Self.writeTestMovie(to: movieURL)
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
        try await Self.waitUntil("initial presentation did not become ready") {
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
    func testRapidLifecycleHandoffCancelsObsoleteLayersBeforePreparingNewestDestination() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-transition-rapid-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movieURL = directory.appendingPathComponent("transition.mov")
        try await Self.writeTestMovie(to: movieURL)
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
        try await Self.waitUntil("outgoing presentation did not become ready") {
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
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertTrue(endedIDs.isEmpty)
        XCTAssertNil(view.destinationPlayerLayer.player)
        XCTAssertNil(view.lifecycleTransitionPlayerLayer.player)
        XCTAssertFalse(view.playerLayer.isHidden)
        controller.clearTransientPresentation()
    }

    @MainActor
    func testLifecycleHandoffCancelsPendingDirectReplacementBeforeReusingStandbyLayer() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-transition-pending-direct-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movieURL = directory.appendingPathComponent("transition.mov")
        try await Self.writeTestMovie(to: movieURL)
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
        try await Self.waitUntil("outgoing presentation did not become ready") {
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
        try await Self.waitUntil("new lifecycle handoff did not commit") {
            controller.currentState == .review
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(controller.currentState, .review)
        XCTAssertNil(view.destinationPlayerLayer.player)
        XCTAssertNil(view.lifecycleTransitionPlayerLayer.player)
        XCTAssertFalse(view.playerLayer.isHidden)
        controller.clearTransientPresentation()
    }

    @MainActor
    func testSuspensionCancelsLifecycleReadinessDeadlineUntilResume() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-transition-suspend-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movieURL = directory.appendingPathComponent("transition.mov")
        try await Self.writeTestMovie(to: movieURL)
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
        try await Self.waitUntil("outgoing presentation did not become ready") {
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
        try await Task.sleep(nanoseconds: 4_100_000_000)
        XCTAssertNotNil(view.playerLayer.player)
        XCTAssertFalse(view.playerLayer.isHidden)
        XCTAssertTrue(view.destinationPlayerLayer.isHidden)
        XCTAssertTrue(view.lifecycleTransitionPlayerLayer.isHidden)
        XCTAssertTrue(endedIDs.isEmpty)
        XCTAssertTrue(failedIDs.isEmpty)
        XCTAssertFalse(controller.hasPendingLifecyclePlaybackStallTimeoutForTesting)

        controller.setSuspended(false, for: .windowOccluded)
        try await Self.waitUntil("resumed handoff did not commit its destination") {
            endedIDs == [91] && controller.currentState == .running
        }
        XCTAssertTrue(failedIDs.isEmpty)
        XCTAssertFalse(view.playerLayer.isHidden)
        XCTAssertNil(view.destinationPlayerLayer.player)
        XCTAssertNil(view.lifecycleTransitionPlayerLayer.player)
        controller.clearTransientPresentation()
    }

    @MainActor
    func testInitialDirectPresentationPreparedWhileSuspendedCommitsAfterResume() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-initial-suspended-direct-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movieURL = directory.appendingPathComponent("movie.mov")
        try await Self.writeTestMovie(to: movieURL)
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
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(controller.currentURL)
        XCTAssertTrue(view.destinationPlayerLayer.isHidden)

        controller.setSuspended(false, for: .windowOccluded)
        try await Self.waitUntil("initial suspended presentation did not commit after resume") {
            controller.currentURL == movieURL && controller.currentState == .idle
        }
        XCTAssertFalse(view.playerLayer.isHidden)
        XCTAssertNil(view.destinationPlayerLayer.player)
        controller.clearTransientPresentation()
    }

    @MainActor
    func testLifecycleReadinessTimeoutRetainsOutgoingWhenNeitherOverlayIsVisible() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-transition-timeout-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movieURL = directory.appendingPathComponent("transition.mov")
        try await Self.writeTestMovie(to: movieURL)
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
        try await Self.waitUntil("outgoing presentation did not become ready") {
            controller.currentURL == movieURL
        }
        let outgoing = view.playerLayer.player
        var failedIDs: [UInt64] = []
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
        XCTAssertTrue(view.playerLayer.player === outgoing)
        XCTAssertFalse(view.playerLayer.isHidden)
        XCTAssertNil(view.destinationPlayerLayer.player)
        XCTAssertNil(view.lifecycleTransitionPlayerLayer.player)
        controller.clearTransientPresentation()
    }

    @MainActor
    func testLifecyclePlaybackStallPromotesReadyDestinationWithoutBlanking() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-transition-stall-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movieURL = directory.appendingPathComponent("transition.mov")
        try await Self.writeTestMovie(to: movieURL)
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
        try await Self.waitUntil("outgoing presentation did not become ready") {
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
            transitionID: 95,
            startedAt: DispatchTime.now().uptimeNanoseconds
        )
        try await Self.waitUntil("transition foreground did not become visible") {
            !view.lifecycleTransitionPlayerLayer.isHidden
                && controller.hasPendingLifecyclePlaybackStallTimeoutForTesting
        }
        view.lifecycleTransitionPlayerLayer.player?.pause()
        try await Task.sleep(nanoseconds: 50_000_000)
        controller.fireLifecyclePlaybackStallTimeoutForTesting(transitionID: 95)

        try await Self.waitUntil("stall fallback did not promote destination") {
            endedIDs == [95] && controller.currentState == .running
        }
        XCTAssertFalse(view.playerLayer.isHidden)
        XCTAssertNil(view.destinationPlayerLayer.player)
        XCTAssertNil(view.lifecycleTransitionPlayerLayer.player)
        controller.clearTransientPresentation()
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

    @MainActor
    func testQuickControlsHaveLargeHitTargetsAndDispatchActionsInsidePetPanel() throws {
        let panel = PetPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            alwaysOnTop: false,
            fullScreenAuxiliary: false
        )
        let view = PetPlayerView(frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 320, height: 240))
        panel.contentView = view
        view.updateQuickControls(
            canAdvanceClip: true,
            liveState: .idle,
            displayedState: .idle,
            manualPreview: nil
        )
        view.layoutSubtreeIfNeeded()

        let controls = try XCTUnwrap(
            view.subviews.compactMap { $0 as? NSStackView }
                .first { $0.accessibilityLabel() == "Pet quick controls" }
        )
        let buttons = controls.arrangedSubviews.compactMap { $0 as? NSButton }
        let nextButton = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "Next clip for idle" })
        let stateButton = try XCTUnwrap(buttons.first { $0.accessibilityLabel()?.hasPrefix("Temporary State") == true })

        for button in [nextButton, stateButton] {
            XCTAssertGreaterThanOrEqual(button.frame.width, 40)
            XCTAssertGreaterThanOrEqual(button.frame.height, 40)
            XCTAssertFalse(button.showsBorderOnlyWhileMouseInside)

            let center = button.convert(
                NSPoint(x: button.bounds.midX, y: button.bounds.midY),
                to: view
            )
            XCTAssertTrue(view.hitTest(center) === button)
            let insideEdge = button.convert(
                NSPoint(x: button.bounds.maxX - 0.5, y: button.bounds.maxY - 0.5),
                to: view
            )
            XCTAssertTrue(view.hitTest(insideEdge) === button)
        }

        let orderedButtons = [nextButton, stateButton].sorted { $0.frame.minY < $1.frame.minY }
        let gapPoint = controls.convert(
            NSPoint(
                x: controls.bounds.midX,
                y: (orderedButtons[0].frame.maxY + orderedButtons[1].frame.minY) / 2
            ),
            to: view
        )
        XCTAssertFalse(view.hitTest(gapPoint) is NSButton)

        var advanceCount = 0
        view.onAdvanceClip = { advanceCount += 1 }
        nextButton.performClick(nil)
        XCTAssertEqual(advanceCount, 1)

        var selectedState: PetState?
        view.onTemporaryStateSelection = { selectedState = $0 }
        let menu = view.makeTemporaryStateMenu()
        let runningItem = try XCTUnwrap(menu.items.first { $0.representedObject as? String == PetState.running.rawValue })
        XCTAssertEqual(runningItem.action, #selector(PetPlayerView.selectTemporaryState(_:)))
        XCTAssertTrue(NSApplication.shared.sendAction(runningItem.action!, to: runningItem.target, from: runningItem))
        XCTAssertEqual(selectedState, .running)
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

    private static func testTransitionAttestation(
        for movieURL: URL
    ) throws -> CharacterTransitionRuntimeAttestation {
        let reportURL = movieURL.deletingPathExtension().appendingPathExtension("report.json")
        if !FileManager.default.fileExists(atPath: reportURL.path) {
            try Data("test transition attestation".utf8).write(to: reportURL)
        }
        return CharacterTransitionRuntimeAttestation(
            movieRevision: try XCTUnwrap(LocalFileRevision(url: movieURL)),
            reportRevision: try XCTUnwrap(LocalFileRevision(url: reportURL))
        )
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
