import AppKit
import CodexPetCore

private final class TopAlignedSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class SessionActivityAppearancePreviewView: NSView {
    private let label = NSTextField(labelWithString: "Running · Tool #1 · just now")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 10
        label.alignment = .center
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Activity popup appearance preview")
    }

    required init?(coder: NSCoder) {
        fatalError("SessionActivityAppearancePreviewView does not support NSCoder initialization")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 260, height: 42)
    }

    func apply(_ appearance: SessionActivityPanelAppearance) {
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let resolved = SessionActivityView.resolveAppearance(
            appearance: appearance,
            systemBackgroundColor: .windowBackgroundColor,
            systemTextColor: .labelColor,
            secondaryTextColor: .secondaryLabelColor,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
        layer?.backgroundColor = resolved.backgroundColor
            .withAlphaComponent(CGFloat(resolved.opacity))
            .cgColor
        label.textColor = resolved.primaryTextColor
        setAccessibilityValue(
            "\(appearance.automaticContrast ? "Automatic" : "Custom") contrast, ratio \(String(format: "%.1f", resolved.contrastRatio))"
        )
    }
}

private final class DialogueAppearancePreviewView: NSView {
    private let label = NSTextField(labelWithString: "Statelet dialogue preview")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 10
        label.alignment = .center
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Dialogue bubble appearance preview")
    }

    required init?(coder: NSCoder) {
        fatalError("DialogueAppearancePreviewView does not support NSCoder initialization")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 260, height: 42)
    }

    func apply(_ appearance: PetAppearanceConfiguration) {
        let resolved = PetPlayerView.resolveDialogueAppearance(
            configuration: appearance,
            systemBackgroundColor: .windowBackgroundColor,
            systemTextColor: .labelColor,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
        layer?.backgroundColor = resolved.backgroundColor
            .withAlphaComponent(CGFloat(resolved.backgroundOpacity))
            .cgColor
        label.textColor = resolved.textColor
        setAccessibilityValue("Contrast ratio \(String(format: "%.1f", resolved.contrastRatio))")
    }
}

private final class SettingsAnimationsPaneView: NSView {
    weak var statusView: NSView?
    weak var modeView: NSView?
    weak var libraryView: NSView?
    weak var footerView: NSView?

    override func layout() {
        super.layout()
        guard let statusView, let modeView, let libraryView, let footerView else { return }

        let statusHeight: CGFloat = 42
        let modeHeight: CGFloat = 24
        let footerHeight: CGFloat = 20
        statusView.frame = NSRect(
            x: 0,
            y: max(0, bounds.height - statusHeight),
            width: bounds.width,
            height: statusHeight
        )
        modeView.frame = NSRect(
            x: 0,
            y: max(0, statusView.frame.minY - 8 - modeHeight),
            width: min(270, bounds.width),
            height: modeHeight
        )
        footerView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: footerHeight)
        let libraryBottom = footerView.frame.maxY + 10
        libraryView.frame = NSRect(
            x: 0,
            y: libraryBottom,
            width: bounds.width,
            height: max(0, modeView.frame.minY - 8 - libraryBottom)
        )
    }
}

struct SettingsSnapshot {
    let mediaMap: MediaMap
    let mediaMapURL: URL
    let globalTransitionLibrary: GlobalTransitionLibrary
    let globalTransitionLibraryURL: URL
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
        globalTransitionLibrary: GlobalTransitionLibrary = try! GlobalTransitionLibrary(),
        globalTransitionLibraryURL: URL? = nil,
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
        self.globalTransitionLibrary = globalTransitionLibrary
        self.globalTransitionLibraryURL = globalTransitionLibraryURL ?? mediaMapURL
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

enum SettingsWindowSizeStore {
    static let defaultsKey = "Statelet.settingsWindowContentSize.v1"

    private static let widthKey = "width"
    private static let heightKey = "height"
    private static let maximumDimension: Double = 10_000

    static func restored(from defaults: UserDefaults) -> NSSize? {
        guard let values = defaults.dictionary(forKey: defaultsKey),
              let width = (values[widthKey] as? NSNumber)?.doubleValue,
              let height = (values[heightKey] as? NSNumber)?.doubleValue,
              isValid(width: width),
              isValid(height: height) else { return nil }
        return NSSize(width: width, height: height)
    }

    static func persist(_ size: NSSize, to defaults: UserDefaults) {
        let width = Double(size.width)
        let height = Double(size.height)
        guard isValid(width: width), isValid(height: height) else { return }
        defaults.set([
            widthKey: width,
            heightKey: height,
        ], forKey: defaultsKey)
    }

    static func reset(in defaults: UserDefaults) {
        defaults.removeObject(forKey: defaultsKey)
    }

    private static func isValid(width: Double) -> Bool {
        width.isFinite && width > 0 && width <= maximumDimension
    }

    private static func isValid(height: Double) -> Bool {
        height.isFinite && height > 0 && height <= maximumDimension
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static let defaultStateLabelCustomColor = "#007AFF"
    private static let preferredContentSize = NSSize(width: 760, height: 650)
    private static let minimumContentSize = NSSize(width: 700, height: 570)
    private static let screenMargin: CGFloat = 12
    private static let sidebarWidth: CGFloat = 148
    private static let selectedSectionDefaultsKey = "Statelet.Settings.selectedSection"
    private static let sectionLabels = [
        "Animations",
        "Voice",
        "Appearance",
        "General",
        "Diagnostics",
        "Help",
        "Prompts",
        "Recommendation",
    ]

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
    var onSessionActivityAppearanceChange: ((SessionActivityPanelAppearance) -> Void)?
    var onResetActivityPosition: (() -> Void)?
    var onRefreshDiagnostics: (() -> Void)?
    var onRepairInstallation: (() -> Void)?
    var onLaunchAtLoginChange: ((Bool) -> Void)?
    var onCleanUnusedMedia: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onCancelUpdate: (() -> Void)?
    var onInstallUpdate: (() -> Void)?
    var onAutomaticInstallChange: ((Bool) -> Void)?
    var onImportVoiceAsset: ((DialogueVoiceAssetKind, DialogueVoiceProfileDraft) -> Void)?
    var onSaveVoiceProfile: ((DialogueVoiceProfileDraft) -> Void)?
    var onRemoveVoiceProfile: ((GPTSoVITSVoiceProfile) -> Void)?
    var onConfigureQwenProfile: (() -> Void)?
    var onSelectVoiceProvider: ((DialogueVoiceProviderKind) -> Void)?
    var onRemoveQwenProfile: ((Qwen3TTSVoiceProfile) -> Void)?
    var onConfigureVoxCPM2Profile: ((String) -> Void)?
    var onRemoveVoxCPM2Profile: ((VoxCPM2VoiceProfile) -> Void)?
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
    var onMigrateGlobalTransitionLegacy: (() -> Void)?
    var onImportTransitionMP4: ((TransitionLibraryScope, SettingsTransitionRoute) -> Void)?
    var onUseTransitionMovie: ((TransitionLibraryScope, SettingsTransitionRoute) -> Void)?
    var onReplaceTransitionMP4: ((TransitionLibraryScope, SettingsTransitionRoute, String) -> Void)?
    var onReplaceTransitionMovie: ((TransitionLibraryScope, SettingsTransitionRoute, String) -> Void)?
    var onPreviewTransition: ((TransitionLibraryScope, SettingsTransitionRoute, String) -> Void)?
    var onRemoveTransition: ((TransitionLibraryScope, SettingsTransitionRoute, String) -> Void)?
    var onMoveTransition: ((TransitionLibraryScope, SettingsTransitionRoute, String, Int) -> Void)?
    var onTransitionModeChange: ((TransitionLibraryScope, SettingsTransitionRoute, MediaPlaybackMode) -> Void)?
    var onSetFixedTransition: ((TransitionLibraryScope, SettingsTransitionRoute, String) -> Void)?

    private let sidebar = NSVisualEffectView()
    private let sidebarScrollView = NSScrollView()
    private let sidebarTableView = NSTableView()
    private let sidebarDivider = NSBox()
    private let paneHost = NSView()
    private let animationsPane = SettingsAnimationsPaneView()
    private let dialogueVoiceView = DialogueVoiceSettingsView()
    private let appearancePane = NSView()
    private let generalPane = NSView()
    private let diagnosticsPane = NSView()
    private let helpPane = NSView()
    private let promptsPane = NSView()
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
    private let resetSettingsWindowSizeButton = NSButton(title: "Reset Window Size", target: nil, action: nil)
    private let fpsEnabledCheckbox = NSButton(checkboxWithTitle: "Show video FPS", target: nil, action: nil)
    private let fpsColorWell = NSColorWell()
    private let fpsSizePopup = NSPopUpButton()
    private let activityBackgroundColorWell = NSColorWell()
    private let activityOpacitySlider = NSSlider(value: 92, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let activityOpacityLabel = NSTextField(labelWithString: "92%")
    private let activityContrastPopup = NSPopUpButton()
    private let activityAppearancePreview = SessionActivityAppearancePreviewView()
    private let dialogueBackgroundColorWell = NSColorWell()
    private let dialogueTextColorWell = NSColorWell()
    private let dialogueOpacitySlider = NSSlider(value: 88, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let dialogueOpacityLabel = NSTextField(labelWithString: "88%")
    private let dialogueContrastPopup = NSPopUpButton()
    private let dialogueAppearancePreview = DialogueAppearancePreviewView()
    private let reduceMotionLabel = NSTextField(labelWithString: "Reduce Motion: Checking")
    private let helpStatePopup = NSPopUpButton()
    private let helpPromptTextView = NSTextView()
    private let updateStatusLabel = NSTextField(wrappingLabelWithString: "Checking for updates…")
    private let updateVersionLabel = NSTextField(labelWithString: "Installed version: Checking…")
    private let updateNotesLabel = NSTextField(wrappingLabelWithString: "")
    private let updateProgress = NSProgressIndicator()
    private let checkForUpdatesButton = NSButton(title: "Check Now", target: nil, action: nil)
    private let cancelUpdateButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let installUpdateButton = NSButton(title: "Install at Restart", target: nil, action: nil)
    private let automaticInstallCheckbox = NSButton(checkboxWithTitle: "Automatically install verified updates at the next safe restart", target: nil, action: nil)
    private let diagnosticsTextView = NSTextView()
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Start Statelet when I log in", target: nil, action: nil)
    private let launchAtLoginLabel = NSTextField(wrappingLabelWithString: "Checking…")
    private let repairButton = NSButton(title: "Repair Startup…", target: nil, action: nil)
    private let animationLibraryHost = NSView()
    private let animationLibrary = AnimationLibraryView()
    private let transitionLibrary = TransitionLibraryView()
    private let animationsMode = NSSegmentedControl(
        labels: ["State Animations", "Transitions"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private var snapshot: SettingsSnapshot?
    private var selectedAnimationState: PetState = .idle
    private var selectedTransitionScope: TransitionLibraryScope = .character
    private var toolchainState: AlphaToolchainState = .checking
    private var activity: SettingsActivity = .idle
    private var libraryRevisionTimer: Timer?
    private weak var displayedPane: NSView?
    private var displayedPaneConstraints: [NSLayoutConstraint] = []
    private weak var displayedAnimationLibrary: NSView?
    private var displayedAnimationLibraryConstraints: [NSLayoutConstraint] = []
    private var minimumPaneWidthConstraint: NSLayoutConstraint?
    private var minimumPaneHeightConstraint: NSLayoutConstraint?
    private var hasShownWindow = false
    private let defaults: UserDefaults
    private var sessionActivityAppearance = try! SessionActivityPanelAppearance()
    private var selectedSectionIndex = 0
    private var usePreferredSizeOnFirstShow = true
    private var aspectRatio = 1.5
    private let stateLabelPositions: [StateLabelPosition] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
    private let stateLabelSizes: [StateLabelSize] = [.small, .regular, .large]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let restoredSize = SettingsWindowSizeStore.restored(from: defaults)
        usePreferredSizeOnFirstShow = restoredSize == nil
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: restoredSize ?? Self.preferredContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Statelet Settings"
        window.contentMinSize = Self.minimumContentSize
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        if defaults.object(forKey: Self.selectedSectionDefaultsKey) != nil {
            let restoredSection = defaults.integer(forKey: Self.selectedSectionDefaultsKey)
            if Self.sectionLabels.indices.contains(restoredSection) {
                selectedSectionIndex = restoredSection
            }
        }
        buildInterface()
        configureWindowActions()
        fitWindowToVisibleScreen(usePreferredSize: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureWindowActions() {
        resetSettingsWindowSizeButton.target = self
        resetSettingsWindowSizeButton.action = #selector(resetSettingsWindowSize)
        resetSettingsWindowSizeButton.controlSize = .small
        resetSettingsWindowSizeButton.bezelStyle = .texturedRounded
        resetSettingsWindowSizeButton.setAccessibilityLabel("Reset Settings Window Size")
        resetSettingsWindowSizeButton.setAccessibilityHelp(
            "Restore the default Settings window size without changing the pet window."
        )
        resetSettingsWindowSizeButton.toolTip = "Restore the default Settings window size"

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 132, height: 22))
        resetSettingsWindowSizeButton.frame = accessoryView.bounds
        resetSettingsWindowSizeButton.autoresizingMask = [.width, .height]
        accessoryView.addSubview(resetSettingsWindowSizeButton)
        accessory.view = accessoryView
        window?.addTitlebarAccessoryViewController(accessory)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        animationLibrary.invalidateRowCache()
        refreshRows()
        startLibraryRevisionTimer()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        let shouldUsePreferredSize = !hasShownWindow && usePreferredSizeOnFirstShow
        fitWindowToVisibleScreen(usePreferredSize: shouldUsePreferredSize)
        DispatchQueue.main.async { [weak self] in
            self?.fitWindowToVisibleScreen(usePreferredSize: shouldUsePreferredSize)
        }
        hasShownWindow = true
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

    func update(sessionActivityAppearance appearance: SessionActivityPanelAppearance) {
        sessionActivityAppearance = appearance
        activityBackgroundColorWell.color = NSColor.codexPet(hex: appearance.backgroundColor)
        activityOpacitySlider.doubleValue = appearance.opacity * 100
        activityContrastPopup.selectItem(at: appearance.automaticContrast ? 0 : 1)
        activityOpacityLabel.stringValue = "\(Int(activityOpacitySlider.doubleValue.rounded()))%"
        activityAppearancePreview.apply(appearance)
        updateAppearanceLabelsAndEnabledState()
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

    func update(update snapshot: StateletUpdateSnapshot) {
        let installed = snapshot.installedVersion
        if let candidate = snapshot.candidateVersion {
            updateVersionLabel.stringValue = "Installed: \(installed) · Available: \(candidate)"
        } else {
            updateVersionLabel.stringValue = "Installed version: \(installed)"
        }
        updateStatusLabel.stringValue = snapshot.status
        let status = snapshot.status.lowercased()
        updateStatusLabel.textColor = status.contains("unable")
            || status.contains("could not")
            || status.contains("failed")
            || status.contains("recovery")
            ? .systemRed
            : (snapshot.isReadyToInstall || snapshot.isScheduledForRestart ? .systemGreen : .secondaryLabelColor)
        updateNotesLabel.stringValue = snapshot.releaseNotes ?? ""
        updateNotesLabel.isHidden = snapshot.releaseNotes == nil
        updateProgress.isHidden = snapshot.progress == nil
        if let progress = snapshot.progress {
            updateProgress.doubleValue = min(max(progress, 0), 1) * 100
        }
        checkForUpdatesButton.isEnabled = !snapshot.isChecking
            && !snapshot.isReadyToInstall
            && !snapshot.isScheduledForRestart
            && !snapshot.isBlocked
        cancelUpdateButton.isEnabled = snapshot.isChecking && !snapshot.isBlocked
        installUpdateButton.isEnabled = snapshot.isReadyToInstall
            && !snapshot.isChecking
            && !snapshot.isBlocked
        automaticInstallCheckbox.state = snapshot.automaticInstallEnabled ? .on : .off
        automaticInstallCheckbox.isEnabled = !snapshot.isChecking
            && !snapshot.isScheduledForRestart
            && !snapshot.isBlocked
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
        let initialSectionIndex = selectedSectionIndex
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .followsWindowActiveState
        sidebar.setAccessibilityElement(false)
        sidebarScrollView.translatesAutoresizingMaskIntoConstraints = false
        sidebarScrollView.documentView = sidebarTableView
        sidebarScrollView.drawsBackground = false
        sidebarScrollView.hasVerticalScroller = true
        sidebarScrollView.autohidesScrollers = true
        sidebarScrollView.scrollerStyle = .overlay
        sidebarScrollView.setAccessibilityLabel("Settings navigation sidebar")
        sidebarTableView.headerView = nil
        sidebarTableView.backgroundColor = .clear
        sidebarTableView.style = .sourceList
        sidebarTableView.rowHeight = 32
        sidebarTableView.intercellSpacing = NSSize(width: 0, height: 2)
        sidebarTableView.allowsEmptySelection = false
        sidebarTableView.allowsMultipleSelection = false
        sidebarTableView.focusRingType = .default
        sidebarTableView.delegate = self
        sidebarTableView.dataSource = self
        sidebarTableView.setAccessibilityLabel("Settings navigation")
        sidebarTableView.setAccessibilityRole(.list)
        let sidebarColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SettingsSidebarColumn"))
        sidebarColumn.resizingMask = .autoresizingMask
        sidebarTableView.addTableColumn(sidebarColumn)
        sidebar.addSubview(sidebarScrollView)
        sidebarDivider.translatesAutoresizingMaskIntoConstraints = false
        sidebarDivider.boxType = .separator
        paneHost.translatesAutoresizingMaskIntoConstraints = false
        animationsPane.translatesAutoresizingMaskIntoConstraints = false
        dialogueVoiceView.translatesAutoresizingMaskIntoConstraints = false
        appearancePane.translatesAutoresizingMaskIntoConstraints = false
        generalPane.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsPane.translatesAutoresizingMaskIntoConstraints = false
        helpPane.translatesAutoresizingMaskIntoConstraints = false
        promptsPane.translatesAutoresizingMaskIntoConstraints = false
        recommendationPane.translatesAutoresizingMaskIntoConstraints = false
        for pane in [
            animationsPane,
            dialogueVoiceView,
            appearancePane,
            generalPane,
            diagnosticsPane,
            helpPane,
            promptsPane,
            recommendationPane,
        ] {
            pane.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        contentView.addSubview(sidebar)
        contentView.addSubview(sidebarDivider)
        contentView.addSubview(paneHost)
        let minimumPaneWidth = paneHost.widthAnchor.constraint(greaterThanOrEqualToConstant: 495)
        let minimumPaneHeight = paneHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 534)
        minimumPaneWidthConstraint = minimumPaneWidth
        minimumPaneHeightConstraint = minimumPaneHeight
        NSLayoutConstraint.activate([
            minimumPaneWidth,
            minimumPaneHeight,
            sidebar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: contentView.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
            sidebarScrollView.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            sidebarScrollView.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            sidebarScrollView.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 16),
            sidebarScrollView.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -12),
            sidebarDivider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarDivider.widthAnchor.constraint(equalToConstant: 1),
            sidebarDivider.topAnchor.constraint(equalTo: contentView.topAnchor),
            sidebarDivider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            paneHost.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            paneHost.leadingAnchor.constraint(equalTo: sidebarDivider.trailingAnchor, constant: 16),
            paneHost.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            paneHost.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
        ])
        buildAnimationsPane()
        configureDialogueVoicePane()
        buildAppearancePane()
        buildGeneralPane()
        buildDiagnosticsPane()
        buildHelpPane()
        buildPromptsPane()
        buildRecommendationPane()
        sidebarTableView.reloadData()
        sidebarTableView.selectRowIndexes(IndexSet(integer: initialSectionIndex), byExtendingSelection: false)
        changePane()
    }

    private func buildAnimationsPane() {
        publisherLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        publisherLabel.translatesAutoresizingMaskIntoConstraints = false
        let statusBox = NSBox()
        statusBox.translatesAutoresizingMaskIntoConstraints = true
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
        transitionLibrary.onImportMP4 = { [weak self] route in
            guard let self else { return }
            self.onImportTransitionMP4?(self.selectedTransitionScope, route)
        }
        transitionLibrary.onMigrateLegacy = { [weak self] in
            self?.onMigrateGlobalTransitionLegacy?()
        }
        transitionLibrary.onUseMovie = { [weak self] route in
            guard let self else { return }
            self.onUseTransitionMovie?(self.selectedTransitionScope, route)
        }
        transitionLibrary.onReplaceMP4 = { [weak self] route, path in
            guard let self else { return }
            self.onReplaceTransitionMP4?(self.selectedTransitionScope, route, path)
        }
        transitionLibrary.onReplaceMovie = { [weak self] route, path in
            guard let self else { return }
            self.onReplaceTransitionMovie?(self.selectedTransitionScope, route, path)
        }
        transitionLibrary.onPreviewOrStop = { [weak self] clip, shouldStop in
            if shouldStop {
                self?.onStopPreview?()
            } else {
                guard let self else { return }
                self.onPreviewTransition?(self.selectedTransitionScope, clip.route, clip.path)
            }
        }
        transitionLibrary.onRemove = { [weak self] clip in
            guard let self else { return }
            self.onRemoveTransition?(self.selectedTransitionScope, clip.route, clip.path)
        }
        transitionLibrary.onMove = { [weak self] route, path, index in
            guard let self else { return }
            self.onMoveTransition?(self.selectedTransitionScope, route, path, index)
        }
        transitionLibrary.onModeChange = { [weak self] route, mode in
            guard let self else { return }
            self.onTransitionModeChange?(self.selectedTransitionScope, route, mode)
        }
        transitionLibrary.onSetFixed = { [weak self] route, path in
            guard let self else { return }
            self.onSetFixedTransition?(self.selectedTransitionScope, route, path)
        }
        transitionLibrary.onScopeChange = { [weak self] scope in
            self?.selectedTransitionScope = scope
            self?.refreshRows()
        }
        animationsMode.selectedSegment = 0
        animationsMode.translatesAutoresizingMaskIntoConstraints = true
        animationsMode.target = self
        animationsMode.action = #selector(changeAnimationsMode)
        animationsMode.setAccessibilityLabel("Animation library mode")
        animationLibraryHost.translatesAutoresizingMaskIntoConstraints = true

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
        footer.translatesAutoresizingMaskIntoConstraints = true
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 6
        toolsRow.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        activityRow.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true

        animationsPane.addSubview(statusBox)
        animationsPane.addSubview(animationsMode)
        animationsPane.addSubview(animationLibraryHost)
        animationsPane.addSubview(footer)
        animationsPane.statusView = statusBox
        animationsPane.modeView = animationsMode
        animationsPane.libraryView = animationLibraryHost
        animationsPane.footerView = footer
        changeAnimationsMode()
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
        dialogueVoiceView.onConfigureVoxCPM2Profile = { [weak self] transcript in
            self?.onConfigureVoxCPM2Profile?(transcript)
        }
        dialogueVoiceView.onRemoveVoxCPM2Profile = { [weak self] profile in
            self?.onRemoveVoxCPM2Profile?(profile)
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

        activityBackgroundColorWell.target = self
        activityBackgroundColorWell.action = #selector(activityAppearanceChanged)
        if #available(macOS 14.0, *) {
            activityBackgroundColorWell.supportsAlpha = false
        }
        activityBackgroundColorWell.setAccessibilityLabel("Activity popup background color")
        activityBackgroundColorWell.color = NSColor.codexPet(hex: SessionActivityPanelAppearance.defaultBackgroundColor)
        activityOpacitySlider.target = self
        activityOpacitySlider.action = #selector(activityAppearanceChanged)
        activityOpacitySlider.isContinuous = false
        activityOpacitySlider.setAccessibilityLabel("Activity popup background opacity")
        activityOpacityLabel.alignment = .right
        activityOpacityLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        activityContrastPopup.addItems(withTitles: ["Automatic", "Custom"])
        activityContrastPopup.selectItem(at: 0)
        activityContrastPopup.target = self
        activityContrastPopup.action = #selector(activityAppearanceChanged)
        activityContrastPopup.setAccessibilityLabel("Activity popup contrast")
        activityAppearancePreview.translatesAutoresizingMaskIntoConstraints = false
        activityAppearancePreview.apply(sessionActivityAppearance)
        let activityHelp = NSTextField(
            wrappingLabelWithString: "The popup is draggable when click-through is off. Automatic contrast follows the system appearance and accessibility settings; custom mode uses the selected background color with readable labels."
        )
        activityHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        activityHelp.textColor = .secondaryLabelColor
        let resetActivityAppearance = NSButton(
            title: "Reset Activity Popup Appearance",
            target: self,
            action: #selector(resetActivityAppearance)
        )
        resetActivityAppearance.controlSize = .small
        let activityStack = NSStackView(views: [
            makeAppearanceRow(title: "Contrast", control: activityContrastPopup),
            makeAppearanceRow(title: "Background", control: activityBackgroundColorWell),
            makeAppearanceRow(title: "Opacity", control: activityOpacitySlider, value: activityOpacityLabel),
            activityAppearancePreview,
            activityHelp,
            resetActivityAppearance,
        ])
        activityStack.orientation = .vertical
        activityStack.alignment = .leading
        activityStack.spacing = 9
        let activityBox = makeSection(title: "Codex Activity Popup", content: activityStack)

        dialogueBackgroundColorWell.target = self
        dialogueBackgroundColorWell.action = #selector(dialogueAppearanceChanged)
        if #available(macOS 14.0, *) {
            dialogueBackgroundColorWell.supportsAlpha = false
        }
        dialogueBackgroundColorWell.setAccessibilityLabel("Dialogue bubble background color")
        dialogueBackgroundColorWell.color = NSColor.codexPet(hex: PetAppearanceConfiguration.defaultDialogueBackgroundColor)
        dialogueTextColorWell.target = self
        dialogueTextColorWell.action = #selector(dialogueAppearanceChanged)
        if #available(macOS 14.0, *) {
            dialogueTextColorWell.supportsAlpha = false
        }
        dialogueTextColorWell.setAccessibilityLabel("Dialogue bubble text color")
        dialogueTextColorWell.color = NSColor.codexPet(hex: PetAppearanceConfiguration.defaultDialogueTextColor)
        dialogueOpacitySlider.target = self
        dialogueOpacitySlider.action = #selector(dialogueAppearanceChanged)
        dialogueOpacitySlider.isContinuous = false
        dialogueOpacitySlider.setAccessibilityLabel("Dialogue bubble background opacity")
        dialogueOpacityLabel.alignment = .right
        dialogueOpacityLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        dialogueContrastPopup.addItems(withTitles: ["Automatic", "Custom"])
        dialogueContrastPopup.selectItem(at: 0)
        dialogueContrastPopup.target = self
        dialogueContrastPopup.action = #selector(dialogueAppearanceChanged)
        dialogueContrastPopup.setAccessibilityLabel("Dialogue bubble contrast")
        dialogueAppearancePreview.translatesAutoresizingMaskIntoConstraints = false
        dialogueAppearancePreview.apply(try! PetAppearanceConfiguration())
        let dialogueHelp = NSTextField(
            wrappingLabelWithString: "Automatic contrast follows light/dark mode and accessibility settings. Custom colors are checked at runtime; unsafe combinations fall back to a readable system color without changing dialogue text, voice, or playback timing."
        )
        dialogueHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        dialogueHelp.textColor = .secondaryLabelColor
        let dialogueStack = NSStackView(views: [
            makeAppearanceRow(title: "Contrast", control: dialogueContrastPopup),
            makeAppearanceRow(title: "Background", control: dialogueBackgroundColorWell),
            makeAppearanceRow(title: "Text", control: dialogueTextColorWell),
            makeAppearanceRow(title: "Opacity", control: dialogueOpacitySlider, value: dialogueOpacityLabel),
            dialogueAppearancePreview,
            dialogueHelp,
        ])
        dialogueStack.orientation = .vertical
        dialogueStack.alignment = .leading
        dialogueStack.spacing = 9
        let dialogueBox = makeSection(title: "Dialogue Bubble", content: dialogueStack)

        let reset = NSButton(title: "Reset Appearance", target: self, action: #selector(resetAppearance))
        reset.controlSize = .small
        let surfaceRow = NSStackView(views: [surfaceBox, borderBox])
        surfaceRow.orientation = .vertical
        surfaceRow.alignment = .leading
        surfaceRow.spacing = 12
        let overlayRow = NSStackView(views: [badgeBox, fpsBox])
        overlayRow.orientation = .vertical
        overlayRow.alignment = .leading
        overlayRow.spacing = 12
        let stack = NSStackView(views: [surfaceRow, overlayRow, dialogueBox, activityBox, reset])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        let (_, documentView) = makeScrollablePane(for: appearancePane)
        documentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            surfaceRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            surfaceBox.widthAnchor.constraint(equalTo: surfaceRow.widthAnchor),
            borderBox.widthAnchor.constraint(equalTo: surfaceRow.widthAnchor),
            overlayRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            badgeBox.widthAnchor.constraint(equalTo: overlayRow.widthAnchor),
            fpsBox.widthAnchor.constraint(equalTo: overlayRow.widthAnchor),
            dialogueBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            activityBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
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
        let resetActivityPosition = NSButton(
            title: "Reset Activity Popup Position",
            target: self,
            action: #selector(resetActivityPositionAction)
        )
        resetActivityPosition.alignment = .left

        let petWindowStack = NSStackView(views: [sizeTitle, sizeControls, alwaysOnTopCheckbox, alwaysOnTopHelp, clickThroughCheckbox, clickHelp, fullScreenCheckbox, resetPosition, resetActivityPosition])
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
        let managedMediaLabel = NSTextField(
            wrappingLabelWithString: "Managed media location: ~/Library/Application Support/Statelet/media/ (Statelet.app stays media-free; external source files are not moved or deleted)."
        )
        managedMediaLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        managedMediaLabel.textColor = .secondaryLabelColor
        let localStack = NSStackView(views: [launchHelp, managedMediaLabel, localButtons])
        localStack.orientation = .vertical
        localStack.alignment = .leading
        localStack.spacing = 9
        let localBox = makeSection(title: "App and Local Data", content: localStack)

        let stack = NSStackView(views: [petWindowBox, motionBox, localBox])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        let (_, documentView) = makeScrollablePane(for: generalPane)
        documentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            petWindowBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            motionBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            localBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
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
        let title = NSTextField(labelWithString: "Using Statelet")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let introduction = NSTextField(wrappingLabelWithString: "Statelet is a local-first Codex companion. This guide keeps the supported workflow, recovery paths and privacy boundary in one place.")
        introduction.textColor = .secondaryLabelColor

        let quickStart = makeSection(
            title: "First launch",
            content: NSTextField(wrappingLabelWithString: "Open the Statelet menu-bar icon and choose Settings. Start with Animations → Idle, import a verified MP4 that you own or are authorized to use, then restart Codex if it was already running when Statelet was installed. If click-through is enabled, the menu-bar icon remains the recovery path.")
        )
        let lifecycle = makeSection(
            title: "Lifecycle states",
            content: NSTextField(wrappingLabelWithString: "Idle means no active Codex turn. Running means Codex is working. Waiting means Codex needs input or permission. Review means tests, lint, type checks or review work are active. Statelet keeps these records local and does not store prompts or tool output.")
        )
        let media = makeSection(
            title: "Animation and voice",
            content: NSTextField(wrappingLabelWithString: "Animation imports run through HEVC-with-alpha and playback validation. Use the Animations pane for playlists, transitions and Reduce Motion posters. GPT-SoVITS, Qwen3-TTS and VoxCPM2 run locally; model files, reference audio, dialogue and generated speech stay in private Application Support and are never bundled in releases.")
        )
        let managedMediaLabel = NSTextField(
            wrappingLabelWithString: "Managed media location: ~/Library/Application Support/Statelet/media/. Downloads and Finder paths are import sources only. Successful verified media, maps, reports, and character assets remain playable here if the source is moved or removed; Statelet.app never becomes a user-media container."
        )
        managedMediaLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let managedMediaButton = NSButton(
            title: "Open Managed Media in Finder",
            target: self,
            action: #selector(revealMediaFolder)
        )
        managedMediaButton.bezelStyle = .rounded
        managedMediaButton.setAccessibilityLabel("Open managed media location in Finder")
        let managedMediaStack = NSStackView(views: [managedMediaLabel, managedMediaButton])
        managedMediaStack.orientation = .vertical
        managedMediaStack.alignment = .leading
        managedMediaStack.spacing = 8
        let managedMedia = makeSection(title: "Managed media location", content: managedMediaStack)
        let accessibility = makeSection(
            title: "Interaction and accessibility",
            content: NSTextField(wrappingLabelWithString: "Settings supports keyboard navigation and VoiceOver labels. Reduce Motion replaces transition motion with verified posters when available. If click-through prevents pointer access to the pet, use the Statelet menu-bar icon to reopen Settings or turn click-through off.")
        )
        let recovery = makeSection(
            title: "Recovery and diagnostics",
            content: NSTextField(wrappingLabelWithString: "Use Diagnostics → Refresh when startup, conversion or lifecycle data looks stale. Repair Startup only touches Statelet-managed LaunchAgents. The app keeps the current media and settings when a conversion, update check or installation step fails.")
        )

        let docsButton = NSButton(title: "Open Usage Guide", target: self, action: #selector(openUsageGuide))
        docsButton.bezelStyle = .rounded
        docsButton.setAccessibilityLabel("Open Statelet usage guide")
        let releaseButton = NSButton(title: "Open Releases", target: self, action: #selector(openReleasesPage))
        releaseButton.bezelStyle = .rounded
        releaseButton.setAccessibilityLabel("Open Statelet releases")
        let supportButton = NSButton(title: "Open Support", target: self, action: #selector(openSupportPage))
        supportButton.bezelStyle = .rounded
        supportButton.setAccessibilityLabel("Open Statelet support")
        let links = NSStackView(views: [docsButton, releaseButton, supportButton])
        links.orientation = .horizontal
        links.alignment = .centerY
        links.spacing = 8

        updateVersionLabel.stringValue = "Installed version: \(StateletVersion.current().description)"
        updateVersionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        updateStatusLabel.textColor = .secondaryLabelColor
        updateStatusLabel.setAccessibilityLabel("Update status")
        checkForUpdatesButton.target = self
        checkForUpdatesButton.action = #selector(checkForUpdates)
        checkForUpdatesButton.bezelStyle = .rounded
        checkForUpdatesButton.setAccessibilityLabel("Check for Statelet updates")
        cancelUpdateButton.target = self
        cancelUpdateButton.action = #selector(cancelUpdate)
        cancelUpdateButton.bezelStyle = .rounded
        cancelUpdateButton.isEnabled = false
        cancelUpdateButton.setAccessibilityLabel("Cancel Statelet update")
        installUpdateButton.target = self
        installUpdateButton.action = #selector(installUpdate)
        installUpdateButton.bezelStyle = .rounded
        installUpdateButton.isEnabled = false
        installUpdateButton.setAccessibilityLabel("Install verified Statelet update at restart")
        automaticInstallCheckbox.target = self
        automaticInstallCheckbox.action = #selector(automaticInstallChanged)
        automaticInstallCheckbox.setAccessibilityLabel("Automatically install verified updates")
        automaticInstallCheckbox.setAccessibilityHelp("Download verified updates in the background and install them only at a safe restart boundary.")
        updateProgress.isIndeterminate = false
        updateProgress.isHidden = true
        updateProgress.controlSize = .small
        let updateButtons = NSStackView(views: [checkForUpdatesButton, cancelUpdateButton, installUpdateButton])
        updateButtons.orientation = .horizontal
        updateButtons.alignment = .centerY
        updateButtons.spacing = 8
        updateNotesLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        updateNotesLabel.textColor = .secondaryLabelColor
        updateNotesLabel.isHidden = true
        let updateStack = NSStackView(views: [updateVersionLabel, updateStatusLabel, updateNotesLabel, updateProgress, updateButtons, automaticInstallCheckbox])
        updateStack.orientation = .vertical
        updateStack.alignment = .leading
        updateStack.spacing = 8
        let updateBox = makeSection(title: "Updates", content: updateStack)

        let stack = NSStackView(views: [
            title,
            introduction,
            quickStart,
            lifecycle,
            media,
            managedMedia,
            accessibility,
            recovery,
            links,
            updateBox,
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        for view in [quickStart, lifecycle, media, managedMedia, accessibility, recovery, updateBox] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let (_, document) = makeScrollablePane(for: helpPane)
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4),
        ])
    }

    private func buildPromptsPane() {
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
        scroll.setAccessibilityLabel("Settings pane scroll area")
        scroll.documentView = helpPromptTextView

        let checklist = NSTextField(wrappingLabelWithString: "Before import, inspect the generated MP4. The first and last frames should be pixel-identical for a seamless loop. Require a completely uniform RGB #00FF00 pure green background; no white background, scene, floor, material texture, shadow, reflection, particles, text, logo, watermark. Also reject cuts, camera movement, gradients, motion blur, green spill on the character, or any foreground touching the frame edge.")
        checklist.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        checklist.textColor = .secondaryLabelColor

        for view in [title, introduction, promptControls, checklist] {
            view.translatesAutoresizingMaskIntoConstraints = false
            promptsPane.addSubview(view)
        }
        promptsPane.addSubview(scroll)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: promptsPane.topAnchor, constant: 4),
            title.leadingAnchor.constraint(equalTo: promptsPane.leadingAnchor),
            title.trailingAnchor.constraint(equalTo: promptsPane.trailingAnchor),
            introduction.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            introduction.leadingAnchor.constraint(equalTo: promptsPane.leadingAnchor),
            introduction.trailingAnchor.constraint(equalTo: promptsPane.trailingAnchor),
            promptControls.topAnchor.constraint(equalTo: introduction.bottomAnchor, constant: 14),
            promptControls.leadingAnchor.constraint(equalTo: promptsPane.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: promptControls.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: promptsPane.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: promptsPane.trailingAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 330),
            checklist.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            checklist.leadingAnchor.constraint(equalTo: promptsPane.leadingAnchor),
            checklist.trailingAnchor.constraint(equalTo: promptsPane.trailingAnchor),
            checklist.bottomAnchor.constraint(lessThanOrEqualTo: promptsPane.bottomAnchor),
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
        let (_, documentView) = makeScrollablePane(for: recommendationPane)
        documentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            loopBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            backgroundBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            framingBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            toolsBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
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

    private func makeScrollablePane(for pane: NSView) -> (scroll: NSScrollView, document: NSView) {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.setAccessibilityLabel("Settings pane scroll area")

        let document = TopAlignedSettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        pane.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: pane.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
        ])
        return (scroll, document)
    }

    private func makeAppearanceRow(title: String, control: NSView, value: NSTextField? = nil) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .left
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        if control is NSSlider {
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
            control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        dialogueBackgroundColorWell.color = NSColor.codexPet(hex: appearance.dialogueBackgroundColor)
        dialogueTextColorWell.color = NSColor.codexPet(hex: appearance.dialogueTextColor)
        dialogueOpacitySlider.doubleValue = appearance.dialogueBackgroundOpacity * 100
        dialogueContrastPopup.selectItem(at: appearance.dialogueContrastMode == .automatic ? 0 : 1)
        dialogueOpacityLabel.stringValue = "\(Int(dialogueOpacitySlider.doubleValue.rounded()))%"
        dialogueAppearancePreview.apply(appearance)
        activityOpacityLabel.stringValue = "\(Int(activityOpacitySlider.doubleValue.rounded()))%"
        activityAppearancePreview.apply(sessionActivityAppearance)
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
            fpsLabelSize: stateLabelSizes[fpsSizeIndex],
            dialogueBackgroundColor: dialogueBackgroundColorWell.color.codexPetHex,
            dialogueTextColor: dialogueTextColorWell.color.codexPetHex,
            dialogueBackgroundOpacity: dialogueOpacitySlider.doubleValue / 100,
            dialogueContrastMode: dialogueContrastPopup.indexOfSelectedItem == 0 ? .automatic : .custom
        )
    }

    private func currentSessionActivityAppearance() -> SessionActivityPanelAppearance? {
        try? SessionActivityPanelAppearance(
            backgroundColor: activityBackgroundColorWell.color.codexPetHex,
            opacity: activityOpacitySlider.doubleValue / 100,
            automaticContrast: activityContrastPopup.indexOfSelectedItem == 0
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
        let dialogueCustom = dialogueContrastPopup.indexOfSelectedItem == 1
        dialogueBackgroundColorWell.isEnabled = dialogueCustom
        dialogueTextColorWell.isEnabled = dialogueCustom
        activityBackgroundColorWell.isEnabled = activityContrastPopup.indexOfSelectedItem == 1
        dialogueOpacityLabel.stringValue = "\(Int(dialogueOpacitySlider.doubleValue.rounded()))%"
        activityOpacityLabel.stringValue = "\(Int(activityOpacitySlider.doubleValue.rounded()))%"
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
        var transitionClips: [SettingsTransitionClip]
        let globalFallbackRoutes: Set<StateTransitionKey>
        let globalLegacyRouteCount: Int
        switch selectedTransitionScope {
        case .character:
            transitionClips = snapshot.mediaMap.transitions.flatMap { key, playlist in
                playlist.entries.enumerated().map { index, entry in
                    SettingsTransitionClip(
                        route: .directional(source: key.from, destination: key.to),
                        path: entry.path,
                        exists: FileManager.default.isReadableFile(
                            atPath: snapshot.mediaMap.resolvedURL(for: entry, relativeTo: snapshot.mediaMapURL).path
                        ),
                        position: index,
                        count: playlist.entries.count,
                        mode: playlist.mode,
                        isFixed: entry.path == playlist.fixedPath
                    )
                }
            }
            globalLegacyRouteCount = 0
        case .global:
            if let playlist = snapshot.globalTransitionLibrary.universalPlaylist {
                transitionClips = playlist.entries.enumerated().map { index, entry in
                    SettingsTransitionClip(
                        route: .global,
                        path: entry.path,
                        exists: FileManager.default.isReadableFile(
                            atPath: snapshot.globalTransitionLibrary.resolvedURL(
                                for: entry,
                                relativeTo: snapshot.globalTransitionLibraryURL
                            ).path
                        ),
                        position: index,
                        count: playlist.entries.count,
                        mode: playlist.mode,
                        isFixed: entry.path == playlist.fixedPath
                    )
                }
            } else {
                // Conflicting legacy route-keyed data is retained by the
                // model and shown as a migration notice, never flattened by
                // silently choosing one route.
                transitionClips = []
            }
            globalLegacyRouteCount = snapshot.globalTransitionLibrary.requiresLegacyMigration
                ? snapshot.globalTransitionLibrary.transitions.count
                : 0
        }
        if snapshot.globalTransitionLibrary.universalPlaylist != nil {
            globalFallbackRoutes = Set(
                PetState.allCases.flatMap { source in
                    PetState.allCases.compactMap { destination in
                        guard source != destination else { return nil }
                        return try? StateTransitionKey(from: source, to: destination)
                    }
                }
            )
        } else if snapshot.globalTransitionLibrary.legacyRouteFallbackIsActive {
            globalFallbackRoutes = Set(snapshot.globalTransitionLibrary.transitions.keys)
        } else {
            globalFallbackRoutes = []
        }
        if selectedTransitionScope == .character {
            transitionClips += snapshot.mediaMap.inStateTransitions.map { state, entry in
                SettingsTransitionClip(
                    route: .directional(source: state, destination: state),
                    path: entry.path,
                    exists: FileManager.default.isReadableFile(atPath: snapshot.mediaMap.resolvedURL(for: entry, relativeTo: snapshot.mediaMapURL).path),
                    position: 0,
                    count: 1,
                    mode: .fixed,
                    isFixed: true
                )
            }
        }
        transitionLibrary.update(
            clips: transitionClips,
            globalFallbackRoutes: globalFallbackRoutes,
            globalLegacyRouteCount: globalLegacyRouteCount,
            previewPath: snapshot.preview?.path,
            reduceMotion: snapshot.reduceMotion,
            busy: globallyBusy,
            characterName: activeCharacterName,
            scope: selectedTransitionScope
        )
    }

    @objc private func changeAnimationsMode() {
        let selectedLibrary: NSView = animationsMode.selectedSegment == 1
            ? transitionLibrary
            : animationLibrary
        guard displayedAnimationLibrary !== selectedLibrary else { return }

        NSLayoutConstraint.deactivate(displayedAnimationLibraryConstraints)
        displayedAnimationLibraryConstraints.removeAll()
        displayedAnimationLibrary?.removeFromSuperview()
        animationLibraryHost.addSubview(selectedLibrary)
        displayedAnimationLibraryConstraints = [
            selectedLibrary.leadingAnchor.constraint(equalTo: animationLibraryHost.leadingAnchor),
            selectedLibrary.trailingAnchor.constraint(equalTo: animationLibraryHost.trailingAnchor),
            selectedLibrary.topAnchor.constraint(equalTo: animationLibraryHost.topAnchor),
            selectedLibrary.bottomAnchor.constraint(equalTo: animationLibraryHost.bottomAnchor),
        ]
        NSLayoutConstraint.activate(displayedAnimationLibraryConstraints)
        displayedAnimationLibrary = selectedLibrary
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
        persistSettingsWindowSize()
        libraryRevisionTimer?.invalidate()
        libraryRevisionTimer = nil
    }

    func windowDidResize(_ notification: Notification) {
        persistSettingsWindowSize()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        fitWindowToVisibleScreen(usePreferredSize: false)
    }

    private func changePane() {
        let panes = [
            animationsPane,
            dialogueVoiceView,
            appearancePane,
            generalPane,
            diagnosticsPane,
            helpPane,
            promptsPane,
            recommendationPane,
        ]
        let requestedIndex = sidebarTableView.selectedRow
        let index = panes.indices.contains(requestedIndex) ? requestedIndex : selectedSectionIndex
        selectedSectionIndex = index
        defaults.set(index, forKey: Self.selectedSectionDefaultsKey)
        let selectedPane = panes[index]
        guard displayedPane !== selectedPane else { return }
        let preservedContentSize = window?.contentLayoutRect.size

        NSLayoutConstraint.deactivate(displayedPaneConstraints)
        displayedPaneConstraints.removeAll()
        displayedPane?.removeFromSuperview()
        paneHost.addSubview(selectedPane)
        displayedPaneConstraints = [
            selectedPane.leadingAnchor.constraint(equalTo: paneHost.leadingAnchor),
            selectedPane.trailingAnchor.constraint(equalTo: paneHost.trailingAnchor),
            selectedPane.topAnchor.constraint(equalTo: paneHost.topAnchor),
            selectedPane.bottomAnchor.constraint(equalTo: paneHost.bottomAnchor),
        ]
        NSLayoutConstraint.activate(displayedPaneConstraints)
        displayedPane = selectedPane
        if let preservedContentSize {
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.setContentSize(preservedContentSize)
        }
    }

    private func fitWindowToVisibleScreen(usePreferredSize: Bool) {
        guard let window,
              let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let safeFrame = screen.visibleFrame.insetBy(dx: Self.screenMargin, dy: Self.screenMargin)
        guard safeFrame.width > 0, safeFrame.height > 0 else { return }

        let maximumContentSize = window.contentRect(forFrameRect: safeFrame).size
        let effectiveMinimumSize = NSSize(
            width: min(Self.minimumContentSize.width, maximumContentSize.width),
            height: min(Self.minimumContentSize.height, maximumContentSize.height)
        )
        minimumPaneWidthConstraint?.constant = max(
            0,
            effectiveMinimumSize.width - Self.sidebarWidth - 1 - 36
        )
        minimumPaneHeightConstraint?.constant = max(0, effectiveMinimumSize.height - 36)
        window.contentMinSize = effectiveMinimumSize
        window.contentMaxSize = maximumContentSize

        let currentSize = window.contentLayoutRect.size
        let requestedSize = usePreferredSize ? Self.preferredContentSize : currentSize
        let targetSize = NSSize(
            width: min(max(requestedSize.width, effectiveMinimumSize.width), maximumContentSize.width),
            height: min(max(requestedSize.height, effectiveMinimumSize.height), maximumContentSize.height)
        )
        window.setContentSize(targetSize)

        var frame = window.frame
        frame.origin.x = min(max(frame.origin.x, safeFrame.minX), safeFrame.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, safeFrame.minY), safeFrame.maxY - frame.height)
        window.setFrame(frame, display: false)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        persistSettingsWindowSize()
    }

    @objc private func resetSettingsWindowSize() {
        SettingsWindowSizeStore.reset(in: defaults)
        usePreferredSizeOnFirstShow = false
        fitWindowToVisibleScreen(usePreferredSize: true)
    }

    private func persistSettingsWindowSize() {
        guard let window else { return }
        SettingsWindowSizeStore.persist(window.contentLayoutRect.size, to: defaults)
    }

    @objc private func helpStateChanged() { updateHelpPrompt() }

    @objc private func checkForUpdates() { onCheckForUpdates?() }

    @objc private func cancelUpdate() { onCancelUpdate?() }

    @objc private func installUpdate() { onInstallUpdate?() }

    @objc private func automaticInstallChanged() {
        onAutomaticInstallChange?(automaticInstallCheckbox.state == .on)
    }

    @objc private func openUsageGuide() {
        guard let url = URL(string: "https://github.com/Coke1120/statelet-codex-pet-macos/blob/main/docs/USAGE.md") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openReleasesPage() {
        guard let url = URL(string: "https://github.com/Coke1120/statelet-codex-pet-macos/releases") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openSupportPage() {
        guard let url = URL(string: "https://github.com/Coke1120/statelet-codex-pet-macos/issues") else { return }
        NSWorkspace.shared.open(url)
    }

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
    @objc private func resetActivityPositionAction() { onResetActivityPosition?() }
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
        dialogueAppearancePreview.apply(currentAppearance() ?? (try! PetAppearanceConfiguration()))
        publishWindowSettings(width: sizeSlider.doubleValue)
    }

    @objc private func dialogueAppearanceChanged() {
        updateAppearanceLabelsAndEnabledState()
        guard let appearance = currentAppearance() else { return }
        dialogueAppearancePreview.apply(appearance)
        publishWindowSettings(width: sizeSlider.doubleValue)
    }

    @objc private func activityAppearanceChanged() {
        guard let appearance = currentSessionActivityAppearance() else { return }
        sessionActivityAppearance = appearance
        activityAppearancePreview.apply(appearance)
        onSessionActivityAppearanceChange?(appearance)
    }

    @objc private func resetActivityAppearance() {
        let appearance = try! SessionActivityPanelAppearance()
        update(sessionActivityAppearance: appearance)
        onSessionActivityAppearanceChange?(appearance)
    }

    @objc private func resetAppearance() {
        updateAppearanceControls(try! PetAppearanceConfiguration())
        publishWindowSettings(width: sizeSlider.doubleValue)
        resetActivityAppearance()
    }

    @objc private func showSetupGuide() {
        let alert = NSAlert()
        alert.messageText = "Prepare Local Conversion Tools"
        alert.informativeText = "Install ffmpeg with Homebrew, then choose a Python 3 executable containing NumPy and Pillow. Developers can also set STATELET_ALPHA_PYTHON before launch. Conversion and verification stay entirely on this Mac."
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

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        Self.sectionLabels.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard Self.sectionLabels.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("SettingsSidebarCell")
        let cell: NSTableCellView
        if let reusedCell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reusedCell
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            cell.textField = label
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let label = Self.sectionLabels[row]
        cell.textField?.stringValue = label
        cell.textField?.setAccessibilityLabel(label)
        cell.setAccessibilityElement(true)
        cell.setAccessibilityRole(.staticText)
        cell.setAccessibilityLabel(label)
        cell.setAccessibilityValue(row == sidebarTableView.selectedRow ? "Selected" : "Not selected")
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        changePane()
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
