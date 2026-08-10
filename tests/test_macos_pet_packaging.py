#!/usr/bin/env python3
"""Production packaging tests for the board-independent macOS companion."""

from __future__ import annotations

import json
import os
import plistlib
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "mac" / "CodexPetMac"
BUILD_SCRIPT = PACKAGE / "scripts" / "build_app.sh"
INSTALL_SCRIPT = PACKAGE / "scripts" / "install.sh"
UNINSTALL_SCRIPT = PACKAGE / "scripts" / "uninstall.sh"
ALPHA_COORDINATOR = PACKAGE / "Sources" / "CodexPetMac" / "AlphaConversion.swift"
PET_APP_DELEGATE = PACKAGE / "Sources" / "CodexPetMac" / "PetAppDelegate.swift"
MANAGED_MARKER = "mac-widget-v1"
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
    else
      touch "$CODEX_PET_FAKE_LAUNCH_STATE/$label"
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

    def test_bundle_info_contract_and_public_payload(self) -> None:
        bundle = self.make_bundle("InfoContract")
        with (bundle / "Contents" / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)

        self.assertEqual(info["CFBundleExecutable"], "CodexPetMac")
        self.assertEqual(info["CFBundleName"], "CodexPetMac")
        self.assertEqual(info["CFBundleIdentifier"], "com.coke1120.CodexPetMac")
        self.assertEqual(info["CFBundleDisplayName"], "Statelet")
        self.assertEqual(info["CFBundleIconFile"], "Statelet.icns")
        self.assertIn("Codex Pet", info["CFBundleGetInfoString"])
        self.assertEqual(
            info["NSHumanReadableCopyright"],
            "Copyright © 2026 Statelet contributors. MIT licensed.",
        )
        self.assertEqual(info["CFBundleShortVersionString"], "1.6.0")
        self.assertEqual(info["CFBundleVersion"], "11")
        self.assertEqual(info["CFBundlePackageType"], "APPL")
        self.assertEqual(info["LSMinimumSystemVersion"], "13.0")
        self.assertTrue(info["LSUIElement"])
        self.assertEqual(info["CodexPetManaged"], MANAGED_MARKER)
        self.assertTrue((bundle / "Contents" / "MacOS" / "CodexPetMac").stat().st_mode & 0o111)
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
        self.assertFalse([path for path in bundle.rglob("__pycache__")])
        self.assertFalse([path for path in bundle.rglob("*.pyc")])

        forbidden = {".mp4", ".mov", ".gif", ".apng", ".webm", ".mkv"}
        self.assertFalse(
            [path for path in bundle.rglob("*") if path.is_file() and path.suffix.lower() in forbidden]
        )
        bundle_payload = b"".join(
            path.read_bytes() for path in bundle.rglob("*") if path.is_file()
        )
        for private_prefix in (str(ROOT), str(Path.home()), "/Users/", "/private/tmp/"):
            self.assertNotIn(private_prefix.encode(), bundle_payload)

    def test_default_bundle_and_symbol_destinations_are_statelet(self) -> None:
        source = BUILD_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('output="$package_dir/dist/Statelet.app"', source)
        self.assertIn('symbols_output="${output}.dSYM"', source)
        install_source = INSTALL_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('app_bundle="$package_dir/dist/Statelet.app"', install_source)
        self.assertIn('app_dest="$applications_dir/Statelet.app"', install_source)

    def test_runtime_converter_cannot_mutate_signed_bundle_with_python_bytecode(self) -> None:
        source = ALPHA_COORDINATOR.read_text(encoding="utf-8")
        self.assertIn('"-B",\n            toolchain.converter.path', source)
        self.assertIn('"PYTHONDONTWRITEBYTECODE": "1"', source)

    def test_cancelled_import_retains_failures_collected_before_cancel(self) -> None:
        source = PET_APP_DELEGATE.read_text(encoding="utf-8")
        cancelled_branch = source.split("if cancelled {", 1)[1].split(
            "} else if failures.isEmpty", 1
        )[0]
        self.assertIn("summarizedImportFailures(failures)", cancelled_branch)
        self.assertIn("Earlier failures:", cancelled_branch)

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
        board_runtime = self.home / "Library" / "Application Support" / "CodexPet" / "runtime" / "board-sentinel.txt"
        board_runtime.parent.mkdir(parents=True)
        board_runtime.write_text("preserve", encoding="utf-8")

        result = self.install(bundle)
        self.assertEqual(result.returncode, 0, result.stderr)

        launch_agents = self.home / "Library" / "LaunchAgents"
        aggregator_path = launch_agents / "com.coke1120.codex-pet.state-aggregator.plist"
        player_path = launch_agents / "com.coke1120.codex-pet.mac-player.plist"
        with aggregator_path.open("rb") as handle:
            aggregator = plistlib.load(handle)
        with player_path.open("rb") as handle:
            player = plistlib.load(handle)
        with board_plist.open("rb") as handle:
            board = plistlib.load(handle)

        self.assertEqual(aggregator["CodexPetMacManaged"], MANAGED_MARKER)
        self.assertEqual(player["CodexPetMacManaged"], MANAGED_MARKER)
        self.assertEqual(aggregator["Label"], "com.coke1120.codex-pet.state-aggregator")
        self.assertEqual(player["Label"], "com.coke1120.codex-pet.mac-player")
        self.assertFalse(player["KeepAlive"])
        self.assertEqual(player["LimitLoadToSessionType"], "Aqua")
        self.assertEqual(player["ProcessType"], "Interactive")
        self.assertTrue(player["ProgramArguments"][0].endswith("/Applications/Statelet.app/Contents/MacOS/CodexPetMac"))
        self.assertEqual(aggregator["ProcessType"], "Background")
        aggregator_arguments = "\n".join(aggregator["ProgramArguments"])
        self.assertIn("codex_pet_state_aggregator.py", aggregator_arguments)
        self.assertNotIn("codex_pet_daemon.py", aggregator_arguments)
        self.assertNotIn("serial", aggregator_arguments.lower())
        self.assertNotIn("/dev/", aggregator_arguments)
        self.assertFalse(aggregator["ProgramArguments"][0].startswith(str(ROOT)))
        self.assertFalse(aggregator["ProgramArguments"][0].startswith(str(self.base)))
        self.assertEqual(board, {"Label": "com.coke1120.codex-pet", "BoardSentinel": True})
        self.assertEqual(board_runtime.read_text(encoding="utf-8"), "preserve")

        component = self.home / "Library" / "Application Support" / "CodexPet" / "mac-widget"
        installed_names = {path.name for path in component.rglob("*") if path.is_file()}
        self.assertEqual(
            installed_names,
            {
                "MANAGED_BY_CODEX_PET",
                "codex_pet_hook.py",
                "codex_pet_state.py",
                "codex_pet_state_aggregator.py",
            },
        )
        self.assertNotIn("codex_pet_daemon.py", installed_names)
        self.assertEqual(
            (self.home / "Library" / "Application Support" / "CodexPet" / "media" / "media-map.json").stat().st_mode & 0o777,
            0o600,
        )

    def test_reinstall_preserves_managed_launch_at_login_choice(self) -> None:
        first_bundle = self.make_bundle("LoginPreferenceOne")
        result = self.install(first_bundle)
        self.assertEqual(result.returncode, 0, result.stderr)

        player_path = (
            self.home
            / "Library"
            / "LaunchAgents"
            / "com.coke1120.codex-pet.mac-player.plist"
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
        self.assertEqual(reinstalled["CodexPetMacManaged"], MANAGED_MARKER)

    def test_hook_merge_is_additive_and_migrates_exact_documents_entry(self) -> None:
        bundle = self.make_bundle("Hooks")
        hooks_file = self.home / ".codex" / "hooks.json"
        hooks_file.parent.mkdir(parents=True)
        obsolete = f"python3 {self.home}/Documents/codex-pet-dev-board/mac/codex_pet_hook.py"
        unrelated_documents = f"python3 {self.home}/Documents/another-project/codex_pet_hook.py"
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
                if isinstance(command, str) and "/mac-widget/python/codex_pet_hook.py" in command
            ]
            self.assertEqual(len(widget_commands), 1, event)
            self.assertIn("/mac-widget/python/codex_pet_hook.py", widget_commands[0])
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
        board_hook = self.home / "Library" / "Application Support" / "CodexPet" / "runtime" / "codex_pet_hook.py"
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
                if isinstance(item, dict) and "codex_pet_hook.py" in str(item.get("command"))
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
                if isinstance(item, dict) and "codex_pet_hook.py" in str(item.get("command"))
            ]
            self.assertEqual(commands, [board_command], event)

    def test_failed_upgrade_rolls_back_every_managed_target(self) -> None:
        first = self.make_bundle("First", "first")
        result = self.install(first)
        self.assertEqual(result.returncode, 0, result.stderr)

        installed_app = self.home / "Applications" / "Statelet.app"
        legacy_app = self.home / "Applications" / "CodexPetMac.app"
        subprocess.run(["ditto", str(installed_app), str(legacy_app)], check=True)
        installed_executable = installed_app / "Contents" / "MacOS" / "CodexPetMac"
        legacy_executable = legacy_app / "Contents" / "MacOS" / "CodexPetMac"
        old_executable = installed_executable.read_bytes()
        old_legacy_executable = legacy_executable.read_bytes()
        support = self.home / "Library" / "Application Support" / "CodexPet"
        component_marker = support / "mac-widget" / "MANAGED_BY_CODEX_PET"
        old_component = component_marker.read_bytes()
        aggregator_plist = self.home / "Library" / "LaunchAgents" / "com.coke1120.codex-pet.state-aggregator.plist"
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

    def test_rollback_reloads_only_previously_loaded_jobs(self) -> None:
        first = self.make_bundle("LoadedStateFirst", "first")
        initial = self.install(first)
        self.assertEqual(initial.returncode, 0, initial.stderr)
        statelet = self.home / "Applications" / "Statelet.app"
        legacy = self.home / "Applications" / "CodexPetMac.app"
        statelet.rename(legacy)

        second = self.make_bundle("LoadedStateSecond", "second")
        environment, log = self.fake_launchctl_environment(
            "com.coke1120.codex-pet.state-aggregator"
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
        support = self.home / "Library" / "Application Support" / "CodexPet"
        media_map = support / "media" / "media-map.json"
        media_map.write_text('{"user":"preserve"}\n', encoding="utf-8")
        private_movie = support / "media" / "idle.mov"
        private_movie.write_bytes(b"user-private-media")
        board_runtime = support / "runtime" / "board.txt"
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
        self.assertFalse(legacy_app.exists())
        self.assertFalse((support / "mac-widget").exists())
        self.assertFalse((self.home / "Library" / "LaunchAgents" / "com.coke1120.codex-pet.state-aggregator.plist").exists())
        self.assertFalse((self.home / "Library" / "LaunchAgents" / "com.coke1120.codex-pet.mac-player.plist").exists())
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
            [command for command in remaining_commands if "mac-widget/python/codex_pet_hook.py" in str(command)]
        )
        self.assertIn("keep-me", remaining_commands)

    def test_unmanaged_launch_agent_fails_before_mutation(self) -> None:
        bundle = self.make_bundle("Unmanaged")
        plist = self.home / "Library" / "LaunchAgents" / "com.coke1120.codex-pet.mac-player.plist"
        plist.parent.mkdir(parents=True)
        plist.parent.chmod(0o711)
        launch_agents_mode = plist.parent.stat().st_mode & 0o777
        original = plistlib.dumps({"Label": "someone.else"})
        plist.write_bytes(original)
        support = self.home / "Library" / "Application Support" / "CodexPet"

        result = self.install(bundle)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to replace an unmanaged LaunchAgent", result.stderr)
        self.assertEqual(plist.read_bytes(), original)
        self.assertEqual(plist.parent.stat().st_mode & 0o777, launch_agents_mode)
        self.assertFalse(support.exists())
        self.assertFalse((self.home / "Applications" / "Statelet.app").exists())

    def test_managed_legacy_app_is_migrated_to_statelet(self) -> None:
        first = self.make_bundle("LegacyManaged", "legacy")
        installed = self.install(first)
        self.assertEqual(installed.returncode, 0, installed.stderr)

        statelet = self.home / "Applications" / "Statelet.app"
        legacy = self.home / "Applications" / "CodexPetMac.app"
        statelet.rename(legacy)
        old_payload = (legacy / "Contents" / "MacOS" / "CodexPetMac").read_bytes()
        player_path = (
            self.home
            / "Library"
            / "LaunchAgents"
            / "com.coke1120.codex-pet.mac-player.plist"
        )
        with player_path.open("rb") as handle:
            player = plistlib.load(handle)
        player["RunAtLoad"] = False
        player_path.write_bytes(plistlib.dumps(player))

        second = self.make_bundle("MigratedStatelet", "new")
        migrated = self.install(second)
        self.assertEqual(migrated.returncode, 0, migrated.stderr)
        self.assertTrue(statelet.exists())
        self.assertFalse(legacy.exists())
        self.assertNotEqual(
            (statelet / "Contents" / "MacOS" / "CodexPetMac").read_bytes(),
            old_payload,
        )
        with player_path.open("rb") as handle:
            migrated_player = plistlib.load(handle)
        self.assertFalse(migrated_player["RunAtLoad"])

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
        old_payload = (statelet / "Contents" / "MacOS" / "CodexPetMac").read_bytes()
        second = self.make_bundle("BootoutSecond", "second")
        aggregator = "com.coke1120.codex-pet.state-aggregator"
        player = "com.coke1120.codex-pet.mac-player"
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
            (statelet / "Contents" / "MacOS" / "CodexPetMac").read_bytes(),
            old_payload,
        )

    def test_install_reports_incomplete_launchd_rollback(self) -> None:
        first = self.make_bundle("RollbackLaunchFirst", "first")
        installed = self.install(first)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        second = self.make_bundle("RollbackLaunchSecond", "second")
        aggregator = "com.coke1120.codex-pet.state-aggregator"
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

    def test_install_waits_for_delayed_launchd_transitions(self) -> None:
        first = self.make_bundle("DelayedLaunchFirst", "first")
        installed = self.install(first)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        second = self.make_bundle("DelayedLaunchSecond", "second")
        aggregator = "com.coke1120.codex-pet.state-aggregator"
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
        aggregator = "com.coke1120.codex-pet.state-aggregator"
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
        support = self.home / "Library" / "Application Support" / "CodexPet"
        component = support / "mac-widget"
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
        aggregator = "com.coke1120.codex-pet.state-aggregator"
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
