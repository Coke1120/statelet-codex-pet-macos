import Foundation

public enum TransitionLibraryScope: String, Codable, CaseIterable, Sendable {
    case character
    case global
}

public struct ResolvedTransitionPlaylist: Equatable, Sendable {
    public let scope: TransitionLibraryScope
    public let playlist: StateMediaPlaylist

    public init(scope: TransitionLibraryScope, playlist: StateMediaPlaylist) {
        self.scope = scope
        self.playlist = playlist
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
        if let playlist = character.transitionPlaylist(from: from, to: to) {
            return ResolvedTransitionPlaylist(scope: .character, playlist: playlist)
        }
        guard let playlist = global.transitionPlaylist(from: from, to: to) else {
            return nil
        }
        return ResolvedTransitionPlaylist(scope: .global, playlist: playlist)
    }
}

public struct GlobalTransitionLibrary: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let transitions: [StateTransitionKey: StateMediaPlaylist]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        transitions: [StateTransitionKey: StateMediaPlaylist] = [:]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw PetContractError.unsupportedVersion(schemaVersion)
        }
        self.schemaVersion = schemaVersion
        self.transitions = try Self.normalized(transitions)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case transitions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
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
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            transitions: transitions
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(
            Dictionary(uniqueKeysWithValues: transitions.map { ($0.key.storageKey, $0.value) }),
            forKey: .transitions
        )
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
        try Self(schemaVersion: schemaVersion, transitions: transitions)
    }

    private static func normalized(
        _ transitions: [StateTransitionKey: StateMediaPlaylist]
    ) throws -> [StateTransitionKey: StateMediaPlaylist] {
        var normalized: [StateTransitionKey: StateMediaPlaylist] = [:]
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
            normalized[key] = try StateMediaPlaylist(
                mode: playlist.mode,
                advanceOn: .stateEntry,
                fixedPath: playlist.fixedPath,
                entries: entries
            )
        }
        return normalized
    }
}
