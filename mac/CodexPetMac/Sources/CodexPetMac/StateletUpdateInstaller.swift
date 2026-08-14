import Foundation
import Darwin

enum StateletUpdateInstaller {
    typealias BundleValidation = (URL, Bool) throws -> StateletBundleMetadata
    typealias CheckpointHandler = (InstallCheckpoint) throws -> Void

    enum InstallCheckpoint: CaseIterable {
        case transactionJournaled
        case candidateStaged
        case swapPrepared
        case bundlesSwapped
        case published
        case validated
    }

    /// Test-only fault used to model process death without running in-process rollback.
    struct SimulatedCrash: Error {}

    private static let applicationsDirectoryName = "Applications"
    private static let transactionPrefix = ".statelet-update-"
    private static let activeTransactionName = ".statelet-update-active"
    private static let journalName = "journal.json"
    private static let swapName = "swap.app"
    private static let maximumJournalBytes = 64 * 1_024

    private enum Phase: String, Codable {
        case staged
        case swapPrepared
        case published
        case validated
    }

    private struct Transaction: Codable {
        let targetPath: String
        let swapPath: String
        let transactionPath: String
        let candidateVersion: String
        let candidateBuild: Int
        var phase: Phase
    }

    static func installedAppURL(
        fileManager: FileManager = .default,
        homeURL: URL? = nil
    ) -> URL {
        (homeURL ?? fileManager.homeDirectoryForCurrentUser)
            .appendingPathComponent(applicationsDirectoryName, isDirectory: true)
            .appendingPathComponent(StateletIdentity.appBundleName, isDirectory: true)
    }

    /// Publishes a verified bundle with a durable journal and an atomic name
    /// exchange. The installed app path therefore remains populated before,
    /// during, and after publication, including after process death.
    static func install(
        _ downloaded: StateletDownloadedUpdate,
        targetURL: URL = installedAppURL(),
        fileManager: FileManager = .default,
        validateBundle: @escaping BundleValidation = { url, requireTrustedSignature in
            try StateletBundleValidator.validate(at: url, requireTrustedSignature: requireTrustedSignature)
        },
        checkpoint: CheckpointHandler? = nil
    ) throws {
        let candidate = try validateBundle(downloaded.bundleURL, true)
        let targetMetadata = try validateBundle(targetURL, false)
        guard candidate.version > targetMetadata.version else {
            throw StateletUpdaterError.versionMismatch
        }
        try validateInstallBoundary(targetURL: targetURL, fileManager: fileManager)

        let parent = targetURL.deletingLastPathComponent().standardizedFileURL
        guard try findTransaction(for: targetURL, parent: parent, fileManager: fileManager) == nil else {
            throw StateletUpdaterError.transactionRecoveryRequired
        }
        let transactionURL = parent.appendingPathComponent(activeTransactionName, isDirectory: true)
        let swapURL = transactionURL.appendingPathComponent(swapName, isDirectory: true)
        var transaction = Transaction(
            targetPath: targetURL.path,
            swapPath: swapURL.path,
            transactionPath: transactionURL.path,
            candidateVersion: candidate.version.semantic.description,
            candidateBuild: candidate.version.build,
            phase: .staged
        )

        var ownsTransaction = false
        do {
            try fileManager.createDirectory(at: transactionURL, withIntermediateDirectories: false)
            ownsTransaction = true
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transactionURL.path)
            try write(transaction: transaction, to: transactionURL, fileManager: fileManager)
            try syncDirectory(parent)
            try checkpoint?(.transactionJournaled)

            try fileManager.moveItem(at: downloaded.bundleURL, to: swapURL)
            try syncDirectory(transactionURL)
            let stagedMetadata = try validateBundle(swapURL, true)
            guard stagedMetadata.version == candidate.version else {
                throw StateletUpdaterError.versionMismatch
            }
            try checkpoint?(.candidateStaged)

            transaction.phase = .swapPrepared
            try write(transaction: transaction, to: transactionURL, fileManager: fileManager)
            try checkpoint?(.swapPrepared)

            try atomicSwap(targetURL, swapURL)
            try checkpoint?(.bundlesSwapped)

            transaction.phase = .published
            try write(transaction: transaction, to: transactionURL, fileManager: fileManager)
            try checkpoint?(.published)

            let publishedMetadata = try validateBundle(targetURL, true)
            guard publishedMetadata.version == candidate.version else {
                throw StateletUpdaterError.versionMismatch
            }
            transaction.phase = .validated
            try write(transaction: transaction, to: transactionURL, fileManager: fileManager)
            try checkpoint?(.validated)
        } catch let error as SimulatedCrash {
            // A real process death cannot execute rollback. Leaving the exact
            // on-disk state intact lets tests exercise startup reconciliation.
            throw error
        } catch {
            guard ownsTransaction else {
                throw StateletUpdaterError.transactionRecoveryRequired
            }
            do {
                try rollback(
                    transaction: transaction,
                    fileManager: fileManager,
                    validateBundle: validateBundle
                )
            } catch {
                throw StateletUpdaterError.transactionRecoveryRequired
            }
            throw error
        }
    }

    /// Finalizes a successful update or atomically restores the previous app
    /// after an interrupted publication. It never discards a transaction whose
    /// paths, candidate identity, or recoverable side cannot be established.
    static func reconcilePendingTransaction(
        targetURL: URL = installedAppURL(),
        fileManager: FileManager = .default,
        validateBundle: @escaping BundleValidation = { url, requireTrustedSignature in
            try StateletBundleValidator.validate(at: url, requireTrustedSignature: requireTrustedSignature)
        }
    ) throws {
        try validateInstallBoundary(targetURL: targetURL, fileManager: fileManager)
        let parent = targetURL.deletingLastPathComponent().standardizedFileURL
        guard let transaction = try findTransaction(
            for: targetURL,
            parent: parent,
            fileManager: fileManager
        ) else { return }

        switch transaction.phase {
        case .staged:
            guard fileManager.fileExists(atPath: targetURL.path) else {
                throw StateletUpdaterError.transactionRecoveryRequired
            }
            _ = try validateBundle(targetURL, false)
            try removeTransaction(transaction, fileManager: fileManager)
        case .swapPrepared, .published, .validated:
            try reconcileExchange(
                transaction,
                fileManager: fileManager,
                validateBundle: validateBundle
            )
        }
    }

    private static func validateInstallBoundary(
        targetURL: URL,
        fileManager: FileManager
    ) throws {
        guard targetURL.pathExtension == "app",
              targetURL.lastPathComponent == StateletIdentity.appBundleName else {
            throw StateletUpdaterError.unsafeInstallBoundary
        }
        let parent = targetURL.deletingLastPathComponent().standardizedFileURL
        guard parent.pathExtension.isEmpty,
              parent.lastPathComponent == applicationsDirectoryName else {
            throw StateletUpdaterError.unsafeInstallBoundary
        }
        let parentValues = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else {
            throw StateletUpdaterError.unsafeInstallBoundary
        }
        let attributes = try fileManager.attributesOfItem(atPath: parent.path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.intValue == Int(getuid()) else {
            throw StateletUpdaterError.unsafeInstallBoundary
        }
    }

    private static func write(
        transaction: Transaction,
        to transactionURL: URL,
        fileManager: FileManager
    ) throws {
        let journalURL = transactionURL.appendingPathComponent(journalName)
        let data = try JSONEncoder().encode(transaction)
        try data.write(to: journalURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        try syncFile(journalURL)
        try syncDirectory(transactionURL)
    }

    private static func findTransaction(
        for targetURL: URL,
        parent: URL,
        fileManager: FileManager
    ) throws -> Transaction? {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ).filter { $0.lastPathComponent.hasPrefix(transactionPrefix) }
        } catch {
            throw StateletUpdaterError.transactionRecoveryRequired
        }
        guard entries.count <= 1 else {
            throw StateletUpdaterError.transactionRecoveryRequired
        }
        guard let entry = entries.first else { return nil }
        guard entry.lastPathComponent == activeTransactionName else {
            throw StateletUpdaterError.transactionRecoveryRequired
        }

        do {
            let entryValues = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let entryAttributes = try fileManager.attributesOfItem(atPath: entry.path)
            guard entryValues.isDirectory == true,
                  entryValues.isSymbolicLink != true,
                  isPrivateItem(entryAttributes, requiredPermissions: 0o700) else {
                throw StateletUpdaterError.transactionRecoveryRequired
            }

            let journalURL = entry.appendingPathComponent(journalName, isDirectory: false)
            let journalValues = try journalURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ])
            let journalAttributes = try fileManager.attributesOfItem(atPath: journalURL.path)
            guard journalValues.isRegularFile == true,
                  journalValues.isSymbolicLink != true,
                  let journalSize = journalValues.fileSize,
                  journalSize > 0,
                  journalSize <= maximumJournalBytes,
                  isPrivateItem(journalAttributes, requiredPermissions: 0o600) else {
                throw StateletUpdaterError.transactionRecoveryRequired
            }

            let data = try Data(contentsOf: journalURL, options: [.mappedIfSafe])
            let transaction = try JSONDecoder().decode(Transaction.self, from: data)
            let canonicalEntry = canonicalFileURL(entry)
            let expectedTarget = canonicalFileURL(targetURL)
            let expectedSwap = canonicalEntry.appendingPathComponent(swapName, isDirectory: true)
            guard canonicalFileURL(URL(fileURLWithPath: transaction.targetPath)).path == expectedTarget.path,
                  canonicalFileURL(URL(fileURLWithPath: transaction.transactionPath)).path == canonicalEntry.path,
                  canonicalFileURL(URL(fileURLWithPath: transaction.swapPath)).path == expectedSwap.path,
                  expectedCandidateVersion(transaction) != nil else {
                throw StateletUpdaterError.transactionRecoveryRequired
            }
            return Transaction(
                targetPath: expectedTarget.path,
                swapPath: expectedSwap.path,
                transactionPath: canonicalEntry.path,
                candidateVersion: transaction.candidateVersion,
                candidateBuild: transaction.candidateBuild,
                phase: transaction.phase
            )
        } catch let error as StateletUpdaterError {
            throw error
        } catch {
            throw StateletUpdaterError.transactionRecoveryRequired
        }
    }

    private static func reconcileExchange(
        _ transaction: Transaction,
        fileManager: FileManager,
        validateBundle: BundleValidation
    ) throws {
        guard let expectedCandidate = expectedCandidateVersion(transaction) else {
            throw StateletUpdaterError.transactionRecoveryRequired
        }
        let targetURL = URL(fileURLWithPath: transaction.targetPath)
        let swapURL = URL(fileURLWithPath: transaction.swapPath)
        let targetMetadata = try? validateExistingBundle(
            targetURL,
            requireTrustedSignature: false,
            fileManager: fileManager,
            validateBundle: validateBundle
        )
        let swapMetadata = try? validateExistingBundle(
            swapURL,
            requireTrustedSignature: false,
            fileManager: fileManager,
            validateBundle: validateBundle
        )
        let candidateAtTarget = targetMetadata?.version == expectedCandidate
        let candidateAtSwap = swapMetadata?.version == expectedCandidate
        guard candidateAtTarget != candidateAtSwap else {
            throw StateletUpdaterError.transactionRecoveryRequired
        }

        if candidateAtTarget {
            do {
                let trusted = try validateExistingBundle(
                    targetURL,
                    requireTrustedSignature: true,
                    fileManager: fileManager,
                    validateBundle: validateBundle
                )
                guard trusted.version == expectedCandidate else {
                    throw StateletUpdaterError.versionMismatch
                }
            } catch {
                guard swapMetadata != nil else {
                    throw StateletUpdaterError.transactionRecoveryRequired
                }
                try atomicSwap(targetURL, swapURL)
                _ = try validateExistingBundle(
                    targetURL,
                    requireTrustedSignature: false,
                    fileManager: fileManager,
                    validateBundle: validateBundle
                )
            }
        } else {
            guard targetMetadata != nil else {
                throw StateletUpdaterError.transactionRecoveryRequired
            }
        }
        try removeTransaction(transaction, fileManager: fileManager)
    }

    private static func rollback(
        transaction: Transaction,
        fileManager: FileManager,
        validateBundle: BundleValidation
    ) throws {
        let targetURL = URL(fileURLWithPath: transaction.targetPath)
        guard fileManager.fileExists(atPath: targetURL.path) else {
            throw StateletUpdaterError.transactionRecoveryRequired
        }
        switch transaction.phase {
        case .staged:
            _ = try validateBundle(targetURL, false)
        case .swapPrepared, .published, .validated:
            guard let expectedCandidate = expectedCandidateVersion(transaction) else {
                throw StateletUpdaterError.transactionRecoveryRequired
            }
            let swapURL = URL(fileURLWithPath: transaction.swapPath)
            let targetMetadata = try? validateExistingBundle(
                targetURL,
                requireTrustedSignature: false,
                fileManager: fileManager,
                validateBundle: validateBundle
            )
            let swapMetadata = try? validateExistingBundle(
                swapURL,
                requireTrustedSignature: false,
                fileManager: fileManager,
                validateBundle: validateBundle
            )
            let candidateAtTarget = targetMetadata?.version == expectedCandidate
            let candidateAtSwap = swapMetadata?.version == expectedCandidate
            guard candidateAtTarget != candidateAtSwap else {
                throw StateletUpdaterError.transactionRecoveryRequired
            }
            if candidateAtTarget {
                guard swapMetadata != nil else {
                    throw StateletUpdaterError.transactionRecoveryRequired
                }
                try atomicSwap(targetURL, swapURL)
            } else {
                guard targetMetadata != nil else {
                    throw StateletUpdaterError.transactionRecoveryRequired
                }
            }
            _ = try validateBundle(targetURL, false)
        }
        try removeTransaction(transaction, fileManager: fileManager)
    }

    private static func validateExistingBundle(
        _ url: URL,
        requireTrustedSignature: Bool,
        fileManager: FileManager,
        validateBundle: BundleValidation
    ) throws -> StateletBundleMetadata {
        guard fileManager.fileExists(atPath: url.path) else {
            throw StateletUpdaterError.transactionRecoveryRequired
        }
        return try validateBundle(url, requireTrustedSignature)
    }

    private static func expectedCandidateVersion(_ transaction: Transaction) -> StateletVersion? {
        StateletVersion(
            version: transaction.candidateVersion,
            build: String(transaction.candidateBuild)
        )
    }

    private static func atomicSwap(_ first: URL, _ second: URL) throws {
        let firstParent = first.deletingLastPathComponent()
        let secondParent = second.deletingLastPathComponent()
        let firstDescriptor = Darwin.open(
            firstParent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard firstDescriptor >= 0 else {
            throw StateletUpdaterError.transactionRecoveryRequired
        }
        defer { Darwin.close(firstDescriptor) }
        let secondDescriptor = Darwin.open(
            secondParent.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard secondDescriptor >= 0 else {
            throw StateletUpdaterError.transactionRecoveryRequired
        }
        defer { Darwin.close(secondDescriptor) }

        let result = first.lastPathComponent.withCString { firstName in
            second.lastPathComponent.withCString { secondName in
                Darwin.renameatx_np(
                    firstDescriptor,
                    firstName,
                    secondDescriptor,
                    secondName,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0,
              Darwin.fsync(firstDescriptor) == 0,
              Darwin.fsync(secondDescriptor) == 0 else {
            throw StateletUpdaterError.transactionRecoveryRequired
        }
    }

    private static func syncFile(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw StateletUpdaterError.transactionRecoveryRequired
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw StateletUpdaterError.transactionRecoveryRequired
        }
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw StateletUpdaterError.transactionRecoveryRequired
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw StateletUpdaterError.transactionRecoveryRequired
        }
    }

    private static func canonicalFileURL(_ url: URL) -> URL {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        return parent.appendingPathComponent(
            url.lastPathComponent,
            isDirectory: url.hasDirectoryPath
        ).standardizedFileURL
    }

    private static func isPrivateItem(
        _ attributes: [FileAttributeKey: Any],
        requiredPermissions: Int
    ) -> Bool {
        guard (attributes[.ownerAccountID] as? NSNumber)?.intValue == Int(getuid()),
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue else {
            return false
        }
        return permissions & 0o777 == requiredPermissions
    }

    private static func removeTransaction(
        _ transaction: Transaction,
        fileManager: FileManager
    ) throws {
        let transactionURL = URL(fileURLWithPath: transaction.transactionPath)
        guard fileManager.fileExists(atPath: transactionURL.path) else { return }
        let parent = transactionURL.deletingLastPathComponent()
        try fileManager.removeItem(at: transactionURL)
        try syncDirectory(parent)
    }
}
