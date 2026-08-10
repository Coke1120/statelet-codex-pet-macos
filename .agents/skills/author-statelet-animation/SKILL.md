---
name: author-statelet-animation
description: Author, convert, and verify local animation media for Statelet, the macOS Codex Pet companion. Use when preparing a Statelet lifecycle MP4, producing HEVC-with-alpha MOV output, validating conversion reports, or importing verified media into the macOS app.
---

# Author Statelet animation

Keep the workflow local to macOS and keep source media outside the repository.
Use only media the user owns or is authorized to adapt and distribute.

## Workflow

1. Read [references/macos-alpha.md](references/macos-alpha.md) before authoring
   or converting media.
2. Confirm the source is a constant-frame-rate MP4 with one stable video stream,
   a locked camera, no audio, and a seamless loop. Safe subject margins are a
   recommendation, not a hard import gate; edge contact is accepted, while
   content outside the output canvas is necessarily cropped.
3. Use the exact uniform RGB `#00FF00` background authoring target. Do not treat
   runtime chroma keying as a supported delivery path.
4. Install the Python 3.9 dependencies from `mac/requirements-alpha.txt` with
   `--require-hashes`, and use locally installed `ffmpeg`, `ffprobe`, and Apple's
   `avconvert`.
5. Convert with the repository tool. Keep the source, MOV, retained intermediate,
   and JSON report outside the public checkout.
6. Accept a delivery only when the tool completes its Apple round-trip and the
   report says verification was performed, `unsafe` is false, all frames were
   checked, alpha was retained, composite gates passed, and artifact hashes match.
7. Import the verified MOV together with its sibling `.report.json` through
   Statelet Settings. Do not hand-edit the report or claim visual success from an
   encode exit code alone.

Use default quality thresholds unless a repository change explicitly updates
the contract and tests. Never weaken a gate merely to make a candidate pass.

Preserve the stable Codex Pet bundle identifier, executable, Application Support
directory, preference keys, and LaunchAgent labels; they remain intentionally
unchanged for Statelet upgrade compatibility.
