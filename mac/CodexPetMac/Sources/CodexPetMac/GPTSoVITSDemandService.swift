import CodexPetCore
import Darwin
import Foundation

/// Only explicit `synthesize` / `validateProfile` calls acquire a lease. Construction,
/// persisted-profile checks and cached playback must not acquire one. The shared live
/// instance arbitrates all clients; injected transports default to `noop` instead.
/// Custom endpoints and unrecognized jobs are never started or stopped.
///
/// Coordinator contract: GPTSoVITSAPIClient owns acquisition/release around both
/// public operations. Do not separately acquire in the coordinator, or call API
/// validation from restoration, provider selection or cached-WAV preview. Lease
/// release is idempotent and awaited; a final release stops only an owned PID.
/// Installers may bind a marked API-v2 backend to a different-port pinned gateway
/// with StateletVoiceEndpoint. Without that field, only exact bind/port jobs match.
actor GPTSoVITSDemandService {
    static let label = "com.coke1120.statelet.gpt-sovits"
    static let shared = GPTSoVITSDemandService(dependencies: .live)
    static let noop = GPTSoVITSDemandService(dependencies: Dependencies(
        discover: { _, _ in nil }, inspect: { _ in .unloaded },
        start: { _ in throw DialogueVoiceRuntimeError.inferenceUnavailable }, stop: { _, _ in }
    ))

    struct Job: Equatable, Sendable {
        let plistURL: URL
        let endpoint: URL
        let userID: UInt32
        let runAtLoad: Bool

        var target: String { "gui/\(userID)/\(GPTSoVITSDemandService.label)" }
    }

    /// The birth timestamp prevents a recycled PID from becoming an owned process.
    struct ProcessIdentity: Equatable, Sendable {
        let pid: Int32
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    enum JobState: Equatable, Sendable {
        case unloaded
        case stopped
        case running(ProcessIdentity)
    }

    struct StartedProcess: Sendable {
        let process: ProcessIdentity
        let owned: Bool
    }

    struct Dependencies: Sendable {
        var discover: @Sendable (URL, URL) async throws -> Job?
        var inspect: @Sendable (Job) async throws -> JobState
        // Start must finish its bounded launchctl transaction even when cancelled,
        // returning the spawned identity so acquire can await its cleanup.
        var start: @Sendable (Job) async throws -> StartedProcess
        var stop: @Sendable (Job, ProcessIdentity) async -> Void
        var now: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var sleep: @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000))
        }
    }

    struct Lease: Sendable {
        fileprivate let id: UUID?
    }

    private struct Session {
        let job: Job
        let process: ProcessIdentity
        let owned: Bool
        var leases: Set<UUID>
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let dependencies: Dependencies
    private let warmupTimeout: TimeInterval
    private var session: Session?
    private var transitioning = false
    private var waiters: [Waiter] = []

    init(dependencies: Dependencies, warmupTimeout: TimeInterval = 240) {
        self.dependencies = dependencies
        self.warmupTimeout = warmupTimeout
    }

    /// `health` must use the profile's pinned HTTPS transport and honor the supplied
    /// per-attempt timeout. It must not activate weights or submit synthesis.
    func acquire(
        baseURL: URL,
        applicationSupportRoot: URL,
        health: @escaping @Sendable (TimeInterval) async throws -> Void
    ) async throws -> Lease {
        guard await enterTransition(cancellable: true) else { throw CancellationError() }
        defer { leaveTransition() }
        try Task.checkCancellation()
        guard let job = try await dependencies.discover(baseURL, applicationSupportRoot) else {
            return Lease(id: nil)
        }
        try Task.checkCancellation()
        let id = UUID()
        if var current = session {
            guard current.job == job,
                  try await dependencies.inspect(job) == .running(current.process) else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
            try Task.checkCancellation()
            current.leases.insert(id)
            session = current
            return Lease(id: id)
        }

        let state = try await dependencies.inspect(job)
        try Task.checkCancellation()
        let process: ProcessIdentity
        let owned: Bool
        if case let .running(existing) = state {
            process = existing
            owned = false
        } else {
            let started = try await dependencies.start(job)
            process = started.process
            owned = started.owned
        }
        do {
            try Task.checkCancellation()
            try await waitForHealth(health)
            try Task.checkCancellation()
            guard try await dependencies.inspect(job) == .running(process) else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
            try Task.checkCancellation()
            session = Session(job: job, process: process, owned: owned, leases: [id])
            return Lease(id: id)
        } catch {
            if owned { await dependencies.stop(job, process) }
            throw error
        }
    }

    /// Always await release, including from cancelled tasks. It deliberately ignores
    /// caller cancellation while waiting for the final owned-process cleanup.
    func release(_ lease: Lease) async {
        guard let id = lease.id else { return }
        _ = await enterTransition(cancellable: false)
        defer { leaveTransition() }
        guard var current = session, current.leases.remove(id) != nil else { return }
        if current.leases.isEmpty {
            if current.owned { await dependencies.stop(current.job, current.process) }
            session = nil
        } else {
            session = current
        }
    }

    private func waitForHealth(
        _ health: @Sendable (TimeInterval) async throws -> Void
    ) async throws {
        let deadline = dependencies.now() + warmupTimeout
        while dependencies.now() < deadline {
            try Task.checkCancellation()
            do {
                try await health(min(5, deadline - dependencies.now()))
                try Task.checkCancellation()
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as DialogueVoiceRuntimeError where error != .inferenceUnavailable {
                throw error
            } catch {
                try Task.checkCancellation()
                let remaining = deadline - dependencies.now()
                guard remaining > 0 else { break }
                try await dependencies.sleep(min(1, remaining))
            }
        }
        throw DialogueVoiceRuntimeError.inferenceUnavailable
    }

    // Actors are reentrant across launchctl/HTTPS awaits. This small FIFO protects
    // transitions without holding a thread or delaying cancellation of queued callers.
    private func enterTransition(cancellable: Bool) async -> Bool {
        if cancellable && Task.isCancelled { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if transitioning {
                    waiters.append(Waiter(id: id, continuation: continuation))
                } else {
                    transitioning = true
                    continuation.resume(returning: true)
                }
            }
        } onCancel: {
            if cancellable { Task { await self.cancelWaiter(id) } }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private func leaveTransition() {
        if waiters.isEmpty {
            transitioning = false
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }
}

// The live adapter reads bounded, owner-private LaunchAgent metadata only. It never
// reads service configs, logs, transcripts, references or model files, and never
// invokes a shell, installs assets, changes the plist, or uses kickstart -k.
extension GPTSoVITSDemandService.Dependencies {
    static let live = Self(
        discover: { endpoint, _ in try GPTSoVITSLaunchAgent.discover(endpoint: endpoint) },
        inspect: { try await GPTSoVITSLaunchAgent().inspect($0) },
        start: { try await GPTSoVITSLaunchAgent().start($0) },
        stop: { await GPTSoVITSLaunchAgent().stop($0, process: $1) }
    )
}

struct GPTSoVITSLaunchAgent: Sendable {
    typealias Job = GPTSoVITSDemandService.Job
    typealias ProcessIdentity = GPTSoVITSDemandService.ProcessIdentity
    typealias JobState = GPTSoVITSDemandService.JobState

    var discoverJob: @Sendable (URL) throws -> Job? = { try Self.discover(endpoint: $0) }
    var runCommand: @Sendable ([String]) async throws -> CommandResult = { try await Self.command($0) }
    var processIdentity: @Sendable (Int32, UInt32) -> ProcessIdentity? = { Self.identity($0, userID: $1) }
    var signal: @Sendable (Int32, Int32) -> Bool = { Darwin.kill($0, $1) == 0 }
    var wallTime: @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    var now: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var pause: @Sendable () async -> Void = {
        await Task.detached { try? await Task.sleep(nanoseconds: 100_000_000) }.value
    }

    static func discover(endpoint: URL) throws -> Job? {
        _ = try DialogueVoiceEndpointPolicy.validatedLoopbackURL(endpoint)
        guard getuid() == geteuid() else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directories = [home, home.appendingPathComponent("Library"),
                           home.appendingPathComponent("Library/LaunchAgents")]
        for directory in directories {
            var info = stat()
            guard lstat(directory.path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
                  info.st_mode & 0o022 == 0 else { return nil }
        }
        let plistURL = directories[2].appendingPathComponent("\(GPTSoVITSDemandService.label).plist")
        let descriptor = open(plistURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o022 == 0,
              info.st_size > 0, info.st_size <= 65_536 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try handle.read(upToCount: 65_537), data.count == info.st_size,
              let metadata = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return recognizedJob(metadata: metadata, endpoint: endpoint, plistURL: plistURL, userID: geteuid())
    }

    /// The installer attests legacy ownership before adding StateletManaged.
    /// Requests never adopt unmarked jobs or gateway/wrapper executables.
    static func recognizedJob(
        metadata: [String: Any], endpoint: URL, plistURL: URL, userID: UInt32
    ) -> Job? {
        guard (try? DialogueVoiceEndpointPolicy.validatedLoopbackURL(endpoint)) != nil,
              metadata["Label"] as? String == GPTSoVITSDemandService.label,
              metadata["StateletManaged"] as? String == "statelet-v2",
              metadata["KeepAlive"] as? Bool == false,
              let runAtLoad = metadata["RunAtLoad"] as? Bool,
              ["Sockets", "MachServices", "LaunchEvents", "StartInterval", "StartCalendarInterval",
               "WatchPaths", "QueueDirectories", "StartOnMount"].allSatisfy({ metadata[$0] == nil }),
              metadata["OnDemand"] as? Bool != false,
              let arguments = metadata["ProgramArguments"] as? [String],
              (6...16).contains(arguments.count), arguments.allSatisfy({ $0.utf8.count <= 4096 }),
              arguments[0].hasPrefix("/"),
              URL(fileURLWithPath: arguments[0]).lastPathComponent.range(
                  of: "^python(3(\\.[0-9]{1,2})?)?$", options: .regularExpression
              ) != nil,
              metadata["Program"] == nil || metadata["Program"] as? String == arguments[0],
              arguments[1].hasPrefix("/"),
              URL(fileURLWithPath: arguments[1]).lastPathComponent == "api_v2.py",
              metadata["WorkingDirectory"] as? String == URL(fileURLWithPath: arguments[1]).deletingLastPathComponent().path,
              (arguments.count - 2) % 2 == 0 else { return nil }
        var options: [String: String] = [:]
        for index in stride(from: 2, to: arguments.count, by: 2) {
            let option = arguments[index]
            guard ["-a", "-p", "-c"].contains(option), options[option] == nil else { return nil }
            options[option] = arguments[index + 1]
        }
        guard let address = options["-a"], DialogueVoiceEndpointPolicy.isNumericLoopbackHost(address),
              let port = options["-p"].flatMap(Int.init), (1...65_535).contains(port) else { return nil }
        if let binding = metadata["StateletVoiceEndpoint"] {
            // An installed, explicitly marked job can own a different-port backend
            // behind the user's pinned TLS gateway. Never infer this relationship.
            guard let value = binding as? String, let boundEndpoint = URL(string: value),
                  (try? DialogueVoiceEndpointPolicy.validatedLoopbackURL(boundEndpoint)) != nil,
                  boundEndpoint.host == endpoint.host,
                  (boundEndpoint.port ?? 443) == (endpoint.port ?? 443) else { return nil }
        } else {
            let brackets = CharacterSet(charactersIn: "[]")
            guard address.trimmingCharacters(in: brackets) == endpoint.host?.trimmingCharacters(in: brackets),
                  port == (endpoint.port ?? 443) else { return nil }
        }
        return Job(plistURL: plistURL, endpoint: endpoint, userID: userID, runAtLoad: runAtLoad)
    }

    func inspect(_ job: Job) async throws -> JobState {
        let result = try await runCommand(["print", job.target])
        if result.status == 113 { return .unloaded }
        guard result.status == 0,
              result.output.hasPrefix("\(job.target) = {"),
              Self.topLevelValue("path", in: result.output) == job.plistURL.path,
              Self.topLevelValue("type", in: result.output) == "LaunchAgent" else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        guard let pidValue = Self.topLevelValue("pid", in: result.output) else { return .stopped }
        guard let pid = Int32(pidValue), let process = processIdentity(pid, job.userID) else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        return .running(process)
    }

    func start(_ job: Job) async throws -> GPTSoVITSDemandService.StartedProcess {
        // Re-read metadata before any mutation; never bootstrap a login-starting or
        // auto-restarting replacement. A running service is never kickstarted here.
        guard try discoverJob(job.endpoint) == job else {
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
        switch try await inspect(job) {
        case let .running(existing):
            return .init(process: existing, owned: false)
        case .unloaded:
            guard !job.runAtLoad,
                  try await runCommand(["bootstrap", "gui/\(job.userID)", job.plistURL.path]).status == 0 else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
        case .stopped: break
        }
        try Task.checkCancellation()
        let notBefore = wallTime()
        var spawned: ProcessIdentity?
        do {
            let result = try await runCommand(["kickstart", "-p", job.target])
            guard let pid = Int32(result.output.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let process = processIdentity(pid, job.userID) else {
                throw DialogueVoiceRuntimeError.inferenceUnavailable
            }
            let owned = born(process, atOrAfter: notBefore)
            if owned { spawned = process }
            guard result.status == 0 else { throw DialogueVoiceRuntimeError.inferenceUnavailable }
            // kickstart without -k can return an existing PID. Never own a process
            // born before this transaction, including an external start race.
            return .init(process: process, owned: owned)
        } catch {
            // Only the PID returned by this kickstart can be owned. Inferring one
            // from a later `print` could claim an externally started replacement.
            if let spawned { await stop(job, process: spawned) }
            throw DialogueVoiceRuntimeError.inferenceUnavailable
        }
    }

    private func born(_ process: ProcessIdentity, atOrAfter time: TimeInterval) -> Bool {
        Double(process.startSeconds) + Double(process.startMicroseconds) / 1_000_000 >= time
    }

    func stop(_ job: Job, process: ProcessIdentity) async {
        // Signal a verified PID rather than `launchctl kill/bootout`: those target a
        // job and could kill a different process after a crash or external restart.
        guard (try? discoverJob(job.endpoint)) == job,
              (try? await inspect(job)) == .running(process),
              processIdentity(process.pid, job.userID) == process else { return }
        guard signal(process.pid, SIGTERM) else { return }
        let deadline = now() + 5
        while processIdentity(process.pid, job.userID) == process,
              now() < deadline {
            // Cleanup must outlive cancellation of the HTTP caller.
            await pause()
        }
        guard (try? await inspect(job)) == .running(process),
              processIdentity(process.pid, job.userID) == process else { return }
        _ = signal(process.pid, SIGKILL)
        for _ in 0..<10 {
            if processIdentity(process.pid, job.userID) != process { return }
            await pause()
        }
    }

    private static func identity(_ pid: Int32, userID: UInt32) -> ProcessIdentity? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
              info.pbi_uid == userID else { return nil }
        return ProcessIdentity(pid: pid, startSeconds: info.pbi_start_tvsec,
                               startMicroseconds: info.pbi_start_tvusec)
    }

    private static func topLevelValue(_ key: String, in output: String) -> String? {
        let prefix = "\t\(key) = "
        return output.split(separator: "\n").first(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)) }
    }

    struct CommandResult: Sendable {
        let status: Int32
        let output: String
    }

    private static let commandQueue = DispatchQueue(label: "com.coke1120.statelet.gpt-sovits.launchctl", qos: .utility)

    private static func command(_ arguments: [String]) async throws -> CommandResult {
        // launchctl itself is bounded and deliberately not cancelled halfway through
        // kickstart: the caller must collect the PID before cancellation cleanup.
        try await withCheckedThrowingContinuation { continuation in
            commandQueue.async {
                continuation.resume(with: Result { try blockingCommand(arguments) })
            }
        }
    }

    private static func blockingCommand(_ arguments: [String]) throws -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        let capture = BoundedOutput()
        let exited = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        DispatchQueue.global(qos: .utility).async {
            defer { drained.signal() }
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
                capture.append(chunk)
            }
        }
        let timedOut = exited.wait(timeout: .now() + 5) == .timedOut
        if timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        guard drained.wait(timeout: .now() + 1) == .success,
              let output = capture.string else { throw DialogueVoiceRuntimeError.inferenceUnavailable }
        // Preserve a collected kickstart PID even on timeout so the adapter can
        // clean up that exact process without guessing from a later snapshot.
        return CommandResult(status: timedOut ? -1 : process.terminationStatus, output: output)
    }

    private final class BoundedOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var exceeded = false

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            if chunk.count > 65_536 - data.count { exceeded = true }
            if !exceeded { data.append(chunk) }
        }

        var string: String? {
            lock.lock()
            defer { lock.unlock() }
            return exceeded ? nil : String(data: data, encoding: .utf8)
        }
    }
}
