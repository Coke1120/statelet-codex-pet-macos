#!/usr/bin/env python3
"""Publish board-independent Codex lifecycle state for the macOS player."""

import argparse
import fcntl
import json
import math
import os
import select
import signal
import stat
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
        VALID_EVENTS,
        VALID_REJECTION_REASONS,
        VALID_STATES,
        aggregate_state_with_source,
        default_state_dir,
        read_session_activity,
        read_session_snapshot,
        SESSION_ACTIVITY_FILENAME,
    )
except ModuleNotFoundError as error:
    if error.name != "statelet_state":
        raise
    # Repository/source compatibility. Installed Statelet components use the
    # canonical module name above.
    from codex_pet_state import (  # noqa: E402
        DEFAULT_ACTIVE_TTL,
        STATE_PRIORITY,
        VALID_EVENTS,
        VALID_REJECTION_REASONS,
        VALID_STATES,
        aggregate_state_with_source,
        default_state_dir,
        read_session_activity,
        read_session_snapshot,
        SESSION_ACTIVITY_FILENAME,
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
REVISION_TICKS_PER_SECOND = 1_000_000
REVISION_SIDECAR_SUFFIX = ".revision"
MAX_PUBLICATION_REVISION = (1 << 63) - 2
DEFAULT_POLL_INTERVAL = 0.25
# State changes still publish immediately.  The heartbeat exists only to make
# writer liveness observable, so keep it low-frequency to avoid needless SSD
# churn while an idle companion runs all day.
DEFAULT_HEARTBEAT_INTERVAL = 60.0
OPTIONAL_ACTIVITY_DIAGNOSTIC_INTERVAL = 60.0
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
    publication_revision: Optional[int] = None,
    latest_event: Optional[str] = None,
    latest_event_at: Optional[float] = None,
    rejection_diagnostics: Optional[Dict[str, object]] = None,
    recovery: Optional[bool] = None,
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
    if publication_revision is not None and (
        isinstance(publication_revision, bool) or publication_revision < 1
    ):
        raise ValueError("publication_revision must be a positive integer")
    if latest_event is not None and latest_event not in VALID_EVENTS:
        latest_event = "unknown"
    if latest_event_at is not None and not math.isfinite(latest_event_at):
        raise ValueError("latest_event_at must be finite when present")
    rejection_diagnostics = sanitize_rejection_diagnostics(rejection_diagnostics)
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
    if publication_revision is not None:
        record.update(
            {
                "publication_revision": publication_revision,
                "latest_event": latest_event,
                "latest_event_at": latest_event_at,
                "rejection_diagnostics": rejection_diagnostics,
                "recovery": bool(recovery),
            }
        )
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


def sanitize_rejection_diagnostics(
    diagnostic: Optional[Dict[str, object]],
) -> Dict[str, object]:
    reasons: Dict[str, int] = {}
    raw_reasons = diagnostic.get("reasons") if isinstance(diagnostic, dict) else None
    if isinstance(raw_reasons, dict):
        for reason in sorted(VALID_REJECTION_REASONS):
            count = raw_reasons.get(reason)
            if (
                isinstance(count, int)
                and not isinstance(count, bool)
                and count > 0
            ):
                reasons[reason] = min(1_000_000, count)
    return {"count": min(1_000_000, sum(reasons.values())), "reasons": reasons}


def _open_owner_activity_directory(path: Path) -> int:
    descriptor = os.open(
        path,
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0),
    )
    try:
        status = os.fstat(descriptor)
        if not stat.S_ISDIR(status.st_mode) or status.st_uid != os.getuid():
            raise OSError("session activity directory is not owner-controlled")
        os.fchmod(descriptor, 0o700)
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def atomic_write_session_activity(
    output_path: Path,
    snapshot: Dict[str, object],
    emitted_at: float,
) -> Dict[str, object]:
    """Publish the bounded privacy-safe session activity sidecar."""
    if not math.isfinite(emitted_at):
        raise ValueError("activity emitted_at must be finite")
    active = snapshot.get("active", [])
    completed = snapshot.get("completed", [])
    if not isinstance(active, list) or not isinstance(completed, list):
        raise ValueError("activity groups must be lists")
    record: Dict[str, object] = {
        "version": 1,
        "schema_version": 1,
        "emitted_at": emitted_at,
        "active": active,
        "completed": completed,
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    directory_fd = _open_owner_activity_directory(output_path.parent)
    fd = -1
    temporary = ""
    try:
        for attempt in range(16):
            temporary = ".session-activity-{}-{}-{}.json".format(
                os.getpid(), time.time_ns(), attempt
            )
            try:
                fd = os.open(
                    temporary,
                    os.O_WRONLY
                    | os.O_CREAT
                    | os.O_EXCL
                    | getattr(os, "O_NOFOLLOW", 0)
                    | getattr(os, "O_CLOEXEC", 0),
                    0o600,
                    dir_fd=directory_fd,
                )
                break
            except FileExistsError:
                continue
        if fd < 0:
            raise OSError("could not reserve session activity temporary file")
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            fd = -1
            json.dump(record, handle, separators=(",", ":"), sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(
            temporary,
            output_path.name,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
        )
        temporary = ""
        os.fsync(directory_fd)
    finally:
        if fd >= 0:
            os.close(fd)
        if temporary:
            try:
                os.unlink(temporary, dir_fd=directory_fd)
            except FileNotFoundError:
                pass
        os.close(directory_fd)
    return record


class SessionActivityPublisher:
    """Suppress unchanged activity sidecar writes until the heartbeat."""

    def __init__(self, output_path: Path, heartbeat: float) -> None:
        self.output_path = output_path
        self.heartbeat = heartbeat
        self.last_fingerprint: Optional[str] = None
        self.next_heartbeat_at = 0.0

    def publish_if_due(
        self,
        snapshot: Dict[str, object],
        wall_time: float,
        monotonic_time: float,
    ) -> Optional[Dict[str, object]]:
        fingerprint = json.dumps(
            {
                "active": snapshot.get("active", []),
                "completed": snapshot.get("completed", []),
            },
            sort_keys=True,
            separators=(",", ":"),
        )
        if (
            fingerprint == self.last_fingerprint
            and monotonic_time < self.next_heartbeat_at
        ):
            return None
        record = atomic_write_session_activity(self.output_path, snapshot, wall_time)
        self.last_fingerprint = fingerprint
        self.next_heartbeat_at = monotonic_time + self.heartbeat
        return record


class StatePublisher:
    """Suppress unchanged writes until the heartbeat becomes due."""

    def __init__(self, output_path: Path, heartbeat: float) -> None:
        self.output_path = output_path
        self.revision_path = output_path.with_name(
            output_path.name + REVISION_SIDECAR_SUFFIX
        )
        self.heartbeat = heartbeat
        self.last_state: Optional[str] = None
        self.last_forced: Optional[bool] = None
        self.last_fingerprint: Optional[Tuple[object, ...]] = None
        self.next_heartbeat_at = 0.0
        self.publication_revision = self._seed_revision()
        self.recovery_pending = True

    def _seed_revision(self) -> int:
        wall_clock_floor = min(
            MAX_PUBLICATION_REVISION,
            max(0, int(time.time() * REVISION_TICKS_PER_SECOND)),
        )
        sidecar_floor = self._read_revision_sidecar()
        descriptor: Optional[int] = None
        try:
            flags = (
                os.O_RDONLY
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0)
            )
            descriptor = os.open(self.output_path, flags)
            status = os.fstat(descriptor)
            if (
                not stat.S_ISREG(status.st_mode)
                or status.st_size > 16 * 1024
                or status.st_uid != os.getuid()
            ):
                return max(wall_clock_floor, sidecar_floor)
            raw = os.read(descriptor, status.st_size + 1)
            if len(raw) != status.st_size:
                return max(wall_clock_floor, sidecar_floor)
            record = json.loads(raw.decode("utf-8"))
            if not isinstance(record, dict):
                return max(wall_clock_floor, sidecar_floor)
            revision = record.get("publication_revision", 0)
            if (
                record.get("version") != SCHEMA_VERSION
                or record.get("schema_version") != SCHEMA_VERSION
                or record.get("state") not in VALID_STATES
                or record.get("source") != "aggregate"
                or isinstance(revision, bool)
                or not isinstance(revision, int)
                or revision < 0
                or revision > MAX_PUBLICATION_REVISION
            ):
                return max(wall_clock_floor, sidecar_floor)
            return max(wall_clock_floor, sidecar_floor, revision)
        except (OSError, ValueError, UnicodeError, AttributeError):
            return max(wall_clock_floor, sidecar_floor)
        finally:
            if descriptor is not None:
                os.close(descriptor)

    def _read_revision_sidecar(self) -> int:
        descriptor: Optional[int] = None
        try:
            descriptor = os.open(
                self.revision_path,
                os.O_RDONLY
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0),
            )
            status = os.fstat(descriptor)
            if (
                not stat.S_ISREG(status.st_mode)
                or status.st_size > 32
                or status.st_uid != os.getuid()
            ):
                return 0
            raw = os.read(descriptor, status.st_size + 1).decode("ascii").strip()
            value = int(raw)
            return value if 0 < value <= MAX_PUBLICATION_REVISION else 0
        except (OSError, ValueError, UnicodeError):
            return 0
        finally:
            if descriptor is not None:
                os.close(descriptor)

    def _persist_revision(self) -> None:
        self.revision_path.parent.mkdir(parents=True, exist_ok=True)
        self.revision_path.parent.chmod(0o700)
        fd, temporary = tempfile.mkstemp(
            prefix=".revision-", dir=str(self.revision_path.parent)
        )
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="ascii") as handle:
                fd = -1
                handle.write(str(self.publication_revision) + "\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, self.revision_path)
            self.revision_path.chmod(0o600)
        finally:
            if fd >= 0:
                os.close(fd)
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass

    def publish_if_due(
        self,
        state: str,
        source_updated_at: Optional[float],
        wall_time: float,
        monotonic_time: float,
        active_sessions: int = 0,
        forced: bool = False,
        latest_event: Optional[str] = None,
        latest_event_at: Optional[float] = None,
        rejection_diagnostics: Optional[Dict[str, object]] = None,
    ) -> Optional[Dict[str, object]]:
        diagnostic = sanitize_rejection_diagnostics(rejection_diagnostics)
        if latest_event is not None and latest_event not in VALID_EVENTS:
            latest_event = "unknown"
        fingerprint = (
            state,
            source_updated_at,
            active_sessions,
            forced,
            latest_event,
            latest_event_at,
            json.dumps(diagnostic, sort_keys=True, separators=(",", ":")),
        )
        if (
            fingerprint == self.last_fingerprint
            and monotonic_time < self.next_heartbeat_at
        ):
            return None
        if self.publication_revision >= MAX_PUBLICATION_REVISION:
            # The operational wall-clock range is centuries below this guard;
            # fail closed instead of emitting a value Swift cannot decode.
            raise OverflowError("publication revision exhausted")
        self.publication_revision += 1
        record = atomic_write_state(
            self.output_path,
            state,
            source_updated_at,
            wall_time,
            active_sessions,
            forced,
            self.publication_revision,
            latest_event,
            latest_event_at,
            diagnostic,
            self.recovery_pending,
        )
        self._persist_revision()
        self.last_state = state
        self.last_forced = forced
        self.last_fingerprint = fingerprint
        self.recovery_pending = False
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


def print_activity_diagnostic(message: str) -> None:
    allowed = frozenset(
        (
            "Statelet session activity sidecar status=degraded reason=io_error",
            "Statelet session activity sidecar status=degraded reason=encoding_error",
            "Statelet session activity sidecar status=degraded reason=invalid_projection",
            "Statelet session activity sidecar status=recovered",
        )
    )
    if message not in allowed:
        raise ValueError("invalid activity sidecar diagnostic")
    print(message, file=sys.stderr)


class OptionalActivityDiagnostic:
    def __init__(
        self,
        diagnostic: Callable[[str], None],
        interval: float = OPTIONAL_ACTIVITY_DIAGNOSTIC_INTERVAL,
    ) -> None:
        self.diagnostic = diagnostic
        self.interval = interval
        self.degraded = False
        self.reported_degraded = False
        self.next_report_at = 0.0

    def failure(self, reason: str, monotonic_time: float) -> None:
        if reason not in ("io_error", "encoding_error", "invalid_projection"):
            raise ValueError("invalid activity sidecar failure reason")
        if monotonic_time >= self.next_report_at:
            self.diagnostic(
                "Statelet session activity sidecar status=degraded reason={}".format(
                    reason
                )
            )
            self.next_report_at = monotonic_time + self.interval
            self.reported_degraded = True
        self.degraded = True

    def recovery(self) -> None:
        if not self.degraded:
            return
        if self.reported_degraded:
            self.diagnostic("Statelet session activity sidecar status=recovered")
        self.degraded = False
        self.reported_degraded = False


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
    active = read_session_snapshot(
        state_dir, now=wall_time, active_ttl=active_ttl
    )["active"]
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
    snapshot = read_session_snapshot(
        state_dir, now=wall_time, active_ttl=active_ttl
    )
    active = snapshot["active"]
    lifecycle, source_updated_at = aggregate_state_with_source(active)
    next_expiry = (
        snapshot["next_expiry"] + TTL_DEADLINE_EPSILON
        if snapshot["next_expiry"] is not None
        else None
    )
    return (lifecycle, source_updated_at, len(active), next_expiry)


def resolve_diagnostic_snapshot(
    state_dir: Path, active_ttl: float, wall_time: float
) -> Tuple[
    str,
    Optional[float],
    int,
    Optional[float],
    Optional[str],
    Optional[float],
    Dict[str, object],
]:
    snapshot = read_session_snapshot(state_dir, now=wall_time, active_ttl=active_ttl)
    active = snapshot["active"]
    lifecycle, source_updated_at = aggregate_state_with_source(active)
    next_expiry = (
        snapshot["next_expiry"] + TTL_DEADLINE_EPSILON
        if snapshot["next_expiry"] is not None
        else None
    )
    reasons = snapshot["rejections"]
    diagnostics: Dict[str, object] = {
        "count": min(1_000_000, sum(reasons.values())),
        "reasons": reasons,
    }
    return (
        lifecycle,
        source_updated_at,
        len(active),
        next_expiry,
        snapshot["latest_event"],
        snapshot["latest_event_at"],
        diagnostics,
    )


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
    activity_diagnostic: Callable[[str], None] = print_activity_diagnostic,
) -> int:
    publisher = StatePublisher(output_path, heartbeat)
    activity_publisher = SessionActivityPublisher(
        state_dir / SESSION_ACTIVITY_FILENAME,
        heartbeat,
    )
    activity_health = OptionalActivityDiagnostic(activity_diagnostic)
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
            if forced:
                (
                    state,
                    source_updated_at,
                    active_sessions,
                    source_expiry_at,
                ) = resolve_state_snapshot_with_expiry(
                    state_dir,
                    active_ttl,
                    wall_time,
                    forced_state,
                    force_started_at,
                )
                latest_event = None
                latest_event_at = None
                rejection_diagnostics: Dict[str, object] = {"count": 0, "reasons": {}}
            else:
                (
                    state,
                    source_updated_at,
                    active_sessions,
                    source_expiry_at,
                    latest_event,
                    latest_event_at,
                    rejection_diagnostics,
                ) = resolve_diagnostic_snapshot(state_dir, active_ttl, wall_time)
            record = publisher.publish_if_due(
                state,
                source_updated_at,
                wall_time,
                monotonic_time,
                active_sessions,
                forced,
                latest_event,
                latest_event_at,
                rejection_diagnostics,
            )
            if record is not None and print_state:
                print(state, flush=True)
            # The activity rail is an optional projection. Publish the
            # authoritative lifecycle state first, then fail soft only for
            # expected filesystem/serialization errors in the sidecar path.
            try:
                activity_snapshot = read_session_activity(
                    state_dir,
                    now=wall_time,
                    active_ttl=active_ttl,
                )
                activity_publisher.publish_if_due(
                    activity_snapshot,
                    wall_time,
                    monotonic_time,
                )
                activity_health.recovery()
            except OSError:
                activity_health.failure("io_error", monotonic_time)
            except UnicodeError:
                activity_health.failure("encoding_error", monotonic_time)
            except (TypeError, ValueError):
                activity_health.failure("invalid_projection", monotonic_time)
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
