---
name: operate-statelet-local-voice
description: Configure, migrate, generate, and verify private GPT-SoVITS, Qwen3-TTS, or VoxCPM2 dialogue for Statelet. Use when importing GPT `.ckpt`, SoVITS `.pth`, reference audio, a self-contained Qwen handover, or a complete VoxCPM2 handover; selecting a validated local Python runtime; configuring a loopback API v2 service; adding Idle, Running, Waiting, or Review state-owned messages; diagnosing silent or fragmented WAV output; validating synthesis-policy migration; or installing and testing local voice after a Statelet upgrade.
---

# Operate Statelet local voice

Keep model weights, reference recordings, dialogue text, and generated WAV files
in private local storage. Never commit, bundle, diagnose-upload, or log them.

## Workflow

1. Inspect the current checkout, installed app, voice library, configured
   providers, and required local runtime or service before changing anything.
   Recheck identities and hashes; do not trust an earlier run.
2. Choose the provider contract:
   - For GPT-SoVITS, identify one validated GPT epoch, one matching SoVITS
     weight, and one reference recording with its exact transcript and
     language. Require API v2 behind a pinned-TLS service or gateway on numeric
     loopback HTTPS. Never load unknown PyTorch checkpoints.
   - For Qwen3-TTS, require a trusted self-contained handover and a trusted
     local Python executable whose environment provides MLX Audio. The current
     Statelet profile is Japanese-only and accepts at most 500 characters per
     line. Read [references/qwen3-tts-mlx.md](references/qwen3-tts-mlx.md).
   - For VoxCPM2, require the complete source snapshot folder, one trusted
     WAV reference and exact transcript, and a trusted Python executable. The
     snapshot is copied into Statelet's private managed storage through a
     descriptor-bound staged import and fingerprinted as a complete
     regular-file tree. The bounded probe must load only that managed copy
     offline, report `mps`, `cuda`, or `cpu`, and confirm a 48 kHz model output rate. Read
     [references/voxcpm2.md](references/voxcpm2.md).
3. Import through **Settings → Voice → Voice Setup** so Statelet copies and
   fingerprints private inputs below Application Support. Select the provider
   page first. GPT-SoVITS imports three assets separately; Qwen3-TTS imports the
   handover directory and then asks for the Python executable. Compare the
   managed identities with the selected originals after import.
4. Add short messages through **Dialogue**. Assign one preferred message to
   each required lifecycle state: Idle, Running, Waiting, and Review. Keep the
   text to one concise sentence for one contiguous utterance. Preserve an
   unsaved draft while switching Voice pages or importing assets.
5. Wait for every line to reach `ready`. Automatic state speech must not
   interrupt active speech; only the latest pending state entry should play.
   Same-state heartbeats and clip rotation must not replay delivered speech.
6. Read the provider reference before changing request fields, persistence,
   migration, or playback behavior: [GPT-SoVITS v2](references/gpt-sovits-v2.md)
   or [Qwen3-TTS with MLX Audio](references/qwen3-tts-mlx.md), or
   [VoxCPM2](references/voxcpm2.md).
7. For GPT-SoVITS, run
   `python3 .agents/skills/operate-statelet-local-voice/scripts/verify_statelet_voice.py --support-root "$HOME/Library/Application Support/Statelet"`
   to verify state coverage, managed paths, WAV geometry, synthesis-policy
   version, and non-silent sample energy without printing dialogue or paths.
   This verifier does not yet accept Qwen profiles. For Qwen3-TTS, require a
   `Ready` provider, a Japanese line of 500 characters or fewer that reaches
   `Ready`, successful **Preview**, and the runtime-enforced 24 kHz mono PCM16
   WAV contract.
   For VoxCPM2, require a `Ready` provider, a Japanese line of 1,000
   characters or fewer that reaches `Ready`, successful **Preview**, and the
   runtime-enforced 48 kHz mono PCM16 WAV contract. Do not claim audible
   quality from the probe; generation remains asynchronous and MPS float32
   can be slow.
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
- Qwen import is rejected before generation: confirm the selected directory is
  the complete self-contained handover, contains no symbolic links or special
  files, remains within the package-size bound, and declares Japanese. Then
  choose the Python executable from the environment that provides MLX Audio;
  selecting an arbitrary shell or system Python is not sufficient.
- Qwen generation is rejected: keep the language set to `japanese`, shorten
  the saved line to 500 characters or fewer, and retry only after the provider
  returns to `Ready`. Do not enable downloads or replace the pinned package at
  runtime; Statelet deliberately runs Qwen with offline model-loading flags.
- VoxCPM2 import is rejected before generation: confirm that the selected
  folder contains the full snapshot (including `model.safetensors`,
  `audiovae.pth`, config, tokenizer assets, and tokenization code), contains no
  symbolic links or special files, fits the 8 GiB aggregate limit, and can be
  copied into private Application Support with adequate free space. Re-import
  the complete handover if the managed copy fails its stored tree digest or the probe
  reports an incompatible device or sample rate.
- Keep Statelet's per-job GPT and SoVITS activation as an integrity reassertion.
  Configure the local service to make repeated activation of the same absolute,
  canonical weight path a no-op; reloading identical weights has empirically
  changed or hung otherwise deterministic inference.
- A short sentence still reaches the request timeout and the API stops
  answering health checks: do not repeatedly Retry or merely raise the timeout.
  Confirm the request used the current deterministic seed, let Statelet mark
  the profile unavailable, restart only the managed loopback service, allow
  startup to exceed 60 seconds while it is still making progress, and do not
  retry until the pinned numeric-loopback HTTPS endpoint answers promptly with
  the saved leaf-certificate pin. Then revalidate and regenerate.
- Use **Retry** only for `failed` or `stale` lines. Use **Regenerate** for a
  `ready` line whose WAV fails audible acceptance. Run the verifier with
  `--allow-pending` only for diagnosis; final acceptance must omit it.
- Speech skipped at launch: distinguish profile validation, generation, active
  playback, and state-token cancellation. Retry when the pinned line becomes
  ready; never recompute an unrelated line during snapshot refresh.
- Legacy generated output: version the synthesis policy independently from the
  input fingerprint. Retain the old WAV until replacement succeeds, then clean
  it atomically.
- Provider changes: GPT-SoVITS, Qwen3-TTS, and VoxCPM2 profiles may coexist, but only one
  is active. Use the provider's **Use** button and wait for revalidation and
  regeneration before judging playback. Removing Qwen deletes Statelet's
  managed package and generated speech while preserving dialogue text and a
  separately configured GPT-SoVITS profile. VoxCPM2 removal preserves the
  selected source folder and removes Statelet's managed snapshot, reference,
  and speech.
- `swift test` cannot import XCTest under Command Line Tools: use local builds
  and source checks for iteration, then require the repository full-Xcode CI
  before merge.

Do not claim audible success from an HTTP 200, a `ready` status, or a playable
container alone. Require non-silent audio evidence and an installed-app test.
