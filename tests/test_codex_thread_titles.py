#!/usr/bin/env python3
"""Tests for the privacy-bounded Codex App Server title resolver."""

from __future__ import annotations

import json
import os
import signal
import sys
import tempfile
import time
import unittest
from pathlib import Path
from typing import Optional
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "mac"))

from codex_thread_titles import (  # noqa: E402
    MAX_THREAD_TITLE_BYTES,
    MAX_THREAD_TITLE_SCALARS,
    CodexThreadTitleResolver,
)


FAKE_SERVER = r'''#!/usr/bin/env python3
import json, os, sys, time

mode = os.environ.get("STATELET_FAKE_MODE", "ok")
log_path = os.environ.get("STATELET_FAKE_LOG")
count_path = os.environ.get("STATELET_FAKE_COUNT")
pid_path = os.environ.get("STATELET_FAKE_PID")

if count_path:
    with open(count_path, "a", encoding="utf-8") as handle:
        handle.write("launch\n")
if pid_path:
    with open(pid_path, "w", encoding="utf-8") as handle:
        handle.write(str(os.getpid()))
if mode == "nonzero":
    raise SystemExit(7)
if mode == "timeout":
    time.sleep(10)
    raise SystemExit(0)
if mode == "oversized_output":
    sys.stdout.write("x" * (1024 * 1024 + 1))
    sys.stdout.flush()
    time.sleep(10)
    raise SystemExit(0)
if mode == "malformed":
    sys.stdout.write("not-json\n")
    sys.stdout.flush()
    raise SystemExit(0)

def read_message():
    line = sys.stdin.readline()
    if not line:
        raise SystemExit(4)
    if log_path:
        with open(log_path, "a", encoding="utf-8") as handle:
            handle.write(line)
    return json.loads(line)

initialize = read_message()
if mode == "init_error":
    print(json.dumps({"id": initialize["id"], "error": {"message": "private sentinel"}}), flush=True)
    raise SystemExit(0)
print(json.dumps({"id": initialize["id"], "result": {"serverInfo": {"name": "fake"}}}), flush=True)
initialized = read_message()

expected = int(os.environ.get("STATELET_FAKE_EXPECTED", "1"))
names = json.loads(os.environ.get("STATELET_FAKE_NAMES", "{}"))
if mode == "backpressure":
    notification = json.dumps({"method": "private/event", "params": {"padding": "x" * 4096}}) + "\n"
    while True:
        sys.stdout.write(notification)
        sys.stdout.flush()

for _ in range(expected):
    request = read_message()
    thread_id = request["params"]["threadId"]
    if mode == "request_error":
        print(json.dumps({"id": request["id"], "error": {"message": "private sentinel"}}), flush=True)
        continue
    response_id = "different-private-id" if mode == "mismatch" else thread_id
    thread = {
        "id": response_id,
        "name": names.get(thread_id),
        "preview": "PRIVATE_PREVIEW_SENTINEL",
        "turns": [{"items": ["PRIVATE_CONVERSATION_SENTINEL"]}],
        "cwd": "/PRIVATE/PATH/SENTINEL",
    }
    print(json.dumps({"id": request["id"], "result": {"thread": thread}}), flush=True)
'''


class CodexThreadTitleResolverTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.executable = self.base / "codex"
        self.executable.write_text(
            FAKE_SERVER.replace("#!/usr/bin/env python3", "#!{}".format(sys.executable), 1),
            encoding="utf-8",
        )
        self.executable.chmod(0o755)
        self.log = self.base / "wire.jsonl"
        self.count = self.base / "launches.txt"
        self.environment = {
            "STATELET_FAKE_MODE": "ok",
            "STATELET_FAKE_LOG": str(self.log),
            "STATELET_FAKE_COUNT": str(self.count),
            "STATELET_FAKE_EXPECTED": "1",
            "STATELET_FAKE_NAMES": "{}",
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def resolve(
        self,
        thread_ids: list[str],
        *,
        resolver: Optional[CodexThreadTitleResolver] = None,
        now: Optional[float] = None,
        **environment: str,
    ) -> tuple[dict[str, str], Optional[str]]:
        values = dict(self.environment)
        values.update(environment)
        instance = resolver or CodexThreadTitleResolver(self.executable, timeout=5.0)
        with mock.patch.dict(os.environ, values):
            return instance.resolve(thread_ids, monotonic_time=now)

    def wire_messages(self) -> list[dict[str, object]]:
        return [json.loads(line) for line in self.log.read_text(encoding="utf-8").splitlines()]

    def launches(self) -> int:
        if not self.count.exists():
            return 0
        return len(self.count.read_text(encoding="utf-8").splitlines())

    def test_batches_exact_metadata_only_wire_requests_and_discards_private_fields(self) -> None:
        first = "thread-one"
        second = "thread-two"
        titles, failure = self.resolve(
            [first, second],
            STATELET_FAKE_EXPECTED="2",
            STATELET_FAKE_NAMES=json.dumps({first: "First title", second: "Second title"}),
        )

        self.assertEqual(titles, {first: "First title", second: "Second title"})
        self.assertIsNone(failure)
        messages = self.wire_messages()
        self.assertEqual(
            messages[0],
            {
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientInfo": {"name": "statelet", "title": "Statelet", "version": "1"}
                },
            },
        )
        self.assertEqual(messages[1], {"method": "initialized", "params": {}})
        self.assertEqual(
            messages[2:],
            [
                {
                    "id": 2,
                    "method": "thread/read",
                    "params": {"threadId": first, "includeTurns": False},
                },
                {
                    "id": 3,
                    "method": "thread/read",
                    "params": {"threadId": second, "includeTurns": False},
                },
            ],
        )
        combined = json.dumps(titles)
        self.assertNotIn("PRIVATE_PREVIEW_SENTINEL", combined)
        self.assertNotIn("PRIVATE_CONVERSATION_SENTINEL", combined)
        self.assertNotIn("PRIVATE/PATH", combined)

    def test_sanitizes_nfc_whitespace_and_control_or_format_characters(self) -> None:
        raw = "  Cafe\u0301\ntask\u200b\x00  "
        titles, failure = self.resolve(
            ["one"], STATELET_FAKE_NAMES=json.dumps({"one": raw})
        )
        self.assertEqual(titles, {"one": "Café task"})
        self.assertIsNone(failure)

    def test_title_scalar_and_byte_limits_are_rejected_without_truncation(self) -> None:
        self.assertEqual(MAX_THREAD_TITLE_SCALARS, 120)
        self.assertEqual(MAX_THREAD_TITLE_BYTES, 256)
        for index, title in enumerate(("x" * 121, "界" * 86), start=1):
            with self.subTest(title=index):
                resolver = CodexThreadTitleResolver(self.executable, timeout=5.0, cache_ttl=0)
                titles, failure = self.resolve(
                    [f"thread-{index}"],
                    resolver=resolver,
                    now=float(index),
                    STATELET_FAKE_NAMES=json.dumps({f"thread-{index}": title}),
                )
                self.assertEqual(titles, {})
                self.assertIsNone(failure)

    def test_missing_null_and_empty_names_are_successful_no_title_results(self) -> None:
        for name in (None, "", "\n\t"):
            with self.subTest(name=name):
                titles, failure = self.resolve(
                    ["one"], STATELET_FAKE_NAMES=json.dumps({"one": name})
                )
                self.assertEqual(titles, {})
                self.assertIsNone(failure)

    def test_mismatch_error_and_malformed_or_oversized_output_fail_closed(self) -> None:
        expected = {
            "mismatch": "protocol_error",
            "request_error": "protocol_error",
            "init_error": "protocol_error",
            "malformed": "protocol_error",
            "oversized_output": "protocol_error",
        }
        for mode, kind in expected.items():
            with self.subTest(mode=mode):
                titles, failure = self.resolve(["private-thread-id"], STATELET_FAKE_MODE=mode)
                self.assertEqual(titles, {})
                self.assertEqual(failure, kind)

    def test_timeout_nonzero_and_unavailable_have_bounded_failures(self) -> None:
        resolver = CodexThreadTitleResolver(self.executable, timeout=0.1)
        titles, failure = self.resolve(
            ["one"], resolver=resolver, STATELET_FAKE_MODE="timeout"
        )
        self.assertEqual((titles, failure), ({}, "timeout"))

        titles, failure = self.resolve(["one"], STATELET_FAKE_MODE="nonzero")
        self.assertEqual((titles, failure), ({}, "unavailable"))

        resolver = CodexThreadTitleResolver(self.base / "missing", timeout=0.1)
        self.assertEqual(resolver.resolve(["one"]), ({}, "unavailable"))

    def test_server_stdout_backpressure_cannot_block_request_writes(self) -> None:
        identifiers = [f"thread-{index}-" + "x" * 500 for index in range(64)]
        started = time.monotonic()
        titles, failure = self.resolve(
            identifiers,
            resolver=CodexThreadTitleResolver(self.executable, timeout=0.3),
            STATELET_FAKE_MODE="backpressure",
            STATELET_FAKE_EXPECTED="64",
        )

        self.assertEqual(titles, {})
        self.assertIn(failure, {"timeout", "protocol_error"})
        self.assertLess(time.monotonic() - started, 2.0)

    def test_discovers_a_trusted_standard_user_executable(self) -> None:
        standard = self.base / "standard-home" / ".local" / "bin" / "codex"
        standard.parent.mkdir(parents=True)
        standard.write_text(FAKE_SERVER, encoding="utf-8")
        standard.chmod(0o755)
        resolver = CodexThreadTitleResolver(timeout=5.0)
        titles, failure = self.resolve(
            ["one"],
            resolver=resolver,
            HOME=str(self.base / "standard-home"),
            STATELET_FAKE_NAMES=json.dumps({"one": "Standard path"}),
        )
        self.assertEqual((titles, failure), ({"one": "Standard path"}, None))

        standard.chmod(0o777)
        uncached = CodexThreadTitleResolver(standard, timeout=0.1)
        titles, failure = self.resolve(
            ["two"], resolver=uncached, HOME=str(self.base / "standard-home")
        )
        self.assertEqual((titles, failure), ({}, "unavailable"))

    def test_timeout_reaps_the_child_process(self) -> None:
        pid_path = self.base / "pid"
        titles, failure = self.resolve(
            ["one"],
            resolver=CodexThreadTitleResolver(self.executable, timeout=5.0),
            STATELET_FAKE_MODE="timeout",
            STATELET_FAKE_PID=str(pid_path),
        )
        self.assertEqual((titles, failure), ({}, "timeout"))
        pid = int(pid_path.read_text(encoding="utf-8"))
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_success_and_null_results_are_cached_then_refreshed_after_ttl(self) -> None:
        resolver = CodexThreadTitleResolver(
            self.executable, timeout=5.0, cache_ttl=60, failure_backoff=0.25
        )
        first = self.resolve(
            ["named", "null"],
            resolver=resolver,
            now=10,
            STATELET_FAKE_EXPECTED="2",
            STATELET_FAKE_NAMES=json.dumps({"named": "Original", "null": None}),
        )
        cached = self.resolve(
            ["named", "null"],
            resolver=resolver,
            now=69,
            STATELET_FAKE_EXPECTED="2",
            STATELET_FAKE_NAMES=json.dumps({"named": "Changed", "null": "Now named"}),
        )
        refreshed = self.resolve(
            ["named", "null"],
            resolver=resolver,
            now=70,
            STATELET_FAKE_EXPECTED="2",
            STATELET_FAKE_NAMES=json.dumps({"named": "Changed", "null": "Now named"}),
        )
        self.assertEqual(first, ({"named": "Original"}, None))
        self.assertEqual(cached, ({"named": "Original"}, None))
        self.assertEqual(refreshed, ({"named": "Changed", "null": "Now named"}, None))
        self.assertEqual(self.launches(), 2)

    def test_failure_backoff_prevents_immediate_respawn(self) -> None:
        resolver = CodexThreadTitleResolver(
            self.executable, timeout=5.0, cache_ttl=60, failure_backoff=0.25
        )
        first = self.resolve(
            ["one"], resolver=resolver, now=5, STATELET_FAKE_MODE="nonzero"
        )
        second = self.resolve(
            ["one"], resolver=resolver, now=5.1, STATELET_FAKE_MODE="ok"
        )
        third = self.resolve(
            ["one"],
            resolver=resolver,
            now=5.25,
            STATELET_FAKE_NAMES=json.dumps({"one": "Recovered"}),
        )
        self.assertEqual(first, ({}, "unavailable"))
        self.assertEqual(second, ({}, "unavailable"))
        self.assertEqual(third, ({"one": "Recovered"}, None))
        self.assertEqual(self.launches(), 2)

    def test_invalid_thread_ids_fail_before_launch(self) -> None:
        resolver = CodexThreadTitleResolver(self.executable)
        for values in ([""], ["line\nbreak"], ["x" * 513], list(map(str, range(65)))):
            with self.subTest(count=len(values)):
                self.assertEqual(resolver.resolve(values), ({}, "protocol_error"))
        self.assertEqual(self.launches(), 0)


if __name__ == "__main__":
    unittest.main()
