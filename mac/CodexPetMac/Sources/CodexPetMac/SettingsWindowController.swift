import AppKit
import CodexPetCore

struct SettingsSnapshot {
    let mediaMap: MediaMap
    let mediaMapURL: URL
    let publisherSummary: String
    let reduceMotion: Bool
    let currentState: PetState
    let preview: SettingsPreviewMetadata?
    let diagnosticsReport: String
    let launchAtLoginEnabled: Bool
    let launchAtLoginSummary: String
    let repairAvailable: Bool
    let characterProfiles: [CharacterProfileSummary]
    let activeCharacterID: String

    init(
        mediaMap: MediaMap,
        mediaMapURL: URL,
        publisherSummary: String,
        reduceMotion: Bool,
        currentState: PetState = .idle,
        preview: SettingsPreviewMetadata? = nil,
        diagnosticsReport: String = "Checking…",
        launchAtLoginEnabled: Bool = false,
        launchAtLoginSummary: String = "Checking…",
        repairAvailable: Bool = false,
        characterProfiles: [CharacterProfileSummary] = [
            CharacterProfileSummary(id: "default", name: "Default", clipCount: 0)
        ],
        activeCharacterID: String = "default"
    ) {
        self.mediaMap = mediaMap
        self.mediaMapURL = mediaMapURL
        self.publisherSummary = publisherSummary
        self.reduceMotion = reduceMotion
        self.currentState = currentState
        self.preview = preview
        self.diagnosticsReport = diagnosticsReport
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.launchAtLoginSummary = launchAtLoginSummary
        self.repairAvailable = repairAvailable
        self.characterProfiles = characterProfiles
        self.activeCharacterID = activeCharacterID
    }
}

enum SettingsActivity: Equatable {
    case idle
    case converting(PetState, String)
    case working(PetState, String)
    case applying(PetState)
    case succeeded(PetState, String)
    case failed(PetState?, String)
    case characterWorking(String)
    case characterSucceeded(String)

    var message: String? {
        switch self {
        case .idle:
            return nil
        case let .converting(_, message), let .working(_, message):
            return message
        case let .applying(state):
            return "Applying \(state.displayName) animation…"
        case let .succeeded(_, message), let .failed(_, message),
             let .characterWorking(message), let .characterSucceeded(message):
            return message
        }
    }

    var isBusy: Bool {
        switch self {
        case .converting, .working, .applying, .characterWorking: return true
        case .idle, .succeeded, .failed, .characterSucceeded: return false
        }
    }
}

struct WindowSettingsUpdate {
    let width: Double
    let height: Double
    let alwaysOnTop: Bool
    let clickThrough: Bool
    let fullScreenAuxiliary: Bool
    let appearance: PetAppearanceConfiguration
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static let defaultStateLabelCustomColor = "#007AFF"

    var onImportMP4: ((PetState) -> Void)?
    var onDropMP4s: ((PetState, [URL]) -> Void)?
    var onUseMovie: ((PetState) -> Void)?
    var onPlaybackModeChange: ((PetState, MediaPlaybackMode) -> Void)?
    var onAdvanceTriggerChange: ((PetState, MediaPlaylistAdvancePolicy) -> Void)?
    var onMoveMedia: ((PetState, String, Int) -> Void)?
    var onRelinkMedia: ((PetState, String) -> Void)?
    var onPlayOnce: ((PetState, String) -> Void)?
    var onStopPreview: (() -> Void)?
    var onSetFixed: ((PetState, String) -> Void)?
    var onChoosePoster: ((PetState, String) -> Void)?
    var onRemovePoster: ((PetState, String) -> Void)?
    var onRevealMedia: ((PetState, String) -> Void)?
    var onRemoveMedia: ((PetState, String, ManagedMediaRemovalMode) -> Void)?
    var onRevealMediaFolder: (() -> Void)?
    var onRevealMap: (() -> Void)?
    var onRevealLogs: (() -> Void)?
    var onRevealApp: (() -> Void)?
    var onCheckTools: (() -> Void)?
    var onChoosePython: (() -> Void)?
    var onCancelConversion: (() -> Void)?
    var onRetryFailedMP4s: (() -> Void)?
    var onConversionProfileChange: ((AlphaConversionProfile) -> Void)?
    var onWindowSettingsChange: ((WindowSettingsUpdate) -> Void)?
    var onResetPosition: (() -> Void)?
    var onRefreshDiagnostics: (() -> Void)?
    var onRepairInstallation: (() -> Void)?
    var onLaunchAtLoginChange: ((Bool) -> Void)?
    var onCleanUnusedMedia: (() -> Void)?
    var onImportVoiceAsset: ((DialogueVoiceAssetKind, DialogueVoiceProfileDraft) -> Void)?
    var onSaveVoiceProfile: ((DialogueVoiceProfileDraft) -> Void)?
    var onRemoveVoiceProfile: ((GPTSoVITSVoiceProfile) -> Void)?
    var onConfigureQwenProfile: (() -> Void)?
    var onSelectVoiceProvider: ((DialogueVoiceProviderKind) -> Void)?
    var onRemoveQwenProfile: ((Qwen3TTSVoiceProfile) -> Void)?
    var onAddDialogueLine: ((String, String, PetState) -> Void)?
    var onUpdateDialogueLine: ((DialogueLine, String, String, PetState) -> Void)?
    var onDeleteDialogueLine: ((DialogueLine) -> Void)?
    var onPreviewDialogueLine: ((DialogueLine) -> Void)?
    var onRetryDialogueLine: ((DialogueLine) -> Void)?
    var onRegenerateDialogueLine: ((DialogueLine) -> Void)?
    var onDialogueVoicePlaybackSettingsChange: ((DialogueVoicePlaybackSettings) -> Void)?
    var onCharacterSelection: ((String) -> Void)?
    var onCreateCharacter: ((String) -> Void)?
    var onRenameCharacter: ((String, String) -> Void)?
    var onDuplicateCharacter: ((String, String) -> Void)?
    var onDeleteCharacter: ((String) -> Void)?
    var onImportCharacterBundle: (() -> Void)?
    var onExportCharacterBundle: ((String) -> Void)?

    private let tabs = NSSegmentedControl(labels: ["Animations", "Voice", "Appearance", "General", "Diagnostics", "Prompts", "Recommendation"], trackingMode: .selectOne, target: nil, action: nil)
    private let paneHost = NSView()
    private let animationsPane = NSView()
    private let dialogueVoiceView = DialogueVoiceSettingsView()
    private let appearancePane = NSView()
    private let generalPane = NSView()
    private let diagnosticsPane = NSView()
    private let helpPane = NSView()
    private let recommendationPane = NSView()
    private let publisherLabel = NSTextField(labelWithString: "Lifecycle status: Checking")
    private let characterSelector = CharacterProfileSelectorView()
    private let toolsLabel = NSTextField(labelWithString: "Checking conversion tools…")
    private let checkToolsButton = NSButton(title: "Check Again", target: nil, action: nil)
    private let setupButton = NSButton(title: "Setup Guide", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel Conversion", target: nil, action: nil)
    private let retryFailedButton = NSButton(title: "Retry Failed", target: nil, action: nil)
    private let conversionProfilePopup = NSPopUpButton()
    private let progress = NSProgressIndicator()
    private let progressPercentLabel = NSTextField(labelWithString: "0%")
    private let activityLabel = NSTextField(wrappingLabelWithString: "")
    private let activityRow = NSStackView()
    private let sizeSlider = NSSlider(value: 320, minValue: 160, maxValue: 640, target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: "320 × 480 pt")
    private let alwaysOnTopCheckbox = NSButton(checkboxWithTitle: "Keep Statelet on Top", target: nil, action: nil)
    private let clickThroughCheckbox = NSButton(checkboxWithTitle: "Let clicks pass through the pet", target: nil, action: nil)
    private let fullScreenCheckbox = NSButton(checkboxWithTitle: "Show pet over full-screen apps", target: nil, action: nil)
    private let backgroundEnabledCheckbox = NSButton(checkboxWithTitle: "Show translucent background", target: nil, action: nil)
    private let backgroundColorWell = NSColorWell()
    private let backgroundOpacitySlider = NSSlider(value: 28, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let backgroundOpacityLabel = NSTextField(labelWithString: "28%")
    private let cornerRadiusSlider = NSSlider(value: 22, minValue: 0, maxValue: 256, target: nil, action: nil)
    private let cornerRadiusLabel = NSTextField(labelWithString: "22 pt")
    private let borderEnabledCheckbox = NSButton(checkboxWithTitle: "Show border", target: nil, action: nil)
    private let borderColorWell = NSColorWell()
    private let borderOpacitySlider = NSSlider(value: 24, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let borderOpacityLabel = NSTextField(labelWithString: "24%")
    private let borderWidthSlider = NSSlider(value: 1, minValue: 0, maxValue: 12, target: nil, action: nil)
    private let borderWidthLabel = NSTextField(labelWithString: "1.0 pt")
    private let stateLabelEnabledCheckbox = NSButton(checkboxWithTitle: "Show current Codex state", target: nil, action: nil)
    private let stateLabelAutomaticColorCheckbox = NSButton(checkboxWithTitle: "Automatic color by state", target: nil, action: nil)
    private let stateLabelColorWell = NSColorWell()
    private let stateLabelPositionPopup = NSPopUpButton()
    private let stateLabelSizePopup = NSPopUpButton()
    private let fpsEnabledCheckbox = NSButton(checkboxWithTitle: "Show video FPS", target: nil, action: nil)
    private let fpsColorWell = NSColorWell()
    private let fpsSizePopup = NSPopUpButton()
    private let reduceMotionLabel = NSTextField(labelWithString: "Reduce Motion: Checking")
    private let helpStatePopup = NSPopUpButton()
    private let helpPromptTextView = NSTextView()
    private let diagnosticsTextView = NSTextView()
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Start Statelet when I log in", target: nil, action: nil)
    private let launchAtLoginLabel = NSTextField(wrappingLabelWithString: "Checking…")
    private let repairButton = NSButton(title: "Repair Startup…", target: nil, action: nil)
    private let animationLibrary = AnimationLibraryView()
    private var snapshot: SettingsSnapshot?
    private var selectedAnimationState: PetState = .idle
    private var toolchainState: AlphaToolchainState = .checking
    private var activity: SettingsActivity = .idle
    private var libraryRevisionTimer: Timer?
    private var aspectRatio = 1.5
    private let stateLabelPositions: [StateLabelPosition] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
    private let stateLabelSizes: [StateLabelSize] = [.small, .regular, .large]

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Statelet Settings"
        window.minSize = NSSize(width: 720, height: 610)
        window.contentMinSize = NSSize(width: 700, height: 570)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildInterface()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        if let window, window.contentLayoutRect.width < 700 || window.contentLayoutRect.height < 570 {
            window.setContentSize(NSSize(width: 760, height: 650))
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        animationLibrary.invalidateRowCache()
        refreshRows()
        startLibraryRevisionTimer()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func update(snapshot: SettingsSnapshot) {
        self.snapshot = snapshot
        publisherLabel.stringValue = snapshot.publisherSummary
        publisherLabel.setAccessibilityLabel(snapshot.publisherSummary)
        reduceMotionLabel.stringValue = snapshot.reduceMotion
            ? "Reduce Motion: On — static posters are shown"
            : "Reduce Motion: Off — animations are shown"
        let configuration = snapshot.mediaMap.window
        aspectRatio = configuration.height / configuration.width
        sizeSlider.minValue = min(160, configuration.width)
        sizeSlider.maxValue = max(640, configuration.width)
        sizeSlider.doubleValue = configuration.width
        sizeLabel.stringValue = sizeDescription(width: configuration.width, height: configuration.height)
        alwaysOnTopCheckbox.state = configuration.alwaysOnTop ? .on : .off
        clickThroughCheckbox.state = configuration.clickThrough ? .on : .off
        fullScreenCheckbox.state = configuration.fullScreenAuxiliary ? .on : .off
        updateAppearanceControls(configuration.appearance)
        refreshRows()
        diagnosticsTextView.string = snapshot.diagnosticsReport
        launchAtLoginCheckbox.state = snapshot.launchAtLoginEnabled ? .on : .off
        launchAtLoginLabel.stringValue = snapshot.launchAtLoginSummary
        repairButton.isEnabled = snapshot.repairAvailable
        updateCharacterSelector()
    }

    func update(toolchainState: AlphaToolchainState) {
        self.toolchainState = toolchainState
        switch toolchainState {
        case .checking:
            toolsLabel.stringValue = "Checking conversion tools…"
            toolsLabel.textColor = .secondaryLabelColor
            checkToolsButton.isEnabled = false
            setupButton.isHidden = true
        case let .ready(toolchain):
            toolsLabel.stringValue = "Conversion tools \(toolchain.summary)"
            toolsLabel.textColor = .systemGreen
            checkToolsButton.isEnabled = true
            setupButton.isHidden = true
        case let .unavailable(reason):
            toolsLabel.stringValue = "Conversion unavailable — \(reason)"
            toolsLabel.textColor = .systemOrange
            checkToolsButton.isEnabled = true
            setupButton.isHidden = false
        }
        conversionProfilePopup.isEnabled = toolchainState.isReady && !activity.isBusy
        refreshRows()
    }

    func update(conversionProfile: AlphaConversionProfile) {
        if let index = conversionProfilePopup.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == conversionProfile.rawValue
        }) {
            conversionProfilePopup.selectItem(at: index)
        } else {
            conversionProfilePopup.selectItem(at: 0)
        }
    }

    func update(dialogueVoice snapshot: DialogueVoiceCoordinatorSnapshot) {
        dialogueVoiceView.update(snapshot: snapshot)
    }

    func update(
        activity: SettingsActivity,
        progressValue: Double? = nil,
        retryFailedAvailable: Bool = false
    ) {
        self.activity = activity
        let isConverting: Bool
        let isCancelable: Bool
        switch activity {
        case .converting:
            isConverting = true
            isCancelable = true
        case .working, .applying, .characterWorking:
            isConverting = true
            isCancelable = false
        case .idle, .succeeded, .failed, .characterSucceeded:
            isConverting = false
            isCancelable = false
        }
        activityLabel.stringValue = activity.message ?? ""
        activityLabel.toolTip = activity.message
        activityLabel.setAccessibilityHelp(activity.message)
        activityRow.isHidden = activity.message == nil
        progress.isHidden = !isConverting
        progressPercentLabel.isHidden = true
        cancelButton.isHidden = !isCancelable
        retryFailedButton.isHidden = !retryFailedAvailable || isConverting
        conversionProfilePopup.isEnabled = toolchainState.isReady && !isConverting
        if isConverting {
            if let progressValue, progressValue.isFinite {
                progress.isIndeterminate = false
                progress.doubleValue = min(100, max(0, progressValue))
                progressPercentLabel.stringValue = "\(Int(progress.doubleValue.rounded()))%"
                progressPercentLabel.isHidden = false
                progress.setAccessibilityValue(progressPercentLabel.stringValue)
                progress.stopAnimation(nil)
            } else {
                progress.isIndeterminate = true
                progress.setAccessibilityValue("In progress")
                progress.startAnimation(nil)
            }
        } else {
            progress.stopAnimation(nil)
        }
        switch activity {
        case .failed:
            activityLabel.textColor = .systemRed
        case .succeeded, .characterSucceeded:
            activityLabel.textColor = .systemGreen
        case .idle, .converting, .working, .applying, .characterWorking:
            activityLabel.textColor = .secondaryLabelColor
        }
        updateCharacterSelector()
        refreshRows()
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.selectedSegment = 0
        tabs.segmentDistribution = .fillEqually
        tabs.target = self
        tabs.action = #selector(changePane)
        tabs.setAccessibilityLabel("Settings section")
        paneHost.translatesAutoresizingMaskIntoConstraints = false
        animationsPane.translatesAutoresizingMaskIntoConstraints = false
        dialogueVoiceView.translatesAutoresizingMaskIntoConstraints = false
        appearancePane.translatesAutoresizingMaskIntoConstraints = false
        generalPane.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsPane.translatesAutoresizingMaskIntoConstraints = false
        helpPane.translatesAutoresizingMaskIntoConstraints = false
        recommendationPane.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabs)
        contentView.addSubview(paneHost)
        paneHost.addSubview(animationsPane)
        paneHost.addSubview(dialogueVoiceView)
        paneHost.addSubview(appearancePane)
        paneHost.addSubview(generalPane)
        paneHost.addSubview(diagnosticsPane)
        paneHost.addSubview(helpPane)
        paneHost.addSubview(recommendationPane)
        for pane in [animationsPane, dialogueVoiceView, appearancePane, generalPane, diagnosticsPane, helpPane, recommendationPane] {
            NSLayoutConstraint.activate([
                pane.leadingAnchor.constraint(equalTo: paneHost.leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: paneHost.trailingAnchor),
                pane.topAnchor.constraint(equalTo: paneHost.topAnchor),
                pane.bottomAnchor.constraint(equalTo: paneHost.bottomAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            tabs.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            tabs.widthAnchor.constraint(equalToConstant: 680),
            paneHost.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 14),
            paneHost.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            paneHost.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            paneHost.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
        ])
        buildAnimationsPane()
        configureDialogueVoicePane()
        buildAppearancePane()
        buildGeneralPane()
        buildDiagnosticsPane()
        buildHelpPane()
        buildRecommendationPane()
        changePane()
    }

    private func buildAnimationsPane() {
        publisherLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        publisherLabel.translatesAutoresizingMaskIntoConstraints = false
        let statusBox = NSBox()
        statusBox.translatesAutoresizingMaskIntoConstraints = false
        statusBox.boxType = .custom
        statusBox.cornerRadius = 8
        statusBox.borderColor = .separatorColor
        statusBox.fillColor = .controlBackgroundColor
        let characterLabel = NSTextField(labelWithString: "ACTIVE CHARACTER")
        characterLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        characterLabel.textColor = .secondaryLabelColor
        characterLabel.setContentHuggingPriority(.required, for: .horizontal)
        characterSelector.onSelectProfile = { [weak self] id in self?.onCharacterSelection?(id) }
        characterSelector.onNewCharacter = { [weak self] in self?.promptForNewCharacter() }
        characterSelector.onRenameActive = { [weak self] in self?.promptForCharacterRename() }
        characterSelector.onDuplicateActive = { [weak self] in self?.promptForCharacterDuplicate() }
        characterSelector.onDeleteActive = { [weak self] id in self?.confirmCharacterDeletion(id: id) }
        characterSelector.onImportBundle = { [weak self] in self?.onImportCharacterBundle?() }
        characterSelector.onExportActive = { [weak self] in
            guard let id = self?.snapshot?.activeCharacterID else { return }
            self?.onExportCharacterBundle?(id)
        }
        let characterStack = NSStackView(views: [characterLabel, characterSelector])
        characterStack.orientation = .horizontal
        characterStack.alignment = .centerY
        characterStack.spacing = 7
        characterStack.translatesAutoresizingMaskIntoConstraints = false
        publisherLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let statusRow = NSStackView(views: [characterStack, publisherLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.distribution = .fill
        statusRow.spacing = 12
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusBox.contentView?.addSubview(statusRow)
        if let content = statusBox.contentView {
            NSLayoutConstraint.activate([
                statusRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                statusRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
                statusRow.centerYAnchor.constraint(equalTo: content.centerYAnchor),
                characterSelector.widthAnchor.constraint(greaterThanOrEqualToConstant: 214),
            ])
        }
        statusBox.heightAnchor.constraint(equalToConstant: 42).isActive = true

        animationLibrary.onStateSelection = { [weak self] state in
            self?.selectedAnimationState = state
            self?.refreshRows()
        }
        animationLibrary.onModeChange = { [weak self] mode in
            guard let self else { return }
            self.onPlaybackModeChange?(self.selectedAnimationState, mode)
        }
        animationLibrary.onAdvanceTriggerChange = { [weak self] trigger in
            guard let self else { return }
            self.onAdvanceTriggerChange?(self.selectedAnimationState, trigger)
        }
        animationLibrary.onImportMP4 = { [weak self] in
            guard let self else { return }
            self.onImportMP4?(self.selectedAnimationState)
        }
        animationLibrary.onDropMP4s = { [weak self] urls in
            guard let self else { return }
            self.onDropMP4s?(self.selectedAnimationState, urls)
        }
        animationLibrary.onUseMovie = { [weak self] in
            guard let self else { return }
            self.onUseMovie?(self.selectedAnimationState)
        }
        animationLibrary.onPlayOrStop = { [weak self] entry, shouldStop in
            guard let self else { return }
            if shouldStop {
                self.onStopPreview?()
            } else {
                self.onPlayOnce?(self.selectedAnimationState, entry.path)
            }
        }
        animationLibrary.onMore = { [weak self] entry, sender in
            self?.showClipActions(for: entry, relativeTo: sender)
        }
        animationLibrary.onRemove = { [weak self] entry in
            guard let self else { return }
            self.confirmClipRemoval(state: self.selectedAnimationState, path: entry.path)
        }

        toolsLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        toolsLabel.lineBreakMode = .byTruncatingTail
        toolsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        checkToolsButton.target = self
        checkToolsButton.action = #selector(checkTools)
        checkToolsButton.controlSize = .small
        setupButton.target = self
        setupButton.action = #selector(showSetupGuide)
        setupButton.controlSize = .small
        setupButton.isHidden = true
        cancelButton.target = self
        cancelButton.action = #selector(cancelConversion)
        cancelButton.controlSize = .small
        cancelButton.isHidden = true
        retryFailedButton.target = self
        retryFailedButton.action = #selector(retryFailedMP4s)
        retryFailedButton.controlSize = .small
        retryFailedButton.isHidden = true
        for profile in AlphaConversionProfile.allCases {
            conversionProfilePopup.addItem(withTitle: profile.displayName)
            conversionProfilePopup.lastItem?.representedObject = profile.rawValue
        }
        conversionProfilePopup.target = self
        conversionProfilePopup.action = #selector(conversionProfileChanged)
        conversionProfilePopup.controlSize = .small
        conversionProfilePopup.setAccessibilityLabel("MP4 framing profile")
        conversionProfilePopup.toolTip = "Choose whether MP4s crop to the 320 × 480 canvas or fit inside it with transparent padding."
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 100
        progress.isIndeterminate = false
        progress.isHidden = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.widthAnchor.constraint(equalToConstant: 150).isActive = true
        progress.setAccessibilityLabel("Current operation progress")
        progressPercentLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .medium
        )
        progressPercentLabel.alignment = .right
        progressPercentLabel.isHidden = true
        progressPercentLabel.widthAnchor.constraint(equalToConstant: 38).isActive = true
        activityLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        activityLabel.textColor = .secondaryLabelColor
        activityLabel.lineBreakMode = .byWordWrapping
        activityLabel.maximumNumberOfLines = 2
        activityLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let showFolder = NSButton(title: "Show Media Folder", target: self, action: #selector(revealMediaFolder))
        showFolder.controlSize = .small
        let toolsRow = NSStackView(views: [showFolder, toolsLabel, conversionProfilePopup, setupButton, checkToolsButton])
        toolsRow.orientation = .horizontal
        toolsRow.alignment = .centerY
        toolsRow.spacing = 8
        for view in [progress, progressPercentLabel, activityLabel, cancelButton, retryFailedButton] {
            activityRow.addArrangedSubview(view)
        }
        activityRow.orientation = .horizontal
        activityRow.alignment = .centerY
        activityRow.spacing = 8
        activityRow.isHidden = true
        let footer = NSStackView(views: [toolsRow, activityRow])
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 6
        toolsRow.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        activityRow.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true

        animationsPane.addSubview(statusBox)
        animationsPane.addSubview(animationLibrary)
        animationsPane.addSubview(footer)
        NSLayoutConstraint.activate([
            statusBox.topAnchor.constraint(equalTo: animationsPane.topAnchor),
            statusBox.leadingAnchor.constraint(equalTo: animationsPane.leadingAnchor),
            statusBox.trailingAnchor.constraint(equalTo: animationsPane.trailingAnchor),
            animationLibrary.topAnchor.constraint(equalTo: statusBox.bottomAnchor, constant: 10),
            animationLibrary.leadingAnchor.constraint(equalTo: animationsPane.leadingAnchor),
            animationLibrary.trailingAnchor.constraint(equalTo: animationsPane.trailingAnchor),
            footer.topAnchor.constraint(equalTo: animationLibrary.bottomAnchor, constant: 10),
            footer.leadingAnchor.constraint(equalTo: animationsPane.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: animationsPane.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: animationsPane.bottomAnchor),
        ])
    }

    private func configureDialogueVoicePane() {
        dialogueVoiceView.onImportGPTWeight = { [weak self] draft in
            self?.onImportVoiceAsset?(.gptWeight, draft)
        }
        dialogueVoiceView.onImportSoVITSWeight = { [weak self] draft in
            self?.onImportVoiceAsset?(.sovitsWeight, draft)
        }
        dialogueVoiceView.onImportReferenceAudio = { [weak self] draft in
            self?.onImportVoiceAsset?(.referenceAudio, draft)
        }
        dialogueVoiceView.onSaveProfile = { [weak self] draft in
            self?.onSaveVoiceProfile?(draft)
        }
        dialogueVoiceView.onRemoveProfile = { [weak self] profile in
            self?.onRemoveVoiceProfile?(profile)
        }
        dialogueVoiceView.onConfigureQwenProfile = { [weak self] in
            self?.onConfigureQwenProfile?()
        }
        dialogueVoiceView.onSelectVoiceProvider = { [weak self] provider in
            self?.onSelectVoiceProvider?(provider)
        }
        dialogueVoiceView.onRemoveQwenProfile = { [weak self] profile in
            self?.onRemoveQwenProfile?(profile)
        }
        dialogueVoiceView.onAddLine = { [weak self] text, language, state in
            self?.onAddDialogueLine?(text, language, state)
        }
        dialogueVoiceView.onUpdateLine = { [weak self] line, text, language, state in
            self?.onUpdateDialogueLine?(line, text, language, state)
        }
        dialogueVoiceView.onDeleteLine = { [weak self] line in
            self?.onDeleteDialogueLine?(line)
        }
        dialogueVoiceView.onPreviewLine = { [weak self] line in
            self?.onPreviewDialogueLine?(line)
        }
        dialogueVoiceView.onRetryLine = { [weak self] line in
            self?.onRetryDialogueLine?(line)
        }
        dialogueVoiceView.onRegenerateLine = { [weak self] line in
            self?.onRegenerateDialogueLine?(line)
        }
        dialogueVoiceView.onPlaybackSettingsChange = { [weak self] settings in
            self?.onDialogueVoicePlaybackSettingsChange?(settings)
        }
    }

    private func buildAppearancePane() {
        backgroundEnabledCheckbox.target = self
        backgroundEnabledCheckbox.action = #selector(appearanceChanged)
        backgroundColorWell.target = self
        backgroundColorWell.action = #selector(appearanceChanged)
        if #available(macOS 14.0, *) {
            backgroundColorWell.supportsAlpha = false
        }
        backgroundColorWell.setAccessibilityLabel("Pet background color")
        backgroundOpacitySlider.target = self
        backgroundOpacitySlider.action = #selector(appearanceChanged)
        backgroundOpacitySlider.isContinuous = false
        backgroundOpacitySlider.setAccessibilityLabel("Pet background opacity")
        cornerRadiusSlider.target = self
        cornerRadiusSlider.action = #selector(appearanceChanged)
        cornerRadiusSlider.isContinuous = false
        cornerRadiusSlider.setAccessibilityLabel("Pet corner radius")
        for label in [backgroundOpacityLabel, cornerRadiusLabel] {
            label.alignment = .right
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        }
        let surfaceStack = NSStackView(views: [
            backgroundEnabledCheckbox,
            makeAppearanceRow(title: "Color", control: backgroundColorWell),
            makeAppearanceRow(title: "Opacity", control: backgroundOpacitySlider, value: backgroundOpacityLabel),
            makeAppearanceRow(title: "Corner radius", control: cornerRadiusSlider, value: cornerRadiusLabel),
        ])
        surfaceStack.orientation = .vertical
        surfaceStack.alignment = .leading
        surfaceStack.spacing = 9
        let surfaceBox = makeSection(title: "Surface", content: surfaceStack)

        borderEnabledCheckbox.target = self
        borderEnabledCheckbox.action = #selector(appearanceChanged)
        borderColorWell.target = self
        borderColorWell.action = #selector(appearanceChanged)
        if #available(macOS 14.0, *) {
            borderColorWell.supportsAlpha = false
        }
        borderColorWell.setAccessibilityLabel("Pet border color")
        borderOpacitySlider.target = self
        borderOpacitySlider.action = #selector(appearanceChanged)
        borderOpacitySlider.isContinuous = false
        borderOpacitySlider.setAccessibilityLabel("Pet border opacity")
        borderWidthSlider.target = self
        borderWidthSlider.action = #selector(appearanceChanged)
        borderWidthSlider.isContinuous = false
        borderWidthSlider.setAccessibilityLabel("Pet border width")
        for label in [borderOpacityLabel, borderWidthLabel] {
            label.alignment = .right
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        }
        let borderStack = NSStackView(views: [
            borderEnabledCheckbox,
            makeAppearanceRow(title: "Color", control: borderColorWell),
            makeAppearanceRow(title: "Opacity", control: borderOpacitySlider, value: borderOpacityLabel),
            makeAppearanceRow(title: "Width", control: borderWidthSlider, value: borderWidthLabel),
        ])
        borderStack.orientation = .vertical
        borderStack.alignment = .leading
        borderStack.spacing = 9
        let borderBox = makeSection(title: "Border", content: borderStack)

        stateLabelEnabledCheckbox.target = self
        stateLabelEnabledCheckbox.action = #selector(appearanceChanged)
        stateLabelAutomaticColorCheckbox.target = self
        stateLabelAutomaticColorCheckbox.action = #selector(appearanceChanged)
        stateLabelColorWell.target = self
        stateLabelColorWell.action = #selector(appearanceChanged)
        stateLabelColorWell.color = NSColor.codexPet(hex: Self.defaultStateLabelCustomColor)
        if #available(macOS 14.0, *) {
            stateLabelColorWell.supportsAlpha = false
        }
        stateLabelColorWell.setAccessibilityLabel("Custom current state label color")
        stateLabelPositionPopup.addItems(withTitles: stateLabelPositions.map(\.displayName))
        stateLabelPositionPopup.target = self
        stateLabelPositionPopup.action = #selector(appearanceChanged)
        stateLabelPositionPopup.setAccessibilityLabel("Current state label position")
        stateLabelSizePopup.addItems(withTitles: stateLabelSizes.map(\.displayName))
        stateLabelSizePopup.target = self
        stateLabelSizePopup.action = #selector(appearanceChanged)
        stateLabelSizePopup.setAccessibilityLabel("Current state label size")
        let badgeHelp = NSTextField(wrappingLabelWithString: "The badge shows the requested Codex lifecycle state. Offline or stale publisher data is labeled clearly instead of pretending to be live Idle.")
        badgeHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        badgeHelp.textColor = .secondaryLabelColor
        let badgeStack = NSStackView(views: [
            stateLabelEnabledCheckbox,
            stateLabelAutomaticColorCheckbox,
            makeAppearanceRow(title: "Custom color", control: stateLabelColorWell),
            makeAppearanceRow(title: "Position", control: stateLabelPositionPopup),
            makeAppearanceRow(title: "Size", control: stateLabelSizePopup),
            badgeHelp,
        ])
        badgeStack.orientation = .vertical
        badgeStack.alignment = .leading
        badgeStack.spacing = 9
        let badgeBox = makeSection(title: "Current State Label", content: badgeStack)

        fpsEnabledCheckbox.target = self
        fpsEnabledCheckbox.action = #selector(appearanceChanged)
        fpsColorWell.target = self
        fpsColorWell.action = #selector(appearanceChanged)
        if #available(macOS 14.0, *) {
            fpsColorWell.supportsAlpha = false
        }
        fpsColorWell.setAccessibilityLabel("FPS label color")
        fpsSizePopup.addItems(withTitles: stateLabelSizes.map(\.displayName))
        fpsSizePopup.target = self
        fpsSizePopup.action = #selector(appearanceChanged)
        fpsSizePopup.setAccessibilityLabel("FPS label size")
        let fpsHelp = NSTextField(wrappingLabelWithString: "Shows intended playback FPS at the top-right edge. When playback rate changes it also shows the source nominal FPS; this is not measured rendered FPS. Static Reduce Motion posters are labeled Still.")
        fpsHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        fpsHelp.textColor = .secondaryLabelColor
        let fpsStack = NSStackView(views: [
            fpsEnabledCheckbox,
            makeAppearanceRow(title: "Color", control: fpsColorWell),
            makeAppearanceRow(title: "Size", control: fpsSizePopup),
            fpsHelp,
        ])
        fpsStack.orientation = .vertical
        fpsStack.alignment = .leading
        fpsStack.spacing = 9
        let fpsBox = makeSection(title: "Playback FPS", content: fpsStack)

        let reset = NSButton(title: "Reset Appearance", target: self, action: #selector(resetAppearance))
        reset.controlSize = .small
        let surfaceRow = NSStackView(views: [surfaceBox, borderBox])
        surfaceRow.orientation = .horizontal
        surfaceRow.alignment = .top
        surfaceRow.distribution = .fillEqually
        surfaceRow.spacing = 12
        let overlayRow = NSStackView(views: [badgeBox, fpsBox])
        overlayRow.orientation = .horizontal
        overlayRow.alignment = .top
        overlayRow.distribution = .fillEqually
        overlayRow.spacing = 12
        let stack = NSStackView(views: [surfaceRow, overlayRow, reset])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        appearancePane.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: appearancePane.topAnchor),
            stack.leadingAnchor.constraint(equalTo: appearancePane.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: appearancePane.trailingAnchor),
            surfaceRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            overlayRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: appearancePane.bottomAnchor),
        ])
    }

    private func buildGeneralPane() {
        let sizeTitle = NSTextField(labelWithString: "Pet size")
        sizeTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged)
        sizeSlider.isContinuous = false
        sizeSlider.setAccessibilityLabel("Pet width")
        sizeLabel.alignment = .right
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let resetSize = NSButton(title: "Reset Size", target: self, action: #selector(resetSize))
        resetSize.controlSize = .small
        let sizeControls = NSStackView(views: [sizeSlider, sizeLabel, resetSize])
        sizeControls.orientation = .horizontal
        sizeControls.alignment = .centerY
        sizeControls.spacing = 10

        for checkbox in [alwaysOnTopCheckbox, clickThroughCheckbox, fullScreenCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(windowOptionChanged)
        }
        alwaysOnTopCheckbox.toolTip = "Turn this off to let other app windows cover Statelet."
        alwaysOnTopCheckbox.setAccessibilityHelp("Turn this off to let other app windows cover Statelet.")
        let alwaysOnTopHelp = NSTextField(
            wrappingLabelWithString: "When off, other app windows can cover Statelet. You can also change this from the pet's right-click menu or the menu-bar icon."
        )
        alwaysOnTopHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        alwaysOnTopHelp.textColor = .secondaryLabelColor
        let clickHelp = NSTextField(wrappingLabelWithString: "Right-click the pet for its menu. When click-through is on, use the Statelet menu-bar icon to turn it off again.")
        clickHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        clickHelp.textColor = .secondaryLabelColor
        let resetPosition = NSButton(title: "Reset Position", target: self, action: #selector(resetPositionAction))
        resetPosition.alignment = .left

        let petWindowStack = NSStackView(views: [sizeTitle, sizeControls, alwaysOnTopCheckbox, alwaysOnTopHelp, clickThroughCheckbox, clickHelp, fullScreenCheckbox, resetPosition])
        petWindowStack.orientation = .vertical
        petWindowStack.alignment = .leading
        petWindowStack.spacing = 9
        let petWindowBox = makeSection(title: "Pet Window", content: petWindowStack)

        reduceMotionLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        let openAccessibility = NSButton(title: "Open Accessibility Settings…", target: self, action: #selector(openAccessibilitySettings))
        let motionStack = NSStackView(views: [reduceMotionLabel, openAccessibility])
        motionStack.orientation = .vertical
        motionStack.alignment = .leading
        motionStack.spacing = 10
        let motionBox = makeSection(title: "Motion", content: motionStack)

        let revealMedia = NSButton(title: "Show Media Folder", target: self, action: #selector(revealMediaFolder))
        let revealMap = NSButton(title: "Show Media Map", target: self, action: #selector(revealMap))
        let revealLogs = NSButton(title: "Show Logs Folder", target: self, action: #selector(revealLogs))
        let revealApp = NSButton(title: "Show App in Finder", target: self, action: #selector(revealApp))
        let localButtons = NSStackView(views: [revealApp, revealMedia, revealMap, revealLogs])
        localButtons.orientation = .horizontal
        localButtons.spacing = 8
        let launchHelp = NSTextField(wrappingLabelWithString: "Open Statelet from Finder → Home → Applications. The installed app starts at login and intentionally uses the menu bar instead of a Dock icon.")
        launchHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        launchHelp.textColor = .secondaryLabelColor
        let localStack = NSStackView(views: [launchHelp, localButtons])
        localStack.orientation = .vertical
        localStack.alignment = .leading
        localStack.spacing = 9
        let localBox = makeSection(title: "App and Local Data", content: localStack)

        let stack = NSStackView(views: [petWindowBox, motionBox, localBox])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        generalPane.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: generalPane.topAnchor),
            stack.leadingAnchor.constraint(equalTo: generalPane.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: generalPane.trailingAnchor),
            petWindowBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            motionBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            localBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func buildDiagnosticsPane() {
        let title = NSTextField(labelWithString: "Diagnostics and Repair")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let introduction = NSTextField(wrappingLabelWithString: "Review the local lifecycle publisher, media library, conversion tools, and startup installation without exposing prompt or session content.")
        introduction.textColor = .secondaryLabelColor

        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(launchAtLoginChanged)
        launchAtLoginLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        launchAtLoginLabel.textColor = .secondaryLabelColor
        let loginStack = NSStackView(views: [launchAtLoginCheckbox, launchAtLoginLabel])
        loginStack.orientation = .vertical
        loginStack.alignment = .leading
        loginStack.spacing = 5
        let loginBox = makeSection(title: "Startup", content: loginStack)

        diagnosticsTextView.isEditable = false
        diagnosticsTextView.isSelectable = true
        diagnosticsTextView.isRichText = false
        diagnosticsTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        diagnosticsTextView.textColor = .labelColor
        diagnosticsTextView.backgroundColor = .textBackgroundColor
        diagnosticsTextView.textContainerInset = NSSize(width: 10, height: 10)
        diagnosticsTextView.frame = NSRect(x: 0, y: 0, width: 680, height: 260)
        diagnosticsTextView.minSize = NSSize(width: 0, height: 260)
        diagnosticsTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        diagnosticsTextView.isVerticallyResizable = true
        diagnosticsTextView.isHorizontallyResizable = false
        diagnosticsTextView.autoresizingMask = [.width]
        diagnosticsTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        diagnosticsTextView.textContainer?.widthTracksTextView = true
        diagnosticsTextView.setAccessibilityLabel("Statelet diagnostics report")
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = diagnosticsTextView

        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshDiagnostics))
        let copy = NSButton(title: "Copy Diagnostics", target: self, action: #selector(copyDiagnostics))
        repairButton.target = self
        repairButton.action = #selector(repairInstallation)
        repairButton.isEnabled = false
        let revealLogs = NSButton(title: "Reveal Logs", target: self, action: #selector(revealLogs))
        let clean = NSButton(title: "Clean Unused Media…", target: self, action: #selector(cleanUnusedMedia))
        let controls = NSStackView(views: [refresh, copy, repairButton, revealLogs, clean])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8

        for view in [title, introduction, loginBox, scroll, controls] {
            view.translatesAutoresizingMaskIntoConstraints = false
            diagnosticsPane.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: diagnosticsPane.topAnchor, constant: 4),
            title.leadingAnchor.constraint(equalTo: diagnosticsPane.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: diagnosticsPane.trailingAnchor),
            introduction.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            introduction.leadingAnchor.constraint(equalTo: diagnosticsPane.leadingAnchor),
            introduction.trailingAnchor.constraint(equalTo: diagnosticsPane.trailingAnchor),
            loginBox.topAnchor.constraint(equalTo: introduction.bottomAnchor, constant: 12),
            loginBox.leadingAnchor.constraint(equalTo: diagnosticsPane.leadingAnchor),
            loginBox.trailingAnchor.constraint(equalTo: diagnosticsPane.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: loginBox.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: diagnosticsPane.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: diagnosticsPane.trailingAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            controls.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            controls.leadingAnchor.constraint(equalTo: diagnosticsPane.leadingAnchor),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: diagnosticsPane.trailingAnchor),
            controls.bottomAnchor.constraint(lessThanOrEqualTo: diagnosticsPane.bottomAnchor),
        ])
    }

    private func buildHelpPane() {
        let title = NSTextField(labelWithString: "Generate conversion-friendly animation")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let introduction = NSTextField(wrappingLabelWithString: "Use these copy-ready prompts with an authorized video generator. Replace [CHARACTER DESCRIPTION] with your character, and only use media you own or are authorized to use.")
        introduction.textColor = .secondaryLabelColor

        helpStatePopup.addItems(withTitles: PetState.allCases.map(\.displayName))
        helpStatePopup.target = self
        helpStatePopup.action = #selector(helpStateChanged)
        helpStatePopup.setAccessibilityLabel("Video prompt state")
        let copyButton = NSButton(title: "Copy Prompt", target: self, action: #selector(copyHelpPrompt))
        copyButton.bezelStyle = .rounded
        copyButton.setAccessibilityLabel("Copy selected video generation prompt")
        let promptControls = NSStackView(views: [NSTextField(labelWithString: "Animation state:"), helpStatePopup, copyButton])
        promptControls.orientation = .horizontal
        promptControls.alignment = .centerY
        promptControls.spacing = 8

        helpPromptTextView.isEditable = false
        helpPromptTextView.isSelectable = true
        helpPromptTextView.isRichText = false
        helpPromptTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        helpPromptTextView.textColor = .labelColor
        helpPromptTextView.backgroundColor = .textBackgroundColor
        helpPromptTextView.textContainerInset = NSSize(width: 10, height: 10)
        helpPromptTextView.frame = NSRect(x: 0, y: 0, width: 680, height: 330)
        helpPromptTextView.minSize = NSSize(width: 0, height: 330)
        helpPromptTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        helpPromptTextView.isVerticallyResizable = true
        helpPromptTextView.isHorizontallyResizable = false
        helpPromptTextView.autoresizingMask = [.width]
        helpPromptTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        helpPromptTextView.textContainer?.widthTracksTextView = true
        helpPromptTextView.setAccessibilityLabel("Video generation prompt")
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = helpPromptTextView

        let checklist = NSTextField(wrappingLabelWithString: "Before import, inspect the generated MP4. The first and last frames should be pixel-identical for a seamless loop. Require a completely uniform RGB #00FF00 pure green background; no white background, scene, floor, material texture, shadow, reflection, particles, text, logo, watermark. Also reject cuts, camera movement, gradients, motion blur, green spill on the character, or any foreground touching the frame edge.")
        checklist.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        checklist.textColor = .secondaryLabelColor

        for view in [title, introduction, promptControls, checklist] {
            view.translatesAutoresizingMaskIntoConstraints = false
            helpPane.addSubview(view)
        }
        helpPane.addSubview(scroll)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: helpPane.topAnchor, constant: 4),
            title.leadingAnchor.constraint(equalTo: helpPane.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: helpPane.trailingAnchor),
            introduction.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            introduction.leadingAnchor.constraint(equalTo: helpPane.leadingAnchor),
            introduction.trailingAnchor.constraint(equalTo: helpPane.trailingAnchor),
            promptControls.topAnchor.constraint(equalTo: introduction.bottomAnchor, constant: 14),
            promptControls.leadingAnchor.constraint(equalTo: helpPane.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: promptControls.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: helpPane.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: helpPane.trailingAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 330),
            checklist.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            checklist.leadingAnchor.constraint(equalTo: helpPane.leadingAnchor),
            checklist.trailingAnchor.constraint(equalTo: helpPane.trailingAnchor),
            checklist.bottomAnchor.constraint(lessThanOrEqualTo: helpPane.bottomAnchor),
        ])
        updateHelpPrompt()
    }

    private func buildRecommendationPane() {
        let title = NSTextField(labelWithString: "Animation Source Recommendations")
        title.font = .systemFont(ofSize: 18, weight: .semibold)

        let introduction = NSTextField(wrappingLabelWithString: "Generate clean source footage before importing it into Statelet. These requirements make transparency conversion and continuous playback more reliable.")
        introduction.textColor = .secondaryLabelColor

        let loopGuidance = NSTextField(wrappingLabelWithString: "Seamless loop: the first and last frames should be pixel-identical. Match the character's pose, position, expression, lighting, and motion direction exactly so playback has no jump, pause, cross-fade, or restart.")
        let loopBox = makeSection(title: "Loop", content: loopGuidance)

        let backgroundGuidance = NSTextField(wrappingLabelWithString: "Source requirement: completely uniform RGB #00FF00 pure green background; no white background, scene, floor, material texture, shadow, reflection, particles, text, logo, watermark.")
        let backgroundBox = makeSection(title: "Background", content: backgroundGuidance)

        let framingGuidance = NSTextField(wrappingLabelWithString: "Lock the camera. Keep the complete character centered and visible with safe green space on every side. Avoid cuts, transitions, zoom, shake, entrances, exits, motion blur, green spill, and contact with any frame edge.")
        let framingBox = makeSection(title: "Framing and Effects", content: framingGuidance)

        let toolsGuidance = NSTextField(wrappingLabelWithString: "Example tools you may try: Google Omni or Grok Imagine, Minimax H3, Seedance 2.5, and LSX2.3. These are user-provided examples, not endorsements or claims about availability, features, or output quality.")
        toolsGuidance.textColor = .secondaryLabelColor
        let toolsBox = makeSection(title: "Generator Examples", content: toolsGuidance)

        let stack = NSStackView(views: [title, introduction, loopBox, backgroundBox, framingBox, toolsBox])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        recommendationPane.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: recommendationPane.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: recommendationPane.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: recommendationPane.trailingAnchor),
            loopBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            backgroundBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            framingBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            toolsBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: recommendationPane.bottomAnchor),
        ])
    }

    private func makeSection(title: String, content: NSView) -> NSBox {
        let box = NSBox()
        box.title = title
        box.titlePosition = .atTop
        box.boxType = .primary
        content.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(content)
        if let container = box.contentView {
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
                content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            ])
        }
        return box
    }

    private func makeAppearanceRow(title: String, control: NSView, value: NSTextField? = nil) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .left
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        if control is NSSlider {
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        }
        var views: [NSView] = [label, control]
        if let value {
            value.widthAnchor.constraint(equalToConstant: 64).isActive = true
            views.append(value)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    private func updateAppearanceControls(_ appearance: PetAppearanceConfiguration) {
        backgroundEnabledCheckbox.state = appearance.backgroundEnabled ? .on : .off
        backgroundColorWell.color = NSColor.codexPet(hex: appearance.backgroundColor)
        backgroundOpacitySlider.doubleValue = appearance.backgroundOpacity * 100
        cornerRadiusSlider.doubleValue = appearance.cornerRadius
        borderEnabledCheckbox.state = appearance.borderEnabled ? .on : .off
        borderColorWell.color = NSColor.codexPet(hex: appearance.borderColor)
        borderOpacitySlider.doubleValue = appearance.borderOpacity * 100
        borderWidthSlider.doubleValue = appearance.borderWidth
        stateLabelEnabledCheckbox.state = appearance.showStateLabel ? .on : .off
        stateLabelAutomaticColorCheckbox.state = appearance.stateLabelColor == nil ? .on : .off
        if let stateLabelColor = appearance.stateLabelColor {
            stateLabelColorWell.color = NSColor.codexPet(hex: stateLabelColor)
        } else {
            stateLabelColorWell.color = NSColor.codexPet(hex: Self.defaultStateLabelCustomColor)
        }
        if let index = stateLabelPositions.firstIndex(of: appearance.stateLabelPosition) {
            stateLabelPositionPopup.selectItem(at: index)
        }
        if let index = stateLabelSizes.firstIndex(of: appearance.stateLabelSize) {
            stateLabelSizePopup.selectItem(at: index)
        }
        fpsEnabledCheckbox.state = appearance.showFPS ? .on : .off
        fpsColorWell.color = NSColor.codexPet(hex: appearance.fpsColor)
        if let index = stateLabelSizes.firstIndex(of: appearance.fpsLabelSize) {
            fpsSizePopup.selectItem(at: index)
        }
        updateAppearanceLabelsAndEnabledState()
    }

    private func currentAppearance() -> PetAppearanceConfiguration? {
        let positionIndex = max(0, min(stateLabelPositionPopup.indexOfSelectedItem, stateLabelPositions.count - 1))
        let sizeIndex = max(0, min(stateLabelSizePopup.indexOfSelectedItem, stateLabelSizes.count - 1))
        let fpsSizeIndex = max(0, min(fpsSizePopup.indexOfSelectedItem, stateLabelSizes.count - 1))
        return try? PetAppearanceConfiguration(
            backgroundEnabled: backgroundEnabledCheckbox.state == .on,
            backgroundColor: backgroundColorWell.color.codexPetHex,
            backgroundOpacity: backgroundOpacitySlider.doubleValue / 100,
            borderEnabled: borderEnabledCheckbox.state == .on,
            borderColor: borderColorWell.color.codexPetHex,
            borderOpacity: borderOpacitySlider.doubleValue / 100,
            borderWidth: borderWidthSlider.doubleValue,
            cornerRadius: cornerRadiusSlider.doubleValue,
            showStateLabel: stateLabelEnabledCheckbox.state == .on,
            stateLabelPosition: stateLabelPositions[positionIndex],
            stateLabelSize: stateLabelSizes[sizeIndex],
            stateLabelColor: stateLabelAutomaticColorCheckbox.state == .on
                ? nil
                : stateLabelColorWell.color.codexPetHex,
            showFPS: fpsEnabledCheckbox.state == .on,
            fpsColor: fpsColorWell.color.codexPetHex,
            fpsLabelSize: stateLabelSizes[fpsSizeIndex]
        )
    }

    private func updateAppearanceLabelsAndEnabledState() {
        backgroundOpacityLabel.stringValue = "\(Int(backgroundOpacitySlider.doubleValue.rounded()))%"
        cornerRadiusLabel.stringValue = "\(Int(cornerRadiusSlider.doubleValue.rounded())) pt"
        borderOpacityLabel.stringValue = "\(Int(borderOpacitySlider.doubleValue.rounded()))%"
        borderWidthLabel.stringValue = String(format: "%.1f pt", borderWidthSlider.doubleValue)
        let backgroundEnabled = backgroundEnabledCheckbox.state == .on
        backgroundColorWell.isEnabled = backgroundEnabled
        backgroundOpacitySlider.isEnabled = backgroundEnabled
        let borderEnabled = borderEnabledCheckbox.state == .on
        borderColorWell.isEnabled = borderEnabled
        borderOpacitySlider.isEnabled = borderEnabled
        borderWidthSlider.isEnabled = borderEnabled
        let labelEnabled = stateLabelEnabledCheckbox.state == .on
        stateLabelAutomaticColorCheckbox.isEnabled = labelEnabled
        stateLabelColorWell.isEnabled = labelEnabled && stateLabelAutomaticColorCheckbox.state == .off
        stateLabelPositionPopup.isEnabled = labelEnabled
        stateLabelSizePopup.isEnabled = labelEnabled
        let fpsEnabled = fpsEnabledCheckbox.state == .on
        fpsColorWell.isEnabled = fpsEnabled
        fpsSizePopup.isEnabled = fpsEnabled
    }

    private func refreshRows() {
        guard let snapshot else { return }
        let globallyBusy: Bool
        switch activity {
        case .converting, .working, .applying, .characterWorking: globallyBusy = true
        case .idle, .succeeded, .failed, .characterSucceeded: globallyBusy = false
        }
        let counts = Dictionary(uniqueKeysWithValues: PetState.allCases.map {
            ($0, snapshot.mediaMap.playlist(for: $0)?.entries.count ?? 0)
        })
        animationLibrary.update(
            selectedState: selectedAnimationState,
            currentState: snapshot.currentState,
            playlist: snapshot.mediaMap.playlist(for: selectedAnimationState),
            counts: counts,
            mapURL: snapshot.mediaMapURL,
            mediaMap: snapshot.mediaMap,
            preview: snapshot.preview,
            reduceMotion: snapshot.reduceMotion,
            busy: globallyBusy,
            importEnabled: toolchainState.isReady,
            characterName: activeCharacterName
        )
    }

    private var activeCharacterName: String {
        guard let snapshot else { return "Default" }
        return snapshot.characterProfiles.first(where: { $0.id == snapshot.activeCharacterID })?.name
            ?? snapshot.characterProfiles.first?.name
            ?? "Default"
    }

    private func updateCharacterSelector() {
        guard let snapshot else { return }
        characterSelector.update(
            profiles: snapshot.characterProfiles,
            activeID: snapshot.activeCharacterID,
            busy: activity.isBusy
        )
    }

    private func promptForNewCharacter() {
        promptForCharacterName(
            title: "New Character",
            message: "Create a separate animation profile for this character.",
            initialValue: ""
        ) { [weak self] name in
            self?.onCreateCharacter?(name)
        }
    }

    private func promptForCharacterRename() {
        guard let snapshot else { return }
        promptForCharacterName(
            title: "Rename Character",
            message: "Change the display name without changing its animation library.",
            initialValue: activeCharacterName
        ) { [weak self] name in
            self?.onRenameCharacter?(snapshot.activeCharacterID, name)
        }
    }

    private func promptForCharacterDuplicate() {
        guard let snapshot else { return }
        promptForCharacterName(
            title: "Duplicate Character",
            message: "Copy the animation assignments and reuse their verified media files.",
            initialValue: "\(activeCharacterName) Copy"
        ) { [weak self] name in
            self?.onDuplicateCharacter?(snapshot.activeCharacterID, name)
        }
    }

    private func promptForCharacterName(
        title: String,
        message: String,
        initialValue: String,
        completion: @escaping (String) -> Void
    ) {
        guard let window else { return }
        let field = NSTextField(string: initialValue)
        field.placeholderString = "Character name"
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        field.setAccessibilityLabel("Character name")
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = field
        let confirmTitle = switch title {
        case "New Character": "Create"
        case "Duplicate Character": "Duplicate"
        default: "Save"
        }
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping
            guard !name.isEmpty, name.count <= 80,
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                self?.update(activity: .failed(nil, "Character name must be 1–80 visible characters."))
                return
            }
            completion(name)
        }
        DispatchQueue.main.async {
            field.selectText(nil)
            window.makeFirstResponder(field)
        }
    }

    private func confirmCharacterDeletion(id: String) {
        guard let window, let snapshot,
              let request = CharacterProfileDeletionRequest(
                  requestedProfileID: id,
                  profiles: snapshot.characterProfiles,
                  activeProfileID: snapshot.activeCharacterID,
                  busy: activity.isBusy
              ) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \u{201c}\(request.profileName)\u{201d}?"
        alert.informativeText = "This removes the character from the selector. Its map and all media files remain untouched; Clean Unused Media can review unreferenced files later."
        alert.addButton(withTitle: "Delete Character")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, let snapshot = self.snapshot,
                  let confirmedID = request.confirmedProfileID(
                      response: response,
                      profiles: snapshot.characterProfiles,
                      activeProfileID: snapshot.activeCharacterID,
                      busy: self.activity.isBusy
                  ) else { return }
            self.onDeleteCharacter?(confirmedID)
        }
    }

    private func startLibraryRevisionTimer() {
        guard libraryRevisionTimer == nil else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshRows()
        }
        timer.tolerance = 0.35
        RunLoop.main.add(timer, forMode: .common)
        libraryRevisionTimer = timer
    }

    func windowWillClose(_ notification: Notification) {
        libraryRevisionTimer?.invalidate()
        libraryRevisionTimer = nil
    }

    @objc private func changePane() {
        animationsPane.isHidden = tabs.selectedSegment != 0
        dialogueVoiceView.isHidden = tabs.selectedSegment != 1
        appearancePane.isHidden = tabs.selectedSegment != 2
        generalPane.isHidden = tabs.selectedSegment != 3
        diagnosticsPane.isHidden = tabs.selectedSegment != 4
        helpPane.isHidden = tabs.selectedSegment != 5
        recommendationPane.isHidden = tabs.selectedSegment != 6
    }

    @objc private func helpStateChanged() { updateHelpPrompt() }

    @objc private func copyHelpPrompt() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(helpPromptTextView.string, forType: .string)
    }

    private func updateHelpPrompt() {
        let index = max(0, min(helpStatePopup.indexOfSelectedItem, PetState.allCases.count - 1))
        helpPromptTextView.string = PetState.allCases[index].generationPrompt
        helpPromptTextView.scrollToBeginningOfDocument(nil)
    }

    private func showClipActions(for entry: MediaEntry, relativeTo sender: NSButton) {
        let state = selectedAnimationState
        let menu = NSMenu()
        let fixed = NSMenuItem(title: "Set as Fixed", action: #selector(setFixed(_:)), keyEquivalent: "")
        configure(fixed, state: state, path: entry.path)
        let playlist = snapshot?.mediaMap.playlist(for: state)
        fixed.isEnabled = playlist?.fixedPath != entry.path || playlist?.mode != .fixed
        menu.addItem(fixed)
        let entries = playlist?.entries ?? []
        let index = entries.firstIndex(where: { mediaPathsEqual($0.path, entry.path) })
        let moveUp = NSMenuItem(title: "Move Up", action: #selector(moveClipUp(_:)), keyEquivalent: "")
        configure(moveUp, state: state, path: entry.path)
        moveUp.isEnabled = index.map { $0 > 0 } ?? false
        menu.addItem(moveUp)
        let moveDown = NSMenuItem(title: "Move Down", action: #selector(moveClipDown(_:)), keyEquivalent: "")
        configure(moveDown, state: state, path: entry.path)
        moveDown.isEnabled = index.map { $0 < entries.count - 1 } ?? false
        menu.addItem(moveDown)
        menu.addItem(.separator())
        let posterTitle = entry.posterPath == nil ? "Choose Poster…" : "Replace Poster…"
        let poster = NSMenuItem(title: posterTitle, action: #selector(choosePoster(_:)), keyEquivalent: "")
        configure(poster, state: state, path: entry.path)
        menu.addItem(poster)
        let removePoster = NSMenuItem(title: "Remove Poster", action: #selector(removePoster(_:)), keyEquivalent: "")
        configure(removePoster, state: state, path: entry.path)
        removePoster.isEnabled = entry.posterPath != nil
        menu.addItem(removePoster)
        menu.addItem(.separator())
        let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(revealClip(_:)), keyEquivalent: "")
        configure(reveal, state: state, path: entry.path)
        let resolvedURL = snapshot.map { $0.mediaMap.resolvedURL(for: entry, relativeTo: $0.mediaMapURL) }
        reveal.isEnabled = resolvedURL.map { FileManager.default.isReadableFile(atPath: $0.path) } ?? false
        menu.addItem(reveal)
        let relink = NSMenuItem(title: "Relink…", action: #selector(relinkClip(_:)), keyEquivalent: "")
        configure(relink, state: state, path: entry.path)
        relink.isEnabled = !(resolvedURL.map { FileManager.default.isReadableFile(atPath: $0.path) } ?? false)
        relink.toolTip = relink.isEnabled ? "Choose a verified replacement for this missing movie." : "Relink is available when the movie file is missing."
        menu.addItem(relink)
        menu.addItem(.separator())
        let removeMedia = NSMenuItem(title: "Remove…", action: #selector(removeClip(_:)), keyEquivalent: "")
        configure(removeMedia, state: state, path: entry.path)
        menu.addItem(removeMedia)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    private func configure(_ item: NSMenuItem, state: PetState, path: String) {
        item.target = self
        item.representedObject = ["state": state.rawValue, "path": path]
    }

    private func clipAction(from sender: NSMenuItem) -> (PetState, String)? {
        guard let value = sender.representedObject as? [String: String],
              let rawState = value["state"], let state = PetState(rawValue: rawState),
              let path = value["path"] else { return nil }
        return (state, path)
    }

    @objc private func setFixed(_ sender: NSMenuItem) {
        guard let (state, path) = clipAction(from: sender) else { return }
        onSetFixed?(state, path)
    }

    @objc private func choosePoster(_ sender: NSMenuItem) {
        guard let (state, path) = clipAction(from: sender) else { return }
        onChoosePoster?(state, path)
    }

    @objc private func moveClipUp(_ sender: NSMenuItem) {
        guard let (state, path) = clipAction(from: sender),
              let entries = snapshot?.mediaMap.playlist(for: state)?.entries,
              let index = entries.firstIndex(where: { mediaPathsEqual($0.path, path) }),
              index > 0 else { return }
        onMoveMedia?(state, path, index - 1)
    }

    @objc private func moveClipDown(_ sender: NSMenuItem) {
        guard let (state, path) = clipAction(from: sender),
              let entries = snapshot?.mediaMap.playlist(for: state)?.entries,
              let index = entries.firstIndex(where: { mediaPathsEqual($0.path, path) }),
              index < entries.count - 1 else { return }
        onMoveMedia?(state, path, index + 1)
    }

    @objc private func relinkClip(_ sender: NSMenuItem) {
        guard let (state, path) = clipAction(from: sender) else { return }
        onRelinkMedia?(state, path)
    }

    @objc private func removePoster(_ sender: NSMenuItem) {
        guard let (state, path) = clipAction(from: sender) else { return }
        onRemovePoster?(state, path)
    }

    @objc private func revealClip(_ sender: NSMenuItem) {
        guard let (state, path) = clipAction(from: sender) else { return }
        onRevealMedia?(state, path)
    }

    @objc private func removeClip(_ sender: NSMenuItem) {
        guard let (state, path) = clipAction(from: sender) else { return }
        confirmClipRemoval(state: state, path: path)
    }

    private func confirmClipRemoval(state: PetState, path: String) {
        let alert = NSAlert()
        let name = URL(fileURLWithPath: path).lastPathComponent
        let managedPlan = snapshot.flatMap { snapshot in
            try? ManagedMediaRemovalPlanner.plan(
                mediaMap: snapshot.mediaMap,
                mapURL: snapshot.mediaMapURL,
                state: state,
                path: path,
                canonicalRoot: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(
                        "\(StateletIdentity.applicationSupportRelativePath)/media",
                        isDirectory: true
                    )
            )
        }
        alert.messageText = "Remove \(name) from \(state.displayName)?"
        if let managedPlan {
            let fileCount = managedPlan.trashURLs.count
            alert.informativeText = "Remove only the library entry, or also move the managed MOV\(fileCount > 1 ? " and verification report" : "") to Trash. Posters are kept. Trash items remain recoverable."
        } else {
            alert.informativeText = "This removes the clip from the \(state.displayName) state. Missing, shared, external, or otherwise unmanaged files remain on disk."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove from State")
        if managedPlan != nil {
            alert.addButton(withTitle: "Remove & Move Files to Trash")
        }
        alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.onRemoveMedia?(state, path, .libraryOnly)
            } else if managedPlan != nil, response == .alertSecondButtonReturn {
                self?.onRemoveMedia?(state, path, .moveManagedFilesToTrash)
            }
        }
    }

    @objc private func checkTools() { onCheckTools?() }
    @objc private func cancelConversion() { onCancelConversion?() }

    @objc private func retryFailedMP4s() { onRetryFailedMP4s?() }

    @objc private func conversionProfileChanged() {
        guard let value = conversionProfilePopup.selectedItem?.representedObject as? String,
              let profile = AlphaConversionProfile(rawValue: value) else { return }
        onConversionProfileChange?(profile)
    }
    @objc private func revealMediaFolder() { onRevealMediaFolder?() }
    @objc private func revealMap() { onRevealMap?() }
    @objc private func revealLogs() { onRevealLogs?() }
    @objc private func revealApp() { onRevealApp?() }
    @objc private func resetPositionAction() { onResetPosition?() }
    @objc private func refreshDiagnostics() { onRefreshDiagnostics?() }
    @objc private func repairInstallation() { onRepairInstallation?() }
    @objc private func launchAtLoginChanged() { onLaunchAtLoginChange?(launchAtLoginCheckbox.state == .on) }
    @objc private func cleanUnusedMedia() { onCleanUnusedMedia?() }

    @objc private func copyDiagnostics() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(diagnosticsTextView.string, forType: .string)
    }

    @objc private func appearanceChanged() {
        updateAppearanceLabelsAndEnabledState()
        publishWindowSettings(width: sizeSlider.doubleValue)
    }

    @objc private func resetAppearance() {
        updateAppearanceControls(try! PetAppearanceConfiguration())
        publishWindowSettings(width: sizeSlider.doubleValue)
    }

    @objc private func showSetupGuide() {
        let alert = NSAlert()
        alert.messageText = "Prepare Local Conversion Tools"
        alert.informativeText = "Install ffmpeg with Homebrew, then choose a Python 3 executable containing NumPy and Pillow. Developers can also set CODEX_PET_ALPHA_PYTHON before launch. Conversion and verification stay entirely on this Mac."
        alert.addButton(withTitle: "Choose Python…")
        alert.addButton(withTitle: "Close")
        if let window {
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn {
                    self?.onChoosePython?()
                }
            }
        }
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?Seeing_Display") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func sizeChanged() {
        publishWindowSettings(width: sizeSlider.doubleValue)
    }

    @objc private func resetSize() {
        sizeSlider.doubleValue = 320
        aspectRatio = 1.5
        publishWindowSettings(width: 320)
    }

    @objc private func windowOptionChanged() {
        publishWindowSettings(width: sizeSlider.doubleValue)
    }

    private func publishWindowSettings(width: Double) {
        guard let appearance = currentAppearance() else { return }
        let roundedWidth = width.rounded()
        let roundedHeight = (roundedWidth * aspectRatio).rounded()
        sizeLabel.stringValue = sizeDescription(width: roundedWidth, height: roundedHeight)
        onWindowSettingsChange?(
            WindowSettingsUpdate(
                width: roundedWidth,
                height: roundedHeight,
                alwaysOnTop: alwaysOnTopCheckbox.state == .on,
                clickThrough: clickThroughCheckbox.state == .on,
                fullScreenAuxiliary: fullScreenCheckbox.state == .on,
                appearance: appearance
            )
        )
    }

    private func sizeDescription(width: Double, height: Double) -> String {
        "\(Int(width.rounded())) × \(Int(height.rounded())) pt"
    }
}

private func mediaPathsEqual(_ lhs: String, _ rhs: String) -> Bool {
    NSString(string: lhs).standardizingPath == NSString(string: rhs).standardizingPath
}

private extension StateLabelPosition {
    var displayName: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
}

private extension StateLabelSize {
    var displayName: String { rawValue.capitalized }
}

extension PetState {
    var displayName: String { rawValue.capitalized }

    var explanation: String {
        switch self {
        case .idle: return "No active Codex turn"
        case .running: return "Codex is working"
        case .waiting: return "Codex needs input or permission"
        case .review: return "Tests, lint, or review"
        }
    }

    var symbolName: String {
        switch self {
        case .idle: return "moon.stars"
        case .running: return "bolt.fill"
        case .waiting: return "hand.raised.fill"
        case .review: return "checkmark.seal.fill"
        }
    }

    var generationPrompt: String {
        let stateDirection: String
        switch self {
        case .idle:
            stateDirection = """
            Create the Idle lifecycle state. The character looks relaxed, available, and quietly attentive. Use a natural asymmetric stance, a very gentle weight shift, small eye or head drift, and one slow blink. Keep the feet and root position nearly fixed. Avoid waving, dancing, exaggerated emotion, or repetitive fidgeting.
            """
        case .running:
            stateDirection = """
            Create the Running lifecycle state, representing active work rather than traveling across the scene. Give the character a focused expression, a slight forward lean, restrained alternating hand movement, and a light in-place step or body rhythm. Make the activity clearer and more energetic than Idle while remaining controlled and centered. Do not let the character travel laterally or approach the frame edges.
            """
        case .waiting:
            stateDirection = """
            Create the Waiting lifecycle state. The character is calmly waiting for user input or permission, without panic or distress. Use a mildly expectant expression, one slow toe tap, a small weight shift, and a brief searching glance to one side before returning to neutral. Avoid frantic gestures, repeated checking, slumping, anger, or sadness.
            """
        case .review:
            stateDirection = """
            Create the Review lifecycle state. The character appears thoughtful and deliberately evaluative. Use a serious but calm expression, a small forward lean, one brief hand-to-chin gesture, and a measured eye scan from one side to the other before returning to the opening pose. Do not introduce documents, screens, signs, or other objects containing text.
            """
        }
        return """
        Character: [CHARACTER DESCRIPTION]

        \(stateDirection)

        Create one 8–10 second seamless-loop video of an original, non-branded full-body character, intended as source footage for offline transparency conversion.

        Use a completely uniform RGB #00FF00 pure green background. No white background, scene, floor, material texture, shadow, reflection, particles, text, logo, or watermark. Also include no ground plane, horizon, gradient, vignette, glow, smoke, border, UI, or other visual effect.

        Lock the camera completely. No pan, tilt, zoom, orbit, shake, focus pull, reframing, cuts, transitions, entrances, or exits. Keep the full character centered and visible from head to feet throughout the entire video. Maintain at least 10% empty green safe margin on every side. Hair, hands, clothing, accessories, and feet must never touch or cross a frame edge.

        Keep framing, scale, lens, focus, exposure, character lighting, and color stable. Use a clean silhouette and minimal motion blur. Keep the movement subtle but readable. Avoid green character details and green bounce light where practical.

        The first and last frames must be pixel-identical for a seamless loop. Match pose, position, expression, lighting, and motion direction exactly so the loop repeats without a jump, pause, cross-fade, or restart. Use constant-frame-rate 24 fps if frame-rate control is available. No audio.

        Rights: use only an original character or a design/reference you own or have permission to adapt.
        """
    }
}
