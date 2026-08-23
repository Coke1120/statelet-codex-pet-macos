import AppKit
import XCTest
@testable import Statelet

final class WindowResizeFrameCoordinatorTests: XCTestCase {
    @MainActor
    func testSubmitCoalescesQueuedFramesAndAppliesOnlyTheLatest() {
        var scheduledActions: [() -> Void] = []
        var appliedFrames: [NSRect] = []
        let coordinator = WindowResizeFrameCoordinator(
            schedule: { action in scheduledActions.append(action) },
            apply: { frame in appliedFrames.append(frame) }
        )
        let firstFrame = NSRect(x: 10, y: 20, width: 800, height: 600)
        let latestFrame = NSRect(x: 10, y: 20, width: 860, height: 640)

        coordinator.submit(firstFrame)
        coordinator.submit(latestFrame)

        XCTAssertEqual(scheduledActions.count, 1)
        XCTAssertTrue(appliedFrames.isEmpty)

        scheduledActions.removeFirst()()

        XCTAssertEqual(appliedFrames, [latestFrame])
    }

    @MainActor
    func testFlushAppliesPendingFrameAndMakesScheduledWorkANoOp() {
        var scheduledActions: [() -> Void] = []
        var appliedFrames: [NSRect] = []
        let coordinator = WindowResizeFrameCoordinator(
            schedule: { action in scheduledActions.append(action) },
            apply: { frame in appliedFrames.append(frame) }
        )
        let frame = NSRect(x: 40, y: 50, width: 900, height: 650)

        coordinator.submit(frame)
        coordinator.flush()

        XCTAssertEqual(appliedFrames, [frame])
        XCTAssertEqual(scheduledActions.count, 1)

        scheduledActions.removeFirst()()

        XCTAssertEqual(appliedFrames, [frame])
    }
}
