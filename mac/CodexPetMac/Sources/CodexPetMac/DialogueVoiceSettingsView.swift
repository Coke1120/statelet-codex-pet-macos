import AppKit
import CodexPetCore

struct DialogueVoiceProfileDraft: Equatable {
    var name: String
    var apiBaseURL: String
    var promptLanguage: String
    var defaultTextLanguage: String
    var referenceText: String
}

private final class TopAlignedVoiceDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class DialogueVoiceSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    var onImportGPTWeight: ((DialogueVoiceProfileDraft) -> Void)?
    var onImportSoVITSWeight: ((DialogueVoiceProfileDraft) -> Void)?
    var onImportReferenceAudio: ((DialogueVoiceProfileDraft) -> Void)?
    var onSaveProfile: ((DialogueVoiceProfileDraft) -> Void)?
    var onRemoveProfile: ((GPTSoVITSVoiceProfile) -> Void)?
    var onConfigureQwenProfile: (() -> Void)?
    var onSelectVoiceProvider: ((DialogueVoiceProviderKind) -> Void)?
    var onRemoveQwenProfile: ((Qwen3TTSVoiceProfile) -> Void)?
    var onConfigureVoxCPM2Profile: ((String) -> Void)?
    var onRemoveVoxCPM2Profile: ((VoxCPM2VoiceProfile) -> Void)?
    var onAddLine: ((String, String, PetState) -> Void)?
    var onUpdateLine: ((DialogueLine, String, String, PetState) -> Void)?
    var onClearEditor: (() -> Void)?
    var onDeleteLine: ((DialogueLine) -> Void)?
    var onPreviewLine: ((DialogueLine) -> Void)?
    var onRetryLine: ((DialogueLine) -> Void)?
    var onRegenerateLine: ((DialogueLine) -> Void)?
    var onPlaybackSettingsChange: ((DialogueVoicePlaybackSettings) -> Void)?

    private enum Column {
        static let dialogue = NSUserInterfaceItemIdentifier("dialogue-voice.dialogue")
        static let state = NSUserInterfaceItemIdentifier("dialogue-voice.state")
        static let language = NSUserInterfaceItemIdentifier("dialogue-voice.language")
        static let status = NSUserInterfaceItemIdentifier("dialogue-voice.status")
    }

    private enum VoiceSection: Int {
        case dialogue
        case voiceSetup
    }

    private struct PendingNewDialogueSubmission {
        let editorText: String
        let editorState: PetState
        let editorLanguage: String
        let submittedText: String
        let submittedState: PetState
        let submittedLanguage: String
        let existingLineIDs: Set<UUID>
    }

    private let outerScrollView = NSScrollView()
    private let documentView = TopAlignedVoiceDocumentView()
    private let voiceSectionControl = NSSegmentedControl(
        labels: ["Dialogue", "Voice Setup"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let dialoguePage = NSStackView()
    private let voiceSetupPage = NSStackView()
    private let voiceProviderControl = NSSegmentedControl(
        labels: ["GPT-SoVITS", "Qwen3-TTS", "VoxCPM2"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let gptProfilePage = NSStackView()
    private let qwenProfilePage = NSStackView()
    private let voxProfilePage = NSStackView()
    private let nameField = NSTextField()
    private let apiBaseURLField = NSTextField()
    private let promptLanguageField = NSTextField()
    private let defaultTextLanguageField = NSTextField()
    private let referenceTextField = NSTextField()
    private let profileStatusLabel = NSTextField(labelWithString: "Not configured")
    private let gptWeightLabel = NSTextField(labelWithString: "Not imported")
    private let sovitsWeightLabel = NSTextField(labelWithString: "Not imported")
    private let referenceAudioLabel = NSTextField(labelWithString: "Not imported")
    private let importGPTButton = NSButton(title: "Import GPT Weight…", target: nil, action: nil)
    private let importSoVITSButton = NSButton(title: "Import SoVITS Weight…", target: nil, action: nil)
    private let importReferenceAudioButton = NSButton(title: "Import Reference Audio…", target: nil, action: nil)
    private let saveProfileButton = NSButton(title: "Save Profile", target: nil, action: nil)
    private let useGPTButton = NSButton(title: "Use GPT-SoVITS", target: nil, action: nil)
    private let removeProfileButton = NSButton(title: "Remove GPT Profile…", target: nil, action: nil)
    private let qwenStatusLabel = NSTextField(labelWithString: "Not configured")
    private let qwenPackageLabel = NSTextField(labelWithString: "Not imported")
    private let qwenRuntimeLabel = NSTextField(labelWithString: "Not selected")
    private let qwenConfigurationLabel = NSTextField(wrappingLabelWithString: "Japanese zero-shot · 24 kHz PCM16")
    private let importQwenButton = NSButton(title: "Import Qwen Handover…", target: nil, action: nil)
    private let useQwenButton = NSButton(title: "Use Qwen3-TTS", target: nil, action: nil)
    private let removeQwenButton = NSButton(title: "Remove Qwen Profile…", target: nil, action: nil)
    private let voxStatusLabel = NSTextField(labelWithString: "Not configured")
    private let voxSnapshotLabel = NSTextField(labelWithString: "Not selected")
    private let voxRuntimeLabel = NSTextField(labelWithString: "Not selected")
    private let voxReferenceTextField = NSTextField()
    private let importVoxButton = NSButton(title: "Configure VoxCPM2…", target: nil, action: nil)
    private let useVoxButton = NSButton(title: "Use VoxCPM2", target: nil, action: nil)
    private let removeVoxButton = NSButton(title: "Remove VoxCPM2 Profile…", target: nil, action: nil)

    private let dialogueTextView = NSTextView()
    private let dialogueStatePopup = NSPopUpButton()
    private let dialogueLanguageField = NSTextField()
    private let addLineButton = NSButton(title: "Add", target: nil, action: nil)
    private let updateLineButton = NSButton(title: "Update", target: nil, action: nil)
    private let clearEditorButton = NSButton(title: "Clear", target: nil, action: nil)
    private let linesTable = NSTableView()
    private let linesScrollView = NSScrollView()
    private let deleteButton = NSButton(title: "Delete…", target: nil, action: nil)
    private let previewButton = NSButton(title: "Preview", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let regenerateButton = NSButton(title: "Regenerate", target: nil, action: nil)
    private let dialogueSetupHint = NSStackView()
    private let openVoiceSetupButton = NSButton(title: "Open Voice Setup", target: nil, action: nil)
    private let automaticPlaybackCheckbox = NSButton(
        checkboxWithTitle: "Automatic playback",
        target: nil,
        action: nil
    )
    private let voiceVolumeSlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let voiceVolumeValueLabel = NSTextField(labelWithString: "100%")
    private let repeatIntervalPopup = NSPopUpButton()
    private let activityLabel = NSTextField(wrappingLabelWithString: "")

    private let repeatIntervalValues: [TimeInterval?] = [nil, 15, 30, 60, 120, 300, 600]
    private var customRepeatInterval: TimeInterval?

    private var profile: GPTSoVITSVoiceProfile?
    private var qwenProfile: Qwen3TTSVoiceProfile?
    private var voxProfile: VoxCPM2VoiceProfile?
    private var activeProviderKind: DialogueVoiceProviderKind?
    private var profileStatus: DialogueVoiceProfileStatus = .notConfigured
    private var lines: [DialogueLine] = []
    private var importedAssets = DialogueVoiceImportedAssets()
    private var draftDefaultTextLanguage = ""
    private var selectedLineID: UUID?
    private var lastAppliedProfileDraft: DialogueVoiceProfileDraft?
    private var lastAppliedEditorLine: DialogueLine?
    private var lastAppliedNewDialogueState: PetState = .idle
    private var lastAppliedNewDialogueLanguage = ""
    private var pendingNewDialogueSubmission: PendingNewDialogueSubmission?
    private var isRefreshing = false
    private var hasSelectedVoiceSection = false
    private var hasSelectedVoiceProvider = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        buildInterface()
        refreshButtonEnablement()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var profileDraft: DialogueVoiceProfileDraft {
        DialogueVoiceProfileDraft(
            name: nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            apiBaseURL: apiBaseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            promptLanguage: promptLanguageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            defaultTextLanguage: defaultTextLanguageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            referenceText: referenceTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func update(snapshot: DialogueVoiceCoordinatorSnapshot) {
        let preserveProfileEdits = profileEditorIsDirty
            && snapshot.draft == lastAppliedProfileDraft
        let preserveDialogueEdits = dialogueEditorIsDirty
        let preserveNewDialogueText = newDialogueTextIsDirty
        let preserveNewDialogueState = newDialogueStateIsDirty
        let preserveNewDialogueLanguage = newDialogueLanguageIsDirty
        isRefreshing = true
        defer {
            isRefreshing = false
            refreshButtonEnablement()
        }

        let library = snapshot.library
        let submittedNewDialogueWasSaved = pendingNewDialogueSubmission.map { submission in
            library.lines.contains {
                !submission.existingLineIDs.contains($0.id)
                    && $0.text == submission.submittedText
                    && $0.state == submission.submittedState
                    && $0.textLanguage == submission.submittedLanguage
            }
        } ?? false
        let shouldClearSubmittedNewDialogue = submittedNewDialogueWasSaved
            && dialogueTextView.string == pendingNewDialogueSubmission?.editorText
            && selectedDialogueState == pendingNewDialogueSubmission?.editorState
            && dialogueLanguageField.stringValue == pendingNewDialogueSubmission?.editorLanguage
        if submittedNewDialogueWasSaved {
            pendingNewDialogueSubmission = nil
        }
        profile = library.profile
        qwenProfile = library.qwenProfile
        voxProfile = library.voxcpm2Profile
        activeProviderKind = library.activeProviderKind
        profileStatus = library.profileStatus
        lines = library.lines
        importedAssets = snapshot.importedAssets
        draftDefaultTextLanguage = snapshot.draft.defaultTextLanguage
        applyPlaybackSettings(library.playbackSettings)
        if !hasSelectedVoiceSection {
            selectVoiceSection(library.activeProviderKind == nil ? .voiceSetup : .dialogue, userInitiated: false)
        }
        if !hasSelectedVoiceProvider {
            selectDisplayedProvider(
                library.activeProviderKind ?? (library.qwenProfile == nil ? .gptSovits : .qwen3TTS),
                userInitiated: false
            )
        }
        dialogueSetupHint.isHidden = library.profileStatus == .ready
        if !preserveProfileEdits {
            applyProfileDraft(snapshot.draft)
        }
        gptWeightLabel.stringValue = snapshot.importedAssets.gptWeightRelativePath
            .map(safeBasename) ?? "Not imported"
        sovitsWeightLabel.stringValue = snapshot.importedAssets.sovitsWeightRelativePath
            .map(safeBasename) ?? "Not imported"
        referenceAudioLabel.stringValue = snapshot.importedAssets.referenceAudioRelativePath
            .map(safeBasename) ?? "Not imported"
        profileStatusLabel.stringValue = providerStatusTitle(
            configured: library.profile != nil,
            active: library.activeProviderKind == .gptSovits,
            activeStatus: library.profileStatus
        )
        applyQwenSummary(profile: library.qwenProfile, activeProviderKind: library.activeProviderKind)
        applyVoxSummary(profile: library.voxcpm2Profile, activeProviderKind: library.activeProviderKind)

        activityLabel.stringValue = snapshot.activityMessage ?? ""
        activityLabel.isHidden = snapshot.activityMessage?.isEmpty != false
        activityLabel.toolTip = snapshot.activityMessage
        activityLabel.setAccessibilityHelp(snapshot.activityMessage)

        let preservedID = selectedLineID
        linesTable.reloadData()
        if let preservedID, let row = lines.firstIndex(where: { $0.id == preservedID }) {
            linesTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            let refreshedLine = lines[row]
            if !preserveDialogueEdits || editorContentChanged(onServer: refreshedLine) {
                populateEditor(with: refreshedLine)
            } else {
                lastAppliedEditorLine = refreshedLine
            }
        } else {
            selectedLineID = nil
            lastAppliedEditorLine = nil
            linesTable.deselectAll(nil)
            if shouldClearSubmittedNewDialogue || (!preserveNewDialogueText && !preserveNewDialogueState && !preserveNewDialogueLanguage) {
                if shouldClearSubmittedNewDialogue {
                    clearSubmittedDialogueText()
                } else {
                    clearEditorFields()
                }
            } else {
                if !preserveNewDialogueState { applyDefaultDialogueState() }
                if !preserveNewDialogueLanguage { applyDefaultDialogueLanguage() }
            }
        }
        linesTable.setAccessibilityHelp(
            lines.isEmpty
                ? "No dialogue lines have been added."
                : "\(lines.count) dialogue lines. Select a row to edit or manage its generated audio."
        )
    }

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRefreshing else { return }
        if let line = selectedLine() {
            pendingNewDialogueSubmission = nil
            selectedLineID = line.id
            populateEditor(with: line)
        } else {
            selectedLineID = nil
            lastAppliedEditorLine = nil
        }
        refreshButtonEnablement()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < lines.count, let tableColumn else { return nil }
        let line = lines[row]
        let cell = reusableCell(identifier: tableColumn.identifier)
        switch tableColumn.identifier {
        case Column.dialogue:
            cell.textField?.stringValue = line.text
            cell.textField?.lineBreakMode = .byTruncatingTail
            cell.setAccessibilityLabel(line.text)
        case Column.state:
            cell.textField?.stringValue = line.state.displayName
            cell.setAccessibilityLabel("State \(line.state.displayName)")
        case Column.language:
            cell.textField?.stringValue = line.textLanguage
            cell.setAccessibilityLabel("Language \(line.textLanguage)")
        case Column.status:
            let output = line.outputRelativePath.map { safeBasename($0) }
            let failure = line.failureCode?.isEmpty == false ? line.failureCode : nil
            let detail = output ?? failure
            cell.textField?.stringValue = detail.map { "\(statusTitle(line.status)) · \($0)" } ?? statusTitle(line.status)
            cell.textField?.textColor = line.status == .failed ? .systemRed : .labelColor
            cell.setAccessibilityLabel(detail.map { "\(statusTitle(line.status)), \($0)" } ?? statusTitle(line.status))
        default:
            return nil
        }
        return cell
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !isRefreshing else { return }
        refreshButtonEnablement()
    }

    func textDidChange(_ notification: Notification) {
        guard !isRefreshing else { return }
        refreshButtonEnablement()
    }

    private func buildInterface() {
        outerScrollView.translatesAutoresizingMaskIntoConstraints = false
        outerScrollView.hasVerticalScroller = true
        outerScrollView.hasHorizontalScroller = false
        outerScrollView.autohidesScrollers = true
        outerScrollView.drawsBackground = false
        outerScrollView.documentView = documentView
        documentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outerScrollView)
        NSLayoutConstraint.activate([
            outerScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            outerScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            outerScrollView.topAnchor.constraint(equalTo: topAnchor),
            outerScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            documentView.leadingAnchor.constraint(equalTo: outerScrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: outerScrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: outerScrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: outerScrollView.contentView.widthAnchor),
        ])

        configureFields()
        configureButtons()
        configureTable()
        configureVoiceSections()

        let profileTitle = sectionTitle("GPT-SOVITS PROFILE")
        let profileHelp = helpLabel("Connect to a GPT-SoVITS API running only on this Mac. Statelet stores managed copies of the selected model files and reference audio.")
        let profileGrid = NSGridView(views: [
            [fieldLabel("Display name"), nameField],
            [fieldLabel("API base URL"), apiBaseURLField],
            [fieldLabel("Prompt language"), promptLanguageField],
            [fieldLabel("Default text language"), defaultTextLanguageField],
            [fieldLabel("Reference text"), referenceTextField],
            [fieldLabel("Validation status"), profileStatusLabel],
            [fieldLabel("GPT weight"), fileRow(label: gptWeightLabel, button: importGPTButton)],
            [fieldLabel("SoVITS weight"), fileRow(label: sovitsWeightLabel, button: importSoVITSButton)],
            [fieldLabel("Reference audio"), fileRow(label: referenceAudioLabel, button: importReferenceAudioButton)],
        ])
        profileGrid.translatesAutoresizingMaskIntoConstraints = false
        profileGrid.rowSpacing = 7
        profileGrid.columnSpacing = 10
        profileGrid.column(at: 0).xPlacement = .trailing
        profileGrid.column(at: 1).xPlacement = .fill
        let profileGridRow = centeredRow(profileGrid)
        let profileActions = buttonRow([saveProfileButton, useGPTButton, removeProfileButton])

        let qwenTitle = sectionTitle("QWEN3-TTS PROFILE")
        let qwenHelp = helpLabel("Import a trusted, self-contained Qwen handover package for private local generation. Statelet displays only managed basenames and never reveals the reference transcript here.")
        let qwenGrid = NSGridView(views: [
            [fieldLabel("Provider status"), qwenStatusLabel],
            [fieldLabel("Managed package"), qwenPackageLabel],
            [fieldLabel("Python runtime"), qwenRuntimeLabel],
            [fieldLabel("Generation recipe"), qwenConfigurationLabel],
        ])
        qwenGrid.translatesAutoresizingMaskIntoConstraints = false
        qwenGrid.rowSpacing = 7
        qwenGrid.columnSpacing = 10
        qwenGrid.column(at: 0).xPlacement = .trailing
        qwenGrid.column(at: 1).xPlacement = .fill
        let qwenActions = buttonRow([importQwenButton, useQwenButton, removeQwenButton])
        let voxTitle = sectionTitle("VOXCPM2 PROFILE")
        let voxHelp = helpLabel("Pin a trusted external VoxCPM2 snapshot and Python runtime, copy one private reference WAV, and enter its exact transcript.")
        let voxGrid = NSGridView(views: [
            [fieldLabel("Provider status"), voxStatusLabel],
            [fieldLabel("Snapshot"), voxSnapshotLabel],
            [fieldLabel("Python runtime"), voxRuntimeLabel],
            [fieldLabel("Reference text"), voxReferenceTextField],
        ])
        let voxActions = buttonRow([importVoxButton, useVoxButton, removeVoxButton])

        configurePage(
            gptProfilePage,
            views: [profileTitle, profileHelp, profileGridRow, profileActions],
            accessibilityLabel: "GPT-SoVITS profile setup"
        )
        configurePage(
            qwenProfilePage,
            views: [qwenTitle, qwenHelp, centeredRow(qwenGrid), qwenActions],
            accessibilityLabel: "Qwen3-TTS profile setup"
        )
        configurePage(voxProfilePage, views: [voxTitle, voxHelp, centeredRow(voxGrid), voxActions], accessibilityLabel: "VoxCPM2 profile setup")

        let dialogueTitle = sectionTitle("STATE-OWNED MESSAGES & VOICE")
        let dialogueHelp = helpLabel("Each message and its generated voice belongs to one Statelet lifecycle state. Adding or updating a message requests background pre-generation.")
        let textLabel = fieldLabel("Dialogue text")
        textLabel.alignment = .left
        textLabel.setAccessibilityLabel("Dialogue text label")
        let languageRow = NSStackView(views: [
            fieldLabel("Owning state"), dialogueStatePopup,
            fieldLabel("Text language"), dialogueLanguageField,
        ])
        languageRow.orientation = .horizontal
        languageRow.alignment = .centerY
        languageRow.spacing = 10
        let editorActions = buttonRow([addLineButton, updateLineButton, clearEditorButton])
        let selectedActions = buttonRow([deleteButton, previewButton, retryButton, regenerateButton])

        let dialogueSetupText = helpLabel("Choose Add to save this text as a draft. Voice Setup and the local service must be ready to generate audio.")
        dialogueSetupHint.orientation = .horizontal
        dialogueSetupHint.alignment = .centerY
        dialogueSetupHint.spacing = 8
        dialogueSetupHint.addArrangedSubview(dialogueSetupText)
        dialogueSetupHint.addArrangedSubview(openVoiceSetupButton)
        dialogueSetupText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let playbackTitle = sectionTitle("VOICE PLAYBACK")
        let playbackHelp = helpLabel("Choose whether ready state-owned dialogue plays automatically. Preview remains available whenever a selected line is ready.")
        let volumeRow = NSStackView(views: [voiceVolumeSlider, voiceVolumeValueLabel])
        volumeRow.orientation = .horizontal
        volumeRow.alignment = .centerY
        volumeRow.spacing = 8
        let playbackGrid = NSGridView(views: [
            [fieldLabel("Playback"), automaticPlaybackCheckbox],
            [fieldLabel("Voice volume"), volumeRow],
            [fieldLabel("Repeat interval"), repeatIntervalPopup],
        ])
        playbackGrid.translatesAutoresizingMaskIntoConstraints = false
        playbackGrid.rowSpacing = 7
        playbackGrid.columnSpacing = 10
        playbackGrid.column(at: 0).xPlacement = .trailing
        playbackGrid.column(at: 1).xPlacement = .fill

        configurePage(
            voiceSetupPage,
            views: [centeredRow(voiceProviderControl), gptProfilePage, qwenProfilePage, voxProfilePage],
            accessibilityLabel: "Voice Setup page"
        )
        configurePage(
            dialoguePage,
            views: [
                dialogueTitle,
                dialogueHelp,
                dialogueSetupHint,
                playbackTitle,
                playbackHelp,
                playbackGrid,
                textLabel,
                dialogueTextScrollView(),
                languageRow,
                editorActions,
                linesScrollView,
                selectedActions,
            ],
            accessibilityLabel: "Dialogue page"
        )
        gptProfilePage.setCustomSpacing(4, after: profileTitle)
        qwenProfilePage.setCustomSpacing(4, after: qwenTitle)
        dialoguePage.setCustomSpacing(4, after: dialogueTitle)
        dialoguePage.setCustomSpacing(4, after: playbackTitle)

        activityLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        activityLabel.textColor = .secondaryLabelColor
        activityLabel.isHidden = true
        activityLabel.setAccessibilityLabel("Dialogue voice activity")

        let voiceSectionPickerRow = centeredRow(voiceSectionControl)
        let contentStack = NSStackView(views: [
            voiceSectionPickerRow,
            dialoguePage,
            voiceSetupPage,
            activityLabel,
        ])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .width
        contentStack.spacing = 8
        documentView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 4),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -8),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 2),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -8),
            voiceSectionPickerRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            dialoguePage.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            voiceSetupPage.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            linesScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 190),
            dialogueLanguageField.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            dialogueStatePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
            voiceVolumeSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            voiceVolumeValueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            repeatIntervalPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
        selectVoiceSection(.voiceSetup, userInitiated: false)
    }

    private func configureVoiceSections() {
        voiceSectionControl.target = self
        voiceSectionControl.action = #selector(voiceSectionChanged)
        voiceSectionControl.segmentStyle = .rounded
        voiceSectionControl.setAccessibilityLabel("Voice section")
        voiceSectionControl.setAccessibilityHelp("Choose between dialogue editing and local voice profile setup.")
        openVoiceSetupButton.target = self
        openVoiceSetupButton.action = #selector(openVoiceSetup)
        openVoiceSetupButton.setAccessibilityLabel("Open Voice Setup")
        openVoiceSetupButton.setAccessibilityHelp("Open the voice profile and model import page without discarding this dialogue draft.")
        voiceProviderControl.target = self
        voiceProviderControl.action = #selector(voiceProviderChanged)
        voiceProviderControl.segmentStyle = .rounded
        voiceProviderControl.setAccessibilityLabel("Voice provider")
        voiceProviderControl.setAccessibilityHelp("Choose which local voice provider profile to view and configure. This does not discard dialogue or GPT profile drafts.")
    }

    private func configurePage(_ page: NSStackView, views: [NSView], accessibilityLabel: String) {
        page.translatesAutoresizingMaskIntoConstraints = false
        page.orientation = .vertical
        page.alignment = .width
        page.spacing = 8
        page.setAccessibilityElement(true)
        page.setAccessibilityRole(.group)
        page.setAccessibilityLabel(accessibilityLabel)
        for view in views {
            page.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        }
    }

    private func selectVoiceSection(_ section: VoiceSection, userInitiated: Bool) {
        voiceSectionControl.selectedSegment = section.rawValue
        dialoguePage.isHidden = section != .dialogue
        voiceSetupPage.isHidden = section != .voiceSetup
        if userInitiated {
            hasSelectedVoiceSection = true
        }
    }

    private func selectDisplayedProvider(_ provider: DialogueVoiceProviderKind, userInitiated: Bool) {
        let segment = switch provider { case .gptSovits: 0; case .qwen3TTS: 1; case .voxcpm2: 2 }
        voiceProviderControl.selectedSegment = segment
        gptProfilePage.isHidden = provider != .gptSovits
        qwenProfilePage.isHidden = provider != .qwen3TTS
        voxProfilePage.isHidden = provider != .voxcpm2
        if userInitiated {
            hasSelectedVoiceProvider = true
        }
    }

    private func configureFields() {
        nameField.placeholderString = "Character voice"
        apiBaseURLField.placeholderString = "http://127.0.0.1:9880"
        promptLanguageField.placeholderString = "e.g. zh, yue, en, ja"
        defaultTextLanguageField.placeholderString = "e.g. zh, yue, en, ja"
        referenceTextField.placeholderString = "Transcript of the reference audio"
        dialogueLanguageField.placeholderString = "Text language"
        voxReferenceTextField.placeholderString = "Exact transcript of the reference WAV"
        voxReferenceTextField.delegate = self
        dialogueStatePopup.addItems(withTitles: PetState.allCases.map(\.displayName))
        dialogueStatePopup.selectItem(at: PetState.allCases.firstIndex(of: .idle) ?? 0)
        dialogueStatePopup.target = self
        dialogueStatePopup.action = #selector(dialogueStateChanged)
        dialogueStatePopup.setAccessibilityLabel("Owning lifecycle state")
        dialogueStatePopup.setAccessibilityHelp("Choose which Statelet lifecycle state owns this message and generated voice.")
        repeatIntervalPopup.addItems(withTitles: [
            "Never", "15s", "30s", "60s", "120s", "300s", "600s",
        ])
        repeatIntervalPopup.setAccessibilityLabel("Automatic voice repeat interval")
        repeatIntervalPopup.setAccessibilityHelp("Choose how often automatic voice may repeat, or Never to disable repeats.")
        voiceVolumeSlider.numberOfTickMarks = 11
        voiceVolumeSlider.allowsTickMarkValuesOnly = false
        voiceVolumeSlider.setAccessibilityLabel("Voice volume")
        voiceVolumeSlider.setAccessibilityHelp("Set dialogue voice playback volume from 0 to 100 percent.")
        voiceVolumeValueLabel.setAccessibilityLabel("Voice volume value")
        automaticPlaybackCheckbox.setAccessibilityLabel("Automatic voice playback")
        automaticPlaybackCheckbox.setAccessibilityHelp("Play ready dialogue automatically when Statelet enters its owning lifecycle state.")
        for (field, label, help) in [
            (nameField, "Voice profile display name", "A local label for this voice profile."),
            (apiBaseURLField, "GPT-SoVITS API base URL", "Use a loopback URL such as http://127.0.0.1:9880."),
            (promptLanguageField, "Reference prompt language", "Language identifier accepted by the local GPT-SoVITS API."),
            (defaultTextLanguageField, "Default dialogue text language", "Used when preparing new dialogue lines."),
            (referenceTextField, "Reference audio transcript", "Enter the exact spoken text in the imported reference audio."),
            (dialogueLanguageField, "Dialogue text language", "Language identifier for the dialogue currently being edited."),
        ] {
            field.delegate = self
            field.setAccessibilityLabel(label)
            field.setAccessibilityHelp(help)
        }
        for label in [gptWeightLabel, sovitsWeightLabel, referenceAudioLabel] {
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 1
            label.textColor = .secondaryLabelColor
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        profileStatusLabel.textColor = .secondaryLabelColor
        profileStatusLabel.setAccessibilityLabel("Voice profile validation status")
        for label in [qwenStatusLabel, qwenPackageLabel, qwenRuntimeLabel, qwenConfigurationLabel] {
            label.textColor = .secondaryLabelColor
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        qwenPackageLabel.lineBreakMode = .byTruncatingMiddle
        qwenRuntimeLabel.lineBreakMode = .byTruncatingMiddle
        qwenStatusLabel.setAccessibilityLabel("Qwen3-TTS provider status")
        qwenPackageLabel.setAccessibilityLabel("Qwen3-TTS managed package")
        qwenRuntimeLabel.setAccessibilityLabel("Qwen3-TTS Python runtime")
        qwenConfigurationLabel.setAccessibilityLabel("Qwen3-TTS generation recipe")
        qwenConfigurationLabel.setAccessibilityHelp("Fixed local Japanese zero-shot output and sampling parameters. The private reference transcript is not displayed.")
    }

    private func configureButtons() {
        let actions: [(NSButton, Selector, String, String)] = [
            (importGPTButton, #selector(importGPTWeight), "Import GPT weight", "Select the trusted GPT checkpoint used by the local API."),
            (importSoVITSButton, #selector(importSoVITSWeight), "Import SoVITS weight", "Select the trusted SoVITS checkpoint used by the local API."),
            (importReferenceAudioButton, #selector(importReferenceAudio), "Import reference audio", "Select the local reference recording for this voice."),
            (saveProfileButton, #selector(saveProfile), "Save voice profile", "Save the profile fields shown above."),
            (useGPTButton, #selector(useGPTProfile), "Use GPT-SoVITS", "Make the configured GPT-SoVITS profile the active voice provider."),
            (removeProfileButton, #selector(removeProfile), "Remove GPT-SoVITS profile", "Remove the configured GPT-SoVITS profile after confirmation by the app."),
            (importQwenButton, #selector(importQwenProfile), "Import Qwen handover package", "Choose a trusted self-contained Qwen3-TTS handover package and Python runtime for private local use."),
            (useQwenButton, #selector(useQwenProfile), "Use Qwen3-TTS", "Make the configured Qwen3-TTS profile the active voice provider."),
            (removeQwenButton, #selector(removeQwenProfile), "Remove Qwen profile", "Remove the configured Qwen3-TTS profile after confirmation by the app."),
            (importVoxButton, #selector(importVoxProfile), "Configure VoxCPM2", "Choose the trusted snapshot, reference WAV, and Python runtime."),
            (useVoxButton, #selector(useVoxProfile), "Use VoxCPM2", "Make the configured VoxCPM2 profile active."),
            (removeVoxButton, #selector(removeVoxProfile), "Remove VoxCPM2 profile", "Remove its private reference and generated speech after confirmation."),
            (addLineButton, #selector(addLine), "Add dialogue line", "Save this text as a new line and request pre-generation."),
            (updateLineButton, #selector(updateLine), "Update selected dialogue line", "Save changes to the selected line and request new audio."),
            (clearEditorButton, #selector(clearEditor), "Clear dialogue editor", "Clear the editor and selection without deleting a saved line."),
            (deleteButton, #selector(deleteLine), "Delete selected dialogue line", "Delete the selected line after confirmation by the app."),
            (previewButton, #selector(previewLine), "Preview selected dialogue line", "Play the selected line when generated audio is ready."),
            (retryButton, #selector(retryLine), "Retry selected dialogue line", "Retry a failed generation without creating another line."),
            (regenerateButton, #selector(regenerateLine), "Regenerate selected dialogue line", "Discard the selected line's generated result and request a fresh one."),
            (automaticPlaybackCheckbox, #selector(playbackSettingsChanged), "Automatic voice playback", "Play ready dialogue automatically when Statelet enters its owning lifecycle state."),
        ]
        for (button, action, label, help) in actions {
            button.target = self
            button.action = action
            button.setAccessibilityLabel(label)
            button.setAccessibilityHelp(help)
        }
        voiceVolumeSlider.target = self
        voiceVolumeSlider.action = #selector(playbackSettingsChanged)
        repeatIntervalPopup.target = self
        repeatIntervalPopup.action = #selector(playbackSettingsChanged)
    }

    private func configureTable() {
        linesTable.delegate = self
        linesTable.dataSource = self
        linesTable.rowHeight = 30
        linesTable.allowsMultipleSelection = false
        linesTable.allowsEmptySelection = true
        linesTable.usesAlternatingRowBackgroundColors = true
        linesTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        linesTable.setAccessibilityLabel("Dialogue lines")
        addColumn(Column.dialogue, title: "Dialogue", width: 390, minimumWidth: 220)
        addColumn(Column.state, title: "State", width: 90, minimumWidth: 75)
        addColumn(Column.language, title: "Language", width: 90, minimumWidth: 75)
        addColumn(Column.status, title: "Status", width: 170, minimumWidth: 120)
        linesScrollView.translatesAutoresizingMaskIntoConstraints = false
        linesScrollView.borderType = .bezelBorder
        linesScrollView.hasVerticalScroller = true
        linesScrollView.hasHorizontalScroller = true
        linesScrollView.autohidesScrollers = true
        linesScrollView.documentView = linesTable
    }

    private func addColumn(_ identifier: NSUserInterfaceItemIdentifier, title: String, width: CGFloat, minimumWidth: CGFloat) {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = width
        column.minWidth = minimumWidth
        column.resizingMask = [.autoresizingMask, .userResizingMask]
        linesTable.addTableColumn(column)
    }

    private func dialogueTextScrollView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = dialogueTextView
        dialogueTextView.delegate = self
        dialogueTextView.isRichText = false
        dialogueTextView.isAutomaticQuoteSubstitutionEnabled = false
        dialogueTextView.isAutomaticDashSubstitutionEnabled = false
        dialogueTextView.font = .systemFont(ofSize: NSFont.systemFontSize)
        dialogueTextView.textContainerInset = NSSize(width: 5, height: 5)
        dialogueTextView.setAccessibilityLabel("Dialogue text")
        dialogueTextView.setAccessibilityHelp("Enter the character line to save and pre-generate.")
        scroll.heightAnchor.constraint(equalToConstant: 70).isActive = true
        return scroll
    }

    private func reusableCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        if let cell = linesTable.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell.textField?.textColor = .labelColor
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.textField = label
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func helpLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.setAccessibilityHelp(text)
        return label
    }

    private func fileRow(label: NSTextField, button: NSButton) -> NSView {
        let row = NSStackView(views: [label, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 8
        return row
    }

    private func buttonRow(_ buttons: [NSButton]) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [spacer] + buttons)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func centeredRow(_ view: NSView) -> NSStackView {
        let leadingSpacer = NSView()
        let trailingSpacer = NSView()
        leadingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [leadingSpacer, view, trailingSpacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        leadingSpacer.widthAnchor.constraint(equalTo: trailingSpacer.widthAnchor).isActive = true
        return row
    }

    private func selectedLine() -> DialogueLine? {
        let row = linesTable.selectedRow
        guard row >= 0, row < lines.count else { return nil }
        return lines[row]
    }

    private func populateEditor(with line: DialogueLine) {
        dialogueTextView.string = line.text
        selectDialogueState(line.state)
        dialogueLanguageField.stringValue = line.textLanguage
        lastAppliedEditorLine = line
    }

    private func clearEditorFields() {
        dialogueTextView.string = ""
        applyDefaultDialogueState()
        applyDefaultDialogueLanguage()
    }

    private func clearSubmittedDialogueText() {
        dialogueTextView.string = ""
        lastAppliedNewDialogueState = selectedDialogueState
        lastAppliedNewDialogueLanguage = dialogueLanguageField.stringValue
    }

    private var selectedDialogueState: PetState {
        let index = dialogueStatePopup.indexOfSelectedItem
        guard PetState.allCases.indices.contains(index) else { return .idle }
        return PetState.allCases[index]
    }

    private func selectDialogueState(_ state: PetState) {
        dialogueStatePopup.selectItem(at: PetState.allCases.firstIndex(of: state) ?? 0)
    }

    private func applyDefaultDialogueState() {
        selectDialogueState(.idle)
        lastAppliedNewDialogueState = selectedDialogueState
    }

    private func applyDefaultDialogueLanguage() {
        dialogueLanguageField.stringValue = profile?.defaultTextLanguage ?? draftDefaultTextLanguage
        lastAppliedNewDialogueLanguage = dialogueLanguageField.stringValue
    }

    private var profileEditorIsDirty: Bool {
        guard let lastAppliedProfileDraft else { return false }
        return profileDraft != lastAppliedProfileDraft
    }

    private var dialogueEditorIsDirty: Bool {
        guard let line = lastAppliedEditorLine, selectedLineID == line.id else { return false }
        return dialogueTextView.string != line.text
            || selectedDialogueState != line.state
            || dialogueLanguageField.stringValue != line.textLanguage
    }

    private var newDialogueTextIsDirty: Bool {
        guard selectedLineID == nil else { return false }
        return !dialogueTextView.string.isEmpty
    }

    private var newDialogueLanguageIsDirty: Bool {
        guard selectedLineID == nil else { return false }
        return dialogueLanguageField.stringValue != lastAppliedNewDialogueLanguage
    }

    private var newDialogueStateIsDirty: Bool {
        guard selectedLineID == nil else { return false }
        return selectedDialogueState != lastAppliedNewDialogueState
    }

    private func applyProfileDraft(_ draft: DialogueVoiceProfileDraft) {
        nameField.stringValue = draft.name
        apiBaseURLField.stringValue = draft.apiBaseURL
        promptLanguageField.stringValue = draft.promptLanguage
        defaultTextLanguageField.stringValue = draft.defaultTextLanguage
        referenceTextField.stringValue = draft.referenceText
        lastAppliedProfileDraft = draft
    }

    private func applyPlaybackSettings(_ settings: DialogueVoicePlaybackSettings) {
        automaticPlaybackCheckbox.state = settings.automaticPlaybackEnabled ? .on : .off
        let volumePercent = Int((settings.volume * 100).rounded())
        voiceVolumeSlider.integerValue = volumePercent
        voiceVolumeValueLabel.stringValue = "\(volumePercent)%"
        voiceVolumeSlider.setAccessibilityValue(voiceVolumeValueLabel.stringValue)
        while repeatIntervalPopup.numberOfItems > repeatIntervalValues.count {
            repeatIntervalPopup.removeItem(at: repeatIntervalPopup.numberOfItems - 1)
        }
        if let repeatIndex = repeatIntervalValues.firstIndex(where: { candidate in
            switch (candidate, settings.repeatIntervalSeconds) {
            case (nil, nil): return true
            case let (candidate?, selected?): return candidate == selected
            default: return false
            }
        }) {
            customRepeatInterval = nil
            repeatIntervalPopup.selectItem(at: repeatIndex)
        } else if let customInterval = settings.repeatIntervalSeconds {
            customRepeatInterval = customInterval
            repeatIntervalPopup.addItem(
                withTitle: "\(Self.repeatIntervalLabel(customInterval)) (Custom)"
            )
            repeatIntervalPopup.selectItem(at: repeatIntervalPopup.numberOfItems - 1)
        }
    }

    private func validatedPlaybackSettings() -> DialogueVoicePlaybackSettings? {
        let repeatIndex = repeatIntervalPopup.indexOfSelectedItem
        let repeatInterval: TimeInterval?
        if repeatIntervalValues.indices.contains(repeatIndex) {
            repeatInterval = repeatIntervalValues[repeatIndex]
        } else if repeatIndex == repeatIntervalValues.count, let customRepeatInterval {
            repeatInterval = customRepeatInterval
        } else {
            return nil
        }
        return try? DialogueVoicePlaybackSettings(
            automaticPlaybackEnabled: automaticPlaybackCheckbox.state == .on,
            volume: min(max(voiceVolumeSlider.doubleValue / 100, 0), 1),
            repeatIntervalSeconds: repeatInterval
        )
    }

    private static func repeatIntervalLabel(_ interval: TimeInterval) -> String {
        interval.rounded() == interval
            ? "\(Int(interval))s"
            : "\(interval.formatted(.number.precision(.fractionLength(1))))s"
    }

    private func editorContentChanged(onServer line: DialogueLine) -> Bool {
        guard let lastAppliedEditorLine else { return true }
        return line.id != lastAppliedEditorLine.id
            || line.revision != lastAppliedEditorLine.revision
            || line.text != lastAppliedEditorLine.text
            || line.state != lastAppliedEditorLine.state
            || line.textLanguage != lastAppliedEditorLine.textLanguage
    }

    private func refreshButtonEnablement() {
        let draft = profileDraft
        let hasProfileFields = !draft.name.isEmpty
            && !draft.apiBaseURL.isEmpty
            && !draft.promptLanguage.isEmpty
            && !draft.defaultTextLanguage.isEmpty
            && !draft.referenceText.isEmpty
        let hasImportedAssets = importedAssets.gptWeightRelativePath != nil
            && importedAssets.sovitsWeightRelativePath != nil
            && importedAssets.referenceAudioRelativePath != nil
            && importedAssets.digests != nil
        saveProfileButton.isEnabled = hasProfileFields && hasImportedAssets
        useGPTButton.isEnabled = profile != nil && activeProviderKind != .gptSovits
        useGPTButton.isHidden = profile == nil || activeProviderKind == .gptSovits
        removeProfileButton.isEnabled = profile != nil
        importQwenButton.isEnabled = true
        useQwenButton.isEnabled = qwenProfile != nil && activeProviderKind != .qwen3TTS
        useQwenButton.isHidden = qwenProfile == nil || activeProviderKind == .qwen3TTS
        removeQwenButton.isEnabled = qwenProfile != nil
        importVoxButton.isEnabled = !voxReferenceTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        useVoxButton.isEnabled = voxProfile != nil && activeProviderKind != .voxcpm2
        useVoxButton.isHidden = voxProfile == nil || activeProviderKind == .voxcpm2
        removeVoxButton.isEnabled = voxProfile != nil

        let hasLineText = !dialogueTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasLineLanguage = !dialogueLanguageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        addLineButton.isEnabled = hasLineText && hasLineLanguage && selectedLine() == nil
        updateLineButton.isEnabled = hasLineText && hasLineLanguage && selectedLine() != nil
        clearEditorButton.isEnabled = newDialogueTextIsDirty
            || newDialogueStateIsDirty
            || newDialogueLanguageIsDirty
            || selectedLine() != nil

        let line = selectedLine()
        deleteButton.isEnabled = line != nil
        previewButton.isEnabled = line?.status == .ready
            && (profileStatus == .ready || profileStatus == .unavailable)
        retryButton.isEnabled = (line?.status == .failed || line?.status == .stale)
            && (profileStatus == .ready || profileStatus == .unavailable)
        regenerateButton.isEnabled = profileStatus == .ready
            && line.map { $0.status != .queued && $0.status != .generating } == true
    }

    private func statusTitle(_ status: DialogueGenerationStatus) -> String {
        status.rawValue.prefix(1).uppercased() + status.rawValue.dropFirst()
    }

    private func profileStatusTitle(_ status: DialogueVoiceProfileStatus) -> String {
        switch status {
        case .notConfigured: return "Not configured"
        case .validating: return "Validating"
        case .ready: return "Ready"
        case .invalid: return "Invalid — re-import required"
        case .unavailable: return "Local service unavailable"
        }
    }

    private func providerStatusTitle(
        configured: Bool,
        active: Bool,
        activeStatus: DialogueVoiceProfileStatus
    ) -> String {
        guard configured else { return "Not configured" }
        return active ? "Active · \(profileStatusTitle(activeStatus))" : "Configured"
    }

    private func safeBasename(_ path: String) -> String {
        let basename = URL(fileURLWithPath: path).lastPathComponent
        return basename.isEmpty ? "Imported file" : basename
    }

    private func applyQwenSummary(
        profile: Qwen3TTSVoiceProfile?,
        activeProviderKind: DialogueVoiceProviderKind?
    ) {
        guard let profile else {
            qwenStatusLabel.stringValue = "Not configured"
            qwenPackageLabel.stringValue = "Not imported"
            qwenRuntimeLabel.stringValue = "Not selected"
            qwenConfigurationLabel.stringValue = "Japanese zero-shot · 24 kHz PCM16"
            return
        }
        qwenStatusLabel.stringValue = providerStatusTitle(
            configured: true,
            active: activeProviderKind == .qwen3TTS,
            activeStatus: profileStatus
        )
        qwenPackageLabel.stringValue = "\(profile.name) · \(safeBasename(profile.packageRootRelativePath))"
        qwenRuntimeLabel.stringValue = safeBasename(profile.pythonExecutablePath)
        qwenConfigurationLabel.stringValue = "Japanese zero-shot · 24 kHz PCM16 · seed \(profile.seed) · temperature \(profile.temperature) · top-k \(profile.topK) · top-p \(profile.topP) · repetition \(profile.repetitionPenalty) · max \(profile.maximumTokens) tokens"
    }

    private func applyVoxSummary(profile: VoxCPM2VoiceProfile?, activeProviderKind: DialogueVoiceProviderKind?) {
        guard let profile else { voxStatusLabel.stringValue = "Not configured"; voxSnapshotLabel.stringValue = "Not selected"; voxRuntimeLabel.stringValue = "Not selected"; return }
        voxStatusLabel.stringValue = providerStatusTitle(configured: true, active: activeProviderKind == .voxcpm2, activeStatus: profileStatus)
        voxSnapshotLabel.stringValue = safeBasename(profile.snapshotPath)
        voxRuntimeLabel.stringValue = safeBasename(profile.pythonExecutablePath)
        if voxReferenceTextField.stringValue.isEmpty { voxReferenceTextField.stringValue = profile.referenceText }
    }

    @objc private func importGPTWeight() { onImportGPTWeight?(profileDraft) }
    @objc private func importSoVITSWeight() { onImportSoVITSWeight?(profileDraft) }
    @objc private func importReferenceAudio() { onImportReferenceAudio?(profileDraft) }
    @objc private func saveProfile() { onSaveProfile?(profileDraft) }
    @objc private func useGPTProfile() {
        guard profile != nil, activeProviderKind != .gptSovits else { return }
        onSelectVoiceProvider?(.gptSovits)
    }
    @objc private func removeProfile() {
        guard let profile else { return }
        onRemoveProfile?(profile)
    }
    @objc private func importQwenProfile() { onConfigureQwenProfile?() }
    @objc private func useQwenProfile() {
        guard qwenProfile != nil, activeProviderKind != .qwen3TTS else { return }
        onSelectVoiceProvider?(.qwen3TTS)
    }
    @objc private func removeQwenProfile() {
        guard let qwenProfile else { return }
        onRemoveQwenProfile?(qwenProfile)
    }
    @objc private func importVoxProfile() { onConfigureVoxCPM2Profile?(voxReferenceTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
    @objc private func useVoxProfile() { if voxProfile != nil { onSelectVoiceProvider?(.voxcpm2) } }
    @objc private func removeVoxProfile() { if let voxProfile { onRemoveVoxCPM2Profile?(voxProfile) } }
    @objc private func addLine() {
        let submittedText = dialogueTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittedLanguage = dialogueLanguageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingNewDialogueSubmission = PendingNewDialogueSubmission(
            editorText: dialogueTextView.string,
            editorState: selectedDialogueState,
            editorLanguage: dialogueLanguageField.stringValue,
            submittedText: submittedText,
            submittedState: selectedDialogueState,
            submittedLanguage: submittedLanguage,
            existingLineIDs: Set(lines.map(\.id))
        )
        onAddLine?(
            submittedText,
            submittedLanguage,
            selectedDialogueState
        )
    }
    @objc private func updateLine() {
        guard let line = selectedLine() else { return }
        onUpdateLine?(
            line,
            dialogueTextView.string.trimmingCharacters(in: .whitespacesAndNewlines),
            dialogueLanguageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            selectedDialogueState
        )
    }
    @objc private func clearEditor() {
        pendingNewDialogueSubmission = nil
        selectedLineID = nil
        lastAppliedEditorLine = nil
        linesTable.deselectAll(nil)
        clearEditorFields()
        refreshButtonEnablement()
        onClearEditor?()
    }
    @objc private func deleteLine() {
        guard let line = selectedLine() else { return }
        onDeleteLine?(line)
    }
    @objc private func previewLine() {
        guard let line = selectedLine(), line.status == .ready else { return }
        onPreviewLine?(line)
    }
    @objc private func retryLine() {
        guard let line = selectedLine(), line.status == .failed || line.status == .stale else { return }
        onRetryLine?(line)
    }
    @objc private func regenerateLine() {
        guard let line = selectedLine(), line.status != .queued, line.status != .generating else { return }
        onRegenerateLine?(line)
    }
    @objc private func playbackSettingsChanged() {
        guard !isRefreshing, let settings = validatedPlaybackSettings() else { return }
        applyPlaybackSettings(settings)
        onPlaybackSettingsChange?(settings)
    }
    @objc private func voiceSectionChanged() {
        guard let section = VoiceSection(rawValue: voiceSectionControl.selectedSegment) else { return }
        selectVoiceSection(section, userInitiated: true)
    }
    @objc private func voiceProviderChanged() {
        let provider: DialogueVoiceProviderKind = switch voiceProviderControl.selectedSegment {
        case 0: .gptSovits
        case 1: .qwen3TTS
        default: .voxcpm2
        }
        selectDisplayedProvider(provider, userInitiated: true)
    }
    @objc private func openVoiceSetup() {
        selectVoiceSection(.voiceSetup, userInitiated: true)
    }
    @objc private func dialogueStateChanged() {
        guard !isRefreshing else { return }
        refreshButtonEnablement()
    }
}
