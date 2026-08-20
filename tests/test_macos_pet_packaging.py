#!/usr/bin/env python3
"""Production packaging tests for the board-independent macOS companion."""

from __future__ import annotations

import json
import hashlib
import os
import plistlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "mac" / "CodexPetMac"
BUILD_SCRIPT = PACKAGE / "scripts" / "build_app.sh"
INSTALL_SCRIPT = PACKAGE / "scripts" / "install.sh"
UNINSTALL_SCRIPT = PACKAGE / "scripts" / "uninstall.sh"
ALPHA_COORDINATOR = PACKAGE / "Sources" / "CodexPetMac" / "AlphaConversion.swift"
STATELET_IDENTITY = PACKAGE / "Sources" / "CodexPetMac" / "StateletIdentity.swift"
PET_APP_DELEGATE = PACKAGE / "Sources" / "CodexPetMac" / "PetAppDelegate.swift"
PET_PANEL = PACKAGE / "Sources" / "CodexPetMac" / "PetPanel.swift"
PET_PLAYER = PACKAGE / "Sources" / "CodexPetMac" / "PetPlayer.swift"
ANIMATION_LIBRARY = PACKAGE / "Sources" / "CodexPetMac" / "AnimationLibraryView.swift"
RUNTIME_EFFICIENCY = PACKAGE / "Sources" / "CodexPetCore" / "RuntimeEfficiency.swift"
SETTINGS_CONTROLLER = PACKAGE / "Sources" / "CodexPetMac" / "SettingsWindowController.swift"
MAC_MAIN = PACKAGE / "Sources" / "CodexPetMac" / "main.swift"
MANAGED_MARKER = "statelet-v2"
LEGACY_MARKER = "mac-widget-v1"
HOOK_EVENTS = (
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PermissionRequest",
    "PreCompact",
    "PostCompact",
    "SubagentStart",
    "SubagentStop",
    "Stop",
)


class MacPetPackagingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.home = self.base / "home"
        self.home.mkdir()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def make_bundle(self, name: str, payload: str = "bundle") -> Path:
        executable = self.base / f"{name}-executable"
        executable.write_text(f"#!/bin/sh\n# {payload}\nexit 0\n", encoding="utf-8")
        executable.chmod(0o755)
        bundle = self.base / f"{name}.app"
        subprocess.run(
            [
                "bash",
                str(BUILD_SCRIPT),
                "--output",
                str(bundle),
                "--executable",
                str(executable),
                "--skip-sign",
            ],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        return bundle

    def make_legacy_bundle(self, name: str, payload: str = "legacy") -> Path:
        canonical = self.make_bundle(name, payload)
        bundle = self.base / f"{name}-legacy.app"
        shutil.copytree(canonical, bundle)
        info_path = bundle / "Contents" / "Info.plist"
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
        info.update(
            {
                "CFBundleExecutable": "CodexPetMac",
                "CFBundleName": "CodexPetMac",
                "CFBundleIdentifier": "com.coke1120.CodexPetMac",
                "CodexPetManaged": LEGACY_MARKER,
            }
        )
        info.pop("StateletManaged", None)
        info_path.write_bytes(plistlib.dumps(info))
        (bundle / "Contents" / "MacOS" / "Statelet").rename(
            bundle / "Contents" / "MacOS" / "CodexPetMac"
        )
        return bundle

    def install(self, bundle: Path, *extra: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        command = [
            "bash",
            str(INSTALL_SCRIPT),
            "--home",
            str(self.home),
            "--app-bundle",
            str(bundle),
            "--skip-launchctl",
            *extra,
        ]
        return subprocess.run(
            command,
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )

    def journal_command(self, root: Path, command: str, *args: str) -> subprocess.CompletedProcess[str]:
        source = INSTALL_SCRIPT.read_text(encoding="utf-8")
        start = source.index("import ctypes,", source.index("journal_command()"))
        end = source.index("\nPY\n}", start)
        return subprocess.run(
            [sys.executable, "-", str(root), str(self.home), command, *args],
            input=source[start:end],
            check=False,
            capture_output=True,
            text=True,
        )

    def safe_tree_digest(self, path: Path) -> str:
        result = subprocess.run(
            [sys.executable, str(PACKAGE / "scripts" / "merge_hooks.py"), "--safe-tree-digest", str(path)],
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()

    def fake_launchctl_environment(
        self,
        *loaded_labels: str,
        fail_action: str = "",
        fail_label: str = "",
        delay_label: str = "",
    ) -> tuple[dict[str, str], Path]:
        fake_bin = self.base / f"fake-bin-{len(list(self.base.glob('fake-bin-*')))}"
        fake_bin.mkdir()
        state = fake_bin / "state"
        state.mkdir()
        for label in loaded_labels:
            (state / label).touch()
        log = fake_bin / "launchctl.log"
        launchctl = fake_bin / "launchctl"
        launchctl.write_text(
            """#!/bin/bash
set -u
printf '%s\\n' "$*" >> "$CODEX_PET_FAKE_LAUNCH_LOG"
action="$1"
case "$action" in
  print)
    label="${2##*/}"
    [[ -f "$CODEX_PET_FAKE_LAUNCH_STATE/$label" ]]
    ;;
  bootout|bootstrap)
    if [[ "$action" == "bootout" ]]; then
      label="${2##*/}"
    else
      plist="$3"
      label="$(basename "$plist" .plist)"
    fi
    if [[ "$action" == "$CODEX_PET_FAKE_FAIL_ACTION" && "$label" == "$CODEX_PET_FAKE_FAIL_LABEL" ]]; then
      exit 64
    fi
    if [[ "$label" == "$CODEX_PET_FAKE_DELAY_LABEL" ]]; then
      if [[ "$action" == "bootout" ]]; then
        (/bin/sleep 0.15; rm -f "$CODEX_PET_FAKE_LAUNCH_STATE/$label") >/dev/null 2>&1 &
      else
        (/bin/sleep 0.15; touch "$CODEX_PET_FAKE_LAUNCH_STATE/$label") >/dev/null 2>&1 &
      fi
      exit 0
    fi
    if [[ "$action" == "bootout" ]]; then
      rm -f "$CODEX_PET_FAKE_LAUNCH_STATE/$label"
      if [[ "$label" == "${STATELET_FAKE_BOOTOUT_TAMPER_LABEL:-}" && -n "${STATELET_FAKE_BOOTOUT_TAMPER_PATH:-}" ]]; then
        printf '\n# tampered after bootout\n' >> "$STATELET_FAKE_BOOTOUT_TAMPER_PATH"
      elif [[ "$label" == "${STATELET_FAKE_BOOTOUT_REPLACE_LABEL:-}" && -n "${STATELET_FAKE_BOOTOUT_REPLACE_PATH:-}" ]]; then
        cp -p "$STATELET_FAKE_BOOTOUT_REPLACE_PATH" "$STATELET_FAKE_BOOTOUT_REPLACE_PATH.replacement"
        mv -f "$STATELET_FAKE_BOOTOUT_REPLACE_PATH.replacement" "$STATELET_FAKE_BOOTOUT_REPLACE_PATH"
      elif [[ "$label" == "${STATELET_FAKE_BOOTOUT_REPARENT_LABEL:-}" && -n "${STATELET_FAKE_BOOTOUT_REPARENT_PATH:-}" ]]; then
        parent="$(dirname "$STATELET_FAKE_BOOTOUT_REPARENT_PATH")"
        displaced="$parent.displaced"
        mv "$parent" "$displaced"
        mkdir "$parent"
        mv "$displaced/$(basename "$STATELET_FAKE_BOOTOUT_REPARENT_PATH")" "$STATELET_FAKE_BOOTOUT_REPARENT_PATH"
      fi
    else
      touch "$CODEX_PET_FAKE_LAUNCH_STATE/$label"
      if [[ "$label" == "${STATELET_FAKE_WRITER_LABEL:-}" && -n "${STATELET_FAKE_WRITER_SCRIPT:-}" ]]; then
        mkdir -p "$(dirname "$STATELET_FAKE_WRITER_OUTPUT")" "$(dirname "$STATELET_FAKE_WRITER_STDOUT")"
        if [[ -n "${STATELET_FAKE_WRITER_TRANSACTION:-}" ]]; then
          "$STATELET_FAKE_WRITER_PYTHON" - "$STATELET_FAKE_WRITER_TRANSACTION/journal.json" "$STATELET_FAKE_WRITER_PHASE" <<'PY'
import json, sys
from pathlib import Path
journal, output = map(Path, sys.argv[1:])
output.write_text(json.loads(journal.read_text(encoding="utf-8"))["state"] + "\\n", encoding="utf-8")
PY
        fi
        "$STATELET_FAKE_WRITER_PYTHON" -B "$STATELET_FAKE_WRITER_SCRIPT" \
          --once --state-dir "$STATELET_FAKE_WRITER_SESSIONS" --output "$STATELET_FAKE_WRITER_OUTPUT" \
          >>"$STATELET_FAKE_WRITER_STDOUT" 2>>"$STATELET_FAKE_WRITER_STDERR"
      fi
      if [[ "$label" == "${STATELET_FAKE_TAMPER_LABEL:-}" && -n "${STATELET_FAKE_TAMPER_PATH:-}" ]]; then
        printf '\n# tampered after file commit\n' >> "$STATELET_FAKE_TAMPER_PATH"
      fi
    fi
    ;;
  *) exit 2 ;;
esac
""",
            encoding="utf-8",
        )
        launchctl.chmod(0o755)
        environment = os.environ.copy()
        environment.update(
            {
                "HOME": str(self.home),
                "PATH": f"{fake_bin}:{environment['PATH']}",
                "CODEX_PET_FAKE_LAUNCH_LOG": str(log),
                "CODEX_PET_FAKE_LAUNCH_STATE": str(state),
                "CODEX_PET_FAKE_FAIL_ACTION": fail_action,
                "CODEX_PET_FAKE_FAIL_LABEL": fail_label,
                "CODEX_PET_FAKE_DELAY_LABEL": delay_label,
            }
        )
        return environment, log

    def enable_fake_runtime_writer(self, environment: dict[str, str]) -> Path:
        support = self.home / "Library" / "Application Support" / "Statelet"
        phase = self.base / "writer-transaction-phase.txt"
        environment.update(
            {
                "STATELET_FAKE_WRITER_LABEL": "com.coke1120.statelet.state-aggregator",
                "STATELET_FAKE_WRITER_PYTHON": sys.executable,
                "STATELET_FAKE_WRITER_SCRIPT": str(support / "Statelet" / "python" / "statelet_state_aggregator.py"),
                "STATELET_FAKE_WRITER_SESSIONS": str(support / "sessions"),
                "STATELET_FAKE_WRITER_OUTPUT": str(support / "runtime" / "current_state.json"),
                "STATELET_FAKE_WRITER_STDOUT": str(support / "logs" / "state-aggregator.out.log"),
                "STATELET_FAKE_WRITER_STDERR": str(support / "logs" / "state-aggregator.err.log"),
                "STATELET_FAKE_WRITER_TRANSACTION": str(self.home / ".statelet-install-transaction"),
                "STATELET_FAKE_WRITER_PHASE": str(phase),
            }
        )
        return phase

    def recompute_transaction_seal(self, journal: dict[str, object]) -> None:
        operations = journal["operations"]
        self.assertIsInstance(operations, list)
        active: list[int] = []
        for index, operation in enumerate(operations):
            if operation.get("kind") not in {"backup", "install"}:
                continue
            target = Path(operation["target"])
            active = [owner for owner in active if not Path(operations[owner]["target"]).is_relative_to(target)]
            if operation["kind"] == "install":
                active.append(index)
        launch = journal["launch"]
        sealed_launch = (
            {"skipped": True}
            if launch == {"skipped": True}
            else {"labels": launch["labels"], "plists": launch["plists"], "desired": launch["desired"]}
        )
        payload = {
            "operations": operations,
            "operation_count": len(operations),
            "active_targets": [operations[index]["target"] for index in active],
            "handoff": journal["handoff"],
            "launch": sealed_launch,
        }
        journal["seal"] = {
            "version": 1,
            "operation_count": payload["operation_count"],
            "active_targets": payload["active_targets"],
            "digest": hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
        }

    def assert_sealed_operation_tamper_is_rejected(self, *, skip_launchctl: bool, empty: bool) -> None:
        first = self.make_bundle(f"SealFirst-{skip_launchctl}-{empty}", "first")
        second = self.make_bundle(f"SealSecond-{skip_launchctl}-{empty}", "second")
        if skip_launchctl:
            self.assertEqual(self.install(first).returncode, 0)
            environment = os.environ.copy()
            environment["STATELET_INSTALL_CRASH_AT"] = "after-files-commit"
            crashed = self.install(second, env=environment)
        else:
            environment, _ = self.fake_launchctl_environment()
            self.assertEqual(
                subprocess.run(
                    ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(first)],
                    cwd=ROOT,
                    check=False,
                    capture_output=True,
                    text=True,
                    env=environment,
                ).returncode,
                0,
            )
            environment["STATELET_INSTALL_CRASH_AT"] = "after-files-commit"
            crashed = subprocess.run(
                ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(second)],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
        self.assertEqual(crashed.returncode, -9, crashed.stderr)
        transaction = self.home / ".statelet-install-transaction"
        journal_path = transaction / "journal.json"
        journal = json.loads(journal_path.read_text(encoding="utf-8"))
        self.assertEqual(journal["state"], "files-committed")
        self.assertTrue(any((transaction / "backup").rglob("*")))
        journal["operations"] = [] if empty else journal["operations"][:-1]
        self.recompute_transaction_seal(journal)
        journal_path.write_text(json.dumps(journal, separators=(",", ":")) + "\n", encoding="utf-8")
        journal_path.chmod(0o600)
        environment.pop("STATELET_INSTALL_CRASH_AT")

        if skip_launchctl:
            refused = self.install(second, env=environment)
        else:
            refused = subprocess.run(
                ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(second)],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )

        self.assertEqual(refused.returncode, 74, refused.stderr)
        self.assertIn("interrupted Statelet installation is ambiguous", refused.stderr)
        self.assertTrue(transaction.exists())
        self.assertTrue(any((transaction / "backup").rglob("*")))

    def test_bundle_info_contract_and_public_payload(self) -> None:
        bundle = self.make_bundle("InfoContract")
        with (bundle / "Contents" / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)

        self.assertEqual(info["CFBundleExecutable"], "Statelet")
        self.assertEqual(info["CFBundleName"], "Statelet")
        self.assertEqual(info["CFBundleIdentifier"], "com.coke1120.Statelet")
        self.assertEqual(info["CFBundleDisplayName"], "Statelet")
        self.assertEqual(info["CFBundleIconFile"], "Statelet.icns")
        self.assertEqual(
            info["CFBundleGetInfoString"],
            "Statelet — a local-first Codex lifecycle companion for macOS",
        )
        self.assertEqual(
            info["NSHumanReadableCopyright"],
            "Copyright © 2026 Statelet contributors. MIT licensed.",
        )
        self.assertEqual(info["CFBundleShortVersionString"], "1.8.11")
        self.assertEqual(info["CFBundleVersion"], "25")
        self.assertEqual(info["CFBundlePackageType"], "APPL")
        self.assertEqual(info["LSMinimumSystemVersion"], "13.0")
        self.assertTrue(info["LSUIElement"])
        self.assertEqual(info["StateletManaged"], MANAGED_MARKER)
        self.assertNotIn("CodexPetManaged", info)
        self.assertTrue((bundle / "Contents" / "MacOS" / "Statelet").stat().st_mode & 0o111)
        icon = bundle / "Contents" / "Resources" / "Statelet.icns"
        self.assertTrue(icon.is_file())
        self.assertTrue(os.access(icon, os.R_OK))
        self.assertGreater(icon.stat().st_size, 0)
        menu_icon = bundle / "Contents" / "Resources" / "StateletMenuBarTemplate.pdf"
        self.assertTrue(menu_icon.is_file())
        self.assertTrue(os.access(menu_icon, os.R_OK))
        self.assertGreater(menu_icon.stat().st_size, 0)

        alpha_tools = bundle / "Contents" / "Resources" / "AlphaTools"
        expected_alpha_resources = {
            "convert_codex_pet_macos_alpha.py",
            "codex_pet_alpha.py",
            "requirements-alpha.txt",
        }
        self.assertEqual(
            {path.name for path in alpha_tools.iterdir() if path.is_file()},
            expected_alpha_resources,
        )
        for resource in expected_alpha_resources:
            path = alpha_tools / resource
            self.assertTrue(os.access(path, os.R_OK))
            self.assertFalse(path.stat().st_mode & 0o111)

        qwen_tools = bundle / "Contents" / "Resources" / "QwenTTS"
        expected_qwen_resources = {"qwen3_tts_generate.py", "qwen3_tts_probe.py"}
        self.assertEqual(
            {path.name for path in qwen_tools.iterdir() if path.is_file()},
            expected_qwen_resources,
        )
        for resource in expected_qwen_resources:
            path = qwen_tools / resource
            self.assertTrue(os.access(path, os.R_OK))
            self.assertFalse(path.stat().st_mode & 0o111)

        voxcpm2_tools = bundle / "Contents" / "Resources" / "VoxCPM2"
        expected_voxcpm2_resources = {"voxcpm2_generate.py", "voxcpm2_probe.py"}
        self.assertEqual(
            {path.name for path in voxcpm2_tools.iterdir() if path.is_file()},
            expected_voxcpm2_resources,
        )
        for resource in expected_voxcpm2_resources:
            path = voxcpm2_tools / resource
            self.assertTrue(os.access(path, os.R_OK))
            self.assertFalse(path.stat().st_mode & 0o111)
        self.assertFalse([path for path in bundle.rglob("__pycache__")])
        self.assertFalse([path for path in bundle.rglob("*.pyc")])

        forbidden = {
            ".mp4", ".mov", ".gif", ".apng", ".webm", ".mkv",
            ".safetensors", ".ckpt", ".pth", ".wav", ".flac", ".mp3",
        }
        self.assertFalse(
            [path for path in bundle.rglob("*") if path.is_file() and path.suffix.lower() in forbidden]
        )
        bundle_payload = b"".join(
            path.read_bytes() for path in bundle.rglob("*") if path.is_file()
        )
        for private_prefix in (str(ROOT), str(Path.home()), "/Users/", "/private/tmp/"):
            self.assertNotIn(private_prefix.encode(), bundle_payload)
        self.assertNotIn(b"STATELET_PRIVATE_VOICE_FIXTURE", bundle_payload)

    def test_default_bundle_and_symbol_destinations_are_statelet(self) -> None:
        source = BUILD_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('output="$package_dir/dist/Statelet.app"', source)
        self.assertIn('symbols_output="${output}.dSYM"', source)
        install_source = INSTALL_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('app_bundle="$package_dir/dist/Statelet.app"', install_source)
        self.assertIn('app_dest="$applications_dir/Statelet.app"', install_source)

    def test_readmes_use_statelet_as_the_product_name(self) -> None:
        for readme in (ROOT / "README.md", PACKAGE / "README.md"):
            with self.subTest(readme=readme.relative_to(ROOT)):
                source = readme.read_text(encoding="utf-8")
                self.assertTrue(source.startswith("# Statelet"))
                self.assertNotIn("Codex Pet for macOS", source)
                self.assertNotIn("Codex Pet Mac", source)

    def test_runtime_converter_cannot_mutate_signed_bundle_with_python_bytecode(self) -> None:
        source = ALPHA_COORDINATOR.read_text(encoding="utf-8")
        self.assertIn('"-B",\n            toolchain.converter.path', source)
        self.assertIn('"PYTHONDONTWRITEBYTECODE": "1"', source)

    def test_pet_panel_switches_window_level_without_losing_space_behavior(self) -> None:
        if sys.platform != "darwin":
            self.skipTest("PetPanel AppKit verification requires macOS")
        swiftc = shutil.which("swiftc")
        self.assertIsNotNone(swiftc)
        with tempfile.TemporaryDirectory(prefix="statelet-pet-panel-") as temporary:
            temp = Path(temporary)
            harness = temp / "PetPanelHarness.swift"
            harness.write_text(
                r'''
import AppKit

@main
struct PetPanelHarness {
    static func main() {
        _ = NSApplication.shared
        let panel = PetPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            alwaysOnTop: true,
            fullScreenAuxiliary: true
        )
        guard panel.level == .floating, panel.isFloatingPanel else { exit(1) }
        guard panel.collectionBehavior.contains(.canJoinAllSpaces) else { exit(2) }
        guard panel.collectionBehavior.contains(.ignoresCycle) else { exit(3) }
        guard panel.collectionBehavior.contains(.fullScreenAuxiliary) else { exit(4) }

        panel.apply(alwaysOnTop: false, fullScreenAuxiliary: true)
        guard panel.level == .normal, !panel.isFloatingPanel else { exit(5) }
        guard panel.collectionBehavior.contains(.canJoinAllSpaces) else { exit(6) }
        guard panel.collectionBehavior.contains(.ignoresCycle) else { exit(7) }
        guard panel.collectionBehavior.contains(.fullScreenAuxiliary) else { exit(8) }

        panel.apply(alwaysOnTop: true, fullScreenAuxiliary: false)
        guard panel.level == .floating, panel.isFloatingPanel else { exit(9) }
        guard panel.collectionBehavior.contains(.canJoinAllSpaces) else { exit(10) }
        guard panel.collectionBehavior.contains(.ignoresCycle) else { exit(11) }
        guard !panel.collectionBehavior.contains(.fullScreenAuxiliary) else { exit(12) }
        print("pet-panel-level-ok")
    }
}
''',
                encoding="utf-8",
            )
            executable = temp / "pet-panel-harness"
            compiled = subprocess.run(
                [
                    swiftc,
                    "-parse-as-library",
                    str(PET_PANEL),
                    str(harness),
                    "-framework",
                    "AppKit",
                    "-o",
                    str(executable),
                ],
                capture_output=True,
                text=True,
                timeout=90,
                check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            verified = subprocess.run(
                [str(executable)],
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
            self.assertEqual(verified.returncode, 0, verified.stderr)
            self.assertEqual(verified.stdout.strip(), "pet-panel-level-ok")

    def test_always_on_top_menu_is_checked_and_uses_window_settings_persistence(self) -> None:
        delegate = PET_APP_DELEGATE.read_text(encoding="utf-8")
        settings = SETTINGS_CONTROLLER.read_text(encoding="utf-8")

        self.assertIn("case alwaysOnTop", delegate)
        self.assertIn('title: "Keep Statelet on Top"', delegate)
        self.assertIn("action: #selector(toggleAlwaysOnTop)", delegate)
        self.assertIn("alwaysOnTopItem.state = effectiveAlwaysOnTop ? .on : .off", delegate)
        self.assertIn("@objc private func toggleAlwaysOnTop()", delegate)
        self.assertIn("mediaMap.window.replacing(alwaysOnTop: !effectiveAlwaysOnTop)", delegate)
        self.assertIn("options.alwaysOnTopOverride = nil", delegate)
        self.assertIn("applyPublishedMediaMap(updated, refreshPlayback: false)", delegate)
        self.assertIn("alwaysOnTop: update.alwaysOnTop", delegate)
        self.assertIn("try publishMediaMap(updated)", delegate)
        self.assertIn('checkboxWithTitle: "Keep Statelet on Top"', settings)

    def test_player_suspends_for_occlusion_and_screen_sleep_without_cross_resuming(self) -> None:
        player = PET_PLAYER.read_text(encoding="utf-8")
        delegate = PET_APP_DELEGATE.read_text(encoding="utf-8")
        policy = RUNTIME_EFFICIENCY.read_text(encoding="utf-8")

        self.assertIn("private var suspensionPolicy = PlaybackSuspensionPolicy()", player)
        self.assertIn("changed = reasons.insert(reason).inserted", policy)
        self.assertIn("changed = reasons.remove(reason) != nil", policy)
        self.assertIn("guard reasons.isEmpty else", policy)
        self.assertIn("queuePlayer.pause()", player)
        self.assertIn("queuePlayer.playImmediately(atRate: Float(rate))", player)
        self.assertIn("readinessTimeoutWorkItem?.cancel()", player)
        self.assertIn("windowDidChangeOcclusionState", delegate)
        self.assertIn("NSWorkspace.screensDidSleepNotification", delegate)
        self.assertIn("NSWorkspace.screensDidWakeNotification", delegate)
        self.assertIn("!panel.occlusionState.contains(.visible)", delegate)
        self.assertIn("DisplayWakeRecoveryPolicy.steps", delegate)
        self.assertNotIn("preventUserIdleSystemSleep", delegate)

    def test_fps_metadata_is_badge_gated_reuses_item_asset_and_has_a_bounded_cache(self) -> None:
        player = PET_PLAYER.read_text(encoding="utf-8")
        policy = RUNTIME_EFFICIENCY.read_text(encoding="utf-8")

        self.assertIn("guard view.isFPSBadgeEnabled else", player)
        self.assertIn("asset: queuePlayer.currentItem?.asset ?? item.asset", player)
        self.assertNotIn("AVURLAsset(url: url)", player)
        self.assertIn("maximumCachedFrameRates = 32", player)
        self.assertIn("BoundedLRUCache<LocalFileRevision, Double>", player)
        self.assertIn("device = UInt64(info.st_dev)", policy)
        self.assertIn("inode = UInt64(info.st_ino)", policy)
        self.assertIn("while order.count > capacity", policy)

    def test_unchanged_lifecycle_and_library_updates_skip_expensive_refreshes(self) -> None:
        delegate = PET_APP_DELEGATE.read_text(encoding="utf-8")
        settings = SETTINGS_CONTROLLER.read_text(encoding="utf-8")
        library = ANIMATION_LIBRARY.read_text(encoding="utf-8")

        apply_body = delegate.split("private func apply(state: PetState", 1)[1].split(
            "private func startLifecyclePresentation", 1
        )[0]
        decision_gate = apply_body.index("let shouldRefreshUI = LifecycleUIRefreshPolicy.shouldRefresh")
        self.assertNotIn("updateStatusMenu()", apply_body[:decision_gate])
        self.assertNotIn("refreshSettings()", apply_body[:decision_gate])
        self.assertIn("LibraryRowRefreshPolicy.shouldRefresh", library)
        self.assertIn("fileRevisions: fileRevisions", library)
        self.assertIn("startLibraryRevisionTimer()", settings)
        self.assertIn("timer.tolerance = 0.35", settings)
        self.assertIn("animationLibrary.invalidateRowCache()", settings)

    def test_conversion_process_is_bounded_and_force_terminates_when_stuck(self) -> None:
        source = ALPHA_COORDINATOR.read_text(encoding="utf-8")
        self.assertIn("maximumCapturedOutputBytes", source)
        self.assertIn("overallDeadlineSeconds", source)
        self.assertIn("noProgressDeadlineSeconds", source)
        self.assertIn("terminationGraceSeconds", source)
        self.assertIn("SIGKILL", source)
        self.assertIn("recordActivity", source)
        self.assertIn("AlphaPlaybackProcessValidator", source)
        self.assertIn("--statelet-playback-smoke-helper", MAC_MAIN.read_text(encoding="utf-8"))

    def test_conversion_watchdog_kills_stderr_noise_and_releases_coordinator(self) -> None:
        if sys.platform != "darwin":
            self.skipTest("Swift process-group watchdog verification requires macOS")
        swiftc = shutil.which("swiftc")
        self.assertIsNotNone(swiftc)
        core_sources = sorted((PACKAGE / "Sources" / "CodexPetCore").glob("*.swift"))
        with tempfile.TemporaryDirectory(prefix="statelet-watchdog-") as temporary:
            temp = Path(temporary)
            fake_python = temp / "fake-python"
            fake_python.write_text(
                "#!/bin/sh\ntrap '' TERM\nsleep 1000 &\nchild=$!\nprintf '%s\\n' \"$child\" > \"$2.childpid\"\nwhile :; do echo harmless-noise >&2; sleep 0.02; done\n",
                encoding="utf-8",
            )
            fake_python.chmod(0o755)
            failing_python = temp / "failing-python"
            failing_python.write_text(
                "#!/bin/sh\nprintf '%s\\n' '{\"event\":\"progress\",\"status\":\"failed\",\"percent\":37,\"stage\":\"verify\",\"message\":\"The animation failed a quality gate.\",\"code\":\"QUALITY_GATE_FAILED\",\"safe_message\":\"The animation failed a quality gate.\"}'\necho '/Users/private/raw-tool-error' >&2\nsleep 0.1\nexit 2\n",
                encoding="utf-8",
            )
            failing_python.chmod(0o755)
            converter = temp / "converter.py"
            converter.write_text("# fake\n", encoding="utf-8")
            playback_helper = temp / "playback-helper"
            playback_helper.write_text(
                "#!/bin/sh\nprintf '%s' '{\"isPlayable\":true,\"videoTrackCount\":1,\"audioTrackCount\":0,\"codec\":\"hevc\",\"width\":320,\"height\":480,\"nominalFrameRate\":24,\"durationSeconds\":2.6666666667,\"decodedFirstFrame\":true}'\n",
                encoding="utf-8",
            )
            playback_helper.chmod(0o755)
            hanging_playback_helper = temp / "hanging-playback-helper"
            playback_child_pid = temp / "playback-child.pid"
            hanging_playback_helper.write_text(
                f"#!/bin/sh\ntrap '' TERM\nsleep 1000 &\nprintf '%s\\n' \"$!\" > '{playback_child_pid}'\nwhile :; do sleep 1; done\n",
                encoding="utf-8",
            )
            hanging_playback_helper.chmod(0o755)
            harness = temp / "WatchdogHarness.swift"
            harness.write_text(
                r'''
import Foundation
import Darwin
import CodexPetCore

final class LockedResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Value, Error>?

    func set(_ value: Result<Value, Error>) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    func clear() {
        lock.lock()
        stored = nil
        lock.unlock()
    }

    var value: Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

@main
struct WatchdogHarness {
    static func main() {
        let arguments = CommandLine.arguments
        let temporary = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let suiteName = "statelet-profile-test-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { exit(10) }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("fit", forKey: AlphaConversionProfile.defaultsKey)
        guard AlphaConversionProfile.restored(from: defaults) == .fit else { exit(11) }
        defaults.set("future-invalid-profile", forKey: AlphaConversionProfile.defaultsKey)
        guard AlphaConversionProfile.restored(from: defaults) == .fill else { exit(12) }
        AlphaConversionProfile.fit.persist(to: defaults)
        guard defaults.string(forKey: AlphaConversionProfile.defaultsKey) == "fit" else { exit(13) }
        guard AlphaRecoveryArtifactPolicy.accepts(
            artifactStem: "idle",
            outputBasename: "idle-1723456789-deadbeef.mov",
            reportBasename: "idle-1723456789-deadbeef.report.json"
        ) else { exit(14) }
        guard AlphaRecoveryArtifactPolicy.accepts(
            artifactStem: "transition-idle-to-running",
            outputBasename: "transition-idle-to-running-1723456789-deadbeef.mov",
            reportBasename: "transition-idle-to-running-1723456789-deadbeef.report.json"
        ), !AlphaRecoveryArtifactPolicy.accepts(
            artifactStem: "transition-idle-to-thinking",
            outputBasename: "transition-idle-to-running-1723456789-deadbeef.mov",
            reportBasename: "transition-idle-to-running-1723456789-deadbeef.report.json"
        ) else { exit(41) }
        let hostilePairs = [
            ("media-map.json", "media-map.report.json"),
            ("running-1723456789-deadbeef.mov", "running-1723456789-deadbeef.report.json"),
            ("idle-1723456789-deadbeef.mov", "idle-1723456789-cafebabe.report.json"),
            ("idle-1723456789-DEADBEEF.mov", "idle-1723456789-DEADBEEF.report.json"),
            ("idle-1723456789-deadbeef.mov", "media-map.json"),
        ]
        for pair in hostilePairs {
            guard !AlphaRecoveryArtifactPolicy.accepts(
                artifactStem: "idle",
                outputBasename: pair.0,
                reportBasename: pair.1
            ) else { exit(15) }
        }
        func requireCopyFailure(_ operation: () throws -> Void, _ code: Int32) {
            do { try operation(); exit(code) } catch { }
        }
        let portableRoot = temporary.appendingPathComponent("portable-tests", isDirectory: true)
        try! FileManager.default.createDirectory(at: portableRoot, withIntermediateDirectories: true)
        let movie = portableRoot.appendingPathComponent("sample.mov")
        let report = portableRoot.appendingPathComponent("sample.report.json")
        try! Data(repeating: 0x41, count: 64).write(to: movie)
        try! Data("{}".utf8).write(to: report)
        let safeCopier = PortableMediaSecureCopier(
            limits: PortableMediaCopyLimits(
                maxMovieBytes: 1_024,
                maxReportBytes: 1_024,
                minimumFreeSpaceReserveBytes: 0,
                chunkBytes: 8
            ),
            availableDiskBytes: { _ in 1_000_000 }
        )
        let safeDestination = portableRoot.appendingPathComponent("safe", isDirectory: true)
        let copied = try! safeCopier.copyPair(
            movieSource: movie,
            reportSource: report,
            destinationDirectory: safeDestination
        )
        guard (try! Data(contentsOf: copied.movieURL)) == Data(repeating: 0x41, count: 64),
              (try! Data(contentsOf: copied.reportURL)) == Data("{}".utf8) else { exit(16) }
        var mode = stat()
        guard lstat(copied.movieURL.path, &mode) == 0,
              mode.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              mode.st_mode & 0o777 == 0o600 else { exit(17) }

        requireCopyFailure({
            _ = try safeCopier.copyPair(
                movieSource: URL(string: "https://example.invalid/sample.mov")!,
                reportSource: report,
                destinationDirectory: portableRoot.appendingPathComponent("non-local")
            )
        }, 26)

        let movieLink = portableRoot.appendingPathComponent("movie-link.mov")
        try! FileManager.default.createSymbolicLink(at: movieLink, withDestinationURL: movie)
        requireCopyFailure({
            _ = try safeCopier.copyPair(
                movieSource: movieLink,
                reportSource: report,
                destinationDirectory: portableRoot.appendingPathComponent("symlink-movie")
            )
        }, 18)
        let reportLink = portableRoot.appendingPathComponent("sample-link.report.json")
        try! FileManager.default.createSymbolicLink(at: reportLink, withDestinationURL: report)
        requireCopyFailure({
            _ = try safeCopier.copyPair(
                movieSource: movie,
                reportSource: reportLink,
                destinationDirectory: portableRoot.appendingPathComponent("symlink-report")
            )
        }, 19)
        let fifo = portableRoot.appendingPathComponent("special.mov")
        guard mkfifo(fifo.path, 0o600) == 0 else { exit(20) }
        requireCopyFailure({
            _ = try safeCopier.copyPair(
                movieSource: fifo,
                reportSource: report,
                destinationDirectory: portableRoot.appendingPathComponent("special")
            )
        }, 21)
        let tinyReportCopier = PortableMediaSecureCopier(
            limits: PortableMediaCopyLimits(maxMovieBytes: 1_024, maxReportBytes: 1),
            availableDiskBytes: { _ in 1_000_000 }
        )
        requireCopyFailure({
            _ = try tinyReportCopier.copyPair(
                movieSource: movie,
                reportSource: report,
                destinationDirectory: portableRoot.appendingPathComponent("large-report")
            )
        }, 22)
        let tinyMovieCopier = PortableMediaSecureCopier(
            limits: PortableMediaCopyLimits(maxMovieBytes: 8, maxReportBytes: 1_024),
            availableDiskBytes: { _ in 1_000_000 }
        )
        requireCopyFailure({
            _ = try tinyMovieCopier.copyPair(
                movieSource: movie,
                reportSource: report,
                destinationDirectory: portableRoot.appendingPathComponent("large-movie")
            )
        }, 23)
        let noDiskCopier = PortableMediaSecureCopier(
            limits: PortableMediaCopyLimits(
                maxMovieBytes: 1_024,
                maxReportBytes: 1_024,
                minimumFreeSpaceReserveBytes: 1
            ),
            availableDiskBytes: { _ in 0 }
        )
        requireCopyFailure({
            _ = try noDiskCopier.copyPair(
                movieSource: movie,
                reportSource: report,
                destinationDirectory: portableRoot.appendingPathComponent("no-disk")
            )
        }, 24)
        var mutated = false
        let mutationCopier = PortableMediaSecureCopier(
            limits: PortableMediaCopyLimits(
                maxMovieBytes: 1_024,
                maxReportBytes: 1_024,
                minimumFreeSpaceReserveBytes: 0,
                chunkBytes: 8
            ),
            availableDiskBytes: { _ in 1_000_000 },
            afterChunk: { kind in
                guard kind == .movie, !mutated else { return }
                mutated = true
                let handle = try! FileHandle(forWritingTo: movie)
                try! handle.seekToEnd()
                try! handle.write(contentsOf: Data([0x42]))
                try! handle.close()
            }
        )
        requireCopyFailure({
            _ = try mutationCopier.copyPair(
                movieSource: movie,
                reportSource: report,
                destinationDirectory: portableRoot.appendingPathComponent("mutated")
            )
        }, 25)
        try! Data("{}".utf8).write(to: report)
        var reportMutated = false
        let reportMutationCopier = PortableMediaSecureCopier(
            limits: PortableMediaCopyLimits(
                maxMovieBytes: 1_024,
                maxReportBytes: 1_024,
                minimumFreeSpaceReserveBytes: 0,
                chunkBytes: 1
            ),
            availableDiskBytes: { _ in 1_000_000 },
            afterChunk: { kind in
                guard kind == .report, !reportMutated else { return }
                reportMutated = true
                let handle = try! FileHandle(forWritingTo: report)
                try! handle.seekToEnd()
                try! handle.write(contentsOf: Data([0x20]))
                try! handle.close()
            }
        )
        requireCopyFailure({
            _ = try reportMutationCopier.copyPair(
                movieSource: movie,
                reportSource: report,
                destinationDirectory: portableRoot.appendingPathComponent("report-mutated")
            )
        }, 27)
        let timedResult = LockedResult<Int>()
        let timeoutStarted = Date()
        Task {
            do {
                let value = try await PortableMediaOperationRunner.run(timeoutSeconds: 0.1) { token in
                    while true {
                        try token.check()
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                } as Int
                timedResult.set(.success(value))
            } catch {
                timedResult.set(.failure(error))
            }
        }
        while timedResult.value == nil, Date().timeIntervalSince(timeoutStarted) < 2.5 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard case let .failure(timeoutError)? = timedResult.value,
              timeoutError.localizedDescription.contains("timed out"),
              Date().timeIntervalSince(timeoutStarted) < 2.5 else { exit(28) }
        let resetResult = LockedResult<Int>()
        Task {
            do {
                resetResult.set(.success(
                    try await PortableMediaOperationRunner.run(timeoutSeconds: 1) { token in
                        try token.check()
                        return 42
                    }
                ))
            } catch {
                resetResult.set(.failure(error))
            }
        }
        let resetDeadline = Date().addingTimeInterval(1)
        while resetResult.value == nil, Date() < resetDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard case let .success(value)? = resetResult.value, value == 42 else { exit(29) }
        let slowDestination = portableRoot.appendingPathComponent("slow-timeout", isDirectory: true)
        let slowResult = LockedResult<PortableMediaCopyResult>()
        Task {
            do {
                slowResult.set(.success(
                    try await PortableMediaOperationRunner.run(timeoutSeconds: 0.05) { token in
                        try PortableMediaSecureCopier(
                            limits: PortableMediaCopyLimits(
                                maxMovieBytes: 1_024,
                                maxReportBytes: 1_024,
                                minimumFreeSpaceReserveBytes: 0,
                                chunkBytes: 1
                            ),
                            availableDiskBytes: { _ in 1_000_000 },
                            afterChunk: { _ in usleep(100_000) },
                            operationCheck: token.check
                        ).copyPair(
                            movieSource: movie,
                            reportSource: report,
                            destinationDirectory: slowDestination
                        )
                    }
                ))
            } catch {
                slowResult.set(.failure(error))
            }
        }
        let slowDeadline = Date().addingTimeInterval(1)
        while slowResult.value == nil, Date() < slowDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard case let .failure(slowError)? = slowResult.value,
              slowError.localizedDescription.contains("timed out") else { exit(30) }
        let cleanupDeadline = Date().addingTimeInterval(1)
        while FileManager.default.fileExists(atPath: slowDestination.path), Date() < cleanupDeadline {
            usleep(10_000)
        }
        guard !FileManager.default.fileExists(atPath: slowDestination.path) else { exit(31) }
        let unquotedPath = "/Users/leoho/My Videos/foo.mp4"
        let quotedPath = "'/Users/leoho/My Videos/foo.mp4'"
        let sanitized = AlphaConversionCoordinator.sanitizedFailureMessage(
            from: Data("failed \(unquotedPath) and \(quotedPath): codec error\n".utf8)
        )
        guard !sanitized.contains("/Users/"),
              !sanitized.contains("leoho"),
              !sanitized.contains("My Videos"),
              sanitized.components(separatedBy: "<local-file>").count >= 3 else { exit(32) }
        let extensionless = AlphaConversionCoordinator.sanitizedFailureMessage(
            from: Data("failed /Users/leoho/My Folder/tool and '/Users/leoho/My Folder/tool'\n".utf8)
        )
        guard !extensionless.contains("/Users/"),
              !extensionless.contains("My Folder"),
              !extensionless.contains("Videos/foo"),
              extensionless.contains("<local-file>") else { exit(41) }
        let probe = try! AlphaPlaybackProcessValidator.probe(
            url: movie,
            timeoutSeconds: 1,
            helperExecutableURL: URL(fileURLWithPath: arguments[4])
        )
        guard probe.isPlayable, probe.width == 320, probe.height == 480 else { exit(33) }
        let hangingHelper = URL(fileURLWithPath: arguments[5])
        let playbackTimeoutStarted = Date()
        do {
            _ = try AlphaPlaybackProcessValidator.probe(
                url: movie,
                timeoutSeconds: 1,
                helperExecutableURL: hangingHelper
            )
            exit(34)
        } catch {
            guard error.localizedDescription.contains("timed out"),
                  Date().timeIntervalSince(playbackTimeoutStarted) < 2.5 else { exit(35) }
        }
        let helperChildURL = URL(fileURLWithPath: arguments[6])
        guard let helperChildText = try? String(contentsOf: helperChildURL, encoding: .utf8),
              let helperChildPID = pid_t(helperChildText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            exit(36)
        }
        let helperReapDeadline = Date().addingTimeInterval(1)
        while kill(helperChildPID, 0) == 0, Date() < helperReapDeadline {
            usleep(10_000)
        }
        guard kill(helperChildPID, 0) != 0, errno == ESRCH else { exit(37) }
        let stableDiagnostics = [
            AlphaConversionFailure.alreadyRunning.conversionDiagnostic,
            AlphaConversionFailure.launchFailed.conversionDiagnostic,
            AlphaConversionFailure.cancelled.conversionDiagnostic,
            AlphaConversionFailure.converterFailed("safe").conversionDiagnostic,
            AlphaConversionFailure.timedOut("ignored").conversionDiagnostic,
            AlphaConversionFailure.invalidProgressProtocol.conversionDiagnostic,
            AlphaConversionFailure.missingArtifact.conversionDiagnostic,
        ]
        guard stableDiagnostics.map(\.code) == [
            "ALREADY_RUNNING", "LAUNCH_FAILED", "CANCELLED", "CONVERSION_FAILED",
            "PROCESS_TIMEOUT", "PROGRESS_PROTOCOL_INVALID", "ARTIFACT_MISSING",
        ] else { exit(38) }
        let failureCoordinator = AlphaConversionCoordinator(
            overallDeadlineSeconds: 2,
            noProgressDeadlineSeconds: 1,
            terminationGraceSeconds: 0.15
        )
        let failureResult = LockedResult<AlphaConversionResult>()
        failureCoordinator.convert(
            sourceURL: temporary.appendingPathComponent("failing-source.mp4"),
            outputURL: temporary.appendingPathComponent("failing-output.mov"),
            reportURL: temporary.appendingPathComponent("failing-output.report.json"),
            width: 320,
            height: 480,
            toolchain: AlphaToolchain(
                python: URL(fileURLWithPath: arguments[7]),
                converter: URL(fileURLWithPath: arguments[3]),
                ffmpeg: URL(fileURLWithPath: "/Users/private/ffmpeg"),
                ffprobe: URL(fileURLWithPath: "/Users/private/ffprobe"),
                avconvert: URL(fileURLWithPath: "/Users/private/avconvert")
            ),
            invocationChallenge: String(repeating: "d", count: 64),
            phase: { _ in },
            completion: { failureResult.set($0) }
        )
        let failureDeadline = Date().addingTimeInterval(2)
        while failureResult.value == nil, Date() < failureDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard case let .failure(structuredError)? = failureResult.value,
              let alphaFailure = structuredError as? AlphaConversionFailure,
              alphaFailure.conversionDiagnostic.code == "QUALITY_GATE_FAILED",
              alphaFailure.conversionDiagnostic.stage == "verify",
              !structuredError.localizedDescription.contains("/Users/") else { exit(39) }
        let coordinator = AlphaConversionCoordinator(
            overallDeadlineSeconds: 2,
            noProgressDeadlineSeconds: 0.3,
            terminationGraceSeconds: 0.15
        )
        let toolchain = AlphaToolchain(
            python: URL(fileURLWithPath: arguments[2]),
            converter: URL(fileURLWithPath: arguments[3]),
            ffmpeg: URL(fileURLWithPath: "/usr/bin/true"),
            ffprobe: URL(fileURLWithPath: "/usr/bin/true"),
            avconvert: URL(fileURLWithPath: "/usr/bin/true")
        )
        let result = LockedResult<AlphaConversionResult>()
        let started = Date()
        coordinator.convert(
            sourceURL: temporary.appendingPathComponent("source.mp4"),
            outputURL: temporary.appendingPathComponent("output.mov"),
            reportURL: temporary.appendingPathComponent("output.report.json"),
            width: 320,
            height: 480,
            toolchain: toolchain,
            invocationChallenge: String(repeating: "a", count: 64),
            phase: { _ in },
            completion: { result.set($0) }
        )
        while result.value == nil, Date().timeIntervalSince(started) < 3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        guard case let .failure(error)? = result.value else { exit(2) }
        guard error.localizedDescription.contains("no progress") else { exit(3) }
        guard !coordinator.isRunning else { exit(4) }
        result.clear()
        coordinator.convert(
            sourceURL: temporary.appendingPathComponent("source.mp4"),
            outputURL: temporary.appendingPathComponent("output-2.mov"),
            reportURL: temporary.appendingPathComponent("output-2.report.json"),
            width: 320,
            height: 480,
            toolchain: toolchain,
            invocationChallenge: String(repeating: "b", count: 64),
            phase: { _ in },
            completion: { result.set($0) }
        )
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            coordinator.cancel()
        }
        let cancelStarted = Date()
        while result.value == nil, Date().timeIntervalSince(cancelStarted) < 2 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        guard case let .failure(cancelError)? = result.value,
              cancelError.localizedDescription.contains("cancelled") else { exit(5) }
        guard !coordinator.isRunning else { exit(6) }
        result.clear()
        coordinator.convert(
            sourceURL: temporary.appendingPathComponent("source.mp4"),
            outputURL: temporary.appendingPathComponent("output-3.mov"),
            reportURL: temporary.appendingPathComponent("output-3.report.json"),
            width: 320,
            height: 480,
            toolchain: toolchain,
            invocationChallenge: String(repeating: "c", count: 64),
            phase: { _ in },
            completion: { result.set($0) }
        )
        let launchDeadline = Date().addingTimeInterval(1)
        while !coordinator.isRunning, Date() < launchDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard coordinator.terminateAndWait(graceSeconds: 0.1, deadlineSeconds: 1.5),
              !coordinator.isRunning else { exit(7) }
        let childPIDURL = URL(fileURLWithPath: arguments[3] + ".childpid")
        guard let childText = try? String(contentsOf: childPIDURL, encoding: .utf8),
              let childPID = pid_t(childText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            exit(8)
        }
        let reapDeadline = Date().addingTimeInterval(1)
        while kill(childPID, 0) == 0, Date() < reapDeadline {
            usleep(10_000)
        }
        guard kill(childPID, 0) != 0, errno == ESRCH else { exit(9) }
        print("watchdog-ok")
    }
}
''',
                encoding="utf-8",
            )
            module = temp / "CodexPetCore.swiftmodule"
            library = temp / "libCodexPetCore.dylib"
            core = subprocess.run(
                [
                    swiftc,
                    "-parse-as-library",
                    "-emit-library",
                    "-emit-module",
                    "-module-name",
                    "CodexPetCore",
                    *map(str, core_sources),
                    "-framework",
                    "AVFoundation",
                    "-emit-module-path",
                    str(module),
                    "-o",
                    str(library),
                ],
                capture_output=True,
                text=True,
                timeout=90,
                check=False,
            )
            self.assertEqual(core.returncode, 0, core.stderr)
            executable = temp / "watchdog-harness"
            app = subprocess.run(
                [
                    swiftc,
                    "-parse-as-library",
                    "-I",
                    str(temp),
                    "-L",
                    str(temp),
                    "-lCodexPetCore",
                    str(STATELET_IDENTITY),
                    str(ALPHA_COORDINATOR),
                    str(harness),
                    "-Xlinker",
                    "-rpath",
                    "-Xlinker",
                    str(temp),
                    "-o",
                    str(executable),
                ],
                capture_output=True,
                text=True,
                timeout=90,
                check=False,
            )
            self.assertEqual(app.returncode, 0, app.stderr)
            for iteration in range(5):
                runtime_root = temp / f"run-{iteration}"
                runtime_root.mkdir()
                playback_child_pid.unlink(missing_ok=True)
                Path(str(converter) + ".childpid").unlink(missing_ok=True)
                result = subprocess.run(
                    [
                        str(executable),
                        str(runtime_root),
                        str(fake_python),
                        str(converter),
                        str(playback_helper),
                        str(hanging_playback_helper),
                        str(playback_child_pid),
                        str(failing_python),
                    ],
                    capture_output=True,
                    text=True,
                    timeout=15,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "watchdog-ok")

    def test_failed_mp4s_can_be_retried_without_reimporting_successes(self) -> None:
        source = PET_APP_DELEGATE.read_text(encoding="utf-8")
        self.assertIn("lastFailedMP4Batch", source)
        self.assertIn("retryLastFailedMP4Batch", source)
        self.assertIn("retryFailedAvailable: !retryURLs.isEmpty", source)
        validation_failures = source.split("let validationFailures = rejected.map", 1)[1].split(
            "startConversionBatch(", 1
        )[0]
        self.assertIn("sourceURL: nil", validation_failures)
        retry = source.split("private func retryLastFailedMP4Batch()", 1)[1].split(
            "private func batchProgress", 1
        )[0]
        self.assertIn("importMP4s(batch.sourceURLs, for: batch.state)", retry)
        self.assertNotIn("startConversionBatch", retry)

    def test_portable_import_uses_secure_budgeted_regular_file_copy(self) -> None:
        coordinator = ALPHA_COORDINATOR.read_text(encoding="utf-8")
        source = PET_APP_DELEGATE.read_text(encoding="utf-8")
        copy_body = source.split("private func copyVerifiedMovieAndReport", 1)[1].split(
            "private func copyIntoMediaDirectory", 1
        )[0]
        self.assertIn("PortableMediaSecureCopier", coordinator)
        self.assertIn("O_NOFOLLOW", coordinator)
        self.assertIn("S_IFREG", coordinator)
        self.assertIn("maxReportBytes: UInt64 = 1_048_576", coordinator)
        self.assertIn("fsync", coordinator)
        self.assertIn("fstat", coordinator)
        self.assertIn("availableDiskBytes", coordinator)
        self.assertIn("PortableMediaSecureCopier", copy_body)
        self.assertNotIn("copyItem", copy_body)
        portable_loop = source.split("for (index, sourceURL) in sourceURLs.enumerated()", 1)[1].split(
            "mediaMutationInProgress = false", 1
        )[0]
        prepare = source.split("private func prepareVerifiedMovie", 1)[1].split(
            "private func validatePortableMovie", 1
        )[0]
        validate = source.split("private func validatePortableMovie", 1)[1].split(
            "private func playOnce", 1
        )[0]
        self.assertEqual(prepare.count("validatePortableMovie"), 1)
        self.assertNotIn("validatePortableMovie", portable_loop)
        self.assertIn("digestAfterPlayback == report.outputSHA256", validate)
        self.assertIn("reportDataAfterPlayback == reportData", validate)
        self.assertIn("movieIdentityAfterPlayback == movieIdentity", validate)
        self.assertIn("reportIdentityAfterPlayback == reportIdentity", validate)
        self.assertIn("directoryStatusAfterPlayback.st_ino == directoryStatus.st_ino", validate)
        self.assertIn("directoryStatus.st_mode & 0o077 == 0", validate)
        self.assertIn("PortableMediaOperationRunner.run", source)
        self.assertIn("portableCopyTimeoutSeconds", source)
        self.assertIn("portableValidationTimeoutSeconds", source)
        portable_batch = source.split("private func importVerifiedMovies", 1)[1].split(
            "private func prepareVerifiedMovie", 1
        )[0]
        self.assertIn("reason: String(error.localizedDescription.prefix(300))", portable_batch)
        self.assertIn("summarizedImportFailures(failures)", portable_batch)
        self.assertIn("mediaMutationInProgress = false", portable_batch)

    def test_local_and_recovery_reports_use_bounded_nofollow_reader_and_post_playback_recheck(self) -> None:
        coordinator = ALPHA_COORDINATOR.read_text(encoding="utf-8")
        source = PET_APP_DELEGATE.read_text(encoding="utf-8")
        coordinator_completion = coordinator.split("if progressProtocol.hasFailed", 1)[1].split(
            "private func boundedEnvironment", 1
        )[0]
        self.assertIn("PortableMediaSecureCopier.readRegularFile", coordinator_completion)
        self.assertNotIn("Data(contentsOf: reportURL)", coordinator_completion)
        recovery = source.split("private func recoverInterruptedConversionIfPresent", 1)[1].split(
            "private static func isValidInvocationChallenge", 1
        )[0]
        self.assertGreaterEqual(recovery.count("PortableMediaSecureCopier.readRegularFile"), 1)
        self.assertNotIn("Data(contentsOf:", recovery)
        local_validation = source.split("private static func validateLocallyAttestedMovie", 1)[1].split(
            "private func validatePortableMovie", 1
        )[0]
        self.assertIn("AlphaPlaybackProcessValidator.validate", local_validation)
        self.assertIn("reportDataAfterPlayback == reportData", local_validation)
        self.assertIn("digestAfterPlayback == report.outputSHA256", local_validation)
        self.assertIn("movieIdentityAfterPlayback == movieIdentity", local_validation)
        self.assertIn("reportIdentityAfterPlayback == reportIdentity", local_validation)
        self.assertNotIn("AlphaPlaybackAcceptanceValidator.validate(\n                url:", source)

    def test_structured_conversion_failures_feed_sanitized_diagnostics(self) -> None:
        progress = (PACKAGE / "Sources" / "CodexPetCore" / "AlphaConversionProgress.swift").read_text(
            encoding="utf-8"
        )
        coordinator = ALPHA_COORDINATOR.read_text(encoding="utf-8")
        source = PET_APP_DELEGATE.read_text(encoding="utf-8")
        diagnostics = (PACKAGE / "Sources" / "CodexPetMac" / "PetDiagnostics.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn("allowedFailureCodes", progress)
        self.assertIn("safeMessage = \"safe_message\"", progress)
        self.assertIn("maximumUTF8Bytes: 256", progress)
        self.assertIn("My Videos/foo.mp4", tests_source := Path(__file__).read_text(encoding="utf-8"))
        self.assertIn("LockedTerminalConversionFailure", coordinator)
        self.assertIn("terminalFailure.record(event)", coordinator)
        self.assertIn("structuredConverterFailed", coordinator)
        protocol_branch = coordinator.split("if progressProtocol.hasFailed", 1)[1].split(
            "guard FileManager.default.isReadableFile", 1
        )[0]
        self.assertLess(
            protocol_branch.index("terminalFailure.failure"),
            protocol_branch.index("process.terminationStatus != 0"),
        )
        self.assertIn("lastConversionFailureDiagnostic", source)
        self.assertIn("conversionFailureCategory: lastConversionFailureDiagnostic?.code", source)
        self.assertIn("conversionFailureStage: lastConversionFailureDiagnostic?.stage", source)
        self.assertIn("conversion.failure_category", diagnostics)
        self.assertIn("conversion.failure_stage", diagnostics)

    def test_failure_path_sanitizer_handles_paths_with_spaces(self) -> None:
        source = ALPHA_COORDINATOR.read_text(encoding="utf-8")
        self.assertIn("My Videos", tests_source := Path(__file__).read_text(encoding="utf-8"))
        self.assertIn("My Folder/tool", tests_source)
        self.assertIn("mediaPathRedacted", source)
        self.assertIn("<local-file>", source)

    def test_app_shutdown_boundedly_reaps_conversion_process_group(self) -> None:
        coordinator = ALPHA_COORDINATOR.read_text(encoding="utf-8")
        source = PET_APP_DELEGATE.read_text(encoding="utf-8")
        shutdown = source.split("func applicationWillTerminate", 1)[1].split(
            "func windowDidMove", 1
        )[0]
        self.assertIn("terminateAndWait", shutdown)
        self.assertIn("func terminateAndWait", coordinator)
        self.assertIn("SIGTERM", coordinator)
        self.assertIn("SIGKILL", coordinator)

    def test_conversion_journal_is_private_path_free_and_attested_before_recovery(self) -> None:
        source = PET_APP_DELEGATE.read_text(encoding="utf-8")
        journal = source.split("private struct ActiveConversionJournal", 1)[1].split("}", 1)[0]
        self.assertNotIn("sourceURL", journal)
        self.assertIn("outputBasename", journal)
        self.assertIn("reportBasename", journal)
        self.assertIn("invocationChallenge", journal)
        self.assertIn(".posixPermissions: NSNumber(value: Int16(0o600))", source)
        self.assertIn("SecRandomCopyBytes", source)
        self.assertIn("invocationChallenge: journal.invocationChallenge", source)
        local_validation = source.split("private static func validateLocallyAttestedMovie", 1)[1].split(
            "private func validatePortableMovie", 1
        )[0]
        self.assertIn("expectedLocalProvenanceChallenge: invocationChallenge", local_validation)
        self.assertIn("AlphaPlaybackProcessValidator.validate", local_validation)
        self.assertIn("recoverInterruptedConversionIfPresent()", source)
        self.assertIn("AlphaRecoveryArtifactPolicy.accepts(", source)
        recovery = source.split("private func recoverInterruptedConversionIfPresent()", 1)[1].split(
            "private static func isValidInvocationChallenge", 1
        )[0]
        self.assertIn("mediaMutationInProgress = true", recovery)
        self.assertIn("self.mediaMutationInProgress = false", recovery)
        self.assertNotIn("removeItem(at: journalURL)", recovery)
        failure_branch = recovery.split("case .failure:", 1)[1].split("case let .success", 1)[0]
        self.assertNotIn("removeItem(at: outputURL)", failure_branch)
        self.assertNotIn("removeItem(at: reportURL)", failure_branch)
        self.assertNotIn("clearConversionJournal", failure_branch)
        self.assertNotIn("renameat", failure_branch)
        self.assertIn("action=retain_journal_and_artifacts", failure_branch)
        self.assertIn("pendingRecoveryNotice", failure_branch)

    def test_portable_movs_require_explicit_user_trust_and_playback_acceptance(self) -> None:
        source = PET_APP_DELEGATE.read_text(encoding="utf-8")
        self.assertIn("Trust portable verification for this batch?", source)
        self.assertIn("case .portableClaim where allowPortableClaim", source)
        self.assertIn("case .legacyPortableClaim", source)
        self.assertIn("Import the source MP4 instead for local attestation.", source)

    def test_mp4_conversion_profile_is_wired_without_changing_delivery_canvas(self) -> None:
        coordinator = ALPHA_COORDINATOR.read_text(encoding="utf-8")
        source = PET_APP_DELEGATE.read_text(encoding="utf-8")
        settings = SETTINGS_CONTROLLER.read_text(encoding="utf-8")
        self.assertIn("enum AlphaConversionProfile", coordinator)
        self.assertIn('static let defaultsKey = "StateletAlphaConversionProfile"', coordinator)
        for canonical in (
            "STATELET_ALPHA_CONVERTER",
            "STATELET_ALPHA_PYTHON",
            "STATELET_FFMPEG",
            "STATELET_FFPROBE",
            "STATELET_AVCONVERT",
        ):
            self.assertIn(canonical, coordinator)
        self.assertIn("static func restored(from defaults: UserDefaults = .standard)", coordinator)
        self.assertIn("func persist(to defaults: UserDefaults = .standard)", coordinator)
        self.assertIn('"--profile", profile.commandProfile', coordinator)
        self.assertIn('"--resize-mode", profile.resizeMode', coordinator)
        self.assertIn(
            'if allowEmptyFrames { arguments.append("--allow-empty-frame") }',
            coordinator,
        )
        self.assertIn("conversionProfile = AlphaConversionProfile.restored()", source)
        self.assertIn("profile.persist()", source)
        self.assertIn("controller.update(conversionProfile: conversionProfile)", source)
        self.assertIn("func update(conversionProfile: AlphaConversionProfile)", settings)
        self.assertIn("profile: conversionProfile", source)
        self.assertIn("width: AlphaAuthoringCanvas.width", source)
        self.assertIn("height: AlphaAuthoringCanvas.height", source)

    def test_cancelled_import_retains_failures_collected_before_cancel(self) -> None:
        source = PET_APP_DELEGATE.read_text(encoding="utf-8")
        cancelled_branch = source.split("if cancelled {", 1)[1].split(
            "} else if failures.isEmpty", 1
        )[0]
        self.assertIn("summarizedImportFailures(failures)", cancelled_branch)
        self.assertIn("Earlier failures:", cancelled_branch)

    def test_mp4_import_uses_stable_authoring_canvas(self) -> None:
        source = PET_APP_DELEGATE.read_text(encoding="utf-8")
        conversion_call = source.split("conversionCoordinator.convert(", 1)[1].split(
            "toolchain: toolchain", 1
        )[0]
        self.assertIn("width: AlphaAuthoringCanvas.width", conversion_call)
        self.assertIn("height: AlphaAuthoringCanvas.height", conversion_call)
        self.assertNotIn("mediaMap.window", conversion_call)

    def test_mp4_import_surfaces_informational_report_notices(self) -> None:
        source = PET_APP_DELEGATE.read_text(encoding="utf-8")
        self.assertIn("messages: report.notices.map(\\.message)", source)
        self.assertIn("summarizedImportNotices(notices)", source)

    def test_bundle_builder_rejects_embedded_private_path(self) -> None:
        executable = self.base / "leaky-executable"
        executable.write_text(
            "#!/bin/sh\n# /Users/private-owner/Documents/private-source.swift\nexit 0\n",
            encoding="utf-8",
        )
        executable.chmod(0o755)
        bundle = self.base / "Leaky.app"

        result = subprocess.run(
            [
                "bash",
                str(BUILD_SCRIPT),
                "--output",
                str(bundle),
                "--executable",
                str(executable),
                "--skip-sign",
            ],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Privacy scan failed", result.stderr)
        self.assertFalse(bundle.exists())

    def test_install_uses_separate_marked_board_independent_agents(self) -> None:
        bundle = self.make_bundle("Install")
        board_plist = self.home / "Library" / "LaunchAgents" / "com.coke1120.codex-pet.plist"
        board_plist.parent.mkdir(parents=True)
        board_plist.write_bytes(plistlib.dumps({"Label": "com.coke1120.codex-pet", "BoardSentinel": True}))
        board_runtime = self.home / "Library" / "Application Support" / "Statelet" / "runtime" / "board-sentinel.txt"
        board_runtime.parent.mkdir(parents=True)
        board_runtime.write_text("preserve", encoding="utf-8")

        result = self.install(bundle)
        self.assertEqual(result.returncode, 0, result.stderr)

        launch_agents = self.home / "Library" / "LaunchAgents"
        aggregator_path = launch_agents / "com.coke1120.statelet.state-aggregator.plist"
        player_path = launch_agents / "com.coke1120.statelet.mac-player.plist"
        with aggregator_path.open("rb") as handle:
            aggregator = plistlib.load(handle)
        with player_path.open("rb") as handle:
            player = plistlib.load(handle)
        with board_plist.open("rb") as handle:
            board = plistlib.load(handle)

        self.assertEqual(aggregator["StateletManaged"], MANAGED_MARKER)
        self.assertEqual(player["StateletManaged"], MANAGED_MARKER)
        self.assertEqual(aggregator["Label"], "com.coke1120.statelet.state-aggregator")
        self.assertEqual(player["Label"], "com.coke1120.statelet.mac-player")
        self.assertFalse(player["KeepAlive"])
        self.assertEqual(player["LimitLoadToSessionType"], "Aqua")
        self.assertEqual(player["ProcessType"], "Interactive")
        self.assertTrue(player["ProgramArguments"][0].endswith("/Applications/Statelet.app/Contents/MacOS/Statelet"))
        self.assertEqual(aggregator["ProcessType"], "Background")
        aggregator_arguments = "\n".join(aggregator["ProgramArguments"])
        self.assertIn("statelet_state_aggregator.py", aggregator_arguments)
        self.assertEqual(aggregator["ProgramArguments"][1], "-B")
        self.assertNotIn("codex_pet_daemon.py", aggregator_arguments)
        self.assertNotIn("serial", aggregator_arguments.lower())
        self.assertNotIn("/dev/", aggregator_arguments)
        self.assertFalse(aggregator["ProgramArguments"][0].startswith(str(ROOT)))
        self.assertFalse(aggregator["ProgramArguments"][0].startswith(str(self.base)))
        self.assertEqual(board, {"Label": "com.coke1120.codex-pet", "BoardSentinel": True})
        self.assertEqual(board_runtime.read_text(encoding="utf-8"), "preserve")

        component = self.home / "Library" / "Application Support" / "Statelet" / "Statelet"
        installed_names = {path.name for path in component.rglob("*") if path.is_file()}
        self.assertEqual(
            installed_names,
            {
                "MANAGED_BY_STATELET",
                "statelet_hook.py",
                "statelet_state.py",
                "statelet_state_aggregator.py",
            },
        )
        self.assertNotIn("codex_pet_daemon.py", installed_names)
        self.assertEqual(
            (self.home / "Library" / "Application Support" / "Statelet" / "media" / "media-map.json").stat().st_mode & 0o777,
            0o600,
        )

    def test_install_removes_owned_regular_obsolete_activity_titles(self) -> None:
        bundle = self.make_bundle("ObsoleteActivityTitles")
        sessions = (
            self.home
            / "Library"
            / "Application Support"
            / "Statelet"
            / "sessions"
        )
        sessions.mkdir(parents=True)
        obsolete = sessions / "activity-titles-v1.json"
        obsolete_payload = '{"private":"title"}\n'
        obsolete.write_text(obsolete_payload, encoding="utf-8")
        retained = sessions / "activity-targets-v1.json"
        retained.write_text('{"targets":{}}\n', encoding="utf-8")

        failed_environment = os.environ.copy()
        failed_environment["STATELET_INSTALL_FAIL_AT"] = "after-support"
        failed = self.install(bundle, env=failed_environment)

        self.assertEqual(failed.returncode, 70, failed.stderr)
        self.assertEqual(obsolete.read_text(encoding="utf-8"), obsolete_payload)
        self.assertFalse((self.home / ".statelet-install-transaction").exists())

        result = self.install(bundle)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(obsolete.exists())
        self.assertEqual(retained.read_text(encoding="utf-8"), '{"targets":{}}\n')

    def test_install_rejects_obsolete_activity_titles_symlink_without_following_it(self) -> None:
        bundle = self.make_bundle("ObsoleteActivityTitlesSymlink")
        sessions = (
            self.home
            / "Library"
            / "Application Support"
            / "Statelet"
            / "sessions"
        )
        sessions.mkdir(parents=True)
        private_target = self.base / "private-title-target.json"
        private_payload = '{"private":"do not disclose"}\n'
        private_target.write_text(private_payload, encoding="utf-8")
        obsolete = sessions / "activity-titles-v1.json"
        obsolete.symlink_to(private_target)

        result = self.install(bundle)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing unsafe obsolete Statelet activity metadata", result.stderr)
        self.assertNotIn(str(obsolete), result.stderr)
        self.assertNotIn(str(private_target), result.stderr)
        self.assertNotIn("do not disclose", result.stderr)
        self.assertTrue(obsolete.is_symlink())
        self.assertEqual(private_target.read_text(encoding="utf-8"), private_payload)
        self.assertFalse((self.home / ".statelet-install-transaction").exists())

    def test_install_rejects_obsolete_activity_titles_special_file(self) -> None:
        bundle = self.make_bundle("ObsoleteActivityTitlesSpecial")
        sessions = (
            self.home
            / "Library"
            / "Application Support"
            / "Statelet"
            / "sessions"
        )
        sessions.mkdir(parents=True)
        obsolete = sessions / "activity-titles-v1.json"
        os.mkfifo(obsolete)

        result = self.install(bundle)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing unsafe obsolete Statelet activity metadata", result.stderr)
        self.assertNotIn(str(obsolete), result.stderr)
        self.assertTrue(obsolete.exists())
        self.assertFalse((self.home / ".statelet-install-transaction").exists())

    def test_reinstall_preserves_managed_launch_at_login_choice(self) -> None:
        first_bundle = self.make_bundle("LoginPreferenceOne")
        result = self.install(first_bundle)
        self.assertEqual(result.returncode, 0, result.stderr)

        player_path = (
            self.home
            / "Library"
            / "LaunchAgents"
            / "com.coke1120.statelet.mac-player.plist"
        )
        with player_path.open("rb") as handle:
            player = plistlib.load(handle)
        player["RunAtLoad"] = False
        player_path.write_bytes(plistlib.dumps(player))

        second_bundle = self.make_bundle("LoginPreferenceTwo")
        result = self.install(second_bundle)
        self.assertEqual(result.returncode, 0, result.stderr)
        with player_path.open("rb") as handle:
            reinstalled = plistlib.load(handle)
        self.assertFalse(reinstalled["RunAtLoad"])
        self.assertEqual(reinstalled["StateletManaged"], MANAGED_MARKER)

    def test_hook_merge_is_additive_and_migrates_exact_documents_entry(self) -> None:
        bundle = self.make_bundle("Hooks")
        hooks_file = self.home / ".codex" / "hooks.json"
        hooks_file.parent.mkdir(parents=True)
        obsolete = f"python3 {self.home}/Documents/codex-pet-dev-board/mac/statelet_hook.py"
        unrelated_documents = f"python3 {self.home}/Documents/another-project/statelet_hook.py"
        original = {
            "unrelated": {"keep": True},
            "hooks": {
                "Stop": [
                    {"hooks": [{"type": "command", "command": "keep-me"}]},
                    {"hooks": [{"type": "command", "command": obsolete}]},
                    {"hooks": [{"type": "command", "command": unrelated_documents}]},
                ]
            },
        }
        hooks_file.write_text(json.dumps(original), encoding="utf-8")

        result = self.install(bundle)
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = json.loads(hooks_file.read_text(encoding="utf-8"))

        self.assertEqual(installed["unrelated"], {"keep": True})
        for event in HOOK_EVENTS:
            commands = [
                item.get("command")
                for group in installed["hooks"][event]
                if isinstance(group, dict)
                for item in group.get("hooks", [])
                if isinstance(item, dict)
            ]
            widget_commands = [
                command
                for command in commands
                if isinstance(command, str) and "/Statelet/python/statelet_hook.py" in command
            ]
            self.assertEqual(len(widget_commands), 1, event)
            self.assertIn("/Statelet/python/statelet_hook.py", widget_commands[0])
            self.assertNotIn("/Documents/", widget_commands[0])
        stop_commands = [
            item.get("command")
            for group in installed["hooks"]["Stop"]
            if isinstance(group, dict)
            for item in group.get("hooks", [])
            if isinstance(item, dict)
        ]
        self.assertIn("keep-me", stop_commands)
        self.assertIn(unrelated_documents, stop_commands)

    def test_existing_application_support_board_hook_is_reused_without_duplicates(self) -> None:
        bundle = self.make_bundle("SharedHook")
        board_hook = self.home / "Library" / "Application Support" / "Statelet" / "runtime" / "statelet_hook.py"
        board_hook.parent.mkdir(parents=True)
        board_hook.write_text("# existing board-compatible lifecycle hook\n", encoding="utf-8")
        board_command = shlex.join(["/usr/bin/python3", str(board_hook)])
        hooks_file = self.home / ".codex" / "hooks.json"
        hooks_file.parent.mkdir(parents=True)
        hooks_file.write_text(
            json.dumps(
                {
                    "hooks": {
                        "Stop": [
                            {"hooks": [{"type": "command", "command": board_command}]}
                        ]
                    }
                }
            ),
            encoding="utf-8",
        )

        result = self.install(bundle)
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = json.loads(hooks_file.read_text(encoding="utf-8"))
        for event in HOOK_EVENTS:
            commands = [
                item.get("command")
                for group in installed["hooks"][event]
                if isinstance(group, dict)
                for item in group.get("hooks", [])
                if isinstance(item, dict) and "statelet_hook.py" in str(item.get("command"))
            ]
            self.assertEqual(commands, [board_command], event)
        self.assertTrue(board_hook.exists())

        removed = subprocess.run(
            ["bash", str(UNINSTALL_SCRIPT), "--home", str(self.home), "--skip-launchctl"],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(removed.returncode, 0, removed.stderr)
        after_uninstall = json.loads(hooks_file.read_text(encoding="utf-8"))
        for event in HOOK_EVENTS:
            commands = [
                item.get("command")
                for group in after_uninstall["hooks"][event]
                if isinstance(group, dict)
                for item in group.get("hooks", [])
                if isinstance(item, dict) and "statelet_hook.py" in str(item.get("command"))
            ]
            self.assertEqual(commands, [board_command], event)

    def test_legacy_application_support_hook_is_replaced_by_canonical_hook(self) -> None:
        bundle = self.make_bundle("LegacySharedHook")
        legacy_hook = (
            self.home
            / "Library"
            / "Application Support"
            / "CodexPet"
            / "runtime"
            / "codex_pet_hook.py"
        )
        legacy_hook.parent.mkdir(parents=True)
        legacy_hook.write_text("# retained legacy compatibility hook\n", encoding="utf-8")
        legacy_command = shlex.join(["/usr/bin/python3", str(legacy_hook)])
        hooks_file = self.home / ".codex" / "hooks.json"
        hooks_file.parent.mkdir(parents=True)
        hooks_file.write_text(
            json.dumps(
                {
                    "hooks": {
                        "Stop": [
                            {"hooks": [{"type": "command", "command": legacy_command}]}
                        ]
                    }
                }
            ),
            encoding="utf-8",
        )

        result = self.install(bundle)
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = json.loads(hooks_file.read_text(encoding="utf-8"))
        commands = [
            item.get("command")
            for groups in installed["hooks"].values()
            for group in groups
            if isinstance(group, dict)
            for item in group.get("hooks", [])
            if isinstance(item, dict)
        ]
        self.assertNotIn(legacy_command, commands)
        self.assertTrue(commands)
        self.assertTrue(
            all("/Application Support/Statelet/Statelet/python/statelet_hook.py" in command for command in commands)
        )
        self.assertTrue(legacy_hook.exists())

    def test_failed_upgrade_rolls_back_every_managed_target(self) -> None:
        first = self.make_bundle("First", "first")
        result = self.install(first)
        self.assertEqual(result.returncode, 0, result.stderr)

        installed_app = self.home / "Applications" / "Statelet.app"
        legacy_app = self.home / "Applications" / "CodexPetMac.app"
        shutil.copytree(self.make_legacy_bundle("RollbackLegacy"), legacy_app)
        installed_executable = installed_app / "Contents" / "MacOS" / "Statelet"
        legacy_executable = legacy_app / "Contents" / "MacOS" / "CodexPetMac"
        old_executable = installed_executable.read_bytes()
        old_legacy_executable = legacy_executable.read_bytes()
        support = self.home / "Library" / "Application Support" / "Statelet"
        component_marker = support / "Statelet" / "MANAGED_BY_STATELET"
        old_component = component_marker.read_bytes()
        aggregator_plist = self.home / "Library" / "LaunchAgents" / "com.coke1120.statelet.state-aggregator.plist"
        old_plist = aggregator_plist.read_bytes()
        hooks_file = self.home / ".codex" / "hooks.json"
        old_hooks = hooks_file.read_bytes()

        second = self.make_bundle("Second", "second")
        environment = os.environ.copy()
        environment["CODEX_PET_INSTALL_FAIL_AT"] = "after-app"
        failed = self.install(second, env=environment)

        self.assertEqual(failed.returncode, 70)
        self.assertIn("Injected installation failure", failed.stderr)
        self.assertEqual(installed_executable.read_bytes(), old_executable)
        self.assertEqual(legacy_executable.read_bytes(), old_legacy_executable)
        self.assertEqual(component_marker.read_bytes(), old_component)
        self.assertEqual(aggregator_plist.read_bytes(), old_plist)
        self.assertEqual(hooks_file.read_bytes(), old_hooks)
        self.assertFalse(list(support.glob(".mac-widget-stage.*")))
        self.assertFalse(list(support.glob(".mac-widget-backup.*")))

    def test_abrupt_kill_after_app_replacement_recovers_then_completes(self) -> None:
        first = self.make_bundle("CrashAppFirst", "first")
        self.assertEqual(self.install(first).returncode, 0)
        installed = self.home / "Applications" / "Statelet.app" / "Contents" / "MacOS" / "Statelet"
        original = installed.read_bytes()
        hooks = self.home / ".codex" / "hooks.json"
        original_hooks = hooks.read_bytes()

        second = self.make_bundle("CrashAppSecond", "second")
        expected = (second / "Contents" / "MacOS" / "Statelet").read_bytes()
        environment = os.environ.copy()
        environment["STATELET_INSTALL_CRASH_AT"] = "after-app"
        crashed = self.install(second, env=environment)

        self.assertEqual(crashed.returncode, -9, crashed.stderr)
        transaction = self.home / ".statelet-install-transaction"
        self.assertTrue((transaction / "journal.json").is_file())
        self.assertNotEqual(installed.read_bytes(), original)

        completed = self.install(second)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(installed.read_bytes(), expected)
        self.assertNotEqual(installed.read_bytes(), original)
        self.assertEqual(hooks.read_bytes(), original_hooks)
        self.assertFalse(transaction.exists())

    def test_abrupt_kill_after_support_publication_recovers_private_data_then_completes(self) -> None:
        legacy = self.home / "Library" / "Application Support" / "CodexPet"
        component = legacy / "mac-widget"
        component.mkdir(parents=True)
        (component / "MANAGED_BY_CODEX_PET").write_text(LEGACY_MARKER + "\n", encoding="utf-8")
        private_voice = legacy / "voice" / "profile.json"
        private_voice.parent.mkdir()
        private_payload = b"private-voice-before-crash"
        private_voice.write_bytes(private_payload)
        alpha_tool = legacy / "alpha-runtime" / "bin" / "ffmpeg"
        alpha_tool.parent.mkdir(parents=True)
        alpha_tool.write_bytes(b"private-alpha-runtime")
        board_file = legacy / "runtime" / "board-sentinel.txt"
        board_file.parent.mkdir()
        board_file.write_bytes(b"unrelated-board-state")
        bundle = self.make_bundle("CrashSupport", "published")
        environment = os.environ.copy()
        environment["STATELET_INSTALL_CRASH_AT"] = "after-support"

        crashed = self.install(bundle, env=environment)

        self.assertEqual(crashed.returncode, -9, crashed.stderr)
        transaction = self.home / ".statelet-install-transaction"
        canonical_voice = self.home / "Library" / "Application Support" / "Statelet" / "voice" / "profile.json"
        canonical_alpha_tool = self.home / "Library" / "Application Support" / "Statelet" / "alpha-runtime" / "bin" / "ffmpeg"
        self.assertEqual(canonical_voice.read_bytes(), private_payload)
        self.assertEqual(canonical_alpha_tool.read_bytes(), b"private-alpha-runtime")
        self.assertEqual(private_voice.read_bytes(), private_payload)
        self.assertEqual(board_file.read_bytes(), b"unrelated-board-state")
        self.assertTrue(transaction.exists())

        completed = self.install(bundle)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(canonical_voice.read_bytes(), private_payload)
        self.assertEqual(canonical_alpha_tool.read_bytes(), b"private-alpha-runtime")
        self.assertEqual(alpha_tool.read_bytes(), b"private-alpha-runtime")
        self.assertEqual(private_voice.read_bytes(), private_payload)
        self.assertEqual(board_file.read_bytes(), b"unrelated-board-state")
        self.assertFalse(component.exists())
        self.assertFalse(transaction.exists())

    def test_interrupted_transaction_fails_closed_if_installed_target_changed(self) -> None:
        first = self.make_bundle("CrashAmbiguousFirst", "first")
        self.assertEqual(self.install(first).returncode, 0)
        second = self.make_bundle("CrashAmbiguousSecond", "second")
        environment = os.environ.copy()
        environment["STATELET_INSTALL_CRASH_AT"] = "after-app"
        self.assertEqual(self.install(second, env=environment).returncode, -9)
        installed = self.home / "Applications" / "Statelet.app" / "Contents" / "MacOS" / "Statelet"
        installed.write_bytes(b"#!/bin/sh\n# unmanaged-newer-change\n")

        refused = self.install(second)

        self.assertEqual(refused.returncode, 74)
        self.assertIn("interrupted Statelet installation is ambiguous", refused.stderr)
        self.assertEqual(installed.read_bytes(), b"#!/bin/sh\n# unmanaged-newer-change\n")
        self.assertTrue((self.home / ".statelet-install-transaction" / "journal.json").exists())

    def test_rollback_reloads_only_previously_loaded_jobs(self) -> None:
        first = self.make_bundle("LoadedStateFirst", "first")
        initial = self.install(first)
        self.assertEqual(initial.returncode, 0, initial.stderr)
        statelet = self.home / "Applications" / "Statelet.app"
        legacy = self.home / "Applications" / "CodexPetMac.app"
        statelet.rename(self.base / "discarded-canonical.app")
        shutil.copytree(self.make_legacy_bundle("LoadedLegacy", "first"), legacy)

        second = self.make_bundle("LoadedStateSecond", "second")
        environment, log = self.fake_launchctl_environment(
            "com.coke1120.statelet.state-aggregator"
        )
        environment["CODEX_PET_INSTALL_FAIL_AT"] = "after-app"

        failed = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(second)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(failed.returncode, 70, failed.stderr)
        commands = log.read_text(encoding="utf-8").splitlines()
        bootstraps = [command for command in commands if command.startswith("bootstrap ")]
        self.assertEqual(len(bootstraps), 1)
        self.assertIn("state-aggregator.plist", bootstraps[0])
        self.assertNotIn("mac-player.plist", bootstraps[0])
        self.assertTrue(legacy.exists())
        self.assertFalse(statelet.exists())

    def test_uninstall_preserves_user_and_board_data(self) -> None:
        bundle = self.make_bundle("Uninstall")
        hooks_file = self.home / ".codex" / "hooks.json"
        hooks_file.parent.mkdir(parents=True)
        hooks_file.write_text(
            json.dumps(
                {
                    "other": {"preserve": True},
                    "hooks": {
                        "Stop": [
                            {"hooks": [{"type": "command", "command": "keep-me"}]}
                        ]
                    },
                }
            ),
            encoding="utf-8",
        )
        result = self.install(bundle)
        self.assertEqual(result.returncode, 0, result.stderr)
        installed_app = self.home / "Applications" / "Statelet.app"
        legacy_app = self.home / "Applications" / "CodexPetMac.app"
        subprocess.run(["ditto", str(installed_app), str(legacy_app)], check=True)
        support = self.home / "Library" / "Application Support" / "Statelet"
        media_map = support / "media" / "media-map.json"
        media_map.write_text('{"user":"preserve"}\n', encoding="utf-8")
        private_movie = support / "media" / "idle.mov"
        private_movie.write_bytes(b"user-private-media")
        legacy_support = self.home / "Library" / "Application Support" / "CodexPet"
        board_runtime = legacy_support / "runtime" / "board.txt"
        board_runtime.parent.mkdir(parents=True, exist_ok=True)
        board_runtime.write_text("preserve", encoding="utf-8")

        removed = subprocess.run(
            ["bash", str(UNINSTALL_SCRIPT), "--home", str(self.home), "--skip-launchctl"],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertFalse(installed_app.exists())
        self.assertTrue(legacy_app.exists())
        self.assertFalse((support / "Statelet").exists())
        self.assertFalse((self.home / "Library" / "LaunchAgents" / "com.coke1120.statelet.state-aggregator.plist").exists())
        self.assertFalse((self.home / "Library" / "LaunchAgents" / "com.coke1120.statelet.mac-player.plist").exists())
        self.assertEqual(media_map.read_text(encoding="utf-8"), '{"user":"preserve"}\n')
        self.assertEqual(private_movie.read_bytes(), b"user-private-media")
        self.assertEqual(board_runtime.read_text(encoding="utf-8"), "preserve")
        hooks = json.loads(hooks_file.read_text(encoding="utf-8"))
        self.assertEqual(hooks["other"], {"preserve": True})
        remaining_commands = [
            item.get("command")
            for groups in hooks["hooks"].values()
            for group in groups
            if isinstance(group, dict)
            for item in group.get("hooks", [])
            if isinstance(item, dict)
        ]
        self.assertFalse(
            [command for command in remaining_commands if "mac-widget/python/statelet_hook.py" in str(command)]
        )
        self.assertIn("keep-me", remaining_commands)

    def test_unmanaged_launch_agent_fails_before_mutation(self) -> None:
        bundle = self.make_bundle("Unmanaged")
        plist = self.home / "Library" / "LaunchAgents" / "com.coke1120.statelet.mac-player.plist"
        plist.parent.mkdir(parents=True)
        plist.parent.chmod(0o711)
        launch_agents_mode = plist.parent.stat().st_mode & 0o777
        original = plistlib.dumps({"Label": "someone.else"})
        plist.write_bytes(original)
        support = self.home / "Library" / "Application Support" / "Statelet"

        result = self.install(bundle)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to replace an unmanaged LaunchAgent", result.stderr)
        self.assertEqual(plist.read_bytes(), original)
        self.assertEqual(plist.parent.stat().st_mode & 0o777, launch_agents_mode)
        self.assertFalse(support.exists())
        self.assertFalse((self.home / "Applications" / "Statelet.app").exists())

    def test_managed_legacy_app_is_migrated_to_statelet(self) -> None:
        statelet = self.home / "Applications" / "Statelet.app"
        legacy = self.home / "Applications" / "CodexPetMac.app"
        legacy.parent.mkdir(parents=True)
        shutil.copytree(self.make_legacy_bundle("LegacyManaged", "legacy"), legacy)
        old_payload = (legacy / "Contents" / "MacOS" / "CodexPetMac").read_bytes()
        player_path = (
            self.home
            / "Library"
            / "LaunchAgents"
            / "com.coke1120.codex-pet.mac-player.plist"
        )
        player_path.parent.mkdir(parents=True)
        player_path.write_bytes(
            plistlib.dumps(
                {
                    "Label": "com.coke1120.codex-pet.mac-player",
                    "CodexPetMacManaged": LEGACY_MARKER,
                    "RunAtLoad": False,
                }
            )
        )

        second = self.make_bundle("MigratedStatelet", "new")
        migrated = self.install(second)
        self.assertEqual(migrated.returncode, 0, migrated.stderr)
        self.assertTrue(statelet.exists())
        self.assertFalse(legacy.exists())
        self.assertNotEqual(
            (statelet / "Contents" / "MacOS" / "Statelet").read_bytes(),
            old_payload,
        )
        player_path = self.home / "Library" / "LaunchAgents" / "com.coke1120.statelet.mac-player.plist"
        with player_path.open("rb") as handle:
            migrated_player = plistlib.load(handle)
        self.assertFalse(migrated_player["RunAtLoad"])

    def test_legacy_support_migration_preserves_private_data_byte_for_byte(self) -> None:
        legacy = self.home / "Library" / "Application Support" / "CodexPet"
        fixtures = {
            "media/idle.mov": b"representative-media\x00\xff",
            "voice/generated/idle/one.wav": b"representative-voice\x10\x20",
            "characters/chloe/library.json": b'{"character":"private"}\n',
            "sessions/active/state.json": b'{"state":"running"}\n',
            "alpha-runtime/bin/ffmpeg": b"private-alpha-toolchain",
            "runtime/current_state.json": b'{"state":"waiting"}\n',
        }
        for relative, payload in fixtures.items():
            path = legacy / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(payload)
        board_sentinel = legacy / "runtime" / "board-sentinel.txt"
        board_sentinel.write_bytes(b"unrelated-board-runtime")
        legacy_component = legacy / "mac-widget"
        legacy_component.mkdir()
        (legacy_component / "MANAGED_BY_CODEX_PET").write_text(LEGACY_MARKER + "\n", encoding="utf-8")

        installed = self.install(self.make_bundle("DataMigration"))
        self.assertEqual(installed.returncode, 0, installed.stderr)
        canonical = self.home / "Library" / "Application Support" / "Statelet"
        for relative, payload in fixtures.items():
            self.assertEqual((canonical / relative).read_bytes(), payload, relative)
            self.assertEqual((legacy / relative).read_bytes(), payload, relative)
        self.assertEqual(board_sentinel.read_bytes(), b"unrelated-board-runtime")
        self.assertFalse(legacy_component.exists())

    def test_legacy_uninstalled_but_retained_user_data_is_migrated(self) -> None:
        legacy = self.home / "Library" / "Application Support" / "CodexPet"
        fixtures = {
            "media/idle.mov": b"retained-private-media",
            "voice/profile.json": b"retained-private-voice",
            "characters/chloe/library.json": b"retained-private-character",
            "sessions/old/state.json": b"retained-private-session",
            "alpha-runtime/bin/ffmpeg": b"retained-private-alpha-runtime",
            "runtime/current_state.json": b"retained-private-current-state",
        }
        for relative, payload in fixtures.items():
            path = legacy / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(payload)
        board_sentinel = legacy / "runtime" / "board-sentinel.txt"
        board_sentinel.write_bytes(b"unrelated-board-runtime")
        unrelated = legacy / "user-notes.txt"
        unrelated.write_bytes(b"unrelated-root-data")
        self.assertFalse((legacy / "mac-widget").exists())
        self.assertFalse((self.home / "Applications" / "CodexPetMac.app").exists())

        installed = self.install(self.make_bundle("RetainedLegacyData"))

        self.assertEqual(installed.returncode, 0, installed.stderr)
        canonical = self.home / "Library" / "Application Support" / "Statelet"
        for relative, payload in fixtures.items():
            self.assertEqual((canonical / relative).read_bytes(), payload, relative)
            self.assertEqual((legacy / relative).read_bytes(), payload, relative)
        self.assertEqual(board_sentinel.read_bytes(), b"unrelated-board-runtime")
        self.assertEqual(unrelated.read_bytes(), b"unrelated-root-data")

    def test_completed_legacy_migration_allows_canonical_edits_on_reinstall(self) -> None:
        legacy = self.home / "Library" / "Application Support" / "CodexPet"
        legacy_voice = legacy / "voice" / "profile.json"
        legacy_voice.parent.mkdir(parents=True)
        legacy_voice.write_bytes(b"retained-legacy-voice")
        first = self.install(self.make_bundle("MigrationAttestedFirst", "first"))
        self.assertEqual(first.returncode, 0, first.stderr)
        canonical_voice = self.home / "Library" / "Application Support" / "Statelet" / "voice" / "profile.json"
        canonical_voice.write_bytes(b"newer-canonical-voice")

        second = self.install(self.make_bundle("MigrationAttestedSecond", "second"))

        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(canonical_voice.read_bytes(), b"newer-canonical-voice")
        self.assertEqual(legacy_voice.read_bytes(), b"retained-legacy-voice")
        manifest = self.home / "Library" / "Application Support" / "Statelet" / ".legacy-migration-v1.json"
        self.assertTrue(manifest.is_file())
        self.assertEqual(manifest.stat().st_mode & 0o777, 0o600)

    def test_completed_migration_preserves_intentional_canonical_subtree_absence(self) -> None:
        legacy = self.home / "Library" / "Application Support" / "CodexPet"
        legacy_voice = legacy / "voice" / "profile.json"
        legacy_voice.parent.mkdir(parents=True)
        legacy_voice.write_bytes(b"retained-legacy-voice")
        bundle = self.make_bundle("MigrationAttestedDeletion")
        self.assertEqual(self.install(bundle).returncode, 0)
        canonical_voice = self.home / "Library" / "Application Support" / "Statelet" / "voice"
        shutil.rmtree(canonical_voice)

        reinstalled = self.install(bundle)

        self.assertEqual(reinstalled.returncode, 0, reinstalled.stderr)
        self.assertFalse(canonical_voice.exists())
        self.assertEqual(legacy_voice.read_bytes(), b"retained-legacy-voice")

    def test_tampered_attestation_with_absent_destination_uses_first_migration_copy(self) -> None:
        legacy = self.home / "Library" / "Application Support" / "CodexPet"
        legacy_voice = legacy / "voice" / "profile.json"
        legacy_voice.parent.mkdir(parents=True)
        legacy_voice.write_bytes(b"retained-legacy-voice")
        bundle = self.make_bundle("MigrationTamperedAbsent")
        self.assertEqual(self.install(bundle).returncode, 0)
        canonical = self.home / "Library" / "Application Support" / "Statelet"
        shutil.rmtree(canonical / "voice")
        manifest = canonical / ".legacy-migration-v1.json"
        manifest.write_text('{"version":1,"source_identity":"tampered","subtrees":{}}\n', encoding="utf-8")
        manifest.chmod(0o600)

        reinstalled = self.install(bundle)

        self.assertEqual(reinstalled.returncode, 0, reinstalled.stderr)
        self.assertEqual((canonical / "voice" / "profile.json").read_bytes(), b"retained-legacy-voice")
        self.assertEqual(legacy_voice.read_bytes(), b"retained-legacy-voice")

    def test_tampered_migration_manifest_forces_safe_conflict_comparison(self) -> None:
        legacy = self.home / "Library" / "Application Support" / "CodexPet"
        legacy_voice = legacy / "voice" / "profile.json"
        legacy_voice.parent.mkdir(parents=True)
        legacy_voice.write_bytes(b"retained-legacy-voice")
        bundle = self.make_bundle("MigrationAttestationTampered")
        self.assertEqual(self.install(bundle).returncode, 0)
        canonical_voice = self.home / "Library" / "Application Support" / "Statelet" / "voice" / "profile.json"
        canonical_voice.write_bytes(b"newer-canonical-voice")
        manifest = self.home / "Library" / "Application Support" / "Statelet" / ".legacy-migration-v1.json"
        manifest.write_text('{"version":1,"source_identity":"tampered","subtrees":{}}\n', encoding="utf-8")
        manifest.chmod(0o600)

        failed = self.install(bundle)

        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("Refusing to overwrite conflicting Statelet data", failed.stderr)
        self.assertNotIn("profile.json", failed.stderr)
        self.assertEqual(canonical_voice.read_bytes(), b"newer-canonical-voice")
        self.assertEqual(legacy_voice.read_bytes(), b"retained-legacy-voice")

    def test_legacy_support_symlink_is_rejected_before_mutation(self) -> None:
        legacy_root = self.home / "Library" / "Application Support" / "CodexPet"
        component = legacy_root / "mac-widget"
        component.mkdir(parents=True)
        (component / "MANAGED_BY_CODEX_PET").write_text(LEGACY_MARKER + "\n", encoding="utf-8")
        external = self.base / "external-private.wav"
        external.write_bytes(b"must-not-copy")
        voice = legacy_root / "voice"
        voice.mkdir()
        (voice / "linked.wav").symlink_to(external)

        failed = self.install(self.make_bundle("RejectSymlink"))
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("Refusing unsafe legacy Statelet data", failed.stderr)
        self.assertFalse((self.home / "Applications" / "Statelet.app").exists())
        self.assertEqual(external.read_bytes(), b"must-not-copy")

    def test_legacy_support_root_symlink_is_rejected_before_classification(self) -> None:
        external = self.base / "external-legacy-support"
        component = external / "mac-widget"
        component.mkdir(parents=True)
        (component / "MANAGED_BY_CODEX_PET").write_text(LEGACY_MARKER + "\n", encoding="utf-8")
        sentinel = component / "external-sentinel.txt"
        sentinel.write_bytes(b"external-legacy-unchanged")
        application_support = self.home / "Library" / "Application Support"
        application_support.mkdir(parents=True)
        (application_support / "CodexPet").symlink_to(external, target_is_directory=True)
        bundle = self.make_bundle("RejectLegacySupportRootSymlink")
        label = "com.coke1120.statelet.state-aggregator"
        environment, log = self.fake_launchctl_environment(label)

        failed = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("Refusing unsafe Statelet support directory layout", failed.stderr)
        self.assertEqual(sentinel.read_bytes(), b"external-legacy-unchanged")
        self.assertTrue(component.exists())
        self.assertFalse((self.home / "Applications" / "Statelet.app").exists())
        self.assertFalse((self.home / ".statelet-install-transaction").exists())
        self.assertTrue((log.parent / "state" / label).exists())
        self.assertFalse(log.exists())

    def test_canonical_support_root_symlink_is_rejected_before_mutation(self) -> None:
        external = self.base / "external-canonical-support"
        component = external / "Statelet"
        component.mkdir(parents=True)
        (component / "MANAGED_BY_STATELET").write_text(MANAGED_MARKER + "\n", encoding="utf-8")
        sentinel = component / "external-sentinel.txt"
        sentinel.write_bytes(b"external-canonical-unchanged")
        application_support = self.home / "Library" / "Application Support"
        application_support.mkdir(parents=True)
        (application_support / "Statelet").symlink_to(external, target_is_directory=True)
        bundle = self.make_bundle("RejectCanonicalSupportRootSymlink")
        label = "com.coke1120.statelet.state-aggregator"
        environment, log = self.fake_launchctl_environment(label)

        failed = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("Refusing unsafe Statelet support directory layout", failed.stderr)
        self.assertEqual(sentinel.read_bytes(), b"external-canonical-unchanged")
        self.assertTrue(component.exists())
        self.assertFalse((self.home / "Applications" / "Statelet.app").exists())
        self.assertFalse((self.home / ".statelet-install-transaction").exists())
        self.assertTrue((log.parent / "state" / label).exists())
        self.assertFalse(log.exists())

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO fixture requires POSIX")
    def test_legacy_support_special_file_is_rejected_before_mutation(self) -> None:
        legacy_root = self.home / "Library" / "Application Support" / "CodexPet"
        component = legacy_root / "mac-widget"
        component.mkdir(parents=True)
        (component / "MANAGED_BY_CODEX_PET").write_text(LEGACY_MARKER + "\n", encoding="utf-8")
        runtime = legacy_root / "runtime"
        runtime.mkdir()
        os.mkfifo(runtime / "current_state.json")

        failed = self.install(self.make_bundle("RejectFIFO"))
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("Refusing unsafe legacy Statelet data", failed.stderr)
        self.assertFalse((self.home / "Applications" / "Statelet.app").exists())

    def test_support_migration_conflict_fails_closed_before_mutation(self) -> None:
        legacy_root = self.home / "Library" / "Application Support" / "CodexPet"
        component = legacy_root / "mac-widget"
        component.mkdir(parents=True)
        (component / "MANAGED_BY_CODEX_PET").write_text(LEGACY_MARKER + "\n", encoding="utf-8")
        legacy = legacy_root / "voice"
        canonical = self.home / "Library" / "Application Support" / "Statelet" / "voice"
        legacy.mkdir(parents=True)
        canonical.mkdir(parents=True)
        (legacy / "library.json").write_bytes(b"legacy-private")
        (canonical / "library.json").write_bytes(b"newer-private")

        failed = self.install(self.make_bundle("Conflict"))
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("Refusing to overwrite conflicting Statelet data", failed.stderr)
        self.assertEqual((legacy / "library.json").read_bytes(), b"legacy-private")
        self.assertEqual((canonical / "library.json").read_bytes(), b"newer-private")
        self.assertFalse((self.home / "Applications" / "Statelet.app").exists())

    def test_identical_partial_support_migration_is_resumable(self) -> None:
        legacy_root = self.home / "Library" / "Application Support" / "CodexPet"
        component = legacy_root / "mac-widget"
        component.mkdir(parents=True)
        (component / "MANAGED_BY_CODEX_PET").write_text(LEGACY_MARKER + "\n", encoding="utf-8")
        legacy = legacy_root / "voice"
        canonical = self.home / "Library" / "Application Support" / "Statelet" / "voice"
        legacy.mkdir(parents=True)
        canonical.mkdir(parents=True)
        payload = b"already-copied-private-data"
        (legacy / "library.json").write_bytes(payload)
        (canonical / "library.json").write_bytes(payload)

        installed = self.install(self.make_bundle("Resumable"))
        self.assertEqual(installed.returncode, 0, installed.stderr)
        self.assertEqual((legacy / "library.json").read_bytes(), payload)
        self.assertEqual((canonical / "library.json").read_bytes(), payload)

    def test_support_migration_rolls_back_exactly_after_injected_failure(self) -> None:
        legacy_root = self.home / "Library" / "Application Support" / "CodexPet"
        component = legacy_root / "mac-widget"
        component.mkdir(parents=True)
        (component / "MANAGED_BY_CODEX_PET").write_text(LEGACY_MARKER + "\n", encoding="utf-8")
        legacy = legacy_root / "voice"
        legacy.mkdir(parents=True)
        payload = b"rollback-private-data"
        (legacy / "profile.json").write_bytes(payload)
        environment = os.environ.copy()
        environment["STATELET_INSTALL_FAIL_AT"] = "after-support"

        failed = self.install(self.make_bundle("MigrationRollback"), env=environment)
        self.assertEqual(failed.returncode, 70, failed.stderr)
        self.assertEqual((legacy / "profile.json").read_bytes(), payload)
        self.assertFalse((self.home / "Library" / "Application Support" / "Statelet" / "voice").exists())
        self.assertFalse((self.home / "Applications" / "Statelet.app").exists())

    def test_runtime_file_only_migration_failure_removes_journaled_parent(self) -> None:
        legacy = self.home / "Library" / "Application Support" / "CodexPet"
        current_state = legacy / "runtime" / "current_state.json"
        current_state.parent.mkdir(parents=True)
        payload = b'{"state":"retained-runtime-only"}\n'
        current_state.write_bytes(payload)
        hooks_file = self.home / ".codex" / "hooks.json"
        hooks_file.parent.mkdir()
        hooks_file.write_text(json.dumps({"unrelated": {"keep": True}, "hooks": {}}), encoding="utf-8")
        original_hooks = hooks_file.read_bytes()
        environment = os.environ.copy()
        environment["STATELET_INSTALL_FAIL_AT"] = "after-support"

        failed = self.install(self.make_bundle("RuntimeOnlyRollback"), env=environment)

        self.assertEqual(failed.returncode, 70, failed.stderr)
        self.assertEqual(current_state.read_bytes(), payload)
        self.assertFalse((self.home / "Library" / "Application Support" / "Statelet").exists())
        self.assertFalse((self.home / "Applications" / "Statelet.app").exists())
        self.assertFalse((self.home / ".statelet-install-transaction").exists())
        self.assertEqual(hooks_file.read_bytes(), original_hooks)

    def test_runtime_symlink_destination_is_rejected_before_external_write(self) -> None:
        legacy = self.home / "Library" / "Application Support" / "CodexPet"
        current_state = legacy / "runtime" / "current_state.json"
        current_state.parent.mkdir(parents=True)
        current_state.write_bytes(b'{"state":"legacy"}\n')
        support = self.home / "Library" / "Application Support" / "Statelet"
        support.mkdir(parents=True)
        external = self.base / "external-runtime"
        external.mkdir()
        sentinel = external / "sentinel.txt"
        sentinel.write_bytes(b"external-unchanged")
        (support / "runtime").symlink_to(external, target_is_directory=True)
        hooks_file = self.home / ".codex" / "hooks.json"
        hooks_file.parent.mkdir()
        hooks_file.write_text(json.dumps({"hooks": {}, "unrelated": {"keep": True}}), encoding="utf-8")
        original_hooks = hooks_file.read_bytes()

        failed = self.install(self.make_bundle("RejectRuntimeSymlink"))

        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(sentinel.read_bytes(), b"external-unchanged")
        self.assertFalse((external / "current_state.json").exists())
        self.assertEqual(current_state.read_bytes(), b'{"state":"legacy"}\n')
        self.assertFalse((self.home / "Applications" / "Statelet.app").exists())
        self.assertEqual(hooks_file.read_bytes(), original_hooks)
        self.assertFalse((self.home / ".statelet-install-transaction").exists())

    def test_codex_directory_symlink_is_rejected_before_hook_publication(self) -> None:
        external = self.base / "external-codex"
        external.mkdir()
        sentinel = external / "sentinel.txt"
        sentinel.write_bytes(b"external-codex-unchanged")
        (self.home / ".codex").symlink_to(external, target_is_directory=True)

        failed = self.install(self.make_bundle("RejectCodexSymlink"))

        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(sentinel.read_bytes(), b"external-codex-unchanged")
        self.assertFalse((external / "hooks.json").exists())
        self.assertFalse((self.home / "Applications" / "Statelet.app").exists())
        self.assertFalse((self.home / ".statelet-install-transaction").exists())

    def test_parent_swap_after_descriptor_open_never_writes_external_directory(self) -> None:
        applications = self.home / "Applications"
        applications.mkdir()
        held_directory = self.base / "held-applications"
        external = self.base / "external-applications"
        external.mkdir()
        sentinel = external / "sentinel.txt"
        sentinel.write_bytes(b"external-unchanged")
        gate = self.home / "parent-fd-gate"
        environment = os.environ.copy()
        environment["HOME"] = str(self.home)
        environment["STATELET_INSTALL_TEST_PARENT_FD_GATE"] = str(gate)
        process = subprocess.Popen(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(self.make_bundle("ParentSwap")), "--skip-launchctl"],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
        )
        import time
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and not Path(f"{gate}.ready").exists():
            time.sleep(0.01)
        if not Path(f"{gate}.ready").exists():
            process.terminate()
            try:
                _, stderr = process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                _, stderr = process.communicate(timeout=5)
            self.fail(f"parent descriptor gate was not reached: {stderr}")
        applications.rename(held_directory)
        applications.symlink_to(external, target_is_directory=True)
        Path(f"{gate}.release").touch()
        _, stderr = process.communicate(timeout=15)

        self.assertEqual(sentinel.read_bytes(), b"external-unchanged")
        self.assertFalse((external / "Statelet.app").exists())
        self.assertNotEqual(process.returncode, 0, stderr)
        self.assertTrue((self.home / ".statelet-install-transaction" / "journal.json").exists())
        self.assertFalse((held_directory / "Statelet.app").exists())
        applications.unlink()
        held_directory.rename(applications)
        environment.pop("STATELET_INSTALL_TEST_PARENT_FD_GATE")
        recovered = self.install(self.make_bundle("ParentSwapRecovery"), env=environment)
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertFalse((self.home / ".statelet-install-transaction").exists())

    def test_recovery_parent_swap_fails_closed_without_external_write(self) -> None:
        first = self.make_bundle("RecoveryParentFirst", "first")
        self.assertEqual(self.install(first).returncode, 0)
        second = self.make_bundle("RecoveryParentSecond", "second")
        environment = os.environ.copy()
        environment["STATELET_INSTALL_CRASH_AT"] = "after-app"
        self.assertEqual(self.install(second, env=environment).returncode, -9)
        applications = self.home / "Applications"
        detached = self.base / "detached-recovery-applications"
        external = self.base / "external-recovery-applications"
        external.mkdir()
        sentinel = external / "sentinel.txt"
        sentinel.write_bytes(b"external-recovery-unchanged")
        applications.rename(detached)
        applications.symlink_to(external, target_is_directory=True)
        environment.pop("STATELET_INSTALL_CRASH_AT")

        failed = self.install(second, env=environment)

        self.assertEqual(failed.returncode, 74, failed.stderr)
        self.assertEqual(sentinel.read_bytes(), b"external-recovery-unchanged")
        self.assertFalse((external / "Statelet.app").exists())
        self.assertTrue((self.home / ".statelet-install-transaction" / "journal.json").exists())

    def test_unmanaged_legacy_app_is_preserved_while_statelet_installs(self) -> None:
        legacy = self.home / "Applications" / "CodexPetMac.app"
        contents = legacy / "Contents"
        contents.mkdir(parents=True)
        sentinel = contents / "unmanaged.txt"
        sentinel.write_text("keep", encoding="utf-8")
        (contents / "Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleIdentifier": "example.unmanaged",
                    "CodexPetManaged": MANAGED_MARKER,
                }
            )
        )

        bundle = self.make_bundle("PreserveLegacy")
        result = self.install(bundle)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")
        self.assertTrue((self.home / "Applications" / "Statelet.app").exists())

    def test_unmanaged_statelet_destination_is_refused(self) -> None:
        destination = self.home / "Applications" / "Statelet.app"
        contents = destination / "Contents"
        contents.mkdir(parents=True)
        destination.parent.chmod(0o751)
        applications_mode = destination.parent.stat().st_mode & 0o777
        sentinel = contents / "unmanaged.txt"
        sentinel.write_text("keep", encoding="utf-8")
        (contents / "Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleIdentifier": "example.unmanaged",
                    "CodexPetManaged": MANAGED_MARKER,
                }
            )
        )

        bundle = self.make_bundle("RefuseStatelet")
        result = self.install(bundle)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to replace an unmanaged app", result.stderr)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")
        self.assertEqual(destination.parent.stat().st_mode & 0o777, applications_mode)
        self.assertFalse((self.home / "Library").exists())
        self.assertFalse((self.home / ".codex").exists())

    def test_install_bootout_failure_preserves_files_and_loaded_state(self) -> None:
        first = self.make_bundle("BootoutFirst", "first")
        installed = self.install(first)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        statelet = self.home / "Applications" / "Statelet.app"
        old_payload = (statelet / "Contents" / "MacOS" / "Statelet").read_bytes()
        second = self.make_bundle("BootoutSecond", "second")
        aggregator = "com.coke1120.statelet.state-aggregator"
        player = "com.coke1120.statelet.mac-player"
        environment, _ = self.fake_launchctl_environment(
            aggregator,
            player,
            fail_action="bootout",
            fail_label=aggregator,
        )

        failed = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(second)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(failed.returncode, 72, failed.stderr)
        self.assertIn("installation was not applied", failed.stderr)
        self.assertEqual(
            (statelet / "Contents" / "MacOS" / "Statelet").read_bytes(),
            old_payload,
        )

    def test_install_reports_incomplete_launchd_rollback(self) -> None:
        first = self.make_bundle("RollbackLaunchFirst", "first")
        installed = self.install(first)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        second = self.make_bundle("RollbackLaunchSecond", "second")
        aggregator = "com.coke1120.statelet.state-aggregator"
        environment, _ = self.fake_launchctl_environment(
            aggregator,
            fail_action="bootstrap",
            fail_label=aggregator,
        )
        environment["CODEX_PET_INSTALL_FAIL_AT"] = "after-app"

        failed = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(second)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(failed.returncode, 71, failed.stderr)
        self.assertIn("launchd rollback was incomplete", failed.stderr)

    def test_fresh_install_player_bootstrap_failure_retains_sealed_files_for_forward_recovery(self) -> None:
        bundle = self.make_bundle("FreshPlayerBootstrapFailure")
        aggregator = "com.coke1120.statelet.state-aggregator"
        player = "com.coke1120.statelet.mac-player"
        environment, log = self.fake_launchctl_environment(
            fail_action="bootstrap",
            fail_label=player,
        )

        failed = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(failed.returncode, 71, failed.stderr)
        self.assertIn("launchd rollback was incomplete", failed.stderr)
        state = log.parent / "state"
        self.assertTrue((state / aggregator).exists())
        self.assertFalse((state / player).exists())
        self.assertTrue((self.home / "Applications" / "Statelet.app").exists())
        self.assertTrue((self.home / "Library" / "Application Support" / "Statelet").exists())
        transaction = self.home / ".statelet-install-transaction"
        self.assertEqual(json.loads((transaction / "journal.json").read_text())["state"], "files-committed")
        commands = log.read_text(encoding="utf-8").splitlines()
        self.assertTrue(any(command.startswith("bootstrap ") and "state-aggregator.plist" in command for command in commands))
        environment["CODEX_PET_FAKE_FAIL_ACTION"] = ""
        environment["CODEX_PET_FAKE_FAIL_LABEL"] = ""

        recovered = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertTrue((state / aggregator).exists())
        self.assertTrue((state / player).exists())
        self.assertFalse(transaction.exists())

    def test_immediate_runtime_writes_start_only_after_files_are_committed(self) -> None:
        bundle = self.make_bundle("ImmediateRuntimeWriter")
        aggregator = "com.coke1120.statelet.state-aggregator"
        player = "com.coke1120.statelet.mac-player"
        environment, _ = self.fake_launchctl_environment()
        phase = self.enable_fake_runtime_writer(environment)

        installed = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(installed.returncode, 0, installed.stderr)
        self.assertEqual(phase.read_text(encoding="utf-8"), "files-committed\n")
        support = self.home / "Library" / "Application Support" / "Statelet"
        current_state = json.loads((support / "runtime" / "current_state.json").read_text(encoding="utf-8"))
        self.assertEqual(current_state["source"], "aggregate")
        self.assertTrue((support / "logs" / "state-aggregator.out.log").is_file())
        self.assertTrue((support / "logs" / "state-aggregator.err.log").is_file())
        state = Path(environment["CODEX_PET_FAKE_LAUNCH_STATE"])
        self.assertTrue((state / aggregator).exists())
        self.assertTrue((state / player).exists())
        self.assertFalse((self.home / ".statelet-install-transaction").exists())

    def test_post_files_commit_immutable_tamper_fails_final_commit_closed(self) -> None:
        bundle = self.make_bundle("PostFilesCommitImmutableTamper")
        environment, _ = self.fake_launchctl_environment()
        installed = self.home / "Applications" / "Statelet.app" / "Contents" / "MacOS" / "Statelet"
        environment.update(
            {
                "STATELET_FAKE_TAMPER_LABEL": "com.coke1120.statelet.state-aggregator",
                "STATELET_FAKE_TAMPER_PATH": str(installed),
            }
        )

        failed = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(failed.returncode, 74, failed.stderr)
        self.assertIn("file rollback was ambiguous", failed.stderr)
        transaction = self.home / ".statelet-install-transaction"
        self.assertEqual(json.loads((transaction / "journal.json").read_text())["state"], "files-committed")
        self.assertIn(b"tampered after file commit", installed.read_bytes())

    def test_crash_after_files_commit_recovers_forward_without_republishing_files(self) -> None:
        first = self.make_bundle("FilesCommittedFirst", "first")
        self.assertEqual(self.install(first).returncode, 0)
        second = self.make_bundle("FilesCommittedSecond", "second")
        expected = (second / "Contents" / "MacOS" / "Statelet").read_bytes()
        aggregator = "com.coke1120.statelet.state-aggregator"
        player = "com.coke1120.statelet.mac-player"
        environment, _ = self.fake_launchctl_environment(aggregator, player)
        environment["STATELET_INSTALL_CRASH_AT"] = "after-files-commit"

        crashed = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(second)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(crashed.returncode, -9, crashed.stderr)
        installed = self.home / "Applications" / "Statelet.app" / "Contents" / "MacOS" / "Statelet"
        self.assertEqual(installed.read_bytes(), expected)
        transaction = self.home / ".statelet-install-transaction"
        journal = json.loads((transaction / "journal.json").read_text(encoding="utf-8"))
        self.assertEqual(journal["state"], "files-committed")
        self.assertEqual(journal["launch"]["desired"], [True, True, False, False])
        environment.pop("STATELET_INSTALL_CRASH_AT")

        recovered = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(first)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertEqual(installed.read_bytes(), expected)
        state = Path(environment["CODEX_PET_FAKE_LAUNCH_STATE"])
        self.assertTrue((state / aggregator).exists())
        self.assertTrue((state / player).exists())
        self.assertFalse(transaction.exists())

    def test_files_committed_recovery_rejects_missing_desired_launch_state(self) -> None:
        bundle = self.make_bundle("FilesCommittedMissingDesired")
        environment, _ = self.fake_launchctl_environment()
        environment["STATELET_INSTALL_CRASH_AT"] = "after-files-commit"
        crashed = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(crashed.returncode, -9, crashed.stderr)
        transaction = self.home / ".statelet-install-transaction"
        journal_path = transaction / "journal.json"
        journal = json.loads(journal_path.read_text(encoding="utf-8"))
        journal["launch"].pop("desired")
        journal_path.write_text(json.dumps(journal, separators=(",", ":")) + "\n", encoding="utf-8")
        journal_path.chmod(0o600)
        environment.pop("STATELET_INSTALL_CRASH_AT")

        refused = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(refused.returncode, 74, refused.stderr)
        self.assertIn("interrupted Statelet installation is ambiguous", refused.stderr)
        self.assertEqual(json.loads(journal_path.read_text(encoding="utf-8"))["state"], "files-committed")
        self.assertTrue((self.home / "Applications" / "Statelet.app").exists())

    def test_files_committed_recovery_rejects_tampered_handoff_identity(self) -> None:
        bundle = self.make_bundle("FilesCommittedHandoffIdentity")
        environment, _ = self.fake_launchctl_environment()
        environment["STATELET_INSTALL_CRASH_AT"] = "after-files-commit"
        crashed = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(crashed.returncode, -9, crashed.stderr)
        transaction = self.home / ".statelet-install-transaction"
        journal_path = transaction / "journal.json"
        journal = json.loads(journal_path.read_text(encoding="utf-8"))
        journal["handoff"]["runtime"]["identity"][1] += 1
        journal_path.write_text(json.dumps(journal, separators=(",", ":")) + "\n", encoding="utf-8")
        journal_path.chmod(0o600)
        environment.pop("STATELET_INSTALL_CRASH_AT")

        refused = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(refused.returncode, 74, refused.stderr)
        self.assertIn("interrupted Statelet installation is ambiguous", refused.stderr)
        self.assertTrue(transaction.exists())

    def test_launch_plist_swap_after_bootstrap_fails_closed(self) -> None:
        bundle = self.make_bundle("LaunchPlistPostBootstrapSwap")
        environment, _ = self.fake_launchctl_environment()
        plist = self.home / "Library" / "LaunchAgents" / "com.coke1120.statelet.state-aggregator.plist"
        environment.update(
            {
                "STATELET_FAKE_TAMPER_LABEL": "com.coke1120.statelet.state-aggregator",
                "STATELET_FAKE_TAMPER_PATH": str(plist),
            }
        )

        failed = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(failed.returncode, 74, failed.stderr)
        transaction = self.home / ".statelet-install-transaction"
        self.assertEqual(json.loads((transaction / "journal.json").read_text())["state"], "files-committed")
        self.assertIn(b"tampered after file commit", plist.read_bytes())

    def test_files_committed_recovery_rejects_immutable_target_tamper(self) -> None:
        bundle = self.make_bundle("FilesCommittedImmutableTamper")
        environment, _ = self.fake_launchctl_environment()
        environment["STATELET_INSTALL_CRASH_AT"] = "after-files-commit"
        crashed = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(crashed.returncode, -9, crashed.stderr)
        installed = self.home / "Applications" / "Statelet.app" / "Contents" / "MacOS" / "Statelet"
        installed.write_bytes(installed.read_bytes() + b"\n# immutable tamper\n")
        transaction = self.home / ".statelet-install-transaction"
        environment.pop("STATELET_INSTALL_CRASH_AT")

        refused = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(refused.returncode, 74, refused.stderr)
        self.assertIn("interrupted Statelet installation is ambiguous", refused.stderr)
        self.assertEqual(json.loads((transaction / "journal.json").read_text())["state"], "files-committed")

    def test_files_committed_recovery_rejects_handed_off_current_state_symlink(self) -> None:
        legacy = self.home / "Library" / "Application Support" / "CodexPet"
        current_state = legacy / "runtime" / "current_state.json"
        current_state.parent.mkdir(parents=True)
        current_state.write_text('{"state":"idle"}\n', encoding="utf-8")
        bundle = self.make_bundle("FilesCommittedCurrentStateSymlink")
        environment, _ = self.fake_launchctl_environment()
        environment["STATELET_INSTALL_CRASH_AT"] = "after-files-commit"
        crashed = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(crashed.returncode, -9, crashed.stderr)
        canonical = self.home / "Library" / "Application Support" / "Statelet" / "runtime" / "current_state.json"
        replacement = self.base / "untrusted-current-state.json"
        replacement.write_text('{"state":"waiting"}\n', encoding="utf-8")
        canonical.unlink()
        canonical.symlink_to(replacement)
        transaction = self.home / ".statelet-install-transaction"
        environment.pop("STATELET_INSTALL_CRASH_AT")

        refused = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(refused.returncode, 74, refused.stderr)
        self.assertIn("interrupted Statelet installation is ambiguous", refused.stderr)
        self.assertTrue(canonical.is_symlink())
        self.assertEqual(json.loads((transaction / "journal.json").read_text())["state"], "files-committed")

    def test_fresh_files_committed_recovery_rejects_new_current_state_symlink(self) -> None:
        bundle = self.make_bundle("FreshCurrentStateSymlink")
        environment, _ = self.fake_launchctl_environment()
        environment["STATELET_INSTALL_CRASH_AT"] = "after-files-commit"
        crashed = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(crashed.returncode, -9, crashed.stderr)
        support = self.home / "Library" / "Application Support" / "Statelet"
        canonical = support / "runtime" / "current_state.json"
        replacement = self.base / "fresh-untrusted-current-state.json"
        replacement.write_text('{"state":"waiting"}\n', encoding="utf-8")
        canonical.symlink_to(replacement)
        transaction = self.home / ".statelet-install-transaction"
        environment.pop("STATELET_INSTALL_CRASH_AT")

        refused = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(refused.returncode, 74, refused.stderr)
        self.assertIn("interrupted Statelet installation is ambiguous", refused.stderr)
        self.assertTrue(canonical.is_symlink())
        self.assertEqual(json.loads((transaction / "journal.json").read_text())["state"], "files-committed")

    def test_files_committed_recovery_rejects_preexisting_logs_root_replacement(self) -> None:
        support = self.home / "Library" / "Application Support" / "Statelet"
        logs = support / "logs"
        logs.mkdir(parents=True)
        (logs / "preserved.log").write_text("before install\n", encoding="utf-8")
        bundle = self.make_bundle("LogsRootReplacement")
        environment, _ = self.fake_launchctl_environment()
        environment["STATELET_INSTALL_CRASH_AT"] = "after-files-commit"
        crashed = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(crashed.returncode, -9, crashed.stderr)
        displaced = support / "displaced-logs"
        logs.rename(displaced)
        logs.mkdir()
        (logs / "replacement.log").write_text("replacement\n", encoding="utf-8")
        transaction = self.home / ".statelet-install-transaction"
        environment.pop("STATELET_INSTALL_CRASH_AT")

        refused = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(refused.returncode, 74, refused.stderr)
        self.assertIn("interrupted Statelet installation is ambiguous", refused.stderr)
        self.assertEqual(json.loads((transaction / "journal.json").read_text())["state"], "files-committed")
        self.assertTrue((displaced / "preserved.log").is_file())

    def test_files_committed_recovery_rejects_non_allowlisted_launch_metadata(self) -> None:
        bundle = self.make_bundle("FilesCommittedLaunchAllowlist")
        environment, _ = self.fake_launchctl_environment()
        environment["STATELET_INSTALL_CRASH_AT"] = "after-files-commit"
        crashed = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(crashed.returncode, -9, crashed.stderr)
        transaction = self.home / ".statelet-install-transaction"
        journal_path = transaction / "journal.json"
        journal = json.loads(journal_path.read_text(encoding="utf-8"))
        journal["launch"]["labels"][0] = "com.example.untrusted"
        journal_path.write_text(json.dumps(journal, separators=(",", ":")) + "\n", encoding="utf-8")
        journal_path.chmod(0o600)
        environment.pop("STATELET_INSTALL_CRASH_AT")

        refused = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(refused.returncode, 74, refused.stderr)
        self.assertIn("interrupted Statelet installation is ambiguous", refused.stderr)
        self.assertTrue(transaction.exists())

    def test_files_committed_recovery_rejects_unsealed_desired_launch_state(self) -> None:
        bundle = self.make_bundle("FilesCommittedDesiredLaunch")
        environment, _ = self.fake_launchctl_environment()
        environment["STATELET_INSTALL_CRASH_AT"] = "after-files-commit"
        crashed = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(crashed.returncode, -9, crashed.stderr)
        transaction = self.home / ".statelet-install-transaction"
        journal_path = transaction / "journal.json"
        journal = json.loads(journal_path.read_text(encoding="utf-8"))
        journal["launch"]["desired"] = [False, True, True, True]
        journal_path.write_text(json.dumps(journal, separators=(",", ":")) + "\n", encoding="utf-8")
        journal_path.chmod(0o600)
        environment.pop("STATELET_INSTALL_CRASH_AT")

        refused = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(refused.returncode, 74, refused.stderr)
        self.assertIn("interrupted Statelet installation is ambiguous", refused.stderr)
        self.assertTrue(transaction.exists())
        state = Path(environment["CODEX_PET_FAKE_LAUNCH_STATE"])
        self.assertFalse(any(state.iterdir()))

    def test_files_committed_recovery_rejects_operation_outside_allowlist_before_open(self) -> None:
        bundle = self.make_bundle("FilesCommittedOperationAllowlist")
        environment, _ = self.fake_launchctl_environment()
        environment["STATELET_INSTALL_CRASH_AT"] = "after-files-commit"
        crashed = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(crashed.returncode, -9, crashed.stderr)
        transaction = self.home / ".statelet-install-transaction"
        journal_path = transaction / "journal.json"
        journal = json.loads(journal_path.read_text(encoding="utf-8"))
        sentinel = self.base / "outside-allowlist"
        sentinel.mkdir()
        journal["operations"][0]["target"] = str(sentinel / "missing")
        journal_path.write_text(json.dumps(journal, separators=(",", ":")) + "\n", encoding="utf-8")
        journal_path.chmod(0o600)
        environment.pop("STATELET_INSTALL_CRASH_AT")

        refused = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(refused.returncode, 74, refused.stderr)
        self.assertIn("interrupted Statelet installation is ambiguous", refused.stderr)
        self.assertTrue(transaction.exists())
        self.assertEqual(list(sentinel.iterdir()), [])

    def test_skip_launchctl_crash_after_files_commit_recovers_without_launch_mutation(self) -> None:
        first = self.make_bundle("SkipLaunchFilesFirst", "first")
        self.assertEqual(self.install(first).returncode, 0)
        second = self.make_bundle("SkipLaunchFilesSecond", "second")
        expected = (second / "Contents" / "MacOS" / "Statelet").read_bytes()
        fake_bin = self.base / "skip-launch-fake-bin"
        fake_bin.mkdir()
        launch_log = fake_bin / "launchctl.log"
        launchctl = fake_bin / "launchctl"
        launchctl.write_text(f"#!/bin/sh\nprintf '%s\\n' \"$*\" >> {shlex.quote(str(launch_log))}\nexit 99\n", encoding="utf-8")
        launchctl.chmod(0o755)
        environment = os.environ.copy()
        environment["PATH"] = f"{fake_bin}:{environment['PATH']}"
        environment["STATELET_INSTALL_CRASH_AT"] = "after-files-commit"

        crashed = self.install(second, env=environment)

        self.assertEqual(crashed.returncode, -9, crashed.stderr)
        transaction = self.home / ".statelet-install-transaction"
        journal = json.loads((transaction / "journal.json").read_text(encoding="utf-8"))
        self.assertEqual(journal["state"], "files-committed")
        self.assertEqual(journal["launch"], {"skipped": True})
        environment.pop("STATELET_INSTALL_CRASH_AT")
        recovered = self.install(first, env=environment)

        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        installed = self.home / "Applications" / "Statelet.app" / "Contents" / "MacOS" / "Statelet"
        self.assertEqual(installed.read_bytes(), expected)
        self.assertFalse(transaction.exists())
        self.assertFalse(launch_log.exists())

    def test_active_partial_transaction_has_no_forward_promotion_surface(self) -> None:
        bundle = self.make_bundle("NoForwardPromotion")
        environment = os.environ.copy()
        environment["STATELET_INSTALL_CRASH_AT"] = "after-app"
        crashed = self.install(bundle, env=environment)
        self.assertEqual(crashed.returncode, -9, crashed.stderr)
        transaction = self.home / ".statelet-install-transaction"
        self.assertEqual(json.loads((transaction / "journal.json").read_text())["state"], "active")
        environment.pop("STATELET_INSTALL_CRASH_AT")

        refused = self.install(bundle, "--forward-seal-transaction", env=environment)

        self.assertEqual(refused.returncode, 2, refused.stderr)
        self.assertIn("Unknown option", refused.stderr)
        self.assertEqual(json.loads((transaction / "journal.json").read_text())["state"], "active")

    def test_skip_launch_files_committed_rejects_empty_operations_and_retains_backups(self) -> None:
        self.assert_sealed_operation_tamper_is_rejected(skip_launchctl=True, empty=True)

    def test_skip_launch_files_committed_rejects_truncated_operations_and_retains_backups(self) -> None:
        self.assert_sealed_operation_tamper_is_rejected(skip_launchctl=True, empty=False)

    def test_launch_files_committed_rejects_empty_operations_and_retains_backups(self) -> None:
        self.assert_sealed_operation_tamper_is_rejected(skip_launchctl=False, empty=True)

    def test_launch_files_committed_rejects_truncated_operations_and_retains_backups(self) -> None:
        self.assert_sealed_operation_tamper_is_rejected(skip_launchctl=False, empty=False)

    def test_recomputed_seal_omitting_app_backup_operation_retains_transaction_and_backup(self) -> None:
        first = self.make_bundle("OmittedAppBackupFirst", "first")
        second = self.make_bundle("OmittedAppBackupSecond", "second")
        self.assertEqual(self.install(first).returncode, 0)
        environment = os.environ.copy()
        environment["STATELET_INSTALL_CRASH_AT"] = "after-files-commit"
        crashed = self.install(second, env=environment)
        self.assertEqual(crashed.returncode, -9, crashed.stderr)
        transaction = self.home / ".statelet-install-transaction"
        journal_path = transaction / "journal.json"
        journal = json.loads(journal_path.read_text(encoding="utf-8"))
        app_target = self.home / "Applications" / "Statelet.app"
        removed = [
            operation for operation in journal["operations"]
            if operation.get("kind") == "backup" and Path(operation.get("target", "")) == app_target
        ]
        self.assertEqual(len(removed), 1)
        app_backup = Path(removed[0]["source"])
        self.assertTrue(app_backup.exists())
        journal["operations"].remove(removed[0])
        self.recompute_transaction_seal(journal)
        journal_path.write_text(json.dumps(journal, separators=(",", ":")) + "\n", encoding="utf-8")
        journal_path.chmod(0o600)
        environment.pop("STATELET_INSTALL_CRASH_AT")

        refused = self.install(second, env=environment)

        self.assertEqual(refused.returncode, 74, refused.stderr)
        self.assertTrue(transaction.exists())
        self.assertTrue(app_backup.exists())

    def test_recomputed_seal_omitting_fresh_media_map_install_rejects_live_tamper(self) -> None:
        bundle = self.make_bundle("OmittedFreshMediaMap")
        environment = os.environ.copy()
        environment["STATELET_INSTALL_CRASH_AT"] = "after-files-commit"
        crashed = self.install(bundle, env=environment)
        self.assertEqual(crashed.returncode, -9, crashed.stderr)
        transaction = self.home / ".statelet-install-transaction"
        journal_path = transaction / "journal.json"
        journal = json.loads(journal_path.read_text(encoding="utf-8"))
        media_map = self.home / "Library" / "Application Support" / "Statelet" / "media" / "media-map.json"
        removed = [
            operation for operation in journal["operations"]
            if operation.get("kind") == "install" and Path(operation.get("target", "")) == media_map
        ]
        self.assertEqual(len(removed), 1)
        journal["operations"].remove(removed[0])
        media_map.write_text('{"unvalidated":true}\n', encoding="utf-8")
        self.recompute_transaction_seal(journal)
        journal_path.write_text(json.dumps(journal, separators=(",", ":")) + "\n", encoding="utf-8")
        journal_path.chmod(0o600)
        environment.pop("STATELET_INSTALL_CRASH_AT")

        refused = self.install(bundle, env=environment)

        self.assertEqual(refused.returncode, 74, refused.stderr)
        self.assertTrue(transaction.exists())
        self.assertEqual(media_map.read_text(encoding="utf-8"), '{"unvalidated":true}\n')

    def test_sigkill_after_first_bootout_recovers_original_launch_jobs(self) -> None:
        bundle = self.make_bundle("CrashAfterFirstBootout")
        aggregator = "com.coke1120.statelet.state-aggregator"
        player = "com.coke1120.statelet.mac-player"
        environment, log = self.fake_launchctl_environment(aggregator, player)
        launch_agents = self.home / "Library" / "LaunchAgents"
        launch_agents.mkdir(parents=True)
        for label in (aggregator, player):
            (launch_agents / f"{label}.plist").write_bytes(
                plistlib.dumps({"Label": label, "StateletManaged": MANAGED_MARKER})
            )
        environment["STATELET_INSTALL_CRASH_AT"] = "after-first-bootout"

        crashed = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(crashed.returncode, -9, crashed.stderr)
        state = log.parent / "state"
        self.assertFalse((state / aggregator).exists())
        self.assertTrue((state / player).exists())
        environment.pop("STATELET_INSTALL_CRASH_AT")
        recovered = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertTrue((state / aggregator).exists())
        self.assertTrue((state / player).exists())
        self.assertFalse((self.home / ".statelet-install-transaction").exists())
        commands = log.read_text(encoding="utf-8").splitlines()
        first_recovery_bootstrap = next(
            index for index, command in enumerate(commands) if command.startswith("bootstrap ")
        )
        later_requiesce = next(
            index for index, command in enumerate(commands[first_recovery_bootstrap + 1 :], first_recovery_bootstrap + 1)
            if command.startswith("bootout ")
        )
        self.assertLess(first_recovery_bootstrap, later_requiesce)

    def test_active_recovery_rejects_prequiesce_plist_tamper_before_bootstrap(self) -> None:
        bundle = self.make_bundle("PrequiescePlistTamper")
        aggregator = "com.coke1120.statelet.state-aggregator"
        environment, log = self.fake_launchctl_environment(aggregator)
        launch_agents = self.home / "Library" / "LaunchAgents"
        launch_agents.mkdir(parents=True)
        plist = launch_agents / f"{aggregator}.plist"
        plist.write_bytes(plistlib.dumps({"Label": aggregator, "StateletManaged": MANAGED_MARKER}))
        environment["STATELET_INSTALL_CRASH_AT"] = "after-first-bootout"
        crashed = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(crashed.returncode, -9, crashed.stderr)
        plist.write_bytes(plist.read_bytes() + b"\n# tampered after bootout\n")
        before = len(log.read_text(encoding="utf-8").splitlines())
        environment.pop("STATELET_INSTALL_CRASH_AT")

        refused = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(refused.returncode, 74, refused.stderr)
        self.assertTrue((self.home / ".statelet-install-transaction" / "journal.json").is_file())
        recovery_commands = log.read_text(encoding="utf-8").splitlines()[before:]
        self.assertFalse(any(command.startswith("bootstrap ") for command in recovery_commands))

    def test_install_rejects_launch_plist_changed_between_bootout_and_backup(self) -> None:
        self.assert_launch_plist_change_between_bootout_and_backup_is_rejected("digest")

    def test_install_rejects_launch_plist_replaced_between_bootout_and_backup(self) -> None:
        self.assert_launch_plist_change_between_bootout_and_backup_is_rejected("entry")

    def test_install_rejects_launch_plist_reparented_between_bootout_and_backup(self) -> None:
        self.assert_launch_plist_change_between_bootout_and_backup_is_rejected("parent")

    def assert_launch_plist_change_between_bootout_and_backup_is_rejected(self, mismatch: str) -> None:
        bundle = self.make_bundle("BootoutBackupPlistTamper")
        aggregator = "com.coke1120.statelet.state-aggregator"
        environment, log = self.fake_launchctl_environment(aggregator)
        launch_agents = self.home / "Library" / "LaunchAgents"
        launch_agents.mkdir(parents=True)
        plist = launch_agents / f"{aggregator}.plist"
        original = plistlib.dumps({"Label": aggregator, "StateletManaged": MANAGED_MARKER})
        plist.write_bytes(original)
        original_digest = self.safe_tree_digest(plist)
        mutation_variables = {
            "digest": ("STATELET_FAKE_BOOTOUT_TAMPER_LABEL", "STATELET_FAKE_BOOTOUT_TAMPER_PATH"),
            "entry": ("STATELET_FAKE_BOOTOUT_REPLACE_LABEL", "STATELET_FAKE_BOOTOUT_REPLACE_PATH"),
            "parent": ("STATELET_FAKE_BOOTOUT_REPARENT_LABEL", "STATELET_FAKE_BOOTOUT_REPARENT_PATH"),
        }
        label_variable, path_variable = mutation_variables[mismatch]
        environment.update({label_variable: aggregator, path_variable: str(plist), "STATELET_INSTALL_FAIL_AT": "after-app"})

        refused = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(refused.returncode, 74, refused.stderr)
        self.assertIn("file rollback was ambiguous", refused.stderr)
        transaction = self.home / ".statelet-install-transaction"
        journal = json.loads((transaction / "journal.json").read_text(encoding="utf-8"))
        original_record = journal["launch"]["original_plists"][0]
        self.assertEqual(original_record["digest"], original_digest)
        backups = [
            operation for operation in journal["operations"]
            if operation.get("kind") == "backup" and operation.get("target") == str(plist)
        ]
        self.assertEqual(len(backups), 1)
        comparisons = {
            "digest": backups[0]["digest"] == original_record["digest"],
            "entry": backups[0]["source_entry"] == original_record["entry"],
            "parent": backups[0]["target_parent"] == original_record["parent"],
        }
        self.assertFalse(comparisons[mismatch])
        self.assertTrue(all(matches for field, matches in comparisons.items() if field != mismatch))
        commands = log.read_text(encoding="utf-8").splitlines()
        bootout = next(index for index, command in enumerate(commands) if command.startswith("bootout "))
        self.assertFalse(any(command.startswith("bootstrap ") for command in commands[bootout + 1 :]))
        self.assertFalse((log.parent / "state" / aggregator).exists())

    def test_sigkill_after_delayed_bootout_submission_reconciles_pending_state(self) -> None:
        bundle = self.make_bundle("CrashAfterDelayedBootoutSubmit")
        aggregator = "com.coke1120.statelet.state-aggregator"
        environment, _ = self.fake_launchctl_environment(aggregator, delay_label=aggregator)
        launch_agents = self.home / "Library" / "LaunchAgents"
        launch_agents.mkdir(parents=True)
        (launch_agents / f"{aggregator}.plist").write_bytes(
            plistlib.dumps({"Label": aggregator, "StateletManaged": MANAGED_MARKER})
        )
        environment["STATELET_INSTALL_CRASH_AT"] = "after-first-bootout-submit"

        crashed = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(crashed.returncode, -9, crashed.stderr)
        environment.pop("STATELET_INSTALL_CRASH_AT")
        recovered = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertTrue((Path(environment["CODEX_PET_FAKE_LAUNCH_STATE"]) / aggregator).exists())
        self.assertFalse((self.home / ".statelet-install-transaction").exists())

    def test_launch_recovery_failure_retains_journal_for_retry(self) -> None:
        bundle = self.make_bundle("LaunchRecoveryRetry")
        aggregator = "com.coke1120.statelet.state-aggregator"
        environment, _ = self.fake_launchctl_environment(aggregator)
        launch_agents = self.home / "Library" / "LaunchAgents"
        launch_agents.mkdir(parents=True)
        plist = launch_agents / f"{aggregator}.plist"
        plist.write_bytes(plistlib.dumps({"Label": aggregator, "StateletManaged": MANAGED_MARKER}))
        environment["STATELET_INSTALL_CRASH_AT"] = "after-first-bootout"
        self.assertEqual(
            subprocess.run(
                ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            ).returncode,
            -9,
        )
        environment.pop("STATELET_INSTALL_CRASH_AT")
        environment["CODEX_PET_FAKE_FAIL_ACTION"] = "bootstrap"
        environment["CODEX_PET_FAKE_FAIL_LABEL"] = aggregator

        failed_recovery = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(failed_recovery.returncode, 71, failed_recovery.stderr)
        transaction = self.home / ".statelet-install-transaction"
        self.assertTrue((transaction / "journal.json").exists())
        environment["CODEX_PET_FAKE_FAIL_ACTION"] = ""
        environment["CODEX_PET_FAKE_FAIL_LABEL"] = ""
        recovered = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(bundle)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertFalse(transaction.exists())

    def test_crash_after_rebootstrap_keeps_sealed_files_and_completes_forward(self) -> None:
        first = self.make_bundle("RebootstrapCrashFirst", "first")
        self.assertEqual(self.install(first).returncode, 0)
        aggregator = "com.coke1120.statelet.state-aggregator"
        environment, log = self.fake_launchctl_environment(aggregator)
        environment["STATELET_INSTALL_CRASH_AT"] = "after-aggregator-rebootstrap"
        crashed = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(self.make_bundle("RebootstrapCrashSecond", "second"))],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(crashed.returncode, -9, crashed.stderr)
        installed = self.home / "Applications" / "Statelet.app" / "Contents" / "MacOS" / "Statelet"
        expected = (self.base / "RebootstrapCrashSecond.app" / "Contents" / "MacOS" / "Statelet").read_bytes()
        self.assertEqual(installed.read_bytes(), expected)
        transaction = self.home / ".statelet-install-transaction"
        self.assertEqual(json.loads((transaction / "journal.json").read_text())["state"], "files-committed")
        environment.pop("STATELET_INSTALL_CRASH_AT")
        before = len(log.read_text(encoding="utf-8").splitlines())
        recovered = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(first)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        recovery_commands = log.read_text(encoding="utf-8").splitlines()[before:]
        self.assertFalse(any(command.startswith("bootout ") and aggregator in command for command in recovery_commands))
        self.assertEqual(installed.read_bytes(), expected)
        self.assertFalse(transaction.exists())

    def test_file_recovery_crash_is_idempotent_on_retry(self) -> None:
        first = self.make_bundle("RecoveryCrashFirst", "first")
        self.assertEqual(self.install(first).returncode, 0)
        second = self.make_bundle("RecoveryCrashSecond", "second")
        environment = os.environ.copy()
        environment["STATELET_INSTALL_CRASH_AT"] = "after-app"
        self.assertEqual(self.install(second, env=environment).returncode, -9)
        environment.pop("STATELET_INSTALL_CRASH_AT")
        environment["STATELET_INSTALL_CRASH_DURING_RECOVERY"] = "1"
        recovery_crash = self.install(second, env=environment)
        self.assertEqual(recovery_crash.returncode, 74, recovery_crash.stderr)
        self.assertIn("interrupted Statelet installation is ambiguous", recovery_crash.stderr)
        transaction = self.home / ".statelet-install-transaction"
        self.assertTrue((transaction / "journal.json").exists())
        environment.pop("STATELET_INSTALL_CRASH_DURING_RECOVERY")
        recovered = self.install(second, env=environment)
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertFalse(transaction.exists())

    def test_files_commit_rejects_noncanonical_synthetic_ownership_graph(self) -> None:
        target = self.home / "owned"
        nested = target / "nested"
        nested.parent.mkdir(parents=True)
        nested.write_bytes(b"original-nested")
        (target / "retained.txt").write_bytes(b"original-retained")
        transaction = self.home / ".statelet-install-transaction"
        initialized = self.journal_command(transaction, "init")
        self.assertEqual(initialized.returncode, 0, initialized.stderr)
        staged = transaction / "stage" / "owned"
        staged.mkdir()
        (staged / "nested").write_bytes(b"replacement-nested")
        (staged / "retained.txt").write_bytes(b"replacement-retained")

        backup_nested = transaction / "backup" / "nested"
        moved_nested = self.journal_command(
            transaction,
            "backup-move",
            str(nested),
            str(backup_nested),
            self.safe_tree_digest(nested),
        )
        self.assertEqual(moved_nested.returncode, 0, moved_nested.stderr)
        backup_parent = transaction / "backup" / "owned"
        moved_parent = self.journal_command(
            transaction,
            "backup-move",
            str(target),
            str(backup_parent),
            self.safe_tree_digest(target),
        )
        self.assertEqual(moved_parent.returncode, 0, moved_parent.stderr)
        installed = self.journal_command(
            transaction,
            "install-move",
            str(staged),
            str(target),
            self.safe_tree_digest(staged),
        )
        self.assertEqual(installed.returncode, 0, installed.stderr)

        (self.home / "runtime").mkdir()
        (self.home / "logs").mkdir()
        files_committed = self.journal_command(
            transaction,
            "files-commit",
            str(target),
            str(nested),
            str(self.home / "runtime"),
            str(self.home / "logs"),
            str(self.home),
        )
        self.assertNotEqual(files_committed.returncode, 0, files_committed.stderr)
        self.assertIn("transaction publication contract is invalid", files_committed.stderr)
        self.assertEqual((target / "nested").read_bytes(), b"replacement-nested")
        self.assertEqual((backup_nested).read_bytes(), b"original-nested")
        self.assertEqual(json.loads((transaction / "journal.json").read_text())["state"], "active")

    def test_commit_rejects_changed_final_install_and_retains_journal(self) -> None:
        self.assertEqual(self.install(self.make_bundle("CommitTargetFirst", "first")).returncode, 0)
        gate = self.home / "commit-target-gate"
        environment = os.environ.copy()
        environment["STATELET_INSTALL_TEST_COMMIT_GATE"] = str(gate)
        process = subprocess.Popen(
            [
                "bash",
                str(INSTALL_SCRIPT),
                "--home",
                str(self.home),
                "--app-bundle",
                str(self.make_bundle("CommitTargetSecond", "second")),
                "--skip-launchctl",
            ],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
        )
        import time
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline and not Path(f"{gate}.ready").exists():
            if process.poll() is not None:
                _, stderr = process.communicate()
                self.fail(f"installer exited before commit gate: {stderr}")
            time.sleep(0.01)
        if not Path(f"{gate}.ready").exists():
            process.terminate()
            _, stderr = process.communicate(timeout=5)
            self.fail(f"commit gate was not reached: {stderr}")
        executable = self.home / "Applications" / "Statelet.app" / "Contents" / "MacOS" / "Statelet"
        executable.write_bytes(executable.read_bytes() + b"\n# changed after publication\n")
        Path(f"{gate}.release").touch()

        _, stderr = process.communicate(timeout=30)

        self.assertEqual(process.returncode, 74, stderr)
        self.assertIn("file rollback was ambiguous", stderr)
        self.assertTrue((self.home / ".statelet-install-transaction" / "journal.json").is_file())

    def test_commit_rejects_same_content_replacement_and_retains_journal(self) -> None:
        self.assertEqual(self.install(self.make_bundle("CommitIdentityFirst", "first")).returncode, 0)
        gate = self.home / "commit-identity-gate"
        environment = os.environ.copy()
        environment["STATELET_INSTALL_TEST_COMMIT_GATE"] = str(gate)
        process = subprocess.Popen(
            [
                "bash",
                str(INSTALL_SCRIPT),
                "--home",
                str(self.home),
                "--app-bundle",
                str(self.make_bundle("CommitIdentitySecond", "second")),
                "--skip-launchctl",
            ],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
        )
        import time
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline and not Path(f"{gate}.ready").exists():
            if process.poll() is not None:
                _, stderr = process.communicate()
                self.fail(f"installer exited before commit gate: {stderr}")
            time.sleep(0.01)
        if not Path(f"{gate}.ready").exists():
            process.terminate()
            _, stderr = process.communicate(timeout=5)
            self.fail(f"commit gate was not reached: {stderr}")
        applications = self.home / "Applications"
        installed = applications / "Statelet.app"
        replacement = applications / "replacement.app"
        displaced = applications / "displaced.app"
        shutil.copytree(installed, replacement)
        installed.rename(displaced)
        replacement.rename(installed)
        Path(f"{gate}.release").touch()

        _, stderr = process.communicate(timeout=30)

        self.assertEqual(process.returncode, 74, stderr)
        self.assertIn("file rollback was ambiguous", stderr)
        self.assertTrue((self.home / ".statelet-install-transaction" / "journal.json").is_file())

    def test_commit_rejects_changed_backup_and_retains_journal(self) -> None:
        self.assertEqual(self.install(self.make_bundle("CommitBackupFirst", "first")).returncode, 0)
        gate = self.home / "commit-backup-gate"
        environment = os.environ.copy()
        environment["STATELET_INSTALL_TEST_COMMIT_GATE"] = str(gate)
        process = subprocess.Popen(
            [
                "bash",
                str(INSTALL_SCRIPT),
                "--home",
                str(self.home),
                "--app-bundle",
                str(self.make_bundle("CommitBackupSecond", "second")),
                "--skip-launchctl",
            ],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
        )
        import time
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline and not Path(f"{gate}.ready").exists():
            if process.poll() is not None:
                _, stderr = process.communicate()
                self.fail(f"installer exited before commit gate: {stderr}")
            time.sleep(0.01)
        if not Path(f"{gate}.ready").exists():
            process.terminate()
            _, stderr = process.communicate(timeout=5)
            self.fail(f"commit gate was not reached: {stderr}")
        backup = self.home / ".statelet-install-transaction" / "backup" / "app" / "Contents" / "MacOS" / "Statelet"
        backup.write_bytes(backup.read_bytes() + b"\n# changed after backup\n")
        Path(f"{gate}.release").touch()

        _, stderr = process.communicate(timeout=30)

        self.assertEqual(process.returncode, 74, stderr)
        self.assertIn("file rollback was ambiguous", stderr)
        self.assertTrue((self.home / ".statelet-install-transaction" / "journal.json").is_file())

    def test_commit_rejects_changed_nested_install_owner_and_retains_journal(self) -> None:
        legacy_media = self.home / "Library" / "Application Support" / "CodexPet" / "media" / "idle.mov"
        legacy_media.parent.mkdir(parents=True)
        legacy_media.write_bytes(b"private-migrated-media")
        gate = self.home / "commit-nested-owner-gate"
        environment = os.environ.copy()
        environment["STATELET_INSTALL_TEST_COMMIT_GATE"] = str(gate)
        process = subprocess.Popen(
            [
                "bash",
                str(INSTALL_SCRIPT),
                "--home",
                str(self.home),
                "--app-bundle",
                str(self.make_bundle("CommitNestedOwner")),
                "--skip-launchctl",
            ],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
        )
        import time
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline and not Path(f"{gate}.ready").exists():
            if process.poll() is not None:
                _, stderr = process.communicate()
                self.fail(f"installer exited before commit gate: {stderr}")
            time.sleep(0.01)
        if not Path(f"{gate}.ready").exists():
            process.terminate()
            _, stderr = process.communicate(timeout=5)
            self.fail(f"commit gate was not reached: {stderr}")
        installed_media = self.home / "Library" / "Application Support" / "Statelet" / "media" / "idle.mov"
        installed_media.write_bytes(b"changed-after-nested-publication")
        Path(f"{gate}.release").touch()

        _, stderr = process.communicate(timeout=30)

        self.assertEqual(process.returncode, 74, stderr)
        self.assertIn("file rollback was ambiguous", stderr)
        self.assertTrue((self.home / ".statelet-install-transaction" / "journal.json").is_file())

    def test_legacy_source_mutation_after_copy_aborts_before_publication(self) -> None:
        legacy = self.home / "Library" / "Application Support" / "CodexPet"
        voice = legacy / "voice" / "profile.json"
        voice.parent.mkdir(parents=True)
        voice.write_bytes(b"snapshot-before-mutation")
        cached_legacy_hook = legacy / "mac-widget" / "python" / "codex_pet_hook.py"
        cached_legacy_hook.parent.mkdir(parents=True)
        cached_legacy_hook.write_text("# cached legacy writer\n", encoding="utf-8")
        (legacy / "mac-widget" / "MANAGED_BY_CODEX_PET").write_text(LEGACY_MARKER + "\n", encoding="utf-8")
        hooks_file = self.home / ".codex" / "hooks.json"
        hooks_file.parent.mkdir()
        legacy_hook_command = shlex.join(
            ["/usr/bin/python3", str(cached_legacy_hook)]
        )
        hooks_payload = {
            "unrelated": {"keep": True},
            "hooks": {"Stop": [{"hooks": [{"type": "command", "command": legacy_hook_command, "timeout": 0.1}]}]},
        }
        hooks_file.write_text(json.dumps(hooks_payload), encoding="utf-8")
        original_hooks = hooks_file.read_bytes()
        legacy_plist = self.home / "Library" / "LaunchAgents" / "com.coke1120.codex-pet.state-aggregator.plist"
        legacy_plist.parent.mkdir(parents=True)
        legacy_plist.write_bytes(
            plistlib.dumps(
                {
                    "Label": "com.coke1120.codex-pet.state-aggregator",
                    "CodexPetMacManaged": LEGACY_MARKER,
                }
            )
        )
        legacy_label = "com.coke1120.codex-pet.state-aggregator"
        environment, log = self.fake_launchctl_environment(legacy_label)
        gate = self.home / "migration-gate"
        environment["STATELET_INSTALL_TEST_POSTVALIDATION_GATE"] = str(gate)
        process = subprocess.Popen(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(self.make_bundle("MutationGate"))],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
        )
        import time
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline and not Path(f"{gate}.ready").exists():
            if process.poll() is not None:
                _, stderr = process.communicate()
                self.fail(f"installer exited before migration gate: {stderr}")
            time.sleep(0.01)
        if not Path(f"{gate}.ready").exists():
            process.terminate()
            _, stderr = process.communicate(timeout=5)
            self.fail(f"migration gate was not reached: {stderr}")
        self.assertFalse((log.parent / "state" / legacy_label).exists())
        self.assertFalse(cached_legacy_hook.exists())
        quiesced_hooks = hooks_file.read_text(encoding="utf-8")
        self.assertNotIn(legacy_hook_command, quiesced_hooks)
        self.assertIn('"keep": true', quiesced_hooks)
        voice.write_bytes(b"mutated-after-copy")
        Path(f"{gate}.release").touch()

        _, stderr = process.communicate(timeout=30)

        self.assertEqual(process.returncode, 75, stderr)
        self.assertEqual(voice.read_bytes(), b"mutated-after-copy")
        self.assertFalse((self.home / "Applications" / "Statelet.app").exists())
        self.assertFalse((self.home / "Library" / "Application Support" / "Statelet").exists())
        self.assertTrue((log.parent / "state" / legacy_label).exists())
        self.assertEqual(hooks_file.read_bytes(), original_hooks)
        self.assertFalse((self.home / ".statelet-install-transaction").exists())

    def test_legacy_path_created_after_snapshot_aborts_and_rolls_back(self) -> None:
        legacy = self.home / "Library" / "Application Support" / "CodexPet"
        legacy.mkdir(parents=True)
        hooks_file = self.home / ".codex" / "hooks.json"
        hooks_file.parent.mkdir()
        hooks_file.write_text(json.dumps({"hooks": {}}), encoding="utf-8")
        original_hooks = hooks_file.read_bytes()
        gate = self.home / "absent-migration-gate"
        environment = os.environ.copy()
        environment["HOME"] = str(self.home)
        environment["STATELET_INSTALL_TEST_POSTVALIDATION_GATE"] = str(gate)
        process = subprocess.Popen(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(self.make_bundle("AbsentMutationGate")), "--skip-launchctl"],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
        )
        import time
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline and not Path(f"{gate}.ready").exists():
            if process.poll() is not None:
                _, stderr = process.communicate()
                self.fail(f"installer exited before migration gate: {stderr}")
            time.sleep(0.01)
        if not Path(f"{gate}.ready").exists():
            process.terminate()
            _, stderr = process.communicate(timeout=5)
            self.fail(f"migration gate was not reached: {stderr}")
        created = legacy / "sessions" / "late" / "state.json"
        created.parent.mkdir(parents=True)
        created.write_bytes(b"late-hook-write")
        Path(f"{gate}.release").touch()
        _, stderr = process.communicate(timeout=30)

        self.assertEqual(process.returncode, 75, stderr)
        self.assertEqual(created.read_bytes(), b"late-hook-write")
        self.assertEqual(hooks_file.read_bytes(), original_hooks)
        self.assertFalse((self.home / "Applications" / "Statelet.app").exists())
        self.assertFalse((self.home / "Library" / "Application Support" / "Statelet").exists())
        self.assertFalse((self.home / ".statelet-install-transaction").exists())

    def test_managed_hook_without_timeout_uses_nonzero_conservative_drain(self) -> None:
        source = INSTALL_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('except KeyError:\n                        timeout = 10.0', source)

    def test_obsolete_documents_hook_is_disabled_before_snapshot(self) -> None:
        legacy = self.home / "Library" / "Application Support" / "CodexPet"
        voice = legacy / "voice" / "profile.json"
        voice.parent.mkdir(parents=True)
        voice.write_bytes(b"documents-hook-snapshot")
        hooks_file = self.home / ".codex" / "hooks.json"
        hooks_file.parent.mkdir()
        obsolete = self.home / "Documents" / "codex-pet-dev-board" / "mac" / "codex_pet_hook.py"
        obsolete.parent.mkdir(parents=True)
        obsolete.write_text("# obsolete writer\n", encoding="utf-8")
        command = shlex.join(["/usr/bin/python3", str(obsolete)])
        hooks_file.write_text(
            json.dumps({"hooks": {"Stop": [{"hooks": [{"type": "command", "command": command, "timeout": 0.1}]}]}}),
            encoding="utf-8",
        )
        gate = self.home / "documents-hook-gate"
        environment = os.environ.copy()
        environment["HOME"] = str(self.home)
        environment["STATELET_INSTALL_TEST_MIGRATION_GATE"] = str(gate)
        process = subprocess.Popen(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(self.make_bundle("DocumentsHookGate")), "--skip-launchctl"],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
        )
        import time
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline and not Path(f"{gate}.ready").exists():
            if process.poll() is not None:
                _, stderr = process.communicate()
                self.fail(f"installer exited before migration gate: {stderr}")
            time.sleep(0.01)
        if not Path(f"{gate}.ready").exists():
            process.terminate()
            _, stderr = process.communicate(timeout=5)
            self.fail(f"migration gate was not reached: {stderr}")
        self.assertNotIn(command, hooks_file.read_text(encoding="utf-8"))
        Path(f"{gate}.release").touch()
        _, stderr = process.communicate(timeout=30)
        self.assertEqual(process.returncode, 0, stderr)

    def test_explicit_long_hook_timeout_is_fully_drained_before_snapshot(self) -> None:
        legacy = self.home / "Library" / "Application Support" / "CodexPet"
        voice = legacy / "voice" / "profile.json"
        voice.parent.mkdir(parents=True)
        voice.write_bytes(b"before-delayed-writer")
        hooks_file = self.home / ".codex" / "hooks.json"
        hooks_file.parent.mkdir()
        hook_path = legacy / "runtime" / "codex_pet_hook.py"
        hook_path.parent.mkdir(parents=True)
        hook_path.write_text("# delayed writer\n", encoding="utf-8")
        command = shlex.join(["/usr/bin/python3", str(hook_path)])
        hooks_file.write_text(
            json.dumps({"hooks": {"Stop": [{"hooks": [{"type": "command", "command": command, "timeout": 10.2}]}]}}),
            encoding="utf-8",
        )
        writer = subprocess.Popen(["/bin/bash", "-c", f"sleep 10.05; printf after-delayed-writer > {shlex.quote(str(voice))}"])
        try:
            installed = self.install(self.make_bundle("LongHookDrain"))
            writer.wait(timeout=5)
        finally:
            if writer.poll() is None:
                writer.terminate()
                writer.wait(timeout=5)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        canonical = self.home / "Library" / "Application Support" / "Statelet" / "voice" / "profile.json"
        self.assertEqual(canonical.read_bytes(), b"after-delayed-writer")
        self.assertEqual(voice.read_bytes(), b"after-delayed-writer")

    def test_unsupported_managed_hook_timeout_fails_before_mutation_privately(self) -> None:
        hooks_file = self.home / ".codex" / "hooks.json"
        hooks_file.parent.mkdir()
        private_hook = self.home / "Library" / "Application Support" / "CodexPet" / "runtime" / "codex_pet_hook.py"
        private_hook.parent.mkdir(parents=True)
        private_hook.write_text("# private hook\n", encoding="utf-8")
        private_name = "private-profile-name"
        hooks_file.write_text(
            json.dumps(
                {
                    "hooks": {
                        "Stop": [
                            {
                                "hooks": [
                                    {
                                        "type": "command",
                                        "command": shlex.join(["/usr/bin/python3", str(private_hook)]),
                                        "timeout": 60.1,
                                        "private": private_name,
                                    }
                                ]
                            }
                        ]
                    }
                }
            ),
            encoding="utf-8",
        )
        original = hooks_file.read_bytes()

        failed = self.install(self.make_bundle("RejectUnsupportedHookTimeout"))

        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("Refusing unsupported Statelet hook configuration", failed.stderr)
        self.assertNotIn(str(private_hook), failed.stderr)
        self.assertNotIn(private_name, failed.stderr)
        self.assertEqual(hooks_file.read_bytes(), original)
        self.assertFalse((self.home / ".statelet-install-transaction").exists())
        self.assertFalse((self.home / "Applications" / "Statelet.app").exists())

    def test_install_waits_for_delayed_launchd_transitions(self) -> None:
        first = self.make_bundle("DelayedLaunchFirst", "first")
        installed = self.install(first)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        second = self.make_bundle("DelayedLaunchSecond", "second")
        aggregator = "com.coke1120.statelet.state-aggregator"
        environment, _ = self.fake_launchctl_environment(
            aggregator,
            delay_label=aggregator,
        )

        updated = subprocess.run(
            ["bash", str(INSTALL_SCRIPT), "--app-bundle", str(second)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(updated.returncode, 0, updated.stderr)

    def test_uninstall_bootout_failure_preserves_managed_install(self) -> None:
        bundle = self.make_bundle("UninstallBootout")
        installed = self.install(bundle)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        statelet = self.home / "Applications" / "Statelet.app"
        aggregator = "com.coke1120.statelet.state-aggregator"
        environment, _ = self.fake_launchctl_environment(
            aggregator,
            fail_action="bootout",
            fail_label=aggregator,
        )

        failed = subprocess.run(
            ["bash", str(UNINSTALL_SCRIPT)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(failed.returncode, 72, failed.stderr)
        self.assertIn("uninstall was not applied", failed.stderr)
        self.assertTrue(statelet.exists())

    def test_uninstall_refusal_does_not_stage_or_change_directory_modes(self) -> None:
        support = self.home / "Library" / "Application Support" / "Statelet"
        component = support / "Statelet"
        component.mkdir(parents=True)
        support.chmod(0o751)
        support_mode = support.stat().st_mode & 0o777
        (component / "unmanaged.txt").write_text("keep", encoding="utf-8")

        failed = subprocess.run(
            ["bash", str(UNINSTALL_SCRIPT), "--home", str(self.home), "--skip-launchctl"],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("Refusing to remove unmanaged component", failed.stderr)
        self.assertEqual(support.stat().st_mode & 0o777, support_mode)
        self.assertFalse(list(support.glob(".mac-widget-uninstall.*")))
        self.assertFalse((self.home / "Applications").exists())
        self.assertFalse((self.home / ".codex").exists())

    def test_uninstall_reports_incomplete_launchd_rollback(self) -> None:
        bundle = self.make_bundle("UninstallRollback")
        installed = self.install(bundle)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        aggregator = "com.coke1120.statelet.state-aggregator"
        environment, _ = self.fake_launchctl_environment(
            aggregator,
            fail_action="bootstrap",
            fail_label=aggregator,
        )
        environment["CODEX_PET_UNINSTALL_FAIL_AT"] = "after-targets"

        failed = subprocess.run(
            ["bash", str(UNINSTALL_SCRIPT)],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(failed.returncode, 71, failed.stderr)
        self.assertIn("launchd rollback was incomplete", failed.stderr)
        self.assertTrue((self.home / "Applications" / "Statelet.app").exists())

    def test_uninstall_preserves_unmanaged_legacy_app(self) -> None:
        bundle = self.make_bundle("UninstallPreservesLegacy")
        installed = self.install(bundle)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        legacy = self.home / "Applications" / "CodexPetMac.app"
        legacy.mkdir()
        sentinel = legacy / "unmanaged.txt"
        sentinel.write_text("keep", encoding="utf-8")

        removed = subprocess.run(
            ["bash", str(UNINSTALL_SCRIPT), "--home", str(self.home), "--skip-launchctl"],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertFalse((self.home / "Applications" / "Statelet.app").exists())
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")


if __name__ == "__main__":
    unittest.main()
