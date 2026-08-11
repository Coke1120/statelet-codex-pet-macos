import Darwin
import Foundation
import XCTest
@testable import CodexPetCore

final class DialogueVoiceTests: XCTestCase {
    private enum InjectedFailure: Error { case beforeCommit }

    private let profileID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let lineID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func profile(revision: Int = 1, endpoint: String = "http://127.0.0.1:9880") throws -> GPTSoVITSVoiceProfile {
        try GPTSoVITSVoiceProfile(
            id: profileID,
            revision: revision,
            name: "Test Voice",
            apiBaseURL: try XCTUnwrap(URL(string: endpoint)),
            gptWeightRelativePath: "voice/assets/gpt/test.ckpt",
            sovitsWeightRelativePath: "voice/assets/sovits/test.pth",
            referenceAudioRelativePath: "voice/assets/reference/test.wav",
            referenceText: "Reference text",
            promptLanguage: "zh",
            defaultTextLanguage: "yue",
            inputFingerprint: String(repeating: "a", count: 64)
        )
    }

    private func libraryWithQueuedLine(state: PetState = .idle) throws -> DialogueVoiceLibrary {
        var library = try DialogueVoiceLibrary(profile: profile())
        try library.addLine(text: "你好", state: state, id: lineID)
        return library
    }

    func testRoundTripAndStoreUsesPrivatePermissions() throws {
        var library = try libraryWithQueuedLine(state: .review)
        let ticket = try library.beginGeneration(for: lineID)
        try library.completeGeneration(ticket: ticket, outputPath: "audio/line.wav")

        let encoded = try JSONEncoder().encode(library)
        XCTAssertEqual(try JSONDecoder().decode(DialogueVoiceLibrary.self, from: encoded), library)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dialogue-voice-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DialogueVoiceStore(rootURL: root)
        try store.save(library)
        XCTAssertEqual(try store.load(), library)

        let rootMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        let fileMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        XCTAssertEqual(rootMode, 0o700)
        XCTAssertEqual(fileMode, 0o600)
    }

    func testDialogueStateRoundTripsAndLegacyLinesMigrateToIdle() throws {
        let line = try DialogueLine(
            id: lineID,
            state: .waiting,
            text: "Please confirm",
            textLanguage: "en"
        )
        let encoded = try JSONEncoder().encode(line)
        XCTAssertEqual(try JSONDecoder().decode(DialogueLine.self, from: encoded).state, .waiting)

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "state")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        XCTAssertEqual(try JSONDecoder().decode(DialogueLine.self, from: legacyData).state, .idle)
    }

    func testLegacySynthesisOutputMigratesAndIsRetainedUntilReplacementSucceeds() throws {
        var original = try libraryWithQueuedLine()
        let firstTicket = try original.beginGeneration(for: lineID)
        _ = try original.completeGeneration(
            ticket: firstTicket,
            outputPath: "voice/generated/legacy.wav"
        )

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
        )
        var legacyLines = try XCTUnwrap(legacyObject["lines"] as? [[String: Any]])
        legacyLines[0].removeValue(forKey: "generated_synthesis_policy_version")
        legacyObject["lines"] = legacyLines
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        var migrated = try JSONDecoder().decode(DialogueVoiceLibrary.self, from: legacyData)

        XCTAssertEqual(
            migrated.lines[0].generatedSynthesisPolicyVersion,
            DialogueSynthesisPolicy.legacyVersion
        )
        try migrated.setProfileStatus(.validating)
        XCTAssertEqual(try migrated.migrateOutdatedSynthesisOutputs(), 1)
        XCTAssertEqual(migrated.lines[0].status, .stale)
        XCTAssertEqual(migrated.lines[0].outputRelativePath, "voice/generated/legacy.wav")
        XCTAssertTrue(migrated.referencedManagedPaths.contains("voice/generated/legacy.wav"))

        XCTAssertEqual(try migrated.activateValidatedProfile(), 1)
        XCTAssertEqual(migrated.lines[0].status, .queued)
        XCTAssertEqual(migrated.lines[0].outputRelativePath, "voice/generated/legacy.wav")
        let replacementTicket = try migrated.beginGeneration(for: lineID)
        XCTAssertEqual(migrated.lines[0].status, .generating)
        XCTAssertEqual(migrated.lines[0].outputRelativePath, "voice/generated/legacy.wav")

        _ = try migrated.failGeneration(ticket: replacementTicket, failureCode: "INFERENCE_UNAVAILABLE")
        XCTAssertEqual(migrated.lines[0].status, .stale)
        XCTAssertEqual(migrated.lines[0].outputRelativePath, "voice/generated/legacy.wav")

        _ = try migrated.retryLine(id: lineID)
        let successfulTicket = try migrated.beginGeneration(for: lineID)
        _ = try migrated.completeGeneration(
            ticket: successfulTicket,
            outputPath: "voice/generated/current.wav"
        )
        XCTAssertEqual(migrated.lines[0].status, .ready)
        XCTAssertEqual(
            migrated.lines[0].generatedSynthesisPolicyVersion,
            DialogueSynthesisPolicy.currentVersion
        )
        XCTAssertEqual(migrated.lines[0].outputRelativePath, "voice/generated/current.wav")
    }

    func testInvalidationKeepsQueuedAndGeneratingMigrationOutputsReferenced() throws {
        let queuedID = UUID(uuidString: "10000000-0000-0000-0000-000000000010")!
        let generatingID = UUID(uuidString: "10000000-0000-0000-0000-000000000011")!
        let queuedPath = "voice/generated/legacy-queued.wav"
        let generatingPath = "voice/generated/legacy-generating.wav"
        var library = try DialogueVoiceLibrary(
            profile: profile(),
            lines: [
                try DialogueLine(
                    id: queuedID,
                    text: "Queued migration",
                    textLanguage: "en",
                    status: .stale,
                    generatedProfileRevision: 1,
                    generatedSynthesisPolicyVersion: DialogueSynthesisPolicy.legacyVersion,
                    outputRelativePath: queuedPath
                ),
                try DialogueLine(
                    id: generatingID,
                    text: "Generating migration",
                    textLanguage: "en",
                    status: .stale,
                    generatedProfileRevision: 1,
                    generatedSynthesisPolicyVersion: DialogueSynthesisPolicy.legacyVersion,
                    outputRelativePath: generatingPath
                ),
            ]
        )
        library = try JSONDecoder().decode(
            DialogueVoiceLibrary.self,
            from: JSONEncoder().encode(library)
        )

        XCTAssertEqual(try library.activateValidatedProfile(), 2)
        _ = try library.beginGeneration(for: generatingID)
        XCTAssertEqual(library.lines.first(where: { $0.id == queuedID })?.status, .queued)
        XCTAssertEqual(library.lines.first(where: { $0.id == generatingID })?.status, .generating)

        try library.setProfileStatus(.invalid, invalidatingOutputs: true)
        for (lineID, path) in [(queuedID, queuedPath), (generatingID, generatingPath)] {
            let line = try XCTUnwrap(library.lines.first(where: { $0.id == lineID }))
            XCTAssertEqual(line.status, .stale)
            XCTAssertEqual(line.outputRelativePath, path)
            XCTAssertTrue(library.referencedManagedPaths.contains(path))
        }
    }

    func testStoreRejectsSymlinkRootAndSymlinkDestination() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("dialogue-voice-symlink-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        let realRoot = container.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: false)
        let symlinkRoot = container.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: realRoot)

        let library = try libraryWithQueuedLine()
        let linkedStore = DialogueVoiceStore(rootURL: symlinkRoot)
        XCTAssertThrowsError(try linkedStore.save(library)) {
            XCTAssertEqual($0 as? DialogueVoiceError, .storeFailure)
        }
        XCTAssertThrowsError(try linkedStore.load()) {
            XCTAssertEqual($0 as? DialogueVoiceError, .storeFailure)
        }

        let externalFile = container.appendingPathComponent("external.json")
        try Data("external".utf8).write(to: externalFile)
        let destination = realRoot.appendingPathComponent(DialogueVoiceStore.fileName)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: externalFile)
        let store = DialogueVoiceStore(rootURL: realRoot)
        XCTAssertThrowsError(try store.save(library)) {
            XCTAssertEqual($0 as? DialogueVoiceError, .storeFailure)
        }
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? DialogueVoiceError, .storeFailure)
        }
        XCTAssertEqual(try String(contentsOf: externalFile), "external")
    }

    func testStoreRejectsCorruptAndFutureSchemaWithoutLeakingPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dialogue-voice-corrupt-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let store = DialogueVoiceStore(rootURL: root)
        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? DialogueVoiceError, .storeFailure)
            XCTAssertFalse(error.localizedDescription.contains(root.path))
        }

        let future = #"{"version":2,"profile":null,"lines":[]}"#
        try Data(future.utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? DialogueVoiceError, .unsupportedSchemaVersion(2))
            XCTAssertFalse(error.localizedDescription.contains(root.path))
        }
    }

    func testPreCommitFailurePreservesPreviouslyDecodableLibrary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dialogue-voice-atomic-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DialogueVoiceStore(rootURL: root)
        let original = try libraryWithQueuedLine()
        try store.save(original)

        var replacement = original
        try replacement.editLine(id: lineID, text: "replacement")
        let failingStore = DialogueVoiceStore(rootURL: root, beforeCommit: {
            throw InjectedFailure.beforeCommit
        })
        XCTAssertThrowsError(try failingStore.save(replacement)) {
            XCTAssertEqual($0 as? DialogueVoiceError, .storeFailure)
        }
        XCTAssertEqual(try store.load(), original)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(leftovers, [DialogueVoiceStore.fileName])
    }

    func testAddEditFailureAndRetryTransitions() throws {
        var library = try libraryWithQueuedLine(state: .running)
        XCTAssertEqual(library.lines[0].status, .queued)
        XCTAssertEqual(library.lines[0].textLanguage, "yue")
        XCTAssertEqual(library.lines[0].state, .running)

        let ticket = try library.beginGeneration(for: lineID)
        try library.failGeneration(ticket: ticket, failureCode: "SERVICE_UNAVAILABLE")
        XCTAssertEqual(library.lines[0].status, .failed)
        XCTAssertEqual(library.lines[0].failureCode, "SERVICE_UNAVAILABLE")
        XCTAssertEqual(library.lines[0].state, .running)

        try library.retryLine(id: lineID)
        XCTAssertEqual(library.lines[0].status, .queued)
        XCTAssertNil(library.lines[0].failureCode)
        XCTAssertEqual(library.lines[0].state, .running)

        let edited = try library.editLine(id: lineID, text: "新的台詞", language: "zh")
        XCTAssertEqual(edited.revision, 2)
        XCTAssertEqual(edited.status, .queued)
        XCTAssertEqual(edited.textLanguage, "zh")
        XCTAssertEqual(edited.state, .running)

        let reassigned = try library.editLine(
            id: lineID,
            text: edited.text,
            language: edited.textLanguage,
            state: .review
        )
        XCTAssertEqual(reassigned.state, .review)

        let completionTicket = try library.beginGeneration(for: lineID)
        let completed = try library.completeGeneration(
            ticket: completionTicket,
            outputPath: "voice/generated/review.wav"
        )
        XCTAssertEqual(completed.state, .review)

        try library.replaceActiveProfile(profile(revision: 2))
        XCTAssertEqual(library.lines[0].state, .review)
        try library.retryLine(id: lineID)
        _ = try library.beginGeneration(for: lineID)
        XCTAssertEqual(try library.recoverInterruptedGenerations(), 1)
        XCTAssertEqual(library.lines[0].state, .review)
    }

    func testPreferredLineSelectsReadyFirstWithinRequestedState() throws {
        let idleDraftID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let idleReadyID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let runningID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        var library = try DialogueVoiceLibrary(profile: profile())
        _ = try library.addLine(text: "Idle draft", state: .idle, id: idleDraftID)
        _ = try library.addLine(text: "Idle ready", state: .idle, id: idleReadyID)
        _ = try library.addLine(text: "Running", state: .running, id: runningID)

        let readyTicket = try library.beginGeneration(for: idleReadyID)
        _ = try library.completeGeneration(
            ticket: readyTicket,
            outputPath: "voice/generated/idle-ready.wav"
        )

        XCTAssertEqual(library.preferredLine(for: .idle)?.id, idleReadyID)
        XCTAssertEqual(library.preferredLine(for: .running)?.id, runningID)
        XCTAssertNil(library.preferredLine(for: .waiting))
        XCTAssertEqual(library.lines.first(where: { $0.id == idleDraftID })?.status, .queued)
    }

    func testProfileValidationStatusControlsQueueingAndPersists() throws {
        var library = try DialogueVoiceLibrary(profile: profile(), profileStatus: .validating)
        let draft = try library.addLine(text: "wait for validation", id: lineID)
        XCTAssertEqual(draft.status, .draft)
        XCTAssertThrowsError(try library.beginGeneration(for: lineID)) {
            XCTAssertEqual($0 as? DialogueVoiceError, .profileNotConfigured)
        }

        XCTAssertEqual(try library.activateValidatedProfile(), 1)
        XCTAssertEqual(library.profileStatus, .ready)
        XCTAssertEqual(library.lines[0].status, .queued)
        let encoded = try JSONEncoder().encode(library)
        XCTAssertEqual(try JSONDecoder().decode(DialogueVoiceLibrary.self, from: encoded), library)

        let ticket = try library.beginGeneration(for: lineID)
        try library.completeGeneration(ticket: ticket, outputPath: "audio/ready.wav")
        try library.setProfileStatus(.unavailable)
        XCTAssertNoThrow(try library.outputURL(
            for: lineID,
            relativeTo: URL(fileURLWithPath: "/managed/root")
        ))

        try library.setProfileStatus(.invalid, invalidatingOutputs: true)
        XCTAssertEqual(library.lines[0].status, .stale)
        XCTAssertThrowsError(try library.outputURL(
            for: lineID,
            relativeTo: URL(fileURLWithPath: "/managed/root")
        ))
    }

    func testProfileRejectsInvalidInputFingerprint() throws {
        XCTAssertThrowsError(try GPTSoVITSVoiceProfile(
            id: profileID,
            name: "Voice",
            apiBaseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:9880")),
            gptWeightRelativePath: "models/test.ckpt",
            sovitsWeightRelativePath: "models/test.pth",
            referenceAudioRelativePath: "references/test.wav",
            referenceText: "Reference",
            promptLanguage: "zh",
            defaultTextLanguage: "zh",
            inputFingerprint: "not-a-digest"
        )) {
            XCTAssertEqual($0 as? DialogueVoiceError, .invalidProfile)
        }
    }

    func testCleanupTombstonesPersistAndAreVoiceScoped() throws {
        var library = try libraryWithQueuedLine()
        try library.enqueueCleanup(paths: [
            "voice/generated/old.wav",
            "voice/assets/gpt/old.ckpt",
        ])
        try library.enqueueCleanup(paths: ["voice/generated/old.wav"])
        XCTAssertEqual(library.pendingCleanupPaths.count, 2)
        let encoded = try JSONEncoder().encode(library)
        XCTAssertEqual(
            try JSONDecoder().decode(DialogueVoiceLibrary.self, from: encoded).pendingCleanupPaths,
            library.pendingCleanupPaths
        )
        XCTAssertThrowsError(try library.enqueueCleanup(paths: ["media/private.mov"])) {
            XCTAssertEqual($0 as? DialogueVoiceError, .invalidManagedPath)
        }
        try library.replacePendingCleanupPaths([])
        XCTAssertTrue(library.pendingCleanupPaths.isEmpty)
    }

    func testCleanupTombstonesRejectActiveProfileAndOutputPaths() throws {
        var library = try libraryWithQueuedLine()
        let activeGPTPath = try XCTUnwrap(library.profile?.gptWeightRelativePath)
        XCTAssertThrowsError(try library.enqueueCleanup(paths: [activeGPTPath])) {
            XCTAssertEqual($0 as? DialogueVoiceError, .invalidState)
        }

        let ticket = try library.beginGeneration(for: lineID)
        let outputPath = "voice/generated/current.wav"
        try library.completeGeneration(ticket: ticket, outputPath: outputPath)
        XCTAssertTrue(library.referencedManagedPaths.contains(outputPath))
        XCTAssertThrowsError(try library.enqueueCleanup(paths: [outputPath])) {
            XCTAssertEqual($0 as? DialogueVoiceError, .invalidState)
        }
        XCTAssertThrowsError(try library.replacePendingCleanupPaths([outputPath])) {
            XCTAssertEqual($0 as? DialogueVoiceError, .invalidState)
        }
        XCTAssertTrue(library.pendingCleanupPaths.isEmpty)
    }

    func testCleanupTombstoneCannotBecomeAnActiveProfileOrGeneratedOutput() throws {
        var profileLibrary = try libraryWithQueuedLine()
        let replacementGPTPath = "voice/assets/gpt/replacement.ckpt"
        try profileLibrary.enqueueCleanup(paths: [replacementGPTPath])
        let replacementProfile = try GPTSoVITSVoiceProfile(
            id: profileID,
            revision: 2,
            name: "Replacement Voice",
            apiBaseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:9880")),
            gptWeightRelativePath: replacementGPTPath,
            sovitsWeightRelativePath: "voice/assets/sovits/replacement.pth",
            referenceAudioRelativePath: "voice/assets/reference/replacement.wav",
            referenceText: "Replacement reference",
            promptLanguage: "zh",
            defaultTextLanguage: "yue",
            inputFingerprint: String(repeating: "b", count: 64)
        )
        XCTAssertThrowsError(try profileLibrary.replaceActiveProfile(replacementProfile)) {
            XCTAssertEqual($0 as? DialogueVoiceError, .invalidState)
        }
        XCTAssertEqual(profileLibrary.profile?.revision, 1)

        var outputLibrary = try libraryWithQueuedLine()
        let pendingOutputPath = "voice/generated/collision.wav"
        try outputLibrary.enqueueCleanup(paths: [pendingOutputPath])
        let ticket = try outputLibrary.beginGeneration(for: lineID)
        XCTAssertThrowsError(
            try outputLibrary.completeGeneration(ticket: ticket, outputPath: pendingOutputPath)
        ) {
            XCTAssertEqual($0 as? DialogueVoiceError, .invalidState)
        }
        XCTAssertEqual(outputLibrary.lines[0].status, .generating)
    }

    func testStoreRejectsCleanupTombstoneOverlappingReferencedData() throws {
        var library = try libraryWithQueuedLine()
        let ticket = try library.beginGeneration(for: lineID)
        try library.completeGeneration(ticket: ticket, outputPath: "voice/generated/current.wav")
        let encoded = try JSONEncoder().encode(library)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["pending_cleanup_paths"] = ["voice/generated/current.wav"]

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dialogue-voice-overlap-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let store = DialogueVoiceStore(rootURL: root)
        try JSONSerialization.data(withJSONObject: object).write(to: store.fileURL)

        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? DialogueVoiceError, .invalidState)
        }
    }

    func testInterruptedGenerationRecoversToQueue() throws {
        var library = try libraryWithQueuedLine()
        _ = try library.beginGeneration(for: lineID)
        XCTAssertEqual(try library.recoverInterruptedGenerations(), 1)
        XCTAssertEqual(library.lines[0].status, .queued)
        XCTAssertEqual(try library.recoverInterruptedGenerations(), 0)
    }

    func testLateCompletionAfterEditIsRejected() throws {
        var library = try libraryWithQueuedLine()
        let ticket = try library.beginGeneration(for: lineID)
        try library.editLine(id: lineID, text: "Changed while generating")

        XCTAssertThrowsError(try library.completeGeneration(ticket: ticket, outputPath: "audio/late.wav")) {
            XCTAssertEqual($0 as? DialogueVoiceError, .generationResultRejected)
        }
        XCTAssertEqual(library.lines[0].revision, 2)
        XCTAssertEqual(library.lines[0].status, .queued)
    }

    func testDeletedLineRejectsLateCompletion() throws {
        var library = try libraryWithQueuedLine()
        let ticket = try library.beginGeneration(for: lineID)
        try library.removeLine(id: lineID)

        XCTAssertThrowsError(try library.completeGeneration(ticket: ticket, outputPath: "audio/late.wav")) {
            XCTAssertEqual($0 as? DialogueVoiceError, .generationResultRejected)
        }
        XCTAssertTrue(library.lines.isEmpty)
    }

    func testProfileReplacementInvalidatesReadyAudioAndOldTicket() throws {
        var library = try libraryWithQueuedLine()
        let ticket = try library.beginGeneration(for: lineID)
        try library.completeGeneration(ticket: ticket, outputPath: "voice/generated/original.wav")

        try library.replaceActiveProfile(profile(revision: 2))
        XCTAssertEqual(library.lines[0].status, .stale)
        XCTAssertEqual(library.lines[0].generatedProfileRevision, 1)
        XCTAssertThrowsError(try library.outputURL(for: lineID, relativeTo: URL(fileURLWithPath: "/tmp/root"))) {
            XCTAssertEqual($0 as? DialogueVoiceError, .outputNotReady)
        }

        try library.retryLine(id: lineID)
        XCTAssertNil(library.lines[0].outputRelativePath)
        XCTAssertNoThrow(try library.enqueueCleanup(paths: ["voice/generated/original.wav"]))
        let replacementTicket = try library.beginGeneration(for: lineID)
        XCTAssertThrowsError(try library.completeGeneration(ticket: ticket, outputPath: "audio/late.wav")) {
            XCTAssertEqual($0 as? DialogueVoiceError, .generationResultRejected)
        }
        XCTAssertEqual(replacementTicket.profileRevision, 2)
    }

    func testRejectsUnsafeManagedPathsAndEndpoints() throws {
        for path in ["/tmp/model.ckpt", "../model.ckpt", "models/../model.ckpt", "~/model.ckpt", "C:model.ckpt", "models\\model.ckpt"] {
            XCTAssertThrowsError(try GPTSoVITSVoiceProfile(
                id: profileID,
                name: "Voice",
                apiBaseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:9880")),
                gptWeightRelativePath: path,
                sovitsWeightRelativePath: "models/test.pth",
                referenceAudioRelativePath: "references/test.wav",
                referenceText: "Reference",
                promptLanguage: "zh",
                defaultTextLanguage: "zh",
                inputFingerprint: String(repeating: "a", count: 64)
            ), "accepted \(path)")
        }

        for endpoint in [
            "https://127.0.0.1:9880",
            "http://192.168.1.20:9880",
            "http://example.com",
            "http://localhost:9880",
            "http://127.0.0.1:9880/api",
            "http://user@127.0.0.1:9880",
        ] {
            XCTAssertThrowsError(try profile(endpoint: endpoint), "accepted \(endpoint)") {
                XCTAssertEqual($0 as? DialogueVoiceError, .invalidEndpoint)
            }
        }
        XCTAssertNoThrow(try profile(endpoint: "http://[::1]:9880"))
        XCTAssertNoThrow(try profile(endpoint: "http://127.0.0.2:9880"))
    }

    func testRejectsBlankOversizeTextAndInvalidDecodedState() throws {
        var library = try DialogueVoiceLibrary(profile: profile())
        XCTAssertThrowsError(try library.addLine(text: "  \n", id: lineID)) {
            XCTAssertEqual($0 as? DialogueVoiceError, .invalidText)
        }
        XCTAssertThrowsError(try library.addLine(text: String(repeating: "x", count: 4_001), id: lineID))

        let ticketLibrary = try libraryWithQueuedLine()
        var failingLibrary = ticketLibrary
        let ticket = try failingLibrary.beginGeneration(for: lineID)
        XCTAssertThrowsError(try failingLibrary.failGeneration(
            ticket: ticket,
            failureCode: "/Users/person/private/model.ckpt"
        )) {
            XCTAssertEqual($0 as? DialogueVoiceError, .invalidFailureCode)
        }

        let invalid = """
        {"version":1,"profile":null,"lines":[{"id":"\(lineID.uuidString)","text":"hello","text_language":"en","revision":1,"status":"ready","generated_profile_revision":null,"output_relative_path":null,"failure_code":null}]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(DialogueVoiceLibrary.self, from: invalid))
    }

    func testOutputResolutionRequiresReadyLine() throws {
        var library = try libraryWithQueuedLine()
        let root = URL(fileURLWithPath: "/managed/root", isDirectory: true)
        XCTAssertThrowsError(try library.outputURL(for: lineID, relativeTo: root)) {
            XCTAssertEqual($0 as? DialogueVoiceError, .outputNotReady)
        }

        let ticket = try library.beginGeneration(for: lineID)
        try library.completeGeneration(ticket: ticket, outputPath: "audio/ready.wav")
        XCTAssertEqual(
            try library.outputURL(for: lineID, relativeTo: root).path,
            "/managed/root/audio/ready.wav"
        )
    }
}
