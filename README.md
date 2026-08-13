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

Statelet 1.7.0 (build 12) requires macOS 13 or newer. The first public release
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
- Keeps several named characters in one local library and switches each
  character's complete four-state animation map from the Animations pane.
- Supports Fixed, Random, and Sequential animation libraries for every state.
- Imports one or more MP4 files through an offline, verified HEVC-with-alpha
  conversion pipeline.
- Binds local conversions to schema-versioned reports with fresh invocation
  provenance, reproducibility metadata, immutable alpha gates, and an
  AVFoundation playback smoke check.
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
heartbeat, playlist, and filesystem contracts. Developers can use the
[local performance harness](docs/PERFORMANCE.md) for path-free CPU, memory,
soak, and warm state-switch evidence.

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
aggregator normally uses macOS `kqueue` directory events to publish state
changes immediately. It wakes on session TTL and temporary force-state
deadlines, and republishes unchanged state once per minute as a liveness
heartbeat. If event watching is unsupported or fails, it uses bounded 250 ms
polling instead. A path-free startup/runtime diagnostic reports
`mode=event_driven` or `mode=poll_fallback` with a sanitized reason category.
A same-state heartbeat refreshes health without restarting playback or
advancing a playlist.

## Animation libraries

The character selector at the top of **Settings → Animations** chooses which
character owns the four state libraries shown below it. **New Character…**
starts with an empty map that copies the current map's window/default-format
settings; the actions menu can rename, duplicate, export, or delete the active
character. A directly visible **Delete Profile…** button uses the same confirmed
deletion flow.
Duplicate copies the character's map, while Delete removes only its catalog
entry and keeps its map and media files. The last character cannot be deleted.

Existing installations remain the `Default` character backed by the configured
root map—normally `media-map.json`; no migration rewrites that file. Statelet
stores the catalog beside it as `character-library.json`. Additional characters
use separate hidden `.character-<id>.media-map.json` files in that same
directory, so legacy relative media paths keep the same base directory and older
Statelet builds can continue editing the default map without deleting other
characters.

**Import Bundle…** and **Export…** use a directory package ending in
`.statelet-character`. A package contains one schema-compatible Statelet
`MediaMap`, a bounded manifest, and declared assets. Import rejects unsafe paths,
size or hash mismatches, invalid report references, and movies that fail
AVFoundation playback checks. Reports are validated when present. Reportless
legacy clips are accepted only after the import confirmation explicitly grants
legacy trust; they still receive playback checks and are not described as
locally attested.

Each state has an independent library:

- **Fixed** uses the configured fixed clip for automatic state entry.
- **Random** chooses a readable clip and avoids an immediate repeat when
  possible.
- **Sequential** follows the declared clip order and wraps.

The default `state_entry` policy changes selection when the real lifecycle
enters a state. Random and Sequential libraries with at least two entries can
enable **Continue with another clip when this clip ends**. Statelet then
hard-cuts to the next eligible clip using one AVFoundation decoder. Normal
playlist changes do not cross-fade, warm a second decoder, or support weighted
selection.

The Animations pane also provides:

- Finder drag-and-drop MP4 import;
- verified MOV/report-pair import;
- determinate MP4 batch progress and cancellation;
- **Preview** and **Play Once** without changing the live lifecycle state;
- **Next Clip** and temporary Idle/Running/Waiting/Review presentation;
- clip reordering, relinking, fixed selection, and Reduce Motion posters; and
- state-only removal or eligible managed-file moves to macOS Trash.

The **Transitions** mode in the same pane can assign an optional directional
clip to every distinct source → destination lifecycle pair for the active
character. Import an MP4 for conversion or a verified transparent MOV, then
preview, replace, or remove it. A configured clip plays once before Statelet
commits the destination animation; clips are limited to 4 seconds and must
carry a current alpha-validation report. During a real lifecycle handoff,
Statelet retains the outgoing animation until the transition's first frame is
display-ready, composites the transparent transition above it, and starts the
destination animation below the foreground before the transition ends. The
default overlap is deterministic: at most 350 ms, or half of a shorter clip.
This is layered alpha compositing, not an opacity cross-fade. Reduce Motion
skips transition video and presents the destination's static fallback without
clearing the current presentation first. Existing maps without a `transitions`
object retain their current direct-to-destination behavior.

Read [Using Statelet](docs/USAGE.md) for the full interaction, animation,
appearance, resize, FPS, prompts, deletion, and recovery behavior.

## Dialogue and local voice

The **Voice** Settings pane has separate **Dialogue** and **Voice Setup** pages.
Dialogue assigns every message and generated voice to Idle, Running, Waiting,
or Review, and provides preview, retry, and regeneration controls. When a new
lifecycle state is presented, Statelet shows its selected message on the pet
and plays ready audio without interrupting speech already in progress; the
latest state-entry voice waits until the active clip finishes. Voice Setup
supports local GPT-SoVITS and Qwen3-TTS profiles. Both profiles may remain
configured, while one selected provider is active. Imported assets and Qwen
packages are copied into private Application Support storage; they are never
added to the repository or release bundle. Persisted fingerprints bind model,
reference, language, and runtime inputs and are revalidated at launch.

GPT-SoVITS accepts separate user-selected GPT `.ckpt` and SoVITS `.pth` weights,
reference inputs, and a numeric-loopback API v2 endpoint such as
`http://127.0.0.1:9880`. Qwen3-TTS accepts a trusted self-contained handover and
the Python executable from a trusted local MLX Audio environment. Qwen runs
locally with offline model-loading flags, accepts Japanese lines of 500
characters or fewer, and publishes only validated 24 kHz mono PCM16 WAV output.

Adding or editing a line persists it immediately and queues background
synthesis. Successful WAV output is validated and published atomically before
it becomes available to **Preview**. Playback never starts synchronous
inference, and failed or stale lines remain editable and retryable. Switching
providers revalidates the selected profile and refreshes incompatible output;
the old WAV is retained until its replacement succeeds.

Statelet does not train either provider or install their external runtimes.
Start GPT-SoVITS API v2 locally or provide an already working local Qwen Python
and MLX Audio environment. Import only model files you trust, and use voices
and reference recordings you are authorized to use. See
[Using Statelet](docs/USAGE.md#dialogue-and-local-voice) for setup and recovery.

## Privacy and security

Statelet is designed for local operation:

- The application and lifecycle publisher contain no telemetry or automatic
  crash upload. Optional voice generation permits HTTP only to loopback; it
  rejects remote hosts and redirects.
- Package managers may use the network when you install optional build or media
  conversion dependencies.
- Lifecycle files exclude prompts, tool output, transcript paths, working
  directories, account information, and credentials.
- The installer restricts managed support directories to the current account;
  imported media and state files receive restrictive local permissions.
- Logs remain under `~/Library/Application Support/Statelet/logs/`.
- **Copy Diagnostics** emits sanitized categories and counts rather than raw
  paths, clip names, session identifiers, logs, or tool output. Review copied
  diagnostics before sharing them.
- Media removal is fail-closed and uses recoverable macOS Trash when eligible.
- Character packages are verified locally from their manifest and lowercase
  SHA-256 declarations before installation; package reports never silently gain
  local-attestation status.

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
- No TTS runtime, model weights, reference recordings, dialogue, or generated
  speech is bundled. Voice generation requires either a user-managed local
  GPT-SoVITS API v2 service or a trusted local Qwen3-TTS handover with a working
  Python and MLX Audio environment.
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

Statelet uses one canonical identity for new builds and installations:

| Field | Value |
| --- | --- |
| App bundle | `Statelet.app` |
| Bundle identifier | `com.coke1120.Statelet` |
| `CFBundleName` | `Statelet` |
| Executable | `Statelet` |
| Application Support | `~/Library/Application Support/Statelet` |
| LaunchAgents | `com.coke1120.statelet.state-aggregator`, `com.coke1120.statelet.mac-player` |
| Managed marker | `statelet-v2` |
| App version | `1.7.0` |
| Build number | `12` |

## Uninstall

From the same checkout, run:

```bash
bash mac/CodexPetMac/scripts/uninstall.sh
```

The uninstaller removes only the marked Statelet app, component directory,
LaunchAgents, and exact widget hook commands. It preserves animation media,
`media-map.json`, `character-library.json`, hidden character maps and assets,
state, session records, and logs so reinstall and recovery do not discard user
data. Use Finder if you later choose to move that preserved Application Support
data to Trash.

## Development

```bash
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import unittest

suite = unittest.defaultTestLoader.discover(
    "tests", pattern="test_*.py"
)
result = unittest.TextTestRunner(verbosity=2).run(suite)
if result.skipped:
    raise SystemExit(f"Python tests skipped: {result.skipped}")
raise SystemExit(0 if result.wasSuccessful() else 1)
PY

swift run -c release --package-path mac/CodexPetMac codex-pet-core-self-test
swift test -c release --package-path mac/CodexPetMac
bash mac/CodexPetMac/scripts/build_app.sh
codesign --verify --deep --strict mac/CodexPetMac/dist/Statelet.app
python3 -m json.tool mac/CodexPetMac/Examples/media-map.json >/dev/null
```

Install the optional alpha authoring toolchain before running the complete
Python suite; release verification treats every skipped test as a failure. See
[Deployment](docs/DEPLOYMENT.md#release-verification) for the complete release
gate and [the lifecycle and media reference](docs/MACOS_COMPANION.md) for
implementation contracts.

## License and project status

Project-authored code and documentation are available under the
[MIT License](LICENSE). Animation media remains subject to its own rights and is
not included in this repository.

Statelet is an independent community project and is not affiliated with or
endorsed by OpenAI.
