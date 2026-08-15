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
        label.setAccessibilityValue("\(item.category.displayName), started \(relativeAge(item.startedAt)) ago")
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
        label.setAccessibilityValue("\(item.category.displayName), completed \(relativeAge(completionTime)) ago")

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
    override var canBecomeKey: Bool { false }
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

    static func anchoredFrame(
        beside petFrame: NSRect,
        contentSize: NSSize,
        visibleFrame: NSRect,
        gap: CGFloat = 10
    ) -> NSRect {
        let preferredRight = petFrame.maxX + gap
        let preferredLeft = petFrame.minX - gap - contentSize.width
        let x = preferredRight + contentSize.width <= visibleFrame.maxX
            ? preferredRight
            : max(visibleFrame.minX, preferredLeft)
        let y = min(
            max(visibleFrame.minY, petFrame.maxY - contentSize.height),
            visibleFrame.maxY - contentSize.height
        )
        return NSRect(x: x, y: y, width: contentSize.width, height: contentSize.height)
    }
}
