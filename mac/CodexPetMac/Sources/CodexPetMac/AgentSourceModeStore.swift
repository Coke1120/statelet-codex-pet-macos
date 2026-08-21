import CodexPetCore
import Darwin
import Foundation

struct AgentSourceModeStore {
    static let filename = "agent-source-v1.json"
    static let maximumBytes = 4_096

    enum Failure: Error {
        case unsafePath
        case unsafeDirectory
        case unsafeDirectoryMetadata
        case unsafeDestination
        case writeFailed
    }

    let url: URL

    init(sessionActivityURL: URL) {
        url = sessionActivityURL.deletingLastPathComponent()
            .appendingPathComponent(Self.filename)
    }

    func load() -> AgentSourceMode {
        guard let directory = try? openDirectory(create: false) else { return .combined }
        defer { close(directory) }
        let descriptor = openat(
            directory,
            Self.filename,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else { return .combined }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_size <= Self.maximumBytes,
              (status.st_mode & 0o077) == 0 else {
            return .combined
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while data.count <= Self.maximumBytes {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            guard count > 0 else { return .combined }
            data.append(contentsOf: buffer.prefix(count))
        }
        var finalStatus = stat()
        guard fstat(descriptor, &finalStatus) == 0,
              sameIdentityAndRevision(status, finalStatus),
              Int64(data.count) == status.st_size,
              data.count <= Self.maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "mode"],
              let version = object["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.doubleValue == 1,
              version.intValue == 1,
              let rawMode = object["mode"] as? String,
              let mode = AgentSourceMode(rawValue: rawMode) else {
            return .combined
        }
        return mode
    }

    func save(_ mode: AgentSourceMode) throws {
        let directory = try openDirectory(create: true)
        defer { close(directory) }
        try validateExistingDestination(in: directory)

        let temporaryName = ".\(Self.filename).\(UUID().uuidString).tmp"
        let temporary = openat(
            directory,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard temporary >= 0 else { throw Failure.writeFailed }
        var shouldRemoveTemporary = true
        defer {
            close(temporary)
            if shouldRemoveTemporary { unlinkat(directory, temporaryName, 0) }
        }
        let data = Data("{\"version\":1,\"mode\":\"\(mode.rawValue)\"}".utf8)
        let wroteAll = data.withUnsafeBytes { bytes -> Bool in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    temporary,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wroteAll,
              fchmod(temporary, 0o600) == 0,
              fsync(temporary) == 0 else {
            throw Failure.writeFailed
        }
        guard renameat(directory, temporaryName, directory, Self.filename) == 0 else {
            throw Failure.writeFailed
        }
        shouldRemoveTemporary = false
        _ = fsync(directory)
    }

    private func validateExistingDestination(in directory: Int32) throws {
        var status = stat()
        if fstatat(directory, Self.filename, &status, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw Failure.unsafeDestination }
            return
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1 else {
            throw Failure.unsafeDestination
        }
    }

    private func openDirectory(create: Bool) throws -> Int32 {
        let path = url.deletingLastPathComponent().path
        guard path.hasPrefix("/"), !path.contains("/../") else { throw Failure.unsafePath }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw Failure.unsafePath }
        let components = path.split(separator: "/").map(String.init)
        var createdLeaf = false
        for (index, component) in components.enumerated() {
            var next = openat(current, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            if next < 0, create, errno == ENOENT {
                let created = mkdirat(current, component, 0o700) == 0
                guard created || errno == EEXIST else {
                    close(current)
                    throw Failure.unsafePath
                }
                if created, index == components.index(before: components.endIndex) {
                    createdLeaf = true
                }
                next = openat(current, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard next >= 0 else {
                close(current)
                throw Failure.unsafeDirectory
            }
            close(current)
            current = next
        }
        var status = stat()
        guard fstat(current, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == getuid(),
              createdLeaf || (status.st_mode & 0o077) == 0 else {
            close(current)
            throw Failure.unsafeDirectoryMetadata
        }
        if createdLeaf, fchmod(current, 0o700) != 0 {
            close(current)
            throw Failure.writeFailed
        }
        return current
    }

    private func sameIdentityAndRevision(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev
            && first.st_ino == second.st_ino
            && first.st_mode == second.st_mode
            && first.st_uid == second.st_uid
            && first.st_nlink == second.st_nlink
            && first.st_size == second.st_size
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
            && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
    }
}
