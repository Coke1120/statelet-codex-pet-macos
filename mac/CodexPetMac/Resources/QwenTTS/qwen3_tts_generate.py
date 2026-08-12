#!/usr/bin/env python3
"""Bounded Statelet Qwen3-TTS helper. Accepts one private JSON request on stdin."""

import json
import os
import sys
from contextlib import contextmanager
from pathlib import Path


def fail() -> None:
    # Deliberately omit exception, text, and path details from the subprocess channel.
    sys.stderr.write("QWEN_TTS_FAILED\n")
    raise SystemExit(1)


@contextmanager
def silence_third_party_output():
    sys.stdout.flush()
    sys.stderr.flush()
    saved_stdout = os.dup(sys.stdout.fileno())
    saved_stderr = os.dup(sys.stderr.fileno())
    null_fd = os.open(os.devnull, os.O_WRONLY)
    try:
        os.dup2(null_fd, sys.stdout.fileno())
        os.dup2(null_fd, sys.stderr.fileno())
        yield
    finally:
        sys.stdout.flush()
        sys.stderr.flush()
        os.dup2(saved_stdout, sys.stdout.fileno())
        os.dup2(saved_stderr, sys.stderr.fileno())
        os.close(null_fd)
        os.close(saved_stdout)
        os.close(saved_stderr)


def absolute_child(root: Path, value: str) -> Path:
    path = Path(value)
    if not path.is_absolute():
        fail()
    resolved = path.resolve(strict=True)
    try:
        resolved.relative_to(root)
    except ValueError:
        fail()
    return resolved


def relative_child(root: Path, value: str) -> Path:
    path = Path(value)
    if path.is_absolute() or not path.parts or any(part in ("", ".", "..") for part in path.parts):
        fail()
    resolved = (root / path).resolve(strict=True)
    try:
        resolved.relative_to(root)
    except ValueError:
        fail()
    return resolved


def main() -> None:
    try:
        if os.getpgrp() != os.getpid():
            fail()
        raw_request = sys.stdin.buffer.read(262_145)
        if len(raw_request) > 262_144:
            fail()
        request = json.loads(raw_request)
        text = request.get("text")
        if not isinstance(request, dict) or not isinstance(text, str) or not text.strip() or len(text) > 500:
            fail()
        if str(request.get("text_language", "")).lower() != "japanese":
            fail()
        if str(request.get("reference_language", "")).lower() != "japanese":
            fail()

        package_root = Path(request["package_root"]).resolve(strict=True)
        if not package_root.is_dir():
            fail()
        model_file = absolute_child(package_root, request["model_file"])
        config_path = absolute_child(package_root, request["config_file"])
        reference_path = absolute_child(package_root, request["reference_file"])
        output_path = Path(request["output_file"])
        if not output_path.is_absolute() or output_path.exists():
            fail()
        output_parent = output_path.parent.resolve(strict=True)
        if not output_parent.is_dir():
            fail()

        config = json.loads(config_path.read_text(encoding="utf-8"))
        generation = config["generation"]
        expected = {
            "reference_text": request["reference_text"],
            "language": request["reference_language"],
        }
        if config.get("reference_text") != expected["reference_text"]:
            fail()
        if str(config.get("language", "")).lower() != expected["language"].lower():
            fail()
        if relative_child(package_root, str(config["reference_audio"])) != reference_path:
            fail()
        configured_model = relative_child(package_root, str(config["model_path"]))
        if configured_model != model_file.parent:
            fail()
        if config.get("audio") != {
            "format": "wav", "subtype": "PCM_16", "expected_sample_rate": 24000
        }:
            fail()
        parameters = request["parameters"]
        for key in ("temperature", "top_k", "top_p", "repetition_penalty", "max_tokens", "seed"):
            if generation.get(key) != parameters.get(key):
                fail()

        with silence_third_party_output():
            import mlx.core as mx
            import numpy as np
            import soundfile as sf
            from mlx_audio.tts.utils import load_model

            mx.random.seed(int(parameters["seed"]))
            model = load_model(str(configured_model))
            results = list(model.generate(
                text=request["text"],
                lang_code=request["text_language"],
                ref_audio=str(reference_path),
                ref_text=request["reference_text"],
                temperature=float(parameters["temperature"]),
                top_k=int(parameters["top_k"]),
                top_p=float(parameters["top_p"]),
                repetition_penalty=float(parameters["repetition_penalty"]),
                max_tokens=int(parameters["max_tokens"]),
                verbose=False,
            ))
        if not results:
            fail()
        sample_rate = int(results[0].sample_rate)
        if sample_rate != 24_000:
            fail()
        audio = np.concatenate([np.asarray(result.audio).reshape(-1) for result in results])
        if audio.size == 0 or audio.size > sample_rate * 60:
            fail()

        temporary = output_parent / ("." + output_path.name + ".partial")
        if temporary.exists():
            fail()
        sf.write(temporary, audio, sample_rate, subtype="PCM_16", format="WAV")
        os.chmod(temporary, 0o600)
        with temporary.open("rb") as stream:
            os.fsync(stream.fileno())
        os.replace(temporary, output_path)
        directory_fd = os.open(output_parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except SystemExit:
        raise
    except BaseException:
        fail()


if __name__ == "__main__":
    main()
