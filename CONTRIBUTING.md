# Contributing to Statelet

Thank you for improving Statelet, the local-first Codex lifecycle companion for
macOS.

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
- Xcode Command Line Tools with Swift 5.9 or newer
- Python 3.9 for the hash-locked alpha-authoring dependencies
- `ffmpeg` and Apple's `avconvert` for the complete media round-trip tests

Create a local Python environment and run the checks from the repository root:

```bash
python3.9 -m venv .venv
.venv/bin/python -m pip install --upgrade pip
.venv/bin/python -m pip install --require-hashes -r mac/requirements-alpha.txt
.venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v
swift test --package-path mac/CodexPetMac
swift run --package-path mac/CodexPetMac -c release codex-pet-core-self-test
bash mac/CodexPetMac/scripts/build_app.sh
codesign --verify --deep --strict mac/CodexPetMac/dist/Statelet.app
```

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
