#!/usr/bin/env python3
"""Read Grok Bot's local roster as a coarse, privacy-safe presence source.

Grok Bot is a cloud-agent desktop client.  It does not expose the hook contract
used by Codex and Grok Build, but it does maintain a local roster of its bots and
their high-level activity.  This module projects only the small, text-free
subset needed for Statelet's existing lifecycle states:

    awaitingUserResponse != null/false  -> waiting
    recent lastActivityAt/localActivityAt -> running
    otherwise                             -> no contribution

The same projected presence can be surfaced as generic activity-rail rows.  The
rail receives only the opaque bot hash, the coarse state, and the stable start /
latest-activity timestamps.  It never receives a bot name, title, preview, or
raw identifier.

Bot names, titles, descriptions, message previews, avatars, repository paths,
and raw bot identifiers never cross this parser boundary.  The source is
read-only, local-only, and best-effort: an error must never prevent the
aggregator from publishing hook-based state, and a sustained error removes this
source's contribution after a bounded grace period.
"""

import base64
import hashlib
import json
import math
import os
import stat
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple


DEFAULT_POLL_INTERVAL = 2.0
DEFAULT_ACTIVE_WINDOW = 120.0
DISABLED_RECHECK_INTERVAL = 30.0
NOT_RUNNING_RECHECK_INTERVAL = 5.0
DIAGNOSTIC_INTERVAL = 60.0
STALE_GRACE_SECONDS = 30.0

RosterSignature = Tuple[Tuple[str, int, int, int, int, int], ...]

MAX_ROSTER_BYTES = 8 * 1024 * 1024
MAX_STATUS_BYTES = 4 * 1024
MAX_ROWS = 1024
MAX_ID_LENGTH = 256
MAX_BLOB_NAME_LENGTH = 512
MAX_SCANNED_ENTRIES = 4096
MAX_CANDIDATES = 4
UNREAD_COUNT_LIMIT = 1_000_000
MILLISECONDS_THRESHOLD = 10_000_000_000.0

ROSTER_SUFFIX = ".roster.last-roster"
SUPPORTED_SCHEMA_VERSION = 4

VALID_DIAGNOSTIC_REASONS = frozenset(
    (
        "no_roster",
        "unreadable",
        "invalid_json",
        "unsupported_schema",
        "invalid_rows",
        "too_large",
        "changing",
        "internal_error",
    )
)


class RosterReadError(Exception):
    """A bounded, path-free reason why the roster could not be projected."""

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


def default_grokbot_persistence_dir() -> Path:
    return (
        Path.home()
        / "Library"
        / "Application Support"
        / "Grok Bot"
        / "sand-client-persistence"
    )


def default_grokbot_status_path() -> Path:
    return (
        Path.home()
        / "Library"
        / "Application Support"
        / "Grok Bot"
        / "desktop-status.json"
    )


def decode_roster_blob_name(stem: str) -> Optional[str]:
    """Decode an unpadded, lowercase base32 persistence filename."""
    if not stem or len(stem) > MAX_BLOB_NAME_LENGTH:
        return None
    padded = stem.upper()
    padding = (-len(padded)) % 8
    if padding:
        padded += "=" * padding
    try:
        raw = base64.b32decode(padded, casefold=True)
    except (TypeError, ValueError):
        return None
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return None


def session_identifier(bot_id: str) -> str:
    """Return the opaque 24-hex identity used for this bot."""
    return hashlib.sha256(("grokbot:" + bot_id).encode("utf-8")).hexdigest()[:24]


def _finite_timestamp(value: object) -> Optional[float]:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        parsed = float(value)
    except (TypeError, ValueError, OverflowError):
        return None
    if not math.isfinite(parsed) or parsed <= 0:
        return None
    # Grok Bot currently writes epoch milliseconds; accept seconds as well so
    # a future format change does not silently produce absurd freshness ages.
    if parsed > MILLISECONDS_THRESHOLD:
        parsed /= 1000.0
    return parsed if math.isfinite(parsed) and parsed > 0 else None


def _identity(status: os.stat_result) -> Tuple[int, int, int, int, int]:
    return (
        status.st_dev,
        status.st_ino,
        status.st_size,
        status.st_mtime_ns,
        status.st_ctime_ns,
    )


def _read_bounded(descriptor: int, size: int) -> bytes:
    chunks = []
    remaining = size
    while remaining > 0:
        chunk = os.read(descriptor, min(65_536, remaining))
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def _project_document(document: object) -> List[Dict[str, object]]:
    if not isinstance(document, dict):
        raise RosterReadError("invalid_rows")
    version = document.get("schemaVersion")
    if (
        isinstance(version, bool)
        or not isinstance(version, int)
        or version != SUPPORTED_SCHEMA_VERSION
    ):
        raise RosterReadError("unsupported_schema")
    value = document.get("value")
    if not isinstance(value, dict) or not isinstance(value.get("rows"), list):
        raise RosterReadError("invalid_rows")
    raw_rows = value["rows"]
    projected: List[Dict[str, object]] = []
    seen = set()
    for raw in raw_rows[:MAX_ROWS]:
        if not isinstance(raw, dict):
            continue
        bot_id = raw.get("id")
        if (
            not isinstance(bot_id, str)
            or not bot_id
            or len(bot_id) > MAX_ID_LENGTH
            or bot_id in seen
        ):
            continue
        seen.add(bot_id)
        awaiting_value = raw.get("awaitingUserResponse")
        awaiting = awaiting_value is not None and awaiting_value is not False
        hidden = raw.get("isHiddenFromSidebar") is True
        has_unread = raw.get("hasUnread") is True
        raw_unread_count = raw.get("unreadCount")
        if (
            isinstance(raw_unread_count, bool)
            or not isinstance(raw_unread_count, int)
            or raw_unread_count < 0
        ):
            unread_count = 0
        else:
            unread_count = min(raw_unread_count, UNREAD_COUNT_LIMIT)
        timestamps = [
            timestamp
            for timestamp in (
                _finite_timestamp(raw.get("lastActivityAt")),
                _finite_timestamp(raw.get("localActivityAt")),
            )
            if timestamp is not None
        ]
        projected.append(
            {
                "id_hash": session_identifier(bot_id),
                "awaiting": awaiting,
                "hidden": hidden,
                "has_unread": has_unread,
                "unread_count": unread_count,
                "activity_at": max(timestamps) if timestamps else None,
            }
        )
    if raw_rows and not projected:
        raise RosterReadError("invalid_rows")
    return projected


def _read_roster_blob(path: Path) -> List[Dict[str, object]]:
    descriptor: Optional[int] = None
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
        )
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.getuid()
            or before.st_size <= 0
        ):
            raise RosterReadError("unreadable")
        if before.st_size > MAX_ROSTER_BYTES:
            raise RosterReadError("too_large")
        identity = _identity(before)
        raw = _read_bounded(descriptor, before.st_size)
        after = os.fstat(descriptor)
        if _identity(after) != identity or len(raw) != before.st_size:
            raise RosterReadError("changing")
    except RosterReadError:
        raise
    except OSError:
        raise RosterReadError("unreadable")
    finally:
        if descriptor is not None:
            os.close(descriptor)
    try:
        document = json.loads(raw.decode("utf-8"))
    except (UnicodeError, ValueError, RecursionError):
        raise RosterReadError("invalid_json")
    return _project_document(document)


def _candidate_roster_paths(persistence_dir: Path) -> List[Path]:
    candidates: List[Tuple[int, Path]] = []
    try:
        with os.scandir(persistence_dir) as entries:
            for index, entry in enumerate(entries):
                if index >= MAX_SCANNED_ENTRIES:
                    break
                name = entry.name
                if (
                    not name.endswith(".blob")
                    or len(name) > MAX_BLOB_NAME_LENGTH
                ):
                    continue
                key = decode_roster_blob_name(name[:-5])
                if key is None or not key.endswith(ROSTER_SUFFIX):
                    continue
                try:
                    if not entry.is_file(follow_symlinks=False):
                        continue
                    status = entry.stat(follow_symlinks=False)
                except OSError:
                    continue
                if status.st_uid != os.getuid() or not stat.S_ISREG(status.st_mode):
                    continue
                candidates.append((status.st_mtime_ns, persistence_dir / name))
    except OSError:
        raise RosterReadError("unreadable")
    candidates.sort(key=lambda item: item[0], reverse=True)
    if not candidates:
        raise RosterReadError("no_roster")
    return [path for _modified, path in candidates[:MAX_CANDIDATES]]


def _candidate_roster_signature(persistence_dir: Path) -> RosterSignature:
    """Return stable file metadata for the candidate roster blobs.

    The signature lets the source skip reparsing an unchanged roster on every
    two-second poll.  It is intentionally metadata-only; reading the content
    still goes through the owner, regular-file, size, and identity checks in
    ``_read_roster_blob``.
    """
    signature = []
    for path in _candidate_roster_paths(persistence_dir):
        try:
            status = os.stat(path, follow_symlinks=False)
        except OSError:
            raise RosterReadError("unreadable")
        signature.append(
            (
                path.name,
                status.st_dev,
                status.st_ino,
                status.st_size,
                status.st_mtime_ns,
                status.st_ctime_ns,
            )
        )
    return tuple(signature)


def read_roster_rows_with_status(
    persistence_dir: Path,
) -> Tuple[List[Dict[str, object]], Optional[str]]:
    """Return projected rows plus the newest-candidate error reason, if any.

    A non-None reason means the newest candidate failed and an older valid
    candidate was used.  Callers that present presence to the user must bound
    how long this fallback may last; the reader itself is stateless.
    """
    candidates = _candidate_roster_paths(persistence_dir)
    first_error: Optional[RosterReadError] = None
    for path in candidates:
        try:
            rows = _read_roster_blob(path)
        except RosterReadError as error:
            if first_error is None:
                first_error = error
            if error.reason == "unsupported_schema":
                raise
            continue
        return rows, (first_error.reason if first_error is not None else None)
    raise first_error or RosterReadError("no_roster")


def read_roster_rows(persistence_dir: Path) -> List[Dict[str, object]]:
    """Return the newest valid roster's privacy-projected rows.

    The newest unsupported schema fails closed immediately.  A malformed newer
    blob may fall back to a small number of older candidates, which covers an
    in-progress replacement without trusting arbitrary stale data.
    """
    rows, _fallback_reason = read_roster_rows_with_status(persistence_dir)
    return rows


def _read_status_pid(path: Path) -> Optional[int]:
    descriptor: Optional[int] = None
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
        )
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.getuid()
            or before.st_size <= 0
            or before.st_size > MAX_STATUS_BYTES
        ):
            return None
        identity = _identity(before)
        raw = _read_bounded(descriptor, before.st_size)
        after = os.fstat(descriptor)
        if _identity(after) != identity or len(raw) != before.st_size:
            return None
    except OSError:
        return None
    finally:
        if descriptor is not None:
            os.close(descriptor)
    try:
        document = json.loads(raw.decode("utf-8"))
    except (UnicodeError, ValueError, RecursionError):
        return None
    if not isinstance(document, dict):
        return None
    pid = document.get("pid")
    if (
        isinstance(pid, bool)
        or not isinstance(pid, int)
        or pid <= 0
        or pid > (2**31 - 1)
    ):
        return None
    if document.get("signedIn") is False:
        return None
    return pid


def _process_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # The status file belongs to this user's Grok Bot.  A PID we cannot
        # signal belongs to another user and is not a valid presence source.
        return False
    except OSError:
        return False
    return True


class GrokBotRosterSource:
    """Best-effort presence source for an installed, running Grok Bot."""

    def __init__(
        self,
        persistence_dir: Optional[Path] = None,
        status_path: Optional[Path] = None,
        poll_interval: float = DEFAULT_POLL_INTERVAL,
        active_window: float = DEFAULT_ACTIVE_WINDOW,
        process_alive: Optional[Callable[[int], bool]] = None,
        diagnostic: Optional[Callable[[str], None]] = None,
    ) -> None:
        self.persistence_dir = (
            Path(persistence_dir)
            if persistence_dir is not None
            else default_grokbot_persistence_dir()
        )
        self.status_path = (
            Path(status_path)
            if status_path is not None
            else default_grokbot_status_path()
        )
        try:
            parsed_poll_interval = float(poll_interval)
        except (TypeError, ValueError):
            parsed_poll_interval = DEFAULT_POLL_INTERVAL
        try:
            parsed_active_window = float(active_window)
        except (TypeError, ValueError):
            parsed_active_window = DEFAULT_ACTIVE_WINDOW
        self.poll_interval = (
            parsed_poll_interval
            if math.isfinite(parsed_poll_interval) and parsed_poll_interval > 0
            else DEFAULT_POLL_INTERVAL
        )
        self.active_window = (
            parsed_active_window
            if math.isfinite(parsed_active_window) and parsed_active_window > 0
            else DEFAULT_ACTIVE_WINDOW
        )
        self._process_alive = process_alive or _process_alive
        self._diagnostic = diagnostic or (lambda _message: None)
        self._next_poll_at = 0.0
        self._last_source_mode: Optional[str] = None
        self._last_active: List[Tuple[str, float]] = []
        self._activity_items: List[Dict[str, object]] = []
        self._rows: List[Dict[str, object]] = []
        self._rows_signature: Optional[RosterSignature] = None
        self._rows_loaded_monotonic = 0.0
        self._rows_valid = False
        self._rows_fallback = False
        self._fallback_since: Optional[float] = None
        self._waiting_since: Dict[str, float] = {}
        self._running_since: Dict[str, float] = {}
        self._degraded = False
        self._last_reason: Optional[str] = None
        self._next_diagnostic_at = 0.0

    def poll(
        self,
        now: float,
        monotonic_now: float,
        source_mode: str = "combined",
    ) -> List[Tuple[str, float]]:
        if source_mode != self._last_source_mode:
            self._last_source_mode = source_mode
            self._next_poll_at = 0.0
        if monotonic_now < self._next_poll_at:
            return list(self._last_active)
        self._next_poll_at = monotonic_now + self.poll_interval
        try:
            return self._poll(now, monotonic_now, source_mode)
        except Exception:
            # A presence source must never take down hook aggregation.  Retry
            # after a bounded cooldown rather than reproducing the same failure
            # every 250 ms.
            self._clear_presence()
            self._next_poll_at = monotonic_now + DISABLED_RECHECK_INTERVAL
            self._mark_degraded("internal_error", monotonic_now)
            return []

    def next_deadline(self, monotonic_now: float) -> float:
        return max(monotonic_now, self._next_poll_at)

    def activity_items(self) -> List[Dict[str, object]]:
        """Return the current generic activity-rail rows.

        The rows contain only an opaque 24-hex bot hash, the coarse Waiting or
        Running state, and bounded timestamps.  They intentionally contain no
        bot name, title, preview, repository path, or raw identifier.
        """
        return [dict(item) for item in self._activity_items]

    def _clear_projection(self) -> None:
        self._last_active = []
        self._activity_items = []

    def _clear_presence(self) -> None:
        self._clear_projection()
        self._waiting_since.clear()
        self._running_since.clear()

    def _drop_cached_rows(self) -> None:
        # Keep _fallback_since as an expired marker so a persistent malformed
        # newest blob cannot restart the same fallback window on the next poll.
        self._rows = []
        self._rows_signature = None
        self._rows_valid = False
        self._rows_fallback = False
        self._clear_presence()

    def _poll(
        self,
        now: float,
        monotonic_now: float,
        source_mode: str,
    ) -> List[Tuple[str, float]]:
        if source_mode not in ("combined", "grokbot"):
            # Keep the stable waiting/running start timestamps for an immediate
            # switch back, but remove this source's visible contribution now.
            self._clear_projection()
            self._next_poll_at = monotonic_now + DISABLED_RECHECK_INTERVAL
            return []
        if not self.persistence_dir.is_dir():
            self._clear_presence()
            self._next_poll_at = monotonic_now + DISABLED_RECHECK_INTERVAL
            return []
        pid = _read_status_pid(self.status_path)
        if pid is None or not self._process_alive(pid):
            self._clear_presence()
            self._next_poll_at = monotonic_now + NOT_RUNNING_RECHECK_INTERVAL
            return []
        try:
            signature = _candidate_roster_signature(self.persistence_dir)
        except (OSError, RosterReadError):
            signature = None
        if (
            signature is not None
            and self._rows_valid
            and not self._rows_fallback
            and signature == self._rows_signature
        ):
            rows = self._rows
            self._rows_loaded_monotonic = monotonic_now
            self._mark_recovered()
        else:
            try:
                rows, fallback_reason = read_roster_rows_with_status(
                    self.persistence_dir
                )
            except RosterReadError as error:
                fallback_expired = (
                    self._rows_fallback
                    and self._fallback_since is not None
                    and monotonic_now - self._fallback_since
                    > STALE_GRACE_SECONDS
                )
                if (
                    error.reason != "unsupported_schema"
                    and self._rows_valid
                    and monotonic_now - self._rows_loaded_monotonic
                    <= STALE_GRACE_SECONDS
                    and not fallback_expired
                ):
                    rows = self._rows
                else:
                    self._drop_cached_rows()
                    if error.reason == "unsupported_schema":
                        self._fallback_since = None
                    self._mark_degraded(error.reason, monotonic_now)
                    return []
            else:
                if fallback_reason is not None:
                    if self._fallback_since is None:
                        self._fallback_since = monotonic_now
                    if (
                        monotonic_now - self._fallback_since
                        > STALE_GRACE_SECONDS
                    ):
                        self._drop_cached_rows()
                        self._mark_degraded(fallback_reason, monotonic_now)
                        return []
                    self._rows = rows
                    self._rows_signature = signature
                    self._rows_loaded_monotonic = monotonic_now
                    self._rows_valid = True
                    self._rows_fallback = True
                    self._mark_degraded(fallback_reason, monotonic_now)
                else:
                    self._rows = rows
                    self._rows_signature = signature
                    self._rows_loaded_monotonic = monotonic_now
                    self._rows_valid = True
                    self._rows_fallback = False
                    self._fallback_since = None
                    self._mark_recovered()
        self._last_active = self._derive_presence(rows, now)
        return list(self._last_active)

    def _derive_presence(
        self,
        rows: List[Dict[str, object]],
        now: float,
    ) -> List[Tuple[str, float]]:
        active: List[Tuple[str, float]] = []
        self._activity_items = []
        seen = set()
        running_active = set()
        for row in rows:
            identifier = row.get("id_hash")
            if not isinstance(identifier, str) or identifier in seen:
                continue
            seen.add(identifier)
            if row.get("hidden") is True:
                self._waiting_since.pop(identifier, None)
                self._running_since.pop(identifier, None)
                continue
            if row.get("awaiting") is True:
                self._running_since.pop(identifier, None)
                since = self._waiting_since.get(identifier)
                if since is None:
                    since = now
                    self._waiting_since[identifier] = since
                active.append(("waiting", since))
                self._activity_items.append(
                    {
                        "id": identifier,
                        "state": "waiting",
                        "started_at": since,
                        "event_at": since,
                    }
                )
                continue
            self._waiting_since.pop(identifier, None)
            activity_at = row.get("activity_at")
            if isinstance(activity_at, bool) or not isinstance(
                activity_at, (int, float)
            ):
                self._running_since.pop(identifier, None)
                continue
            timestamp = float(activity_at)
            if not (
                math.isfinite(timestamp)
                and 0 <= now - timestamp <= self.active_window
            ):
                self._running_since.pop(identifier, None)
                continue
            running_since = self._running_since.get(identifier)
            if running_since is None:
                running_since = timestamp
            else:
                # Keep the rail row stable across poll ticks while preserving
                # the activity item contract's started_at <= event_at rule even
                # if the system clock moves backwards.
                running_since = min(running_since, timestamp)
            self._running_since[identifier] = running_since
            running_active.add(identifier)
            active.append(("running", timestamp))
            self._activity_items.append(
                {
                    "id": identifier,
                    "state": "running",
                    "started_at": running_since,
                    "event_at": timestamp,
                }
            )
        if self._waiting_since:
            self._waiting_since = {
                identifier: timestamp
                for identifier, timestamp in self._waiting_since.items()
                if identifier in seen
            }
        if self._running_since:
            self._running_since = {
                identifier: timestamp
                for identifier, timestamp in self._running_since.items()
                if identifier in running_active
            }
        return active

    def _mark_degraded(self, reason: str, monotonic_now: float) -> None:
        if reason not in VALID_DIAGNOSTIC_REASONS:
            reason = "internal_error"
        if reason == "no_roster":
            # A roster is absent during normal startup and between app updates;
            # do not turn that transient state into a log entry.
            return
        self._degraded = True
        if (
            reason == self._last_reason
            and monotonic_now < self._next_diagnostic_at
        ):
            return
        try:
            self._diagnostic(
                "Statelet Grok Bot roster status=degraded reason={}".format(reason)
            )
        except Exception:
            # Diagnostics are best-effort and must never affect presence.
            pass
        self._last_reason = reason
        self._next_diagnostic_at = monotonic_now + DIAGNOSTIC_INTERVAL

    def _mark_recovered(self) -> None:
        if not self._degraded:
            return
        try:
            self._diagnostic("Statelet Grok Bot roster status=recovered")
        except Exception:
            pass
        self._degraded = False
        self._last_reason = None
        self._next_diagnostic_at = 0.0


__all__ = [
    "DEFAULT_ACTIVE_WINDOW",
    "DEFAULT_POLL_INTERVAL",
    "GrokBotRosterSource",
    "RosterReadError",
    "SUPPORTED_SCHEMA_VERSION",
    "VALID_DIAGNOSTIC_REASONS",
    "decode_roster_blob_name",
    "default_grokbot_persistence_dir",
    "default_grokbot_status_path",
    "read_roster_rows",
    "read_roster_rows_with_status",
    "session_identifier",
]
