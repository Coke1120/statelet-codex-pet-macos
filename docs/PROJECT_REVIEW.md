# Project review — 2026-09-05

Follow-up implementation and runtime evidence are recorded in the
[stabilization qualification](PRODUCTION_READINESS.md). This review preserves
the evidence and decisions from the earlier documentation-only phase.

## Assessment

Statelet has a strong technical foundation for a personal macOS companion:
native rendering, useful multi-session lifecycle signals, private local assets,
recoverable operations, and substantial release verification. Its next priority
should be making those capabilities easier to adopt and maintain.

This is a project-management assessment of the current checkout, documentation,
tests and delivery process. It is not a new security audit, a usability study,
or certification of every runtime path. No adoption, retention, demand or
customer-satisfaction data was supplied; feature quantity and release frequency
cannot substitute for that evidence.

## Evidence snapshot

- Reviewed base: `50491324f1d01c593b9f6ffc6795fcea4e2b1b05`, version 1.8.21,
  build 35, plus the existing local working tree.
- Nine voice-related files already had uncommitted changes when this review
  began. Those changes were preserved; hosted CI for the base does not qualify
  that pending work.
- GitHub showed successful [macOS CI](https://github.com/Coke1120/statelet-codex-pet-macos/actions/runs/33672857358)
  and [signed release](https://github.com/Coke1120/statelet-codex-pet-macos/actions/runs/33672859504)
  runs for that exact base. [Release 1.8.21](https://github.com/Coke1120/statelet-codex-pet-macos/releases/tag/v1.8.21)
  had the arm64 ZIP, manifest and signature. This review inspected metadata,
  not downloaded artifact bytes or the installed bundle.
- One open issue, [Windows/Linux support #4](https://github.com/Coke1120/statelet-codex-pet-macos/issues/4),
  and no open pull requests were observed. This is a dated snapshot, not a
  measure of user demand.

## Findings and decisions

Priorities below are planning priorities, not vulnerability severity ratings.

| Priority | Finding and evidence | Decision |
| --- | --- | --- |
| 1 | First-run value depends on user-supplied media and, for MP4 conversion, an additional toolchain. The README's original first-run path only described MP4 conversion even though verified MOV import is supported. | Put setup ahead of implementation detail, explain both import paths, and define visible playback plus a real agent turn as the first success check. Observe a fresh installation before designing more onboarding UI. |
| 1 | CONTRIBUTING and the release guide used plain `swift test`, which leaves the opt-in AVPlayer integration suite skipped. CONTRIBUTING also allowed skipped Python tests while describing CI-equivalent checks. | Use one canonical complete local gate with zero-skip Python and explicitly enabled AVPlayer tests. Link contributors and the README to it. |
| 1 | Uncommitted voice work is separate from the passing released base. A completed import dialog or unit test cannot establish real generation and post-restart behavior. | Qualify that work separately before the next release; preserve configured providers and private assets. |
| 2 | Four files hold 54.7% of app-target Swift lines, and Settings/delegate files recur frequently in recent commits. | Favor a small, behavior-tested lifecycle coordinator extraction after stabilization; avoid a broad rewrite or concurrent feature expansion. |
| 2 | The macOS 13 deployment target is broader than hosted verification: CI uses `macos-14`, release packaging uses `macos-15`. The performance guide explicitly has no completed live benchmark in the repository. | Record minimum-OS, architecture and representative-media checks separately; label unrun checks rather than treating CI as proof. |
| 2 | There was no repository roadmap or structured issue/PR intake. The remaining public feature request expands platform scope substantially. | Add an ordered roadmap, problem/outcome-based feature requests, reproducible bug reports and explicit verification fields. Defer platform expansion. |
| 2 | Agent guidance prohibited all external app networking despite the implemented GitHub updater, and contained maintainer-specific absolute links. README decoder limitations also needed to distinguish ordinary playback from layered transitions. | Correct documentation to describe existing boundaries and portable navigation without changing runtime permissions or behavior. |

## Engineering strengths and limits

The app target currently contains 33 Swift files and 36,294 lines. Of those,
`PetAppDelegate` has 7,675 lines, `DialogueVoiceRuntime` 5,488,
`SettingsWindowController` 3,553 and `PetPlayer` 3,132. These counts include the
pending local changes and are a maintenance-concentration indicator, not proof
of defects. Among the last 30 commits, Settings was touched 12 times, the app
delegate seven times and the player four times.

The delegate coordinates publication acceptance/recovery, Settings callbacks
and asynchronous media imports. The 42-test
[`test_macos_lifecycle_transition_runtime.py`](../tests/test_macos_lifecycle_transition_runtime.py)
module checks source text and ordering; it does not execute that orchestration.
That is a useful contract guard but leaves room for direct behavioral coverage.

The foundation is not untested:
[`test_codex_hook.py`](../tests/test_codex_hook.py) exercises persisted permission
and Stop behavior, and [`test_codex_pet_state.py`](../tests/test_codex_pet_state.py)
exercises priority, malformed/stale records and the aggregator loop. The
[`AVPlayer integration suite`](../mac/CodexPetMac/Tests/CodexPetMacTests/PetPlayerPlaybackTests.swift)
uses a real generated movie, playback readiness and media-time progression.
Its small H.264 fixture supports playback-control confidence; it does not prove
representative HEVC-alpha appearance or resource use.

The release workflow already verifies the exact commit's CI, pinned signing
authority, manifest bindings, hosted bytes and expected asset set. Retain these
controls. The process improvement is accurate local instructions and explicit
installed acceptance evidence, not a replacement release mechanism.

## Changes made in this review

- Reordered README setup guidance, clarified import choices and corrected
  runtime/privacy descriptions.
- Aligned contributor, README and agent guidance with the canonical complete
  release verification instructions.
- Added privacy-conscious bug and feature forms and a PR verification template.
- Added an [ordered roadmap](../ROADMAP.md) with completion criteria, roles,
  dependencies and deferred scope.

Production code, existing pending voice edits, installed services and private
assets were not changed. No commit, issue publication or release was made.

## Validation and handoff

Focused hook, Grok, lifecycle-state and performance-parser suites passed
142 tests; existing CI/release-workflow policy suites passed another six:
**148 tests, zero skips**. The review also checked 32 local documentation links,
22 shell blocks and embedded Python syntax, and verified that all nine pending
voice files remained byte-identical. An independent pass verified documentation
anchors, all three issue YAML files and their form structure, and consistency
with current source and CI. These checks support this
documentation/process change; they do not qualify a new application release.
Full Python/Swift/AVPlayer suites, live UI, voice inference, installed update
acceptance and live performance measurements were not rerun here.

Use the [roadmap](../ROADMAP.md) for the next implementation decision and
[release verification](DEPLOYMENT.md#release-verification) for acceptance.
