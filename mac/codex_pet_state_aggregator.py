#!/usr/bin/env python3
"""Publish board-independent Codex lifecycle state for the macOS player."""

import argparse
import fcntl
import json
import math
import os
import signal
import sys
import tempfile
import time
from pathlib import Path
from typing import Callable, Dict, Optional, TextIO, Tuple

MAC_DIR = Path(__file__).resolve().parent
if str(MAC_DIR) not in sys.path:
    sys.path.insert(0, str(MAC_DIR))

from codex_pet_state import (  # noqa: E402
    DEFAULT_ACTIVE_TTL,
    STATE_PRIORITY,
    VALID_STATES,
    aggregate_state_with_source,
    default_state_dir,
    read_active_states,
)


SCHEMA_VERSION = 1
DEFAULT_OUTPUT_PATH = (
    Path.home()
    / "Library"
    / "Application Support"
    / "CodexPet"
    / "runtime"
    / "current_state.json"
)
DEFAULT_POLL_INTERVAL = 0.25
# State changes still publish immediately.  The heartbeat exists only to make
# writer liveness observable, so keep it low-frequency to avoid needless SSD
# churn while an idle companion runs all day.
DEFAULT_HEARTBEAT_INTERVAL = 60.0
DEFAULT_FORCE_DURATION = 30.0
MAX_FORCE_DURATION = 300.0


def positive_float(raw: str) -> float:
    value = float(raw)
    if not math.isfinite(value) or value <= 0:
        raise argparse.ArgumentTypeError("expected a positive finite number")
    return value


def force_duration(raw: str) -> float:
    value = positive_float(raw)
    if value > MAX_FORCE_DURATION:
        raise argparse.ArgumentTypeError(
            "force duration must not exceed {} seconds".format(MAX_FORCE_DURATION)
        )
    return value


def atomic_write_state(
    output_path: Path,
    state: str,
    source_updated_at: Optional[float],
    emitted_at: float,
    active_sessions: int = 0,
    forced: bool = False,
) -> Dict[str, object]:
    """Atomically publish a small state record with private permissions."""
    if state not in VALID_STATES:
        raise ValueError("invalid state: {}".format(state))
    if active_sessions < 0:
        raise ValueError("active_sessions must not be negative")
    if not math.isfinite(emitted_at):
        raise ValueError("emitted_at must be finite")
    if source_updated_at is not None and not math.isfinite(source_updated_at):
        raise ValueError("source_updated_at must be finite when present")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.parent.chmod(0o700)
    record: Dict[str, object] = {
        "version": SCHEMA_VERSION,
        "schema_version": SCHEMA_VERSION,
        "state": state,
        "source": "aggregate",
        "priority": STATE_PRIORITY[state],
        "active_sessions": active_sessions,
        # Keep the v1 player's original freshness field while exposing the
        # source and publication clocks independently.
        "updated_at": emitted_at,
        "forced": forced,
        "source_updated_at": source_updated_at,
        "emitted_at": emitted_at,
    }
    fd, temporary = tempfile.mkstemp(
        prefix=".current-state-", suffix=".json", dir=str(output_path.parent)
    )
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            fd = -1
            json.dump(record, handle, separators=(",", ":"), sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, output_path)
        output_path.chmod(0o600)
        directory_fd = os.open(output_path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if fd >= 0:
            try:
                os.close(fd)
            except OSError:
                pass
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
    return record


class StatePublisher:
    """Suppress unchanged writes until the heartbeat becomes due."""

    def __init__(self, output_path: Path, heartbeat: float) -> None:
        self.output_path = output_path
        self.heartbeat = heartbeat
        self.last_state: Optional[str] = None
        self.next_heartbeat_at = 0.0

    def publish_if_due(
        self,
        state: str,
        source_updated_at: Optional[float],
        wall_time: float,
        monotonic_time: float,
        active_sessions: int = 0,
        forced: bool = False,
    ) -> Optional[Dict[str, object]]:
        if state == self.last_state and monotonic_time < self.next_heartbeat_at:
            return None
        record = atomic_write_state(
            self.output_path,
            state,
            source_updated_at,
            wall_time,
            active_sessions,
            forced,
        )
        self.last_state = state
        self.next_heartbeat_at = monotonic_time + self.heartbeat
        return record


class InstanceLock:
    """Non-blocking process lock held for the aggregator lifetime."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.handle: Optional[TextIO] = None

    def __enter__(self) -> "InstanceLock":
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.parent.chmod(0o700)
        self.handle = self.path.open("a+", encoding="utf-8")
        os.chmod(self.path, 0o600)
        try:
            fcntl.flock(self.handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            self.handle.close()
            self.handle = None
            raise RuntimeError("another Codex Pet state aggregator is running") from exc
        return self

    def __exit__(self, _type, _value, _traceback) -> None:
        if self.handle is not None:
            fcntl.flock(self.handle.fileno(), fcntl.LOCK_UN)
            self.handle.close()
            self.handle = None


def force_is_active(
    forced_state: Optional[str],
    once: bool,
    force_deadline: Optional[float],
    monotonic_time: float,
) -> bool:
    return forced_state is not None and (
        once or (force_deadline is not None and monotonic_time < force_deadline)
    )


def resolve_state_snapshot(
    state_dir: Path,
    active_ttl: float,
    wall_time: float,
    forced_state: Optional[str] = None,
    force_source_updated_at: Optional[float] = None,
) -> Tuple[str, Optional[float], int]:
    if forced_state is not None:
        source_updated_at = (
            wall_time
            if force_source_updated_at is None
            else force_source_updated_at
        )
        return (forced_state, source_updated_at, 0)
    active = read_active_states(state_dir, now=wall_time, active_ttl=active_ttl)
    lifecycle, source_updated_at = aggregate_state_with_source(active)
    return (lifecycle, source_updated_at, len(active))


def run(
    state_dir: Path,
    output_path: Path,
    poll: float,
    heartbeat: float,
    active_ttl: float,
    once: bool,
    print_state: bool,
    forced_state: Optional[str],
    force_seconds: float,
    should_stop: Callable[[], bool],
) -> int:
    publisher = StatePublisher(output_path, heartbeat)
    force_started_at = time.time() if forced_state is not None else None
    force_deadline = (
        time.monotonic() + force_seconds
        if forced_state is not None and not once
        else None
    )
    while not should_stop():
        wall_time = time.time()
        monotonic_time = time.monotonic()
        forced = force_is_active(
            forced_state, once, force_deadline, monotonic_time
        )
        state, source_updated_at, active_sessions = resolve_state_snapshot(
            state_dir,
            active_ttl,
            wall_time,
            forced_state if forced else None,
            force_started_at,
        )
        record = publisher.publish_if_due(
            state,
            source_updated_at,
            wall_time,
            monotonic_time,
            active_sessions,
            forced,
        )
        if record is not None and print_state:
            print(state, flush=True)
        if once:
            break
        time.sleep(poll)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Publish Codex lifecycle state without requiring a board or pyserial."
    )
    parser.add_argument("--state-dir", type=Path, default=default_state_dir())
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT_PATH)
    parser.add_argument("--poll", type=positive_float, default=DEFAULT_POLL_INTERVAL)
    parser.add_argument(
        "--heartbeat", type=positive_float, default=DEFAULT_HEARTBEAT_INTERVAL
    )
    parser.add_argument("--active-ttl", type=positive_float, default=DEFAULT_ACTIVE_TTL)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--print-state", action="store_true")
    parser.add_argument("--force-state", choices=VALID_STATES)
    parser.add_argument(
        "--force-seconds",
        type=force_duration,
        default=DEFAULT_FORCE_DURATION,
        help=(
            "temporary override duration (maximum {} seconds); with --once the "
            "override applies only to that single write"
        ).format(int(MAX_FORCE_DURATION)),
    )
    args = parser.parse_args()

    stopped = False

    def request_stop(_signum, _frame) -> None:
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)

    lock_path = args.output.parent / ".state-aggregator.lock"
    try:
        with InstanceLock(lock_path):
            return run(
                args.state_dir,
                args.output,
                args.poll,
                args.heartbeat,
                args.active_ttl,
                args.once,
                args.print_state,
                args.force_state,
                args.force_seconds,
                lambda: stopped,
            )
    except (OSError, RuntimeError) as exc:
        print("Codex Pet state aggregator error: {}".format(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
