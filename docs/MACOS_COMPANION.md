# Statelet lifecycle and media reference

This reference documents the internal contracts behind Statelet 1.6.0 (build
11), the native Codex lifecycle companion for macOS. Start with
[Deployment](DEPLOYMENT.md) for installation or [Using Statelet](USAGE.md) for
daily operation.

## Product boundary

Statelet is a macOS 13+ AppKit accessory application. It requires no external
display or development board. AVFoundation owns the active media decoder, and a
Python standard-library publisher converts local Codex hook events into a small
state file.

No animation media is bundled. MP4, MOV, poster, and report files remain
user-supplied local content.

The first public release is source-only. `build_app.sh` creates an ad-hoc-signed
app for personal local use; it is not Developer ID signed or notarized.

## Lifecycle data flow

```text
Codex hook event on stdin
  -> mac/codex_pet_hook.py
  -> ~/Library/Application Support/CodexPet/sessions/<hashed-session>.json
  -> mac/codex_pet_state_aggregator.py
  -> ~/Library/Application Support/CodexPet/runtime/current_state.json
  -> Swift state watcher
  -> lifecycle badge and animation library
```

The hook stores only:

- schema version;
- mapped lifecycle state;
- recognized event name; and
- `updated_at` timestamp.

The filename is the first 24 hexadecimal characters of a SHA-256 hash of the
session identifier. Prompt text, tool output, transcript paths, and working
directories are excluded.

## Event mapping

| Codex event | State |
| --- | --- |
| `SessionStart`, `SessionEnd`, `Stop` | Idle |
| `UserPromptSubmit`, `SubagentStart`, `SubagentStop` | Running |
| `PermissionRequest` | Waiting |
| `PreCompact`, `PostCompact` | Review |
| `PreToolUse`, `PostToolUse` | Review for recognized test/lint/typecheck/review work; Running otherwise |

The display hook always exits successfully after emitting valid empty JSON on
stdout. A display-state write failure must not block or alter the Codex turn.

## Multi-session aggregation

The state priority is:

```text
waiting > review > running > idle
```

Each valid session record remains active for 900 seconds after `updated_at`.
Records that are malformed, non-finite, expired, or more than 60 seconds in the
future are rejected or pruned. Equal-priority records use the newest timestamp.

The aggregator normally uses macOS `kqueue` directory events, so changed
session records wake it immediately. It also wakes at session TTL,
temporary-force, and once-per-minute liveness-heartbeat deadlines. If event
watching is unsupported or fails, bounded 250 ms polling preserves the same
behavior. Its path-free log diagnostic reports `mode=event_driven` or
`mode=poll_fallback` with a sanitized reason category. The aggregate contains
separate clocks:

- `source_updated_at` identifies the winning session event; and
- `emitted_at` identifies the aggregator publication time.

It also records the number of active sessions. Swift uses `emitted_at` for
publisher health. It accepts publications up to 150 seconds old and no more than
60 seconds in the future. Missing, malformed, stale, or farther-future data
produces an Offline badge and safe Idle fallback.

A fresh publication recovers automatically. A same-state heartbeat updates
liveness without rebuilding playback or advancing a playlist.

## Media map

The installed map is:

```text
~/Library/Application Support/CodexPet/media/media-map.json
```

The complete example is
[`mac/CodexPetMac/Examples/media-map.json`](../mac/CodexPetMac/Examples/media-map.json).
Each configured state has a playlist containing:

- `mode`: `fixed`, `random`, or `sequential`;
- optional `advance_on`: `state_entry` or `clip_end`;
- `fixed_path` identifying an entry after normalization; and
- ordered entries with `path`, optional `poster_path`, `loop`, and
  `playback_rate`.

`advance_on` defaults to `state_entry`. `clip_end` rotation is effective for
Random or Sequential libraries with at least two readable entries. Relative
paths resolve beside `media-map.json`. Duplicate normalized paths are rejected.

Legacy single-entry state objects still decode as Fixed, one-clip,
`state_entry` playlists. The next app-written map uses playlist form, so no
manual migration is required.

## Playback and preview contract

Statelet uses exactly one AVFoundation decoder. A real lifecycle change
preempts the current clip. Natural completion can hard-cut to another clip when
effective `clip_end` rotation is enabled. There is no cross-fade, second warmed
decoder, or weighted selection.

Play Once and Temporary State affect only the current process. They do not edit
the aggregate state or media map. The first fresh different producer state
relinquishes Temporary State and preempts one-time playback. Same-state
heartbeats preserve the temporary view.

The FPS label is metadata-based. It reports intended playback FPS and nominal
source FPS, not measured rendered frames.

## Verified alpha-video pipeline

MP4 is authoring input, not the delivered runtime format. The maintained
converter:

1. probes a constant-frame-rate, square-pixel source and records audio tracks;
2. aspect-fills a stable 320×480 authoring canvas, independent of window points;
3. estimates the observed green background per frame;
4. creates continuous alpha and controlled despill;
5. records source edge contact, informational loop-seam metrics, and clears the
   pre-codec output border;
6. writes a silent ProRes 4444 intermediate;
7. creates Apple HEVC with alpha;
8. decodes the delivery through Apple's media pipeline; and
9. checks alpha loss, corruption, retained green, and white/black/checkerboard
   composites on every frame.

Accepted output is a `.mov` beside its converter-generated `.report.json`.
Statelet copies and revalidates both before atomically updating the media map.
The running app never chroma-keys green video. Import results surface audio
removal, non-identical loop endpoints, and automatic even-geometry alignment as
notices; none of them bypasses a delivery acceptance gate.

## Managed media safety

Imported files live under:

```text
~/Library/Application Support/CodexPet/media/
```

Statelet offers file-moving deletion only for an unshared regular movie inside
that canonical directory while the active media map is also canonical. It
revalidates the map and filesystem immediately before moving the MOV and sibling
report to macOS Trash. Posters remain. External, shared, missing, symbolic-link,
or changed targets fail closed to mapping-only removal.

Unused-media cleanup lists candidates and size before confirmation, rescans, and
moves only still-unreferenced recognized files to Trash.

## Privacy and process boundary

The application and state publisher make no runtime network requests, collect
no telemetry, and upload no crash reports. Optional package installation may use
the network through the user's package manager.

Statelet is not sandboxed. The installer manages files in the current account's
Application Support and LaunchAgents directories and merges commands into
`~/.codex/hooks.json`. Managed directories and installed data use restrictive
local permissions. Diagnostics intentionally report categories and counts
rather than private content, but users should still review copied text before
sharing it.

## Stable compatibility identifiers

The Finder-visible name is Statelet. These identifiers remain unchanged for
managed upgrades:

| Field | Value |
| --- | --- |
| Bundle filename | `Statelet.app` |
| Display name | `Statelet` |
| Bundle identifier | `com.coke1120.CodexPetMac` |
| `CFBundleName` | `CodexPetMac` |
| Executable | `CodexPetMac` |
| Player LaunchAgent | `com.coke1120.codex-pet.mac-player` |
| Aggregator LaunchAgent | `com.coke1120.codex-pet.state-aggregator` |
| Managed marker | `mac-widget-v1` |

## Further reading

- [README](../README.md)
- [Deployment](DEPLOYMENT.md)
- [Using Statelet](USAGE.md)

Statelet is an independent community project and is not affiliated with or
endorsed by OpenAI.
