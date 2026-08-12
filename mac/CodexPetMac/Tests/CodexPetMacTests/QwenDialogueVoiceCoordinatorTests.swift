import CodexPetCore
import CryptoKit
import Foundation
import XCTest
@testable import CodexPetMac

final class QwenDialogueVoiceCoordinatorTests: XCTestCase {
    private final class RequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0
        func increment() { lock.withLock { storage += 1 } }
        func reset() { lock.withLock { storage = 0 } }
        var value: Int { lock.withLock { storage } }
    }

    private final class QwenUnexpectedGPTURLProtocol: URLProtocol {
        static let counter = RequestCounter()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.counter.increment()
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        }
        override func stopLoading() {}
    }

    private final class SuccessfulGPTURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": request.url?.lastPathComponent == "tts" ? "audio/wav" : "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: request.url?.lastPathComponent == "tts" ? Self.wav() : Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
        private static func wav() -> Data { pcmWAV(sampleRate: 16_000, frames: 16_000) }
    }

    private final class DelayedGPTURLProtocol: URLProtocol {
        private static let lock = NSLock()
        private static var synthesisStarted: (() -> Void)?
        private static var synthesisGate = DispatchSemaphore(value: 0)

        static func reset(onSynthesisStarted: @escaping () -> Void) {
            lock.withLock {
                synthesisStarted = onSynthesisStarted
                synthesisGate = DispatchSemaphore(value: 0)
            }
        }

        static func releaseSynthesis() { lock.withLock { synthesisGate }.signal() }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            if request.url?.lastPathComponent == "tts" {
                let state = Self.lock.withLock { (Self.synthesisStarted, Self.synthesisGate) }
                state.0?()
                state.1.wait()
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": request.url?.lastPathComponent == "tts" ? "audio/wav" : "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(
                self,
                didLoad: request.url?.lastPathComponent == "tts"
                    ? pcmWAV(sampleRate: 16_000, frames: 16_000)
                    : Data("{}".utf8)
            )
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private final class CancellationInsensitiveGenerationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

        func wait(onStarted: (Int) -> Void) async -> Int {
            let number = lock.withLock { () -> Int in
                count += 1
                return count
            }
            await withCheckedContinuation { continuation in
                lock.withLock { continuations[number] = continuation }
                onStarted(number)
            }
            return number
        }

        func release(_ number: Int) {
            lock.withLock { continuations.removeValue(forKey: number) }?.resume()
        }
    }

    private final class BlockingQwenInstallGate: @unchecked Sendable {
        private let lock = NSLock()
        private var starts = 0
        private var continuations: [Int: DispatchSemaphore] = [:]
        private var onStart: ((Int) -> Void)?

        func reset(onStart: @escaping (Int) -> Void) {
            lock.withLock {
                starts = 0
                continuations = [:]
                self.onStart = onStart
            }
        }

        func wait() -> Int {
            let state = lock.withLock { () -> (Int, DispatchSemaphore, ((Int) -> Void)?) in
                starts += 1
                let gate = DispatchSemaphore(value: 0)
                continuations[starts] = gate
                return (starts, gate, onStart)
            }
            state.2?(state.0)
            state.1.wait()
            return state.0
        }

        func release(_ number: Int) {
            lock.withLock { continuations.removeValue(forKey: number) }?.signal()
        }
    }

    override func setUp() {
        super.setUp()
        QwenUnexpectedGPTURLProtocol.counter.reset()
    }

    @MainActor
    func testSelectedQwenQueuedLineDispatchesOnlyQwenClient() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try makeQwenProfile(root: root)
        var library = try DialogueVoiceLibrary(qwenProfile: profile, activeProviderKind: .qwen3TTS)
        _ = try library.addLine(text: "テスト音声です", language: "japanese")
        try save(library, root: root)

        let qwenCalls = RequestCounter()
        let qwen = Qwen3TTSClient(
            helperExecutableURL: helperURL(root),
            probeExecutableURL: helperURL(root)
        ) { invocation in
            if invocation.requiresOutputFile {
                qwenCalls.increment()
                try Self.pcmWAV(sampleRate: 24_000, frames: 2_400).write(to: invocation.outputURL)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QwenUnexpectedGPTURLProtocol.self]
        let coordinator = DialogueVoiceCoordinator(
            applicationSupportRoot: root,
            client: GPTSoVITSAPIClient(configuration: configuration),
            qwenClient: qwen
        )
        defer { coordinator.shutdown() }
        let ready = expectation(description: "Qwen output is ready")
        coordinator.onChange = { snapshot in
            if snapshot.library.lines.first?.status == .ready { ready.fulfill() }
        }
        coordinator.start()
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(qwenCalls.value, 1)
        XCTAssertEqual(QwenUnexpectedGPTURLProtocol.counter.value, 0)
    }

    @MainActor
    func testQwenRejectsOversizedTextBeforeClientDispatch() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try makeQwenProfile(root: root)
        var library = try DialogueVoiceLibrary(qwenProfile: profile, activeProviderKind: .qwen3TTS)
        _ = try library.addLine(text: String(repeating: "あ", count: 501), language: "japanese")
        try save(library, root: root)
        let qwenCalls = RequestCounter()
        let coordinator = DialogueVoiceCoordinator(
            applicationSupportRoot: root,
            qwenClient: Qwen3TTSClient(
                helperExecutableURL: helperURL(root),
                probeExecutableURL: helperURL(root)
            ) { invocation in
                if invocation.requiresOutputFile { qwenCalls.increment() }
            }
        )
        defer { coordinator.shutdown() }
        let failed = expectation(description: "oversized Qwen line fails safely")
        coordinator.onChange = { snapshot in
            if snapshot.library.lines.first?.failureCode == "REQUEST_REJECTED" { failed.fulfill() }
        }
        coordinator.start()
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertEqual(qwenCalls.value, 0)
    }

    @MainActor
    func testStartupRetriesBothJournaledQwenDestinationAndPartialCleanup() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let token = UUID().uuidString.lowercased()
        let paths = try Qwen3TTSPackageInstaller.managedRelativePaths(destinationToken: token)
        for path in [paths.destination, paths.staging] {
            let file = root.appendingPathComponent(path, isDirectory: true)
                .appendingPathComponent("nested/payload.bin")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("private".utf8).write(to: file)
        }
        var library = try DialogueVoiceLibrary()
        try library.enqueueCleanup(paths: [paths.destination, paths.staging])
        try save(library, root: root)

        let coordinator = DialogueVoiceCoordinator(applicationSupportRoot: root)
        defer { coordinator.shutdown() }
        coordinator.start()

        XCTAssertTrue(coordinator.library.pendingCleanupPaths.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(paths.destination).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(paths.staging).path
        ))
    }

    @MainActor
    func testOverlappingQwenImportsPreserveLiveReservationUntilImporterFinishes() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gptProfile = try makeGPTProfile(root: root)
        var library = try DialogueVoiceLibrary(profile: gptProfile)
        let line = try library.addLine(text: "Existing GPT line", language: "en")
        let ticket = try library.beginGeneration(for: line.id)
        let outputPath = "voice/generated/existing-gpt.wav"
        let outputURL = root.appendingPathComponent(outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.pcmWAV(sampleRate: 16_000, frames: 1_600).write(to: outputURL)
        _ = try library.completeGeneration(ticket: ticket, outputPath: outputPath)
        try save(library, root: root)
        let gate = BlockingQwenInstallGate()
        let firstStarted = expectation(description: "first Qwen import starts")
        let secondStarted = expectation(description: "second Qwen import starts")
        gate.reset { attempt in
            if attempt == 1 { firstStarted.fulfill() }
            if attempt == 2 { secondStarted.fulfill() }
        }
        let coordinator = DialogueVoiceCoordinator(
            applicationSupportRoot: root,
            qwenPackageInstall: { _, supportRoot, token, pythonURL in
                let paths = try Qwen3TTSPackageInstaller.managedRelativePaths(
                    destinationToken: token
                )
                let destination = supportRoot.appendingPathComponent(paths.destination, isDirectory: true)
                let marker = destination.appendingPathComponent("marker.bin")
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: true
                )
                try Data("reserved".utf8).write(to: marker)
                let attempt = gate.wait()
                if attempt == 2 { throw DialogueVoiceRuntimeError.copyFailed }
                throw DialogueVoiceRuntimeError.cancelled
            }
        )
        defer {
            gate.release(1)
            gate.release(2)
            coordinator.shutdown()
        }
        coordinator.start()
        coordinator.configureQwenProfile(
            sourceURL: root.appendingPathComponent("first"),
            pythonExecutableURL: URL(fileURLWithPath: "/bin/sh")
        )
        await fulfillment(of: [firstStarted], timeout: 5)
        let firstPaths = try XCTUnwrap(
            qwenReservationPairs(in: coordinator.library).first
        )

        coordinator.configureQwenProfile(
            sourceURL: root.appendingPathComponent("second"),
            pythonExecutableURL: URL(fileURLWithPath: "/bin/sh")
        )
        await fulfillment(of: [secondStarted], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(firstPaths.destination).path
        ))

        gate.release(2)
        try await waitUntil(timeout: 5) {
            qwenReservationPairs(in: coordinator.library).count == 1
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(firstPaths.destination).path
        ))

        gate.release(1)
        try await waitUntil(timeout: 5) {
            coordinator.library.pendingCleanupPaths.isEmpty
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(firstPaths.destination).path
        ))
        XCTAssertEqual(coordinator.library.activeProviderKind, .gptSovits)
        XCTAssertNil(coordinator.library.qwenProfile)
        XCTAssertEqual(coordinator.library.lines.first?.status, .ready)
        XCTAssertEqual(coordinator.library.lines.first?.outputRelativePath, outputPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }

    @MainActor
    func testSuccessfulQwenConfigureKeepsActiveGPTReadyOutput() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gptProfile = try makeGPTProfile(root: root)
        let qwenFixture = try makeQwenProfile(root: root)
        var library = try DialogueVoiceLibrary(profile: gptProfile)
        let line = try library.addLine(text: "Existing GPT line", language: "en")
        let ticket = try library.beginGeneration(for: line.id)
        let outputPath = "voice/generated/existing-gpt.wav"
        let outputURL = root.appendingPathComponent(outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.pcmWAV(sampleRate: 16_000, frames: 1_600).write(to: outputURL)
        _ = try library.completeGeneration(ticket: ticket, outputPath: outputPath)
        try save(library, root: root)
        let fixtureRoot = root.appendingPathComponent(
            qwenFixture.packageRootRelativePath,
            isDirectory: true
        )
        let runtime = try Qwen3TTSProfileValidator.validatePythonExecutable(
            at: URL(fileURLWithPath: "/bin/sh")
        )

        let coordinator = DialogueVoiceCoordinator(
            applicationSupportRoot: root,
            qwenPackageInstall: { _, supportRoot, token, _ in
                let paths = try Qwen3TTSPackageInstaller.managedRelativePaths(
                    destinationToken: token
                )
                let destination = supportRoot.appendingPathComponent(
                    paths.destination,
                    isDirectory: true
                )
                try FileManager.default.copyItem(at: fixtureRoot, to: destination)
                return (
                    Qwen3TTSImportedPackage(
                        packageRootRelativePath: paths.destination,
                        manifest: qwenFixture.manifest,
                        treeSHA256: qwenFixture.packageTreeSHA256,
                        referenceText: qwenFixture.referenceText,
                        referenceLanguage: qwenFixture.referenceLanguage,
                        parameters: qwenFixture.parameters
                    ),
                    runtime
                )
            }
        )
        defer { coordinator.shutdown() }
        coordinator.start()
        coordinator.configureQwenProfile(
            sourceURL: fixtureRoot,
            pythonExecutableURL: URL(fileURLWithPath: "/bin/sh")
        )
        try await waitUntil(timeout: 5) { coordinator.library.qwenProfile != nil }

        XCTAssertEqual(coordinator.library.activeProviderKind, .gptSovits)
        XCTAssertEqual(coordinator.library.lines.first?.status, .ready)
        XCTAssertEqual(coordinator.library.lines.first?.outputRelativePath, outputPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertTrue(coordinator.library.pendingCleanupPaths.isEmpty)
        let configured = try XCTUnwrap(coordinator.library.qwenProfile)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(configured.packageRootRelativePath).path
        ))
    }

    @MainActor
    func testLegacyGPTLibraryStartsWithoutQwenDispatch() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try makeGPTProfile(root: root)
        var library = try DialogueVoiceLibrary(profile: profile)
        _ = try library.addLine(text: "Hello", language: "en")
        try save(library, root: root)
        let qwenCalls = RequestCounter()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuccessfulGPTURLProtocol.self]
        let coordinator = DialogueVoiceCoordinator(
            applicationSupportRoot: root,
            client: GPTSoVITSAPIClient(configuration: configuration),
            qwenClient: Qwen3TTSClient(
                helperExecutableURL: helperURL(root),
                probeExecutableURL: helperURL(root)
            ) { invocation in
                if invocation.requiresOutputFile { qwenCalls.increment() }
            }
        )
        defer { coordinator.shutdown() }
        let ready = expectation(description: "legacy GPT output is ready")
        coordinator.onChange = { snapshot in
            if snapshot.library.lines.first?.status == .ready { ready.fulfill() }
        }
        coordinator.start()
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(qwenCalls.value, 0)
        XCTAssertEqual(coordinator.library.activeProviderKind, .gptSovits)
    }

    @MainActor
    func testRemovingInactiveQwenProfileDoesNotCancelActiveGPTGeneration() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gptProfile = try makeGPTProfile(root: root)
        let qwenProfile = try makeQwenProfile(root: root)
        var library = try DialogueVoiceLibrary(
            profile: gptProfile,
            qwenProfile: qwenProfile,
            activeProviderKind: .gptSovits
        )
        let line = try library.addLine(text: "Synthetic speech", language: "en")
        try save(library, root: root)

        let synthesisStarted = expectation(description: "GPT synthesis is active")
        DelayedGPTURLProtocol.reset { synthesisStarted.fulfill() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedGPTURLProtocol.self]
        let coordinator = DialogueVoiceCoordinator(
            applicationSupportRoot: root,
            client: GPTSoVITSAPIClient(configuration: configuration)
        )
        defer {
            DelayedGPTURLProtocol.releaseSynthesis()
            coordinator.shutdown()
        }
        coordinator.start()
        await fulfillment(of: [synthesisStarted], timeout: 5)

        try coordinator.removeProfile(provider: .qwen3TTS)
        XCTAssertEqual(coordinator.library.activeProviderKind, .gptSovits)
        XCTAssertEqual(coordinator.library.lines.first?.status, .generating)
        XCTAssertNil(coordinator.library.qwenProfile)

        let ready = expectation(description: "original GPT generation completes")
        coordinator.onChange = { snapshot in
            if snapshot.library.lines.first(where: { $0.id == line.id })?.status == .ready {
                ready.fulfill()
            }
        }
        DelayedGPTURLProtocol.releaseSynthesis()
        await fulfillment(of: [ready], timeout: 5)
        let completed = try XCTUnwrap(coordinator.library.lines.first(where: { $0.id == line.id }))
        XCTAssertEqual(completed.status, .ready)
        XCTAssertNotNil(completed.outputRelativePath)
    }

    @MainActor
    func testQwenProviderRoundTripDiscardsCancellationInsensitiveStaleAttempt() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let gptProfile = try makeGPTProfile(root: root)
        let qwenProfile = try makeQwenProfile(root: root)
        var library = try DialogueVoiceLibrary(
            profile: gptProfile,
            qwenProfile: qwenProfile,
            activeProviderKind: .qwen3TTS
        )
        let line = try library.addLine(text: "テスト用音声", language: "japanese")
        try save(library, root: root)

        let firstStarted = expectation(description: "first Qwen attempt starts")
        let secondStarted = expectation(description: "replacement Qwen attempt starts")
        let firstReturned = expectation(description: "cancelled first Qwen runner returns")
        let gate = CancellationInsensitiveGenerationGate()
        let qwen = Qwen3TTSClient(
            helperExecutableURL: helperURL(root),
            probeExecutableURL: helperURL(root)
        ) { invocation in
            guard invocation.requiresOutputFile else { return }
            let attempt = await gate.wait { attempt in
                if attempt == 1 { firstStarted.fulfill() }
                if attempt == 2 { secondStarted.fulfill() }
            }
            let frames = attempt == 1 ? 2_400 : 4_800
            try Self.pcmWAV(sampleRate: 24_000, frames: frames).write(to: invocation.outputURL)
            if attempt == 1 { firstReturned.fulfill() }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuccessfulGPTURLProtocol.self]
        let coordinator = DialogueVoiceCoordinator(
            applicationSupportRoot: root,
            client: GPTSoVITSAPIClient(configuration: configuration),
            qwenClient: qwen
        )
        defer {
            gate.release(1)
            gate.release(2)
            coordinator.shutdown()
        }
        coordinator.start()
        await fulfillment(of: [firstStarted], timeout: 5)

        try coordinator.selectActiveProvider(.gptSovits)
        try coordinator.selectActiveProvider(.qwen3TTS)
        await fulfillment(of: [secondStarted], timeout: 5)

        gate.release(1)
        await fulfillment(of: [firstReturned], timeout: 5)
        try await waitUntil(timeout: 5) {
            let temporaryRoot = root.appendingPathComponent("voice/tmp", isDirectory: true)
            let jobCount = (try? FileManager.default.contentsOfDirectory(
                at: temporaryRoot,
                includingPropertiesForKeys: nil
            ).count) ?? 0
            return jobCount == 1
        }
        await Task.yield()
        XCTAssertEqual(coordinator.library.lines.first?.status, .generating)

        let ready = expectation(description: "replacement Qwen attempt completes")
        coordinator.onChange = { snapshot in
            if snapshot.library.lines.first(where: { $0.id == line.id })?.status == .ready {
                ready.fulfill()
            }
        }
        gate.release(2)
        await fulfillment(of: [ready], timeout: 5)
        let completed = try XCTUnwrap(coordinator.library.lines.first(where: { $0.id == line.id }))
        XCTAssertEqual(completed.status, .ready)
        XCTAssertNotNil(completed.outputRelativePath)
        XCTAssertEqual(coordinator.library.activeProviderKind, .qwen3TTS)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("qwen-coordinator-\(UUID())", isDirectory: true)
    }

    private func save(_ library: DialogueVoiceLibrary, root: URL) throws {
        try DialogueVoiceStore(rootURL: root.appendingPathComponent("voice", isDirectory: true)).save(library)
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the expected coordinator state")
    }

    private func qwenReservationPairs(
        in library: DialogueVoiceLibrary
    ) -> [(destination: String, staging: String)] {
        let paths = Set(library.pendingCleanupPaths)
        return paths.compactMap { path in
            guard path.hasPrefix("voice/packages/qwen/"),
                  !path.contains(".partial") else { return nil }
            let token = String(path.split(separator: "/").last ?? "")
            guard let pair = try? Qwen3TTSPackageInstaller.managedRelativePaths(
                destinationToken: token
            ), paths.contains(pair.staging) else { return nil }
            return pair
        }
    }

    private func helperURL(_ root: URL) -> URL { root.appendingPathComponent("helper.py") }

    private func makeQwenProfile(root: URL) throws -> Qwen3TTSVoiceProfile {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let packageRelative = "voice/packages/qwen/test"
        let package = root.appendingPathComponent(packageRelative, isDirectory: true)
        let reference = package.appendingPathComponent("reference", isDirectory: true)
        try FileManager.default.createDirectory(at: reference, withIntermediateDirectories: true)
        let files: [(String, Data)] = [
            ("model/model.safetensors", Data("model".utf8)),
            ("config.json", Data("{}".utf8)),
            ("generate.py", Data("generator".utf8)),
            ("reference/fixture.wav", Self.pcmWAV(sampleRate: 32_000, frames: 3_200)),
        ]
        try FileManager.default.createDirectory(at: package.appendingPathComponent("model"), withIntermediateDirectories: true)
        for (path, data) in files { try data.write(to: package.appendingPathComponent(path)) }
        let helper = helperURL(root)
        try Data("helper".utf8).write(to: helper)
        let python = URL(fileURLWithPath: "/bin/sh")
        let manifest = try Qwen3TTSPackageManifest(
            referenceAudioRelativePath: files[3].0,
            modelSHA256: sha(files[0].1), configSHA256: sha(files[1].1),
            handoverGeneratorSHA256: sha(files[2].1), referenceAudioSHA256: sha(files[3].1)
        )
        let provisional = try Qwen3TTSVoiceProfile(
            name: "Qwen", packageRootRelativePath: packageRelative,
            pythonExecutablePath: python.path, pythonExecutableSHA256: sha(try Data(contentsOf: python)),
            packageTreeSHA256: try Qwen3TTSProfileValidator.computePackageTreeSHA256(packageRoot: package),
            manifest: manifest, referenceText: "合成テスト用の参照文です。",
            referenceLanguage: "japanese", defaultTextLanguage: "japanese",
            inputFingerprint: String(repeating: "0", count: 64)
        )
        return try Qwen3TTSVoiceProfile(
            id: provisional.id, name: provisional.name, packageRootRelativePath: packageRelative,
            pythonExecutablePath: python.path, pythonExecutableSHA256: provisional.pythonExecutableSHA256,
            packageTreeSHA256: provisional.packageTreeSHA256,
            manifest: manifest, referenceText: provisional.referenceText,
            referenceLanguage: provisional.referenceLanguage, defaultTextLanguage: provisional.defaultTextLanguage,
            inputFingerprint: fingerprint(provisional.inputFingerprintComponents)
        )
    }

    private func makeGPTProfile(root: URL) throws -> GPTSoVITSVoiceProfile {
        let paths = ["voice/assets/gpt/test.ckpt", "voice/assets/sovits/test.pth", "voice/assets/reference/test.wav"]
        let data = [Data("gpt".utf8), Data("sovits".utf8), Self.pcmWAV(sampleRate: 16_000, frames: 1_600)]
        for (path, bytes) in zip(paths, data) {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        let digests = DialogueVoiceAssetDigests(gptWeight: sha(data[0]), sovitsWeight: sha(data[1]), referenceAudio: sha(data[2]))
        let endpoint = URL(string: "http://127.0.0.1:9880")!
        return try GPTSoVITSVoiceProfile(
            name: "GPT", apiBaseURL: endpoint, gptWeightRelativePath: paths[0], sovitsWeightRelativePath: paths[1],
            referenceAudioRelativePath: paths[2], referenceText: "Reference", promptLanguage: "en", defaultTextLanguage: "en",
            inputFingerprint: DialogueVoiceProfileFingerprint.compute(
                apiBaseURL: endpoint, referenceText: "Reference", promptLanguage: "en", defaultTextLanguage: "en", assetDigests: digests
            )
        )
    }

    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func fingerprint(_ fields: [String]) -> String {
        var hasher = SHA256()
        for field in fields {
            var length = UInt64(field.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
            hasher.update(data: Data(field.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func pcmWAV(sampleRate: UInt32, frames: Int) -> Data {
        let byteCount = frames * 2
        var data = Data("RIFF".utf8)
        append(UInt32(36 + byteCount), to: &data); data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &data); append(UInt16(1), to: &data); append(UInt16(1), to: &data)
        append(sampleRate, to: &data); append(sampleRate * 2, to: &data); append(UInt16(2), to: &data); append(UInt16(16), to: &data)
        data.append(Data("data".utf8)); append(UInt32(byteCount), to: &data); data.append(Data(repeating: 0, count: byteCount))
        return data
    }
    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
