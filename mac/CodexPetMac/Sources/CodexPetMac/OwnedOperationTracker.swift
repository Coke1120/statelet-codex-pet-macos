import Foundation

/// A small main-thread handoff queue that can be drained normally by the main
/// dispatch queue or synchronously by a termination boundary already running
/// on the main thread.
final class MainThreadFinalizationQueue: @unchecked Sendable {
    private typealias Finalization = @MainActor @Sendable () -> Void
    private let lock = NSLock()
    private var pending: [Finalization] = []

    func enqueue(_ finalization: @escaping @MainActor @Sendable () -> Void) {
        lock.withLock { pending.append(finalization) }
        DispatchQueue.main.async { [weak self] in self?.drain() }
    }

    func drain() {
        dispatchPrecondition(condition: .onQueue(.main))
        while true {
            let next = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
            guard let next else { return }
            MainActor.assumeIsolated { next() }
        }
    }
}

/// Tracks file/process operations whose final ownership handoff may run on the
/// main actor. Termination callers can cancel every registered operation and
/// synchronously wait without starving queued MainActor finalizers.
final class OwnedOperationTracker: @unchecked Sendable {
    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private weak var tracker: OwnedOperationTracker?
        private let id: UUID
        private var finished = false

        fileprivate init(tracker: OwnedOperationTracker, id: UUID) {
            self.tracker = tracker
            self.id = id
        }

        func setCancellation(_ cancellation: @escaping @Sendable () -> Void) {
            tracker?.setCancellation(cancellation, for: id)
        }

        func finish() {
            let owner = lock.withLock { () -> OwnedOperationTracker? in
                guard !finished else { return nil }
                finished = true
                let owner = tracker
                tracker = nil
                return owner
            }
            owner?.finish(id)
        }

        deinit { finish() }
    }

    private struct Activity {
        var cancellation: (@Sendable () -> Void)?
    }

    private let condition = NSCondition()
    private var activities: [UUID: Activity] = [:]

    var isQuiescent: Bool {
        condition.lock()
        defer { condition.unlock() }
        return activities.isEmpty
    }

    func begin() -> Lease {
        let id = UUID()
        condition.lock()
        activities[id] = Activity(cancellation: nil)
        condition.unlock()
        return Lease(tracker: self, id: id)
    }

    func waitForQuiescence(
        timeout: TimeInterval,
        mainThreadWork: (() -> Void)? = nil
    ) -> Bool {
        waitForQuiescence(
            timeout: timeout,
            cancelling: false,
            mainThreadWork: mainThreadWork
        )
    }

    func cancelAndWaitForQuiescence(
        timeout: TimeInterval,
        mainThreadWork: (() -> Void)? = nil
    ) -> Bool {
        waitForQuiescence(
            timeout: timeout,
            cancelling: true,
            mainThreadWork: mainThreadWork
        )
    }

    private func setCancellation(
        _ cancellation: @escaping @Sendable () -> Void,
        for id: UUID
    ) {
        condition.lock()
        guard activities[id] != nil else {
            condition.unlock()
            return
        }
        activities[id]?.cancellation = cancellation
        condition.unlock()
    }

    private func finish(_ id: UUID) {
        condition.lock()
        activities.removeValue(forKey: id)
        if activities.isEmpty { condition.broadcast() }
        condition.unlock()
    }

    private func waitForQuiescence(
        timeout: TimeInterval,
        cancelling: Bool,
        mainThreadWork: (() -> Void)?
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: max(0, timeout))
        if cancelling {
            condition.lock()
            let cancellations = activities.values.compactMap(\.cancellation)
            condition.unlock()
            cancellations.forEach { $0() }
        }

        if Thread.isMainThread {
            while Date() < deadline {
                mainThreadWork?()
                condition.lock()
                let complete = activities.isEmpty
                condition.unlock()
                if complete { return true }

                // Service ordinary main-queue work as well as the explicit
                // finalization drain, using a slice bounded by `deadline`.
                _ = RunLoop.current.run(
                    mode: .default,
                    before: min(deadline, Date(timeIntervalSinceNow: 0.01))
                )
            }
            mainThreadWork?()
            condition.lock()
            let complete = activities.isEmpty
            condition.unlock()
            return complete
        }

        condition.lock()
        defer { condition.unlock() }
        while !activities.isEmpty {
            if !condition.wait(until: deadline), !activities.isEmpty {
                return false
            }
        }
        return true
    }
}
