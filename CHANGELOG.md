# Changelog

All notable changes to Statelet are documented here. Versions follow semantic
versioning for the public source release.

## Unreleased

### Changed

- MP4 authoring now uses a stable even 320×480 pixel canvas independent of the
  resizable AppKit window.
- Conversion reports and import results identify stripped audio, non-identical
  loop endpoints, and automatic codec-canvas alignment as informational notices.
- Explicit non-square sample-aspect-ratio input is rejected before decoding.
- macOS CI discovers every Python test module and fails if any test is skipped.

### Fixed

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
- The internal bundle identifier, executable, LaunchAgent labels, preferences,
  and Application Support paths retain their legacy compatibility values.

[1.6.0]: https://github.com/Coke1120/statelet-codex-pet-macos/releases/tag/v1.6.0
