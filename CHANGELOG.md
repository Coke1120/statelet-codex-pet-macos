# Changelog

All notable changes to Statelet are documented here. Versions follow semantic
versioning for the public source release.

## Unreleased

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

[1.7.1]: https://github.com/Coke1120/statelet-codex-pet-macos/releases/tag/v1.7.1
[1.7.0]: https://github.com/Coke1120/statelet-codex-pet-macos/releases/tag/v1.7.0
[1.6.0]: https://github.com/Coke1120/statelet-codex-pet-macos/releases/tag/v1.6.0
