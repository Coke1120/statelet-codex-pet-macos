import Darwin
import Foundation
import OSLog
import Security

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

    private enum AttemptOutcome: Sendable {
        case success([String: CodexAppServerThreadName])
        case failure(CodexAppServerResolutionFailure)
        case cancelled
    }

    private struct AttemptWaiter {
        let isExactRequest: Bool
        let continuation: CheckedContinuation<AttemptOutcome, Never>
    }

    private struct InFlightAttempt {
        let token: UInt64
        let threadIDs: [String]
        let task: Task<Void, Never>
        var waiters: [UInt64: AttemptWaiter]
    }

    /// SessionActivityPresentation exposes at most three active and three
    /// completed rows. Keep app-server work bounded to that visible surface.
    private static let maximumActivityCount = 6

    private let executableLocator: ExecutableLocator
    private let clock: Clock
    private let runner: Runner
    private let timeout: TimeInterval
    private let maximumOutputBytes: Int
    private let cacheTTL: TimeInterval
    private let failureBackoff: TimeInterval
    private let maximumCacheEntries: Int
    private let healthReporter: HealthReporter
    private var cache: [String: CacheEntry] = [:]
    private var retryAfter: TimeInterval = 0
    private var nextAttemptToken: UInt64 = 0
    private var nextWaiterToken: UInt64 = 0
    private var inFlightAttempt: InFlightAttempt?
    private var activeAttemptTasks: [UInt64: Task<Void, Never>] = [:]
    private var isShuttingDown = false
    private var lastReportedHealth: CodexAppServerTitleHealth?

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
        self.maximumCacheEntries = 128
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
        maximumCacheEntries: Int = 128,
        healthReporter: @escaping HealthReporter = { _ in }
    ) {
        self.executableLocator = executableLocator
        self.clock = clock
        self.runner = runner
        self.timeout = max(0.05, timeout)
        self.maximumOutputBytes = max(1, maximumOutputBytes)
        // A zero-duration cache or backoff would let the actor's completion
        // loop immediately relaunch forever when an injected clock is stable.
        self.cacheTTL = max(0.001, cacheTTL)
        self.failureBackoff = max(0.001, failureBackoff)
        self.maximumCacheEntries = max(1, maximumCacheEntries)
        self.healthReporter = healthReporter
    }

    /// Maps private activity IDs to sanitized thread titles. All failures are
    /// deliberately soft and omit any activity without a fresh cached title.
    func resolve(activityThreads: [String: String]) async -> [String: String] {
        guard !isShuttingDown,
              !activityThreads.isEmpty,
              activityThreads.count <= Self.maximumActivityCount else { return [:] }
        let validPairs = activityThreads.filter { Self.isValidThreadID($0.value) }
        guard !validPairs.isEmpty else { return [:] }

        let uniqueThreadIDs = Array(Set(validPairs.values)).sorted()
        var names = cachedNames(for: uniqueThreadIDs, now: clock())
        while names.count < uniqueThreadIDs.count {
            guard !isShuttingDown, !Task.isCancelled else { break }
            let missing = uniqueThreadIDs.filter { names[$0] == nil }
            let now = clock()
            guard now >= retryAfter else { break }

            if let attempt = inFlightAttempt {
                let outcome = await waitForAttempt(
                    token: attempt.token,
                    isExactRequest: attempt.threadIDs == missing
                )
                if case .cancelled = outcome, Task.isCancelled { break }
            } else {
                guard let executable = executableLocator() else {
                    retryAfter = now + failureBackoff
                    reportHealth(.unavailable)
                    break
                }
                nextAttemptToken &+= 1
                let token = nextAttemptToken
                let runner = self.runner
                let timeout = self.timeout
                let maximumOutputBytes = self.maximumOutputBytes
                let task = Task<Void, Never> { [weak self] in
                    let outcome: AttemptOutcome
                    do {
                        outcome = .success(try await runner(executable, missing, timeout, maximumOutputBytes))
                    } catch is CancellationError {
                        outcome = .cancelled
                    } catch CodexAppServerResolutionFailure.cancelled {
                        outcome = .cancelled
                    } catch let failure as CodexAppServerResolutionFailure {
                        outcome = .failure(failure)
                    } catch {
                        outcome = .failure(.unavailable)
                    }
                    await self?.completeAttempt(token: token, outcome: outcome)
                }
                inFlightAttempt = InFlightAttempt(
                    token: token,
                    threadIDs: missing,
                    task: task,
                    waiters: [:]
                )
                activeAttemptTasks[token] = task
                let outcome = await waitForAttempt(token: token, isExactRequest: true)
                if case .cancelled = outcome, Task.isCancelled { break }
            }
            names = cachedNames(for: uniqueThreadIDs, now: clock())
        }

        return validPairs.reduce(into: [:]) { result, pair in
            if case let .title(title)? = names[pair.value] { result[pair.key] = title }
        }
    }

    /// Permanently stops resolution and does not return until every launched
    /// app-server runner has completed its process-reaping cleanup.
    func shutdown() async {
        isShuttingDown = true
        if let attempt = inFlightAttempt {
            inFlightAttempt = nil
            for waiter in attempt.waiters.values {
                waiter.continuation.resume(returning: .cancelled)
            }
        }
        let tasks = Array(activeAttemptTasks.values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    func cachedEntryCountForTesting() -> Int { cache.count }

    func inFlightWaiterCountsForTesting() -> (exact: Int, observers: Int) {
        guard let attempt = inFlightAttempt else { return (0, 0) }
        let exact = attempt.waiters.values.filter(\.isExactRequest).count
        return (exact, attempt.waiters.count - exact)
    }

    private func cachedNames(for threadIDs: [String], now: TimeInterval) -> [String: CachedName] {
        cache = cache.filter { $0.value.expiresAt > now }
        return threadIDs.reduce(into: [:]) { result, threadID in
            if let entry = cache[threadID] { result[threadID] = entry.value }
        }
    }

    private func waitForAttempt(token: UInt64, isExactRequest: Bool) async -> AttemptOutcome {
        nextWaiterToken &+= 1
        let waiterToken = nextWaiterToken
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard var attempt = inFlightAttempt,
                      attempt.token == token else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    if isExactRequest,
                       !attempt.waiters.values.contains(where: \.isExactRequest) {
                        inFlightAttempt = nil
                        attempt.task.cancel()
                        for observer in attempt.waiters.values {
                            observer.continuation.resume(returning: .cancelled)
                        }
                    }
                    return
                }
                attempt.waiters[waiterToken] = AttemptWaiter(
                    isExactRequest: isExactRequest,
                    continuation: continuation
                )
                inFlightAttempt = attempt
            }
        } onCancel: {
            Task { await self.cancelWaiter(token: token, waiterToken: waiterToken) }
        }
    }

    private func cancelWaiter(token: UInt64, waiterToken: UInt64) {
        guard var attempt = inFlightAttempt,
              attempt.token == token,
              let waiter = attempt.waiters.removeValue(forKey: waiterToken) else { return }
        waiter.continuation.resume(returning: .cancelled)
        let hasExactWaiter = attempt.waiters.values.contains(where: \.isExactRequest)
        guard waiter.isExactRequest, !hasExactWaiter else {
            inFlightAttempt = attempt
            return
        }
        inFlightAttempt = nil
        attempt.task.cancel()
        for observer in attempt.waiters.values {
            observer.continuation.resume(returning: .cancelled)
        }
    }

    private func completeAttempt(token: UInt64, outcome: AttemptOutcome) {
        activeAttemptTasks.removeValue(forKey: token)
        guard let attempt = inFlightAttempt, attempt.token == token else { return }
        inFlightAttempt = nil
        apply(outcome, threadIDs: attempt.threadIDs)
        for waiter in attempt.waiters.values {
            waiter.continuation.resume(returning: outcome)
        }
    }

    private func apply(_ outcome: AttemptOutcome, threadIDs: [String]) {
        let completedAt = clock()
        switch outcome {
        case let .success(resolved):
            guard Set(resolved.keys) == Set(threadIDs) else {
                retryAfter = completedAt + failureBackoff
                reportHealth(.protocolViolation)
                return
            }
            var values: [String: CachedName] = [:]
            for threadID in threadIDs {
                switch resolved[threadID] {
                case let .title(rawTitle):
                    values[threadID] = Self.sanitize(rawTitle).map(CachedName.title) ?? .missing
                case .missing:
                    values[threadID] = .missing
                case nil:
                    retryAfter = completedAt + failureBackoff
                    reportHealth(.protocolViolation)
                    return
                }
            }
            for (threadID, value) in values {
                cache[threadID] = CacheEntry(value: value, expiresAt: completedAt + cacheTTL)
            }
            trimCache()
            retryAfter = 0
            reportHealth(.healthy)
        case let .failure(failure):
            retryAfter = completedAt + failureBackoff
            if let health = CodexAppServerTitleHealth(failure: failure) {
                reportHealth(health)
            }
        case .cancelled:
            break
        }
    }

    private func reportHealth(_ health: CodexAppServerTitleHealth) {
        guard health != lastReportedHealth else { return }
        lastReportedHealth = health
        healthReporter(health)
    }

    private func trimCache() {
        let overflow = cache.count - maximumCacheEntries
        guard overflow > 0 else { return }
        let oldestKeys = cache.keys.sorted { lhs, rhs in
            let left = cache[lhs]!.expiresAt
            let right = cache[rhs]!.expiresAt
            return left == right ? lhs < rhs : left < right
        }
        for key in oldestKeys.prefix(overflow) { cache.removeValue(forKey: key) }
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

enum CodexAppServerResolutionFailure: Error, Equatable, Sendable {
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
    static let trustedTeamIdentifier = "2DC432GLL2"

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
        return candidates.first {
            isTrustedExecutable($0, policy: .openAISigned, fileManager: fileManager)
        }
    }

    static func isTrustedExecutable(
        _ candidate: URL,
        policy: CodexAppServerExecutableTrustPolicy = .openAISigned,
        fileManager: FileManager = .default
    ) -> Bool {
        let resolved = candidate.resolvingSymlinksInPath()
        var status = stat()
        guard lstat(resolved.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == 0 || status.st_uid == getuid(),
              (status.st_mode & 0o022) == 0,
              fileManager.isExecutableFile(atPath: resolved.path) else { return false }
        guard policy == .openAISigned else { return true }

        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(resolved as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        return isValidOpenAIStaticCode(code)
    }

    static func isTrustedRunningProcess(
        _ process: Process,
        policy: CodexAppServerExecutableTrustPolicy = .openAISigned
    ) -> Bool {
        guard policy == .openAISigned else { return true }
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: process.processIdentifier),
        ] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code,
              let requirement = openAIRequirement(),
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            return false
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        return hasTrustedTeamIdentifier(staticCode)
    }

    private static func openAIRequirement() -> SecRequirement? {
        var requirement: SecRequirement?
        let requirementText = "anchor apple generic and certificate leaf[subject.OU] = \"\(trustedTeamIdentifier)\""
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess else {
            return nil
        }
        return requirement
    }

    private static func isValidOpenAIStaticCode(_ code: SecStaticCode) -> Bool {
        guard let requirement = openAIRequirement(),
              SecStaticCodeCheckValidity(
                code,
                SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                requirement
              ) == errSecSuccess else { return false }
        return hasTrustedTeamIdentifier(code)
    }

    private static func hasTrustedTeamIdentifier(_ code: SecStaticCode) -> Bool {
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
              let information = signingInformation as? [String: Any],
              information[kSecCodeInfoTeamIdentifier as String] as? String == trustedTeamIdentifier,
              let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate],
              !certificates.isEmpty else { return false }
        return true
    }
}

enum CodexAppServerExecutableTrustPolicy: Sendable {
    case openAISigned
    case testOnlyAllowUnsignedExecutable
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
    typealias PrelaunchHook = @Sendable (URL) throws -> Void
    typealias RunningProcessValidator = @Sendable (Process, CodexAppServerExecutableTrustPolicy) -> Bool

    static func run(
        executable: URL,
        threadIDs: [String],
        timeout: TimeInterval,
        maximumOutputBytes: Int,
        trustPolicy: CodexAppServerExecutableTrustPolicy = .openAISigned,
        prelaunchHook: @escaping PrelaunchHook = { _ in },
        runningProcessValidator: @escaping RunningProcessValidator = {
            CodexAppServerExecutableDiscovery.isTrustedRunningProcess($0, policy: $1)
        }
    ) async throws -> [String: CodexAppServerThreadName] {
        let control = CodexAppServerProcessControl()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try runBlocking(
                    executable: executable,
                    threadIDs: threadIDs,
                    timeout: timeout,
                    maximumOutputBytes: maximumOutputBytes,
                    trustPolicy: trustPolicy,
                    prelaunchHook: prelaunchHook,
                    runningProcessValidator: runningProcessValidator,
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
        trustPolicy: CodexAppServerExecutableTrustPolicy,
        prelaunchHook: PrelaunchHook,
        runningProcessValidator: RunningProcessValidator,
        control: CodexAppServerProcessControl
    ) throws -> [String: CodexAppServerThreadName] {
        if control.isCancelled { throw CodexAppServerResolutionFailure.cancelled }
        let resolvedExecutable = executable.resolvingSymlinksInPath()
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let drain = CodexAppServerLineDrain(maximumBytes: maximumOutputBytes)
        let readers = DispatchGroup()

        process.executableURL = resolvedExecutable
        process.arguments = ["app-server"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw CodexAppServerResolutionFailure.unavailable
        }

        guard !control.isCancelled else { throw CodexAppServerResolutionFailure.cancelled }
        guard CodexAppServerExecutableDiscovery.isTrustedExecutable(
            resolvedExecutable,
            policy: trustPolicy
        ) else { throw CodexAppServerResolutionFailure.unavailable }
        do { try prelaunchHook(resolvedExecutable) } catch {
            throw CodexAppServerResolutionFailure.unavailable
        }
        do { try process.run() } catch { throw CodexAppServerResolutionFailure.unavailable }
        let pid = process.processIdentifier
        let ownsGroup = setpgid(pid, pid) == 0 || getpgid(pid) == pid
        control.install(process, ownsGroup: ownsGroup)

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

        guard runningProcessValidator(process, trustPolicy) else {
            throw CodexAppServerResolutionFailure.unavailable
        }

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
            guard let number = message["id"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite,
                  number.doubleValue == Double(id),
                  number.intValue == id else {
                throw CodexAppServerResolutionFailure.protocolViolation
            }
            return message
        }
    }
}
