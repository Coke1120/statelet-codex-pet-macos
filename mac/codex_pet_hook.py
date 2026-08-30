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
import math
import os
import re
import stat
import sys
import time
from pathlib import Path
from typing import Any, Dict, Optional

VALID_STATES = ("idle", "running", "waiting", "review")
VALID_PROVIDERS = ("codex", "grok")
GROK_EVENT_ALIASES = {
    "SessionStart": "SessionStart",
    "sessionStart": "SessionStart",
    "session_start": "SessionStart",
    "SessionEnd": "SessionEnd",
    "sessionEnd": "SessionEnd",
    "session_end": "SessionEnd",
    "UserPromptSubmit": "UserPromptSubmit",
    "userPromptSubmit": "UserPromptSubmit",
    "user_prompt_submit": "UserPromptSubmit",
    "PreToolUse": "PreToolUse",
    "preToolUse": "PreToolUse",
    "pre_tool_use": "PreToolUse",
    "PostToolUse": "PostToolUse",
    "postToolUse": "PostToolUse",
    "post_tool_use": "PostToolUse",
    "PostToolUseFailure": "PostToolUseFailure",
    "postToolUseFailure": "PostToolUseFailure",
    "post_tool_use_failure": "PostToolUseFailure",
    "PermissionDenied": "PermissionDenied",
    "permissionDenied": "PermissionDenied",
    "permission_denied": "PermissionDenied",
    "Stop": "Stop",
    "stop": "Stop",
    "StopFailure": "StopFailure",
    "stopFailure": "StopFailure",
    "stop_failure": "StopFailure",
    "StopCancelled": "StopCancelled",
    "stopCancelled": "StopCancelled",
    "stop_cancelled": "StopCancelled",
    "Notification": "Notification",
    "notification": "Notification",
    "SubagentStart": "SubagentStart",
    "subagentStart": "SubagentStart",
    "subagent_start": "SubagentStart",
    "SubagentStop": "SubagentStop",
    "subagentStop": "SubagentStop",
    "subagent_stop": "SubagentStop",
    "SubagentEnd": "SubagentStop",
    "subagentEnd": "SubagentStop",
    "subagent_end": "SubagentStop",
    "PreCompact": "PreCompact",
    "preCompact": "PreCompact",
    "pre_compact": "PreCompact",
    "PostCompact": "PostCompact",
    "postCompact": "PostCompact",
    "post_compact": "PostCompact",
}
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
TERMINAL_EVENTS = frozenset(("SessionEnd",))
TURN_CLOSING_EVENTS = frozenset(("Stop",))
REVIVAL_EVENTS = frozenset(("SessionStart", "UserPromptSubmit"))
GROK_CONTINUATION_EVENTS = frozenset(
    (
        "PreToolUse",
        "PostToolUse",
        "PermissionRequest",
        "SubagentStart",
        "PreCompact",
    )
)
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
OPAQUE_TARGET_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,511}$")
MAX_RECORD_BYTES = 1_048_576
MAX_HOOK_INPUT_BYTES = 1_048_576
MAX_TOOL_FINGERPRINT_BYTES = 262_144
MAX_REVIEW_COMMAND_BYTES = 16_384
ACTIVATION_TARGET_WRITE_WARNING = (
    "Statelet hook warning: activation target sidecar write failed"
)


def event_category(event: str) -> str:
    """Return a safe, bounded client/category label derived from the event."""
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


def _finite_timestamp(value: Any) -> Optional[float]:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    return parsed if math.isfinite(parsed) else None


def default_state_dir() -> Path:
    override = os.environ.get("STATELET_STATE_DIR") or os.environ.get("CODEX_PET_STATE_DIR")
    if override:
        return Path(override).expanduser()
    return Path.home() / "Library" / "Application Support" / "Statelet" / "sessions"


def agent_provider() -> str:
    """Return the bounded provider selected by the installed hook entry."""
    return "grok" if os.environ.get("STATELET_AGENT_PROVIDER") == "grok" else "codex"


def normalize_payload(
    payload: Dict[str, Any], provider: Optional[str] = None
) -> Dict[str, Any]:
    """Normalize supported provider envelopes without retaining their raw data."""
    selected = provider if provider in VALID_PROVIDERS else agent_provider()
    retained_keys = (
        "hook_event_name",
        "session_id",
        "thread_id",
        "threadId",
        "conversation_id",
        "sessionId",
        "turn_id",
        "tool_name",
        "tool_input",
        "tool_use_id",
        "subagentType",
        "subagent_type",
    )
    normalized = {key: payload[key] for key in retained_keys if key in payload}
    normalized["_statelet_provider"] = selected
    if selected != "grok":
        return normalized

    aliases = {
        "hookEventName": "hook_event_name",
        "sessionId": "session_id",
        "promptId": "turn_id",
        "toolName": "tool_name",
        "toolInput": "tool_input",
        "toolUseId": "tool_use_id",
    }
    for source, destination in aliases.items():
        if destination not in normalized and source in payload:
            normalized[destination] = payload[source]

    raw_event = str(normalized.get("hook_event_name") or "")
    event = GROK_EVENT_ALIASES.get(raw_event, raw_event)
    normalized["hook_event_name"] = event
    if event == "Notification":
        notification_type = str(
            payload.get("notificationType") or payload.get("notification_type") or ""
        )
        if notification_type == "permission_prompt":
            normalized["hook_event_name"] = "PermissionRequest"
        elif notification_type == "idle_prompt":
            normalized["hook_event_name"] = "Stop"
    elif event in ("StopFailure", "StopCancelled"):
        normalized["hook_event_name"] = "Stop"
    elif event in ("PostToolUseFailure", "PermissionDenied"):
        normalized["hook_event_name"] = "PostToolUse"

    background_tasks = payload.get("backgroundTasks")
    if isinstance(background_tasks, list):
        normalized["_statelet_background_active"] = any(
            isinstance(task, dict)
            and str(task.get("status") or "").lower()
            in ("running", "working", "pending", "in_progress")
            for task in background_tasks[:128]
        )
    return normalized


def _is_grok_child_payload(payload: Dict[str, Any]) -> bool:
    if payload.get("_statelet_provider") != "grok":
        return False
    # SubagentStart is emitted by the host but necessarily carries the new
    # child's type. Other event payloads carrying subagentType execute inside
    # the child session and must not enter the host projection.
    if payload.get("hook_event_name") == "SubagentStart":
        return False
    subagent_type = payload.get("subagentType", payload.get("subagent_type"))
    return isinstance(subagent_type, str) and bool(subagent_type.strip())


def event_state(payload: Dict[str, Any]) -> str:
    event = str(payload.get("hook_event_name") or "")
    provider = payload.get("_statelet_provider", "codex")
    if event == "Stop" and payload.get("_statelet_background_active") is True:
        return "running"
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
        if provider == "grok" and event == "PreToolUse":
            if tool_name == "ask_user_question":
                return "waiting"
            if tool_name == "exit_plan_mode":
                return "review"
        searchable = tool_name + " " + _review_command_text(
            payload.get("tool_input")
        ).lower()
        if REVIEW_PATTERN.search(searchable):
            return "review"
        return "running"
    return "idle"


def _review_command_text(tool_input: Any) -> str:
    """Project only executable command fields for activity classification."""
    if not isinstance(tool_input, dict):
        return ""
    fragments = []
    for key in ("command", "cmd", "script"):
        value = tool_input.get(key)
        if isinstance(value, str):
            fragments.append(value)
    arguments = tool_input.get("args")
    if fragments and isinstance(arguments, list):
        fragments.extend(
            str(value)
            for value in arguments[:128]
            if isinstance(value, (str, int, float)) and not isinstance(value, bool)
        )
    return " ".join(fragments).encode(
        "utf-8", errors="replace"
    )[:MAX_REVIEW_COMMAND_BYTES].decode("utf-8", errors="ignore")


def session_key(payload: Dict[str, Any]) -> str:
    raw = "global"
    for key in ("session_id", "thread_id", "threadId", "conversation_id", "sessionId"):
        candidate = payload.get(key)
        if isinstance(candidate, (str, int)) and not isinstance(candidate, bool):
            text = str(candidate).strip()
            if text:
                raw = text
                break
    provider = payload.get("_statelet_provider", "codex")
    if provider == "grok":
        raw = "grok:" + raw
    return hashlib.sha256(raw.encode("utf-8", errors="replace")).hexdigest()[:24]


def _private_key_hash(payload: Dict[str, Any], key: str) -> Optional[str]:
    value = payload.get(key)
    if not isinstance(value, (str, int)) or isinstance(value, bool):
        return None
    text = str(value).strip()
    if not text:
        return None
    return hashlib.sha256(text.encode("utf-8", errors="replace")).hexdigest()[:24]


def _open_state_directory(path: Path) -> int:
    absolute_text = os.path.abspath(path.expanduser())
    if sys.platform == "darwin":
        for alias, canonical in (("/var", "/private/var"), ("/tmp", "/private/tmp")):
            if absolute_text == alias or absolute_text.startswith(alias + "/"):
                absolute_text = canonical + absolute_text[len(alias):]
                break
    absolute = Path(absolute_text)
    descriptor = os.open(
        "/",
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0),
    )
    try:
        for component in absolute.parts[1:]:
            try:
                child = os.open(
                    component,
                    os.O_RDONLY
                    | getattr(os, "O_DIRECTORY", 0)
                    | getattr(os, "O_NOFOLLOW", 0)
                    | getattr(os, "O_CLOEXEC", 0),
                    dir_fd=descriptor,
                )
            except FileNotFoundError:
                try:
                    os.mkdir(component, 0o700, dir_fd=descriptor)
                except FileExistsError:
                    pass
                child = os.open(
                    component,
                    os.O_RDONLY
                    | getattr(os, "O_DIRECTORY", 0)
                    | getattr(os, "O_NOFOLLOW", 0)
                    | getattr(os, "O_CLOEXEC", 0),
                    dir_fd=descriptor,
                )
            os.close(descriptor)
            descriptor = child
        status = os.fstat(descriptor)
        if not stat.S_ISDIR(status.st_mode) or status.st_uid != os.getuid():
            raise OSError("state directory is not owner-controlled")
        os.fchmod(descriptor, 0o700)
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def _read_existing(directory_fd: int, name: str) -> Optional[Dict[str, Any]]:
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
            or before.st_size < 0
            or before.st_size > MAX_RECORD_BYTES
        ):
            return None
        raw = b""
        while len(raw) <= before.st_size:
            chunk = os.read(descriptor, min(65_536, before.st_size + 1 - len(raw)))
            if not chunk:
                break
            raw += chunk
        after = os.fstat(descriptor)
        if (
            before.st_dev != after.st_dev
            or before.st_ino != after.st_ino
            or before.st_size != after.st_size
            or before.st_mtime_ns != after.st_mtime_ns
            or before.st_ctime_ns != after.st_ctime_ns
            or len(raw) != before.st_size
        ):
            return None
        value = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeError, ValueError):
        return None
    finally:
        if descriptor is not None:
            os.close(descriptor)
    return value if isinstance(value, dict) else None


def _atomic_write_record(
    directory_fd: int,
    destination_name: str,
    record: Dict[str, Any],
) -> None:
    fd = -1
    temporary = ""
    try:
        for attempt in range(16):
            temporary = ".event-{}-{}-{}.json".format(
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
            raise OSError("could not reserve hook temporary file")
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            fd = -1
            json.dump(record, handle, separators=(",", ":"), sort_keys=True)
            handle.write("\n")
            handle.flush()
        os.replace(
            temporary,
            destination_name,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
        )
        temporary = ""
        # Publication is complete before best-effort durability work. A hook
        # deadline must not strand the only valid record in a hidden temp file.
        try:
            destination_fd = os.open(
                destination_name,
                os.O_RDONLY
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=directory_fd,
            )
            try:
                os.fsync(destination_fd)
            finally:
                os.close(destination_fd)
            os.fsync(directory_fd)
        except OSError:
            pass
    finally:
        if fd >= 0:
            try:
                os.close(fd)
            except OSError:
                pass
        if temporary:
            try:
                os.unlink(temporary, dir_fd=directory_fd)
            except FileNotFoundError:
                pass


def _activation_target(payload: Dict[str, Any]) -> Optional[str]:
    """Return only a documented opaque Codex activation identifier."""
    for key in ("thread_id", "threadId", "session_id"):
        value = payload.get(key)
        if not isinstance(value, str):
            continue
        candidate = value.strip()
        if OPAQUE_TARGET_PATTERN.fullmatch(candidate) is not None:
            return candidate
    return None


def _publish_activation_target_best_effort(
    directory_fd: int,
    payload: Dict[str, Any],
    identifier: str,
    updated_at: float,
) -> None:
    if payload.get("_statelet_provider", "codex") != "codex":
        return
    if payload.get("hook_event_name") not in ("SessionStart", "UserPromptSubmit"):
        return
    target = _activation_target(payload)
    if target is None:
        return
    try:
        _atomic_write_record(
            directory_fd,
            identifier + ".target.json",
            {
                "version": 1,
                "id": identifier,
                "thread_id": target,
                "updated_at": updated_at,
            },
        )
    except (OSError, TypeError, ValueError):
        # Activation is optional. Never let its private sidecar interfere with
        # the authoritative lifecycle publication for the same hook.
        print(ACTIVATION_TARGET_WRITE_WARNING, file=sys.stderr)


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


def _empty_fence() -> Dict[str, Any]:
    return {
        "version": 1,
        "turn_closed": False,
        "closed_turn": None,
        "session_closed": False,
    }


def _read_fence(value: Any, existing_event: Optional[str]) -> Dict[str, Any]:
    if isinstance(value, dict) and set(value) == {
        "version", "turn_closed", "closed_turn", "session_closed"
    }:
        closed_turn = value.get("closed_turn")
        if (
            value.get("version") == 1
            and isinstance(value.get("turn_closed"), bool)
            and isinstance(value.get("session_closed"), bool)
            and (
                closed_turn is None
                or (
                    isinstance(closed_turn, str)
                    and HASH_PATTERN.fullmatch(closed_turn) is not None
                )
            )
        ):
            return dict(value)
    fence = _empty_fence()
    if existing_event == "Stop":
        fence["turn_closed"] = True
    elif existing_event == "SessionEnd":
        fence["session_closed"] = True
    return fence


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
    encoder = json.JSONEncoder(
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )
    digest = hashlib.sha256()
    encoded_bytes = 0
    for fragment in encoder.iterencode(value):
        encoded = fragment.encode("utf-8", errors="replace")
        encoded_bytes += len(encoded)
        if encoded_bytes > MAX_TOOL_FINGERPRINT_BYTES:
            raise ValueError("hook tool input exceeds the fingerprint size limit")
        digest.update(encoded)
    return digest.hexdigest()[:24]


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
        if payload.get("_statelet_provider") == "grok" and pending_permissions:
            # Grok permission notifications do not carry the eventual tool
            # fingerprint. Any correlated tool callback proves the prompt was
            # resolved, without persisting notification or tool contents.
            causal["pending_permissions"] = []
            pending_permissions = []
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
    elif event == "Stop":
        # Stop closes the current turn for every provider. A permission that
        # was never followed by a tool callback cannot keep the session in the
        # waiting projection after that boundary.
        causal["pending_permissions"] = []
    elif event == "PreCompact":
        if causal.get("latest_event") == "PostCompact":
            return False

    causal["latest_event"] = event
    return True


def _fence_accepts(payload: Dict[str, Any], event: str, fence: Dict[str, Any]) -> bool:
    if event == "SessionStart":
        return True
    if event in TERMINAL_EVENTS:
        return True
    if fence["session_closed"]:
        return event in REVIVAL_EVENTS
    if not fence["turn_closed"]:
        return True
    if (
        payload.get("_statelet_provider") == "grok"
        and event in GROK_CONTINUATION_EVENTS
    ):
        # A Grok Stop hook may itself be blocked. Correlated same-prompt work
        # can therefore resume; the causal tool phases below still reject
        # delayed callbacks that were already observed before the Stop.
        return True
    if event == "Stop":
        incoming_turn = _private_key_hash(payload, "turn_id")
        closed_turn = fence["closed_turn"]
        return incoming_turn is not None and incoming_turn != closed_turn
    if event != "UserPromptSubmit":
        return False
    incoming_turn = _private_key_hash(payload, "turn_id")
    closed_turn = fence["closed_turn"]
    # A turn id proves a distinct prompt. Older payloads without turn ids are
    # treated as a new prompt because UserPromptSubmit is the only safe revival
    # boundary available for those clients.
    return incoming_turn is None or closed_turn is None or incoming_turn != closed_turn


def write_event(payload: Dict[str, Any], state_dir: Path) -> Path:
    payload = normalize_payload(payload)
    identifier = session_key(payload)
    destination_name = identifier + ".json"
    destination = state_dir / destination_name
    if _is_grok_child_payload(payload):
        return destination
    directory_fd = _open_state_directory(state_dir)
    event = str(payload.get("hook_event_name") or "")
    accepted_event = event if event in VALID_EVENTS else "unknown"
    received_at = time.time()
    lock_fd = -1
    try:
        lock_fd = os.open(
            ".hook-write.lock",
            os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=directory_fd,
        )
        lock_status = os.fstat(lock_fd)
        if not stat.S_ISREG(lock_status.st_mode) or lock_status.st_uid != os.getuid():
            raise OSError("hook lock is not owner-controlled")
        os.fchmod(lock_fd, 0o600)
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        existing = _read_existing(directory_fd, destination_name)
        causal = _read_causal_state(existing.get("causal") if existing else None)
        fence = _read_fence(
            existing.get("fence") if existing else None,
            existing.get("event") if existing else None,
        )
        if (
            existing is not None
            and existing.get("event") == "Stop"
            and fence["closed_turn"] is None
        ):
            fence["closed_turn"] = causal.get("current_turn")
        existing_at = None
        existing_started_at = None
        existing_completed_at = None
        existing_category = None
        existing_provider = "codex"
        existing_terminal = False
        existing_valid = (
            existing is not None
            and existing.get("version") in (1, 2)
            and existing.get("state") in VALID_STATES
            and existing.get("event") in VALID_EVENTS.union(("unknown",))
        )
        if existing_valid:
            existing_terminal = existing.get("event") in TERMINAL_EVENTS
            try:
                existing_at = float(existing.get("event_at", existing.get("updated_at")))
            except (TypeError, ValueError):
                existing_at = None
            existing_started_at = _finite_timestamp(
                existing.get("started_at", existing_at)
            )
            existing_completed_at = _finite_timestamp(
                existing.get(
                    "completed_at",
                    existing_at if existing_terminal else None,
                )
            )
            existing_category = existing.get("category")
            if not isinstance(existing_category, str) or existing_category not in {
                "codex", "approval", "tool", "review", "subagent", "activity"
            }:
                existing_category = None
            candidate_provider = existing.get("provider", "codex")
            if candidate_provider in VALID_PROVIDERS:
                existing_provider = candidate_provider
        terminal_late_callback = (
            existing_valid
            and fence["session_closed"]
            and accepted_event not in REVIVAL_EVENTS
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
        fence_accepted = _fence_accepts(payload, accepted_event, fence)
        causally_accepted = fence_accepted and _causally_accept(
            payload, accepted_event, proposed_causal
        )
        if terminal_late_callback or not causally_accepted:
            terminal_reaffirmation = (
                terminal_late_callback
                and accepted_event in TERMINAL_EVENTS
                and causally_accepted
            )
            preserved_causal = (
                proposed_causal
                if accepted_event in TERMINAL_EVENTS and causally_accepted
                else causal
            )
            rejections = existing.get("rejections") if existing_valid else None
            if not isinstance(rejections, dict):
                rejections = {}
            if not terminal_reaffirmation:
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
                        existing_terminal
                    ),
                    "started_at": existing_started_at or existing_at or received_at,
                    "completed_at": existing_completed_at
                    if existing_terminal
                    else None,
                    "category": existing_category or event_category(existing["event"]),
                    "provider": existing_provider,
                    "rejections": rejections,
                    "causal": preserved_causal,
                    "fence": fence,
                }
                _atomic_write_record(directory_fd, destination_name, preserved)
            else:
                record = {
                    "version": 2,
                    "state": "idle",
                    "event": "unknown",
                    "event_at": received_at,
                    "updated_at": received_at,
                    "terminal": False,
                    "started_at": received_at,
                    "completed_at": None,
                    "category": event_category("unknown"),
                    "provider": payload["_statelet_provider"],
                    "rejections": rejections,
                    "causal": preserved_causal,
                    "fence": fence,
                }
                _atomic_write_record(directory_fd, destination_name, record)
            return destination
        if accepted_event == "SessionStart":
            fence = _empty_fence()
        elif accepted_event == "UserPromptSubmit":
            fence["turn_closed"] = False
            fence["closed_turn"] = None
            fence["session_closed"] = False
        elif (
            payload.get("_statelet_provider") == "grok"
            and accepted_event in GROK_CONTINUATION_EVENTS
        ):
            fence["turn_closed"] = False
            fence["closed_turn"] = None
        elif accepted_event in TURN_CLOSING_EVENTS and event_state(payload) == "idle":
            fence["turn_closed"] = True
            fence["closed_turn"] = (
                _private_key_hash(payload, "turn_id")
                or proposed_causal.get("current_turn")
            )
        elif accepted_event in TERMINAL_EVENTS:
            fence["session_closed"] = True
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
            "started_at": (
                received_at
                if (
                    accepted_event == "SessionStart"
                    or not existing_valid
                    or (
                        accepted_event == "UserPromptSubmit"
                        and existing_terminal
                    )
                )
                else existing_started_at or existing_at or received_at
            ),
            "completed_at": (
                received_at if accepted_event in TERMINAL_EVENTS else None
            ),
            "category": event_category(accepted_event),
            "provider": payload["_statelet_provider"],
            "rejections": {},
            "causal": proposed_causal,
            "fence": fence,
        }
        _atomic_write_record(directory_fd, destination_name, record)
        _publish_activation_target_best_effort(
            directory_fd, payload, identifier, received_at
        )
    finally:
        if lock_fd >= 0:
            os.close(lock_fd)
        os.close(directory_fd)
    return destination


def main() -> int:
    try:
        raw = sys.stdin.buffer.read(MAX_HOOK_INPUT_BYTES + 1)
        if len(raw) > MAX_HOOK_INPUT_BYTES:
            raise ValueError("hook payload exceeds the input size limit")
        payload = json.loads(raw.decode("utf-8"))
        if not isinstance(payload, dict):
            raise ValueError("hook payload must be a JSON object")
        write_event(payload, default_state_dir())
    except Exception:
        # Lifecycle display failures must never block or alter a Codex turn.
        print("Statelet hook warning: lifecycle event was not recorded", file=sys.stderr)
    # Stop and UserPromptSubmit require valid JSON output when stdout is used.
    print("{}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
