# Grok Bot presence source

Status: Phase 1 lifecycle presence and Phase 2 generic activity-rail rows are
implemented on 2026-10-28. Optional Accessibility classification and a
text-free completion projection remain future work.

## Goal

Let Statelet's existing **Idle**, **Running**, and **Waiting** animations respond
to local Grok Bot activity without credentials, network access, private APIs, or
a new Grok Bot hook protocol. Phase 2 also exposes the same coarse presence as
generic active rows in the existing activity rail, with a dedicated source
filter.

Grok Bot is a cloud-agent desktop client. It does not expose the Codex/Grok
Build lifecycle hook contract used by `codex_pet_hook.py`. It does, however,
maintain a local roster of its bots and their high-level activity. That roster is
enough for a coarse, privacy-safe presence source.

## Non-goals

- No Grok Bot hook protocol. None exists to integrate with.
- No private API, Keychain, session token, or account credential access.
- No prompt, message, transcript, bot name, title, description, avatar, path, or
  repository data in logs, diagnostics, Statelet state, or the activity rail.
- No **Review** animation. The roster has no review-work signal.
- No claim of successful completion or failure. Unread is not success.
- No Accessibility permission requirement.
- No per-bot rail title. Rows are generic **Grok Bot · Waiting/Running ·
  Activity** entries; the opaque hash is not displayed.
- No synthetic completed or unread rail outcome. Phase 2 adds active presence
  only.
- No new onboarding flow; the existing **Agent Source** selector gains a
  Grok Bot choice because the user explicitly selected this Phase 2 track.

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
| `hasUnread`, `unreadCount` | bounded metadata | reserved; never projected as completion |

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
| Unread / unread count | Not projected | Reserved; not a completion claim |
| Failed | Not available without Accessibility | Out of scope |
| Review work | Not available | Out of scope |

The default active window is 120 seconds. This is deliberately short: a bot
that runs a long tool call without refreshing the roster can briefly fall back
to Idle. Optional Accessibility-enhanced classification for accurate
Running/Failed remains future work. The roster-only mode must not pretend to
have that accuracy.

`awaitingUserResponse` is treated as a direct Waiting signal. Its contents are
never decoded. The source records the first time it observed the wait and keeps
that timestamp stable across polls so the publisher does not rewrite state every
two seconds. When the field clears, the wait timestamp is discarded; a later
wait starts a new interval. Running rows use the first observed activity time as
their stable start and the latest roster activity time as their bounded event
time.

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
       merge generic active rail rows
  -> runtime/current_state.json
  -> sessions/activity-v1.json
  -> Swift state watcher, PetPlayer, and activity rail
```

The roster source lives inside the existing aggregator process. There is no new
LaunchAgent, no synthetic session file, and no separate Grok Bot activity
sidecar. This keeps one state authority, avoids extra process memory, and lets
the existing priority, freshness, and publication rules apply unchanged.

### Activity-rail projection

The aggregator copies only the source's generic active rows into
`sessions/activity-v1.json`:

| Field | Value |
| --- | --- |
| `id` | opaque 24-hex bot hash |
| `state` | `waiting` or `running` |
| `event` / `category` | `unknown` / `activity` |
| `provider` | `grokbot` |
| `started_at` / `event_at` | stable start and latest activity/wait timestamp |
| `terminal` | `false` |

Hook rows win identifier collisions and the existing 64-row cap. The merge
skips malformed rows rather than making the whole sidecar unreadable. Grok Bot
rows never enter the completed or unread groups and never produce an activation
target. The rail displays the provider name and coarse state only; it does not
display the opaque hash.

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

The source contributes when the aggregator's **Agent Source** mode is
`combined` or `grokbot`. Selecting Codex or Grok hides Grok Bot presence from
both the pet state and the activity rail. The dedicated `grokbot` mode shows
only roster presence and filters out hook sessions; Combined shows both.

## Polling and liveness

- Poll at most once every 2 seconds. Cache projected rows by candidate-file
  metadata and re-derive presence from the cached rows as time advances; a
  degraded fallback is re-read so its 30-second bound can be enforced.
- Read `desktop-status.json`, require a positive PID, and verify the process with
  `kill(pid, 0)`. Treat `signedIn: false` as unavailable.
- If Grok Bot is not running, contribute nothing and clear both lifecycle
  presence and generic rail rows.
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

## Implementation checklist

Phase 1:

1. Add `mac/codex_pet_grokbot.py` with the bounded roster reader, privacy
   projection, presence derivation, liveness check, and diagnostics.
2. Add `--grokbot*` options to `mac/codex_pet_state_aggregator.py`; merge source
   presence into the existing lifecycle aggregation without changing hook
   sessions.
3. Include the new source deadline in the aggregator wake calculation.
4. Install `statelet_grokbot.py` with the existing Python component and enable
   `--grokbot` in the installed aggregator LaunchAgent with explicit home paths.
5. Add synthetic-fixture tests for schema, privacy, waiting/running/idle,
   milliseconds/seconds, hidden bots, liveness, malformed data, source mode,
   stale fallback, and aggregator priority/deadline integration.
6. Document the source, limits, and privacy behavior in the macOS companion and
   usage guides.

Phase 2 activity rail:

1. Add `grokbot` to `AgentProvider` and `AgentSourceMode`, including a Settings
   choice and Python source-mode validation.
2. Project the source's coarse presence into generic active rows in
   `sessions/activity-v1.json`; keep completed, unread, target, and title paths
   Grok-Bot-free.
3. Preserve hook-row collision and cap precedence; skip malformed presence rows.
4. Add Python merge/projection tests and Swift contract, rail-label, and
   Settings tests.
5. Document the generic-row privacy boundary and the Combined/Grok Bot filter
   behavior.

## Remaining Phase 2 options

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

Manual check with Grok Bot running (use a temporary state directory so the
installed activity sidecar is never rewritten):

```bash
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/statelet-grokbot-check.XXXXXX")
trap 'rm -rf "$check_dir"' EXIT
python3 mac/codex_pet_state_aggregator.py \
  --state-dir "$check_dir/sessions" \
  --output "$check_dir/current_state.json" \
  --grokbot --once --print-state
```

The manual command prints only the coarse state. It must not print bot names,
IDs, message text, or paths.
