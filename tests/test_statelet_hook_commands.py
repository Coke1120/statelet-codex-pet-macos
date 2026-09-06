#!/usr/bin/env python3
"""Behavioral coverage for non-disruptive, Statelet-owned shell hook commands."""

import importlib.util
import json
import os
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "statelet_hook_commands", ROOT / "mac/CodexPetMac/scripts/merge_hooks.py"
)
assert SPEC and SPEC.loader
hooks = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hooks)


class StateletHookCommandTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="statelet-hook-command-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.support = self.base / "home/Library/Application Support/Statelet"
        self.widget = self.support / "Statelet/python/statelet_hook.py"
        self.shared = self.support / "runtime/statelet_hook.py"

    def write_config(self, name: str, data: dict) -> Path:
        path = self.base / name
        path.write_text(json.dumps(data), encoding="utf-8")
        path.chmod(0o600)
        return path

    def write_hook(self, path: Path, source: str = "# synthetic fixture\n") -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source, encoding="utf-8")

    def handler(self, command: str, **properties: object) -> dict:
        return {"type": "command", "command": command, **properties}

    def guarded(self, hook: Path, python: str = sys.executable) -> str:
        return hooks.guarded_statelet_command(python, hook)

    def run_command(self, command: str, *, shell: str = "/bin/sh", env: dict = None):
        return subprocess.run(
            [shell, "-c", command],
            input="synthetic hook input\n",
            capture_output=True,
            text=True,
            timeout=10,
            env=env,
        )

    def test_guarded_identity_recognizes_legacy_and_exact_generated_forms(self) -> None:
        for interpreter in (sys.executable, "python3", "/framework/Python", "historical-runner"):
            for path in (self.widget, self.support / "quote ' dollar $() ;/codex_pet_hook.py"):
                with self.subTest(interpreter=interpreter, path=path.name):
                    legacy = shlex.join([interpreter, str(path)])
                    guarded = self.guarded(path, interpreter)
                    self.assertEqual(hooks.parse_statelet_command(legacy), (guarded, path))
                    self.assertEqual(hooks.parse_statelet_command(guarded), (guarded, path))

    def test_guarded_parser_does_not_claim_other_shell_grammars(self) -> None:
        legacy = shlex.join([sys.executable, str(self.widget)])
        guarded = self.guarded(self.widget)
        foreign = (
            guarded + " ; printf unrelated",
            "printf unrelated; " + guarded,
            "(" + legacy + ") >/dev/null 2>&1 || :",
            legacy + " >/dev/null 2>&1 || true",
            legacy + "  >/dev/null 2>&1 || :",
            legacy + " extra >/dev/null 2>&1 || :",
            shlex.join(["/bin/sh", "-c", legacy]) + " >/dev/null 2>&1 || :",
            shlex.join([sys.executable, str(self.widget)]) + " 2>/dev/null || :",
            "'unterminated",
            None,
        )
        for command in foreign:
            with self.subTest(command=command):
                self.assertIsNone(hooks.parse_statelet_command(command))
                self.assertFalse(hooks.command_interpreter_exists(command))

    def test_fresh_command_delivers_stdin_and_provider_environment_without_output(self) -> None:
        result_path = self.base / "dispatch.json"
        unusual_hook = self.support / "space ' dollar $() ;/statelet_hook.py"
        self.write_hook(
            unusual_hook,
            "import json, os, pathlib, sys\n"
            "pathlib.Path(os.environ['STATELET_TEST_RESULT']).write_text(json.dumps({\n"
            "    'stdin': sys.stdin.read(), 'provider': os.environ['STATELET_AGENT_PROVIDER'],\n"
            "    'argv': sys.argv[1:]}))\n"
            "print('synthetic stdout')\n"
            "print('synthetic stderr', file=sys.stderr)\n",
        )
        command = hooks.choose_command({}, sys.executable, unusual_hook)
        handler = hooks.managed_handler(command, "grok")
        environment = dict(os.environ, STATELET_TEST_RESULT=str(result_path), **handler["env"])
        result = self.run_command(handler["command"], env=environment)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))
        self.assertEqual(
            json.loads(result_path.read_text(encoding="utf-8")),
            {"stdin": "synthetic hook input\n", "provider": "grok", "argv": []},
        )

    def test_missing_or_failing_command_is_silent_and_successful(self) -> None:
        noisy_hook = self.support / "noisy/statelet_hook.py"
        self.write_hook(
            noisy_hook,
            "import sys\nprint('synthetic stdout')\n"
            "print('synthetic stderr', file=sys.stderr)\nraise SystemExit(2)\n",
        )
        inaccessible_interpreter = self.base / "not-executable-python"
        inaccessible_interpreter.write_text("#!/bin/sh\nexit 2\n", encoding="utf-8")
        inaccessible_interpreter.chmod(0o600)
        scenarios = {
            "missing script": hooks.choose_command({}, sys.executable, self.widget),
            "missing interpreter": self.guarded(self.widget, str(self.base / "missing-python")),
            "nonexecutable interpreter": self.guarded(self.widget, str(inaccessible_interpreter)),
            "nonzero helper": self.guarded(noisy_hook),
        }
        for shell in ("/bin/sh", "/bin/bash"):
            for scenario, command in scenarios.items():
                with self.subTest(shell=shell, scenario=scenario):
                    result = self.run_command(command, shell=shell)
                    self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))

    def test_interpreter_check_uses_wrapped_interpreter(self) -> None:
        self.assertTrue(hooks.command_interpreter_exists(self.guarded(self.widget)))
        self.assertFalse(
            hooks.command_interpreter_exists(self.guarded(self.widget, str(self.base / "missing-python")))
        )

    def test_merge_migrates_old_and_guarded_duplicates_idempotently(self) -> None:
        legacy = shlex.join([sys.executable, str(self.widget)])
        guarded = self.guarded(self.widget)
        foreign = self.handler(guarded + " ; printf unrelated", timeout=7, metadata="preserve")
        for provider in ("codex", "grok"):
            with self.subTest(provider=provider):
                environment = {"env": {"STATELET_AGENT_PROVIDER": "grok"}} if provider == "grok" else {}
                destination = self.write_config(provider + ".json", {
                    "unrelated": {"preserve": True},
                    "hooks": {"Stop": [{"metadata": "preserve", "hooks": [
                        self.handler(legacy, timeout=9, **environment),
                        self.handler(guarded, timeout=9, **environment),
                        foreign,
                    ]}]},
                })
                first = self.base / (provider + "-first.json")
                second = self.base / (provider + "-second.json")
                hooks.merge(destination, first, sys.executable, self.widget, provider)
                hooks.merge(first, second, sys.executable, self.widget, provider)
                self.assertEqual(first.read_bytes(), second.read_bytes())
                installed = json.loads(first.read_text(encoding="utf-8"))
                self.assertEqual(installed["unrelated"], {"preserve": True})
                self.assertIn(foreign, list(hooks.iter_items(installed["hooks"])))
                for event, matcher in hooks.registrations(provider):
                    managed = [
                        item
                        for group in installed["hooks"][event]
                        if group.get("matcher") == matcher
                        for item in group["hooks"]
                        if item.get("command") == guarded
                    ]
                    self.assertEqual(managed, [hooks.managed_handler(guarded, provider)])

    def test_shared_runtime_selection_counts_old_and_guarded_as_one_identity(self) -> None:
        self.write_hook(self.shared)
        other_shared = self.support / "other/statelet_hook.py"
        self.write_hook(other_shared)
        old = shlex.join([sys.executable, str(self.shared)])
        selected = self.guarded(self.shared)
        other = self.guarded(other_shared)
        configuration = {"Stop": [{"hooks": [
            self.handler(old), self.handler(selected), self.handler(old),
            self.handler(other), self.handler(other),
        ]}]}
        self.assertEqual(hooks.choose_command(configuration, sys.executable, self.widget), selected)
        destination = self.write_config("shared.json", {"hooks": configuration})
        output = self.base / "shared-merged.json"
        hooks.merge(destination, output, sys.executable, self.widget, "codex")
        installed = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(
            [item["command"] for item in hooks.iter_items(installed["hooks"])],
            [selected] * len(hooks.CODEX_EVENTS),
        )

    def test_missing_shared_interpreter_falls_back_to_guarded_widget(self) -> None:
        self.write_hook(self.shared)
        command = self.guarded(self.shared, str(self.base / "missing-python"))
        self.assertEqual(
            hooks.choose_command({"Stop": [{"hooks": [self.handler(command)]}]}, sys.executable, self.widget),
            self.guarded(self.widget),
        )

    def test_quiescence_recognizes_both_forms_and_preserves_foreign_wrapper(self) -> None:
        legacy = shlex.join([sys.executable, str(self.widget)])
        guarded = self.guarded(self.widget)
        foreign = self.handler(guarded + " ; printf unrelated", timeout=60)
        for provider in ("codex", "grok"):
            with self.subTest(provider=provider):
                destination = self.write_config(provider + "-quiesce.json", {"hooks": {"Stop": [{
                    "metadata": "preserve", "hooks": [
                        self.handler(legacy, timeout=2), self.handler(guarded, timeout=3), foreign,
                    ],
                }]}})
                output = self.base / (provider + "-quiesced.json")
                drain, _ = hooks.quiesce_managed_hooks(destination, output, provider)
                self.assertEqual(drain, 3.1)
                self.assertEqual(json.loads(output.read_text(encoding="utf-8")), {
                    "hooks": {"Stop": [{"metadata": "preserve", "hooks": [foreign]}]},
                })

    def test_uninstall_deduplicates_and_guards_shared_replacement(self) -> None:
        self.write_hook(self.shared)
        old_shared = shlex.join([sys.executable, str(self.shared)])
        guarded_shared = self.guarded(self.shared)
        shared_properties = {"timeout": 4, "env": {"SYNTHETIC_SHARED": "preserve"}}
        foreign = self.handler(self.guarded(self.widget) + " ; printf unrelated")
        destination = self.write_config("uninstall.json", {"hooks": {
            "Stop": [{"hooks": [
                self.handler(shlex.join([sys.executable, str(self.widget)])),
                self.handler(self.guarded(self.widget)),
                self.handler(old_shared, **shared_properties),
                self.handler(guarded_shared, **shared_properties),
                foreign,
            ]}],
            "PreToolUse": [{"hooks": [self.handler(self.guarded(self.widget))]}],
        }})
        first = self.base / "uninstalled-first.json"
        second = self.base / "uninstalled-second.json"
        hooks.remove_widget_hook(destination, first, self.widget, "codex")
        hooks.remove_widget_hook(first, second, self.widget, "codex")
        self.assertEqual(first.read_bytes(), second.read_bytes())
        installed = json.loads(first.read_text(encoding="utf-8"))
        self.assertEqual(list(hooks.iter_items({"Stop": installed["hooks"]["Stop"]})), [
            self.handler(guarded_shared, **shared_properties), foreign,
        ])
        self.assertEqual(list(hooks.iter_items({"PreToolUse": installed["hooks"]["PreToolUse"]})), [
            hooks.managed_handler(guarded_shared, "codex"),
        ])

    def test_grok_uninstall_removes_both_forms_without_removing_foreign_command(self) -> None:
        self.write_hook(self.shared)
        foreign = self.handler(self.guarded(self.shared) + " ; printf unrelated")
        destination = self.write_config("grok-uninstall.json", {"hooks": {"Stop": [{"hooks": [
            self.handler(shlex.join([sys.executable, str(self.widget)])),
            self.handler(self.guarded(self.widget)),
            self.handler(shlex.join([sys.executable, str(self.shared)])),
            self.handler(self.guarded(self.shared)),
            foreign,
        ]}]}})
        output = self.base / "grok-uninstalled.json"
        hooks.remove_widget_hook(destination, output, self.widget, "grok")
        installed = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(list(hooks.iter_items(installed["hooks"])), [foreign])

    def test_uninstall_preserves_distinct_shared_registration_properties(self) -> None:
        self.write_hook(self.shared)
        legacy = shlex.join([sys.executable, str(self.shared)])
        guarded = self.guarded(self.shared)
        groups = [
            {"matcher": "first", "hooks": [self.handler(legacy, timeout=2)]},
            {"matcher": "second", "hooks": [self.handler(guarded, timeout=2)]},
            {"matcher": "second", "hooks": [self.handler(legacy, timeout=4, env={"SYNTHETIC": "keep"})]},
        ]
        destination = self.write_config("distinct-uninstall.json", {"hooks": {"PreToolUse": groups}})
        output = self.base / "distinct-uninstalled.json"
        hooks.remove_widget_hook(destination, output, self.widget, "codex")
        expected = json.loads(json.dumps(groups))
        for group in expected:
            group["hooks"][0]["command"] = guarded
        self.assertEqual(json.loads(output.read_text(encoding="utf-8")), {"hooks": {"PreToolUse": expected}})


if __name__ == "__main__":
    unittest.main()
