#!/usr/bin/env python3
"""Stage an additive, duplicate-free Statelet lifecycle hook configuration."""

from __future__ import annotations

import argparse
import hashlib
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
MAX_MIGRATION_FILES = 100_000
MAX_MIGRATION_BYTES = 32 * 1024 * 1024 * 1024


def safe_tree_digest(root: Path) -> str:
    """Hash one bounded regular-file tree without following links."""
    if root.is_symlink():
        raise ValueError(f"migration source contains a symbolic link: {root.name}")
    digest = hashlib.sha256()
    file_count = 0
    byte_count = 0
    paths = [root] if not root.is_dir() else sorted(root.rglob("*"))
    for path in paths:
        status = path.lstat()
        relative = "." if path == root else path.relative_to(root).as_posix()
        if stat.S_ISLNK(status.st_mode):
            raise ValueError(f"migration source contains a symbolic link: {relative}")
        if stat.S_ISDIR(status.st_mode):
            digest.update(b"D\0" + relative.encode() + b"\0")
            continue
        if not stat.S_ISREG(status.st_mode):
            raise ValueError(f"migration source contains a special file: {relative}")
        file_count += 1
        byte_count += status.st_size
        if file_count > MAX_MIGRATION_FILES or byte_count > MAX_MIGRATION_BYTES:
            raise ValueError("migration source exceeds the safe size limit")
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            final = os.fstat(descriptor)
            if not stat.S_ISREG(final.st_mode) or (final.st_dev, final.st_ino) != (status.st_dev, status.st_ino):
                raise ValueError(f"migration source changed during validation: {relative}")
            digest.update(b"F\0" + relative.encode() + b"\0")
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
            if os.fstat(descriptor).st_size != status.st_size:
                raise ValueError(f"migration source changed during validation: {relative}")
        finally:
            os.close(descriptor)
    return digest.hexdigest()


def safe_copy_tree(source: Path, destination: Path) -> None:
    expected = safe_tree_digest(source)
    if destination.exists():
        raise ValueError("migration staging destination already exists")
    if source.is_dir():
        shutil.copytree(source, destination, symlinks=False)
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination, follow_symlinks=False)
    if safe_tree_digest(destination) != expected:
        shutil.rmtree(destination, ignore_errors=True) if destination.is_dir() else destination.unlink(missing_ok=True)
        raise ValueError("migration copy did not validate")


def parse_statelet_command(command: object) -> Optional[Tuple[str, Path]]:
    if not isinstance(command, str):
        return None
    try:
        parts = shlex.split(command)
    except ValueError:
        return None
    if len(parts) != 2 or Path(parts[1]).name not in {"statelet_hook.py", "codex_pet_hook.py"}:
        return None
    return command, Path(parts[1]).expanduser()


def is_application_support_hook(path: Path) -> bool:
    normalized = str(path).replace("\\", "/")
    return path.is_absolute() and any(
        marker in normalized
        for marker in (
            "/Library/Application Support/Statelet/",
            "/Library/Application Support/CodexPet/",
        )
    )


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
        parsed = parse_statelet_command(item.get("command"))
        if parsed is None:
            continue
        command, hook_path = parsed
        if (
            is_application_support_hook(hook_path)
            and hook_path.is_file()
            and command_interpreter_exists(command)
            and "/Library/Application Support/Statelet/" in str(hook_path).replace("\\", "/")
            and "/Statelet/python/" not in str(hook_path).replace("\\", "/")
        ):
            candidates[command] += 1
            candidate_paths[command] = hook_path
    if candidates:
        # Reuse only canonical Statelet shared runtimes. Legacy CodexPet paths
        # point at the support tree retained for rollback; choosing one here
        # would leave a fresh installation dependent on compatibility data.
        return min(
            candidates,
            key=lambda command: (
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
                parsed = parse_statelet_command(item.get("command") if isinstance(item, dict) else None)
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
        parsed = parse_statelet_command(item.get("command"))
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
                parsed = parse_statelet_command(item.get("command") if isinstance(item, dict) else None)
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
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--python")
    parser.add_argument("--hook-script", type=Path)
    parser.add_argument("--remove-widget-hook", action="store_true")
    parser.add_argument("--safe-tree-digest", type=Path)
    parser.add_argument("--safe-copy-source", type=Path)
    parser.add_argument("--safe-copy-destination", type=Path)
    args = parser.parse_args()
    if args.safe_tree_digest is not None:
        print(safe_tree_digest(args.safe_tree_digest))
        return 0
    if args.safe_copy_source is not None or args.safe_copy_destination is not None:
        if args.safe_copy_source is None or args.safe_copy_destination is None:
            parser.error("safe copy requires both source and destination")
        safe_copy_tree(args.safe_copy_source, args.safe_copy_destination)
        return 0
    if None in (args.destination, args.output, args.python, args.hook_script):
        parser.error("hook merge requires destination, output, python, and hook-script")
    if args.remove_widget_hook:
        remove_widget_hook(args.destination, args.output, args.hook_script)
    else:
        merge(args.destination, args.output, args.python, args.hook_script)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
