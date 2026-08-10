#!/usr/bin/env python3
"""Regression contracts for the native Animations settings layout."""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ANIMATION_LIBRARY = (
    ROOT
    / "mac"
    / "CodexPetMac"
    / "Sources"
    / "CodexPetMac"
    / "AnimationLibraryView.swift"
)
CORE_SOURCES = sorted(
    (ROOT / "mac" / "CodexPetMac" / "Sources" / "CodexPetCore").glob("*.swift")
)


class MacAnimationLibraryUISourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = ANIMATION_LIBRARY.read_text(encoding="utf-8")

    def test_drop_target_is_a_compact_import_strip(self) -> None:
        self.assertIn("static let importStripHeight: CGFloat = 48", self.source)
        self.assertIn(
            "heightAnchor.constraint(equalToConstant: AnimationLibraryLayout.importStripHeight)",
            self.source,
        )
        self.assertIn('systemSymbolName: "square.and.arrow.down"', self.source)
        self.assertIn("detailLabel.maximumNumberOfLines = 1", self.source)

    def test_clip_list_remains_visible_and_identified_per_state(self) -> None:
        self.assertIn('labelWithString: "CLIPS"', self.source)
        self.assertIn("private let clipsCountLabel", self.source)
        self.assertIn("static let minimumClipListHeight: CGFloat = 160", self.source)
        self.assertIn(
            "greaterThanOrEqualToConstant: AnimationLibraryLayout.minimumClipListHeight",
            self.source,
        )
        self.assertIn("minimumClipListHeight.priority = NSLayoutConstraint.Priority(999)", self.source)
        self.assertIn('let clipNoun = clipRows.count == 1 ? "clip" : "clips"', self.source)
        self.assertIn(
            'clipsCountLabel.stringValue = "\\(clipRows.count) \\(clipNoun)"',
            self.source,
        )
        self.assertIn(
            'clipsCountLabel.setAccessibilityLabel("\\(clipRows.count) \\(clipNoun) for \\(selectedState.displayName)")',
            self.source,
        )

    def test_mode_help_does_not_compete_with_the_clip_list_for_height(self) -> None:
        self.assertIn("modeHelp.maximumNumberOfLines = 1", self.source)
        self.assertIn("modeHelp.lineBreakMode = .byTruncatingTail", self.source)
        self.assertIn("modeHelp.toolTip = modeHelp.stringValue", self.source)

    def test_mixed_drop_keeps_valid_mp4s_and_reports_each_rejection(self) -> None:
        self.assertIn("struct MP4ImportRejection", self.source)
        self.assertIn("case accepted([URL], rejected: [MP4ImportRejection])", self.source)
        self.assertIn("rejections.append(", self.source)
        self.assertIn("Skipped \\(rejected.count)", self.source)
        self.assertIn("onImport?(urls)", self.source)


class MacAnimationLibraryUILayoutTests(unittest.TestCase):
    def test_minimum_window_layout_and_state_switch(self) -> None:
        if sys.platform != "darwin":
            self.skipTest("AppKit layout verification requires macOS")
        swiftc = shutil.which("swiftc")
        self.assertIsNotNone(swiftc, "swiftc is required for the native AppKit layout test")

        support_source = textwrap.dedent(
            r'''
            import AppKit
            import CodexPetCore

            extension PetState {
                var displayName: String { rawValue.capitalized }

                var explanation: String {
                    switch self {
                    case .idle: return "No active Codex turn"
                    case .running: return "Codex is working"
                    case .waiting: return "Codex needs input or permission"
                    case .review: return "Tests, lint, or review"
                    }
                }

                var symbolName: String {
                    switch self {
                    case .idle: return "moon.stars"
                    case .running: return "bolt.fill"
                    case .waiting: return "hand.raised.fill"
                    case .review: return "checkmark.seal.fill"
                    }
                }
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
            struct AnimationLibraryLayoutHarness {
                static func descendants(of view: NSView) -> [NSView] {
                    view.subviews.flatMap { [$0] + descendants(of: $0) }
                }

                static func require(
                    _ condition: @autoclosure () -> Bool,
                    _ message: String
                ) throws {
                    guard condition() else { throw HarnessFailure.failed(message) }
                }

                static func main() throws {
                    let application = NSApplication.shared
                    application.setActivationPolicy(.prohibited)

                    let mediaDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent(
                            "statelet-animation-layout-test-\(UUID().uuidString)",
                            isDirectory: true
                        )
                    try FileManager.default.createDirectory(
                        at: mediaDirectory,
                        withIntermediateDirectories: true
                    )
                    defer { try? FileManager.default.removeItem(at: mediaDirectory) }

                    let acceptedMP4 = mediaDirectory.appendingPathComponent("accepted.mp4")
                    let rejectedMOV = mediaDirectory.appendingPathComponent("rejected.mov")
                    let emptyMP4 = mediaDirectory.appendingPathComponent("empty.mp4")
                    try Data([1]).write(to: acceptedMP4)
                    try Data([1]).write(to: rejectedMOV)
                    try Data().write(to: emptyMP4)
                    switch MP4ImportURLValidator.validate([rejectedMOV, acceptedMP4, emptyMP4]) {
                    case let .accepted(urls, rejected):
                        try require(urls == [acceptedMP4], "mixed import lost its valid MP4")
                        try require(rejected.count == 2, "mixed import did not report every rejection")
                    case let .rejected(reason):
                        throw HarnessFailure.failed("mixed import rejected the valid MP4: \(reason)")
                    }

                    func entries(prefix: String, count: Int) throws -> [MediaEntry] {
                        try (1...count).map { index in
                            let url = mediaDirectory.appendingPathComponent(
                                "\(prefix)-\(index).mov"
                            )
                            try Data([0]).write(to: url, options: .atomic)
                            return try MediaEntry(path: url.path)
                        }
                    }

                    let idlePlaylist = try StateMediaPlaylist(
                        mode: .sequential,
                        advanceOn: .clipEnd,
                        entries: entries(prefix: "idle", count: 3)
                    )
                    let runningPlaylist = try StateMediaPlaylist(
                        mode: .random,
                        entries: entries(prefix: "running", count: 2)
                    )
                    let mediaMap = try MediaMap(states: [
                        .idle: idlePlaylist,
                        .running: runningPlaylist,
                    ])
                    let counts: [PetState: Int] = [
                        .idle: 3,
                        .running: 2,
                        .waiting: 0,
                        .review: 0,
                    ]

                    // 660x392 is the Animations library's constrained size in the
                    // 700x570 minimum Settings content area with its activity row shown.
                    let view = AnimationLibraryView(
                        frame: NSRect(x: 0, y: 0, width: 660, height: 392)
                    )
                    func apply(_ state: PetState) {
                        view.update(
                            selectedState: state,
                            currentState: .running,
                            playlist: mediaMap.playlist(for: state),
                            counts: counts,
                            mapURL: mediaDirectory.appendingPathComponent("media-map.json"),
                            mediaMap: mediaMap,
                            preview: nil,
                            reduceMotion: false,
                            busy: false,
                            importEnabled: true
                        )
                    }
                    view.onStateSelection = { state in apply(state) }
                    apply(.idle)

                    let host = NSView(frame: view.bounds)
                    let window = NSWindow(
                        contentRect: host.bounds,
                        styleMask: [.titled],
                        backing: .buffered,
                        defer: false
                    )
                    window.contentView = host
                    host.addSubview(view)
                    NSLayoutConstraint.activate([
                        view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                        view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                        view.topAnchor.constraint(equalTo: host.topAnchor),
                        view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                    ])
                    window.layoutIfNeeded()
                    host.layoutSubtreeIfNeeded()
                    view.layoutSubtreeIfNeeded()

                    let descendants = descendants(of: view)
                    guard let dropZone = descendants.first(where: {
                        String(describing: type(of: $0)) == "MP4DropZoneView"
                    }) else {
                        throw HarnessFailure.failed("drop zone not found")
                    }
                    guard let clipsScrollView = descendants
                        .compactMap({ $0 as? NSScrollView })
                        .first(where: { $0.documentView is NSTableView }),
                        let tableView = clipsScrollView.documentView as? NSTableView
                    else {
                        throw HarnessFailure.failed("clip list not found")
                    }
                    guard let clipsCountLabel = descendants
                        .compactMap({ $0 as? NSTextField })
                        .first(where: { $0.stringValue == "3 clips" })
                    else {
                        throw HarnessFailure.failed("idle clip count not found")
                    }

                    try require(
                        abs(dropZone.frame.height - 48) < 0.5,
                        "drop zone is not 48 points high"
                    )
                    try require(
                        clipsScrollView.frame.height >= 159.5,
                        "clip list collapsed below 160 points"
                    )
                    try require(tableView.numberOfRows == 3, "idle rows were not loaded")
                    try require(!view.hasAmbiguousLayout, "animation library layout is ambiguous")
                    try require(!dropZone.hasAmbiguousLayout, "drop zone layout is ambiguous")
                    try require(
                        !clipsScrollView.hasAmbiguousLayout,
                        "clip list layout is ambiguous"
                    )

                    guard let runningButton = descendants
                        .compactMap({ $0 as? NSButton })
                        .first(where: {
                            $0.accessibilityLabel()?.hasPrefix("Running, 2 clips") == true
                        })
                    else {
                        throw HarnessFailure.failed("running state button not found")
                    }
                    runningButton.performClick(nil)
                    window.layoutIfNeeded()
                    view.layoutSubtreeIfNeeded()

                    try require(
                        tableView.numberOfRows == 2,
                        "running rows were not loaded after state switch"
                    )
                    try require(
                        clipsCountLabel.stringValue == "2 clips",
                        "clip count did not refresh after state switch"
                    )
                    try require(
                        tableView.accessibilityLabel() == "Running animation clips",
                        "clip list accessibility label did not refresh after state switch"
                    )
                    print("layout-ok")
                }
            }
            '''
        )

        with tempfile.TemporaryDirectory(prefix="statelet-animation-layout-") as temporary:
            temporary_path = Path(temporary)
            support = temporary_path / "PreviewSupport.swift"
            harness = temporary_path / "LayoutHarness.swift"
            module = temporary_path / "CodexPetCore.swiftmodule"
            library = temporary_path / "libCodexPetCore.dylib"
            executable = temporary_path / "animation-layout-harness"
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
            self.assertEqual(result.stdout.strip(), "layout-ok")


if __name__ == "__main__":
    unittest.main()
