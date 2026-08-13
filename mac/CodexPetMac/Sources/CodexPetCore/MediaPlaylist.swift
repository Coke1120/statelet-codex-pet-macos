import Foundation

public enum MediaPlaybackMode: String, Codable, CaseIterable, Sendable {
    case fixed
    case random
    case sequential
}

public enum MediaPlaylistAdvancePolicy: String, Codable, CaseIterable, Sendable {
    case stateEntry = "state_entry"
    case clipEnd = "clip_end"
}

public enum MediaSelectionAdvancePolicy {
    /// Playlist cursors advance only when the published lifecycle state enters
    /// a different state. Retries, heartbeats, map edits, and other forced
    /// refreshes retain the selected clip when it remains eligible.
    public static func shouldAdvance(
        previousLifecycleState: PetState?,
        incomingState: PetState,
        forceRefresh: Bool
    ) -> Bool {
        !forceRefresh && previousLifecycleState != incomingState
    }
}

public enum PlaybackFallbackPolicy {
    /// A known-good lifecycle clip may be retained for a missing non-idle
    /// mapping, but a one-shot preview must never become lifecycle fallback.
    public static func shouldRetainCurrentPresentation(
        hasCurrentMedia: Bool,
        currentIsOneShot: Bool,
        requestedState: PetState
    ) -> Bool {
        hasCurrentMedia && !currentIsOneShot && requestedState != .idle
    }
}

/// An in-memory override for manually previewing lifecycle presentation.
/// The preview survives baseline heartbeats, but the first real lifecycle
/// transition relinquishes it so lifecycle state remains authoritative.
public enum TemporaryStatePreviewLifecycleOutcome: Equatable, Sendable {
    case presentingPreview(PetState)
    case presentingLifecycle(PetState)
}

public struct TemporaryStatePreviewPolicy: Equatable, Sendable {
    public private(set) var realState: PetState?
    public private(set) var previewState: PetState?

    public init() {}

    public var presentedState: PetState? {
        previewState ?? realState
    }

    @discardableResult
    public mutating func begin(
        previewState: PetState,
        baselineRealState: PetState? = nil
    ) -> PetState {
        realState = baselineRealState
        self.previewState = previewState
        return previewState
    }

    @discardableResult
    public mutating func receiveLifecycleState(
        _ incomingState: PetState
    ) -> TemporaryStatePreviewLifecycleOutcome {
        if previewState != nil, incomingState != realState {
            self.previewState = nil
            realState = incomingState
            return .presentingLifecycle(incomingState)
        }

        realState = incomingState
        if let previewState {
            return .presentingPreview(previewState)
        }
        return .presentingLifecycle(incomingState)
    }

    @discardableResult
    public mutating func cancel() -> PetState? {
        previewState = nil
        return realState
    }
}

public struct StateMediaPlaylist: Codable, Equatable, Sendable {
    public let mode: MediaPlaybackMode
    public let advanceOn: MediaPlaylistAdvancePolicy
    public let fixedPath: String
    public let entries: [MediaEntry]

    public init(
        mode: MediaPlaybackMode = .fixed,
        advanceOn: MediaPlaylistAdvancePolicy = .stateEntry,
        fixedPath: String? = nil,
        entries: [MediaEntry]
    ) throws {
        guard !entries.isEmpty else {
            throw PetContractError.invalidValue("media playlist entries must not be empty")
        }

        var seen = Set<String>()
        for entry in entries {
            guard seen.insert(Self.normalizedPath(entry.path)).inserted else {
                throw PetContractError.invalidValue("media playlist paths must be unique")
            }
        }

        let requestedFixedPath = fixedPath ?? entries[0].path
        guard let fixedEntry = entries.first(where: {
            Self.normalizedPath($0.path) == Self.normalizedPath(requestedFixedPath)
        }) else {
            throw PetContractError.invalidValue("fixed_path must reference a playlist entry")
        }

        self.mode = mode
        self.advanceOn = advanceOn
        self.fixedPath = fixedEntry.path
        self.entries = entries
    }

    public var fixedEntry: MediaEntry {
        entries.first(where: { Self.pathsEqual($0.path, fixedPath) })!
    }

    public var isContinuousRotationEffective: Bool {
        advanceOn == .clipEnd && mode != .fixed && entries.count > 1
    }

    public func entry(path: String) -> MediaEntry? {
        entries.first(where: { Self.pathsEqual($0.path, path) })
    }

    public func appending(_ entry: MediaEntry) throws -> StateMediaPlaylist {
        try StateMediaPlaylist(mode: mode, advanceOn: advanceOn, fixedPath: fixedPath, entries: entries + [entry])
    }

    public func replacing(path: String, with replacement: MediaEntry) throws -> StateMediaPlaylist {
        guard let index = entries.firstIndex(where: { Self.pathsEqual($0.path, path) }) else {
            throw PetContractError.invalidValue("media playlist entry was not found")
        }
        var updated = entries
        updated[index] = replacement
        let updatedFixedPath = Self.pathsEqual(fixedPath, path) ? replacement.path : fixedPath
        return try StateMediaPlaylist(mode: mode, advanceOn: advanceOn, fixedPath: updatedFixedPath, entries: updated)
    }

    /// Returns nil when removing the last entry, allowing the state mapping to
    /// be removed without representing an invalid empty playlist.
    public func removing(path: String) throws -> StateMediaPlaylist? {
        guard let index = entries.firstIndex(where: { Self.pathsEqual($0.path, path) }) else {
            throw PetContractError.invalidValue("media playlist entry was not found")
        }
        guard entries.count > 1 else { return nil }
        var updated = entries
        updated.remove(at: index)
        let updatedFixedPath = Self.pathsEqual(fixedPath, path) ? updated[0].path : fixedPath
        return try StateMediaPlaylist(mode: mode, advanceOn: advanceOn, fixedPath: updatedFixedPath, entries: updated)
    }

    public func changingMode(to mode: MediaPlaybackMode) throws -> StateMediaPlaylist {
        try StateMediaPlaylist(mode: mode, advanceOn: advanceOn, fixedPath: fixedPath, entries: entries)
    }

    public func settingFixed(path: String) throws -> StateMediaPlaylist {
        try StateMediaPlaylist(mode: .fixed, advanceOn: advanceOn, fixedPath: path, entries: entries)
    }

    public func settingAdvanceOn(_ advanceOn: MediaPlaylistAdvancePolicy) throws -> StateMediaPlaylist {
        try StateMediaPlaylist(mode: mode, advanceOn: advanceOn, fixedPath: fixedPath, entries: entries)
    }

    public func movingEntry(path: String, to destinationIndex: Int) throws -> StateMediaPlaylist {
        guard entries.indices.contains(destinationIndex) else {
            throw PetContractError.invalidValue("media playlist destination index is out of bounds")
        }
        guard let sourceIndex = entries.firstIndex(where: { Self.pathsEqual($0.path, path) }) else {
            throw PetContractError.invalidValue("media playlist entry was not found")
        }
        guard sourceIndex != destinationIndex else { return self }

        var updated = entries
        let entry = updated.remove(at: sourceIndex)
        updated.insert(entry, at: destinationIndex)
        return try StateMediaPlaylist(mode: mode, advanceOn: advanceOn, fixedPath: fixedPath, entries: updated)
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case advanceOn = "advance_on"
        case fixedPath = "fixed_path"
        case entries
        // Legacy singleton MediaEntry keys.
        case path
        case posterPath = "poster_path"
        case loop
        case playbackRate = "playback_rate"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.entries) {
            let entries = try container.decode([MediaEntry].self, forKey: .entries)
            try self.init(
                mode: container.decodeIfPresent(MediaPlaybackMode.self, forKey: .mode) ?? .fixed,
                advanceOn: container.decodeIfPresent(MediaPlaylistAdvancePolicy.self, forKey: .advanceOn) ?? .stateEntry,
                fixedPath: container.decodeIfPresent(String.self, forKey: .fixedPath),
                entries: entries
            )
            return
        }

        let legacy = try MediaEntry(from: decoder)
        try self.init(mode: .fixed, advanceOn: .stateEntry, fixedPath: legacy.path, entries: [legacy])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(advanceOn, forKey: .advanceOn)
        try container.encode(fixedPath, forKey: .fixedPath)
        try container.encode(entries, forKey: .entries)
    }

    static func normalizedPath(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if let last = components.last, last != ".." {
                    components.removeLast()
                } else if !isAbsolute {
                    components.append(component)
                }
            } else {
                components.append(component)
            }
        }
        let joined = components.joined(separator: "/")
        return isAbsolute ? "/" + joined : (joined.isEmpty ? "." : joined)
    }

    static func pathsEqual(_ lhs: String, _ rhs: String) -> Bool {
        normalizedPath(lhs) == normalizedPath(rhs)
    }
}

public extension MediaMap {
    func appendingEntry(_ entry: MediaEntry, for state: PetState) throws -> MediaMap {
        var updated = states
        if let playlist = updated[state] {
            updated[state] = try playlist.appending(entry)
        } else {
            updated[state] = try StateMediaPlaylist(entries: [entry])
        }
        return try replacingStates(updated)
    }

    func replacingEntry(for state: PetState, path: String, with replacement: MediaEntry) throws -> MediaMap {
        guard let playlist = states[state] else {
            throw PetContractError.invalidValue("media playlist state was not found")
        }
        var updated = states
        updated[state] = try playlist.replacing(path: path, with: replacement)
        return try replacingStates(updated)
    }

    func removingEntry(for state: PetState, path: String) throws -> MediaMap {
        guard let playlist = states[state] else {
            throw PetContractError.invalidValue("media playlist state was not found")
        }
        var updated = states
        updated[state] = try playlist.removing(path: path)
        return try replacingStates(updated)
    }

    func changingPlaybackMode(for state: PetState, to mode: MediaPlaybackMode) throws -> MediaMap {
        guard let playlist = states[state] else {
            throw PetContractError.invalidValue("media playlist state was not found")
        }
        var updated = states
        updated[state] = try playlist.changingMode(to: mode)
        return try replacingStates(updated)
    }

    func settingFixedEntry(for state: PetState, path: String) throws -> MediaMap {
        guard let playlist = states[state] else {
            throw PetContractError.invalidValue("media playlist state was not found")
        }
        var updated = states
        updated[state] = try playlist.settingFixed(path: path)
        return try replacingStates(updated)
    }

    func settingAdvanceOn(for state: PetState, to advanceOn: MediaPlaylistAdvancePolicy) throws -> MediaMap {
        guard let playlist = states[state] else {
            throw PetContractError.invalidValue("media playlist state was not found")
        }
        var updated = states
        updated[state] = try playlist.settingAdvanceOn(advanceOn)
        return try replacingStates(updated)
    }

    func movingEntry(for state: PetState, path: String, to destinationIndex: Int) throws -> MediaMap {
        guard let playlist = states[state] else {
            throw PetContractError.invalidValue("media playlist state was not found")
        }
        var updated = states
        updated[state] = try playlist.movingEntry(path: path, to: destinationIndex)
        return try replacingStates(updated)
    }

    func settingTransition(from: PetState, to: PetState, entry: MediaEntry) throws -> MediaMap {
        let key = try StateTransitionKey(from: from, to: to)
        var updated = transitions
        updated[key] = try StateMediaPlaylist(entries: [entry])
        return try replacingTransitions(updated)
    }

    func appendingTransitionEntry(_ entry: MediaEntry, from: PetState, to: PetState) throws -> MediaMap {
        let key = try StateTransitionKey(from: from, to: to)
        var updated = transitions
        if let playlist = updated[key] {
            updated[key] = try playlist.appending(entry)
        } else {
            updated[key] = try StateMediaPlaylist(entries: [entry])
        }
        return try replacingTransitions(updated)
    }

    func replacingTransitionEntry(
        from: PetState,
        to: PetState,
        path: String,
        with replacement: MediaEntry
    ) throws -> MediaMap {
        let key = try StateTransitionKey(from: from, to: to)
        guard let playlist = transitions[key] else {
            throw PetContractError.invalidValue("transition playlist was not found")
        }
        var updated = transitions
        updated[key] = try playlist.replacing(path: path, with: replacement)
        return try replacingTransitions(updated)
    }

    func removingTransitionEntry(from: PetState, to: PetState, path: String) throws -> MediaMap {
        let key = try StateTransitionKey(from: from, to: to)
        guard let playlist = transitions[key] else {
            throw PetContractError.invalidValue("transition playlist was not found")
        }
        var updated = transitions
        updated[key] = try playlist.removing(path: path)
        return try replacingTransitions(updated)
    }

    func changingTransitionPlaybackMode(
        from: PetState,
        to: PetState,
        to mode: MediaPlaybackMode
    ) throws -> MediaMap {
        let key = try StateTransitionKey(from: from, to: to)
        guard let playlist = transitions[key] else {
            throw PetContractError.invalidValue("transition playlist was not found")
        }
        var updated = transitions
        updated[key] = try playlist.changingMode(to: mode)
        return try replacingTransitions(updated)
    }

    func settingFixedTransitionEntry(from: PetState, to: PetState, path: String) throws -> MediaMap {
        let key = try StateTransitionKey(from: from, to: to)
        guard let playlist = transitions[key] else {
            throw PetContractError.invalidValue("transition playlist was not found")
        }
        var updated = transitions
        updated[key] = try StateMediaPlaylist(
            mode: playlist.mode,
            advanceOn: .stateEntry,
            fixedPath: path,
            entries: playlist.entries
        )
        return try replacingTransitions(updated)
    }

    func movingTransitionEntry(
        from: PetState,
        to: PetState,
        path: String,
        to destinationIndex: Int
    ) throws -> MediaMap {
        let key = try StateTransitionKey(from: from, to: to)
        guard let playlist = transitions[key] else {
            throw PetContractError.invalidValue("transition playlist was not found")
        }
        var updated = transitions
        updated[key] = try playlist.movingEntry(path: path, to: destinationIndex)
        return try replacingTransitions(updated)
    }

    func removingTransition(from: PetState, to: PetState) throws -> MediaMap {
        let key = try StateTransitionKey(from: from, to: to)
        var updated = transitions
        updated[key] = nil
        return try replacingTransitions(updated)
    }

    func settingInStateTransition(for state: PetState, entry: MediaEntry) throws -> MediaMap {
        var updated = inStateTransitions
        updated[state] = entry
        return try replacingInStateTransitions(updated)
    }

    func removingInStateTransition(for state: PetState) throws -> MediaMap {
        var updated = inStateTransitions
        updated[state] = nil
        return try replacingInStateTransitions(updated)
    }

    private func replacingStates(_ states: [PetState: StateMediaPlaylist]) throws -> MediaMap {
        try MediaMap(
            version: version,
            defaultFormat: defaultFormat,
            window: window,
            states: states,
            transitions: transitions,
            inStateTransitions: inStateTransitions
        )
    }

    private func replacingTransitions(_ transitions: [StateTransitionKey: StateMediaPlaylist]) throws -> MediaMap {
        try MediaMap(
            version: version,
            defaultFormat: defaultFormat,
            window: window,
            states: states,
            transitions: transitions,
            inStateTransitions: inStateTransitions
        )
    }

    private func replacingInStateTransitions(_ routes: [PetState: MediaEntry]) throws -> MediaMap {
        try MediaMap(
            version: version,
            defaultFormat: defaultFormat,
            window: window,
            states: states,
            transitions: transitions,
            inStateTransitions: routes
        )
    }
}

public struct TransitionSelectionRequest: Equatable, Sendable {
    public let route: StateTransitionKey
    public private(set) var triedPaths: Set<String>
    public private(set) var selectedPath: String?
    public private(set) var isCommitted: Bool
    private let candidates: [MediaEntry]

    fileprivate init(route: StateTransitionKey, candidates: [MediaEntry]) {
        self.route = route
        self.candidates = candidates
        triedPaths = []
        selectedPath = nil
        isCommitted = false
    }

    public var remainingCount: Int {
        candidates.lazy.filter { !triedPaths.contains(StateMediaPlaylist.normalizedPath($0.path)) }.count
    }

    /// Returns each candidate at most once for this request. Call only after a
    /// candidate fails attestation/readiness; successful selection is committed separately.
    public mutating func next() -> MediaEntry? {
        guard let candidate = candidates.first(where: {
            !triedPaths.contains(StateMediaPlaylist.normalizedPath($0.path))
        }) else { return nil }
        triedPaths.insert(StateMediaPlaylist.normalizedPath(candidate.path))
        selectedPath = candidate.path
        return candidate
    }

    /// Commits at most once, so retries and stale callbacks cannot advance the
    /// persisted route cursor again.
    @discardableResult
    public mutating func commit(to cursor: inout TransitionSelectionCursor) -> Bool {
        guard !isCommitted, let selectedPath else { return false }
        cursor.commit(path: selectedPath, for: route)
        isCommitted = true
        return true
    }
}

public struct TransitionSelectionCursor: Equatable, Sendable {
    public private(set) var selectedPaths: [StateTransitionKey: String]

    public init(selectedPaths: [StateTransitionKey: String] = [:]) {
        self.selectedPaths = selectedPaths
    }

    public func selectedPath(for route: StateTransitionKey) -> String? {
        selectedPaths[route]
    }

    public func selectedPath(from: PetState, to: PetState) -> String? {
        guard let route = try? StateTransitionKey(from: from, to: to) else { return nil }
        return selectedPath(for: route)
    }

    public func request(
        from: PetState,
        to: PetState,
        playlist: StateMediaPlaylist,
        isEligible: (MediaEntry) -> Bool = { _ in true },
        randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) throws -> TransitionSelectionRequest {
        let route = try StateTransitionKey(from: from, to: to)
        let eligible = playlist.entries.filter(isEligible)
        guard !eligible.isEmpty else { return TransitionSelectionRequest(route: route, candidates: []) }
        let previousPath = selectedPaths[route]
        let ordered: [MediaEntry]
        switch playlist.mode {
        case .fixed:
            let fixed = eligible.first(where: {
                StateMediaPlaylist.pathsEqual($0.path, playlist.fixedPath)
            })
            ordered = (fixed.map { [$0] } ?? []) + eligible.filter {
                !StateMediaPlaylist.pathsEqual($0.path, playlist.fixedPath)
            }
        case .sequential:
            let startIndex: Int
            if let previousPath,
               let index = playlist.entries.firstIndex(where: {
                   StateMediaPlaylist.pathsEqual($0.path, previousPath)
               }) {
                startIndex = (index + 1) % playlist.entries.count
            } else {
                startIndex = 0
            }
            ordered = (0..<playlist.entries.count).compactMap { offset in
                let entry = playlist.entries[(startIndex + offset) % playlist.entries.count]
                return isEligible(entry) ? entry : nil
            }
        case .random:
            var pool = eligible
            var deferredImmediateRepeat = false
            if pool.count >= 2, let previousPath,
               let index = pool.firstIndex(where: { StateMediaPlaylist.pathsEqual($0.path, previousPath) }) {
                let repeated = pool.remove(at: index)
                pool.append(repeated)
                deferredImmediateRepeat = true
            }
            var randomized: [MediaEntry] = []
            while !pool.isEmpty {
                let selectableCount = (randomized.isEmpty && pool.count > 1 && deferredImmediateRepeat)
                    ? pool.count - 1
                    : pool.count
                let rawIndex = randomIndex(selectableCount)
                let index = ((rawIndex % selectableCount) + selectableCount) % selectableCount
                randomized.append(pool.remove(at: index))
            }
            ordered = randomized
        }
        return TransitionSelectionRequest(route: route, candidates: ordered)
    }

    public mutating func reset(route: StateTransitionKey? = nil) {
        if let route { selectedPaths[route] = nil } else { selectedPaths.removeAll() }
    }

    fileprivate mutating func commit(path: String, for route: StateTransitionKey) {
        selectedPaths[route] = path
    }
}

public struct MediaSelectionCursor: Equatable, Sendable {
    public private(set) var selectedPaths: [PetState: String]

    public init(selectedPaths: [PetState: String] = [:]) {
        self.selectedPaths = selectedPaths
    }

    public func selectedPath(for state: PetState) -> String? {
        selectedPaths[state]
    }

    public static func canSelectNextExplicitly(
        currentPath: String?,
        from playlist: StateMediaPlaylist,
        isEligible: (MediaEntry) -> Bool = { _ in true }
    ) -> Bool {
        let baselinePath = currentPath ?? playlist.fixedPath
        return playlist.entries.contains { entry in
            isEligible(entry) && !StateMediaPlaylist.pathsEqual(entry.path, baselinePath)
        }
    }

    public mutating func select(
        for state: PetState,
        from playlist: StateMediaPlaylist,
        advance: Bool = true,
        isEligible: (MediaEntry) -> Bool = { _ in true },
        randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> MediaEntry? {
        if playlist.mode == .fixed {
            let entry = playlist.fixedEntry
            selectedPaths[state] = entry.path
            return entry
        }

        let eligible = playlist.entries.filter(isEligible)
        guard !eligible.isEmpty else {
            selectedPaths[state] = nil
            return nil
        }

        let previousPath = selectedPaths[state]
        if !advance,
           let previousPath,
           let active = eligible.first(where: { StateMediaPlaylist.pathsEqual($0.path, previousPath) }) {
            return active
        }

        let selection: MediaEntry
        switch playlist.mode {
        case .fixed:
            selection = playlist.fixedEntry
        case .random:
            let candidates: [MediaEntry]
            if eligible.count >= 2, let previousPath {
                candidates = eligible.filter { !StateMediaPlaylist.pathsEqual($0.path, previousPath) }
            } else {
                candidates = eligible
            }
            let rawIndex = randomIndex(candidates.count)
            let index = ((rawIndex % candidates.count) + candidates.count) % candidates.count
            selection = candidates[index]
        case .sequential:
            if let previousPath,
               let previousIndex = playlist.entries.firstIndex(where: {
                   StateMediaPlaylist.pathsEqual($0.path, previousPath)
               }) {
                selection = Self.nextEligible(after: previousIndex, entries: playlist.entries, isEligible: isEligible) ?? eligible[0]
            } else {
                selection = eligible[0]
            }
        }

        selectedPaths[state] = selection.path
        return selection
    }

    /// Selects another eligible entry after an explicit user request. Unlike
    /// automatic state-entry/clip-end selection, this deliberately permits a
    /// temporary runtime advance from a Fixed playlist without changing its
    /// persisted `fixed_path`.
    public mutating func selectNextExplicitly(
        for state: PetState,
        from playlist: StateMediaPlaylist,
        isEligible: (MediaEntry) -> Bool = { _ in true },
        randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> MediaEntry? {
        let eligible = playlist.entries.filter(isEligible)
        guard !eligible.isEmpty else {
            selectedPaths[state] = nil
            return nil
        }

        let previousPath = selectedPaths[state] ?? playlist.fixedPath
        let selection: MediaEntry
        if playlist.mode == .random {
            let candidates = eligible.count >= 2
                ? eligible.filter { !StateMediaPlaylist.pathsEqual($0.path, previousPath) }
                : eligible
            let rawIndex = randomIndex(candidates.count)
            let index = ((rawIndex % candidates.count) + candidates.count) % candidates.count
            selection = candidates[index]
        } else if let previousIndex = playlist.entries.firstIndex(where: {
            StateMediaPlaylist.pathsEqual($0.path, previousPath)
        }) {
            selection = Self.nextEligible(
                after: previousIndex,
                entries: playlist.entries,
                isEligible: isEligible
            ) ?? eligible[0]
        } else {
            selection = eligible[0]
        }

        selectedPaths[state] = selection.path
        return selection
    }

    public mutating func reset(state: PetState? = nil) {
        if let state {
            selectedPaths[state] = nil
        } else {
            selectedPaths.removeAll()
        }
    }

    private static func nextEligible(
        after index: Int,
        entries: [MediaEntry],
        isEligible: (MediaEntry) -> Bool
    ) -> MediaEntry? {
        for offset in 1...entries.count {
            let candidate = entries[(index + offset) % entries.count]
            if isEligible(candidate) { return candidate }
        }
        return nil
    }
}

public struct OneShotPlaybackToken: Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public struct OneShotPlayback: Equatable, Sendable {
    public let token: OneShotPlaybackToken
    public let state: PetState
    public let path: String

    public init(token: OneShotPlaybackToken, state: PetState, path: String) throws {
        guard !path.isEmpty, !path.contains("\0") else { throw PetContractError.invalidMediaPath }
        self.token = token
        self.state = state
        self.path = path
    }
}

public enum OneShotHeartbeatOutcome: Equatable, Sendable {
    case inactive
    case continuing(OneShotPlayback)
    case preempted(OneShotPlayback)
}

public struct OneShotPlaybackArbiter: Equatable, Sendable {
    public private(set) var active: OneShotPlayback?
    private var nextTokenValue: UInt64

    public init() {
        active = nil
        nextTokenValue = 1
    }

    @discardableResult
    public mutating func start(state: PetState, path: String) throws -> OneShotPlayback {
        let playback = try OneShotPlayback(
            token: OneShotPlaybackToken(rawValue: nextTokenValue),
            state: state,
            path: path
        )
        nextTokenValue &+= 1
        active = playback
        return playback
    }

    public mutating func heartbeat(state: PetState) -> OneShotHeartbeatOutcome {
        guard let active else { return .inactive }
        guard active.state == state else {
            self.active = nil
            return .preempted(active)
        }
        return .continuing(active)
    }

    @discardableResult
    public mutating func complete(token: OneShotPlaybackToken) -> OneShotPlayback? {
        finish(token: token)
    }

    @discardableResult
    public mutating func cancel(token: OneShotPlaybackToken) -> OneShotPlayback? {
        finish(token: token)
    }

    private mutating func finish(token: OneShotPlaybackToken) -> OneShotPlayback? {
        guard let active, active.token == token else { return nil }
        self.active = nil
        return active
    }
}
