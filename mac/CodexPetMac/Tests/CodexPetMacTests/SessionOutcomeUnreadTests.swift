import AppKit
import CodexPetCore
import XCTest
@testable import Statelet

final class SessionOutcomeUnreadTests: XCTestCase {
    private func item(_ session: String = "a", receipt: String = "1", blocked: Bool = false) throws -> SessionActivityItem {
        try SessionActivityItem(
            id: String(repeating: session, count: 24), state: .idle,
            event: blocked ? .stopFailure : .interrupt, eventAt: 90, terminal: true,
            provider: blocked ? .grok : .codex, outcome: blocked ? .blocked : .interrupted,
            outcomeID: String(repeating: receipt, count: 24)
        )
    }

    func testSameSessionNextTurnIsUnreadEvenWithoutObservedRunningSnapshot() throws {
        let first = try item(receipt: "1")
        let next = try item(receipt: "2")
        let prior = try SessionActivitySnapshot(emittedAt: 100, outcomes: [first])
        let incoming = try SessionActivitySnapshot(emittedAt: 101, outcomes: [next])
        let history = SessionActivityApplicationPolicy.recordingAcknowledgement(first.acknowledgementID, in: [])
        let applied = SessionActivityApplicationPolicy.apply(incoming, lastAccepted: prior, currentlyDisplayed: prior, acknowledgementHistory: history, now: 101)
        XCTAssertEqual(applied.decision, .acceptNewer)
        XCTAssertEqual(SessionActivityPresentation.unacknowledgedCompletedItems(snapshot: applied.displayedSnapshot, acknowledgedIDs: applied.acknowledgedIDs), [next])
        XCTAssertTrue(SessionActivityPresentation.unacknowledgedCompletedItems(snapshot: prior, acknowledgedIDs: applied.acknowledgedIDs).isEmpty)
    }

    func testDuplicateRollbackAndOtherSessionsDoNotResetReadReceipt() throws {
        let first = try item()
        let other = try item("b", receipt: "2", blocked: true)
        let snapshot = try SessionActivitySnapshot(emittedAt: 100, outcomes: [first, other])
        let history = [first.acknowledgementID]
        for time in [100.0, 99.0] {
            let replay = try SessionActivitySnapshot(emittedAt: time, outcomes: [first, other])
            let applied = SessionActivityApplicationPolicy.apply(replay, lastAccepted: snapshot, currentlyDisplayed: snapshot, acknowledgementHistory: history, now: 101)
            XCTAssertFalse(applied.decision.shouldAccept)
            XCTAssertEqual(applied.acknowledgementHistory, history)
            XCTAssertEqual(SessionActivityPresentation.unacknowledgedCompletedItems(snapshot: applied.displayedSnapshot, acknowledgedIDs: applied.acknowledgedIDs), [other])
        }
    }

    func testActivationTargetsUseSessionIDInsteadOfReceipt() throws {
        let outcome = try item()
        let snapshot = try SessionActivitySnapshot(emittedAt: 100, outcomes: [outcome])
        let json = """
        {"version":1,"schema_version":1,"emitted_at":100,"targets":[{"id":"\(outcome.id)","thread_id":"synthetic-thread"}]}
        """
        let targets = try JSONDecoder.codexPet.decode(SessionActivityTargets.self, from: Data(json.utf8))
        XCTAssertEqual(targets.validated(for: snapshot), [outcome.id: "synthetic-thread"])
    }

    func testRepeatedReadsInOneSessionPreserveHiddenProvidersReadMarker() throws {
        let hidden = try item("b", receipt: "f", blocked: true)
        var state = SessionActivityAcknowledgementState().recording([hidden])
        var previous: SessionActivitySnapshot?
        var latest: SessionActivityItem?
        for turn in 0..<140 {
            let current = try SessionActivityItem(
                id: String(repeating: "a", count: 24), state: .idle, event: .stop,
                eventAt: 90, terminal: true, outcome: .unverified,
                outcomeID: String(format: "%024x", turn + 1000)
            )
            // The source-filtered snapshot contains no Grok item. Applying it
            // must not discard that provider's acknowledgement association.
            let snapshot = try SessionActivitySnapshot(emittedAt: 100 + Double(turn), outcomes: [current])
            let application = SessionActivityApplicationPolicy.apply(
                snapshot, lastAccepted: previous, currentlyDisplayed: previous,
                acknowledgementHistory: state.history, now: snapshot.emittedAt
            )
            state = state.retaining(application.acknowledgementHistory).recording([current])
            previous = application.lastAcceptedSnapshot
            latest = current
        }
        XCTAssertEqual(state.entries.count, 2)
        XCTAssertTrue(state.history.contains(hidden.acknowledgementID))
        let combined = try SessionActivitySnapshot(emittedAt: 250, outcomes: [hidden, XCTUnwrap(latest)])
        XCTAssertTrue(SessionActivityPresentation.unacknowledgedCompletedItems(snapshot: combined, acknowledgedIDs: Set(state.history)).isEmpty)

        let suite = "statelet-unread-regression-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        SessionActivityAcknowledgementStore.persistState(state, to: defaults)
        XCTAssertEqual(SessionActivityAcknowledgementStore.restoredState(from: defaults), state)
    }

    func testLegacyAcknowledgementMigratesAndNewReceiptReplacesItsSessionSlot() throws {
        let suite = "statelet-unread-migration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacyID = String(repeating: "a", count: 24)
        defaults.set([legacyID], forKey: SessionActivityAcknowledgementStore.defaultsKey)
        let migrated = SessionActivityAcknowledgementStore.restoredState(from: defaults)
        XCTAssertEqual(migrated.entries, [.init(sessionID: legacyID, receiptID: legacyID)])
        let newer = try item()
        let updated = migrated.recording([newer])
        XCTAssertEqual(updated.entries.count, 1)
        XCTAssertEqual(updated.history, [newer.acknowledgementID])
        let active = try SessionActivityItem(id: legacyID, state: .running, event: .userPromptSubmit, eventAt: 100, terminal: false)
        let application = SessionActivityApplicationPolicy.apply(
            try SessionActivitySnapshot(emittedAt: 100, active: [active]),
            lastAccepted: nil, currentlyDisplayed: nil, acknowledgementHistory: migrated.history, now: 100
        )
        XCTAssertTrue(migrated.retaining(application.acknowledgementHistory).entries.isEmpty)
    }

    func testMappedAcknowledgementsBoundDistinctSessionsAndBatchReplacement() throws {
        let items = try (0..<140).map { index in
            try SessionActivityItem(id: String(format: "%024x", index), state: .idle, event: .stop,
                                    eventAt: 90, terminal: true, outcome: .unverified,
                                    outcomeID: String(format: "%024x", index + 1000))
        }
        let bounded = SessionActivityAcknowledgementState().recording(items)
        XCTAssertEqual(bounded.entries.count, 128)
        XCTAssertEqual(bounded.entries.first?.sessionID, items[12].id)
        let last = try XCTUnwrap(items.last)
        let newer = try SessionActivityItem(id: last.id, state: .idle, event: .interrupt,
                                           eventAt: 91, terminal: true, outcome: .interrupted,
                                           outcomeID: String(repeating: "f", count: 24))
        let updated = bounded.recording([newer, newer])
        XCTAssertEqual(updated.entries.count, 128)
        XCTAssertEqual(updated.entries.last?.receiptID, newer.acknowledgementID)
        XCTAssertFalse(updated.history.contains(last.acknowledgementID))
    }

    func testInvalidMappedPreferencesFallBackToLegacyWithoutRawData() throws {
        let suite = "statelet-unread-invalid-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacyID = String(repeating: "a", count: 24)
        defaults.set([legacyID], forKey: SessionActivityAcknowledgementStore.defaultsKey)
        defaults.set(Data("not JSON /private/path".utf8), forKey: SessionActivityAcknowledgementStore.mappedDefaultsKey)
        XCTAssertEqual(SessionActivityAcknowledgementStore.restoredState(from: defaults).history, [legacyID])
        let invalid = SessionActivityAcknowledgementState(entries: [.init(sessionID: "/private/path", receiptID: legacyID)])
        XCTAssertTrue(invalid.entries.isEmpty)
    }

    @MainActor
    func testReadClearAndOpenActionsUseTheirOwnIdentifiers() throws {
        let interrupted = try item()
        let blocked = try item("b", receipt: "2", blocked: true)
        let closed = try SessionActivityItem(id: String(repeating: "c", count: 24), state: .idle, event: .sessionEnd, eventAt: 95, terminal: true)
        let snapshot = try SessionActivitySnapshot(emittedAt: 100, completed: [closed], outcomes: [interrupted, blocked])
        let view = SessionActivityView(frame: NSRect(x: 0, y: 0, width: 700, height: 400), clock: { Date(timeIntervalSince1970: 100) })
        var acknowledged: String?
        var opened: String?
        var cleared: [String] = []
        view.onAcknowledge = { acknowledged = $0 }
        view.onOpen = { opened = $0 }
        view.onAcknowledgeAllCompleted = { cleared = $0 }
        view.update(snapshot: snapshot, acknowledgedIDs: [], openableIDs: [interrupted.id])
        view.layoutSubtreeIfNeeded()
        let buttons = descendants(view).compactMap { $0 as? NSButton }
        try XCTUnwrap(buttons.first { $0.title == "Open in Codex" }).performClick(nil)
        XCTAssertEqual(opened, interrupted.id)
        XCTAssertNil(acknowledged)
        try XCTUnwrap(buttons.first { $0.title == "Mark as read" && $0.identifier?.rawValue == interrupted.acknowledgementID }).performClick(nil)
        XCTAssertEqual(acknowledged, interrupted.acknowledgementID)
        try XCTUnwrap(buttons.first { $0.title == "Clear all" }).performClick(nil)
        XCTAssertEqual(Set(cleared), [interrupted.acknowledgementID, blocked.acknowledgementID, closed.id])
        let history = SessionActivityApplicationPolicy.recordingAcknowledgements(cleared, in: [])
        XCTAssertTrue(SessionActivityPresentation.unacknowledgedCompletedItems(snapshot: snapshot, acknowledgedIDs: Set(history)).isEmpty)
        let labels = descendants(view).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains { $0.contains("Blocked") })
        XCTAssertTrue(labels.contains { $0.contains("Interrupted") })
        XCTAssertTrue(labels.contains { $0.contains("Session closed") })
        XCTAssertFalse(labels.contains { $0.contains("Completed") || $0.contains("Ready") })
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
