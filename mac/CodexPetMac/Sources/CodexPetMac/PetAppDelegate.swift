import AppKit
import AVFoundation
import CodexPetCore
import CryptoKit
import Darwin
import OSLog
import Security
import UniformTypeIdentifiers

private struct LaunchOptions {
    var mediaMapURL: URL
    var stateURL: URL
    var sessionActivityURL: URL
    var forcedState: PetState?
    var clickThroughOverride: Bool?
    var alwaysOnTopOverride: Bool?
    var openSettings: Bool

    static func parse(arguments: [String], fileManager: FileManager = .default) -> LaunchOptions {
        let support = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                StateletIdentity.applicationSupportRelativePath,
                isDirectory: true
            )
        let defaultMap = support.appendingPathComponent("media/media-map.json")
        let defaultState = support.appendingPathComponent("runtime/current_state.json")
        let defaultSessionActivity = support.appendingPathComponent("sessions/activity-v1.json")
        var options = LaunchOptions(
            mediaMapURL: defaultMap,
            stateURL: defaultState,
            sessionActivityURL: defaultSessionActivity,
            forcedState: nil,
            clickThroughOverride: nil,
            alwaysOnTopOverride: nil,
            openSettings: false
        )

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--media-map", "--state":
                guard index + 1 < arguments.count else { break }
                let url = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
                if argument == "--media-map" { options.mediaMapURL = url } else { options.stateURL = url }
                index += 1
            case "--session-activity":
                guard index + 1 < arguments.count else { break }
                options.sessionActivityURL = URL(
                    fileURLWithPath: arguments[index + 1]
                ).standardizedFileURL
                index += 1
            case "--force-state":
                guard index + 1 < arguments.count else { break }
                options.forcedState = PetState(rawValue: arguments[index + 1])
                index += 1
            case "--click-through":
                options.clickThroughOverride = true
            case "--no-click-through":
                options.clickThroughOverride = false
            case "--always-on-top":
                options.alwaysOnTopOverride = true
            case "--no-always-on-top":
                options.alwaysOnTopOverride = false
            case "--settings":
                options.openSettings = true
            default:
                break
            }
            index += 1
        }
        return options
    }
}

private enum PublisherHealth: String, Equatable {
    case unknown
    case live
    case stale
    case missing
    case corrupt
    case futureSkew = "future_skew"
    case manual

    var menuTitle: String {
        switch self {
        case .unknown: return "Publisher: Checking"
        case .live: return "Publisher: Live"
        case .stale: return "Publisher: Stale — showing idle"
        case .missing: return "Publisher: Missing — showing idle"
        case .corrupt: return "Publisher: Invalid — showing idle"
        case .futureSkew: return "Publisher: Clock skew — showing idle"
        case .manual: return "Publisher: Manual state"
        }
    }

    var accessibilitySummary: String {
        switch self {
        case .unknown: return "publisher status checking"
        case .live: return "publisher live"
        case .stale: return "publisher stale, safe idle fallback"
        case .missing: return "publisher missing, safe idle fallback"
        case .corrupt: return "publisher state invalid, safe idle fallback"
        case .futureSkew: return "publisher clock invalid, safe idle fallback"
        case .manual: return "manual state override"
        }
    }

    func menuTitle(temporaryPreviewActive: Bool) -> String {
        guard temporaryPreviewActive else { return menuTitle }
        switch self {
        case .stale: return "Publisher: Stale — temporary preview active"
        case .missing: return "Publisher: Missing — temporary preview active"
        case .corrupt: return "Publisher: Invalid — temporary preview active"
        case .futureSkew: return "Publisher: Clock skew — temporary preview active"
        case .unknown, .live, .manual: return menuTitle
        }
    }

    func accessibilitySummary(temporaryPreviewActive: Bool) -> String {
        guard temporaryPreviewActive else { return accessibilitySummary }
        switch self {
        case .stale: return "publisher stale, temporary preview active"
        case .missing: return "publisher missing, temporary preview active"
        case .corrupt: return "publisher state invalid, temporary preview active"
        case .futureSkew: return "publisher clock invalid, temporary preview active"
        case .unknown, .live, .manual: return accessibilitySummary
        }
    }

    var usesIdleFallback: Bool {
        switch self {
        case .stale, .missing, .corrupt, .futureSkew: return true
        case .unknown, .live, .manual: return false
        }
    }

    var badgeVisualStatus: PublisherBadgeVisualStatus {
        switch self {
        case .unknown: return .checking
        case .live: return .live
        case .manual: return .manual
        case .stale, .missing, .corrupt, .futureSkew: return .unavailable
        }
    }
}

private enum MediaMapLoadResult: Equatable {
    case playbackChanged
    case windowChanged
    case unchanged
    case failed

    var didChange: Bool {
        self == .playbackChanged || self == .windowChanged
    }
}

private struct VerifiedMovieCopy: Sendable {
    let directory: URL
    let movieURL: URL
    let reportURL: URL
    let relativePath: String
}

private struct VerifiedMovieInstall: Sendable {
    let directory: URL
    let movieURL: URL
    let reportURL: URL
    let relativePath: String
    let validation: VerifiedMovieValidation
}

private struct VerifiedMovieValidation: Sendable {
    let report: ValidatedAlphaConversionReport
    let movieIdentity: PortableMediaFileIdentity
    let reportIdentity: PortableMediaFileIdentity
    let durationSeconds: Double
}

private struct MP4ImportFailure {
    let name: String
    let reason: String
    let sourceURL: URL?
}

private struct FailedMP4Batch {
    let state: PetState
    let sourceURLs: [URL]
}

private struct ActiveConversionJournal: Codable {
    let state: String
    let characterID: String?
    let mediaMapBasename: String?
    let mediaMapSHA256: String?
    let outputBasename: String
    let reportBasename: String
    let invocationChallenge: String
    let transitionFrom: String?
    let transitionTo: String?
    let transitionScope: TransitionLibraryScope?
    let globalTransitionLibrarySHA256: String?

    init(
        state: String,
        characterID: String? = nil,
        mediaMapBasename: String? = nil,
        mediaMapSHA256: String? = nil,
        outputBasename: String,
        reportBasename: String,
        invocationChallenge: String,
        transitionFrom: String? = nil,
        transitionTo: String? = nil,
        transitionScope: TransitionLibraryScope? = nil,
        globalTransitionLibrarySHA256: String? = nil
    ) {
        self.state = state
        self.characterID = characterID
        self.mediaMapBasename = mediaMapBasename
        self.mediaMapSHA256 = mediaMapSHA256
        self.outputBasename = outputBasename
        self.reportBasename = reportBasename
        self.invocationChallenge = invocationChallenge
        self.transitionFrom = transitionFrom
        self.transitionTo = transitionTo
        self.transitionScope = transitionScope
        self.globalTransitionLibrarySHA256 = globalTransitionLibrarySHA256
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case characterID = "character_id"
        case mediaMapBasename = "media_map_basename"
        case mediaMapSHA256 = "media_map_sha256"
        case outputBasename
        case reportBasename
        case invocationChallenge
        case transitionFrom = "transition_from"
        case transitionTo = "transition_to"
        case transitionScope = "transition_scope"
        case globalTransitionLibrarySHA256 = "global_transition_library_sha256"
    }
}

enum ConversionRecoveryRoutePolicy {
    static func accepts(
        state: String,
        transitionFrom: String?,
        transitionTo: String?,
        transitionScope: TransitionLibraryScope?
    ) -> Bool {
        if transitionFrom == nil, transitionTo == nil { return true }
        guard let rawFrom = transitionFrom,
              let rawTo = transitionTo,
              let from = PetState(rawValue: rawFrom),
              let to = PetState(rawValue: rawTo),
              state == to.rawValue else { return false }
        return from != to || transitionScope == .character
    }
}

private struct RecoveryOwner {
    let entry: CharacterLibraryEntry
    let map: MediaMap
    let encodedData: Data
    let catalogEncodedData: Data?
    let isActive: Bool
}

private struct GlobalTransitionRecoveryOwner {
    let library: GlobalTransitionLibrary
    let encodedData: Data?
}

private enum ConversionRecoveryOwner {
    case character(RecoveryOwner)
    case global(GlobalTransitionRecoveryOwner)
}

private struct MP4ImportNotice {
    let name: String
    let messages: [String]
}

private struct ActiveOneShotPreview {
    let playback: OneShotPlayback
    let libraryState: PetState
    let transitionID: UInt64
}

private struct ActiveLifecycleTransition {
    let id: UInt64
    let source: PetState
    let destination: PetState
    let transitionEntry: MediaEntry
    let transitionURL: URL
    let destinationEntry: MediaEntry
    let destinationURL: URL
    let transitionScope: TransitionLibraryScope
    var transitionSelectionRequest: TransitionSelectionRequest?
    var destinationSelectionRequest: MediaSelectionRequest?
    let isInState: Bool
}

private struct PendingLifecycleTransitionAttestation {
    let id: UInt64
    let source: PetState
    let destination: PetState
    let transitionEntry: MediaEntry
    let transitionURL: URL
    let destinationEntry: MediaEntry
    let destinationURL: URL
    let transitionScope: TransitionLibraryScope
    var transitionSelectionRequest: TransitionSelectionRequest?
    var destinationSelectionRequest: MediaSelectionRequest?
    let isInState: Bool
}

private struct PendingInStateTransitionPrewarm {
    let baseTransitionID: UInt64
    let request: PendingLifecycleTransitionAttestation
}

private struct PendingMediaSelectionCommit {
    let transitionID: UInt64
    var request: MediaSelectionRequest
    let target: MediaSelectionCommitTarget
}

private enum MediaSelectionCommitTarget {
    case lifecycle
    case manualPreview
}

enum LifecycleTransitionCompletionDecision: Equatable {
    case commit(PetState)
    case ignore

    static func decide(
        callbackID: UInt64,
        currentSequence: UInt64,
        activeID: UInt64?,
        activeDestination: PetState?,
        authoritativeState: PetState,
        temporaryPreviewActive: Bool
    ) -> LifecycleTransitionCompletionDecision {
        guard callbackID == currentSequence,
              activeID == callbackID,
              let activeDestination,
              authoritativeState == activeDestination,
              !temporaryPreviewActive else { return .ignore }
        return .commit(activeDestination)
    }
}

enum LifecyclePresentationTrigger: Equatable {
    case authoritativeChange
    case initialPresentation
    case sameStateHeartbeat
    case forcedRefresh
    case playlistRotation
    case nextClip
    case playOnce
    case temporaryState
}

struct LifecycleTransitionPolicy {
    static func trigger(
        previousLifecycleState: PetState?,
        incomingState: PetState,
        forceRefresh: Bool
    ) -> LifecyclePresentationTrigger {
        if forceRefresh { return .forcedRefresh }
        guard let previousLifecycleState else { return .initialPresentation }
        return previousLifecycleState == incomingState
            ? .sameStateHeartbeat
            : .authoritativeChange
    }

    static func source(
        lastCommittedState: PetState?,
        incomingState: PetState,
        trigger: LifecyclePresentationTrigger,
        reduceMotion: Bool,
        hasConfiguredMedia: Bool
    ) -> PetState? {
        guard trigger == .authoritativeChange,
              !reduceMotion,
              hasConfiguredMedia,
              let lastCommittedState,
              lastCommittedState != incomingState else { return nil }
        return lastCommittedState
    }
}

enum InStateTransitionPolicy {
    static func shouldTrigger(
        trigger: LifecyclePresentationTrigger,
        reduceMotion: Bool,
        continuousRotation: Bool,
        temporaryPreviewActive: Bool
    ) -> Bool {
        trigger == .playlistRotation
            && !reduceMotion
            && continuousRotation
            && !temporaryPreviewActive
    }
}

enum StateDialogueAudioDisposition: Equatable {
    case pending
    case deferred
    case delivered
}

struct StateDialoguePresentation: Equatable {
    let id: UUID
    let state: PetState
    var lineID: UUID?
    var lineRevision: Int?
    var text: String?
    var audioDisposition: StateDialogueAudioDisposition

    mutating func recordAutomaticPlaybackStarted(_ line: DialogueLine) -> Bool {
        guard line.state == state else { return false }
        lineID = line.id
        lineRevision = line.revision
        text = line.text
        audioDisposition = .delivered
        return true
    }

    mutating func recordAutomaticPlaybackFinished(
        requestID: UUID,
        lineID finishedLineID: UUID,
        replacementLine: DialogueLine?
    ) -> StateDialogueFinishOutcome {
        guard id == requestID else {
            return audioDisposition == .delivered ? .ignored : .revealCurrent
        }
        guard lineID == finishedLineID else { return .ignored }
        guard replacementLine?.state == state || replacementLine == nil else { return .ignored }
        lineID = replacementLine?.id
        lineRevision = replacementLine?.revision
        text = replacementLine?.text
        audioDisposition = .pending
        return .updated
    }
}

enum StateDialogueFinishOutcome: Equatable {
    case updated
    case revealCurrent
    case ignored
}

private enum StatusMenuTag: Int {
    case state = 1
    case clickThrough = 2
    case publisherHealth = 3
    case stopOneShot = 4
    case nextClip = 5
    case temporaryState = 6
    case followCodex = 7
    case alwaysOnTop = 8
    case character = 9
}

final class PetAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, @unchecked Sendable {
    private static let healthCheckIntervalSeconds = 30
    private static let positionSaveDebounceMilliseconds = 300
    private static let portableCopyTimeoutSeconds: TimeInterval = 120
    private static let portableValidationTimeoutSeconds: TimeInterval = 30
    private static let transitionAttestationTimeoutSeconds: TimeInterval = 20
    private static let sessionActivityAcknowledgementKey = "Statelet.sessionActivityAcknowledgements.v1"
    private static let sessionActivityPanelSize = NSSize(width: 230, height: 150)

    private let logger = Logger(subsystem: StateletIdentity.bundleIdentifier, category: "app")
    private let freshnessPolicy = StateFreshnessPolicy.production
    private var options: LaunchOptions!
    private var mediaMap = try! MediaMap()
    private var mediaMapURL: URL!
    private var configuredMediaMapURL: URL!
    private var mediaMapEncodedData: Data?
    private var characterLibrary = CharacterLibrary.legacy
    private var characterLibraryEncodedData: Data?
    private var characterLibraryStorage: CharacterLibraryStorage!
    private var globalTransitionLibrary = try! GlobalTransitionLibrary()
    private var globalTransitionLibraryEncodedData: Data?
    private var characterClipCounts: [String: Int] = [:]
    private let characterMetadataQueue = DispatchQueue(
        label: "com.coke1120.Statelet.character-metadata",
        qos: .utility
    )
    private let lifecycleStateReader = LifecycleStateFileReader()
    private let sessionActivityReader = SessionActivityFileReader()
    private let codexDesktopActivator = CodexDesktopActivator()
    private var characterCountRefreshGeneration: UInt64 = 0
    private var panel: PetPanel!
    private var player: PetPlayerController!
    private var sessionActivityPanel: SessionActivityPanel!
    private var sessionActivityView: SessionActivityView!
    private var sessionActivityScrollContainer: SessionActivityScrollContainer!
    private var stateWatcher: StateDirectoryWatcher!
    private var sessionActivityWatcher: StateDirectoryWatcher!
    private var mapWatcher: StateDirectoryWatcher!
    private var characterLibraryWatcher: StateDirectoryWatcher!
    private var globalTransitionLibraryWatcher: StateDirectoryWatcher!
    private var healthCheckTimer: DispatchSourceTimer?
    private var positionSaveWorkItem: DispatchWorkItem?
    private var positionSaveGeneration: UInt64 = 0
    private var positionStore = PositionStore()
    private var statusItem: NSStatusItem!
    private var clickThrough = false
    private var currentState: PetState = .idle
    /// The newest decodable snapshot seen on disk, including a publication
    /// later rejected by freshness or monotonic ordering checks.
    private var lastPublishedSnapshot: CurrentState?
    /// The monotonic lifecycle publication accepted by the app. Transient
    /// missing/corrupt reads must not erase this rollback barrier.
    private var lastAcceptedPublishedSnapshot: CurrentState?
    private var lastPublicationRejectionReason: String?
    private var publicationRejectionReasons: [String: Int] = [:]
    private var transientStateReadRetry: DispatchWorkItem?
    private var sessionActivityReadRetry: DispatchWorkItem?
    private var sessionActivitySnapshot: SessionActivitySnapshot?
    private var sessionActivityTargets: [String: String] = [:]
    private var lastAcceptedSessionActivitySnapshot: SessionActivitySnapshot?
    private var sessionActivityAcknowledgementHistory: [String] = []
    private var sessionActivityExpandedByUser = false
    private var sessionActivityLayoutAvailable = true
    private var sessionActivityAppearance = try! SessionActivityPanelAppearance()
    private var sessionActivityUserOrigin: NSPoint?
    private var isPositioningSessionActivityPanel = false
    private var lastLifecycleStateForSelection: PetState?
    private var lastPresentedState: PetState?
    private var lastCommittedLifecycleState: PetState?
    private var pendingPresentationState: PetState?
    private var pendingLifecycleTransitionAttestation: PendingLifecycleTransitionAttestation?
    private var pendingLifecycleTransitionAttestationTask: Task<
        Result<CharacterTransitionRuntimeAttestation, Error>, Never
    >?
    private var pendingInStateTransitionPrewarm: PendingInStateTransitionPrewarm?
    private var pendingInStateTransitionPrewarmTask: Task<
        Result<CharacterTransitionRuntimeAttestation, Error>, Never
    >?
    private var activeLifecycleTransition: ActiveLifecycleTransition?
    private var pendingMediaSelectionCommit: PendingMediaSelectionCommit?
    private var stateDialoguePresentation: StateDialoguePresentation?
    private var publisherHealth: PublisherHealth = .unknown
    private var mapReadFailureReported = false
    private var reduceMotion = false
    private var transitionSequence: UInt64 = 0
    private var lastIssuedTransitionID: UInt64 = 0
    private var mediaSelectionCursor = MediaSelectionCursor()
    private var transitionSelectionCursorsByCharacterAndScope: [String: TransitionSelectionCursor] = [:]
    private var manualPreviewSelectionCursor = MediaSelectionCursor()
    private var temporaryStatePreviewPolicy = TemporaryStatePreviewPolicy()
    private var oneShotArbiter = OneShotPlaybackArbiter()
    private var activeOneShotPreview: ActiveOneShotPreview?
    private var settingsController: SettingsWindowController?
    private var updateCoordinator: StateletUpdateCoordinator?
    private var updateRecoveryBlocked = false
    private var dialogueVoiceCoordinator: DialogueVoiceCoordinator!
    private let toolchainDiscovery = AlphaToolchainDiscovery()
    private var toolchainState: AlphaToolchainState = .checking
    private let conversionCoordinator = AlphaConversionCoordinator()
    private var conversionProfile: AlphaConversionProfile = .fill
    private let launchAtLoginManager = LaunchAtLoginManager()
    private let diagnostics = PetDiagnostics()
    private let preferencesMigrationStatus: PreferencesMigration.Status
    private var cachedLaunchAtLoginStatus: LaunchAtLoginManager.Status?
    private var cachedDiagnosticsReport = "Open Diagnostics and choose Refresh to inspect this Mac."
    private var activeMP4BatchID: UUID?
    private var activeTransitionConversionID: UUID?
    private var activeTransitionConversionDestination: PetState?
    private var transitionConversionCancellationRequested = false
    private var lastFailedMP4Batch: FailedMP4Batch?
    private var lastConversionFailureDiagnostic: (code: String, stage: String)?

    private func reserveTransitionID() -> UInt64 {
        lastIssuedTransitionID &+= 1
        return lastIssuedTransitionID
    }

    private func beginTransition() -> UInt64 {
        let transitionID = reserveTransitionID()
        transitionSequence = transitionID
        return transitionID
    }

    private func transitionSelectionCursor(
        for scope: TransitionLibraryScope
    ) -> TransitionSelectionCursor {
        let cursorKey = scope == .global
            ? "global"
            : "\(characterLibrary.activeCharacterID):\(scope.rawValue)"
        return transitionSelectionCursorsByCharacterAndScope[
            cursorKey,
            default: TransitionSelectionCursor()
        ]
    }

    private func setTransitionSelectionCursor(
        _ cursor: TransitionSelectionCursor,
        for scope: TransitionLibraryScope
    ) {
        let cursorKey = scope == .global
            ? "global"
            : "\(characterLibrary.activeCharacterID):\(scope.rawValue)"
        transitionSelectionCursorsByCharacterAndScope[
            cursorKey
        ] = cursor
    }
    private var pendingRecoveryNotice: (PetState, String)?
    private var mp4BatchCancellationRequested = false
    private var mediaMapReloadDeferred = false
    private var characterLibraryReloadDeferred = false
    private var globalTransitionLibraryReloadDeferred = false
    private var pendingCharacterBundleOpenURL: URL?
    private var mediaMutationInProgress = false {
        didSet {
            if oldValue, !mediaMutationInProgress {
                applyDeferredMediaMapReloadIfNeeded()
                applyDeferredCharacterLibraryReloadIfNeeded()
                applyDeferredGlobalTransitionLibraryReloadIfNeeded()
                processPendingCharacterBundleOpenIfPossible()
            }
        }
    }

    init(preferencesMigrationStatus: PreferencesMigration.Status = .notRun) {
        self.preferencesMigrationStatus = preferencesMigrationStatus
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        conversionProfile = AlphaConversionProfile.restored()
        options = LaunchOptions.parse(arguments: CommandLine.arguments)
        loadSessionActivityAcknowledgements()
        sessionActivityAppearance = SessionActivityPanelAppearanceStore.restored()
        sessionActivityUserOrigin = SessionActivityPanelPositionStore.restored()
        do {
            try StateletUpdateInstaller.reconcilePendingTransaction()
        } catch {
            updateRecoveryBlocked = true
            logger.error("event=update_transaction_recovery_failed action=retain_journal")
        }
        if !updateRecoveryBlocked {
            let updater = StateletUpdateCoordinator(
                installer: { downloaded, _ in
                    try StateletUpdateInstaller.install(downloaded)
                }
            )
            updater.onSnapshot = { [weak self] snapshot in
                self?.settingsController?.update(update: snapshot)
            }
            updateCoordinator = updater
            updater.startAutomaticChecks()
        }
        configuredMediaMapURL = options.mediaMapURL
        configureCharacterLibrary()
        loadMediaMap()
        loadGlobalTransitionLibrary()
        dialogueVoiceCoordinator = DialogueVoiceCoordinator()
        dialogueVoiceCoordinator.onChange = { [weak self] snapshot in
            guard let self else { return }
            self.settingsController?.update(dialogueVoice: snapshot)
            self.refreshStateOwnedDialogue(using: snapshot)
        }
        dialogueVoiceCoordinator.onAutomaticPlaybackStarted = { [weak self] requestID, line in
            self?.markStateOwnedDialogueAudioDelivered(requestID: requestID, line: line)
        }
        dialogueVoiceCoordinator.onAutomaticPlaybackFinished = { [weak self] requestID, lineID in
            self?.finishStateOwnedDialogueAudio(requestID: requestID, lineID: lineID)
        }
        dialogueVoiceCoordinator.start()
        refreshCharacterClipCounts()

        let configuredWindow = mediaMap.window
        let size = NSSize(width: configuredWindow.width, height: configuredWindow.height)
        let initialFrame: NSRect
        if let storedFrame = positionStore.frame(for: NSScreen.main) {
            initialFrame = WindowFramePolicy.applyingConfiguredSize(size, to: storedFrame)
        } else {
            initialFrame = WindowFramePolicy.centeredFrame(
                in: NSScreen.main?.visibleFrame ?? .zero,
                size: size
            )
        }
        panel = PetPanel(
            contentRect: positionStore.clampedFrame(initialFrame),
            alwaysOnTop: options.alwaysOnTopOverride ?? configuredWindow.alwaysOnTop,
            fullScreenAuxiliary: configuredWindow.fullScreenAuxiliary
        )
        panel.delegate = self
        panel.contentView = PetPlayerView(frame: panel.contentRect(forFrameRect: panel.frame))
        player = PetPlayerController(view: panel.contentView as! PetPlayerView)
        player.applyAppearance(configuredWindow.appearance)
        player.onPresentationEvent = { [weak self] transitionID, state, event in
            self?.handlePresentationEvent(transitionID: transitionID, state: state, event: event)
        }
        player.onOneShotEnded = { [weak self] transitionID in
            self?.finishOneShotPreview(transitionID: transitionID, reason: "completed")
        }
        player.onPlaylistClipApproachingEnd = { [weak self] transitionID, state in
            self?.beginInStateTransitionPrewarm(
                baseTransitionID: transitionID,
                state: state
            ) ?? false
        }
        player.onPlaylistClipEnded = { [weak self] transitionID, state in
            self?.advancePlaylistAfterClipEnd(transitionID: transitionID, state: state)
        }
        player.onPreparedLifecycleTransitionActivation = {
            [weak self] transitionID, baseTransitionID, state in
            self?.activateInStateTransitionPrewarm(
                transitionID: transitionID,
                baseTransitionID: baseTransitionID,
                state: state
            ) ?? false
        }
        player.onLifecycleTransitionEnded = { [weak self] transitionID in
            self?.finishLifecycleTransition(transitionID: transitionID, outcome: "completed")
        }
        player.onLifecycleTransitionFailed = { [weak self] transitionID in
            self?.handleLifecycleTransitionFailure(transitionID: transitionID)
        }
        player.view.onAdvanceClip = { [weak self] in
            self?.advanceCurrentClip(reason: "pet_button")
        }
        player.view.onPetClick = { [weak self] in
            self?.advanceCurrentClip(reason: "pet_click")
        }
        player.view.onResizeEnded = { [weak self] size in
            self?.persistUserResizedWindow(size: size)
        }
        player.view.onTemporaryStateSelection = { [weak self] state in
            self?.selectTemporaryState(state, reason: "pet_button")
        }
        sessionActivityView = SessionActivityView(
            frame: NSRect(origin: .zero, size: Self.sessionActivityPanelSize)
        )
        sessionActivityView.applyAppearance(sessionActivityAppearance)
        sessionActivityView.onAcknowledge = { [weak self] id in
            self?.acknowledgeSessionActivity(id)
        }
        sessionActivityView.onOpen = { [weak self] id in
            self?.openSessionActivity(id)
        }
        sessionActivityView.onExpand = { [weak self] in
            self?.expandSessionActivityPanel()
        }
        sessionActivityPanel = SessionActivityPanel(
            contentRect: SessionActivityPanel.anchoredFrame(
                beside: panel.frame,
                contentSize: Self.sessionActivityPanelSize,
                visibleFrame: NSScreen.main?.visibleFrame ?? panel.frame
            ),
            alwaysOnTop: effectiveAlwaysOnTop,
            fullScreenAuxiliary: configuredWindow.fullScreenAuxiliary
        )
        sessionActivityPanel.delegate = self
        sessionActivityScrollContainer = SessionActivityScrollContainer(
            activityView: sessionActivityView
        )
        sessionActivityPanel.contentView = sessionActivityScrollContainer
        sessionActivityPanel.ignoresMouseEvents = clickThrough
        sessionActivityPanel.orderFront(nil)
        refreshSessionActivityPresentation()
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        player.setReduceMotion(reduceMotion)
        clickThrough = options.clickThroughOverride ?? configuredWindow.clickThrough
        panel.ignoresMouseEvents = clickThrough
        sessionActivityPanel.ignoresMouseEvents = clickThrough
        sessionActivityPanel.isMovableByWindowBackground = !clickThrough
        positionSessionActivityPanel()
        if effectiveAlwaysOnTop {
            panel.orderFrontRegardless()
        } else {
            panel.orderFront(nil)
        }
        updateWindowOcclusionSuspension()

        installStatusItem()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screensDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        if let forcedState = options.forcedState {
            setPublisherHealth(.manual)
            apply(state: forcedState)
        } else {
            installWatchers()
            // Close the startup race between the pre-window load and each
            // watcher's initial identity snapshot.
            handleCharacterLibraryReloadRequest()
            if loadMediaMap().didChange {
                applyConfiguredWindowSize()
            }
            handleGlobalTransitionLibraryReloadRequest()
            readState(from: options.stateURL)
            readSessionActivity(from: options.sessionActivityURL)
            installHealthCheckTimer()
        }
        if options.openSettings {
            DispatchQueue.main.async { [weak self] in self?.showSettings() }
        }
        recoverInterruptedConversionIfPresent()
        DispatchQueue.main.async { [weak self] in
            self?.processPendingCharacterBundleOpenIfPossible()
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let bundles = filenames.map { URL(fileURLWithPath: $0).standardizedFileURL }.filter {
            $0.pathExtension.caseInsensitiveCompare("statelet-character") == .orderedSame
        }
        guard bundles.count == 1, pendingCharacterBundleOpenURL == nil else {
            sender.reply(toOpenOrPrint: .failure)
            return
        }
        pendingCharacterBundleOpenURL = bundles[0]
        sender.reply(toOpenOrPrint: .success)
        processPendingCharacterBundleOpenIfPossible()
    }

    func applicationWillTerminate(_ notification: Notification) {
        transientStateReadRetry?.cancel()
        transientStateReadRetry = nil
        sessionActivityReadRetry?.cancel()
        sessionActivityReadRetry = nil
        pendingLifecycleTransitionAttestationTask?.cancel()
        pendingLifecycleTransitionAttestationTask = nil
        pendingLifecycleTransitionAttestation = nil
        pendingInStateTransitionPrewarmTask?.cancel()
        pendingInStateTransitionPrewarmTask = nil
        pendingInStateTransitionPrewarm = nil
        stateWatcher?.stop()
        sessionActivityWatcher?.stop()
        mapWatcher?.stop()
        characterLibraryWatcher?.stop()
        globalTransitionLibraryWatcher?.stop()
        healthCheckTimer?.cancel()
        healthCheckTimer = nil
        positionSaveGeneration &+= 1
        positionSaveWorkItem?.cancel()
        positionSaveWorkItem = nil
        let playerQuiescent = player?.shutdownForTermination() ?? true
        let conversionQuiescent = conversionCoordinator.terminateAndWait()
        let voiceQuiescent = dialogueVoiceCoordinator?.shutdownAndWaitForQuiescence() ?? true
        let updateCheckQuiescent = updateCoordinator?.shutdownAndWaitForQuiescence() ?? true
        let updaterWorkQuiescent = playerQuiescent
            && conversionQuiescent
            && voiceQuiescent
            && updateCheckQuiescent
        do {
            if let candidate = try updateCoordinator?.commitScheduledUpdateAtTermination(
                ifQuiescent: updaterWorkQuiescent
            ) {
                logger.info("event=update_committed_at_termination version=\(candidate.version.description, privacy: .public)")
            } else if !updaterWorkQuiescent,
                      updateCoordinator?.snapshot.isScheduledForRestart == true {
                logger.error("event=update_commit_skipped reason=work_not_quiescent action=retain_current_app")
            }
        } catch {
            logger.error("event=update_commit_failed action=retain_current_or_recover_on_launch")
        }
        updateCoordinator?.discardPreparedUpdateAtTermination()
        savePanelFrame()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func windowDidMove(_ notification: Notification) {
        if let movedWindow = notification.object as? NSWindow,
           movedWindow === sessionActivityPanel {
            guard !isPositioningSessionActivityPanel else { return }
            sessionActivityUserOrigin = movedWindow.frame.origin
            SessionActivityPanelPositionStore.persist(movedWindow.frame.origin)
            positionSessionActivityPanel()
            return
        }
        schedulePositionSave()
        positionSessionActivityPanel()
    }
    func windowDidResize(_ notification: Notification) {
        if let resizedWindow = notification.object as? NSWindow,
           resizedWindow === sessionActivityPanel {
            positionSessionActivityPanel()
            return
        }
        schedulePositionSave()
        positionSessionActivityPanel()
    }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        updateWindowOcclusionSuspension()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    @objc private func screenParametersChanged() {
        guard let panel else { return }
        panel.setFrame(positionStore.clampedFrame(panel.frame), display: false)
        positionSessionActivityPanel()
        savePanelFrame()
    }

    @objc private func accessibilityDisplayOptionsChanged() {
        let newValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let motionChanged = newValue != reduceMotion
        if motionChanged {
            reduceMotion = newValue
            player?.setReduceMotion(reduceMotion)
            apply(state: currentState, forceRefresh: true)
        }
        player?.applyAppearance(mediaMap.window.appearance)
        sessionActivityView?.applyAppearance(sessionActivityAppearance)
        refreshSettings()
    }

    @objc private func screensDidSleep() {
        player?.setSuspended(true, for: .screenAsleep)
    }

    @objc private func screensDidWake() {
        for step in DisplayWakeRecoveryPolicy.steps {
            switch step {
            case .clearWindowOcclusion:
                player?.setSuspended(false, for: .windowOccluded)
            case .clearScreenSleep:
                player?.setSuspended(false, for: .screenAsleep)
            case .recheckWindowOcclusion:
                DispatchQueue.main.async { [weak self] in
                    self?.updateWindowOcclusionSuspension()
                }
            }
        }
    }

    private func updateWindowOcclusionSuspension() {
        guard let panel else { return }
        player?.setSuspended(
            !panel.occlusionState.contains(.visible),
            for: .windowOccluded
        )
    }

    private func installWatchers() {
        guard options.forcedState == nil else { return }
        stateWatcher = StateDirectoryWatcher(fileURL: options.stateURL)
        stateWatcher.start(emitInitial: false) { [weak self] url in self?.readState(from: url) }
        sessionActivityWatcher = StateDirectoryWatcher(fileURL: options.sessionActivityURL)
        sessionActivityWatcher.start(emitInitial: false) { [weak self] url in
            self?.readSessionActivity(from: url)
        }
        installMapWatcher()
        characterLibraryWatcher = StateDirectoryWatcher(fileURL: characterLibraryStorage.catalogURL)
        characterLibraryWatcher.start(emitInitial: false) { [weak self] _ in
            self?.handleCharacterLibraryReloadRequest()
        }
        globalTransitionLibraryWatcher = StateDirectoryWatcher(
            fileURL: characterLibraryStorage.globalTransitionLibraryURL
        )
        globalTransitionLibraryWatcher.start(emitInitial: false) { [weak self] _ in
            self?.handleGlobalTransitionLibraryReloadRequest()
        }
    }

    private func installMapWatcher() {
        mapWatcher?.stop()
        mapWatcher = StateDirectoryWatcher(fileURL: mediaMapURL)
        mapWatcher.start(emitInitial: false) { [weak self] _ in
            self?.handleMediaMapReloadRequest()
        }
    }

    private func installHealthCheckTimer() {
        guard healthCheckTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + .seconds(Self.healthCheckIntervalSeconds),
            repeating: .seconds(Self.healthCheckIntervalSeconds),
            leeway: .seconds(5)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // The same low-frequency timer covers in-place map edits that may
            // not produce a containing-directory event.
            self.handleMediaMapReloadRequest()
            self.handleCharacterLibraryReloadRequest()
            self.handleGlobalTransitionLibraryReloadRequest()
            self.readState(from: self.options.stateURL)
            self.readSessionActivity(from: self.options.sessionActivityURL)
        }
        healthCheckTimer = timer
        timer.resume()
    }

    private func handleMediaMapReloadRequest() {
        guard !mediaMutationInProgress else {
            mediaMapReloadDeferred = true
            return
        }
        let result = loadMediaMap()
        guard result != .failed else { return }
        if result.didChange {
            applyConfiguredWindowSize()
        }
        if result == .playbackChanged {
            apply(state: currentState, forceRefresh: true)
        } else if result == .windowChanged {
            updateStatusMenu()
            refreshSettings()
        }
    }

    private func applyDeferredMediaMapReloadIfNeeded() {
        guard mediaMapReloadDeferred else { return }
        mediaMapReloadDeferred = false
        handleMediaMapReloadRequest()
    }

    private func configureCharacterLibrary() {
        characterLibraryStorage = CharacterLibraryStorage(mediaMapURL: configuredMediaMapURL)
        do {
            let snapshot = try characterLibraryStorage.loadCatalog()
            characterLibrary = snapshot.library
            characterLibraryEncodedData = snapshot.encodedData
        } catch {
            characterLibrary = (try? CharacterLibrary.legacy(
                mapPath: configuredMediaMapURL.lastPathComponent
            )) ?? .legacy
            characterLibraryEncodedData = nil
            logger.error("event=character_library_load_failed action=use_legacy_profile")
        }
        mediaMapURL = characterLibrary.activeCharacter.resolvedMapURL(
            relativeTo: configuredMediaMapURL
        )
    }

    private func handleCharacterLibraryReloadRequest() {
        guard !mediaMutationInProgress else {
            characterLibraryReloadDeferred = true
            return
        }
        do {
            let snapshot = try characterLibraryStorage.loadCatalog()
            guard snapshot.encodedData != characterLibraryEncodedData else { return }
            let activeMapChanged = snapshot.library.activeCharacterID != characterLibrary.activeCharacterID
                || snapshot.library.activeCharacter.mapPath != characterLibrary.activeCharacter.mapPath
            if activeMapChanged {
                let entry = snapshot.library.activeCharacter
                let loaded = try characterLibraryStorage.loadMediaMap(for: entry)
                characterLibrary = snapshot.library
                characterLibraryEncodedData = snapshot.encodedData
                activateCharacter(entry: entry, map: loaded.map, encodedData: loaded.encodedData)
                refreshCharacterClipCounts()
            } else {
                characterLibrary = snapshot.library
                characterLibraryEncodedData = snapshot.encodedData
                refreshCharacterClipCounts()
                updateStatusMenu()
                refreshSettings()
            }
        } catch {
            logger.error("event=character_library_reload_failed action=retain_current")
        }
    }

    private func applyDeferredCharacterLibraryReloadIfNeeded() {
        guard characterLibraryReloadDeferred else { return }
        characterLibraryReloadDeferred = false
        handleCharacterLibraryReloadRequest()
    }

    private func handleGlobalTransitionLibraryReloadRequest() {
        guard !mediaMutationInProgress else {
            globalTransitionLibraryReloadDeferred = true
            return
        }
        let previous = globalTransitionLibrary
        guard loadGlobalTransitionLibrary() else { return }
        if previous != globalTransitionLibrary {
            apply(state: currentState, forceRefresh: true)
        } else {
            refreshSettings()
        }
    }

    private func applyDeferredGlobalTransitionLibraryReloadIfNeeded() {
        guard globalTransitionLibraryReloadDeferred else { return }
        globalTransitionLibraryReloadDeferred = false
        handleGlobalTransitionLibraryReloadRequest()
    }

    @discardableResult
    private func loadGlobalTransitionLibrary() -> Bool {
        do {
            let loaded = try characterLibraryStorage.loadGlobalTransitionLibrary()
            globalTransitionLibrary = loaded.library
            globalTransitionLibraryEncodedData = loaded.encodedData
            return true
        } catch {
            logger.error("event=global_transition_library_load_failed action=retain_previous_or_empty")
            return false
        }
    }

    @discardableResult
    private func loadMediaMap() -> MediaMapLoadResult {
        do {
            let loaded = try characterLibraryStorage.loadMediaMap(
                for: characterLibrary.activeCharacter
            )
            let decoded = loaded.map
            let impact = MediaMapChangeImpact.decide(previous: mediaMap, incoming: decoded)
            mediaMap = decoded
            mediaMapEncodedData = loaded.encodedData
            characterClipCounts[characterLibrary.activeCharacterID] = totalClipCount(in: decoded)
            mapReadFailureReported = false
            switch impact {
            case .unchanged: return .unchanged
            case .windowOnly: return .windowChanged
            case .playback: return .playbackChanged
            }
        } catch {
            if !mapReadFailureReported {
                logger.error("event=media_map_load_failed action=retain_previous_or_defaults")
                mapReadFailureReported = true
            }
            return .failed
        }
    }

    private func activateCharacter(
        entry: CharacterLibraryEntry,
        map: MediaMap,
        encodedData: Data
    ) {
        cancelActiveLifecycleTransition(reason: "character_changed")
        cancelActiveOneShotWithoutRestore(reason: "character_changed")
        _ = temporaryStatePreviewPolicy.cancel()
        mediaSelectionCursor = MediaSelectionCursor()
        manualPreviewSelectionCursor = MediaSelectionCursor()
        lastLifecycleStateForSelection = nil
        lastPresentedState = nil
        lastCommittedLifecycleState = nil
        pendingPresentationState = nil
        mediaMapURL = entry.resolvedMapURL(relativeTo: configuredMediaMapURL)
        mediaMap = map
        mediaMapEncodedData = encodedData
        characterClipCounts[entry.id] = totalClipCount(in: map)
        if options.forcedState == nil {
            installMapWatcher()
            // Close the same load-to-watch race as startup: if another writer
            // replaced the selected map between validation and registration,
            // prefer the newly stable bytes before presenting the character.
            _ = loadMediaMap()
        }
        applyConfiguredWindowSize()
        apply(state: currentState, forceRefresh: true)
        updateStatusMenu()
        refreshSettings()
    }

    private func refreshCharacterClipCounts() {
        characterCountRefreshGeneration &+= 1
        let generation = characterCountRefreshGeneration
        let librarySnapshot = characterLibrary
        let rootMapURL = configuredMediaMapURL!
        characterClipCounts = characterClipCounts.filter { id, _ in
            librarySnapshot.character(id: id) != nil
        }
        characterClipCounts[librarySnapshot.activeCharacterID] = totalClipCount(in: mediaMap)
        characterMetadataQueue.async { [weak self] in
            let storage = CharacterLibraryStorage(mediaMapURL: rootMapURL)
            var counts: [String: Int] = [:]
            for entry in librarySnapshot.characters where entry.id != librarySnapshot.activeCharacterID {
                counts[entry.id] = autoreleasepool {
                    guard let loaded = try? storage.loadMediaMap(for: entry) else { return 0 }
                    return loaded.map.states.values.reduce(0) { $0 + $1.entries.count }
                        + loaded.map.allTransitionEntries.count
                        + loaded.map.allInStateTransitionEntries.count
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      generation == self.characterCountRefreshGeneration,
                      librarySnapshot == self.characterLibrary else { return }
                for (id, count) in counts { self.characterClipCounts[id] = count }
                self.refreshSettings()
            }
        }
    }

    private func totalClipCount(in map: MediaMap) -> Int {
        map.allMediaEntries.count
    }

    private func allMediaEntries(in map: MediaMap) -> [MediaEntry] {
        map.allMediaEntries
    }

    private func applyConfiguredWindowSize() {
        guard let panel else { return }
        let size = NSSize(width: mediaMap.window.width, height: mediaMap.window.height)
        let resized = WindowFramePolicy.applyingConfiguredSize(size, to: panel.frame)
        panel.setFrame(positionStore.clampedFrame(resized), display: true)
        clickThrough = options.clickThroughOverride ?? mediaMap.window.clickThrough
        panel.ignoresMouseEvents = clickThrough
        sessionActivityPanel?.ignoresMouseEvents = clickThrough
        sessionActivityPanel?.isMovableByWindowBackground = !clickThrough
        panel.apply(
            alwaysOnTop: options.alwaysOnTopOverride ?? mediaMap.window.alwaysOnTop,
            fullScreenAuxiliary: mediaMap.window.fullScreenAuxiliary
        )
        sessionActivityPanel?.apply(
            alwaysOnTop: effectiveAlwaysOnTop,
            fullScreenAuxiliary: mediaMap.window.fullScreenAuxiliary
        )
        sessionActivityView?.applyAppearance(sessionActivityAppearance)
        positionSessionActivityPanel()
        refreshSessionActivityPresentation()
        player?.applyAppearance(mediaMap.window.appearance)
    }

    private func readState(from url: URL, retryAttempt: Int = 0) {
        if retryAttempt == 0 {
            transientStateReadRetry?.cancel()
            transientStateReadRetry = nil
        }
        lifecycleStateReader.read(url) { [weak self] result in
            self?.applyLifecycleStateReadResult(result, from: url, retryAttempt: retryAttempt)
        }
    }

    private func readSessionActivity(from url: URL, retryAttempt: Int = 0) {
        if retryAttempt == 0 {
            sessionActivityReadRetry?.cancel()
            sessionActivityReadRetry = nil
        }
        sessionActivityReader.readWithTargets(url) { [weak self] result, targets in
            self?.applySessionActivityReadResult(
                result,
                targets: targets,
                from: url,
                retryAttempt: retryAttempt
            )
        }
    }

    private func applySessionActivityReadResult(
        _ result: SessionActivityReadResult,
        targets: [String: String],
        from url: URL,
        retryAttempt: Int
    ) {
        switch result {
        case let .snapshot(snapshot):
            sessionActivityReadRetry?.cancel()
            sessionActivityReadRetry = nil
            let application = SessionActivityApplicationPolicy.apply(
                snapshot,
                lastAccepted: lastAcceptedSessionActivitySnapshot,
                currentlyDisplayed: sessionActivitySnapshot,
                acknowledgementHistory: sessionActivityAcknowledgementHistory,
                now: Date().timeIntervalSince1970
            )
            lastAcceptedSessionActivitySnapshot = application.lastAcceptedSnapshot
            sessionActivitySnapshot = application.displayedSnapshot
            sessionActivityTargets = SessionActivityTargetAdoptionPolicy.apply(
                incomingTargets: targets,
                application: application,
                currentlyAcceptedTargets: sessionActivityTargets
            )
            if application.acknowledgementHistory != sessionActivityAcknowledgementHistory {
                sessionActivityAcknowledgementHistory = application.acknowledgementHistory
                persistSessionActivityAcknowledgements()
            }
            refreshSessionActivityPresentation()
        case .missing, .corrupt:
            guard retryAttempt < 2 else {
                sessionActivitySnapshot = nil
                sessionActivityTargets = [:]
                refreshSessionActivityPresentation()
                return
            }
            sessionActivityReadRetry?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.readSessionActivity(from: url, retryAttempt: retryAttempt + 1)
            }
            sessionActivityReadRetry = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(100 * (retryAttempt + 1)),
                execute: work
            )
        }
    }

    private func loadSessionActivityAcknowledgements() {
        let values = UserDefaults.standard.array(
            forKey: Self.sessionActivityAcknowledgementKey
        ) as? [String] ?? []
        let normalized = SessionActivityApplicationPolicy.normalizedHistory(values)
        sessionActivityAcknowledgementHistory = normalized
        if normalized != values {
            UserDefaults.standard.set(
                normalized,
                forKey: Self.sessionActivityAcknowledgementKey
            )
        }
    }

    private func persistSessionActivityAcknowledgements() {
        UserDefaults.standard.set(
            sessionActivityAcknowledgementHistory,
            forKey: Self.sessionActivityAcknowledgementKey
        )
    }

    private func acknowledgeSessionActivity(_ id: String) {
        guard sessionActivitySnapshot?.completed.contains(where: {
            $0.id == id && $0.event == .sessionEnd
        }) == true else {
            return
        }
        sessionActivityAcknowledgementHistory = SessionActivityApplicationPolicy.recordingAcknowledgement(
            id,
            in: sessionActivityAcknowledgementHistory
        )
        persistSessionActivityAcknowledgements()
        refreshSessionActivityPresentation()
    }

    private func openSessionActivity(_ id: String) {
        guard let threadID = sessionActivityTargets[id] else { return }
        _ = codexDesktopActivator.open(threadID: threadID)
    }

    private func refreshSessionActivityPresentation() {
        guard let sessionActivityView, let sessionActivityPanel else { return }
        let openableIDs = Set(sessionActivityTargets.compactMap { id, threadID in
            codexDesktopActivator.canOpen(threadID: threadID) ? id : nil
        })
        sessionActivityView.update(
            snapshot: sessionActivitySnapshot,
            acknowledgedIDs: Set(sessionActivityAcknowledgementHistory),
            openableIDs: openableIDs
        )
        if sessionActivityView.isHidden {
            sessionActivityExpandedByUser = false
            sessionActivityLayoutAvailable = true
            sessionActivityPanel.orderOut(nil)
        } else {
            positionSessionActivityPanel(restoreVisibility: false)
            guard sessionActivityLayoutAvailable else {
                sessionActivityPanel.orderOut(nil)
                return
            }
            orderSessionActivityPanelVisible()
        }
    }

    private func positionSessionActivityPanel(
        display: Bool = false,
        restoreVisibility: Bool = true
    ) {
        guard let panel, let sessionActivityPanel, let sessionActivityView,
              !sessionActivityView.isHidden else { return }
        let visibleFrame = panel.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? panel.frame
        sessionActivityView.setCompactOverride(false)
        let expandedFittingSize = sessionActivityView.fittingSize
        let expandedSize = NSSize(
            width: max(Self.sessionActivityPanelSize.width, expandedFittingSize.width),
            height: max(Self.sessionActivityPanelSize.height, expandedFittingSize.height)
        )
        sessionActivityView.setCompactOverride(true)
        let compactFittingSize = sessionActivityView.fittingSize
        let compactSize = NSSize(
            width: max(190, compactFittingSize.width),
            height: max(44, compactFittingSize.height)
        )
        let layout = SessionActivityLayoutPolicy.layout(
            beside: panel.frame,
            expandedSize: expandedSize,
            compactSize: compactSize,
            visibleFrame: visibleFrame,
            forceExpanded: sessionActivityExpandedByUser
        )
        let wasAvailable = sessionActivityLayoutAvailable
        sessionActivityLayoutAvailable = layout.available
        guard layout.available else {
            sessionActivityPanel.orderOut(nil)
            return
        }
        sessionActivityView.setCompactOverride(layout.compact)
        sessionActivityScrollContainer.setScrollable(layout.scrollable)
        let targetFrame: NSRect
        if let origin = sessionActivityUserOrigin {
            let availableFrames = NSScreen.screens.map(\.visibleFrame)
            let clampedOrigin = SessionActivityPanelPositionStore.clamped(
                origin: origin,
                size: layout.frame.size,
                to: availableFrames.isEmpty ? [visibleFrame] : availableFrames
            )
            if clampedOrigin != origin {
                sessionActivityUserOrigin = clampedOrigin
                SessionActivityPanelPositionStore.persist(clampedOrigin)
            }
            targetFrame = NSRect(origin: clampedOrigin, size: layout.frame.size)
        } else {
            targetFrame = layout.frame
        }
        isPositioningSessionActivityPanel = true
        sessionActivityPanel.setFrame(targetFrame, display: display)
        isPositioningSessionActivityPanel = false
        if restoreVisibility,
           SessionActivityPanelVisibilityPolicy.shouldOrderFront(
               wasAvailable: wasAvailable,
               isAvailable: layout.available
           ) {
            orderSessionActivityPanelVisible()
        }
    }

    private func orderSessionActivityPanelVisible() {
        sessionActivityPanel.apply(
            alwaysOnTop: effectiveAlwaysOnTop,
            fullScreenAuxiliary: mediaMap.window.fullScreenAuxiliary
        )
        sessionActivityPanel.ignoresMouseEvents = clickThrough
        sessionActivityPanel.isMovableByWindowBackground = !clickThrough
        sessionActivityPanel.orderVisible(alwaysOnTop: effectiveAlwaysOnTop)
    }

    private func expandSessionActivityPanel() {
        sessionActivityExpandedByUser = true
        positionSessionActivityPanel(display: true)
    }

    private func applySessionActivityAppearance(_ appearance: SessionActivityPanelAppearance) {
        sessionActivityAppearance = appearance
        SessionActivityPanelAppearanceStore.persist(appearance)
        sessionActivityView?.applyAppearance(appearance)
        refreshSessionActivityPresentation()
    }

    private func resetSessionActivityPanelPosition() {
        sessionActivityUserOrigin = nil
        SessionActivityPanelPositionStore.reset()
        positionSessionActivityPanel(display: true)
    }

    private func applyLifecycleStateReadResult(
        _ result: LifecycleStateReadResult,
        from url: URL,
        retryAttempt: Int
    ) {
        switch result {
        case .missing:
            retryLifecycleStateReadOrReject(.missing, from: url, retryAttempt: retryAttempt)
        case .corrupt:
            retryLifecycleStateReadOrReject(.corrupt, from: url, retryAttempt: retryAttempt)
        case let .state(state):
            transientStateReadRetry?.cancel()
            transientStateReadRetry = nil
            applyLifecycleState(state)
        }
    }

    private func retryLifecycleStateReadOrReject(
        _ health: PublisherHealth,
        from url: URL,
        retryAttempt: Int
    ) {
        // Atomic replacement should make malformed snapshots exceptional, but
        // a writer or directory can still be observed while recovering. Give
        // it two short bounded retries before exposing an idle fallback.
        guard retryAttempt < 2 else {
            lastPublicationRejectionReason = health.rawValue
            rejectPublisher(health)
            return
        }
        transientStateReadRetry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.readState(from: url, retryAttempt: retryAttempt + 1)
        }
        transientStateReadRetry = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(100 * (retryAttempt + 1)),
            execute: work
        )
    }

    private func applyLifecycleState(_ state: CurrentState) {
        lastPublishedSnapshot = state
        let ordering = StatePublicationOrderPolicy.decide(
            lastAccepted: lastAcceptedPublishedSnapshot,
            incoming: state
        )
        guard ordering.shouldAccept else {
            let freshness = freshnessPolicy.freshness(
                of: state,
                now: Date().timeIntervalSince1970
            )
            // A health read of the same immutable snapshot is normally a
            // no-op. If the path disappeared or was malformed in between,
            // however, the identical snapshot is authoritative recovery and
            // must restore live presentation without consuming a new cursor.
            if ordering == .rejectEqualRevisionDuplicate
                || ordering == .rejectLegacyTimestampDuplicate,
               freshness == .fresh {
                lastPublicationRejectionReason = nil
                if publisherHealth != .live || currentState != state.state {
                    let previousPreview = temporaryStatePreviewPolicy.previewState
                    let outcome = temporaryStatePreviewPolicy.receiveLifecycleState(state.state)
                    if previousPreview != nil,
                       case .presentingLifecycle = outcome {
                        relinquishTemporaryStatePreview(
                            previousPreview: previousPreview,
                            reason: "publisher_recovered"
                        )
                    }
                    setPublisherHealth(.live)
                    apply(state: state.state)
                } else {
                    updateStatusMenu()
                    refreshSettings()
                }
            } else if ![
                StatePublicationOrderDecision.rejectEqualRevisionDuplicate,
                .rejectLegacyTimestampDuplicate,
            ].contains(ordering) {
                recordPublicationRejection(ordering.rejectionReason ?? "order_rejected")
                updateStatusMenu()
                refreshSettings()
            } else {
                lastPublicationRejectionReason = freshness.rawValue
                rejectPublisher(freshness == .futureSkew ? .futureSkew : .stale)
            }
            return
        }
        switch freshnessPolicy.freshness(of: state, now: Date().timeIntervalSince1970) {
        case .fresh:
            lastAcceptedPublishedSnapshot = state
            lastPublicationRejectionReason = nil
            let previousPreview = temporaryStatePreviewPolicy.previewState
            let outcome = temporaryStatePreviewPolicy.receiveLifecycleState(state.state)
            if previousPreview != nil,
               case .presentingLifecycle = outcome {
                relinquishTemporaryStatePreview(
                    previousPreview: previousPreview,
                    reason: "lifecycle_changed"
                )
            }
            setPublisherHealth(.live)
            apply(state: state.state)
            // Metadata-only revisions are intentionally playback-neutral, but
            // diagnostics/settings should expose the repair immediately.
            updateStatusMenu()
            refreshSettings()
        case .stale:
            lastPublicationRejectionReason = PublisherHealth.stale.rawValue
            rejectPublisher(.stale)
        case .futureSkew:
            lastPublicationRejectionReason = PublisherHealth.futureSkew.rawValue
            rejectPublisher(.futureSkew)
        }
    }

    private func recordPublicationRejection(_ reason: String) {
        let allowed = Set([
            "lower_revision", "equal_revision_duplicate", "equal_revision_conflict",
            "revisionless_rollback", "legacy_timestamp_duplicate", "legacy_timestamp_rollback",
        ])
        guard allowed.contains(reason) else { return }
        lastPublicationRejectionReason = reason
        publicationRejectionReasons[reason] = min(
            1_000_000,
            (publicationRejectionReasons[reason] ?? 0) + 1
        )
        logger.info("event=lifecycle_publication_rejected reason=\(reason, privacy: .public)")
    }

    private func rejectPublisher(_ health: PublisherHealth) {
        setPublisherHealth(health)
        cancelActiveLifecycleTransition(reason: "publisher_rejected")
        apply(state: .idle, forceRefresh: true)
    }

    private func setPublisherHealth(_ health: PublisherHealth) {
        guard publisherHealth != health else { return }
        publisherHealth = health
        updateStatusMenu()
        refreshSettings()
        logger.info("event=publisher_health health=\(health.rawValue, privacy: .public) idle_fallback=\(health.usesIdleFallback, privacy: .public)")
    }

    private func apply(state: PetState, forceRefresh: Bool = false) {
        let previousProducerState = currentState
        let presentationTrigger = LifecycleTransitionPolicy.trigger(
            previousLifecycleState: lastLifecycleStateForSelection,
            incomingState: state,
            forceRefresh: forceRefresh
        )
        let shouldAdvanceSelection = MediaSelectionAdvancePolicy.shouldAdvance(
            previousLifecycleState: lastLifecycleStateForSelection,
            incomingState: state,
            forceRefresh: forceRefresh
        )
        lastLifecycleStateForSelection = state
        if forceRefresh {
            cancelActiveOneShotWithoutRestore(reason: "forced_refresh")
        } else if activeOneShotPreview != nil {
            switch oneShotArbiter.heartbeat(state: state) {
            case .inactive:
                activeOneShotPreview = nil
                lastPresentedState = nil
                pendingPresentationState = nil
            case .continuing:
                break
            case let .preempted(preview):
                activeOneShotPreview = nil
                lastPresentedState = nil
                pendingPresentationState = nil
                logger.info("event=one_shot_preempted token=\(preview.token.rawValue, privacy: .public) lifecycle_state=\(state.rawValue, privacy: .public)")
            }
        }
        let presentationState = temporaryStatePreviewPolicy.previewState ?? state
        let decision = StatePresentationDecision.decide(
            lastPresentedState: lastPresentedState,
            pendingState: pendingPresentationState,
            incomingState: presentationState,
            forceRefresh: forceRefresh
        )
        let supersedesDifferentPendingPresentation = pendingPresentationState.map {
            $0 != presentationState
        } ?? false
        currentState = state
        let shouldRefreshUI = LifecycleUIRefreshPolicy.shouldRefresh(
            previousProducerState: previousProducerState,
            incomingProducerState: state,
            presentationWillRefresh: decision.shouldRefresh
        )
        var cancelledLifecycleTransition = false
        if let pendingLifecycleTransitionAttestation,
           forceRefresh || pendingLifecycleTransitionAttestation.destination != state {
            cancelActiveLifecycleTransition(
                reason: forceRefresh ? "forced_refresh" : "authoritative_state_changed"
            )
            cancelledLifecycleTransition = true
        } else if let activeLifecycleTransition,
           forceRefresh || activeLifecycleTransition.destination != state {
            cancelActiveLifecycleTransition(
                reason: forceRefresh ? "forced_refresh" : "authoritative_state_changed"
            )
            cancelledLifecycleTransition = true
        }
        guard decision.shouldRefresh
                || cancelledLifecycleTransition
                || supersedesDifferentPendingPresentation else {
            if shouldRefreshUI {
                updateStatusMenu()
                refreshSettings()
            }
            return
        }


        let configuredTransition = lastCommittedLifecycleState.flatMap {
            TransitionLibraryResolver.resolve(
                from: $0,
                to: state,
                character: mediaMap,
                global: globalTransitionLibrary
            )
        }
        if temporaryStatePreviewPolicy.previewState == nil,
           activeOneShotPreview == nil,
           let source = LifecycleTransitionPolicy.source(
               lastCommittedState: lastCommittedLifecycleState,
               incomingState: state,
               trigger: presentationTrigger,
               reduceMotion: reduceMotion,
               hasConfiguredMedia: configuredTransition != nil
           ),
           beginLifecycleTransition(
               from: source,
               to: state,
               advanceSelection: shouldAdvanceSelection
           ) {
            return
        }

        startLifecyclePresentation(
            state: presentationState,
            advanceSelection: temporaryStatePreviewPolicy.previewState == nil
                ? shouldAdvanceSelection
                : false,
            refreshReason: decision.rawValue,
            useManualPreviewCursor: temporaryStatePreviewPolicy.previewState != nil
        )
    }

    private func beginLifecycleTransition(
        from source: PetState,
        to destination: PetState,
        advanceSelection: Bool
    ) -> Bool {
        guard !reduceMotion,
              let mediaMapURL,
              let resolvedTransition = TransitionLibraryResolver.resolve(
                  from: source,
                  to: destination,
                  character: mediaMap,
                  global: globalTransitionLibrary
              )
        else {
            return false
        }
        let transitionPlaylist = resolvedTransition.playlist
        let transitionLibraryURL = resolvedTransition.scope == .character
            ? mediaMapURL
            : characterLibraryStorage.globalTransitionLibraryURL
        let selectionCursor = transitionSelectionCursor(for: resolvedTransition.scope)
        let isEligible: (MediaEntry) -> Bool = { [mediaMap, transitionLibraryURL] entry in
            FileManager.default.isReadableFile(
                atPath: mediaMap.resolvedURL(for: entry, relativeTo: transitionLibraryURL).path
            )
        }
        let selectionRequest: TransitionSelectionRequest?
        if resolvedTransition.isUniversalGlobal {
            selectionRequest = try? selectionCursor.requestGlobal(
                from: source,
                to: destination,
                playlist: transitionPlaylist,
                isEligible: isEligible
            )
        } else {
            selectionRequest = try? selectionCursor.request(
                from: source,
                to: destination,
                playlist: transitionPlaylist,
                isEligible: isEligible
            )
        }
        guard var selectionRequest, let transitionEntry = selectionRequest.next() else {
            logger.error("event=lifecycle_transition_unavailable from=\(source.rawValue, privacy: .public) to=\(destination.rawValue, privacy: .public) reason=no_eligible_variant")
            return false
        }
        guard let destinationEntry = selectedEntry(
            for: destination,
            advance: advanceSelection,
            useManualPreviewCursor: false
        ) else { return false }
        let destinationURL = mediaMap.resolvedURL(for: destinationEntry, relativeTo: mediaMapURL)
        guard FileManager.default.isReadableFile(atPath: destinationURL.path) else {
            logger.error("event=lifecycle_transition_unavailable from=\(source.rawValue, privacy: .public) to=\(destination.rawValue, privacy: .public) reason=unreadable")
            return false
        }
        let transitionURL = mediaMap.resolvedURL(for: transitionEntry, relativeTo: transitionLibraryURL)
        cancelActiveLifecycleTransition(reason: "superseded")
        if stateDialoguePresentation != nil {
            dialogueVoiceCoordinator.cancelAutomaticPlayback()
            stateDialoguePresentation = nil
            player.view.showDialogueMessage(nil)
        }
        let transitionID = beginTransition()
        let request = PendingLifecycleTransitionAttestation(
            id: transitionID,
            source: source,
            destination: destination,
            transitionEntry: transitionEntry,
            transitionURL: transitionURL,
            destinationEntry: destinationEntry,
            destinationURL: destinationURL,
            transitionScope: resolvedTransition.scope,
            transitionSelectionRequest: selectionRequest,
            destinationSelectionRequest: nil,
            isInState: false
        )
        pendingLifecycleTransitionAttestation = request
        pendingPresentationState = destination
        logger.info("event=lifecycle_transition_attestation_started transition_id=\(transitionID, privacy: .public) from=\(source.rawValue, privacy: .public) to=\(destination.rawValue, privacy: .public)")
        let verifier = Task.detached(priority: .userInitiated) {
            await Self.attestRuntimeTransition(
                movieURL: transitionURL,
                timeoutSeconds: Self.transitionAttestationTimeoutSeconds
            )
        }
        pendingLifecycleTransitionAttestationTask = verifier
        Task { @MainActor [weak self] in
            let result = await verifier.value
            self?.finishLifecycleTransitionAttestation(request: request, result: result)
        }
        updateStatusMenu()
        refreshSettings()
        return true
    }

    private func finishLifecycleTransitionAttestation(
        request: PendingLifecycleTransitionAttestation,
        result: Result<CharacterTransitionRuntimeAttestation, Error>
    ) {
        guard pendingLifecycleTransitionAttestation?.id == request.id,
              transitionSequence == request.id,
              currentState == request.destination,
              temporaryStatePreviewPolicy.previewState == nil,
              activeOneShotPreview == nil else { return }
        pendingLifecycleTransitionAttestation = nil
        pendingLifecycleTransitionAttestationTask = nil
        switch result {
        case .failure:
            logger.error("event=lifecycle_transition_unavailable from=\(request.source.rawValue, privacy: .public) to=\(request.destination.rawValue, privacy: .public) reason=attestation_failed")
            retryLifecycleTransition(request: request, reason: "attestation_failed")
        case let .success(attestation):
            activeLifecycleTransition = ActiveLifecycleTransition(
                id: request.id,
                source: request.source,
                destination: request.destination,
                transitionEntry: request.transitionEntry,
                transitionURL: request.transitionURL,
                destinationEntry: request.destinationEntry,
                destinationURL: request.destinationURL,
                transitionScope: request.transitionScope,
                transitionSelectionRequest: request.transitionSelectionRequest,
                destinationSelectionRequest: request.destinationSelectionRequest,
                isInState: request.isInState
            )
            let continuousRotation = mediaMap.playlist(for: request.destination)?.isContinuousRotationEffective == true
            let playback = player.showLifecycleTransition(
                sourceState: request.source,
                destinationState: request.destination,
                transitionEntry: request.transitionEntry,
                transitionURL: request.transitionURL,
                transitionAttestation: attestation,
                destinationEntry: request.destinationEntry,
                destinationURL: request.destinationURL,
                transitionID: request.id,
                startedAt: DispatchTime.now().uptimeNanoseconds,
                advancePlaylistWhenEnded: continuousRotation
            )
            guard playback == .preparing else {
                activeLifecycleTransition = nil
                retryLifecycleTransition(request: request, reason: "binding_failed")
                return
            }
            logger.info("event=lifecycle_transition_started transition_id=\(request.id, privacy: .public) from=\(request.source.rawValue, privacy: .public) to=\(request.destination.rawValue, privacy: .public)")
            updateStatusMenu()
            refreshSettings()
        }
    }

    private func retryLifecycleTransition(
        request: PendingLifecycleTransitionAttestation,
        reason: String
    ) {
        guard transitionSequence == request.id,
              currentState == request.destination,
              temporaryStatePreviewPolicy.previewState == nil,
              activeOneShotPreview == nil else { return }
        guard var selectionRequest = request.transitionSelectionRequest,
              let transitionEntry = selectionRequest.next() else {
            pendingPresentationState = nil
            logger.error("event=lifecycle_transition_variants_exhausted transition_id=\(request.id, privacy: .public) from=\(request.source.rawValue, privacy: .public) to=\(request.destination.rawValue, privacy: .public) reason=\(reason, privacy: .public)")
            startLifecyclePresentation(
                state: request.destination,
                advanceSelection: false,
                refreshReason: "layered_handoff_variants_exhausted",
                preselectedEntry: request.destinationEntry,
                selectionRequest: request.destinationSelectionRequest
            )
            return
        }
        let retryID = beginTransition()
        let transitionLibraryURL = request.transitionScope == .character
            ? mediaMapURL!
            : characterLibraryStorage.globalTransitionLibraryURL
        let transitionURL = mediaMap.resolvedURL(for: transitionEntry, relativeTo: transitionLibraryURL)
        let retry = PendingLifecycleTransitionAttestation(
            id: retryID,
            source: request.source,
            destination: request.destination,
            transitionEntry: transitionEntry,
            transitionURL: transitionURL,
            destinationEntry: request.destinationEntry,
            destinationURL: request.destinationURL,
            transitionScope: request.transitionScope,
            transitionSelectionRequest: selectionRequest,
            destinationSelectionRequest: request.destinationSelectionRequest,
            isInState: false
        )
        pendingLifecycleTransitionAttestation = retry
        pendingPresentationState = request.destination
        let verifier = Task.detached(priority: .userInitiated) {
            await Self.attestRuntimeTransition(
                movieURL: transitionURL,
                timeoutSeconds: Self.transitionAttestationTimeoutSeconds
            )
        }
        pendingLifecycleTransitionAttestationTask = verifier
        Task { @MainActor [weak self] in
            let result = await verifier.value
            self?.finishLifecycleTransitionAttestation(request: retry, result: result)
        }
        logger.info("event=lifecycle_transition_variant_retry transition_id=\(retryID, privacy: .public) previous_transition_id=\(request.id, privacy: .public) from=\(request.source.rawValue, privacy: .public) to=\(request.destination.rawValue, privacy: .public) remaining=\(selectionRequest.remainingCount, privacy: .public) reason=\(reason, privacy: .public)")
    }

    private func finishLifecycleTransition(transitionID: UInt64, outcome: String) {
        guard let active = activeLifecycleTransition,
              LifecycleTransitionCompletionDecision.decide(
                  callbackID: transitionID,
                  currentSequence: transitionSequence,
                  activeID: active.id,
                  activeDestination: active.destination,
                  authoritativeState: currentState,
                  temporaryPreviewActive: temporaryStatePreviewPolicy.previewState != nil
              ) == .commit(active.destination) else { return }
        activeLifecycleTransition = nil
        pendingPresentationState = nil
        logger.info("event=lifecycle_transition_finished transition_id=\(transitionID, privacy: .public) from=\(active.source.rawValue, privacy: .public) to=\(active.destination.rawValue, privacy: .public) outcome=\(outcome, privacy: .public)")
        if outcome == "completed" {
            if var selectionRequest = active.transitionSelectionRequest {
                var cursor = transitionSelectionCursor(for: active.transitionScope)
                _ = selectionRequest.commit(to: &cursor)
                setTransitionSelectionCursor(cursor, for: active.transitionScope)
            }
            if var selectionRequest = active.destinationSelectionRequest {
                _ = selectionRequest.commit(to: &mediaSelectionCursor)
            }
            lastPresentedState = active.destination
            lastCommittedLifecycleState = active.destination
            if !active.isInState { presentStateOwnedDialogueIfNeeded(for: active.destination) }
        } else {
            if active.isInState {
                startLifecyclePresentation(
                    state: active.destination,
                    advanceSelection: false,
                    refreshReason: "in_state_handoff_failed",
                    preselectedEntry: active.destinationEntry,
                    selectionRequest: active.destinationSelectionRequest
                )
                return
            }
            retryLifecycleTransition(
                request: PendingLifecycleTransitionAttestation(
                    id: active.id,
                    source: active.source,
                    destination: active.destination,
                    transitionEntry: active.transitionEntry,
                    transitionURL: active.transitionURL,
                    destinationEntry: active.destinationEntry,
                    destinationURL: active.destinationURL,
                    transitionScope: active.transitionScope,
                    transitionSelectionRequest: active.transitionSelectionRequest,
                    destinationSelectionRequest: active.destinationSelectionRequest,
                    isInState: false
                ),
                reason: "playback_failed"
            )
            return
        }
        updateStatusMenu()
        refreshSettings()
    }

    private static func attestRuntimeTransition(
        movieURL: URL,
        timeoutSeconds: TimeInterval
    ) async -> Result<CharacterTransitionRuntimeAttestation, Error> {
        do {
            let attestation = try await PortableMediaOperationRunner.run(
                timeoutSeconds: timeoutSeconds
            ) { token in
                try token.check()
                let result = try CharacterLibraryStorage.attestRuntimeTransition(
                    movieURL: movieURL,
                    operationCheck: { try token.check() }
                )
                try token.check()
                return result
            }
            return .success(attestation)
        } catch {
            return .failure(error)
        }
    }

    @discardableResult
    private func cancelInStateTransitionPrewarm(
        matchingTransitionID: UInt64? = nil,
        reason: String
    ) -> Bool {
        guard let pending = pendingInStateTransitionPrewarm,
              matchingTransitionID == nil
                || pending.request.id == matchingTransitionID else { return false }
        pendingInStateTransitionPrewarm = nil
        pendingInStateTransitionPrewarmTask?.cancel()
        pendingInStateTransitionPrewarmTask = nil
        player?.cancelLifecycleTransition()
        logger.info(
            "event=in_state_transition_prewarm_cancelled transition_id=\(pending.request.id, privacy: .public) base_transition_id=\(pending.baseTransitionID, privacy: .public) state=\(pending.request.destination.rawValue, privacy: .public) reason=\(reason, privacy: .public)"
        )
        return true
    }

    private func handleLifecycleTransitionFailure(transitionID: UInt64) {
        if cancelInStateTransitionPrewarm(
            matchingTransitionID: transitionID,
            reason: "preparation_failed"
        ) {
            return
        }
        finishLifecycleTransition(transitionID: transitionID, outcome: "failed")
    }

    private func cancelActiveLifecycleTransition(reason: String) {
        _ = cancelInStateTransitionPrewarm(reason: reason)
        var cancelledPending = false
        if let pending = pendingLifecycleTransitionAttestation {
            cancelledPending = true
            pendingLifecycleTransitionAttestation = nil
            pendingLifecycleTransitionAttestationTask?.cancel()
            pendingLifecycleTransitionAttestationTask = nil
            if pendingPresentationState == pending.destination {
                pendingPresentationState = nil
            }
            logger.info("event=lifecycle_transition_attestation_cancelled transition_id=\(pending.id, privacy: .public) from=\(pending.source.rawValue, privacy: .public) to=\(pending.destination.rawValue, privacy: .public) reason=\(reason, privacy: .public)")
        }
        guard let active = activeLifecycleTransition else {
            if cancelledPending {
                updateStatusMenu()
                refreshSettings()
            }
            return
        }
        activeLifecycleTransition = nil
        pendingPresentationState = nil
        player.cancelLifecycleTransition()
        logger.info("event=lifecycle_transition_cancelled transition_id=\(active.id, privacy: .public) from=\(active.source.rawValue, privacy: .public) to=\(active.destination.rawValue, privacy: .public) reason=\(reason, privacy: .public)")
    }

    private func startLifecyclePresentation(
        state: PetState,
        advanceSelection: Bool,
        refreshReason: String,
        useManualPreviewCursor: Bool = false,
        explicitUserAdvance: Bool = false,
        preselectedEntry: MediaEntry? = nil,
        selectionRequest: MediaSelectionRequest? = nil,
        selectionCommitTarget: MediaSelectionCommitTarget = .lifecycle
    ) {
        pendingMediaSelectionCommit = nil
        if stateDialoguePresentation?.state != state {
            let keepSpokenMessage = dialogueVoiceCoordinator.isAutomaticPlaybackActive
            dialogueVoiceCoordinator.cancelAutomaticPlayback()
            stateDialoguePresentation = nil
            if !keepSpokenMessage {
                player?.view.showDialogueMessage(nil)
            }
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let transitionID = beginTransition()
        let entry = preselectedEntry ?? selectedEntry(
            for: state,
            advance: advanceSelection,
            useManualPreviewCursor: useManualPreviewCursor,
            explicitUserAdvance: explicitUserAdvance
        )
        let url = entry.map { mediaMap.resolvedURL(for: $0, relativeTo: mediaMapURL) }
        let posterURL = entry.flatMap { mediaMap.resolvedPosterURL(for: $0, relativeTo: mediaMapURL) }
        let continuousRotation = mediaMap.playlist(for: state)?.isContinuousRotationEffective == true
        let startResult = player?.show(
            state: state,
            entry: entry,
            url: url,
            posterURL: posterURL,
            transitionID: transitionID,
            startedAt: started,
            advancePlaylistWhenEnded: continuousRotation
        ) ?? .failed
        switch startResult {
        case .presented:
            if var selectionRequest {
                commitMediaSelectionRequest(
                    &selectionRequest,
                    target: selectionCommitTarget
                )
            }
            lastPresentedState = state
            if temporaryStatePreviewPolicy.previewState == nil, activeOneShotPreview == nil {
                lastCommittedLifecycleState = state
            }
            pendingPresentationState = nil
            presentStateOwnedDialogueIfNeeded(for: state)
        case .preparing:
            if let selectionRequest {
                pendingMediaSelectionCommit = PendingMediaSelectionCommit(
                    transitionID: transitionID,
                    request: selectionRequest,
                    target: selectionCommitTarget
                )
            }
            lastPresentedState = nil
            pendingPresentationState = state
        case .failed:
            lastPresentedState = nil
            pendingPresentationState = nil
        }
        updateStatusMenu()
        refreshSettings()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        logger.info("event=state_transition_setup transition_id=\(transitionID, privacy: .public) state=\(state.rawValue, privacy: .public) refresh_reason=\(refreshReason, privacy: .public) start_result=\(startResult.rawValue, privacy: .public) reduce_motion=\(self.reduceMotion, privacy: .public) continuous_rotation=\(continuousRotation, privacy: .public) setup_duration_ms=\(elapsed, format: .fixed(precision: 3), privacy: .public)")
    }

    private func advancePlaylistAfterClipEnd(transitionID: UInt64, state: PetState) {
        guard transitionID == transitionSequence,
              state == effectivePresentationState,
              activeOneShotPreview == nil,
              mediaMap.playlist(for: state)?.isContinuousRotationEffective == true else { return }
        _ = cancelInStateTransitionPrewarm(reason: "source_clip_ended_before_activation")
        pendingPresentationState = nil
        logger.info("event=playlist_advance_triggered transition_id=\(transitionID, privacy: .public) state=\(state.rawValue, privacy: .public) reason=clip_end")
        let useManualPreviewCursor = temporaryStatePreviewPolicy.previewState != nil
        guard let selectionRequest = mediaSelectionRequest(
            for: state,
            advance: true,
            useManualPreviewCursor: useManualPreviewCursor
        ) else { return }
        startLifecyclePresentation(
            state: state,
            advanceSelection: false,
            refreshReason: "clip_end",
            useManualPreviewCursor: useManualPreviewCursor,
            preselectedEntry: selectionRequest.entry,
            selectionRequest: selectionRequest,
            selectionCommitTarget: useManualPreviewCursor ? .manualPreview : .lifecycle
        )
    }

    private func beginInStateTransitionPrewarm(
        baseTransitionID: UInt64,
        state: PetState
    ) -> Bool {
        guard baseTransitionID == transitionSequence,
              state == effectivePresentationState,
              activeLifecycleTransition == nil,
              pendingLifecycleTransitionAttestation == nil,
              InStateTransitionPolicy.shouldTrigger(
                  trigger: .playlistRotation,
                  reduceMotion: reduceMotion,
                  continuousRotation: true,
                  temporaryPreviewActive: temporaryStatePreviewPolicy.previewState != nil
              ),
              activeOneShotPreview == nil,
              let mediaMapURL,
              let transitionEntry = mediaMap.inStateTransition(for: state) else { return false }
        let transitionURL = mediaMap.resolvedURL(for: transitionEntry, relativeTo: mediaMapURL)
        guard FileManager.default.isReadableFile(atPath: transitionURL.path),
              let destinationSelectionRequest = mediaSelectionRequest(
                  for: state,
                  advance: true,
                  useManualPreviewCursor: false
              ) else { return false }
        let destinationEntry = destinationSelectionRequest.entry
        let destinationURL = mediaMap.resolvedURL(for: destinationEntry, relativeTo: mediaMapURL)
        guard FileManager.default.isReadableFile(atPath: destinationURL.path) else { return false }

        _ = cancelInStateTransitionPrewarm(reason: "superseded_prewarm")
        let transitionID = reserveTransitionID()
        let request = PendingLifecycleTransitionAttestation(
            id: transitionID,
            source: state,
            destination: state,
            transitionEntry: transitionEntry,
            transitionURL: transitionURL,
            destinationEntry: destinationEntry,
            destinationURL: destinationURL,
            transitionScope: .character,
            transitionSelectionRequest: nil,
            destinationSelectionRequest: destinationSelectionRequest,
            isInState: true
        )
        pendingInStateTransitionPrewarm = PendingInStateTransitionPrewarm(
            baseTransitionID: baseTransitionID,
            request: request
        )
        let verifier = Task.detached(priority: .userInitiated) {
            await Self.attestRuntimeTransition(
                movieURL: transitionURL,
                timeoutSeconds: Self.transitionAttestationTimeoutSeconds
            )
        }
        pendingInStateTransitionPrewarmTask = verifier
        Task { @MainActor [weak self] in
            let result = await verifier.value
            self?.finishInStateTransitionPrewarm(
                baseTransitionID: baseTransitionID,
                request: request,
                result: result
            )
        }
        logger.info(
            "event=in_state_transition_prewarm_started transition_id=\(transitionID, privacy: .public) base_transition_id=\(baseTransitionID, privacy: .public) state=\(state.rawValue, privacy: .public)"
        )
        return true
    }

    private func finishInStateTransitionPrewarm(
        baseTransitionID: UInt64,
        request: PendingLifecycleTransitionAttestation,
        result: Result<CharacterTransitionRuntimeAttestation, Error>
    ) {
        guard let pending = pendingInStateTransitionPrewarm,
              pending.baseTransitionID == baseTransitionID,
              pending.request.id == request.id,
              transitionSequence == baseTransitionID,
              currentState == request.destination,
              temporaryStatePreviewPolicy.previewState == nil,
              activeOneShotPreview == nil else { return }
        pendingInStateTransitionPrewarmTask = nil
        switch result {
        case .failure:
            pendingInStateTransitionPrewarm = nil
            logger.error(
                "event=in_state_transition_prewarm_unavailable transition_id=\(request.id, privacy: .public) base_transition_id=\(baseTransitionID, privacy: .public) state=\(request.destination.rawValue, privacy: .public) reason=attestation_failed"
            )
        case let .success(attestation):
            let continuousRotation = mediaMap.playlist(
                for: request.destination
            )?.isContinuousRotationEffective == true
            let playback = player.showLifecycleTransition(
                sourceState: request.source,
                destinationState: request.destination,
                transitionEntry: request.transitionEntry,
                transitionURL: request.transitionURL,
                transitionAttestation: attestation,
                destinationEntry: request.destinationEntry,
                destinationURL: request.destinationURL,
                transitionID: request.id,
                startedAt: DispatchTime.now().uptimeNanoseconds,
                advancePlaylistWhenEnded: continuousRotation,
                sameStateBaseTransitionID: baseTransitionID
            )
            guard playback == .preparing else {
                _ = cancelInStateTransitionPrewarm(
                    matchingTransitionID: request.id,
                    reason: "binding_failed"
                )
                return
            }
            logger.info(
                "event=in_state_transition_prewarm_ready transition_id=\(request.id, privacy: .public) base_transition_id=\(baseTransitionID, privacy: .public) state=\(request.destination.rawValue, privacy: .public)"
            )
        }
    }

    private func activateInStateTransitionPrewarm(
        transitionID: UInt64,
        baseTransitionID: UInt64,
        state: PetState
    ) -> Bool {
        guard let pending = pendingInStateTransitionPrewarm,
              pending.baseTransitionID == baseTransitionID,
              pending.request.id == transitionID,
              transitionSequence == baseTransitionID,
              currentState == state,
              effectivePresentationState == state,
              temporaryStatePreviewPolicy.previewState == nil,
              activeOneShotPreview == nil else { return false }
        let request = pending.request
        pendingInStateTransitionPrewarm = nil
        pendingInStateTransitionPrewarmTask?.cancel()
        pendingInStateTransitionPrewarmTask = nil
        transitionSequence = transitionID
        activeLifecycleTransition = ActiveLifecycleTransition(
            id: request.id,
            source: request.source,
            destination: request.destination,
            transitionEntry: request.transitionEntry,
            transitionURL: request.transitionURL,
            destinationEntry: request.destinationEntry,
            destinationURL: request.destinationURL,
            transitionScope: request.transitionScope,
            transitionSelectionRequest: request.transitionSelectionRequest,
            destinationSelectionRequest: request.destinationSelectionRequest,
            isInState: true
        )
        pendingPresentationState = state
        logger.info(
            "event=in_state_transition_prewarm_activated transition_id=\(transitionID, privacy: .public) base_transition_id=\(baseTransitionID, privacy: .public) state=\(state.rawValue, privacy: .public)"
        )
        updateStatusMenu()
        refreshSettings()
        return true
    }

    private func mediaSelectionRequest(
        for state: PetState,
        advance: Bool,
        useManualPreviewCursor: Bool
    ) -> MediaSelectionRequest? {
        guard let mediaMapURL,
              let playlist = mediaMap.playlist(for: state) else { return nil }
        let cursor = useManualPreviewCursor
            ? manualPreviewSelectionCursor
            : mediaSelectionCursor
        return cursor.request(
            for: state,
            from: playlist,
            advance: advance,
            isEligible: { [mediaMap, mediaMapURL] entry in
                FileManager.default.isReadableFile(
                    atPath: mediaMap.resolvedURL(for: entry, relativeTo: mediaMapURL).path
                )
            }
        )
    }

    private func commitMediaSelectionRequest(
        _ request: inout MediaSelectionRequest,
        target: MediaSelectionCommitTarget
    ) {
        switch target {
        case .lifecycle:
            _ = request.commit(to: &mediaSelectionCursor)
        case .manualPreview:
            _ = request.commit(to: &manualPreviewSelectionCursor)
        }
    }

    private func handlePresentationEvent(
        transitionID: UInt64,
        state: PetState,
        event: PlaybackPresentationEvent
    ) {
        guard transitionID == transitionSequence, state == effectivePresentationState else { return }
        pendingPresentationState = nil
        if activeOneShotPreview?.transitionID == transitionID {
            switch event {
            case .ready:
                lastPresentedState = state
                logger.info("event=one_shot_ready transition_id=\(transitionID, privacy: .public) lifecycle_state=\(state.rawValue, privacy: .public)")
                updateStatusMenu()
                refreshSettings()
            case .failed:
                logger.error("event=one_shot_failed transition_id=\(transitionID, privacy: .public) lifecycle_state=\(state.rawValue, privacy: .public)")
                finishOneShotPreview(transitionID: transitionID, reason: "failed")
            }
            return
        }
        switch event {
        case .ready:
            if var pending = pendingMediaSelectionCommit,
               pending.transitionID == transitionID {
                commitMediaSelectionRequest(
                    &pending.request,
                    target: pending.target
                )
                pendingMediaSelectionCommit = nil
            }
            lastPresentedState = state
            if temporaryStatePreviewPolicy.previewState == nil, activeOneShotPreview == nil {
                lastCommittedLifecycleState = state
            }
            presentStateOwnedDialogueIfNeeded(for: state)
            logger.info("event=presentation_committed transition_id=\(transitionID, privacy: .public) state=\(state.rawValue, privacy: .public)")
        case .failed:
            if pendingMediaSelectionCommit?.transitionID == transitionID {
                pendingMediaSelectionCommit = nil
            }
            lastPresentedState = nil
            logger.error("event=presentation_revoked transition_id=\(transitionID, privacy: .public) state=\(state.rawValue, privacy: .public)")
        }
        updateStatusMenu()
    }

    private func presentStateOwnedDialogueIfNeeded(for state: PetState) {
        if stateDialoguePresentation?.state == state {
            ensureStateOwnedDialoguePlayback()
            return
        }
        dialogueVoiceCoordinator.cancelAutomaticPlayback()
        let line = dialogueVoiceCoordinator.preferredLine(for: state)
        let presentation = StateDialoguePresentation(
            id: UUID(),
            state: state,
            lineID: line?.id,
            lineRevision: line?.revision,
            text: line?.text,
            audioDisposition: .pending
        )
        let keepSpokenMessage = dialogueVoiceCoordinator.isAutomaticPlaybackActive
        stateDialoguePresentation = presentation
        if !keepSpokenMessage {
            player?.view.showDialogueMessage(line?.text)
        }
        applyStateOwnedDialoguePlaybackResult(
            dialogueVoiceCoordinator.beginAutomaticPlayback(
                for: state,
                requestID: presentation.id
            ),
            requestID: presentation.id
        )
    }

    private func refreshStateOwnedDialogue(using snapshot: DialogueVoiceCoordinatorSnapshot) {
        guard player != nil,
              var presentation = stateDialoguePresentation,
              presentation.state == effectivePresentationState else {
            return
        }
        guard !dialogueVoiceCoordinator.isAutomaticPlaybackActive else {
            return
        }
        let selectedLine = presentation.lineID.flatMap { lineID in
            snapshot.library.lines.first { line in
                line.id == lineID && line.state == presentation.state
            }
        } ?? snapshot.library.preferredLine(for: presentation.state)
        if presentation.lineID != selectedLine?.id || presentation.lineRevision != selectedLine?.revision {
            presentation.lineID = selectedLine?.id
            presentation.lineRevision = selectedLine?.revision
            presentation.text = selectedLine?.text
            presentation.audioDisposition = .pending
        }
        stateDialoguePresentation = presentation
        player.view.showDialogueMessage(presentation.text)
        ensureStateOwnedDialoguePlayback()
    }

    private func ensureStateOwnedDialoguePlayback() {
        guard let presentation = stateDialoguePresentation,
              presentation.state == effectivePresentationState else { return }
        applyStateOwnedDialoguePlaybackResult(
            dialogueVoiceCoordinator.ensureAutomaticPlayback(
                for: presentation.state,
                requestID: presentation.id
            ),
            requestID: presentation.id
        )
    }

    private func applyStateOwnedDialoguePlaybackResult(
        _ result: DialoguePlaybackResult,
        requestID: UUID
    ) {
        guard result == .deferred,
              var presentation = stateDialoguePresentation,
              presentation.id == requestID,
              presentation.audioDisposition != .delivered else { return }
        presentation.audioDisposition = .deferred
        stateDialoguePresentation = presentation
        logger.info("event=state_dialogue_deferred state=\(presentation.state.rawValue, privacy: .public)")
    }

    private func markStateOwnedDialogueAudioDelivered(requestID: UUID, line: DialogueLine) {
        guard var presentation = stateDialoguePresentation,
              presentation.id == requestID,
              presentation.state == effectivePresentationState,
              presentation.recordAutomaticPlaybackStarted(line) else {
            return
        }
        stateDialoguePresentation = presentation
        player?.view.showDialogueMessage(line.text)
        logger.info("event=state_dialogue_started state=\(presentation.state.rawValue, privacy: .public)")
    }

    private func finishStateOwnedDialogueAudio(requestID: UUID, lineID: UUID) {
        guard var presentation = stateDialoguePresentation,
              presentation.state == effectivePresentationState else {
            player?.view.showDialogueMessage(nil)
            return
        }
        let selectedLine = dialogueVoiceCoordinator.library.lines.first { line in
            line.id == lineID && line.state == presentation.state
        } ?? dialogueVoiceCoordinator.preferredLine(for: presentation.state)
        switch presentation.recordAutomaticPlaybackFinished(
            requestID: requestID,
            lineID: lineID,
            replacementLine: selectedLine
        ) {
        case .updated:
            stateDialoguePresentation = presentation
            player?.view.showDialogueMessage(presentation.text)
        case .revealCurrent:
            player?.view.showDialogueMessage(presentation.text)
        case .ignored:
            break
        }
    }

    private func selectedEntry(
        for state: PetState,
        advance: Bool,
        useManualPreviewCursor: Bool,
        explicitUserAdvance: Bool = false
    ) -> MediaEntry? {
        guard let playlist = mediaMap.playlist(for: state) else {
            if useManualPreviewCursor {
                manualPreviewSelectionCursor.reset(state: state)
            } else {
                mediaSelectionCursor.reset(state: state)
            }
            return nil
        }
        let eligibility: (MediaEntry) -> Bool = { [mediaMap, mediaMapURL] entry in
            guard let mediaMapURL else { return false }
            let url = mediaMap.resolvedURL(for: entry, relativeTo: mediaMapURL)
            return FileManager.default.isReadableFile(atPath: url.path)
        }
        let selected: MediaEntry?
        if useManualPreviewCursor {
            if explicitUserAdvance {
                selected = manualPreviewSelectionCursor.selectNextExplicitly(
                    for: state,
                    from: playlist,
                    isEligible: eligibility
                )
            } else {
                selected = manualPreviewSelectionCursor.select(
                    for: state,
                    from: playlist,
                    advance: advance,
                    isEligible: eligibility
                )
            }
        } else {
            if explicitUserAdvance {
                selected = mediaSelectionCursor.selectNextExplicitly(
                    for: state,
                    from: playlist,
                    isEligible: eligibility
                )
            } else {
                selected = mediaSelectionCursor.select(
                    for: state,
                    from: playlist,
                    advance: advance,
                    isEligible: eligibility
                )
            }
        }
        if let selected,
           let index = playlist.entries.firstIndex(where: { $0.path == selected.path }) {
            let selectionScope = useManualPreviewCursor ? "manual_preview" : "lifecycle"
            logger.info("event=media_selected state=\(state.rawValue, privacy: .public) mode=\(playlist.mode.rawValue, privacy: .public) index=\(index, privacy: .public) count=\(playlist.entries.count, privacy: .public) advanced=\(advance, privacy: .public) explicit_user_advance=\(explicitUserAdvance, privacy: .public) selection_scope=\(selectionScope, privacy: .public)")
        } else {
            logger.error("event=media_selection_unavailable state=\(state.rawValue, privacy: .public) mode=\(playlist.mode.rawValue, privacy: .public) count=\(playlist.entries.count, privacy: .public)")
        }
        return selected
    }

    private var effectivePresentationState: PetState {
        temporaryStatePreviewPolicy.previewState ?? currentState
    }

    private var reportedProducerState: PetState {
        temporaryStatePreviewPolicy.realState ?? currentState
    }

    private func canAdvanceClip(for state: PetState) -> Bool {
        guard let playlist = mediaMap.playlist(for: state) else { return false }
        let cursor = temporaryStatePreviewPolicy.previewState == nil
            ? mediaSelectionCursor
            : manualPreviewSelectionCursor
        return MediaSelectionCursor.canSelectNextExplicitly(
            currentPath: cursor.selectedPath(for: state),
            from: playlist
        ) { [mediaMap, mediaMapURL] entry in
            guard let mediaMapURL else { return false }
            let url = mediaMap.resolvedURL(for: entry, relativeTo: mediaMapURL)
            return FileManager.default.isReadableFile(atPath: url.path)
        }
    }

    private func advanceCurrentClip(reason: String) {
        let state = effectivePresentationState
        guard canAdvanceClip(for: state) else {
            updateStatusMenu()
            return
        }
        cancelActiveLifecycleTransition(reason: "next_clip")
        cancelActiveOneShotWithoutRestore(reason: "next_clip")
        pendingPresentationState = nil
        logger.info("event=playlist_advance_triggered state=\(state.rawValue, privacy: .public) reason=\(reason, privacy: .public)")
        startLifecyclePresentation(
            state: state,
            advanceSelection: true,
            refreshReason: reason,
            useManualPreviewCursor: temporaryStatePreviewPolicy.previewState != nil,
            explicitUserAdvance: true
        )
    }

    private func selectTemporaryState(_ state: PetState?, reason: String) {
        guard let state else {
            stopTemporaryStatePreview(reason: reason)
            return
        }
        if temporaryStatePreviewPolicy.previewState == state {
            updateStatusMenu()
            return
        }
        if temporaryStatePreviewPolicy.previewState == nil, state == currentState {
            updateStatusMenu()
            return
        }

        cancelActiveLifecycleTransition(reason: "temporary_state_changed")
        cancelActiveOneShotWithoutRestore(reason: "temporary_state_changed")
        if temporaryStatePreviewPolicy.previewState == nil {
            manualPreviewSelectionCursor = mediaSelectionCursor
        }
        lastPresentedState = nil
        pendingPresentationState = nil
        _ = temporaryStatePreviewPolicy.begin(
            previewState: state,
            baselineRealState: temporaryStatePreviewPolicy.realState
        )
        logger.info("event=temporary_state_preview_started preview_state=\(state.rawValue, privacy: .public) reason=\(reason, privacy: .public)")
        startLifecyclePresentation(
            state: state,
            advanceSelection: true,
            refreshReason: "temporary_state_preview",
            useManualPreviewCursor: true
        )
    }

    private func stopTemporaryStatePreview(reason: String) {
        guard let preview = temporaryStatePreviewPolicy.previewState else {
            updateStatusMenu()
            return
        }
        _ = temporaryStatePreviewPolicy.cancel()
        relinquishTemporaryStatePreview(previousPreview: preview, reason: reason)
        startLifecyclePresentation(
            state: currentState,
            advanceSelection: false,
            refreshReason: "follow_codex",
            useManualPreviewCursor: false
        )
    }

    private func relinquishTemporaryStatePreview(
        previousPreview: PetState?,
        reason: String
    ) {
        cancelActiveLifecycleTransition(reason: "temporary_state_relinquished")
        cancelActiveOneShotWithoutRestore(reason: "temporary_state_relinquished")
        lastPresentedState = nil
        pendingPresentationState = nil
        if let previousPreview {
            logger.info("event=temporary_state_preview_stopped preview_state=\(previousPreview.rawValue, privacy: .public) reason=\(reason, privacy: .public)")
        }
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let brandedImage = Bundle.main.url(
            forResource: "StateletMenuBarTemplate",
            withExtension: "pdf"
        ).flatMap(NSImage.init(contentsOf:))
        brandedImage?.isTemplate = true
        brandedImage?.size = NSSize(width: 18, height: 18)
        statusItem.button?.image = brandedImage ?? NSImage(
            systemSymbolName: "sparkles",
            accessibilityDescription: "Statelet"
        )
        statusItem.button?.setAccessibilityLabel("Statelet")
        statusItem.menu = makeMenu()
        player?.view.contextMenuProvider = { [weak self] in self?.statusItem?.menu }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let stateItem = NSMenuItem(title: "State: \(currentState.rawValue)", action: nil, keyEquivalent: "")
        stateItem.tag = StatusMenuTag.state.rawValue
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        let healthItem = NSMenuItem(title: publisherHealth.menuTitle, action: nil, keyEquivalent: "")
        healthItem.tag = StatusMenuTag.publisherHealth.rawValue
        healthItem.isEnabled = false
        menu.addItem(healthItem)
        let characterItem = NSMenuItem(
            title: "Character: \(characterLibrary.activeCharacter.name)",
            action: nil,
            keyEquivalent: ""
        )
        characterItem.tag = StatusMenuTag.character.rawValue
        characterItem.submenu = makeCharacterMenu()
        menu.addItem(characterItem)
        let stopPreviewItem = NSMenuItem(
            title: "Stop Play Once",
            action: #selector(stopOneShotPreviewFromMenu),
            keyEquivalent: ""
        )
        stopPreviewItem.target = self
        stopPreviewItem.tag = StatusMenuTag.stopOneShot.rawValue
        stopPreviewItem.isHidden = true
        menu.addItem(stopPreviewItem)
        let nextClipItem = NSMenuItem(
            title: "Next Clip",
            action: #selector(advanceCurrentClipFromMenu),
            keyEquivalent: "]"
        )
        nextClipItem.target = self
        nextClipItem.tag = StatusMenuTag.nextClip.rawValue
        menu.addItem(nextClipItem)
        let temporaryStateItem = NSMenuItem(title: "Temporary State", action: nil, keyEquivalent: "")
        temporaryStateItem.tag = StatusMenuTag.temporaryState.rawValue
        temporaryStateItem.submenu = makeTemporaryStateMenu()
        menu.addItem(temporaryStateItem)
        menu.addItem(.separator())
        let alwaysOnTopItem = NSMenuItem(
            title: "Keep Statelet on Top",
            action: #selector(toggleAlwaysOnTop),
            keyEquivalent: ""
        )
        alwaysOnTopItem.target = self
        alwaysOnTopItem.tag = StatusMenuTag.alwaysOnTop.rawValue
        alwaysOnTopItem.toolTip = "Turn this off to let other app windows cover Statelet."
        menu.addItem(alwaysOnTopItem)
        let clickItem = NSMenuItem(title: "Click-through", action: #selector(toggleClickThrough), keyEquivalent: "")
        clickItem.target = self
        clickItem.tag = StatusMenuTag.clickThrough.rawValue
        menu.addItem(clickItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem(title: "Reveal media folder", action: #selector(revealMediaFolder), keyEquivalent: ""))
        menu.items.last?.target = self
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Statelet", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    private func makeTemporaryStateMenu() -> NSMenu {
        let menu = NSMenu(title: "Temporary State")
        for state in PetState.allCases {
            let item = NSMenuItem(
                title: state.rawValue.capitalized,
                action: #selector(selectTemporaryStateFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = state.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let followItem = NSMenuItem(
            title: "Follow Codex",
            action: #selector(followCodexFromMenu),
            keyEquivalent: "0"
        )
        followItem.target = self
        followItem.tag = StatusMenuTag.followCodex.rawValue
        menu.addItem(followItem)
        return menu
    }

    private func makeCharacterMenu() -> NSMenu {
        let menu = NSMenu(title: "Character")
        for character in characterLibrary.characters {
            let item = NSMenuItem(
                title: character.name,
                action: #selector(selectCharacterFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = character.id
            item.state = character.id == characterLibrary.activeCharacterID ? .on : .off
            item.isEnabled = !mediaMutationInProgress
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let manage = NSMenuItem(
            title: "Manage Characters…",
            action: #selector(showSettings),
            keyEquivalent: ""
        )
        manage.target = self
        menu.addItem(manage)
        return menu
    }

    private func updateStatusMenu() {
        let stateTitle = statusMenuStateTitle
        let targetState = effectivePresentationState
        let canAdvance = canAdvanceClip(for: targetState)
        let manualPreview = temporaryStatePreviewPolicy.previewState
        let reportedLiveState = manualPreview == nil ? currentState : reportedProducerState
        let healthTitle = publisherHealth.menuTitle(temporaryPreviewActive: manualPreview != nil)
        let menu = statusItem?.menu
        if let stateItem = menu?.item(withTag: StatusMenuTag.state.rawValue) {
            stateItem.title = stateTitle
        }
        if let healthItem = menu?.item(withTag: StatusMenuTag.publisherHealth.rawValue) {
            healthItem.title = healthTitle
        }
        if let characterItem = menu?.item(withTag: StatusMenuTag.character.rawValue) {
            characterItem.title = "Character: \(characterLibrary.activeCharacter.name)"
            characterItem.submenu = makeCharacterMenu()
        }
        if let clickItem = menu?.item(withTag: StatusMenuTag.clickThrough.rawValue) {
            clickItem.state = clickThrough ? .on : .off
        }
        if let alwaysOnTopItem = menu?.item(withTag: StatusMenuTag.alwaysOnTop.rawValue) {
            alwaysOnTopItem.state = effectiveAlwaysOnTop ? .on : .off
        }
        if let stopPreviewItem = menu?.item(withTag: StatusMenuTag.stopOneShot.rawValue) {
            stopPreviewItem.isHidden = activeOneShotPreview == nil
            stopPreviewItem.isEnabled = activeOneShotPreview != nil
        }
        if let nextClipItem = menu?.item(withTag: StatusMenuTag.nextClip.rawValue) {
            nextClipItem.isEnabled = canAdvance
            nextClipItem.toolTip = canAdvance
                ? "Immediately show another playable \(targetState.rawValue) clip"
                : "No different readable \(targetState.rawValue) clip is available"
        }
        if let temporaryStateItem = menu?.item(withTag: StatusMenuTag.temporaryState.rawValue) {
            temporaryStateItem.title = manualPreview.map {
                "Temporary State: \($0.rawValue.capitalized)"
            } ?? "Temporary State: Follow Codex"
            for item in temporaryStateItem.submenu?.items ?? [] {
                if let rawValue = item.representedObject as? String,
                   let state = PetState(rawValue: rawValue) {
                    item.state = manualPreview == state ? .on : .off
                }
            }
            if let followItem = temporaryStateItem.submenu?.item(
                withTag: StatusMenuTag.followCodex.rawValue
            ) {
                followItem.state = manualPreview == nil ? .on : .off
                followItem.isEnabled = manualPreview != nil
            }
        }
        let tooltip = "Statelet — \(characterLibrary.activeCharacter.name) — \(stateTitle) — \(healthTitle)"
        statusItem.button?.toolTip = tooltip
        player?.view.toolTip = tooltip
        player?.updatePublisherHealth(
            publisherHealth.accessibilitySummary(temporaryPreviewActive: manualPreview != nil)
        )
        player?.view.updateStateBadge(
            state: targetState,
            publisherStatus: publisherHealth.badgeVisualStatus
        )
        player?.view.updateQuickControls(
            canAdvanceClip: canAdvance,
            liveState: reportedLiveState,
            displayedState: player?.currentState ?? targetState,
            manualPreview: manualPreview
        )
    }

    private var statusMenuStateTitle: String {
        guard let manualPreview = temporaryStatePreviewPolicy.previewState else {
            return player?.presentationStatus.menuTitle(requestedState: currentState)
                ?? "State: \(currentState.rawValue)"
        }
        let prefix = "Codex: \(reportedProducerState.rawValue) · Preview: \(manualPreview.rawValue)"
        guard let status = player?.presentationStatus else { return prefix }
        switch status {
        case .awaiting, .presented:
            return prefix
        case .preparing:
            return "\(prefix) — preparing"
        case let .previewing(_, clipName):
            return "\(prefix) — playing \(clipName) once"
        case .placeholder:
            return "\(prefix) — media unavailable"
        case let .retained(_, displayed):
            return "\(prefix) — showing \(displayed.rawValue)"
        }
    }

    @objc private func advanceCurrentClipFromMenu() {
        advanceCurrentClip(reason: "menu")
    }

    @objc private func selectCharacterFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        selectCharacter(id: id)
    }

    @objc private func selectTemporaryStateFromMenu(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let state = PetState(rawValue: rawValue) else { return }
        selectTemporaryState(state, reason: "menu")
    }

    @objc private func followCodexFromMenu() {
        selectTemporaryState(nil, reason: "menu")
    }

    @objc private func toggleClickThrough() {
        let previous = clickThrough
        do {
            clickThrough = try ClickThroughPersistenceTransaction.apply(
                current: previous,
                updateRuntime: { [weak self] value in
                    guard let self else { return }
                    self.clickThrough = value
                    self.panel.ignoresMouseEvents = value
                    self.sessionActivityPanel?.ignoresMouseEvents = value
                    self.sessionActivityPanel?.isMovableByWindowBackground = !value
                    self.updateStatusMenu()
                    self.refreshSettings()
                },
                persist: { [weak self] value in
                    try self?.persistRuntimeClickThrough(value)
                }
            )
        } catch {
            logger.error("event=window_setting_save_failed setting=click_through")
            presentSettingsError("Click-through could not be saved.")
        }
        refreshSettings()
    }

    @objc private func toggleAlwaysOnTop() {
        do {
            let window = try mediaMap.window.replacing(alwaysOnTop: !effectiveAlwaysOnTop)
            let updated = try mediaMap.replacingWindow(window)
            try publishMediaMap(updated)
            options.alwaysOnTopOverride = nil
            applyPublishedMediaMap(updated, refreshPlayback: false)
        } catch {
            logger.error("event=window_setting_save_failed setting=always_on_top")
            presentSettingsError("Keep Statelet on Top could not be saved.")
            updateStatusMenu()
            refreshSettings()
        }
    }

    private var effectiveAlwaysOnTop: Bool {
        options?.alwaysOnTopOverride ?? mediaMap.window.alwaysOnTop
    }

    @objc private func showSettings() {
        if settingsController == nil {
            settingsController = makeSettingsController()
            checkConversionTools()
        }
        refreshDiagnosticsSnapshot()
        refreshSettings()
        if let snapshot = updateCoordinator?.snapshot {
            settingsController?.update(update: snapshot)
        }
        settingsController?.show()
    }

    private func makeSettingsController() -> SettingsWindowController {
        let controller = SettingsWindowController()
        controller.onImportMP4 = { [weak self] state in self?.chooseMP4(for: state) }
        controller.onDropMP4s = { [weak self] state, urls in self?.importMP4s(urls, for: state) }
        controller.onUseMovie = { [weak self] state in self?.chooseTransparentMovie(for: state) }
        controller.onImportTransitionMP4 = { [weak self] scope, route in
            self?.chooseTransitionMP4(scope: scope, route: route)
        }
        controller.onMigrateGlobalTransitionLegacy = { [weak self] in
            self?.migrateGlobalTransitionLegacy()
        }
        controller.onUseTransitionMovie = { [weak self] scope, route in
            self?.chooseTransitionMovie(scope: scope, route: route)
        }
        controller.onReplaceTransitionMP4 = { [weak self] scope, route, path in
            self?.chooseTransitionMP4(scope: scope, route: route, replacingPath: path)
        }
        controller.onReplaceTransitionMovie = { [weak self] scope, route, path in
            self?.chooseTransitionMovie(scope: scope, route: route, replacingPath: path)
        }
        controller.onPreviewTransition = { [weak self] scope, route, path in
            self?.previewTransition(scope: scope, route: route, path: path)
        }
        controller.onRemoveTransition = { [weak self] scope, route, path in
            self?.removeTransition(scope: scope, route: route, path: path)
        }
        controller.onMoveTransition = { [weak self] scope, route, path, index in
            self?.moveTransition(scope: scope, route: route, path: path, to: index)
        }
        controller.onTransitionModeChange = { [weak self] scope, route, mode in
            self?.changeTransitionPlaybackMode(scope: scope, route: route, to: mode)
        }
        controller.onSetFixedTransition = { [weak self] scope, route, path in
            self?.setFixedTransition(scope: scope, route: route, path: path)
        }
        controller.onPlaybackModeChange = { [weak self] state, mode in
            self?.changePlaybackMode(for: state, to: mode)
        }
        controller.onAdvanceTriggerChange = { [weak self] state, policy in
            self?.changeAdvancePolicy(for: state, to: policy)
        }
        controller.onMoveMedia = { [weak self] state, path, destinationIndex in
            self?.moveMedia(for: state, path: path, to: destinationIndex)
        }
        controller.onRelinkMedia = { [weak self] state, path in
            self?.relinkMedia(for: state, path: path)
        }
        controller.onPlayOnce = { [weak self] state, path in self?.playOnce(state: state, path: path) }
        controller.onStopPreview = { [weak self] in self?.stopOneShotPreview(reason: "settings") }
        controller.onSetFixed = { [weak self] state, path in self?.setFixedEntry(for: state, path: path) }
        controller.onChoosePoster = { [weak self] state, path in self?.choosePoster(for: state, path: path) }
        controller.onRemovePoster = { [weak self] state, path in self?.removePoster(for: state, path: path) }
        controller.onRevealMedia = { [weak self] state, path in self?.revealMedia(for: state, path: path) }
        controller.onRemoveMedia = { [weak self] state, path, mode in
            self?.removeMedia(for: state, path: path, mode: mode)
        }
        controller.onRevealMediaFolder = { [weak self] in self?.revealMediaFolder() }
        controller.onRevealMap = { [weak self] in self?.revealMediaMap() }
        controller.onRevealLogs = { [weak self] in self?.revealLogsFolder() }
        controller.onRevealApp = { [weak self] in self?.revealApp() }
        controller.onCheckTools = { [weak self] in self?.checkConversionTools() }
        controller.onChoosePython = { [weak self] in self?.choosePythonRuntime() }
        controller.onCancelConversion = { [weak self] in self?.cancelMP4ImportBatch() }
        controller.onRetryFailedMP4s = { [weak self] in self?.retryLastFailedMP4Batch() }
        controller.onConversionProfileChange = { [weak self] profile in
            self?.conversionProfile = profile
            profile.persist()
        }
        controller.onWindowSettingsChange = { [weak self] update in self?.applyWindowSettings(update) }
        controller.onResetPosition = { [weak self] in self?.resetPanelPosition() }
        controller.onSessionActivityAppearanceChange = { [weak self] appearance in
            self?.applySessionActivityAppearance(appearance)
        }
        controller.onResetActivityPosition = { [weak self] in
            self?.resetSessionActivityPanelPosition()
        }
        controller.onRefreshDiagnostics = { [weak self] in self?.refreshDiagnosticsSnapshot() }
        controller.onRepairInstallation = { [weak self] in self?.repairStartupInstallation() }
        controller.onLaunchAtLoginChange = { [weak self] enabled in self?.setLaunchAtLogin(enabled) }
        controller.onCleanUnusedMedia = { [weak self] in self?.cleanUnusedMedia() }
        controller.onCheckForUpdates = { [weak self] in self?.updateCoordinator?.checkNow() }
        controller.onCancelUpdate = { [weak self] in self?.updateCoordinator?.cancel() }
        controller.onInstallUpdate = { [weak self] in self?.updateCoordinator?.installReadyUpdate() }
        controller.onAutomaticInstallChange = { [weak self] enabled in
            self?.updateCoordinator?.setAutomaticInstall(enabled)
        }
        controller.onImportVoiceAsset = { [weak self] kind, draft in
            self?.chooseVoiceAsset(kind: kind, preserving: draft)
        }
        controller.onSaveVoiceProfile = { [weak self] draft in self?.saveVoiceProfile(draft) }
        controller.onRemoveVoiceProfile = { [weak self] profile in self?.confirmVoiceProfileRemoval(profile) }
        controller.onConfigureQwenProfile = { [weak self] in self?.chooseQwenVoiceProfile() }
        controller.onSelectVoiceProvider = { [weak self] provider in
            self?.selectVoiceProvider(provider)
        }
        controller.onRemoveQwenProfile = { [weak self] profile in
            self?.confirmQwenVoiceProfileRemoval(profile)
        }
        controller.onConfigureVoxCPM2Profile = { [weak self] transcript in
            self?.chooseVoxCPM2Snapshot(referenceText: transcript)
        }
        controller.onRemoveVoxCPM2Profile = { [weak self] profile in
            self?.confirmVoxCPM2ProfileRemoval(profile)
        }
        controller.onDialogueVoicePlaybackSettingsChange = { [weak self] settings in
            self?.updateDialogueVoicePlaybackSettings(settings)
        }
        controller.onAddDialogueLine = { [weak self] text, language, state in
            self?.addDialogueLine(text: text, language: language, state: state)
        }
        controller.onUpdateDialogueLine = { [weak self] line, text, language, state in
            self?.updateDialogueLine(line, text: text, language: language, state: state)
        }
        controller.onDeleteDialogueLine = { [weak self] line in self?.confirmDialogueLineDeletion(line) }
        controller.onPreviewDialogueLine = { [weak self] line in self?.previewDialogueLine(line) }
        controller.onRetryDialogueLine = { [weak self] line in self?.retryDialogueLine(line) }
        controller.onRegenerateDialogueLine = { [weak self] line in self?.regenerateDialogueLine(line) }
        controller.onCharacterSelection = { [weak self] id in self?.selectCharacter(id: id) }
        controller.onCreateCharacter = { [weak self] name in self?.createCharacter(name: name) }
        controller.onRenameCharacter = { [weak self] id, name in
            self?.renameCharacter(id: id, name: name)
        }
        controller.onDuplicateCharacter = { [weak self] id, name in
            self?.duplicateCharacter(id: id, name: name)
        }
        controller.onDeleteCharacter = { [weak self] id in self?.deleteCharacter(id: id) }
        controller.onImportCharacterBundle = { [weak self] in self?.chooseCharacterBundle() }
        controller.onExportCharacterBundle = { [weak self] id in self?.exportCharacterBundle(id: id) }
        controller.update(toolchainState: toolchainState)
        controller.update(conversionProfile: conversionProfile)
        controller.update(dialogueVoice: dialogueVoiceCoordinator.snapshot)
        controller.update(sessionActivityAppearance: sessionActivityAppearance)
        if let snapshot = updateCoordinator?.snapshot {
            controller.update(update: snapshot)
        } else if updateRecoveryBlocked {
            controller.update(
                update: StateletUpdateSnapshot(
                    status: StateletUpdaterError.transactionRecoveryRequired.safeStatus,
                    installedVersion: StateletVersion.current().description,
                    candidateVersion: nil,
                    releaseNotes: nil,
                    progress: nil,
                    isChecking: false,
                    isReadyToInstall: false,
                    isScheduledForRestart: false,
                    isBlocked: true,
                    automaticInstallEnabled: false
                )
            )
        }
        if let pendingRecoveryNotice {
            controller.update(activity: .failed(pendingRecoveryNotice.0, pendingRecoveryNotice.1))
        }
        return controller
    }

    private func refreshSettings() {
        guard let settingsController else { return }
        let effectiveMap: MediaMap
        do {
            let effectiveWindow = try mediaMap.window.replacing(
                alwaysOnTop: options?.alwaysOnTopOverride,
                clickThrough: options?.clickThroughOverride
            )
            effectiveMap = try mediaMap.replacingWindow(effectiveWindow)
        } catch {
            effectiveMap = mediaMap
        }
        settingsController.update(
            snapshot: SettingsSnapshot(
                mediaMap: effectiveMap,
                mediaMapURL: mediaMapURL,
                globalTransitionLibrary: globalTransitionLibrary,
                globalTransitionLibraryURL: characterLibraryStorage.globalTransitionLibraryURL,
                publisherSummary: publisherSettingsSummary,
                reduceMotion: reduceMotion,
                currentState: currentState,
                preview: activeOneShotPreview.map {
                    SettingsPreviewMetadata(state: $0.libraryState, path: $0.playback.path)
                },
                diagnosticsReport: cachedDiagnosticsReport,
                launchAtLoginEnabled: cachedLaunchAtLoginStatus?.isEnabled ?? false,
                launchAtLoginSummary: cachedLaunchAtLoginStatus?.summary ?? "Choose Refresh to inspect startup.",
                repairAvailable: cachedLaunchAtLoginStatus?.canRepair ?? false,
                characterProfiles: characterLibrary.characters.map {
                    CharacterProfileSummary(
                        id: $0.id,
                        name: $0.name,
                        clipCount: characterClipCounts[$0.id, default: 0]
                    )
                },
                activeCharacterID: characterLibrary.activeCharacterID
            )
        )
        settingsController.update(toolchainState: toolchainState)
        settingsController.update(dialogueVoice: dialogueVoiceCoordinator.snapshot)
        settingsController.update(sessionActivityAppearance: sessionActivityAppearance)
    }

    private func persistCharacterLibrary(_ updated: CharacterLibrary) throws {
        let data = try characterLibraryStorage.saveCatalog(
            updated,
            expectedData: characterLibraryEncodedData
        )
        characterLibrary = updated
        characterLibraryEncodedData = data
    }

    private func selectCharacter(id: String) {
        guard !mediaMutationInProgress, id != characterLibrary.activeCharacterID,
              let entry = characterLibrary.character(id: id) else { return }
        do {
            let loaded = try characterLibraryStorage.loadMediaMap(for: entry)
            let updated = try characterLibrary.selectingCharacter(id: id)
            try persistCharacterLibrary(updated)
            activateCharacter(entry: entry, map: loaded.map, encodedData: loaded.encodedData)
            settingsController?.update(
                activity: .characterSucceeded("\(entry.name) is now the active character")
            )
            logger.info("event=character_selected")
        } catch {
            settingsController?.update(
                activity: .failed(nil, "Character could not be selected. The previous character remains active.")
            )
            logger.error("event=character_select_failed action=retain_current")
            handleCharacterLibraryReloadRequest()
        }
    }

    private func createCharacter(name: String) {
        guard !mediaMutationInProgress else { return }
        let id = UUID().uuidString.lowercased()
        var createdEntry: CharacterLibraryEntry?
        do {
            let added = try characterLibrary.addingCharacter(id: id, name: name)
            guard let entry = added.character(id: id) else {
                throw PetContractError.invalidValue("new character was not created")
            }
            createdEntry = entry
            let emptyMap = try MediaMap(
                defaultFormat: mediaMap.defaultFormat,
                window: mediaMap.window,
                states: [PetState: StateMediaPlaylist]()
            )
            let encodedMap = try characterLibraryStorage.saveMediaMap(
                emptyMap,
                for: entry,
                expectedData: nil
            )
            do {
                let selected = try added.selectingCharacter(id: id)
                try persistCharacterLibrary(selected)
                activateCharacter(entry: entry, map: emptyMap, encodedData: encodedMap)
            } catch {
                try? FileManager.default.removeItem(
                    at: entry.resolvedMapURL(relativeTo: configuredMediaMapURL)
                )
                throw error
            }
            settingsController?.update(activity: .characterSucceeded("Created \(entry.name)"))
            logger.info("event=character_created")
        } catch {
            if let createdEntry,
               characterLibrary.character(id: createdEntry.id) == nil {
                try? FileManager.default.removeItem(
                    at: createdEntry.resolvedMapURL(relativeTo: configuredMediaMapURL)
                )
            }
            settingsController?.update(activity: .failed(nil, "Character could not be created. Check that its name is unique."))
            logger.error("event=character_create_failed")
        }
    }

    private func renameCharacter(id: String, name: String) {
        guard !mediaMutationInProgress else { return }
        do {
            let updated = try characterLibrary.renamingCharacter(id: id, to: name)
            try persistCharacterLibrary(updated)
            updateStatusMenu()
            refreshSettings()
            settingsController?.update(activity: .characterSucceeded("Character renamed to \(name)"))
            logger.info("event=character_renamed")
        } catch {
            settingsController?.update(activity: .failed(nil, "Character could not be renamed. Check that its name is unique."))
            logger.error("event=character_rename_failed")
        }
    }

    private func duplicateCharacter(id: String, name: String) {
        guard !mediaMutationInProgress, let source = characterLibrary.character(id: id) else { return }
        let newID = UUID().uuidString.lowercased()
        var destination: CharacterLibraryEntry?
        do {
            let loaded = try characterLibraryStorage.loadMediaMap(for: source)
            let added = try characterLibrary.duplicatingCharacter(
                id: id,
                as: newID,
                name: name
            )
            guard let entry = added.character(id: newID) else {
                throw PetContractError.invalidValue("duplicated character was not created")
            }
            destination = entry
            let encoded = try characterLibraryStorage.saveMediaMap(
                loaded.map,
                for: entry,
                expectedData: nil
            )
            do {
                let selected = try added.selectingCharacter(id: newID)
                try persistCharacterLibrary(selected)
                activateCharacter(entry: entry, map: loaded.map, encodedData: encoded)
            } catch {
                try? FileManager.default.removeItem(
                    at: entry.resolvedMapURL(relativeTo: configuredMediaMapURL)
                )
                throw error
            }
            settingsController?.update(activity: .characterSucceeded("Duplicated as \(entry.name)"))
            logger.info("event=character_duplicated")
        } catch {
            if let destination,
               characterLibrary.character(id: destination.id) == nil {
                try? FileManager.default.removeItem(
                    at: destination.resolvedMapURL(relativeTo: configuredMediaMapURL)
                )
            }
            settingsController?.update(activity: .failed(nil, "Character could not be duplicated. Check that its name is unique."))
            logger.error("event=character_duplicate_failed")
        }
    }

    private func deleteCharacter(id: String) {
        guard !mediaMutationInProgress,
              characterLibrary.characters.count > 1,
              characterLibrary.activeCharacterID == id,
              characterLibrary.character(id: id) != nil else { return }
        do {
            let updated = try characterLibrary.removingCharacter(id: id)
            let activeChanged = updated.activeCharacterID != characterLibrary.activeCharacterID
            let replacement: (entry: CharacterLibraryEntry, map: MediaMap, encodedData: Data)?
            if activeChanged {
                let entry = updated.activeCharacter
                let loaded = try characterLibraryStorage.loadMediaMap(for: entry)
                replacement = (entry, loaded.map, loaded.encodedData)
            } else {
                replacement = nil
            }
            try persistCharacterLibrary(updated)
            characterClipCounts[id] = nil
            if let replacement {
                activateCharacter(
                    entry: replacement.entry,
                    map: replacement.map,
                    encodedData: replacement.encodedData
                )
            } else {
                updateStatusMenu()
                refreshSettings()
            }
            settingsController?.update(activity: .characterSucceeded("Character deleted; its media files were kept"))
            logger.info("event=character_deleted files=kept")
        } catch {
            settingsController?.update(activity: .failed(nil, "Character could not be deleted."))
            logger.error("event=character_delete_failed action=retain_current")
        }
    }

    private static var characterBundleType: UTType {
        UTType(
            exportedAs: "com.coke1120.statelet.character-bundle",
            conformingTo: .package
        )
    }

    private func chooseCharacterBundle() {
        guard !mediaMutationInProgress, let window = settingsController?.window else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Statelet Character"
        panel.prompt = "Import Character"
        panel.allowedContentTypes = [Self.characterBundleType]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.confirmCharacterBundleImport(url)
        }
    }

    private func confirmCharacterBundleImport(_ url: URL) {
        guard let window = settingsController?.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Import Character Bundle?"
        alert.informativeText = "Statelet will verify the bundle manifest, every file hash, reports when present, and AVFoundation playback. Legacy reportless clips receive playback checks only and require this explicit trust."
        alert.addButton(withTitle: "Import Character")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.importCharacterBundle(url, allowLegacyTrust: true)
        }
    }

    private func processPendingCharacterBundleOpenIfPossible() {
        guard characterLibraryStorage != nil,
              panel != nil,
              !mediaMutationInProgress,
              let url = pendingCharacterBundleOpenURL else { return }
        pendingCharacterBundleOpenURL = nil
        showSettings()
        DispatchQueue.main.async { [weak self] in
            self?.confirmCharacterBundleImport(url)
        }
    }

    private func importCharacterBundle(_ url: URL, allowLegacyTrust: Bool) {
        guard !mediaMutationInProgress else { return }
        mediaMutationInProgress = true
        settingsController?.update(activity: .characterWorking("Checking character bundle and media…"))
        let storage = characterLibraryStorage!
        let baselineLibrary = characterLibrary
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try storage.stageImport(
                        from: url,
                        against: baselineLibrary,
                        allowLegacyTrust: allowLegacyTrust
                    )
                }
            }.value
            switch result {
            case let .failure(error):
                mediaMutationInProgress = false
                let detail = (error as? CharacterLibraryStorageError)?.localizedDescription
                    ?? "The bundle did not satisfy Statelet's character safety contract."
                settingsController?.update(
                    activity: .failed(nil, "Character bundle was not imported · \(detail)")
                )
                logger.error("event=character_bundle_import_failed")
            case let .success(staged):
                do {
                    let entry = try staged.commit()
                    do {
                        let loaded = try characterLibraryStorage.loadMediaMap(for: entry)
                        let added = try characterLibrary.addingCharacter(
                            id: entry.id,
                            name: entry.name
                        )
                        let selected = try added.selectingCharacter(id: entry.id)
                        try persistCharacterLibrary(selected)
                        activateCharacter(
                            entry: entry,
                            map: loaded.map,
                            encodedData: loaded.encodedData
                        )
                        staged.finalize()
                        mediaMutationInProgress = false
                        settingsController?.update(
                            activity: .characterSucceeded("Imported and activated \(entry.name)")
                        )
                        logger.info("event=character_bundle_imported")
                    } catch {
                        staged.rollback()
                        throw error
                    }
                } catch {
                    staged.discard()
                    mediaMutationInProgress = false
                    settingsController?.update(
                        activity: .failed(nil, "Character bundle could not be installed. The library was not changed.")
                    )
                    logger.error("event=character_bundle_install_failed action=rollback")
                }
            }
        }
    }

    private func exportCharacterBundle(id: String) {
        guard !mediaMutationInProgress,
              let entry = characterLibrary.character(id: id),
              let window = settingsController?.window else { return }
        let panel = NSSavePanel()
        panel.title = "Export Statelet Character"
        panel.prompt = "Export Character"
        panel.allowedContentTypes = [Self.characterBundleType]
        panel.canCreateDirectories = true
        let safeName = entry.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(safeName).statelet-character"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            self.mediaMutationInProgress = true
            self.settingsController?.update(
                activity: .characterWorking("Exporting \(entry.name)…")
            )
            let storage = self.characterLibraryStorage!
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try storage.exportCharacter(entry, to: destination) }
                }.value
                self.mediaMutationInProgress = false
                switch result {
                case .success:
                    self.settingsController?.update(
                        activity: .characterSucceeded("Exported \(entry.name)")
                    )
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                    self.logger.info("event=character_bundle_exported")
                case .failure:
                    self.settingsController?.update(
                        activity: .failed(nil, "Character bundle could not be exported. No partial bundle was kept.")
                    )
                    self.logger.error("event=character_bundle_export_failed")
                }
            }
        }
    }

    private var publisherSettingsSummary: String {
        let stateName = currentState.rawValue.capitalized
        if let manualPreview = temporaryStatePreviewPolicy.previewState {
            return "\(publisherHealth.menuTitle(temporaryPreviewActive: true)) · Codex state: \(reportedProducerState.rawValue.capitalized) · Temporary preview: \(manualPreview.rawValue.capitalized)"
        }
        switch publisherHealth {
        case .live:
            return "Lifecycle connected · Current state: \(stateName)"
        case .manual:
            return "Manual preview · Current state: \(stateName)"
        case .unknown:
            return "Lifecycle status is being checked"
        case .stale:
            return "Lifecycle updates are stale · Showing Idle"
        case .missing:
            return "Lifecycle publisher unavailable · Showing Idle"
        case .corrupt:
            return "Lifecycle data is invalid · Showing Idle"
        case .futureSkew:
            return "Lifecycle clock is invalid · Showing Idle"
        }
    }

    private func checkConversionTools() {
        toolchainState = .checking
        settingsController?.update(toolchainState: .checking)
        toolchainDiscovery.discover { [weak self] state in
            guard let self else { return }
            self.toolchainState = state
            self.settingsController?.update(toolchainState: state)
        }
    }

    private func choosePythonRuntime() {
        guard let settingsWindow = settingsController?.window else { return }
        let openPanel = NSOpenPanel()
        openPanel.title = "Choose Python 3"
        openPanel.message = "Choose a Python executable that can import NumPy and Pillow. Statelet stores this local path in its preferences."
        openPanel.prompt = "Use Python"
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.beginSheetModal(for: settingsWindow) { [weak self] response in
            guard response == .OK, let url = openPanel.url else { return }
            UserDefaults.standard.set(
                url.standardizedFileURL.path,
                forKey: AlphaToolchainDiscovery.configuredPythonDefaultsKey
            )
            self?.checkConversionTools()
        }
    }

    private func chooseVoiceAsset(
        kind: DialogueVoiceAssetKind,
        preserving draft: DialogueVoiceProfileDraft
    ) {
        guard let settingsWindow = settingsController?.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        switch kind {
        case .gptWeight:
            panel.title = "Import GPT Weight"
            panel.message = "Choose a trusted GPT-SoVITS .ckpt file. Model files can execute code when loaded by their runtime; only import files you trust."
            panel.prompt = "Import GPT Weight"
            panel.allowedContentTypes = [UTType(filenameExtension: "ckpt") ?? .data]
        case .sovitsWeight:
            panel.title = "Import SoVITS Weight"
            panel.message = "Choose a trusted GPT-SoVITS .pth file. Model files can execute code when loaded by their runtime; only import files you trust."
            panel.prompt = "Import SoVITS Weight"
            panel.allowedContentTypes = [UTType(filenameExtension: "pth") ?? .data]
        case .referenceAudio:
            panel.title = "Import Reference Audio"
            panel.message = "Choose reference audio that you own or are authorized to use. Statelet keeps a private local copy."
            panel.prompt = "Import Reference Audio"
            panel.allowedContentTypes = [.audio]
        case .voxcpm2ReferenceAudio:
            panel.title = "Import VoxCPM2 Reference Audio"
            panel.message = "Choose a trusted WAV that you own or are authorized to use."
            panel.prompt = "Import Reference Audio"
            panel.allowedContentTypes = [.wav]
        }
        panel.beginSheetModal(for: settingsWindow) { [weak self] response in
            guard response == .OK, let sourceURL = panel.url else { return }
            self?.dialogueVoiceCoordinator.importAsset(
                sourceURL: sourceURL,
                kind: kind,
                preserving: draft
            )
        }
    }

    private func saveVoiceProfile(_ draft: DialogueVoiceProfileDraft) {
        guard dialogueVoiceCoordinator.library.profile != nil,
              let settingsWindow = settingsController?.window else {
            persistVoiceProfile(draft)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Replace the active voice profile?"
        alert.informativeText = "Saving this profile invalidates all generated dialogue audio. Statelet keeps the dialogue text, validates the replacement profile, then queues fresh background generation."
        alert.addButton(withTitle: "Save and Regenerate")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: settingsWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.persistVoiceProfile(draft)
        }
    }

    private func persistVoiceProfile(_ draft: DialogueVoiceProfileDraft) {
        do {
            try dialogueVoiceCoordinator.saveProfile(draft)
        } catch {
            presentSettingsError(error.localizedDescription)
        }
    }

    private func confirmVoiceProfileRemoval(_ profile: GPTSoVITSVoiceProfile) {
        guard let settingsWindow = settingsController?.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove \(profile.name)?"
        alert.informativeText = "Statelet will remove its managed model files, reference audio, and generated speech. Dialogue text will be kept as drafts."
        alert.addButton(withTitle: "Remove Voice Profile")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: settingsWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try self?.dialogueVoiceCoordinator.removeProfile()
            } catch {
                self?.presentSettingsError(error.localizedDescription)
            }
        }
    }

    private func chooseQwenVoiceProfile() {
        guard let settingsWindow = settingsController?.window else { return }
        let packagePanel = NSOpenPanel()
        packagePanel.title = "Import Qwen3-TTS Handover"
        packagePanel.message = "Choose a trusted self-contained Qwen3-TTS handover folder. Statelet copies it into private local storage; the model and reference audio are never added to the app or diagnostics."
        packagePanel.prompt = "Choose Handover"
        packagePanel.canChooseFiles = false
        packagePanel.canChooseDirectories = true
        packagePanel.allowsMultipleSelection = false
        packagePanel.beginSheetModal(for: settingsWindow) { [weak self] response in
            guard response == .OK, let packageURL = packagePanel.url else { return }
            self?.chooseQwenPythonRuntime(for: packageURL)
        }
    }

    private func chooseQwenPythonRuntime(for packageURL: URL) {
        guard let settingsWindow = settingsController?.window else { return }
        let pythonPanel = NSOpenPanel()
        pythonPanel.title = "Choose Qwen Python Runtime"
        pythonPanel.message = "Choose the Python executable from a trusted local environment that provides MLX Audio. Statelet pins the launcher and interpreter identity before generation."
        pythonPanel.prompt = "Use Runtime"
        pythonPanel.canChooseFiles = true
        pythonPanel.canChooseDirectories = false
        pythonPanel.allowsMultipleSelection = false
        // Preserve a virtual environment launcher symlink so Python discovers
        // that environment's site-packages. Runtime validation separately pins
        // both the launcher and its final interpreter identity.
        pythonPanel.resolvesAliases = false
        pythonPanel.beginSheetModal(for: settingsWindow) { [weak self] response in
            guard response == .OK, let pythonURL = pythonPanel.url else { return }
            self?.dialogueVoiceCoordinator.configureQwenProfile(
                sourceURL: packageURL,
                pythonExecutableURL: pythonURL
            )
        }
    }

    private func chooseVoxCPM2Snapshot(referenceText: String) {
        guard let window = settingsController?.window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose VoxCPM2 Snapshot"
        panel.message = "Choose a trusted complete openbmb/VoxCPM2 snapshot. Statelet copies and fingerprints it in private managed storage and never uploads or bundles it."
        panel.prompt = "Use Snapshot"; panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let snapshot = panel.url else { return }
            self?.chooseVoxCPM2Reference(snapshotURL: snapshot, referenceText: referenceText)
        }
    }

    private func chooseVoxCPM2Reference(snapshotURL: URL, referenceText: String) {
        guard let window = settingsController?.window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose VoxCPM2 Reference WAV"
        panel.message = "Choose one trusted reference WAV that you own or may use. Statelet keeps a private managed copy."
        panel.prompt = "Use Reference"; panel.allowedContentTypes = [.wav]
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let reference = panel.url else { return }
            self?.chooseVoxCPM2Python(snapshotURL: snapshotURL, referenceURL: reference, referenceText: referenceText)
        }
    }

    private func chooseVoxCPM2Python(snapshotURL: URL, referenceURL: URL, referenceText: String) {
        guard let window = settingsController?.window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose VoxCPM2 Python Runtime"
        panel.message = "Choose a trusted Python executable whose environment provides voxcpm, PyTorch, and soundfile."
        panel.prompt = "Use Runtime"; panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.resolvesAliases = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let python = panel.url else { return }
            self?.dialogueVoiceCoordinator.configureVoxCPM2Profile(
                snapshotURL: snapshotURL, referenceAudioURL: referenceURL,
                referenceText: referenceText, pythonExecutableURL: python
            )
        }
    }

    private func confirmVoxCPM2ProfileRemoval(_ profile: VoxCPM2VoiceProfile) {
        guard let window = settingsController?.window else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Remove \(profile.name)?"
        alert.informativeText = "Statelet removes its managed snapshot, reference, and generated speech. The selected source folder, dialogue text, and other providers remain untouched."
        alert.addButton(withTitle: "Remove VoxCPM2 Profile"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            do { try self?.dialogueVoiceCoordinator.removeProfile(provider: .voxcpm2) }
            catch { self?.presentSettingsError(error.localizedDescription) }
        }
    }

    private func selectVoiceProvider(_ provider: DialogueVoiceProviderKind) {
        do {
            try dialogueVoiceCoordinator.selectActiveProvider(provider)
        } catch {
            presentSettingsError(error.localizedDescription)
        }
    }

    private func confirmQwenVoiceProfileRemoval(_ profile: Qwen3TTSVoiceProfile) {
        guard let settingsWindow = settingsController?.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove \(profile.name)?"
        alert.informativeText = "Statelet will remove its private managed Qwen package and generated speech. Dialogue text and any separately configured GPT-SoVITS profile will be kept."
        alert.addButton(withTitle: "Remove Qwen Profile")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: settingsWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try self?.dialogueVoiceCoordinator.removeProfile(provider: .qwen3TTS)
            } catch {
                self?.presentSettingsError(error.localizedDescription)
            }
        }
    }

    private func addDialogueLine(text: String, language: String, state: PetState) {
        do {
            try dialogueVoiceCoordinator.addLine(text: text, language: language, state: state)
        } catch {
            presentSettingsError(error.localizedDescription)
        }
    }

    private func updateDialogueVoicePlaybackSettings(
        _ settings: DialogueVoicePlaybackSettings
    ) {
        do {
            try dialogueVoiceCoordinator.updatePlaybackSettings(settings)
        } catch {
            presentSettingsError(error.localizedDescription)
        }
    }

    private func updateDialogueLine(
        _ line: DialogueLine,
        text: String,
        language: String,
        state: PetState
    ) {
        do {
            try dialogueVoiceCoordinator.updateLine(
                id: line.id,
                text: text,
                language: language,
                state: state
            )
        } catch {
            presentSettingsError(error.localizedDescription)
        }
    }

    private func confirmDialogueLineDeletion(_ line: DialogueLine) {
        guard let settingsWindow = settingsController?.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete this dialogue line?"
        alert.informativeText = "The saved text and generated audio will be removed."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: settingsWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try self?.dialogueVoiceCoordinator.deleteLine(id: line.id)
            } catch {
                self?.presentSettingsError(error.localizedDescription)
            }
        }
    }

    private func previewDialogueLine(_ line: DialogueLine) {
        do {
            try dialogueVoiceCoordinator.previewLine(id: line.id)
        } catch {
            presentSettingsError(error.localizedDescription)
        }
    }

    private func retryDialogueLine(_ line: DialogueLine) {
        do {
            try dialogueVoiceCoordinator.retryLine(id: line.id)
        } catch {
            presentSettingsError(error.localizedDescription)
        }
    }

    private func regenerateDialogueLine(_ line: DialogueLine) {
        do {
            try dialogueVoiceCoordinator.regenerateLine(id: line.id)
        } catch {
            presentSettingsError(error.localizedDescription)
        }
    }

    private func chooseMP4(for state: PetState) {
        guard !mediaMutationInProgress else { return }
        guard let settingsWindow = settingsController?.window else { return }
        guard toolchainState.isReady else {
            presentSettingsError("Conversion tools aren’t ready. Use Setup Guide, then Check Again.")
            return
        }
        let openPanel = NSOpenPanel()
        openPanel.title = "Import MP4s for \(state.rawValue.capitalized)"
        openPanel.message = "Background removal, encoding, and verification run entirely on this Mac. Only use media you own or are authorized to use."
        openPanel.prompt = "Import MP4s"
        openPanel.allowedContentTypes = [.mpeg4Movie]
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.beginSheetModal(for: settingsWindow) { [weak self] response in
            guard response == .OK, !openPanel.urls.isEmpty else { return }
            self?.importMP4s(openPanel.urls, for: state)
        }
    }

    private func transitionActivityState(for route: SettingsTransitionRoute) -> PetState {
        route.destination ?? currentState
    }

    private func transitionStates(
        for route: SettingsTransitionRoute
    ) -> (source: PetState, destination: PetState)? {
        guard case let .directional(source, destination) = route else { return nil }
        return (source, destination)
    }

    private func migrateGlobalTransitionLegacy() {
        guard !mediaMutationInProgress,
              globalTransitionLibrary.requiresLegacyMigration,
              let settingsWindow = settingsController?.window else { return }

        let routes = globalTransitionLibrary.transitions.keys.sorted {
            $0.storageKey < $1.storageKey
        }
        guard !routes.isEmpty else { return }

        let popup = NSPopUpButton(
            frame: NSRect(x: 0, y: 0, width: 360, height: 26),
            pullsDown: false
        )
        popup.setAccessibilityLabel("Legacy Global transition to use")
        for route in routes {
            guard let playlist = globalTransitionLibrary.transitions[route] else { continue }
            popup.addItem(
                withTitle: "\(route.from.displayName) → \(route.to.displayName) · \(playlist.entries.count) variants · \(playlist.mode.rawValue.capitalized)"
            )
            popup.lastItem?.representedObject = route.storageKey
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Resolve legacy Global transitions?"
        alert.informativeText = "Choose one preserved route playlist as the universal Global fallback. All legacy route-specific playlists and their media remain in the library for recovery; only this explicit choice changes runtime fallback behavior."
        alert.accessoryView = popup
        alert.addButton(withTitle: "Use Selected as Universal")
        alert.addButton(withTitle: "Cancel")
        let expectedLibrary = globalTransitionLibrary
        let expectedData = globalTransitionLibraryEncodedData
        alert.beginSheetModal(for: settingsWindow) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn,
                  let storageKey = popup.selectedItem?.representedObject as? String,
                  let route = try? StateTransitionKey(storageKey: storageKey) else { return }
            guard !self.mediaMutationInProgress,
                  self.globalTransitionLibrary == expectedLibrary,
                  self.globalTransitionLibraryEncodedData == expectedData else {
                self.settingsController?.update(
                    activity: .failed(self.currentState, "The Global transition library changed before migration. Nothing was changed.")
                )
                return
            }
            do {
                let updated = try self.globalTransitionLibrary.migratingLegacyToUniversal(using: route)
                try self.publishGlobalTransitionLibrary(updated)
                self.applyPublishedGlobalTransitionLibrary(updated)
                self.settingsController?.update(
                    activity: .succeeded(self.currentState, "Global legacy transitions resolved")
                )
            } catch {
                self.settingsController?.update(activity: .failed(self.currentState, error.localizedDescription))
            }
        }
    }

    private func chooseTransitionMP4(
        scope: TransitionLibraryScope,
        route: SettingsTransitionRoute,
        replacingPath: String? = nil
    ) {
        guard !mediaMutationInProgress, let settingsWindow = settingsController?.window else { return }
        guard toolchainState.isReady else {
            presentSettingsError("Conversion tools aren’t ready. Use Setup Guide, then Check Again.")
            return
        }
        let openPanel = NSOpenPanel()
        openPanel.title = "Import \(route.displayName) MP4"
        openPanel.prompt = "Import Transition"
        openPanel.allowedContentTypes = [.mpeg4Movie]
        openPanel.allowsMultipleSelection = replacingPath == nil && !route.isSameState
        openPanel.canChooseDirectories = false
        openPanel.beginSheetModal(for: settingsWindow) { [weak self] response in
            guard response == .OK, !openPanel.urls.isEmpty else { return }
            self?.importTransitionMP4s(openPanel.urls, scope: scope, route: route, replacingPath: replacingPath)
        }
    }

    private func chooseTransitionMovie(
        scope: TransitionLibraryScope,
        route: SettingsTransitionRoute,
        replacingPath: String? = nil
    ) {
        guard !mediaMutationInProgress, let settingsWindow = settingsController?.window else { return }
        let openPanel = NSOpenPanel()
        openPanel.title = "Choose \(route.displayName) Transition"
        openPanel.prompt = "Import Transition"
        openPanel.allowedContentTypes = [.quickTimeMovie]
        openPanel.allowsMultipleSelection = replacingPath == nil && !route.isSameState
        openPanel.canChooseDirectories = false
        openPanel.beginSheetModal(for: settingsWindow) { [weak self] response in
            guard response == .OK, !openPanel.urls.isEmpty else { return }
            self?.confirmPortableTransitionImport(openPanel.urls, scope: scope, route: route, replacingPath: replacingPath)
        }
    }

    private func confirmPortableTransitionImport(
        _ urls: [URL],
        scope: TransitionLibraryScope,
        route: SettingsTransitionRoute,
        replacingPath: String?
    ) {
        guard let window = settingsController?.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Trust portable verification for this transition?"
        alert.informativeText = "Statelet will verify the report hash, transparency, duration, and AVFoundation playback, but cannot prove the report was produced on this Mac."
        alert.addButton(withTitle: "Import Portable MOV")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.importTransitionMovies(urls, scope: scope, route: route, replacingPath: replacingPath)
        }
    }

    private func importTransitionMovies(
        _ sourceURLs: [URL],
        scope: TransitionLibraryScope,
        route: SettingsTransitionRoute,
        replacingPath: String?
    ) {
        guard !mediaMutationInProgress else { return }
        let destination = transitionActivityState(for: route)
        mediaMutationInProgress = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            var importedCount = 0
            for sourceURL in sourceURLs {
                var installedDirectoryToRemove: URL?
                do {
                    let installed = try await prepareVerifiedMovie(sourceURL, allowPortableClaim: true)
                    installedDirectoryToRemove = installed.directory
                    let duration = installed.validation.durationSeconds
                    guard duration.isFinite, duration > 0,
                          duration <= LifecycleTransitionMediaPolicy.maximumDuration else {
                        throw PetContractError.invalidValue("Transition movies must be no longer than \(LifecycleTransitionMediaPolicy.maximumDuration) seconds.")
                    }
                    try Self.requireValidatedFilesUnchanged(
                        installed.validation,
                        outputURL: installed.movieURL,
                        reportURL: installed.reportURL
                    )
                    let entry = try MediaEntry(path: installed.relativePath, loop: false)
                    do {
                        try updateTransitionLibrary(
                            scope: scope,
                            adding: entry,
                            route: route,
                            replacingPath: replacingPath
                        )
                        importedCount += 1
                        installedDirectoryToRemove = nil
                    } catch {
                        try? FileManager.default.removeItem(at: installed.directory)
                        throw error
                    }
                } catch {
                    if let installedDirectoryToRemove {
                        try? FileManager.default.removeItem(at: installedDirectoryToRemove)
                    }
                    settingsController?.update(activity: .failed(destination, error.localizedDescription))
                    if replacingPath != nil { break }
                }
            }
            if importedCount > 0 {
                let message = importedCount == 1 ? "Transition imported" : "\(importedCount) transitions imported"
                settingsController?.update(activity: .succeeded(destination, message))
            }
            mediaMutationInProgress = false
            refreshSettings()
        }
    }

    private func updateTransitionLibrary(
        scope: TransitionLibraryScope,
        adding entry: MediaEntry,
        route: SettingsTransitionRoute,
        replacingPath: String?
    ) throws {
        switch scope {
        case .character:
            guard let states = transitionStates(for: route) else {
                throw PetContractError.invalidValue("Global route cannot be edited in Character scope")
            }
            let source = states.source
            let destination = states.destination
            let updated: MediaMap
            if source == destination {
                updated = try mediaMap.settingInStateTransition(for: source, entry: entry)
            } else {
                updated = try replacingPath.map {
                    try mediaMap.replacingTransitionEntry(
                        from: source, to: destination, path: $0, with: entry
                    )
                } ?? mediaMap.appendingTransitionEntry(entry, from: source, to: destination)
            }
            try publishMediaMap(updated)
            applyPublishedMediaMap(updated)
        case .global:
            guard route == .global else {
                throw PetContractError.invalidValue("Global scope uses one universal transition route")
            }
            let updated = try replacingPath.map {
                try globalTransitionLibrary.replacingUniversalTransitionEntry(path: $0, with: entry)
            } ?? globalTransitionLibrary.appendingUniversalTransitionEntry(entry)
            try publishGlobalTransitionLibrary(updated)
            applyPublishedGlobalTransitionLibrary(updated)
        }
    }

    private func importTransitionMP4s(
        _ sourceURLs: [URL],
        scope: TransitionLibraryScope,
        route: SettingsTransitionRoute,
        replacingPath: String?
    ) {
        let orderedURLs = replacingPath == nil && !route.isSameState ? sourceURLs : Array(sourceURLs.prefix(1))
        guard let first = orderedURLs.first else { return }
        importTransitionMP4(first, scope: scope, route: route, replacingPath: replacingPath) { [weak self] _ in
            guard replacingPath == nil else { return }
            self?.importTransitionMP4s(
                Array(orderedURLs.dropFirst()),
                scope: scope,
                route: route,
                replacingPath: nil
            )
        }
    }

    private func importTransitionMP4(
        _ sourceURL: URL,
        scope: TransitionLibraryScope,
        route: SettingsTransitionRoute,
        replacingPath: String?,
        completion: @escaping (Bool) -> Void
    ) {
        let destination = transitionActivityState(for: route)
        guard !mediaMutationInProgress else {
            settingsController?.update(
                activity: .failed(destination, "Transition import unavailable · wait for the current media operation to finish")
            )
            completion(false)
            return
        }
        guard case let .ready(toolchain) = toolchainState else {
            completion(false)
            return
        }
        switch MP4ImportURLValidator.validate([sourceURL]) {
        case let .rejected(reason):
            settingsController?.update(activity: .failed(destination, reason))
            completion(false)
        case let .accepted(urls, _):
            guard let validatedSource = urls.first else {
                completion(false)
                return
            }
            do { try prepareMediaDirectory() } catch {
                settingsController?.update(activity: .failed(destination, "Statelet couldn’t prepare the Media folder."))
                completion(false)
                return
            }
            mediaMutationInProgress = true
            let conversionID = UUID()
            activeTransitionConversionID = conversionID
            transitionConversionCancellationRequested = false
            let token = versionToken()
            let outputName: String
            if let states = transitionStates(for: route) {
                outputName = "transition-\(states.source.rawValue)-to-\(states.destination.rawValue)-\(token).mov"
            } else {
                outputName = "transition-global-\(token).mov"
            }
            let outputURL = mediaMapURL.deletingLastPathComponent().appendingPathComponent(outputName)
            let reportURL = outputURL.deletingPathExtension().appendingPathExtension("report.json")
            activeTransitionConversionDestination = destination
            let challenge: String
            do {
                challenge = try Self.makeInvocationChallenge()
                try writeConversionJournal(
                    ActiveConversionJournal(
                        state: destination.rawValue,
                        characterID: scope == .character ? characterLibrary.activeCharacterID : nil,
                        mediaMapBasename: scope == .character ? mediaMapURL.lastPathComponent : nil,
                        mediaMapSHA256: scope == .character ? try currentMediaMapSHA256() : nil,
                        outputBasename: outputURL.lastPathComponent,
                        reportBasename: reportURL.lastPathComponent,
                        invocationChallenge: challenge,
                        transitionFrom: transitionStates(for: route)?.source.rawValue,
                        transitionTo: transitionStates(for: route)?.destination.rawValue,
                        transitionScope: scope,
                        globalTransitionLibrarySHA256: scope == .global
                            ? currentGlobalTransitionLibrarySHA256()
                            : nil
                    )
                )
            } catch {
                activeTransitionConversionID = nil
                activeTransitionConversionDestination = nil
                transitionConversionCancellationRequested = false
                mediaMutationInProgress = false
                settingsController?.update(activity: .failed(destination, "Statelet could not prepare transition conversion."))
                completion(false)
                return
            }
            conversionCoordinator.convert(
                sourceURL: validatedSource,
                outputURL: outputURL,
                reportURL: reportURL,
                width: AlphaAuthoringCanvas.width,
                height: AlphaAuthoringCanvas.height,
                toolchain: toolchain,
                invocationChallenge: challenge,
                profile: conversionProfile,
                allowEmptyFrames: true,
                phase: { [weak self] phase in
                    guard let self,
                          self.activeTransitionConversionID == conversionID,
                          !self.transitionConversionCancellationRequested else { return }
                    self.settingsController?.update(activity: .converting(destination, phase))
                },
                progress: { [weak self] progress in
                    guard let self,
                          self.activeTransitionConversionID == conversionID,
                          !self.transitionConversionCancellationRequested else { return }
                    self.settingsController?.update(
                        activity: .converting(destination, progress.message),
                        progressValue: progress.percent
                    )
                },
                completion: { [weak self] result in
                    guard let self else { return }
                    Task { @MainActor in
                        guard self.activeTransitionConversionID == conversionID else {
                            try? FileManager.default.removeItem(at: outputURL)
                            try? FileManager.default.removeItem(at: reportURL)
                            completion(false)
                            return
                        }
                        if self.transitionConversionCancellationRequested {
                            let outputAbsent = self.removeCancelledTransitionArtifact(outputURL)
                            let reportAbsent = self.removeCancelledTransitionArtifact(reportURL)
                            guard outputAbsent, reportAbsent else {
                                self.settingsController?.update(
                                    activity: .failed(
                                        destination,
                                        "Transition cancellation cleanup could not be verified. Restart Statelet to recover safely."
                                    )
                                )
                                self.refreshSettings()
                                completion(false)
                                return
                            }
                            guard self.removeCancelledTransitionArtifact(self.conversionJournalURL) else {
                                self.settingsController?.update(
                                    activity: .failed(
                                        destination,
                                        "Transition recovery record could not be cleared. Restart Statelet to recover safely."
                                    )
                                )
                                self.refreshSettings()
                                completion(false)
                                return
                            }
                            self.activeTransitionConversionID = nil
                            self.activeTransitionConversionDestination = nil
                            self.transitionConversionCancellationRequested = false
                            self.mediaMutationInProgress = false
                            self.settingsController?.update(
                                activity: .failed(destination, "Transition conversion cancelled")
                            )
                            self.refreshSettings()
                            completion(false)
                            return
                        }
                        var succeeded = false
                        do {
                            let conversion = try result.get()
                            let validation = try Self.validateLocallyAttestedMovie(
                                outputURL: conversion.outputURL,
                                reportURL: conversion.reportURL,
                                expectedOutputBasename: conversion.outputURL.lastPathComponent,
                                invocationChallenge: challenge,
                                expectedInitialReportData: conversion.reportData
                            )
                            let duration = validation.durationSeconds
                            guard duration.isFinite, duration > 0,
                                  duration <= LifecycleTransitionMediaPolicy.maximumDuration else {
                                throw PetContractError.invalidValue("Transition movies must be no longer than \(LifecycleTransitionMediaPolicy.maximumDuration) seconds.")
                            }
                            try Self.requireValidatedFilesUnchanged(
                                validation,
                                outputURL: conversion.outputURL,
                                reportURL: conversion.reportURL
                            )
                            let entry = try MediaEntry(path: conversion.outputURL.lastPathComponent, loop: false)
                            try self.updateTransitionLibrary(
                                scope: scope,
                                adding: entry,
                                route: route,
                                replacingPath: replacingPath
                            )
                            self.clearConversionJournal()
                            self.settingsController?.update(activity: .succeeded(destination, "Transition imported"))
                            succeeded = true
                        } catch {
                            try? FileManager.default.removeItem(at: outputURL)
                            try? FileManager.default.removeItem(at: reportURL)
                            self.clearConversionJournal()
                            self.settingsController?.update(activity: .failed(destination, error.localizedDescription))
                        }
                        self.activeTransitionConversionID = nil
                        self.activeTransitionConversionDestination = nil
                        self.transitionConversionCancellationRequested = false
                        self.mediaMutationInProgress = false
                        self.refreshSettings()
                        completion(succeeded)
                    }
                }
            )
        }
    }

    private func previewTransition(
        scope: TransitionLibraryScope,
        route: SettingsTransitionRoute,
        path: String
    ) {
        guard !reduceMotion else { return }
        let destination = transitionActivityState(for: route)
        let entry: MediaEntry?
        let libraryURL: URL
        switch scope {
        case .character:
            guard let states = transitionStates(for: route) else { return }
            entry = states.source == states.destination
                ? mediaMap.inStateTransition(for: states.source)
                : mediaMap.transitionPlaylist(from: states.source, to: states.destination)?.entry(path: path)
            libraryURL = mediaMapURL
        case .global:
            guard route == .global else { return }
            entry = globalTransitionLibrary.universalPlaylist?.entry(path: path)
            libraryURL = characterLibraryStorage.globalTransitionLibraryURL
        }
        guard let entry else { return }
        cancelActiveLifecycleTransition(reason: "transition_preview")
        cancelActiveOneShotWithoutRestore(reason: "transition_preview")
        let transitionID = beginTransition()
        let url = mediaMap.resolvedURL(for: entry, relativeTo: libraryURL)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            settingsController?.update(
                activity: .failed(destination, "The transition movie is missing or unreadable.")
            )
            apply(state: currentState, forceRefresh: true)
            return
        }
        let oneShot = try? MediaEntry(path: entry.path, posterPath: entry.posterPath, loop: false, playbackRate: entry.playbackRate.value)
        guard let oneShot else { return }
        guard let playback = try? oneShotArbiter.start(state: currentState, path: entry.path) else { return }
        activeOneShotPreview = ActiveOneShotPreview(
            playback: playback,
            libraryState: destination,
            transitionID: transitionID
        )
        let result = player.show(
            state: effectivePresentationState,
            entry: oneShot,
            url: url,
            posterURL: nil,
            transitionID: transitionID,
            startedAt: DispatchTime.now().uptimeNanoseconds,
            previewName: url.lastPathComponent,
            notifyWhenEnded: true
        )
        if result == .failed {
            _ = oneShotArbiter.cancel(token: playback.token)
            activeOneShotPreview = nil
            apply(state: currentState, forceRefresh: true)
        }
    }

    private func characterRouteContains(_ route: SettingsTransitionRoute, path: String) -> Bool {
        guard let states = transitionStates(for: route) else { return false }
        return states.source == states.destination
            ? mediaMap.inStateTransition(for: states.source)?.path == path
            : mediaMap.transitionPlaylist(from: states.source, to: states.destination)?.entry(path: path) != nil
    }

    private func removeTransition(
        scope: TransitionLibraryScope,
        route: SettingsTransitionRoute,
        path: String
    ) {
        let destination = transitionActivityState(for: route)
        let entryExists: Bool
        switch scope {
        case .character:
            guard let states = transitionStates(for: route) else { return }
            entryExists = states.source == states.destination
                ? mediaMap.inStateTransition(for: states.source)?.path == path
                : mediaMap.transitionPlaylist(from: states.source, to: states.destination)?.entry(path: path) != nil
        case .global:
            guard route == .global else { return }
            entryExists = globalTransitionLibrary.universalPlaylist?.entry(path: path) != nil
        }
        guard !mediaMutationInProgress, entryExists else { return }
        guard let window = settingsController?.window else { return }
        let requestedCharacterID = characterLibrary.activeCharacterID
        let requestedMapURL = mediaMapURL.standardizedFileURL
        let requestedMapData = mediaMapEncodedData
        let requestedGlobalData = globalTransitionLibraryEncodedData
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove this transition?"
        alert.informativeText = scope == .global
            ? "Remove this shared Global transition. Managed files remain available for safe cleanup after every character and Global reference is checked."
            : "Remove only the transition mapping, or also move managed files to Trash after Statelet revalidates every character map."
        alert.addButton(withTitle: scope == .global ? "Remove from Global Library" : "Remove and Trash Managed Files")
        alert.addButton(withTitle: "Remove from Library Only")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response != .alertThirdButtonReturn else { return }
            if scope == .global {
                guard !self.mediaMutationInProgress,
                      self.globalTransitionLibraryEncodedData == requestedGlobalData,
                      self.globalTransitionLibrary.universalPlaylist?.entry(path: path) != nil else {
                    self.settingsController?.update(activity: .failed(destination, "The Global transition changed before removal. Nothing was removed."))
                    return
                }
                do {
                    let updated = try self.globalTransitionLibrary.removingUniversalTransitionEntry(path: path)
                    try self.publishGlobalTransitionLibrary(updated)
                    self.applyPublishedGlobalTransitionLibrary(updated)
                    self.settingsController?.update(activity: .succeeded(destination, "Global transition removed"))
                } catch {
                    self.settingsController?.update(activity: .failed(destination, error.localizedDescription))
                }
                return
            }
            let catalogSnapshot = try? self.characterLibraryStorage.loadCatalog()
            guard !self.mediaMutationInProgress,
                  catalogSnapshot?.library == self.characterLibrary,
                  catalogSnapshot?.encodedData == self.characterLibraryEncodedData,
                  self.characterLibrary.activeCharacterID == requestedCharacterID,
                  self.mediaMapURL.standardizedFileURL == requestedMapURL,
                  self.mediaMapEncodedData == requestedMapData,
                  self.characterRouteContains(route, path: path) else {
                self.settingsController?.update(
                    activity: .failed(destination, "The character or transition changed before removal. Nothing was removed.")
                )
                return
            }
            self.mediaMutationInProgress = true
            defer {
                self.mediaMutationInProgress = false
                self.refreshSettings()
            }
            do {
                let updated: MediaMap
                guard let states = self.transitionStates(for: route) else {
                    throw PetContractError.invalidValue("Character transition route is unavailable")
                }
                if response == .alertFirstButtonReturn {
                    let originalMap = self.mediaMap
                    let plan = try states.source == states.destination
                        ? ManagedMediaRemovalPlanner.plan(
                            mediaMap: self.mediaMap,
                            mapURL: self.mediaMapURL,
                            inStateTransition: states.source,
                            canonicalRoot: self.canonicalManagedMediaRoot
                        )
                        : ManagedMediaRemovalPlanner.plan(
                            mediaMap: self.mediaMap,
                            mapURL: self.mediaMapURL,
                            transitionFrom: states.source,
                            transitionTo: states.destination,
                            path: path,
                            canonicalRoot: self.canonicalManagedMediaRoot
                        )
                    let libraryMaps = try self.allCharacterMediaMaps()
                    guard !plan.trashURLs.contains(where: { target in
                        self.globalTransitionLibraryReferences(target)
                            ||
                        libraryMaps.contains { character, map, mapURL in
                            guard character.id != self.characterLibrary.activeCharacterID else { return false }
                            return self.mediaMap(map, at: mapURL, references: target)
                        }
                    }) else {
                        throw PetContractError.invalidValue("This transition media is shared by another character. Remove only the library entry.")
                    }
                    let snapshot = try ManagedMediaTrashRevalidator.captureLibrary(
                        targetURLs: plan.trashURLs,
                        maps: libraryMaps.map { _, map, mapURL in ManagedMediaTrashMap(url: mapURL, map: map) },
                        catalogURL: self.characterLibraryStorage.catalogURL,
                        globalTransitionLibrary: self.managedMediaTrashGlobalTransitionLibrary,
                        canonicalRoot: self.canonicalManagedMediaRoot
                    )
                    try ManagedMediaTrashRevalidator.validateLibraryUnchanged(
                        snapshot: snapshot,
                        canonicalRoot: self.canonicalManagedMediaRoot
                    )
                    updated = plan.updatedMap
                    try self.publishMediaMap(updated)
                    self.applyPublishedMediaMap(updated)
                    let quarantine: ManagedMediaTrashQuarantine
                    do {
                        quarantine = try ManagedMediaTrashRevalidator.quarantineLibraryAfterPublish(
                            snapshot: snapshot,
                            publishedMap: ManagedMediaTrashMap(url: self.mediaMapURL, map: updated),
                            canonicalRoot: self.canonicalManagedMediaRoot
                        )
                    } catch {
                        try ManagedMediaTrashRevalidator.validateLibraryReadyForMapRestore(
                            snapshot: snapshot,
                            publishedMap: ManagedMediaTrashMap(url: self.mediaMapURL, map: updated),
                            canonicalRoot: self.canonicalManagedMediaRoot
                        )
                        try self.publishMediaMap(originalMap)
                        self.applyPublishedMediaMap(originalMap)
                        throw error
                    }
                    do {
                        try FileManager.default.trashItem(at: quarantine.directoryURL, resultingItemURL: nil)
                    } catch {
                        self.settingsController?.update(
                            activity: .failed(destination, "The transition was removed, but its quarantined managed files could not be moved to Trash.")
                        )
                        return
                    }
                } else {
                    updated = try states.source == states.destination
                        ? self.mediaMap.removingInStateTransition(for: states.source)
                        : self.mediaMap.removingTransitionEntry(from: states.source, to: states.destination, path: path)
                    try self.publishMediaMap(updated)
                    self.applyPublishedMediaMap(updated)
                }
                self.settingsController?.update(activity: .succeeded(destination, "Transition removed"))
            } catch {
                self.settingsController?.update(activity: .failed(destination, error.localizedDescription))
            }
        }
    }

    private func moveTransition(
        scope: TransitionLibraryScope,
        route: SettingsTransitionRoute,
        path: String,
        to destinationIndex: Int
    ) {
        mutateTransition(scope: scope, destination: transitionActivityState(for: route)) {
            switch scope {
            case .character:
                guard let states = self.transitionStates(for: route) else {
                    throw PetContractError.invalidValue("Character transition route is unavailable")
                }
                return try .character(mediaMap.movingTransitionEntry(
                    from: states.source, to: states.destination, path: path, to: destinationIndex
                ))
            case .global:
                guard route == .global else {
                    throw PetContractError.invalidValue("Global scope uses one universal transition route")
                }
                return try .global(globalTransitionLibrary.movingUniversalTransitionEntry(
                    path: path, to: destinationIndex
                ))
            }
        }
    }

    private func changeTransitionPlaybackMode(
        scope: TransitionLibraryScope,
        route: SettingsTransitionRoute,
        to mode: MediaPlaybackMode
    ) {
        mutateTransition(scope: scope, destination: transitionActivityState(for: route)) {
            switch scope {
            case .character:
                guard let states = self.transitionStates(for: route) else {
                    throw PetContractError.invalidValue("Character transition route is unavailable")
                }
                return try .character(mediaMap.changingTransitionPlaybackMode(from: states.source, to: states.destination, to: mode))
            case .global:
                guard route == .global else {
                    throw PetContractError.invalidValue("Global scope uses one universal transition route")
                }
                return try .global(globalTransitionLibrary.changingUniversalTransitionPlaybackMode(to: mode))
            }
        }
    }

    private func setFixedTransition(scope: TransitionLibraryScope, route: SettingsTransitionRoute, path: String) {
        mutateTransition(scope: scope, destination: transitionActivityState(for: route)) {
            switch scope {
            case .character:
                guard let states = self.transitionStates(for: route) else {
                    throw PetContractError.invalidValue("Character transition route is unavailable")
                }
                return try .character(mediaMap.settingFixedTransitionEntry(from: states.source, to: states.destination, path: path))
            case .global:
                guard route == .global else {
                    throw PetContractError.invalidValue("Global scope uses one universal transition route")
                }
                return try .global(globalTransitionLibrary.settingFixedUniversalTransitionEntry(path: path))
            }
        }
    }

    private enum TransitionLibraryMutation {
        case character(MediaMap)
        case global(GlobalTransitionLibrary)
    }

    private func mutateTransition(
        scope: TransitionLibraryScope,
        destination: PetState,
        mutation: () throws -> TransitionLibraryMutation
    ) {
        guard !mediaMutationInProgress else { return }
        do {
            if scope == .global {
                let current = try characterLibraryStorage.loadGlobalTransitionLibrary()
                guard current.encodedData == globalTransitionLibraryEncodedData,
                      current.library == globalTransitionLibrary else {
                    throw CharacterLibraryStorageError.catalogConflict
                }
            }
            let updated = try mutation()
            switch updated {
            case let .character(map):
                try publishMediaMap(map)
                applyPublishedMediaMap(map, refreshPlayback: false)
            case let .global(library):
                try publishGlobalTransitionLibrary(library)
                applyPublishedGlobalTransitionLibrary(library, refreshPlayback: false)
            }
        } catch {
            settingsController?.update(activity: .failed(destination, error.localizedDescription))
        }
    }

    private func importMP4s(_ sourceURLs: [URL], for state: PetState) {
        guard !mediaMutationInProgress else {
            settingsController?.update(activity: .failed(state, "Nothing imported · wait for the current media operation to finish"))
            return
        }
        guard case let .ready(toolchain) = toolchainState else {
            settingsController?.update(activity: .failed(state, "Nothing imported · conversion tools aren’t ready"))
            return
        }
        switch MP4ImportURLValidator.validate(sourceURLs) {
        case let .rejected(reason):
            settingsController?.update(activity: .failed(state, "Nothing imported · \(reason)"))
        case let .accepted(orderedURLs, rejected):
            let validationFailures = rejected.map {
                MP4ImportFailure(
                    name: safeMediaDisplayName($0.sourceURL),
                    reason: String($0.reason.prefix(300)),
                    sourceURL: nil
                )
            }
            startConversionBatch(
                sourceURLs: orderedURLs,
                state: state,
                toolchain: toolchain,
                initialFailures: validationFailures,
                totalCount: orderedURLs.count + validationFailures.count
            )
        }
    }

    private func startConversionBatch(
        sourceURLs: [URL],
        state: PetState,
        toolchain: AlphaToolchain,
        initialFailures: [MP4ImportFailure] = [],
        totalCount: Int? = nil
    ) {
        guard !sourceURLs.isEmpty else { return }
        do {
            try prepareMediaDirectory()
        } catch {
            presentSettingsError("Statelet couldn’t prepare the Media folder.")
            return
        }
        mediaMutationInProgress = true
        let batchID = UUID()
        activeMP4BatchID = batchID
        mp4BatchCancellationRequested = false
        lastFailedMP4Batch = nil
        convertNextMP4(
            sourceURLs: sourceURLs,
            index: 0,
            totalCount: totalCount ?? sourceURLs.count,
            state: state,
            toolchain: toolchain,
            imported: 0,
            failures: initialFailures,
            notices: [],
            batchID: batchID
        )
    }

    private func convertNextMP4(
        sourceURLs: [URL],
        index: Int,
        totalCount: Int,
        state: PetState,
        toolchain: AlphaToolchain,
        imported: Int,
        failures: [MP4ImportFailure],
        notices: [MP4ImportNotice],
        batchID: UUID
    ) {
        guard activeMP4BatchID == batchID else { return }
        if mp4BatchCancellationRequested {
            finishMP4Batch(
                state: state,
                total: totalCount,
                imported: imported,
                failures: failures,
                notices: notices,
                cancelled: true,
                batchID: batchID
            )
            return
        }
        guard index < sourceURLs.count else {
            finishMP4Batch(
                state: state,
                total: totalCount,
                imported: imported,
                failures: failures,
                notices: notices,
                cancelled: false,
                batchID: batchID
            )
            return
        }
        let sourceURL = sourceURLs[index]
        let token = versionToken()
        let outputURL = mediaMapURL.deletingLastPathComponent()
            .appendingPathComponent("\(state.rawValue)-\(token).mov")
        let reportURL = mediaMapURL.deletingLastPathComponent()
            .appendingPathComponent("\(state.rawValue)-\(token).report.json")
        let position = index + 1
        let invocationChallenge: String
        do {
            invocationChallenge = try Self.makeInvocationChallenge()
            try writeConversionJournal(
                ActiveConversionJournal(
                    state: state.rawValue,
                    characterID: characterLibrary.activeCharacterID,
                    mediaMapBasename: mediaMapURL.lastPathComponent,
                    mediaMapSHA256: try currentMediaMapSHA256(),
                    outputBasename: outputURL.lastPathComponent,
                    reportBasename: reportURL.lastPathComponent,
                    invocationChallenge: invocationChallenge
                )
            )
        } catch {
            let failure = MP4ImportFailure(
                name: safeMediaDisplayName(sourceURL),
                reason: "Statelet could not create a private recovery record for this conversion.",
                sourceURL: sourceURL
            )
            convertNextMP4(
                sourceURLs: sourceURLs,
                index: index + 1,
                totalCount: totalCount,
                state: state,
                toolchain: toolchain,
                imported: imported,
                failures: failures + [failure],
                notices: notices,
                batchID: batchID
            )
            return
        }
        settingsController?.update(
            activity: .converting(
                state,
                "Clip \(position) of \(sourceURLs.count): preflighting compatibility and disk space…"
            ),
            progressValue: batchProgress(index: index, total: sourceURLs.count, clipPercent: 0)
        )
        conversionCoordinator.convert(
            sourceURL: sourceURL,
            outputURL: outputURL,
            reportURL: reportURL,
            width: AlphaAuthoringCanvas.width,
            height: AlphaAuthoringCanvas.height,
            toolchain: toolchain,
            invocationChallenge: invocationChallenge,
            profile: conversionProfile,
            phase: { [weak self] phase in
                guard let self else { return }
                self.settingsController?.update(
                    activity: .converting(state, "Clip \(position) of \(sourceURLs.count): \(phase)"),
                    progressValue: self.batchProgress(
                        index: index,
                        total: sourceURLs.count,
                        clipPercent: 0
                    )
                )
            },
            progress: { [weak self] progress in
                guard let self, self.activeMP4BatchID == batchID else { return }
                let clipPercent = min(96, progress.percent * 0.96)
                self.settingsController?.update(
                    activity: .converting(
                        state,
                        "Clip \(position) of \(sourceURLs.count): \(progress.message)"
                    ),
                    progressValue: self.batchProgress(
                        index: index,
                        total: sourceURLs.count,
                        clipPercent: clipPercent
                    )
                )
            },
            completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case let .failure(error):
                    self.updateConversionFailureDiagnostic(from: error)
                    try? FileManager.default.removeItem(at: outputURL)
                    try? FileManager.default.removeItem(at: reportURL)
                    self.clearConversionJournal()
                    if self.mp4BatchCancellationRequested
                        || (error as? AlphaConversionFailure).map({
                            if case .cancelled = $0 { return true }
                            return false
                        }) == true {
                        self.finishMP4Batch(
                            state: state,
                            total: totalCount,
                            imported: imported,
                            failures: failures,
                            notices: notices,
                            cancelled: true,
                            batchID: batchID
                        )
                    } else {
                        let failure = MP4ImportFailure(
                            name: self.safeMediaDisplayName(sourceURL),
                            reason: String(error.localizedDescription.prefix(300)),
                            sourceURL: sourceURL
                        )
                        self.logger.error("event=animation_import_failed state=\(state.rawValue, privacy: .public) batch_index=\(position, privacy: .public) batch_count=\(sourceURLs.count, privacy: .public) stage=converter")
                        self.convertNextMP4(
                            sourceURLs: sourceURLs,
                            index: index + 1,
                            totalCount: totalCount,
                            state: state,
                            toolchain: toolchain,
                            imported: imported,
                            failures: failures + [failure],
                            notices: notices,
                            batchID: batchID
                        )
                    }
                case let .success(conversion):
                    self.lastConversionFailureDiagnostic = nil
                    self.settingsController?.update(
                        activity: .converting(state, "Clip \(position) of \(sourceURLs.count): validating transparency…"),
                        progressValue: self.batchProgress(
                            index: index,
                            total: sourceURLs.count,
                            clipPercent: 97
                        )
                    )
                    Task { @MainActor in
                        let validation = await Task.detached(priority: .userInitiated) {
                            try Self.validateLocallyAttestedMovie(
                                outputURL: conversion.outputURL,
                                reportURL: conversion.reportURL,
                                expectedOutputBasename: conversion.outputURL.lastPathComponent,
                                invocationChallenge: invocationChallenge,
                                expectedInitialReportData: conversion.reportData
                            )
                        }.result
                            guard self.activeMP4BatchID == batchID else {
                                try? FileManager.default.removeItem(at: conversion.outputURL)
                                try? FileManager.default.removeItem(at: conversion.reportURL)
                                self.clearConversionJournal()
                                return
                            }
                            if self.mp4BatchCancellationRequested {
                                try? FileManager.default.removeItem(at: conversion.outputURL)
                                try? FileManager.default.removeItem(at: conversion.reportURL)
                                self.clearConversionJournal()
                                self.finishMP4Batch(
                                    state: state,
                                    total: totalCount,
                                    imported: imported,
                                    failures: failures,
                                    notices: notices,
                                    cancelled: true,
                                    batchID: batchID
                                )
                                return
                            }
                            var nextImported = imported
                            var nextFailures = failures
                            var nextNotices = notices
                            switch validation {
                            case let .failure(error):
                                self.lastConversionFailureDiagnostic = nil
                                try? FileManager.default.removeItem(at: conversion.outputURL)
                                try? FileManager.default.removeItem(at: conversion.reportURL)
                                self.clearConversionJournal()
                                nextFailures.append(
                                    MP4ImportFailure(
                                        name: self.safeMediaDisplayName(sourceURL),
                                        reason: String(error.localizedDescription.prefix(300)),
                                        sourceURL: sourceURL
                                    )
                                )
                                self.logger.error("event=animation_import_failed state=\(state.rawValue, privacy: .public) batch_index=\(position, privacy: .public) batch_count=\(sourceURLs.count, privacy: .public) stage=report_validation")
                            case let .success(validation):
                                do {
                                    let report = validation.report
                                    guard report.trust == .locallyAttested else {
                                        throw AlphaConversionFailure.converterFailed(
                                            "The converted movie was not locally attested."
                                        )
                                    }
                                    self.settingsController?.update(
                                        activity: .converting(
                                            state,
                                            "Clip \(position) of \(sourceURLs.count): adding verified movie…"
                                        ),
                                        progressValue: self.batchProgress(
                                            index: index,
                                            total: sourceURLs.count,
                                            clipPercent: 99
                                        )
                                    )
                                    try Self.requireValidatedFilesUnchanged(
                                        validation,
                                        outputURL: conversion.outputURL,
                                        reportURL: conversion.reportURL
                                    )
                                    try self.installMediaEntry(
                                        for: state,
                                        path: conversion.outputURL.lastPathComponent
                                    )
                                    self.lastConversionFailureDiagnostic = nil
                                    self.clearConversionJournal()
                                    nextImported += 1
                                    if !report.notices.isEmpty {
                                        nextNotices.append(
                                            MP4ImportNotice(
                                                name: self.safeMediaDisplayName(sourceURL),
                                                messages: report.notices.map(\.message)
                                            )
                                        )
                                    }
                                    self.logger.info("event=animation_imported state=\(state.rawValue, privacy: .public) frames=\(report.frames, privacy: .public) batch_index=\(position, privacy: .public) batch_count=\(sourceURLs.count, privacy: .public)")
                                } catch {
                                    try? FileManager.default.removeItem(at: conversion.outputURL)
                                    try? FileManager.default.removeItem(at: conversion.reportURL)
                                    self.clearConversionJournal()
                                    nextFailures.append(
                                        MP4ImportFailure(
                                            name: self.safeMediaDisplayName(sourceURL),
                                            reason: "The verified movie could not be added to the library.",
                                            sourceURL: sourceURL
                                        )
                                    )
                                    self.logger.error("event=animation_import_failed state=\(state.rawValue, privacy: .public) batch_index=\(position, privacy: .public) batch_count=\(sourceURLs.count, privacy: .public) stage=library_install")
                                }
                            }
                            self.convertNextMP4(
                                sourceURLs: sourceURLs,
                                index: index + 1,
                                totalCount: totalCount,
                                state: state,
                                toolchain: toolchain,
                                imported: nextImported,
                                failures: nextFailures,
                                notices: nextNotices,
                                batchID: batchID
                            )
                    }
                }
            }
        )
    }

    private func finishMP4Batch(
        state: PetState,
        total: Int,
        imported: Int,
        failures: [MP4ImportFailure],
        notices: [MP4ImportNotice],
        cancelled: Bool,
        batchID: UUID
    ) {
        guard activeMP4BatchID == batchID else { return }
        activeMP4BatchID = nil
        mp4BatchCancellationRequested = false
        mediaMutationInProgress = false
        let retryURLs = failures.compactMap(\.sourceURL).reduce(into: [URL]()) { urls, url in
            if !urls.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
                urls.append(url)
            }
        }
        lastFailedMP4Batch = retryURLs.isEmpty
            ? nil
            : FailedMP4Batch(state: state, sourceURLs: retryURLs)
        let noticeSummary = summarizedImportNotices(notices)
        if cancelled {
            let priorFailures = summarizedImportFailures(failures)
            settingsController?.update(
                activity: .failed(
                    state,
                    "Import cancelled · \(imported) of \(total) clips were added"
                        + (priorFailures.map { " · Earlier failures: \($0)" } ?? "")
                        + (noticeSummary.map { " · Notices: \($0)" } ?? "")
                ),
                retryFailedAvailable: !retryURLs.isEmpty
            )
        } else if failures.isEmpty {
            settingsController?.update(
                activity: .succeeded(
                    state,
                    "Imported \(imported) clip\(imported == 1 ? "" : "s")"
                        + (noticeSummary.map { " · \($0)" } ?? "")
                )
            )
        } else {
            settingsController?.update(
                activity: .failed(
                    state,
                    "Imported \(imported) of \(total) · "
                        + (summarizedImportFailures(failures) ?? "Conversion failed")
                        + (noticeSummary.map { " · Notices: \($0)" } ?? "")
                ),
                retryFailedAvailable: !retryURLs.isEmpty
            )
        }
        refreshSettings()
    }

    private func updateConversionFailureDiagnostic(from error: Error) {
        lastConversionFailureDiagnostic = (error as? AlphaConversionFailure)?.conversionDiagnostic
    }

    private func summarizedImportFailures(_ failures: [MP4ImportFailure]) -> String? {
        guard !failures.isEmpty else { return nil }
        let visible = failures.prefix(2)
            .map { "\($0.name): \($0.reason)" }
            .joined(separator: " · ")
        let suffix = failures.count > 2 ? " · and \(failures.count - 2) more" : ""
        return visible + suffix
    }

    private func summarizedImportNotices(_ notices: [MP4ImportNotice]) -> String? {
        guard !notices.isEmpty else { return nil }
        let visible = notices.prefix(2)
            .map { "\($0.name): \($0.messages.joined(separator: ", "))" }
            .joined(separator: " · ")
        let suffix = notices.count > 2 ? " · and \(notices.count - 2) more" : ""
        return visible + suffix
    }

    private func cancelMP4ImportBatch() {
        if let conversionID = activeTransitionConversionID {
            cancelTransitionConversion(conversionID)
            return
        }
        guard activeMP4BatchID != nil else { return }
        mp4BatchCancellationRequested = true
        conversionCoordinator.cancel()
    }

    private func cancelTransitionConversion(_ conversionID: UUID) {
        guard activeTransitionConversionID == conversionID,
              !transitionConversionCancellationRequested else { return }
        let destination = activeTransitionConversionDestination ?? currentState
        transitionConversionCancellationRequested = true
        conversionCoordinator.cancel()
        settingsController?.update(
            activity: .working(destination, "Cancelling transition conversion…")
        )
    }

    private func removeCancelledTransitionArtifact(_ artifactURL: URL) -> Bool {
        let mediaRoot = mediaMapURL.deletingLastPathComponent().standardizedFileURL
        let standardizedArtifact = artifactURL.standardizedFileURL
        guard standardizedArtifact.deletingLastPathComponent() == mediaRoot else { return false }
        let basename = standardizedArtifact.lastPathComponent
        guard !basename.isEmpty,
              basename != ".",
              basename != "..",
              !basename.contains("/") else { return false }

        let rootDescriptor = Darwin.open(
            mediaRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else { return false }
        defer { Darwin.close(rootDescriptor) }

        var status = stat()
        let statusResult = basename.withCString {
            Darwin.fstatat(rootDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if statusResult != 0 {
            return errno == ENOENT
        }

        let unlinkResult = basename.withCString {
            Darwin.unlinkat(rootDescriptor, $0, 0)
        }
        if unlinkResult != 0, errno != ENOENT { return false }
        if unlinkResult == 0, Darwin.fsync(rootDescriptor) != 0 { return false }

        var remainingStatus = stat()
        let remainingResult = basename.withCString {
            Darwin.fstatat(rootDescriptor, $0, &remainingStatus, AT_SYMLINK_NOFOLLOW)
        }
        return remainingResult != 0 && errno == ENOENT
    }

    private func retryLastFailedMP4Batch() {
        guard !mediaMutationInProgress,
              let batch = lastFailedMP4Batch else { return }
        importMP4s(batch.sourceURLs, for: batch.state)
    }

    private func batchProgress(index: Int, total: Int, clipPercent: Double) -> Double {
        guard total > 0 else { return 0 }
        let boundedClip = min(100, max(0, clipPercent)) / 100
        return min(100, max(0, (Double(index) + boundedClip) / Double(total) * 100))
    }

    private func safeMediaDisplayName(_ url: URL) -> String {
        let flattened = url.lastPathComponent
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String((flattened.isEmpty ? "MP4" : flattened).prefix(100))
    }

    private var conversionJournalURL: URL {
        mediaMapURL.deletingLastPathComponent()
            .appendingPathComponent(".statelet-conversion-journal.json")
    }

    private func writeConversionJournal(_ journal: ActiveConversionJournal) throws {
        let data = try JSONEncoder().encode(journal)
        let url = conversionJournalURL
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    private func currentMediaMapSHA256() throws -> String {
        guard let data = mediaMapEncodedData else {
            throw PetContractError.invalidValue("media map snapshot is unavailable")
        }
        return Self.sha256Hex(of: data)
    }

    private func currentGlobalTransitionLibrarySHA256() -> String? {
        globalTransitionLibraryEncodedData.map(Self.sha256Hex(of:))
    }

    private func clearConversionJournal() {
        try? FileManager.default.removeItem(at: conversionJournalURL)
    }

    private static func makeInvocationChallenge() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw AlphaConversionFailure.launchFailed
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func recoverInterruptedConversionIfPresent() {
        let journalURL = conversionJournalURL
        var journalStatus = stat()
        guard Darwin.lstat(journalURL.path, &journalStatus) == 0 else { return }
        guard let data = try? PortableMediaSecureCopier.readRegularFile(
                  at: journalURL,
                  maximumBytes: PortableMediaCopyLimits().maxReportBytes
              ),
              let journal = try? JSONDecoder().decode(ActiveConversionJournal.self, from: data),
              let state = PetState(rawValue: journal.state),
              let owner = try? recoveryOwner(for: journal),
              Self.isValidRecoveryRoute(journal),
              AlphaRecoveryArtifactPolicy.accepts(
                  artifactStem: Self.recoveryArtifactStem(journal, state: state),
                  outputBasename: journal.outputBasename,
                  reportBasename: journal.reportBasename
              ),
              Self.isValidInvocationChallenge(journal.invocationChallenge) else { return }
        let mediaDirectory = configuredMediaMapURL.deletingLastPathComponent()
        mediaMutationInProgress = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outputURL = mediaDirectory.appendingPathComponent(journal.outputBasename)
            let reportURL = mediaDirectory.appendingPathComponent(journal.reportBasename)
            let validation = await Task.detached(priority: .utility) {
                try Self.validateLocallyAttestedMovie(
                    outputURL: outputURL,
                    reportURL: reportURL,
                    expectedOutputBasename: journal.outputBasename,
                    invocationChallenge: journal.invocationChallenge,
                    expectedInitialReportData: nil
                )
            }.result
            switch validation {
                case .failure:
                    // Failed validation does not prove that these names remain
                    // unowned. Keep both artifacts and the journal untouched so
                    // a later retry can re-evaluate the complete library graph.
                    let notice = "Interrupted conversion could not be recovered safely. Its recovery journal and artifacts were retained for retry."
                    self.pendingRecoveryNotice = (state, notice)
                    self.settingsController?.update(activity: .failed(state, notice))
                    self.logger.error("event=animation_recovery_deferred state=\(state.rawValue, privacy: .public) action=retain_journal_and_artifacts")
                case let .success(validation):
                    do {
                        if let rawFrom = journal.transitionFrom,
                           let rawTo = journal.transitionTo,
                           let from = PetState(rawValue: rawFrom),
                           let to = PetState(rawValue: rawTo) {
                            let duration = validation.durationSeconds
                            guard duration.isFinite, duration > 0,
                                  duration <= LifecycleTransitionMediaPolicy.maximumDuration else {
                                throw PetContractError.invalidValue("Recovered transition exceeds the duration limit.")
                            }
                            let entry = try MediaEntry(path: journal.outputBasename, loop: false)
                            switch owner {
                            case let .character(characterOwner):
                                var updated = characterOwner.map
                                if from == to {
                                    updated = try updated.settingInStateTransition(for: from, entry: entry)
                                } else if updated.transitionPlaylist(from: from, to: to)?
                                    .entry(path: journal.outputBasename) == nil {
                                    updated = try updated.appendingTransitionEntry(entry, from: from, to: to)
                                }
                                try Self.requireValidatedFilesUnchanged(
                                    validation,
                                    outputURL: outputURL,
                                    reportURL: reportURL
                                )
                                let encoded = try self.characterLibraryStorage.saveRecoveredMediaMap(
                                    updated,
                                    for: characterOwner.entry,
                                    expectedData: characterOwner.encodedData,
                                    expectedCatalogData: characterOwner.catalogEncodedData
                                )
                                if characterOwner.isActive {
                                    self.mediaMapEncodedData = encoded
                                    self.applyPublishedMediaMap(updated)
                                } else {
                                    self.characterClipCounts[characterOwner.entry.id] = self.totalClipCount(in: updated)
                                }
                            case let .global(globalOwner):
                                guard from != to else {
                                    throw PetContractError.invalidValue("same-state transitions are character-scoped")
                                }
                                let updated = try globalOwner.library.recoveringLegacyTransitionEntry(
                                    entry,
                                    from: from,
                                    to: to
                                )
                                try Self.requireValidatedFilesUnchanged(
                                    validation,
                                    outputURL: outputURL,
                                    reportURL: reportURL
                                )
                                let encoded = try self.characterLibraryStorage
                                    .saveRecoveredGlobalTransitionLibrary(
                                        updated,
                                        expectedData: globalOwner.encodedData
                                    )
                                self.globalTransitionLibraryEncodedData = encoded
                                self.applyPublishedGlobalTransitionLibrary(updated)
                            }
                        } else {
                            let duration = validation.durationSeconds
                            guard duration.isFinite, duration > 0,
                                  duration <= LifecycleTransitionMediaPolicy.maximumDuration else {
                                throw PetContractError.invalidValue("Recovered transition exceeds the duration limit.")
                            }
                            let entry = try MediaEntry(path: journal.outputBasename, loop: false)
                            if case let .global(globalOwner) = owner {
                                var updated = globalOwner.library
                                if updated.universalPlaylist?.entry(path: journal.outputBasename) == nil {
                                    updated = try updated.appendingUniversalTransitionEntry(entry)
                                }
                                try Self.requireValidatedFilesUnchanged(
                                    validation,
                                    outputURL: outputURL,
                                    reportURL: reportURL
                                )
                                let encoded = try self.characterLibraryStorage
                                    .saveRecoveredGlobalTransitionLibrary(
                                        updated,
                                        expectedData: globalOwner.encodedData
                                    )
                                self.globalTransitionLibraryEncodedData = encoded
                                self.applyPublishedGlobalTransitionLibrary(updated)
                            } else {
                                guard case let .character(characterOwner) = owner else {
                                    throw PetContractError.invalidValue("global recovery requires a transition route")
                                }
                                var updated = characterOwner.map
                                let alreadyInstalled = updated.playlist(for: state)?
                                    .entries.contains(where: { $0.path == journal.outputBasename }) == true
                                if !alreadyInstalled {
                                    updated = try updated.appendingEntry(
                                        MediaEntry(path: journal.outputBasename),
                                        for: state
                                    )
                                }
                                try Self.requireValidatedFilesUnchanged(
                                    validation,
                                    outputURL: outputURL,
                                    reportURL: reportURL
                                )
                                let encoded = try self.characterLibraryStorage.saveRecoveredMediaMap(
                                    updated,
                                    for: characterOwner.entry,
                                    expectedData: characterOwner.encodedData,
                                    expectedCatalogData: characterOwner.catalogEncodedData
                                )
                                if characterOwner.isActive {
                                    self.mediaMapEncodedData = encoded
                                    self.applyPublishedMediaMap(updated)
                                } else {
                                    self.characterClipCounts[characterOwner.entry.id] = self.totalClipCount(in: updated)
                                }
                            }
                        }
                        self.clearConversionJournal()
                        self.logger.info("event=animation_recovered state=\(state.rawValue, privacy: .public)")
                        self.refreshSettings()
                    } catch {
                        self.logger.error("event=animation_recovery_deferred state=\(state.rawValue, privacy: .public)")
                    }
                }
            self.mediaMutationInProgress = false
        }
    }

    private func recoveryOwner(for journal: ActiveConversionJournal) throws -> ConversionRecoveryOwner {
        if journal.transitionScope == .global {
            guard journal.characterID == nil,
                  journal.mediaMapBasename == nil,
                  journal.mediaMapSHA256 == nil else {
                throw PetContractError.invalidValue("global conversion recovery owner is incomplete")
            }
            let loaded = try characterLibraryStorage.loadGlobalTransitionLibrary()
            switch (journal.globalTransitionLibrarySHA256, loaded.encodedData) {
            case (nil, nil):
                return .global(GlobalTransitionRecoveryOwner(
                    library: loaded.library,
                    encodedData: nil
                ))
            case let (.some(expected), .some(data)):
                guard expected.count == 64,
                      expected.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                      Self.sha256Hex(of: data) == expected else {
                    throw PetContractError.invalidValue("global conversion recovery ownership changed")
                }
                return .global(GlobalTransitionRecoveryOwner(
                    library: loaded.library,
                    encodedData: data
                ))
            default:
                throw PetContractError.invalidValue("global conversion recovery ownership changed")
            }
        }
        guard journal.transitionScope == nil || journal.transitionScope == .character,
              journal.globalTransitionLibrarySHA256 == nil else {
            throw PetContractError.invalidValue("conversion recovery scope is incomplete")
        }
        let catalogSnapshot = try characterLibraryStorage.loadCatalog()
        let catalog = catalogSnapshot.library
        let entry: CharacterLibraryEntry
        switch (journal.characterID, journal.mediaMapBasename, journal.mediaMapSHA256) {
        case (nil, nil, nil):
            throw PetContractError.invalidValue("legacy recovery owner is ambiguous")
        case let (.some(characterID), .some(mapBasename), .some(mapSHA256)):
            guard mapSHA256.count == 64,
                  mapSHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                  let matched = catalog.character(id: characterID),
                  matched.mapPath == mapBasename else {
                throw PetContractError.invalidValue("conversion recovery owner changed")
            }
            entry = matched
            let loaded = try characterLibraryStorage.loadMediaMap(for: entry)
            let catalogAfterLoad = try characterLibraryStorage.loadCatalog()
            guard catalogAfterLoad.encodedData == catalogSnapshot.encodedData,
                  catalogAfterLoad.library.character(id: entry.id)?.mapPath == entry.mapPath,
                  Self.sha256Hex(of: loaded.encodedData) == mapSHA256 else {
                throw PetContractError.invalidValue("conversion recovery ownership changed")
            }
            let catalogMatchesLiveState = catalogSnapshot.encodedData == characterLibraryEncodedData
                && catalog.activeCharacterID == characterLibrary.activeCharacterID
            return .character(RecoveryOwner(
                    entry: entry,
                    map: loaded.map,
                    encodedData: loaded.encodedData,
                    catalogEncodedData: catalogSnapshot.encodedData,
                    isActive: catalogMatchesLiveState && entry.id == catalog.activeCharacterID
                ))
        default:
            throw PetContractError.invalidValue("conversion recovery owner is incomplete")
        }
    }

    private static func isValidInvocationChallenge(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func isValidRecoveryRoute(_ journal: ActiveConversionJournal) -> Bool {
        ConversionRecoveryRoutePolicy.accepts(
            state: journal.state,
            transitionFrom: journal.transitionFrom,
            transitionTo: journal.transitionTo,
            transitionScope: journal.transitionScope
        )
    }

    private static func recoveryArtifactStem(
        _ journal: ActiveConversionJournal,
        state: PetState
    ) -> String {
        guard let from = journal.transitionFrom,
              let to = journal.transitionTo else {
            return journal.transitionScope == .global ? "transition-global" : state.rawValue
        }
        return "transition-\(from)-to-\(to)"
    }

    private func isMediaPathReferenced(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.path
        do {
            if globalTransitionLibraryReferences(url) {
                return true
            }
            return try allCharacterMediaMaps().contains { _, map, mapURL in
                allMediaEntries(in: map).contains { entry in
                    let movie = map.resolvedURL(for: entry, relativeTo: mapURL)
                        .standardizedFileURL
                    return movie.path == target
                        || movie.deletingPathExtension()
                            .appendingPathExtension("report.json")
                            .standardizedFileURL.path == target
                        || map.resolvedPosterURL(for: entry, relativeTo: mapURL)?
                            .standardizedFileURL.path == target
                }
            }
        } catch {
            // Missing or corrupt inactive profiles must never make managed
            // artifacts look safe to quarantine or delete.
            return true
        }
    }

    private func isMediaPathReferencedByInactiveCharacter(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.path
        do {
            return try allCharacterMediaMaps().contains { character, map, mapURL in
                guard character.id != characterLibrary.activeCharacterID else { return false }
                return allMediaEntries(in: map).contains { entry in
                        let movie = map.resolvedURL(for: entry, relativeTo: mapURL)
                            .standardizedFileURL
                        return movie.path == target
                            || movie.deletingPathExtension()
                                .appendingPathExtension("report.json")
                                .standardizedFileURL.path == target
                            || map.resolvedPosterURL(for: entry, relativeTo: mapURL)?
                                .standardizedFileURL.path == target
                }
            }
        } catch {
            return true
        }
    }

    private func mediaMap(_ map: MediaMap, at mapURL: URL, references url: URL) -> Bool {
        let target = url.standardizedFileURL.path
        return allMediaEntries(in: map).contains { entry in
                let movie = map.resolvedURL(for: entry, relativeTo: mapURL).standardizedFileURL
                return movie.path == target
                    || movie.deletingPathExtension().appendingPathExtension("report.json")
                        .standardizedFileURL.path == target
                    || map.resolvedPosterURL(for: entry, relativeTo: mapURL)?
                        .standardizedFileURL.path == target
        }
    }

    private func globalTransitionLibraryReferences(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.path
        let libraryURL = characterLibraryStorage.globalTransitionLibraryURL
        return globalTransitionLibrary.allEntries.contains { entry in
            let movie = globalTransitionLibrary.resolvedURL(for: entry, relativeTo: libraryURL)
                .standardizedFileURL
            return movie.path == target
                || movie.deletingPathExtension().appendingPathExtension("report.json")
                    .standardizedFileURL.path == target
                || globalTransitionLibrary.resolvedPosterURL(for: entry, relativeTo: libraryURL)?
                    .standardizedFileURL.path == target
        }
    }

    private var managedMediaTrashGlobalTransitionLibrary: ManagedMediaTrashGlobalTransitionLibrary {
        ManagedMediaTrashGlobalTransitionLibrary(
            url: characterLibraryStorage.globalTransitionLibraryURL,
            library: globalTransitionLibrary,
            expectedEncodedData: globalTransitionLibraryEncodedData
        )
    }

    private func allCharacterMediaMaps() throws -> [(CharacterLibraryEntry, MediaMap, URL)] {
        try characterLibrary.characters.map { entry in
            let mapURL = entry.resolvedMapURL(relativeTo: configuredMediaMapURL)
            if entry.id == characterLibrary.activeCharacterID {
                return (entry, mediaMap, mapURL)
            }
            let loaded = try characterLibraryStorage.loadMediaMap(for: entry)
            return (entry, loaded.map, mapURL)
        }
    }

    private func chooseTransparentMovie(for state: PetState) {
        guard !mediaMutationInProgress else { return }
        guard let settingsWindow = settingsController?.window else { return }
        let openPanel = NSOpenPanel()
        openPanel.title = "Choose Portable MOVs for \(state.rawValue.capitalized)"
        openPanel.message = "Portable MOV reports cannot prove local verification. Prefer importing the source MP4 so Statelet can convert and attest it on this Mac."
        openPanel.prompt = "Import MOVs"
        openPanel.allowedContentTypes = [.quickTimeMovie]
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.beginSheetModal(for: settingsWindow) { [weak self] response in
            guard response == .OK, !openPanel.urls.isEmpty else { return }
            self?.importVerifiedMovies(openPanel.urls, for: state)
        }
    }

    private func importVerifiedMovies(
        _ sourceURLs: [URL],
        for state: PetState,
        replacingPath: String? = nil,
        userConfirmedPortableTrust: Bool = false
    ) {
        guard !sourceURLs.isEmpty else { return }
        guard userConfirmedPortableTrust else {
            guard let settingsWindow = settingsController?.window else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Trust portable verification for this batch?"
            alert.informativeText = "Statelet will check each report hash, transparency gates, and AVFoundation playback, but it cannot prove that the report was produced on this Mac. Import the source MP4 instead for local attestation."
            alert.addButton(withTitle: "Import Portable MOVs")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: settingsWindow) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.importVerifiedMovies(
                    sourceURLs,
                    for: state,
                    replacingPath: replacingPath,
                    userConfirmedPortableTrust: true
                )
            }
            return
        }
        mediaMutationInProgress = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            var imported = 0
            var failures: [MP4ImportFailure] = []
            for (index, sourceURL) in sourceURLs.enumerated() {
                self.settingsController?.update(
                    activity: .working(
                        state,
                        "Portable MOV \(index + 1) of \(sourceURLs.count): checking claim and playback…"
                    )
                )
                do {
                    let installed = try await self.prepareVerifiedMovie(
                        sourceURL,
                        allowPortableClaim: userConfirmedPortableTrust
                    )
                    do {
                        if let replacingPath {
                            try self.installRelinkedMediaEntry(
                                for: state,
                                replacingPath: replacingPath,
                                with: installed.relativePath
                            )
                        } else {
                            try self.installMediaEntry(for: state, path: installed.relativePath)
                        }
                        imported += 1
                        self.logger.info("event=user_trusted_portable_animation_imported state=\(state.rawValue, privacy: .public) batch_index=\(index + 1, privacy: .public) batch_count=\(sourceURLs.count, privacy: .public) relink=\(replacingPath != nil, privacy: .public)")
                    } catch {
                        try? FileManager.default.removeItem(at: installed.directory)
                        throw error
                    }
                } catch {
                    failures.append(
                        MP4ImportFailure(
                            name: self.safeMediaDisplayName(sourceURL),
                            reason: String(error.localizedDescription.prefix(300)),
                            sourceURL: nil
                        )
                    )
                }
            }
            mediaMutationInProgress = false
            if replacingPath != nil {
                if imported == 1 {
                    settingsController?.update(activity: .succeeded(state, "Missing clip relinked"))
                } else {
                    settingsController?.update(
                        activity: .failed(
                            state,
                            "The missing clip could not be relinked with a user-trusted portable MOV · "
                                + (self.summarizedImportFailures(failures) ?? "Portable import failed")
                        )
                    )
                }
            } else if failures.isEmpty {
                settingsController?.update(
                    activity: .succeeded(state, "Imported \(imported) user-trusted portable MOV\(imported == 1 ? "" : "s")")
                )
            } else {
                settingsController?.update(
                    activity: .failed(
                        state,
                        "Imported \(imported) of \(sourceURLs.count) · "
                            + (self.summarizedImportFailures(failures) ?? "Portable import failed")
                    )
                )
            }
            refreshSettings()
        }
    }

    private func prepareVerifiedMovie(
        _ sourceURL: URL,
        allowPortableClaim: Bool
    ) async throws -> VerifiedMovieInstall {
        let reportURL = sourceURL.deletingPathExtension().appendingPathExtension("report.json")
        let installed = try await PortableMediaOperationRunner.run(
            timeoutSeconds: Self.portableCopyTimeoutSeconds
        ) { [self] token in
            try copyVerifiedMovieAndReport(
                sourceURL,
                reportURL: reportURL,
                operationToken: token
            )
        }
        do {
            let validation = try await validatePortableMovie(
                installed,
                allowPortableClaim: allowPortableClaim
            )
            return VerifiedMovieInstall(
                directory: installed.directory,
                movieURL: installed.movieURL,
                reportURL: installed.reportURL,
                relativePath: installed.relativePath,
                validation: validation
            )
        } catch {
            try? FileManager.default.removeItem(at: installed.directory)
            throw error
        }
    }

    private static func validateLocallyAttestedMovie(
        outputURL: URL,
        reportURL: URL,
        expectedOutputBasename: String,
        invocationChallenge: String,
        expectedInitialReportData: Data?
    ) throws -> VerifiedMovieValidation {
        let limits = PortableMediaCopyLimits()
        let movieIdentity = try PortableMediaSecureCopier.regularFileIdentity(
            at: outputURL,
            maximumBytes: limits.maxMovieBytes
        )
        let reportIdentity = try PortableMediaSecureCopier.regularFileIdentity(
            at: reportURL,
            maximumBytes: limits.maxReportBytes
        )
        var directoryIdentity = stat()
        guard Darwin.lstat(outputURL.deletingLastPathComponent().path, &directoryIdentity) == 0,
              directoryIdentity.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw PortableMediaCopyError.invalidSource
        }
        let reportData = try PortableMediaSecureCopier.readRegularFile(
            at: reportURL,
            maximumBytes: limits.maxReportBytes
        )
        if let expectedInitialReportData, expectedInitialReportData != reportData {
            throw PortableMediaCopyError.sourceChanged
        }
        let digest = try sha256Hex(of: outputURL)
        let report = try AlphaConversionReportValidator.validate(
            data: reportData,
            expectedOutputBasename: expectedOutputBasename,
            actualOutputSHA256: digest,
            expectedLocalProvenanceChallenge: invocationChallenge
        )
        guard report.trust == .locallyAttested else {
            throw AlphaConversionFailure.converterFailed("Local conversion attestation was missing.")
        }
        let probe = try AlphaPlaybackProcessValidator.validate(url: outputURL, expected: report)

        let reportDataAfterPlayback = try PortableMediaSecureCopier.readRegularFile(
            at: reportURL,
            maximumBytes: limits.maxReportBytes
        )
        let digestAfterPlayback = try sha256Hex(of: outputURL)
        let movieIdentityAfterPlayback = try PortableMediaSecureCopier.regularFileIdentity(
            at: outputURL,
            maximumBytes: limits.maxMovieBytes
        )
        let reportIdentityAfterPlayback = try PortableMediaSecureCopier.regularFileIdentity(
            at: reportURL,
            maximumBytes: limits.maxReportBytes
        )
        var directoryIdentityAfterPlayback = stat()
        guard reportDataAfterPlayback == reportData,
              digestAfterPlayback == report.outputSHA256,
              movieIdentityAfterPlayback == movieIdentity,
              reportIdentityAfterPlayback == reportIdentity,
              Darwin.lstat(
                  outputURL.deletingLastPathComponent().path,
                  &directoryIdentityAfterPlayback
              ) == 0,
              directoryIdentityAfterPlayback.st_dev == directoryIdentity.st_dev,
              directoryIdentityAfterPlayback.st_ino == directoryIdentity.st_ino,
              directoryIdentityAfterPlayback.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw PortableMediaCopyError.sourceChanged
        }
        return VerifiedMovieValidation(
            report: report,
            movieIdentity: movieIdentityAfterPlayback,
            reportIdentity: reportIdentityAfterPlayback,
            durationSeconds: probe.durationSeconds
        )
    }

    private static func requireValidatedFilesUnchanged(
        _ validation: VerifiedMovieValidation,
        outputURL: URL,
        reportURL: URL
    ) throws {
        let limits = PortableMediaCopyLimits()
        guard try PortableMediaSecureCopier.regularFileIdentity(
                  at: outputURL,
                  maximumBytes: limits.maxMovieBytes
              ) == validation.movieIdentity,
              try PortableMediaSecureCopier.regularFileIdentity(
                  at: reportURL,
                  maximumBytes: limits.maxReportBytes
              ) == validation.reportIdentity else {
            throw PortableMediaCopyError.sourceChanged
        }
    }

    private func validatePortableMovie(
        _ installed: VerifiedMovieCopy,
        allowPortableClaim: Bool
    ) async throws -> VerifiedMovieValidation {
        try await PortableMediaOperationRunner.run(
            timeoutSeconds: Self.portableValidationTimeoutSeconds
        ) { token in
            try token.check()
            var directoryStatus = stat()
            guard Darwin.lstat(installed.directory.path, &directoryStatus) == 0,
                  directoryStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  directoryStatus.st_mode & 0o077 == 0 else {
                throw PortableMediaCopyError.invalidSource
            }
            let limits = PortableMediaCopyLimits()
            let movieIdentity = try PortableMediaSecureCopier.regularFileIdentity(
                at: installed.movieURL,
                maximumBytes: limits.maxMovieBytes
            )
            let reportIdentity = try PortableMediaSecureCopier.regularFileIdentity(
                at: installed.reportURL,
                maximumBytes: limits.maxReportBytes
            )
            let reportData = try PortableMediaSecureCopier.readRegularFile(
                at: installed.reportURL,
                maximumBytes: limits.maxReportBytes,
                operationCheck: token.check
            )
            let digest = try Self.sha256Hex(of: installed.movieURL, operationCheck: token.check)
            let report = try AlphaConversionReportValidator.validate(
                data: reportData,
                expectedOutputBasename: installed.movieURL.lastPathComponent,
                actualOutputSHA256: digest
            )
            switch report.trust {
            case .locallyAttested:
                break
            case .portableClaim where allowPortableClaim:
                break
            case .portableClaim:
                throw AlphaConversionFailure.converterFailed(
                    "Portable verification must be explicitly trusted before import."
                )
            case .legacyPortableClaim:
                throw AlphaConversionFailure.converterFailed(
                    "Legacy portable reports are not accepted. Reconvert the source MP4 with the current Statelet converter."
                )
            }
            let probe = try AlphaPlaybackProcessValidator.validate(
                url: installed.movieURL,
                expected: report
            )
            try token.check()
            let reportDataAfterPlayback = try PortableMediaSecureCopier.readRegularFile(
                at: installed.reportURL,
                maximumBytes: limits.maxReportBytes,
                operationCheck: token.check
            )
            let digestAfterPlayback = try Self.sha256Hex(
                of: installed.movieURL,
                operationCheck: token.check
            )
            let movieIdentityAfterPlayback = try PortableMediaSecureCopier.regularFileIdentity(
                at: installed.movieURL,
                maximumBytes: limits.maxMovieBytes
            )
            let reportIdentityAfterPlayback = try PortableMediaSecureCopier.regularFileIdentity(
                at: installed.reportURL,
                maximumBytes: limits.maxReportBytes
            )
            var directoryStatusAfterPlayback = stat()
            guard reportDataAfterPlayback == reportData,
                  digestAfterPlayback == report.outputSHA256,
                  movieIdentityAfterPlayback == movieIdentity,
                  reportIdentityAfterPlayback == reportIdentity,
                  Darwin.lstat(installed.directory.path, &directoryStatusAfterPlayback) == 0,
                  directoryStatusAfterPlayback.st_dev == directoryStatus.st_dev,
                  directoryStatusAfterPlayback.st_ino == directoryStatus.st_ino,
                  directoryStatusAfterPlayback.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  directoryStatusAfterPlayback.st_mode & 0o077 == 0 else {
                throw PortableMediaCopyError.sourceChanged
            }
            try token.check()
            return VerifiedMovieValidation(
                report: report,
                movieIdentity: movieIdentityAfterPlayback,
                reportIdentity: reportIdentityAfterPlayback,
                durationSeconds: probe.durationSeconds
            )
        }
    }

    private func playOnce(state libraryState: PetState, path: String) {
        guard !reduceMotion else {
            presentSettingsError("Play Once is unavailable while macOS Reduce Motion is on.")
            return
        }
        guard let entry = mediaMap.playlist(for: libraryState)?.entry(path: path) else {
            presentSettingsError("That animation is no longer in the selected state.")
            refreshSettings()
            return
        }
        let url = mediaMap.resolvedURL(for: entry, relativeTo: mediaMapURL)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            presentSettingsError("The selected movie is missing or unreadable.")
            refreshSettings()
            return
        }

        cancelActiveLifecycleTransition(reason: "play_once")
        cancelActiveOneShotWithoutRestore(reason: "superseded")
        do {
            let presentationState = effectivePresentationState
            let oneShotEntry = try MediaEntry(
                path: entry.path,
                posterPath: entry.posterPath,
                loop: false,
                playbackRate: entry.playbackRate.value
            )
            let playback = try oneShotArbiter.start(state: currentState, path: entry.path)
            let transitionID = beginTransition()
            activeOneShotPreview = ActiveOneShotPreview(
                playback: playback,
                libraryState: libraryState,
                transitionID: transitionID
            )
            let started = DispatchTime.now().uptimeNanoseconds
            let startResult = player.show(
                state: presentationState,
                entry: oneShotEntry,
                url: url,
                posterURL: mediaMap.resolvedPosterURL(for: entry, relativeTo: mediaMapURL),
                transitionID: transitionID,
                startedAt: started,
                previewName: url.lastPathComponent,
                notifyWhenEnded: true
            )
            switch startResult {
            case .preparing:
                pendingPresentationState = presentationState
            case .presented:
                lastPresentedState = presentationState
                pendingPresentationState = nil
            case .failed:
                pendingPresentationState = nil
                stopOneShotPreview(reason: "start_failed")
                presentSettingsError("The selected movie could not be played.")
                return
            }
            logger.info("event=one_shot_started token=\(playback.token.rawValue, privacy: .public) transition_id=\(transitionID, privacy: .public) lifecycle_state=\(self.currentState.rawValue, privacy: .public) presentation_state=\(presentationState.rawValue, privacy: .public) library_state=\(libraryState.rawValue, privacy: .public)")
            updateStatusMenu()
            refreshSettings()
        } catch {
            presentSettingsError("The selected movie could not be prepared for one-time playback.")
            refreshSettings()
        }
    }

    private func finishOneShotPreview(transitionID: UInt64, reason: String) {
        guard let active = activeOneShotPreview,
              active.transitionID == transitionID,
              oneShotArbiter.complete(token: active.playback.token) != nil else { return }
        activeOneShotPreview = nil
        pendingPresentationState = nil
        logger.info("event=one_shot_finished token=\(active.playback.token.rawValue, privacy: .public) reason=\(reason, privacy: .public)")
        updateStatusMenu()
        refreshSettings()
        apply(state: currentState, forceRefresh: true)
    }

    private func stopOneShotPreview(reason: String) {
        guard let active = activeOneShotPreview,
              oneShotArbiter.cancel(token: active.playback.token) != nil else { return }
        activeOneShotPreview = nil
        pendingPresentationState = nil
        logger.info("event=one_shot_stopped token=\(active.playback.token.rawValue, privacy: .public) reason=\(reason, privacy: .public)")
        updateStatusMenu()
        refreshSettings()
        apply(state: currentState, forceRefresh: true)
    }

    private func cancelActiveOneShotWithoutRestore(reason: String) {
        guard let active = activeOneShotPreview else { return }
        _ = oneShotArbiter.cancel(token: active.playback.token)
        activeOneShotPreview = nil
        pendingPresentationState = nil
        logger.info("event=one_shot_cancelled token=\(active.playback.token.rawValue, privacy: .public) reason=\(reason, privacy: .public)")
    }

    @objc private func stopOneShotPreviewFromMenu() {
        stopOneShotPreview(reason: "menu")
    }

    private func changePlaybackMode(for state: PetState, to mode: MediaPlaybackMode) {
        do {
            let updated = try mediaMap.changingPlaybackMode(for: state, to: mode)
            try publishMediaMap(updated)
            applyPublishedMediaMap(updated)
            settingsController?.update(activity: .succeeded(state, "Playback mode set to \(mode.rawValue.capitalized)"))
        } catch {
            settingsController?.update(activity: .failed(state, "The playback mode could not be changed."))
        }
    }

    private func changeAdvancePolicy(
        for state: PetState,
        to policy: MediaPlaylistAdvancePolicy
    ) {
        do {
            let updated = try mediaMap.settingAdvanceOn(for: state, to: policy)
            try publishMediaMap(updated)
            applyPublishedMediaMap(updated)
            let message = policy == .clipEnd
                ? "Continuous rotation enabled"
                : "Rotation occurs when the state begins"
            settingsController?.update(activity: .succeeded(state, message))
        } catch {
            settingsController?.update(activity: .failed(state, "The rotation setting could not be changed."))
        }
    }

    private func moveMedia(
        for state: PetState,
        path: String,
        to destinationIndex: Int
    ) {
        do {
            let updated = try mediaMap.movingEntry(
                for: state,
                path: path,
                to: destinationIndex
            )
            try publishMediaMap(updated)
            applyPublishedMediaMap(updated)
            settingsController?.update(activity: .succeeded(state, "Clip order updated"))
        } catch {
            settingsController?.update(activity: .failed(state, "The clip order could not be changed."))
        }
    }

    private func relinkMedia(for state: PetState, path: String) {
        guard !mediaMutationInProgress else { return }
        guard let settingsWindow = settingsController?.window,
              let entry = mediaMap.playlist(for: state)?.entry(path: path) else { return }
        let currentURL = mediaMap.resolvedURL(for: entry, relativeTo: mediaMapURL)
        guard !FileManager.default.isReadableFile(atPath: currentURL.path) else {
            presentSettingsError("Relink is only needed when the current movie is missing or unreadable.")
            return
        }
        let openPanel = NSOpenPanel()
        openPanel.title = "Relink Missing Clip with Portable MOV"
        openPanel.message = "Choose a portable HEVC-with-alpha MOV beside its matching current-format .report.json file. You will be asked to trust its verification claim."
        openPanel.prompt = "Relink"
        openPanel.allowedContentTypes = [.quickTimeMovie]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.beginSheetModal(for: settingsWindow) { [weak self] response in
            guard response == .OK, let sourceURL = openPanel.url else { return }
            self?.importVerifiedMovies([sourceURL], for: state, replacingPath: path)
        }
    }

    private func setFixedEntry(for state: PetState, path: String) {
        do {
            let updated = try mediaMap.settingFixedEntry(for: state, path: path)
            try publishMediaMap(updated)
            mediaSelectionCursor.reset(state: state)
            applyPublishedMediaMap(updated)
            settingsController?.update(activity: .succeeded(state, "Fixed clip updated"))
        } catch {
            settingsController?.update(activity: .failed(state, "The fixed clip could not be changed."))
        }
    }

    private func choosePoster(for state: PetState, path: String) {
        guard !mediaMutationInProgress else { return }
        guard let settingsWindow = settingsController?.window else { return }
        guard mediaMap.playlist(for: state)?.entry(path: path) != nil else {
            presentSettingsError("That animation is no longer in the selected state.")
            return
        }
        let openPanel = NSOpenPanel()
        openPanel.title = "Choose Reduce Motion Poster"
        openPanel.message = "This still image is shown when macOS Reduce Motion is enabled."
        openPanel.prompt = "Use Poster"
        openPanel.allowedContentTypes = [.png, .jpeg, .heic]
        openPanel.allowsMultipleSelection = false
        openPanel.beginSheetModal(for: settingsWindow) { [weak self] response in
            guard response == .OK, let sourceURL = openPanel.url, let self else { return }
            self.mediaMutationInProgress = true
            self.settingsController?.update(activity: .working(state, "Copying Reduce Motion poster…"))
            DispatchQueue.global(qos: .userInitiated).async {
                let copied = Result { try self.copyPosterIntoMediaDirectory(sourceURL) }
                DispatchQueue.main.async {
                    switch copied {
                    case let .success(installed):
                        do {
                            try self.installPoster(for: state, path: path, relativePath: installed.relativePath)
                            self.mediaMutationInProgress = false
                            self.settingsController?.update(activity: .succeeded(state, "Reduce Motion poster is ready"))
                        } catch {
                            self.mediaMutationInProgress = false
                            try? FileManager.default.removeItem(at: installed.url)
                            self.settingsController?.update(activity: .failed(state, "The poster could not be applied."))
                        }
                    case .failure:
                        self.mediaMutationInProgress = false
                        self.settingsController?.update(activity: .failed(state, "The poster could not be copied."))
                    }
                }
            }
        }
    }

    private func removePoster(for state: PetState, path: String) {
        guard !mediaMutationInProgress,
              let entry = mediaMap.playlist(for: state)?.entry(path: path) else { return }
        do {
            let replacement = try MediaEntry(
                path: entry.path,
                posterPath: nil,
                loop: entry.loop,
                playbackRate: entry.playbackRate.value
            )
            let updated = try mediaMap.replacingEntry(for: state, path: path, with: replacement)
            try publishMediaMap(updated)
            applyPublishedMediaMap(updated)
            settingsController?.update(activity: .succeeded(state, "Reduce Motion poster removed"))
        } catch {
            settingsController?.update(activity: .failed(state, "The poster setting could not be changed."))
        }
    }

    private func installMediaEntry(for state: PetState, path: String) throws {
        let entry = try MediaEntry(
            path: path,
            posterPath: nil,
            loop: true,
            playbackRate: 1
        )
        let updated = try mediaMap.appendingEntry(entry, for: state)
        try publishMediaMap(updated)
        applyPublishedMediaMap(updated)
    }

    private func installRelinkedMediaEntry(
        for state: PetState,
        replacingPath: String,
        with relativePath: String
    ) throws {
        guard let previous = mediaMap.playlist(for: state)?.entry(path: replacingPath) else {
            throw PetContractError.invalidMediaPath
        }
        let replacement = try MediaEntry(
            path: relativePath,
            posterPath: previous.posterPath,
            loop: previous.loop,
            playbackRate: previous.playbackRate.value
        )
        let updated = try mediaMap.replacingEntry(
            for: state,
            path: replacingPath,
            with: replacement
        )
        try publishMediaMap(updated)
        mediaSelectionCursor.reset(state: state)
        applyPublishedMediaMap(updated)
    }

    private func installPoster(for state: PetState, path: String, relativePath: String) throws {
        guard let previous = mediaMap.playlist(for: state)?.entry(path: path) else {
            throw PetContractError.invalidMediaPath
        }
        let replacement = try MediaEntry(
            path: previous.path,
            posterPath: relativePath,
            loop: previous.loop,
            playbackRate: previous.playbackRate.value
        )
        let updated = try mediaMap.replacingEntry(for: state, path: path, with: replacement)
        try publishMediaMap(updated)
        applyPublishedMediaMap(updated)
    }

    private func removeMedia(
        for state: PetState,
        path: String,
        mode: ManagedMediaRemovalMode
    ) {
        guard !mediaMutationInProgress else { return }
        switch mode {
        case .libraryOnly:
            do {
                let updated = try mediaMap.removingEntry(for: state, path: path)
                try publishMediaMap(updated)
                if activeOneShotPreview?.libraryState == state,
                   activeOneShotPreview?.playback.path == path {
                    cancelActiveOneShotWithoutRestore(reason: "media_removed")
                }
                applyPublishedMediaMap(updated)
                settingsController?.update(
                    activity: .succeeded(state, "Clip removed from state; files kept on disk")
                )
            } catch {
                settingsController?.update(
                    activity: .failed(state, "The clip could not be removed from this state.")
                )
            }
        case .moveManagedFilesToTrash:
            let plan: ManagedMediaRemovalPlan
            let trashSnapshot: ManagedMediaTrashSnapshot
            let originalMap = mediaMap
            do {
                plan = try ManagedMediaRemovalPlanner.plan(
                    mediaMap: mediaMap,
                    mapURL: mediaMapURL,
                    state: state,
                    path: path,
                    canonicalRoot: canonicalManagedMediaRoot
                )
                let libraryMaps = try allCharacterMediaMaps()
                guard !plan.trashURLs.contains(where: { target in
                    libraryMaps.contains { character, map, mapURL in
                        guard character.id != characterLibrary.activeCharacterID else { return false }
                        return mediaMap(map, at: mapURL, references: target)
                    }
                }) else {
                    throw PetContractError.invalidValue(
                        "This media is shared by another character. Remove only the library entry to keep that character working."
                    )
                }
                trashSnapshot = try ManagedMediaTrashRevalidator.captureLibrary(
                    targetURLs: plan.trashURLs,
                    maps: libraryMaps.map { character, map, mapURL in
                        ManagedMediaTrashMap(url: mapURL, map: map)
                    },
                    catalogURL: characterLibraryStorage.catalogURL,
                    globalTransitionLibrary: managedMediaTrashGlobalTransitionLibrary,
                    canonicalRoot: canonicalManagedMediaRoot
                )
            } catch {
                settingsController?.update(activity: .failed(state, error.localizedDescription))
                return
            }
            mediaMutationInProgress = true
            settingsController?.update(
                activity: .working(
                    state,
                    "Removing clip and moving \(plan.trashURLs.count) managed file\(plan.trashURLs.count == 1 ? "" : "s") to Trash…"
                )
            )
            do {
                try ManagedMediaTrashRevalidator.validateLibraryUnchanged(
                    snapshot: trashSnapshot,
                    canonicalRoot: canonicalManagedMediaRoot
                )
                try publishMediaMap(plan.updatedMap)
                if activeOneShotPreview?.libraryState == state,
                   activeOneShotPreview?.playback.path == path {
                    cancelActiveOneShotWithoutRestore(reason: "media_trashed")
                }
                applyPublishedMediaMap(plan.updatedMap)
            } catch {
                mediaMutationInProgress = false
                handleMediaMapReloadRequest()
                settingsController?.update(
                    activity: .failed(state, "The library could not be updated; no files were moved.")
                )
                return
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let quarantine: ManagedMediaTrashQuarantine
                do {
                    quarantine = try ManagedMediaTrashRevalidator.quarantineLibraryAfterPublish(
                        snapshot: trashSnapshot,
                        publishedMap: ManagedMediaTrashMap(
                            url: self.mediaMapURL,
                            map: plan.updatedMap
                        ),
                        canonicalRoot: self.canonicalManagedMediaRoot
                    )
                } catch {
                    DispatchQueue.main.async {
                        self.mediaMutationInProgress = false
                        do {
                            try ManagedMediaTrashRevalidator.validateLibraryReadyForMapRestore(
                                snapshot: trashSnapshot,
                                publishedMap: ManagedMediaTrashMap(
                                    url: self.mediaMapURL,
                                    map: plan.updatedMap
                                ),
                                canonicalRoot: self.canonicalManagedMediaRoot
                            )
                            try self.publishMediaMap(originalMap)
                            self.applyPublishedMediaMap(originalMap)
                        } catch {
                            self.handleMediaMapReloadRequest()
                        }
                        self.settingsController?.update(
                            activity: .failed(state, error.localizedDescription)
                        )
                        self.refreshDiagnosticsSnapshot()
                        self.refreshSettings()
                    }
                    return
                }
                let moved: Int
                let failed: Int
                do {
                    try FileManager.default.trashItem(
                        at: quarantine.directoryURL,
                        resultingItemURL: nil
                    )
                    moved = quarantine.itemCount
                    failed = 0
                } catch {
                    moved = 0
                    failed = quarantine.itemCount
                }
                DispatchQueue.main.async {
                    self.mediaMutationInProgress = false
                    self.handleMediaMapReloadRequest()
                    if failed == 0 {
                        self.settingsController?.update(
                            activity: .succeeded(
                                state,
                                "Clip removed; moved \(moved) managed file\(moved == 1 ? "" : "s") to Trash"
                            )
                        )
                    } else {
                        self.settingsController?.update(
                            activity: .failed(
                                state,
                                "Clip removed; moved \(moved) file\(moved == 1 ? "" : "s"), but \(failed) could not be moved"
                            )
                        )
                    }
                    self.refreshDiagnosticsSnapshot()
                    self.refreshSettings()
                }
            }
        }
    }

    private var canonicalManagedMediaRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "\(StateletIdentity.applicationSupportRelativePath)/media",
                isDirectory: true
            )
            .standardizedFileURL
    }

    private func copyVerifiedMovieAndReport(
        _ sourceURL: URL,
        reportURL: URL,
        operationToken: PortableMediaOperationToken
    ) throws -> VerifiedMovieCopy {
        let root = mediaMapURL.deletingLastPathComponent()
        let importsRoot = root.appendingPathComponent("imports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: importsRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var importsStatus = stat()
        guard Darwin.lstat(importsRoot.path, &importsStatus) == 0,
              importsStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw PortableMediaCopyError.invalidSource
        }
        let relativeDirectory = "imports/\(versionToken())"
        let destinationDirectory = root.appendingPathComponent(relativeDirectory, isDirectory: true)
        do {
            let copied = try PortableMediaSecureCopier(
                operationCheck: operationToken.check
            ).copyPair(
                movieSource: sourceURL,
                reportSource: reportURL,
                destinationDirectory: destinationDirectory
            )
            return VerifiedMovieCopy(
                directory: destinationDirectory,
                movieURL: copied.movieURL,
                reportURL: copied.reportURL,
                relativePath: "\(relativeDirectory)/\(sourceURL.lastPathComponent)"
            )
        } catch {
            try? FileManager.default.removeItem(at: destinationDirectory)
            throw error
        }
    }

    private func copyIntoMediaDirectory(_ sourceURL: URL, subdirectory: String?) throws -> (url: URL, relativePath: String) {
        let root = mediaMapURL.deletingLastPathComponent()
        let destinationDirectory = subdirectory.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let sourceExtension = sourceURL.pathExtension.lowercased()
        let filename = "\(sourceURL.deletingPathExtension().lastPathComponent.prefix(40))-\(versionToken()).\(sourceExtension)"
        let destination = destinationDirectory.appendingPathComponent(filename)
        let temporary = destinationDirectory.appendingPathComponent(".\(filename).partial-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: sourceURL, to: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try FileManager.default.moveItem(at: temporary, to: destination)
        let relativePath = subdirectory.map { "\($0)/\(filename)" } ?? filename
        return (destination, relativePath)
    }

    private func copyPosterIntoMediaDirectory(_ sourceURL: URL) throws -> (url: URL, relativePath: String) {
        let root = mediaMapURL.deletingLastPathComponent()
        let destinationDirectory = root.appendingPathComponent("posters", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let sourceExtension = sourceURL.pathExtension.lowercased()
        let filename = "\(sourceURL.deletingPathExtension().lastPathComponent.prefix(40))-\(versionToken()).\(sourceExtension)"
        let destination = destinationDirectory.appendingPathComponent(filename)
        try SecurePosterInstaller().install(source: sourceURL, destination: destination)
        return (destination, "posters/\(filename)")
    }

    private func publishMediaMap(_ updated: MediaMap) throws {
        mediaMapEncodedData = try characterLibraryStorage.saveMediaMap(
            updated,
            for: characterLibrary.activeCharacter,
            expectedData: mediaMapEncodedData
        )
    }

    private func publishGlobalTransitionLibrary(_ updated: GlobalTransitionLibrary) throws {
        globalTransitionLibraryEncodedData = try characterLibraryStorage.saveGlobalTransitionLibrary(
            updated,
            expectedData: globalTransitionLibraryEncodedData
        )
    }

    private func applyPublishedGlobalTransitionLibrary(
        _ updated: GlobalTransitionLibrary,
        refreshPlayback: Bool = true
    ) {
        globalTransitionLibrary = updated
        if refreshPlayback {
            apply(state: currentState, forceRefresh: true)
        } else {
            updateStatusMenu()
            refreshSettings()
        }
    }

    private func applyPublishedMediaMap(_ updated: MediaMap, refreshPlayback: Bool = true) {
        mediaMap = updated
        characterClipCounts[characterLibrary.activeCharacterID] = totalClipCount(in: updated)
        applyConfiguredWindowSize()
        if refreshPlayback {
            apply(state: currentState, forceRefresh: true)
        } else {
            updateStatusMenu()
            refreshSettings()
        }
    }

    private func applyWindowSettings(_ update: WindowSettingsUpdate) {
        do {
            let window = try mediaMap.window.replacing(
                width: update.width,
                height: update.height,
                alwaysOnTop: update.alwaysOnTop,
                clickThrough: update.clickThrough,
                fullScreenAuxiliary: update.fullScreenAuxiliary,
                appearance: update.appearance
            )
            let updated = try mediaMap.replacingWindow(window)
            try publishMediaMap(updated)
            options.alwaysOnTopOverride = nil
            options.clickThroughOverride = nil
            clickThrough = update.clickThrough
            panel.ignoresMouseEvents = clickThrough
            sessionActivityPanel?.ignoresMouseEvents = clickThrough
            sessionActivityPanel?.isMovableByWindowBackground = !clickThrough
            applyPublishedMediaMap(updated, refreshPlayback: false)
        } catch {
            presentSettingsError("The window setting could not be saved.")
            refreshSettings()
        }
    }

    private func persistUserResizedWindow(size: NSSize) {
        do {
            let window = try mediaMap.window.replacing(
                width: size.width,
                height: size.height
            )
            let updated = try mediaMap.replacingWindow(window)
            try publishMediaMap(updated)
            applyPublishedMediaMap(updated, refreshPlayback: false)
            savePanelFrame()
            logger.info(
                "event=window_resized width=\(size.width, format: .fixed(precision: 1), privacy: .public) height=\(size.height, format: .fixed(precision: 1), privacy: .public)"
            )
        } catch {
            logger.error("event=window_setting_save_failed setting=user_resize")
            applyConfiguredWindowSize()
            refreshSettings()
        }
    }

    private func persistRuntimeClickThrough(_ value: Bool) throws {
        let window = try mediaMap.window.replacing(clickThrough: value)
        let updated = try mediaMap.replacingWindow(window)
        try publishMediaMap(updated)
        mediaMap = updated
    }

    private func resetPanelPosition() {
        let size = NSSize(width: mediaMap.window.width, height: mediaMap.window.height)
        let frame = WindowFramePolicy.centeredFrame(in: NSScreen.main?.visibleFrame ?? .zero, size: size)
        panel.setFrame(positionStore.clampedFrame(frame), display: true, animate: true)
        savePanelFrame()
    }

    private func revealMedia(for state: PetState, path: String) {
        if let entry = mediaMap.playlist(for: state)?.entry(path: path) {
            let url = mediaMap.resolvedURL(for: entry, relativeTo: mediaMapURL)
            guard FileManager.default.fileExists(atPath: url.path) else {
                revealMediaFolder()
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            revealMediaFolder()
        }
    }

    private func revealMediaMap() {
        if FileManager.default.fileExists(atPath: mediaMapURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([mediaMapURL])
        } else {
            revealMediaFolder()
        }
    }

    private func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    private func revealLogsFolder() {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "\(StateletIdentity.applicationSupportRelativePath)/logs",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: logs,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        NSWorkspace.shared.activateFileViewerSelecting([logs])
    }

    private func refreshDiagnosticsSnapshot() {
        let startup = launchAtLoginManager.status()
        cachedLaunchAtLoginStatus = startup
        let now = Date().timeIntervalSince1970
        let observed = lastPublishedSnapshot
        let accepted = lastAcceptedPublishedSnapshot
        let emittedAge = observed.map { max(0, now - $0.emittedAt) }
        let sourceAge = accepted?.sourceUpdatedAt.map { max(0, now - $0) }
        let latestHookAge = accepted?.latestEventAt.map { max(0, now - $0) }
        let publisherRejections = accepted?.rejectionDiagnostics.reasons ?? [:]
        let combinedRejectionReasons = publisherRejections.merging(
            publicationRejectionReasons,
            uniquingKeysWith: { min(1_000_000, $0 + $1) }
        )
        let combinedRejectionCount = min(
            1_000_000,
            (accepted?.rejectionDiagnostics.count ?? 0)
                + publicationRejectionReasons.values.reduce(0, +)
        )
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "developer"
        let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "developer"
        let playbackMode = mediaMap.playlist(for: currentState)?.mode.rawValue ?? "unmapped"
        let input = PetDiagnosticsInput(
            appVersion: appVersion,
            appBuild: appBuild,
            lifecycleState: currentState.rawValue,
            publisherHealth: publisherHealth.rawValue,
            publisherSource: accepted?.source ?? "unavailable",
            emittedAgeSeconds: emittedAge,
            observedAgeSeconds: sourceAge,
            activeSessionCount: accepted?.activeSessions,
            latestHookEvent: accepted?.latestEvent,
            latestHookAgeSeconds: latestHookAge,
            observedPublicationRevision: observed?.publicationRevision,
            acceptedLifecycleState: accepted?.state.rawValue,
            acceptedPublicationRevision: accepted?.publicationRevision,
            publisherRecovery: accepted?.recovery,
            overrideStatus: temporaryStatePreviewPolicy.previewState == nil ? "inactive" : "active",
            fallbackReason: publisherHealth.usesIdleFallback
                ? publisherHealth.rawValue
                : lastPublicationRejectionReason,
            publicationRejectionCount: combinedRejectionCount,
            publicationRejectionReasons: combinedRejectionReasons,
            playbackMode: playbackMode,
            selectedClipName: player?.currentURL?.lastPathComponent,
            previewStatus: diagnosticsPresentationStatus,
            toolchainStatus: diagnosticsToolchainStatus,
            lastFailureCategory: publisherHealth.usesIdleFallback ? publisherHealth.rawValue : nil,
            conversionFailureCategory: lastConversionFailureDiagnostic?.code,
            conversionFailureStage: lastConversionFailureDiagnostic?.stage,
            preferencesMigrationStatus: preferencesMigrationStatus
        )
        cachedDiagnosticsReport = diagnostics.build(input: input)
        refreshSettings()
    }

    private var diagnosticsPresentationStatus: String {
        guard let player else { return "unavailable" }
        switch player.presentationStatus {
        case .awaiting: return "awaiting"
        case .preparing: return "preparing"
        case .presented: return "presented"
        case .previewing: return "play-once"
        case .placeholder: return "placeholder"
        case .retained: return "retained-fallback"
        }
    }

    private var diagnosticsToolchainStatus: String {
        switch toolchainState {
        case .checking: return "checking"
        case .ready: return "ready"
        case .unavailable: return "unavailable"
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            cachedLaunchAtLoginStatus = try launchAtLoginManager.setEnabled(enabled)
            refreshDiagnosticsSnapshot()
        } catch {
            presentSettingsError(error.localizedDescription)
            refreshDiagnosticsSnapshot()
        }
    }

    private func repairStartupInstallation() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Repair Statelet Startup?"
        alert.informativeText = "This recreates only Statelet’s managed player startup item. It does not change Codex hooks, the lifecycle publisher, or any Serial service."
        alert.addButton(withTitle: "Repair Startup")
        alert.addButton(withTitle: "Cancel")
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                self.cachedLaunchAtLoginStatus = try self.launchAtLoginManager.repairStartup()
                self.refreshDiagnosticsSnapshot()
            } catch {
                self.presentSettingsError(error.localizedDescription)
                self.refreshDiagnosticsSnapshot()
            }
        }
        if let window = settingsController?.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func cleanUnusedMedia() {
        guard !mediaMutationInProgress else { return }
        let candidates: [URL]
        do {
            candidates = try unusedMediaCandidates()
        } catch {
            presentSettingsError("Statelet could not safely inspect the Media folder.")
            return
        }
        guard !candidates.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No Unused Media"
            alert.informativeText = "Every managed media file is currently referenced, or no safe cleanup candidates were found."
            alert.addButton(withTitle: "OK")
            if let window = settingsController?.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
            return
        }

        let totalBytes = candidates.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
        let names = candidates.prefix(8).map(\.lastPathComponent).joined(separator: "\n")
        let extra = candidates.count > 8 ? "\n…and \(candidates.count - 8) more" : ""
        let formattedSize = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move \(candidates.count) Unused File\(candidates.count == 1 ? "" : "s") to Trash?"
        alert.informativeText = "Only unreferenced media inside Statelet’s managed Media folder will be moved. This can be recovered from Trash.\n\n\(names)\(extra)\n\nApproximate size: \(formattedSize)"
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let currentCandidates = (try? self.unusedMediaCandidates()) ?? []
            let approved = Set(candidates.map { $0.standardizedFileURL.path })
            let targets = currentCandidates.filter { approved.contains($0.standardizedFileURL.path) }
            guard !targets.isEmpty else {
                self.refreshDiagnosticsSnapshot()
                return
            }
            let cleanupSnapshot: ManagedMediaTrashSnapshot
            do {
                let libraryMaps = try self.allCharacterMediaMaps()
                cleanupSnapshot = try ManagedMediaTrashRevalidator.captureUnusedLibrary(
                    targetURLs: targets,
                    maps: libraryMaps.map { _, map, mapURL in
                        ManagedMediaTrashMap(url: mapURL, map: map)
                    },
                    catalogURL: self.characterLibraryStorage.catalogURL,
                    globalTransitionLibrary: self.managedMediaTrashGlobalTransitionLibrary,
                    canonicalRoot: self.canonicalManagedMediaRoot
                )
            } catch {
                self.presentSettingsError("The media libraries changed before cleanup. No files were moved.")
                self.refreshDiagnosticsSnapshot()
                return
            }
            self.mediaMutationInProgress = true
            self.settingsController?.update(
                activity: .working(self.currentState, "Moving \(targets.count) unused media file\(targets.count == 1 ? "" : "s") to Trash…")
            )
            DispatchQueue.global(qos: .utility).async {
                var moved = 0
                var failed = 0
                do {
                    try ManagedMediaTrashRevalidator.validateUnusedLibraryUnchanged(
                        snapshot: cleanupSnapshot,
                        canonicalRoot: self.canonicalManagedMediaRoot
                    )
                    let quarantine = try ManagedMediaTrashRevalidator.quarantineLibraryAfterPublish(
                        snapshot: cleanupSnapshot,
                        publishedMap: ManagedMediaTrashMap(
                            url: self.mediaMapURL,
                            map: self.mediaMap
                        ),
                        canonicalRoot: self.canonicalManagedMediaRoot
                    )
                    try FileManager.default.trashItem(
                        at: quarantine.directoryURL,
                        resultingItemURL: nil
                    )
                    moved = targets.count
                } catch {
                    failed = targets.count
                }
                DispatchQueue.main.async {
                    self.mediaMutationInProgress = false
                    if failed == 0 {
                        self.settingsController?.update(
                            activity: .succeeded(self.currentState, "Moved \(moved) unused file\(moved == 1 ? "" : "s") to Trash")
                        )
                    } else {
                        self.settingsController?.update(
                            activity: .failed(self.currentState, "Moved \(moved); \(failed) file\(failed == 1 ? "" : "s") could not be moved")
                        )
                    }
                    self.refreshDiagnosticsSnapshot()
                }
            }
        }
        if let window = settingsController?.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func unusedMediaCandidates() throws -> [URL] {
        let canonicalRoot = canonicalManagedMediaRoot
        let canonicalMap = canonicalRoot.appendingPathComponent("media-map.json").standardizedFileURL
        let configuredMap = configuredMediaMapURL.standardizedFileURL
        let rootValues = try canonicalRoot.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard configuredMap.path == canonicalMap.path,
              configuredMap.resolvingSymlinksInPath().path == canonicalMap.path,
              rootValues.isSymbolicLink != true,
              canonicalRoot.resolvingSymlinksInPath().path == canonicalRoot.path else {
            throw PetContractError.invalidValue(
                "unused-media cleanup requires the canonical managed media map"
            )
        }
        let root = canonicalRoot
        var referenced = Set<String>()
        referenced.insert(characterLibraryStorage.catalogURL.standardizedFileURL.path)
        referenced.insert(
            characterLibraryStorage.globalTransitionLibraryURL.standardizedFileURL.path
        )
        let globalLibraryURL = characterLibraryStorage.globalTransitionLibraryURL
        for entry in globalTransitionLibrary.allEntries {
            let movie = globalTransitionLibrary.resolvedURL(
                for: entry,
                relativeTo: globalLibraryURL
            ).resolvingSymlinksInPath().standardizedFileURL
            if isInsideManagedMedia(movie, root: root) {
                referenced.insert(movie.path)
                referenced.insert(
                    movie.deletingPathExtension()
                        .appendingPathExtension("report.json")
                        .standardizedFileURL.path
                )
            }
            if let poster = globalTransitionLibrary.resolvedPosterURL(
                for: entry,
                relativeTo: globalLibraryURL
            )?.resolvingSymlinksInPath().standardizedFileURL,
               isInsideManagedMedia(poster, root: root) {
                referenced.insert(poster.path)
            }
        }
        for (character, map, mapURL) in try allCharacterMediaMaps() {
            referenced.insert(
                character.resolvedMapURL(relativeTo: configuredMediaMapURL)
                    .resolvingSymlinksInPath().standardizedFileURL.path
            )
            for entry in allMediaEntries(in: map) {
                    let movie = map.resolvedURL(for: entry, relativeTo: mapURL)
                    .resolvingSymlinksInPath().standardizedFileURL
                    if isInsideManagedMedia(movie, root: root) {
                        referenced.insert(movie.path)
                        referenced.insert(
                            movie.deletingPathExtension()
                                .appendingPathExtension("report.json")
                                .standardizedFileURL.path
                        )
                    }
                    if let poster = map.resolvedPosterURL(for: entry, relativeTo: mapURL)?
                        .resolvingSymlinksInPath().standardizedFileURL,
                       isInsideManagedMedia(poster, root: root) {
                        referenced.insert(poster.path)
                    }
            }
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in false }
        ) else { return [] }
        var candidates: [URL] = []
        for case let rawURL as URL in enumerator {
            let values = try rawURL.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let url = rawURL.resolvingSymlinksInPath().standardizedFileURL
            guard isInsideManagedMedia(url, root: root), !referenced.contains(url.path) else { continue }
            let lowercaseName = url.lastPathComponent.lowercased()
            let allowedExtension = ["mov", "mp4", "m4v", "png", "jpg", "jpeg", "heic"]
                .contains(url.pathExtension.lowercased())
            guard allowedExtension || lowercaseName.hasSuffix(".report.json") else { continue }
            candidates.append(url)
        }
        return candidates.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func isInsideManagedMedia(_ url: URL, root: URL) -> Bool {
        url.path.hasPrefix(root.path + "/")
    }

    private func prepareMediaDirectory() throws {
        try FileManager.default.createDirectory(
            at: mediaMapURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func versionToken() -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        return "\(timestamp)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    private func presentSettingsError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Statelet"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let settingsWindow = settingsController?.window {
            alert.beginSheetModal(for: settingsWindow)
        } else {
            alert.runModal()
        }
    }

    private static func sha256Hex(
        of url: URL,
        operationCheck: () throws -> Void = {}
    ) throws -> String {
        try operationCheck()
        guard url.isFileURL, url.host.map({ $0.isEmpty || $0 == "localhost" }) ?? true else {
            throw PortableMediaCopyError.nonLocalFile
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PortableMediaCopyError.invalidSource }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_size >= 0,
              UInt64(before.st_size) <= PortableMediaCopyLimits().maxMovieBytes else {
            throw PortableMediaCopyError.invalidSource
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try operationCheck()
            hasher.update(data: chunk)
        }
        try operationCheck()
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw PortableMediaCopyError.sourceChanged
        }
        try operationCheck()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @objc private func revealMediaFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([mediaMapURL.deletingLastPathComponent()])
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func savePanelFrame() {
        guard let panel else { return }
        let screen = NSScreen.screens.max {
            $0.visibleFrame.intersection(panel.frame).area < $1.visibleFrame.intersection(panel.frame).area
        }
        positionStore.save(frame: panel.frame, on: screen ?? NSScreen.main)
    }

    private func schedulePositionSave() {
        positionSaveWorkItem?.cancel()
        positionSaveGeneration &+= 1
        let generation = positionSaveGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, generation == self.positionSaveGeneration else { return }
            self.positionSaveWorkItem = nil
            self.savePanelFrame()
        }
        positionSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Self.positionSaveDebounceMilliseconds),
            execute: workItem
        )
    }
}

private extension NSRect {
    var area: CGFloat { max(0, width) * max(0, height) }
}
