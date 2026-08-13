import AppKit
import XCTest
@testable import Statelet

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    func testInitialPaneDoesNotInflateRequestedWindowSize() throws {
        let controller = SettingsWindowController()
        let window = try XCTUnwrap(controller.window)

        controller.show()
        Self.pumpMainRunLoop(for: 0.1)
        defer {
            window.close()
            Self.pumpMainRunLoop(for: 0.05)
        }

        let tabs = try XCTUnwrap(
            Self.descendants(of: window.contentView).compactMap { $0 as? NSSegmentedControl }.first {
                $0.accessibilityLabel() == "Settings section"
            }
        )
        let animationModes = try XCTUnwrap(
            Self.descendants(of: window.contentView).compactMap { $0 as? NSSegmentedControl }.first {
                $0.accessibilityLabel() == "Animation library mode"
            }
        )
        let stateAnimationsHeight = try XCTUnwrap(
            Self.descendants(of: window.contentView).first {
                $0.accessibilityLabel() == "Animation clips"
            }
        ).frame.height
        XCTAssertGreaterThan(stateAnimationsHeight, 100)

        animationModes.selectedSegment = 1
        NSApp.sendAction(animationModes.action!, to: animationModes.target, from: animationModes)
        Self.pumpMainRunLoop(for: 0.05)
        let transitionsHeight = try XCTUnwrap(
            Self.descendants(of: window.contentView).first {
                $0.accessibilityLabel() == "Directional lifecycle transitions"
            }
        ).frame.height
        XCTAssertGreaterThan(transitionsHeight, 100)

        for section in 0 ..< tabs.segmentCount {
            tabs.selectedSegment = section
            NSApp.sendAction(tabs.action!, to: tabs.target, from: tabs)
            Self.pumpMainRunLoop(for: 0.05)

            XCTAssertGreaterThanOrEqual(window.contentLayoutRect.width, 700, "section \(section)")
            XCTAssertLessThanOrEqual(window.contentLayoutRect.width, 800, "section \(section)")
            XCTAssertGreaterThanOrEqual(window.contentLayoutRect.height, 570, "section \(section)")
            XCTAssertLessThanOrEqual(window.contentLayoutRect.height, 650, "section \(section)")
            if let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
                XCTAssertLessThanOrEqual(window.frame.width, visibleFrame.width, "section \(section)")
                XCTAssertLessThanOrEqual(window.frame.height, visibleFrame.height, "section \(section)")
                XCTAssertTrue(visibleFrame.contains(window.frame), "section \(section)")
            }
        }
    }

    private static func descendants(of root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { descendants(of: $0) }
    }

    private static func pumpMainRunLoop(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        }
    }
}
