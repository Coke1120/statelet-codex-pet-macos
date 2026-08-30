#!/usr/bin/env python3
"""Verify private Statelet state-owned voice without printing text or paths."""

from __future__ import annotations

import argparse
import array
import hashlib
import json
import math
import os
import stat
import struct
import sys
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import BinaryIO, Iterator
from urllib.parse import urlsplit


REQUIRED_STATES = ("idle", "running", "waiting", "review")
DEFAULT_POLICY_VERSION = 3
MAX_LIBRARY_BYTES = 8 * 1024 * 1024
MAX_AUDIO_BYTES = 64 * 1024 * 1024
MAX_STATE_AUDIO_DURATION_SECONDS = 15.0
MIN_PCM_SAMPLE_RATE = 8_000
MAX_PCM_SAMPLE_RATE = 192_000
VOICE_CLEANUP_PREFIXES = (
    "voice/assets/gpt/",
    "voice/assets/sovits/",
    "voice/assets/reference/",
    "voice/generated/",
)


class VerificationError(Exception):
    pass


def positive_integer(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def valid_uuid(value: object) -> bool:
    if not isinstance(value, str):
        return False
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError):
        return False
    return str(parsed) == value.lower()


def nonblank_string(value: object, maximum: int) -> bool:
    return (
        isinstance(value, str)
        and bool(value.strip())
        and len(value) <= maximum
        and "\0" not in value
    )


def valid_failure_code(value: object) -> bool:
    return (
        isinstance(value, str)
        and 1 <= len(value) <= 64
        and all(character in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_" for character in value)
    )


def safe_managed_path(value: object) -> bool:
    if (
        not isinstance(value, str)
        or not value
        or len(value) > 1_024
        or value.startswith(("/", "~"))
        or "\\" in value
        or ":" in value
        or "\0" in value
    ):
        return False
    candidate = Path(value)
    return (
        not candidate.is_absolute()
        and value == candidate.as_posix()
        and all(part not in {"", ".", ".."} for part in candidate.parts)
    )


def numeric_loopback_https_endpoint(value: object) -> bool:
    if not isinstance(value, str):
        return False
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError:
        return False
    if (
        parsed.scheme.lower() != "https"
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or parsed.path not in {"", "/"}
        or parsed.hostname is None
        or (port is not None and not 1 <= port <= 65_535)
    ):
        return False
    host = parsed.hostname.lower()
    if host == "::1":
        return True
    octets = host.split(".")
    return (
        len(octets) == 4
        and octets[0] == "127"
        and all(octet.isascii() and octet.isdigit() and 0 <= int(octet) <= 255 for octet in octets)
    )


def validate_profile_schema(profile: object) -> int:
    if not isinstance(profile, dict):
        raise VerificationError("voice profile schema is invalid")
    revision = profile.get("revision")
    fingerprint = profile.get("input_fingerprint")
    tls_pin = profile.get("tls_leaf_certificate_sha256")
    paths = (
        (profile.get("gpt_weight_relative_path"), "voice/assets/gpt/"),
        (profile.get("sovits_weight_relative_path"), "voice/assets/sovits/"),
        (profile.get("reference_audio_relative_path"), "voice/assets/reference/"),
    )
    if (
        not valid_uuid(profile.get("id"))
        or not positive_integer(revision)
        or not nonblank_string(profile.get("name"), 128)
        or not numeric_loopback_https_endpoint(profile.get("api_base_url"))
        or not isinstance(tls_pin, str)
        or len(tls_pin) != 64
        or any(character not in "0123456789abcdefABCDEF" for character in tls_pin)
        or not all(
            safe_managed_path(path) and path.startswith(prefix)
            for path, prefix in paths
        )
        or not nonblank_string(profile.get("reference_text"), 20_000)
        or not nonblank_string(profile.get("prompt_language"), 64)
        or not nonblank_string(profile.get("default_text_language"), 64)
        or not isinstance(fingerprint, str)
        or len(fingerprint) != 64
        or any(character not in "0123456789abcdef" for character in fingerprint)
    ):
        raise VerificationError("voice profile schema is invalid")
    return revision


def validate_lines_schema(lines: object, profile_revision: int) -> list[dict[str, object]]:
    if not isinstance(lines, list) or len(lines) > 500:
        raise VerificationError("voice library lines are invalid")
    validated = []
    line_ids = set()
    for line in lines:
        if not isinstance(line, dict):
            raise VerificationError("dialogue line schema is invalid")
        line_id = line.get("id")
        status = line.get("status")
        state = line.get("state", "idle")
        generated_profile_revision = line.get("generated_profile_revision")
        generated_policy_version = line.get("generated_synthesis_policy_version")
        output_path = line.get("output_relative_path")
        if generated_policy_version is None and output_path is not None:
            generated_policy_version = 1
        failure_code = line.get("failure_code")
        if (
            not valid_uuid(line_id)
            or state not in REQUIRED_STATES
            or not nonblank_string(line.get("text"), 4_000)
            or not nonblank_string(line.get("text_language"), 64)
            or not positive_integer(line.get("revision"))
            or status not in ("draft", "queued", "generating", "ready", "failed", "stale")
        ):
            raise VerificationError("dialogue line schema is invalid")
        canonical_line_id = uuid.UUID(line_id)
        if canonical_line_id in line_ids:
            raise VerificationError("dialogue line schema is invalid")

        has_output = (
            positive_integer(generated_profile_revision)
            and positive_integer(generated_policy_version)
            and isinstance(output_path, str)
            and bool(output_path)
            and output_path.startswith("voice/generated/")
            and safe_managed_path(output_path)
        )
        no_output = (
            generated_profile_revision is None
            and generated_policy_version is None
            and output_path is None
        )
        if status == "draft" and (not no_output or failure_code is not None):
            raise VerificationError("dialogue line state is invalid")
        if status in {"queued", "generating"} and (
            not (no_output or has_output) or failure_code is not None
        ):
            raise VerificationError("dialogue line state is invalid")
        if status in {"ready", "stale"} and (not has_output or failure_code is not None):
            raise VerificationError("dialogue line state is invalid")
        if status == "ready" and generated_profile_revision != profile_revision:
            raise VerificationError("dialogue line state is invalid")
        if status == "failed" and (
            not no_output or not valid_failure_code(failure_code)
        ):
            raise VerificationError("dialogue line state is invalid")

        line_ids.add(canonical_line_id)
        validated.append(line)
    return validated


def validate_cleanup_schema(
    pending_paths: object,
    profile: dict[str, object],
    lines: list[dict[str, object]],
) -> None:
    if not isinstance(pending_paths, list):
        raise VerificationError("voice cleanup queue schema is invalid")
    referenced_paths = {
        profile.get("gpt_weight_relative_path"),
        profile.get("sovits_weight_relative_path"),
        profile.get("reference_audio_relative_path"),
    }
    referenced_paths.update(
        line.get("output_relative_path")
        for line in lines
        if line.get("output_relative_path") is not None
    )
    observed = set()
    for path in pending_paths:
        if (
            not safe_managed_path(path)
            or not any(path.startswith(prefix) for prefix in VOICE_CLEANUP_PREFIXES)
            or path in observed
            or path in referenced_paths
        ):
            raise VerificationError("voice cleanup queue schema is invalid")
        observed.add(path)


def private_directory(descriptor: int) -> None:
    status = os.fstat(descriptor)
    if not stat.S_ISDIR(status.st_mode):
        raise VerificationError("managed path parent is not a directory")
    if status.st_uid != os.getuid() or stat.S_IMODE(status.st_mode) & 0o077:
        raise VerificationError("managed directory ownership or permissions are not private")


@contextmanager
def managed_file(
    root: Path,
    relative: object,
    prefix: str,
    maximum: int,
) -> Iterator[BinaryIO]:
    if not isinstance(relative, str) or not relative.startswith(prefix):
        raise VerificationError("managed relative path has the wrong scope")
    candidate_path = Path(relative)
    if (
        candidate_path.is_absolute()
        or relative != candidate_path.as_posix()
        or any(part in {"", ".", ".."} for part in candidate_path.parts)
    ):
        raise VerificationError("managed relative path is unsafe")

    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    file_flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
    directories = []
    file_descriptor = -1
    source = None
    try:
        directories.append(os.open(root, directory_flags))
        private_directory(directories[-1])
        for part in candidate_path.parts[:-1]:
            directories.append(os.open(part, directory_flags, dir_fd=directories[-1]))
            private_directory(directories[-1])
        file_descriptor = os.open(
            candidate_path.parts[-1],
            file_flags,
            dir_fd=directories[-1],
        )
        status = os.fstat(file_descriptor)
        if not stat.S_ISREG(status.st_mode):
            raise VerificationError("managed file is missing or not regular")
        if status.st_uid != os.getuid() or stat.S_IMODE(status.st_mode) & 0o077:
            raise VerificationError("managed file ownership or permissions are not private")
        if status.st_size <= 0 or status.st_size > maximum:
            raise VerificationError("managed file size is outside the accepted range")
        source = os.fdopen(file_descriptor, "rb", closefd=True)
        file_descriptor = -1
        yield source
    except OSError as error:
        raise VerificationError("managed path could not be opened safely") from error
    finally:
        if source is not None:
            source.close()
        elif file_descriptor >= 0:
            os.close(file_descriptor)
        for descriptor in reversed(directories):
            os.close(descriptor)


def pcm_samples(data: bytes, sample_width: int) -> tuple[int, float, float, float]:
    if sample_width == 1:
        values = (byte - 128 for byte in data)
        peak = 128.0
    elif sample_width in {2, 4}:
        typecode = "h" if sample_width == 2 else "i"
        decoded = array.array(typecode)
        decoded.frombytes(data)
        if sys.byteorder != "little":
            decoded.byteswap()
        values = iter(decoded)
        peak = float(1 << (sample_width * 8 - 1))
    elif sample_width == 3:
        def signed_24() -> object:
            for offset in range(0, len(data) - 2, 3):
                value = int.from_bytes(data[offset : offset + 3], "little", signed=False)
                yield value - (1 << 24) if value & (1 << 23) else value

        values = signed_24()
        peak = float(1 << 23)
    else:
        raise VerificationError("unsupported PCM sample width")

    count = 0
    square_sum = 0.0
    quiet = 0
    maximum = 0.0
    quiet_limit = peak * 0.001
    for value in values:
        numeric = float(value)
        count += 1
        square_sum += numeric * numeric
        maximum = max(maximum, abs(numeric))
        if abs(numeric) <= quiet_limit:
            quiet += 1
    if count == 0:
        raise VerificationError("WAV contains no samples")
    normalized_rms = math.sqrt(square_sum / count) / peak
    return count, normalized_rms, quiet / count, maximum / peak


def inspect_wav(data: bytes) -> tuple[float, float, float, float]:
    if (
        len(data) < 44
        or data[:4] != b"RIFF"
        or data[8:12] != b"WAVE"
        or struct.unpack_from("<I", data, 4)[0] + 8 != len(data)
    ):
        raise VerificationError("WAV container is invalid")

    offset = 12
    found_format = False
    found_audio = False
    rate = 0
    width = 0
    block_alignment = 0
    sample_data = b""
    while offset + 8 <= len(data):
        identifier = data[offset : offset + 4]
        size = struct.unpack_from("<I", data, offset + 4)[0]
        payload_start = offset + 8
        payload_end = payload_start + size
        padded_end = payload_end + (size & 1)
        if payload_end > len(data) or padded_end > len(data):
            raise VerificationError("WAV container is invalid")

        if identifier == b"fmt ":
            if found_format or size < 16:
                raise VerificationError("WAV geometry is invalid")
            format_tag, channels, rate, byte_rate, block_alignment, bits_per_sample = (
                struct.unpack_from("<HHIIHH", data, payload_start)
            )
            width = bits_per_sample // 8
            expected_block_alignment = channels * width
            if (
                format_tag != 1
                or not 1 <= channels <= 8
                or not MIN_PCM_SAMPLE_RATE <= rate <= MAX_PCM_SAMPLE_RATE
                or bits_per_sample not in {8, 16, 24, 32}
                or block_alignment != expected_block_alignment
                or byte_rate != rate * expected_block_alignment
            ):
                raise VerificationError("WAV geometry is invalid")
            found_format = True
        elif identifier == b"data":
            if (
                found_audio
                or not found_format
                or size == 0
                or size % block_alignment != 0
            ):
                raise VerificationError("WAV geometry is invalid")
            frames = size // block_alignment
            if frames > rate * 60:
                raise VerificationError("WAV geometry is invalid")
            sample_data = data[payload_start:payload_end]
            found_audio = True

        offset = padded_end

    if not found_format or not found_audio or offset != len(data):
        raise VerificationError("WAV container is invalid")

    frames = len(sample_data) // block_alignment
    _, normalized_rms, quiet_ratio, normalized_peak = pcm_samples(sample_data, width)
    duration = frames / rate
    if duration < 0.05:
        raise VerificationError("WAV is too short")
    if duration > MAX_STATE_AUDIO_DURATION_SECONDS:
        raise VerificationError("WAV exceeds the accepted short-state duration")
    if normalized_rms < 0.0001 or normalized_peak < 0.005 or quiet_ratio > 0.995:
        raise VerificationError("WAV is effectively silent")
    return duration, normalized_rms, quiet_ratio, normalized_peak


def digest(source: BinaryIO) -> str:
    hasher = hashlib.sha256()
    for chunk in iter(lambda: source.read(1024 * 1024), b""):
        hasher.update(chunk)
    return hasher.hexdigest()


def verify(args: argparse.Namespace) -> None:
    support_root = args.support_root.expanduser()
    try:
        with managed_file(
            support_root,
            "voice/dialogue-voice.json",
            "voice/",
            MAX_LIBRARY_BYTES,
        ) as source:
            library = json.loads(source.read().decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise VerificationError("voice library is not valid JSON") from error
    if (
        not isinstance(library, dict)
        or type(library.get("version")) is not int
        or library.get("version") != 1
    ):
        raise VerificationError("voice library schema is unsupported")
    profile = library.get("profile")
    profile_revision = validate_profile_schema(profile)
    profile_status = library.get("profile_status", "ready")
    if profile_status not in {"ready", "unavailable"}:
        raise VerificationError("voice profile status is invalid")
    lines = validate_lines_schema(library.get("lines"), profile_revision)
    pending_cleanup_paths = library.get("pending_cleanup_paths", [])
    validate_cleanup_schema(pending_cleanup_paths, profile, lines)

    assets = (
        (
            "gpt",
            profile.get("gpt_weight_relative_path"),
            "voice/assets/gpt/",
            4 * 1024 * 1024 * 1024,
        ),
        (
            "sovits",
            profile.get("sovits_weight_relative_path"),
            "voice/assets/sovits/",
            4 * 1024 * 1024 * 1024,
        ),
        (
            "reference",
            profile.get("reference_audio_relative_path"),
            "voice/assets/reference/",
            MAX_AUDIO_BYTES,
        ),
    )
    for label, relative, prefix, maximum in assets:
        with managed_file(support_root, relative, prefix, maximum) as source:
            if args.hash_assets:
                print(f"asset={label} sha256={digest(source)}")

    failures = []
    reports = []
    if profile_status != "ready" and not args.allow_pending:
        failures.append("voice profile is unavailable")
    for state in REQUIRED_STATES:
        matching = [
            line
            for line in lines
            if isinstance(line, dict) and line.get("state", "idle") == state
        ]
        ready = [
            line
            for line in matching
            if line.get("status") == "ready"
        ]
        if not ready:
            statuses = sorted(
                {
                    status if isinstance(status, str) and status else "invalid"
                    for status in (line.get("status") for line in matching)
                }
            )
            observed = ",".join(statuses) if statuses else "missing"
            if args.allow_pending and matching:
                reports.append(f"state={state} status=pending observed={observed}")
                continue
            failures.append(f"state {state} has no ready dialogue (observed={observed})")
            continue
        line = ready[0]
        try:
            if line.get("generated_synthesis_policy_version") != args.required_policy_version:
                raise VerificationError("uses an outdated synthesis policy")
            with managed_file(
                support_root,
                line.get("output_relative_path"),
                "voice/generated/",
                MAX_AUDIO_BYTES,
            ) as source:
                audio_data = source.read(MAX_AUDIO_BYTES + 1)
            if len(audio_data) > MAX_AUDIO_BYTES:
                raise VerificationError("managed file size is outside the accepted range")
            duration, normalized_rms, quiet_ratio, normalized_peak = inspect_wav(audio_data)
        except VerificationError as error:
            failures.append(f"state {state}: {error}")
            continue
        reports.append(
            f"state={state} status=ready duration={duration:.3f}s "
            f"normalized_rms={normalized_rms:.6f} normalized_peak={normalized_peak:.6f} "
            f"quiet_ratio={quiet_ratio:.3f}"
        )
    for report in reports:
        print(report)
    if failures:
        raise VerificationError("; ".join(failures))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--support-root",
        type=Path,
        default=Path.home() / "Library" / "Application Support" / "Statelet",
    )
    parser.add_argument(
        "--required-policy-version",
        type=int,
        default=DEFAULT_POLICY_VERSION,
    )
    parser.add_argument("--allow-pending", action="store_true")
    parser.add_argument("--hash-assets", action="store_true")
    return parser.parse_args()


def main() -> int:
    try:
        verify(parse_args())
    except VerificationError as error:
        print(f"verification failed: {error}", file=sys.stderr)
        return 1
    print("Statelet local voice verification passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
