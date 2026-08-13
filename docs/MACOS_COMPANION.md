# Statelet lifecycle and media reference

This reference documents the internal contracts behind Statelet 1.7.0 (build
12), the native Codex lifecycle companion for macOS. Start with
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
  -> ~/Library/Application Support/Statelet/sessions/<hashed-session>.json
  -> mac/codex_pet_state_aggregator.py
  -> ~/Library/Application Support/Statelet/runtime/current_state.json
  -> Swift state watcher
  -> lifecycle badge and animation library
```

The hook stores one versioned record per Codex session. It contains only:

- schema version;
- mapped lifecycle state;
- recognized event name;
- authoritative event time and local receipt time;
- terminal status; and
- bounded rejection counts for stale or conflicting callbacks; and
- bounded 24-hex hashes of Codex turn/tool correlation IDs plus closed event
  phases, stored inside the same atomic owner-only record.

The filename is the first 24 hexadecimal characters of a SHA-256 hash of the
session identifier. Prompt text, tool output, transcript paths, and working
directories are excluded.
The correlation metadata is never copied into `current_state.json` or app
diagnostics and expires with its session record.

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

`Stop` and `SessionEnd` terminalize only their own session. Each other valid
session record remains active for 900 seconds after its authoritative event
time. Records that are malformed, non-finite, expired, or more than 60 seconds
in the future are rejected or pruned. A delayed callback cannot replace a newer
event for the same session. Equal-priority records use the newest timestamp.

The aggregator normally uses macOS `kqueue` directory events, so changed
session records wake it immediately. It also wakes at session TTL,
temporary-force, and once-per-minute liveness-heartbeat deadlines. If event
watching is unsupported or fails, bounded 250 ms polling preserves the same
behavior. Its path-free log diagnostic reports `mode=event_driven` or
`mode=poll_fallback` with a sanitized reason category. The aggregate contains
separate clocks and ordering metadata:

- `source_updated_at` identifies the winning session event; and
- `emitted_at` identifies the aggregator publication time;
- `publication_revision` increases monotonically across changed publications
  and heartbeats, including aggregator restarts;
- `latest_event` and `latest_event_at` identify the newest accepted hook event;
  and
- `recovery` marks the first publication after the aggregator starts.

It also records the number of active sessions and bounded rejection counts.
Swift uses `emitted_at` for publisher health and the revision to reject an
older or conflicting snapshot that arrives after a newer one. It accepts
publications up to 150 seconds old and no more than 60 seconds in the future.
The watcher retries transient missing or malformed reads after atomic
replacement and falls back to polling if its directory watch is invalidated.
Persistent missing, malformed, stale, or farther-future data produces an
Offline badge and safe Idle fallback.

A fresh publication recovers automatically. A same-state heartbeat updates
liveness without rebuilding playback or advancing a playlist.

## Media map

The installed map is:

```text
~/Library/Application Support/Statelet/media/media-map.json
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

Normal Statelet playback uses one AVFoundation decoder. Natural completion can
hard-cut to another clip when effective `clip_end` rotation is enabled. Normal
playlist playback has no cross-fade, warmed decoder, or weighted selection.

An optional `transitions` map can bind a distinct ordered state pair such as
`idle_to_running` to an ordered playlist. Each route has an independent
`fixed`, `random`, or `sequential` selection mode and `fixed_path`. Fixed uses
the selected default, Random avoids an immediate repeat when another readable
variant exists, and Sequential follows persisted order and wraps. Existing
single-entry transition objects decode as Fixed singleton playlists.

Selection occurs once for an accepted real lifecycle change. Initial launch,
same-state heartbeats, forced refresh, playlist rotation, Next Clip, Play Once,
transition preview, and Temporary State do not consume a route cursor. Reduce
Motion also skips selection and leaves the cursor unchanged. A selected
transition plays once and is bounded to 4 seconds. The player retains the
outgoing animation until the transition foreground has a display-ready first
frame. It prepares the destination on a separate lower player and starts it
during the final 350 ms, or halfway through a shorter transition. Completion
removes the foreground and promotes the already-running destination without
clearing every layer. This is alpha compositing rather than an opacity
cross-fade.

Transition movies require current alpha reports; reportless or opaque assets
cannot round-trip through a character bundle. When a selected variant is
unreadable or fails runtime attestation/readiness, Statelet tries each other
eligible variant for that route at most once before committing the newest
destination directly. Superseding lifecycle changes remove stale players,
observers, deadlines, layers, and selection work; stale callbacks cannot commit
a route cursor or reveal an obsolete destination. Reduce Motion skips
transition video and switches to the destination static presentation without
an empty frame. Maps without `transitions` preserve direct destination commit.

Character export/import rewrites and preserves every transition variant,
ordered position, selection mode, fixed/default path, poster/report reference,
hash, and validation record. Managed removal drops only the selected route
reference first and will not move files that another state, transition variant,
or character map still references.

Play Once and Temporary State affect only the current process. They do not edit
the aggregate state or media map. **Return to Live State** immediately restores
the newest accepted live snapshot. The first fresh different producer state
also relinquishes Temporary State and preempts one-time playback. Same-state
heartbeats preserve the temporary view while still repairing publisher metadata.

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
~/Library/Application Support/Statelet/media/
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

## Canonical installed identity

New builds, installations, and repaired startup items use these identifiers:

| Field | Value |
| --- | --- |
| Bundle filename | `Statelet.app` |
| Display name | `Statelet` |
| Bundle identifier | `com.coke1120.Statelet` |
| `CFBundleName` | `Statelet` |
| Executable | `Statelet` |
| Application Support | `~/Library/Application Support/Statelet` |
| Player LaunchAgent | `com.coke1120.statelet.mac-player` |
| Aggregator LaunchAgent | `com.coke1120.statelet.state-aggregator` |
| Managed marker | `statelet-v2` |

### Legacy upgrade compatibility

The installer accepts the old `CodexPetMac.app`, bundle ID
`com.coke1120.CodexPetMac`, Application Support directory `CodexPet`,
`com.coke1120.codex-pet.*` LaunchAgents, legacy managed plist keys, and marker
`mac-widget-v1` only as ownership-checked migration input. They are not used for
fresh installations or repaired startup items.

## Further reading

- [README](../README.md)
- [Deployment](DEPLOYMENT.md)
- [Using Statelet](USAGE.md)

Statelet is an independent community project and is not affiliated with or
endorsed by OpenAI.
