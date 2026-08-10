#!/usr/bin/env python3
"""Stage an additive, duplicate-free Statelet lifecycle hook configuration."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import stat
from collections import Counter
from pathlib import Path
from typing import Any, Optional, Tuple


EVENTS = (
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
EVENT_MATCHERS = {"SessionStart": "startup|resume|clear|compact"}


def parse_codex_pet_command(command: object) -> Optional[Tuple[str, Path]]:
    if not isinstance(command, str):
        return None
    try:
        parts = shlex.split(command)
    except ValueError:
        return None
    if len(parts) != 2 or Path(parts[1]).name != "codex_pet_hook.py":
        return None
    return command, Path(parts[1]).expanduser()


def is_application_support_hook(path: Path) -> bool:
    return path.is_absolute() and "/Library/Application Support/CodexPet/" in str(path)


def command_interpreter_exists(command: str) -> bool:
    parts = shlex.split(command)
    interpreter = parts[0]
    if "/" in interpreter:
        return os.access(interpreter, os.X_OK) and Path(interpreter).is_file()
    return shutil.which(interpreter) is not None


def is_obsolete_documents_hook(path: Path) -> bool:
    normalized = str(path).replace("\\", "/")
    return "/Documents/" in normalized and normalized.endswith(
        (
            "/codex-pet-dev-board/mac/codex_pet_hook.py",
            "/codex-pet-arduino/mac/codex_pet_hook.py",
        )
    )


def iter_items(hooks: dict[str, Any]):
    for groups in hooks.values():
        if not isinstance(groups, list):
            continue
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                continue
            for item in group["hooks"]:
                if isinstance(item, dict):
                    yield item


def choose_command(hooks: dict[str, Any], python: str, installed_hook: Path) -> str:
    candidates: Counter[str] = Counter()
    candidate_paths: dict[str, Path] = {}
    for item in iter_items(hooks):
        parsed = parse_codex_pet_command(item.get("command"))
        if parsed is None:
            continue
        command, hook_path = parsed
        if (
            is_application_support_hook(hook_path)
            and hook_path.is_file()
            and command_interpreter_exists(command)
        ):
            candidates[command] += 1
            candidate_paths[command] = hook_path
    if candidates:
        # Prefer the shared board runtime when present, then the most complete
        # existing hook coverage. This avoids adding a widget-only duplicate.
        return min(
            candidates,
            key=lambda command: (
                "/mac-widget/" in str(candidate_paths[command]),
                -candidates[command],
                command,
            ),
        )
    return shlex.join([python, str(installed_hook)])


def merge(destination: Path, output: Path, python: str, installed_hook: Path) -> None:
    data: dict[str, Any] = {}
    mode = 0o600
    if destination.exists():
        mode = stat.S_IMODE(destination.stat().st_mode)
        loaded = json.loads(destination.read_text(encoding="utf-8"))
        if not isinstance(loaded, dict):
            raise ValueError("existing hooks file must contain a JSON object")
        data = loaded
    hooks = data.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("existing 'hooks' value must be a JSON object")
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            raise ValueError(f"existing hook event {event!r} must contain a list")

    canonical = choose_command(hooks, python, installed_hook)
    for event in EVENTS:
        groups = hooks.setdefault(event, [])
        expected_matcher = EVENT_MATCHERS.get(event)
        found = False
        for group in groups:
            if not isinstance(group, dict):
                continue
            items = group.get("hooks")
            if not isinstance(items, list):
                continue
            retained = []
            for item in items:
                parsed = parse_codex_pet_command(item.get("command") if isinstance(item, dict) else None)
                if parsed is None:
                    retained.append(item)
                    continue
                command, hook_path = parsed
                recognized = is_application_support_hook(hook_path) or is_obsolete_documents_hook(hook_path)
                matcher_compatible = not group.get("matcher") or group.get("matcher") == expected_matcher
                if recognized and matcher_compatible:
                    if command == canonical and not found:
                        retained.append(item)
                        found = True
                    # Drop duplicate installed commands and exact obsolete
                    # Documents/repository commands for this lifecycle event.
                    continue
                retained.append(item)
            group["hooks"] = retained
        if not found:
            group: dict[str, Any] = {
                "hooks": [{"type": "command", "command": canonical, "timeout": 3}]
            }
            if expected_matcher is not None:
                group["matcher"] = expected_matcher
            groups.append(group)

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")
    os.chmod(output, mode)


def remove_widget_hook(destination: Path, output: Path, widget_hook: Path) -> None:
    """Remove only the widget command, migrating to a valid shared hook."""
    if not destination.exists():
        raise ValueError("hooks destination does not exist")
    mode = stat.S_IMODE(destination.stat().st_mode)
    loaded = json.loads(destination.read_text(encoding="utf-8"))
    if not isinstance(loaded, dict):
        raise ValueError("existing hooks file must contain a JSON object")
    hooks = loaded.get("hooks")
    if not isinstance(hooks, dict):
        raise ValueError("existing 'hooks' value must be a JSON object")

    widget_hook = widget_hook.expanduser()
    shared: Counter[str] = Counter()
    shared_paths: dict[str, Path] = {}
    for item in iter_items(hooks):
        parsed = parse_codex_pet_command(item.get("command"))
        if parsed is None:
            continue
        command, hook_path = parsed
        if hook_path == widget_hook:
            continue
        if (
            is_application_support_hook(hook_path)
            and hook_path.is_file()
            and command_interpreter_exists(command)
        ):
            shared[command] += 1
            shared_paths[command] = hook_path
    replacement = None
    if shared:
        replacement = min(
            shared,
            key=lambda command: (
                "/runtime/" not in str(shared_paths[command]),
                -shared[command],
                command,
            ),
        )

    for event, groups in hooks.items():
        if not isinstance(groups, list):
            raise ValueError(f"existing hook event {event!r} must contain a list")
        found_replacement = False
        retained_groups = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                retained_groups.append(group)
                continue
            retained_items = []
            for item in group["hooks"]:
                parsed = parse_codex_pet_command(item.get("command") if isinstance(item, dict) else None)
                if parsed is not None and parsed[1] == widget_hook:
                    continue
                if parsed is not None and replacement is not None and parsed[0] == replacement:
                    found_replacement = True
                retained_items.append(item)
            group["hooks"] = retained_items
            if retained_items or set(group) - {"hooks", "matcher"}:
                retained_groups.append(group)
        if replacement is not None and event in EVENTS and not found_replacement:
            group = {"hooks": [{"type": "command", "command": replacement, "timeout": 3}]}
            if event in EVENT_MATCHERS:
                group["matcher"] = EVENT_MATCHERS[event]
            retained_groups.append(group)
        hooks[event] = retained_groups

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as handle:
        json.dump(loaded, handle, indent=2)
        handle.write("\n")
    os.chmod(output, mode)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--python", required=True)
    parser.add_argument("--hook-script", type=Path, required=True)
    parser.add_argument("--remove-widget-hook", action="store_true")
    args = parser.parse_args()
    if args.remove_widget_hook:
        remove_widget_hook(args.destination, args.output, args.hook_script)
    else:
        merge(args.destination, args.output, args.python, args.hook_script)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
