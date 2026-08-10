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

    let playerLayer = AVPlayerLayer()
    private let posterView = NSImageView()
    private let placeholderLabel = NSTextField(wrappingLabelWithString: "")
    private let stateBadge = PetStateBadgeView()
    private let fpsBadge = NSTextField(labelWithString: "")
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
        layer?.addSublayer(playerLayer)

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
        quickControls.spacing = 3
        quickControls.translatesAutoresizingMaskIntoConstraints = true
        quickControls.setViews([nextClipButton, temporaryStateButton], in: .leading)
        quickControls.setAccessibilityElement(true)
        quickControls.setAccessibilityRole(.group)
        quickControls.setAccessibilityLabel("Pet quick controls")
        addSubview(quickControls)
    }

    private func configureQuickControlButton(
        _ button: NSButton,
        symbolName: String,
        accessibilityLabel: String,
        action: Selector
    ) {
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.bezelStyle = .inline
        button.controlSize = .small
        button.showsBorderOnlyWhileMouseInside = true
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
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

    func showPoster(_ image: NSImage?) {
        posterView.image = image
        posterView.isHidden = image == nil
        playerLayer.isHidden = image != nil
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
        menu.popUp(
            positioning: menu.items.first(where: { $0.state == .on }),
            at: NSPoint(x: temporaryStateButton.bounds.minX, y: temporaryStateButton.bounds.maxY + 2),
            in: temporaryStateButton
        )
    }

    @objc private func selectTemporaryState(_ sender: NSMenuItem) {
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
        if quickControls.frame.contains(point) {
            let controlPoint = convert(point, to: quickControls)
            return quickControls.hitTest(controlPoint) ?? self
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

    private struct ActiveTransition {
        let id: UInt64
        let state: PetState
        let url: URL
        let startedAt: UInt64
        let previewName: String?
        var readiness = PresentationReadinessTracker()
    }

    private let logger = Logger(subsystem: StateletIdentity.bundleIdentifier, category: "player")
    let view: PetPlayerView
    private let queuePlayer = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var currentItemObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var displayReadyObservation: NSKeyValueObservation?
    private var failedToEndObserver: NSObjectProtocol?
    private var didPlayToEndObserver: NSObjectProtocol?
    private var readinessTimeoutWorkItem: DispatchWorkItem?
    private var fpsLoadingTask: Task<Void, Never>?
    private var activeTransition: ActiveTransition?
    private var itemReadyLoggedTransitionID: UInt64?
    private var displayResetTransitionID: UInt64?
    private var observedCurrentItemIdentifier: ObjectIdentifier?
    private var readyItemIdentifier: ObjectIdentifier?
    private var activeItemIdentifiers: Set<ObjectIdentifier> = []
    private var oneShotEndTransitionID: UInt64?
    private var playlistEndTransitionID: UInt64?
    private(set) var currentState: PetState = .idle
    private(set) var currentURL: URL?
    private var currentPresentationIsOneShot = false
    private(set) var presentationStatus: PlaybackPresentationStatus = .awaiting
    private var reduceMotion = false

    var onPresentationEvent: ((UInt64, PetState, PlaybackPresentationEvent) -> Void)?
    var onOneShotEnded: ((UInt64) -> Void)?
    var onPlaylistClipEnded: ((UInt64, PetState) -> Void)?

    init(view: PetPlayerView) {
        self.view = view
        view.playerLayer.player = queuePlayer
        queuePlayer.actionAtItemEnd = .none
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
            }
        }
    }

    deinit {
        readinessTimeoutWorkItem?.cancel()
        fpsLoadingTask?.cancel()
        if let failedToEndObserver {
            NotificationCenter.default.removeObserver(failedToEndObserver)
        }
        if let didPlayToEndObserver {
            NotificationCenter.default.removeObserver(didPlayToEndObserver)
        }
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
        invalidateActiveTransition()
        if reduceMotion {
            return showReducedMotion(state: state, posterURL: posterURL)
        }
        guard let entry, let url else {
            return softFailure(state: state, reason: .unmapped)
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return softFailure(state: state, reason: .unreadable)
        }

        stopQueuePlayback()
        currentPresentationIsOneShot = notifyWhenEnded
        currentURL = nil
        itemReadyLoggedTransitionID = nil
        displayResetTransitionID = nil
        observedCurrentItemIdentifier = nil
        readyItemIdentifier = nil
        activeItemIdentifiers.removeAll(keepingCapacity: true)
        activeTransition = ActiveTransition(
            id: transitionID,
            state: state,
            url: url,
            startedAt: startedAt,
            previewName: previewName
        )
        oneShotEndTransitionID = notifyWhenEnded ? transitionID : nil
        playlistEndTransitionID = advancePlaylistWhenEnded ? transitionID : nil
        view.hideFPSBadge()
        loadFPS(
            for: url,
            playbackRate: entry.playbackRate.value,
            transitionID: transitionID
        )

        // Detaching the layer invalidates readiness inherited from the prior
        // item. A new transition cannot pass the display gate until the layer
        // has been observed not-ready for this transition and then ready again.
        view.playerLayer.player = nil
        if !view.playerLayer.isReadyForDisplay {
            displayResetTransitionID = transitionID
        }
        view.playerLayer.player = queuePlayer

        let item = AVPlayerItem(url: url)
        if entry.loop && !advancePlaylistWhenEnded {
            looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        } else {
            queuePlayer.insert(item, after: nil)
        }
        observeCurrentItem(queuePlayer.currentItem)
        presentationStatus = .preparing(state)
        view.showPoster(nil)
        view.showPlaceholder(nil)
        view.updateAccessibility(
            state: state,
            reducedMotion: reduceMotion,
            presentationSummary: previewName.map { "preparing one-time preview of \($0)" }
                ?? "preparing media"
        )
        scheduleReadinessTimeout(transitionID: transitionID)
        queuePlayer.playImmediately(atRate: Float(entry.playbackRate.value))
        return .preparing
    }

    func setReduceMotion(_ enabled: Bool) {
        reduceMotion = enabled
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
        invalidateActiveTransition()
        stopQueuePlayback()
        currentURL = nil
        currentPresentationIsOneShot = false
        presentationStatus = .awaiting
        view.showPoster(nil)
        view.showPlaceholder(nil)
        view.hideFPSBadge()
    }

    private func showReducedMotion(state: PetState, posterURL: URL?) -> PlaybackStartDisposition {
        stopQueuePlayback()
        currentState = state
        currentURL = nil
        currentPresentationIsOneShot = false
        presentationStatus = .presented(state)
        view.updateAccessibility(state: state, reducedMotion: reduceMotion)
        if let posterURL,
           FileManager.default.isReadableFile(atPath: posterURL.path),
           let image = NSImage(contentsOf: posterURL) {
            view.showPlaceholder(nil)
            view.showPoster(image)
            view.updateFPSBadge(
                nominalFramesPerSecond: nil,
                intendedFramesPerSecond: nil,
                reducedMotion: true
            )
            return .presented
        }
        view.showPoster(nil)
        view.showPlaceholder("\(state.rawValue)\nReduce Motion")
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
        onPresentationEvent?(transition.id, transition.state, .ready)
    }

    private func failActiveTransition(reason: PlaybackFailureReason) {
        guard var transition = activeTransition,
              transition.readiness.receive(.failure) == .becameFailed else { return }
        activeTransition = nil
        oneShotEndTransitionID = nil
        playlistEndTransitionID = nil
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
        onPresentationEvent?(transition.id, transition.state, .failed)
    }

    private func scheduleReadinessTimeout(transitionID: UInt64) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.activeTransition?.id == transitionID,
                  self.activeTransition?.readiness.state == .preparing else { return }
            self.failActiveTransition(reason: .readinessTimeout)
        }
        readinessTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readinessTimeout, execute: workItem)
    }

    private func invalidateActiveTransition() {
        readinessTimeoutWorkItem?.cancel()
        readinessTimeoutWorkItem = nil
        fpsLoadingTask?.cancel()
        fpsLoadingTask = nil
        activeTransition = nil
        oneShotEndTransitionID = nil
        playlistEndTransitionID = nil
        itemStatusObservation = nil
        observedCurrentItemIdentifier = nil
        readyItemIdentifier = nil
        displayResetTransitionID = nil
        activeItemIdentifiers.removeAll(keepingCapacity: true)
    }

    private func stopQueuePlayback() {
        view.playerLayer.player = nil
        queuePlayer.pause()
        looper = nil
        queuePlayer.removeAllItems()
        view.playerLayer.player = queuePlayer
    }

    private func loadFPS(for url: URL, playbackRate: Double, transitionID: UInt64) {
        fpsLoadingTask?.cancel()
        fpsLoadingTask = Task { @MainActor [weak self] in
            do {
                let asset = AVURLAsset(url: url)
                guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                    guard !Task.isCancelled, self?.activeTransition?.id == transitionID else { return }
                    self?.view.hideFPSBadge()
                    self?.fpsLoadingTask = nil
                    return
                }
                let nominal = Double(try await videoTrack.load(.nominalFrameRate))
                try Task.checkCancellation()
                guard let self, self.activeTransition?.id == transitionID else { return }
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
