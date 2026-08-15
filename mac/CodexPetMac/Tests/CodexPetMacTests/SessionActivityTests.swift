import AppKit
import CodexPetCore
import XCTest
@testable import Statelet

final class SessionActivityTests: XCTestCase {
    private func item(
        _ hex: String,
        state: PetState,
        event: CurrentStateHookEvent,
        terminal: Bool,
        eventAt: Double
    ) throws -> SessionActivityItem {
        try SessionActivityItem(
            id: String(repeating: hex, count: 24),
            state: state,
            event: event,
            eventAt: eventAt,
            terminal: terminal
        )
    }

    @MainActor
    func testPresentationFiltersAcknowledgementsAndBoundsRows() throws {
        let active = try [
            item("a", state: .waiting, event: .permissionRequest, terminal: false, eventAt: 1),
            item("b", state: .review, event: .preCompact, terminal: false, eventAt: 2),
            item("c", state: .running, event: .userPromptSubmit, terminal: false, eventAt: 3),
            item("d", state: .running, event: .postToolUse, terminal: false, eventAt: 4),
        ]
        let completed = try [
            item("e", state: .idle, event: .sessionEnd, terminal: true, eventAt: 5),
            item("f", state: .idle, event: .stop, terminal: true, eventAt: 6),
        ]
        let snapshot = try SessionActivitySnapshot(
            emittedAt: 10,
            active: active,
            completed: completed
        )

        let display = SessionActivityPresentation.displayState(
            snapshot: snapshot,
            acknowledgedIDs: [String(repeating: "e", count: 24)],
            compact: false,
            maximumRowsPerGroup: 3
        )
        XCTAssertEqual(display.active.count, 3)
        XCTAssertEqual(display.hiddenActiveCount, 1)
        XCTAssertEqual(display.completed.map(\.id), [String(repeating: "f", count: 24)])
        XCTAssertEqual(display.hiddenCompletedCount, 0)
    }

    @MainActor
    func testViewRendersUnreadActionAndCompactCounts() throws {
        let completed = try item(
            "a",
            state: .idle,
            event: .sessionEnd,
            terminal: true,
            eventAt: 90
        )
        let snapshot = try SessionActivitySnapshot(
            emittedAt: 100,
            completed: [completed]
        )
        let view = SessionActivityView(
            frame: NSRect(x: 0, y: 0, width: 230, height: 150),
            clock: { Date(timeIntervalSince1970: 100) }
        )
        var acknowledged: String?
        view.onAcknowledge = { acknowledged = $0 }
        view.update(snapshot: snapshot, acknowledgedIDs: [])
        view.layoutSubtreeIfNeeded()

        XCTAssertFalse(view.isHidden)
        XCTAssertEqual(view.renderedItemIDs, [completed.id])
        let button = allDescendants(of: view).compactMap { $0 as? NSButton }.first {
            $0.title == "Mark as read"
        }
        XCTAssertNotNil(button)
        button?.performClick(nil)
        XCTAssertEqual(acknowledged, completed.id)

        view.setCompactOverride(true)
        XCTAssertTrue(view.displayState.compact)
        XCTAssertEqual(view.displayState.hiddenCompletedCount, 1)
        XCTAssertTrue(view.renderedItemIDs.isEmpty)
        let pill = allDescendants(of: view).compactMap { $0 as? NSButton }.first {
            $0.title == "Completed · 1"
        }
        XCTAssertNotNil(pill)
        pill?.performClick(nil)
        XCTAssertFalse(view.displayState.compact)
    }

    @MainActor
    func testPanelAnchorsRightThenFallsBackLeftWithoutLeavingVisibleFrame() {
        let pet = NSRect(x: 600, y: 400, width: 160, height: 160)
        let visible = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let right = SessionActivityPanel.anchoredFrame(
            beside: pet,
            contentSize: NSSize(width: 200, height: 140),
            visibleFrame: visible
        )
        XCTAssertEqual(right.minX, 770)
        XCTAssertTrue(visible.contains(right))

        let edgePet = NSRect(x: 850, y: 400, width: 140, height: 160)
        let left = SessionActivityPanel.anchoredFrame(
            beside: edgePet,
            contentSize: NSSize(width: 200, height: 140),
            visibleFrame: visible
        )
        XCTAssertEqual(left.maxX, 840)
        XCTAssertTrue(visible.contains(left))
    }

    private func allDescendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allDescendants)
    }
}
