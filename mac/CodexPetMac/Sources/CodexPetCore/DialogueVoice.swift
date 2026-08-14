import Foundation
import Darwin

public enum DialogueVoiceEndpointPolicy {
    public static func validatedLoopbackURL(_ url: URL) throws -> URL {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "http",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host?.lowercased(),
              isNumericLoopbackHost(host) else {
            throw DialogueVoiceError.invalidEndpoint
        }
        return url
    }

    public static func isNumericLoopbackHost(_ host: String) -> Bool {
        if host == "::1" || host == "[::1]" {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4
            && octets.first == "127"
            && octets.allSatisfy { octet in
                guard !octet.isEmpty,
                      octet.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
                      let value = Int(octet) else {
                    return false
                }
                return (0...255).contains(value)
            }
    }
}

public enum DialogueVoiceError: Error, Equatable, LocalizedError {
    case unsupportedSchemaVersion(Int)
    case invalidProfile
    case invalidEndpoint
    case invalidLanguage
    case invalidText
    case invalidManagedPath
    case invalidFailureCode
    case invalidPlaybackSettings
    case invalidState
    case lineNotFound
    case profileNotConfigured
    case generationResultRejected
    case outputNotReady
    case storeFailure

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            return "Unsupported dialogue voice schema version: \(version)"
        case .invalidProfile:
            return "The voice profile is invalid."
        case .invalidEndpoint:
            return "The voice service must use a numeric loopback-only HTTP endpoint."
        case .invalidLanguage:
            return "The language value is invalid."
        case .invalidText:
            return "The dialogue text is invalid."
        case .invalidManagedPath:
            return "A managed file path is invalid."
        case .invalidFailureCode:
            return "The generation failure code is invalid."
        case .invalidPlaybackSettings:
            return "The voice playback settings are invalid."
        case .invalidState:
            return "The dialogue generation state is invalid."
        case .lineNotFound:
            return "The dialogue line no longer exists."
        case .profileNotConfigured:
            return "No voice profile is configured."
        case .generationResultRejected:
            return "The generation result no longer matches the current dialogue or voice profile."
        case .outputNotReady:
            return "The dialogue audio is not ready."
        case .storeFailure:
            return "The dialogue voice library could not be stored."
        }
    }
}

private enum DialogueVoiceValidation {
    static let maximumDialogueLength = 4_000
    static let maximumReferenceTextLength = 20_000
    static let maximumLabelLength = 128
    static let maximumLanguageLength = 64
    static let maximumDialogueCount = 500

    static func nonBlank(_ value: String, maximum: Int, error: DialogueVoiceError) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, value.count <= maximum, !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw error
        }
        return value
    }

    static func language(_ value: String) throws -> String {
        try nonBlank(value, maximum: maximumLanguageLength, error: .invalidLanguage)
    }

    static func managedPath(_ value: String) throws -> String {
        guard !value.isEmpty,
              value.count <= 1_024,
              !value.hasPrefix("/"),
              !value.hasPrefix("~"),
              !value.contains("\\"),
              !value.contains(":"),
              !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw DialogueVoiceError.invalidManagedPath
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DialogueVoiceError.invalidManagedPath
        }
        return value
    }

    static func packageRelativePath(_ value: String) throws -> String {
        let path = try managedPath(value)
        guard !path.hasPrefix("voice/") else {
            throw DialogueVoiceError.invalidManagedPath
        }
        return path
    }

    static func absoluteExecutablePath(_ value: String) throws -> String {
        guard !value.isEmpty,
              value.count <= 4_096,
              value.hasPrefix("/"),
              !value.hasPrefix("//"),
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw DialogueVoiceError.invalidManagedPath
        }
        let standardized = URL(fileURLWithPath: value, isDirectory: false).standardizedFileURL.path
        guard standardized == value, value != "/" else {
            throw DialogueVoiceError.invalidManagedPath
        }
        return value
    }

    static func voiceCleanupPath(_ value: String) throws -> String {
        let path = try managedPath(value)
        guard [
            "voice/assets/gpt/",
            "voice/assets/sovits/",
            "voice/assets/reference/",
            "voice/packages/qwen/",
            "voice/packages/voxcpm2/",
            "voice/assets/voxcpm2-reference/",
            "voice/generated/",
        ].contains(where: { path.hasPrefix($0) }) else {
            throw DialogueVoiceError.invalidManagedPath
        }
        return path
    }

    static func voxCPM2SnapshotPath(_ value: String) throws -> String {
        let path = try managedPath(value)
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 4,
              components[0] == "voice",
              components[1] == "packages",
              components[2] == "voxcpm2" else {
            throw DialogueVoiceError.invalidManagedPath
        }
        let token = String(components[3])
        guard UUID(uuidString: token) != nil, token == token.lowercased() else {
            throw DialogueVoiceError.invalidManagedPath
        }
        return path
    }

    static func endpoint(_ url: URL) throws -> URL {
        do {
            return try DialogueVoiceEndpointPolicy.validatedLoopbackURL(url)
        } catch {
            throw DialogueVoiceError.invalidEndpoint
        }
    }

    static func failureCode(_ value: String) throws -> String {
        guard !value.isEmpty, value.count <= 64,
              value.unicodeScalars.allSatisfy({ scalar in
                  (65...90).contains(scalar.value)
                      || (48...57).contains(scalar.value)
                      || scalar.value == 95
              }) else {
            throw DialogueVoiceError.invalidFailureCode
        }
        return value
    }

    static func sha256(_ value: String) throws -> String {
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
              }) else {
            throw DialogueVoiceError.invalidProfile
        }
        return value
    }
}

public enum DialogueVoiceProviderKind: String, Codable, CaseIterable, Sendable {
    case gptSovits = "gpt_sovits"
    case qwen3TTS = "qwen3_tts"
    case voxcpm2
}

public struct VoxCPM2SynthesisParameters: Codable, Equatable, Sendable {
    public static let verifiedDefaults = try! VoxCPM2SynthesisParameters()
    public let cfgValue: Double
    public let inferenceTimesteps: Int
    public let seed: Int
    public let loadDenoiser: Bool
    public let optimize: Bool

    public init(cfgValue: Double = 2, inferenceTimesteps: Int = 10, seed: Int = 1_112,
                loadDenoiser: Bool = false, optimize: Bool = false) throws {
        guard cfgValue.isFinite, (0...10).contains(cfgValue),
              (1...100).contains(inferenceTimesteps), seed >= 0,
              !loadDenoiser, !optimize else { throw DialogueVoiceError.invalidProfile }
        self.cfgValue = cfgValue
        self.inferenceTimesteps = inferenceTimesteps
        self.seed = seed
        self.loadDenoiser = loadDenoiser
        self.optimize = optimize
    }
}

/// A pinned, local-only VoxCPM2 zero-shot profile. `snapshotPath` retains its
/// persisted field name for schema compatibility, but stores only a managed
/// Application Support-relative package path.
public struct VoxCPM2VoiceProfile: Codable, Equatable, Sendable {
    public let id: UUID
    public let revision: Int
    public let name: String
    public let snapshotPath: String
    public let snapshotTreeSHA256: String
    public let pythonExecutablePath: String
    public let pythonExecutableSHA256: String
    public let referenceAudioRelativePath: String
    public let referenceAudioSHA256: String
    public let referenceText: String
    public let defaultTextLanguage: String
    public let parameters: VoxCPM2SynthesisParameters
    public let inputFingerprint: String

    public init(id: UUID = UUID(), revision: Int = 1, name: String,
                snapshotPath: String, snapshotTreeSHA256: String,
                pythonExecutablePath: String, pythonExecutableSHA256: String,
                referenceAudioRelativePath: String, referenceAudioSHA256: String,
                referenceText: String, defaultTextLanguage: String = "japanese",
                parameters: VoxCPM2SynthesisParameters = .verifiedDefaults,
                inputFingerprint: String) throws {
        guard revision > 0 else { throw DialogueVoiceError.invalidProfile }
        self.id = id; self.revision = revision
        self.name = try DialogueVoiceValidation.nonBlank(name, maximum: DialogueVoiceValidation.maximumLabelLength, error: .invalidProfile)
        self.snapshotPath = try DialogueVoiceValidation.voxCPM2SnapshotPath(snapshotPath)
        self.snapshotTreeSHA256 = try DialogueVoiceValidation.sha256(snapshotTreeSHA256)
        self.pythonExecutablePath = try DialogueVoiceValidation.absoluteExecutablePath(pythonExecutablePath)
        self.pythonExecutableSHA256 = try DialogueVoiceValidation.sha256(pythonExecutableSHA256)
        let reference = try DialogueVoiceValidation.managedPath(referenceAudioRelativePath)
        guard reference.hasPrefix("voice/assets/voxcpm2-reference/") else { throw DialogueVoiceError.invalidManagedPath }
        self.referenceAudioRelativePath = reference
        self.referenceAudioSHA256 = try DialogueVoiceValidation.sha256(referenceAudioSHA256)
        self.referenceText = try DialogueVoiceValidation.nonBlank(referenceText, maximum: DialogueVoiceValidation.maximumReferenceTextLength, error: .invalidText)
        self.defaultTextLanguage = try DialogueVoiceValidation.language(defaultTextLanguage)
        self.parameters = parameters
        self.inputFingerprint = try DialogueVoiceValidation.sha256(inputFingerprint)
    }

    public var inputFingerprintComponents: [String] {
        ["statelet-voxcpm2-profile-v2", snapshotPath, snapshotTreeSHA256,
         pythonExecutablePath, pythonExecutableSHA256, referenceAudioRelativePath,
         referenceAudioSHA256, referenceText, defaultTextLanguage,
         String(parameters.cfgValue), String(parameters.inferenceTimesteps),
         String(parameters.seed), String(parameters.loadDenoiser), String(parameters.optimize)]
    }

    private enum CodingKeys: String, CodingKey {
        case id, revision, name, snapshotPath, snapshotTreeSHA256
        case pythonExecutablePath, pythonExecutableSHA256
        case referenceAudioRelativePath, referenceAudioSHA256, referenceText
        case defaultTextLanguage, parameters, inputFingerprint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            revision: container.decode(Int.self, forKey: .revision),
            name: container.decode(String.self, forKey: .name),
            snapshotPath: container.decode(String.self, forKey: .snapshotPath),
            snapshotTreeSHA256: container.decode(String.self, forKey: .snapshotTreeSHA256),
            pythonExecutablePath: container.decode(String.self, forKey: .pythonExecutablePath),
            pythonExecutableSHA256: container.decode(String.self, forKey: .pythonExecutableSHA256),
            referenceAudioRelativePath: container.decode(
                String.self,
                forKey: .referenceAudioRelativePath
            ),
            referenceAudioSHA256: container.decode(String.self, forKey: .referenceAudioSHA256),
            referenceText: container.decode(String.self, forKey: .referenceText),
            defaultTextLanguage: container.decode(String.self, forKey: .defaultTextLanguage),
            parameters: container.decode(VoxCPM2SynthesisParameters.self, forKey: .parameters),
            inputFingerprint: container.decode(String.self, forKey: .inputFingerprint)
        )
    }
}

public struct GPTSoVITSVoiceProfile: Codable, Equatable, Sendable {
    public let id: UUID
    public let revision: Int
    public let name: String
    public let apiBaseURL: URL
    public let gptWeightRelativePath: String
    public let sovitsWeightRelativePath: String
    public let referenceAudioRelativePath: String
    public let referenceText: String
    public let promptLanguage: String
    public let defaultTextLanguage: String
    public let inputFingerprint: String

    public init(
        id: UUID = UUID(),
        revision: Int = 1,
        name: String,
        apiBaseURL: URL,
        gptWeightRelativePath: String,
        sovitsWeightRelativePath: String,
        referenceAudioRelativePath: String,
        referenceText: String,
        promptLanguage: String,
        defaultTextLanguage: String,
        inputFingerprint: String
    ) throws {
        guard revision > 0 else { throw DialogueVoiceError.invalidProfile }
        self.id = id
        self.revision = revision
        self.name = try DialogueVoiceValidation.nonBlank(
            name,
            maximum: DialogueVoiceValidation.maximumLabelLength,
            error: .invalidProfile
        )
        self.apiBaseURL = try DialogueVoiceValidation.endpoint(apiBaseURL)
        self.gptWeightRelativePath = try DialogueVoiceValidation.managedPath(gptWeightRelativePath)
        self.sovitsWeightRelativePath = try DialogueVoiceValidation.managedPath(sovitsWeightRelativePath)
        self.referenceAudioRelativePath = try DialogueVoiceValidation.managedPath(referenceAudioRelativePath)
        self.referenceText = try DialogueVoiceValidation.nonBlank(
            referenceText,
            maximum: DialogueVoiceValidation.maximumReferenceTextLength,
            error: .invalidText
        )
        self.promptLanguage = try DialogueVoiceValidation.language(promptLanguage)
        self.defaultTextLanguage = try DialogueVoiceValidation.language(defaultTextLanguage)
        self.inputFingerprint = try DialogueVoiceValidation.sha256(inputFingerprint)
    }

    private enum CodingKeys: String, CodingKey {
        case id, revision
        case name
        case apiBaseURL = "api_base_url"
        case gptWeightRelativePath = "gpt_weight_relative_path"
        case sovitsWeightRelativePath = "sovits_weight_relative_path"
        case referenceAudioRelativePath = "reference_audio_relative_path"
        case referenceText = "reference_text"
        case promptLanguage = "prompt_language"
        case defaultTextLanguage = "default_text_language"
        case inputFingerprint = "input_fingerprint"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            revision: container.decode(Int.self, forKey: .revision),
            name: container.decode(String.self, forKey: .name),
            apiBaseURL: container.decode(URL.self, forKey: .apiBaseURL),
            gptWeightRelativePath: container.decode(String.self, forKey: .gptWeightRelativePath),
            sovitsWeightRelativePath: container.decode(String.self, forKey: .sovitsWeightRelativePath),
            referenceAudioRelativePath: container.decode(String.self, forKey: .referenceAudioRelativePath),
            referenceText: container.decode(String.self, forKey: .referenceText),
            promptLanguage: container.decode(String.self, forKey: .promptLanguage),
            defaultTextLanguage: container.decode(String.self, forKey: .defaultTextLanguage),
            inputFingerprint: container.decode(String.self, forKey: .inputFingerprint)
        )
    }
}

public struct Qwen3TTSSynthesisParameters: Codable, Equatable, Sendable {
    public static let verifiedDefaults = try! Qwen3TTSSynthesisParameters()

    public let temperature: Double
    public let topK: Int
    public let topP: Double
    public let repetitionPenalty: Double
    public let maximumTokens: Int
    public let seed: Int

    public init(
        temperature: Double = 0.7,
        topK: Int = 40,
        topP: Double = 0.95,
        repetitionPenalty: Double = 1.05,
        maximumTokens: Int = 2_048,
        seed: Int = 1_112
    ) throws {
        guard temperature.isFinite, (0...2).contains(temperature),
              (1...1_000).contains(topK),
              topP.isFinite, (0...1).contains(topP),
              repetitionPenalty.isFinite, (0.1...10).contains(repetitionPenalty),
              (1...8_192).contains(maximumTokens),
              seed >= 0 else {
            throw DialogueVoiceError.invalidProfile
        }
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.repetitionPenalty = repetitionPenalty
        self.maximumTokens = maximumTokens
        self.seed = seed
    }

    private enum CodingKeys: String, CodingKey {
        case temperature
        case topK = "top_k"
        case topP = "top_p"
        case repetitionPenalty = "repetition_penalty"
        case maximumTokens = "maximum_tokens"
        case seed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            temperature: container.decode(Double.self, forKey: .temperature),
            topK: container.decode(Int.self, forKey: .topK),
            topP: container.decode(Double.self, forKey: .topP),
            repetitionPenalty: container.decode(Double.self, forKey: .repetitionPenalty),
            maximumTokens: container.decode(Int.self, forKey: .maximumTokens),
            seed: container.decode(Int.self, forKey: .seed)
        )
    }
}

/// Immutable identities for the private files that make up an imported Qwen
/// handover package. Paths are relative to `packageRootRelativePath` and never
/// accept external URLs or model identifiers.
public struct Qwen3TTSPackageManifest: Codable, Equatable, Sendable {
    public let modelRelativePath: String
    public let configRelativePath: String
    public let handoverGeneratorRelativePath: String
    public let referenceAudioRelativePath: String
    public let modelSHA256: String
    public let configSHA256: String
    public let handoverGeneratorSHA256: String
    public let referenceAudioSHA256: String

    public init(
        modelRelativePath: String = "model/model.safetensors",
        configRelativePath: String = "config.json",
        handoverGeneratorRelativePath: String = "generate.py",
        referenceAudioRelativePath: String,
        modelSHA256: String,
        configSHA256: String,
        handoverGeneratorSHA256: String,
        referenceAudioSHA256: String
    ) throws {
        self.modelRelativePath = try DialogueVoiceValidation.packageRelativePath(modelRelativePath)
        self.configRelativePath = try DialogueVoiceValidation.packageRelativePath(configRelativePath)
        self.handoverGeneratorRelativePath = try DialogueVoiceValidation.packageRelativePath(
            handoverGeneratorRelativePath
        )
        self.referenceAudioRelativePath = try DialogueVoiceValidation.packageRelativePath(
            referenceAudioRelativePath
        )
        self.modelSHA256 = try DialogueVoiceValidation.sha256(modelSHA256)
        self.configSHA256 = try DialogueVoiceValidation.sha256(configSHA256)
        self.handoverGeneratorSHA256 = try DialogueVoiceValidation.sha256(handoverGeneratorSHA256)
        self.referenceAudioSHA256 = try DialogueVoiceValidation.sha256(referenceAudioSHA256)
    }

    private enum CodingKeys: String, CodingKey {
        case modelRelativePath = "model_relative_path"
        case configRelativePath = "config_relative_path"
        case handoverGeneratorRelativePath = "handover_generator_relative_path"
        case referenceAudioRelativePath = "reference_audio_relative_path"
        case modelSHA256 = "model_sha256"
        case configSHA256 = "config_sha256"
        case handoverGeneratorSHA256 = "handover_generator_sha256"
        case referenceAudioSHA256 = "reference_audio_sha256"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            modelRelativePath: container.decode(String.self, forKey: .modelRelativePath),
            configRelativePath: container.decode(String.self, forKey: .configRelativePath),
            handoverGeneratorRelativePath: container.decode(String.self, forKey: .handoverGeneratorRelativePath),
            referenceAudioRelativePath: container.decode(String.self, forKey: .referenceAudioRelativePath),
            modelSHA256: container.decode(String.self, forKey: .modelSHA256),
            configSHA256: container.decode(String.self, forKey: .configSHA256),
            handoverGeneratorSHA256: container.decode(String.self, forKey: .handoverGeneratorSHA256),
            referenceAudioSHA256: container.decode(String.self, forKey: .referenceAudioSHA256)
        )
    }
}

public struct Qwen3TTSVoiceProfile: Codable, Equatable, Sendable {
    public let id: UUID
    public let revision: Int
    public let name: String
    public let packageRootRelativePath: String
    public let pythonExecutablePath: String
    public let pythonExecutableSHA256: String
    public let packageTreeSHA256: String
    public let manifest: Qwen3TTSPackageManifest
    public let referenceText: String
    public let referenceLanguage: String
    public let defaultTextLanguage: String
    public let parameters: Qwen3TTSSynthesisParameters
    public let inputFingerprint: String

    public var modelRelativePath: String { manifest.modelRelativePath }
    public var configRelativePath: String { manifest.configRelativePath }
    public var handoverGeneratorRelativePath: String { manifest.handoverGeneratorRelativePath }
    public var referenceAudioRelativePath: String { manifest.referenceAudioRelativePath }
    public var modelSHA256: String { manifest.modelSHA256 }
    public var configSHA256: String { manifest.configSHA256 }
    public var handoverGeneratorSHA256: String { manifest.handoverGeneratorSHA256 }
    public var referenceAudioSHA256: String { manifest.referenceAudioSHA256 }
    public var temperature: Double { parameters.temperature }
    public var topK: Int { parameters.topK }
    public var topP: Double { parameters.topP }
    public var repetitionPenalty: Double { parameters.repetitionPenalty }
    public var maximumTokens: Int { parameters.maximumTokens }
    public var seed: Int { parameters.seed }

    public init(
        id: UUID = UUID(),
        revision: Int = 1,
        name: String,
        packageRootRelativePath: String,
        pythonExecutablePath: String,
        pythonExecutableSHA256: String,
        packageTreeSHA256: String,
        manifest: Qwen3TTSPackageManifest,
        referenceText: String,
        referenceLanguage: String,
        defaultTextLanguage: String,
        parameters: Qwen3TTSSynthesisParameters = .verifiedDefaults,
        inputFingerprint: String
    ) throws {
        guard revision > 0 else { throw DialogueVoiceError.invalidProfile }
        let packageRoot = try DialogueVoiceValidation.managedPath(packageRootRelativePath)
        guard packageRoot.hasPrefix("voice/packages/qwen/") else {
            throw DialogueVoiceError.invalidManagedPath
        }
        self.id = id
        self.revision = revision
        self.name = try DialogueVoiceValidation.nonBlank(
            name,
            maximum: DialogueVoiceValidation.maximumLabelLength,
            error: .invalidProfile
        )
        self.packageRootRelativePath = packageRoot
        self.pythonExecutablePath = try DialogueVoiceValidation.absoluteExecutablePath(pythonExecutablePath)
        self.pythonExecutableSHA256 = try DialogueVoiceValidation.sha256(pythonExecutableSHA256)
        self.packageTreeSHA256 = try DialogueVoiceValidation.sha256(packageTreeSHA256)
        self.manifest = manifest
        self.referenceText = try DialogueVoiceValidation.nonBlank(
            referenceText,
            maximum: DialogueVoiceValidation.maximumReferenceTextLength,
            error: .invalidText
        )
        self.referenceLanguage = try DialogueVoiceValidation.language(referenceLanguage)
        self.defaultTextLanguage = try DialogueVoiceValidation.language(defaultTextLanguage)
        self.parameters = parameters
        self.inputFingerprint = try DialogueVoiceValidation.sha256(inputFingerprint)
    }

    /// Stable UTF-8 material for recomputing `inputFingerprint`. Runtime code
    /// hashes these length-delimited fields with SHA-256 after validating the
    /// selected Python executable and imported package files against their
    /// recorded identities.
    public var inputFingerprintComponents: [String] {
        [
            "statelet-qwen3-tts-profile-v1",
            packageRootRelativePath,
            pythonExecutablePath,
            pythonExecutableSHA256,
            packageTreeSHA256,
            manifest.modelRelativePath,
            manifest.modelSHA256,
            manifest.configRelativePath,
            manifest.configSHA256,
            manifest.handoverGeneratorRelativePath,
            manifest.handoverGeneratorSHA256,
            manifest.referenceAudioRelativePath,
            manifest.referenceAudioSHA256,
            referenceText,
            referenceLanguage,
            defaultTextLanguage,
            String(parameters.temperature),
            String(parameters.topK),
            String(parameters.topP),
            String(parameters.repetitionPenalty),
            String(parameters.maximumTokens),
            String(parameters.seed),
        ]
    }

    private enum CodingKeys: String, CodingKey {
        case id, revision, name, manifest, parameters
        case packageRootRelativePath = "package_root_relative_path"
        case pythonExecutablePath = "python_executable_path"
        case pythonExecutableSHA256 = "python_executable_sha256"
        case packageTreeSHA256 = "package_tree_sha256"
        case referenceText = "reference_text"
        case referenceLanguage = "reference_language"
        case defaultTextLanguage = "default_text_language"
        case inputFingerprint = "input_fingerprint"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            revision: container.decode(Int.self, forKey: .revision),
            name: container.decode(String.self, forKey: .name),
            packageRootRelativePath: container.decode(String.self, forKey: .packageRootRelativePath),
            pythonExecutablePath: container.decode(String.self, forKey: .pythonExecutablePath),
            pythonExecutableSHA256: container.decode(String.self, forKey: .pythonExecutableSHA256),
            packageTreeSHA256: container.decode(String.self, forKey: .packageTreeSHA256),
            manifest: container.decode(Qwen3TTSPackageManifest.self, forKey: .manifest),
            referenceText: container.decode(String.self, forKey: .referenceText),
            referenceLanguage: container.decode(String.self, forKey: .referenceLanguage),
            defaultTextLanguage: container.decode(String.self, forKey: .defaultTextLanguage),
            parameters: container.decode(Qwen3TTSSynthesisParameters.self, forKey: .parameters),
            inputFingerprint: container.decode(String.self, forKey: .inputFingerprint)
        )
    }
}

public enum DialogueGenerationStatus: String, Codable, CaseIterable, Sendable {
    case draft
    case queued
    case generating
    case ready
    case failed
    case stale
}

public enum DialogueSynthesisPolicy {
    /// Outputs created before Statelet adopted the deterministic short-utterance
    /// GPT-SoVITS request recipe.
    public static let legacyVersion = 1

    /// `cut0`, serial inference, no split buckets or fragment padding, pinned
    /// sampling controls, and a deterministic GPT-SoVITS seed.
    public static let currentVersion = 3
}

public enum DialogueVoiceProfileStatus: String, Codable, CaseIterable, Sendable {
    case notConfigured = "not_configured"
    case validating
    case ready
    case invalid
    case unavailable
}

public struct DialogueLine: Codable, Equatable, Sendable {
    public let id: UUID
    public let state: PetState
    public let text: String
    public let textLanguage: String
    public let revision: Int
    public let status: DialogueGenerationStatus
    public let generatedProfileRevision: Int?
    public let generatedSynthesisPolicyVersion: Int?
    public let outputRelativePath: String?
    public let failureCode: String?

    public init(
        id: UUID = UUID(),
        state: PetState = .idle,
        text: String,
        textLanguage: String,
        revision: Int = 1,
        status: DialogueGenerationStatus = .draft,
        generatedProfileRevision: Int? = nil,
        generatedSynthesisPolicyVersion: Int? = nil,
        outputRelativePath: String? = nil,
        failureCode: String? = nil
    ) throws {
        guard revision > 0 else { throw DialogueVoiceError.invalidState }
        self.id = id
        self.state = state
        self.text = try DialogueVoiceValidation.nonBlank(
            text,
            maximum: DialogueVoiceValidation.maximumDialogueLength,
            error: .invalidText
        )
        self.textLanguage = try DialogueVoiceValidation.language(textLanguage)
        self.revision = revision
        self.status = status
        self.generatedProfileRevision = generatedProfileRevision
        self.generatedSynthesisPolicyVersion = generatedSynthesisPolicyVersion
        self.outputRelativePath = try outputRelativePath.map(DialogueVoiceValidation.managedPath)
        self.failureCode = try failureCode.map(DialogueVoiceValidation.failureCode)
        try validateState()
    }

    private func validateState() throws {
        switch status {
        case .draft:
            guard generatedProfileRevision == nil,
                  generatedSynthesisPolicyVersion == nil,
                  outputRelativePath == nil,
                  failureCode == nil else {
                throw DialogueVoiceError.invalidState
            }
        case .queued, .generating:
            let hasNoPriorOutput = generatedProfileRevision == nil
                && generatedSynthesisPolicyVersion == nil
                && outputRelativePath == nil
            let hasRetainedPriorOutput = (generatedProfileRevision ?? 0) > 0
                && (generatedSynthesisPolicyVersion ?? 0) > 0
                && outputRelativePath != nil
            guard (hasNoPriorOutput || hasRetainedPriorOutput), failureCode == nil else {
                throw DialogueVoiceError.invalidState
            }
        case .ready:
            guard let generatedProfileRevision, generatedProfileRevision > 0,
                  let generatedSynthesisPolicyVersion, generatedSynthesisPolicyVersion > 0,
                  outputRelativePath != nil, failureCode == nil else {
                throw DialogueVoiceError.invalidState
            }
        case .failed:
            guard generatedProfileRevision == nil,
                  generatedSynthesisPolicyVersion == nil,
                  outputRelativePath == nil,
                  failureCode != nil else {
                throw DialogueVoiceError.invalidState
            }
        case .stale:
            guard let generatedProfileRevision, generatedProfileRevision > 0,
                  let generatedSynthesisPolicyVersion, generatedSynthesisPolicyVersion > 0,
                  outputRelativePath != nil, failureCode == nil else {
                throw DialogueVoiceError.invalidState
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, state, text, revision, status
        case textLanguage = "text_language"
        case generatedProfileRevision = "generated_profile_revision"
        case generatedSynthesisPolicyVersion = "generated_synthesis_policy_version"
        case outputRelativePath = "output_relative_path"
        case failureCode = "failure_code"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decode(DialogueGenerationStatus.self, forKey: .status)
        let outputRelativePath = try container.decodeIfPresent(String.self, forKey: .outputRelativePath)
        let generatedSynthesisPolicyVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .generatedSynthesisPolicyVersion
        ) ?? (outputRelativePath == nil ? nil : DialogueSynthesisPolicy.legacyVersion)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            state: container.decodeIfPresent(PetState.self, forKey: .state) ?? .idle,
            text: container.decode(String.self, forKey: .text),
            textLanguage: container.decode(String.self, forKey: .textLanguage),
            revision: container.decode(Int.self, forKey: .revision),
            status: status,
            generatedProfileRevision: container.decodeIfPresent(Int.self, forKey: .generatedProfileRevision),
            generatedSynthesisPolicyVersion: generatedSynthesisPolicyVersion,
            outputRelativePath: outputRelativePath,
            failureCode: container.decodeIfPresent(String.self, forKey: .failureCode)
        )
    }
}

public struct DialogueGenerationTicket: Codable, Equatable, Sendable {
    public let lineID: UUID
    public let lineRevision: Int
    public let profileID: UUID
    public let profileRevision: Int
    public let synthesisPolicyVersion: Int
    public let attemptID: UUID

    public init(
        lineID: UUID,
        lineRevision: Int,
        profileID: UUID,
        profileRevision: Int,
        synthesisPolicyVersion: Int = DialogueSynthesisPolicy.currentVersion,
        attemptID: UUID = UUID()
    ) throws {
        guard lineRevision > 0, profileRevision > 0, synthesisPolicyVersion > 0 else {
            throw DialogueVoiceError.invalidState
        }
        self.lineID = lineID
        self.lineRevision = lineRevision
        self.profileID = profileID
        self.profileRevision = profileRevision
        self.synthesisPolicyVersion = synthesisPolicyVersion
        self.attemptID = attemptID
    }

    private enum CodingKeys: String, CodingKey {
        case lineID = "line_id"
        case lineRevision = "line_revision"
        case profileID = "profile_id"
        case profileRevision = "profile_revision"
        case synthesisPolicyVersion = "synthesis_policy_version"
        case attemptID = "attempt_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            lineID: container.decode(UUID.self, forKey: .lineID),
            lineRevision: container.decode(Int.self, forKey: .lineRevision),
            profileID: container.decode(UUID.self, forKey: .profileID),
            profileRevision: container.decode(Int.self, forKey: .profileRevision),
            synthesisPolicyVersion: container.decodeIfPresent(Int.self, forKey: .synthesisPolicyVersion)
                ?? DialogueSynthesisPolicy.currentVersion,
            attemptID: container.decodeIfPresent(UUID.self, forKey: .attemptID) ?? UUID()
        )
    }
}

public struct DialogueVoicePlaybackSettings: Codable, Equatable, Sendable {
    public static let minimumRepeatIntervalSeconds: TimeInterval = 5
    public static let maximumRepeatIntervalSeconds: TimeInterval = 3_600
    public static let defaults = try! DialogueVoicePlaybackSettings()

    public let automaticPlaybackEnabled: Bool
    public let volume: Double
    public let repeatIntervalSeconds: TimeInterval?

    public init(
        automaticPlaybackEnabled: Bool = true,
        volume: Double = 1,
        repeatIntervalSeconds: TimeInterval? = nil
    ) throws {
        guard volume.isFinite, (0...1).contains(volume) else {
            throw DialogueVoiceError.invalidPlaybackSettings
        }
        if let repeatIntervalSeconds {
            guard repeatIntervalSeconds.isFinite,
                  (Self.minimumRepeatIntervalSeconds...Self.maximumRepeatIntervalSeconds)
                    .contains(repeatIntervalSeconds) else {
                throw DialogueVoiceError.invalidPlaybackSettings
            }
        }
        self.automaticPlaybackEnabled = automaticPlaybackEnabled
        self.volume = volume
        self.repeatIntervalSeconds = repeatIntervalSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case automaticPlaybackEnabled = "automatic_playback_enabled"
        case volume
        case repeatIntervalSeconds = "repeat_interval_seconds"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            automaticPlaybackEnabled: container.decode(Bool.self, forKey: .automaticPlaybackEnabled),
            volume: container.decode(Double.self, forKey: .volume),
            repeatIntervalSeconds: container.decodeIfPresent(TimeInterval.self, forKey: .repeatIntervalSeconds)
        )
    }
}

public struct DialogueVoiceLibrary: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public private(set) var version: Int
    public private(set) var activeProviderKind: DialogueVoiceProviderKind?
    public private(set) var profile: GPTSoVITSVoiceProfile?
    public private(set) var qwenProfile: Qwen3TTSVoiceProfile?
    public private(set) var voxcpm2Profile: VoxCPM2VoiceProfile?
    public private(set) var profileStatus: DialogueVoiceProfileStatus
    public private(set) var lines: [DialogueLine]
    public private(set) var pendingCleanupPaths: [String]
    public private(set) var playbackSettings: DialogueVoicePlaybackSettings

    public var referencedManagedPaths: Set<String> {
        Self.referencedPaths(profile: profile, qwenProfile: qwenProfile, voxcpm2Profile: voxcpm2Profile, lines: lines)
    }

    public var activeProfileID: UUID? {
        switch activeProviderKind {
        case .gptSovits: profile?.id
        case .qwen3TTS: qwenProfile?.id
        case .voxcpm2: voxcpm2Profile?.id
        case nil: nil
        }
    }

    public var activeProfileRevision: Int? {
        switch activeProviderKind {
        case .gptSovits: profile?.revision
        case .qwen3TTS: qwenProfile?.revision
        case .voxcpm2: voxcpm2Profile?.revision
        case nil: nil
        }
    }

    public var activeProfileInputFingerprint: String? {
        switch activeProviderKind {
        case .gptSovits: profile?.inputFingerprint
        case .qwen3TTS: qwenProfile?.inputFingerprint
        case .voxcpm2: voxcpm2Profile?.inputFingerprint
        case nil: nil
        }
    }

    public var activeProfileDefaultTextLanguage: String? {
        switch activeProviderKind {
        case .gptSovits: profile?.defaultTextLanguage
        case .qwen3TTS: qwenProfile?.defaultTextLanguage
        case .voxcpm2: voxcpm2Profile?.defaultTextLanguage
        case nil: nil
        }
    }

    public var profileID: UUID? { activeProfileID }
    public var profileRevision: Int? { activeProfileRevision }
    public var inputFingerprint: String? { activeProfileInputFingerprint }

    public init(
        version: Int = Self.schemaVersion,
        profile: GPTSoVITSVoiceProfile? = nil,
        qwenProfile: Qwen3TTSVoiceProfile? = nil,
        voxcpm2Profile: VoxCPM2VoiceProfile? = nil,
        activeProviderKind: DialogueVoiceProviderKind? = nil,
        profileStatus: DialogueVoiceProfileStatus? = nil,
        lines: [DialogueLine] = [],
        pendingCleanupPaths: [String] = [],
        playbackSettings: DialogueVoicePlaybackSettings = .defaults
    ) throws {
        guard version == Self.schemaVersion else {
            throw DialogueVoiceError.unsupportedSchemaVersion(version)
        }
        guard Set(lines.map(\.id)).count == lines.count else { throw DialogueVoiceError.invalidState }
        let validatedCleanupPaths = try pendingCleanupPaths.map(DialogueVoiceValidation.voiceCleanupPath)
        guard Set(validatedCleanupPaths).count == validatedCleanupPaths.count else {
            throw DialogueVoiceError.invalidState
        }
        guard Set(validatedCleanupPaths).isDisjoint(
            with: Self.referencedPaths(profile: profile, qwenProfile: qwenProfile, voxcpm2Profile: voxcpm2Profile, lines: lines)
        ) else {
            throw DialogueVoiceError.invalidState
        }
        self.version = version
        self.profile = profile
        self.qwenProfile = qwenProfile
        self.voxcpm2Profile = voxcpm2Profile
        self.activeProviderKind = activeProviderKind
            ?? (profile != nil ? .gptSovits : (qwenProfile != nil ? .qwen3TTS : (voxcpm2Profile != nil ? .voxcpm2 : nil)))
        self.profileStatus = profileStatus ?? (self.activeProviderKind == nil ? .notConfigured : .ready)
        self.lines = lines
        self.pendingCleanupPaths = validatedCleanupPaths
        self.playbackSettings = playbackSettings
        try validateProfileRelationships()
    }

    public mutating func updatePlaybackSettings(_ settings: DialogueVoicePlaybackSettings) {
        playbackSettings = settings
    }

    public mutating func replaceActiveProfile(_ profile: GPTSoVITSVoiceProfile) throws {
        var candidate = self
        candidate.profile = profile
        try candidate.selectActiveProvider(.gptSovits)
        self = candidate
    }

    public mutating func replaceActiveProfile(_ profile: Qwen3TTSVoiceProfile) throws {
        var candidate = self
        candidate.qwenProfile = profile
        try candidate.selectActiveProvider(.qwen3TTS)
        self = candidate
    }

    /// Stores a validated Qwen profile without changing the currently selected
    /// provider or invalidating outputs owned by that provider.
    public mutating func replaceConfiguredProfile(_ profile: Qwen3TTSVoiceProfile) throws {
        var candidate = self
        candidate.qwenProfile = profile
        try candidate.validateProfileRelationships()
        self = candidate
    }

    public mutating func replaceActiveProfile(_ profile: VoxCPM2VoiceProfile) throws {
        var candidate = self; candidate.voxcpm2Profile = profile
        try candidate.selectActiveProvider(.voxcpm2); self = candidate
    }

    public mutating func replaceConfiguredProfile(_ profile: VoxCPM2VoiceProfile) throws {
        var candidate = self; candidate.voxcpm2Profile = profile
        try candidate.validateProfileRelationships(); self = candidate
    }

    public mutating func selectActiveProvider(_ provider: DialogueVoiceProviderKind) throws {
        guard (provider == .gptSovits && profile != nil)
                || (provider == .qwen3TTS && qwenProfile != nil)
                || (provider == .voxcpm2 && voxcpm2Profile != nil) else {
            throw DialogueVoiceError.profileNotConfigured
        }
        let updatedLines = try lines.map { line in
            switch line.status {
            case .ready, .stale:
                return try DialogueLine(
                    id: line.id,
                    state: line.state,
                    text: line.text,
                    textLanguage: line.textLanguage,
                    revision: line.revision,
                    status: .stale,
                    generatedProfileRevision: line.generatedProfileRevision,
                    generatedSynthesisPolicyVersion: line.generatedSynthesisPolicyVersion,
                    outputRelativePath: line.outputRelativePath
                )
            case .generating, .queued, .failed:
                return try pendingLine(from: line, status: .queued)
            case .draft:
                return try pendingLine(from: line, status: .queued)
            }
        }
        guard Set(pendingCleanupPaths).isDisjoint(
            with: Self.referencedPaths(profile: profile, qwenProfile: qwenProfile, voxcpm2Profile: voxcpm2Profile, lines: updatedLines)
        ) else {
            throw DialogueVoiceError.invalidState
        }
        activeProviderKind = provider
        profileStatus = .ready
        lines = updatedLines
    }

    public mutating func setProfileStatus(
        _ status: DialogueVoiceProfileStatus,
        invalidatingOutputs: Bool = false
    ) throws {
        guard activeProfileID != nil, status != .notConfigured else {
            throw DialogueVoiceError.profileNotConfigured
        }
        guard invalidatingOutputs else {
            profileStatus = status
            return
        }
        let updatedLines = try lines.map { line in
            switch line.status {
            case .ready, .stale:
                return try DialogueLine(
                    id: line.id,
                    state: line.state,
                    text: line.text,
                    textLanguage: line.textLanguage,
                    revision: line.revision,
                    status: .stale,
                    generatedProfileRevision: line.generatedProfileRevision,
                    generatedSynthesisPolicyVersion: line.generatedSynthesisPolicyVersion,
                    outputRelativePath: line.outputRelativePath
                )
            case .failed:
                return line
            case .queued where line.outputRelativePath != nil,
                 .generating where line.outputRelativePath != nil:
                return try DialogueLine(
                    id: line.id,
                    state: line.state,
                    text: line.text,
                    textLanguage: line.textLanguage,
                    revision: line.revision,
                    status: .stale,
                    generatedProfileRevision: line.generatedProfileRevision,
                    generatedSynthesisPolicyVersion: line.generatedSynthesisPolicyVersion,
                    outputRelativePath: line.outputRelativePath
                )
            case .draft, .queued, .generating:
                return try pendingLine(from: line, status: .draft)
            }
        }
        profileStatus = status
        lines = updatedLines
    }

    @discardableResult
    public mutating func activateValidatedProfile() throws -> Int {
        guard activeProfileID != nil else { throw DialogueVoiceError.profileNotConfigured }
        var count = 0
        let updatedLines = try lines.map { line in
            switch line.status {
            case .draft:
                count += 1
                return try pendingLine(from: line, status: .queued)
            case .stale:
                count += 1
                if shouldRetainOutputForSynthesisMigration(line) {
                    return try pendingLineRetainingOutput(from: line, status: .queued)
                }
                return try pendingLine(from: line, status: .queued)
            case .queued, .generating, .ready, .failed:
                return line
            }
        }
        profileStatus = .ready
        lines = updatedLines
        return count
    }

    @discardableResult
    public mutating func addLine(
        text: String,
        language: String? = nil,
        state: PetState = .idle,
        id: UUID = UUID()
    ) throws -> DialogueLine {
        guard lines.count < DialogueVoiceValidation.maximumDialogueCount,
              !lines.contains(where: { $0.id == id }) else {
            throw DialogueVoiceError.invalidState
        }
        let resolvedLanguage = try language ?? activeProfileDefaultTextLanguage
            ?? { throw DialogueVoiceError.invalidLanguage }()
        let line = try DialogueLine(
            id: id,
            state: state,
            text: text,
            textLanguage: resolvedLanguage,
            status: activeProfileID != nil && profileStatus == .ready ? .queued : .draft
        )
        lines.append(line)
        return line
    }

    @discardableResult
    public mutating func editLine(
        id: UUID,
        text: String,
        language: String? = nil,
        state: PetState? = nil
    ) throws -> DialogueLine {
        let index = try lineIndex(id)
        let old = lines[index]
        let line = try DialogueLine(
            id: old.id,
            state: state ?? old.state,
            text: text,
            textLanguage: language ?? old.textLanguage,
            revision: old.revision + 1,
            status: activeProfileID != nil && profileStatus == .ready ? .queued : .draft
        )
        lines[index] = line
        return line
    }

    @discardableResult
    public mutating func retryLine(id: UUID) throws -> DialogueLine {
        guard activeProfileID != nil, profileStatus == .ready else {
            throw DialogueVoiceError.profileNotConfigured
        }
        let index = try lineIndex(id)
        guard lines[index].status == .failed || lines[index].status == .stale else {
            throw DialogueVoiceError.invalidState
        }
        let line = if lines[index].status == .stale,
                      shouldRetainOutputForSynthesisMigration(lines[index]) {
            try pendingLineRetainingOutput(from: lines[index], status: .queued)
        } else {
            try pendingLine(from: lines[index], status: .queued)
        }
        lines[index] = line
        return line
    }

    public mutating func beginGeneration(for id: UUID) throws -> DialogueGenerationTicket {
        guard let profileID = activeProfileID,
              let profileRevision = activeProfileRevision,
              profileStatus == .ready else {
            throw DialogueVoiceError.profileNotConfigured
        }
        let index = try lineIndex(id)
        guard lines[index].status == .queued else { throw DialogueVoiceError.invalidState }
        lines[index] = try pendingLineRetainingOutput(from: lines[index], status: .generating)
        return try DialogueGenerationTicket(
            lineID: id,
            lineRevision: lines[index].revision,
            profileID: profileID,
            profileRevision: profileRevision,
            synthesisPolicyVersion: DialogueSynthesisPolicy.currentVersion
        )
    }

    @discardableResult
    public mutating func completeGeneration(
        ticket: DialogueGenerationTicket,
        outputPath: String
    ) throws -> DialogueLine {
        let index = try matchingGenerationIndex(ticket)
        let old = lines[index]
        let line = try DialogueLine(
            id: old.id,
            state: old.state,
            text: old.text,
            textLanguage: old.textLanguage,
            revision: old.revision,
            status: .ready,
            generatedProfileRevision: ticket.profileRevision,
            generatedSynthesisPolicyVersion: ticket.synthesisPolicyVersion,
            outputRelativePath: outputPath
        )
        var updatedLines = lines
        updatedLines[index] = line
        guard Set(pendingCleanupPaths).isDisjoint(
            with: Self.referencedPaths(profile: profile, qwenProfile: qwenProfile, voxcpm2Profile: voxcpm2Profile, lines: updatedLines)
        ) else {
            throw DialogueVoiceError.invalidState
        }
        lines = updatedLines
        return line
    }

    @discardableResult
    public mutating func failGeneration(
        ticket: DialogueGenerationTicket,
        failureCode: String
    ) throws -> DialogueLine {
        let index = try matchingGenerationIndex(ticket)
        let old = lines[index]
        let line: DialogueLine
        if old.outputRelativePath != nil {
            line = try DialogueLine(
                id: old.id,
                state: old.state,
                text: old.text,
                textLanguage: old.textLanguage,
                revision: old.revision,
                status: .stale,
                generatedProfileRevision: old.generatedProfileRevision,
                generatedSynthesisPolicyVersion: old.generatedSynthesisPolicyVersion,
                outputRelativePath: old.outputRelativePath
            )
        } else {
            line = try DialogueLine(
                id: old.id,
                state: old.state,
                text: old.text,
                textLanguage: old.textLanguage,
                revision: old.revision,
                status: .failed,
                failureCode: failureCode
            )
        }
        lines[index] = line
        return line
    }

    @discardableResult
    public mutating func removeLine(id: UUID) throws -> DialogueLine {
        let index = try lineIndex(id)
        return lines.remove(at: index)
    }

    public mutating func enqueueCleanup(paths: [String]) throws {
        let validated = try paths.map(DialogueVoiceValidation.voiceCleanupPath)
        guard Set(validated).isDisjoint(with: referencedManagedPaths) else {
            throw DialogueVoiceError.invalidState
        }
        for path in validated
            where !pendingCleanupPaths.contains(path) {
            pendingCleanupPaths.append(path)
        }
    }

    public mutating func replacePendingCleanupPaths(_ paths: [String]) throws {
        let validated = try paths.map(DialogueVoiceValidation.voiceCleanupPath)
        guard Set(validated).count == validated.count,
              Set(validated).isDisjoint(with: referencedManagedPaths) else {
            throw DialogueVoiceError.invalidState
        }
        pendingCleanupPaths = validated
    }

    @discardableResult
    public mutating func recoverInterruptedGenerations() throws -> Int {
        var count = 0
        lines = try lines.map { line in
            guard line.status == .generating else { return line }
            count += 1
            if line.outputRelativePath != nil {
                return try pendingLineRetainingOutput(
                    from: line,
                    status: activeProfileID != nil && profileStatus == .ready ? .queued : .stale
                )
            }
            return try pendingLine(
                from: line,
                status: activeProfileID != nil && profileStatus == .ready ? .queued : .draft
            )
        }
        return count
    }

    /// Marks ready output from an older inference recipe for replacement while
    /// retaining the WAV as a cleanup-protected fallback until fresh generation
    /// succeeds.
    @discardableResult
    public mutating func migrateOutdatedSynthesisOutputs(
        to currentVersion: Int = DialogueSynthesisPolicy.currentVersion
    ) throws -> Int {
        guard currentVersion > 0 else { throw DialogueVoiceError.invalidState }
        var count = 0
        lines = try lines.map { line in
            guard line.status == .ready,
                  line.generatedSynthesisPolicyVersion != currentVersion else {
                return line
            }
            count += 1
            return try DialogueLine(
                id: line.id,
                state: line.state,
                text: line.text,
                textLanguage: line.textLanguage,
                revision: line.revision,
                status: .stale,
                generatedProfileRevision: line.generatedProfileRevision,
                generatedSynthesisPolicyVersion: line.generatedSynthesisPolicyVersion,
                outputRelativePath: line.outputRelativePath
            )
        }
        return count
    }

    public func outputURL(for id: UUID, relativeTo managedRoot: URL) throws -> URL {
        guard let line = lines.first(where: { $0.id == id }) else { throw DialogueVoiceError.lineNotFound }
        guard line.status == .ready,
              profileStatus == .ready || profileStatus == .unavailable,
              let outputPath = line.outputRelativePath else {
            throw DialogueVoiceError.outputNotReady
        }
        let path = try DialogueVoiceValidation.managedPath(outputPath)
        return managedRoot.appendingPathComponent(path, isDirectory: false).standardizedFileURL
    }

    /// Returns the deterministic presentation line for a lifecycle state without
    /// mutating generation or playback state. Ready audio is preferred so the
    /// displayed message can match the clip selected for automatic playback.
    public func preferredLine(for state: PetState) -> DialogueLine? {
        let matchingLines = lines.filter { $0.state == state }
        return matchingLines.first(where: { $0.status == .ready }) ?? matchingLines.first
    }

    private func lineIndex(_ id: UUID) throws -> Int {
        guard let index = lines.firstIndex(where: { $0.id == id }) else {
            throw DialogueVoiceError.lineNotFound
        }
        return index
    }

    private func matchingGenerationIndex(_ ticket: DialogueGenerationTicket) throws -> Int {
        guard let index = lines.firstIndex(where: { $0.id == ticket.lineID }),
              lines[index].revision == ticket.lineRevision,
              lines[index].status == .generating,
              profileStatus == .ready,
              activeProfileID == ticket.profileID,
              activeProfileRevision == ticket.profileRevision else {
            throw DialogueVoiceError.generationResultRejected
        }
        return index
    }

    private func pendingLine(from line: DialogueLine, status: DialogueGenerationStatus) throws -> DialogueLine {
        try DialogueLine(
            id: line.id,
            state: line.state,
            text: line.text,
            textLanguage: line.textLanguage,
            revision: line.revision,
            status: status
        )
    }

    private func pendingLineRetainingOutput(
        from line: DialogueLine,
        status: DialogueGenerationStatus
    ) throws -> DialogueLine {
        guard line.outputRelativePath != nil else {
            return try pendingLine(from: line, status: status)
        }
        return try DialogueLine(
            id: line.id,
            state: line.state,
            text: line.text,
            textLanguage: line.textLanguage,
            revision: line.revision,
            status: status,
            generatedProfileRevision: line.generatedProfileRevision,
            generatedSynthesisPolicyVersion: line.generatedSynthesisPolicyVersion,
            outputRelativePath: line.outputRelativePath
        )
    }

    private func shouldRetainOutputForSynthesisMigration(_ line: DialogueLine) -> Bool {
        guard let profileRevision = activeProfileRevision else { return false }
        return line.outputRelativePath != nil
            && line.generatedProfileRevision == profileRevision
            && line.generatedSynthesisPolicyVersion != DialogueSynthesisPolicy.currentVersion
    }

    private static func referencedPaths(
        profile: GPTSoVITSVoiceProfile?,
        qwenProfile: Qwen3TTSVoiceProfile?,
        voxcpm2Profile: VoxCPM2VoiceProfile?,
        lines: [DialogueLine]
    ) -> Set<String> {
        var paths = Set(lines.compactMap(\.outputRelativePath))
        if let profile {
            paths.insert(profile.gptWeightRelativePath)
            paths.insert(profile.sovitsWeightRelativePath)
            paths.insert(profile.referenceAudioRelativePath)
        }
        if let qwenProfile {
            paths.insert(qwenProfile.packageRootRelativePath)
        }
        if let voxcpm2Profile {
            paths.insert(voxcpm2Profile.snapshotPath)
            paths.insert(voxcpm2Profile.referenceAudioRelativePath)
        }
        return paths
    }

    private func validateProfileRelationships() throws {
        let configuredProfileCount = (profile == nil ? 0 : 1) + (qwenProfile == nil ? 0 : 1) + (voxcpm2Profile == nil ? 0 : 1)
        if configuredProfileCount == 0 {
            guard profileStatus == .notConfigured,
                  activeProviderKind == nil,
                  lines.allSatisfy({ $0.status == .draft }) else {
                throw DialogueVoiceError.invalidState
            }
            return
        }
        guard configuredProfileCount > 0,
              (activeProviderKind != .gptSovits || profile != nil),
              (activeProviderKind != .qwen3TTS || qwenProfile != nil),
              (activeProviderKind != .voxcpm2 || voxcpm2Profile != nil),
              activeProviderKind != nil else {
            throw DialogueVoiceError.invalidState
        }
        if let profile, let qwenProfile, profile.id == qwenProfile.id {
            throw DialogueVoiceError.invalidState
        }
        let ids = [profile?.id, qwenProfile?.id, voxcpm2Profile?.id].compactMap { $0 }
        guard Set(ids).count == ids.count else { throw DialogueVoiceError.invalidState }
        guard profileStatus != .notConfigured else { throw DialogueVoiceError.invalidState }
        for line in lines {
            if line.status == .ready,
               line.generatedProfileRevision != activeProfileRevision {
                throw DialogueVoiceError.invalidState
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case activeProviderKind = "active_provider"
        case profile
        case qwenProfile = "qwen_profile"
        case voxcpm2Profile = "voxcpm2_profile"
        case profileStatus = "profile_status"
        case lines
        case pendingCleanupPaths = "pending_cleanup_paths"
        case playbackSettings = "playback_settings"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let profile = try container.decodeIfPresent(GPTSoVITSVoiceProfile.self, forKey: .profile)
        let qwenProfile = try container.decodeIfPresent(Qwen3TTSVoiceProfile.self, forKey: .qwenProfile)
        let voxcpm2Profile = try container.decodeIfPresent(VoxCPM2VoiceProfile.self, forKey: .voxcpm2Profile)
        let activeProviderKind = try container.decodeIfPresent(
            DialogueVoiceProviderKind.self,
            forKey: .activeProviderKind
        )
            ?? (profile == nil ? (qwenProfile == nil ? (voxcpm2Profile == nil ? nil : .voxcpm2) : .qwen3TTS) : .gptSovits)
        try self.init(
            version: container.decode(Int.self, forKey: .version),
            profile: profile,
            qwenProfile: qwenProfile,
            voxcpm2Profile: voxcpm2Profile,
            activeProviderKind: activeProviderKind,
            profileStatus: container.decodeIfPresent(DialogueVoiceProfileStatus.self, forKey: .profileStatus)
                ?? (activeProviderKind == nil ? .notConfigured : .ready),
            lines: container.decode([DialogueLine].self, forKey: .lines),
            pendingCleanupPaths: container.decodeIfPresent([String].self, forKey: .pendingCleanupPaths) ?? [],
            playbackSettings: container.decodeIfPresent(
                DialogueVoicePlaybackSettings.self,
                forKey: .playbackSettings
            ) ?? .defaults
        )
    }
}

public struct DialogueVoiceStore: Sendable {
    public static let fileName = "dialogue-voice.json"
    private static let maximumFileSize = 8 * 1_024 * 1_024

    public let rootURL: URL
    private let beforeCommit: (@Sendable () throws -> Void)?

    public init(rootURL: URL) {
        self.rootURL = rootURL
        self.beforeCommit = nil
    }

    init(rootURL: URL, beforeCommit: (@Sendable () throws -> Void)?) {
        self.rootURL = rootURL
        self.beforeCommit = beforeCommit
    }

    public var fileURL: URL { rootURL.appendingPathComponent(Self.fileName, isDirectory: false) }

    public func load() throws -> DialogueVoiceLibrary {
        do {
            let rootDescriptor = try openValidatedRoot(createIfMissing: false)
            defer { close(rootDescriptor) }
            let fileDescriptor = Self.openFile(at: rootDescriptor, flags: O_RDONLY | O_NOFOLLOW)
            guard fileDescriptor >= 0 else { throw DialogueVoiceError.storeFailure }
            defer { close(fileDescriptor) }

            var information = stat()
            guard fstat(fileDescriptor, &information) == 0,
                  Self.isRegularFile(information),
                  information.st_size >= 0,
                  information.st_size <= Self.maximumFileSize else {
                throw DialogueVoiceError.storeFailure
            }
            let data = try Self.readBounded(from: fileDescriptor)
            return try JSONDecoder().decode(DialogueVoiceLibrary.self, from: data)
        } catch let error as DialogueVoiceError {
            throw error
        } catch {
            throw DialogueVoiceError.storeFailure
        }
    }

    public func save(_ library: DialogueVoiceLibrary) throws {
        do {
            let rootDescriptor = try openValidatedRoot(createIfMissing: true)
            defer { close(rootDescriptor) }
            try Self.validateExistingDestination(at: rootDescriptor)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(library)
            guard data.count <= Self.maximumFileSize else { throw DialogueVoiceError.storeFailure }
            let temporaryName = ".dialogue-voice-\(UUID().uuidString).tmp"
            let temporaryDescriptor = Self.openFile(
                at: rootDescriptor,
                name: temporaryName,
                flags: O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                mode: 0o600
            )
            guard temporaryDescriptor >= 0 else { throw DialogueVoiceError.storeFailure }
            var published = false
            defer {
                close(temporaryDescriptor)
                if !published { Self.unlinkFile(at: rootDescriptor, name: temporaryName) }
            }
            guard fchmod(temporaryDescriptor, 0o600) == 0 else { throw DialogueVoiceError.storeFailure }
            try Self.writeAll(data, to: temporaryDescriptor)
            guard fsync(temporaryDescriptor) == 0 else { throw DialogueVoiceError.storeFailure }
            try beforeCommit?()
            guard Self.renameFile(
                at: rootDescriptor,
                from: temporaryName,
                to: Self.fileName
            ) == 0 else {
                throw DialogueVoiceError.storeFailure
            }
            published = true
            guard fsync(rootDescriptor) == 0 else { throw DialogueVoiceError.storeFailure }
        } catch {
            throw DialogueVoiceError.storeFailure
        }
    }

    private func openValidatedRoot(createIfMissing: Bool) throws -> Int32 {
        guard rootURL.isFileURL else { throw DialogueVoiceError.storeFailure }
        var information = stat()
        if lstat(rootURL.path, &information) != 0 {
            guard createIfMissing, errno == ENOENT else { throw DialogueVoiceError.storeFailure }
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard lstat(rootURL.path, &information) == 0 else { throw DialogueVoiceError.storeFailure }
        }
        guard Self.isDirectory(information), !Self.isSymbolicLink(information) else {
            throw DialogueVoiceError.storeFailure
        }
        let descriptor = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw DialogueVoiceError.storeFailure }
        if createIfMissing, fchmod(descriptor, 0o700) != 0 {
            close(descriptor)
            throw DialogueVoiceError.storeFailure
        }
        return descriptor
    }

    private static func validateExistingDestination(at rootDescriptor: Int32) throws {
        var information = stat()
        let result = fileName.withCString {
            fstatat(rootDescriptor, $0, &information, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            guard errno == ENOENT else { throw DialogueVoiceError.storeFailure }
            return
        }
        guard isRegularFile(information), !isSymbolicLink(information) else {
            throw DialogueVoiceError.storeFailure
        }
    }

    private static func readBounded(from descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return data }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw DialogueVoiceError.storeFailure
            }
            guard data.count + count <= maximumFileSize else {
                throw DialogueVoiceError.storeFailure
            }
            data.append(buffer, count: count)
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var address = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, address, remaining)
                guard count > 0 else {
                    if count < 0, errno == EINTR { continue }
                    throw DialogueVoiceError.storeFailure
                }
                address = address.advanced(by: count)
                remaining -= count
            }
        }
    }

    private static func openFile(
        at rootDescriptor: Int32,
        name: String = fileName,
        flags: Int32,
        mode: mode_t = 0
    ) -> Int32 {
        name.withCString { openat(rootDescriptor, $0, flags, mode) }
    }

    private static func renameFile(
        at rootDescriptor: Int32,
        from source: String,
        to destination: String
    ) -> Int32 {
        source.withCString { sourcePath in
            destination.withCString { destinationPath in
                renameat(rootDescriptor, sourcePath, rootDescriptor, destinationPath)
            }
        }
    }

    private static func unlinkFile(at rootDescriptor: Int32, name: String) {
        _ = name.withCString { unlinkat(rootDescriptor, $0, 0) }
    }

    private static func isDirectory(_ information: stat) -> Bool {
        information.st_mode & S_IFMT == S_IFDIR
    }

    private static func isRegularFile(_ information: stat) -> Bool {
        information.st_mode & S_IFMT == S_IFREG
    }

    private static func isSymbolicLink(_ information: stat) -> Bool {
        information.st_mode & S_IFMT == S_IFLNK
    }
}
