import AppKit
import XCTest
@testable import Statelet

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    func testSettingsWindowSizeStoreRoundTripsAndRejectsMalformedValues() throws {
        let suiteName = "statelet-settings-window-size-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let expected = NSSize(width: 812.5, height: 601.25)
        SettingsWindowSizeStore.persist(expected, to: defaults)
        let restored = try XCTUnwrap(SettingsWindowSizeStore.restored(from: defaults))
        XCTAssertEqual(restored.width, expected.width, accuracy: 0.001)
        XCTAssertEqual(restored.height, expected.height, accuracy: 0.001)

        defaults.set(["width": -1.0, "height": 600.0], forKey: SettingsWindowSizeStore.defaultsKey)
        XCTAssertNil(SettingsWindowSizeStore.restored(from: defaults))

        defaults.set(["width": 10_001.0, "height": 600.0], forKey: SettingsWindowSizeStore.defaultsKey)
        XCTAssertNil(SettingsWindowSizeStore.restored(from: defaults))

        defaults.set(["width": "not-a-number", "height": 600.0], forKey: SettingsWindowSizeStore.defaultsKey)
        XCTAssertNil(SettingsWindowSizeStore.restored(from: defaults))

        SettingsWindowSizeStore.reset(in: defaults)
        XCTAssertNil(SettingsWindowSizeStore.restored(from: defaults))
    }

    func testSettingsWindowRestoresSizePersistsResizeAndExposesResetAction() throws {
        let suiteName = "statelet-settings-window-controller-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        SettingsWindowSizeStore.persist(NSSize(width: 720, height: 580), to: defaults)
        let controller = SettingsWindowController(defaults: defaults)
        let window = try XCTUnwrap(controller.window)
        controller.show()
        Self.pumpMainRunLoop(for: 0.1)
        defer {
            window.close()
            Self.pumpMainRunLoop(for: 0.05)
        }

        XCTAssertEqual(window.contentLayoutRect.width, 720, accuracy: 1)
        XCTAssertEqual(window.contentLayoutRect.height, 580, accuracy: 1)

        window.setContentSize(NSSize(width: 740, height: 600))
        Self.pumpMainRunLoop(for: 0.05)
        let resized = try XCTUnwrap(SettingsWindowSizeStore.restored(from: defaults))
        XCTAssertEqual(resized.width, window.contentLayoutRect.width, accuracy: 1)
        XCTAssertEqual(resized.height, window.contentLayoutRect.height, accuracy: 1)

        let resetButton = try XCTUnwrap(
            controller.window?.titlebarAccessoryViewControllers
                .flatMap { Self.descendants(of: $0.view) }
                .compactMap { $0 as? NSButton }
                .first { $0.accessibilityLabel() == "Reset Settings Window Size" }
        )
        resetButton.performClick(nil)
        Self.pumpMainRunLoop(for: 0.05)
        XCTAssertEqual(window.contentLayoutRect.width, min(760, window.contentMaxSize.width), accuracy: 1)
        XCTAssertEqual(window.contentLayoutRect.height, min(650, window.contentMaxSize.height), accuracy: 1)
        let resetSize = try XCTUnwrap(SettingsWindowSizeStore.restored(from: defaults))
        XCTAssertEqual(resetSize.width, window.contentLayoutRect.width, accuracy: 1)
        XCTAssertEqual(resetSize.height, window.contentLayoutRect.height, accuracy: 1)
    }

    func testStaticSettingsPanesProvideScrollableOverflow() throws {
        let suiteName = "statelet-settings-scroll-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let controller = SettingsWindowController(defaults: defaults)
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
        for section in [2, 3, 6] {
            tabs.selectedSegment = section
            NSApp.sendAction(tabs.action!, to: tabs.target, from: tabs)
            Self.pumpMainRunLoop(for: 0.05)
            let scrollView = try XCTUnwrap(
                Self.descendants(of: window.contentView).compactMap { $0 as? NSScrollView }.first {
                    $0.accessibilityLabel() == "Settings pane scroll area"
                },
                "section \(section)"
            )
            XCTAssertTrue(
                try XCTUnwrap(scrollView.documentView, "section \(section)").isFlipped,
                "section \(section) should open at the top of its scrollable content"
            )
        }
    }

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
        let transitionScope = try XCTUnwrap(
            Self.descendants(of: window.contentView).compactMap { $0 as? NSSegmentedControl }.first {
                $0.accessibilityLabel() == "Transition library scope"
            }
        )
        XCTAssertEqual(transitionScope.selectedSegment, 0)
        let transitionsHeight = try XCTUnwrap(
            Self.descendants(of: window.contentView).first {
                $0.accessibilityLabel() == "Directional lifecycle transitions"
            }
        ).frame.height
        XCTAssertGreaterThan(transitionsHeight, 100)

        transitionScope.selectedSegment = 1
        NSApp.sendAction(transitionScope.action!, to: transitionScope.target, from: transitionScope)
        Self.pumpMainRunLoop(for: 0.05)
        XCTAssertEqual(transitionScope.accessibilityValue() as? String, "Global")

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
