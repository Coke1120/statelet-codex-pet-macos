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

Session records remain eligible for 900 seconds. On macOS, `kqueue` directory
events normally wake the aggregator immediately; explicit TTL, temporary-force,
and once-per-minute heartbeat deadlines handle changes that do not produce a
file event. If event watching is unsupported or fails, bounded 250 ms polling
preserves correctness. The aggregator log reports a path-free
`mode=event_driven` or `mode=poll_fallback` diagnostic with a sanitized reason
category. A heartbeat refreshes publisher health but does not restart a movie
or advance a playlist.

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
- Clear **Keep Statelet on Top** to use normal window stacking, so other app
  windows can cover the pet. The same control is available in **Settings →
  General**.
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

## Manage characters

The character selector at the top of **Settings → Animations** controls the
complete animation map currently being viewed and played. Its menu shows each
character's name and clip count, followed by:

- **New Character…**, which creates and activates an empty four-state map while
  copying the current map's window and default-format settings; and
- **Import Bundle…**, which verifies and installs one `.statelet-character`
  directory package, then activates the imported character.

Use the adjacent actions button for **Rename…**, **Duplicate…**, **Export…**,
and **Delete…**, or use the directly visible **Delete Profile…** button. Names
must be unique. Duplicate copies the selected character's
entire map and activates the copy; media paths may remain shared. Delete removes
the character from the selector but deliberately keeps its map, movies, posters,
reports, and imported asset directory. This avoids irreversible data loss. The
last character cannot be deleted.

The original installation is always bootstrapped as `Default` and continues to
use the configured root map basename—normally `media-map.json`. Statelet does
not embed the character catalog into that map. Instead, it stores an
authoritative `character-library.json` sidecar beside the root map and gives
new characters separate same-directory hidden maps named
`.character-<id>.media-map.json`. Therefore:

- each character still has one ordinary, backward-compatible `MediaMap`;
- relative movie and poster paths resolve from the same directory as before;
- an older Statelet build can keep reading and writing the root default map;
  and
- switching characters loads that character's map directly rather than
  mirroring it into `media-map.json`.

### Import and export character packages

A `.statelet-character` item is a directory package. Export writes
`manifest.json` plus declared movies, posters, and any matching reports under
the package. The manifest carries one ordinary Statelet media map with paths
rewritten only to its bundle-relative assets.

Import is local and fail-closed. Statelet bounds the manifest, asset count,
individual role sizes, and aggregate size; rejects absolute, traversing,
backslash, non-normalized, duplicate, and case/NFC-colliding paths; opens package
content without following symbolic links; verifies every declared byte size and
lowercase SHA-256; and requires movie, poster, and report references to match
their declared roles. Movies must also pass AVFoundation playback checks.

When a report is present, Statelet validates the report against the copied
movie and does not convert a portable claim into local attestation. A package
may omit reports for legacy portability, but importing those reportless movies
requires the explicit trust confirmation shown before import. Explicit trust
does not create a report or claim full alpha/composite provenance; the movies
still have to pass playback checks. Cancel the confirmation if the package or
its media source is not trusted.

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
Normal playlist rotation does not use a cross-fade or second warmed decoder.

The clip table shows order, filename, readiness, fixed state, poster state, and
preview state. Each row provides **Preview** or **Stop**, **Actions…**, and
**Remove…**.

The Actions menu can:

- choose or remove a Reduce Motion poster;
- reveal a readable movie in Finder;
- relink a missing movie using a verified MOV/report pair;
- set the fixed clip; and
- move a clip up or down in display and Sequential order.

### Directional lifecycle transitions

Choose **Transitions** in Settings → Animations to configure the active
character's optional source → destination clips. All 12 distinct ordered pairs
are available: `Idle → Running` and `Running → Idle`, for example, are separate
settings. Each row offers **Import…** or **Replace…**, **Preview**, and
**Remove…**. Import accepts an MP4 for conversion or a verified transparent
MOV/report pair using the same validation and managed-media safety boundary as
state animation clips.

A transition clip is decorative, must be no longer than 4 seconds, and must
retain a working alpha channel backed by its current converter report. Reportless
or visually opaque transition assets are rejected, including during character
bundle import and export.

For a real A → B lifecycle change, Statelet keeps A attached while it prepares
the transition and B. The transition becomes a foreground layer only after its
first frame is display-ready. B then starts below that foreground before the
transition ends; the default lead-in is the final 350 ms, or half of a shorter
clip. When the foreground completes, only that layer is removed and the already
running B animation continues. A newer lifecycle event cancels every obsolete
player, readiness observer, deadline, and layer before it can reveal a stale
destination. If either new asset fails, the last valid lower presentation stays
visible while Statelet retries or safely retains it for the newest authoritative
state; it never substitutes an empty lower layer.

This handoff is transparent layer compositing, not an opacity cross-fade. With
Reduce Motion enabled, preview is unavailable and runtime transition video is
skipped; Statelet switches to the destination static presentation without an
intermediate blank frame.

Transitions are stored per character and round-trip, with their movie/report
hash binding and validation status, in secure `.statelet-character` bundles.
Removing a transition first removes only the
active character's reference; managed-file Trash eligibility is revalidated
before any file move. Maps and imported character bundles without transitions
remain compatible and continue switching directly to destination animations.

## Import MP4 animations

Use only media you own or have permission to adapt and distribute. Keep private
source videos outside the repository.

The recommended source is:

- a constant-frame-rate MP4 with one stable video stream;
- square pixels with no rotation metadata;
- a full-body character with clean margin on every side;
- a locked camera and stable framing, exposure, scale, and focus;
- a clean, stable green-screen background (uniform RGB `#00FF00` is ideal);
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
the selected state's drop zone. A drop preserves Finder order and removes exact
duplicate paths. Missing, unreadable, directory, remote, and non-MP4 items are
reported individually while the remaining valid MP4s continue through the
batch.

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

Before expensive frame processing, conversion preflight rejects unsupported
rotation, non-square pixels, variable frame rate, HDR/BT.2020, interlacing,
oversized sources, excessive duration or frame count, and insufficient working
disk space. These are actionable source-compatibility failures, not reasons to
relax delivery verification. Audio is the exception: it is intentionally
stripped and reported as a warning because Statelet animations are silent.

The `standard` profile keeps strict source preparation and delivery gates. Its
framing mode can be `fill` (crop to the stable canvas) or `fit` (preserve the
whole frame and pad with the supported green key background). Profile and
normalization choices are written into report schema v1 so an imported result
can be explained and reproduced. The profile never changes the required codec,
geometry/frame agreement, Apple round-trip, all-frame alpha/composite checks,
artifact hashes, or atomic publication rules.

The progress indicator uses structured probe, per-frame matte, encode,
round-trip, and Swift installation stages. It measures completed work rather
than estimating time remaining. Verification can take several minutes.

One failed source does not stop later files. The final status shows sanitized
filenames and actionable sanitized reasons. **Cancel Conversion** stops the
active MP4, skips the remaining batch, removes incomplete artifacts, and keeps
clips already appended.

## Portable MOV reports

Keep each locally created movie beside its matching report when diagnosing or
recovering conversion output:

```text
idle.mov
idle.report.json
```

Report schema v1 records toolchain, profile,
normalization, and invocation provenance; unknown future schema versions fail
closed. Report JSON is limited to 1 MiB and schema-v1 provenance must use the
canonical Statelet method, producer, and a 64-character lowercase hexadecimal
challenge even when the report is being considered as a portable claim.
Reports without a schema remain parseable only as legacy portable
claims. A challenge written in a portable report is self-asserted and does not
grant local trust. Output bound to the current conversion is installed as
**locally attested**. A schema-v1 portable pair can be installed only after the
app clearly labels it **portable/unattested** and the user explicitly accepts
that trust decision; confirmation does not rewrite the report or claim it was
produced locally. Legacy schema-less claims remain parser-compatible but may be
rejected by the app. Statelet also verifies AVFoundation can open exactly one
HEVC video track, find zero delivery audio tracks, match the reported
geometry/FPS/duration, and decode its first frame. A source-audio-stripped
notice describes authoring input; it never permits audio in the delivered movie.

For the direct **Verified MOVs…** workflow, an arbitrary MOV, opaque H.264 MP4,
renamed file, missing report, or mismatched report is rejected. A portable
unattested report never passes silently: either the user explicitly accepts it
or imports the authorized source MP4 so this Statelet installation can convert
and attest it locally. The separate character-package workflow permits
reportless legacy clips only with the explicit package-level trust described
above. Its runtime playback smoke check complements rather than replaces the
converter's all-frame Apple round-trip and alpha/composite gates.

## Remove clips and clean media

**Remove from State** changes only the active character's map; it keeps the
movie, report, and poster files.

**Remove & Move Files to Trash** appears only when the movie is an unshared
regular file inside the canonical managed media folder and the active media map
is also canonical. It moves the MOV and sibling `.report.json` to recoverable
Trash and keeps posters.

External, missing, shared, symbolic-link, or noncanonical targets fail closed to
state-only removal. Removing the active or fixed entry selects from the
remaining library. Removing the last entry removes that state mapping and uses
the normal no-media fallback.

Use **Settings → Diagnostics → Clean Unused Media…** to find recognized files
inside the managed media directory that no character playlist references.
Statelet loads every profile map before considering a file unused; a missing or
invalid inactive map makes cleanup fail closed instead of risking shared media.
The catalog and all profile map files are always retained. Statelet lists names
and approximate size, asks for confirmation, rescans, and moves only recognized
movie, poster, or report files that remain eligible to Trash. Files retained by
Delete become cleanup candidates only when no remaining profile references
them.

## Dialogue and local voice

Open **Settings → Voice**. Use **Voice Setup** to configure one local GPT-SoVITS
voice profile, then use **Dialogue** to enter text and manage generated lines.
If no profile has been saved yet, Voice opens on Voice Setup; otherwise it opens
on Dialogue and remembers subsequent page changes while Settings remains open.

1. Start GPT-SoVITS API v2 on this Mac. The default endpoint is
   `http://127.0.0.1:9880`.
2. In **Voice Setup**, enter a profile name, prompt language, default dialogue
   language, and the exact transcript of the reference recording.
3. Still in Voice Setup, import the trained GPT `.ckpt` weight, SoVITS `.pth`
   weight, and reference audio separately. Import only files you trust and
   recordings you are authorized to use.
4. Save the profile. Statelet rejects non-loopback endpoints, missing managed
   assets, unsafe paths, symbolic links, and unsupported import extensions.
5. Switch to **Dialogue**, choose the owning Idle, Running, Waiting, or Review
   state, enter a line and its GPT-SoVITS language identifier, then choose
   **Add**. The line is saved before background generation begins.

Dialogue text can be saved as a draft before Voice Setup is ready. The page
shows that generation will begin only after a valid profile and local service
are available; switching between the two pages does not discard unsaved form
or dialogue edits.

The profile reports `Not configured`, `Validating`, `Ready`, `Invalid`, or
`Local service unavailable`; Statelet fingerprints the model bytes, reference
audio, transcript, endpoint, and language inputs and revalidates them after
restart and before generation if file identity changes. Reference audio must be
decodable by macOS, and the profile becomes `Ready` only after the local API
accepts both weight files. The table reports `Draft`, `Queued`, `Generating`,
`Ready`, `Failed`, or `Stale`. **Preview** is enabled only for validated `Ready`
output. **Retry**
reuses the same line after a failed request, while **Regenerate** invalidates
the old result and queues a new revision. Editing a line or saving a changed
profile also invalidates prior output. A late result cannot replace a newer
revision or recreate a deleted line.

When Statelet commits a newly entered lifecycle state, it displays that state's
preferred message on the pet. If the preferred line has ready generated audio
Statelet plays it without interrupting a preview or state voice already in
progress. Only the latest state-entry voice remains queued while audio is busy.
Same-state heartbeats and clip rotation do not replay the message. Legacy
dialogue saved before state ownership existed is assigned to Idle.

Statelet calls GPT-SoVITS API v2's local `/set_gpt_weights`,
`/set_sovits_weights`, and `/tts` endpoints. It does not start, install, train,
download, or update GPT-SoVITS. The service must be reachable through plain
HTTP on numeric IPv4 or IPv6 loopback; hostnames, proxies, redirects, and remote
hosts are refused so sensitive request data cannot leave the local transport.
Dialogue uses a separate speech player; accepted Statelet animation deliveries
remain silent, so preview or runtime speech does not pause lifecycle animation.
TTS requests use `cut0`, batch size `1`, disabled parallel/bucket inference,
zero fragment interval, and the bounded sampling values documented in the
source so short messages remain contiguous. Statelet versions generated output
independently from the model fingerprint; after this recipe changes, legacy WAV
files remain protected until their replacements generate successfully.

Managed voice data lives below:

```text
~/Library/Application Support/Statelet/voice/
```

Directories and files are owner-only. Metadata and generated WAV files use
temporary writes plus atomic publication. Logs record line identifiers, state,
and bounded error codes—not dialogue text, reference text, model paths, or
audio. Reopening Statelet safely requeues interrupted work; missing ready audio
is treated as stale. Removing a profile deletes Statelet's managed model,
reference, and generated-audio copies while retaining dialogue text as drafts.
If a private managed file cannot be removed safely, Statelet persists a bounded
cleanup record, reports the deferred cleanup, and retries it at next launch.

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
"$HOME/Library/Application Support/Statelet/alpha-runtime/bin/python3" \
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
launchctl print gui/$(id -u)/com.coke1120.statelet.state-aggregator
launchctl print gui/$(id -u)/com.coke1120.statelet.mac-player
tail -n 100 "$HOME/Library/Application Support/Statelet/logs/state-aggregator.err.log"
tail -n 100 "$HOME/Library/Application Support/Statelet/logs/mac-player.err.log"
```

Missing, invalid, future-dated, or stale publisher data falls back safely to
Offline Idle. A fresh record recovers automatically.

### Full Swift tests cannot import XCTest

Install and select full Xcode. Command Line Tools can build Statelet and run the
core self-test, but may not include the XCTest module.

## Privacy reminder

Statelet's lifecycle records do not include prompts, tool output, transcripts,
or working directories. Logs, animation media, voice models, reference audio,
dialogue, and generated speech remain local. The application does not send
telemetry or upload crashes; the optional voice adapter permits only loopback
HTTP. Review any diagnostic excerpt before sharing it, and never publish
private media, models, speech, reports, credentials, or complete local logs.

Statelet is an independent community project and is not affiliated with or
endorsed by OpenAI.
