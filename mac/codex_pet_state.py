#!/usr/bin/env python3
"""Privacy-safe Codex lifecycle state validation and aggregation."""

import json
import math
import os
import re
import stat
import time
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple


VALID_STATES = ("idle", "running", "waiting", "review")
VALID_EVENTS = frozenset(
    (
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PermissionRequest",
        "PreCompact",
        "PostCompact",
        "SubagentStart",
        "SubagentStop",
        "Stop",
        "unknown",
    )
)
STATE_PRIORITY = {"idle": 0, "running": 1, "review": 2, "waiting": 3}
HOOK_RECORD_NAME = re.compile(r"^[0-9a-f]{24}\.json$")
TARGET_RECORD_NAME = re.compile(r"^[0-9a-f]{24}\.target\.json$")
SESSION_ACTIVITY_FILENAME = "activity-v1.json"
SESSION_ACTIVITY_TARGETS_FILENAME = "activity-targets-v1.json"
SESSION_ACTIVITY_TITLES_FILENAME = "activity-titles-v1.json"
HOOK_RECORD_KEYS = frozenset(("version", "state", "event", "updated_at"))
HOOK_RECORD_V2_KEYS = frozenset(
    ("version", "state", "event", "event_at", "updated_at", "terminal", "rejections", "causal")
)
HOOK_RECORD_V2_OPTIONAL_KEYS = frozenset(
    ("started_at", "completed_at", "category", "fence")
)
ACTIVITY_CATEGORIES = frozenset(("codex", "approval", "tool", "review", "subagent", "activity"))
VALID_REJECTION_REASONS = frozenset(
    (
        "invalid_record",
        "invalid_timestamp",
        "expired",
        "future_event",
        "quiescent_expired",
        "stale_event",
    )
)
MAX_REJECTION_REASONS = 8
MAX_REJECTION_COUNT = 1_000_000
DEFAULT_ACTIVE_TTL = 900.0
DEFAULT_COMPLETED_TTL = 7 * 24 * 60 * 60.0
MAX_ACTIVITY_ENTRIES = 64
MAX_HOOK_RECORD_BYTES = 1_048_576
# A completed tool is evidence that the session is no longer actively using a
# tool.  If Desktop fails to emit its terminal callback after that point, a
# short grace period prevents the generic 15-minute session lease from making
# the pet appear busy indefinitely.  Subsequent hook events refresh the record
# and continue to use the normal active lease.
DEFAULT_QUIESCENT_TTL = 30.0
QUIESCENT_EVENTS = frozenset(("PostToolUse",))
MAX_FUTURE_SKEW = 60.0
CAUSAL_HASH = re.compile(r"^[0-9a-f]{24}$")
CAUSAL_KEYS = frozenset(
    ("version", "current_turn", "prior_turns", "tool_phases", "active_tool", "pending_permissions", "latest_event")
)
FENCE_KEYS = frozenset(("version", "turn_closed", "closed_turn", "session_closed"))
TARGET_RECORD_KEYS = frozenset(("version", "id", "thread_id", "updated_at"))
OPAQUE_TARGET = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,511}$")


def default_state_dir() -> Path:
    override = os.environ.get("STATELET_STATE_DIR") or os.environ.get("CODEX_PET_STATE_DIR")
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Application Support" / "Statelet" / "sessions"


FileIdentity = Tuple[int, int, int, int, int]
HOOK_RECORD_OK = "ok"
HOOK_RECORD_CORRUPT = "corrupt"
HOOK_RECORD_IGNORED = "ignored"


def _status_identity(status: os.stat_result) -> FileIdentity:
    return (
        status.st_dev,
        status.st_ino,
        status.st_size,
        status.st_mtime_ns,
        status.st_ctime_ns,
    )


def _open_state_directory(state_dir: Path) -> Optional[int]:
    try:
        descriptor = os.open(
            state_dir,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
        )
        status = os.fstat(descriptor)
        if not stat.S_ISDIR(status.st_mode) or status.st_uid != os.getuid():
            os.close(descriptor)
            return None
        return descriptor
    except OSError:
        return None


def _read_hook_record(
    directory_fd: int,
    name: str,
) -> Tuple[str, Optional[Any], Optional[FileIdentity]]:
    descriptor: Optional[int] = None
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY
            | getattr(os, "O_NONBLOCK", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
            dir_fd=directory_fd,
        )
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.getuid()
        ):
            return (HOOK_RECORD_IGNORED, None, None)
        identity = _status_identity(before)
        if before.st_size < 0 or before.st_size > MAX_HOOK_RECORD_BYTES:
            return (HOOK_RECORD_CORRUPT, None, identity)
        try:
            remaining = before.st_size + 1
            chunks = []
            while remaining > 0:
                chunk = os.read(descriptor, min(65_536, remaining))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            after = os.fstat(descriptor)
            if _status_identity(before) != _status_identity(after):
                return (HOOK_RECORD_IGNORED, None, None)
            raw = b"".join(chunks)
            if len(raw) != before.st_size:
                return (HOOK_RECORD_CORRUPT, None, identity)
            record = json.loads(raw.decode("utf-8"))
            return (HOOK_RECORD_OK, record, identity)
        except (OSError, UnicodeError, json.JSONDecodeError):
            return (HOOK_RECORD_CORRUPT, None, identity)
    except OSError:
        return (HOOK_RECORD_IGNORED, None, None)
    finally:
        if descriptor is not None:
            os.close(descriptor)


def _prune_if_unchanged(
    directory_fd: int,
    name: str,
    identity: Optional[FileIdentity],
) -> None:
    if identity is None:
        return
    quarantine = ".statelet-prune-{}-{}".format(os.getpid(), time.time_ns())
    try:
        os.rename(
            name,
            quarantine,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
        )
    except OSError:
        return
    moved_identity: Optional[FileIdentity] = None
    descriptor: Optional[int] = None
    try:
        descriptor = os.open(
            quarantine,
            os.O_RDONLY
            | getattr(os, "O_NONBLOCK", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
            dir_fd=directory_fd,
        )
        moved_identity = _status_identity(os.fstat(descriptor))
    except OSError:
        moved_identity = None
    finally:
        if descriptor is not None:
            os.close(descriptor)
    # Renaming can advance ctime even though the inode and file contents are
    # unchanged, so the cleanup comparison intentionally excludes ctime.
    if moved_identity is not None and moved_identity[:4] == identity[:4]:
        try:
            os.unlink(quarantine, dir_fd=directory_fd)
        except OSError:
            pass
        return
    # A pathname replacement won the race. Restore it without overwriting a
    # newer record; if the original name was recreated, leave the quarantined
    # inode intact rather than deleting data we did not validate.
    try:
        os.link(
            quarantine,
            name,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
            follow_symlinks=False,
        )
        os.unlink(quarantine, dir_fd=directory_fd)
    except OSError:
        pass


def _record_names(directory_fd: int) -> List[str]:
    try:
        return sorted(
            name
            for name in os.listdir(directory_fd)
            if HOOK_RECORD_NAME.fullmatch(name) is not None
        )
    except OSError:
        return []


def _target_record_names(directory_fd: int) -> List[str]:
    try:
        return sorted(
            name
            for name in os.listdir(directory_fd)
            if TARGET_RECORD_NAME.fullmatch(name) is not None
        )
    except OSError:
        return []


def read_active_states(
    state_dir: Path,
    now: Optional[float] = None,
    active_ttl: float = DEFAULT_ACTIVE_TTL,
) -> List[Tuple[str, float]]:
    """Return validated, live lifecycle records and prune expired candidates."""
    return read_session_snapshot(state_dir, now, active_ttl)["active"]


def active_ttl_for_event(event: str, active_ttl: float) -> float:
    """Return the bounded lease for a nonterminal hook event."""
    if event in QUIESCENT_EVENTS:
        return min(active_ttl, DEFAULT_QUIESCENT_TTL)
    return active_ttl


def _add_rejection(rejections: Dict[str, int], reason: str, count: int = 1) -> None:
    if reason not in VALID_REJECTION_REASONS or (
        len(rejections) >= MAX_REJECTION_REASONS and reason not in rejections
    ):
        return
    rejections[reason] = min(MAX_REJECTION_COUNT, rejections.get(reason, 0) + count)


def _valid_causal_metadata(value: Any) -> bool:
    if not isinstance(value, dict) or set(value) != CAUSAL_KEYS or value.get("version") != 1:
        return False
    current_turn = value.get("current_turn")
    active_tool = value.get("active_tool")
    pending_permissions = value.get("pending_permissions")
    prior_turns = value.get("prior_turns")
    tool_phases = value.get("tool_phases")
    latest_event = value.get("latest_event")
    return (
        (current_turn is None or (isinstance(current_turn, str) and CAUSAL_HASH.fullmatch(current_turn)))
        and (active_tool is None or (isinstance(active_tool, str) and CAUSAL_HASH.fullmatch(active_tool)))
        and isinstance(pending_permissions, list)
        and len(pending_permissions) <= 64
        and all(
            isinstance(item, str) and CAUSAL_HASH.fullmatch(item)
            for item in pending_permissions
        )
        and isinstance(prior_turns, list)
        and len(prior_turns) <= 8
        and all(isinstance(item, str) and CAUSAL_HASH.fullmatch(item) for item in prior_turns)
        and isinstance(tool_phases, dict)
        and len(tool_phases) <= 64
        and all(
            isinstance(key, str)
            and CAUSAL_HASH.fullmatch(key)
            and isinstance(rank, int)
            and not isinstance(rank, bool)
            and 1 <= rank <= 3
            for key, rank in tool_phases.items()
        )
        and (latest_event is None or latest_event in VALID_EVENTS)
    )


def _valid_fence(value: Any) -> bool:
    if (
        not isinstance(value, dict)
        or set(value) != FENCE_KEYS
        or value.get("version") != 1
        or isinstance(value.get("version"), bool)
    ):
        return False
    closed_turn = value.get("closed_turn")
    return (
        isinstance(value.get("turn_closed"), bool)
        and isinstance(value.get("session_closed"), bool)
        and (
            closed_turn is None
            or (
                isinstance(closed_turn, str)
                and CAUSAL_HASH.fullmatch(closed_turn) is not None
            )
        )
    )


def _valid_hook_record_keys(record: Dict[str, Any], version: Any) -> bool:
    keys = set(record)
    if version == 1:
        return keys == HOOK_RECORD_KEYS
    if version != 2:
        return False
    required = HOOK_RECORD_V2_KEYS - {"causal"}
    return required <= keys <= HOOK_RECORD_V2_KEYS | HOOK_RECORD_V2_OPTIONAL_KEYS


def _event_category(event: str) -> str:
    if event == "PermissionRequest":
        return "approval"
    if event in ("PreToolUse", "PostToolUse"):
        return "tool"
    if event in ("PreCompact", "PostCompact"):
        return "review"
    if event in ("SubagentStart", "SubagentStop"):
        return "subagent"
    if event in ("SessionStart", "SessionEnd", "UserPromptSubmit", "Stop"):
        return "codex"
    return "activity"


def _finite_or_none(value: Any) -> Optional[float]:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    return parsed if math.isfinite(parsed) else None


def read_session_snapshot(
    state_dir: Path,
    now: Optional[float] = None,
    active_ttl: float = DEFAULT_ACTIVE_TTL,
) -> Dict[str, Any]:
    """Read active sessions plus bounded, identifier-free event diagnostics."""
    current = time.time() if now is None else now
    active: List[Tuple[str, float]] = []
    active_expiries: List[float] = []
    latest_event: Optional[str] = None
    latest_event_at: Optional[float] = None
    rejections: Dict[str, int] = {}
    directory_fd = _open_state_directory(state_dir)
    if directory_fd is None:
        return {
            "active": active,
            "latest_event": latest_event,
            "latest_event_at": latest_event_at,
            "rejections": rejections,
            "next_expiry": None,
        }
    try:
        for name in _record_names(directory_fd):
            read_status, record, identity = _read_hook_record(directory_fd, name)
            if read_status == HOOK_RECORD_IGNORED:
                continue
            if read_status == HOOK_RECORD_CORRUPT:
                _add_rejection(rejections, "invalid_record")
                continue
            try:
                if not isinstance(record, dict):
                    _add_rejection(rejections, "invalid_record")
                    continue
                version = record.get("version")
                if not _valid_hook_record_keys(record, version):
                    _add_rejection(rejections, "invalid_record")
                    continue
                event = record.get("event")
                if event not in VALID_EVENTS:
                    _add_rejection(rejections, "invalid_record")
                    continue
                state = record["state"]
                updated_at = float(record["updated_at"])
                event_at = float(record.get("event_at", updated_at))
                terminal = record.get("terminal", event == "SessionEnd")
                started_at = record.get("started_at", event_at)
                completed_at = record.get("completed_at", event_at if terminal else None)
                category = record.get("category", _event_category(event))
                stored_rejections = record.get("rejections", {})
                causal = record.get("causal")
                fence = record.get("fence")
            except (ValueError, TypeError, KeyError):
                _add_rejection(rejections, "invalid_timestamp")
                continue
            if (
                state not in VALID_STATES
                or not math.isfinite(updated_at)
                or not math.isfinite(event_at)
                or _finite_or_none(started_at) is None
                or (completed_at is not None and _finite_or_none(completed_at) is None)
                or not isinstance(terminal, bool)
                or (event != "Stop" and terminal != (event == "SessionEnd"))
                or not isinstance(category, str)
                or category not in ACTIVITY_CATEGORIES
                or not isinstance(stored_rejections, dict)
                or (causal is not None and not _valid_causal_metadata(causal))
                or (fence is not None and not _valid_fence(fence))
            ):
                _add_rejection(rejections, "invalid_record")
                _prune_if_unchanged(directory_fd, name, identity)
                continue
            for reason, count in stored_rejections.items():
                if (
                    reason in VALID_REJECTION_REASONS
                    and isinstance(count, int)
                    and not isinstance(count, bool)
                    and 0 < count <= MAX_REJECTION_COUNT
                ):
                    _add_rejection(rejections, reason, count)
            event_ttl = active_ttl_for_event(event, active_ttl)
            age = current - event_at
            if age < -MAX_FUTURE_SKEW or age > event_ttl:
                # Terminal records are the source for the optional session
                # activity rail. Keep them for a bounded retention window even
                # after they stop contributing to aggregate lifecycle state.
                if terminal and 0 <= age <= DEFAULT_COMPLETED_TTL:
                    continue
                reason = (
                    "future_event"
                    if age < 0
                    else (
                        "quiescent_expired"
                        if event in QUIESCENT_EVENTS
                        else "expired"
                    )
                )
                _add_rejection(rejections, reason)
                _prune_if_unchanged(directory_fd, name, identity)
                continue
            if latest_event_at is None or (event_at, event) > (
                latest_event_at,
                latest_event or "",
            ):
                latest_event = event
                latest_event_at = event_at
            if not terminal and event != "Stop":
                active.append((state, event_at))
                active_expiries.append(event_at + event_ttl)
    finally:
        os.close(directory_fd)
    return {
        "active": active,
        "latest_event": latest_event,
        "latest_event_at": latest_event_at,
        "rejections": rejections,
        "next_expiry": min(active_expiries) if active_expiries else None,
    }


def read_session_activity(
    state_dir: Path,
    now: Optional[float] = None,
    active_ttl: float = DEFAULT_ACTIVE_TTL,
    completed_ttl: float = DEFAULT_COMPLETED_TTL,
) -> Dict[str, Any]:
    """Return bounded, identifier-free active and completed session summaries.

    The filename is already a truncated SHA-256 session key. The activity
    contract intentionally exposes only that opaque key, lifecycle state, safe
    event category, bounded start/event/completion timestamps, and terminal
    status; prompt, transcript, repository, and correlation metadata never
    crosses this boundary.
    """
    current = time.time() if now is None else now
    active: List[Dict[str, Any]] = []
    completed: List[Dict[str, Any]] = []
    directory_fd = _open_state_directory(state_dir)
    if directory_fd is None:
        return {
            "version": 1,
            "emitted_at": current,
            "active": active,
            "completed": completed,
        }
    record_identities: Dict[str, FileIdentity] = {}
    try:
        for name in _record_names(directory_fd):
            read_status, record, identity = _read_hook_record(directory_fd, name)
            if read_status != HOOK_RECORD_OK or identity is None:
                continue
            try:
                if not isinstance(record, dict):
                    continue
                version = record.get("version")
                if not _valid_hook_record_keys(record, version):
                    continue
                event = record.get("event")
                state = record.get("state")
                updated_at = float(record.get("updated_at"))
                event_at = float(record.get("event_at", updated_at))
                terminal = record.get("terminal", event == "SessionEnd")
                started_at = _finite_or_none(record.get("started_at", event_at))
                completed_at = _finite_or_none(
                    record.get("completed_at", event_at if terminal else None)
                )
                category = record.get("category", _event_category(event))
            except (TypeError, ValueError, KeyError):
                continue
            if (
                event not in VALID_EVENTS
                or state not in VALID_STATES
                or not math.isfinite(updated_at)
                or not math.isfinite(event_at)
                or started_at is None
                or (terminal and completed_at is None)
                or (not terminal and record.get("completed_at") is not None and completed_at is None)
                or not isinstance(terminal, bool)
                or (event != "Stop" and terminal != (event == "SessionEnd"))
                or not isinstance(category, str)
                or category not in ACTIVITY_CATEGORIES
            ):
                continue
            age = current - event_at
            event_ttl = active_ttl_for_event(event, active_ttl)
            if age < -MAX_FUTURE_SKEW:
                continue
            identifier = name[:-5]
            record_identities[identifier] = identity
            is_completed = terminal and event == "SessionEnd"
            if is_completed:
                if age > completed_ttl:
                    _prune_if_unchanged(directory_fd, name, identity)
                    continue
                completed.append({
                    "id": identifier,
                    "state": state,
                    "event": event,
                    "event_at": event_at,
                    "started_at": started_at,
                    "completed_at": completed_at,
                    "category": category,
                    "terminal": True,
                })
            elif event != "Stop" and age <= event_ttl and state != "idle":
                active.append({
                    "id": identifier,
                    "state": state,
                    "event": event,
                    "event_at": event_at,
                    "started_at": started_at,
                    "completed_at": None,
                    "category": category,
                    "terminal": False,
                })
            elif age > event_ttl:
                _prune_if_unchanged(directory_fd, name, identity)
        active.sort(
            key=lambda item: (
                -STATE_PRIORITY[item["state"]],
                -item["event_at"],
                item["id"],
            )
        )
        completed.sort(key=lambda item: (-item["event_at"], item["id"]))
        # Terminal records no longer contribute to current_state.json, so the
        # bounded activity rail may safely discard the oldest overflow entries.
        for item in completed[MAX_ACTIVITY_ENTRIES:]:
            _prune_if_unchanged(
                directory_fd,
                f"{item['id']}.json",
                record_identities.get(item["id"]),
            )
    finally:
        os.close(directory_fd)
    return {
        "version": 1,
        "emitted_at": current,
        "active": active[:MAX_ACTIVITY_ENTRIES],
        "completed": completed[:MAX_ACTIVITY_ENTRIES],
    }


def read_session_targets(
    state_dir: Path,
    activity: Dict[str, Any],
    now: Optional[float] = None,
    target_ttl: float = DEFAULT_COMPLETED_TTL,
) -> Dict[str, Any]:
    """Read the private activation mapping for currently projected sessions."""
    current = time.time() if now is None else now
    projected_ids = {
        item.get("id")
        for group in (activity.get("active", []), activity.get("completed", []))
        if isinstance(group, list)
        for item in group
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    targets: List[Dict[str, str]] = []
    directory_fd = _open_state_directory(state_dir)
    if directory_fd is None:
        return {"version": 1, "emitted_at": current, "targets": targets}
    try:
        for name in _target_record_names(directory_fd):
            read_status, record, identity = _read_hook_record(directory_fd, name)
            if read_status != HOOK_RECORD_OK or identity is None:
                continue
            identifier = name[:-12]
            valid = False
            try:
                raw_updated_at = record.get("updated_at") if isinstance(record, dict) else None
                updated_at = (
                    float(raw_updated_at)
                    if not isinstance(raw_updated_at, bool)
                    else math.nan
                )
                thread_id = record.get("thread_id") if isinstance(record, dict) else None
                valid = (
                    isinstance(record, dict)
                    and set(record) == TARGET_RECORD_KEYS
                    and record.get("version") == 1
                    and not isinstance(record.get("version"), bool)
                    and record.get("id") == identifier
                    and isinstance(thread_id, str)
                    and OPAQUE_TARGET.fullmatch(thread_id) is not None
                    and math.isfinite(updated_at)
                    and -MAX_FUTURE_SKEW <= current - updated_at <= target_ttl
                )
            except (TypeError, ValueError):
                valid = False
            if not valid:
                _prune_if_unchanged(directory_fd, name, identity)
                continue
            # A normal turn ends with Stop before the main session may later
            # emit SessionEnd. Keep the private target for its bounded TTL
            # during that unprojected interval, but never expose it in the
            # consolidated sidecar until the session is projected again.
            if identifier in projected_ids:
                targets.append({"id": identifier, "thread_id": thread_id})
    finally:
        os.close(directory_fd)
    targets.sort(key=lambda item: item["id"])
    return {"version": 1, "emitted_at": current, "targets": targets}


def aggregate_state(active: Iterable[Tuple[str, float]]) -> str:
    """Aggregate sessions using waiting > review > running > idle priority."""
    return aggregate_state_with_source(active)[0]


def aggregate_state_with_source(
    active: Iterable[Tuple[str, float]],
) -> Tuple[str, Optional[float]]:
    entries = list(active)
    if not entries:
        return ("idle", None)
    # A recent Stop event writes idle for that session; concurrent active
    # sessions still win through priority.
    state, updated_at = max(
        entries, key=lambda item: (STATE_PRIORITY[item[0]], item[1])
    )
    return (state, updated_at)
