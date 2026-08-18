import AppKit
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

final class CodexDesktopActivator {
    typealias ApplicationResolver = (URL) -> URL?
    typealias ApplicationTrustResolver = (URL) -> Bool
    typealias Opener = (URL, URL) -> Void

    private let applicationResolver: ApplicationResolver
    private let applicationTrustResolver: ApplicationTrustResolver
    private let opener: Opener

    init(
        applicationResolver: @escaping ApplicationResolver = { NSWorkspace.shared.urlForApplication(toOpen: $0) },
        applicationTrustResolver: @escaping ApplicationTrustResolver = {
            CodexDesktopActivationPolicy.isTrustedApplication(at: $0)
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
        self.applicationTrustResolver = applicationTrustResolver
        self.opener = opener
    }

    func canOpen(threadID: String) -> Bool {
        guard let deepLink = CodexDesktopActivationPolicy.deepLink(for: threadID),
              let applicationURL = applicationResolver(deepLink) else { return false }
        return applicationTrustResolver(applicationURL)
    }

    @discardableResult
    func open(threadID: String) -> Bool {
        guard let deepLink = CodexDesktopActivationPolicy.deepLink(for: threadID),
              let applicationURL = applicationResolver(deepLink),
              applicationTrustResolver(applicationURL) else {
            return false
        }
        opener(deepLink, applicationURL)
        return true
    }
}
