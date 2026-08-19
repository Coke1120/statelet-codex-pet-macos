import Darwin
import Foundation
import OSLog

/// Resolves the user-facing names of Codex threads without retaining thread
/// previews, turns, items, stderr, or raw protocol failures.
actor CodexAppServerTitleResolver {
    typealias ExecutableLocator = @Sendable () -> URL?
    typealias Clock = @Sendable () -> TimeInterval
    typealias Runner = @Sendable (URL, [String], TimeInterval, Int) async throws -> [String: CodexAppServerThreadName]
    typealias HealthReporter = @Sendable (CodexAppServerTitleHealth) -> Void

    private enum CachedName: Sendable {
        case title(String)
        case missing
    }

    private struct CacheEntry: Sendable {
        let value: CachedName
        let expiresAt: TimeInterval
    }

    private let executableLocator: ExecutableLocator
    private let clock: Clock
    private let runner: Runner
    private let timeout: TimeInterval
    private let maximumOutputBytes: Int
    private let cacheTTL: TimeInterval
    private let failureBackoff: TimeInterval
    private let healthReporter: HealthReporter
    private var cache: [String: CacheEntry] = [:]
    private var retryAfter: TimeInterval = 0
    private var lastReportedHealth: CodexAppServerTitleHealth?

    static let maximumActivityCount = 128

    init() {
        self.executableLocator = { CodexAppServerExecutableDiscovery.locate() }
        self.clock = { ProcessInfo.processInfo.systemUptime }
        self.runner = { executable, threadIDs, timeout, maximumOutputBytes in
            try await CodexAppServerProcessRunner.run(
                executable: executable,
                threadIDs: threadIDs,
                timeout: timeout,
                maximumOutputBytes: maximumOutputBytes
            )
        }
        self.timeout = 1.5
        self.maximumOutputBytes = 1_048_576
        self.cacheTTL = 60
        self.failureBackoff = 60
        self.healthReporter = { CodexAppServerTitleDiagnostics.report($0) }
    }

    init(
        executableLocator: @escaping ExecutableLocator,
        clock: @escaping Clock,
        runner: @escaping Runner,
        timeout: TimeInterval = 1.5,
        maximumOutputBytes: Int = 1_048_576,
        cacheTTL: TimeInterval = 60,
        failureBackoff: TimeInterval = 60,
        healthReporter: @escaping HealthReporter = { _ in }
    ) {
        self.executableLocator = executableLocator
        self.clock = clock
        self.runner = runner
        self.timeout = max(0.05, timeout)
        self.maximumOutputBytes = max(1, maximumOutputBytes)
        self.cacheTTL = max(0, cacheTTL)
        self.failureBackoff = max(0, failureBackoff)
        self.healthReporter = healthReporter
    }

    /// Maps private activity IDs to sanitized thread titles. All failures are
    /// deliberately soft: a stale cached title is returned when available,
    /// otherwise that activity is omitted.
    func resolve(activityThreads: [String: String]) async -> [String: String] {
        guard !activityThreads.isEmpty,
              activityThreads.count <= Self.maximumActivityCount else {
            cache.removeAll(keepingCapacity: false)
            return [:]
        }
        let validPairs = activityThreads.filter { Self.isValidThreadID($0.value) }
        guard !validPairs.isEmpty else {
            cache.removeAll(keepingCapacity: false)
            return [:]
        }

        let now = clock()
        let currentThreadIDs = Set(validPairs.values)
        cache = cache.filter { currentThreadIDs.contains($0.key) }
        let uniqueThreadIDs = Array(currentThreadIDs).sorted()
        var names: [String: CachedName] = [:]
        var missing: [String] = []
        for threadID in uniqueThreadIDs {
            if let entry = cache[threadID], entry.expiresAt > now {
                names[threadID] = entry.value
            } else {
                missing.append(threadID)
            }
        }

        if !missing.isEmpty, now >= retryAfter {
            if let executable = executableLocator() {
                do {
                    let resolved = try await runner(executable, missing, timeout, maximumOutputBytes)
                    guard Set(resolved.keys) == Set(missing) else {
                        throw CodexAppServerResolutionFailure.protocolViolation
                    }
                    for threadID in missing {
                        let value: CachedName
                        switch resolved[threadID] {
                        case let .title(rawTitle):
                            value = Self.sanitize(rawTitle).map(CachedName.title) ?? .missing
                        case .missing:
                            value = .missing
                        case nil:
                            throw CodexAppServerResolutionFailure.protocolViolation
                        }
                        cache[threadID] = CacheEntry(value: value, expiresAt: now + cacheTTL)
                        names[threadID] = value
                    }
                    retryAfter = 0
                    reportHealth(.healthy)
                } catch CodexAppServerResolutionFailure.cancelled {
                    for threadID in missing {
                        if let stale = cache[threadID]?.value { names[threadID] = stale }
                    }
                } catch is CancellationError {
                    for threadID in missing {
                        if let stale = cache[threadID]?.value { names[threadID] = stale }
                    }
                } catch let failure as CodexAppServerResolutionFailure {
                    retryAfter = now + failureBackoff
                    if let health = CodexAppServerTitleHealth(failure: failure) {
                        reportHealth(health)
                    }
                    for threadID in missing {
                        if let stale = cache[threadID]?.value { names[threadID] = stale }
                    }
                } catch {
                    retryAfter = now + failureBackoff
                    reportHealth(.protocolViolation)
                    for threadID in missing {
                        if let stale = cache[threadID]?.value { names[threadID] = stale }
                    }
                }
            } else {
                retryAfter = now + failureBackoff
                reportHealth(.unavailable)
                for threadID in missing {
                    if let stale = cache[threadID]?.value { names[threadID] = stale }
                }
            }
        } else {
            for threadID in missing {
                if let stale = cache[threadID]?.value { names[threadID] = stale }
            }
        }

        return validPairs.reduce(into: [:]) { result, pair in
            if case let .title(title)? = names[pair.value] { result[pair.key] = title }
        }
    }

    private func reportHealth(_ health: CodexAppServerTitleHealth) {
        guard health != lastReportedHealth else { return }
        lastReportedHealth = health
        healthReporter(health)
    }

    static func sanitize(_ value: String) -> String? {
        let normalized = value.precomposedStringWithCanonicalMapping
        var filtered = String.UnicodeScalarView()
        for scalar in normalized.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control:
                if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    filtered.append(" ")
                }
            case .format:
                continue
            default:
                filtered.append(scalar)
            }
        }
        let title = String(filtered)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .precomposedStringWithCanonicalMapping
        guard !title.isEmpty,
              title.unicodeScalars.count <= 120,
              title.lengthOfBytes(using: .utf8) <= 256 else { return nil }
        return title
    }

    private static func isValidThreadID(_ value: String) -> Bool {
        guard !value.isEmpty, value.unicodeScalars.count <= 512 else { return false }
        return !value.unicodeScalars.contains {
            $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
        }
    }
}

enum CodexAppServerThreadName: Equatable, Sendable {
    case title(String)
    case missing
}

enum CodexAppServerResolutionFailure: Error {
    case unavailable
    case timeout
    case protocolViolation
    case cancelled
}

enum CodexAppServerTitleHealth: String, Equatable, Sendable {
    case healthy
    case unavailable
    case timeout
    case protocolViolation = "protocol_violation"

    init?(failure: CodexAppServerResolutionFailure) {
        switch failure {
        case .unavailable:
            self = .unavailable
        case .timeout:
            self = .timeout
        case .protocolViolation:
            self = .protocolViolation
        case .cancelled:
            return nil
        }
    }
}

private enum CodexAppServerTitleDiagnostics {
    private static let logger = Logger(
        subsystem: StateletIdentity.bundleIdentifier,
        category: "session-titles"
    )

    static func report(_ health: CodexAppServerTitleHealth) {
        logger.notice("Codex task title lookup status=\(health.rawValue, privacy: .public)")
    }
}

enum CodexAppServerExecutableDiscovery {
    static func locate(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        let candidates = [
            homeDirectory.appendingPathComponent(".local/bin/codex"),
            homeDirectory.appendingPathComponent(".codex/packages/standalone/current/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ]
        return candidates.first { isTrustedExecutable($0, fileManager: fileManager) }
    }

    static func isTrustedExecutable(_ candidate: URL, fileManager: FileManager = .default) -> Bool {
        let resolved = candidate.resolvingSymlinksInPath()
        var status = stat()
        guard lstat(resolved.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == 0 || status.st_uid == getuid(),
              (status.st_mode & 0o022) == 0,
              fileManager.isExecutableFile(atPath: resolved.path) else { return false }
        return true
    }
}

private final class CodexAppServerProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var ownsGroup = false
    private var cancelled = false

    func install(_ process: Process, ownsGroup: Bool) {
        lock.lock()
        self.process = process
        self.ownsGroup = ownsGroup
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { terminate(signal: SIGTERM) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        terminate(signal: SIGTERM)
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func terminate(signal: Int32) {
        lock.lock()
        let process = self.process
        let ownsGroup = self.ownsGroup
        lock.unlock()
        guard let process else { return }
        if ownsGroup {
            _ = Darwin.kill(-process.processIdentifier, signal)
        } else if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, signal)
        }
    }
}

private final class CodexAppServerLineDrain: @unchecked Sendable {
    private let condition = NSCondition()
    private let maximumBytes: Int
    private var buffer = Data()
    private var totalBytes = 0
    private var ended = false
    private var overflowed = false

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    func append(_ data: Data) {
        condition.lock()
        totalBytes += data.count
        if totalBytes > maximumBytes {
            overflowed = true
        } else {
            buffer.append(data)
        }
        condition.broadcast()
        condition.unlock()
    }

    func finish() {
        condition.lock(); ended = true; condition.broadcast(); condition.unlock()
    }

    func nextLine(deadline: TimeInterval, control: CodexAppServerProcessControl) throws -> Data {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if overflowed { throw CodexAppServerResolutionFailure.protocolViolation }
            if control.isCancelled { throw CodexAppServerResolutionFailure.cancelled }
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard !line.isEmpty else { throw CodexAppServerResolutionFailure.protocolViolation }
                return Data(line)
            }
            if ended { throw CodexAppServerResolutionFailure.unavailable }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { throw CodexAppServerResolutionFailure.timeout }
            _ = condition.wait(until: Date(timeIntervalSinceNow: min(remaining, 0.05)))
        }
    }
}

enum CodexAppServerProcessRunner {
    static func run(
        executable: URL,
        threadIDs: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) async throws -> [String: CodexAppServerThreadName] {
        let control = CodexAppServerProcessControl()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try runBlocking(
                    executable: executable,
                    threadIDs: threadIDs,
                    timeout: timeout,
                    maximumOutputBytes: maximumOutputBytes,
                    control: control
                )
            }.value
        } onCancel: {
            control.cancel()
        }
    }

    private static func runBlocking(
        executable: URL,
        threadIDs: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int,
        control: CodexAppServerProcessControl
    ) throws -> [String: CodexAppServerThreadName] {
        if control.isCancelled { throw CodexAppServerResolutionFailure.cancelled }
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let drain = CodexAppServerLineDrain(maximumBytes: maximumOutputBytes)
        let readers = DispatchGroup()

        process.executableURL = executable.resolvingSymlinksInPath()
        process.arguments = ["app-server"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do { try process.run() } catch { throw CodexAppServerResolutionFailure.unavailable }
        let pid = process.processIdentifier
        let ownsGroup = setpgid(pid, pid) == 0 || getpgid(pid) == pid
        control.install(process, ownsGroup: ownsGroup)

        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            let handle = stdout.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                drain.append(data)
            }
            drain.finish()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            let handle = stderr.fileHandleForReading
            while !handle.availableData.isEmpty {}
            readers.leave()
        }

        defer {
            try? stdin.fileHandleForWriting.close()
            control.terminate(signal: SIGTERM)
            let grace = Date().addingTimeInterval(0.25)
            while process.isRunning, Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { control.terminate(signal: SIGKILL) }
            process.waitUntilExit()
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            _ = readers.wait(timeout: .now() + 0.5)
        }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        try send([
            "id": 1,
            "method": "initialize",
            "params": ["clientInfo": ["name": "statelet", "title": "Statelet", "version": "1"]],
        ], to: stdin.fileHandleForWriting)
        let initialize = try response(id: 1, drain: drain, deadline: deadline, control: control)
        guard initialize["error"] == nil, initialize["result"] is [String: Any] else {
            throw CodexAppServerResolutionFailure.protocolViolation
        }
        try send(["method": "initialized", "params": [:]], to: stdin.fileHandleForWriting)

        var result: [String: CodexAppServerThreadName] = [:]
        for (offset, threadID) in threadIDs.enumerated() {
            let requestID = offset + 2
            try send([
                "id": requestID,
                "method": "thread/read",
                "params": ["threadId": threadID, "includeTurns": false],
            ], to: stdin.fileHandleForWriting)
            let message = try response(id: requestID, drain: drain, deadline: deadline, control: control)
            if isThreadNotLoaded(message, requestedThreadID: threadID) {
                result[threadID] = .missing
                continue
            }
            guard message["error"] == nil,
                  let responseResult = message["result"] as? [String: Any],
                  let thread = responseResult["thread"] as? [String: Any],
                  thread["id"] as? String == threadID else {
                throw CodexAppServerResolutionFailure.protocolViolation
            }
            if let name = thread["name"], !(name is NSNull) {
                guard let string = name as? String else {
                    throw CodexAppServerResolutionFailure.protocolViolation
                }
                result[threadID] = .title(string)
            } else {
                result[threadID] = .missing
            }
        }
        return result
    }

    private static func isThreadNotLoaded(
        _ message: [String: Any],
        requestedThreadID: String
    ) -> Bool {
        guard message["result"] == nil,
              let error = message["error"] as? [String: Any],
              Set(error.keys) == Set(["code", "message"]),
              (error["code"] as? NSNumber)?.compare(NSNumber(value: -32600)) == .orderedSame,
              error["message"] as? String == "thread not loaded: \(requestedThreadID)" else {
            return false
        }
        return true
    }

    private static func send(_ object: [String: Any], to handle: FileHandle) throws {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object) else {
            throw CodexAppServerResolutionFailure.protocolViolation
        }
        data.append(0x0A)
        do { try handle.write(contentsOf: data) } catch {
            throw CodexAppServerResolutionFailure.unavailable
        }
    }

    private static func response(
        id: Int,
        drain: CodexAppServerLineDrain,
        deadline: TimeInterval,
        control: CodexAppServerProcessControl
    ) throws -> [String: Any] {
        while true {
            let line = try drain.nextLine(deadline: deadline, control: control)
            guard let object = try? JSONSerialization.jsonObject(with: line),
                  let message = object as? [String: Any] else {
                throw CodexAppServerResolutionFailure.protocolViolation
            }
            if message["id"] == nil { continue }
            guard let responseID = message["id"] as? NSNumber,
                  CFGetTypeID(responseID) != CFBooleanGetTypeID(),
                  responseID.compare(NSNumber(value: id)) == .orderedSame else {
                throw CodexAppServerResolutionFailure.protocolViolation
            }
            return message
        }
    }
}
