#!/usr/bin/env python3
"""Source-level regression contracts for Statelet dialogue voice support."""

from __future__ import annotations

import re
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MAC_SOURCES = ROOT / "mac" / "CodexPetMac" / "Sources" / "CodexPetMac"
CORE_SOURCES = ROOT / "mac" / "CodexPetMac" / "Sources" / "CodexPetCore"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def method_body(source: str, declaration: str) -> str:
    """Return one four-space-indented Swift method without parsing closure braces."""
    start = source.find(declaration)
    if start < 0:
        raise AssertionError(f"Swift declaration was not found: {declaration}")
    next_method = re.search(
        r"\n    (?:private\s+)?(?:static\s+)?func\s+",
        source[start + len(declaration) :],
    )
    end = (
        start + len(declaration) + next_method.start()
        if next_method is not None
        else len(source)
    )
    return source[start:end]


class MacDialogueVoiceSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.settings = read(MAC_SOURCES / "SettingsWindowController.swift")
        cls.voice_view = read(MAC_SOURCES / "DialogueVoiceSettingsView.swift")
        cls.coordinator = read(MAC_SOURCES / "DialogueVoiceCoordinator.swift")
        cls.runtime = read(MAC_SOURCES / "DialogueVoiceRuntime.swift")
        cls.app_delegate = read(MAC_SOURCES / "PetAppDelegate.swift")
        cls.core = read(CORE_SOURCES / "DialogueVoice.swift")
        cls.identity = read(MAC_SOURCES / "StateletIdentity.swift")
        cls.diagnostics = read(MAC_SOURCES / "PetDiagnostics.swift")
        cls.build_script = read(ROOT / "mac" / "CodexPetMac" / "scripts" / "build_app.sh")

    def test_voice_is_the_seventh_accessible_settings_pane(self) -> None:
        tab_match = re.search(
            r"NSSegmentedControl\(labels:\s*\[(?P<labels>[^]]+)\]",
            self.settings,
        )
        self.assertIsNotNone(tab_match, "Settings tab labels were not found")
        labels = re.findall(r'"([^"]+)"', tab_match.group("labels"))
        self.assertEqual(len(labels), 7)
        self.assertEqual(labels[1], "Voice")
        self.assertIn("dialogueVoiceView.isHidden = tabs.selectedSegment != 1", self.settings)

        required_accessibility_labels = {
            "GPT-SoVITS API base URL",
            "Import GPT weight",
            "Import SoVITS weight",
            "Import reference audio",
            "Dialogue lines",
            "Dialogue text",
            "Add dialogue line",
            "Preview selected dialogue line",
        }
        for label in required_accessibility_labels:
            self.assertIn(f'"{label}"', self.voice_view)
        self.assertIn("button.setAccessibilityLabel(label)", self.voice_view)
        self.assertIn("field.setAccessibilityLabel(label)", self.voice_view)
        self.assertIn('linesTable.setAccessibilityLabel("Dialogue lines")', self.voice_view)
        self.assertIn('dialogueTextView.setAccessibilityLabel("Dialogue text")', self.voice_view)
        self.assertIn("setAccessibilityHelp", self.voice_view)

    def test_gpt_sovits_and_reference_audio_are_separate_typed_imports(self) -> None:
        self.assertRegex(
            self.runtime,
            r"case\s+gptWeight\s*=\s*\"gpt\"[\s\S]*?return\s*\[\"ckpt\"\]",
        )
        self.assertRegex(
            self.runtime,
            r"case\s+sovitsWeight\s*=\s*\"sovits\"[\s\S]*?return\s*\[\"pth\"\]",
        )
        self.assertRegex(
            self.runtime,
            r"case\s+referenceAudio\s*=\s*\"reference\"[\s\S]*?return\s*\[[^]]*\"wav\"",
        )
        for callback in (
            "onImportGPTWeight",
            "onImportSoVITSWeight",
            "onImportReferenceAudio",
        ):
            self.assertIn(callback, self.voice_view)
        for kind in (".gptWeight", ".sovitsWeight", ".referenceAudio"):
            self.assertIn(f"onImportVoiceAsset?({kind}, draft)", self.settings)

    def test_http_adapter_is_loopback_only_and_refuses_redirects(self) -> None:
        endpoint_policy = re.search(
            r"public enum DialogueVoiceEndpointPolicy[\s\S]*?\n\}",
            self.core,
        )
        self.assertIsNotNone(endpoint_policy, "Shared endpoint policy was not found")
        policy = endpoint_policy.group(0)
        self.assertIn('components.scheme?.lowercased() == "http"', policy)
        self.assertIn('octets.first == "127"', policy)
        self.assertIn('host == "::1"', policy)
        self.assertNotIn('host == "localhost"', policy)
        self.assertIn("DialogueVoiceEndpointPolicy.validatedLoopbackURL(url)", self.runtime)
        self.assertIn("configuration.connectionProxyDictionary = [:]", self.runtime)
        self.assertIn("DialogueVoiceBoundedRequest", self.runtime)
        redirect_method = re.search(
            r"willPerformHTTPRedirection[\s\S]*?completionHandler\((?P<decision>[^)]+)\)",
            self.runtime,
        )
        self.assertIsNotNone(redirect_method, "Redirect policy was not found")
        self.assertEqual(redirect_method.group("decision").strip(), "nil")

    def test_adapter_uses_api_v2_endpoints_and_exact_tts_snake_case_keys(self) -> None:
        for endpoint in ("set_gpt_weights", "set_sovits_weights", "tts"):
            self.assertIn(f'"{endpoint}"', self.runtime)
        self.assertIn('queryName: "weights_path"', self.runtime)

        coding_keys = re.search(
            r"private struct TTSBody:[\s\S]*?enum CodingKeys:[\s\S]*?\{(?P<body>[\s\S]*?)\n\s*\}",
            self.runtime,
        )
        self.assertIsNotNone(coding_keys, "TTS request coding keys were not found")
        body = coding_keys.group("body")
        explicit_keys = dict(
            re.findall(r"case\s+(\w+)\s*=\s*\"([^\"]+)\"", body)
        )
        self.assertEqual(
            explicit_keys,
            {
                "textLanguage": "text_lang",
                "referenceAudioPath": "ref_audio_path",
                "promptText": "prompt_text",
                "promptLanguage": "prompt_lang",
                "mediaType": "media_type",
                "streamingMode": "streaming_mode",
            },
        )
        self.assertRegex(body, r"\bcase\s+text\b")
        self.assertIn('request.httpMethod = "POST"', self.runtime)
        self.assertIn('request.setValue("application/json", forHTTPHeaderField: "Content-Type")', self.runtime)

    def test_add_and_edit_persist_before_asynchronous_pre_generation(self) -> None:
        for method_name, mutation in (
            ("addLine", "$0.addLine"),
            ("updateLine", "$0.editLine"),
        ):
            body = method_body(self.coordinator, f"    func {method_name}")
            self.assertIn("try commit", body)
            self.assertLess(body.index(mutation), body.index("processNextQueuedLine()"))

        commit = method_body(self.coordinator, "    private func commit")
        self.assertLess(commit.index("mutation(&updated)"), commit.index("store.save(updated)"))
        self.assertLess(commit.index("store.save(updated)"), commit.index("library = updated"))

        self.assertIn("Task.detached(priority: .userInitiated)", self.coordinator)
        self.assertIn("let ticket = try commit { try $0.beginGeneration", self.coordinator)
        self.assertIn("completeGeneration(ticket: ticket", self.coordinator)
        self.assertIn("failGeneration(ticket: ticket", self.coordinator)
        self.assertIn("deferCleanup(paths: [outputPath])", self.coordinator)
        self.assertIn("event=generation_result_discarded code=STALE_RESULT", self.coordinator)

    def test_preview_is_ready_only_and_never_calls_synthesis(self) -> None:
        body = method_body(self.coordinator, "    func previewLine")
        self.assertIn("playReadyLine(id: id) == .played", body)
        self.assertNotIn("synthesize", body)
        self.assertNotIn("processNextQueuedLine", body)

        playback = method_body(self.runtime, "    func playReadyLine")
        self.assertIn("line.status == .ready", playback)
        self.assertIn("player.play", playback)
        self.assertIn(".unavailable(.missingOrInvalidAudio)", playback)

        preview_action = method_body(self.voice_view, "    @objc private func previewLine()")
        self.assertIn("line.status == .ready", preview_action)
        self.assertIn("previewButton.isEnabled = line?.status == .ready", self.voice_view)
        self.assertIn("profileStatus == .ready || profileStatus == .unavailable", self.voice_view)

    def test_background_refresh_preserves_dirty_settings_editors(self) -> None:
        update = method_body(self.voice_view, "    func update")
        self.assertIn("let preserveProfileEdits = profileEditorIsDirty", update)
        self.assertIn("let preserveDialogueEdits = dialogueEditorIsDirty", update)
        self.assertIn("if !preserveProfileEdits", update)
        self.assertIn("if !preserveDialogueEdits || editorContentChanged", update)
        self.assertIn("lastAppliedProfileDraft", self.voice_view)
        self.assertIn("lastAppliedEditorLine", self.voice_view)

    def test_profile_state_fingerprint_and_secure_cleanup_are_persisted(self) -> None:
        for status in ("notConfigured", "validating", "ready", "invalid", "unavailable"):
            self.assertRegex(self.core, rf"\bcase\s+{status}\b")
        self.assertIn('case inputFingerprint = "input_fingerprint"', self.core)
        self.assertIn('case profileStatus = "profile_status"', self.core)
        self.assertIn("DialogueVoiceProfileFingerprint.validateAssets", self.coordinator)
        self.assertIn("profile.inputFingerprint", self.coordinator)
        self.assertIn("Darwin.openat", self.runtime)
        self.assertIn("O_DIRECTORY | O_NOFOLLOW", self.runtime)
        self.assertIn("Darwin.unlinkat(parent.descriptor", self.runtime)
        self.assertIn('case pendingCleanupPaths = "pending_cleanup_paths"', self.core)
        self.assertIn("retryPendingCleanup()", self.coordinator)
        self.assertIn("public var referencedManagedPaths", self.core)
        self.assertIn("Set(validatedCleanupPaths).isDisjoint", self.core)
        self.assertIn("Set(validated).isDisjoint(with: referencedManagedPaths)", self.core)

        retry_cleanup = method_body(
            self.coordinator,
            "    private func retryPendingCleanup",
        )
        self.assertIn("library.referencedManagedPaths", retry_cleanup)
        self.assertIn("guard !library.referencedManagedPaths.contains(path)", retry_cleanup)
        self.assertLess(
            retry_cleanup.index("guard !library.referencedManagedPaths.contains(path)"),
            retry_cleanup.index("removeManagedFile"),
        )
        self.assertIn("metadataPersistenceFailed", self.coordinator)
        self.assertIn("outcome.remainingCount == 0", self.coordinator)
        late_import = method_body(self.coordinator, "    func importAsset")
        self.assertIn("if cleanup.requiresNotice", late_import)
        self.assertIn("self.notify()", late_import)
        self.assertIn("acceptImportedAsset(kind: kind, asset: asset)", late_import)

        accept_import = method_body(
            self.coordinator,
            "    private func acceptImportedAsset",
        )
        self.assertIn("updated.enqueueCleanup(paths: [asset.relativePath])", accept_import)
        self.assertLess(
            accept_import.index("store.save(updated)"),
            accept_import.index("importedAssets.gptWeightRelativePath = asset.relativePath"),
        )
        self.assertIn("retryPendingCleanup(preserving: stagedImportedPaths)", accept_import)

        shutdown = method_body(self.coordinator, "    func shutdown")
        self.assertIn("retryPendingCleanup(preserving: [])", shutdown)

        remove_profile = method_body(self.coordinator, "    func removeProfile")
        self.assertIn("retryPendingCleanup(preserving: [])", remove_profile)

        retry_cleanup = method_body(
            self.coordinator,
            "    private func retryPendingCleanup",
        )
        self.assertIn("preservedPaths ?? stagedImportedPaths", retry_cleanup)

        save_profile = method_body(self.coordinator, "    func saveProfile")
        self.assertLess(
            save_profile.index("replacePendingCleanupPaths"),
            save_profile.index("replaceActiveProfile(profile)"),
        )
        self.assertIn("Replace the active voice profile?", self.app_delegate)
        self.assertIn(
            "Saving this profile invalidates all generated dialogue audio.",
            self.app_delegate,
        )

        coordinator_tests = read(
            ROOT
            / "mac"
            / "CodexPetMac"
            / "Tests"
            / "CodexPetMacTests"
            / "DialogueVoiceRuntimeTests.swift"
        )
        self.assertIn(
            "testCoordinatorRestoresQueuedLineGeneratesPublishesAndPlaysReadyAudio",
            coordinator_tests,
        )
        self.assertIn(
            "testCoordinatorStartupCleansPersistedStagedImportFromPriorRun",
            coordinator_tests,
        )

    def test_adapter_reactivates_each_job_and_streams_bounded_responses(self) -> None:
        synthesize = method_body(self.runtime, "    func synthesize")
        self.assertIn("try await activateProfile", synthesize)
        activation = method_body(self.runtime, "    private func activateProfile")
        self.assertIn('endpoint: "set_gpt_weights"', activation)
        self.assertIn('endpoint: "set_sovits_weights"', activation)
        self.assertNotIn("activeProfile", self.runtime)
        self.assertIn("didReceive chunk: Data", self.runtime)
        self.assertIn("chunk.count <= maximumBytes - data.count", self.runtime)
        self.assertIn("DialogueVoiceRuntimeError.responseTooLarge", self.runtime)
        self.assertIn("func validateProfile", self.runtime)
        self.assertIn("validateReferenceAudio", self.runtime)
        self.assertIn("inputFingerprintMismatch", self.runtime)
        self.assertIn("case profileRejected", self.runtime)
        self.assertIn("case requestRejected", self.runtime)

    def test_voice_data_is_private_local_state_not_release_or_diagnostic_payload(self) -> None:
        self.assertIn(
            'applicationSupportRelativePath = "Library/Application Support/CodexPet"',
            self.identity,
        )
        self.assertIn('appendingPathComponent("voice", isDirectory: true)', self.coordinator)
        self.assertIn("voice/assets/", self.runtime)
        self.assertIn("voice/generated/", self.runtime)
        self.assertIn("[.posixPermissions: 0o700]", self.runtime)
        self.assertIn("mode_t(S_IRUSR | S_IWUSR)", self.runtime)

        tracked = subprocess.run(
            ["git", "ls-files"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.splitlines()
        private_extensions = {".ckpt", ".pth", ".wav", ".flac", ".mp3", ".m4a", ".aac", ".ogg"}
        leaked = [path for path in tracked if Path(path).suffix.lower() in private_extensions]
        self.assertEqual(leaked, [], f"Tracked voice assets must not ship: {leaked}")
        for extension in ("*.ckpt", "*.pth", "*.wav"):
            self.assertNotIn(extension, self.build_script)

        self.assertNotRegex(self.diagnostics, r"Dialogue(Line|Voice)|referenceText|gptWeight|sovitsWeight")
        log_calls = "\n".join(
            re.findall(r"logger\.(?:info|error|warning|debug)\([^\n]+", self.coordinator)
        )
        for sensitive_expression in (
            "sourceURL",
            "relativePath",
            "line.text",
            "draft.",
            "referenceText",
            "gptWeightRelativePath",
            "sovitsWeightRelativePath",
            "referenceAudioRelativePath",
        ):
            self.assertNotIn(sensitive_expression, log_calls)

    def test_statelet_compatibility_identifiers_remain_unchanged(self) -> None:
        expected = {
            "appBundleName": "Statelet.app",
            "executableName": "CodexPetMac",
            "bundleIdentifier": "com.coke1120.CodexPetMac",
            "applicationSupportRelativePath": "Library/Application Support/CodexPet",
            "playerLaunchAgentLabel": "com.coke1120.codex-pet.mac-player",
            "aggregatorLaunchAgentLabel": "com.coke1120.codex-pet.state-aggregator",
            "appManagedPlistKey": "CodexPetManaged",
            "launchAgentManagedPlistKey": "CodexPetMacManaged",
            "managedMarker": "mac-widget-v1",
        }
        actual = dict(
            re.findall(r'static let\s+(\w+)\s*=\s*"([^"]+)"', self.identity)
        )
        for key, value in expected.items():
            self.assertEqual(actual.get(key), value, key)


if __name__ == "__main__":
    unittest.main()
