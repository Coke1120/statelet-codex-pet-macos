# Statelet roadmap

Statelet's priority is a reliable native macOS companion that makes agent
activity understandable at a glance. The next development cycle should improve
setup, everyday reliability, and release evidence before expanding the feature
surface. This is an ordered backlog, not a promised release schedule.

See the [2026-09-05 project review](docs/PROJECT_REVIEW.md) for the evidence behind
these priorities. Each item needs a named owner when work starts; roles below
describe the responsibility rather than assigning someone else's time.

The [1.9.3 candidate](docs/PRODUCTION_READINESS.md#193-qualification--2026-10-06)
restores mandatory release checks and addresses the local Settings-layout and
crash-symbol privacy blockers found during qualification. Its release notes
record the final verification scope separately from the earlier baseline below.

The release baseline checked on 2026-10-06 is **1.9.2, build 40**, commit
`8288361c22d86d76c79f3a1f8699dd626c6b5205`. The
[release-status record](docs/PRODUCTION_READINESS.md#release-status--2026-10-06)
distinguishes 1.9.0's passing exact-commit CI from the owner-authorized CI and
updater-test waivers used for 1.9.1 and 1.9.2. Build, signing and hosted artifact
checks passed for both waived releases; 1.9.2 installed motion was not checked.
The maintained workflow now requires both test gates without a waiver.

The September stabilization checks remain historical evidence for their
recorded source and binaries. The next release needs the complete gate on its
own committed source, installed acceptance including companion transitions,
and the platform checks below.

## Next: qualify a stabilization release

| Priority | Outcome | Completion evidence | Responsible role |
| --- | --- | --- | --- |
| 1 | Qualify the current release candidate without test waivers | Run the complete release gate on the candidate commit and repeat installed acceptance, including companion transitions; retain the historical voice/private-data preservation evidence and identify provider/platform checks not performed | macOS maintainer + release owner |
| 1 | Make first-run success observable | In an isolated fresh account/profile, follow the README, configure one authorized Idle clip, confirm visible playback and a real agent turn; record setup time and blockers; provide actionable recovery for absent media or conversion tools | macOS UX maintainer |
| 1 | Make every release's verification scope explicit | Record exact commit, version/build, automated results, installed smoke results and unrun platform/voice checks; passing CI must refer to the released commit | Release owner |
| 2 | Verify everyday native behavior after Settings changes | Exercise Command-comma, Command-W, Command-Q, resize, click-through recovery, sleep/wake and agent-source switching; observe all four lifecycle states and preserved settings after relaunch | macOS maintainer |

Keep one implementation item in progress at a time, with review and verification
completed before starting another. Resolve data-loss, privacy, installation,
or incorrect lifecycle behavior ahead of cosmetic changes. Combine related
fixes into a verified release; ship urgent regressions as focused patches.

## Then: reduce maintenance and setup cost

1. **Test lifecycle orchestration through behavior.** Cover stale/equal revision
   recovery, preview cancellation and superseded callbacks through explicit
   inputs and observable effects. If necessary, extract one lifecycle
   presentation coordinator from `PetAppDelegate`; retain the current privacy,
   timing and playback contracts. Source-text assertions alone do not complete
   this item. Avoid mixing this extraction with voice-runtime changes.
2. **Validate the minimum supported platform.** Record a macOS 13 smoke result
   for the release candidate, plus architecture-specific evidence for each
   artifact offered. Keep unsupported or untested combinations explicit;
   a deployment target is not a runtime test.
3. **Establish representative performance evidence.** Run the existing
   [performance harness](docs/PERFORMANCE.md) on the exact candidate and
   authorized media, including transitions and a longer soak. Retain sanitized
   results privately and report budgets passed, failed or unmeasured. Do not
   infer real alpha-media performance from small synthetic playback fixtures.
4. **Improve onboarding based on observation.** Have a first-time user follow
   the guide without coaching. Fix the largest observed blocker before adding
   a wizard, new preferences, or more provider choices. Compare task completion
   and interventions before/after; these are manual observations, not telemetry.
5. **Reduce the cost of starting with saved voice audio.** Saved VoxCPM2 profile
   validation currently loads the full model even when only cached speech will
   play. Evaluate separating cached-audio validation from model loading while
   retaining runtime authority, source fingerprints and output checks. Measure
   startup memory and time before changing this trust boundary.

## Deferred

- **Windows and Linux:** keep [issue #4](https://github.com/Coke1120/statelet-codex-pet-macos/issues/4)
  as a future proposal. Revisit after the stabilization outcomes above, with a
  platform owner and a separate architecture/support estimate.
- **More voice providers, playlist modes, and large Settings redesigns:** first
  qualify and simplify the existing capabilities. Revisit when a documented
  user problem cannot be solved with them.
- **General public binary distribution:** treat Developer ID signing,
  notarization and Gatekeeper testing as a separate distribution project. The
  current personal-update package must keep its existing trust description.
- **Bundled character media or a media marketplace:** outside the current
  user-supplied-asset boundary. Do not add copyrighted examples to reduce setup
  friction.

## Accepting new work

Use a concrete user problem, reproduction or example, observable acceptance
criteria, compatibility impact and verification plan. The issue forms and PR
template capture these fields. A feature request is a proposal, not a delivery
commitment. Review this order after each stabilization release or when a
confirmed regression changes the priorities.
