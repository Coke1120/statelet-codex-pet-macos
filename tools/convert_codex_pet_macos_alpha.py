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
import hashlib
import json
import math
import os
import signal
import stat
import subprocess
import sys
import tempfile
import warnings
from pathlib import Path
from typing import Any, Iterable, TextIO

if __name__ == "__main__":
    try:
        # The macOS app cancels this owned group so ffmpeg/avconvert descendants
        # cannot outlive the conversion coordinator.
        os.setpgid(0, 0)
    except OSError:
        print("error: conversion process group could not be created", file=sys.stderr)
        raise SystemExit(2)

    def _cancel_conversion(_signum: int, _frame: Any) -> None:
        os.write(2, b"error: conversion cancelled\n")
        raise SystemExit(2)

    signal.signal(signal.SIGTERM, _cancel_conversion)

try:  # Script execution from repository root: ``python tools/...``.
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
    )
except ImportError:  # Module import as ``tools.convert_codex_pet_macos_alpha``.
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
    )


DEFAULT_PRESET = "PresetHEVCHighestQualityWithAlpha"
ROUNDTRIP_PRESET = "PresetAppleProRes4444LPCM"


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

    def emit(
        self,
        percent: int,
        *,
        stage: str,
        message: str,
        status: str = "running",
        frame_completed: int | None = None,
        frame_total: int | None = None,
    ) -> None:
        if not self.enabled:
            return
        self.percent = max(self.percent, min(100, max(0, int(percent))))
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
        print(
            json.dumps(_safe_report_value(event), sort_keys=True, separators=(",", ":")),
            file=self.stream,
            flush=True,
        )

    def failed(self) -> None:
        self.emit(
            self.percent,
            stage="failed",
            message="Conversion failed",
            status="failed",
        )


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


def _sha256_source_file(path: Path) -> str:
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

        digest = hashlib.sha256()
        bytes_hashed = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            bytes_hashed += len(chunk)
            digest.update(chunk)
        if bytes_hashed == 0:
            raise AlphaConversionError(
                "source video must be a non-empty regular file"
            )
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


def _assert_source_unchanged(source: Path, expected_sha256: str) -> str:
    """Rehash a source and reject any in-place mutation during conversion."""

    current_sha256 = _sha256_source_file(source)
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


def _publish_transaction(
    output_stage: Path,
    output_target: Path,
    intermediate_stage: Path | None,
    intermediate_target: Path | None,
    report_target: Path,
    report_payload: dict[str, Any],
    *,
    replace: bool,
) -> None:
    """Publish delivery, optional intermediate, and report as one transaction.

    Existing targets are moved to sibling backups before any staged file is
    installed.  Any failed move (including report publication) removes newly
    installed files and restores every backup, preserving old artifact/report
    pairs for operators and retry automation.
    """

    staged: list[tuple[Path, Path]] = [(output_stage, output_target)]
    if intermediate_stage is not None:
        if intermediate_target is None:
            raise AlphaConversionError("intermediate stage has no target")
        staged.append((intermediate_stage, intermediate_target))
    report_stage = _write_json_temp(report_target, report_payload)
    staged.append((report_stage, report_target))

    backups: list[tuple[Path, Path]] = []
    published: list[Path] = []
    try:
        for stage, target in staged:
            if not stage.is_file() or stage.stat().st_size == 0:
                raise AlphaConversionError("staged conversion artifact is missing")
            if target.exists():
                if not replace:
                    raise AlphaConversionError(
                        f"{target.name} already exists; pass --replace to overwrite"
                    )
                backup = _reserve_backup_path(target)
                os.replace(target, backup)
                backups.append((target, backup))
            os.replace(stage, target)
            published.append(target)
    except BaseException as exc:
        rollback_error: BaseException | None = None
        for target in reversed(published):
            try:
                target.unlink()
            except FileNotFoundError:
                pass
            except OSError as cleanup_exc:
                rollback_error = cleanup_exc
        for target, backup in reversed(backups):
            if not backup.exists():
                continue
            try:
                os.replace(backup, target)
            except OSError as restore_exc:
                rollback_error = restore_exc
        for stage, _target in staged:
            try:
                stage.unlink()
            except FileNotFoundError:
                pass
            except OSError as cleanup_exc:
                rollback_error = cleanup_exc
        if rollback_error is not None:
            raise AlphaConversionError(
                "artifact publication failed and rollback was incomplete"
            ) from rollback_error
        if isinstance(exc, AlphaConversionError):
            raise
        raise AlphaConversionError("unable to complete artifact publication") from exc
    else:
        # Backups are no longer needed once all three targets are installed.
        # Cleanup failure does not invalidate the committed artifact/report
        # pair; a later retry can safely remove the hidden sibling backup.
        for _target, backup in backups:
            try:
                backup.unlink()
            except OSError:
                # Publication is already committed.  A read-only directory,
                # transient filesystem failure, or a concurrent cleanup must
                # not turn a successful artifact/report transaction into a
                # failure.  Only the sibling basename is emitted so the
                # warning remains path-sanitized.
                warnings.warn_explicit(
                    "publication committed; unable to remove backup "
                    f"{backup.name}",
                    RuntimeWarning,
                    filename=Path(__file__).name,
                    lineno=0,
                    module=__name__,
                )


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
) -> tuple[Any, Any]:
    """Start both RGBA decoders and close the first if the second fails."""

    reference_decoder: Any | None = None
    delivery_decoder: Any | None = None
    try:
        reference_decoder = _start_process(
            build_ffmpeg_rgba_decode_command(
                reference_video, width=width, height=height, ffmpeg=ffmpeg
            ),
            stdout=subprocess.PIPE,
        )
        delivery_decoder = _start_process(
            build_ffmpeg_rgba_decode_command(
                roundtrip_video, width=width, height=height, ffmpeg=ffmpeg
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


def _run_avconvert(
    source: Path,
    output: Path,
    *,
    avconvert: str,
    preset: str,
) -> None:
    command = build_avconvert_command(source, output, avconvert=avconvert, preset=preset)
    try:
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as exc:
        raise AlphaConversionError("unable to execute avconvert") from exc
    if result.returncode != 0:
        raise AlphaConversionError(
            f"avconvert conversion failed (exit {result.returncode})"
        )
    if not output.is_file() or output.stat().st_size == 0:
        raise AlphaConversionError("avconvert produced no output movie")


def _stream_matte_to_prores(
    source: Path,
    intermediate: Path,
    reference_alpha: Path,
    *,
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
    progress: _ProgressReporter | None = None,
) -> dict[str, Any]:
    decode_command = build_ffmpeg_decode_command(
        source, width=width, height=height, ffmpeg=ffmpeg
    )
    encode_command = build_ffmpeg_prores_command(
        intermediate, width=width, height=height, fps=info.fps, ffmpeg=ffmpeg
    )
    decoder = _start_process(decode_command, stdout=subprocess.PIPE)
    encoder = _start_process(encode_command, stdin=subprocess.PIPE)
    frames_checked = 0
    max_edge_alpha = 0
    max_green_ratio = 0.0
    max_magenta_ratio = 0.0
    max_green_excess = 0
    max_magenta_excess = 0
    semitransparent_total = 0
    foreground_total = 0
    max_preclean_edge_alpha = 0
    preclean_edge_contact_total = 0
    try:
        if encoder.stdin is None:
            raise AlphaConversionError("ffmpeg ProRes encoder did not expose stdin")
        try:
            with reference_alpha.open("wb") as alpha_handle:
                for rgb in read_raw_frames(
                    decoder,
                    width=width,
                    height=height,
                    expected_frames=info.frame_count,
                    channels=3,
                ):
                    matte_diagnostics: dict[str, int] = {}
                    frame_number = frames_checked + 1
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
                        encoder.stdin.write(rgba.tobytes())
                        alpha_handle.write(rgba[:, :, 3].tobytes())
                    except (BrokenPipeError, OSError) as exc:
                        raise AlphaConversionError(
                            "ffmpeg ProRes encoder closed its input"
                        ) from exc
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
                    foreground_total += int(metrics["foreground_pixels"])
                alpha_handle.flush()
                os.fsync(alpha_handle.fileno())
        except OSError as exc:
            raise AlphaConversionError("unable to write matte alpha reference") from exc
        encoder.stdin.close()
        return_code = encoder.wait()
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
    return {
        "codec": actual.codec_name,
        "profile": actual.codec_profile,
        "pixel_format": actual.pixel_format,
        "width": actual.width,
        "height": actual.height,
        "frames": actual.frame_count,
        "fps": actual.fps_text,
        "duration_seconds": actual.duration_seconds,
        "quality_passed": True,
    }


def _read_alpha_reference(handle: Any, *, width: int, height: int) -> Any:
    import numpy as np

    raw = handle.read(width * height)
    if len(raw) != width * height:
        raise AlphaConversionError("matte alpha reference is truncated")
    return np.frombuffer(raw, dtype=np.uint8).reshape(height, width).copy()


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
    delivery_info = probe_video(delivery, ffprobe=ffprobe)
    delivery_report = _verify_basic_info(
        delivery_info, expected, expected_codec="hevc", label="HEVC delivery"
    )
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
        )
        if progress is not None:
            progress.emit(
                79,
                stage="verify",
                message="Probing Apple alpha round-trip",
            )
        roundtrip_info = probe_video(roundtrip, ffprobe=ffprobe)
        roundtrip_report = _verify_basic_info(
            roundtrip_info, expected, expected_codec="prores", label="ProRes alpha round-trip"
        )
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
        )
        frames_verified = 0
        max_border = 0
        max_green = 0.0
        max_magenta = 0.0
        alpha_metrics: list[dict[str, int | float | bool]] = []
        composite_metrics: list[dict[str, Any]] = []
        reference_frames = read_raw_frames(
            reference_decoder,
            width=expected.width,
            height=expected.height,
            expected_frames=expected.frame_count,
            channels=4,
        )
        delivery_frames = read_raw_frames(
            decoder,
            width=expected.width,
            height=expected.height,
            expected_frames=expected.frame_count,
            channels=4,
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
                        alpha_metrics.append(comparison)
                        composite_metrics.append(composite)
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
    if not composite_metrics:
        raise AlphaConversionError("round-trip produced no composite quality metrics")
    backgrounds = {
        name: {
            "frames_checked": frames_verified,
            "maximum_delivery_green_fringe_ratio": max(
                float(item["backgrounds"][name]["green_fringe_ratio"])
                for item in composite_metrics
            ),
            "maximum_delivery_magenta_fringe_ratio": max(
                float(item["backgrounds"][name]["magenta_fringe_ratio"])
                for item in composite_metrics
            ),
            "maximum_introduced_green_fringe_ratio": max(
                float(item["backgrounds"][name]["introduced_green_fringe_ratio"])
                for item in composite_metrics
            ),
            "maximum_introduced_magenta_fringe_ratio": max(
                float(item["backgrounds"][name]["introduced_magenta_fringe_ratio"])
                for item in composite_metrics
            ),
            "green_fringe_pixels_total": sum(
                int(item["backgrounds"][name]["green_fringe_pixels"])
                for item in composite_metrics
            ),
            "maximum_delivery_green_fringe_excess": max(
                int(item["backgrounds"][name]["green_fringe_max_excess"])
                for item in composite_metrics
            ),
            "maximum_introduced_green_fringe_excess": max(
                int(
                    item["backgrounds"][name][
                        "introduced_green_fringe_max_excess"
                    ]
                )
                for item in composite_metrics
            ),
            "magenta_fringe_pixels_total": sum(
                int(item["backgrounds"][name]["magenta_fringe_pixels"])
                for item in composite_metrics
            ),
            "maximum_delivery_magenta_fringe_excess": max(
                int(item["backgrounds"][name]["magenta_fringe_max_excess"])
                for item in composite_metrics
            ),
            "maximum_introduced_magenta_fringe_excess": max(
                int(
                    item["backgrounds"][name][
                        "introduced_magenta_fringe_max_excess"
                    ]
                )
                for item in composite_metrics
            ),
        }
        for name in composite_metrics[0]["background_names"]
    }
    maximum_delivery_green_fringe = max(
        float(item["maximum_delivery_green_fringe_ratio"])
        for item in composite_metrics
    )
    maximum_delivery_magenta_fringe = max(
        float(item["maximum_delivery_magenta_fringe_ratio"])
        for item in composite_metrics
    )
    maximum_introduced_green_fringe = max(
        float(item["maximum_introduced_green_fringe_ratio"])
        for item in composite_metrics
    )
    maximum_introduced_magenta_fringe = max(
        float(item["maximum_introduced_magenta_fringe_ratio"])
        for item in composite_metrics
    )
    maximum_introduced_green_excess = max(
        int(item["maximum_introduced_green_fringe_excess"])
        for item in composite_metrics
    )
    maximum_introduced_magenta_excess = max(
        int(item["maximum_introduced_magenta_fringe_excess"])
        for item in composite_metrics
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
            "mean_absolute_error_max": max(
                float(item["mean_absolute_error"]) for item in alpha_metrics
            ),
            "p95_absolute_error_max": max(
                float(item["p95_absolute_error"]) for item in alpha_metrics
            ),
            "maximum_absolute_error_max": max(
                int(item["maximum_absolute_error"]) for item in alpha_metrics
            ),
            "lost_alpha_pixels_total": sum(
                int(item["lost_alpha_pixels"]) for item in alpha_metrics
            ),
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
    # Bind the source before ffprobe and any decoder process starts.  The
    # digest is carried through the report and checked again immediately
    # before publication so a source edited in place cannot be paired with
    # artifacts produced from a different byte sequence.
    source_sha256_before_probe = _sha256_source_file(source)
    progress.emit(5, stage="probe", message="Probing source video")
    info = probe_video(source, ffprobe=ffprobe)
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

    if args.dry_run:
        decode_command = build_ffmpeg_decode_command(
            Path("source.mp4"), width=width, height=height, ffmpeg=ffmpeg
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
            "status": "dry-run",
            "source": {
                "name": _safe_name(source),
                "codec": info.codec_name,
                "profile": info.codec_profile,
                "pixel_format": info.pixel_format,
                "width": info.width,
                "height": info.height,
                "frames": info.frame_count,
                "fps": info.fps_text,
                "duration_seconds": info.duration_seconds,
            },
            "geometry": {"width": width, "height": height},
            "geometry_alignment": geometry_alignment,
            "source_framing": {
                "resize_mode": SOURCE_RESIZE_MODE,
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

    with tempfile.TemporaryDirectory(prefix="codex-pet-alpha-") as temp_name:
        temp_dir = Path(temp_name)
        temp_intermediate = temp_dir / "intermediate.prores4444.mov"
        reference_alpha = temp_dir / "matte-alpha.raw"
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
            progress=progress,
        )
        progress.emit(57, stage="probe", message="Probing ProRes intermediate")
        intermediate_info = probe_video(temp_intermediate, ffprobe=ffprobe)
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
        if "4444" not in intermediate_info.codec_profile.lower() and not intermediate_info.pixel_format.lower().startswith("yuva"):
            raise FrameQualityError("ProRes intermediate does not retain an alpha plane")
        temp_output = temp_dir / "output.hevc-alpha.mov"
        progress.emit(62, stage="encode", message="Encoding HEVC with alpha")
        _run_avconvert(
            temp_intermediate,
            temp_output,
            avconvert=avconvert,
            preset=args.preset,
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
        )

        delivery_sha256 = _sha256_file(temp_output)
        intermediate_sha256 = (
            _sha256_file(temp_intermediate) if intermediate_target is not None else None
        )
        report = {
            "status": "converted",
            "source": {
                "name": _safe_name(source),
                "codec": info.codec_name,
                "profile": info.codec_profile,
                "pixel_format": info.pixel_format,
                "width": info.width,
                "height": info.height,
                "frames": info.frame_count,
                "fps": info.fps_text,
                "duration_seconds": info.duration_seconds,
            },
            "geometry": {"width": width, "height": height, "pixel_format": "straight-rgba"},
            "geometry_alignment": geometry_alignment,
            "source_framing": {
                "resize_mode": SOURCE_RESIZE_MODE,
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
            source, source_sha256_before_probe
        )
        report["artifacts"][
            "source_sha256_before_publication"
        ] = source_sha256_before_publication
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
        progress.failed()
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
