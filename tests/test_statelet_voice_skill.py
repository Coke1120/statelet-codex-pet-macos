#!/usr/bin/env python3
"""Tests for the project-local Statelet voice verification skill."""

from __future__ import annotations

import importlib.util
import io
import json
import math
import struct
import tempfile
import unittest
import wave
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from typing import Optional
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (
    ROOT
    / ".agents"
    / "skills"
    / "operate-statelet-local-voice"
    / "scripts"
    / "verify_statelet_voice.py"
)
SPEC = importlib.util.spec_from_file_location("verify_statelet_voice", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load Statelet voice verifier")
VOICE_VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VOICE_VERIFIER)


class StateletVoiceSkillTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="statelet-voice-skill-")
        self.root = Path(self.temporary.name)
        for relative in (
            "voice/assets/gpt",
            "voice/assets/sovits",
            "voice/assets/reference",
            "voice/generated",
        ):
            directory = self.root / relative
            directory.mkdir(parents=True, exist_ok=True)
            current = directory
            while current != self.root:
                current.chmod(0o700)
                current = current.parent
        gpt = self.root / "voice/assets/gpt/test.ckpt"
        sovits = self.root / "voice/assets/sovits/test.pth"
        gpt.write_bytes(b"gpt")
        sovits.write_bytes(b"sovits")
        gpt.chmod(0o600)
        sovits.chmod(0o600)
        self.write_wav(self.root / "voice/assets/reference/test.wav")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_wav(
        self,
        path: Path,
        silent: bool = False,
        constant_amplitude: Optional[int] = None,
        duration_seconds: float = 0.2,
        rate: int = 16_000,
    ) -> None:
        samples = []
        for index in range(round(rate * duration_seconds)):
            if silent:
                value = 0
            elif constant_amplitude is not None:
                value = constant_amplitude
            else:
                value = int(5_000 * math.sin(2 * math.pi * 440 * index / rate))
            samples.append(struct.pack("<h", value))
        with wave.open(str(path), "wb") as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(rate)
            output.writeframes(b"".join(samples))
        path.chmod(0o600)

    def write_library(
        self,
        silent_state: Optional[str] = None,
        omit_state: Optional[str] = None,
    ) -> None:
        lines = []
        for state in VOICE_VERIFIER.REQUIRED_STATES:
            if state == omit_state:
                continue
            relative = f"voice/generated/{state}.wav"
            self.write_wav(self.root / relative, silent=state == silent_state)
            lines.append(
                {
                    "id": f"00000000-0000-0000-0000-00000000000{len(lines)}",
                    "state": state,
                    "text": f"Test dialogue for {state}.",
                    "text_language": "en",
                    "revision": 1,
                    "status": "ready",
                    "generated_profile_revision": 1,
                    "generated_synthesis_policy_version": VOICE_VERIFIER.DEFAULT_POLICY_VERSION,
                    "output_relative_path": relative,
                }
            )
        library = {
            "version": 1,
            "profile_status": "ready",
            "profile": {
                "id": "10000000-0000-0000-0000-000000000000",
                "revision": 1,
                "name": "Test voice",
                "api_base_url": "http://127.0.0.1:9880",
                "gpt_weight_relative_path": "voice/assets/gpt/test.ckpt",
                "sovits_weight_relative_path": "voice/assets/sovits/test.pth",
                "reference_audio_relative_path": "voice/assets/reference/test.wav",
                "reference_text": "Test reference audio.",
                "prompt_language": "en",
                "default_text_language": "en",
                "input_fingerprint": "0" * 64,
            },
            "lines": lines,
            "pending_cleanup_paths": [],
        }
        library_path = self.root / "voice/dialogue-voice.json"
        library_path.write_text(
            json.dumps(library),
            encoding="utf-8",
        )
        library_path.chmod(0o600)

    def arguments(self) -> SimpleNamespace:
        return SimpleNamespace(
            support_root=self.root,
            required_policy_version=VOICE_VERIFIER.DEFAULT_POLICY_VERSION,
            allow_pending=False,
            hash_assets=False,
        )

    def verify(self) -> None:
        with redirect_stdout(io.StringIO()):
            VOICE_VERIFIER.verify(self.arguments())

    def test_default_support_root_uses_statelet_identity(self) -> None:
        with patch("sys.argv", [str(SCRIPT)]):
            arguments = VOICE_VERIFIER.parse_args()
        self.assertEqual(
            arguments.support_root,
            Path.home() / "Library" / "Application Support" / "Statelet",
        )

    def test_accepts_ready_non_silent_audio_for_every_state(self) -> None:
        self.write_library()
        self.assertIsNone(self.verify())

    def test_rejects_effectively_silent_ready_audio(self) -> None:
        self.write_library(silent_state="waiting")
        with self.assertRaisesRegex(VOICE_VERIFIER.VerificationError, "effectively silent"):
            self.verify()

    def test_rejects_missing_required_state(self) -> None:
        self.write_library(omit_state="review")
        with self.assertRaisesRegex(VOICE_VERIFIER.VerificationError, "review has no ready"):
            self.verify()

    def test_rejects_structurally_invalid_statelet_library(self) -> None:
        self.write_library()
        library_path = self.root / "voice/dialogue-voice.json"
        library = json.loads(library_path.read_text(encoding="utf-8"))
        del library["lines"][0]["text_language"]
        library_path.write_text(json.dumps(library), encoding="utf-8")
        with self.assertRaisesRegex(VOICE_VERIFIER.VerificationError, "line schema is invalid"):
            self.verify()

    def test_accepts_decode_defaults_and_reports_legacy_output_policy(self) -> None:
        self.write_library()
        library_path = self.root / "voice/dialogue-voice.json"
        library = json.loads(library_path.read_text(encoding="utf-8"))
        del library["profile_status"]
        del library["pending_cleanup_paths"]
        del library["lines"][0]["state"]
        del library["lines"][1]["generated_synthesis_policy_version"]
        library_path.write_text(json.dumps(library), encoding="utf-8")
        with self.assertRaisesRegex(
            VOICE_VERIFIER.VerificationError,
            "state running: uses an outdated synthesis policy",
        ):
            self.verify()

    def test_rejects_invalid_cleanup_queue_entries(self) -> None:
        invalid_queues = (
            ["voice/other/orphan.wav"],
            ["voice/generated/../orphan.wav"],
            ["voice/generated/orphan.wav", "voice/generated/orphan.wav"],
            ["voice/generated/waiting.wav"],
            ["voice/assets/gpt/test.ckpt"],
        )
        for pending_cleanup_paths in invalid_queues:
            with self.subTest(pending_cleanup_paths=pending_cleanup_paths):
                self.write_library()
                library_path = self.root / "voice/dialogue-voice.json"
                library = json.loads(library_path.read_text(encoding="utf-8"))
                library["pending_cleanup_paths"] = pending_cleanup_paths
                library_path.write_text(json.dumps(library), encoding="utf-8")
                with self.assertRaisesRegex(
                    VOICE_VERIFIER.VerificationError,
                    "cleanup queue schema is invalid",
                ):
                    self.verify()

    def test_rejects_invalid_failure_code_alphabet(self) -> None:
        self.write_library()
        library_path = self.root / "voice/dialogue-voice.json"
        library = json.loads(library_path.read_text(encoding="utf-8"))
        line = library["lines"][0]
        line["status"] = "failed"
        del line["generated_profile_revision"]
        del line["generated_synthesis_policy_version"]
        del line["output_relative_path"]
        line["failure_code"] = "lowercase-not-allowed"
        library_path.write_text(json.dumps(library), encoding="utf-8")
        with self.assertRaisesRegex(VOICE_VERIFIER.VerificationError, "line state is invalid"):
            self.verify()

    def test_rejects_unsafe_retained_output_path(self) -> None:
        self.write_library()
        library_path = self.root / "voice/dialogue-voice.json"
        library = json.loads(library_path.read_text(encoding="utf-8"))
        line = library["lines"][0]
        line["status"] = "stale"
        line["output_relative_path"] = "voice/generated/../idle.wav"
        library_path.write_text(json.dumps(library), encoding="utf-8")
        with self.assertRaisesRegex(VOICE_VERIFIER.VerificationError, "line state is invalid"):
            self.verify()

    def test_reports_every_bad_state_in_one_run(self) -> None:
        self.write_library(silent_state="waiting", omit_state="review")
        with self.assertRaises(VOICE_VERIFIER.VerificationError) as caught:
            self.verify()
        message = str(caught.exception)
        self.assertIn("state waiting: WAV is effectively silent", message)
        self.assertIn("state review has no ready dialogue", message)

    def test_rejects_low_level_constant_signal(self) -> None:
        self.write_library()
        self.write_wav(
            self.root / "voice/generated/waiting.wav",
            constant_amplitude=4,
        )
        with self.assertRaisesRegex(VOICE_VERIFIER.VerificationError, "effectively silent"):
            self.verify()

    def test_rejects_world_readable_managed_audio(self) -> None:
        self.write_library()
        output = self.root / "voice/generated/waiting.wav"
        output.chmod(0o644)
        with self.assertRaisesRegex(VOICE_VERIFIER.VerificationError, "permissions are not private"):
            self.verify()

    def test_rejects_state_audio_longer_than_fifteen_seconds(self) -> None:
        self.write_library()
        self.write_wav(
            self.root / "voice/generated/waiting.wav",
            duration_seconds=16,
        )
        with self.assertRaisesRegex(
            VOICE_VERIFIER.VerificationError,
            "exceeds the accepted short-state duration",
        ):
            self.verify()

    def test_rejects_truncated_data_payload(self) -> None:
        self.write_library()
        output = self.root / "voice/generated/waiting.wav"
        truncated = bytearray(output.read_bytes()[:-1])
        struct.pack_into("<I", truncated, 4, len(truncated) - 8)
        output.write_bytes(truncated)
        with self.assertRaisesRegex(VOICE_VERIFIER.VerificationError, "container is invalid"):
            self.verify()

    def test_rejects_trailing_bytes_after_declared_riff(self) -> None:
        self.write_library()
        output = self.root / "voice/generated/waiting.wav"
        with_junk = bytearray(output.read_bytes() + b"junk")
        struct.pack_into("<I", with_junk, 4, len(with_junk) - 8)
        output.write_bytes(with_junk)
        with self.assertRaisesRegex(VOICE_VERIFIER.VerificationError, "container is invalid"):
            self.verify()

    def test_rejects_sample_rate_below_statelet_runtime_range(self) -> None:
        self.write_library()
        self.write_wav(
            self.root / "voice/generated/waiting.wav",
            duration_seconds=1,
            rate=1,
        )
        with self.assertRaisesRegex(VOICE_VERIFIER.VerificationError, "geometry is invalid"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
