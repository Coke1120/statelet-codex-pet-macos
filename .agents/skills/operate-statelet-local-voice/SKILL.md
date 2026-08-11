---
name: operate-statelet-local-voice
description: Configure, migrate, generate, and verify private GPT-SoVITS dialogue for Statelet. Use when importing GPT `.ckpt`, SoVITS `.pth`, or reference audio; configuring a loopback API v2 service; adding Idle, Running, Waiting, or Review state-owned messages; diagnosing silent or fragmented WAV output; validating synthesis-policy migration; or installing and testing local voice after a Statelet upgrade.
---

# Operate Statelet local voice

Keep model weights, reference recordings, dialogue text, and generated WAV files
in private local storage. Never commit, bundle, diagnose-upload, or log them.

## Workflow

1. Inspect the current checkout, installed app, voice library, and local service
   before changing anything. Recheck paths and hashes; do not trust an earlier
   run. Require GPT-SoVITS API v2 on numeric loopback HTTP only.
2. Identify the weight roles. Select one validated GPT epoch, one matching
   SoVITS weight, and one reference recording with its exact transcript and
   language. Validate the reference, prompt, and seed together with bounded
   duration and ASR checks; do not assume any reference or prompt is neutral.
   Never load unknown PyTorch checkpoints.
3. Import assets through **Settings → Voice → Voice Setup** so Statelet copies
   and fingerprints them below private Application Support. Compare SHA-256
   with the user-selected originals after import.
4. Add short messages through **Dialogue**. Assign one preferred message to
   each required lifecycle state: Idle, Running, Waiting, and Review. Keep the
   text to one concise sentence for one contiguous utterance. Preserve an
   unsaved draft while switching Voice pages or importing assets.
5. Wait for every line to reach `ready`. Automatic state speech must not
   interrupt active speech; only the latest pending state entry should play.
   Same-state heartbeats and clip rotation must not replay delivered speech.
6. Read [references/gpt-sovits-v2.md](references/gpt-sovits-v2.md) before
   changing request fields, persistence, migration, or playback behavior.
7. Run `python3 .agents/skills/operate-statelet-local-voice/scripts/verify_statelet_voice.py`
   to verify state coverage, managed paths, WAV geometry, synthesis-policy
   version, and non-silent sample energy without printing dialogue or paths.
8. Verify the installed app separately: full-Xcode CI, signed release build,
   installed-binary hash equality, live animation, message display, and audible
   state transitions. Preserve existing media and voice data during upgrades.

## Failure routing

- A WAV that plays with no audible speech: measure duration, normalized RMS,
  and quiet-sample ratio before blaming the weights. Recheck the reference
  transcript, language, selected GPT/SoVITS pair, and request recipe.
- Long gaps or missing clauses: keep `cut0` and serial inference. Shorten the
  saved message to one sentence and regenerate it as one `/tts` request. Inspect
  the exact bad WAV before proposing DSP. Do not add automatic fragmentation,
  retries with unvalidated seeds, silence trimming, or PCM concatenation without
  a separate fixture-backed change.
- Keep Statelet's per-job GPT and SoVITS activation as an integrity reassertion.
  Configure the local service to make repeated activation of the same absolute,
  canonical weight path a no-op; reloading identical weights has empirically
  changed or hung otherwise deterministic inference.
- A short sentence still reaches the request timeout and the API stops
  answering health checks: do not repeatedly Retry or merely raise the timeout.
  Confirm the request used the current deterministic seed, let Statelet mark
  the profile unavailable, restart only the managed loopback service, allow
  startup to exceed 60 seconds while it is still making progress, and do not
  retry until the numeric-loopback endpoint answers promptly. Then revalidate
  and regenerate.
- Use **Retry** only for `failed` or `stale` lines. Use **Regenerate** for a
  `ready` line whose WAV fails audible acceptance. Run the verifier with
  `--allow-pending` only for diagnosis; final acceptance must omit it.
- Speech skipped at launch: distinguish profile validation, generation, active
  playback, and state-token cancellation. Retry when the pinned line becomes
  ready; never recompute an unrelated line during snapshot refresh.
- Legacy generated output: version the synthesis policy independently from the
  input fingerprint. Retain the old WAV until replacement succeeds, then clean
  it atomically.
- `swift test` cannot import XCTest under Command Line Tools: use local builds
  and source checks for iteration, then require the repository full-Xcode CI
  before merge.

Do not claim audible success from an HTTP 200, a `ready` status, or a playable
container alone. Require non-silent audio evidence and an installed-app test.
