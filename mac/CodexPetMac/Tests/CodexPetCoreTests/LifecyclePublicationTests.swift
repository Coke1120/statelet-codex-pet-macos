import XCTest
@testable import CodexPetCore

final class LifecyclePublicationTests: XCTestCase {
    func testInvalidInitialPublicationDoesNotPoisonLaterValidRevision() throws {
        for emittedAt in [849.0, 1_061.0] {
            let invalid = try snapshot(.waiting, at: emittedAt, revision: 50)
            let rejected = evaluate(invalid, at: 1_000)
            XCTAssertEqual(
                rejected.action,
                .rejectFreshness(emittedAt < 1_000 ? .stale : .futureSkew)
            )
            XCTAssertNil(rejected.acceptedSnapshot)
            XCTAssertNil(rejected.temporaryPreview.realState)

            let valid = try snapshot(.running, at: 1_000, revision: 2)
            let accepted = evaluate(valid, after: rejected, at: 1_000)
            XCTAssertEqual(accepted.action, .accept)
            XCTAssertEqual(accepted.acceptedSnapshot, valid)
            XCTAssertEqual(accepted.temporaryPreview.realState, .running)
        }
    }

    func testIdenticalPublicationRecoversAfterMissingOrCorruptFallbackWithoutAdvancingRevision() throws {
        // Missing/corrupt readers retain the accepted snapshot while the app
        // falls back to idle. The next readable copy may have the same revision.
        let publication = try snapshot(.running, at: 1_000, revision: 7)
        let accepted = evaluate(publication, at: 1_000)
        let recovered = evaluate(
            publication, after: accepted, at: 1_030,
            publisherIsLive: false, currentState: .idle
        )
        XCTAssertEqual(recovered.action, .recover)
        XCTAssertEqual(recovered.acceptedSnapshot, accepted.acceptedSnapshot)
        XCTAssertEqual(recovered.temporaryPreview.realState, .running)
        XCTAssertNil(recovered.relinquishedPreview)

        let subsequentRead = evaluate(
            publication, after: recovered, at: 1_060,
            publisherIsLive: true, currentState: .running
        )
        XCTAssertEqual(subsequentRead.action, .unchanged)
        XCTAssertEqual(subsequentRead.acceptedSnapshot?.publicationRevision, 7)
    }

    func testLegacyDuplicateRecoveryUsesTheSameFreshnessBoundary() throws {
        let publication = try snapshot(.review, at: 1_000, revision: nil)
        let accepted = evaluate(publication, at: 1_000)
        let boundary = evaluate(publication, after: accepted, at: 1_150)
        XCTAssertEqual(boundary.action, .recover)
        XCTAssertEqual(boundary.acceptedSnapshot, publication)

        let expired = evaluate(publication, after: boundary, at: 1_150.001)
        XCTAssertEqual(expired.action, .rejectFreshness(.stale))
        XCTAssertEqual(expired.acceptedSnapshot, publication)
    }

    func testExpiredDuplicateCannotRevivePublisherOrReplaceRollbackBarrier() throws {
        let publication = try snapshot(.waiting, at: 1_000, revision: 8)
        let accepted = evaluate(publication, at: 1_000)
        let stale = evaluate(publication, after: accepted, at: 1_151)
        XCTAssertEqual(stale.action, .rejectFreshness(.stale))
        XCTAssertEqual(stale.acceptedSnapshot, publication)

        let lower = try snapshot(.running, at: 1_152, revision: 7)
        let rejected = evaluate(lower, after: stale, at: 1_152)
        XCTAssertEqual(rejected.action, .rejectOrder(.rejectLowerRevision, acceptedFreshness: .stale))
        XCTAssertEqual(rejected.acceptedSnapshot, publication)

        let newer = try snapshot(.review, at: 1_153, revision: 9)
        let recovered = evaluate(newer, after: rejected, at: 1_153)
        XCTAssertEqual(recovered.action, .accept)
        XCTAssertEqual(recovered.acceptedSnapshot, newer)
        XCTAssertEqual(recovered.temporaryPreview.realState, .review)
    }

    func testRepeatedFreshRollbackCannotKeepAnExpiredAcceptedStateLive() throws {
        let publication = try snapshot(.running, at: 1_000, revision: 9)
        var previous = evaluate(publication, at: 1_000)
        for now in [1_030.0, 1_090.0, 1_150.0, 1_151.0, 1_300.0] {
            let lower = try snapshot(.waiting, at: now, revision: 8)
            previous = evaluate(
                lower, after: previous, at: now,
                publisherIsLive: true, currentState: .running
            )
            XCTAssertEqual(
                previous.action,
                .rejectOrder(.rejectLowerRevision, acceptedFreshness: now <= 1_150 ? .fresh : .stale)
            )
            XCTAssertEqual(previous.acceptedSnapshot, publication)
            XCTAssertEqual(previous.temporaryPreview.realState, .running)
        }
    }

    func testConflictingOrRevisionlessInputCannotRenewAcceptedLiveness() throws {
        let publication = try snapshot(.running, at: 1_000, revision: 9)
        let accepted = evaluate(publication, at: 1_000)
        let inputs: [(CurrentState, StatePublicationOrderDecision)] = [
            (try snapshot(.review, at: 1_151, revision: 9), .rejectEqualRevisionConflict),
            (try snapshot(.review, at: 1_151, revision: nil), .rejectRevisionlessRollback),
        ]
        for (incoming, reason) in inputs {
            let rejected = evaluate(incoming, after: accepted, at: 1_151)
            XCTAssertEqual(rejected.action, .rejectOrder(reason, acceptedFreshness: .stale))
            XCTAssertEqual(rejected.acceptedSnapshot, publication)
        }
    }

    func testRejectedOldInputDoesNotPrematurelyExpireFreshAcceptedState() throws {
        let publication = try snapshot(.running, at: 1_000, revision: 9)
        let accepted = evaluate(publication, at: 1_000)
        let old = try snapshot(.waiting, at: 500, revision: 8)
        let rejected = evaluate(old, after: accepted, at: 1_020, publisherIsLive: true, currentState: .running)
        XCTAssertEqual(rejected.action, .rejectOrder(.rejectLowerRevision, acceptedFreshness: .fresh))
        XCTAssertEqual(rejected.acceptedSnapshot, publication)
    }

    func testFutureDatedNewerRevisionCannotBlockLaterValidPublication() throws {
        let original = try snapshot(.running, at: 1_000, revision: 9)
        let accepted = evaluate(original, at: 1_000)
        let invalid = try snapshot(.waiting, at: 2_000, revision: 100)
        let rejected = evaluate(invalid, after: accepted, at: 1_001)
        XCTAssertEqual(rejected.action, .rejectFreshness(.futureSkew))
        XCTAssertEqual(rejected.acceptedSnapshot, original)

        let valid = try snapshot(.review, at: 1_002, revision: 10)
        let recovered = evaluate(valid, after: rejected, at: 1_002)
        XCTAssertEqual(recovered.action, .accept)
        XCTAssertEqual(recovered.acceptedSnapshot, valid)
    }

    func testDuplicateAndMetadataHeartbeatPreserveManualPreviewAndPlaybackSelection() throws {
        let publication = try snapshot(.running, at: 1_000, revision: 9)
        var preview = TemporaryStatePreviewPolicy()
        preview.begin(previewState: .waiting, baselineRealState: .running)
        let duplicate = LifecyclePublicationPolicy.evaluate(
            lastAccepted: publication, incoming: publication, now: 1_020,
            publisherIsLive: true, currentState: .running, temporaryPreview: preview
        )
        XCTAssertEqual(duplicate.action, .unchanged)
        XCTAssertEqual(duplicate.temporaryPreview, preview)
        XCTAssertNil(duplicate.relinquishedPreview)

        let metadata = try CurrentState(
            state: .running, activeSessions: 2, emittedAt: 1_030,
            publicationRevision: 10, latestEvent: "PostToolUse", latestEventAt: 1_030
        )
        let heartbeat = evaluate(metadata, after: duplicate, at: 1_030, publisherIsLive: true, currentState: .running)
        XCTAssertEqual(heartbeat.action, .accept)
        XCTAssertEqual(heartbeat.acceptedSnapshot?.activeSessions, 2)
        XCTAssertEqual(heartbeat.temporaryPreview, preview)
        XCTAssertNil(heartbeat.relinquishedPreview)
        XCTAssertEqual(
            StatePresentationDecision.decide(lastPresentedState: .waiting, incomingState: heartbeat.temporaryPreview.presentedState!),
            .unchanged
        )
    }

    func testAuthoritativeChangeRelinquishesPreviewEvenWhenItMatchesThePreviewValue() throws {
        let original = try snapshot(.running, at: 1_000, revision: 9)
        var preview = TemporaryStatePreviewPolicy()
        preview.begin(previewState: .waiting, baselineRealState: .running)
        let waiting = try snapshot(.waiting, at: 1_001, revision: 10)
        let changed = LifecyclePublicationPolicy.evaluate(
            lastAccepted: original, incoming: waiting, now: 1_001,
            publisherIsLive: true, currentState: .running, temporaryPreview: preview
        )
        XCTAssertEqual(changed.action, .accept)
        XCTAssertEqual(changed.relinquishedPreview, .waiting)
        XCTAssertNil(changed.temporaryPreview.previewState)
        XCTAssertEqual(changed.temporaryPreview.realState, .waiting)
        XCTAssertEqual(changed.acceptedSnapshot, waiting)
    }

    func testRejectedInputCannotCancelManualPreviewOrChangeItsBaseline() throws {
        let original = try snapshot(.running, at: 1_000, revision: 9)
        var preview = TemporaryStatePreviewPolicy()
        preview.begin(previewState: .waiting, baselineRealState: .running)
        let inputs = [
            try snapshot(.review, at: 1_000, revision: 8),
            try snapshot(.review, at: 500, revision: 10),
            try snapshot(.review, at: 2_000, revision: 10),
        ]
        for incoming in inputs {
            let rejected = LifecyclePublicationPolicy.evaluate(
                lastAccepted: original, incoming: incoming, now: 1_001,
                publisherIsLive: true, currentState: .running, temporaryPreview: preview
            )
            XCTAssertEqual(rejected.acceptedSnapshot, original)
            XCTAssertEqual(rejected.temporaryPreview, preview)
            XCTAssertNil(rejected.relinquishedPreview)
        }
    }

    func testRecoveryPreservesBaselinePreviewButRelinquishesOneWithoutABaseline() throws {
        let publication = try snapshot(.running, at: 1_000, revision: 9)
        for baseline: PetState? in [.running, nil] {
            var preview = TemporaryStatePreviewPolicy()
            preview.begin(previewState: .waiting, baselineRealState: baseline)
            let recovered = LifecyclePublicationPolicy.evaluate(
                lastAccepted: publication, incoming: publication, now: 1_010,
                publisherIsLive: false, currentState: .idle, temporaryPreview: preview
            )
            XCTAssertEqual(recovered.action, .recover)
            XCTAssertEqual(recovered.acceptedSnapshot, publication)
            XCTAssertEqual(recovered.temporaryPreview.realState, .running)
            XCTAssertEqual(recovered.temporaryPreview.previewState, baseline == nil ? nil : .waiting)
            XCTAssertEqual(recovered.relinquishedPreview, baseline == nil ? .waiting : nil)
        }
    }

    private func snapshot(_ state: PetState, at time: TimeInterval, revision: Int?) throws -> CurrentState {
        try CurrentState(state: state, emittedAt: time, publicationRevision: revision)
    }

    private func evaluate(
        _ incoming: CurrentState,
        after previous: LifecyclePublicationUpdate? = nil,
        at now: TimeInterval,
        publisherIsLive: Bool = false,
        currentState: PetState = .idle
    ) -> LifecyclePublicationUpdate {
        LifecyclePublicationPolicy.evaluate(
            lastAccepted: previous?.acceptedSnapshot,
            incoming: incoming,
            now: now,
            publisherIsLive: publisherIsLive,
            currentState: currentState,
            temporaryPreview: previous?.temporaryPreview ?? TemporaryStatePreviewPolicy()
        )
    }
}
