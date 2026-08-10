import AppKit
import CodexPetCore
import Darwin

private enum AnimationLibraryLayout {
    static let importStripHeight: CGFloat = 48
    static let minimumClipListHeight: CGFloat = 160
}

enum MP4ImportURLValidation {
    case accepted([URL])
    case rejected(String)
}

enum MP4ImportURLValidator {
    static func validate(_ sourceURLs: [URL], fileManager _: FileManager = .default) -> MP4ImportURLValidation {
        guard !sourceURLs.isEmpty else {
            return .rejected("No files were provided.")
        }
        var seenPaths: Set<String> = []
        var accepted: [URL] = []
        for sourceURL in sourceURLs {
            guard sourceURL.isFileURL, sourceURL.host.map({ $0.isEmpty || $0 == "localhost" }) ?? true else {
                return .rejected("Only local MP4 files can be imported.")
            }
            let url = sourceURL.standardizedFileURL
            let name = url.lastPathComponent.isEmpty ? "That item" : url.lastPathComponent
            guard url.pathExtension.caseInsensitiveCompare("mp4") == .orderedSame else {
                return .rejected("\(name) is not an MP4 file.")
            }
            if let rejectionReason = rejectionReason(for: url, name: name) {
                return .rejected(rejectionReason)
            }
            if seenPaths.insert(url.path).inserted {
                accepted.append(url)
            }
        }
        guard !accepted.isEmpty else {
            return .rejected("No new MP4 files were provided.")
        }
        return .accepted(accepted)
    }

    private static func rejectionReason(for url: URL, name: String) -> String? {
        var pathStatus = stat()
        let inspectionResult = url.path.withCString { path in
            Darwin.lstat(path, &pathStatus)
        }
        guard inspectionResult == 0 else {
            return errno == ENOENT || errno == ENOTDIR
                ? "\(name) could not be found."
                : "\(name) could not be inspected."
        }

        let pathType = pathStatus.st_mode & mode_t(S_IFMT)
        if pathType == mode_t(S_IFLNK) {
            return "\(name) is a symbolic link. Drop the original MP4 file instead."
        }
        guard pathType == mode_t(S_IFREG) else {
            if pathType == mode_t(S_IFDIR) {
                return "\(name) is a folder. Drop MP4 files instead."
            }
            return "\(name) is not a regular file."
        }

        let descriptor = url.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            switch errno {
            case EACCES, EPERM:
                return "\(name) is not readable."
            case ELOOP:
                return "\(name) is a symbolic link. Drop the original MP4 file instead."
            case ENOENT, ENOTDIR:
                return "\(name) could not be found."
            default:
                return "\(name) could not be opened."
            }
        }
        defer { Darwin.close(descriptor) }

        var openedStatus = stat()
        guard Darwin.fstat(descriptor, &openedStatus) == 0 else {
            return "\(name) could not be inspected."
        }
        guard openedStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            return "\(name) is not a regular file."
        }
        guard openedStatus.st_size > 0 else {
            return "\(name) is empty."
        }
        return nil
    }
}

struct SettingsPreviewMetadata: Equatable {
    let state: PetState
    let path: String
}

private final class LibraryStateButton: NSButton {
    let petState: PetState

    init(state: PetState, target: AnyObject?, action: Selector) {
        petState = state
        super.init(frame: .zero)
        title = state.displayName
        image = NSImage(systemSymbolName: state.symbolName, accessibilityDescription: nil)
        imagePosition = .imageLeading
        alignment = .left
        bezelStyle = .recessed
        setButtonType(.toggle)
        self.target = target
        self.action = action
        controlSize = .regular
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 38).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(count: Int, isEditing: Bool, isCurrent: Bool) {
        self.state = isEditing ? .on : .off
        let currentMarker = isCurrent ? "  •" : ""
        title = "\(petState.displayName)  \(count)\(currentMarker)"
        let editing = isEditing ? ", editing" : ""
        let current = isCurrent ? ", current lifecycle state" : ""
        setAccessibilityLabel("\(petState.displayName), \(count) clips\(editing)\(current)")
    }
}

private enum LibraryColumn {
    static let clip = NSUserInterfaceItemIdentifier("animation-library.clip")
    static let status = NSUserInterfaceItemIdentifier("animation-library.status")
    static let preview = NSUserInterfaceItemIdentifier("animation-library.preview")
    static let actions = NSUserInterfaceItemIdentifier("animation-library.actions")
    static let remove = NSUserInterfaceItemIdentifier("animation-library.remove")
}

private struct LibraryClipRowModel {
    let position: Int
    let entry: MediaEntry
    let name: String
    let exists: Bool
    let posterSummary: String
    let posterMissing: Bool
    let isFixed: Bool
    let isPreviewing: Bool
    let reduceMotion: Bool
    let busy: Bool

    var statusSummary: String {
        var attributes: [String] = []
        if isFixed { attributes.append("Fixed") }
        if isPreviewing { attributes.append("Previewing") }
        return attributes.isEmpty ? "Available" : attributes.joined(separator: " · ")
    }

    var previewDisabledReason: String? {
        if isPreviewing { return nil }
        if !exists { return "The movie file is missing." }
        if reduceMotion { return "Preview is unavailable while Reduce Motion is on." }
        if busy { return "Wait for the current media operation to finish." }
        return nil
    }

    var accessibilitySummary: String {
        let fixed = isFixed ? ", fixed clip" : ""
        let preview = isPreviewing ? ", previewing" : ""
        let poster = posterMissing ? ", poster file missing" : ", \(posterSummary.lowercased())"
        return "\(position), \(name), \(exists ? "ready" : "file missing")\(fixed)\(preview)\(poster)"
    }
}

private final class LibraryTextCell: NSTableCellView {
    private let primaryLabel = NSTextField(labelWithString: "")
    private let secondaryLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        primaryLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        primaryLabel.lineBreakMode = .byTruncatingMiddle
        primaryLabel.maximumNumberOfLines = 1
        secondaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        secondaryLabel.textColor = .secondaryLabelColor
        secondaryLabel.lineBreakMode = .byTruncatingTail
        secondaryLabel.maximumNumberOfLines = 1
        for label in [primaryLabel, secondaryLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            primaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            primaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            primaryLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            secondaryLabel.leadingAnchor.constraint(equalTo: primaryLabel.leadingAnchor),
            secondaryLabel.trailingAnchor.constraint(equalTo: primaryLabel.trailingAnchor),
            secondaryLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 1),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(
        primary: String,
        secondary: String,
        primaryColor: NSColor = .labelColor,
        secondaryColor: NSColor = .secondaryLabelColor,
        accessibilityLabel: String
    ) {
        primaryLabel.stringValue = primary
        primaryLabel.textColor = primaryColor
        secondaryLabel.stringValue = secondary
        secondaryLabel.textColor = secondaryColor
        setAccessibilityLabel(accessibilityLabel)
    }
}

private final class LibraryActionCell: NSTableCellView {
    let button: NSButton

    init(title: String, target: AnyObject, action: Selector) {
        button = NSButton(title: title, target: target, action: action)
        super.init(frame: .zero)
        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class MP4DropZoneView: NSView {
    var onImport: (([URL]) -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private var selectedState: PetState = .idle
    private var importEnabled = false
    private var busy = false
    private var isDragHighlighted = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        registerForDraggedTypes([.fileURL, .URL])
        iconView.image = NSImage(
            systemSymbolName: "square.and.arrow.down",
            accessibilityDescription: nil
        )
        iconView.contentTintColor = .secondaryLabelColor
        iconView.setAccessibilityElement(false)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .left
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        let contentStack = NSStackView(views: [iconView, textStack])
        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: AnimationLibraryLayout.importStripHeight),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        updatePresentation(resetMessage: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        let fillColor = isDragHighlighted
            ? NSColor.controlAccentColor.withAlphaComponent(0.12)
            : NSColor.controlBackgroundColor
        fillColor.setFill()
        path.fill()
        (isDragHighlighted ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isDragHighlighted ? 2 : 1
        path.setLineDash([6, 4], count: 2, phase: 0)
        path.stroke()
    }

    func update(selectedState: PetState, importEnabled: Bool, busy: Bool) {
        let shouldReset = self.selectedState != selectedState
            || self.importEnabled != importEnabled
            || self.busy != busy
        self.selectedState = selectedState
        self.importEnabled = importEnabled
        self.busy = busy
        updatePresentation(resetMessage: shouldReset)
    }

    private func updatePresentation(resetMessage: Bool) {
        titleLabel.stringValue = "Drop MP4s into \(selectedState.displayName)"
        if resetMessage {
            if busy {
                setDetailMessage("Import is disabled while the current media operation finishes.")
            } else if !importEnabled {
                setDetailMessage("Conversion tools must be ready before MP4s can be dropped.")
            } else {
                setDetailMessage(
                    "or choose Add Clip…",
                    accessibilityHelp: "Drop local MP4 files from Finder. Files are imported in their dropped order."
                )
            }
        }
        setAccessibilityLabel("Drop MP4s for \(selectedState.displayName) animations")
        alphaValue = importEnabled && !busy ? 1 : 0.65
        needsDisplay = true
    }

    private func setDetailMessage(_ message: String, accessibilityHelp: String? = nil) {
        detailLabel.stringValue = message
        detailLabel.toolTip = message
        toolTip = message
        setAccessibilityHelp(accessibilityHelp ?? message)
    }

    private func draggedURLs(from pasteboard: NSPasteboard) -> [URL]? {
        guard let values = pasteboard.readObjects(forClasses: [NSURL.self]) as? [NSURL], !values.isEmpty else {
            return nil
        }
        return values.map { $0 as URL }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard importEnabled, !busy else {
            setDetailMessage(
                busy
                    ? "Wait for the current media operation to finish."
                    : "Conversion tools are not ready."
            )
            return []
        }
        guard let urls = draggedURLs(from: sender.draggingPasteboard) else {
            setDetailMessage("Nothing imported: drop local MP4 files from Finder.")
            return []
        }
        isDragHighlighted = true
        switch MP4ImportURLValidator.validate(urls) {
        case let .accepted(accepted):
            setDetailMessage("Release to import \(accepted.count) MP4\(accepted.count == 1 ? "" : "s") into \(selectedState.displayName).")
            return .copy
        case let .rejected(reason):
            setDetailMessage("Nothing will be imported: \(reason)")
            return []
        }
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragHighlighted = false
        updatePresentation(resetMessage: true)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragHighlighted = false
        guard importEnabled, !busy, let urls = draggedURLs(from: sender.draggingPasteboard) else {
            setDetailMessage("Nothing imported: drop local MP4 files from Finder.")
            return false
        }
        switch MP4ImportURLValidator.validate(urls) {
        case let .accepted(accepted):
            setDetailMessage("Starting import of \(accepted.count) MP4\(accepted.count == 1 ? "" : "s") into \(selectedState.displayName)…")
            onImport?(accepted)
            return true
        case let .rejected(reason):
            setDetailMessage("Nothing imported: \(reason)")
            return false
        }
    }
}

final class AnimationLibraryView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onStateSelection: ((PetState) -> Void)?
    var onModeChange: ((MediaPlaybackMode) -> Void)?
    var onAdvanceTriggerChange: ((MediaPlaylistAdvancePolicy) -> Void)?
    var onImportMP4: (() -> Void)?
    var onDropMP4s: (([URL]) -> Void)?
    var onUseMovie: (() -> Void)?
    var onPlayOrStop: ((MediaEntry, Bool) -> Void)?
    var onMore: ((MediaEntry, NSButton) -> Void)?
    var onRemove: ((MediaEntry) -> Void)?

    private let stateButtons: [LibraryStateButton]
    private let stateTitle = NSTextField(labelWithString: "")
    private let stateDescription = NSTextField(wrappingLabelWithString: "")
    private let modeControl = NSSegmentedControl(labels: ["Fixed", "Random", "Sequential"], trackingMode: .selectOne, target: nil, action: nil)
    private let modeHelp = NSTextField(wrappingLabelWithString: "")
    private let continuousRotationCheckbox = NSButton(
        checkboxWithTitle: "Continue with another clip when this clip ends",
        target: nil,
        action: nil
    )
    private let addClip = NSPopUpButton()
    private let dropZone = MP4DropZoneView()
    private let clipsSectionTitle = NSTextField(labelWithString: "CLIPS")
    private let clipsCountLabel = NSTextField(labelWithString: "0 clips")
    private let tableView = NSTableView()
    private let clipsScrollView = NSScrollView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "No clips for this state. Add an MP4 to convert, or add a verified transparent MOV.")
    private let emptyAddButton = NSButton(title: "Add Clip…", target: nil, action: nil)
    private var clipRows: [LibraryClipRowModel] = []

    override init(frame frameRect: NSRect) {
        stateButtons = PetState.allCases.map { LibraryStateButton(state: $0, target: nil, action: #selector(selectState(_:))) }
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        resizeFlexibleClipColumn()
    }

    private func build() {
        for button in stateButtons { button.target = self }
        let sidebarTitle = NSTextField(labelWithString: "STATES")
        sidebarTitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        sidebarTitle.textColor = .secondaryLabelColor
        let sidebar = NSStackView(views: [sidebarTitle] + stateButtons)
        sidebar.orientation = .vertical
        sidebar.alignment = .width
        sidebar.spacing = 5
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        stateTitle.font = .systemFont(ofSize: 18, weight: .semibold)
        stateDescription.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stateDescription.textColor = .secondaryLabelColor
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.setAccessibilityLabel("Playback mode")
        modeHelp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        modeHelp.textColor = .secondaryLabelColor
        modeHelp.maximumNumberOfLines = 1
        modeHelp.lineBreakMode = .byTruncatingTail
        modeHelp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addClip.addItem(withTitle: "Add Clip…")
        addClip.menu?.addItem(.separator())
        continuousRotationCheckbox.target = self
        continuousRotationCheckbox.action = #selector(advanceTriggerChanged)
        continuousRotationCheckbox.setAccessibilityHelp("Random and Sequential modes can advance to another clip without waiting for the lifecycle state to change.")

        addClip.addItem(withTitle: "Import MP4s…")
        addClip.lastItem?.target = self
        addClip.lastItem?.action = #selector(importMP4)
        addClip.addItem(withTitle: "Verified MOVs…")
        addClip.lastItem?.target = self
        addClip.lastItem?.action = #selector(useMovie)
        addClip.setAccessibilityLabel("Add animation clip")
        dropZone.onImport = { [weak self] urls in self?.onDropMP4s?(urls) }

        let headerButtons = NSStackView(views: [modeControl, addClip])
        headerButtons.orientation = .horizontal
        headerButtons.alignment = .centerY
        headerButtons.spacing = 8
        let header = NSStackView(views: [stateTitle, headerButtons])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill

        clipsSectionTitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        clipsSectionTitle.textColor = .secondaryLabelColor
        clipsSectionTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)
        clipsCountLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        clipsCountLabel.textColor = .secondaryLabelColor
        clipsCountLabel.alignment = .right
        clipsCountLabel.setContentHuggingPriority(.required, for: .horizontal)
        let clipsHeader = NSStackView(views: [clipsSectionTitle, clipsCountLabel])
        clipsHeader.orientation = .horizontal
        clipsHeader.alignment = .centerY
        clipsHeader.distribution = .fill

        configureTable()

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyAddButton.target = self
        emptyAddButton.action = #selector(showEmptyAddMenu(_:))
        let emptyStack = NSStackView(views: [emptyLabel, emptyAddButton])
        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 10
        emptyStack.translatesAutoresizingMaskIntoConstraints = false

        let detail = NSView()
        detail.translatesAutoresizingMaskIntoConstraints = false
        for view in [header, stateDescription, modeHelp, continuousRotationCheckbox, dropZone, clipsHeader, clipsScrollView, emptyStack] { view.translatesAutoresizingMaskIntoConstraints = false; detail.addSubview(view) }
        let minimumClipListHeight = clipsScrollView.heightAnchor.constraint(
            greaterThanOrEqualToConstant: AnimationLibraryLayout.minimumClipListHeight
        )
        minimumClipListHeight.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: detail.topAnchor),
            header.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            stateDescription.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 3),
            stateDescription.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            stateDescription.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            modeHelp.topAnchor.constraint(equalTo: stateDescription.bottomAnchor, constant: 7),
            modeHelp.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            modeHelp.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            continuousRotationCheckbox.topAnchor.constraint(equalTo: modeHelp.bottomAnchor, constant: 6),
            continuousRotationCheckbox.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            continuousRotationCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: detail.trailingAnchor),
            dropZone.topAnchor.constraint(equalTo: continuousRotationCheckbox.bottomAnchor, constant: 8),
            dropZone.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            dropZone.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            clipsHeader.topAnchor.constraint(equalTo: dropZone.bottomAnchor, constant: 8),
            clipsHeader.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            clipsHeader.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            clipsScrollView.topAnchor.constraint(equalTo: clipsHeader.bottomAnchor, constant: 4),
            clipsScrollView.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            clipsScrollView.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            clipsScrollView.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
            minimumClipListHeight,
            emptyStack.centerXAnchor.constraint(equalTo: clipsScrollView.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: clipsScrollView.centerYAnchor),
            emptyStack.widthAnchor.constraint(lessThanOrEqualTo: clipsScrollView.widthAnchor, constant: -60),
        ])

        addSubview(sidebar)
        addSubview(detail)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 155),
            detail.topAnchor.constraint(equalTo: topAnchor),
            detail.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 16),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor),
            sidebar.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func configureTable() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 48
        tableView.intercellSpacing = NSSize(width: 4, height: 1)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.headerView = NSTableHeaderView()
        tableView.target = self
        tableView.doubleAction = #selector(previewSelectedClip)
        tableView.setAccessibilityLabel("Animation clips")
        tableView.setAccessibilityHelp("Use the arrow keys to select a clip. Double-click a row to preview it.")

        addColumn(identifier: LibraryColumn.clip, title: "Clip", width: 220, minimumWidth: 145, flexible: true)
        addColumn(identifier: LibraryColumn.status, title: "Status", width: 78, minimumWidth: 72)
        addColumn(identifier: LibraryColumn.preview, title: "Preview", width: 70, minimumWidth: 66)
        addColumn(identifier: LibraryColumn.actions, title: "Actions", width: 70, minimumWidth: 66)
        addColumn(identifier: LibraryColumn.remove, title: "Remove", width: 70, minimumWidth: 66)

        clipsScrollView.borderType = .bezelBorder
        clipsScrollView.hasVerticalScroller = true
        clipsScrollView.hasHorizontalScroller = true
        clipsScrollView.autohidesScrollers = true
        clipsScrollView.drawsBackground = true
        clipsScrollView.backgroundColor = .controlBackgroundColor
        clipsScrollView.documentView = tableView
        clipsScrollView.translatesAutoresizingMaskIntoConstraints = false
        clipsScrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        clipsScrollView.setContentCompressionResistancePriority(
            NSLayoutConstraint.Priority(999),
            for: .vertical
        )
    }

    private func addColumn(
        identifier: NSUserInterfaceItemIdentifier,
        title: String,
        width: CGFloat,
        minimumWidth: CGFloat,
        flexible: Bool = false
    ) {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = width
        column.minWidth = minimumWidth
        column.resizingMask = flexible ? [.autoresizingMask, .userResizingMask] : []
        tableView.addTableColumn(column)
    }

    private func resizeFlexibleClipColumn() {
        guard
            clipsScrollView.contentView.bounds.width > 0,
            let clipColumn = tableView.tableColumn(withIdentifier: LibraryColumn.clip)
        else { return }
        let fixedWidth = tableView.tableColumns
            .filter { $0 !== clipColumn }
            .reduce(CGFloat.zero) { $0 + $1.width }
        let spacingWidth = tableView.intercellSpacing.width * CGFloat(max(0, tableView.numberOfColumns - 1))
        let availableWidth = clipsScrollView.contentView.bounds.width - fixedWidth - spacingWidth - 2
        let desiredWidth = max(clipColumn.minWidth, availableWidth)
        if abs(clipColumn.width - desiredWidth) > 0.5 {
            clipColumn.width = desiredWidth
        }
    }

    func update(
        selectedState: PetState,
        currentState: PetState,
        playlist: StateMediaPlaylist?,
        counts: [PetState: Int],
        mapURL: URL,
        mediaMap: MediaMap,
        preview: SettingsPreviewMetadata?,
        reduceMotion: Bool,
        busy: Bool,
        importEnabled: Bool
    ) {
        for button in stateButtons {
            button.update(count: counts[button.petState, default: 0], isEditing: button.petState == selectedState, isCurrent: button.petState == currentState)
        }
        stateTitle.stringValue = "\(selectedState.displayName) Animations"
        stateTitle.setAccessibilityLabel("Editing \(selectedState.displayName) animations")
        stateDescription.stringValue = selectedState.explanation
        switch playlist?.mode ?? .fixed {
        case .fixed:
            modeControl.selectedSegment = 0
            modeHelp.stringValue = "Always use the fixed clip for this state. Continuous rotation is inactive in Fixed mode."
        case .random:
            modeControl.selectedSegment = 1
            modeHelp.stringValue = playlist?.advanceOn == .clipEnd
                ? "Choose at random when the state begins and after each clip ends, avoiding an immediate repeat when possible."
                : "Choose a clip at random when this state begins, avoiding an immediate repeat when possible."
        case .sequential:
            modeControl.selectedSegment = 2
            modeHelp.stringValue = playlist?.advanceOn == .clipEnd
                ? "Use clips in their listed order, continuing to the next clip whenever one ends."
                : "Use clips in their listed order each time this state begins."
        }
        modeHelp.toolTip = modeHelp.stringValue
        modeHelp.setAccessibilityHelp(modeHelp.stringValue)
        continuousRotationCheckbox.state = playlist?.advanceOn == .clipEnd ? .on : .off
        let canContinuouslyRotate = playlist?.mode != .fixed && (playlist?.entries.count ?? 0) > 1
        continuousRotationCheckbox.isEnabled = canContinuouslyRotate && !busy
        continuousRotationCheckbox.toolTip = canContinuouslyRotate
            ? "Advance after each clip ends while this lifecycle state remains active."
            : "Choose Random or Sequential and add at least two clips to enable continuous rotation."
        modeControl.isEnabled = playlist != nil && !busy
        addClip.isEnabled = !busy
        emptyAddButton.isEnabled = !busy
        addClip.item(at: 2)?.isEnabled = importEnabled && !busy
        dropZone.update(selectedState: selectedState, importEnabled: importEnabled, busy: busy)

        let selectedPath = selectedRowModel()?.entry.path
        clipRows = (playlist?.entries ?? []).enumerated().map { index, entry in
            let resolvedURL = mediaMap.resolvedURL(for: entry, relativeTo: mapURL)
            let resolvedPosterURL = mediaMap.resolvedPosterURL(for: entry, relativeTo: mapURL)
            let posterExists = resolvedPosterURL.map { FileManager.default.isReadableFile(atPath: $0.path) } ?? false
            return LibraryClipRowModel(
                position: index + 1,
                entry: entry,
                name: URL(fileURLWithPath: entry.path).lastPathComponent,
                exists: FileManager.default.isReadableFile(atPath: resolvedURL.path),
                posterSummary: entry.posterPath == nil ? "No poster" : (posterExists ? "Poster ready" : "Poster missing"),
                posterMissing: entry.posterPath != nil && !posterExists,
                isFixed: playlist?.fixedPath == entry.path,
                isPreviewing: preview?.state == selectedState && preview?.path == entry.path,
                reduceMotion: reduceMotion,
                busy: busy
            )
        }
        let clipNoun = clipRows.count == 1 ? "clip" : "clips"
        clipsCountLabel.stringValue = "\(clipRows.count) \(clipNoun)"
        clipsCountLabel.setAccessibilityLabel("\(clipRows.count) \(clipNoun) for \(selectedState.displayName)")
        tableView.setAccessibilityLabel("\(selectedState.displayName) animation clips")
        tableView.reloadData()
        if let selectedPath, let selectedIndex = clipRows.firstIndex(where: { $0.entry.path == selectedPath }) {
            tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        emptyLabel.superview?.isHidden = !(playlist?.entries.isEmpty ?? true)
        tableView.setAccessibilityHelp(
            clipRows.isEmpty
                ? "No clips are available for this state."
                : "\(clipRows.count) clips. Use the arrow keys to select a clip, or double-click a row to preview it."
        )
        resizeFlexibleClipColumn()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { clipRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < clipRows.count, let tableColumn else { return nil }
        let model = clipRows[row]
        switch tableColumn.identifier {
        case LibraryColumn.clip:
            let cell = reusableTextCell(identifier: LibraryColumn.clip)
            cell.update(
                primary: "\(model.position). \(model.name)",
                secondary: model.posterSummary,
                primaryColor: model.exists ? .labelColor : .systemRed,
                secondaryColor: model.posterMissing ? .systemRed : .secondaryLabelColor,
                accessibilityLabel: model.accessibilitySummary
            )
            return cell
        case LibraryColumn.status:
            let cell = reusableTextCell(identifier: LibraryColumn.status)
            cell.update(
                primary: model.exists ? "Ready" : "Missing",
                secondary: model.statusSummary,
                primaryColor: model.exists ? .labelColor : .systemRed,
                accessibilityLabel: "\(model.exists ? "Ready" : "File missing"), \(model.statusSummary)"
            )
            return cell
        case LibraryColumn.preview:
            let cell = reusableActionCell(
                identifier: LibraryColumn.preview,
                title: "Preview",
                action: #selector(playOnce(_:))
            )
            cell.button.title = model.isPreviewing ? "Stop" : "Preview"
            cell.button.isEnabled = model.isPreviewing || (model.exists && !model.reduceMotion && !model.busy)
            cell.button.toolTip = model.previewDisabledReason
            cell.button.setAccessibilityHelp(model.previewDisabledReason)
            cell.button.setAccessibilityLabel(model.isPreviewing ? "Stop preview of \(model.name)" : "Preview \(model.name)")
            return cell
        case LibraryColumn.actions:
            let cell = reusableActionCell(
                identifier: LibraryColumn.actions,
                title: "Actions…",
                action: #selector(showMore(_:))
            )
            cell.button.isEnabled = !model.busy
            cell.button.toolTip = "Set fixed clip, reorder, manage the poster, reveal, or relink."
            cell.button.setAccessibilityLabel("Actions for \(model.name)")
            return cell
        case LibraryColumn.remove:
            let cell = reusableActionCell(
                identifier: LibraryColumn.remove,
                title: "Remove…",
                action: #selector(removeClip(_:))
            )
            cell.button.isEnabled = !model.busy
            cell.button.toolTip = "Remove from this state or move managed converted files to Trash."
            cell.button.setAccessibilityLabel("Remove \(model.name)")
            cell.button.setAccessibilityHelp(
                "Remove this clip from the state, with an option to move managed converted files to Trash."
            )
            return cell
        default:
            return nil
        }
    }

    private func reusableTextCell(identifier: NSUserInterfaceItemIdentifier) -> LibraryTextCell {
        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? LibraryTextCell {
            return cell
        }
        let cell = LibraryTextCell()
        cell.identifier = identifier
        return cell
    }

    private func reusableActionCell(
        identifier: NSUserInterfaceItemIdentifier,
        title: String,
        action: Selector
    ) -> LibraryActionCell {
        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? LibraryActionCell {
            return cell
        }
        let cell = LibraryActionCell(title: title, target: self, action: action)
        cell.identifier = identifier
        return cell
    }

    private func rowModel(for sender: NSView) -> LibraryClipRowModel? {
        let row = tableView.row(for: sender)
        guard row >= 0, row < clipRows.count else { return nil }
        return clipRows[row]
    }

    private func selectedRowModel() -> LibraryClipRowModel? {
        guard tableView.selectedRow >= 0, tableView.selectedRow < clipRows.count else { return nil }
        return clipRows[tableView.selectedRow]
    }

    @objc private func selectState(_ sender: LibraryStateButton) { onStateSelection?(sender.petState) }

    @objc private func modeChanged() {
        let modes: [MediaPlaybackMode] = [.fixed, .random, .sequential]
        guard modeControl.selectedSegment >= 0 else { return }
        onModeChange?(modes[modeControl.selectedSegment])
    }

    @objc private func advanceTriggerChanged() {
        onAdvanceTriggerChange?(continuousRotationCheckbox.state == .on ? .clipEnd : .stateEntry)
    }

    @objc private func importMP4() { onImportMP4?() }
    @objc private func useMovie() { onUseMovie?() }

    @objc private func showEmptyAddMenu(_ sender: NSButton) {
        addClip.menu?.popUp(positioning: addClip.item(at: 2), at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func playOnce(_ sender: NSButton) {
        guard let model = rowModel(for: sender) else { return }
        onPlayOrStop?(model.entry, model.isPreviewing)
    }

    @objc private func showMore(_ sender: NSButton) {
        guard let model = rowModel(for: sender) else { return }
        onMore?(model.entry, sender)
    }

    @objc private func removeClip(_ sender: NSButton) {
        guard let model = rowModel(for: sender) else { return }
        onRemove?(model.entry)
    }

    @objc private func previewSelectedClip() {
        guard let model = selectedRowModel() else { return }
        if model.isPreviewing || (model.exists && !model.reduceMotion && !model.busy) {
            onPlayOrStop?(model.entry, model.isPreviewing)
        }
    }
}
