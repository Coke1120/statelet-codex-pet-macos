import CodexPetCore
import Darwin
import Foundation
import XCTest
@testable import Statelet

final class GPTSoVITSDemandServiceTests: XCTestCase {
    private static let endpoint = URL(string: "https://127.0.0.1:9880")!
    private static let pin = String(repeating: "a", count: 64)

    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            opened = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    /// Every OS boundary in the production launchctl adapter is replaced. No test
    /// invokes launchctl, signals a real process or reads an installed service plist.
    private final class FakeLaunchctl: @unchecked Sendable {
        typealias Identity = GPTSoVITSDemandService.ProcessIdentity
        private let lock = NSLock()
        let job = GPTSoVITSDemandService.Job(
            plistURL: URL(fileURLWithPath: "/synthetic/LaunchAgents/\(GPTSoVITSDemandService.label).plist"),
            endpoint: GPTSoVITSDemandServiceTests.endpoint, userID: 501, runAtLoad: false
        )
        private var registered = true
        private var process: Identity?
        private var commands: [[String]] = []
        private var signals: [(Int32, Int32)] = []
        private var seconds: TimeInterval = 0
        private var discoveries = 0
        var startGate: Gate?
        var didStart: (@Sendable () -> Void)?
        var failStart = false
        var spawnOnFailure = false

        var commandLog: [[String]] { lock.withLock { commands } }
        var signalLog: [(Int32, Int32)] { lock.withLock { signals } }
        var discoveryCount: Int { lock.withLock { discoveries } }
        var uptime: TimeInterval { lock.withLock { seconds } }

        func advance(_ duration: TimeInterval) { lock.withLock { seconds += duration } }
        func setRegistered(_ value: Bool) { lock.withLock { registered = value } }
        func replace(with process: Identity?) { lock.withLock { self.process = process } }

        func adapter() -> GPTSoVITSLaunchAgent {
            GPTSoVITSLaunchAgent(
                discoverJob: { endpoint in
                    self.lock.withLock {
                        self.discoveries += 1
                        return endpoint == self.job.endpoint ? self.job : nil
                    }
                },
                runCommand: { try await self.run($0) },
                processIdentity: { pid, uid in
                    self.lock.withLock {
                        self.process?.pid == pid && uid == self.job.userID ? self.process : nil
                    }
                },
                signal: { pid, signal in
                    self.lock.withLock {
                        self.signals.append((pid, signal))
                        if self.process?.pid == pid { self.process = nil }
                        return true
                    }
                },
                wallTime: { 100 }, now: { self.uptime }, pause: { self.advance(0.1) }
            )
        }

        func service(timeout: TimeInterval = 240) -> GPTSoVITSDemandService {
            let adapter = adapter()
            return GPTSoVITSDemandService(dependencies: .init(
                discover: { endpoint, _ in try adapter.discoverJob(endpoint) },
                inspect: { try await adapter.inspect($0) },
                start: { try await adapter.start($0) },
                stop: { await adapter.stop($0, process: $1) },
                now: { self.uptime },
                sleep: {
                    try Task.checkCancellation()
                    self.advance($0)
                }
            ), warmupTimeout: timeout)
        }

        private func run(_ arguments: [String]) async throws -> GPTSoVITSLaunchAgent.CommandResult {
            let result: GPTSoVITSLaunchAgent.CommandResult = lock.withLock {
                commands.append(arguments)
                switch arguments.first {
                case "print":
                    guard registered else { return .init(status: 113, output: "") }
                    let pid = process.map { "\tpid = \($0.pid)\n" } ?? ""
                    return .init(status: 0, output: "\(job.target) = {\n\tpath = \(job.plistURL.path)\n\ttype = LaunchAgent\n\(pid)}")
                case "bootstrap":
                    registered = true
                    return .init(status: 0, output: "")
                case "kickstart":
                    if !failStart || spawnOnFailure {
                        process = Identity(pid: 321, startSeconds: 200, startMicroseconds: 1)
                    }
                    return .init(status: failStart ? 1 : 0, output: process?.pid == 321 ? "321\n" : "")
                default:
                    return .init(status: 1, output: "")
                }
            }
            if arguments.first == "kickstart" {
                didStart?()
                await startGate?.wait()
            }
            return result
        }
    }

    private final class Transport: @unchecked Sendable {
        struct Entry {
            let path: String
            let pin: String
            let timeout: TimeInterval
            let resourceTimeout: TimeInterval
        }
        private let lock = NSLock()
        private var recorded: [Entry] = []
        var healthFailures = 0
        var statusByPath: [String: Int] = [:]
        var audio = GPTSoVITSDemandServiceTests.wave()
        var beforeResponse: (@Sendable (String) async throws -> Void)?
        var entries: [Entry] { lock.withLock { recorded } }

        func perform(_ request: URLRequest, pin: String, configuration: URLSessionConfiguration) async throws -> (Data, URLResponse) {
            let path = request.url!.path.isEmpty ? "/" : request.url!.path
            let status = lock.withLock { () -> Int in
                recorded.append(Entry(path: path, pin: pin, timeout: request.timeoutInterval,
                                      resourceTimeout: configuration.timeoutIntervalForResource))
                if path == "/", healthFailures > 0 {
                    healthFailures -= 1
                    return 503
                }
                return statusByPath[path] ?? (path == "/" ? 404 : 200)
            }
            try await beforeResponse?(path)
            return (path == "/tts" ? audio : Data(), HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
            )!)
        }
    }

    private func client(_ service: GPTSoVITSDemandService, _ transport: Transport) -> GPTSoVITSAPIClient {
        GPTSoVITSAPIClient(demandService: service) { request, _, pin, configuration in
            try await transport.perform(request, pin: pin, configuration: configuration)
        }
    }

    private func fixture() throws -> (root: URL, profile: GPTSoVITSVoiceProfile, line: DialogueLine) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("demand-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let profile = try GPTSoVITSVoiceProfile(
            name: "Synthetic", apiBaseURL: Self.endpoint, tlsLeafCertificateSHA256: Self.pin,
            gptWeightRelativePath: "voice/models/test.ckpt", sovitsWeightRelativePath: "voice/models/test.pth",
            referenceAudioRelativePath: "voice/reference/test.wav", referenceText: "Synthetic reference",
            promptLanguage: "en", defaultTextLanguage: "en", inputFingerprint: String(repeating: "b", count: 64)
        )
        for path in [profile.gptWeightRelativePath, profile.sovitsWeightRelativePath, profile.referenceAudioRelativePath] {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Inert bytes only. The fake gateway never opens or executes a checkpoint.
            try Data([1, 2, 3]).write(to: file)
        }
        return (root, profile, try DialogueLine(text: "Synthetic line", textLanguage: "en"))
    }

    func testColdStartCanExceedSixtySecondsAndPreservesPinnedRequestsThenStops() async throws {
        let fixture = try fixture()
        let launchctl = FakeLaunchctl()
        let transport = Transport()
        transport.healthFailures = 70
        let data = try await client(launchctl.service(), transport).synthesize(
            profile: fixture.profile, line: fixture.line, applicationSupportRoot: fixture.root
        )
        XCTAssertEqual(data, Self.wave())
        XCTAssertEqual(launchctl.uptime, 70)
        XCTAssertEqual(launchctl.commandLog.filter { $0.first == "kickstart" }, [["kickstart", "-p", launchctl.job.target]])
        XCTAssertEqual(transport.entries.suffix(3).map(\.path), ["/set_gpt_weights", "/set_sovits_weights", "/tts"])
        XCTAssertEqual(Set(transport.entries.map(\.pin)), [Self.pin])
        XCTAssertTrue(transport.entries.filter { $0.path == "/" }.allSatisfy { $0.timeout <= 5 && $0.resourceTimeout <= 5 })
        XCTAssertEqual(launchctl.signalLog.map { $0.0 }, [321])
        XCTAssertEqual(launchctl.signalLog.map { $0.1 }, [SIGTERM])
    }

    func testActivationAndSynthesisFailuresAwaitOwnedCleanup() async throws {
        for failingPath in ["/set_gpt_weights", "/set_sovits_weights", "/tts"] {
            let fixture = try fixture()
            let launchctl = FakeLaunchctl()
            let transport = Transport()
            transport.statusByPath[failingPath] = 500
            do {
                _ = try await client(launchctl.service(), transport).synthesize(
                    profile: fixture.profile, line: fixture.line, applicationSupportRoot: fixture.root
                )
                XCTFail("Failed HTTP request succeeded")
            } catch {
                XCTAssertEqual(error as? DialogueVoiceRuntimeError, .inferenceUnavailable)
            }
            XCTAssertEqual(launchctl.signalLog.count, 1, failingPath)
        }
    }

    func testWarmupDeadlineAndInvalidAudioBothReleaseOwnedProcess() async throws {
        for failsHealth in [true, false] {
            let fixture = try fixture()
            let launchctl = FakeLaunchctl()
            let transport = Transport()
            transport.healthFailures = failsHealth ? 1_000 : 0
            transport.audio = Data([1, 2, 3])
            do {
                _ = try await client(launchctl.service(timeout: 3), transport).synthesize(
                    profile: fixture.profile, line: fixture.line, applicationSupportRoot: fixture.root
                )
                XCTFail("Unhealthy or invalid audio succeeded")
            } catch {
                XCTAssertEqual(error as? DialogueVoiceRuntimeError, failsHealth ? .inferenceUnavailable : .invalidAudio)
            }
            XCTAssertEqual(launchctl.signalLog.count, 1)
            if failsHealth {
                XCTAssertEqual(launchctl.uptime, 3)
                XCTAssertEqual(transport.entries.map(\.path), ["/", "/", "/"])
            }
        }
    }

    func testValidationIsExplicitDemandAndReactivatesBothWeights() async throws {
        let fixture = try fixture()
        let launchctl = FakeLaunchctl()
        let transport = Transport()
        try await client(launchctl.service(), transport).validateProfile(fixture.profile, applicationSupportRoot: fixture.root)
        XCTAssertEqual(transport.entries.map(\.path), ["/", "/set_gpt_weights", "/set_sovits_weights"])
        XCTAssertEqual(launchctl.signalLog.count, 1)
    }

    func testPreexistingServiceIsBorrowedOnSuccessAndFailure() async throws {
        for fail in [false, true] {
            let fixture = try fixture()
            let launchctl = FakeLaunchctl()
            launchctl.replace(with: .init(pid: 123, startSeconds: 99, startMicroseconds: 0))
            let transport = Transport()
            transport.statusByPath["/set_gpt_weights"] = fail ? 400 : 200
            do {
                try await client(launchctl.service(), transport).validateProfile(fixture.profile, applicationSupportRoot: fixture.root)
                XCTAssertFalse(fail)
            } catch { XCTAssertTrue(fail) }
            XCTAssertFalse(launchctl.commandLog.contains { $0.first == "kickstart" })
            XCTAssertTrue(launchctl.signalLog.isEmpty)
        }
    }

    func testOverlappingLeasesStartOnceAndOnlyFinalReleaseStops() async throws {
        let launchctl = FakeLaunchctl()
        let service = launchctl.service()
        let first = try await service.acquire(baseURL: Self.endpoint, applicationSupportRoot: URL(fileURLWithPath: "/unused")) { _ in }
        let second = try await service.acquire(baseURL: Self.endpoint, applicationSupportRoot: URL(fileURLWithPath: "/unused")) { _ in
            XCTFail("An already-ready lease repeated warmup")
        }
        await service.release(first)
        XCTAssertTrue(launchctl.signalLog.isEmpty)
        let release = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await service.release(second)
        }
        await release.value
        await service.release(second)
        XCTAssertEqual(launchctl.signalLog.count, 1)
        XCTAssertEqual(launchctl.commandLog.filter { $0.first == "kickstart" }.count, 1)
    }

    func testCancelledQueuedAcquireReturnsWithoutWaitingForOtherWarmup() async throws {
        let launchctl = FakeLaunchctl()
        let service = launchctl.service()
        let gate = Gate()
        let warming = expectation(description: "First lease is warming")
        let first = Task {
            try await service.acquire(baseURL: Self.endpoint, applicationSupportRoot: URL(fileURLWithPath: "/unused")) { _ in
                warming.fulfill()
                await gate.wait()
            }
        }
        await fulfillment(of: [warming], timeout: 2)
        let queued = Task {
            try await service.acquire(baseURL: Self.endpoint, applicationSupportRoot: URL(fileURLWithPath: "/unused")) { _ in }
        }
        queued.cancel()
        do { _ = try await queued.value; XCTFail("Cancelled acquisition succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(launchctl.signalLog.isEmpty)
        await gate.open()
        let lease = try await first.value
        await service.release(lease)
        XCTAssertEqual(launchctl.signalLog.count, 1)
    }

    func testCancellationDuringKickstartCollectsPIDAndAwaitsCleanup() async throws {
        let fixture = try fixture()
        let launchctl = FakeLaunchctl()
        let gate = Gate()
        let started = expectation(description: "Fake kickstart spawned a PID")
        launchctl.startGate = gate
        launchctl.didStart = { started.fulfill() }
        let api = client(launchctl.service(), Transport())
        let request = Task { try await api.validateProfile(fixture.profile, applicationSupportRoot: fixture.root) }
        await fulfillment(of: [started], timeout: 2)
        request.cancel()
        await gate.open()
        do { try await request.value; XCTFail("Cancelled validation succeeded") }
        catch { XCTAssertEqual(error as? DialogueVoiceRuntimeError, .cancelled) }
        XCTAssertEqual(launchctl.signalLog.count, 1)
    }

    func testCancellationDuringHealthAndTTSStopsOwnedProcess() async throws {
        for blockedPath in ["/", "/tts"] {
            let fixture = try fixture()
            let launchctl = FakeLaunchctl()
            let transport = Transport()
            let entered = expectation(description: "Request entered \(blockedPath)")
            transport.beforeResponse = { path in
                if path == blockedPath {
                    entered.fulfill()
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                }
            }
            let api = client(launchctl.service(), transport)
            let request = Task { try await api.synthesize(profile: fixture.profile, line: fixture.line, applicationSupportRoot: fixture.root) }
            await fulfillment(of: [entered], timeout: 2)
            request.cancel()
            do { _ = try await request.value; XCTFail("Cancelled request succeeded") }
            catch { XCTAssertEqual(error as? DialogueVoiceRuntimeError, .cancelled) }
            XCTAssertEqual(launchctl.signalLog.count, 1, blockedPath)
        }
    }

    func testFailedStartCleansUpEvenWhenLaunchctlSpawnedBeforeReportingFailure() async throws {
        for spawned in [false, true] {
            let launchctl = FakeLaunchctl()
            launchctl.failStart = true
            launchctl.spawnOnFailure = spawned
            do {
                _ = try await launchctl.service().acquire(baseURL: Self.endpoint, applicationSupportRoot: URL(fileURLWithPath: "/unused")) { _ in
                    XCTFail("Failed start reached health")
                }
                XCTFail("Failed start acquired a lease")
            } catch { XCTAssertEqual(error as? DialogueVoiceRuntimeError, .inferenceUnavailable) }
            XCTAssertEqual(launchctl.signalLog.count, spawned ? 1 : 0)
        }
    }

    func testReplacementPIDAndRecycledPIDAreNeverSignalled() async throws {
        for pid: Int32 in [321, 654] {
            let launchctl = FakeLaunchctl()
            let service = launchctl.service()
            let lease = try await service.acquire(baseURL: Self.endpoint, applicationSupportRoot: URL(fileURLWithPath: "/unused")) { _ in }
            launchctl.replace(with: .init(pid: pid, startSeconds: 300, startMicroseconds: 0))
            await service.release(lease)
            XCTAssertTrue(launchctl.signalLog.isEmpty)
        }
    }

    func testFailedStartDoesNotClaimAnExternalReplacement() async throws {
        let launchctl = FakeLaunchctl()
        launchctl.failStart = true
        launchctl.spawnOnFailure = true
        launchctl.didStart = {
            launchctl.replace(with: .init(pid: 654, startSeconds: 300, startMicroseconds: 0))
        }
        do {
            _ = try await launchctl.service().acquire(baseURL: Self.endpoint, applicationSupportRoot: URL(fileURLWithPath: "/unused")) { _ in }
            XCTFail("Failed start succeeded")
        } catch { XCTAssertEqual(error as? DialogueVoiceRuntimeError, .inferenceUnavailable) }
        XCTAssertTrue(launchctl.signalLog.isEmpty)
    }

    func testKickstartReturningAnOlderProcessBorrowsWithoutStopping() async throws {
        let launchctl = FakeLaunchctl()
        launchctl.didStart = {
            launchctl.replace(with: .init(pid: 321, startSeconds: 99, startMicroseconds: 0))
        }
        let service = launchctl.service()
        let lease = try await service.acquire(baseURL: Self.endpoint, applicationSupportRoot: URL(fileURLWithPath: "/unused")) { _ in }
        await service.release(lease)
        XCTAssertTrue(launchctl.signalLog.isEmpty)
    }

    func testUnloadedNonAutostartingJobBootstrapsBeforeKickstart() async throws {
        let launchctl = FakeLaunchctl()
        launchctl.setRegistered(false)
        let service = launchctl.service()
        let lease = try await service.acquire(baseURL: Self.endpoint, applicationSupportRoot: URL(fileURLWithPath: "/unused")) { _ in }
        await service.release(lease)
        XCTAssertEqual(launchctl.commandLog.filter { $0.first != "print" }, [
            ["bootstrap", "gui/501", launchctl.job.plistURL.path], ["kickstart", "-p", launchctl.job.target]
        ])
    }

    func testCustomGatewayAndMockedTransportsDoNotManageAService() async throws {
        let launchctl = FakeLaunchctl()
        let service = launchctl.service()
        let lease = try await service.acquire(baseURL: URL(string: "https://127.0.0.1:9881")!, applicationSupportRoot: URL(fileURLWithPath: "/unused")) { _ in
            XCTFail("Unmanaged gateway must use the existing direct request contract")
        }
        await service.release(lease)
        XCTAssertTrue(launchctl.commandLog.isEmpty)
        let mockPerformer = GPTSoVITSAPIClient { _, _, _, _ in throw URLError(.cannotConnectToHost) }
        XCTAssertTrue(mockPerformer.demandService === GPTSoVITSDemandService.noop)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NeverUsedProtocol.self]
        let mockProtocol = GPTSoVITSAPIClient(configuration: configuration)
        XCTAssertTrue(mockProtocol.demandService === GPTSoVITSDemandService.noop)
        XCTAssertTrue(GPTSoVITSAPIClient().demandService === GPTSoVITSDemandService.shared)
    }

    func testInvalidEndpointPinAndFilesAreRejectedBeforeDiscovery() async throws {
        let fixture = try fixture()
        let launchctl = FakeLaunchctl()
        let api = client(launchctl.service(), Transport())
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.profile)) as? [String: Any])
        for key in ["api_base_url", "tls_leaf_certificate_sha256", "missing-file"] {
            var object = encoded
            if key == "api_base_url" { object[key] = "http://127.0.0.1:9880" }
            if key == "tls_leaf_certificate_sha256" { object.removeValue(forKey: key) }
            if key == "missing-file" { try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(fixture.profile.gptWeightRelativePath)) }
            let profile = try JSONDecoder().decode(GPTSoVITSVoiceProfile.self, from: JSONSerialization.data(withJSONObject: object))
            do { try await api.validateProfile(profile, applicationSupportRoot: fixture.root); XCTFail("Invalid profile succeeded") }
            catch { }
        }
        XCTAssertEqual(launchctl.discoveryCount, 0)
        XCTAssertTrue(launchctl.commandLog.isEmpty)
    }

    func testRecognitionRejectsForeignOrAutomaticallyRestartingJobs() {
        let job = FakeLaunchctl().job
        let metadata: [String: Any] = [
            "Label": GPTSoVITSDemandService.label, "RunAtLoad": false, "KeepAlive": false,
            "StateletManaged": "statelet-v2",
            "WorkingDirectory": "/synthetic/GPT-SoVITS",
            "ProgramArguments": ["/synthetic/python", "/synthetic/GPT-SoVITS/api_v2.py", "-a", "127.0.0.1", "-p", "9880", "-c", "/synthetic/config.yaml"]
        ]
        func recognized(_ metadata: [String: Any]) -> Bool {
            GPTSoVITSLaunchAgent.recognizedJob(metadata: metadata, endpoint: Self.endpoint,
                                             plistURL: job.plistURL, userID: job.userID) != nil
        }
        XCTAssertTrue(recognized(metadata))
        var unmarked = metadata
        unmarked.removeValue(forKey: "StateletManaged")
        XCTAssertFalse(recognized(unmarked), "Only the installer may adopt a legacy job")
        for (key, value) in [
            ("Label", "another.job" as Any), ("StateletManaged", "foreign"), ("KeepAlive", true),
            ("KeepAlive", ["SuccessfulExit": false]), ("StartInterval", 60), ("Sockets", [:]),
            ("StartOnMount", true), ("OnDemand", false),
            ("WorkingDirectory", "/other"),
            ("ProgramArguments", ["/synthetic/gateway", "/synthetic/GPT-SoVITS/api_v2.py", "-a", "127.0.0.1", "-p", "9880"]),
            ("ProgramArguments", ["/synthetic/python", "/synthetic/GPT-SoVITS/api_v2.py", "-a", "127.0.0.1", "-p", "9881"]),
            ("ProgramArguments", ["/synthetic/python", "/synthetic/GPT-SoVITS/api_v2.py", "-a", "0.0.0.0", "-p", "9880"])
        ] {
            var changed = metadata
            changed[key] = value
            XCTAssertFalse(recognized(changed), key)
        }
    }

    func testIPv6LoopbackJobMatchesBracketedEndpointHost() {
        let job = FakeLaunchctl().job
        let endpoint = URL(string: "https://[::1]:9880")!
        let metadata: [String: Any] = [
            "Label": GPTSoVITSDemandService.label, "RunAtLoad": false, "KeepAlive": false,
            "StateletManaged": "statelet-v2",
            "WorkingDirectory": "/synthetic/GPT-SoVITS",
            "ProgramArguments": ["/synthetic/python", "/synthetic/GPT-SoVITS/api_v2.py", "-a", "::1", "-p", "9880"]
        ]
        XCTAssertNotNil(GPTSoVITSLaunchAgent.recognizedJob(
            metadata: metadata, endpoint: endpoint, plistURL: job.plistURL, userID: job.userID
        ))
    }

    func testExplicitMarkedBindingAllowsDifferentBackendAndPinnedGatewayPorts() {
        let job = FakeLaunchctl().job
        let gateway = URL(string: "https://127.0.0.1:9881")!
        var metadata: [String: Any] = [
            "Label": GPTSoVITSDemandService.label, "RunAtLoad": false, "KeepAlive": false,
            "WorkingDirectory": "/synthetic/GPT-SoVITS", "StateletManaged": "statelet-v2",
            "StateletVoiceEndpoint": gateway.absoluteString,
            "ProgramArguments": ["/synthetic/python", "/synthetic/GPT-SoVITS/api_v2.py", "-a", "127.0.0.1", "-p", "9880"]
        ]
        func recognize(_ endpoint: URL) -> GPTSoVITSDemandService.Job? {
            GPTSoVITSLaunchAgent.recognizedJob(metadata: metadata, endpoint: endpoint,
                                             plistURL: job.plistURL, userID: job.userID)
        }
        XCTAssertEqual(recognize(gateway)?.endpoint, gateway)
        XCTAssertNil(recognize(URL(string: "https://127.0.0.1:9882")!))
        metadata.removeValue(forKey: "StateletManaged")
        XCTAssertNil(recognize(gateway), "An unmarked job cannot assert a gateway binding")
        metadata.removeValue(forKey: "StateletVoiceEndpoint")
        XCTAssertNil(recognize(gateway), "An unbound custom endpoint cannot start the backend")
        XCTAssertNil(recognize(Self.endpoint), "Unmarked jobs remain externally managed")
        metadata["StateletManaged"] = "statelet-v2"
        XCTAssertNotNil(recognize(Self.endpoint), "Marked exact-port jobs do not need a gateway binding")
    }

    private final class NeverUsedProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { false }
    }

    private static func wave() -> Data {
        var data = Data("RIFF".utf8)
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        u32(38); data.append(Data("WAVEfmt ".utf8)); u32(16)
        u16(1); u16(1); u32(8_000); u32(16_000); u16(2); u16(16)
        data.append(Data("data".utf8)); u32(2); u16(1)
        return data
    }
}
