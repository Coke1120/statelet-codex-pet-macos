import AppKit

@MainActor
final class WindowResizeFrameCoordinator {
    typealias Scheduler = (@escaping @MainActor @Sendable () -> Void) -> Void
    nonisolated static func scheduleOnMain(_ action: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async(execute: action)
    }

    private let schedule: Scheduler
    private let apply: (NSRect) -> Void
    private var pendingFrame: NSRect?
    private var updateScheduled = false
    private var scheduleGeneration: UInt = 0

    init(
        schedule: @escaping Scheduler = WindowResizeFrameCoordinator.scheduleOnMain,
        apply: @escaping (NSRect) -> Void
    ) {
        self.schedule = schedule
        self.apply = apply
    }

    func submit(_ frame: NSRect) {
        pendingFrame = frame
        guard !updateScheduled else { return }

        updateScheduled = true
        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        schedule { [weak self] in
            self?.applyScheduledFrame(generation: generation)
        }
    }

    func flush() {
        scheduleGeneration &+= 1
        updateScheduled = false
        applyPendingFrame()
    }

    func cancel() {
        scheduleGeneration &+= 1
        updateScheduled = false
        pendingFrame = nil
    }

    private func applyScheduledFrame(generation: UInt) {
        guard updateScheduled, generation == scheduleGeneration else { return }
        updateScheduled = false
        applyPendingFrame()
    }

    private func applyPendingFrame() {
        guard let frame = pendingFrame else { return }
        pendingFrame = nil
        apply(frame)
    }
}
