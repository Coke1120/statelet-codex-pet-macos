import CryptoKit
import Darwin
import Foundation
import Security

struct StateletSemanticVersion: Comparable, CustomStringConvertible, Equatable {
    private enum Identifier: Equatable {
        case number(Int)
        case text(String)
    }

    let major: Int
    let minor: Int
    let patch: Int
    private let prerelease: [Identifier]
    private let prereleaseText: String?

    init?(_ value: String) {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.first == "v" || normalized.first == "V" {
            normalized.removeFirst()
        }
        let withoutBuild = normalized.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let versionAndPrerelease = withoutBuild.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let components = versionAndPrerelease[0].split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard (1 ... 3).contains(components.count) else { return nil }
        var numbers = [Int]()
        for component in components {
            guard !component.isEmpty,
                  component.allSatisfy({ $0.isNumber }),
                  (component.count == 1 || component.first != "0"),
                  let number = Int(component) else {
                return nil
            }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }

        var parsedPrerelease = [Identifier]()
        var parsedPrereleaseText: String?
        if versionAndPrerelease.count == 2 {
            let text = String(versionAndPrerelease[1])
            guard !text.isEmpty else { return nil }
            for component in text.split(separator: ".", omittingEmptySubsequences: false) {
                guard !component.isEmpty,
                      component.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
                    return nil
                }
                if component.allSatisfy({ $0.isNumber }) {
                    guard component.count == 1 || component.first != "0",
                          let number = Int(component) else {
                        return nil
                    }
                    parsedPrerelease.append(.number(number))
                } else {
                    parsedPrerelease.append(.text(String(component).lowercased()))
                }
            }
            parsedPrereleaseText = text
        }

        major = numbers[0]
        minor = numbers[1]
        patch = numbers[2]
        prerelease = parsedPrerelease
        prereleaseText = parsedPrereleaseText
    }

    var description: String {
        let base = "\(major).\(minor).\(patch)"
        return prereleaseText.map { "\(base)-\($0)" } ?? base
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let lhsCore = [lhs.major, lhs.minor, lhs.patch]
        let rhsCore = [rhs.major, rhs.minor, rhs.patch]
        if lhsCore != rhsCore {
            return lhsCore.lexicographicallyPrecedes(rhsCore)
        }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (left, right) {
            case let (.number(a), .number(b)):
                return a < b
            case (.number, .text):
                return true
            case (.text, .number):
                return false
            case let (.text(a), .text(b)):
                return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

struct StateletVersion: Comparable, CustomStringConvertible, Equatable {
    let semantic: StateletSemanticVersion
    let build: Int

    init?(version: String, build: String) {
        guard let semantic = StateletSemanticVersion(version),
              let buildNumber = Int(build),
              buildNumber >= 0 else {
            return nil
        }
        self.semantic = semantic
        self.build = buildNumber
    }

    init?(releaseTag: String, releaseName: String? = nil) {
        guard let semantic = StateletSemanticVersion(releaseTag) else { return nil }
        self.semantic = semantic
        build = Self.releaseBuild(tag: releaseTag, name: releaseName) ?? 0
    }

    var description: String { "\(semantic) (\(build))" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.semantic == rhs.semantic ? lhs.build < rhs.build : lhs.semantic < rhs.semantic
    }

    static func current(bundle: Bundle = .main) -> StateletVersion {
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return StateletVersion(version: version, build: build)
            ?? StateletVersion(version: "0.0.0", build: "0")!
    }

    private static func releaseBuild(tag: String, name: String?) -> Int? {
        let buildMetadata = tag.split(separator: "+", maxSplits: 1).dropFirst().first.map(String.init)
        if let buildMetadata {
            let components = buildMetadata.split { !$0.isNumber }
            if let candidate = components.last, let value = Int(candidate) { return value }
        }
        if let name,
           let open = name.lastIndex(of: "("),
           let close = name[open...].firstIndex(of: ")") {
            let candidate = name[name.index(after: open) ..< close]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Int(candidate) { return value }
        }
        return nil
    }
}

struct StateletReleaseAsset: Decodable, Equatable {
    let name: String
    let browserDownloadURL: URL
    let size: Int64
    let contentType: String
    let digest: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
        case contentType = "content_type"
        case digest
    }

    var sha256Digest: String? {
        guard let digest else { return nil }
        let parts = digest.lowercased().split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0] == "sha256", Self.isSHA256(String(parts[1])) else {
            return nil
        }
        return String(parts[1])
    }

    fileprivate static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }
}

struct StateletGitHubRelease: Decodable, Equatable {
    let tagName: String
    let name: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let htmlURL: URL
    let publishedAt: Date?
    let assets: [StateletReleaseAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case draft
        case prerelease
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case assets
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try values.decode(String.self, forKey: .tagName)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        body = try values.decodeIfPresent(String.self, forKey: .body)
        draft = try values.decode(Bool.self, forKey: .draft)
        prerelease = try values.decode(Bool.self, forKey: .prerelease)
        htmlURL = try values.decode(URL.self, forKey: .htmlURL)
        assets = try values.decode([StateletReleaseAsset].self, forKey: .assets)
        if let dateText = try values.decodeIfPresent(String.self, forKey: .publishedAt) {
            publishedAt = Self.parseDate(dateText)
        } else {
            publishedAt = nil
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

struct StateletUpdateCandidate: Equatable {
    let version: StateletVersion
    let releaseNotes: String
    let releasePageURL: URL
    let packageAsset: StateletReleaseAsset
    let checksumAsset: StateletReleaseAsset?
}

enum StateletReleaseFeed {
    static let releasesURL = URL(
        string: "https://api.github.com/repos/Coke1120/statelet-codex-pet-macos/releases?per_page=20"
    )!

    static func decode(_ data: Data) throws -> [StateletGitHubRelease] {
        do {
            return try JSONDecoder().decode([StateletGitHubRelease].self, from: data)
        } catch {
            throw StateletUpdaterError.invalidReleaseFeed
        }
    }

    static func selectCandidate(
        from releases: [StateletGitHubRelease],
        newerThan installed: StateletVersion
    ) -> StateletUpdateCandidate? {
        releases.compactMap { release -> StateletUpdateCandidate? in
            guard !release.draft,
                  !release.prerelease,
                  release.htmlURL.scheme?.lowercased() == "https",
                  let version = StateletVersion(releaseTag: release.tagName, releaseName: release.name),
                  version > installed,
                  let package = selectPackage(from: release.assets) else {
                return nil
            }
            let checksum = selectChecksum(for: package, from: release.assets)
            guard package.sha256Digest != nil || checksum != nil else { return nil }
            return StateletUpdateCandidate(
                version: version,
                releaseNotes: sanitizedNotes(release.body),
                releasePageURL: release.htmlURL,
                packageAsset: package,
                checksumAsset: checksum
            )
        }.max { $0.version < $1.version }
    }

    private static func selectPackage(from assets: [StateletReleaseAsset]) -> StateletReleaseAsset? {
        assets.filter { asset in
            let lower = asset.name.lowercased()
            return asset.browserDownloadURL.scheme?.lowercased() == "https"
                && asset.size > 0
                && lower.hasPrefix("statelet")
                && lower.hasSuffix(".zip")
        }.sorted { lhs, rhs in
            packageRank(lhs.name) < packageRank(rhs.name)
        }.first
    }

    private static func packageRank(_ name: String) -> Int {
        let lower = name.lowercased()
        if lower.contains("universal") { return 0 }
        #if arch(arm64)
        if lower.contains("arm64") || lower.contains("aarch64") { return 1 }
        #elseif arch(x86_64)
        if lower.contains("x86_64") || lower.contains("amd64") { return 1 }
        #endif
        return 2
    }

    private static func selectChecksum(
        for package: StateletReleaseAsset,
        from assets: [StateletReleaseAsset]
    ) -> StateletReleaseAsset? {
        let preferred = [
            "\(package.name).sha256",
            "\((package.name as NSString).deletingPathExtension).sha256",
            "SHA256SUMS.txt",
        ]
        for name in preferred {
            if let match = assets.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
                    && $0.browserDownloadURL.scheme?.lowercased() == "https"
                    && $0.size > 0
            }) {
                return match
            }
        }
        return nil
    }

    private static func sanitizedNotes(_ value: String?) -> String {
        let notes = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return notes.isEmpty ? "See the release page for details." : String(notes.prefix(20_000))
    }
}

enum StateletArtifactVerifier {
    static func expectedSHA256(
        for package: StateletReleaseAsset,
        checksumData: Data?
    ) throws -> String {
        if let digest = package.sha256Digest { return digest }
        guard let checksumData,
              checksumData.count <= 1_048_576,
              let text = String(data: checksumData, encoding: .utf8) else {
            throw StateletUpdaterError.missingChecksum
        }
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard let first = fields.first else { continue }
            let digest = String(first).lowercased()
            guard StateletReleaseAsset.isSHA256(digest) else { continue }
            if fields.count == 1 { return digest }
            let filename = fields.dropFirst().joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if filename == package.name { return digest }
        }
        throw StateletUpdaterError.missingChecksum
    }

    static func verifyFile(at url: URL, expectedSize: Int64, expectedSHA256: String) throws {
        try Task.checkCancellation()
        guard url.isFileURL,
              expectedSize > 0,
              StateletReleaseAsset.isSHA256(expectedSHA256.lowercased()) else {
            throw StateletUpdaterError.invalidArtifact
        }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values?.isRegularFile == true,
              values?.isSymbolicLink != true,
              Int64(values?.fileSize ?? -1) == expectedSize else {
            throw StateletUpdaterError.artifactSizeMismatch
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw StateletUpdaterError.invalidArtifact
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw StateletUpdaterError.invalidArtifact
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expectedSHA256.lowercased() else {
            throw StateletUpdaterError.artifactHashMismatch
        }
    }
}

struct StateletBundleMetadata {
    let version: StateletVersion
    let minimumSystemVersion: OperatingSystemVersion?
}

enum StateletBundleValidator {
    static func validate(at bundleURL: URL, requireTrustedSignature: Bool = true) throws -> StateletBundleMetadata {
        guard bundleURL.isFileURL else { throw StateletUpdaterError.invalidBundle }
        let bundleValues = try? bundleURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard bundleValues?.isDirectory == true, bundleValues?.isSymbolicLink != true else {
            throw StateletUpdaterError.invalidBundle
        }
        let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        let infoValues = try? infoURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard infoValues?.isRegularFile == true,
              infoValues?.isSymbolicLink != true,
              let data = try? Data(contentsOf: infoURL, options: [.mappedIfSafe]),
              data.count <= 1_048_576,
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == StateletIdentity.bundleIdentifier,
              info["CFBundleExecutable"] as? String == StateletIdentity.executableName,
              info[StateletIdentity.appManagedPlistKey] as? String == StateletIdentity.managedMarker,
              let versionString = info["CFBundleShortVersionString"] as? String,
              let buildString = info["CFBundleVersion"] as? String,
              let version = StateletVersion(version: versionString, build: buildString) else {
            throw StateletUpdaterError.invalidBundleIdentity
        }
        let executableURL = bundleURL.appendingPathComponent(
            "Contents/MacOS/\(StateletIdentity.executableName)",
            isDirectory: false
        )
        let executableValues = try? executableURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isExecutableKey,
        ])
        guard executableValues?.isRegularFile == true,
              executableValues?.isSymbolicLink != true,
              executableValues?.isExecutable == true else {
            throw StateletUpdaterError.invalidBundleIdentity
        }
        if requireTrustedSignature { try validateSignature(at: bundleURL) }

        guard let minimumVersionText = info["LSMinimumSystemVersion"] as? String,
              let minimumVersion = parseOperatingSystemVersion(minimumVersionText) else {
            throw StateletUpdaterError.unsupportedSystem
        }
        if !ProcessInfo.processInfo.isOperatingSystemAtLeast(minimumVersion) {
            throw StateletUpdaterError.unsupportedSystem
        }
        return StateletBundleMetadata(version: version, minimumSystemVersion: minimumVersion)
    }

    private static func validateSignature(at bundleURL: URL) throws {
        guard let authorizedTeamIdentifier = Bundle.main.object(
            forInfoDictionaryKey: StateletIdentity.updateSigningTeamIdentifierKey
        ) as? String,
        authorizedTeamIdentifier.count == 10,
        authorizedTeamIdentifier != "$(STATELET_UPDATE_SIGNING_TEAM_IDENTIFIER)" else {
            throw StateletUpdaterError.untrustedSignature
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else {
            throw StateletUpdaterError.untrustedSignature
        }
        var requirement: SecRequirement?
        let requirementText = "identifier \"\(StateletIdentity.bundleIdentifier)\" and anchor apple generic"
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(
                code,
                SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                requirement
              ) == errSecSuccess else {
            throw StateletUpdaterError.untrustedSignature
        }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInformation) == errSecSuccess,
              let information = signingInformation as? [String: Any],
              information[kSecCodeInfoTeamIdentifier as String] as? String == authorizedTeamIdentifier,
              let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate],
              !certificates.isEmpty else {
            throw StateletUpdaterError.untrustedSignature
        }
        try validateArchitecture(at: bundleURL)
    }

    private static func validateArchitecture(at bundleURL: URL) throws {
        let executable = bundleURL.appendingPathComponent(
            "Contents/MacOS/\(StateletIdentity.executableName)",
            isDirectory: false
        )
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
        process.arguments = ["-info", executable.path]
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw StateletUpdaterError.invalidBundleIdentity
        }
        guard process.terminationStatus == 0,
              let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            throw StateletUpdaterError.invalidBundleIdentity
        }
        #if arch(arm64)
        let requiredArchitecture = "arm64"
        #elseif arch(x86_64)
        let requiredArchitecture = "x86_64"
        #else
        let requiredArchitecture = ""
        #endif
        guard !requiredArchitecture.isEmpty,
              text.split(whereSeparator: { $0.isWhitespace }).contains(where: { $0 == requiredArchitecture }) else {
            throw StateletUpdaterError.invalidBundleIdentity
        }
        let gatekeeper = Process()
        gatekeeper.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        gatekeeper.arguments = ["--assess", "--type", "execute", "--no-cache", bundleURL.path]
        gatekeeper.standardOutput = FileHandle.nullDevice
        gatekeeper.standardError = FileHandle.nullDevice
        do {
            try gatekeeper.run()
            gatekeeper.waitUntilExit()
        } catch {
            throw StateletUpdaterError.untrustedSignature
        }
        guard gatekeeper.terminationStatus == 0 else {
            throw StateletUpdaterError.untrustedSignature
        }
    }

    private static func parseOperatingSystemVersion(_ value: String) -> OperatingSystemVersion? {
        let rawComponents = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard (1 ... 3).contains(rawComponents.count) else { return nil }
        var components = [Int]()
        for component in rawComponents {
            guard !component.isEmpty,
                  component.allSatisfy(\.isNumber),
                  let number = Int(component),
                  number >= 0 else {
                return nil
            }
            components.append(number)
        }
        guard components[0] > 0 else { return nil }
        return OperatingSystemVersion(
            majorVersion: components[0],
            minorVersion: components.count > 1 ? components[1] : 0,
            patchVersion: components.count > 2 ? components[2] : 0
        )
    }
}

struct StateletDownloadedUpdate {
    let artifactURL: URL
    let bundleURL: URL
    let cleanupRootURL: URL?

    init(artifactURL: URL, bundleURL: URL, cleanupRootURL: URL? = nil) {
        self.artifactURL = artifactURL
        self.bundleURL = bundleURL
        self.cleanupRootURL = cleanupRootURL
    }

    func removeOwnedStaging(fileManager: FileManager = .default) {
        guard let cleanupRootURL else { return }
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("StateletUpdates", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let root = cleanupRootURL.resolvingSymlinksInPath().standardizedFileURL
        let artifact = artifactURL.resolvingSymlinksInPath().standardizedFileURL
        let bundle = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : "\(root.path)/"
        guard root.deletingLastPathComponent().path == base.path,
              !root.lastPathComponent.isEmpty,
              artifact.path.hasPrefix(rootPrefix),
              bundle.path.hasPrefix(rootPrefix),
              fileManager.fileExists(atPath: root.path) else {
            return
        }
        try? fileManager.removeItem(at: root)
    }
}

struct StateletUpdateSnapshot: Equatable {
    let status: String
    let installedVersion: String
    let candidateVersion: String?
    let releaseNotes: String?
    let progress: Double?
    let isChecking: Bool
    let isReadyToInstall: Bool
    let isScheduledForRestart: Bool
    let isBlocked: Bool
    let automaticInstallEnabled: Bool
}

struct StateletUpdatePolicy {
    static let checkInterval: TimeInterval = 24 * 60 * 60

    static func shouldCheckAutomatically(now: Date, lastCheck: Date?) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= checkInterval
    }
}

enum StateletUpdaterError: Error, Equatable {
    case invalidReleaseFeed
    case offline
    case noTrustedReleaseAsset
    case missingChecksum
    case invalidArtifact
    case artifactSizeMismatch
    case artifactHashMismatch
    case invalidBundle
    case invalidBundleIdentity
    case untrustedSignature
    case unsupportedSystem
    case versionMismatch
    case unsafeInstallBoundary
    case transactionRecoveryRequired
    case cancelled

    var safeStatus: String {
        switch self {
        case .invalidReleaseFeed: return "The update feed could not be verified."
        case .offline: return "Statelet is offline; the current app will keep running."
        case .noTrustedReleaseAsset: return "No trusted Statelet update package is available."
        case .missingChecksum: return "The update checksum is missing or invalid."
        case .invalidArtifact: return "The downloaded update could not be verified."
        case .artifactSizeMismatch: return "The downloaded update has an unexpected size."
        case .artifactHashMismatch: return "The downloaded update failed integrity verification."
        case .invalidBundle, .invalidBundleIdentity: return "The update is not a managed Statelet app."
        case .untrustedSignature: return "The update does not have a trusted signature."
        case .unsupportedSystem: return "This update does not support this Mac."
        case .versionMismatch: return "The update version does not match the release."
        case .unsafeInstallBoundary: return "The update is ready and will install at a safe restart."
        case .transactionRecoveryRequired: return "The update transaction needs recovery before another install."
        case .cancelled: return "Update check cancelled."
        }
    }
}

final class StateletUpdateCoordinator {
    typealias ReleaseFetcher = () async throws -> Data
    typealias AssetDataFetcher = (StateletReleaseAsset) async throws -> Data
    typealias Downloader = (
        StateletReleaseAsset,
        @escaping (Double) -> Void
    ) async throws -> StateletDownloadedUpdate
    typealias DownloadPreparation = (StateletDownloadedUpdate) async throws -> StateletDownloadedUpdate
    typealias Installer = (StateletDownloadedUpdate, StateletUpdateCandidate) throws -> Void
    typealias BundleValidation = (URL) async throws -> StateletBundleMetadata

    var onSnapshot: ((StateletUpdateSnapshot) -> Void)? {
        didSet { onSnapshot?(snapshot) }
    }

    private(set) var snapshot: StateletUpdateSnapshot
    private let installedVersion: StateletVersion
    private let defaults: UserDefaults
    private let lastCheckKey: String
    private let automaticInstallKey: String
    private let pendingInstallRetryKey: String
    private let now: () -> Date
    private let fetchReleases: ReleaseFetcher
    private let fetchAssetData: AssetDataFetcher
    private let download: Downloader
    private let prepareDownloadedUpdate: DownloadPreparation
    private let installer: Installer
    private let validateBundle: BundleValidation
    private var operation: Task<Void, Never>?
    private var readyUpdate: (StateletDownloadedUpdate, StateletUpdateCandidate)?
    private var downloadProgressToken: UUID?

    convenience init(
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main,
        installer: Installer? = nil
    ) {
        let resolvedInstaller = installer ?? { _, _ in
            // Installation must be supplied by the transactional installer boundary.
            // The standalone core intentionally cannot replace the running app.
            throw StateletUpdaterError.unsafeInstallBoundary
        }
        self.init(
            installedVersion: .current(bundle: bundle),
            defaults: defaults,
            fetchReleases: {
                try await Self.fetchHTTPSData(
                    from: StateletReleaseFeed.releasesURL,
                    maximumSize: 2 * 1_048_576
                )
            },
            fetchAssetData: { asset in
                try await Self.fetchHTTPSData(
                    from: asset.browserDownloadURL,
                    maximumSize: 1_048_576
                )
            },
            download: { asset, progress in
                try await Self.downloadArtifact(asset: asset, progress: progress)
            },
            prepareDownloadedUpdate: { downloaded in
                try await Self.expandDownloadedUpdate(downloaded)
            },
            installer: resolvedInstaller,
            validateBundle: { url in
                try await Self.validateBundleOffMain(url)
            }
        )
    }

    init(
        installedVersion: StateletVersion = .current(),
        defaults: UserDefaults = .standard,
        lastCheckKey: String = "StateletUpdater.lastCheckDate.v1",
        automaticInstallKey: String = "StateletUpdater.automaticInstall.v1",
        pendingInstallRetryKey: String = "StateletUpdater.pendingInstallRetry.v1",
        now: @escaping () -> Date = Date.init,
        fetchReleases: @escaping ReleaseFetcher,
        fetchAssetData: @escaping AssetDataFetcher,
        download: @escaping Downloader,
        prepareDownloadedUpdate: @escaping DownloadPreparation = { $0 },
        installer: @escaping Installer,
        validateBundle: @escaping BundleValidation = { url in
            try await StateletUpdateCoordinator.validateBundleOffMain(url)
        }
    ) {
        self.installedVersion = installedVersion
        self.defaults = defaults
        self.lastCheckKey = lastCheckKey
        self.automaticInstallKey = automaticInstallKey
        self.pendingInstallRetryKey = pendingInstallRetryKey
        self.now = now
        self.fetchReleases = fetchReleases
        self.fetchAssetData = fetchAssetData
        self.download = download
        self.prepareDownloadedUpdate = prepareDownloadedUpdate
        self.installer = installer
        self.validateBundle = validateBundle
        let automaticInstall = defaults.bool(forKey: automaticInstallKey)
        snapshot = StateletUpdateSnapshot(
            status: "Ready to check for updates.",
            installedVersion: installedVersion.description,
            candidateVersion: nil,
            releaseNotes: nil,
            progress: nil,
            isChecking: false,
            isReadyToInstall: false,
            isScheduledForRestart: false,
            isBlocked: false,
            automaticInstallEnabled: automaticInstall
        )
    }

    func startAutomaticChecks() {
        let lastCheck = defaults.object(forKey: lastCheckKey) as? Date
        let retryPendingInstall = defaults.bool(forKey: pendingInstallRetryKey)
        guard retryPendingInstall
            || StateletUpdatePolicy.shouldCheckAutomatically(now: now(), lastCheck: lastCheck) else { return }
        Task { @MainActor [weak self] in self?.beginCheck() }
    }

    func checkNow() {
        Task { @MainActor [weak self] in self?.beginCheck() }
    }

    func setAutomaticInstall(_ enabled: Bool) {
        defaults.set(enabled, forKey: automaticInstallKey)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.publish(
                status: self.snapshot.status,
                candidate: self.readyUpdate?.1,
                progress: self.snapshot.progress,
                isChecking: self.snapshot.isChecking,
                isReady: self.snapshot.isReadyToInstall,
                isScheduled: self.snapshot.isScheduledForRestart
            )
            if self.defaults.bool(forKey: self.automaticInstallKey), self.readyUpdate != nil {
                self.scheduleReadyInstall()
            }
        }
    }

    func installReadyUpdate() {
        Task { @MainActor [weak self] in self?.scheduleReadyInstall() }
    }

    @MainActor
    private func scheduleReadyInstall() {
        guard let readyUpdate else { return }
        publish(
            status: "Update scheduled for the next Statelet restart.",
            candidate: readyUpdate.1,
            progress: 1,
            isScheduled: true
        )
    }

    @MainActor
    func commitScheduledUpdateAtTermination(
        ifQuiescent isQuiescent: Bool
    ) throws -> StateletUpdateCandidate? {
        guard snapshot.isScheduledForRestart,
              let readyUpdate else { return nil }
        guard isQuiescent else {
            defaults.set(true, forKey: pendingInstallRetryKey)
            return nil
        }
        defer { readyUpdate.0.removeOwnedStaging() }
        do {
            try installer(readyUpdate.0, readyUpdate.1)
        } catch {
            defaults.set(true, forKey: pendingInstallRetryKey)
            throw error
        }
        self.readyUpdate = nil
        defaults.removeObject(forKey: pendingInstallRetryKey)
        publish(
            status: "Update installed. Reopen Statelet to use the new version.",
            candidate: readyUpdate.1,
            progress: 1
        )
        return readyUpdate.1
    }

    @MainActor
    func discardPreparedUpdateAtTermination() {
        readyUpdate?.0.removeOwnedStaging()
        readyUpdate = nil
    }

    func cancel() {
        defaults.removeObject(forKey: pendingInstallRetryKey)
        Task { @MainActor [weak self] in self?.operation?.cancel() }
    }

    @MainActor
    private func beginCheck() {
        guard operation == nil,
              readyUpdate == nil,
              !snapshot.isScheduledForRestart,
              !snapshot.isBlocked else { return }
        defaults.set(now(), forKey: lastCheckKey)
        operation = Task { [weak self] in
            guard let self else { return }
            await self.performCheck()
            self.operation = nil
        }
    }

    @MainActor
    private func performCheck() async {
        var stagingToCleanup: StateletDownloadedUpdate?
        let retryPendingInstall = defaults.bool(forKey: pendingInstallRetryKey)
        publish(status: "Checking for updates…", isChecking: true)
        do {
            let data = try await fetchReleases()
            try Task.checkCancellation()
            let releases = try StateletReleaseFeed.decode(data)
            guard let candidate = StateletReleaseFeed.selectCandidate(
                from: releases,
                newerThan: installedVersion
            ) else {
                readyUpdate = nil
                defaults.removeObject(forKey: pendingInstallRetryKey)
                publish(status: "Statelet is up to date.")
                return
            }
            publish(
                status: "Downloading update…",
                candidate: candidate,
                progress: 0,
                isChecking: true
            )
            let checksumData: Data?
            if let checksumAsset = candidate.checksumAsset,
               candidate.packageAsset.sha256Digest == nil {
                checksumData = try await fetchAssetData(checksumAsset)
            } else {
                checksumData = nil
            }
            let expectedHash = try StateletArtifactVerifier.expectedSHA256(
                for: candidate.packageAsset,
                checksumData: checksumData
            )
            let progressToken = UUID()
            downloadProgressToken = progressToken
            let downloaded = try await download(candidate.packageAsset) { [weak self] progress in
                Task { @MainActor in
                    guard let self,
                          self.operation != nil,
                          self.downloadProgressToken == progressToken else { return }
                    self.publish(
                        status: "Downloading update…",
                        candidate: candidate,
                        progress: min(max(progress, 0), 1),
                        isChecking: true
                    )
                }
            }
            await Task.yield()
            downloadProgressToken = nil
            stagingToCleanup = downloaded
            try Task.checkCancellation()
            try await Self.verifyArtifactOffMain(
                downloaded.artifactURL,
                expectedSize: candidate.packageAsset.size,
                expectedSHA256: expectedHash
            )
            let preparedUpdate = try await prepareDownloadedUpdate(downloaded)
            stagingToCleanup = preparedUpdate
            try Task.checkCancellation()
            let metadata = try await validateBundle(preparedUpdate.bundleURL)
            try Task.checkCancellation()
            guard metadata.version > installedVersion,
                  metadata.version.semantic == candidate.version.semantic,
                  candidate.version.build == 0 || metadata.version.build == candidate.version.build else {
                throw StateletUpdaterError.versionMismatch
            }
            readyUpdate = (preparedUpdate, candidate)
            stagingToCleanup = nil
            publish(
                status: "Update verified and ready to install.",
                candidate: candidate,
                progress: 1,
                isReady: true
            )
            if snapshot.automaticInstallEnabled || retryPendingInstall {
                scheduleReadyInstall()
            }
        } catch is CancellationError {
            downloadProgressToken = nil
            readyUpdate = nil
            publish(status: StateletUpdaterError.cancelled.safeStatus)
        } catch let error as StateletUpdaterError {
            downloadProgressToken = nil
            readyUpdate = nil
            publish(status: error.safeStatus)
        } catch is URLError {
            downloadProgressToken = nil
            readyUpdate = nil
            publish(status: StateletUpdaterError.offline.safeStatus)
        } catch {
            downloadProgressToken = nil
            readyUpdate = nil
            publish(status: "Unable to check for updates. Statelet will keep running normally.")
        }
        if let stagingToCleanup {
            await Self.removeOwnedStagingOffMain(stagingToCleanup)
        }
    }

    @MainActor
    private func publish(
        status: String,
        candidate: StateletUpdateCandidate? = nil,
        progress: Double? = nil,
        isChecking: Bool = false,
        isReady: Bool = false,
        isScheduled: Bool = false,
        isBlocked: Bool = false
    ) {
        snapshot = StateletUpdateSnapshot(
            status: status,
            installedVersion: installedVersion.description,
            candidateVersion: candidate?.version.description,
            releaseNotes: candidate?.releaseNotes,
            progress: progress,
            isChecking: isChecking,
            isReadyToInstall: isReady,
            isScheduledForRestart: isScheduled,
            isBlocked: isBlocked,
            automaticInstallEnabled: defaults.bool(forKey: automaticInstallKey)
        )
        onSnapshot?(snapshot)
    }

    private static func fetchHTTPSData(from url: URL, maximumSize: Int) async throws -> Data {
        guard url.scheme?.lowercased() == "https", maximumSize > 0 else {
            throw StateletUpdaterError.invalidReleaseFeed
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Statelet-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode),
              http.url?.scheme?.lowercased() == "https",
              data.count <= maximumSize else {
            throw StateletUpdaterError.invalidReleaseFeed
        }
        return data
    }

    private static func verifyArtifactOffMain(
        _ url: URL,
        expectedSize: Int64,
        expectedSHA256: String
    ) async throws {
        let verification = Task.detached(priority: .utility) {
            try StateletArtifactVerifier.verifyFile(
                at: url,
                expectedSize: expectedSize,
                expectedSHA256: expectedSHA256
            )
        }
        try await withTaskCancellationHandler {
            try await verification.value
        } onCancel: {
            verification.cancel()
        }
    }

    private static func validateBundleOffMain(_ url: URL) async throws -> StateletBundleMetadata {
        let validation = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let metadata = try StateletBundleValidator.validate(at: url)
            try Task.checkCancellation()
            return metadata
        }
        return try await withTaskCancellationHandler {
            try await validation.value
        } onCancel: {
            validation.cancel()
        }
    }

    private static func removeOwnedStagingOffMain(_ update: StateletDownloadedUpdate) async {
        await Task.detached(priority: .utility) {
            update.removeOwnedStaging()
        }.value
    }

    private static func downloadArtifact(
        asset: StateletReleaseAsset,
        progress: @escaping (Double) -> Void
    ) async throws -> StateletDownloadedUpdate {
        guard asset.browserDownloadURL.scheme?.lowercased() == "https", asset.size > 0 else {
            throw StateletUpdaterError.invalidArtifact
        }
        var request = URLRequest(url: asset.browserDownloadURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 5 * 60
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("Statelet-Updater", forHTTPHeaderField: "User-Agent")
        progress(0)
        let progressDelegate = StateletUpdateDownloadProgressDelegate(
            declaredSize: asset.size,
            progress: progress
        )
        let (temporaryURL, response) = try await URLSession.shared.download(
            for: request,
            delegate: progressDelegate
        )
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode),
              http.url?.scheme?.lowercased() == "https" else {
            throw StateletUpdaterError.invalidArtifact
        }
        let result = try await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let base = manager.temporaryDirectory
                .appendingPathComponent("StateletUpdates", isDirectory: true)
            try manager.createDirectory(at: base, withIntermediateDirectories: true)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
            let staging = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: staging, withIntermediateDirectories: false)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
            do {
                let artifact = staging.appendingPathComponent("Statelet-update.zip")
                try manager.moveItem(at: temporaryURL, to: artifact)
                return StateletDownloadedUpdate(
                    artifactURL: artifact,
                    bundleURL: artifact,
                    cleanupRootURL: staging
                )
            } catch {
                try? manager.removeItem(at: staging)
                throw error
            }
        }.value
        progress(1)
        return result
    }

    private static func expandDownloadedUpdate(
        _ downloaded: StateletDownloadedUpdate
    ) async throws -> StateletDownloadedUpdate {
        let expansion = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let manager = FileManager.default
            let staging = downloaded.artifactURL.deletingLastPathComponent()
            let expanded = staging.appendingPathComponent("Expanded", isDirectory: true)
            try manager.createDirectory(at: expanded, withIntermediateDirectories: false)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", "--noqtn", downloaded.artifactURL.path, expanded.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                while process.isRunning {
                    if Task.isCancelled {
                        process.terminate()
                        process.waitUntilExit()
                        throw CancellationError()
                    }
                    Darwin.usleep(50_000)
                }
                try Task.checkCancellation()
                guard process.terminationReason == .exit,
                      process.terminationStatus == 0 else {
                    throw StateletUpdaterError.invalidArtifact
                }
                let bundle = expanded.appendingPathComponent(
                    StateletIdentity.appBundleName,
                    isDirectory: true
                )
                let topLevel = try manager.contentsOfDirectory(
                    at: expanded,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
                guard topLevel.count == 1,
                      topLevel[0].lastPathComponent == StateletIdentity.appBundleName else {
                    throw StateletUpdaterError.invalidBundle
                }
                return StateletDownloadedUpdate(
                    artifactURL: downloaded.artifactURL,
                    bundleURL: bundle,
                    cleanupRootURL: downloaded.cleanupRootURL
                )
            } catch {
                try? manager.removeItem(at: expanded)
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            try await expansion.value
        } onCancel: {
            expansion.cancel()
        }
    }
}

private final class StateletUpdateDownloadProgressDelegate: NSObject,
    URLSessionDownloadDelegate,
    @unchecked Sendable {
    private let declaredSize: Int64
    private let progress: (Double) -> Void
    private let lock = NSLock()
    private var lastReportedProgress = 0.0

    init(declaredSize: Int64, progress: @escaping (Double) -> Void) {
        self.declaredSize = declaredSize
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expected = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite
            : declaredSize
        guard expected > 0 else { return }
        let fraction = min(max(Double(totalBytesWritten) / Double(expected), 0), 1)
        lock.lock()
        guard fraction > lastReportedProgress else {
            lock.unlock()
            return
        }
        lastReportedProgress = fraction
        lock.unlock()
        progress(fraction)
    }
}
