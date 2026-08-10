#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
package_dir="$(cd "$script_dir/.." && pwd -P)"
repo_root="$(cd "$package_dir/../.." && pwd -P)"
output="$package_dir/dist/Statelet.app"
icon="$package_dir/Design/Statelet.icns"
menu_icon="$package_dir/Design/StateletMenuBarTemplate.pdf"
executable=""
skip_sign=0
release_build=0
symbols_output=""
build_scratch=""
swift_temp_root="${TMPDIR:-/tmp}"
swift_temp_root="${swift_temp_root%/}"

usage() {
  cat <<'EOF'
Usage: build_app.sh [--output APP] [--executable FILE] [--skip-sign]

Builds a release SwiftPM executable and assembles an ad-hoc signed .app bundle.
Release crash symbols are written beside the app as Statelet.app.dSYM.
--executable is intended for isolated packaging tests; normal builds omit it.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      output="$2"
      shift 2
      ;;
    --executable)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      executable="$2"
      shift 2
      ;;
    --skip-sign)
      skip_sign=1
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

[[ "$output" = /* ]] || output="$PWD/$output"
output="${output%/}"
[[ "$output" == *.app ]] || { printf 'Output must end in .app: %s\n' "$output" >&2; exit 2; }

if [[ -z "$executable" ]]; then
  release_build=1
  command -v swift >/dev/null || { printf 'Swift is required.\n' >&2; exit 1; }
  mkdir -p "$package_dir/.build"
  build_scratch="$(mktemp -d "$package_dir/.build/CodexPetMac-release.XXXXXX")"
  trap 'rm -rf "$build_scratch"' EXIT
  module_cache="$build_scratch/ModuleCache"
  swift build --package-path "$package_dir" -c release --product codex-pet-mac \
    -Xswiftc -file-prefix-map \
    -Xswiftc "$package_dir=/BUILD/CodexPetMac" \
    -Xswiftc -file-prefix-map \
    -Xswiftc "$build_scratch=/BUILD/CodexPetMacTemp" \
    -Xswiftc -file-prefix-map \
    -Xswiftc "$swift_temp_root=/BUILD/SwiftTemp" \
    -Xswiftc -module-cache-path \
    -Xswiftc "$module_cache" \
    -Xcc "-fmodules-cache-path=$module_cache" \
    -Xcc "-ffile-prefix-map=$build_scratch=/BUILD/CodexPetMacTemp" \
    -Xcc "-ffile-prefix-map=$swift_temp_root=/BUILD/SwiftTemp"
  bin_dir="$(swift build --package-path "$package_dir" -c release --show-bin-path)"
  executable="$bin_dir/codex-pet-mac"
fi

[[ -f "$executable" && -x "$executable" ]] || {
  printf 'Executable is missing or not executable: %s\n' "$executable" >&2
  exit 1
}
[[ -f "$icon" && -r "$icon" ]] || {
  printf 'Statelet app icon is missing or unreadable: %s\n' "$icon" >&2
  exit 1
}
[[ -f "$menu_icon" && -r "$menu_icon" ]] || {
  printf 'Statelet menu bar icon is missing or unreadable: %s\n' "$menu_icon" >&2
  exit 1
}

parent="$(dirname "$output")"
mkdir -p "$parent"
stage="$(mktemp -d "$parent/.Statelet.app.stage.XXXXXX")"
symbols_stage_root=""
symbols_stage=""
backup=""
symbols_backup=""
output_installed=0
symbols_installed=0
cleanup() {
  rm -rf "$build_scratch"
  rm -rf "$stage"
  rm -rf "$symbols_stage_root"
  if [[ "$output_installed" -eq 1 ]]; then
    rm -rf "$output"
  fi
  if [[ "$symbols_installed" -eq 1 ]]; then
    rm -rf "$symbols_output"
  fi
  if [[ -n "$backup" && -e "$backup" ]]; then
    mv "$backup" "$output"
  fi
  if [[ -n "$symbols_backup" && -e "$symbols_backup" ]]; then
    mv "$symbols_backup" "$symbols_output"
  fi
}
trap cleanup EXIT

mkdir -p "$stage/Contents/MacOS" "$stage/Contents/Resources/AlphaTools"
install -m 0755 "$executable" "$stage/Contents/MacOS/CodexPetMac"
install -m 0644 "$package_dir/Resources/Info.plist" "$stage/Contents/Info.plist"
install -m 0644 "$icon" "$stage/Contents/Resources/Statelet.icns"
install -m 0644 "$menu_icon" "$stage/Contents/Resources/StateletMenuBarTemplate.pdf"
install -m 0644 "$package_dir/Examples/media-map.json" "$stage/Contents/Resources/media-map.example.json"
install -m 0644 "$repo_root/tools/convert_codex_pet_macos_alpha.py" \
  "$stage/Contents/Resources/AlphaTools/convert_codex_pet_macos_alpha.py"
install -m 0644 "$repo_root/tools/codex_pet_alpha.py" \
  "$stage/Contents/Resources/AlphaTools/codex_pet_alpha.py"
install -m 0644 "$repo_root/mac/requirements-alpha.txt" \
  "$stage/Contents/Resources/AlphaTools/requirements-alpha.txt"

if [[ "$release_build" -eq 1 ]]; then
  command -v xcrun >/dev/null || { printf 'xcrun is required to preserve crash symbols.\n' >&2; exit 1; }
  symbols_output="${output}.dSYM"
  symbols_stage_root="$(mktemp -d "$parent/.Statelet.symbols.stage.XXXXXX")"
  symbols_stage="$symbols_stage_root/Statelet.app.dSYM"
  xcrun dsymutil --quiet "$executable" -o "$symbols_stage"
  # dsymutil's relocation sidecar repeats local object-file paths. It is not
  # needed for crash symbolication once DWARF has been linked into the dSYM.
  rm -rf "$symbols_stage/Contents/Resources/Relocations"
  strip -S "$stage/Contents/MacOS/CodexPetMac"
  binary_uuid="$(xcrun dwarfdump --uuid "$stage/Contents/MacOS/CodexPetMac" | awk 'NR == 1 { print $2 }')"
  symbols_uuid="$(xcrun dwarfdump --uuid "$symbols_stage" | awk 'NR == 1 { print $2 }')"
  [[ -n "$binary_uuid" && "$binary_uuid" == "$symbols_uuid" ]] || {
    printf 'Crash symbol UUID does not match the release executable.\n' >&2
    exit 1
  }
fi

plutil -lint "$stage/Contents/Info.plist" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$stage/Contents/Info.plist")" == "CodexPetMac" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$stage/Contents/Info.plist")" == "com.coke1120.CodexPetMac" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$stage/Contents/Info.plist")" == "Statelet" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$stage/Contents/Info.plist")" == "Statelet.icns" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$stage/Contents/Info.plist")" == "true" ]]

scan_private_paths() {
  local target="$1"
  local label="$2"
  local needle
  for needle in "$package_dir/" "$HOME/" "/Users/" "/home/" "/private/tmp/" "/private/var/folders/" "/var/folders/"; do
    if LC_ALL=C grep -R -a -F -q "$needle" "$target"; then
      printf 'Privacy scan failed: %s contains private path prefix %s\n' "$label" "$needle" >&2
      return 1
    fi
  done
}
scan_private_paths "$stage" "application bundle"
if [[ -n "$symbols_stage" ]]; then
  scan_private_paths "$symbols_stage" "crash symbols"
fi

if [[ "$skip_sign" -eq 0 ]]; then
  command -v codesign >/dev/null || { printf 'codesign is required.\n' >&2; exit 1; }
  codesign --force --sign - --timestamp=none "$stage"
  codesign --verify --deep --strict --verbose=2 "$stage"
fi

if [[ -e "$output" ]]; then
  backup="$(mktemp -d "$parent/.Statelet.app.backup.XXXXXX")/Statelet.app"
  mv "$output" "$backup"
fi
if [[ -n "$symbols_output" && -e "$symbols_output" ]]; then
  symbols_backup="$(mktemp -d "$parent/.Statelet.symbols.backup.XXXXXX")/Statelet.app.dSYM"
  mv "$symbols_output" "$symbols_backup"
fi
mv "$stage" "$output"
stage=""
output_installed=1
if [[ -n "$symbols_stage" ]]; then
  mv "$symbols_stage" "$symbols_output"
  symbols_stage=""
  symbols_installed=1
fi
if [[ -n "$backup" ]]; then
  rm -rf "${backup%/Statelet.app}"
fi
if [[ -n "$symbols_backup" ]]; then
  rm -rf "${symbols_backup%/Statelet.app.dSYM}"
fi
backup=""
symbols_backup=""
output_installed=0
symbols_installed=0
rm -rf "$symbols_stage_root"
symbols_stage_root=""
rm -rf "$build_scratch"
build_scratch=""
trap - EXIT

printf 'Built %s\n' "$output"
if [[ -n "$symbols_output" ]]; then
  printf 'Crash symbols: %s\n' "$symbols_output"
fi
if [[ "$skip_sign" -eq 0 ]]; then
  codesign -dv --verbose=2 "$output" 2>&1 | grep -E '^(Identifier|Signature)='
fi
