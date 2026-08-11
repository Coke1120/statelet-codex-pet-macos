import AppKit
import CodexPetCore

struct DialogueVoiceProfileDraft: Equatable {
    var name: String
    var apiBaseURL: String
    var promptLanguage: String
    var defaultTextLanguage: String
    var referenceText: String
}

final class DialogueVoiceSettingsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    var onImportGPTWeight: ((DialogueVoiceProfileDraft) -> Void)?
    var onImportSoVITSWeight: ((DialogueVoiceProfileDraft) -> Void)?
    var onImportReferenceAudio: ((DialogueVoiceProfileDraft) -> Void)?
    var onSaveProfile: ((DialogueVoiceProfileDraft) -> Void)?
    var onRemoveProfile: ((GPTSoVITSVoiceProfile) -> Void)?
    var onAddLine: ((String, String) -> Void)?
    var onUpdateLine: ((DialogueLine, String, String) -> Void)?
    var onClearEditor: (() -> Void)?
    var onDeleteLine: ((DialogueLine) -> Void)?
    var onPreviewLine: ((DialogueLine) -> Void)?
    var onRetryLine: ((DialogueLine) -> Void)?
    var onRegenerateLine: ((DialogueLine) -> Void)?

    private enum Column {
        static let dialogue = NSUserInterfaceItemIdentifier("dialogue-voice.dialogue")
        static let language = NSUserInterfaceItemIdentifier("dialogue-voice.language")
        static let status = NSUserInterfaceItemIdentifier("dialogue-voice.status")
    }

    private let outerScrollView = NSScrollView()
    private let documentView = NSView()
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
    private let removeProfileButton = NSButton(title: "Remove Profile…", target: nil, action: nil)

    private let dialogueTextView = NSTextView()
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
    private let activityLabel = NSTextField(wrappingLabelWithString: "")

    private var profile: GPTSoVITSVoiceProfile?
    private var profileStatus: DialogueVoiceProfileStatus = .notConfigured
    private var lines: [DialogueLine] = []
    private var importedAssets = DialogueVoiceImportedAssets()
    private var draftDefaultTextLanguage = ""
    private var selectedLineID: UUID?
    private var lastAppliedProfileDraft: DialogueVoiceProfileDraft?
    private var lastAppliedEditorLine: DialogueLine?
    private var isRefreshing = false

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
        isRefreshing = true
        defer {
            isRefreshing = false
            refreshButtonEnablement()
        }

        let library = snapshot.library
        profile = library.profile
        profileStatus = library.profileStatus
        lines = library.lines
        importedAssets = snapshot.importedAssets
        draftDefaultTextLanguage = snapshot.draft.defaultTextLanguage
        if !preserveProfileEdits {
            applyProfileDraft(snapshot.draft)
        }
        gptWeightLabel.stringValue = snapshot.importedAssets.gptWeightRelativePath
            .map(safeBasename) ?? "Not imported"
        sovitsWeightLabel.stringValue = snapshot.importedAssets.sovitsWeightRelativePath
            .map(safeBasename) ?? "Not imported"
        referenceAudioLabel.stringValue = snapshot.importedAssets.referenceAudioRelativePath
            .map(safeBasename) ?? "Not imported"
        profileStatusLabel.stringValue = profileStatusTitle(library.profileStatus)

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
            clearEditorFields()
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

        let profileTitle = sectionTitle("VOICE PROFILE")
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
        let profileActions = buttonRow([saveProfileButton, removeProfileButton])

        let dialogueTitle = sectionTitle("DIALOGUE LINES")
        let dialogueHelp = helpLabel("Adding or updating a line requests background pre-generation. Playback and persistence are handled outside this view.")
        let textLabel = fieldLabel("Dialogue text")
        textLabel.setAccessibilityLabel("Dialogue text label")
        let languageRow = NSStackView(views: [fieldLabel("Text language"), dialogueLanguageField])
        languageRow.orientation = .horizontal
        languageRow.alignment = .centerY
        languageRow.spacing = 10
        let editorActions = buttonRow([addLineButton, updateLineButton, clearEditorButton])
        let selectedActions = buttonRow([deleteButton, previewButton, retryButton, regenerateButton])

        activityLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        activityLabel.textColor = .secondaryLabelColor
        activityLabel.isHidden = true
        activityLabel.setAccessibilityLabel("Dialogue voice activity")

        let contentStack = NSStackView(views: [
            profileTitle,
            profileHelp,
            profileGrid,
            profileActions,
            separator(),
            dialogueTitle,
            dialogueHelp,
            textLabel,
            dialogueTextScrollView(),
            languageRow,
            editorActions,
            linesScrollView,
            selectedActions,
            activityLabel,
        ])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .width
        contentStack.spacing = 8
        contentStack.setCustomSpacing(4, after: profileTitle)
        contentStack.setCustomSpacing(14, after: profileActions)
        contentStack.setCustomSpacing(14, after: separatorView(in: contentStack))
        documentView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 4),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -8),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 2),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -8),
            linesScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 190),
            dialogueLanguageField.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])
    }

    private func configureFields() {
        nameField.placeholderString = "Character voice"
        apiBaseURLField.placeholderString = "http://127.0.0.1:9880"
        promptLanguageField.placeholderString = "e.g. zh, yue, en, ja"
        defaultTextLanguageField.placeholderString = "e.g. zh, yue, en, ja"
        referenceTextField.placeholderString = "Transcript of the reference audio"
        dialogueLanguageField.placeholderString = "Text language"
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
    }

    private func configureButtons() {
        let actions: [(NSButton, Selector, String, String)] = [
            (importGPTButton, #selector(importGPTWeight), "Import GPT weight", "Select the trusted GPT checkpoint used by the local API."),
            (importSoVITSButton, #selector(importSoVITSWeight), "Import SoVITS weight", "Select the trusted SoVITS checkpoint used by the local API."),
            (importReferenceAudioButton, #selector(importReferenceAudio), "Import reference audio", "Select the local reference recording for this voice."),
            (saveProfileButton, #selector(saveProfile), "Save voice profile", "Save the profile fields shown above."),
            (removeProfileButton, #selector(removeProfile), "Remove voice profile", "Remove the active profile after confirmation by the app."),
            (addLineButton, #selector(addLine), "Add dialogue line", "Save this text as a new line and request pre-generation."),
            (updateLineButton, #selector(updateLine), "Update selected dialogue line", "Save changes to the selected line and request new audio."),
            (clearEditorButton, #selector(clearEditor), "Clear dialogue editor", "Clear the editor and selection without deleting a saved line."),
            (deleteButton, #selector(deleteLine), "Delete selected dialogue line", "Delete the selected line after confirmation by the app."),
            (previewButton, #selector(previewLine), "Preview selected dialogue line", "Play the selected line when generated audio is ready."),
            (retryButton, #selector(retryLine), "Retry selected dialogue line", "Retry a failed generation without creating another line."),
            (regenerateButton, #selector(regenerateLine), "Regenerate selected dialogue line", "Discard the selected line's generated result and request a fresh one."),
        ]
        for (button, action, label, help) in actions {
            button.target = self
            button.action = action
            button.setAccessibilityLabel(label)
            button.setAccessibilityHelp(help)
        }
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

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func separatorView(in stack: NSStackView) -> NSView {
        stack.arrangedSubviews.first { ($0 as? NSBox)?.boxType == .separator } ?? stack
    }

    private func selectedLine() -> DialogueLine? {
        let row = linesTable.selectedRow
        guard row >= 0, row < lines.count else { return nil }
        return lines[row]
    }

    private func populateEditor(with line: DialogueLine) {
        dialogueTextView.string = line.text
        dialogueLanguageField.stringValue = line.textLanguage
        lastAppliedEditorLine = line
    }

    private func clearEditorFields() {
        dialogueTextView.string = ""
        dialogueLanguageField.stringValue = profile?.defaultTextLanguage ?? draftDefaultTextLanguage
    }

    private var profileEditorIsDirty: Bool {
        guard let lastAppliedProfileDraft else { return false }
        return profileDraft != lastAppliedProfileDraft
    }

    private var dialogueEditorIsDirty: Bool {
        guard let line = lastAppliedEditorLine, selectedLineID == line.id else { return false }
        return dialogueTextView.string != line.text
            || dialogueLanguageField.stringValue != line.textLanguage
    }

    private func applyProfileDraft(_ draft: DialogueVoiceProfileDraft) {
        nameField.stringValue = draft.name
        apiBaseURLField.stringValue = draft.apiBaseURL
        promptLanguageField.stringValue = draft.promptLanguage
        defaultTextLanguageField.stringValue = draft.defaultTextLanguage
        referenceTextField.stringValue = draft.referenceText
        lastAppliedProfileDraft = draft
    }

    private func editorContentChanged(onServer line: DialogueLine) -> Bool {
        guard let lastAppliedEditorLine else { return true }
        return line.id != lastAppliedEditorLine.id
            || line.revision != lastAppliedEditorLine.revision
            || line.text != lastAppliedEditorLine.text
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
        removeProfileButton.isEnabled = profile != nil

        let hasLineText = !dialogueTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasLineLanguage = !dialogueLanguageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        addLineButton.isEnabled = hasLineText && hasLineLanguage && selectedLine() == nil
        updateLineButton.isEnabled = hasLineText && hasLineLanguage && selectedLine() != nil
        clearEditorButton.isEnabled = hasLineText || selectedLine() != nil

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

    private func safeBasename(_ path: String) -> String {
        let basename = URL(fileURLWithPath: path).lastPathComponent
        return basename.isEmpty ? "Imported file" : basename
    }

    @objc private func importGPTWeight() { onImportGPTWeight?(profileDraft) }
    @objc private func importSoVITSWeight() { onImportSoVITSWeight?(profileDraft) }
    @objc private func importReferenceAudio() { onImportReferenceAudio?(profileDraft) }
    @objc private func saveProfile() { onSaveProfile?(profileDraft) }
    @objc private func removeProfile() {
        guard let profile else { return }
        onRemoveProfile?(profile)
    }
    @objc private func addLine() {
        onAddLine?(
            dialogueTextView.string.trimmingCharacters(in: .whitespacesAndNewlines),
            dialogueLanguageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
    @objc private func updateLine() {
        guard let line = selectedLine() else { return }
        onUpdateLine?(
            line,
            dialogueTextView.string.trimmingCharacters(in: .whitespacesAndNewlines),
            dialogueLanguageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
    @objc private func clearEditor() {
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
}
