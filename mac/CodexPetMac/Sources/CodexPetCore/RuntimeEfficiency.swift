import Darwin
import Foundation

public enum PlaybackSuspensionReason: String, Hashable, Sendable {
    case screenAsleep = "screen_asleep"
    case windowOccluded = "window_occluded"
}

public enum PlaybackControlDirective: Equatable, Sendable {
    case none
    case pause
    case resume(rate: Double)
}

/// Pure playback-intent state. AVFoundation remains the executor, while this
/// policy guarantees that independent system reasons cannot resume each other.
public struct PlaybackSuspensionPolicy: Equatable, Sendable {
    public private(set) var reasons: Set<PlaybackSuspensionReason> = []
    public private(set) var intendedPlaybackRate: Double?

    public init() {}

    public var canStartReadinessDeadline: Bool { reasons.isEmpty }

    public mutating func replacePlayback(rate: Double?) -> PlaybackControlDirective {
        intendedPlaybackRate = rate
        guard let rate else { return .none }
        return reasons.isEmpty ? .resume(rate: rate) : .pause
    }

    public mutating func clearPlayback() {
        intendedPlaybackRate = nil
    }

    public mutating func setSuspended(
        _ suspended: Bool,
        for reason: PlaybackSuspensionReason
    ) -> PlaybackControlDirective {
        let changed: Bool
        if suspended {
            changed = reasons.insert(reason).inserted
        } else {
            changed = reasons.remove(reason) != nil
        }
        guard changed else { return .none }
        guard reasons.isEmpty else { return suspended ? .pause : .none }
        guard let intendedPlaybackRate else { return .none }
        return .resume(rate: intendedPlaybackRate)
    }
}

public enum DisplayWakeRecoveryStep: Equatable, Sendable {
    case clearWindowOcclusion
    case clearScreenSleep
    case recheckWindowOcclusion
}

public enum DisplayWakeRecoveryPolicy {
    /// Clear possibly stale occlusion while screen sleep still prevents a
    /// resume, then clear sleep and re-evaluate AppKit on the next run-loop.
    public static let steps: [DisplayWakeRecoveryStep] = [
        .clearWindowOcclusion,
        .clearScreenSleep,
        .recheckWindowOcclusion,
    ]
}

public struct LocalFileRevision: Hashable, Sendable {
    public let path: String
    public let device: UInt64
    public let inode: UInt64
    public let size: UInt64
    public let modifiedNanoseconds: Int64

    public init?(url: URL) {
        let standardizedURL = url.standardizedFileURL
        var info = stat()
        guard lstat(standardizedURL.path, &info) == 0 else { return nil }
        path = standardizedURL.path
        device = UInt64(info.st_dev)
        inode = UInt64(info.st_ino)
        size = UInt64(max(0, info.st_size))
        modifiedNanoseconds = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000
            + Int64(info.st_mtimespec.tv_nsec)
    }
}

public struct BoundedLRUCache<Key: Hashable, Value> {
    public let capacity: Int
    private var storage: [Key: Value] = [:]
    private var order: [Key] = []

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { storage.count }

    public mutating func value(for key: Key) -> Value? {
        guard let value = storage[key] else { return nil }
        touch(key)
        return value
    }

    public mutating func insert(_ value: Value, for key: Key) {
        storage[key] = value
        touch(key)
        while order.count > capacity {
            storage.removeValue(forKey: order.removeFirst())
        }
    }

    private mutating func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

public enum LifecycleUIRefreshPolicy {
    public static func shouldRefresh(
        previousProducerState: PetState,
        incomingProducerState: PetState,
        presentationWillRefresh: Bool
    ) -> Bool {
        presentationWillRefresh || previousProducerState != incomingProducerState
    }
}

public enum LibraryRowRefreshPolicy {
    public static func shouldRefresh<Key: Equatable>(previous: Key?, incoming: Key) -> Bool {
        previous != incoming
    }
}
