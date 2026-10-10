import CoreFoundation
import Darwin
import Foundation

/// Run only local help/feature probes and the read-only hooks catalog. Raw
/// output has a bounded lifetime and never reaches diagnostics, logs or disk.
struct CodexCompatibilityService {
    var candidates: () -> [URL] = { CodexAppServerExecutableDiscovery.candidates() }
    var trustPolicy: CodexAppServerExecutableTrustPolicy = .openAISigned
    var homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    var codexHomeURL: URL? = nil
    var timeout: TimeInterval = 8

    static func shutdownAll() { CodexCompatibilityLifetime.shared.shutdown() }

    func check(control: CodexAppServerProcessControl) -> CodexCompatibilitySnapshot {
        var snapshot = CodexCompatibilitySnapshot(flags: .unverified, features: .unverified,
                                                  hooks: CodexHookSummary(status: .unverified))
        guard !control.isCancelled, let id = CodexCompatibilityLifetime.shared.begin(control) else { return snapshot }
        defer { CodexCompatibilityLifetime.shared.finish(id) }
        let candidates = candidates()
        guard let executable = candidates.first(where: {
            CodexAppServerExecutableDiscovery.isTrustedExecutable($0, policy: trustPolicy)
        }) else {
            snapshot.installation = candidates.contains { FileManager.default.fileExists(atPath: $0.path) } ? .unverified : .missing
            return snapshot
        }
        snapshot.installation = .signed
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("statelet-compat-\(UUID())")
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.1, min(timeout, 15))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let runner = CodexDiagnosticProcess(executable: executable, trustPolicy: trustPolicy,
                directory: directory, deadline: deadline, control: control)
            let isolated = environment(home: directory, codexHome: directory)
            let version = try runner.output(arguments: ["--version"], environment: isolated)
            guard version.status == 0 else { return snapshot }
            snapshot.version = CodexCLIVersion.parse(version.text)
            let help = try runner.output(arguments: CompanionChatPolicy.arguments + ["--help"], environment: isolated)
            snapshot.flags = help.status == 0 && help.text.contains("Usage: codex exec ") ? .compatible : .incompatible
            let features = try runner.output(arguments: ["features", "list"] + CompanionChatPolicy.disabledFeatureArguments,
                                             environment: isolated)
            if features.status == 0, let values = featureValues(features.text) {
                snapshot.features = CompanionChatPolicy.disabledFeatures.allSatisfy { values[$0] == false } ? .compatible : .incompatible
            }
            let codexHome = codexHomeURL ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
                ?? homeURL.appendingPathComponent(".codex")
            let userEnvironment = environment(home: homeURL, codexHome: codexHome)
            let effective = try runner.output(arguments: ["features", "list"], environment: userEnvironment)
            guard effective.status == 0, let enabled = featureValues(effective.text)?["hooks"] else { return snapshot }
            guard enabled else { snapshot.hooks.status = .featureDisabled; return snapshot }
            let metadata = try runner.hooks(environment: userEnvironment)
            snapshot.hooks = CodexHookSummary.evaluate(metadata,
                expectedHook: homeURL.appendingPathComponent("Library/Application Support/Statelet/python/statelet_hook.py"),
                codexHome: codexHome)
        } catch { /* Fixed unverified categories only; never retain the error. */ }
        return snapshot
    }

    private func environment(home: URL, codexHome: URL) -> [String: String] {
        ["HOME": home.path, "CODEX_HOME": codexHome.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
         "TMPDIR": FileManager.default.temporaryDirectory.path, "LANG": "en_US.UTF-8", "RUST_LOG": "off"]
    }
    private func featureValues(_ text: String) -> [String: Bool]? {
        var values: [String: Bool] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 3, let name = fields.first, let value = fields.last,
                  value == "true" || value == "false", values[String(name)] == nil else { return nil }
            values[String(name)] = value == "true"
        }
        return values.isEmpty ? nil : values
    }
}

/// App termination joins cleanup directly, without requiring another main-queue
/// continuation. A stubborn diagnostic child cannot survive its owning app.
private final class CodexCompatibilityLifetime: @unchecked Sendable {
    static let shared = CodexCompatibilityLifetime()
    private let lock = NSLock()
    private let workers = DispatchGroup()
    private var controls: [UUID: CodexAppServerProcessControl] = [:]
    private var shuttingDown = false
    func begin(_ control: CodexAppServerProcessControl) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard !shuttingDown else { return nil }
        let id = UUID(); controls[id] = control; workers.enter(); return id
    }
    func finish(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        controls.removeValue(forKey: id); workers.leave()
    }
    func shutdown() {
        lock.lock(); shuttingDown = true; let pending = Array(controls.values); lock.unlock()
        pending.forEach { $0.cancel() }
        if workers.wait(timeout: .now() + 0.5) == .timedOut {
            pending.forEach { $0.terminate(signal: SIGKILL) }
            _ = workers.wait(timeout: .now() + 0.5)
        }
    }
}

private final class CodexDiagnosticCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    private var storage = Data()
    private(set) var overflow = false
    func append(_ data: Data, stdout: Bool) {
        lock.lock(); defer { lock.unlock() }
        bytes += data.count
        if bytes > 1_048_576 { overflow = true }
        else if stdout { storage.append(data) }
    }
    func value() throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard !overflow, let text = String(data: storage, encoding: .utf8) else {
            throw CodexAppServerResolutionFailure.protocolViolation
        }
        return text
    }
}

private struct CodexDiagnosticProcess {
    let executable: URL
    let trustPolicy: CodexAppServerExecutableTrustPolicy
    let directory: URL
    let deadline: TimeInterval
    let control: CodexAppServerProcessControl

    func output(arguments: [String], environment: [String: String]) throws -> (status: Int32, text: String) {
        let output = try run(arguments: arguments, environment: environment) { process, _, _, _ in
            while process.isRunning {
                try checkDeadline()
                Thread.sleep(forTimeInterval: 0.01)
            }
            return process.terminationStatus
        }
        return (output.result, output.text)
    }

    func hooks(environment: [String: String]) throws -> [String: Any] {
        let arguments = ["--disable", "apps", "--disable", "plugins",
            "-c", "otel.exporter=\"none\"", "-c", "otel.trace_exporter=\"none\"",
            "-c", "analytics.enabled=false", "-c", "feedback.enabled=false", "app-server"]
        return try run(arguments: arguments, environment: environment) { _, input, drain, _ in
            try send(["id": 1, "method": "initialize", "params": [
                "clientInfo": ["name": "statelet_compatibility", "version": "1"],
                "capabilities": ["experimentalApi": true],
            ]], to: input)
            _ = try response(id: 1, drain: drain)
            try send(["method": "initialized", "params": [:]], to: input)
            try send(["id": 2, "method": "hooks/list", "params": ["cwds": [directory.path]]], to: input)
            return try response(id: 2, drain: drain)
        }.result
    }

    private struct Output<Value> {
        let result: Value
        let text: String
    }
    private func run<Value>(arguments: [String], environment: [String: String],
        body: (Process, FileHandle, CodexAppServerLineDrain, CodexDiagnosticCapture) throws -> Value) throws -> Output<Value> {
        try checkDeadline()
        guard CodexAppServerExecutableDiscovery.isTrustedExecutable(executable, policy: trustPolicy) else {
            throw CodexAppServerResolutionFailure.unavailable
        }
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        let readers = DispatchGroup(), capture = CodexDiagnosticCapture()
        let drain = CodexAppServerLineDrain(maximumBytes: 1_048_576)
        guard let outReader = ProcessPipeReader(handle: output.fileHandleForReading),
              let errReader = ProcessPipeReader(handle: errors.fileHandleForReading),
              fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw CodexAppServerResolutionFailure.unavailable
        }
        process.executableURL = executable.resolvingSymlinksInPath()
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        let pid = process.processIdentifier
        control.install(process, ownsGroup: setpgid(pid, pid) == 0 || getpgid(pid) == pid)
        defer {
            try? input.fileHandleForWriting.close()
            control.terminate(signal: SIGTERM)
            let grace = ProcessInfo.processInfo.systemUptime + 0.2
            while process.isRunning, ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.01) }
            control.terminate(signal: SIGKILL)
            process.waitUntilExit()
            // Let normal EOF drain before stopping descendants that retained a pipe.
            if readers.wait(timeout: .now() + 0.1) == .timedOut { outReader.stop(); errReader.stop(); readers.wait() }
            try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
        }
        if process.isRunning, !CodexAppServerExecutableDiscovery.isTrustedRunningProcess(process, policy: trustPolicy) {
            // Help/version can exit while Security inspects their PID. Retain
            // the static signature policy for an already-exited child; a live
            // child must still pass the running-process policy.
            guard !process.isRunning,
                  CodexAppServerExecutableDiscovery.isTrustedExecutable(executable, policy: trustPolicy) else {
                throw CodexAppServerResolutionFailure.unavailable
            }
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            outReader.drain { capture.append($0, stdout: true); drain.append($0) }
            drain.finish(); readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errReader.drain { capture.append($0, stdout: false) }; readers.leave()
        }
        // Help and feature commands never read stdin; close it immediately.
        if !arguments.contains("app-server") { try? input.fileHandleForWriting.close() }
        let value = try body(process, input.fileHandleForWriting, drain, capture)
        if arguments.contains("app-server") { try? input.fileHandleForWriting.close(); control.terminate(signal: SIGTERM) }
        // All successful reads include queued bytes before checking the shared cap.
        if readers.wait(timeout: .now() + 0.1) == .timedOut { outReader.stop(); errReader.stop(); readers.wait() }
        try checkDeadline()
        return Output(result: value, text: try capture.value())
    }
    private func checkDeadline() throws {
        if control.isCancelled { throw CodexAppServerResolutionFailure.cancelled }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw CodexAppServerResolutionFailure.timeout }
    }
    private func send(_ object: [String: Any], to input: FileHandle) throws {
        try checkDeadline()
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }
    private func response(id: Int, drain: CodexAppServerLineDrain) throws -> [String: Any] {
        while true {
            let line = try drain.nextLine(deadline: deadline, control: control)
            guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw CodexAppServerResolutionFailure.protocolViolation
            }
            if message["id"] == nil { continue }
            guard let number = message["id"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == Double(id), message["error"] == nil,
                  let result = message["result"] as? [String: Any] else { throw CodexAppServerResolutionFailure.protocolViolation }
            return result
        }
    }
}

