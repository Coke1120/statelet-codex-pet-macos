# Grok Bot presence source

Status: Phase 1 implemented on 2026-10-28. Phase 2 remains proposed and is not
part of this change.

## Goal

Let Statelet's existing **Idle**, **Running**, and **Waiting** animations respond
to local Grok Bot activity without credentials, network access, private APIs, or
a new Grok Bot hook protocol.

Grok Bot is a cloud-agent desktop client. It does not expose the Codex/Grok
Build lifecycle hook contract used by `codex_pet_hook.py`. It does, however,
maintain a local roster of its bots and their high-level activity. That roster is
enough for a coarse, privacy-safe presence source.

## Non-goals for Phase 1

- No Grok Bot hook protocol. None exists to integrate with.
- No private API, Keychain, session token, or account credential access.
- No prompt, message, transcript, bot name, title, description, avatar, path, or
  repository data in logs, diagnostics, or Statelet state.
- No **Review** animation. The roster has no review-work signal.
- No claim of successful completion or failure. Unread is not success.
- No Accessibility permission requirement.
- No new **Agent Source** selector or Settings provider choice. This follows the
  roadmap caution against adding provider choices before onboarding work.
- No activity-rail entry yet. Phase 1 drives the lifecycle animation only.

## Source

Read-only local inputs:

```text
~/Library/Application Support/Grok Bot/sand-client-persistence/
  <base32-encoded-key>.blob
      newest key ending in .roster.last-roster

~/Library/Application Support/Grok Bot/desktop-status.json
  pid, signedIn, appVersion, startedAtMs
```

The roster blob is JSON with `schemaVersion: 4` and `value.rows[]`. Each row
contains bot identity and activity metadata. Some rows also contain private
message previews, names, titles, descriptions, avatar photos, and repository
paths; those fields are deliberately not retained.

### Privacy projection

Only these row fields cross the parser boundary:

| Source field | Internal projection | Purpose |
| --- | --- | --- |
| `id` | first 24 hex characters of `SHA-256("grokbot:" + id)` | stable opaque identity |
| `awaitingUserResponse` | boolean `awaiting` (non-null/non-false) | Waiting |
| `lastActivityAt`, `localActivityAt` | finite normalized epoch seconds | coarse Running |
| `isHiddenFromSidebar` | boolean `hidden` | skip user-hidden bots |
| `hasUnread`, `unreadCount` | bounded metadata | reserved for Phase 2 |

The raw bot ID is used only to compute the opaque hash during projection. It is
not stored in the projected row, retained across polls, or written to state.

Explicitly discarded: `name`, `title`, `description`, `lastEntry`,
`sessionPreview`, `avatarPhoto`, `path`, `memberIds`, and every other key.

## State mapping

| Grok Bot condition | Statelet state | Quality |
| --- | --- | --- |
| `awaitingUserResponse` is non-null/non-false | **Waiting** | Direct roster signal |
| `max(lastActivityAt, localActivityAt)` is within the active window | **Running** | Coarse; recent-activity pulse |
| Otherwise | **Idle** | No active roster contribution |
| Hidden from sidebar | Ignored | User intent |
| Unread / unread count | Not projected in Phase 1 | Reserved |
| Failed | Not available without Accessibility | Out of scope |
| Review work | Not available | Out of scope |

The default active window is 120 seconds. This is deliberately short: a bot
that runs a long tool call without refreshing the roster can briefly fall back
to Idle. Phase 2 can add an optional Accessibility-enhanced mode for accurate
Running/Failed classification. The roster-only mode must not pretend to have
that accuracy.

`awaitingUserResponse` is treated as a direct Waiting signal. Its contents are
never decoded. The source records the first time it observed the wait and keeps
that timestamp stable across polls so the publisher does not rewrite state every
two seconds. When the field clears, the wait timestamp is discarded; a later
wait starts a new interval.

## Architecture

```text
Grok Bot roster blob + desktop-status.json
  -> mac/codex_pet_grokbot.py
       base32 filename decode
       schema/version and size checks
       privacy projection (no text, names, or raw IDs)
       per-bot waiting/running presence
  -> mac/codex_pet_state_aggregator.py
       merge roster presence with hook sessions
       waiting > review > running > idle
  -> runtime/current_state.json
  -> Swift state watcher and PetPlayer
```

The roster source lives inside the existing aggregator process. There is no new
LaunchAgent and no synthetic session file. This keeps one state authority, avoids
extra process memory, and lets the existing priority and publication rules apply
unchanged.

## Enablement and configuration

The source is opt-in at the aggregator command line:

```text
--grokbot
--grokbot-persistence-dir PATH
--grokbot-status-path PATH
--grokbot-poll SECONDS
--grokbot-active-window SECONDS
```

The installer passes `--grokbot` with explicit paths under the installation
home. Repository tests and manual aggregator runs without the flag never inspect
a developer's real Grok Bot data.

The source contributes only when the aggregator's **Agent Source** mode is
`combined`. Selecting Codex or Grok hides Grok Bot presence as well, matching the
current projection semantics. A dedicated Grok Bot source filter is Phase 2.

## Polling and liveness

- Poll at most once every 2 seconds. Cache projected rows by candidate-file
  metadata and re-derive presence from the cached rows as time advances; a
  degraded fallback is re-read so its 30-second bound can be enforced.
- Read `desktop-status.json`, require a positive PID, and verify the process with
  `kill(pid, 0)`. Treat `signedIn: false` as unavailable.
- If Grok Bot is not running, contribute nothing and clear waiting timestamps.
- If the persistence directory is absent, contribute nothing. Recheck less often
  so users who install Grok Bot later are detected without a restart.
- Pick the newest roster blob whose base32-decoded key ends in
  `.roster.last-roster`. If it is unreadable or malformed, try a small number of
  older candidates. An older-candidate fallback is degraded and is used for at
  most 30 seconds; then the source fails closed until the newest roster becomes
  valid. If all candidates fail, reuse the last valid rows for a 30-second grace
  period, then fail closed.
- Require `schemaVersion == 4`. An unsupported schema fails closed rather than
  guessing at a future format.
- Bound the roster to 8 MiB, 1,024 rows, and a 256-character raw ID.
- Use a stable file identity check (`dev`, `ino`, `size`, `mtime_ns`, `ctime_ns`)
  around each read so a partially replaced file is never parsed.

## Diagnostics

Diagnostics are path-free, ID-free, and rate-limited:

```text
Statelet Grok Bot roster status=degraded reason=<category>
Statelet Grok Bot roster status=recovered
```

Allowed categories: `unreadable`, `invalid_json`, `unsupported_schema`,
`invalid_rows`, `too_large`, `changing`, and `internal_error`. `no_roster` is an
internal reason and stays silent; missing Grok Bot or a stopped app is not an
error.

## Failure behavior

The source is best-effort:

- A parser or filesystem error never crashes the aggregator. A newer malformed
  blob may briefly fall back to an older candidate; a sustained error removes the
  source's contribution after the bounded grace period (or immediately for an
  unsupported schema), and the aggregator keeps publishing hook-based state.
- A malformed roster cannot keep a stale bot busy indefinitely; both the stale
  cache and any older-candidate fallback are bounded to 30 seconds.
- Grok Bot quitting removes its contribution on the next poll.
- The source never uses the network.
- The source never writes to the Grok Bot directory.

## Phase 1 implementation checklist

1. Add `mac/codex_pet_grokbot.py` with the bounded roster reader, privacy
   projection, presence derivation, liveness check, and diagnostics.
2. Add `--grokbot*` options to `mac/codex_pet_state_aggregator.py`; merge source
   presence into the existing lifecycle aggregation without changing hook
   sessions or the activity sidecar.
3. Include the new source deadline in the aggregator wake calculation.
4. Install `statelet_grokbot.py` with the existing Python component and enable
   `--grokbot` in the installed aggregator LaunchAgent with explicit home paths.
5. Add synthetic-fixture tests for schema, privacy, waiting/running/idle,
   milliseconds/seconds, hidden bots, liveness, malformed data, source mode,
   stale fallback, and aggregator priority/deadline integration.
6. Document the source, limits, and privacy behavior in the macOS companion and
   usage guides.

## Phase 2 options

Only after Phase 1 is verified:

- Add a `grokbot` activity-rail provider with a distinct source filter. This
  requires `AgentProvider`, `AgentSourceMode`, Python provider validation, UI
  labels, and Settings tests.
- Add an optional, opt-in Accessibility classifier for accurate Running and
  Failed states. It must be app-side, occlusion-aware, transient-only, and
  explicit about its English-only text heuristics.
- Define a text-free unread/completion projection. `hasUnread` alone is not a
  successful turn and must not produce a Ready claim.

## Verification

Use full Xcode for the Swift commands (for example,
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`). The
canonical gate remains
[DEPLOYMENT.md](DEPLOYMENT.md#release-verification).

```bash
PYTHONDONTWRITEBYTECODE=1 python3 tools/run_tests.py
swift run --package-path mac/CodexPetMac -c release codex-pet-core-self-test
swift test -c release --package-path mac/CodexPetMac --skip PetPlayerPlaybackIntegrationTests
STATELET_RUN_AVPLAYER_INTEGRATION=1 swift test -c release --package-path mac/CodexPetMac --filter PetPlayerPlaybackIntegrationTests
bash mac/CodexPetMac/scripts/build_app.sh
codesign --verify --deep --strict mac/CodexPetMac/dist/Statelet.app
```

Manual check with Grok Bot running:

```bash
python3 mac/codex_pet_state_aggregator.py \
  --state-dir "$HOME/Library/Application Support/Statelet/sessions" \
  --output "${TMPDIR:-/tmp}/statelet-grokbot-check.json" \
  --grokbot --once --print-state
```

The manual command must not print bot names, IDs, message text, or paths.
