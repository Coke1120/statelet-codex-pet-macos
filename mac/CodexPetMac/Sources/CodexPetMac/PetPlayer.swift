import AVFoundation
import AppKit
import CodexPetCore
import OSLog

private enum PlaybackFailureReason: String {
    case unmapped
    case unreadable
    case itemFailed = "item_failed"
    case playbackFailed = "playback_failed"
    case readinessTimeout = "readiness_timeout"

    func userMessage(for state: PetState) -> String {
        switch self {
        case .unmapped: return "No media mapped for \(state.rawValue)"
        case .unreadable: return "Media is missing or unreadable"
        case .itemFailed: return "Media could not be decoded"
        case .playbackFailed: return "Playback stopped unexpectedly"
        case .readinessTimeout: return "Media did not become ready"
        }
    }
}

enum PlaybackStartDisposition: String {
    case preparing
    case presented
    case failed
}

enum PlaybackPresentationEvent {
    case ready
    case failed
}

enum LifecycleTransitionDeadline {
    static func uptimeNanoseconds(
        startedAt: UInt64,
        maximumDuration: TimeInterval = LifecycleTransitionMediaPolicy.maximumDuration
    ) -> UInt64 {
        guard maximumDuration.isFinite, maximumDuration > 0 else { return startedAt }
        let boundedDuration = maximumDuration
        let durationNanoseconds = UInt64(min(
            Double(UInt64.max),
            boundedDuration * 1_000_000_000
        ))
        let (deadline, overflow) = startedAt.addingReportingOverflow(durationNanoseconds)
        return overflow ? UInt64.max : deadline
    }
}

enum PlaybackPresentationStatus: Equatable {
    case awaiting
    case preparing(PetState)
    case presented(PetState)
    case previewing(requested: PetState, clipName: String)
    case placeholder(PetState)
    case retained(requested: PetState, displayed: PetState)

    func menuTitle(requestedState: PetState) -> String {
        switch self {
        case .awaiting:
            return "State: \(requestedState.rawValue)"
        case let .preparing(state):
            return "State: \(state.rawValue) — preparing"
        case let .presented(state):
            return "State: \(state.rawValue)"
        case let .previewing(requested, clipName):
            return "State: \(requested.rawValue) — previewing \(clipName) once"
        case let .placeholder(state):
            return "State: \(state.rawValue) — media unavailable"
        case let .retained(requested, displayed):
            return "State: \(requested.rawValue) — showing \(displayed.rawValue)"
        }
    }
}

/// Retains a resume request while `AVPlayerLooper` is still populating its
/// queue. A later suspension cancels the deferred request; clearing that
/// suspension produces a fresh directive from `PlaybackSuspensionPolicy`.
struct DeferredPlaybackResume: Equatable {
    private(set) var rate: Double?

    mutating func prepare(rate: Double, currentItemAvailable: Bool) -> Double? {
        guard !currentItemAvailable else {
            self.rate = nil
            return rate
        }
        self.rate = rate
        return nil
    }

    mutating func consumeWhenCurrentItemBecomesAvailable() -> Double? {
        defer { rate = nil }
        return rate
    }

    mutating func cancel() {
        rate = nil
    }
}

final class PetPlayerView: NSView {
    private struct ResizeEdges: OptionSet {
        let rawValue: UInt8

        static let left = ResizeEdges(rawValue: 1 << 0)
        static let right = ResizeEdges(rawValue: 1 << 1)
        static let bottom = ResizeEdges(rawValue: 1 << 2)
        static let top = ResizeEdges(rawValue: 1 << 3)
    }

    private struct PointerInteraction {
        let mouse: NSPoint
        let windowFrame: NSRect
        let resizeEdges: ResizeEdges
        var didDrag = false
    }

    private static let resizeHandleWidth: CGFloat = 8
    private static let minimumWindowWidth: CGFloat = 160
    private static let dragThreshold: CGFloat = 3
    private static let resizeNorthwestSoutheastCursor = diagonalResizeCursor(
        symbolName: "arrow.up.left.and.arrow.down.right"
    )
    private static let resizeNortheastSouthwestCursor = diagonalResizeCursor(
        symbolName: "arrow.up.right.and.arrow.down.left"
    )

    private(set) var playerLayer = AVPlayerLayer()
    private(set) var destinationPlayerLayer = AVPlayerLayer()
    let lifecycleTransitionPlayerLayer = AVPlayerLayer()
    private let posterView = NSImageView()
    private let placeholderLabel = NSTextField(wrappingLabelWithString: "")
    private let stateBadge = PetStateBadgeView()
    private let fpsBadge = NSTextField(labelWithString: "")
    private let dialogueBubble = NSView()
    private let dialogueLabel = NSTextField(wrappingLabelWithString: "")
    private let nextClipButton = NSButton()
    private let temporaryStateButton = NSButton()
    private let quickControls = NSStackView()
    private var appearanceConfiguration = try! PetAppearanceConfiguration()
    private var requestedState: PetState = .idle
    private var presentedState: PetState = .idle
    private var liveState: PetState = .idle
    private var displayedState: PetState = .idle
    private var manualPreviewState: PetState?
    private var publisherBadgeStatus: PublisherBadgeVisualStatus = .checking
    private var accessibleReducedMotion = false
    private var accessiblePublisherHealth = "publisher status checking"
    private var accessiblePresentationSummary: String?
    private var fpsBadgeIsEnabled = false
    private var fpsBadgeHasReading = false
    private var pointerInteraction: PointerInteraction?
    var contextMenuProvider: (() -> NSMenu?)?
    var onAdvanceClip: (() -> Void)?
    var onPetClick: (() -> Void)?
    var onResizeEnded: ((NSSize) -> Void)?
    var onTemporaryStateSelection: ((PetState?) -> Void)?

    var isFPSBadgeEnabled: Bool { fpsBadgeIsEnabled }
    var hasVisiblePoster: Bool { !posterView.isHidden && posterView.image != nil }

    // Keep AppKit from consuming the gesture as background movement. The
    // explicit delta-based fallback below works for real and synthesized drag
    // sequences while preserving the nonactivating panel's focus behavior.
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.clear.cgColor
        playerLayer.zPosition = 0
        layer?.addSublayer(playerLayer)
        destinationPlayerLayer.videoGravity = .resizeAspect
        destinationPlayerLayer.backgroundColor = NSColor.clear.cgColor
        destinationPlayerLayer.isHidden = true
        destinationPlayerLayer.zPosition = 1
        layer?.addSublayer(destinationPlayerLayer)
        lifecycleTransitionPlayerLayer.videoGravity = .resizeAspect
        lifecycleTransitionPlayerLayer.backgroundColor = NSColor.clear.cgColor
        lifecycleTransitionPlayerLayer.isHidden = true
        lifecycleTransitionPlayerLayer.zPosition = 2
        layer?.addSublayer(lifecycleTransitionPlayerLayer)

        posterView.imageScaling = .scaleProportionallyUpOrDown
        posterView.isHidden = true
        addSubview(posterView)

        placeholderLabel.alignment = .center
        placeholderLabel.textColor = NSColor.secondaryLabelColor
        placeholderLabel.font = NSFont.systemFont(ofSize: 12)
        placeholderLabel.isHidden = true
        placeholderLabel.maximumNumberOfLines = 3
        placeholderLabel.lineBreakMode = .byWordWrapping
        addSubview(placeholderLabel)

        stateBadge.translatesAutoresizingMaskIntoConstraints = true
        addSubview(stateBadge)
        configureFPSBadge()
        configureQuickControls()
        configureDialogueBubble()
        applyAppearance(appearanceConfiguration)
        updateStateBadge(state: .idle, publisherStatus: .checking)
        updateQuickControls(
            canAdvanceClip: false,
            liveState: .idle,
            displayedState: .idle,
            manualPreview: nil
        )
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Statelet")
    }

    required init?(coder: NSCoder) {
        fatalError("PetPlayerView does not support NSCoder initialization")
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
        destinationPlayerLayer.frame = bounds
        lifecycleTransitionPlayerLayer.frame = bounds
        posterView.frame = bounds
        let placeholderBounds = bounds.insetBy(dx: 16, dy: 16)
        placeholderLabel.preferredMaxLayoutWidth = placeholderBounds.width
        let placeholderHeight = min(
            placeholderBounds.height,
            max(placeholderLabel.fittingSize.height, 1)
        )
        placeholderLabel.frame = NSRect(
            x: placeholderBounds.minX,
            y: placeholderBounds.midY - placeholderHeight / 2,
            width: placeholderBounds.width,
            height: placeholderHeight
        )
        layoutFPSBadge()
        layoutStateBadge()
        layoutQuickControls()
        layoutDialogueBubble()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let width = Self.resizeHandleWidth
        let corner = width * 2
        let horizontalSpan = max(0, bounds.width - corner * 2)
        let verticalSpan = max(0, bounds.height - corner * 2)

        addCursorRect(NSRect(x: 0, y: 0, width: corner, height: corner), cursor: Self.resizeNortheastSouthwestCursor)
        addCursorRect(NSRect(x: bounds.maxX - corner, y: 0, width: corner, height: corner), cursor: Self.resizeNorthwestSoutheastCursor)
        addCursorRect(NSRect(x: 0, y: bounds.maxY - corner, width: corner, height: corner), cursor: Self.resizeNorthwestSoutheastCursor)
        addCursorRect(NSRect(x: bounds.maxX - corner, y: bounds.maxY - corner, width: corner, height: corner), cursor: Self.resizeNortheastSouthwestCursor)
        addCursorRect(NSRect(x: corner, y: 0, width: horizontalSpan, height: width), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: corner, y: bounds.maxY - width, width: horizontalSpan, height: width), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: corner, width: width, height: verticalSpan), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.maxX - width, y: corner, width: width, height: verticalSpan), cursor: .resizeLeftRight)
    }

    private static func diagonalResizeCursor(symbolName: String) -> NSCursor {
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Resize") else {
            return .crosshair
        }
        image.size = NSSize(width: 18, height: 18)
        return NSCursor(image: image, hotSpot: NSPoint(x: 9, y: 9))
    }

    private func configureFPSBadge() {
        fpsBadge.alignment = .center
        fpsBadge.lineBreakMode = .byClipping
        fpsBadge.translatesAutoresizingMaskIntoConstraints = true
        fpsBadge.wantsLayer = true
        fpsBadge.layer?.cornerCurve = .continuous
        fpsBadge.isHidden = true
        fpsBadge.setAccessibilityLabel("Video frame rate")
        addSubview(fpsBadge)
    }

    private func applyFPSBadgeAppearance(
        configuration: PetAppearanceConfiguration,
        reduceTransparency: Bool
    ) {
        fpsBadgeIsEnabled = configuration.showFPS
        fpsBadge.textColor = NSColor.codexPet(hex: configuration.fpsColor)
        fpsBadge.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(
            reduceTransparency ? 1 : 0.82
        ).cgColor
        let fontSize: CGFloat
        switch configuration.fpsLabelSize {
        case .small: fontSize = 9
        case .regular: fontSize = 11
        case .large: fontSize = 14
        }
        fpsBadge.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold)
        fpsBadge.layer?.cornerRadius = fontSize
        fpsBadge.isHidden = !fpsBadgeIsEnabled || !fpsBadgeHasReading
        needsLayout = true
    }

    /// Updates truthful presentation data. Passing only a nominal rate labels
    /// it as nominal; passing no usable rates hides the badge.
    func updateFPSBadge(
        nominalFramesPerSecond nominal: Double?,
        intendedFramesPerSecond intended: Double?,
        reducedMotion: Bool
    ) {
        if reducedMotion {
            fpsBadge.stringValue = "Still"
            fpsBadge.setAccessibilityValue("Still image because Reduce Motion is enabled")
            fpsBadgeHasReading = true
        } else {
            let nominal = Self.usableFramesPerSecond(nominal)
            let intended = Self.usableFramesPerSecond(intended)
            switch (intended, nominal) {
            case let (.some(intended), .some(nominal)) where abs(intended - nominal) < 0.05:
                fpsBadge.stringValue = "\(Self.formatFPS(intended)) FPS"
                fpsBadge.setAccessibilityValue("Intended playback and nominal frame rate are \(Self.formatFPS(intended)) frames per second")
                fpsBadgeHasReading = true
            case let (.some(intended), .some(nominal)):
                fpsBadge.stringValue = "\(Self.formatFPS(intended)) FPS · \(Self.formatFPS(nominal)) nominal"
                fpsBadge.setAccessibilityValue("Intended playback \(Self.formatFPS(intended)) frames per second; source nominal \(Self.formatFPS(nominal)) frames per second")
                fpsBadgeHasReading = true
            case let (.some(intended), nil):
                fpsBadge.stringValue = "\(Self.formatFPS(intended)) FPS intended"
                fpsBadge.setAccessibilityValue("Intended playback \(Self.formatFPS(intended)) frames per second")
                fpsBadgeHasReading = true
            case let (nil, .some(nominal)):
                fpsBadge.stringValue = "\(Self.formatFPS(nominal)) FPS nominal"
                fpsBadge.setAccessibilityValue("Nominal \(Self.formatFPS(nominal)) frames per second; current frame rate unavailable")
                fpsBadgeHasReading = true
            case (nil, nil):
                fpsBadgeHasReading = false
            }
        }
        fpsBadge.isHidden = !fpsBadgeIsEnabled || !fpsBadgeHasReading
        needsLayout = true
    }

    func hideFPSBadge() {
        fpsBadgeHasReading = false
        fpsBadge.isHidden = true
        needsLayout = true
    }

    private static func usableFramesPerSecond(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func formatFPS(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private func layoutFPSBadge() {
        guard !fpsBadge.isHidden else { return }
        let horizontalPadding: CGFloat = 8
        let verticalPadding: CGFloat = 4
        let fittingSize = fpsBadge.intrinsicContentSize
        let size = NSSize(
            width: ceil(fittingSize.width + horizontalPadding * 2),
            height: ceil(fittingSize.height + verticalPadding * 2)
        )
        let margin: CGFloat = 12
        fpsBadge.frame = NSRect(
            x: max(4, bounds.maxX - size.width - margin),
            y: max(4, bounds.maxY - size.height - margin),
            width: min(size.width, max(0, bounds.width - 8)),
            height: min(size.height, max(0, bounds.height - 8))
        )
    }

    private func configureQuickControls() {
        configureQuickControlButton(
            nextClipButton,
            symbolName: "forward.end.fill",
            accessibilityLabel: "Next Clip",
            action: #selector(advanceClip)
        )
        configureQuickControlButton(
            temporaryStateButton,
            symbolName: "clock.arrow.circlepath",
            accessibilityLabel: "Temporary State",
            action: #selector(showTemporaryStateMenu)
        )
        quickControls.orientation = .vertical
        quickControls.alignment = .centerX
        quickControls.spacing = 6
        quickControls.translatesAutoresizingMaskIntoConstraints = true
        quickControls.setViews([nextClipButton, temporaryStateButton], in: .leading)
        quickControls.setAccessibilityElement(true)
        quickControls.setAccessibilityRole(.group)
        quickControls.setAccessibilityLabel("Pet quick controls")
        addSubview(quickControls)
    }

    private func configureDialogueBubble() {
        dialogueBubble.wantsLayer = true
        dialogueBubble.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.88).cgColor
        dialogueBubble.layer?.cornerCurve = .continuous
        dialogueBubble.layer?.cornerRadius = 10
        dialogueBubble.isHidden = true
        dialogueBubble.setAccessibilityElement(true)
        dialogueBubble.setAccessibilityRole(.staticText)
        dialogueBubble.setAccessibilityLabel("Statelet message")

        dialogueLabel.alignment = .center
        dialogueLabel.font = .systemFont(ofSize: 13, weight: .medium)
        dialogueLabel.textColor = .labelColor
        dialogueLabel.maximumNumberOfLines = 4
        dialogueLabel.lineBreakMode = .byWordWrapping
        dialogueLabel.translatesAutoresizingMaskIntoConstraints = true
        dialogueBubble.addSubview(dialogueLabel)
        addSubview(dialogueBubble)
    }

    private func configureQuickControlButton(
        _ button: NSButton,
        symbolName: String,
        accessibilityLabel: String,
        action: Selector
    ) {
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.controlSize = .regular
        button.showsBorderOnlyWhileMouseInside = false
        button.contentTintColor = .labelColor
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 40).isActive = true
        button.heightAnchor.constraint(equalToConstant: 40).isActive = true
        button.setAccessibilityLabel(accessibilityLabel)
    }

    private func layoutQuickControls() {
        let size = quickControls.fittingSize
        let margin: CGFloat = 6
        var origin = NSPoint(
            x: max(margin, bounds.maxX - size.width - margin),
            y: max(margin, bounds.midY - size.height / 2)
        )
        origin.y = min(origin.y, max(margin, bounds.maxY - size.height - margin))

        if !stateBadge.isHidden {
            let proposedFrame = NSRect(origin: origin, size: size)
            if proposedFrame.intersects(stateBadge.frame.insetBy(dx: -4, dy: -4)) {
                origin.x = max(margin, stateBadge.frame.minX - size.width - 6)
            }
        }
        quickControls.frame = NSRect(origin: origin, size: size)
    }

    private func layoutDialogueBubble() {
        guard !dialogueBubble.isHidden else { return }
        let margin: CGFloat = 12
        let horizontalPadding: CGFloat = 12
        let verticalPadding: CGFloat = 8
        let overlayGap: CGFloat = 8
        let availableMaxX = quickControls.isHidden
            ? bounds.maxX - margin
            : quickControls.frame.minX - overlayGap
        let availableWidth = max(0, availableMaxX - margin)
        let bubbleWidth = min(320, availableWidth)
        guard bubbleWidth > horizontalPadding * 2 else {
            dialogueBubble.frame = .zero
            return
        }

        dialogueLabel.preferredMaxLayoutWidth = bubbleWidth - horizontalPadding * 2
        let fittingSize = dialogueLabel.fittingSize
        let bubbleHeight = min(
            bounds.height - margin * 2,
            ceil(fittingSize.height + verticalPadding * 2)
        )
        let x = margin + max(0, (availableWidth - bubbleWidth) / 2)
        let occupiedFrames = [stateBadge, fpsBadge, quickControls]
            .filter { !$0.isHidden && !$0.frame.isEmpty }
            .map(\.frame)
        let candidateYPositions = ([margin] + occupiedFrames.map { $0.maxY + overlayGap })
            .sorted()
        let resolvedFrame = candidateYPositions.lazy
            .map { y in
                NSRect(x: x, y: y, width: bubbleWidth, height: max(0, bubbleHeight))
            }
            .first { candidate in
                candidate.maxY <= bounds.maxY - margin
                    && occupiedFrames.allSatisfy { occupied in
                        !candidate.intersects(occupied.insetBy(dx: -overlayGap, dy: -overlayGap))
                    }
            }
        dialogueBubble.frame = resolvedFrame ?? .zero
        dialogueLabel.frame = dialogueBubble.bounds.insetBy(
            dx: horizontalPadding,
            dy: verticalPadding
        )
    }

    func applyAppearance(_ configuration: PetAppearanceConfiguration) {
        appearanceConfiguration = configuration
        let workspace = NSWorkspace.shared
        let reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        let increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        let shortestSide = max(0, min(bounds.width, bounds.height))
        let radius = min(CGFloat(configuration.cornerRadius), shortestSide / 2)

        layer?.cornerCurve = .continuous
        layer?.cornerRadius = radius
        layer?.masksToBounds = radius > 0
        if configuration.backgroundEnabled {
            let opacity = reduceTransparency
                ? max(configuration.backgroundOpacity, 0.72)
                : configuration.backgroundOpacity
            layer?.backgroundColor = NSColor.codexPet(
                hex: configuration.backgroundColor,
                opacity: opacity
            ).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
        if configuration.borderEnabled {
            let opacity = increaseContrast
                ? max(configuration.borderOpacity, 0.85)
                : configuration.borderOpacity
            layer?.borderColor = NSColor.codexPet(
                hex: configuration.borderColor,
                opacity: opacity
            ).cgColor
            let width = increaseContrast ? max(configuration.borderWidth, 2) : configuration.borderWidth
            layer?.borderWidth = CGFloat(width)
        } else {
            layer?.borderColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
        }
        applyFPSBadgeAppearance(
            configuration: configuration,
            reduceTransparency: reduceTransparency
        )
        stateBadge.isHidden = !configuration.showStateLabel
        refreshStateBadge(
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast
        )
        needsLayout = true
    }

    func updateStateBadge(state: PetState, publisherStatus: PublisherBadgeVisualStatus) {
        requestedState = state
        publisherBadgeStatus = publisherStatus
        let workspace = NSWorkspace.shared
        refreshStateBadge(
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast
        )
        refreshAccessibility()
        needsLayout = true
    }

    private func refreshStateBadge(
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) {
        let title = manualPreviewState.map {
            "\(liveState.rawValue.capitalized) → \($0.rawValue.capitalized)"
        }
        stateBadge.update(
            state: requestedState,
            publisherStatus: publisherBadgeStatus,
            size: appearanceConfiguration.stateLabelSize,
            reduceTransparency: reduceTransparency,
            increaseContrast: increaseContrast,
            customColor: appearanceConfiguration.stateLabelColor.map { NSColor.codexPet(hex: $0) },
            stateTitle: title
        )
    }

    private func layoutStateBadge() {
        guard !stateBadge.isHidden else { return }
        let size = stateBadge.intrinsicContentSize
        let margin: CGFloat = 12
        let x: CGFloat
        let y: CGFloat
        switch appearanceConfiguration.stateLabelPosition {
        case .topLeft:
            x = margin
            y = bounds.height - size.height - margin
        case .topRight:
            x = bounds.width - size.width - margin
            y = fpsBadge.isHidden
                ? bounds.height - size.height - margin
                : fpsBadge.frame.minY - size.height - 6
        case .bottomLeft:
            x = margin
            y = margin
        case .bottomRight:
            x = bounds.width - size.width - margin
            y = margin
        }
        stateBadge.frame = NSRect(
            x: max(4, x),
            y: max(4, y),
            width: min(size.width, max(0, bounds.width - 8)),
            height: min(size.height, max(0, bounds.height - 8))
        )
    }

    func showPlaceholder(_ message: String?) {
        placeholderLabel.stringValue = message ?? ""
        placeholderLabel.isHidden = message == nil
    }

    /// Shows the current lifecycle-state message without coupling the view to
    /// dialogue storage or voice playback. Nil and whitespace-only text hide it.
    func showDialogueMessage(_ message: String?) {
        let normalized = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        dialogueLabel.stringValue = normalized
        dialogueBubble.isHidden = normalized.isEmpty
        dialogueBubble.setAccessibilityValue(normalized.isEmpty ? nil : normalized)
        needsLayout = true
    }

    func showPoster(_ image: NSImage?) {
        posterView.image = image
        posterView.isHidden = image == nil
        playerLayer.isHidden = image != nil
    }

    func prepareLifecycleHandoff(
        destinationPlayer: AVPlayer,
        transitionPlayer: AVPlayer
    ) -> (destinationReset: Bool, transitionReset: Bool) {
        destinationPlayerLayer.player = nil
        lifecycleTransitionPlayerLayer.player = nil
        let destinationReset = !destinationPlayerLayer.isReadyForDisplay
        let transitionReset = !lifecycleTransitionPlayerLayer.isReadyForDisplay
        destinationPlayerLayer.player = destinationPlayer
        destinationPlayerLayer.isHidden = true
        lifecycleTransitionPlayerLayer.player = transitionPlayer
        lifecycleTransitionPlayerLayer.isHidden = true
        playerLayer.isHidden = false
        posterView.isHidden = true
        return (destinationReset, transitionReset)
    }

    func prepareDirectReplacement(_ player: AVPlayer) -> Bool {
        destinationPlayerLayer.player = nil
        let reset = !destinationPlayerLayer.isReadyForDisplay
        destinationPlayerLayer.player = player
        destinationPlayerLayer.isHidden = true
        return reset
    }

    func revealLifecycleTransition() {
        lifecycleTransitionPlayerLayer.isHidden = false
    }

    func revealLifecycleDestination() {
        destinationPlayerLayer.isHidden = false
    }

    /// Promotes the already-visible destination layer without removing it from
    /// the hierarchy. The old base becomes the hidden standby for the next
    /// handoff; z-order changes are committed without implicit animations.
    func promoteLifecycleDestination() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let outgoingLayer = playerLayer
        let promotedLayer = destinationPlayerLayer
        outgoingLayer.player = nil
        outgoingLayer.isHidden = true
        lifecycleTransitionPlayerLayer.isHidden = true
        lifecycleTransitionPlayerLayer.player = nil
        promotedLayer.isHidden = false

        playerLayer = promotedLayer
        destinationPlayerLayer = outgoingLayer
        playerLayer.zPosition = 0
        destinationPlayerLayer.zPosition = 1
        lifecycleTransitionPlayerLayer.zPosition = 2
    }

    func cancelLifecycleHandoffLayers() {
        destinationPlayerLayer.isHidden = true
        destinationPlayerLayer.player = nil
        lifecycleTransitionPlayerLayer.isHidden = true
        lifecycleTransitionPlayerLayer.player = nil
    }

    func updateAccessibility(
        state: PetState,
        reducedMotion: Bool,
        presentationSummary: String? = nil
    ) {
        presentedState = state
        accessibleReducedMotion = reducedMotion
        accessiblePresentationSummary = presentationSummary
        refreshAccessibility()
    }

    func updatePublisherHealth(_ summary: String) {
        accessiblePublisherHealth = summary
        refreshAccessibility()
    }

    /// Keeps quick-control state derived from the app delegate's authoritative
    /// lifecycle and playback model. A temporary selection is intentionally
    /// session-only; the view never persists it.
    func updateQuickControls(
        canAdvanceClip: Bool,
        liveState: PetState,
        displayedState: PetState,
        manualPreview: PetState?
    ) {
        self.liveState = liveState
        self.displayedState = displayedState
        manualPreviewState = manualPreview
        let workspace = NSWorkspace.shared
        refreshStateBadge(
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast
        )

        let requested = manualPreview ?? liveState
        nextClipButton.isEnabled = canAdvanceClip
        let nextSummary = "Next clip for \(requested.rawValue)"
        let displayedSummary = requested == displayedState
            ? ""
            : "; currently displaying \(displayedState.rawValue)"
        nextClipButton.toolTip = (canAdvanceClip
            ? nextSummary
            : "No other playable \(requested.rawValue) clip is available") + displayedSummary
        nextClipButton.setAccessibilityLabel(nextSummary)
        nextClipButton.setAccessibilityHelp(nextClipButton.toolTip)

        let stateSummary: String
        if let manualPreview {
            stateSummary = "temporary state request is \(manualPreview.rawValue); live state is \(liveState.rawValue); displayed media is \(displayedState.rawValue)"
        } else if liveState == displayedState {
            stateSummary = "live state is \(liveState.rawValue)"
        } else {
            stateSummary = "live state is \(liveState.rawValue); displayed media is \(displayedState.rawValue)"
        }
        temporaryStateButton.toolTip = "Temporary State — \(stateSummary)"
        temporaryStateButton.setAccessibilityLabel("Temporary State, \(stateSummary)")
        temporaryStateButton.setAccessibilityHelp("Choose a temporary pet state. \(stateSummary).")
        refreshAccessibility()
    }

    @objc private func advanceClip() {
        onAdvanceClip?()
    }

    @objc private func showTemporaryStateMenu() {
        let menu = makeTemporaryStateMenu()
        menu.popUp(
            positioning: menu.items.first(where: { $0.state == .on }),
            at: NSPoint(x: temporaryStateButton.bounds.minX, y: temporaryStateButton.bounds.maxY + 2),
            in: temporaryStateButton
        )
    }

    func makeTemporaryStateMenu() -> NSMenu {
        let menu = NSMenu(title: "Temporary State")
        for (index, state) in PetState.allCases.enumerated() {
            let item = NSMenuItem(
                title: state.rawValue.capitalized,
                action: #selector(selectTemporaryState(_:)),
                keyEquivalent: String(index + 1)
            )
            item.target = self
            item.representedObject = state.rawValue
            item.keyEquivalentModifierMask = []
            item.state = manualPreviewState == state ? .on : .off
            item.setAccessibilityLabel("Temporarily show \(state.rawValue) state")
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let returnItem = NSMenuItem(
            title: "Return to Live State",
            action: #selector(returnToLiveState),
            keyEquivalent: "0"
        )
        returnItem.target = self
        returnItem.keyEquivalentModifierMask = []
        returnItem.state = manualPreviewState == nil ? .on : .off
        returnItem.isEnabled = manualPreviewState != nil
        returnItem.setAccessibilityLabel("Return to live \(liveState.rawValue) state")
        menu.addItem(returnItem)
        return menu
    }

    @objc func selectTemporaryState(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let state = PetState(rawValue: rawValue) else { return }
        onTemporaryStateSelection?(state)
    }

    @objc private func returnToLiveState() {
        onTemporaryStateSelection?(nil)
    }

    private func refreshAccessibility() {
        let reducedMotion = accessibleReducedMotion
        let mode = reducedMotion ? "static" : "animated"
        let requested = manualPreviewState ?? liveState
        setAccessibilityLabel("Statelet: \(liveState.rawValue)")
        let preview = manualPreviewState.map {
            ", manually previewing \($0.rawValue)"
        } ?? ""
        let display = requested == displayedState
            ? ""
            : ", showing \(displayedState.rawValue) animation"
        let presentation = accessiblePresentationSummary.map { ", \($0)" } ?? ""
        setAccessibilityValue("\(liveState.rawValue) Codex state\(preview), \(mode), \(accessiblePublisherHealth)\(display)\(presentation)")
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(point) else { return nil }
        // NSStackView's fitting frame can be narrower than an arranged
        // button's visible 40-point bezel. Test the button bounds first so the
        // entire physical target remains clickable at every edge.
        for button in [nextClipButton, temporaryStateButton] where !button.isHidden {
            let target = button.convert(button.bounds, to: self)
            if target.contains(point) { return button }
        }
        if quickControls.frame.contains(point) {
            return self
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0,
              !event.modifierFlags.contains(.control),
              let window else { return }
        pointerInteraction = PointerInteraction(
            mouse: NSEvent.mouseLocation,
            windowFrame: window.frame,
            resizeEdges: resizeEdges(at: convert(event.locationInWindow, from: nil))
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, var interaction = pointerInteraction else { return }
        let mouse = NSEvent.mouseLocation
        let delta = NSPoint(x: mouse.x - interaction.mouse.x, y: mouse.y - interaction.mouse.y)
        if !interaction.didDrag,
           hypot(delta.x, delta.y) < Self.dragThreshold {
            return
        }
        interaction.didDrag = true
        pointerInteraction = interaction
        if interaction.resizeEdges.isEmpty {
            window.setFrameOrigin(NSPoint(
                x: interaction.windowFrame.origin.x + delta.x,
                y: interaction.windowFrame.origin.y + delta.y
            ))
        } else {
            window.setFrame(
                resizedFrame(from: interaction.windowFrame, delta: delta, edges: interaction.resizeEdges),
                display: true
            )
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let interaction = pointerInteraction else { return }
        pointerInteraction = nil
        if interaction.didDrag, !interaction.resizeEdges.isEmpty {
            if let size = window?.frame.size {
                onResizeEnded?(size)
            }
        } else if !interaction.didDrag, interaction.resizeEdges.isEmpty {
            onPetClick?()
        }
    }

    private func resizeEdges(at point: NSPoint) -> ResizeEdges {
        let width = Self.resizeHandleWidth
        let corner = width * 2
        var edges: ResizeEdges = []
        if point.x <= corner, point.y <= corner { return [.left, .bottom] }
        if point.x >= bounds.maxX - corner, point.y <= corner { return [.right, .bottom] }
        if point.x <= corner, point.y >= bounds.maxY - corner { return [.left, .top] }
        if point.x >= bounds.maxX - corner, point.y >= bounds.maxY - corner { return [.right, .top] }
        if point.x <= width { edges.insert(.left) }
        if point.x >= bounds.maxX - width { edges.insert(.right) }
        if point.y <= width { edges.insert(.bottom) }
        if point.y >= bounds.maxY - width { edges.insert(.top) }
        return edges
    }

    private func resizedFrame(from frame: NSRect, delta: NSPoint, edges: ResizeEdges) -> NSRect {
        guard frame.width > 0, frame.height > 0 else { return frame }
        let aspectRatio = frame.height / frame.width
        let horizontalWidth: CGFloat? = if edges.contains(.left) {
            frame.width - delta.x
        } else if edges.contains(.right) {
            frame.width + delta.x
        } else {
            nil
        }
        let verticalWidth: CGFloat? = if edges.contains(.bottom) {
            (frame.height - delta.y) / aspectRatio
        } else if edges.contains(.top) {
            (frame.height + delta.y) / aspectRatio
        } else {
            nil
        }
        let proposedWidth: CGFloat
        switch (horizontalWidth, verticalWidth) {
        case let (.some(horizontal), .some(vertical)):
            proposedWidth = abs(horizontal - frame.width) >= abs(vertical - frame.width)
                ? horizontal
                : vertical
        case let (.some(horizontal), nil):
            proposedWidth = horizontal
        case let (nil, .some(vertical)):
            proposedWidth = vertical
        case (nil, nil):
            return frame
        }

        let maximumWidth = min(4096, 4096 / aspectRatio)
        let width = min(max(Self.minimumWindowWidth, proposedWidth), maximumWidth)
        let height = width * aspectRatio
        let x: CGFloat
        if edges.contains(.left) {
            x = frame.maxX - width
        } else if edges.contains(.right) {
            x = frame.minX
        } else {
            x = frame.midX - width / 2
        }
        let y: CGFloat
        if edges.contains(.bottom) {
            y = frame.maxY - height
        } else if edges.contains(.top) {
            y = frame.minY
        } else {
            y = frame.midY - height / 2
        }
        return NSRect(x: x, y: y, width: width, height: height)
    }

}

final class PetPlayerController {
    private static let readinessTimeout: DispatchTimeInterval = .seconds(8)
    private static let maximumCachedFrameRates = 32

    private struct ActiveTransition {
        let id: UInt64
        let state: PetState
        let url: URL
        let startedAt: UInt64
        let previewName: String?
        var readiness = PresentationReadinessTracker()
    }

    private struct ActiveLifecycleHandoff {
        let id: UInt64
        let source: PetState
        let destination: PetState
        let destinationURL: URL
        let destinationEntry: MediaEntry
        let destinationPlayer: AVQueuePlayer
        var destinationLooper: AVPlayerLooper?
        let transitionPlayer: AVPlayer
        let transitionItem: AVPlayerItem
        let transitionPlaybackRate: Double
        let startedAt: UInt64
        let advancePlaylistWhenEnded: Bool
        var destinationItemReady = false
        var destinationDisplayReady = false
        var destinationDisplayReset = false
        var destinationStarted = false
        var destinationVisible = false
        var destinationRetryCount = 0
        var transitionItemReady = false
        var transitionDisplayReady = false
        var transitionDisplayReset = false
        var transitionVisible = false
        var transitionEnded = false
    }

    private struct ActiveDirectReplacement {
        let id: UInt64
        let state: PetState
        let url: URL
        let entry: MediaEntry
        let player: AVQueuePlayer
        var looper: AVPlayerLooper?
        let startedAt: UInt64
        let previewName: String?
        let notifyWhenEnded: Bool
        let advancePlaylistWhenEnded: Bool
        var itemReady = false
        var displayReady = false
        var displayReset = false
    }

    private let logger = Logger(subsystem: StateletIdentity.bundleIdentifier, category: "player")
    let view: PetPlayerView
    private var queuePlayer = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var currentItemObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var displayReadyObservation: NSKeyValueObservation?
    private var failedToEndObserver: NSObjectProtocol?
    private var didPlayToEndObserver: NSObjectProtocol?
    private var readinessTimeoutWorkItem: DispatchWorkItem?
    private var lifecycleTransitionTimeoutWorkItem: DispatchWorkItem?
    private var lifecycleCueTimeObserver: Any?
    private var lifecycleDestinationCurrentItemObservation: NSKeyValueObservation?
    private var lifecycleDestinationItemObservation: NSKeyValueObservation?
    private var lifecycleDestinationDisplayObservation: NSKeyValueObservation?
    private var lifecycleTransitionItemObservation: NSKeyValueObservation?
    private var lifecycleTransitionDisplayObservation: NSKeyValueObservation?
    private var lifecycleDidEndObserver: NSObjectProtocol?
    private var lifecycleFailedObserver: NSObjectProtocol?
    private var directCurrentItemObservation: NSKeyValueObservation?
    private var directItemObservation: NSKeyValueObservation?
    private var directDisplayObservation: NSKeyValueObservation?
    private var directTimeoutWorkItem: DispatchWorkItem?
    private var fpsLoadingTask: Task<Void, Never>?
    private var fpsCache = BoundedLRUCache<LocalFileRevision, Double>(
        capacity: maximumCachedFrameRates
    )
    private var activeTransition: ActiveTransition?
    private var itemReadyLoggedTransitionID: UInt64?
    private var displayResetTransitionID: UInt64?
    private var observedCurrentItemIdentifier: ObjectIdentifier?
    private var readyItemIdentifier: ObjectIdentifier?
    private var activeItemIdentifiers: Set<ObjectIdentifier> = []
    private var oneShotEndTransitionID: UInt64?
    private var playlistEndTransitionID: UInt64?
    private var lifecycleTransitionEndID: UInt64?
    private var activeLifecycleHandoff: ActiveLifecycleHandoff?
    private var activeDirectReplacement: ActiveDirectReplacement?
    private(set) var currentState: PetState = .idle
    private(set) var currentURL: URL?
    private var currentPresentationIsOneShot = false
    private(set) var presentationStatus: PlaybackPresentationStatus = .awaiting
    private var reduceMotion = false
    private var suspensionPolicy = PlaybackSuspensionPolicy()
    private var deferredPlaybackResume = DeferredPlaybackResume()

    var onPresentationEvent: ((UInt64, PetState, PlaybackPresentationEvent) -> Void)?
    var onOneShotEnded: ((UInt64) -> Void)?
    var onPlaylistClipEnded: ((UInt64, PetState) -> Void)?
    var onLifecycleTransitionEnded: ((UInt64) -> Void)?
    var onLifecycleTransitionFailed: ((UInt64) -> Void)?

    init(view: PetPlayerView) {
        self.view = view
        view.playerLayer.player = queuePlayer
        queuePlayer.actionAtItemEnd = .none
        bindBasePlayerObservers()
        failedToEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let failedItem = notification.object as? AVPlayerItem,
                  self.activeItemIdentifiers.contains(ObjectIdentifier(failedItem)) else { return }
            self.failActiveTransition(reason: .playbackFailed)
        }
        didPlayToEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let endedItem = notification.object as? AVPlayerItem,
                  self.activeItemIdentifiers.contains(ObjectIdentifier(endedItem)),
                  let transition = self.activeTransition else { return }
            if self.oneShotEndTransitionID == transition.id {
                self.oneShotEndTransitionID = nil
                self.logger.info("event=one_shot_ended transition_id=\(transition.id, privacy: .public)")
                self.onOneShotEnded?(transition.id)
            } else if self.playlistEndTransitionID == transition.id {
                self.playlistEndTransitionID = nil
                // The completed item is no longer a viable fallback. The app
                // delegate will immediately hard-cut to the next eligible
                // playlist entry or present an honest placeholder.
                self.currentURL = nil
                self.logger.info("event=playlist_clip_ended transition_id=\(transition.id, privacy: .public) state=\(transition.state.rawValue, privacy: .public)")
                self.onPlaylistClipEnded?(transition.id, transition.state)
            } else if self.lifecycleTransitionEndID == transition.id {
                self.lifecycleTransitionTimeoutWorkItem?.cancel()
                self.lifecycleTransitionTimeoutWorkItem = nil
                self.lifecycleTransitionEndID = nil
                self.logger.info("event=lifecycle_transition_ended transition_id=\(transition.id, privacy: .public)")
                self.onLifecycleTransitionEnded?(transition.id)
            }
        }
    }

    deinit {
        readinessTimeoutWorkItem?.cancel()
        lifecycleTransitionTimeoutWorkItem?.cancel()
        fpsLoadingTask?.cancel()
        if let failedToEndObserver {
            NotificationCenter.default.removeObserver(failedToEndObserver)
        }
        if let didPlayToEndObserver {
            NotificationCenter.default.removeObserver(didPlayToEndObserver)
        }
        removeLifecycleNotificationObservers()
    }

    /// Hard-cuts to a new asset. Video is only committed as presented after
    /// both the actual queued item and the AVPlayerLayer pass their readiness
    /// gates. Reduce Motion remains an immediate static presentation.
    @discardableResult
    func show(
        state: PetState,
        entry: MediaEntry?,
        url: URL?,
        posterURL: URL?,
        transitionID: UInt64,
        startedAt: UInt64,
        previewName: String? = nil,
        notifyWhenEnded: Bool = false,
        advancePlaylistWhenEnded: Bool = false
    ) -> PlaybackStartDisposition {
        cancelLifecycleHandoff(notifyFailure: false)
        if reduceMotion {
            return showReducedMotion(state: state, posterURL: posterURL)
        }
        guard let entry, let url else {
            return softFailure(state: state, reason: .unmapped)
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return softFailure(state: state, reason: .unreadable)
        }

        cancelDirectReplacement()
        view.hideFPSBadge()
        let replacementPlayer = AVQueuePlayer()
        replacementPlayer.actionAtItemEnd = .none
        let item = AVPlayerItem(url: url)
        let replacementLooper: AVPlayerLooper?
        if entry.loop && !advancePlaylistWhenEnded {
            replacementLooper = AVPlayerLooper(player: replacementPlayer, templateItem: item)
        } else {
            replacementLooper = nil
            replacementPlayer.insert(item, after: nil)
        }
        let playbackRate = entry.playbackRate.value
        activeDirectReplacement = ActiveDirectReplacement(
            id: transitionID,
            state: state,
            url: url,
            entry: entry,
            player: replacementPlayer,
            looper: replacementLooper,
            startedAt: startedAt,
            previewName: previewName,
            notifyWhenEnded: notifyWhenEnded,
            advancePlaylistWhenEnded: advancePlaylistWhenEnded
        )
        let displayReset = view.prepareDirectReplacement(replacementPlayer)
        if var replacement = activeDirectReplacement {
            replacement.displayReset = displayReset
            activeDirectReplacement = replacement
        }
        observeDirectCurrentItem(replacementPlayer.currentItem, transitionID: transitionID)
        directCurrentItemObservation = replacementPlayer.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            let currentItem = player.currentItem
            DispatchQueue.main.async {
                self?.observeDirectCurrentItem(currentItem, transitionID: transitionID)
            }
        }
        directDisplayObservation = view.destinationPlayerLayer.observe(
            \.isReadyForDisplay,
            options: [.initial, .new]
        ) { [weak self] layer, _ in
            let ready = layer.isReadyForDisplay
            DispatchQueue.main.async {
                self?.handleDirectDisplayReady(ready, transitionID: transitionID)
            }
        }
        presentationStatus = .preparing(state)
        view.showPlaceholder(nil)
        view.updateAccessibility(
            state: state,
            reducedMotion: reduceMotion,
            presentationSummary: previewName.map { "preparing one-time preview of \($0)" }
                ?? "preparing media"
        )
        scheduleDirectReadinessTimeout(transitionID: transitionID)
        replacementPlayer.preroll(atRate: Float(playbackRate)) { [weak self] ready in
            guard ready else { return }
            DispatchQueue.main.async { self?.tryPromoteDirectReplacement(transitionID: transitionID) }
        }
        if suspensionPolicy.reasons.isEmpty {
            replacementPlayer.playImmediately(atRate: Float(playbackRate))
        }
        return .preparing
    }

    /// Prepares the destination below a one-shot transition while retaining the
    /// current base layer. Neither overlay is revealed until its decoded first
    /// frame is display-ready.
    @discardableResult
    func showLifecycleTransition(
        sourceState: PetState,
        destinationState: PetState,
        transitionEntry: MediaEntry,
        transitionURL: URL,
        destinationEntry: MediaEntry,
        destinationURL: URL,
        transitionID: UInt64,
        startedAt: UInt64,
        advancePlaylistWhenEnded: Bool = false
    ) -> PlaybackStartDisposition {
        guard !reduceMotion,
              FileManager.default.isReadableFile(atPath: transitionURL.path),
              FileManager.default.isReadableFile(atPath: destinationURL.path) else {
            return .failed
        }
        cancelLifecycleHandoff(notifyFailure: false)

        let destinationPlayer = AVQueuePlayer()
        destinationPlayer.actionAtItemEnd = .none
        let destinationItem = AVPlayerItem(url: destinationURL)
        let destinationLooper: AVPlayerLooper?
        if destinationEntry.loop && !advancePlaylistWhenEnded {
            destinationLooper = AVPlayerLooper(player: destinationPlayer, templateItem: destinationItem)
        } else {
            destinationLooper = nil
            destinationPlayer.insert(destinationItem, after: nil)
        }
        let transitionItem = AVPlayerItem(url: transitionURL)
        let transitionPlayer = AVPlayer(playerItem: transitionItem)
        transitionPlayer.actionAtItemEnd = .pause
        activeLifecycleHandoff = ActiveLifecycleHandoff(
            id: transitionID,
            source: sourceState,
            destination: destinationState,
            destinationURL: destinationURL,
            destinationEntry: destinationEntry,
            destinationPlayer: destinationPlayer,
            destinationLooper: destinationLooper,
            transitionPlayer: transitionPlayer,
            transitionItem: transitionItem,
            transitionPlaybackRate: transitionEntry.playbackRate.value,
            startedAt: startedAt,
            advancePlaylistWhenEnded: advancePlaylistWhenEnded
        )
        lifecycleTransitionEndID = transitionID
        let displayReset = view.prepareLifecycleHandoff(
            destinationPlayer: destinationPlayer,
            transitionPlayer: transitionPlayer
        )
        if var handoff = activeLifecycleHandoff {
            handoff.destinationDisplayReset = displayReset.destinationReset
            handoff.transitionDisplayReset = displayReset.transitionReset
            activeLifecycleHandoff = handoff
        }
        observeLifecycleDestinationCurrentItem(destinationPlayer.currentItem, transitionID: transitionID)
        lifecycleDestinationCurrentItemObservation = destinationPlayer.observe(
            \.currentItem,
            options: [.new]
        ) { [weak self] player, _ in
            let item = player.currentItem
            DispatchQueue.main.async {
                self?.observeLifecycleDestinationCurrentItem(item, transitionID: transitionID)
            }
        }
        lifecycleDestinationDisplayObservation = view.destinationPlayerLayer.observe(
            \.isReadyForDisplay,
            options: [.initial, .new]
        ) { [weak self] layer, _ in
            let ready = layer.isReadyForDisplay
            DispatchQueue.main.async {
                self?.handleLifecycleDestinationDisplayReady(ready, transitionID: transitionID)
            }
        }
        lifecycleTransitionItemObservation = transitionItem.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self] item, _ in
            DispatchQueue.main.async {
                self?.handleLifecycleTransitionItemStatus(item, transitionID: transitionID)
            }
        }
        lifecycleTransitionDisplayObservation = view.lifecycleTransitionPlayerLayer.observe(
            \.isReadyForDisplay,
            options: [.initial, .new]
        ) { [weak self] layer, _ in
            let ready = layer.isReadyForDisplay
            DispatchQueue.main.async {
                self?.handleLifecycleTransitionDisplayReady(ready, transitionID: transitionID)
            }
        }
        lifecycleDidEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: transitionItem,
            queue: .main
        ) { [weak self] _ in
            self?.handleLifecycleTransitionEnded(transitionID: transitionID)
        }
        lifecycleFailedObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: transitionItem,
            queue: .main
        ) { [weak self] _ in
            self?.failLifecycleHandoff(transitionID: transitionID, reason: "transition_playback_failed")
        }
        transitionPlayer.preroll(atRate: Float(transitionEntry.playbackRate.value)) { [weak self] ready in
            DispatchQueue.main.async {
                guard let self, self.activeLifecycleHandoff?.id == transitionID else { return }
                if ready {
                    self.tryRevealLifecycleTransition(transitionID: transitionID)
                }
            }
        }
        destinationPlayer.preroll(atRate: Float(destinationEntry.playbackRate.value)) { [weak self] ready in
            DispatchQueue.main.async {
                guard let self, self.activeLifecycleHandoff?.id == transitionID else { return }
                if ready {
                    self.tryRevealLifecycleDestination(transitionID: transitionID)
                }
            }
        }
        scheduleLifecycleTransitionTimeout(transitionID: transitionID, startedAt: startedAt)
        presentationStatus = .preparing(destinationState)
        return .preparing
    }

    /// Cancels only handoff overlays, leaving the last committed base visible.
    func cancelLifecycleTransition() {
        cancelLifecycleHandoff(notifyFailure: false)
    }

    func setReduceMotion(_ enabled: Bool) {
        if enabled {
            cancelLifecycleHandoff(notifyFailure: false)
        }
        reduceMotion = enabled
    }

    func applyAppearance(_ configuration: PetAppearanceConfiguration) {
        let wasEnabled = view.isFPSBadgeEnabled
        view.applyAppearance(configuration)
        if !view.isFPSBadgeEnabled {
            fpsLoadingTask?.cancel()
            fpsLoadingTask = nil
            view.hideFPSBadge()
        } else if !wasEnabled,
                  let transition = activeTransition,
                  let asset = queuePlayer.currentItem?.asset,
                  let rate = suspensionPolicy.intendedPlaybackRate {
            loadFPSIfNeeded(
                for: transition.url,
                asset: asset,
                playbackRate: rate,
                transitionID: transition.id
            )
        }
    }

    /// Independent reasons compose: playback resumes only after every active
    /// system suspension has cleared. Replacing media while suspended updates
    /// the intended rate without losing the new item or its current time.
    func setSuspended(_ suspended: Bool, for reason: PlaybackSuspensionReason) {
        let directive = suspensionPolicy.setSuspended(suspended, for: reason)
        guard directive != .none else { return }
        applyPlaybackDirective(directive)
        if suspensionPolicy.reasons.isEmpty {
            if let transition = activeTransition,
               transition.readiness.state == .preparing {
                scheduleReadinessTimeout(transitionID: transition.id)
            }
            resumeLifecycleHandoffIfNeeded()
            logger.info("event=playback_resumed cleared_reason=\(reason.rawValue, privacy: .public)")
        } else {
            queuePlayer.pause()
            activeDirectReplacement?.player.pause()
            activeLifecycleHandoff?.transitionPlayer.pause()
            activeLifecycleHandoff?.destinationPlayer.pause()
            lifecycleTransitionTimeoutWorkItem?.cancel()
            lifecycleTransitionTimeoutWorkItem = nil
            readinessTimeoutWorkItem?.cancel()
            readinessTimeoutWorkItem = nil
            directTimeoutWorkItem?.cancel()
            directTimeoutWorkItem = nil
            logger.info("event=playback_suspended reason=\(reason.rawValue, privacy: .public) active_reason_count=\(self.suspensionPolicy.reasons.count, privacy: .public)")
        }
    }

    func updatePublisherHealth(_ summary: String) {
        view.updatePublisherHealth(summary)
    }

    /// Removes a one-shot item before the lifecycle presentation is restored.
    /// This prevents the normal soft-failure retention policy from treating a
    /// preview as the last known-good lifecycle animation.
    func clearOneShotPresentation() {
        clearTransientPresentation()
    }

    /// Removes any temporary presentation before authoritative lifecycle media
    /// is restored, so a manual preview cannot become fallback content.
    func clearTransientPresentation() {
        cancelLifecycleHandoff(notifyFailure: false)
        invalidateActiveTransition()
        stopQueuePlayback()
        currentURL = nil
        currentPresentationIsOneShot = false
        presentationStatus = .awaiting
        view.showPoster(nil)
        view.showPlaceholder(nil)
        view.hideFPSBadge()
    }

    private func bindBasePlayerObservers() {
        currentItemObservation = nil
        displayReadyObservation = nil
        currentItemObservation = queuePlayer.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            let item = player.currentItem
            DispatchQueue.main.async { self?.observeCurrentItem(item) }
        }
        displayReadyObservation = view.playerLayer.observe(
            \.isReadyForDisplay,
            options: [.initial, .new]
        ) { [weak self] layer, _ in
            let isReady = layer.isReadyForDisplay
            DispatchQueue.main.async { self?.handleDisplayReadiness(isReady) }
        }
    }

    private func observeDirectCurrentItem(_ item: AVPlayerItem?, transitionID: UInt64) {
        guard let item,
              activeDirectReplacement?.id == transitionID,
              activeDirectReplacement?.player.currentItem === item else { return }
        directItemObservation = nil
        directItemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                self?.handleDirectItemStatus(item, transitionID: transitionID)
            }
        }
    }

    private func handleDirectItemStatus(_ item: AVPlayerItem, transitionID: UInt64) {
        guard var replacement = activeDirectReplacement,
              replacement.id == transitionID,
              replacement.player.currentItem === item else { return }
        switch item.status {
        case .readyToPlay:
            replacement.itemReady = true
            activeDirectReplacement = replacement
            tryPromoteDirectReplacement(transitionID: transitionID)
        case .failed:
            failDirectReplacement(transitionID: transitionID)
        case .unknown:
            break
        @unknown default:
            failDirectReplacement(transitionID: transitionID)
        }
    }

    private func handleDirectDisplayReady(_ ready: Bool, transitionID: UInt64) {
        guard var replacement = activeDirectReplacement,
              replacement.id == transitionID else { return }
        if !ready {
            replacement.displayReset = true
            activeDirectReplacement = replacement
            return
        }
        guard replacement.displayReset else { return }
        replacement.displayReady = true
        activeDirectReplacement = replacement
        tryPromoteDirectReplacement(transitionID: transitionID)
    }

    private func tryPromoteDirectReplacement(transitionID: UInt64) {
        guard let replacement = activeDirectReplacement,
              replacement.id == transitionID,
              replacement.itemReady,
              replacement.displayReady else { return }
        directTimeoutWorkItem?.cancel()
        directTimeoutWorkItem = nil
        clearDirectReplacementObservers()
        view.revealLifecycleDestination()
        let outgoingPlayer = queuePlayer
        invalidateActiveTransition()
        queuePlayer = replacement.player
        looper = replacement.looper
        view.promoteLifecycleDestination()
        outgoingPlayer.pause()
        outgoingPlayer.removeAllItems()
        bindBasePlayerObservers()
        applyPlaybackDirective(
            suspensionPolicy.replacePlayback(rate: replacement.entry.playbackRate.value)
        )
        var promoted = ActiveTransition(
            id: replacement.id,
            state: replacement.state,
            url: replacement.url,
            startedAt: replacement.startedAt,
            previewName: replacement.previewName
        )
        _ = promoted.readiness.receive(.itemReady)
        _ = promoted.readiness.receive(.displayReady)
        activeTransition = promoted
        currentState = replacement.state
        currentURL = replacement.url
        currentPresentationIsOneShot = replacement.notifyWhenEnded
        presentationStatus = replacement.previewName.map {
            .previewing(requested: replacement.state, clipName: $0)
        } ?? .presented(replacement.state)
        oneShotEndTransitionID = replacement.notifyWhenEnded ? replacement.id : nil
        playlistEndTransitionID = replacement.advancePlaylistWhenEnded ? replacement.id : nil
        activeItemIdentifiers = Set(queuePlayer.items().map(ObjectIdentifier.init))
        observeCurrentItem(queuePlayer.currentItem)
        activeDirectReplacement = nil
        view.showPoster(nil)
        view.showPlaceholder(nil)
        view.updateAccessibility(state: replacement.state, reducedMotion: false)
        onPresentationEvent?(replacement.id, replacement.state, .ready)
    }

    private func scheduleDirectReadinessTimeout(transitionID: UInt64) {
        guard suspensionPolicy.canStartReadinessDeadline else { return }
        directTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.failDirectReplacement(transitionID: transitionID)
        }
        directTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readinessTimeout, execute: workItem)
    }

    private func failDirectReplacement(transitionID: UInt64) {
        guard let replacement = activeDirectReplacement,
              replacement.id == transitionID else { return }
        cancelDirectReplacement()
        if currentURL == nil, !view.hasVisiblePoster {
            currentState = replacement.state
            presentationStatus = .placeholder(replacement.state)
            view.showPlaceholder("\(replacement.state.rawValue)\nMedia could not be decoded")
        } else {
            presentationStatus = .retained(requested: replacement.state, displayed: currentState)
        }
        onPresentationEvent?(replacement.id, replacement.state, .failed)
    }

    private func cancelDirectReplacement() {
        guard let replacement = activeDirectReplacement else {
            clearDirectReplacementObservers()
            return
        }
        activeDirectReplacement = nil
        directTimeoutWorkItem?.cancel()
        directTimeoutWorkItem = nil
        clearDirectReplacementObservers()
        replacement.player.pause()
        replacement.player.removeAllItems()
        view.cancelLifecycleHandoffLayers()
    }

    private func clearDirectReplacementObservers() {
        directCurrentItemObservation = nil
        directItemObservation = nil
        directDisplayObservation = nil
    }

    private func observeLifecycleDestinationCurrentItem(
        _ item: AVPlayerItem?,
        transitionID: UInt64
    ) {
        guard let item,
              activeLifecycleHandoff?.id == transitionID,
              activeLifecycleHandoff?.destinationPlayer.currentItem === item else { return }
        lifecycleDestinationItemObservation = nil
        lifecycleDestinationItemObservation = item.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self] item, _ in
            DispatchQueue.main.async {
                self?.handleLifecycleDestinationItemStatus(item, transitionID: transitionID)
            }
        }
    }

    private func handleLifecycleDestinationItemStatus(
        _ item: AVPlayerItem,
        transitionID: UInt64
    ) {
        guard var handoff = activeLifecycleHandoff,
              handoff.id == transitionID,
              handoff.destinationPlayer.currentItem === item else { return }
        switch item.status {
        case .readyToPlay:
            handoff.destinationItemReady = true
            activeLifecycleHandoff = handoff
            tryRevealLifecycleDestination(transitionID: transitionID)
        case .failed:
            retryLifecycleDestination(transitionID: transitionID)
        case .unknown:
            break
        @unknown default:
            retryLifecycleDestination(transitionID: transitionID)
        }
    }

    private func handleLifecycleDestinationDisplayReady(
        _ ready: Bool,
        transitionID: UInt64
    ) {
        guard ready,
              var handoff = activeLifecycleHandoff,
              handoff.id == transitionID else {
            if !ready,
               var handoff = activeLifecycleHandoff,
               handoff.id == transitionID {
                handoff.destinationDisplayReset = true
                activeLifecycleHandoff = handoff
            }
            return
        }
        guard handoff.destinationDisplayReset else { return }
        handoff.destinationDisplayReady = true
        activeLifecycleHandoff = handoff
        tryRevealLifecycleDestination(transitionID: transitionID)
    }

    private func handleLifecycleTransitionItemStatus(
        _ item: AVPlayerItem,
        transitionID: UInt64
    ) {
        guard var handoff = activeLifecycleHandoff,
              handoff.id == transitionID,
              handoff.transitionItem === item else { return }
        switch item.status {
        case .readyToPlay:
            handoff.transitionItemReady = true
            activeLifecycleHandoff = handoff
            tryRevealLifecycleTransition(transitionID: transitionID)
        case .failed:
            failLifecycleHandoff(transitionID: transitionID, reason: "transition_item_failed")
        case .unknown:
            break
        @unknown default:
            failLifecycleHandoff(transitionID: transitionID, reason: "transition_item_failed")
        }
    }

    private func handleLifecycleTransitionDisplayReady(
        _ ready: Bool,
        transitionID: UInt64
    ) {
        guard ready,
              var handoff = activeLifecycleHandoff,
              handoff.id == transitionID else {
            if !ready,
               var handoff = activeLifecycleHandoff,
               handoff.id == transitionID {
                handoff.transitionDisplayReset = true
                activeLifecycleHandoff = handoff
            }
            return
        }
        guard handoff.transitionDisplayReset else { return }
        handoff.transitionDisplayReady = true
        activeLifecycleHandoff = handoff
        tryRevealLifecycleTransition(transitionID: transitionID)
    }

    private func tryRevealLifecycleTransition(transitionID: UInt64) {
        guard var handoff = activeLifecycleHandoff,
              handoff.id == transitionID,
              handoff.transitionItemReady,
              handoff.transitionDisplayReady,
              !handoff.transitionVisible else { return }
        handoff.transitionVisible = true
        activeLifecycleHandoff = handoff
        view.revealLifecycleTransition()
        lifecycleTransitionTimeoutWorkItem?.cancel()
        lifecycleTransitionTimeoutWorkItem = nil
        if suspensionPolicy.reasons.isEmpty {
            handoff.transitionPlayer.playImmediately(
                atRate: Float(max(handoff.transitionPlaybackRate, 0.01))
            )
        }
        scheduleLifecycleDestinationCue(transitionID: transitionID)
        logger.info("event=lifecycle_transition_first_frame transition_id=\(transitionID, privacy: .public)")
    }

    private func scheduleLifecycleDestinationCue(transitionID: UInt64) {
        guard let handoff = activeLifecycleHandoff,
              handoff.id == transitionID else { return }
        removeLifecycleCueTimeObserver(from: handoff.transitionPlayer)
        let duration = handoff.transitionItem.duration.seconds
        let transitionRate = max(handoff.transitionPlaybackRate, 0.01)
        let playbackDuration = duration.isFinite && duration > 0
            ? duration / transitionRate
            : LayeredLifecycleHandoffPolicy.maximumOverlap
        let delay = LayeredLifecycleHandoffPolicy.destinationPrerollTime(duration: playbackDuration)
        let cueMediaSeconds = max(0, min(duration, delay * transitionRate))
        lifecycleCueTimeObserver = handoff.transitionPlayer.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: cueMediaSeconds, preferredTimescale: 600))],
            queue: .main
        ) { [weak self] in
            self?.startLifecycleDestination(transitionID: transitionID)
        }
    }

    private func startLifecycleDestination(transitionID: UInt64) {
        guard var handoff = activeLifecycleHandoff,
              handoff.id == transitionID,
              !handoff.destinationStarted else { return }
        handoff.destinationStarted = true
        activeLifecycleHandoff = handoff
        if suspensionPolicy.reasons.isEmpty {
            handoff.destinationPlayer.playImmediately(
                atRate: Float(handoff.destinationEntry.playbackRate.value)
            )
        }
        tryRevealLifecycleDestination(transitionID: transitionID)
        logger.info("event=lifecycle_destination_preroll_started transition_id=\(transitionID, privacy: .public)")
    }

    private func tryRevealLifecycleDestination(transitionID: UInt64) {
        guard var handoff = activeLifecycleHandoff,
              handoff.id == transitionID,
              handoff.destinationStarted,
              handoff.destinationItemReady,
              handoff.destinationDisplayReady,
              !handoff.destinationVisible else { return }
        handoff.destinationVisible = true
        activeLifecycleHandoff = handoff
        view.revealLifecycleDestination()
        logger.info("event=lifecycle_destination_first_frame transition_id=\(transitionID, privacy: .public)")
        if handoff.transitionEnded {
            promoteLifecycleDestination(transitionID: transitionID)
        }
    }

    private func handleLifecycleTransitionEnded(transitionID: UInt64) {
        guard var handoff = activeLifecycleHandoff,
              handoff.id == transitionID else { return }
        handoff.transitionEnded = true
        activeLifecycleHandoff = handoff
        startLifecycleDestination(transitionID: transitionID)
        if activeLifecycleHandoff?.destinationVisible == true {
            promoteLifecycleDestination(transitionID: transitionID)
        }
    }

    private func promoteLifecycleDestination(transitionID: UInt64) {
        guard let handoff = activeLifecycleHandoff,
              handoff.id == transitionID,
              handoff.destinationVisible else { return }
        let outgoingPlayer = queuePlayer
        invalidateActiveTransition()
        clearLifecycleHandoffObservers()
        queuePlayer = handoff.destinationPlayer
        looper = handoff.destinationLooper
        view.promoteLifecycleDestination()
        outgoingPlayer.pause()
        outgoingPlayer.removeAllItems()
        queuePlayer.actionAtItemEnd = .none
        bindBasePlayerObservers()
        applyPlaybackDirective(
            suspensionPolicy.replacePlayback(rate: handoff.destinationEntry.playbackRate.value)
        )

        var promoted = ActiveTransition(
            id: transitionID,
            state: handoff.destination,
            url: handoff.destinationURL,
            startedAt: handoff.startedAt,
            previewName: nil
        )
        _ = promoted.readiness.receive(.itemReady)
        _ = promoted.readiness.receive(.displayReady)
        activeTransition = promoted
        currentState = handoff.destination
        currentURL = handoff.destinationURL
        currentPresentationIsOneShot = false
        presentationStatus = .presented(handoff.destination)
        playlistEndTransitionID = handoff.advancePlaylistWhenEnded ? transitionID : nil
        activeItemIdentifiers = Set(queuePlayer.items().map(ObjectIdentifier.init))
        observeCurrentItem(queuePlayer.currentItem)
        activeLifecycleHandoff = nil
        lifecycleTransitionEndID = nil
        lifecycleTransitionTimeoutWorkItem?.cancel()
        lifecycleTransitionTimeoutWorkItem = nil
        removeLifecycleCueTimeObserver(from: handoff.transitionPlayer)
        view.showPoster(nil)
        view.showPlaceholder(nil)
        view.updateAccessibility(state: handoff.destination, reducedMotion: false)
        logger.info("event=lifecycle_destination_promoted transition_id=\(transitionID, privacy: .public)")
        onLifecycleTransitionEnded?(transitionID)
    }

    private func resumeLifecycleHandoffIfNeeded() {
        if let replacement = activeDirectReplacement {
            replacement.player.playImmediately(atRate: Float(replacement.entry.playbackRate.value))
            scheduleDirectReadinessTimeout(transitionID: replacement.id)
        }
        guard let handoff = activeLifecycleHandoff else { return }
        if !handoff.transitionVisible {
            scheduleLifecycleTransitionTimeout(
                transitionID: handoff.id,
                startedAt: DispatchTime.now().uptimeNanoseconds
            )
        }
        if handoff.transitionVisible, !handoff.transitionEnded {
            handoff.transitionPlayer.playImmediately(
                atRate: Float(max(handoff.transitionPlaybackRate, 0.01))
            )
        }
        if handoff.destinationStarted {
            handoff.destinationPlayer.playImmediately(
                atRate: Float(handoff.destinationEntry.playbackRate.value)
            )
        }
    }

    private func failLifecycleHandoff(transitionID: UInt64, reason: String) {
        guard var handoff = activeLifecycleHandoff,
              handoff.id == transitionID else { return }
        if handoff.destinationVisible {
            handoff.transitionEnded = true
            activeLifecycleHandoff = handoff
            promoteLifecycleDestination(transitionID: transitionID)
            return
        }
        if reason.hasPrefix("transition_") {
            handoff.transitionEnded = true
            activeLifecycleHandoff = handoff
            view.lifecycleTransitionPlayerLayer.isHidden = true
            startLifecycleDestination(transitionID: transitionID)
            return
        }
        logger.error("event=lifecycle_handoff_failed transition_id=\(transitionID, privacy: .public) reason=\(reason, privacy: .public)")
        cancelLifecycleHandoff(notifyFailure: true)
    }

    /// A destination decode failure gets one fresh item attempt on the hidden
    /// lower layer. The committed outgoing layer is never detached during the
    /// retry, and the authoritative four-second deadline still bounds it.
    private func retryLifecycleDestination(transitionID: UInt64) {
        guard var handoff = activeLifecycleHandoff,
              handoff.id == transitionID else { return }
        guard handoff.destinationRetryCount == 0 else {
            failLifecycleHandoff(transitionID: transitionID, reason: "destination_item_failed")
            return
        }
        handoff.destinationRetryCount = 1
        handoff.destinationItemReady = false
        handoff.destinationDisplayReady = false
        handoff.destinationDisplayReset = false
        handoff.destinationStarted = false
        handoff.destinationVisible = false
        handoff.destinationLooper = nil
        activeLifecycleHandoff = handoff
        lifecycleDestinationItemObservation = nil
        lifecycleDestinationCurrentItemObservation = nil
        view.destinationPlayerLayer.player = nil
        handoff.destinationPlayer.pause()
        handoff.destinationPlayer.removeAllItems()
        let item = AVPlayerItem(url: handoff.destinationURL)
        if handoff.destinationEntry.loop && !handoff.advancePlaylistWhenEnded {
            handoff.destinationLooper = AVPlayerLooper(
                player: handoff.destinationPlayer,
                templateItem: item
            )
        } else {
            handoff.destinationPlayer.insert(item, after: nil)
        }
        activeLifecycleHandoff = handoff
        view.destinationPlayerLayer.player = handoff.destinationPlayer
        observeLifecycleDestinationCurrentItem(
            handoff.destinationPlayer.currentItem,
            transitionID: transitionID
        )
        lifecycleDestinationCurrentItemObservation = handoff.destinationPlayer.observe(
            \.currentItem,
            options: [.new]
        ) { [weak self] player, _ in
            let currentItem = player.currentItem
            DispatchQueue.main.async {
                self?.observeLifecycleDestinationCurrentItem(currentItem, transitionID: transitionID)
            }
        }
        handoff.destinationPlayer.preroll(
            atRate: Float(handoff.destinationEntry.playbackRate.value)
        ) { [weak self] ready in
            guard ready else { return }
            DispatchQueue.main.async {
                self?.tryRevealLifecycleDestination(transitionID: transitionID)
            }
        }
        if handoff.transitionEnded {
            startLifecycleDestination(transitionID: transitionID)
        }
        logger.info("event=lifecycle_destination_retry transition_id=\(transitionID, privacy: .public)")
    }

    private func cancelLifecycleHandoff(notifyFailure: Bool) {
        guard let handoff = activeLifecycleHandoff else {
            clearLifecycleHandoffObservers()
            view.cancelLifecycleHandoffLayers()
            return
        }
        activeLifecycleHandoff = nil
        lifecycleTransitionEndID = nil
        lifecycleTransitionTimeoutWorkItem?.cancel()
        lifecycleTransitionTimeoutWorkItem = nil
        removeLifecycleCueTimeObserver(from: handoff.transitionPlayer)
        clearLifecycleHandoffObservers()
        handoff.transitionPlayer.pause()
        handoff.destinationPlayer.pause()
        handoff.destinationPlayer.removeAllItems()
        view.cancelLifecycleHandoffLayers()
        if notifyFailure {
            presentationStatus = .retained(requested: handoff.destination, displayed: handoff.source)
            onLifecycleTransitionFailed?(handoff.id)
        }
    }

    private func clearLifecycleHandoffObservers() {
        lifecycleDestinationCurrentItemObservation = nil
        lifecycleDestinationItemObservation = nil
        lifecycleDestinationDisplayObservation = nil
        lifecycleTransitionItemObservation = nil
        lifecycleTransitionDisplayObservation = nil
        removeLifecycleNotificationObservers()
    }

    private func removeLifecycleCueTimeObserver(from player: AVPlayer) {
        guard let lifecycleCueTimeObserver else { return }
        player.removeTimeObserver(lifecycleCueTimeObserver)
        self.lifecycleCueTimeObserver = nil
    }

    private func removeLifecycleNotificationObservers() {
        if let lifecycleDidEndObserver {
            NotificationCenter.default.removeObserver(lifecycleDidEndObserver)
            self.lifecycleDidEndObserver = nil
        }
        if let lifecycleFailedObserver {
            NotificationCenter.default.removeObserver(lifecycleFailedObserver)
            self.lifecycleFailedObserver = nil
        }
    }

    private func showReducedMotion(state: PetState, posterURL: URL?) -> PlaybackStartDisposition {
        cancelDirectReplacement()
        let posterImage = posterURL.flatMap { url -> NSImage? in
            guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
            return NSImage(contentsOf: url)
        }
        if let image = posterImage {
            view.showPlaceholder(nil)
            view.showPoster(image)
            stopQueuePlayback()
            currentState = state
            currentURL = nil
            currentPresentationIsOneShot = false
            presentationStatus = .presented(state)
            view.updateAccessibility(state: state, reducedMotion: reduceMotion)
            view.updateFPSBadge(
                nominalFramesPerSecond: nil,
                intendedFramesPerSecond: nil,
                reducedMotion: true
            )
            return .presented
        }
        if currentURL != nil || view.hasVisiblePoster {
            presentationStatus = .retained(requested: state, displayed: currentState)
            view.updateAccessibility(
                state: currentState,
                reducedMotion: reduceMotion,
                presentationSummary: "requested \(state.rawValue) has no static poster; showing \(currentState.rawValue)"
            )
            return .failed
        }
        view.showPlaceholder("\(state.rawValue)\nReduce Motion")
        currentState = state
        currentURL = nil
        currentPresentationIsOneShot = false
        presentationStatus = .presented(state)
        view.updateAccessibility(state: state, reducedMotion: reduceMotion)
        view.hideFPSBadge()
        return .presented
    }

    private func observeCurrentItem(_ item: AVPlayerItem?) {
        guard var transition = activeTransition,
              let item,
              queuePlayer.currentItem === item else { return }
        let identifier = ObjectIdentifier(item)
        guard identifier != observedCurrentItemIdentifier else {
            handleDisplayReadiness(view.playerLayer.isReadyForDisplay)
            return
        }
        if observedCurrentItemIdentifier != nil, transition.readiness.state == .preparing {
            transition.readiness = PresentationReadinessTracker()
            activeTransition = transition
            displayResetTransitionID = view.playerLayer.isReadyForDisplay ? nil : transition.id
        }
        observedCurrentItemIdentifier = identifier
        activeItemIdentifiers.insert(identifier)
        if let rate = deferredPlaybackResume.consumeWhenCurrentItemBecomesAvailable() {
            queuePlayer.playImmediately(atRate: Float(rate))
        }
        readyItemIdentifier = nil
        itemStatusObservation = nil
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async { self?.handleItemStatus(item) }
        }
    }

    private func handleItemStatus(_ item: AVPlayerItem) {
        guard var transition = activeTransition,
              queuePlayer.currentItem === item else { return }
        switch item.status {
        case .readyToPlay:
            readyItemIdentifier = ObjectIdentifier(item)
            let wasReady = transition.readiness.itemIsReady
            let outcome = transition.readiness.receive(.itemReady)
            activeTransition = transition
            if !wasReady, itemReadyLoggedTransitionID != transition.id {
                itemReadyLoggedTransitionID = transition.id
                let duration = Self.elapsedMilliseconds(since: transition.startedAt)
                logger.info("event=player_item_ready transition_id=\(transition.id, privacy: .public) state=\(transition.state.rawValue, privacy: .public) duration_ms=\(duration, format: .fixed(precision: 3), privacy: .public)")
            }
            resolve(outcome, transitionID: transition.id)
            handleDisplayReadiness(view.playerLayer.isReadyForDisplay)
        case .failed:
            failActiveTransition(reason: .itemFailed)
        case .unknown:
            break
        @unknown default:
            failActiveTransition(reason: .itemFailed)
        }
    }

    private func handleDisplayReadiness(_ isReady: Bool) {
        guard var transition = activeTransition else { return }
        if !isReady {
            displayResetTransitionID = transition.id
            return
        }
        guard displayResetTransitionID == transition.id,
              let currentItem = queuePlayer.currentItem,
              readyItemIdentifier == ObjectIdentifier(currentItem) else { return }
        let outcome = transition.readiness.receive(.displayReady)
        activeTransition = transition
        resolve(outcome, transitionID: transition.id)
    }

    private func resolve(_ outcome: PresentationReadinessOutcome, transitionID: UInt64) {
        guard outcome == .becameReady,
              let transition = activeTransition,
              transition.id == transitionID else { return }
        readinessTimeoutWorkItem?.cancel()
        readinessTimeoutWorkItem = nil
        currentState = transition.state
        currentURL = transition.url
        if let previewName = transition.previewName {
            presentationStatus = .previewing(requested: transition.state, clipName: previewName)
        } else {
            presentationStatus = .presented(transition.state)
        }
        view.showPoster(nil)
        view.showPlaceholder(nil)
        view.updateAccessibility(
            state: transition.state,
            reducedMotion: reduceMotion,
            presentationSummary: transition.previewName.map { "previewing \($0) once" }
        )
        let duration = Self.elapsedMilliseconds(since: transition.startedAt)
        logger.info("event=display_ready transition_id=\(transition.id, privacy: .public) state=\(transition.state.rawValue, privacy: .public) duration_ms=\(duration, format: .fixed(precision: 3), privacy: .public)")
        if lifecycleTransitionEndID == transition.id {
            // The lifecycle deadline was anchored at the authoritative state
            // change, so decoder readiness consumes the same bounded budget.
        } else {
            onPresentationEvent?(transition.id, transition.state, .ready)
        }
    }

    private func failActiveTransition(reason: PlaybackFailureReason) {
        guard var transition = activeTransition,
              transition.readiness.receive(.failure) == .becameFailed else { return }
        let failedLifecycleTransitionID = lifecycleTransitionEndID == transition.id
            ? transition.id
            : nil
        activeTransition = nil
        oneShotEndTransitionID = nil
        playlistEndTransitionID = nil
        lifecycleTransitionEndID = nil
        lifecycleTransitionTimeoutWorkItem?.cancel()
        lifecycleTransitionTimeoutWorkItem = nil
        readinessTimeoutWorkItem?.cancel()
        readinessTimeoutWorkItem = nil
        fpsLoadingTask?.cancel()
        fpsLoadingTask = nil
        itemStatusObservation = nil
        activeItemIdentifiers.removeAll(keepingCapacity: true)
        stopQueuePlayback()
        currentState = transition.state
        currentURL = nil
        currentPresentationIsOneShot = false
        presentationStatus = .placeholder(transition.state)
        view.showPoster(nil)
        view.showPlaceholder("\(transition.state.rawValue)\n\(reason.userMessage(for: transition.state))")
        view.hideFPSBadge()
        view.updateAccessibility(
            state: transition.state,
            reducedMotion: reduceMotion,
            presentationSummary: "media unavailable, transparent placeholder"
        )
        logger.error("event=playback_unavailable transition_id=\(transition.id, privacy: .public) state=\(transition.state.rawValue, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        if let failedLifecycleTransitionID {
            onLifecycleTransitionFailed?(failedLifecycleTransitionID)
        } else {
            onPresentationEvent?(transition.id, transition.state, .failed)
        }
    }

    private func scheduleReadinessTimeout(transitionID: UInt64) {
        guard suspensionPolicy.canStartReadinessDeadline else { return }
        readinessTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.activeTransition?.id == transitionID,
                  self.activeTransition?.readiness.state == .preparing else { return }
            self.failActiveTransition(reason: .readinessTimeout)
        }
        readinessTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readinessTimeout, execute: workItem)
    }

    private func scheduleLifecycleTransitionTimeout(transitionID: UInt64, startedAt: UInt64) {
        lifecycleTransitionTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.lifecycleTransitionEndID == transitionID,
                  self.activeLifecycleHandoff?.id == transitionID else { return }
            self.abortLifecycleTransition(transitionID: transitionID)
        }
        lifecycleTransitionTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: DispatchTime(uptimeNanoseconds: LifecycleTransitionDeadline.uptimeNanoseconds(
                startedAt: startedAt
            )),
            execute: workItem
        )
    }

    private func abortLifecycleTransition(transitionID: UInt64) {
        guard lifecycleTransitionEndID == transitionID,
              activeLifecycleHandoff?.id == transitionID else { return }
        logger.error("event=lifecycle_transition_timeout transition_id=\(transitionID, privacy: .public)")
        startLifecycleDestination(transitionID: transitionID)
        if activeLifecycleHandoff?.destinationVisible == true {
            promoteLifecycleDestination(transitionID: transitionID)
            return
        }
        cancelLifecycleHandoff(notifyFailure: true)
    }

    private func invalidateActiveTransition() {
        readinessTimeoutWorkItem?.cancel()
        readinessTimeoutWorkItem = nil
        fpsLoadingTask?.cancel()
        fpsLoadingTask = nil
        activeTransition = nil
        oneShotEndTransitionID = nil
        playlistEndTransitionID = nil
        lifecycleTransitionEndID = nil
        lifecycleTransitionTimeoutWorkItem?.cancel()
        lifecycleTransitionTimeoutWorkItem = nil
        itemStatusObservation = nil
        observedCurrentItemIdentifier = nil
        readyItemIdentifier = nil
        displayResetTransitionID = nil
        activeItemIdentifiers.removeAll(keepingCapacity: true)
    }

    private func stopQueuePlayback() {
        view.playerLayer.player = nil
        queuePlayer.pause()
        suspensionPolicy.clearPlayback()
        deferredPlaybackResume.cancel()
        looper = nil
        queuePlayer.removeAllItems()
        view.playerLayer.player = queuePlayer
    }

    private func applyPlaybackDirective(_ directive: PlaybackControlDirective) {
        switch directive {
        case .none:
            break
        case .pause:
            deferredPlaybackResume.cancel()
            queuePlayer.pause()
        case let .resume(rate):
            if let applicableRate = deferredPlaybackResume.prepare(
                rate: rate,
                currentItemAvailable: queuePlayer.currentItem != nil
            ) {
                queuePlayer.playImmediately(atRate: Float(applicableRate))
            }
        }
    }

    private func loadFPSIfNeeded(
        for url: URL,
        asset: AVAsset,
        playbackRate: Double,
        transitionID: UInt64
    ) {
        fpsLoadingTask?.cancel()
        guard view.isFPSBadgeEnabled else {
            fpsLoadingTask = nil
            return
        }
        let cacheKey = LocalFileRevision(url: url)
        if let cacheKey, let nominal = fpsCache.value(for: cacheKey) {
            view.updateFPSBadge(
                nominalFramesPerSecond: nominal,
                intendedFramesPerSecond: nominal * playbackRate,
                reducedMotion: false
            )
            fpsLoadingTask = nil
            return
        }
        fpsLoadingTask = Task { @MainActor [weak self] in
            do {
                guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                    guard !Task.isCancelled, self?.activeTransition?.id == transitionID else { return }
                    self?.view.hideFPSBadge()
                    self?.fpsLoadingTask = nil
                    return
                }
                let nominal = Double(try await videoTrack.load(.nominalFrameRate))
                try Task.checkCancellation()
                guard let self, self.activeTransition?.id == transitionID else { return }
                if let cacheKey, nominal.isFinite, nominal > 0 {
                    self.fpsCache.insert(nominal, for: cacheKey)
                }
                let intended = nominal * playbackRate
                self.view.updateFPSBadge(
                    nominalFramesPerSecond: nominal,
                    intendedFramesPerSecond: intended,
                    reducedMotion: false
                )
                self.fpsLoadingTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self?.activeTransition?.id == transitionID else { return }
                self?.view.hideFPSBadge()
                self?.fpsLoadingTask = nil
            }
        }
    }

    private static func elapsedMilliseconds(since started: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    }

    private func softFailure(
        state: PetState,
        reason: PlaybackFailureReason
    ) -> PlaybackStartDisposition {
        logger.error("event=playback_unavailable state=\(state.rawValue, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        // Before replacing the queue, retain a known-good active clip for
        // non-idle requests. Once a queued item fails, failActiveTransition
        // stops it and truthfully presents a transparent placeholder instead.
        let shouldRetain = PlaybackFallbackPolicy.shouldRetainCurrentPresentation(
            hasCurrentMedia: currentURL != nil,
            currentIsOneShot: currentPresentationIsOneShot,
            requestedState: state
        )
        if !shouldRetain {
            stopQueuePlayback()
            currentState = state
            currentURL = nil
            currentPresentationIsOneShot = false
            presentationStatus = .placeholder(state)
            view.showPoster(nil)
            view.showPlaceholder("\(state.rawValue)\n\(reason.userMessage(for: state))")
            view.hideFPSBadge()
            view.updateAccessibility(
                state: state,
                reducedMotion: reduceMotion,
                presentationSummary: "media unavailable, transparent placeholder"
            )
        } else {
            presentationStatus = .retained(requested: state, displayed: currentState)
            view.updateAccessibility(
                state: currentState,
                reducedMotion: reduceMotion,
                presentationSummary: "requested \(state.rawValue) unavailable, showing \(currentState.rawValue)"
            )
        }
        return .failed
    }
}
