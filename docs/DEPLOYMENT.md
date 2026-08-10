# Deploy Statelet, the Codex Pet for macOS

This guide covers building, installing, upgrading, starting automatically, and
uninstalling Statelet 1.6.0 (build 11) on macOS 13 or newer.

The first public release is source-only. The maintained build script produces
an ad-hoc-signed `.app` for personal local use. It does not produce a DMG,
Developer ID signature, notarization ticket, or App Store package.

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
Statelet files under `~/Library/Application Support/CodexPet/`, but it does not
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
- preserves an existing `media-map.json` and user media during upgrades.

A managed legacy `~/Applications/CodexPetMac.app` is migrated to
`~/Applications/Statelet.app`. An unmanaged app or LaunchAgent at a managed
destination causes installation to fail before replacement.

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
`mac-widget-v1`-marked player LaunchAgent. It does not edit Codex hooks or the
state aggregator.

## Prepare MP4 conversion tools

Statelet performs background removal offline. Runtime playback never chroma-keys
an MP4. The converter creates Apple HEVC with alpha and verifies the result
through Apple's media pipeline before adding it to a library.

Install `ffmpeg` using a package manager you trust. With Homebrew:

```bash
brew install ffmpeg
```

Create the reproducible Python 3.9 conversion environment:

```bash
CODEX_PET_ALPHA_RUNTIME="$HOME/Library/Application Support/CodexPet/alpha-runtime"
python3.9 -m venv "$CODEX_PET_ALPHA_RUNTIME"
"$CODEX_PET_ALPHA_RUNTIME/bin/python3" -m pip install --require-hashes \
  -r mac/requirements-alpha.txt

command -v ffmpeg
command -v ffprobe
test -x /usr/bin/avconvert
"$CODEX_PET_ALPHA_RUNTIME/bin/python3" \
  -c 'import numpy, PIL; print(numpy.__version__, PIL.__version__)'
```

The app discovers that `alpha-runtime` automatically. You can instead use
**Settings → Animations → Setup Guide → Choose Python…** to select another
Python executable that can import NumPy and Pillow.

Developers may configure these environment variables before launching the app:

- `CODEX_PET_ALPHA_PYTHON`
- `CODEX_PET_FFMPEG`
- `CODEX_PET_FFPROBE`
- `CODEX_PET_AVCONVERT`

Return to **Animations** and choose **Check Again** after changing tools.

## Upgrade

Pull or unpack the newer source, then rebuild and rerun the installer:

```bash
bash mac/CodexPetMac/scripts/build_app.sh
bash mac/CodexPetMac/scripts/install.sh
```

Do not uninstall first. A managed upgrade preserves media, the media map, and
the current start-at-login choice.

The public name is Statelet, while compatibility identifiers remain unchanged:

| Field | Value |
| --- | --- |
| Installed app | `~/Applications/Statelet.app` |
| Bundle identifier | `com.coke1120.CodexPetMac` |
| Executable and `CFBundleName` | `CodexPetMac` |
| Managed marker | `mac-widget-v1` |

## Installed files

```text
~/Applications/Statelet.app
~/Library/Application Support/CodexPet/media/media-map.json
~/Library/Application Support/CodexPet/runtime/current_state.json
~/Library/Application Support/CodexPet/sessions/
~/Library/Application Support/CodexPet/logs/
~/Library/Application Support/CodexPet/mac-widget/
~/Library/LaunchAgents/com.coke1120.codex-pet.state-aggregator.plist
~/Library/LaunchAgents/com.coke1120.codex-pet.mac-player.plist
~/.codex/hooks.json
```

Statelet does not install animation media. Imported media stays under the
current account's Application Support directory.

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
- aggregate state and per-session records; and
- local logs.

This preservation makes reinstall and recovery possible. If you want to remove
the retained data, open Finder, choose **Go → Go to Folder…**, enter
`~/Library/Application Support/CodexPet`, inspect its contents, and move the
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
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  tests.test_codex_hook \
  tests.test_codex_pet_state \
  tests.test_macos_pet_packaging \
  tests.test_macos_pet_startup -v

swift run -c release --package-path mac/CodexPetMac codex-pet-core-self-test
swift test -c release --package-path mac/CodexPetMac
bash mac/CodexPetMac/scripts/build_app.sh
codesign --verify --deep --strict mac/CodexPetMac/dist/Statelet.app
python3 -m json.tool mac/CodexPetMac/Examples/media-map.json >/dev/null
git diff --check
```

After preparing the alpha toolchain, also run:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.test_macos_alpha_video -v
```

Full `swift test` requires Xcode with XCTest. Command Line Tools alone can build
the app and run `codex-pet-core-self-test`, but may not provide XCTest.
