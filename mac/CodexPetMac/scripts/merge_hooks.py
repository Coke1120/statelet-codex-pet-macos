#!/usr/bin/env python3
"""Stage an additive, duplicate-free Statelet lifecycle hook configuration."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import shlex
import shutil
import stat
from collections import Counter
from pathlib import Path
from typing import Any, Optional, Tuple


CODEX_EVENTS = (
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
CODEX_EVENT_MATCHERS = {"SessionStart": "startup|resume|clear|compact"}
GROK_EVENTS = (
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PostToolUseFailure",
    "PermissionDenied",
    "PreCompact",
    "PostCompact",
    "SubagentStart",
    "SubagentStop",
    "Stop",
    "StopFailure",
)
GROK_NOTIFICATION_MATCHERS = ("permission_prompt", "idle_prompt")
MAX_MIGRATION_FILES = 100_000
MAX_MIGRATION_BYTES = 32 * 1024 * 1024 * 1024
MAX_HOOK_CONFIG_BYTES = 16 * 1024 * 1024


def read_hook_config(path: Path, *, required: bool = False) -> tuple[Optional[dict[str, Any]], int]:
    """Read one owned, stable regular config without following its final link."""
    try:
        before = path.lstat()
    except FileNotFoundError:
        if required:
            raise ValueError("hooks destination does not exist")
        return None, 0o600
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_uid != os.getuid()
        or before.st_nlink != 1
        or before.st_size > MAX_HOOK_CONFIG_BYTES
    ):
        raise ValueError("existing hooks file is unsafe")
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    if hasattr(os, "O_NONBLOCK"):
        flags |= os.O_NONBLOCK
    descriptor = os.open(path, flags)
    fields = (
        "st_dev",
        "st_ino",
        "st_mode",
        "st_uid",
        "st_nlink",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    try:
        opened = os.fstat(descriptor)
        if any(getattr(before, field) != getattr(opened, field) for field in fields):
            raise ValueError("existing hooks file changed during validation")
        content = bytearray()
        while True:
            chunk = os.read(descriptor, min(1024 * 1024, MAX_HOOK_CONFIG_BYTES + 1 - len(content)))
            if not chunk:
                break
            content.extend(chunk)
            if len(content) > MAX_HOOK_CONFIG_BYTES:
                raise ValueError("existing hooks file exceeds the size limit")
        final = os.fstat(descriptor)
        if any(getattr(opened, field) != getattr(final, field) for field in fields):
            raise ValueError("existing hooks file changed while reading")
    finally:
        os.close(descriptor)
    rebound = path.lstat()
    if any(getattr(final, field) != getattr(rebound, field) for field in fields):
        raise ValueError("existing hooks file changed after reading")
    try:
        loaded = json.loads(content.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("existing hooks file is not valid JSON") from error
    if not isinstance(loaded, dict):
        raise ValueError("existing hooks file must contain a JSON object")
    return loaded, stat.S_IMODE(final.st_mode)


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
            "/codex-pet-dev-board/mac/statelet_hook.py",
            "/codex-pet-arduino/mac/codex_pet_hook.py",
            "/codex-pet-arduino/mac/statelet_hook.py",
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


def registrations(provider: str) -> tuple[tuple[str, Optional[str]], ...]:
    if provider == "codex":
        return tuple((event, CODEX_EVENT_MATCHERS.get(event)) for event in CODEX_EVENTS)
    if provider == "grok":
        return tuple((event, None) for event in GROK_EVENTS) + tuple(
            ("Notification", matcher) for matcher in GROK_NOTIFICATION_MATCHERS
        )
    raise ValueError(f"unsupported hook provider: {provider}")


def managed_handler(command: str, provider: str) -> dict[str, Any]:
    handler: dict[str, Any] = {"type": "command", "command": command, "timeout": 3}
    if provider == "grok":
        handler["env"] = {"STATELET_AGENT_PROVIDER": "grok"}
    return handler


def is_canonical_handler(item: object, command: str, provider: str) -> bool:
    if not isinstance(item, dict) or item.get("command") != command:
        return False
    if provider == "grok":
        return item.get("env") == {"STATELET_AGENT_PROVIDER": "grok"}
    return "env" not in item or item.get("env") in ({}, None)


def matcher_is_compatible(provider: str, event: str, actual: object, expected: Optional[str]) -> bool:
    if provider == "grok":
        # Grok Notification matchers distinguish permission and idle signals.
        # Never retain a broad, matcher-free Statelet notification handler.
        return actual == expected
    return not actual or actual == expected


def matcher_is_registered(provider: str, event: str, matcher: object) -> bool:
    return any(
        registered_event == event and expected_matcher == matcher
        for registered_event, expected_matcher in registrations(provider)
    )


def merge(
    destination: Path,
    output: Path,
    python: str,
    installed_hook: Path,
    provider: str,
) -> None:
    loaded, mode = read_hook_config(destination)
    data: dict[str, Any] = loaded if loaded is not None else {}
    hooks = data.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("existing 'hooks' value must be a JSON object")
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            raise ValueError(f"existing hook event {event!r} must contain a list")

    canonical = choose_command(hooks, python, installed_hook)
    for event, expected_matcher in registrations(provider):
        groups = hooks.setdefault(event, [])
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
                matcher_compatible = matcher_is_compatible(
                    provider,
                    event,
                    group.get("matcher"),
                    expected_matcher,
                )
                if recognized and matcher_compatible:
                    if is_canonical_handler(item, canonical, provider) and not found:
                        retained.append(managed_handler(canonical, provider))
                        found = True
                    # Drop duplicate installed commands and exact obsolete
                    # Documents/repository commands for this lifecycle event.
                    continue
                if (
                    provider == "grok"
                    and recognized
                    and not matcher_is_registered(provider, event, group.get("matcher"))
                ):
                    # This dedicated Grok config is Statelet-owned. Remove
                    # obsolete broad or unsupported Statelet registrations,
                    # while preserving every unrelated handler and key.
                    continue
                retained.append(item)
            group["hooks"] = retained
        if not found:
            group: dict[str, Any] = {"hooks": [managed_handler(canonical, provider)]}
            if expected_matcher is not None:
                group["matcher"] = expected_matcher
            groups.append(group)

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")
    os.chmod(output, mode)


def remove_widget_hook(
    destination: Path,
    output: Path,
    widget_hook: Path,
    provider: str,
) -> None:
    """Remove only the widget command, migrating to a valid shared hook."""
    loaded, mode = read_hook_config(destination, required=True)
    assert loaded is not None
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
    if shared and provider == "codex":
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
                recognized_grok_handler = (
                    provider == "grok"
                    and parsed is not None
                    and (
                        is_application_support_hook(parsed[1])
                        or is_obsolete_documents_hook(parsed[1])
                    )
                )
                if parsed is not None and (parsed[1] == widget_hook or recognized_grok_handler):
                    continue
                if parsed is not None and replacement is not None and parsed[0] == replacement:
                    found_replacement = True
                retained_items.append(item)
            group["hooks"] = retained_items
            if retained_items or set(group) - {"hooks", "matcher"}:
                retained_groups.append(group)
        replacement_matcher = next(
            (matcher for registered_event, matcher in registrations(provider) if registered_event == event),
            None,
        )
        registered_event = any(name == event for name, _ in registrations(provider))
        if replacement is not None and registered_event and not found_replacement:
            group = {"hooks": [managed_handler(replacement, provider)]}
            if replacement_matcher is not None:
                group["matcher"] = replacement_matcher
            retained_groups.append(group)
        hooks[event] = retained_groups

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as handle:
        json.dump(loaded, handle, indent=2)
        handle.write("\n")
    os.chmod(output, mode)


def quiesce_managed_hooks(destination: Path, output: Path) -> float:
    """Stage a config without Statelet handlers and return its drain timeout."""
    loaded, mode = read_hook_config(destination)
    data: dict[str, Any] = loaded if loaded is not None else {}
    hooks = data.get("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("existing 'hooks' value must be a JSON object")

    maximum_timeout = 0.0
    for event, groups in list(hooks.items()):
        if not isinstance(groups, list):
            continue
        retained_groups = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                retained_groups.append(group)
                continue
            retained_items = []
            for item in group["hooks"]:
                parsed = parse_statelet_command(item.get("command") if isinstance(item, dict) else None)
                if parsed is None:
                    retained_items.append(item)
                    continue
                _, hook_path = parsed
                if not (is_application_support_hook(hook_path) or is_obsolete_documents_hook(hook_path)):
                    retained_items.append(item)
                    continue
                raw_timeout = item.get("timeout", 10)
                try:
                    timeout = float(raw_timeout)
                except (TypeError, ValueError) as error:
                    raise ValueError("unsupported managed hook timeout") from error
                if not math.isfinite(timeout) or not 0 <= timeout <= 60:
                    raise ValueError("unsupported managed hook timeout")
                maximum_timeout = max(maximum_timeout, timeout)
            replacement = dict(group)
            replacement["hooks"] = retained_items
            if retained_items or set(replacement) - {"hooks", "matcher"}:
                retained_groups.append(replacement)
        hooks[event] = retained_groups

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")
    os.chmod(output, mode)
    return maximum_timeout + 0.1 if maximum_timeout else 0.0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--python")
    parser.add_argument("--hook-script", type=Path)
    parser.add_argument("--provider", choices=("codex", "grok"), default="codex")
    parser.add_argument("--remove-widget-hook", action="store_true")
    parser.add_argument("--quiesce-managed-hooks", action="store_true")
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
    if args.quiesce_managed_hooks:
        if args.destination is None or args.output is None:
            parser.error("hook quiescence requires destination and output")
        print(quiesce_managed_hooks(args.destination, args.output))
        return 0
    if None in (args.destination, args.output, args.python, args.hook_script):
        parser.error("hook merge requires destination, output, python, and hook-script")
    if args.remove_widget_hook:
        remove_widget_hook(args.destination, args.output, args.hook_script, args.provider)
    else:
        merge(args.destination, args.output, args.python, args.hook_script, args.provider)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
