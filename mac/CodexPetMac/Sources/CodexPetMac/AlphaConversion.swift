import Darwin
import Foundation
import CodexPetCore

struct AlphaToolchain: Equatable {
    let python: URL
    let converter: URL
    let ffmpeg: URL
    let ffprobe: URL
    let avconvert: URL

    var summary: String {
        "ready — local background removal and Apple alpha verification"
    }
}

enum AlphaToolchainState: Equatable {
    case checking
    case ready(AlphaToolchain)
    case unavailable(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

enum AlphaConversionFailure: LocalizedError {
    case alreadyRunning
    case launchFailed
    case cancelled
    case converterFailed(String)
    case structuredConverterFailed(message: String, code: String, stage: String)
    case timedOut(String)
    case invalidProgressProtocol
    case missingArtifact

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Another animation conversion is already running."
        case .launchFailed:
            return "The local conversion process could not be started."
        case .cancelled:
            return "Conversion cancelled. Your current animation was not changed."
        case let .converterFailed(message):
            return message
        case let .structuredConverterFailed(message, _, _):
            return message
        case let .timedOut(stage):
            return "Conversion stopped because \(stage). Your current animation was not changed."
        case .invalidProgressProtocol:
            return "The converter returned invalid progress data. Your current animation was not changed."
        case .missingArtifact:
            return "Conversion finished without a verified movie and report."
        }
    }

    var conversionDiagnostic: (code: String, stage: String) {
        switch self {
        case .alreadyRunning: return ("ALREADY_RUNNING", "coordinator")
        case .launchFailed: return ("LAUNCH_FAILED", "prepare")
        case .cancelled: return ("CANCELLED", "coordinator")
        case .converterFailed: return ("CONVERSION_FAILED", "unknown")
        case let .structuredConverterFailed(_, code, stage): return (code, stage)
        case .timedOut: return ("PROCESS_TIMEOUT", "coordinator")
        case .invalidProgressProtocol: return ("PROGRESS_PROTOCOL_INVALID", "progress")
        case .missingArtifact: return ("ARTIFACT_MISSING", "publish")
        }
    }
}

struct AlphaConversionResult {
    let outputURL: URL
    let reportURL: URL
    let reportData: Data
}

enum AlphaConversionProfile: String, CaseIterable {
    static let defaultsKey = "StateletAlphaConversionProfile"

    case fill
    case fit

    var displayName: String {
        switch self {
        case .fill: return "Crop to Fill"
        case .fit: return "Fit with Padding"
        }
    }

    var resizeMode: String { rawValue }
    var commandProfile: String { "standard" }

    static func restored(from defaults: UserDefaults = .standard) -> AlphaConversionProfile {
        guard let value = defaults.string(forKey: defaultsKey),
              let profile = AlphaConversionProfile(rawValue: value) else { return .fill }
        return profile
    }

    func persist(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

enum AlphaRecoveryArtifactPolicy {
    static func accepts(
        artifactStem: String,
        outputBasename: String,
        reportBasename: String
    ) -> Bool {
        let prefix = "\(artifactStem)-"
        guard !artifactStem.isEmpty,
              artifactStem.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
              outputBasename.hasPrefix(prefix),
              outputBasename.hasSuffix(".mov"),
              outputBasename == URL(fileURLWithPath: outputBasename).lastPathComponent,
              !outputBasename.contains("/"),
              !outputBasename.contains("\\") else { return false }

        let tokenStart = outputBasename.index(outputBasename.startIndex, offsetBy: prefix.count)
        let tokenEnd = outputBasename.index(outputBasename.endIndex, offsetBy: -4)
        guard tokenStart < tokenEnd else { return false }
        let components = outputBasename[tokenStart..<tokenEnd].split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 2,
              !components[0].isEmpty,
              components[0].allSatisfy(\.isNumber),
              components[1].count == 8,
              components[1].allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return false }

        let expectedReport = String(outputBasename.dropLast(4)) + ".report.json"
        return reportBasename == expectedReport
    }
}

enum PortableMediaFileKind: Equatable {
    case movie
    case report
}

struct PortableMediaCopyLimits {
    let maxMovieBytes: UInt64
    let maxReportBytes: UInt64
    let minimumFreeSpaceReserveBytes: UInt64
    let chunkBytes: Int

    init(
        maxMovieBytes: UInt64 = 536_870_912,
        maxReportBytes: UInt64 = 1_048_576,
        minimumFreeSpaceReserveBytes: UInt64 = 67_108_864,
        chunkBytes: Int = 1_048_576
    ) {
        self.maxMovieBytes = maxMovieBytes
        self.maxReportBytes = maxReportBytes
        self.minimumFreeSpaceReserveBytes = minimumFreeSpaceReserveBytes
        self.chunkBytes = max(1, chunkBytes)
    }
}

struct PortableMediaCopyResult: Sendable {
    let movieURL: URL
    let reportURL: URL
}

struct PortableMediaFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
}

enum PortableMediaCopyError: LocalizedError {
    case nonLocalFile
    case invalidSource
    case sourceTooLarge(String)
    case insufficientDiskSpace
    case destinationExists
    case sourceChanged
    case copyFailed
    case cancelled
    case timedOut

    var errorDescription: String? {
        switch self {
        case .nonLocalFile: return "Only local portable movie files can be imported."
        case .invalidSource: return "The portable movie and report must be regular, non-symbolic-link files."
        case let .sourceTooLarge(kind): return "The portable \(kind) exceeds Statelet’s safe import limit."
        case .insufficientDiskSpace: return "There is not enough free disk space to import this portable movie safely."
        case .destinationExists: return "Statelet could not create a private destination for the portable movie."
        case .sourceChanged: return "The portable movie or report changed while it was being copied."
        case .copyFailed: return "The portable movie could not be copied safely."
        case .cancelled: return "Portable movie import was cancelled."
        case .timedOut: return "Portable movie import timed out before it could be verified safely."
        }
    }
}

final class PortableMediaOperationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled || Task.isCancelled { throw PortableMediaCopyError.cancelled }
    }
}

private final class PortableMediaContinuation<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(with result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return false
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
        return true
    }
}

enum PortableMediaOperationRunner {
    static func run<Value: Sendable>(
        timeoutSeconds: TimeInterval,
        operation: @escaping @Sendable (PortableMediaOperationToken) async throws -> Value
    ) async throws -> Value {
        let token = PortableMediaOperationToken()
        return try await withCheckedThrowingContinuation { continuation in
            let gate = PortableMediaContinuation<Value>(continuation)
            let task = Task.detached(priority: .userInitiated) {
                do {
                    gate.resume(with: .success(try await operation(token)))
                } catch {
                    gate.resume(with: .failure(error))
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + max(0.05, timeoutSeconds)
            ) {
                if gate.resume(with: .failure(PortableMediaCopyError.timedOut)) {
                    token.cancel()
                    task.cancel()
                }
            }
        }
    }
}

struct PortableMediaSecureCopier {
    typealias DiskSpaceProvider = (URL) throws -> UInt64
    typealias ChunkObserver = (PortableMediaFileKind) -> Void
    typealias OperationCheck = () throws -> Void

    let limits: PortableMediaCopyLimits
    private let availableDiskBytes: DiskSpaceProvider
    private let afterChunk: ChunkObserver?
    private let operationCheck: OperationCheck

    init(
        limits: PortableMediaCopyLimits = PortableMediaCopyLimits(),
        availableDiskBytes: @escaping DiskSpaceProvider = Self.systemAvailableDiskBytes,
        afterChunk: ChunkObserver? = nil,
        operationCheck: @escaping OperationCheck = {}
    ) {
        self.limits = limits
        self.availableDiskBytes = availableDiskBytes
        self.afterChunk = afterChunk
        self.operationCheck = operationCheck
    }

    func copyPair(
        movieSource: URL,
        reportSource: URL,
        destinationDirectory: URL
    ) throws -> PortableMediaCopyResult {
        try operationCheck()
        let movie = try openRegularSource(movieSource, maximumBytes: limits.maxMovieBytes, kind: "movie")
        defer { Darwin.close(movie.descriptor) }
        let report = try openRegularSource(reportSource, maximumBytes: limits.maxReportBytes, kind: "report")
        defer { Darwin.close(report.descriptor) }

        let required = try requiredDiskBytes(movie: movie.size, report: report.size)
        do {
            try FileManager.default.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw PortableMediaCopyError.destinationExists
        }
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: destinationDirectory) }
        }

        let directoryDescriptor = Darwin.open(
            destinationDirectory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else { throw PortableMediaCopyError.copyFailed }
        defer { Darwin.close(directoryDescriptor) }
        guard Darwin.fchmod(directoryDescriptor, mode_t(S_IRWXU)) == 0 else {
            throw PortableMediaCopyError.copyFailed
        }

        guard try availableDiskBytes(destinationDirectory) >= required else {
            throw PortableMediaCopyError.insufficientDiskSpace
        }
        let movieName = try safeBasename(movieSource)
        let reportName = try safeBasename(reportSource)
        guard movieName != reportName else { throw PortableMediaCopyError.invalidSource }

        try copy(
            source: movie,
            destinationDirectoryDescriptor: directoryDescriptor,
            destinationName: movieName,
            kind: .movie
        )
        try copy(
            source: report,
            destinationDirectoryDescriptor: directoryDescriptor,
            destinationName: reportName,
            kind: .report
        )
        try operationCheck()
        guard sourceStillMatches(movie), sourceStillMatches(report) else {
            throw PortableMediaCopyError.sourceChanged
        }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw PortableMediaCopyError.copyFailed
        }
        try operationCheck()
        completed = true
        return PortableMediaCopyResult(
            movieURL: destinationDirectory.appendingPathComponent(movieName),
            reportURL: destinationDirectory.appendingPathComponent(reportName)
        )
    }

    static func readRegularFile(
        at url: URL,
        maximumBytes: UInt64,
        operationCheck: () throws -> Void = {}
    ) throws -> Data {
        try operationCheck()
        guard isLocalFileURL(url) else { throw PortableMediaCopyError.nonLocalFile }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PortableMediaCopyError.invalidSource }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_size >= 0,
              UInt64(status.st_size) <= maximumBytes else {
            throw PortableMediaCopyError.invalidSource
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        while true {
            try operationCheck()
            guard let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty else { break }
            data.append(chunk)
            guard UInt64(data.count) <= maximumBytes else {
                throw PortableMediaCopyError.sourceTooLarge("report")
            }
        }
        try operationCheck()
        var finalStatus = stat()
        guard Darwin.fstat(descriptor, &finalStatus) == 0,
              sameIdentityAndMetadata(status, finalStatus),
              UInt64(data.count) == UInt64(status.st_size) else {
            throw PortableMediaCopyError.sourceChanged
        }
        return data
    }

    static func regularFileIdentity(
        at url: URL,
        maximumBytes: UInt64
    ) throws -> PortableMediaFileIdentity {
        guard isLocalFileURL(url) else { throw PortableMediaCopyError.nonLocalFile }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PortableMediaCopyError.invalidSource }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_size >= 0,
              UInt64(status.st_size) <= maximumBytes else {
            throw PortableMediaCopyError.invalidSource
        }
        return PortableMediaFileIdentity(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            size: Int64(status.st_size),
            modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            changedSeconds: Int64(status.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(status.st_ctimespec.tv_nsec)
        )
    }

    private struct OpenSource {
        let descriptor: Int32
        let status: stat
        let size: UInt64
    }

    private func openRegularSource(
        _ url: URL,
        maximumBytes: UInt64,
        kind: String
    ) throws -> OpenSource {
        try operationCheck()
        guard Self.isLocalFileURL(url) else { throw PortableMediaCopyError.nonLocalFile }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw PortableMediaCopyError.invalidSource }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_size > 0 else {
            Darwin.close(descriptor)
            throw PortableMediaCopyError.invalidSource
        }
        let size = UInt64(status.st_size)
        guard size <= maximumBytes else {
            Darwin.close(descriptor)
            throw PortableMediaCopyError.sourceTooLarge(kind)
        }
        return OpenSource(descriptor: descriptor, status: status, size: size)
    }

    private func requiredDiskBytes(movie: UInt64, report: UInt64) throws -> UInt64 {
        let (content, contentOverflow) = movie.addingReportingOverflow(report)
        let (required, reserveOverflow) = content.addingReportingOverflow(limits.minimumFreeSpaceReserveBytes)
        guard !contentOverflow, !reserveOverflow else { throw PortableMediaCopyError.copyFailed }
        return required
    }

    private func copy(
        source: OpenSource,
        destinationDirectoryDescriptor: Int32,
        destinationName: String,
        kind: PortableMediaFileKind
    ) throws {
        let destination = Darwin.openat(
            destinationDirectoryDescriptor,
            destinationName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard destination >= 0 else { throw PortableMediaCopyError.destinationExists }
        defer { Darwin.close(destination) }
        guard Darwin.fchmod(destination, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw PortableMediaCopyError.copyFailed
        }

        var buffer = [UInt8](repeating: 0, count: limits.chunkBytes)
        var copied: UInt64 = 0
        while copied < source.size {
            try operationCheck()
            let wanted = min(buffer.count, Int(source.size - copied))
            let count = Darwin.read(source.descriptor, &buffer, wanted)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw PortableMediaCopyError.sourceChanged }
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes { bytes in
                    Darwin.write(destination, bytes.baseAddress!.advanced(by: written), count - written)
                }
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw PortableMediaCopyError.copyFailed }
                written += result
            }
            copied += UInt64(count)
            afterChunk?(kind)
            try operationCheck()
        }
        guard copied == source.size, Darwin.fsync(destination) == 0 else {
            throw PortableMediaCopyError.copyFailed
        }
        var finalSource = stat()
        var finalDestination = stat()
        guard Darwin.fstat(source.descriptor, &finalSource) == 0,
              Darwin.fstat(destination, &finalDestination) == 0,
              Self.sameIdentityAndMetadata(source.status, finalSource),
              finalDestination.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              UInt64(finalDestination.st_size) == copied else {
            throw PortableMediaCopyError.sourceChanged
        }
        try operationCheck()
    }

    private static func sameIdentityAndMetadata(_ before: stat, _ after: stat) -> Bool {
        before.st_dev == after.st_dev
            && before.st_ino == after.st_ino
            && before.st_size == after.st_size
            && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
            && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
            && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }

    private func sourceStillMatches(_ source: OpenSource) -> Bool {
        var finalStatus = stat()
        return Darwin.fstat(source.descriptor, &finalStatus) == 0
            && Self.sameIdentityAndMetadata(source.status, finalStatus)
    }

    private func safeBasename(_ url: URL) throws -> String {
        let value = url.lastPathComponent
        guard !value.isEmpty,
              value == URL(fileURLWithPath: value).lastPathComponent,
              !value.contains("/"),
              !value.contains("\\") else { throw PortableMediaCopyError.invalidSource }
        return value
    }

    private static func isLocalFileURL(_ url: URL) -> Bool {
        url.isFileURL && (url.host.map { $0.isEmpty || $0 == "localhost" } ?? true)
    }

    private static func systemAvailableDiskBytes(at url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage,
              available >= 0 else {
            throw PortableMediaCopyError.copyFailed
        }
        return UInt64(available)
    }
}

final class AlphaToolchainDiscovery {
    static let configuredPythonDefaultsKey = "StateletAlphaPythonPath"

    private let fileManager: FileManager
    private let environment: [String: String]
    private let bundle: Bundle
    private let userDefaults: UserDefaults

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        userDefaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.bundle = bundle
        self.userDefaults = userDefaults
    }

    func discover(completion: @escaping (AlphaToolchainState) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = discoverSynchronously()
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func discoverSynchronously() -> AlphaToolchainState {
        guard let converter = firstReadableFile(converterCandidates()) else {
            return .unavailable("Converter resources are missing. Rebuild or reinstall Statelet.")
        }
        guard let ffmpeg = firstExecutable(toolCandidates(environmentKey: "STATELET_FFMPEG", legacyEnvironmentKey: "CODEX_PET_FFMPEG", name: "ffmpeg")),
              let ffprobe = firstExecutable(toolCandidates(environmentKey: "STATELET_FFPROBE", legacyEnvironmentKey: "CODEX_PET_FFPROBE", name: "ffprobe")) else {
            return .unavailable("ffmpeg and ffprobe are required. Install them with Homebrew, then check again.")
        }
        guard let avconvert = firstExecutable(avconvertCandidates()) else {
            return .unavailable("Apple avconvert is unavailable on this Mac.")
        }
        guard let python = pythonCandidates().first(where: pythonSupportsImageDependencies) else {
            return .unavailable("Python with NumPy and Pillow is required for background removal.")
        }
        guard converterSupportsExpectedCLI(python: python, converter: converter) else {
            return .unavailable("The installed converter is incompatible with this version of Statelet.")
        }
        return .ready(
            AlphaToolchain(
                python: python,
                converter: converter,
                ffmpeg: ffmpeg,
                ffprobe: ffprobe,
                avconvert: avconvert
            )
        )
    }

    private func converterCandidates() -> [URL] {
        var candidates: [URL] = []
        if let configured = environmentValue(
            canonical: "STATELET_ALPHA_CONVERTER",
            legacy: "CODEX_PET_ALPHA_CONVERTER"
        ) {
            candidates.append(URL(fileURLWithPath: configured))
        }
        if let resources = bundle.resourceURL {
            candidates.append(
                resources
                    .appendingPathComponent("AlphaTools", isDirectory: true)
                    .appendingPathComponent("convert_codex_pet_macos_alpha.py")
            )
        }
        // Developer builds launched with `swift run` do not have an app bundle.
        // A packaged app never silently reaches back into a checkout.
        if bundle.bundleURL.pathExtension != "app" {
            candidates.append(
                URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
                    .appendingPathComponent("tools", isDirectory: true)
                    .appendingPathComponent("convert_codex_pet_macos_alpha.py")
            )
        }
        return unique(candidates)
    }

    private func pythonCandidates() -> [URL] {
        var candidates: [URL] = []
        if let configured = environmentValue(
            canonical: "STATELET_ALPHA_PYTHON",
            legacy: "CODEX_PET_ALPHA_PYTHON"
        ) {
            candidates.append(URL(fileURLWithPath: configured))
        }
        if let configured = userDefaults.string(forKey: Self.configuredPythonDefaultsKey) {
            candidates.append(URL(fileURLWithPath: configured))
        }
        let home = fileManager.homeDirectoryForCurrentUser
        candidates.append(
            home
                .appendingPathComponent(
                    "\(StateletIdentity.applicationSupportRelativePath)/alpha-runtime/bin/python3"
                )
        )
        candidates.append(
            home
                .appendingPathComponent(".cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3")
        )
        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/python3"),
            URL(fileURLWithPath: "/usr/local/bin/python3"),
            URL(fileURLWithPath: "/usr/bin/python3"),
        ])
        return unique(candidates).filter(isExecutable)
    }

    private func toolCandidates(
        environmentKey: String,
        legacyEnvironmentKey: String,
        name: String
    ) -> [URL] {
        var candidates: [URL] = []
        if let configured = environmentValue(
            canonical: environmentKey,
            legacy: legacyEnvironmentKey
        ) {
            candidates.append(URL(fileURLWithPath: configured))
        }
        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            URL(fileURLWithPath: "/usr/local/bin/\(name)"),
            URL(fileURLWithPath: "/usr/bin/\(name)"),
        ])
        return unique(candidates)
    }

    private func avconvertCandidates() -> [URL] {
        var candidates: [URL] = []
        if let configured = environmentValue(
            canonical: "STATELET_AVCONVERT",
            legacy: "CODEX_PET_AVCONVERT"
        ) {
            candidates.append(URL(fileURLWithPath: configured))
        }
        candidates.append(URL(fileURLWithPath: "/usr/bin/avconvert"))
        return unique(candidates)
    }

    private func environmentValue(canonical: String, legacy: String) -> String? {
        environment[canonical] ?? environment[legacy]
    }

    private func pythonSupportsImageDependencies(_ python: URL) -> Bool {
        let process = Process()
        process.executableURL = python
        process.arguments = ["-c", "import numpy, PIL"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            return false
        }
        return process.terminationStatus == 0
    }

    private func converterSupportsExpectedCLI(python: URL, converter: URL) -> Bool {
        let process = Process()
        process.executableURL = python
        process.arguments = ["-B", converter.path, "--help"]
        process.currentDirectoryURL = converter.deletingLastPathComponent()
        process.environment = [
            "HOME": fileManager.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin",
            "LC_ALL": "en_US.UTF-8",
            "PYTHONDONTWRITEBYTECODE": "1",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            return false
        }
        return process.terminationStatus == 0
    }

    private func firstExecutable(_ candidates: [URL]) -> URL? {
        candidates.first(where: isExecutable)
    }

    private func firstReadableFile(_ candidates: [URL]) -> URL? {
        candidates.first {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
                && fileManager.isReadableFile(atPath: $0.path)
        }
    }

    private func isExecutable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && fileManager.isExecutableFile(atPath: url.path)
    }

    private func unique(_ candidates: [URL]) -> [URL] {
        var seen = Set<String>()
        return candidates.compactMap {
            let standardized = $0.standardizedFileURL
            return seen.insert(standardized.path).inserted ? standardized : nil
        }
    }
}

private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        if storage.count > limit {
            storage.removeFirst(storage.count - limit)
        }
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class LockedActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var lastActivity = Date()

    func recordActivity() {
        lock.lock()
        lastActivity = Date()
        lock.unlock()
    }

    var date: Date {
        lock.lock()
        defer { lock.unlock() }
        return lastActivity
    }
}

private final class LockedProgressProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false

    func recordFailure() {
        lock.lock()
        failed = true
        lock.unlock()
    }

    var hasFailed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }
}

private final class LockedTerminalConversionFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (message: String, code: String, stage: String)?

    func record(_ progress: AlphaConversionProgress) {
        guard progress.isTerminalFailure,
              let code = progress.code,
              let safeMessage = progress.safeMessage else { return }
        lock.lock()
        value = (safeMessage, code, progress.stage)
        lock.unlock()
    }

    var failure: (message: String, code: String, stage: String)? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

enum AlphaPlaybackProcessError: LocalizedError {
    case launchFailed
    case timedOut
    case helperFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .launchFailed: return "Playback verification could not be started."
        case .timedOut: return "Playback verification timed out. The animation was not installed."
        case .helperFailed: return "AVFoundation could not verify this animation for playback."
        case .invalidResponse: return "Playback verification returned invalid data."
        }
    }
}

enum AlphaPlaybackProcessValidator {
    static let defaultTimeoutSeconds: TimeInterval = 15
    private static let maximumResponseBytes = 65_536

    static func validate(
        url: URL,
        expected report: ValidatedAlphaConversionReport,
        timeoutSeconds: TimeInterval = defaultTimeoutSeconds,
        helperExecutableURL: URL? = nil
    ) throws -> AlphaPlaybackProbe {
        let playbackProbe = try probe(
            url: url,
            timeoutSeconds: timeoutSeconds,
            helperExecutableURL: helperExecutableURL
        )
        return try AlphaPlaybackAcceptanceValidator.validate(probe: playbackProbe, expected: report)
    }

    static func probe(
        url: URL,
        timeoutSeconds: TimeInterval = defaultTimeoutSeconds,
        helperExecutableURL: URL? = nil
    ) throws -> AlphaPlaybackProbe {
        guard url.isFileURL,
              url.host.map({ $0.isEmpty || $0 == "localhost" }) ?? true,
              let executable = helperExecutableURL
                ?? Bundle.main.executableURL
                ?? CommandLine.arguments.first.map({ URL(fileURLWithPath: $0) }) else {
            throw AlphaPlaybackProcessError.launchFailed
        }
        let process = Process()
        let stdoutPipe = Pipe()
        let output = LockedDataBuffer(limit: maximumResponseBytes)
        let readGroup = DispatchGroup()
        process.executableURL = executable
        process.arguments = ["--statelet-playback-smoke-helper", url.path]
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin",
            "LC_ALL": "en_US.UTF-8",
        ]
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw AlphaPlaybackProcessError.launchFailed
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let handle = stdoutPipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                guard !chunk.isEmpty else { break }
                output.append(chunk)
            }
            readGroup.leave()
        }

        let pid = process.processIdentifier
        let deadline = Date().addingTimeInterval(max(0.05, timeoutSeconds))
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            terminate(pid: pid, signal: SIGTERM)
            let graceDeadline = Date().addingTimeInterval(0.2)
            while process.isRunning, Date() < graceDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { terminate(pid: pid, signal: SIGKILL) }
            let killDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if !process.isRunning { process.waitUntilExit() }
            if readGroup.wait(timeout: .now() + 0.5) == .timedOut {
                try? stdoutPipe.fileHandleForReading.close()
            }
            throw AlphaPlaybackProcessError.timedOut
        }
        process.waitUntilExit()
        if readGroup.wait(timeout: .now() + 1) == .timedOut {
            try? stdoutPipe.fileHandleForReading.close()
            throw AlphaPlaybackProcessError.invalidResponse
        }
        guard process.terminationStatus == 0 else {
            throw AlphaPlaybackProcessError.helperFailed
        }
        do {
            return try JSONDecoder().decode(AlphaPlaybackProbe.self, from: output.data)
        } catch {
            throw AlphaPlaybackProcessError.invalidResponse
        }
    }

    private static func terminate(pid: pid_t, signal: Int32) {
        if Darwin.getpgid(pid) == pid {
            _ = Darwin.kill(-pid, signal)
        } else {
            _ = Darwin.kill(pid, signal)
        }
    }
}

final class AlphaConversionCoordinator {
    static let maximumCapturedOutputBytes = 64 * 1_024
    static let maximumProgressLineBytes = 64 * 1_024
    static let overallDeadlineSeconds: TimeInterval = 30 * 60
    static let noProgressDeadlineSeconds: TimeInterval = 5 * 60
    static let terminationGraceSeconds: TimeInterval = 3

    private let queue = DispatchQueue(
        label: "\(StateletIdentity.bundleIdentifier).alpha-conversion",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private let overallDeadline: TimeInterval
    private let noProgressDeadline: TimeInterval
    private let terminationGrace: TimeInterval
    private var activeProcess: Process?
    private var activeProcessGroupPID: pid_t?
    private var cancellationRequested = false

    init(
        overallDeadlineSeconds: TimeInterval = AlphaConversionCoordinator.overallDeadlineSeconds,
        noProgressDeadlineSeconds: TimeInterval = AlphaConversionCoordinator.noProgressDeadlineSeconds,
        terminationGraceSeconds: TimeInterval = AlphaConversionCoordinator.terminationGraceSeconds
    ) {
        overallDeadline = max(0.1, overallDeadlineSeconds)
        noProgressDeadline = max(0.1, noProgressDeadlineSeconds)
        terminationGrace = max(0.05, terminationGraceSeconds)
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeProcess != nil
    }

    func convert(
        sourceURL: URL,
        outputURL: URL,
        reportURL: URL,
        width: Int,
        height: Int,
        toolchain: AlphaToolchain,
        invocationChallenge: String,
        profile: AlphaConversionProfile = .fill,
        phase: @escaping (String) -> Void,
        progress: @escaping (AlphaConversionProgress) -> Void = { _ in },
        completion: @escaping (Result<AlphaConversionResult, Error>) -> Void
    ) {
        lock.lock()
        guard activeProcess == nil else {
            lock.unlock()
            DispatchQueue.main.async { completion(.failure(AlphaConversionFailure.alreadyRunning)) }
            return
        }
        cancellationRequested = false
        let process = Process()
        activeProcess = process
        lock.unlock()

        DispatchQueue.main.async {
            phase("Preflighting source compatibility, disk space, and \(profile.displayName.lowercased())…")
        }
        queue.async { [weak self] in
            guard let self else { return }
            let result = run(
                process: process,
                sourceURL: sourceURL,
                outputURL: outputURL,
                reportURL: reportURL,
                width: width,
                height: height,
                toolchain: toolchain,
                invocationChallenge: invocationChallenge,
                profile: profile,
                phase: phase,
                progress: progress
            )
            lock.lock()
            activeProcess = nil
            activeProcessGroupPID = nil
            let wasCancelled = cancellationRequested
            cancellationRequested = false
            lock.unlock()
            let finalResult: Result<AlphaConversionResult, Error> = wasCancelled
                ? .failure(AlphaConversionFailure.cancelled)
                : result
            DispatchQueue.main.async { completion(finalResult) }
        }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let process = activeProcess
        let processGroupPID = activeProcessGroupPID
        lock.unlock()
        if let processGroupPID {
            Darwin.kill(-processGroupPID, SIGTERM)
        } else if let process, process.isRunning {
            process.terminate()
        }
    }

    @discardableResult
    func terminateAndWait(
        graceSeconds: TimeInterval = 1,
        deadlineSeconds: TimeInterval = 4
    ) -> Bool {
        let startedAt = Date()
        let grace = max(0, graceSeconds)
        let deadline = max(grace + 0.1, deadlineSeconds)
        var ownedGroupPID: pid_t?
        var sentTermination = false
        var sentKill = false

        lock.lock()
        cancellationRequested = true
        lock.unlock()

        while Date().timeIntervalSince(startedAt) < deadline {
            lock.lock()
            let process = activeProcess
            if let groupPID = activeProcessGroupPID { ownedGroupPID = groupPID }
            lock.unlock()

            if let groupPID = ownedGroupPID {
                if !sentTermination {
                    terminateProcessGroup(groupPID, signal: SIGTERM)
                    sentTermination = true
                }
                if !sentKill, Date().timeIntervalSince(startedAt) >= grace {
                    terminateProcessGroup(groupPID, signal: SIGKILL)
                    sentKill = true
                }
            } else if let process, process.isRunning, !sentTermination {
                process.terminate()
                sentTermination = true
            }

            let groupAlive = ownedGroupPID.map(processGroupExists) ?? false
            if process == nil, !groupAlive { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }

        if let groupPID = ownedGroupPID {
            terminateProcessGroup(groupPID, signal: SIGKILL)
        } else {
            lock.lock()
            let process = activeProcess
            lock.unlock()
            if let process, process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }

        let finalDeadline = Date().addingTimeInterval(0.5)
        while Date() < finalDeadline {
            lock.lock()
            let active = activeProcess != nil
            lock.unlock()
            let groupAlive = ownedGroupPID.map(processGroupExists) ?? false
            if !active, !groupAlive { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    private func run(
        process: Process,
        sourceURL: URL,
        outputURL: URL,
        reportURL: URL,
        width: Int,
        height: Int,
        toolchain: AlphaToolchain,
        invocationChallenge: String,
        profile: AlphaConversionProfile,
        phase: @escaping (String) -> Void,
        progress: @escaping (AlphaConversionProgress) -> Void
    ) -> Result<AlphaConversionResult, Error> {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdout = LockedDataBuffer(limit: Self.maximumCapturedOutputBytes)
        let stderr = LockedDataBuffer(limit: Self.maximumCapturedOutputBytes)
        let activityClock = LockedActivityClock()
        let progressProtocol = LockedProgressProtocolState()
        let terminalFailure = LockedTerminalConversionFailure()
        let readGroup = DispatchGroup()

        process.executableURL = toolchain.python
        process.arguments = [
            "-B",
            toolchain.converter.path,
            sourceURL.path,
            outputURL.path,
            "--report", reportURL.path,
            "--ffmpeg", toolchain.ffmpeg.path,
            "--ffprobe", toolchain.ffprobe.path,
            "--avconvert", toolchain.avconvert.path,
            "--width", String(width),
            "--height", String(height),
            "--profile", profile.commandProfile,
            "--resize-mode", profile.resizeMode,
            "--invocation-challenge", invocationChallenge,
            "--progress-jsonl",
        ]
        process.currentDirectoryURL = outputURL.deletingLastPathComponent()
        process.environment = boundedEnvironment(toolchain: toolchain, outputURL: outputURL)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return .failure(AlphaConversionFailure.launchFailed)
        }
        guard waitForOwnedProcessGroup(process) else {
            process.terminate()
            return .failure(AlphaConversionFailure.launchFailed)
        }
        lock.lock()
        activeProcessGroupPID = process.processIdentifier
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel {
            Darwin.kill(-process.processIdentifier, SIGTERM)
        }

        DispatchQueue.main.async {
            phase("Removing background, encoding, and verifying transparency…")
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            var lineBuffer = Data()
            var parser = AlphaConversionProgressParser()
            let handle = stdoutPipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                guard !chunk.isEmpty else { break }
                stdout.append(chunk)
                lineBuffer.append(chunk)
                if lineBuffer.count > Self.maximumProgressLineBytes {
                    progressProtocol.recordFailure()
                    lineBuffer.removeFirst(lineBuffer.count - Self.maximumProgressLineBytes)
                }
                while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
                    let lineData = lineBuffer[..<newlineIndex]
                    lineBuffer.removeSubrange(...newlineIndex)
                    let line = String(decoding: lineData, as: UTF8.self)
                    do {
                        if let event = try parser.parseLine(line) {
                            activityClock.recordActivity()
                            terminalFailure.record(event)
                            DispatchQueue.main.async { progress(event) }
                        }
                    } catch {
                        progressProtocol.recordFailure()
                    }
                }
            }
            if !lineBuffer.isEmpty {
                let line = String(decoding: lineBuffer, as: UTF8.self)
                do {
                    if let event = try parser.parseLine(line) {
                        activityClock.recordActivity()
                        terminalFailure.record(event)
                        DispatchQueue.main.async { progress(event) }
                    }
                } catch {
                    progressProtocol.recordFailure()
                }
            }
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let handle = stderrPipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                guard !chunk.isEmpty else { break }
                stderr.append(chunk)
            }
            readGroup.leave()
        }
        let startedAt = Date()
        var terminationStartedAt: Date?
        var timeoutFailure: AlphaConversionFailure?
        while process.isRunning {
            lock.lock()
            let shouldCancel = cancellationRequested
            lock.unlock()
            let now = Date()
            if terminationStartedAt == nil {
                if shouldCancel {
                    terminateProcessGroup(process.processIdentifier, signal: SIGTERM)
                    terminationStartedAt = now
                } else if now.timeIntervalSince(startedAt) > overallDeadline {
                    timeoutFailure = .timedOut("the 30-minute safety deadline was reached")
                    terminateProcessGroup(process.processIdentifier, signal: SIGTERM)
                    terminationStartedAt = now
                } else if now.timeIntervalSince(activityClock.date) > noProgressDeadline {
                    timeoutFailure = .timedOut("the converter made no progress for 5 minutes")
                    terminateProcessGroup(process.processIdentifier, signal: SIGTERM)
                    terminationStartedAt = now
                }
            } else if let terminationStartedAt,
                      now.timeIntervalSince(terminationStartedAt) > terminationGrace {
                terminateProcessGroup(process.processIdentifier, signal: SIGKILL)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        if readGroup.wait(timeout: .now() + 2) == .timedOut {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            _ = readGroup.wait(timeout: .now() + 1)
        }

        if let timeoutFailure {
            return .failure(timeoutFailure)
        }

        if progressProtocol.hasFailed {
            return .failure(AlphaConversionFailure.invalidProgressProtocol)
        }
        if let failure = terminalFailure.failure {
            return .failure(
                AlphaConversionFailure.structuredConverterFailed(
                    message: failure.message,
                    code: failure.code,
                    stage: failure.stage
                )
            )
        }
        if process.terminationStatus != 0 {
            let safeMessage = Self.sanitizedFailureMessage(from: stderr.data)
            return .failure(AlphaConversionFailure.converterFailed(safeMessage))
        }
        guard FileManager.default.isReadableFile(atPath: outputURL.path),
              let reportData = try? PortableMediaSecureCopier.readRegularFile(
                  at: reportURL,
                  maximumBytes: PortableMediaCopyLimits().maxReportBytes
              ) else {
            return .failure(AlphaConversionFailure.missingArtifact)
        }
        _ = stdout.data
        return .success(AlphaConversionResult(outputURL: outputURL, reportURL: reportURL, reportData: reportData))
    }

    private func boundedEnvironment(toolchain: AlphaToolchain, outputURL: URL) -> [String: String] {
        let fileManager = FileManager.default
        let toolDirectories = [
            toolchain.ffmpeg.deletingLastPathComponent().path,
            toolchain.ffprobe.deletingLastPathComponent().path,
            toolchain.avconvert.deletingLastPathComponent().path,
            "/usr/bin",
            "/bin",
        ]
        return [
            "HOME": fileManager.homeDirectoryForCurrentUser.path,
            "PATH": Array(Set(toolDirectories)).sorted().joined(separator: ":"),
            "TMPDIR": FileManager.default.temporaryDirectory.path,
            "LC_ALL": "en_US.UTF-8",
            "PYTHONDONTWRITEBYTECODE": "1",
        ]
    }

    static func sanitizedFailureMessage(from data: Data) -> String {
        let raw = String(data: data.suffix(8_192), encoding: .utf8) ?? ""
        let lastLine = raw
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        guard let lastLine else {
            return "The background could not be removed safely. Your current animation was not changed."
        }
        let mediaPathRedacted = lastLine
            .replacingOccurrences(
                of: #"(?i)/(?:Users|Volumes|private|tmp|var|Applications|Library)/[^\r\n\"']*?\.(?:mp4|mov|m4v|json|py|png|jpe?g|heic|webm|mkv)"#,
                with: "<local-file>",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)/(?:Users|Volumes|private|tmp|var|Applications|Library)/[^\r\n\"']+"#,
                with: "<local-file>",
                options: .regularExpression
            )
        let basenameOnly = mediaPathRedacted
            .replacingOccurrences(
                of: #"(?:/[^\s:'\"]+)+"#,
                with: "<local-file>",
                options: .regularExpression
            )
        return String(basenameOnly.prefix(500))
    }

    private func waitForOwnedProcessGroup(_ process: Process) -> Bool {
        let pid = process.processIdentifier
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            if Darwin.getpgid(pid) == pid {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    private func terminateProcessGroup(_ pid: pid_t, signal: Int32) {
        if Darwin.getpgid(pid) == pid {
            _ = Darwin.kill(-pid, signal)
        } else {
            _ = Darwin.kill(pid, signal)
        }
    }

    private func processGroupExists(_ pid: pid_t) -> Bool {
        if Darwin.kill(-pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
