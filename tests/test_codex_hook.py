#!/usr/bin/env python3
"""Focused hardening tests for the privacy-safe Codex lifecycle hook."""

import importlib.util
import json
import stat
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "codex_pet_hook_hardening", ROOT / "mac" / "codex_pet_hook.py"
)
assert SPEC and SPEC.loader
hook = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hook)


class HookHardeningTests(unittest.TestCase):
    def test_plain_check_text_is_not_misclassified_as_review_work(self) -> None:
        payload = {
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": {"command": "echo check"},
        }
        self.assertEqual(hook.event_state(payload), "running")
        payload["tool_input"] = {"command": "git diff --check"}
        self.assertEqual(hook.event_state(payload), "review")

    def test_unknown_event_name_is_not_persisted(self) -> None:
        private_event = "PrivateEvent-secret-value"
        with tempfile.TemporaryDirectory() as temporary:
            output = hook.write_event(
                {"session_id": "session", "hook_event_name": private_event},
                Path(temporary),
            )
            record = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(record["event"], "unknown")
        self.assertNotIn(private_event, json.dumps(record))

    def test_state_directory_and_record_are_owner_only(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            state_dir.mkdir(mode=0o755)
            output = hook.write_event(
                {"session_id": "session", "hook_event_name": "Stop"}, state_dir
            )

            self.assertEqual(stat.S_IMODE(state_dir.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            self.assertEqual(list(state_dir.glob(".event-*.json")), [])


if __name__ == "__main__":
    unittest.main()
