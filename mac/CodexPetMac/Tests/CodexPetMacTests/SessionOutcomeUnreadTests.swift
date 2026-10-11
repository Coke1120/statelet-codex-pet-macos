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
