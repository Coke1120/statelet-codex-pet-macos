#!/bin/bash
set -euo pipefail

managed_marker="statelet-v2"
legacy_marker="mac-widget-v1"
aggregator_label="com.coke1120.statelet.state-aggregator"
player_label="com.coke1120.statelet.mac-player"
legacy_aggregator_label="com.coke1120.codex-pet.state-aggregator"
legacy_player_label="com.coke1120.codex-pet.mac-player"
script_dir="$(cd "$(dirname "$0")" && pwd -P)"
package_dir="$(cd "$script_dir/.." && pwd -P)"
repo_root="$(cd "$package_dir/../.." && pwd -P)"
home_dir="$HOME"
app_bundle="$package_dir/dist/Statelet.app"
install_player=1
skip_launchctl=0

usage() {
  cat <<'EOF'
Usage: install.sh [options]

Options:
  --app-bundle APP          Built Statelet.app bundle
  --home DIR                Explicit destination home (safe for tests/staging)
  --no-player-launch-agent  Install the app without launching it at login
  --skip-launchctl          Install files without changing live launchd jobs
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-bundle) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; app_bundle="$2"; shift 2 ;;
    --home) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; home_dir="$2"; shift 2 ;;
    --no-player-launch-agent) install_player=0; shift ;;
    --skip-launchctl) skip_launchctl=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$home_dir" = /* && "$home_dir" != / ]] || { printf 'Destination home must be an absolute non-root directory.\n' >&2; exit 2; }
[[ -d "$home_dir" ]] || { printf 'Destination home does not exist: %s\n' "$home_dir" >&2; exit 2; }
[[ -d "$app_bundle" ]] || { printf 'App bundle does not exist: %s\n' "$app_bundle" >&2; exit 1; }
if [[ "$skip_launchctl" -eq 0 && "$home_dir" != "$HOME" ]]; then
  printf -- '--home requires --skip-launchctl to avoid mutating another account.\n' >&2
  exit 2
fi

info="$app_bundle/Contents/Info.plist"
app_executable="$app_bundle/Contents/MacOS/Statelet"
[[ -f "$info" && -x "$app_executable" ]] || { printf 'Invalid Statelet.app bundle.\n' >&2; exit 1; }
plutil -lint "$info" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")" == "com.coke1120.Statelet" ]] || { printf 'Unexpected application bundle identifier.\n' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :StateletManaged' "$info")" == "$managed_marker" ]] || { printf 'Application bundle is not a managed Statelet build.\n' >&2; exit 1; }

python_bin=""
for candidate in /usr/bin/python3 "$(command -v python3 || true)"; do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  resolved_candidate="$($candidate -c 'import os,sys; print(os.path.realpath(sys.executable))' 2>/dev/null || true)"
  [[ -n "$resolved_candidate" ]] || continue
  case "$resolved_candidate" in "$repo_root"/*|/tmp/*|/private/tmp/*) continue ;; esac
  if "$resolved_candidate" -c 'import sys; raise SystemExit(sys.version_info < (3, 9))'; then python_bin="$resolved_candidate"; break; fi
done
[[ -n "$python_bin" ]] || { printf 'A stable Python 3.9+ interpreter outside the repository and temporary directories is required.\n' >&2; exit 1; }

applications_dir="$home_dir/Applications"
app_dest="$applications_dir/Statelet.app"
legacy_app="$applications_dir/CodexPetMac.app"
support_dir="$home_dir/Library/Application Support/Statelet"
legacy_support="$home_dir/Library/Application Support/CodexPet"
component_dir="$support_dir/Statelet"
legacy_component="$legacy_support/mac-widget"
python_dir="$component_dir/python"
media_dir="$support_dir/media"
runtime_dir="$support_dir/runtime"
logs_dir="$support_dir/logs"
media_map="$media_dir/media-map.json"
migration_manifest="$support_dir/.legacy-migration-v1.json"
launch_agents_dir="$home_dir/Library/LaunchAgents"
aggregator_plist="$launch_agents_dir/$aggregator_label.plist"
player_plist="$launch_agents_dir/$player_label.plist"
legacy_aggregator_plist="$launch_agents_dir/$legacy_aggregator_label.plist"
legacy_player_plist="$launch_agents_dir/$legacy_player_label.plist"
hooks_file="$home_dir/.codex/hooks.json"
player_run_at_load=1
transaction_root="$home_dir/.statelet-install-transaction"
stage_root="$transaction_root/stage"
backup_root="$transaction_root/backup"

validate_support_roots() {
  "$python_bin" - "$home_dir" "$home_dir/Library" "$home_dir/Library/Application Support" "$support_dir" "$legacy_support" <<'PY'
import os, stat, sys
from pathlib import Path

for index, raw_path in enumerate(sys.argv[1:]):
    path = Path(raw_path)
    if not os.path.lexists(path):
        if index == 0:
            raise SystemExit(1)
        continue
    try:
        status = path.lstat()
    except OSError:
        raise SystemExit(1)
    if stat.S_ISLNK(status.st_mode) or not stat.S_ISDIR(status.st_mode) or status.st_uid != os.getuid():
        raise SystemExit(1)
PY
}

is_safe_destination_dir() {
  "$python_bin" - "$1" <<'PY'
import os, stat, sys
from pathlib import Path
path = Path(sys.argv[1])
try:
    status = path.lstat()
except OSError:
    raise SystemExit(1)
raise SystemExit(0 if stat.S_ISDIR(status.st_mode) and not stat.S_ISLNK(status.st_mode) and status.st_uid == os.getuid() else 1)
PY
}

validate_support_parent_chain() {
  "$python_bin" - "$support_dir" "$1" <<'PY'
import os, stat, sys
from pathlib import Path
root = Path(sys.argv[1])
target = Path(sys.argv[2])
try:
    relative = target.relative_to(root)
except ValueError:
    raise SystemExit(1)
candidates = [root]
candidate = root
for part in relative.parts:
    candidate = candidate / part
    candidates.append(candidate)
for candidate in candidates:
    try:
        status = candidate.lstat()
    except OSError:
        raise SystemExit(1)
    if not stat.S_ISDIR(status.st_mode) or stat.S_ISLNK(status.st_mode) or status.st_uid != os.getuid():
        raise SystemExit(1)
PY
}

classify_obsolete_activity_titles() {
  "$python_bin" - "$home_dir" <<'PY'
import errno, os, stat, sys

owner = os.getuid()
directory_flags = os.O_RDONLY | os.O_DIRECTORY
if hasattr(os, "O_CLOEXEC"):
    directory_flags |= os.O_CLOEXEC
if hasattr(os, "O_NOFOLLOW"):
    directory_flags |= os.O_NOFOLLOW

def open_owned_directory(parent_fd, name):
    try:
        descriptor = os.open(name, directory_flags, dir_fd=parent_fd)
    except FileNotFoundError:
        return None
    except OSError:
        raise SystemExit(2)
    status = os.fstat(descriptor)
    if not stat.S_ISDIR(status.st_mode) or status.st_uid != owner:
        os.close(descriptor)
        raise SystemExit(2)
    return descriptor

try:
    current = os.open(sys.argv[1], directory_flags)
except OSError:
    raise SystemExit(2)
try:
    home_status = os.fstat(current)
    if not stat.S_ISDIR(home_status.st_mode) or home_status.st_uid != owner:
        raise SystemExit(2)
    for component in ("Library", "Application Support", "Statelet", "sessions"):
        next_directory = open_owned_directory(current, component)
        if next_directory is None:
            print("absent")
            raise SystemExit(0)
        os.close(current)
        current = next_directory
    try:
        status = os.stat("activity-titles-v1.json", dir_fd=current, follow_symlinks=False)
    except FileNotFoundError:
        print("absent")
        raise SystemExit(0)
    except OSError as error:
        if error.errno == errno.ENOENT:
            print("absent")
            raise SystemExit(0)
        raise SystemExit(2)
    if not stat.S_ISREG(status.st_mode) or status.st_uid != owner:
        raise SystemExit(2)
    print("regular")
finally:
    try:
        os.close(current)
    except NameError:
        pass
PY
}

if ! validate_support_roots; then
  printf 'Refusing unsafe Statelet support directory layout.\n' >&2
  exit 1
fi

is_canonical_app() {
  [[ -f "$1/Contents/Info.plist" ]] &&
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true)" == "com.coke1120.Statelet" ]] &&
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :StateletManaged' "$1/Contents/Info.plist" 2>/dev/null || true)" == "$managed_marker" ]]
}
is_legacy_app() {
  [[ -f "$1/Contents/Info.plist" ]] &&
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true)" == "com.coke1120.CodexPetMac" ]] &&
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CodexPetManaged' "$1/Contents/Info.plist" 2>/dev/null || true)" == "$legacy_marker" ]]
}
is_managed_app() { is_canonical_app "$1" || is_legacy_app "$1"; }
is_canonical_component() { [[ -f "$1/MANAGED_BY_STATELET" ]] && [[ "$(cat "$1/MANAGED_BY_STATELET")" == "$managed_marker" ]]; }
is_legacy_component() { [[ -f "$1/MANAGED_BY_CODEX_PET" ]] && [[ "$(cat "$1/MANAGED_BY_CODEX_PET")" == "$legacy_marker" ]]; }
is_canonical_plist() { [[ -f "$1" ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print :StateletManaged' "$1" 2>/dev/null || true)" == "$managed_marker" ]]; }
is_legacy_plist() { [[ -f "$1" ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print :CodexPetMacManaged' "$1" 2>/dev/null || true)" == "$legacy_marker" ]]; }
is_owned_legacy_data() {
  "$python_bin" - "$legacy_support" "$1" <<'PY'
import os, stat, sys
from pathlib import Path

root = Path(sys.argv[1])
source = Path(sys.argv[2])
try:
    root_status = root.lstat()
    source_status = source.lstat()
except OSError:
    raise SystemExit(1)
if (
    not stat.S_ISDIR(root_status.st_mode)
    or stat.S_ISLNK(root_status.st_mode)
    or root_status.st_uid != os.getuid()
    or stat.S_ISLNK(source_status.st_mode)
    or source_status.st_uid != os.getuid()
):
    raise SystemExit(1)
paths = [source] if not stat.S_ISDIR(source_status.st_mode) else source.rglob("*")
for path in paths:
    if path.lstat().st_uid != os.getuid():
        raise SystemExit(1)
PY
}
migration_attests() {
  "$python_bin" - "$migration_manifest" "$legacy_marker" "$legacy_support" "$1" "$2" <<'PY'
import json, os, stat, sys
from pathlib import Path

path = Path(sys.argv[1])
marker, source_root, relative, expected = sys.argv[2:]
try:
    status = path.lstat()
    if (
        not stat.S_ISREG(status.st_mode)
        or stat.S_ISLNK(status.st_mode)
        or stat.S_IMODE(status.st_mode) != 0o600
        or status.st_uid != os.getuid()
    ):
        raise ValueError
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        with os.fdopen(descriptor, encoding="utf-8") as handle:
            data = json.load(handle)
    except Exception:
        raise ValueError
    if set(data) != {"version", "source_identity", "source_root", "subtrees"}:
        raise ValueError
    if data["version"] != 1 or data["source_identity"] != marker or data["source_root"] != source_root or not isinstance(data["subtrees"], dict):
        raise ValueError
    if set(data["subtrees"]) - {"media", "voice", "characters", "sessions", "alpha-runtime", "runtime/current_state.json"}:
        raise ValueError
    raise SystemExit(0 if data["subtrees"].get(relative) == expected else 1)
except (OSError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
PY
}

journal_command() {
  "$python_bin" - "$transaction_root" "$home_dir" "$@" <<'PY'
import ctypes, hashlib, json, os, shutil, signal, stat, subprocess, sys, time
from pathlib import Path

root = Path(sys.argv[1])
home = Path(sys.argv[2])
command = sys.argv[3]
args = sys.argv[4:]
journal = root / "journal.json"

def digest(path):
    if path.is_symlink():
        raise ValueError(f"symbolic link in transaction path: {path}")
    value = hashlib.sha256()
    paths = [path] if not path.is_dir() else sorted(path.rglob("*"))
    for item in paths:
        status = item.lstat()
        relative = "." if item == path else item.relative_to(path).as_posix()
        if stat.S_ISLNK(status.st_mode) or not (stat.S_ISDIR(status.st_mode) or stat.S_ISREG(status.st_mode)):
            raise ValueError(f"unsafe transaction path: {item}")
        if stat.S_ISDIR(status.st_mode):
            value.update(b"D\0" + relative.encode() + b"\0")
        else:
            value.update(b"F\0" + relative.encode() + b"\0")
            descriptor = os.open(item, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                while True:
                    chunk = os.read(descriptor, 1024 * 1024)
                    if not chunk:
                        break
                    value.update(chunk)
            finally:
                os.close(descriptor)
    return value.hexdigest()

def open_directory_chain(base, relative_parts):
    descriptor = os.open(base, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        status = os.fstat(descriptor)
        if status.st_uid != os.getuid():
            raise ValueError("unsafe directory owner")
        for part in relative_parts:
            next_descriptor = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
            status = os.fstat(descriptor)
            if status.st_uid != os.getuid():
                raise ValueError("unsafe directory owner")
        return descriptor
    except Exception:
        os.close(descriptor)
        raise

def relative_to(path, base):
    try:
        return Path(path).relative_to(base)
    except ValueError as error:
        raise ValueError("path outside allowed root") from error

def rename_exclusive(source_parent, source_name, target_parent, target_name):
    libc = ctypes.CDLL(None, use_errno=True)
    function = libc.renameatx_np
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    if function(source_parent, os.fsencode(source_name), target_parent, os.fsencode(target_name), 0x00000004) != 0:
        error = ctypes.get_errno()
        raise OSError(error, "exclusive rename failed")

def entry_digests_and_identity(parent_fd, name, exclusion_sets):
    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent_fd)
    status = os.fstat(descriptor)
    values = [hashlib.sha256() for _ in exclusion_sets]
    excluded_parts = [
        {tuple(Path(relative).parts) for relative in excluded}
        for excluded in exclusion_sets
    ]
    def validate_stable(fd, before):
        after = os.fstat(fd)
        fields = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
        if any(getattr(before, field) != getattr(after, field) for field in fields):
            raise ValueError("entry changed while reading")
    def visit(directory_fd, entry_name, relative_parts):
        included = [
            not any(relative_parts[:len(parts)] == parts for parts in excluded)
            for excluded in excluded_parts
        ]
        if not any(included):
            return
        current_fd = os.open(
            entry_name,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
            dir_fd=directory_fd,
        )
        current = os.fstat(current_fd)
        relative = "/".join(relative_parts)
        if stat.S_ISREG(current.st_mode):
            for value, include in zip(values, included):
                if include: value.update(b"F\0" + relative.encode() + b"\0")
            try:
                while chunk := os.read(current_fd, 1024 * 1024):
                    for value, include in zip(values, included):
                        if include: value.update(chunk)
                validate_stable(current_fd, current)
            finally: os.close(current_fd)
        elif stat.S_ISDIR(current.st_mode):
            for value, include in zip(values, included):
                if include: value.update(b"D\0" + relative.encode() + b"\0")
            try:
                for child_name in sorted(os.listdir(current_fd)):
                    visit(current_fd, child_name, relative_parts + (child_name,))
                validate_stable(current_fd, current)
            finally: os.close(current_fd)
        else:
            os.close(current_fd)
            raise ValueError("unsafe entry")
    try:
        if stat.S_ISDIR(status.st_mode):
            for child_name in sorted(os.listdir(descriptor)):
                visit(descriptor, child_name, (child_name,))
            validate_stable(descriptor, status)
        elif stat.S_ISREG(status.st_mode):
            if any(excluded_parts):
                raise ValueError("file install cannot own descendants")
            for value in values: value.update(b"F\0.\0")
            while chunk := os.read(descriptor, 1024 * 1024):
                for value in values: value.update(chunk)
            validate_stable(descriptor, status)
        else:
            raise ValueError("unsafe entry")
    finally:
        os.close(descriptor)
    rebound = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if [rebound.st_dev, rebound.st_ino] != [status.st_dev, status.st_ino]:
        raise ValueError("entry identity changed while reading")
    return [value.hexdigest() for value in values], [status.st_dev, status.st_ino]

def entry_digest_and_identity(parent_fd, name, excluded=()):
    digests, current_identity = entry_digests_and_identity(parent_fd, name, [excluded])
    return digests[0], current_identity

def entry_digest(parent_fd, name):
    return entry_digest_and_identity(parent_fd, name)[0]

def remove_entry(parent_fd, name):
    status = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if stat.S_ISDIR(status.st_mode):
        child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
        try:
            for child_name in os.listdir(child): remove_entry(child, child_name)
        finally: os.close(child)
        os.rmdir(name, dir_fd=parent_fd)
    elif stat.S_ISREG(status.st_mode):
        os.unlink(name, dir_fd=parent_fd)
    else:
        raise ValueError("unsafe entry")

def open_parent(path, base):
    relative = relative_to(path, base)
    return open_directory_chain(base, relative.parts[:-1]), relative.name

def entry_identity(status):
    return [status.st_dev, status.st_ino]

def is_within(path, parent):
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False

def active_install_indices(operations):
    active = []
    for index, operation in enumerate(operations):
        kind = operation.get("kind")
        if kind not in {"backup", "install"}:
            continue
        target = Path(operation.get("target", ""))
        active = [
            owner_index
            for owner_index in active
            if not is_within(Path(operations[owner_index]["target"]), target)
        ]
        if kind == "install":
            active.append(index)
    return active

def active_install_owner(operations, active_indices, target):
    candidates = []
    for index in active_indices:
        operation = operations[index]
        owner_target = Path(operation["target"])
        if not is_within(target, owner_target):
            continue
        relative = target.relative_to(owner_target)
        if relative.parts and any(
            is_within(relative, Path(excluded))
            for excluded in operation.get("owned_exclusions", [])
        ):
            continue
        candidates.append(index)
    if not candidates:
        return None
    return max(candidates, key=lambda index: len(Path(operations[index]["target"]).parts))

def open_recorded_target_parent(operations, operation_index):
    operation = operations[operation_index]
    target_parent_path = Path(operation["target"]).parent
    expected = operation.get("target_parent")
    candidates = [(home, relative_to(target_parent_path, home).parts)]
    for later in operations[operation_index + 1:]:
        if later.get("kind") != "backup":
            continue
        later_target = Path(later["target"])
        if not is_within(target_parent_path, later_target):
            continue
        relocated = Path(later["source"]) / target_parent_path.relative_to(later_target)
        candidates.append((root, relative_to(relocated, root).parts))
    for base, parts in candidates:
        try:
            descriptor = open_directory_chain(base, parts)
        except OSError:
            continue
        if entry_identity(os.fstat(descriptor)) == expected:
            return descriptor
        os.close(descriptor)
    raise ValueError("transaction parent changed")

def strict_install_ancestors(operations, target):
    return [
        index
        for index in active_install_indices(operations)
        if Path(operations[index]["target"]) != target
        and is_within(target, Path(operations[index]["target"]))
    ]

def validate_install_at(operation, parent, name, expected_parent=None):
    if expected_parent is not None and entry_identity(os.fstat(parent)) != expected_parent:
        raise ValueError("transaction parent changed")
    digest_value, current_identity = entry_digest_and_identity(
        parent, name, operation.get("owned_exclusions", [])
    )
    if current_identity != operation.get("target_entry"):
        raise ValueError("installed entry identity changed")
    if digest_value != operation.get("owned_digest", operation["digest"]):
        raise ValueError("installed entry changed")

def validate_live_install(operation):
    parent, name = open_parent(Path(operation["target"]), home)
    try:
        validate_install_at(operation, parent, name, operation.get("target_parent"))
    finally:
        os.close(parent)

def prepare_install_ancestor_mutations(data, target):
    indices = strict_install_ancestors(data["operations"], target)
    for index in indices:
        operation = data["operations"][index]
        parent, name = open_parent(Path(operation["target"]), home)
        try:
            if entry_identity(os.fstat(parent)) != operation.get("target_parent"):
                raise ValueError("transaction parent changed")
            relative = str(target.relative_to(Path(operation["target"])))
            existing = [Path(value) for value in operation.get("owned_exclusions", [])]
            if not any(is_within(Path(relative), value) for value in existing):
                existing = [value for value in existing if not is_within(value, Path(relative))]
                existing.append(Path(relative))
            updated_exclusions = sorted(str(value) for value in existing)
            digests, current_identity = entry_digests_and_identity(
                parent,
                name,
                [operation.get("owned_exclusions", []), updated_exclusions],
            )
            if current_identity != operation.get("target_entry"):
                raise ValueError("installed entry identity changed")
            if digests[0] != operation.get("owned_digest", operation["digest"]):
                raise ValueError("installed entry changed")
            operation["owned_exclusions"] = updated_exclusions
            operation["owned_digest"] = digests[1]
        finally:
            os.close(parent)
    return indices

def validate_install_ancestor_mutations(data, indices):
    for index in indices:
        validate_live_install(data["operations"][index])

def validate_handed_off_install(operation):
    parent, name = open_parent(Path(operation["target"]), home)
    try:
        if entry_identity(os.fstat(parent)) != operation.get("target_parent"):
            raise ValueError("transaction parent changed")
        status = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if not stat.S_ISREG(status.st_mode) or status.st_uid != os.getuid():
            raise ValueError("handed-off entry is unsafe")
    finally:
        os.close(parent)

def validate_operation_contract(data, allowed_targets):
    for operation in data.get("operations", []):
        if not isinstance(operation, dict):
            raise ValueError("transaction operation is invalid")
        kind = operation.get("kind")
        source = Path(operation.get("source", ""))
        target = Path(operation.get("target", ""))
        if kind not in {"backup", "install", "mkdir", "retain"} or not target.is_absolute() or str(target) not in allowed_targets:
            raise ValueError("transaction operation is invalid")
        if kind in {"mkdir", "retain"}:
            if operation.get("source") != "":
                raise ValueError("transaction operation is invalid")
            continue
        try:
            source.relative_to(root)
        except ValueError as error:
            raise ValueError("transaction operation is invalid") from error
        expected_source_root = root / "backup" if kind == "backup" else root / "stage"
        try:
            source.relative_to(expected_source_root)
        except ValueError as error:
            raise ValueError("transaction operation is invalid") from error

def validate_retain(operation):
    parent, name = open_parent(Path(operation["target"]), home)
    try:
        if entry_identity(os.fstat(parent)) != operation.get("target_parent"):
            raise ValueError("transaction parent changed")
        digest_value, current_identity = entry_digest_and_identity(parent, name)
        if current_identity != operation.get("target_entry") or digest_value != operation.get("digest"):
            raise ValueError("retained entry changed")
    finally:
        os.close(parent)

def validate_backup_coverage(data):
    declared = []
    for operation in data.get("operations", []):
        if operation.get("kind") != "backup":
            continue
        try:
            declared.append(tuple(Path(operation["source"]).relative_to(root / "backup").parts))
        except ValueError as error:
            raise ValueError("transaction backup source is invalid") from error
    root_fd = os.open(root / "backup", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        def visit(directory_fd, prefix):
            names = sorted(os.listdir(directory_fd))
            for name in names:
                current_parts = prefix + (name,)
                status = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                within_declared = any(current_parts[:len(parts)] == parts for parts in declared)
                ancestor_of_declared = any(parts[:len(current_parts)] == current_parts for parts in declared)
                if not within_declared and not ancestor_of_declared:
                    raise ValueError("unreferenced transaction backup entry")
                if stat.S_ISDIR(status.st_mode):
                    child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory_fd)
                    try:
                        visit(child, current_parts)
                    finally:
                        os.close(child)
                elif not stat.S_ISREG(status.st_mode):
                    raise ValueError("unsafe transaction backup entry")
        visit(root_fd, ())
    finally:
        os.close(root_fd)

def open_bound_directory(path):
    descriptor, name = open_parent(path, home)
    try:
        child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
    finally:
        os.close(descriptor)
    status = os.fstat(child)
    if status.st_uid != os.getuid():
        os.close(child)
        raise ValueError("unsafe handed-off directory owner")
    return child, entry_identity(status)

def record_handoff(support):
    runtime = support / "runtime"
    logs = support / "logs"
    runtime_fd, runtime_identity = open_bound_directory(runtime)
    logs_fd, logs_identity = open_bound_directory(logs)
    try:
        try:
            current = os.stat("current_state.json", dir_fd=runtime_fd, follow_symlinks=False)
        except FileNotFoundError:
            current_state = {"state": "absent"}
        else:
            if not stat.S_ISREG(current.st_mode) or current.st_uid != os.getuid():
                raise ValueError("handed-off entry is unsafe")
            current_state = {"state": "regular", "identity": entry_identity(current)}
    finally:
        os.close(runtime_fd)
        os.close(logs_fd)
    return {
        "runtime": {"path": str(runtime), "identity": runtime_identity},
        "logs": {"path": str(logs), "identity": logs_identity, "mutable_descendants": True},
        "current_state": {"path": str(runtime / "current_state.json"), "initial": current_state, "mutable": True},
    }

def validate_handoff_contract(data, support):
    handoff = data.get("handoff")
    if not isinstance(handoff, dict) or set(handoff) != {"runtime", "logs", "current_state"}:
        raise ValueError("transaction handoff state is invalid")
    runtime = support / "runtime"
    logs = support / "logs"
    expected_paths = (str(runtime), str(logs), str(runtime / "current_state.json"))
    runtime_data, logs_data, current_data = handoff["runtime"], handoff["logs"], handoff["current_state"]
    if (not isinstance(runtime_data, dict) or set(runtime_data) != {"path", "identity"}
            or not isinstance(logs_data, dict) or set(logs_data) != {"path", "identity", "mutable_descendants"}
            or not isinstance(current_data, dict) or set(current_data) != {"path", "initial", "mutable"}
            or (runtime_data["path"], logs_data["path"], current_data["path"]) != expected_paths
            or logs_data["mutable_descendants"] is not True or current_data["mutable"] is not True
            or not all(type(value) is int for item in (runtime_data["identity"], logs_data["identity"])
                       if isinstance(item, list) and len(item) == 2 for value in item)
            or not all(isinstance(item, list) and len(item) == 2 for item in (runtime_data["identity"], logs_data["identity"]))):
        raise ValueError("transaction handoff state is invalid")
    initial = current_data["initial"]
    if (not isinstance(initial, dict) or initial.get("state") not in {"absent", "regular"}
            or (initial["state"] == "absent" and set(initial) != {"state"})
            or (initial["state"] == "regular" and
                (set(initial) != {"state", "identity"} or not isinstance(initial["identity"], list)
                 or len(initial["identity"]) != 2 or not all(type(value) is int for value in initial["identity"])))):
        raise ValueError("transaction handoff state is invalid")
    runtime_fd, runtime_identity = open_bound_directory(runtime)
    logs_fd, logs_identity = open_bound_directory(logs)
    try:
        if runtime_identity != runtime_data["identity"] or logs_identity != logs_data["identity"]:
            raise ValueError("handed-off directory changed")
        try:
            current = os.stat("current_state.json", dir_fd=runtime_fd, follow_symlinks=False)
        except FileNotFoundError:
            current = None
        if current is not None and (not stat.S_ISREG(current.st_mode) or current.st_uid != os.getuid()):
            raise ValueError("handed-off entry is unsafe")
    finally:
        os.close(runtime_fd)
        os.close(logs_fd)
    return {support / "runtime/current_state.json"}

def seal_payload(data):
    operations = data.get("operations")
    launch = data.get("launch")
    handoff = data.get("handoff")
    if not isinstance(operations, list) or not isinstance(launch, dict) or not isinstance(handoff, dict):
        raise ValueError("transaction seal inputs are invalid")
    active_targets = [
        data["operations"][index]["target"]
        for index in active_install_indices(operations)
    ]
    if launch == {"skipped": True}:
        sealed_launch = {"skipped": True}
    else:
        sealed_launch = {
            "labels": launch.get("labels"),
            "plists": launch.get("plists"),
            "desired": launch.get("desired"),
        }
    return {
        "operations": operations,
        "operation_count": len(operations),
        "active_targets": active_targets,
        "handoff": handoff,
        "launch": sealed_launch,
    }

def seal_digest(payload):
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()

def record_seal(data):
    payload = seal_payload(data)
    data["seal"] = {
        "version": 1,
        "operation_count": payload["operation_count"],
        "active_targets": payload["active_targets"],
        "digest": seal_digest(payload),
    }

def validate_seal(data):
    seal = data.get("seal")
    if (not isinstance(seal, dict) or set(seal) != {"version", "operation_count", "active_targets", "digest"}
            or seal.get("version") != 1 or type(seal.get("operation_count")) is not int
            or not isinstance(seal.get("active_targets"), list)
            or not all(isinstance(value, str) for value in seal["active_targets"])
            or not isinstance(seal.get("digest"), str) or len(seal["digest"]) != 64):
        raise ValueError("transaction seal is invalid")
    payload = seal_payload(data)
    if (seal["operation_count"] != payload["operation_count"]
            or seal["active_targets"] != payload["active_targets"]
            or seal["digest"] != seal_digest(payload)):
        raise ValueError("transaction seal is invalid")

def validate_required_publication(data, installer_args, support):
    if len(installer_args) < 9:
        raise ValueError("transaction publication contract is invalid")
    active_targets = {
        Path(data["operations"][index]["target"])
        for index in active_install_indices(data.get("operations", []))
    }
    app, legacy_app, component, legacy_component = map(Path, installer_args[:4])
    aggregator_plist, player_plist, legacy_aggregator_plist, legacy_player_plist = map(Path, installer_args[4:8])
    hooks = Path(installer_args[8])
    required = {app, component, aggregator_plist, hooks, support / ".legacy-migration-v1.json"}
    forbidden = {legacy_app, legacy_component, legacy_aggregator_plist, legacy_player_plist}
    if not required.issubset(active_targets) or active_targets.intersection(forbidden):
        raise ValueError("transaction publication contract is invalid")
    media_map = support / "media/media-map.json"
    media_operations = [
        operation for operation in data.get("operations", [])
        if Path(operation.get("target", "")) == media_map and operation.get("kind") in {"install", "retain"}
    ]
    if len(media_operations) != 1:
        raise ValueError("transaction publication contract is invalid")
    player_active = player_plist in active_targets
    launch = data.get("launch")
    if launch == {"skipped": True}:
        return
    if not isinstance(launch, dict) or launch.get("desired") != [True, player_active, False, False]:
        raise ValueError("transaction publication contract is invalid")

def validate_file_transaction(data, handed_off_targets=()):
    operations = data.get("operations", [])
    active_installs = active_install_indices(operations)
    replayed_installs = []
    displaced_installs = set()
    for index, operation in enumerate(operations):
        kind = operation.get("kind")
        target = Path(operation.get("target", ""))
        if kind == "backup":
            displaced = [
                owner_index
                for owner_index in replayed_installs
                if is_within(Path(operations[owner_index]["target"]), target)
            ]
            for owner_index in displaced:
                owner = operations[owner_index]
                relative = Path(owner["target"]).relative_to(target)
                saved_path = Path(operation["source"]) / relative
                saved_parent, saved_name = open_parent(saved_path, root)
                try:
                    validate_install_at(owner, saved_parent, saved_name)
                finally:
                    os.close(saved_parent)
                displaced_installs.add(owner_index)
            replayed_installs = [owner for owner in replayed_installs if owner not in displaced]
        elif kind == "install":
            displaced = [
                owner_index
                for owner_index in replayed_installs
                if is_within(Path(operations[owner_index]["target"]), target)
            ]
            if displaced:
                raise ValueError("install ownership graph is ambiguous")
            replayed_installs.append(index)

    if replayed_installs != active_installs:
        raise ValueError("install ownership graph is invalid")

    for operation_index, operation in enumerate(operations):
        kind = operation.get("kind")
        if kind in {"install", "backup"}:
            source_parent, source_name = open_parent(Path(operation["source"]), root)
            recorded_target_parent = open_recorded_target_parent(operations, operation_index)
            live_target_parent = None
            try:
                source_status = os.fstat(source_parent)
                if entry_identity(source_status) != operation.get("source_parent"):
                    raise ValueError("transaction parent changed")
                try: source_digest, source_entry_identity = entry_digest_and_identity(source_parent, source_name)
                except FileNotFoundError: source_exists = False
                else: source_exists = True
                try:
                    live_target_parent, target_name = open_parent(Path(operation["target"]), home)
                    os.stat(target_name, dir_fd=live_target_parent, follow_symlinks=False)
                except (FileNotFoundError, NotADirectoryError):
                    target_exists = False
                else:
                    target_exists = True
                if kind == "install":
                    if (source_exists or
                        (operation_index in active_installs and not target_exists) or
                        (operation_index not in active_installs and operation_index not in displaced_installs)):
                        raise ValueError("installed entry changed")
                else:
                    later_owner = active_install_owner(
                        operations, active_installs, Path(operation["target"])
                    )
                    if ((later_owner is None and target_exists) or
                        (later_owner is not None and later_owner <= operation_index) or
                        not source_exists or source_entry_identity != operation.get("source_entry") or
                        source_digest != operation["digest"]):
                        raise ValueError("backup entry changed")
            finally:
                os.close(source_parent)
                os.close(recorded_target_parent)
                if live_target_parent is not None:
                    os.close(live_target_parent)
        elif kind == "mkdir":
            parent, _ = open_parent(Path(operation["target"]), home)
            try:
                status = os.fstat(parent)
                if [status.st_dev, status.st_ino] != operation.get("target_parent"):
                    raise ValueError("transaction parent changed")
                child = os.stat(Path(operation["target"]).name, dir_fd=parent, follow_symlinks=False)
                if not stat.S_ISDIR(child.st_mode) or [child.st_dev, child.st_ino] != operation.get("created"):
                    raise ValueError("transaction directory changed")
            finally:
                os.close(parent)
        elif kind == "retain":
            validate_retain(operation)
    for index in active_installs:
        if Path(operations[index]["target"]) in handed_off_targets:
            validate_handed_off_install(operations[index])
        else:
            validate_live_install(operations[index])

def validate_launch_plist(data, label, plist):
    launch = data.get("launch")
    if not isinstance(launch, dict) or label not in launch.get("labels", []):
        raise ValueError("transaction launch state is invalid")
    index = launch["labels"].index(label)
    if index >= len(launch.get("plists", [])) or launch["plists"][index] != plist:
        raise ValueError("transaction launch state is invalid")
    owners = [
        operation_index
        for operation_index in active_install_indices(data.get("operations", []))
        if data["operations"][operation_index].get("target") == plist
    ]
    if len(owners) != 1:
        raise ValueError("launch plist ownership is invalid")
    validate_live_install(data["operations"][owners[0]])

def original_launch_plist_attestation(data, label, plist, require_backup=False):
    launch = data.get("launch")
    if not isinstance(launch, dict) or label not in launch.get("labels", []):
        raise ValueError("transaction launch state is invalid")
    index = launch["labels"].index(label)
    if index >= len(launch.get("plists", [])) or launch["plists"][index] != plist:
        raise ValueError("transaction launch state is invalid")
    originals = launch.get("original_plists")
    if (not isinstance(originals, list) or len(originals) != 4
            or any(item is not None and
                   (not isinstance(item, dict) or set(item) != {"parent", "entry", "digest"}
                    or not all(isinstance(value, list) and len(value) == 2
                               and all(type(part) is int for part in value)
                               for value in (item.get("parent"), item.get("entry")))
                    or not isinstance(item.get("digest"), str) or len(item["digest"]) != 64)
                   for item in originals)):
        raise ValueError("restored launch plist ownership is invalid")
    backups = [
        operation for operation in data.get("operations", [])
        if operation.get("kind") == "backup" and operation.get("target") == plist
    ]
    if len(backups) > 1 or (require_backup and len(backups) != 1):
        raise ValueError("restored launch plist ownership is invalid")
    original = originals[index]
    if not isinstance(original, dict):
        raise ValueError("restored launch plist ownership is invalid")
    if backups:
        operation = backups[0]
        if (operation.get("digest") != original.get("digest")
                or operation.get("target_parent") != original.get("parent")
                or operation.get("source_entry") != original.get("entry")):
            raise ValueError("restored launch plist attestation changed")
    return original

def validate_launch_backup_attestations(data):
    launch = data.get("launch")
    if launch == {"skipped": True}:
        return
    if not isinstance(launch, dict):
        raise ValueError("transaction launch state is invalid")
    labels, plists, loaded = (launch.get(key) for key in ("labels", "plists", "loaded"))
    if (not all(isinstance(values, list) and len(values) == 4 for values in (labels, plists, loaded))
            or not all(isinstance(value, bool) for value in loaded)):
        raise ValueError("transaction launch state is invalid")
    for label, plist, was_loaded in zip(labels, plists, loaded):
        if was_loaded:
            original_launch_plist_attestation(data, label, plist, require_backup=True)

def validate_restored_launch_plist(data, label, plist):
    original = original_launch_plist_attestation(data, label, plist)
    parent, name = open_parent(Path(plist), home)
    try:
        digest_value, current_identity = entry_digest_and_identity(parent, name)
        if entry_identity(os.fstat(parent)) != original.get("parent"):
            raise ValueError("transaction parent changed")
        if digest_value != original.get("digest") or current_identity != original.get("entry"):
            raise ValueError("restored launch plist changed")
    finally:
        os.close(parent)

def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)

def write(data):
    temporary = root / ".journal.tmp"
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, sort_keys=True, separators=(",", ":"))
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, journal)
    sync_directory(root)

def load():
    status = root.lstat()
    if not stat.S_ISDIR(status.st_mode) or stat.S_IMODE(status.st_mode) != 0o700 or status.st_uid != os.getuid():
        raise ValueError("transaction directory ownership or mode is unsafe")
    journal_status = journal.lstat()
    if not stat.S_ISREG(journal_status.st_mode) or journal_status.st_uid != os.getuid():
        raise ValueError("transaction journal ownership is unsafe")
    data = json.loads(journal.read_text(encoding="utf-8"))
    if data.get("version") != 1 or data.get("home") != str(home) or data.get("state") not in {"active", "files-committed", "committed"}:
        raise ValueError("transaction journal identity is invalid")
    return data

if command == "init":
    root.mkdir(mode=0o700)
    sync_directory(root.parent)
    (root / "stage").mkdir(mode=0o700)
    (root / "backup").mkdir(mode=0o700)
    write({"version": 1, "home": str(home), "state": "active", "operations": []})
elif command == "record":
    kind, source, target, expected = args
    data = load()
    if data["state"] != "active" or kind not in {"backup", "install", "mkdir"}:
        raise ValueError("invalid transaction operation")
    data["operations"].append({"kind": kind, "source": source, "target": target, "digest": expected})
    write(data)
elif command == "install-move":
    source, target, expected = map(str, args)
    data = load()
    if data["state"] != "active":
        raise ValueError("inactive transaction")
    source_path = Path(source)
    target_path = Path(target)
    source_relative = relative_to(source_path, root)
    target_relative = relative_to(target_path, home)
    ancestor_indices = prepare_install_ancestor_mutations(data, target_path)
    source_parent = open_directory_chain(root, source_relative.parts[:-1])
    target_parent = open_directory_chain(home, target_relative.parts[:-1])
    try:
        if entry_digest(source_parent, source_relative.name) != expected:
            raise ValueError("staged digest changed")
        source_identity = os.fstat(source_parent)
        target_identity = os.fstat(target_parent)
        data["operations"].append({"kind": "install", "source": source, "target": target, "digest": expected,
                                   "source_parent": [source_identity.st_dev, source_identity.st_ino],
                                   "target_parent": [target_identity.st_dev, target_identity.st_ino],
                                   "target_entry": None, "owned_digest": expected,
                                   "owned_exclusions": []})
        write(data)
        gate = os.environ.get("STATELET_INSTALL_TEST_PARENT_FD_GATE")
        if gate:
            gate_path = Path(gate)
            relative_to(gate_path, home)
            Path(str(gate_path) + ".ready").touch()
            for _ in range(1500):
                if Path(str(gate_path) + ".release").exists():
                    break
                time.sleep(0.01)
            else:
                raise ValueError("test gate timeout")
        rename_exclusive(source_parent, source_relative.name, target_parent, target_relative.name)
        os.fsync(target_parent)
        os.fsync(source_parent)
        try:
            reopened = open_directory_chain(home, target_relative.parts[:-1])
            try:
                reopened_identity = os.fstat(reopened)
                if [reopened_identity.st_dev, reopened_identity.st_ino] != data["operations"][-1]["target_parent"]:
                    rename_exclusive(target_parent, target_relative.name, source_parent, source_relative.name)
                    os.fsync(target_parent); os.fsync(source_parent)
                    raise ValueError("destination parent changed")
            finally:
                os.close(reopened)
        except Exception:
            if os.path.exists(source_path):
                raise
            rename_exclusive(target_parent, target_relative.name, source_parent, source_relative.name)
            os.fsync(target_parent); os.fsync(source_parent)
            raise
        installed = os.stat(target_relative.name, dir_fd=target_parent, follow_symlinks=False)
        data["operations"][-1]["target_entry"] = entry_identity(installed)
        validate_install_ancestor_mutations(data, ancestor_indices)
        write(data)
    finally:
        os.close(source_parent)
        os.close(target_parent)
elif command == "backup-move":
    target, source, expected = map(str, args)
    data = load()
    target_path, source_path = Path(target), Path(source)
    ancestor_indices = prepare_install_ancestor_mutations(data, target_path)
    target_parent, target_name = open_parent(target_path, home)
    source_parent, source_name = open_parent(source_path, root)
    try:
        if entry_digest(target_parent, target_name) != expected:
            raise ValueError("backup source changed")
        source_identity, target_identity = os.fstat(source_parent), os.fstat(target_parent)
        data["operations"].append({"kind": "backup", "source": source, "target": target, "digest": expected,
                                   "source_parent": [source_identity.st_dev, source_identity.st_ino],
                                   "target_parent": [target_identity.st_dev, target_identity.st_ino],
                                   "source_entry": None})
        write(data)
        rename_exclusive(target_parent, target_name, source_parent, source_name)
        os.fsync(target_parent); os.fsync(source_parent)
        saved = os.stat(source_name, dir_fd=source_parent, follow_symlinks=False)
        data["operations"][-1]["source_entry"] = entry_identity(saved)
        validate_install_ancestor_mutations(data, ancestor_indices)
        write(data)
    finally:
        os.close(target_parent); os.close(source_parent)
elif command == "mkdir-make":
    target, mode = args
    data = load()
    ancestor_indices = prepare_install_ancestor_mutations(data, Path(target))
    parent, name = open_parent(Path(target), home)
    try:
        identity = os.fstat(parent)
        data["operations"].append({"kind": "mkdir", "source": "", "target": target, "digest": "",
                                   "target_parent": [identity.st_dev, identity.st_ino], "created": None})
        write(data)
        os.mkdir(name, int(mode, 8), dir_fd=parent)
        os.fsync(parent)
        created = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if not stat.S_ISDIR(created.st_mode):
            raise ValueError("created entry is not directory")
        data["operations"][-1]["created"] = [created.st_dev, created.st_ino]
        validate_install_ancestor_mutations(data, ancestor_indices)
        write(data)
    finally:
        os.close(parent)
elif command == "retain":
    target = Path(args[0])
    data = load()
    if data["state"] != "active":
        raise ValueError("inactive transaction")
    parent, name = open_parent(target, home)
    try:
        digest_value, current_identity = entry_digest_and_identity(parent, name)
        parent_identity = entry_identity(os.fstat(parent))
        data["operations"].append({"kind": "retain", "source": "", "target": str(target),
                                   "digest": digest_value, "target_parent": parent_identity,
                                   "target_entry": current_identity})
        write(data)
    finally:
        os.close(parent)
elif command == "launch-init":
    data = load()
    labels = args[:4]
    plists = args[4:8]
    loaded_values = args[8:12]
    desired_values = args[12:16]
    if (len(args) != 16 or any(value not in {"0", "1"} for value in loaded_values + desired_values)
            or any(not value for value in labels + plists)):
        raise ValueError("invalid launch state")
    loaded = [value == "1" for value in loaded_values]
    desired = [value == "1" for value in desired_values]
    original_plists = []
    for plist, was_loaded in zip(plists, loaded):
        if not was_loaded:
            original_plists.append(None)
            continue
        parent, name = open_parent(Path(plist), home)
        try:
            digest_value, current_identity = entry_digest_and_identity(parent, name)
            current = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if not stat.S_ISREG(current.st_mode) or current.st_uid != os.getuid():
                raise ValueError("unsafe original launch plist")
            original_plists.append({"parent": entry_identity(os.fstat(parent)),
                                    "entry": current_identity, "digest": digest_value})
        finally:
            os.close(parent)
    data["launch"] = {"labels": labels, "plists": plists, "loaded": loaded, "desired": desired,
                      "original_plists": original_plists,
                      "pending": [False] * 4, "changed": [False] * 4}
    write(data)
elif command == "launch-skip":
    data = load()
    if data["state"] != "active" or "launch" in data:
        raise ValueError("invalid skipped launch state")
    data["launch"] = {"skipped": True}
    write(data)
elif command == "launch-phase":
    data = load()
    if "launch" not in data:
        raise ValueError("launch state was not initialized")
    index = int(args[0])
    phase = args[1]
    if index not in range(4) or phase not in {"pending", "changed", "clear"}:
        raise ValueError("invalid launch mutation phase")
    if phase == "pending":
        data["launch"]["pending"][index] = True
    elif phase == "changed":
        data["launch"]["changed"][index] = True
        data["launch"]["pending"][index] = False
    else:
        data["launch"]["pending"][index] = False
    write(data)
elif command == "launch-validate":
    data = load()
    if data["state"] != "files-committed":
        raise ValueError("file transaction is not committed")
    validate_launch_plist(data, args[0], args[1])
elif command == "files-commit":
    data = load()
    if data["state"] != "active":
        raise ValueError("file transaction is not active")
    gate = os.environ.get("STATELET_INSTALL_TEST_COMMIT_GATE")
    if gate:
        gate_path = Path(gate)
        relative_to(gate_path, home)
        Path(str(gate_path) + ".ready").touch()
        for _ in range(3000):
            if Path(str(gate_path) + ".release").exists():
                break
            time.sleep(0.01)
        else:
            raise ValueError("test gate timeout")
    allowed_targets = set(args[:-1])
    support = Path(args[-1])
    validate_operation_contract(data, allowed_targets)
    validate_required_publication(data, args, support)
    validate_backup_coverage(data)
    validate_launch_backup_attestations(data)
    validate_file_transaction(data)
    data["handoff"] = record_handoff(support)
    record_seal(data)
    data["state"] = "files-committed"
    write(data)
elif command == "commit":
    data = load()
    if data["state"] != "files-committed":
        raise ValueError("file transaction is not committed")
    validate_seal(data)
    allowed_targets = set(args[:-1])
    support = Path(args[-1])
    validate_operation_contract(data, allowed_targets)
    validate_required_publication(data, args, support)
    validate_backup_coverage(data)
    validate_file_transaction(data, validate_handoff_contract(data, support))
    data["state"] = "committed"
    write(data)
elif command == "recover":
    data = load()
    root_prefix = str(root) + os.sep
    allowed_exact = set(args[:-1])
    support = args[-1]
    allowed_support = {
        os.path.join(support, relative)
        for relative in ("media", "voice", "characters", "sessions", "sessions/activity-titles-v1.json", "alpha-runtime", "runtime/current_state.json", "media/media-map.json", ".legacy-migration-v1.json")
    }
    allowed_exact.update(allowed_support)
    if data["state"] in {"files-committed", "committed"}:
        validate_seal(data)
    validate_operation_contract(data, allowed_exact)
    if data["state"] in {"files-committed", "committed"}:
        validate_required_publication(data, args, Path(support))
        validate_backup_coverage(data)
    if data["state"] == "files-committed":
        validate_file_transaction(data, validate_handoff_contract(data, Path(support)))
    if data["state"] == "active" and not data.get("files_restored", False):
        recovered_operations = 0
        for operation in reversed(data["operations"]):
            kind = operation.get("kind")
            source = Path(operation.get("source", ""))
            target = Path(operation.get("target", ""))
            expected = operation.get("digest", "")
            if not target.is_absolute() or str(target) not in allowed_exact:
                raise ValueError(f"transaction target is outside the installer allowlist: {target}")
            if kind == "mkdir":
                target_parent, target_name = open_parent(target, home)
                identity = os.fstat(target_parent)
                if [identity.st_dev, identity.st_ino] != operation.get("target_parent"):
                    raise ValueError("destination parent changed")
                try:
                    target_status = os.stat(target_name, dir_fd=target_parent, follow_symlinks=False)
                except FileNotFoundError:
                    target_status = None
                if operation.get("created") is None:
                    raise ValueError("directory creation was not completed")
                if target_status is not None and stat.S_ISDIR(target_status.st_mode) and [target_status.st_dev, target_status.st_ino] == operation.get("created"):
                    try:
                        os.rmdir(target_name, dir_fd=target_parent)
                    except OSError as error:
                        raise ValueError(f"created directory is no longer empty: {target}") from error
                elif target_status is not None:
                    raise ValueError(f"created directory became ambiguous: {target}")
                os.close(target_parent)
                continue
            if kind == "retain":
                validate_retain(operation)
                continue
            if kind not in {"backup", "install"} or not str(source).startswith(root_prefix):
                raise ValueError("transaction operation is invalid")
            source_parent, source_name = open_parent(source, root)
            target_parent, target_name = open_parent(target, home)
            source_identity, target_identity = os.fstat(source_parent), os.fstat(target_parent)
            if ([source_identity.st_dev, source_identity.st_ino] != operation.get("source_parent") or
                [target_identity.st_dev, target_identity.st_ino] != operation.get("target_parent")):
                raise ValueError("transaction parent changed")
            try: source_status = os.stat(source_name, dir_fd=source_parent, follow_symlinks=False)
            except FileNotFoundError: source_status = None
            try: target_status = os.stat(target_name, dir_fd=target_parent, follow_symlinks=False)
            except FileNotFoundError: target_status = None
            source_exists = source_status is not None
            target_exists = target_status is not None
            if kind == "install":
                if source_exists and target_exists:
                    raise ValueError(f"install state is ambiguous: {target}")
                if target_exists:
                    target_digest, target_entry_identity = entry_digest_and_identity(target_parent, target_name)
                    if (target_digest != expected or
                        (operation.get("target_entry") is not None and target_entry_identity != operation["target_entry"])):
                        raise ValueError(f"installed target changed after interruption: {target}")
                    rename_exclusive(target_parent, target_name, source_parent, source_name)
                elif source_exists:
                    source_digest, source_entry_identity = entry_digest_and_identity(source_parent, source_name)
                    if (source_digest != expected or
                        (operation.get("target_entry") is not None and source_entry_identity != operation["target_entry"])):
                        raise ValueError(f"restored staged target changed after interruption: {source}")
                else:
                    raise ValueError(f"installed target and staged source are both missing: {target}")
            else:
                if source_exists and target_exists:
                    raise ValueError(f"backup state is ambiguous: {target}")
                if source_exists:
                    source_digest, source_entry_identity = entry_digest_and_identity(source_parent, source_name)
                    if (source_digest != expected or
                        (operation.get("source_entry") is not None and source_entry_identity != operation["source_entry"])):
                        raise ValueError(f"backup changed after interruption: {source}")
                    rename_exclusive(source_parent, source_name, target_parent, target_name)
                elif target_exists:
                    target_digest, target_entry_identity = entry_digest_and_identity(target_parent, target_name)
                    if (target_digest != expected or
                        (operation.get("source_entry") is not None and target_entry_identity != operation["source_entry"])):
                        raise ValueError(f"original target changed after interruption: {target}")
                else:
                    raise ValueError(f"original target is missing after interruption: {target}")
            os.fsync(source_parent); os.fsync(target_parent)
            os.close(source_parent); os.close(target_parent)
            recovered_operations += 1
            if recovered_operations == 1 and os.environ.get("STATELET_INSTALL_CRASH_DURING_RECOVERY") == "1":
                os.kill(os.getpid(), signal.SIGKILL)
        data["files_restored"] = True
        write(data)
    launch_failed = False
    launch = data.get("launch")
    if data["state"] == "files-committed" and not isinstance(launch, dict):
        raise ValueError("transaction launch state is invalid")
    launch_skipped = launch == {"skipped": True}
    if data["state"] == "files-committed" and launch_skipped:
        pass
    elif data["state"] in {"active", "files-committed"} and isinstance(launch, dict) and not launch_skipped:
        domain = f"gui/{os.getuid()}"
        should_load_values = launch["loaded"] if data["state"] == "active" else launch.get("desired")
        sequences = [launch.get(key) for key in ("labels", "plists", "loaded", "pending", "changed")]
        expected_plists = args[4:8]
        expected_labels = [Path(value).stem for value in expected_plists]
        active_targets = {
            Path(data["operations"][index]["target"])
            for index in active_install_indices(data["operations"])
        }
        expected_desired = [True, Path(expected_plists[1]) in active_targets, False, False]
        if (not all(isinstance(values, list) and len(values) == 4 for values in sequences)
                or not all(isinstance(value, str) and value for value in launch["labels"] + launch["plists"])
                or not all(isinstance(value, bool) for key in ("loaded", "pending", "changed") for value in launch[key])
                or not isinstance(should_load_values, list) or len(should_load_values) != 4
                or not all(isinstance(value, bool) for value in should_load_values)
                or launch["plists"] != expected_plists or launch["labels"] != expected_labels
                or (data["state"] == "files-committed" and launch.get("desired") != expected_desired)):
            raise ValueError("transaction launch state is invalid")
        for label, plist, should_load, pending, changed in zip(launch["labels"], launch["plists"], should_load_values, launch["pending"], launch["changed"]):
            loaded = subprocess.run(["launchctl", "print", f"{domain}/{label}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
            if data["state"] == "active" and not changed and not pending:
                continue
            if data["state"] == "active" and should_load:
                try:
                    validate_restored_launch_plist(data, label, plist)
                except (OSError, ValueError):
                    raise ValueError("restored launch plist is ambiguous")
            if loaded and (data["state"] == "active" or not should_load):
                result = subprocess.run(["launchctl", "bootout", f"{domain}/{label}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if result.returncode != 0:
                    launch_failed = True
                for _ in range(40):
                    if subprocess.run(["launchctl", "print", f"{domain}/{label}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
                        break
                    time.sleep(0.05)
                else:
                    launch_failed = True
                loaded = False
            if should_load and not loaded:
                try:
                    if data["state"] == "active":
                        validate_restored_launch_plist(data, label, plist)
                    else:
                        validate_launch_plist(data, label, plist)
                except (OSError, ValueError):
                    if data["state"] == "active":
                        raise ValueError("restored launch plist is ambiguous")
                    launch_failed = True
                    continue
                result = subprocess.run(["launchctl", "bootstrap", domain, plist], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if result.returncode != 0:
                    launch_failed = True
                    continue
                for _ in range(40):
                    if subprocess.run(["launchctl", "print", f"{domain}/{label}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                        break
                    time.sleep(0.05)
                else:
                    launch_failed = True
                try:
                    if data["state"] == "files-committed":
                        validate_launch_plist(data, label, plist)
                    else:
                        validate_restored_launch_plist(data, label, plist)
                except (OSError, ValueError):
                    if data["state"] == "active":
                        raise ValueError("restored launch plist is ambiguous")
                    launch_failed = True
            elif not should_load and subprocess.run(["launchctl", "print", f"{domain}/{label}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                launch_failed = True
    if launch_failed:
        raise SystemExit(71)
    shutil.rmtree(root)
    sync_directory(root.parent)
    if data["state"] in {"files-committed", "committed"}:
        raise SystemExit(77)
else:
    raise ValueError("unknown journal command")
PY
}

recover_transaction() {
  if [[ ! -e "$transaction_root" ]]; then return 0; fi
  journal_command recover \
    "$app_dest" "$legacy_app" "$component_dir" "$legacy_component" \
    "$aggregator_plist" "$player_plist" "$legacy_aggregator_plist" "$legacy_player_plist" \
    "$hooks_file" "$applications_dir" "$home_dir/Library" "$home_dir/Library/Application Support" \
    "$support_dir" "$launch_agents_dir" "$home_dir/.codex" "$media_dir" "$runtime_dir" "$logs_dir" "$support_dir" 2>/dev/null
}

if recover_transaction; then
  :
else
  recovery_status=$?
  if [[ "$recovery_status" -eq 77 ]]; then
    printf 'Completed interrupted Statelet installation and launchd reconciliation.\n'
    exit 0
  fi
  if [[ "$recovery_status" -eq 71 ]]; then printf 'Interrupted installation files were recovered but launchd reconciliation was incomplete.\n' >&2; exit 71; fi
  printf 'Refusing to continue because the interrupted Statelet installation is ambiguous.\n' >&2
  exit 74
fi

# Every new and legacy managed target is classified before any destination mutation.
[[ ! -e "$app_dest" ]] || is_managed_app "$app_dest" || { printf 'Refusing to replace an unmanaged app: %s\n' "$app_dest" >&2; exit 1; }
legacy_app_is_managed=0
if [[ -e "$legacy_app" ]]; then
  if is_legacy_app "$legacy_app"; then legacy_app_is_managed=1; fi
fi
[[ ! -e "$component_dir" ]] || is_canonical_component "$component_dir" || { printf 'Refusing to replace an unmanaged component directory: %s\n' "$component_dir" >&2; exit 1; }
legacy_component_is_managed=0
if [[ -e "$legacy_component" ]]; then
  is_legacy_component "$legacy_component" || { printf 'Refusing to migrate an unmanaged legacy component: %s\n' "$legacy_component" >&2; exit 1; }
  legacy_component_is_managed=1
fi
for plist in "$aggregator_plist" "$player_plist"; do
  [[ ! -e "$plist" ]] || is_canonical_plist "$plist" || { printf 'Refusing to replace an unmanaged LaunchAgent: %s\n' "$plist" >&2; exit 1; }
done
for plist in "$legacy_aggregator_plist" "$legacy_player_plist"; do
  [[ ! -e "$plist" ]] || is_legacy_plist "$plist" || { printf 'Refusing to migrate an unmanaged legacy LaunchAgent: %s\n' "$plist" >&2; exit 1; }
done

for plist in "$player_plist" "$legacy_player_plist"; do
  if [[ -f "$plist" ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "$plist" 2>/dev/null || true)" == "false" ]]; then
    player_run_at_load=0
    break
  fi
done

journal_command init
committed=0
labels=("$aggregator_label" "$player_label" "$legacy_aggregator_label" "$legacy_player_label")
plists=("$aggregator_plist" "$player_plist" "$legacy_aggregator_plist" "$legacy_player_plist")
was_loaded=(0 0 0 0)
desired_loaded=(1 "$install_player" 0 0)

job_is_loaded() { launchctl print "gui/$(id -u)/$1" >/dev/null 2>&1; }
wait_for_job_state() {
  local label="$1" expected="$2" attempts=0 consecutive=0 current
  while [[ "$attempts" -lt 40 ]]; do
    if job_is_loaded "$label"; then current=1; else current=0; fi
    if [[ "$current" -eq "$expected" ]]; then consecutive=$((consecutive + 1)); [[ "$consecutive" -ge 3 ]] && return 0; else consecutive=0; fi
    attempts=$((attempts + 1)); /bin/sleep 0.05
  done
  return 1
}
rollback() {
  local original_status=$?
  trap - EXIT
  if [[ "$committed" -eq 0 ]]; then
    if recover_transaction; then
      :
    else
      recovery_status=$?
      if [[ "$recovery_status" -eq 77 ]]; then
        printf 'Installed Statelet, the Codex lifecycle companion.\n'
        exit 0
      fi
      if [[ "$recovery_status" -eq 71 ]]; then printf 'Installation failed and launchd rollback was incomplete.\n' >&2; exit 71; fi
      printf 'Installation failed and file rollback was ambiguous.\n' >&2
      exit 74
    fi
  fi
  exit "$original_status"
}
trap rollback EXIT
backup_target() { local target="$1" name="$2"; if [[ -e "$target" ]]; then local saved="$backup_root/$name" digest; mkdir -p "$(dirname "$saved")"; digest="$("$python_bin" "$script_dir/merge_hooks.py" --safe-tree-digest "$target")"; journal_command backup-move "$target" "$saved" "$digest" 2>/dev/null || { printf 'Statelet backup failed safely.\n' >&2; exit 74; }; fi; }
install_target() { local staged="$1" target="$2" parent digest; parent="$(dirname "$target")"; is_safe_destination_dir "$parent" || { printf 'Installation target parent is unsafe.\n' >&2; exit 74; }; case "$parent" in "$support_dir"|"$support_dir"/*) validate_support_parent_chain "$parent" || { printf 'Installation target parent is unsafe.\n' >&2; exit 74; } ;; esac; digest="$("$python_bin" "$script_dir/merge_hooks.py" --safe-tree-digest "$staged")"; journal_command install-move "$staged" "$target" "$digest" 2>/dev/null || { printf 'Statelet publication failed safely.\n' >&2; exit 74; }; }

stage_app="$stage_root/Statelet.app"
stage_component="$stage_root/Statelet"
stage_aggregator_plist="$stage_root/$aggregator_label.plist"
stage_player_plist="$stage_root/$player_label.plist"
ditto "$app_bundle" "$stage_app"
mkdir -p "$stage_component/python"
install -m 0644 "$repo_root/mac/codex_pet_state.py" "$stage_component/python/statelet_state.py"
install -m 0755 "$repo_root/mac/codex_pet_state_aggregator.py" "$stage_component/python/statelet_state_aggregator.py"
install -m 0755 "$repo_root/mac/codex_pet_hook.py" "$stage_component/python/statelet_hook.py"
printf '%s\n' "$managed_marker" > "$stage_component/MANAGED_BY_STATELET"
chmod 0644 "$stage_component/MANAGED_BY_STATELET"
PYTHONDONTWRITEBYTECODE=1 "$python_bin" -m py_compile "$stage_component/python/statelet_state.py" "$stage_component/python/statelet_state_aggregator.py" "$stage_component/python/statelet_hook.py"
rm -rf "$stage_component/python/__pycache__"

stage_hooks="$stage_root/hooks.json"
"$python_bin" "$script_dir/merge_hooks.py" --destination "$hooks_file" --output "$stage_hooks" --python "$python_bin" --hook-script "$python_dir/statelet_hook.py"
stage_quiesced_hooks="$stage_root/hooks-quiesced.json"
if hook_drain_seconds="$("$python_bin" - "$hooks_file" "$stage_quiesced_hooks" <<'PY'
import json, math, os, shlex, stat, sys
from pathlib import Path

source, output = map(Path, sys.argv[1:])
data = json.loads(source.read_text(encoding="utf-8")) if source.exists() else {}
mode = stat.S_IMODE(source.stat().st_mode) if source.exists() else 0o600
hooks = data.get("hooks", {})
if not isinstance(data, dict) or not isinstance(hooks, dict):
    raise SystemExit(2)
maximum_timeout = 0.0
if isinstance(hooks, dict):
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
                command = item.get("command") if isinstance(item, dict) else None
                try:
                    parts = shlex.split(command) if isinstance(command, str) else []
                except ValueError:
                    parts = []
                normalized = parts[1].replace("\\", "/") if len(parts) == 2 else ""
                managed = (
                    Path(normalized).name in {"statelet_hook.py", "codex_pet_hook.py"}
                    and (
                        any(prefix in normalized for prefix in ("/Library/Application Support/Statelet/", "/Library/Application Support/CodexPet/"))
                        or normalized.endswith("/Documents/codex-pet-dev-board/mac/codex_pet_hook.py")
                        or normalized.endswith("/Documents/codex-pet-dev-board/mac/statelet_hook.py")
                        or normalized.endswith("/Documents/codex-pet-arduino/mac/codex_pet_hook.py")
                        or normalized.endswith("/Documents/codex-pet-arduino/mac/statelet_hook.py")
                    )
                )
                if not managed:
                    retained_items.append(item)
                else:
                    try:
                        timeout = float(item["timeout"])
                        if not math.isfinite(timeout) or timeout < 0 or timeout > 60:
                            raise ValueError
                    except KeyError:
                        timeout = 10.0
                    except (TypeError, ValueError):
                        raise SystemExit("Unsupported managed hook timeout.")
                    maximum_timeout = max(maximum_timeout, timeout)
            replacement = dict(group)
            replacement["hooks"] = retained_items
            if retained_items or set(replacement) - {"hooks", "matcher"}:
                retained_groups.append(replacement)
        hooks[event] = retained_groups
output.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
os.chmod(output, mode)
print(maximum_timeout + 0.1 if maximum_timeout else 0.0)
PY
)"; then
  :
else
  printf 'Refusing unsupported Statelet hook configuration.\n' >&2
  exit 1
fi

"$python_bin" - "$stage_aggregator_plist" "$stage_player_plist" "$python_bin" "$python_dir" "$support_dir" "$app_dest" "$aggregator_label" "$player_label" "$managed_marker" "$player_run_at_load" <<'PY'
import plistlib, sys
from pathlib import Path
(aggregator_path, player_path, python_bin, python_dir, support_dir, app_dest,
 aggregator_label, player_label, marker, player_run_at_load) = sys.argv[1:]
support = Path(support_dir)
common = {"StateletManaged": marker, "ProcessType": "Background", "RunAtLoad": True, "ThrottleInterval": 10}
aggregator = {**common, "Label": aggregator_label, "KeepAlive": True,
 "ProgramArguments": [python_bin, "-B", str(Path(python_dir) / "statelet_state_aggregator.py"), "--state-dir", str(support / "sessions"), "--output", str(support / "runtime/current_state.json")],
 "WorkingDirectory": python_dir, "StandardOutPath": str(support / "logs/state-aggregator.out.log"), "StandardErrorPath": str(support / "logs/state-aggregator.err.log")}
player = {**common, "RunAtLoad": player_run_at_load == "1", "Label": player_label, "KeepAlive": False,
 "LimitLoadToSessionType": "Aqua", "ProcessType": "Interactive",
 "ProgramArguments": [str(Path(app_dest) / "Contents/MacOS/Statelet"), "--media-map", str(support / "media/media-map.json"), "--state", str(support / "runtime/current_state.json")],
 "StandardOutPath": str(support / "logs/mac-player.out.log"), "StandardErrorPath": str(support / "logs/mac-player.err.log")}
for path, payload in ((aggregator_path, aggregator), (player_path, player)):
    with Path(path).open("wb") as handle: plistlib.dump(payload, handle, sort_keys=True)
PY
plutil -lint "$stage_aggregator_plist" "$stage_player_plist" >/dev/null

if [[ "$skip_launchctl" -eq 0 ]]; then
  for ((index=0; index<4; index++)); do if job_is_loaded "${labels[$index]}"; then was_loaded[$index]=1; fi; done
  journal_command launch-init "${labels[@]}" "${plists[@]}" "${was_loaded[@]}" "${desired_loaded[@]}"
  for ((index=0; index<4; index++)); do
    label="${labels[$index]}"
    if [[ "${was_loaded[$index]}" -eq 1 ]]; then
      journal_command launch-phase "$index" pending
      if ! launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1; then
        if wait_for_job_state "$label" "${was_loaded[$index]}"; then
          journal_command launch-phase "$index" clear
          printf 'Could not stop managed LaunchAgent %s; installation was not applied.\n' "$label" >&2
          exit 72
        fi
        printf 'Managed LaunchAgent %s entered an ambiguous state; installation was not applied.\n' "$label" >&2
        exit 71
      fi
      if [[ "${STATELET_INSTALL_CRASH_AT:-}" == "after-first-bootout-submit" ]]; then kill -KILL $$; fi
      wait_for_job_state "$label" 0 || { printf 'Managed LaunchAgent %s remained loaded; installation was not applied.\n' "$label" >&2; exit 72; }
      journal_command launch-phase "$index" changed
      if [[ "${STATELET_INSTALL_CRASH_AT:-}" == "after-first-bootout" ]]; then kill -KILL $$; fi
    fi
  done
else
  journal_command launch-skip
fi

if [[ -e "$hooks_file" ]]; then
  backup_target "$hooks_file" hooks-original.json
  install_target "$stage_quiesced_hooks" "$hooks_file"
fi
backup_target "$component_dir" component
[[ "$legacy_component_is_managed" -eq 0 ]] || backup_target "$legacy_component" legacy/component
# Drain already-running managed hooks for the largest configured timeout,
# bounded to 10 seconds. The final post-publication digest check remains
# authoritative if a process outlives that contract.
[[ "$hook_drain_seconds" == "0.0" ]] || /bin/sleep "$hook_drain_seconds"

# An unpublished interim build persisted thread titles beside the activity
# records. Remove that file only after managed writers are quiesced and only
# through the journal, so a later installation rollback restores it.
if obsolete_activity_titles_status="$(classify_obsolete_activity_titles)"; then
  if [[ "$obsolete_activity_titles_status" == "regular" ]]; then
    backup_target "$support_dir/sessions/activity-titles-v1.json" obsolete/activity-titles-v1.json
  fi
else
  printf 'Refusing unsafe obsolete Statelet activity metadata.\n' >&2
  exit 1
fi

migration_relatives=()
migration_digests=()
migration_present_relatives=()
migration_copy_relatives=()
# Snapshot legacy data only after all managed legacy/canonical writers are
# quiesced. Completed provenance makes canonical authoritative only when the
# retained legacy source still matches the attested digest.
for relative in media voice characters sessions alpha-runtime runtime/current_state.json; do
  source="$legacy_support/$relative"
  destination="$support_dir/$relative"
  migration_relatives+=("$relative")
  if [[ -e "$source" ]]; then
    is_owned_legacy_data "$source" || { printf 'Refusing unowned legacy Statelet data.\n' >&2; exit 1; }
    source_digest="$("$python_bin" "$script_dir/merge_hooks.py" --safe-tree-digest "$source")" || { printf 'Refusing unsafe legacy Statelet data.\n' >&2; exit 1; }
    migration_digests+=("$source_digest")
    migration_present_relatives+=("$relative")
    attested=0
    if migration_attests "$relative" "$source_digest"; then attested=1; fi
    if [[ -e "$destination" ]]; then
      destination_digest="$("$python_bin" "$script_dir/merge_hooks.py" --safe-tree-digest "$destination")" || { printf 'Refusing unsafe Statelet destination data.\n' >&2; exit 1; }
      if [[ "$source_digest" != "$destination_digest" && "$attested" -eq 0 ]]; then
        printf 'Refusing to overwrite conflicting Statelet data.\n' >&2
        exit 1
      fi
    elif [[ "$attested" -eq 0 ]]; then
      migration_copy_relatives+=("$relative")
    fi
  else
    migration_digests+=("__absent__")
  fi
done

stage_migration_manifest="$stage_root/legacy-migration-v1.json"
migration_manifest_args=("$stage_migration_manifest" "$legacy_marker" "$legacy_support")
for ((index=0; index<${#migration_present_relatives[@]}; index++)); do migration_manifest_args+=("${migration_present_relatives[$index]}"); done
migration_manifest_args+=(--)
for ((index=0; index<${#migration_relatives[@]}; index++)); do
  [[ "${migration_digests[$index]}" == "__absent__" ]] || migration_manifest_args+=("${migration_digests[$index]}")
done
"$python_bin" - "${migration_manifest_args[@]}" <<'PY'
import json, os, sys
from pathlib import Path

path = Path(sys.argv[1])
identity = sys.argv[2]
source_root = sys.argv[3]
separator = sys.argv.index("--")
relatives = sys.argv[4:separator]
digests = sys.argv[separator + 1:]
if len(relatives) != len(digests):
    raise SystemExit("invalid migration manifest inputs")
with path.open("w", encoding="utf-8") as handle:
    json.dump(
        {"version": 1, "source_identity": identity, "source_root": source_root, "subtrees": dict(zip(relatives, digests))},
        handle,
        sort_keys=True,
        separators=(",", ":"),
    )
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.chmod(path, 0o600)
PY

for ((index=0; index<${#migration_copy_relatives[@]}; index++)); do
  relative="${migration_copy_relatives[$index]}"
  source="$legacy_support/$relative"
  destination="$support_dir/$relative"
  mkdir -p "$(dirname "$stage_root/migration/$relative")"
  "$python_bin" "$script_dir/merge_hooks.py" --safe-copy-source "$source" --safe-copy-destination "$stage_root/migration/$relative"
done

# Hooks can still write while launchd is quiesced. Revalidate every selected
# source and staged copy immediately before the first destination mutation.
if [[ -n "${STATELET_INSTALL_TEST_MIGRATION_GATE:-}" ]]; then
  gate="${STATELET_INSTALL_TEST_MIGRATION_GATE}"
  [[ "$gate" = "$home_dir"/* ]] || { printf 'Invalid migration test gate.\n' >&2; exit 2; }
  : > "$gate.ready"
  attempt=0
  while [[ "$attempt" -lt 200 && ! -e "$gate.release" ]]; do /bin/sleep 0.01; attempt=$((attempt + 1)); done
  [[ -e "$gate.release" ]] || { printf 'Migration test gate timed out.\n' >&2; exit 76; }
fi
for ((index=0; index<${#migration_relatives[@]}; index++)); do
  relative="${migration_relatives[$index]}"
  source="$legacy_support/$relative"
  expected_digest="${migration_digests[$index]}"
  if [[ "$expected_digest" == "__absent__" ]]; then
    [[ ! -e "$source" ]] || { printf 'Legacy Statelet data changed during migration.\n' >&2; exit 75; }
    continue
  fi
  current_digest="$("$python_bin" "$script_dir/merge_hooks.py" --safe-tree-digest "$source")" || { printf 'Legacy Statelet data changed during migration.\n' >&2; exit 75; }
  [[ "$current_digest" == "$expected_digest" ]] || { printf 'Legacy Statelet data changed during migration.\n' >&2; exit 75; }
  if [[ -e "$stage_root/migration/$relative" ]]; then
    staged_digest="$("$python_bin" "$script_dir/merge_hooks.py" --safe-tree-digest "$stage_root/migration/$relative")"
    [[ "$staged_digest" == "$expected_digest" ]] || { printf 'Staged Statelet data failed migration validation.\n' >&2; exit 75; }
  fi
done

ensure_dir() { if [[ -e "$1" || -L "$1" ]]; then is_safe_destination_dir "$1" || { printf 'Refusing unsafe Statelet destination directory.\n' >&2; exit 1; }; else journal_command mkdir-make "$1" 0755 2>/dev/null || { printf 'Statelet directory creation failed safely.\n' >&2; exit 74; }; is_safe_destination_dir "$1" || exit 1; fi; }
ensure_private_dir() { if [[ -e "$1" || -L "$1" ]]; then is_safe_destination_dir "$1" || { printf 'Refusing unsafe Statelet destination directory.\n' >&2; exit 1; }; else journal_command mkdir-make "$1" 0700 2>/dev/null || { printf 'Statelet directory creation failed safely.\n' >&2; exit 74; }; is_safe_destination_dir "$1" || exit 1; fi; }
ensure_dir "$applications_dir"
ensure_dir "$home_dir/Library"
ensure_dir "$home_dir/Library/Application Support"
ensure_private_dir "$support_dir"
ensure_dir "$launch_agents_dir"
ensure_dir "$home_dir/.codex"

backup_target "$app_dest" app
[[ "$legacy_app_is_managed" -eq 0 ]] || backup_target "$legacy_app" legacy/app
backup_target "$aggregator_plist" agents/aggregator
backup_target "$player_plist" agents/player
[[ ! -e "$legacy_aggregator_plist" ]] || backup_target "$legacy_aggregator_plist" agents/legacy-aggregator
[[ ! -e "$legacy_player_plist" ]] || backup_target "$legacy_player_plist" agents/legacy-player
[[ ! -e "$hooks_file" ]] || backup_target "$hooks_file" hooks-quiesced.json
install_target "$stage_app" "$app_dest"
if [[ "${STATELET_INSTALL_CRASH_AT:-}" == "after-app" ]]; then kill -KILL $$; fi
if [[ "${STATELET_INSTALL_FAIL_AT:-${CODEX_PET_INSTALL_FAIL_AT:-}}" == "after-app" ]]; then printf 'Injected installation failure after app replacement.\n' >&2; exit 70; fi
install_target "$stage_component" "$component_dir"
install_target "$stage_aggregator_plist" "$aggregator_plist"
if [[ "$install_player" -eq 1 ]]; then install_target "$stage_player_plist" "$player_plist"; fi
install_target "$stage_hooks" "$hooks_file"

for ((index=0; index<${#migration_relatives[@]}; index++)); do
  [[ "${migration_digests[$index]}" == "__absent__" ]] && continue
  relative="${migration_relatives[$index]}"
  destination="$support_dir/$relative"
  if [[ -e "$stage_root/migration/$relative" ]]; then
    destination_parent="$(dirname "$destination")"
    ensure_private_dir "$destination_parent"
    install_target "$stage_root/migration/$relative" "$destination"
  fi
done
backup_target "$migration_manifest" migration-manifest
install_target "$stage_migration_manifest" "$migration_manifest"
for directory in "$media_dir" "$runtime_dir" "$logs_dir"; do ensure_private_dir "$directory"; done
if [[ ! -e "$media_map" ]]; then
  cp "$package_dir/Examples/media-map.json" "$stage_root/media-map.json"
  chmod 0600 "$stage_root/media-map.json"
  install_target "$stage_root/media-map.json" "$media_map"
else
  journal_command retain "$media_map"
fi
if [[ -n "${STATELET_INSTALL_TEST_POSTVALIDATION_GATE:-}" ]]; then
  gate="${STATELET_INSTALL_TEST_POSTVALIDATION_GATE}"
  [[ "$gate" = "$home_dir"/* ]] || { printf 'Invalid migration test gate.\n' >&2; exit 2; }
  : > "$gate.ready"
  attempt=0
  while [[ "$attempt" -lt 200 && ! -e "$gate.release" ]]; do /bin/sleep 0.01; attempt=$((attempt + 1)); done
  [[ -e "$gate.release" ]] || { printf 'Migration test gate timed out.\n' >&2; exit 76; }
fi
for ((index=0; index<${#migration_relatives[@]}; index++)); do
  relative="${migration_relatives[$index]}"
  source="$legacy_support/$relative"
  expected_digest="${migration_digests[$index]}"
  if [[ "$expected_digest" == "__absent__" ]]; then
    [[ ! -e "$source" ]] || { printf 'Legacy Statelet data changed during publication.\n' >&2; exit 75; }
    continue
  fi
  current_digest="$("$python_bin" "$script_dir/merge_hooks.py" --safe-tree-digest "$source")" || { printf 'Legacy Statelet data changed during publication.\n' >&2; exit 75; }
  [[ "$current_digest" == "$expected_digest" ]] || { printf 'Legacy Statelet data changed during publication.\n' >&2; exit 75; }
  destination="$support_dir/$relative"
  if [[ -e "$stage_root/migration/$relative" ]]; then
    published_digest="$("$python_bin" "$script_dir/merge_hooks.py" --safe-tree-digest "$destination")"
    [[ "$published_digest" == "$expected_digest" ]] || { printf 'Published Statelet data failed migration validation.\n' >&2; exit 75; }
  fi
done
if [[ "${STATELET_INSTALL_CRASH_AT:-}" == "after-support" ]]; then kill -KILL $$; fi
if [[ "${STATELET_INSTALL_FAIL_AT:-${CODEX_PET_INSTALL_FAIL_AT:-}}" == "after-support" ]]; then printf 'Injected installation failure after support migration.\n' >&2; exit 70; fi

journal_command files-commit \
  "$app_dest" "$legacy_app" "$component_dir" "$legacy_component" \
  "$aggregator_plist" "$player_plist" "$legacy_aggregator_plist" "$legacy_player_plist" \
  "$hooks_file" "$applications_dir" "$home_dir/Library" "$home_dir/Library/Application Support" \
  "$support_dir" "$launch_agents_dir" "$home_dir/.codex" "$media_dir" "$runtime_dir" "$logs_dir" \
  "$support_dir/media" "$support_dir/voice" "$support_dir/characters" "$support_dir/sessions" \
  "$support_dir/sessions/activity-titles-v1.json" \
  "$support_dir/alpha-runtime" "$support_dir/runtime/current_state.json" "$support_dir/media/media-map.json" \
  "$support_dir/.legacy-migration-v1.json" "$support_dir"
if [[ "${STATELET_INSTALL_CRASH_AT:-}" == "after-files-commit" ]]; then kill -KILL $$; fi

if [[ "$skip_launchctl" -eq 0 ]]; then
  journal_command launch-phase 0 pending
  journal_command launch-validate "$aggregator_label" "$aggregator_plist"
  launchctl bootstrap "gui/$(id -u)" "$aggregator_plist"
  wait_for_job_state "$aggregator_label" 1 || { printf 'The aggregator LaunchAgent did not load after bootstrap.\n' >&2; exit 73; }
  journal_command launch-validate "$aggregator_label" "$aggregator_plist"
  if [[ "${STATELET_INSTALL_CRASH_AT:-}" == "after-aggregator-rebootstrap" ]]; then kill -KILL $$; fi
  journal_command launch-phase 0 changed
  if [[ "$install_player" -eq 1 ]]; then
    journal_command launch-phase 1 pending
    journal_command launch-validate "$player_label" "$player_plist"
    launchctl bootstrap "gui/$(id -u)" "$player_plist"
    wait_for_job_state "$player_label" 1 || { printf 'The player LaunchAgent did not register after bootstrap.\n' >&2; exit 73; }
    journal_command launch-validate "$player_label" "$player_plist"
    journal_command launch-phase 1 changed
    [[ "$player_run_at_load" -eq 1 ]] || /usr/bin/open "$app_dest"
  fi
fi

journal_command commit \
  "$app_dest" "$legacy_app" "$component_dir" "$legacy_component" \
  "$aggregator_plist" "$player_plist" "$legacy_aggregator_plist" "$legacy_player_plist" \
  "$hooks_file" "$applications_dir" "$home_dir/Library" "$home_dir/Library/Application Support" \
  "$support_dir" "$launch_agents_dir" "$home_dir/.codex" "$media_dir" "$runtime_dir" "$logs_dir" \
  "$support_dir/media" "$support_dir/voice" "$support_dir/characters" "$support_dir/sessions" \
  "$support_dir/sessions/activity-titles-v1.json" \
  "$support_dir/alpha-runtime" "$support_dir/runtime/current_state.json" "$support_dir/media/media-map.json" \
  "$support_dir/.legacy-migration-v1.json" "$support_dir"
committed=1
rm -rf "$transaction_root"
trap - EXIT
printf 'Installed Statelet, the Codex lifecycle companion.\n'
printf '  App: %s\n  Media map: %s\n  Aggregator: %s\n' "$app_dest" "$media_map" "$aggregator_plist"
if [[ "$install_player" -eq 1 ]]; then printf '  Player: %s\n' "$player_plist"; else printf '  Player LaunchAgent: not installed\n'; fi
