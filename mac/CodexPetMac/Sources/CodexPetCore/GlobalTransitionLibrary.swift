import Foundation

public enum TransitionLibraryScope: String, Codable, CaseIterable, Sendable {
    case character
    case global
}

public struct ResolvedTransitionPlaylist: Equatable, Sendable {
    public let scope: TransitionLibraryScope
    public let playlist: StateMediaPlaylist
    public let isUniversalGlobal: Bool

    public init(
        scope: TransitionLibraryScope,
        playlist: StateMediaPlaylist,
        isUniversalGlobal: Bool = false
    ) {
        self.scope = scope
        self.playlist = playlist
        self.isUniversalGlobal = isUniversalGlobal
    }
}

public enum TransitionLibraryResolver {
    /// Character-specific routes take precedence. A missing local route falls
    /// back to the global library; an absent route in both libraries is nil.
    public static func resolve(
        from: PetState,
        to: PetState,
        character: MediaMap,
        global: GlobalTransitionLibrary
    ) -> ResolvedTransitionPlaylist? {
        guard from != to else { return nil }
        if let playlist = character.transitionPlaylist(from: from, to: to) {
            return ResolvedTransitionPlaylist(
                scope: .character,
                playlist: playlist,
                isUniversalGlobal: false
            )
        }
        if let playlist = global.universalPlaylist {
            return ResolvedTransitionPlaylist(
                scope: .global,
                playlist: playlist,
                isUniversalGlobal: true
            )
        }
        guard let playlist = global.legacyTransitionPlaylist(from: from, to: to) else { return nil }
        return ResolvedTransitionPlaylist(
            scope: .global,
            playlist: playlist,
            isUniversalGlobal: false
        )
    }
}

public struct GlobalTransitionLibrary: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    /// The new app-wide fallback. When present, it applies to every distinct
    /// lifecycle transition that has no character-specific route.
    public let universalPlaylist: StateMediaPlaylist?
    /// Route-keyed data retained only for backward-compatible legacy files
    /// whose playlists could not be collapsed without choosing between them.
    public let transitions: [StateTransitionKey: StateMediaPlaylist]

    public var requiresLegacyMigration: Bool {
        universalPlaylist == nil && !transitions.isEmpty
    }

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        universalPlaylist: StateMediaPlaylist? = nil,
        transitions: [StateTransitionKey: StateMediaPlaylist] = [:]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw PetContractError.unsupportedVersion(schemaVersion)
        }
        self.schemaVersion = schemaVersion
        self.universalPlaylist = try Self.normalizedPlaylist(universalPlaylist)
        self.transitions = try Self.normalized(transitions)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case universalPlaylist = "universal_playlist"
        case transitions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let rawTransitions = try container.decodeIfPresent(
            [String: StateMediaPlaylist].self,
            forKey: .transitions
        ) ?? [:]
        var transitions: [StateTransitionKey: StateMediaPlaylist] = [:]
        for (rawKey, playlist) in rawTransitions {
            let key = try StateTransitionKey(storageKey: rawKey)
            guard transitions.updateValue(playlist, forKey: key) == nil else {
                throw PetContractError.invalidValue("duplicate transition key")
            }
        }
        let normalizedTransitions = try Self.normalized(transitions)
        switch schemaVersion {
        case 1:
            let migrated = Self.migrateLegacy(normalizedTransitions)
            try self.init(
                schemaVersion: Self.currentSchemaVersion,
                universalPlaylist: migrated.universal,
                transitions: migrated.legacy
            )
        case Self.currentSchemaVersion:
            try self.init(
                schemaVersion: schemaVersion,
                universalPlaylist: container.decodeIfPresent(
                    StateMediaPlaylist.self,
                    forKey: .universalPlaylist
                ),
                transitions: normalizedTransitions
            )
        default:
            throw PetContractError.unsupportedVersion(schemaVersion)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(universalPlaylist, forKey: .universalPlaylist)
        try container.encode(
            Dictionary(uniqueKeysWithValues: transitions.map { ($0.key.storageKey, $0.value) }),
            forKey: .transitions
        )
    }

    public func transition(from: PetState, to: PetState) -> MediaEntry? {
        transitionPlaylist(from: from, to: to)?.fixedEntry
    }

    public func transitionPlaylist(from: PetState, to: PetState) -> StateMediaPlaylist? {
        guard from != to else { return nil }
        return universalPlaylist ?? legacyTransitionPlaylist(from: from, to: to)
    }

    public func legacyTransitionPlaylist(from: PetState, to: PetState) -> StateMediaPlaylist? {
        guard from != to, let key = try? StateTransitionKey(from: from, to: to) else { return nil }
        return transitions[key]
    }

    public func transitionEntries(from: PetState, to: PetState) -> [MediaEntry] {
        transitionPlaylist(from: from, to: to)?.entries ?? []
    }

    public var allTransitionEntries: [MediaEntry] {
        (universalPlaylist?.entries ?? []) + transitions.values.flatMap(\.entries)
    }

    public var allEntries: [MediaEntry] { allTransitionEntries }

    public func resolvedURL(for entry: MediaEntry, relativeTo libraryURL: URL) -> URL {
        if entry.path.hasPrefix("/") {
            return URL(fileURLWithPath: entry.path).standardizedFileURL
        }
        return libraryURL.deletingLastPathComponent()
            .appendingPathComponent(entry.path)
            .standardizedFileURL
    }

    public func resolvedPosterURL(for entry: MediaEntry, relativeTo libraryURL: URL) -> URL? {
        guard let path = entry.posterPath else { return nil }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return libraryURL.deletingLastPathComponent()
            .appendingPathComponent(path)
            .standardizedFileURL
    }

    public func settingUniversalTransition(_ entry: MediaEntry) throws -> Self {
        guard !requiresLegacyMigration else {
            throw PetContractError.invalidValue(
                "Global route-specific transitions require an explicit migration before editing the universal transition."
            )
        }
        return try replacingUniversalPlaylist(try StateMediaPlaylist(entries: [entry]))
    }

    /// Resolves conflicting route-keyed legacy data by explicitly choosing the
    /// playlist that becomes the universal fallback. Legacy routes remain in
    /// the file so their media and metadata stay recoverable until cleanup.
    public func migratingLegacyToUniversal(using key: StateTransitionKey) throws -> Self {
        guard requiresLegacyMigration, let playlist = transitions[key] else {
            throw PetContractError.invalidValue("the selected legacy Global transition is unavailable")
        }
        return try Self(
            schemaVersion: schemaVersion,
            universalPlaylist: playlist,
            transitions: transitions
        )
    }

    public func appendingUniversalTransitionEntry(_ entry: MediaEntry) throws -> Self {
        if let universalPlaylist {
            return try replacingUniversalPlaylist(universalPlaylist.appending(entry))
        }
        guard !requiresLegacyMigration else {
            throw PetContractError.invalidValue(
                "Global route-specific transitions require an explicit migration before editing the universal transition."
            )
        }
        return try settingUniversalTransition(entry)
    }

    public func replacingUniversalTransitionEntry(
        path: String,
        with replacement: MediaEntry
    ) throws -> Self {
        guard let universalPlaylist else {
            throw PetContractError.invalidValue("universal Global transition playlist was not found")
        }
        return try replacingUniversalPlaylist(universalPlaylist.replacing(path: path, with: replacement))
    }

    public func removingUniversalTransitionEntry(path: String) throws -> Self {
        guard let universalPlaylist else {
            throw PetContractError.invalidValue("universal Global transition playlist was not found")
        }
        return try replacingUniversalPlaylist(universalPlaylist.removing(path: path))
    }

    public func changingUniversalTransitionPlaybackMode(to mode: MediaPlaybackMode) throws -> Self {
        guard let universalPlaylist else {
            throw PetContractError.invalidValue("universal Global transition playlist was not found")
        }
        return try replacingUniversalPlaylist(universalPlaylist.changingMode(to: mode))
    }

    public func settingFixedUniversalTransitionEntry(path: String) throws -> Self {
        guard let universalPlaylist else {
            throw PetContractError.invalidValue("universal Global transition playlist was not found")
        }
        return try replacingUniversalPlaylist(universalPlaylist.settingFixed(path: path))
    }

    public func movingUniversalTransitionEntry(path: String, to destinationIndex: Int) throws -> Self {
        guard let universalPlaylist else {
            throw PetContractError.invalidValue("universal Global transition playlist was not found")
        }
        return try replacingUniversalPlaylist(universalPlaylist.movingEntry(path: path, to: destinationIndex))
    }

    public func removingUniversalTransition() throws -> Self {
        try replacingUniversalPlaylist(nil)
    }

    public func settingTransition(from: PetState, to: PetState, entry: MediaEntry) throws -> Self {
        let key = try StateTransitionKey(from: from, to: to)
        var updated = transitions
        updated[key] = try StateMediaPlaylist(entries: [entry])
        return try replacingTransitions(updated)
    }

    public func appendingTransitionEntry(_ entry: MediaEntry, from: PetState, to: PetState) throws -> Self {
        let key = try StateTransitionKey(from: from, to: to)
        var updated = transitions
        if let playlist = updated[key] {
            updated[key] = try playlist.appending(entry)
        } else {
            updated[key] = try StateMediaPlaylist(entries: [entry])
        }
        return try replacingTransitions(updated)
    }

    public func replacingTransitionEntry(
        from: PetState,
        to: PetState,
        path: String,
        with replacement: MediaEntry
    ) throws -> Self {
        let key = try StateTransitionKey(from: from, to: to)
        guard let playlist = transitions[key] else {
            throw PetContractError.invalidValue("transition playlist was not found")
        }
        var updated = transitions
        updated[key] = try playlist.replacing(path: path, with: replacement)
        return try replacingTransitions(updated)
    }

    public func removingTransitionEntry(from: PetState, to: PetState, path: String) throws -> Self {
        let key = try StateTransitionKey(from: from, to: to)
        guard let playlist = transitions[key] else {
            throw PetContractError.invalidValue("transition playlist was not found")
        }
        var updated = transitions
        updated[key] = try playlist.removing(path: path)
        return try replacingTransitions(updated)
    }

    public func changingTransitionPlaybackMode(
        from: PetState,
        to: PetState,
        to mode: MediaPlaybackMode
    ) throws -> Self {
        let key = try StateTransitionKey(from: from, to: to)
        guard let playlist = transitions[key] else {
            throw PetContractError.invalidValue("transition playlist was not found")
        }
        var updated = transitions
        updated[key] = try playlist.changingMode(to: mode)
        return try replacingTransitions(updated)
    }

    public func settingFixedTransitionEntry(from: PetState, to: PetState, path: String) throws -> Self {
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

    public func movingTransitionEntry(
        from: PetState,
        to: PetState,
        path: String,
        to destinationIndex: Int
    ) throws -> Self {
        let key = try StateTransitionKey(from: from, to: to)
        guard let playlist = transitions[key] else {
            throw PetContractError.invalidValue("transition playlist was not found")
        }
        var updated = transitions
        updated[key] = try playlist.movingEntry(path: path, to: destinationIndex)
        return try replacingTransitions(updated)
    }

    public func removingTransition(from: PetState, to: PetState) throws -> Self {
        let key = try StateTransitionKey(from: from, to: to)
        var updated = transitions
        updated[key] = nil
        return try replacingTransitions(updated)
    }

    private func replacingTransitions(_ transitions: [StateTransitionKey: StateMediaPlaylist]) throws -> Self {
        try Self(
            schemaVersion: schemaVersion,
            universalPlaylist: universalPlaylist,
            transitions: transitions
        )
    }

    private func replacingUniversalPlaylist(_ playlist: StateMediaPlaylist?) throws -> Self {
        try Self(
            schemaVersion: schemaVersion,
            universalPlaylist: playlist,
            transitions: transitions
        )
    }

    private static func normalizedPlaylist(_ playlist: StateMediaPlaylist?) throws -> StateMediaPlaylist? {
        guard let playlist else { return nil }
        let entries = try playlist.entries.map { entry in
            _ = try PlaybackRate(entry.playbackRate.value)
            return try MediaEntry(
                path: entry.path,
                posterPath: entry.posterPath,
                loop: false,
                playbackRate: entry.playbackRate.value
            )
        }
        return try StateMediaPlaylist(
            mode: playlist.mode,
            advanceOn: .stateEntry,
            fixedPath: playlist.fixedPath,
            entries: entries
        )
    }

    private static func normalized(
        _ transitions: [StateTransitionKey: StateMediaPlaylist]
    ) throws -> [StateTransitionKey: StateMediaPlaylist] {
        var normalized: [StateTransitionKey: StateMediaPlaylist] = [:]
        for (key, playlist) in transitions {
            guard key.from != key.to else {
                throw PetContractError.invalidValue("transition states must be distinct")
            }
            normalized[key] = try normalizedPlaylist(playlist)!
        }
        return normalized
    }

    private static func migrateLegacy(
        _ transitions: [StateTransitionKey: StateMediaPlaylist]
    ) -> (universal: StateMediaPlaylist?, legacy: [StateTransitionKey: StateMediaPlaylist]) {
        guard let first = transitions.values.first else {
            return (nil, [:])
        }
        guard transitions.values.dropFirst().allSatisfy({ $0 == first }) else {
            return (nil, transitions)
        }
        return (first, [:])
    }
}
