import AppKit
import CodexPetCore
import CryptoKit
import Darwin
import OSLog
import Security
import UniformTypeIdentifiers

private struct LaunchOptions {
    var mediaMapURL: URL
    var stateURL: URL
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
        var options = LaunchOptions(
            mediaMapURL: defaultMap,
            stateURL: defaultState,
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

private struct VerifiedMovieInstall: Sendable {
    let directory: URL
    let movieURL: URL
    let reportURL: URL
    let relativePath: String
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
    let outputBasename: String
    let reportBasename: String
    let invocationChallenge: String
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
    private var characterClipCounts: [String: Int] = [:]
    private let characterMetadataQueue = DispatchQueue(
        label: "com.coke1120.CodexPetMac.character-metadata",
        qos: .utility
    )
    private let lifecycleStateReader = LifecycleStateFileReader()
    private var characterCountRefreshGeneration: UInt64 = 0
    private var panel: PetPanel!
    private var player: PetPlayerController!
    private var stateWatcher: StateDirectoryWatcher!
    private var mapWatcher: StateDirectoryWatcher!
    private var characterLibraryWatcher: StateDirectoryWatcher!
    private var healthCheckTimer: DispatchSourceTimer?
    private var positionSaveWorkItem: DispatchWorkItem?
    private var positionSaveGeneration: UInt64 = 0
    private var positionStore = PositionStore()
    private var statusItem: NSStatusItem!
    private var clickThrough = false
    private var currentState: PetState = .idle
    private var lastPublishedSnapshot: CurrentState?
    private var lastLifecycleStateForSelection: PetState?
    private var lastPresentedState: PetState?
    private var pendingPresentationState: PetState?
    private var stateDialoguePresentation: StateDialoguePresentation?
    private var publisherHealth: PublisherHealth = .unknown
    private var mapReadFailureReported = false
    private var reduceMotion = false
    private var transitionSequence: UInt64 = 0
    private var mediaSelectionCursor = MediaSelectionCursor()
    private var manualPreviewSelectionCursor = MediaSelectionCursor()
    private var temporaryStatePreviewPolicy = TemporaryStatePreviewPolicy()
    private var oneShotArbiter = OneShotPlaybackArbiter()
    private var activeOneShotPreview: ActiveOneShotPreview?
    private var settingsController: SettingsWindowController?
    private var dialogueVoiceCoordinator: DialogueVoiceCoordinator!
    private let toolchainDiscovery = AlphaToolchainDiscovery()
    private var toolchainState: AlphaToolchainState = .checking
    private let conversionCoordinator = AlphaConversionCoordinator()
    private var conversionProfile: AlphaConversionProfile = .fill
    private let launchAtLoginManager = LaunchAtLoginManager()
    private let diagnostics = PetDiagnostics()
    private var cachedLaunchAtLoginStatus: LaunchAtLoginManager.Status?
    private var cachedDiagnosticsReport = "Open Diagnostics and choose Refresh to inspect this Mac."
    private var activeMP4BatchID: UUID?
    private var lastFailedMP4Batch: FailedMP4Batch?
    private var lastConversionFailureDiagnostic: (code: String, stage: String)?
    private var pendingRecoveryNotice: (PetState, String)?
    private var mp4BatchCancellationRequested = false
    private var mediaMapReloadDeferred = false
    private var characterLibraryReloadDeferred = false
    private var pendingCharacterBundleOpenURL: URL?
    private var mediaMutationInProgress = false {
        didSet {
            if oldValue, !mediaMutationInProgress {
                applyDeferredMediaMapReloadIfNeeded()
                applyDeferredCharacterLibraryReloadIfNeeded()
                processPendingCharacterBundleOpenIfPossible()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        conversionProfile = AlphaConversionProfile.restored()
        options = LaunchOptions.parse(arguments: CommandLine.arguments)
        configuredMediaMapURL = options.mediaMapURL
        configureCharacterLibrary()
        loadMediaMap()
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
        player.onPlaylistClipEnded = { [weak self] transitionID, state in
            self?.advancePlaylistAfterClipEnd(transitionID: transitionID, state: state)
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
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        player.setReduceMotion(reduceMotion)
        clickThrough = options.clickThroughOverride ?? configuredWindow.clickThrough
        panel.ignoresMouseEvents = clickThrough
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
            readState(from: options.stateURL)
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
        stateWatcher?.stop()
        mapWatcher?.stop()
        characterLibraryWatcher?.stop()
        healthCheckTimer?.cancel()
        healthCheckTimer = nil
        positionSaveGeneration &+= 1
        positionSaveWorkItem?.cancel()
        positionSaveWorkItem = nil
        _ = conversionCoordinator.terminateAndWait()
        dialogueVoiceCoordinator?.shutdown()
        savePanelFrame()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func windowDidMove(_ notification: Notification) { schedulePositionSave() }
    func windowDidResize(_ notification: Notification) { schedulePositionSave() }
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
        installMapWatcher()
        characterLibraryWatcher = StateDirectoryWatcher(fileURL: characterLibraryStorage.catalogURL)
        characterLibraryWatcher.start(emitInitial: false) { [weak self] _ in
            self?.handleCharacterLibraryReloadRequest()
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
            self.readState(from: self.options.stateURL)
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
        cancelActiveOneShotWithoutRestore(reason: "character_changed")
        _ = temporaryStatePreviewPolicy.cancel()
        player?.clearTransientPresentation()
        mediaSelectionCursor = MediaSelectionCursor()
        manualPreviewSelectionCursor = MediaSelectionCursor()
        lastLifecycleStateForSelection = nil
        lastPresentedState = nil
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
        map.states.values.reduce(0) { $0 + $1.entries.count }
    }

    private func applyConfiguredWindowSize() {
        guard let panel else { return }
        let size = NSSize(width: mediaMap.window.width, height: mediaMap.window.height)
        let resized = WindowFramePolicy.applyingConfiguredSize(size, to: panel.frame)
        panel.setFrame(positionStore.clampedFrame(resized), display: true)
        clickThrough = options.clickThroughOverride ?? mediaMap.window.clickThrough
        panel.ignoresMouseEvents = clickThrough
        panel.apply(
            alwaysOnTop: options.alwaysOnTopOverride ?? mediaMap.window.alwaysOnTop,
            fullScreenAuxiliary: mediaMap.window.fullScreenAuxiliary
        )
        player?.applyAppearance(mediaMap.window.appearance)
    }

    private func readState(from url: URL) {
        lifecycleStateReader.read(url) { [weak self] result in
            self?.applyLifecycleStateReadResult(result)
        }
    }

    private func applyLifecycleStateReadResult(_ result: LifecycleStateReadResult) {
        switch result {
        case .missing:
            lastPublishedSnapshot = nil
            rejectPublisher(.missing)
        case .corrupt:
            lastPublishedSnapshot = nil
            rejectPublisher(.corrupt)
        case let .state(state):
            applyLifecycleState(state)
        }
    }

    private func applyLifecycleState(_ state: CurrentState) {
        lastPublishedSnapshot = state
        switch freshnessPolicy.freshness(of: state, now: Date().timeIntervalSince1970) {
        case .fresh:
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
        case .stale:
            rejectPublisher(.stale)
        case .futureSkew:
            rejectPublisher(.futureSkew)
        }
    }

    private func rejectPublisher(_ health: PublisherHealth) {
        setPublisherHealth(health)
        apply(state: .idle)
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
                player.clearTransientPresentation()
                lastPresentedState = nil
                pendingPresentationState = nil
            case .continuing:
                break
            case let .preempted(preview):
                activeOneShotPreview = nil
                player.clearTransientPresentation()
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
        currentState = state
        let shouldRefreshUI = LifecycleUIRefreshPolicy.shouldRefresh(
            previousProducerState: previousProducerState,
            incomingProducerState: state,
            presentationWillRefresh: decision.shouldRefresh
        )
        guard decision.shouldRefresh else {
            if shouldRefreshUI {
                updateStatusMenu()
                refreshSettings()
            }
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

    private func startLifecyclePresentation(
        state: PetState,
        advanceSelection: Bool,
        refreshReason: String,
        useManualPreviewCursor: Bool = false,
        explicitUserAdvance: Bool = false
    ) {
        if stateDialoguePresentation?.state != state {
            let keepSpokenMessage = dialogueVoiceCoordinator.isAutomaticPlaybackActive
            dialogueVoiceCoordinator.cancelAutomaticPlayback()
            stateDialoguePresentation = nil
            if !keepSpokenMessage {
                player?.view.showDialogueMessage(nil)
            }
        }
        let started = DispatchTime.now().uptimeNanoseconds
        transitionSequence &+= 1
        let transitionID = transitionSequence
        let entry = selectedEntry(
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
            lastPresentedState = state
            pendingPresentationState = nil
            presentStateOwnedDialogueIfNeeded(for: state)
        case .preparing:
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
        pendingPresentationState = nil
        logger.info("event=playlist_advance_triggered transition_id=\(transitionID, privacy: .public) state=\(state.rawValue, privacy: .public) reason=clip_end")
        startLifecyclePresentation(
            state: state,
            advanceSelection: true,
            refreshReason: "clip_end",
            useManualPreviewCursor: temporaryStatePreviewPolicy.previewState != nil
        )
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
            lastPresentedState = state
            presentStateOwnedDialogueIfNeeded(for: state)
            logger.info("event=presentation_committed transition_id=\(transitionID, privacy: .public) state=\(state.rawValue, privacy: .public)")
        case .failed:
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

        cancelActiveOneShotWithoutRestore(reason: "temporary_state_changed")
        if temporaryStatePreviewPolicy.previewState == nil {
            manualPreviewSelectionCursor = mediaSelectionCursor
        }
        player.clearTransientPresentation()
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
        cancelActiveOneShotWithoutRestore(reason: "temporary_state_relinquished")
        player.clearTransientPresentation()
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
        settingsController?.show()
    }

    private func makeSettingsController() -> SettingsWindowController {
        let controller = SettingsWindowController()
        controller.onImportMP4 = { [weak self] state in self?.chooseMP4(for: state) }
        controller.onDropMP4s = { [weak self] state, urls in self?.importMP4s(urls, for: state) }
        controller.onUseMovie = { [weak self] state in self?.chooseTransparentMovie(for: state) }
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
        controller.onRefreshDiagnostics = { [weak self] in self?.refreshDiagnosticsSnapshot() }
        controller.onRepairInstallation = { [weak self] in self?.repairStartupInstallation() }
        controller.onLaunchAtLoginChange = { [weak self] enabled in self?.setLaunchAtLogin(enabled) }
        controller.onCleanUnusedMedia = { [weak self] in self?.cleanUnusedMedia() }
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
                            case let .success(report):
                                do {
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
        guard activeMP4BatchID != nil else { return }
        mp4BatchCancellationRequested = true
        conversionCoordinator.cancel()
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
        let mediaDirectory = mediaMapURL.deletingLastPathComponent()
        guard let data = try? PortableMediaSecureCopier.readRegularFile(
                  at: journalURL,
                  maximumBytes: PortableMediaCopyLimits().maxReportBytes
              ),
              let journal = try? JSONDecoder().decode(ActiveConversionJournal.self, from: data),
              let state = PetState(rawValue: journal.state),
              AlphaRecoveryArtifactPolicy.accepts(
                  stateRawValue: state.rawValue,
                  outputBasename: journal.outputBasename,
                  reportBasename: journal.reportBasename
              ),
              Self.isValidInvocationChallenge(journal.invocationChallenge) else {
            try? FileManager.default.removeItem(at: journalURL)
            return
        }
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
                    let outputReferenced = self.isMediaPathReferenced(outputURL)
                    let reportReferenced = self.isMediaPathReferenced(reportURL)
                    let shouldQuarantine = AlphaRecoveryArtifactPolicy.shouldQuarantine(
                        outputReferenced: outputReferenced,
                        reportReferenced: reportReferenced
                    )
                    let quarantined = shouldQuarantine
                        ? self.quarantineFailedRecoveryArtifacts(
                            outputURL: outputURL,
                            reportURL: reportURL
                        )
                        : 0
                    let isReferenced = outputReferenced || reportReferenced
                    self.clearConversionJournal()
                    let notice: String
                    if isReferenced {
                        notice = "Interrupted conversion could not be recovered. Existing library media was left unchanged."
                    } else if quarantined > 0 {
                        notice = "Interrupted conversion could not be recovered. \(quarantined) file\(quarantined == 1 ? " was" : "s were") moved to private recovery quarantine; Clean Unused Media can remove them later."
                    } else {
                        notice = "Interrupted conversion could not be recovered. No managed media files were changed."
                    }
                    self.pendingRecoveryNotice = (state, notice)
                    self.settingsController?.update(activity: .failed(state, notice))
                    self.logger.error("event=animation_recovery_quarantined state=\(state.rawValue, privacy: .public) files=\(quarantined, privacy: .public) referenced=\(isReferenced, privacy: .public) cleanup=unused_media")
                case .success:
                    do {
                        let alreadyInstalled = self.mediaMap.playlist(for: state)?
                            .entries.contains(where: { $0.path == journal.outputBasename }) == true
                        if !alreadyInstalled {
                            try self.installMediaEntry(for: state, path: journal.outputBasename)
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

    private static func isValidInvocationChallenge(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private func isMediaPathReferenced(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.path
        do {
            return try allCharacterMediaMaps().contains { _, map, mapURL in
                map.states.values.contains { playlist in
                    playlist.entries.contains { entry in
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
                return map.states.values.contains { playlist in
                    playlist.entries.contains { entry in
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
            }
        } catch {
            return true
        }
    }

    private func mediaMap(_ map: MediaMap, at mapURL: URL, references url: URL) -> Bool {
        let target = url.standardizedFileURL.path
        return map.states.values.contains { playlist in
            playlist.entries.contains { entry in
                let movie = map.resolvedURL(for: entry, relativeTo: mapURL).standardizedFileURL
                return movie.path == target
                    || movie.deletingPathExtension().appendingPathExtension("report.json")
                        .standardizedFileURL.path == target
                    || map.resolvedPosterURL(for: entry, relativeTo: mapURL)?
                        .standardizedFileURL.path == target
            }
        }
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

    private func quarantineFailedRecoveryArtifacts(outputURL: URL, reportURL: URL) -> Int {
        let mediaDirectory = mediaMapURL.deletingLastPathComponent()
        let quarantineDirectory = mediaDirectory.appendingPathComponent(
            ".recovery-quarantine",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: quarantineDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch CocoaError.fileWriteFileExists {
            // Existing quarantine is accepted only after the no-follow open below.
        } catch {
            return 0
        }
        let sourceDirectoryDescriptor = Darwin.open(
            mediaDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard sourceDirectoryDescriptor >= 0 else { return 0 }
        defer { Darwin.close(sourceDirectoryDescriptor) }
        let quarantineDescriptor = Darwin.open(
            quarantineDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard quarantineDescriptor >= 0 else { return 0 }
        defer { Darwin.close(quarantineDescriptor) }
        guard Darwin.fchmod(quarantineDescriptor, mode_t(S_IRWXU)) == 0 else { return 0 }

        var moved = 0
        let suffix = versionToken()
        for sourceURL in [outputURL, reportURL] {
            let sourceName = sourceURL.lastPathComponent
            guard sourceURL.deletingLastPathComponent().standardizedFileURL == mediaDirectory.standardizedFileURL else {
                continue
            }
            let sourceDescriptor = Darwin.openat(
                sourceDirectoryDescriptor,
                sourceName,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
            guard sourceDescriptor >= 0 else { continue }
            var sourceStatus = stat()
            let isRegular = Darwin.fstat(sourceDescriptor, &sourceStatus) == 0
                && sourceStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            if isRegular { _ = Darwin.fchmod(sourceDescriptor, mode_t(S_IRUSR | S_IWUSR)) }
            Darwin.close(sourceDescriptor)
            guard isRegular else { continue }
            let destinationName = "\(suffix)-\(sourceName)"
            guard Darwin.renameat(
                sourceDirectoryDescriptor,
                sourceName,
                quarantineDescriptor,
                destinationName
            ) == 0 else { continue }
            moved += 1
        }
        _ = Darwin.fsync(sourceDirectoryDescriptor)
        _ = Darwin.fsync(quarantineDescriptor)
        return moved
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
            try await validatePortableMovie(installed, allowPortableClaim: allowPortableClaim)
        } catch {
            try? FileManager.default.removeItem(at: installed.directory)
            throw error
        }
        return installed
    }

    private static func validateLocallyAttestedMovie(
        outputURL: URL,
        reportURL: URL,
        expectedOutputBasename: String,
        invocationChallenge: String,
        expectedInitialReportData: Data?
    ) throws -> ValidatedAlphaConversionReport {
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
        _ = try AlphaPlaybackProcessValidator.validate(url: outputURL, expected: report)

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
        return report
    }

    private func validatePortableMovie(
        _ installed: VerifiedMovieInstall,
        allowPortableClaim: Bool
    ) async throws {
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
            _ = try AlphaPlaybackProcessValidator.validate(
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
            transitionSequence &+= 1
            let transitionID = transitionSequence
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
        player.clearOneShotPresentation()
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
        player.clearOneShotPresentation()
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
        player.clearOneShotPresentation()
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
    ) throws -> VerifiedMovieInstall {
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
            return VerifiedMovieInstall(
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
        let published = lastPublishedSnapshot
        let emittedAge = published.map { max(0, now - $0.emittedAt) }
        let sourceAge = published?.sourceUpdatedAt.map { max(0, now - $0) }
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
            publisherSource: published?.source ?? "unavailable",
            emittedAgeSeconds: emittedAge,
            observedAgeSeconds: sourceAge,
            activeSessionCount: published?.activeSessions,
            playbackMode: playbackMode,
            selectedClipName: player?.currentURL?.lastPathComponent,
            previewStatus: diagnosticsPresentationStatus,
            toolchainStatus: diagnosticsToolchainStatus,
            lastFailureCategory: publisherHealth.usesIdleFallback ? publisherHealth.rawValue : nil,
            conversionFailureCategory: lastConversionFailureDiagnostic?.code,
            conversionFailureStage: lastConversionFailureDiagnostic?.stage
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
            self.mediaMutationInProgress = true
            self.settingsController?.update(
                activity: .working(self.currentState, "Moving \(targets.count) unused media file\(targets.count == 1 ? "" : "s") to Trash…")
            )
            DispatchQueue.global(qos: .utility).async {
                var moved = 0
                var failed = 0
                for target in targets {
                    do {
                        try FileManager.default.trashItem(at: target, resultingItemURL: nil)
                        moved += 1
                    } catch {
                        failed += 1
                    }
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
        for (character, map, mapURL) in try allCharacterMediaMaps() {
            referenced.insert(
                character.resolvedMapURL(relativeTo: configuredMediaMapURL)
                    .resolvingSymlinksInPath().standardizedFileURL.path
            )
            for playlist in map.states.values {
                for entry in playlist.entries {
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
