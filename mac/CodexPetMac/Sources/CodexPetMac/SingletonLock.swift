import Darwin
import Foundation

/// Advisory locks for the current identity and, only when it already exists,
/// the legacy identity. Descriptors remain open for the process lifetime.
final class SingletonLock {
    private var descriptors: [Int32] = []

    init?(fileManager: FileManager = .default, homeURL: URL? = nil) {
        let home = (homeURL ?? fileManager.homeDirectoryForCurrentUser).standardizedFileURL
        let homeDescriptor = open(home.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard homeDescriptor >= 0 else { return nil }
        defer { close(homeDescriptor) }

        let legacyResult = openDirectory(
            relativePath: StateletIdentity.Legacy.applicationSupportRelativePath,
            from: homeDescriptor,
            create: false
        )
        if let legacy = legacyResult.descriptor {
            guard acquireLock(in: legacy) else {
                close(legacy)
                releaseLocks()
                return nil
            }
            close(legacy)
        } else if legacyResult.error != ENOENT {
            return nil
        }

        guard let current = openDirectory(
            relativePath: StateletIdentity.applicationSupportRelativePath,
            from: homeDescriptor,
            create: true
        ).descriptor else {
            releaseLocks()
            return nil
        }
        defer { close(current) }
        guard acquireLock(in: current) else {
            releaseLocks()
            return nil
        }
    }

    deinit { releaseLocks() }

    private func openDirectory(
        relativePath: String,
        from root: Int32,
        create: Bool
    ) -> (descriptor: Int32?, error: Int32) {
        var current = dup(root)
        guard current >= 0 else { return (nil, errno) }
        for component in relativePath.split(separator: "/").map(String.init) {
            var next = openat(current, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            if next < 0, create, errno == ENOENT {
                guard mkdirat(current, component, 0o700) == 0 || errno == EEXIST else {
                    let failure = errno
                    close(current)
                    return (nil, failure)
                }
                next = openat(current, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard next >= 0 else {
                let failure = errno
                close(current)
                return (nil, failure)
            }
            close(current)
            current = next
        }
        return (current, 0)
    }

    private func acquireLock(in directory: Int32) -> Bool {
        let descriptor = openat(
            directory,
            ".mac-player.lock",
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else { return false }
        guard fchmod(descriptor, 0o600) == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        descriptors.append(descriptor)
        return true
    }

    private func releaseLocks() {
        for descriptor in descriptors.reversed() {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        descriptors.removeAll()
    }
}
