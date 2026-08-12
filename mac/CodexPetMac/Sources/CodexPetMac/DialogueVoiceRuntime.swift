@preconcurrency import AVFoundation
import CodexPetCore
import CryptoKit
import Darwin
import Foundation
import os

enum DialogueVoiceAssetKind: String, Sendable {
    case gptWeight = "gpt"
    case sovitsWeight = "sovits"
    case referenceAudio = "reference"

    var allowedExtensions: Set<String> {
        switch self {
        case .gptWeight: return ["ckpt"]
        case .sovitsWeight: return ["pth"]
        case .referenceAudio: return ["wav", "flac", "mp3", "m4a", "aac", "ogg"]
        }
    }

    var maximumBytes: UInt64 {
        switch self {
        case .gptWeight, .sovitsWeight: return 4_294_967_296
        case .referenceAudio: return 67_108_864
        }
    }
}

enum DialogueVoiceRuntimeError: LocalizedError, Sendable, Equatable {
    case invalidSource
    case unsupportedFileType
    case sourceTooLarge
    case sourceChanged
    case copyFailed
    case invalidManagedPath
    case inferenceUnavailable
    case profileRejected
    case requestRejected
    case inputFingerprintMismatch
    case invalidReferenceAudio
    case invalidAudio
    case responseTooLarge
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidSource:
            return "Choose a regular local file that is not a symbolic link."
        case .unsupportedFileType:
            return "The selected file type is not supported for this voice asset."
        case .sourceTooLarge:
            return "The selected voice asset exceeds Statelet’s safe import limit."
        case .sourceChanged:
            return "The selected voice asset changed while it was being imported."
        case .copyFailed:
            return "Statelet could not copy the voice asset into private local storage."
        case .invalidManagedPath:
            return "A managed voice asset is missing or no longer trusted."
        case .inferenceUnavailable:
            return "The local GPT-SoVITS service is unavailable. Start API v2 and retry."
        case .profileRejected:
            return "GPT-SoVITS rejected the selected model or reference profile."
        case .requestRejected:
            return "GPT-SoVITS rejected this dialogue or language request."
        case .inputFingerprintMismatch:
            return "The managed voice inputs changed after validation. Save the profile again."
        case .invalidReferenceAudio:
            return "Choose reference audio that macOS can decode and that is no longer than 60 seconds."
        case .invalidAudio:
            return "GPT-SoVITS did not return a valid WAV file."
        case .responseTooLarge:
            return "GPT-SoVITS returned audio that exceeds Statelet’s safe limit."
        case .cancelled:
            return "Voice generation was cancelled."
        }
    }

    var safeCode: String {
        switch self {
        case .invalidSource: return "INVALID_SOURCE"
        case .unsupportedFileType: return "UNSUPPORTED_FILE_TYPE"
        case .sourceTooLarge: return "SOURCE_TOO_LARGE"
        case .sourceChanged: return "SOURCE_CHANGED"
        case .copyFailed: return "COPY_FAILED"
        case .invalidManagedPath: return "INVALID_MANAGED_PATH"
        case .inferenceUnavailable: return "INFERENCE_UNAVAILABLE"
        case .profileRejected: return "PROFILE_REJECTED"
        case .requestRejected: return "REQUEST_REJECTED"
        case .inputFingerprintMismatch: return "INPUT_FINGERPRINT_MISMATCH"
        case .invalidReferenceAudio: return "INVALID_REFERENCE_AUDIO"
        case .invalidAudio: return "INVALID_AUDIO"
        case .responseTooLarge: return "RESPONSE_TOO_LARGE"
        case .cancelled: return "CANCELLED"
        }
    }
}

struct Qwen3TTSValidatedPackage: Equatable, Sendable {
    let packageRoot: URL
    let pythonExecutable: URL
    let modelFile: URL
    let configFile: URL
    let generatorFile: URL
    let referenceAudioFile: URL
    let identityTokens: [String]
    let treeSHA256: String
}

struct Qwen3TTSPythonRuntimeIdentity: Equatable, Sendable {
    let invocationPath: String
    let finalTargetSHA256: String
    let stableIdentityToken: String
}

struct Qwen3TTSImportedPackage: Sendable {
    let packageRootRelativePath: String
    let manifest: Qwen3TTSPackageManifest
    let treeSHA256: String
    let referenceText: String
    let referenceLanguage: String
    let parameters: Qwen3TTSSynthesisParameters
}

enum Qwen3TTSLanguage {
    static let japanese = "japanese"

    static func canonicalJapanese(_ value: String) -> String? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        switch normalized {
        case japanese, "ja", "ja-jp":
            return japanese
        default:
            return nil
        }
    }

    static func areJapaneseAliases(_ lhs: String, _ rhs: String) -> Bool {
        canonicalJapanese(lhs) != nil && canonicalJapanese(rhs) != nil
    }
}

struct Qwen3TTSPackageInstaller: Sendable {
    private struct SourceFile {
        let relativePath: String
        let url: URL
        let identity: DialogueVoiceFileIdentity
        let size: UInt64
    }

    private struct HandoverConfig: Decodable {
        struct Generation: Decodable {
            let temperature: Double
            let topK: Int
            let topP: Double
            let repetitionPenalty: Double
            let maxTokens: Int
            let seed: Int
            enum CodingKeys: String, CodingKey {
                case temperature, seed
                case topK = "top_k"
                case topP = "top_p"
                case repetitionPenalty = "repetition_penalty"
                case maxTokens = "max_tokens"
            }
        }
        let modelPath: String
        let referenceAudio: String
        let referenceText: String
        let language: String
        let generation: Generation
        enum CodingKeys: String, CodingKey {
            case modelPath = "model_path"
            case referenceAudio = "reference_audio"
            case referenceText = "reference_text"
            case language, generation
        }
    }

    static let maximumPackageBytes: UInt64 = 4_294_967_296
    let applicationSupportRoot: URL

    func install(sourceURL: URL) throws -> Qwen3TTSImportedPackage {
        try Task.checkCancellation()
        guard sourceURL.isFileURL else { throw DialogueVoiceRuntimeError.invalidSource }
        var rootStatus = stat()
        guard Darwin.lstat(sourceURL.path, &rootStatus) == 0,
              rootStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw DialogueVoiceRuntimeError.invalidSource
        }
        let rootIdentity = DialogueVoiceFileIdentity(rootStatus)
        let files = try enumerate(sourceURL)
        let total = files.reduce(UInt64(0)) { $0 + $1.size }
        guard total > 0, total <= Self.maximumPackageBytes else {
            throw DialogueVoiceRuntimeError.sourceTooLarge
        }
        let required = ["model/model.safetensors", "config.json", "generate.py"]
        guard required.allSatisfy({ name in files.contains(where: { $0.relativePath == name }) }) else {
            throw DialogueVoiceRuntimeError.invalidSource
        }
        let configData = try boundedRead(sourceURL.appendingPathComponent("config.json"), maximum: 1_048_576)
        let config = try JSONDecoder().decode(HandoverConfig.self, from: configData)
        guard config.modelPath == "model",
              config.referenceAudio.hasPrefix("reference/"),
              files.contains(where: { $0.relativePath == config.referenceAudio }),
              Qwen3TTSLanguage.canonicalJapanese(config.language) != nil else {
            throw DialogueVoiceRuntimeError.profileRejected
        }
        let parameters = try Qwen3TTSSynthesisParameters(
            temperature: config.generation.temperature,
            topK: config.generation.topK,
            topP: config.generation.topP,
            repetitionPenalty: config.generation.repetitionPenalty,
            maximumTokens: config.generation.maxTokens,
            seed: config.generation.seed
        )
        let available = try applicationSupportRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? 0
        guard available > Int64(total + 268_435_456) else {
            throw DialogueVoiceRuntimeError.sourceTooLarge
        }

        let packagesRoot = applicationSupportRoot.appendingPathComponent("voice/packages/qwen", isDirectory: true)
        try DialogueVoiceAssetInstaller.ensurePrivateDirectory(packagesRoot)
        let token = UUID().uuidString.lowercased()
        let stage = packagesRoot.appendingPathComponent(".\(token).partial", isDirectory: true)
        let destination = packagesRoot.appendingPathComponent(token, isDirectory: true)
        try DialogueVoiceAssetInstaller.ensurePrivateDirectory(stage)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: stage) } }

        for file in files {
            try Task.checkCancellation()
            let target = stage.appendingPathComponent(file.relativePath)
            try DialogueVoiceAssetInstaller.ensurePrivateDirectory(target.deletingLastPathComponent())
            try copyRegularFile(file, to: target)
        }
        var finalRootStatus = stat()
        guard Darwin.lstat(sourceURL.path, &finalRootStatus) == 0,
              DialogueVoiceFileIdentity(finalRootStatus) == rootIdentity else {
            throw DialogueVoiceRuntimeError.sourceChanged
        }
        let model = stage.appendingPathComponent("model/model.safetensors")
        let generator = stage.appendingPathComponent("generate.py")
        let reference = stage.appendingPathComponent(config.referenceAudio)
        let manifest = try Qwen3TTSPackageManifest(
            modelRelativePath: "model/model.safetensors",
            configRelativePath: "config.json",
            handoverGeneratorRelativePath: "generate.py",
            referenceAudioRelativePath: config.referenceAudio,
            modelSHA256: digest(model),
            configSHA256: digest(stage.appendingPathComponent("config.json")),
            handoverGeneratorSHA256: digest(generator),
            referenceAudioSHA256: digest(reference)
        )
        let treeDigest = try Qwen3TTSProfileValidator.computePackageTreeSHA256(packageRoot: stage)
        try FileManager.default.moveItem(at: stage, to: destination)
        published = true
        return Qwen3TTSImportedPackage(
            packageRootRelativePath: "voice/packages/qwen/\(token)", manifest: manifest,
            treeSHA256: treeDigest, referenceText: config.referenceText,
            referenceLanguage: Qwen3TTSLanguage.japanese, parameters: parameters
        )
    }

    func removeManagedPackage(relativePath: String) throws {
        guard relativePath.hasPrefix("voice/packages/qwen/"),
              relativePath.split(separator: "/").count == 4 else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        _ = try DialogueVoiceAssetInstaller.removeManagedDirectory(
            relativePath: relativePath,
            root: applicationSupportRoot,
            maximumBytes: Self.maximumPackageBytes
        )
    }

    private func enumerate(_ root: URL) throws -> [SourceFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsPackageDescendants]
        ) else { throw DialogueVoiceRuntimeError.invalidSource }
        var result: [SourceFile] = []
        while let url = enumerator.nextObject() as? URL {
            var status = stat()
            guard Darwin.lstat(url.path, &status) == 0 else { throw DialogueVoiceRuntimeError.invalidSource }
            let kind = status.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFDIR) { continue }
            guard kind == mode_t(S_IFREG), status.st_size > 0 else {
                throw DialogueVoiceRuntimeError.invalidSource
            }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            result.append(SourceFile(relativePath: relative, url: url,
                                     identity: DialogueVoiceFileIdentity(status), size: UInt64(status.st_size)))
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    private func copyRegularFile(_ source: SourceFile, to target: URL) throws {
        try FileManager.default.copyItem(at: source.url, to: target)
        guard chmod(target.path, 0o600) == 0 else { throw DialogueVoiceRuntimeError.copyFailed }
        var sourceStatus = stat(), targetStatus = stat()
        guard Darwin.lstat(source.url.path, &sourceStatus) == 0,
              DialogueVoiceFileIdentity(sourceStatus) == source.identity,
              Darwin.lstat(target.path, &targetStatus) == 0,
              targetStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              UInt64(targetStatus.st_size) == source.size,
              digest(source.url) == digest(target) else { throw DialogueVoiceRuntimeError.sourceChanged }
    }

    private func boundedRead(_ url: URL, maximum: Int) throws -> Data {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard !data.isEmpty, data.count <= maximum else { throw DialogueVoiceRuntimeError.invalidSource }
        return data
    }

    private func digest(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

}

enum Qwen3TTSProfileValidator {
    private static let maximumModelBytes: UInt64 = 4_294_967_296
    private static let maximumMetadataBytes: UInt64 = 1_048_576

    static func validate(
        profile: Qwen3TTSVoiceProfile,
        applicationSupportRoot: URL
    ) throws -> Qwen3TTSValidatedPackage {
        let packageRoot = applicationSupportRoot
            .appendingPathComponent(profile.packageRootRelativePath, isDirectory: true)
            .standardizedFileURL
        var packageStatus = stat()
        guard Darwin.lstat(packageRoot.path, &packageStatus) == 0,
              packageStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        let paths = [
            profile.manifest.modelRelativePath,
            profile.manifest.configRelativePath,
            profile.manifest.handoverGeneratorRelativePath,
            profile.manifest.referenceAudioRelativePath,
        ]
        let relativePaths = paths.map { profile.packageRootRelativePath + "/" + $0 }
        let maximums = [maximumModelBytes, maximumMetadataBytes, maximumMetadataBytes,
                        DialogueVoiceAssetKind.referenceAudio.maximumBytes]
        let expected = [profile.manifest.modelSHA256, profile.manifest.configSHA256,
                        profile.manifest.handoverGeneratorSHA256, profile.manifest.referenceAudioSHA256]
        var identitiesBefore: [String] = []
        for index in relativePaths.indices {
            identitiesBefore.append(try DialogueVoiceAssetInstaller.managedFileIdentity(
                relativePath: relativePaths[index], root: applicationSupportRoot,
                maximumBytes: maximums[index]
            ))
        }
        for index in relativePaths.indices {
            let digest = try DialogueVoiceAssetInstaller.sha256ManagedFile(
                relativePath: relativePaths[index], root: applicationSupportRoot,
                maximumBytes: maximums[index]
            )
            guard digest == expected[index] else {
                throw DialogueVoiceRuntimeError.inputFingerprintMismatch
            }
        }
        var identitiesAfter: [String] = []
        for index in relativePaths.indices {
            identitiesAfter.append(try DialogueVoiceAssetInstaller.managedFileIdentity(
                relativePath: relativePaths[index], root: applicationSupportRoot,
                maximumBytes: maximums[index]
            ))
        }
        guard identitiesBefore == identitiesAfter else { throw DialogueVoiceRuntimeError.sourceChanged }
        let packageTreeSHA256 = try computePackageTreeSHA256(packageRoot: packageRoot)
        guard packageTreeSHA256 == profile.packageTreeSHA256 else {
            throw DialogueVoiceRuntimeError.inputFingerprintMismatch
        }
        let python = URL(fileURLWithPath: profile.pythonExecutablePath).standardizedFileURL
        let runtimeBefore = try validatePythonExecutable(at: python)
        guard runtimeBefore.finalTargetSHA256 == profile.pythonExecutableSHA256 else {
            throw DialogueVoiceRuntimeError.inputFingerprintMismatch
        }
        let runtimeAfter = try validatePythonExecutable(at: python)
        guard runtimeBefore == runtimeAfter else { throw DialogueVoiceRuntimeError.sourceChanged }
        guard computeInputFingerprint(components: profile.inputFingerprintComponents) == profile.inputFingerprint else {
            throw DialogueVoiceRuntimeError.inputFingerprintMismatch
        }
        let packageIdentities = try packageIdentityTokens(packageRoot: packageRoot)
        return Qwen3TTSValidatedPackage(
            packageRoot: packageRoot,
            pythonExecutable: python,
            modelFile: applicationSupportRoot.appendingPathComponent(relativePaths[0]),
            configFile: applicationSupportRoot.appendingPathComponent(relativePaths[1]),
            generatorFile: applicationSupportRoot.appendingPathComponent(relativePaths[2]),
            referenceAudioFile: applicationSupportRoot.appendingPathComponent(relativePaths[3]),
            identityTokens: packageIdentities + [runtimeAfter.stableIdentityToken],
            treeSHA256: packageTreeSHA256
        )
    }

    static func snapshot(
        profile: Qwen3TTSVoiceProfile,
        applicationSupportRoot: URL
    ) throws -> Qwen3TTSValidatedPackage {
        let packageRoot = applicationSupportRoot
            .appendingPathComponent(profile.packageRootRelativePath, isDirectory: true)
            .standardizedFileURL
        let relativePaths = [
            profile.manifest.modelRelativePath,
            profile.manifest.configRelativePath,
            profile.manifest.handoverGeneratorRelativePath,
            profile.manifest.referenceAudioRelativePath,
        ].map { profile.packageRootRelativePath + "/" + $0 }
        let maximums = [
            UInt64(4_294_967_296),
            UInt64(1_048_576),
            UInt64(1_048_576),
            DialogueVoiceAssetKind.referenceAudio.maximumBytes,
        ]
        for index in relativePaths.indices {
            _ = try DialogueVoiceAssetInstaller.managedFileIdentity(
                relativePath: relativePaths[index],
                root: applicationSupportRoot,
                maximumBytes: maximums[index]
            )
        }
        let runtime = try validatePythonExecutable(
            at: URL(fileURLWithPath: profile.pythonExecutablePath)
        )
        guard runtime.finalTargetSHA256 == profile.pythonExecutableSHA256,
              computeInputFingerprint(components: profile.inputFingerprintComponents)
                == profile.inputFingerprint else {
            throw DialogueVoiceRuntimeError.inputFingerprintMismatch
        }
        let packageIdentities = try packageIdentityTokens(packageRoot: packageRoot)
        return Qwen3TTSValidatedPackage(
            packageRoot: packageRoot,
            pythonExecutable: URL(fileURLWithPath: runtime.invocationPath),
            modelFile: applicationSupportRoot.appendingPathComponent(relativePaths[0]),
            configFile: applicationSupportRoot.appendingPathComponent(relativePaths[1]),
            generatorFile: applicationSupportRoot.appendingPathComponent(relativePaths[2]),
            referenceAudioFile: applicationSupportRoot.appendingPathComponent(relativePaths[3]),
            identityTokens: packageIdentities + [runtime.stableIdentityToken],
            treeSHA256: profile.packageTreeSHA256
        )
    }

    static func validatePythonExecutable(at url: URL) throws -> Qwen3TTSPythonRuntimeIdentity {
        guard url.isFileURL,
              url.host.map({ $0.isEmpty || $0 == "localhost" }) ?? true else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        let invocation = url.standardizedFileURL
        guard invocation.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: invocation.path) else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        let launcher = try pythonLauncherIdentity(invocation)
        let digest = try sha256RegularFile(launcher.target, maximumBytes: 1_073_741_824)
        return Qwen3TTSPythonRuntimeIdentity(
            invocationPath: invocation.path,
            finalTargetSHA256: digest,
            stableIdentityToken: launcher.token
        )
    }

    static func computeInputFingerprint(components: [String]) -> String {
        var hasher = SHA256()
        for field in components {
            var length = UInt64(field.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
            hasher.update(data: Data(field.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct PythonLauncherIdentity: Equatable {
        let launcher: DialogueVoiceFileIdentity
        let target: URL
        let targetIdentity: DialogueVoiceFileIdentity
        var token: String { launcher.token + ":" + target.path + ":" + targetIdentity.token }
    }

    private static func pythonLauncherIdentity(_ url: URL) throws -> PythonLauncherIdentity {
        var launcherStatus = stat()
        guard Darwin.lstat(url.path, &launcherStatus) == 0 else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        let kind = launcherStatus.st_mode & mode_t(S_IFMT)
        let target: URL
        if kind == mode_t(S_IFREG) {
            target = url
        } else if kind == mode_t(S_IFLNK) {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let length = Darwin.readlink(url.path, &buffer, Int(PATH_MAX))
            guard length > 0 else { throw DialogueVoiceRuntimeError.inferenceUnavailable }
            let raw = String(decoding: buffer.prefix(length).map(UInt8.init(bitPattern:)), as: UTF8.self)
            guard raw.hasPrefix("/"), !raw.contains("/../"), !raw.hasSuffix("/..") else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
            target = URL(fileURLWithPath: raw).standardizedFileURL
            guard target.path == raw else { throw DialogueVoiceRuntimeError.inferenceUnavailable }
        } else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        var targetStatus = stat()
        guard Darwin.lstat(target.path, &targetStatus) == 0,
              targetStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              targetStatus.st_size > 0 else { throw DialogueVoiceRuntimeError.inferenceUnavailable }
        return PythonLauncherIdentity(
            launcher: DialogueVoiceFileIdentity(launcherStatus), target: target,
            targetIdentity: DialogueVoiceFileIdentity(targetStatus)
        )
    }

    static func computePackageTreeSHA256(packageRoot: URL) throws -> String {
        var rootStatus = stat()
        guard Darwin.lstat(packageRoot.path, &rootStatus) == 0,
              rootStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              let enumerator = FileManager.default.enumerator(
                at: packageRoot, includingPropertiesForKeys: nil,
                options: [.skipsPackageDescendants]
              ) else { throw DialogueVoiceRuntimeError.invalidManagedPath }
        var entries: [(String, URL, UInt64)] = []
        var total: UInt64 = 0
        while let url = enumerator.nextObject() as? URL {
            var status = stat()
            guard Darwin.lstat(url.path, &status) == 0 else {
                throw DialogueVoiceRuntimeError.invalidManagedPath
            }
            let kind = status.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFDIR) { continue }
            guard kind == mode_t(S_IFREG), status.st_size > 0 else {
                throw DialogueVoiceRuntimeError.invalidManagedPath
            }
            let size = UInt64(status.st_size)
            total += size
            guard total <= Qwen3TTSPackageInstaller.maximumPackageBytes else {
                throw DialogueVoiceRuntimeError.invalidManagedPath
            }
            let relative = String(url.path.dropFirst(packageRoot.path.count + 1))
            entries.append((relative, url, size))
        }
        var hasher = SHA256()
        for entry in entries.sorted(by: { $0.0 < $1.0 }) {
            let digest = try sha256RegularFile(entry.1, maximumBytes: entry.2)
            for field in [entry.0, digest] {
                var length = UInt64(field.utf8.count).bigEndian
                withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
                hasher.update(data: Data(field.utf8))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func packageIdentityTokens(packageRoot: URL) throws -> [String] {
        var rootStatus = stat()
        guard Darwin.lstat(packageRoot.path, &rootStatus) == 0,
              rootStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              let enumerator = FileManager.default.enumerator(
                at: packageRoot, includingPropertiesForKeys: nil,
                options: [.skipsPackageDescendants]
              ) else { throw DialogueVoiceRuntimeError.invalidManagedPath }
        var tokens = ["root:\(DialogueVoiceFileIdentity(rootStatus).token)"]
        var total: UInt64 = 0
        while let url = enumerator.nextObject() as? URL {
            var status = stat()
            guard Darwin.lstat(url.path, &status) == 0 else {
                throw DialogueVoiceRuntimeError.invalidManagedPath
            }
            let kind = status.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFDIR) { continue }
            guard kind == mode_t(S_IFREG), status.st_size > 0 else {
                throw DialogueVoiceRuntimeError.invalidManagedPath
            }
            total += UInt64(status.st_size)
            guard total <= Qwen3TTSPackageInstaller.maximumPackageBytes else {
                throw DialogueVoiceRuntimeError.invalidManagedPath
            }
            let relative = String(url.path.dropFirst(packageRoot.path.count + 1))
            tokens.append("\(relative):\(DialogueVoiceFileIdentity(status).token)")
        }
        return tokens.sorted()
    }

    private static func sha256RegularFile(_ url: URL, maximumBytes: UInt64) throws -> String {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DialogueVoiceRuntimeError.inferenceUnavailable }
        defer { Darwin.close(descriptor) }
        var initial = stat()
        guard Darwin.fstat(descriptor, &initial) == 0,
              initial.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              initial.st_size > 0, UInt64(initial.st_size) <= maximumBytes else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        let identity = DialogueVoiceFileIdentity(initial)
        var hasher = SHA256()
        var count: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let readCount = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if readCount == 0 { break }
            guard readCount > 0 else {
                if errno == EINTR { continue }
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
            count += UInt64(readCount)
            guard count <= maximumBytes else { throw DialogueVoiceRuntimeError.inferenceUnavailable }
            hasher.update(data: Data(buffer.prefix(readCount)))
        }
        var final = stat()
        guard Darwin.fstat(descriptor, &final) == 0,
              DialogueVoiceFileIdentity(final) == identity else { throw DialogueVoiceRuntimeError.sourceChanged }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct DialogueVoiceInstalledAsset: Sendable {
    let relativePath: String
    let contentDigest: String
}

struct DialogueVoiceAssetDigests: Equatable, Sendable {
    let gptWeight: String
    let sovitsWeight: String
    let referenceAudio: String
}

struct DialogueVoiceAssetIdentities: Equatable, Sendable {
    let gptWeight: String
    let sovitsWeight: String
    let referenceAudio: String
}

struct DialogueVoiceValidatedAssets: Equatable, Sendable {
    let digests: DialogueVoiceAssetDigests
    let identities: DialogueVoiceAssetIdentities
}

enum DialogueVoiceProfileFingerprint {
    static func compute(
        apiBaseURL: URL,
        referenceText: String,
        promptLanguage: String,
        defaultTextLanguage: String,
        assetDigests: DialogueVoiceAssetDigests
    ) -> String {
        var hasher = SHA256()
        for field in [
            "statelet-gpt-sovits-api-v2-pcm-wav-v1",
            apiBaseURL.absoluteString,
            assetDigests.gptWeight,
            assetDigests.sovitsWeight,
            assetDigests.referenceAudio,
            referenceText,
            promptLanguage.lowercased(),
            defaultTextLanguage.lowercased(),
        ] {
            var length = UInt64(field.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
            hasher.update(data: Data(field.utf8))
        }
        return hex(hasher.finalize())
    }

    static func validateAssets(
        profile: GPTSoVITSVoiceProfile,
        applicationSupportRoot: URL
    ) throws -> DialogueVoiceValidatedAssets {
        let identitiesBefore = try assetIdentities(
            profile: profile,
            applicationSupportRoot: applicationSupportRoot
        )
        try DialogueVoiceAssetInstaller.validateReferenceAudio(
            relativePath: profile.referenceAudioRelativePath,
            root: applicationSupportRoot
        )
        let digests = try DialogueVoiceAssetDigests(
            gptWeight: DialogueVoiceAssetInstaller.sha256ManagedFile(
                relativePath: profile.gptWeightRelativePath,
                root: applicationSupportRoot,
                maximumBytes: DialogueVoiceAssetKind.gptWeight.maximumBytes
            ),
            sovitsWeight: DialogueVoiceAssetInstaller.sha256ManagedFile(
                relativePath: profile.sovitsWeightRelativePath,
                root: applicationSupportRoot,
                maximumBytes: DialogueVoiceAssetKind.sovitsWeight.maximumBytes
            ),
            referenceAudio: DialogueVoiceAssetInstaller.sha256ManagedFile(
                relativePath: profile.referenceAudioRelativePath,
                root: applicationSupportRoot,
                maximumBytes: DialogueVoiceAssetKind.referenceAudio.maximumBytes
            )
        )
        let identitiesAfter = try assetIdentities(
            profile: profile,
            applicationSupportRoot: applicationSupportRoot
        )
        guard identitiesBefore == identitiesAfter else {
            throw DialogueVoiceRuntimeError.sourceChanged
        }
        return DialogueVoiceValidatedAssets(digests: digests, identities: identitiesAfter)
    }

    static func assetIdentities(
        profile: GPTSoVITSVoiceProfile,
        applicationSupportRoot: URL
    ) throws -> DialogueVoiceAssetIdentities {
        try DialogueVoiceAssetIdentities(
            gptWeight: DialogueVoiceAssetInstaller.managedFileIdentity(
                relativePath: profile.gptWeightRelativePath,
                root: applicationSupportRoot,
                maximumBytes: DialogueVoiceAssetKind.gptWeight.maximumBytes
            ),
            sovitsWeight: DialogueVoiceAssetInstaller.managedFileIdentity(
                relativePath: profile.sovitsWeightRelativePath,
                root: applicationSupportRoot,
                maximumBytes: DialogueVoiceAssetKind.sovitsWeight.maximumBytes
            ),
            referenceAudio: DialogueVoiceAssetInstaller.managedFileIdentity(
                relativePath: profile.referenceAudioRelativePath,
                root: applicationSupportRoot,
                maximumBytes: DialogueVoiceAssetKind.referenceAudio.maximumBytes
            )
        )
    }

    private static func hex<Digest: Sequence>(_ digest: Digest) -> String where Digest.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct DialogueVoiceFileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(_ status: stat) {
        device = UInt64(status.st_dev)
        inode = UInt64(status.st_ino)
        size = Int64(status.st_size)
        modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        changedSeconds = Int64(status.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
    }

    var token: String {
        [
            device,
            inode,
            UInt64(bitPattern: size),
            UInt64(bitPattern: modifiedSeconds),
            UInt64(bitPattern: modifiedNanoseconds),
            UInt64(bitPattern: changedSeconds),
            UInt64(bitPattern: changedNanoseconds),
        ].map(String.init).joined(separator: ":")
    }
}

struct DialogueVoiceAssetInstaller: Sendable {
    let applicationSupportRoot: URL

    func install(sourceURL: URL, kind: DialogueVoiceAssetKind) throws -> DialogueVoiceInstalledAsset {
        try Task.checkCancellation()
        guard sourceURL.isFileURL,
              sourceURL.host.map({ $0.isEmpty || $0 == "localhost" }) ?? true else {
            throw DialogueVoiceRuntimeError.invalidSource
        }
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard kind.allowedExtensions.contains(fileExtension) else {
            throw DialogueVoiceRuntimeError.unsupportedFileType
        }

        let sourceDescriptor = Darwin.open(
            sourceURL.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard sourceDescriptor >= 0 else { throw DialogueVoiceRuntimeError.invalidSource }
        defer { Darwin.close(sourceDescriptor) }

        var sourceStatus = stat()
        guard Darwin.fstat(sourceDescriptor, &sourceStatus) == 0,
              sourceStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              sourceStatus.st_size > 0 else {
            throw DialogueVoiceRuntimeError.invalidSource
        }
        guard UInt64(sourceStatus.st_size) <= kind.maximumBytes else {
            throw DialogueVoiceRuntimeError.sourceTooLarge
        }
        let sourceIdentity = DialogueVoiceFileIdentity(sourceStatus)

        let voiceRoot = applicationSupportRoot.appendingPathComponent("voice", isDirectory: true)
        let assetsRoot = voiceRoot.appendingPathComponent("assets", isDirectory: true)
        let destinationDirectory = assetsRoot.appendingPathComponent(kind.rawValue, isDirectory: true)
        for directory in [applicationSupportRoot, voiceRoot, assetsRoot, destinationDirectory] {
            try Self.ensurePrivateDirectory(directory)
        }

        let filename = "\(UUID().uuidString.lowercased()).\(fileExtension)"
        let temporaryName = ".\(filename).partial"
        let directoryDescriptor = Darwin.open(
            destinationDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else { throw DialogueVoiceRuntimeError.copyFailed }
        defer { Darwin.close(directoryDescriptor) }
        var published = false
        var succeeded = false
        defer {
            let name = published ? filename : temporaryName
            if !succeeded {
                _ = name.withCString { Darwin.unlinkat(directoryDescriptor, $0, 0) }
                _ = Darwin.fsync(directoryDescriptor)
            }
        }

        let destinationDescriptor = temporaryName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard destinationDescriptor >= 0 else { throw DialogueVoiceRuntimeError.copyFailed }
        var destinationOpen = true
        defer {
            if destinationOpen { Darwin.close(destinationDescriptor) }
        }

        var copiedBytes: UInt64 = 0
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { storage in
                Darwin.read(sourceDescriptor, storage.baseAddress, storage.count)
            }
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw DialogueVoiceRuntimeError.copyFailed
            }
            var written = 0
            while written < count {
                try Task.checkCancellation()
                let result = buffer.withUnsafeBytes { storage in
                    Darwin.write(
                        destinationDescriptor,
                        storage.baseAddress?.advanced(by: written),
                        count - written
                    )
                }
                guard result > 0 else {
                    if result < 0, errno == EINTR { continue }
                    throw DialogueVoiceRuntimeError.copyFailed
                }
                written += result
            }
            hasher.update(data: Data(buffer.prefix(count)))
            copiedBytes += UInt64(count)
            guard copiedBytes <= kind.maximumBytes else {
                throw DialogueVoiceRuntimeError.sourceTooLarge
            }
        }

        var finalSourceStatus = stat()
        guard Darwin.fstat(sourceDescriptor, &finalSourceStatus) == 0,
              DialogueVoiceFileIdentity(finalSourceStatus) == sourceIdentity,
              copiedBytes == UInt64(sourceStatus.st_size) else {
            throw DialogueVoiceRuntimeError.sourceChanged
        }
        guard Darwin.fchmod(destinationDescriptor, mode_t(S_IRUSR | S_IWUSR)) == 0,
              Darwin.fsync(destinationDescriptor) == 0 else {
            throw DialogueVoiceRuntimeError.copyFailed
        }
        try Task.checkCancellation()
        Darwin.close(destinationDescriptor)
        destinationOpen = false
        let renameResult = temporaryName.withCString { sourceName in
            filename.withCString { destinationName in
                Darwin.renameat(
                    directoryDescriptor,
                    sourceName,
                    directoryDescriptor,
                    destinationName
                )
            }
        }
        guard renameResult == 0 else {
            throw DialogueVoiceRuntimeError.copyFailed
        }
        published = true
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw DialogueVoiceRuntimeError.copyFailed
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let relativePath = "voice/assets/\(kind.rawValue)/\(filename)"
        if kind == .referenceAudio {
            try Self.validateReferenceAudio(relativePath: relativePath, root: applicationSupportRoot)
        }
        succeeded = true
        return DialogueVoiceInstalledAsset(
            relativePath: relativePath,
            contentDigest: digest
        )
    }

    static func resolveManagedFile(
        relativePath: String,
        root: URL,
        maximumBytes: UInt64
    ) throws -> URL {
        let opened = try openValidatedManagedFile(
            relativePath: relativePath,
            root: root,
            maximumBytes: maximumBytes
        )
        Darwin.close(opened.fileDescriptor)
        Darwin.close(opened.parentDescriptor)
        return opened.url
    }

    static func readManagedFile(
        relativePath: String,
        root: URL,
        maximumBytes: UInt64
    ) throws -> Data {
        let opened = try openValidatedManagedFile(
            relativePath: relativePath,
            root: root,
            maximumBytes: maximumBytes
        )
        defer {
            Darwin.close(opened.fileDescriptor)
            Darwin.close(opened.parentDescriptor)
        }
        let identity = DialogueVoiceFileIdentity(opened.status)
        var data = Data()
        data.reserveCapacity(Int(opened.status.st_size))
        var buffer = [UInt8](repeating: 0, count: 256 * 1_024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(opened.fileDescriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw DialogueVoiceRuntimeError.invalidManagedPath
            }
            guard UInt64(data.count + count) <= maximumBytes else {
                throw DialogueVoiceRuntimeError.invalidManagedPath
            }
            data.append(buffer, count: count)
        }
        var finalStatus = stat()
        guard Darwin.fstat(opened.fileDescriptor, &finalStatus) == 0,
              DialogueVoiceFileIdentity(finalStatus) == identity,
              data.count == Int(opened.status.st_size) else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        return data
    }

    static func sha256ManagedFile(
        relativePath: String,
        root: URL,
        maximumBytes: UInt64
    ) throws -> String {
        let opened = try openValidatedManagedFile(
            relativePath: relativePath,
            root: root,
            maximumBytes: maximumBytes
        )
        defer {
            Darwin.close(opened.fileDescriptor)
            Darwin.close(opened.parentDescriptor)
        }
        let identity = DialogueVoiceFileIdentity(opened.status)
        var hasher = SHA256()
        var readBytes: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(opened.fileDescriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw DialogueVoiceRuntimeError.invalidManagedPath
            }
            readBytes += UInt64(count)
            guard readBytes <= maximumBytes else {
                throw DialogueVoiceRuntimeError.invalidManagedPath
            }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        var finalStatus = stat()
        guard Darwin.fstat(opened.fileDescriptor, &finalStatus) == 0,
              DialogueVoiceFileIdentity(finalStatus) == identity,
              readBytes == UInt64(opened.status.st_size) else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func managedFileIdentity(
        relativePath: String,
        root: URL,
        maximumBytes: UInt64
    ) throws -> String {
        let opened = try openValidatedManagedFile(
            relativePath: relativePath,
            root: root,
            maximumBytes: maximumBytes
        )
        defer {
            Darwin.close(opened.fileDescriptor)
            Darwin.close(opened.parentDescriptor)
        }
        return DialogueVoiceFileIdentity(opened.status).token
    }

    static func validateReferenceAudio(relativePath: String, root: URL) throws {
        let data = try readManagedFile(
            relativePath: relativePath,
            root: root,
            maximumBytes: DialogueVoiceAssetKind.referenceAudio.maximumBytes
        )
        do {
            let player = try AVAudioPlayer(data: data)
            guard player.duration > 0, player.duration <= 60, player.prepareToPlay() else {
                throw DialogueVoiceRuntimeError.invalidReferenceAudio
            }
        } catch let error as DialogueVoiceRuntimeError {
            throw error
        } catch {
            throw DialogueVoiceRuntimeError.invalidReferenceAudio
        }
    }

    @discardableResult
    static func removeManagedFile(
        relativePath: String,
        root: URL,
        maximumBytes: UInt64
    ) throws -> Bool {
        let parent = try openManagedParent(relativePath: relativePath, root: root)
        defer { Darwin.close(parent.descriptor) }
        var currentStatus = stat()
        let statusResult = parent.name.withCString {
            Darwin.fstatat(parent.descriptor, $0, &currentStatus, AT_SYMLINK_NOFOLLOW)
        }
        if statusResult != 0, errno == ENOENT { return false }
        guard statusResult == 0,
              currentStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              currentStatus.st_size > 0,
              UInt64(currentStatus.st_size) <= maximumBytes else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        let fileDescriptor = parent.name.withCString {
            Darwin.openat(
                parent.descriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard fileDescriptor >= 0 else { throw DialogueVoiceRuntimeError.invalidManagedPath }
        defer { Darwin.close(fileDescriptor) }
        var openedStatus = stat()
        guard Darwin.fstat(fileDescriptor, &openedStatus) == 0,
              DialogueVoiceFileIdentity(openedStatus) == DialogueVoiceFileIdentity(currentStatus) else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        let unlinkResult = parent.name.withCString {
            Darwin.unlinkat(parent.descriptor, $0, 0)
        }
        guard unlinkResult == 0 else { throw DialogueVoiceRuntimeError.invalidManagedPath }
        guard Darwin.fsync(parent.descriptor) == 0 else {
            throw DialogueVoiceRuntimeError.copyFailed
        }
        return true
    }

    @discardableResult
    static func removeManagedDirectory(
        relativePath: String,
        root: URL,
        maximumBytes: UInt64
    ) throws -> Bool {
        let parent = try openManagedParent(relativePath: relativePath, root: root)
        defer { Darwin.close(parent.descriptor) }
        var currentStatus = stat()
        let statusResult = parent.name.withCString {
            Darwin.fstatat(parent.descriptor, $0, &currentStatus, AT_SYMLINK_NOFOLLOW)
        }
        if statusResult != 0, errno == ENOENT { return false }
        guard statusResult == 0,
              currentStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        let directoryDescriptor = parent.name.withCString {
            Darwin.openat(
                parent.descriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard directoryDescriptor >= 0 else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        defer { Darwin.close(directoryDescriptor) }
        var openedStatus = stat()
        guard Darwin.fstat(directoryDescriptor, &openedStatus) == 0,
              DialogueVoiceFileIdentity(openedStatus) == DialogueVoiceFileIdentity(currentStatus) else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        var budget = ManagedDirectoryRemovalBudget()
        try removeDirectoryContents(
            descriptor: directoryDescriptor,
            maximumBytes: maximumBytes,
            depth: 0,
            budget: &budget
        )
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw DialogueVoiceRuntimeError.copyFailed
        }
        let unlinkResult = parent.name.withCString {
            Darwin.unlinkat(parent.descriptor, $0, AT_REMOVEDIR)
        }
        guard unlinkResult == 0, Darwin.fsync(parent.descriptor) == 0 else {
            throw DialogueVoiceRuntimeError.copyFailed
        }
        return true
    }

    private struct ManagedDirectoryRemovalBudget {
        var bytes: UInt64 = 0
        var entries = 0
    }

    private static func removeDirectoryContents(
        descriptor: Int32,
        maximumBytes: UInt64,
        depth: Int,
        budget: inout ManagedDirectoryRemovalBudget
    ) throws {
        guard depth <= 32 else { throw DialogueVoiceRuntimeError.invalidManagedPath }
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0, let stream = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        defer { Darwin.closedir(stream) }
        while let entry = Darwin.readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            budget.entries += 1
            guard budget.entries <= 100_000 else {
                throw DialogueVoiceRuntimeError.invalidManagedPath
            }
            var status = stat()
            let statusResult = name.withCString {
                Darwin.fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }
            guard statusResult == 0 else { throw DialogueVoiceRuntimeError.invalidManagedPath }
            let kind = status.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFREG) {
                guard status.st_size > 0 else { throw DialogueVoiceRuntimeError.invalidManagedPath }
                let size = UInt64(status.st_size)
                let (updatedBytes, overflow) = budget.bytes.addingReportingOverflow(size)
                guard !overflow, updatedBytes <= maximumBytes else {
                    throw DialogueVoiceRuntimeError.invalidManagedPath
                }
                budget.bytes = updatedBytes
                let fileDescriptor = name.withCString {
                    Darwin.openat(descriptor, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
                }
                guard fileDescriptor >= 0 else {
                    throw DialogueVoiceRuntimeError.invalidManagedPath
                }
                var openedStatus = stat()
                let identityMatches = Darwin.fstat(fileDescriptor, &openedStatus) == 0
                    && DialogueVoiceFileIdentity(openedStatus) == DialogueVoiceFileIdentity(status)
                Darwin.close(fileDescriptor)
                guard identityMatches,
                      name.withCString({ Darwin.unlinkat(descriptor, $0, 0) }) == 0 else {
                    throw DialogueVoiceRuntimeError.invalidManagedPath
                }
            } else if kind == mode_t(S_IFDIR) {
                let childDescriptor = name.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard childDescriptor >= 0 else {
                    throw DialogueVoiceRuntimeError.invalidManagedPath
                }
                var childStatus = stat()
                let identityMatches = Darwin.fstat(childDescriptor, &childStatus) == 0
                    && DialogueVoiceFileIdentity(childStatus) == DialogueVoiceFileIdentity(status)
                guard identityMatches else {
                    Darwin.close(childDescriptor)
                    throw DialogueVoiceRuntimeError.invalidManagedPath
                }
                do {
                    try removeDirectoryContents(
                        descriptor: childDescriptor,
                        maximumBytes: maximumBytes,
                        depth: depth + 1,
                        budget: &budget
                    )
                    guard Darwin.fsync(childDescriptor) == 0 else {
                        throw DialogueVoiceRuntimeError.copyFailed
                    }
                    Darwin.close(childDescriptor)
                } catch {
                    Darwin.close(childDescriptor)
                    throw error
                }
                guard name.withCString({ Darwin.unlinkat(descriptor, $0, AT_REMOVEDIR) }) == 0 else {
                    throw DialogueVoiceRuntimeError.invalidManagedPath
                }
            } else {
                throw DialogueVoiceRuntimeError.invalidManagedPath
            }
        }
    }

    static func ensurePrivateDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw DialogueVoiceRuntimeError.copyFailed
        }
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              Darwin.chmod(url.path, mode_t(S_IRWXU)) == 0 else {
            throw DialogueVoiceRuntimeError.copyFailed
        }
    }

    private static func openValidatedManagedFile(
        relativePath: String,
        root: URL,
        maximumBytes: UInt64
    ) throws -> (
        parentDescriptor: Int32,
        fileDescriptor: Int32,
        name: String,
        url: URL,
        status: stat
    ) {
        let parent = try openManagedParent(relativePath: relativePath, root: root)
        let fileDescriptor = parent.name.withCString {
            Darwin.openat(
                parent.descriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard fileDescriptor >= 0 else {
            Darwin.close(parent.descriptor)
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        var status = stat()
        guard Darwin.fstat(fileDescriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_size > 0,
              UInt64(status.st_size) <= maximumBytes else {
            Darwin.close(fileDescriptor)
            Darwin.close(parent.descriptor)
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        return (parent.descriptor, fileDescriptor, parent.name, parent.url, status)
    }

    private static func openManagedParent(
        relativePath: String,
        root: URL
    ) throws -> (descriptor: Int32, name: String, url: URL) {
        guard root.isFileURL else { throw DialogueVoiceRuntimeError.invalidManagedPath }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !relativePath.hasPrefix("/"),
              !relativePath.hasPrefix("~"),
              !relativePath.contains("\\"),
              !relativePath.contains(":"),
              !relativePath.contains("\0") else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }

        let standardizedRoot = root.standardizedFileURL
        var rootStatus = stat()
        guard Darwin.lstat(standardizedRoot.path, &rootStatus) == 0,
              rootStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        var currentDescriptor = Darwin.open(
            standardizedRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard currentDescriptor >= 0 else { throw DialogueVoiceRuntimeError.invalidManagedPath }

        for component in components.dropLast() {
            let nextDescriptor = component.withCString {
                Darwin.openat(
                    currentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard nextDescriptor >= 0 else {
                Darwin.close(currentDescriptor)
                throw DialogueVoiceRuntimeError.invalidManagedPath
            }
            var directoryStatus = stat()
            guard Darwin.fstat(nextDescriptor, &directoryStatus) == 0,
                  directoryStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                Darwin.close(nextDescriptor)
                Darwin.close(currentDescriptor)
                throw DialogueVoiceRuntimeError.invalidManagedPath
            }
            Darwin.close(currentDescriptor)
            currentDescriptor = nextDescriptor
        }

        let componentStrings = components.map(String.init)
        let url = componentStrings.reduce(standardizedRoot) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
        return (currentDescriptor, componentStrings.last!, url)
    }
}

final class DialogueVoiceBoundedRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var data = Data()
    private var response: URLResponse?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var finished = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func perform(
        _ request: URLRequest,
        configuration: URLSessionConfiguration
    ) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: nil
                )
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                if Task.isCancelled {
                    cancel()
                    return
                }
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if response.expectedContentLength > Int64(maximumBytes) {
            completionHandler(.cancel)
            finish(.failure(DialogueVoiceRuntimeError.responseTooLarge))
            return
        }
        lock.lock()
        self.response = response
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        let fits = chunk.count <= maximumBytes - data.count
        if fits { data.append(chunk) }
        lock.unlock()
        if !fits {
            dataTask.cancel()
            finish(.failure(DialogueVoiceRuntimeError.responseTooLarge))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }
        lock.lock()
        let response = self.response
        let data = self.data
        lock.unlock()
        guard let response else {
            finish(.failure(DialogueVoiceRuntimeError.inferenceUnavailable))
            return
        }
        finish(.success((data, response)))
    }

    private func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<(Data, URLResponse), Error>) {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        let session = self.session
        self.session = nil
        self.task = nil
        lock.unlock()
        continuation.resume(with: result)
        session?.finishTasksAndInvalidate()
    }
}

actor GPTSoVITSAPIClient {
    private struct TTSBody: Encodable {
        let text: String
        let textLanguage: String
        let referenceAudioPath: String
        let promptText: String
        let promptLanguage: String
        let mediaType = "wav"
        let streamingMode = false
        let textSplitMethod = "cut0"
        let batchSize = 1
        let parallelInfer = false
        let splitBucket = false
        let fragmentInterval = 0.0
        let topK = 5
        let topP = 0.8
        let temperature = 0.6
        let repetitionPenalty = 1.35
        let seed: Int = 24_681

        enum CodingKeys: String, CodingKey {
            case text
            case textLanguage = "text_lang"
            case referenceAudioPath = "ref_audio_path"
            case promptText = "prompt_text"
            case promptLanguage = "prompt_lang"
            case mediaType = "media_type"
            case streamingMode = "streaming_mode"
            case textSplitMethod = "text_split_method"
            case batchSize = "batch_size"
            case parallelInfer = "parallel_infer"
            case splitBucket = "split_bucket"
            case fragmentInterval = "fragment_interval"
            case topK = "top_k"
            case topP = "top_p"
            case temperature
            case repetitionPenalty = "repetition_penalty"
            case seed
        }
    }

    private static let maximumControlResponseBytes = 65_536
    private static let maximumAudioResponseBytes = 67_108_864

    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 180
        self.configuration = configuration
    }

    static func encodedTTSRequestBody(
        text: String,
        textLanguage: String,
        referenceAudioPath: String,
        promptText: String,
        promptLanguage: String
    ) throws -> Data {
        try JSONEncoder().encode(TTSBody(
            text: text,
            textLanguage: textLanguage.lowercased(),
            referenceAudioPath: referenceAudioPath,
            promptText: promptText,
            promptLanguage: promptLanguage.lowercased()
        ))
    }

    func synthesize(
        profile: GPTSoVITSVoiceProfile,
        line: DialogueLine,
        applicationSupportRoot: URL
    ) async throws -> Data {
        try Task.checkCancellation()
        let referenceAudioURL = try await activateProfile(
            profile,
            applicationSupportRoot: applicationSupportRoot
        )
        let baseURL = try Self.validatedBaseURL(profile.apiBaseURL)
        let endpoint = baseURL.appendingPathComponent("tts")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/wav", forHTTPHeaderField: "Accept")
        request.httpBody = try Self.encodedTTSRequestBody(
            text: line.text,
            textLanguage: line.textLanguage,
            referenceAudioPath: referenceAudioURL.path,
            promptText: profile.referenceText,
            promptLanguage: profile.promptLanguage
        )
        let (data, response) = try await perform(
            request,
            maximumBytes: Self.maximumAudioResponseBytes
        )
        guard let http = response as? HTTPURLResponse else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            if Self.isTransientHTTPStatus(http.statusCode) {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
            throw http.statusCode == 404
                ? DialogueVoiceRuntimeError.profileRejected
                : DialogueVoiceRuntimeError.requestRejected
        }
        guard Self.isValidWAV(data) else { throw DialogueVoiceRuntimeError.invalidAudio }
        return data
    }

    func validateProfile(
        _ profile: GPTSoVITSVoiceProfile,
        applicationSupportRoot: URL
    ) async throws {
        _ = try await activateProfile(profile, applicationSupportRoot: applicationSupportRoot)
    }

    private func activateProfile(
        _ profile: GPTSoVITSVoiceProfile,
        applicationSupportRoot: URL
    ) async throws -> URL {
        let baseURL = try Self.validatedBaseURL(profile.apiBaseURL)
        let gptWeightURL = try DialogueVoiceAssetInstaller.resolveManagedFile(
            relativePath: profile.gptWeightRelativePath,
            root: applicationSupportRoot,
            maximumBytes: DialogueVoiceAssetKind.gptWeight.maximumBytes
        )
        let sovitsWeightURL = try DialogueVoiceAssetInstaller.resolveManagedFile(
            relativePath: profile.sovitsWeightRelativePath,
            root: applicationSupportRoot,
            maximumBytes: DialogueVoiceAssetKind.sovitsWeight.maximumBytes
        )
        let referenceAudioURL = try DialogueVoiceAssetInstaller.resolveManagedFile(
            relativePath: profile.referenceAudioRelativePath,
            root: applicationSupportRoot,
            maximumBytes: DialogueVoiceAssetKind.referenceAudio.maximumBytes
        )

        // GPT-SoVITS keeps active weights as process-global state. Re-activate for every
        // request so a service restart or another local client cannot silently select a
        // different model behind Statelet's profile revision.
        try await setWeight(
            baseURL: baseURL,
            endpoint: "set_gpt_weights",
            queryName: "weights_path",
            value: gptWeightURL.path
        )
        try await setWeight(
            baseURL: baseURL,
            endpoint: "set_sovits_weights",
            queryName: "weights_path",
            value: sovitsWeightURL.path
        )
        return referenceAudioURL
    }

    private func setWeight(
        baseURL: URL,
        endpoint: String,
        queryName: String,
        value: String
    ) async throws {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(endpoint),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: queryName, value: value)]
        guard let url = components?.url else { throw DialogueVoiceRuntimeError.inferenceUnavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (_, response) = try await perform(
            request,
            maximumBytes: Self.maximumControlResponseBytes
        )
        guard let http = response as? HTTPURLResponse else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw Self.isTransientHTTPStatus(http.statusCode)
                ? DialogueVoiceRuntimeError.inferenceUnavailable
                : DialogueVoiceRuntimeError.profileRejected
        }
    }

    private func perform(
        _ request: URLRequest,
        maximumBytes: Int
    ) async throws -> (Data, URLResponse) {
        do {
            try Task.checkCancellation()
            return try await DialogueVoiceBoundedRequest(maximumBytes: maximumBytes)
                .perform(request, configuration: configuration)
        } catch let error as DialogueVoiceRuntimeError {
            throw error
        } catch is CancellationError {
            throw DialogueVoiceRuntimeError.cancelled
        } catch {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
    }

    private static func validatedBaseURL(_ url: URL) throws -> URL {
        do {
            return try DialogueVoiceEndpointPolicy.validatedLoopbackURL(url)
        } catch {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
    }

    private static func isTransientHTTPStatus(_ statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
    }

    static func isValidWAV(_ data: Data) -> Bool {
        guard data.count >= 44,
              data.count <= maximumAudioResponseBytes,
              data.prefix(4) == Data("RIFF".utf8),
              data.dropFirst(8).prefix(4) == Data("WAVE".utf8),
              let declaredSize = littleEndianUInt32(data, offset: 4),
              Int(declaredSize) + 8 == data.count else { return false }

        var offset = 12
        var foundFormat = false
        var foundAudio = false
        var blockAlignment: UInt16?
        var sampleRate: UInt32?
        while offset + 8 <= data.count {
            let identifier = data.subdata(in: offset ..< offset + 4)
            guard let sizeValue = littleEndianUInt32(data, offset: offset + 4) else { return false }
            let size = Int(sizeValue)
            let payloadStart = offset + 8
            guard size >= 0, payloadStart <= data.count, size <= data.count - payloadStart else {
                return false
            }
            if identifier == Data("fmt ".utf8) {
                guard !foundFormat,
                      size >= 16,
                      let formatTag = littleEndianUInt16(data, offset: payloadStart), formatTag == 1,
                      let channels = littleEndianUInt16(data, offset: payloadStart + 2), (1...8).contains(channels),
                      let parsedSampleRate = littleEndianUInt32(data, offset: payloadStart + 4),
                      (8_000...192_000).contains(parsedSampleRate),
                      let byteRate = littleEndianUInt32(data, offset: payloadStart + 8),
                      let parsedBlockAlignment = littleEndianUInt16(data, offset: payloadStart + 12),
                      let bitsPerSample = littleEndianUInt16(data, offset: payloadStart + 14),
                      [8, 16, 24, 32].contains(bitsPerSample),
                      bitsPerSample % 8 == 0 else {
                    return false
                }
                let expectedBlockAlignment = UInt32(channels) * UInt32(bitsPerSample / 8)
                let expectedByteRate = UInt64(parsedSampleRate) * UInt64(expectedBlockAlignment)
                guard expectedBlockAlignment == UInt32(parsedBlockAlignment),
                      expectedByteRate == UInt64(byteRate) else { return false }
                foundFormat = true
                blockAlignment = parsedBlockAlignment
                sampleRate = parsedSampleRate
            } else if identifier == Data("data".utf8) {
                guard !foundAudio,
                      foundFormat,
                      let blockAlignment,
                      let sampleRate,
                      size > 0,
                      size % Int(blockAlignment) == 0 else { return false }
                let frameCount = size / Int(blockAlignment)
                guard frameCount <= Int(sampleRate) * 60 else { return false }
                foundAudio = true
            }
            let paddedSize = size + (size & 1)
            guard paddedSize <= data.count - payloadStart else { return false }
            offset = payloadStart + paddedSize
        }
        return foundFormat && foundAudio && offset == data.count
    }

    private static func littleEndianUInt16(_ data: Data, offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func littleEndianUInt32(_ data: Data, offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

struct Qwen3TTSProcessInvocation: Sendable {
    let executableURL: URL
    let helperURL: URL
    let currentDirectoryURL: URL
    let environment: [String: String]
    let standardInput: Data
    let outputURL: URL
    let timeout: TimeInterval
    let requiresOutputFile: Bool

    init(
        executableURL: URL,
        helperURL: URL,
        currentDirectoryURL: URL,
        environment: [String: String],
        standardInput: Data,
        outputURL: URL,
        timeout: TimeInterval,
        requiresOutputFile: Bool = true
    ) {
        self.executableURL = executableURL
        self.helperURL = helperURL
        self.currentDirectoryURL = currentDirectoryURL
        self.environment = environment
        self.standardInput = standardInput
        self.outputURL = outputURL
        self.timeout = timeout
        self.requiresOutputFile = requiresOutputFile
    }
}

private final class QwenLockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private var overflowed = false

    init(limit: Int) { self.limit = limit }

    func append(_ value: Data) {
        lock.lock()
        let remaining = limit - storage.count
        if value.count > remaining { overflowed = true }
        storage.append(value.prefix(max(0, remaining)))
        lock.unlock()
    }

    var snapshot: (data: Data, overflowed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (storage, overflowed)
    }
}

private final class QwenProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func install(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { terminate(process, signal: SIGTERM) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if let process { terminate(process, signal: SIGTERM) }
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func terminate(_ process: Process, signal: Int32) {
        let pid = process.processIdentifier
        if Darwin.getpgid(pid) == pid { _ = Darwin.kill(-pid, signal) }
        else { _ = Darwin.kill(pid, signal) }
    }
}

struct Qwen3TTSProcessRunner: Sendable {
    private static let maximumCapturedBytes = 65_536

    func run(_ invocation: Qwen3TTSProcessInvocation) async throws {
        let cancellation = QwenProcessCancellation()
        do {
            try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try Self.runBlocking(invocation, cancellation: cancellation)
                }.value
            } onCancel: {
                cancellation.cancel()
            }
        } catch is CancellationError {
            throw DialogueVoiceRuntimeError.cancelled
        }
    }

    private static func runBlocking(
        _ invocation: Qwen3TTSProcessInvocation,
        cancellation: QwenProcessCancellation
    ) throws {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdout = QwenLockedDataBuffer(limit: maximumCapturedBytes)
        let stderr = QwenLockedDataBuffer(limit: maximumCapturedBytes)
        let reads = DispatchGroup()
        process.executableURL = invocation.executableURL
        process.arguments = ["-B", invocation.helperURL.path]
        process.currentDirectoryURL = invocation.currentDirectoryURL
        process.environment = invocation.environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do { try process.run() }
        catch { throw DialogueVoiceRuntimeError.inferenceUnavailable }
        cancellation.install(process)

        let groupDeadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < groupDeadline, Darwin.getpgid(process.processIdentifier) != process.processIdentifier {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard process.isRunning,
              Darwin.getpgid(process.processIdentifier) == process.processIdentifier else {
            terminate(process, signal: SIGTERM)
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }

        for (pipe, buffer) in [(stdoutPipe, stdout), (stderrPipe, stderr)] {
            reads.enter()
            DispatchQueue.global(qos: .utility).async {
                let handle = pipe.fileHandleForReading
                while true {
                    let data = handle.availableData
                    guard !data.isEmpty else { break }
                    buffer.append(data)
                }
                reads.leave()
            }
        }
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: invocation.standardInput)
            try stdinPipe.fileHandleForWriting.close()
        } catch {
            terminate(process, signal: SIGTERM)
        }

        let deadline = Date().addingTimeInterval(min(120, max(0.05, invocation.timeout)))
        while process.isRunning, Date() < deadline, !cancellation.isCancelled {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            terminate(process, signal: SIGTERM)
            let grace = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { terminate(process, signal: SIGKILL) }
        }
        if !process.isRunning { process.waitUntilExit() }
        if reads.wait(timeout: .now() + 1) == .timedOut {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }
        if cancellation.isCancelled { throw DialogueVoiceRuntimeError.cancelled }
        let standardOutput = stdout.snapshot
        let standardError = stderr.snapshot
        guard !standardOutput.overflowed, !standardError.overflowed,
              standardOutput.data.isEmpty,
              standardError.data.isEmpty || standardError.data == Data("QWEN_TTS_FAILED\n".utf8) else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        guard process.terminationStatus == 0 else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        guard !invocation.requiresOutputFile
                || FileManager.default.fileExists(atPath: invocation.outputURL.path) else {
            throw DialogueVoiceRuntimeError.invalidAudio
        }
    }

    private static func terminate(_ process: Process, signal: Int32) {
        let pid = process.processIdentifier
        if Darwin.getpgid(pid) == pid { _ = Darwin.kill(-pid, signal) }
        else { _ = Darwin.kill(pid, signal) }
    }
}

actor Qwen3TTSClient {
    typealias Runner = @Sendable (Qwen3TTSProcessInvocation) async throws -> Void
    private static let maximumAudioBytes = 67_108_864
    private static let maximumRequestBytes = 262_144
    private let helperExecutableURL: URL?
    private let probeExecutableURL: URL?
    private let runner: Runner

    init(
        helperExecutableURL: URL? = nil,
        probeExecutableURL: URL? = nil,
        runner: @escaping Runner = { try await Qwen3TTSProcessRunner().run($0) }
    ) {
        self.helperExecutableURL = helperExecutableURL
        self.probeExecutableURL = probeExecutableURL
        self.runner = runner
    }

    func validateProfile(
        _ profile: Qwen3TTSVoiceProfile,
        applicationSupportRoot: URL
    ) async throws {
        _ = try Qwen3TTSProfileValidator.snapshot(
            profile: profile,
            applicationSupportRoot: applicationSupportRoot
        )
        _ = try resolveHelper()
        let probe = try resolveProbe()
        let probeRoot = applicationSupportRoot
            .appendingPathComponent("voice/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try DialogueVoiceAssetInstaller.ensurePrivateDirectory(probeRoot)
        defer { try? FileManager.default.removeItem(at: probeRoot) }
        let marker = probeRoot.appendingPathComponent("probe.ok")
        try await runner(Qwen3TTSProcessInvocation(
            executableURL: URL(fileURLWithPath: profile.pythonExecutablePath),
            helperURL: probe,
            currentDirectoryURL: probeRoot,
            environment: Self.environment(home: probeRoot),
            standardInput: Data(),
            outputURL: marker,
            timeout: 15,
            requiresOutputFile: false
        ))
    }

    func synthesize(
        profile: Qwen3TTSVoiceProfile,
        line: DialogueLine,
        applicationSupportRoot: URL,
        expectedIdentityTokens: [String]? = nil
    ) async throws -> Data {
        try Task.checkCancellation()
        guard line.text.count <= 500,
              Qwen3TTSLanguage.canonicalJapanese(line.textLanguage) != nil,
              Qwen3TTSLanguage.canonicalJapanese(profile.referenceLanguage) != nil else {
            throw DialogueVoiceRuntimeError.requestRejected
        }
        let validated = try Qwen3TTSProfileValidator.snapshot(
            profile: profile, applicationSupportRoot: applicationSupportRoot
        )
        if let expectedIdentityTokens,
           expectedIdentityTokens != validated.identityTokens {
            throw DialogueVoiceRuntimeError.inputFingerprintMismatch
        }
        let packageIdentitiesBefore = try Qwen3TTSProfileValidator.packageIdentityTokens(
            packageRoot: validated.packageRoot
        )
        let helper = try resolveHelper()
        let temporaryRoot = applicationSupportRoot
            .appendingPathComponent("voice/tmp", isDirectory: true)
        try DialogueVoiceAssetInstaller.ensurePrivateDirectory(temporaryRoot)
        let jobDirectory = temporaryRoot.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try DialogueVoiceAssetInstaller.ensurePrivateDirectory(jobDirectory)
        defer { try? FileManager.default.removeItem(at: jobDirectory) }
        let outputURL = jobDirectory.appendingPathComponent("result.wav")
        let request = try Self.encodedRequest(
            profile: profile, line: line, package: validated, outputURL: outputURL
        )
        guard request.count <= Self.maximumRequestBytes else {
            throw DialogueVoiceRuntimeError.requestRejected
        }
        try await runner(Qwen3TTSProcessInvocation(
            executableURL: validated.pythonExecutable,
            helperURL: helper,
            currentDirectoryURL: jobDirectory,
            environment: Self.environment(home: jobDirectory),
            standardInput: request,
            outputURL: outputURL,
            timeout: 120
        ))
        try Task.checkCancellation()
        let validatedAfter = try Qwen3TTSProfileValidator.snapshot(
            profile: profile,
            applicationSupportRoot: applicationSupportRoot
        )
        let packageIdentitiesAfter = try Qwen3TTSProfileValidator.packageIdentityTokens(
            packageRoot: validatedAfter.packageRoot
        )
        guard packageIdentitiesBefore == packageIdentitiesAfter,
              validated.identityTokens == validatedAfter.identityTokens else {
            throw DialogueVoiceRuntimeError.sourceChanged
        }
        let relativeOutput = "voice/tmp/\(jobDirectory.lastPathComponent)/result.wav"
        let data = try DialogueVoiceAssetInstaller.readManagedFile(
            relativePath: relativeOutput,
            root: applicationSupportRoot,
            maximumBytes: UInt64(Self.maximumAudioBytes)
        )
        guard Self.isValidOutputWAV(data) else { throw DialogueVoiceRuntimeError.invalidAudio }
        return data
    }

    static func isValidOutputWAV(_ data: Data) -> Bool {
        guard data.count >= 44,
              data.count <= maximumAudioBytes,
              data.prefix(4) == Data("RIFF".utf8),
              data.dropFirst(8).prefix(4) == Data("WAVE".utf8),
              let declaredSize = uint32(data, 4), Int(declaredSize) + 8 == data.count else { return false }
        var offset = 12
        var formatFound = false
        var audioFound = false
        while offset + 8 <= data.count {
            let id = data.subdata(in: offset ..< offset + 4)
            guard let rawSize = uint32(data, offset + 4) else { return false }
            let size = Int(rawSize)
            let start = offset + 8
            guard size <= data.count - start else { return false }
            if id == Data("fmt ".utf8) {
                guard !formatFound, size >= 16,
                      uint16(data, start) == 1,
                      uint16(data, start + 2) == 1,
                      uint32(data, start + 4) == 24_000,
                      uint32(data, start + 8) == 48_000,
                      uint16(data, start + 12) == 2,
                      uint16(data, start + 14) == 16 else { return false }
                formatFound = true
            } else if id == Data("data".utf8) {
                guard formatFound, !audioFound, size > 0, size % 2 == 0,
                      size / 2 <= 24_000 * 60 else { return false }
                audioFound = true
            }
            let padded = size + (size & 1)
            guard padded <= data.count - start else { return false }
            offset = start + padded
        }
        return formatFound && audioFound && offset == data.count
    }

    private static func encodedRequest(
        profile: Qwen3TTSVoiceProfile,
        line: DialogueLine,
        package: Qwen3TTSValidatedPackage,
        outputURL: URL
    ) throws -> Data {
        let parameters: [String: Any] = [
            "temperature": profile.parameters.temperature,
            "top_k": profile.parameters.topK,
            "top_p": profile.parameters.topP,
            "repetition_penalty": profile.parameters.repetitionPenalty,
            "max_tokens": profile.parameters.maximumTokens,
            "seed": profile.parameters.seed,
        ]
        return try JSONSerialization.data(withJSONObject: [
            "text": line.text,
            "text_language": Qwen3TTSLanguage.japanese,
            "package_root": package.packageRoot.path,
            "model_file": package.modelFile.path,
            "config_file": package.configFile.path,
            "reference_file": package.referenceAudioFile.path,
            "output_file": outputURL.path,
            "reference_text": profile.referenceText,
            "reference_language": Qwen3TTSLanguage.japanese,
            "parameters": parameters,
        ], options: [.sortedKeys])
    }

    private static func environment(home: URL) -> [String: String] {
        [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
            "LC_ALL": "en_US.UTF-8",
            "PYTHONNOUSERSITE": "1",
            "PYTHONDONTWRITEBYTECODE": "1",
            "HF_HUB_OFFLINE": "1",
            "TRANSFORMERS_OFFLINE": "1",
            "TOKENIZERS_PARALLELISM": "false",
        ]
    }

    private func resolveHelper() throws -> URL {
        if let helperExecutableURL { return try Self.validateResource(helperExecutableURL) }
        return try resolveResource(named: "qwen3_tts_generate.py")
    }

    private func resolveProbe() throws -> URL {
        if let probeExecutableURL { return try Self.validateResource(probeExecutableURL) }
        return try resolveResource(named: "qwen3_tts_probe.py")
    }

    private func resolveResource(named name: String) throws -> URL {
        let url = Bundle.main.resourceURL?
            .appendingPathComponent("QwenTTS/\(name)")
        guard let url else { throw DialogueVoiceRuntimeError.inferenceUnavailable }
        return try Self.validateResource(url)
    }

    private static func validateResource(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw DialogueVoiceRuntimeError.inferenceUnavailable }
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_size > 0, status.st_size <= 1_048_576 else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        return url
    }

    private static func uint16(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}

struct DialogueVoiceAudioPublisher: Sendable {
    let applicationSupportRoot: URL

    func publish(
        data: Data,
        ticket: DialogueGenerationTicket
    ) throws -> String {
        try Task.checkCancellation()
        guard GPTSoVITSAPIClient.isValidWAV(data) else {
            throw DialogueVoiceRuntimeError.invalidAudio
        }
        let voiceRoot = applicationSupportRoot.appendingPathComponent("voice", isDirectory: true)
        let generatedRoot = voiceRoot.appendingPathComponent("generated", isDirectory: true)
        for directory in [applicationSupportRoot, voiceRoot, generatedRoot] {
            try DialogueVoiceAssetInstaller.ensurePrivateDirectory(directory)
        }
        let filename = "\(ticket.lineID.uuidString.lowercased())-r\(ticket.lineRevision)-p\(ticket.profileRevision)-\(UUID().uuidString.lowercased()).wav"
        let temporaryName = ".\(filename).partial"
        let directoryDescriptor = Darwin.open(
            generatedRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else { throw DialogueVoiceRuntimeError.copyFailed }
        defer { Darwin.close(directoryDescriptor) }
        var published = false
        var succeeded = false
        defer {
            let name = published ? filename : temporaryName
            if !succeeded {
                _ = name.withCString { Darwin.unlinkat(directoryDescriptor, $0, 0) }
                _ = Darwin.fsync(directoryDescriptor)
            }
        }

        let descriptor = temporaryName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else { throw DialogueVoiceRuntimeError.copyFailed }
        var open = true
        defer { if open { Darwin.close(descriptor) } }
        var offset = 0
        try data.withUnsafeBytes { storage in
            while offset < storage.count {
                try Task.checkCancellation()
                let count = Darwin.write(
                    descriptor,
                    storage.baseAddress?.advanced(by: offset),
                    storage.count - offset
                )
                guard count > 0 else {
                    if count < 0, errno == EINTR { continue }
                    throw DialogueVoiceRuntimeError.copyFailed
                }
                offset += count
            }
        }
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0,
              Darwin.fsync(descriptor) == 0 else {
            throw DialogueVoiceRuntimeError.copyFailed
        }
        Darwin.close(descriptor)
        open = false
        let renameResult = temporaryName.withCString { sourceName in
            filename.withCString { destinationName in
                Darwin.renameat(
                    directoryDescriptor,
                    sourceName,
                    directoryDescriptor,
                    destinationName
                )
            }
        }
        guard renameResult == 0 else {
            throw DialogueVoiceRuntimeError.copyFailed
        }
        published = true
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw DialogueVoiceRuntimeError.copyFailed
        }
        succeeded = true
        return "voice/generated/\(filename)"
    }

}

enum DialoguePlaybackUnavailableReason: Equatable, Sendable {
    case lineNotFound
    case notReady
    case missingOrInvalidAudio
}

enum DialoguePlaybackResult: Equatable, Sendable {
    case played
    case deferred
    case unavailable(DialoguePlaybackUnavailableReason)
}

protocol DialogueAudioPlaying: AnyObject {
    var isPlaying: Bool { get }
    var volume: Float { get set }
    func play(
        relativePath: String,
        applicationSupportRoot: URL,
        onFinished: @escaping () -> Void
    ) throws
    func stop()
}

final class DialogueAudioPlayer: NSObject, DialogueAudioPlaying, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var playbackCompletion: (() -> Void)?
    private var configuredVolume: Float = 1

    var isPlaying: Bool { player?.isPlaying == true }
    var volume: Float {
        get { configuredVolume }
        set {
            configuredVolume = min(max(newValue, 0), 1)
            player?.volume = configuredVolume
        }
    }

    func play(
        relativePath: String,
        applicationSupportRoot: URL,
        onFinished: @escaping () -> Void
    ) throws {
        let data = try DialogueVoiceAssetInstaller.readManagedFile(
            relativePath: relativePath,
            root: applicationSupportRoot,
            maximumBytes: 67_108_864
        )
        guard GPTSoVITSAPIClient.isValidWAV(data) else {
            throw DialogueVoiceRuntimeError.invalidAudio
        }
        let next = try AVAudioPlayer(data: data)
        guard next.prepareToPlay() else { throw DialogueVoiceRuntimeError.invalidAudio }
        stop()
        next.delegate = self
        next.volume = configuredVolume
        player = next
        playbackCompletion = onFinished
        guard next.play() else {
            player = nil
            playbackCompletion = nil
            throw DialogueVoiceRuntimeError.invalidAudio
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playbackCompletion = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === self.player else { return }
        self.player = nil
        let completion = playbackCompletion
        playbackCompletion = nil
        completion?()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        audioPlayerDidFinishPlaying(player, successfully: false)
    }
}

struct DialogueReadyPlaybackService {
    let applicationSupportRoot: URL
    let player: DialogueAudioPlaying

    func playReadyLine(
        id: UUID,
        in library: DialogueVoiceLibrary,
        onFinished: @escaping () -> Void = {}
    ) -> DialoguePlaybackResult {
        guard library.profileStatus == .ready || library.profileStatus == .unavailable else {
            return .unavailable(.notReady)
        }
        guard let line = library.lines.first(where: { $0.id == id }) else {
            return .unavailable(.lineNotFound)
        }
        guard line.status == .ready, let output = line.outputRelativePath else {
            return .unavailable(.notReady)
        }
        do {
            try player.play(
                relativePath: output,
                applicationSupportRoot: applicationSupportRoot,
                onFinished: onFinished
            )
            return .played
        } catch {
            return .unavailable(.missingOrInvalidAudio)
        }
    }
}
