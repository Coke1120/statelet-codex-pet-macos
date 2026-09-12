# Contributing to Statelet

Thank you for improving Statelet, the local-first Codex and Grok Build lifecycle
companion for macOS.

## Project scope

Keep contributions focused on the native macOS application, its local lifecycle
publisher, animation authoring pipeline, tests, and documentation. Do not commit
personal media, generated delivery movies, conversion reports, runtime state,
credentials, signing identities, or build output.

Only contribute assets and source material that you have permission to publish
under the repository's MIT license. Record new public visual assets in
`ASSET_PROVENANCE.md`.

## Development setup

Requirements:

- macOS 13 or newer
- Full Xcode with Swift 5.9 or newer and XCTest for the complete test suite
- Python 3.9 for the hash-locked alpha-authoring dependencies
- `ffmpeg`, `ffprobe`, and Apple's `avconvert` for the complete media round-trip tests
- A logged-in, GUI-capable Mac for native layout and AVPlayer integration tests

Create and activate a local Python environment from the repository root:

```bash
python3.9 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install --require-hashes -r mac/requirements-alpha.txt
. .venv/bin/activate
```

Then run the canonical [release verification gate](docs/DEPLOYMENT.md#release-verification)
in the same shell. Smoke and CI use `python3 tools/run_tests.py`, which excludes
the MP4/alpha conversion suite before import and rejects skipped selected tests.
Run `python3 tools/run_tests.py --include-conversion` only when you want the
manual conversion checks as well. The gate also runs both the Swift unit
suite and the explicitly enabled AVPlayer integration suite. A plain
`swift test` skips AVPlayer integration unless its opt-in environment variable
is set. Command Line Tools alone can build the app and run the core self-test,
but may not provide XCTest; see the gate's Xcode selection instructions.

## Identity and compatibility contract

The macOS-facing identity is Statelet throughout: bundle identifier
`com.coke1120.Statelet`, executable and Swift target `Statelet`, Application
Support directory `Statelet`, and `com.coke1120.statelet.*` LaunchAgents.
Legacy CodexPet identifiers may appear only in ownership-checked migration,
rollback, removal, and regression-test paths. Changes to either side of this
boundary require representative upgrade and data-preservation coverage.

## Pull requests

Keep changes small and explain the user-visible result, compatibility impact,
and verification performed. Add or update tests for behavior changes. A pull
request should pass the same Python, Swift, self-test, build, and ad-hoc
codesign checks as CI.

By contributing, you agree that your contribution is licensed under the MIT
license and that you will follow `CODE_OF_CONDUCT.md`.
