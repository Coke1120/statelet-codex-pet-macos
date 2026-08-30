@preconcurrency import AVFoundation
import CodexPetCore
import CryptoKit
import Darwin
import Foundation
import os
import Security

enum DialogueVoiceAssetKind: String, Sendable {
    case gptWeight = "gpt"
    case sovitsWeight = "sovits"
    case referenceAudio = "reference"
    case voxcpm2ReferenceAudio = "voxcpm2-reference"

    var allowedExtensions: Set<String> {
        switch self {
        case .gptWeight: return ["ckpt"]
        case .sovitsWeight: return ["pth"]
        case .referenceAudio: return ["wav", "flac", "mp3", "m4a", "aac", "ogg"]
        case .voxcpm2ReferenceAudio: return ["wav"]
        }
    }

    var maximumBytes: UInt64 {
        switch self {
        case .gptWeight, .sovitsWeight: return 4_294_967_296
        case .referenceAudio, .voxcpm2ReferenceAudio: return 67_108_864
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
            return "The pinned HTTPS GPT-SoVITS gateway is unavailable or its leaf certificate does not match the saved SHA-256 pin."
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
    let runtimeIdentity: Qwen3TTSPythonRuntimeIdentity
    let identityTokens: [String]
    let treeSHA256: String
}

struct Qwen3TTSPythonRuntimeIdentity: Equatable, Sendable {
    let invocationPath: String
    let finalTargetSHA256: String
    let stableIdentityToken: String
}

struct Qwen3TTSRuntimeSearchPlan: Equatable, Sendable {
    let pythonHome: String
    let roots: [String]
}

struct QwenRuntimeValidationControl: @unchecked Sendable {
    let deadlineUptime: TimeInterval
    let isCancelled: @Sendable () -> Bool

    func check() throws {
        if isCancelled() { throw DialogueVoiceRuntimeError.cancelled }
        if ProcessInfo.processInfo.systemUptime >= deadlineUptime {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
    }
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

    static func managedRelativePaths(destinationToken token: String) throws -> (
        destination: String,
        staging: String
    ) {
        guard UUID(uuidString: token) != nil, token == token.lowercased() else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        return (
            destination: "voice/packages/qwen/\(token)",
            staging: "voice/packages/qwen/.\(token).partial"
        )
    }

    static func checkedAggregateSize(
        _ sizes: some Sequence<UInt64>,
        maximum: UInt64 = maximumPackageBytes
    ) throws -> UInt64 {
        var total: UInt64 = 0
        for size in sizes {
            let (next, overflow) = total.addingReportingOverflow(size)
            guard !overflow, next <= maximum else {
                throw DialogueVoiceRuntimeError.sourceTooLarge
            }
            total = next
        }
        guard total > 0 else { throw DialogueVoiceRuntimeError.sourceTooLarge }
        return total
    }

    func install(sourceURL: URL, destinationToken: String? = nil) throws -> Qwen3TTSImportedPackage {
        try Task.checkCancellation()
        guard sourceURL.isFileURL else { throw DialogueVoiceRuntimeError.invalidSource }
        let rootDescriptor = Darwin.open(
            sourceURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else { throw DialogueVoiceRuntimeError.invalidSource }
        defer { Darwin.close(rootDescriptor) }
        var rootStatus = stat()
        guard Darwin.fstat(rootDescriptor, &rootStatus) == 0,
              rootStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw DialogueVoiceRuntimeError.invalidSource
        }
        let rootIdentity = DialogueVoiceFileIdentity(rootStatus)
        let files = try enumerate(rootDescriptor)
        let total = try Self.checkedAggregateSize(files.lazy.map(\.size))
        let required = ["model/model.safetensors", "config.json", "generate.py"]
        guard required.allSatisfy({ name in files.contains(where: { $0.relativePath == name }) }) else {
            throw DialogueVoiceRuntimeError.invalidSource
        }
        let configData = try boundedRead(
            relativePath: "config.json", rootDescriptor: rootDescriptor, maximum: 1_048_576
        )
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
        let packagesDescriptor = Darwin.open(
            packagesRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard packagesDescriptor >= 0 else { throw DialogueVoiceRuntimeError.copyFailed }
        defer { Darwin.close(packagesDescriptor) }
        var packagesStatus = stat()
        guard Darwin.fstat(packagesDescriptor, &packagesStatus) == 0,
              packagesStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw DialogueVoiceRuntimeError.copyFailed
        }
        let packagesIdentity = DialogueVoiceDirectoryIdentity(packagesStatus)
        let token = destinationToken ?? UUID().uuidString.lowercased()
        let managedPaths = try Self.managedRelativePaths(destinationToken: token)
        let stageName = ".\(token).partial"
        let destinationName = token
        guard stageName.withCString({ Darwin.mkdirat(packagesDescriptor, $0, 0o700) }) == 0 else {
            throw DialogueVoiceRuntimeError.copyFailed
        }
        let stageDescriptor = stageName.withCString {
            Darwin.openat(
                packagesDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard stageDescriptor >= 0 else {
            stageName.withCString { _ = Darwin.unlinkat(packagesDescriptor, $0, AT_REMOVEDIR) }
            throw DialogueVoiceRuntimeError.copyFailed
        }
        defer { Darwin.close(stageDescriptor) }
        var stageStatus = stat()
        guard Darwin.fstat(stageDescriptor, &stageStatus) == 0,
              stageStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw DialogueVoiceRuntimeError.copyFailed
        }
        let stageIdentity = DialogueVoiceDirectoryIdentity(stageStatus)
        var published = false
        defer {
            if !published {
                try? Qwen3TTSPackageInstaller(
                    applicationSupportRoot: applicationSupportRoot
                ).removeManagedPackage(relativePath: managedPaths.staging)
            }
        }

        var stagedDigests: [String: String] = [:]
        for file in files {
            try Task.checkCancellation()
            stagedDigests[file.relativePath] = try copyRegularFile(
                file,
                rootDescriptor: rootDescriptor,
                stagingDescriptor: stageDescriptor
            )
        }
        var finalRootStatus = stat()
        guard Darwin.fstat(rootDescriptor, &finalRootStatus) == 0,
              DialogueVoiceFileIdentity(finalRootStatus) == rootIdentity else {
            throw DialogueVoiceRuntimeError.sourceChanged
        }
        let manifest = try Qwen3TTSPackageManifest(
            modelRelativePath: "model/model.safetensors",
            configRelativePath: "config.json",
            handoverGeneratorRelativePath: "generate.py",
            referenceAudioRelativePath: config.referenceAudio,
            modelSHA256: try requiredDigest(
                "model/model.safetensors", in: stagedDigests
            ),
            configSHA256: try requiredDigest("config.json", in: stagedDigests),
            handoverGeneratorSHA256: try requiredDigest(
                "generate.py", in: stagedDigests
            ),
            referenceAudioSHA256: try requiredDigest(
                config.referenceAudio, in: stagedDigests
            )
        )
        let treeDigest = Self.treeDigest(stagedDigests)
        var finalPackagesStatus = stat()
        var finalStageStatus = stat()
        var namedStageStatus = stat()
        guard Darwin.fstat(packagesDescriptor, &finalPackagesStatus) == 0,
              DialogueVoiceDirectoryIdentity(finalPackagesStatus) == packagesIdentity,
              Darwin.fstat(stageDescriptor, &finalStageStatus) == 0,
              DialogueVoiceDirectoryIdentity(finalStageStatus) == stageIdentity,
              stageName.withCString({
                  Darwin.fstatat(packagesDescriptor, $0, &namedStageStatus, AT_SYMLINK_NOFOLLOW)
              }) == 0,
              DialogueVoiceDirectoryIdentity(namedStageStatus) == stageIdentity else {
            throw DialogueVoiceRuntimeError.copyFailed
        }
        guard stageName.withCString({ stagePointer in
            destinationName.withCString { destinationPointer in
                Darwin.renameatx_np(
                    packagesDescriptor,
                    stagePointer,
                    packagesDescriptor,
                    destinationPointer,
                    UInt32(RENAME_EXCL)
                )
            }
        }) == 0,
              Darwin.fsync(packagesDescriptor) == 0 else {
            throw DialogueVoiceRuntimeError.copyFailed
        }
        var publishedStatus = stat()
        guard destinationName.withCString({
            Darwin.fstatat(packagesDescriptor, $0, &publishedStatus, AT_SYMLINK_NOFOLLOW)
        }) == 0,
              DialogueVoiceDirectoryIdentity(publishedStatus) == stageIdentity else {
            throw DialogueVoiceRuntimeError.copyFailed
        }
        published = true
        return Qwen3TTSImportedPackage(
            packageRootRelativePath: managedPaths.destination, manifest: manifest,
            treeSHA256: treeDigest, referenceText: config.referenceText,
            referenceLanguage: Qwen3TTSLanguage.japanese, parameters: parameters
        )
    }

    func removeManagedPackage(relativePath: String) throws {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 4,
              components[0] == "voice",
              components[1] == "packages",
              components[2] == "qwen" else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        let leaf = String(components[3])
        let token: String
        if leaf.hasPrefix("."), leaf.hasSuffix(".partial") {
            token = String(leaf.dropFirst().dropLast(".partial".count))
        } else {
            token = leaf
        }
        guard UUID(uuidString: token) != nil, token == token.lowercased() else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        _ = try DialogueVoiceAssetInstaller.removeManagedDirectory(
            relativePath: relativePath,
            root: applicationSupportRoot,
            maximumBytes: Self.maximumPackageBytes
        )
    }

    private func enumerate(_ rootDescriptor: Int32) throws -> [SourceFile] {
        var result: [SourceFile] = []
        var entryCount = 0
        try enumerateDirectory(
            descriptor: rootDescriptor, prefix: "", depth: 0,
            entryCount: &entryCount, result: &result
        )
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    private func enumerateDirectory(
        descriptor: Int32,
        prefix: String,
        depth: Int,
        entryCount: inout Int,
        result: inout [SourceFile]
    ) throws {
        guard depth <= 32 else { throw DialogueVoiceRuntimeError.invalidSource }
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0, let stream = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw DialogueVoiceRuntimeError.invalidSource
        }
        defer { Darwin.closedir(stream) }
        Darwin.rewinddir(stream)
        while let entry = Darwin.readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.contains(":") else {
                throw DialogueVoiceRuntimeError.invalidSource
            }
            entryCount += 1
            guard entryCount <= 100_000 else { throw DialogueVoiceRuntimeError.sourceTooLarge }
            let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"
            var status = stat()
            guard name.withCString({ Darwin.fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW) }) == 0 else {
                throw DialogueVoiceRuntimeError.invalidSource
            }
            let kind = status.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFDIR) {
                let child = name.withCString {
                    Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard child >= 0 else { throw DialogueVoiceRuntimeError.invalidSource }
                defer { Darwin.close(child) }
                var opened = stat()
                guard Darwin.fstat(child, &opened) == 0,
                      DialogueVoiceFileIdentity(opened) == DialogueVoiceFileIdentity(status) else {
                    throw DialogueVoiceRuntimeError.sourceChanged
                }
                try enumerateDirectory(
                    descriptor: child, prefix: relative, depth: depth + 1,
                    entryCount: &entryCount, result: &result
                )
                continue
            }
            guard kind == mode_t(S_IFREG), status.st_size > 0 else {
                throw DialogueVoiceRuntimeError.invalidSource
            }
            result.append(SourceFile(
                relativePath: relative,
                identity: DialogueVoiceFileIdentity(status),
                size: UInt64(status.st_size)
            ))
        }
    }

    private func copyRegularFile(
        _ source: SourceFile,
        rootDescriptor: Int32,
        stagingDescriptor: Int32
    ) throws -> String {
        let sourceDescriptor = try openSourceFile(
            relativePath: source.relativePath, rootDescriptor: rootDescriptor
        )
        defer { Darwin.close(sourceDescriptor) }
        var sourceStatus = stat()
        guard Darwin.fstat(sourceDescriptor, &sourceStatus) == 0,
              DialogueVoiceFileIdentity(sourceStatus) == source.identity else {
            throw DialogueVoiceRuntimeError.sourceChanged
        }
        let destinationParent = try openOrCreateDestinationParent(
            relativePath: source.relativePath,
            stagingDescriptor: stagingDescriptor
        )
        defer { Darwin.close(destinationParent.descriptor) }
        let destinationDescriptor = destinationParent.name.withCString {
            Darwin.openat(
                destinationParent.descriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard destinationDescriptor >= 0 else { throw DialogueVoiceRuntimeError.copyFailed }
        defer { Darwin.close(destinationDescriptor) }
        var copied: UInt64 = 0
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(sourceDescriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw DialogueVoiceRuntimeError.copyFailed
            }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes {
                    Darwin.write(destinationDescriptor, $0.baseAddress?.advanced(by: offset), count - offset)
                }
                guard written > 0 else {
                    if written < 0, errno == EINTR { continue }
                    throw DialogueVoiceRuntimeError.copyFailed
                }
                offset += written
            }
            copied += UInt64(count)
            guard copied <= source.size else { throw DialogueVoiceRuntimeError.sourceChanged }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        var finalSource = stat()
        guard copied == source.size,
              Darwin.fstat(sourceDescriptor, &finalSource) == 0,
              DialogueVoiceFileIdentity(finalSource) == source.identity,
              Darwin.fchmod(destinationDescriptor, mode_t(S_IRUSR | S_IWUSR)) == 0,
              Darwin.fsync(destinationDescriptor) == 0,
              Darwin.fsync(destinationParent.descriptor) == 0 else {
            throw DialogueVoiceRuntimeError.sourceChanged
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func requiredDigest(
        _ relativePath: String,
        in digests: [String: String]
    ) throws -> String {
        guard let digest = digests[relativePath] else {
            throw DialogueVoiceRuntimeError.copyFailed
        }
        return digest
    }

    private static func treeDigest(_ digests: [String: String]) -> String {
        var hasher = SHA256()
        for (relativePath, digest) in digests.sorted(by: { $0.key < $1.key }) {
            for field in [relativePath, digest] {
                var length = UInt64(field.utf8.count).bigEndian
                withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
                hasher.update(data: Data(field.utf8))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func openOrCreateDestinationParent(
        relativePath: String,
        stagingDescriptor: Int32
    ) throws -> (descriptor: Int32, name: String) {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DialogueVoiceRuntimeError.invalidSource
        }
        var current = Darwin.dup(stagingDescriptor)
        guard current >= 0 else { throw DialogueVoiceRuntimeError.copyFailed }
        for component in components.dropLast() {
            let opened = component.withCString {
                Darwin.openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            if opened >= 0 {
                Darwin.close(current)
                current = opened
                continue
            }
            guard errno == ENOENT else {
                Darwin.close(current)
                throw DialogueVoiceRuntimeError.copyFailed
            }
            let mkdirResult = component.withCString { Darwin.mkdirat(current, $0, 0o700) }
            guard mkdirResult == 0 || errno == EEXIST else {
                Darwin.close(current)
                throw DialogueVoiceRuntimeError.copyFailed
            }
            let created = component.withCString {
                Darwin.openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            Darwin.close(current)
            guard created >= 0 else { throw DialogueVoiceRuntimeError.copyFailed }
            current = created
        }
        return (current, String(components.last!))
    }

    private func boundedRead(
        relativePath: String,
        rootDescriptor: Int32,
        maximum: Int
    ) throws -> Data {
        let descriptor = try openSourceFile(relativePath: relativePath, rootDescriptor: rootDescriptor)
        defer { Darwin.close(descriptor) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(maximum + 1, 65_536))
        while data.count <= maximum {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw DialogueVoiceRuntimeError.invalidSource
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard !data.isEmpty, data.count <= maximum else { throw DialogueVoiceRuntimeError.invalidSource }
        return data
    }

    private func openSourceFile(relativePath: String, rootDescriptor: Int32) throws -> Int32 {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DialogueVoiceRuntimeError.invalidSource
        }
        var current = Darwin.dup(rootDescriptor)
        guard current >= 0 else { throw DialogueVoiceRuntimeError.invalidSource }
        for component in components.dropLast() {
            let next = component.withCString {
                Darwin.openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            Darwin.close(current)
            guard next >= 0 else { throw DialogueVoiceRuntimeError.sourceChanged }
            current = next
        }
        let file = components.last!.withCString {
            Darwin.openat(current, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        Darwin.close(current)
        guard file >= 0 else { throw DialogueVoiceRuntimeError.sourceChanged }
        var status = stat()
        guard Darwin.fstat(file, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_size > 0 else {
            Darwin.close(file)
            throw DialogueVoiceRuntimeError.invalidSource
        }
        return file
    }

}

enum VoxCPM2SnapshotTree {
    static let maximumBytes: UInt64 = 8_589_934_592
    static let maximumEntryCount = 100_000
    static let maximumDepth = 32
    static let requiredFiles = ["model.safetensors", "audiovae.pth", "config.json"]
    static let tokenizerCandidates = [
        "tokenization_voxcpm2.py", "tokenizer.json", "tokenizer_config.json",
    ]

    enum ModelLayout: Equatable {
        case root
        case nested
    }

    struct Snapshot: Equatable {
        let digest: String
        let identityTokens: [String]
        let usesNestedModelRoot: Bool
    }

    private struct Entry {
        let relativePath: String
        let size: UInt64
        let digest: String
    }

    private struct Budget {
        var bytes: UInt64 = 0
        var entries = 0
    }

    static func checkedEntryCount(_ value: Int) throws -> Int {
        guard value <= maximumEntryCount else {
            throw DialogueVoiceRuntimeError.sourceTooLarge
        }
        return value
    }

    static func checkedDepth(_ value: Int) throws -> Int {
        guard value <= maximumDepth else {
            throw DialogueVoiceRuntimeError.invalidSource
        }
        return value
    }

    static func validatedModelLayout(relativePaths: [String]) throws -> ModelLayout {
        let names = Set(relativePaths)
        let rootComplete = requiredFiles.allSatisfy(names.contains)
            && tokenizerCandidates.contains(where: names.contains)
        let nestedComplete = requiredFiles.allSatisfy { names.contains("model/\($0)") }
            && tokenizerCandidates.contains { names.contains("model/\($0)") }
        guard rootComplete != nestedComplete else {
            throw DialogueVoiceRuntimeError.profileRejected
        }
        return nestedComplete ? .nested : .root
    }

    static func scan(
        rootDescriptor: Int32,
        hashChunkObserver: (@Sendable () -> Void)? = nil
    ) throws -> Snapshot {
        try Task.checkCancellation()
        var rootStatus = stat()
        guard Darwin.fstat(rootDescriptor, &rootStatus) == 0,
              rootStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw DialogueVoiceRuntimeError.invalidSource
        }
        let rootIdentity = DialogueVoiceFileIdentity(rootStatus)
        var budget = Budget()
        var entries: [Entry] = []
        try scanDirectory(
            descriptor: rootDescriptor,
            prefix: "",
            depth: 0,
            budget: &budget,
            entries: &entries,
            hashChunkObserver: hashChunkObserver
        )
        var finalRootStatus = stat()
        guard budget.bytes > 0,
              Darwin.fstat(rootDescriptor, &finalRootStatus) == 0,
              DialogueVoiceFileIdentity(finalRootStatus) == rootIdentity else {
            throw DialogueVoiceRuntimeError.sourceChanged
        }
        let sorted = entries.sorted { $0.relativePath < $1.relativePath }
        let layout = try validatedModelLayout(relativePaths: sorted.map(\.relativePath))
        let components = sorted.flatMap { [$0.relativePath, $0.digest] }
        let digest = Qwen3TTSProfileValidator.computeInputFingerprint(components: components)
        return Snapshot(
            digest: digest,
            identityTokens: ["root:\(rootIdentity.token)"] + sorted.map {
                "\($0.relativePath):\($0.size):\($0.digest)"
            },
            usesNestedModelRoot: layout == .nested
        )
    }

    private static func scanDirectory(
        descriptor: Int32,
        prefix: String,
        depth: Int,
        budget: inout Budget,
        entries: inout [Entry],
        hashChunkObserver: (@Sendable () -> Void)?
    ) throws {
        try Task.checkCancellation()
        _ = try checkedDepth(depth)
        var initialStatus = stat()
        guard Darwin.fstat(descriptor, &initialStatus) == 0,
              initialStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw DialogueVoiceRuntimeError.invalidSource
        }
        let initialIdentity = DialogueVoiceFileIdentity(initialStatus)
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0, let stream = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw DialogueVoiceRuntimeError.invalidSource
        }
        defer { Darwin.closedir(stream) }
        Darwin.rewinddir(stream)
        while let entry = Darwin.readdir(stream) {
            try Task.checkCancellation()
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            guard !name.isEmpty,
                  !name.contains("/"),
                  !name.contains("\\"),
                  !name.contains(":") else {
                throw DialogueVoiceRuntimeError.invalidSource
            }
            budget.entries += 1
            _ = try checkedEntryCount(budget.entries)
            let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"
            var status = stat()
            guard name.withCString({
                Darwin.fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }) == 0 else {
                throw DialogueVoiceRuntimeError.invalidSource
            }
            let kind = status.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFDIR) {
                let child = name.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard child >= 0 else { throw DialogueVoiceRuntimeError.invalidSource }
                var opened = stat()
                guard Darwin.fstat(child, &opened) == 0,
                      DialogueVoiceFileIdentity(opened) == DialogueVoiceFileIdentity(status) else {
                    Darwin.close(child)
                    throw DialogueVoiceRuntimeError.sourceChanged
                }
                do {
                    try scanDirectory(
                        descriptor: child,
                        prefix: relative,
                        depth: depth + 1,
                        budget: &budget,
                        entries: &entries,
                        hashChunkObserver: hashChunkObserver
                    )
                    Darwin.close(child)
                } catch {
                    Darwin.close(child)
                    throw error
                }
                continue
            }
            guard kind == mode_t(S_IFREG), status.st_size > 0 else {
                throw DialogueVoiceRuntimeError.invalidSource
            }
            let size = UInt64(status.st_size)
            let (next, overflow) = budget.bytes.addingReportingOverflow(size)
            guard !overflow, next <= maximumBytes else {
                throw DialogueVoiceRuntimeError.sourceTooLarge
            }
            budget.bytes = next
            let fileDescriptor = name.withCString {
                Darwin.openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard fileDescriptor >= 0 else {
                throw DialogueVoiceRuntimeError.invalidSource
            }
            var openedStatus = stat()
            let expectedIdentity = DialogueVoiceFileIdentity(status)
            guard Darwin.fstat(fileDescriptor, &openedStatus) == 0,
                  DialogueVoiceFileIdentity(openedStatus) == expectedIdentity else {
                Darwin.close(fileDescriptor)
                throw DialogueVoiceRuntimeError.sourceChanged
            }
            do {
                let digest = try hashRegularFile(
                    descriptor: fileDescriptor,
                    expectedIdentity: expectedIdentity,
                    expectedSize: size,
                    hashChunkObserver: hashChunkObserver
                )
                Darwin.close(fileDescriptor)
                entries.append(Entry(
                    relativePath: relative,
                    size: size,
                    digest: digest
                ))
            } catch {
                Darwin.close(fileDescriptor)
                throw error
            }
        }
        var finalStatus = stat()
        guard Darwin.fstat(descriptor, &finalStatus) == 0,
              DialogueVoiceFileIdentity(finalStatus) == initialIdentity else {
            throw DialogueVoiceRuntimeError.sourceChanged
        }
    }

    private static func hashRegularFile(
        descriptor: Int32,
        expectedIdentity: DialogueVoiceFileIdentity,
        expectedSize: UInt64,
        hashChunkObserver: (@Sendable () -> Void)?
    ) throws -> String {
        var hasher = SHA256()
        var total: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw DialogueVoiceRuntimeError.invalidSource
            }
            total += UInt64(count)
            guard total <= expectedSize else {
                throw DialogueVoiceRuntimeError.sourceChanged
            }
            hasher.update(data: Data(buffer.prefix(count)))
            hashChunkObserver?()
        }
        var finalStatus = stat()
        guard total == expectedSize,
              Darwin.fstat(descriptor, &finalStatus) == 0,
              DialogueVoiceFileIdentity(finalStatus) == expectedIdentity else {
            throw DialogueVoiceRuntimeError.sourceChanged
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private enum VoxCPM2ManagedStorage {
    private static let packageComponents = ["voice", "packages", "voxcpm2"]

    static func openPackagesRoot(
        applicationSupportRoot: URL,
        createIfMissing: Bool
    ) throws -> Int32 {
        guard applicationSupportRoot.isFileURL else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        let standardizedRoot = applicationSupportRoot.standardizedFileURL
        var namedRootStatus = stat()
        guard Darwin.lstat(standardizedRoot.path, &namedRootStatus) == 0,
              namedRootStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              namedRootStatus.st_uid == Darwin.geteuid() else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        var current = Darwin.open(
            standardizedRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard current >= 0 else { throw DialogueVoiceRuntimeError.invalidManagedPath }
        var openedRootStatus = stat()
        guard Darwin.fstat(current, &openedRootStatus) == 0,
              DialogueVoiceDirectoryIdentity(openedRootStatus)
                == DialogueVoiceDirectoryIdentity(namedRootStatus) else {
            Darwin.close(current)
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }

        for component in packageComponents {
            var namedStatus = stat()
            let statusResult = component.withCString {
                Darwin.fstatat(current, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
            }
            if statusResult != 0 {
                guard createIfMissing, errno == ENOENT,
                      component.withCString({ Darwin.mkdirat(current, $0, 0o700) }) == 0,
                      Darwin.fsync(current) == 0,
                      component.withCString({
                          Darwin.fstatat(current, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
                      }) == 0 else {
                    Darwin.close(current)
                    throw DialogueVoiceRuntimeError.invalidManagedPath
                }
            }
            guard namedStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  namedStatus.st_uid == Darwin.geteuid() else {
                Darwin.close(current)
                throw DialogueVoiceRuntimeError.invalidManagedPath
            }
            let next = component.withCString {
                Darwin.openat(
                    current,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard next >= 0 else {
                Darwin.close(current)
                throw DialogueVoiceRuntimeError.invalidManagedPath
            }
            var openedStatus = stat()
            guard Darwin.fstat(next, &openedStatus) == 0,
                  DialogueVoiceDirectoryIdentity(openedStatus)
                    == DialogueVoiceDirectoryIdentity(namedStatus),
                  Darwin.fchmod(next, mode_t(S_IRWXU)) == 0,
                  Darwin.fsync(next) == 0 else {
                Darwin.close(next)
                Darwin.close(current)
                throw DialogueVoiceRuntimeError.invalidManagedPath
            }
            Darwin.close(current)
            current = next
        }
        return current
    }

    static func withOpenSnapshot<T>(
        relativePath: String,
        applicationSupportRoot: URL,
        _ body: (Int32, URL) throws -> T
    ) throws -> T {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 4,
              components[0] == "voice",
              components[1] == "packages",
              components[2] == "voxcpm2" else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        let leaf = String(components[3])
        guard UUID(uuidString: leaf) != nil, leaf == leaf.lowercased() else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        let packagesDescriptor = try openPackagesRoot(
            applicationSupportRoot: applicationSupportRoot,
            createIfMissing: false
        )
        defer { Darwin.close(packagesDescriptor) }
        var namedStatus = stat()
        guard leaf.withCString({
            Darwin.fstatat(packagesDescriptor, $0, &namedStatus, AT_SYMLINK_NOFOLLOW)
        }) == 0,
              namedStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        let snapshotDescriptor = leaf.withCString {
            Darwin.openat(
                packagesDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard snapshotDescriptor >= 0 else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        defer { Darwin.close(snapshotDescriptor) }
        var openedStatus = stat()
        let expectedIdentity = DialogueVoiceDirectoryIdentity(namedStatus)
        guard Darwin.fstat(snapshotDescriptor, &openedStatus) == 0,
              DialogueVoiceDirectoryIdentity(openedStatus) == expectedIdentity else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        let url = applicationSupportRoot.standardizedFileURL
            .appendingPathComponent(relativePath, isDirectory: true)
            .standardizedFileURL
        let result = try body(snapshotDescriptor, url)
        var finalNamedStatus = stat()
        guard leaf.withCString({
            Darwin.fstatat(packagesDescriptor, $0, &finalNamedStatus, AT_SYMLINK_NOFOLLOW)
        }) == 0,
              DialogueVoiceDirectoryIdentity(finalNamedStatus) == expectedIdentity else {
            throw DialogueVoiceRuntimeError.sourceChanged
        }
        let verificationPackages = try openPackagesRoot(
            applicationSupportRoot: applicationSupportRoot,
            createIfMissing: false
        )
        defer { Darwin.close(verificationPackages) }
        var verificationStatus = stat()
        guard leaf.withCString({
            Darwin.fstatat(verificationPackages, $0, &verificationStatus, AT_SYMLINK_NOFOLLOW)
        }) == 0,
              DialogueVoiceDirectoryIdentity(verificationStatus) == expectedIdentity else {
            throw DialogueVoiceRuntimeError.sourceChanged
        }
        return result
    }
}

struct VoxCPM2ImportedSnapshot: Equatable, Sendable {
    let snapshotRootRelativePath: String
    let treeSHA256: String
}

/// Copies a complete VoxCPM2 handover into Statelet's private Application
/// Support tree before it can be persisted or executed. All source traversal
/// and reads are descriptor-bound so a path replacement cannot redirect an
/// in-progress import.
struct VoxCPM2SnapshotInstaller: Sendable {
    private struct SourceFile: Equatable {
        let relativePath: String
        let identity: DialogueVoiceFileIdentity
        let size: UInt64
    }

    static let maximumPackageBytes = VoxCPM2SnapshotTree.maximumBytes
    private static let freeSpaceReserveBytes: UInt64 = 268_435_456

    let applicationSupportRoot: URL
    private let afterPublish: (@Sendable () throws -> Void)?

    init(
        applicationSupportRoot: URL,
        afterPublish: (@Sendable () throws -> Void)? = nil
    ) {
        self.applicationSupportRoot = applicationSupportRoot
        self.afterPublish = afterPublish
    }

    static func managedRelativePaths(destinationToken token: String) throws -> (
        destination: String,
        staging: String
    ) {
        guard UUID(uuidString: token) != nil, token == token.lowercased() else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        return (
            destination: "voice/packages/voxcpm2/\(token)",
            staging: "voice/packages/voxcpm2/.\(token).partial"
        )
    }

    static func checkedAggregateSize(
        _ sizes: some Sequence<UInt64>,
        maximum: UInt64 = maximumPackageBytes
    ) throws -> UInt64 {
        var total: UInt64 = 0
        for size in sizes {
            try Task.checkCancellation()
            let (next, overflow) = total.addingReportingOverflow(size)
            guard !overflow, next <= maximum else {
                throw DialogueVoiceRuntimeError.sourceTooLarge
            }
            total = next
        }
        guard total > 0 else { throw DialogueVoiceRuntimeError.sourceTooLarge }
        return total
    }

    func install(
        sourceURL: URL,
        destinationToken: String? = nil
    ) throws -> VoxCPM2ImportedSnapshot {
        try Task.checkCancellation()
        guard sourceURL.isFileURL,
              sourceURL.host.map({ $0.isEmpty || $0 == "localhost" }) ?? true else {
            throw DialogueVoiceRuntimeError.invalidSource
        }
        let rootDescriptor = Darwin.open(
            sourceURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else { throw DialogueVoiceRuntimeError.invalidSource }
        defer { Darwin.close(rootDescriptor) }
        var rootStatus = stat()
        guard Darwin.fstat(rootDescriptor, &rootStatus) == 0,
              rootStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw DialogueVoiceRuntimeError.invalidSource
        }
        let rootIdentity = DialogueVoiceFileIdentity(rootStatus)
        let files = try enumerate(rootDescriptor)
        let total = try Self.checkedAggregateSize(files.lazy.map(\.size))
        try validateRequiredFiles(files.map(\.relativePath))

        let available = try applicationSupportRoot.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage ?? 0
        let requiredCapacity = total.addingReportingOverflow(Self.freeSpaceReserveBytes)
        guard !requiredCapacity.overflow,
              available > 0,
              UInt64(available) > requiredCapacity.partialValue else {
            throw DialogueVoiceRuntimeError.sourceTooLarge
        }

        let packagesDescriptor = try VoxCPM2ManagedStorage.openPackagesRoot(
            applicationSupportRoot: applicationSupportRoot,
            createIfMissing: true
        )
        defer { Darwin.close(packagesDescriptor) }
        var packagesStatus = stat()
        guard Darwin.fstat(packagesDescriptor, &packagesStatus) == 0,
              packagesStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw DialogueVoiceRuntimeError.copyFailed
        }
        let packagesIdentity = DialogueVoiceDirectoryIdentity(packagesStatus)
        let token = destinationToken ?? UUID().uuidString.lowercased()
        let managedPaths = try Self.managedRelativePaths(destinationToken: token)
        let stageName = ".\(token).partial"
        let destinationName = token
        guard stageName.withCString({ Darwin.mkdirat(packagesDescriptor, $0, 0o700) }) == 0,
              Darwin.fsync(packagesDescriptor) == 0 else {
            throw DialogueVoiceRuntimeError.copyFailed
        }
        let stageDescriptor = stageName.withCString {
            Darwin.openat(
                packagesDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard stageDescriptor >= 0 else {
            stageName.withCString { _ = Darwin.unlinkat(packagesDescriptor, $0, AT_REMOVEDIR) }
            throw DialogueVoiceRuntimeError.copyFailed
        }
        defer { Darwin.close(stageDescriptor) }
        var stageStatus = stat()
        guard Darwin.fstat(stageDescriptor, &stageStatus) == 0,
              stageStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw DialogueVoiceRuntimeError.copyFailed
        }
        let stageIdentity = DialogueVoiceDirectoryIdentity(stageStatus)
        var cleanupPath = managedPaths.staging
        do {
            var stagedDigests: [String: String] = [:]
            for file in files {
                try Task.checkCancellation()
                stagedDigests[file.relativePath] = try copyRegularFile(
                    file,
                    rootDescriptor: rootDescriptor,
                    stagingDescriptor: stageDescriptor
                )
            }
            let finalFiles = try enumerate(rootDescriptor)
            var finalRootStatus = stat()
            guard finalFiles == files,
                  Darwin.fstat(rootDescriptor, &finalRootStatus) == 0,
                  DialogueVoiceFileIdentity(finalRootStatus) == rootIdentity,
                  Darwin.fsync(stageDescriptor) == 0 else {
                throw DialogueVoiceRuntimeError.sourceChanged
            }
            let treeDigest = Self.treeDigest(stagedDigests)

            var finalPackagesStatus = stat()
            var finalStageStatus = stat()
            var namedStageStatus = stat()
            guard Darwin.fstat(packagesDescriptor, &finalPackagesStatus) == 0,
                  DialogueVoiceDirectoryIdentity(finalPackagesStatus) == packagesIdentity,
                  Darwin.fstat(stageDescriptor, &finalStageStatus) == 0,
                  DialogueVoiceDirectoryIdentity(finalStageStatus) == stageIdentity,
                  stageName.withCString({
                      Darwin.fstatat(packagesDescriptor, $0, &namedStageStatus, AT_SYMLINK_NOFOLLOW)
                  }) == 0,
                  DialogueVoiceDirectoryIdentity(namedStageStatus) == stageIdentity else {
                throw DialogueVoiceRuntimeError.copyFailed
            }
            guard stageName.withCString({ stagePointer in
                destinationName.withCString { destinationPointer in
                    Darwin.renameatx_np(
                        packagesDescriptor,
                        stagePointer,
                        packagesDescriptor,
                        destinationPointer,
                        UInt32(RENAME_EXCL)
                    )
                }
            }) == 0 else {
                throw DialogueVoiceRuntimeError.copyFailed
            }
            cleanupPath = managedPaths.destination
            try afterPublish?()
            guard Darwin.fsync(packagesDescriptor) == 0 else {
                throw DialogueVoiceRuntimeError.copyFailed
            }
            var publishedStatus = stat()
            guard destinationName.withCString({
                Darwin.fstatat(packagesDescriptor, $0, &publishedStatus, AT_SYMLINK_NOFOLLOW)
            }) == 0,
                  DialogueVoiceDirectoryIdentity(publishedStatus) == stageIdentity else {
                throw DialogueVoiceRuntimeError.copyFailed
            }
            return VoxCPM2ImportedSnapshot(
                snapshotRootRelativePath: managedPaths.destination,
                treeSHA256: treeDigest
            )
        } catch {
            do {
                try removeManagedPackage(relativePath: cleanupPath)
            } catch {
                throw DialogueVoiceRuntimeError.copyFailed
            }
            throw error
        }
    }

    func removeManagedPackage(relativePath: String) throws {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 4,
              components[0] == "voice",
              components[1] == "packages",
              components[2] == "voxcpm2" else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        let leaf = String(components[3])
        let token: String
        if leaf.hasPrefix("."), leaf.hasSuffix(".partial") {
            token = String(leaf.dropFirst().dropLast(".partial".count))
        } else {
            token = leaf
        }
        guard UUID(uuidString: token) != nil, token == token.lowercased() else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        _ = try DialogueVoiceAssetInstaller.removeManagedDirectory(
            relativePath: relativePath,
            root: applicationSupportRoot,
            maximumBytes: Self.maximumPackageBytes
        )
    }

    private func validateRequiredFiles(_ relativePaths: [String]) throws {
        _ = try VoxCPM2SnapshotTree.validatedModelLayout(relativePaths: relativePaths)
    }

    private func enumerate(_ rootDescriptor: Int32) throws -> [SourceFile] {
        var result: [SourceFile] = []
        var entryCount = 0
        try enumerateDirectory(
            descriptor: rootDescriptor,
            prefix: "",
            depth: 0,
            entryCount: &entryCount,
            result: &result
        )
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    private func enumerateDirectory(
        descriptor: Int32,
        prefix: String,
        depth: Int,
        entryCount: inout Int,
        result: inout [SourceFile]
    ) throws {
        try Task.checkCancellation()
        guard depth <= VoxCPM2SnapshotTree.maximumDepth else {
            throw DialogueVoiceRuntimeError.invalidSource
        }
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0, let stream = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw DialogueVoiceRuntimeError.invalidSource
        }
        defer { Darwin.closedir(stream) }
        Darwin.rewinddir(stream)
        while let entry = Darwin.readdir(stream) {
            try Task.checkCancellation()
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            guard !name.isEmpty,
                  !name.contains("/"),
                  !name.contains("\\"),
                  !name.contains(":") else {
                throw DialogueVoiceRuntimeError.invalidSource
            }
            entryCount += 1
            guard entryCount <= VoxCPM2SnapshotTree.maximumEntryCount else {
                throw DialogueVoiceRuntimeError.sourceTooLarge
            }
            let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"
            var status = stat()
            guard name.withCString({
                Darwin.fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
            }) == 0 else {
                throw DialogueVoiceRuntimeError.invalidSource
            }
            let kind = status.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFDIR) {
                let child = name.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard child >= 0 else { throw DialogueVoiceRuntimeError.invalidSource }
                defer { Darwin.close(child) }
                var opened = stat()
                guard Darwin.fstat(child, &opened) == 0,
                      DialogueVoiceFileIdentity(opened) == DialogueVoiceFileIdentity(status) else {
                    throw DialogueVoiceRuntimeError.sourceChanged
                }
                try enumerateDirectory(
                    descriptor: child,
                    prefix: relative,
                    depth: depth + 1,
                    entryCount: &entryCount,
                    result: &result
                )
                continue
            }
            guard kind == mode_t(S_IFREG), status.st_size > 0 else {
                throw DialogueVoiceRuntimeError.invalidSource
            }
            result.append(SourceFile(
                relativePath: relative,
                identity: DialogueVoiceFileIdentity(status),
                size: UInt64(status.st_size)
            ))
        }
    }

    private func copyRegularFile(
        _ source: SourceFile,
        rootDescriptor: Int32,
        stagingDescriptor: Int32
    ) throws -> String {
        try Task.checkCancellation()
        let sourceDescriptor = try openSourceFile(
            relativePath: source.relativePath,
            rootDescriptor: rootDescriptor
        )
        defer { Darwin.close(sourceDescriptor) }
        var sourceStatus = stat()
        guard Darwin.fstat(sourceDescriptor, &sourceStatus) == 0,
              DialogueVoiceFileIdentity(sourceStatus) == source.identity else {
            throw DialogueVoiceRuntimeError.sourceChanged
        }
        let destinationParent = try openOrCreateDestinationParent(
            relativePath: source.relativePath,
            stagingDescriptor: stagingDescriptor
        )
        defer { Darwin.close(destinationParent.descriptor) }
        let destinationDescriptor = destinationParent.name.withCString {
            Darwin.openat(
                destinationParent.descriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard destinationDescriptor >= 0 else {
            throw DialogueVoiceRuntimeError.copyFailed
        }
        defer { Darwin.close(destinationDescriptor) }
        var copied: UInt64 = 0
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(sourceDescriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw DialogueVoiceRuntimeError.copyFailed
            }
            var offset = 0
            while offset < count {
                try Task.checkCancellation()
                let written = buffer.withUnsafeBytes {
                    Darwin.write(
                        destinationDescriptor,
                        $0.baseAddress?.advanced(by: offset),
                        count - offset
                    )
                }
                guard written > 0 else {
                    if written < 0, errno == EINTR { continue }
                    throw DialogueVoiceRuntimeError.copyFailed
                }
                offset += written
            }
            copied += UInt64(count)
            guard copied <= source.size else {
                throw DialogueVoiceRuntimeError.sourceChanged
            }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        var finalSource = stat()
        guard copied == source.size,
              Darwin.fstat(sourceDescriptor, &finalSource) == 0,
              DialogueVoiceFileIdentity(finalSource) == source.identity,
              Darwin.fchmod(destinationDescriptor, mode_t(S_IRUSR | S_IWUSR)) == 0,
              Darwin.fsync(destinationDescriptor) == 0,
              Darwin.fsync(destinationParent.descriptor) == 0 else {
            throw DialogueVoiceRuntimeError.sourceChanged
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func openSourceFile(
        relativePath: String,
        rootDescriptor: Int32
    ) throws -> Int32 {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DialogueVoiceRuntimeError.invalidSource
        }
        var current = Darwin.dup(rootDescriptor)
        guard current >= 0 else { throw DialogueVoiceRuntimeError.invalidSource }
        for component in components.dropLast() {
            try Task.checkCancellation()
            let next = component.withCString {
                Darwin.openat(
                    current,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            Darwin.close(current)
            guard next >= 0 else { throw DialogueVoiceRuntimeError.sourceChanged }
            current = next
        }
        let file = components.last!.withCString {
            Darwin.openat(
                current,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        Darwin.close(current)
        guard file >= 0 else { throw DialogueVoiceRuntimeError.sourceChanged }
        var status = stat()
        guard Darwin.fstat(file, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_size > 0 else {
            Darwin.close(file)
            throw DialogueVoiceRuntimeError.invalidSource
        }
        return file
    }

    private func openOrCreateDestinationParent(
        relativePath: String,
        stagingDescriptor: Int32
    ) throws -> (descriptor: Int32, name: String) {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DialogueVoiceRuntimeError.invalidSource
        }
        var current = Darwin.dup(stagingDescriptor)
        guard current >= 0 else { throw DialogueVoiceRuntimeError.copyFailed }
        for component in components.dropLast() {
            try Task.checkCancellation()
            let opened = component.withCString {
                Darwin.openat(
                    current,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            if opened >= 0 {
                Darwin.close(current)
                current = opened
                continue
            }
            guard errno == ENOENT else {
                Darwin.close(current)
                throw DialogueVoiceRuntimeError.copyFailed
            }
            let mkdirResult = component.withCString {
                Darwin.mkdirat(current, $0, 0o700)
            }
            guard mkdirResult == 0 || errno == EEXIST else {
                Darwin.close(current)
                throw DialogueVoiceRuntimeError.copyFailed
            }
            if mkdirResult == 0, Darwin.fsync(current) != 0 {
                Darwin.close(current)
                throw DialogueVoiceRuntimeError.copyFailed
            }
            let created = component.withCString {
                Darwin.openat(
                    current,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            Darwin.close(current)
            guard created >= 0 else { throw DialogueVoiceRuntimeError.copyFailed }
            current = created
        }
        return (current, String(components.last!))
    }

    private static func treeDigest(_ digests: [String: String]) -> String {
        let components = digests.sorted(by: { $0.key < $1.key }).flatMap {
            [$0.key, $0.value]
        }
        return Qwen3TTSProfileValidator.computeInputFingerprint(components: components)
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
            runtimeIdentity: runtimeAfter,
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
            runtimeIdentity: runtime,
            identityTokens: packageIdentities + [runtime.stableIdentityToken],
            treeSHA256: profile.packageTreeSHA256
        )
    }

    static func validatePythonExecutable(at url: URL) throws -> Qwen3TTSPythonRuntimeIdentity {
        let control = QwenRuntimeValidationControl(
            deadlineUptime: ProcessInfo.processInfo.systemUptime + 120,
            isCancelled: { Task<Never, Never>.isCancelled }
        )
        return try validatePythonRuntimeAuthority(at: url, control: control).identity
    }

    static func validatePythonExecutable(
        at url: URL,
        control: QwenRuntimeValidationControl
    ) throws -> Qwen3TTSPythonRuntimeIdentity {
        try validatePythonRuntimeAuthority(at: url, control: control).identity
    }

    static func validatedRuntimeSearchPlan(
        at url: URL,
        environment: [String: String],
        control: QwenRuntimeValidationControl
    ) throws -> Qwen3TTSRuntimeSearchPlan {
        try control.check()
        try validatePythonLaunchEnvironment(environment)
        let selected = try validatePythonRuntimeAuthority(at: url, control: control)
        var orderedRoots = selected.layout.coreRoots
        var visitedTrees = Set<String>()
        var ignoredDiscoveries: [URL] = []
        for root in orderedRoots {
            try validatePotentialPythonSearchRootAuthority(
                root,
                visitedTrees: &visitedTrees,
                discoveredSearchRoots: &ignoredDiscoveries,
                control: control
            )
        }

        if let virtualEnvironmentRoot = selected.layout.virtualEnvironmentRoot {
            try appendPythonSiteRoots(
                at: virtualEnvironmentRoot,
                version: selected.layout.version,
                to: &orderedRoots,
                visitedTrees: &visitedTrees,
                control: control
            )
        }
        if selected.layout.virtualEnvironmentRoot == nil
            || selected.layout.includesBaseSitePackages {
            try appendPythonSiteRoots(
                at: selected.layout.baseRoot,
                version: selected.layout.version,
                to: &orderedRoots,
                visitedTrees: &visitedTrees,
                control: control
            )
        }

        var seen = Set<String>()
        let roots = orderedRoots.compactMap { root -> String? in
            let path = root.standardizedFileURL.path
            guard seen.insert(path).inserted else { return nil }
            return path
        }
        guard !roots.isEmpty,
              roots.count <= 4_096,
              roots.reduce(0, { $0 + $1.utf8.count }) <= 262_144 else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        return Qwen3TTSRuntimeSearchPlan(
            pythonHome: selected.layout.baseRoot.path,
            roots: roots
        )
    }

    static func validateLaunchResource(
        at url: URL,
        maximumBytes: UInt64,
        control: QwenRuntimeValidationControl? = nil
    ) throws -> String {
        try checkValidation(control)
        try validateRuntimePathAuthority(url, control: control)
        let digest = try sha256RegularFile(
            url,
            maximumBytes: maximumBytes,
            control: control
        )
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        return DialogueVoiceFileIdentity(status).token + ":" + digest
    }

    static func validateLaunchDirectory(
        at url: URL,
        control: QwenRuntimeValidationControl? = nil
    ) throws {
        try checkValidation(control)
        try validateRuntimePathAuthority(url, control: control)
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
    }

    private struct PythonRuntimeAuthorityValidation {
        let identity: Qwen3TTSPythonRuntimeIdentity
        let layout: PythonRuntimeLayout
    }

    private struct PythonRuntimeLayout {
        let version: String
        let baseRoot: URL
        let virtualEnvironmentRoot: URL?
        let includesBaseSitePackages: Bool
        let coreRoots: [URL]
    }

    private static func validatePythonRuntimeAuthority(
        at url: URL,
        control: QwenRuntimeValidationControl
    ) throws -> PythonRuntimeAuthorityValidation {
        try control.check()
        guard url.isFileURL,
              url.host.map({ $0.isEmpty || $0 == "localhost" }) ?? true else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        let invocation = url.standardizedFileURL
        guard invocation.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: invocation.path) else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        let launcher = try pythonLauncherIdentity(invocation, control: control)
        try validateRuntimePathAuthority(invocation, control: control)
        try validateRuntimePathAuthority(launcher.target, control: control)
        let authenticated = try authenticatedPythonLayout(
            invocation: invocation,
            finalTarget: launcher.target,
            control: control
        )
        var visitedEnvironments = Set<String>()
        var visitedTrees = Set<String>()
        var searchRoots: [URL] = []
        try validatePythonEnvironmentAuthority(
            invocation,
            visitedEnvironments: &visitedEnvironments,
            visitedTrees: &visitedTrees,
            discoveredSearchRoots: &searchRoots,
            control: control
        )
        try validatePythonEnvironmentAuthority(
            launcher.target,
            visitedEnvironments: &visitedEnvironments,
            visitedTrees: &visitedTrees,
            discoveredSearchRoots: &searchRoots,
            control: control
        )
        let digest = try sha256RegularFile(
            launcher.target,
            maximumBytes: 1_073_741_824,
            control: control
        )
        let launcherAfter = try pythonLauncherIdentity(invocation, control: control)
        guard launcher == launcherAfter else {
            throw DialogueVoiceRuntimeError.sourceChanged
        }
        try validateRuntimePathAuthority(invocation, control: control)
        try validateRuntimePathAuthority(launcherAfter.target, control: control)
        visitedEnvironments.removeAll(keepingCapacity: true)
        visitedTrees.removeAll(keepingCapacity: true)
        searchRoots.removeAll(keepingCapacity: true)
        try validatePythonEnvironmentAuthority(
            invocation,
            visitedEnvironments: &visitedEnvironments,
            visitedTrees: &visitedTrees,
            discoveredSearchRoots: &searchRoots,
            control: control
        )
        try validatePythonEnvironmentAuthority(
            launcherAfter.target,
            visitedEnvironments: &visitedEnvironments,
            visitedTrees: &visitedTrees,
            discoveredSearchRoots: &searchRoots,
            control: control
        )
        let authenticatedAfter = try authenticatedPythonLayout(
            invocation: invocation,
            finalTarget: launcherAfter.target,
            control: control
        )
        guard authenticated.layout.version == authenticatedAfter.layout.version,
              authenticated.layout.baseRoot == authenticatedAfter.layout.baseRoot,
              authenticated.layout.virtualEnvironmentRoot
                == authenticatedAfter.layout.virtualEnvironmentRoot,
              authenticated.layout.includesBaseSitePackages
                == authenticatedAfter.layout.includesBaseSitePackages,
              authenticated.dependencyToken == authenticatedAfter.dependencyToken else {
            throw DialogueVoiceRuntimeError.sourceChanged
        }
        return PythonRuntimeAuthorityValidation(
            identity: Qwen3TTSPythonRuntimeIdentity(
                invocationPath: invocation.path,
                finalTargetSHA256: digest,
                stableIdentityToken: launcherAfter.token + ":" + authenticatedAfter.dependencyToken
            ),
            layout: authenticatedAfter.layout
        )
    }

    private static let maximumPythonEnvironmentEntries = 500_000
    private static let maximumRuntimeAuthoritySymlinkResolutionSteps = 32

    private static func checkValidation(_ control: QwenRuntimeValidationControl?) throws {
        if let control { try control.check() }
        else { try Task.checkCancellation() }
    }

    /// A selected runtime may be mutable by its owner, but it must never be
    /// replaceable or editable by another local principal between validation
    /// and launch. Root and the current effective user are the only accepted
    /// owners; group/other-writable entries and write-granting ACLs are rejected.
    private static func validateRuntimePathAuthority(
        _ url: URL,
        control: QwenRuntimeValidationControl? = nil
    ) throws {
        var activeSymlinks = Set<String>()
        try validateRuntimePathAuthority(
            url,
            control: control,
            activeSymlinks: &activeSymlinks,
            remainingSymlinkSteps: maximumRuntimeAuthoritySymlinkResolutionSteps
        )
    }

    private static func validateRuntimePathAuthority(
        _ url: URL,
        control: QwenRuntimeValidationControl?,
        activeSymlinks: inout Set<String>,
        remainingSymlinkSteps: Int
    ) throws {
        try checkValidation(control)
        let effectiveUser = Darwin.geteuid()
        let components = url.standardized.pathComponents
        guard components.first == "/" else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        if components.count == 1 {
            var rootStatus = stat()
            guard Darwin.lstat("/", &rootStatus) == 0,
                  rootStatus.st_uid == 0,
                  rootStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  rootStatus.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
                  try !hasWriteGrantingACL(at: URL(fileURLWithPath: "/"), isSymbolicLink: false) else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
            return
        }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for (index, component) in components.dropFirst().enumerated() {
            try checkValidation(control)
            current.appendPathComponent(component)
            var status = stat()
            guard Darwin.lstat(current.path, &status) == 0,
                  status.st_uid == 0 || status.st_uid == effectiveUser,
                  try !hasWriteGrantingACL(
                      at: current,
                      isSymbolicLink: status.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
                  ) else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
            let kind = status.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFLNK) {
                let symlinkPath = current.standardizedFileURL.path
                guard remainingSymlinkSteps > 0,
                      activeSymlinks.insert(symlinkPath).inserted else {
                    throw DialogueVoiceRuntimeError.inferenceUnavailable
                }
                defer { activeSymlinks.remove(symlinkPath) }
                let resolved = try resolveAuthoritySymlink(at: current)
                guard resolved.path != current.path else {
                    throw DialogueVoiceRuntimeError.inferenceUnavailable
                }
                try validateRuntimePathAuthority(
                    resolved,
                    control: control,
                    activeSymlinks: &activeSymlinks,
                    remainingSymlinkSteps: remainingSymlinkSteps - 1
                )
                continue
            }
            guard status.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0 else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
            let isLeaf = index == components.count - 2
            guard isLeaf
                    ? kind == mode_t(S_IFREG) || kind == mode_t(S_IFDIR)
                    : kind == mode_t(S_IFDIR) else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
        }
    }

    static func isSealedSystemRuntimePath(_ path: String) -> Bool {
        if path == "/System" || path.hasPrefix("/System/") { return true }
        if path == "/usr" { return true }
        for root in ["/usr/bin", "/usr/lib", "/usr/libexec", "/usr/sbin", "/usr/share"] {
            if path == root || path.hasPrefix(root + "/") { return true }
        }
        return false
    }

    private static func hasWriteGrantingACL(
        at url: URL,
        isSymbolicLink: Bool
    ) throws -> Bool {
        errno = 0
        let accessControlList: acl_t? = url.path.withCString { path in
            isSymbolicLink
                ? Darwin.acl_get_link_np(path, ACL_TYPE_EXTENDED)
                : Darwin.acl_get_file(path, ACL_TYPE_EXTENDED)
        }
        guard let accessControlList else {
            let error = errno
            // Darwin reports ENOENT when an existing object has no extended
            // ACL. Every caller has already lstat'd the same authority path.
            if error == ENOENT || error == EOPNOTSUPP || error == ENOTSUP { return false }
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        defer { _ = Darwin.acl_free(UnsafeMutableRawPointer(accessControlList)) }

        let writePermissions: [acl_perm_t] = [
            ACL_WRITE_DATA,
            ACL_APPEND_DATA,
            ACL_DELETE,
            ACL_DELETE_CHILD,
            ACL_WRITE_ATTRIBUTES,
            ACL_WRITE_EXTATTRIBUTES,
            ACL_WRITE_SECURITY,
            ACL_CHANGE_OWNER,
        ]
        var entry: acl_entry_t?
        var result = Darwin.acl_get_entry(
            accessControlList,
            ACL_FIRST_ENTRY.rawValue,
            &entry
        )
        while result == 0 {
            guard let currentEntry = entry else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
            var tag = ACL_UNDEFINED_TAG
            var permissions: acl_permset_t?
            guard Darwin.acl_get_tag_type(currentEntry, &tag) == 0,
                  Darwin.acl_get_permset(currentEntry, &permissions) == 0,
                  let permissions else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
            if tag == ACL_EXTENDED_ALLOW {
                for permission in writePermissions {
                    let present = Darwin.acl_get_perm_np(permissions, permission)
                    guard present >= 0 else {
                        throw DialogueVoiceRuntimeError.inferenceUnavailable
                    }
                    if present == 1 { return true }
                }
            }
            result = Darwin.acl_get_entry(
                accessControlList,
                ACL_NEXT_ENTRY.rawValue,
                &entry
            )
        }
        guard result == -1, errno == EINVAL else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        return false
    }

    private static func resolveAuthoritySymlink(at url: URL) throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = Darwin.readlink(url.path, &buffer, Int(PATH_MAX))
        guard length > 0, length < Int(PATH_MAX) else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        let raw = String(
            decoding: buffer.prefix(length).map(UInt8.init(bitPattern:)),
            as: UTF8.self
        )
        let resolved = raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw).standardized
            : URL(
                fileURLWithPath: (url.deletingLastPathComponent().path as NSString)
                    .appendingPathComponent(raw)
            ).standardized
        guard resolved.path.hasPrefix("/") else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        return resolved
    }

    private struct AuthenticatedPythonLayout {
        let layout: PythonRuntimeLayout
        let dependencyToken: String
    }

    private struct MachOLoadPaths {
        var dependencies: [String]
        var runpaths: [String]
    }

    private static func authenticatedPythonLayout(
        invocation: URL,
        finalTarget: URL,
        control: QwenRuntimeValidationControl
    ) throws -> AuthenticatedPythonLayout {
        try control.check()
        let loadPaths = try pythonMachOLoadPaths(at: finalTarget, control: control)
        let pythonDependencies = loadPaths.dependencies.filter { raw in
            let name = (raw as NSString).lastPathComponent.lowercased()
            return name == "python"
                || name == "python3"
                || (name.hasPrefix("libpython") && name.hasSuffix(".dylib"))
        }
        guard !pythonDependencies.isEmpty else {
            // Reject shebang scripts, xcrun shims, and native wrappers which
            // do not directly load an authenticated Python runtime.
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }

        var resolvedDependencies: [URL] = []
        for dependency in pythonDependencies {
            var resolvedThisDependency = false
            for candidate in resolveMachOLoadPath(
                dependency,
                executable: finalTarget,
                runpaths: loadPaths.runpaths
            ) {
                var status = stat()
                guard Darwin.lstat(candidate.path, &status) == 0 else { continue }
                guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                      status.st_size > 0 else {
                    throw DialogueVoiceRuntimeError.inferenceUnavailable
                }
                try validateRuntimePathAuthority(candidate, control: control)
                resolvedDependencies.append(candidate)
                resolvedThisDependency = true
            }
            guard resolvedThisDependency else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
        }
        let uniqueDependencyPaths = Set(resolvedDependencies.map(\.path))
        guard uniqueDependencyPaths.count == 1,
              let dependency = resolvedDependencies.first else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }

        let invocationRoot = pythonEnvironmentRoot(for: invocation)
        let targetRoot = pythonEnvironmentRoot(for: finalTarget)
        let configurationURL = invocationRoot.appendingPathComponent("pyvenv.cfg")
        let configuration = try readPythonEnvironmentConfiguration(
            configurationURL,
            control: control
        )
        let fields = configuration.map(parsePythonEnvironmentConfiguration) ?? [:]
        let isVirtualEnvironment = configuration != nil
        let includesBaseSitePackages = fields["include-system-site-packages"]?
            .lowercased() == "true"

        var baseCandidates: [URL] = []
        for key in ["home", "executable"] {
            guard let value = fields[key], value.hasPrefix("/") else { continue }
            var candidate = URL(fileURLWithPath: value).standardizedFileURL
            if key == "executable" { candidate.deleteLastPathComponent() }
            if candidate.lastPathComponent == "bin" { candidate.deleteLastPathComponent() }
            baseCandidates.append(candidate)
        }
        baseCandidates.append(targetRoot)
        baseCandidates.append(dependency.deletingLastPathComponent())

        var layouts: [(version: String, root: URL, standardLibrary: URL)] = []
        var seenLayouts = Set<String>()
        for candidate in baseCandidates {
            try control.check()
            for library in ["lib", "lib64"] {
                let libraryRoot = candidate.appendingPathComponent(library, isDirectory: true)
                guard let entries = try? FileManager.default.contentsOfDirectory(
                    at: libraryRoot,
                    includingPropertiesForKeys: nil,
                    options: []
                ) else { continue }
                for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    guard let version = pythonVersion(fromLibraryDirectory: entry.lastPathComponent) else {
                        continue
                    }
                    let osModule = entry.appendingPathComponent("os.py")
                    let encodings = entry.appendingPathComponent("encodings/__init__.py")
                    var osStatus = stat()
                    var encodingsStatus = stat()
                    guard Darwin.lstat(osModule.path, &osStatus) == 0,
                          Darwin.lstat(encodings.path, &encodingsStatus) == 0,
                          osStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                          encodingsStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                          osStatus.st_size > 0,
                          encodingsStatus.st_size > 0 else { continue }
                    let key = candidate.path + "|" + version
                    if seenLayouts.insert(key).inserted {
                        layouts.append((version, candidate, entry))
                    }
                }
            }
        }

        let versionHints = pythonVersionHints(finalTarget: finalTarget, dependency: dependency)
        if !versionHints.isEmpty {
            layouts.removeAll { !versionHints.contains($0.version) }
        }
        guard layouts.count == 1, let selected = layouts.first else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        try validateRuntimePathAuthority(selected.root, control: control)
        try validateRuntimePathAuthority(selected.standardLibrary, control: control)
        let dependencyDigest = try sha256RegularFile(
            dependency,
            maximumBytes: 1_073_741_824,
            control: control
        )
        var dependencyStatus = stat()
        guard Darwin.lstat(dependency.path, &dependencyStatus) == 0 else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        let coreRoots = [
            selected.standardLibrary
                .deletingLastPathComponent()
                .appendingPathComponent("python\(selected.version).zip"),
            selected.standardLibrary,
            selected.standardLibrary.appendingPathComponent("lib-dynload", isDirectory: true),
        ]
        return AuthenticatedPythonLayout(
            layout: PythonRuntimeLayout(
                version: selected.version,
                baseRoot: selected.root,
                virtualEnvironmentRoot: isVirtualEnvironment ? invocationRoot : nil,
                includesBaseSitePackages: includesBaseSitePackages,
                coreRoots: coreRoots
            ),
            dependencyToken: DialogueVoiceFileIdentity(dependencyStatus).token
                + ":" + dependencyDigest
        )
    }

    private static func pythonEnvironmentRoot(for executable: URL) -> URL {
        let parent = executable.deletingLastPathComponent().standardizedFileURL
        return parent.lastPathComponent == "bin"
            ? parent.deletingLastPathComponent().standardizedFileURL
            : parent
    }

    private static func parsePythonEnvironmentConfiguration(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let parts = rawLine.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            fields[key] = value
        }
        return fields
    }

    private static func pythonVersion(fromLibraryDirectory name: String) -> String? {
        guard name.hasPrefix("python") else { return nil }
        let version = String(name.dropFirst("python".count))
        let pieces = version.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        return version
    }

    private static func pythonVersionHints(finalTarget: URL, dependency: URL) -> Set<String> {
        var hints = Set<String>()
        for component in finalTarget.pathComponents + dependency.pathComponents {
            if let version = pythonVersion(fromLibraryDirectory: component) {
                hints.insert(version)
            } else if component.hasPrefix("python") || component.hasPrefix("libpython") {
                let digits = component.filter { $0.isNumber || $0 == "." }
                let pieces = digits.split(separator: ".")
                if pieces.count >= 2 {
                    hints.insert("\(pieces[0]).\(pieces[1])")
                }
            }
        }
        return hints
    }

    private static func resolveMachOLoadPath(
        _ raw: String,
        executable: URL,
        runpaths: [String]
    ) -> [URL] {
        let executableRoot = executable.deletingLastPathComponent()
        func resolve(_ value: String) -> URL? {
            if value.hasPrefix("/") {
                return URL(fileURLWithPath: value).standardizedFileURL
            }
            for token in ["@executable_path/", "@loader_path/"] where value.hasPrefix(token) {
                return executableRoot
                    .appendingPathComponent(String(value.dropFirst(token.count)))
                    .standardizedFileURL
            }
            return nil
        }
        if let direct = resolve(raw) { return [direct] }
        guard raw.hasPrefix("@rpath/") else { return [] }
        let suffix = String(raw.dropFirst("@rpath/".count))
        return runpaths.compactMap { runpath in
            guard let root = resolve(runpath) else { return nil }
            return root.appendingPathComponent(suffix).standardizedFileURL
        }
    }

    private static func pythonMachOLoadPaths(
        at url: URL,
        control: QwenRuntimeValidationControl
    ) throws -> MachOLoadPaths {
        try control.check()
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_size > 0,
              status.st_size <= 1_073_741_824 else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        let identity = DialogueVoiceFileIdentity(status)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count == Int(status.st_size) else {
            throw DialogueVoiceRuntimeError.sourceChanged
        }
        let slices = try machOSlices(in: data)
        var dependencies: [String] = []
        var runpaths: [String] = []
        for slice in slices {
            try control.check()
            let paths = try machOLoadPaths(
                in: data,
                sliceOffset: slice.offset,
                endian: slice.endian,
                control: control
            )
            guard paths.dependencies.contains(where: { raw in
                let name = (raw as NSString).lastPathComponent.lowercased()
                return name == "python"
                    || name == "python3"
                    || (name.hasPrefix("libpython") && name.hasSuffix(".dylib"))
            }) else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
            dependencies.append(contentsOf: paths.dependencies)
            runpaths.append(contentsOf: paths.runpaths)
        }
        var rebound = stat()
        guard Darwin.lstat(url.path, &rebound) == 0,
              DialogueVoiceFileIdentity(rebound) == identity else {
            throw DialogueVoiceRuntimeError.sourceChanged
        }
        return MachOLoadPaths(dependencies: dependencies, runpaths: runpaths)
    }

    private enum MachOEndian { case little, big }
    private struct MachOSlice { let offset: Int; let endian: MachOEndian }

    private static func machOSlices(in data: Data) throws -> [MachOSlice] {
        guard data.count >= 4 else { throw DialogueVoiceRuntimeError.inferenceUnavailable }
        let bytes = [UInt8](data.prefix(4))
        if bytes == [0xcf, 0xfa, 0xed, 0xfe] { return [MachOSlice(offset: 0, endian: .little)] }
        if bytes == [0xfe, 0xed, 0xfa, 0xcf] { return [MachOSlice(offset: 0, endian: .big)] }
        let isFat64: Bool
        let endian: MachOEndian
        if bytes == [0xca, 0xfe, 0xba, 0xbe] { isFat64 = false; endian = .big }
        else if bytes == [0xca, 0xfe, 0xba, 0xbf] { isFat64 = true; endian = .big }
        else if bytes == [0xbe, 0xba, 0xfe, 0xca] { isFat64 = false; endian = .little }
        else if bytes == [0xbf, 0xba, 0xfe, 0xca] { isFat64 = true; endian = .little }
        else { throw DialogueVoiceRuntimeError.inferenceUnavailable }
        let count = Int(try machOUInt32(data, at: 4, endian: endian))
        guard count > 0, count <= 32 else { throw DialogueVoiceRuntimeError.inferenceUnavailable }
        let stride = isFat64 ? 32 : 20
        var slices: [MachOSlice] = []
        for index in 0..<count {
            let entry = 8 + index * stride
            let offset: Int
            if isFat64 {
                guard let exactOffset = Int(exactly: try machOUInt64(
                    data,
                    at: entry + 8,
                    endian: endian
                )) else {
                    throw DialogueVoiceRuntimeError.inferenceUnavailable
                }
                offset = exactOffset
            } else {
                offset = Int(try machOUInt32(data, at: entry + 8, endian: endian))
            }
            guard offset <= data.count, data.count - offset >= 32 else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
            let magic = [UInt8](data[offset..<offset + 4])
            if magic == [0xcf, 0xfa, 0xed, 0xfe] {
                slices.append(MachOSlice(offset: offset, endian: .little))
            } else if magic == [0xfe, 0xed, 0xfa, 0xcf] {
                slices.append(MachOSlice(offset: offset, endian: .big))
            } else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
        }
        return slices
    }

    private static func machOLoadPaths(
        in data: Data,
        sliceOffset: Int,
        endian: MachOEndian,
        control: QwenRuntimeValidationControl
    ) throws -> MachOLoadPaths {
        let commandCount = Int(try machOUInt32(data, at: sliceOffset + 16, endian: endian))
        let commandsSize = Int(try machOUInt32(data, at: sliceOffset + 20, endian: endian))
        guard commandCount > 0,
              commandCount <= 16_384,
              commandsSize >= 0,
              sliceOffset + 32 + commandsSize <= data.count else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        var cursor = sliceOffset + 32
        var result = MachOLoadPaths(dependencies: [], runpaths: [])
        for index in 0..<commandCount {
            if index % 64 == 0 { try control.check() }
            let command = try machOUInt32(data, at: cursor, endian: endian)
            let size = Int(try machOUInt32(data, at: cursor + 4, endian: endian))
            guard size >= 8, cursor + size <= sliceOffset + 32 + commandsSize else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
            let baseCommand = command & 0x7fff_ffff
            if [UInt32(0x0c), 0x18, 0x1f, 0x23].contains(baseCommand) {
                let offset = Int(try machOUInt32(data, at: cursor + 8, endian: endian))
                result.dependencies.append(try machOCString(data, start: cursor + offset, end: cursor + size))
            } else if baseCommand == 0x1c {
                let offset = Int(try machOUInt32(data, at: cursor + 8, endian: endian))
                result.runpaths.append(try machOCString(data, start: cursor + offset, end: cursor + size))
            }
            cursor += size
        }
        return result
    }

    private static func machOCString(_ data: Data, start: Int, end: Int) throws -> String {
        guard start >= 0, start < end, end <= data.count,
              let terminator = data[start..<end].firstIndex(of: 0),
              let value = String(data: data[start..<terminator], encoding: .utf8),
              !value.isEmpty else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        return value
    }

    private static func machOUInt32(
        _ data: Data,
        at offset: Int,
        endian: MachOEndian
    ) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        let value = data[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return endian == .big ? value : value.byteSwapped
    }

    private static func machOUInt64(
        _ data: Data,
        at offset: Int,
        endian: MachOEndian
    ) throws -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        let value = data[offset..<offset + 8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return endian == .big ? value : value.byteSwapped
    }

    private static func validatePythonEnvironmentAuthority(
        _ invocation: URL,
        visitedEnvironments: inout Set<String>,
        visitedTrees: inout Set<String>,
        discoveredSearchRoots: inout [URL],
        control: QwenRuntimeValidationControl
    ) throws {
        try control.check()
        let executableParent = invocation.deletingLastPathComponent().standardizedFileURL
        let environmentRoot = executableParent.lastPathComponent == "bin"
            ? executableParent.deletingLastPathComponent().standardizedFileURL
            : executableParent
        guard visitedEnvironments.insert(environmentRoot.path).inserted else { return }
        if environmentRoot.path == "/" {
            // `/bin` is a sealed top-level system runtime location; treating
            // its coarse parent as a Python module tree would incorrectly
            // traverse unrelated mutable volumes such as `/private`.
            try validateRuntimePathAuthority(executableParent, control: control)
            return
        }
        try validatePythonTreeAuthority(
            environmentRoot,
            visitedTrees: &visitedTrees,
            discoveredSearchRoots: &discoveredSearchRoots,
            control: control
        )

        let configurationURL = environmentRoot.appendingPathComponent("pyvenv.cfg")
        if let configuration = try readPythonEnvironmentConfiguration(
            configurationURL,
            control: control
        ) {
            for rawLine in configuration.split(whereSeparator: \.isNewline) {
                let parts = rawLine.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard key == "home" || key == "executable" else { continue }
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                guard value.hasPrefix("/") else {
                    throw DialogueVoiceRuntimeError.inferenceUnavailable
                }
                var base = URL(fileURLWithPath: value).standardizedFileURL
                if key == "executable" { base.deleteLastPathComponent() }
                if base.lastPathComponent == "bin" { base.deleteLastPathComponent() }
                guard base.path != environmentRoot.path else { continue }
                let syntheticExecutable = base
                    .appendingPathComponent("bin", isDirectory: true)
                    .appendingPathComponent("python", isDirectory: false)
                try validatePythonEnvironmentAuthority(
                    syntheticExecutable,
                    visitedEnvironments: &visitedEnvironments,
                    visitedTrees: &visitedTrees,
                    discoveredSearchRoots: &discoveredSearchRoots,
                    control: control
                )
            }
        }
    }

    private static func validatePythonTreeAuthority(
        _ root: URL,
        visitedTrees: inout Set<String>,
        discoveredSearchRoots: inout [URL],
        control: QwenRuntimeValidationControl
    ) throws {
        try control.check()
        let root = root.standardizedFileURL
        guard visitedTrees.insert(root.path).inserted else { return }
        try validateRuntimePathAuthority(root, control: control)
        var rootStatus = stat()
        guard Darwin.lstat(root.path, &rootStatus) == 0,
              rootStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        if rootStatus.st_uid == 0, isSealedSystemRuntimePath(root.path) { return }

        let effectiveUser = Darwin.geteuid()
        var entryCount = 0
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in
                enumerationFailed = true
                return false
            }
        ) else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        while let entry = enumerator.nextObject() as? URL {
            entryCount += 1
            guard entryCount <= maximumPythonEnvironmentEntries else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
            if entryCount % 64 == 0 { try control.check() }
            var status = stat()
            guard Darwin.lstat(entry.path, &status) == 0,
                  status.st_uid == 0 || status.st_uid == effectiveUser,
                  try !hasWriteGrantingACL(
                      at: entry,
                      isSymbolicLink: status.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
                  ) else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
            let kind = status.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFLNK) {
                let resolved = try resolveAuthoritySymlink(at: entry)
                guard resolved.path != entry.path else {
                    throw DialogueVoiceRuntimeError.inferenceUnavailable
                }
                try validateRuntimePathAuthority(resolved, control: control)
                var resolvedStatus = stat()
                guard Darwin.lstat(resolved.path, &resolvedStatus) == 0 else {
                    throw DialogueVoiceRuntimeError.inferenceUnavailable
                }
                if resolvedStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                    guard resolved.path != "/" else {
                        throw DialogueVoiceRuntimeError.inferenceUnavailable
                    }
                    try validatePythonTreeAuthority(
                        resolved,
                        visitedTrees: &visitedTrees,
                        discoveredSearchRoots: &discoveredSearchRoots,
                        control: control
                    )
                }
                continue
            }
            guard kind == mode_t(S_IFDIR) || kind == mode_t(S_IFREG),
                  status.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0 else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
        }
        guard !enumerationFailed else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
    }

    private static func validatePotentialPythonSearchRootAuthority(
        _ candidate: URL,
        visitedTrees: inout Set<String>,
        discoveredSearchRoots: inout [URL],
        control: QwenRuntimeValidationControl
    ) throws {
        try control.check()
        let candidate = candidate.standardizedFileURL
        guard candidate.path.hasPrefix("/") else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        var status = stat()
        if Darwin.lstat(candidate.path, &status) == 0 {
            try validateRuntimePathAuthority(candidate, control: control)
            let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard Darwin.lstat(resolvedCandidate.path, &status) == 0 else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
            let kind = status.st_mode & mode_t(S_IFMT)
            guard kind == mode_t(S_IFDIR) || kind == mode_t(S_IFREG) else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
            discoveredSearchRoots.append(candidate)
            if kind == mode_t(S_IFDIR) {
                try validatePythonTreeAuthority(
                    resolvedCandidate,
                    visitedTrees: &visitedTrees,
                    discoveredSearchRoots: &discoveredSearchRoots,
                    control: control
                )
            }
            return
        }
        guard errno == ENOENT else { throw DialogueVoiceRuntimeError.inferenceUnavailable }
        var existingParent = candidate.deletingLastPathComponent()
        while Darwin.lstat(existingParent.path, &status) != 0 {
            try control.check()
            guard errno == ENOENT, existingParent.path != "/" else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
            existingParent.deleteLastPathComponent()
        }
        try validateRuntimePathAuthority(existingParent, control: control)
        discoveredSearchRoots.append(candidate)
    }

    private static func readBoundedRuntimeText(
        _ url: URL,
        maximumBytes: Int,
        allowsEmpty: Bool,
        control: QwenRuntimeValidationControl
    ) throws -> String? {
        try control.check()
        var pathStatus = stat()
        guard Darwin.lstat(url.path, &pathStatus) == 0 else {
            if errno == ENOENT { return nil }
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        guard pathStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              (allowsEmpty || pathStatus.st_size > 0),
              pathStatus.st_size >= 0,
              pathStatus.st_size <= maximumBytes else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        try validateRuntimePathAuthority(url, control: control)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DialogueVoiceRuntimeError.inferenceUnavailable }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              DialogueVoiceFileIdentity(opened) == DialogueVoiceFileIdentity(pathStatus) else {
            throw DialogueVoiceRuntimeError.sourceChanged
        }
        var data = Data()
        while data.count <= Int(opened.st_size) {
            try control.check()
            let capacity = min(4_096, Int(opened.st_size) + 1 - data.count)
            if capacity == 0 { break }
            var buffer = [UInt8](repeating: 0, count: capacity)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else { throw DialogueVoiceRuntimeError.inferenceUnavailable }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var final = stat()
        var rebound = stat()
        guard Int64(data.count) == Int64(opened.st_size),
              Darwin.fstat(descriptor, &final) == 0,
              DialogueVoiceFileIdentity(final) == DialogueVoiceFileIdentity(opened),
              Darwin.lstat(url.path, &rebound) == 0,
              DialogueVoiceFileIdentity(rebound) == DialogueVoiceFileIdentity(final),
              let value = String(data: data, encoding: .utf8) else {
            throw DialogueVoiceRuntimeError.sourceChanged
        }
        return value
    }

    private static func readPythonEnvironmentConfiguration(
        _ url: URL,
        control: QwenRuntimeValidationControl
    ) throws -> String? {
        try readBoundedRuntimeText(
            url,
            maximumBytes: 65_536,
            allowsEmpty: false,
            control: control
        )
    }

    private static func validatePythonLaunchEnvironment(_ environment: [String: String]) throws {
        let forbiddenExact = Set([
            "PYTHONHOME", "PYTHONPATH", "PYTHONSTARTUP", "PYTHONINSPECT",
            "PYTHONEXECUTABLE", "__PYVENV_LAUNCHER__", "VIRTUAL_ENV",
            "LD_LIBRARY_PATH", "LD_PRELOAD",
        ])
        let allowedPythonKeys = Set(["PYTHONNOUSERSITE", "PYTHONDONTWRITEBYTECODE"])
        for key in environment.keys {
            let upper = key.uppercased()
            if forbiddenExact.contains(upper)
                || (upper.hasPrefix("PYTHON") && !allowedPythonKeys.contains(upper))
                || upper.hasPrefix("DYLD_")
                || upper.hasPrefix("LD_PRELOAD_") {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
        }
    }

    private static func pythonSiteCandidates(prefix: URL, version: String) -> [URL] {
        ["lib", "lib64"].flatMap { library in
            ["site-packages", "dist-packages"].map { packages in
                prefix
                    .appendingPathComponent(library, isDirectory: true)
                    .appendingPathComponent("python\(version)", isDirectory: true)
                    .appendingPathComponent(packages, isDirectory: true)
                    .standardizedFileURL
            }
        }
    }

    private static func appendPythonSiteRoots(
        at prefix: URL,
        version: String,
        to orderedRoots: inout [URL],
        visitedTrees: inout Set<String>,
        control: QwenRuntimeValidationControl
    ) throws {
        for siteRoot in pythonSiteCandidates(prefix: prefix, version: version) {
            try control.check()
            var status = stat()
            guard Darwin.lstat(siteRoot.path, &status) == 0 else {
                if errno == ENOENT { continue }
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
            guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
            var ignoredDiscoveries: [URL] = []
            try validatePotentialPythonSearchRootAuthority(
                siteRoot,
                visitedTrees: &visitedTrees,
                discoveredSearchRoots: &ignoredDiscoveries,
                control: control
            )
            orderedRoots.append(siteRoot)

            let entries = try FileManager.default.contentsOfDirectory(
                at: siteRoot,
                includingPropertiesForKeys: nil,
                options: []
            )
            let pathFiles = entries
                .filter { $0.pathExtension == "pth" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for pathFile in pathFiles {
                guard let configuration = try readBoundedRuntimeText(
                    pathFile,
                    maximumBytes: 65_536,
                    allowsEmpty: true,
                    control: control
                ) else {
                    throw DialogueVoiceRuntimeError.inferenceUnavailable
                }
                for rawLine in configuration.split(whereSeparator: \.isNewline) {
                    try control.check()
                    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty, !line.hasPrefix("#") else { continue }
                    // `-S` keeps executable .pth directives inert. Pure path
                    // entries retain CPython's filename and line order.
                    if line == "import"
                        || line.hasPrefix("import ")
                        || line.hasPrefix("import\t") {
                        continue
                    }
                    let candidate = line.hasPrefix("/")
                        ? URL(fileURLWithPath: line).standardizedFileURL
                        : siteRoot.appendingPathComponent(line).standardizedFileURL
                    guard Darwin.lstat(candidate.path, &status) == 0 else {
                        if errno == ENOENT { continue }
                        throw DialogueVoiceRuntimeError.inferenceUnavailable
                    }
                    try validatePotentialPythonSearchRootAuthority(
                        candidate,
                        visitedTrees: &visitedTrees,
                        discoveredSearchRoots: &ignoredDiscoveries,
                        control: control
                    )
                    orderedRoots.append(candidate)
                }
            }
        }
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

    private static let maximumPythonLauncherResolutionSteps = 32

    private static func pythonLauncherIdentity(
        _ url: URL,
        control: QwenRuntimeValidationControl
    ) throws -> PythonLauncherIdentity {
        try control.check()
        var launcherStatus = stat()
        guard Darwin.lstat(url.path, &launcherStatus) == 0 else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        let kind = launcherStatus.st_mode & mode_t(S_IFMT)
        let target: URL
        if kind == mode_t(S_IFREG) {
            target = url
        } else if kind == mode_t(S_IFLNK) {
            target = try resolvePythonLauncherTarget(startingAt: url, control: control)
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

    private static func resolvePythonLauncherTarget(
        startingAt launcher: URL,
        control: QwenRuntimeValidationControl
    ) throws -> URL {
        var candidate = launcher
        var visited = Set<String>()
        for _ in 0..<maximumPythonLauncherResolutionSteps {
            try control.check()
            guard visited.insert(candidate.path).inserted else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
            var status = stat()
            guard Darwin.lstat(candidate.path, &status) == 0 else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
            let kind = status.st_mode & mode_t(S_IFMT)
            if kind == mode_t(S_IFREG) { return candidate }
            guard kind == mode_t(S_IFLNK) else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let length = Darwin.readlink(candidate.path, &buffer, Int(PATH_MAX))
            guard length > 0, length < Int(PATH_MAX) else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
            let raw = String(
                decoding: buffer.prefix(length).map(UInt8.init(bitPattern:)),
                as: UTF8.self
            )
            if raw.hasPrefix("/") {
                let absolute = URL(fileURLWithPath: raw).standardizedFileURL
                guard absolute.path == raw else {
                    throw DialogueVoiceRuntimeError.inferenceUnavailable
                }
                candidate = absolute
            } else {
                let components = raw.split(separator: "/", omittingEmptySubsequences: false)
                guard !components.contains("..") else {
                    throw DialogueVoiceRuntimeError.inferenceUnavailable
                }
                candidate = URL(
                    fileURLWithPath: raw,
                    relativeTo: candidate.deletingLastPathComponent()
                ).standardizedFileURL.absoluteURL
            }
        }
        throw DialogueVoiceRuntimeError.inferenceUnavailable
    }

    static func computePackageTreeSHA256(packageRoot: URL) throws -> String {
        var rootStatus = stat()
        guard Darwin.lstat(packageRoot.path, &rootStatus) == 0,
              rootStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              let enumerator = FileManager.default.enumerator(atPath: packageRoot.path) else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        var entries: [(String, URL, UInt64)] = []
        var total: UInt64 = 0
        while let relative = enumerator.nextObject() as? String {
            let url = try qwenPackageURL(relativePath: relative, root: packageRoot)
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
              let enumerator = FileManager.default.enumerator(atPath: packageRoot.path) else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        var tokens = ["root:\(DialogueVoiceFileIdentity(rootStatus).token)"]
        var total: UInt64 = 0
        while let relative = enumerator.nextObject() as? String {
            let url = try qwenPackageURL(relativePath: relative, root: packageRoot)
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
            tokens.append("\(relative):\(DialogueVoiceFileIdentity(status).token)")
        }
        return tokens.sorted()
    }

    private static func sha256RegularFile(
        _ url: URL,
        maximumBytes: UInt64,
        control: QwenRuntimeValidationControl? = nil
    ) throws -> String {
        try checkValidation(control)
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
            try checkValidation(control)
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

    static func sha256FileForVoiceProvider(_ url: URL, maximumBytes: UInt64) throws -> String {
        try sha256RegularFile(url, maximumBytes: maximumBytes)
    }
}

struct VoxCPM2ValidatedProfile: Equatable, Sendable {
    let snapshotRoot: URL
    let modelRoot: URL
    let pythonExecutable: URL
    let runtimeIdentity: Qwen3TTSPythonRuntimeIdentity
    let referenceAudio: URL
    let identityTokens: [String]
}

struct VoxCPM2ProbeResult: Equatable, Sendable {
    let device: String
    let sampleRate: Int

    var sanitizedSummary: String {
        "device=\(device) sample_rate=\(sampleRate)"
    }
}

enum VoxCPM2ProfileValidator {
    static let maximumSnapshotBytes = VoxCPM2SnapshotInstaller.maximumPackageBytes

    static func validate(profile: VoxCPM2VoiceProfile, applicationSupportRoot: URL) throws -> VoxCPM2ValidatedProfile {
        try Task.checkCancellation()
        let treeBefore = try managedSnapshotTree(
            relativePath: profile.snapshotPath,
            applicationSupportRoot: applicationSupportRoot
        )
        guard treeBefore.digest == profile.snapshotTreeSHA256 else { throw DialogueVoiceRuntimeError.inputFingerprintMismatch }
        let runtime = try Qwen3TTSProfileValidator.validatePythonExecutable(
            at: URL(fileURLWithPath: profile.pythonExecutablePath)
        )
        guard runtime.finalTargetSHA256 == profile.pythonExecutableSHA256 else {
            throw DialogueVoiceRuntimeError.inputFingerprintMismatch
        }
        let referenceIdentity = try DialogueVoiceAssetInstaller.managedFileIdentity(
            relativePath: profile.referenceAudioRelativePath, root: applicationSupportRoot,
            maximumBytes: DialogueVoiceAssetKind.voxcpm2ReferenceAudio.maximumBytes
        )
        try DialogueVoiceAssetInstaller.validateReferenceAudio(
            relativePath: profile.referenceAudioRelativePath, root: applicationSupportRoot
        )
        let referenceDigest = try DialogueVoiceAssetInstaller.sha256ManagedFile(
            relativePath: profile.referenceAudioRelativePath, root: applicationSupportRoot,
            maximumBytes: DialogueVoiceAssetKind.voxcpm2ReferenceAudio.maximumBytes
        )
        guard referenceDigest == profile.referenceAudioSHA256,
              Qwen3TTSProfileValidator.computeInputFingerprint(components: profile.inputFingerprintComponents)
                == profile.inputFingerprint else { throw DialogueVoiceRuntimeError.inputFingerprintMismatch }
        let treeAfter = try managedSnapshotTree(
            relativePath: profile.snapshotPath,
            applicationSupportRoot: applicationSupportRoot
        )
        guard treeBefore == treeAfter else { throw DialogueVoiceRuntimeError.sourceChanged }
        let snapshot = applicationSupportRoot.standardizedFileURL
            .appendingPathComponent(profile.snapshotPath, isDirectory: true)
            .standardizedFileURL
        return VoxCPM2ValidatedProfile(
            snapshotRoot: snapshot,
            modelRoot: treeAfter.usesNestedModelRoot
                ? snapshot.appendingPathComponent("model", isDirectory: true)
                : snapshot,
            pythonExecutable: URL(fileURLWithPath: runtime.invocationPath),
            runtimeIdentity: runtime,
            referenceAudio: applicationSupportRoot.appendingPathComponent(profile.referenceAudioRelativePath),
            identityTokens: treeAfter.identityTokens + [runtime.stableIdentityToken, referenceIdentity]
        )
    }

    static func computeSnapshotTreeSHA256(
        snapshotRoot: URL,
        hashChunkObserver: (@Sendable () -> Void)? = nil
    ) throws -> String {
        try Task.checkCancellation()
        guard snapshotRoot.isFileURL else {
            throw DialogueVoiceRuntimeError.invalidSource
        }
        let descriptor = Darwin.open(
            snapshotRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw DialogueVoiceRuntimeError.invalidSource }
        defer { Darwin.close(descriptor) }
        return try VoxCPM2SnapshotTree.scan(
            rootDescriptor: descriptor,
            hashChunkObserver: hashChunkObserver
        ).digest
    }

    private static func managedSnapshotTree(
        relativePath: String,
        applicationSupportRoot: URL
    ) throws -> VoxCPM2SnapshotTree.Snapshot {
        try VoxCPM2ManagedStorage.withOpenSnapshot(
            relativePath: relativePath,
            applicationSupportRoot: applicationSupportRoot
        ) { descriptor, _ in
            try VoxCPM2SnapshotTree.scan(rootDescriptor: descriptor)
        }
    }
}

private func qwenPackageURL(relativePath: String, root: URL) throws -> URL {
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard !relativePath.isEmpty,
          !relativePath.hasPrefix("/"),
          components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        throw DialogueVoiceRuntimeError.invalidManagedPath
    }
    return root.appendingPathComponent(relativePath)
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
        tlsLeafCertificateSHA256: String,
        referenceText: String,
        promptLanguage: String,
        defaultTextLanguage: String,
        assetDigests: DialogueVoiceAssetDigests
    ) -> String {
        var hasher = SHA256()
        for field in [
            "statelet-gpt-sovits-api-v2-pcm-wav-pinned-tls-v1",
            apiBaseURL.absoluteString,
            tlsLeafCertificateSHA256.lowercased(),
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

private struct DialogueVoiceDirectoryIdentity: Equatable {
    let fileType: mode_t
    let device: UInt64
    let inode: UInt64

    init(_ status: stat) {
        fileType = status.st_mode & mode_t(S_IFMT)
        device = UInt64(status.st_dev)
        inode = UInt64(status.st_ino)
    }
}

struct DialogueVoiceAssetInstaller: Sendable {
    let applicationSupportRoot: URL

    static func managedRelativePaths(
        kind: DialogueVoiceAssetKind,
        destinationToken token: String,
        fileExtension: String
    ) throws -> (destination: String, staging: String) {
        guard let uuid = UUID(uuidString: token),
              uuid.uuidString.lowercased() == token,
              !fileExtension.isEmpty,
              fileExtension == fileExtension.lowercased(),
              kind.allowedExtensions.contains(fileExtension) else {
            throw DialogueVoiceRuntimeError.invalidManagedPath
        }
        let filename = "\(token).\(fileExtension)"
        let root = "voice/assets/\(kind.rawValue)"
        return (
            destination: "\(root)/\(filename)",
            staging: "\(root)/.\(filename).partial"
        )
    }

    func install(
        sourceURL: URL,
        kind: DialogueVoiceAssetKind,
        destinationToken: String? = nil
    ) throws -> DialogueVoiceInstalledAsset {
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

        let token = destinationToken ?? UUID().uuidString.lowercased()
        let managedPaths = try Self.managedRelativePaths(
            kind: kind,
            destinationToken: token,
            fileExtension: fileExtension
        )
        let filename = String(managedPaths.destination.split(separator: "/").last!)
        let temporaryName = String(managedPaths.staging.split(separator: "/").last!)
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
        let relativePath = managedPaths.destination
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
              currentStatus.st_size >= 0,
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
                guard status.st_size >= 0 else { throw DialogueVoiceRuntimeError.invalidManagedPath }
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

enum DialogueVoicePinnedTLS {
    static func matches(
        leafCertificateDER: Data?,
        expectedSHA256: String?
    ) -> Bool {
        guard let leafCertificateDER,
              let expectedSHA256,
              expectedSHA256.count == 64,
              expectedSHA256.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value)
                      || (65...70).contains(scalar.value)
                      || (97...102).contains(scalar.value)
              }) else {
            return false
        }
        let actualSHA256 = SHA256.hash(data: leafCertificateDER)
            .map { String(format: "%02x", $0) }
            .joined()
        return actualSHA256 == expectedSHA256.lowercased()
    }
}

final class DialogueVoiceBoundedRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private let expectedLeafCertificateSHA256: String?
    private let lock = NSLock()
    private var data = Data()
    private var response: URLResponse?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var finished = false

    init(maximumBytes: Int, expectedLeafCertificateSHA256: String? = nil) {
        self.maximumBytes = maximumBytes
        self.expectedLeafCertificateSHA256 = expectedLeafCertificateSHA256
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              let certificateChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let leafCertificate = certificateChain.first,
              DialogueVoicePinnedTLS.matches(
                  leafCertificateDER: SecCertificateCopyData(leafCertificate) as Data,
                  expectedSHA256: expectedLeafCertificateSHA256
              ) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
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

typealias GPTSoVITSRequestPerformer = @Sendable (
    URLRequest,
    Int,
    String,
    URLSessionConfiguration
) async throws -> (Data, URLResponse)

actor GPTSoVITSAPIClient {
    private struct ActivatedProfile {
        let baseURL: URL
        let tlsLeafCertificateSHA256: String
        let referenceAudioURL: URL
    }

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
    private let requestPerformer: GPTSoVITSRequestPerformer

    init(
        configuration: URLSessionConfiguration = .ephemeral,
        requestPerformer: @escaping GPTSoVITSRequestPerformer = { request, maximumBytes, pin, configuration in
            try await DialogueVoiceBoundedRequest(
                maximumBytes: maximumBytes,
                expectedLeafCertificateSHA256: pin
            ).perform(request, configuration: configuration)
        }
    ) {
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 180
        self.configuration = configuration
        self.requestPerformer = requestPerformer
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
        let activatedProfile = try await activateProfile(
            profile,
            applicationSupportRoot: applicationSupportRoot
        )
        let endpoint = activatedProfile.baseURL.appendingPathComponent("tts")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/wav", forHTTPHeaderField: "Accept")
        request.httpBody = try Self.encodedTTSRequestBody(
            text: line.text,
            textLanguage: line.textLanguage,
            referenceAudioPath: activatedProfile.referenceAudioURL.path,
            promptText: profile.referenceText,
            promptLanguage: profile.promptLanguage
        )
        let (data, response) = try await perform(
            request,
            maximumBytes: Self.maximumAudioResponseBytes,
            tlsLeafCertificateSHA256: activatedProfile.tlsLeafCertificateSHA256
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
    ) async throws -> ActivatedProfile {
        let baseURL = try Self.validatedBaseURL(profile.apiBaseURL)
        guard let tlsLeafCertificateSHA256 = profile.tlsLeafCertificateSHA256 else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
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
            value: gptWeightURL.path,
            tlsLeafCertificateSHA256: tlsLeafCertificateSHA256
        )
        try await setWeight(
            baseURL: baseURL,
            endpoint: "set_sovits_weights",
            queryName: "weights_path",
            value: sovitsWeightURL.path,
            tlsLeafCertificateSHA256: tlsLeafCertificateSHA256
        )
        return ActivatedProfile(
            baseURL: baseURL,
            tlsLeafCertificateSHA256: tlsLeafCertificateSHA256,
            referenceAudioURL: referenceAudioURL
        )
    }

    private func setWeight(
        baseURL: URL,
        endpoint: String,
        queryName: String,
        value: String,
        tlsLeafCertificateSHA256: String
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
            maximumBytes: Self.maximumControlResponseBytes,
            tlsLeafCertificateSHA256: tlsLeafCertificateSHA256
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
        maximumBytes: Int,
        tlsLeafCertificateSHA256: String
    ) async throws -> (Data, URLResponse) {
        do {
            try Task.checkCancellation()
            return try await requestPerformer(
                request,
                maximumBytes,
                tlsLeafCertificateSHA256,
                configuration
            )
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
    let expectedRuntimeIdentity: Qwen3TTSPythonRuntimeIdentity
    let helperURL: URL
    let currentDirectoryURL: URL
    let environment: [String: String]
    let standardInput: Data
    let outputURL: URL
    let timeout: TimeInterval
    let requiresOutputFile: Bool
    let deniesNetwork: Bool

    init(
        executableURL: URL,
        expectedRuntimeIdentity: Qwen3TTSPythonRuntimeIdentity,
        helperURL: URL,
        currentDirectoryURL: URL,
        environment: [String: String],
        standardInput: Data,
        outputURL: URL,
        timeout: TimeInterval,
        requiresOutputFile: Bool = true,
        deniesNetwork: Bool = true
    ) {
        self.executableURL = executableURL
        self.expectedRuntimeIdentity = expectedRuntimeIdentity
        self.helperURL = helperURL
        self.currentDirectoryURL = currentDirectoryURL
        self.environment = environment
        self.standardInput = standardInput
        self.outputURL = outputURL
        self.timeout = timeout
        self.requiresOutputFile = requiresOutputFile
        self.deniesNetwork = deniesNetwork
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

private final class QwenProcessFinalizer {
    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let reads: DispatchGroup
    private var processGroupEstablished = false
    private var finalized = false
    private var forcedCleanup = false

    init(
        process: Process,
        stdinPipe: Pipe,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        reads: DispatchGroup
    ) {
        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.reads = reads
    }

    func markProcessGroupEstablished() {
        processGroupEstablished = true
    }

    @discardableResult
    func finalize() -> Bool {
        guard !finalized else { return forcedCleanup }
        finalized = true

        try? stdinPipe.fileHandleForWriting.close()
        let groupIsAlive = processGroupEstablished && processGroupExists()
        forcedCleanup = process.isRunning || groupIsAlive
        if process.isRunning || groupIsAlive {
            terminate(signal: SIGTERM)
            let termDeadline = Date().addingTimeInterval(0.5)
            while (process.isRunning || processGroupExists()), Date() < termDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        if process.isRunning || (processGroupEstablished && processGroupExists()) {
            terminate(signal: SIGKILL)
        }

        // Process owns the waitpid lifecycle. Once SIGKILL has been sent there is
        // no safe error path that may bypass this reap without leaking a zombie.
        process.waitUntilExit()

        if reads.wait(timeout: .now() + 1) == .timedOut {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            _ = reads.wait(timeout: .now() + 1)
        } else {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }
        return forcedCleanup
    }

    private func terminate(signal: Int32) {
        let pid = process.processIdentifier
        if processGroupEstablished || Darwin.getpgid(pid) == pid {
            _ = Darwin.kill(-pid, signal)
        } else {
            _ = Darwin.kill(pid, signal)
        }
    }

    private func processGroupExists() -> Bool {
        guard processGroupEstablished else { return false }
        errno = 0
        return Darwin.kill(-process.processIdentifier, 0) == 0 || errno == EPERM
    }
}

struct Qwen3TTSProcessRunner: Sendable {
    typealias ProcessGroupValidator = @Sendable (Int32) -> Bool
    private static let maximumCapturedBytes = 65_536
    private static let networkDeniedSandboxProfile = "(version 1) (allow default) (deny network-outbound) (deny network-inbound)"
    private let processGroupValidator: ProcessGroupValidator

    init(
        processGroupValidator: @escaping ProcessGroupValidator = {
            Darwin.getpgid($0) == $0
        }
    ) {
        self.processGroupValidator = processGroupValidator
    }

    func run(_ invocation: Qwen3TTSProcessInvocation) async throws {
        let cancellation = QwenProcessCancellation()
        do {
            try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try runBlocking(invocation, cancellation: cancellation)
                }.value
            } onCancel: {
                cancellation.cancel()
            }
        } catch is CancellationError {
            throw DialogueVoiceRuntimeError.cancelled
        }
    }

    private func runBlocking(
        _ invocation: Qwen3TTSProcessInvocation,
        cancellation: QwenProcessCancellation
    ) throws {
        let totalTimeout = min(120, max(0.05, invocation.timeout))
        let operationDeadline = ProcessInfo.processInfo.systemUptime + totalTimeout
        let control = QwenRuntimeValidationControl(
            deadlineUptime: operationDeadline,
            isCancelled: { cancellation.isCancelled }
        )
        try control.check()
        let runtimeBeforeLaunch = try Qwen3TTSProfileValidator.validatePythonExecutable(
            at: invocation.executableURL,
            control: control
        )
        guard runtimeBeforeLaunch == invocation.expectedRuntimeIdentity else {
            throw DialogueVoiceRuntimeError.inputFingerprintMismatch
        }
        let searchPlanBeforeLaunch = try Qwen3TTSProfileValidator.validatedRuntimeSearchPlan(
            at: invocation.executableURL,
            environment: invocation.environment,
            control: control
        )
        let helperIdentityBeforeLaunch = try Qwen3TTSProfileValidator.validateLaunchResource(
            at: invocation.helperURL,
            maximumBytes: 1_048_576,
            control: control
        )
        try Qwen3TTSProfileValidator.validateLaunchDirectory(
            at: invocation.currentDirectoryURL,
            control: control
        )
        let bootstrap = try Self.pythonBootstrap(searchPlan: searchPlanBeforeLaunch)
        try control.check()
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdout = QwenLockedDataBuffer(limit: Self.maximumCapturedBytes)
        let stderr = QwenLockedDataBuffer(limit: Self.maximumCapturedBytes)
        let reads = DispatchGroup()
        if invocation.deniesNetwork {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = [
                "-p", Self.networkDeniedSandboxProfile,
                invocation.executableURL.path,
                "-S", "-B", "-c", bootstrap, invocation.helperURL.path,
            ]
        } else {
            process.executableURL = invocation.executableURL
            process.arguments = [
                "-S", "-B", "-c", bootstrap, invocation.helperURL.path,
            ]
        }
        process.currentDirectoryURL = invocation.currentDirectoryURL
        var processEnvironment = invocation.environment
        processEnvironment["PYTHONHOME"] = searchPlanBeforeLaunch.pythonHome
        processEnvironment["PYTHONNOUSERSITE"] = "1"
        processEnvironment.removeValue(forKey: "PYTHONPATH")
        processEnvironment.removeValue(forKey: "__PYVENV_LAUNCHER__")
        process.environment = processEnvironment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do { try process.run() }
        catch { throw DialogueVoiceRuntimeError.inferenceUnavailable }
        cancellation.install(process)

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
        let finalizer = QwenProcessFinalizer(
            process: process,
            stdinPipe: stdinPipe,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            reads: reads
        )
        defer { finalizer.finalize() }

        let groupDeadline = min(operationDeadline, ProcessInfo.processInfo.systemUptime + 2)
        while process.isRunning,
              ProcessInfo.processInfo.systemUptime < groupDeadline,
              !cancellation.isCancelled,
              !processGroupValidator(process.processIdentifier) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard process.isRunning,
              processGroupValidator(process.processIdentifier) else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        finalizer.markProcessGroupEstablished()
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: invocation.standardInput)
            try stdinPipe.fileHandleForWriting.close()
        } catch {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }

        while process.isRunning,
              ProcessInfo.processInfo.systemUptime < operationDeadline,
              !cancellation.isCancelled {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if cancellation.isCancelled { throw DialogueVoiceRuntimeError.cancelled }
        guard !process.isRunning else { throw DialogueVoiceRuntimeError.inferenceUnavailable }
        let forcedCleanup = finalizer.finalize()
        let standardOutput = stdout.snapshot
        let standardError = stderr.snapshot
        guard !standardOutput.overflowed, !standardError.overflowed,
              standardOutput.data.isEmpty,
              standardError.data.isEmpty
                || standardError.data == Data("QWEN_TTS_FAILED\n".utf8)
                || standardError.data == Data("VOXCPM2_FAILED\n".utf8) else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        guard process.terminationStatus == 0 else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        guard !forcedCleanup else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        let runtimeAfterLaunch = try Qwen3TTSProfileValidator.validatePythonExecutable(
            at: invocation.executableURL,
            control: control
        )
        guard runtimeAfterLaunch == invocation.expectedRuntimeIdentity else {
            throw DialogueVoiceRuntimeError.sourceChanged
        }
        let searchPlanAfterLaunch = try Qwen3TTSProfileValidator.validatedRuntimeSearchPlan(
            at: invocation.executableURL,
            environment: invocation.environment,
            control: control
        )
        let helperIdentityAfterLaunch = try Qwen3TTSProfileValidator.validateLaunchResource(
            at: invocation.helperURL,
            maximumBytes: 1_048_576,
            control: control
        )
        guard searchPlanAfterLaunch == searchPlanBeforeLaunch,
              helperIdentityAfterLaunch == helperIdentityBeforeLaunch else {
            throw DialogueVoiceRuntimeError.sourceChanged
        }
        guard !invocation.requiresOutputFile
                || FileManager.default.fileExists(atPath: invocation.outputURL.path) else {
            throw DialogueVoiceRuntimeError.invalidAudio
        }
    }

    private static func pythonBootstrap(searchPlan: Qwen3TTSRuntimeSearchPlan) throws -> String {
        let rootsData = try JSONSerialization.data(
            withJSONObject: searchPlan.roots,
            options: [.withoutEscapingSlashes]
        )
        guard rootsData.count <= 262_144,
              let roots = String(data: rootsData, encoding: .utf8) else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        return "import sys;sys.path[:]=\(roots);p=sys.argv[1];sys.argv=sys.argv[1:];g={'__name__':'__main__','__file__':p,'__package__':None,'__cached__':None,'__spec__':None,'__loader__':None};exec(compile(open(p,'rb').read(),p,'exec'),g,g)"
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
        let validated = try Qwen3TTSProfileValidator.snapshot(
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
            executableURL: validated.pythonExecutable,
            expectedRuntimeIdentity: validated.runtimeIdentity,
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
            expectedRuntimeIdentity: validated.runtimeIdentity,
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
            "HF_DATASETS_OFFLINE": "1",
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

actor VoxCPM2Client {
    typealias Runner = @Sendable (Qwen3TTSProcessInvocation) async throws -> Void
    private static let maximumAudioBytes = 67_108_864
    private let helperExecutableURL: URL?
    private let probeExecutableURL: URL?
    private let runner: Runner

    init(helperExecutableURL: URL? = nil, probeExecutableURL: URL? = nil,
         runner: @escaping Runner = { try await Qwen3TTSProcessRunner().run($0) }) {
        self.helperExecutableURL = helperExecutableURL
        self.probeExecutableURL = probeExecutableURL
        self.runner = runner
    }

    func validateProfile(_ profile: VoxCPM2VoiceProfile, applicationSupportRoot: URL) async throws -> VoxCPM2ProbeResult {
        let validated = try VoxCPM2ProfileValidator.validate(profile: profile, applicationSupportRoot: applicationSupportRoot)
        let probe = try resolveResource(probeExecutableURL, named: "voxcpm2_probe.py")
        let job = applicationSupportRoot.appendingPathComponent("voice/tmp/\(UUID().uuidString.lowercased())", isDirectory: true)
        try DialogueVoiceAssetInstaller.ensurePrivateDirectory(job)
        defer { try? FileManager.default.removeItem(at: job) }
        let marker = job.appendingPathComponent("probe.json")
        let request = try JSONSerialization.data(withJSONObject: [
            "snapshot_root": validated.snapshotRoot.path,
            "model_root": validated.modelRoot.path,
            "probe_output": marker.path,
        ], options: [.sortedKeys])
        try await runner(Qwen3TTSProcessInvocation(
            executableURL: validated.pythonExecutable,
            expectedRuntimeIdentity: validated.runtimeIdentity,
            helperURL: probe, currentDirectoryURL: job,
            environment: Self.environment(home: job), standardInput: request,
            outputURL: marker, timeout: 30
        ))
        let data: Data
        do {
            data = try DialogueVoiceAssetInstaller.readManagedFile(
                relativePath: "voice/tmp/\(job.lastPathComponent)/probe.json",
                root: applicationSupportRoot,
                maximumBytes: 4_096
            )
        } catch {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schema"] as? Int == 1,
              let sampleRate = object["sample_rate"] as? Int,
              sampleRate == 48_000,
              let device = object["device"] as? String,
              ["mps", "cuda", "cpu"].contains(device) else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        return VoxCPM2ProbeResult(device: device, sampleRate: sampleRate)
    }

    func synthesize(profile: VoxCPM2VoiceProfile, line: DialogueLine,
                    applicationSupportRoot: URL, expectedIdentityTokens: [String]?) async throws -> Data {
        try Task.checkCancellation()
        guard !line.text.isEmpty, line.text.count <= 1_000 else { throw DialogueVoiceRuntimeError.requestRejected }
        let validated = try VoxCPM2ProfileValidator.validate(profile: profile, applicationSupportRoot: applicationSupportRoot)
        if let expectedIdentityTokens, expectedIdentityTokens != validated.identityTokens {
            throw DialogueVoiceRuntimeError.inputFingerprintMismatch
        }
        let helper = try resolveResource(helperExecutableURL, named: "voxcpm2_generate.py")
        let job = applicationSupportRoot.appendingPathComponent("voice/tmp/\(UUID().uuidString.lowercased())", isDirectory: true)
        try DialogueVoiceAssetInstaller.ensurePrivateDirectory(job)
        defer { try? FileManager.default.removeItem(at: job) }
        let output = job.appendingPathComponent("result.wav")
        let request = try JSONSerialization.data(withJSONObject: [
            "snapshot_root": validated.snapshotRoot.path,
            "model_root": validated.modelRoot.path,
            "prompt_wav_path": validated.referenceAudio.path,
            "reference_wav_path": validated.referenceAudio.path,
            "reference_text": profile.referenceText, "text": line.text, "output_file": output.path,
            "cfg_value": profile.parameters.cfgValue,
            "inference_timesteps": profile.parameters.inferenceTimesteps,
            "seed": profile.parameters.seed, "load_denoiser": false, "optimize": false,
        ], options: [.sortedKeys])
        guard request.count <= 262_144 else { throw DialogueVoiceRuntimeError.requestRejected }
        try await runner(Qwen3TTSProcessInvocation(
            executableURL: validated.pythonExecutable,
            expectedRuntimeIdentity: validated.runtimeIdentity,
            helperURL: helper, currentDirectoryURL: job,
            environment: Self.environment(home: job), standardInput: request, outputURL: output, timeout: 120
        ))
        try Task.checkCancellation()
        let after = try VoxCPM2ProfileValidator.validate(profile: profile, applicationSupportRoot: applicationSupportRoot)
        guard after.identityTokens == validated.identityTokens else { throw DialogueVoiceRuntimeError.sourceChanged }
        let data = try DialogueVoiceAssetInstaller.readManagedFile(
            relativePath: "voice/tmp/\(job.lastPathComponent)/result.wav", root: applicationSupportRoot,
            maximumBytes: UInt64(Self.maximumAudioBytes)
        )
        guard Self.isValidOutputWAV(data) else { throw DialogueVoiceRuntimeError.invalidAudio }
        return data
    }

    static func isValidOutputWAV(_ data: Data) -> Bool {
        guard data.count >= 44, data.count <= maximumAudioBytes,
              data.prefix(4) == Data("RIFF".utf8), data.dropFirst(8).prefix(4) == Data("WAVE".utf8),
              let declared = u32(data, 4), Int(declared) + 8 == data.count else { return false }
        var offset = 12; var format = false; var audio = false
        while offset + 8 <= data.count {
            let id = data.subdata(in: offset..<offset+4); guard let raw = u32(data, offset+4) else { return false }
            let size = Int(raw), start = offset + 8; guard size <= data.count - start else { return false }
            if id == Data("fmt ".utf8) {
                guard !format, size >= 16, u16(data,start) == 1, u16(data,start+2) == 1,
                      u32(data,start+4) == 48_000, u32(data,start+8) == 96_000,
                      u16(data,start+12) == 2, u16(data,start+14) == 16 else { return false }
                format = true
            } else if id == Data("data".utf8) {
                guard format, !audio, size > 0, size % 2 == 0, size / 2 <= 48_000 * 60 else { return false }
                audio = true
            }
            offset = start + size + (size & 1)
        }
        return format && audio && offset == data.count
    }

    private static func environment(home: URL) -> [String:String] { [
        "HOME": home.path, "PATH": "/usr/bin:/bin", "LC_ALL": "en_US.UTF-8",
        "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1", "HF_HUB_OFFLINE": "1",
        "TRANSFORMERS_OFFLINE": "1", "HF_DATASETS_OFFLINE": "1", "NO_PROXY": "*",
    ] }
    private func resolveResource(_ explicit: URL?, named: String) throws -> URL {
        let url = explicit ?? Bundle.main.resourceURL?.appendingPathComponent("VoxCPM2/\(named)")
        guard let url, url.isFileURL else { throw DialogueVoiceRuntimeError.inferenceUnavailable }
        var status = stat(); guard Darwin.lstat(url.path, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), status.st_size > 0,
              status.st_size <= 1_048_576 else { throw DialogueVoiceRuntimeError.inferenceUnavailable }
        return url
    }
    private static func u16(_ d: Data,_ o:Int)->UInt16? { guard o+2<=d.count else{return nil}; return UInt16(d[o])|UInt16(d[o+1])<<8 }
    private static func u32(_ d: Data,_ o:Int)->UInt32? { guard o+4<=d.count else{return nil}; return UInt32(d[o])|UInt32(d[o+1])<<8|UInt32(d[o+2])<<16|UInt32(d[o+3])<<24 }
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
