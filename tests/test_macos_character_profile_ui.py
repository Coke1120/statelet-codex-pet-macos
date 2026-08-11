#!/usr/bin/env python3
"""Executable AppKit contracts for character-profile settings UI."""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MAC_SOURCES = ROOT / "mac" / "CodexPetMac" / "Sources"
SELECTOR = MAC_SOURCES / "CodexPetMac" / "CharacterProfileSelectorView.swift"
ANIMATION_LIBRARY = MAC_SOURCES / "CodexPetMac" / "AnimationLibraryView.swift"
CORE_SOURCES = sorted((MAC_SOURCES / "CodexPetCore").glob("*.swift"))


class CharacterProfileUISourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.selector = SELECTOR.read_text(encoding="utf-8")
        cls.library = ANIMATION_LIBRARY.read_text(encoding="utf-8")

    def test_selector_is_compact_and_exposes_character_commands(self) -> None:
        self.assertIn("heightAnchor.constraint(equalToConstant: 28)", self.selector)
        self.assertIn('setAccessibilityLabel("Active character")', self.selector)
        self.assertIn('setAccessibilityLabel("Active character actions")', self.selector)
        for title in (
            "New Character…",
            "Import Bundle…",
            "Rename…",
            "Duplicate…",
            "Export…",
            "Delete…",
        ):
            self.assertIn(f'title: "{title}"', self.selector)

    def test_animation_library_copy_is_character_scoped(self) -> None:
        self.assertIn('characterName: String = "Default"', self.library)
        self.assertIn(
            'stateTitle.stringValue = "\\(characterName) · \\(selectedState.displayName) Animations"',
            self.library,
        )
        self.assertIn(
            'titleLabel.stringValue = "Drop MP4s into \\(characterName) · \\(selectedState.displayName)"',
            self.library,
        )
        self.assertIn('clipsSectionTitle.stringValue = "CLIPS"', self.library)
        self.assertIn(
            'clipsSectionTitle.setAccessibilityLabel("Clips for \\(characterName), \\(selectedState.displayName)")',
            self.library,
        )
        self.assertIn(
            'tableView.setAccessibilityLabel("\\(characterName), \\(selectedState.displayName) animation clips")',
            self.library,
        )


class CharacterProfileUIHarnessTests(unittest.TestCase):
    def test_callbacks_sync_busy_actions_accessibility_and_layout(self) -> None:
        if sys.platform != "darwin":
            self.skipTest("AppKit verification requires macOS")
        swiftc = shutil.which("swiftc")
        self.assertIsNotNone(swiftc, "swiftc is required for the native AppKit harness")

        support_source = textwrap.dedent(
            r'''
            import AppKit
            import CodexPetCore

            extension PetState {
                var displayName: String { rawValue.capitalized }
                var explanation: String { "Lifecycle state: \(rawValue)" }
                var symbolName: String { "circle.fill" }
            }
            '''
        )
        harness_source = textwrap.dedent(
            r'''
            import AppKit
            import CodexPetCore
            import Foundation

            enum HarnessFailure: LocalizedError {
                case failed(String)
                var errorDescription: String? {
                    guard case let .failed(message) = self else { return nil }
                    return message
                }
            }

            @main
            struct CharacterProfileUIHarness {
                static func descendants(of view: NSView) -> [NSView] {
                    view.subviews.flatMap { [$0] + descendants(of: $0) }
                }

                static func require(
                    _ condition: @autoclosure () -> Bool,
                    _ message: String
                ) throws {
                    guard condition() else { throw HarnessFailure.failed(message) }
                }

                @discardableResult
                static func invoke(_ item: NSMenuItem) throws -> Bool {
                    guard let action = item.action else {
                        throw HarnessFailure.failed("menu item \(item.title) has no action")
                    }
                    return NSApplication.shared.sendAction(action, to: item.target, from: item)
                }

                static func main() throws {
                    let application = NSApplication.shared
                    application.setActivationPolicy(.prohibited)

                    let selector = CharacterProfileSelectorView()
                    let profiles = [
                        CharacterProfileSummary(id: "default", name: "Default", clipCount: 4),
                        CharacterProfileSummary(id: "chloe", name: "Chloe", clipCount: 7),
                    ]
                    var events: [String] = []
                    selector.onSelectProfile = { events.append("select:\($0)") }
                    selector.onNewCharacter = { events.append("new") }
                    selector.onRenameActive = { events.append("rename") }
                    selector.onDuplicateActive = { events.append("duplicate") }
                    selector.onDeleteActive = { events.append("delete") }
                    selector.onImportBundle = { events.append("import") }
                    selector.onExportActive = { events.append("export") }

                    selector.update(profiles: profiles, activeID: "default", busy: false)
                    try require(events.isEmpty, "external update fired a callback")

                    let host = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 42))
                    let window = NSWindow(
                        contentRect: host.bounds,
                        styleMask: [.titled],
                        backing: .buffered,
                        defer: false
                    )
                    window.contentView = host
                    host.addSubview(selector)
                    NSLayoutConstraint.activate([
                        selector.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
                        selector.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
                        selector.centerYAnchor.constraint(equalTo: host.centerYAnchor),
                    ])
                    window.layoutIfNeeded()
                    host.layoutSubtreeIfNeeded()
                    selector.layoutSubtreeIfNeeded()

                    let controls = descendants(of: selector)
                    guard let popup = controls.compactMap({ $0 as? NSPopUpButton }).first else {
                        throw HarnessFailure.failed("profile popup not found")
                    }
                    guard let actionsButton = controls.compactMap({ $0 as? NSButton }).first(where: {
                        $0.accessibilityLabel() == "Active character actions"
                    }), let actionsMenu = actionsButton.menu else {
                        throw HarnessFailure.failed("actions button or menu not found")
                    }

                    try require(selector.frame.height <= 32, "selector exceeds the status strip height")
                    try require(!selector.hasAmbiguousLayout, "selector layout is ambiguous")
                    try require(!popup.hasAmbiguousLayout, "profile popup layout is ambiguous")
                    try require(!actionsButton.hasAmbiguousLayout, "actions button layout is ambiguous")
                    try require(popup.accessibilityLabel() == "Active character", "popup label missing")
                    try require(popup.accessibilityHelp() != nil, "popup help missing")
                    try require(actionsButton.accessibilityHelp() != nil, "actions help missing")
                    try require(popup.titleOfSelectedItem?.hasPrefix("Default") == true, "initial profile is wrong")

                    guard let chloeItem = popup.itemArray.first(where: {
                        ($0.representedObject as? String) == "chloe"
                    }) else {
                        throw HarnessFailure.failed("Chloe menu item not found")
                    }
                    let chloeDelivered = try invoke(chloeItem)
                    try require(chloeDelivered, "profile action was not delivered")
                    try require(events == ["select:chloe"], "profile callback was not exactly once")

                    selector.update(profiles: profiles, activeID: "default", busy: false)
                    try require(events == ["select:chloe"], "external sync fired a callback")
                    try require(popup.titleOfSelectedItem?.hasPrefix("Default") == true, "external sync did not restore Default")

                    guard let newItem = popup.itemArray.first(where: { $0.title == "New Character…" }),
                          let importItem = popup.itemArray.first(where: { $0.title == "Import Bundle…" })
                    else { throw HarnessFailure.failed("profile commands are missing") }
                    let newDelivered = try invoke(newItem)
                    let importDelivered = try invoke(importItem)
                    try require(newDelivered, "new action was not delivered")
                    try require(importDelivered, "import action was not delivered")

                    for (title, expected) in [
                        ("Rename…", "rename"),
                        ("Duplicate…", "duplicate"),
                        ("Export…", "export"),
                        ("Delete…", "delete"),
                    ] {
                        guard let item = actionsMenu.item(withTitle: title) else {
                            throw HarnessFailure.failed("\(title) action is missing")
                        }
                        try require(item.isEnabled, "\(title) action should be enabled")
                        let delivered = try invoke(item)
                        try require(delivered, "\(title) action was not delivered")
                        try require(events.filter { $0 == expected }.count == 1, "\(title) callback was not exactly once")
                    }
                    try require(events.filter { $0 == "new" }.count == 1, "new callback was not exactly once")
                    try require(events.filter { $0 == "import" }.count == 1, "import callback was not exactly once")

                    selector.update(profiles: [profiles[0]], activeID: "default", busy: false)
                    guard let deleteItem = actionsButton.menu?.item(withTitle: "Delete…") else {
                        throw HarnessFailure.failed("delete action disappeared")
                    }
                    try require(!deleteItem.isEnabled, "last-character delete is enabled")

                    selector.update(profiles: profiles, activeID: "chloe", busy: true)
                    try require(!popup.isEnabled, "busy popup is enabled")
                    try require(!actionsButton.isEnabled, "busy actions button is enabled")
                    try require(
                        actionsButton.menu?.items.filter({ !$0.isSeparatorItem }).allSatisfy({ !$0.isEnabled }) == true,
                        "busy action menu contains an enabled command"
                    )
                    try require(events.count == 7, "busy/external updates fired callbacks")

                    let mediaDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("statelet-character-copy-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: mediaDirectory) }
                    let clip = mediaDirectory.appendingPathComponent("idle.mov")
                    try Data([0]).write(to: clip)
                    let playlist = try StateMediaPlaylist(entries: [try MediaEntry(path: clip.path)])
                    let mediaMap = try MediaMap(states: [.idle: playlist])
                    let library = AnimationLibraryView(frame: NSRect(x: 0, y: 0, width: 660, height: 392))
                    library.update(
                        selectedState: .idle,
                        currentState: .idle,
                        playlist: playlist,
                        counts: [.idle: 1],
                        mapURL: mediaDirectory.appendingPathComponent("media-map.json"),
                        mediaMap: mediaMap,
                        preview: nil,
                        reduceMotion: false,
                        busy: false,
                        importEnabled: true,
                        characterName: "Chloe"
                    )
                    let libraryLabels = descendants(of: library).compactMap { $0 as? NSTextField }
                    try require(
                        libraryLabels.contains(where: { $0.stringValue == "Chloe · Idle Animations" }),
                        "state title is not character-scoped"
                    )
                    try require(
                        libraryLabels.contains(where: { $0.stringValue == "Drop MP4s into Chloe · Idle" }),
                        "drop-zone copy is not character-scoped"
                    )
                    try require(
                        libraryLabels.contains(where: { $0.stringValue == "CLIPS" }),
                        "clips heading is missing"
                    )
                    try require(
                        libraryLabels.contains(where: { $0.stringValue.hasPrefix("No idle clips for Chloe.") }),
                        "empty-state copy is not character-scoped"
                    )
                    guard let table = descendants(of: library).compactMap({ $0 as? NSTableView }).first else {
                        throw HarnessFailure.failed("animation table not found")
                    }
                    try require(
                        table.accessibilityLabel() == "Chloe, Idle animation clips",
                        "animation table accessibility is not character-scoped"
                    )

                    library.update(
                        selectedState: .idle,
                        currentState: .idle,
                        playlist: playlist,
                        counts: [.idle: 1],
                        mapURL: mediaDirectory.appendingPathComponent("media-map.json"),
                        mediaMap: mediaMap,
                        preview: nil,
                        reduceMotion: false,
                        busy: false,
                        importEnabled: true,
                        characterName: "Nova"
                    )
                    try require(
                        table.accessibilityLabel() == "Nova, Idle animation clips",
                        "rename-only update left the animation table accessibility label stale"
                    )
                    try require(
                        table.accessibilityHelp() == "1 clips for Nova, Idle. Use the arrow keys to select a clip, or double-click a row to preview it.",
                        "rename-only update left the animation table accessibility help stale"
                    )
                    print("character-profile-ui-ok")
                }
            }
            '''
        )

        with tempfile.TemporaryDirectory(prefix="statelet-character-ui-") as temporary:
            temporary_path = Path(temporary)
            support = temporary_path / "PreviewSupport.swift"
            harness = temporary_path / "CharacterProfileUIHarness.swift"
            module = temporary_path / "CodexPetCore.swiftmodule"
            library = temporary_path / "libCodexPetCore.dylib"
            executable = temporary_path / "character-profile-ui-harness"
            support.write_text(support_source, encoding="utf-8")
            harness.write_text(harness_source, encoding="utf-8")

            compile_core = subprocess.run(
                [
                    swiftc,
                    "-parse-as-library",
                    "-emit-library",
                    "-emit-module",
                    "-module-name",
                    "CodexPetCore",
                    *map(str, CORE_SOURCES),
                    "-emit-module-path",
                    str(module),
                    "-o",
                    str(library),
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=60,
            )
            self.assertEqual(compile_core.returncode, 0, compile_core.stderr)

            compile_harness = subprocess.run(
                [
                    swiftc,
                    "-parse-as-library",
                    "-I",
                    str(temporary_path),
                    "-L",
                    str(temporary_path),
                    "-lCodexPetCore",
                    str(SELECTOR),
                    str(ANIMATION_LIBRARY),
                    str(support),
                    str(harness),
                    "-framework",
                    "AppKit",
                    "-Xlinker",
                    "-rpath",
                    "-Xlinker",
                    str(temporary_path),
                    "-o",
                    str(executable),
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=60,
            )
            self.assertEqual(compile_harness.returncode, 0, compile_harness.stderr)

            result = subprocess.run(
                [str(executable)],
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "character-profile-ui-ok")


if __name__ == "__main__":
    unittest.main()
