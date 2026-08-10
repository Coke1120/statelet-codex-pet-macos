# Statelet

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)](docs/DEPLOYMENT.md)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white)](mac/CodexPetMac/Package.swift)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/Coke1120/statelet-codex-pet-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/Coke1120/statelet-codex-pet-macos/actions/workflows/ci.yml)

Statelet is a native, local-first macOS companion for Codex. It turns Codex
lifecycle events—Idle, Running, Waiting, and Review—into an animated,
transparent desktop presence. It runs without a development board, keeps its
runtime data on the Mac, and uses AppKit and AVFoundation rather than a browser
runtime.

Statelet 1.6.0 (build 11) requires macOS 13 or newer. The first public release
is source-only: the build script creates an ad-hoc-signed app for personal local
use, not a Developer ID-signed or notarized public binary.

> **No character or animation media is bundled.** Import media that you own or
> are authorized to use. Until at least an Idle clip is configured, the panel
> can appear blank while the menu-bar controls remain available.

## Highlights

- Shows `idle`, `running`, `waiting`, and `review` as distinct animation states.
- Aggregates several simultaneous Codex sessions with
  `waiting > review > running > idle` priority.
- Provides a movable, border-and-corner-resizable transparent AppKit panel.
- Keeps recovery controls in the menu bar when the panel is click-through.
- Supports Fixed, Random, and Sequential animation libraries for every state.
- Imports one or more MP4 files through an offline, verified HEVC-with-alpha
  conversion pipeline.
- Shows structured conversion progress and preserves completed imports when a
  later file fails or the remaining batch is cancelled.
- Supports one-time preview, temporary state selection, Next Clip, Reduce Motion
  posters, appearance controls, diagnostics, and recoverable media cleanup.
- Runs the lifecycle publisher with the Python standard library; Python media
  packages are needed only for optional MP4 conversion.

## How it works

```text
Codex lifecycle hooks
  -> privacy-safe per-session JSON
  -> local multi-session state aggregator
     waiting > review > running > idle
  -> current_state.json
  -> Statelet AppKit panel and AVFoundation player
```

Each hook record contains only a schema version, mapped state, event name, and
timestamp. Its filename is derived from a truncated SHA-256 hash of the session
identifier. Statelet does not store prompts, tool output, transcript paths, or
working directories in those records.

See [the lifecycle and media reference](docs/MACOS_COMPANION.md) for freshness,
heartbeat, playlist, and filesystem contracts.

## Requirements

The app and lifecycle publisher require:

- macOS 13 or newer;
- Xcode Command Line Tools with Swift 5.9 or newer; and
- a stable Python 3.9 or newer interpreter outside the checkout and temporary
  directories.

Optional MP4 transparency conversion also requires:

- `ffmpeg` and `ffprobe`;
- Apple `/usr/bin/avconvert`; and
- Python 3.9 with the hash-locked NumPy and Pillow versions in
  `mac/requirements-alpha.txt`.

## Build and install

Run these commands from the repository root:

```bash
bash mac/CodexPetMac/scripts/build_app.sh
codesign --verify --deep --strict mac/CodexPetMac/dist/Statelet.app
bash mac/CodexPetMac/scripts/install.sh
open "$HOME/Applications/Statelet.app"
```

The installer places `Statelet.app` in `~/Applications`, installs the local
state publisher, adds two marked LaunchAgents, and merges lifecycle commands
into `~/.codex/hooks.json` without replacing unrelated hooks. Restart Codex once
after the first install so it loads the merged hook configuration.

Statelet is an `LSUIElement` accessory app, so it intentionally has no Dock
icon. Use the Statelet orbit icon in the menu bar to open Settings, disable
click-through, reveal files, repair managed startup, or quit.

For installation modes, upgrades, autostart behavior, installed files, and the
public-distribution boundary, read [Deployment](docs/DEPLOYMENT.md).

## First run

1. Open the Statelet menu-bar icon and choose **Settings…** (`Command-,`).
2. Open **Animations** and select **Idle**.
3. Drag one or more local `.mp4` files onto the Idle drop zone, or choose
   **Add Clip… → Import MP4s…**.
4. If conversion tools are missing, follow the in-app Setup Guide or
   [prepare the optional toolchain](docs/DEPLOYMENT.md#prepare-mp4-conversion-tools).
5. Restart Codex if it was already running during the first installation.

Statelet keeps the current animation visible while a batch converts. It appends
each successful clip atomically and reports later failures without discarding
earlier results.

## Lifecycle states

| State | Meaning |
| --- | --- |
| Idle | No active Codex turn |
| Running | Codex is working |
| Waiting | Codex needs input or permission |
| Review | Tests, lint, type checks, or review work are active |

Each session stays eligible for 900 seconds after its latest event. The
aggregator polls every 250 ms, publishes state changes on the next poll, and
republishes unchanged state once per minute as a liveness heartbeat. A
same-state heartbeat refreshes health without restarting playback or advancing
a playlist.

## Animation libraries

Each state has an independent library:

- **Fixed** uses the configured fixed clip for automatic state entry.
- **Random** chooses a readable clip and avoids an immediate repeat when
  possible.
- **Sequential** follows the declared clip order and wraps.

The default `state_entry` policy changes selection when the real lifecycle
enters a state. Random and Sequential libraries with at least two entries can
enable **Continue with another clip when this clip ends**. Statelet then
hard-cuts to the next eligible clip using one AVFoundation decoder. It does not
cross-fade, warm a second decoder, or support weighted selection.

The Animations pane also provides:

- Finder drag-and-drop MP4 import;
- verified MOV/report-pair import;
- determinate MP4 batch progress and cancellation;
- **Preview** and **Play Once** without changing the live lifecycle state;
- **Next Clip** and temporary Idle/Running/Waiting/Review presentation;
- clip reordering, relinking, fixed selection, and Reduce Motion posters; and
- state-only removal or eligible managed-file moves to macOS Trash.

Read [Using Statelet](docs/USAGE.md) for the full interaction, animation,
appearance, resize, FPS, prompts, deletion, and recovery behavior.

## Privacy and security

Statelet is designed for local operation:

- The application and lifecycle publisher contain no telemetry or automatic
  crash upload and make no runtime network requests.
- Package managers may use the network when you install optional build or media
  conversion dependencies.
- Lifecycle files exclude prompts, tool output, transcript paths, working
  directories, account information, and credentials.
- The installer restricts managed support directories to the current account;
  imported media and state files receive restrictive local permissions.
- Logs remain under `~/Library/Application Support/CodexPet/logs/`.
- **Copy Diagnostics** emits sanitized categories and counts rather than raw
  paths, clip names, session identifiers, logs, or tool output. Review copied
  diagnostics before sharing them.
- Media removal is fail-closed and uses recoverable macOS Trash when eligible.

Statelet is not sandboxed. Its local installer manages LaunchAgents and merges
commands into `~/.codex/hooks.json`, and the app reads user-selected media and
its Application Support directory. Review the scripts before installation if
those changes are outside your preferred trust boundary.

Report vulnerabilities according to [SECURITY.md](SECURITY.md). Do not include
credentials, private media, complete logs, usernames, or absolute home paths in
a public report.

## Limitations

- macOS 13 or newer is the only supported runtime.
- The first public release is source-only. The generated app is ad-hoc signed,
  is not notarized, and is not offered as a public binary or DMG.
- No animation media is bundled; users supply authorized media.
- MP4 conversion needs additional local tools and can take several minutes
  because every accepted delivery passes Apple round-trip and all-frame checks.
- Statelet exposes four lifecycle states and one active decoder.
- Clip changes are hard cuts; there is no cross-fade or weighted playlist mode.
- The FPS label reports intended playback FPS and the source track's nominal
  FPS. It does not measure rendered frame rate.
- Temporary State, Next Clip cursors, and Play Once are process-local controls;
  they do not rewrite the published Codex state.
- Full Swift XCTest execution requires full Xcode. Command Line Tools can build
  the app and run the dependency-free core self-test but may not include XCTest.

The visible bundle is `Statelet.app`. Upgrade compatibility intentionally keeps
these internal identifiers:

| Field | Value |
| --- | --- |
| Bundle identifier | `com.coke1120.CodexPetMac` |
| `CFBundleName` | `CodexPetMac` |
| Executable | `CodexPetMac` |
| App version | `1.6.0` |
| Build number | `11` |

## Uninstall

From the same checkout, run:

```bash
bash mac/CodexPetMac/scripts/uninstall.sh
```

The uninstaller removes only the marked Statelet app, component directory,
LaunchAgents, and exact widget hook commands. It preserves animation media,
`media-map.json`, state, session records, and logs so reinstall and recovery do
not discard user data. Use Finder if you later choose to move that preserved
Application Support data to Trash.

## Development

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  tests.test_codex_hook \
  tests.test_codex_pet_state \
  tests.test_macos_pet_packaging \
  tests.test_macos_pet_startup -v

swift run -c release --package-path mac/CodexPetMac codex-pet-core-self-test
swift test -c release --package-path mac/CodexPetMac
bash mac/CodexPetMac/scripts/build_app.sh
codesign --verify --deep --strict mac/CodexPetMac/dist/Statelet.app
python3 -m json.tool mac/CodexPetMac/Examples/media-map.json >/dev/null
```

Run `tests.test_macos_alpha_video` after installing the optional alpha authoring
toolchain. See [Deployment](docs/DEPLOYMENT.md#release-verification) for the
complete release gate and [the lifecycle and media reference](docs/MACOS_COMPANION.md)
for implementation contracts.

## License and project status

Project-authored code and documentation are available under the
[MIT License](LICENSE). Animation media remains subject to its own rights and is
not included in this repository.

Statelet is an independent community project and is not affiliated with or
endorsed by OpenAI.
