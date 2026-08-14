import CryptoKit
import Foundation
import XCTest
@testable import Statelet

final class StateletUpdaterTests: XCTestCase {
    func testSemanticVersionAndBuildComparison() throws {
        let release = try XCTUnwrap(StateletVersion(version: "1.8.0", build: "14"))
        let rebuild = try XCTUnwrap(StateletVersion(version: "1.8.0", build: "15"))
        let prerelease = try XCTUnwrap(StateletSemanticVersion("v2.0.0-beta.2"))
        let laterPrerelease = try XCTUnwrap(StateletSemanticVersion("2.0.0-beta.11"))
        let stable = try XCTUnwrap(StateletSemanticVersion("2.0.0"))

        XCTAssertLessThan(release, rebuild)
        XCTAssertLessThan(prerelease, laterPrerelease)
        XCTAssertLessThan(laterPrerelease, stable)
        XCTAssertNil(StateletSemanticVersion("1.02.0"))
        XCTAssertNil(StateletVersion(version: "1.0.0", build: "private"))
        XCTAssertEqual(
            StateletVersion(releaseTag: "v1.9.0+build.21")?.build,
            21
        )
        XCTAssertEqual(
            StateletVersion(releaseTag: "v1.9.0", releaseName: "Statelet 1.9.0 (22)")?.build,
            22
        )
        XCTAssertEqual(
            StateletVersion(releaseTag: "v1.9.3", releaseName: "Statelet 1.9.3")?.build,
            0
        )
    }

    func testReleaseFeedSelectsLatestStableTrustedZip() throws {
        let hash = String(repeating: "a", count: 64)
        let releases = try StateletReleaseFeed.decode(Data("""
        [
          {
            "tag_name":"v3.0.0","name":"Statelet 3.0.0","body":"draft",
            "draft":true,"prerelease":false,
            "html_url":"https://github.com/Coke1120/statelet-codex-pet-macos/releases/tag/v3.0.0",
            "published_at":"2026-08-14T10:00:00Z",
            "assets":[]
          },
          {
            "tag_name":"v2.1.0","name":"Statelet 2.1.0","body":"beta",
            "draft":false,"prerelease":true,
            "html_url":"https://github.com/Coke1120/statelet-codex-pet-macos/releases/tag/v2.1.0",
            "published_at":"2026-08-14T09:00:00Z",
            "assets":[]
          },
          {
            "tag_name":"v2.0.0+20","name":"Statelet 2.0.0 (20)","body":"Safe public notes.",
            "draft":false,"prerelease":false,
            "html_url":"https://github.com/Coke1120/statelet-codex-pet-macos/releases/tag/v2.0.0",
            "published_at":"2026-08-14T08:00:00.123Z",
            "assets":[
              {
                "name":"Statelet-macos-universal.zip",
                "browser_download_url":"https://github.com/assets/statelet.zip",
                "size":123,"content_type":"application/zip","digest":"sha256:\(hash)"
              },
              {
                "name":"Statelet-macos-arm64.zip",
                "browser_download_url":"https://github.com/assets/statelet-arm64.zip",
                "size":100,"content_type":"application/zip","digest":"sha256:\(hash)"
              }
            ]
          }
        ]
        """.utf8))
        let installed = try XCTUnwrap(StateletVersion(version: "1.7.1", build: "13"))

        let candidate = try XCTUnwrap(
            StateletReleaseFeed.selectCandidate(from: releases, newerThan: installed)
        )
        XCTAssertEqual(candidate.version, StateletVersion(version: "2.0.0", build: "20"))
        XCTAssertEqual(candidate.packageAsset.name, "Statelet-macos-universal.zip")
        XCTAssertEqual(candidate.releaseNotes, "Safe public notes.")
    }

    func testReleaseFeedRejectsMalformedJSONAndPackageWithoutChecksum() throws {
        XCTAssertThrowsError(try StateletReleaseFeed.decode(Data("private path".utf8))) {
            XCTAssertEqual($0 as? StateletUpdaterError, .invalidReleaseFeed)
        }
        let releases = try StateletReleaseFeed.decode(Data("""
        [{
          "tag_name":"v2.0.0","name":null,"body":null,"draft":false,"prerelease":false,
          "html_url":"https://example.com/release","published_at":null,
          "assets":[{
            "name":"Statelet.zip","browser_download_url":"https://example.com/Statelet.zip",
            "size":10,"content_type":"application/zip","digest":null
          }]
        }]
        """.utf8))
        let installed = try XCTUnwrap(StateletVersion(version: "1.0.0", build: "1"))
        XCTAssertNil(StateletReleaseFeed.selectCandidate(from: releases, newerThan: installed))
    }

    func testChecksumParsingAndArtifactVerificationFailClosed() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifact = directory.appendingPathComponent("Statelet.zip")
        let payload = Data("verified artifact".utf8)
        try payload.write(to: artifact)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let package = try releaseAsset(
            name: "Statelet.zip",
            size: Int64(payload.count),
            digest: nil
        )
        let checksum = Data("\(digest)  Statelet.zip\n".utf8)

        XCTAssertEqual(
            try StateletArtifactVerifier.expectedSHA256(for: package, checksumData: checksum),
            digest
        )
        XCTAssertNoThrow(
            try StateletArtifactVerifier.verifyFile(
                at: artifact,
                expectedSize: Int64(payload.count),
                expectedSHA256: digest
            )
        )
        XCTAssertThrowsError(
            try StateletArtifactVerifier.verifyFile(
                at: artifact,
                expectedSize: Int64(payload.count + 1),
                expectedSHA256: digest
            )
        ) { XCTAssertEqual($0 as? StateletUpdaterError, .artifactSizeMismatch) }
        XCTAssertThrowsError(
            try StateletArtifactVerifier.verifyFile(
                at: artifact,
                expectedSize: Int64(payload.count),
                expectedSHA256: String(repeating: "0", count: 64)
            )
        ) { XCTAssertEqual($0 as? StateletUpdaterError, .artifactHashMismatch) }
    }

    func testManagedBundleValidationChecksCanonicalIdentityAndExecutable() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try makeBundle(in: directory, identifier: StateletIdentity.bundleIdentifier)

        let metadata = try StateletBundleValidator.validate(
            at: bundle,
            requireTrustedSignature: false
        )
        XCTAssertEqual(metadata.version, StateletVersion(version: "2.0.0", build: "20"))

        let invalidBundle = try makeBundle(in: directory, name: "Unmanaged.app", identifier: "example.unmanaged")
        XCTAssertThrowsError(
            try StateletBundleValidator.validate(at: invalidBundle, requireTrustedSignature: false)
        ) { XCTAssertEqual($0 as? StateletUpdaterError, .invalidBundleIdentity) }
        XCTAssertThrowsError(try StateletBundleValidator.validate(at: bundle)) {
            XCTAssertEqual($0 as? StateletUpdaterError, .untrustedSignature)
        }
    }

    func testTransactionalInstallerRetainsJournalUntilNextLaunchReconciles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let target = try makeBundle(in: applications, identifier: StateletIdentity.bundleIdentifier)
        let candidate = try makeBundle(in: staging, identifier: StateletIdentity.bundleIdentifier)
        try Data("candidate".utf8).write(to: candidate.appendingPathComponent("candidate.marker"))
        let oldVersion = try XCTUnwrap(StateletVersion(version: "1.0.0", build: "1"))
        let newVersion = try XCTUnwrap(StateletVersion(version: "2.0.0", build: "20"))
        let downloaded = StateletDownloadedUpdate(artifactURL: staging.appendingPathComponent("update.zip"), bundleURL: candidate)
        let validate: StateletUpdateInstaller.BundleValidation = { _, trusted in
            StateletBundleMetadata(version: trusted ? newVersion : oldVersion, minimumSystemVersion: nil)
        }

        try StateletUpdateInstaller.install(
            downloaded,
            targetURL: target,
            validateBundle: validate
        )
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("candidate.marker")), "candidate")
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil)
                .contains { $0.lastPathComponent.hasPrefix(".statelet-update-") }
        )

        try StateletUpdateInstaller.reconcilePendingTransaction(
            targetURL: target,
            validateBundle: validate
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil)
                .contains { $0.lastPathComponent.hasPrefix(".statelet-update-") }
        )
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("candidate.marker")), "candidate")
    }

    func testTransactionalInstallerRestoresPreviousBundleWhenPostPublishValidationFails() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let target = try makeBundle(in: applications, identifier: StateletIdentity.bundleIdentifier)
        let candidate = try makeBundle(in: staging, identifier: StateletIdentity.bundleIdentifier)
        try Data("old".utf8).write(to: target.appendingPathComponent("version.marker"))
        try Data("candidate".utf8).write(to: candidate.appendingPathComponent("version.marker"))
        let oldVersion = try XCTUnwrap(StateletVersion(version: "1.0.0", build: "1"))
        let newVersion = try XCTUnwrap(StateletVersion(version: "2.0.0", build: "20"))
        let downloaded = StateletDownloadedUpdate(artifactURL: staging.appendingPathComponent("update.zip"), bundleURL: candidate)
        var validationCount = 0
        let validate: StateletUpdateInstaller.BundleValidation = { _, trusted in
            validationCount += 1
            if trusted, validationCount == 3 { throw StateletUpdaterError.untrustedSignature }
            return StateletBundleMetadata(version: trusted ? newVersion : oldVersion, minimumSystemVersion: nil)
        }

        XCTAssertThrowsError(
            try StateletUpdateInstaller.install(
                downloaded,
                targetURL: target,
                validateBundle: validate
            )
        ) { XCTAssertEqual($0 as? StateletUpdaterError, .untrustedSignature) }
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("version.marker")), "old")
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil)
                .contains { $0.lastPathComponent.hasPrefix(".statelet-update-") }
        )
    }

    func testAutomaticCheckPolicyUsesLaunchAndTwentyFourHourBoundary() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertTrue(StateletUpdatePolicy.shouldCheckAutomatically(now: now, lastCheck: nil))
        XCTAssertFalse(StateletUpdatePolicy.shouldCheckAutomatically(
            now: now,
            lastCheck: now.addingTimeInterval(-StateletUpdatePolicy.checkInterval + 1)
        ))
        XCTAssertTrue(StateletUpdatePolicy.shouldCheckAutomatically(
            now: now,
            lastCheck: now.addingTimeInterval(-StateletUpdatePolicy.checkInterval)
        ))
    }

    @MainActor
    func testCoordinatorCoalescesChecksAndKeepsUnderlyingErrorsPrivate() async throws {
        let suite = "StateletUpdaterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let completed = expectation(description: "completed")
        let fetchCounter = FetchCounter()
        let coordinator = StateletUpdateCoordinator(
            installedVersion: try XCTUnwrap(StateletVersion(version: "1.0.0", build: "1")),
            defaults: defaults,
            fetchReleases: {
                await fetchCounter.increment()
                try await Task.sleep(nanoseconds: 50_000_000)
                throw NSError(
                    domain: "test",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "/private/checkout/token.txt"]
                )
            },
            fetchAssetData: { _ in Data() },
            download: { _, _ in throw StateletUpdaterError.invalidArtifact },
            installer: { _, _ in }
        )
        coordinator.onSnapshot = { snapshot in
            if snapshot.status.contains("keep running normally") { completed.fulfill() }
        }

        coordinator.checkNow()
        coordinator.checkNow()
        await fulfillment(of: [completed], timeout: 2)
        let finalFetchCount = await fetchCounter.value
        XCTAssertEqual(finalFetchCount, 1)
        XCTAssertFalse(coordinator.snapshot.status.contains("private"))
        XCTAssertFalse(coordinator.snapshot.status.contains("token"))
    }

    @MainActor
    func testCoordinatorReportsOfflineWithoutChangingInstalledState() async throws {
        let suite = "StateletUpdaterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let offline = expectation(description: "offline")
        let installed = try XCTUnwrap(StateletVersion(version: "1.0.0", build: "1"))
        let coordinator = StateletUpdateCoordinator(
            installedVersion: installed,
            defaults: defaults,
            fetchReleases: { throw URLError(.notConnectedToInternet) },
            fetchAssetData: { _ in Data() },
            download: { _, _ in throw StateletUpdaterError.invalidArtifact },
            installer: { _, _ in }
        )
        coordinator.onSnapshot = { snapshot in
            if snapshot.status.localizedCaseInsensitiveContains("offline") { offline.fulfill() }
        }

        coordinator.checkNow()
        await fulfillment(of: [offline], timeout: 2)
        XCTAssertEqual(coordinator.snapshot.installedVersion, installed.description)
        XCTAssertFalse(coordinator.snapshot.isChecking)
    }

    @MainActor
    func testCoordinatorVerifiesStagesAndRequiresSafeInstallBoundary() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifact = directory.appendingPathComponent("Statelet.zip")
        let payload = Data("signed-update-archive".utf8)
        try payload.write(to: artifact)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let bundle = directory.appendingPathComponent("Statelet.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let feed = releaseFeedJSON(size: payload.count, digest: digest)
        let suite = "StateletUpdaterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ready = expectation(description: "ready")
        let safeBoundary = expectation(description: "safe boundary retained")
        let installed = expectation(description: "installed at safe boundary")
        var installCount = 0
        var safeToInstall = false
        var safeBoundaryFulfilled = false
        let candidateVersion = try XCTUnwrap(StateletVersion(version: "2.0.0", build: "20"))
        let coordinator = StateletUpdateCoordinator(
            installedVersion: try XCTUnwrap(StateletVersion(version: "1.0.0", build: "1")),
            defaults: defaults,
            fetchReleases: { feed },
            fetchAssetData: { _ in Data() },
            download: { _, progress in
                progress(0.5)
                return StateletDownloadedUpdate(artifactURL: artifact, bundleURL: bundle)
            },
            installer: { _, _ in
                installCount += 1
                installed.fulfill()
            },
            isSafeToInstall: { safeToInstall },
            validateBundle: { _ in
                StateletBundleMetadata(version: candidateVersion, minimumSystemVersion: nil)
            }
        )
        coordinator.onSnapshot = { snapshot in
            if snapshot.status == "Update verified and ready to install." { ready.fulfill() }
            if snapshot.status.contains("safe restart"), !safeBoundaryFulfilled {
                safeBoundaryFulfilled = true
                safeBoundary.fulfill()
            }
        }

        coordinator.checkNow()
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertTrue(coordinator.snapshot.isReadyToInstall)
        XCTAssertEqual(coordinator.snapshot.progress, 1)
        coordinator.installReadyUpdate()
        await fulfillment(of: [safeBoundary], timeout: 2)
        XCTAssertEqual(installCount, 0)
        XCTAssertTrue(coordinator.snapshot.isReadyToInstall)
        coordinator.setAutomaticInstall(true)
        await Task.yield()
        safeToInstall = true
        coordinator.retryAutomaticInstallIfNeeded()
        await fulfillment(of: [installed], timeout: 2)
        XCTAssertEqual(installCount, 1)
    }

    @MainActor
    func testAutomaticInstallIsPersistedOptIn() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifact = directory.appendingPathComponent("Statelet.zip")
        let payload = Data("auto-install-archive".utf8)
        try payload.write(to: artifact)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let bundle = directory.appendingPathComponent("Statelet.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let suite = "StateletUpdaterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let installed = expectation(description: "installed")
        let candidateVersion = try XCTUnwrap(StateletVersion(version: "2.0.0", build: "20"))
        let coordinator = StateletUpdateCoordinator(
            installedVersion: try XCTUnwrap(StateletVersion(version: "1.0.0", build: "1")),
            defaults: defaults,
            fetchReleases: { self.releaseFeedJSON(size: payload.count, digest: digest) },
            fetchAssetData: { _ in Data() },
            download: { _, _ in StateletDownloadedUpdate(artifactURL: artifact, bundleURL: bundle) },
            installer: { _, _ in installed.fulfill() },
            isSafeToInstall: { true },
            validateBundle: { _ in
                StateletBundleMetadata(version: candidateVersion, minimumSystemVersion: nil)
            }
        )
        coordinator.setAutomaticInstall(true)
        XCTAssertTrue(defaults.bool(forKey: "StateletUpdater.automaticInstall.v1"))
        coordinator.checkNow()
        await fulfillment(of: [installed], timeout: 2)
        XCTAssertEqual(coordinator.snapshot.status, "Update installed. Restart Statelet to finish.")
    }

    private func releaseAsset(name: String, size: Int64, digest: String?) throws -> StateletReleaseAsset {
        let digestValue = digest.map { "\"sha256:\($0)\"" } ?? "null"
        let data = Data("""
        {
          "name":"\(name)","browser_download_url":"https://example.com/\(name)",
          "size":\(size),"content_type":"application/zip","digest":\(digestValue)
        }
        """.utf8)
        return try JSONDecoder().decode(StateletReleaseAsset.self, from: data)
    }

    private func releaseFeedJSON(size: Int, digest: String) -> Data {
        Data("""
        [{
          "tag_name":"v2.0.0+20","name":"Statelet 2.0.0 (20)","body":"Release notes",
          "draft":false,"prerelease":false,
          "html_url":"https://github.com/Coke1120/statelet-codex-pet-macos/releases/tag/v2.0.0",
          "published_at":"2026-08-14T08:00:00Z",
          "assets":[{
            "name":"Statelet-macos-universal.zip",
            "browser_download_url":"https://github.com/assets/Statelet.zip",
            "size":\(size),"content_type":"application/zip","digest":"sha256:\(digest)"
          }]
        }]
        """.utf8)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-updater-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeBundle(
        in directory: URL,
        name: String = "Statelet.app",
        identifier: String
    ) throws -> URL {
        let bundle = directory.appendingPathComponent(name, isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent(StateletIdentity.executableName)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": StateletIdentity.executableName,
            "CFBundleShortVersionString": "2.0.0",
            "CFBundleVersion": "20",
            "LSMinimumSystemVersion": "13.0",
            StateletIdentity.appManagedPlistKey: StateletIdentity.managedMarker,
        ]
        let plist = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        return bundle
    }
}

private actor FetchCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
