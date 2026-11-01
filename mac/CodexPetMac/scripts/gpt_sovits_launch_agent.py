#!/usr/bin/env python3
"""Recognize existing Statelet voice jobs without inspecting private runtime assets."""

import re
import ipaddress
from pathlib import Path
from urllib.parse import urlsplit


LABEL = "com.coke1120.statelet.gpt-sovits"
MARKER = "statelet-v2"
START_TRIGGERS = {
    "Sockets", "MachServices", "LaunchEvents", "WatchPaths", "QueueDirectories",
    "StartInterval", "StartCalendarInterval", "StartOnMount",
}


def profile_endpoint(document):
    """Read only a saved GPT endpoint and pin; never infer backend/gateway ports."""
    profile = document.get("profile") if isinstance(document, dict) else None
    if not isinstance(profile, dict):
        return None
    endpoint = profile.get("api_base_url")
    pin = profile.get("tls_leaf_certificate_sha256")
    if (not isinstance(endpoint, str) or not isinstance(pin, str)
            or not re.fullmatch(r"[0-9a-fA-F]{64}", pin)
            or not endpoint.isascii() or any(character.isspace() for character in endpoint)):
        return None
    try:
        url = urlsplit(endpoint)
        address = ipaddress.ip_address(url.hostname or "")
        port = url.port
        if (url.scheme != "https" or not endpoint.startswith("https://")
                or not address.is_loopback or "%" in (url.hostname or "")
                or url.username is not None or url.password is not None
                or url.path not in {"", "/"} or url.query or url.fragment
                or "?" in endpoint or "#" in endpoint
                or (port is not None and not 1 <= port <= 65535)):
            return None
        host = f"[{address.compressed}]" if address.version == 6 else address.compressed
        authority = host + (f":{port}" if port is not None else "")
        if url.netloc != authority:
            return None
        return endpoint
    except ValueError:
        return None


def migrate_plist(payload, home, endpoint=None):
    """Return the on-demand payload, or None for an unrelated/unknown job.

    Early manually provisioned API-v2 jobs have no ownership marker. Adopt only
    their combined label, venv/API, loopback and Statelet log signature. Explicitly
    marked API jobs may retain custom arguments; gateway/wrapper executables stay
    externally managed. Never read weights,
    configuration, TLS keys, or the runtime executable to recognize a job.
    """
    if not isinstance(payload, dict) or payload.get("Label") != LABEL:
        return None
    # Bootstrap must not start an engine through another launchd trigger.
    if START_TRIGGERS.intersection(payload) or payload.get("OnDemand") is False:
        return None
    marker = payload.get("StateletManaged")
    if marker == MARKER:
        arguments = payload.get("ProgramArguments")
        if (not isinstance(arguments, list) or len(arguments) < 2
                or not isinstance(arguments[1], str)
                or Path(arguments[1]).name != "api_v2.py"):
            return None
    if marker != MARKER:
        if "StateletManaged" in payload or "Program" in payload:
            return None
        arguments = payload.get("ProgramArguments")
        working = payload.get("WorkingDirectory")
        if (not isinstance(arguments, list) or len(arguments) != 8
                or not all(isinstance(value, str) and value for value in arguments)
                or not isinstance(working, str) or not Path(working).is_absolute()):
            return None
        directory = Path(working)
        python, api = map(Path, arguments[:2])
        if (not python.is_absolute() or ".." in python.parts or ".." in directory.parts
                or not re.fullmatch(r"python(?:3(?:\.\d+)?)?", python.name)
                or python.parent.name != "bin" or python.parent.parent.parent != directory
                or python.parent.parent.name not in {".venv", "venv"}
                or api != directory / "api_v2.py"
                or arguments[2] != "-a" or arguments[3] not in {"127.0.0.1", "::1"}
                or arguments[4] != "-p" or len(arguments[5]) > 5 or not arguments[5].isascii()
                or not arguments[5].isdigit() or not 1 <= int(arguments[5]) <= 65535
                or arguments[6] != "-c" or not Path(arguments[7]).is_absolute()
                or payload.get("KeepAlive") is not False):
            return None
        support = Path(home) / "Library/Application Support/Statelet"
        for key in ("StandardOutPath", "StandardErrorPath"):
            value = payload.get(key)
            if not isinstance(value, str):
                return None
            path = Path(value)
            if (support not in path.parents or ".." in path.parts
                    or not path.name.startswith("gpt-sovits")):
                return None
    migrated = {**payload, "StateletManaged": MARKER, "RunAtLoad": False, "KeepAlive": False}
    if endpoint is not None and "StateletVoiceEndpoint" not in payload:
        migrated["StateletVoiceEndpoint"] = endpoint
    return migrated
