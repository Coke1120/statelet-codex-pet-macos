import Foundation
import Darwin

enum StateletUpdateInstaller {
    typealias BundleValidation = (URL, Bool) throws -> StateletBundleMetadata
    private static let applicationsDirectoryName = "Applications"
    private static let transactionPrefix = ".statelet-update-"

    private enum Phase: String, Codable {
        case staged
        case backedUp
        case published
        case validated
    }

    private struct Transaction: Codable {
        let targetPath: String
        let backupPath: String
        let stagedPath: String
        let transactionPath: String
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

    /// Publishes a verified bundle with a durable journal. The previous app is
    /// retained until the next Statelet launch reconciles the transaction.
    static func install(
        _ downloaded: StateletDownloadedUpdate,
        targetURL: URL = installedAppURL(),
        fileManager: FileManager = .default,
        validateBundle: @escaping BundleValidation = { url, requireTrustedSignature in
            try StateletBundleValidator.validate(at: url, requireTrustedSignature: requireTrustedSignature)
        }
    ) throws {
        let candidate = try validateBundle(downloaded.bundleURL, true)
        let targetMetadata = try validateBundle(targetURL, false)
        guard candidate.version > targetMetadata.version else {
            throw StateletUpdaterError.versionMismatch
        }
        try validateInstallBoundary(targetURL: targetURL, fileManager: fileManager)

        let parent = targetURL.deletingLastPathComponent().standardizedFileURL
        let transactionURL = parent.appendingPathComponent(
            "\(transactionPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        let stagedURL = transactionURL.appendingPathComponent(StateletIdentity.appBundleName, isDirectory: true)
        let backupURL = transactionURL.appendingPathComponent("previous.app", isDirectory: true)
        var transaction = Transaction(
            targetPath: targetURL.path,
            backupPath: backupURL.path,
            stagedPath: stagedURL.path,
            transactionPath: transactionURL.path,
            phase: .staged
        )

        do {
            try fileManager.createDirectory(at: transactionURL, withIntermediateDirectories: false)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transactionURL.path)
            try write(transaction: transaction, to: transactionURL, fileManager: fileManager)

            try fileManager.moveItem(at: downloaded.bundleURL, to: stagedURL)
            try write(transaction: transaction, to: transactionURL, fileManager: fileManager)

            transaction.phase = .backedUp
            try write(transaction: transaction, to: transactionURL, fileManager: fileManager)
            try fileManager.moveItem(at: targetURL, to: backupURL)
            try write(transaction: transaction, to: transactionURL, fileManager: fileManager)

            try fileManager.moveItem(at: stagedURL, to: targetURL)
            transaction.phase = .published
            try write(transaction: transaction, to: transactionURL, fileManager: fileManager)
            _ = try validateBundle(targetURL, true)
            transaction.phase = .validated
            try write(transaction: transaction, to: transactionURL, fileManager: fileManager)
        } catch {
            try rollback(transaction: transaction, fileManager: fileManager)
            throw error
        }
    }

    /// Finalizes a successful update or restores the previous app after an
    /// interrupted publication. It never discards a transaction it cannot
    /// validate or roll back completely.
    static func reconcilePendingTransaction(
        targetURL: URL = installedAppURL(),
        fileManager: FileManager = .default,
        validateBundle: @escaping BundleValidation = { url, requireTrustedSignature in
            try StateletBundleValidator.validate(at: url, requireTrustedSignature: requireTrustedSignature)
        }
    ) throws {
        let parent = targetURL.deletingLastPathComponent().standardizedFileURL
        guard let transaction = try findTransaction(
            for: targetURL,
            parent: parent,
            fileManager: fileManager
        ) else { return }

        switch transaction.phase {
        case .staged:
            try removeTransaction(transaction, fileManager: fileManager)
        case .backedUp:
            try restoreBackup(transaction, fileManager: fileManager)
            try removeTransaction(transaction, fileManager: fileManager)
        case .published, .validated:
            do {
                _ = try validateBundle(targetURL, true)
                try removeItemIfPresent(URL(fileURLWithPath: transaction.backupPath), fileManager: fileManager)
                try removeTransaction(transaction, fileManager: fileManager)
            } catch {
                try rollback(transaction: transaction, fileManager: fileManager)
                throw error
            }
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
        let journalURL = transactionURL.appendingPathComponent("journal.json")
        let temporaryURL = transactionURL.appendingPathComponent("journal.json.tmp")
        let data = try JSONEncoder().encode(transaction)
        try data.write(to: temporaryURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
        if fileManager.fileExists(atPath: journalURL.path) {
            try fileManager.removeItem(at: journalURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: journalURL)
    }

    private static func findTransaction(
        for targetURL: URL,
        parent: URL,
        fileManager: FileManager
    ) throws -> Transaction? {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { return nil }
        for entry in entries where entry.lastPathComponent.hasPrefix(transactionPrefix) {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            let journalURL = entry.appendingPathComponent("journal.json")
            guard let data = try? Data(contentsOf: journalURL),
                  let transaction = try? JSONDecoder().decode(Transaction.self, from: data),
                  URL(fileURLWithPath: transaction.targetPath).standardizedFileURL == targetURL.standardizedFileURL,
                  URL(fileURLWithPath: transaction.transactionPath).standardizedFileURL == entry.standardizedFileURL else { continue }
            return transaction
        }
        return nil
    }

    private static func rollback(
        transaction: Transaction,
        fileManager: FileManager
    ) throws {
        let targetURL = URL(fileURLWithPath: transaction.targetPath)
        let backupURL = URL(fileURLWithPath: transaction.backupPath)
        let hasBackup = fileManager.fileExists(atPath: backupURL.path)
        if hasBackup {
            try removeItemIfPresent(targetURL, fileManager: fileManager)
            try fileManager.moveItem(at: backupURL, to: targetURL)
        } else if transaction.phase == .published || transaction.phase == .validated {
            try removeItemIfPresent(targetURL, fileManager: fileManager)
        }
        try removeTransaction(transaction, fileManager: fileManager)
    }

    private static func restoreBackup(
        _ transaction: Transaction,
        fileManager: FileManager
    ) throws {
        let targetURL = URL(fileURLWithPath: transaction.targetPath)
        let backupURL = URL(fileURLWithPath: transaction.backupPath)
        guard fileManager.fileExists(atPath: backupURL.path) else {
            throw StateletUpdaterError.transactionRecoveryRequired
        }
        try removeItemIfPresent(targetURL, fileManager: fileManager)
        try fileManager.moveItem(at: backupURL, to: targetURL)
    }

    private static func removeTransaction(
        _ transaction: Transaction,
        fileManager: FileManager
    ) throws {
        let transactionURL = URL(fileURLWithPath: transaction.transactionPath)
        guard fileManager.fileExists(atPath: transactionURL.path) else { return }
        try fileManager.removeItem(at: transactionURL)
    }

    private static func removeItemIfPresent(_ url: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}
