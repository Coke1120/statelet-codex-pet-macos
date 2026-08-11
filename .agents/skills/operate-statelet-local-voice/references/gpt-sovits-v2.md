# Statelet GPT-SoVITS v2 reference

## Private asset contract

- Keep one active profile with distinct GPT weight, SoVITS weight, reference
  audio, reference transcript, prompt language, and default text language.
- Copy selected assets below Statelet Application Support with private
  permissions. Refuse symbolic links, unsafe relative paths, oversized files,
  redirects, proxies, hostnames, and non-loopback destinations.
- Treat `torch.load(..., weights_only=False)` checkpoints as executable input.
  Load only weights the user trusts and verify managed copies by SHA-256.
- Never include `.ckpt`, `.pth`, reference audio, generated WAV, dialogue JSON,
  user paths, or service configuration in source, diagnostics, app bundles, or
  releases.

## API v2 activation and synthesis

Activate both weights for every job through:

- `/set_gpt_weights?weights_path=...`
- `/set_sovits_weights?weights_path=...`

Statelet deliberately reasserts both weights before every job because
GPT-SoVITS keeps them as process-global state. Preserve that client-side
integrity boundary. In the local service, resolve each supplied absolute path
to its real path and make activation idempotent when it matches the already
active canonical path. Still load a genuinely different canonical path.
Repeatedly reloading identical weights has empirically changed or hung output
despite an otherwise deterministic request.

Send `/tts` a bounded JSON request and accept only a bounded valid PCM WAV.
Use the Statelet short-utterance recipe:

| Field | Value |
| --- | --- |
| `text_split_method` | `cut0` |
| `batch_size` | `1` |
| `streaming_mode` | `false` |
| `parallel_infer` | `false` |
| `split_bucket` | `false` |
| `fragment_interval` | `0` |
| `top_k` | `5` |
| `top_p` | `0.8` |
| `temperature` | `0.6` |
| `repetition_penalty` | `1.35` |
| `seed` | `24681` |

Keep booleans encoded as JSON booleans and numeric fields encoded as numbers;
Foundation bridges both through `NSNumber`, so tests must distinguish
`CFBoolean` from numeric values explicitly.

The seed is part of the synthesis policy. Do not omit it or use API default
`-1`: that randomizes each request, and a seed that never emits EOS can drive
the semantic loop to its token ceiling. Bump the synthesis-policy version when
changing the seed or another output-affecting request field.

Treat the reference recording, its exact prompt transcript and language, and
the seed as one empirical selection. Generate bounded candidates, reject
unexpectedly long output, and compare private ASR results with the expected
utterance without logging either text. Do not assume a reference, prompt, or
seed is neutral merely because it sounds acceptable in isolation. After
selection, keep each Statelet line to one concise utterance and send exactly one
`/tts` request; do not add automatic splitting, fragment retries, or PCM
concatenation.

The app runtime may accept a WAV up to 60 seconds as a defensive container
bound. The operational verifier intentionally rejects state-owned utterances
longer than 15 seconds because they violate the short-state speech contract.

## Timeout and service recovery

Statelet's synthesis request is bounded. A client timeout does not necessarily
stop GPT-SoVITS inference, and a blocking single-worker API may then accept TCP
while every HTTP endpoint hangs. Shortening text and increasing the timeout do
not repair an already abandoned request.

1. Stop creating Retry or profile-save requests.
2. Wait until Statelet records the active generation as failed and the profile
   as unavailable, so the queue cannot immediately refill the service.
3. Restart the managed local service with its existing LaunchAgent, for example:

   ```bash
   launchctl kickstart -k "gui/$(id -u)/com.coke1120.statelet.gpt-sovits"
   ```

   Treat the label and port as discovered defaults: substitute the inspected
   LaunchAgent label and the profile's validated numeric-loopback endpoint when
   a local installation is customized.

4. Permit startup to exceed 60 seconds while the process remains alive and
   reports loading progress; elapsed startup time alone is not permission to
   submit another synthesis request.
5. Require `http://127.0.0.1:9880/` to answer promptly before retry; HTTP 404 at
   the unused root route is sufficient health evidence.
6. Revalidate the profile and generate one deterministic short line. Confirm it
   reaches `ready` and passes WAV energy checks before filling the whole queue.

## State-owned presentation

- Persist the owning `PetState` on every dialogue line. Decode legacy missing
  state as Idle.
- Select a stable line ID when a new state presentation commits. Keep its text
  and voice bound to that entry token while validation or generation finishes.
- Cancel deferred audio before preparing a different lifecycle state. Recheck
  line ID, revision, and owning state immediately before playback.
- Never interrupt active preview or state speech. Queue only the latest ready
  state-entry request and mark delivery only when playback actually starts.
- Prefer a ready line within the requested state; otherwise keep the first
  deterministic matching line visible while its audio becomes ready.

## Output migration and cleanup

- Store a synthesis-policy version independently from the model/reference
  fingerprint. Missing legacy versions decode as version 1.
- Mark an old-policy ready line stale, queue its replacement, and keep the old
  output referenced through queued/generating states.
- If replacement fails or the profile becomes invalid, return the retained
  output to stale rather than orphaning it.
- On successful replacement, persist the new ready output and old-output
  cleanup tombstone atomically before deleting the old WAV.
- Profile replacement is different from recipe migration: drop obsolete output
  references and schedule their cleanup so they cannot collide with the new
  profile save.

## Acceptance evidence

Require all of the following:

1. Original and managed asset hashes match.
2. API listens only on numeric loopback.
3. Every required state has a ready line at the current policy version.
4. Each WAV is regular, managed, valid PCM, non-empty, measurably non-silent,
   and no longer than 15 seconds for operational short-state acceptance.
5. Rapid state changes do not play stale deferred audio.
6. Full-Xcode tests, release build, codesign, install, and installed hash pass.
7. Live Statelet shows the correct message and plays the expected state voice.

From the repository root, the normal release/install evidence is:

```bash
bash mac/CodexPetMac/scripts/build_app.sh
codesign --verify --deep --strict mac/CodexPetMac/dist/Statelet.app
bash mac/CodexPetMac/scripts/install.sh
shasum -a 256 \
  mac/CodexPetMac/dist/Statelet.app/Contents/MacOS/CodexPetMac \
  "$HOME/Applications/Statelet.app/Contents/MacOS/CodexPetMac"
```

The two executable digests must match. Full-Xcode CI remains authoritative when
the selected Command Line Tools cannot import XCTest.
