#!/usr/bin/env python3
"""Publish board-independent Codex lifecycle state for the macOS player."""

import argparse
import fcntl
import json
import math
import os
import select
import signal
import sys
import tempfile
import time
from pathlib import Path
from typing import Callable, Dict, Optional, TextIO, Tuple

MAC_DIR = Path(__file__).resolve().parent
if str(MAC_DIR) not in sys.path:
    sys.path.insert(0, str(MAC_DIR))

try:
    from statelet_state import (  # type: ignore[import-not-found]  # noqa: E402
        DEFAULT_ACTIVE_TTL,
        STATE_PRIORITY,
        VALID_STATES,
        aggregate_state_with_source,
        default_state_dir,
        read_active_states,
    )
except ModuleNotFoundError as error:
    if error.name != "statelet_state":
        raise
    # Repository/source compatibility. Installed Statelet components use the
    # canonical module name above.
    from codex_pet_state import (  # noqa: E402
        DEFAULT_ACTIVE_TTL,
        STATE_PRIORITY,
        VALID_STATES,
        aggregate_state_with_source,
        default_state_dir,
        read_active_states,
    )


DEFAULT_OUTPUT_PATH = (
    Path.home()
    / "Library"
    / "Application Support"
    / "Statelet"
    / "runtime"
    / "current_state.json"
)
SCHEMA_VERSION = 1
DEFAULT_POLL_INTERVAL = 0.25
# State changes still publish immediately.  The heartbeat exists only to make
# writer liveness observable, so keep it low-frequency to avoid needless SSD
# churn while an idle companion runs all day.
DEFAULT_HEARTBEAT_INTERVAL = 60.0
DEFAULT_FORCE_DURATION = 30.0
MAX_FORCE_DURATION = 300.0
TTL_DEADLINE_EPSILON = 0.001
EVENT_DRIVEN_MODE = "event_driven"
POLL_FALLBACK_MODE = "poll_fallback"
FALLBACK_REASONS = frozenset(
    ("unsupported", "open_failed", "registration_failed", "wait_failed")
)


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
        self.last_forced: Optional[bool] = None
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
        if (
            state == self.last_state
            and forced == self.last_forced
            and monotonic_time < self.next_heartbeat_at
        ):
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
        self.last_forced = forced
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
            raise RuntimeError("another Statelet state aggregator is running") from exc
        return self

    def __exit__(self, _type, _value, _traceback) -> None:
        if self.handle is not None:
            fcntl.flock(self.handle.fileno(), fcntl.LOCK_UN)
            self.handle.close()
            self.handle = None


class DirectoryEventWaiter:
    """Wait for secure directory changes, with bounded polling as a fallback."""

    def __init__(
        self,
        state_dir: Path,
        poll_interval: float,
        sleep: Callable[[float], None] = time.sleep,
        diagnostic: Optional[Callable[[str, Optional[str]], None]] = None,
    ) -> None:
        self.state_dir = state_dir
        self.poll_interval = poll_interval
        self.sleep = sleep
        self.diagnostic = diagnostic
        self._last_reported_mode: Optional[Tuple[str, Optional[str]]] = None
        self._kqueue = None
        self._directory_fd: Optional[int] = None
        self._wake_read_fd: Optional[int] = None
        self._wake_write_fd: Optional[int] = None
        self._initialize_kqueue()

    @property
    def event_driven(self) -> bool:
        return self._kqueue is not None and self._directory_fd is not None

    def _initialize_kqueue(self) -> None:
        if not hasattr(select, "kqueue") or not hasattr(select, "KQ_FILTER_VNODE"):
            self._report_mode(POLL_FALLBACK_MODE, "unsupported")
            return
        try:
            self._kqueue = select.kqueue()
            self._wake_read_fd, self._wake_write_fd = os.pipe()
            for fd in (self._wake_read_fd, self._wake_write_fd):
                os.set_inheritable(fd, False)
                os.set_blocking(fd, False)
            wake_event = select.kevent(
                self._wake_read_fd,
                filter=select.KQ_FILTER_READ,
                flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
            )
            self._kqueue.control([wake_event], 0, 0)
            self._try_watch_directory()
        except (OSError, ValueError):
            self._disable_kqueue()
            self._report_mode(POLL_FALLBACK_MODE, "registration_failed")

    def _report_mode(self, mode: str, reason: Optional[str] = None) -> None:
        if reason is not None and reason not in FALLBACK_REASONS:
            raise ValueError("invalid fallback diagnostic reason")
        diagnostic = (mode, reason)
        if self.diagnostic is None or diagnostic == self._last_reported_mode:
            return
        self._last_reported_mode = diagnostic
        self.diagnostic(mode, reason)

    def _try_watch_directory(self) -> Tuple[bool, bool]:
        if self._kqueue is None:
            return (False, False)
        if self._directory_fd is not None:
            return (True, False)
        flags = os.O_RDONLY
        for flag_name in ("O_CLOEXEC", "O_DIRECTORY", "O_NOFOLLOW", "O_EVTONLY"):
            flags |= getattr(os, flag_name, 0)
        try:
            directory_fd = os.open(str(self.state_dir), flags)
        except OSError:
            self._report_mode(POLL_FALLBACK_MODE, "open_failed")
            return (False, False)
        try:
            vnode_flags = 0
            for flag_name in (
                "KQ_NOTE_WRITE",
                "KQ_NOTE_EXTEND",
                "KQ_NOTE_ATTRIB",
                "KQ_NOTE_LINK",
                "KQ_NOTE_RENAME",
                "KQ_NOTE_DELETE",
                "KQ_NOTE_REVOKE",
            ):
                vnode_flags |= getattr(select, flag_name, 0)
            event = select.kevent(
                directory_fd,
                filter=select.KQ_FILTER_VNODE,
                flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                fflags=vnode_flags,
            )
            self._kqueue.control([event], 0, 0)
        except (OSError, ValueError):
            try:
                os.close(directory_fd)
            except OSError:
                pass
            self._report_mode(POLL_FALLBACK_MODE, "registration_failed")
            return (False, False)
        self._directory_fd = directory_fd
        self._report_mode(EVENT_DRIVEN_MODE)
        return (True, True)

    def prepare(self) -> bool:
        """Arm the directory watch before its contents are scanned."""
        watching, _newly_armed = self._try_watch_directory()
        return watching

    def _drop_directory_watch(self) -> None:
        if self._directory_fd is not None:
            try:
                os.close(self._directory_fd)
            except OSError:
                pass
            self._directory_fd = None

    def _disable_kqueue(self) -> None:
        self._drop_directory_watch()
        if self._kqueue is not None:
            try:
                self._kqueue.close()
            except OSError:
                pass
            self._kqueue = None
        for attribute in ("_wake_read_fd", "_wake_write_fd"):
            fd = getattr(self, attribute)
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass
                setattr(self, attribute, None)

    def wait(self, timeout: float) -> None:
        timeout = max(0.0, timeout)
        watching, newly_armed = self._try_watch_directory()
        if not watching:
            self.sleep(min(timeout, self.poll_interval))
            return
        if newly_armed:
            # The directory may have appeared after the preceding scan. Return
            # immediately so the caller scans the now-watched directory before
            # blocking for a future change.
            return
        try:
            events = self._kqueue.control(None, 8, timeout)
        except (OSError, ValueError):
            self._disable_kqueue()
            self._report_mode(POLL_FALLBACK_MODE, "wait_failed")
            self.sleep(min(timeout, self.poll_interval))
            return
        for event in events:
            if event.ident == self._wake_read_fd:
                try:
                    os.read(self._wake_read_fd, 4096)
                except (BlockingIOError, OSError):
                    pass
            elif event.ident == self._directory_fd:
                invalidating_flags = 0
                for flag_name in (
                    "KQ_NOTE_RENAME",
                    "KQ_NOTE_DELETE",
                    "KQ_NOTE_REVOKE",
                ):
                    invalidating_flags |= getattr(select, flag_name, 0)
                if event.fflags & invalidating_flags:
                    self._drop_directory_watch()

    def wake(self) -> None:
        if self._wake_write_fd is None:
            return
        try:
            os.write(self._wake_write_fd, b"x")
        except OSError:
            pass

    def close(self) -> None:
        self._disable_kqueue()


def print_mode_diagnostic(mode: str, reason: Optional[str]) -> None:
    """Write a path-free mode diagnostic suitable for persistent service logs."""
    if mode == EVENT_DRIVEN_MODE and reason is None:
        print("Statelet state aggregator mode=event_driven", file=sys.stderr)
        return
    if mode == POLL_FALLBACK_MODE and reason in FALLBACK_REASONS:
        print(
            "Statelet state aggregator mode=poll_fallback reason={}".format(reason),
            file=sys.stderr,
        )
        return
    raise ValueError("invalid state aggregator mode diagnostic")


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


def resolve_state_snapshot_with_expiry(
    state_dir: Path,
    active_ttl: float,
    wall_time: float,
    forced_state: Optional[str] = None,
    force_source_updated_at: Optional[float] = None,
) -> Tuple[str, Optional[float], int, Optional[float]]:
    if forced_state is not None:
        state, source_updated_at, active_sessions = resolve_state_snapshot(
            state_dir,
            active_ttl,
            wall_time,
            forced_state,
            force_source_updated_at,
        )
        return (state, source_updated_at, active_sessions, None)
    active = read_active_states(state_dir, now=wall_time, active_ttl=active_ttl)
    lifecycle, source_updated_at = aggregate_state_with_source(active)
    next_expiry = (
        min(updated_at + active_ttl for _, updated_at in active)
        + TTL_DEADLINE_EPSILON
        if active
        else None
    )
    return (lifecycle, source_updated_at, len(active), next_expiry)


def next_wake_timeout(
    publisher: StatePublisher,
    wall_time: float,
    monotonic_time: float,
    force_deadline: Optional[float],
    source_expiry_at: Optional[float],
) -> float:
    deadlines = [max(0.0, publisher.next_heartbeat_at - monotonic_time)]
    if force_deadline is not None and force_deadline > monotonic_time:
        deadlines.append(force_deadline - monotonic_time)
    if source_expiry_at is not None:
        deadlines.append(max(0.0, source_expiry_at - wall_time))
    return min(deadlines)


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
    waiter: Optional[DirectoryEventWaiter] = None,
    wall_clock: Callable[[], float] = time.time,
    monotonic_clock: Callable[[], float] = time.monotonic,
) -> int:
    publisher = StatePublisher(output_path, heartbeat)
    force_started_at = wall_clock() if forced_state is not None else None
    force_deadline = (
        monotonic_clock() + force_seconds
        if forced_state is not None and not once
        else None
    )
    active_waiter = waiter or DirectoryEventWaiter(state_dir, poll)
    owns_waiter = waiter is None
    try:
        while not should_stop():
            active_waiter.prepare()
            wall_time = wall_clock()
            monotonic_time = monotonic_clock()
            forced = force_is_active(
                forced_state, once, force_deadline, monotonic_time
            )
            state, source_updated_at, active_sessions, source_expiry_at = (
                resolve_state_snapshot_with_expiry(
                    state_dir,
                    active_ttl,
                    wall_time,
                    forced_state if forced else None,
                    force_started_at,
                )
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
            timeout = next_wake_timeout(
                publisher,
                wall_time,
                monotonic_time,
                force_deadline if forced else None,
                source_expiry_at,
            )
            active_waiter.wait(timeout)
    finally:
        if owns_waiter:
            active_waiter.close()
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
    waiter = DirectoryEventWaiter(
        args.state_dir,
        args.poll,
        diagnostic=print_mode_diagnostic,
    )

    def request_stop(_signum, _frame) -> None:
        nonlocal stopped
        stopped = True
        waiter.wake()

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
                waiter=waiter,
            )
    except (OSError, RuntimeError) as exc:
        print("Statelet state aggregator error: {}".format(exc), file=sys.stderr)
        return 1
    finally:
        waiter.close()


if __name__ == "__main__":
    raise SystemExit(main())
