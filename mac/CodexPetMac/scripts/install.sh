#!/bin/bash
set -euo pipefail

managed_marker="mac-widget-v1"
aggregator_label="com.coke1120.codex-pet.state-aggregator"
player_label="com.coke1120.codex-pet.mac-player"
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
    --app-bundle)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      app_bundle="$2"
      shift 2
      ;;
    --home)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      home_dir="$2"
      shift 2
      ;;
    --no-player-launch-agent)
      install_player=0
      shift
      ;;
    --skip-launchctl)
      skip_launchctl=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ "$home_dir" = /* && "$home_dir" != / ]] || {
  printf 'Destination home must be an absolute non-root directory.\n' >&2
  exit 2
}
[[ -d "$home_dir" ]] || { printf 'Destination home does not exist: %s\n' "$home_dir" >&2; exit 2; }
[[ -d "$app_bundle" ]] || { printf 'App bundle does not exist: %s\n' "$app_bundle" >&2; exit 1; }

info="$app_bundle/Contents/Info.plist"
app_executable="$app_bundle/Contents/MacOS/CodexPetMac"
[[ -f "$info" && -x "$app_executable" ]] || { printf 'Invalid Statelet.app bundle.\n' >&2; exit 1; }
plutil -lint "$info" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")" == "com.coke1120.CodexPetMac" ]] || {
  printf 'Unexpected application bundle identifier.\n' >&2
  exit 1
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CodexPetManaged' "$info")" == "$managed_marker" ]] || {
  printf 'Application bundle is not a managed Statelet build.\n' >&2
  exit 1
}

python_bin=""
for candidate in /usr/bin/python3 "$(command -v python3 || true)"; do
  [[ -n "$candidate" && -x "$candidate" ]] || continue
  resolved_candidate="$($candidate -c 'import os,sys; print(os.path.realpath(sys.executable))' 2>/dev/null || true)"
  [[ -n "$resolved_candidate" ]] || continue
  case "$resolved_candidate" in
    "$repo_root"/*|/tmp/*|/private/tmp/*)
      continue
      ;;
  esac
  if "$resolved_candidate" -c 'import sys; raise SystemExit(sys.version_info < (3, 9))'; then
    python_bin="$resolved_candidate"
    break
  fi
done
[[ -n "$python_bin" ]] || {
  printf 'A stable Python 3.9+ interpreter outside the repository and temporary directories is required.\n' >&2
  exit 1
}
"$python_bin" -c 'import sys; raise SystemExit(sys.version_info < (3, 9))' || {
  printf 'Python 3.9 or newer is required.\n' >&2
  exit 1
}

applications_dir="$home_dir/Applications"
app_dest="$applications_dir/Statelet.app"
legacy_app="$applications_dir/CodexPetMac.app"
support_dir="$home_dir/Library/Application Support/CodexPet"
component_dir="$support_dir/mac-widget"
python_dir="$component_dir/python"
media_dir="$support_dir/media"
runtime_dir="$support_dir/runtime"
logs_dir="$support_dir/logs"
media_map="$media_dir/media-map.json"
launch_agents_dir="$home_dir/Library/LaunchAgents"
aggregator_plist="$launch_agents_dir/$aggregator_label.plist"
player_plist="$launch_agents_dir/$player_label.plist"
hooks_file="$home_dir/.codex/hooks.json"
player_run_at_load=1
legacy_app_is_managed=0

is_managed_app() {
  [[ -f "$1/Contents/Info.plist" ]] &&
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true)" == "com.coke1120.CodexPetMac" ]] &&
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CodexPetManaged' "$1/Contents/Info.plist" 2>/dev/null || true)" == "$managed_marker" ]]
}
is_managed_component() {
  [[ -f "$1/MANAGED_BY_CODEX_PET" ]] && [[ "$(cat "$1/MANAGED_BY_CODEX_PET")" == "$managed_marker" ]]
}
is_managed_plist() {
  [[ -f "$1" ]] && [[ "$(/usr/libexec/PlistBuddy -c 'Print :CodexPetMacManaged' "$1" 2>/dev/null || true)" == "$managed_marker" ]]
}

# Resolve ownership for every managed destination before mkdir, chmod, staging,
# launchd changes, or any other destination-side mutation.
if [[ -e "$app_dest" ]] && ! is_managed_app "$app_dest"; then
  printf 'Refusing to replace an unmanaged app: %s\n' "$app_dest" >&2
  exit 1
fi
if [[ -e "$legacy_app" ]] && is_managed_app "$legacy_app"; then
  legacy_app_is_managed=1
fi
if [[ -e "$component_dir" ]] && ! is_managed_component "$component_dir"; then
  printf 'Refusing to replace an unmanaged component directory: %s\n' "$component_dir" >&2
  exit 1
fi
for plist in "$aggregator_plist" "$player_plist"; do
  if [[ -e "$plist" ]] && ! is_managed_plist "$plist"; then
    printf 'Refusing to replace an unmanaged LaunchAgent: %s\n' "$plist" >&2
    exit 1
  fi
done
if [[ "$skip_launchctl" -eq 0 && "$home_dir" != "$HOME" ]]; then
  printf -- '--home requires --skip-launchctl to avoid mutating another account.\n' >&2
  exit 2
fi

# Preserve the user's in-app "Start at Login" choice across managed updates.
# Ownership validation below still refuses an unmarked plist before mutation.
if [[ -f "$player_plist" ]] &&
   [[ "$(/usr/libexec/PlistBuddy -c 'Print :CodexPetMacManaged' "$player_plist" 2>/dev/null || true)" == "$managed_marker" ]] &&
   [[ "$(/usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "$player_plist" 2>/dev/null || true)" == "false" ]]; then
  player_run_at_load=0
fi

mkdir -p "$applications_dir" "$support_dir" "$media_dir" "$runtime_dir" "$logs_dir" "$launch_agents_dir"
chmod 700 "$support_dir" "$media_dir" "$runtime_dir" "$logs_dir"
stage_root="$(mktemp -d "$support_dir/.mac-widget-stage.XXXXXX")"
backup_root="$(mktemp -d "$support_dir/.mac-widget-backup.XXXXXX")"
installed_targets=()
backed_up_targets=()
backed_up_paths=()
created_media_map=0
committed=0
aggregator_was_loaded=0
player_was_loaded=0
targets_mutated=0
aggregator_bootout_requested=0
player_bootout_requested=0

job_is_loaded() {
  launchctl print "gui/$(id -u)/$1" >/dev/null 2>&1
}

wait_for_job_state() {
  local label="$1"
  local expected_loaded="$2"
  local attempts=0
  local consecutive=0
  local current_loaded
  while [[ "$attempts" -lt 40 ]]; do
    if job_is_loaded "$label"; then
      current_loaded=1
    else
      current_loaded=0
    fi
    if [[ "$current_loaded" -eq "$expected_loaded" ]]; then
      consecutive=$((consecutive + 1))
      [[ "$consecutive" -ge 3 ]] && return 0
    else
      consecutive=0
    fi
    attempts=$((attempts + 1))
    /bin/sleep 0.05
  done
  return 1
}

restore_job_state() {
  local label="$1"
  local plist="$2"
  local should_be_loaded="$3"
  local must_reload="$4"
  local transition_requested="$5"

  if [[ "$must_reload" -eq 1 ]]; then
    if ! launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1; then
      wait_for_job_state "$label" 0 || return 1
    fi
    wait_for_job_state "$label" 0 || return 1
  elif [[ "$should_be_loaded" -eq 1 && "$transition_requested" -eq 1 ]]; then
    if wait_for_job_state "$label" 0; then
      [[ -f "$plist" ]] || return 1
      launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1 || return 1
      wait_for_job_state "$label" 1 || return 1
      return 0
    fi
    wait_for_job_state "$label" 1 || return 1
    return 0
  elif [[ "$should_be_loaded" -eq 0 ]]; then
    if job_is_loaded "$label"; then
      launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || return 1
    fi
    wait_for_job_state "$label" 0 || return 1
  else
    wait_for_job_state "$label" 1 || return 1
    return 0
  fi
  if [[ "$should_be_loaded" -eq 1 ]]; then
    [[ -f "$plist" ]] || return 1
    launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1 || return 1
    wait_for_job_state "$label" 1 || return 1
  fi
}

rollback() {
  local original_status=$?
  local index
  local rollback_failed=0
  trap - EXIT
  if [[ "$committed" -eq 0 ]]; then
    for ((index=${#installed_targets[@]}-1; index>=0; index--)); do
      rm -rf "${installed_targets[$index]}"
    done
    for ((index=${#backed_up_targets[@]}-1; index>=0; index--)); do
      mkdir -p "$(dirname "${backed_up_targets[$index]}")"
      mv "${backed_up_paths[$index]}" "${backed_up_targets[$index]}"
    done
    if [[ "$created_media_map" -eq 1 ]]; then
      rm -f "$media_map"
    fi
    if [[ "$skip_launchctl" -eq 0 ]]; then
      restore_job_state "$aggregator_label" "$aggregator_plist" "$aggregator_was_loaded" "$targets_mutated" "$aggregator_bootout_requested" || rollback_failed=1
      restore_job_state "$player_label" "$player_plist" "$player_was_loaded" "$targets_mutated" "$player_bootout_requested" || rollback_failed=1
    fi
  fi
  rm -rf "$stage_root" "$backup_root"
  if [[ "$rollback_failed" -ne 0 ]]; then
    printf 'Installation failed and launchd rollback was incomplete.\n' >&2
    exit 71
  fi
  exit "$original_status"
}
trap rollback EXIT

stage_app="$stage_root/Statelet.app"
stage_component="$stage_root/mac-widget"
stage_aggregator_plist="$stage_root/$aggregator_label.plist"
stage_player_plist="$stage_root/$player_label.plist"
ditto "$app_bundle" "$stage_app"
mkdir -p "$stage_component/python"
install -m 0644 "$repo_root/mac/codex_pet_state.py" "$stage_component/python/codex_pet_state.py"
install -m 0755 "$repo_root/mac/codex_pet_state_aggregator.py" "$stage_component/python/codex_pet_state_aggregator.py"
install -m 0755 "$repo_root/mac/codex_pet_hook.py" "$stage_component/python/codex_pet_hook.py"
printf '%s\n' "$managed_marker" > "$stage_component/MANAGED_BY_CODEX_PET"
chmod 0644 "$stage_component/MANAGED_BY_CODEX_PET"

PYTHONDONTWRITEBYTECODE=1 "$python_bin" -m py_compile \
  "$stage_component/python/codex_pet_state.py" \
  "$stage_component/python/codex_pet_state_aggregator.py" \
  "$stage_component/python/codex_pet_hook.py"
rm -rf "$stage_component/python/__pycache__"

stage_hooks="$stage_root/hooks.json"
"$python_bin" "$script_dir/merge_hooks.py" \
  --destination "$hooks_file" \
  --output "$stage_hooks" \
  --python "$python_bin" \
  --hook-script "$python_dir/codex_pet_hook.py"

"$python_bin" - "$stage_aggregator_plist" "$stage_player_plist" \
  "$python_bin" "$python_dir" "$support_dir" "$app_dest" \
  "$aggregator_label" "$player_label" "$managed_marker" "$player_run_at_load" <<'PY'
import plistlib
import sys
from pathlib import Path

(
    aggregator_path,
    player_path,
    python_bin,
    python_dir,
    support_dir,
    app_dest,
    aggregator_label,
    player_label,
    marker,
    player_run_at_load,
) = sys.argv[1:]
support = Path(support_dir)

common = {
    "CodexPetMacManaged": marker,
    "ProcessType": "Background",
    "RunAtLoad": True,
    "ThrottleInterval": 10,
}
aggregator = {
    **common,
    "Label": aggregator_label,
    "KeepAlive": True,
    "ProgramArguments": [
        python_bin,
        str(Path(python_dir) / "codex_pet_state_aggregator.py"),
        "--state-dir",
        str(support / "sessions"),
        "--output",
        str(support / "runtime" / "current_state.json"),
    ],
    "WorkingDirectory": python_dir,
    "StandardOutPath": str(support / "logs" / "state-aggregator.out.log"),
    "StandardErrorPath": str(support / "logs" / "state-aggregator.err.log"),
}
player = {
    **common,
    "RunAtLoad": player_run_at_load == "1",
    "Label": player_label,
    "KeepAlive": False,
    "LimitLoadToSessionType": "Aqua",
    "ProcessType": "Interactive",
    "ProgramArguments": [
        str(Path(app_dest) / "Contents" / "MacOS" / "CodexPetMac"),
        "--media-map",
        str(support / "media" / "media-map.json"),
        "--state",
        str(support / "runtime" / "current_state.json"),
    ],
    "StandardOutPath": str(support / "logs" / "mac-player.out.log"),
    "StandardErrorPath": str(support / "logs" / "mac-player.err.log"),
}
for path, payload in ((aggregator_path, aggregator), (player_path, player)):
    with Path(path).open("wb") as handle:
        plistlib.dump(payload, handle, sort_keys=True)
PY
plutil -lint "$stage_aggregator_plist" "$stage_player_plist" >/dev/null

if [[ "$skip_launchctl" -eq 0 ]]; then
  if job_is_loaded "$aggregator_label"; then
    aggregator_was_loaded=1
  fi
  if job_is_loaded "$player_label"; then
    player_was_loaded=1
  fi
  if [[ "$aggregator_was_loaded" -eq 1 ]] &&
     [[ "$aggregator_bootout_requested" -eq 0 ]]; then
    aggregator_bootout_requested=1
  fi
  if [[ "$aggregator_was_loaded" -eq 1 ]] &&
     ! launchctl bootout "gui/$(id -u)/$aggregator_label" >/dev/null 2>&1; then
    printf 'Could not stop the existing aggregator LaunchAgent; installation was not applied.\n' >&2
    exit 72
  fi
  if [[ "$aggregator_was_loaded" -eq 1 ]] && ! wait_for_job_state "$aggregator_label" 0; then
    printf 'The aggregator LaunchAgent remained loaded; installation was not applied.\n' >&2
    exit 72
  fi
  if [[ "$player_was_loaded" -eq 1 ]] &&
     [[ "$player_bootout_requested" -eq 0 ]]; then
    player_bootout_requested=1
  fi
  if [[ "$player_was_loaded" -eq 1 ]] &&
     ! launchctl bootout "gui/$(id -u)/$player_label" >/dev/null 2>&1; then
    printf 'Could not stop the existing player LaunchAgent; installation was not applied.\n' >&2
    exit 72
  fi
  if [[ "$player_was_loaded" -eq 1 ]] && ! wait_for_job_state "$player_label" 0; then
    printf 'The player LaunchAgent remained loaded; installation was not applied.\n' >&2
    exit 72
  fi
fi

backup_target() {
  local target="$1"
  local name="$2"
  if [[ -e "$target" ]]; then
    local saved="$backup_root/$name"
    mv "$target" "$saved"
    backed_up_targets+=("$target")
    backed_up_paths+=("$saved")
  fi
}
install_target() {
  local staged="$1"
  local target="$2"
  mv "$staged" "$target"
  installed_targets+=("$target")
}

targets_mutated=1
backup_target "$app_dest" app
if [[ "$legacy_app_is_managed" -eq 1 ]]; then
  backup_target "$legacy_app" legacy-app
fi
backup_target "$component_dir" component
backup_target "$aggregator_plist" aggregator.plist
backup_target "$player_plist" player.plist
backup_target "$hooks_file" hooks.json
install_target "$stage_app" "$app_dest"

# Test-only fault injection validates rollback without touching a real home.
if [[ "${CODEX_PET_INSTALL_FAIL_AT:-}" == "after-app" ]]; then
  printf 'Injected installation failure after app replacement.\n' >&2
  exit 70
fi

install_target "$stage_component" "$component_dir"
install_target "$stage_aggregator_plist" "$aggregator_plist"
if [[ "$install_player" -eq 1 ]]; then
  install_target "$stage_player_plist" "$player_plist"
fi
mkdir -p "$(dirname "$hooks_file")"
install_target "$stage_hooks" "$hooks_file"

if [[ ! -e "$media_map" ]]; then
  media_stage="$media_dir/.media-map.json.stage.$$"
  install -m 0600 "$package_dir/Examples/media-map.json" "$media_stage"
  mv "$media_stage" "$media_map"
  created_media_map=1
fi

if [[ "$skip_launchctl" -eq 0 ]]; then
  launchctl bootstrap "gui/$(id -u)" "$aggregator_plist"
  wait_for_job_state "$aggregator_label" 1 || {
    printf 'The aggregator LaunchAgent did not load after bootstrap.\n' >&2
    exit 73
  }
  if [[ "$install_player" -eq 1 ]]; then
    launchctl bootstrap "gui/$(id -u)" "$player_plist"
    wait_for_job_state "$player_label" 1 || {
      printf 'The player LaunchAgent did not register after bootstrap.\n' >&2
      exit 73
    }
    if [[ "$player_run_at_load" -eq 0 ]]; then
      /usr/bin/open "$app_dest"
    fi
  fi
fi

committed=1
rm -rf "$backup_root" "$stage_root"
trap - EXIT

printf 'Installed Statelet, the Codex lifecycle companion.\n'
printf '  App: %s\n' "$app_dest"
printf '  Media map: %s\n' "$media_map"
printf '  Aggregator: %s\n' "$aggregator_plist"
if [[ "$install_player" -eq 1 ]]; then
  printf '  Player: %s\n' "$player_plist"
else
  printf '  Player LaunchAgent: not installed\n'
fi
