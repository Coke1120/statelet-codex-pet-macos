# Statelet brand direction

## Recommended product name

**Statelet**

Descriptor: **A living Codex lifecycle companion for macOS**

Traditional Chinese positioning: **把 Codex 的工作狀態變成桌面上有生命感的小夥伴。**

Why it fits:

- `State` describes the product's real job: translating Idle, Running, Waiting,
  and Review into visible behavior.
- The `-let` ending makes the name feel small, lightweight, and companion-like.
- It stays character-agnostic, so users can import their own animation style.
- It can grow beyond one generator, one character, or one animation format.

Use **Statelet** as the Finder and Settings display name. Keep the existing
bundle identifier and executable name during a rename so installed-user and
LaunchAgent upgrades remain compatible.

## Icon concept: Living State Orbit

The icon combines three product ideas without using a character portrait:

1. **Sprite tile** — the stepped central shape represents a small desktop
   resident and an animation frame.
2. **Developer cursor** — the pearl caret and mint underscore read as a tiny
   terminal prompt without using text or a vendor logo.
3. **Lifecycle orbit** — the open mint loop has four broad notches for Idle,
   Running, Waiting, and Review, while one bright bead makes the state feel alive.

The icon deliberately avoids multicolor runtime dots: live state colors belong
in the badge, while the application identity stays stable. The caret, underscore,
and open orbit remain recognizable at Finder and Spotlight sizes.

## Color system

| Role | Color |
| --- | --- |
| Graphite surface | `#171D24` |
| Deep background | `#0D1116` |
| Primary lifecycle mint | `#3EE6A8` |
| Cursor pearl | `#F3F7F5` |

The icon itself should not change for each runtime state. State color changes
belong in the pet badge and menu-bar UI, keeping the application identity stable.

## Delivered assets

- `statelet-app-icon.svg` — editable vector master.
- `statelet-app-icon-1024.png` — 1024 px app-icon master.
- `Statelet.icns` — ready for a macOS application bundle.
- `statelet-menubar-template.svg` — editable monochrome menu-bar master.
- `StateletMenuBarTemplate.pdf` — bundled template image for light and dark menu bars.

## Integration boundary

The integrated display-brand boundary is:

1. Copy `Statelet.icns` into `Contents/Resources` during `build_app.sh`.
2. Set `CFBundleIconFile` to `Statelet.icns` and `CFBundleDisplayName` to
   `Statelet`.
3. Use the user-visible bundle filename `Statelet.app`. The installer migrates
   only a legacy `CodexPetMac.app` carrying the expected bundle ID and managed
   marker, with transactional rollback and unmanaged-file preservation.
4. Keep `CFBundleIdentifier`, `CFBundleName`, executable, LaunchAgent labels,
   runtime paths, and preference keys unchanged for upgrade compatibility.

## Alternate names

1. **Codex Sprite** — clearest connection to the existing product and animated
   desktop-sprite behavior.
2. **Loopling** — more playful and animation-led.
3. **Deskbit** — compact, local, and developer-oriented.
4. **Runlet** — emphasizes active work but undersells Waiting and Review.

Name and trademark availability have not been checked.

Statelet is an independent community project and is not affiliated with or
endorsed by OpenAI. Asset authorship and redistribution details are recorded in
the repository's `ASSET_PROVENANCE.md`.
