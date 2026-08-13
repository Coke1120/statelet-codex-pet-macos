# Statelet VoxCPM2 reference

## Private handover and runtime contract

- Import the complete `VoxCPM2-Sakamata-ZeroShot-Handover` directory through
  **Settings → Voice → Voice Setup → VoxCPM2**. Do not select only
  `model.safetensors`; the model directory also needs the AudioVAE, config,
  tokenizer assets, and tokenization module.
- Choose one trusted reference WAV and enter its exact transcript. The initial
  profile passes that WAV as both `prompt_wav_path` and `reference_wav_path`.
- Choose the Python executable from the prepared environment that provides
  `voxcpm` and its PyTorch dependencies. Statelet pins its executable identity,
  the complete external tree digest, the managed reference digest, transcript,
  language, seed, CFG, timestep, and policy settings.
- Statelet copies only the reference WAV into private Application Support. It
  never commits, bundles, uploads, logs, or automatically downloads the
  snapshot, reference, transcript, dialogue, or generated WAV.

## Probe and generation

The bounded probe sets Hugging Face/Transformers/Datasets offline flags and
loads `VoxCPM.from_pretrained(... local_files_only=True,
load_denoiser=False, optimize=False, device="auto")`. It reports only `mps`,
`cuda`, or `cpu` plus the model sample rate and refuses anything other than
48 kHz. The selected runtime and snapshot code run as a child process below an
OS network-denied sandbox as well as the helper's offline flags.

Generation is asynchronous and cancellable. It uses the saved transcript as
`prompt_text`, passes the same reference WAV to both prompt/reference inputs,
and defaults to CFG 2, 10 inference timesteps, seed 1112, no denoiser, and no
optimization. The output is accepted only as a bounded 48 kHz mono PCM16 WAV;
the previous ready result remains until atomic replacement succeeds.

Apple Silicon MPS follows the upstream float32 stability path and may be slow
or memory-intensive on a MacBook Air. A `Ready` profile or playable container
does not prove natural or audible speech; use **Preview** and evaluate private
audio locally.

## Recovery and removal

- If validation becomes `Invalid`, re-import the complete unchanged handover,
  matching reference WAV/transcript, and the Python executable from its working
  environment. Do not edit the external snapshot in place.
- If validation is `Local service unavailable`, confirm the runtime can import
  `voxcpm` offline and that the bounded probe can load the model within its
  timeout. Restore the prepared environment before retrying.
- If generation times out or is cancelled, Statelet kills the contained child
  process and retains the previous ready WAV. Retry only after the profile is
  `Ready`.
- Remove the VoxCPM2 profile to delete only Statelet's managed reference and
  generated speech. The external snapshot remains untouched; dialogue text and
  other configured providers remain available. Deferred cleanup is retried.
