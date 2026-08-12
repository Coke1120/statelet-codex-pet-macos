import CodexPetCore
import CryptoKit
import Foundation
import XCTest
@testable import CodexPetMac

final class DialogueVoiceRuntimeTests: XCTestCase {
    private final class LockedQwenInvocation: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Qwen3TTSProcessInvocation?

        func set(_ value: Qwen3TTSProcessInvocation) {
            lock.lock()
            storage = value
            lock.unlock()
        }

        var value: Qwen3TTSProcessInvocation? {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private struct QwenFixture {
        let profile: Qwen3TTSVoiceProfile
        let python: URL
        let helper: URL
    }
    private final class ChunkedURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data([1, 2, 3]))
            client?.urlProtocol(self, didLoad: Data([4, 5, 6]))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private final class SuccessfulGPTSoVITSURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let isTTSRequest = request.url?.lastPathComponent == "tts"
            let data = isTTSRequest ? Self.pcmWAV() : Data("{}".utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": isTTSRequest ? "audio/wav" : "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        private static func pcmWAV() -> Data {
            let sampleBytes = 32_000
            var data = Data("RIFF".utf8)
            appendUInt32(UInt32(36 + sampleBytes), to: &data)
            data.append(Data("WAVEfmt ".utf8))
            appendUInt32(16, to: &data)
            appendUInt16(1, to: &data)
            appendUInt16(1, to: &data)
            appendUInt32(16_000, to: &data)
            appendUInt32(32_000, to: &data)
            appendUInt16(2, to: &data)
            appendUInt16(16, to: &data)
            data.append(Data("data".utf8))
            appendUInt32(UInt32(sampleBytes), to: &data)
            data.append(Data(repeating: 0, count: sampleBytes))
            return data
        }

        private static func appendUInt16(_ value: UInt16, to data: inout Data) {
            data.append(UInt8(value & 0xff))
            data.append(UInt8((value >> 8) & 0xff))
        }

        private static func appendUInt32(_ value: UInt32, to data: inout Data) {
            data.append(UInt8(value & 0xff))
            data.append(UInt8((value >> 8) & 0xff))
            data.append(UInt8((value >> 16) & 0xff))
            data.append(UInt8((value >> 24) & 0xff))
        }
    }

    private final class UnavailableThenSuccessfulGPTSoVITSURLProtocol: URLProtocol {
        private static let stateLock = NSLock()
        private static var failNextRequest = true

        static func reset() {
            stateLock.lock()
            failNextRequest = true
            stateLock.unlock()
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.stateLock.lock()
            let shouldFail = Self.failNextRequest
            Self.failNextRequest = false
            Self.stateLock.unlock()

            let isTTSRequest = request.url?.lastPathComponent == "tts"
            let statusCode = shouldFail ? 503 : 200
            let data = isTTSRequest ? Self.pcmWAV() : Data("{}".utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": isTTSRequest ? "audio/wav" : "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        private static func pcmWAV() -> Data {
            let sampleBytes = 32_000
            var data = Data("RIFF".utf8)
            appendUInt32(UInt32(36 + sampleBytes), to: &data)
            data.append(Data("WAVEfmt ".utf8))
            appendUInt32(16, to: &data)
            appendUInt16(1, to: &data)
            appendUInt16(1, to: &data)
            appendUInt32(16_000, to: &data)
            appendUInt32(32_000, to: &data)
            appendUInt16(2, to: &data)
            appendUInt16(16, to: &data)
            data.append(Data("data".utf8))
            appendUInt32(UInt32(sampleBytes), to: &data)
            data.append(Data(repeating: 0, count: sampleBytes))
            return data
        }

        private static func appendUInt16(_ value: UInt16, to data: inout Data) {
            data.append(UInt8(value & 0xff))
            data.append(UInt8((value >> 8) & 0xff))
        }

        private static func appendUInt32(_ value: UInt32, to data: inout Data) {
            data.append(UInt8(value & 0xff))
            data.append(UInt8((value >> 8) & 0xff))
            data.append(UInt8((value >> 16) & 0xff))
            data.append(UInt8((value >> 24) & 0xff))
        }
    }

    private final class FakePlayer: DialogueAudioPlaying {
        var playedPaths: [String] = []
        var error: Error?
        var isPlaying = false
        var volume: Float = 1
        var validatesManagedAudio = false
        private var completion: (() -> Void)?

        func play(
            relativePath: String,
            applicationSupportRoot: URL,
            onFinished: @escaping () -> Void
        ) throws {
            if let error { throw error }
            if validatesManagedAudio {
                let data = try DialogueVoiceAssetInstaller.readManagedFile(
                    relativePath: relativePath,
                    root: applicationSupportRoot,
                    maximumBytes: 67_108_864
                )
                guard GPTSoVITSAPIClient.isValidWAV(data) else {
                    throw FakeError.playback
                }
            }
            stop()
            playedPaths.append(relativePath)
            completion = onFinished
            isPlaying = true
        }

        func stop() {
            completion = nil
            isPlaying = false
        }

        func finishCurrentPlayback() {
            let callback = completion
            completion = nil
            isPlaying = false
            callback?()
        }
    }

    private final class ControlledSleeper: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedValues: [TimeInterval] = []
        private var waiters: [CheckedContinuation<Void, Error>] = []
        private var observer: ((Int) -> Void)?

        var values: [TimeInterval] {
            lock.lock()
            defer { lock.unlock() }
            return recordedValues
        }

        func sleep(for interval: TimeInterval) async throws {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                recordedValues.append(interval)
                waiters.append(continuation)
                let count = recordedValues.count
                let observer = observer
                lock.unlock()
                observer?(count)
            }
        }

        func setObserver(_ observer: @escaping (Int) -> Void) {
            lock.lock()
            self.observer = observer
            lock.unlock()
        }

        func resumeNext() {
            lock.lock()
            let continuation = waiters.isEmpty ? nil : waiters.removeFirst()
            lock.unlock()
            continuation?.resume(returning: ())
        }
    }

    private final class DeterministicRandomIndex: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int]

        init(_ values: [Int]) {
            self.values = values
        }

        func next(upperBound: Int) -> Int {
            lock.lock()
            let value = values.isEmpty ? 0 : values.removeFirst()
            lock.unlock()
            return value % upperBound
        }
    }

    private enum FakeError: Error { case playback }

    private let lineID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func profile() throws -> GPTSoVITSVoiceProfile {
        try GPTSoVITSVoiceProfile(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Test voice",
            apiBaseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:9880")),
            gptWeightRelativePath: "voice/assets/gpt/test.ckpt",
            sovitsWeightRelativePath: "voice/assets/sovits/test.pth",
            referenceAudioRelativePath: "voice/assets/reference/test.wav",
            referenceText: "Reference",
            promptLanguage: "en",
            defaultTextLanguage: "en",
            inputFingerprint: String(repeating: "a", count: 64)
        )
    }

    private func readyLibrary() throws -> DialogueVoiceLibrary {
        var library = try DialogueVoiceLibrary(profile: profile())
        _ = try library.addLine(text: "Hello", id: lineID)
        let ticket = try library.beginGeneration(for: lineID)
        _ = try library.completeGeneration(
            ticket: ticket,
            outputPath: "voice/generated/ready.wav"
        )
        return library
    }

    func testReadyPlaybackHasExplicitFallbackAndNeverSynthesizes() throws {
        let player = FakePlayer()
        let service = DialogueReadyPlaybackService(
            applicationSupportRoot: URL(fileURLWithPath: "/managed/root"),
            player: player
        )
        let ready = try readyLibrary()
        XCTAssertEqual(service.playReadyLine(id: lineID, in: ready), .played)
        XCTAssertEqual(player.playedPaths, ["voice/generated/ready.wav"])

        var queued = try DialogueVoiceLibrary(profile: profile())
        _ = try queued.addLine(text: "Queued", id: lineID)
        XCTAssertEqual(
            service.playReadyLine(id: lineID, in: queued),
            .unavailable(.notReady)
        )
        XCTAssertEqual(player.playedPaths.count, 1)

        player.error = FakeError.playback
        XCTAssertEqual(
            service.playReadyLine(id: lineID, in: ready),
            .unavailable(.missingOrInvalidAudio)
        )
    }

    func testStateDialoguePresentationFollowsTheExactSpokenLineUntilPlaybackFinishes() throws {
        let requestID = UUID()
        let fallbackLine = try DialogueLine(state: .idle, text: "Fallback", textLanguage: "en")
        let spokenLine = try DialogueLine(state: .idle, text: "Random choice", textLanguage: "en")
        var presentation = StateDialoguePresentation(
            id: requestID,
            state: .idle,
            lineID: fallbackLine.id,
            lineRevision: fallbackLine.revision,
            text: fallbackLine.text,
            audioDisposition: .pending
        )

        XCTAssertTrue(presentation.recordAutomaticPlaybackStarted(spokenLine))
        XCTAssertEqual(presentation.lineID, spokenLine.id)
        XCTAssertEqual(presentation.text, spokenLine.text)
        XCTAssertEqual(presentation.audioDisposition, .delivered)

        let editedSpokenLine = try DialogueLine(
            id: spokenLine.id,
            state: .idle,
            text: "Edited while old audio was playing",
            textLanguage: "en",
            revision: spokenLine.revision + 1,
            status: .draft
        )
        XCTAssertEqual(
            presentation.recordAutomaticPlaybackFinished(
                requestID: requestID,
                lineID: spokenLine.id,
                replacementLine: editedSpokenLine
            ),
            .updated
        )
        XCTAssertEqual(presentation.text, editedSpokenLine.text)
        XCTAssertEqual(presentation.audioDisposition, .pending)

        let nextRequestID = UUID()
        let runningLine = try DialogueLine(state: .running, text: "New state", textLanguage: "en")
        var nextPresentation = StateDialoguePresentation(
            id: nextRequestID,
            state: .running,
            lineID: runningLine.id,
            lineRevision: runningLine.revision,
            text: runningLine.text,
            audioDisposition: .deferred
        )
        XCTAssertEqual(
            nextPresentation.recordAutomaticPlaybackFinished(
                requestID: requestID,
                lineID: spokenLine.id,
                replacementLine: runningLine
            ),
            .revealCurrent
        )
        XCTAssertEqual(nextPresentation.text, runningLine.text)
        XCTAssertEqual(nextPresentation.audioDisposition, .deferred)
    }

    func testWAVValidationRejectsMalformedGeometryAndTrailingData() {
        let valid = pcmWAV()
        XCTAssertTrue(GPTSoVITSAPIClient.isValidWAV(valid))

        var invalidAlignment = valid
        invalidAlignment[32] = 1
        XCTAssertFalse(GPTSoVITSAPIClient.isValidWAV(invalidAlignment))

        var trailing = valid
        trailing.append(0)
        XCTAssertFalse(GPTSoVITSAPIClient.isValidWAV(trailing))
    }

    func testQwenWAVValidationRequiresPCM16Mono24000AndBoundedDuration() {
        let valid = qwenPCM24kWAV(sampleFrames: 24_000)
        XCTAssertTrue(Qwen3TTSClient.isValidOutputWAV(valid))

        var stereo = valid
        stereo[22] = 2
        stereo[28] = 0x00
        stereo[29] = 0x77 // 96,000 byte rate
        stereo[32] = 4
        XCTAssertFalse(Qwen3TTSClient.isValidOutputWAV(stereo))

        var wrongRate = valid
        wrongRate[24] = 0x80
        wrongRate[25] = 0x3e // 16,000 Hz
        wrongRate[28] = 0x00
        wrongRate[29] = 0x7d // 32,000 byte rate
        XCTAssertFalse(Qwen3TTSClient.isValidOutputWAV(wrongRate))
        XCTAssertFalse(Qwen3TTSClient.isValidOutputWAV(qwenPCM24kWAV(sampleFrames: 24_000 * 60 + 1)))
    }

    func testQwenSynthesisUsesStdinAndScrubbedOfflineEnvironment() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeQwenFixture(root: root)
        let captured = LockedQwenInvocation()
        let client = Qwen3TTSClient(helperExecutableURL: fixture.helper) { invocation in
            captured.set(invocation)
            try self.qwenPCM24kWAV(sampleFrames: 2_400).write(to: invocation.outputURL)
        }
        let line = try DialogueLine(text: "private sentence", textLanguage: "JA_jp")
        let data = try await client.synthesize(
            profile: fixture.profile,
            line: line,
            applicationSupportRoot: root
        )
        XCTAssertTrue(Qwen3TTSClient.isValidOutputWAV(data))
        let invocation = try XCTUnwrap(captured.value)
        XCTAssertEqual(invocation.executableURL, fixture.python)
        XCTAssertEqual(invocation.environment["HF_HUB_OFFLINE"], "1")
        XCTAssertEqual(invocation.environment["TRANSFORMERS_OFFLINE"], "1")
        XCTAssertNil(invocation.environment["SSH_AUTH_SOCK"])
        XCTAssertNotEqual(invocation.helperURL, root.appendingPathComponent(
            fixture.profile.packageRootRelativePath + "/" + fixture.profile.handoverGeneratorRelativePath
        ))
        XCTAssertFalse(invocation.executableURL.path.contains("private sentence"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: invocation.standardInput) as? [String: Any])
        XCTAssertEqual(body["text"] as? String, "private sentence")
        XCTAssertEqual(body["text_language"] as? String, "japanese")
        XCTAssertEqual(body["reference_language"] as? String, "japanese")
    }

    func testQwenJapaneseLanguageAliasesAreBoundedAndCanonical() {
        for alias in ["japanese", "JAPANESE", "ja", "JA", "ja-JP", "JA_jp"] {
            XCTAssertEqual(Qwen3TTSLanguage.canonicalJapanese(alias), "japanese")
            XCTAssertTrue(Qwen3TTSLanguage.areJapaneseAliases(alias, "japanese"))
        }
        for unsupported in ["jp", "ja-JP-extra", "en", "chinese", ""] {
            XCTAssertNil(Qwen3TTSLanguage.canonicalJapanese(unsupported))
            XCTAssertFalse(Qwen3TTSLanguage.areJapaneseAliases(unsupported, "japanese"))
        }
    }

    func testQwenSynthesisRejectsNonJapaneseLanguage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeQwenFixture(root: root)
        let captured = LockedQwenInvocation()
        let client = Qwen3TTSClient(helperExecutableURL: fixture.helper) { invocation in
            captured.set(invocation)
        }
        let line = try DialogueLine(text: "private sentence", textLanguage: "en")

        do {
            _ = try await client.synthesize(
                profile: fixture.profile,
                line: line,
                applicationSupportRoot: root
            )
            XCTFail("A non-Japanese Qwen request was accepted")
        } catch let error as DialogueVoiceRuntimeError {
            XCTAssertEqual(error, .requestRejected)
        }
        XCTAssertNil(captured.value)
    }

    func testQwenPackageTreeDigestChangesWithNestedModelFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeQwenFixture(root: root)
        let package = root.appendingPathComponent(fixture.profile.packageRootRelativePath)
        let tokenizer = package.appendingPathComponent("model/speech_tokenizer/model.safetensors")
        try FileManager.default.createDirectory(
            at: tokenizer.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("tokenizer-a".utf8).write(to: tokenizer)
        let first = try Qwen3TTSProfileValidator.computePackageTreeSHA256(packageRoot: package)
        try Data("tokenizer-b".utf8).write(to: tokenizer)
        let second = try Qwen3TTSProfileValidator.computePackageTreeSHA256(packageRoot: package)
        XCTAssertNotEqual(first, second)
    }

    func testQwenPackageInstallerBindsFullTreeAndRemovesPrivateCopy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen-package-installer-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("handover", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try makeSyntheticQwenHandover(at: source)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let installer = Qwen3TTSPackageInstaller(applicationSupportRoot: support)
        let imported = try installer.install(sourceURL: source)
        let managedRoot = support.appendingPathComponent(
            imported.packageRootRelativePath,
            isDirectory: true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedRoot.path))
        XCTAssertEqual(
            imported.treeSHA256,
            try Qwen3TTSProfileValidator.computePackageTreeSHA256(packageRoot: managedRoot)
        )
        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: managedRoot.path)[.posixPermissions]
                as? NSNumber
        ).intValue & 0o777
        let modelMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: managedRoot.appendingPathComponent("model/model.safetensors").path
            )[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        XCTAssertEqual(directoryMode, 0o700)
        XCTAssertEqual(modelMode, 0o600)

        let runtime = try Qwen3TTSProfileValidator.validatePythonExecutable(
            at: URL(fileURLWithPath: "/bin/sh")
        )
        let provisional = try Qwen3TTSVoiceProfile(
            name: "Synthetic Qwen",
            packageRootRelativePath: imported.packageRootRelativePath,
            pythonExecutablePath: runtime.invocationPath,
            pythonExecutableSHA256: runtime.finalTargetSHA256,
            packageTreeSHA256: imported.treeSHA256,
            manifest: imported.manifest,
            referenceText: imported.referenceText,
            referenceLanguage: imported.referenceLanguage,
            defaultTextLanguage: imported.referenceLanguage,
            parameters: imported.parameters,
            inputFingerprint: String(repeating: "0", count: 64)
        )
        let profile = try Qwen3TTSVoiceProfile(
            id: provisional.id,
            revision: provisional.revision,
            name: provisional.name,
            packageRootRelativePath: provisional.packageRootRelativePath,
            pythonExecutablePath: provisional.pythonExecutablePath,
            pythonExecutableSHA256: provisional.pythonExecutableSHA256,
            packageTreeSHA256: provisional.packageTreeSHA256,
            manifest: provisional.manifest,
            referenceText: provisional.referenceText,
            referenceLanguage: provisional.referenceLanguage,
            defaultTextLanguage: provisional.defaultTextLanguage,
            parameters: provisional.parameters,
            inputFingerprint: Qwen3TTSProfileValidator.computeInputFingerprint(
                components: provisional.inputFingerprintComponents
            )
        )
        XCTAssertNoThrow(try Qwen3TTSProfileValidator.validate(
            profile: profile,
            applicationSupportRoot: support
        ))

        try Data("changed-tokenizer".utf8).write(
            to: managedRoot.appendingPathComponent("model/tokenizer_config.json")
        )
        XCTAssertThrowsError(try Qwen3TTSProfileValidator.validate(
            profile: profile,
            applicationSupportRoot: support
        )) { error in
            XCTAssertEqual(error as? DialogueVoiceRuntimeError, .inputFingerprintMismatch)
        }

        XCTAssertNoThrow(try installer.removeManagedPackage(
            relativePath: imported.packageRootRelativePath
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: managedRoot.path))
    }

    func testQwenPackageSizeAccumulatorRejectsOverflowAndConfiguredLimit() throws {
        XCTAssertThrowsError(
            try Qwen3TTSPackageInstaller.checkedAggregateSize(
                [UInt64.max, 1],
                maximum: UInt64.max
            )
        ) { error in
            XCTAssertEqual(error as? DialogueVoiceRuntimeError, .sourceTooLarge)
        }
        XCTAssertThrowsError(
            try Qwen3TTSPackageInstaller.checkedAggregateSize([3, 3], maximum: 5)
        ) { error in
            XCTAssertEqual(error as? DialogueVoiceRuntimeError, .sourceTooLarge)
        }
        XCTAssertEqual(
            try Qwen3TTSPackageInstaller.checkedAggregateSize([2, 3], maximum: 5),
            5
        )
    }

    func testQwenPackageInstallerRemovesJournaledPartialTree() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen-partial-cleanup-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        let token = UUID().uuidString.lowercased()
        let paths = try Qwen3TTSPackageInstaller.managedRelativePaths(destinationToken: token)
        let partial = support.appendingPathComponent(paths.staging, isDirectory: true)
        let nested = partial.appendingPathComponent("model/partial.bin")
        try FileManager.default.createDirectory(
            at: nested.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: nested)

        let installer = Qwen3TTSPackageInstaller(applicationSupportRoot: support)
        XCTAssertNoThrow(try installer.removeManagedPackage(relativePath: paths.staging))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testQwenPackageRemovalNeverFollowsSymbolicLinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen-package-removal-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("handover", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let outside = root.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("outside-sentinel".utf8).write(to: outside)
        try makeSyntheticQwenHandover(at: source)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let installer = Qwen3TTSPackageInstaller(applicationSupportRoot: support)
        let imported = try installer.install(sourceURL: source)
        let managedRoot = support.appendingPathComponent(imported.packageRootRelativePath)
        let escape = managedRoot.appendingPathComponent("model/escape")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)

        XCTAssertThrowsError(try installer.removeManagedPackage(
            relativePath: imported.packageRootRelativePath
        ))
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside-sentinel".utf8))
    }

    func testQwenRuntimeProbeRejectsNonPythonExecutable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen-runtime-probe-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeQwenFixture(root: root)
        let client = Qwen3TTSClient(
            helperExecutableURL: fixture.helper,
            probeExecutableURL: fixture.helper
        )
        do {
            try await client.validateProfile(
                fixture.profile,
                applicationSupportRoot: root
            )
            XCTFail("A non-Python executable passed the Qwen dependency probe")
        } catch let error as DialogueVoiceRuntimeError {
            XCTAssertEqual(error, .inferenceUnavailable)
        }
    }

    func testQwenProcessRunnerCompletesContainedSilentProbeAfterStdinHandshake() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen-fast-probe-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let probe = root.appendingPathComponent("probe.py")
        try Data(
            "import os, sys\n"
                .appending("assert os.getpgrp() == os.getpid()\n")
                .appending("sys.stdin.buffer.read()\n")
                .utf8
        ).write(to: probe)
        let marker = root.appendingPathComponent("not-required")

        try await Qwen3TTSProcessRunner().run(Qwen3TTSProcessInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            helperURL: probe,
            currentDirectoryURL: root,
            environment: ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"],
            standardInput: Data(),
            outputURL: marker,
            timeout: 5,
            requiresOutputFile: false
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testQwenProcessRunnerKillsAndReapsTermResistantProcessGroup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen-resistant-probe-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let probe = root.appendingPathComponent("probe.py")
        let parentPID = root.appendingPathComponent("parent.pid")
        let childPID = root.appendingPathComponent("child.pid")
        try Data(
            "import os, signal, sys, time\n"
                .appending("signal.signal(signal.SIGTERM, signal.SIG_IGN)\n")
                .appending("open('parent.pid','w').write(str(os.getpid()))\n")
                .appending("pid = os.fork()\n")
                .appending("if pid == 0:\n")
                .appending(" signal.signal(signal.SIGTERM, signal.SIG_IGN)\n")
                .appending(" open('child.pid','w').write(str(os.getpid()))\n")
                .appending(" while True: time.sleep(1)\n")
                .appending("sys.stdin.buffer.read()\n")
                .appending("while True: time.sleep(1)\n")
                .utf8
        ).write(to: probe)

        do {
            try await Qwen3TTSProcessRunner().run(Qwen3TTSProcessInvocation(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                helperURL: probe,
                currentDirectoryURL: root,
                environment: ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"],
                standardInput: Data(), outputURL: root.appendingPathComponent("unused"),
                timeout: 1, requiresOutputFile: false
            ))
            XCTFail("A TERM-resistant process completed successfully")
        } catch let error as DialogueVoiceRuntimeError {
            XCTAssertEqual(error, .inferenceUnavailable)
        }

        let publishedParent = try XCTUnwrap(readPublishedPID(parentPID))
        let publishedChild = try XCTUnwrap(readPublishedPID(childPID))
        XCTAssertTrue(waitForProcessExit(publishedParent), "parent remained alive or unreaped")
        XCTAssertTrue(waitForProcessExit(publishedChild), "grandchild remained alive after group SIGKILL")
    }

    func testQwenProcessRunnerReapsChildWhenContainmentIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen-containment-rejection-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let probe = root.appendingPathComponent("probe.py")
        let parentPID = root.appendingPathComponent("parent.pid")
        let childPID = root.appendingPathComponent("child.pid")
        try Data(
            "import os, signal, time\n"
                .appending("signal.signal(signal.SIGTERM, signal.SIG_IGN)\n")
                .appending("open('parent.pid','w').write(str(os.getpid()))\n")
                .appending("pid = os.fork()\n")
                .appending("if pid == 0:\n")
                .appending(" signal.signal(signal.SIGTERM, signal.SIG_IGN)\n")
                .appending(" open('child.pid','w').write(str(os.getpid()))\n")
                .appending(" while True: time.sleep(1)\n")
                .appending("while True: time.sleep(1)\n")
                .utf8
        ).write(to: probe)

        do {
            try await Qwen3TTSProcessRunner(processGroupValidator: { _ in false }).run(
                Qwen3TTSProcessInvocation(
                    executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                    helperURL: probe,
                    currentDirectoryURL: root,
                    environment: ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"],
                    standardInput: Data(), outputURL: root.appendingPathComponent("unused"),
                    timeout: 5, requiresOutputFile: false
                )
            )
            XCTFail("A process without accepted containment completed successfully")
        } catch let error as DialogueVoiceRuntimeError {
            XCTAssertEqual(error, .inferenceUnavailable)
        }

        let publishedParent = try XCTUnwrap(readPublishedPID(parentPID))
        let publishedChild = try XCTUnwrap(readPublishedPID(childPID))
        XCTAssertTrue(waitForProcessExit(publishedParent), "rejected child remained alive or unreaped")
        XCTAssertTrue(waitForProcessExit(publishedChild), "rejected descendant escaped cleanup")
    }

    func testQwenProcessRunnerCancellationReapsContainedChild() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen-cancelled-probe-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let probe = root.appendingPathComponent("probe.py")
        let parentPID = root.appendingPathComponent("parent.pid")
        try Data(
            "import os, signal, time\n"
                .appending("signal.signal(signal.SIGTERM, signal.SIG_IGN)\n")
                .appending("open('parent.pid','w').write(str(os.getpid()))\n")
                .appending("while True: time.sleep(1)\n")
                .utf8
        ).write(to: probe)

        let invocation = Qwen3TTSProcessInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            helperURL: probe,
            currentDirectoryURL: root,
            environment: ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"],
            standardInput: Data(), outputURL: root.appendingPathComponent("unused"),
            timeout: 30, requiresOutputFile: false
        )
        let task = Task { try await Qwen3TTSProcessRunner().run(invocation) }
        let publicationDeadline = Date().addingTimeInterval(2)
        while readPublishedPID(parentPID) == nil, Date() < publicationDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let publishedParent = try XCTUnwrap(readPublishedPID(parentPID))
        task.cancel()
        do {
            try await task.value
            XCTFail("A cancelled Qwen process completed successfully")
        } catch let error as DialogueVoiceRuntimeError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertTrue(waitForProcessExit(publishedParent), "cancelled child remained alive or unreaped")
    }

    func testQwenProcessRunnerKillsDescendantAfterSuccessfulLeaderExit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen-orphan-probe-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let probe = root.appendingPathComponent("probe.py")
        let childPID = root.appendingPathComponent("child.pid")
        try Data(
            "import os, signal, time\n"
                .appending("child = os.fork()\n")
                .appending("if child == 0:\n")
                .appending(" signal.signal(signal.SIGTERM, signal.SIG_IGN)\n")
                .appending(" open('child.pid','w').write(str(os.getpid()))\n")
                .appending(" while True: time.sleep(1)\n")
                .appending("deadline = time.time() + 2\n")
                .appending("while not os.path.exists('child.pid') and time.time() < deadline: time.sleep(0.01)\n")
                .utf8
        ).write(to: probe)

        do {
            try await Qwen3TTSProcessRunner().run(Qwen3TTSProcessInvocation(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                helperURL: probe,
                currentDirectoryURL: root,
                environment: ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"],
                standardInput: Data(), outputURL: root.appendingPathComponent("unused"),
                timeout: 5, requiresOutputFile: false
            ))
            XCTFail("A successful leader left a descendant but was accepted")
        } catch let error as DialogueVoiceRuntimeError {
            XCTAssertEqual(error, .inferenceUnavailable)
        }
        let publishedChild = try XCTUnwrap(readPublishedPID(childPID))
        XCTAssertTrue(waitForProcessExit(publishedChild), "leader descendant escaped finalization")
    }

    func testQwenPythonRuntimeIdentityPreservesRegularAndAbsoluteSymlinkInvocation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("python-real")
        let launcher = root.appendingPathComponent("python-venv")
        try Data("fixture python".utf8).write(to: executable)
        XCTAssertEqual(chmod(executable.path, 0o700), 0)
        XCTAssertEqual(symlink(executable.path, launcher.path), 0)

        let regular = try Qwen3TTSProfileValidator.validatePythonExecutable(at: executable)
        let linked = try Qwen3TTSProfileValidator.validatePythonExecutable(at: launcher)
        XCTAssertEqual(regular.invocationPath, executable.path)
        XCTAssertEqual(linked.invocationPath, launcher.path)
        XCTAssertEqual(regular.finalTargetSHA256, linked.finalTargetSHA256)
        XCTAssertNotEqual(regular.stableIdentityToken, linked.stableIdentityToken)
        XCTAssertEqual(
            Qwen3TTSProfileValidator.computeInputFingerprint(components: ["a", "bc"]),
            Qwen3TTSProfileValidator.computeInputFingerprint(components: ["a", "bc"])
        )
    }

    func testFingerprintIsStableAndChangesWithEverySynthesisInput() throws {
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:9880"))
        let digests = DialogueVoiceAssetDigests(
            gptWeight: String(repeating: "1", count: 64),
            sovitsWeight: String(repeating: "2", count: 64),
            referenceAudio: String(repeating: "3", count: 64)
        )
        let baseline = DialogueVoiceProfileFingerprint.compute(
            apiBaseURL: endpoint,
            referenceText: "Reference",
            promptLanguage: "en",
            defaultTextLanguage: "en",
            assetDigests: digests
        )
        XCTAssertEqual(baseline.count, 64)
        XCTAssertEqual(
            baseline,
            DialogueVoiceProfileFingerprint.compute(
                apiBaseURL: endpoint,
                referenceText: "Reference",
                promptLanguage: "en",
                defaultTextLanguage: "en",
                assetDigests: digests
            )
        )
        XCTAssertNotEqual(
            baseline,
            DialogueVoiceProfileFingerprint.compute(
                apiBaseURL: endpoint,
                referenceText: "Changed",
                promptLanguage: "en",
                defaultTextLanguage: "en",
                assetDigests: digests
            )
        )
        XCTAssertNotEqual(
            baseline,
            DialogueVoiceProfileFingerprint.compute(
                apiBaseURL: endpoint,
                referenceText: "Reference",
                promptLanguage: "en",
                defaultTextLanguage: "en",
                assetDigests: DialogueVoiceAssetDigests(
                    gptWeight: String(repeating: "4", count: 64),
                    sovitsWeight: digests.sovitsWeight,
                    referenceAudio: digests.referenceAudio
                )
            )
        )
    }

    func testDescriptorRelativeCleanupRejectsIntermediateSymlink() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("dialogue-runtime-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("root", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = outside.appendingPathComponent("private.wav")
        try pcmWAV().write(to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("voice", isDirectory: true),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try DialogueVoiceAssetInstaller.removeManagedFile(
            relativePath: "voice/private.wav",
            root: root,
            maximumBytes: 1_024 * 1_024
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    func testReferenceAudioMustDecodeAndManagedIdentityDetectsMutation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dialogue-audio-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let referenceDirectory = root
            .appendingPathComponent("voice/assets/reference", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceDirectory, withIntermediateDirectories: true)
        let relativePath = "voice/assets/reference/test.wav"
        let file = root.appendingPathComponent(relativePath)
        try Data("not audio".utf8).write(to: file)
        XCTAssertThrowsError(try DialogueVoiceAssetInstaller.validateReferenceAudio(
            relativePath: relativePath,
            root: root
        )) {
            XCTAssertEqual($0 as? DialogueVoiceRuntimeError, .invalidReferenceAudio)
        }

        try pcmWAV().write(to: file)
        XCTAssertNoThrow(try DialogueVoiceAssetInstaller.validateReferenceAudio(
            relativePath: relativePath,
            root: root
        ))
        let originalIdentity = try DialogueVoiceAssetInstaller.managedFileIdentity(
            relativePath: relativePath,
            root: root,
            maximumBytes: 1_024 * 1_024
        )
        var changed = pcmWAV()
        changed.append(contentsOf: [0, 0])
        try changed.write(to: file)
        let changedIdentity = try DialogueVoiceAssetInstaller.managedFileIdentity(
            relativePath: relativePath,
            root: root,
            maximumBytes: 1_024 * 1_024
        )
        XCTAssertNotEqual(originalIdentity, changedIdentity)
    }

    func testBoundedRequestCancelsWhenChunkedResponseExceedsLimit() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedURLProtocol.self]
        let request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1/test")))
        do {
            _ = try await DialogueVoiceBoundedRequest(maximumBytes: 5)
                .perform(request, configuration: configuration)
            XCTFail("oversized chunked response was accepted")
        } catch {
            XCTAssertEqual(error as? DialogueVoiceRuntimeError, .responseTooLarge)
        }
    }

    @MainActor
    func testCoordinatorPersistsImportedAssetCleanupAndRemovesItOnShutdownBeforeSave() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dialogue-import-shutdown-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ckpt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("first model".utf8).write(to: source)

        let coordinator = DialogueVoiceCoordinator(applicationSupportRoot: root)
        coordinator.start()
        let imported = expectation(description: "asset is imported")
        coordinator.onChange = { snapshot in
            if snapshot.importedAssets.gptWeightRelativePath != nil {
                imported.fulfill()
            }
        }
        coordinator.importAsset(
            sourceURL: source,
            kind: .gptWeight,
            preserving: coordinator.draft
        )
        await fulfillment(of: [imported], timeout: 5)

        let relativePath = try XCTUnwrap(coordinator.importedAssets.gptWeightRelativePath)
        let store = DialogueVoiceStore(rootURL: root.appendingPathComponent("voice", isDirectory: true))
        XCTAssertEqual(try store.load().pendingCleanupPaths, [relativePath])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path))

        coordinator.shutdown()

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path))
        XCTAssertTrue(try store.load().pendingCleanupPaths.isEmpty)
    }

    @MainActor
    func testCoordinatorCleansReplacedImportButPreservesCurrentImportUntilShutdown() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dialogue-import-replacement-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let firstSource = root.appendingPathComponent("first.ckpt")
        let secondSource = root.appendingPathComponent("second.ckpt")
        try Data("first model".utf8).write(to: firstSource)
        try Data("second model".utf8).write(to: secondSource)

        let coordinator = DialogueVoiceCoordinator(applicationSupportRoot: root)
        coordinator.start()
        let firstImported = expectation(description: "first asset is imported")
        coordinator.onChange = { snapshot in
            if snapshot.importedAssets.gptWeightRelativePath != nil {
                firstImported.fulfill()
            }
        }
        coordinator.importAsset(
            sourceURL: firstSource,
            kind: .gptWeight,
            preserving: coordinator.draft
        )
        await fulfillment(of: [firstImported], timeout: 5)
        let firstPath = try XCTUnwrap(coordinator.importedAssets.gptWeightRelativePath)

        let secondImported = expectation(description: "replacement asset is imported")
        coordinator.onChange = { snapshot in
            if let path = snapshot.importedAssets.gptWeightRelativePath, path != firstPath {
                secondImported.fulfill()
            }
        }
        coordinator.importAsset(
            sourceURL: secondSource,
            kind: .gptWeight,
            preserving: coordinator.draft
        )
        await fulfillment(of: [secondImported], timeout: 5)
        let secondPath = try XCTUnwrap(coordinator.importedAssets.gptWeightRelativePath)
        let store = DialogueVoiceStore(rootURL: root.appendingPathComponent("voice", isDirectory: true))

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(firstPath).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(secondPath).path))
        XCTAssertEqual(try store.load().pendingCleanupPaths, [secondPath])

        coordinator.shutdown()
    }

    @MainActor
    func testDialogueCleanupOperationPreservesCurrentStagedImport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dialogue-import-preservation-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.ckpt")
        try Data("staged model".utf8).write(to: source)

        let coordinator = DialogueVoiceCoordinator(applicationSupportRoot: root)
        coordinator.start()
        try coordinator.addLine(text: "Before", language: "en", state: .running)
        let lineID = try XCTUnwrap(coordinator.library.lines.first?.id)
        XCTAssertEqual(coordinator.library.lines.first?.state, .running)
        let imported = expectation(description: "asset is imported")
        coordinator.onChange = { snapshot in
            if snapshot.importedAssets.gptWeightRelativePath != nil {
                imported.fulfill()
            }
        }
        coordinator.importAsset(
            sourceURL: source,
            kind: .gptWeight,
            preserving: coordinator.draft
        )
        await fulfillment(of: [imported], timeout: 5)
        coordinator.onChange = nil
        let relativePath = try XCTUnwrap(coordinator.importedAssets.gptWeightRelativePath)

        try coordinator.updateLine(
            id: lineID,
            text: "After",
            language: "en",
            state: .review
        )
        XCTAssertEqual(coordinator.library.lines.first?.state, .review)

        let store = DialogueVoiceStore(rootURL: root.appendingPathComponent("voice", isDirectory: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path))
        XCTAssertEqual(try store.load().pendingCleanupPaths, [relativePath])
        coordinator.shutdown()
    }

    @MainActor
    func testCoordinatorStartupCleansPersistedStagedImportFromPriorRun() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dialogue-import-restart-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.ckpt")
        try Data("orphaned staged model".utf8).write(to: source)

        let firstCoordinator = DialogueVoiceCoordinator(applicationSupportRoot: root)
        firstCoordinator.start()
        let imported = expectation(description: "asset is imported before simulated crash")
        firstCoordinator.onChange = { snapshot in
            if snapshot.importedAssets.gptWeightRelativePath != nil {
                imported.fulfill()
            }
        }
        firstCoordinator.importAsset(
            sourceURL: source,
            kind: .gptWeight,
            preserving: firstCoordinator.draft
        )
        await fulfillment(of: [imported], timeout: 5)
        let relativePath = try XCTUnwrap(firstCoordinator.importedAssets.gptWeightRelativePath)
        let store = DialogueVoiceStore(rootURL: root.appendingPathComponent("voice", isDirectory: true))
        XCTAssertEqual(try store.load().pendingCleanupPaths, [relativePath])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path))

        let restartedCoordinator = DialogueVoiceCoordinator(applicationSupportRoot: root)
        restartedCoordinator.start()

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(relativePath).path))
        XCTAssertTrue(try store.load().pendingCleanupPaths.isEmpty)
        restartedCoordinator.shutdown()
        firstCoordinator.shutdown()
    }

    @MainActor
    func testRetryStaleLineWhenProfileIsUnavailableReactivatesAndProcessesIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dialogue-unavailable-retry-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = (
            gpt: "voice/assets/gpt/test.ckpt",
            sovits: "voice/assets/sovits/test.pth",
            reference: "voice/assets/reference/test.wav",
            firstOutput: "voice/generated/stale-first.wav",
            secondOutput: "voice/generated/stale-second.wav"
        )
        let secondLineID = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
        for relativeDirectory in [
            "voice/assets/gpt",
            "voice/assets/sovits",
            "voice/assets/reference",
            "voice/generated",
        ] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(relativeDirectory, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Data("gpt".utf8).write(to: root.appendingPathComponent(paths.gpt))
        try Data("sovits".utf8).write(to: root.appendingPathComponent(paths.sovits))
        try pcmWAV().write(to: root.appendingPathComponent(paths.reference))
        try pcmWAV().write(to: root.appendingPathComponent(paths.firstOutput))
        try pcmWAV().write(to: root.appendingPathComponent(paths.secondOutput))

        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:9880"))
        let provisionalProfile = try GPTSoVITSVoiceProfile(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Retry voice",
            apiBaseURL: endpoint,
            gptWeightRelativePath: paths.gpt,
            sovitsWeightRelativePath: paths.sovits,
            referenceAudioRelativePath: paths.reference,
            referenceText: "Reference",
            promptLanguage: "en",
            defaultTextLanguage: "en",
            inputFingerprint: String(repeating: "0", count: 64)
        )
        let validated = try DialogueVoiceProfileFingerprint.validateAssets(
            profile: provisionalProfile,
            applicationSupportRoot: root
        )
        let profile = try GPTSoVITSVoiceProfile(
            id: provisionalProfile.id,
            name: provisionalProfile.name,
            apiBaseURL: endpoint,
            gptWeightRelativePath: paths.gpt,
            sovitsWeightRelativePath: paths.sovits,
            referenceAudioRelativePath: paths.reference,
            referenceText: provisionalProfile.referenceText,
            promptLanguage: provisionalProfile.promptLanguage,
            defaultTextLanguage: provisionalProfile.defaultTextLanguage,
            inputFingerprint: DialogueVoiceProfileFingerprint.compute(
                apiBaseURL: endpoint,
                referenceText: provisionalProfile.referenceText,
                promptLanguage: provisionalProfile.promptLanguage,
                defaultTextLanguage: provisionalProfile.defaultTextLanguage,
                assetDigests: validated.digests
            )
        )
        var library = try DialogueVoiceLibrary(profile: profile)
        _ = try library.addLine(text: "Retry me", id: lineID)
        let firstTicket = try library.beginGeneration(for: lineID)
        _ = try library.completeGeneration(ticket: firstTicket, outputPath: paths.firstOutput)
        _ = try library.addLine(text: "Reactivate me too", id: secondLineID)
        let secondTicket = try library.beginGeneration(for: secondLineID)
        _ = try library.completeGeneration(ticket: secondTicket, outputPath: paths.secondOutput)
        try library.setProfileStatus(.unavailable, invalidatingOutputs: true)
        let store = DialogueVoiceStore(
            rootURL: root.appendingPathComponent("voice", isDirectory: true)
        )
        try store.save(library)

        UnavailableThenSuccessfulGPTSoVITSURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnavailableThenSuccessfulGPTSoVITSURLProtocol.self]
        let coordinator = DialogueVoiceCoordinator(
            applicationSupportRoot: root,
            client: GPTSoVITSAPIClient(configuration: configuration)
        )
        defer { coordinator.shutdown() }
        let unavailable = expectation(description: "saved profile becomes unavailable")
        coordinator.onChange = { snapshot in
            guard snapshot.library.profileStatus == .unavailable,
                  snapshot.library.lines.count == 2,
                  snapshot.library.lines.allSatisfy({ $0.status == .stale }) else {
                return
            }
            unavailable.fulfill()
        }
        coordinator.start()
        await fulfillment(of: [unavailable], timeout: 5)

        let generated = expectation(description: "stale retry is processed")
        coordinator.onChange = { snapshot in
            guard snapshot.library.lines.count == 2,
                  snapshot.library.lines.allSatisfy({ $0.status == .ready }) else {
                return
            }
            generated.fulfill()
        }
        try coordinator.retryLine(id: lineID)
        await fulfillment(of: [generated], timeout: 10)

        let readyLine = try XCTUnwrap(
            coordinator.library.lines.first(where: { $0.id == lineID })
        )
        XCTAssertEqual(readyLine.status, .ready)
        let secondReadyLine = try XCTUnwrap(
            coordinator.library.lines.first(where: { $0.id == secondLineID })
        )
        XCTAssertEqual(secondReadyLine.status, .ready)
        XCTAssertNotEqual(readyLine.outputRelativePath, paths.firstOutput)
        XCTAssertNotEqual(secondReadyLine.outputRelativePath, paths.secondOutput)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(paths.firstOutput).path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(paths.secondOutput).path)
        )
        XCTAssertTrue(try store.load().pendingCleanupPaths.isEmpty)
    }

    @MainActor
    func testSavingReplacementProfileWithReadyOutputCleansPreviousWAV() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dialogue-profile-replacement-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = (
            gpt: "voice/assets/gpt/test.ckpt",
            sovits: "voice/assets/sovits/test.pth",
            reference: "voice/assets/reference/test.wav",
            output: "voice/generated/previous.wav"
        )
        for relativeDirectory in [
            "voice/assets/gpt",
            "voice/assets/sovits",
            "voice/assets/reference",
            "voice/generated",
        ] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(relativeDirectory, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Data("gpt".utf8).write(to: root.appendingPathComponent(paths.gpt))
        try Data("sovits".utf8).write(to: root.appendingPathComponent(paths.sovits))
        try pcmWAV().write(to: root.appendingPathComponent(paths.reference))
        try pcmWAV().write(to: root.appendingPathComponent(paths.output))

        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:9880"))
        let provisionalProfile = try GPTSoVITSVoiceProfile(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Original voice",
            apiBaseURL: endpoint,
            gptWeightRelativePath: paths.gpt,
            sovitsWeightRelativePath: paths.sovits,
            referenceAudioRelativePath: paths.reference,
            referenceText: "Reference",
            promptLanguage: "en",
            defaultTextLanguage: "en",
            inputFingerprint: String(repeating: "0", count: 64)
        )
        let validated = try DialogueVoiceProfileFingerprint.validateAssets(
            profile: provisionalProfile,
            applicationSupportRoot: root
        )
        let profile = try GPTSoVITSVoiceProfile(
            id: provisionalProfile.id,
            name: provisionalProfile.name,
            apiBaseURL: endpoint,
            gptWeightRelativePath: paths.gpt,
            sovitsWeightRelativePath: paths.sovits,
            referenceAudioRelativePath: paths.reference,
            referenceText: provisionalProfile.referenceText,
            promptLanguage: provisionalProfile.promptLanguage,
            defaultTextLanguage: provisionalProfile.defaultTextLanguage,
            inputFingerprint: DialogueVoiceProfileFingerprint.compute(
                apiBaseURL: endpoint,
                referenceText: provisionalProfile.referenceText,
                promptLanguage: provisionalProfile.promptLanguage,
                defaultTextLanguage: provisionalProfile.defaultTextLanguage,
                assetDigests: validated.digests
            )
        )
        var library = try DialogueVoiceLibrary(profile: profile)
        _ = try library.addLine(text: "Existing generated line", id: lineID)
        let ticket = try library.beginGeneration(for: lineID)
        _ = try library.completeGeneration(ticket: ticket, outputPath: paths.output)
        let store = DialogueVoiceStore(
            rootURL: root.appendingPathComponent("voice", isDirectory: true)
        )
        try store.save(library)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuccessfulGPTSoVITSURLProtocol.self]
        let coordinator = DialogueVoiceCoordinator(
            applicationSupportRoot: root,
            client: GPTSoVITSAPIClient(configuration: configuration),
            audioPlayer: FakePlayer()
        )
        defer { coordinator.shutdown() }
        let validatedProfile = expectation(description: "saved profile validates")
        var fulfilled = false
        coordinator.onChange = { snapshot in
            guard !fulfilled,
                  snapshot.library.profileStatus == .ready,
                  snapshot.library.lines.first?.status == .ready else { return }
            fulfilled = true
            validatedProfile.fulfill()
        }
        coordinator.start()
        await fulfillment(of: [validatedProfile], timeout: 5)

        XCTAssertNoThrow(try coordinator.saveProfile(DialogueVoiceProfileDraft(
            name: "Replacement voice",
            apiBaseURL: endpoint.absoluteString,
            promptLanguage: "en",
            defaultTextLanguage: "en",
            referenceText: "Reference"
        )))
        XCTAssertEqual(coordinator.library.profile?.revision, 2)
        XCTAssertEqual(coordinator.library.profileStatus, .validating)
        XCTAssertEqual(coordinator.library.lines.first?.status, .queued)
        XCTAssertNil(coordinator.library.lines.first?.outputRelativePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(paths.output).path))
        XCTAssertFalse(try store.load().pendingCleanupPaths.contains(paths.output))
    }

    @MainActor
    func testCoordinatorRestoresQueuedLineGeneratesPublishesAndPlaysReadyAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dialogue-coordinator-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = (
            gpt: "voice/assets/gpt/test.ckpt",
            sovits: "voice/assets/sovits/test.pth",
            reference: "voice/assets/reference/test.wav"
        )
        for relativeDirectory in [
            "voice/assets/gpt",
            "voice/assets/sovits",
            "voice/assets/reference",
        ] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(relativeDirectory, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Data("gpt".utf8).write(to: root.appendingPathComponent(paths.gpt))
        try Data("sovits".utf8).write(to: root.appendingPathComponent(paths.sovits))
        try pcmWAV().write(to: root.appendingPathComponent(paths.reference))

        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:9880"))
        let provisionalProfile = try GPTSoVITSVoiceProfile(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Integration voice",
            apiBaseURL: endpoint,
            gptWeightRelativePath: paths.gpt,
            sovitsWeightRelativePath: paths.sovits,
            referenceAudioRelativePath: paths.reference,
            referenceText: "Reference",
            promptLanguage: "en",
            defaultTextLanguage: "en",
            inputFingerprint: String(repeating: "0", count: 64)
        )
        let validated = try DialogueVoiceProfileFingerprint.validateAssets(
            profile: provisionalProfile,
            applicationSupportRoot: root
        )
        let profile = try GPTSoVITSVoiceProfile(
            id: provisionalProfile.id,
            name: provisionalProfile.name,
            apiBaseURL: endpoint,
            gptWeightRelativePath: paths.gpt,
            sovitsWeightRelativePath: paths.sovits,
            referenceAudioRelativePath: paths.reference,
            referenceText: provisionalProfile.referenceText,
            promptLanguage: provisionalProfile.promptLanguage,
            defaultTextLanguage: provisionalProfile.defaultTextLanguage,
            inputFingerprint: DialogueVoiceProfileFingerprint.compute(
                apiBaseURL: endpoint,
                referenceText: provisionalProfile.referenceText,
                promptLanguage: provisionalProfile.promptLanguage,
                defaultTextLanguage: provisionalProfile.defaultTextLanguage,
                assetDigests: validated.digests
            )
        )
        var library = try DialogueVoiceLibrary(profile: profile)
        _ = try library.addLine(text: "Hello from the queue", id: lineID)
        let runningLineID = UUID(uuidString: "66666666-7777-8888-9999-AAAAAAAAAAAA")!
        _ = try library.addLine(text: "Running now", state: .running, id: runningLineID)
        let alternateRunningLineID = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
        _ = try library.addLine(
            text: "Still running",
            state: .running,
            id: alternateRunningLineID
        )
        let corruptWaitingLineID = UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000000")!
        _ = try library.addLine(
            text: "Waiting with corrupt audio",
            state: .waiting,
            id: corruptWaitingLineID
        )
        let store = DialogueVoiceStore(
            rootURL: root.appendingPathComponent("voice", isDirectory: true)
        )
        try store.save(library)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuccessfulGPTSoVITSURLProtocol.self]
        let player = FakePlayer()
        player.validatesManagedAudio = true
        let intervalRecorder = ControlledSleeper()
        let randomIndex = DeterministicRandomIndex([0, 1, 0, 0])
        let coordinator = DialogueVoiceCoordinator(
            applicationSupportRoot: root,
            client: GPTSoVITSAPIClient(configuration: configuration),
            audioPlayer: player,
            randomIndex: { upperBound in
                randomIndex.next(upperBound: upperBound)
            },
            sleepForInterval: { interval in
                try await intervalRecorder.sleep(for: interval)
            }
        )
        defer { coordinator.shutdown() }
        let generated = expectation(description: "queued dialogue becomes ready")
        var fulfilled = false
        coordinator.onChange = { snapshot in
            guard !fulfilled,
                  snapshot.library.lines.count == 4,
                  snapshot.library.lines.allSatisfy({ $0.status == .ready }) else {
                return
            }
            fulfilled = true
            generated.fulfill()
        }

        coordinator.start()
        await fulfillment(of: [generated], timeout: 10)

        let readyLine = try XCTUnwrap(
            coordinator.library.lines.first(where: { $0.id == lineID })
        )
        XCTAssertEqual(readyLine.status, .ready)
        let outputPath = try XCTUnwrap(readyLine.outputRelativePath)
        let runningOutputPath = try XCTUnwrap(
            coordinator.library.lines.first(where: { $0.id == runningLineID })?.outputRelativePath
        )
        let alternateRunningOutputPath = try XCTUnwrap(
            coordinator.library.lines.first(where: { $0.id == alternateRunningLineID })?.outputRelativePath
        )
        let corruptWaitingOutputPath = try XCTUnwrap(
            coordinator.library.lines.first(where: { $0.id == corruptWaitingLineID })?.outputRelativePath
        )
        try Data("not a wave".utf8).write(to: root.appendingPathComponent(corruptWaitingOutputPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(outputPath).path))
        let ttsBody = try GPTSoVITSAPIClient.encodedTTSRequestBody(
            text: readyLine.text,
            textLanguage: "JA",
            referenceAudioPath: root.appendingPathComponent(paths.reference).path,
            promptText: profile.referenceText,
            promptLanguage: "JA"
        )
        let ttsJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ttsBody) as? [String: Any]
        )
        XCTAssertEqual(ttsJSON["text_lang"] as? String, "ja")
        XCTAssertEqual(ttsJSON["prompt_lang"] as? String, "ja")
        XCTAssertEqual(ttsJSON["text_split_method"] as? String, "cut0")
        try assertJSONBoolean(ttsJSON["streaming_mode"], equals: false)
        try assertJSONNumber(ttsJSON["batch_size"], equals: 1)
        try assertJSONBoolean(ttsJSON["parallel_infer"], equals: false)
        try assertJSONBoolean(ttsJSON["split_bucket"], equals: false)
        try assertJSONNumber(ttsJSON["fragment_interval"], equals: 0)
        try assertJSONNumber(ttsJSON["top_k"], equals: 5)
        try assertJSONNumber(ttsJSON["top_p"], equals: 0.8)
        try assertJSONNumber(ttsJSON["temperature"], equals: 0.6)
        try assertJSONNumber(ttsJSON["repetition_penalty"], equals: 1.35)
        try assertJSONNumber(ttsJSON["seed"], equals: 24_681)

        try coordinator.updatePlaybackSettings(try DialogueVoicePlaybackSettings(
            automaticPlaybackEnabled: true,
            volume: 0.25,
            repeatIntervalSeconds: 15
        ))
        XCTAssertEqual(player.volume, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(try store.load().playbackSettings.volume, 0.25, accuracy: 0.000_001)

        let idleRequest = UUID()
        let runningRequest = UUID()
        var automaticStarts: [(UUID, UUID)] = []
        var automaticFinishes: [(UUID, UUID)] = []
        let firstRunningStart = expectation(description: "latest state starts after preview")
        let repeatedRunningStart = expectation(description: "same state repeats after interval")
        let firstIntervalScheduled = expectation(description: "repeat interval scheduled after finish")
        let libraryStaleIntervalScheduled = expectation(description: "interval scheduled before settings change")
        let stateStaleIntervalScheduled = expectation(description: "interval scheduled before state change")
        let shutdownStaleIntervalScheduled = expectation(description: "interval scheduled before shutdown")
        intervalRecorder.setObserver { count in
            if count == 1 {
                firstIntervalScheduled.fulfill()
            } else if count == 2 {
                libraryStaleIntervalScheduled.fulfill()
            } else if count == 3 {
                stateStaleIntervalScheduled.fulfill()
            } else if count == 4 {
                shutdownStaleIntervalScheduled.fulfill()
            }
        }
        coordinator.onAutomaticPlaybackStarted = { requestID, line in
            automaticStarts.append((requestID, line.id))
            if requestID == runningRequest {
                if automaticStarts.filter({ $0.0 == runningRequest }).count == 1 {
                    firstRunningStart.fulfill()
                } else {
                    repeatedRunningStart.fulfill()
                }
            }
        }
        coordinator.onAutomaticPlaybackFinished = { requestID, lineID in
            automaticFinishes.append((requestID, lineID))
        }

        XCTAssertEqual(
            coordinator.beginAutomaticPlayback(for: .idle, requestID: idleRequest),
            .played
        )
        XCTAssertEqual(automaticStarts.map(\.1), [lineID])
        XCTAssertEqual(player.playedPaths, [outputPath])
        XCTAssertTrue(intervalRecorder.values.isEmpty, "Repeat timing starts only after audio finishes")

        XCTAssertEqual(
            coordinator.beginAutomaticPlayback(for: .running, requestID: runningRequest),
            .deferred
        )

        // Preview replaces the current automatic clip immediately, but the
        // newest lifecycle session resumes only after the preview finishes.
        XCTAssertEqual(coordinator.playReadyLine(id: lineID), .played)
        XCTAssertEqual(player.playedPaths, [outputPath, outputPath])
        XCTAssertTrue(automaticFinishes.isEmpty, "An interrupted automatic clip did not finish")
        player.finishCurrentPlayback()
        await fulfillment(of: [firstRunningStart], timeout: 2)
        XCTAssertEqual(automaticStarts[1].0, runningRequest)
        XCTAssertEqual(automaticStarts[1].1, alternateRunningLineID)
        XCTAssertEqual(player.playedPaths, [outputPath, outputPath, alternateRunningOutputPath])

        // A completed automatic clip waits for the configured quiet interval,
        // then selects another currently playable line for the same state.
        player.finishCurrentPlayback()
        await fulfillment(of: [firstIntervalScheduled], timeout: 2)
        XCTAssertEqual(intervalRecorder.values, [15])
        XCTAssertEqual(automaticStarts.map(\.1), [lineID, alternateRunningLineID])
        intervalRecorder.resumeNext()
        await fulfillment(of: [repeatedRunningStart], timeout: 2)
        XCTAssertEqual(automaticFinishes.map(\.1), [alternateRunningLineID])
        XCTAssertEqual(automaticStarts.map(\.1), [lineID, alternateRunningLineID, runningLineID])
        XCTAssertEqual(
            player.playedPaths,
            [outputPath, outputPath, alternateRunningOutputPath, runningOutputPath]
        )

        player.finishCurrentPlayback()
        await fulfillment(of: [libraryStaleIntervalScheduled], timeout: 2)
        let noLibraryStaleStart = expectation(description: "settings change invalidates stale timer")
        noLibraryStaleStart.isInverted = true
        coordinator.onAutomaticPlaybackStarted = { _, _ in noLibraryStaleStart.fulfill() }
        try coordinator.updatePlaybackSettings(try DialogueVoicePlaybackSettings(
            automaticPlaybackEnabled: true,
            volume: 0,
            repeatIntervalSeconds: nil
        ))
        intervalRecorder.resumeNext()
        await fulfillment(of: [noLibraryStaleStart], timeout: 0.1)
        XCTAssertEqual(intervalRecorder.values, [15, 15])

        try coordinator.updatePlaybackSettings(try DialogueVoicePlaybackSettings(
            automaticPlaybackEnabled: false,
            volume: 0,
            repeatIntervalSeconds: nil
        ))
        let noFurtherAutomaticStart = expectation(description: "disabled automatic playback stays cancelled")
        noFurtherAutomaticStart.isInverted = true
        coordinator.onAutomaticPlaybackStarted = { _, _ in noFurtherAutomaticStart.fulfill() }
        XCTAssertEqual(player.volume, 0, accuracy: 0.000_001)
        await fulfillment(of: [noFurtherAutomaticStart], timeout: 0.1)

        // Automatic playback being off does not disable explicit Preview.
        XCTAssertEqual(coordinator.playReadyLine(id: lineID), .played)
        XCTAssertEqual(player.playedPaths.last, outputPath)
        player.stop()

        try coordinator.updatePlaybackSettings(try DialogueVoicePlaybackSettings(
            automaticPlaybackEnabled: true,
            volume: 1,
            repeatIntervalSeconds: nil
        ))
        let neverRequest = UUID()
        let entryStarted = expectation(description: "Never still permits state-entry playback")
        coordinator.onAutomaticPlaybackStarted = { requestID, _ in
            if requestID == neverRequest { entryStarted.fulfill() }
        }
        XCTAssertEqual(
            coordinator.beginAutomaticPlayback(for: .running, requestID: neverRequest),
            .played
        )
        await fulfillment(of: [entryStarted], timeout: 1)
        let noNeverRepeat = expectation(description: "Never does not repeat")
        noNeverRepeat.isInverted = true
        coordinator.onAutomaticPlaybackStarted = { _, _ in noNeverRepeat.fulfill() }
        player.finishCurrentPlayback()
        await fulfillment(of: [noNeverRepeat], timeout: 0.1)
        XCTAssertEqual(intervalRecorder.values, [15, 15])

        let playbackCount = player.playedPaths.count
        XCTAssertEqual(
            coordinator.beginAutomaticPlayback(for: .waiting, requestID: UUID()),
            .unavailable(.missingOrInvalidAudio)
        )
        XCTAssertEqual(player.playedPaths.count, playbackCount)

        let beforeStateChangeRequest = UUID()
        let beforeStateChangeStarted = expectation(description: "clip starts before state cancellation")
        coordinator.onAutomaticPlaybackStarted = { requestID, _ in
            if requestID == beforeStateChangeRequest { beforeStateChangeStarted.fulfill() }
        }
        XCTAssertEqual(
            coordinator.beginAutomaticPlayback(for: .running, requestID: beforeStateChangeRequest),
            .played
        )
        await fulfillment(of: [beforeStateChangeStarted], timeout: 1)
        try coordinator.updatePlaybackSettings(try DialogueVoicePlaybackSettings(
            automaticPlaybackEnabled: true,
            volume: 1,
            repeatIntervalSeconds: 15
        ))
        player.finishCurrentPlayback()
        await fulfillment(of: [stateStaleIntervalScheduled], timeout: 2)
        let noStateStaleStart = expectation(description: "state change invalidates stale timer")
        noStateStaleStart.isInverted = true
        coordinator.onAutomaticPlaybackStarted = { _, _ in noStateStaleStart.fulfill() }
        XCTAssertEqual(
            coordinator.beginAutomaticPlayback(for: .review, requestID: UUID()),
            .unavailable(.notReady)
        )
        intervalRecorder.resumeNext()
        await fulfillment(of: [noStateStaleStart], timeout: 0.1)

        let beforeShutdownRequest = UUID()
        let beforeShutdownStarted = expectation(description: "clip starts before shutdown cancellation")
        coordinator.onAutomaticPlaybackStarted = { requestID, _ in
            if requestID == beforeShutdownRequest { beforeShutdownStarted.fulfill() }
        }
        XCTAssertEqual(
            coordinator.beginAutomaticPlayback(for: .running, requestID: beforeShutdownRequest),
            .played
        )
        await fulfillment(of: [beforeShutdownStarted], timeout: 1)
        player.finishCurrentPlayback()
        await fulfillment(of: [shutdownStaleIntervalScheduled], timeout: 2)
        let noShutdownStaleStart = expectation(description: "shutdown invalidates stale timer")
        noShutdownStaleStart.isInverted = true
        coordinator.onAutomaticPlaybackStarted = { _, _ in noShutdownStaleStart.fulfill() }
        coordinator.shutdown()
        intervalRecorder.resumeNext()
        await fulfillment(of: [noShutdownStaleStart], timeout: 0.1)
        XCTAssertEqual(intervalRecorder.values, [15, 15, 15, 15])

        let restartedPlayer = FakePlayer()
        let restartedCoordinator = DialogueVoiceCoordinator(
            applicationSupportRoot: root,
            client: GPTSoVITSAPIClient(configuration: configuration),
            audioPlayer: restartedPlayer
        )
        restartedCoordinator.start()
        XCTAssertEqual(
            restartedCoordinator.library.playbackSettings,
            try DialogueVoicePlaybackSettings(
                automaticPlaybackEnabled: true,
                volume: 1,
                repeatIntervalSeconds: 15
            )
        )
        XCTAssertEqual(restartedPlayer.volume, 1, accuracy: 0.000_001)
        restartedCoordinator.shutdown()
    }

    private func assertJSONBoolean(
        _ value: Any?,
        equals expected: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let number = try XCTUnwrap(value as? NSNumber, file: file, line: line)
        XCTAssertEqual(
            CFGetTypeID(number as CFTypeRef),
            CFBooleanGetTypeID(),
            "Expected a JSON boolean",
            file: file,
            line: line
        )
        XCTAssertEqual(number.boolValue, expected, file: file, line: line)
    }

    private func assertJSONNumber(
        _ value: Any?,
        equals expected: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let number = try XCTUnwrap(value as? NSNumber, file: file, line: line)
        XCTAssertNotEqual(
            CFGetTypeID(number as CFTypeRef),
            CFBooleanGetTypeID(),
            "Expected a JSON number, not a boolean",
            file: file,
            line: line
        )
        XCTAssertEqual(number.doubleValue, expected, accuracy: 0.000_001, file: file, line: line)
    }

    private func readPublishedPID(_ url: URL) -> Int32? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func waitForProcessExit(_ pid: Int32, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            errno = 0
            if Darwin.kill(pid, 0) != 0, errno == ESRCH { return true }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        errno = 0
        return Darwin.kill(pid, 0) != 0 && errno == ESRCH
    }

    private func pcmWAV() -> Data {
        let sampleBytes = 32_000
        var data = Data("RIFF".utf8)
        appendUInt32(UInt32(36 + sampleBytes), to: &data)
        data.append(Data("WAVEfmt ".utf8))
        appendUInt32(16, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(1, to: &data)
        appendUInt32(16_000, to: &data)
        appendUInt32(32_000, to: &data)
        appendUInt16(2, to: &data)
        appendUInt16(16, to: &data)
        data.append(Data("data".utf8))
        appendUInt32(UInt32(sampleBytes), to: &data)
        data.append(Data(repeating: 0, count: sampleBytes))
        return data
    }

    private func qwenPCM24kWAV(sampleFrames: Int) -> Data {
        let sampleBytes = sampleFrames * 2
        var data = Data("RIFF".utf8)
        appendUInt32(UInt32(36 + sampleBytes), to: &data)
        data.append(Data("WAVEfmt ".utf8))
        appendUInt32(16, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(1, to: &data)
        appendUInt32(24_000, to: &data)
        appendUInt32(48_000, to: &data)
        appendUInt16(2, to: &data)
        appendUInt16(16, to: &data)
        data.append(Data("data".utf8))
        appendUInt32(UInt32(sampleBytes), to: &data)
        data.append(Data(repeating: 0, count: sampleBytes))
        return data
    }

    private func makeQwenFixture(root: URL) throws -> QwenFixture {
        let packageRelative = "voice/packages/qwen/fixture"
        let package = root.appendingPathComponent(packageRelative, isDirectory: true)
        let model = package.appendingPathComponent("model/model.safetensors")
        let config = package.appendingPathComponent("config.json")
        let generator = package.appendingPathComponent("generate.py")
        let reference = package.appendingPathComponent("reference/clean.wav")
        let python = root.appendingPathComponent("runtime/python")
        let helper = root.appendingPathComponent("statelet-helper.py")
        for directory in [model.deletingLastPathComponent(), reference.deletingLastPathComponent(),
                          python.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("model".utf8).write(to: model)
        try Data("config".utf8).write(to: config)
        try Data("handover".utf8).write(to: generator)
        try qwenPCM24kWAV(sampleFrames: 240).write(to: reference)
        try Data("python".utf8).write(to: python)
        try Data("helper".utf8).write(to: helper)
        XCTAssertEqual(chmod(python.path, 0o700), 0)
        let manifest = try Qwen3TTSPackageManifest(
            modelRelativePath: "model/model.safetensors",
            configRelativePath: "config.json",
            handoverGeneratorRelativePath: "generate.py",
            referenceAudioRelativePath: "reference/clean.wav",
            modelSHA256: digest(model),
            configSHA256: digest(config),
            handoverGeneratorSHA256: digest(generator),
            referenceAudioSHA256: digest(reference)
        )
        let placeholder = try Qwen3TTSVoiceProfile(
            name: "Fixture", packageRootRelativePath: packageRelative,
            pythonExecutablePath: python.path, pythonExecutableSHA256: digest(python),
            packageTreeSHA256: try Qwen3TTSProfileValidator.computePackageTreeSHA256(packageRoot: package),
            manifest: manifest, referenceText: "reference", referenceLanguage: "japanese",
            defaultTextLanguage: "japanese", inputFingerprint: String(repeating: "0", count: 64)
        )
        var hasher = SHA256()
        for field in placeholder.inputFingerprintComponents {
            var length = UInt64(field.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
            hasher.update(data: Data(field.utf8))
        }
        let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let profile = try Qwen3TTSVoiceProfile(
            name: "Fixture", packageRootRelativePath: packageRelative,
            pythonExecutablePath: python.path, pythonExecutableSHA256: digest(python),
            packageTreeSHA256: try Qwen3TTSProfileValidator.computePackageTreeSHA256(packageRoot: package),
            manifest: manifest, referenceText: "reference", referenceLanguage: "japanese",
            defaultTextLanguage: "japanese", inputFingerprint: fingerprint
        )
        return QwenFixture(profile: profile, python: python, helper: helper)
    }

    private func makeSyntheticQwenHandover(at root: URL) throws {
        let files: [String: Data] = [
            "model/model.safetensors": Data("model".utf8),
            "model/tokenizer_config.json": Data("{}".utf8),
            "model/speech_tokenizer/model.safetensors": Data("speech-tokenizer".utf8),
            "generate.py": Data("# provenance only\n".utf8),
            "reference/clean.wav": qwenPCM24kWAV(sampleFrames: 2_400),
        ]
        for (relativePath, data) in files {
            let destination = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination)
        }
        let config: [String: Any] = [
            "model_path": "model",
            "reference_audio": "reference/clean.wav",
            "reference_text": "reference",
            "language": "japanese",
            "generation": [
                "temperature": 0.7,
                "top_k": 40,
                "top_p": 0.95,
                "repetition_penalty": 1.05,
                "max_tokens": 2_048,
                "seed": 1_112,
            ],
            "audio": [
                "format": "wav",
                "subtype": "PCM_16",
                "expected_sample_rate": 24_000,
            ],
        ]
        try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("config.json"))
    }

    private func digest(_ url: URL) -> String {
        let data = try! Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }
}
