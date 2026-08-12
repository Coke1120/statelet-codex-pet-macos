#!/usr/bin/env python3
"""Parser and evaluator tests for the macOS performance harness."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "mac" / "CodexPetMac" / "scripts" / "measure_runtime.py"
SPEC = importlib.util.spec_from_file_location("measure_runtime", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
measure_runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(measure_runtime)


def samples(cpu: float, rss: float, count: int = 61):
    return [
        {"time_seconds": float(index), "cpu_percent": cpu, "rss_mb": rss + index * 0.1}
        for index in range(count)
    ]


class MacPerformanceHarnessTests(unittest.TestCase):
    def test_bounded_log_drain_collects_durations_without_raw_retention(self) -> None:
        collector = measure_runtime.BoundedDisplayReadyCollector(
            event_limit=2,
            line_limit_bytes=128,
        )
        read_fd, write_fd = os.pipe()
        errors = []
        thread = threading.Thread(
            target=measure_runtime.drain_unified_log,
            args=(read_fd, collector, errors),
        )
        thread.start()
        try:
            os.write(write_fd, b"x" * 129 + b"\n")
            os.write(
                write_fd,
                b"event=display_ready transition_id=1 duration_ms=10\n"
                b"event=display_ready transition_id=2 duration_ms=20\n"
                b"event=display_ready transition_id=3 duration_ms=30\n",
            )
        finally:
            os.close(write_fd)
        thread.join(timeout=2)
        os.close(read_fd)
        self.assertFalse(thread.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(collector.snapshot(), [(1, 10.0), (2, 20.0)])
        self.assertEqual(collector.discarded_event_count, 1)
        self.assertEqual(collector.tracked_transition_id_count, 2)
        self.assertEqual(collector.oversized_line_count, 1)

    def test_state_cycler_repeats_sequence_for_long_runs(self) -> None:
        cycler = measure_runtime.StateCycler(
            ["idle", "running", "waiting"],
            interval=2.0,
        )
        self.assertEqual(cycler.due(1.9), [])
        self.assertEqual(cycler.due(2.0), ["running"])
        self.assertEqual(
            cycler.due(10.0),
            ["waiting", "idle", "running", "waiting"],
        )
        self.assertEqual(cycler.due(12.0), ["idle"])

    def test_display_ready_parser_uses_ids_for_cold_and_deduplicates(self) -> None:
        log = "\n".join(
            [
                "event=display_ready transition_id=2 state=running duration_ms=120.500",
                "event=display_ready transition_id=4 state=review duration_ms=150.000",
                "noise duration_ms=9999",
                "event=display_ready transition_id=3 state=waiting duration_ms=180.250",
                "event=display_ready transition_id=2 state=running duration_ms=999.000",
                "event=display_ready transition_id=5 state=idle duration_ms=110.000",
                "event=display_ready transition_id=6 state=running duration_ms=130.000",
                "event=display_ready transition_id=1 state=idle duration_ms=450.000",
            ]
        )
        collector = measure_runtime._collector_from_text(log)
        events = measure_runtime.parse_display_ready(log)
        self.assertEqual(
            events,
            [
                (2, 120.5),
                (4, 150.0),
                (3, 180.25),
                (5, 110.0),
                (6, 130.0),
                (1, 450.0),
            ],
        )
        self.assertEqual(collector.duplicate_event_count, 1)
        report, passed = measure_runtime.evaluate(
            samples(2.0, 30.0),
            events,
            samples(0.1, 10.0),
            executable_sha256="a" * 64,
            duplicate_display_ready_count=collector.duplicate_event_count,
            aggregator_requested=True,
        )
        self.assertTrue(passed)
        self.assertTrue(report["passed"])
        self.assertEqual(report["measurement"], {"mode": "fixture", "live": False})
        self.assertFalse(report["executable"]["attested"])
        self.assertEqual(report["presentation"]["cold_start_count"], 1)
        self.assertEqual(report["presentation"]["warm_switch_count"], 5)
        self.assertEqual(report["presentation"]["duplicate_transition_count"], 1)
        self.assertEqual(report["presentation"]["warm_switch_p95_ms"], 180.25)
        self.assertNotIn("path", json.dumps(report).lower())

    def test_malformed_display_ready_id_is_rejected(self) -> None:
        with self.assertRaises(measure_runtime.HarnessError):
            measure_runtime.parse_display_ready(
                "event=display_ready state=idle duration_ms=100"
            )
        with self.assertRaises(measure_runtime.HarnessError):
            measure_runtime.parse_display_ready(
                "event=display_ready transition_id=nope duration_ms=100"
            )

    def test_budget_and_hard_failures_are_reported(self) -> None:
        # Samples at 0...60 seconds make the 60-second hard CPU gate measurable.
        player = samples(9.0, 260.0, count=61)
        events = [(index, 350.0) for index in range(2, 7)]
        report, passed = measure_runtime.evaluate(player, events)
        self.assertFalse(passed)
        failed = {item["name"] for item in report["checks"] if item["passed"] is False}
        self.assertIn("player_cpu_average_percent", failed)
        self.assertIn("player_cpu_sustained_hard_seconds", failed)
        self.assertIn("player_rss_hard_mb", failed)
        self.assertIn("warm_switch_p95_ms", failed)

    def test_single_display_ready_fails_closed_without_a_warm_switch(self) -> None:
        report, passed = measure_runtime.evaluate(
            samples(1.0, 20.0),
            [(1, 100.0)],
        )
        self.assertFalse(passed)
        self.assertEqual(report["presentation"]["warm_switch_count"], 0)

    def test_evidence_minimums_require_samples_warm_events_and_span(self) -> None:
        events = [(index, 100.0) for index in range(2, 7)]
        report, passed = measure_runtime.evaluate(
            samples(1.0, 20.0, count=9),
            events,
            requested_duration_seconds=60,
        )
        self.assertFalse(passed)
        failed = {item["name"] for item in report["checks"] if item["passed"] is False}
        self.assertIn("player_sample_count", failed)
        self.assertIn("player_observation_span_seconds", failed)

        report, passed = measure_runtime.evaluate(
            samples(1.0, 20.0),
            events[:4],
            requested_duration_seconds=60,
        )
        self.assertFalse(passed)
        failed = {item["name"] for item in report["checks"] if item["passed"] is False}
        self.assertIn("warm_switch_count", failed)

    def test_final_timestamp_does_not_fabricate_span_after_late_samples(self) -> None:
        self.assertEqual(
            measure_runtime.final_observation_timestamp(100.0, now=160.0),
            60.0,
        )
        late_samples = samples(1.0, 20.0, count=51)
        for sample in late_samples:
            sample["time_seconds"] += 10.0
        # The real final sample is at elapsed 60, not first-success + duration.
        late_samples[-1]["time_seconds"] = 60.0
        events = [(index, 100.0) for index in range(2, 7)]
        report, passed = measure_runtime.evaluate(
            late_samples,
            events,
            requested_duration_seconds=60,
        )
        self.assertFalse(passed)
        self.assertEqual(report["observation"]["player_span_seconds"], 50.0)
        failed = {item["name"] for item in report["checks"] if item["passed"] is False}
        self.assertIn("player_observation_span_seconds", failed)

    def test_fixture_cli_is_path_free_and_does_not_launch_gui(self) -> None:
        fixture = {
            "player_samples": samples(1.5, 25.0),
            "aggregator_samples": samples(0.05, 8.0),
            "log": "\n".join(
                [
                    "event=display_ready transition_id=1 duration_ms=400",
                    "event=display_ready transition_id=2 duration_ms=90",
                    "event=display_ready transition_id=3 duration_ms=140",
                    "event=display_ready transition_id=4 duration_ms=120",
                    "event=display_ready transition_id=5 duration_ms=110",
                    "event=display_ready transition_id=6 duration_ms=100",
                ]
            ),
            "executable_sha256": "b" * 64,
            "requested_duration_seconds": 60,
        }
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "fixture.json"
            path.write_text(json.dumps(fixture), encoding="utf-8")
            completed = subprocess.run(
                [sys.executable, str(SCRIPT), "--fixture", str(path)],
                check=False,
                capture_output=True,
                text=True,
                timeout=10,
            )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        report = json.loads(completed.stdout)
        self.assertTrue(report["passed"])
        self.assertEqual(report["measurement"], {"mode": "fixture", "live": False})
        self.assertFalse(report["executable"]["attested"])
        self.assertTrue(report["aggregator"]["requested"])
        self.assertFalse(report["aggregator"]["identity_validated"])
        self.assertNotIn(str(Path.home()), completed.stdout)

    def test_aggregator_pid_requires_positive_owned_aggregator_process(self) -> None:
        self.assertEqual(measure_runtime.positive_pid("42"), 42)
        with self.assertRaises(argparse.ArgumentTypeError):
            measure_runtime.positive_pid("0")
        with self.assertRaises(measure_runtime.HarnessError):
            measure_runtime.validate_aggregator_process(os.getpid())

    def test_aggregator_pid_accepts_canonical_and_legacy_compatibility_names(self) -> None:
        for name in ("statelet_state_aggregator.py", "codex_pet_state_aggregator.py"):
            completed = subprocess.CompletedProcess(
                args=[],
                returncode=0,
                stdout=f"{os.getuid()} /usr/bin/python3 /private/runtime/{name}\n",
                stderr="",
            )
            with mock.patch.object(measure_runtime.subprocess, "run", return_value=completed):
                measure_runtime.validate_aggregator_process(42)

    def test_fixture_rejects_path_bearing_logs_and_non_monotonic_samples(self) -> None:
        unsafe = {
            "player_samples": samples(1.0, 20.0),
            "log": "event=display_ready duration_ms=100 /Users/private/movie.mov",
        }
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "fixture.json"
            path.write_text(json.dumps(unsafe), encoding="utf-8")
            completed = subprocess.run(
                [sys.executable, str(SCRIPT), "--fixture", str(path)],
                check=False,
                capture_output=True,
                text=True,
                timeout=10,
            )
        self.assertEqual(completed.returncode, 2)
        self.assertEqual(json.loads(completed.stdout)["error"], "unsafe_fixture_log")
        for private_path in (
            "/tmp/private.mov",
            "/var/folders/private.mov",
            "/Library/Application Support/private.mov",
            "~/Movies/private.mov",
            r"C:\Users\private\movie.mov",
        ):
            with self.subTest(private_path=private_path):
                self.assertIsNotNone(measure_runtime.PATH_LIKE.search(private_path))
        with self.assertRaises(measure_runtime.HarnessError):
            measure_runtime.normalize_samples(
                [
                    {"time_seconds": 1, "cpu_percent": 1, "rss_mb": 20},
                    {"time_seconds": 1, "cpu_percent": 1, "rss_mb": 20},
                ],
                "player",
            )

    def test_fixture_and_sample_inputs_are_bounded(self) -> None:
        with self.assertRaisesRegex(
            measure_runtime.HarnessError,
            "player_sample_limit_exceeded",
        ):
            measure_runtime.normalize_samples(
                [
                    {"time_seconds": 0, "cpu_percent": 1, "rss_mb": 20}
                ]
                * (measure_runtime.MAX_PROCESS_SAMPLES + 1),
                "player",
            )

        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "oversized-fixture.json"
            path.write_bytes(b" " * (measure_runtime.MAX_FIXTURE_BYTES + 1))
            completed = subprocess.run(
                [sys.executable, str(SCRIPT), "--fixture", str(path)],
                check=False,
                capture_output=True,
                text=True,
                timeout=10,
            )
        self.assertEqual(completed.returncode, 2)
        self.assertEqual(json.loads(completed.stdout)["error"], "fixture_too_large")

    def test_live_commands_capture_info_while_forcing_visible_measurement(self) -> None:
        command = measure_runtime.build_player_command(
            Path("/tmp/statelet"),
            Path("/tmp/media-map.json"),
            Path("/tmp/current-state.json"),
        )
        self.assertEqual(
            command,
            [
                "/tmp/statelet",
                "--media-map",
                "/tmp/media-map.json",
                "--state",
                "/tmp/current-state.json",
                "--always-on-top",
                "--no-click-through",
            ],
        )
        self.assertNotIn("--no-always-on-top", command)
        self.assertEqual(
            measure_runtime.build_log_command(123),
            [
                "/usr/bin/log",
                "stream",
                "--style",
                "compact",
                "--info",
                "--predicate",
                'processID == 123 AND subsystem == "com.coke1120.Statelet"',
            ],
        )

    def test_live_inputs_reject_symlinks_and_normalize_media_into_isolated_map(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            movie = root / "clip.mov"
            movie.write_bytes(b"local test media")
            link = root / "linked.mov"
            link.symlink_to(movie)
            with self.assertRaises(measure_runtime.HarnessError):
                measure_runtime._local_regular_file(str(link))

            source = root / "media-map.json"
            source.write_text(
                json.dumps(
                    {
                        "version": 1,
                        "states": {
                            "idle": {
                                "mode": "fixed",
                                "fixed_path": "clip.mov",
                                "entries": [{"path": "clip.mov", "loop": True}],
                            }
                        },
                    }
                ),
                encoding="utf-8",
            )
            destination = root / "isolated" / "media-map.json"
            measure_runtime.isolated_media_map(source.resolve(), destination)
            isolated = json.loads(destination.read_text(encoding="utf-8"))
            self.assertEqual(
                isolated["states"]["idle"]["entries"][0]["path"],
                str(movie.resolve()),
            )
            self.assertEqual(destination.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
