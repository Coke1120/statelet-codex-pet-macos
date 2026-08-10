import Foundation

/// Caller-owned runtime facts for the copyable diagnostics report.
///
/// Supply status categories and counts only. Never pass prompts, session IDs,
/// transcripts, tool output, account information, or raw error/log text.
struct PetDiagnosticsInput {
    var appVersion: String
    var appBuild: String
    var lifecycleState: String
    var publisherHealth: String
    var publisherSource: String
    var emittedAgeSeconds: Double?
    var observedAgeSeconds: Double?
    var activeSessionCount: Int?
    var playbackMode: String
    var selectedClipName: String?
    var previewStatus: String
    var toolchainStatus: String
    var lastFailureCategory: String?

    init(
        appVersion: String,
        appBuild: String,
        lifecycleState: String,
        publisherHealth: String,
        publisherSource: String,
        emittedAgeSeconds: Double? = nil,
        observedAgeSeconds: Double? = nil,
        activeSessionCount: Int? = nil,
        playbackMode: String,
        selectedClipName: String? = nil,
        previewStatus: String,
        toolchainStatus: String,
        lastFailureCategory: String? = nil
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.lifecycleState = lifecycleState
        self.publisherHealth = publisherHealth
        self.publisherSource = publisherSource
        self.emittedAgeSeconds = emittedAgeSeconds
        self.observedAgeSeconds = observedAgeSeconds
        self.activeSessionCount = activeSessionCount
        self.playbackMode = playbackMode
        self.selectedClipName = selectedClipName
        self.previewStatus = previewStatus
        self.toolchainStatus = toolchainStatus
        self.lastFailureCategory = lastFailureCategory
    }
}

/// Builds a sanitized, copyable local health report without reading log contents.
struct PetDiagnostics {
    private static let aggregatorLabel = "com.coke1120.codex-pet.state-aggregator"

    private let fileManager: FileManager
    private let homeURL: URL
    private let launchAtLoginManager: LaunchAtLoginManager

    init(fileManager: FileManager = .default, homeURL: URL? = nil) {
        self.fileManager = fileManager
        let resolvedHome = (homeURL ?? fileManager.homeDirectoryForCurrentUser).standardizedFileURL
        self.homeURL = resolvedHome
        self.launchAtLoginManager = LaunchAtLoginManager(fileManager: fileManager, homeURL: resolvedHome)
    }

    /// Creates a report safe to copy into an issue or support conversation.
    /// Absolute home paths and free-form caller text are never emitted.
    func build(input: PetDiagnosticsInput) -> String {
        let startup = launchAtLoginManager.status()
        let support = homeURL.appendingPathComponent("Library/Application Support/CodexPet", isDirectory: true)
        let app = inspectInstalledApp()
        let aggregator = inspectManagedPlist(
            at: homeURL.appendingPathComponent("Library/LaunchAgents/\(Self.aggregatorLabel).plist"),
            label: Self.aggregatorLabel
        )

        var lines = [
            "Statelet Diagnostics",
            "privacy: sanitized-status-only",
            "app.version: \(safeLabel(input.appVersion))",
            "app.build: \(safeLabel(input.appBuild))",
            "app.bundle: \(app)",
            "lifecycle.state: \(safeLabel(input.lifecycleState))",
            "publisher.health: \(safeLabel(input.publisherHealth))",
            "publisher.source: \(safePublisherSource(input.publisherSource))",
            "publisher.emitted_age: \(age(input.emittedAgeSeconds))",
            "publisher.source_age: \(age(input.observedAgeSeconds))",
            "publisher.active_sessions: \(count(input.activeSessionCount))",
            "playback.mode: \(safeLabel(input.playbackMode))",
            "playback.media: \(safeMediaKind(input.selectedClipName))",
            "preview.status: \(safeLabel(input.previewStatus))",
            "toolchain.status: \(safeLabel(input.toolchainStatus))",
            "failure.category: \(safeOptionalLabel(input.lastFailureCategory))",
            "startup.player_plist: \(stateLabel(startup.state))",
            "startup.player_job: \(startupJobLabel(startup))",
            "startup.aggregator_plist: \(aggregator)",
            "storage.media_map: \(fileStatus(support.appendingPathComponent("media/media-map.json")))",
            "storage.state: \(fileStatus(support.appendingPathComponent("runtime/current_state.json")))",
            "storage.media_directory: \(directoryStatus(support.appendingPathComponent("media", isDirectory: true)))",
            "storage.logs_directory: \(directoryStatus(support.appendingPathComponent("logs", isDirectory: true)))",
        ]
        lines.append("note: report excludes paths, prompt/session content, logs, tool output, and account data")
        return lines.joined(separator: "\n")
    }

    private func stateLabel(_ state: LaunchAtLoginManager.State) -> String {
        switch state {
        case .missing: return "missing"
        case .managedEnabled: return "managed-enabled"
        case .managedDisabled: return "managed-disabled"
        case .staleManaged: return "managed-stale"
        case .malformed: return "malformed-unverified"
        case .unmanaged: return "unmanaged"
        }
    }

    private func startupJobLabel(_ status: LaunchAtLoginManager.Status) -> String {
        guard status.isLoaded else { return "not-loaded" }
        return status.loadedConfigurationIsCurrent ? "loaded-current" : "loaded-stale-until-login"
    }

    private func inspectInstalledApp() -> String {
        let app = homeURL.appendingPathComponent("Applications/Statelet.app", isDirectory: true)
        guard fileManager.fileExists(atPath: app.path) else { return "missing" }
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: infoURL),
            let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let info = object as? [String: Any]
        else { return "malformed" }
        guard info["CodexPetManaged"] as? String == LaunchAtLoginManager.managedMarker else {
            return "unmanaged"
        }
        guard
            info["CFBundleIdentifier"] as? String == LaunchAtLoginManager.bundleIdentifier,
            fileManager.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/CodexPetMac").path)
        else { return "managed-stale" }
        return "managed-valid"
    }

    private func inspectManagedPlist(at url: URL, label: String) -> String {
        guard fileManager.fileExists(atPath: url.path) else { return "missing" }
        guard
            let data = try? Data(contentsOf: url),
            let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let payload = object as? [String: Any]
        else { return "malformed-unverified" }
        guard payload["CodexPetMacManaged"] as? String == LaunchAtLoginManager.managedMarker else {
            return "unmanaged"
        }
        return payload["Label"] as? String == label ? "managed" : "managed-stale"
    }

    private func fileStatus(_ url: URL) -> String {
        guard fileManager.fileExists(atPath: url.path) else { return "missing" }
        return fileManager.isReadableFile(atPath: url.path) ? "readable" : "unreadable"
    }

    private func directoryStatus(_ url: URL) -> String {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return "missing" }
        guard isDirectory.boolValue else { return "not-directory" }
        return fileManager.isReadableFile(atPath: url.path) ? "readable" : "unreadable"
    }

    private func age(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "unavailable" }
        return String(format: "%.1fs", min(value, 86_400 * 365))
    }

    private func count(_ value: Int?) -> String {
        guard let value, value >= 0 else { return "unavailable" }
        return String(min(value, 10_000))
    }

    private func safeMediaKind(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "none" }
        switch URL(fileURLWithPath: value).pathExtension.lowercased() {
        case "mov": return "mov"
        case "mp4": return "mp4"
        case "m4v": return "m4v"
        default: return "other"
        }
    }

    private func safePublisherSource(_ value: String) -> String {
        value == "aggregate" ? "aggregate" : "unavailable"
    }

    private func safeOptionalLabel(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "none" }
        return safeLabel(value)
    }

    private func safeLabel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unavailable" }
        if trimmed.contains("/") || trimmed.contains("\\") || trimmed.contains("@") || trimmed.contains("~") {
            return "redacted"
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._()-"))
        let filteredScalars = trimmed.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let filtered = String(filteredScalars.prefix(120))
        return filtered.isEmpty ? "unavailable" : filtered
    }
}
