#!/usr/bin/env python3
"""Offline green-screen matting and macOS alpha-video helpers.

This module deliberately keeps chroma-key work out of the runtime player.  A
source MP4 is decoded once, matted to straight RGBA, and sent to a ProRes 4444
intermediate before Apple's ``avconvert`` creates the HEVC-with-alpha delivery
movie.  The public helpers are small enough to unit-test with synthetic frames
without requiring a real/private character video.
"""

from __future__ import annotations

import contextlib
import json
import math
import os
import re
import selectors
import shutil
import subprocess
import tempfile
import time
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

try:  # Keep importable so command/error tests can run on minimal hosts.
    import numpy as np
except ImportError as exc:  # pragma: no cover - exercised by host error tests
    np = None  # type: ignore[assignment]
    _NUMPY_ERROR = exc
else:
    _NUMPY_ERROR = None

try:  # Pillow is part of the supported authoring environment.
    from PIL import Image
except ImportError as exc:  # pragma: no cover - exercised by host error tests
    Image = None  # type: ignore[assignment,misc]
    _PIL_ERROR = exc
else:
    _PIL_ERROR = None


class AlphaConversionError(RuntimeError):
    """Base class for errors that should be shown as a concise CLI failure."""


class MissingToolError(AlphaConversionError):
    """A required external executable is unavailable."""


class MissingDependencyError(AlphaConversionError):
    """NumPy or Pillow is unavailable in the selected Python environment."""


class ProbeError(AlphaConversionError):
    """The source media does not satisfy the conversion contract."""


class FrameQualityError(AlphaConversionError):
    """A matted frame violates the transparent-video quality contract."""


# HEVC-with-alpha is intentionally accepted only after an Apple decode
# round-trip.  These limits are measured in 8-bit alpha units and are
# deliberately conservative for the high-quality preset: a tiny amount of
# codec ringing is acceptable, but a meaningful foreground pixel may never
# disappear.  Keep the tolerances visible in reports so a release review can
# distinguish a normal codec budget from an unverified external artifact.
# Apple HEVC-alpha can ring a source-zero border by a few alpha units.  Real
# 320x480 clips measured 9, 12, and 14 after round-trip; 16 accepts that faint
# codec halo while remaining below the meaningful-alpha threshold of 20.
DEFAULT_MAX_BORDER_ALPHA = 16
DEFAULT_ALPHA_MEAN_ABS_ERROR = 8.0
DEFAULT_ALPHA_P95_ABS_ERROR = 24.0
DEFAULT_ALPHA_MAX_ABS_ERROR = 64
# Apple's HEVC-alpha round-trip can quantize an isolated ~18/255 fringe pixel
# to zero even at the highest-quality preset.  Treat values up to 20 as
# non-meaningful while still rejecting a genuinely visible alpha loss.
DEFAULT_ALPHA_LOSS_THRESHOLD = 20

# Straight-alpha RGB is undefined where opacity is close to zero.  A green
# screen reconstruction can therefore extrapolate wildly (often to clipped
# magenta) for a one-pixel compression/background mismatch.  Copying colour
# from nearby retained foreground pixels keeps those soft edges compositing
# safely without changing their alpha values.
DEFAULT_EDGE_RGB_SOURCE_ALPHA = 80
DEFAULT_EDGE_RGB_BLEED_RADIUS = 3
# Colour repair and hue corroboration are separate budgets.  Repairing a
# three-pixel low-alpha extrapolation does not allow distant opaque colour to
# excuse a contaminated semitransparent edge.
DEFAULT_EDGE_HUE_SUPPORT_RADIUS = 2
DEFAULT_SOURCE_EDGE_ALPHA_FLOOR = 64
# A frame edge is safety padding, not a crop boundary.  Treat only opacity
# above the alpha-loss budget as meaningful contact; tiny codec/background
# noise remains eligible for the normal transparent-edge cleanup.
DEFAULT_MATTE_EDGE_CONTACT_ALPHA = DEFAULT_ALPHA_LOSS_THRESHOLD

# Source effects get more latitude than codec-introduced fringes.  These
# source-only limits accept stronger translucent AI effects while remaining
# bounded enough to catch a matte that retains most of the green background.
DEFAULT_MAX_SOURCE_EDGE_RATIO = 0.15
# Delivery frames are compared against the ProRes reference and keep the
# original direct-RGBA tolerance.  Source authoring flags must never weaken
# this codec-corruption boundary.
DEFAULT_MAX_DELIVERY_EDGE_RATIO = 0.05
DEFAULT_DELIVERY_EDGE_ALPHA_FLOOR = 64

# Composite gates deliberately use neutral light/dark/checkerboard backgrounds
# so a chroma spill is measurable without assuming the character's intended
# colours.  The ratio is evaluated over every semitransparent pixel in every
# decoded frame; a clip that contains a meaningful translucent green or
# magenta fringe therefore cannot pass on a sample-only visual check.
DEFAULT_MAX_GREEN_FRINGE_RATIO = 0.05
DEFAULT_MAX_MAGENTA_FRINGE_RATIO = 0.05
DEFAULT_FRINGE_CHANNEL_EXCESS = 24
# Apple may quantize an edge by a few dozen channel values, but a large
# localized increase is a real spill/halo even when a ratio is diluted by a
# large number of harmless semitransparent pixels.  These maxima are measured
# on the *introduced* excess relative to the ProRes reference, not on intended
# saturated foreground colour.  The authorized 241-frame Apple run measured
# maxima of 18 green and 35 magenta introduced excess; 64 leaves codec margin
# without allowing the severe localized contamination covered by the tests.
DEFAULT_MAX_INTRODUCED_GREEN_FRINGE_EXCESS = 64
DEFAULT_MAX_INTRODUCED_MAGENTA_FRINGE_EXCESS = 64
# Meaningful source-edge gates use the same alpha floor as the measured
# authorized clip.  Its unsupported magenta maximum was 58 at this floor;
# 96 admits stronger authored effects without changing the stricter
# delivery-introduced codec limits above.
DEFAULT_MAX_UNSUPPORTED_GREEN_EDGE_EXCESS = 96
DEFAULT_MAX_UNSUPPORTED_MAGENTA_EDGE_EXCESS = 96
DEFAULT_CHECKERBOARD_TILE = 24
SOURCE_RESIZE_MODE = "aspect_fill_center_crop"
DEFAULT_PROBE_TIMEOUT_SECONDS = 30.0
DEFAULT_PROCESS_TIMEOUT_SECONDS = 900.0
DEFAULT_MIN_GREEN_BORDER_RATIO = 0.50
DEFAULT_GREEN_BORDER_EXCESS = 24
DEFAULT_MIN_GREEN_SOURCE_RATIO = 0.05
DEFAULT_MIN_GREEN_SOURCE_BORDER_RATIO = 0.02
DEFAULT_MIN_GREEN_SOURCE_AXIS_COVERAGE = 0.50
DEFAULT_MIN_GREEN_CONNECTED_RATIO = 0.08


@dataclass(frozen=True)
class VideoInfo:
    """The private-path-free properties needed for deterministic conversion."""

    width: int
    height: int
    frame_count: int
    fps: Fraction
    duration_seconds: float
    codec_name: str
    pixel_format: str
    codec_profile: str = "unknown"
    sample_aspect_ratio: str = "1:1"
    audio_codecs: tuple[str, ...] = ()
    stream_index: int = 0
    color_primaries: str = "unknown"
    color_transfer: str = "unknown"
    color_space: str = "unknown"
    color_range: str = "unknown"
    field_order: str = "progressive"
    bit_depth: int = 8
    time_base: str = "unknown"

    @property
    def fps_text(self) -> str:
        return f"{self.fps.numerator}/{self.fps.denominator}"


_QUOTED_LOCAL_PATH = re.compile(
    r"(?i)(?P<quote>['\"])(?P<path>(?:file://)?(?:~|/(?:Users|Volumes|private|"
    r"tmp|var|opt|Applications|Library|System|usr))(?:/[^'\"\r\n]*)?)"
    r"(?P=quote)"
)
_UNQUOTED_LOCAL_PATH = re.compile(
    r"(?i)(?<![a-z0-9:/])(?:(?:file://)?(?:~|/(?:Users|Volumes|private|tmp|var|"
    r"opt|Applications|Library|System|usr))(?:/[^\r\n]*)?)"
)


def _looks_like_path(value: str) -> bool:
    """Return whether a command/report token can disclose a filesystem path."""

    if not value:
        return False
    if value.startswith(("/", "~", "\\")):
        return True
    # Do not mistake frame-rate fractions (for example ``24/1``) for paths.
    if (
        "/" in value
        and not any(character.isspace() for character in value)
        and not re.fullmatch(r"[+-]?\d+/[+-]?\d+", value)
    ):
        return True
    return False


def sanitize_value(value: Any) -> Any:
    """Remove private absolute paths from a command/report value.

    Execution commands retain their real paths internally.  This helper is
    used at the report boundary and in dry-run output; path-like strings are
    reduced to basenames while ordinary values (including ``24/1`` frame
    rates) remain unchanged.
    """

    if isinstance(value, Path):
        return value.name
    if isinstance(value, str) and _looks_like_path(value):
        return Path(value).name
    return value


def sanitize_text(value: str) -> str:
    """Redact embedded local paths without truncating ordinary slash prose."""

    quoted = _QUOTED_LOCAL_PATH.sub(
        lambda match: f"{match.group('quote')}<local-file>{match.group('quote')}",
        value,
    )
    return _UNQUOTED_LOCAL_PATH.sub("<local-file>", quoted)


def sanitize_command(command: Sequence[Any]) -> list[Any]:
    """Return a path-free command suitable for a public report or dry-run."""

    return [sanitize_value(value) for value in command]


def _require_numpy() -> Any:
    if np is None:
        detail = f": {_NUMPY_ERROR}" if _NUMPY_ERROR else ""
        raise MissingDependencyError(
            "NumPy is required for offline alpha conversion" + detail
        )
    return np


def require_image_dependencies() -> None:
    """Fail early with an actionable message when image dependencies are absent."""

    _require_numpy()
    if Image is None:
        detail = f": {_PIL_ERROR}" if _PIL_ERROR else ""
        raise MissingDependencyError(
            "Pillow is required for offline alpha conversion" + detail
        )


def require_tool(name: str, executable: str | os.PathLike[str] | None = None) -> str:
    """Resolve an executable or raise without leaking a private media path."""

    candidate = str(executable or name)
    resolved = shutil.which(candidate)
    if resolved is None:
        raise MissingToolError(
            f"{name} is required for offline alpha conversion; "
            f"install it or pass --{name} PATH"
        )
    return resolved


def _parse_rate(value: Any, *, label: str) -> Fraction:
    if value is None or value in ("", "N/A", "0/0", 0, 0.0):
        raise ProbeError(f"video {label} is missing or invalid")
    try:
        if isinstance(value, str) and "/" in value:
            numerator, denominator = value.split("/", 1)
            rate = Fraction(int(numerator), int(denominator))
        else:
            rate = Fraction(str(value))
    except (ValueError, ZeroDivisionError) as exc:
        raise ProbeError(f"video {label} is not a valid frame rate") from exc
    if rate <= 0:
        raise ProbeError(f"video {label} must be positive")
    return rate


def build_ffprobe_command(
    source: Path | str,
    *,
    ffprobe: str = "ffprobe",
    include_frames: bool = True,
) -> list[str]:
    """Build the strict probe command used before any frame decoding."""

    entries = (
        "stream=index,codec_type,codec_name,profile,width,height,avg_frame_rate,"
        "r_frame_rate,nb_frames,nb_read_frames,duration,pix_fmt,sample_aspect_ratio,"
        "color_primaries,color_transfer,color_space,color_range,field_order,"
        "bits_per_raw_sample,time_base:"
        "stream_tags=rotate:stream_side_data=rotation:"
        "stream_disposition=attached_pic:format=duration"
    )
    if include_frames:
        entries += ":frame=stream_index,media_type,best_effort_timestamp_time,pkt_duration_time"
    command = [
        ffprobe,
        "-v",
        "error",
        "-count_frames",
        "-show_entries",
        entries,
        "-of",
        "json",
    ]
    if include_frames:
        command.append("-show_frames")
    command.append(str(source))
    return command


def _probe_failure(result: subprocess.CompletedProcess[str]) -> ProbeError:
    # ffprobe diagnostics can echo the private source path.  Keep the CLI error
    # stable and path-free; the full stderr remains available to a caller that
    # explicitly invokes ffprobe itself.
    return ProbeError(
        "ffprobe could not inspect the input video"
        + (f" (exit {result.returncode})" if result.returncode else "")
    )


def _normalized_sample_aspect_ratio(value: Any) -> str:
    """Return the square-pixel contract or reject explicit anamorphic input.

    ffprobe reports an omitted sample-aspect-ratio as ``N/A`` or ``0:1`` for
    ordinary square-pixel files.  Those unspecified values follow FFmpeg's
    square-pixel default.  Any explicit non-square value is rejected before
    decoding so ``setsar=1`` cannot silently change the displayed geometry.
    """

    if value in (None, "", "N/A", "0:1", "0/1"):
        return "1:1"
    text = str(value).strip()
    separator = ":" if ":" in text else "/" if "/" in text else None
    if separator is None:
        raise ProbeError("video sample aspect ratio is invalid")
    try:
        numerator_text, denominator_text = text.split(separator, 1)
        ratio = Fraction(int(numerator_text), int(denominator_text))
    except (ValueError, ZeroDivisionError) as exc:
        raise ProbeError("video sample aspect ratio is invalid") from exc
    if ratio != 1:
        raise ProbeError(
            "input video must use square pixels; normalize externally to sample aspect ratio 1:1, then retry"
        )
    return "1:1"


def _pixel_format_bit_depth(pixel_format: str) -> int | None:
    text = pixel_format.lower()
    match = re.fullmatch(r"ya(8|16|32)(?:le|be)?", text)
    if match:
        return int(match.group(1)) // 2
    match = re.fullmatch(r"(?:rgb|bgr)(24|30|36|48)(?:le|be)?", text)
    if match:
        return int(match.group(1)) // 3
    match = re.fullmatch(r"(?:rgba|bgra|argb|abgr)(32|64)(?:le|be)?", text)
    if match:
        return int(match.group(1)) // 4
    if re.fullmatch(r"nv20(?:le|be)?", text):
        return 10
    # FFmpeg's high-depth planar and packed names consistently carry the
    # per-component depth immediately before an optional endian suffix.  This
    # covers formats such as yuv420p10le, xyz12le, x2rgb10le, v210, and y216.
    match = re.search(r"(9|10|12|14|16)(?:le|be)?$", text)
    if match:
        return int(match.group(1))
    if re.fullmatch(
        r"(?:"
        r"yuvj?\d+p|yuva\d+p|gbrp|gbrap|gray8?|"
        r"nv12|nv21|nv16|nv24|"
        r"rgb24|bgr24|rgba|bgra|argb|abgr|rgb0|bgr0|0rgb|0bgr|"
        r"rgb(?:444|555|565)(?:le|be)?|bgr(?:444|555|565)(?:le|be)?|"
        r"yuyv422|uyvy422|uyyvyy411|pal8|monow|monob"
        r")",
        text,
    ):
        return 8
    return None


def _validate_video_timestamps(
    timestamps: Sequence[float],
    *,
    frame_count: int,
    fps: Fraction,
    time_base: str,
) -> float:
    if len(timestamps) != frame_count:
        raise ProbeError("ffprobe video timestamp count does not match decoded frame count")

    expected_delta = 1.0 / float(fps)
    try:
        time_base_seconds = float(_parse_rate(time_base, label="time base"))
    except ProbeError:
        time_base_seconds = 0.0
    tolerance = max(0.0005, expected_delta * 0.01, time_base_seconds * 1.1)

    for previous, current in zip(timestamps, timestamps[1:]):
        delta = current - previous
        if (
            not math.isfinite(delta)
            or delta <= 0
            or abs(delta - expected_delta) > tolerance
        ):
            raise ProbeError(
                "input video frame timestamps are not uniformly spaced "
                f"within {tolerance:.6f} seconds"
            )
    return tolerance


def _run_bounded_capture(
    command: list[str],
    *,
    timeout_seconds: float,
    stdout_limit: int,
    stderr_limit: int,
    overflow_message: str,
    timeout_message: str,
    total_limit: int | None = None,
) -> subprocess.CompletedProcess[str]:
    """Capture a child actively and terminate it at hard output/time bounds."""

    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    limits = {"stdout": stdout_limit, "stderr": stderr_limit}
    selector = selectors.DefaultSelector()
    try:
        assert process.stdout is not None and process.stderr is not None
        selector.register(process.stdout.fileno(), selectors.EVENT_READ, "stdout")
        selector.register(process.stderr.fileno(), selectors.EVENT_READ, "stderr")
        deadline = time.monotonic() + timeout_seconds
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ProbeError(timeout_message)
            events = selector.select(remaining)
            if not events:
                raise ProbeError(timeout_message)
            for key, _mask in events:
                chunk = os.read(key.fd, 65536)
                if not chunk:
                    selector.unregister(key.fd)
                    continue
                name = key.data
                buffers[name].extend(chunk)
                if len(buffers[name]) > limits[name] or (
                    total_limit is not None
                    and sum(len(buffer) for buffer in buffers.values()) > total_limit
                ):
                    raise ProbeError(overflow_message)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ProbeError(timeout_message)
        try:
            return_code = process.wait(timeout=remaining)
        except subprocess.TimeoutExpired as exc:
            raise ProbeError(timeout_message) from exc
    except BaseException:
        if process.poll() is None:
            with contextlib.suppress(OSError):
                process.kill()
            with contextlib.suppress(OSError, subprocess.TimeoutExpired):
                process.wait(timeout=2)
        raise
    finally:
        selector.close()
        for stream in (process.stdout, process.stderr):
            if stream is not None:
                with contextlib.suppress(OSError):
                    stream.close()
    return subprocess.CompletedProcess(
        command,
        return_code,
        buffers["stdout"].decode("utf-8", errors="replace"),
        buffers["stderr"].decode("utf-8", errors="replace"),
    )


def probe_video(
    source: Path | str,
    *,
    ffprobe: str = "ffprobe",
    runner: Any = subprocess.run,
    timeout_seconds: float = DEFAULT_PROBE_TIMEOUT_SECONDS,
    validate_timestamps: bool | None = None,
    enforce_source_color_policy: bool = True,
) -> VideoInfo:
    """Probe and validate one CFR video stream before starting the matte pass."""

    source_path = Path(source)
    if validate_timestamps is None:
        validate_timestamps = False
    if not source_path.is_file():
        raise ProbeError("input video does not exist or is not a regular file")
    executable = require_tool("ffprobe", ffprobe)
    command = build_ffprobe_command(
        source_path, ffprobe=executable, include_frames=validate_timestamps
    )
    try:
        if runner is subprocess.run:
            result = _run_bounded_capture(
                command,
                timeout_seconds=timeout_seconds,
                stdout_limit=16 * 1024 * 1024,
                stderr_limit=4096,
                total_limit=16 * 1024 * 1024,
                overflow_message="ffprobe metadata exceeds the supported size",
                timeout_message="ffprobe timed out while inspecting the input video",
            )
        else:
            result = runner(
                command,
                check=False,
                capture_output=True,
                text=True,
                timeout=timeout_seconds,
            )
    except subprocess.TimeoutExpired as exc:
        raise ProbeError("ffprobe timed out while inspecting the input video") from exc
    except OSError as exc:
        raise ProbeError("unable to execute ffprobe") from exc
    if result.returncode != 0:
        raise _probe_failure(result)
    try:
        payload = json.loads(result.stdout)
    except (TypeError, ValueError) as exc:
        raise ProbeError("ffprobe returned invalid JSON") from exc

    streams = payload.get("streams")
    if not isinstance(streams, list):
        raise ProbeError("ffprobe did not return a stream list")
    # MP4/MOV files may carry cover art as an attached video stream.  It is not
    # a playable video and must not make a valid source fail the one-video rule.
    video_streams = [
        stream
        for stream in streams
        if stream.get("codec_type") == "video"
        and not bool((stream.get("disposition") or {}).get("attached_pic"))
    ]
    if len(video_streams) != 1:
        raise ProbeError(
            "input video must contain exactly one video stream "
            f"(found {len(video_streams)})"
        )
    stream = video_streams[0]
    try:
        stream_index = int(stream.get("index", 0))
    except (TypeError, ValueError) as exc:
        raise ProbeError("video stream index is invalid") from exc
    sample_aspect_ratio = _normalized_sample_aspect_ratio(
        stream.get("sample_aspect_ratio")
    )
    audio_codecs = tuple(
        str(item.get("codec_name") or "unknown")
        for item in streams
        if item.get("codec_type") == "audio"
    )
    width = stream.get("width")
    height = stream.get("height")
    try:
        width = int(width)
        height = int(height)
    except (TypeError, ValueError) as exc:
        raise ProbeError("video dimensions are missing or invalid") from exc
    if width <= 0 or height <= 0:
        raise ProbeError("video dimensions must be positive")

    average_rate = _parse_rate(stream.get("avg_frame_rate"), label="average frame rate")
    nominal_rate = _parse_rate(stream.get("r_frame_rate"), label="nominal frame rate")
    if average_rate != nominal_rate:
        raise ProbeError(
            "input video must be constant frame rate "
            f"(avg {average_rate} != nominal {nominal_rate}); transcode externally to CFR, then retry"
        )

    frame_value = stream.get("nb_read_frames")
    if frame_value in (None, "", "N/A"):
        frame_value = stream.get("nb_frames")
    try:
        frame_count = int(frame_value)
    except (TypeError, ValueError) as exc:
        raise ProbeError("video frame count is missing or invalid") from exc
    if frame_count <= 0:
        raise ProbeError("video frame count must be positive")

    duration_value = stream.get("duration")
    if duration_value in (None, "", "N/A"):
        duration_value = (payload.get("format") or {}).get("duration")
    if duration_value in (None, "", "N/A"):
        duration_seconds = float(Fraction(frame_count, 1) / average_rate)
    else:
        try:
            duration_seconds = float(duration_value)
        except (TypeError, ValueError) as exc:
            raise ProbeError("video duration is invalid") from exc
        expected_duration = float(Fraction(frame_count, 1) / average_rate)
        tolerance = max(0.05, 1.5 / float(average_rate))
        if not math.isfinite(duration_seconds) or duration_seconds <= 0:
            raise ProbeError("video duration must be positive")
        if abs(duration_seconds - expected_duration) > tolerance:
            raise ProbeError(
                "video duration does not match frame count and frame rate"
            )

    rotation = 0.0
    tags = stream.get("tags")
    if isinstance(tags, Mapping) and tags.get("rotate") not in (None, "", "0", 0):
        try:
            rotation = float(tags["rotate"])
        except (TypeError, ValueError) as exc:
            raise ProbeError("video rotation metadata is invalid") from exc
    for side_data in stream.get("side_data_list") or ():
        if isinstance(side_data, Mapping) and side_data.get("rotation") not in (
            None,
            "",
            "0",
            0,
        ):
            try:
                rotation = float(side_data["rotation"])
            except (TypeError, ValueError) as exc:
                raise ProbeError("video rotation metadata is invalid") from exc
    if rotation % 360:
        raise ProbeError(
            "input video requires rotation metadata; bake rotation externally, then retry"
        )

    color_primaries = str(stream.get("color_primaries") or "unknown").lower()
    color_transfer = str(stream.get("color_transfer") or "unknown").lower()
    color_space = str(stream.get("color_space") or "unknown").lower()
    color_range = str(stream.get("color_range") or "unknown").lower()
    field_order = str(stream.get("field_order") or "progressive").lower()
    if enforce_source_color_policy:
        allowed_primaries = {"unknown", "bt709", "smpte170m", "bt470bg"}
        allowed_transfers = {
            "unknown",
            "bt709",
            "smpte170m",
            "bt470bg",
            "gamma22",
            "gamma28",
            "iec61966-2-1",
        }
        allowed_spaces = {"unknown", "bt709", "smpte170m", "bt470bg", "fcc"}
        allowed_ranges = {"unknown", "tv", "pc"}
        if (
            color_primaries not in allowed_primaries
            or color_transfer not in allowed_transfers
            or color_space not in allowed_spaces
            or color_range not in allowed_ranges
        ):
            raise ProbeError(
                "wide-gamut, HDR, or unsupported color metadata; normalize externally to 8-bit BT.709 SDR, then retry"
            )
        if (
            color_primaries == "bt709"
            and color_space not in {"unknown", "bt709"}
        ):
            raise ProbeError(
                "unsupported color primaries and matrix combination; normalize externally to BT.709 SDR, then retry"
            )
    if enforce_source_color_policy and field_order not in {"progressive", "unknown"}:
        raise ProbeError(
            "interlaced input; deinterlace externally to progressive video, then retry"
        )
    bits_value = stream.get("bits_per_raw_sample")
    bit_depth = 0
    if bits_value not in (None, "", "N/A", "0", 0):
        try:
            bit_depth = int(bits_value)
        except (TypeError, ValueError) as exc:
            raise ProbeError("video bit depth metadata is invalid") from exc
    if bit_depth <= 0:
        pixel_format = str(stream.get("pix_fmt") or "unknown").lower()
        inferred_bit_depth = _pixel_format_bit_depth(pixel_format)
        if inferred_bit_depth is None:
            if enforce_source_color_policy:
                raise ProbeError(
                    "source video bit depth could not be verified; normalize externally to 8-bit BT.709 SDR, then retry"
                )
            bit_depth = 0
        else:
            bit_depth = inferred_bit_depth
    if enforce_source_color_policy and bit_depth > 8:
        raise ProbeError(
            "source video uses more than 8 bits per channel; normalize externally to 8-bit BT.709 SDR, then retry"
        )

    frames = payload.get("frames")
    if validate_timestamps:
        if not isinstance(frames, list):
            raise ProbeError("ffprobe did not return all-frame timestamp metadata")
        timestamps: list[float] = []
        for frame in frames:
            if not isinstance(frame, Mapping):
                continue
            if frame.get("media_type") not in (None, "video"):
                continue
            try:
                frame_stream_index = int(frame.get("stream_index", stream_index))
            except (TypeError, ValueError) as exc:
                raise ProbeError("video frame stream index is invalid") from exc
            if frame_stream_index != stream_index:
                continue
            value = frame.get("best_effort_timestamp_time")
            if value in (None, "", "N/A"):
                raise ProbeError("video frame timestamp metadata is missing")
            try:
                timestamps.append(float(value))
            except (TypeError, ValueError) as exc:
                raise ProbeError("video frame timestamp metadata is invalid") from exc
        _validate_video_timestamps(
            timestamps,
            frame_count=frame_count,
            fps=average_rate,
            time_base=str(stream.get("time_base") or "unknown"),
        )

    return VideoInfo(
        width=width,
        height=height,
        frame_count=frame_count,
        fps=average_rate,
        duration_seconds=duration_seconds,
        codec_name=str(stream.get("codec_name") or "unknown"),
        pixel_format=str(stream.get("pix_fmt") or "unknown"),
        codec_profile=str(stream.get("profile") or "unknown"),
        sample_aspect_ratio=sample_aspect_ratio,
        audio_codecs=audio_codecs,
        stream_index=stream_index,
        color_primaries=color_primaries,
        color_transfer=color_transfer,
        color_space=color_space,
        color_range=color_range,
        field_order=field_order,
        bit_depth=bit_depth,
        time_base=str(stream.get("time_base") or "unknown"),
    )


def build_ffprobe_cadence_command(
    source: Path | str, *, stream_index: int, ffprobe: str = "ffprobe"
) -> list[str]:
    return [
        ffprobe,
        "-v",
        "error",
        "-select_streams",
        str(stream_index),
        "-show_entries",
        "frame=best_effort_timestamp_time",
        "-of",
        "csv=p=0",
        str(source),
    ]


def verify_video_cadence(
    source: Path | str,
    info: VideoInfo,
    *,
    ffprobe: str = "ffprobe",
    timeout_seconds: float = DEFAULT_PROBE_TIMEOUT_SECONDS,
    max_output_bytes: int = 2 * 1024 * 1024,
    process_factory: Any = subprocess.Popen,
) -> dict[str, int | float | bool]:
    """Verify selected-video timestamps with an actively bounded compact probe."""

    executable = require_tool("ffprobe", ffprobe)
    command = build_ffprobe_cadence_command(
        source, stream_index=info.stream_index, ffprobe=executable
    )
    try:
        process = process_factory(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError as exc:
        raise ProbeError("unable to execute ffprobe cadence check") from exc
    if process.stdout is None:
        close_process(process)
        raise ProbeError("ffprobe cadence check did not expose output")
    deadline = time.monotonic() + timeout_seconds
    output = bytearray()
    try:
        try:
            descriptor = process.stdout.fileno()
        except (AttributeError, OSError):
            descriptor = None
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ProbeError("ffprobe cadence check timed out")
            if descriptor is None:
                chunk = process.stdout.read(65536)
            else:
                selector = selectors.DefaultSelector()
                try:
                    selector.register(descriptor, selectors.EVENT_READ)
                    if not selector.select(remaining):
                        raise ProbeError("ffprobe cadence check timed out")
                    chunk = os.read(descriptor, 65536)
                finally:
                    selector.close()
            if not chunk:
                break
            output.extend(chunk)
            if len(output) > max_output_bytes:
                raise ProbeError("ffprobe cadence output exceeds the configured bound")
        try:
            return_code = process.wait(timeout=max(0.001, deadline - time.monotonic()))
        except subprocess.TimeoutExpired as exc:
            raise ProbeError("ffprobe cadence check timed out") from exc
        if return_code != 0:
            raise ProbeError(f"ffprobe cadence check failed (exit {return_code})")
    except BaseException:
        close_process(process)
        raise

    timestamps: list[float] = []
    for line in output.decode("utf-8", errors="replace").splitlines():
        text = line.strip().rstrip(",")
        if not text or text == "N/A":
            raise ProbeError("video frame timestamp metadata is missing")
        try:
            timestamps.append(float(text))
        except ValueError as exc:
            raise ProbeError("video frame timestamp metadata is invalid") from exc
    tolerance = _validate_video_timestamps(
        timestamps,
        frame_count=info.frame_count,
        fps=info.fps,
        time_base=info.time_base,
    )
    return {
        "frames_checked": len(timestamps),
        "expected_frames": info.frame_count,
        "time_base_tolerance_seconds": tolerance,
        "quality_passed": True,
    }


def build_ffmpeg_decode_command(
    source: Path | str,
    *,
    width: int,
    height: int,
    ffmpeg: str = "ffmpeg",
    stream_index: int = 0,
    resize_mode: str = "fill",
) -> list[str]:
    """Build an aspect-filled raw RGB stream; no runtime key is involved.

    A generated landscape source must not be squeezed into the portrait pet
    canvas.  Scaling until the canvas is covered, then cropping from its
    centre, preserves character proportions while still producing the exact
    requested geometry.  ``setsar=1`` makes that geometry unambiguous to the
    downstream raw-frame and codec stages.
    """

    command = [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        str(source),
        "-map",
        f"0:{stream_index}",
        "-an",
    ]
    if resize_mode not in {"fill", "fit"}:
        raise AlphaConversionError("source resize mode must be fill or fit")
    if width > 0 and height > 0:
        if resize_mode == "fill":
            video_filter = (
                f"scale={width}:{height}:force_original_aspect_ratio=increase:"
                "flags=lanczos,"
                f"crop={width}:{height}:(iw-ow)*0.5:(ih-oh)*0.5,setsar=1"
            )
        else:
            video_filter = (
                f"scale={width}:{height}:force_original_aspect_ratio=decrease:"
                "flags=lanczos,"
                f"pad={width}:{height}:(ow-iw)*0.5:(oh-ih)*0.5:color=0x00ff00,setsar=1"
            )
        command.extend(
            [
                "-vf",
                video_filter,
            ]
        )
    command.extend(["-vsync", "0", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
    return command


def build_ffmpeg_rgba_decode_command(
    source: Path | str,
    *,
    width: int,
    height: int,
    ffmpeg: str = "ffmpeg",
) -> list[str]:
    """Build the independent RGBA decoder used for Apple alpha proof.

    This command is intentionally run only on the ProRes 4444 movie produced
    by ``avconvert``.  Decoding HEVC directly with ffmpeg's ``alphaextract``
    filter is not an acceptance proof because ffprobe/ffmpeg do not expose
    Apple's auxiliary alpha-track contract reliably.
    """

    command = [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        str(source),
        "-map",
        "0:v:0",
        "-an",
    ]
    if width > 0 and height > 0:
        command.extend(["-vf", f"scale={width}:{height}:flags=lanczos"])
    command.extend(["-vsync", "0", "-f", "rawvideo", "-pix_fmt", "rgba", "-"])
    return command


def build_ffmpeg_prores_command(
    output: Path | str,
    *,
    width: int,
    height: int,
    fps: Fraction | str,
    ffmpeg: str = "ffmpeg",
) -> list[str]:
    """Build the RGBA-stdin -> ProRes 4444 intermediate command."""

    fps_text = str(fps)
    return [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-f",
        "rawvideo",
        "-pix_fmt",
        "rgba",
        "-s",
        f"{width}x{height}",
        "-r",
        fps_text,
        "-i",
        "-",
        "-an",
        "-c:v",
        "prores_ks",
        "-profile:v",
        "4",
        "-pix_fmt",
        "yuva444p10le",
        str(output),
    ]


def build_avconvert_command(
    source: Path | str,
    output: Path | str,
    *,
    avconvert: str = "avconvert",
    preset: str = "PresetHEVCHighestQualityWithAlpha",
) -> list[str]:
    """Build Apple's HEVC-with-alpha conversion command."""

    return [
        avconvert,
        "--source",
        str(source),
        "--output",
        str(output),
        "--preset",
        preset,
        "--replace",
    ]


def _array_from_rgb(rgb: Any) -> Any:
    module = _require_numpy()
    array = module.asarray(rgb)
    if array.ndim != 3 or array.shape[2] != 3:
        raise ValueError("RGB frame must have shape (height, width, 3)")
    if array.shape[0] < 3 or array.shape[1] < 3:
        raise ValueError("RGB frame must be at least 3x3 pixels")
    if array.dtype != module.uint8:
        array = module.clip(array, 0, 255).astype(module.uint8)
    return array


def _border_samples(rgb: Any, border_width: int = 1) -> tuple[Any, Any]:
    module = _require_numpy()
    if border_width < 1:
        raise ValueError("border width must be at least one pixel")
    height, width = rgb.shape[:2]
    border_width = min(border_width, max(1, height // 2), max(1, width // 2))
    mask = module.zeros((height, width), dtype=bool)
    mask[:border_width, :] = True
    mask[-border_width:, :] = True
    mask[:, :border_width] = True
    mask[:, -border_width:] = True
    ys, xs = module.nonzero(mask)
    return module.stack((xs, ys), axis=1), rgb[mask].astype(module.float32)


def estimate_background(rgb: Any, *, border_width: int = 1) -> Any:
    """Estimate a smooth per-pixel background surface from the frame border.

    A median RGB triplet is insufficient for generated videos: lighting and
    diffusion commonly make the green vary across both axes and between frames.
    We fit a low-order spatial surface to robustly selected border samples.  A
    foreground object touching part of the border is rejected by its chroma and
    residual, while the interpolation keeps the varying background colour.
    """

    module = _require_numpy()
    frame = _array_from_rgb(rgb).astype(module.float32)
    height, width = frame.shape[:2]
    coords, samples = _border_samples(frame, border_width)
    x = (coords[:, 0].astype(module.float32) / max(width - 1, 1)) * 2.0 - 1.0
    y = (coords[:, 1].astype(module.float32) / max(height - 1, 1)) * 2.0 - 1.0
    features = module.stack((
        module.ones_like(x),
        x,
        y,
        x * y,
        x * x,
        y * y,
    ), axis=1)

    chroma = samples[:, 1] - module.maximum(samples[:, 0], samples[:, 2])
    # Generated greens are not guaranteed to share one RGB value, but they do
    # remain the dominant green-excess population on the border.  Keeping the
    # upper half rejects most subject-colour contamination without a fixed RGB.
    threshold = float(module.percentile(chroma, 50.0))
    keep = chroma >= threshold
    minimum_points = min(len(samples), features.shape[1] + 2)
    if int(keep.sum()) < minimum_points:
        keep = module.ones(len(samples), dtype=bool)

    coefficients = None
    for _ in range(3):
        try:
            coefficients, _, _, _ = module.linalg.lstsq(
                features[keep], samples[keep], rcond=None
            )
        except module.linalg.LinAlgError:
            coefficients = None
            break
        predicted_border = features @ coefficients
        residual = module.sqrt(module.mean((samples - predicted_border) ** 2, axis=1))
        median = float(module.median(residual[keep]))
        mad = float(module.median(module.abs(residual[keep] - median)))
        limit = median + 4.0 * max(mad, 1.5)
        next_keep = keep & (residual <= limit)
        if int(next_keep.sum()) < minimum_points:
            break
        if bool(module.array_equal(next_keep, keep)):
            break
        keep = next_keep

    if coefficients is None:
        # This is a numerical fallback, not a fixed-key colour fallback.  The
        # border median still varies per frame and remains pathologically safe.
        background_colour = module.median(samples[keep], axis=0)
        return module.broadcast_to(background_colour, frame.shape).copy()

    yy, xx = module.mgrid[0:height, 0:width]
    full_x = (xx.astype(module.float32) / max(width - 1, 1)) * 2.0 - 1.0
    full_y = (yy.astype(module.float32) / max(height - 1, 1)) * 2.0 - 1.0
    full_features = module.stack((
        module.ones_like(full_x),
        full_x,
        full_y,
        full_x * full_y,
        full_x * full_x,
        full_y * full_y,
    ), axis=-1)
    background = module.einsum("...k,kc->...c", full_features, coefficients)
    return module.clip(background, 0.0, 255.0).astype(module.float32)


def smoothstep(value: Any) -> Any:
    module = _require_numpy()
    value = module.asarray(value, dtype=module.float32)
    return value * value * (3.0 - 2.0 * value)


def _bleed_edge_rgb(
    rgba: Any,
    *,
    source_alpha: int = DEFAULT_EDGE_RGB_SOURCE_ALPHA,
    radius: int = DEFAULT_EDGE_RGB_BLEED_RADIUS,
) -> Any:
    """Repair low-opacity RGB from nearby retained foreground colours.

    Straight RGB has no visual meaning at alpha zero, but it still affects
    filtering and codec interpolation around a silhouette.  The matte can
    otherwise divide by a tiny alpha and create clipped magenta values from a
    small source/background mismatch.  A bounded four-neighbour flood copies
    RGB only into pixels below ``source_alpha``; alpha itself is untouched.
    """

    module = _require_numpy()
    if not 1 <= source_alpha <= 255:
        raise ValueError("edge RGB source alpha must be between one and 255")
    if radius < 0:
        raise ValueError("edge RGB bleed radius must not be negative")
    result = module.asarray(rgba).copy()
    if result.ndim != 3 or result.shape[2] != 4:
        raise ValueError("RGBA frame must have shape (height, width, 4)")
    if result.dtype != module.uint8:
        raise ValueError("RGBA frame must use uint8 channels")

    alpha = result[:, :, 3]
    known = alpha >= source_alpha
    colours = result[:, :, :3].astype(module.uint32)
    height, width = known.shape
    for _ in range(radius):
        sums = module.zeros((height, width, 3), dtype=module.uint32)
        counts = module.zeros((height, width), dtype=module.uint16)
        for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            source_y = slice(max(0, -dy), min(height, height - dy))
            source_x = slice(max(0, -dx), min(width, width - dx))
            target_y = slice(max(0, dy), min(height, height + dy))
            target_x = slice(max(0, dx), min(width, width + dx))
            neighbour_known = known[source_y, source_x]
            sums[target_y, target_x] += (
                colours[source_y, source_x] * neighbour_known[:, :, None]
            )
            counts[target_y, target_x] += neighbour_known
        newly_known = ~known & (counts > 0)
        if not bool(newly_known.any()):
            break
        colours[newly_known] = (
            sums[newly_known] / counts[newly_known][:, None]
        ).astype(module.uint32)
        known[newly_known] = True

    repair = (alpha < source_alpha) & known
    result[:, :, :3][repair] = module.clip(
        colours[repair], 0, 255
    ).astype(module.uint8)
    return result


def matte_frame(
    rgb: Any,
    *,
    border_width: int = 1,
    key_floor: float = 0.06,
    key_ceiling: float = 0.94,
    despill_strength: float = 0.80,
    despill_allowance: float = 2.0,
    diagnostics: dict[str, Any] | None = None,
    reject_edge_contact: bool = False,
    min_green_border_ratio: float = DEFAULT_MIN_GREEN_BORDER_RATIO,
    green_border_excess: int = DEFAULT_GREEN_BORDER_EXCESS,
    suitability_bounds: tuple[int, int, int, int] | None = None,
    background_attested: bool = False,
    background_rgb: tuple[int, int, int] | None = None,
) -> Any:
    """Return straight RGBA for one RGB frame using a continuous matte.

    ``key_floor`` and ``key_ceiling`` operate on observed/background green
    excess, not RGB constants.  The resulting smoothstep alpha preserves
    antialiased hair, hands, and footwear instead of inventing a blurred binary
    silhouette.  Despill is applied to the recovered foreground across all
    retained pixels, including nominally opaque dark clothing.
    """

    module = _require_numpy()
    frame = _array_from_rgb(rgb).astype(module.float32)
    if not (0.0 <= key_floor < key_ceiling <= 1.5):
        raise ValueError("key floor/ceiling must satisfy 0 <= floor < ceiling <= 1.5")
    if not 0.0 <= despill_strength <= 1.0:
        raise ValueError("despill strength must be between zero and one")
    if despill_allowance < 0.0:
        raise ValueError("despill allowance must not be negative")
    if not 0.0 <= min_green_border_ratio <= 1.0:
        raise ValueError("minimum green border ratio must be between zero and one")

    suitability_frame = frame
    if suitability_bounds is not None:
        left, top, right, bottom = suitability_bounds
        if not (0 <= left < right <= frame.shape[1] and 0 <= top < bottom <= frame.shape[0]):
            raise FrameQualityError("source suitability bounds are invalid")
        suitability_frame = frame[top:bottom, left:right]
    if background_attested:
        green_background_border_ratio = 1.0
    else:
        suitability = assess_green_background(
            suitability_frame,
            green_excess=green_border_excess,
        )
        green_background_border_ratio = float(suitability["green_source_ratio"])

    use_spatial_background = background_rgb is None
    if background_rgb is not None:
        border_mask = module.zeros(frame.shape[:2], dtype=bool)
        border_mask[0, :] = True
        border_mask[-1, :] = True
        border_mask[:, 0] = True
        border_mask[:, -1] = True
        border_pixels = frame[border_mask]
        border_excess = border_pixels[:, 1] - module.maximum(
            border_pixels[:, 0], border_pixels[:, 2]
        )
        use_spatial_background = float(
            (border_excess >= green_border_excess).mean()
        ) >= 0.50
    if use_spatial_background:
        background = estimate_background(frame, border_width=border_width)
    else:
        background = module.empty_like(frame)
        background[:, :, :] = module.asarray(background_rgb, dtype=module.float32)
    observed_excess = frame[:, :, 1] - module.maximum(frame[:, :, 0], frame[:, :, 2])
    background_excess = background[:, :, 1] - module.maximum(
        background[:, :, 0], background[:, :, 2]
    )
    ratio = observed_excess / module.maximum(background_excess, 1.0)
    key_strength = module.clip(
        (ratio - key_floor) / max(key_ceiling - key_floor, 1e-6), 0.0, 1.0
    )
    alpha_values = 1.0 - smoothstep(key_strength)
    alpha_values = module.clip(alpha_values, 0.0, 1.0)

    alpha_safe = module.maximum(alpha_values[:, :, None], 1.0 / 255.0)
    foreground = (frame - background * (1.0 - alpha_values[:, :, None])) / alpha_safe
    foreground = module.clip(foreground, 0.0, 255.0)
    foreground_max_rb = module.maximum(foreground[:, :, 0], foreground[:, :, 2])
    spill = module.maximum(
        foreground[:, :, 1] - foreground_max_rb - float(despill_allowance), 0.0
    )
    retained = alpha_values > 0.0
    foreground[:, :, 1] = module.where(
        retained,
        foreground[:, :, 1] - spill * float(despill_strength),
        0.0,
    )
    foreground[~retained] = 0.0

    alpha = module.rint(alpha_values * 255.0).astype(module.uint8)
    outer_edge = module.zeros(alpha.shape, dtype=bool)
    outer_edge[0, :] = True
    outer_edge[-1, :] = True
    outer_edge[:, 0] = True
    outer_edge[:, -1] = True
    outer_alpha = alpha[outer_edge]
    preclean_edge_alpha_maximum = int(outer_alpha.max())
    preclean_edge_contact_pixels = int(
        (outer_alpha > DEFAULT_MATTE_EDGE_CONTACT_ALPHA).sum()
    )
    if diagnostics is not None:
        diagnostics.update(
            {
                "preclean_outer_edge_alpha_maximum": preclean_edge_alpha_maximum,
                "preclean_outer_edge_contact_pixels": preclean_edge_contact_pixels,
                "green_background_border_ratio": green_background_border_ratio,
                "green_background_minimum_ratio": min_green_border_ratio,
            }
        )
    if reject_edge_contact and preclean_edge_contact_pixels:
        raise FrameQualityError(
            "computed matte foreground touches outer frame edge "
            f"({preclean_edge_contact_pixels} pixels above "
            f"{DEFAULT_MATTE_EDGE_CONTACT_ALPHA} alpha)"
        )

    # The player assumes a transparent safety margin around every movie frame.
    alpha[0, :] = 0
    alpha[-1, :] = 0
    alpha[:, 0] = 0
    alpha[:, -1] = 0
    foreground[alpha == 0] = 0.0
    rgba = module.dstack((module.rint(foreground).astype(module.uint8), alpha))
    rgba = _bleed_edge_rgb(rgba)
    # Keep transparent holes and the safety border fully black after colour
    # bleeding.  Their RGB is intentionally not used as foreground evidence.
    rgba[rgba[:, :, 3] == 0] = 0
    rgba[0, :, :] = 0
    rgba[-1, :, :] = 0
    rgba[:, 0, :] = 0
    rgba[:, -1, :] = 0
    return rgba.astype(module.uint8, copy=False)


def assess_green_background(
    rgb: Any,
    *,
    min_green_ratio: float = DEFAULT_MIN_GREEN_SOURCE_RATIO,
    green_excess: int = DEFAULT_GREEN_BORDER_EXCESS,
    min_green_border_ratio: float = DEFAULT_MIN_GREEN_SOURCE_BORDER_RATIO,
    min_green_axis_coverage: float = DEFAULT_MIN_GREEN_SOURCE_AXIS_COVERAGE,
    min_connected_green_ratio: float = DEFAULT_MIN_GREEN_CONNECTED_RATIO,
) -> dict[str, int | float | bool]:
    """Attest one border-connected source-space green background component."""

    module = _require_numpy()
    frame = _array_from_rgb(rgb).astype(module.int16)
    if not 0.0 <= min_green_ratio <= 1.0:
        raise ValueError("minimum green source ratio must be between zero and one")
    if not 0.0 <= min_green_axis_coverage <= 1.0:
        raise ValueError("minimum green source axis coverage must be between zero and one")
    if not 0.0 <= min_connected_green_ratio <= 1.0:
        raise ValueError("minimum connected green ratio must be between zero and one")
    excess = frame[:, :, 1] - module.maximum(frame[:, :, 0], frame[:, :, 2])
    green_pixels = excess >= green_excess
    ratio = float(green_pixels.mean())
    connected = _largest_connected_mask(green_pixels)
    connected_ratio = float(connected.mean())
    border_mask = module.zeros(green_pixels.shape, dtype=bool)
    border_mask[0, :] = True
    border_mask[-1, :] = True
    border_mask[:, 0] = True
    border_mask[:, -1] = True
    border_ratio = float(green_pixels[border_mask].mean())
    row_coverage = float(connected.any(axis=1).mean())
    column_coverage = float(connected.any(axis=0).mean())
    if (
        ratio < min_green_ratio
        or connected_ratio < min_connected_green_ratio
        or border_ratio < min_green_border_ratio
        or row_coverage < min_green_axis_coverage
        or column_coverage < min_green_axis_coverage
    ):
        raise FrameQualityError(
            "source does not have a supported green-screen background "
            f"(source ratio {ratio:.3f}, connected ratio {connected_ratio:.3f}, "
            f"border ratio {border_ratio:.3f}, "
            f"row coverage {row_coverage:.3f}, column coverage {column_coverage:.3f})"
        )
    background_rgb = module.median(frame[connected], axis=0)
    return {
        "green_source_ratio": ratio,
        "minimum_green_source_ratio": min_green_ratio,
        "green_source_connected_ratio": connected_ratio,
        "minimum_green_source_connected_ratio": min_connected_green_ratio,
        "green_source_border_ratio": border_ratio,
        "minimum_green_source_border_ratio": min_green_border_ratio,
        "green_source_row_coverage": row_coverage,
        "green_source_column_coverage": column_coverage,
        "minimum_green_source_axis_coverage": min_green_axis_coverage,
        "green_excess": green_excess,
        "background_rgb": [int(round(value)) for value in background_rgb],
        "quality_passed": True,
    }


def _largest_connected_mask(mask: Any) -> Any:
    """Return the largest border-seeded 4-connected true component.

    Selecting one substantial component prevents a thin green cross or green
    clothing from becoming the background reference.  Relaxed edge contact is
    still accepted when a narrow visible green corridor connects the border to
    the large background pocket.
    """

    module = _require_numpy()
    source = module.asarray(mask, dtype=bool)
    if source.ndim != 2:
        raise ValueError("green component mask must be two-dimensional")
    height, width = source.shape
    visited = module.zeros(source.shape, dtype=bool)
    largest_spans: list[tuple[int, int, int]] = []
    largest_size = 0
    for seed_y, seed_x in zip(*module.nonzero(source)):
        if visited[seed_y, seed_x]:
            continue
        seeds: list[tuple[int, int]] = [(int(seed_y), int(seed_x))]
        spans: list[tuple[int, int, int]] = []
        component_size = 0
        touches_border = False
        while seeds:
            y, x = seeds.pop()
            if visited[y, x] or not source[y, x]:
                continue
            left = x
            while left > 0 and source[y, left - 1] and not visited[y, left - 1]:
                left -= 1
            right = x
            while (
                right + 1 < width
                and source[y, right + 1]
                and not visited[y, right + 1]
            ):
                right += 1
            visited[y, left : right + 1] = True
            spans.append((y, left, right))
            component_size += right - left + 1
            touches_border = touches_border or (
                y == 0 or y == height - 1 or left == 0 or right == width - 1
            )
            for adjacent_y in (y - 1, y + 1):
                if not 0 <= adjacent_y < height:
                    continue
                cursor = left
                while cursor <= right:
                    if source[adjacent_y, cursor] and not visited[adjacent_y, cursor]:
                        seeds.append((adjacent_y, cursor))
                        cursor += 1
                        while (
                            cursor <= right
                            and source[adjacent_y, cursor]
                            and not visited[adjacent_y, cursor]
                        ):
                            cursor += 1
                    else:
                        cursor += 1
        if touches_border and component_size > largest_size:
            largest_size = component_size
            largest_spans = spans
    connected = module.zeros(source.shape, dtype=bool)
    for y, left, right in largest_spans:
        connected[y, left : right + 1] = True
    return connected


def frame_quality(
    rgba: Any,
    *,
    reference_rgba: Any | None = None,
    max_green_edge_ratio: float = DEFAULT_MAX_SOURCE_EDGE_RATIO,
    max_magenta_edge_ratio: float = DEFAULT_MAX_SOURCE_EDGE_RATIO,
    max_green_edge_excess: int = DEFAULT_MAX_UNSUPPORTED_GREEN_EDGE_EXCESS,
    max_magenta_edge_excess: int = DEFAULT_MAX_UNSUPPORTED_MAGENTA_EDGE_EXCESS,
    source_edge_alpha_floor: int = DEFAULT_SOURCE_EDGE_ALPHA_FLOOR,
    require_foreground: bool = True,
    max_outer_edge_alpha: int = 0,
) -> dict[str, int | float | bool]:
    """Measure and enforce the per-frame transparent-edge contract.

    Source matte frames use the strict default of zero.  Apple codec
    round-trip frames may use a small documented ringing allowance, but never
    the unbounded edge leak accepted by a visual-only smoke test.
    """

    module = _require_numpy()
    frame = module.asarray(rgba)
    if frame.ndim != 3 or frame.shape[2] != 4:
        raise FrameQualityError("matted frame must have shape (height, width, 4)")
    if frame.dtype != module.uint8:
        raise FrameQualityError("matted frame must use uint8 RGBA channels")
    reference = None
    if reference_rgba is not None:
        reference = module.asarray(reference_rgba)
        if reference.shape != frame.shape or reference.dtype != module.uint8:
            raise FrameQualityError(
                "reference frame geometry or channels do not match delivery"
            )
    if not 0 <= max_outer_edge_alpha <= 255:
        raise FrameQualityError("maximum outer-edge alpha must be between zero and 255")
    if not 0.0 <= max_green_edge_ratio <= 1.0:
        raise FrameQualityError("maximum green edge ratio must be between zero and one")
    if not 0.0 <= max_magenta_edge_ratio <= 1.0:
        raise FrameQualityError("maximum magenta edge ratio must be between zero and one")
    if not 0 <= max_green_edge_excess <= 255:
        raise FrameQualityError("maximum green edge excess must be between zero and 255")
    if not 0 <= max_magenta_edge_excess <= 255:
        raise FrameQualityError(
            "maximum magenta edge excess must be between zero and 255"
        )
    if not 0 <= source_edge_alpha_floor <= 255:
        raise FrameQualityError("source edge alpha floor must be between zero and 255")
    alpha = frame[:, :, 3]
    edge_alpha_maximum = int(
        max(
            int(alpha[0, :].max()),
            int(alpha[-1, :].max()),
            int(alpha[:, 0].max()),
            int(alpha[:, -1].max()),
        )
    )
    if edge_alpha_maximum > max_outer_edge_alpha:
        raise FrameQualityError(
            "frame outer-edge alpha exceeds configured limit "
            f"({edge_alpha_maximum} > {max_outer_edge_alpha})"
        )
    if not bool(module.isfinite(frame.astype(module.float32)).all()):
        raise FrameQualityError("matted frame contains non-finite channel values")
    if require_foreground and int(alpha.max()) == 0:
        raise FrameQualityError("matted frame contains no foreground pixels")

    semitransparent = (alpha > 0) & (alpha < 255)
    meaningful_edge = semitransparent & (alpha >= source_edge_alpha_floor)
    colours = frame[:, :, :3].astype(module.int16)
    green_excess = module.maximum(
        colours[:, :, 1] - module.maximum(colours[:, :, 0], colours[:, :, 2]),
        0,
    )
    magenta_excess = module.maximum(
        module.minimum(colours[:, :, 0], colours[:, :, 2]) - colours[:, :, 1],
        0,
    )
    if reference is None:
        opaque_green = (alpha >= 240) & (green_excess > 32)
        supported_green = opaque_green.copy()
        for _ in range(DEFAULT_EDGE_HUE_SUPPORT_RADIUS):
            expanded = supported_green.copy()
            expanded[1:, :] |= supported_green[:-1, :]
            expanded[:-1, :] |= supported_green[1:, :]
            expanded[:, 1:] |= supported_green[:, :-1]
            expanded[:, :-1] |= supported_green[:, 1:]
            supported_green = expanded
        green = meaningful_edge & (green_excess > 32) & ~supported_green
        # A saturated magenta edge is legitimate when opaque foreground of the
        # same hue corroborates it nearby (for example, a magenta accessory).
        # Unsupported magenta next to neutral/green opaque foreground remains
        # a source-matte artifact and is still rejected.
        opaque_magenta = (alpha >= 240) & (magenta_excess > 32)
        supported = opaque_magenta.copy()
        for _ in range(DEFAULT_EDGE_HUE_SUPPORT_RADIUS):
            expanded = supported.copy()
            expanded[1:, :] |= supported[:-1, :]
            expanded[:-1, :] |= supported[1:, :]
            expanded[:, 1:] |= supported[:, :-1]
            expanded[:, :-1] |= supported[:, 1:]
            supported = expanded
        magenta = meaningful_edge & (magenta_excess > 32) & ~supported
    else:
        reference_colours = reference[:, :, :3].astype(module.int16)
        reference_magenta_excess = module.maximum(
            module.minimum(reference_colours[:, :, 0], reference_colours[:, :, 2])
            - reference_colours[:, :, 1],
            0,
        )
        magenta = meaningful_edge & (
            (magenta_excess - reference_magenta_excess) > 32
        )
        reference_green_excess = module.maximum(
            reference_colours[:, :, 1]
            - module.maximum(reference_colours[:, :, 0], reference_colours[:, :, 2]),
            0,
        )
        green = meaningful_edge & (
            (green_excess - reference_green_excess) > 32
        )
    semitransparent_count = int(semitransparent.sum())
    meaningful_edge_count = int(meaningful_edge.sum())
    green_count = int(green.sum())
    magenta_count = int(magenta.sum())
    green_ratio = green_count / max(meaningful_edge_count, 1)
    magenta_ratio = magenta_count / max(meaningful_edge_count, 1)
    if green_ratio > max_green_edge_ratio:
        raise FrameQualityError(
            "green edge ratio exceeds configured limit "
            f"({green_ratio:.4f} > {max_green_edge_ratio:.4f})"
        )
    if magenta_ratio > max_magenta_edge_ratio:
        raise FrameQualityError(
            "magenta edge ratio exceeds configured limit "
            f"({magenta_ratio:.4f} > {max_magenta_edge_ratio:.4f})"
        )
    green_max_excess = int(green_excess[green].max()) if green_count else 0
    magenta_max_excess = int(magenta_excess[magenta].max()) if magenta_count else 0
    if reference is None and green_max_excess > max_green_edge_excess:
        raise FrameQualityError(
            "green edge ratio/channel excess exceeds configured limit "
            f"({green_max_excess} > {max_green_edge_excess})"
        )
    if reference is None and magenta_max_excess > max_magenta_edge_excess:
        raise FrameQualityError(
            "magenta edge ratio/channel excess exceeds configured limit "
            f"({magenta_max_excess} > {max_magenta_edge_excess})"
        )
    return {
        "outer_edge_alpha_maximum": edge_alpha_maximum,
        "outer_edge_alpha_limit": max_outer_edge_alpha,
        "semitransparent_edge_pixels": semitransparent_count,
        "green_edge_pixels": green_count,
        "green_edge_ratio": float(green_ratio),
        "green_edge_limit": max_green_edge_ratio,
        "green_edge_max_excess": green_max_excess,
        "magenta_edge_pixels": magenta_count,
        "magenta_edge_ratio": float(magenta_ratio),
        "magenta_edge_limit": max_magenta_edge_ratio,
        "magenta_edge_max_excess": magenta_max_excess,
        "meaningful_edge_pixels": meaningful_edge_count,
        "source_edge_alpha_floor": source_edge_alpha_floor,
        "foreground_pixels": int((alpha > 0).sum()),
        "opaque_pixels": int((alpha == 255).sum()),
        "quality_passed": True,
    }


def _background_pattern(name: str, *, height: int, width: int) -> Any:
    """Return one deterministic neutral RGB composite background."""

    module = _require_numpy()
    if height <= 0 or width <= 0:
        raise FrameQualityError("composite geometry must be positive")
    if name == "white":
        return module.full((height, width, 3), 255, dtype=module.uint8)
    if name == "black":
        return module.zeros((height, width, 3), dtype=module.uint8)
    if name == "checkerboard":
        yy, xx = module.indices((height, width))
        cells = ((xx // DEFAULT_CHECKERBOARD_TILE + yy // DEFAULT_CHECKERBOARD_TILE) & 1).astype(bool)
        background = module.empty((height, width, 3), dtype=module.uint8)
        background[~cells] = (45, 49, 58)
        background[cells] = (76, 82, 94)
        return background
    raise FrameQualityError(f"unsupported composite background: {name}")


def composite_rgba(rgba: Any, background: Any) -> Any:
    """Composite straight-alpha uint8 RGBA over an RGB background.

    ``background`` may be a three-channel array matching the frame geometry or
    a three-item RGB sequence.  Rounding is explicit so repeated test runs
    produce identical fringe metrics across Python/NumPy versions.
    """

    module = _require_numpy()
    frame = module.asarray(rgba)
    if frame.ndim != 3 or frame.shape[2] != 4 or frame.dtype != module.uint8:
        raise FrameQualityError("RGBA composite input must use uint8 HxWx4 channels")
    height, width = frame.shape[:2]
    background_array = module.asarray(background)
    if background_array.ndim == 1 and background_array.shape == (3,):
        background_array = module.broadcast_to(
            background_array.reshape(1, 1, 3), (height, width, 3)
        )
    if background_array.shape != (height, width, 3):
        raise FrameQualityError("composite background geometry does not match RGBA")
    if background_array.dtype != module.uint8:
        if not bool(module.isfinite(background_array.astype(module.float32)).all()):
            raise FrameQualityError("composite background contains non-finite values")
        background_array = module.clip(background_array, 0, 255).astype(module.uint8)
    alpha = frame[:, :, 3:4].astype(module.uint32)
    # Integer arithmetic gives a stable round-to-nearest result while avoiding
    # platform-dependent floating-point accumulation in all-frame reports.
    foreground = frame[:, :, :3].astype(module.uint32)
    background_uint = background_array.astype(module.uint32)
    result = (foreground * alpha + background_uint * (255 - alpha) + 127) // 255
    return result.astype(module.uint8)


def composite_over_background(rgba: Any, background: str | Any) -> Any:
    """Composite RGBA over a named release-gate background or RGB value."""

    module = _require_numpy()
    frame = module.asarray(rgba)
    if frame.ndim != 3 or frame.shape[2] != 4:
        raise FrameQualityError("RGBA composite input must use HxWx4 channels")
    if isinstance(background, str):
        background = _background_pattern(
            background, height=frame.shape[0], width=frame.shape[1]
        )
    return composite_rgba(frame, background)


def composite_quality(
    rgba: Any,
    *,
    reference_rgba: Any | None = None,
    max_green_fringe_ratio: float = DEFAULT_MAX_GREEN_FRINGE_RATIO,
    max_magenta_fringe_ratio: float = DEFAULT_MAX_MAGENTA_FRINGE_RATIO,
    channel_excess: int = DEFAULT_FRINGE_CHANNEL_EXCESS,
    max_introduced_green_fringe_excess: int = (
        DEFAULT_MAX_INTRODUCED_GREEN_FRINGE_EXCESS
    ),
    max_introduced_magenta_fringe_excess: int = (
        DEFAULT_MAX_INTRODUCED_MAGENTA_FRINGE_EXCESS
    ),
    backgrounds: Sequence[str] = ("white", "black", "checkerboard"),
    require_foreground: bool = True,
) -> dict[str, Any]:
    """Gate newly introduced green/magenta fringe on neutral composites.

    ``rgba`` is the Apple-roundtripped frame and ``reference_rgba`` is the
    ProRes-4444 reference decoded through the same RGBA path.  Comparing their
    channel excesses avoids rejecting an authorized translucent saturated green
    or magenta foreground that the codec preserved faithfully.  When no
    reference is supplied, the helper retains its strict absolute-colour
    behaviour for small unit fixtures and pre-reference callers.
    """

    module = _require_numpy()
    frame = module.asarray(rgba)
    if frame.ndim != 3 or frame.shape[2] != 4 or frame.dtype != module.uint8:
        raise FrameQualityError("composite quality input must use uint8 HxWx4 channels")
    reference = None
    if reference_rgba is not None:
        reference = module.asarray(reference_rgba)
        if reference.shape != frame.shape or reference.dtype != module.uint8:
            raise FrameQualityError(
                "reference composite RGBA geometry or channels do not match delivery"
            )
    if not 0.0 <= max_green_fringe_ratio <= 1.0:
        raise FrameQualityError("maximum green fringe ratio must be between zero and one")
    if not 0.0 <= max_magenta_fringe_ratio <= 1.0:
        raise FrameQualityError("maximum magenta fringe ratio must be between zero and one")
    if not 0 <= channel_excess <= 255:
        raise FrameQualityError("fringe channel excess must be between zero and 255")
    if not 0 <= max_introduced_green_fringe_excess <= 255:
        raise FrameQualityError(
            "maximum introduced green fringe excess must be between zero and 255"
        )
    if not 0 <= max_introduced_magenta_fringe_excess <= 255:
        raise FrameQualityError(
            "maximum introduced magenta fringe excess must be between zero and 255"
        )
    if not backgrounds:
        raise FrameQualityError("at least one composite background is required")

    alpha = frame[:, :, 3]
    if require_foreground and int(alpha.max()) == 0:
        raise FrameQualityError("composite frame contains no foreground pixels")
    reference_alpha = reference[:, :, 3] if reference is not None else None
    if reference is None:
        semitransparent = (alpha > 0) & (alpha < 255)
    else:
        semitransparent = ((alpha > 0) & (alpha < 255)) | (
            (reference_alpha > 0) & (reference_alpha < 255)
        )
    semitransparent_count = int(semitransparent.sum())
    background_reports: dict[str, dict[str, int | float | bool]] = {}
    maximum_green_ratio = 0.0
    maximum_magenta_ratio = 0.0
    maximum_introduced_green_ratio = 0.0
    maximum_introduced_magenta_ratio = 0.0
    maximum_introduced_green_excess = 0
    maximum_introduced_magenta_excess = 0
    total_green_pixels = 0
    total_magenta_pixels = 0
    total_introduced_green_pixels = 0
    total_introduced_magenta_pixels = 0

    for name in backgrounds:
        if not isinstance(name, str):
            raise FrameQualityError("composite background names must be strings")
        delivery_composite = composite_over_background(frame, name)
        delivery_colours = delivery_composite.astype(module.int16)
        green_excess = module.maximum(
            delivery_colours[:, :, 1]
            - module.maximum(delivery_colours[:, :, 0], delivery_colours[:, :, 2]),
            0,
        )
        magenta_excess = module.maximum(
            module.minimum(delivery_colours[:, :, 0], delivery_colours[:, :, 2])
            - delivery_colours[:, :, 1],
            0,
        )
        if reference is None:
            reference_green_excess = module.zeros_like(green_excess)
            reference_magenta_excess = module.zeros_like(magenta_excess)
        else:
            reference_composite = composite_over_background(reference, name)
            reference_colours = reference_composite.astype(module.int16)
            reference_green_excess = module.maximum(
                reference_colours[:, :, 1]
                - module.maximum(reference_colours[:, :, 0], reference_colours[:, :, 2]),
                0,
            )
            reference_magenta_excess = module.maximum(
                module.minimum(reference_colours[:, :, 0], reference_colours[:, :, 2])
                - reference_colours[:, :, 1],
                0,
            )
        introduced_green_excess = module.maximum(
            green_excess - reference_green_excess, 0
        )
        introduced_magenta_excess = module.maximum(
            magenta_excess - reference_magenta_excess, 0
        )
        green = semitransparent & (green_excess > channel_excess)
        magenta = semitransparent & (magenta_excess > channel_excess)
        introduced_green = semitransparent & (
            introduced_green_excess > channel_excess
        )
        introduced_magenta = semitransparent & (
            introduced_magenta_excess > channel_excess
        )
        green_pixels = int(green.sum())
        magenta_pixels = int(magenta.sum())
        introduced_green_pixels = int(introduced_green.sum())
        introduced_magenta_pixels = int(introduced_magenta.sum())
        green_ratio = green_pixels / max(semitransparent_count, 1)
        magenta_ratio = magenta_pixels / max(semitransparent_count, 1)
        introduced_green_ratio = introduced_green_pixels / max(
            semitransparent_count, 1
        )
        introduced_magenta_ratio = introduced_magenta_pixels / max(
            semitransparent_count, 1
        )
        maximum_green_ratio = max(maximum_green_ratio, green_ratio)
        maximum_magenta_ratio = max(maximum_magenta_ratio, magenta_ratio)
        maximum_introduced_green_ratio = max(
            maximum_introduced_green_ratio, introduced_green_ratio
        )
        maximum_introduced_magenta_ratio = max(
            maximum_introduced_magenta_ratio, introduced_magenta_ratio
        )
        if semitransparent_count:
            maximum_introduced_green_excess = max(
                maximum_introduced_green_excess,
                int(introduced_green_excess[semitransparent].max()),
            )
            maximum_introduced_magenta_excess = max(
                maximum_introduced_magenta_excess,
                int(introduced_magenta_excess[semitransparent].max()),
            )
        total_green_pixels += green_pixels
        total_magenta_pixels += magenta_pixels
        total_introduced_green_pixels += introduced_green_pixels
        total_introduced_magenta_pixels += introduced_magenta_pixels
        background_reports[name] = {
            "semitransparent_pixels": semitransparent_count,
            "reference_green_fringe_ratio": float(
                int((semitransparent & (reference_green_excess > channel_excess)).sum())
                / max(semitransparent_count, 1)
            ),
            "reference_magenta_fringe_ratio": float(
                int((semitransparent & (reference_magenta_excess > channel_excess)).sum())
                / max(semitransparent_count, 1)
            ),
            "green_fringe_pixels": green_pixels,
            "green_fringe_ratio": float(green_ratio),
            "green_fringe_max_excess": max(
                0, int(green_excess[semitransparent].max())
            )
            if semitransparent_count
            else 0,
            "magenta_fringe_pixels": magenta_pixels,
            "magenta_fringe_ratio": float(magenta_ratio),
            "magenta_fringe_max_excess": max(
                0, int(magenta_excess[semitransparent].max())
            )
            if semitransparent_count
            else 0,
            "introduced_green_fringe_pixels": introduced_green_pixels,
            "introduced_green_fringe_ratio": float(introduced_green_ratio),
            "introduced_green_fringe_max_excess": int(
                introduced_green_excess[semitransparent].max()
            )
            if semitransparent_count
            else 0,
            "introduced_magenta_fringe_pixels": introduced_magenta_pixels,
            "introduced_magenta_fringe_ratio": float(introduced_magenta_ratio),
            "introduced_magenta_fringe_max_excess": int(
                introduced_magenta_excess[semitransparent].max()
            )
            if semitransparent_count
            else 0,
            "quality_passed": True,
        }

    if maximum_introduced_green_ratio > max_green_fringe_ratio:
        raise FrameQualityError(
            "introduced green fringe ratio exceeds configured limit "
            f"({maximum_introduced_green_ratio:.4f} > {max_green_fringe_ratio:.4f})"
        )
    if maximum_introduced_magenta_ratio > max_magenta_fringe_ratio:
        raise FrameQualityError(
            "introduced magenta fringe ratio exceeds configured limit "
            f"({maximum_introduced_magenta_ratio:.4f} > {max_magenta_fringe_ratio:.4f})"
        )
    if maximum_introduced_green_excess > max_introduced_green_fringe_excess:
        raise FrameQualityError(
            "introduced green fringe channel excess exceeds configured limit "
            f"({maximum_introduced_green_excess} > "
            f"{max_introduced_green_fringe_excess})"
        )
    if maximum_introduced_magenta_excess > max_introduced_magenta_fringe_excess:
        raise FrameQualityError(
            "introduced magenta fringe channel excess exceeds configured limit "
            f"({maximum_introduced_magenta_excess} > "
            f"{max_introduced_magenta_fringe_excess})"
        )
    background_count = len(background_reports)
    return {
        "backgrounds": background_reports,
        "background_names": list(background_reports),
        "semitransparent_pixels": semitransparent_count,
        "green_fringe_pixels": total_green_pixels,
        "green_fringe_ratio": float(
            total_green_pixels / max(semitransparent_count * background_count, 1)
        ),
        "maximum_delivery_green_fringe_ratio": float(maximum_green_ratio),
        "magenta_fringe_pixels": total_magenta_pixels,
        "magenta_fringe_ratio": float(
            total_magenta_pixels / max(semitransparent_count * background_count, 1)
        ),
        "maximum_delivery_magenta_fringe_ratio": float(maximum_magenta_ratio),
        "maximum_delivery_green_fringe_excess": max(
            int(item["green_fringe_max_excess"])
            for item in background_reports.values()
        ),
        "maximum_delivery_magenta_fringe_excess": max(
            int(item["magenta_fringe_max_excess"])
            for item in background_reports.values()
        ),
        "introduced_green_fringe_pixels": total_introduced_green_pixels,
        "introduced_green_fringe_ratio": float(
            total_introduced_green_pixels
            / max(semitransparent_count * background_count, 1)
        ),
        "maximum_introduced_green_fringe_ratio": float(
            maximum_introduced_green_ratio
        ),
        "maximum_introduced_green_fringe_excess": maximum_introduced_green_excess,
        "introduced_magenta_fringe_pixels": total_introduced_magenta_pixels,
        "introduced_magenta_fringe_ratio": float(
            total_introduced_magenta_pixels
            / max(semitransparent_count * background_count, 1)
        ),
        "maximum_introduced_magenta_fringe_ratio": float(
            maximum_introduced_magenta_ratio
        ),
        "maximum_introduced_magenta_fringe_excess": maximum_introduced_magenta_excess,
        "limits": {
            "max_introduced_green_fringe_ratio": float(max_green_fringe_ratio),
            "max_introduced_magenta_fringe_ratio": float(max_magenta_fringe_ratio),
            "channel_excess": channel_excess,
            "max_introduced_green_fringe_excess": max_introduced_green_fringe_excess,
            "max_introduced_magenta_fringe_excess": max_introduced_magenta_fringe_excess,
        },
        "quality_passed": True,
    }


def compare_alpha_planes(
    expected: Any,
    actual: Any,
    *,
    max_mean_abs_error: float = DEFAULT_ALPHA_MEAN_ABS_ERROR,
    max_p95_abs_error: float = DEFAULT_ALPHA_P95_ABS_ERROR,
    max_abs_error: int = DEFAULT_ALPHA_MAX_ABS_ERROR,
    loss_threshold: int = DEFAULT_ALPHA_LOSS_THRESHOLD,
    max_lost_pixels: int = 0,
) -> dict[str, int | float | bool]:
    """Compare matte alpha with alpha decoded from an Apple round-trip.

    ``expected`` is the exact 8-bit matte emitted into ProRes 4444 and
    ``actual`` is decoded from the *avconvert HEVC -> avconvert ProRes 4444*
    round-trip.  This intentionally does not use ffmpeg's HEVC alphaextract
    filter as proof.  Meaningful foreground (alpha > ``loss_threshold``)
    may not disappear; faint sub-threshold edge quantization is bounded by
    the error tolerances.
    """

    module = _require_numpy()
    expected_array = module.asarray(expected)
    actual_array = module.asarray(actual)
    if expected_array.shape != actual_array.shape:
        raise FrameQualityError("round-trip alpha geometry does not match the matte")
    if expected_array.ndim != 2:
        raise FrameQualityError("alpha planes must be two-dimensional")
    if expected_array.dtype != module.uint8 or actual_array.dtype != module.uint8:
        raise FrameQualityError("round-trip alpha planes must use uint8 values")
    if not 0 <= loss_threshold <= 255:
        raise FrameQualityError("alpha-loss threshold must be between zero and 255")
    if max_lost_pixels < 0:
        raise FrameQualityError("maximum lost alpha pixels must not be negative")
    if max_mean_abs_error < 0 or max_p95_abs_error < 0 or max_abs_error < 0:
        raise FrameQualityError("alpha-error tolerances must not be negative")
    expected_float = expected_array.astype(module.float32)
    actual_float = actual_array.astype(module.float32)
    if not bool(module.isfinite(expected_float).all()) or not bool(
        module.isfinite(actual_float).all()
    ):
        raise FrameQualityError("round-trip alpha contains non-finite values")
    difference = module.abs(actual_float - expected_float)
    mean_error = float(difference.mean())
    p95_error = float(module.percentile(difference, 95.0))
    maximum_error = int(difference.max()) if difference.size else 0
    lost_pixels = int(((expected_array > loss_threshold) & (actual_array == 0)).sum())
    if mean_error > max_mean_abs_error:
        raise FrameQualityError(
            "round-trip alpha mean error exceeds configured limit "
            f"({mean_error:.3f} > {max_mean_abs_error:.3f})"
        )
    if p95_error > max_p95_abs_error:
        raise FrameQualityError(
            "round-trip alpha p95 error exceeds configured limit "
            f"({p95_error:.3f} > {max_p95_abs_error:.3f})"
        )
    if maximum_error > max_abs_error:
        raise FrameQualityError(
            "round-trip alpha maximum error exceeds configured limit "
            f"({maximum_error} > {max_abs_error})"
        )
    if lost_pixels > max_lost_pixels:
        raise FrameQualityError(
            "round-trip alpha lost meaningful foreground pixels "
            f"({lost_pixels} > {max_lost_pixels})"
        )
    return {
        "mean_absolute_error": mean_error,
        "p95_absolute_error": p95_error,
        "maximum_absolute_error": maximum_error,
        "loss_threshold": loss_threshold,
        "lost_alpha_pixels": lost_pixels,
        "max_lost_alpha_pixels": max_lost_pixels,
        "quality_passed": True,
    }


def read_raw_frames(
    process: subprocess.Popen[bytes],
    *,
    width: int,
    height: int,
    expected_frames: int,
    channels: int = 3,
    timeout_seconds: float = DEFAULT_PROCESS_TIMEOUT_SECONDS,
) -> Iterable[Any]:
    """Yield raw frames from ffmpeg and verify the exact expected count."""

    module = _require_numpy()
    if process.stdout is None:
        raise AlphaConversionError("ffmpeg source decoder did not expose stdout")
    if channels not in (3, 4):
        raise AlphaConversionError("rawvideo channel count must be three or four")
    frame_bytes = width * height * channels
    deadline = time.monotonic() + timeout_seconds

    def read_bounded(size: int) -> bytes:
        remaining_seconds = deadline - time.monotonic()
        if remaining_seconds <= 0:
            close_process(process)
            raise AlphaConversionError("ffmpeg source decode timed out")
        try:
            descriptor = process.stdout.fileno()
        except (AttributeError, OSError):
            return process.stdout.read(size)
        selector = selectors.DefaultSelector()
        try:
            selector.register(descriptor, selectors.EVENT_READ)
            if not selector.select(remaining_seconds):
                close_process(process)
                raise AlphaConversionError("ffmpeg source decode timed out")
            return os.read(descriptor, size)
        finally:
            selector.close()

    count = 0
    while count < expected_frames:
        chunks: list[bytes] = []
        remaining = frame_bytes
        while remaining:
            chunk = read_bounded(remaining)
            if not chunk:
                if not chunks:
                    break
                raise AlphaConversionError("ffmpeg returned a truncated raw frame")
            chunks.append(chunk)
            remaining -= len(chunk)
        if not chunks:
            break
        raw = b"".join(chunks)
        count += 1
        yield module.frombuffer(raw, dtype=module.uint8).reshape(
            height, width, channels
        ).copy()
    extra = read_bounded(1)
    if extra:
        raise AlphaConversionError("ffmpeg decoded more frames than expected")
    remaining_seconds = deadline - time.monotonic()
    if remaining_seconds <= 0:
        close_process(process)
        raise AlphaConversionError("ffmpeg source decode timed out")
    try:
        return_code = process.wait(timeout=remaining_seconds)
    except subprocess.TimeoutExpired as exc:
        close_process(process)
        raise AlphaConversionError("ffmpeg source decode timed out") from exc
    if return_code != 0:
        raise AlphaConversionError(f"ffmpeg source decode failed (exit {return_code})")
    if count != expected_frames:
        raise AlphaConversionError(
            f"ffmpeg decoded {count} frames but expected {expected_frames}"
        )


def close_process(process: subprocess.Popen[Any]) -> None:
    """Best-effort cleanup used when a quality gate fails mid-stream."""

    for stream in (process.stdin, process.stdout, process.stderr):
        if stream is not None:
            try:
                stream.close()
            except OSError:
                pass
    if process.poll() is None:
        try:
            process.terminate()
            process.wait(timeout=2)
        except (OSError, subprocess.TimeoutExpired):
            try:
                process.kill()
            except OSError:
                return
            try:
                process.wait(timeout=2)
            except (OSError, subprocess.TimeoutExpired):
                pass


__all__ = [
    "AlphaConversionError",
    "DEFAULT_CHECKERBOARD_TILE",
    "DEFAULT_ALPHA_LOSS_THRESHOLD",
    "DEFAULT_ALPHA_MAX_ABS_ERROR",
    "DEFAULT_ALPHA_MEAN_ABS_ERROR",
    "DEFAULT_ALPHA_P95_ABS_ERROR",
    "DEFAULT_DELIVERY_EDGE_ALPHA_FLOOR",
    "DEFAULT_EDGE_HUE_SUPPORT_RADIUS",
    "DEFAULT_EDGE_RGB_BLEED_RADIUS",
    "DEFAULT_EDGE_RGB_SOURCE_ALPHA",
    "DEFAULT_SOURCE_EDGE_ALPHA_FLOOR",
    "DEFAULT_MATTE_EDGE_CONTACT_ALPHA",
    "DEFAULT_FRINGE_CHANNEL_EXCESS",
    "DEFAULT_MAX_UNSUPPORTED_GREEN_EDGE_EXCESS",
    "DEFAULT_MAX_UNSUPPORTED_MAGENTA_EDGE_EXCESS",
    "SOURCE_RESIZE_MODE",
    "DEFAULT_MAX_DELIVERY_EDGE_RATIO",
    "DEFAULT_MAX_SOURCE_EDGE_RATIO",
    "DEFAULT_MAX_INTRODUCED_GREEN_FRINGE_EXCESS",
    "DEFAULT_MAX_INTRODUCED_MAGENTA_FRINGE_EXCESS",
    "DEFAULT_MAX_GREEN_FRINGE_RATIO",
    "DEFAULT_MAX_MAGENTA_FRINGE_RATIO",
    "DEFAULT_MAX_BORDER_ALPHA",
    "FrameQualityError",
    "MissingDependencyError",
    "MissingToolError",
    "ProbeError",
    "VideoInfo",
    "build_avconvert_command",
    "build_ffmpeg_decode_command",
    "build_ffmpeg_rgba_decode_command",
    "build_ffmpeg_prores_command",
    "build_ffprobe_command",
    "close_process",
    "compare_alpha_planes",
    "composite_over_background",
    "composite_quality",
    "composite_rgba",
    "estimate_background",
    "frame_quality",
    "matte_frame",
    "probe_video",
    "read_raw_frames",
    "require_image_dependencies",
    "require_tool",
    "sanitize_command",
    "sanitize_text",
    "sanitize_value",
    "smoothstep",
]
