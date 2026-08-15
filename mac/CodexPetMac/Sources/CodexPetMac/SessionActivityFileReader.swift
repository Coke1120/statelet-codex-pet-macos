import CodexPetCore
import Darwin
import Foundation

enum SessionActivityReadResult: Equatable {
    case snapshot(SessionActivitySnapshot)
    case missing
    case corrupt
}

/// Reads the activity sidecar using the same no-follow, bounded and immutable
/// descriptor checks as the lifecycle-state reader.
final class SessionActivityFileReader: @unchecked Sendable {
    static let maximumBytes: UInt64 = 1_048_576

    private let queue = DispatchQueue(
        label: "com.coke1120.Statelet.session-activity-reader",
        qos: .utility
    )
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private let loader: @Sendable (URL) -> SessionActivityReadResult

    init(
        loader: @escaping @Sendable (URL) -> SessionActivityReadResult = { url in
            SessionActivityFileReader.load(url)
        }
    ) {
        self.loader = loader
    }

    func read(
        _ url: URL,
        completion: @escaping @Sendable (SessionActivityReadResult) -> Void
    ) {
        lock.lock()
        generation &+= 1
        let requestGeneration = generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.loader(url)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let current = self.generation == requestGeneration
                self.lock.unlock()
                if current { completion(result) }
            }
        }
    }

    static func load(_ url: URL) -> SessionActivityReadResult {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            return errno == ENOENT ? .missing : .corrupt
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_size >= 0,
              UInt64(before.st_size) <= maximumBytes else {
            return .corrupt
        }
        var data = Data()
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                data.append(chunk)
                guard UInt64(data.count) <= maximumBytes else { return .corrupt }
            }
        } catch {
            return .corrupt
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              data.count == Int(before.st_size),
              let snapshot = try? JSONDecoder.codexPet.decode(
                  SessionActivitySnapshot.self,
                  from: data
              ) else {
            return .corrupt
        }
        return .snapshot(snapshot)
    }
}
