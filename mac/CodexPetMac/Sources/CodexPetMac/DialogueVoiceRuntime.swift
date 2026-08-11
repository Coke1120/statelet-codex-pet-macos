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
    func play(relativePath: String, applicationSupportRoot: URL) throws
    func stop()
}

final class DialogueAudioPlayer: DialogueAudioPlaying {
    private var player: AVAudioPlayer?

    var isPlaying: Bool { player?.isPlaying == true }

    func play(relativePath: String, applicationSupportRoot: URL) throws {
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
        player = next
        guard next.play() else {
            player = nil
            throw DialogueVoiceRuntimeError.invalidAudio
        }
    }

    func stop() {
        player?.stop()
        player = nil
    }
}

struct DialogueReadyPlaybackService {
    let applicationSupportRoot: URL
    let player: DialogueAudioPlaying

    func playReadyLine(id: UUID, in library: DialogueVoiceLibrary) -> DialoguePlaybackResult {
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
            try player.play(relativePath: output, applicationSupportRoot: applicationSupportRoot)
            return .played
        } catch {
            return .unavailable(.missingOrInvalidAudio)
        }
    }
}
