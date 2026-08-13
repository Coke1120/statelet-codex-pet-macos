#!/usr/bin/env python3
"""Translate Codex lifecycle hooks into small, privacy-safe Statelet state files.

Codex sends one JSON object on stdin. This hook deliberately stores only a
hashed session key, bounded hashes used for turn/tool causality, the mapped
pet state, event name, and timestamp. It never stores prompts, tool output,
transcript paths, or working directories.
"""

import fcntl
import hashlib
import json
import os
import re
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, Optional

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
    )
)
TERMINAL_EVENTS = frozenset(("SessionEnd", "Stop"))
REVIVAL_EVENTS = frozenset(("SessionStart", "UserPromptSubmit"))
MAX_REJECTION_COUNT = 1_000_000
MAX_PRIOR_TURNS = 8
MAX_TOOL_IDS = 64
REVIEW_PATTERN = re.compile(
    r"(?<![a-z0-9_])"
    r"(?:review|tests?|pytest|unittest|vitest|jest|lint|ruff|mypy|"
    r"typecheck|git\s+diff(?:\s+--check)?|cargo\s+check|"
    r"(?:npm|pnpm|yarn)\s+(?:run\s+)?check)"
    r"(?![a-z0-9_])"
)
HASH_PATTERN = re.compile(r"^[0-9a-f]{24}$")


def default_state_dir() -> Path:
    override = os.environ.get("STATELET_STATE_DIR") or os.environ.get("CODEX_PET_STATE_DIR")
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Application Support" / "Statelet" / "sessions"


def event_state(payload: Dict[str, Any]) -> str:
    event = str(payload.get("hook_event_name") or "")
    if event in ("SessionStart", "SessionEnd", "Stop"):
        return "idle"
    if event == "PermissionRequest":
        return "waiting"
    if event in ("UserPromptSubmit", "SubagentStart", "SubagentStop"):
        return "running"
    if event in ("PreCompact", "PostCompact"):
        return "review"
    if event in ("PreToolUse", "PostToolUse"):
        tool_name = str(payload.get("tool_name") or "").lower()
        tool_input = payload.get("tool_input")
        searchable = tool_name + " " + json.dumps(tool_input, ensure_ascii=False).lower()
        if REVIEW_PATTERN.search(searchable):
            return "review"
        return "running"
    return "idle"


def session_key(payload: Dict[str, Any]) -> str:
    raw = "global"
    for key in ("session_id", "thread_id", "conversation_id", "sessionId"):
        candidate = payload.get(key)
        if isinstance(candidate, (str, int)) and not isinstance(candidate, bool):
            text = str(candidate).strip()
            if text:
                raw = text
                break
    return hashlib.sha256(raw.encode("utf-8", errors="replace")).hexdigest()[:24]


def _private_key_hash(payload: Dict[str, Any], key: str) -> Optional[str]:
    value = payload.get(key)
    if not isinstance(value, (str, int)) or isinstance(value, bool):
        return None
    text = str(value).strip()
    if not text:
        return None
    return hashlib.sha256(text.encode("utf-8", errors="replace")).hexdigest()[:24]


def _read_existing(path: Path) -> Optional[Dict[str, Any]]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def _atomic_write_record(destination: Path, record: Dict[str, Any]) -> None:
    fd, temporary = tempfile.mkstemp(
        prefix=".event-", suffix=".json", dir=str(destination.parent)
    )
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            fd = -1
            json.dump(record, handle, separators=(",", ":"), sort_keys=True)
            handle.write("\n")
            handle.flush()
        os.replace(temporary, destination)
        destination.chmod(0o600)
        # Publication is complete before best-effort durability work. A hook
        # deadline must not strand the only valid record in a hidden temp file.
        try:
            destination_fd = os.open(
                destination,
                os.O_RDONLY
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0),
            )
            try:
                os.fsync(destination_fd)
            finally:
                os.close(destination_fd)
            directory_fd = os.open(destination.parent, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        except OSError:
            pass
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


def _empty_causal_state() -> Dict[str, Any]:
    return {
        "version": 1,
        "current_turn": None,
        "prior_turns": [],
        "tool_phases": {},
        "active_tool": None,
        "pending_permissions": [],
        "latest_event": None,
    }


def _read_causal_state(value: Any) -> Dict[str, Any]:
    if not isinstance(value, dict) or value.get("version") != 1:
        return _empty_causal_state()
    if set(value) != {
        "version", "current_turn", "prior_turns", "tool_phases",
        "active_tool", "pending_permissions", "latest_event",
    }:
        return _empty_causal_state()
    current_turn = value.get("current_turn")
    prior_turns = value.get("prior_turns")
    tool_phases = value.get("tool_phases")
    active_tool = value.get("active_tool")
    pending_permissions = value.get("pending_permissions")
    latest_event = value.get("latest_event")
    if current_turn is not None and (
        not isinstance(current_turn, str) or HASH_PATTERN.fullmatch(current_turn) is None
    ):
        return _empty_causal_state()
    if not isinstance(prior_turns, list) or len(prior_turns) > MAX_PRIOR_TURNS or not all(
        isinstance(item, str) and HASH_PATTERN.fullmatch(item) is not None for item in prior_turns
    ):
        return _empty_causal_state()
    if not isinstance(tool_phases, dict) or len(tool_phases) > MAX_TOOL_IDS or not all(
        isinstance(key, str)
        and HASH_PATTERN.fullmatch(key) is not None
        and isinstance(rank, int)
        and not isinstance(rank, bool)
        and 1 <= rank <= 3
        for key, rank in tool_phases.items()
    ):
        return _empty_causal_state()
    if active_tool is not None and (
        not isinstance(active_tool, str) or HASH_PATTERN.fullmatch(active_tool) is None
    ):
        return _empty_causal_state()
    if not isinstance(pending_permissions, list) or len(pending_permissions) > MAX_TOOL_IDS or not all(
        isinstance(item, str) and HASH_PATTERN.fullmatch(item) is not None
        for item in pending_permissions
    ):
        return _empty_causal_state()
    if latest_event is not None and latest_event not in VALID_EVENTS.union(("unknown",)):
        return _empty_causal_state()
    return {
        "version": 1,
        "current_turn": current_turn,
        "prior_turns": prior_turns[-MAX_PRIOR_TURNS:],
        "tool_phases": dict(list(tool_phases.items())[-MAX_TOOL_IDS:]),
        "active_tool": active_tool,
        "pending_permissions": pending_permissions,
        "latest_event": latest_event,
    }


def _start_turn(causal: Dict[str, Any], turn: str) -> None:
    previous = causal.get("current_turn")
    prior = [item for item in causal["prior_turns"] if item != turn]
    if isinstance(previous, str) and previous != turn:
        prior.append(previous)
    causal["prior_turns"] = prior[-MAX_PRIOR_TURNS:]
    causal["current_turn"] = turn
    causal["tool_phases"] = {}
    causal["active_tool"] = None
    causal["pending_permissions"] = []
    causal["latest_event"] = None


def _tool_fingerprint(payload: Dict[str, Any]) -> str:
    value = {
        "tool_name": str(payload.get("tool_name") or ""),
        "tool_input": payload.get("tool_input"),
    }
    encoded = json.dumps(
        value, ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).encode("utf-8", errors="replace")
    return hashlib.sha256(encoded).hexdigest()[:24]


def _causally_accept(
    payload: Dict[str, Any], event: str, causal: Dict[str, Any]
) -> bool:
    """Reject callbacks proven stale by Codex's turn/tool correlation fields."""
    turn = _private_key_hash(payload, "turn_id")
    current_turn = causal.get("current_turn")

    if turn is not None and current_turn is None:
        _start_turn(causal, turn)
    elif turn is not None and turn != current_turn:
        if turn in causal["prior_turns"]:
            return False
        _start_turn(causal, turn)
    elif event == "UserPromptSubmit" and turn is not None:
        latest = causal.get("latest_event")
        if latest not in (None, "UserPromptSubmit"):
            return False

    if event == "SessionStart":
        causal.clear()
        causal.update(_empty_causal_state())
    elif event in ("PreToolUse", "PostToolUse"):
        tool = _private_key_hash(payload, "tool_use_id")
        if tool is None:
            return False
        fingerprint = _tool_fingerprint(payload)
        pending_permissions = causal.get("pending_permissions", [])
        if fingerprint in pending_permissions:
            if event == "PreToolUse":
                return False
            remaining_permissions = list(pending_permissions)
            remaining_permissions.remove(fingerprint)
            causal["pending_permissions"] = remaining_permissions
        phase = 1 if event == "PreToolUse" else 3
        previous_phase = causal["tool_phases"].get(tool, 0)
        if phase <= previous_phase:
            return False
        causal["tool_phases"][tool] = phase
        causal["tool_phases"] = dict(
            list(causal["tool_phases"].items())[-MAX_TOOL_IDS:]
        )
        if event == "PreToolUse":
            causal["active_tool"] = tool
        elif causal.get("active_tool") == tool:
            causal["active_tool"] = None
    elif event == "PermissionRequest":
        fingerprint = _tool_fingerprint(payload)
        pending_permissions = causal.get("pending_permissions", [])
        causal["pending_permissions"] = (pending_permissions + [fingerprint])[-MAX_TOOL_IDS:]
    elif event == "PreCompact":
        if causal.get("latest_event") == "PostCompact":
            return False

    causal["latest_event"] = event
    return True


def write_event(payload: Dict[str, Any], state_dir: Path) -> Path:
    state_dir.mkdir(parents=True, exist_ok=True)
    state_dir.chmod(0o700)
    event = str(payload.get("hook_event_name") or "")
    accepted_event = event if event in VALID_EVENTS else "unknown"
    received_at = time.time()
    destination = state_dir / (session_key(payload) + ".json")
    lock_path = state_dir / ".hook-write.lock"
    lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        os.fchmod(lock_fd, 0o600)
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        existing = _read_existing(destination)
        causal = _read_causal_state(existing.get("causal") if existing else None)
        existing_at = None
        existing_valid = (
            existing is not None
            and existing.get("version") in (1, 2)
            and existing.get("state") in VALID_STATES
            and existing.get("event") in VALID_EVENTS.union(("unknown",))
        )
        if existing_valid:
            try:
                existing_at = float(existing.get("event_at", existing.get("updated_at")))
            except (TypeError, ValueError):
                existing_at = None
        incoming_turn = _private_key_hash(payload, "turn_id")
        causal_turn = causal.get("current_turn")
        terminal_late_callback = (
            existing_valid
            and existing.get("terminal") is True
            and accepted_event not in REVIVAL_EVENTS
            and (incoming_turn is None or incoming_turn == causal_turn)
        )
        proposed_causal = {
            "version": causal["version"],
            "current_turn": causal["current_turn"],
            "prior_turns": list(causal["prior_turns"]),
            "tool_phases": dict(causal["tool_phases"]),
            "active_tool": causal["active_tool"],
            "pending_permissions": list(causal["pending_permissions"]),
            "latest_event": causal["latest_event"],
        }
        causally_accepted = _causally_accept(payload, accepted_event, proposed_causal)
        if terminal_late_callback or not causally_accepted:
            rejections = existing.get("rejections") if existing_valid else None
            if not isinstance(rejections, dict):
                rejections = {}
            count = rejections.get("stale_event", 0)
            if not isinstance(count, int) or isinstance(count, bool) or count < 0:
                count = 0
            rejections["stale_event"] = min(MAX_REJECTION_COUNT, count + 1)
            if existing_valid:
                preserved = {
                    "version": 2,
                    "state": existing["state"],
                    "event": existing["event"],
                    "event_at": existing_at,
                    "updated_at": received_at,
                    "terminal": bool(
                        existing.get(
                            "terminal", existing.get("event") in TERMINAL_EVENTS
                        )
                    ),
                    "rejections": rejections,
                    "causal": causal,
                }
                _atomic_write_record(destination, preserved)
            else:
                record = {
                    "version": 2,
                    "state": "idle",
                    "event": "unknown",
                    "event_at": received_at,
                    "updated_at": received_at,
                    "terminal": False,
                    "rejections": rejections,
                    "causal": causal,
                }
                _atomic_write_record(destination, record)
            return destination
        record_state = event_state(payload)
        if proposed_causal["pending_permissions"]:
            record_state = "waiting"
        record = {
            "version": 2,
            "state": record_state,
            "event": accepted_event,
            "event_at": received_at,
            "updated_at": received_at,
            "terminal": accepted_event in TERMINAL_EVENTS,
            "rejections": {},
            "causal": proposed_causal,
        }
        _atomic_write_record(destination, record)
    finally:
        os.close(lock_fd)
    return destination


def main() -> int:
    try:
        payload = json.load(sys.stdin)
        if not isinstance(payload, dict):
            raise ValueError("hook payload must be a JSON object")
        write_event(payload, default_state_dir())
    except Exception as exc:
        # Lifecycle display failures must never block or alter a Codex turn.
        print("Statelet hook warning: {}".format(exc), file=sys.stderr)
    # Stop and UserPromptSubmit require valid JSON output when stdout is used.
    print("{}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
