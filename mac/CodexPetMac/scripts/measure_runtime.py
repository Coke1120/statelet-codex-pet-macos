#!/usr/bin/env python3
"""Measure Statelet CPU, memory, and warm presentation latency on macOS.

Live mode is intentionally opt-in and local-only. Parser mode evaluates a
fixture without launching AppKit, so hosted CI can test the report contract.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple


VALID_STATES = ("idle", "running", "waiting", "review")
DEFAULT_LIMITS = {
    "player_cpu_average_percent": 3.0,
    "player_rss_peak_mb": 120.0,
    "warm_switch_p95_ms": 300.0,
    "aggregator_cpu_average_percent": 0.3,
    "hard_cpu_sustained_percent": 8.0,
    "hard_cpu_sustained_seconds": 60.0,
    "hard_rss_peak_mb": 250.0,
}
DISPLAY_READY_MARKER = re.compile(r"\bevent=display_ready\b")
TRANSITION_ID = re.compile(r"\btransition_id=(?P<transition_id>[0-9]+)\b")
DISPLAY_READY_DURATION = re.compile(
    r"\bduration_ms=(?P<duration>[0-9]+(?:\.[0-9]+)?)\b"
)
PATH_LIKE = re.compile(
    r"(?:file://|(?:^|[\s=:'\"])(?:~/|/)[^\s'\"]+|"
    r"(?:^|[\s=:'\"])[A-Za-z]:\\[^\s'\"]+)"
)
LOG_READ_CHUNK_BYTES = 4096
LOG_LINE_LIMIT_BYTES = 8192
DISPLAY_READY_EVENT_LIMIT = 8192
MAX_FIXTURE_BYTES = 1024 * 1024
MAX_PROCESS_SAMPLES = 20000
MIN_PLAYER_SAMPLES = 10
MIN_WARM_TRANSITIONS = 5
OBSERVATION_TARGET_SECONDS = 60.0
OBSERVATION_TOLERANCE_SECONDS = 0.05


class HarnessError(Exception):
    """A safe, user-actionable harness failure."""


def _finite_number(value: Any, label: str) -> float:
    if isinstance(value, bool):
        raise HarnessError("invalid_{}".format(label))
    try:
        result = float(value)
    except (TypeError, ValueError):
        raise HarnessError("invalid_{}".format(label))
    if not math.isfinite(result) or result < 0:
        raise HarnessError("invalid_{}".format(label))
    return result


def _local_regular_file(raw: str, executable: bool = False) -> Path:
    if not raw or "://" in raw:
        raise HarnessError("invalid_local_input")
    supplied = Path(raw).expanduser()
    if not supplied.is_absolute() or supplied.is_symlink():
        raise HarnessError("invalid_local_input")
    try:
        info = supplied.lstat()
        resolved = supplied.resolve(strict=True)
    except OSError:
        raise HarnessError("invalid_local_input")
    # Parent components such as macOS /var -> /private/var may resolve through
    # system-managed symlinks. Reject a symlink at the supplied file itself,
    # while accepting those stable parent aliases.
    if not stat.S_ISREG(info.st_mode):
        raise HarnessError("invalid_local_input")
    if hasattr(os, "getuid") and info.st_uid != os.getuid():
        raise HarnessError("unowned_local_input")
    if executable and not os.access(str(resolved), os.X_OK):
        raise HarnessError("input_not_executable")
    if not os.access(str(resolved), os.R_OK):
        raise HarnessError("input_not_readable")
    return resolved


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _read_bounded_fixture(path: Path) -> bytes:
    """Read one owned regular fixture without following its final symlink."""
    flags = os.O_RDONLY
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor: Optional[int] = None
    try:
        descriptor = os.open(str(path), flags)
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise HarnessError("invalid_fixture")
        if hasattr(os, "getuid") and before.st_uid != os.getuid():
            raise HarnessError("invalid_fixture")
        if before.st_size > MAX_FIXTURE_BYTES:
            raise HarnessError("fixture_too_large")
        content = bytearray()
        while len(content) <= MAX_FIXTURE_BYTES:
            chunk = os.read(
                descriptor,
                min(64 * 1024, MAX_FIXTURE_BYTES + 1 - len(content)),
            )
            if not chunk:
                break
            content.extend(chunk)
        if len(content) > MAX_FIXTURE_BYTES:
            raise HarnessError("fixture_too_large")
        after = os.fstat(descriptor)
        if (
            before.st_dev,
            before.st_ino,
            before.st_size,
            before.st_mtime_ns,
            before.st_ctime_ns,
        ) != (
            after.st_dev,
            after.st_ino,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        ):
            raise HarnessError("fixture_changed_during_read")
        return bytes(content)
    except HarnessError:
        raise
    except OSError:
        raise HarnessError("invalid_fixture")
    finally:
        if descriptor is not None:
            os.close(descriptor)


def percentile(values: Sequence[float], percentile_value: float) -> Optional[float]:
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, int(math.ceil((percentile_value / 100.0) * len(ordered))))
    return ordered[rank - 1]


def _collector_from_text(text: str) -> "BoundedDisplayReadyCollector":
    collector = BoundedDisplayReadyCollector()
    encoded = text.encode("utf-8", errors="replace")
    for offset in range(0, len(encoded), LOG_READ_CHUNK_BYTES):
        collector.feed(encoded[offset : offset + LOG_READ_CHUNK_BYTES])
    collector.finish()
    return collector


def parse_display_ready(text: str) -> List[Tuple[int, float]]:
    collector = _collector_from_text(text)
    if collector.malformed_event_count:
        raise HarnessError("malformed_display_ready_event")
    if collector.discarded_event_count:
        raise HarnessError("display_ready_event_limit_exceeded")
    if collector.oversized_line_count:
        raise HarnessError("oversized_log_line")
    return collector.snapshot()


class BoundedDisplayReadyCollector:
    """Incrementally retain only bounded display-ready duration values."""

    def __init__(
        self,
        event_limit: int = DISPLAY_READY_EVENT_LIMIT,
        line_limit_bytes: int = LOG_LINE_LIMIT_BYTES,
    ) -> None:
        if event_limit < 1 or line_limit_bytes < 128:
            raise ValueError("collector limits must be positive")
        self.event_limit = event_limit
        self.line_limit_bytes = line_limit_bytes
        self._line = bytearray()
        self._discarding_line = False
        self._events: List[Tuple[int, float]] = []
        self._seen_transition_ids = set()  # type: set
        self.discarded_event_count = 0
        self.duplicate_event_count = 0
        self.malformed_event_count = 0
        self.oversized_line_count = 0

    def feed(self, chunk: bytes) -> None:
        """Consume one bounded-size byte chunk without retaining raw log text."""
        if len(chunk) > LOG_READ_CHUNK_BYTES:
            raise ValueError("log chunk exceeds the read bound")
        for byte in chunk:
            if byte == 0x0A:
                if not self._discarding_line:
                    self._consume_line()
                self._line.clear()
                self._discarding_line = False
                continue
            if self._discarding_line:
                continue
            if len(self._line) >= self.line_limit_bytes:
                self._line.clear()
                self._discarding_line = True
                self.oversized_line_count += 1
                continue
            self._line.append(byte)

    def finish(self) -> None:
        if self._line and not self._discarding_line:
            self._consume_line()
        self._line.clear()
        self._discarding_line = False

    def snapshot(self) -> List[Tuple[int, float]]:
        return list(self._events)

    @property
    def tracked_transition_id_count(self) -> int:
        return len(self._seen_transition_ids)

    def _consume_line(self) -> None:
        line = self._line.decode("utf-8", errors="replace")
        if not DISPLAY_READY_MARKER.search(line):
            return
        transition_match = TRANSITION_ID.search(line)
        duration_match = DISPLAY_READY_DURATION.search(line)
        if transition_match is None or duration_match is None:
            self.malformed_event_count += 1
            return
        transition_id = int(transition_match.group("transition_id"))
        if transition_id < 1:
            self.malformed_event_count += 1
            return
        duration = _finite_number(
            duration_match.group("duration"), "display_ready_duration"
        )
        if transition_id in self._seen_transition_ids:
            self.duplicate_event_count += 1
            return
        if len(self._events) >= self.event_limit:
            self.discarded_event_count += 1
            return
        self._seen_transition_ids.add(transition_id)
        self._events.append((transition_id, duration))


class StateCycler:
    """Return every transition due while cycling a finite state sequence."""

    def __init__(self, states: Sequence[str], interval: float) -> None:
        if len(states) < 2 or any(state not in VALID_STATES for state in states):
            raise ValueError("invalid state sequence")
        if not math.isfinite(interval) or interval <= 0:
            raise ValueError("invalid transition interval")
        self.states = tuple(states)
        self.interval = interval
        self.next_transition = interval
        self.index = 1

    def due(self, elapsed: float) -> List[str]:
        result: List[str] = []
        while elapsed >= self.next_transition:
            result.append(self.states[self.index])
            self.index = (self.index + 1) % len(self.states)
            self.next_transition += self.interval
        return result


def drain_unified_log(
    file_descriptor: int,
    collector: BoundedDisplayReadyCollector,
    errors: List[str],
) -> None:
    """Continuously drain log output; retain no raw line or path data."""
    try:
        while True:
            chunk = os.read(file_descriptor, LOG_READ_CHUNK_BYTES)
            if not chunk:
                break
            collector.feed(chunk)
    except (OSError, ValueError, HarnessError):
        errors.append("log_stream_drain_failed")
    finally:
        collector.finish()


def _consecutive_over(samples: Sequence[Dict[str, float]], threshold: float) -> float:
    longest = 0.0
    current = 0.0
    previous_time: Optional[float] = None
    for sample in samples:
        timestamp = sample["time_seconds"]
        interval = 0.0 if previous_time is None else max(0.0, timestamp - previous_time)
        previous_time = timestamp
        if sample["cpu_percent"] > threshold:
            current += interval
            longest = max(longest, current)
        else:
            current = 0.0
    return longest


def _rss_slope(samples: Sequence[Dict[str, float]]) -> Optional[float]:
    if len(samples) < 2:
        return None
    xs = [sample["time_seconds"] for sample in samples]
    ys = [sample["rss_mb"] for sample in samples]
    mean_x = sum(xs) / len(xs)
    mean_y = sum(ys) / len(ys)
    denominator = sum((value - mean_x) ** 2 for value in xs)
    if denominator <= 0:
        return None
    mb_per_second = sum(
        (x - mean_x) * (y - mean_y) for x, y in zip(xs, ys)
    ) / denominator
    return mb_per_second * 3600.0


def normalize_samples(raw_samples: Any, label: str) -> List[Dict[str, float]]:
    if raw_samples is None:
        return []
    if not isinstance(raw_samples, list):
        raise HarnessError("invalid_{}_samples".format(label))
    if len(raw_samples) > MAX_PROCESS_SAMPLES:
        raise HarnessError("{}_sample_limit_exceeded".format(label))
    result: List[Dict[str, float]] = []
    last_time = -1.0
    for raw in raw_samples:
        if not isinstance(raw, dict) or set(raw) != {
            "time_seconds",
            "cpu_percent",
            "rss_mb",
        }:
            raise HarnessError("invalid_{}_samples".format(label))
        sample = {
            "time_seconds": _finite_number(raw["time_seconds"], "sample_time"),
            "cpu_percent": _finite_number(raw["cpu_percent"], "sample_cpu"),
            "rss_mb": _finite_number(raw["rss_mb"], "sample_rss"),
        }
        if sample["time_seconds"] <= last_time:
            raise HarnessError("non_monotonic_{}_samples".format(label))
        last_time = sample["time_seconds"]
        result.append(sample)
    return result


def summarize_process(samples: Sequence[Dict[str, float]]) -> Dict[str, Any]:
    if not samples:
        return {
            "sample_count": 0,
            "cpu_average_percent": None,
            "cpu_peak_percent": None,
            "cpu_over_hard_limit_longest_seconds": None,
            "rss_average_mb": None,
            "rss_peak_mb": None,
            "rss_slope_mb_per_hour": None,
        }
    cpus = [sample["cpu_percent"] for sample in samples]
    rss = [sample["rss_mb"] for sample in samples]
    return {
        "sample_count": len(samples),
        "cpu_average_percent": round(sum(cpus) / len(cpus), 3),
        "cpu_peak_percent": round(max(cpus), 3),
        "cpu_over_hard_limit_longest_seconds": round(
            _consecutive_over(samples, DEFAULT_LIMITS["hard_cpu_sustained_percent"]), 3
        ),
        "rss_average_mb": round(sum(rss) / len(rss), 3),
        "rss_peak_mb": round(max(rss), 3),
        "rss_slope_mb_per_hour": (
            None
            if _rss_slope(samples) is None
            else round(_rss_slope(samples) or 0.0, 3)
        ),
    }


def observation_span(samples: Sequence[Dict[str, float]]) -> Optional[float]:
    if len(samples) < 2:
        return None
    return max(0.0, samples[-1]["time_seconds"] - samples[0]["time_seconds"])


def final_observation_timestamp(started_at: float, now: Optional[float] = None) -> float:
    """Return honest monotonic elapsed time for the final process samples."""
    current = time.monotonic() if now is None else now
    if not math.isfinite(started_at) or not math.isfinite(current):
        raise HarnessError("invalid_observation_clock")
    return max(0.0, current - started_at)


def evaluate(
    player_samples: Sequence[Dict[str, float]],
    display_ready_events: Sequence[Tuple[int, float]],
    aggregator_samples: Sequence[Dict[str, float]] = (),
    executable_sha256: Optional[str] = None,
    footprint_mb: Optional[float] = None,
    requested_duration_seconds: float = OBSERVATION_TARGET_SECONDS,
    duplicate_display_ready_count: int = 0,
    aggregator_requested: bool = False,
    aggregator_identity_validated: bool = False,
    measurement_mode: str = "fixture",
) -> Tuple[Dict[str, Any], bool]:
    if measurement_mode not in {"fixture", "live"}:
        raise HarnessError("invalid_measurement_mode")
    player = summarize_process(player_samples)
    aggregator = summarize_process(aggregator_samples)
    warm = [
        duration
        for transition_id, duration in display_ready_events
        if transition_id != 1
    ]
    cold_count = sum(
        1 for transition_id, _ in display_ready_events if transition_id == 1
    )
    warm_p95 = percentile(warm, 95.0)
    player_span = observation_span(player_samples)
    aggregator_span = observation_span(aggregator_samples)
    required_span = min(
        OBSERVATION_TARGET_SECONDS,
        _finite_number(requested_duration_seconds, "requested_duration"),
    )
    checks: List[Dict[str, Any]] = []

    def check(
        name: str,
        actual: Optional[float],
        limit: float,
        required: bool = True,
        fail_at_limit: bool = False,
    ) -> None:
        passed = actual is not None and (
            actual < limit if fail_at_limit else actual <= limit
        )
        checks.append(
            {
                "name": name,
                "actual": actual,
                "limit": limit,
                "comparison": "<" if fail_at_limit else "<=",
                "required": required,
                "passed": passed if required or actual is not None else None,
            }
        )

    def minimum_check(
        name: str,
        actual: Optional[float],
        minimum: float,
        required: bool = True,
        tolerance: float = 0.0,
    ) -> None:
        passed = actual is not None and actual + tolerance >= minimum
        checks.append(
            {
                "name": name,
                "actual": actual,
                "limit": minimum,
                "comparison": ">=",
                "required": required,
                "passed": passed if required or actual is not None else None,
            }
        )

    minimum_check(
        "player_sample_count",
        float(len(player_samples)),
        MIN_PLAYER_SAMPLES,
    )
    minimum_check(
        "player_observation_span_seconds",
        player_span,
        required_span,
        tolerance=OBSERVATION_TOLERANCE_SECONDS,
    )
    minimum_check(
        "warm_switch_count",
        float(len(warm)),
        MIN_WARM_TRANSITIONS,
    )

    check(
        "player_cpu_average_percent",
        player["cpu_average_percent"],
        DEFAULT_LIMITS["player_cpu_average_percent"],
    )
    check(
        "player_rss_peak_mb",
        player["rss_peak_mb"],
        DEFAULT_LIMITS["player_rss_peak_mb"],
    )
    check("warm_switch_p95_ms", warm_p95, DEFAULT_LIMITS["warm_switch_p95_ms"])
    check(
        "player_cpu_sustained_hard_seconds",
        player["cpu_over_hard_limit_longest_seconds"],
        DEFAULT_LIMITS["hard_cpu_sustained_seconds"],
        fail_at_limit=True,
    )
    check(
        "player_rss_hard_mb",
        player["rss_peak_mb"],
        DEFAULT_LIMITS["hard_rss_peak_mb"],
    )
    check(
        "aggregator_cpu_average_percent",
        aggregator["cpu_average_percent"],
        DEFAULT_LIMITS["aggregator_cpu_average_percent"],
        required=aggregator_requested,
    )
    minimum_check(
        "aggregator_sample_count",
        float(len(aggregator_samples)) if aggregator_requested else None,
        MIN_PLAYER_SAMPLES,
        required=aggregator_requested,
    )
    minimum_check(
        "aggregator_observation_span_seconds",
        aggregator_span,
        required_span,
        required=aggregator_requested,
        tolerance=OBSERVATION_TOLERANCE_SECONDS,
    )
    passed = all(item["passed"] is not False for item in checks)
    report = {
        "schema_version": 1,
        "passed": passed,
        "measurement": {
            "mode": measurement_mode,
            "live": measurement_mode == "live",
        },
        "limits": dict(DEFAULT_LIMITS),
        "evidence_minimums": {
            "player_sample_count": MIN_PLAYER_SAMPLES,
            "warm_transition_count": MIN_WARM_TRANSITIONS,
            "maximum_required_span_seconds": OBSERVATION_TARGET_SECONDS,
        },
        "executable": {
            "sha256": executable_sha256,
            "attested": bool(
                measurement_mode == "live"
                and executable_sha256
                and re.fullmatch(r"[0-9a-f]{64}", executable_sha256)
            ),
        },
        "player": player,
        "aggregator": dict(
            aggregator,
            requested=aggregator_requested,
            identity_validated=aggregator_identity_validated,
        ),
        "observation": {
            "requested_duration_seconds": requested_duration_seconds,
            "required_span_seconds": required_span,
            "tolerance_seconds": OBSERVATION_TOLERANCE_SECONDS,
            "player_span_seconds": player_span,
            "aggregator_span_seconds": aggregator_span,
        },
        "presentation": {
            "display_ready_count": len(display_ready_events),
            "cold_start_count": cold_count,
            "warm_switch_count": len(warm),
            "duplicate_transition_count": duplicate_display_ready_count,
            "warm_switch_average_ms": (
                None if not warm else round(sum(warm) / len(warm), 3)
            ),
            "warm_switch_peak_ms": None if not warm else round(max(warm), 3),
            "warm_switch_p95_ms": None if warm_p95 is None else round(warm_p95, 3),
        },
        "footprint": {
            "available": footprint_mb is not None,
            "physical_footprint_mb": footprint_mb,
        },
        "checks": checks,
    }
    return report, passed


def evaluate_fixture(path: Path) -> Tuple[Dict[str, Any], bool]:
    try:
        payload = json.loads(_read_bounded_fixture(path).decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        raise HarnessError("invalid_fixture")
    if not isinstance(payload, dict):
        raise HarnessError("invalid_fixture")
    allowed = {
        "player_samples",
        "aggregator_samples",
        "log",
        "executable_sha256",
        "footprint_mb",
        "requested_duration_seconds",
    }
    if not set(payload).issubset(allowed):
        raise HarnessError("invalid_fixture")
    log_text = payload.get("log", "")
    if not isinstance(log_text, str) or PATH_LIKE.search(log_text):
        raise HarnessError("unsafe_fixture_log")
    digest = payload.get("executable_sha256")
    if digest is not None and (
        not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest)
    ):
        raise HarnessError("invalid_executable_digest")
    footprint = payload.get("footprint_mb")
    normalized_footprint = (
        None if footprint is None else _finite_number(footprint, "footprint")
    )
    if "requested_duration_seconds" not in payload:
        raise HarnessError("fixture_requested_duration_required")
    requested_duration = _finite_number(
        payload["requested_duration_seconds"], "requested_duration"
    )
    if requested_duration <= 0 or requested_duration > 3600:
        raise HarnessError("invalid_requested_duration")
    collector = _collector_from_text(log_text)
    if collector.malformed_event_count:
        raise HarnessError("malformed_display_ready_event")
    if collector.discarded_event_count:
        raise HarnessError("display_ready_event_limit_exceeded")
    if collector.oversized_line_count:
        raise HarnessError("oversized_log_line")
    aggregator_samples = normalize_samples(
        payload.get("aggregator_samples"), "aggregator"
    )
    return evaluate(
        normalize_samples(payload.get("player_samples"), "player"),
        collector.snapshot(),
        aggregator_samples,
        digest,
        normalized_footprint,
        requested_duration_seconds=requested_duration,
        duplicate_display_ready_count=collector.duplicate_event_count,
        aggregator_requested="aggregator_samples" in payload,
        measurement_mode="fixture",
    )


def _resolve_media_path(raw: str, base: Path) -> str:
    candidate = Path(raw).expanduser()
    if not candidate.is_absolute():
        candidate = base / candidate
    # Normalize dot components without resolving the final component first;
    # _local_regular_file must still see and reject a media-file symlink.
    normalized = Path(os.path.abspath(str(candidate)))
    return str(_local_regular_file(str(normalized)))


def isolated_media_map(source: Path, destination: Path) -> None:
    try:
        payload = json.loads(source.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        raise HarnessError("invalid_media_map")
    if not isinstance(payload, dict) or not isinstance(payload.get("states"), dict):
        raise HarnessError("invalid_media_map")
    base = source.parent
    for state, configuration in payload["states"].items():
        if state not in VALID_STATES or not isinstance(configuration, dict):
            raise HarnessError("invalid_media_map")
        if isinstance(configuration.get("path"), str):
            configuration["path"] = _resolve_media_path(configuration["path"], base)
        if isinstance(configuration.get("fixed_path"), str):
            configuration["fixed_path"] = _resolve_media_path(configuration["fixed_path"], base)
        entries = configuration.get("entries", [])
        if entries is not None and not isinstance(entries, list):
            raise HarnessError("invalid_media_map")
        for entry in entries or []:
            if not isinstance(entry, dict) or not isinstance(entry.get("path"), str):
                raise HarnessError("invalid_media_map")
            entry["path"] = _resolve_media_path(entry["path"], base)
            if isinstance(entry.get("poster_path"), str):
                entry["poster_path"] = _resolve_media_path(entry["poster_path"], base)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(
        json.dumps(payload, separators=(",", ":"), sort_keys=True) + "\n",
        encoding="utf-8",
    )
    destination.chmod(0o600)


def atomic_state_write(path: Path, state: str) -> None:
    if state not in VALID_STATES:
        raise HarnessError("invalid_state_sequence")
    now = time.time()
    payload = {
        "active_sessions": 1,
        "emitted_at": now,
        "forced": False,
        "priority": {"idle": 0, "running": 1, "review": 2, "waiting": 3}[state],
        "schema_version": 1,
        "source": "aggregate",
        "source_updated_at": now,
        "state": state,
        "updated_at": now,
        "version": 1,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.parent.chmod(0o700)
    temporary = path.parent / ".statelet-performance-state.tmp"
    temporary.write_text(
        json.dumps(payload, separators=(",", ":"), sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.chmod(0o600)
    os.replace(str(temporary), str(path))


def sample_process(pid: int, elapsed: float) -> Optional[Dict[str, float]]:
    try:
        result = subprocess.run(
            ["/bin/ps", "-o", "%cpu=,rss=", "-p", str(pid)],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=3.0,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    fields = result.stdout.strip().split()
    if result.returncode != 0 or len(fields) != 2:
        return None
    try:
        cpu = float(fields[0])
        rss_mb = float(fields[1]) / 1024.0
    except ValueError:
        return None
    if not math.isfinite(cpu) or not math.isfinite(rss_mb) or cpu < 0 or rss_mb < 0:
        return None
    return {"time_seconds": elapsed, "cpu_percent": cpu, "rss_mb": rss_mb}


def positive_pid(raw: str) -> int:
    try:
        value = int(raw)
    except (TypeError, ValueError):
        raise argparse.ArgumentTypeError("PID must be a positive integer")
    if value <= 0:
        raise argparse.ArgumentTypeError("PID must be a positive integer")
    return value


def validate_aggregator_process(pid: int) -> None:
    """Require an owned live process whose command identifies the aggregator."""
    try:
        result = subprocess.run(
            ["/bin/ps", "-o", "uid=,command=", "-p", str(pid)],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=3.0,
        )
    except (OSError, subprocess.TimeoutExpired):
        raise HarnessError("invalid_aggregator_pid")
    fields = result.stdout.strip().split(None, 1)
    if (
        result.returncode != 0
        or len(fields) != 2
        or fields[0] != str(os.getuid())
        or "codex_pet_state_aggregator.py" not in fields[1]
    ):
        raise HarnessError("invalid_aggregator_pid")


def optional_footprint(pid: int) -> Optional[float]:
    executable = shutil.which("footprint")
    if not executable:
        return None
    try:
        result = subprocess.run(
            [executable, "-p", str(pid)],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=10.0,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    matches = re.findall(
        r"(?:physical footprint|Footprint):?\s*([0-9.]+)\s*(KB|MB|GB)",
        result.stdout,
        re.IGNORECASE,
    )
    if not matches:
        return None
    value, unit = matches[-1]
    multiplier = {"KB": 1.0 / 1024.0, "MB": 1.0, "GB": 1024.0}[unit.upper()]
    return round(float(value) * multiplier, 3)


def _terminate_group(process: Optional[subprocess.Popen[str]]) -> None:
    if process is None or process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=5.0)
    except (OSError, subprocess.TimeoutExpired):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            process.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            pass


def build_player_command(
    executable: Path,
    media_map: Path,
    state_path: Path,
) -> List[str]:
    """Keep the measured panel visible so occlusion suspension cannot skew it."""
    return [
        str(executable),
        "--media-map",
        str(media_map),
        "--state",
        str(state_path),
        "--always-on-top",
        "--no-click-through",
    ]


def build_log_command(process_id: int) -> List[str]:
    """Capture informational presentation events for only the measured process."""
    return [
        "/usr/bin/log",
        "stream",
        "--style",
        "compact",
        "--info",
        "--predicate",
        'processID == {} AND subsystem == "com.coke1120.CodexPetMac"'.format(
            process_id
        ),
    ]


def run_live(args: argparse.Namespace) -> Tuple[Dict[str, Any], bool]:
    if sys.platform != "darwin":
        raise HarnessError("live_mode_requires_macos")
    executable = _local_regular_file(args.executable, executable=True)
    source_map = _local_regular_file(args.media_map)
    states = [
        value.strip().lower() for value in args.states.split(",") if value.strip()
    ]
    if len(states) < 2 or any(state not in VALID_STATES for state in states):
        raise HarnessError("invalid_state_sequence")
    if args.aggregator_pid is not None:
        validate_aggregator_process(args.aggregator_pid)
    digest = sha256_file(executable)
    player: Optional[subprocess.Popen[str]] = None
    log_process: Optional[subprocess.Popen[bytes]] = None
    log_thread: Optional[threading.Thread] = None
    log_errors: List[str] = []
    log_collector = BoundedDisplayReadyCollector()
    with tempfile.TemporaryDirectory(prefix="statelet-performance-") as raw_root:
        root = Path(raw_root)
        home = root / "home"
        temporary = root / "tmp"
        media_map = root / "media" / "media-map.json"
        state_path = root / "runtime" / "current_state.json"
        home.mkdir(mode=0o700)
        temporary.mkdir(mode=0o700)
        isolated_media_map(source_map, media_map)
        atomic_state_write(state_path, states[0])
        environment = os.environ.copy()
        environment.update(
            {
                "HOME": str(home),
                "CFFIXED_USER_HOME": str(home),
                "TMPDIR": str(temporary),
            }
        )
        command = build_player_command(executable, media_map, state_path)
        samples: List[Dict[str, float]] = []
        aggregator_samples: List[Dict[str, float]] = []
        try:
            player = subprocess.Popen(
                command,
                env=environment,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                text=True,
                start_new_session=True,
            )
            log_command = build_log_command(player.pid)
            log_process = subprocess.Popen(
                log_command,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            if log_process.stdout is None:
                raise HarnessError("log_stream_unavailable")
            log_thread = threading.Thread(
                target=drain_unified_log,
                args=(log_process.stdout.fileno(), log_collector, log_errors),
                name="statelet-performance-log-drain",
                daemon=True,
            )
            log_thread.start()
            start = time.monotonic()
            cycler = StateCycler(states, args.transition_interval)
            while True:
                elapsed = time.monotonic() - start
                if elapsed >= args.duration:
                    break
                if player.poll() is not None:
                    raise HarnessError("player_exited_early")
                for state in cycler.due(elapsed):
                    atomic_state_write(state_path, state)
                sample = sample_process(player.pid, elapsed)
                if sample is not None:
                    samples.append(sample)
                if args.aggregator_pid is not None:
                    aggregator_sample = sample_process(args.aggregator_pid, elapsed)
                    if aggregator_sample is not None:
                        aggregator_samples.append(aggregator_sample)
                time.sleep(min(args.interval, max(0.0, args.duration - elapsed)))
            if player.poll() is not None:
                raise HarnessError("player_exited_early")
            for state in cycler.due(args.duration):
                atomic_state_write(state_path, state)
            final_timestamp = final_observation_timestamp(start)
            final_sample = sample_process(player.pid, final_timestamp)
            if final_sample is not None:
                samples.append(final_sample)
            if args.aggregator_pid is not None:
                final_aggregator_sample = sample_process(
                    args.aggregator_pid, final_timestamp
                )
                if final_aggregator_sample is not None:
                    aggregator_samples.append(final_aggregator_sample)
                validate_aggregator_process(args.aggregator_pid)
            footprint = optional_footprint(player.pid)
        finally:
            _terminate_group(player)
            if log_process is not None:
                _terminate_group(log_process)
            if log_thread is not None:
                log_thread.join(timeout=3.0)
                if log_thread.is_alive() and log_process is not None:
                    if log_process.stdout is not None:
                        log_process.stdout.close()
                    log_thread.join(timeout=1.0)
                if log_thread.is_alive():
                    log_errors.append("log_stream_drain_failed")
        if len(samples) < 2:
            raise HarnessError("insufficient_process_samples")
        if log_errors:
            raise HarnessError("log_stream_drain_failed")
        if log_collector.discarded_event_count:
            raise HarnessError("display_ready_event_limit_exceeded")
        if log_collector.malformed_event_count:
            raise HarnessError("malformed_display_ready_event")
        if log_collector.oversized_line_count:
            raise HarnessError("oversized_log_line")
        if sha256_file(executable) != digest:
            raise HarnessError("executable_changed_during_run")
        return evaluate(
            samples,
            log_collector.snapshot(),
            aggregator_samples,
            executable_sha256=digest,
            footprint_mb=footprint,
            requested_duration_seconds=args.duration,
            duplicate_display_ready_count=log_collector.duplicate_event_count,
            aggregator_requested=args.aggregator_pid is not None,
            aggregator_identity_validated=args.aggregator_pid is not None,
            measurement_mode="live",
        )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Measure Statelet runtime resource use")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument(
        "--fixture",
        help="Evaluate a path-free JSON fixture without launching the app",
    )
    mode.add_argument(
        "--executable", help="Absolute, owned, non-symlink Statelet executable"
    )
    parser.add_argument(
        "--media-map", help="Absolute, owned, non-symlink media map for live mode"
    )
    parser.add_argument("--duration", type=float, default=60.0)
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument("--transition-interval", type=float, default=8.0)
    parser.add_argument("--states", default="idle,running,waiting,review,running")
    parser.add_argument(
        "--aggregator-pid",
        type=positive_pid,
        help="Optional owned codex_pet_state_aggregator.py PID to sample",
    )
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.fixture:
            fixture = _local_regular_file(args.fixture)
            report, passed = evaluate_fixture(fixture)
        else:
            if not args.media_map:
                raise HarnessError("media_map_required")
            for value, label, minimum, maximum in (
                (args.duration, "duration", 3.0, 3600.0),
                (args.interval, "interval", 0.2, 60.0),
                (args.transition_interval, "transition_interval", 0.5, 600.0),
            ):
                number = _finite_number(value, label)
                if number < minimum or number > maximum:
                    raise HarnessError("invalid_{}".format(label))
            report, passed = run_live(args)
        print(json.dumps(report, separators=(",", ":"), sort_keys=True))
        return 0 if passed else 1
    except HarnessError as error:
        print(
            json.dumps(
                {"schema_version": 1, "passed": False, "error": str(error)},
                separators=(",", ":"),
                sort_keys=True,
            )
        )
        return 2
    except (OSError, subprocess.SubprocessError):
        # Do not echo exception text: operating-system errors commonly embed
        # the private executable, media, or temporary path.
        print(
            json.dumps(
                {
                    "schema_version": 1,
                    "passed": False,
                    "error": "runtime_measurement_failed",
                },
                separators=(",", ":"),
                sort_keys=True,
            )
        )
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
