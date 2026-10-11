import Foundation
import XCTest
@testable import CodexPetCore

final class SessionTurnOutcomeTests: XCTestCase {
    private func item(_ index: Int, kind: SessionTurnOutcome = .unverified, at: Double = 99) throws -> SessionActivityItem {
        try SessionActivityItem(
            id: String(format: "%024x", index), state: .idle,
            event: kind == .blocked ? .stopFailure : kind == .interrupted ? .interrupt : .stop,
            eventAt: at, terminal: true, provider: kind == .blocked ? .grok : .codex,
            outcome: kind, outcomeID: String(format: "%024x", index + 1000)
        )
    }

    func testLegacySnapshotDecodesWithoutInventingSuccessfulTurn() throws {
        let json = #"{"version":1,"emitted_at":100,"completed":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","state":"idle","event":"SessionEnd","event_at":99,"terminal":true}]}"#
        let snapshot = try JSONDecoder.codexPet.decode(SessionActivitySnapshot.self, from: Data(json.utf8))
        XCTAssertTrue(snapshot.outcomes.isEmpty)
        XCTAssertEqual(snapshot.recentItems.first?.outcomeTitle, "Session closed")
        XCTAssertEqual(snapshot.recentItems.first?.acknowledgementID, String(repeating: "a", count: 24))
    }

    func testOutcomeRoundTripKeepsReceiptSeparateFromActivationID() throws {
        let interrupted = try item(1, kind: .interrupted)
        let snapshot = try SessionActivitySnapshot(emittedAt: 100, outcomes: [interrupted])
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder.codexPet.decode(SessionActivitySnapshot.self, from: data), snapshot)
        XCTAssertNotEqual(interrupted.acknowledgementID, interrupted.id)
        XCTAssertTrue(snapshot.completed.isEmpty)
        XCTAssertEqual(interrupted.outcomeTitle, "Interrupted")
        XCTAssertEqual(PetState.allCases.count, 4)
    }

    func testBlockedPriorityIsIndependentOfRecencyAndStopsStayUnverified() throws {
        let snapshot = try SessionActivitySnapshot(emittedAt: 100, outcomes: [
            item(1, at: 99), item(2, kind: .blocked, at: 90), item(3, kind: .interrupted, at: 95),
        ])
        XCTAssertEqual(snapshot.recentItems.map(\.outcome), [.blocked, .unverified, .interrupted])
        XCTAssertEqual(snapshot.recentItems[1].outcomeTitle, "Stopped · outcome unverified")
    }

    func testRejectsUnsupportedSuccessAndInconsistentOutcomeMetadata() throws {
        let data = try JSONEncoder().encode(item(1, kind: .blocked))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let mutations: [(String, Any?)] = [
            ("outcome", "ready"), ("outcome", "interrupted"), ("provider", "codex"),
            ("outcome_id", "private path"), ("outcome_id", nil), ("outcome", nil),
            ("event", "SessionEnd"), ("terminal", false), ("state", "running"),
        ]
        for (key, value) in mutations {
            var changed = original
            changed[key] = value
            XCTAssertThrowsError(try JSONDecoder.codexPet.decode(
                SessionActivityItem.self, from: JSONSerialization.data(withJSONObject: changed)
            ), key)
        }
    }

    func testOutcomeCannotEnterLegacyCompletedGroupOrDuplicateSession() throws {
        let outcome = try item(1)
        XCTAssertThrowsError(try SessionActivitySnapshot(emittedAt: 100, completed: [outcome]))
        let active = try SessionActivityItem(id: outcome.id, state: .running, event: .userPromptSubmit, eventAt: 99, terminal: false)
        XCTAssertThrowsError(try SessionActivitySnapshot(emittedAt: 100, active: [active], outcomes: [outcome]))
        let duplicateReceipt = try SessionActivityItem(id: String(repeating: "b", count: 24), state: .idle, event: .stop, eventAt: 99, terminal: true, outcome: .unverified, outcomeID: outcome.outcomeID)
        XCTAssertThrowsError(try SessionActivitySnapshot(emittedAt: 100, outcomes: [outcome, duplicateReceipt]))
        let closed = try SessionActivityItem(id: try XCTUnwrap(outcome.outcomeID), state: .idle, event: .sessionEnd, eventAt: 99, terminal: true)
        XCTAssertThrowsError(try SessionActivitySnapshot(emittedAt: 100, completed: [closed], outcomes: [outcome]))
    }

    func testSharedRecentBoundIncludesLegacyClosures() throws {
        let outcomes = try (0..<64).map { try item($0) }
        XCTAssertEqual(try SessionActivitySnapshot(emittedAt: 100, outcomes: outcomes).recentItems.count, 64)
        let closed = try SessionActivityItem(id: String(repeating: "f", count: 24), state: .idle, event: .sessionEnd, eventAt: 99, terminal: true)
        XCTAssertThrowsError(try SessionActivitySnapshot(emittedAt: 100, completed: [closed], outcomes: outcomes))
    }
}
