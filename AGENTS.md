# AGENTS.md

Operational and architectural reference for AI coding assistants working on Statelet (`statelet-codex-pet-macos`).

---

## 1. Project Overview

Statelet is a native, local-first macOS companion for Codex and Grok Build. It translates agent lifecycle events (**Idle**, **Running**, **Waiting**, and **Review**) into an animated, transparent desktop presence using **AppKit** and **AVFoundation**, without requiring a web runtime or external hardware.

### Canonical Identity
- **Application Bundle**: `Statelet.app`
- **Bundle Identifier**: `com.coke1120.Statelet`
- **Swift Target / Executable**: `Statelet`
- **Application Support Directory**: `~/Library/Application Support/Statelet`
- **LaunchAgents**: `com.coke1120.statelet.state-aggregator`, `com.coke1120.statelet.mac-player`
- **Managed Marker**: `statelet-v2`
- **Legacy Identity Policy**: Legacy `CodexPet` identifiers are strictly restricted to migration, backward-compatible import, rollback, and uninstallation routines. Do not introduce legacy identifiers into fresh installation or feature code.

---

## 2. System Architecture & Data Flow

```text
Codex lifecycle hooks (~/.codex/hooks.json) + Grok Build hooks (~/.grok/hooks/statelet.json)
  │
  ▼
mac/codex_pet_hook.py (stdin -> privacy-safe JSON)
  │
  ▼
~/Library/Application Support/Statelet/sessions/<provider-hashed-session>.json
  │
  ▼
mac/codex_pet_state_aggregator.py (kqueue directory watcher with 250 ms poll fallback)
  │  Multi-session aggregation: waiting > review > running > idle
  ▼
~/Library/Application Support/Statelet/runtime/current_state.json
  │  Sidecars: sessions/activity-v1.json + sessions/activity-targets-v1.json
  ▼
Statelet AppKit Panel (PetAppDelegate / PetPlayer)
  │  AVQueuePlayer + AVPlayerLooper (single active decoder, layered transitions)
  ▼
AVFoundation Desktop Playback & Menu Bar Controls
```

### Core Components
1. **Hook Handlers (`mac/codex_pet_hook.py`)**:
   - Intercepts lifecycle events on stdin from Codex and Grok Build.
   - Maps events to canonical states:
     - `SessionStart`, `SessionEnd`, `Stop`, `idle_prompt` → `Idle`
     - `UserPromptSubmit`, ordinary tool activity → `Running`
     - `PermissionRequest`, `permission_prompt`, `ask_user_question` → `Waiting`
     - `PreCompact`, `PostCompact`, test/lint/review tool usage → `Review`
   - Strips prompt text, tool output, transcript paths, and working directories. Writes only bounded timestamps, provider, mapped state, and session hashes to per-session JSON.
2. **State Aggregator (`mac/codex_pet_state_aggregator.py`)**:
   - Watches `sessions/` directory using macOS `kqueue` kernel events with 250 ms polling fallback.
   - Enforces state priority: `waiting > review > running > idle`.
   - Enforces 900-second session TTL (with 30-second grace period for `PostToolUse`).
   - Publishes atomic `current_state.json` with monotonic revision counter and 60-second liveness heartbeats.
3. **Swift Core Library (`mac/CodexPetMac/Sources/CodexPetCore`)**:
   - Houses contracts, data models, and pure logic:
     - `Contracts.swift`: Schema definitions for lifecycle states, media maps, and session activities.
     - `MediaPlaylist.swift`: Character animation selection policies (`Fixed`, `Random`, `Sequential`) and clip-end rotation.
     - `CharacterLibrary.swift` & `CharacterBundleManifest.swift`: Multi-character profile catalog and packaging.
     - `GlobalTransitionLibrary.swift` & `LayeredLifecycleHandoff.swift`: State transition route definitions and multi-phase pre-roll compositing.
     - `AlphaConversionReport.swift`: Strict schema verification for conversion reports.
     - `DialogueVoice.swift`: Data contracts for dialogue items and speech profile configurations.
     - `ManagedMediaRemoval.swift`: Fail-closed media removal utilizing macOS Trash.
4. **macOS Application (`mac/CodexPetMac/Sources/CodexPetMac`)**:
   - `PetAppDelegate.swift`: Application lifecycle, menu bar orbit accessory, settings window, and notification wiring.
   - `PetPanel.swift`: Borderless, transparent, resizable floating AppKit window.
   - `PetPlayer.swift`: AVFoundation-backed playback engine managing `AVQueuePlayer`, `AVPlayerLooper`, occlusion suspension, and transition compositing.
   - `CodexAppServerTitleResolver.swift`: Ephemeral in-memory resolution of Codex thread titles via local App Server (`thread/read` with `includeTurns: false`). Process verified against OpenAI Developer ID Team ID; titles are never persisted to disk.
   - `DialogueVoiceRuntime.swift` & `DialogueVoiceCoordinator.swift`: Private speech generation runtime managing offline GPT-SoVITS, Qwen3-TTS, and VoxCPM2 providers.
   - `StateletUpdater.swift`: Owner-authorized updates verifying Ed25519 signatures against GitHub release manifests.
5. **Media Authoring Pipeline (`tools/`)**:
   - `codex_pet_alpha.py` & `convert_codex_pet_macos_alpha.py`: Converts `#00FF00` green-screen MP4s into HEVC-with-alpha MOVs with reproducible `.report.json` verification sidecars.

---

## 3. Directory Layout

```text
statelet-codex-pet-macos/
├── .agents/
│   └── skills/                       # Bundled agent skills
│       ├── author-statelet-animation # Media conversion, alpha validation, playback checks
│       ├── craft-video-generation-prompts # Video prompt engineering
│       └── operate-statelet-local-voice   # Local TTS setup, import, and verification
├── .github/
│   └── workflows/
│       ├── ci.yml                    # Main CI pipeline (Python, Swift, codesign, media checks)
│       └── release.yml               # Pinned-key signed release packaging
├── docs/                             # Project documentation
│   ├── DEPLOYMENT.md                 # Install, upgrade, autostart, and uninstallation guide
│   ├── MACOS_COMPANION.md            # Lifecycle, heartbeat, and filesystem contracts
│   ├── PERFORMANCE.md                # CPU, RSS, and latency benchmark harness
│   └── USAGE.md                      # Complete user guide for settings, voice, and media
├── mac/
│   ├── codex_pet_hook.py             # Event hook handler (Python stdlib)
│   ├── codex_pet_state.py            # State normalization and parsing
│   ├── codex_pet_state_aggregator.py # Multi-session aggregator (kqueue)
│   ├── requirements-alpha.txt        # Hash-pinned dependencies for alpha conversion
│   └── CodexPetMac/                  # SwiftPM package & native app sources
│       ├── Package.swift             # Package manifest (Swift 5.9+, macOS 13+)
│       ├── Sources/
│       │   ├── CodexPetCore/         # Shared models, contracts, and business logic
│       │   ├── CodexPetCoreSelfTest/ # Lightweight self-test executable
│       │   └── CodexPetMac/          # AppKit UI, AVFoundation player, settings, voice
│       ├── Tests/
│       │   ├── CodexPetCoreTests/    # Core unit tests
│       │   └── CodexPetMacTests/     # AppKit and player playback integration tests
│       └── scripts/
│           ├── build_app.sh          # App assembler and ad-hoc code signer
│           ├── install.sh            # User-level installer and hook merger
│           ├── measure_runtime.py    # Runtime CPU, RSS, and latency harness
│           ├── merge_hooks.py        # Safe additive hook configuration merger
│           └── uninstall.sh          # Safe uninstaller (preserves user data)
├── tests/                            # Comprehensive Python unit test suite
└── tools/                            # MP4-to-HEVC-alpha conversion toolchain
```

---

## 4. Development & Verification Commands

### Prerequisites
- macOS 13 (Ventura) or newer
- Xcode Command Line Tools (`swift --version` >= 5.9)
- Python 3.9+ with hash-locked alpha dependencies (for authoring/tests)
- `ffmpeg`, `ffprobe`, and `/usr/bin/avconvert` (for media tests)

### Setup Virtual Environment
```bash
python3.9 -m venv .venv
source .venv/bin/activate
pip install --require-hashes -r mac/requirements-alpha.txt
```

### Complete Test & Verification Suite
Run these verification commands before opening a pull request:

1. **Python Test Suite (Zero Skips Permitted in CI)**:
   ```bash
   PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'
   import unittest
   suite = unittest.defaultTestLoader.discover("tests", pattern="test_*.py")
   result = unittest.TextTestRunner(verbosity=2).run(suite)
   if result.skipped:
       raise SystemExit(f"Python tests skipped: {result.skipped}")
   raise SystemExit(0 if result.wasSuccessful() else 1)
   PY
   ```

2. **Swift Core Self-Test**:
   ```bash
   swift run --package-path mac/CodexPetMac -c release codex-pet-core-self-test
   ```

3. **Swift Unit Tests**:
   ```bash
   swift test -c release --package-path mac/CodexPetMac --skip PetPlayerPlaybackIntegrationTests
   ```

4. **AVPlayer Playback Integration Suite**:
   ```bash
   STATELET_RUN_AVPLAYER_INTEGRATION=1 swift test -c release --package-path mac/CodexPetMac --filter PetPlayerPlaybackIntegrationTests
   ```

5. **Build & Code Sign Application**:
   ```bash
   bash mac/CodexPetMac/scripts/build_app.sh
   codesign --verify --deep --strict mac/CodexPetMac/dist/Statelet.app
   ```

6. **Verify No Forbidden Media / Binaries Tracked**:
   ```bash
   if git ls-files | grep -Ei '^(private-assets|private-media|prompts|esp32-p4|vendor)/|\.(mp4|mov|m4v|webm|mkv|avi|gif|hevc|prores[^/]*|safetensors|ckpt|pth|wav|flac|mp3|m4a|aac|ogg)$'; then
     echo "Excluded private, hardware, or media content is tracked." >&2
     exit 1
   fi
   ```

7. **Example Media Map Schema Validation**:
   ```bash
   python3 -m json.tool mac/CodexPetMac/Examples/media-map.json >/dev/null
   ```

8. **Runtime Performance Harness (Local Observation)**:
   ```bash
   python3 mac/CodexPetMac/scripts/measure_runtime.py \
     --executable "$(pwd)/mac/CodexPetMac/.build/release/statelet" \
     --media-map "$HOME/Library/Application Support/Statelet/media/media-map.json" \
     --duration 60 \
     --interval 1 \
     --transition-interval 8
   ```

---

## 5. Security, Privacy & Architectural Invariants

Agents modifying Statelet must strictly adhere to the following non-negotiable invariants:

### 1. Privacy & Zero-Telemetry Boundary
- Statelet contains **no telemetry, no analytics, and no remote crash reporting**.
- **Never make external network calls** from the app or aggregator. The sole network exception is local voice generation via loopback HTTPS (`https://127.0.0.1:<port>`) with pinned leaf TLS certificates.
- **Never log, persist, or expose sensitive user data**: Prompt text, tool input/output, file paths, repository URLs, transcript contents, account credentials, and voice dialogue lines must never be written to logs, diagnostics, or shared state files.
- The `Copy Diagnostics` action in Settings must output strictly sanitized counts and categories, never raw paths or session IDs.

### 2. Repository Asset Boundaries
- **No media or weights in git**: Never commit animation media (`.mp4`, `.mov`, `.gif`), audio recordings (`.wav`, `.mp3`), or model weights (`.safetensors`, `.ckpt`, `.pth`) to this repository.
- Animation media and voice weights are strictly user-supplied local assets stored in `~/Library/Application Support/Statelet/`.

### 3. Fail-Closed Verification & Data Integrity
- **Alpha Video Conversion**: Candidate MOV deliveries must strictly pass all verification gates: Apple round-trip checks via `avconvert`, non-zero alpha retention, composite bounds check, and hash matching in `.report.json`.
- **Character Bundles**: Imported `.statelet-character` bundles must match manifest file hashes and pass AVFoundation playback verification before acceptance.
- **Media Removal**: Deletion is fail-closed; eligible files must be safely moved to macOS Trash rather than irreversibly unlinked.
- **Ephemeral Task Titles**: Thread title resolution via Codex App Server is fail-soft and kept exclusively in memory. If Codex or the title is unavailable, Statelet falls back gracefully to generic lifecycle labels.

### 4. Non-Disruptive Hook Execution
- Hook handlers must execute quickly and exit with code 0.
- A failure writing display state must **never** break, block, or delay an active agent turn in Codex or Grok Build.

---

## 6. Agent Skills Reference

Specialized skills are maintained under [`.agents/skills/`](file:///Users/leoho/Documents/Github/statelet-codex-pet-macos/.agents/skills):

| Skill Name | Location | Intended Purpose |
| --- | --- | --- |
| `author-statelet-animation` | [`.agents/skills/author-statelet-animation/SKILL.md`](file:///Users/leoho/Documents/Github/statelet-codex-pet-macos/.agents/skills/author-statelet-animation/SKILL.md) | Authoring, converting (`#00FF00` green-screen MP4 to HEVC-with-alpha MOV), validating conversion reports, importing verified media, and diagnosing frozen frame playback. |
| `craft-video-generation-prompts` | [`.agents/skills/craft-video-generation-prompts/SKILL.md`](file:///Users/leoho/Documents/Github/statelet-codex-pet-macos/.agents/skills/craft-video-generation-prompts/SKILL.md) | Formulating, refining, and validating video-generation prompts (e.g. Gemini, Veo) with motion constraints, seamless loop instructions, and chroma backgrounds. |
| `operate-statelet-local-voice` | [`.agents/skills/operate-statelet-local-voice/SKILL.md`](file:///Users/leoho/Documents/Github/statelet-codex-pet-macos/.agents/skills/operate-statelet-local-voice/SKILL.md) | Configuring, migrating, synthesizing, and validating local GPT-SoVITS, Qwen3-TTS (MLX), or VoxCPM2 voice models without leaking private weights or recordings. |

Before performing tasks related to media authoring, prompt engineering, or voice models, consult the corresponding skill documentation.

---

## 7. Development Guidelines for Agents

- **Documentation Integrity**: Preserve existing comments and docstrings. Do not strip or alter copyright notices, headers, or existing explanations.
- **Codebase Memory Graph**: When `codebase-memory-mcp` is active, prefer MCP tools (`search_graph`, `trace_path`, `get_code_snippet`) for navigating Swift and Python symbols. When MCP is inactive or unavailable, fall back cleanly to file inspection and ripgrep.
- **Clickable Symbol & File Links**: In agent responses, always format files and code symbols as clickable Markdown links with `file://` URIs (e.g., [`PetPlayer.swift`](file:///Users/leoho/Documents/Github/statelet-codex-pet-macos/mac/CodexPetMac/Sources/CodexPetMac/PetPlayer.swift) or [`MediaPlaylist`](file:///Users/leoho/Documents/Github/statelet-codex-pet-macos/mac/CodexPetMac/Sources/CodexPetCore/MediaPlaylist.swift)).
