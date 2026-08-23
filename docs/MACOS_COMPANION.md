# Statelet lifecycle and media reference

This reference documents the internal contracts behind Statelet 1.8.17 (build
31), the native Codex and Grok Build lifecycle companion for macOS. Start with
[Deployment](DEPLOYMENT.md) for installation or [Using Statelet](USAGE.md) for
daily operation.

## Product boundary

Statelet is a macOS 13+ AppKit accessory application. It requires no external
display or development board. AVFoundation owns the active media decoder, and a
Python standard-library publisher converts local Codex and Grok Build hook
events into a small state file.

No animation media is bundled. MP4, MOV, poster, and report files remain
user-supplied local content.

Statelet 1.8.5 is the first tag with a workflow-produced, ad-hoc-signed personal
update package. Existing 1.8.4 or earlier installs require one manual bootstrap
update before later tags can install at a safe restart boundary. The package is
not Developer ID signed or notarized.
Owner-authorized updates use a pinned Ed25519 repository key plus a signed
GitHub release manifest; this is Statelet's personal-update authority, not a
replacement for Developer ID and notarization in public distribution.

## Lifecycle data flow

```text
Codex or Grok Build hook event on stdin
  -> mac/codex_pet_hook.py
  -> ~/Library/Application Support/Statelet/sessions/<hashed-session>.json
  -> mac/codex_pet_state_aggregator.py
  -> ~/Library/Application Support/Statelet/runtime/current_state.json
  -> Swift state watcher
  -> lifecycle badge and animation library
```

The hook stores one versioned record per provider session. It contains only:

- schema version;
- bounded provider (`codex` or `grok`);
- mapped lifecycle state;
- recognized event name;
- authoritative event time and local receipt time;
- terminal status; and
- bounded rejection counts for stale or conflicting callbacks; and
- bounded 24-hex hashes of turn/tool correlation IDs plus closed event
  phases, stored inside the same atomic owner-only record.

The filename is the first 24 hexadecimal characters of a provider-scoped
SHA-256 hash of the session identifier. The Codex namespace keeps its legacy
hash unchanged, while Grok uses a distinct namespace so equal raw identifiers
cannot collide. Prompt text, tool output, transcript paths, and working
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

Grok Build's documented global hook surface uses camelCase field names with
snake_case `hookEventName` values; Statelet normalizes both into the same bounded
contract. `UserPromptSubmit` and ordinary tool activity map to Running;
`permission_prompt` and `ask_user_question` waiting map to Waiting;
`exit_plan_mode` maps to Review until its tool callback; and `Stop`,
`StopFailure`, plus the `idle_prompt` notification settle the turn to Idle.
Statelet also accepts `StopCancelled` when a Grok release emits it, while the
current stable hook baseline uses `idle_prompt` as the cancellation backstop. A
Stop carrying active `backgroundTasks` remains Running. Grok can
block a Stop and continue the same prompt, so a newer correlated tool event may
revive it; the later final Stop still settles it, while stale tool callbacks are
rejected. Child-session payloads carrying `subagentType` are ignored for the
top-level projection.

`sessions/agent-source-v1.json` stores only `{version, mode}` where mode is
`combined`, `codex`, or `grok`. Missing or invalid data defaults to Combined.
Filtering is a projection: fresh records from the hidden provider remain
available and can reappear immediately when the selection changes, while normal
TTL and completed-history retention still bound both providers.

The Grok adapter is based on the public [Grok Build hooks contract](https://docs.x.ai/build/features/hooks),
not on private session-file tailing. ACP and streaming JSON remain separate
options for clients that own the Grok process; Statelet's passive desktop mode
does not require that ownership.

The display hook always exits successfully after emitting valid empty JSON on
stdout. A display-state write failure must not block or alter the Codex turn.

## Multi-session aggregation

The state priority is:

```text
waiting > review > running > idle
```

`Stop` closes the current turn and maps that session to Idle without creating a
completed-unread activity item. Its private causal fence still rejects delayed
callbacks from that stopped turn. `SessionEnd` alone terminalizes the session
and becomes a completed-unread activity item. Each other valid session record
remains active for 900 seconds after its authoritative event
time, except a `PostToolUse` record, which has a 30-second quiescent grace
period when Desktop fails to provide a terminal callback. A later hook event
refreshes the normal 900-second lease. Records that are malformed, non-finite,
expired, or more than 60 seconds in the future are rejected or pruned. A
delayed callback cannot replace a newer event for the same session.
Equal-priority records use the newest timestamp.

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
switch to another clip when effective `clip_end` rotation is enabled. A
character-scoped optional `in_state_transitions` entry for the current state can
decorate only that automatic handoff with the transparent layered transition
contract and a pre-rolled lower destination. These entries are independent of
distinct-state routes and their cursors. Reduce Motion and manual or refresh
paths use the direct switch.

An optional `transitions` map can bind a distinct ordered state pair such as
`idle_to_running` to an ordered playlist. Character maps keep character-local
routes, while `global-transitions.json` stores a separate shared Global
library. Runtime resolution is per route: a configured active-character route
overrides the matching Global route, and an absent character route falls back
to Global. The Transitions pane's Character/Global scope selector edits those
stores independently.

Each route has an independent `fixed`, `random`, or `sequential` selection mode
and `fixed_path`. Fixed uses the selected default, Random avoids an immediate
repeat when another readable variant exists, and Sequential follows persisted
order and wraps. Existing single-entry transition objects decode as Fixed
singleton playlists.

Selection occurs once for an accepted real lifecycle change. Initial launch,
same-state heartbeats, forced refresh, playlist rotation, Next Clip, Play Once,
transition preview, and Temporary State do not consume a route cursor. Reduce
Motion also skips selection and leaves the cursor unchanged. A selected
transition source may be up to 4 seconds, but playback is accelerated when
needed so the foreground is bounded to 1.5 seconds on screen. The player
retains the outgoing animation until the transition foreground has a
display-ready first frame. For a distinct-state change, it prepares the
destination on a separate hidden player and starts it during the final 350 ms,
or halfway through a shorter transition, before an atomic promotion. A
same-state clip-end handoff starts hidden attestation and player preparation up
to 3 seconds before the source ends, without consuming the source clip's normal
end fallback. The foreground is revealed from a source-player media-time cue,
timed to finish with the source when the remaining clip duration permits. Its
actual duration is split into thirds: outgoing fade, transition only, then
destination start and fade-in.
At the 1.5-second cap those phases are 0.5 seconds each. Because the outgoing
layer is transparent before the destination becomes visible, two state
animations never composite. A late destination keeps the transition's final
frame visible until atomic promotion.
If prewarm fails or misses activation, clip-end takes the direct replacement
path; Statelet does not restart transition attestation after the source stops.

Transition movies require current alpha reports; reportless or opaque assets
cannot round-trip through a character bundle. When a selected variant is
unreadable or fails runtime attestation/readiness, Statelet tries each other
eligible variant for that route at most once before committing the newest
destination directly. Superseding lifecycle changes remove stale players,
observers, deadlines, layers, and selection work; stale callbacks cannot commit
a route cursor or reveal an obsolete destination. Reduce Motion skips
transition video and switches to the destination static presentation without
an empty frame. Maps without `transitions` preserve direct destination commit.

Character export/import rewrites and preserves every character-local transition
variant, ordered position, selection mode, fixed/default path, poster/report
reference, hash, and validation record. Bundles exclude the Global transition
library, so importing or exporting a character never modifies shared routes.
Managed removal drops only the selected route reference first and will not move
files that another state, transition variant, character map, or Global route
still references.

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
3. estimates the observed green background per frame, reusing an earlier
   attested reference only for colour-matched, border-visible heavy occlusion;
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
Transition imports may contain fully transparent keyed frames when foreground
exists elsewhere in the clip; state-loop imports still require foreground in
every frame, and entirely transparent output is always rejected.

## Managed media safety

Imported files live under:

```text
~/Library/Application Support/Statelet/media/
```

Downloads and Finder paths are import sources only; `Statelet.app` remains
media-free. Settings → Help & Updates and Settings → General show this managed location
and offer an explicit Finder action without relocating or deleting an external
source.

Statelet offers file-moving deletion only for an unshared regular movie inside
that canonical directory while the active media map is also canonical. It
revalidates the map and filesystem immediately before moving the MOV and sibling
report to macOS Trash. Posters remain. External, shared, missing, symbolic-link,
or changed targets fail closed to mapping-only removal.

Unused-media cleanup lists candidates and size before confirmation, rescans, and
moves only still-unreferenced recognized files to Trash.

## Privacy and process boundary

The state publisher and local App Server title lookup make no network requests.
Statelet collects no telemetry and uploads no crash reports. Update checks and
owner-authorized package downloads contact the pinned GitHub repository;
optional package installation may also use the network through the user's
package manager.

For rows with a validated private activation target, the signed app can query
the local Codex App Server with `thread/read` and `includeTurns: false`. It
accepts only a bounded, sanitized `thread.name`, holds it in memory, and
discards previews, turns, and items. Title lookup never changes lifecycle state
or activation eligibility; resolved titles are not written to sidecars,
preferences, or logs.
The executable and exact launched process must satisfy OpenAI's Developer ID
Team ID requirement before Statelet sends any private thread identifier. Only
rows actually rendered in the expanded popup are eligible for lookup.
Only transition-based categorical lookup health is logged; raw errors, thread
identifiers, titles, paths, and response content are excluded.

Statelet is not sandboxed. The installer manages files in the current account's
Application Support and LaunchAgents directories, merges commands into
`~/.codex/hooks.json`, and installs additive global Grok registrations at
`~/.grok/hooks/statelet.json`. Managed directories and installed data use
restrictive local permissions. Diagnostics intentionally report categories and
counts rather than private content, but users should still review copied text
before sharing it.

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
endorsed by OpenAI or xAI.
