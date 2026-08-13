import AppKit
import CodexPetCore
import Darwin

private enum AnimationLibraryLayout {
    static let importStripHeight: CGFloat = 48
    static let minimumClipListHeight: CGFloat = 160
}

struct SettingsTransitionClip: Equatable {
    let source: PetState
    let destination: PetState
    let path: String
    let exists: Bool
    let position: Int
    let count: Int
    let mode: MediaPlaybackMode
    let isFixed: Bool
}

private struct SettingsTransitionPair: Hashable {
    let source: PetState
    let destination: PetState
}

private enum TransitionColumn {
    static let route = NSUserInterfaceItemIdentifier("animation-library.transition.route")
    static let clip = NSUserInterfaceItemIdentifier("animation-library.transition.clip")
    static let mode = NSUserInterfaceItemIdentifier("animation-library.transition.mode")
    static let fixed = NSUserInterfaceItemIdentifier("animation-library.transition.fixed")
    static let preview = NSUserInterfaceItemIdentifier("animation-library.transition.preview")
    static let add = NSUserInterfaceItemIdentifier("animation-library.transition.add")
    static let replace = NSUserInterfaceItemIdentifier("animation-library.transition.replace")
    static let reorder = NSUserInterfaceItemIdentifier("animation-library.transition.reorder")
    static let remove = NSUserInterfaceItemIdentifier("animation-library.transition.remove")
}

private struct SettingsTransitionRowModel {
    let pair: SettingsTransitionPair
    let clip: SettingsTransitionClip?
    let position: Int
    let count: Int
    let mode: MediaPlaybackMode
    let usesGlobalFallback: Bool

    var isPlaceholder: Bool { clip == nil }
}

enum MP4ImportURLValidation {
    case accepted([URL], rejected: [MP4ImportRejection])
    case rejected(String)
}

struct MP4ImportRejection: Equatable {
    let sourceURL: URL
    let reason: String
}

enum MP4ImportURLValidator {
    static func validate(_ sourceURLs: [URL], fileManager _: FileManager = .default) -> MP4ImportURLValidation {
        guard !sourceURLs.isEmpty else {
            return .rejected("No files were provided.")
        }
        var seenPaths: Set<String> = []
        var accepted: [URL] = []
        var rejections: [MP4ImportRejection] = []
        for sourceURL in sourceURLs {
            guard sourceURL.isFileURL, sourceURL.host.map({ $0.isEmpty || $0 == "localhost" }) ?? true else {
                rejections.append(
                    MP4ImportRejection(
                        sourceURL: sourceURL,
                        reason: "Only local MP4 files can be imported."
                    )
                )
                continue
            }
            let url = sourceURL.standardizedFileURL
            let name = url.lastPathComponent.isEmpty ? "That item" : url.lastPathComponent
            guard url.pathExtension.caseInsensitiveCompare("mp4") == .orderedSame else {
                rejections.append(
                    MP4ImportRejection(sourceURL: url, reason: "\(name) is not an MP4 file.")
                )
                continue
            }
            if let rejectionReason = rejectionReason(for: url, name: name) {
                rejections.append(MP4ImportRejection(sourceURL: url, reason: rejectionReason))
                continue
            }
            if seenPaths.insert(url.path).inserted {
                accepted.append(url)
            }
        }
        guard !accepted.isEmpty else {
            let reason = rejections.first?.reason ?? "No new MP4 files were provided."
            return .rejected(reason)
        }
        return .accepted(accepted, rejected: rejections)
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
    private var characterName = "Default"
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

    func update(selectedState: PetState, characterName: String, importEnabled: Bool, busy: Bool) {
        let shouldReset = self.selectedState != selectedState
            || self.characterName != characterName
            || self.importEnabled != importEnabled
            || self.busy != busy
        self.selectedState = selectedState
        self.characterName = characterName
        self.importEnabled = importEnabled
        self.busy = busy
        updatePresentation(resetMessage: shouldReset)
    }

    private func updatePresentation(resetMessage: Bool) {
        titleLabel.stringValue = "Drop MP4s into \(characterName) · \(selectedState.displayName)"
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
        setAccessibilityLabel("Drop MP4s for \(characterName), \(selectedState.displayName) animations")
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
        case let .accepted(accepted, rejected):
            let skipped = rejected.isEmpty ? "" : " · Skipped \(rejected.count) unsupported item\(rejected.count == 1 ? "" : "s")"
            setDetailMessage("Release to import \(accepted.count) MP4\(accepted.count == 1 ? "" : "s") into \(characterName) · \(selectedState.displayName)\(skipped).")
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
        case let .accepted(accepted, rejected):
            let skipped = rejected.isEmpty ? "" : " · Skipped \(rejected.count) unsupported item\(rejected.count == 1 ? "" : "s")"
            setDetailMessage("Starting import of \(accepted.count) MP4\(accepted.count == 1 ? "" : "s") into \(characterName) · \(selectedState.displayName)…\(skipped)")
            // Preserve the complete batch so the delegate can surface a
            // sanitized reason for every skipped item while still converting
            // the accepted MP4s.
            onImport?(urls)
            return true
        case let .rejected(reason):
            setDetailMessage("Nothing imported: \(reason)")
            return false
        }
    }
}

final class AnimationLibraryView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private struct RowUpdateKey: Equatable {
        let selectedState: PetState
        let characterName: String
        let playlist: StateMediaPlaylist?
        let mapURL: URL
        let selectedPreviewPath: String?
        let reduceMotion: Bool
        let busy: Bool
        let fileRevisions: [LocalFileRevision?]
    }
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
    private var lastRowUpdateKey: RowUpdateKey?

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

    func invalidateRowCache() {
        lastRowUpdateKey = nil
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
        stateTitle.maximumNumberOfLines = 1
        stateTitle.lineBreakMode = .byTruncatingTail
        stateTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        addClip.addItem(withTitle: "Portable MOVs…")
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
        importEnabled: Bool,
        characterName: String = "Default"
    ) {
        for button in stateButtons {
            button.update(count: counts[button.petState, default: 0], isEditing: button.petState == selectedState, isCurrent: button.petState == currentState)
        }
        stateTitle.stringValue = "\(characterName) · \(selectedState.displayName) Animations"
        stateTitle.setAccessibilityLabel("Editing \(characterName), \(selectedState.displayName) animations")
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
        dropZone.update(
            selectedState: selectedState,
            characterName: characterName,
            importEnabled: importEnabled,
            busy: busy
        )
        clipsSectionTitle.stringValue = "CLIPS"
        clipsSectionTitle.setAccessibilityLabel("Clips for \(characterName), \(selectedState.displayName)")
        emptyLabel.stringValue = "No \(selectedState.displayName.lowercased()) clips for \(characterName). Add an MP4 to convert, or add a verified transparent MOV."

        let resolvedEntries = (playlist?.entries ?? []).map { entry in
            (
                entry,
                mediaMap.resolvedURL(for: entry, relativeTo: mapURL),
                mediaMap.resolvedPosterURL(for: entry, relativeTo: mapURL)
            )
        }
        let watchedURLs = resolvedEntries.flatMap { _, movieURL, posterURL in
            [movieURL] + (posterURL.map { [$0] } ?? [])
        }
        let fileRevisions = watchedURLs.map(LocalFileRevision.init(url:))

        let rowUpdateKey = RowUpdateKey(
            selectedState: selectedState,
            characterName: characterName,
            playlist: playlist,
            mapURL: mapURL.standardizedFileURL,
            selectedPreviewPath: preview?.state == selectedState ? preview?.path : nil,
            reduceMotion: reduceMotion,
            busy: busy,
            fileRevisions: fileRevisions
        )
        guard LibraryRowRefreshPolicy.shouldRefresh(
            previous: lastRowUpdateKey,
            incoming: rowUpdateKey
        ) else { return }
        lastRowUpdateKey = rowUpdateKey

        let selectedPath = selectedRowModel()?.entry.path
        clipRows = resolvedEntries.enumerated().map { index, resolvedEntry in
            let (entry, resolvedURL, resolvedPosterURL) = resolvedEntry
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
        clipsCountLabel.setAccessibilityLabel("\(clipRows.count) \(clipNoun) for \(characterName), \(selectedState.displayName)")
        tableView.setAccessibilityLabel("\(characterName), \(selectedState.displayName) animation clips")
        tableView.reloadData()
        if let selectedPath, let selectedIndex = clipRows.firstIndex(where: { $0.entry.path == selectedPath }) {
            tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        emptyLabel.superview?.isHidden = !(playlist?.entries.isEmpty ?? true)
        tableView.setAccessibilityHelp(
            clipRows.isEmpty
                ? "No clips are available for \(characterName), \(selectedState.displayName)."
                : "\(clipRows.count) clips for \(characterName), \(selectedState.displayName). Use the arrow keys to select a clip, or double-click a row to preview it."
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

final class TransitionLibraryView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var onScopeChange: ((TransitionLibraryScope) -> Void)?
    var onImportMP4: ((PetState, PetState) -> Void)?
    var onUseMovie: ((PetState, PetState) -> Void)?
    var onReplaceMP4: ((PetState, PetState, String) -> Void)?
    var onReplaceMovie: ((PetState, PetState, String) -> Void)?
    var onPreviewOrStop: ((SettingsTransitionClip, Bool) -> Void)?
    var onRemove: ((SettingsTransitionClip) -> Void)?
    var onMove: ((PetState, PetState, String, Int) -> Void)?
    var onModeChange: ((PetState, PetState, MediaPlaybackMode) -> Void)?
    var onSetFixed: ((PetState, PetState, String) -> Void)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let scopeControl = NSSegmentedControl(
        labels: ["Character", "Global"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let guidance = NSTextField(
        wrappingLabelWithString: "Optional directional clips play once before the destination animation. Maximum duration: 4 seconds."
    )
    private var rows: [SettingsTransitionRowModel] = []
    private var previewPath: String?
    private var reduceMotion = false
    private var busy = false
    private var scope: TransitionLibraryScope = .character

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        let title = NSTextField(labelWithString: "LIFECYCLE TRANSITIONS")
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        title.textColor = .secondaryLabelColor
        guidance.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        guidance.textColor = .secondaryLabelColor
        guidance.maximumNumberOfLines = 2
        guidance.setAccessibilityLabel("Lifecycle transition guidance")
        scopeControl.selectedSegment = TransitionLibraryScope.allCases.firstIndex(of: .character) ?? 0
        scopeControl.target = self
        scopeControl.action = #selector(changeScope)
        scopeControl.setAccessibilityLabel("Transition library scope")
        scopeControl.setAccessibilityHelp("Choose whether to edit transitions for the active character or the global transition library.")
        let header = NSStackView(views: [title, scopeControl])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill
        header.spacing = 12

        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 42
        tableView.intercellSpacing = NSSize(width: 4, height: 1)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.headerView = NSTableHeaderView()
        tableView.setAccessibilityLabel("Directional lifecycle transitions")
        addColumn(identifier: TransitionColumn.route, title: "Direction", width: 138, minimumWidth: 120)
        addColumn(identifier: TransitionColumn.clip, title: "Variant", width: 170, minimumWidth: 120, flexible: true)
        addColumn(identifier: TransitionColumn.mode, title: "Selection", width: 104, minimumWidth: 96)
        addColumn(identifier: TransitionColumn.fixed, title: "Default", width: 68, minimumWidth: 64)
        addColumn(identifier: TransitionColumn.preview, title: "Preview", width: 70, minimumWidth: 66)
        addColumn(identifier: TransitionColumn.add, title: "Add", width: 72, minimumWidth: 68)
        addColumn(identifier: TransitionColumn.replace, title: "Replace", width: 82, minimumWidth: 76)
        addColumn(identifier: TransitionColumn.reorder, title: "Order", width: 92, minimumWidth: 86)
        addColumn(identifier: TransitionColumn.remove, title: "Remove", width: 70, minimumWidth: 66)

        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView

        for view in [header, guidance, scrollView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            guidance.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 5),
            guidance.leadingAnchor.constraint(equalTo: leadingAnchor),
            guidance.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: guidance.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
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

    func update(
        clips: [SettingsTransitionClip],
        globalFallbackRoutes: Set<StateTransitionKey>,
        previewPath: String?,
        reduceMotion: Bool,
        busy: Bool,
        characterName: String,
        scope: TransitionLibraryScope
    ) {
        let pairs = PetState.allCases.flatMap { source in
            PetState.allCases.compactMap { destination in
                source == destination ? nil : SettingsTransitionPair(source: source, destination: destination)
            }
        }
        let grouped = Dictionary(grouping: clips) {
            SettingsTransitionPair(source: $0.source, destination: $0.destination)
        }
        rows = pairs.flatMap { pair -> [SettingsTransitionRowModel] in
            let routeClips = (grouped[pair] ?? []).sorted { $0.position < $1.position }
            guard !routeClips.isEmpty else {
                let key = try? StateTransitionKey(from: pair.source, to: pair.destination)
                return [SettingsTransitionRowModel(
                    pair: pair,
                    clip: nil,
                    position: 0,
                    count: 0,
                    mode: .fixed,
                    usesGlobalFallback: scope == .character && key.map(globalFallbackRoutes.contains) == true
                )]
            }
            return routeClips.map {
                SettingsTransitionRowModel(
                    pair: pair,
                    clip: $0,
                    position: $0.position,
                    count: $0.count,
                    mode: $0.mode,
                    usesGlobalFallback: false
                )
            }
        }
        self.previewPath = previewPath
        self.reduceMotion = reduceMotion
        self.busy = busy
        self.scope = scope
        scopeControl.selectedSegment = TransitionLibraryScope.allCases.firstIndex(of: scope) ?? 0
        scopeControl.setAccessibilityValue(scope == .character ? "Character" : "Global")
        let libraryName = scope == .character ? characterName : "Global"
        guidance.stringValue = reduceMotion
            ? "Reduce Motion is on for \(libraryName) transitions. Video preview and playback are skipped; the destination fallback is presented."
            : "Optional directional clips for \(libraryName) play once before the destination animation. Maximum duration: 4 seconds."
        guidance.setAccessibilityHelp(guidance.stringValue)
        tableView.setAccessibilityLabel(scope == .character
            ? "\(characterName) directional lifecycle transitions"
            : "Global directional lifecycle transitions")
        tableView.reloadData()
    }

    @objc private func changeScope() {
        guard TransitionLibraryScope.allCases.indices.contains(scopeControl.selectedSegment) else { return }
        let selected = TransitionLibraryScope.allCases[scopeControl.selectedSegment]
        guard selected != scope else { return }
        scope = selected
        scopeControl.setAccessibilityValue(selected == .character ? "Character" : "Global")
        onScopeChange?(selected)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < rows.count, let tableColumn else { return nil }
        let model = rows[row]
        let pair = model.pair
        let clip = model.clip
        let filename = clip.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "Not configured"
        switch tableColumn.identifier {
        case TransitionColumn.route:
            let configurationStatus = clip.map { $0.exists ? "\($0.count) variants" : "Variant \($0.position + 1) missing" } ?? "No variants"
            return textCell(
                identifier: TransitionColumn.route,
                primary: "\(pair.source.displayName) → \(pair.destination.displayName)",
                secondary: configurationStatus,
                secondaryColor: clip?.exists == false ? .systemRed : .secondaryLabelColor,
                accessibilityLabel: "\(pair.source.displayName) to \(pair.destination.displayName), \(configurationStatus.lowercased())"
            )
        case TransitionColumn.clip:
            let clipStatus: String
            if clip == nil {
                clipStatus = model.usesGlobalFallback
                    ? "Using Global fallback"
                    : "Destination animation is used directly"
            } else if clip?.exists == false {
                clipStatus = "Movie file is missing"
            } else {
                clipStatus = "Plays once, then commits destination"
            }
            return textCell(
                identifier: TransitionColumn.clip,
                primary: clip.map { "\($0.position + 1). \(filename)" } ?? filename,
                secondary: clipStatus,
                primaryColor: clip?.exists == false ? .systemRed : .labelColor,
                secondaryColor: clip?.exists == false ? .systemRed : .secondaryLabelColor,
                accessibilityLabel: "\(filename), \(clipStatus.lowercased())"
            )
        case TransitionColumn.mode:
            let cell = actionCell(identifier: TransitionColumn.mode, title: model.mode.rawValue.capitalized, action: #selector(changeMode(_:)))
            cell.button.isEnabled = model.clip != nil && !busy
            cell.button.setAccessibilityLabel("Selection mode for \(pair.source.displayName) to \(pair.destination.displayName): \(model.mode.rawValue)")
            cell.button.toolTip = model.clip == nil
                ? "Add a transition variant before choosing a selection mode."
                : "Choose Fixed, Random, or Sequential selection for this route."
            return cell
        case TransitionColumn.fixed:
            let cell = actionCell(identifier: TransitionColumn.fixed, title: clip?.isFixed == true ? "Default" : "Set", action: #selector(setFixed(_:)))
            cell.button.isEnabled = clip != nil && clip?.isFixed == false && !busy
            cell.button.setAccessibilityLabel("\(clip?.isFixed == true ? "Default variant" : "Set as default") for \(pair.source.displayName) to \(pair.destination.displayName)")
            return cell
        case TransitionColumn.preview:
            let cell = actionCell(identifier: TransitionColumn.preview, title: "Preview", action: #selector(previewTransition(_:)))
            let isPreviewing = clip?.path == previewPath
            cell.button.title = isPreviewing ? "Stop" : "Preview"
            cell.button.isEnabled = isPreviewing || (clip?.exists == true && !reduceMotion && !busy)
            let disabledReason: String?
            if reduceMotion {
                disabledReason = "Preview is unavailable while Reduce Motion is on."
            } else if clip == nil {
                disabledReason = "Import a transition clip first."
            } else if clip?.exists == false {
                disabledReason = "The transition movie file is missing. Replace or remove it."
            } else {
                disabledReason = nil
            }
            cell.button.toolTip = disabledReason
            cell.button.setAccessibilityHelp(disabledReason)
            cell.button.setAccessibilityLabel("\(isPreviewing ? "Stop preview" : "Preview") \(pair.source.displayName) to \(pair.destination.displayName) transition")
            return cell
        case TransitionColumn.add:
            let cell = actionCell(identifier: TransitionColumn.add, title: "Add…", action: #selector(addVariants(_:)))
            cell.button.isEnabled = !busy
            cell.button.setAccessibilityLabel("Add variants for \(pair.source.displayName) to \(pair.destination.displayName)")
            cell.button.toolTip = "Import one or multiple MP4s, or add verified transparent MOVs."
            return cell
        case TransitionColumn.replace:
            let cell = actionCell(identifier: TransitionColumn.replace, title: "Replace…", action: #selector(replaceVariant(_:)))
            cell.button.isEnabled = clip != nil && !busy
            cell.button.setAccessibilityLabel("Replace variant \((clip?.position ?? 0) + 1) for \(pair.source.displayName) to \(pair.destination.displayName)")
            cell.button.toolTip = "Replace only this transition variant."
            return cell
        case TransitionColumn.reorder:
            let cell = actionCell(identifier: TransitionColumn.reorder, title: "Up / Down", action: #selector(showReorder(_:)))
            cell.button.isEnabled = clip != nil && model.count > 1 && !busy
            cell.button.setAccessibilityLabel("Move variant \(model.position + 1) for \(pair.source.displayName) to \(pair.destination.displayName)")
            return cell
        case TransitionColumn.remove:
            let cell = actionCell(identifier: TransitionColumn.remove, title: "Remove…", action: #selector(removeTransition(_:)))
            cell.button.isEnabled = clip != nil && !busy
            cell.button.setAccessibilityLabel("Remove \(pair.source.displayName) to \(pair.destination.displayName) transition")
            return cell
        default:
            return nil
        }
    }

    private func textCell(
        identifier: NSUserInterfaceItemIdentifier,
        primary: String,
        secondary: String,
        primaryColor: NSColor = .labelColor,
        secondaryColor: NSColor = .secondaryLabelColor,
        accessibilityLabel: String
    ) -> LibraryTextCell {
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? LibraryTextCell) ?? LibraryTextCell()
        cell.identifier = identifier
        cell.update(
            primary: primary,
            secondary: secondary,
            primaryColor: primaryColor,
            secondaryColor: secondaryColor,
            accessibilityLabel: accessibilityLabel
        )
        return cell
    }

    private func actionCell(identifier: NSUserInterfaceItemIdentifier, title: String, action: Selector) -> LibraryActionCell {
        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? LibraryActionCell {
            cell.button.title = title
            return cell
        }
        let cell = LibraryActionCell(title: title, target: self, action: action)
        cell.identifier = identifier
        return cell
    }

    private func rowModel(for sender: NSView) -> SettingsTransitionRowModel? {
        let row = tableView.row(for: sender)
        guard row >= 0, row < rows.count else { return nil }
        return rows[row]
    }

    @objc private func previewTransition(_ sender: NSButton) {
        guard let clip = rowModel(for: sender)?.clip else { return }
        onPreviewOrStop?(clip, clip.path == previewPath)
    }

    @objc private func addVariants(_ sender: NSButton) {
        guard rowModel(for: sender) != nil else { return }
        let menu = NSMenu()
        let mp4 = NSMenuItem(title: "Import MP4s…", action: #selector(importTransitionMP4(_:)), keyEquivalent: "")
        mp4.target = self
        mp4.representedObject = tableView.row(for: sender)
        menu.addItem(mp4)
        let movie = NSMenuItem(title: "Add Verified MOVs…", action: #selector(useTransitionMovie(_:)), keyEquivalent: "")
        movie.target = self
        movie.representedObject = tableView.row(for: sender)
        menu.addItem(movie)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func replaceVariant(_ sender: NSButton) {
        guard rowModel(for: sender)?.clip != nil else { return }
        let menu = NSMenu()
        let mp4 = NSMenuItem(title: "Replace with MP4…", action: #selector(importTransitionMP4(_:)), keyEquivalent: "")
        mp4.target = self
        mp4.representedObject = tableView.row(for: sender)
        menu.addItem(mp4)
        let movie = NSMenuItem(title: "Replace with Verified MOV…", action: #selector(useTransitionMovie(_:)), keyEquivalent: "")
        movie.target = self
        movie.representedObject = tableView.row(for: sender)
        menu.addItem(movie)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    private func representedRow(_ sender: NSMenuItem) -> SettingsTransitionRowModel? {
        guard let row = sender.representedObject as? Int, row >= 0, row < rows.count else { return nil }
        return rows[row]
    }

    @objc private func importTransitionMP4(_ sender: NSMenuItem) {
        guard let model = representedRow(sender) else { return }
        if sender.title.hasPrefix("Replace"), let clip = model.clip {
            onReplaceMP4?(model.pair.source, model.pair.destination, clip.path)
        } else {
            onImportMP4?(model.pair.source, model.pair.destination)
        }
    }

    @objc private func useTransitionMovie(_ sender: NSMenuItem) {
        guard let model = representedRow(sender) else { return }
        if sender.title.hasPrefix("Replace"), let clip = model.clip {
            onReplaceMovie?(model.pair.source, model.pair.destination, clip.path)
        } else {
            onUseMovie?(model.pair.source, model.pair.destination)
        }
    }

    @objc private func removeTransition(_ sender: NSButton) {
        guard let clip = rowModel(for: sender)?.clip else { return }
        onRemove?(clip)
    }

    @objc private func changeMode(_ sender: NSButton) {
        guard let model = rowModel(for: sender) else { return }
        let menu = NSMenu()
        for mode in MediaPlaybackMode.allCases {
            let item = NSMenuItem(title: mode.rawValue.capitalized, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.state = mode == model.mode ? .on : .off
            item.representedObject = [tableView.row(for: sender), MediaPlaybackMode.allCases.firstIndex(of: mode) ?? 0]
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [Int], values.count == 2,
              values[0] >= 0, values[0] < rows.count,
              values[1] >= 0, values[1] < MediaPlaybackMode.allCases.count else { return }
        let pair = rows[values[0]].pair
        onModeChange?(pair.source, pair.destination, MediaPlaybackMode.allCases[values[1]])
    }

    @objc private func setFixed(_ sender: NSButton) {
        guard let clip = rowModel(for: sender)?.clip else { return }
        onSetFixed?(clip.source, clip.destination, clip.path)
    }

    @objc private func showReorder(_ sender: NSButton) {
        guard let model = rowModel(for: sender), model.clip != nil else { return }
        let menu = NSMenu()
        for (title, index) in [("Move Up", model.position - 1), ("Move Down", model.position + 1)] {
            let item = NSMenuItem(title: title, action: #selector(moveTransition(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = index >= 0 && index < model.count
            item.representedObject = [tableView.row(for: sender), index]
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func moveTransition(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [Int], values.count == 2,
              values[0] >= 0, values[0] < rows.count,
              let clip = rows[values[0]].clip else { return }
        onMove?(clip.source, clip.destination, clip.path, values[1])
    }
}
