import AppKit
import CodexPetCore
import Foundation

private final class PlaybackHelperResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<AlphaPlaybackProbe, Error>?

    func store(_ value: Result<AlphaPlaybackProbe, Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }

    func load() -> Result<AlphaPlaybackProbe, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

private func runPlaybackSmokeHelper(arguments: [String]) -> Never {
    guard arguments.count == 3 else {
        FileHandle.standardError.write(Data("invalid playback helper arguments\n".utf8))
        exit(EXIT_FAILURE)
    }
    let result = PlaybackHelperResult()
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            result.store(
                .success(
                    try await AlphaPlaybackAcceptanceValidator.probe(
                        url: URL(fileURLWithPath: arguments[2])
                    )
                )
            )
        } catch {
            result.store(.failure(error))
        }
        semaphore.signal()
    }
    semaphore.wait()
    do {
        let probe = try result.load()!.get()
        FileHandle.standardOutput.write(try JSONEncoder().encode(probe))
        exit(EXIT_SUCCESS)
    } catch {
        FileHandle.standardError.write(Data("playback smoke failed\n".utf8))
        exit(EXIT_FAILURE)
    }
}

if CommandLine.arguments.dropFirst().first == "--statelet-playback-smoke-helper" {
    runPlaybackSmokeHelper(arguments: CommandLine.arguments)
}

guard let singletonLock = SingletonLock() else {
    FileHandle.standardError.write(Data("Statelet is already running or its lock cannot be created.\n".utf8))
    exit(EXIT_FAILURE)
}
withExtendedLifetime(singletonLock) {
    // Complete the legacy preferences import before NSApplication, the app
    // delegate, PositionStore, or any other UserDefaults.standard consumer is
    // initialized. Publishing the plist after that point can leave the process
    // reading a stale cfprefsd cache for the rest of this launch.
    let preferencesMigrationStatus = PreferencesMigration().migrate()
    guard preferencesMigrationStatus != .failed else {
        FileHandle.standardError.write(Data("Statelet could not prepare its preferences.\n".utf8))
        exit(EXIT_FAILURE)
    }
    let application = NSApplication.shared
    let delegate = PetAppDelegate(preferencesMigrationStatus: preferencesMigrationStatus)
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
