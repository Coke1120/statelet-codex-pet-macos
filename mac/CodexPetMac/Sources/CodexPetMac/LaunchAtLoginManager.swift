import Foundation

/// Manages only Statelet's marked macOS player LaunchAgent.
///
/// This type deliberately does not inspect or change lifecycle hooks, the state
/// aggregator, or the hardware/Serial service. Callers should present
/// `LaunchAtLoginStatus.summary` directly; it never contains an absolute path.
struct LaunchAtLoginManager {
    static let playerLabel = StateletIdentity.playerLaunchAgentLabel
    static let bundleIdentifier = StateletIdentity.bundleIdentifier
    static let managedMarker = StateletIdentity.managedMarker

    enum State: Equatable {
        case missing
        case managedEnabled
        case managedDisabled
        case staleManaged
        case malformed
        case unmanaged
    }

    struct Status: Equatable {
        let state: State
        let isLoaded: Bool
        let loadedConfigurationIsCurrent: Bool
        let appIsValid: Bool

        var isEnabled: Bool { state == .managedEnabled }

        var canRepair: Bool {
            appIsValid && (state == .missing || state == .staleManaged)
        }

        var summary: String {
            let loaded = isLoaded ? "loaded" : "not loaded"
            if isLoaded, !loadedConfigurationIsCurrent,
               state == .managedEnabled || state == .managedDisabled {
                return "Startup item is repaired on disk; the loaded job keeps its previous settings until next login."
            }
            switch state {
            case .missing:
                return appIsValid
                    ? "Startup item is missing; Startup Repair can recreate it."
                    : "Startup item is missing and the installed app could not be verified."
            case .managedEnabled:
                return "Starts at login; player job is \(loaded)."
            case .managedDisabled:
                return "Does not start at login; the current app remains open."
            case .staleManaged:
                return appIsValid
                    ? "Managed startup item is stale; Startup Repair is available."
                    : "Managed startup item is stale and the installed app could not be verified."
            case .malformed:
                return "Startup item is malformed; ownership cannot be verified, so it was not changed."
            case .unmanaged:
                return "Startup item is not managed by Statelet and was not changed."
            }
        }
    }

    enum ManagerError: LocalizedError {
        case invalidInstalledApp
        case unmanagedPlist
        case malformedPlist
        case stalePlist
        case serializationFailed
        case writeFailed(String)
        case snapshotFailed
        case bootstrapFailed
        case rollbackFailed

        var errorDescription: String? {
            switch self {
            case .invalidInstalledApp:
                return "The installed \(StateletIdentity.appBundleName) could not be verified."
            case .unmanagedPlist:
                return "The startup item is not managed by Statelet and was not changed."
            case .malformedPlist:
                return "The startup item is malformed; ownership cannot be verified."
            case .stalePlist:
                return "The managed startup item is stale. Run Startup Repair first."
            case .serializationFailed:
                return "The startup item could not be serialized."
            case let .writeFailed(message):
                return "The startup item could not be written: \(message)"
            case .snapshotFailed:
                return "The existing startup item could not be safely snapshotted and was not changed."
            case .bootstrapFailed:
                return "The startup item was restored because launchd could not load it."
            case .rollbackFailed:
                return "Startup update failed and rollback was incomplete."
            }
        }
    }

    private let fileManager: FileManager
    private let homeURL: URL
    private let userID: uid_t
    private let beforeTransactionSnapshot: (() -> Void)?
    private let launchctlRunner: (([String]) -> (succeeded: Bool, output: String))?

    init(
        fileManager: FileManager = .default,
        homeURL: URL? = nil,
        userID: uid_t = getuid(),
        beforeTransactionSnapshot: (() -> Void)? = nil,
        launchctlRunner: (([String]) -> (succeeded: Bool, output: String))? = nil
    ) {
        self.fileManager = fileManager
        self.homeURL = (homeURL ?? fileManager.homeDirectoryForCurrentUser).standardizedFileURL
        self.userID = userID
        self.beforeTransactionSnapshot = beforeTransactionSnapshot
        self.launchctlRunner = launchctlRunner
    }

    /// Returns a read-only, privacy-safe view of the managed player startup item.
    func status() -> Status {
        let inspection = inspectPlist()
        let job = inspectLoadedJob()
        return Status(
            state: inspection.state,
            isLoaded: job.isLoaded,
            loadedConfigurationIsCurrent: job.configurationIsCurrent,
            appIsValid: installedAppIsValid()
        )
    }

    /// Enables or disables future login launch.
    ///
    /// Disabling updates only `RunAtLoad`; it never boots out launchd and never
    /// terminates the currently running app. Enabling a missing item creates the
    /// installer-compatible player plist after validating the installed bundle.
    @discardableResult
    func setEnabled(_ enabled: Bool) throws -> Status {
        let inspection = inspectPlist()
        switch inspection.state {
        case .unmanaged:
            throw ManagerError.unmanagedPlist
        case .malformed:
            throw ManagerError.malformedPlist
        case .staleManaged:
            throw ManagerError.stalePlist
        case .missing:
            guard enabled else { return status() }
            try repairStartup(enabled: true)
            return status()
        case .managedEnabled, .managedDisabled:
            guard var payload = inspection.payload else { throw ManagerError.malformedPlist }
            payload["RunAtLoad"] = enabled
            try transact(payload: payload, bootstrapWhenEnabled: enabled)
            return status()
        }
    }

    /// Repairs only the player startup plist using the same schema as install.sh.
    /// It refuses to replace unmarked or malformed files and does not touch the
    /// lifecycle aggregator, hooks, or any Serial service.
    @discardableResult
    func repairStartup() throws -> Status {
        let inspection = inspectPlist()
        let enabled: Bool
        switch inspection.state {
        case .missing:
            enabled = true
        case .staleManaged:
            enabled = inspection.payload?["RunAtLoad"] as? Bool ?? true
        case .managedEnabled:
            enabled = true
        case .managedDisabled:
            enabled = false
        case .unmanaged:
            throw ManagerError.unmanagedPlist
        case .malformed:
            throw ManagerError.malformedPlist
        }
        try repairStartup(enabled: enabled)
        return status()
    }

    private var supportURL: URL {
        homeURL.appendingPathComponent(
            StateletIdentity.applicationSupportRelativePath,
            isDirectory: true
        )
    }

    private var launchAgentsURL: URL {
        homeURL.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    private var playerPlistURL: URL {
        launchAgentsURL.appendingPathComponent("\(Self.playerLabel).plist")
    }

    private var installedAppURL: URL {
        homeURL.appendingPathComponent(
            "Applications/\(StateletIdentity.appBundleName)",
            isDirectory: true
        )
    }

    private var executableURL: URL {
        installedAppURL.appendingPathComponent(
            "Contents/MacOS/\(StateletIdentity.executableName)"
        )
    }

    private struct PlistInspection {
        let state: State
        let payload: [String: Any]?
    }

    private struct PlistSnapshot {
        let existed: Bool
        let data: Data?
        let permissions: mode_t
    }

    private struct LoadedJobInspection {
        let isLoaded: Bool
        let configurationIsCurrent: Bool
    }

    private func inspectPlist() -> PlistInspection {
        guard fileManager.fileExists(atPath: playerPlistURL.path) else {
            return PlistInspection(state: .missing, payload: nil)
        }
        guard
            let data = try? Data(contentsOf: playerPlistURL),
            let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let payload = object as? [String: Any]
        else {
            return PlistInspection(state: .malformed, payload: nil)
        }
        guard
            let marker = payload[StateletIdentity.launchAgentManagedPlistKey] as? String,
            marker == Self.managedMarker
        else {
            return PlistInspection(state: .unmanaged, payload: payload)
        }
        guard plistMatchesInstallerSchema(payload) else {
            return PlistInspection(state: .staleManaged, payload: payload)
        }
        guard let runAtLoad = payload["RunAtLoad"] as? Bool else {
            return PlistInspection(state: .staleManaged, payload: payload)
        }
        return PlistInspection(
            state: runAtLoad ? .managedEnabled : .managedDisabled,
            payload: payload
        )
    }

    private func plistMatchesInstallerSchema(_ payload: [String: Any]) -> Bool {
        guard
            payload["Label"] as? String == Self.playerLabel,
            payload["KeepAlive"] as? Bool == false,
            payload["LimitLoadToSessionType"] as? String == "Aqua",
            payload["ProcessType"] as? String == "Interactive",
            number(payload["ThrottleInterval"]) == 10,
            payload["StandardOutPath"] as? String == supportURL.appendingPathComponent("logs/mac-player.out.log").path,
            payload["StandardErrorPath"] as? String == supportURL.appendingPathComponent("logs/mac-player.err.log").path,
            let arguments = payload["ProgramArguments"] as? [String]
        else { return false }
        return arguments == expectedProgramArguments
    }

    private func number(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }

    private var expectedProgramArguments: [String] {
        [
            executableURL.path,
            "--media-map",
            supportURL.appendingPathComponent("media/media-map.json").path,
            "--state",
            supportURL.appendingPathComponent("runtime/current_state.json").path,
        ]
    }

    private func installerPayload(enabled: Bool) -> [String: Any] {
        [
            StateletIdentity.launchAgentManagedPlistKey: Self.managedMarker,
            "ProcessType": "Interactive",
            "RunAtLoad": enabled,
            "ThrottleInterval": 10,
            "Label": Self.playerLabel,
            "KeepAlive": false,
            "LimitLoadToSessionType": "Aqua",
            "ProgramArguments": expectedProgramArguments,
            "StandardOutPath": supportURL.appendingPathComponent("logs/mac-player.out.log").path,
            "StandardErrorPath": supportURL.appendingPathComponent("logs/mac-player.err.log").path,
        ]
    }

    private func installedAppIsValid() -> Bool {
        let expected = homeURL.appendingPathComponent(
            "Applications/\(StateletIdentity.appBundleName)",
            isDirectory: true
        )
            .standardizedFileURL
        guard installedAppURL.standardizedFileURL == expected else { return false }
        let infoURL = installedAppURL.appendingPathComponent("Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: infoURL),
            let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let info = object as? [String: Any],
            info["CFBundleIdentifier"] as? String == Self.bundleIdentifier,
            info[StateletIdentity.appManagedPlistKey] as? String == Self.managedMarker,
            fileManager.isExecutableFile(atPath: executableURL.path)
        else { return false }
        return true
    }

    private func repairStartup(enabled: Bool) throws {
        guard installedAppIsValid() else { throw ManagerError.invalidInstalledApp }
        let inspection = inspectPlist()
        guard inspection.state != .unmanaged else { throw ManagerError.unmanagedPlist }
        guard inspection.state != .malformed else { throw ManagerError.malformedPlist }
        try transact(payload: installerPayload(enabled: enabled), bootstrapWhenEnabled: enabled)
    }

    private func transact(payload: [String: Any], bootstrapWhenEnabled: Bool) throws {
        beforeTransactionSnapshot?()
        let prior = try snapshotPlist()
        let data: Data
        do {
            data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        } catch {
            throw ManagerError.serializationFailed
        }

        try fileManager.createDirectory(at: launchAgentsURL, withIntermediateDirectories: true)
        try requireUnchangedSnapshot(prior)
        var installedNewData = false
        do {
            try data.write(to: playerPlistURL, options: .atomic)
            installedNewData = true
            guard chmod(playerPlistURL.path, 0o644) == 0 else {
                throw ManagerError.writeFailed("permissions")
            }
        } catch let error as ManagerError {
            if installedNewData {
                do {
                    try restore(prior, replacing: data)
                } catch {
                    throw ManagerError.rollbackFailed
                }
            }
            throw error
        } catch {
            if installedNewData {
                do {
                    try restore(prior, replacing: data)
                } catch {
                    throw ManagerError.rollbackFailed
                }
            }
            throw ManagerError.writeFailed("atomic replacement failed")
        }

        guard bootstrapWhenEnabled, !launchJobIsLoaded() else { return }
        guard runLaunchctl(["bootstrap", "gui/\(userID)", playerPlistURL.path]) else {
            var launchdRollbackComplete = true
            if launchJobIsLoaded() {
                launchdRollbackComplete = runLaunchctl([
                    "bootout",
                    "gui/\(userID)",
                    playerPlistURL.path,
                ]) && !launchJobIsLoaded()
            }
            do {
                try restore(prior, replacing: data)
            } catch {
                throw ManagerError.rollbackFailed
            }
            guard launchdRollbackComplete else { throw ManagerError.rollbackFailed }
            throw ManagerError.bootstrapFailed
        }
    }

    private func snapshotPlist() throws -> PlistSnapshot {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: playerPlistURL.path, isDirectory: &isDirectory) else {
            return PlistSnapshot(existed: false, data: nil, permissions: 0o644)
        }
        guard !isDirectory.boolValue else { throw ManagerError.snapshotFailed }
        do {
            let data = try Data(contentsOf: playerPlistURL)
            guard
                let object = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                ),
                let payload = object as? [String: Any]
            else { throw ManagerError.snapshotFailed }
            guard
                let marker = payload[StateletIdentity.launchAgentManagedPlistKey] as? String,
                marker == Self.managedMarker
            else {
                throw ManagerError.unmanagedPlist
            }
            let attributes = try fileManager.attributesOfItem(atPath: playerPlistURL.path)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
            return PlistSnapshot(existed: true, data: data, permissions: mode_t(permissions))
        } catch let error as ManagerError {
            throw error
        } catch {
            throw ManagerError.snapshotFailed
        }
    }

    private func requireUnchangedSnapshot(_ prior: PlistSnapshot) throws {
        if prior.existed {
            guard let expectedData = prior.data,
                  let currentData = try? Data(contentsOf: playerPlistURL),
                  currentData == expectedData else {
                throw ManagerError.snapshotFailed
            }
        } else if fileManager.fileExists(atPath: playerPlistURL.path) {
            throw ManagerError.snapshotFailed
        }
    }

    private func restore(_ prior: PlistSnapshot, replacing installedData: Data) throws {
        guard let currentData = try? Data(contentsOf: playerPlistURL),
              currentData == installedData else {
            throw ManagerError.rollbackFailed
        }
        if prior.existed {
            guard let data = prior.data else { throw ManagerError.rollbackFailed }
            try data.write(to: playerPlistURL, options: .atomic)
            guard chmod(playerPlistURL.path, prior.permissions) == 0 else {
                throw ManagerError.rollbackFailed
            }
        } else if fileManager.fileExists(atPath: playerPlistURL.path) {
            try fileManager.removeItem(at: playerPlistURL)
        }
    }

    private func launchJobIsLoaded() -> Bool {
        inspectLoadedJob().isLoaded
    }

    private func inspectLoadedJob() -> LoadedJobInspection {
        let result = launchctlResult(["print", "gui/\(userID)/\(Self.playerLabel)"])
        guard result.succeeded else {
            return LoadedJobInspection(isLoaded: false, configurationIsCurrent: true)
        }
        let requiredValues = expectedProgramArguments
        return LoadedJobInspection(
            isLoaded: true,
            configurationIsCurrent: requiredValues.allSatisfy { result.output.contains($0) }
        )
    }

    @discardableResult
    private func runLaunchctl(_ arguments: [String]) -> Bool {
        launchctlResult(arguments).succeeded
    }

    private func launchctlResult(_ arguments: [String]) -> (succeeded: Bool, output: String) {
        if let launchctlRunner {
            return launchctlRunner(arguments)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (
                process.terminationStatus == 0,
                String(data: data, encoding: .utf8) ?? ""
            )
        } catch {
            return (false, "")
        }
    }
}
