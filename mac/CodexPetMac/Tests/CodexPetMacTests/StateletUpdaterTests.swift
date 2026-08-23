import CryptoKit
import Foundation
import XCTest
@testable import Statelet

final class StateletUpdaterTests: XCTestCase {
    func testPinnedReleaseAuthorityIsImmutableRepositoryAndProductionKey() {
        XCTAssertEqual(StateletReleaseFeed.repository, "Coke1120/statelet-codex-pet-macos")
        XCTAssertEqual(StateletReleaseFeed.repositoryID, 1_329_561_047)
        XCTAssertEqual(
            StateletReleaseFeed.releaseSigningPublicKeyBase64,
            "AXJpDm8ZsTUvMGS7dzbiNxBIGwehb+ern2ietCTAgIg="
        )
    }

    func testSignedReleaseManifestVerifiesRealEd25519Signature() throws {
        let hash = String(repeating: "a", count: 64)
        let candidate = try signedCandidate(size: 123, digest: hash)
        let key = Curve25519.Signing.PrivateKey()
        let manifest = try signedManifestData(candidate: candidate, sha256: hash)
        let signature = try key.signature(for: manifest).base64EncodedData()

        XCTAssertEqual(
            try StateletReleaseProvenance.verify(
                candidate: candidate,
                manifestData: manifest,
                signatureData: signature,
                publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString()
            ),
            StateletReleaseArtifactAuthority(expectedSize: 123, expectedSHA256: hash)
        )
    }

    func testSignedReleaseManifestRejectsTamperWrongAuthorityAndWrongSignature() throws {
        let hash = String(repeating: "a", count: 64)
        let candidate = try signedCandidate(size: 123, digest: hash)
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()

        let validManifest = try signedManifestData(candidate: candidate, sha256: hash)
        let validSignature = try key.signature(for: validManifest).base64EncodedData()
        var tampered = validManifest
        tampered.append(0x20)
        XCTAssertThrowsError(try StateletReleaseProvenance.verify(
            candidate: candidate,
            manifestData: tampered,
            signatureData: validSignature,
            publicKeyBase64: publicKey
        )) { XCTAssertEqual($0 as? StateletUpdaterError, .invalidReleaseProvenance) }

        let invalidAuthorities: [[String: Any]] = [
            ["repository": "attacker/statelet"],
            ["repository_id": StateletReleaseFeed.repositoryID + 1],
            ["ref": "refs/tags/v9.9.9"],
            ["commit_sha": String(repeating: "A", count: 40)],
            ["version": "2.0.1"],
            ["build": candidate.version.build + 1],
            ["asset_name": "Other.zip"],
            ["asset_size": candidate.packageAsset.size + 1],
            ["asset_sha256": String(repeating: "b", count: 64)],
        ]
        for override in invalidAuthorities {
            let manifest = try signedManifestData(
                candidate: candidate,
                sha256: hash,
                overrides: override
            )
            let signature = try key.signature(for: manifest).base64EncodedData()
            XCTAssertThrowsError(try StateletReleaseProvenance.verify(
                candidate: candidate,
                manifestData: manifest,
                signatureData: signature,
                publicKeyBase64: publicKey
            )) { XCTAssertEqual($0 as? StateletUpdaterError, .invalidReleaseProvenance) }
        }

        let extraFieldManifest = try signedManifestData(
            candidate: candidate,
            sha256: hash,
            overrides: ["unexpected": "field"]
        )
        let extraFieldSignature = try key.signature(for: extraFieldManifest).base64EncodedData()
        XCTAssertThrowsError(try StateletReleaseProvenance.verify(
            candidate: candidate,
            manifestData: extraFieldManifest,
            signatureData: extraFieldSignature,
            publicKeyBase64: publicKey
        )) { XCTAssertEqual($0 as? StateletUpdaterError, .invalidReleaseProvenance) }

        let wrongKey = Curve25519.Signing.PrivateKey()
        let wrongSignature = try wrongKey.signature(for: validManifest).base64EncodedData()
        XCTAssertThrowsError(try StateletReleaseProvenance.verify(
            candidate: candidate,
            manifestData: validManifest,
            signatureData: wrongSignature,
            publicKeyBase64: publicKey
        )) { XCTAssertEqual($0 as? StateletUpdaterError, .invalidReleaseProvenance) }
    }

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
              },
              {
                "name":"Statelet-macos-universal.zip.manifest.json",
                "browser_download_url":"https://github.com/assets/statelet.manifest.json",
                "size":512,"content_type":"application/json","digest":null
              },
              {
                "name":"Statelet-macos-universal.zip.manifest.sig",
                "browser_download_url":"https://github.com/assets/statelet.manifest.sig",
                "size":88,"content_type":"application/octet-stream","digest":null
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
        XCTAssertEqual(candidate.releaseTag, "v2.0.0+20")
        XCTAssertEqual(candidate.packageAsset.name, "Statelet-macos-universal.zip")
        XCTAssertEqual(candidate.releaseNotes, "Safe public notes.")
    }

    func testReleaseFeedRejectsMalformedJSONAndPackageWithoutSignedManifestAssets() throws {
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

    @MainActor
    func testCoordinatorVerifiesProvenanceBeforePackageDownload() async throws {
        let hash = String(repeating: "a", count: 64)
        let suite = "StateletUpdaterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rejected = expectation(description: "provenance rejected")
        var fetchedAssetNames = [String]()
        var downloadCalled = false
        let coordinator = StateletUpdateCoordinator(
            installedVersion: try XCTUnwrap(StateletVersion(version: "1.0.0", build: "1")),
            defaults: defaults,
            fetchReleases: { self.releaseFeedJSON(size: 123, digest: hash) },
            fetchAssetData: { asset in
                fetchedAssetNames.append(asset.name)
                return Data("bounded".utf8)
            },
            verifyProvenance: { _, _, _ in
                throw StateletUpdaterError.invalidReleaseProvenance
            },
            download: { _, _ in
                downloadCalled = true
                throw StateletUpdaterError.invalidArtifact
            },
            installer: { _, _ in }
        )
        coordinator.onSnapshot = { snapshot in
            if snapshot.status == StateletUpdaterError.invalidReleaseProvenance.safeStatus {
                rejected.fulfill()
            }
        }

        coordinator.checkNow()
        await fulfillment(of: [rejected], timeout: 2)
        XCTAssertEqual(fetchedAssetNames, [
            "Statelet-macos-universal.zip.manifest.json",
            "Statelet-macos-universal.zip.manifest.sig",
        ])
        XCTAssertFalse(downloadCalled)
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

    func testArtifactVerificationPreservesCancellation() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifact = directory.appendingPathComponent("Statelet.zip")
        let payload = Data("cancelled verification".utf8)
        try payload.write(to: artifact)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let gate = AsyncTestGate()
        let verification = Task {
            await gate.wait()
            try StateletArtifactVerifier.verifyFile(
                at: artifact,
                expectedSize: Int64(payload.count),
                expectedSHA256: digest
            )
        }

        verification.cancel()
        await gate.open()
        do {
            try await verification.value
            XCTFail("cancelled verification must not succeed")
        } catch is CancellationError {
            // Expected: cancellation is not rewritten as an artifact failure.
        }
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

        let missingCompatibility = try makeBundle(
            in: directory,
            name: "MissingCompatibility.app",
            identifier: StateletIdentity.bundleIdentifier,
            minimumSystemVersion: nil
        )
        XCTAssertThrowsError(
            try StateletBundleValidator.validate(
                at: missingCompatibility,
                requireTrustedSignature: false
            )
        ) { XCTAssertEqual($0 as? StateletUpdaterError, .unsupportedSystem) }

        let malformedCompatibility = try makeBundle(
            in: directory,
            name: "MalformedCompatibility.app",
            identifier: StateletIdentity.bundleIdentifier,
            minimumSystemVersion: "14.foo"
        )
        XCTAssertThrowsError(
            try StateletBundleValidator.validate(
                at: malformedCompatibility,
                requireTrustedSignature: false
            )
        ) { XCTAssertEqual($0 as? StateletUpdaterError, .unsupportedSystem) }
    }

    func testTransactionalInstallerRetainsJournalUntilNextLaunchReconciles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let target = try makeInstallerBundle(in: applications, marker: "old", version: "1.0.0", build: "1")
        let candidate = try makeInstallerBundle(in: staging, marker: "candidate", version: "2.0.0", build: "20")
        let validate = try installerValidation()
        let downloaded = StateletDownloadedUpdate(
            artifactURL: staging.appendingPathComponent("update.zip"),
            bundleURL: candidate
        )

        try StateletUpdateInstaller.install(
            downloaded,
            targetURL: target,
            validateBundle: validate
        )
        XCTAssertEqual(try installerMarker(at: target), "candidate")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: applications.appendingPathComponent(".statelet-update-active").path
        ))

        try StateletUpdateInstaller.reconcilePendingTransaction(
            targetURL: target,
            validateBundle: validate
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: applications.appendingPathComponent(".statelet-update-active").path
        ))
        XCTAssertEqual(try installerMarker(at: target), "candidate")
    }

    func testTransactionalInstallerRestoresPreviousBundleWhenPostPublishValidationFails() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let target = try makeInstallerBundle(in: applications, marker: "old", version: "1.0.0", build: "1")
        let candidate = try makeInstallerBundle(in: staging, marker: "candidate", version: "2.0.0", build: "20")
        let validate = try installerValidation(rejectTrustedCandidateAt: target)
        let downloaded = StateletDownloadedUpdate(
            artifactURL: staging.appendingPathComponent("update.zip"),
            bundleURL: candidate
        )

        XCTAssertThrowsError(
            try StateletUpdateInstaller.install(
                downloaded,
                targetURL: target,
                validateBundle: validate
            )
        ) { XCTAssertEqual($0 as? StateletUpdaterError, .untrustedSignature) }
        XCTAssertEqual(try installerMarker(at: target), "old")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: applications.appendingPathComponent(".statelet-update-active").path
        ))
    }

    func testTransactionalInstallerKeepsTargetRunnableAcrossEveryCrashCheckpoint() throws {
        for checkpoint in StateletUpdateInstaller.InstallCheckpoint.allCases {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let applications = root.appendingPathComponent("Applications", isDirectory: true)
            let staging = root.appendingPathComponent("staging", isDirectory: true)
            try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let target = try makeInstallerBundle(
                in: applications,
                marker: "old",
                version: "1.0.0",
                build: "1"
            )
            let candidate = try makeInstallerBundle(
                in: staging,
                marker: "candidate",
                version: "2.0.0",
                build: "20"
            )
            let validate = try installerValidation()
            let downloaded = StateletDownloadedUpdate(
                artifactURL: staging.appendingPathComponent("update.zip"),
                bundleURL: candidate
            )

            XCTAssertThrowsError(
                try StateletUpdateInstaller.install(
                    downloaded,
                    targetURL: target,
                    validateBundle: validate,
                    checkpoint: { observed in
                        if observed == checkpoint {
                            throw StateletUpdateInstaller.SimulatedCrash()
                        }
                    }
                ),
                "checkpoint: \(checkpoint)"
            ) { XCTAssertTrue($0 is StateletUpdateInstaller.SimulatedCrash) }
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: target.path),
                "target missing after checkpoint: \(checkpoint)"
            )

            try StateletUpdateInstaller.reconcilePendingTransaction(
                targetURL: target,
                validateBundle: validate
            )
            let candidateWasPublished: Bool
            switch checkpoint {
            case .bundlesSwapped, .published, .validated:
                candidateWasPublished = true
            case .transactionJournaled, .candidateStaged, .swapPrepared:
                candidateWasPublished = false
            }
            XCTAssertEqual(
                try installerMarker(at: target),
                candidateWasPublished ? "candidate" : "old",
                "checkpoint: \(checkpoint)"
            )
        }
    }

    func testTransactionalInstallerRejectsMalformedPendingJournal() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let target = try makeBundle(in: applications, identifier: StateletIdentity.bundleIdentifier)
        let transaction = applications.appendingPathComponent(".statelet-update-active", isDirectory: true)
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transaction.path)
        let journal = transaction.appendingPathComponent("journal.json")
        try Data("{not-json".utf8).write(to: journal)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)

        XCTAssertThrowsError(
            try StateletUpdateInstaller.reconcilePendingTransaction(targetURL: target)
        ) { XCTAssertEqual($0 as? StateletUpdaterError, .transactionRecoveryRequired) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.path))
    }

    func testTransactionalInstallerRejectsMultipleOrUnexpectedPendingJournals() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let target = try makeBundle(in: applications, identifier: StateletIdentity.bundleIdentifier)
        let first = try writeTransactionJournal(parent: applications, target: target, phase: "staged")
        let second = try writeTransactionJournal(
            parent: applications,
            target: target,
            phase: "staged",
            transactionName: ".statelet-update-unexpected"
        )

        XCTAssertThrowsError(
            try StateletUpdateInstaller.reconcilePendingTransaction(targetURL: target)
        ) { XCTAssertEqual($0 as? StateletUpdaterError, .transactionRecoveryRequired) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testTransactionalInstallerRefusesNewInstallWhileJournalIsPending() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let target = try makeInstallerBundle(in: applications, marker: "old", version: "1.0.0", build: "1")
        let pending = try writeTransactionJournal(parent: applications, target: target, phase: "staged")
        let candidate = try makeInstallerBundle(in: staging, marker: "candidate", version: "2.0.0", build: "20")
        let downloaded = StateletDownloadedUpdate(
            artifactURL: staging.appendingPathComponent("update.zip"),
            bundleURL: candidate
        )

        XCTAssertThrowsError(
            try StateletUpdateInstaller.install(
                downloaded,
                targetURL: target,
                validateBundle: try installerValidation()
            )
        ) { XCTAssertEqual($0 as? StateletUpdaterError, .transactionRecoveryRequired) }
        XCTAssertEqual(try installerMarker(at: target), "old")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
    }

    func testTransactionalInstallerRejectsJournalPathsOutsideTransaction() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let target = try makeBundle(in: applications, identifier: StateletIdentity.bundleIdentifier)
        let externalSwap = root.appendingPathComponent("must-not-touch-swap.app", isDirectory: true)
        try FileManager.default.createDirectory(at: externalSwap, withIntermediateDirectories: true)
        let transaction = try writeTransactionJournal(
            parent: applications,
            target: target,
            phase: "staged",
            swapPath: externalSwap.path
        )

        XCTAssertThrowsError(
            try StateletUpdateInstaller.reconcilePendingTransaction(targetURL: target)
        ) { XCTAssertEqual($0 as? StateletUpdaterError, .transactionRecoveryRequired) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalSwap.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.path))
    }

    func testTransactionalInstallerRejectsNonPrivateJournalPermissions() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let target = try makeBundle(in: applications, identifier: StateletIdentity.bundleIdentifier)
        let transaction = try writeTransactionJournal(
            parent: applications,
            target: target,
            phase: "staged"
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: transaction.appendingPathComponent("journal.json").path
        )

        XCTAssertThrowsError(
            try StateletUpdateInstaller.reconcilePendingTransaction(targetURL: target)
        ) { XCTAssertEqual($0 as? StateletUpdaterError, .transactionRecoveryRequired) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.path))
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
            verifyProvenance: acceptingProvenance,
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
            verifyProvenance: acceptingProvenance,
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
    func testCancellationDuringTrustValidationNeverPublishesReadyAndCleansStaging() async throws {
        let directory = try makeOwnedStagingDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifact = directory.appendingPathComponent("Statelet-update.zip")
        let payload = Data("cancel-during-validation".utf8)
        try payload.write(to: artifact)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let bundle = try makeBundle(in: directory, identifier: StateletIdentity.bundleIdentifier)
        let suite = "StateletUpdaterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let validationStarted = expectation(description: "validation started")
        let cancelled = expectation(description: "cancelled")
        let validationGate = AsyncTestGate()
        let candidateVersion = try XCTUnwrap(StateletVersion(version: "2.0.0", build: "20"))
        let coordinator = StateletUpdateCoordinator(
            installedVersion: try XCTUnwrap(StateletVersion(version: "1.0.0", build: "1")),
            defaults: defaults,
            fetchReleases: { self.releaseFeedJSON(size: payload.count, digest: digest) },
            fetchAssetData: { _ in Data() },
            verifyProvenance: acceptingProvenance,
            download: { _, _ in
                StateletDownloadedUpdate(
                    artifactURL: artifact,
                    bundleURL: bundle,
                    cleanupRootURL: directory
                )
            },
            installer: { _, _ in XCTFail("cancelled update must not install") },
            validateBundle: { _ in
                validationStarted.fulfill()
                await validationGate.wait()
                return StateletBundleMetadata(
                    version: candidateVersion,
                    minimumSystemVersion: OperatingSystemVersion(
                        majorVersion: 13,
                        minorVersion: 0,
                        patchVersion: 0
                    )
                )
            }
        )
        coordinator.onSnapshot = { snapshot in
            if snapshot.status == StateletUpdaterError.cancelled.safeStatus {
                cancelled.fulfill()
            }
        }

        coordinator.checkNow()
        await fulfillment(of: [validationStarted], timeout: 2)
        coordinator.cancel()
        await Task.yield()
        await validationGate.open()
        await fulfillment(of: [cancelled], timeout: 2)

        XCTAssertFalse(coordinator.snapshot.isReadyToInstall)
        XCTAssertFalse(coordinator.snapshot.isScheduledForRestart)
        let cleanupDeadline = Date().addingTimeInterval(2)
        while FileManager.default.fileExists(atPath: directory.path), Date() < cleanupDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    func testTerminationCancelsInFlightValidationAndCleansStagingBeforeExit() async throws {
        let directory = try makeOwnedStagingDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifact = directory.appendingPathComponent("Statelet-update.zip")
        let payload = Data("termination-during-validation".utf8)
        try payload.write(to: artifact)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let bundle = try makeBundle(in: directory, identifier: StateletIdentity.bundleIdentifier)
        let suite = "StateletUpdaterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let validationStarted = expectation(description: "validation started")
        let cancellationObserved = expectation(description: "cancellation observed")
        let validationGate = AsyncTestGate()
        let candidateVersion = try XCTUnwrap(StateletVersion(version: "2.0.0", build: "20"))
        let coordinator = StateletUpdateCoordinator(
            installedVersion: try XCTUnwrap(StateletVersion(version: "1.0.0", build: "1")),
            defaults: defaults,
            fetchReleases: { self.releaseFeedJSON(size: payload.count, digest: digest) },
            fetchAssetData: { _ in Data() },
            verifyProvenance: acceptingProvenance,
            download: { _, _ in
                StateletDownloadedUpdate(
                    artifactURL: artifact,
                    bundleURL: bundle,
                    cleanupRootURL: directory
                )
            },
            installer: { _, _ in XCTFail("in-flight update must not install") },
            validateBundle: { _ in
                validationStarted.fulfill()
                await validationGate.wait()
                return StateletBundleMetadata(
                    version: candidateVersion,
                    minimumSystemVersion: OperatingSystemVersion(
                        majorVersion: 13,
                        minorVersion: 0,
                        patchVersion: 0
                    )
                )
            }
        )
        coordinator.onSnapshot = { snapshot in
            if snapshot.status == StateletUpdaterError.cancelled.safeStatus {
                cancellationObserved.fulfill()
            }
        }

        coordinator.checkNow()
        await fulfillment(of: [validationStarted], timeout: 2)

        XCTAssertFalse(coordinator.shutdownAndWaitForQuiescence(timeout: 0.2))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(coordinator.snapshot.isReadyToInstall)
        XCTAssertFalse(coordinator.snapshot.isScheduledForRestart)

        await validationGate.open()
        await fulfillment(of: [cancellationObserved], timeout: 2)
    }

    @MainActor
    func testCoordinatorVerifiesStagesAndCommitsOnlyAtTerminationBoundary() async throws {
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
        let downloadProgress = expectation(description: "download progress")
        let ready = expectation(description: "ready")
        let scheduled = expectation(description: "scheduled for restart")
        let relaunchRequested = expectation(description: "relaunch requested")
        let terminationRequested = expectation(description: "termination requested")
        let installed = expectation(description: "installed at termination boundary")
        var installCount = 0
        let candidateVersion = try XCTUnwrap(StateletVersion(version: "2.0.0", build: "20"))
        let coordinator = StateletUpdateCoordinator(
            installedVersion: try XCTUnwrap(StateletVersion(version: "1.0.0", build: "1")),
            defaults: defaults,
            fetchReleases: { feed },
            fetchAssetData: { _ in Data() },
            verifyProvenance: acceptingProvenance,
            download: { _, progress in
                progress(0.5)
                return StateletDownloadedUpdate(artifactURL: artifact, bundleURL: bundle)
            },
            installer: { _, _ in
                installCount += 1
                installed.fulfill()
            },
            validateBundle: { _ in
                StateletBundleMetadata(version: candidateVersion, minimumSystemVersion: nil)
            }
        )
        coordinator.onSnapshot = { snapshot in
            if snapshot.status == "Downloading update…", snapshot.progress == 0.5 {
                downloadProgress.fulfill()
            }
            if snapshot.status == "Update verified and ready to install." { ready.fulfill() }
            if snapshot.isScheduledForRestart {
                scheduled.fulfill()
            }
        }
        coordinator.onRelaunchRequested = {
            relaunchRequested.fulfill()
            return true
        }
        coordinator.onTerminationRequested = { terminationRequested.fulfill() }

        coordinator.checkNow()
        await fulfillment(of: [downloadProgress, ready], timeout: 2)
        XCTAssertTrue(coordinator.snapshot.isReadyToInstall)
        XCTAssertEqual(coordinator.snapshot.progress, 1)
        coordinator.installReadyUpdate()
        coordinator.installReadyUpdate()
        await fulfillment(of: [scheduled, relaunchRequested, terminationRequested], timeout: 2)
        XCTAssertEqual(installCount, 0)
        XCTAssertEqual(coordinator.snapshot.status, "Restarting Statelet to install the update…")
        XCTAssertFalse(coordinator.snapshot.isReadyToInstall)
        XCTAssertTrue(coordinator.snapshot.isScheduledForRestart)

        let skipped = try coordinator.commitScheduledUpdateAtTermination(ifQuiescent: false)
        XCTAssertNil(skipped)
        XCTAssertEqual(installCount, 0)
        XCTAssertTrue(coordinator.snapshot.isScheduledForRestart)

        let committed = try coordinator.commitScheduledUpdateAtTermination(ifQuiescent: true)
        await fulfillment(of: [installed], timeout: 2)
        XCTAssertEqual(installCount, 1)
        XCTAssertEqual(committed?.version, candidateVersion)
        XCTAssertFalse(coordinator.snapshot.isScheduledForRestart)
    }

    @MainActor
    func testUnsafeTerminationPersistsRetryIntentAndForcesNextLaunchCheck() async throws {
        let suite = "StateletUpdaterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let candidateVersion = try XCTUnwrap(StateletVersion(version: "2.0.0", build: "20"))

        let firstDirectory = try makeOwnedStagingDirectory()
        defer { try? FileManager.default.removeItem(at: firstDirectory) }
        let firstArtifact = firstDirectory.appendingPathComponent("Statelet.zip")
        let firstPayload = Data("first scheduled archive".utf8)
        try firstPayload.write(to: firstArtifact)
        let firstDigest = SHA256.hash(data: firstPayload).map { String(format: "%02x", $0) }.joined()
        let firstBundle = firstDirectory.appendingPathComponent("Statelet.app", isDirectory: true)
        try FileManager.default.createDirectory(at: firstBundle, withIntermediateDirectories: true)
        let firstReady = expectation(description: "first update ready")
        let firstScheduled = expectation(description: "first update scheduled")
        let firstCoordinator = StateletUpdateCoordinator(
            installedVersion: try XCTUnwrap(StateletVersion(version: "1.0.0", build: "1")),
            defaults: defaults,
            fetchReleases: { self.releaseFeedJSON(size: firstPayload.count, digest: firstDigest) },
            fetchAssetData: { _ in Data() },
            verifyProvenance: acceptingProvenance,
            download: { _, _ in
                StateletDownloadedUpdate(
                    artifactURL: firstArtifact,
                    bundleURL: firstBundle,
                    cleanupRootURL: firstDirectory
                )
            },
            installer: { _, _ in XCTFail("unsafe termination must not install") },
            validateBundle: { _ in
                StateletBundleMetadata(version: candidateVersion, minimumSystemVersion: nil)
            }
        )
        firstCoordinator.onSnapshot = { snapshot in
            if snapshot.isReadyToInstall { firstReady.fulfill() }
            if snapshot.isScheduledForRestart { firstScheduled.fulfill() }
        }
        firstCoordinator.checkNow()
        await fulfillment(of: [firstReady], timeout: 2)
        firstCoordinator.installReadyUpdate()
        await fulfillment(of: [firstScheduled], timeout: 2)
        XCTAssertNil(try firstCoordinator.commitScheduledUpdateAtTermination(ifQuiescent: false))
        XCTAssertTrue(defaults.bool(forKey: "StateletUpdater.pendingInstallRetry.v1"))
        firstCoordinator.discardPreparedUpdateAtTermination()
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstDirectory.path))

        let retryDirectory = try makeOwnedStagingDirectory()
        defer { try? FileManager.default.removeItem(at: retryDirectory) }
        let retryArtifact = retryDirectory.appendingPathComponent("Statelet.zip")
        let retryPayload = Data("retried scheduled archive".utf8)
        try retryPayload.write(to: retryArtifact)
        let retryDigest = SHA256.hash(data: retryPayload).map { String(format: "%02x", $0) }.joined()
        let retryBundle = retryDirectory.appendingPathComponent("Statelet.app", isDirectory: true)
        try FileManager.default.createDirectory(at: retryBundle, withIntermediateDirectories: true)
        let retryScheduled = expectation(description: "pending install retried despite recent check")
        let retryCoordinator = StateletUpdateCoordinator(
            installedVersion: try XCTUnwrap(StateletVersion(version: "1.0.0", build: "1")),
            defaults: defaults,
            fetchReleases: { self.releaseFeedJSON(size: retryPayload.count, digest: retryDigest) },
            fetchAssetData: { _ in Data() },
            verifyProvenance: acceptingProvenance,
            download: { _, _ in
                StateletDownloadedUpdate(
                    artifactURL: retryArtifact,
                    bundleURL: retryBundle,
                    cleanupRootURL: retryDirectory
                )
            },
            installer: { _, _ in },
            validateBundle: { _ in
                StateletBundleMetadata(version: candidateVersion, minimumSystemVersion: nil)
            }
        )
        retryCoordinator.onSnapshot = { snapshot in
            if snapshot.isScheduledForRestart { retryScheduled.fulfill() }
        }

        retryCoordinator.startAutomaticChecks()
        await fulfillment(of: [retryScheduled], timeout: 2)
        XCTAssertTrue(retryCoordinator.snapshot.isScheduledForRestart)
        _ = try retryCoordinator.commitScheduledUpdateAtTermination(ifQuiescent: true)
        XCTAssertFalse(defaults.bool(forKey: "StateletUpdater.pendingInstallRetry.v1"))
    }

    @MainActor
    func testAutomaticInstallIsPersistedOptIn() async throws {
        let directory = try makeOwnedStagingDirectory()
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
        let scheduled = expectation(description: "scheduled")
        let installed = expectation(description: "installed at termination")
        var installCount = 0
        var relaunchRequestCount = 0
        let candidateVersion = try XCTUnwrap(StateletVersion(version: "2.0.0", build: "20"))
        let coordinator = StateletUpdateCoordinator(
            installedVersion: try XCTUnwrap(StateletVersion(version: "1.0.0", build: "1")),
            defaults: defaults,
            fetchReleases: { self.releaseFeedJSON(size: payload.count, digest: digest) },
            fetchAssetData: { _ in Data() },
            verifyProvenance: acceptingProvenance,
            download: { _, _ in
                StateletDownloadedUpdate(
                    artifactURL: artifact,
                    bundleURL: bundle,
                    cleanupRootURL: directory
                )
            },
            installer: { _, _ in
                installCount += 1
                installed.fulfill()
            },
            validateBundle: { _ in
                StateletBundleMetadata(version: candidateVersion, minimumSystemVersion: nil)
            }
        )
        coordinator.onSnapshot = { snapshot in
            if snapshot.isScheduledForRestart { scheduled.fulfill() }
        }
        coordinator.onRelaunchRequested = {
            relaunchRequestCount += 1
            return true
        }
        coordinator.setAutomaticInstall(true)
        XCTAssertTrue(defaults.bool(forKey: "StateletUpdater.automaticInstall.v1"))
        coordinator.checkNow()
        await fulfillment(of: [scheduled], timeout: 2)
        XCTAssertEqual(installCount, 0)
        XCTAssertEqual(relaunchRequestCount, 0)
        XCTAssertTrue(coordinator.snapshot.isScheduledForRestart)

        let updateQuiescent = coordinator.shutdownAndWaitForQuiescence()
        XCTAssertTrue(updateQuiescent)
        _ = try coordinator.commitScheduledUpdateAtTermination(ifQuiescent: updateQuiescent)
        await fulfillment(of: [installed], timeout: 2)
        XCTAssertEqual(installCount, 1)
        XCTAssertEqual(coordinator.snapshot.status, "Update installed. Reopen Statelet to use the new version.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
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

    private func signedCandidate(size: Int, digest: String) throws -> StateletUpdateCandidate {
        let releases = try StateletReleaseFeed.decode(releaseFeedJSON(size: size, digest: digest))
        return try XCTUnwrap(StateletReleaseFeed.selectCandidate(
            from: releases,
            newerThan: try XCTUnwrap(StateletVersion(version: "1.0.0", build: "1"))
        ))
    }

    private func signedManifestData(
        candidate: StateletUpdateCandidate,
        sha256: String,
        overrides: [String: Any] = [:]
    ) throws -> Data {
        var manifest: [String: Any] = [
            "schema_version": 1,
            "repository": StateletReleaseFeed.repository,
            "repository_id": StateletReleaseFeed.repositoryID,
            "ref": "refs/tags/\(candidate.releaseTag)",
            "commit_sha": String(repeating: "b", count: 40),
            "version": candidate.version.semantic.description,
            "build": candidate.version.build,
            "asset_name": candidate.packageAsset.name,
            "asset_size": candidate.packageAsset.size,
            "asset_sha256": sha256,
        ]
        for (key, value) in overrides { manifest[key] = value }
        return try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
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
          },{
            "name":"Statelet-macos-universal.zip.manifest.json",
            "browser_download_url":"https://github.com/assets/Statelet.zip.manifest.json",
            "size":512,"content_type":"application/json","digest":null
          },{
            "name":"Statelet-macos-universal.zip.manifest.sig",
            "browser_download_url":"https://github.com/assets/Statelet.zip.manifest.sig",
            "size":88,"content_type":"application/octet-stream","digest":null
          }]
        }]
        """.utf8)
    }

    private var acceptingProvenance: StateletUpdateCoordinator.ProvenanceVerifier {
        { candidate, _, _ in
            StateletReleaseArtifactAuthority(
                expectedSize: candidate.packageAsset.size,
                expectedSHA256: try XCTUnwrap(candidate.packageAsset.sha256Digest)
            )
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-updater-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeOwnedStagingDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("StateletUpdates", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func makeBundle(
        in directory: URL,
        name: String = "Statelet.app",
        identifier: String,
        minimumSystemVersion: String? = "13.0",
        version: String = "2.0.0",
        build: String = "20"
    ) throws -> URL {
        let bundle = directory.appendingPathComponent(name, isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent(StateletIdentity.executableName)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        var info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": StateletIdentity.executableName,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            StateletIdentity.appManagedPlistKey: StateletIdentity.managedMarker,
        ]
        if let minimumSystemVersion {
            info["LSMinimumSystemVersion"] = minimumSystemVersion
        }
        let plist = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        return bundle
    }

    private func makeInstallerBundle(
        in directory: URL,
        marker: String,
        version: String,
        build: String
    ) throws -> URL {
        let bundle = try makeBundle(
            in: directory,
            identifier: StateletIdentity.bundleIdentifier,
            version: version,
            build: build
        )
        try Data(marker.utf8).write(to: bundle.appendingPathComponent("version.marker"))
        return bundle
    }

    private func installerMarker(at bundle: URL) throws -> String {
        try String(contentsOf: bundle.appendingPathComponent("version.marker"), encoding: .utf8)
    }

    private func installerValidation(
        rejectTrustedCandidateAt rejectedTarget: URL? = nil
    ) throws -> StateletUpdateInstaller.BundleValidation {
        let oldVersion = try XCTUnwrap(StateletVersion(version: "1.0.0", build: "1"))
        let candidateVersion = try XCTUnwrap(StateletVersion(version: "2.0.0", build: "20"))
        return { url, requireTrustedSignature in
            let marker = try self.installerMarker(at: url)
            if requireTrustedSignature,
               marker == "candidate",
               let rejectedTarget,
               url.standardizedFileURL.path == rejectedTarget.standardizedFileURL.path {
                throw StateletUpdaterError.untrustedSignature
            }
            let version: StateletVersion
            switch marker {
            case "old":
                version = oldVersion
            case "candidate":
                version = candidateVersion
            default:
                throw StateletUpdaterError.invalidArtifact
            }
            return StateletBundleMetadata(version: version, minimumSystemVersion: nil)
        }
    }

    private func writeTransactionJournal(
        parent: URL,
        target: URL,
        phase: String,
        swapPath: String? = nil,
        transactionName: String = ".statelet-update-active"
    ) throws -> URL {
        let transaction = parent.appendingPathComponent(
            transactionName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transaction.path)
        let journal: [String: Any] = [
            "targetPath": target.path,
            "swapPath": swapPath ?? transaction.appendingPathComponent("swap.app").path,
            "transactionPath": transaction.path,
            "candidateVersion": "2.0.0",
            "candidateBuild": 20,
            "phase": phase,
        ]
        let data = try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys])
        let journalURL = transaction.appendingPathComponent("journal.json")
        try data.write(to: journalURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        return transaction
    }
}

private actor FetchCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor AsyncTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
