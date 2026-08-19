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

        XCTAssertEqual(Self.contentSize(of: window).width, 720, accuracy: 1)
        XCTAssertEqual(Self.contentSize(of: window).height, 580, accuracy: 1)

        window.setContentSize(NSSize(width: 740, height: 600))
        Self.pumpMainRunLoop(for: 0.05)
        let resized = try XCTUnwrap(SettingsWindowSizeStore.restored(from: defaults))
        XCTAssertEqual(resized.width, Self.contentSize(of: window).width, accuracy: 1)
        XCTAssertEqual(resized.height, Self.contentSize(of: window).height, accuracy: 1)

        let toolbar = try XCTUnwrap(window.toolbar)
        let resetItem = try XCTUnwrap(
            toolbar.items.first {
                $0.itemIdentifier.rawValue == "StateletSettingsResetWindowSize"
            }
        )
        XCTAssertEqual(resetItem.label, "Reset Window Size")
        XCTAssertEqual(resetItem.toolTip, "Restore the default Settings window size")
        XCTAssertNotNil(resetItem.image)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(resetItem.action), to: resetItem.target, from: resetItem))
        Self.pumpMainRunLoop(for: 0.05)
        XCTAssertEqual(Self.contentSize(of: window).width, min(760, window.contentMaxSize.width), accuracy: 1)
        XCTAssertEqual(Self.contentSize(of: window).height, min(650, window.contentMaxSize.height), accuracy: 1)
        let resetSize = try XCTUnwrap(SettingsWindowSizeStore.restored(from: defaults))
        XCTAssertEqual(resetSize.width, Self.contentSize(of: window).width, accuracy: 1)
        XCTAssertEqual(resetSize.height, Self.contentSize(of: window).height, accuracy: 1)
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
            "App",
            "General",
            "Appearance",
            "Pet Content",
            "Animations",
            "Dialogue & Voice",
            "Create Media",
            "Prompt Generator",
            "Source Requirements",
            "Support",
            "Help & Updates",
            "Diagnostics & Repair",
        ]
        let groupRows = [0, 3, 6, 9]
        let destinationLabels = expectedLabels.enumerated().compactMap { index, label in
            groupRows.contains(index) ? nil : label
        }
        XCTAssertEqual(sidebar.numberOfRows, expectedLabels.count)
        XCTAssertEqual(
            (0 ..< sidebar.numberOfRows).map { Self.sidebarLabel(in: sidebar, row: $0) },
            expectedLabels
        )
        XCTAssertEqual(sidebar.accessibilityLabel(), "Settings navigation")
        XCTAssertEqual(sidebar.accessibilityRole(), .list)
        XCTAssertEqual(sidebar.selectedRow, 1)
        for row in groupRows {
            XCTAssertTrue(sidebar.delegate?.tableView?(sidebar, isGroupRow: row) ?? false)
            XCTAssertFalse(sidebar.delegate?.tableView?(sidebar, shouldSelectRow: row) ?? true)
            XCTAssertEqual(sidebar.view(atColumn: 0, row: row, makeIfNecessary: true)?.accessibilityRole(), .group)
        }
        XCTAssertFalse(
            Self.descendants(of: window.contentView).compactMap { $0 as? NSSegmentedControl }.contains {
                $0.accessibilityLabel() == "Settings section"
            }
        )
        let splitViewController = try XCTUnwrap(
            Self.descendants(of: window.contentView)
                .compactMap { $0.nextResponder as? NSSplitViewController }
                .first
        )
        XCTAssertEqual(
            splitViewController.splitViewItems.first?.viewController.view.frame.width ?? 0,
            218,
            accuracy: 1
        )
        XCTAssertGreaterThanOrEqual(sidebar.enclosingScrollView?.frame.width ?? 0, 200)
        XCTAssertLessThanOrEqual(sidebar.enclosingScrollView?.frame.width ?? .greatestFiniteMagnitude, 210)
        for label in destinationLabels {
            let row = try Self.sidebarRow(in: sidebar, label: label)
            let cell = try XCTUnwrap(sidebar.view(atColumn: 0, row: row, makeIfNecessary: true))
            let labelView = try XCTUnwrap(Self.sidebarLabelView(in: sidebar, row: row))
            XCTAssertGreaterThanOrEqual(labelView.frame.width + 0.5, labelView.intrinsicContentSize.width, label)
            XCTAssertFalse(cell.isAccessibilityElement(), "native table rows should own destination selection semantics")
            XCTAssertNotNil(
                (cell as? NSTableCellView)?.imageView?.image,
                "destination \(label) should use a monochrome system symbol"
            )
        }
        XCTAssertEqual(Self.contentSize(of: window).width, 700, accuracy: 1)
        XCTAssertEqual(Self.contentSize(of: window).height, 570, accuracy: 1)

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
        XCTAssertEqual(sidebar.selectedRow, 2)
        XCTAssertEqual(sidebar.accessibilitySelectedRows()?.count, 1)

        sidebar.keyDown(with: downArrow)
        Self.pumpMainRunLoop(for: 0.05)
        XCTAssertEqual(sidebar.selectedRow, 4, "keyboard navigation should skip the Pet Content group heading")

        let promptRow = try Self.selectSidebar(in: sidebar, label: "Prompt Generator")
        XCTAssertEqual(sidebar.selectedRowIndexes, IndexSet(integer: promptRow))
        XCTAssertEqual(sidebar.accessibilitySelectedRows()?.count, 1)
        XCTAssertEqual(defaults.string(forKey: "Statelet.Settings.selectedSectionID"), "prompts")
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
        let restoredSidebar = try Self.settingsSidebar(in: restoredWindow)
        XCTAssertEqual(restoredSidebar.selectedRow, try Self.sidebarRow(in: restoredSidebar, label: "Prompt Generator"))
    }

    func testSettingsSidebarMigratesLegacySelectionWithoutChangingItsDestination() throws {
        let suiteName = "statelet-settings-sidebar-legacy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(0, forKey: "Statelet.Settings.selectedSection")

        let controller = SettingsWindowController(defaults: defaults)
        let window = try XCTUnwrap(controller.window)
        controller.show()
        Self.pumpMainRunLoop(for: 0.1)
        defer {
            window.close()
            Self.pumpMainRunLoop(for: 0.05)
        }

        let sidebar = try Self.settingsSidebar(in: window)
        XCTAssertEqual(sidebar.selectedRow, try Self.sidebarRow(in: sidebar, label: "Animations"))
        XCTAssertEqual(defaults.string(forKey: "Statelet.Settings.selectedSectionID"), "animations")
    }

    func testSettingsUsesUnifiedTitlebarAndModernStaticPageSurfaces() throws {
        let controller = SettingsWindowController()
        let window = try XCTUnwrap(controller.window)
        controller.show()
        Self.pumpMainRunLoop(for: 0.1)
        defer {
            window.close()
            Self.pumpMainRunLoop(for: 0.05)
        }

        let toolbar = try XCTUnwrap(window.toolbar)
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertTrue(toolbar.isVisible)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        let resetItem = try XCTUnwrap(toolbar.items.first {
            $0.itemIdentifier.rawValue == "StateletSettingsResetWindowSize"
        })
        XCTAssertEqual(resetItem.label, "Reset Window Size")
        XCTAssertNotNil(resetItem.image)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty)

        let sidebar = try Self.settingsSidebar(in: window)
        try Self.selectSidebar(in: sidebar, label: "General")

        let pageTitle = try XCTUnwrap(
            Self.descendants(of: window.contentView)
                .compactMap { $0 as? NSTextField }
                .first { $0.identifier?.rawValue == "SettingsPageTitle" }
        )
        XCTAssertEqual(pageTitle.stringValue, "General")
        XCTAssertEqual(pageTitle.accessibilityLabel(), "General")
        XCTAssertGreaterThanOrEqual(pageTitle.font?.pointSize ?? 0, 20)
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            XCTAssertEqual(pageTitle.accessibilityRole(), .headingRole)
        }
#endif

        let splitViewController = try XCTUnwrap(
            Self.descendants(of: window.contentView)
                .compactMap { $0.nextResponder as? NSSplitViewController }
                .first
        )
        XCTAssertEqual(splitViewController.splitViewItems.count, 2)
        XCTAssertEqual(splitViewController.splitViewItems.first?.behavior, .sidebar)
        XCTAssertEqual(splitViewController.splitViewItems.first?.allowsFullHeightLayout, true)
        let sidebarView = try XCTUnwrap(splitViewController.splitViewItems.first?.viewController.view)
        XCTAssertGreaterThan(sidebarView.safeAreaInsets.top, 0)
        XCTAssertGreaterThan(
            sidebarView.frame.maxY,
            splitViewController.splitView.bounds.maxY - splitViewController.splitView.safeAreaInsets.top
        )

        let cards = Self.descendants(of: window.contentView)
            .compactMap { $0 as? NSVisualEffectView }
            .filter { $0.identifier?.rawValue == "SettingsSectionCard" }
        XCTAssertEqual(cards.count, 4)
        XCTAssertTrue(cards.allSatisfy { $0.material == .contentBackground })
        XCTAssertTrue(cards.allSatisfy { $0.blendingMode == .withinWindow })
        XCTAssertTrue(cards.allSatisfy { ($0.layer?.cornerRadius ?? 0) >= 12 })
        XCTAssertTrue(cards.allSatisfy { $0.accessibilityRole() == .group })
        XCTAssertEqual(
            Set(cards.compactMap { $0.accessibilityLabel() }),
            Set(["Startup", "Pet Window", "Motion and Accessibility", "App and Local Data"])
        )
        for card in cards {
            let title = try XCTUnwrap(
                Self.descendants(of: card).compactMap { $0 as? NSTextField }.first {
                    $0.stringValue == card.accessibilityLabel()
                }
            )
            XCTAssertFalse(title.isAccessibilityElement(), "the group label should be announced once by its card")
        }
        XCTAssertTrue(cards.allSatisfy { Self.descendants(of: $0).count > 3 })
        XCTAssertFalse(
            Self.descendants(of: window.contentView)
                .compactMap { $0 as? NSVisualEffectView }
                .contains { $0.material == .sidebar }
        )
    }

    func testAnimationsAndDialogueVoiceUseConsistentPageHeaders() throws {
        let controller = SettingsWindowController()
        let window = try XCTUnwrap(controller.window)
        controller.show()
        Self.pumpMainRunLoop(for: 0.1)
        defer {
            window.close()
            Self.pumpMainRunLoop(for: 0.05)
        }

        let sidebar = try Self.settingsSidebar(in: window)
        for title in ["Animations", "Dialogue & Voice"] {
            try Self.selectSidebar(in: sidebar, label: title)
            let pageTitle = try XCTUnwrap(
                Self.descendants(of: window.contentView).compactMap { $0 as? NSTextField }.first {
                    $0.identifier?.rawValue == "SettingsPageTitle"
                },
                "missing page header for \(title)"
            )
            XCTAssertEqual(pageTitle.stringValue, title)
            XCTAssertEqual(pageTitle.accessibilityLabel(), title)
            XCTAssertGreaterThanOrEqual(pageTitle.font?.pointSize ?? 0, 20)
        }
    }

    func testSettingsContentClassificationPlacesPreferencesUnderAppAndRepairsUnderSupport() throws {
        let controller = SettingsWindowController()
        let window = try XCTUnwrap(controller.window)
        controller.show()
        Self.pumpMainRunLoop(for: 0.1)
        defer {
            window.close()
            Self.pumpMainRunLoop(for: 0.05)
        }

        let sidebar = try Self.settingsSidebar(in: window)
        try Self.selectSidebar(in: sidebar, label: "General")
        XCTAssertTrue(Self.descendants(of: window.contentView).compactMap { $0 as? NSButton }.contains {
            $0.title == "Start Statelet when I log in"
        })
        XCTAssertFalse(Self.descendants(of: window.contentView).compactMap { $0 as? NSButton }.contains {
            $0.title == "Reveal Logs"
        })

        try Self.selectSidebar(in: sidebar, label: "Diagnostics & Repair")
        XCTAssertFalse(Self.descendants(of: window.contentView).compactMap { $0 as? NSButton }.contains {
            $0.title == "Start Statelet when I log in"
        })
        XCTAssertTrue(Self.descendants(of: window.contentView).compactMap { $0 as? NSButton }.contains {
            $0.title == "Reveal Logs"
        })
        XCTAssertTrue(Self.descendants(of: window.contentView).compactMap { $0 as? NSTextField }.contains {
            $0.stringValue == "Diagnostics & Repair"
        })
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
        try Self.selectSidebar(in: sidebar, label: "Appearance")

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
        try Self.selectSidebar(in: sidebar, label: "Help & Updates")
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
        for section in ["Appearance", "General", "Help & Updates", "Prompt Generator", "Source Requirements"] {
            try Self.selectSidebar(in: sidebar, label: section)
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
            if section == "Help & Updates" {
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
        XCTAssertEqual(sidebar.numberOfRows, 12)
        XCTAssertLessThan(
            try Self.sidebarRow(in: sidebar, label: "Prompt Generator"),
            try Self.sidebarRow(in: sidebar, label: "Help & Updates")
        )

        try Self.selectSidebar(in: sidebar, label: "Help & Updates")
        XCTAssertNotNil(
            Self.descendants(of: window.contentView).compactMap { $0 as? NSTextField }.first {
                $0.stringValue == "Help & Updates"
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

        try Self.selectSidebar(in: sidebar, label: "Prompt Generator")
        XCTAssertNotNil(
            Self.descendants(of: window.contentView).compactMap { $0 as? NSTextField }.first {
                $0.stringValue == "Prompt Generator"
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
        try Self.selectSidebar(in: sidebar, label: "Animations")
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

        let requestedFrameSize = NSSize(width: 720, height: 600)
        window.setFrame(
            NSRect(origin: window.frame.origin, size: requestedFrameSize),
            display: false
        )
        Self.pumpMainRunLoop(for: 0.05)
        XCTAssertEqual(window.frame.width, requestedFrameSize.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, requestedFrameSize.height, accuracy: 1)
        XCTAssertEqual(Self.contentSize(of: window).width, requestedFrameSize.width, accuracy: 1)
        XCTAssertEqual(Self.contentSize(of: window).height, requestedFrameSize.height, accuracy: 1)

        for section in [
            "General",
            "Appearance",
            "Animations",
            "Dialogue & Voice",
            "Prompt Generator",
            "Source Requirements",
            "Help & Updates",
            "Diagnostics & Repair",
        ] {
            try Self.selectSidebar(in: sidebar, label: section)

            XCTAssertEqual(window.frame.width, requestedFrameSize.width, accuracy: 1, "section \(section)")
            XCTAssertEqual(window.frame.height, requestedFrameSize.height, accuracy: 1, "section \(section)")
            XCTAssertEqual(Self.contentSize(of: window).width, requestedFrameSize.width, accuracy: 1, "section \(section)")
            XCTAssertEqual(Self.contentSize(of: window).height, requestedFrameSize.height, accuracy: 1, "section \(section)")
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
        try Self.selectSidebar(in: sidebar, label: "Animations")
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
        sidebarLabelView(in: sidebar, row: row)?.stringValue
    }

    private static func sidebarLabelView(in sidebar: NSTableView, row: Int) -> NSTextField? {
        guard let cell = sidebar.view(atColumn: 0, row: row, makeIfNecessary: true) else { return nil }
        return descendants(of: cell).compactMap { $0 as? NSTextField }.first
    }

    private static func sidebarRow(in sidebar: NSTableView, label: String) throws -> Int {
        try XCTUnwrap(
            (0 ..< sidebar.numberOfRows).first { sidebarLabel(in: sidebar, row: $0) == label },
            "missing sidebar destination \(label)"
        )
    }

    @discardableResult
    private static func selectSidebar(in sidebar: NSTableView, label: String) throws -> Int {
        let row = try sidebarRow(in: sidebar, label: label)
        sidebar.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        pumpMainRunLoop(for: 0.05)
        return row
    }

    private static func contentSize(of window: NSWindow) -> NSSize {
        window.contentView?.bounds.size ?? window.contentLayoutRect.size
    }

    private static func pumpMainRunLoop(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        }
    }
}
