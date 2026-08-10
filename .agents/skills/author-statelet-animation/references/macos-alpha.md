# Statelet macOS alpha reference

## Source contract

- Use an 8–10 second seamless, silent, constant-frame-rate MP4.
- Prefer 24 fps and verify the real stream metadata rather than trusting the
  requested generation settings.
- Keep the camera, framing, exposure, scale, and focus stable.
- Prefer a full subject with about 10% empty border for predictable framing.
  Statelet's relaxed importer accepts edge contact and oversized effects, but
  pixels outside the selected output canvas cannot be recovered.
- Use one completely uniform RGB `#00FF00` background with no floor, shadow,
  reflection, particles, text, logo, watermark, entrance, exit, or camera move.
- Make the first and last frames pixel-identical and minimize motion blur.

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
