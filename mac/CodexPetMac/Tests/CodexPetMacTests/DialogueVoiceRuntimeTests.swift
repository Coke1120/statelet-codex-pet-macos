import CodexPetCore
import Foundation
import XCTest
@testable import CodexPetMac

final class DialogueVoiceRuntimeTests: XCTestCase {
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

    private final class FakePlayer: DialogueAudioPlaying {
        var playedPaths: [String] = []
        var error: Error?

        func play(relativePath: String, applicationSupportRoot: URL) throws {
            if let error { throw error }
            playedPaths.append(relativePath)
        }

        func stop() {}
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
        try coordinator.addLine(text: "Before", language: "en")
        let lineID = try XCTUnwrap(coordinator.library.lines.first?.id)
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

        try coordinator.updateLine(id: lineID, text: "After", language: "en")

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
        let store = DialogueVoiceStore(
            rootURL: root.appendingPathComponent("voice", isDirectory: true)
        )
        try store.save(library)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuccessfulGPTSoVITSURLProtocol.self]
        let player = FakePlayer()
        let coordinator = DialogueVoiceCoordinator(
            applicationSupportRoot: root,
            client: GPTSoVITSAPIClient(configuration: configuration),
            audioPlayer: player
        )
        defer { coordinator.shutdown() }
        let generated = expectation(description: "queued dialogue becomes ready")
        var fulfilled = false
        coordinator.onChange = { snapshot in
            guard !fulfilled,
                  snapshot.library.lines.first(where: { $0.id == self.lineID })?.status == .ready else {
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(outputPath).path))
        XCTAssertEqual(coordinator.playReadyLine(id: lineID), .played)
        XCTAssertEqual(player.playedPaths, [outputPath])
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
