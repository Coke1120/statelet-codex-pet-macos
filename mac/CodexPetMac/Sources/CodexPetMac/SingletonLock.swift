import Darwin
import Foundation

/// An advisory lock works for both a packaged accessory application and the
/// bundle-less SwiftPM executable, where bundle-identifier based discovery is
/// unavailable. The descriptor remains open for the process lifetime.
final class SingletonLock {
    private var descriptor: Int32 = -1

    init?(fileManager: FileManager = .default) {
        let support = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                StateletIdentity.applicationSupportRelativePath,
                isDirectory: true
            )
        do {
            try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
        } catch {
            return nil
        }

        descriptor = open(support.appendingPathComponent(".mac-player.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        if descriptor >= 0 { fchmod(descriptor, 0o600) }
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            descriptor = -1
            return nil
        }
    }

    deinit {
        if descriptor >= 0 {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }
}
