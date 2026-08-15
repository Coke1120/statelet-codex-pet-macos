#!/usr/bin/env python3
"""Convert a green-screen MP4 into a verified macOS HEVC-alpha movie.

The source is decoded and keyed only during this offline command.  Frames are
converted to straight RGBA, checked, streamed to a ProRes 4444 intermediate,
and then encoded by Apple's ``avconvert`` using an alpha-capable HEVC preset.
By default the resulting HEVC movie is *proved* by a second Apple conversion
back to ``PresetAppleProRes4444LPCM`` followed by an independent RGBA decode
and all-frame alpha comparison.  A direct ffmpeg HEVC ``alphaextract`` is not
used as acceptance evidence because Apple's auxiliary alpha-track contract is
not reliably represented by ffprobe's normal pixel format fields.

The script is intentionally path-private: execution commands retain real
paths internally, but dry-run output, JSON reports, and user-facing failures
contain basenames only.  Final artifacts are written through temporary files,
and existing outputs are never replaced unless ``--replace`` is explicit.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import math
import os
import re
import selectors
import secrets
import signal
import shutil
import stat
import statistics
import subprocess
import sys
import tempfile
import time
import warnings
from pathlib import Path
from typing import Any, Iterable, TextIO


def _ensure_owned_process_group() -> None:
    """Own the conversion process group, accepting an existing owned group."""

    if os.getpgrp() == os.getpid():
        return
    try:
        os.setpgid(0, 0)
    except OSError:
        # Launchers may establish the child's group concurrently. Treat that
        # race as success only when this process is now the group leader.
        if os.getpgrp() != os.getpid():
            raise


if __name__ == "__main__":
    try:
        # The macOS app cancels this owned group so ffmpeg/avconvert descendants
        # cannot outlive the conversion coordinator.
        _ensure_owned_process_group()
    except OSError:
        print("error: conversion process group could not be created", file=sys.stderr)
        raise SystemExit(2)

    def _cancel_conversion(_signum: int, _frame: Any) -> None:
        os.write(2, b"error: conversion cancelled\n")
        raise SystemExit(2)

    signal.signal(signal.SIGTERM, _cancel_conversion)

try:  # Script execution from repository root: ``python tools/...``.
    import codex_pet_alpha as alpha_engine
    from codex_pet_alpha import (
        AlphaConversionError,
        DEFAULT_ALPHA_LOSS_THRESHOLD,
        DEFAULT_ALPHA_MAX_ABS_ERROR,
        DEFAULT_ALPHA_MEAN_ABS_ERROR,
        DEFAULT_ALPHA_P95_ABS_ERROR,
        DEFAULT_DELIVERY_EDGE_ALPHA_FLOOR,
        DEFAULT_FRINGE_CHANNEL_EXCESS,
        DEFAULT_MAX_INTRODUCED_GREEN_FRINGE_EXCESS,
        DEFAULT_MAX_INTRODUCED_MAGENTA_FRINGE_EXCESS,
        DEFAULT_MAX_GREEN_FRINGE_RATIO,
        DEFAULT_MAX_MAGENTA_FRINGE_RATIO,
        DEFAULT_MAX_BORDER_ALPHA,
        DEFAULT_MAX_UNSUPPORTED_GREEN_EDGE_EXCESS,
        DEFAULT_MAX_UNSUPPORTED_MAGENTA_EDGE_EXCESS,
        DEFAULT_MAX_DELIVERY_EDGE_RATIO,
        DEFAULT_MAX_SOURCE_EDGE_RATIO,
        DEFAULT_SOURCE_EDGE_ALPHA_FLOOR,
        SOURCE_RESIZE_MODE,
        assess_green_background,
        FrameQualityError,
        VideoInfo,
        build_avconvert_command,
        build_ffmpeg_decode_command,
        build_ffmpeg_prores_command,
        build_ffmpeg_rgba_decode_command,
        close_process,
        compare_alpha_planes,
        composite_quality,
        frame_quality,
        matte_frame,
        probe_video,
        read_raw_frames,
        require_image_dependencies,
        require_tool,
        sanitize_command,
        sanitize_text,
        sanitize_value,
        verify_video_cadence,
    )
except ImportError:  # Module import as ``tools.convert_codex_pet_macos_alpha``.
    from tools import codex_pet_alpha as alpha_engine
    from tools.codex_pet_alpha import (  # type: ignore[no-redef]
        AlphaConversionError,
        DEFAULT_ALPHA_LOSS_THRESHOLD,
        DEFAULT_ALPHA_MAX_ABS_ERROR,
        DEFAULT_ALPHA_MEAN_ABS_ERROR,
        DEFAULT_ALPHA_P95_ABS_ERROR,
        DEFAULT_DELIVERY_EDGE_ALPHA_FLOOR,
        DEFAULT_FRINGE_CHANNEL_EXCESS,
        DEFAULT_MAX_INTRODUCED_GREEN_FRINGE_EXCESS,
        DEFAULT_MAX_INTRODUCED_MAGENTA_FRINGE_EXCESS,
        DEFAULT_MAX_GREEN_FRINGE_RATIO,
        DEFAULT_MAX_MAGENTA_FRINGE_RATIO,
        DEFAULT_MAX_BORDER_ALPHA,
        DEFAULT_MAX_UNSUPPORTED_GREEN_EDGE_EXCESS,
        DEFAULT_MAX_UNSUPPORTED_MAGENTA_EDGE_EXCESS,
        DEFAULT_MAX_DELIVERY_EDGE_RATIO,
        DEFAULT_MAX_SOURCE_EDGE_RATIO,
        DEFAULT_SOURCE_EDGE_ALPHA_FLOOR,
        SOURCE_RESIZE_MODE,
        assess_green_background,
        FrameQualityError,
        VideoInfo,
        build_avconvert_command,
        build_ffmpeg_decode_command,
        build_ffmpeg_prores_command,
        build_ffmpeg_rgba_decode_command,
        close_process,
        compare_alpha_planes,
        composite_quality,
        frame_quality,
        matte_frame,
        probe_video,
        read_raw_frames,
        require_image_dependencies,
        require_tool,
        sanitize_command,
        sanitize_text,
        sanitize_value,
        verify_video_cadence,
    )


DEFAULT_PRESET = "PresetHEVCHighestQualityWithAlpha"
ROUNDTRIP_PRESET = "PresetAppleProRes4444LPCM"
REPORT_SCHEMA_VERSION = 1
DEFAULT_PROCESS_TIMEOUT_SECONDS = 900.0
DEFAULT_MAX_SOURCE_BYTES = 2 * 1024 * 1024 * 1024
DEFAULT_MAX_SOURCE_PIXELS = 3840 * 2160
DEFAULT_MAX_SOURCE_FRAMES = 14_400
DEFAULT_MAX_SOURCE_DURATION_SECONDS = 600.0
DEFAULT_MAX_SOURCE_FPS = 120.0
DEFAULT_MIN_FREE_DISK_BYTES = 512 * 1024 * 1024
PRORES_PEAK_BYTES_PER_PIXEL = 8
HEVC_PEAK_BYTES_PER_PIXEL = 4
ALPHA_REFERENCE_BYTES_PER_PIXEL = 1
REPORT_STAGE_RESERVE_BYTES = 1024 * 1024
DISK_ALLOCATION_SAFETY_NUMERATOR = 5
DISK_ALLOCATION_SAFETY_DENOMINATOR = 4
DISK_ARTIFACT_FIXED_OVERHEAD_BYTES = 64 * 1024


def _align_hevc_alpha_geometry(width: int, height: int) -> tuple[int, int]:
    """Floor each canvas dimension to the even geometry Apple preserves.

    ``avconvert`` silently removes the final row or column from odd-sized
    ProRes inputs when producing HEVC with alpha.  Aligning before matting
    keeps the reference alpha, intermediate, delivery, and report bound to
    one exact geometry instead of weakening the post-encode verification.
    """

    if width < 4 or height < 4:
        raise AlphaConversionError(
            "HEVC alpha output dimensions must be at least 4 pixels"
        )
    return width - (width % 2), height - (height % 2)


def _fit_content_bounds(
    info: VideoInfo, *, width: int, height: int
) -> tuple[int, int, int, int]:
    """Return the actual source rectangle inside deterministic Fit padding."""

    scale = min(width / info.width, height / info.height)
    content_width = max(1, min(width, round(info.width * scale)))
    content_height = max(1, min(height, round(info.height * scale)))
    left = (width - content_width) // 2
    top = (height - content_height) // 2
    return left, top, left + content_width, top + content_height


def _source_audio_report(info: VideoInfo) -> dict[str, Any]:
    """Describe the intentional silent-delivery policy without rejecting input."""

    return {
        "stream_count": len(info.audio_codecs),
        "codecs": list(info.audio_codecs),
        "policy": "stripped" if info.audio_codecs else "none",
    }


def _preflight_resources(
    source: Path,
    output_target: Path,
    report_target: Path,
    intermediate_target: Path | None,
    info: VideoInfo,
    *,
    width: int,
    height: int,
    max_source_bytes: int,
    max_source_pixels: int,
    max_source_frames: int,
    max_source_duration_seconds: float,
    max_source_fps: float,
    min_free_disk_bytes: int,
) -> dict[str, Any]:
    """Reject unbounded work before starting any decoder or encoder."""

    source_bytes = _preflight_source_size(
        source, max_source_bytes=max_source_bytes
    )
    if info.width * info.height > max_source_pixels:
        raise AlphaConversionError("source video exceeds the configured pixel budget")
    if info.frame_count > max_source_frames:
        raise AlphaConversionError("source video exceeds the configured frame budget")
    if info.duration_seconds > max_source_duration_seconds:
        raise AlphaConversionError("source video exceeds the configured duration budget")
    if float(info.fps) > max_source_fps:
        raise AlphaConversionError("source video exceeds the configured frame-rate budget")

    disk_peak = _check_peak_disk_capacity(
        output_target,
        report_target,
        intermediate_target,
        info=info,
        width=width,
        height=height,
        reserve_bytes=min_free_disk_bytes,
    )
    return {
        "source_bytes": source_bytes,
        "disk_peak": disk_peak,
        "limits": {
            "max_source_bytes": max_source_bytes,
            "max_source_pixels": max_source_pixels,
            "max_source_frames": max_source_frames,
            "max_source_duration_seconds": max_source_duration_seconds,
            "max_source_fps": max_source_fps,
            "min_free_disk_bytes": min_free_disk_bytes,
        },
        "passed": True,
    }


def _check_peak_disk_capacity(
    output_target: Path,
    report_target: Path,
    intermediate_target: Path | None,
    *,
    info: VideoInfo,
    width: int,
    height: int,
    reserve_bytes: int,
) -> dict[str, Any]:
    """Aggregate conservative simultaneous allocation peaks by filesystem."""

    pixels = info.frame_count * width * height
    temp_bytes = sum(
        _allocation_with_overhead(payload_bytes)
        for payload_bytes in (
            pixels * PRORES_PEAK_BYTES_PER_PIXEL,
            pixels * HEVC_PEAK_BYTES_PER_PIXEL,
            pixels * ALPHA_REFERENCE_BYTES_PER_PIXEL,
            pixels * PRORES_PEAK_BYTES_PER_PIXEL,
            info.frame_count * 3,
        )
    )
    allocations: list[tuple[str, Path, int]] = [
        ("conversion-temp", Path(tempfile.gettempdir()), temp_bytes),
        (
            "delivery-stage",
            output_target.parent,
            _allocation_with_overhead(pixels * HEVC_PEAK_BYTES_PER_PIXEL),
        ),
        (
            "report-stage",
            report_target.parent,
            _allocation_with_overhead(REPORT_STAGE_RESERVE_BYTES),
        ),
    ]
    if intermediate_target is not None:
        allocations.append(
            (
                "intermediate-stage",
                intermediate_target.parent,
                _allocation_with_overhead(
                    pixels * PRORES_PEAK_BYTES_PER_PIXEL
                ),
            )
        )
    return _check_disk_allocations(
        allocations,
        reserve_bytes=reserve_bytes,
        model="simultaneous-alpha-pipeline-v1",
    )


def _allocation_with_overhead(payload_bytes: int) -> int:
    """Allow codec/container growth, allocation rounding, and file metadata."""

    scaled = (
        int(payload_bytes) * DISK_ALLOCATION_SAFETY_NUMERATOR
        + DISK_ALLOCATION_SAFETY_DENOMINATOR
        - 1
    ) // DISK_ALLOCATION_SAFETY_DENOMINATOR
    return scaled + DISK_ARTIFACT_FIXED_OVERHEAD_BYTES


def _check_publication_disk_capacity(
    output_stage: Path,
    output_target: Path,
    intermediate_stage: Path | None,
    intermediate_target: Path | None,
    report_target: Path,
    report_payload: dict[str, Any],
    *,
    reserve_bytes: int,
) -> dict[str, Any]:
    """Check only allocations still needed from the current publication point."""

    try:
        output_bytes = output_stage.stat().st_size
        if output_bytes <= 0:
            raise OSError("empty output stage")
        report_bytes = len(
            (
                json.dumps(
                    _safe_report_value(report_payload), indent=2, sort_keys=True
                )
                + "\n"
            ).encode("utf-8")
        )
        allocations: list[tuple[str, Path, int]] = [
            (
                "delivery-stage",
                output_target.parent,
                _allocation_with_overhead(output_bytes),
            ),
            (
                "report-stage",
                report_target.parent,
                _allocation_with_overhead(report_bytes),
            ),
        ]
        if intermediate_stage is not None:
            if intermediate_target is None:
                raise OSError("intermediate target missing")
            intermediate_bytes = intermediate_stage.stat().st_size
            if intermediate_bytes <= 0:
                raise OSError("empty intermediate stage")
            allocations.append(
                (
                    "intermediate-stage",
                    intermediate_target.parent,
                    _allocation_with_overhead(intermediate_bytes),
                )
            )
    except (OSError, TypeError, ValueError) as exc:
        raise AlphaConversionError(
            "unable to estimate remaining publication disk space"
        ) from exc
    return _check_disk_allocations(
        allocations,
        reserve_bytes=reserve_bytes,
        model="publication-remaining-v1",
    )


def _check_disk_allocations(
    allocations: list[tuple[str, Path, int]],
    *,
    reserve_bytes: int,
    model: str,
) -> dict[str, Any]:
    """Aggregate path-private allocation requirements by filesystem device."""

    by_device: dict[int, dict[str, Any]] = {}
    try:
        for label, location, required in allocations:
            device = int(os.stat(location).st_dev)
            item = by_device.setdefault(
                device,
                {
                    "location": location,
                    "required_bytes": int(reserve_bytes),
                    "components": [],
                },
            )
            item["required_bytes"] += int(required)
            item["components"].append(label)
    except OSError as exc:
        raise AlphaConversionError("unable to inspect available disk space") from exc

    summaries: list[dict[str, Any]] = []
    for index, (_device, item) in enumerate(sorted(by_device.items()), start=1):
        try:
            free_bytes = int(shutil.disk_usage(item["location"]).free)
        except OSError as exc:
            raise AlphaConversionError("unable to inspect available disk space") from exc
        required_bytes = int(item["required_bytes"])
        if free_bytes < required_bytes:
            raise AlphaConversionError("insufficient free disk space for conversion")
        summaries.append(
            {
                "label": f"volume-{index}",
                "required_bytes": required_bytes,
                "free_bytes_at_check": free_bytes,
                "components": sorted(item["components"]),
            }
        )
    return {
        "model": model,
        "volume_count": len(summaries),
        "total_required_bytes": sum(item["required_bytes"] for item in summaries),
        "maximum_volume_required_bytes": max(
            (item["required_bytes"] for item in summaries), default=0
        ),
        "volumes": summaries,
    }


def _preflight_source_size(source: Path, *, max_source_bytes: int) -> int:
    """Apply the cheapest source budget before hashing or all-frame probing."""

    try:
        source_bytes = source.stat().st_size
    except OSError as exc:
        raise AlphaConversionError("unable to inspect source resource usage") from exc
    if source_bytes > max_source_bytes:
        raise AlphaConversionError("source video exceeds the configured size budget")
    return source_bytes


def _bounded_tool_output(
    executable: str,
    arguments: tuple[str, ...],
    *,
    cache: dict[tuple[str, tuple[str, ...]], str],
    timeout_seconds: float = 10.0,
) -> str:
    key = (executable, arguments)
    if key in cache:
        return cache[key]
    try:
        result = alpha_engine._run_bounded_capture(
            [executable, *arguments],
            timeout_seconds=timeout_seconds,
            stdout_limit=1024 * 1024,
            stderr_limit=1024 * 1024,
            overflow_message="conversion tool capability output is too large",
            timeout_message="conversion tool capability check timed out",
            total_limit=1024 * 1024,
        )
    except (OSError, alpha_engine.ProbeError) as exc:
        raise AlphaConversionError("unable to inspect conversion tool capabilities") from exc
    text = result.stdout + result.stderr
    if result.returncode != 0 and not text.strip():
        raise AlphaConversionError("conversion tool capability check failed")
    cache[key] = text
    return text


def _safe_tool_version(output: str) -> str:
    first = next((line.strip() for line in output.splitlines() if line.strip()), "unknown")
    safe = sanitize_text(first).replace("/", "-").replace("\\", "-")
    safe = "".join(character for character in safe if character.isprintable())
    return safe[:256] or "unknown"


def _converter_fingerprint() -> str:
    engine_path = Path(alpha_engine.__file__ or "")
    if not engine_path.is_file():
        raise AlphaConversionError("converter engine fingerprint is unavailable")
    component_hashes = (
        _sha256_file(Path(__file__)),
        _sha256_file(engine_path),
    )
    return hashlib.sha256(":".join(component_hashes).encode("ascii")).hexdigest()


def _preflight_tool_capabilities(
    *, ffmpeg: str, ffprobe: str, avconvert: str
) -> dict[str, Any]:
    """Require the exact local encoder/filter/preset surface before source work."""

    cache: dict[tuple[str, tuple[str, ...]], str] = {}
    encoders = _bounded_tool_output(
        ffmpeg, ("-hide_banner", "-encoders"), cache=cache
    )
    if not re.search(r"\bprores_ks\b", encoders):
        raise AlphaConversionError("ffmpeg does not provide the required prores_ks encoder")
    filters = _bounded_tool_output(
        ffmpeg, ("-hide_banner", "-filters"), cache=cache
    )
    for name in ("scale", "crop", "pad"):
        if not re.search(rf"(?m)^\s*\.{{2,3}}\s+{name}\s", filters):
            raise AlphaConversionError(f"ffmpeg does not provide the required {name} filter")
    full_help = _bounded_tool_output(
        ffmpeg, ("-hide_banner", "-h", "full"), cache=cache
    )
    if re.search(r"(?m)^\s*-fps_mode(?:\[|:|\s)", full_help):
        frame_sync_mode = "fps_mode"
    elif re.search(r"(?m)^\s*-vsync(?:\s|$)", full_help):
        frame_sync_mode = "vsync"
    else:
        raise AlphaConversionError(
            "ffmpeg does not provide a supported frame synchronization mode"
        )
    avconvert_help = _bounded_tool_output(avconvert, ("--help",), cache=cache)
    for preset in (DEFAULT_PRESET, ROUNDTRIP_PRESET):
        if preset not in avconvert_help:
            raise AlphaConversionError(
                f"avconvert does not provide the required {preset} preset"
            )
    ffmpeg_version = _bounded_tool_output(ffmpeg, ("-version",), cache=cache)
    ffprobe_version = _bounded_tool_output(ffprobe, ("-version",), cache=cache)
    macos_build_output = _bounded_tool_output(
        "/usr/bin/sw_vers", ("-buildVersion",), cache=cache
    )
    converter_sha256 = _converter_fingerprint()
    avconvert_path = Path(avconvert)
    avconvert_sha256 = (
        _sha256_file(avconvert_path) if avconvert_path.is_file() else "unavailable"
    )
    return {
        "toolchain": {
            "converter_version": f"sha256-{converter_sha256}",
            "ffmpeg_version": _safe_tool_version(ffmpeg_version),
            "ffprobe_version": _safe_tool_version(ffprobe_version),
            "avconvert_version": f"sha256-{avconvert_sha256}",
            "macos_build": _safe_tool_version(macos_build_output),
        },
        "capabilities": {
            "ffmpeg_encoder": "prores_ks",
            "ffmpeg_filters": ["scale", "crop", "pad"],
            "ffmpeg_frame_sync": frame_sync_mode,
            "avconvert_presets": [DEFAULT_PRESET, ROUNDTRIP_PRESET],
            "passed": True,
        },
    }


def _report_contract(
    args: argparse.Namespace,
    *,
    tool_preflight: dict[str, Any],
) -> dict[str, Any]:

    contract: dict[str, Any] = {
        "report_schema_version": REPORT_SCHEMA_VERSION,
        "toolchain": tool_preflight["toolchain"],
        "tool_capabilities": tool_preflight["capabilities"],
        "profile": {
            "name": args.profile,
            "framing": args.resize_mode,
            "keying": "green-screen-continuous-alpha",
        },
        "normalization": {
            "applied": ["strip-audio", "square-pixel-output"],
            "warnings": [
                "rotation-sar-vfr-hdr-interlace-rejected-before-decode",
                "high-bit-depth-and-wide-gamut-rejected-before-decode",
            ],
        },
    }
    contract["provenance"] = {
        "method": "invocation-challenge-v1",
        "producer": "statelet",
        "challenge": args.invocation_challenge or secrets.token_hex(32),
    }
    return contract


def _loop_seam_diagnostics(first_rgba: Any, last_rgba: Any) -> dict[str, Any]:
    """Measure the authored loop seam without turning it into a codec gate."""

    numpy = _numpy_for_loop_seam()
    if first_rgba.shape != last_rgba.shape:
        raise AlphaConversionError("loop seam frames have different geometry")
    difference = numpy.abs(
        first_rgba.astype(numpy.int16) - last_rgba.astype(numpy.int16)
    )
    differing_pixels = int(numpy.count_nonzero(numpy.any(difference != 0, axis=2)))
    return {
        "performed": True,
        "exact_match": differing_pixels == 0,
        "differing_pixels": differing_pixels,
        "mean_absolute_error": float(difference.mean()),
        "maximum_absolute_error": int(difference.max()),
        "policy": "informational",
    }


def _numpy_for_loop_seam() -> Any:
    """Return NumPy after the normal dependency guard has run."""

    require_image_dependencies()
    # Keep NumPy optional at module import time so error-path tests still run on
    # minimal hosts.  The normal dependency guard above makes this lazy import
    # safe for both package imports and direct ``python tools/...`` execution.
    import numpy as numpy

    return numpy


def _positive_int(value: str) -> int:
    try:
        result = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a positive integer") from exc
    if result <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return result


def _byte_int(value: str) -> int:
    try:
        result = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be an integer from zero to 255") from exc
    if not 0 <= result <= 255:
        raise argparse.ArgumentTypeError("must be an integer from zero to 255")
    return result


def _nonnegative_float(value: str) -> float:
    try:
        result = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a non-negative number") from exc
    if not math.isfinite(result) or result < 0:
        raise argparse.ArgumentTypeError("must be a non-negative number")
    return result


def _unit_float(value: str) -> float:
    try:
        result = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be between zero and one") from exc
    if not 0.0 <= result <= 1.0:
        raise argparse.ArgumentTypeError("must be between zero and one")
    return result


def _challenge(value: str) -> str:
    if not re.fullmatch(r"[0-9a-f]{64}", value):
        raise argparse.ArgumentTypeError("must be exactly 64 lowercase hex characters")
    return value


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Offline matte an AI-generated green-screen MP4 and encode "
            "transparent HEVC for the macOS pet player. Alpha verification "
            "is mandatory for every published delivery."
        )
    )
    parser.add_argument("source", type=Path, help="source constant-frame-rate MP4")
    parser.add_argument("output", type=Path, help="HEVC-with-alpha .mov output")
    parser.add_argument(
        "--report",
        type=Path,
        help="JSON report path (default: output filename with .report.json)",
    )
    parser.add_argument(
        "--intermediate-output",
        type=Path,
        help="retain the ProRes 4444 intermediate at this path",
    )
    parser.add_argument(
        "--keep-intermediate",
        action="store_true",
        help="retain a sibling .prores4444.mov intermediate",
    )
    parser.add_argument("--ffmpeg", default="ffmpeg", help="ffmpeg executable")
    parser.add_argument("--ffprobe", default="ffprobe", help="ffprobe executable")
    parser.add_argument("--avconvert", default="avconvert", help="avconvert executable")
    parser.add_argument(
        "--preset",
        default=DEFAULT_PRESET,
        help=f"delivery avconvert preset (default: {DEFAULT_PRESET})",
    )
    parser.add_argument(
        "--profile",
        choices=("standard",),
        default="standard",
        help="named source preparation profile; strict delivery verification is unchanged",
    )
    parser.add_argument(
        "--resize-mode",
        choices=("fill", "fit"),
        default="fill",
        help="fill crops to canvas; fit pads with the supported green background",
    )
    parser.add_argument(
        "--invocation-challenge",
        type=_challenge,
        help=argparse.SUPPRESS,
    )
    parser.add_argument(
        "--process-timeout-seconds",
        type=_nonnegative_float,
        default=DEFAULT_PROCESS_TIMEOUT_SECONDS,
        help="absolute deadline for each external conversion stage",
    )
    parser.add_argument(
        "--max-source-bytes",
        type=_positive_int,
        default=DEFAULT_MAX_SOURCE_BYTES,
        help="maximum accepted source file size",
    )
    parser.add_argument(
        "--max-source-pixels",
        type=_positive_int,
        default=DEFAULT_MAX_SOURCE_PIXELS,
    )
    parser.add_argument(
        "--max-source-frames",
        type=_positive_int,
        default=DEFAULT_MAX_SOURCE_FRAMES,
    )
    parser.add_argument(
        "--max-source-duration-seconds",
        type=_nonnegative_float,
        default=DEFAULT_MAX_SOURCE_DURATION_SECONDS,
    )
    parser.add_argument(
        "--max-source-fps",
        type=_nonnegative_float,
        default=DEFAULT_MAX_SOURCE_FPS,
    )
    parser.add_argument(
        "--min-free-disk-bytes",
        type=_positive_int,
        default=DEFAULT_MIN_FREE_DISK_BYTES,
        help="minimum free space required on temporary and output volumes",
    )
    parser.add_argument("--width", type=_positive_int, help="optional output width")
    parser.add_argument("--height", type=_positive_int, help="optional output height")
    parser.add_argument(
        "--border-width",
        type=_positive_int,
        default=1,
        help="border width used for dynamic background estimation (default: 1)",
    )
    parser.add_argument(
        "--key-floor",
        type=_unit_float,
        default=0.06,
        help="green-excess ratio treated as opaque foreground (default: 0.06)",
    )
    parser.add_argument(
        "--key-ceiling",
        type=_nonnegative_float,
        default=0.94,
        help="green-excess ratio treated as transparent background (default: 0.94)",
    )
    parser.add_argument(
        "--despill-strength",
        type=_unit_float,
        default=0.80,
        help="green-spill suppression strength (default: 0.80)",
    )
    parser.add_argument(
        "--despill-allowance",
        type=_nonnegative_float,
        default=2.0,
        help="green excess retained in foreground RGB (default: 2)",
    )
    parser.add_argument(
        "--max-green-edge-ratio",
        type=_unit_float,
        default=DEFAULT_MAX_SOURCE_EDGE_RATIO,
        help=(
            "maximum source-matte unsupported green edge ratio "
            f"(default: {DEFAULT_MAX_SOURCE_EDGE_RATIO:g})"
        ),
    )
    parser.add_argument(
        "--max-magenta-edge-ratio",
        type=_unit_float,
        default=DEFAULT_MAX_SOURCE_EDGE_RATIO,
        help=(
            "maximum source-matte unsupported magenta edge ratio "
            f"(default: {DEFAULT_MAX_SOURCE_EDGE_RATIO:g})"
        ),
    )
    parser.add_argument(
        "--source-edge-alpha-floor",
        type=_byte_int,
        default=DEFAULT_SOURCE_EDGE_ALPHA_FLOOR,
        help=(
            "minimum alpha for meaningful source-edge colour gates "
            f"(default: {DEFAULT_SOURCE_EDGE_ALPHA_FLOOR})"
        ),
    )
    parser.add_argument(
        "--max-green-edge-excess",
        type=_byte_int,
        default=DEFAULT_MAX_UNSUPPORTED_GREEN_EDGE_EXCESS,
        help=(
            "maximum unsupported source green edge channel excess "
            f"(default: {DEFAULT_MAX_UNSUPPORTED_GREEN_EDGE_EXCESS})"
        ),
    )
    parser.add_argument(
        "--max-magenta-edge-excess",
        type=_byte_int,
        default=DEFAULT_MAX_UNSUPPORTED_MAGENTA_EDGE_EXCESS,
        help=(
            "maximum unsupported source magenta edge channel excess "
            f"(default: {DEFAULT_MAX_UNSUPPORTED_MAGENTA_EDGE_EXCESS})"
        ),
    )
    parser.add_argument(
        "--max-introduced-green-fringe-ratio",
        "--max-green-fringe-ratio",
        dest="max_introduced_green_fringe_ratio",
        type=_unit_float,
        default=DEFAULT_MAX_GREEN_FRINGE_RATIO,
        help=(
            "maximum all-background introduced green-fringe ratio after the "
            f"Apple round-trip (default: {DEFAULT_MAX_GREEN_FRINGE_RATIO:g})"
        ),
    )
    parser.add_argument(
        "--max-introduced-magenta-fringe-ratio",
        "--max-magenta-fringe-ratio",
        dest="max_introduced_magenta_fringe_ratio",
        type=_unit_float,
        default=DEFAULT_MAX_MAGENTA_FRINGE_RATIO,
        help=(
            "maximum all-background introduced magenta-fringe ratio after the "
            f"Apple round-trip (default: {DEFAULT_MAX_MAGENTA_FRINGE_RATIO:g})"
        ),
    )
    parser.add_argument(
        "--fringe-channel-excess",
        type=_byte_int,
        default=DEFAULT_FRINGE_CHANNEL_EXCESS,
        help=(
            "minimum channel excess used to classify green/magenta fringe "
            f"pixels (default: {DEFAULT_FRINGE_CHANNEL_EXCESS})"
        ),
    )
    parser.add_argument(
        "--max-introduced-green-fringe-excess",
        type=_byte_int,
        default=DEFAULT_MAX_INTRODUCED_GREEN_FRINGE_EXCESS,
        help=(
            "maximum newly introduced green channel excess relative to the "
            f"ProRes reference (default: {DEFAULT_MAX_INTRODUCED_GREEN_FRINGE_EXCESS})"
        ),
    )
    parser.add_argument(
        "--max-introduced-magenta-fringe-excess",
        type=_byte_int,
        default=DEFAULT_MAX_INTRODUCED_MAGENTA_FRINGE_EXCESS,
        help=(
            "maximum newly introduced magenta channel excess relative to the "
            f"ProRes reference (default: {DEFAULT_MAX_INTRODUCED_MAGENTA_FRINGE_EXCESS})"
        ),
    )
    parser.add_argument(
        "--max-border-alpha",
        type=_byte_int,
        default=DEFAULT_MAX_BORDER_ALPHA,
        help=(
            "maximum decoded outer-border alpha after Apple round-trip "
            f"(default: {DEFAULT_MAX_BORDER_ALPHA})"
        ),
    )
    parser.add_argument(
        "--alpha-mean-error",
        type=_nonnegative_float,
        default=DEFAULT_ALPHA_MEAN_ABS_ERROR,
        help=(
            "maximum mean absolute 8-bit alpha error after round-trip "
            f"(default: {DEFAULT_ALPHA_MEAN_ABS_ERROR:g})"
        ),
    )
    parser.add_argument(
        "--alpha-p95-error",
        type=_nonnegative_float,
        default=DEFAULT_ALPHA_P95_ABS_ERROR,
        help=(
            "maximum p95 absolute 8-bit alpha error after round-trip "
            f"(default: {DEFAULT_ALPHA_P95_ABS_ERROR:g})"
        ),
    )
    parser.add_argument(
        "--alpha-max-error",
        type=_byte_int,
        default=DEFAULT_ALPHA_MAX_ABS_ERROR,
        help=(
            "maximum per-pixel 8-bit alpha error after round-trip "
            f"(default: {DEFAULT_ALPHA_MAX_ABS_ERROR})"
        ),
    )
    parser.add_argument(
        "--alpha-loss-threshold",
        type=_byte_int,
        default=DEFAULT_ALPHA_LOSS_THRESHOLD,
        help=(
            "alpha above this value may not round-trip to zero "
            f"(default: {DEFAULT_ALPHA_LOSS_THRESHOLD})"
        ),
    )
    parser.add_argument(
        "--allow-empty-frame",
        action="store_true",
        help="allow a frame with no retained foreground (normally a hard failure)",
    )
    parser.add_argument(
        "--strict-source-framing",
        action="store_true",
        help=(
            "reject source foreground that touches the outer frame; by default "
            "edge contact is recorded and the output border is made transparent"
        ),
    )
    parser.add_argument(
        "--replace",
        action="store_true",
        help="replace existing output/report/intermediate files",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="probe and print path-sanitized planned commands without encoding",
    )
    parser.add_argument(
        "--progress-jsonl",
        action="store_true",
        help=(
            "emit flushed, machine-readable JSONL progress on stdout instead "
            "of the final pretty-printed JSON report"
        ),
    )
    return parser


def _default_report_path(output: Path) -> Path:
    return output.with_suffix(".report.json")


def _default_intermediate_path(output: Path) -> Path:
    return output.with_name(output.stem + ".prores4444.mov")


def _safe_name(path: Path | str) -> str:
    # Reports are intentionally path-free.  A basename is useful for a local
    # operator while avoiding leakage of private checkout/user directories.
    return Path(path).name


def _safe_command(command: Iterable[Any]) -> list[Any]:
    return sanitize_command(list(command))


def _safe_report_value(value: Any) -> Any:
    """Recursively sanitize report values supplied by callers or CLI flags."""

    if isinstance(value, dict):
        return {str(key): _safe_report_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_safe_report_value(item) for item in value]
    if isinstance(value, str):
        return sanitize_text(value)
    return sanitize_value(value)


class _ProgressReporter:
    """Emit path-free, monotonic conversion progress for the macOS app."""

    def __init__(self, enabled: bool, *, stream: TextIO | None = None) -> None:
        self.enabled = enabled
        self.stream = stream if stream is not None else sys.stdout
        self.percent = 0
        self.stage = "prepare"

    def emit(
        self,
        percent: int,
        *,
        stage: str,
        message: str,
        status: str = "running",
        frame_completed: int | None = None,
        frame_total: int | None = None,
        code: str | None = None,
        safe_message: str | None = None,
    ) -> None:
        if not self.enabled:
            return
        self.percent = max(self.percent, min(100, max(0, int(percent))))
        self.stage = stage
        event: dict[str, Any] = {
            "event": "progress",
            "status": status,
            "percent": self.percent,
            "stage": stage,
            "message": message,
        }
        if frame_completed is not None or frame_total is not None:
            if frame_completed is None or frame_total is None:
                raise ValueError("frame progress requires completed and total")
            event["completed_frames"] = int(frame_completed)
            event["total_frames"] = int(frame_total)
        if code is not None:
            event["code"] = code
        if safe_message is not None:
            event["safe_message"] = safe_message
        print(
            json.dumps(_safe_report_value(event), sort_keys=True, separators=(",", ":")),
            file=self.stream,
            flush=True,
        )

    def failed(self, exc: BaseException) -> None:
        code, stage, safe_message = _failure_details(exc, current_stage=self.stage)
        self.emit(
            self.percent,
            stage=stage,
            message=safe_message,
            status="failed",
            code=code,
            safe_message=safe_message,
        )


def _failure_details(
    exc: BaseException, *, current_stage: str
) -> tuple[str, str, str]:
    text = str(exc).lower()
    if isinstance(exc, alpha_engine.MissingToolError):
        return "TOOL_MISSING", "prepare", "A required conversion tool is unavailable."
    if isinstance(exc, alpha_engine.MissingDependencyError):
        return "DEPENDENCY_MISSING", "prepare", "A required conversion dependency is unavailable."
    if isinstance(exc, alpha_engine.ProbeError):
        return "SOURCE_UNSUPPORTED", "probe", "The source video is unsupported."
    if isinstance(exc, FrameQualityError):
        stage = "matte" if "source frame" in text or "matte" in text else "verify"
        return "QUALITY_GATE_FAILED", stage, "The animation failed a quality gate."
    if "timed out" in text:
        return "PROCESS_TIMEOUT", current_stage, "A conversion stage timed out."
    if "disk" in text or "budget" in text or "resource" in text:
        return "RESOURCE_LIMIT", "prepare", "The conversion exceeds available resources."
    if "publication" in text or "manifest" in text or "published" in text:
        return "PUBLICATION_FAILED", "publish", "Verified artifacts could not be published safely."
    if "cancel" in text:
        return "CANCELLED", current_stage, "Conversion was cancelled."
    return "CONVERSION_FAILED", current_stage, "Conversion failed."


def _write_json_temp(path: Path, payload: dict[str, Any]) -> Path:
    """Write a sanitized report to a sibling temporary file."""

    try:
        path.parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise AlphaConversionError("unable to prepare report directory") from exc
    temporary: Path | None = None
    keep_temporary = False
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temporary = Path(handle.name)
            json.dump(_safe_report_value(payload), handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        assert temporary is not None
        keep_temporary = True
        return temporary
    except OSError as exc:
        raise AlphaConversionError("unable to write report") from exc
    finally:
        if temporary is not None and not keep_temporary:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


def _write_json(path: Path, payload: dict[str, Any], *, replace: bool) -> None:
    if path.exists() and not replace:
        raise AlphaConversionError(
            f"report already exists: {path.name}; pass --replace to overwrite"
        )
    temporary = _write_json_temp(path, payload)
    try:
        os.replace(temporary, path)
    except OSError as exc:
        raise AlphaConversionError("unable to write report") from exc
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _sha256_file(path: Path) -> str:
    """Return a file digest without exposing its path in errors/reports."""

    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as exc:
        raise AlphaConversionError("unable to hash conversion artifact") from exc
    return digest.hexdigest()


def _sha256_source_file(
    path: Path, *, max_source_bytes: int = DEFAULT_MAX_SOURCE_BYTES
) -> str:
    """Hash one non-empty regular source without following or blocking on it."""

    flags = os.O_RDONLY
    for flag_name in ("O_CLOEXEC", "O_NONBLOCK", "O_NOFOLLOW"):
        flags |= getattr(os, flag_name, 0)

    descriptor: int | None = None
    try:
        # Reject special files before opening them at all. O_NOFOLLOW and
        # O_NONBLOCK then make the open safe against path replacement where
        # those platform flags are available.
        path_stat = os.lstat(path)
        if (
            stat.S_ISLNK(path_stat.st_mode)
            or not stat.S_ISREG(path_stat.st_mode)
            or path_stat.st_size <= 0
        ):
            raise AlphaConversionError(
                "source video must be a non-empty regular file"
            )
        descriptor = os.open(path, flags)
        source_stat = os.fstat(descriptor)
        if not stat.S_ISREG(source_stat.st_mode) or source_stat.st_size <= 0:
            raise AlphaConversionError(
                "source video must be a non-empty regular file"
            )
        if source_stat.st_size > max_source_bytes:
            raise AlphaConversionError("source video exceeds the configured size budget")

        digest = hashlib.sha256()
        bytes_hashed = 0
        while bytes_hashed < source_stat.st_size:
            chunk = os.read(
                descriptor, min(1024 * 1024, source_stat.st_size - bytes_hashed)
            )
            if not chunk:
                raise AlphaConversionError("source video changed during hashing")
            bytes_hashed += len(chunk)
            digest.update(chunk)
        if os.read(descriptor, 1):
            raise AlphaConversionError("source video changed during hashing")
        final_stat = os.fstat(descriptor)
        path_final_stat = os.stat(path, follow_symlinks=False)
        identity_fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
        if any(
            getattr(source_stat, field) != getattr(final_stat, field)
            or getattr(source_stat, field) != getattr(path_final_stat, field)
            for field in identity_fields
        ):
            raise AlphaConversionError("source video changed during hashing")
        return digest.hexdigest()
    except AlphaConversionError:
        raise
    except OSError:
        raise AlphaConversionError(
            "source video must be a non-empty regular file"
        ) from None
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass


def _assert_source_unchanged(
    source: Path, expected_sha256: str, *, max_source_bytes: int
) -> str:
    """Rehash a source and reject any in-place mutation during conversion."""

    current_sha256 = _sha256_source_file(
        source, max_source_bytes=max_source_bytes
    )
    if current_sha256 != expected_sha256:
        raise AlphaConversionError("source video changed during conversion")
    return current_sha256


def _reserve_backup_path(target: Path) -> Path:
    try:
        descriptor, name = tempfile.mkstemp(
            dir=target.parent,
            prefix=f".{target.name}.",
            suffix=".bak",
        )
        os.close(descriptor)
        backup = Path(name)
        backup.unlink()
        return backup
    except OSError as exc:
        raise AlphaConversionError("unable to prepare artifact rollback") from exc


def _prospective_backup_path(target: Path) -> Path:
    for _attempt in range(8):
        candidate = target.parent / f".{target.name}.{secrets.token_hex(8)}.bak"
        if not candidate.exists():
            return candidate
    raise AlphaConversionError("unable to prepare artifact rollback")


class _InjectedPublicationCrash(BaseException):
    """Test-only hard-crash marker that intentionally bypasses rollback."""


def _fsync_directory(path: Path) -> None:
    descriptor: int | None = None
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        os.fsync(descriptor)
    except OSError as exc:
        raise AlphaConversionError("unable to durably publish conversion artifacts") from exc
    finally:
        if descriptor is not None:
            os.close(descriptor)


def _durable_replace(source: Path, target: Path) -> None:
    try:
        os.replace(source, target)
    except OSError as exc:
        raise AlphaConversionError("unable to complete artifact publication") from exc
    _fsync_directory(target.parent)
    if source.parent != target.parent:
        _fsync_directory(source.parent)


def _durable_unlink(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        return
    except OSError as exc:
        raise AlphaConversionError("unable to durably clean publication state") from exc
    _fsync_directory(path.parent)


def _transaction_manifest_path(report_target: Path) -> Path:
    return report_target.parent / f".{report_target.name}.transaction.json"


def _write_transaction_manifest(path: Path, payload: dict[str, Any]) -> None:
    temporary: Path | None = None
    try:
        descriptor, name = tempfile.mkstemp(
            dir=path.parent, prefix=f".{path.name}.", suffix=".tmp"
        )
        temporary = Path(name)
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        _durable_replace(temporary, path)
        temporary = None
    except AlphaConversionError:
        raise
    except OSError as exc:
        raise AlphaConversionError("unable to persist publication recovery state") from exc
    finally:
        if temporary is not None:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


def _transaction_identity(path: Path, *, require_private_file: bool) -> dict[str, Any]:
    descriptor: int | None = None
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NONBLOCK", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        metadata = os.fstat(descriptor)
    except OSError as exc:
        if descriptor is not None:
            with contextlib.suppress(OSError):
                os.close(descriptor)
        raise AlphaConversionError("publication recovery artifact is invalid") from exc
    try:
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
            or (require_private_file and stat.S_IMODE(metadata.st_mode) != 0o600)
        ):
            raise AlphaConversionError("publication recovery artifact is invalid")
        digest = hashlib.sha256()
        remaining = metadata.st_size
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                raise AlphaConversionError("publication recovery artifact changed")
            digest.update(chunk)
            remaining -= len(chunk)
        if os.read(descriptor, 1):
            raise AlphaConversionError("publication recovery artifact changed")
        final_metadata = os.fstat(descriptor)
        if any(
            getattr(metadata, field) != getattr(final_metadata, field)
            for field in ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
        ):
            raise AlphaConversionError("publication recovery artifact changed")
        return {
            "dev": int(metadata.st_dev),
            "ino": int(metadata.st_ino),
            "size": int(metadata.st_size),
            "sha256": digest.hexdigest(),
        }
    finally:
        if descriptor is not None:
            with contextlib.suppress(OSError):
                os.close(descriptor)


def _identity_matches(
    path: Path, identity: dict[str, Any], *, require_private_file: bool
) -> bool:
    try:
        return _transaction_identity(
            path, require_private_file=require_private_file
        ) == identity
    except AlphaConversionError:
        return False


def _inode_matches(path: Path, identity: dict[str, Any]) -> bool:
    descriptor: int | None = None
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NONBLOCK", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        metadata = os.fstat(descriptor)
        return (
            stat.S_ISREG(metadata.st_mode)
            and metadata.st_dev == identity.get("dev")
            and metadata.st_ino == identity.get("ino")
        )
    except OSError:
        return False
    finally:
        if descriptor is not None:
            with contextlib.suppress(OSError):
                os.close(descriptor)


def _create_transaction_directory(parent: Path, transaction_id: str) -> Path:
    try:
        directory = Path(
            tempfile.mkdtemp(dir=parent, prefix=f".statelet-{transaction_id}-")
        )
        directory.chmod(0o700)
        _fsync_directory(parent)
        return directory
    except OSError as exc:
        raise AlphaConversionError("unable to prepare private publication state") from exc


def _transaction_directory_identity(directory: Path) -> dict[str, int]:
    descriptor: int | None = None
    try:
        descriptor = os.open(
            directory,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        metadata = os.fstat(descriptor)
    except OSError as exc:
        if descriptor is not None:
            with contextlib.suppress(OSError):
                os.close(descriptor)
        raise AlphaConversionError("publication recovery directory is invalid") from exc
    try:
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or stat.S_IMODE(metadata.st_mode) != 0o700
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink < 1
        ):
            raise AlphaConversionError("publication recovery directory is invalid")
        return {
            "dev": int(metadata.st_dev),
            "ino": int(metadata.st_ino),
            "nlink": int(metadata.st_nlink),
        }
    finally:
        if descriptor is not None:
            with contextlib.suppress(OSError):
                os.close(descriptor)


def _remove_transaction_directory(directory: Path) -> None:
    try:
        directory.rmdir()
    except FileNotFoundError:
        return
    except OSError as exc:
        raise AlphaConversionError("unable to clean private publication state") from exc
    _fsync_directory(directory.parent)


def _copy_transaction_stage(source: Path, destination: Path) -> None:
    try:
        descriptor = os.open(
            destination,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as target_handle, source.open("rb") as source_handle:
            shutil.copyfileobj(source_handle, target_handle, length=1024 * 1024)
            target_handle.flush()
            os.fsync(target_handle.fileno())
        _fsync_directory(destination.parent)
    except OSError as exc:
        raise AlphaConversionError("unable to stage conversion artifact") from exc


def _write_transaction_report_stage(path: Path, payload: dict[str, Any]) -> None:
    try:
        descriptor = os.open(
            path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(_safe_report_value(payload), handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        _fsync_directory(path.parent)
    except OSError as exc:
        raise AlphaConversionError("unable to stage conversion report") from exc


def _validated_transaction_manifest(
    manifest: Path, expected_targets: tuple[Path, ...]
) -> dict[str, Any]:
    descriptor: int | None = None
    try:
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(manifest, flags)
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_size <= 0
            or metadata.st_size > 64 * 1024
            or stat.S_IMODE(metadata.st_mode) != 0o600
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
        ):
            raise ValueError
        chunks: list[bytes] = []
        remaining = 64 * 1024 + 1
        while remaining:
            chunk = os.read(descriptor, min(8192, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        raw = b"".join(chunks)
        if len(raw) > 64 * 1024:
            raise ValueError
        payload = json.loads(raw.decode("utf-8"))
    except (OSError, ValueError, TypeError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise AlphaConversionError("publication recovery manifest is invalid") from exc
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
    if not isinstance(payload, dict) or payload.get("schema") != 2:
        raise AlphaConversionError("publication recovery manifest is invalid")
    transaction_id = payload.get("transaction_id")
    directories = payload.get("directories")
    if (
        not isinstance(transaction_id, str)
        or not re.fullmatch(r"[0-9a-f]{64}", transaction_id)
        or not isinstance(directories, list)
        or not directories
    ):
        raise AlphaConversionError("publication recovery manifest is invalid")
    validated_directories: dict[str, Path] = {}
    allowed_parents = {target.absolute().parent for target in expected_targets}
    for record in directories:
        if not isinstance(record, dict) or not isinstance(record.get("path"), str):
            raise AlphaConversionError("publication recovery manifest is invalid")
        directory = Path(record["path"])
        if (
            not directory.is_absolute()
            or directory.parent not in allowed_parents
            or not directory.name.startswith(f".statelet-{transaction_id}-")
            or set(record) != {"path", "dev", "ino", "nlink"}
        ):
            raise AlphaConversionError("publication recovery directory is invalid")
        actual = _transaction_directory_identity(directory)
        if actual["dev"] != record.get("dev") or actual["ino"] != record.get("ino"):
            raise AlphaConversionError("publication recovery directory is invalid")
        validated_directories[str(directory)] = directory
    entries = payload.get("entries")
    if not isinstance(entries, list) or len(entries) != len(expected_targets):
        raise AlphaConversionError(
            "publication recovery requires identical artifact path flags"
        )
    expected = {
        str(target.absolute()): target.absolute() for target in expected_targets
    }
    seen: set[str] = set()
    allowed_artifacts: dict[Path, set[str]] = {
        directory: set() for directory in validated_directories.values()
    }
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            raise AlphaConversionError("publication recovery manifest is invalid")
        target_text = entry.get("target")
        directory_text = entry.get("directory")
        digest = entry.get("sha256")
        if (
            not isinstance(target_text, str)
            or target_text in seen
            or not isinstance(directory_text, str)
            or not isinstance(digest, str)
            or not re.fullmatch(r"[0-9a-f]{64}", digest)
            or not isinstance(entry.get("had_target"), bool)
        ):
            raise AlphaConversionError("publication recovery manifest is invalid")
        if target_text not in expected:
            raise AlphaConversionError(
                "publication recovery requires identical artifact path flags"
            )
        target = Path(target_text)
        if not target.is_absolute() or target != Path(os.path.abspath(target)):
            raise AlphaConversionError("publication recovery manifest is invalid")
        directory = validated_directories.get(directory_text)
        if directory is None or directory.parent != target.parent:
            raise AlphaConversionError("publication recovery directory is invalid")
        stage = directory / f"stage-{index}"
        backup = directory / f"backup-{index}"
        allowed_artifacts[directory].update((stage.name, backup.name))
        if (
            entry.get("stage_name") != stage.name
            or entry.get("backup_name") != backup.name
            or not isinstance(entry.get("stage_identity"), dict)
            or (
                entry["had_target"]
                and not isinstance(entry.get("original_identity"), dict)
            )
        ):
            raise AlphaConversionError("publication recovery manifest is invalid")
        for identity_name in ("stage_identity", "original_identity"):
            identity = entry.get(identity_name)
            if identity is None:
                continue
            if set(identity) != {"dev", "ino", "size", "sha256"} or not re.fullmatch(
                r"[0-9a-f]{64}", str(identity.get("sha256", ""))
            ):
                raise AlphaConversionError("publication recovery manifest is invalid")
        if stage.exists() and not _identity_matches(
            stage, entry["stage_identity"], require_private_file=True
        ):
            raise AlphaConversionError("publication recovery artifact is invalid")
        if backup.exists() and not _identity_matches(
            backup, entry["original_identity"], require_private_file=False
        ):
            raise AlphaConversionError("publication recovery backup is invalid")
        entry["stage"] = str(stage)
        entry["backup"] = str(backup)
        seen.add(target_text)
    for directory, allowed_names in allowed_artifacts.items():
        try:
            actual_names = {item.name for item in directory.iterdir()}
            directory_metadata = os.lstat(directory)
        except OSError as exc:
            raise AlphaConversionError("publication recovery directory is invalid") from exc
        if not actual_names.issubset(allowed_names) or directory_metadata.st_nlink not in {
            2,
            2 + len(actual_names),
        }:
            raise AlphaConversionError("publication recovery directory is invalid")
    if seen != set(expected):
        raise AlphaConversionError(
            "publication recovery requires identical artifact path flags"
        )
    if not isinstance(payload.get("committed"), bool):
        raise AlphaConversionError("publication recovery manifest is invalid")
    return payload


def _recover_publish_transaction(
    output_target: Path,
    intermediate_target: Path | None,
    report_target: Path,
) -> None:
    manifest = _transaction_manifest_path(report_target)
    if not os.path.lexists(manifest):
        return
    expected_targets = tuple(
        target
        for target in (output_target, intermediate_target, report_target)
        if target is not None
    )
    payload = _validated_transaction_manifest(manifest, expected_targets)
    entries = payload["entries"]
    directory_identities = {
        record["path"]: record for record in payload["directories"]
    }

    def revalidate_directory(entry: dict[str, Any]) -> None:
        record = directory_identities[entry["directory"]]
        current = _transaction_directory_identity(Path(entry["directory"]))
        if current["dev"] != record["dev"] or current["ino"] != record["ino"]:
            raise AlphaConversionError("publication recovery directory changed")

    if payload["committed"]:
        for entry in entries:
            revalidate_directory(entry)
            target = Path(entry["target"])
            if not target.is_file() or _sha256_file(target) != entry["sha256"]:
                raise AlphaConversionError("committed publication recovery digest mismatch")
        for entry in entries:
            revalidate_directory(entry)
            _durable_unlink(Path(entry["stage"]))
            _durable_unlink(Path(entry["backup"]))
    else:
        for entry in reversed(entries):
            revalidate_directory(entry)
            target = Path(entry["target"])
            stage = Path(entry["stage"])
            backup = Path(entry["backup"])
            if backup.exists():
                if target.exists():
                    if not _inode_matches(target, entry["stage_identity"]):
                        raise AlphaConversionError(
                            "publication recovery target identity mismatch"
                        )
                    _durable_unlink(target)
                _durable_replace(backup, target)
            elif entry["had_target"]:
                if not target.exists() or not _identity_matches(
                    target,
                    entry["original_identity"],
                    require_private_file=False,
                ):
                    raise AlphaConversionError(
                        "publication recovery original identity mismatch"
                    )
            elif target.exists() and not stage.exists():
                if not _inode_matches(target, entry["stage_identity"]):
                    raise AlphaConversionError(
                        "publication recovery target identity mismatch"
                    )
                _durable_unlink(target)
            _durable_unlink(stage)
    for directory_record in payload["directories"]:
        _remove_transaction_directory(Path(directory_record["path"]))
    _durable_unlink(manifest)


def _stage_artifact_for_target(source: Path, target: Path) -> Path:
    """Copy a verified artifact to a private sibling stage on the target volume."""

    temporary: Path | None = None
    completed = False
    try:
        source_sha256 = _sha256_file(source)
        descriptor, name = tempfile.mkstemp(
            dir=target.parent,
            prefix=f".{target.name}.",
            suffix=".tmp",
        )
        temporary = Path(name)
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as destination, source.open("rb") as origin:
            shutil.copyfileobj(origin, destination, length=1024 * 1024)
            destination.flush()
            os.fsync(destination.fileno())
        if temporary.stat().st_size == 0:
            raise AlphaConversionError("staged conversion artifact is missing")
        if _sha256_file(temporary) != source_sha256:
            raise AlphaConversionError("staged conversion artifact digest mismatch")
        completed = True
        return temporary
    except AlphaConversionError:
        raise
    except OSError as exc:
        raise AlphaConversionError("unable to stage conversion artifact") from exc
    finally:
        if temporary is not None and not completed:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


def _publish_transaction(
    output_stage: Path,
    output_target: Path,
    intermediate_stage: Path | None,
    intermediate_target: Path | None,
    report_target: Path,
    report_payload: dict[str, Any],
    *,
    replace: bool,
    _crash_after_rename: int | None = None,
) -> None:
    """Crash-recoverably publish delivery, intermediate, and bound report."""

    _recover_publish_transaction(output_target, intermediate_target, report_target)
    manifest = _transaction_manifest_path(report_target)
    transaction_id = secrets.token_hex(32)
    sources_and_targets: list[tuple[Path | None, Path, bool]] = [
        (output_stage, output_target, False)
    ]
    if intermediate_stage is not None:
        if intermediate_target is None:
            raise AlphaConversionError("intermediate stage has no target")
        sources_and_targets.append((intermediate_stage, intermediate_target, False))
    sources_and_targets.append((None, report_target, True))
    transaction_directories: dict[Path, Path] = {}
    entries: list[dict[str, Any]] = []
    try:
        for parent in {target.parent for _source, target, _is_report in sources_and_targets}:
            transaction_directories[parent] = _create_transaction_directory(
                parent, transaction_id
            )
        for index, (source, target, is_report) in enumerate(sources_and_targets):
            directory = transaction_directories[target.parent]
            stage = directory / f"stage-{index}"
            backup = directory / f"backup-{index}"
            if is_report:
                _write_transaction_report_stage(stage, report_payload)
            else:
                assert source is not None
                _copy_transaction_stage(source, stage)
            had_target = target.exists()
            if had_target and not replace:
                raise AlphaConversionError(
                    f"{target.name} already exists; pass --replace to overwrite"
                )
            stage_identity = _transaction_identity(stage, require_private_file=True)
            artifacts = report_payload.get("artifacts")
            expected_sha256: str | None = None
            if isinstance(artifacts, dict):
                if target == output_target:
                    expected_sha256 = artifacts.get("output_sha256")
                elif intermediate_target is not None and target == intermediate_target:
                    expected_sha256 = artifacts.get("intermediate_sha256")
            if expected_sha256 is not None and stage_identity["sha256"] != expected_sha256:
                raise AlphaConversionError(
                    "staged conversion artifact does not match report digest"
                )
            original_identity = (
                _transaction_identity(target, require_private_file=False)
                if had_target
                else None
            )
            entries.append(
                {
                    "target": str(target.absolute()),
                    "directory": str(directory.absolute()),
                    "stage_name": stage.name,
                    "backup_name": backup.name,
                    "had_target": had_target,
                    "sha256": stage_identity["sha256"],
                    "stage_identity": stage_identity,
                    "original_identity": original_identity,
                }
            )
        directory_records = [
            {"path": str(directory.absolute()), **_transaction_directory_identity(directory)}
            for directory in transaction_directories.values()
        ]
        manifest_payload = {
            "schema": 2,
            "transaction_id": transaction_id,
            "committed": False,
            "directories": directory_records,
            "entries": entries,
        }
        _write_transaction_manifest(manifest, manifest_payload)
        rename_count = 0

        def rename(source: Path, target: Path) -> None:
            nonlocal rename_count
            _durable_replace(source, target)
            rename_count += 1
            if _crash_after_rename == rename_count:
                raise _InjectedPublicationCrash()

        for entry in entries:
            if entry["had_target"]:
                rename(
                    Path(entry["target"]),
                    Path(entry["directory"]) / entry["backup_name"],
                )
        for entry in entries:
            rename(
                Path(entry["directory"]) / entry["stage_name"],
                Path(entry["target"]),
            )
        for entry in entries:
            target = Path(entry["target"])
            if _sha256_file(target) != entry["sha256"]:
                raise AlphaConversionError("published conversion artifact digest mismatch")
        manifest_payload["committed"] = True
        _write_transaction_manifest(manifest, manifest_payload)
        cleanup_failed = False
        for entry in entries:
            try:
                _durable_unlink(
                    Path(entry["directory"]) / entry["backup_name"]
                )
            except AlphaConversionError:
                cleanup_failed = True
                warnings.warn_explicit(
                    "publication committed; unable to remove backup "
                    f"{entry['backup_name']}",
                    RuntimeWarning,
                    filename=Path(__file__).name,
                    lineno=0,
                    module=__name__,
                )
        if not cleanup_failed:
            for directory in transaction_directories.values():
                _remove_transaction_directory(directory)
            _durable_unlink(manifest)
    except _InjectedPublicationCrash:
        raise
    except BaseException as exc:
        try:
            if os.path.lexists(manifest):
                _recover_publish_transaction(
                    output_target, intermediate_target, report_target
                )
            else:
                for index, (_source, target, _is_report) in enumerate(
                    sources_and_targets
                ):
                    directory = transaction_directories.get(target.parent)
                    if directory is not None:
                        _durable_unlink(directory / f"stage-{index}")
                        _durable_unlink(directory / f"backup-{index}")
                for directory in transaction_directories.values():
                    _remove_transaction_directory(directory)
        except BaseException as recovery_exc:
            raise AlphaConversionError(
                "artifact publication failed and recovery was incomplete"
            ) from recovery_exc
        if isinstance(exc, AlphaConversionError):
            raise
        raise AlphaConversionError("unable to complete artifact publication") from exc


def _check_target_collisions(
    source: Path,
    output: Path,
    report: Path,
    intermediate: Path | None,
    *,
    replace: bool,
) -> None:
    resolved = {"source": source.resolve(), "output": output.resolve(), "report": report.resolve()}
    if intermediate is not None:
        resolved["intermediate"] = intermediate.resolve()
    if resolved["source"] == resolved["output"]:
        raise AlphaConversionError("source and output must be different files")
    if resolved["source"] in set(resolved.values()) - {resolved["source"]}:
        raise AlphaConversionError("source must not be used as an output or report target")
    names = list(resolved.items())
    for index, (left_name, left_path) in enumerate(names):
        for right_name, right_path in names[index + 1 :]:
            if left_path == right_path:
                raise AlphaConversionError(
                    f"{left_name} and {right_name} targets must be different files"
                )
    for name in ("output", "report", "intermediate"):
        target = resolved.get(name)
        if target is not None and target.exists() and not replace:
            raise AlphaConversionError(
                f"{name} already exists: {target.name}; pass --replace to overwrite"
            )
    try:
        output.parent.mkdir(parents=True, exist_ok=True)
        report.parent.mkdir(parents=True, exist_ok=True)
        if intermediate is not None:
            intermediate.parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise AlphaConversionError("unable to prepare output directories") from exc


def _start_process(command: list[str], *, stdin: Any = None, stdout: Any = None) -> Any:
    try:
        return subprocess.Popen(
            command,
            stdin=stdin,
            stdout=stdout,
            # ffmpeg diagnostics are intentionally discarded here: they can
            # contain private paths and an unconsumed PIPE can deadlock a long
            # video when a decoder emits repeated warnings.  The stable error
            # category and exit code are sufficient for the release report.
            stderr=subprocess.DEVNULL,
        )
    except OSError as exc:
        raise AlphaConversionError("unable to start ffmpeg") from exc


def _start_rgba_decoder_pair(
    reference_video: Path,
    roundtrip_video: Path,
    *,
    width: int,
    height: int,
    ffmpeg: str,
    frame_sync_mode: str = "fps_mode",
) -> tuple[Any, Any]:
    """Start both RGBA decoders and close the first if the second fails."""

    reference_decoder: Any | None = None
    delivery_decoder: Any | None = None
    try:
        reference_decoder = _start_process(
            build_ffmpeg_rgba_decode_command(
                reference_video,
                width=width,
                height=height,
                ffmpeg=ffmpeg,
                frame_sync_mode=frame_sync_mode,
            ),
            stdout=subprocess.PIPE,
        )
        delivery_decoder = _start_process(
            build_ffmpeg_rgba_decode_command(
                roundtrip_video,
                width=width,
                height=height,
                ffmpeg=ffmpeg,
                frame_sync_mode=frame_sync_mode,
            ),
            stdout=subprocess.PIPE,
        )
        return reference_decoder, delivery_decoder
    except BaseException:
        if reference_decoder is not None:
            close_process(reference_decoder)
        if delivery_decoder is not None:
            close_process(delivery_decoder)
        raise


def _start_matte_process_pair(
    decode_command: list[str], encode_command: list[str]
) -> tuple[Any, Any]:
    """Start decoder/encoder together without leaking a half-started process."""

    decoder: Any | None = None
    encoder: Any | None = None
    try:
        decoder = _start_process(decode_command, stdout=subprocess.PIPE)
        encoder = _start_process(encode_command, stdin=subprocess.PIPE)
        return decoder, encoder
    except BaseException:
        if decoder is not None:
            close_process(decoder)
        if encoder is not None:
            close_process(encoder)
        raise


def _run_avconvert(
    source: Path,
    output: Path,
    *,
    avconvert: str,
    preset: str,
    timeout_seconds: float = DEFAULT_PROCESS_TIMEOUT_SECONDS,
) -> None:
    command = build_avconvert_command(source, output, avconvert=avconvert, preset=preset)
    try:
        result = alpha_engine._run_bounded_capture(
            command,
            timeout_seconds=timeout_seconds,
            stdout_limit=64 * 1024,
            stderr_limit=64 * 1024,
            overflow_message="avconvert diagnostic output exceeds the supported bound",
            timeout_message="avconvert timed out before producing a movie",
            total_limit=64 * 1024,
        )
        diagnostic = sanitize_text((result.stdout + result.stderr).strip())[-500:]
    except alpha_engine.ProbeError as exc:
        if "timed out" in str(exc):
            raise AlphaConversionError(
                "avconvert timed out before producing a movie"
            ) from exc
        raise AlphaConversionError("avconvert diagnostic output exceeded its bound") from exc
    except OSError as exc:
        raise AlphaConversionError("unable to execute avconvert") from exc
    if result.returncode != 0:
        raise AlphaConversionError(
            f"avconvert conversion failed (exit {result.returncode})"
            + (f": {diagnostic}" if diagnostic else "")
        )
    if not output.is_file() or output.stat().st_size == 0:
        raise AlphaConversionError("avconvert produced no output movie")


def _verify_source_background(
    source: Path,
    *,
    background_reference: Path,
    info: VideoInfo,
    ffmpeg: str,
    timeout_seconds: float,
    progress: _ProgressReporter | None = None,
    frame_sync_mode: str = "fps_mode",
) -> dict[str, Any]:
    """Attest green evidence on every untransformed source frame."""

    command = build_ffmpeg_decode_command(
        source,
        width=0,
        height=0,
        ffmpeg=ffmpeg,
        stream_index=info.stream_index,
        frame_sync_mode=frame_sync_mode,
    )
    decoder = _start_process(command, stdout=subprocess.PIPE)
    frames_checked = 0
    minimum_ratio = 1.0
    minimum_connected_ratio = 1.0
    minimum_border_ratio = 1.0
    minimum_row_coverage = 1.0
    minimum_column_coverage = 1.0
    temporal_occlusion_frames = 0
    strict_background_samples: list[tuple[int, int, int]] = []
    try:
        with background_reference.open("wb") as background_handle:
            for rgb in read_raw_frames(
                decoder,
                width=info.width,
                height=info.height,
                expected_frames=info.frame_count,
                channels=3,
                timeout_seconds=timeout_seconds,
            ):
                frame_number = frames_checked + 1
                try:
                    evidence = assess_green_background(rgb)
                except FrameQualityError as exc:
                    if len(strict_background_samples) < 3:
                        raise FrameQualityError(
                            f"source frame {frame_number}: {exc}"
                        ) from exc
                    trusted_background_rgb = tuple(
                        int(
                            round(
                                statistics.median(
                                    sample[channel]
                                    for sample in strict_background_samples
                                )
                            )
                        )
                        for channel in range(3)
                    )
                    try:
                        evidence = (
                            alpha_engine.assess_temporally_occluded_green_background(
                                rgb,
                                trusted_background_rgb=trusted_background_rgb,
                            )
                        )
                    except FrameQualityError as temporal_exc:
                        raise FrameQualityError(
                            f"source frame {frame_number}: {temporal_exc}"
                        ) from exc
                    temporal_occlusion_frames += 1
                else:
                    strict_background_samples.append(
                        tuple(int(value) for value in evidence["background_rgb"])
                    )
                background_handle.write(bytes(evidence["background_rgb"]))
                frames_checked += 1
                if progress is not None:
                    progress.emit(
                        12 + round(3 * frames_checked / info.frame_count),
                        stage="source-background",
                        message="Checking source green background",
                        frame_completed=frames_checked,
                        frame_total=info.frame_count,
                    )
                minimum_ratio = min(
                    minimum_ratio, float(evidence["green_source_ratio"])
                )
                minimum_connected_ratio = min(
                    minimum_connected_ratio,
                    float(
                        evidence.get(
                            "green_source_connected_ratio",
                            evidence["green_source_ratio"],
                        )
                    ),
                )
                minimum_border_ratio = min(
                    minimum_border_ratio,
                    float(evidence["green_source_border_ratio"]),
                )
                minimum_row_coverage = min(
                    minimum_row_coverage,
                    float(evidence["green_source_row_coverage"]),
                )
                minimum_column_coverage = min(
                    minimum_column_coverage,
                    float(evidence["green_source_column_coverage"]),
                )
            background_handle.flush()
            os.fsync(background_handle.fileno())
    except OSError as exc:
        raise AlphaConversionError("unable to write source background reference") from exc
    finally:
        close_process(decoder)
    return {
        "performed": True,
        "space": "source-before-framing",
        "frames_checked": frames_checked,
        "expected_frames": info.frame_count,
        "minimum_green_source_ratio": minimum_ratio,
        "minimum_green_source_connected_ratio": minimum_connected_ratio,
        "minimum_green_source_border_ratio": minimum_border_ratio,
        "minimum_green_source_row_coverage": minimum_row_coverage,
        "minimum_green_source_column_coverage": minimum_column_coverage,
        "strict_background_attestation_frames": len(strict_background_samples),
        "temporal_occlusion_frames": temporal_occlusion_frames,
        "quality_passed": True,
    }


def _write_all_with_deadline(
    stream: Any, data: bytes, *, deadline: float
) -> None:
    """Write one frame without allowing a full encoder pipe to stall forever."""

    try:
        descriptor = stream.fileno()
    except (AttributeError, OSError):
        raise AlphaConversionError(
            "ffmpeg ProRes encoder input does not support bounded writes"
        )
    try:
        os.set_blocking(descriptor, False)
    except OSError as exc:
        raise AlphaConversionError("unable to configure ffmpeg encoder input") from exc
    remaining = memoryview(data)
    selector = selectors.DefaultSelector()
    try:
        selector.register(descriptor, selectors.EVENT_WRITE)
        while remaining:
            timeout = deadline - time.monotonic()
            if timeout <= 0 or not selector.select(timeout):
                raise AlphaConversionError("ffmpeg ProRes encoding timed out")
            try:
                written = os.write(descriptor, remaining)
            except BlockingIOError:
                continue
            except (BrokenPipeError, OSError) as exc:
                raise AlphaConversionError(
                    "ffmpeg ProRes encoder closed its input"
                ) from exc
            if written <= 0:
                raise AlphaConversionError("ffmpeg ProRes encoder closed its input")
            remaining = remaining[written:]
    finally:
        selector.close()


def _stream_matte_to_prores(
    source: Path,
    intermediate: Path,
    reference_alpha: Path,
    *,
    background_reference: Path | None = None,
    info: VideoInfo,
    width: int,
    height: int,
    ffmpeg: str,
    border_width: int,
    key_floor: float,
    key_ceiling: float,
    despill_strength: float,
    despill_allowance: float,
    max_green_edge_ratio: float,
    max_magenta_edge_ratio: float,
    source_edge_alpha_floor: int,
    max_green_edge_excess: int,
    max_magenta_edge_excess: int,
    allow_empty_frame: bool,
    reject_edge_contact: bool,
    timeout_seconds: float = DEFAULT_PROCESS_TIMEOUT_SECONDS,
    resize_mode: str = "fill",
    progress: _ProgressReporter | None = None,
    frame_sync_mode: str = "fps_mode",
) -> dict[str, Any]:
    decode_command = build_ffmpeg_decode_command(
        source,
        width=width,
        height=height,
        ffmpeg=ffmpeg,
        stream_index=info.stream_index,
        resize_mode=resize_mode,
        frame_sync_mode=frame_sync_mode,
    )
    encode_command = build_ffmpeg_prores_command(
        intermediate, width=width, height=height, fps=info.fps, ffmpeg=ffmpeg
    )
    decoder, encoder = _start_matte_process_pair(decode_command, encode_command)
    stage_deadline = time.monotonic() + timeout_seconds
    frames_checked = 0
    max_edge_alpha = 0
    max_green_ratio = 0.0
    max_magenta_ratio = 0.0
    max_green_excess = 0
    max_magenta_excess = 0
    semitransparent_total = 0
    foreground_total = 0
    empty_frame_count = 0
    consecutive_empty_frames = 0
    maximum_consecutive_empty_frames = 0
    max_preclean_edge_alpha = 0
    preclean_edge_contact_total = 0
    first_rgba: Any | None = None
    last_rgba: Any | None = None
    suitability_bounds = (
        _fit_content_bounds(info, width=width, height=height)
        if resize_mode == "fit"
        else None
    )
    try:
        if encoder.stdin is None:
            raise AlphaConversionError("ffmpeg ProRes encoder did not expose stdin")
        try:
            background_context = (
                background_reference.open("rb")
                if background_reference is not None
                else contextlib.nullcontext(None)
            )
            with background_context as background_handle, reference_alpha.open(
                "wb"
            ) as alpha_handle:
                for rgb in read_raw_frames(
                    decoder,
                    width=width,
                    height=height,
                    expected_frames=info.frame_count,
                    channels=3,
                    timeout_seconds=timeout_seconds,
                ):
                    matte_diagnostics: dict[str, int] = {}
                    frame_number = frames_checked + 1
                    background_rgb: tuple[int, int, int] | None = None
                    if background_handle is not None:
                        raw_background = background_handle.read(3)
                        if len(raw_background) != 3:
                            raise AlphaConversionError(
                                "source background reference is truncated"
                            )
                        background_rgb = tuple(raw_background)  # type: ignore[assignment]
                    try:
                        rgba = matte_frame(
                            rgb,
                            border_width=border_width,
                            key_floor=key_floor,
                            key_ceiling=key_ceiling,
                            despill_strength=despill_strength,
                            despill_allowance=despill_allowance,
                            diagnostics=matte_diagnostics,
                            reject_edge_contact=reject_edge_contact,
                            suitability_bounds=suitability_bounds,
                            background_attested=background_reference is not None,
                            background_rgb=background_rgb,
                        )
                        metrics = frame_quality(
                            rgba,
                            max_green_edge_ratio=max_green_edge_ratio,
                            max_magenta_edge_ratio=max_magenta_edge_ratio,
                            max_green_edge_excess=max_green_edge_excess,
                            max_magenta_edge_excess=max_magenta_edge_excess,
                            source_edge_alpha_floor=source_edge_alpha_floor,
                            require_foreground=not allow_empty_frame,
                        )
                    except FrameQualityError as exc:
                        raise FrameQualityError(
                            f"source frame {frame_number}: {exc}"
                        ) from exc
                    try:
                        _write_all_with_deadline(
                            encoder.stdin,
                            rgba.tobytes(),
                            deadline=stage_deadline,
                        )
                        alpha_handle.write(rgba[:, :, 3].tobytes())
                    except (BrokenPipeError, OSError) as exc:
                        raise AlphaConversionError(
                            "ffmpeg ProRes encoder closed its input"
                        ) from exc
                    if first_rgba is None:
                        first_rgba = rgba.copy()
                    last_rgba = rgba
                    frames_checked += 1
                    if progress is not None:
                        progress.emit(
                            10 + round(45 * frames_checked / info.frame_count),
                            stage="matte",
                            message="Matting source frames",
                            frame_completed=frames_checked,
                            frame_total=info.frame_count,
                        )
                    max_edge_alpha = max(
                        max_edge_alpha, int(metrics["outer_edge_alpha_maximum"])
                    )
                    max_magenta_ratio = max(
                        max_magenta_ratio, float(metrics["magenta_edge_ratio"])
                    )
                    max_green_ratio = max(
                        max_green_ratio, float(metrics["green_edge_ratio"])
                    )
                    max_green_excess = max(
                        max_green_excess, int(metrics["green_edge_max_excess"])
                    )
                    max_magenta_excess = max(
                        max_magenta_excess, int(metrics["magenta_edge_max_excess"])
                    )
                    max_preclean_edge_alpha = max(
                        max_preclean_edge_alpha,
                        int(matte_diagnostics["preclean_outer_edge_alpha_maximum"]),
                    )
                    preclean_edge_contact_total += int(
                        matte_diagnostics["preclean_outer_edge_contact_pixels"]
                    )
                    semitransparent_total += int(metrics["semitransparent_edge_pixels"])
                    foreground_pixels = int(metrics["foreground_pixels"])
                    foreground_total += foreground_pixels
                    if foreground_pixels == 0:
                        empty_frame_count += 1
                        consecutive_empty_frames += 1
                        maximum_consecutive_empty_frames = max(
                            maximum_consecutive_empty_frames,
                            consecutive_empty_frames,
                        )
                    else:
                        consecutive_empty_frames = 0
                alpha_handle.flush()
                os.fsync(alpha_handle.fileno())
                if background_handle is not None and background_handle.read(1):
                    raise AlphaConversionError(
                        "source background reference contains extra frames"
                    )
        except OSError as exc:
            raise AlphaConversionError("unable to write matte alpha reference") from exc
        encoder.stdin.close()
        try:
            remaining_timeout = max(0.001, stage_deadline - time.monotonic())
            return_code = encoder.wait(timeout=remaining_timeout)
        except subprocess.TimeoutExpired as exc:
            raise AlphaConversionError("ffmpeg ProRes encoding timed out") from exc
        if return_code != 0:
            raise AlphaConversionError(
                f"ffmpeg ProRes 4444 encoding failed (exit {return_code})"
            )
    except BaseException:
        close_process(decoder)
        close_process(encoder)
        raise
    finally:
        close_process(decoder)
        close_process(encoder)
    if frames_checked != info.frame_count:
        raise AlphaConversionError(
            f"matted {frames_checked} frames but expected {info.frame_count}"
        )
    if not intermediate.is_file() or intermediate.stat().st_size == 0:
        raise AlphaConversionError("ffmpeg produced no ProRes 4444 intermediate")
    expected_size = info.frame_count * width * height
    try:
        reference_size = reference_alpha.stat().st_size
    except OSError as exc:
        raise AlphaConversionError("unable to inspect matte alpha reference") from exc
    if reference_size != expected_size:
        raise AlphaConversionError("matte alpha reference has an unexpected size")
    if first_rgba is None or last_rgba is None:
        raise AlphaConversionError("source produced no frames for loop seam analysis")
    if foreground_total == 0:
        raise FrameQualityError("matted animation contains no foreground pixels")
    return {
        "frames_checked": frames_checked,
        "expected_frames": info.frame_count,
        "maximum_outer_edge_alpha": max_edge_alpha,
        "preclean_outer_edge_alpha_maximum": max_preclean_edge_alpha,
        "preclean_outer_edge_contact_pixels": preclean_edge_contact_total,
        "maximum_green_edge_ratio": max_green_ratio,
        "maximum_magenta_edge_ratio": max_magenta_ratio,
        "maximum_green_edge_excess": max_green_excess,
        "maximum_magenta_edge_excess": max_magenta_excess,
        "source_edge_limits": {
            "max_green_edge_ratio": max_green_edge_ratio,
            "max_magenta_edge_ratio": max_magenta_edge_ratio,
            "max_green_edge_excess": max_green_edge_excess,
            "max_magenta_edge_excess": max_magenta_edge_excess,
            "source_edge_alpha_floor": source_edge_alpha_floor,
        },
        "semitransparent_edge_pixels": semitransparent_total,
        "foreground_pixels": foreground_total,
        "empty_frames": empty_frame_count,
        "maximum_consecutive_empty_frames": maximum_consecutive_empty_frames,
        "loop_seam": _loop_seam_diagnostics(first_rgba, last_rgba),
        "quality_passed": True,
    }


def _verify_basic_info(
    actual: VideoInfo,
    expected: VideoInfo,
    *,
    expected_codec: str | None = None,
    label: str,
) -> dict[str, Any]:
    """Require exact geometry, frame count, and constant rate for one stage."""

    if expected_codec is not None and actual.codec_name.lower() != expected_codec.lower():
        raise FrameQualityError(
            f"{label} codec is {actual.codec_name}, expected {expected_codec}"
        )
    if actual.width != expected.width or actual.height != expected.height:
        raise FrameQualityError(
            f"{label} geometry is {actual.width}x{actual.height}; "
            f"expected {expected.width}x{expected.height}"
        )
    if actual.frame_count != expected.frame_count:
        raise FrameQualityError(
            f"{label} contains {actual.frame_count} frames; expected {expected.frame_count}"
        )
    if actual.fps != expected.fps:
        raise FrameQualityError(
            f"{label} frame rate is {actual.fps_text}; expected {expected.fps_text}"
        )
    if actual.audio_codecs:
        raise FrameQualityError(
            f"{label} contains audio streams; verified animation artifacts must be silent"
        )
    return {
        "codec": actual.codec_name,
        "profile": actual.codec_profile,
        "pixel_format": actual.pixel_format,
        "width": actual.width,
        "height": actual.height,
        "frames": actual.frame_count,
        "fps": actual.fps_text,
        "duration_seconds": actual.duration_seconds,
        "audio_streams": 0,
        "quality_passed": True,
    }


def _read_alpha_reference(handle: Any, *, width: int, height: int) -> Any:
    import numpy as np

    raw = handle.read(width * height)
    if len(raw) != width * height:
        raise AlphaConversionError("matte alpha reference is truncated")
    return np.frombuffer(raw, dtype=np.uint8).reshape(height, width).copy()


class _RoundtripMetricsAccumulator:
    """Keep all-frame verification evidence in bounded aggregate storage."""

    def __init__(self) -> None:
        self.frames = 0
        self.alpha_mean_max = 0.0
        self.alpha_p95_max = 0.0
        self.alpha_absolute_max = 0
        self.alpha_lost_total = 0
        self.composite_maxima = {
            "maximum_delivery_green_fringe_ratio": 0.0,
            "maximum_delivery_magenta_fringe_ratio": 0.0,
            "maximum_introduced_green_fringe_ratio": 0.0,
            "maximum_introduced_magenta_fringe_ratio": 0.0,
            "maximum_introduced_green_fringe_excess": 0,
            "maximum_introduced_magenta_fringe_excess": 0,
        }
        self.backgrounds: dict[str, dict[str, int | float]] = {}

    def add(self, comparison: dict[str, Any], composite: dict[str, Any]) -> None:
        self.frames += 1
        self.alpha_mean_max = max(
            self.alpha_mean_max, float(comparison["mean_absolute_error"])
        )
        self.alpha_p95_max = max(
            self.alpha_p95_max, float(comparison["p95_absolute_error"])
        )
        self.alpha_absolute_max = max(
            self.alpha_absolute_max, int(comparison["maximum_absolute_error"])
        )
        self.alpha_lost_total += int(comparison["lost_alpha_pixels"])
        for key in self.composite_maxima:
            value = composite[key]
            self.composite_maxima[key] = max(self.composite_maxima[key], value)
        for name in composite["background_names"]:
            item = composite["backgrounds"][name]
            aggregate = self.backgrounds.setdefault(
                name,
                {
                    "frames_checked": 0,
                    "maximum_delivery_green_fringe_ratio": 0.0,
                    "maximum_delivery_magenta_fringe_ratio": 0.0,
                    "maximum_introduced_green_fringe_ratio": 0.0,
                    "maximum_introduced_magenta_fringe_ratio": 0.0,
                    "green_fringe_pixels_total": 0,
                    "maximum_delivery_green_fringe_excess": 0,
                    "maximum_introduced_green_fringe_excess": 0,
                    "magenta_fringe_pixels_total": 0,
                    "maximum_delivery_magenta_fringe_excess": 0,
                    "maximum_introduced_magenta_fringe_excess": 0,
                },
            )
            aggregate["frames_checked"] = int(aggregate["frames_checked"]) + 1
            mappings = {
                "maximum_delivery_green_fringe_ratio": "green_fringe_ratio",
                "maximum_delivery_magenta_fringe_ratio": "magenta_fringe_ratio",
                "maximum_introduced_green_fringe_ratio": "introduced_green_fringe_ratio",
                "maximum_introduced_magenta_fringe_ratio": "introduced_magenta_fringe_ratio",
                "maximum_delivery_green_fringe_excess": "green_fringe_max_excess",
                "maximum_introduced_green_fringe_excess": "introduced_green_fringe_max_excess",
                "maximum_delivery_magenta_fringe_excess": "magenta_fringe_max_excess",
                "maximum_introduced_magenta_fringe_excess": "introduced_magenta_fringe_max_excess",
            }
            for target, source in mappings.items():
                aggregate[target] = max(aggregate[target], item[source])
            aggregate["green_fringe_pixels_total"] = int(
                aggregate["green_fringe_pixels_total"]
            ) + int(item["green_fringe_pixels"])
            aggregate["magenta_fringe_pixels_total"] = int(
                aggregate["magenta_fringe_pixels_total"]
            ) + int(item["magenta_fringe_pixels"])

    def snapshot(self) -> dict[str, Any]:
        """Return the stable report fields without exposing per-frame storage."""

        return {
            "frames": self.frames,
            "backgrounds": self.backgrounds,
            "composite_maxima": dict(self.composite_maxima),
            "alpha": {
                "mean_absolute_error_max": self.alpha_mean_max,
                "p95_absolute_error_max": self.alpha_p95_max,
                "maximum_absolute_error_max": self.alpha_absolute_max,
                "lost_alpha_pixels_total": self.alpha_lost_total,
            },
        }


def _verify_alpha_roundtrip(
    delivery: Path,
    reference_alpha: Path,
    *,
    reference_video: Path,
    expected: VideoInfo,
    avconvert: str,
    ffprobe: str,
    ffmpeg: str,
    max_border_alpha: int,
    max_green_edge_ratio: float,
    max_magenta_edge_ratio: float,
    source_edge_alpha_floor: int,
    max_mean_abs_error: float,
    max_p95_abs_error: float,
    max_abs_error: int,
    loss_threshold: int,
    max_green_fringe_ratio: float = DEFAULT_MAX_GREEN_FRINGE_RATIO,
    max_magenta_fringe_ratio: float = DEFAULT_MAX_MAGENTA_FRINGE_RATIO,
    fringe_channel_excess: int = DEFAULT_FRINGE_CHANNEL_EXCESS,
    max_introduced_green_fringe_excess: int = (
        DEFAULT_MAX_INTRODUCED_GREEN_FRINGE_EXCESS
    ),
    max_introduced_magenta_fringe_excess: int = (
        DEFAULT_MAX_INTRODUCED_MAGENTA_FRINGE_EXCESS
    ),
    require_foreground: bool = True,
    progress: _ProgressReporter | None = None,
    timeout_seconds: float = DEFAULT_PROCESS_TIMEOUT_SECONDS,
    frame_sync_mode: str = "fps_mode",
) -> dict[str, Any]:
    """Prove HEVC alpha and visual fidelity through lockstep Apple round-trips."""

    if not reference_video.is_file():
        raise AlphaConversionError("ProRes reference video is missing")
    if progress is not None:
        progress.emit(
            72,
            stage="verify",
            message="Probing HEVC-alpha delivery",
        )
    delivery_info = probe_video(
        delivery,
        ffprobe=ffprobe,
        enforce_source_color_policy=False,
        timeout_seconds=min(timeout_seconds, 30.0),
    )
    delivery_cadence = verify_video_cadence(
        delivery,
        delivery_info,
        label="HEVC delivery",
        allow_packet_fallback=True,
        ffprobe=ffprobe,
        timeout_seconds=min(timeout_seconds, 30.0),
    )
    delivery_report = _verify_basic_info(
        delivery_info, expected, expected_codec="hevc", label="HEVC delivery"
    )
    delivery_report["cadence"] = delivery_cadence
    try:
        reference_size = reference_alpha.stat().st_size
    except OSError as exc:
        raise AlphaConversionError("unable to inspect matte alpha reference") from exc
    if reference_size != expected.frame_count * expected.width * expected.height:
        raise AlphaConversionError("matte alpha reference has an unexpected size")
    with tempfile.TemporaryDirectory(prefix="codex-pet-alpha-verify-") as temp_name:
        roundtrip = Path(temp_name) / "roundtrip.prores4444.mov"
        if progress is not None:
            progress.emit(
                75,
                stage="verify",
                message="Running Apple alpha round-trip",
            )
        _run_avconvert(
            delivery,
            roundtrip,
            avconvert=avconvert,
            preset=ROUNDTRIP_PRESET,
            timeout_seconds=timeout_seconds,
        )
        if progress is not None:
            progress.emit(
                79,
                stage="verify",
                message="Probing Apple alpha round-trip",
            )
        roundtrip_info = probe_video(
            roundtrip,
            ffprobe=ffprobe,
            enforce_source_color_policy=False,
            timeout_seconds=min(timeout_seconds, 30.0),
        )
        roundtrip_cadence = verify_video_cadence(
            roundtrip,
            roundtrip_info,
            label="ProRes alpha round-trip",
            ffprobe=ffprobe,
            timeout_seconds=min(timeout_seconds, 30.0),
        )
        roundtrip_report = _verify_basic_info(
            roundtrip_info, expected, expected_codec="prores", label="ProRes alpha round-trip"
        )
        roundtrip_report["cadence"] = roundtrip_cadence
        if "4444" not in roundtrip_info.codec_profile.lower() and not roundtrip_info.pixel_format.lower().startswith("yuva"):
            raise FrameQualityError(
                "ProRes alpha round-trip is not an alpha-capable 4444 stream"
            )
        reference_decoder: Any | None = None
        decoder: Any | None = None
        reference_decoder, decoder = _start_rgba_decoder_pair(
            reference_video,
            roundtrip,
            width=expected.width,
            height=expected.height,
            ffmpeg=ffmpeg,
            frame_sync_mode=frame_sync_mode,
        )
        frames_verified = 0
        max_border = 0
        max_green = 0.0
        max_magenta = 0.0
        metrics = _RoundtripMetricsAccumulator()
        reference_frames = read_raw_frames(
            reference_decoder,
            width=expected.width,
            height=expected.height,
            expected_frames=expected.frame_count,
            channels=4,
            timeout_seconds=timeout_seconds,
        )
        delivery_frames = read_raw_frames(
            decoder,
            width=expected.width,
            height=expected.height,
            expected_frames=expected.frame_count,
            channels=4,
            timeout_seconds=timeout_seconds,
        )
        try:
            try:
                with reference_alpha.open("rb") as reference_handle:
                    for _frame_index in range(expected.frame_count):
                        try:
                            reference_rgba = next(reference_frames)
                            rgba = next(delivery_frames)
                        except StopIteration as exc:
                            raise AlphaConversionError(
                                "reference or Apple round-trip RGBA stream ended early"
                            ) from exc
                        expected_alpha = _read_alpha_reference(
                            reference_handle, width=expected.width, height=expected.height
                        )
                        quality = frame_quality(
                            rgba,
                            reference_rgba=reference_rgba,
                            max_green_edge_ratio=max_green_edge_ratio,
                            max_magenta_edge_ratio=max_magenta_edge_ratio,
                            source_edge_alpha_floor=source_edge_alpha_floor,
                            require_foreground=require_foreground,
                            max_outer_edge_alpha=max_border_alpha,
                        )
                        composite = composite_quality(
                            rgba,
                            reference_rgba=reference_rgba,
                            max_green_fringe_ratio=max_green_fringe_ratio,
                            max_magenta_fringe_ratio=max_magenta_fringe_ratio,
                            channel_excess=fringe_channel_excess,
                            max_introduced_green_fringe_excess=(
                                max_introduced_green_fringe_excess
                            ),
                            max_introduced_magenta_fringe_excess=(
                                max_introduced_magenta_fringe_excess
                            ),
                            require_foreground=require_foreground,
                        )
                        comparison = compare_alpha_planes(
                            expected_alpha,
                            rgba[:, :, 3],
                            max_mean_abs_error=max_mean_abs_error,
                            max_p95_abs_error=max_p95_abs_error,
                            max_abs_error=max_abs_error,
                            loss_threshold=loss_threshold,
                        )
                        frames_verified += 1
                        if progress is not None:
                            progress.emit(
                                80
                                + round(
                                    15 * frames_verified / expected.frame_count
                                ),
                                stage="verify",
                                message="Verifying Apple alpha frames",
                                frame_completed=frames_verified,
                                frame_total=expected.frame_count,
                            )
                        max_border = max(
                            max_border, int(quality["outer_edge_alpha_maximum"])
                        )
                        max_magenta = max(
                            max_magenta, float(quality["magenta_edge_ratio"])
                        )
                        max_green = max(
                            max_green, float(quality["green_edge_ratio"])
                        )
                        metrics.add(comparison, composite)
                    # Force both generators to read EOF and wait so a shorter
                    # or longer reference stream cannot be silently accepted.
                    try:
                        next(reference_frames)
                    except StopIteration:
                        pass
                    else:
                        raise AlphaConversionError(
                            "ProRes reference RGBA stream contains more frames than expected"
                        )
                    try:
                        next(delivery_frames)
                    except StopIteration:
                        pass
                    else:
                        raise AlphaConversionError(
                            "Apple round-trip RGBA stream contains more frames than expected"
                        )
                    if reference_handle.read(1):
                        raise AlphaConversionError(
                            "matte alpha reference contains more frames than expected"
                        )
            except OSError as exc:
                raise AlphaConversionError("unable to read matte alpha reference") from exc
        finally:
            if reference_decoder is not None:
                close_process(reference_decoder)
            if decoder is not None:
                close_process(decoder)
    if frames_verified != expected.frame_count:
        raise AlphaConversionError(
            f"round-trip decoded {frames_verified} frames; expected {expected.frame_count}"
        )
    if metrics.frames == 0:
        raise AlphaConversionError("round-trip produced no composite quality metrics")
    metric_summary = metrics.snapshot()
    backgrounds = metric_summary["backgrounds"]
    composite_maxima = metric_summary["composite_maxima"]
    alpha_summary = metric_summary["alpha"]
    maximum_delivery_green_fringe = float(
        composite_maxima["maximum_delivery_green_fringe_ratio"]
    )
    maximum_delivery_magenta_fringe = float(
        composite_maxima["maximum_delivery_magenta_fringe_ratio"]
    )
    maximum_introduced_green_fringe = float(
        composite_maxima["maximum_introduced_green_fringe_ratio"]
    )
    maximum_introduced_magenta_fringe = float(
        composite_maxima["maximum_introduced_magenta_fringe_ratio"]
    )
    maximum_introduced_green_excess = int(
        composite_maxima["maximum_introduced_green_fringe_excess"]
    )
    maximum_introduced_magenta_excess = int(
        composite_maxima["maximum_introduced_magenta_fringe_excess"]
    )
    return {
        "performed": True,
        "unsafe": False,
        "delivery": delivery_report,
        "roundtrip": roundtrip_report,
        "frames_verified": frames_verified,
        "maximum_outer_edge_alpha": max_border,
        "maximum_introduced_green_edge_ratio": max_green,
        "maximum_introduced_magenta_edge_ratio": max_magenta,
        "direct_edge_limits": {
            "max_introduced_green_edge_ratio": max_green_edge_ratio,
            "max_introduced_magenta_edge_ratio": max_magenta_edge_ratio,
            "alpha_floor": source_edge_alpha_floor,
        },
        "composite": {
            "performed": True,
            "background_names": list(backgrounds),
            "frames_checked": frames_verified,
            "maximum_delivery_green_fringe_ratio": maximum_delivery_green_fringe,
            "maximum_delivery_magenta_fringe_ratio": maximum_delivery_magenta_fringe,
            "maximum_introduced_green_fringe_ratio": maximum_introduced_green_fringe,
            "maximum_introduced_magenta_fringe_ratio": maximum_introduced_magenta_fringe,
            "maximum_delivery_green_fringe_excess": max(
                int(item["maximum_delivery_green_fringe_excess"])
                for item in backgrounds.values()
            ),
            "maximum_delivery_magenta_fringe_excess": max(
                int(item["maximum_delivery_magenta_fringe_excess"])
                for item in backgrounds.values()
            ),
            "maximum_introduced_green_fringe_excess": maximum_introduced_green_excess,
            "maximum_introduced_magenta_fringe_excess": maximum_introduced_magenta_excess,
            "reference_comparison": True,
            "backgrounds": backgrounds,
            "limits": {
                "max_introduced_green_fringe_ratio": max_green_fringe_ratio,
                "max_introduced_magenta_fringe_ratio": max_magenta_fringe_ratio,
                "channel_excess": fringe_channel_excess,
                "max_introduced_green_fringe_excess": (
                    max_introduced_green_fringe_excess
                ),
                "max_introduced_magenta_fringe_excess": (
                    max_introduced_magenta_fringe_excess
                ),
            },
            "quality_passed": True,
        },
        "alpha": {
            **alpha_summary,
            "tolerances": {
                "max_border_alpha": max_border_alpha,
                "max_mean_abs_error": max_mean_abs_error,
                "max_p95_abs_error": max_p95_abs_error,
                "max_abs_error": max_abs_error,
                "loss_threshold": loss_threshold,
            },
        },
    }


def convert_video(
    args: argparse.Namespace, *, progress: _ProgressReporter | None = None
) -> dict[str, Any]:
    """Run conversion and return a path-free report."""

    progress = progress or _ProgressReporter(False)
    progress.emit(0, stage="prepare", message="Preparing conversion")
    require_image_dependencies()
    source = args.source.expanduser()
    output = args.output.expanduser()
    report_path = (args.report or _default_report_path(output)).expanduser()
    intermediate_target = (
        args.intermediate_output.expanduser() if args.intermediate_output else None
    )
    if args.keep_intermediate and intermediate_target is None:
        intermediate_target = _default_intermediate_path(output)
    _recover_publish_transaction(output, intermediate_target, report_path)
    _check_target_collisions(
        source,
        output,
        report_path,
        intermediate_target,
        replace=args.replace,
    )
    if (args.width is None) != (args.height is None):
        raise AlphaConversionError("--width and --height must be supplied together")
    if args.key_floor >= args.key_ceiling:
        raise AlphaConversionError("--key-floor must be less than --key-ceiling")
    if args.key_ceiling > 1.5:
        raise AlphaConversionError("--key-ceiling must not exceed 1.5")

    progress.emit(2, stage="prepare", message="Checking conversion tools")
    ffprobe = require_tool("ffprobe", args.ffprobe)
    ffmpeg = require_tool("ffmpeg", args.ffmpeg)
    avconvert = require_tool("avconvert", args.avconvert)
    tool_preflight = _preflight_tool_capabilities(
        ffmpeg=ffmpeg, ffprobe=ffprobe, avconvert=avconvert
    )
    frame_sync_mode = str(
        tool_preflight["capabilities"].get("ffmpeg_frame_sync", "fps_mode")
    )
    _preflight_source_size(source, max_source_bytes=args.max_source_bytes)
    # Bind the source before ffprobe and any decoder process starts.  The
    # digest is carried through the report and checked again immediately
    # before publication so a source edited in place cannot be paired with
    # artifacts produced from a different byte sequence.
    source_sha256_before_probe = _sha256_source_file(
        source, max_source_bytes=args.max_source_bytes
    )
    progress.emit(5, stage="probe", message="Probing source video")
    info = probe_video(
        source,
        ffprobe=ffprobe,
        timeout_seconds=min(args.process_timeout_seconds, 30.0),
        validate_timestamps=False,
    )
    progress.emit(10, stage="probe", message="Source video probe complete")
    requested_width = args.width or info.width
    requested_height = args.height or info.height
    width, height = _align_hevc_alpha_geometry(
        requested_width,
        requested_height,
    )
    geometry_alignment = {
        "requested_width": requested_width,
        "requested_height": requested_height,
        "policy": "floor_to_even",
        "adjusted": width != requested_width or height != requested_height,
    }
    resource_preflight = _preflight_resources(
        source,
        output,
        report_path,
        intermediate_target,
        info,
        width=width,
        height=height,
        max_source_bytes=args.max_source_bytes,
        max_source_pixels=args.max_source_pixels,
        max_source_frames=args.max_source_frames,
        max_source_duration_seconds=args.max_source_duration_seconds,
        max_source_fps=args.max_source_fps,
        min_free_disk_bytes=args.min_free_disk_bytes,
    )
    report_contract = _report_contract(args, tool_preflight=tool_preflight)

    if args.dry_run:
        decode_command = build_ffmpeg_decode_command(
            Path("source.mp4"),
            width=width,
            height=height,
            ffmpeg=ffmpeg,
            stream_index=info.stream_index,
            resize_mode=args.resize_mode,
            frame_sync_mode=frame_sync_mode,
        )
        prores_command = build_ffmpeg_prores_command(
            Path("intermediate.prores4444.mov"),
            width=width,
            height=height,
            fps=info.fps,
            ffmpeg=ffmpeg,
        )
        avconvert_command = build_avconvert_command(
            Path("intermediate.prores4444.mov"),
            Path("output.hevc-alpha.mov"),
            avconvert=avconvert,
            preset=args.preset,
        )
        report = {
            **report_contract,
            "status": "dry-run",
            "source": {
                "name": _safe_name(source),
                "codec": info.codec_name,
                "profile": info.codec_profile,
                "pixel_format": info.pixel_format,
                "bit_depth": info.bit_depth,
                "time_base": info.time_base,
                "width": info.width,
                "height": info.height,
                "frames": info.frame_count,
                "fps": info.fps_text,
                "duration_seconds": info.duration_seconds,
                "sample_aspect_ratio": info.sample_aspect_ratio,
                "audio": _source_audio_report(info),
                "stream_index": info.stream_index,
                "color": {
                    "primaries": info.color_primaries,
                    "transfer": info.color_transfer,
                    "space": info.color_space,
                    "range": info.color_range,
                    "field_order": info.field_order,
                },
            },
            "resource_preflight": resource_preflight,
            "geometry": {"width": width, "height": height},
            "geometry_alignment": geometry_alignment,
            "source_framing": {
                "resize_mode": (
                    SOURCE_RESIZE_MODE
                    if args.resize_mode == "fill"
                    else "aspect_fit_green_pad"
                ),
                "strict": bool(args.strict_source_framing),
                "edge_contact_policy": (
                    "reject"
                    if args.strict_source_framing
                    else "record_and_clear_output_border"
                ),
            },
            "verification": {
                "default": True,
                "roundtrip_preset": ROUNDTRIP_PRESET,
            },
            "commands": {
                "decode": _safe_command(decode_command),
                "prores": _safe_command(prores_command),
                "avconvert": _safe_command(avconvert_command),
            },
        }
        progress.emit(90, stage="publish", message="Publishing dry-run report")
        _write_json(report_path, report, replace=args.replace)
        progress.emit(
            100,
            stage="complete",
            message="Dry run complete",
            status="completed",
        )
        return report

    progress.emit(11, stage="probe", message="Verifying source frame cadence")
    cadence = verify_video_cadence(
        source,
        info,
        label="source",
        ffprobe=ffprobe,
        timeout_seconds=min(args.process_timeout_seconds, 30.0),
    )
    with tempfile.TemporaryDirectory(prefix="codex-pet-alpha-") as temp_name:
        temp_dir = Path(temp_name)
        temp_intermediate = temp_dir / "intermediate.prores4444.mov"
        reference_alpha = temp_dir / "matte-alpha.raw"
        background_reference = temp_dir / "source-background.rgb"
        progress.emit(12, stage="probe", message="Checking source background")
        source_background = _verify_source_background(
            source,
            background_reference=background_reference,
            info=info,
            ffmpeg=ffmpeg,
            timeout_seconds=args.process_timeout_seconds,
            progress=progress,
            frame_sync_mode=frame_sync_mode,
        )
        progress.emit(
            10,
            stage="matte",
            message="Matting source frames",
            frame_completed=0,
            frame_total=info.frame_count,
        )
        quality = _stream_matte_to_prores(
            source,
            temp_intermediate,
            reference_alpha,
            background_reference=background_reference,
            info=info,
            width=width,
            height=height,
            ffmpeg=ffmpeg,
            border_width=args.border_width,
            key_floor=args.key_floor,
            key_ceiling=args.key_ceiling,
            despill_strength=args.despill_strength,
            despill_allowance=args.despill_allowance,
            max_green_edge_ratio=args.max_green_edge_ratio,
            max_magenta_edge_ratio=args.max_magenta_edge_ratio,
            max_green_edge_excess=args.max_green_edge_excess,
            max_magenta_edge_excess=args.max_magenta_edge_excess,
            source_edge_alpha_floor=args.source_edge_alpha_floor,
            allow_empty_frame=args.allow_empty_frame,
            reject_edge_contact=args.strict_source_framing,
            timeout_seconds=args.process_timeout_seconds,
            resize_mode=args.resize_mode,
            progress=progress,
            frame_sync_mode=frame_sync_mode,
        )
        quality["source_cadence"] = cadence
        quality["source_background"] = source_background
        progress.emit(57, stage="probe", message="Probing ProRes intermediate")
        intermediate_info = probe_video(
            temp_intermediate,
            ffprobe=ffprobe,
            enforce_source_color_policy=False,
            timeout_seconds=min(args.process_timeout_seconds, 30.0),
        )
        intermediate_report = _verify_basic_info(
            intermediate_info,
            VideoInfo(
                width=width,
                height=height,
                frame_count=info.frame_count,
                fps=info.fps,
                duration_seconds=info.duration_seconds,
                codec_name="",
                pixel_format="",
            ),
            expected_codec="prores",
            label="ProRes intermediate",
        )
        intermediate_report["cadence"] = verify_video_cadence(
            temp_intermediate,
            intermediate_info,
            label="ProRes intermediate",
            ffprobe=ffprobe,
            timeout_seconds=min(args.process_timeout_seconds, 30.0),
        )
        if "4444" not in intermediate_info.codec_profile.lower() and not intermediate_info.pixel_format.lower().startswith("yuva"):
            raise FrameQualityError("ProRes intermediate does not retain an alpha plane")
        temp_output = temp_dir / "output.hevc-alpha.mov"
        progress.emit(62, stage="encode", message="Encoding HEVC with alpha")
        _run_avconvert(
            temp_intermediate,
            temp_output,
            avconvert=avconvert,
            preset=args.preset,
            timeout_seconds=args.process_timeout_seconds,
        )
        progress.emit(70, stage="encode", message="HEVC-alpha encode complete")
        verification = _verify_alpha_roundtrip(
            temp_output,
            reference_alpha,
            reference_video=temp_intermediate,
            expected=VideoInfo(
                width=width,
                height=height,
                frame_count=info.frame_count,
                fps=info.fps,
                duration_seconds=info.duration_seconds,
                codec_name="",
                pixel_format="",
            ),
            avconvert=avconvert,
            ffprobe=ffprobe,
            ffmpeg=ffmpeg,
            max_border_alpha=args.max_border_alpha,
            max_green_edge_ratio=DEFAULT_MAX_DELIVERY_EDGE_RATIO,
            max_magenta_edge_ratio=DEFAULT_MAX_DELIVERY_EDGE_RATIO,
            source_edge_alpha_floor=DEFAULT_DELIVERY_EDGE_ALPHA_FLOOR,
            max_mean_abs_error=args.alpha_mean_error,
            max_p95_abs_error=args.alpha_p95_error,
            max_abs_error=args.alpha_max_error,
            loss_threshold=args.alpha_loss_threshold,
            max_green_fringe_ratio=args.max_introduced_green_fringe_ratio,
            max_magenta_fringe_ratio=args.max_introduced_magenta_fringe_ratio,
            fringe_channel_excess=args.fringe_channel_excess,
            max_introduced_green_fringe_excess=(
                args.max_introduced_green_fringe_excess
            ),
            max_introduced_magenta_fringe_excess=(
                args.max_introduced_magenta_fringe_excess
            ),
            require_foreground=not args.allow_empty_frame,
            progress=progress,
            timeout_seconds=args.process_timeout_seconds,
            frame_sync_mode=frame_sync_mode,
        )

        delivery_sha256 = _sha256_file(temp_output)
        intermediate_sha256 = (
            _sha256_file(temp_intermediate) if intermediate_target is not None else None
        )
        report = {
            **report_contract,
            "status": "converted",
            "source": {
                "name": _safe_name(source),
                "codec": info.codec_name,
                "profile": info.codec_profile,
                "pixel_format": info.pixel_format,
                "bit_depth": info.bit_depth,
                "time_base": info.time_base,
                "width": info.width,
                "height": info.height,
                "frames": info.frame_count,
                "fps": info.fps_text,
                "duration_seconds": info.duration_seconds,
                "sample_aspect_ratio": info.sample_aspect_ratio,
                "audio": _source_audio_report(info),
                "stream_index": info.stream_index,
                "color": {
                    "primaries": info.color_primaries,
                    "transfer": info.color_transfer,
                    "space": info.color_space,
                    "range": info.color_range,
                    "field_order": info.field_order,
                },
            },
            "resource_preflight": resource_preflight,
            "geometry": {"width": width, "height": height, "pixel_format": "straight-rgba"},
            "geometry_alignment": geometry_alignment,
            "source_framing": {
                "resize_mode": (
                    SOURCE_RESIZE_MODE
                    if args.resize_mode == "fill"
                    else "aspect_fit_green_pad"
                ),
                "strict": bool(args.strict_source_framing),
                "edge_contact_policy": (
                    "reject"
                    if args.strict_source_framing
                    else "record_and_clear_output_border"
                ),
                "preclean_outer_edge_alpha_maximum": int(
                    quality.get("preclean_outer_edge_alpha_maximum", 0)
                ),
                "preclean_outer_edge_contact_pixels": int(
                    quality.get("preclean_outer_edge_contact_pixels", 0)
                ),
            },
            "matte": {
                "method": "dynamic-border-spatial-green-mixture-continuous-alpha",
                "border_width": args.border_width,
                "key_floor": args.key_floor,
                "key_ceiling": args.key_ceiling,
                "despill_strength": args.despill_strength,
                "despill_allowance": args.despill_allowance,
                "runtime_chroma_key": False,
            },
            "quality": quality,
            "codec": {
                "intermediate": "ProRes 4444",
                "intermediate_probe": intermediate_report,
                "delivery": "HEVC with alpha",
                "preset": sanitize_value(args.preset),
            },
            "verification": verification,
            "artifacts": {
                "source_name": _safe_name(source),
                "source_sha256": source_sha256_before_probe,
                "source_sha256_before_probe": source_sha256_before_probe,
                "source_sha256_before_publication": None,
                "output_name": _safe_name(output),
                "output_sha256": delivery_sha256,
                "intermediate_name": _safe_name(intermediate_target)
                if intermediate_target is not None
                else None,
                "intermediate_sha256": intermediate_sha256,
                "report_name": _safe_name(report_path),
            },
        }
        source_sha256_before_publication = _assert_source_unchanged(
            source,
            source_sha256_before_probe,
            max_source_bytes=args.max_source_bytes,
        )
        report["artifacts"][
            "source_sha256_before_publication"
        ] = source_sha256_before_publication
        report["resource_preflight"]["publication_recheck"] = (
            _check_publication_disk_capacity(
                temp_output,
                output,
                temp_intermediate if intermediate_target is not None else None,
                intermediate_target,
                report_path,
                report,
                reserve_bytes=args.min_free_disk_bytes,
            )
        )
        progress.emit(98, stage="publish", message="Publishing verified artifacts")
        _publish_transaction(
            temp_output,
            output,
            temp_intermediate if intermediate_target is not None else None,
            intermediate_target,
            report_path,
            report,
            replace=args.replace,
        )
        progress.emit(
            100,
            stage="complete",
            message="Conversion complete",
            status="completed",
        )
        return report


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    progress = _ProgressReporter(args.progress_jsonl)
    try:
        report = convert_video(args, progress=progress)
    except (AlphaConversionError, ValueError) as exc:
        progress.failed(exc)
        if args.progress_jsonl:
            print(f"error: {_safe_report_value(str(exc))}", file=sys.stderr)
        else:
            print(f"error: {exc}", file=sys.stderr)
        return 2
    if not args.progress_jsonl:
        print(json.dumps(_safe_report_value(report), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
