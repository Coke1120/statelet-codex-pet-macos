# Passive turn outcomes and remaining public integration paths

Cloud design audit, 2026-10-11. Implementation base: main
`7df695bc3e27b2bce2b1b781b213d7fbae99124d` (PR43, post-merge native CI 233 passed).
This supersedes the outcome and public-integration gaps in the historical
[2026-10-10 review](CLOUD_REVIEW_2026-10-10.md); PR42 already delivered diagnostics
and the configurable shortcut, and PR43 delivered outgoing-context preview.

## Evidence before implementation

The [official pet guide](https://learn.chatgpt.com/docs/pets) distinguishes unread
successful completion (Ready), failure/system error (Blocked), and requests for
input. Statelet must not infer success from a session closing or from silence.

| Observed public signal | Meaning this change can safely display |
| --- | --- |
| Codex/Grok Stop | Stopped, outcome unverified. A Stop hook can request continuation. |
| Grok StopFailure | Blocked; retain no error details. |
| Codex Interrupt / Grok StopCancelled | Interrupted; never successful completion. |
| SessionEnd | Session closed, preserving a preceding known result. |
| Missing/old payload without outcome | Existing lifecycle/closure only; do not backfill success. |
| Quick Chat's owned CLI stream | Already requires `turn.completed`; that explicit chat runtime is separate from passive session observation. |

Codex's [public hook documentation](https://learn.chatgpt.com/docs/hooks) says
SessionEnd also occurs on archival, deletion, ordinary closure or idle unload.
We checked both the established 0.159.2 baseline
(`ff6aec96948b70d94983af2641a6b67c94faeff5`) and 0.162.1
(`092d3acd6bec3e3a14bdc7e7a2810ab628ab759d`, latest release observed October 11).
The [0.162.1 Stop input schema](https://github.com/openai/codex/blob/092d3acd6bec3e3a14bdc7e7a2810ab628ab759d/codex-rs/hooks/src/schema.rs)
has correlation and assistant text, but no authoritative success/failure field.
The [turn loop](https://github.com/openai/codex/blob/092d3acd6bec3e3a14bdc7e7a2810ab628ab759d/codex-rs/core/src/session/turn.rs)
runs Stop hooks before deciding whether to continue the turn. The released hook
schema has no StopFailure event. Unknown Codex StopFailure input cannot create
a Blocked badge.

There is a public legacy `agent-turn-complete` notify callback, but its
[implementation](https://github.com/openai/codex/blob/092d3acd6bec3e3a14bdc7e7a2810ab628ab759d/codex-rs/hooks/src/legacy_notify.rs)
passes a JSON payload containing conversation text and cwd on argv. This change
does not install that channel or relax Statelet's privacy policy to obtain Ready.
A future public, bounded terminal feed needs a separate design and explicit
ownership/coverage tests; an App Server connection is not proof that it can
observe every desktop-owned turn.

Grok's [public hook guide](https://docs.x.ai/build/features/hooks) and published
[event schema](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-hooks/src/event.rs)
distinguish Stop, StopFailure and StopCancelled. Its
[turn-end dispatcher](https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-shell/src/session/acp_session_impl/turn_end_hooks.rs)
uses the failure/cancellation events instead of ordinary Stop for those results.
The existing installer already registers StopFailure. This patch preserves that
configuration, accepts cancellation when delivered, and does not silently add
hooks unsupported by the older stable baseline. Stop can still be blocked for
continuation; `idle_prompt` alone remains an unverified stop signal.

## Bounded implementation

- Keep the four animation states, priority, hook exit-zero behavior and Interrupt
  fence. Correlated new PreToolUse after provisional Codex Stop may resume the
  same turn, but a late PostToolUse alone cannot; failure/interruption remain fenced.
- Store a random 24-hex receipt, fixed outcome enum and timestamp only. No prompt,
  assistant/error/tool text, credential or sensitive path enters the new metadata.
- Add optional `outcomes` beside legacy `completed` in activity schema v1. An
  interruption never enters the legacy completion list. Old files default to no
  outcomes; malformed/unsupported outcomes fail closed.
- Show latest outcome per session, not a turn archive. Accepted new work replaces
  it. Known failures/interruption survive subsequent SessionEnd without a new
  unread receipt. Duplicate/stale callbacks keep the existing receipt and time.
- Read/clear uses result receipts; task opening uses session IDs. A new result
  cannot inherit an earlier result's read state when a running snapshot was missed.
  Legacy closure acknowledgements remain compatible. Reading is explicit and local.
- Share the existing 64-item recent bound and seven-day retention. Each provider's
  private retention remains bounded during source filtering. Blocked results sort
  first within recent outcomes; active lifecycle ordering remains unchanged.

This is a truthful partial implementation of status parity: **passive Ready and
Codex failure badges remain unsupported**, rather than guessed. Missing hooks,
process loss and arbitrary tool errors do not prove a final failed turn.

## Separate follow-up PRs, not enabled by this change

| Area | Public route and feasible next bounded PR | Remaining gate |
| --- | --- | --- |
| Quick Chat capabilities | Keep today's two UTF-8 attachments, each at most 16 KiB, and disabled skills/apps/web/images/computer use. First assess explicit file/image selection against public CLI inputs or a separately authenticated API; preserve the complete outgoing preview. | A capability-specific permission/transport design and tests must precede enabling tools. Do not simply remove the current feature flags. No authenticated chat acceptance was performed in Cloud. |
| Realtime voice | The [public Realtime API](https://developers.openai.com/api/docs/guides/realtime) supports owned speech sessions with ephemeral credentials. A separate prototype could test interruption and audio handling with synthetic transports. | Requires credential, network/privacy and cost design plus microphone/audio testing. It does not attach to the official desktop voice session. Existing on-device dictation and system TTS remain unchanged. |
| Appshots / computer-use PiP | The official [Appshots guide](https://learn.chatgpt.com/docs/appshots) documents desktop capture and states that CLI cannot create Appshots. [Computer Use](https://learn.chatgpt.com/docs/computer-use) documents its plugin and OS permissions; the pet guide documents PiP attachment. A follow-up should first seek an explicit third-party handoff/attachment contract. | The reviewed public pages do not establish an external PiP/desktop voice control API. A standalone capture integration would be a separate consent/preview feature requiring macOS permission and real-screen tests, not an undocumented bridge to ChatGPT. |
| Official sprite interchange | The public [pet install deep link](https://learn.chatgpt.com/docs/reference/commands#pets) accepts `name`, HTTPS `imageUrl`, optional `description`, and sprite version 1 or 2. A separate PR can validate a user-supplied local sprite format and design an explicit export/install handoff. | Frame/state layout, licenses, alpha/playback verification and remote asset hosting need review. Do not upload private art automatically. The web upload dimensions (1536 × 1872 PNG/WebP, ≤20 MiB) alone do not establish desktop frame semantics. Physical official-app installation remains untested. |

The [official Voice guide](https://learn.chatgpt.com/docs/features/voice) describes
task steering and screen context in ChatGPT. These are product capabilities, not
evidence of a reusable Statelet control endpoint. Public integration paths exist;
the missing pieces above should not be described collectively as private or
impossible.

## Validation scope

Synthetic tests cover duplicate, stale and out-of-order callbacks, continuation,
failure versus cancellation, cross-session/provider isolation, read/clear actions,
missed running snapshots, old schema, malformed fields, privacy, target mapping,
retention and publisher changes. Final native CI must run Python without selected
skips, Swift, AVPlayer, core self-test, build and strict codesign on the candidate.

Cloud automation does not establish physical keyboard routing/focus, VoiceOver,
multiple displays/Spaces, macOS 13, signed-in conversation, actual provider hook
delivery, microphone/speaker behavior, or official-app sprite installation.
Independent review is a separate gate; author inspection is not independent review.
This draft has no merge, release or deploy authorization.
