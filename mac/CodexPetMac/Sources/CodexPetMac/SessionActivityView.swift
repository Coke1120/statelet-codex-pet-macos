import AppKit
import CodexPetCore
import Foundation

struct SessionActivityDisplayState: Equatable {
    let active: [SessionActivityItem]
    let completed: [SessionActivityItem]
    let hiddenActiveCount: Int
    let hiddenCompletedCount: Int
    let compact: Bool

    var isEmpty: Bool { active.isEmpty && completed.isEmpty && !compact }
    var visibleItemCount: Int { active.count + completed.count }
}

enum SessionActivityPresentation {
    static let maximumRowsPerGroup = 3

    static func displayState(
        snapshot: SessionActivitySnapshot?,
        acknowledgedIDs: Set<String>,
        compact: Bool,
        maximumRowsPerGroup: Int = Self.maximumRowsPerGroup
    ) -> SessionActivityDisplayState {
        let active = snapshot?.active ?? []
        let completed = (snapshot?.completed ?? []).filter {
            !acknowledgedIDs.contains($0.id)
        }
        guard !compact else {
            return SessionActivityDisplayState(
                active: [],
                completed: [],
                hiddenActiveCount: active.count,
                hiddenCompletedCount: completed.count,
                compact: true
            )
        }
        let rowLimit = max(1, maximumRowsPerGroup)
        return SessionActivityDisplayState(
            active: Array(active.prefix(rowLimit)),
            completed: Array(completed.prefix(rowLimit)),
            hiddenActiveCount: max(0, active.count - rowLimit),
            hiddenCompletedCount: max(0, completed.count - rowLimit),
            compact: false
        )
    }
}

final class SessionActivityView: NSView {
    private let stack = NSStackView()
    private let clock: () -> Date
    private var snapshot: SessionActivitySnapshot?
    private var acknowledgedIDs: Set<String> = []
    private var compactOverride: Bool?
    private(set) var displayState = SessionActivityDisplayState(
        active: [],
        completed: [],
        hiddenActiveCount: 0,
        hiddenCompletedCount: 0,
        compact: false
    )
    private(set) var renderedItemIDs: [String] = []
    var onAcknowledge: ((String) -> Void)?
    var onExpand: (() -> Void)?

    init(frame frameRect: NSRect = .zero, clock: @escaping () -> Date = Date.init) {
        self.clock = clock
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
        layer?.borderWidth = 1

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Codex session activity")
        rebuild()
    }

    required init?(coder: NSCoder) {
        fatalError("SessionActivityView does not support NSCoder initialization")
    }

    override var intrinsicContentSize: NSSize {
        let fitting = stack.fittingSize
        return NSSize(
            width: max(190, ceil(fitting.width + 20)),
            height: max(44, ceil(fitting.height + 20))
        )
    }

    override func layout() {
        super.layout()
        let compact = compactOverride ?? (bounds.width < 180 || bounds.height < 110)
        if compact != displayState.compact {
            rebuild()
        }
    }

    func update(snapshot: SessionActivitySnapshot?, acknowledgedIDs: Set<String>) {
        self.snapshot = snapshot
        self.acknowledgedIDs = acknowledgedIDs
        rebuild()
    }

    func setCompactOverride(_ compact: Bool?) {
        compactOverride = compact
        rebuild()
    }

    private func rebuild() {
        let compact = compactOverride ?? (bounds.width < 180 || bounds.height < 110)
        displayState = SessionActivityPresentation.displayState(
            snapshot: snapshot,
            acknowledgedIDs: acknowledgedIDs,
            compact: compact
        )
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        renderedItemIDs = []

        let activeCount = snapshot?.active.count ?? 0
        let completedCount = snapshot?.completed.filter {
            !acknowledgedIDs.contains($0.id)
        }.count ?? 0
        guard activeCount > 0 || completedCount > 0 else {
            isHidden = true
            invalidateIntrinsicContentSize()
            return
        }
        isHidden = false

        if compact {
            if activeCount > 0 {
                addCompactPill(title: "Running · \(activeCount)", accessibility: "Running sessions: \(activeCount)")
            }
            if completedCount > 0 {
                addCompactPill(title: "Completed · \(completedCount)", accessibility: "Completed unread sessions: \(completedCount)")
            }
        } else {
            if !displayState.active.isEmpty {
                addGroup(
                    title: "Running · \(activeCount)",
                    accessibility: "Running sessions: \(activeCount)",
                    items: displayState.active,
                    completed: false,
                    hiddenCount: displayState.hiddenActiveCount
                )
            }
            if !displayState.completed.isEmpty {
                addGroup(
                    title: "Completed · \(completedCount)",
                    accessibility: "Completed unread sessions: \(completedCount)",
                    items: displayState.completed,
                    completed: true,
                    hiddenCount: displayState.hiddenCompletedCount
                )
            }
        }
        setAccessibilityValue(
            "\(activeCount) running, \(completedCount) completed unread"
        )
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func addGroup(
        title: String,
        accessibility: String,
        items: [SessionActivityItem],
        completed: Bool,
        hiddenCount: Int
    ) {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 12, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.setAccessibilityElement(true)
        header.setAccessibilityRole(.staticText)
        header.setAccessibilityLabel(accessibility)
        stack.addArrangedSubview(header)

        for (index, item) in items.enumerated() {
            renderedItemIDs.append(item.id)
            if completed {
                addCompletedRow(item, ordinal: index + 1)
            } else {
                addActiveRow(item, ordinal: index + 1)
            }
        }
        if hiddenCount > 0 {
            let overflow = NSTextField(labelWithString: "+\(hiddenCount) more")
            overflow.font = .systemFont(ofSize: 11)
            overflow.textColor = .secondaryLabelColor
            overflow.setAccessibilityElement(true)
            overflow.setAccessibilityRole(.staticText)
            overflow.setAccessibilityLabel("\(hiddenCount) more sessions")
            stack.addArrangedSubview(overflow)
        }
    }

    private func addActiveRow(_ item: SessionActivityItem, ordinal: Int) {
        let label = NSTextField(labelWithString: "\(item.state.rawValue.capitalized) · \(item.category.displayName) #\(ordinal) · \(relativeAge(item.startedAt))")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = item.state.sessionActivityColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityElement(true)
        label.setAccessibilityRole(.staticText)
        label.setAccessibilityLabel("Active \(item.state.rawValue) session \(ordinal)")
        label.setAccessibilityValue("\(item.category.displayName), started \(relativeAge(item.startedAt))")
        let row = NSStackView(views: [activityDot(color: item.state.sessionActivityColor), label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        stack.addArrangedSubview(row)
    }

    private func addCompletedRow(_ item: SessionActivityItem, ordinal: Int) {
        let completionTime = item.completedAt ?? item.eventAt
        let label = NSTextField(labelWithString: "Completed · \(item.category.displayName) #\(ordinal) · \(relativeAge(completionTime)) · Unread")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .systemGreen
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityElement(true)
        label.setAccessibilityRole(.staticText)
        label.setAccessibilityLabel("Completed unread session \(ordinal)")
        label.setAccessibilityValue("\(item.category.displayName), completed \(relativeAge(completionTime))")

        let acknowledge = NSButton(title: "Mark as read", target: self, action: #selector(markAsRead(_:)))
        acknowledge.bezelStyle = .inline
        acknowledge.controlSize = .small
        acknowledge.setAccessibilityLabel("Mark completed session as read")
        acknowledge.identifier = NSUserInterfaceItemIdentifier(item.id)

        let row = NSStackView(views: [activityDot(color: .systemGreen), label, acknowledge])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.group)
        row.setAccessibilityLabel("Completed unread session \(ordinal)")
        stack.addArrangedSubview(row)
    }

    private func activityDot(color: NSColor) -> NSTextField {
        let dot = NSTextField(labelWithString: "●")
        dot.font = .systemFont(ofSize: 9, weight: .bold)
        dot.textColor = color
        dot.setAccessibilityElement(false)
        return dot
    }

    private func addCompactPill(title: String, accessibility: String) {
        let expand = NSButton(title: title, target: self, action: #selector(expandCompact(_:)))
        expand.bezelStyle = .inline
        expand.font = .systemFont(ofSize: 13, weight: .semibold)
        expand.alignment = .left
        expand.contentTintColor = .labelColor
        expand.setAccessibilityLabel("Show \(accessibility.lowercased()) details")
        expand.setAccessibilityValue("Compact count; activate to expand")
        stack.addArrangedSubview(expand)
    }

    private func relativeAge(_ timestamp: Double) -> String {
        let seconds = max(0, clock().timeIntervalSince1970 - timestamp)
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }

    @objc private func markAsRead(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        onAcknowledge?(id)
    }

    @objc private func expandCompact(_ sender: NSButton) {
        compactOverride = false
        rebuild()
        onExpand?()
    }
}

final class SessionActivityScrollContainer: NSScrollView {
    private let activityView: SessionActivityView

    init(activityView: SessionActivityView) {
        self.activityView = activityView
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        autohidesScrollers = true
        documentView = activityView
    }

    required init?(coder: NSCoder) {
        fatalError("SessionActivityScrollContainer does not support NSCoder initialization")
    }

    func setScrollable(_ scrollable: Bool) {
        hasVerticalScroller = scrollable
        hasHorizontalScroller = scrollable
        layoutDocument()
    }

    override func layout() {
        super.layout()
        layoutDocument()
    }

    private func layoutDocument() {
        let fitting = activityView.fittingSize
        let viewport = contentSize
        activityView.frame = NSRect(
            origin: .zero,
            size: NSSize(
                width: max(viewport.width, fitting.width),
                height: max(viewport.height, fitting.height)
            )
        )
    }
}

private extension PetState {
    var sessionActivityColor: NSColor {
        switch self {
        case .idle: return .secondaryLabelColor
        case .running: return .systemBlue
        case .waiting: return .systemOrange
        case .review: return .systemIndigo
        }
    }
}

final class SessionActivityPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect, alwaysOnTop: Bool, fullScreenAuxiliary: Bool) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = alwaysOnTop
        level = alwaysOnTop ? .floating : .normal
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        if fullScreenAuxiliary { collectionBehavior.insert(.fullScreenAuxiliary) }
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
    }

    func apply(alwaysOnTop: Bool, fullScreenAuxiliary: Bool) {
        isFloatingPanel = alwaysOnTop
        level = alwaysOnTop ? .floating : .normal
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        if fullScreenAuxiliary { behavior.insert(.fullScreenAuxiliary) }
        collectionBehavior = behavior
    }

    func orderVisible(alwaysOnTop: Bool) {
        if alwaysOnTop {
            orderFrontRegardless()
        } else {
            orderFront(nil)
        }
    }

    static func anchoredFrame(
        beside petFrame: NSRect,
        contentSize: NSSize,
        visibleFrame: NSRect,
        gap: CGFloat = 10
    ) -> NSRect {
        SessionActivityPanelPlacement.frame(
            beside: petFrame,
            contentSize: contentSize,
            visibleFrame: visibleFrame,
            gap: gap
        )
    }
}

enum SessionActivityPanelVisibilityPolicy {
    static func shouldOrderFront(
        wasAvailable: Bool,
        isAvailable: Bool
    ) -> Bool {
        !wasAvailable && isAvailable
    }
}

private enum SessionActivityPanelPlacement {
    private enum Edge: Int {
        case right
        case left
        case above
        case below
    }

    private struct Region {
        let edge: Edge
        let frame: NSRect
    }

    static func frame(
        beside petFrame: NSRect,
        contentSize: NSSize,
        visibleFrame: NSRect,
        gap: CGFloat
    ) -> NSRect {
        let requested = NSSize(
            width: min(max(1, contentSize.width), visibleFrame.width),
            height: min(max(1, contentSize.height), visibleFrame.height)
        )
        let regions = availableRegions(
            beside: petFrame,
            visibleFrame: visibleFrame,
            gap: gap
        )
        if let fitting = regions.first(where: {
            $0.frame.width >= requested.width && $0.frame.height >= requested.height
        }) {
            return positioned(requested, in: fitting, beside: petFrame)
        }
        guard let safest = regions.max(by: {
            usableArea(for: requested, in: $0.frame)
                < usableArea(for: requested, in: $1.frame)
        }) else {
            return NSRect(origin: visibleFrame.origin, size: .zero)
        }
        let bounded = NSSize(
            width: min(requested.width, safest.frame.width),
            height: min(requested.height, safest.frame.height)
        )
        return positioned(bounded, in: safest, beside: petFrame)
    }

    static func canFit(
        _ size: NSSize,
        beside petFrame: NSRect,
        visibleFrame: NSRect,
        gap: CGFloat
    ) -> Bool {
        availableRegions(beside: petFrame, visibleFrame: visibleFrame, gap: gap).contains {
            $0.frame.width >= size.width && $0.frame.height >= size.height
        }
    }

    private static func availableRegions(
        beside petFrame: NSRect,
        visibleFrame: NSRect,
        gap: CGFloat
    ) -> [Region] {
        let rightX = max(visibleFrame.minX, petFrame.maxX + gap)
        let aboveY = max(visibleFrame.minY, petFrame.maxY + gap)
        return [
            Region(
                edge: .right,
                frame: NSRect(
                    x: rightX,
                    y: visibleFrame.minY,
                    width: max(0, visibleFrame.maxX - rightX),
                    height: visibleFrame.height
                )
            ),
            Region(
                edge: .left,
                frame: NSRect(
                    x: visibleFrame.minX,
                    y: visibleFrame.minY,
                    width: max(0, min(visibleFrame.maxX, petFrame.minX - gap) - visibleFrame.minX),
                    height: visibleFrame.height
                )
            ),
            Region(
                edge: .above,
                frame: NSRect(
                    x: visibleFrame.minX,
                    y: aboveY,
                    width: visibleFrame.width,
                    height: max(0, visibleFrame.maxY - aboveY)
                )
            ),
            Region(
                edge: .below,
                frame: NSRect(
                    x: visibleFrame.minX,
                    y: visibleFrame.minY,
                    width: visibleFrame.width,
                    height: max(0, min(visibleFrame.maxY, petFrame.minY - gap) - visibleFrame.minY)
                )
            ),
        ].filter { $0.frame.width > 0 && $0.frame.height > 0 }
    }

    private static func usableArea(for size: NSSize, in region: NSRect) -> CGFloat {
        min(size.width, region.width) * min(size.height, region.height)
    }

    private static func positioned(
        _ size: NSSize,
        in region: Region,
        beside petFrame: NSRect
    ) -> NSRect {
        let x: CGFloat
        let y: CGFloat
        switch region.edge {
        case .right:
            x = region.frame.minX
            y = min(max(region.frame.minY, petFrame.maxY - size.height), region.frame.maxY - size.height)
        case .left:
            x = region.frame.maxX - size.width
            y = min(max(region.frame.minY, petFrame.maxY - size.height), region.frame.maxY - size.height)
        case .above:
            x = min(max(region.frame.minX, petFrame.midX - size.width / 2), region.frame.maxX - size.width)
            y = region.frame.minY
        case .below:
            x = min(max(region.frame.minX, petFrame.midX - size.width / 2), region.frame.maxX - size.width)
            y = region.frame.maxY - size.height
        }
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
}

struct SessionActivityPanelLayout: Equatable {
    let available: Bool
    let compact: Bool
    let scrollable: Bool
    let frame: NSRect
}

enum SessionActivityLayoutPolicy {
    static func layout(
        beside petFrame: NSRect,
        expandedSize: NSSize,
        compactSize: NSSize,
        visibleFrame: NSRect,
        forceExpanded: Bool,
        gap: CGFloat = 10
    ) -> SessionActivityPanelLayout {
        let expandedFits = SessionActivityPanelPlacement.canFit(
            expandedSize,
            beside: petFrame,
            visibleFrame: visibleFrame,
            gap: gap
        )
        let compactFits = SessionActivityPanelPlacement.canFit(
            compactSize,
            beside: petFrame,
            visibleFrame: visibleFrame,
            gap: gap
        )
        let hasSafeViewport = SessionActivityPanelPlacement.canFit(
            NSSize(width: 1, height: 1),
            beside: petFrame,
            visibleFrame: visibleFrame,
            gap: gap
        )
        guard hasSafeViewport else {
            // No visible, non-overlapping geometry exists. Report the panel as
            // unavailable so callers hide it instead of exposing a zero-sized
            // interactive surface or overlapping the pet.
            return SessionActivityPanelLayout(
                available: false,
                compact: true,
                scrollable: false,
                frame: .zero
            )
        }
        let scrollable = !expandedFits && (forceExpanded || !compactFits)
        let compact = !expandedFits && !scrollable
        let selectedSize = expandedFits ? expandedSize : compactSize
        return SessionActivityPanelLayout(
            available: true,
            compact: compact,
            scrollable: scrollable,
            frame: SessionActivityPanel.anchoredFrame(
                beside: petFrame,
                contentSize: selectedSize,
                visibleFrame: visibleFrame,
                gap: gap
            )
        )
    }
}
