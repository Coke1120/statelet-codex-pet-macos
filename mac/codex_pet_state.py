#!/usr/bin/env python3
"""Privacy-safe Codex lifecycle state validation and aggregation."""

import json
import math
import os
import re
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
SESSION_ACTIVITY_FILENAME = "activity-v1.json"
HOOK_RECORD_KEYS = frozenset(("version", "state", "event", "updated_at"))
HOOK_RECORD_V2_KEYS = frozenset(
    ("version", "state", "event", "event_at", "updated_at", "terminal", "rejections", "causal")
)
HOOK_RECORD_V2_OPTIONAL_KEYS = frozenset(("started_at", "completed_at", "category"))
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


def default_state_dir() -> Path:
    override = os.environ.get("STATELET_STATE_DIR") or os.environ.get("CODEX_PET_STATE_DIR")
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Application Support" / "Statelet" / "sessions"


def _file_identity(path: Path) -> Optional[Tuple[int, int, int, int]]:
    try:
        stat = path.stat()
    except OSError:
        return None
    return (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns)


def _prune_if_unchanged(
    path: Path, identity: Optional[Tuple[int, int, int, int]]
) -> None:
    if identity is None or _file_identity(path) != identity:
        return
    try:
        path.unlink()
    except OSError:
        # Another hook may have replaced it, or a transient filesystem error
        # may make it readable again on the next poll.
        pass


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
    if not state_dir.exists():
        return {
            "active": active,
            "latest_event": latest_event,
            "latest_event_at": latest_event_at,
            "rejections": rejections,
            "next_expiry": None,
        }
    for path in sorted(state_dir.glob("*.json"), key=lambda candidate: candidate.name):
        if HOOK_RECORD_NAME.fullmatch(path.name) is None:
            continue
        identity = _file_identity(path)
        if identity is None:
            continue
        try:
            record: Any = json.loads(path.read_text(encoding="utf-8"))
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
            terminal = record.get("terminal", event in ("SessionEnd", "Stop"))
            started_at = record.get("started_at", event_at)
            completed_at = record.get("completed_at", event_at if terminal else None)
            category = record.get("category", _event_category(event))
            stored_rejections = record.get("rejections", {})
            causal = record.get("causal")
        except OSError:
            continue
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
            or terminal != (event in ("SessionEnd", "Stop"))
            or not isinstance(category, str)
            or category not in ACTIVITY_CATEGORIES
            or not isinstance(stored_rejections, dict)
            or (causal is not None and not _valid_causal_metadata(causal))
        ):
            _add_rejection(rejections, "invalid_record")
            _prune_if_unchanged(path, identity)
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
            _prune_if_unchanged(path, identity)
            continue
        if latest_event_at is None or (event_at, event) > (
            latest_event_at,
            latest_event or "",
        ):
            latest_event = event
            latest_event_at = event_at
        if not terminal:
            active.append((state, event_at))
            active_expiries.append(event_at + event_ttl)
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
    if not state_dir.exists():
        return {
            "version": 1,
            "emitted_at": current,
            "active": active,
            "completed": completed,
        }
    for path in sorted(state_dir.glob("*.json"), key=lambda candidate: candidate.name):
        if HOOK_RECORD_NAME.fullmatch(path.name) is None:
            continue
        identity = _file_identity(path)
        if identity is None:
            continue
        try:
            record: Any = json.loads(path.read_text(encoding="utf-8"))
            if not isinstance(record, dict):
                continue
            version = record.get("version")
            if not _valid_hook_record_keys(record, version):
                continue
            event = record.get("event")
            state = record.get("state")
            updated_at = float(record.get("updated_at"))
            event_at = float(record.get("event_at", updated_at))
            terminal = record.get("terminal", event in ("SessionEnd", "Stop"))
            started_at = _finite_or_none(record.get("started_at", event_at))
            completed_at = _finite_or_none(
                record.get("completed_at", event_at if terminal else None)
            )
            category = record.get("category", _event_category(event))
        except (OSError, TypeError, ValueError, KeyError, json.JSONDecodeError):
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
            or terminal != (event in ("SessionEnd", "Stop"))
            or not isinstance(category, str)
            or category not in ACTIVITY_CATEGORIES
        ):
            continue
        age = current - event_at
        event_ttl = active_ttl_for_event(event, active_ttl)
        if age < -MAX_FUTURE_SKEW:
            continue
        is_completed = terminal and event in ("SessionEnd", "Stop")
        if is_completed:
            if age > completed_ttl:
                _prune_if_unchanged(path, identity)
                continue
            completed.append(
                {
                    "id": path.stem,
                    "state": state,
                    "event": event,
                    "event_at": event_at,
                    "started_at": started_at,
                    "completed_at": completed_at,
                    "category": category,
                    "terminal": True,
                }
            )
        elif age <= event_ttl and state != "idle":
            active.append(
                {
                    "id": path.stem,
                    "state": state,
                    "event": event,
                    "event_at": event_at,
                    "started_at": started_at,
                    "completed_at": None,
                    "category": category,
                    "terminal": False,
                }
            )
        else:
            _prune_if_unchanged(path, identity)
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
        path = state_dir / f"{item['id']}.json"
        _prune_if_unchanged(path, _file_identity(path))
    return {
        "version": 1,
        "emitted_at": current,
        "active": active[:MAX_ACTIVITY_ENTRIES],
        "completed": completed[:MAX_ACTIVITY_ENTRIES],
    }


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
