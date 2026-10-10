# CLI health and Companion shortcut — 2026-10-10

## Starting point and scope

Cloud Linux checkout, freshly fetched `main`
`80bccf93d2a2ffbb9c304f52488201d0d531a7bb`, on the separate
`codex/cli-health-companion-shortcut-20261010` branch. PR #41's lifecycle,
reader, routing, FIFO, speech and Reduce Motion fixes are already present.
Only compatibility diagnostics and a configurable Companion shortcut are in
scope. No personal Mac, installation, merge, release or deployment is authorized.

## Design before implementation

- Extend the existing Settings diagnostics report with a typed, sanitized
  compatibility result. Discover the same signed CLI as Quick Chat; never run
  an unsigned candidate or relax its signature policy to obtain a result.
- Check version, exact Quick Chat argument parsing, and every disabled feature
  offline in a fresh private scratch home. `0.159.2` is the validated baseline,
  not a claim about the earliest supporting release. Report an older version,
  unknown version, rejected flags and missing features separately.
- Inspect effective user hooks through the official read-only `hooks/list`
  App Server method in a scratch working directory, without starting a thread
  or sending a prompt. Inspect the user's hooks feature separately. Disable
  plugins/apps and telemetry for the diagnostic invocation only; never write
  security/trust settings or pass a trust-bypass flag.
- Identify only exact Statelet interpreter/script commands and expected event
  matchers. Count enabled/trusted/modified/untrusted registrations; discard
  commands, source paths, keys, hashes, warnings and raw errors. An unreadable
  or unfamiliar response is unverified, not healthy. Configured/trusted is not
  a live hook-delivery or authenticated-chat test.
- Bound time, bytes and child-process lifetime; serialize checks on the
  existing diagnostics queue, cancel superseded checks and cancel on exit.
- Keep shortcut registration in a small AppKit/Carbon bridge. Settings records
  a supported key plus modifiers; preference changes are transactional. A
  collision or registration failure leaves the previous shortcut active and
  saved. Disable and reset are explicit actions. Default: Control–Option–Command–J.
- Use the existing long-lived Companion model. A shortcut hides a focused
  panel, brings an unfocused panel forward, or opens a hidden panel and focuses
  its composer. Preserve drafts, attachments and Mini mode. Escape closes it.
- Clamp presentation against current visible screen frames, selecting the
  display with the greatest pet overlap, then the nearest display. Account for
  negative coordinates, small screens, removed displays and mode changes.

## Test matrix

| Area | Automated evidence required |
| --- | --- |
| CLI availability | Missing / signature-unverified candidates never run; normal, older and malformed versions have distinct actions |
| Flags / features | Synthetic CLIs accepting or rejecting the actual argument vector; missing feature names cannot report compatible |
| Hooks | Complete trusted, missing, incomplete, disabled, untrusted and modified definitions; misleading commands/matchers and malformed responses fail safely |
| Privacy / resources | Private sentinels in all raw fields never reach the report; no prompt/thread/write RPC; timeout, output cap, cancellation and cleanup |
| Shortcut preferences | Valid persistence/reload, disabled/reset, reserved and invalid combinations, conflict rollback and shutdown unregister |
| Companion | Repeated show/hide/refocus retains draft and attachments; explicit focus requests and Escape close |
| Geometry | Negative coordinates, greatest overlap, nearest screen, small-screen fit, removed display and Mini/expanded transitions |

Native Swift tests will run in the existing macOS CI on the final candidate.
Selected portable Python checks and offline CLI probes run in Cloud first;
the incomplete Linux full Python baseline is not rerun. Physical global-key
delivery, other apps' registrations, focus across Spaces/fullscreen, actual
multi-monitor arrangements, keyboard layouts and macOS 13 remain manual limits.

## Contract sources

Checked 2026-10-10: [official hook trust flow](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks),
[official macOS pet shortcut](https://learn.chatgpt.com/docs/pets#show-or-hide-the-floating-controls),
and Codex 0.159.2's offline CLI help. Hook metadata is pinned to
[HooksListResponse](https://github.com/openai/codex/blob/ff6aec96948b70d94983af2641a6b67c94faeff5/codex-rs/app-server-protocol/schema/json/v2/HooksListResponse.json)
and [read-only catalog implementation](https://github.com/openai/codex/blob/ff6aec96948b70d94983af2641a6b67c94faeff5/codex-rs/app-server/src/request_processors/catalog_processor.rs).
The RPC lists definitions without dispatching hooks or starting a model turn.

## Results

- The existing signed-executable discovery policy is shared by Quick Chat and
  diagnostics. Diagnostics exports only typed categories, bounded counts and a
  parsed numeric version. Compatibility probes do not send prompt content,
  start a thread, invoke a trust bypass or issue a write RPC. Superseded probes
  cancel, pipe readers join, and application shutdown joins/kills pending work.
- Shortcut preferences and registration have one owner. Settings retains its
  attempted combination after a conflict and displays the still-active setting.
  Exclusive Carbon registration checks enabled system hotkeys and ignores key
  repeat until release. No global input monitor or new permission prompt is used.
- Companion reuses its model, explicitly requests composer focus, restores the
  previous application on shortcut/Escape hiding, and fits against live screen
  frames, including when displays change during a mode transition.
- Review caught the existing standalone diagnostics compilation harness's new
  dependency. The pure report/metadata policy was separated from process probes
  and added to that harness, preserving the existing privacy assertions.
- Follow-up review requires a regular executable interpreter and both installed
  hook modules before runtime presence can count as ready. It also restores the
  prior Statelet key window when opening Companion from Settings, avoiding a
  stale external-app focus target. Regression cases cover both corrections.
- Command recognition preserves POSIX double-quoted non-special backslashes,
  so a nonexistent interpreter cannot be mistaken for an executable one.
- The native gate identified Carbon's imported `Int` event-count parameter;
  buffer size and event count now use the native Swift counts without narrowing
  conversions. The gate is rerun automatically on the corrected committed head.
- The next native gate passed all nine compatibility cases and three geometry
  cases before the focus fixture failed its physical foreground assumption and
  crashed during window cleanup. The regression now supplies its focus context,
  verifies the AppKit return-focus request, and disables close-time auto-release
  on its Swift-owned test window. Actual foreground/Spaces focus stays manual.
- Native gate #229 passed all 19 new cases, including real Carbon exclusive
  collision/release, retained Settings drafts and return-focus requests. Its two
  failures were the existing General-page card count/title expectations; these
  now include the new Companion Shortcut card. All style/accessibility checks
  remain in place.
- Cloud Linux: **169 selected portable Python tests passed, zero skips** using
  the command in [the prior review](CLOUD_REVIEW_2026-10-10.md#environment-and-baseline).
  A smaller 16-test hook-registration/CI selection passed first. No unrelated
  full Linux run or media conversion experiment was repeated.
- Offline Codex **0.159.2** accepted the exact `CompanionChatPolicy.arguments`
  with `--help`. All **17** disabled feature names were recognized and false in
  a fresh isolated home. No authenticated model request was made.
- The real **0.159.2** read-only `hooks/list` API was exercised against an
  isolated synthetic config: all 12 event definitions were enabled/untrusted,
  with the expected camel-case metadata and no warnings/errors. Only initialize,
  initialized and hooks/list messages were sent; no hook or model turn ran.
- New native tests cover synthetic CLI compatibility, hook trust/registration
  variants, warning/malformed metadata, privacy sentinels, active cancellation,
  deadlines/output caps, shortcut persistence/conflict rollback, actual Carbon
  reservation collision/release, Settings' retained draft, repeated panel
  toggle/refocus, Escape and screen geometry. Native execution is recorded in
  the draft PR against its final committed head; it is not a Linux result.

Physical global-key delivery, other apps' interception, keyboard layouts,
Spaces/fullscreen focus, installed multi-monitor behavior, macOS 13, sign-in,
live lifecycle delivery and authenticated chat remain unverified. Automated
Carbon reservation and synthetic screen tests do not establish those outcomes.
