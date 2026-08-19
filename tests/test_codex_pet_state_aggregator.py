#!/usr/bin/env python3
"""Focused concurrency regressions for the Statelet lifecycle aggregator."""

import json
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


def write_session(path: Path, lifecycle: str, event: str) -> None:
    path.write_text(
        json.dumps(
            {
                "version": 2,
                "state": lifecycle,
                "event": event,
                "event_at": 100.0,
                "updated_at": 100.0,
                "terminal": False,
                "completed_at": None,
                "rejections": {},
            }
        ),
        encoding="utf-8",
    )


def write_target(path: Path, identifier: str, thread_id: str) -> None:
    path.write_text(
        json.dumps(
            {
                "version": 1,
                "id": identifier,
                "thread_id": thread_id,
                "updated_at": 100.0,
            }
        ),
        encoding="utf-8",
    )


def wait_until(predicate, timeout: float = 2.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise AssertionError("condition was not satisfied before timeout")


class EventWaiter:
    def __init__(self) -> None:
        self.event = threading.Event()

    def prepare(self) -> bool:
        return True

    def wait(self, timeout: float) -> None:
        self.event.wait(min(timeout, 0.1))
        self.event.clear()

    def wake(self) -> None:
        self.event.set()

    def close(self) -> None:
        pass


class BlockingResolver:
    def __init__(self) -> None:
        self.started = threading.Event()
        self.release = threading.Event()
        self.finished = threading.Event()

    def resolve(self, thread_ids, monotonic_time=None):
        del thread_ids, monotonic_time
        self.started.set()
        self.release.wait()
        self.finished.set()
        return ({}, None)

    def close(self) -> None:
        self.release.set()

    def force_close(self) -> None:
        self.release.set()


class AggregatorTitleConcurrencyTests(unittest.TestCase):
    def test_refresh_deadline_uses_completion_time_and_preempts_heartbeat(self) -> None:
        resolver = BlockingResolver()
        waiter = EventWaiter()
        now = [10.0]
        resolution = aggregator.AsyncTitleResolution(
            resolver,
            waiter.wake,
            clock=lambda: now[0],
        )
        snapshot = {
            "targets": [{"id": "a" * 24, "thread_id": "thread:one"}]
        }

        titles, failure, pending = resolution.request(snapshot, now[0])
        self.assertEqual((titles, failure, pending), ({"titles": []}, None, True))
        self.assertTrue(resolver.started.wait(1.0))
        now[0] = 25.0
        resolver.release.set()
        self.assertTrue(waiter.event.wait(1.0))
        self.assertEqual(resolution.next_refresh_deadline(), 85.0)

        publisher = mock.Mock(next_heartbeat_at=325.0)
        self.assertEqual(
            aggregator.next_wake_timeout(
                publisher,
                wall_time=100.0,
                monotonic_time=25.0,
                force_deadline=None,
                source_expiry_at=None,
                title_refresh_at=resolution.next_refresh_deadline(),
            ),
            60.0,
        )
        resolution.close()
        self.assertFalse(resolution.worker.is_alive())

    def test_successful_empty_resolution_recovers_independent_health(self) -> None:
        messages = []
        health = aggregator.OptionalActivityDiagnostic(
            messages.append,
            component="session_titles",
        )
        resolution_failure = "timeout"
        write_failure = None
        health.failure(
            aggregator.title_projection_failure(
                resolution_failure,
                write_failure,
            ),
            10.0,
        )

        resolution_failure = None
        combined = aggregator.title_projection_failure(
            resolution_failure,
            write_failure,
        )
        self.assertIsNone(combined)
        health.recovery()

        self.assertEqual(
            messages,
            [
                "Statelet session activity sidecar component=session_titles "
                "status=degraded reason=timeout",
                "Statelet session activity sidecar component=session_titles "
                "status=recovered",
            ],
        )

    def test_blocking_resolver_cannot_block_lifecycle_updates_or_shutdown(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            state_dir = root / "sessions"
            output = root / "runtime" / "current_state.json"
            state_dir.mkdir()
            session_path = state_dir / (("a" * 24) + ".json")
            identifier = "a" * 24
            write_session(session_path, "running", "UserPromptSubmit")
            write_target(
                state_dir / (identifier + ".target.json"),
                identifier,
                "thread:blocked",
            )
            resolver = BlockingResolver()
            waiter = EventWaiter()
            stop = threading.Event()
            run_thread = threading.Thread(
                target=aggregator.run,
                args=(
                    state_dir,
                    output,
                    0.01,
                    60.0,
                    900.0,
                    False,
                    False,
                    None,
                    30.0,
                    stop.is_set,
                ),
                kwargs={
                    "waiter": waiter,
                    "wall_clock": lambda: 100.0,
                    "title_resolver": resolver,
                },
            )
            run_thread.start()
            self.assertTrue(resolver.started.wait(1.0))

            write_session(session_path, "waiting", "PermissionRequest")
            waiter.wake()
            wait_until(
                lambda: output.exists()
                and json.loads(output.read_text(encoding="utf-8"))["state"]
                == "waiting"
            )

            stop.set()
            waiter.wake()
            run_thread.join(1.0)
            self.assertFalse(run_thread.is_alive())
            self.assertTrue(resolver.release.is_set())
            self.assertTrue(resolver.finished.wait(0.5))

    def test_stale_title_result_cannot_overwrite_latest_target(self) -> None:
        class Resolver:
            def __init__(self) -> None:
                self.calls = []
                self.old_started = threading.Event()
                self.release_old = threading.Event()

            def resolve(self, thread_ids, monotonic_time=None):
                del monotonic_time
                thread_id = thread_ids[0]
                self.calls.append(thread_id)
                if thread_id == "thread:old":
                    self.old_started.set()
                    self.release_old.wait()
                    return ({thread_id: "Old title"}, None)
                return ({thread_id: "New title"}, None)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            state_dir = root / "sessions"
            output = root / "runtime" / "current_state.json"
            state_dir.mkdir()
            identifier = "b" * 24
            write_session(
                state_dir / (("b" * 24) + ".json"),
                "running",
                "UserPromptSubmit",
            )
            target_path = state_dir / (identifier + ".target.json")
            write_target(target_path, identifier, "thread:old")
            resolver = Resolver()
            waiter = EventWaiter()
            stop = threading.Event()
            written_title_snapshots = []
            original_write = aggregator.atomic_write_activity_titles

            def capture_write(path, snapshot, emitted_at):
                written_title_snapshots.append(snapshot)
                return original_write(path, snapshot, emitted_at)

            with mock.patch.object(
                aggregator,
                "atomic_write_activity_titles",
                side_effect=capture_write,
            ):
                run_thread = threading.Thread(
                    target=aggregator.run,
                    args=(
                        state_dir,
                        output,
                        0.01,
                        60.0,
                        900.0,
                        False,
                        False,
                        None,
                        30.0,
                        stop.is_set,
                    ),
                    kwargs={
                        "waiter": waiter,
                        "wall_clock": lambda: 100.0,
                        "title_resolver": resolver,
                    },
                )
                run_thread.start()
                self.assertTrue(resolver.old_started.wait(1.0))

                write_target(target_path, identifier, "thread:new")
                waiter.wake()
                targets_path = state_dir / state.SESSION_ACTIVITY_TARGETS_FILENAME
                wait_until(
                    lambda: targets_path.exists()
                    and json.loads(targets_path.read_text(encoding="utf-8"))[
                        "targets"
                    ][0]["thread_id"]
                    == "thread:new"
                )
                resolver.release_old.set()

                titles_path = state_dir / state.SESSION_ACTIVITY_TITLES_FILENAME
                wait_until(
                    lambda: titles_path.exists()
                    and json.loads(titles_path.read_text(encoding="utf-8"))[
                        "titles"
                    ]
                    == [{"id": identifier, "title": "New title"}]
                )
                stop.set()
                waiter.wake()
                run_thread.join(1.0)

            self.assertFalse(run_thread.is_alive())
            self.assertEqual(resolver.calls, ["thread:old", "thread:new"])
            self.assertNotIn(
                {"titles": [{"id": identifier, "title": "Old title"}]},
                written_title_snapshots,
            )


if __name__ == "__main__":
    unittest.main()
