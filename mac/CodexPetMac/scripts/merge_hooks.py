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
MAX_MIGRATION_ENTRIES = 100_000
MAX_MIGRATION_BYTES = 32 * 1024 * 1024 * 1024
MAX_HOOK_CONFIG_BYTES = 16 * 1024 * 1024
TREE_DIGEST_ALGORITHM = "statelet-safe-tree-v2"
LEGACY_TREE_DIGEST_ALGORITHM = "statelet-unframed-v1"
TREE_DIGEST_ALGORITHMS = {TREE_DIGEST_ALGORITHM, LEGACY_TREE_DIGEST_ALGORITHM}
_TREE_DIGEST_DOMAIN = b"STATELET-SAFE-TREE-DIGEST\0v2\0"
_HOOK_ATTESTATION_VERSION = 2


def _new_tree_digest(algorithm: str = TREE_DIGEST_ALGORITHM) -> Any:
    if algorithm == TREE_DIGEST_ALGORITHM:
        return hashlib.sha256(_TREE_DIGEST_DOMAIN)
    if algorithm == LEGACY_TREE_DIGEST_ALGORITHM:
        return hashlib.sha256()
    raise ValueError("unsupported tree digest algorithm")


def _tree_digest_field(digest: Any, tag: bytes, value: bytes) -> None:
    """Append one tagged, length-framed canonical tree-record field."""
    if len(tag) != 1:
        raise ValueError("tree digest field tags must be one byte")
    digest.update(tag)
    digest.update(len(value).to_bytes(8, "big"))
    digest.update(value)


def _begin_tree_digest_entry(
    digest: Any,
    *,
    entry_type: bytes,
    relative: str,
    mode: int,
    content_length: Optional[int] = None,
    algorithm: str = TREE_DIGEST_ALGORITHM,
) -> None:
    """Begin one injectively framed file or directory record."""
    if entry_type not in {b"file", b"directory"}:
        raise ValueError("unsupported tree digest entry type")
    if algorithm == LEGACY_TREE_DIGEST_ALGORITHM:
        if entry_type == b"directory" and relative == ".":
            return
        marker = b"F" if entry_type == b"file" else b"D"
        digest.update(marker + b"\0" + relative.encode() + b"\0")
        return
    if algorithm != TREE_DIGEST_ALGORITHM:
        raise ValueError("unsupported tree digest algorithm")
    digest.update(b"E")
    _tree_digest_field(digest, b"T", entry_type)
    _tree_digest_field(digest, b"P", os.fsencode(relative))
    _tree_digest_field(digest, b"M", stat.S_IMODE(mode).to_bytes(4, "big"))
    if content_length is None:
        digest.update(b"Z")
        return
    if content_length < 0:
        raise ValueError("tree digest content length cannot be negative")
    digest.update(b"C")
    digest.update(content_length.to_bytes(8, "big"))


def _finish_tree_digest_file(
    digest: Any,
    algorithm: str = TREE_DIGEST_ALGORITHM,
) -> None:
    if algorithm == TREE_DIGEST_ALGORITHM:
        digest.update(b"Z")
    elif algorithm != LEGACY_TREE_DIGEST_ALGORITHM:
        raise ValueError("unsupported tree digest algorithm")


def read_hook_config(
    path: Path,
    *,
    required: bool = False,
    owner_private: bool = False,
) -> tuple[Optional[dict[str, Any]], int, dict[str, Any]]:
    """Read one owned, stable regular config without following its final link."""
    try:
        before = path.lstat()
    except FileNotFoundError:
        if required:
            raise ValueError("hooks destination does not exist")
        return None, 0o600, {
            "version": _HOOK_ATTESTATION_VERSION,
            "digest_algorithm": TREE_DIGEST_ALGORITHM,
            "exists": False,
        }
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_uid != os.getuid()
        or before.st_nlink != 1
        or before.st_size > MAX_HOOK_CONFIG_BYTES
        or (owner_private and stat.S_IMODE(before.st_mode) != 0o600)
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
    digest = _new_tree_digest()
    _begin_tree_digest_entry(
        digest,
        entry_type=b"file",
        relative=".",
        mode=final.st_mode,
        content_length=final.st_size,
    )
    digest.update(content)
    _finish_tree_digest_file(digest)
    return loaded, stat.S_IMODE(final.st_mode), {
        "version": _HOOK_ATTESTATION_VERSION,
        "digest_algorithm": TREE_DIGEST_ALGORITHM,
        "exists": True,
        "digest": digest.hexdigest(),
        "entry": [getattr(final, field) for field in fields],
    }


def write_attestation(path: Path, attestation: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(attestation, handle, sort_keys=True, separators=(",", ":"))
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(path, 0o600)


def attest_private_directories(paths: list[Path]) -> list[dict[str, Any]]:
    attestations = []
    fields = ("st_dev", "st_ino", "st_mode", "st_uid")
    for path in paths:
        if not os.path.lexists(path):
            attestations.append({"path": str(path), "exists": False})
            continue
        status = path.lstat()
        if (
            not stat.S_ISDIR(status.st_mode)
            or stat.S_ISLNK(status.st_mode)
            or status.st_uid != os.getuid()
            or stat.S_IMODE(status.st_mode) != 0o700
        ):
            raise ValueError("Grok hook directory is not owner-private")
        attestations.append(
            {"path": str(path), "exists": True, "entry": [getattr(status, field) for field in fields]}
        )
    return attestations


_TREE_STABILITY_FIELDS = (
    "st_dev",
    "st_ino",
    "st_mode",
    "st_uid",
    "st_gid",
    "st_nlink",
    "st_size",
    "st_mtime_ns",
    "st_ctime_ns",
)


def _same_tree_entry(left: os.stat_result, right: os.stat_result) -> bool:
    return all(getattr(left, field) == getattr(right, field) for field in _TREE_STABILITY_FIELDS)


def _tree_open_flags(*, directory: bool) -> int:
    flags = os.O_RDONLY
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    if directory and hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    if not directory and hasattr(os, "O_NONBLOCK"):
        flags |= os.O_NONBLOCK
    return flags


def _open_stable_tree_root(root: Path) -> tuple[int, os.stat_result, bool]:
    before = root.lstat()
    directory = stat.S_ISDIR(before.st_mode)
    if stat.S_ISLNK(before.st_mode):
        raise ValueError(f"migration source contains a symbolic link: {root.name}")
    if not directory and not stat.S_ISREG(before.st_mode):
        raise ValueError("migration source contains a special file: .")
    descriptor = os.open(root, _tree_open_flags(directory=directory))
    opened = os.fstat(descriptor)
    if not _same_tree_entry(before, opened):
        os.close(descriptor)
        raise ValueError("migration source changed during validation: .")
    return descriptor, opened, directory


def _write_all(descriptor: int, content: bytes) -> None:
    view = memoryview(content)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise OSError("short write while staging migration source")
        view = view[written:]


def _copy_or_digest_tree(
    source_descriptor: int,
    source_status: os.stat_result,
    *,
    source_is_directory: bool,
    digest: Any,
    budget: dict[str, int],
    relative: str,
    destination_descriptor: Optional[int],
    algorithm: str,
) -> os.stat_result:
    if not source_is_directory:
        budget["entries"] += 1
        budget["files"] += 1
        budget["bytes"] += source_status.st_size
        if (
            budget["entries"] > MAX_MIGRATION_ENTRIES
            or budget["files"] > MAX_MIGRATION_FILES
            or budget["bytes"] > MAX_MIGRATION_BYTES
        ):
            raise ValueError("migration source exceeds the safe size limit")
        _begin_tree_digest_entry(
            digest,
            entry_type=b"file",
            relative=relative,
            mode=source_status.st_mode,
            content_length=source_status.st_size,
            algorithm=algorithm,
        )
        copied = 0
        while True:
            chunk = os.read(
                source_descriptor,
                min(1024 * 1024, max(1, source_status.st_size + 1 - copied)),
            )
            if not chunk:
                break
            copied += len(chunk)
            if copied > source_status.st_size:
                raise ValueError(f"migration source changed during validation: {relative}")
            digest.update(chunk)
            if destination_descriptor is not None:
                _write_all(destination_descriptor, chunk)
        if copied != source_status.st_size:
            raise ValueError(f"migration source changed during validation: {relative}")
        _finish_tree_digest_file(digest, algorithm)
        final = os.fstat(source_descriptor)
        if not _same_tree_entry(source_status, final):
            raise ValueError(f"migration source changed during validation: {relative}")
        if destination_descriptor is not None:
            os.fchmod(destination_descriptor, stat.S_IMODE(source_status.st_mode))
            os.fsync(destination_descriptor)
        return final

    _begin_tree_digest_entry(
        digest,
        entry_type=b"directory",
        relative=relative,
        mode=source_status.st_mode,
        algorithm=algorithm,
    )
    names = sorted(os.listdir(source_descriptor))
    for name in names:
        child_relative = name if relative == "." else f"{relative}/{name}"
        before = os.stat(name, dir_fd=source_descriptor, follow_symlinks=False)
        if stat.S_ISLNK(before.st_mode):
            raise ValueError(f"migration source contains a symbolic link: {child_relative}")
        child_is_directory = stat.S_ISDIR(before.st_mode)
        if not child_is_directory and not stat.S_ISREG(before.st_mode):
            raise ValueError(f"migration source contains a special file: {child_relative}")
        if child_is_directory:
            budget["entries"] += 1
            if budget["entries"] > MAX_MIGRATION_ENTRIES:
                raise ValueError("migration source exceeds the safe size limit")
        child_source = os.open(
            name,
            _tree_open_flags(directory=child_is_directory),
            dir_fd=source_descriptor,
        )
        child_destination: Optional[int] = None
        try:
            opened = os.fstat(child_source)
            if not _same_tree_entry(before, opened):
                raise ValueError(f"migration source changed during validation: {child_relative}")
            if child_is_directory:
                if destination_descriptor is not None:
                    os.mkdir(name, mode=0o700, dir_fd=destination_descriptor)
                    child_destination = os.open(
                        name,
                        _tree_open_flags(directory=True),
                        dir_fd=destination_descriptor,
                    )
                child_final = _copy_or_digest_tree(
                    child_source,
                    opened,
                    source_is_directory=True,
                    digest=digest,
                    budget=budget,
                    relative=child_relative,
                    destination_descriptor=child_destination,
                    algorithm=algorithm,
                )
                if child_destination is not None:
                    os.fchmod(child_destination, stat.S_IMODE(opened.st_mode))
                    os.fsync(child_destination)
            else:
                if destination_descriptor is not None:
                    destination_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
                    if hasattr(os, "O_CLOEXEC"):
                        destination_flags |= os.O_CLOEXEC
                    if hasattr(os, "O_NOFOLLOW"):
                        destination_flags |= os.O_NOFOLLOW
                    child_destination = os.open(
                        name,
                        destination_flags,
                        stat.S_IMODE(opened.st_mode),
                        dir_fd=destination_descriptor,
                    )
                child_final = _copy_or_digest_tree(
                    child_source,
                    opened,
                    source_is_directory=False,
                    digest=digest,
                    budget=budget,
                    relative=child_relative,
                    destination_descriptor=child_destination,
                    algorithm=algorithm,
                )
            rebound = os.stat(name, dir_fd=source_descriptor, follow_symlinks=False)
            if not _same_tree_entry(child_final, rebound):
                raise ValueError(f"migration source changed during validation: {child_relative}")
        finally:
            if child_destination is not None:
                os.close(child_destination)
            os.close(child_source)
    final = os.fstat(source_descriptor)
    if not _same_tree_entry(source_status, final):
        raise ValueError(f"migration source changed during validation: {relative}")
    return final


def safe_tree_digest(
    root: Path,
    *,
    algorithm: str = TREE_DIGEST_ALGORITHM,
) -> str:
    """Hash one bounded stable regular-file tree without following links."""
    if algorithm not in TREE_DIGEST_ALGORITHMS:
        raise ValueError("unsupported tree digest algorithm")
    descriptor, opened, directory = _open_stable_tree_root(root)
    digest = _new_tree_digest(algorithm)
    try:
        final = _copy_or_digest_tree(
            descriptor,
            opened,
            source_is_directory=directory,
            digest=digest,
            budget={"entries": 0, "files": 0, "bytes": 0},
            relative=".",
            destination_descriptor=None,
            algorithm=algorithm,
        )
    finally:
        os.close(descriptor)
    rebound = root.lstat()
    if not _same_tree_entry(final, rebound):
        raise ValueError("migration source changed after validation: .")
    return digest.hexdigest()


def safe_copy_tree(source: Path, destination: Path) -> None:
    """Copy one stable tree from no-follow descriptors into a private staging path."""
    if os.path.lexists(destination):
        raise ValueError("migration staging destination already exists")
    source_descriptor, source_opened, source_is_directory = _open_stable_tree_root(source)
    digest = _new_tree_digest()
    created = False
    destination_descriptor: Optional[int] = None
    try:
        destination.parent.mkdir(parents=True, exist_ok=True)
        if source_is_directory:
            destination.mkdir(mode=0o700)
            created = True
            destination_descriptor = os.open(destination, _tree_open_flags(directory=True))
        else:
            destination_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            if hasattr(os, "O_CLOEXEC"):
                destination_flags |= os.O_CLOEXEC
            if hasattr(os, "O_NOFOLLOW"):
                destination_flags |= os.O_NOFOLLOW
            destination_descriptor = os.open(
                destination,
                destination_flags,
                stat.S_IMODE(source_opened.st_mode),
            )
            created = True
        source_final = _copy_or_digest_tree(
            source_descriptor,
            source_opened,
            source_is_directory=source_is_directory,
            digest=digest,
            budget={"entries": 0, "files": 0, "bytes": 0},
            relative=".",
            destination_descriptor=destination_descriptor,
            algorithm=TREE_DIGEST_ALGORITHM,
        )
        if source_is_directory:
            os.fchmod(destination_descriptor, stat.S_IMODE(source_opened.st_mode))
            os.fsync(destination_descriptor)
        source_rebound = source.lstat()
        if not _same_tree_entry(source_final, source_rebound):
            raise ValueError("migration source changed after validation: .")
        expected = digest.hexdigest()
    except Exception:
        if destination_descriptor is not None:
            os.close(destination_descriptor)
            destination_descriptor = None
        if created:
            if destination.is_dir() and not destination.is_symlink():
                shutil.rmtree(destination, ignore_errors=True)
            else:
                destination.unlink(missing_ok=True)
        raise
    finally:
        if destination_descriptor is not None:
            os.close(destination_descriptor)
        os.close(source_descriptor)
    if safe_tree_digest(destination) != expected:
        if destination.is_dir() and not destination.is_symlink():
            shutil.rmtree(destination, ignore_errors=True)
        else:
            destination.unlink(missing_ok=True)
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
) -> dict[str, Any]:
    loaded, mode, attestation = read_hook_config(
        destination,
        owner_private=provider == "grok",
    )
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
    os.chmod(output, 0o600 if provider == "grok" else mode)
    return attestation


def remove_widget_hook(
    destination: Path,
    output: Path,
    widget_hook: Path,
    provider: str,
) -> dict[str, Any]:
    """Remove only the widget command, migrating to a valid shared hook."""
    loaded, mode, attestation = read_hook_config(
        destination,
        required=True,
        owner_private=provider == "grok",
    )
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
    os.chmod(output, 0o600 if provider == "grok" else mode)
    return attestation


def quiesce_managed_hooks(
    destination: Path,
    output: Path,
    provider: str,
) -> tuple[float, dict[str, Any]]:
    """Stage a config without Statelet handlers and return its drain timeout."""
    loaded, mode, attestation = read_hook_config(
        destination,
        owner_private=provider == "grok",
    )
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
    os.chmod(output, 0o600 if provider == "grok" else mode)
    return maximum_timeout + 0.1 if maximum_timeout else 0.0, attestation


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--python")
    parser.add_argument("--hook-script", type=Path)
    parser.add_argument("--provider", choices=("codex", "grok"), default="codex")
    parser.add_argument("--attestation-output", type=Path)
    parser.add_argument("--private-directory", action="append", default=[], type=Path)
    parser.add_argument("--remove-widget-hook", action="store_true")
    parser.add_argument("--quiesce-managed-hooks", action="store_true")
    parser.add_argument("--safe-tree-digest", type=Path)
    parser.add_argument(
        "--safe-tree-digest-algorithm",
        choices=tuple(sorted(TREE_DIGEST_ALGORITHMS)),
        default=TREE_DIGEST_ALGORITHM,
    )
    parser.add_argument("--safe-copy-source", type=Path)
    parser.add_argument("--safe-copy-destination", type=Path)
    args = parser.parse_args()
    if args.safe_tree_digest is not None:
        print(
            safe_tree_digest(
                args.safe_tree_digest,
                algorithm=args.safe_tree_digest_algorithm,
            )
        )
        return 0
    if args.safe_copy_source is not None or args.safe_copy_destination is not None:
        if args.safe_copy_source is None or args.safe_copy_destination is None:
            parser.error("safe copy requires both source and destination")
        safe_copy_tree(args.safe_copy_source, args.safe_copy_destination)
        return 0
    if args.quiesce_managed_hooks:
        if args.destination is None or args.output is None:
            parser.error("hook quiescence requires destination and output")
        timeout, attestation = quiesce_managed_hooks(args.destination, args.output, args.provider)
        if args.private_directory:
            attestation["private_directories"] = attest_private_directories(args.private_directory)
        if args.attestation_output is not None:
            write_attestation(args.attestation_output, attestation)
        print(timeout)
        return 0
    if None in (args.destination, args.output, args.python, args.hook_script):
        parser.error("hook merge requires destination, output, python, and hook-script")
    if args.remove_widget_hook:
        attestation = remove_widget_hook(args.destination, args.output, args.hook_script, args.provider)
    else:
        attestation = merge(args.destination, args.output, args.python, args.hook_script, args.provider)
    if args.private_directory:
        attestation["private_directories"] = attest_private_directories(args.private_directory)
    if args.attestation_output is not None:
        write_attestation(args.attestation_output, attestation)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
