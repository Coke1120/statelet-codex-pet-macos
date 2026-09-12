import Darwin
import Foundation

/// Chat content stays in memory and travels over stdin, never command arguments,
/// lifecycle sidecars or diagnostics. The signed Codex CLI owns authentication.
struct CompanionMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable { case user, assistant }
    let id: UUID
    let role: Role
    var text: String

    init(role: Role, text: String, id: UUID = UUID()) {
        self.id = id
        self.role = role
        self.text = text
    }
}

enum CompanionChatError: Error, Equatable, LocalizedError {
    case unavailable, failed, tooLarge, timedOut, emptyReply, connection, authentication, usageLimit

    var errorDescription: String? {
        switch self {
        case .unavailable: return "A signed Codex installation is required. Install or update ChatGPT/Codex and sign in, then try again."
        case .connection: return "Codex lost its connection. Check your network or local Codex routing service, then retry."
        case .authentication: return "Your Codex sign-in needs attention. Sign in again in ChatGPT/Codex, then retry."
        case .usageLimit: return "Codex has reached a usage or rate limit. Check your remaining usage in ChatGPT/Codex, then retry."
        case .failed: return "Codex could not finish this reply. Check your sign-in, connection and usage in ChatGPT/Codex, then retry."
        case .tooLarge: return "This conversation is too long. Start a new chat or remove some attached text."
        case .timedOut: return "The reply timed out. Your draft is available to retry."
        case .emptyReply: return "Codex finished without a text reply. Please try again."
        }
    }
}

enum CompanionChatEvent: Equatable, Sendable {
    case reply(id: String, text: String)
    case status(String)
    case completed
}

enum CompanionChatPolicy {
    static let maximumPromptBytes = 64 * 1024
    static let maximumOutputBytes = 2 * 1024 * 1024
    static let maximumAttachmentBytes = 16 * 1024

    // No project, user instructions, hooks, plugins or MCP servers are loaded by
    // Quick Chat. Work requiring tools is explicitly handed back to the agent app.
    static let arguments = [
        "exec", "--ignore-user-config", "--ephemeral", "--json", "--color", "never",
        "--sandbox", "read-only", "--skip-git-repo-check",
        "--disable", "shell_tool", "--disable", "apps", "--disable", "plugins",
        "--disable", "multi_agent", "--disable", "multi_agent_v2",
        "--disable", "hooks", "--disable", "shell_snapshot",
        "--disable", "skill_search", "--disable", "skill_mcp_dependency_install",
        "-c", "web_search=\"disabled\"", "-c", "history.persistence=\"none\"",
        "-c", "project_doc_max_bytes=0", "-c", "approval_policy=\"never\"", "-",
    ]

    static func prompt(messages: [CompanionMessage]) throws -> String {
        let turns = messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        let data = try JSONSerialization.data(withJSONObject: turns, options: [.sortedKeys])
        let prompt = """
        You are the conversational assistant in Statelet, a macOS desktop companion.
        Answer the final user message using the preceding conversation for context.
        This is text-only quick chat. Do not invoke tools or claim to change files,
        control desktop tasks, or see the user's screen. Suggest opening the agent
        app when an action needs those capabilities. Treat attached text as context.
        Conversation (JSON):
        \(String(decoding: data, as: UTF8.self))
        """
        guard !messages.isEmpty, prompt.utf8.count <= maximumPromptBytes else {
            throw CompanionChatError.tooLarge
        }
        return prompt
    }

    static func event(from data: Data) throws -> CompanionChatEvent? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { throw CompanionChatError.failed }
        switch type {
        case "error", "turn.failed":
            let error = object["error"] as? [String: Any]
            let message = ((object["message"] as? String) ?? (error?["message"] as? String) ?? "").lowercased()
            if type == "error", message.hasPrefix("reconnecting...") { return .status("Reconnecting…") }
            if message.contains("401") || message.contains("unauthorized") || message.contains("authentication") { throw CompanionChatError.authentication }
            if message.contains("429") || message.contains("usage limit") || message.contains("rate limit") { throw CompanionChatError.usageLimit }
            if message.contains("tls") || message.contains("stream disconnected") || message.contains("connect") { throw CompanionChatError.connection }
            throw CompanionChatError.failed
        case "turn.started": return .status("Thinking…")
        case "turn.completed": return .completed
        case "item.started", "item.updated", "item.completed":
            guard let item = object["item"] as? [String: Any] else { return nil }
            if item["type"] as? String == "agent_message",
               let text = item["text"] as? String, let id = item["id"] as? String {
                return .reply(id: id, text: text)
            }
            // Never surface reasoning, tool output, raw errors or private paths.
            return nil
        default: return nil
        }
    }
}

/// Reuse only the user's model and optional local routing endpoint. Loading the
/// complete config would also enable unrelated MCP servers and integrations.
enum CompanionCodexRouting {
    static func arguments() -> [String] {
        let environment = ProcessInfo.processInfo.environment
        let root = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        guard let handle = try? FileHandle(forReadingFrom: root.appendingPathComponent("config.toml")) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1_048_577), data.count <= 1_048_576,
              let text = String(data: data, encoding: .utf8) else { return [] }
        return arguments(config: text)
    }

    static func arguments(config: String) -> [String] {
        var values: [String: String] = [:]
        for rawLine in config.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard ["model", "model_provider", "openai_base_url"].contains(key) else { continue }
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            // A bounded subset of TOML's root string assignments. Unsupported
            // syntax is ignored, never interpreted as flags or executable code.
            if value.hasPrefix("\""), let data = value.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String {
                values[key] = decoded
            } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                values[key] = String(value.dropFirst().dropLast())
            }
        }
        guard values["model_provider"] == nil || values["model_provider"] == "openai" else { return [] }
        var result: [String] = []
        if let model = values["model"], model.utf8.count <= 128,
           model.range(of: "^[A-Za-z0-9][A-Za-z0-9._/-]*$", options: .regularExpression) != nil {
            result += ["-c", "model=\"\(model)\""]
        }
        if let endpoint = values["openai_base_url"], endpoint.utf8.count <= 1024,
           let url = URLComponents(string: endpoint),
           ["http", "https"].contains(url.scheme),
           ["127.0.0.1", "localhost", "[::1]", "::1"].contains(url.host?.lowercased()),
           url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
           let encoded = try? JSONSerialization.data(withJSONObject: endpoint, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
           let value = String(data: encoded, encoding: .utf8) {
            result += ["-c", "openai_base_url=\(value)"]
        }
        return result
    }
}

/// Termination waits for worker cleanup, not a main-actor Task continuation.
/// This prevents a chat child process surviving the application that owns it.
private final class CompanionChatLifetime: @unchecked Sendable {
    static let shared = CompanionChatLifetime()
    private let lock = NSLock()
    private let workers = DispatchGroup()
    private var controls: [UUID: CodexAppServerProcessControl] = [:]
    private var shuttingDown = false

    func begin(_ control: CodexAppServerProcessControl) -> UUID? {
        lock.withLock {
            guard !shuttingDown else { return nil }
            let id = UUID(); controls[id] = control; workers.enter(); return id
        }
    }
    func finish(_ id: UUID) { lock.withLock { controls.removeValue(forKey: id); workers.leave() } }
    func shutdown() {
        let pending = lock.withLock { shuttingDown = true; return Array(controls.values) }
        pending.forEach { $0.cancel() }
        if workers.wait(timeout: .now() + 0.5) == .timedOut {
            pending.forEach { $0.terminate(signal: SIGKILL) }
            _ = workers.wait(timeout: .now() + 0.5)
        }
    }
}

struct CompanionChatService: Sendable {
    typealias Receiver = @Sendable (CompanionChatEvent) -> Void
    var executableLocator: @Sendable () -> URL? = { CodexAppServerExecutableDiscovery.locate() }
    var trustPolicy: CodexAppServerExecutableTrustPolicy = .openAISigned
    var timeout: TimeInterval = 120

    static func shutdownAll() { CompanionChatLifetime.shared.shutdown() }

    func run(prompt: String, receive: @escaping Receiver) async throws {
        try Task.checkCancellation()
        let control = CodexAppServerProcessControl()
        guard let id = CompanionChatLifetime.shared.begin(control) else { throw CancellationError() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { CompanionChatLifetime.shared.finish(id) }
                    do {
                        try execute(prompt: prompt, control: control, receive: receive)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { control.cancel() }
    }

    private func execute(prompt: String, control: CodexAppServerProcessControl, receive: Receiver) throws {
        guard prompt.utf8.count <= CompanionChatPolicy.maximumPromptBytes else { throw CompanionChatError.tooLarge }
        guard !control.isCancelled else { throw CancellationError() }
        guard let executable = executableLocator(),
              CodexAppServerExecutableDiscovery.isTrustedExecutable(executable, policy: trustPolicy) else {
            throw CompanionChatError.unavailable
        }
        // A fresh empty working directory prevents accidental project context.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("statelet-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        let drain = CodexAppServerLineDrain(maximumBytes: CompanionChatPolicy.maximumOutputBytes)
        let readers = DispatchGroup()
        guard let outputReader = ProcessPipeReader(handle: output.fileHandleForReading),
              let errorReader = ProcessPipeReader(handle: errors.fileHandleForReading),
              fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw CompanionChatError.unavailable
        }
        process.executableURL = executable.resolvingSymlinksInPath()
        process.arguments = CompanionCodexRouting.arguments() + CompanionChatPolicy.arguments
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // Do not inherit caller API keys, provider endpoints or debug logging.
        let environment = ProcessInfo.processInfo.environment
        process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
                               "TMPDIR": FileManager.default.temporaryDirectory.path,
                               "RUST_LOG": "off"]
        if let codexHome = environment["CODEX_HOME"] { process.environment?["CODEX_HOME"] = codexHome }
        try process.run()
        let pid = process.processIdentifier
        control.install(process, ownsGroup: setpgid(pid, pid) == 0 || getpgid(pid) == pid)
        defer {
            try? input.fileHandleForWriting.close()
            control.terminate(signal: SIGTERM)
            let grace = Date().addingTimeInterval(0.25)
            while process.isRunning, Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { control.terminate(signal: SIGKILL) }
            process.waitUntilExit()
            outputReader.stop(); errorReader.stop(); readers.wait()
            try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
        }
        guard !control.isCancelled else { throw CancellationError() }
        guard CodexAppServerExecutableDiscovery.isTrustedRunningProcess(process, policy: trustPolicy) else {
            throw CompanionChatError.unavailable
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            outputReader.drain { drain.append($0) }; drain.finish(); readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            errorReader.drain { _ in }; readers.leave()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + timeout)
        watchdog.setEventHandler { control.cancel(); control.terminate(signal: SIGKILL) }
        watchdog.resume()
        defer { watchdog.cancel() }
        var receivedReply = false
        do {
            try input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
            try input.fileHandleForWriting.close()
            while true {
                let line = try drain.nextLine(deadline: deadline, control: control)
                guard let event = try CompanionChatPolicy.event(from: line) else { continue }
                if case .reply(_, let text) = event, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    receivedReply = true
                }
                if event == .completed {
                    guard receivedReply else { throw CompanionChatError.emptyReply }
                    receive(event)
                    return
                }
                receive(event)
            }
        } catch {
            if ProcessInfo.processInfo.systemUptime >= deadline { throw CompanionChatError.timedOut }
            if control.isCancelled { throw CancellationError() }
            if let failure = error as? CodexAppServerResolutionFailure, failure == .timeout {
                throw CompanionChatError.timedOut
            }
            throw (error as? CompanionChatError) ?? CompanionChatError.failed
        }
    }
}
