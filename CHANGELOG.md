# Changelog

All notable changes to Statelet are documented here. Versions follow semantic
versioning for the public source release.

## Unreleased

## [1.8.10] - 2026-08-20

### Changed

- Settings now opens at a wider 1000 × 650 point default, clamped to the
  visible display, while preserving user-resized dimensions.
- Existing installs still using the former 760 × 650 point default migrate
  once to the wider layout without overriding a later custom size.

### Fixed

- Opening Dialogue & Voice no longer lets AppKit shift the native split view
  to the right and expose a blank column beneath the window controls.
- A resize performed immediately after opening Settings is no longer replaced
  by the deferred first-show screen-clamping pass.

### Distribution notes

- Version 1.8.10 supersedes 1.8.9 with the Settings layout and resize fixes
  above; lifecycle, media, voice, and private runtime storage contracts remain
  unchanged.
- The package remains ad-hoc signed for owner-authorized personal updates. It
  is not Developer ID signed, notarized, or presented as an Apple-authorized
  public binary.

## [1.8.9] - 2026-08-19

### Fixed

- Statelet now validates both the on-disk Codex executable and the exact
  launched process against OpenAI's Developer ID Team ID before sending a
  private thread identifier.
- Title hydration is limited to rows actually rendered in the expanded popup;
  hidden, compact, unavailable, remapped, or stale rows cancel or reject their
  lookup without changing lifecycle or **Open in Codex** behavior.
- Resolver work now coalesces exact requests, globally expires and caps its
  memory cache, ignores cancellation for failure backoff, and reaps every App
  Server child during cancellation and app shutdown.
- Strict response IDs, nullable or missing names, closed input pipes, oversized
  output, and process replacement all fail soft without leaking private data.

### Distribution notes

- Version 1.8.9 supersedes 1.8.8 with the exact-process, shutdown, and
  rendered-row hardening above while retaining 1.8.8's unloaded-thread
  compatibility behavior; title text remains memory-only.
- No task title, technical thread identifier, conversation preview, turn,
  prompt, transcript, character media, voice data, or other private runtime
  data is bundled or persisted by title hydration.
- The package remains ad-hoc signed for owner-authorized personal updates. It
  is not Developer ID signed, notarized, or presented as an Apple-authorized
  public binary.

## [1.8.8] - 2026-08-19

### Fixed

- A displayed row whose Codex thread is no longer loaded no longer aborts task
  title hydration for other valid rows. Statelet accepts only the exact bounded
  App Server `thread not loaded` response as a missing title and continues the
  batch; malformed, mismatched, or unrelated protocol errors still fail closed.

### Distribution notes

- Version 1.8.8 supersedes 1.8.7 after live mixed loaded/unloaded task targets
  exposed this compatibility edge case. The title remains memory-only, and a
  missing title does not disable **Open in Codex** or change lifecycle state.

## [1.8.7] - 2026-08-19

### Changed

- Codex task-title hydration now ships inside the signed Swift application and
  stays memory-only, so an in-app update from 1.8.5 receives the complete
  feature without another source-installer bootstrap.
- The app requests only `thread/read` with `includeTurns: false`, accepts a
  bounded sanitized `thread.name`, and discards previews, turns, items, and
  other response fields.

### Fixed

- Title lookup timeouts, malformed or oversized responses, subprocess
  backpressure, and stale asynchronous completions fail soft without disabling
  **Open in Codex**, changing lifecycle state, or replacing a newer task title.
- Transition-only lookup health reports fixed categories without retaining raw
  errors, identifiers, titles, paths, or response content.
- Duplicate activity rows targeting one Codex thread share one cached lookup
  while retaining their independent lifecycle and acknowledgement state.
- The source installer journals and removes the obsolete owner-regular title
  sidecar left by the unpublished 1.8.6 candidate; unsafe path types fail
  closed without being followed.

### Distribution notes

- Version 1.8.7 supersedes the unpublished 1.8.6 release candidate, whose signed
  release job was cancelled before publication because that implementation
  still depended on external lifecycle components not delivered by app-only
  updates.
- No task title, technical thread identifier, conversation preview, turn,
  prompt, transcript, character media, voice data, or other private runtime data
  is bundled or persisted by title hydration.
- The package remains ad-hoc signed for owner-authorized personal updates. It is
  not Developer ID signed, notarized, or presented as an Apple-authorized public
  binary.

## [1.8.5] - 2026-08-19

### Added

- Owner-authorized personal update packages with a pinned Ed25519 manifest
  signature, immutable repository and `main` commit binding, and exactly one
  app ZIP plus its manifest and signature on tagged releases.
- Privacy-safe **Open in Codex** actions for supported pinned session targets;
  private target details remain outside the public activity feed.

### Changed

- Settings now uses a native unified Tahoe titlebar, full-height source-list
  sidebar, real toolbar reset item, semantic material cards, and consistent
  page headers while retaining macOS 13 compatibility.
- Settings destinations are grouped as App, Pet Content, Create Media, and
  Support, with stable persisted IDs, monochrome system symbols, and clearer
  names for Dialogue & Voice and Source Requirements.
- Sidebar rows and section cards rely on native AppKit selection and grouping
  semantics so keyboard and assistive navigation avoid duplicate announcements.

### Fixed

- Lifecycle records now retain bounded private correlation fences so delayed
  or conflicting callbacks cannot silently replace newer turn and tool phases.

### Distribution notes

- No character, animation, voice model, reference audio, session record, or
  other private runtime data is bundled.
- Version 1.8.5 is the first workflow-produced personal update package. An
  existing 1.8.4 or earlier install requires this one manual bootstrap update;
  later signed releases can install at a verified safe restart boundary.
- The package is ad-hoc signed for owner-authorized personal updates. It is not
  Developer ID signed, notarized, or presented as an Apple-authorized public
  binary.

## [1.8.4] - 2026-08-18

### Added

- Configurable dialogue-bubble background, text, opacity, and contrast behavior
  with readable light/dark and accessibility fallbacks.
- A movable, appearance-configurable activity popup with persisted,
  screen-clamped placement and a reset-to-default position action.
- Native Settings navigation with a stable AppKit source-list sidebar and
  managed-media location/status guidance.

### Changed

- Activity rows remain privacy-safe and explicitly informational when no
  supported Codex Desktop activation contract is available.
- Imported animation media remains in Statelet's private managed Application
  Support directory; the signed app bundle stays media-free.

### Distribution notes

- No character, animation, voice model, reference audio, session record, or
  other private runtime data is bundled.
- This release remains source-only. The local builder produces an
  ad-hoc-signed app for personal local use; a public updater package still
  requires Developer ID signing, notarization, stapling, a pinned team
  identifier, and clean-Mac Gatekeeper verification.

## [1.8.3] - 2026-08-18

### Changed

- Same-state clip-end handoffs now prewarm the transition and destination while
  the outgoing clip is still moving. The visible effect is aligned to the
  outgoing player's media clock and completes within the transition's actual
  presentation duration, capped at 1.5 seconds.
- The visible duration is split into three non-overlapping phases: fade the
  outgoing state out, show only the transition, then start and fade the
  destination in. A 1.5-second effect therefore uses three 0.5-second phases.

### Fixed

- Same-state rotation no longer waits for clip-end before attesting and decoding
  the transition, eliminating the normal frozen-final-frame preparation gap.
- Opacity is derived from transition media time rather than wall-clock work
  items, so sleep, occlusion, and resume keep the layers synchronized.
- Late destination readiness and retry keep the transition's final frame in
  front; cancellation and promotion reset every layer and time observer.
- If prewarm cannot finish before clip-end, rotation cuts directly to the
  already-selected next clip instead of restarting transition preparation on a
  frozen final frame.

### Distribution notes

- No character, animation, voice model, reference audio, session record, or
  other private runtime data is bundled.
- This release remains source-only. The local builder produces an
  ad-hoc-signed app for personal local use; a public updater package still
  requires Developer ID signing, notarization, stapling, a pinned team
  identifier, and clean-Mac Gatekeeper verification.

## [1.8.2] - 2026-08-16

### Changed

- Transition source clips remain compatible up to four seconds, while runtime
  playback accelerates longer effects so the foreground completes within 1.5
  seconds on screen.
- Lifecycle handoffs pre-roll the destination on a hidden player and promote it
  atomically after the transition ends and the destination is display-ready.
  Same-state clip-end handoffs start that hidden pre-roll as soon as the
  transition foreground is ready.

### Fixed

- A layered handoff whose destination was ready when the transition failed now
  commits that destination consistently instead of reporting completion while
  retaining the outgoing layer.

### Distribution notes

- No character, animation, voice model, reference audio, session record, or
  other private runtime data is bundled.
- This release remains source-only. The local builder produces an
  ad-hoc-signed app for personal local use; a public updater package still
  requires Developer ID signing, notarization, stapling, a pinned team
  identifier, and clean-Mac Gatekeeper verification.

## [1.8.1] - 2026-08-15

### Changed

- Transition imports can use a color-bound temporal green-background
  attestation when an effect temporarily obscures most of an otherwise verified
  background.
- Transition conversion accepts fully transparent keyed frames needed by
  fade-in and reveal effects, while still rejecting an animation that is
  transparent for its entire duration.

### Distribution notes

- No character, animation, voice model, reference audio, session record, or
  other private runtime data is bundled.
- This release remains source-only. The local builder produces an
  ad-hoc-signed app for personal local use; a public updater package still
  requires Developer ID signing, notarization, stapling, a pinned team
  identifier, and clean-Mac Gatekeeper verification.

## [1.8.0] - 2026-08-15

### Added

- Settings now includes a dedicated Help pane with privacy-safe release status,
  manual and daily update checks, cancellable download progress, and opt-in
  installation at a safe restart boundary.
- A session activity rail beside the pet shows active sessions and completed,
  unread work from a bounded owner-only sidecar without changing the
  authoritative lifecycle animation state.
- VoxCPM2 is available as a third private, offline dialogue provider using an
  explicitly imported local handover and reference WAV.
- Character playlists can use same-state clip-end transitions while retaining
  the outgoing layer until the next clip is ready.
- Settings window size is persisted, screen-clamped, resettable, and usable
  through scrollable compact layouts.

### Changed

- Global transitions now use one universal playlist for every distinct-state
  lifecycle change that has no character-specific directional override.
- The updater stages privately, verifies release metadata and artifacts, waits
  for playback, conversion, and voice work to quiesce, and publishes through a
  crash-recoverable atomic transaction journal.
- Qwen virtual-environment launchers may use relative or chained interpreter
  symlinks while retaining their environment-specific invocation path.

### Fixed

- Statelet returns to Idle after a quiescent final Desktop tool callback even
  when Codex does not deliver a terminal Stop or SessionEnd event.
- Alpha conversion uses FFmpeg's current per-stream passthrough mode so frame
  decoding remains compatible with FFmpeg 9 without synthesizing timestamps.
- Universal Global migration preserves unresolved legacy routes, keeps archived
  routes from silently reactivating, and recovers interrupted conversions as a
  visible conflict.
- Session activity publication, decoding, acknowledgement retention, window
  placement, and terminal callback handling now fail closed across stale data,
  symlinks, path replacement, malformed records, and constrained displays.

### Distribution notes

- No character, animation, voice model, reference audio, session record, or
  other private runtime data is bundled.
- This release remains source-only. The local builder produces an
  ad-hoc-signed app for personal local use; a public updater package still
  requires Developer ID signing, notarization, stapling, a pinned team
  identifier, and clean-Mac Gatekeeper verification.

## [1.7.1] - 2026-08-14

### Added

- Directional lifecycle routes now support ordered variants, batch import,
  per-variant replacement, and independent Fixed, Random, or Sequential
  selection.
- Directional transition playlists can be edited either for the active
  character or in a separate shared **Global** library. A character route takes
  precedence when present; an unconfigured character route falls back to its
  matching Global route.
- The Transitions pane provides a Character/Global scope selector for all 12
  ordered lifecycle routes.

### Changed

- Character bundles remain character-scoped: export and import include the
  selected character's transition playlists and assets, but never copy or
  modify the installation's Global transition library.
- Lifecycle hooks correlate turn and tool callbacks inside privacy-safe
  per-session records, while the aggregate publication remains free of those
  identifiers.

### Fixed

- Transition selection retries other eligible variants after runtime failure,
  commits its cursor only after accepted presentation, and prevents superseded
  callbacks from revealing a stale destination.
- Lifecycle publication recovers from replaced watched directories and stale
  aggregate files while keeping retry and watcher diagnostics path-free.

### Distribution notes

- No character or animation media is bundled.
- This release remains source-only. The local builder produces an
  ad-hoc-signed app for personal local use; a public binary still requires
  Developer ID signing, notarization, stapling, and clean-Mac Gatekeeper
  verification.

## [1.7.0] - 2026-08-13

### Added

- Dialogue messages and generated voice can be owned by Idle, Running, Waiting,
  or Review and are presented automatically when that lifecycle state appears.
- The active-character row exposes a directly visible **Delete Profile…**
  control while retaining confirmed, non-destructive deletion semantics.

### Changed

- macOS now uses the canonical Statelet bundle, process, preferences,
  Application Support, and LaunchAgent identity while preserving owned legacy
  installations through a crash-recoverable migration.
- Voice settings now separate dialogue text and generated-line controls from
  local GPT-SoVITS model, reference-audio, and profile setup.
- MP4 authoring now uses a stable even 320×480 pixel canvas independent of the
  resizable AppKit window.
- Conversion reports and import results identify stripped audio, non-identical
  loop endpoints, and automatic codec-canvas alignment as informational notices.
- Explicit non-square sample-aspect-ratio input is rejected before decoding.
- macOS CI discovers every Python test module and fails if any test is skipped.

### Fixed

- Looping animations no longer remain on their first frame when
  `AVPlayerLooper` populates its first queue item asynchronously.
- GPT-SoVITS requests use contiguous, non-parallel inference settings for short
  state messages; old-recipe clips are regenerated without deleting their WAV
  fallback before replacement succeeds.
- Odd requested HEVC-alpha dimensions are aligned before matting so Apple
  `avconvert` cannot silently crop a row or column after reference generation.
- The Animations pane keeps its per-state clip list visible at minimum window
  size and uses a compact MP4 import strip.

## [1.6.0] - 2026-08-10

First public release of **Statelet**, the local-first Codex lifecycle companion
for macOS.

### Added

- Native AppKit desktop companion for the `idle`, `running`, `waiting`, and
  `review` Codex lifecycle states.
- Privacy-safe multi-session lifecycle hook and local state aggregator.
- Transparent, draggable, border-resizable pet panel with menu-bar recovery.
- Per-state Fixed, Random, and Sequential animation libraries.
- Drop-zone and file-picker MP4 import with determinate conversion progress.
- Verified local MP4-to-HEVC-with-alpha conversion and sibling quality reports.
- Per-clip preview, Play Once, removal, Finder reveal, and managed-disk cleanup.
- Next Clip and temporary-state controls on the pet and in the menu bar.
- Reduce Motion posters, appearance controls, adjustable state-label color, and
  intended/nominal FPS display.
- Transactional source build, install, upgrade, startup repair, and uninstall
  workflows.
- Statelet app and menu-bar icon set.

### Distribution notes

- No character or animation media is bundled.
- This release is source-only. The local builder produces an ad-hoc-signed app;
  a public binary still requires Developer ID signing, notarization, stapling,
  and clean-Mac Gatekeeper verification.
- Version 1.6.0 retained the pre-Statelet technical identity. Version 1.7.0
  migrates those values to the canonical Statelet identity.

[1.8.10]: https://github.com/Coke1120/statelet-codex-pet-macos/releases/tag/v1.8.10
[1.8.9]: https://github.com/Coke1120/statelet-codex-pet-macos/releases/tag/v1.8.9
[1.8.8]: https://github.com/Coke1120/statelet-codex-pet-macos/releases/tag/v1.8.8
[1.8.7]: https://github.com/Coke1120/statelet-codex-pet-macos/releases/tag/v1.8.7
[1.8.5]: https://github.com/Coke1120/statelet-codex-pet-macos/releases/tag/v1.8.5
[1.8.4]: https://github.com/Coke1120/statelet-codex-pet-macos/releases/tag/v1.8.4
[1.8.3]: https://github.com/Coke1120/statelet-codex-pet-macos/releases/tag/v1.8.3
[1.8.2]: https://github.com/Coke1120/statelet-codex-pet-macos/releases/tag/v1.8.2
[1.8.1]: https://github.com/Coke1120/statelet-codex-pet-macos/releases/tag/v1.8.1
[1.8.0]: https://github.com/Coke1120/statelet-codex-pet-macos/releases/tag/v1.8.0
[1.7.1]: https://github.com/Coke1120/statelet-codex-pet-macos/releases/tag/v1.7.1
[1.7.0]: https://github.com/Coke1120/statelet-codex-pet-macos/releases/tag/v1.7.0
[1.6.0]: https://github.com/Coke1120/statelet-codex-pet-macos/releases/tag/v1.6.0
