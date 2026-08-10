import Foundation

/// The four lifecycle states shared with the existing macOS hook/daemon.
public enum PetState: String, Codable, CaseIterable, Sendable {
    case idle
    case running
    case waiting
    case review
}

public enum PetContractError: Error, Equatable, LocalizedError {
    case unsupportedVersion(Int)
    case invalidState(String)
    case invalidNumber(String)
    case invalidValue(String)
    case invalidMediaPath

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            return "Unsupported Statelet contract version: \(version)"
        case let .invalidState(state):
            return "Invalid Statelet state: \(state)"
        case let .invalidNumber(name):
            return "Invalid number for \(name)"
        case let .invalidValue(message):
            return message
        case .invalidMediaPath:
            return "Media path must be a non-empty relative or absolute path"
        }
    }
}

public enum StateContract {
    public static let version = 1
    public static let priority: [PetState: Int] = [
        .idle: 0,
        .running: 1,
        .review: 2,
        .waiting: 3,
    ]

    /// Validates the state vocabulary without deriving validity from priority.
    /// This keeps the decoder compatible with producers that omit or evolve the
    /// advisory `priority` field while preserving the four-state contract.
    public static func validate(_ state: PetState) throws {
        guard PetState.allCases.contains(state) else {
            throw PetContractError.invalidState(state.rawValue)
        }
    }

    public static func validatePriority(_ priority: Int) throws {
        guard (0...3).contains(priority) else {
            throw PetContractError.invalidValue("priority must be between 0 and 3")
        }
    }
}

public struct PlaybackRate: Codable, Equatable, Sendable {
    public static let minimum = 0.25
    public static let maximum = 4.0

    public let value: Double

    public init(_ value: Double) throws {
        guard value.isFinite, value >= Self.minimum, value <= Self.maximum else {
            throw PetContractError.invalidNumber("playback_rate")
        }
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(Double.self)
        try self.init(value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct CurrentState: Codable, Equatable, Sendable {
    public let version: Int
    public let schemaVersion: Int
    public let state: PetState
    public let source: String?
    public let priority: Int?
    public let activeSessions: Int
    /// Compatibility timestamp retained for older writers that only emit
    /// `updated_at`. New writers should also provide the two explicit fields.
    public let updatedAt: Double
    /// The lifecycle source clock is absent when no active session exists.
    public let sourceUpdatedAt: Double?
    public let emittedAt: Double
    public let reason: String?
    public let forced: Bool

    public init(
        version: Int = StateContract.version,
        schemaVersion: Int = StateContract.version,
        state: PetState,
        source: String? = nil,
        priority: Int? = nil,
        activeSessions: Int = 0,
        updatedAt: Double? = nil,
        sourceUpdatedAt: Double? = nil,
        emittedAt: Double? = nil,
        reason: String? = nil,
        forced: Bool = false
    ) throws {
        guard version == StateContract.version else {
            throw PetContractError.unsupportedVersion(version)
        }
        guard schemaVersion == StateContract.version else {
            throw PetContractError.unsupportedVersion(schemaVersion)
        }
        try StateContract.validate(state)
        if let priority {
            try StateContract.validatePriority(priority)
        }
        guard activeSessions >= 0 else {
            throw PetContractError.invalidValue("active_sessions must not be negative")
        }
        guard let publicationTimestamp = emittedAt ?? updatedAt else {
            throw PetContractError.invalidValue("emitted_at or updated_at is required")
        }
        let compatibilityTimestamp = updatedAt ?? publicationTimestamp
        let emittedTimestamp = emittedAt ?? compatibilityTimestamp
        guard compatibilityTimestamp.isFinite else {
            throw PetContractError.invalidNumber("updated_at")
        }
        if let sourceUpdatedAt, !sourceUpdatedAt.isFinite {
            throw PetContractError.invalidNumber("source_updated_at")
        }
        guard emittedTimestamp.isFinite else {
            throw PetContractError.invalidNumber("emitted_at")
        }
        self.version = version
        self.schemaVersion = schemaVersion
        self.state = state
        self.source = source
        self.priority = priority
        self.activeSessions = activeSessions
        self.updatedAt = compatibilityTimestamp
        self.sourceUpdatedAt = sourceUpdatedAt
        self.emittedAt = emittedTimestamp
        self.reason = reason
        self.forced = forced
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case schemaVersion = "schema_version"
        case state
        case source
        case priority
        case activeSessions = "active_sessions"
        case updatedAt = "updated_at"
        case sourceUpdatedAt = "source_updated_at"
        case emittedAt = "emitted_at"
        case reason
        case forced
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version)
            ?? container.decode(Int.self, forKey: .schemaVersion)
        let schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? version
        let rawState = try container.decode(String.self, forKey: .state)
        guard let state = PetState(rawValue: rawState) else {
            throw PetContractError.invalidState(rawState)
        }
        try self.init(
            version: version,
            schemaVersion: schemaVersion,
            state: state,
            source: try container.decodeIfPresent(String.self, forKey: .source),
            priority: try container.decodeIfPresent(Int.self, forKey: .priority),
            activeSessions: try container.decodeIfPresent(Int.self, forKey: .activeSessions) ?? 0,
            updatedAt: try container.decodeIfPresent(Double.self, forKey: .updatedAt),
            sourceUpdatedAt: try container.decodeIfPresent(Double.self, forKey: .sourceUpdatedAt),
            emittedAt: try container.decodeIfPresent(Double.self, forKey: .emittedAt),
            reason: try container.decodeIfPresent(String.self, forKey: .reason),
            forced: try container.decodeIfPresent(Bool.self, forKey: .forced) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(state.rawValue, forKey: .state)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(priority, forKey: .priority)
        try container.encode(activeSessions, forKey: .activeSessions)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(sourceUpdatedAt, forKey: .sourceUpdatedAt)
        try container.encode(emittedAt, forKey: .emittedAt)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encode(forced, forKey: .forced)
    }
}

/// The health of the state publisher's most recent publication timestamp.
public enum StatePublicationFreshness: String, Equatable, Sendable {
    case fresh
    case stale
    case futureSkew = "future_skew"
}

/// Validates the liveness clock published in `CurrentState.emittedAt`.
///
/// The production default allows 150 seconds of age: two normal 60-second
/// publisher heartbeat intervals plus 30 seconds for scheduling and wake-up
/// jitter. Publications more than 60 seconds in the future are rejected using
/// the same future-skew tolerance as the lifecycle session producer.
public struct StateFreshnessPolicy: Equatable, Sendable {
    public static let defaultMaximumAge: TimeInterval = 150
    public static let defaultMaximumFutureSkew: TimeInterval = 60
    public static let production = try! StateFreshnessPolicy()

    public let maximumAge: TimeInterval
    public let maximumFutureSkew: TimeInterval

    public init(
        maximumAge: TimeInterval = Self.defaultMaximumAge,
        maximumFutureSkew: TimeInterval = Self.defaultMaximumFutureSkew
    ) throws {
        guard maximumAge.isFinite, maximumAge > 0 else {
            throw PetContractError.invalidNumber("state maximum age")
        }
        guard maximumFutureSkew.isFinite, maximumFutureSkew >= 0 else {
            throw PetContractError.invalidNumber("state maximum future skew")
        }
        self.maximumAge = maximumAge
        self.maximumFutureSkew = maximumFutureSkew
    }

    public func freshness(emittedAt: TimeInterval, now: TimeInterval) -> StatePublicationFreshness {
        let age = now - emittedAt
        if age < -maximumFutureSkew {
            return .futureSkew
        }
        if age > maximumAge {
            return .stale
        }
        return .fresh
    }

    public func freshness(of state: CurrentState, now: TimeInterval) -> StatePublicationFreshness {
        freshness(emittedAt: state.emittedAt, now: now)
    }
}

/// Decides whether an incoming lifecycle state requires rebuilding playback.
/// Heartbeat replacements with an unchanged state are intentionally ignored.
public enum StatePresentationDecision: String, Equatable, Sendable {
    case initial
    case stateChanged = "state_changed"
    case forcedRefresh = "forced_refresh"
    case unchanged

    public var shouldRefresh: Bool { self != .unchanged }

    public static func decide(
        lastPresentedState: PetState?,
        pendingState: PetState? = nil,
        incomingState: PetState,
        forceRefresh: Bool = false
    ) -> StatePresentationDecision {
        if forceRefresh { return .forcedRefresh }
        if pendingState == incomingState { return .unchanged }
        guard let lastPresentedState else { return .initial }
        return lastPresentedState == incomingState ? .unchanged : .stateChanged
    }
}

public enum PresentationReadinessSignal: Equatable, Sendable {
    case itemReady
    case displayReady
    case failure
}

public enum PresentationReadinessState: Equatable, Sendable {
    case preparing
    case ready
    case failed
}

public enum PresentationReadinessOutcome: Equatable, Sendable {
    case noChange
    case becameReady
    case becameFailed
}

/// Tracks the two independent gates required before playback is considered
/// presented. Failure remains actionable after readiness so a later decoder or
/// playback error can revoke presentation success and permit a retry.
public struct PresentationReadinessTracker: Equatable, Sendable {
    public private(set) var state: PresentationReadinessState = .preparing
    public private(set) var itemIsReady = false
    public private(set) var displayIsReady = false

    public init() {}

    @discardableResult
    public mutating func receive(_ signal: PresentationReadinessSignal) -> PresentationReadinessOutcome {
        switch signal {
        case .failure:
            guard state != .failed else { return .noChange }
            state = .failed
            return .becameFailed
        case .itemReady:
            guard state == .preparing, !itemIsReady else { return .noChange }
            itemIsReady = true
        case .displayReady:
            guard state == .preparing, !displayIsReady else { return .noChange }
            displayIsReady = true
        }
        guard itemIsReady, displayIsReady else { return .noChange }
        state = .ready
        return .becameReady
    }
}

public struct MediaEntry: Codable, Equatable, Sendable {
    public let path: String
    public let posterPath: String?
    public let loop: Bool
    public let playbackRate: PlaybackRate

    public init(path: String, posterPath: String? = nil, loop: Bool = true, playbackRate: Double = 1.0) throws {
        guard !path.isEmpty, !path.contains("\0") else {
            throw PetContractError.invalidMediaPath
        }
        if let posterPath, posterPath.isEmpty || posterPath.contains("\0") {
            throw PetContractError.invalidMediaPath
        }
        self.path = path
        self.posterPath = posterPath
        self.loop = loop
        self.playbackRate = try PlaybackRate(playbackRate)
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case posterPath = "poster_path"
        case loop
        case playbackRate = "playback_rate"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedRate = try container.decodeIfPresent(PlaybackRate.self, forKey: .playbackRate)
        try self.init(
            path: container.decode(String.self, forKey: .path),
            posterPath: container.decodeIfPresent(String.self, forKey: .posterPath),
            loop: container.decodeIfPresent(Bool.self, forKey: .loop) ?? true,
            playbackRate: decodedRate?.value ?? 1.0
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(posterPath, forKey: .posterPath)
        try container.encode(loop, forKey: .loop)
        try container.encode(playbackRate, forKey: .playbackRate)
    }
}

public struct WindowConfiguration: Codable, Equatable, Sendable {
    public let width: Double
    public let height: Double
    public let alwaysOnTop: Bool
    public let clickThrough: Bool
    public let fullScreenAuxiliary: Bool
    public let appearance: PetAppearanceConfiguration

    public init(
        width: Double = 320,
        height: Double = 480,
        alwaysOnTop: Bool = true,
        clickThrough: Bool = false,
        fullScreenAuxiliary: Bool = false,
        appearance: PetAppearanceConfiguration = try! PetAppearanceConfiguration()
    ) throws {
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 4096, height <= 4096 else {
            throw PetContractError.invalidValue("window dimensions must be between 0 and 4096")
        }
        self.width = width
        self.height = height
        self.alwaysOnTop = alwaysOnTop
        self.clickThrough = clickThrough
        self.fullScreenAuxiliary = fullScreenAuxiliary
        self.appearance = appearance
    }

    private enum CodingKeys: String, CodingKey {
        case width
        case height
        case alwaysOnTop = "always_on_top"
        case clickThrough = "click_through"
        case fullScreenAuxiliary = "full_screen_auxiliary"
        case appearance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            width: container.decodeIfPresent(Double.self, forKey: .width) ?? 320,
            height: container.decodeIfPresent(Double.self, forKey: .height) ?? 480,
            alwaysOnTop: container.decodeIfPresent(Bool.self, forKey: .alwaysOnTop) ?? true,
            clickThrough: container.decodeIfPresent(Bool.self, forKey: .clickThrough) ?? false,
            fullScreenAuxiliary: container.decodeIfPresent(Bool.self, forKey: .fullScreenAuxiliary) ?? false,
            appearance: try container.decodeIfPresent(PetAppearanceConfiguration.self, forKey: .appearance) ?? PetAppearanceConfiguration()
        )
    }
}

public struct MediaMap: Codable, Equatable, Sendable {
    public let version: Int
    public let defaultFormat: String
    public let window: WindowConfiguration
    public let states: [PetState: StateMediaPlaylist]

    public init(
        version: Int = StateContract.version,
        defaultFormat: String = "mov",
        window: WindowConfiguration = try! WindowConfiguration(),
        states: [PetState: StateMediaPlaylist] = [:]
    ) throws {
        guard version == StateContract.version else {
            throw PetContractError.unsupportedVersion(version)
        }
        guard !defaultFormat.isEmpty, !defaultFormat.contains("\0") else {
            throw PetContractError.invalidValue("default_format must not be empty")
        }
        for playlist in states.values {
            for entry in playlist.entries {
                _ = try PlaybackRate(entry.playbackRate.value)
            }
        }
        self.version = version
        self.defaultFormat = defaultFormat
        self.window = window
        self.states = states
    }

    /// Source-compatible initializer for callers that still supply one entry
    /// per state. Each entry becomes a fixed singleton playlist.
    public init(
        version: Int = StateContract.version,
        defaultFormat: String = "mov",
        window: WindowConfiguration = try! WindowConfiguration(),
        states: [PetState: MediaEntry]
    ) throws {
        let playlists = try Dictionary(uniqueKeysWithValues: states.map { state, entry in
            (state, try StateMediaPlaylist(entries: [entry]))
        })
        try self.init(
            version: version,
            defaultFormat: defaultFormat,
            window: window,
            states: playlists
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case defaultFormat = "default_format"
        case window
        case states
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawStates = try container.decodeIfPresent([String: StateMediaPlaylist].self, forKey: .states) ?? [:]
        var decodedStates: [PetState: StateMediaPlaylist] = [:]
        for (rawState, playlist) in rawStates {
            guard let state = PetState(rawValue: rawState) else {
                throw PetContractError.invalidState(rawState)
            }
            decodedStates[state] = playlist
        }
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            defaultFormat: container.decodeIfPresent(String.self, forKey: .defaultFormat) ?? "mov",
            window: container.decodeIfPresent(WindowConfiguration.self, forKey: .window) ?? (try WindowConfiguration()),
            states: decodedStates
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(defaultFormat, forKey: .defaultFormat)
        try container.encode(window, forKey: .window)
        try container.encode(Dictionary(uniqueKeysWithValues: states.map { ($0.key.rawValue, $0.value) }), forKey: .states)
    }

    public func entry(for state: PetState) -> MediaEntry? {
        playlist(for: state)?.fixedEntry
    }

    public func playlist(for state: PetState) -> StateMediaPlaylist? {
        states[state]
    }

    public func entries(for state: PetState) -> [MediaEntry] {
        playlist(for: state)?.entries ?? []
    }

    public func resolvedURL(for state: PetState, relativeTo mapURL: URL) -> URL? {
        guard let entry = entry(for: state) else { return nil }
        return resolvedURL(for: entry, relativeTo: mapURL)
    }

    public func resolvedURL(for entry: MediaEntry, relativeTo mapURL: URL) -> URL {
        if entry.path.hasPrefix("/") {
            return URL(fileURLWithPath: entry.path).standardizedFileURL
        }
        return mapURL.deletingLastPathComponent().appendingPathComponent(entry.path).standardizedFileURL
    }

    public func resolvedPosterURL(for state: PetState, relativeTo mapURL: URL) -> URL? {
        guard let entry = entry(for: state) else { return nil }
        return resolvedPosterURL(for: entry, relativeTo: mapURL)
    }

    public func resolvedPosterURL(for entry: MediaEntry, relativeTo mapURL: URL) -> URL? {
        guard let path = entry.posterPath else { return nil }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return mapURL.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
    }
}

/// Classifies media-map changes so window-only edits can be applied without
/// rebuilding the active AVPlayer queue.
public enum MediaMapChangeImpact: String, Equatable, Sendable {
    case unchanged
    case windowOnly = "window_only"
    case playback

    public var didChange: Bool { self != .unchanged }
    public var shouldRefreshPlayback: Bool { self == .playback }

    public static func decide(previous: MediaMap, incoming: MediaMap) -> MediaMapChangeImpact {
        guard previous != incoming else { return .unchanged }
        if previous.version != incoming.version
            || previous.defaultFormat != incoming.defaultFormat
            || previous.states != incoming.states {
            return .playback
        }
        return .windowOnly
    }
}

public extension JSONDecoder {
    static var codexPet: JSONDecoder { JSONDecoder() }
}
