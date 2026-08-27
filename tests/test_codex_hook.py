#!/usr/bin/env python3
"""Focused hardening tests for the privacy-safe Codex lifecycle hook."""

import importlib.util
import io
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

    def test_session_activity_metadata_preserves_start_and_session_end_time(self) -> None:
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
                {"session_id": "session", "hook_event_name": "SessionEnd"},
                state_dir,
            )
            record = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(record["started_at"], 100.0)
        self.assertEqual(record["completed_at"], 120.0)
        self.assertEqual(record["category"], "codex")
        self.assertEqual(record["provider"], "codex")

    def test_stop_ends_only_the_current_turn_without_completing_the_session(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = hook.write_event(
                {
                    "session_id": "session",
                    "turn_id": "turn-one",
                    "hook_event_name": "Stop",
                },
                Path(temporary),
            )
            record = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(record["event"], "Stop")
        self.assertEqual(record["state"], "idle")
        self.assertFalse(record["terminal"])
        self.assertIsNone(record["completed_at"])

    def test_stop_clears_unresolved_permission_before_returning_idle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            common = {
                "session_id": "session",
                "turn_id": "turn-one",
            }
            output = hook.write_event(
                dict(
                    common,
                    hook_event_name="PermissionRequest",
                    tool_name="Bash",
                    tool_input={"command": "needs-approval"},
                ),
                state_dir,
            )
            waiting = json.loads(output.read_text(encoding="utf-8"))
            hook.write_event(dict(common, hook_event_name="Stop"), state_dir)
            stopped = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(waiting["state"], "waiting")
        self.assertEqual(len(waiting["causal"]["pending_permissions"]), 1)
        self.assertEqual(stopped["event"], "Stop")
        self.assertEqual(stopped["state"], "idle")
        self.assertEqual(stopped["causal"]["pending_permissions"], [])
        self.assertTrue(stopped["fence"]["turn_closed"])
        self.assertFalse(stopped["terminal"])

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

    def test_hook_writer_rejects_symlinked_state_directory_without_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "target"
            target.mkdir(mode=0o755)
            os.chmod(target, 0o755)
            target_record = target / (hook.session_key({"session_id": "session"}) + ".json")
            target_record.write_text("keep\n", encoding="utf-8")
            os.chmod(target_record, 0o644)
            linked = root / "sessions"
            linked.symlink_to(target, target_is_directory=True)

            with self.assertRaises(OSError):
                hook.write_event(
                    {"session_id": "session", "hook_event_name": "Stop"},
                    linked,
                )

            contents = target_record.read_text(encoding="utf-8")
            directory_mode = stat.S_IMODE(target.stat().st_mode)
            file_mode = stat.S_IMODE(target_record.stat().st_mode)

        self.assertEqual(contents, "keep\n")
        self.assertEqual(directory_mode, 0o755)
        self.assertEqual(file_mode, 0o644)

    def test_hook_writer_never_follows_symlinked_ancestor_when_creating_state_dir(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "target"
            target.mkdir(mode=0o755)
            linked_parent = root / "linked-parent"
            linked_parent.symlink_to(target, target_is_directory=True)

            with self.assertRaises(OSError):
                hook.write_event(
                    {"session_id": "session", "hook_event_name": "Stop"},
                    linked_parent / "sessions",
                )

            target_entries = list(target.iterdir())
            target_mode = stat.S_IMODE(target.stat().st_mode)

        self.assertEqual(target_entries, [])
        self.assertEqual(target_mode, 0o755)

    def test_hook_writer_parent_swap_stays_on_validated_directory_descriptor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sessions = root / "sessions"
            sessions.mkdir()
            old_sessions = root / "old-sessions"
            destination_name = hook.session_key({"session_id": "session"}) + ".json"
            real_read = hook._read_existing
            swapped = False

            def swap_after_read(directory_fd, name):
                nonlocal swapped
                result = real_read(directory_fd, name)
                if not swapped:
                    swapped = True
                    sessions.rename(old_sessions)
                    sessions.mkdir(mode=0o755)
                    replacement = sessions / destination_name
                    replacement.write_text("keep\n", encoding="utf-8")
                    os.chmod(replacement, 0o644)
                return result

            with mock.patch.object(hook, "_read_existing", side_effect=swap_after_read):
                hook.write_event(
                    {"session_id": "session", "hook_event_name": "Stop"},
                    sessions,
                )

            replacement = sessions / destination_name
            replacement_contents = replacement.read_text(encoding="utf-8")
            replacement_mode = stat.S_IMODE(replacement.stat().st_mode)
            new_directory_mode = stat.S_IMODE(sessions.stat().st_mode)
            published = json.loads((old_sessions / destination_name).read_text(encoding="utf-8"))

        self.assertTrue(swapped)
        self.assertEqual(replacement_contents, "keep\n")
        self.assertEqual(replacement_mode, 0o644)
        self.assertEqual(new_directory_mode, 0o755)
        self.assertEqual(published["event"], "Stop")

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

    def test_stop_rejects_a_stale_same_turn_tool_callback(self) -> None:
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
        self.assertEqual(record["state"], "idle")
        self.assertFalse(record["terminal"])
        self.assertIsNone(record["completed_at"])
        self.assertEqual(record["rejections"], {"stale_event": 1})

    def test_stop_rejects_a_same_turn_callback_without_a_tool_id(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            output = hook.write_event(
                {
                    "session_id": "session",
                    "turn_id": "turn-one",
                    "hook_event_name": "Stop",
                },
                state_dir,
            )
            hook.write_event(
                {
                    "session_id": "session",
                    "turn_id": "turn-one",
                    "hook_event_name": "PostToolUse",
                    "tool_name": "Bash",
                    "tool_input": {},
                },
                state_dir,
            )
            record = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(record["event"], "Stop")
        self.assertEqual(record["state"], "idle")
        self.assertFalse(record["terminal"])
        self.assertIsNone(record["completed_at"])
        self.assertEqual(record["rejections"], {"stale_event": 1})

    def test_legacy_v1_stop_terminal_marker_is_normalized_while_rejecting_stale_callback(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            hook.time, "time", return_value=100.0
        ):
            state_dir = Path(temporary) / "sessions"
            state_dir.mkdir()
            destination = state_dir / (hook.session_key({"session_id": "session"}) + ".json")
            destination.write_text(
                json.dumps({
                    "version": 1,
                    "state": "idle",
                    "event": "Stop",
                    "updated_at": 50.0,
                }),
                encoding="utf-8",
            )

            hook.write_event(
                {
                    "session_id": "session",
                    "turn_id": "turn",
                    "hook_event_name": "PostToolUse",
                    "tool_name": "Bash",
                    "tool_input": {},
                    "tool_use_id": "tool",
                },
                state_dir,
            )
            record = json.loads(destination.read_text(encoding="utf-8"))

        self.assertEqual(record["event"], "Stop")
        self.assertEqual(record["state"], "idle")
        self.assertFalse(record["terminal"])
        self.assertIsNone(record["completed_at"])
        self.assertEqual(record["rejections"], {"stale_event": 1})

    def test_legacy_v1_terminal_blocks_stale_tool_callback_without_tool_id(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            hook.time, "time", return_value=100.0
        ):
            state_dir = Path(temporary) / "sessions"
            state_dir.mkdir()
            destination = state_dir / (hook.session_key({"session_id": "session"}) + ".json")
            destination.write_text(
                json.dumps({
                    "version": 1,
                    "state": "idle",
                    "event": "SessionEnd",
                    "updated_at": 60.0,
                }),
                encoding="utf-8",
            )

            hook.write_event(
                {
                    "session_id": "session",
                    "hook_event_name": "PostToolUse",
                    "tool_name": "Bash",
                    "tool_input": {},
                },
                state_dir,
            )
            record = json.loads(destination.read_text(encoding="utf-8"))

        self.assertEqual(record["event"], "SessionEnd")
        self.assertTrue(record["terminal"])
        self.assertEqual(record["completed_at"], 60.0)
        self.assertEqual(record["rejections"], {"stale_event": 1})

    def test_new_turn_prompt_revives_the_same_session_after_stop(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            output = hook.write_event(
                {
                    "conversation_id": "conversation",
                    "turn_id": "turn-one",
                    "hook_event_name": "Stop",
                },
                state_dir,
            )
            hook.write_event(
                {
                    "conversation_id": "conversation",
                    "turn_id": "turn-one",
                    "hook_event_name": "PostToolUse",
                },
                state_dir,
            )
            stopped = json.loads(output.read_text(encoding="utf-8"))
            hook.write_event(
                {
                    "conversation_id": "conversation",
                    "turn_id": "turn-two",
                    "hook_event_name": "UserPromptSubmit",
                },
                state_dir,
            )
            revived = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(stopped["event"], "Stop")
        self.assertFalse(stopped["terminal"])
        self.assertIsNone(stopped["completed_at"])
        self.assertEqual(stopped["rejections"], {"stale_event": 1})
        self.assertEqual(revived["event"], "UserPromptSubmit")
        self.assertEqual(revived["state"], "running")
        self.assertFalse(revived["terminal"])
        self.assertIsNone(revived["completed_at"])

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
        self.assertFalse(record["terminal"])
        self.assertIsNone(record["completed_at"])
        self.assertEqual(record["rejections"], {"stale_event": 1})
        self.assertNotIn("delayed private prompt", json.dumps(record))

    def test_stop_arriving_before_same_turn_prompt_keeps_that_turn_closed(self) -> None:
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
        self.assertFalse(record["terminal"])
        self.assertIsNone(record["completed_at"])
        self.assertEqual(record["rejections"], {"stale_event": 1})

    def test_session_end_terminalizes_the_session_after_stop_closes_its_turn(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(
            hook.time, "time", side_effect=[100.0, 110.0]
        ):
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
                    "hook_event_name": "SessionEnd",
                },
                state_dir,
            )
            record = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(record["event"], "SessionEnd")
        self.assertEqual(record["state"], "idle")
        self.assertTrue(record["terminal"])
        self.assertEqual(record["completed_at"], 110.0)
        self.assertTrue(record["fence"]["session_closed"])

    def test_accepted_session_activation_events_publish_private_bounded_targets(self) -> None:
        for event in ("SessionStart", "UserPromptSubmit"):
            with (
                self.subTest(event=event),
                tempfile.TemporaryDirectory() as temporary,
                mock.patch.object(hook.time, "time", return_value=100.0),
            ):
                state_dir = Path(temporary) / "sessions"
                payload = {
                    "session_id": "root-session",
                    "thread_id": "preferred-thread:123",
                    "hook_event_name": event,
                }
                if event == "UserPromptSubmit":
                    payload["turn_id"] = "turn"
                lifecycle_path = hook.write_event(payload, state_dir)
                identifier = hook.session_key(payload)
                target_path = state_dir / f"{identifier}.target.json"
                target = json.loads(target_path.read_text(encoding="utf-8"))
                lifecycle = lifecycle_path.read_text(encoding="utf-8")

                self.assertEqual(
                    target,
                    {
                        "version": 1,
                        "id": identifier,
                        "thread_id": "preferred-thread:123",
                        "updated_at": 100.0,
                    },
                )
                self.assertEqual(stat.S_IMODE(target_path.stat().st_mode), 0o600)
                self.assertNotIn("preferred-thread:123", lifecycle)
                self.assertNotIn("root-session", lifecycle)

    def test_rejected_same_turn_prompt_does_not_overwrite_accepted_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            common = {"session_id": "session", "turn_id": "turn"}
            hook.write_event(
                dict(
                    common,
                    hook_event_name="UserPromptSubmit",
                    thread_id="accepted-thread",
                ),
                state_dir,
            )
            hook.write_event(
                dict(
                    common,
                    hook_event_name="PreToolUse",
                    tool_name="Bash",
                    tool_input={},
                    tool_use_id="tool",
                ),
                state_dir,
            )
            hook.write_event(
                dict(
                    common,
                    hook_event_name="UserPromptSubmit",
                    thread_id="rejected-thread",
                ),
                state_dir,
            )
            identifier = hook.session_key(common)
            target = json.loads(
                (state_dir / f"{identifier}.target.json").read_text(encoding="utf-8")
            )

        self.assertEqual(target["thread_id"], "accepted-thread")

    def test_invalid_activation_target_is_not_published(self) -> None:
        invalid_values = ("contains whitespace", "contains/slash", "x" * 513)
        for value in invalid_values:
            with (
                self.subTest(value=value[:20]),
                tempfile.TemporaryDirectory() as temporary,
            ):
                state_dir = Path(temporary) / "sessions"
                hook.write_event(
                    {
                        "session_id": value,
                        "thread_id": value,
                        "hook_event_name": "SessionStart",
                    },
                    state_dir,
                )

                self.assertEqual(list(state_dir.glob("*.target.json")), [])

    def test_activation_target_write_failure_warns_without_blocking_lifecycle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            payload = {
                "session_id": "private-session-id",
                "thread_id": "private-thread:secret",
                "hook_event_name": "SessionStart",
            }
            original_write = hook._atomic_write_record

            def fail_only_target(directory_fd, destination_name, record):
                if destination_name.endswith(".target.json"):
                    raise OSError("/Users/private/repository private-thread:secret")
                return original_write(directory_fd, destination_name, record)

            stderr = io.StringIO()
            with (
                mock.patch.object(
                    hook, "_atomic_write_record", side_effect=fail_only_target
                ),
                mock.patch.object(hook.sys, "stderr", stderr),
            ):
                lifecycle_path = hook.write_event(payload, state_dir)

            lifecycle = json.loads(lifecycle_path.read_text(encoding="utf-8"))
            warning = stderr.getvalue()

        self.assertEqual(lifecycle["event"], "SessionStart")
        self.assertEqual(lifecycle["state"], "idle")
        self.assertEqual(warning, hook.ACTIVATION_TARGET_WRITE_WARNING + "\n")
        self.assertEqual(warning.count("\n"), 1)
        self.assertNotIn("/Users/", warning)
        self.assertNotIn("private-session-id", warning)
        self.assertNotIn("private-thread:secret", warning)


if __name__ == "__main__":
    unittest.main()
