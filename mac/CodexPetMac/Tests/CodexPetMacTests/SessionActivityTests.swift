import AppKit
import CodexPetCore
import XCTest
@testable import Statelet

private final class ActivityReaderState: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private var delivered: [Double] = []

    func nextCall() -> Int {
        lock.withLock {
            callCount += 1
            return callCount
        }
    }

    func append(_ value: Double) {
        lock.withLock { delivered.append(value) }
    }

    var values: [Double] { lock.withLock { delivered } }
}

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
        let scrollContainer = SessionActivityScrollContainer(activityView: view)
        scrollContainer.frame = NSRect(x: 0, y: 0, width: 190, height: 44)
        scrollContainer.setScrollable(true)
        scrollContainer.layoutSubtreeIfNeeded()
        XCTAssertTrue(scrollContainer.hasVerticalScroller)
        XCTAssertEqual(view.renderedItemIDs, [completed.id])
        XCTAssertGreaterThan(view.frame.height, scrollContainer.contentSize.height)

        let accessibilityValues = allDescendants(of: view).compactMap {
            $0.accessibilityValue() as? String
        }
        XCTAssertFalse(accessibilityValues.contains { $0.contains("ago ago") })
    }

    @MainActor
    func testActivityRowsAreExplicitlyInformationalWhenActivationIsUnavailable() throws {
        let active = try item(
            "a",
            state: .running,
            event: .userPromptSubmit,
            terminal: false,
            eventAt: 90
        )
        let snapshot = try SessionActivitySnapshot(emittedAt: 100, active: [active])
        let view = SessionActivityView(
            frame: NSRect(x: 0, y: 0, width: 230, height: 150),
            clock: { Date(timeIntervalSince1970: 100) }
        )
        view.update(snapshot: snapshot, acknowledgedIDs: [])
        view.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            allDescendants(of: view).compactMap { $0 as? NSTextField }.contains {
                $0.stringValue.contains("activation is unavailable")
            }
        )
        let rowLabel = try XCTUnwrap(
            allDescendants(of: view).compactMap { $0 as? NSTextField }.first {
                $0.accessibilityLabel()?.contains("Active running") == true
            }
        )
        XCTAssertEqual(rowLabel.accessibilityRole(), .staticText)
        XCTAssertEqual(rowLabel.accessibilityLabel(), "Active running session 1")
    }

    @MainActor
    func testPanelAppearanceAndPositionStoresRejectInvalidValuesAndRoundTrip() throws {
        let suiteName = "statelet-session-activity-(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let appearance = try SessionActivityPanelAppearance(
            backgroundColor: "#aBc123",
            opacity: 0.41,
            automaticContrast: false
        )
        SessionActivityPanelAppearanceStore.persist(appearance, to: defaults)
        XCTAssertEqual(SessionActivityPanelAppearanceStore.restored(from: defaults), appearance)
        defaults.set(Data("{\"opacity\":99}".utf8), forKey: SessionActivityPanelAppearanceStore.defaultsKey)
        XCTAssertEqual(
            SessionActivityPanelAppearanceStore.restored(from: defaults),
            try SessionActivityPanelAppearance()
        )

        let origin = NSPoint(x: 240, y: 180)
        SessionActivityPanelPositionStore.persist(origin, to: defaults)
        XCTAssertEqual(SessionActivityPanelPositionStore.restored(from: defaults), origin)
        defaults.set(["x": "bad", "y": 10], forKey: SessionActivityPanelPositionStore.defaultsKey)
        XCTAssertNil(SessionActivityPanelPositionStore.restored(from: defaults))

        let clamped = SessionActivityPanelPositionStore.clamped(
            origin: NSPoint(x: -500, y: 1_000),
            size: NSSize(width: 230, height: 150),
            to: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        XCTAssertTrue(
            NSRect(origin: clamped, size: NSSize(width: 230, height: 150))
                .intersection(NSRect(x: 0, y: 0, width: 800, height: 600)).width >= 48
        )
    }

    @MainActor
    func testCustomActivityBackgroundResolvesReadableForeground() throws {
        let appearance = try SessionActivityPanelAppearance(
            backgroundColor: "#FFFFFF",
            opacity: 0.4,
            automaticContrast: false
        )
        let resolved = SessionActivityView.resolveAppearance(
            appearance: appearance,
            systemBackgroundColor: .white,
            systemTextColor: .white,
            secondaryTextColor: .white,
            reduceTransparency: false,
            increaseContrast: false
        )

        XCTAssertEqual(resolved.backgroundColor.codexPetHex, "#FFFFFF")
        XCTAssertEqual(resolved.primaryTextColor.codexPetHex, "#000000")
        XCTAssertEqual(resolved.secondaryTextColor.codexPetHex, "#000000")
        XCTAssertGreaterThanOrEqual(resolved.contrastRatio, 4.5)

        let increased = SessionActivityView.resolveAppearance(
            appearance: try SessionActivityPanelAppearance(
                backgroundColor: "#777777",
                opacity: 0.2,
                automaticContrast: false
            ),
            systemBackgroundColor: .white,
            systemTextColor: .white,
            secondaryTextColor: .white,
            reduceTransparency: false,
            increaseContrast: true
        )
        XCTAssertGreaterThanOrEqual(increased.contrastRatio, 7)
        XCTAssertGreaterThanOrEqual(increased.opacity, 0.96)
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

    @MainActor
    func testLayoutPolicyUsesCompactModeForActualSideSpaceAndExpandsOnRequest() {
        let visible = NSRect(x: 0, y: 0, width: 400, height: 300)
        let pet = NSRect(x: 150, y: 80, width: 100, height: 140)
        let automatic = SessionActivityLayoutPolicy.layout(
            beside: pet,
            expandedSize: NSSize(width: 230, height: 150),
            compactSize: NSSize(width: 100, height: 60),
            visibleFrame: visible,
            forceExpanded: false
        )
        XCTAssertTrue(automatic.compact)
        XCTAssertTrue(automatic.available)
        XCTAssertTrue(visible.contains(automatic.frame))
        XCTAssertFalse(automatic.frame.intersects(pet))

        let expanded = SessionActivityLayoutPolicy.layout(
            beside: pet,
            expandedSize: NSSize(width: 230, height: 150),
            compactSize: NSSize(width: 100, height: 60),
            visibleFrame: visible,
            forceExpanded: true
        )
        XCTAssertFalse(expanded.compact)
        XCTAssertTrue(expanded.scrollable)
        XCTAssertTrue(visible.contains(expanded.frame))
        XCTAssertFalse(expanded.frame.intersects(pet))

        let oversized = SessionActivityPanel.anchoredFrame(
            beside: pet,
            contentSize: NSSize(width: 800, height: 600),
            visibleFrame: visible
        )
        XCTAssertTrue(visible.contains(oversized))
        XCTAssertFalse(oversized.intersects(pet))
    }

    @MainActor
    func testProductionSizeCompactAndForcedExpandedLayoutsNeverOverlapPet() {
        let visible = NSRect(x: 0, y: 0, width: 600, height: 400)
        let pet = NSRect(x: 185, y: 120, width: 230, height: 150)
        let automatic = SessionActivityLayoutPolicy.layout(
            beside: pet,
            expandedSize: NSSize(width: 230, height: 150),
            compactSize: NSSize(width: 190, height: 68),
            visibleFrame: visible,
            forceExpanded: false
        )
        XCTAssertTrue(automatic.compact)
        XCTAssertFalse(automatic.scrollable)
        XCTAssertTrue(visible.contains(automatic.frame))
        XCTAssertFalse(automatic.frame.intersects(pet))
        XCTAssertEqual(automatic.frame.size, NSSize(width: 190, height: 68))

        let forced = SessionActivityLayoutPolicy.layout(
            beside: pet,
            expandedSize: NSSize(width: 230, height: 150),
            compactSize: NSSize(width: 190, height: 68),
            visibleFrame: visible,
            forceExpanded: true
        )
        XCTAssertFalse(forced.compact)
        XCTAssertTrue(forced.scrollable)
        XCTAssertTrue(visible.contains(forced.frame))
        XCTAssertFalse(forced.frame.intersects(pet))
        XCTAssertEqual(forced.frame.size, NSSize(width: 190, height: 68))

        let roomyVisible = NSRect(x: 0, y: 0, width: 1_000, height: 700)
        let roomyPet = NSRect(x: 300, y: 250, width: 230, height: 150)
        let fullExpandedSize = NSSize(width: 230, height: 150)
        let fullExpanded = SessionActivityLayoutPolicy.layout(
            beside: roomyPet,
            expandedSize: fullExpandedSize,
            compactSize: NSSize(width: 190, height: 68),
            visibleFrame: roomyVisible,
            forceExpanded: true
        )
        XCTAssertFalse(fullExpanded.compact)
        XCTAssertFalse(fullExpanded.scrollable)
        XCTAssertEqual(fullExpanded.frame.size, fullExpandedSize)
        XCTAssertFalse(fullExpanded.frame.intersects(roomyPet))

        let constrainedVisible = NSRect(x: 0, y: 0, width: 300, height: 200)
        let constrainedPet = NSRect(x: 50, y: 40, width: 200, height: 120)
        let overflow = SessionActivityLayoutPolicy.layout(
            beside: constrainedPet,
            expandedSize: fullExpandedSize,
            compactSize: NSSize(width: 190, height: 68),
            visibleFrame: constrainedVisible,
            forceExpanded: false
        )
        XCTAssertFalse(overflow.compact)
        XCTAssertTrue(overflow.available)
        XCTAssertTrue(overflow.scrollable)
        XCTAssertTrue(constrainedVisible.contains(overflow.frame))
        XCTAssertFalse(overflow.frame.intersects(constrainedPet))

        let coveredVisible = NSRect(x: 0, y: 0, width: 300, height: 200)
        let unavailable = SessionActivityLayoutPolicy.layout(
            beside: coveredVisible,
            expandedSize: fullExpandedSize,
            compactSize: NSSize(width: 190, height: 68),
            visibleFrame: coveredVisible,
            forceExpanded: true
        )
        XCTAssertFalse(unavailable.available)
        XCTAssertFalse(unavailable.scrollable)
        XCTAssertEqual(unavailable.frame, .zero)
    }

    @MainActor
    func testUnavailableLayoutBecomingFeasibleRestoresPanelWithEffectiveWindowLevel() {
        let visible = NSRect(x: 0, y: 0, width: 600, height: 400)
        let unavailable = SessionActivityLayoutPolicy.layout(
            beside: visible,
            expandedSize: NSSize(width: 230, height: 150),
            compactSize: NSSize(width: 190, height: 68),
            visibleFrame: visible,
            forceExpanded: false
        )
        let available = SessionActivityLayoutPolicy.layout(
            beside: NSRect(x: 185, y: 120, width: 230, height: 150),
            expandedSize: NSSize(width: 230, height: 150),
            compactSize: NSSize(width: 190, height: 68),
            visibleFrame: visible,
            forceExpanded: false
        )

        XCTAssertFalse(unavailable.available)
        XCTAssertTrue(available.available)
        XCTAssertTrue(SessionActivityPanelVisibilityPolicy.shouldOrderFront(
            wasAvailable: unavailable.available,
            isAvailable: available.available
        ))
        XCTAssertFalse(SessionActivityPanelVisibilityPolicy.shouldOrderFront(
            wasAvailable: true,
            isAvailable: true
        ))

        let panel = SessionActivityPanel(
            contentRect: available.frame,
            alwaysOnTop: false,
            fullScreenAuxiliary: false
        )
        panel.orderOut(nil)
        panel.apply(alwaysOnTop: false, fullScreenAuxiliary: false)
        panel.orderVisible(alwaysOnTop: false)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.level, .normal)

        panel.orderOut(nil)
        panel.apply(alwaysOnTop: true, fullScreenAuxiliary: false)
        panel.orderVisible(alwaysOnTop: true)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.level, .floating)
        panel.orderOut(nil)
    }

    @MainActor
    func testPanelCanReceiveKeyboardFocusWithoutActivatingOnDisplay() {
        let panel = SessionActivityPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            alwaysOnTop: false,
            fullScreenAuxiliary: false
        )
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        let previousKeyWindow = NSApp.keyWindow
        panel.orderFront(nil)
        XCTAssertTrue(NSApp.keyWindow === previousKeyWindow)
        panel.orderOut(nil)
    }

    @MainActor
    func testActivityReaderOnlyDeliversNewestGenerationOutOfOrder() throws {
        let firstStarted = expectation(description: "first activity read started")
        let newestDelivered = expectation(description: "newest activity read delivered")
        let releaseFirst = DispatchSemaphore(value: 0)
        let state = ActivityReaderState()
        let older = try SessionActivitySnapshot(emittedAt: 100)
        let newer = try SessionActivitySnapshot(emittedAt: 101)
        let reader = SessionActivityFileReader { _ in
            if state.nextCall() == 1 {
                firstStarted.fulfill()
                releaseFirst.wait()
                return .snapshot(older)
            }
            return .snapshot(newer)
        }
        let url = URL(fileURLWithPath: "/tmp/activity-v1.json")
        reader.read(url) { result in
            if case let .snapshot(snapshot) = result {
                state.append(snapshot.emittedAt)
            }
        }
        wait(for: [firstStarted], timeout: 1)
        reader.read(url) { result in
            if case let .snapshot(snapshot) = result {
                state.append(snapshot.emittedAt)
                newestDelivered.fulfill()
            }
        }
        releaseFirst.signal()
        wait(for: [newestDelivered], timeout: 1)
        XCTAssertEqual(state.values, [101])
    }

    func testRejectedSnapshotNeverPrunesAcknowledgements() throws {
        let acknowledgedID = String(repeating: "a", count: 24)
        let completed = try item(
            "a",
            state: .idle,
            event: .sessionEnd,
            terminal: true,
            eventAt: 100
        )
        let accepted = try SessionActivitySnapshot(
            emittedAt: 100,
            completed: [completed]
        )
        let rollback = try SessionActivitySnapshot(emittedAt: 99)
        let application = SessionActivityApplicationPolicy.apply(
            rollback,
            lastAccepted: accepted,
            currentlyDisplayed: accepted,
            acknowledgementHistory: [acknowledgedID],
            now: 100,
            freshnessPolicy: StateFreshnessPolicy.production
        )

        XCTAssertEqual(application.decision, .rejectRollback)
        XCTAssertEqual(application.lastAcceptedSnapshot, accepted)
        XCTAssertEqual(application.displayedSnapshot, accepted)
        XCTAssertEqual(application.acknowledgedIDs, [acknowledgedID])
    }

    func testStaleDisplayedSnapshotHidesWithoutDroppingBarrierAndDuplicateRecovers() throws {
        let freshness = try StateFreshnessPolicy(maximumAge: 10, maximumFutureSkew: 2)
        let accepted = try SessionActivitySnapshot(emittedAt: 100)
        let stale = SessionActivityApplicationPolicy.apply(
            accepted,
            lastAccepted: accepted,
            currentlyDisplayed: accepted,
            acknowledgementHistory: [],
            now: 111,
            freshnessPolicy: freshness
        )
        XCTAssertEqual(stale.decision, .rejectStale)
        XCTAssertEqual(stale.lastAcceptedSnapshot, accepted)
        XCTAssertNil(stale.displayedSnapshot)

        let future = try SessionActivitySnapshot(emittedAt: 104)
        let futureInvalid = SessionActivityApplicationPolicy.apply(
            future,
            lastAccepted: future,
            currentlyDisplayed: future,
            acknowledgementHistory: [],
            now: 100,
            freshnessPolicy: freshness
        )
        XCTAssertEqual(futureInvalid.decision, .rejectFutureSkew)
        XCTAssertEqual(futureInvalid.lastAcceptedSnapshot, future)
        XCTAssertNil(futureInvalid.displayedSnapshot)

        let recovered = SessionActivityApplicationPolicy.apply(
            accepted,
            lastAccepted: stale.lastAcceptedSnapshot,
            currentlyDisplayed: stale.displayedSnapshot,
            acknowledgementHistory: stale.acknowledgementHistory,
            now: 105,
            freshnessPolicy: freshness
        )
        XCTAssertEqual(recovered.decision, .rejectDuplicate)
        XCTAssertEqual(recovered.lastAcceptedSnapshot, accepted)
        XCTAssertEqual(recovered.displayedSnapshot, accepted)
    }

    func testAcknowledgementHistorySurvivesOmissionClearsOnRevivalAndIsBoundedLRU() throws {
        let firstID = String(repeating: "a", count: 24)
        let secondID = String(repeating: "b", count: 24)
        let accepted = try SessionActivitySnapshot(emittedAt: 100)
        let omitted = try SessionActivitySnapshot(emittedAt: 101)
        let retained = SessionActivityApplicationPolicy.apply(
            omitted,
            lastAccepted: accepted,
            currentlyDisplayed: accepted,
            acknowledgementHistory: [firstID, secondID],
            now: 101
        )
        XCTAssertEqual(retained.acknowledgementHistory, [firstID, secondID])

        let revivedItem = try item(
            "a",
            state: .running,
            event: .userPromptSubmit,
            terminal: false,
            eventAt: 102
        )
        let revived = try SessionActivitySnapshot(emittedAt: 102, active: [revivedItem])
        let cleared = SessionActivityApplicationPolicy.apply(
            revived,
            lastAccepted: omitted,
            currentlyDisplayed: omitted,
            acknowledgementHistory: retained.acknowledgementHistory,
            now: 102
        )
        XCTAssertEqual(cleared.acknowledgementHistory, [secondID])

        var history: [String] = []
        for value in 0..<140 {
            history = SessionActivityApplicationPolicy.recordingAcknowledgement(
                String(format: "%024x", value),
                in: history
            )
        }
        XCTAssertEqual(history.count, SessionActivityApplicationPolicy.maximumAcknowledgements)
        XCTAssertEqual(history.first, String(format: "%024x", 12))
        XCTAssertEqual(history.last, String(format: "%024x", 139))
        let touched = SessionActivityApplicationPolicy.recordingAcknowledgement(
            String(format: "%024x", 12),
            in: history
        )
        XCTAssertEqual(touched.last, String(format: "%024x", 12))
    }

    private func allDescendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allDescendants)
    }
}
