import CoreFoundation
import Darwin
import Foundation

/// Only a parsed numeric release can leave the probe. Never echo CLI output.
struct CodexCLIVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    static let validatedBaseline = CodexCLIVersion(major: 0, minor: 159, patch: 2)
    var label: String { "\(major).\(minor).\(patch)" }

    static func parse(_ text: String) -> Self? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: "^codex-cli [0-9]{1,4}\\.[0-9]{1,4}\\.[0-9]{1,4}$", options: .regularExpression) != nil else { return nil }
        let parts = text.dropFirst(10).split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Self(major: parts[0], minor: parts[1], patch: parts[2])
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct CodexHookSummary: Equatable, Sendable {
    enum Status: String, Sendable {
        case notChecked = "not-checked", ready, missing, incomplete, disabled
        case needsReview = "needs-review", modified
        case featureDisabled = "feature-disabled", runtimeUnavailable = "runtime-unavailable", unverified
    }
    static let requiredEvents: Set<String> = [
        "sessionStart", "sessionEnd", "userPromptSubmit", "preToolUse", "postToolUse",
        "permissionRequest", "preCompact", "postCompact", "subagentStart", "subagentStop", "stop", "interrupt",
    ]
    var status: Status = .notChecked
    var registered = 0
    var trusted = 0
    var disabled = 0
    var needsReview = 0
    var modified = 0

    /// Consume effective CLI metadata, never infer trust from a file or heartbeat.
    /// Restrict scope to the installed Statelet user hook in the active Codex home.
    static func evaluate(_ result: [String: Any], expectedHook: URL, codexHome: URL) -> Self {
        var summary = Self(status: .unverified)
        guard let data = result["data"] as? [[String: Any]], data.count == 1,
              let entry = data.first,
              let errors = entry["errors"] as? [Any], errors.isEmpty,
              let warnings = entry["warnings"] as? [Any], warnings.isEmpty,
              let hooks = entry["hooks"] as? [[String: Any]], hooks.count <= 4096 else { return summary }
        let sources = Set(["hooks.json", "config.toml"].map { codexHome.appendingPathComponent($0).standardizedFileURL.path })
        var events: Set<String> = []
        var interpreters: Set<String> = []
        for hook in hooks {
            guard hook["handlerType"] as? String == "command",
                  hook["source"] as? String == "user",
                  let path = hook["sourcePath"] as? String, path.hasPrefix("/"),
                  sources.contains(URL(fileURLWithPath: path).standardizedFileURL.path),
                  let command = hook["command"] as? String,
                  let parts = commandParts(command), parts[1] == expectedHook.path else { continue }
            guard let event = hook["eventName"] as? String, requiredEvents.contains(event),
                  let enabled = jsonBoolean(hook["enabled"]),
                  let trust = hook["trustStatus"] as? String,
                  ["trusted", "managed", "untrusted", "modified"].contains(trust) else { return Self(status: .unverified) }
            let matcher = hook["matcher"] as? String
            if event == "sessionStart" {
                guard matcher == "startup|resume|clear|compact" else { continue }
            } else {
                guard hook["matcher"] == nil || hook["matcher"] is NSNull || matcher == "" else { continue }
            }
            events.insert(event)
            interpreters.insert(parts[0])
            summary.registered += 1
            if !enabled { summary.disabled += 1 }
            if trust == "trusted" || trust == "managed" { summary.trusted += 1 }
            if trust == "untrusted" { summary.needsReview += 1 }
            if trust == "modified" { summary.modified += 1 }
        }
        if events.isEmpty { summary.status = .missing }
        else if summary.modified > 0 { summary.status = .modified }
        else if summary.needsReview > 0 { summary.status = .needsReview }
        else if summary.disabled > 0 { summary.status = .disabled }
        else if events != requiredEvents { summary.status = .incomplete }
        else {
            let hookReadable = [expectedHook, expectedHook.deletingLastPathComponent().appendingPathComponent("codex_pet_state.py")].allSatisfy {
                var info = stat()
                return lstat($0.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
                    && FileManager.default.isReadableFile(atPath: $0.path)
            }
            let interpretersReady = interpreters.allSatisfy {
                guard $0.hasPrefix("/") else { return false }
                let executable = URL(fileURLWithPath: $0).resolvingSymlinksInPath()
                var interpreterInfo = stat()
                return lstat(executable.path, &interpreterInfo) == 0 && interpreterInfo.st_mode & S_IFMT == S_IFREG
                    && FileManager.default.isExecutableFile(atPath: executable.path)
            }
            summary.status = hookReadable && interpretersReady ? .ready : .runtimeUnavailable
        }
        return summary
    }

    private static func jsonBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// A narrow POSIX shell lexer for the installer's two-argument invocation.
    /// Commands are compared, never executed. Expansions and wrappers fail closed.
    private static func commandParts(_ command: String) -> [String]? {
        guard command.utf8.count <= 16_384 else { return nil }
        let guardSuffix = " >/dev/null 2>&1 || :"
        let invocation = command.hasSuffix(guardSuffix) ? String(command.dropLast(guardSuffix.count)) : command
        var parts: [String] = [], token = "", quote: Character?, escaped = false, started = false
        for character in invocation {
            if escaped {
                // POSIX double quotes preserve backslashes before ordinary
                // characters. Do not turn a nonexistent python\\3 into python3.
                if quote == "\"", !"$`\"\\\n".contains(character) { token.append("\\") }
                if character != "\n" { token.append(character) }
                escaped = false; started = true; continue
            }
            if quote == "'" {
                if character == "'" { quote = nil } else { token.append(character) }
                continue
            }
            if character == "\\" { escaped = true; started = true; continue }
            if let active = quote {
                if character == active { quote = nil }
                else if character == "$" || character == "`" { return nil }
                else { token.append(character) }
                continue
            }
            if character == "'" || character == "\"" { quote = character; started = true }
            else if character == " " || character == "\t" {
                if started { parts.append(token); token = ""; started = false }
            } else if "$`;|&<>\n\r()".contains(character) { return nil }
            else { token.append(character); started = true }
        }
        guard !escaped, quote == nil else { return nil }
        if started { parts.append(token) }
        return parts.count == 2 && !parts[0].isEmpty ? parts : nil
    }
}

struct CodexCompatibilitySnapshot: Equatable, Sendable {
    enum Installation: String, Sendable { case notChecked = "not-checked", signed, missing, unverified }
    enum Capability: String, Sendable { case notChecked = "not-checked", compatible, incompatible, unverified }
    var installation: Installation = .notChecked
    var version: CodexCLIVersion?
    var flags: Capability = .notChecked
    var features: Capability = .notChecked
    var hooks = CodexHookSummary()

    var diagnosticLines: [String] {
        let versionStatus: String
        if let version {
            versionStatus = version < .validatedBaseline ? "older-than-validated" :
                (version == .validatedBaseline ? "validated-baseline" : "newer-than-validated")
        } else { versionStatus = "unverified" }
        var lines = [
            "compatibility.cli.installation: \(installation.rawValue)",
            "compatibility.cli.version: \(version?.label ?? "unavailable")",
            "compatibility.cli.version_status: \(versionStatus)",
            "compatibility.cli.flags: \(flags.rawValue)",
            "compatibility.cli.features: \(features.rawValue)",
            "compatibility.hooks.scope: installed-user-hooks",
            "compatibility.hooks.status: \(hooks.status.rawValue)",
            "compatibility.hooks.registered: \(min(4096, max(0, hooks.registered)))",
            "compatibility.hooks.trusted: \(min(4096, max(0, hooks.trusted)))",
            "compatibility.hooks.disabled: \(min(4096, max(0, hooks.disabled)))",
            "compatibility.hooks.needs_review: \(min(4096, max(0, hooks.needsReview)))",
            "compatibility.hooks.modified: \(min(4096, max(0, hooks.modified)))",
        ]
        let cliAction: String
        switch installation {
        case .notChecked: cliAction = "Choose Refresh to run local offline compatibility checks."
        case .missing: cliAction = "Install or update the official ChatGPT/Codex app, then Refresh."
        case .unverified: cliAction = "Use an official signed ChatGPT/Codex installation; its identity could not be verified."
        case .signed:
            if version == nil || flags == .unverified || features == .unverified {
                cliAction = "The local probe was inconclusive. Update ChatGPT/Codex and Refresh; no safety flags were relaxed."
            } else if version! < .validatedBaseline || flags == .incompatible || features == .incompatible {
                cliAction = "Update ChatGPT/Codex and Refresh. Statelet requires its safety flags and features; 0.159.2 is the validated baseline."
            } else {
                cliAction = "Offline CLI capabilities are compatible. Sign-in and a live reply have not been tested."
            }
        }
        lines.append("compatibility.cli.action: \(cliAction)")
        let hookAction: String
        switch hooks.status {
        case .notChecked: hookAction = "Choose Refresh to inspect effective user-hook readiness."
        case .ready: hookAction = "Installed user hooks are configured, enabled and trusted. Live event delivery and project overrides have not been tested."
        case .missing, .incomplete, .runtimeUnavailable:
            hookAction = "Rerun the Statelet installer to restore its lifecycle hooks/runtime, then review the exact definitions in Codex /hooks and Refresh."
        case .needsReview, .modified:
            hookAction = "Open Codex /hooks and review the new or changed Statelet definitions. Trust only definitions you accept, then Refresh."
        case .disabled:
            hookAction = "Statelet hooks are disabled. Inspect Codex /hooks; enable only the definitions you want, then Refresh."
        case .featureDisabled:
            hookAction = "The Codex hooks feature is off. If you want lifecycle hooks, enable that feature yourself, review /hooks, then Refresh."
        case .unverified:
            hookAction = "Hook readiness could not be verified. Inspect Codex /hooks and update Codex if needed, then Refresh."
        }
        lines.append("compatibility.hooks.action: \(hookAction)")
        return lines
    }
}
