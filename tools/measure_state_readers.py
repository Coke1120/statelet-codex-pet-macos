#!/usr/bin/env python3
"""Measure synthetic lifecycle reader work without launching a native player.

Run this same script with --source-root pointing to each checkout to compare
revisions. Each iteration uses a new snapshot when the checkout supports it;
older revisions use their original three independent readers. The output
includes projection hashes and separately instrumented deterministic I/O
counts. Timings exclude fixture creation, instrumentation, and publication.
They are warm filesystem microbenchmarks, not macOS CPU or kqueue evidence.
"""

import argparse
from contextlib import nullcontext
import hashlib
import json
import platform
import statistics
import sys
import tempfile
import time
from pathlib import Path
from unittest import mock


def bounded_positive(raw: str) -> int:
    value = int(raw)
    if not 1 <= value <= 10_000:
        raise argparse.ArgumentTypeError("expected an integer from 1 to 10000")
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--sessions", nargs="+", type=bounded_positive, default=[1, 16, 64, 256, 1024])
    parser.add_argument("--rounds", type=bounded_positive, default=5)
    parser.add_argument("--iterations", type=bounded_positive, default=20)
    args = parser.parse_args()
    sys.path.insert(0, str(args.source_root.resolve() / "mac"))
    import codex_pet_state as state
    import codex_pet_state_aggregator as aggregator

    snapshot_type = getattr(state, "SessionRecordSnapshot", None)

    def project(directory):
        context = snapshot_type(directory) if snapshot_type else nullcontext(None)
        with context as records:
            options = {"records": records} if records is not None else {}
            lifecycle = aggregator.resolve_diagnostic_snapshot(directory, 900.0, 100.0, **options)
            activity = state.read_session_activity(directory, now=100.0, **options)
            targets = state.read_session_targets(directory, activity, now=100.0, **options)
        return lifecycle, activity, targets

    report = {
        "mode": "synthetic_reader_only",
        "platform": platform.system(),
        "python": platform.python_version(),
        "reader_mode": "shared_iteration" if snapshot_type else "independent",
        "rounds": args.rounds,
        "iterations_per_round": args.iterations,
        "results": [],
    }
    for count in args.sessions:
        with tempfile.TemporaryDirectory(prefix="statelet-readers-") as root:
            directory = Path(root)
            for index in range(count):
                identifier = format(index, "024x")
                (directory / (identifier + ".json")).write_text(json.dumps({
                    "version": 2, "state": "running", "event": "UserPromptSubmit",
                    "event_at": 99.0, "updated_at": 99.0, "terminal": False,
                    "completed_at": None, "rejections": {},
                }), encoding="utf-8")
                (directory / (identifier + ".target.json")).write_text(json.dumps({
                    "version": 1, "id": identifier,
                    "thread_id": "synthetic-thread-" + str(index), "updated_at": 99.0,
                }), encoding="utf-8")
            sample = project(directory)
            timings = []
            for _ in range(args.rounds):
                started = time.perf_counter_ns()
                for _ in range(args.iterations):
                    project(directory)
                timings.append((time.perf_counter_ns() - started) / args.iterations / 1e6)
            with mock.patch.object(state, "_read_hook_record", wraps=state._read_hook_record) as reads, mock.patch.object(state.os, "listdir", wraps=state.os.listdir) as lists:
                counted_sample = project(directory)
            if counted_sample != sample:
                raise RuntimeError("synthetic projections changed during measurement")
            report["results"].append({
                "sessions": count,
                "target_files": count,
                "median_ms": round(statistics.median(timings), 4),
                "rounds_ms": [round(value, 4) for value in timings],
                "record_reads_per_iteration": reads.call_count,
                "directory_lists_per_iteration": lists.call_count,
                "active_projection_count": len(sample[1]["active"]),
                "projection_sha256": hashlib.sha256(
                    json.dumps(sample, sort_keys=True, separators=(",", ":")).encode("utf-8")
                ).hexdigest(),
            })
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
