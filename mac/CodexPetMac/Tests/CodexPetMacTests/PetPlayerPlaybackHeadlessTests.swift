import AppKit
import CodexPetCore
import XCTest
@testable import Statelet

final class PetPlayerPlaybackHeadlessTests: XCTestCase {
    func testConversionRecoveryRoutePolicyAcceptsOnlyCharacterScopedSameStateRoutes() {
        XCTAssertTrue(ConversionRecoveryRoutePolicy.accepts(
            state: PetState.running.rawValue,
            transitionFrom: PetState.idle.rawValue,
            transitionTo: PetState.running.rawValue,
            transitionScope: .global
        ))
        XCTAssertTrue(ConversionRecoveryRoutePolicy.accepts(
            state: PetState.running.rawValue,
            transitionFrom: PetState.running.rawValue,
            transitionTo: PetState.running.rawValue,
            transitionScope: .character
        ))
        XCTAssertFalse(ConversionRecoveryRoutePolicy.accepts(
            state: PetState.running.rawValue,
            transitionFrom: PetState.running.rawValue,
            transitionTo: PetState.running.rawValue,
            transitionScope: .global
        ))
        XCTAssertFalse(ConversionRecoveryRoutePolicy.accepts(
            state: PetState.running.rawValue,
            transitionFrom: PetState.running.rawValue,
            transitionTo: PetState.running.rawValue,
            transitionScope: nil
        ))
        XCTAssertFalse(ConversionRecoveryRoutePolicy.accepts(
            state: PetState.idle.rawValue,
            transitionFrom: PetState.running.rawValue,
            transitionTo: PetState.running.rawValue,
            transitionScope: .character
        ))
    }

    func testInStateTransitionPolicyOnlyAllowsAutomaticContinuousClipEnd() {
        XCTAssertTrue(InStateTransitionPolicy.shouldTrigger(
            trigger: .playlistRotation,
            reduceMotion: false,
            continuousRotation: true,
            temporaryPreviewActive: false
        ))
        for trigger in [
            LifecyclePresentationTrigger.authoritativeChange,
            .initialPresentation, .sameStateHeartbeat, .forcedRefresh,
            .nextClip, .playOnce, .temporaryState,
        ] {
            XCTAssertFalse(InStateTransitionPolicy.shouldTrigger(
                trigger: trigger,
                reduceMotion: false,
                continuousRotation: true,
                temporaryPreviewActive: false
            ))
        }
        XCTAssertFalse(InStateTransitionPolicy.shouldTrigger(
            trigger: .playlistRotation,
            reduceMotion: true,
            continuousRotation: true,
            temporaryPreviewActive: false
        ))
        XCTAssertFalse(InStateTransitionPolicy.shouldTrigger(
            trigger: .playlistRotation,
            reduceMotion: false,
            continuousRotation: false,
            temporaryPreviewActive: false
        ))
        XCTAssertFalse(InStateTransitionPolicy.shouldTrigger(
            trigger: .playlistRotation,
            reduceMotion: false,
            continuousRotation: true,
            temporaryPreviewActive: true
        ))
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

    func testTransitionSourceDurationRemainsCompatibleWhileVisibleTimeIsBounded() {
        XCTAssertEqual(LifecycleTransitionMediaPolicy.maximumDuration, 4)
        XCTAssertEqual(LifecycleTransitionMediaPolicy.maximumPresentationDuration, 1.5)
        XCTAssertEqual(
            LifecycleTransitionMediaPolicy.presentationPlaybackRate(
                sourceDuration: 4,
                requestedRate: 0.5
            ),
            4 / 1.5,
            accuracy: 0.0001
        )
    }

    func testSlowTransitionCueUsesMediaTimeScaledByPlaybackRate() {
        let sourceDuration = 4.0
        let playbackRate = LifecycleTransitionMediaPolicy.presentationPlaybackRate(
            sourceDuration: sourceDuration,
            requestedRate: 0.5
        )
        let visibleDuration = sourceDuration / playbackRate
        let cueWallTime = LayeredLifecycleHandoffPolicy.destinationPrerollTime(
            duration: visibleDuration
        )
        let cueMediaTime = cueWallTime * playbackRate

        XCTAssertEqual(cueWallTime, 1.15, accuracy: 0.001)
        XCTAssertEqual(cueMediaTime, 3.0667, accuracy: 0.001)
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

    @MainActor
    func testTerminationShutdownDetachesBasePlaybackSurface() {
        let view = PetPlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        let controller = PetPlayerController(view: view)

        XCTAssertNotNil(view.playerLayer.player)
        XCTAssertTrue(controller.shutdownForTermination())
        XCTAssertTrue(controller.isQuiescentForTerminationForTesting)
        XCTAssertNil(view.playerLayer.player)
        XCTAssertNil(view.destinationPlayerLayer.player)
        XCTAssertNil(view.lifecycleTransitionPlayerLayer.player)
        XCTAssertTrue(controller.shutdownForTermination(), "shutdown must remain idempotent")
    }
}
