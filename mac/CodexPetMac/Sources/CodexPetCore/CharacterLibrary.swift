import Foundation

public struct CharacterLibraryEntry: Codable, Equatable, Sendable {
    public static let maximumIDLength = 64
    public static let maximumNameLength = 80

    public let id: String
    public let name: String
    public let mapPath: String

    public init(id: String, name: String, mapPath: String? = nil) throws {
        try Self.validateID(id)
        try Self.validateName(name)
        let resolvedMapPath = mapPath ?? Self.defaultMapPath(for: id)
        try Self.validateMapPath(resolvedMapPath, for: id)
        self.id = id
        self.name = name
        self.mapPath = resolvedMapPath
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case mapPath = "map_path"
    }

    public func resolvedMapURL(relativeTo rootMapURL: URL) -> URL {
        rootMapURL.deletingLastPathComponent()
            .appendingPathComponent(mapPath)
            .standardizedFileURL
    }

    static func defaultMapPath(for id: String) -> String {
        id == CharacterLibrary.defaultCharacterID
            ? CharacterLibrary.defaultMapPath
            : ".character-\(id).media-map.json"
    }

    static func validateID(_ id: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !id.isEmpty,
              id.count <= maximumIDLength,
              id.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              id.first?.isLetter == true || id.first?.isNumber == true else {
            throw PetContractError.invalidValue(
                "character id must be 1...\(maximumIDLength) ASCII letters, digits, dot, underscore, or hyphen and start with a letter or digit"
            )
        }
    }

    static func validateName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name == trimmed,
              !name.isEmpty,
              name.count <= maximumNameLength,
              name == name.precomposedStringWithCanonicalMapping,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PetContractError.invalidValue(
                "character name must be 1...\(maximumNameLength) NFC characters without surrounding whitespace or controls"
            )
        }
    }

    static func validateMapPath(_ path: String, for id: String) throws {
        try CharacterBundlePath.validate(path)
        if id == CharacterLibrary.defaultCharacterID {
            guard !path.contains("/") else {
                throw PetContractError.invalidValue("default character map_path must be a same-directory basename")
            }
            return
        }
        guard path == defaultMapPath(for: id) else {
            throw PetContractError.invalidValue(
                "non-default character map_path must be .character-<id>.media-map.json"
            )
        }
    }
}

public struct CharacterLibrary: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let defaultCharacterID = "default"
    public static let defaultCharacterName = "Default"
    public static let defaultMapPath = "media-map.json"
    public static let maximumCharacterCount = 256

    public let schemaVersion: Int
    public let activeCharacterID: String
    public let characters: [CharacterLibraryEntry]

    public static var legacy: CharacterLibrary {
        try! legacy(mapPath: defaultMapPath)
    }

    public static func legacy(mapPath: String) throws -> CharacterLibrary {
        try CharacterLibrary(
            activeCharacterID: defaultCharacterID,
            characters: [try CharacterLibraryEntry(
                id: defaultCharacterID,
                name: defaultCharacterName,
                mapPath: mapPath
            )]
        )
    }

    public init(
        schemaVersion: Int = Self.schemaVersion,
        activeCharacterID: String,
        characters: [CharacterLibraryEntry]
    ) throws {
        guard schemaVersion == Self.schemaVersion else {
            throw PetContractError.unsupportedVersion(schemaVersion)
        }
        guard !characters.isEmpty else {
            throw PetContractError.invalidValue("character library must contain at least one character")
        }
        guard characters.count <= Self.maximumCharacterCount else {
            throw PetContractError.invalidValue("character library contains more than 256 characters")
        }

        var ids = Set<String>()
        var names = Set<String>()
        var paths = Set<String>()
        for character in characters {
            try CharacterLibraryEntry.validateID(character.id)
            try CharacterLibraryEntry.validateName(character.name)
            try CharacterLibraryEntry.validateMapPath(character.mapPath, for: character.id)
            guard ids.insert(character.id.lowercased()).inserted else {
                throw PetContractError.invalidValue("character ids must be unique ignoring case")
            }
            guard names.insert(Self.collisionKey(character.name)).inserted else {
                throw PetContractError.invalidValue("character names must be unique ignoring case and NFC")
            }
            guard paths.insert(Self.collisionKey(character.mapPath)).inserted else {
                throw PetContractError.invalidValue("character map paths must be unique ignoring case and NFC")
            }
        }
        guard characters.contains(where: { $0.id == activeCharacterID }) else {
            throw PetContractError.invalidValue("active_character_id must reference a character")
        }
        self.schemaVersion = schemaVersion
        self.activeCharacterID = activeCharacterID
        self.characters = characters
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case activeCharacterID = "active_character_id"
        case characters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            activeCharacterID: container.decode(String.self, forKey: .activeCharacterID),
            characters: container.decode([CharacterLibraryEntry].self, forKey: .characters)
        )
    }

    public var activeCharacter: CharacterLibraryEntry {
        characters.first(where: { $0.id == activeCharacterID })!
    }

    public func character(id: String) -> CharacterLibraryEntry? {
        characters.first(where: { $0.id == id })
    }

    public func selectingCharacter(id: String) throws -> CharacterLibrary {
        guard character(id: id) != nil else {
            throw PetContractError.invalidValue("character was not found")
        }
        return try CharacterLibrary(
            schemaVersion: schemaVersion,
            activeCharacterID: id,
            characters: characters
        )
    }

    public func addingCharacter(id: String, name: String) throws -> CharacterLibrary {
        guard character(id: id) == nil else {
            throw PetContractError.invalidValue("character id already exists")
        }
        let added = try CharacterLibraryEntry(id: id, name: name)
        return try CharacterLibrary(
            schemaVersion: schemaVersion,
            activeCharacterID: activeCharacterID,
            characters: characters + [added]
        )
    }

    public func renamingCharacter(id: String, to name: String) throws -> CharacterLibrary {
        guard let index = characters.firstIndex(where: { $0.id == id }) else {
            throw PetContractError.invalidValue("character was not found")
        }
        var updated = characters
        updated[index] = try CharacterLibraryEntry(
            id: updated[index].id,
            name: name,
            mapPath: updated[index].mapPath
        )
        return try CharacterLibrary(
            schemaVersion: schemaVersion,
            activeCharacterID: activeCharacterID,
            characters: updated
        )
    }

    public func duplicatingCharacter(id: String, as newID: String, name: String) throws -> CharacterLibrary {
        guard character(id: id) != nil else {
            throw PetContractError.invalidValue("character was not found")
        }
        return try addingCharacter(id: newID, name: name)
    }

    public func removingCharacter(id: String) throws -> CharacterLibrary {
        guard character(id: id) != nil else {
            throw PetContractError.invalidValue("character was not found")
        }
        guard characters.count > 1 else {
            throw PetContractError.invalidValue("cannot remove the last character")
        }
        let updated = characters.filter { $0.id != id }
        let nextActiveID: String
        if id != activeCharacterID {
            nextActiveID = activeCharacterID
        } else if updated.contains(where: { $0.id == Self.defaultCharacterID }) {
            nextActiveID = Self.defaultCharacterID
        } else {
            nextActiveID = updated.map(\.id).sorted()[0]
        }
        return try CharacterLibrary(
            schemaVersion: schemaVersion,
            activeCharacterID: nextActiveID,
            characters: updated
        )
    }

    private static func collisionKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
    }
}

enum CharacterBundlePath {
    static let maximumPathBytes = 1_024
    static let maximumComponentBytes = 255

    static func validate(_ path: String) throws {
        guard !path.isEmpty,
              path.utf8.count <= maximumPathBytes,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              path == path.precomposedStringWithCanonicalMapping else {
            throw PetContractError.invalidValue("path must be a non-empty normalized bundle-relative path")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({
            !$0.isEmpty
                && $0 != "."
                && $0 != ".."
                && $0.utf8.count <= maximumComponentBytes
        }) else {
            throw PetContractError.invalidValue("path must not contain empty, dot, or dot-dot components")
        }
    }
}
