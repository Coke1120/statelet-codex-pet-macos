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
                "rejections": rejections or {},
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
