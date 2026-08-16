# Deploy Statelet on macOS

This guide covers building, installing, upgrading, starting automatically, and
uninstalling Statelet 1.8.2 (build 16) on macOS 13 or newer.

The first public release is source-only. The maintained build script produces
an ad-hoc-signed `.app` for personal local use. It does not produce a DMG,
Developer ID signature, notarization ticket, or App Store package.

The in-app updater follows the same boundary: it will show release metadata,
but it will not install an artifact until the signed release build embeds the
authorized Developer ID team identifier in `StateletUpdateSigningTeamIdentifier`
and publishes a matching `Statelet*.zip` with a GitHub SHA-256 digest. This
prevents the current source-only/ad-hoc build from treating an arbitrary
trusted certificate as a Statelet publisher.

## Choose a deployment path

| Goal | Procedure | Result |
| --- | --- | --- |
| Try the interface | Build and open the app from `dist/` | Temporary app; no lifecycle publisher, hooks, or login item are installed |
| Use Statelet daily | Build, then run the installer | App in `~/Applications`, Codex lifecycle hooks, state aggregator, and optional login launch |
| Publish a binary | Complete a separate signed-release process | Developer ID signing, hardened-runtime review, notarization, stapling, and Gatekeeper testing are required |

Do not redistribute the current ad-hoc-signed app as though it were a notarized
public release.

## Requirements

Install Xcode Command Line Tools if Swift is unavailable:

```bash
xcode-select --install
```

Check the required tools:

```bash
sw_vers -productVersion
swift --version
python3 --version
test -x /usr/bin/avconvert
```

Statelet requires macOS 13+, Swift 5.9+, and a stable Python 3.9+ interpreter.
The installer rejects a Python executable located inside the repository or a
temporary directory because its LaunchAgent path must remain valid after the
checkout changes.

`avconvert` is needed only for optional MP4 transparency conversion.

## Build the app

Run from the repository root:

```bash
bash mac/CodexPetMac/scripts/build_app.sh
```

The builder:

1. compiles the SwiftPM executable in release mode;
2. assembles `mac/CodexPetMac/dist/Statelet.app`;
3. embeds the icon, example media map, and maintained conversion tools;
4. validates `Info.plist`;
5. rejects private workspace, home, or temporary paths in the app and dSYM;
6. strips release debug metadata from the delivered executable; and
7. applies an ad-hoc signature.

It also writes matching local crash symbols beside the app:

```text
mac/CodexPetMac/dist/Statelet.app.dSYM
```

Verify the bundle:

```bash
codesign --verify --deep --strict mac/CodexPetMac/dist/Statelet.app
plutil -lint mac/CodexPetMac/dist/Statelet.app/Contents/Info.plist
```

The dSYM is useful for matching local crash symbolication. It is not needed to
run the app and is not a public release binary.

## Try without installing

```bash
open mac/CodexPetMac/dist/Statelet.app --args --settings
```

This starts the app from the checkout and opens Settings. It reads the normal
Statelet files under `~/Library/Application Support/Statelet/`, but it does not
install the lifecycle publisher, merge hooks, or add a login item.

## Install for the current account

Build first, then run:

```bash
bash mac/CodexPetMac/scripts/install.sh
```

The installer performs ownership checks before changing managed destinations.
It stages replacements transactionally, stops and restarts managed LaunchAgents,
and rolls back files and prior loaded state after a failed transition when
possible.

The installer:

- installs `Statelet.app` in `~/Applications`;
- installs the standard-library lifecycle hook and aggregator;
- creates marked state-aggregator and player LaunchAgents;
- merges Statelet's commands into `~/.codex/hooks.json` without replacing
  unrelated commands; and
- preserves an existing `media-map.json`, `global-transitions.json`,
  `character-library.json`, hidden per-character maps/assets, and user media
  during upgrades.

An unmanaged app or LaunchAgent at a managed destination causes installation to
fail before replacement. See [Legacy identity migration](#legacy-identity-migration)
for the ownership checks applied to older installations.

Restart Codex after the first installation so it loads the new hook
configuration. Launch Statelet with:

```bash
open "$HOME/Applications/Statelet.app"
```

Statelet has no Dock icon. Look for its orbit icon in the menu bar.

## Control autostart

The normal installer registers the player to start at login. To install the app
and lifecycle aggregator without registering the player LaunchAgent:

```bash
bash mac/CodexPetMac/scripts/install.sh --no-player-launch-agent
open "$HOME/Applications/Statelet.app"
```

After a normal installation, use **Settings → Diagnostics → Start Statelet when
I log in** to control future logins. Turning it off does not quit the current
process. Managed upgrades preserve that preference.

Use **Repair Startup…** only when Diagnostics reports a missing or stale managed
player startup item. Repair validates the installed app and changes only the
`statelet-v2`-marked player LaunchAgent. It does not edit Codex hooks or the
state aggregator.

## Prepare MP4 conversion tools

Statelet performs background removal offline. Runtime playback never chroma-keys
an MP4. The converter creates Apple HEVC with alpha and verifies the result
through Apple's media pipeline before adding it to a library.

Every new conversion report uses schema v1 and records the toolchain, selected
profile, explicit normalization policy, and a fresh 256-bit invocation
challenge. The app supplies that challenge to the converter and accepts local
installation only when the returned report matches it. A report copied from
elsewhere remains a portable, self-asserted claim even if it contains a
challenge; it cannot acquire local trust without the app's expected value. A
schema-v1 portable pair therefore requires a separate, explicit user trust
confirmation and remains labeled portable/unattested. Reports with no schema
key remain decodable only for legacy diagnostics, while explicit version 0 and
unknown future versions fail closed. The Swift validator rejects report data
larger than 1 MiB before JSON decoding and requires canonical schema-v1
provenance even when no local challenge is expected.

Install `ffmpeg` using a package manager you trust. With Homebrew:

```bash
brew install ffmpeg
```

Create the reproducible Python 3.9 conversion environment:

```bash
STATELET_ALPHA_RUNTIME="$HOME/Library/Application Support/Statelet/alpha-runtime"
python3.9 -m venv "$STATELET_ALPHA_RUNTIME"
"$STATELET_ALPHA_RUNTIME/bin/python3" -m pip install --require-hashes \
  -r mac/requirements-alpha.txt

command -v ffmpeg
command -v ffprobe
test -x /usr/bin/avconvert
"$STATELET_ALPHA_RUNTIME/bin/python3" \
  -c 'import numpy, PIL; print(numpy.__version__, PIL.__version__)'
```

The app discovers that `alpha-runtime` automatically. You can instead use
**Settings → Animations → Setup Guide → Choose Python…** to select another
Python executable that can import NumPy and Pillow.

Developers may configure these environment variables before launching the app:

- `STATELET_ALPHA_PYTHON`
- `STATELET_FFMPEG`
- `STATELET_FFPROBE`
- `STATELET_AVCONVERT`

Return to **Animations** and choose **Check Again** after changing tools.

To exercise the same AVFoundation extraction used by installed-media playback
acceptance against a real converted movie:

```bash
swift run --package-path mac/CodexPetMac \
  codex-pet-core-self-test \
  --playback-smoke "$STATELET_OUTPUT" 320 480 24
```

This smoke requires one playable HEVC video track, zero audio tracks,
transformed geometry and nominal FPS matching the arguments, and a successfully
decoded first frame. Source audio may be reported as stripped, but delivery
audio always fails. The smoke does not replace the report's all-frame Apple
round-trip, alpha, composite, hash, and source-immutability gates.

## Upgrade

Pull or unpack the newer source, then rebuild and rerun the installer:

```bash
bash mac/CodexPetMac/scripts/build_app.sh
bash mac/CodexPetMac/scripts/install.sh
```

Do not uninstall first. A managed upgrade preserves media, the media map, the
separate Global transition library, and the current start-at-login choice.
Multi-character installations also preserve the authoritative catalog sidecar
and every profile map; the installer does not merge profile data into the
legacy root map.

New builds and installations use the canonical Statelet identity:

| Field | Value |
| --- | --- |
| Installed app | `~/Applications/Statelet.app` |
| Bundle identifier | `com.coke1120.Statelet` |
| Executable and `CFBundleName` | `Statelet` |
| Application Support | `~/Library/Application Support/Statelet` |
| LaunchAgents | `com.coke1120.statelet.state-aggregator`, `com.coke1120.statelet.mac-player` |
| Managed marker | `statelet-v2` |

### Legacy identity migration

The installer recognizes a legacy `~/Applications/CodexPetMac.app`, bundle ID
`com.coke1120.CodexPetMac`, `CodexPetManaged`/`CodexPetMacManaged` keys,
`~/Library/Application Support/CodexPet`, `com.coke1120.codex-pet.*`
LaunchAgents, and marker `mac-widget-v1` only when their ownership markers are
valid. It migrates owned user data and startup files transactionally to the
canonical Statelet locations, refuses conflicting canonical data, and preserves
unmanaged legacy artifacts. Rollback restores both identity sets if installation
does not commit.

## Installed files

```text
~/Applications/Statelet.app
~/Library/Application Support/Statelet/media/media-map.json
~/Library/Application Support/Statelet/media/global-transitions.json
~/Library/Application Support/Statelet/media/character-library.json
~/Library/Application Support/Statelet/media/.character-<id>.media-map.json
~/Library/Application Support/Statelet/media/.character-<id>.assets/
~/Library/Application Support/Statelet/runtime/current_state.json
~/Library/Application Support/Statelet/sessions/
~/Library/Application Support/Statelet/logs/
~/Library/Application Support/Statelet/Statelet/
~/Library/LaunchAgents/com.coke1120.statelet.state-aggregator.plist
~/Library/LaunchAgents/com.coke1120.statelet.mac-player.plist
~/.codex/hooks.json
```

Statelet does not install animation media. Imported media stays under the
current account's Application Support directory. On an existing or custom
`--media-map` installation, absence of `character-library.json` bootstraps one
`Default` profile that points at that configured same-directory root basename.
Additional profiles keep independent hidden same-directory maps so relative
media paths and older root-map readers remain compatible.

Exported `.statelet-character` items are user-chosen directory packages, not
installed application components. Each contains a bounded `manifest.json`, one
ordinary Statelet media map, and declared assets. Import verifies safe relative
paths, declared sizes and lowercase SHA-256 hashes, report-to-movie references,
and AVFoundation playback before committing a new hidden map and asset tree.
Reports may be absent only for legacy portability; the app requires an explicit
trust confirmation and still performs playback checks. It does not represent a
reportless import as locally attested.

## Uninstall

Run from a checkout containing the matching uninstaller:

```bash
bash mac/CodexPetMac/scripts/uninstall.sh
```

The uninstaller removes only marked Statelet components and exact hook commands
that point to the removed widget runtime. It refuses unmarked component or
LaunchAgent targets and preserves unrelated hooks.

It intentionally preserves:

- animation movies and posters;
- converter reports;
- `media-map.json`;
- `global-transitions.json`;
- `character-library.json`;
- hidden `.character-<id>.media-map.json` files and imported asset trees;
- aggregate state and per-session records; and
- local logs.

This preservation makes reinstall and recovery possible. If you want to remove
the retained data, open Finder, choose **Go → Go to Folder…**, enter
`~/Library/Application Support/Statelet`, inspect its contents, and move the
chosen data to Trash.

## Public binary distribution

The current build is suitable for personal local execution only. Before
attaching a binary to a public release:

1. sign with an authorized Developer ID Application identity;
2. decide and review hardened-runtime entitlements;
3. notarize the exact distributed artifact;
4. staple the notarization ticket;
5. test first launch and upgrades on a clean Mac under Gatekeeper;
6. scan the app and symbols for private paths;
7. exclude all user media, reports, settings, logs, credentials, and local
   state; and
8. complete a rights review for every bundled visual asset.

A DMG is only an optional presentation container. It does not replace signing
or notarization. The first public Statelet release therefore publishes source,
not an ad-hoc-signed app.

## Release verification

Run the affected checks from the repository root:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
import unittest

suite = unittest.defaultTestLoader.discover(
    "tests", pattern="test_*.py"
)
result = unittest.TextTestRunner(verbosity=2).run(suite)
if result.skipped:
    raise SystemExit(f"Python tests skipped: {result.skipped}")
raise SystemExit(0 if result.wasSuccessful() else 1)
PY

swift run -c release --package-path mac/CodexPetMac codex-pet-core-self-test
swift test -c release --package-path mac/CodexPetMac
bash mac/CodexPetMac/scripts/build_app.sh
codesign --verify --deep --strict mac/CodexPetMac/dist/Statelet.app
python3 -m json.tool mac/CodexPetMac/Examples/media-map.json >/dev/null
git diff --check
```

Prepare the alpha toolchain before running this gate. Test discovery includes
every `tests/test_*.py` module, including the alpha and native AppKit layout
suites, and the release gate fails if any test is skipped.

Full `swift test` requires Xcode with XCTest. Command Line Tools alone can build
the app and run `codex-pet-core-self-test`, but may not provide XCTest.
