# Statelet for macOS

Statelet is a personal-local Codex lifecycle companion for macOS 13 or newer.
It is an AppKit accessory application: the transparent panel can be moved by dragging
its body and resized from any border or corner without taking keyboard focus,
AVFoundation owns exactly one decoder, and the menu-bar item keeps click-through
recoverable. The current app version is 1.6.0. The visible bundle filename is
`Statelet.app`; the stable bundle identifier, `CFBundleName`, executable,
LaunchAgent labels, preferences, and Application Support paths remain unchanged.

The application is independent of the ESP32 board. Its state aggregator uses
only the Python standard library and does not import `pyserial`, open a USB
device, or replace the existing `com.coke1120.codex-pet` board LaunchAgent.

For the complete personal-local workflow—from prerequisites through first run,
Settings, MP4 conversion, daily use, troubleshooting, upgrade, and uninstall—
follow the [macOS deployment and use guide](../../docs/MACOS_COMPANION.md). This
README is the developer reference for the app bundle, media contract, services,
and packaging behavior.

## Build a local app bundle

Requirements are Xcode Command Line Tools with Swift 5.9 or newer and macOS 13
or newer.

```bash
bash mac/CodexPetMac/scripts/build_app.sh
```

This runs a release SwiftPM build, assembles
`mac/CodexPetMac/dist/Statelet.app`, validates `Info.plist`, and applies an
ad-hoc signature. The app is an `LSUIElement` accessory and therefore appears
in the menu bar rather than the Dock.

The release builder remaps Swift source prefixes, exports matching crash symbols
to `mac/CodexPetMac/dist/Statelet.app.dSYM`, strips debug metadata from the
delivered executable, and rejects any app or dSYM that still embeds a workspace,
home, or temporary private path. Keep the dSYM with the matching build for local
crash symbolication; it is deliberately outside the application bundle.

The repository's macOS CI job runs the full Swift XCTest suite with Xcode, the
dependency-free core self-test, the release app build, and strict signature
verification. A Command Line Tools-only Mac can still build the app and run
`swift run -c release codex-pet-core-self-test`, but Apple does not include the
XCTest module in that smaller toolchain.

An ad-hoc signature is appropriate for personal local execution. It is not a
Developer ID signature and is not notarized. Distribution to other people
requires an authorized Apple Developer identity, hardened-runtime review,
notarization, stapling, and testing under the intended Gatekeeper policy.
The `.app` is the runnable product; a `.dmg` is only an optional distribution
container and is not produced by the current build script.

## Convert AI-generated MP4 input

Open the Statelet menu-bar icon and choose **Settings…** (`Command-,`) for the supported
local workflow. The **Animations** pane manages Idle, Running, Waiting, and
Review as separate clip libraries:

- The state-named drop zone accepts one or more local `.mp4` files dragged from
  Finder and sends them directly through the same verified sequential batch
  importer. It preserves dropped order, removes exact duplicate paths, and
  rejects the entire drop before conversion if any item is missing, unreadable,
  a directory, remote, or not an MP4.
- **Add Clip… → Import MP4s…** accepts multiple files. It runs background
  removal, HEVC-with-alpha encoding, Apple round-trip verification, and
  all-frame composite quality gates sequentially, appending each successful
  clip before moving to the next source. The app shows a determinate overall
  batch percentage built from structured, path-safe probe, per-frame matte,
  encode, per-frame Apple round-trip verification, and Swift validation/install
  stages.
- **Verified MOVs…** accepts multiple converter-produced HEVC-with-alpha
  QuickTime movies. Each movie must remain beside its matching `.report.json`.
  The app copies and revalidates each pair sequentially in the private media
  directory before appending it.
- **Fixed** uses the clip selected with **Actions… → Set as Fixed** for automatic
  state-entry and refresh selection; that action also switches the state to
  Fixed mode. Explicit Next Clip or body-click advance can move temporarily
  through other readable entries without changing `fixed_path`. If the selected
  clip is missing, one readable alternative is enough to enable that explicit
  advance.
  **Random** chooses on real state entry and avoids an immediate repeat when at
  least two readable clips are available. **Sequential** advances through the
  listed readable clips in order on each real state entry. There is no weighted
  mode.
- `advance_on` defaults to `state_entry`. For Random or Sequential libraries
  with at least two entries, **Continue with another clip when this clip ends**
  selects `clip_end`: the player hard-cuts to the next eligible clip while the
  lifecycle state stays active. In Fixed mode or a one-entry library,
  `clip_end` is ineffective and the entry's normal `loop` behavior applies.
- The native clip table aligns filename, readiness, fixed/poster status, and
  row actions for quick comparison. **Preview** plays that exact clip once
  without changing the live Codex state,
  the fixed selection, or the Random/Sequential cursor. **Stop** (or **Stop Play
  Once** in the pet/menu-bar menu) returns to the live state animation. A real
  lifecycle change preempts the preview immediately; a same-state heartbeat
  does not.
- Each clip has a visible **Remove…** button. Its **Actions…** menu sets the fixed
  clip, chooses or removes its Reduce Motion poster, moves it up or down in
  display/Sequential order, reveals that movie in Finder, or relinks a missing
  movie.
  **Relink…** is enabled only when the current movie is missing or unreadable;
  the replacement must be a verified MOV beside its sibling report. **Remove
  from State** changes only the mapping and keeps all files. For an eligible
  managed movie, **Remove & Move Files to Trash** also moves the MOV and its
  sibling `.report.json`; posters are kept and Trash remains recoverable. The
  pane footer reveals the entire media directory.

## Pet interaction and quick controls

Two controls remain visible beside the pet and expose equivalent actions in the
menu-bar/right-click menu:

- **Next Clip** advances the current temporary-state playlist when a temporary
  state is active; otherwise it advances the live Codex state's playlist. The
  action is enabled in every mode when at least two clips are readable. Random
  avoids an immediate repeat; Sequential and Fixed follow declared entry order,
  wrap, and skip unreadable entries. Missing files that leave fewer than two
  readable clips and one-entry libraries disable it. The live and temporary
  selection cursors exist only in memory; using the action does not persist a
  choice or modify `media-map.json`. In Fixed mode, `fixed_path` remains
  unchanged, and a later lifecycle state entry or forced refresh can restore
  it. With Reduce Motion on, advancing changes the selected poster or other
  static presentation instead of playing motion.
- **Temporary State** offers Idle, Running, Waiting, and Review. The pet-side
  submenu calls the exit action **Return to Live State**; the menu-bar submenu
  calls it **Follow Codex**. This override is process-memory only and disappears
  when the app exits. Same-state fresh producer heartbeats retain it. The first
  different fresh producer state—including one that matches the previewed
  value—relinquishes it automatically and resumes lifecycle presentation.
- Temporary presentation does not overwrite or disguise publisher health. The
  menu and Settings continue to report the real publisher status and live
  state while the pet marks the requested state as a preview. Selecting a new
  temporary state preempts **Play Once**; a different fresh producer state also
  preempts it.
- Click-through routes all pointer events past the pet, so neither pet-side
  button can be used while it is enabled. **Next Clip**, **Temporary State**,
  and **Follow Codex** remain available from the Statelet menu-bar icon.
- **Keep Statelet on Top** is enabled by default. Clear it from the pet's
  right-click menu, the menu-bar icon, or **Settings → General** to return the
  pet to normal window stacking so other app windows can cover it.

A simple primary click on the pet body invokes the same eligible **Next Clip**
action for the effective temporary or live state. Moving the panel, resizing it
from a border or corner, pressing a quick-control button, Control-clicking, and
right-clicking do not also advance the clip. Click-through prevents the pet from
receiving a body click, so the menu-bar **Next Clip** action is the fallback.

MP4 conversion shows a determinate overall batch percentage. The converter
publishes monotonic, path-safe structured events for source probing, per-frame
matting, HEVC-alpha encoding, and per-frame Apple round-trip verification; the
Swift app reserves the final portion of each clip for report validation and
library installation. Evidence collection can take several minutes, and the
percentage represents actual frames and completed stages rather than a time
estimate. The current stage remains visible, and partial failures identify the
source by sanitized basename with an actionable sanitized reason. **Cancel
Conversion** cancels the active MP4 conversion, skips all remaining sources,
removes incomplete artifacts, and keeps clips already appended. Verified MOV
copy/validation remains sequential and indeterminate and does not expose a
cancel button. The current animation stays active on failure, and
`media-map.json` is replaced atomically only after each new delivery report and
SHA-256 pass validation. Successful imports append; they do not discard
previously configured clips.

File-moving removal fails closed. **Remove & Move Files to Trash** appears only
when `media-map.json` is in the canonical managed media folder and the selected
movie is an unshared regular file inside
`~/Library/Application Support/CodexPet/media`. Missing or external movies,
shared targets, symbolic links, unsafe sibling reports, and noncanonical media
maps leave only **Remove from State** available. When file removal is eligible,
the app moves the MOV and an existing sibling `.report.json` to recoverable
Trash and deliberately keeps posters. Removing the current or fixed clip uses
the existing playlist selection contract to choose a remaining clip; removing
the last entry removes that state's mapping and falls back normally.

The app bundle includes the maintained converter source, but not a private
Python runtime or Homebrew binaries. Settings therefore reports conversion-tool
readiness honestly. It requires `ffmpeg`, `ffprobe`, Apple's `avconvert`, and a
Python 3 executable with NumPy and Pillow; set `CODEX_PET_ALPHA_PYTHON` before
launch when the desired Python is not found automatically.

Version 1.5.0 renames the former **Help** pane to **Prompts**. It includes
copy-ready, vendor-neutral prompts for the four lifecycle states. The
**Recommendation** pane defines the source target:
pixel-identical first and last frames; a completely uniform RGB `#00FF00` pure
green background; and no white background, scene, floor, material texture,
shadow, reflection, particles, text, logo, or watermark. It also requires a
locked camera, full-character safe margins, minimal motion blur, and stable
framing. Google Omni or Grok Imagine, Minimax H3, Seedance 2.5, and LSX2.3 are
listed only as user-provided generator examples, not endorsements or claims
about availability, features, or output quality.

Only convert character media you own or are authorized to use for the intended
derivative and distribution scope. Keep private input, alpha masters, reports,
and runtime movies outside a public checkout. Do not commit them to this
repository or put private paths in public reports.

The exact uniform `#00FF00` recommendation is the authoring target. Because a
generator may still return imperfect or varying green, the maintained converter
estimates the border background on every frame, preserves
source proportions with aspect-fill scaling and a centered crop to the
stable 320×480 authoring canvas, produces a continuous alpha matte, applies controlled
green despill, records source foreground edge contact, clears only the
pre-codec output border, writes a ProRes 4444 intermediate, and uses Apple's
`avconvert` for HEVC with alpha. It allows character motion and effects to
cross that crop instead of squeezing them. The Apple-roundtripped delivery
border remains bounded at alpha `16` to tolerate limited codec ringing.
Source-only unsupported green and magenta edge limits default to a `0.15` ratio
and `96` channel excess to accept stronger authored effects. Low-alpha RGB
repair reaches three pixels while hue support remains limited to two.
Source-matte failures identify the one-based source frame and preserve
`ratio/channel excess` wording.

Every Apple-roundtripped frame is composited over white, black, and
checkerboard backgrounds; codec-introduced green- and magenta-fringe limits are
enforced and recorded. Alpha loss, corruption, retained green screen, and an
outer-border alpha above `16` remain hard failures. The app does no runtime
chroma keying. Every published delivery is Apple-roundtrip verified; the
converter has no release verification bypass.
Its report binds the source both before decoding and immediately before
publication, plus the delivery and retained intermediate, by SHA-256. The
artifact/report set is rolled back together if publication fails.
The probe rejects explicit non-square sample aspect ratios. Source audio is
stripped and reported, while first/last post-matte differences are recorded as
an informational loop-seam notice; neither notice relaxes a delivery gate.

The converter needs `ffmpeg`, `ffprobe`, Apple's `avconvert`, NumPy, and Pillow.
Probe the planned pipeline first:

```bash
python3 tools/convert_codex_pet_macos_alpha.py \
  /private/path/source.mp4 \
  /private/path/idle.mov \
  --dry-run
```

Then convert and retain a quality report:

```bash
python3 tools/convert_codex_pet_macos_alpha.py \
  /private/path/source.mp4 \
  /private/path/idle.mov \
  --report /private/path/idle.report.json
```

Default conversion records source edge contact and clears the pre-codec output
border. The Apple-roundtripped delivery allows outer-border alpha through `16`
for codec ringing. Append `--strict-source-framing` when source framing itself
must be a hard gate.

The command continues to print the same final, path-sanitized JSON report by
default. Add `--progress-jsonl` only for machine-readable, flushed progress
events; that mode replaces the pretty-printed final JSON on standard output.

The default source-key thresholds are starting values, not proof for every
generated clip. Review the enforced all-frame white, black, and checkerboard
metrics plus the rendered output. Reject clips with cuts, camera movement, lost
foreground, opaque output edges, visible spill, or a poor loop seam.

## Install

After building, install for the current account:

```bash
bash mac/CodexPetMac/scripts/install.sh
```

The installer completes ownership preflight for both app paths, the component,
and both LaunchAgents before creating directories, changing modes, or staging.
It then stages and validates everything before replacement and rolls back prior
managed files on failure. LaunchAgent stop/load failures are fatal; rollback
restores the prior loaded set or reports that launchd rollback was incomplete.
It installs:

- `~/Applications/Statelet.app`
- board-independent Python modules under
  `~/Library/Application Support/CodexPet/mac-widget/python/`
- `com.coke1120.codex-pet.state-aggregator.plist`
- `com.coke1120.codex-pet.mac-player.plist`
- an example media map only when the user has no existing map

The installed application is a normal `.app` at
`~/Applications/Statelet.app`. Open it from **Finder → Home → Applications**
or run:

```bash
open "$HOME/Applications/Statelet.app"
```

The app has no Dock icon because `LSUIElement` is enabled. Its player
LaunchAgent starts it automatically at login by default. Use the Statelet
orbit icon in the menu bar to open Settings, reveal local files, or quit. You can
also right-click the pet to open the same context menu. When click-through is
enabled, the pet intentionally ignores mouse events; the Statelet menu-bar icon is
the recovery path.

After installation, **Settings → Diagnostics → Start Statelet when I log in**
controls future logins. Turning it off updates only the marked player startup
item and leaves the current app open. A later managed installer upgrade
preserves this choice.

On upgrade, a legacy `~/Applications/CodexPetMac.app` is migrated only when its
bundle identifier is `com.coke1120.CodexPetMac` and its `CodexPetManaged`
marker is `mac-widget-v1`. An unmanaged legacy bundle is left untouched. An
unmanaged item already occupying `~/Applications/Statelet.app` causes a
fail-closed refusal. Installation rollback restores both bundle paths and the
previous launchd loaded state.

To install the app and aggregator without launching the player at login:

```bash
bash mac/CodexPetMac/scripts/install.sh --no-player-launch-agent
```

No animation media is bundled, and the installer never copies `.mp4` or `.mov`
media. Settings imports authorized media into:

```text
~/Library/Application Support/CodexPet/media/
```

You can still manage `media-map.json` directly for developer workflows.
Relative paths resolve beside the map. `Examples/media-map.json` documents all
three playback modes across the four lifecycle states. Each state contains:

- `mode`: `fixed`, `random`, or `sequential`;
- `advance_on`: `state_entry` or `clip_end`; omitted values decode as
  `state_entry` for backward compatibility;
- `fixed_path`: a path that identifies an item in `entries` after normalization;
  and
- `entries`: one or more unique clip records in display/Sequential order.

Paths in one state must be unique after normalization. There are no weight
fields. `clip_end` continuous rotation is effective only for Random or
Sequential playlists with at least two entries. A legacy state value containing
one media entry directly, such as `"idle": {"path": "idle.mov"}`, still decodes
as a Fixed singleton playlist. The next app-written map uses the playlist
representation; no manual migration is required.

The optional `window.appearance.state_label_color` value controls the requested
state label. Omit it or set it to `null` to use automatic semantic colors by
state, or set it to a `#RRGGBB` string for one custom accent applied to the
state text, state symbol, and badge border. The
publisher health text keeps its independent health color. Maps created before
this key was added therefore retain the automatic behavior.

Each entry retains its own `loop`, `playback_rate`, and optional user-supplied
`poster_path`, such as `posters/idle.png`. A clip can use
`"playback_rate": 0.9583333333` for an accepted 23/24 retime without dropping
or re-encoding frames. When macOS Reduce Motion is enabled, the player shows
the selected clip's static poster instead of continuously decoding its movie,
and **Play Once** is disabled. Posters follow the same private/public asset
boundary and are never installed by this repository.

## Operation and recovery

Lifecycle priority is `waiting > review > running > idle`. The player reads:

```text
~/Library/Application Support/CodexPet/runtime/current_state.json
```

The complete serial-free state path is:

```text
Codex lifecycle hooks
  -> per-session JSON in Application Support
  -> board-independent priority aggregator
  -> runtime/current_state.json
  -> Swift file watcher
  -> requested lifecycle badge and animation
```

Each hook invocation writes one privacy-safe record named with the first 24
hexadecimal characters of the session ID's SHA-256 hash. The record contains
only version, mapped lifecycle state, event name, and `updated_at`. It excludes
prompts, tool output, transcript paths, and working directories.
`UserPromptSubmit` and subagent events map to Running; `PermissionRequest` maps
to Waiting; compact events map to Review; and tool events map to Review for
test, lint, typecheck, or review work and Running otherwise. `SessionStart`,
`SessionEnd`, and `Stop` map only that session to Idle.

Session records remain active for 900 seconds. Malformed records, non-finite
timestamps, records more than 60 seconds in the future, and expired records are
rejected or pruned. The aggregator chooses the greatest tuple of lifecycle
priority and `updated_at`: `waiting > review > running > idle`, with the newest
timestamp breaking a same-priority tie. An older Waiting session therefore
beats a newer Running session. When that Waiting session emits Stop, only its
record becomes Idle, so another active Review or Running session can win. With
no active record, the result is Idle with no `source_updated_at`.

The aggregator normally uses macOS `kqueue` directory events to publish a
changed result immediately. Session TTL, temporary-force, and once-per-minute
liveness-heartbeat deadlines wake it without file activity. If event watching
is unsupported or fails, bounded 250 ms polling preserves correctness. A
path-free log diagnostic reports `mode=event_driven` or `mode=poll_fallback`
with a sanitized reason category. `current_state.json` preserves the winning
session clock as `source_updated_at`, writes the publication clock as
`emitted_at`, and includes the active-session count. The player checks the
publication clock every 30 seconds. Swift `CurrentState` uses legacy
`updated_at` only when `emitted_at` is absent; `readState` does not re-aggregate
sessions or use `source_updated_at` as a liveness clock. If the publication is
more than 150 seconds old, more than 60 seconds in the future, missing, or
invalid, the pet falls back to idle and reports the publisher health. A fresh
heartbeat recovers automatically, and an unchanged heartbeat does not restart
the movie loop or advance a Random/Sequential playlist.
With `advance_on: state_entry`, initial presentation and an actual lifecycle
state change are the selection boundaries. With effective `clip_end` rotation,
natural clip completion independently advances the same-state playlist. A
forced media refresh retains the selected clip when it remains eligible.

Temporary-state preview arbitration runs after freshness validation. A stale,
missing, corrupt, or future-dated record still updates publisher health
truthfully but cannot masquerade as the fresh different producer state that
relinquishes an override. The override itself is never written to the publisher
record, media map, preferences, or any other restart-persistent store.

Continuous rotation still uses one AVFoundation decoder. Each natural clip end
hard-cuts to the next eligible movie; the app does not cross-fade or warm a
second decoder. An actual lifecycle state change preempts that sequence and
starts the newly requested state immediately.

The on-pet badge always names the requested lifecycle state. Its health label
is **Live** for a fresh publisher, **Offline** for missing, stale, invalid, or
future-dated data, and **Preview** when the app itself is launched with the
developer-only `--force-state` option. An Offline fallback is labeled honestly
instead of presenting Idle as live Codex activity.

The installer also merges lifecycle commands additively into
`~/.codex/hooks.json`. Unrelated hooks and top-level settings are preserved. A
valid existing Statelet-compatible hook under Application Support is reused
(including a board installation) instead of adding duplicate commands; only
exact obsolete `Documents/.../codex_pet_hook.py` command entries are migrated.
Restart Codex after first installation so the new hook configuration is loaded.

For a one-state visual check, temporarily stop the aggregator, publish one
forced record, and restart it when finished:

```bash
launchctl bootout gui/$(id -u) \
  "$HOME/Library/LaunchAgents/com.coke1120.codex-pet.state-aggregator.plist"

python3 "$HOME/Library/Application Support/CodexPet/mac-widget/python/codex_pet_state_aggregator.py" \
  --once --force-state running \
  --state-dir "$HOME/Library/Application Support/CodexPet/sessions" \
  --output "$HOME/Library/Application Support/CodexPet/runtime/current_state.json"

launchctl bootstrap gui/$(id -u) \
  "$HOME/Library/LaunchAgents/com.coke1120.codex-pet.state-aggregator.plist"
```

Click-through is disabled by default. Right-click the pet to open its context
menu. If click-through is enabled and the pet cannot be clicked, open the
Statelet menu-bar icon and clear **Click-through**.

Always-on-top is enabled by default. Clear **Keep Statelet on Top** in the same
menu, or in **Settings → General**, when other app windows should cover the pet.

Drag the body to move the panel. Drag any border or corner to resize it while
preserving the current aspect ratio, down to a minimum width of 160 points. The
app persists the final width and height in the `window` object of
`media-map.json`; General settings and the next launch use the saved size.
Window dimensions are display points only and do not change the 320×480 pixel
canvas used for newly converted animation media.

The **Appearance** pane controls:

- background visibility, color, and opacity;
- corner radius;
- border visibility, color, opacity, and width;
- current-state label visibility, corner position, size, and **Automatic color
  by state** or **Custom color**;
- playback-FPS visibility, color, and size; and
- **Reset Appearance**.

Defaults are background `#20242A` at 28% opacity, border `#FFFFFF` at 24%
opacity and 1 pt, a 22 pt corner radius, a regular state label in the top-left
corner, and a small FPS label in the top-right enabled in green `#00FF00`. The
automatic state-label mode uses semantic colors for the requested lifecycle
state. Version 1.6.0 includes a custom mode that accepts a `#RRGGBB` badge accent
for the state text, symbol, and border; the publisher health text retains its
independent health color. The
FPS label shows intended playback FPS and the source track's nominal FPS; it
does not claim to measure rendered FPS. Equal values collapse to one FPS value,
while a retimed clip labels the source rate as nominal. A Reduce Motion poster
displays `Still`. Appearance-only changes update the window without restarting
the active animation. The **General** pane controls size, always-on-top,
full-screen Space behavior, position reset, click-through, Reduce Motion
status, **Show App in Finder**, and Finder access to media, the map, and logs.
The menu-bar item remains the recovery path and can also reveal the media
directory or quit the player.

The **Diagnostics** pane builds a sanitized, copyable status report. It contains
only app version/build and managed-bundle status; current lifecycle, publisher
health/source/ages and active-session count; playback mode, selected movie
kind/extension and presentation state; conversion-tool readiness; player startup and
aggregator plist status; and media-map, state, media-directory and logs-directory
readability. **Copy Diagnostics** excludes absolute home paths, prompts, session
identifiers, clip basenames, log contents, tool output, account information, and
raw errors. Publisher source values are restricted to recognized status labels.
**Reveal Logs** opens the managed logs folder.

**Repair Startup…** validates the installed managed app and will create or
replace only the `mac-widget-v1`-marked player LaunchAgent. It refuses an
unmarked or malformed destination and never edits lifecycle hooks, the state
aggregator, or the board/Serial service. If the stale player job is already
loaded, the repaired on-disk settings take effect at the next login so the
current app is not terminated. **Clean Unused Media…** scans the
managed media directory, shows a confirmation list and size, rescans after
confirmation, and moves only still-unreferenced recognized regular media,
poster, or `.report.json` files inside that directory to Trash. It does not
select symbolic-link files, and any resolved path outside the managed media
directory is rejected.

Logs are kept outside the installed code:

```bash
tail -f "$HOME/Library/Application Support/CodexPet/logs/state-aggregator.err.log"
tail -f "$HOME/Library/Application Support/CodexPet/logs/mac-player.err.log"
```

Inspect services with:

```bash
launchctl print gui/$(id -u)/com.coke1120.codex-pet.state-aggregator
launchctl print gui/$(id -u)/com.coke1120.codex-pet.mac-player
```

Missing or invalid media fails softly in the transparent panel. If a valid
clip was already playing, the player retains it instead of warming a second
decoder.

## Uninstall

```bash
bash mac/CodexPetMac/scripts/uninstall.sh
```

Uninstall preflights ownership before staging or changing launchd. It removes a
managed `Statelet.app` and any managed legacy
`CodexPetMac.app`, and preserves an unmanaged bundle at either path. It removes
modules and LaunchAgents only when they carry the `mac-widget-v1` marker, and
preserves user media, media-map configuration, aggregate state, session records,
logs, and the board daemon/runtime. Unmarked component or LaunchAgent targets
cause a fail-closed refusal instead of deletion.
Uninstall removes only exact commands pointing at the deleted `mac-widget`
hook. If a valid shared board-runtime hook exists, it migrates lifecycle events
to that command; existing board hooks are otherwise left untouched. Unrelated
commands and settings remain unchanged.

## Isolated packaging tests

Both scripts support an explicit temporary home and skip live launchd changes:

```bash
bash mac/CodexPetMac/scripts/install.sh \
  --home /absolute/path/to/test-home \
  --app-bundle /absolute/path/to/Statelet.app \
  --skip-launchctl
```

Never point `--home` at `/`. The scripts reject it.

## Developer verification

Run the release checks from the repository root:

```bash
python3 -m unittest tests.test_macos_pet_packaging -v
python3 -m unittest tests.test_macos_pet_startup -v
swift run -c release --package-path mac/CodexPetMac codex-pet-core-self-test
swift test -c release --package-path mac/CodexPetMac
bash mac/CodexPetMac/scripts/build_app.sh
codesign --verify --deep --strict mac/CodexPetMac/dist/Statelet.app
python3 -m json.tool mac/CodexPetMac/Examples/media-map.json >/dev/null
git diff --check
```

The full `swift test` command requires Xcode/XCTest. Command Line Tools alone
can build the app and run the core self-test but may not provide the XCTest
module.

The signed app invokes the bundled converter with Python `-B` and sets
`PYTHONDONTWRITEBYTECODE=1`. Preserve both controls when changing or debugging
the launcher; they prevent Python bytecode caches from modifying signed app
resources.
