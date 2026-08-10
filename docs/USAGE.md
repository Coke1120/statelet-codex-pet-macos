# Use Statelet on macOS

Statelet presents Codex lifecycle activity as a transparent animated companion.
This guide covers first run, animation libraries, conversion, controls,
appearance, diagnostics, troubleshooting, and local-data behavior.

Install Statelet first by following [Deployment](DEPLOYMENT.md).

## First run

Statelet is a menu-bar accessory app and has no Dock icon. Open the Statelet
orbit icon and choose **Settings…** (`Command-,`). The same menu remains
available when click-through prevents the panel from receiving pointer input.

No animation media is bundled. Add at least one Idle clip:

1. Open **Settings → Animations**.
2. Select **Idle**.
3. Drag one or more local `.mp4` files from Finder onto the Idle drop zone, or
   choose **Add Clip… → Import MP4s…**.
4. Resolve any toolchain warning using the Setup Guide.
5. Wait for conversion and verification to finish.

Restart Codex once if Statelet was installed while Codex was already running.

## Lifecycle behavior

| State | Meaning |
| --- | --- |
| Idle | No active Codex turn |
| Running | A prompt, subagent, or ordinary tool task is active |
| Waiting | Codex needs input or permission |
| Review | Tests, lint, type checks, compaction, or review work are active |

Several Codex sessions can be active at once. Statelet selects the highest
priority state:

```text
waiting > review > running > idle
```

At equal priority, the newest session event wins. A Stop event changes only its
own session to Idle; another active session may still keep Statelet in Waiting,
Review, or Running.

Session records remain eligible for 900 seconds. The aggregator checks them
every 250 ms and republishes unchanged state once per minute. A heartbeat
refreshes publisher health but does not restart a movie or advance a playlist.

The badge reports:

- **Live** when the state publisher is valid and fresh;
- **Offline** when state data is missing, malformed, stale, or too far in the
  future, with safe Idle fallback; and
- **Preview** for developer-forced state presentation.

## Move, resize, and interact

- Drag the pet body to move the panel.
- Drag any edge or corner to resize while preserving the current aspect ratio.
- The minimum width is 160 points.
- Position is stored per display and clamped onto a visible screen after monitor
  changes.
- The final width and height are saved in `media-map.json`.
- Right-click the pet for the context menu.
- Enable **Click-through** to send pointer events to the app underneath.

When click-through is enabled, the pet cannot receive clicks or drags. Use the
menu-bar icon to turn it off, open Settings, select a temporary state, or advance
the clip.

A simple primary click on the pet performs the same eligible action as **Next
Clip**. Moving, resizing, pressing a quick-control button, Control-clicking, and
right-clicking do not also advance the library.

## Use quick controls

### Next Clip

**Next Clip** advances the effective state's readable library without changing
the stored playlist mode, order, or fixed path.

- With a temporary state active, it advances that state.
- Otherwise it advances the live Codex state.
- Random avoids an immediate repeat.
- Sequential and Fixed follow declared entry order and skip unreadable files.
- In Fixed mode, the explicit change is temporary; a later real state entry or
  refresh can restore `fixed_path`.
- With Reduce Motion enabled, it changes the selected poster or other static
  output instead of starting video.

### Temporary State

Choose Idle, Running, Waiting, or Review without changing Codex or
`current_state.json`. Choose **Return to Live State** beside the pet or
**Follow Codex** in the menu-bar menu to end the override.

Temporary State is not saved. A fresh publisher heartbeat for the same real
state leaves it active. The first fresh different real state returns the player
to lifecycle control. Publisher health continues to show the actual producer
condition during the preview.

### Play Once

Use a clip row's **Preview** action to play that exact clip once. It does not
change the live state, fixed selection, or Random/Sequential cursor. Completion
or **Stop Play Once** returns to the current lifecycle animation. A real state
change or a new Temporary State preempts it immediately.

Play Once is unavailable while Reduce Motion is enabled.

## Manage animation libraries

Every state has its own playlist and playback mode.

| Mode | Behavior |
| --- | --- |
| Fixed | Automatic selection uses the clip chosen with **Set as Fixed** |
| Random | Selects a readable clip on real state entry and avoids an immediate repeat when possible |
| Sequential | Selects readable clips in declared order and wraps |

There is no weighted mode.

The default advance policy is `state_entry`. It selects a clip when the real
lifecycle enters the state. For Random and Sequential libraries with at least
two entries, enable **Continue with another clip when this clip ends** to use
`clip_end`. Statelet hard-cuts to the next clip with one AVFoundation decoder.
It does not use a cross-fade or second warmed decoder.

The clip table shows order, filename, readiness, fixed state, poster state, and
preview state. Each row provides **Preview** or **Stop**, **Actions…**, and
**Remove…**.

The Actions menu can:

- choose or remove a Reduce Motion poster;
- reveal a readable movie in Finder;
- relink a missing movie using a verified MOV/report pair;
- set the fixed clip; and
- move a clip up or down in display and Sequential order.

## Import MP4 animations

Use only media you own or have permission to adapt and distribute. Keep private
source videos outside the repository.

The recommended source is:

- a constant-frame-rate MP4 with one stable video stream;
- square pixels with no rotation metadata;
- a full-body character with clean margin on every side;
- a locked camera and stable framing, exposure, scale, and focus;
- a completely uniform RGB `#00FF00` background;
- no floor, shadow, reflection, gradient, smoke, text, logo, watermark, camera
  movement, cut, entrance, or exit;
- an 8–10 second seamless loop with no audio; and
- pixel-identical first and last frames.

The margin is a quality recommendation, not a rejection rule. Statelet accepts
subjects and effects that touch or exceed the source canvas; anything outside
the stable 320×480 authoring canvas is cropped because those pixels do not exist
in the delivered frame. Resizing the on-screen pet changes AppKit display points,
not the pixel geometry used for future conversions.

Select **Add Clip… → Import MP4s…**, or drag local `.mp4` files from Finder onto
the selected state's drop zone. A drop preserves Finder order, removes exact
duplicate paths, and is rejected before conversion if any item is missing,
unreadable, a directory, remote, or not an MP4.

Explicit non-square sample-aspect-ratio media is rejected before decoding.
Audio tracks are removed because Statelet animations are silent; the completed
import reports that removal instead of ignoring it. A non-identical first/last
frame remains importable but produces a **loop endpoints differ** notice so a
visible seam can be reauthored without weakening alpha or composite checks.

Accepted files run sequentially through:

```text
source probe
  -> continuous matte and controlled despill
  -> ProRes 4444 intermediate
  -> Apple HEVC-with-alpha delivery
  -> Apple round-trip decode
  -> all-frame alpha and composite checks
  -> Swift report validation and atomic library install
```

The progress indicator uses structured probe, per-frame matte, encode,
round-trip, and Swift installation stages. It measures completed work rather
than estimating time remaining. Verification can take several minutes.

One failed source does not stop later files. The final status shows sanitized
filenames and actionable sanitized reasons. **Cancel Conversion** stops the
active MP4, skips the remaining batch, removes incomplete artifacts, and keeps
clips already appended.

## Import verified MOV files

Use **Add Clip… → Verified MOVs…** only for files created by the maintained
converter. Keep each movie beside its matching report:

```text
idle.mov
idle.report.json
```

Statelet copies each pair into a private staging directory, validates the copied
bytes and report, and appends it only after the movie is playable. An arbitrary
MOV, opaque H.264 MP4, renamed file, missing report, or mismatched report is
rejected. This batch is sequential, can report partial failures, and does not
show the MP4 conversion cancel button.

## Remove clips and clean media

**Remove from State** changes only `media-map.json`; it keeps the movie, report,
and poster files.

**Remove & Move Files to Trash** appears only when the movie is an unshared
regular file inside the canonical managed media folder and the active media map
is also canonical. It moves the MOV and sibling `.report.json` to recoverable
Trash and keeps posters.

External, missing, shared, symbolic-link, or noncanonical targets fail closed to
state-only removal. Removing the active or fixed entry selects from the
remaining library. Removing the last entry removes that state mapping and uses
the normal no-media fallback.

Use **Settings → Diagnostics → Clean Unused Media…** to find recognized files
inside the managed media directory that no playlist references. Statelet lists
names and approximate size, asks for confirmation, rescans, and moves only files
that remain eligible to Trash.

## Appearance, resizing, and FPS

Open **Settings → Appearance** to configure:

- background color, opacity, enablement, and corner radius;
- border color, opacity, width, and enablement;
- lifecycle label visibility, corner position, size, automatic state color, or
  a custom `#RRGGBB` accent; and
- FPS label visibility, color, and size.

The custom lifecycle color applies to the state text, state symbol, and badge
border. Publisher health keeps an independent health color.

The FPS label shows intended playback FPS and the source track's nominal FPS.
When they differ because of `playback_rate`, the source value is labeled as
nominal. These are media metadata and playback intent, not a measurement of
rendered frames. Reduce Motion posters display `Still`.

## Prompts and source recommendations

**Settings → Prompts** provides copy-ready, vendor-neutral authoring prompts for
Idle, Running, Waiting, and Review. Replace the character placeholder with a
description you own or are authorized to use.

Copy-ready English base prompt:

```text
Create an 8–10 second seamless looping video of [CHARACTER] performing
[STATE ACTION]. Make the first frame and last frame pixel-identical. Use a
locked camera, stable framing, stable lighting and colour, minimal motion blur,
constant 24 fps if controllable, and no audio.

The entire background must be perfectly uniform pure green RGB #00FF00. Do not
add a white background, scene, floor, material texture, shadow, reflection,
particles, text, logo, watermark, border, UI, gradient, vignette, glow, smoke,
camera movement, cut, entrance, or exit. Keep the character readable and
centered. Empty margin is recommended, but effects may touch the canvas.
```

Use one state-specific action:

| State | `[STATE ACTION]` |
| --- | --- |
| Idle | Relaxed in-place breathing with an occasional natural blink |
| Running | Focused in-place work with small purposeful hand movement |
| Waiting | Calm expectant pose with a subtle toe tap or weight shift |
| Review | Thoughtful in-place review gesture, such as hand to chin |

The adjacent **Recommendation** pane repeats the exact green-background,
fixed-camera, clean-frame, and seamless-loop contract. Named generators are
examples supplied by users, not endorsements, availability claims, or proof
that a service can produce acceptable media.

Examples currently listed in the app include Google Omni or Grok Imagine,
Minimax H3, Seedance 2.5, and LSX2.3. Product names, access, and terms can
change; verify them independently before uploading private or licensed artwork.

## Diagnostics and recovery

Open **Settings → Diagnostics** and choose **Refresh**. The report includes:

- app version/build and managed installation status;
- requested state, publisher health, publication ages, and active-session count;
- playback mode, selected media kind, and presentation state;
- conversion-tool readiness;
- player and aggregator LaunchAgent status; and
- readability of the media map, current state, media directory, and logs.

**Copy Diagnostics** excludes absolute home paths, prompts, session identifiers,
clip basenames, log contents, tool output, account information, and raw errors.
**Reveal Logs** opens the local logs directory in Finder.

Use **Repair Startup…** only for a missing or stale marked player startup item.
It never changes Codex hooks or the state aggregator.

## Troubleshooting

### Statelet has no Dock icon

This is expected. Open the Statelet orbit icon in the menu bar. If the app is not
running, launch it from Finder's Home → Applications folder or run:

```bash
open "$HOME/Applications/Statelet.app"
```

### The panel is blank

Import at least one Idle animation. Missing or invalid media fails softly. Use
**Actions… → Relink…** for a missing verified movie, or **General → Show Media
Map** to inspect its configured path.

### The pet cannot be clicked

Open the menu-bar icon and disable **Click-through**. If the panel moved off
screen, use **Settings → General → Reset Position**.

### Conversion tools are unavailable

```bash
command -v ffmpeg
command -v ffprobe
test -x /usr/bin/avconvert
"$HOME/Library/Application Support/CodexPet/alpha-runtime/bin/python3" \
  -c 'import numpy, PIL'
```

Choose **Check Again** after correcting the toolchain. If Python is elsewhere,
select it in the in-app Setup Guide.

### Conversion rejects a source

Inspect the complete clip. Common failures include a poor loop seam, variable
frame rate, camera motion, cuts, lost foreground, a shadow connected to the
subject, heavy green spill, alpha loss, corruption, or codec-introduced fringe.
The default importer records source edge contact and clears the pre-codec output
border; developer CLI use can opt into stricter source-framing rejection.

### Publisher health is Offline

Restart Codex if hooks were installed while it was open. Then inspect managed
jobs and logs:

```bash
launchctl print gui/$(id -u)/com.coke1120.codex-pet.state-aggregator
launchctl print gui/$(id -u)/com.coke1120.codex-pet.mac-player
tail -n 100 "$HOME/Library/Application Support/CodexPet/logs/state-aggregator.err.log"
tail -n 100 "$HOME/Library/Application Support/CodexPet/logs/mac-player.err.log"
```

Missing, invalid, future-dated, or stale publisher data falls back safely to
Offline Idle. A fresh record recovers automatically.

### Full Swift tests cannot import XCTest

Install and select full Xcode. Command Line Tools can build Statelet and run the
core self-test, but may not include the XCTest module.

## Privacy reminder

Statelet's lifecycle records do not include prompts, tool output, transcripts,
or working directories. Logs and animation media remain local. The application
does not send telemetry or upload crashes. Review any diagnostic excerpt before
sharing it, and never publish private media, reports, credentials, or complete
local logs.

Statelet is an independent community project and is not affiliated with or
endorsed by OpenAI.
