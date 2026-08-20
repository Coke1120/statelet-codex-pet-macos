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
    var latestHookEvent: String?
    var latestHookAgeSeconds: Double?
    var observedPublicationRevision: Int?
    var acceptedLifecycleState: String?
    var acceptedPublicationRevision: Int?
    var publisherRecovery: Bool?
    var overrideStatus: String
    var fallbackReason: String?
    var publicationRejectionCount: Int?
    var publicationRejectionReasons: [String: Int]
    var playbackMode: String
    var selectedClipName: String?
    var previewStatus: String
    var toolchainStatus: String
    var lastFailureCategory: String?
    var conversionFailureCategory: String?
    var conversionFailureStage: String?
    var preferencesMigrationStatus: PreferencesMigration.Status

    init(
        appVersion: String,
        appBuild: String,
        lifecycleState: String,
        publisherHealth: String,
        publisherSource: String,
        emittedAgeSeconds: Double? = nil,
        observedAgeSeconds: Double? = nil,
        activeSessionCount: Int? = nil,
        latestHookEvent: String? = nil,
        latestHookAgeSeconds: Double? = nil,
        observedPublicationRevision: Int? = nil,
        acceptedLifecycleState: String? = nil,
        acceptedPublicationRevision: Int? = nil,
        publisherRecovery: Bool? = nil,
        overrideStatus: String = "inactive",
        fallbackReason: String? = nil,
        publicationRejectionCount: Int? = nil,
        publicationRejectionReasons: [String: Int] = [:],
        playbackMode: String,
        selectedClipName: String? = nil,
        previewStatus: String,
        toolchainStatus: String,
        lastFailureCategory: String? = nil,
        conversionFailureCategory: String? = nil,
        conversionFailureStage: String? = nil,
        preferencesMigrationStatus: PreferencesMigration.Status = .notRun
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.lifecycleState = lifecycleState
        self.publisherHealth = publisherHealth
        self.publisherSource = publisherSource
        self.emittedAgeSeconds = emittedAgeSeconds
        self.observedAgeSeconds = observedAgeSeconds
        self.activeSessionCount = activeSessionCount
        self.latestHookEvent = latestHookEvent
        self.latestHookAgeSeconds = latestHookAgeSeconds
        self.observedPublicationRevision = observedPublicationRevision
        self.acceptedLifecycleState = acceptedLifecycleState
        self.acceptedPublicationRevision = acceptedPublicationRevision
        self.publisherRecovery = publisherRecovery
        self.overrideStatus = overrideStatus
        self.fallbackReason = fallbackReason
        self.publicationRejectionCount = publicationRejectionCount
        self.publicationRejectionReasons = publicationRejectionReasons
        self.playbackMode = playbackMode
        self.selectedClipName = selectedClipName
        self.previewStatus = previewStatus
        self.toolchainStatus = toolchainStatus
        self.lastFailureCategory = lastFailureCategory
        self.conversionFailureCategory = conversionFailureCategory
        self.conversionFailureStage = conversionFailureStage
        self.preferencesMigrationStatus = preferencesMigrationStatus
    }
}

/// Builds a sanitized, copyable local health report without reading log contents.
struct PetDiagnostics {
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
    func build(
        input: PetDiagnosticsInput,
        startupStatus: LaunchAtLoginManager.Status? = nil
    ) -> String {
        let startup = startupStatus ?? launchAtLoginManager.status()
        let support = homeURL.appendingPathComponent(
            StateletIdentity.applicationSupportRelativePath,
            isDirectory: true
        )
        let app = inspectInstalledApp()
        let aggregator = inspectManagedPlist(
            at: homeURL.appendingPathComponent(
                "Library/LaunchAgents/\(StateletIdentity.aggregatorLaunchAgentLabel).plist"
            ),
            label: StateletIdentity.aggregatorLaunchAgentLabel
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
            "publisher.latest_event: \(hookEvent(input.latestHookEvent))",
            "publisher.latest_event_age: \(age(input.latestHookAgeSeconds))",
            "publisher.observed_revision: \(revision(input.observedPublicationRevision))",
            "publisher.accepted_state: \(lifecycleState(input.acceptedLifecycleState))",
            "publisher.accepted_revision: \(revision(input.acceptedPublicationRevision))",
            "publisher.recovery: \(boolean(input.publisherRecovery))",
            "publisher.override: \(category(input.overrideStatus, allowed: ["active", "inactive"]))",
            "publisher.fallback_reason: \(fallbackReason(input.fallbackReason))",
            "publisher.rejections: \(count(input.publicationRejectionCount))",
            "publisher.rejection_categories: \(rejectionCategories(input.publicationRejectionReasons))",
            "playback.mode: \(safeLabel(input.playbackMode))",
            "playback.media: \(safeMediaKind(input.selectedClipName))",
            "preview.status: \(safeLabel(input.previewStatus))",
            "toolchain.status: \(safeLabel(input.toolchainStatus))",
            "failure.category: \(safeOptionalLabel(input.lastFailureCategory))",
            "conversion.failure_category: \(safeOptionalLabel(input.conversionFailureCategory))",
            "conversion.failure_stage: \(safeOptionalLabel(input.conversionFailureStage))",
            "preferences.migration: \(input.preferencesMigrationStatus.diagnosticLabel)",
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
        case .legacyManaged: return "legacy-managed"
        case .malformed: return "malformed-unverified"
        case .unmanaged: return "unmanaged"
        }
    }

    private func startupJobLabel(_ status: LaunchAtLoginManager.Status) -> String {
        guard status.isLoaded else { return "not-loaded" }
        return status.loadedConfigurationIsCurrent ? "loaded-current" : "loaded-stale-until-login"
    }

    private func inspectInstalledApp() -> String {
        let app = homeURL.appendingPathComponent(
            "Applications/\(StateletIdentity.appBundleName)",
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: app.path) else { return "missing" }
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: infoURL),
            let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let info = object as? [String: Any]
        else { return "malformed" }
        guard info[StateletIdentity.appManagedPlistKey] as? String == LaunchAtLoginManager.managedMarker else {
            return "unmanaged"
        }
        guard
            info["CFBundleIdentifier"] as? String == LaunchAtLoginManager.bundleIdentifier,
            fileManager.isExecutableFile(
                atPath: app.appendingPathComponent(
                    "Contents/MacOS/\(StateletIdentity.executableName)"
                ).path
            )
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
        guard
            let marker = payload[StateletIdentity.launchAgentManagedPlistKey] as? String,
            marker == LaunchAtLoginManager.managedMarker
        else {
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

    private func revision(_ value: Int?) -> String {
        guard let value, value > 0 else { return "unavailable" }
        return String(value)
    }

    private func boolean(_ value: Bool?) -> String {
        guard let value else { return "unavailable" }
        return value ? "yes" : "no"
    }

    private func lifecycleState(_ value: String?) -> String {
        category(value, allowed: ["idle", "running", "waiting", "review"])
    }

    private func hookEvent(_ value: String?) -> String {
        category(value, allowed: [
            "PermissionRequest", "PostCompact", "PostToolUse", "PreCompact", "PreToolUse",
            "SessionEnd", "SessionStart", "Stop", "SubagentStart", "SubagentStop", "UserPromptSubmit",
            "unknown",
        ])
    }

    private func fallbackReason(_ value: String?) -> String {
        category(value, allowed: [
            "corrupt", "equal_revision_conflict", "equal_revision_duplicate", "future_skew",
            "legacy_timestamp_duplicate", "legacy_timestamp_rollback", "lower_revision", "missing",
            "revisionless_rollback", "stale", "unreadable",
        ])
    }

    private func rejectionCategories(_ reasons: [String: Int]) -> String {
        let allowed = Set([
            "expired", "future_event", "invalid_record", "invalid_timestamp",
            "quiescent_expired", "stale_event",
            "equal_revision_conflict", "equal_revision_duplicate", "legacy_timestamp_duplicate",
            "legacy_timestamp_rollback", "lower_revision", "revisionless_rollback",
        ])
        let entries = reasons
            .filter { allowed.contains($0.key) && $0.value > 0 }
            .sorted { $0.key < $1.key }
            .prefix(8)
            .map { "\($0.key)=\(min($0.value, 1_000_000))" }
        return entries.isEmpty ? "none" : entries.joined(separator: ",")
    }

    private func category(_ value: String?, allowed: Set<String>) -> String {
        guard let value, allowed.contains(value) else { return "unavailable" }
        return value
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
