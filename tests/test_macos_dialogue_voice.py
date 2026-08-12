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
            "Owning lifecycle state",
            "Add dialogue line",
            "Preview selected dialogue line",
        }
        for label in required_accessibility_labels:
            self.assertIn(f'"{label}"', self.voice_view)
        self.assertIn("button.setAccessibilityLabel(label)", self.voice_view)
        self.assertIn("field.setAccessibilityLabel(label)", self.voice_view)
        self.assertIn('linesTable.setAccessibilityLabel("Dialogue lines")', self.voice_view)
        self.assertIn('dialogueTextView.setAccessibilityLabel("Dialogue text")', self.voice_view)
        self.assertIn('dialogueStatePopup.setAccessibilityLabel("Owning lifecycle state")', self.voice_view)
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
                "textSplitMethod": "text_split_method",
                "batchSize": "batch_size",
                "splitBucket": "split_bucket",
                "fragmentInterval": "fragment_interval",
                "parallelInfer": "parallel_infer",
                "repetitionPenalty": "repetition_penalty",
                "topK": "top_k",
                "topP": "top_p",
            },
        )
        self.assertRegex(body, r"\bcase\s+text\b")
        self.assertRegex(body, r"\bcase\s+seed\b")
        self.assertIn('request.httpMethod = "POST"', self.runtime)
        self.assertIn('request.setValue("application/json", forHTTPHeaderField: "Content-Type")', self.runtime)
        for declaration in (
            'let textSplitMethod = "cut0"',
            "let batchSize = 1",
            "let parallelInfer = false",
            "let splitBucket = false",
            "let fragmentInterval = 0.0",
            "let topK = 5",
            "let topP = 0.8",
            "let temperature = 0.6",
            "let repetitionPenalty = 1.35",
            "seed: Int = 24_681",
        ):
            self.assertIn(declaration, self.runtime)

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

    def test_retry_accepts_failed_and_stale_lines_when_profile_allows_it(self) -> None:
        enablement = method_body(self.voice_view, "    private func refreshButtonEnablement")
        self.assertIn(
            "retryButton.isEnabled = (line?.status == .failed || line?.status == .stale)",
            enablement,
        )
        self.assertIn(
            "profileStatus == .ready || profileStatus == .unavailable",
            enablement,
        )

        retry_action = method_body(self.voice_view, "    @objc private func retryLine()")
        self.assertIn("line.status == .failed || line.status == .stale", retry_action)
        self.assertIn("onRetryLine?(line)", retry_action)

    def test_unavailable_stale_retry_uses_profile_activation_without_retrying_queued_state(self) -> None:
        retry = method_body(self.coordinator, "    func retryLine")
        self.assertIn("let selectedWasStale", retry)
        self.assertIn("$0.activateValidatedProfile()", retry)
        self.assertIn("if selectedWasStale", retry)
        self.assertIn("activatedLine.status == .queued", retry)
        self.assertIn("line = try $0.retryLine(id: id)", retry)
        self.assertLess(
            retry.index("$0.activateValidatedProfile()"),
            retry.index("if selectedWasStale"),
        )
        self.assertIn("previousOutputPaths.subtracting(retainedOutputPaths).sorted()", retry)

    def test_background_refresh_preserves_dirty_settings_editors(self) -> None:
        update = method_body(self.voice_view, "    func update")
        self.assertIn("let preserveProfileEdits = profileEditorIsDirty", update)
        self.assertIn("let preserveDialogueEdits = dialogueEditorIsDirty", update)
        self.assertIn("let preserveNewDialogueText = newDialogueTextIsDirty", update)
        self.assertIn("let preserveNewDialogueState = newDialogueStateIsDirty", update)
        self.assertIn("let preserveNewDialogueLanguage = newDialogueLanguageIsDirty", update)
        self.assertIn("if !preserveProfileEdits", update)
        self.assertIn("if !preserveDialogueEdits || editorContentChanged", update)
        self.assertIn("!preserveNewDialogueText && !preserveNewDialogueState && !preserveNewDialogueLanguage", update)
        self.assertIn("if !preserveNewDialogueState", update)
        self.assertIn("if !preserveNewDialogueLanguage", update)
        self.assertIn("lastAppliedProfileDraft", self.voice_view)
        self.assertIn("lastAppliedEditorLine", self.voice_view)

    def test_dialogue_page_exposes_accessible_voice_playback_controls(self) -> None:
        self.assertIn('checkboxWithTitle: "Automatic playback"', self.voice_view)
        self.assertIn("NSSlider(value: 100, minValue: 0, maxValue: 100", self.voice_view)
        self.assertIn('fieldLabel("Voice volume")', self.voice_view)
        self.assertIn('fieldLabel("Repeat interval")', self.voice_view)
        self.assertIn(
            '"Never", "15s", "30s", "60s", "120s", "300s", "600s"',
            self.voice_view,
        )
        self.assertIn(
            "private let repeatIntervalValues: [TimeInterval?] = [nil, 15, 30, 60, 120, 300, 600]",
            self.voice_view,
        )
        for label in (
            "Automatic voice playback",
            "Voice volume",
            "Voice volume value",
            "Automatic voice repeat interval",
        ):
            self.assertIn(f'AccessibilityLabel("{label}")', self.voice_view)
        self.assertIn("voiceVolumeSlider.setAccessibilityValue", self.voice_view)

    def test_playback_snapshot_refresh_is_silent_and_preserves_dialogue_drafts(self) -> None:
        update = method_body(self.voice_view, "    func update")
        self.assertIn("let preserveProfileEdits = profileEditorIsDirty", update)
        self.assertIn("let preserveNewDialogueText = newDialogueTextIsDirty", update)
        self.assertIn("isRefreshing = true", update)
        self.assertIn("applyPlaybackSettings(library.playbackSettings)", update)
        self.assertLess(
            update.index("isRefreshing = true"),
            update.index("applyPlaybackSettings(library.playbackSettings)"),
        )
        apply_settings = method_body(
            self.voice_view,
            "    private func applyPlaybackSettings",
        )
        self.assertNotIn("onPlaybackSettingsChange", apply_settings)
        action = method_body(
            self.voice_view,
            "    @objc private func playbackSettingsChanged()",
        )
        self.assertIn("guard !isRefreshing", action)
        self.assertIn("let settings = validatedPlaybackSettings()", action)
        self.assertIn("onPlaybackSettingsChange?(settings)", action)

    def test_playback_controls_emit_validated_settings_through_window_controller(self) -> None:
        validated = method_body(
            self.voice_view,
            "    private func validatedPlaybackSettings",
        )
        self.assertIn("return try? DialogueVoicePlaybackSettings(", validated)
        self.assertIn("automaticPlaybackEnabled: automaticPlaybackCheckbox.state == .on", validated)
        self.assertIn("volume: min(max(voiceVolumeSlider.doubleValue / 100, 0), 1)", validated)
        self.assertIn("repeatIntervalSeconds: repeatInterval", validated)
        self.assertIn("let customRepeatInterval", validated)
        apply_settings = method_body(
            self.voice_view,
            "    private func applyPlaybackSettings",
        )
        self.assertIn("customRepeatInterval = customInterval", apply_settings)
        self.assertIn("(Custom)", apply_settings)
        self.assertNotIn("?? 0", apply_settings)
        self.assertIn(
            "var onPlaybackSettingsChange: ((DialogueVoicePlaybackSettings) -> Void)?",
            self.voice_view,
        )
        self.assertIn(
            "var onDialogueVoicePlaybackSettingsChange: ((DialogueVoicePlaybackSettings) -> Void)?",
            self.settings,
        )
        wiring = method_body(self.settings, "    private func configureDialogueVoicePane")
        self.assertIn("dialogueVoiceView.onPlaybackSettingsChange", wiring)
        self.assertIn("onDialogueVoicePlaybackSettingsChange?(settings)", wiring)
        app_wiring = method_body(self.app_delegate, "    private func makeSettingsController")
        self.assertIn("controller.onDialogueVoicePlaybackSettingsChange", app_wiring)
        self.assertIn("updateDialogueVoicePlaybackSettings(settings)", app_wiring)
        persistence = method_body(
            self.app_delegate,
            "    private func updateDialogueVoicePlaybackSettings",
        )
        self.assertIn("dialogueVoiceCoordinator.updatePlaybackSettings(settings)", persistence)

    def test_manual_preview_enablement_is_independent_of_automatic_playback(self) -> None:
        enablement = method_body(self.voice_view, "    private func refreshButtonEnablement")
        self.assertIn("previewButton.isEnabled = line?.status == .ready", enablement)
        self.assertNotIn("automaticPlaybackCheckbox", enablement)
        preview_action = method_body(self.voice_view, "    @objc private func previewLine()")
        self.assertNotIn("automaticPlaybackCheckbox", preview_action)

    def test_background_refresh_preserves_an_unselected_new_dialogue_draft(self) -> None:
        text_dirty = re.search(
            r"private var newDialogueTextIsDirty: Bool \{(?P<body>[\s\S]*?)\n    \}",
            self.voice_view,
        )
        language_dirty = re.search(
            r"private var newDialogueLanguageIsDirty: Bool \{(?P<body>[\s\S]*?)\n    \}",
            self.voice_view,
        )
        state_dirty = re.search(
            r"private var newDialogueStateIsDirty: Bool \{(?P<body>[\s\S]*?)\n    \}",
            self.voice_view,
        )
        self.assertIsNotNone(text_dirty, "New-dialogue text dirty-state check was not found")
        self.assertIsNotNone(language_dirty, "New-dialogue language dirty-state check was not found")
        self.assertIsNotNone(state_dirty, "New-dialogue state dirty-state check was not found")
        self.assertIn("selectedLineID == nil", text_dirty.group("body"))
        self.assertIn("!dialogueTextView.string.isEmpty", text_dirty.group("body"))
        self.assertIn("selectedLineID == nil", language_dirty.group("body"))
        self.assertIn("lastAppliedNewDialogueLanguage", language_dirty.group("body"))
        self.assertIn("selectedLineID == nil", state_dirty.group("body"))
        self.assertIn("lastAppliedNewDialogueState", state_dirty.group("body"))

        update = method_body(self.voice_view, "    func update")
        no_selection = re.search(
            r"else \{\s*selectedLineID = nil[\s\S]*?linesTable\.deselectAll\(nil\)(?P<body>[\s\S]*?)\n        \}",
            update,
        )
        self.assertIsNotNone(no_selection, "No-selection refresh branch was not found")
        self.assertIn(
            "!preserveNewDialogueText && !preserveNewDialogueState && !preserveNewDialogueLanguage",
            no_selection.group("body"),
        )
        self.assertIn("clearSubmittedDialogueText()", no_selection.group("body"))
        self.assertIn("if !preserveNewDialogueState", no_selection.group("body"))
        self.assertIn("if !preserveNewDialogueLanguage", no_selection.group("body"))
        self.assertIn("applyDefaultDialogueState()", no_selection.group("body"))
        self.assertIn("applyDefaultDialogueLanguage()", no_selection.group("body"))

        clear_fields = method_body(self.voice_view, "    private func clearEditorFields")
        self.assertIn("applyDefaultDialogueLanguage()", clear_fields)
        self.assertIn("applyDefaultDialogueState()", clear_fields)
        clear_submitted = method_body(self.voice_view, "    private func clearSubmittedDialogueText")
        self.assertIn('dialogueTextView.string = ""', clear_submitted)
        self.assertNotIn("applyDefaultDialogueState()", clear_submitted)
        self.assertNotIn("applyDefaultDialogueLanguage()", clear_submitted)
        self.assertIn("lastAppliedNewDialogueState = selectedDialogueState", clear_submitted)
        self.assertIn("lastAppliedNewDialogueLanguage = dialogueLanguageField.stringValue", clear_submitted)
        apply_default = method_body(self.voice_view, "    private func applyDefaultDialogueLanguage")
        self.assertIn("lastAppliedNewDialogueLanguage = dialogueLanguageField.stringValue", apply_default)

        add_line = method_body(self.voice_view, "    @objc private func addLine()")
        self.assertIn("pendingNewDialogueSubmission = PendingNewDialogueSubmission", add_line)
        self.assertIn("existingLineIDs: Set(lines.map(\\.id))", add_line)
        self.assertIn("shouldClearSubmittedNewDialogue", update)

    def test_language_only_new_draft_can_be_cleared_and_pending_state_is_cancelled(self) -> None:
        enablement = method_body(self.voice_view, "    private func refreshButtonEnablement")
        self.assertIn("clearEditorButton.isEnabled = newDialogueTextIsDirty", enablement)
        self.assertIn("|| newDialogueLanguageIsDirty", enablement)
        self.assertIn("|| newDialogueStateIsDirty", enablement)

        clear_editor = method_body(self.voice_view, "    @objc private func clearEditor()")
        self.assertIn("pendingNewDialogueSubmission = nil", clear_editor)
        selection = method_body(self.voice_view, "    func tableViewSelectionDidChange")
        self.assertIn("if let line = selectedLine()", selection)
        self.assertIn("pendingNewDialogueSubmission = nil", selection)

    def test_voice_view_has_two_persistent_internal_pages(self) -> None:
        self.assertIn("private final class TopAlignedVoiceDocumentView", self.voice_view)
        self.assertIn("override var isFlipped: Bool { true }", self.voice_view)
        self.assertIn("private let documentView = TopAlignedVoiceDocumentView()", self.voice_view)
        section_control = re.search(
            r'NSSegmentedControl\(\s*labels:\s*\[(?P<labels>[^]]+)\]',
            self.voice_view,
        )
        self.assertIsNotNone(section_control, "Voice section control was not found")
        labels = re.findall(r'"([^"]+)"', section_control.group("labels"))
        self.assertEqual(labels, ["Dialogue", "Voice Setup"])
        self.assertIn('voiceSectionControl.setAccessibilityLabel("Voice section")', self.voice_view)
        self.assertIn("let voiceSectionPickerRow = centeredRow(voiceSectionControl)", self.voice_view)
        self.assertIn("let profileGridRow = centeredRow(profileGrid)", self.voice_view)
        self.assertIn("views: [profileTitle, profileHelp, profileGridRow, profileActions]", self.voice_view)
        self.assertIn(
            "voiceSectionPickerRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor)",
            self.voice_view,
        )
        self.assertIn("dialoguePage.widthAnchor.constraint(equalTo: contentStack.widthAnchor)", self.voice_view)
        self.assertIn("voiceSetupPage.widthAnchor.constraint(equalTo: contentStack.widthAnchor)", self.voice_view)
        self.assertIn("view.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true", self.voice_view)
        self.assertIn("textLabel.alignment = .left", self.voice_view)

        for page in ("dialoguePage", "voiceSetupPage"):
            self.assertIn(f"private let {page} = NSStackView()", self.voice_view)
            self.assertIn(f"{page}.isHidden", self.voice_view)
        self.assertNotIn("removeArrangedSubview(dialoguePage)", self.voice_view)
        self.assertNotIn("removeArrangedSubview(voiceSetupPage)", self.voice_view)

    def test_dialogue_messages_and_voice_are_owned_by_lifecycle_state(self) -> None:
        self.assertIn('sectionTitle("STATE-OWNED MESSAGES & VOICE")', self.voice_view)
        self.assertIn('fieldLabel("Owning state")', self.voice_view)
        self.assertIn('addColumn(Column.state, title: "State"', self.voice_view)
        self.assertIn("cell.textField?.stringValue = line.state.displayName", self.voice_view)
        self.assertIn("dialogueStatePopup.addItems(withTitles: PetState.allCases.map(\\.displayName))", self.voice_view)
        self.assertIn("var onAddLine: ((String, String, PetState) -> Void)?", self.voice_view)
        self.assertIn("var onUpdateLine: ((DialogueLine, String, String, PetState) -> Void)?", self.voice_view)
        self.assertIn("var onAddDialogueLine: ((String, String, PetState) -> Void)?", self.settings)
        self.assertIn("var onUpdateDialogueLine: ((DialogueLine, String, String, PetState) -> Void)?", self.settings)
        add_line = method_body(self.voice_view, "    @objc private func addLine()")
        update_line = method_body(self.voice_view, "    @objc private func updateLine()")
        self.assertIn("selectedDialogueState", add_line)
        self.assertIn("selectedDialogueState", update_line)

        presentation = method_body(
            self.app_delegate,
            "    private func presentStateOwnedDialogueIfNeeded",
        )
        self.assertIn("stateDialoguePresentation?.state == state", presentation)
        self.assertIn("lineID: line?.id", presentation)
        self.assertIn("keepSpokenMessage", presentation)
        self.assertIn("if !keepSpokenMessage", presentation)
        self.assertIn("beginAutomaticPlayback(", presentation)
        self.assertIn("requestID: presentation.id", presentation)
        lifecycle_start = method_body(
            self.app_delegate,
            "    private func startLifecyclePresentation",
        )
        self.assertIn("stateDialoguePresentation?.state != state", lifecycle_start)
        self.assertIn("let keepSpokenMessage = dialogueVoiceCoordinator.isAutomaticPlaybackActive", lifecycle_start)
        self.assertIn("if !keepSpokenMessage", lifecycle_start)
        self.assertLess(
            lifecycle_start.index("cancelAutomaticPlayback()"),
            lifecycle_start.index("let started = DispatchTime.now()"),
        )
        refresh = method_body(
            self.app_delegate,
            "    private func refreshStateOwnedDialogue",
        )
        self.assertIn("guard !dialogueVoiceCoordinator.isAutomaticPlaybackActive", refresh)
        self.assertLess(
            refresh.index("guard !dialogueVoiceCoordinator.isAutomaticPlaybackActive"),
            refresh.index("let selectedLine"),
        )
        self.assertIn("presentation.lineID", refresh)
        self.assertIn("line.state == presentation.state", refresh)
        self.assertIn("preferredLine(for: presentation.state)", refresh)
        self.assertIn("presentation.audioDisposition = .pending", refresh)
        ensure = method_body(
            self.app_delegate,
            "    private func ensureStateOwnedDialoguePlayback",
        )
        self.assertIn("ensureAutomaticPlayback(", ensure)
        automatic_entry = method_body(
            self.coordinator,
            "    func beginAutomaticPlayback",
        )
        self.assertIn("pendingOpportunity: true", automatic_entry)
        self.assertIn("attemptAutomaticPlayback()", automatic_entry)
        automatic_attempt = method_body(
            self.coordinator,
            "    private func attemptAutomaticPlayback",
        )
        self.assertIn("automaticCandidate", automatic_attempt)
        self.assertIn("guard !audioPlayer.isPlaying", automatic_attempt)
        self.assertIn("playbackService.playReadyLine", automatic_attempt)
        self.assertIn("onAutomaticPlaybackStarted?(session.requestID, line)", automatic_attempt)
        self.assertNotIn("synthesize", automatic_attempt)
        scheduler = method_body(
            self.coordinator,
            "    private func scheduleAutomaticRepeatIfNeeded",
        )
        self.assertIn("sleepForInterval", scheduler)
        self.assertNotIn("while", scheduler)
        candidates = method_body(
            self.coordinator,
            "    private func automaticCandidate",
        )
        self.assertIn("line.status == .ready", candidates)
        self.assertIn("line.outputRelativePath != nil", candidates)
        self.assertNotIn("readManagedFile", candidates)
        self.assertIn("candidates.count >= 2", candidates)
        self.assertIn("lastAutomaticLineIDByState", candidates)
        self.assertIn("lastFailedAutomaticLineIDByState", candidates)
        finished = method_body(
            self.coordinator,
            "    private func voicePlaybackFinished",
        )
        self.assertIn("onAutomaticPlaybackFinished?(requestID, lineID)", finished)
        self.assertLess(
            finished.index("onAutomaticPlaybackFinished?(requestID, lineID)"),
            finished.index("resumeAutomaticPlaybackAfterAudioFinishes()"),
        )
        bubble_finish = method_body(
            self.app_delegate,
            "    private func finishStateOwnedDialogueAudio",
        )
        self.assertIn("line.id == lineID && line.state == presentation.state", bubble_finish)
        self.assertIn("presentation.recordAutomaticPlaybackFinished(", bubble_finish)
        self.assertIn("showDialogueMessage(presentation.text)", bubble_finish)
        finish_reducer = method_body(
            self.app_delegate,
            "    mutating func recordAutomaticPlaybackFinished",
        )
        self.assertIn("guard id == requestID", finish_reducer)
        self.assertIn("guard lineID == finishedLineID", finish_reducer)
        self.assertIn("audioDisposition = .pending", finish_reducer)

    def test_voice_page_default_and_user_selection_are_preserved(self) -> None:
        update = method_body(self.voice_view, "    func update")
        self.assertIn("if !hasSelectedVoiceSection", update)
        self.assertIn("library.activeProviderKind == nil ? .voiceSetup : .dialogue", update)
        selection = method_body(self.voice_view, "    private func selectVoiceSection")
        self.assertIn("hasSelectedVoiceSection = true", selection)
        self.assertIn("dialoguePage.isHidden = section != .dialogue", selection)
        self.assertIn("voiceSetupPage.isHidden = section != .voiceSetup", selection)

    def test_dialogue_page_offers_voice_setup_without_losing_drafts(self) -> None:
        self.assertIn("Choose Add to save this text as a draft.", self.voice_view)
        self.assertIn("Voice Setup and the local service must be ready to generate audio.", self.voice_view)
        self.assertIn('NSButton(title: "Open Voice Setup"', self.voice_view)
        self.assertIn("#selector(openVoiceSetup)", self.voice_view)
        update = method_body(self.voice_view, "    func update")
        self.assertIn("dialogueSetupHint.isHidden = library.profileStatus == .ready", update)
        self.assertIn('accessibilityLabel: "Dialogue page"', self.voice_view)
        self.assertIn('accessibilityLabel: "Voice Setup page"', self.voice_view)
        self.assertIn("page.setAccessibilityRole(.group)", self.voice_view)
        self.assertIn("page.setAccessibilityLabel(accessibilityLabel)", self.voice_view)

    def test_internal_pages_preserve_existing_voice_callbacks(self) -> None:
        callback_actions = {
            "onImportGPTWeight": "importGPTWeight",
            "onImportSoVITSWeight": "importSoVITSWeight",
            "onImportReferenceAudio": "importReferenceAudio",
            "onSaveProfile": "saveProfile",
            "onRemoveProfile": "removeProfile",
            "onAddLine": "addLine",
            "onUpdateLine": "updateLine",
            "onClearEditor": "clearEditor",
            "onDeleteLine": "deleteLine",
            "onPreviewLine": "previewLine",
            "onRetryLine": "retryLine",
            "onRegenerateLine": "regenerateLine",
        }
        for callback, action in callback_actions.items():
            self.assertIn(callback, self.voice_view)
            self.assertIn(f"#selector({action})", self.voice_view)

    def test_qwen_voice_setup_is_provider_scoped_and_private(self) -> None:
        self.assertIn('labels: ["GPT-SoVITS", "Qwen3-TTS"]', self.voice_view)
        self.assertIn('setAccessibilityLabel("Voice provider")', self.voice_view)
        self.assertIn('NSButton(title: "Import Qwen Handover…"', self.voice_view)
        self.assertIn('NSButton(title: "Use Qwen3-TTS"', self.voice_view)
        self.assertIn('NSButton(title: "Use GPT-SoVITS"', self.voice_view)
        self.assertIn('NSButton(title: "Remove Qwen Profile…"', self.voice_view)
        self.assertIn("library.activeProviderKind", self.voice_view)
        self.assertIn("library.qwenProfile", self.voice_view)
        self.assertIn("profile.packageRootRelativePath", self.voice_view)
        self.assertIn("profile.pythonExecutablePath", self.voice_view)
        self.assertIn("24 kHz PCM16", self.voice_view)
        self.assertIn("profile.seed", self.voice_view)
        self.assertIn("profile.temperature", self.voice_view)
        self.assertNotIn("qwenProfile.referenceText", self.voice_view)
        self.assertNotIn("profile.referenceText", method_body(
            self.voice_view,
            "    private func applyQwenSummary",
        ))
        selection = method_body(self.voice_view, "    private func selectDisplayedProvider")
        self.assertIn("gptProfilePage.isHidden", selection)
        self.assertIn("qwenProfilePage.isHidden", selection)
        self.assertIn("hasSelectedVoiceProvider = true", selection)

    def test_qwen_settings_callbacks_are_forwarded_for_app_delegate_wiring(self) -> None:
        callbacks = (
            "onConfigureQwenProfile",
            "onSelectVoiceProvider",
            "onRemoveQwenProfile",
        )
        for callback in callbacks:
            self.assertIn(callback, self.voice_view)
            self.assertIn(callback, self.settings)
            self.assertIn(f"dialogueVoiceView.{callback}", self.settings)
            self.assertIn(f"self?.{callback}?", self.settings)
        self.assertIn("onSelectVoiceProvider?(.qwen3TTS)", self.voice_view)
        self.assertIn("onSelectVoiceProvider?(.gptSovits)", self.voice_view)
        runtime_picker = method_body(
            self.app_delegate,
            "    private func chooseQwenPythonRuntime",
        )
        self.assertIn("pythonPanel.resolvesAliases = false", runtime_picker)

    def test_qwen_helpers_use_parent_owned_process_group_handshake(self) -> None:
        helper_root = ROOT / "mac" / "CodexPetMac" / "Resources" / "QwenTTS"
        generator = (helper_root / "qwen3_tts_generate.py").read_text(encoding="utf-8")
        probe = (helper_root / "qwen3_tts_probe.py").read_text(encoding="utf-8")
        for source in (generator, probe):
            self.assertNotIn("os.setsid()", source)
            self.assertIn("os.getpgrp() != os.getpid()", source)
        self.assertLess(
            probe.index("sys.stdin.buffer.read()"),
            probe.index("import mlx"),
        )

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
        self.assertIn("public enum DialogueSynthesisPolicy", self.core)
        self.assertIn("public static let currentVersion = 3", self.core)
        self.assertIn('case generatedSynthesisPolicyVersion = "generated_synthesis_policy_version"', self.core)
        self.assertIn("migrateOutdatedSynthesisOutputs()", self.coordinator)
        self.assertIn("pendingLineRetainingOutput", self.core)
        generation_finish = method_body(self.coordinator, "    private func finishGeneration")
        self.assertIn("replacedOutput", generation_finish)
        self.assertIn("enqueueCleanup(paths: [replacedOutput])", generation_finish)

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
        self.assertIn("retryPendingCleanup(preserving: cleanupPreservationPaths)", accept_import)
        self.assertIn("stagedImportedPaths.union(inFlightQwenPackagePaths)", accept_import)

        shutdown = method_body(self.coordinator, "    func shutdown")
        self.assertIn("retryPendingCleanup()", shutdown)
        self.assertIn("inFlightQwenPackagePaths", self.coordinator)

        remove_profile = method_body(
            self.coordinator,
            "    func removeProfile(provider removedProvider: DialogueVoiceProviderKind)",
        )
        self.assertIn("cleanupPreservationPaths", remove_profile)

        retry_cleanup = method_body(
            self.coordinator,
            "    private func retryPendingCleanup",
        )
        self.assertIn("preservedPaths ?? cleanupPreservationPaths", retry_cleanup)

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
