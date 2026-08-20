import AppKit
import CodexPetCore
import Foundation
import Security

enum CodexDesktopActivationPolicy {
    static let trustedBundleIdentifier = "com.openai.codex"
    static let trustedTeamIdentifier = "2DC432GLL2"
    static let maximumThreadIDBytes = 512

    static func isValidThreadID(_ threadID: String) -> Bool {
        let bytes = threadID.utf8.count
        return bytes > 0 && bytes <= maximumThreadIDBytes && threadID.unicodeScalars.allSatisfy {
            !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0)
        }
    }

    static func deepLink(for threadID: String) -> URL? {
        guard isValidThreadID(threadID) else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%?#")
        guard let encoded = threadID.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.percentEncodedPath = "/\(encoded)"
        return components.url
    }

    static func isTrustedApplication(at applicationURL: URL) -> Bool {
        guard applicationURL.isFileURL,
              Bundle(url: applicationURL)?.bundleIdentifier == trustedBundleIdentifier else {
            return false
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(applicationURL as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        var requirement: SecRequirement?
        let requirementText = "identifier \"\(trustedBundleIdentifier)\" and anchor apple generic"
        guard SecRequirementCreateWithString(
            requirementText as CFString,
            [],
            &requirement
        ) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(
                code,
                SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                requirement
              ) == errSecSuccess else { return false }
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

struct CodexDesktopApplicationIdentity: Hashable, Sendable {
    let bundleRevision: LocalFileRevision
    let executableRevision: LocalFileRevision
    let infoRevision: LocalFileRevision
    let codeResourcesRevision: LocalFileRevision

    static func resolve(at applicationURL: URL) -> CodexDesktopApplicationIdentity? {
        let bundleURL = applicationURL.resolvingSymlinksInPath().standardizedFileURL
        guard let bundle = Bundle(url: bundleURL),
              let executableURL = bundle.executableURL,
              let bundleRevision = LocalFileRevision(url: bundleURL),
              let executableRevision = LocalFileRevision(url: executableURL),
              let infoRevision = LocalFileRevision(
                  url: bundleURL.appendingPathComponent("Contents/Info.plist")
              ),
              let codeResourcesRevision = LocalFileRevision(
                  url: bundleURL.appendingPathComponent("Contents/_CodeSignature/CodeResources")
              ) else {
            return nil
        }
        return CodexDesktopApplicationIdentity(
            bundleRevision: bundleRevision,
            executableRevision: executableRevision,
            infoRevision: infoRevision,
            codeResourcesRevision: codeResourcesRevision
        )
    }
}

private actor CodexDesktopApplicationTrustCache {
    typealias TrustResolver = @Sendable (URL) -> Bool
    private static let untrustedCacheLifetime: TimeInterval = 30

    private let trustResolver: TrustResolver
    private var cachedIdentity: CodexDesktopApplicationIdentity?
    private var cachedResult: Bool?
    private var cachedAt: Date?

    init(trustResolver: @escaping TrustResolver) {
        self.trustResolver = trustResolver
    }

    func validate(
        applicationURL: URL,
        identity: CodexDesktopApplicationIdentity,
        force: Bool
    ) -> Bool {
        if !force, cachedIdentity == identity, let cachedResult, let cachedAt {
            if cachedResult || Date().timeIntervalSince(cachedAt) < Self.untrustedCacheLifetime {
                return cachedResult
            }
        }
        let result = trustResolver(applicationURL)
        cachedIdentity = identity
        cachedResult = result
        cachedAt = Date()
        return result
    }
}

final class CodexDesktopActivator {
    typealias ApplicationResolver = (URL) -> URL?
    typealias ApplicationTrustResolver = @Sendable (URL) -> Bool
    typealias ApplicationIdentityResolver = (URL) -> CodexDesktopApplicationIdentity?
    typealias Opener = (URL, URL) -> Void

    private let applicationResolver: ApplicationResolver
    private let applicationIdentityResolver: ApplicationIdentityResolver
    private let applicationTrustCache: CodexDesktopApplicationTrustCache
    private let opener: Opener

    init(
        applicationResolver: @escaping ApplicationResolver = { NSWorkspace.shared.urlForApplication(toOpen: $0) },
        applicationTrustResolver: @escaping ApplicationTrustResolver = {
            CodexDesktopActivationPolicy.isTrustedApplication(at: $0)
        },
        applicationIdentityResolver: @escaping ApplicationIdentityResolver = {
            CodexDesktopApplicationIdentity.resolve(at: $0)
        },
        opener: @escaping Opener = { deepLink, applicationURL in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(
                [deepLink],
                withApplicationAt: applicationURL,
                configuration: configuration
            )
        }
    ) {
        self.applicationResolver = applicationResolver
        self.applicationIdentityResolver = applicationIdentityResolver
        self.applicationTrustCache = CodexDesktopApplicationTrustCache(
            trustResolver: applicationTrustResolver
        )
        self.opener = opener
    }

    @MainActor
    func openableIDs(for targets: [String: String]) async -> Set<String> {
        let validTargets = targets.compactMap { id, threadID -> (String, URL)? in
            guard let deepLink = CodexDesktopActivationPolicy.deepLink(for: threadID) else {
                return nil
            }
            return (id, deepLink)
        }
        guard let firstDeepLink = validTargets.first?.1,
              let applicationURL = applicationResolver(firstDeepLink),
              let identity = applicationIdentityResolver(applicationURL),
              await applicationTrustCache.validate(
                  applicationURL: applicationURL,
                  identity: identity,
                  force: false
              ),
              applicationIdentityResolver(applicationURL) == identity else {
            return []
        }
        // Every target uses the same validated `codex:` handler. Thread IDs are
        // still validated individually before their activity rows become links.
        return Set(validTargets.map(\.0))
    }

    @discardableResult
    @MainActor
    func open(threadID: String) async -> Bool {
        guard let deepLink = CodexDesktopActivationPolicy.deepLink(for: threadID),
              let applicationURL = applicationResolver(deepLink),
              let identity = applicationIdentityResolver(applicationURL),
              await applicationTrustCache.validate(
                  applicationURL: applicationURL,
                  identity: identity,
                  force: true
              ),
              !Task.isCancelled,
              applicationIdentityResolver(applicationURL) == identity else {
            return false
        }
        opener(deepLink, applicationURL)
        return true
    }
}
