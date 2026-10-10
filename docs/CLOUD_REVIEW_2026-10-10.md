# Cloud stabilization review — 2026-10-10

This review starts from remote `main`
`26a40c27020fe626e8220d9a7f5abc3627a4c713`, fetched on 2026-10-10.
The checkout was clean. Work uses a separate `codex/cloud-compatibility-performance-20261010`
branch; no release, merge, installation, or access to a personal Mac is part of
this review.

## Environment and baseline

The selected Codex Cloud environment is Linux x86_64 with Python 3.12.14,
Codex CLI 0.159.2, FFmpeg and ffprobe. It has no Swift, Xcode, codesign, plutil,
Apple avconvert, or macOS GUI. Python 3.9 and the project's hash-locked macOS
authoring environment are also absent; installed NumPy is 2.3.5, not the pinned
2.0.2. No `cloud-environment-onboarding` setup was supplied in the environment
or available skill catalogs, so no such setup was run. The repository guidance,
CI workflow, roadmap and relevant bundled media/voice skill boundaries were
inspected; private media and voice runtimes were not provisioned.

The complete Python runner was attempted against an untouched base worktree:
469 tests, 13 failures, 124 errors and 14 skips with `umask 022`. These are
incomplete native validation, not a passing gate: packaging requires `plutil`,
codesign and Darwin `renameatx_np`; other checks require Swift, AppKit or kqueue.
An earlier run with the Cloud default `umask 077` additionally failed three
fixture permission assumptions. No tests were weakened or skipped in CI.

The explicitly selected portable baseline passed **156 tests with zero skips**:

```bash
umask 022
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  tests.test_codex_hook tests.test_grok_hook \
  tests.test_codex_pet_state.LifecycleStateTests \
  tests.test_codex_pet_state.PublisherTests \
  tests.test_macos_performance tests.test_ci_workflow \
  tests.test_statelet_hook_commands -v
```

## Confirmed baseline defects

- Malformed nested lifecycle events and overflowing integer timestamps can
  terminate aggregation before a healthy sibling session is published.
- Lifecycle, activity and activation-target readers enumerate the same
  directory three times and read each hook record twice per iteration.
- Codex `Interrupt` is absent from registration and both language contracts.
  A synthetic prompt → permission request → interrupt remains `waiting`, with
  event `unknown` and an open turn fence.
- Companion's root-config line parser ignores normal trailing TOML comments
  and can mistake text inside a multiline instruction for an actual endpoint.
- Opening a FIFO attachment blocks before the regular-file check. A Linux
  POSIX surrogate exceeded a 501 ms timeout with the existing flags; adding
  `O_NONBLOCK` returned in 0.032 ms and identified a non-regular file. This is
  syscall evidence, not a macOS UI measurement.
- Independent review found the same blocking-open issue in the Codex config
  reader before the chat watchdog starts.
- Closing Companion stops current speech but a pending reply can start speech
  again after the panel closes.
- Enabling Reduce Motion without a configured poster retains the current video
  without suspending it. Existing tests check retained identity, not stopped
  playback.

## Implemented and reviewed changes

- Reject malformed lifecycle data per record, so healthy sessions still
  publish. Hook writers can recover from damaged existing records as well.
- Share bounded hook reads within one aggregation iteration, with no cache
  retained across iterations; preserve safe pruning and publication order.
- Register and decode Codex `Interrupt`, clear outstanding approvals and close
  the turn fence. Preserve nonterminal idle and reject stale callbacks without
  manufacturing completed-unread activity. A new prompt can start a fresh turn.
- Parse only supported root TOML settings, including trailing comments; reject
  multiline/container/quoted-key decoys. Unsupported root syntax uses the
  documented default routing fallback. Open config files without FIFO blocking,
  retaining regular-file symlink compatibility and bounded reads.
- Disable the current CLI's separate image/browser/computer capabilities and
  execution-rule loading. Keep the read-only sandbox and document the remaining
  upstream zero-tool limitation below.
- Reject special-file attachments without blocking. Keep completed reply text
  while suppressing automatic speech after Companion closes.
- Compose Reduce Motion with sleep and occlusion suspension, freezing retained
  video even without a poster and restoring the intended rate only when every
  suspension reason clears.

Final selected portable validation: **169 tests passed, zero skips** using the
baseline command above. Independent review found no blocking issues after the
config-reader follow-up; it separately ran 75 lifecycle tests (six additional
Darwin-only tests unavailable), 71 hook/Grok/registration tests, malformed-field
probes and descriptor-cleanup probes. New Swift tests cover Interrupt decoding,
config/attachment FIFO rejection, conservative routing, hidden-panel speech and
Reduce Motion playback; their execution belongs to the native CI gate.

All 17 disabled feature names were recognized as false by the installed Codex
0.159.2 feature listing, and the exact chat argument policy passed offline help
parsing. These checks made no authenticated model request. Diff whitespace,
example media-map JSON, new relative documentation links and the tracked-media
exclusion check passed.

The reviewed work is delivered in [draft PR #41](https://github.com/Coke1120/statelet-codex-pet-macos/pull/41).
Its checks and PR verification record bind native results to the final head;
an earlier run on an intermediate commit is not final-candidate evidence.

## Reader performance comparison

The same [benchmark script](../tools/measure_state_readers.py) ran against the
untouched base worktree and the patched readers committed as `d9bbfbf`, using
synthetic records only:

```bash
python3 tools/measure_state_readers.py --source-root /path/to/baseline
python3 tools/measure_state_readers.py --source-root /path/to/candidate
```

Five rounds of 20 warm iterations per size, with one target file per session:

| Sessions | Baseline median (ms) | Candidate median (ms) | Reduction |
| ---: | ---: | ---: | ---: |
| 1 | 0.0527 | 0.0405 | 23.1% |
| 16 | 0.4278 | 0.3340 | 21.9% |
| 64 | 1.5895 | 1.1853 | 25.4% |
| 256 | 6.3256 | 4.7579 | 24.8% |
| 1,024 | 26.9725 | 20.0176 | 25.8% |

Instrumented reads fall from **3N to 2N**, directory listings from **3 to 1**.
All five projection SHA-256 values match between revisions. The shared snapshot
is discarded every iteration, preserves descriptor-bound reads and cleanup,
and caps reuse at 4 MiB of input file bytes / 4,096 hook records. Above the cap,
secure reads continue without caching; targets are never cached. The byte cap
is not a measurement of Python object memory.

Raw results: [before](benchmarks/2026-10-10-readers-before.json),
[after](benchmarks/2026-10-10-readers-after.json). These are reader-only Linux
microbenchmarks, excluding fixture construction and publication. They do not
measure macOS kqueue wakeups, player CPU/RSS, energy, alpha-media playback or
end-to-end presentation latency. Timing varies with host load; the operation
counts and matching outputs provide the deterministic evidence.

The lifecycle patch passed 162 selected portable tests with zero skips,
including six added malformed-record/snapshot regressions.

## Current ChatGPT Mini / pet compatibility

Official Mini is a floating desktop chat interface with the pet hidden, not a
model. Statelet already offers a compact draft-preserving bar, chat, an activity
list, task opening, pet visibility, resizing and verified character import.
Its idle/running/waiting/review animation contract differs from the official
Running/Needs input/Ready/Blocked status presentation. [Official pet guide](https://learn.chatgpt.com/docs/pets)

| Area | Verified Statelet scope / remaining difference |
| --- | --- |
| Chat | Ephemeral Codex CLI conversation; two bounded UTF-8 text attachments. No authenticated end-to-end chat was run during this review. |
| Voice | On-device dictation and system speech; not ChatGPT's realtime voice or task steering. |
| Activation | Existing menu command and verified task opening; no configurable global shortcut. |
| Character assets | Verified `.statelet-character` bundles; no established OpenAI desktop pet installation API. |
| Context and desktop work | No verified third-party Appshots, computer-use PiP, or desktop voice-control integration. |

CLI 0.159.2's offline generated schema confirms `Interrupt` support; the earliest
supporting version was not established. The official hook contract identifies
an active main-turn interruption, including `turn_id`; it is not session end.
User hooks require definition-specific review/trust through `/hooks`.
[Official hook contract](https://learn.chatgpt.com/docs/hooks#interrupt)

The existing JSONL reply decoder and title resolver match the documented
non-interactive and App Server shapes. Public `turn/interrupt` and `turn/steer`
methods do not establish ownership of a separate desktop app's turn. No private
protocol was invented. [Non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode),
[App Server](https://learn.chatgpt.com/docs/app-server)

The installed version's official source shows `view_image` is registered
independently of `shell_tool`. The existing flags therefore do not enforce the
documented text-only boundary. A true empty tool allowlist exists in the Rust
extension API but was not found in the public CLI/config/ThreadStart schema;
`apply_patch` can remain advertised under the read-only sandbox. Do not describe
feature disables as a verified zero-tool protocol.
[Pinned Codex 0.159.2 tool registration](https://github.com/openai/codex/blob/ff6aec96948b70d94983af2641a6b67c94faeff5/codex-rs/core/src/tools/spec_plan.rs),
[extension tool policy](https://github.com/openai/codex/blob/ff6aec96948b70d94983af2641a6b67c94faeff5/codex-rs/ext/extension-api/src/tool_policy.rs)

Official documentation was accessed on 2026-10-10; those pages did not show
absolute publication dates. Local help/schema inspection made no model request.

## Feature proposals, not implemented scope

| Priority | Proposal | Acceptance evidence needed |
| --- | --- | --- |
| P1 | Safe compatibility diagnostics for CLI flags and hook readiness | Supported and incompatible synthetic CLIs produce actionable categories without paths, prompts, credentials or raw errors. |
| P1 | Configurable global Companion shortcut | Conflict handling, draft preservation, focus and multiple-display testing on macOS. Avoid taking the official app's shortcut by default. |
| P2 | Separate failed/interrupted/ready outcome badges | Authoritative provider events and migration tests; keep existing user media usable and never label cancellation as success. |
| P2 | Explicit context handoff preview | User reviews bounded selected context before sending; no clipboard monitoring or automatic screen capture. |
| P2 | Validate cached voice separately from model loading | Measure startup time/RSS with authorized models before changing the existing trust boundary, as already proposed in the roadmap. |
| P3 | Public sprite-sheet import feasibility | Confirm format semantics, licensing, conversion verification and performance; a web upload format does not authorize private desktop installation. |

## Validation limits

The existing macOS CI is the native automated gate: Python, Swift, AVPlayer,
release build and ad-hoc signature verification. It cannot establish installed
acceptance, macOS 13 behavior, real alpha-media CPU/RSS/energy, microphone and
speech permissions, audible voice quality, or private-model operation. Those
checks require a separately authorized native environment and assets. No claim
in this review represents a Linux run of macOS GUI code.
