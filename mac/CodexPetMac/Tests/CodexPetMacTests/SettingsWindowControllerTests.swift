import AppKit
import CodexPetCore
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

    func testSettingsSidebarProvidesOrderedAccessibleKeyboardNavigationAndPersistsSelection() throws {
        let suiteName = "statelet-settings-sidebar-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let controller = SettingsWindowController(defaults: defaults)
        let window = try XCTUnwrap(controller.window)
        controller.show()
        Self.pumpMainRunLoop(for: 0.1)
        window.setContentSize(NSSize(width: 700, height: 570))
        Self.pumpMainRunLoop(for: 0.05)

        let sidebar = try Self.settingsSidebar(in: window)
        let expectedLabels = [
            "Animations",
            "Voice",
            "Appearance",
            "General",
            "Diagnostics",
            "Help",
            "Prompts",
            "Recommendation",
        ]
        XCTAssertEqual(sidebar.numberOfRows, expectedLabels.count)
        XCTAssertEqual(
            (0 ..< sidebar.numberOfRows).map { Self.sidebarLabel(in: sidebar, row: $0) },
            expectedLabels
        )
        XCTAssertEqual(sidebar.accessibilityLabel(), "Settings navigation")
        XCTAssertEqual(sidebar.accessibilityRole(), .list)
        XCTAssertEqual(sidebar.selectedRow, 0)
        XCTAssertFalse(
            Self.descendants(of: window.contentView).compactMap { $0 as? NSSegmentedControl }.contains {
                $0.accessibilityLabel() == "Settings section"
            }
        )
        XCTAssertGreaterThanOrEqual(sidebar.enclosingScrollView?.frame.width ?? 0, 125)
        XCTAssertLessThanOrEqual(sidebar.enclosingScrollView?.frame.width ?? .greatestFiniteMagnitude, 160)
        XCTAssertEqual(window.contentLayoutRect.width, 700, accuracy: 1)
        XCTAssertEqual(window.contentLayoutRect.height, 570, accuracy: 1)

        XCTAssertTrue(window.makeFirstResponder(sidebar))
        let downArrow = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{F701}",
            charactersIgnoringModifiers: "\u{F701}",
            isARepeat: false,
            keyCode: 125
        ))
        sidebar.keyDown(with: downArrow)
        Self.pumpMainRunLoop(for: 0.05)
        XCTAssertEqual(sidebar.selectedRow, 1)

        sidebar.selectRowIndexes(IndexSet(integer: 6), byExtendingSelection: false)
        Self.pumpMainRunLoop(for: 0.05)
        XCTAssertEqual(sidebar.selectedRowIndexes, IndexSet(integer: 6))
        XCTAssertEqual(sidebar.accessibilitySelectedRows()?.count, 1)
        XCTAssertEqual(defaults.integer(forKey: "Statelet.Settings.selectedSection"), 6)
        window.close()
        Self.pumpMainRunLoop(for: 0.05)

        let restoredController = SettingsWindowController(defaults: defaults)
        let restoredWindow = try XCTUnwrap(restoredController.window)
        restoredController.show()
        Self.pumpMainRunLoop(for: 0.1)
        defer {
            restoredWindow.close()
            Self.pumpMainRunLoop(for: 0.05)
        }
        XCTAssertEqual(try Self.settingsSidebar(in: restoredWindow).selectedRow, 6)
    }

    @MainActor
    func testAppearanceExposesDialogueAndActivityPopupControlsAndPreviews() throws {
        let controller = SettingsWindowController()
        let window = try XCTUnwrap(controller.window)
        controller.update(
            snapshot: SettingsSnapshot(
                mediaMap: try MediaMap(),
                mediaMapURL: URL(fileURLWithPath: "/tmp/media-map.json"),
                publisherSummary: "Test",
                reduceMotion: false
            )
        )
        controller.show()
        Self.pumpMainRunLoop(for: 0.1)
        defer {
            window.close()
            Self.pumpMainRunLoop(for: 0.05)
        }

        let sidebar = try Self.settingsSidebar(in: window)
        sidebar.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        Self.pumpMainRunLoop(for: 0.05)

        let labels = Self.descendants(of: window.contentView)
            .compactMap { $0.accessibilityLabel() }
        for label in [
            "Dialogue bubble background color",
            "Dialogue bubble text color",
            "Dialogue bubble background opacity",
            "Dialogue bubble contrast",
            "Activity popup background color",
            "Activity popup background opacity",
            "Activity popup contrast",
            "Dialogue bubble appearance preview",
            "Activity popup appearance preview",
        ] {
            XCTAssertTrue(labels.contains(label), "missing \(label)")
        }
        sidebar.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
        Self.pumpMainRunLoop(for: 0.05)
        XCTAssertTrue(Self.descendants(of: window.contentView).compactMap { $0 as? NSTextField }.contains {
            $0.stringValue.contains("Managed media location")
        })
        XCTAssertNotNil(
            Self.descendants(of: window.contentView).compactMap { $0 as? NSButton }.first {
                $0.accessibilityLabel() == "Open managed media location in Finder"
            }
        )
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

        let sidebar = try Self.settingsSidebar(in: window)
        for section in [2, 3, 5, 6] {
            sidebar.selectRowIndexes(IndexSet(integer: section), byExtendingSelection: false)
            Self.pumpMainRunLoop(for: 0.05)
            let scrollView = try XCTUnwrap(
                Self.descendants(of: window.contentView).compactMap { $0 as? NSScrollView }.first {
                    $0.accessibilityLabel() == "Settings pane scroll area"
                },
                "section \(section)"
            )
            let documentView = try XCTUnwrap(scrollView.documentView, "section \(section)")
            XCTAssertTrue(
                documentView.isFlipped,
                "section \(section) should open at the top of its scrollable content"
            )
            if section == 5 {
                XCTAssertGreaterThan(
                    documentView.frame.height,
                    scrollView.contentView.bounds.height,
                    "Help should retain scrollable overflow at the supported compact size"
                )
            }
        }
    }

    func testHelpAndPromptsSectionsRemainDistinctAndExposeUpdateControls() throws {
        let controller = SettingsWindowController()
        let window = try XCTUnwrap(controller.window)
        controller.show()
        Self.pumpMainRunLoop(for: 0.1)
        defer {
            window.close()
            Self.pumpMainRunLoop(for: 0.05)
        }

        let sidebar = try Self.settingsSidebar(in: window)
        XCTAssertEqual(sidebar.numberOfRows, 8)
        XCTAssertEqual(Self.sidebarLabel(in: sidebar, row: 5), "Help")
        XCTAssertEqual(Self.sidebarLabel(in: sidebar, row: 6), "Prompts")

        sidebar.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
        Self.pumpMainRunLoop(for: 0.05)
        XCTAssertNotNil(
            Self.descendants(of: window.contentView).compactMap { $0 as? NSTextField }.first {
                $0.stringValue == "Using Statelet"
            }
        )
        XCTAssertNotNil(
            Self.descendants(of: window.contentView).compactMap { $0 as? NSButton }.first {
                $0.accessibilityLabel() == "Check for Statelet updates"
            }
        )
        XCTAssertNotNil(
            Self.descendants(of: window.contentView).compactMap { $0 as? NSButton }.first {
                $0.accessibilityLabel() == "Automatically install verified updates"
            }
        )
        XCTAssertNotNil(
            Self.descendants(of: window.contentView).compactMap { $0 as? NSButton }.first {
                $0.accessibilityLabel() == "Cancel Statelet update"
            }
        )

        controller.update(
            update: StateletUpdateSnapshot(
                status: StateletUpdaterError.transactionRecoveryRequired.safeStatus,
                installedVersion: "1.7.1 (13)",
                candidateVersion: nil,
                releaseNotes: nil,
                progress: nil,
                isChecking: false,
                isReadyToInstall: false,
                isScheduledForRestart: false,
                isBlocked: true,
                automaticInstallEnabled: false
            )
        )
        Self.pumpMainRunLoop(for: 0.05)
        let updateControls = Self.descendants(of: window.contentView)
            .compactMap { $0 as? NSButton }
            .filter {
                [
                    "Check for Statelet updates",
                    "Cancel Statelet update",
                    "Install verified Statelet update at restart",
                    "Automatically install verified updates",
                ].contains($0.accessibilityLabel() ?? "")
            }
        XCTAssertEqual(updateControls.count, 4)
        XCTAssertTrue(updateControls.allSatisfy { !$0.isEnabled })

        sidebar.selectRowIndexes(IndexSet(integer: 6), byExtendingSelection: false)
        Self.pumpMainRunLoop(for: 0.05)
        XCTAssertNotNil(
            Self.descendants(of: window.contentView).compactMap { $0 as? NSTextField }.first {
                $0.stringValue == "Generate conversion-friendly animation"
            }
        )
    }

    func testInitialPaneDoesNotInflateRequestedWindowSize() throws {
        let suiteName = "statelet-settings-pane-size-\(UUID().uuidString)"
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

        let sidebar = try Self.settingsSidebar(in: window)
        sidebar.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        Self.pumpMainRunLoop(for: 0.05)
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

        for section in 0 ..< sidebar.numberOfRows {
            sidebar.selectRowIndexes(IndexSet(integer: section), byExtendingSelection: false)
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

    func testGlobalTransitionScopeShowsOneEditorAndDisablesEditsDuringLegacyResolution() throws {
        let route = try StateTransitionKey(from: .idle, to: .running)
        let universal = try StateMediaPlaylist(entries: [
            MediaEntry(path: "global.mov", loop: false),
        ])
        let conflict = try GlobalTransitionLibrary(universalPlaylist: universal)
            .recoveringLegacyTransitionEntry(
                MediaEntry(path: "recovered.mov", loop: false),
                from: route.from,
                to: route.to
            )
        let controller = SettingsWindowController()
        let window = try XCTUnwrap(controller.window)
        controller.update(snapshot: SettingsSnapshot(
            mediaMap: try MediaMap(),
            mediaMapURL: URL(fileURLWithPath: "/tmp/media-map.json"),
            globalTransitionLibrary: conflict,
            globalTransitionLibraryURL: URL(fileURLWithPath: "/tmp/global-transitions.json"),
            publisherSummary: "Test",
            reduceMotion: false
        ))
        controller.show()
        Self.pumpMainRunLoop(for: 0.1)
        defer {
            window.close()
            Self.pumpMainRunLoop(for: 0.05)
        }

        let sidebar = try Self.settingsSidebar(in: window)
        sidebar.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        Self.pumpMainRunLoop(for: 0.05)
        let animationModes = try XCTUnwrap(
            Self.descendants(of: window.contentView).compactMap { $0 as? NSSegmentedControl }.first {
                $0.accessibilityLabel() == "Animation library mode"
            }
        )
        animationModes.selectedSegment = 1
        NSApp.sendAction(animationModes.action!, to: animationModes.target, from: animationModes)
        Self.pumpMainRunLoop(for: 0.05)
        let transitionScope = try XCTUnwrap(
            Self.descendants(of: window.contentView).compactMap { $0 as? NSSegmentedControl }.first {
                $0.accessibilityLabel() == "Transition library scope"
            }
        )
        transitionScope.selectedSegment = 1
        NSApp.sendAction(transitionScope.action!, to: transitionScope.target, from: transitionScope)
        Self.pumpMainRunLoop(for: 0.05)

        let globalEditors = Self.descendants(of: window.contentView).compactMap { $0 as? NSTableView }.filter {
            $0.accessibilityLabel() == "Global lifecycle transition"
        }
        let globalEditor = try XCTUnwrap(globalEditors.first)
        XCTAssertEqual(globalEditors.count, 1)
        XCTAssertEqual(globalEditor.numberOfRows, 1)

        let resolveButton = try XCTUnwrap(
            Self.descendants(of: window.contentView).compactMap { $0 as? NSButton }.first {
                $0.accessibilityLabel() == "Resolve legacy Global transitions"
            }
        )
        XCTAssertFalse(resolveButton.isHidden)
        XCTAssertTrue(resolveButton.isEnabled)

        let addColumn = try XCTUnwrap(globalEditor.tableColumns.firstIndex { $0.title == "Add" })
        let addCell = try XCTUnwrap(
            globalEditor.view(atColumn: addColumn, row: 0, makeIfNecessary: true)
        )
        let addButton = try XCTUnwrap(
            Self.descendants(of: addCell).compactMap { $0 as? NSButton }.first
        )
        XCTAssertFalse(addButton.isEnabled)

        let previewColumn = try XCTUnwrap(globalEditor.tableColumns.firstIndex { $0.title == "Preview" })
        let previewCell = try XCTUnwrap(
            globalEditor.view(atColumn: previewColumn, row: 0, makeIfNecessary: true)
        )
        let previewButton = try XCTUnwrap(
            Self.descendants(of: previewCell).compactMap { $0 as? NSButton }.first
        )
        XCTAssertEqual(previewButton.title, "Preview")
        XCTAssertFalse(previewButton.isEnabled)
        XCTAssertTrue(
            Self.descendants(of: window.contentView).compactMap { $0 as? NSTextField }.contains {
                $0.stringValue.contains("Resolve the migration before editing")
            }
        )

        let archivedOnly = try conflict
            .migratingLegacyToUniversal(using: route)
            .removingUniversalTransition()
        controller.update(snapshot: SettingsSnapshot(
            mediaMap: try MediaMap(),
            mediaMapURL: URL(fileURLWithPath: "/tmp/media-map.json"),
            globalTransitionLibrary: archivedOnly,
            globalTransitionLibraryURL: URL(fileURLWithPath: "/tmp/global-transitions.json"),
            publisherSummary: "Test",
            reduceMotion: false
        ))
        transitionScope.selectedSegment = 0
        NSApp.sendAction(transitionScope.action!, to: transitionScope.target, from: transitionScope)
        Self.pumpMainRunLoop(for: 0.05)

        XCTAssertFalse(
            Self.descendants(of: window.contentView).compactMap { $0 as? NSTextField }.contains {
                $0.stringValue.contains("Using Global fallback")
            }
        )
    }

    private static func descendants(of root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { descendants(of: $0) }
    }

    private static func settingsSidebar(in window: NSWindow) throws -> NSTableView {
        try XCTUnwrap(
            descendants(of: window.contentView).compactMap { $0 as? NSTableView }.first {
                $0.accessibilityLabel() == "Settings navigation"
            }
        )
    }

    private static func sidebarLabel(in sidebar: NSTableView, row: Int) -> String? {
        guard let cell = sidebar.view(atColumn: 0, row: row, makeIfNecessary: true) else { return nil }
        return descendants(of: cell).compactMap { $0 as? NSTextField }.first?.stringValue
    }

    private static func pumpMainRunLoop(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        }
    }
}
