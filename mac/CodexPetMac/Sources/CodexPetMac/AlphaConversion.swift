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
        case .invalidProgressProtocol:
            return "The converter returned invalid progress data. Your current animation was not changed."
        case .missingArtifact:
            return "Conversion finished without a verified movie and report."
        }
    }
}

struct AlphaConversionResult {
    let outputURL: URL
    let reportURL: URL
    let reportData: Data
}

final class AlphaToolchainDiscovery {
    static let configuredPythonDefaultsKey = "CodexPetAlphaPythonPath"

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
        guard let ffmpeg = firstExecutable(toolCandidates(environmentKey: "CODEX_PET_FFMPEG", name: "ffmpeg")),
              let ffprobe = firstExecutable(toolCandidates(environmentKey: "CODEX_PET_FFPROBE", name: "ffprobe")) else {
            return .unavailable("ffmpeg and ffprobe are required. Install them with Homebrew, then check again.")
        }
        guard let avconvert = firstExecutable(avconvertCandidates()) else {
            return .unavailable("Apple avconvert is unavailable on this Mac.")
        }
        guard let python = pythonCandidates().first(where: pythonSupportsImageDependencies) else {
            return .unavailable("Python with NumPy and Pillow is required for background removal.")
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
        if let configured = environment["CODEX_PET_ALPHA_CONVERTER"] {
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
        if let configured = environment["CODEX_PET_ALPHA_PYTHON"] {
            candidates.append(URL(fileURLWithPath: configured))
        }
        if let configured = userDefaults.string(forKey: Self.configuredPythonDefaultsKey) {
            candidates.append(URL(fileURLWithPath: configured))
        }
        let home = fileManager.homeDirectoryForCurrentUser
        candidates.append(
            home
                .appendingPathComponent("Library/Application Support/CodexPet/alpha-runtime/bin/python3")
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

    private func toolCandidates(environmentKey: String, name: String) -> [URL] {
        var candidates: [URL] = []
        if let configured = environment[environmentKey] {
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
        if let configured = environment["CODEX_PET_AVCONVERT"] {
            candidates.append(URL(fileURLWithPath: configured))
        }
        candidates.append(URL(fileURLWithPath: "/usr/bin/avconvert"))
        return unique(candidates)
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
    private var storage = Data()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
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

final class AlphaConversionCoordinator {
    private let queue = DispatchQueue(label: "com.coke1120.CodexPetMac.alpha-conversion", qos: .userInitiated)
    private let lock = NSLock()
    private var activeProcess: Process?
    private var activeProcessGroupPID: pid_t?
    private var cancellationRequested = false

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

        DispatchQueue.main.async { phase("Checking source and conversion tools…") }
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

    private func run(
        process: Process,
        sourceURL: URL,
        outputURL: URL,
        reportURL: URL,
        width: Int,
        height: Int,
        toolchain: AlphaToolchain,
        phase: @escaping (String) -> Void,
        progress: @escaping (AlphaConversionProgress) -> Void
    ) -> Result<AlphaConversionResult, Error> {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdout = LockedDataBuffer()
        let stderr = LockedDataBuffer()
        let progressProtocol = LockedProgressProtocolState()
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
                while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
                    let lineData = lineBuffer[..<newlineIndex]
                    lineBuffer.removeSubrange(...newlineIndex)
                    let line = String(decoding: lineData, as: UTF8.self)
                    do {
                        if let event = try parser.parseLine(line) {
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
            stderr.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }
        process.waitUntilExit()
        readGroup.wait()

        if process.terminationStatus != 0 {
            let safeMessage = sanitizedFailureMessage(from: stderr.data)
            return .failure(AlphaConversionFailure.converterFailed(safeMessage))
        }
        if progressProtocol.hasFailed {
            return .failure(AlphaConversionFailure.invalidProgressProtocol)
        }
        guard FileManager.default.isReadableFile(atPath: outputURL.path),
              FileManager.default.isReadableFile(atPath: reportURL.path),
              let reportData = try? Data(contentsOf: reportURL) else {
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

    private func sanitizedFailureMessage(from data: Data) -> String {
        let raw = String(data: data.suffix(8_192), encoding: .utf8) ?? ""
        let lastLine = raw
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        guard let lastLine else {
            return "The background could not be removed safely. Your current animation was not changed."
        }
        let basenameOnly = lastLine
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
}
