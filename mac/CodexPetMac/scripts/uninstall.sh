#!/bin/bash
set -euo pipefail

managed_marker="statelet-v2"
aggregator_label="com.coke1120.statelet.state-aggregator"
player_label="com.coke1120.statelet.mac-player"
script_dir="$(cd "$(dirname "$0")" && pwd -P)"
home_dir="$HOME"
skip_launchctl=0

usage() {
  cat <<'EOF'
Usage: uninstall.sh [--home DIR] [--skip-launchctl]

Removes only the canonical Statelet app, component, and managed LaunchAgents.
User media, voice, characters, state, logs, sessions, and legacy artifacts are preserved.
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --home) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; home_dir="$2"; shift 2 ;;
    --skip-launchctl) skip_launchctl=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ "$home_dir" = /* && "$home_dir" != / ]] || { printf 'Destination home must be an absolute non-root directory.\n' >&2; exit 2; }
[[ -d "$home_dir" ]] || { printf 'Destination home does not exist: %s\n' "$home_dir" >&2; exit 2; }
if [[ "$skip_launchctl" -eq 0 && "$home_dir" != "$HOME" ]]; then printf -- '--home requires --skip-launchctl.\n' >&2; exit 2; fi

app="$home_dir/Applications/Statelet.app"
support="$home_dir/Library/Application Support/Statelet"
component="$support/Statelet"
launch_agents="$home_dir/Library/LaunchAgents"
aggregator_plist="$launch_agents/$aggregator_label.plist"
player_plist="$launch_agents/$player_label.plist"
hooks_file="$home_dir/.codex/hooks.json"
grok_hooks_file="$home_dir/.grok/hooks/statelet.json"
widget_hook="$component/python/statelet_hook.py"

is_managed_app() {
  [[ -f "$1/Contents/Info.plist" ]] &&
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true)" == "com.coke1120.Statelet" ]] &&
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :StateletManaged' "$1/Contents/Info.plist" 2>/dev/null || true)" == "$managed_marker" ]]
}
is_managed_component() { [[ -f "$1/MANAGED_BY_STATELET" ]] && [[ "$(cat "$1/MANAGED_BY_STATELET")" == "$managed_marker" ]]; }
is_managed_plist() { [[ -f "$1" ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print :StateletManaged' "$1" 2>/dev/null || true)" == "$managed_marker" ]]; }

app_is_managed=0
if [[ -e "$app" ]]; then is_managed_app "$app" || { printf 'Refusing to remove unmanaged app: %s\n' "$app" >&2; exit 1; }; app_is_managed=1; fi
if [[ -e "$component" ]] && ! is_managed_component "$component"; then printf 'Refusing to remove unmanaged component: %s\n' "$component" >&2; exit 1; fi
for plist in "$aggregator_plist" "$player_plist"; do
  [[ ! -e "$plist" ]] || is_managed_plist "$plist" || { printf 'Refusing to remove unmanaged LaunchAgent: %s\n' "$plist" >&2; exit 1; }
done

python_bin="$(command -v python3 || true)"
[[ -n "$python_bin" ]] || { printf 'Python 3 is required to validate Statelet hooks.\n' >&2; exit 1; }
attest_hook_config() {
  "$python_bin" - "$home_dir" "$1" <<'PY'
import json, os, stat, sys

home, relative = sys.argv[1:]
parts = tuple(part for part in relative.split("/") if part)
directory_flags = os.O_RDONLY | os.O_DIRECTORY
if hasattr(os, "O_CLOEXEC"):
    directory_flags |= os.O_CLOEXEC
if hasattr(os, "O_NOFOLLOW"):
    directory_flags |= os.O_NOFOLLOW
file_flags = os.O_RDONLY
if hasattr(os, "O_CLOEXEC"):
    file_flags |= os.O_CLOEXEC
if hasattr(os, "O_NOFOLLOW"):
    file_flags |= os.O_NOFOLLOW

def identity(status):
    return [status.st_dev, status.st_ino, status.st_mode, status.st_uid]

current = None
try:
    current = os.open(home, directory_flags)
    home_status = os.fstat(current)
    if not stat.S_ISDIR(home_status.st_mode) or home_status.st_uid != os.getuid():
        raise ValueError
    parents = [identity(home_status)]
    for index, part in enumerate(parts[:-1]):
        try:
            child = os.open(part, directory_flags, dir_fd=current)
        except FileNotFoundError:
            print(json.dumps({"state": "absent", "missing": index, "parents": parents}, separators=(",", ":")))
            raise SystemExit(0)
        child_status = os.fstat(child)
        if not stat.S_ISDIR(child_status.st_mode) or child_status.st_uid != os.getuid():
            os.close(child)
            raise ValueError
        os.close(current)
        current = child
        parents.append(identity(child_status))
    name = parts[-1]
    try:
        before = os.stat(name, dir_fd=current, follow_symlinks=False)
    except FileNotFoundError:
        print(json.dumps({"state": "absent", "missing": len(parts) - 1, "parents": parents}, separators=(",", ":")))
        raise SystemExit(0)
    if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_nlink != 1:
        raise ValueError
    descriptor = os.open(name, file_flags, dir_fd=current)
    try:
        after = os.fstat(descriptor)
        fields = ("st_dev", "st_ino", "st_mode", "st_uid", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
        if any(getattr(before, field) != getattr(after, field) for field in fields):
            raise ValueError
        print(json.dumps({
            "state": "regular",
            "parents": parents,
            "file": [getattr(after, field) for field in fields],
        }, separators=(",", ":")))
    finally:
        os.close(descriptor)
except (OSError, ValueError, IndexError):
    raise SystemExit(1)
finally:
    if current is not None:
        os.close(current)
PY
}
if ! codex_hook_snapshot="$(attest_hook_config .codex/hooks.json)" \
  || ! grok_hook_snapshot="$(attest_hook_config .grok/hooks/statelet.json)"; then
  printf 'Refusing unsafe Statelet hook configuration layout.\n' >&2
  exit 1
fi

trash="$(mktemp -d "$home_dir/.statelet-uninstall.XXXXXX")"
moved_targets=()
moved_paths=()
committed=0
codex_hook_updated=0
grok_hook_updated=0
launch_state_mutated=0
labels=("$aggregator_label" "$player_label")
plists=("$aggregator_plist" "$player_plist")
was_loaded=(0 0)

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
  for ((index=0; index<2; index++)); do
    label="${labels[$index]}"; plist="${plists[$index]}"
    if job_is_loaded "$label"; then launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || return 1; wait_for_job_state "$label" 0 || return 1; fi
    if [[ "${was_loaded[$index]}" -eq 1 ]]; then [[ -f "$plist" ]] || return 1; launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1 || return 1; wait_for_job_state "$label" 1 || return 1; fi
  done
}
rollback() {
  local original_status=$? index rollback_failed=0
  trap - EXIT
  if [[ "$committed" -eq 0 ]]; then
    if [[ "$codex_hook_updated" -eq 1 ]]; then rm -f "$hooks_file"; fi
    if [[ "$grok_hook_updated" -eq 1 ]]; then rm -f "$grok_hooks_file"; fi
    for ((index=${#moved_targets[@]}-1; index>=0; index--)); do mkdir -p "$(dirname "${moved_targets[$index]}")"; mv "${moved_paths[$index]}" "${moved_targets[$index]}"; done
    if [[ "$skip_launchctl" -eq 0 && "$launch_state_mutated" -eq 1 ]]; then restore_jobs || rollback_failed=1; fi
  fi
  rm -rf "$trash"
  if [[ "$rollback_failed" -ne 0 ]]; then printf 'Uninstall failed and launchd rollback was incomplete.\n' >&2; exit 71; fi
  exit "$original_status"
}
trap rollback EXIT

if [[ "$skip_launchctl" -eq 0 ]]; then
  for ((index=0; index<2; index++)); do
    label="${labels[$index]}"
    if job_is_loaded "$label"; then
      was_loaded[index]=1
      launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || { printf 'Could not stop managed LaunchAgent; uninstall was not applied.\n' >&2; exit 72; }
      wait_for_job_state "$label" 0 || { printf 'Managed LaunchAgent remained loaded; uninstall was not applied.\n' >&2; exit 72; }
      launch_state_mutated=1
    fi
  done
fi

move_managed() { local target="$1" name="$2"; if [[ -e "$target" ]]; then local moved="$trash/$name"; mkdir -p "$(dirname "$moved")"; mv "$target" "$moved"; moved_targets+=("$target"); moved_paths+=("$moved"); fi; }
[[ "$app_is_managed" -eq 0 ]] || move_managed "$app" app
move_managed "$component" component
move_managed "$aggregator_plist" agents/aggregator
move_managed "$player_plist" agents/player
if [[ "${STATELET_UNINSTALL_FAIL_AT:-${CODEX_PET_UNINSTALL_FAIL_AT:-}}" == "after-targets" ]]; then printf 'Injected uninstall failure after managed target removal.\n' >&2; exit 70; fi
if [[ -f "$hooks_file" ]]; then
  [[ "$(attest_hook_config .codex/hooks.json)" == "$codex_hook_snapshot" ]] || { printf 'Statelet hook configuration changed during uninstall.\n' >&2; exit 1; }
  staged_hooks="$trash/hooks.updated"
  "$python_bin" "$script_dir/merge_hooks.py" --destination "$hooks_file" --output "$staged_hooks" --python "$python_bin" --hook-script "$widget_hook" --remove-widget-hook
  move_managed "$hooks_file" hooks.original
  mkdir -p "$(dirname "$hooks_file")"
  mv "$staged_hooks" "$hooks_file"
  codex_hook_updated=1
fi
if [[ -f "$grok_hooks_file" ]]; then
  [[ "$(attest_hook_config .grok/hooks/statelet.json)" == "$grok_hook_snapshot" ]] || { printf 'Statelet hook configuration changed during uninstall.\n' >&2; exit 1; }
  staged_grok_hooks="$trash/grok-hooks.updated"
  "$python_bin" "$script_dir/merge_hooks.py" --destination "$grok_hooks_file" --output "$staged_grok_hooks" --python "$python_bin" --hook-script "$widget_hook" --provider grok --remove-widget-hook
  move_managed "$grok_hooks_file" grok-hooks.original
  if "$python_bin" - "$staged_grok_hooks" <<'PY'
import json, sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
hooks = data.get("hooks", {})
other = {key: value for key, value in data.items() if key != "hooks"}
raise SystemExit(0 if not other and isinstance(hooks, dict) and all(not groups for groups in hooks.values()) else 1)
PY
  then
    rm -f "$staged_grok_hooks"
  else
    mkdir -p "$(dirname "$grok_hooks_file")"
    mv "$staged_grok_hooks" "$grok_hooks_file"
  fi
  grok_hook_updated=1
fi

committed=1
rm -rf "$trash"
trap - EXIT
printf 'Removed canonical Statelet components. User data and unrelated legacy artifacts were preserved.\n'
