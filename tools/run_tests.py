#!/usr/bin/env python3
"""Run Statelet's Python smoke/CI suite; video conversion is opt-in."""

import argparse
from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
CONVERSION_MODULE = "test_macos_alpha_video.py"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--include-conversion", action="store_true",
        help="also run the MP4/alpha conversion suite (requires its local toolchain)",
    )
    parser.add_argument("--list", action="store_true", help="list selected modules without importing or running them")
    args = parser.parse_args()
    paths = [
        path for path in sorted((ROOT / "tests").glob("test_*.py"))
        if args.include_conversion or path.name != CONVERSION_MODULE
    ]
    if args.list:
        print("\n".join(path.name for path in paths))
        return 0

    sys.path.insert(0, str(ROOT))
    suite = unittest.TestSuite()
    loader = unittest.TestLoader()
    # Exclude the conversion module before import, so it cannot start work or
    # introduce conversion-only dependencies into smoke/CI discovery.
    for path in paths:
        suite.addTests(loader.discover(str(ROOT / "tests"), pattern=path.name))
    if not args.include_conversion:
        print("MP4/alpha conversion tests are manual: add --include-conversion.", flush=True)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if result.skipped:
        print(f"Selected Python tests skipped: {result.skipped}", file=sys.stderr)
    return 0 if result.wasSuccessful() and not result.skipped else 1


if __name__ == "__main__":
    raise SystemExit(main())
