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
    let releaseTag: String
    let releaseNotes: String
    let releasePageURL: URL
    let packageAsset: StateletReleaseAsset
    let manifestAsset: StateletReleaseAsset
    let signatureAsset: StateletReleaseAsset
    let checksumAsset: StateletReleaseAsset?
}

enum StateletReleaseFeed {
    static let repository = "Coke1120/statelet-codex-pet-macos"
    static let repositoryID: Int64 = 1_329_561_047
    static let releaseSigningPublicKeyBase64 = "AXJpDm8ZsTUvMGS7dzbiNxBIGwehb+ern2ietCTAgIg="
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
            guard let manifest = selectNamedAsset(
                "\(package.name).manifest.json",
                from: release.assets,
                maximumSize: Int64(StateletSignedReleaseManifest.maximumByteCount)
            ), let signature = selectNamedAsset(
                "\(package.name).manifest.sig",
                from: release.assets,
                maximumSize: Int64(StateletSignedReleaseManifest.signatureMaximumByteCount)
            ) else { return nil }
            let checksum = selectChecksum(for: package, from: release.assets)
            return StateletUpdateCandidate(
                version: version,
                releaseTag: release.tagName,
                releaseNotes: sanitizedNotes(release.body),
                releasePageURL: release.htmlURL,
                packageAsset: package,
                manifestAsset: manifest,
                signatureAsset: signature,
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

    private static func selectNamedAsset(
        _ name: String,
        from assets: [StateletReleaseAsset],
        maximumSize: Int64
    ) -> StateletReleaseAsset? {
        assets.first {
            $0.name == name
                && $0.browserDownloadURL.scheme?.lowercased() == "https"
                && $0.size > 0
                && $0.size <= maximumSize
        }
    }

    private static func sanitizedNotes(_ value: String?) -> String {
        let notes = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return notes.isEmpty ? "See the release page for details." : String(notes.prefix(20_000))
    }
}

struct StateletSignedReleaseManifest: Decodable, Equatable {
    let schemaVersion: Int
    let repository: String
    let repositoryID: Int64
    let ref: String
    let commitSHA: String
    let version: String
    let build: Int
    let assetName: String
    let assetSize: Int64
    let assetSHA256: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case repository
        case repositoryID = "repository_id"
        case ref
        case commitSHA = "commit_sha"
        case version
        case build
        case assetName = "asset_name"
        case assetSize = "asset_size"
        case assetSHA256 = "asset_sha256"
    }

    static let maximumByteCount = 64 * 1024
    static let signatureMaximumByteCount = 1024

    static func decodeStrict(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumByteCount,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == Set(CodingKeys.allCases.map(\.stringValue)),
              let manifest = try? JSONDecoder().decode(Self.self, from: data) else {
            throw StateletUpdaterError.invalidReleaseProvenance
        }
        return manifest
    }
}

struct StateletReleaseArtifactAuthority: Equatable {
    let expectedSize: Int64
    let expectedSHA256: String
}

enum StateletReleaseProvenance {
    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (97 ... 102).contains($0)
        }
    }

    static func verify(
        candidate: StateletUpdateCandidate,
        manifestData: Data,
        signatureData: Data,
        publicKeyBase64: String = StateletReleaseFeed.releaseSigningPublicKeyBase64
    ) throws -> StateletReleaseArtifactAuthority {
        let manifest = try StateletSignedReleaseManifest.decodeStrict(manifestData)
        guard signatureData.count <= StateletSignedReleaseManifest.signatureMaximumByteCount,
              let signatureText = String(data: signatureData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let signature = Data(base64Encoded: signatureText),
              signature.count == 64,
              let publicKeyData = Data(base64Encoded: publicKeyBase64),
              publicKeyData.count == 32,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
              publicKey.isValidSignature(signature, for: manifestData) else {
            throw StateletUpdaterError.invalidReleaseProvenance
        }
        let canonicalVersion = StateletSemanticVersion(manifest.version)
        guard manifest.schemaVersion == 1,
              manifest.repository == StateletReleaseFeed.repository,
              manifest.repositoryID == StateletReleaseFeed.repositoryID,
              manifest.ref == "refs/tags/\(candidate.releaseTag)",
              isLowercaseHex(manifest.commitSHA, count: 40),
              let canonicalVersion,
              canonicalVersion.description == manifest.version,
              canonicalVersion == candidate.version.semantic,
              manifest.build >= 0,
              manifest.build == candidate.version.build,
              manifest.assetName == candidate.packageAsset.name,
              manifest.assetSize > 0,
              manifest.assetSize == candidate.packageAsset.size,
              isLowercaseHex(manifest.assetSHA256, count: 64) else {
            throw StateletUpdaterError.invalidReleaseProvenance
        }
        if let githubDigest = candidate.packageAsset.sha256Digest,
           githubDigest != manifest.assetSHA256 {
            throw StateletUpdaterError.invalidReleaseProvenance
        }
        return StateletReleaseArtifactAuthority(
            expectedSize: manifest.assetSize,
            expectedSHA256: manifest.assetSHA256
        )
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
        if requireTrustedSignature {
            try validateSignature(at: bundleURL)
            try validateArchitecture(at: bundleURL)
        }

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
        let configuredTeamIdentifier = Bundle.main.object(
            forInfoDictionaryKey: StateletIdentity.updateSigningTeamIdentifierKey
        ) as? String
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else {
            throw StateletUpdaterError.untrustedSignature
        }
        var requirement: SecRequirement?
        let hasConfiguredTeam = configuredTeamIdentifier?.utf8.count == 10
            && configuredTeamIdentifier?.utf8.allSatisfy({
                (48 ... 57).contains($0) || (65 ... 90).contains($0)
            }) == true
        let requirementText = hasConfiguredTeam
            ? "identifier \"\(StateletIdentity.bundleIdentifier)\" and anchor apple generic"
            : "identifier \"\(StateletIdentity.bundleIdentifier)\""
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(
                code,
                SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                requirement
              ) == errSecSuccess else {
            throw StateletUpdaterError.untrustedSignature
        }
        guard hasConfiguredTeam, let authorizedTeamIdentifier = configuredTeamIdentifier else {
            return
        }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInformation) == errSecSuccess,
              let information = signingInformation as? [String: Any],
              information[kSecCodeInfoTeamIdentifier as String] as? String == authorizedTeamIdentifier,
              let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate],
              !certificates.isEmpty else {
            throw StateletUpdaterError.untrustedSignature
        }
        try validateGatekeeper(at: bundleURL)
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
    }

    private static func validateGatekeeper(at bundleURL: URL) throws {
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

final class StateletUpdateDetachedActivityTracker: @unchecked Sendable {
    private let condition = NSCondition()
    private var activeCount = 0
    private var terminating = false
    private var ownedUpdates: [String: StateletDownloadedUpdate] = [:]

    func begin(owning update: StateletDownloadedUpdate? = nil) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !terminating else { return false }
        if let update, let key = ownershipKey(for: update) {
            ownedUpdates[key] = update
        }
        activeCount += 1
        return true
    }

    func finish() {
        condition.lock()
        activeCount -= 1
        if activeCount == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }

    func track(_ update: StateletDownloadedUpdate) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !terminating else { return false }
        if let key = ownershipKey(for: update) {
            ownedUpdates[key] = update
        }
        return true
    }

    func release(_ update: StateletDownloadedUpdate) {
        guard let key = ownershipKey(for: update) else { return }
        condition.lock()
        ownedUpdates.removeValue(forKey: key)
        condition.unlock()
    }

    func beginTermination() {
        condition.lock()
        terminating = true
        condition.unlock()
    }

    func waitForQuiescence(timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: max(0, timeout))
        condition.lock()
        defer { condition.unlock() }
        while activeCount > 0 {
            if !condition.wait(until: deadline), activeCount > 0 {
                return false
            }
        }
        return true
    }

    func takeOwnedUpdates() -> [StateletDownloadedUpdate] {
        condition.lock()
        defer { condition.unlock() }
        let updates = Array(ownedUpdates.values)
        ownedUpdates.removeAll()
        return updates
    }

    private func ownershipKey(for update: StateletDownloadedUpdate) -> String? {
        update.cleanupRootURL?.standardizedFileURL.path
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
    case invalidReleaseProvenance
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
        case .invalidReleaseProvenance: return "The update release authorization could not be verified."
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
    typealias ProvenanceVerifier = (
        StateletUpdateCandidate,
        Data,
        Data
    ) throws -> StateletReleaseArtifactAuthority

    var onSnapshot: ((StateletUpdateSnapshot) -> Void)? {
        didSet { onSnapshot?(snapshot) }
    }
    var onRelaunchRequested: (() -> Bool)?
    var onTerminationRequested: (() -> Void)?

    private(set) var snapshot: StateletUpdateSnapshot
    private let installedVersion: StateletVersion
    private let defaults: UserDefaults
    private let lastCheckKey: String
    private let automaticInstallKey: String
    private let pendingInstallRetryKey: String
    private let now: () -> Date
    private let fetchReleases: ReleaseFetcher
    private let fetchAssetData: AssetDataFetcher
    private let verifyProvenance: ProvenanceVerifier
    private let download: Downloader
    private let prepareDownloadedUpdate: DownloadPreparation
    private let installer: Installer
    private let validateBundle: BundleValidation
    private let detachedActivities: StateletUpdateDetachedActivityTracker
    private var operation: Task<Void, Never>?
    private var readyUpdate: (StateletDownloadedUpdate, StateletUpdateCandidate)?
    private var downloadProgressToken: UUID?
    private var isTerminating = false
    private var isRelaunchRequestPending = false

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
        let detachedActivities = StateletUpdateDetachedActivityTracker()
        self.init(
            installedVersion: .current(bundle: bundle),
            defaults: defaults,
            fetchReleases: {
                return try await Self.fetchHTTPSData(
                    from: StateletReleaseFeed.releasesURL,
                    maximumSize: 2 * 1_048_576
                )
            },
            fetchAssetData: { asset in
                let maximumSize = asset.name.hasSuffix(".manifest.sig")
                    ? StateletSignedReleaseManifest.signatureMaximumByteCount
                    : StateletSignedReleaseManifest.maximumByteCount
                return try await Self.fetchHTTPSData(
                    from: asset.browserDownloadURL,
                    maximumSize: maximumSize
                )
            },
            verifyProvenance: { candidate, manifest, signature in
                try StateletReleaseProvenance.verify(
                    candidate: candidate,
                    manifestData: manifest,
                    signatureData: signature
                )
            },
            download: { asset, progress in
                try await Self.downloadArtifact(
                    asset: asset,
                    progress: progress,
                    detachedActivities: detachedActivities
                )
            },
            prepareDownloadedUpdate: { downloaded in
                try await Self.expandDownloadedUpdate(
                    downloaded,
                    detachedActivities: detachedActivities
                )
            },
            installer: resolvedInstaller,
            validateBundle: { url in
                try await Self.validateBundleOffMain(
                    url,
                    detachedActivities: detachedActivities
                )
            },
            detachedActivities: detachedActivities
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
        verifyProvenance: @escaping ProvenanceVerifier,
        download: @escaping Downloader,
        prepareDownloadedUpdate: @escaping DownloadPreparation = { $0 },
        installer: @escaping Installer,
        validateBundle: BundleValidation? = nil,
        detachedActivities: StateletUpdateDetachedActivityTracker = .init()
    ) {
        self.installedVersion = installedVersion
        self.defaults = defaults
        self.lastCheckKey = lastCheckKey
        self.automaticInstallKey = automaticInstallKey
        self.pendingInstallRetryKey = pendingInstallRetryKey
        self.now = now
        self.fetchReleases = fetchReleases
        self.fetchAssetData = fetchAssetData
        self.verifyProvenance = verifyProvenance
        self.download = download
        self.prepareDownloadedUpdate = prepareDownloadedUpdate
        self.installer = installer
        self.validateBundle = validateBundle ?? { url in
            try await StateletUpdateCoordinator.validateBundleOffMain(
                url,
                detachedActivities: detachedActivities
            )
        }
        self.detachedActivities = detachedActivities
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
        Task { @MainActor [weak self] in
            guard let self,
                  !self.isRelaunchRequestPending,
                  self.readyUpdate != nil else { return }
            self.isRelaunchRequestPending = true
            guard self.onRelaunchRequested?() == true else {
                _ = self.scheduleReadyInstall(
                    status: "Statelet could not restart automatically. Quit and reopen it to install the update."
                )
                return
            }
            guard self.scheduleReadyInstall(
                status: "Restarting Statelet to install the update…"
            ) else { return }
            self.onTerminationRequested?()
        }
    }

    @MainActor
    @discardableResult
    private func scheduleReadyInstall(
        status: String = "Update scheduled for the next Statelet restart."
    ) -> Bool {
        guard let readyUpdate else { return false }
        publish(
            status: status,
            candidate: readyUpdate.1,
            progress: 1,
            isScheduled: true
        )
        return true
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
        isRelaunchRequestPending = false
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
        isRelaunchRequestPending = false
    }

    @MainActor
    @discardableResult
    func shutdownAndWaitForQuiescence(timeout: TimeInterval = 5) -> Bool {
        isTerminating = true
        detachedActivities.beginTermination()
        let hadInFlightOperation = operation != nil
        operation?.cancel()
        operation = nil
        downloadProgressToken = nil
        let detachedWorkQuiescent = detachedActivities.waitForQuiescence(timeout: timeout)
        for update in detachedActivities.takeOwnedUpdates() {
            update.removeOwnedStaging()
        }
        return !hadInFlightOperation && detachedWorkQuiescent
    }

    func cancel() {
        defaults.removeObject(forKey: pendingInstallRetryKey)
        Task { @MainActor [weak self] in self?.operation?.cancel() }
    }

    @MainActor
    private func beginCheck() {
        guard !isTerminating,
              operation == nil,
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
                status: "Verifying release authorization…",
                candidate: candidate,
                progress: 0,
                isChecking: true
            )
            let manifestData = try await fetchAssetData(candidate.manifestAsset)
            try Task.checkCancellation()
            let signatureData = try await fetchAssetData(candidate.signatureAsset)
            try Task.checkCancellation()
            let authority = try verifyProvenance(
                candidate,
                manifestData,
                signatureData
            )
            publish(
                status: "Downloading update…",
                candidate: candidate,
                progress: 0,
                isChecking: true
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
            guard detachedActivities.track(downloaded) else {
                downloaded.removeOwnedStaging()
                throw CancellationError()
            }
            stagingToCleanup = downloaded
            await Task.yield()
            downloadProgressToken = nil
            try Task.checkCancellation()
            try await Self.verifyArtifactOffMain(
                downloaded.artifactURL,
                expectedSize: authority.expectedSize,
                expectedSHA256: authority.expectedSHA256,
                detachedActivities: detachedActivities
            )
            let preparedUpdate = try await prepareDownloadedUpdate(downloaded)
            detachedActivities.release(downloaded)
            guard detachedActivities.track(preparedUpdate) else {
                preparedUpdate.removeOwnedStaging()
                throw CancellationError()
            }
            stagingToCleanup = preparedUpdate
            try Task.checkCancellation()
            let metadata = try await validateBundle(preparedUpdate.bundleURL)
            try Task.checkCancellation()
            guard metadata.version > installedVersion,
                  metadata.version.semantic == candidate.version.semantic,
                  candidate.version.build == 0 || metadata.version.build == candidate.version.build else {
                throw StateletUpdaterError.versionMismatch
            }
            detachedActivities.release(preparedUpdate)
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
            await Self.removeOwnedStagingOffMain(
                stagingToCleanup,
                detachedActivities: detachedActivities
            )
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
        expectedSHA256: String,
        detachedActivities: StateletUpdateDetachedActivityTracker
    ) async throws {
        guard detachedActivities.begin() else { throw CancellationError() }
        let verification = Task.detached(priority: .utility) {
            defer { detachedActivities.finish() }
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

    private static func validateBundleOffMain(
        _ url: URL,
        detachedActivities: StateletUpdateDetachedActivityTracker
    ) async throws -> StateletBundleMetadata {
        guard detachedActivities.begin() else { throw CancellationError() }
        let validation = Task.detached(priority: .utility) {
            defer { detachedActivities.finish() }
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

    private static func removeOwnedStagingOffMain(
        _ update: StateletDownloadedUpdate,
        detachedActivities: StateletUpdateDetachedActivityTracker
    ) async {
        guard detachedActivities.begin() else {
            update.removeOwnedStaging()
            detachedActivities.release(update)
            return
        }
        await Task.detached(priority: .utility) {
            defer { detachedActivities.finish() }
            update.removeOwnedStaging()
            detachedActivities.release(update)
        }.value
    }

    private static func downloadArtifact(
        asset: StateletReleaseAsset,
        progress: @escaping (Double) -> Void,
        detachedActivities: StateletUpdateDetachedActivityTracker
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
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("StateletUpdates", isDirectory: true)
        let staging = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let artifact = staging.appendingPathComponent("Statelet-update.zip")
        let trackedUpdate = StateletDownloadedUpdate(
            artifactURL: artifact,
            bundleURL: artifact,
            cleanupRootURL: staging
        )
        guard detachedActivities.begin(owning: trackedUpdate) else {
            throw CancellationError()
        }
        let finalization = Task.detached(priority: .utility) {
            defer { detachedActivities.finish() }
            try Task.checkCancellation()
            let manager = FileManager.default
            do {
                try manager.createDirectory(at: base, withIntermediateDirectories: true)
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
                try manager.createDirectory(at: staging, withIntermediateDirectories: false)
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
                try Task.checkCancellation()
                try manager.moveItem(at: temporaryURL, to: artifact)
                try Task.checkCancellation()
                return trackedUpdate
            } catch {
                try? manager.removeItem(at: staging)
                detachedActivities.release(trackedUpdate)
                throw error
            }
        }
        let result: StateletDownloadedUpdate
        do {
            result = try await withTaskCancellationHandler {
                try await finalization.value
            } onCancel: {
                finalization.cancel()
            }
            try Task.checkCancellation()
        } catch {
            trackedUpdate.removeOwnedStaging()
            detachedActivities.release(trackedUpdate)
            throw error
        }
        progress(1)
        return result
    }

    private static func expandDownloadedUpdate(
        _ downloaded: StateletDownloadedUpdate,
        detachedActivities: StateletUpdateDetachedActivityTracker
    ) async throws -> StateletDownloadedUpdate {
        guard detachedActivities.begin() else { throw CancellationError() }
        let expansion = Task.detached(priority: .utility) {
            defer { detachedActivities.finish() }
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
