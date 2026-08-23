# Statelet for macOS

Statelet is a personal-local Codex and Grok Build lifecycle companion for macOS 13 or newer.
It is an AppKit accessory application: the transparent panel can be moved by dragging
its body and resized from any border or corner without taking keyboard focus,
AVFoundation owns exactly one decoder, and the menu-bar item keeps click-through
recoverable. The current app version is 1.8.16 (build 30). New builds and
installations use
`Statelet.app`, bundle identifier `com.coke1120.Statelet`, `CFBundleName` and
executable `Statelet`, Application Support under
`~/Library/Application Support/Statelet`, `com.coke1120.statelet.*`
LaunchAgent labels, and the `statelet-v2` managed marker.

The application is independent of the ESP32 board. Its state aggregator uses
only the Python standard library and does not import `pyserial`, open a USB
device, or replace the existing board LaunchAgent.

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

## Local voice providers

Voice Setup supports GPT-SoVITS, Qwen3-TTS, and VoxCPM2 while keeping only one
provider active. VoxCPM2 imports the complete source handover directory, one
WAV reference with its exact transcript, and a trusted Python runtime. Statelet
descriptor-copies and fingerprints both the snapshot and reference in private
Application Support, then executes only the managed snapshot. Its bounded
probe loads the snapshot offline, confirms a sanitized `mps`, `cuda`, or `cpu`
device category and a 48 kHz model rate, and its helper runs under an OS
network-denied child-process policy. MPS uses the upstream float32 stability
path and may be slow on Apple Silicon. See [Using Statelet](../../docs/USAGE.md#voxcpm2-setup-and-recovery)
and the project-local [VoxCPM2 voice reference](../../.agents/skills/operate-statelet-local-voice/references/voxcpm2.md).

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

- The character selector owns the complete four-state map shown in the pane.
  **New Character…** creates and activates an empty map with a copy of the
  current map's window/default-format settings. The adjacent actions menu can rename,
  duplicate, export, or delete the active character. Duplicate copies the map;
  Delete removes only the catalog record and keeps its map and media files. The
  last character cannot be deleted.
- **Import Bundle…** installs a verified `.statelet-character` directory
  package and activates it. **Export…** writes the active character as that
  package type without changing its live map.
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
  selects `clip_end`: the player switches to the next eligible clip while the
  lifecycle state stays active. In Fixed mode or a one-entry library,
  `clip_end` is ineffective and the entry's normal `loop` behavior applies.
  The active character can optionally configure one same-state transition for
  each lifecycle state. It is used only for automatic effective `clip_end`
  rotation, reuses the transparent layered handoff, and falls back to the next
  ready clip on validation, readiness, playback, or timeout failure. Reduce
  Motion and all manual or refresh paths bypass it.
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

### Directional transition playlists

The **Transitions** category exposes all 12 ordered lifecycle routes and a
Character/Global scope selector. **Character** edits routes owned by the active
character. **Global** edits the separate shared `global-transitions.json`
library. A character route overrides the matching Global route; when the local
route is absent, runtime selection falls back to Global. A route such as
Idle → Running is independent from Running → Idle and owns its own ordered
variants, selection mode, default path, and in-memory cursor.

- **Add… → Import MP4s…** converts one or more sources and appends each accepted
  delivery. **Add… → Add Verified MOVs…** installs one or more validated
  MOV/report pairs. Existing variants remain in place.
- **Replace…**, **Preview**, **Remove…**, and **Up / Down** act on one variant.
  Preview does not change the runtime selection cursor.
- **Fixed** uses the variant marked **Default**. **Random** avoids an immediate
  repeat when another readable variant exists. **Sequential** follows the
  displayed order and wraps.
- Only an accepted real lifecycle A → B change consumes a selection. Initial
  presentation, same-state heartbeat, refresh, state-playlist rotation, Next
  Clip, Play Once, Temporary State, and transition preview do not.
- Reduce Motion skips transition playback and leaves the route cursor
  unchanged.

For a distinct-state route, the chosen variant keeps the outgoing state visible
until its first frame is ready, then pre-rolls the destination in a hidden lower
player before the atomic promotion. Same-state clip-end handoffs prewarm the
foreground and replacement while the outgoing clip still moves, then align the
visible effect to the outgoing player's media clock. Its actual duration is
split into outgoing fade, transition-only, and replacement fade phases. At the
1.5-second cap each phase is 0.5 seconds. The outgoing layer is transparent
before the replacement becomes visible, so only one state animation is visible
at a time.
If a variant is unreadable or fails runtime attestation/readiness, Statelet
tries each other eligible variant once for that request before committing the
newest destination directly. A superseding lifecycle change cancels obsolete
selection and presentation work so stale callbacks cannot advance the cursor or
reveal an older destination.

Each character retains its complete local transition libraries. Secure
`.statelet-character` export/import preserves local variant order, selection
mode, default path, movies, posters, reports, hashes, and validation records
while rewriting paths to the package layout. Bundles exclude Global routes and
assets, so importing a character never changes the installation's shared
library. A legacy single transition entry decodes as a Fixed singleton
playlist. Removal revalidates all character maps and the Global library before
moving a managed file that might still be referenced elsewhere.

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
  when the app exits. **Return to Live State** immediately presents the newest
  accepted publisher snapshot. Same-state fresh producer heartbeats retain the
  override. The first different fresh producer state—including one that matches
  the previewed value—relinquishes it automatically and resumes lifecycle
  presentation.
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
the active character's map is replaced atomically only after each new delivery
report and SHA-256 pass validation. Successful imports append; they do not
discard previously configured clips.

File-moving removal fails closed. **Remove & Move Files to Trash** appears only
when `media-map.json` is in the canonical managed media folder and the selected
movie is an unshared regular file inside
`~/Library/Application Support/Statelet/media`. Missing or external movies,
shared targets, symbolic links, unsafe sibling reports, and noncanonical media
maps leave only **Remove from State** available. When file removal is eligible,
the app moves the MOV and an existing sibling `.report.json` to recoverable
Trash and deliberately keeps posters. Removing the current or fixed clip uses
the existing playlist selection contract to choose a remaining clip; removing
the last entry removes that state's mapping and falls back normally.

### Character catalog and packages

The character catalog is deliberately separate from `MediaMap`. With the
normal managed root, the installed layout is:

```text
media-map.json                         # Default/legacy character map
character-library.json                 # authoritative catalog and active id
.character-<id>.media-map.json         # one ordinary map per added character
.character-<id>.assets/                # assets installed from a package
```

For `--media-map /path/custom.json`, absence of the sidecar bootstraps the
`Default` character against `custom.json`; the sidecar and hidden maps remain in
that same directory. This preserves the base directory for all existing
relative media paths. The root map stays wire-compatible with older builds, and
selecting another character loads its hidden map directly—there is no
compatibility mirror or dual-write into the root map.

Export creates a directory package ending in `.statelet-character`. It contains
`manifest.json`, one ordinary Statelet media map whose media references are
rewritten to bundle-relative paths, and declared movies/posters/reports. Import
opens package content without following symbolic links, enforces manifest and
asset-count/size bounds, rejects unsafe or colliding paths, verifies declared
sizes and lowercase SHA-256 hashes, validates report references, and runs
AVFoundation playback checks before committing the map, asset tree, and catalog
selection. Partial installation is rolled back.

Reports are validated when available, but they are optional in the package for
legacy portability. A reportless movie requires the explicit import trust
confirmation and still must pass playback validation. That choice does not
create an attestation or claim that all-frame alpha/composite gates ran.
Deleting a character removes only its catalog entry; its hidden map and files
remain for recovery.

The app bundle includes the maintained converter source, but not a private
Python runtime or Homebrew binaries. Settings therefore reports conversion-tool
readiness honestly. It requires `ffmpeg`, `ffprobe`, Apple's `avconvert`, and a
Python 3 executable with NumPy and Pillow; set `STATELET_ALPHA_PYTHON` before
launch when the desired Python is not found automatically.

Version 1.5.0 renamed the former **Help** pane to **Prompts**. The current
**Prompt Generator** destination includes copy-ready, vendor-neutral prompts
for the four lifecycle states. **Source Requirements** defines the source target:
pixel-identical first and last frames; a completely uniform RGB `#00FF00` pure
green background; and no white background, scene, floor, material texture,
shadow, reflection, particles, text, logo, or watermark. It also requires a
locked camera, full-character safe margins, minimal motion blur, and stable
framing. Google Omni or Grok Imagine, Minimax H3, Seedance 2.5, and LSX2.3 are
listed only as user-provided generator examples, not endorsements or claims
about availability, features, or output quality.

The current **Help & Updates** destination is separate from **Prompt Generator**. It collects first-run,
lifecycle, animation, voice/privacy, recovery, and diagnostics guidance and
shows the installed version plus the privacy-safe update status. Automatic
checks do not block the local app; verified installation waits for a safe
restart boundary and never replaces an unmanaged app. Installation also stays
fail-closed until a release artifact carries the pinned Statelet repository
signature. The signed manifest binds the immutable GitHub repository, `main`
tag commit, version/build, package identity, size, and SHA-256 before download.
A configured Developer ID team remains an additional Apple/Gatekeeper check,
while owner-authorized personal updates may remain ad-hoc signed. Version 1.8.5
is the first build containing the pinned repository key, so an existing v1.8.4
or earlier app requires one manual bootstrap install before later signed tags
can update themselves.

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
cross that crop instead of squeezing them. When earlier frames establish a
stable green background, a heavily occluded frame may reuse that reference
only if its remaining border green is sufficient and colour-matched.
Transition imports may contain transparent keyed frames when the complete clip
still contains foreground; ordinary state clips continue to require foreground
in every frame. The Apple-roundtripped delivery
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
  `~/Library/Application Support/Statelet/Statelet/python/`
- `com.coke1120.statelet.state-aggregator.plist`
- `com.coke1120.statelet.mac-player.plist`
- additive lifecycle hooks in `~/.codex/hooks.json` and
  `~/.grok/hooks/statelet.json`
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

After installation, **Settings → General → Start Statelet when I log in**
controls future logins. Turning it off updates only the marked player startup
item and leaves the current app open. A later managed installer upgrade
preserves this choice.

### Upgrade compatibility from the legacy identity

On upgrade, the installer recognizes the old `~/Applications/CodexPetMac.app`
only when its bundle identifier is `com.coke1120.CodexPetMac` and its
`CodexPetManaged` marker is `mac-widget-v1`. It also recognizes the corresponding
managed `~/Library/Application Support/CodexPet` data and
`com.coke1120.codex-pet.*` LaunchAgents. The installer migrates owned data into
the canonical Statelet locations, removes owned legacy startup files, and
leaves unmanaged legacy artifacts untouched. An unmanaged item already
occupying `~/Applications/Statelet.app` causes a fail-closed refusal.
Installation rollback restores both identities and the previous launchd loaded
state.

To install the app and aggregator without launching the player at login:

```bash
bash mac/CodexPetMac/scripts/install.sh --no-player-launch-agent
```

No animation media is bundled, and the installer never copies `.mp4` or `.mov`
media. Settings imports authorized media into:

```text
~/Library/Application Support/Statelet/media/
```

The Settings window presents its eight destinations in a persistent native
sidebar. Settings → Appearance owns the dialogue-bubble contrast controls and
the activity-popup background/opacity controls; Settings → General and Help & Updates
show the same managed-media location with an **Open in Finder** action. The
General pane also provides an **Agent Source** selector for Combined (default),
Codex, or Grok aggregation without deleting hidden-provider records. The
activity popup is draggable when click-through is disabled and remembers its
position. Rows with a fresh owner-only target expose **Open in Codex** through
OpenAI's documented `codex://threads/<thread-id>` link; legacy or unverified
targets and all Grok rows remain informational, and opening never marks a
completed row as read.
Rows can also show a bounded, sanitized user-facing task title resolved in
memory through the experimental local Codex App Server. Missing titles keep the
generic lifecycle label and do not affect **Open in Codex**.

The installer preserves `media-map.json`, `global-transitions.json`,
`character-library.json`, hidden per-character maps/assets, and user media on
upgrade. You can still manage the root `media-map.json` directly for
legacy/default developer workflows. Relative paths resolve beside each
character's map. `Examples/media-map.json` documents all three playback modes
across the four lifecycle states. Each state contains:

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
~/Library/Application Support/Statelet/runtime/current_state.json
```

The activity rail reads the bounded, owner-only companion sidecar:

```text
~/Library/Application Support/Statelet/sessions/activity-v1.json
```

The optional activation bridge is stored separately so the activity projection
continues to contain no raw session identifiers:

```text
~/Library/Application Support/Statelet/sessions/activity-targets-v1.json
```

The complete serial-free state path is:

```text
Codex lifecycle hooks + Grok Build global hooks
  -> per-session JSON in Application Support
  -> board-independent priority aggregator
  -> runtime/current_state.json
  -> sessions/activity-v1.json + private activity-targets-v1.json
  -> Swift file watchers
  -> requested lifecycle badge, activity rail, and animation
```

Each hook invocation writes one privacy-safe record named with the first 24
hexadecimal characters of a provider-scoped session hash. Existing Codex hashes
remain backward compatible, while Grok uses a distinct namespace. The versioned
record contains only bounded provider, mapped lifecycle state, event name, safe event category,
authoritative event time, bounded start/completion timestamps, local receipt
time, terminal status, bounded rejection counts, and bounded 24-hex hashes of
turn/tool correlation IDs with closed event phases. It excludes
prompts, tool output, transcript paths, and working directories.
Correlation metadata stays inside the owner-only session record and is never
forwarded into `current_state.json` or diagnostics.
The activity sidecar exposes only bounded active/completed summaries keyed by
the same opaque filename hash, with safe event categories and start/event/
completion timestamps. Completed items remain unread until the user explicitly
acknowledges them in the rail; no prompt, transcript, repository, media, voice,
or credential data is included.
The separate owner-only activation sidecar contains only the opaque hash and a
bounded technical thread identifier needed for the supported desktop deep link.
It is optional, freshness-matched to the public sidecar, and never changes
lifecycle aggregation.
For eligible rows, the signed app issues `thread/read` with
`includeTurns: false` to the local Codex App Server. It accepts only the
bounded, sanitized `thread.name` field, discards previews, turns, and items, and
keeps accepted titles in memory only. Nothing is added to `activity-v1.json`,
`activity-targets-v1.json`, preferences, or diagnostics.
Before sending a private thread identifier, Statelet validates the selected
Codex executable and the exact launched process against OpenAI's Developer ID
Team ID. Lookup is restricted to rows actually rendered in the expanded popup.

The App Server integration is experimental and fail-soft. An unavailable Codex
binary, App Server error, missing title, or rejected title leaves the existing
generic label in place. Title resolution neither changes aggregation nor gates
**Open in Codex**, which continues to use only the independently validated
activation target.
`UserPromptSubmit` and subagent events map to Running; `PermissionRequest` maps
to Waiting; compact events map to Review; and tool events map to Review for
test, lint, typecheck, or review work and Running otherwise. `SessionStart`,
`SessionEnd`, and `Stop` map only that session to Idle. `Stop` closes a turn and
does not create unread completion; `SessionEnd` alone terminalizes the session
and appears in Completed.

Grok's camelCase fields and snake_case `hookEventName` values are normalized
before this mapping.
`permission_prompt` and `ask_user_question` produce Waiting,
`exit_plan_mode` produces Review, and supported Stop events plus `idle_prompt`
settle a turn. The adapter accepts `StopCancelled` when emitted, while the
current stable hook baseline relies on `idle_prompt` after cancellation. Active
`backgroundTasks` keep Running. A blocked Stop may be
revived by newer correlated work and later settled again; stale callbacks and
child envelopes carrying `subagentType` cannot replace the host projection.
`sessions/agent-source-v1.json` selects `combined`, `codex`, or `grok` without
deleting records from the hidden provider.

Nonterminal session records remain active for 900 seconds, except a
`PostToolUse` record, which has a 30-second quiescent grace period when Desktop
fails to provide a terminal callback. A later hook event refreshes the normal
900-second lease. Malformed records, non-finite timestamps, records more than
60 seconds in the future, and expired records are rejected or pruned. A
delayed or conflicting callback cannot replace a newer event for its session.
The aggregator chooses the greatest
tuple of lifecycle priority and event time:
`waiting > review > running > idle`, with the newest
timestamp breaking a same-priority tie. An older Waiting session therefore
beats a newer Running session. When that Waiting session emits Stop, it becomes
Idle without creating a completed item, so another active Review or Running
session can win. With no active record, the result is Idle with no
`source_updated_at`.

The aggregator normally uses macOS `kqueue` directory events to publish a
changed result immediately. Session TTL, temporary-force, and once-per-minute
liveness-heartbeat deadlines wake it without file activity. If event watching
is unsupported or fails, bounded 250 ms polling preserves correctness. A
path-free log diagnostic reports `mode=event_driven` or `mode=poll_fallback`
with a sanitized reason category. `current_state.json` preserves the winning
session clock as `source_updated_at`, writes the publication clock as
`emitted_at`, and includes the active-session count, aggregate state, latest
accepted hook event/time, bounded rejection counts, monotonically increasing
`publication_revision`, and a recovery marker on the first publication after
aggregator start. The aggregator seeds the revision from a valid existing
snapshot before publishing again.

The player checks the publication clock every 30 seconds. Swift `CurrentState`
uses legacy `updated_at` only when `emitted_at` is absent; `readState` does not
re-aggregate sessions or use `source_updated_at` as a liveness clock. The app
rejects older or conflicting revisions after accepting a newer snapshot. It
retries transient missing or malformed reads caused by atomic replacement and
uses bounded polling when the watched directory is replaced, renamed, deleted,
or revoked. If publication remains more than 150 seconds old, more than 60
seconds in the future, missing, or invalid, the pet falls back to idle and
reports publisher health. A fresh publication recovers automatically, and an
unchanged heartbeat can repair metadata without restarting the movie loop or
advancing a Random/Sequential playlist.
With `advance_on: state_entry`, initial presentation and an actual lifecycle
state change are the selection boundaries. With effective `clip_end` rotation,
natural clip completion independently advances the same-state playlist. A
forced media refresh retains the selected clip when it remains eligible.

Temporary-state preview arbitration runs after freshness and publication-order
validation. **Return to Live State** immediately restores the newest accepted
live snapshot. A stale,
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
`~/.codex/hooks.json` and publishes global Grok registrations at
`~/.grok/hooks/statelet.json`. Unrelated hooks and top-level settings are preserved. A
valid existing Statelet-compatible hook under Application Support is reused
(including a board installation) instead of adding duplicate commands; only
exact obsolete `Documents/.../codex_pet_hook.py` command entries are migrated.
Restart Codex and any active Grok Build session after first installation so the
new hook configuration is loaded.

For a one-state visual check, temporarily stop the aggregator, publish one
forced record, and restart it when finished:

```bash
launchctl bootout gui/$(id -u) \
  "$HOME/Library/LaunchAgents/com.coke1120.statelet.state-aggregator.plist"

python3 "$HOME/Library/Application Support/Statelet/Statelet/python/statelet_state_aggregator.py" \
  --once --force-state running \
  --state-dir "$HOME/Library/Application Support/Statelet/sessions" \
  --output "$HOME/Library/Application Support/Statelet/runtime/current_state.json"

launchctl bootstrap gui/$(id -u) \
  "$HOME/Library/LaunchAgents/com.coke1120.statelet.state-aggregator.plist"
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
status, **Show App in Finder**, and Finder access to media and the map.
The menu-bar item remains the recovery path and can also reveal the media
directory or quit the player.

The **Diagnostics & Repair** pane builds a sanitized, copyable status report.
It contains only app version/build and managed-bundle status; requested and
last accepted live lifecycle state; publisher health/source/ages, publication and accepted
revisions, recovery status, latest accepted hook event/time, active-session
count, and aggregate state; bounded rejection categories/counts; preview or
fallback override status; playback mode and selected movie kind/extension;
conversion-tool readiness; player startup and aggregator plist status; and
media-map, state, media-directory and logs-directory readability. **Copy
Diagnostics** excludes absolute home paths, prompts, session identifiers, clip
basenames, log contents, tool output, account information, credentials, and raw
errors. Publisher source, events, and rejection reasons are restricted to
recognized status labels. **Reveal Logs** opens the managed logs folder.

**Repair Startup…** validates the installed managed app and will create or
replace only the `statelet-v2`-marked player LaunchAgent. It refuses an
unmarked or malformed destination and never edits lifecycle hooks, the state
aggregator, or the board/Serial service. If the stale player job is already
loaded, the repaired on-disk settings take effect at the next login so the
current app is not terminated. **Clean Unused Media…** scans the
managed media directory, loads every character map, shows a confirmation list
and size, rescans after confirmation, and moves only still-unreferenced
recognized regular media, poster, or `.report.json` files inside that directory
to Trash. The catalog and profile maps are retained. A missing or corrupt
inactive map makes cleanup fail closed, because its references cannot be proved
unused. Cleanup does not select symbolic-link files, and any resolved path
outside the managed media directory is rejected.

Logs are kept outside the installed code:

```bash
tail -f "$HOME/Library/Application Support/Statelet/logs/state-aggregator.err.log"
tail -f "$HOME/Library/Application Support/Statelet/logs/mac-player.err.log"
```

Inspect services with:

```bash
launchctl print gui/$(id -u)/com.coke1120.statelet.state-aggregator
launchctl print gui/$(id -u)/com.coke1120.statelet.mac-player
```

Missing or invalid media fails softly in the transparent panel. If a valid
clip was already playing, the player retains it instead of warming a second
decoder.

## Uninstall

```bash
bash mac/CodexPetMac/scripts/uninstall.sh
```

Uninstall preflights ownership before staging or changing launchd. It removes
only the canonical `statelet-v2`-managed `Statelet.app`, component, LaunchAgents,
and exact Statelet hook commands in both provider configs. It preserves user media, the separate Global
transition library, voice, characters, state, sessions, logs, and all legacy
artifacts. Unmarked canonical targets
cause a fail-closed refusal instead of deletion. Unrelated commands and settings
remain unchanged.

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

The AVPlayer integration suite writes and decodes real movies and therefore
requires a logged-in, GUI-capable Mac. Opt in explicitly on such a machine:

```bash
STATELET_RUN_AVPLAYER_INTEGRATION=1 swift test -c release \
  --package-path mac/CodexPetMac \
  --filter PetPlayerPlaybackIntegrationTests
```

Hosted CI still compiles that suite, but excludes it from execution because the
hosted macOS decoder service can abort the test process before XCTest reports a
failure. The deterministic playback-policy, lifecycle reducer, and PetPlayer UI
tests continue to run normally.

The signed app invokes the bundled converter with Python `-B` and sets
`PYTHONDONTWRITEBYTECODE=1`. Preserve both controls when changing or debugging
the launcher; they prevent Python bytecode caches from modifying signed app
resources.
