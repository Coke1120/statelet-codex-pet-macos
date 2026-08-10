#!/usr/bin/env python3
"""Translate Codex lifecycle hooks into small, privacy-safe Codex Pet state files.

Codex sends one JSON object on stdin. This hook deliberately stores only a
hashed session key, the mapped pet state, event name, and timestamp. It never
stores prompts, tool output, transcript paths, or working directories.
"""

import hashlib
import json
import os
import re
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Dict

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
REVIEW_PATTERN = re.compile(
    r"(?<![a-z0-9_])"
    r"(?:review|tests?|pytest|unittest|vitest|jest|lint|ruff|mypy|"
    r"typecheck|git\s+diff(?:\s+--check)?|cargo\s+check|"
    r"(?:npm|pnpm|yarn)\s+(?:run\s+)?check)"
    r"(?![a-z0-9_])"
)


def default_state_dir() -> Path:
    override = os.environ.get("CODEX_PET_STATE_DIR")
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Application Support" / "CodexPet" / "sessions"


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
    raw = str(payload.get("session_id") or "global")
    return hashlib.sha256(raw.encode("utf-8", errors="replace")).hexdigest()[:24]


def write_event(payload: Dict[str, Any], state_dir: Path) -> Path:
    state_dir.mkdir(parents=True, exist_ok=True)
    state_dir.chmod(0o700)
    event = str(payload.get("hook_event_name") or "")
    record = {
        "version": 1,
        "state": event_state(payload),
        "event": event if event in VALID_EVENTS else "unknown",
        "updated_at": time.time(),
    }
    destination = state_dir / (session_key(payload) + ".json")
    fd, temporary = tempfile.mkstemp(prefix=".event-", suffix=".json", dir=str(state_dir))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            fd = -1
            json.dump(record, handle, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
        destination.chmod(0o600)
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
    return destination


def main() -> int:
    try:
        payload = json.load(sys.stdin)
        if not isinstance(payload, dict):
            raise ValueError("hook payload must be a JSON object")
        write_event(payload, default_state_dir())
    except Exception as exc:
        # Lifecycle display failures must never block or alter a Codex turn.
        print("Codex Pet hook warning: {}".format(exc), file=sys.stderr)
    # Stop and UserPromptSubmit require valid JSON output when stdout is used.
    print("{}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
