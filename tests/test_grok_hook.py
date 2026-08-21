#!/usr/bin/env python3
"""Provider-specific tests for the privacy-safe Grok Build hook adapter."""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "grok_pet_hook", ROOT / "mac" / "codex_pet_hook.py"
)
assert SPEC and SPEC.loader
hook = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hook)


class GrokHookTests(unittest.TestCase):
    def write(self, state_dir: Path, payload):
        with mock.patch.dict(os.environ, {"STATELET_AGENT_PROVIDER": "grok"}):
            output = hook.write_event(payload, state_dir)
        return json.loads(output.read_text(encoding="utf-8"))

    def test_camel_case_envelope_is_normalized_and_privacy_safe(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            record = self.write(
                Path(temporary),
                {
                    "hookEventName": "user_prompt_submit",
                    "sessionId": "private-grok-session",
                    "promptId": "private-prompt",
                    "prompt": "private prompt text",
                    "cwd": "/private/repository",
                },
            )

        serialized = json.dumps(record)
        self.assertEqual(record["event"], "UserPromptSubmit")
        self.assertEqual(record["state"], "running")
        self.assertEqual(record["provider"], "grok")
        self.assertNotIn("private-grok-session", serialized)
        self.assertNotIn("private-prompt", serialized)
        self.assertNotIn("private prompt text", serialized)
        self.assertNotIn("/private/repository", serialized)

    def test_documented_snake_case_wire_events_normalize_to_bounded_events(self) -> None:
        cases = {
            "session_start": "SessionStart",
            "session_end": "SessionEnd",
            "user_prompt_submit": "UserPromptSubmit",
            "pre_tool_use": "PreToolUse",
            "post_tool_use": "PostToolUse",
            "post_tool_use_failure": "PostToolUse",
            "permission_denied": "PostToolUse",
            "pre_compact": "PreCompact",
            "post_compact": "PostCompact",
            "subagent_start": "SubagentStart",
            "subagent_stop": "SubagentStop",
            "subagent_end": "SubagentStop",
            "stop": "Stop",
            "stop_failure": "Stop",
            "stop_cancelled": "Stop",
        }
        for wire_name, expected in cases.items():
            with self.subTest(wire_name=wire_name):
                normalized = hook.normalize_payload(
                    {"hookEventName": wire_name}, "grok"
                )
                self.assertEqual(normalized["hook_event_name"], expected)
                self.assertIn(expected, hook.VALID_EVENTS)

        self.assertEqual(
            hook.normalize_payload(
                {"hookEventName": "preToolUse"}, "grok"
            )["hook_event_name"],
            "PreToolUse",
        )

    def test_grok_and_codex_session_namespaces_cannot_collide(self) -> None:
        codex = hook.session_key(hook.normalize_payload({"session_id": "same"}, "codex"))
        grok = hook.session_key(hook.normalize_payload({"sessionId": "same"}, "grok"))

        self.assertNotEqual(codex, grok)
        self.assertEqual(
            codex,
            hook.session_key({"session_id": "same"}),
            "Codex hashes remain backward compatible",
        )

    def test_permission_and_idle_notifications_map_to_bounded_states(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary)
            waiting = self.write(
                state_dir,
                {
                    "hookEventName": "notification",
                    "notificationType": "permission_prompt",
                    "sessionId": "session",
                    "promptId": "prompt",
                    "message": "private notification",
                },
            )
            idle = self.write(
                state_dir,
                {
                    "hookEventName": "notification",
                    "notificationType": "idle_prompt",
                    "sessionId": "session",
                    "promptId": "prompt",
                },
            )

        self.assertEqual((waiting["event"], waiting["state"]), ("PermissionRequest", "waiting"))
        self.assertEqual((idle["event"], idle["state"]), ("Stop", "idle"))
        self.assertEqual(idle["causal"]["pending_permissions"], [])
        self.assertNotIn("private notification", json.dumps(waiting))

    def test_grok_interaction_tools_use_waiting_review_then_running(self) -> None:
        cases = (
            ("ask_user_question", "waiting"),
            ("exit_plan_mode", "review"),
        )
        for tool_name, expected in cases:
            with self.subTest(tool_name=tool_name), tempfile.TemporaryDirectory() as temporary:
                state_dir = Path(temporary)
                before = self.write(
                    state_dir,
                    {
                        "hookEventName": "pre_tool_use",
                        "sessionId": tool_name,
                        "promptId": "prompt",
                        "toolUseId": "tool",
                        "toolName": tool_name,
                        "toolInput": {"question": "private"},
                    },
                )
                after = self.write(
                    state_dir,
                    {
                        "hookEventName": "post_tool_use",
                        "sessionId": tool_name,
                        "promptId": "prompt",
                        "toolUseId": "tool",
                        "toolName": tool_name,
                        "toolInput": {"question": "private"},
                    },
                )

            self.assertEqual(before["state"], expected)
            self.assertEqual(after["state"], "running")
            self.assertNotIn("private", json.dumps(after))

    def test_blocked_stop_revives_for_new_same_prompt_work_but_stale_tool_does_not(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary)
            self.write(
                state_dir,
                {
                    "hookEventName": "pre_tool_use",
                    "sessionId": "session",
                    "promptId": "prompt",
                    "toolUseId": "first",
                    "toolName": "shell",
                },
            )
            self.write(
                state_dir,
                {
                    "hookEventName": "stop",
                    "sessionId": "session",
                    "promptId": "prompt",
                },
            )
            revived = self.write(
                state_dir,
                {
                    "hookEventName": "pre_tool_use",
                    "sessionId": "session",
                    "promptId": "prompt",
                    "toolUseId": "second",
                    "toolName": "shell",
                },
            )
            stale = self.write(
                state_dir,
                {
                    "hookEventName": "pre_tool_use",
                    "sessionId": "session",
                    "promptId": "prompt",
                    "toolUseId": "first",
                    "toolName": "shell",
                },
            )

        self.assertEqual((revived["event"], revived["state"]), ("PreToolUse", "running"))
        self.assertEqual((stale["event"], stale["state"]), ("PreToolUse", "running"))
        self.assertEqual(stale["rejections"], {"stale_event": 1})

    def test_revived_blocked_stop_can_settle_with_final_idle_notification(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary)
            self.write(
                state_dir,
                {
                    "hookEventName": "stop",
                    "sessionId": "session",
                    "promptId": "prompt",
                },
            )
            revived = self.write(
                state_dir,
                {
                    "hookEventName": "pre_tool_use",
                    "sessionId": "session",
                    "promptId": "prompt",
                    "toolUseId": "new-tool",
                    "toolName": "shell",
                },
            )
            settled = self.write(
                state_dir,
                {
                    "hookEventName": "notification",
                    "notificationType": "idle_prompt",
                    "sessionId": "session",
                },
            )

        self.assertFalse(revived["fence"]["turn_closed"])
        self.assertEqual((settled["event"], settled["state"]), ("Stop", "idle"))
        self.assertTrue(settled["fence"]["turn_closed"])

    def test_child_agent_envelopes_do_not_change_host_activity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary)
            host = self.write(
                state_dir,
                {
                    "hookEventName": "user_prompt_submit",
                    "sessionId": "host",
                    "promptId": "prompt",
                },
            )
            ignored_path = state_dir / hook.session_key(
                hook.normalize_payload({"sessionId": "child"}, "grok")
            )
            with mock.patch.dict(os.environ, {"STATELET_AGENT_PROVIDER": "grok"}):
                ignored_output = hook.write_event({
                    "hookEventName": "session_end",
                    "sessionId": "child",
                    "subagentType": "explore",
                }, state_dir)
            unchanged = self.write(
                state_dir,
                {
                    "hookEventName": "stop",
                    "sessionId": "host",
                    "promptId": "prompt",
                    "subagentType": "explore",
                },
            )
            top_level_subagent = self.write(
                state_dir,
                {
                    "hookEventName": "subagent_start",
                    "sessionId": "host",
                    "promptId": "prompt",
                    "subagentId": "child",
                    "subagentType": "explore",
                },
            )
            ignored_subagent_stop = self.write(
                state_dir,
                {
                    "hookEventName": "subagent_stop",
                    "sessionId": "host",
                    "promptId": "prompt",
                    "subagentId": "child",
                    "subagentType": "explore",
                    "phase": "after",
                },
            )

        self.assertEqual(ignored_output, ignored_path.with_suffix(".json"))
        self.assertFalse(ignored_output.exists())
        self.assertEqual(unchanged, host)
        self.assertEqual(top_level_subagent["event"], "SubagentStart")
        self.assertEqual(top_level_subagent["state"], "running")
        self.assertEqual(ignored_subagent_stop, top_level_subagent)

    def test_installed_entrypoint_ignores_child_agent_payload(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            environment = dict(os.environ)
            environment.update(
                {
                    "STATELET_AGENT_PROVIDER": "grok",
                    "STATELET_STATE_DIR": temporary,
                }
            )
            result = subprocess.run(
                [sys.executable, str(ROOT / "mac" / "codex_pet_hook.py")],
                input=json.dumps(
                    {
                        "hookEventName": "user_prompt_submit",
                        "sessionId": "child",
                        "promptId": "prompt",
                        "subagentType": "explore",
                    }
                ),
                text=True,
                capture_output=True,
                env=environment,
                check=False,
            )

            self.assertEqual(result.returncode, 0)
            self.assertEqual(json.loads(result.stdout), {})
            self.assertEqual(list(Path(temporary).glob("*.json")), [])

    def test_stop_variants_settle_and_running_background_tasks_remain_active(self) -> None:
        for event in ("stop_failure", "stop_cancelled"):
            with self.subTest(event=event), tempfile.TemporaryDirectory() as temporary:
                record = self.write(
                    Path(temporary),
                    {"hookEventName": event, "sessionId": event, "promptId": "prompt"},
                )
            self.assertEqual((record["event"], record["state"]), ("Stop", "idle"))

        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary)
            record = self.write(
                state_dir,
                {
                    "hookEventName": "stop",
                    "sessionId": "background",
                    "promptId": "prompt",
                    "backgroundTasks": [
                        {"id": "private-task", "status": "running", "command": "private"}
                    ],
                },
            )
            settled = self.write(
                state_dir,
                {
                    "hookEventName": "stop",
                    "sessionId": "background",
                    "promptId": "prompt",
                    "stopHookActive": True,
                    "backgroundTasks": [],
                },
            )

        self.assertEqual((record["event"], record["state"]), ("Stop", "running"))
        self.assertFalse(record["fence"]["turn_closed"])
        self.assertNotIn("private-task", json.dumps(record))
        self.assertEqual((settled["event"], settled["state"]), ("Stop", "idle"))
        self.assertTrue(settled["fence"]["turn_closed"])

    def test_failure_and_denial_tool_events_use_real_wire_names_without_leaking(self) -> None:
        for wire_event in ("post_tool_use_failure", "permission_denied"):
            with self.subTest(wire_event=wire_event), tempfile.TemporaryDirectory() as temporary:
                record = self.write(
                    Path(temporary),
                    {
                        "hookEventName": wire_event,
                        "sessionId": wire_event,
                        "promptId": "prompt",
                        "toolUseId": "tool",
                        "toolName": "run_terminal_command",
                        "toolInput": {"command": "private-command"},
                        "error": "private-error",
                    },
                )

            self.assertEqual((record["event"], record["state"]), ("PostToolUse", "running"))
            self.assertNotIn("private-command", json.dumps(record))
            self.assertNotIn("private-error", json.dumps(record))

    def test_session_end_stop_reason_remains_nonterminal_until_session_end(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary)
            stopped = self.write(
                state_dir,
                {
                    "hookEventName": "stop",
                    "sessionId": "session",
                    "reason": "channel_closed",
                    "stopHookActive": False,
                },
            )
            ended = self.write(
                state_dir,
                {
                    "hookEventName": "session_end",
                    "sessionId": "session",
                    "reason": "shutdown",
                },
            )

        self.assertFalse(stopped["terminal"])
        self.assertEqual((ended["event"], ended["state"]), ("SessionEnd", "idle"))
        self.assertTrue(ended["terminal"])

    def test_grok_never_publishes_a_codex_activation_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary)
            record = self.write(
                state_dir,
                {
                    "hookEventName": "user_prompt_submit",
                    "sessionId": "safe-but-grok-only",
                    "promptId": "prompt",
                },
            )

            self.assertEqual(record["provider"], "grok")
            self.assertEqual(list(state_dir.glob("*.target.json")), [])


if __name__ == "__main__":
    unittest.main()
