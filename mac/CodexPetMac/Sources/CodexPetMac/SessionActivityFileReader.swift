import CodexPetCore
import Darwin
import Foundation

enum SessionActivityReadResult: Equatable {
    case snapshot(SessionActivitySnapshot)
    case missing
    case corrupt
}

struct SessionActivityTargets: Codable, Equatable, Sendable {
    static let version = 1
    static let maximumTargets = SessionActivitySnapshot.maximumItemsPerGroup * 2

    struct Target: Codable, Equatable, Sendable {
        let id: String
        let threadID: String

        private enum CodingKeys: String, CodingKey {
            case id
            case threadID = "thread_id"
        }
    }

    let version: Int
    let schemaVersion: Int
    let emittedAt: Double
    let targets: [Target]

    private enum CodingKeys: String, CodingKey {
        case version
        case schemaVersion = "schema_version"
        case emittedAt = "emitted_at"
        case targets
    }

    func validated(for activity: SessionActivitySnapshot) -> [String: String] {
        guard version == Self.version,
              schemaVersion == Self.version,
              emittedAt.isFinite,
              emittedAt == activity.emittedAt,
              targets.count <= Self.maximumTargets else { return [:] }
        let activityItems = Dictionary(
            uniqueKeysWithValues: (activity.active + activity.completed).map { ($0.id, $0) }
        )
        var result: [String: String] = [:]
        for target in targets {
            guard let item = activityItems[target.id] else { return [:] }
            guard item.provider == .codex else { continue }
            guard target.id.count == SessionActivityItem.maximumIdentifierLength,
                  target.id.unicodeScalars.allSatisfy(
                      String("0123456789abcdef").unicodeScalars.contains
                  ),
                  CodexDesktopActivationPolicy.isValidThreadID(target.threadID),
                  result.updateValue(target.threadID, forKey: target.id) == nil else {
                return [:]
            }
        }
        return result
    }
}

struct SessionActivityApplication: Equatable {
    let decision: SessionActivityAcceptanceDecision
    let lastAcceptedSnapshot: SessionActivitySnapshot?
    let displayedSnapshot: SessionActivitySnapshot?
    let acknowledgementHistory: [String]

    var acknowledgedIDs: Set<String> { Set(acknowledgementHistory) }
}

enum SessionActivityTargetAdoptionPolicy {
    static func apply(
        incomingTargets: [String: String],
        application: SessionActivityApplication,
        currentlyAcceptedTargets: [String: String]
    ) -> [String: String] {
        guard application.displayedSnapshot != nil else { return [:] }
        switch application.decision {
        case .acceptInitial, .acceptNewer, .rejectDuplicate:
            return incomingTargets
        case .rejectEqualTimestampConflict, .rejectRollback, .rejectStale, .rejectFutureSkew:
            return currentlyAcceptedTargets
        }
    }
}

enum SessionActivityApplicationPolicy {
    static let maximumAcknowledgements = 128

    static func apply(
        _ incoming: SessionActivitySnapshot,
        lastAccepted: SessionActivitySnapshot?,
        currentlyDisplayed: SessionActivitySnapshot?,
        acknowledgementHistory: [String],
        now: TimeInterval,
        freshnessPolicy: StateFreshnessPolicy = .production
    ) -> SessionActivityApplication {
        let decision = SessionActivityAcceptancePolicy.decide(
            lastAccepted: lastAccepted,
            incoming: incoming,
            now: now,
            freshnessPolicy: freshnessPolicy
        )
        let retainedDisplay = currentlyDisplayed.flatMap { snapshot in
            freshnessPolicy.freshness(emittedAt: snapshot.emittedAt, now: now) == .fresh
                ? snapshot
                : nil
        }
        let boundedHistory = normalizedHistory(acknowledgementHistory)
        guard decision.shouldAccept else {
            return SessionActivityApplication(
                decision: decision,
                lastAcceptedSnapshot: lastAccepted,
                displayedSnapshot: decision == .rejectDuplicate ? incoming : retainedDisplay,
                acknowledgementHistory: boundedHistory
            )
        }
        let activeIDs = Set(incoming.active.map(\.id))
        let retainedHistory = boundedHistory.filter { !activeIDs.contains($0) }
        return SessionActivityApplication(
            decision: decision,
            lastAcceptedSnapshot: incoming,
            displayedSnapshot: incoming,
            acknowledgementHistory: retainedHistory
        )
    }

    static func recordingAcknowledgement(
        _ id: String,
        in history: [String]
    ) -> [String] {
        normalizedHistory(history.filter { $0 != id } + [id])
    }

    static func recordingAcknowledgements(
        _ ids: [String],
        in history: [String]
    ) -> [String] {
        normalizedHistory(history + ids)
    }

    static func normalizedHistory(_ history: [String]) -> [String] {
        var ordered: [String] = []
        for id in history where id.count == SessionActivityItem.maximumIdentifierLength {
            ordered.removeAll { $0 == id }
            ordered.append(id)
        }
        return Array(ordered.suffix(maximumAcknowledgements))
    }
}

enum SessionActivityAcknowledgementStore {
    static let defaultsKey = "Statelet.sessionActivityAcknowledgements.v1"

    static func restored(from defaults: UserDefaults = .standard) -> [String] {
        let values = defaults.array(forKey: defaultsKey) as? [String] ?? []
        let normalized = SessionActivityApplicationPolicy.normalizedHistory(values)
        if normalized != values {
            defaults.set(normalized, forKey: defaultsKey)
        }
        return normalized
    }

    static func persist(
        _ history: [String],
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(
            SessionActivityApplicationPolicy.normalizedHistory(history),
            forKey: defaultsKey
        )
    }
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
    private let targetLoader: @Sendable (URL, SessionActivitySnapshot) -> [String: String]

    init(
        loader: @escaping @Sendable (URL) -> SessionActivityReadResult = { url in
            SessionActivityFileReader.load(url)
        },
        targetLoader: @escaping @Sendable (URL, SessionActivitySnapshot) -> [String: String] = { url, snapshot in
            SessionActivityFileReader.loadTargets(for: url, activity: snapshot)
        }
    ) {
        self.loader = loader
        self.targetLoader = targetLoader
    }

    func readWithTargets(
        _ url: URL,
        completion: @escaping @Sendable (SessionActivityReadResult, [String: String]) -> Void
    ) {
        lock.lock()
        generation &+= 1
        let requestGeneration = generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.loader(url)
            let targets: [String: String]
            if case let .snapshot(snapshot) = result {
                targets = self.targetLoader(url, snapshot)
            } else {
                targets = [:]
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let current = self.generation == requestGeneration
                self.lock.unlock()
                if current { completion(result, targets) }
            }
        }
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

    static func load(
        _ url: URL,
        afterOpeningDirectory: (() -> Void)? = nil
    ) -> SessionActivityReadResult {
        let directoryURL = url.deletingLastPathComponent()
        let directoryDescriptor = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            return errno == ENOENT ? .missing : .corrupt
        }
        defer { Darwin.close(directoryDescriptor) }
        var directoryBefore = stat()
        guard Darwin.fstat(directoryDescriptor, &directoryBefore) == 0,
              directoryBefore.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              directoryBefore.st_uid == Darwin.geteuid() else {
            return .corrupt
        }
        afterOpeningDirectory?()
        let descriptor = Darwin.openat(
            directoryDescriptor,
            url.lastPathComponent,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            return errno == ENOENT ? .missing : .corrupt
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_uid == Darwin.geteuid(),
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
        var directoryAfter = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              Darwin.fstat(directoryDescriptor, &directoryAfter) == 0,
              directoryBefore.st_dev == directoryAfter.st_dev,
              directoryBefore.st_ino == directoryAfter.st_ino,
              directoryBefore.st_uid == directoryAfter.st_uid,
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

    static func loadTargets(
        for activityURL: URL,
        activity: SessionActivitySnapshot
    ) -> [String: String] {
        let targetURL = activityURL.deletingLastPathComponent()
            .appendingPathComponent("activity-targets-v1.json")
        guard case let .data(data) = loadBoundedData(targetURL),
              let targets = try? JSONDecoder.codexPet.decode(SessionActivityTargets.self, from: data) else {
            return [:]
        }
        return targets.validated(for: activity)
    }

    private enum BoundedDataResult {
        case data(Data)
        case missing
        case corrupt
    }

    private static func loadBoundedData(_ url: URL) -> BoundedDataResult {
        let directoryDescriptor = Darwin.open(
            url.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            return errno == ENOENT ? .missing : .corrupt
        }
        defer { Darwin.close(directoryDescriptor) }
        var directoryBefore = stat()
        guard Darwin.fstat(directoryDescriptor, &directoryBefore) == 0,
              directoryBefore.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              directoryBefore.st_uid == Darwin.geteuid() else { return .corrupt }
        let descriptor = Darwin.openat(
            directoryDescriptor,
            url.lastPathComponent,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            return errno == ENOENT ? .missing : .corrupt
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_uid == Darwin.geteuid(),
              before.st_size >= 0,
              UInt64(before.st_size) <= maximumBytes else { return .corrupt }
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
        var directoryAfter = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              Darwin.fstat(directoryDescriptor, &directoryAfter) == 0,
              directoryBefore.st_dev == directoryAfter.st_dev,
              directoryBefore.st_ino == directoryAfter.st_ino,
              directoryBefore.st_uid == directoryAfter.st_uid,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              data.count == Int(before.st_size) else { return .corrupt }
        return .data(data)
    }
}
