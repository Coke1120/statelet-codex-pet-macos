import Darwin
import Foundation

/// Watches the containing directory instead of the JSON inode. The state
/// writer replaces files atomically, so a file descriptor opened on the old
/// inode would otherwise stop receiving events after the first replacement.
final class StateDirectoryWatcher {
    private let directoryURL: URL
    private let filename: String
    private var source: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private var callback: ((URL) -> Void)?
    private var lastIdentity: FileIdentity?

    init(fileURL: URL) {
        self.directoryURL = fileURL.deletingLastPathComponent()
        self.filename = fileURL.lastPathComponent
    }

    func start(emitInitial: Bool = true, onChange: @escaping (URL) -> Void) {
        stop()
        callback = onChange
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            startPolling(emitInitial: emitInitial)
            return
        }

        let fileDescriptor = open(directoryURL.path, O_EVTONLY | O_CLOEXEC)
        guard fileDescriptor >= 0 else {
            startPolling(emitInitial: emitInitial)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete, .link, .attrib, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.emitIfChanged()
        }
        source.setCancelHandler { close(fileDescriptor) }
        self.source = source
        source.resume()
        prepareInitialIdentity(emitInitial: emitInitial)
    }

    func stop() {
        source?.cancel()
        source = nil
        pollTimer?.cancel()
        pollTimer = nil
        callback = nil
    }

    deinit { stop() }

    private func startPolling(emitInitial: Bool) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(750))
        timer.setEventHandler { [weak self] in self?.emitIfChanged() }
        pollTimer = timer
        timer.resume()
        prepareInitialIdentity(emitInitial: emitInitial)
    }

    private func prepareInitialIdentity(emitInitial: Bool) {
        if emitInitial {
            emitIfChanged(force: true)
        } else {
            lastIdentity = FileIdentity(url: directoryURL.appendingPathComponent(filename))
        }
    }

    private func emitIfChanged(force: Bool = false) {
        let url = directoryURL.appendingPathComponent(filename)
        let identity = FileIdentity(url: url)
        if force || identity != lastIdentity {
            lastIdentity = identity
            callback?(url)
        }
    }
}

private struct FileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modified: Int64

    init?(url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        device = UInt64(info.st_dev)
        inode = UInt64(info.st_ino)
        size = UInt64(info.st_size)
        modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
    }
}
