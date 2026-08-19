#!/usr/bin/env python3
"""Resolve privacy-bounded Codex thread titles through the local App Server."""

from __future__ import annotations

import json
import os
import select
import signal
import stat
import subprocess
import threading
import time
import unicodedata
from pathlib import Path
from typing import Callable, Iterable, Optional, Union


MAX_THREAD_TITLE_SCALARS = 120
MAX_THREAD_TITLE_BYTES = 256

_MAX_THREAD_ID_SCALARS = 512
_MAX_THREAD_IDS_PER_RESOLVE = 64
_MAX_CACHE_ENTRIES = 128
_MAX_STDOUT_BYTES = 1024 * 1024
_READ_CHUNK_BYTES = 16 * 1024


class _ResolutionFailure(Exception):
    def __init__(self, kind: str) -> None:
        super().__init__(kind)
        self.kind = kind


def _sanitize_title(value: object) -> Optional[str]:
    if not isinstance(value, str):
        return None
    normalized = unicodedata.normalize("NFC", value)
    filtered = "".join(
        " "
        if unicodedata.category(character) == "Cc" and character.isspace()
        else ""
        if unicodedata.category(character) in {"Cc", "Cf"}
        else character
        for character in normalized
    )
    title = " ".join(filtered.split())
    if not title:
        return None
    if len(title) > MAX_THREAD_TITLE_SCALARS:
        return None
    if len(title.encode("utf-8")) > MAX_THREAD_TITLE_BYTES:
        return None
    return title


class CodexThreadTitleResolver:
    """Short-lived, fail-closed metadata client for ``codex app-server``."""

    def __init__(
        self,
        executable: Optional[Union[os.PathLike[str], str]] = None,
        *,
        timeout: float = 1.5,
        cache_ttl: float = 60.0,
        failure_backoff: float = 60.0,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._executable_override = Path(executable).expanduser() if executable else None
        self._timeout = max(0.05, float(timeout))
        self._cache_ttl = max(0.0, float(cache_ttl))
        self._failure_backoff = max(0.0, float(failure_backoff))
        self._clock = clock
        self._cache: dict[str, tuple[float, Optional[str]]] = {}
        self._retry_after = 0.0
        self._last_failure: Optional[str] = None
        self._process_lock = threading.Lock()
        self._active_process: Optional[subprocess.Popen[bytes]] = None
        self._closed = False

    def resolve(
        self,
        thread_ids: Iterable[str],
        monotonic_time: Optional[float] = None,
    ) -> tuple[dict[str, str], Optional[str]]:
        now = self._clock() if monotonic_time is None else float(monotonic_time)
        with self._process_lock:
            if self._closed:
                return {}, "unavailable"
        requested = self._validate_thread_ids(thread_ids)
        if requested is None:
            return {}, "protocol_error"
        self._trim_cache(now)

        titles: dict[str, str] = {}
        missing: list[str] = []
        for thread_id in requested:
            cached = self._cache.get(thread_id)
            if cached is not None and cached[0] > now:
                if cached[1] is not None:
                    titles[thread_id] = cached[1]
            else:
                self._cache.pop(thread_id, None)
                missing.append(thread_id)

        if not missing:
            return titles, None
        if now < self._retry_after:
            return titles, self._last_failure or "unavailable"

        executable = self._discover_executable()
        if executable is None:
            self._record_failure(now, "unavailable")
            return titles, "unavailable"

        try:
            resolved = self._resolve_uncached(executable, missing)
        except _ResolutionFailure as failure:
            self._record_failure(now, failure.kind)
            return titles, failure.kind

        expires_at = now + self._cache_ttl
        for thread_id in missing:
            title = resolved.get(thread_id)
            self._cache[thread_id] = (expires_at, title)
            if title is not None:
                titles[thread_id] = title
        self._trim_cache(now)
        self._retry_after = 0.0
        self._last_failure = None
        return titles, None

    def _record_failure(self, now: float, failure: str) -> None:
        self._retry_after = now + self._failure_backoff
        self._last_failure = failure

    def _trim_cache(self, now: float) -> None:
        for thread_id, (expires_at, _) in list(self._cache.items()):
            if expires_at <= now:
                self._cache.pop(thread_id, None)
        overflow = len(self._cache) - _MAX_CACHE_ENTRIES
        if overflow <= 0:
            return
        oldest = sorted(
            self._cache,
            key=lambda thread_id: (self._cache[thread_id][0], thread_id),
        )
        for thread_id in oldest[:overflow]:
            self._cache.pop(thread_id, None)

    @staticmethod
    def _validate_thread_ids(thread_ids: Iterable[str]) -> Optional[list[str]]:
        try:
            values = list(thread_ids)
        except (TypeError, ValueError):
            return None
        if len(values) > _MAX_THREAD_IDS_PER_RESOLVE:
            return None
        unique: list[str] = []
        seen: set[str] = set()
        for value in values:
            if (
                not isinstance(value, str)
                or not value
                or len(value) > _MAX_THREAD_ID_SCALARS
                or any(unicodedata.category(character) in {"Cc", "Cf"} for character in value)
            ):
                return None
            if value not in seen:
                unique.append(value)
                seen.add(value)
        return unique

    def _discover_executable(self) -> Optional[Path]:
        if self._executable_override is not None:
            candidates = [self._executable_override]
        else:
            home = Path.home()
            candidates = [
                home / ".local/bin/codex",
                home / ".codex/packages/standalone/current/bin/codex",
                Path("/opt/homebrew/bin/codex"),
                Path("/usr/local/bin/codex"),
            ]
        for candidate in candidates:
            try:
                status = candidate.stat()
            except OSError:
                continue
            if (
                stat.S_ISREG(status.st_mode)
                and status.st_uid in {0, os.getuid()}
                and not status.st_mode & 0o022
                and os.access(candidate, os.X_OK)
            ):
                return candidate
        return None

    def _resolve_uncached(
        self, executable: Path, thread_ids: list[str]
    ) -> dict[str, Optional[str]]:
        try:
            process = subprocess.Popen(
                [str(executable), "app-server"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                bufsize=0,
                start_new_session=True,
            )
        except OSError as error:
            raise _ResolutionFailure("unavailable") from error

        with self._process_lock:
            if self._closed:
                self._signal_process(process, signal.SIGTERM)
                self._reap(process)
                raise _ResolutionFailure("unavailable")
            self._active_process = process

        deadline = self._clock() + self._timeout
        buffer = bytearray()
        total_stdout = 0
        try:
            self._send(
                process,
                {
                    "id": 1,
                    "method": "initialize",
                    "params": {
                        "clientInfo": {
                            "name": "statelet",
                            "title": "Statelet",
                            "version": "1",
                        }
                    },
                },
            )
            response, total_stdout = self._read_response(
                process, 1, deadline, buffer, total_stdout
            )
            if "error" in response or not isinstance(response.get("result"), dict):
                raise _ResolutionFailure("protocol_error")

            self._send(process, {"method": "initialized", "params": {}})
            resolved: dict[str, Optional[str]] = {}
            for offset, thread_id in enumerate(thread_ids, start=2):
                self._send(
                    process,
                    {
                        "id": offset,
                        "method": "thread/read",
                        "params": {"threadId": thread_id, "includeTurns": False},
                    },
                )
                response, total_stdout = self._read_response(
                    process, offset, deadline, buffer, total_stdout
                )
                if "error" in response:
                    raise _ResolutionFailure("protocol_error")
                result = response.get("result")
                thread = result.get("thread") if isinstance(result, dict) else None
                if not isinstance(thread, dict) or thread.get("id") != thread_id:
                    raise _ResolutionFailure("protocol_error")
                name = thread.get("name")
                if name is not None and not isinstance(name, str):
                    raise _ResolutionFailure("protocol_error")
                resolved[thread_id] = _sanitize_title(name)
            return resolved
        finally:
            self._reap(process)
            with self._process_lock:
                if self._active_process is process:
                    self._active_process = None

    def close(self) -> None:
        with self._process_lock:
            self._closed = True
            process = self._active_process
        if process is not None:
            self._signal_process(process, signal.SIGTERM)

    def force_close(self) -> None:
        with self._process_lock:
            self._closed = True
            process = self._active_process
        if process is not None:
            self._signal_process(process, signal.SIGKILL)

    @staticmethod
    def _signal_process(process: subprocess.Popen[bytes], process_signal: int) -> None:
        if process.poll() is not None:
            return
        try:
            os.killpg(process.pid, process_signal)
        except OSError:
            try:
                os.kill(process.pid, process_signal)
            except OSError:
                pass

    @staticmethod
    def _send(process: subprocess.Popen[bytes], message: dict[str, object]) -> None:
        if process.stdin is None:
            raise _ResolutionFailure("unavailable")
        payload = (
            json.dumps(message, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
            + b"\n"
        )
        try:
            process.stdin.write(payload)
            process.stdin.flush()
        except (BrokenPipeError, OSError) as error:
            raise _ResolutionFailure("unavailable") from error

    def _read_response(
        self,
        process: subprocess.Popen[bytes],
        response_id: int,
        deadline: float,
        buffer: bytearray,
        total_stdout: int,
    ) -> tuple[dict[str, object], int]:
        while True:
            response, total_stdout = self._read_any_response(
                process, deadline, buffer, total_stdout
            )
            if response.get("id") == response_id:
                return response, total_stdout
            if "id" in response:
                raise _ResolutionFailure("protocol_error")

    def _read_any_response(
        self,
        process: subprocess.Popen[bytes],
        deadline: float,
        buffer: bytearray,
        total_stdout: int,
    ) -> tuple[dict[str, object], int]:
        if process.stdout is None:
            raise _ResolutionFailure("unavailable")
        descriptor = process.stdout.fileno()
        while True:
            newline = buffer.find(b"\n")
            if newline >= 0:
                raw = bytes(buffer[:newline])
                del buffer[: newline + 1]
                if not raw:
                    raise _ResolutionFailure("protocol_error")
                try:
                    response = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as error:
                    raise _ResolutionFailure("protocol_error") from error
                if not isinstance(response, dict):
                    raise _ResolutionFailure("protocol_error")
                return response, total_stdout

            remaining = deadline - self._clock()
            if remaining <= 0:
                raise _ResolutionFailure("timeout")
            try:
                ready, _, _ = select.select([descriptor], [], [], remaining)
            except (OSError, ValueError) as error:
                raise _ResolutionFailure("unavailable") from error
            if not ready:
                raise _ResolutionFailure("timeout")
            try:
                chunk = os.read(descriptor, _READ_CHUNK_BYTES)
            except OSError as error:
                raise _ResolutionFailure("unavailable") from error
            if not chunk:
                # EOF means the App Server side of the pipe is gone. Its
                # process status may not be observable yet, so classify the
                # race consistently as an availability failure.
                raise _ResolutionFailure("unavailable")
            total_stdout += len(chunk)
            if total_stdout > _MAX_STDOUT_BYTES:
                raise _ResolutionFailure("protocol_error")
            buffer.extend(chunk)

    @staticmethod
    def _reap(process: subprocess.Popen[bytes]) -> None:
        for stream in (process.stdin, process.stdout):
            if stream is not None:
                try:
                    stream.close()
                except OSError:
                    pass
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except OSError:
                try:
                    process.terminate()
                except OSError:
                    pass
            try:
                process.wait(timeout=0.5)
                return
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except OSError:
                    try:
                        process.kill()
                    except OSError:
                        pass
            except OSError:
                return
        try:
            process.wait(timeout=1.0)
        except (OSError, subprocess.TimeoutExpired):
            pass
