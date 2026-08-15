# Statelet macOS alpha reference

## Source contract

- Use an 8–10 second seamless, silent, constant-frame-rate MP4.
- Prefer 24 fps and verify the real stream metadata rather than trusting the
  requested generation settings.
- Keep the camera, framing, exposure, scale, and focus stable.
- Prefer a full subject with about 10% empty border for predictable framing.
  Statelet's relaxed importer accepts edge contact and oversized effects, but
  pixels outside the selected output canvas cannot be recovered. After earlier
  frames establish a stable green background, a heavily occluded frame may
  reuse that reference only when its remaining border green is sufficient and
  its colour matches the attested background; every frame still passes the
  downstream alpha/composite gates.
- Use one completely uniform RGB `#00FF00` background with no floor, shadow,
  reflection, particles, text, logo, watermark, entrance, exit, or camera move.
- Make the first and last frames pixel-identical and minimize motion blur.
- One-shot transition overlays may contain fully transparent lead-in, middle,
  or lead-out frames after keying, but the complete clip must retain foreground;
  ordinary looping state animations still require foreground in every frame.

## Local toolchain

Use macOS, Python 3.9 with the repository's hash-locked NumPy and Pillow wheels,
FFmpeg/FFprobe, and Apple's `avconvert`.

Example from the repository root, using paths outside the checkout:

```bash
python3.9 -m venv "$STATELET_ALPHA_RUNTIME"
"$STATELET_ALPHA_RUNTIME/bin/python" -m pip install --require-hashes \
  -r mac/requirements-alpha.txt
"$STATELET_ALPHA_RUNTIME/bin/python" tools/convert_codex_pet_macos_alpha.py \
  "$STATELET_SOURCE" "$STATELET_OUTPUT" \
  --report "$STATELET_REPORT" \
  --intermediate-output "$STATELET_INTERMEDIATE"
```

Use task-specific absolute paths for the environment variables. Never commit
the source, output, intermediate, report, or local runtime.

## Acceptance evidence

Require the converter's final report to bind source, output, and intermediate
artifacts by SHA-256. Require every decoded frame to pass the Apple round-trip,
outer-border alpha, alpha-loss, direct edge, and white/black/checkerboard
composite gates. Inspect the complete loop visually in Statelet as a separate
final check; report that check as not run when it was not observed.

## Runtime playback acceptance

Separate asset evidence from player evidence:

1. Use FFprobe to confirm duration, frame rate, frame count, codec, and loop
   length. Decode frames at separated timestamps and prove their hashes differ.
2. Verify the active character map resolves to the expected installed movie and
   that the current lifecycle state selects that entry. For random or sequential
   playlists, preview or temporarily select the candidate directly. Treat Reduce
   Motion separately from screen-sleep or window-occlusion suspension.
3. Observe the installed Statelet across at least two complete loops. Compare
   screenshots or frames from separated timestamps and inspect player time/rate;
   a single screenshot cannot prove animation.
4. When the first decoded frame appears but time stays at zero, treat
   asynchronous `AVPlayerLooper.currentItem` population as a player race rather
   than regenerating a known-moving asset. Defer the intended resume rate until
   the current item exists, while allowing pause/stop to cancel that intent.
5. Keep a full-Xcode regression that exercises a real `AVPlayerLooper` with a
   runtime-generated multi-frame MOV. Require current-item population, nonzero
   playback rate, and advancing current time.
6. After release installation, confirm the installed executable hash equals the
   packaged `mac/CodexPetMac/dist/Statelet.app` executable before recording the
   live result. Also confirm the player LaunchAgent targets the installed app and
   the live PID began after installation.

When runtime telemetry is unavailable, record that limitation. Separated screen
captures plus differing pixels prove visible motion; they do not identify player
rate, current time, `currentItem`, or suspension state. Use the real full-Xcode
player integration test for that internal evidence rather than inferring it from
an asset-only check.
