import Darwin
import Foundation

/// A pipe reader whose descriptor remains valid even when its Foundation handle
/// closes. Create it before closing that handle and call `drain` on one worker.
/// Cleanup must call `stop`, then join the worker before releasing its buffers.
final class ProcessPipeReader: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var stopped = false

    init?(handle: FileHandle) {
        let descriptor = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { return nil }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        self.descriptor = descriptor
    }

    deinit { Darwin.close(descriptor) }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    func drain(_ receive: (Data) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while !isStopped {
            // A descendant can retain stdout after its parent exits. Polling a
            // nonblocking descriptor gives cancellation a bounded wait without
            // racing FileHandle.availableData against FileHandle.close().
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&event, 1, 50)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }
            guard event.revents & Int16(POLLIN | POLLHUP) != 0 else { break }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                receive(Data(buffer.prefix(count)))
            } else if count == 0 {
                break
            } else if errno != EINTR, errno != EAGAIN {
                break
            }
        }
    }
}
