#!/usr/bin/env python3
"""Tests for the board-independent Statelet lifecycle publisher."""

import json
import os
import select
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
MAC_DIR = ROOT / "mac"
if str(MAC_DIR) not in sys.path:
    sys.path.insert(0, str(MAC_DIR))

import codex_pet_state as state
import codex_pet_state_aggregator as aggregator


def record_path(directory: Path, digit: str) -> Path:
    return directory / ((digit * 24) + ".json")


def write_record(path: Path, lifecycle: str, updated_at: float) -> None:
    path.write_text(
        json.dumps(
            {
                "version": 1,
                "state": lifecycle,
                "event": "UserPromptSubmit",
                "updated_at": updated_at,
            }
        ),
        encoding="utf-8",
    )


def write_v2_record(
    path: Path,
    lifecycle: str,
    event: str,
    event_at: float,
    *,
    terminal: bool = False,
    rejections=None,
) -> None:
    path.write_text(
        json.dumps(
            {
                "version": 2,
                "state": lifecycle,
                "event": event,
                "event_at": event_at,
                "updated_at": event_at,
                "terminal": terminal,
                "completed_at": event_at if terminal else None,
                "rejections": rejections or {},
            }
        ),
        encoding="utf-8",
    )


def write_target_record(
    path: Path,
    identifier: str,
    thread_id: str,
    updated_at: float,
) -> None:
    path.write_text(
        json.dumps(
            {
                "version": 1,
                "id": identifier,
                "thread_id": thread_id,
                "updated_at": updated_at,
            }
        ),
        encoding="utf-8",
    )


class FakeClock:
    def __init__(self, wall_time: float = 100.0, monotonic_time: float = 10.0):
        self.wall_time = wall_time
        self.monotonic_time = monotonic_time

    def wall(self) -> float:
        return self.wall_time

    def monotonic(self) -> float:
        return self.monotonic_time

    def advance(self, seconds: float) -> None:
        self.wall_time += seconds
        self.monotonic_time += seconds


class ScriptedWaiter:
    def __init__(self, clock: FakeClock, actions=None):
        self.clock = clock
        self.actions = list(actions or [])
        self.timeouts = []
        self.wait_count = 0
        self.prepare_count = 0

    def prepare(self) -> bool:
        self.prepare_count += 1
        return True

    def wait(self, timeout: float) -> None:
        self.timeouts.append(timeout)
        action = (
            self.actions[self.wait_count]
            if self.wait_count < len(self.actions)
            else None
        )
        self.wait_count += 1
        if action is None:
            self.clock.advance(timeout)
        else:
            action(timeout)

    def close(self) -> None:
        pass


class LifecycleStateTests(unittest.TestCase):
    def test_default_paths_use_statelet_identity_with_legacy_environment_fallback(self) -> None:
        previous_statelet = os.environ.pop("STATELET_STATE_DIR", None)
        previous_legacy = os.environ.pop("CODEX_PET_STATE_DIR", None)
        try:
            self.assertEqual(
                state.default_state_dir(),
                Path.home() / "Library" / "Application Support" / "Statelet" / "sessions",
            )
            self.assertEqual(
                aggregator.DEFAULT_OUTPUT_PATH,
                Path.home()
                / "Library"
                / "Application Support"
                / "Statelet"
                / "runtime"
                / "current_state.json",
            )
            os.environ["CODEX_PET_STATE_DIR"] = "/tmp/legacy-statelet-compat"
            self.assertEqual(state.default_state_dir(), Path("/tmp/legacy-statelet-compat"))
            os.environ["STATELET_STATE_DIR"] = "/tmp/canonical-statelet"
            self.assertEqual(state.default_state_dir(), Path("/tmp/canonical-statelet"))
        finally:
            if previous_statelet is None:
                os.environ.pop("STATELET_STATE_DIR", None)
            else:
                os.environ["STATELET_STATE_DIR"] = previous_statelet
            if previous_legacy is None:
                os.environ.pop("CODEX_PET_STATE_DIR", None)
            else:
                os.environ["CODEX_PET_STATE_DIR"] = previous_legacy

    def test_priority_and_source_timestamp(self) -> None:
        active = [
            ("waiting", 8.0),
            ("review", 20.0),
            ("running", 30.0),
            ("waiting", 9.0),
        ]
        self.assertEqual(state.aggregate_state(active), "waiting")
        self.assertEqual(state.aggregate_state_with_source(active), ("waiting", 9.0))
        self.assertEqual(state.aggregate_state_with_source([]), ("idle", None))

    def test_ttl_future_skew_and_corrupt_records_fail_soft(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            live = record_path(directory, "a")
            stale = record_path(directory, "b")
            tolerated_future = record_path(directory, "c")
            invalid_future = record_path(directory, "d")
            corrupt = record_path(directory, "e")
            write_record(live, "running", 95.0)
            write_record(stale, "review", 89.0)
            write_record(tolerated_future, "waiting", 160.0)
            write_record(invalid_future, "waiting", 160.01)
            corrupt.write_text("{not-json", encoding="utf-8")

            active = state.read_active_states(directory, now=100.0, active_ttl=10.0)

            self.assertCountEqual(active, [("running", 95.0), ("waiting", 160.0)])
            self.assertFalse(stale.exists())
            self.assertFalse(invalid_future.exists())
            self.assertTrue(corrupt.exists())

            self.assertEqual(
                aggregator.resolve_state_snapshot(directory, 10.0, 100.0),
                ("waiting", 160.0, 2),
            )

    def test_post_tool_use_quiescent_fallback_expires_before_generic_ttl(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            record = record_path(directory, "a")
            write_v2_record(record, "running", "PostToolUse", 99.0)

            snapshot = state.read_session_snapshot(
                directory,
                now=99.0 + state.DEFAULT_QUIESCENT_TTL + 0.01,
                active_ttl=state.DEFAULT_ACTIVE_TTL,
            )

            self.assertEqual(snapshot["active"], [])
            self.assertEqual(snapshot["next_expiry"], None)
            self.assertEqual(snapshot["rejections"], {"quiescent_expired": 1})
            self.assertFalse(record.exists())

            self.assertEqual(
                aggregator.resolve_state_snapshot(
                    directory,
                    active_ttl=state.DEFAULT_ACTIVE_TTL,
                    wall_time=99.0 + state.DEFAULT_QUIESCENT_TTL + 0.01,
                ),
                ("idle", None, 0),
            )

    def test_post_tool_use_remains_active_during_quiescent_grace(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            write_v2_record(record_path(directory, "a"), "running", "PostToolUse", 99.0)

            snapshot = state.read_session_snapshot(
                directory,
                now=99.0 + state.DEFAULT_QUIESCENT_TTL - 0.01,
                active_ttl=state.DEFAULT_ACTIVE_TTL,
            )

        self.assertEqual(snapshot["active"], [("running", 99.0)])
        self.assertEqual(
            snapshot["next_expiry"], 99.0 + state.DEFAULT_QUIESCENT_TTL
        )

    def test_terminal_session_is_excluded_and_diagnostics_are_privacy_safe(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            write_v2_record(
                record_path(directory, "a"),
                "idle",
                "SessionEnd",
                99.0,
                terminal=True,
            )
            write_v2_record(
                record_path(directory, "b"),
                "waiting",
                "PermissionRequest",
                98.0,
                rejections={"stale_event": 2},
            )

            snapshot = state.read_session_snapshot(directory, now=100.0, active_ttl=10.0)

        self.assertEqual(snapshot["active"], [("waiting", 98.0)])
        self.assertEqual(snapshot["latest_event"], "SessionEnd")
        self.assertEqual(snapshot["latest_event_at"], 99.0)
        self.assertEqual(snapshot["rejections"], {"stale_event": 2})
        self.assertNotIn("a" * 24, json.dumps(snapshot))
        self.assertNotIn("b" * 24, json.dumps(snapshot))

    def test_session_activity_orders_groups_and_retains_terminal_records(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            write_v2_record(
                record_path(directory, "a"),
                "running",
                "UserPromptSubmit",
                130.0,
            )
            write_v2_record(
                record_path(directory, "b"),
                "waiting",
                "PermissionRequest",
                120.0,
            )
            write_v2_record(
                record_path(directory, "c"),
                "idle",
                "SessionEnd",
                100.0,
                terminal=True,
            )

            activity = state.read_session_activity(
                directory,
                now=130.0 + state.DEFAULT_ACTIVE_TTL + 1.0,
                active_ttl=state.DEFAULT_ACTIVE_TTL,
            )
            aggregate = state.read_session_snapshot(
                directory,
                now=130.0 + state.DEFAULT_ACTIVE_TTL + 1.0,
                active_ttl=state.DEFAULT_ACTIVE_TTL,
            )

        self.assertEqual([item["id"] for item in activity["active"]], [])
        self.assertEqual([item["id"] for item in activity["completed"]], ["c" * 24])
        self.assertTrue(aggregate["active"] == [])
        self.assertTrue(activity["completed"][0]["terminal"])
        self.assertEqual(activity["completed"][0]["started_at"], 100.0)
        self.assertEqual(activity["completed"][0]["completed_at"], 100.0)
        self.assertEqual(activity["completed"][0]["category"], "codex")

    def test_session_activity_omits_stop_and_projects_only_session_end_as_completed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            write_v2_record(
                record_path(directory, "a"),
                "idle",
                "Stop",
                99.0,
                terminal=False,
            )
            write_v2_record(
                record_path(directory, "b"),
                "idle",
                "SessionEnd",
                100.0,
                terminal=True,
            )

            activity = state.read_session_activity(directory, now=101.0)

        self.assertEqual(activity["active"], [])
        self.assertEqual([item["id"] for item in activity["completed"]], ["b" * 24])
        self.assertEqual(activity["completed"][0]["event"], "SessionEnd")
        self.assertTrue(activity["completed"][0]["terminal"])

    def test_legacy_stop_record_is_normalized_as_a_nonterminal_turn_end(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            record = record_path(directory, "a")
            record.write_text(
                json.dumps({
                    "version": 1,
                    "state": "idle",
                    "event": "Stop",
                    "updated_at": 100.0,
                }),
                encoding="utf-8",
            )

            activity = state.read_session_activity(directory, now=101.0)
            record_still_exists = record.exists()

        self.assertEqual(activity["active"], [])
        self.assertEqual(activity["completed"], [])
        self.assertTrue(record_still_exists)

    def test_one_session_record_moves_between_activity_groups_without_duplication(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            record = record_path(directory, "a")

            write_v2_record(record, "idle", "Stop", 100.0, terminal=False)
            after_stop = state.read_session_activity(directory, now=100.0)

            write_v2_record(record, "running", "UserPromptSubmit", 110.0)
            after_prompt = state.read_session_activity(directory, now=110.0)

            write_v2_record(record, "idle", "SessionEnd", 120.0, terminal=True)
            after_session_end = state.read_session_activity(directory, now=120.0)

        identifier = "a" * 24
        self.assertEqual(after_stop["active"], [])
        self.assertEqual(after_stop["completed"], [])
        self.assertEqual([item["id"] for item in after_prompt["active"]], [identifier])
        self.assertEqual(after_prompt["completed"], [])
        self.assertEqual(after_session_end["active"], [])
        self.assertEqual(
            [item["id"] for item in after_session_end["completed"]],
            [identifier],
        )

    def test_session_activity_deterministically_prioritizes_active_states(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            write_v2_record(record_path(directory, "a"), "running", "UserPromptSubmit", 108.0)
            write_v2_record(record_path(directory, "b"), "waiting", "PermissionRequest", 101.0)
            write_v2_record(record_path(directory, "c"), "review", "PreCompact", 109.0)

            activity = state.read_session_activity(directory, now=110.0)

        self.assertEqual(
            [item["id"] for item in activity["active"]],
            ["b" * 24, "c" * 24, "a" * 24],
        )
        self.assertEqual(activity["active"][0]["category"], "approval")
        self.assertNotIn("prompt", json.dumps(activity))

    def test_session_activity_prunes_terminal_overflow_but_not_active_records(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for index in range(66):
                write_v2_record(
                    directory / f"{index:024x}.json",
                    "idle",
                    "SessionEnd",
                    100.0 + index,
                    terminal=True,
                )
            write_v2_record(
                record_path(directory, "f"),
                "running",
                "UserPromptSubmit",
                100.0,
            )

            activity = state.read_session_activity(directory, now=165.0)
            self.assertEqual(len(activity["completed"]), state.MAX_ACTIVITY_ENTRIES)
            self.assertFalse((directory / f"{0:024x}.json").exists())
            self.assertFalse((directory / f"{1:024x}.json").exists())
            self.assertTrue((directory / ("f" * 24 + ".json")).exists())

    def test_session_activity_excludes_fresh_idle_start_without_pruning_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            record = record_path(directory, "a")
            write_v2_record(record, "idle", "SessionStart", 99.0)

            activity = state.read_session_activity(directory, now=100.0)
            aggregate = state.read_session_snapshot(directory, now=100.0)
            record_exists = record.exists()

        self.assertEqual(activity["active"], [])
        self.assertTrue(record_exists)
        self.assertEqual(aggregate["active"], [("idle", 99.0)])

    def test_session_targets_filter_unsafe_records_and_retain_bounded_unprojected_targets(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / "sessions"
            directory.mkdir()
            projected = "a" * 24
            orphan = "b" * 24
            corrupt = "c" * 24
            invalid = "d" * 24
            symlinked = "e" * 24
            expired = "f" * 24
            write_target_record(
                directory / f"{projected}.target.json",
                projected,
                "thread:projected",
                99.0,
            )
            write_target_record(
                directory / f"{orphan}.target.json",
                orphan,
                "thread:orphan",
                99.0,
            )
            (directory / f"{corrupt}.target.json").write_text(
                "{not-json", encoding="utf-8"
            )
            write_target_record(
                directory / f"{invalid}.target.json",
                invalid,
                "contains whitespace",
                99.0,
            )
            write_target_record(
                directory / f"{expired}.target.json",
                expired,
                "thread:expired",
                100.0 - state.DEFAULT_COMPLETED_TTL - 1.0,
            )
            outside = root / "outside-target.json"
            write_target_record(outside, symlinked, "thread:outside", 99.0)
            link = directory / f"{symlinked}.target.json"
            link.symlink_to(outside)
            activity = {
                "active": [{"id": projected}, {"id": invalid}, {"id": symlinked}],
                "completed": [],
            }

            targets = state.read_session_targets(directory, activity, now=100.0)

            self.assertEqual(
                targets,
                {
                    "version": 1,
                    "emitted_at": 100.0,
                    "targets": [
                        {"id": projected, "thread_id": "thread:projected"}
                    ],
                },
            )
            self.assertTrue((directory / f"{orphan}.target.json").exists())
            self.assertTrue((directory / f"{corrupt}.target.json").exists())
            self.assertFalse((directory / f"{invalid}.target.json").exists())
            self.assertFalse((directory / f"{expired}.target.json").exists())
            self.assertTrue(link.is_symlink())
            self.assertEqual(
                json.loads(outside.read_text(encoding="utf-8"))["thread_id"],
                "thread:outside",
            )

    def test_session_target_survives_stop_until_session_end_projection(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "sessions"
            directory.mkdir()
            identifier = "a" * 24
            record = directory / f"{identifier}.json"
            target = directory / f"{identifier}.target.json"
            write_target_record(target, identifier, "thread:completed", 99.0)
            write_v2_record(record, "idle", "Stop", 100.0, terminal=False)

            stopped_activity = state.read_session_activity(directory, now=100.0)
            stopped_targets = state.read_session_targets(
                directory, stopped_activity, now=100.0
            )

            self.assertEqual(stopped_activity["active"], [])
            self.assertEqual(stopped_activity["completed"], [])
            self.assertEqual(stopped_targets["targets"], [])
            self.assertTrue(target.exists())

            write_v2_record(record, "idle", "SessionEnd", 101.0, terminal=True)
            completed_activity = state.read_session_activity(directory, now=101.0)
            completed_targets = state.read_session_targets(
                directory, completed_activity, now=101.0
            )

        self.assertEqual(
            [item["id"] for item in completed_activity["completed"]],
            [identifier],
        )
        self.assertEqual(
            completed_targets["targets"],
            [{"id": identifier, "thread_id": "thread:completed"}],
        )

    def test_hook_record_reader_ignores_symlinks_and_special_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            outside = directory / "outside.json"
            write_v2_record(outside, "waiting", "PermissionRequest", 99.0)
            link = record_path(directory, "a")
            link.symlink_to(outside)
            fifo = record_path(directory, "b")
            os.mkfifo(fifo)

            snapshot = state.read_session_snapshot(directory, now=100.0)
            link_is_symlink = link.is_symlink()
            fifo_is_fifo = stat.S_ISFIFO(os.lstat(fifo).st_mode)

        self.assertEqual(snapshot["active"], [])
        self.assertEqual(snapshot["rejections"], {})
        self.assertTrue(link_is_symlink)
        self.assertTrue(fifo_is_fifo)

    def test_owner_regular_corrupt_records_remain_bounded_diagnostics(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            malformed_json = record_path(directory, "c")
            malformed_utf8 = record_path(directory, "d")
            read_failure = record_path(directory, "e")
            malformed_json.write_text("{not-json", encoding="utf-8")
            malformed_utf8.write_bytes(b"\xff\xfe")
            write_v2_record(read_failure, "running", "UserPromptSubmit", 99.0)
            real_read = state.os.read
            failure_inode = read_failure.stat().st_ino

            def fail_one_read(descriptor, count):
                if os.fstat(descriptor).st_ino == failure_inode:
                    raise OSError("ordinary read failure")
                return real_read(descriptor, count)

            with mock.patch.object(state.os, "read", side_effect=fail_one_read):
                snapshot = state.read_session_snapshot(directory, now=100.0)

            files_remain = all(
                path.exists() for path in (malformed_json, malformed_utf8, read_failure)
            )

        self.assertEqual(snapshot["active"], [])
        self.assertEqual(snapshot["rejections"], {"invalid_record": 3})
        self.assertTrue(files_remain)

    def test_pruning_preserves_a_pathname_replacement(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            record = record_path(directory, "a")
            write_v2_record(record, "running", "UserPromptSubmit", 1.0)
            real_rename = state.os.rename
            replaced = False

            def replace_before_rename(source, destination, **kwargs):
                nonlocal replaced
                if not replaced and source == record.name:
                    replaced = True
                    replacement = directory / ".replacement.json"
                    write_v2_record(
                        replacement,
                        "waiting",
                        "PermissionRequest",
                        100.0,
                    )
                    os.replace(replacement, record)
                return real_rename(source, destination, **kwargs)

            with mock.patch.object(state.os, "rename", side_effect=replace_before_rename):
                state.read_session_snapshot(directory, now=100.0, active_ttl=10.0)

            preserved = json.loads(record.read_text(encoding="utf-8"))

        self.assertTrue(replaced)
        self.assertEqual(preserved["state"], "waiting")
        self.assertEqual(preserved["event_at"], 100.0)

    def test_pruning_uses_open_directory_when_parent_path_is_swapped(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / "sessions"
            directory.mkdir()
            record = record_path(directory, "a")
            write_v2_record(record, "running", "UserPromptSubmit", 1.0)
            original_read = state._read_hook_record
            swapped = False

            def swap_after_read(directory_fd, name):
                nonlocal swapped
                result = original_read(directory_fd, name)
                if not swapped:
                    swapped = True
                    directory.rename(root / "old-sessions")
                    directory.mkdir()
                    write_v2_record(
                        record_path(directory, "a"),
                        "waiting",
                        "PermissionRequest",
                        100.0,
                    )
                return result

            with mock.patch.object(state, "_read_hook_record", side_effect=swap_after_read):
                state.read_session_snapshot(directory, now=100.0, active_ttl=10.0)

            preserved = json.loads(record_path(directory, "a").read_text(encoding="utf-8"))

        self.assertTrue(swapped)
        self.assertEqual(preserved["state"], "waiting")

    def test_private_event_string_is_rejected_before_aggregation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            private = record_path(directory, "a")
            write_v2_record(
                private,
                "running",
                "/Users/private/repository prompt contents",
                99.0,
            )

            snapshot = state.read_session_snapshot(directory, now=100.0, active_ttl=10.0)

        self.assertEqual(snapshot["active"], [])
        self.assertIsNone(snapshot["latest_event"])
        self.assertEqual(snapshot["rejections"], {"invalid_record": 1})

    def test_bounded_causal_metadata_is_accepted_but_never_aggregated(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            record = record_path(directory, "c")
            turn_hash = "a" * 24
            record.write_text(
                json.dumps({
                    "version": 2,
                    "state": "running",
                    "event": "PreToolUse",
                    "event_at": 99.0,
                    "updated_at": 99.0,
                    "terminal": False,
                    "rejections": {},
                    "causal": {
                        "version": 1,
                        "current_turn": turn_hash,
                        "prior_turns": [],
                        "tool_phases": {},
                        "active_tool": None,
                        "pending_permissions": [],
                        "latest_event": "PreToolUse",
                    },
                }),
                encoding="utf-8",
            )

            snapshot = state.read_session_snapshot(directory, now=100.0, active_ttl=10.0)

        self.assertEqual(snapshot["active"], [("running", 99.0)])
        self.assertNotIn("causal", snapshot)
        self.assertNotIn(turn_hash, json.dumps(snapshot))

    def test_malformed_causal_metadata_invalidates_record_without_crashing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            record = record_path(directory, "d")
            write_v2_record(record, "running", "PreToolUse", 99.0)
            value = json.loads(record.read_text(encoding="utf-8"))
            value["causal"] = []
            record.write_text(json.dumps(value), encoding="utf-8")

            snapshot = state.read_session_snapshot(directory, now=100.0, active_ttl=10.0)

        self.assertEqual(snapshot["active"], [])
        self.assertEqual(snapshot["rejections"], {"invalid_record": 1})


class PublisherTests(unittest.TestCase):
    def test_default_heartbeat_is_low_frequency(self) -> None:
        self.assertGreaterEqual(aggregator.DEFAULT_HEARTBEAT_INTERVAL, 60.0)

    def test_atomic_write_session_activity_is_private_and_versioned(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "sessions" / state.SESSION_ACTIVITY_FILENAME
            snapshot = {
                "active": [
                    {
                        "id": "a" * 24,
                        "state": "running",
                        "event": "UserPromptSubmit",
                        "event_at": 100.0,
                        "started_at": 100.0,
                        "completed_at": None,
                        "category": "codex",
                        "terminal": False,
                    }
                ],
                "completed": [],
            }
            record = aggregator.atomic_write_session_activity(output, snapshot, 101.0)

            self.assertEqual(record["version"], 1)
            self.assertEqual(json.loads(output.read_text(encoding="utf-8")), record)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            self.assertNotIn("/Users/", output.read_text(encoding="utf-8"))

    def test_activity_and_private_targets_publish_with_matching_emitted_at(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            activity_path = state_dir / state.SESSION_ACTIVITY_FILENAME
            identifier = "a" * 24
            snapshot = {
                "active": [
                    {
                        "id": identifier,
                        "state": "running",
                        "event": "UserPromptSubmit",
                        "event_at": 100.0,
                        "started_at": 100.0,
                        "completed_at": None,
                        "category": "codex",
                        "terminal": False,
                    }
                ],
                "completed": [],
            }
            target_snapshot = {
                "targets": [{"id": identifier, "thread_id": "thread:private"}]
            }
            publisher = aggregator.SessionActivityPublisher(activity_path, heartbeat=60.0)

            publisher.publish_if_due(snapshot, 123.0, 10.0, target_snapshot)

            activity = json.loads(activity_path.read_text(encoding="utf-8"))
            targets = json.loads(
                (state_dir / state.SESSION_ACTIVITY_TARGETS_FILENAME).read_text(encoding="utf-8")
            )
            self.assertEqual(activity["emitted_at"], 123.0)
            self.assertEqual(targets["emitted_at"], 123.0)
            self.assertNotIn("thread:private", json.dumps(activity))
            self.assertEqual(
                stat.S_IMODE(
                    (state_dir / state.SESSION_ACTIVITY_TARGETS_FILENAME).stat().st_mode
                ),
                0o600,
            )
            self.assertEqual(
                targets["targets"],
                [{"id": identifier, "thread_id": "thread:private"}],
            )

    def test_private_titles_publish_exact_bounded_schema_without_public_leakage(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            output = state_dir / state.SESSION_ACTIVITY_FILENAME
            identifier = "a" * 24
            snapshot = {
                "active": [{
                    "id": identifier,
                    "state": "running",
                    "event": "UserPromptSubmit",
                    "event_at": 100.0,
                    "started_at": 100.0,
                    "completed_at": None,
                    "category": "codex",
                    "terminal": False,
                }],
                "completed": [],
            }
            targets = {"targets": [{"id": identifier, "thread_id": "thread:secret"}]}
            titles = {"titles": [{"id": identifier, "title": "Fix tool execution"}]}
            publisher = aggregator.SessionActivityPublisher(output, heartbeat=60.0)

            publisher.publish_if_due(snapshot, 123.0, 10.0, targets, titles)

            public = json.loads(output.read_text(encoding="utf-8"))
            private = json.loads(
                output.with_name(state.SESSION_ACTIVITY_TITLES_FILENAME).read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(
                private,
                {
                    "version": 1,
                    "schema_version": 1,
                    "emitted_at": 123.0,
                    "titles": [{"id": identifier, "title": "Fix tool execution"}],
                },
            )
            self.assertEqual(stat.S_IMODE(output.with_name(state.SESSION_ACTIVITY_TITLES_FILENAME).stat().st_mode), 0o600)
            self.assertEqual(public["emitted_at"], private["emitted_at"])
            self.assertNotIn("Fix tool execution", json.dumps(public))
            self.assertNotIn("thread:secret", json.dumps(private))
            for sentinel in ("preview", "prompt", "turns", "responses", "/Users/private"):
                self.assertNotIn(sentinel, json.dumps(private))

    def test_title_projection_sanitizes_and_writer_rejects_invalid_titles(self) -> None:
        identifier = "a" * 24
        targets = {"targets": [{"id": identifier, "thread_id": "thread:one"}]}
        self.assertEqual(
            aggregator.activity_title_snapshot(
                targets,
                {"thread:one": "  Fix\n\u200btool\t execution  "},
            ),
            {"titles": [{"id": identifier, "title": "Fixtool execution"}]},
        )
        self.assertEqual(
            aggregator.activity_title_snapshot(targets, {"thread:one": "x" * 121}),
            {"titles": []},
        )
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(ValueError):
                aggregator.atomic_write_activity_titles(
                    Path(temporary) / state.SESSION_ACTIVITY_TITLES_FILENAME,
                    {"titles": [{"id": identifier, "title": "bad\nname"}]},
                    100.0,
                )

    def test_resolver_success_null_and_failure_are_fail_soft(self) -> None:
        class Resolver:
            def __init__(self, result):
                self.result = result
                self.calls = []

            def resolve(self, thread_ids, monotonic_time=None):
                self.calls.append((list(thread_ids), monotonic_time))
                return self.result

        for result, expected_titles, expected_diagnostic in (
            (({"thread:private": "Named task"}, None), [{"id": "a" * 24, "title": "Named task"}], []),
            (({}, None), [], []),
            (({"thread:private": "must be discarded"}, "timeout"), [], [
                "Statelet session activity sidecar component=session_titles status=degraded reason=timeout"
            ]),
        ):
            with self.subTest(result=result), tempfile.TemporaryDirectory() as temporary:
                state_dir = Path(temporary) / "sessions"
                output = Path(temporary) / "runtime" / "current_state.json"
                state_dir.mkdir()
                identifier = "a" * 24
                write_v2_record(record_path(state_dir, "a"), "running", "UserPromptSubmit", 100.0)
                write_target_record(state_dir / f"{identifier}.target.json", identifier, "thread:private", 100.0)
                diagnostics = []
                resolver = Resolver(result)

                aggregator.run(
                    state_dir, output, 0.25, 60.0, 900.0, True, False, None, 30.0,
                    lambda: False,
                    waiter=ScriptedWaiter(FakeClock()),
                    wall_clock=lambda: 100.0,
                    monotonic_clock=lambda: 10.0,
                    activity_diagnostic=diagnostics.append,
                    title_resolver=resolver,
                )

                titles = json.loads((state_dir / state.SESSION_ACTIVITY_TITLES_FILENAME).read_text(encoding="utf-8"))
                targets = json.loads((state_dir / state.SESSION_ACTIVITY_TARGETS_FILENAME).read_text(encoding="utf-8"))
                self.assertEqual(titles["titles"], expected_titles)
                self.assertEqual(targets["targets"], [{"id": identifier, "thread_id": "thread:private"}])
                self.assertEqual(diagnostics, expected_diagnostic)
                self.assertEqual(resolver.calls, [(["thread:private"], 10.0)])

    def test_title_only_change_republishes_activity_commit_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "sessions" / state.SESSION_ACTIVITY_FILENAME
            identifier = "a" * 24
            snapshot = {"active": [], "completed": []}
            targets = {"targets": [{"id": identifier, "thread_id": "thread:private"}]}
            publisher = aggregator.SessionActivityPublisher(output, heartbeat=60.0)

            first = publisher.publish_if_due(snapshot, 100.0, 10.0, targets, {"titles": []})
            second = publisher.publish_if_due(
                snapshot,
                101.0,
                11.0,
                targets,
                {"titles": [{"id": identifier, "title": "Fresh title"}]},
            )

            self.assertIsNotNone(first)
            self.assertIsNotNone(second)
            self.assertEqual(second["emitted_at"], 101.0)
            title_record = json.loads(output.with_name(state.SESSION_ACTIVITY_TITLES_FILENAME).read_text(encoding="utf-8"))
            self.assertEqual(title_record["emitted_at"], 101.0)
            self.assertEqual(title_record["titles"][0]["title"], "Fresh title")

    def test_target_write_failure_does_not_block_activity_or_current_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            output = Path(temporary) / "runtime" / "current_state.json"
            state_dir.mkdir()
            write_v2_record(
                record_path(state_dir, "a"),
                "running",
                "UserPromptSubmit",
                100.0,
            )
            clock = FakeClock(wall_time=100.0, monotonic_time=10.0)
            diagnostics = []

            with mock.patch.object(
                aggregator,
                "atomic_write_activity_targets",
                side_effect=OSError(
                    "/Users/private/repository private-thread:secret"
                ),
            ):
                aggregator.run(
                    state_dir,
                    output,
                    poll=0.25,
                    heartbeat=60.0,
                    active_ttl=900.0,
                    once=True,
                    print_state=False,
                    forced_state=None,
                    force_seconds=30.0,
                    should_stop=lambda: False,
                    waiter=ScriptedWaiter(clock),
                    wall_clock=clock.wall,
                    monotonic_clock=clock.monotonic,
                    activity_diagnostic=diagnostics.append,
                )

            current_state = json.loads(output.read_text(encoding="utf-8"))
            activity = json.loads(
                (state_dir / state.SESSION_ACTIVITY_FILENAME).read_text(
                    encoding="utf-8"
                )
            )

        self.assertEqual(current_state["state"], "running")
        self.assertEqual(current_state["active_sessions"], 1)
        self.assertEqual(activity["active"][0]["id"], "a" * 24)
        self.assertEqual(
            diagnostics,
            [
                "Statelet session activity sidecar component=activation_targets "
                "status=degraded reason=io_error"
            ],
        )
        self.assertNotIn("/Users/", json.dumps(diagnostics))
        self.assertNotIn("private-thread:secret", json.dumps(diagnostics))

    def test_target_read_failure_does_not_block_activity_or_current_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            output = Path(temporary) / "runtime" / "current_state.json"
            state_dir.mkdir()
            write_v2_record(
                record_path(state_dir, "a"),
                "waiting",
                "PermissionRequest",
                100.0,
            )
            clock = FakeClock(wall_time=100.0, monotonic_time=10.0)
            diagnostics = []

            with mock.patch.object(
                aggregator,
                "read_session_targets",
                side_effect=OSError("/Users/private/repository private target"),
            ):
                aggregator.run(
                    state_dir,
                    output,
                    poll=0.25,
                    heartbeat=60.0,
                    active_ttl=900.0,
                    once=True,
                    print_state=False,
                    forced_state=None,
                    force_seconds=30.0,
                    should_stop=lambda: False,
                    waiter=ScriptedWaiter(clock),
                    wall_clock=clock.wall,
                    monotonic_clock=clock.monotonic,
                    activity_diagnostic=diagnostics.append,
                )

            current_state = json.loads(output.read_text(encoding="utf-8"))
            activity = json.loads(
                (state_dir / state.SESSION_ACTIVITY_FILENAME).read_text(
                    encoding="utf-8"
                )
            )

        self.assertEqual(current_state["state"], "waiting")
        self.assertEqual(activity["active"][0]["id"], "a" * 24)
        self.assertEqual(
            diagnostics,
            [
                "Statelet session activity sidecar component=activation_targets "
                "status=degraded reason=io_error"
            ],
        )
        self.assertNotIn("/Users/", json.dumps(diagnostics))
        self.assertNotIn("private target", json.dumps(diagnostics))

    def test_activity_writer_rejects_symlinked_state_directory_without_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "target-sessions"
            target.mkdir(mode=0o755)
            os.chmod(target, 0o755)
            target_activity = target / state.SESSION_ACTIVITY_FILENAME
            target_activity.write_text("keep\n", encoding="utf-8")
            os.chmod(target_activity, 0o644)
            linked = root / "sessions"
            linked.symlink_to(target, target_is_directory=True)
            snapshot = {"active": [], "completed": []}

            with self.assertRaises(OSError):
                aggregator.atomic_write_session_activity(
                    linked / state.SESSION_ACTIVITY_FILENAME,
                    snapshot,
                    100.0,
                )

            clock = FakeClock(wall_time=100.0, monotonic_time=10.0)
            current_state = root / "runtime" / "current_state.json"
            aggregator.run(
                linked,
                current_state,
                poll=0.25,
                heartbeat=60.0,
                active_ttl=900.0,
                once=True,
                print_state=False,
                forced_state=None,
                force_seconds=30.0,
                should_stop=lambda: False,
                waiter=ScriptedWaiter(clock),
                wall_clock=clock.wall,
                monotonic_clock=clock.monotonic,
                activity_diagnostic=lambda _message: None,
            )

            target_contents = target_activity.read_text(encoding="utf-8")
            target_mode = stat.S_IMODE(target.stat().st_mode)
            target_file_mode = stat.S_IMODE(target_activity.stat().st_mode)
            published = json.loads(current_state.read_text(encoding="utf-8"))

        self.assertEqual(target_contents, "keep\n")
        self.assertEqual(target_mode, 0o755)
        self.assertEqual(target_file_mode, 0o644)
        self.assertEqual(published["state"], "idle")

    def test_run_publishes_session_activity_sidecar_with_lifecycle_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            output = Path(temporary) / "runtime" / "current_state.json"
            state_dir.mkdir()
            write_v2_record(
                record_path(state_dir, "a"),
                "running",
                "UserPromptSubmit",
                100.0,
            )
            clock = FakeClock(wall_time=100.0, monotonic_time=10.0)
            aggregator.run(
                state_dir,
                output,
                poll=0.25,
                heartbeat=60.0,
                active_ttl=900.0,
                once=True,
                print_state=False,
                forced_state=None,
                force_seconds=30.0,
                should_stop=lambda: False,
                waiter=ScriptedWaiter(clock),
                wall_clock=clock.wall,
                monotonic_clock=clock.monotonic,
            )
            activity_path = state_dir / state.SESSION_ACTIVITY_FILENAME
            activity = json.loads(activity_path.read_text(encoding="utf-8"))

        self.assertEqual(activity["version"], 1)
        self.assertEqual(activity["active"][0]["id"], "a" * 24)
        self.assertEqual(activity["active"][0]["state"], "running")
        self.assertEqual(activity["active"][0]["category"], "codex")

    def test_optional_activity_projection_failure_does_not_block_current_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            output = Path(temporary) / "runtime" / "current_state.json"
            state_dir.mkdir()
            write_v2_record(
                record_path(state_dir, "a"),
                "running",
                "UserPromptSubmit",
                100.0,
            )
            clock = FakeClock(wall_time=100.0, monotonic_time=10.0)
            diagnostics = []
            with mock.patch.object(
                aggregator,
                "read_session_activity",
                side_effect=OSError("optional projection failed"),
            ):
                aggregator.run(
                    state_dir,
                    output,
                    poll=0.25,
                    heartbeat=60.0,
                    active_ttl=900.0,
                    once=True,
                    print_state=False,
                    forced_state=None,
                    force_seconds=30.0,
                    should_stop=lambda: False,
                    waiter=ScriptedWaiter(clock),
                    wall_clock=clock.wall,
                    monotonic_clock=clock.monotonic,
                    activity_diagnostic=diagnostics.append,
                )

            published = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(published["state"], "running")
        self.assertEqual(published["active_sessions"], 1)
        self.assertEqual(
            diagnostics,
            ["Statelet session activity sidecar status=degraded reason=io_error"],
        )

    def test_optional_activity_write_failure_happens_after_current_state_publication(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            output = Path(temporary) / "runtime" / "current_state.json"
            state_dir.mkdir()
            write_v2_record(
                record_path(state_dir, "a"),
                "waiting",
                "PermissionRequest",
                100.0,
            )
            clock = FakeClock(wall_time=100.0, monotonic_time=10.0)

            def fail_after_authoritative_publish(*_args, **_kwargs):
                self.assertEqual(
                    json.loads(output.read_text(encoding="utf-8"))["state"],
                    "waiting",
                )
                raise OSError("optional write failed")

            with mock.patch.object(
                aggregator,
                "atomic_write_session_activity",
                side_effect=fail_after_authoritative_publish,
            ):
                aggregator.run(
                    state_dir,
                    output,
                    poll=0.25,
                    heartbeat=60.0,
                    active_ttl=900.0,
                    once=True,
                    print_state=False,
                    forced_state=None,
                    force_seconds=30.0,
                    should_stop=lambda: False,
                    waiter=ScriptedWaiter(clock),
                    wall_clock=clock.wall,
                    monotonic_clock=clock.monotonic,
                    activity_diagnostic=lambda _message: None,
                )

    def test_optional_activity_diagnostic_is_rate_limited_and_reports_recovery(self) -> None:
        messages = []
        diagnostic = aggregator.OptionalActivityDiagnostic(messages.append, interval=60.0)

        diagnostic.failure("io_error", 10.0)
        diagnostic.failure("invalid_projection", 20.0)
        diagnostic.failure("encoding_error", 70.0)
        diagnostic.recovery()
        diagnostic.recovery()

        self.assertEqual(
            messages,
            [
                "Statelet session activity sidecar status=degraded reason=io_error",
                "Statelet session activity sidecar status=degraded reason=encoding_error",
                "Statelet session activity sidecar status=recovered",
            ],
        )

    def test_optional_activity_diagnostic_bounds_tight_failure_recovery_flapping(self) -> None:
        messages = []
        diagnostic = aggregator.OptionalActivityDiagnostic(messages.append, interval=60.0)

        diagnostic.failure("io_error", 10.0)
        diagnostic.recovery()
        for timestamp in (20.0, 30.0, 40.0):
            diagnostic.failure("io_error", timestamp)
            diagnostic.recovery()
        diagnostic.failure("io_error", 70.0)
        diagnostic.recovery()

        self.assertEqual(
            messages,
            [
                "Statelet session activity sidecar status=degraded reason=io_error",
                "Statelet session activity sidecar status=recovered",
                "Statelet session activity sidecar status=degraded reason=io_error",
                "Statelet session activity sidecar status=recovered",
            ],
        )

    def test_activation_target_diagnostic_recovers_only_after_successful_retry(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary) / "sessions"
            output = state_dir / state.SESSION_ACTIVITY_FILENAME
            identifier = "a" * 24
            snapshot = {"active": [], "completed": []}
            targets = {
                "targets": [{"id": identifier, "thread_id": "thread:private"}]
            }
            publisher = aggregator.SessionActivityPublisher(output, heartbeat=60.0)
            messages = []
            health = aggregator.OptionalActivityDiagnostic(
                messages.append,
                interval=60.0,
                component="activation_targets",
            )
            original_target_write = aggregator.atomic_write_activity_targets
            target_write_attempts = 0

            def fail_once_then_write(*args, **kwargs):
                nonlocal target_write_attempts
                target_write_attempts += 1
                if target_write_attempts == 1:
                    raise OSError("private failure")
                return original_target_write(*args, **kwargs)

            with mock.patch.object(
                aggregator,
                "atomic_write_activity_targets",
                side_effect=fail_once_then_write,
            ):
                first = publisher.publish_if_due(snapshot, 100.0, 10.0, targets)
                health.failure(publisher.last_target_write_status, 10.0)
                self.assertEqual(
                    messages,
                    [
                        "Statelet session activity sidecar component=activation_targets "
                        "status=degraded reason=io_error"
                    ],
                )

                suppressed = publisher.publish_if_due(snapshot, 101.0, 11.0, targets)
                self.assertIsNone(suppressed)
                self.assertEqual(target_write_attempts, 1)
                self.assertIsNone(publisher.last_target_write_status)
                retried = publisher.publish_if_due(snapshot, 160.0, 70.0, targets)
                self.assertEqual(publisher.last_target_write_status, "success")
                health.recovery()

            self.assertIsNotNone(first)
            self.assertIsNotNone(retried)
            self.assertEqual(retried["emitted_at"], 160.0)
            target_record = json.loads(
                output.with_name(
                    state.SESSION_ACTIVITY_TARGETS_FILENAME
                ).read_text(encoding="utf-8")
            )
            self.assertEqual(target_record["emitted_at"], 160.0)
            self.assertEqual(
                messages,
                [
                    "Statelet session activity sidecar component=activation_targets "
                    "status=degraded reason=io_error",
                    "Statelet session activity sidecar component=activation_targets "
                    "status=recovered",
                ],
            )

    def test_activation_target_diagnostic_is_rate_limited(self) -> None:
        messages = []
        diagnostic = aggregator.OptionalActivityDiagnostic(
            messages.append,
            interval=60.0,
            component="activation_targets",
        )

        diagnostic.failure("io_error", 10.0)
        diagnostic.failure("invalid_projection", 20.0)
        diagnostic.failure("encoding_error", 70.0)

        self.assertEqual(
            messages,
            [
                "Statelet session activity sidecar component=activation_targets "
                "status=degraded reason=io_error",
                "Statelet session activity sidecar component=activation_targets "
                "status=degraded reason=encoding_error",
            ],
        )

    def test_session_title_write_failure_retries_recovers_and_is_rate_limited(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "sessions" / state.SESSION_ACTIVITY_FILENAME
            identifier = "a" * 24
            publisher = aggregator.SessionActivityPublisher(output, heartbeat=60.0)
            messages = []
            health = aggregator.OptionalActivityDiagnostic(
                messages.append,
                interval=60.0,
                component="session_titles",
            )
            titles = {"titles": [{"id": identifier, "title": "Private name"}]}
            original_write = aggregator.atomic_write_activity_titles
            attempts = 0

            def fail_once(*args, **kwargs):
                nonlocal attempts
                attempts += 1
                if attempts == 1:
                    raise OSError("/Users/private title write")
                return original_write(*args, **kwargs)

            with mock.patch.object(aggregator, "atomic_write_activity_titles", side_effect=fail_once):
                publisher.publish_if_due({"active": [], "completed": []}, 100.0, 10.0, None, titles)
                health.failure(publisher.last_title_write_status, 10.0)
                health.failure("protocol_error", 20.0)
                suppressed = publisher.publish_if_due(
                    {"active": [], "completed": []},
                    101.0,
                    11.0,
                    None,
                    titles,
                )
                self.assertIsNone(suppressed)
                self.assertEqual(attempts, 1)
                self.assertIsNone(publisher.last_title_write_status)
                retried = publisher.publish_if_due(
                    {"active": [], "completed": []},
                    160.0,
                    70.0,
                    None,
                    titles,
                )
                self.assertEqual(publisher.last_title_write_status, "success")
                health.recovery()

            self.assertIsNotNone(retried)
            self.assertEqual(attempts, 2)
            self.assertEqual(
                messages,
                [
                    "Statelet session activity sidecar component=session_titles status=degraded reason=io_error",
                    "Statelet session activity sidecar component=session_titles status=recovered",
                ],
            )
            self.assertNotIn("/Users/", json.dumps(messages))
            record = json.loads(output.with_name(state.SESSION_ACTIVITY_TITLES_FILENAME).read_text(encoding="utf-8"))
            self.assertEqual(record["emitted_at"], 160.0)

    def test_shared_current_state_fixture_matches_python_publisher(self) -> None:
        fixture_path = ROOT / "mac" / "contracts" / "current_state-v1.example.json"
        fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "runtime" / "current_state.json"
            record = aggregator.atomic_write_state(
                output,
                "running",
                1710000000.0,
                1710000000.25,
                active_sessions=2,
            )
        self.assertEqual(record, fixture)

    def test_atomic_schema_and_permissions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "runtime" / "current_state.json"
            record = aggregator.atomic_write_state(output, "review", 10.5, 12.0)

            self.assertEqual(
                record,
                {
                    "version": 1,
                    "schema_version": 1,
                    "state": "review",
                    "source": "aggregate",
                    "priority": 2,
                    "active_sessions": 0,
                    "updated_at": 12.0,
                    "forced": False,
                    "source_updated_at": 10.5,
                    "emitted_at": 12.0,
                },
            )
            self.assertEqual(json.loads(output.read_text(encoding="utf-8")), record)
            self.assertEqual(record["updated_at"], record["emitted_at"])
            self.assertEqual(stat.S_IMODE(output.parent.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            self.assertEqual(list(output.parent.glob(".current-state-*.json")), [])

    def test_atomic_writer_rejects_invalid_numeric_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "runtime" / "current_state.json"
            with self.assertRaisesRegex(ValueError, "active_sessions"):
                aggregator.atomic_write_state(
                    output, "idle", None, 1.0, active_sessions=-1
                )
            with self.assertRaisesRegex(ValueError, "emitted_at"):
                aggregator.atomic_write_state(output, "idle", None, float("nan"))
            with self.assertRaisesRegex(ValueError, "source_updated_at"):
                aggregator.atomic_write_state(
                    output, "idle", float("inf"), 1.0
                )

    def test_change_writes_immediately_and_heartbeat_suppresses_duplicates(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "current_state.json"
            publisher = aggregator.StatePublisher(output, heartbeat=5.0)

            first = publisher.publish_if_due("idle", None, 100.0, 10.0)
            suppressed = publisher.publish_if_due("idle", None, 101.0, 14.99)
            changed = publisher.publish_if_due("running", 101.5, 101.5, 15.0)
            heartbeat = publisher.publish_if_due("running", 102.0, 106.5, 20.0)

            self.assertIsNotNone(first)
            self.assertIsNone(suppressed)
            self.assertEqual(changed["state"], "running")
            self.assertEqual(heartbeat["source_updated_at"], 102.0)
            self.assertEqual(heartbeat["emitted_at"], 106.5)

    def test_restart_seeds_revision_and_publishes_recovery_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "current_state.json"
            first = aggregator.StatePublisher(output, heartbeat=60.0)
            initial = first.publish_if_due(
                "running",
                99.0,
                100.0,
                10.0,
                active_sessions=1,
                latest_event="UserPromptSubmit",
                latest_event_at=99.0,
            )
            restarted = aggregator.StatePublisher(output, heartbeat=60.0)
            recovered = restarted.publish_if_due(
                "running",
                99.0,
                101.0,
                11.0,
                active_sessions=1,
                latest_event="UserPromptSubmit",
                latest_event_at=99.0,
            )

        self.assertGreater(initial["publication_revision"], 1)
        self.assertTrue(initial["recovery"])
        self.assertGreater(
            recovered["publication_revision"], initial["publication_revision"]
        )
        self.assertTrue(recovered["recovery"])

    def test_same_state_metadata_change_repairs_before_heartbeat(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "current_state.json"
            publisher = aggregator.StatePublisher(output, heartbeat=60.0)
            publisher.publish_if_due(
                "running",
                99.0,
                100.0,
                10.0,
                active_sessions=1,
                latest_event="UserPromptSubmit",
                latest_event_at=99.0,
            )
            repaired = publisher.publish_if_due(
                "running",
                100.0,
                100.1,
                10.1,
                active_sessions=2,
                latest_event="SubagentStart",
                latest_event_at=100.0,
                rejection_diagnostics={"count": 1, "reasons": {"stale_event": 1}},
            )

        self.assertIsNotNone(repaired)
        self.assertEqual(repaired["active_sessions"], 2)
        self.assertEqual(repaired["latest_event"], "SubagentStart")
        self.assertEqual(repaired["rejection_diagnostics"]["count"], 1)
        self.assertFalse(repaired["recovery"])

    def test_publication_canonicalizes_private_diagnostics(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "current_state.json"
            publisher = aggregator.StatePublisher(output, heartbeat=60.0)
            published = publisher.publish_if_due(
                "running",
                99.0,
                100.0,
                10.0,
                latest_event="prompt:/Users/private/repository",
                latest_event_at=99.0,
                rejection_diagnostics={
                    "count": 999,
                    "reasons": {
                        "stale_event": 2,
                        "/Users/private/repository": 500,
                        "prompt contents": 700,
                    },
                },
            )

        encoded = json.dumps(published)
        self.assertEqual(published["latest_event"], "unknown")
        self.assertEqual(
            published["rejection_diagnostics"],
            {"count": 2, "reasons": {"stale_event": 2}},
        )
        self.assertNotIn("/Users/private", encoded)
        self.assertNotIn("prompt contents", encoded)

    def test_missing_or_corrupt_output_uses_wall_clock_revision_floor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "current_state.json"
            with mock.patch.object(aggregator.time, "time", return_value=1234.5):
                missing = aggregator.StatePublisher(output, heartbeat=60.0)
            output.write_text("{corrupt", encoding="utf-8")
            with mock.patch.object(aggregator.time, "time", return_value=1234.6):
                corrupt = aggregator.StatePublisher(output, heartbeat=60.0)

        self.assertGreaterEqual(missing.publication_revision, 1_234_500_000)
        self.assertGreater(corrupt.publication_revision, missing.publication_revision)

    def test_revision_sidecar_survives_output_corruption_and_clock_rollback(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "current_state.json"
            with mock.patch.object(aggregator.time, "time", return_value=2000.0):
                publisher = aggregator.StatePublisher(output, heartbeat=60.0)
            published = publisher.publish_if_due("running", 1.0, 2.0, 3.0)
            output.write_text("{corrupt", encoding="utf-8")

            with mock.patch.object(aggregator.time, "time", return_value=1000.0):
                restarted = aggregator.StatePublisher(output, heartbeat=60.0)

        self.assertGreaterEqual(
            restarted.publication_revision,
            published["publication_revision"],
        )

    def test_oversized_revision_sources_are_ignored_for_automatic_recovery(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "current_state.json"
            output.write_text(json.dumps({
                "version": 1,
                "schema_version": 1,
                "state": "running",
                "source": "aggregate",
                "publication_revision": 1 << 100,
            }), encoding="utf-8")
            output.with_name(output.name + aggregator.REVISION_SIDECAR_SUFFIX).write_text(
                str(1 << 100), encoding="ascii"
            )
            with mock.patch.object(aggregator.time, "time", return_value=1234.5):
                publisher = aggregator.StatePublisher(output, heartbeat=60.0)

        self.assertEqual(publisher.publication_revision, 1_234_500_000)

    def test_force_state_expires_back_to_aggregate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            write_record(record_path(directory, "a"), "running", 99.0)

            self.assertTrue(
                aggregator.force_is_active("waiting", False, 101.0, 100.0)
            )
            forced = aggregator.resolve_state_snapshot(
                directory,
                active_ttl=900.0,
                wall_time=100.0,
                forced_state="waiting",
                force_source_updated_at=99.5,
            )
            self.assertFalse(
                aggregator.force_is_active("waiting", False, 101.0, 101.0)
            )
            expired = aggregator.resolve_state_snapshot(
                directory,
                active_ttl=900.0,
                wall_time=101.0,
            )

            self.assertEqual(forced, ("waiting", 99.5, 0))
            self.assertEqual(expired, ("running", 99.0, 1))

    def test_event_wake_publishes_state_change_without_poll_delay(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sessions = root / "sessions"
            sessions.mkdir()
            output = root / "current_state.json"
            clock = FakeClock()

            def create_session(_timeout: float) -> None:
                clock.advance(0.05)
                write_record(record_path(sessions, "a"), "running", clock.wall())

            waiter = ScriptedWaiter(clock, [create_session, lambda _timeout: None])
            aggregator.run(
                sessions,
                output,
                poll=0.25,
                heartbeat=60.0,
                active_ttl=900.0,
                once=False,
                print_state=False,
                forced_state=None,
                force_seconds=30.0,
                should_stop=lambda: waiter.wait_count >= 2,
                waiter=waiter,
                wall_clock=clock.wall,
                monotonic_clock=clock.monotonic,
            )

            self.assertEqual(json.loads(output.read_text())["state"], "running")
            self.assertEqual(waiter.timeouts[0], 60.0)
            self.assertEqual(waiter.prepare_count, 2)
            self.assertLess(clock.wall_time, 101.0)

    def test_deadline_wakes_for_heartbeat_and_session_ttl(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sessions = root / "sessions"
            sessions.mkdir()
            output = root / "current_state.json"
            clock = FakeClock()
            write_record(record_path(sessions, "a"), "running", 99.0)
            waiter = ScriptedWaiter(clock)

            aggregator.run(
                sessions,
                output,
                poll=0.25,
                heartbeat=60.0,
                active_ttl=2.0,
                once=False,
                print_state=False,
                forced_state=None,
                force_seconds=30.0,
                should_stop=lambda: waiter.wait_count >= 2,
                waiter=waiter,
                wall_clock=clock.wall,
                monotonic_clock=clock.monotonic,
            )

            self.assertAlmostEqual(waiter.timeouts[0], 1.001, places=6)
            self.assertEqual(json.loads(output.read_text())["state"], "idle")
            self.assertFalse(record_path(sessions, "a").exists())

    def test_deadline_wakes_for_quiescent_tool_session(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sessions = root / "sessions"
            sessions.mkdir()
            output = root / "current_state.json"
            clock = FakeClock()
            write_v2_record(
                record_path(sessions, "a"),
                "running",
                "PostToolUse",
                99.0,
            )
            waiter = ScriptedWaiter(clock)

            aggregator.run(
                sessions,
                output,
                poll=0.25,
                heartbeat=60.0,
                active_ttl=state.DEFAULT_ACTIVE_TTL,
                once=False,
                print_state=False,
                forced_state=None,
                force_seconds=30.0,
                should_stop=lambda: waiter.wait_count >= 2,
                waiter=waiter,
                wall_clock=clock.wall,
                monotonic_clock=clock.monotonic,
            )

            self.assertAlmostEqual(
                waiter.timeouts[0],
                state.DEFAULT_QUIESCENT_TTL - 1.0 + aggregator.TTL_DEADLINE_EPSILON,
                places=6,
            )
            self.assertEqual(json.loads(output.read_text())["state"], "idle")
            self.assertFalse(record_path(sessions, "a").exists())

    def test_heartbeat_deadline_wakes_without_events(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sessions = root / "sessions"
            sessions.mkdir()
            output = root / "current_state.json"
            clock = FakeClock()
            waiter = ScriptedWaiter(clock)

            aggregator.run(
                sessions,
                output,
                poll=0.25,
                heartbeat=5.0,
                active_ttl=900.0,
                once=False,
                print_state=False,
                forced_state=None,
                force_seconds=30.0,
                should_stop=lambda: waiter.wait_count >= 2,
                waiter=waiter,
                wall_clock=clock.wall,
                monotonic_clock=clock.monotonic,
            )

            self.assertEqual(waiter.timeouts[0], 5.0)
            persisted = json.loads(output.read_text())
            self.assertEqual(persisted["state"], "idle")
            self.assertEqual(persisted["emitted_at"], 105.0)

    def test_force_deadline_wakes_without_directory_event(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sessions = root / "sessions"
            sessions.mkdir()
            output = root / "current_state.json"
            clock = FakeClock()
            write_record(record_path(sessions, "a"), "running", 99.0)
            waiter = ScriptedWaiter(clock)

            aggregator.run(
                sessions,
                output,
                poll=0.25,
                heartbeat=60.0,
                active_ttl=900.0,
                once=False,
                print_state=False,
                forced_state="review",
                force_seconds=2.0,
                should_stop=lambda: waiter.wait_count >= 2,
                waiter=waiter,
                wall_clock=clock.wall,
                monotonic_clock=clock.monotonic,
            )

            self.assertEqual(waiter.timeouts[0], 2.0)
            persisted = json.loads(output.read_text())
            self.assertEqual(persisted["state"], "running")
            self.assertFalse(persisted["forced"])

    def test_force_expiry_republishes_when_aggregate_state_is_the_same(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sessions = root / "sessions"
            sessions.mkdir()
            output = root / "current_state.json"
            clock = FakeClock()
            write_record(record_path(sessions, "a"), "review", 99.0)
            waiter = ScriptedWaiter(clock)

            aggregator.run(
                sessions,
                output,
                poll=0.25,
                heartbeat=60.0,
                active_ttl=900.0,
                once=False,
                print_state=False,
                forced_state="review",
                force_seconds=2.0,
                should_stop=lambda: waiter.wait_count >= 2,
                waiter=waiter,
                wall_clock=clock.wall,
                monotonic_clock=clock.monotonic,
            )

            persisted = json.loads(output.read_text())
            self.assertEqual(persisted["state"], "review")
            self.assertFalse(persisted["forced"])

    def test_stop_after_wake_does_not_rescan(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sessions = root / "sessions"
            sessions.mkdir()
            output = root / "current_state.json"
            clock = FakeClock()
            stopped = [False]

            def stop_after_change(_timeout: float) -> None:
                write_record(record_path(sessions, "a"), "running", clock.wall())
                stopped[0] = True

            waiter = ScriptedWaiter(clock, [stop_after_change])
            aggregator.run(
                sessions,
                output,
                poll=0.25,
                heartbeat=60.0,
                active_ttl=900.0,
                once=False,
                print_state=False,
                forced_state=None,
                force_seconds=30.0,
                should_stop=lambda: stopped[0],
                waiter=waiter,
                wall_clock=clock.wall,
                monotonic_clock=clock.monotonic,
            )

            self.assertEqual(json.loads(output.read_text())["state"], "idle")

    def test_waiter_fallback_is_bounded_by_poll_interval(self) -> None:
        slept = []
        diagnostics = []
        waiter = aggregator.DirectoryEventWaiter(
            Path("/definitely/missing/statelet/session-directory"),
            poll_interval=0.25,
            sleep=slept.append,
            diagnostic=lambda mode, reason: diagnostics.append((mode, reason)),
        )
        try:
            waiter._disable_kqueue()
            waiter.wait(60.0)
            waiter.wait(60.0)
        finally:
            waiter.close()
        self.assertEqual(slept, [0.25, 0.25])
        expected_reason = (
            "open_failed"
            if hasattr(select, "kqueue")
            else "unsupported"
        )
        self.assertEqual(
            diagnostics,
            [(aggregator.POLL_FALLBACK_MODE, expected_reason)],
        )

    def test_waiter_does_not_follow_a_symlinked_session_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            real_sessions = root / "real-sessions"
            real_sessions.mkdir()
            linked_sessions = root / "sessions"
            linked_sessions.symlink_to(real_sessions, target_is_directory=True)
            slept = []
            waiter = aggregator.DirectoryEventWaiter(
                linked_sessions,
                poll_interval=0.25,
                sleep=slept.append,
            )
            try:
                self.assertFalse(waiter.event_driven)
                waiter.wait(60.0)
            finally:
                waiter.close()
            self.assertEqual(slept, [0.25])

    def test_mode_diagnostic_is_path_free_and_rejects_unknown_reasons(self) -> None:
        self.assertEqual(
            aggregator.FALLBACK_REASONS,
            frozenset(
                (
                    "unsupported",
                    "open_failed",
                    "registration_failed",
                    "wait_failed",
                )
            ),
        )
        script = """
import sys
sys.path.insert(0, {!r})
from codex_pet_state_aggregator import print_mode_diagnostic
print_mode_diagnostic('event_driven', None)
print_mode_diagnostic('poll_fallback', 'wait_failed')
""".format(str(MAC_DIR))
        result = subprocess.run(
            [sys.executable, "-c", script],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stderr.splitlines(),
            [
                "Statelet state aggregator mode=event_driven",
                "Statelet state aggregator mode=poll_fallback reason=wait_failed",
            ],
        )
        with self.assertRaisesRegex(ValueError, "invalid"):
            aggregator.print_mode_diagnostic("poll_fallback", "/private/path")

    def test_single_instance_lock_is_non_blocking(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            lock_path = Path(temporary) / "runtime" / ".state-aggregator.lock"
            with aggregator.InstanceLock(lock_path):
                with self.assertRaisesRegex(RuntimeError, "another .* is running"):
                    with aggregator.InstanceLock(lock_path):
                        self.fail("a second lock unexpectedly succeeded")

    def test_aggregator_import_does_not_require_pyserial(self) -> None:
        script = """
import builtins
import sys
real_import = builtins.__import__
def guarded(name, *args, **kwargs):
    if name == 'serial' or name.startswith('serial.'):
        raise AssertionError('pyserial import attempted')
    return real_import(name, *args, **kwargs)
builtins.__import__ = guarded
sys.path.insert(0, {!r})
import codex_pet_state_aggregator
""".format(str(MAC_DIR))
        result = subprocess.run(
            [sys.executable, "-c", script],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_once_force_is_one_shot_and_printable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "runtime" / "current_state.json"
            result = subprocess.run(
                [
                    sys.executable,
                    str(MAC_DIR / "codex_pet_state_aggregator.py"),
                    "--state-dir",
                    str(root / "sessions"),
                    "--output",
                    str(output),
                    "--once",
                    "--print-state",
                    "--force-state",
                    "review",
                ],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "review")
            expected_reason = (
                "open_failed"
                if hasattr(select, "kqueue")
                else "unsupported"
            )
            self.assertEqual(
                result.stderr.strip(),
                "Statelet state aggregator mode=poll_fallback reason={}".format(
                    expected_reason
                ),
            )
            self.assertNotIn(temporary, result.stderr)
            persisted = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(persisted["state"], "review")
            self.assertTrue(persisted["forced"])
            self.assertLessEqual(
                persisted["source_updated_at"], persisted["emitted_at"]
            )


@unittest.skipUnless(
    hasattr(select, "kqueue") and hasattr(select, "KQ_FILTER_VNODE"),
    "Darwin kqueue is unavailable",
)
class DarwinDirectoryEventWaiterTests(unittest.TestCase):
    def test_mode_diagnostic_reports_failure_again_after_recovery(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sessions = root / "sessions"
            diagnostics = []
            waiter = aggregator.DirectoryEventWaiter(
                sessions,
                poll_interval=0.25,
                diagnostic=lambda mode, reason: diagnostics.append((mode, reason)),
            )
            self.assertFalse(waiter.event_driven)

            sessions.mkdir()
            self.assertTrue(waiter.prepare())
            sessions.rename(root / "old-sessions")
            waiter.wait(2.0)
            self.assertFalse(waiter.event_driven)
            self.assertFalse(waiter.prepare())
            waiter.close()

            self.assertEqual(
                diagnostics,
                [
                    (aggregator.POLL_FALLBACK_MODE, "open_failed"),
                    (aggregator.EVENT_DRIVEN_MODE, None),
                    (aggregator.POLL_FALLBACK_MODE, "open_failed"),
                ],
            )

    def test_atomic_directory_update_wakes_kqueue(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sessions = Path(temporary) / "sessions"
            sessions.mkdir()
            diagnostics = []
            waiter = aggregator.DirectoryEventWaiter(
                sessions,
                poll_interval=0.25,
                diagnostic=lambda mode, reason: diagnostics.append((mode, reason)),
            )
            self.assertTrue(waiter.event_driven)

            def replace_record() -> None:
                time.sleep(0.05)
                temporary_record = sessions / ".record.tmp"
                temporary_record.write_text("{}", encoding="utf-8")
                os.replace(temporary_record, record_path(sessions, "c"))

            writer = threading.Thread(target=replace_record)
            writer.start()
            started = time.monotonic()
            try:
                waiter.wait(2.0)
            finally:
                waiter.close()
                writer.join()

            self.assertLess(time.monotonic() - started, 1.0)
            self.assertTrue(record_path(sessions, "c").exists())
            self.assertEqual(
                diagnostics,
                [(aggregator.EVENT_DRIVEN_MODE, None)],
            )

    def test_directory_rename_then_rewatch_wakes_for_new_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sessions = root / "sessions"
            sessions.mkdir()
            waiter = aggregator.DirectoryEventWaiter(sessions, poll_interval=0.25)
            self.assertTrue(waiter.event_driven)

            sessions.rename(root / "old-sessions")
            waiter.wait(2.0)
            self.assertFalse(waiter.event_driven)
            sessions.mkdir()

            # The watch is re-established before the next scan. A write in the
            # former scan-to-wait gap must therefore queue a vnode event.
            self.assertTrue(waiter.prepare())
            temporary_record = sessions / ".record.tmp"
            temporary_record.write_text("{}", encoding="utf-8")
            os.replace(temporary_record, record_path(sessions, "d"))
            started = time.monotonic()
            try:
                waiter.wait(2.0)
            finally:
                waiter.close()

            self.assertLess(time.monotonic() - started, 1.0)
            self.assertTrue(record_path(sessions, "d").exists())

    def test_late_directory_registration_returns_for_immediate_rescan(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sessions = Path(temporary) / "sessions"
            slept = []
            waiter = aggregator.DirectoryEventWaiter(
                sessions,
                poll_interval=0.25,
                sleep=slept.append,
            )
            self.assertFalse(waiter.prepare())

            # Simulate the directory and its first record appearing after the
            # scan but before wait(). Newly arming must not block afterward.
            sessions.mkdir()
            write_record(record_path(sessions, "e"), "running", time.time())
            started = time.monotonic()
            try:
                waiter.wait(2.0)
            finally:
                waiter.close()

            self.assertLess(time.monotonic() - started, 0.5)
            self.assertEqual(slept, [])
            self.assertTrue(record_path(sessions, "e").exists())

    def test_wake_interrupts_kqueue_wait(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sessions = Path(temporary) / "sessions"
            sessions.mkdir()
            waiter = aggregator.DirectoryEventWaiter(sessions, poll_interval=0.25)

            def wake_waiter() -> None:
                time.sleep(0.05)
                waiter.wake()

            waker = threading.Thread(target=wake_waiter)
            waker.start()
            started = time.monotonic()
            try:
                waiter.wait(2.0)
            finally:
                waiter.close()
                waker.join()

            self.assertLess(time.monotonic() - started, 1.0)

    def test_wait_failure_transitions_once_to_bounded_poll_fallback(self) -> None:
        class FailingKqueue:
            def control(self, _changes, _max_events, _timeout):
                raise OSError("synthetic wait failure")

            def close(self):
                pass

        with tempfile.TemporaryDirectory() as temporary:
            sessions = Path(temporary) / "sessions"
            sessions.mkdir()
            diagnostics = []
            slept = []
            waiter = aggregator.DirectoryEventWaiter(
                sessions,
                poll_interval=0.25,
                sleep=slept.append,
                diagnostic=lambda mode, reason: diagnostics.append((mode, reason)),
            )
            real_kqueue = waiter._kqueue
            waiter._kqueue = FailingKqueue()
            try:
                waiter.wait(60.0)
                waiter.wait(60.0)
            finally:
                waiter.close()
                real_kqueue.close()

            self.assertEqual(slept, [0.25, 0.25])
            self.assertEqual(
                diagnostics,
                [
                    (aggregator.EVENT_DRIVEN_MODE, None),
                    (aggregator.POLL_FALLBACK_MODE, "wait_failed"),
                ],
            )

if __name__ == "__main__":
    unittest.main()
