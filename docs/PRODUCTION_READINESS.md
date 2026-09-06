# Stabilization qualification — 2026-09-06

This record follows the [project review](PROJECT_REVIEW.md) and covers the
working tree based on `50491324f1d01c593b9f6ffc6795fcea4e2b1b05` (1.8.21,
build 35). It includes the pending local voice work and the stabilization fixes
below. Local stabilization checks are complete on the available host. Final
packaging and restoration are recorded below. This is candidate evidence, not
a published release or qualification for every supported platform.

## Corrected behavior

- Rejected older/conflicting publications cannot keep an expired lifecycle
  snapshot Live. The accepted revision remains the rollback barrier, and
  recovery still requires an admissible fresh publication.
- An empty or unreadable animation mapping offers a readable **Animations…**
  recovery action that opens the affected state's library. Valid poster-only
  Reduce Motion playback remains supported, and informational placeholders
  retain the normal controls at the minimum pet size.
- An unavailable-media request cancels an older standby player and its
  callbacks before returning. A superseded preload cannot replace the newer
  placeholder after resume or timeout.
- Local Python authority checks reach the terminal directory behind chained
  package symlinks and reject writable modules there.
- VoxCPM2 handles the supported local runtime, offline loading, seeds the
  supported random generators and bounds process cleanup. A profile-save error
  preserves any committed assets and blocks further editing until restart.
- Explicit regeneration retains the previous WAV through failure, cancellation,
  retry and restart, cleaning it up only after a valid replacement is saved.
  Editing the text or invalidating the profile still rejects stale results.
  The new retention marker is omitted from unaffected saved dialogue records.
- Process output readers use independently owned nonblocking descriptors and
  stop before the corresponding Foundation handles close. This fixes a
  reproduced startup abort during Codex title resolution and the equivalent
  voice/conversion cleanup race.
- Canonical hook updates and rollback exchange the component directories
  atomically. Cached hook commands retain a usable path during installation;
  newly registered commands also return harmlessly if their script or
  interpreter is unavailable.
- The performance harness resolves and checks transition media and posters
  alongside state clips when preparing its private isolated map. Successful
  standby-player promotion emits the original request's presentation timing.
- Repeated Settings sizing callbacks leave unchanged constraints alone; actual
  resize updates remain coalesced and persist when the gesture ends.

The lifecycle and preload regressions were reproduced before their fixes.
Behavioral tests cover publication ordering/expiry/recovery, real AVPlayer
supersession, recovery navigation, pointer hit testing and Reduce Motion.

## Qualification scope

The available host is Apple Silicon running macOS 26.5.1 with full Xcode.
Automated checks exercise generated media and isolated filesystem fixtures.
Live qualification uses authorized local HEVC-alpha media and the existing
VoxCPM2 setup; private models, recordings, dialogue, paths and raw logs are
excluded from this repository.

## Automated checks

The final locally built executable's SHA-256 is
`73dfe9836769bc2b3f7cb5e41530608abafc597d4e5fd47908059bf200c4e7d8`.
The final change updates the Regenerate button's help text to describe retained
audio. Its release build, normal installation and strict code-sign verification
passed. The complete installed bundle matches the build, both VoxCPM2 helpers
match their source, and both LaunchAgents are running. Raw evidence
remains private; no model, recording, dialogue or local path is included here.

| Check | Observed result |
| --- | --- |
| Swift unit suite | 482 passed after the retention fix; release build with warnings as errors |
| AVPlayer integration | 17 passed, zero skipped |
| Swift core self-test | Passed |
| Python suite | 601 tests executed, zero skipped; 599 passed in the full run and two installer fixtures timed out under load |
| Installer fixture reruns | Both passed after increasing only fixture coordination deadlines and bounding fixture cleanup; production installer code was unchanged |
| Voice checks after retention fix | 68 focused Swift tests and 31 Python voice checks passed |
| App assembly and strict code-sign verification | Passed; ad-hoc signature |
| Workflow syntax, example map and tracked-asset boundary | Passed |

The Python evidence is a full run plus two successful reruns, not a single
clean full-suite run. Fixture changes retain the actual cached-hook deadline
and all recovery/security assertions.

## Installed behavior and private data

- A normal update completed with zero missing-path observations across 1,870
  samples and zero failures in 164 calls using the old unguarded canonical
  hook command. Both provider hook configurations retained their semantics.
- The installed app stayed alive through title resolution, profile validation,
  generation, failure cleanup and a normal restart after the pipe-reader fix.
- Command-comma, Command-W and Command-Q behaved correctly. Missing-media
  recovery opened the affected animation library, and stale publication
  recovery was observed in the live UI.
- An isolated fresh application profile imported an authorized HEVC-alpha
  clip and played it over multiple loops. This was a fresh profile on the
  existing account, not a clean macOS account or an uncoached onboarding study.
- All 20 pre-existing dialogue records, all three configured provider profiles,
  playback settings and 24 baselined private audio/reference/weight files were
  preserved. The temporary test line was removed with a reversible backup;
  no original audio was removed. The large model snapshot was not independently
  hash-baselined in its entirety.
- Final handoff left the installed companion and aggregator running, Settings
  closed, all 20 original lines Ready, the active VoxCPM2 profile Ready and no
  voice helper running. The player used 71.345 MiB physical footprint at that
  observation. The installed help text and complete bundle identity were
  verified after the final rebuild.

## Performance and voice observations

The playback candidate before the final voice-retention change had SHA-256
`76527f408516df32237e315b83a9ba67724f4e7a856298df94492f5eb5cd70e4`.
Its short run used authorized local animation media,
an isolated media map, all four states and repeated transitions. It passed
every required player budget: 1.387% average CPU, 96.547 MiB peak RSS and
43.139 ms warm-switch p95 across seven warm switches. Peak physical footprint
was 26.876 MiB. A separate 60-second observation of the installed aggregator,
with process identity checked before and after sampling, passed its 0.3% CPU
budget: 0.162% average CPU and 8.594 MiB peak RSS across 61 samples.

The 900-second playback soak also passed all required player budgets: 1.408%
average CPU, 99.062 MiB peak RSS and 65.023 ms warm-switch p95 across 15 warm
switches and 891 process samples. Peak physical footprint was 27.673 MiB. RSS
had a negative measured slope over the run; this observation does not prove
the absence of every long-duration leak.

After the retention change, executable
`aac11441b2346a769c6a19b6c520c404517be28e9ef3c38f923f088e2c09ea8b`
passed a fresh 60-second
playback check: 1.382% average CPU, 95.922 MiB peak RSS and 44.802 ms warm-switch
p95 across seven warm switches. Peak physical footprint was 26.298 MiB. The
15-minute soak preceded the voice-retention change; the short run was repeated
on its rebuilt executable. The final tooltip-only package has the same
playback and generation logic; its benchmark was not repeated for that text
change.

VoxCPM2's validation and generation helpers reached approximately 13 GiB
physical footprint; saved-profile validation at app launch also loads the
model. The installed player remained below 100 MiB physical footprint, and the
large allocation disappeared when each helper exited. Temporary model memory
during infrequent generation is an accepted usage cost for this qualification; no
arbitrary memory cap or precision change was introduced.

One installed-app generation completed and produced a valid, non-silent
48 kHz mono PCM16 WAV; the UI preview started. Profile validation succeeded
after restart. However, two subsequent generation attempts reached the
600-second deadline, including a retry after other tests had finished. Both
helpers were reaped without retaining the model allocation. Successful
post-restart generation remained open until the retention candidate was
installed and checked below. These timeouts remain a known behavior on this
host; the application must preserve previous audio and reap failed jobs.

A private diagnostic using the unchanged production validator, sandbox,
runner, settings and deadline succeeded in 301.848 seconds with one inference
attempt. Imports took 2.339 seconds, model loading 138.082 seconds, prompt
encoding 6.206 seconds, inference 118.267 seconds and decoding 3.172 seconds.
Its WAV matched the first successful generation byte for byte. Peak helper
physical footprint was 12,250.757 MiB and no owned process remained afterward.
System paging was observed, but neither paging alone nor hidden model retries
is established as the cause of the earlier timeouts.

The installed retention candidate then completed regeneration after restart in
328.711 seconds of observed generation state. The old WAV remained present in
every pending sample; the new WAV became Ready before cleanup removed the old
file. The replacement again matched the initial successful WAV byte for byte,
and the installed UI accepted Preview. This establishes playback initiation
and non-silent audio geometry, not a listening assessment of speech quality.
The generation helper peaked at 12,745.930 MiB physical footprint; the player
peaked at 85.548 MiB. Saved-profile validation peaked at 13,209.914 MiB and its
helper also exited. The test line was removed afterward and its final audio
archived privately; all original records, profiles and baselined assets passed
the preservation check again.

## Release boundaries

- Local evidence does not qualify a different commit or downloaded artifact.
  Before tagging, commit the intended changes and require successful hosted CI
  on that exact commit using the [release procedure](DEPLOYMENT.md#release-verification).
- The macOS 13 deployment target still needs a real minimum-version smoke
  check. Evidence from this host is not proof for other OS versions or Intel.
- The personal-update package remains ad-hoc signed. General public binary
  distribution still requires Developer ID signing, notarization and a
  Gatekeeper check on the delivered artifact.
- Live validation of an active voice provider does not establish fresh import
  or generation compatibility for inactive providers. Preserve those profiles
  and identify their unrun checks explicitly.
- Fresh import/generation for GPT-SoVITS and Qwen, a live Grok Build turn, and
  physical sleep/wake were not run in this qualification.
- The canonical hook continuity fix does not qualify a cached command using
  the legacy CodexPet pathname during migration. Restart legacy agent clients
  around migration; do not extrapolate the canonical update result to that path.

Keep the next release focused on stabilization. The [roadmap](../ROADMAP.md)
records the remaining platform, onboarding and distribution work.
