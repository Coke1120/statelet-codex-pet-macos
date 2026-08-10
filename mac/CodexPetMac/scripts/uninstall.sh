#!/bin/bash
set -euo pipefail

managed_marker="mac-widget-v1"
aggregator_label="com.coke1120.codex-pet.state-aggregator"
player_label="com.coke1120.codex-pet.mac-player"
script_dir="$(cd "$(dirname "$0")" && pwd -P)"
home_dir="$HOME"
skip_launchctl=0
aggregator_was_loaded=0
player_was_loaded=0

usage() {
  cat <<'EOF'
Usage: uninstall.sh [--home DIR] [--skip-launchctl]

Removes only the marked Mac-widget app, component directory, and LaunchAgents.
User media, state, logs, sessions, and the board daemon are preserved.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --home)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      home_dir="$2"
      shift 2
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

app="$home_dir/Applications/Statelet.app"
legacy_app="$home_dir/Applications/CodexPetMac.app"
support="$home_dir/Library/Application Support/CodexPet"
component="$support/mac-widget"
launch_agents="$home_dir/Library/LaunchAgents"
aggregator_plist="$launch_agents/$aggregator_label.plist"
player_plist="$launch_agents/$player_label.plist"
hooks_file="$home_dir/.codex/hooks.json"
widget_hook="$component/python/codex_pet_hook.py"
app_is_managed=0
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

# Classify both app paths and validate all fail-closed destinations before any
# mkdir, staging, launchd change, or other destination-side mutation.
if [[ -e "$app" ]] && is_managed_app "$app"; then
  app_is_managed=1
fi
if [[ -e "$legacy_app" ]] && is_managed_app "$legacy_app"; then
  legacy_app_is_managed=1
fi
if [[ -e "$component" ]] && ! is_managed_component "$component"; then
  printf 'Refusing to remove unmanaged component: %s\n' "$component" >&2
  exit 1
fi
for plist in "$aggregator_plist" "$player_plist"; do
  if [[ -e "$plist" ]] && ! is_managed_plist "$plist"; then
    printf 'Refusing to remove unmanaged LaunchAgent: %s\n' "$plist" >&2
    exit 1
  fi
done
if [[ "$skip_launchctl" -eq 0 && "$home_dir" != "$HOME" ]]; then
  printf -- '--home requires --skip-launchctl.\n' >&2
  exit 2
fi

mkdir -p "$support"
trash="$(mktemp -d "$support/.mac-widget-uninstall.XXXXXX")"
moved_targets=()
moved_paths=()
hook_updated=0
committed=0
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
    if [[ "$hook_updated" -eq 1 ]]; then
      rm -f "$hooks_file"
    fi
    for ((index=${#moved_targets[@]}-1; index>=0; index--)); do
      mkdir -p "$(dirname "${moved_targets[$index]}")"
      mv "${moved_paths[$index]}" "${moved_targets[$index]}"
    done
    if [[ "$skip_launchctl" -eq 0 ]]; then
      restore_job_state "$aggregator_label" "$aggregator_plist" "$aggregator_was_loaded" "$targets_mutated" "$aggregator_bootout_requested" || rollback_failed=1
      restore_job_state "$player_label" "$player_plist" "$player_was_loaded" "$targets_mutated" "$player_bootout_requested" || rollback_failed=1
    fi
  fi
  rm -rf "$trash"
  if [[ "$rollback_failed" -ne 0 ]]; then
    printf 'Uninstall failed and launchd rollback was incomplete.\n' >&2
    exit 71
  fi
  exit "$original_status"
}
trap rollback EXIT

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
    printf 'Could not stop the aggregator LaunchAgent; uninstall was not applied.\n' >&2
    exit 72
  fi
  if [[ "$aggregator_was_loaded" -eq 1 ]] && ! wait_for_job_state "$aggregator_label" 0; then
    printf 'The aggregator LaunchAgent remained loaded; uninstall was not applied.\n' >&2
    exit 72
  fi
  if [[ "$player_was_loaded" -eq 1 ]] &&
     [[ "$player_bootout_requested" -eq 0 ]]; then
    player_bootout_requested=1
  fi
  if [[ "$player_was_loaded" -eq 1 ]] &&
     ! launchctl bootout "gui/$(id -u)/$player_label" >/dev/null 2>&1; then
    printf 'Could not stop the player LaunchAgent; uninstall was not applied.\n' >&2
    exit 72
  fi
  if [[ "$player_was_loaded" -eq 1 ]] && ! wait_for_job_state "$player_label" 0; then
    printf 'The player LaunchAgent remained loaded; uninstall was not applied.\n' >&2
    exit 72
  fi
fi

move_managed() {
  local target="$1"
  local name="$2"
  if [[ -e "$target" ]]; then
    local moved="$trash/$name"
    mv "$target" "$moved"
    moved_targets+=("$target")
    moved_paths+=("$moved")
  fi
}
targets_mutated=1
if [[ "$app_is_managed" -eq 1 ]]; then
  move_managed "$app" app
fi
if [[ "$legacy_app_is_managed" -eq 1 ]]; then
  move_managed "$legacy_app" legacy-app
fi
move_managed "$component" component
move_managed "$aggregator_plist" aggregator.plist
move_managed "$player_plist" player.plist
if [[ "${CODEX_PET_UNINSTALL_FAIL_AT:-}" == "after-targets" ]]; then
  printf 'Injected uninstall failure after managed target removal.\n' >&2
  exit 70
fi
if [[ -f "$hooks_file" ]]; then
  python_bin="$(command -v python3 || true)"
  [[ -n "$python_bin" ]] || { printf 'Python 3 is required to migrate Codex hooks.\n' >&2; exit 1; }
  staged_hooks="$trash/hooks.updated"
  "$python_bin" "$script_dir/merge_hooks.py" \
    --destination "$hooks_file" \
    --output "$staged_hooks" \
    --python "$python_bin" \
    --hook-script "$widget_hook" \
    --remove-widget-hook
  move_managed "$hooks_file" hooks.original
  mkdir -p "$(dirname "$hooks_file")"
  mv "$staged_hooks" "$hooks_file"
  hook_updated=1
fi

committed=1
rm -rf "$trash"
trap - EXIT
printf 'Removed the managed Statelet app. User media, state, logs, sessions, and board service were preserved.\n'
