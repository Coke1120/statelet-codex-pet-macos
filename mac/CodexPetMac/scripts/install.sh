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
import hashlib, json, os, shutil, stat, sys
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
    if data.get("version") != 1 or data.get("home") != str(home) or data.get("state") not in {"active", "committed"}:
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
elif command == "commit":
    data = load()
    data["state"] = "committed"
    write(data)
elif command == "recover":
    data = load()
    root_prefix = str(root) + os.sep
    allowed_exact = set(args[:-1])
    support = args[-1]
    allowed_support = {
        os.path.join(support, relative)
        for relative in ("media", "voice", "characters", "sessions", "alpha-runtime", "runtime/current_state.json", "media/media-map.json", ".legacy-migration-v1.json")
    }
    allowed_exact.update(allowed_support)
    if data["state"] == "active":
        for operation in reversed(data["operations"]):
            kind = operation.get("kind")
            source = Path(operation.get("source", ""))
            target = Path(operation.get("target", ""))
            expected = operation.get("digest", "")
            if not target.is_absolute() or str(target) not in allowed_exact:
                raise ValueError(f"transaction target is outside the installer allowlist: {target}")
            if kind == "mkdir":
                if target.is_dir():
                    try:
                        target.rmdir()
                    except OSError as error:
                        raise ValueError(f"created directory is no longer empty: {target}") from error
                elif target.exists() or target.is_symlink():
                    raise ValueError(f"created directory became ambiguous: {target}")
                continue
            if kind not in {"backup", "install"} or not str(source).startswith(root_prefix):
                raise ValueError("transaction operation is invalid")
            source_exists = source.exists() or source.is_symlink()
            target_exists = target.exists() or target.is_symlink()
            if kind == "install":
                if source_exists and target_exists:
                    raise ValueError(f"install state is ambiguous: {target}")
                if target_exists:
                    if digest(target) != expected:
                        raise ValueError(f"installed target changed after interruption: {target}")
                    shutil.rmtree(target) if target.is_dir() else target.unlink()
                elif not source_exists:
                    raise ValueError(f"installed target and staged source are both missing: {target}")
            else:
                if source_exists and target_exists:
                    raise ValueError(f"backup state is ambiguous: {target}")
                if source_exists:
                    if digest(source) != expected:
                        raise ValueError(f"backup changed after interruption: {source}")
                    target.parent.mkdir(parents=True, exist_ok=True)
                    os.rename(source, target)
                elif not target_exists or digest(target) != expected:
                    raise ValueError(f"original target changed after interruption: {target}")
    shutil.rmtree(root)
    sync_directory(root.parent)
else:
    raise ValueError("unknown journal command")
PY
}

recover_transaction() {
  [[ ! -e "$transaction_root" ]] || journal_command recover \
    "$app_dest" "$legacy_app" "$component_dir" "$legacy_component" \
    "$aggregator_plist" "$player_plist" "$legacy_aggregator_plist" "$legacy_player_plist" \
    "$hooks_file" "$applications_dir" "$home_dir/Library" "$home_dir/Library/Application Support" \
    "$support_dir" "$launch_agents_dir" "$home_dir/.codex" "$media_dir" "$runtime_dir" "$logs_dir" "$support_dir"
}

if ! recover_transaction; then
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

migration_relatives=()
migration_digests=()
# Before a completed migration is attested, canonical data wins only when it
# matches the legacy source. Afterwards canonical is authoritative while the
# attested, unchanged legacy source remains preserved for compatibility.
for relative in media voice characters sessions alpha-runtime runtime/current_state.json; do
  source="$legacy_support/$relative"
  destination="$support_dir/$relative"
  if [[ -e "$source" ]]; then
    is_owned_legacy_data "$source" || { printf 'Refusing unowned legacy Statelet data: %s\n' "$source" >&2; exit 1; }
    source_digest="$("$python_bin" "$script_dir/merge_hooks.py" --safe-tree-digest "$source")" || { printf 'Refusing unsafe legacy Statelet data: %s\n' "$source" >&2; exit 1; }
    migration_relatives+=("$relative")
    migration_digests+=("$source_digest")
    if [[ -e "$destination" ]]; then
      destination_digest="$("$python_bin" "$script_dir/merge_hooks.py" --safe-tree-digest "$destination")" || { printf 'Refusing unsafe Statelet destination data: %s\n' "$destination" >&2; exit 1; }
      if [[ "$source_digest" != "$destination_digest" ]] && ! migration_attests "$relative" "$source_digest"; then
        printf 'Refusing to overwrite conflicting Statelet data: %s\n' "$destination" >&2
        exit 1
      fi
    fi
  fi
done

for plist in "$player_plist" "$legacy_player_plist"; do
  if [[ -f "$plist" ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "$plist" 2>/dev/null || true)" == "false" ]]; then
    player_run_at_load=0
    break
  fi
done

journal_command init
installed_targets=()
backed_up_targets=()
backed_up_paths=()
created_dirs=()
committed=0
targets_mutated=0
launch_state_mutated=0
labels=("$aggregator_label" "$player_label" "$legacy_aggregator_label" "$legacy_player_label")
plists=("$aggregator_plist" "$player_plist" "$legacy_aggregator_plist" "$legacy_player_plist")
was_loaded=(0 0 0 0)
transition_requested=(0 0 0 0)

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
restore_jobs() {
  local index label plist
  for ((index=0; index<4; index++)); do
    label="${labels[$index]}"; plist="${plists[$index]}"
    if job_is_loaded "$label"; then launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || return 1; wait_for_job_state "$label" 0 || return 1; fi
    if [[ "${was_loaded[$index]}" -eq 1 ]]; then
      [[ -f "$plist" ]] || return 1
      launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1 || return 1
      wait_for_job_state "$label" 1 || return 1
    fi
  done
}
rollback() {
  local original_status=$? index rollback_failed=0
  trap - EXIT
  if [[ "$committed" -eq 0 ]]; then
    if ! recover_transaction; then
      printf 'Installation failed and file rollback was ambiguous.\n' >&2
      exit 74
    fi
    if [[ "$skip_launchctl" -eq 0 && "$launch_state_mutated" -eq 1 ]]; then restore_jobs || rollback_failed=1; fi
  fi
  if [[ "$rollback_failed" -ne 0 ]]; then printf 'Installation failed and launchd rollback was incomplete.\n' >&2; exit 71; fi
  exit "$original_status"
}
trap rollback EXIT

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

"$python_bin" - "$stage_aggregator_plist" "$stage_player_plist" "$python_bin" "$python_dir" "$support_dir" "$app_dest" "$aggregator_label" "$player_label" "$managed_marker" "$player_run_at_load" <<'PY'
import plistlib, sys
from pathlib import Path
(aggregator_path, player_path, python_bin, python_dir, support_dir, app_dest,
 aggregator_label, player_label, marker, player_run_at_load) = sys.argv[1:]
support = Path(support_dir)
common = {"StateletManaged": marker, "ProcessType": "Background", "RunAtLoad": True, "ThrottleInterval": 10}
aggregator = {**common, "Label": aggregator_label, "KeepAlive": True,
 "ProgramArguments": [python_bin, str(Path(python_dir) / "statelet_state_aggregator.py"), "--state-dir", str(support / "sessions"), "--output", str(support / "runtime/current_state.json")],
 "WorkingDirectory": python_dir, "StandardOutPath": str(support / "logs/state-aggregator.out.log"), "StandardErrorPath": str(support / "logs/state-aggregator.err.log")}
player = {**common, "RunAtLoad": player_run_at_load == "1", "Label": player_label, "KeepAlive": False,
 "LimitLoadToSessionType": "Aqua", "ProcessType": "Interactive",
 "ProgramArguments": [str(Path(app_dest) / "Contents/MacOS/Statelet"), "--media-map", str(support / "media/media-map.json"), "--state", str(support / "runtime/current_state.json")],
 "StandardOutPath": str(support / "logs/mac-player.out.log"), "StandardErrorPath": str(support / "logs/mac-player.err.log")}
for path, payload in ((aggregator_path, aggregator), (player_path, player)):
    with Path(path).open("wb") as handle: plistlib.dump(payload, handle, sort_keys=True)
PY
plutil -lint "$stage_aggregator_plist" "$stage_player_plist" >/dev/null

stage_migration_manifest="$stage_root/legacy-migration-v1.json"
migration_manifest_args=("$stage_migration_manifest" "$legacy_marker" "$legacy_support")
for ((index=0; index<${#migration_relatives[@]}; index++)); do migration_manifest_args+=("${migration_relatives[$index]}"); done
migration_manifest_args+=(--)
for ((index=0; index<${#migration_digests[@]}; index++)); do migration_manifest_args+=("${migration_digests[$index]}"); done
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

for relative in media voice characters sessions alpha-runtime runtime/current_state.json; do
  source="$legacy_support/$relative"
  destination="$support_dir/$relative"
  if [[ -e "$source" && ! -e "$destination" ]]; then
    mkdir -p "$(dirname "$stage_root/migration/$relative")"
    "$python_bin" "$script_dir/merge_hooks.py" --safe-copy-source "$source" --safe-copy-destination "$stage_root/migration/$relative"
  fi
done

if [[ "$skip_launchctl" -eq 0 ]]; then
  for ((index=0; index<4; index++)); do
    label="${labels[$index]}"
    if job_is_loaded "$label"; then
      was_loaded[$index]=1; transition_requested[$index]=1
      launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || { printf 'Could not stop managed LaunchAgent %s; installation was not applied.\n' "$label" >&2; exit 72; }
      wait_for_job_state "$label" 0 || { printf 'Managed LaunchAgent %s remained loaded; installation was not applied.\n' "$label" >&2; exit 72; }
      launch_state_mutated=1
    fi
  done
fi

ensure_dir() { if [[ ! -d "$1" ]]; then journal_command record mkdir "" "$1" ""; mkdir "$1"; created_dirs+=("$1"); fi; }
ensure_private_dir() { if [[ ! -d "$1" ]]; then journal_command record mkdir "" "$1" ""; mkdir -m 0700 "$1"; created_dirs+=("$1"); fi; }
ensure_dir "$applications_dir"
ensure_dir "$home_dir/Library"
ensure_dir "$home_dir/Library/Application Support"
ensure_private_dir "$support_dir"
ensure_dir "$launch_agents_dir"
ensure_dir "$home_dir/.codex"
backup_target() { local target="$1" name="$2"; if [[ -e "$target" ]]; then local saved="$backup_root/$name" digest; mkdir -p "$(dirname "$saved")"; digest="$("$python_bin" "$script_dir/merge_hooks.py" --safe-tree-digest "$target")"; journal_command record backup "$saved" "$target" "$digest"; mv "$target" "$saved"; backed_up_targets+=("$target"); backed_up_paths+=("$saved"); fi; }
install_target() { local staged="$1" target="$2" digest; mkdir -p "$(dirname "$target")"; digest="$("$python_bin" "$script_dir/merge_hooks.py" --safe-tree-digest "$staged")"; journal_command record install "$staged" "$target" "$digest"; mv "$staged" "$target"; installed_targets+=("$target"); }

targets_mutated=1
backup_target "$app_dest" app
[[ "$legacy_app_is_managed" -eq 0 ]] || backup_target "$legacy_app" legacy/app
backup_target "$component_dir" component
[[ "$legacy_component_is_managed" -eq 0 ]] || backup_target "$legacy_component" legacy/component
backup_target "$aggregator_plist" agents/aggregator
backup_target "$player_plist" agents/player
[[ ! -e "$legacy_aggregator_plist" ]] || backup_target "$legacy_aggregator_plist" agents/legacy-aggregator
[[ ! -e "$legacy_player_plist" ]] || backup_target "$legacy_player_plist" agents/legacy-player
backup_target "$hooks_file" hooks.json
install_target "$stage_app" "$app_dest"
if [[ "${STATELET_INSTALL_CRASH_AT:-}" == "after-app" ]]; then kill -KILL $$; fi
if [[ "${STATELET_INSTALL_FAIL_AT:-${CODEX_PET_INSTALL_FAIL_AT:-}}" == "after-app" ]]; then printf 'Injected installation failure after app replacement.\n' >&2; exit 70; fi
install_target "$stage_component" "$component_dir"
install_target "$stage_aggregator_plist" "$aggregator_plist"
if [[ "$install_player" -eq 1 ]]; then install_target "$stage_player_plist" "$player_plist"; fi
install_target "$stage_hooks" "$hooks_file"

for relative in media voice characters sessions alpha-runtime runtime/current_state.json; do
  source="$legacy_support/$relative"; destination="$support_dir/$relative"
  if [[ -e "$source" ]]; then
    if [[ -e "$stage_root/migration/$relative" ]]; then install_target "$stage_root/migration/$relative" "$destination"; fi
  fi
done
backup_target "$migration_manifest" migration-manifest
install_target "$stage_migration_manifest" "$migration_manifest"
for directory in "$media_dir" "$runtime_dir" "$logs_dir"; do if [[ ! -d "$directory" ]]; then journal_command record mkdir "" "$directory" ""; mkdir -m 0700 "$directory"; created_dirs+=("$directory"); fi; done
if [[ ! -e "$media_map" ]]; then cp "$package_dir/Examples/media-map.json" "$stage_root/media-map.json"; chmod 0600 "$stage_root/media-map.json"; install_target "$stage_root/media-map.json" "$media_map"; fi
if [[ "${STATELET_INSTALL_CRASH_AT:-}" == "after-support" ]]; then kill -KILL $$; fi
if [[ "${STATELET_INSTALL_FAIL_AT:-${CODEX_PET_INSTALL_FAIL_AT:-}}" == "after-support" ]]; then printf 'Injected installation failure after support migration.\n' >&2; exit 70; fi

if [[ "$skip_launchctl" -eq 0 ]]; then
  launchctl bootstrap "gui/$(id -u)" "$aggregator_plist"
  wait_for_job_state "$aggregator_label" 1 || { printf 'The aggregator LaunchAgent did not load after bootstrap.\n' >&2; exit 73; }
  if [[ "$install_player" -eq 1 ]]; then
    launchctl bootstrap "gui/$(id -u)" "$player_plist"
    wait_for_job_state "$player_label" 1 || { printf 'The player LaunchAgent did not register after bootstrap.\n' >&2; exit 73; }
    [[ "$player_run_at_load" -eq 1 ]] || /usr/bin/open "$app_dest"
  fi
fi

journal_command commit
committed=1
rm -rf "$transaction_root"
trap - EXIT
printf 'Installed Statelet, the Codex lifecycle companion.\n'
printf '  App: %s\n  Media map: %s\n  Aggregator: %s\n' "$app_dest" "$media_map" "$aggregator_plist"
if [[ "$install_player" -eq 1 ]]; then printf '  Player: %s\n' "$player_plist"; else printf '  Player LaunchAgent: not installed\n'; fi
