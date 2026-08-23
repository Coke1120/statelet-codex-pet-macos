import AppKit
import XCTest
@testable import Statelet

@MainActor
final class PetPlayerInteractionTests: XCTestCase {
    func testResizeCoalescesFramesUpdatesLayersAndEndsOnceOnMouseUp() throws {
        let initialFrame = NSRect(x: 100, y: 100, width: 320, height: 480)
        let window = PetPanel(
            contentRect: initialFrame,
            alwaysOnTop: false,
            fullScreenAuxiliary: false
        )
        var scheduledActions: [() -> Void] = []
        let view = PetPlayerView(
            frame: NSRect(origin: .zero, size: initialFrame.size),
            resizeFrameScheduler: { action in scheduledActions.append(action) }
        )
        window.contentView = view

        var resizeEndSizes: [NSSize] = []
        view.onResizeEnded = { size in resizeEndSizes.append(size) }
        let initialPoint = NSPoint(x: view.bounds.maxX - 2, y: view.bounds.maxY - 2)
        let firstDraggedPoint = NSPoint(x: initialPoint.x + 20, y: initialPoint.y + 15)
        let latestDraggedPoint = NSPoint(x: initialPoint.x + 40, y: initialPoint.y + 30)
        let expectedSize = NSSize(
            width: initialFrame.width + 40,
            height: (initialFrame.width + 40) * initialFrame.height / initialFrame.width
        )

        view.mouseDown(with: try Self.mouseEvent(
            type: .leftMouseDown,
            location: initialPoint,
            window: window
        ))
        view.mouseDragged(with: try Self.mouseEvent(
            type: .leftMouseDragged,
            location: firstDraggedPoint,
            window: window
        ))
        view.mouseDragged(with: try Self.mouseEvent(
            type: .leftMouseDragged,
            location: latestDraggedPoint,
            window: window
        ))

        XCTAssertEqual(window.frame, initialFrame)
        XCTAssertEqual(scheduledActions.count, 1)
        XCTAssertTrue(resizeEndSizes.isEmpty)

        scheduledActions.removeFirst()()

        XCTAssertEqual(window.frame.width, expectedSize.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, expectedSize.height, accuracy: 1)
        XCTAssertEqual(view.playerLayer.frame, view.bounds)
        XCTAssertEqual(view.destinationPlayerLayer.frame, view.bounds)
        XCTAssertEqual(view.lifecycleTransitionPlayerLayer.frame, view.bounds)
        XCTAssertTrue(resizeEndSizes.isEmpty)

        view.mouseUp(with: try Self.mouseEvent(
            type: .leftMouseUp,
            location: latestDraggedPoint,
            window: window
        ))

        XCTAssertEqual(window.frame.size, expectedSize)
        XCTAssertEqual(resizeEndSizes, [window.frame.size])
    }

    private static func mouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}
