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

public enum CurrentStateHookEvent: String, Codable, CaseIterable, Sendable {
    /// Privacy-safe fallback for an event name a newer producer understands
    /// but this contract version does not yet recognize.
    case unknown
    case permissionRequest = "PermissionRequest"
    case postCompact = "PostCompact"
    case postToolUse = "PostToolUse"
    case preCompact = "PreCompact"
    case preToolUse = "PreToolUse"
    case sessionEnd = "SessionEnd"
    case sessionStart = "SessionStart"
    case stop = "Stop"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case userPromptSubmit = "UserPromptSubmit"
}

public enum SessionActivityCategory: String, Codable, Equatable, Sendable {
    case codex
    case approval
    case tool
    case review
    case subagent
    case activity

    public static func inferred(from event: CurrentStateHookEvent) -> Self {
        switch event {
        case .permissionRequest: return .approval
        case .preToolUse, .postToolUse: return .tool
        case .preCompact, .postCompact: return .review
        case .subagentStart, .subagentStop: return .subagent
        case .sessionStart, .sessionEnd, .userPromptSubmit, .stop: return .codex
        case .unknown: return .activity
        }
    }

    public var displayName: String {
        rawValue.capitalized
    }
}

public struct CurrentStateRejectionDiagnostics: Codable, Equatable, Sendable {
    public static let maximumCount = 1_000_000
    public static let maximumReasons = 8
    public static let allowedReasons: Set<String> = [
        "expired",
        "future_event",
        "invalid_record",
        "invalid_timestamp",
        "quiescent_expired",
        "stale_event",
    ]

    public let count: Int
    public let reasons: [String: Int]

    private enum CodingKeys: String, CodingKey {
        case count
        case reasons
    }

    public init(count: Int = 0, reasons: [String: Int] = [:]) throws {
        guard (0...Self.maximumCount).contains(count) else {
            throw PetContractError.invalidValue("rejection_diagnostics.count is out of range")
        }
        guard reasons.count <= Self.maximumReasons else {
            throw PetContractError.invalidValue("rejection_diagnostics contains too many reasons")
        }
        for (reason, value) in reasons {
            guard Self.allowedReasons.contains(reason), (1...Self.maximumCount).contains(value) else {
                throw PetContractError.invalidValue("rejection_diagnostics contains an invalid reason")
            }
        }
        self.count = count
        self.reasons = reasons
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            count: try container.decodeIfPresent(Int.self, forKey: .count) ?? 0,
            reasons: try container.decodeIfPresent([String: Int].self, forKey: .reasons) ?? [:]
        )
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
    public let publicationRevision: Int?
    public let recovery: Bool
    public let latestEvent: String?
    public let latestEventAt: Double?
    public let rejectionDiagnostics: CurrentStateRejectionDiagnostics

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
        forced: Bool = false,
        publicationRevision: Int? = nil,
        recovery: Bool = false,
        latestEvent: String? = nil,
        latestEventAt: Double? = nil,
        rejectionDiagnostics: CurrentStateRejectionDiagnostics = try! CurrentStateRejectionDiagnostics()
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
        if let publicationRevision, publicationRevision < 1 {
            throw PetContractError.invalidValue("publication_revision must be positive")
        }
        if let latestEventAt, !latestEventAt.isFinite {
            throw PetContractError.invalidNumber("latest_event_at")
        }
        if let latestEvent,
           !CurrentStateHookEvent.allCases.map(\.rawValue).contains(latestEvent) {
            throw PetContractError.invalidValue("latest_event is not a supported hook event")
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
        self.publicationRevision = publicationRevision
        self.recovery = recovery
        self.latestEvent = latestEvent
        self.latestEventAt = latestEventAt
        self.rejectionDiagnostics = rejectionDiagnostics
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
        case publicationRevision = "publication_revision"
        case recovery
        case latestEvent = "latest_event"
        case latestEventAt = "latest_event_at"
        case rejectionDiagnostics = "rejection_diagnostics"
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
            forced: try container.decodeIfPresent(Bool.self, forKey: .forced) ?? false,
            publicationRevision: try container.decodeIfPresent(Int.self, forKey: .publicationRevision),
            recovery: try container.decodeIfPresent(Bool.self, forKey: .recovery) ?? false,
            latestEvent: try container.decodeIfPresent(String.self, forKey: .latestEvent),
            latestEventAt: try container.decodeIfPresent(Double.self, forKey: .latestEventAt),
            rejectionDiagnostics: try container.decodeIfPresent(
                CurrentStateRejectionDiagnostics.self,
                forKey: .rejectionDiagnostics
            ) ?? CurrentStateRejectionDiagnostics()
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
        try container.encodeIfPresent(publicationRevision, forKey: .publicationRevision)
        try container.encode(recovery, forKey: .recovery)
        try container.encodeIfPresent(latestEvent, forKey: .latestEvent)
        try container.encodeIfPresent(latestEventAt, forKey: .latestEventAt)
        try container.encode(rejectionDiagnostics, forKey: .rejectionDiagnostics)
    }
}

/// A bounded, privacy-safe view of the individual Codex sessions used by the
/// optional activity rail. The identifier is the 24-hex truncated hash already
/// used for owner-only hook record filenames; prompts and transcript metadata
/// never cross this contract boundary.
public struct SessionActivityItem: Codable, Equatable, Sendable {
    public static let maximumIdentifierLength = 24

    public let id: String
    public let state: PetState
    public let event: CurrentStateHookEvent
    public let eventAt: Double
    public let startedAt: Double
    public let completedAt: Double?
    public let category: SessionActivityCategory
    public let terminal: Bool

    public init(
        id: String,
        state: PetState,
        event: CurrentStateHookEvent,
        eventAt: Double,
        terminal: Bool,
        startedAt: Double? = nil,
        completedAt: Double? = nil,
        category: SessionActivityCategory? = nil
    ) throws {
        guard id.count == Self.maximumIdentifierLength,
              id.unicodeScalars.allSatisfy(
                  String("0123456789abcdef").unicodeScalars.contains
              ) else {
            throw PetContractError.invalidValue("session activity identifier is invalid")
        }
        guard eventAt.isFinite else {
            throw PetContractError.invalidNumber("session activity event_at")
        }
        let resolvedStartedAt = startedAt ?? eventAt
        guard resolvedStartedAt.isFinite else {
            throw PetContractError.invalidNumber("session activity started_at")
        }
        let resolvedCompletedAt = completedAt ?? (terminal ? eventAt : nil)
        if let resolvedCompletedAt {
            guard resolvedCompletedAt.isFinite else {
                throw PetContractError.invalidNumber("session activity completed_at")
            }
            guard terminal else {
                throw PetContractError.invalidValue("active session activity cannot have completed_at")
            }
        } else if terminal {
            throw PetContractError.invalidValue("terminal session activity is missing completed_at")
        }
        let terminalEvent = event == .sessionEnd || event == .stop
        guard terminal == terminalEvent else {
            throw PetContractError.invalidValue("session activity terminal event is inconsistent")
        }
        guard terminal || state != .idle else {
            throw PetContractError.invalidValue("active session activity cannot be idle")
        }
        guard !terminal || state == .idle else {
            throw PetContractError.invalidValue("terminal session activity must be idle")
        }
        guard resolvedStartedAt <= eventAt else {
            throw PetContractError.invalidValue("session activity started_at is after event_at")
        }
        if let resolvedCompletedAt, resolvedCompletedAt < eventAt {
            throw PetContractError.invalidValue("session activity completed_at is before event_at")
        }
        let resolvedCategory = category ?? .inferred(from: event)
        guard resolvedCategory == .inferred(from: event) else {
            throw PetContractError.invalidValue("session activity category is inconsistent")
        }
        self.id = id
        self.state = state
        self.event = event
        self.eventAt = eventAt
        self.startedAt = resolvedStartedAt
        self.completedAt = resolvedCompletedAt
        self.category = resolvedCategory
        self.terminal = terminal
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case state
        case event
        case eventAt = "event_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case category
        case terminal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let event = try container.decode(CurrentStateHookEvent.self, forKey: .event)
        let eventAt = try container.decode(Double.self, forKey: .eventAt)
        let terminal = try container.decode(Bool.self, forKey: .terminal)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            state: container.decode(PetState.self, forKey: .state),
            event: event,
            eventAt: eventAt,
            terminal: terminal,
            startedAt: container.decodeIfPresent(Double.self, forKey: .startedAt) ?? eventAt,
            completedAt: container.decodeIfPresent(Double.self, forKey: .completedAt),
            category: container.decodeIfPresent(SessionActivityCategory.self, forKey: .category)
        )
    }
}

public struct SessionActivitySnapshot: Codable, Equatable, Sendable {
    public static let version = 1
    public static let maximumItemsPerGroup = 64

    public let version: Int
    public let schemaVersion: Int
    public let emittedAt: Double
    public let active: [SessionActivityItem]
    public let completed: [SessionActivityItem]

    public init(
        version: Int = Self.version,
        schemaVersion: Int = Self.version,
        emittedAt: Double,
        active: [SessionActivityItem] = [],
        completed: [SessionActivityItem] = []
    ) throws {
        guard version == Self.version, schemaVersion == Self.version else {
            throw PetContractError.unsupportedVersion(max(version, schemaVersion))
        }
        guard emittedAt.isFinite else {
            throw PetContractError.invalidNumber("session activity emitted_at")
        }
        guard active.count <= Self.maximumItemsPerGroup,
              completed.count <= Self.maximumItemsPerGroup else {
            throw PetContractError.invalidValue("session activity contains too many items")
        }
        guard active.allSatisfy({ !$0.terminal }),
              completed.allSatisfy(\.terminal) else {
            throw PetContractError.invalidValue("session activity item group is invalid")
        }
        let activeIDs = Set(active.map(\.id))
        let completedIDs = Set(completed.map(\.id))
        guard activeIDs.count == active.count,
              completedIDs.count == completed.count,
              activeIDs.isDisjoint(with: completedIDs) else {
            throw PetContractError.invalidValue("session activity contains duplicate items")
        }
        self.version = version
        self.schemaVersion = schemaVersion
        self.emittedAt = emittedAt
        self.active = active
        self.completed = completed
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case schemaVersion = "schema_version"
        case emittedAt = "emitted_at"
        case active
        case completed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decodeIfPresent(Int.self, forKey: .version) ?? Self.version,
            schemaVersion: container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.version,
            emittedAt: container.decode(Double.self, forKey: .emittedAt),
            active: container.decodeIfPresent([SessionActivityItem].self, forKey: .active) ?? [],
            completed: container.decodeIfPresent([SessionActivityItem].self, forKey: .completed) ?? []
        )
    }
}

public enum SessionActivityAcceptanceDecision: String, Equatable, Sendable {
    case acceptInitial = "accept_initial"
    case acceptNewer = "accept_newer"
    case rejectDuplicate = "duplicate"
    case rejectEqualTimestampConflict = "equal_timestamp_conflict"
    case rejectRollback = "rollback"
    case rejectStale = "stale"
    case rejectFutureSkew = "future_skew"

    public var shouldAccept: Bool {
        self == .acceptInitial || self == .acceptNewer
    }
}

/// Applies the lifecycle publisher's freshness budget plus a monotonic
/// emitted-at barrier to the optional activity sidecar.
public enum SessionActivityAcceptancePolicy {
    public static func decide(
        lastAccepted: SessionActivitySnapshot?,
        incoming: SessionActivitySnapshot,
        now: TimeInterval,
        freshnessPolicy: StateFreshnessPolicy = .production
    ) -> SessionActivityAcceptanceDecision {
        switch freshnessPolicy.freshness(emittedAt: incoming.emittedAt, now: now) {
        case .stale:
            return .rejectStale
        case .futureSkew:
            return .rejectFutureSkew
        case .fresh:
            break
        }
        guard let lastAccepted else { return .acceptInitial }
        if incoming.emittedAt > lastAccepted.emittedAt { return .acceptNewer }
        if incoming.emittedAt < lastAccepted.emittedAt { return .rejectRollback }
        return incoming == lastAccepted ? .rejectDuplicate : .rejectEqualTimestampConflict
    }
}

public enum StatePublicationOrderDecision: String, Equatable, Sendable {
    case acceptInitial = "accept_initial"
    case acceptNewerRevision = "accept_newer_revision"
    case acceptNewerLegacyTimestamp = "accept_newer_legacy_timestamp"
    case rejectLowerRevision = "lower_revision"
    case rejectEqualRevisionDuplicate = "equal_revision_duplicate"
    case rejectEqualRevisionConflict = "equal_revision_conflict"
    case rejectRevisionlessRollback = "revisionless_rollback"
    case rejectLegacyTimestampDuplicate = "legacy_timestamp_duplicate"
    case rejectLegacyTimestampRollback = "legacy_timestamp_rollback"

    public var shouldAccept: Bool {
        switch self {
        case .acceptInitial, .acceptNewerRevision, .acceptNewerLegacyTimestamp:
            return true
        default:
            return false
        }
    }

    public var rejectionReason: String? { shouldAccept ? nil : rawValue }
}

public enum StatePublicationOrderPolicy {
    public static func decide(
        lastAccepted: CurrentState?,
        incoming: CurrentState
    ) -> StatePublicationOrderDecision {
        guard let lastAccepted else { return .acceptInitial }
        switch (lastAccepted.publicationRevision, incoming.publicationRevision) {
        case let (.some(previous), .some(next)):
            if next > previous { return .acceptNewerRevision }
            if next < previous { return .rejectLowerRevision }
            return incoming == lastAccepted ? .rejectEqualRevisionDuplicate : .rejectEqualRevisionConflict
        case (.some, .none):
            return .rejectRevisionlessRollback
        case (.none, .some):
            return .acceptNewerRevision
        case (.none, .none):
            if incoming.emittedAt > lastAccepted.emittedAt { return .acceptNewerLegacyTimestamp }
            if incoming.emittedAt < lastAccepted.emittedAt { return .rejectLegacyTimestampRollback }
            return incoming == lastAccepted ? .rejectLegacyTimestampDuplicate : .rejectLegacyTimestampRollback
        }
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
        if pendingState != nil { return .stateChanged }
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

/// A directional lifecycle transition. Equal source and destination states are
/// invalid because same-state publications never trigger transition media.
public struct StateTransitionKey: Hashable, Codable, Sendable {
    public let from: PetState
    public let to: PetState

    public init(from: PetState, to: PetState) throws {
        guard from != to else {
            throw PetContractError.invalidValue("transition states must be distinct")
        }
        self.from = from
        self.to = to
    }

    public var storageKey: String { "\(from.rawValue)_to_\(to.rawValue)" }

    public init(storageKey: String) throws {
        guard let separator = storageKey.range(of: "_to_"),
              storageKey[separator.upperBound...].range(of: "_to_") == nil,
              let from = PetState(rawValue: String(storageKey[..<separator.lowerBound])),
              let to = PetState(rawValue: String(storageKey[separator.upperBound...])) else {
            throw PetContractError.invalidValue("invalid transition key")
        }
        try self.init(from: from, to: to)
    }

    public init(from decoder: Decoder) throws {
        try self.init(storageKey: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageKey)
    }
}

public enum LifecycleTransitionMediaPolicy {
    /// Preserve the existing portable transition contract. Runtime playback
    /// may accelerate an accepted source so the decorative foreground does not
    /// delay the authoritative destination for the source's full duration.
    public static let maximumDuration: TimeInterval = 4.0
    public static let maximumPresentationDuration: TimeInterval = 1.5

    public static func presentationPlaybackRate(
        sourceDuration: TimeInterval,
        requestedRate: Double
    ) -> Double {
        let safeRequestedRate = requestedRate.isFinite && requestedRate > 0
            ? requestedRate
            : 1.0
        guard sourceDuration.isFinite, sourceDuration > 0 else {
            return safeRequestedRate
        }
        return max(
            safeRequestedRate,
            sourceDuration / maximumPresentationDuration
        )
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
    public let transitions: [StateTransitionKey: StateMediaPlaylist]
    public let inStateTransitions: [PetState: MediaEntry]

    public init(
        version: Int = StateContract.version,
        defaultFormat: String = "mov",
        window: WindowConfiguration = try! WindowConfiguration(),
        states: [PetState: StateMediaPlaylist] = [:],
        transitions: [StateTransitionKey: StateMediaPlaylist] = [:],
        inStateTransitions: [PetState: MediaEntry] = [:]
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
        var normalizedTransitions: [StateTransitionKey: StateMediaPlaylist] = [:]
        for (key, playlist) in transitions {
            guard key.from != key.to else {
                throw PetContractError.invalidValue("transition states must be distinct")
            }
            let entries = try playlist.entries.map { entry in
                _ = try PlaybackRate(entry.playbackRate.value)
                return try MediaEntry(
                    path: entry.path,
                    posterPath: entry.posterPath,
                    loop: false,
                    playbackRate: entry.playbackRate.value
                )
            }
            normalizedTransitions[key] = try StateMediaPlaylist(
                mode: playlist.mode,
                advanceOn: .stateEntry,
                fixedPath: playlist.fixedPath,
                entries: entries
            )
        }
        self.version = version
        self.defaultFormat = defaultFormat
        self.window = window
        self.states = states
        self.transitions = normalizedTransitions
        self.inStateTransitions = try Dictionary(uniqueKeysWithValues: inStateTransitions.map { state, entry in
            _ = try PlaybackRate(entry.playbackRate.value)
            return (state, try MediaEntry(
                path: entry.path,
                posterPath: entry.posterPath,
                loop: false,
                playbackRate: entry.playbackRate.value
            ))
        })
    }

    /// Source-compatible initializer for callers that still supply one entry
    /// per state. Each entry becomes a fixed singleton playlist.
    public init(
        version: Int = StateContract.version,
        defaultFormat: String = "mov",
        window: WindowConfiguration = try! WindowConfiguration(),
        states: [PetState: MediaEntry],
        transitions: [StateTransitionKey: MediaEntry] = [:],
        inStateTransitions: [PetState: MediaEntry] = [:]
    ) throws {
        let playlists = try Dictionary(uniqueKeysWithValues: states.map { state, entry in
            (state, try StateMediaPlaylist(entries: [entry]))
        })
        let transitionPlaylists = try Dictionary(uniqueKeysWithValues: transitions.map { key, entry in
            (key, try StateMediaPlaylist(entries: [entry]))
        })
        try self.init(
            version: version,
            defaultFormat: defaultFormat,
            window: window,
            states: playlists,
            transitions: transitionPlaylists,
            inStateTransitions: inStateTransitions
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case defaultFormat = "default_format"
        case window
        case states
        case transitions
        case inStateTransitions = "in_state_transitions"
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
        let rawTransitions = try container.decodeIfPresent([String: StateMediaPlaylist].self, forKey: .transitions) ?? [:]
        var decodedTransitions: [StateTransitionKey: StateMediaPlaylist] = [:]
        for (rawKey, playlist) in rawTransitions {
            let key = try StateTransitionKey(storageKey: rawKey)
            guard decodedTransitions.updateValue(playlist, forKey: key) == nil else {
                throw PetContractError.invalidValue("duplicate transition key")
            }
        }
        let rawInStateTransitions = try container.decodeIfPresent([String: MediaEntry].self, forKey: .inStateTransitions) ?? [:]
        var decodedInStateTransitions: [PetState: MediaEntry] = [:]
        for (rawState, entry) in rawInStateTransitions {
            guard let state = PetState(rawValue: rawState) else { throw PetContractError.invalidState(rawState) }
            decodedInStateTransitions[state] = entry
        }
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            defaultFormat: container.decodeIfPresent(String.self, forKey: .defaultFormat) ?? "mov",
            window: container.decodeIfPresent(WindowConfiguration.self, forKey: .window) ?? (try WindowConfiguration()),
            states: decodedStates,
            transitions: decodedTransitions,
            inStateTransitions: decodedInStateTransitions
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(defaultFormat, forKey: .defaultFormat)
        try container.encode(window, forKey: .window)
        try container.encode(Dictionary(uniqueKeysWithValues: states.map { ($0.key.rawValue, $0.value) }), forKey: .states)
        if !transitions.isEmpty {
            try container.encode(
                Dictionary(uniqueKeysWithValues: transitions.map { ($0.key.storageKey, $0.value) }),
                forKey: .transitions
            )
        }
        if !inStateTransitions.isEmpty {
            try container.encode(
                Dictionary(uniqueKeysWithValues: inStateTransitions.map { ($0.key.rawValue, $0.value) }),
                forKey: .inStateTransitions
            )
        }
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

    public func transition(from: PetState, to: PetState) -> MediaEntry? {
        transitionPlaylist(from: from, to: to)?.fixedEntry
    }

    public func transitionPlaylist(from: PetState, to: PetState) -> StateMediaPlaylist? {
        guard from != to, let key = try? StateTransitionKey(from: from, to: to) else { return nil }
        return transitions[key]
    }

    public func transitionEntries(from: PetState, to: PetState) -> [MediaEntry] {
        transitionPlaylist(from: from, to: to)?.entries ?? []
    }

    public var allTransitionEntries: [MediaEntry] {
        transitions.values.flatMap(\.entries)
    }

    public func inStateTransition(for state: PetState) -> MediaEntry? { inStateTransitions[state] }

    public var allInStateTransitionEntries: [MediaEntry] { Array(inStateTransitions.values) }

    public var allMediaEntries: [MediaEntry] {
        states.values.flatMap(\.entries) + allTransitionEntries + allInStateTransitionEntries
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
            || previous.states != incoming.states
            || previous.transitions != incoming.transitions
            || previous.inStateTransitions != incoming.inStateTransitions {
            return .playback
        }
        return .windowOnly
    }
}

public extension JSONDecoder {
    static var codexPet: JSONDecoder { JSONDecoder() }
}
