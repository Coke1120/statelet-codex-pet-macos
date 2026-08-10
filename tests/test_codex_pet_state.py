#!/usr/bin/env python3
"""Tests for the board-independent Statelet lifecycle publisher."""

import json
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


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


class LifecycleStateTests(unittest.TestCase):
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
            persisted = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(persisted["state"], "review")
            self.assertTrue(persisted["forced"])
            self.assertLessEqual(
                persisted["source_updated_at"], persisted["emitted_at"]
            )


if __name__ == "__main__":
    unittest.main()
