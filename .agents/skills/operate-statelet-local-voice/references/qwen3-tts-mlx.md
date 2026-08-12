# Statelet Qwen3-TTS with MLX Audio reference

## Private package and runtime contract

- Import only a trusted, self-contained Qwen3-TTS handover directory through
  **Settings → Voice → Voice Setup → Qwen3-TTS**.
- The handover must contain its local model, configuration, generation entry
  point, and referenced audio. Statelet refuses symbolic links, special files,
  missing required inputs, packages larger than 4 GiB, and configurations that
  do not declare Japanese.
- Statelet copies the complete directory into private managed storage, applies
  owner-only permissions, and binds the package tree and required files with
  SHA-256 identities. The source directory remains outside Statelet's control.
- After selecting the handover, select the Python executable from the trusted
  environment that provides MLX Audio. Statelet pins the launcher and resolved
  interpreter identity, then runs a dependency probe before marking the
  provider ready.
- Select the virtual environment launcher itself, even when it is a symbolic
  link. Resolving it to the bare interpreter can lose that environment's
  site-packages and make a working MLX runtime appear unavailable. Statelet's
  picker preserves the launcher while validation pins both identities.
- Never commit, bundle, upload, diagnose-log, or publish the handover, model,
  reference recording, reference transcript, dialogue, generated WAV, or local
  runtime path.

## Provider selection and generation

1. Open **Settings → Voice → Voice Setup** and select **Qwen3-TTS**.
2. Choose **Import Qwen Handover…**, select the trusted directory, then select
   the Python executable from its validated local MLX Audio environment when
   prompted.
3. Wait for the Qwen provider status to become `Ready`. Import performs a
   private managed copy, package validation, runtime identity validation, and
   the dependency probe before queued generation begins.
4. If GPT-SoVITS is currently active, choose **Use Qwen3-TTS**. Both profiles
   remain configured, but only the selected provider generates and plays new
   output. Switching providers invalidates incompatible generated output and
   queues replacement speech.
5. In **Dialogue**, use the language identifier `japanese` and keep each line
   to 500 characters or fewer. Prefer one concise sentence for state speech.
6. Wait for the line to reach `Ready`, choose **Preview**, and confirm audible
   speech before enabling or judging automatic lifecycle playback.

Statelet sends the request to a bundled local helper over private standard
input. It forces offline model-loading flags, disables user-site packages and
bytecode writes, and gives the process a private temporary home. The helper
loads only the imported local package; it must not download or substitute a
model. Generation is bounded by a 120-second process timeout. Swift owns the
child process group; each helper verifies that containment, and the dependency
probe waits for the parent to close standard input before importing MLX. Do not
add `setsid()` inside either helper or accept a fast-exited child before group
ownership is observed, because both changes break the containment handshake.

## Output acceptance

Qwen output is accepted only when it is a bounded, structurally valid WAV with
all of these properties:

| Property | Required value |
| --- | --- |
| Encoding | Linear PCM |
| Sample rate | 24 kHz |
| Channels | Mono |
| Sample width | 16 bit |
| Maximum duration | 60 seconds |
| Maximum file size | 64 MiB |

The runtime validates the container before atomically publishing it for
**Preview**. A `Ready` line proves that the package, runtime, request, and WAV
structure passed their software checks. It does not prove that the speech is
audible or correct. Listen to the preview and inspect private audio-energy or
ASR results when acceptance requires them; never include the audio or text in
public diagnostics.

## Failure and recovery

- `Invalid` after import: reselect the complete original handover and the exact
  Python executable from its working MLX Audio environment. Do not select a
  shell, a generic system Python, or an environment that has not generated a
  local smoke sample successfully.
- `Local service unavailable` with a working runtime: confirm the stored path
  is the virtual environment launcher rather than its resolved bare
  interpreter. Then run the bundled silent dependency probe with that launcher
  under the same offline environment; it must exit zero with empty stdout and
  stderr after the process-group stdin handshake.
- Rejected dialogue: set the language to `japanese` and shorten the line to 500
  characters or fewer, then use **Retry**.
- Package or runtime identity changed: treat the saved profile as invalid and
  re-import it. Do not edit the managed package or replace the selected Python
  executable in place.
- `Ready` but silent or wrong speech: preserve the exact private WAV, measure
  its energy, and compare a private ASR result with the expected line. Do not
  infer audible success from a valid container or successful playback call.
- Interrupted generation: let Statelet recover or mark the line failed, then
  use **Retry**. A late process result must not replace a newer line revision or
  a generation started after a provider switch.

## Removal and coexistence

Use **Remove Qwen Profile…** only after confirming the active provider and any
speech you still need. Statelet removes its managed Qwen package and generated
speech. It keeps dialogue text and any separately configured GPT-SoVITS
profile. If GPT-SoVITS remains configured, Statelet selects and revalidates it;
otherwise dialogue remains as drafts until another provider is configured.

After removal, confirm that the Qwen page reports `Not configured`, the
remaining provider behaves as expected, and dialogue text is still present.
Statelet performs managed directory deletion without following symbolic links;
deferred cleanup is reported and retried rather than silently treated as
success.
