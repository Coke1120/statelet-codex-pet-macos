#!/usr/bin/env python3
"""Silent dependency probe for Statelet's private Qwen3-TTS runtime."""

import os
import sys


def main() -> None:
    try:
        if os.getpgrp() != os.getpid():
            raise SystemExit(1)
        # The parent closes stdin only after confirming this process owns its
        # group, so a successful probe cannot race ahead of containment.
        sys.stdin.buffer.read()
        sys.stdout.flush()
        sys.stderr.flush()
        saved_stdout = os.dup(sys.stdout.fileno())
        saved_stderr = os.dup(sys.stderr.fileno())
        null_fd = os.open(os.devnull, os.O_WRONLY)
        try:
            os.dup2(null_fd, sys.stdout.fileno())
            os.dup2(null_fd, sys.stderr.fileno())
            import mlx  # noqa: F401
            import mlx_audio  # noqa: F401
            import numpy  # noqa: F401
            import soundfile  # noqa: F401
        finally:
            os.dup2(saved_stdout, sys.stdout.fileno())
            os.dup2(saved_stderr, sys.stderr.fileno())
            os.close(null_fd)
            os.close(saved_stdout)
            os.close(saved_stderr)
    except BaseException:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
