"""Synthetic lifecycle outcomes; never read a user's sessions or transcripts."""

import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "mac" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


hook = load("outcome_hook", "codex_pet_hook.py")
state = load("outcome_state", "codex_pet_state.py")
sys.path.insert(0, str(ROOT / "mac"))
import codex_pet_state_aggregator as aggregator


class TurnOutcomeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)

    def write(self, event, at, turn="turn-a", session="synthetic-session", provider="codex", **extra):
        payload = dict(hook_event_name=event, session_id=session, turn_id=turn, **extra)
        with mock.patch.dict(os.environ, {"STATELET_AGENT_PROVIDER": provider}), mock.patch.object(hook.time, "time", return_value=at):
            path = hook.write_event(payload, self.directory)
        return json.loads(path.read_text()), path

    def outcomes(self, now):
        return state.read_session_activity(self.directory, now=now).get("outcomes", [])

    def test_grok_failure_is_blocked_without_private_error_or_false_completion(self):
        record, _ = self.write("StopFailure", 100, provider="grok", errorDetails="private error /secret/file token", lastAssistantMessage="private reply")
        self.assertEqual(record["event"], "StopFailure")
        self.assertFalse(record["terminal"], "A failed turn does not close its session")
        self.assertEqual(record["outcome"]["kind"], "blocked")
        self.assertRegex(record["outcome"]["id"], r"^[0-9a-f]{24}$")
        activity = state.read_session_activity(self.directory, now=101)
        self.assertEqual(activity["completed"], [])
        self.assertEqual(activity["active"], [])
        self.assertEqual(activity["outcomes"][0]["outcome"], "blocked")
        self.assertEqual(activity["outcomes"][0]["outcome_id"], record["outcome"]["id"])
        for private in ("private", "/secret/file", "synthetic-session", "turn-a"):
            self.assertNotIn(private, json.dumps(record) + json.dumps(activity))

    def test_stop_is_unverified_and_cannot_assert_success_with_extra_fields(self):
        for provider in ("codex", "grok"):
            record, _ = self.write("Stop", 100, provider=provider, status="completed", outcome="ready", reason="end_turn", last_assistant_message="All done")
            self.assertEqual(record["outcome"]["kind"], "unverified")
        self.assertEqual([item["outcome"] for item in self.outcomes(101)], ["unverified", "unverified"])

    def test_interrupt_and_grok_cancel_are_not_completed(self):
        for provider, event in (("codex", "Interrupt"), ("grok", "StopCancelled")):
            record, _ = self.write(event, 100, provider=provider)
            self.assertEqual(record["outcome"]["kind"], "interrupted")
            self.assertEqual(record["event"], "Interrupt")
        activity = state.read_session_activity(self.directory, now=101)
        self.assertEqual(activity["completed"], [])
        self.assertEqual([item["outcome"] for item in activity["outcomes"]], ["interrupted", "interrupted"])

    def test_session_close_preserves_known_failure_or_interruption(self):
        for provider, event in (("codex", "Interrupt"), ("grok", "StopFailure")):
            original, _ = self.write(event, 100, provider=provider)
            closed, _ = self.write("SessionEnd", 110, provider=provider)
            self.assertEqual(closed["outcome"], original["outcome"])
            self.assertTrue(closed["terminal"])
        activity = state.read_session_activity(self.directory, now=111)
        self.assertEqual(activity["completed"], [])
        self.assertEqual({item["outcome"] for item in activity["outcomes"]}, {"blocked", "interrupted"})

    def test_duplicates_and_late_callbacks_preserve_receipt(self):
        for provider, event in (("codex", "Interrupt"), ("grok", "StopFailure")):
            original, _ = self.write(event, 100, provider=provider)
            for late in (event, "Stop", "PreToolUse", "PostToolUse"):
                record, _ = self.write(late, 110, provider=provider, tool_use_id="late-tool", tool_name="Bash", tool_input={"command": "private"})
                self.assertEqual(record["outcome"], original["outcome"])
                self.assertEqual(record["event"], original["event"])

    def test_authoritative_failure_or_interrupt_supersedes_unverified_stop(self):
        for provider, event in (("codex", "Interrupt"), ("grok", "StopFailure")):
            stopped, _ = self.write("Stop", 100, provider=provider)
            final, _ = self.write(event, 101, provider=provider)
            self.assertNotEqual(final["outcome"]["id"], stopped["outcome"]["id"])
            self.assertNotEqual(final["outcome"]["kind"], "unverified")

    def test_new_turn_gets_new_receipt_even_if_reader_missed_running(self):
        first, _ = self.write("Stop", 100)
        self.write("UserPromptSubmit", 100, turn="turn-b")
        second, _ = self.write("Stop", 100, turn="turn-b")
        self.assertNotEqual(first["outcome"]["id"], second["outcome"]["id"])
        self.assertEqual(len(self.outcomes(101)), 1)
        stale, _ = self.write("Interrupt", 102, turn="turn-a")
        self.assertEqual(stale["outcome"], second["outcome"])

    def test_cross_session_and_provider_receipts_are_independent(self):
        receipts = []
        for provider in ("codex", "grok"):
            for session in ("session-one", "session-two"):
                record, _ = self.write("Stop", 100, session=session, provider=provider)
                receipts.append(record["outcome"]["id"])
        self.assertEqual(len(set(receipts)), 4)
        self.assertEqual(len(self.outcomes(101)), 4)

    def test_new_tool_work_after_provisional_stop_clears_unverified_outcome(self):
        for provider in ("codex", "grok"):
            self.write("Stop", 100, provider=provider)
            running, _ = self.write("PreToolUse", 101, provider=provider, tool_use_id="continued-tool", tool_name="Bash", tool_input={"command": "echo synthetic"})
            self.assertEqual(running["state"], "running")
            self.assertNotIn("outcome", running)
            self.assertFalse(running["fence"]["turn_closed"])
        self.assertEqual(self.outcomes(102), [])

    def test_background_stop_is_not_a_terminal_outcome(self):
        record, _ = self.write("Stop", 100, provider="grok", backgroundTasks=[{"status": "running"}])
        self.assertEqual(record["state"], "running")
        self.assertNotIn("outcome", record)
        self.assertEqual(self.outcomes(101), [])

    def test_outcome_retention_survives_active_ttl_and_is_bounded(self):
        _, path = self.write("StopFailure", 100, provider="grok")
        self.assertEqual(state.read_session_snapshot(self.directory, now=1100)["active"], [])
        self.assertTrue(path.exists())
        self.assertEqual(len(self.outcomes(1100)), 1)
        self.assertEqual(self.outcomes(100 + state.DEFAULT_COMPLETED_TTL + 1), [])
        self.assertFalse(path.exists())

    def test_legacy_records_remain_readable_without_invented_outcomes(self):
        path = self.directory / ("a" * 24 + ".json")
        path.write_text(json.dumps({"version": 1, "state": "idle", "event": "SessionEnd", "updated_at": 100}))
        snapshot = state.read_session_activity(self.directory, now=101)
        self.assertEqual(len(snapshot["completed"]), 1)
        self.assertEqual(snapshot.get("outcomes", []), [])
        self.assertNotIn("outcome", snapshot["completed"][0])

    def test_malformed_or_forged_outcome_is_not_projected(self):
        for malformed in ({"kind": "ready", "id": "a" * 24, "event_at": 100}, {"kind": "blocked", "id": "a" * 24, "event_at": 100}, {"kind": "unverified", "id": "private", "event_at": 100}, {"kind": "unverified", "id": "a" * 24, "event_at": True}, {"kind": "unverified", "id": "a" * 24, "event_at": 101}, {"kind": "unverified", "id": "a" * 24, "event_at": float("nan")}):
            record, path = self.write("Stop", 100)
            record["outcome"] = malformed
            path.write_text(json.dumps(record))
            self.assertEqual(self.outcomes(101), [])

    def test_ordinary_stop_duplicate_preserves_receipt_without_turn_ids(self):
        for provider in ("codex", "grok"):
            first, _ = self.write("Stop", 100, turn=None, provider=provider)
            duplicate, _ = self.write("Stop", 110, turn=None, provider=provider)
            self.assertEqual(first["outcome"], duplicate["outcome"])

    def test_unobserved_codex_tool_finish_cannot_reopen_provisional_stop(self):
        first, _ = self.write("Stop", 100)
        for late in ("PostToolUse", "SubagentStart", "PreCompact", "PermissionRequest"):
            record, _ = self.write(late, 101, tool_use_id="unobserved-tool")
            self.assertEqual(record["outcome"], first["outcome"])

    def test_corrupt_legacy_event_and_fence_cannot_block_a_new_prompt(self):
        record, path = self.write("Stop", 100)
        record["event"] = []
        record.pop("fence")
        path.write_text(json.dumps(record))
        resumed, _ = self.write("UserPromptSubmit", 101, turn="turn-b")
        self.assertEqual(resumed["state"], "running")
        self.assertNotIn("outcome", resumed)

    def test_unsupported_codex_failure_hook_does_not_invent_blocked(self):
        record, _ = self.write("StopFailure", 100)
        self.assertEqual(record["event"], "unknown")
        self.assertEqual(self.outcomes(101), [])

    def test_retention_caps_combined_outcomes_and_legacy_closures(self):
        for index in range(70):
            self.write("SessionEnd" if index % 2 else "StopFailure", 100 + index, session=f"synthetic-{index}", provider="grok")
        activity = state.read_session_activity(self.directory, now=200)
        self.assertEqual(len(activity["completed"]) + len(activity["outcomes"]), 64)
        self.assertEqual(len(list(self.directory.glob("[0-9a-f]" * 24 + ".json"))), 64)
        self.assertEqual(min(item["event_at"] for group in (activity["completed"], activity["outcomes"]) for item in group), 106)

    def test_source_filter_retains_other_provider_and_activation_uses_session_id(self):
        self.write("UserPromptSubmit", 99)
        codex, codex_path = self.write("Interrupt", 100)
        _, grok_path = self.write("StopFailure", 100, provider="grok")
        selector = self.directory / state.AGENT_SOURCE_FILENAME
        selector.write_text(json.dumps({"version": 1, "mode": "grok"}))
        selector.chmod(0o600)
        self.assertEqual([item["outcome"] for item in self.outcomes(101)], ["blocked"])
        self.assertTrue(codex_path.exists())
        self.assertTrue(grok_path.exists())
        selector.write_text(json.dumps({"version": 1, "mode": "combined"}))
        activity = state.read_session_activity(self.directory, now=101)
        self.assertEqual(len(activity["outcomes"]), 2)
        targets = state.read_session_targets(self.directory, activity, now=101)
        self.assertEqual(targets["targets"], [{"id": codex_path.stem, "thread_id": "synthetic-session"}])
        self.assertNotEqual(codex["outcome"]["id"], codex_path.stem)

    def test_publisher_emits_receipt_only_change_without_waiting_for_heartbeat(self):
        self.write("Interrupt", 100)
        activity = state.read_session_activity(self.directory, now=101)
        path = self.directory / state.SESSION_ACTIVITY_FILENAME
        publisher = aggregator.SessionActivityPublisher(path, heartbeat=60)
        published = publisher.publish_if_due(activity, wall_time=101, monotonic_time=1)
        self.assertEqual(published["outcomes"], activity["outcomes"])
        self.assertIsNone(publisher.publish_if_due(activity, wall_time=102, monotonic_time=2))
        activity["outcomes"][0]["outcome_id"] = "f" * 24
        changed = publisher.publish_if_due(activity, wall_time=103, monotonic_time=3)
        self.assertEqual(changed["outcomes"][0]["outcome_id"], "f" * 24)
        self.assertEqual(json.loads(path.read_text())["outcomes"], changed["outcomes"])
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
