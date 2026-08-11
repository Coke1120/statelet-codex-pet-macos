import Foundation

public enum CharacterBundleAssetRole: String, Codable, CaseIterable, Sendable {
    case movie
    case poster
    case report
}

public struct CharacterBundleAsset: Codable, Equatable, Sendable {
    public let role: CharacterBundleAssetRole
    public let path: String
    public let size: UInt64
    public let sha256: String
    public let moviePath: String?

    public init(
        role: CharacterBundleAssetRole,
        path: String,
        size: UInt64,
        sha256: String,
        moviePath: String? = nil
    ) {
        self.role = role
        self.path = path
        self.size = size
        self.sha256 = sha256
        self.moviePath = moviePath
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case path
        case size
        case sha256
        case moviePath = "movie_path"
    }
}

public struct CharacterBundleManifest: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumManifestSize: UInt64 = 1 * 1024 * 1024
    public static let maximumAssetCount = 256
    public static let maximumMovieSize: UInt64 = 512 * 1024 * 1024
    public static let maximumPosterSize: UInt64 = 32 * 1024 * 1024
    public static let maximumReportSize: UInt64 = 1 * 1024 * 1024
    public static let maximumAggregateSize: UInt64 = 2 * 1024 * 1024 * 1024

    public let schemaVersion: Int
    public let characterID: String
    public let characterName: String
    public let mediaMap: MediaMap
    public let assets: [CharacterBundleAsset]

    public init(
        schemaVersion: Int = Self.schemaVersion,
        characterID: String,
        characterName: String,
        mediaMap: MediaMap,
        assets: [CharacterBundleAsset]
    ) throws {
        self.schemaVersion = schemaVersion
        self.characterID = characterID
        self.characterName = characterName
        self.mediaMap = mediaMap
        self.assets = assets
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case characterID = "character_id"
        case characterName = "character_name"
        case mediaMap = "media_map"
        case assets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            characterID: container.decode(String.self, forKey: .characterID),
            characterName: container.decode(String.self, forKey: .characterName),
            mediaMap: container.decode(MediaMap.self, forKey: .mediaMap),
            assets: container.decode([CharacterBundleAsset].self, forKey: .assets)
        )
    }

    public static func decode(_ data: Data, using decoder: JSONDecoder = .codexPet) throws -> CharacterBundleManifest {
        guard UInt64(data.count) <= maximumManifestSize else {
            throw PetContractError.invalidValue("character bundle manifest exceeds 1 MiB")
        }
        let manifest = try decoder.decode(CharacterBundleManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    public func validate() throws {
        guard schemaVersion == Self.schemaVersion else {
            throw PetContractError.unsupportedVersion(schemaVersion)
        }
        try CharacterLibraryEntry.validateID(characterID)
        try CharacterLibraryEntry.validateName(characterName)
        guard assets.count <= Self.maximumAssetCount else {
            throw PetContractError.invalidValue("character bundle contains more than 256 assets")
        }

        var assetsByPath: [String: CharacterBundleAsset] = [:]
        var collisionKeys = Set<String>()
        var aggregateSize: UInt64 = 0
        for asset in assets {
            try CharacterBundlePath.validate(asset.path)
            let collisionKey = Self.collisionKey(asset.path)
            guard collisionKeys.insert(collisionKey).inserted else {
                throw PetContractError.invalidValue("character bundle asset paths collide by case or NFC")
            }
            assetsByPath[asset.path] = asset
            guard asset.size > 0, asset.size <= Self.maximumSize(for: asset.role) else {
                throw PetContractError.invalidValue("character bundle asset size is invalid for role \(asset.role.rawValue)")
            }
            let (sum, overflow) = aggregateSize.addingReportingOverflow(asset.size)
            guard !overflow, sum <= Self.maximumAggregateSize else {
                throw PetContractError.invalidValue("character bundle aggregate size exceeds 2 GiB")
            }
            aggregateSize = sum
            guard asset.sha256.count == 64,
                  asset.sha256.unicodeScalars.allSatisfy({
                      ($0.value >= 48 && $0.value <= 57) || ($0.value >= 97 && $0.value <= 102)
                  }) else {
                throw PetContractError.invalidValue("character bundle sha256 must be 64 lowercase hexadecimal characters")
            }
            if let moviePath = asset.moviePath {
                try CharacterBundlePath.validate(moviePath)
            }
            if asset.role == .report {
                guard asset.moviePath != nil else {
                    throw PetContractError.invalidValue("report asset must declare movie_path")
                }
            } else if asset.moviePath != nil {
                throw PetContractError.invalidValue("movie_path is only valid for report assets")
            }
        }

        var referencedMoviePaths = Set<String>()
        var referencedPosterPaths = Set<String>()
        for playlist in mediaMap.states.values {
            for entry in playlist.entries {
                try Self.requireAsset(path: entry.path, role: .movie, assetsByPath: assetsByPath)
                referencedMoviePaths.insert(entry.path)
                if let posterPath = entry.posterPath {
                    try Self.requireAsset(path: posterPath, role: .poster, assetsByPath: assetsByPath)
                    referencedPosterPaths.insert(posterPath)
                }
            }
        }
        var reportedMovies = Set<String>()
        for report in assets where report.role == .report {
            try Self.requireAsset(path: report.moviePath!, role: .movie, assetsByPath: assetsByPath)
            guard referencedMoviePaths.contains(report.moviePath!) else {
                throw PetContractError.invalidValue("report asset must reference a movie used by the media map")
            }
            guard reportedMovies.insert(report.moviePath!).inserted else {
                throw PetContractError.invalidValue("character bundle must not contain multiple reports for one movie")
            }
        }
        for asset in assets {
            switch asset.role {
            case .movie:
                guard referencedMoviePaths.contains(asset.path) else {
                    throw PetContractError.invalidValue("character bundle contains an unreferenced movie")
                }
            case .poster:
                guard referencedPosterPaths.contains(asset.path) else {
                    throw PetContractError.invalidValue("character bundle contains an unreferenced poster")
                }
            case .report:
                break
            }
        }
    }

    /// Returns the bundled map with movie and poster references rewritten to
    /// importer-chosen installed paths. Global format and window settings are
    /// preserved exactly.
    public func mediaMap(
        rewritingPaths transform: (String) throws -> String
    ) throws -> MediaMap {
        var rewrittenStates: [PetState: StateMediaPlaylist] = [:]
        for (state, playlist) in mediaMap.states {
            let rewrittenEntries = try playlist.entries.map { entry in
                try MediaEntry(
                    path: transform(entry.path),
                    posterPath: try entry.posterPath.map(transform),
                    loop: entry.loop,
                    playbackRate: entry.playbackRate.value
                )
            }
            rewrittenStates[state] = try StateMediaPlaylist(
                mode: playlist.mode,
                advanceOn: playlist.advanceOn,
                fixedPath: transform(playlist.fixedPath),
                entries: rewrittenEntries
            )
        }
        return try MediaMap(
            version: mediaMap.version,
            defaultFormat: mediaMap.defaultFormat,
            window: mediaMap.window,
            states: rewrittenStates
        )
    }

    private static func maximumSize(for role: CharacterBundleAssetRole) -> UInt64 {
        switch role {
        case .movie: return maximumMovieSize
        case .poster: return maximumPosterSize
        case .report: return maximumReportSize
        }
    }

    private static func requireAsset(
        path: String,
        role: CharacterBundleAssetRole,
        assetsByPath: [String: CharacterBundleAsset]
    ) throws {
        try CharacterBundlePath.validate(path)
        guard let asset = assetsByPath[path], asset.role == role else {
            throw PetContractError.invalidValue(
                "character bundle reference \(path) is absent or has the wrong role"
            )
        }
    }

    private static func collisionKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }
}
