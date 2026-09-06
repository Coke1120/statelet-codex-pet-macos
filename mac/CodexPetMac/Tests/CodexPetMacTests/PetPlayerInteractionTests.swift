import AppKit
import CodexPetCore
import XCTest
@testable import Statelet

@MainActor
final class PetPlayerInteractionTests: XCTestCase {
    func testUnmappedPlaybackOffersStateSpecificRecoveryWithAndWithoutReduceMotion() throws {
        for reduceMotion in [false, true] {
            let view = PetPlayerView(frame: NSRect(x: 0, y: 0, width: 160, height: 240))
            let controller = PetPlayerController(view: view)
            controller.setReduceMotion(reduceMotion)
            var openedStates: [PetState] = []
            view.onOpenAnimationSettings = { openedStates.append($0) }

            XCTAssertEqual(controller.show(
                state: .waiting, entry: nil, url: nil, posterURL: nil,
                transitionID: 1, startedAt: DispatchTime.now().uptimeNanoseconds
            ), .failed)
            XCTAssertEqual(controller.presentationStatus, .placeholder(.waiting))
            view.layoutSubtreeIfNeeded()
            let card = try XCTUnwrap(view.subviews.first {
                $0.identifier?.rawValue == "mediaRecoveryCard"
            })
            let button = try XCTUnwrap(card.subviews.compactMap { $0 as? NSButton }.first)
            let label = try XCTUnwrap(card.subviews.compactMap { $0 as? NSTextField }.first)
            XCTAssertFalse(card.isHidden)
            XCTAssertFalse(button.isHidden)
            XCTAssertTrue(view.bounds.contains(card.frame))
            XCTAssertTrue(card.bounds.contains(button.frame))
            XCTAssertTrue(card.bounds.contains(label.frame))
            XCTAssertGreaterThanOrEqual(label.frame.height + 1, label.fittingSize.height)
            XCTAssertTrue(label.stringValue.contains("Statelet menu bar"))
            XCTAssertEqual(button.accessibilityLabel(), "Open animation settings")
            let buttonCenter = button.convert(
                NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: view
            )
            XCTAssertTrue(view.hitTest(buttonCenter) === button)
            for controls in view.subviews.compactMap({ $0 as? NSStackView }) {
                XCTAssertTrue(controls.isHidden || !controls.frame.intersects(card.frame))
            }
            button.performClick(nil)
            XCTAssertEqual(openedStates, [.waiting])

            // A callback from a previously visible recovery control must not
            // reopen Settings after playback has replaced its placeholder.
            view.showPlaceholder(nil)
            button.performClick(nil)
            XCTAssertTrue(card.isHidden)
            XCTAssertFalse(view.hitTest(buttonCenter) === button)
            XCTAssertEqual(openedStates, [.waiting])
        }
    }

    func testReduceMotionWithoutPosterKeepsQuickControlsBesideInformationalCard() throws {
        let view = PetPlayerView(frame: NSRect(x: 0, y: 0, width: 160, height: 240))
        let controller = PetPlayerController(view: view)
        controller.setReduceMotion(true)
        let entry = try MediaEntry(path: "mapped.mov")
        XCTAssertEqual(controller.show(
            state: .waiting, entry: entry,
            url: URL(fileURLWithPath: "/tmp/statelet-mapped-no-poster.mov"), posterURL: nil,
            transitionID: 1, startedAt: DispatchTime.now().uptimeNanoseconds
        ), .presented)
        view.updateQuickControls(
            canAdvanceClip: true, liveState: .waiting, displayedState: .waiting, manualPreview: nil
        )
        view.layoutSubtreeIfNeeded()

        let card = try XCTUnwrap(view.subviews.first {
            $0.identifier?.rawValue == "mediaRecoveryCard"
        })
        let label = try XCTUnwrap(card.subviews.compactMap { $0 as? NSTextField }.first)
        let recoveryButton = try XCTUnwrap(card.subviews.compactMap { $0 as? NSButton }.first)
        let controls = try XCTUnwrap(view.subviews.compactMap { $0 as? NSStackView }.first)
        XCTAssertFalse(card.isHidden)
        XCTAssertFalse(controls.isHidden)
        XCTAssertTrue(recoveryButton.isHidden)
        XCTAssertTrue(view.bounds.contains(card.frame))
        XCTAssertFalse(controls.frame.intersects(card.frame))
        XCTAssertGreaterThanOrEqual(label.frame.height + 1, label.fittingSize.height)
        let buttons = controls.views.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 2)
        for button in buttons {
            XCTAssertTrue(button.isEnabled)
            XCTAssertFalse(button.isHidden)
            let frame = button.convert(button.bounds, to: view)
            XCTAssertFalse(frame.intersects(card.frame))
            XCTAssertTrue(view.hitTest(NSPoint(x: frame.midX, y: frame.midY)) === button)
        }
        var advanceCount = 0
        view.onAdvanceClip = { advanceCount += 1 }
        let nextButton = try XCTUnwrap(buttons.first {
            $0.accessibilityLabel() == "Next clip for waiting"
        })
        nextButton.performClick(nil)
        XCTAssertEqual(advanceCount, 1)
    }

    func testPosterOnlyReduceMotionPlaybackReplacesRecoveryWithoutRequiringVideo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        try XCTUnwrap(bitmap.bitmapData).initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let poster = root.appendingPathComponent("poster.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: poster)
        let view = PetPlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        let controller = PetPlayerController(view: view)
        controller.setReduceMotion(true)
        _ = controller.show(
            state: .idle, entry: nil, url: nil, posterURL: nil,
            transitionID: 1, startedAt: DispatchTime.now().uptimeNanoseconds
        )
        XCTAssertEqual(controller.show(
            state: .idle, entry: nil, url: nil, posterURL: poster,
            transitionID: 2, startedAt: DispatchTime.now().uptimeNanoseconds
        ), .presented)
        XCTAssertTrue(view.hasVisiblePoster)
        XCTAssertEqual(controller.presentationStatus, .presented(.idle))
        XCTAssertTrue(try XCTUnwrap(view.subviews.first {
            $0.identifier?.rawValue == "mediaRecoveryCard"
        }).isHidden)
    }

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
