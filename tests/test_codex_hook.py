#!/usr/bin/env python3
"""Focused hardening tests for the privacy-safe Codex lifecycle hook."""

import importlib.util
import json
import os
import stat
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "codex_pet_hook_hardening", ROOT / "mac" / "codex_pet_hook.py"
)
assert SPEC and SPEC.loader
hook = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hook)


class HookHardeningTests(unittest.TestCase):
    def test_default_path_uses_statelet_identity_with_legacy_environment_fallback(self) -> None:
        previous_statelet = os.environ.pop("STATELET_STATE_DIR", None)
        previous_legacy = os.environ.pop("CODEX_PET_STATE_DIR", None)
        try:
            self.assertEqual(
                hook.default_state_dir(),
                Path.home() / "Library" / "Application Support" / "Statelet" / "sessions",
            )
            os.environ["CODEX_PET_STATE_DIR"] = "/tmp/legacy-statelet-compat"
            self.assertEqual(hook.default_state_dir(), Path("/tmp/legacy-statelet-compat"))
            os.environ["STATELET_STATE_DIR"] = "/tmp/canonical-statelet"
            self.assertEqual(hook.default_state_dir(), Path("/tmp/canonical-statelet"))
        finally:
            if previous_statelet is None:
                os.environ.pop("STATELET_STATE_DIR", None)
            else:
                os.environ["STATELET_STATE_DIR"] = previous_statelet
            if previous_legacy is None:
                os.environ.pop("CODEX_PET_STATE_DIR", None)
            else:
                os.environ["CODEX_PET_STATE_DIR"] = previous_legacy

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

    def test_session_activity_metadata_preserves_start_and_terminal_times(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            hook.time, "time", side_effect=[100.0, 110.0, 120.0]
        ):
            state_dir = Path(temporary)
            hook.write_event(
                {"session_id": "session", "hook_event_name": "SessionStart"},
                state_dir,
            )
            hook.write_event(
                {"session_id": "session", "hook_event_name": "UserPromptSubmit"},
                state_dir,
            )
            output = hook.write_event(
                {"session_id": "session", "hook_event_name": "Stop"},
                state_dir,
            )
            record = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(record["started_at"], 100.0)
        self.assertEqual(record["completed_at"], 120.0)
        self.assertEqual(record["category"], "codex")

    def test_session_identity_aliases_are_hashed_and_distinct(self) -> None:
        aliases = ("session_id", "thread_id", "conversation_id", "sessionId")
        keys = {
            hook.session_key({alias: "private-{}".format(alias)}) for alias in aliases
        }
        self.assertEqual(len(keys), len(aliases))
        for key in keys:
            self.assertRegex(key, r"^[0-9a-f]{24}$")
            self.assertNotIn("private", key)

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
            record = json.loads(output.read_text(encoding="utf-8"))
            self.assertRegex(record["causal"]["current_turn"] or "", r"^(?:[0-9a-f]{24})?$")

    def test_causal_metadata_is_embedded_in_the_atomic_session_record(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            output = hook.write_event(
                {
                    "session_id": "session",
                    "turn_id": "private-turn",
                    "hook_event_name": "UserPromptSubmit",
                },
                state_dir,
            )
            record = json.loads(output.read_text(encoding="utf-8"))

            self.assertEqual(list(state_dir.glob(".causal-*")), [])
            self.assertRegex(record["causal"]["current_turn"], r"^[0-9a-f]{24}$")
            self.assertNotIn("private-turn", json.dumps(record))

    def test_post_replace_durability_failure_keeps_valid_destination(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            with mock.patch.object(hook.os, "fsync", side_effect=OSError("interrupted")):
                output = hook.write_event(
                    {
                        "session_id": "session",
                        "hook_event_name": "UserPromptSubmit",
                    },
                    state_dir,
                )

            record = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(record["event"], "UserPromptSubmit")
            self.assertEqual(record["state"], "running")
            self.assertEqual(list(state_dir.glob(".event-*.json")), [])

    def test_delayed_pre_tool_use_cannot_replace_post_tool_use(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            output = hook.write_event(
                {
                    "session_id": "private-session-a",
                    "turn_id": "private-turn-a",
                    "hook_event_name": "PostToolUse",
                    "tool_name": "Bash",
                    "tool_input": {"command": "secret command"},
                    "tool_response": {"output": "secret output"},
                    "tool_use_id": "private-tool-a",
                    "cwd": "/private/workspace",
                },
                state_dir,
            )
            hook.write_event(
                {
                    "session_id": "private-session-a",
                    "turn_id": "private-turn-a",
                    "hook_event_name": "PreToolUse",
                    "tool_name": "Bash",
                    "tool_input": {"command": "secret command"},
                    "tool_use_id": "private-tool-a",
                },
                state_dir,
            )
            record = json.loads(output.read_text(encoding="utf-8"))
            serialized = "\n".join(
                path.read_text(encoding="utf-8")
                for path in state_dir.iterdir()
                if path.is_file()
            )

        self.assertEqual(record["state"], "running")
        self.assertEqual(record["event"], "PostToolUse")
        self.assertEqual(record["rejections"], {"stale_event": 1})
        for private_value in (
            "private-session-a",
            "private-turn-a",
            "private-tool-a",
            "secret command",
            "secret output",
            "/private/workspace",
        ):
            self.assertNotIn(private_value, serialized)

    def test_delayed_pre_tool_use_cannot_replace_permission_request(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            payload = {
                "session_id": "session",
                "turn_id": "turn",
                "tool_name": "Bash",
                "tool_input": {"command": "echo hello"},
                "tool_use_id": "tool",
            }
            hook.write_event(dict(payload, hook_event_name="PreToolUse"), state_dir)
            output = hook.write_event(
                {
                    "session_id": "session",
                    "turn_id": "turn",
                    "hook_event_name": "PermissionRequest",
                    "tool_name": "Bash",
                    "tool_input": {"command": "echo hello"},
                },
                state_dir,
            )
            hook.write_event(dict(payload, hook_event_name="PreToolUse"), state_dir)
            record = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(record["event"], "PermissionRequest")
        self.assertEqual(record["state"], "waiting")
        self.assertEqual(record["rejections"], {"stale_event": 1})

    def test_permission_arriving_before_delayed_pre_tool_use_remains_authoritative(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            output = hook.write_event(
                {
                    "session_id": "session",
                    "turn_id": "turn",
                    "hook_event_name": "PermissionRequest",
                    "tool_name": "Bash",
                    "tool_input": {"command": "echo hello"},
                },
                state_dir,
            )
            hook.write_event(
                {
                    "session_id": "session",
                    "turn_id": "turn",
                    "hook_event_name": "PreToolUse",
                    "tool_name": "Bash",
                    "tool_input": {"command": "echo hello"},
                    "tool_use_id": "tool",
                },
                state_dir,
            )
            record = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(record["event"], "PermissionRequest")
        self.assertEqual(record["state"], "waiting")
        self.assertEqual(record["rejections"], {"stale_event": 1})

    def test_rapid_turns_reject_callbacks_from_the_previous_turn(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            hook.write_event(
                {
                    "session_id": "session",
                    "turn_id": "turn-one",
                    "hook_event_name": "UserPromptSubmit",
                    "prompt": "private first prompt",
                },
                state_dir,
            )
            output = hook.write_event(
                {
                    "session_id": "session",
                    "turn_id": "turn-two",
                    "hook_event_name": "UserPromptSubmit",
                    "prompt": "private second prompt",
                },
                state_dir,
            )
            hook.write_event(
                {
                    "session_id": "session",
                    "turn_id": "turn-one",
                    "hook_event_name": "PostToolUse",
                    "tool_name": "Bash",
                    "tool_input": {"command": "old"},
                    "tool_response": {"output": "old"},
                    "tool_use_id": "old-tool",
                },
                state_dir,
            )
            record = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(record["event"], "UserPromptSubmit")
        self.assertEqual(record["state"], "running")
        self.assertEqual(record["rejections"], {"stale_event": 1})
        self.assertNotIn("private", json.dumps(record))

    def test_interleaved_tools_keep_each_tool_phase_monotonic(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            common = {"session_id": "session", "turn_id": "turn"}
            first = dict(
                common,
                hook_event_name="PreToolUse",
                tool_name="Bash",
                tool_input={},
                tool_use_id="tool-one",
            )
            second = dict(
                common,
                hook_event_name="PreToolUse",
                tool_name="Bash",
                tool_input={},
                tool_use_id="tool-two",
            )
            hook.write_event(first, state_dir)
            hook.write_event(second, state_dir)
            hook.write_event(
                dict(
                    first,
                    hook_event_name="PostToolUse",
                    tool_response={"output": "done"},
                ),
                state_dir,
            )
            output = hook.write_event(
                dict(
                    second,
                    hook_event_name="PostToolUse",
                    tool_response={"output": "done"},
                ),
                state_dir,
            )
            hook.write_event(first, state_dir)
            record = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(record["event"], "PostToolUse")
        self.assertEqual(record["rejections"], {"stale_event": 1})

    def test_permission_for_one_interleaved_tool_does_not_block_another(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            common = {"session_id": "session", "turn_id": "turn"}
            first = dict(
                common,
                hook_event_name="PreToolUse",
                tool_name="Bash",
                tool_input={"command": "first"},
                tool_use_id="tool-one",
            )
            second = dict(
                common,
                hook_event_name="PreToolUse",
                tool_name="Bash",
                tool_input={"command": "second"},
                tool_use_id="tool-two",
            )
            hook.write_event(first, state_dir)
            hook.write_event(second, state_dir)
            hook.write_event(
                dict(
                    common,
                    hook_event_name="PermissionRequest",
                    tool_name="Bash",
                    tool_input={"command": "first"},
                ),
                state_dir,
            )
            output = hook.write_event(
                dict(second, hook_event_name="PostToolUse", tool_response={}),
                state_dir,
            )

            record = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(record["event"], "PostToolUse")
        self.assertEqual(record["state"], "waiting")
        self.assertEqual(record["rejections"], {})

    def test_parallel_permissions_keep_waiting_until_each_matching_tool_resolves(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            common = {"session_id": "session", "turn_id": "turn", "tool_name": "Bash"}
            for command in ("first", "second"):
                hook.write_event(
                    dict(
                        common,
                        hook_event_name="PermissionRequest",
                        tool_input={"command": command},
                    ),
                    state_dir,
                )
            output = hook.write_event(
                dict(
                    common,
                    hook_event_name="PostToolUse",
                    tool_input={"command": "first"},
                    tool_response={},
                    tool_use_id="tool-one",
                ),
                state_dir,
            )
            first_resolved = json.loads(output.read_text(encoding="utf-8"))
            hook.write_event(
                dict(
                    common,
                    hook_event_name="PostToolUse",
                    tool_input={"command": "second"},
                    tool_response={},
                    tool_use_id="tool-two",
                ),
                state_dir,
            )
            all_resolved = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(first_resolved["state"], "waiting")
        self.assertEqual(len(first_resolved["causal"]["pending_permissions"]), 1)
        self.assertEqual(all_resolved["state"], "running")
        self.assertEqual(all_resolved["causal"]["pending_permissions"], [])

    def test_identical_parallel_permissions_are_counted_independently(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            permission = {
                "session_id": "session",
                "turn_id": "turn",
                "hook_event_name": "PermissionRequest",
                "tool_name": "Bash",
                "tool_input": {"command": "same"},
            }
            hook.write_event(permission, state_dir)
            output = hook.write_event(permission, state_dir)
            hook.write_event(
                dict(
                    permission,
                    hook_event_name="PostToolUse",
                    tool_use_id="tool-one",
                    tool_response={},
                ),
                state_dir,
            )
            first_resolved = json.loads(output.read_text(encoding="utf-8"))
            hook.write_event(
                dict(
                    permission,
                    hook_event_name="PostToolUse",
                    tool_use_id="tool-two",
                    tool_response={},
                ),
                state_dir,
            )
            all_resolved = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(first_resolved["state"], "waiting")
        self.assertEqual(len(first_resolved["causal"]["pending_permissions"]), 1)
        self.assertEqual(all_resolved["state"], "running")
        self.assertEqual(all_resolved["causal"]["pending_permissions"], [])

    def test_session_end_terminalizes_only_its_hashed_session(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            first = hook.write_event(
                {
                    "session_id": "first",
                    "hook_event_name": "UserPromptSubmit",
                    "turn_id": "turn-first",
                },
                state_dir,
            )
            second = hook.write_event(
                {
                    "session_id": "second",
                    "hook_event_name": "PermissionRequest",
                    "turn_id": "turn-second",
                },
                state_dir,
            )
            hook.write_event(
                {
                    "session_id": "first",
                    "hook_event_name": "SessionEnd",
                },
                state_dir,
            )

            first_record = json.loads(first.read_text(encoding="utf-8"))
            second_record = json.loads(second.read_text(encoding="utf-8"))

        self.assertTrue(first_record["terminal"])
        self.assertFalse(second_record["terminal"])
        self.assertEqual(second_record["state"], "waiting")

    def test_stop_terminalizes_and_stale_tool_callback_cannot_revive_session(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            output = hook.write_event(
                {
                    "thread_id": "thread",
                    "turn_id": "turn",
                    "hook_event_name": "Stop",
                },
                state_dir,
            )
            hook.write_event(
                {
                    "thread_id": "thread",
                    "hook_event_name": "PostToolUse",
                    "turn_id": "turn",
                    "tool_name": "Bash",
                    "tool_input": {},
                    "tool_response": {},
                    "tool_use_id": "tool",
                },
                state_dir,
            )
            record = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(record["event"], "Stop")
        self.assertTrue(record["terminal"])
        self.assertEqual(record["rejections"], {"stale_event": 1})

    def test_stop_without_timestamp_ignores_late_tool_but_new_prompt_revives(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            output = hook.write_event(
                {"conversation_id": "conversation", "hook_event_name": "Stop"},
                state_dir,
            )
            hook.write_event(
                {"conversation_id": "conversation", "hook_event_name": "PostToolUse"},
                state_dir,
            )
            stopped = json.loads(output.read_text(encoding="utf-8"))
            hook.write_event(
                {
                    "conversation_id": "conversation",
                    "hook_event_name": "UserPromptSubmit",
                },
                state_dir,
            )
            revived = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(stopped["event"], "Stop")
        self.assertTrue(stopped["terminal"])
        self.assertEqual(stopped["rejections"], {"stale_event": 1})
        self.assertEqual(revived["event"], "UserPromptSubmit")
        self.assertFalse(revived["terminal"])

    def test_same_turn_delayed_prompt_cannot_revive_stop(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            output = hook.write_event(
                {
                    "session_id": "session",
                    "turn_id": "turn",
                    "hook_event_name": "Stop",
                },
                state_dir,
            )
            hook.write_event(
                {
                    "session_id": "session",
                    "turn_id": "turn",
                    "hook_event_name": "UserPromptSubmit",
                    "prompt": "delayed private prompt",
                },
                state_dir,
            )
            record = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(record["event"], "Stop")
        self.assertTrue(record["terminal"])
        self.assertEqual(record["rejections"], {"stale_event": 1})
        self.assertNotIn("delayed private prompt", json.dumps(record))

    def test_new_turn_stop_arriving_before_prompt_remains_terminal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            hook.write_event(
                {"session_id": "session", "turn_id": "turn-one", "hook_event_name": "Stop"},
                state_dir,
            )
            output = hook.write_event(
                {"session_id": "session", "turn_id": "turn-two", "hook_event_name": "Stop"},
                state_dir,
            )
            hook.write_event(
                {
                    "session_id": "session",
                    "turn_id": "turn-two",
                    "hook_event_name": "UserPromptSubmit",
                    "prompt": "delayed private prompt",
                },
                state_dir,
            )
            record = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(record["event"], "Stop")
        self.assertTrue(record["terminal"])
        self.assertEqual(record["rejections"], {"stale_event": 1})


if __name__ == "__main__":
    unittest.main()
