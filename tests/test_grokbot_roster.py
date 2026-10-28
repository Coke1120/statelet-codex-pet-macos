#!/usr/bin/env python3
"""Synthetic-fixture tests for the optional Grok Bot roster presence source."""

import base64
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
MAC_DIR = ROOT / "mac"
if str(MAC_DIR) not in sys.path:
    sys.path.insert(0, str(MAC_DIR))

import codex_pet_grokbot as grokbot
import codex_pet_state_aggregator as aggregator


def roster_blob_name(key: str) -> str:
    encoded = base64.b32encode(key.encode("utf-8")).decode("ascii").rstrip("=")
    return encoded.lower() + ".blob"


def write_roster(
    directory: Path,
    rows,
    *,
    schema: int = 4,
    key: str = "synthetic.roster.last-roster",
) -> Path:
    path = directory / roster_blob_name(key)
    path.write_text(
        json.dumps({"schemaVersion": schema, "value": {"rows": rows}}),
        encoding="utf-8",
    )
    return path


def write_status(path: Path, pid: int, *, signed_in: bool = True) -> None:
    path.write_text(
        json.dumps(
            {
                "pid": pid,
                "signedIn": signed_in,
                "appVersion": "0.77.0",
                "startedAtMs": 1_700_000_000_000,
            }
        ),
        encoding="utf-8",
    )


def bot_row(
    bot_id: str = "bot-private-1",
    *,
    awaiting=None,
    last_activity=None,
    local_activity=None,
    hidden: bool = False,
    unread: bool = False,
    unread_count: int = 0,
):
    return {
        "id": bot_id,
        "name": "Private Bot Name",
        "title": "Private Bot Title",
        "description": "Private Bot Description",
        "path": "/private/repository",
        "avatarPhoto": "private-avatar-photo",
        "lastEntry": {
            "kind": "text",
            "text": "private message text",
            "sessionPreview": {
                "kind": "message_text",
                "text": "private preview text",
            },
        },
        "awaitingUserResponse": awaiting,
        "lastActivityAt": last_activity,
        "localActivityAt": local_activity,
        "isHiddenFromSidebar": hidden,
        "hasUnread": unread,
        "unreadCount": unread_count,
    }


class GrokBotRosterReaderTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.persistence = self.root / "sand-client-persistence"
        self.persistence.mkdir()
        self.status = self.root / "desktop-status.json"

    def test_unpadded_lowercase_base32_and_privacy_projection(self):
        write_roster(
            self.persistence,
            [
                bot_row(
                    last_activity=1_700_000_000_000,
                    unread=True,
                    unread_count=3,
                )
            ],
        )

        rows = grokbot.read_roster_rows(self.persistence)

        self.assertEqual(len(rows), 1)
        self.assertEqual(
            set(rows[0]),
            {
                "id_hash",
                "awaiting",
                "hidden",
                "has_unread",
                "unread_count",
                "activity_at",
            },
        )
        self.assertEqual(rows[0]["id_hash"], grokbot.session_identifier("bot-private-1"))
        self.assertEqual(rows[0]["activity_at"], 1_700_000_000.0)
        self.assertTrue(rows[0]["has_unread"])
        self.assertEqual(rows[0]["unread_count"], 3)
        serialized = json.dumps(rows)
        for private in (
            "bot-private-1",
            "Private Bot Name",
            "Private Bot Title",
            "Private Bot Description",
            "/private/repository",
            "private-avatar-photo",
            "private message text",
            "private preview text",
        ):
            self.assertNotIn(private, serialized)

    def test_waiting_is_stable_across_polls_and_keeps_contents_private(self):
        write_roster(
            self.persistence,
            [bot_row(awaiting={"prompt": "private prompt text"})],
        )
        write_status(self.status, os.getpid())
        source = grokbot.GrokBotRosterSource(
            self.persistence,
            self.status,
            poll_interval=1.0,
            process_alive=lambda _pid: True,
        )

        self.assertEqual(source.poll(200.0, 0.0), [("waiting", 200.0)])
        self.assertEqual(source.poll(201.0, 1.0), [("waiting", 200.0)])
        self.assertEqual(source.poll(202.0, 2.0), [("waiting", 200.0)])

    def test_unchanged_roster_is_not_reparsed_on_every_poll(self):
        write_roster(self.persistence, [bot_row(awaiting={})])
        write_status(self.status, os.getpid())
        calls = []
        original = grokbot.read_roster_rows_with_status

        def counting_read(directory):
            calls.append(directory)
            return original(directory)

        with mock.patch.object(
            grokbot,
            "read_roster_rows_with_status",
            side_effect=counting_read,
        ):
            source = grokbot.GrokBotRosterSource(
                self.persistence,
                self.status,
                poll_interval=1.0,
                process_alive=lambda _pid: True,
            )
            self.assertEqual(source.poll(200.0, 0.0), [("waiting", 200.0)])
            self.assertEqual(source.poll(201.0, 2.0), [("waiting", 200.0)])
            self.assertEqual(len(calls), 1)

            write_roster(self.persistence, [bot_row("another", awaiting={})])
            self.assertEqual(source.poll(202.0, 4.0), [("waiting", 202.0)])
            self.assertEqual(len(calls), 2)

    def test_recent_activity_is_running_and_old_activity_is_idle(self):
        now = 1_700_000_100.0
        write_roster(
            self.persistence,
            [
                bot_row(
                    "recent",
                    last_activity=int((now - 30.0) * 1000),
                ),
                bot_row(
                    "old",
                    local_activity=int((now - 300.0) * 1000),
                ),
            ],
        )
        write_status(self.status, os.getpid())
        source = grokbot.GrokBotRosterSource(
            self.persistence,
            self.status,
            active_window=120.0,
            process_alive=lambda _pid: True,
        )

        self.assertEqual(source.poll(now, 0.0), [("running", now - 30.0)])

    def test_hidden_bots_are_ignored(self):
        write_roster(
            self.persistence,
            [bot_row(awaiting={"prompt": "private"}, hidden=True)],
        )
        write_status(self.status, os.getpid())
        source = grokbot.GrokBotRosterSource(
            self.persistence,
            self.status,
            process_alive=lambda _pid: True,
        )

        self.assertEqual(source.poll(200.0, 0.0), [])

    def test_app_liveness_and_signed_out_status_fail_closed(self):
        write_roster(self.persistence, [bot_row(awaiting={})])
        write_status(self.status, 4242)
        source = grokbot.GrokBotRosterSource(
            self.persistence,
            self.status,
            process_alive=lambda _pid: False,
        )
        self.assertEqual(source.poll(200.0, 0.0), [])

        write_status(self.status, 4242, signed_in=False)
        source = grokbot.GrokBotRosterSource(
            self.persistence,
            self.status,
            process_alive=lambda _pid: True,
        )
        self.assertEqual(source.poll(200.0, 0.0), [])

    def test_source_mode_switch_repolls_immediately(self):
        write_roster(self.persistence, [bot_row(awaiting={})])
        write_status(self.status, os.getpid())
        source = grokbot.GrokBotRosterSource(
            self.persistence,
            self.status,
            poll_interval=2.0,
            process_alive=lambda _pid: True,
        )

        self.assertEqual(source.poll(200.0, 0.0, "combined"), [("waiting", 200.0)])
        self.assertEqual(source.poll(201.0, 1.0, "codex"), [])
        self.assertEqual(source.poll(202.0, 2.0, "combined"), [("waiting", 200.0)])

    def test_unsupported_schema_fails_closed_and_recovers(self):
        write_roster(self.persistence, [bot_row(awaiting={})], schema=5)
        write_status(self.status, os.getpid())
        diagnostics = []
        source = grokbot.GrokBotRosterSource(
            self.persistence,
            self.status,
            poll_interval=1.0,
            process_alive=lambda _pid: True,
            diagnostic=diagnostics.append,
        )

        self.assertEqual(source.poll(200.0, 0.0), [])
        self.assertEqual(len(diagnostics), 1)
        self.assertIn("reason=unsupported_schema", diagnostics[0])

        write_roster(self.persistence, [bot_row(awaiting={})])
        self.assertEqual(source.poll(201.0, 1.0), [("waiting", 201.0)])
        self.assertIn("status=recovered", diagnostics[-1])

    def test_schema_change_discards_cached_presence_immediately(self):
        write_roster(self.persistence, [bot_row(awaiting={})])
        write_status(self.status, os.getpid())
        source = grokbot.GrokBotRosterSource(
            self.persistence,
            self.status,
            poll_interval=1.0,
            process_alive=lambda _pid: True,
        )
        self.assertEqual(source.poll(200.0, 0.0), [("waiting", 200.0)])

        write_roster(self.persistence, [bot_row(awaiting={})], schema=5)
        self.assertEqual(source.poll(201.0, 2.0), [])

        write_roster(self.persistence, [bot_row(awaiting={})])
        self.assertEqual(source.poll(202.0, 4.0), [("waiting", 202.0)])

    def test_failing_diagnostic_callback_never_breaks_presence(self):
        def failing_diagnostic(_message):
            raise RuntimeError("diagnostic sink failed")

        write_roster(self.persistence, [bot_row(awaiting={})], schema=5)
        write_status(self.status, os.getpid())
        source = grokbot.GrokBotRosterSource(
            self.persistence,
            self.status,
            poll_interval=1.0,
            process_alive=lambda _pid: True,
            diagnostic=failing_diagnostic,
        )
        self.assertEqual(source.poll(200.0, 0.0), [])

        write_roster(self.persistence, [bot_row(awaiting={})])
        self.assertEqual(source.poll(201.0, 1.0), [("waiting", 201.0)])

    def test_malformed_newest_blob_falls_back_to_older_valid_blob(self):
        old = write_roster(
            self.persistence,
            [bot_row("old", awaiting={})],
            key="old.roster.last-roster",
        )
        new = write_roster(
            self.persistence,
            [bot_row("new", awaiting={})],
            key="new.roster.last-roster",
        )
        os.utime(old, (100, 100))
        os.utime(new, (200, 200))
        new.write_text("{not-json", encoding="utf-8")

        rows, fallback_reason = grokbot.read_roster_rows_with_status(
            self.persistence
        )
        self.assertEqual(fallback_reason, "invalid_json")
        self.assertEqual(rows[0]["id_hash"], grokbot.session_identifier("old"))

    def test_older_roster_fallback_is_bounded_and_recovers(self):
        old = write_roster(
            self.persistence,
            [bot_row("old", awaiting={})],
            key="old.roster.last-roster",
        )
        new = write_roster(
            self.persistence,
            [bot_row("new", awaiting={})],
            key="new.roster.last-roster",
        )
        os.utime(old, (100, 100))
        os.utime(new, (200, 200))
        new.write_text("{not-json", encoding="utf-8")
        write_status(self.status, os.getpid())
        diagnostics = []
        source = grokbot.GrokBotRosterSource(
            self.persistence,
            self.status,
            poll_interval=1.0,
            process_alive=lambda _pid: True,
            diagnostic=diagnostics.append,
        )

        self.assertEqual(source.poll(200.0, 0.0), [("waiting", 200.0)])
        self.assertEqual(source.poll(210.0, 10.0), [("waiting", 200.0)])
        self.assertEqual(source.poll(240.0, 40.0), [])
        self.assertEqual(source.poll(242.0, 42.0), [])
        self.assertTrue(any("reason=invalid_json" in item for item in diagnostics))

        write_roster(
            self.persistence,
            [bot_row("new", awaiting={})],
            key="new.roster.last-roster",
        )
        self.assertEqual(source.poll(244.0, 44.0), [("waiting", 244.0)])

    def test_stale_cache_is_bounded_after_roster_becomes_unreadable(self):
        path = write_roster(self.persistence, [bot_row(awaiting={})])
        write_status(self.status, os.getpid())
        diagnostics = []
        source = grokbot.GrokBotRosterSource(
            self.persistence,
            self.status,
            poll_interval=1.0,
            process_alive=lambda _pid: True,
            diagnostic=diagnostics.append,
        )

        self.assertEqual(source.poll(100.0, 0.0), [("waiting", 100.0)])
        path.write_text("{not-json", encoding="utf-8")
        self.assertEqual(source.poll(110.0, 10.0), [("waiting", 100.0)])
        self.assertEqual(source.poll(140.0, 40.0), [])
        self.assertTrue(any("reason=invalid_json" in item for item in diagnostics))

    def test_seconds_and_milliseconds_are_normalized(self):
        write_roster(
            self.persistence,
            [
                bot_row("milliseconds", last_activity=1_700_000_000_000),
                bot_row("seconds", last_activity=1_700_000_000),
            ],
        )

        rows = grokbot.read_roster_rows(self.persistence)
        self.assertEqual([row["activity_at"] for row in rows], [1_700_000_000.0] * 2)

    def test_oversized_roster_is_rejected_before_parsing(self):
        path = write_roster(self.persistence, [])
        path.write_bytes(b"x" * 128)
        with mock.patch.object(grokbot, "MAX_ROSTER_BYTES", 64):
            with self.assertRaises(grokbot.RosterReadError) as context:
                grokbot.read_roster_rows(self.persistence)
        self.assertEqual(context.exception.reason, "too_large")

    def test_rows_without_usable_identity_are_rejected(self):
        write_roster(self.persistence, [{"name": "private but unusable"}])
        with self.assertRaises(grokbot.RosterReadError) as context:
            grokbot.read_roster_rows(self.persistence)
        self.assertEqual(context.exception.reason, "invalid_rows")

    def test_missing_roster_is_silent(self):
        write_status(self.status, os.getpid())
        diagnostics = []
        source = grokbot.GrokBotRosterSource(
            self.persistence,
            self.status,
            process_alive=lambda _pid: True,
            diagnostic=diagnostics.append,
        )
        self.assertEqual(source.poll(200.0, 0.0), [])
        self.assertEqual(diagnostics, [])


class GrokBotAggregatorIntegrationTests(unittest.TestCase):
    def test_grokbot_diagnostic_printer_is_path_free_and_allowlisted(self):
        stderr = io.StringIO()
        with mock.patch.object(sys, "stderr", stderr):
            aggregator.print_grokbot_diagnostic(
                "Statelet Grok Bot roster status=degraded reason=invalid_json"
            )
            aggregator.print_grokbot_diagnostic(
                "Statelet Grok Bot roster status=recovered"
            )
        self.assertEqual(
            stderr.getvalue().splitlines(),
            [
                "Statelet Grok Bot roster status=degraded reason=invalid_json",
                "Statelet Grok Bot roster status=recovered",
            ],
        )
        with self.assertRaises(ValueError):
            aggregator.print_grokbot_diagnostic(
                "Statelet Grok Bot roster status=degraded reason=/private/path"
            )
        with self.assertRaises(ValueError):
            aggregator.print_grokbot_diagnostic("Private Bot Name")

    def test_extra_active_merges_with_hook_sessions(self):
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary).resolve() / "sessions"
            state_dir.mkdir()
            record = state_dir / (("a" * 24) + ".json")
            record.write_text(
                json.dumps(
                    {
                        "version": 1,
                        "state": "running",
                        "event": "UserPromptSubmit",
                        "updated_at": 99.0,
                    }
                ),
                encoding="utf-8",
            )

            (
                lifecycle,
                source_updated_at,
                active_sessions,
                _expiry,
                _latest_event,
                _latest_event_at,
                _diagnostics,
            ) = aggregator.resolve_diagnostic_snapshot(
                state_dir,
                900.0,
                100.0,
                extra_active=[("waiting", 100.0)],
            )

        self.assertEqual(lifecycle, "waiting")
        self.assertEqual(source_updated_at, 100.0)
        self.assertEqual(active_sessions, 2)

    def test_invalid_extra_active_entries_are_ignored(self):
        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary).resolve() / "sessions"
            state_dir.mkdir()
            record = state_dir / (("a" * 24) + ".json")
            record.write_text(
                json.dumps(
                    {
                        "version": 1,
                        "state": "running",
                        "event": "UserPromptSubmit",
                        "updated_at": 99.0,
                    }
                ),
                encoding="utf-8",
            )
            lifecycle, _source, active_sessions, *_rest = (
                aggregator.resolve_diagnostic_snapshot(
                    state_dir,
                    900.0,
                    100.0,
                    extra_active=[
                        ("bogus", 100.0),
                        ("waiting", float("nan")),
                        ("waiting", "not-a-number"),
                    ],
                )
            )
        self.assertEqual(lifecycle, "running")
        self.assertEqual(active_sessions, 1)

    def test_roster_deadline_is_included_in_wake_timeout(self):
        publisher = mock.Mock()
        publisher.next_heartbeat_at = 160.0
        self.assertEqual(
            aggregator.next_wake_timeout(
                publisher,
                wall_time=100.0,
                monotonic_time=100.0,
                force_deadline=None,
                source_expiry_at=None,
                grokbot_deadline=102.0,
            ),
            2.0,
        )

    def test_run_publishes_roster_state_without_activity_sidecar_entry(self):
        class FakeSource:
            def __init__(self):
                self.calls = []

            def poll(self, now, monotonic_now, source_mode):
                self.calls.append((now, monotonic_now, source_mode))
                return [("waiting", 99.0)]

            def next_deadline(self, monotonic_now):
                return monotonic_now + 2.0

        with tempfile.TemporaryDirectory() as temporary:
            state_dir = Path(temporary).resolve() / "sessions"
            state_dir.mkdir()
            output = Path(temporary).resolve() / "runtime" / "current_state.json"
            source = FakeSource()
            result = aggregator.run(
                state_dir,
                output,
                poll=0.25,
                heartbeat=60.0,
                active_ttl=900.0,
                once=True,
                print_state=False,
                forced_state=None,
                force_seconds=30.0,
                should_stop=lambda: False,
                wall_clock=lambda: 100.0,
                monotonic_clock=lambda: 50.0,
                activity_diagnostic=lambda _message: None,
                grokbot_source=source,
            )
            lifecycle = json.loads(output.read_text(encoding="utf-8"))
            activity = json.loads(
                (state_dir / "activity-v1.json").read_text(encoding="utf-8")
            )

        self.assertEqual(result, 0)
        self.assertEqual(lifecycle["state"], "waiting")
        self.assertEqual(lifecycle["active_sessions"], 1)
        self.assertEqual(lifecycle["source_updated_at"], 99.0)
        self.assertEqual(activity["active"], [])
        self.assertEqual(source.calls, [(100.0, 50.0, "combined")])


if __name__ == "__main__":
    unittest.main()
