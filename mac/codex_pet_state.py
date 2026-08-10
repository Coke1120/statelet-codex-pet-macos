#!/usr/bin/env python3
"""Privacy-safe Codex lifecycle state validation and aggregation."""

import json
import math
import os
import re
import time
from pathlib import Path
from typing import Any, Iterable, List, Optional, Tuple


VALID_STATES = ("idle", "running", "waiting", "review")
STATE_PRIORITY = {"idle": 0, "running": 1, "review": 2, "waiting": 3}
HOOK_RECORD_NAME = re.compile(r"^[0-9a-f]{24}\.json$")
HOOK_RECORD_KEYS = frozenset(("version", "state", "event", "updated_at"))
DEFAULT_ACTIVE_TTL = 900.0
MAX_FUTURE_SKEW = 60.0


def default_state_dir() -> Path:
    override = os.environ.get("CODEX_PET_STATE_DIR")
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Application Support" / "CodexPet" / "sessions"


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
    current = time.time() if now is None else now
    active: List[Tuple[str, float]] = []
    if not state_dir.exists():
        return active
    for path in state_dir.glob("*.json"):
        if HOOK_RECORD_NAME.fullmatch(path.name) is None:
            continue
        identity = _file_identity(path)
        if identity is None:
            continue
        try:
            record: Any = json.loads(path.read_text(encoding="utf-8"))
            if (
                not isinstance(record, dict)
                or set(record) != HOOK_RECORD_KEYS
                or record.get("version") != 1
                or not isinstance(record.get("event"), str)
            ):
                continue
            state = record["state"]
            updated_at = float(record["updated_at"])
        except OSError:
            continue
        except (ValueError, TypeError, KeyError):
            continue
        if state not in VALID_STATES or not math.isfinite(updated_at):
            _prune_if_unchanged(path, identity)
            continue
        age = current - updated_at
        if age < -MAX_FUTURE_SKEW or age > active_ttl:
            _prune_if_unchanged(path, identity)
            continue
        active.append((state, updated_at))
    return active


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
