import CodexPetCore
import Foundation
import os

struct DialogueVoiceImportedAssets: Equatable, Sendable {
    var gptWeightRelativePath: String?
    var gptWeightDigest: String?
    var sovitsWeightRelativePath: String?
    var sovitsWeightDigest: String?
    var referenceAudioRelativePath: String?
    var referenceAudioDigest: String?

    init(profile: GPTSoVITSVoiceProfile? = nil) {
        gptWeightRelativePath = profile?.gptWeightRelativePath
        sovitsWeightRelativePath = profile?.sovitsWeightRelativePath
        referenceAudioRelativePath = profile?.referenceAudioRelativePath
    }

    var digests: DialogueVoiceAssetDigests? {
        guard let gptWeightDigest, let sovitsWeightDigest, let referenceAudioDigest else {
            return nil
        }
        return DialogueVoiceAssetDigests(
            gptWeight: gptWeightDigest,
            sovitsWeight: sovitsWeightDigest,
            referenceAudio: referenceAudioDigest
        )
    }
}

struct DialogueVoiceCoordinatorSnapshot {
    let library: DialogueVoiceLibrary
    let draft: DialogueVoiceProfileDraft
    let importedAssets: DialogueVoiceImportedAssets
    let activityMessage: String?
}

final class DialogueVoiceCoordinator: @unchecked Sendable {
    private enum GenerationResult: Sendable {
        case success(String, DialogueVoiceAssetIdentities)
        case failure(String)
    }

    private enum ProfileValidationResult: Sendable {
        case valid(DialogueVoiceValidatedAssets, [ReadyOutputValidationTicket])
        case unavailable(DialogueVoiceValidatedAssets, [ReadyOutputValidationTicket])
        case invalid
    }

    private struct ReadyOutputValidationTicket: Sendable {
        let lineID: UUID
        let lineRevision: Int
        let outputRelativePath: String
    }

    private enum CleanupIssue {
        case retryPending
        case metadataPersistenceFailed
        case activeReferenceConflict
    }

    private struct CleanupOutcome {
        let remainingCount: Int
        let issue: CleanupIssue?

        static let complete = CleanupOutcome(remainingCount: 0, issue: nil)

        static func retryPending(_ count: Int) -> CleanupOutcome {
            guard count > 0 else { return .complete }
            return CleanupOutcome(remainingCount: count, issue: .retryPending)
        }

        var requiresNotice: Bool { issue != nil }
    }

    private let logger = Logger(subsystem: StateletIdentity.bundleIdentifier, category: "dialogue-voice")
    private let applicationSupportRoot: URL
    private let store: DialogueVoiceStore
    private let installer: DialogueVoiceAssetInstaller
    private let publisher: DialogueVoiceAudioPublisher
    private let client: GPTSoVITSAPIClient
    private let audioPlayer: DialogueAudioPlaying
    private let playbackService: DialogueReadyPlaybackService

    private(set) var library: DialogueVoiceLibrary
    private(set) var draft: DialogueVoiceProfileDraft
    private(set) var importedAssets: DialogueVoiceImportedAssets
    private(set) var activityMessage: String?

    private var activeGenerationTask: Task<Void, Never>?
    private var activeTicket: DialogueGenerationTicket?
    private var activeImportTask: Task<Void, Never>?
    private var profileValidationTask: Task<Void, Never>?
    private var validatedAssetIdentities: DialogueVoiceAssetIdentities?
    private var profileValidationSequence: UInt64 = 0
    private var importSequence: UInt64 = 0
    private var persistenceBlocked = false
    private var started = false

    var onChange: ((DialogueVoiceCoordinatorSnapshot) -> Void)?

    init(
        applicationSupportRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(StateletIdentity.applicationSupportRelativePath, isDirectory: true),
        client: GPTSoVITSAPIClient = GPTSoVITSAPIClient(),
        audioPlayer: DialogueAudioPlaying = DialogueAudioPlayer()
    ) {
        self.applicationSupportRoot = applicationSupportRoot
        let voiceRoot = applicationSupportRoot.appendingPathComponent("voice", isDirectory: true)
        store = DialogueVoiceStore(rootURL: voiceRoot)
        installer = DialogueVoiceAssetInstaller(applicationSupportRoot: applicationSupportRoot)
        publisher = DialogueVoiceAudioPublisher(applicationSupportRoot: applicationSupportRoot)
        self.client = client
        self.audioPlayer = audioPlayer
        playbackService = DialogueReadyPlaybackService(
            applicationSupportRoot: applicationSupportRoot,
            player: audioPlayer
        )
        library = try! DialogueVoiceLibrary()
        draft = DialogueVoiceProfileDraft(
            name: "",
            apiBaseURL: "http://127.0.0.1:9880",
            promptLanguage: "",
            defaultTextLanguage: "",
            referenceText: ""
        )
        importedAssets = DialogueVoiceImportedAssets()
    }

    var snapshot: DialogueVoiceCoordinatorSnapshot {
        DialogueVoiceCoordinatorSnapshot(
            library: library,
            draft: draft,
            importedAssets: importedAssets,
            activityMessage: activityMessage
        )
    }

    func start() {
        assertMainThread()
        guard !started else { return }
        started = true
        if FileManager.default.fileExists(atPath: store.fileURL.path) {
            do {
                library = try store.load()
            } catch {
                persistenceBlocked = true
                activityMessage = "Dialogue data is invalid and was left untouched. Restore or remove the local voice library before editing."
                logger.error("event=library_load_failed code=STORE_FAILURE")
                notify()
                return
            }
        }
        importedAssets = DialogueVoiceImportedAssets(profile: library.profile)
        if let profile = library.profile {
            draft = DialogueVoiceProfileDraft(
                name: profile.name,
                apiBaseURL: profile.apiBaseURL.absoluteString,
                promptLanguage: profile.promptLanguage,
                defaultTextLanguage: profile.defaultTextLanguage,
                referenceText: profile.referenceText
            )
        }

        do {
            var recoveredLibrary = library
            if recoveredLibrary.profile != nil {
                try recoveredLibrary.setProfileStatus(.validating)
            }
            let recovered = try recoveredLibrary.recoverInterruptedGenerations()
            var missingOutputs = 0
            for line in recoveredLibrary.lines where line.status == .ready {
                guard let output = line.outputRelativePath else { continue }
                if (try? DialogueVoiceAssetInstaller.resolveManagedFile(
                    relativePath: output,
                    root: applicationSupportRoot,
                    maximumBytes: 67_108_864
                )) == nil {
                    _ = try recoveredLibrary.editLine(id: line.id, text: line.text, language: line.textLanguage)
                    missingOutputs += 1
                }
            }
            if recoveredLibrary != library || recovered > 0 || missingOutputs > 0 {
                try store.save(recoveredLibrary)
                library = recoveredLibrary
                activityMessage = library.profile == nil
                    ? "Recovered \(recovered + missingOutputs) dialogue generation task(s)."
                    : "Validating the saved voice profile before generation and playback…"
            }
        } catch {
            persistenceBlocked = true
            activityMessage = "Dialogue recovery failed without changing the stored library."
            logger.error("event=library_recovery_failed code=STORE_FAILURE")
        }
        if !persistenceBlocked {
            let cleanup = retryPendingCleanup()
            if cleanup.requiresNotice {
                activityMessage = cleanupAwareMessage(
                    activityMessage ?? "Voice cleanup remains pending.",
                    outcome: cleanup
                )
            }
        }
        notify()
        if !persistenceBlocked, let profile = library.profile {
            validatePersistedProfile(profile)
        } else {
            processNextQueuedLine()
        }
    }

    func shutdown() {
        assertMainThread()
        started = false
        activeImportTask?.cancel()
        importSequence &+= 1
        activeImportTask = nil
        profileValidationTask?.cancel()
        profileValidationSequence &+= 1
        profileValidationTask = nil
        validatedAssetIdentities = nil
        activeGenerationTask?.cancel()
        activeGenerationTask = nil
        activeTicket = nil
        audioPlayer.stop()
    }

    func importAsset(sourceURL: URL, kind: DialogueVoiceAssetKind, preserving draft: DialogueVoiceProfileDraft) {
        assertMainThread()
        guard !persistenceBlocked else { return }
        self.draft = draft
        activeImportTask?.cancel()
        importSequence &+= 1
        let sequence = importSequence
        activityMessage = "Importing \(assetDisplayName(kind))…"
        notify()
        let installer = installer
        activeImportTask = Task.detached(priority: .userInitiated) { [self] in
            let result: Result<DialogueVoiceInstalledAsset, DialogueVoiceRuntimeError>
            do {
                result = .success(try installer.install(sourceURL: sourceURL, kind: kind))
            } catch let error as DialogueVoiceRuntimeError {
                result = .failure(error)
            } catch is CancellationError {
                result = .failure(.cancelled)
            } catch {
                result = .failure(.copyFailed)
            }
            await MainActor.run {
                guard sequence == self.importSequence else {
                    if case let .success(asset) = result {
                        let cleanup = self.deferCleanup(paths: [asset.relativePath])
                        if cleanup.requiresNotice {
                            self.activityMessage = self.cleanupAwareMessage(
                                "An outdated imported voice asset was discarded.",
                                outcome: cleanup
                            )
                            self.notify()
                        }
                    }
                    return
                }
                self.activeImportTask = nil
                switch result {
                case let .success(asset):
                    self.replaceImportedAsset(kind: kind, asset: asset)
                    self.activityMessage = self.persistenceBlocked
                        ? "The asset was imported, but cleanup state could not be saved. Restart Statelet before editing voice data."
                        : self.cleanupAwareMessage(
                            "\(self.assetDisplayName(kind)) imported. Save the profile to use it.",
                            outcome: .retryPending(self.library.pendingCleanupPaths.count)
                        )
                    self.logger.info("event=asset_imported kind=\(kind.rawValue, privacy: .public)")
                case let .failure(error):
                    self.activityMessage = error.localizedDescription
                    self.logger.error("event=asset_import_failed kind=\(kind.rawValue, privacy: .public) code=\(error.safeCode, privacy: .public)")
                }
                self.notify()
            }
        }
    }

    func saveProfile(_ draft: DialogueVoiceProfileDraft) throws {
        assertMainThread()
        guard !persistenceBlocked else { throw DialogueVoiceError.storeFailure }
        guard let gptPath = importedAssets.gptWeightRelativePath,
              let assetDigests = importedAssets.digests,
              let sovitsPath = importedAssets.sovitsWeightRelativePath,
              let referencePath = importedAssets.referenceAudioRelativePath,
              let apiURL = URL(string: draft.apiBaseURL) else {
            throw DialogueVoiceError.invalidProfile
        }
        _ = try DialogueVoiceAssetInstaller.resolveManagedFile(
            relativePath: gptPath,
            root: applicationSupportRoot,
            maximumBytes: DialogueVoiceAssetKind.gptWeight.maximumBytes
        )
        _ = try DialogueVoiceAssetInstaller.resolveManagedFile(
            relativePath: sovitsPath,
            root: applicationSupportRoot,
            maximumBytes: DialogueVoiceAssetKind.sovitsWeight.maximumBytes
        )
        _ = try DialogueVoiceAssetInstaller.resolveManagedFile(
            relativePath: referencePath,
            root: applicationSupportRoot,
            maximumBytes: DialogueVoiceAssetKind.referenceAudio.maximumBytes
        )

        let previousProfile = library.profile
        let fingerprint = DialogueVoiceProfileFingerprint.compute(
            apiBaseURL: apiURL,
            referenceText: draft.referenceText,
            promptLanguage: draft.promptLanguage,
            defaultTextLanguage: draft.defaultTextLanguage,
            assetDigests: assetDigests
        )
        let profile = try GPTSoVITSVoiceProfile(
            id: previousProfile?.id ?? UUID(),
            revision: (previousProfile?.revision ?? 0) + 1,
            name: draft.name,
            apiBaseURL: apiURL,
            gptWeightRelativePath: gptPath,
            sovitsWeightRelativePath: sovitsPath,
            referenceAudioRelativePath: referencePath,
            referenceText: draft.referenceText,
            promptLanguage: draft.promptLanguage,
            defaultTextLanguage: draft.defaultTextLanguage,
            inputFingerprint: fingerprint
        )

        profileValidationTask?.cancel()
        profileValidationSequence &+= 1
        profileValidationTask = nil
        validatedAssetIdentities = nil
        activeGenerationTask?.cancel()
        audioPlayer.stop()
        let priorGeneratedPaths = library.lines.compactMap(\.outputRelativePath)
        let replacedAssetPaths = replacedAssets(
            previousProfile: previousProfile,
            activeProfile: profile
        )
        var updated = library
        try updated.replaceActiveProfile(profile)
        for line in updated.lines where line.status == .stale {
            _ = try updated.retryLine(id: line.id)
        }
        try updated.setProfileStatus(.validating)
        try updated.enqueueCleanup(paths: priorGeneratedPaths + replacedAssetPaths)
        do {
            try store.save(updated)
        } catch {
            if let previousProfile { validatePersistedProfile(previousProfile) }
            throw error
        }
        library = updated
        self.draft = draft
        let cleanup = retryPendingCleanup()
        activityMessage = cleanupAwareMessage(
            "Voice profile saved. Validating its assets and the local GPT-SoVITS service…",
            outcome: cleanup
        )
        logger.info("event=profile_saved revision=\(profile.revision, privacy: .public)")
        notify()
        validatePersistedProfile(profile)
    }

    func removeProfile() throws {
        assertMainThread()
        guard !persistenceBlocked else { throw DialogueVoiceError.storeFailure }
        activeImportTask?.cancel()
        importSequence &+= 1
        activeImportTask = nil
        profileValidationTask?.cancel()
        profileValidationSequence &+= 1
        profileValidationTask = nil
        validatedAssetIdentities = nil
        activeGenerationTask?.cancel()
        audioPlayer.stop()
        let profile = library.profile
        let managedAssetPaths = Set([
            importedAssets.gptWeightRelativePath,
            importedAssets.sovitsWeightRelativePath,
            importedAssets.referenceAudioRelativePath,
            profile?.gptWeightRelativePath,
            profile?.sovitsWeightRelativePath,
            profile?.referenceAudioRelativePath,
        ].compactMap { $0 })
        let generatedPaths = library.lines.compactMap(\.outputRelativePath)
        let resetLines = try library.lines.map { line in
            try DialogueLine(
                id: line.id,
                text: line.text,
                textLanguage: line.textLanguage,
                revision: line.revision,
                status: .draft
            )
        }
        var updated = try DialogueVoiceLibrary(
            profile: nil,
            lines: resetLines,
            pendingCleanupPaths: library.pendingCleanupPaths
        )
        try updated.enqueueCleanup(paths: generatedPaths + managedAssetPaths.sorted())
        try store.save(updated)
        library = updated
        let cleanup = retryPendingCleanup()
        importedAssets = DialogueVoiceImportedAssets()
        draft = DialogueVoiceProfileDraft(
            name: "",
            apiBaseURL: "http://127.0.0.1:9880",
            promptLanguage: "",
            defaultTextLanguage: "",
            referenceText: ""
        )
        activityMessage = cleanupAwareMessage(
            "Voice profile removed. Dialogue text was kept as drafts.",
            outcome: cleanup
        )
        logger.info("event=profile_removed")
        notify()
    }

    func addLine(text: String, language: String) throws {
        assertMainThread()
        guard !persistenceBlocked else { throw DialogueVoiceError.storeFailure }
        _ = try commit { try $0.addLine(text: text, language: language) }
        activityMessage = library.profileStatus == .ready
            ? "Dialogue queued for voice generation."
            : library.profile == nil
            ? "Dialogue saved as a draft. Configure a voice profile to generate speech."
            : "Dialogue saved as a draft until the voice profile is ready."
        notify()
        processNextQueuedLine()
    }

    func updateLine(id: UUID, text: String, language: String) throws {
        assertMainThread()
        guard !persistenceBlocked else { throw DialogueVoiceError.storeFailure }
        let oldOutput = library.lines.first(where: { $0.id == id })?.outputRelativePath
        if activeTicket?.lineID == id { activeGenerationTask?.cancel() }
        _ = try commit {
            let line = try $0.editLine(id: id, text: text, language: language)
            try $0.enqueueCleanup(paths: oldOutput.map { [$0] } ?? [])
            return line
        }
        let cleanup = retryPendingCleanup()
        let message = library.profileStatus == .ready
            ? "Dialogue updated and queued for fresh voice generation."
            : "Dialogue updated and saved as a draft until the voice profile is ready."
        activityMessage = cleanupAwareMessage(message, outcome: cleanup)
        notify()
        processNextQueuedLine()
    }

    func retryLine(id: UUID) throws {
        assertMainThread()
        guard !persistenceBlocked else { throw DialogueVoiceError.storeFailure }
        let oldOutput = library.lines.first(where: { $0.id == id })?.outputRelativePath
        _ = try commit {
            if $0.profileStatus == .unavailable {
                _ = try $0.activateValidatedProfile()
            }
            let line = try $0.retryLine(id: id)
            try $0.enqueueCleanup(paths: oldOutput.map { [$0] } ?? [])
            return line
        }
        let cleanup = retryPendingCleanup()
        activityMessage = cleanupAwareMessage(
            "Dialogue queued for retry.",
            outcome: cleanup
        )
        notify()
        processNextQueuedLine()
    }

    func regenerateLine(id: UUID) throws {
        assertMainThread()
        guard !persistenceBlocked else { throw DialogueVoiceError.storeFailure }
        guard let line = library.lines.first(where: { $0.id == id }) else {
            throw DialogueVoiceError.lineNotFound
        }
        try updateLine(id: id, text: line.text, language: line.textLanguage)
    }

    func deleteLine(id: UUID) throws {
        assertMainThread()
        guard !persistenceBlocked else { throw DialogueVoiceError.storeFailure }
        if activeTicket?.lineID == id { activeGenerationTask?.cancel() }
        _ = try commit {
            let removed = try $0.removeLine(id: id)
            try $0.enqueueCleanup(paths: removed.outputRelativePath.map { [$0] } ?? [])
            return removed
        }
        let cleanup = retryPendingCleanup()
        activityMessage = cleanupAwareMessage(
            "Dialogue deleted.",
            outcome: cleanup
        )
        logger.info("event=line_deleted line_id=\(id.uuidString, privacy: .public)")
        notify()
        processNextQueuedLine()
    }

    func previewLine(id: UUID) throws {
        assertMainThread()
        guard playReadyLine(id: id) == .played else {
            throw DialogueVoiceError.outputNotReady
        }
        activityMessage = "Playing generated dialogue audio."
        logger.info("event=preview_started line_id=\(id.uuidString, privacy: .public)")
        notify()
    }

    @discardableResult
    func playReadyLine(id: UUID) -> DialoguePlaybackResult {
        assertMainThread()
        return playbackService.playReadyLine(id: id, in: library)
    }

    private func validatePersistedProfile(_ profile: GPTSoVITSVoiceProfile) {
        profileValidationTask?.cancel()
        profileValidationSequence &+= 1
        let sequence = profileValidationSequence
        let root = applicationSupportRoot
        let readyOutputs = library.lines.compactMap { line -> ReadyOutputValidationTicket? in
            guard line.status == .ready, let outputRelativePath = line.outputRelativePath else {
                return nil
            }
            return ReadyOutputValidationTicket(
                lineID: line.id,
                lineRevision: line.revision,
                outputRelativePath: outputRelativePath
            )
        }
        profileValidationTask = Task.detached(priority: .utility) { [self] in
            let result: ProfileValidationResult
            do {
                let validatedAssets = try DialogueVoiceProfileFingerprint.validateAssets(
                    profile: profile,
                    applicationSupportRoot: root
                )
                let fingerprint = DialogueVoiceProfileFingerprint.compute(
                    apiBaseURL: profile.apiBaseURL,
                    referenceText: profile.referenceText,
                    promptLanguage: profile.promptLanguage,
                    defaultTextLanguage: profile.defaultTextLanguage,
                    assetDigests: validatedAssets.digests
                )
                if fingerprint == profile.inputFingerprint {
                    let invalidOutputs = readyOutputs.filter { output in
                        guard let data = try? DialogueVoiceAssetInstaller.readManagedFile(
                            relativePath: output.outputRelativePath,
                            root: root,
                            maximumBytes: 67_108_864
                        ) else {
                            return true
                        }
                        return !GPTSoVITSAPIClient.isValidWAV(data)
                    }
                    do {
                        try await self.client.validateProfile(
                            profile,
                            applicationSupportRoot: root
                        )
                        result = .valid(validatedAssets, invalidOutputs)
                    } catch let error as DialogueVoiceRuntimeError
                        where error == .inferenceUnavailable || error == .cancelled {
                        result = .unavailable(validatedAssets, invalidOutputs)
                    } catch {
                        result = .invalid
                    }
                } else {
                    result = .invalid
                }
            } catch {
                result = .invalid
            }
            await MainActor.run {
                guard sequence == self.profileValidationSequence,
                      self.library.profile?.id == profile.id,
                      self.library.profile?.revision == profile.revision,
                      self.library.profile?.inputFingerprint == profile.inputFingerprint else {
                    return
                }
                self.profileValidationTask = nil
                self.finishProfileValidation(profile: profile, result: result)
            }
        }
    }

    private func finishProfileValidation(
        profile: GPTSoVITSVoiceProfile,
        result: ProfileValidationResult
    ) {
        do {
            switch result {
            case let .valid(validatedAssets, invalidOutputs):
                var updated = try libraryAfterInvalidatingOutputs(invalidOutputs)
                _ = try updated.activateValidatedProfile()
                let replacedOutputs = obsoleteOutputPaths(before: library, after: updated)
                try updated.enqueueCleanup(paths: replacedOutputs)
                try store.save(updated)
                library = updated
                mergeValidatedDigests(profile: profile, digests: validatedAssets.digests)
                validatedAssetIdentities = validatedAssets.identities
                let cleanup = retryPendingCleanup()
                activityMessage = cleanupAwareMessage(
                    "Voice profile validation completed.",
                    outcome: cleanup
                )
                logger.info("event=profile_validated revision=\(profile.revision, privacy: .public)")
            case let .unavailable(validatedAssets, invalidOutputs):
                var updated = try libraryAfterInvalidatingOutputs(invalidOutputs)
                let replacedOutputs = obsoleteOutputPaths(before: library, after: updated)
                try updated.setProfileStatus(.unavailable)
                try updated.enqueueCleanup(paths: replacedOutputs)
                try store.save(updated)
                library = updated
                mergeValidatedDigests(profile: profile, digests: validatedAssets.digests)
                validatedAssetIdentities = validatedAssets.identities
                let cleanup = retryPendingCleanup()
                activityMessage = cleanupAwareMessage(
                    "Voice assets are valid, but the local GPT-SoVITS service is unavailable. Start API v2 and save the profile again.",
                    outcome: cleanup
                )
                logger.error("event=profile_unavailable code=INFERENCE_UNAVAILABLE")
            case .invalid:
                var updated = library
                try updated.setProfileStatus(.invalid, invalidatingOutputs: true)
                try store.save(updated)
                library = updated
                clearDigestsForActiveProfile(profile)
                validatedAssetIdentities = nil
                activityMessage = "The saved voice assets changed, are missing, or are no longer valid. Re-import them before generating speech."
                logger.error("event=profile_validation_failed code=INPUT_FINGERPRINT_MISMATCH")
            }
        } catch {
            persistenceBlocked = true
            activityMessage = "Voice profile validation could not update the stored library."
            logger.error("event=profile_validation_store_failed code=STORE_FAILURE")
        }
        notify()
        processNextQueuedLine()
    }

    private func libraryAfterInvalidatingOutputs(
        _ invalidOutputs: [ReadyOutputValidationTicket]
    ) throws -> DialogueVoiceLibrary {
        var updated = library
        for output in invalidOutputs {
            guard let current = updated.lines.first(where: { $0.id == output.lineID }),
                  current.revision == output.lineRevision,
                  current.status == .ready,
                  current.outputRelativePath == output.outputRelativePath else {
                continue
            }
            _ = try updated.editLine(
                id: current.id,
                text: current.text,
                language: current.textLanguage
            )
        }
        return updated
    }

    private func obsoleteOutputPaths(
        before: DialogueVoiceLibrary,
        after: DialogueVoiceLibrary
    ) -> [String] {
        let retainedPaths = Set(after.lines.compactMap(\.outputRelativePath))
        return before.lines.compactMap(\.outputRelativePath).filter { !retainedPaths.contains($0) }
    }

    private func processNextQueuedLine() {
        guard started, !persistenceBlocked, activeGenerationTask == nil,
              library.profileStatus == .ready,
              let profile = library.profile,
              let queued = library.lines.first(where: { $0.status == .queued }) else { return }
        do {
            let ticket = try commit { try $0.beginGeneration(for: queued.id) }
            let line = try requireLine(ticket.lineID)
            activeTicket = ticket
            activityMessage = "Generating dialogue audio…"
            logger.info("event=generation_started line_id=\(ticket.lineID.uuidString, privacy: .public) revision=\(ticket.lineRevision, privacy: .public)")
            notify()

            let client = client
            let publisher = publisher
            let root = applicationSupportRoot
            let expectedIdentities = validatedAssetIdentities
            activeGenerationTask = Task.detached(priority: .userInitiated) { [self] in
                let result: GenerationResult
                do {
                    let currentIdentities = try DialogueVoiceProfileFingerprint.assetIdentities(
                        profile: profile,
                        applicationSupportRoot: root
                    )
                    let generationIdentities: DialogueVoiceAssetIdentities
                    if currentIdentities == expectedIdentities {
                        generationIdentities = currentIdentities
                    } else {
                        let validatedAssets = try DialogueVoiceProfileFingerprint.validateAssets(
                            profile: profile,
                            applicationSupportRoot: root
                        )
                        let fingerprint = DialogueVoiceProfileFingerprint.compute(
                            apiBaseURL: profile.apiBaseURL,
                            referenceText: profile.referenceText,
                            promptLanguage: profile.promptLanguage,
                            defaultTextLanguage: profile.defaultTextLanguage,
                            assetDigests: validatedAssets.digests
                        )
                        guard fingerprint == profile.inputFingerprint else {
                            throw DialogueVoiceRuntimeError.inputFingerprintMismatch
                        }
                        generationIdentities = validatedAssets.identities
                    }
                    let data = try await client.synthesize(
                        profile: profile,
                        line: line,
                        applicationSupportRoot: root
                    )
                    try Task.checkCancellation()
                    let finalIdentities = try DialogueVoiceProfileFingerprint.assetIdentities(
                        profile: profile,
                        applicationSupportRoot: root
                    )
                    guard finalIdentities == generationIdentities else {
                        throw DialogueVoiceRuntimeError.inputFingerprintMismatch
                    }
                    result = .success(
                        try publisher.publish(data: data, ticket: ticket),
                        finalIdentities
                    )
                } catch let error as DialogueVoiceRuntimeError {
                    result = .failure(error.safeCode)
                } catch is CancellationError {
                    result = .failure(DialogueVoiceRuntimeError.cancelled.safeCode)
                } catch {
                    result = .failure(DialogueVoiceRuntimeError.inferenceUnavailable.safeCode)
                }
                await MainActor.run {
                    self.finishGeneration(ticket: ticket, result: result)
                }
            }
        } catch {
            activityMessage = "Dialogue generation could not start."
            logger.error("event=generation_start_failed code=INVALID_STATE")
            notify()
        }
    }

    private func finishGeneration(ticket: DialogueGenerationTicket, result: GenerationResult) {
        guard started else {
            if case let .success(outputPath, _) = result {
                deferCleanup(paths: [outputPath])
            }
            return
        }
        activeGenerationTask = nil
        activeTicket = nil
        switch result {
        case let .success(outputPath, identities):
            do {
                _ = try commit { try $0.completeGeneration(ticket: ticket, outputPath: outputPath) }
                validatedAssetIdentities = identities
                activityMessage = "Dialogue audio is ready."
                logger.info("event=generation_ready line_id=\(ticket.lineID.uuidString, privacy: .public) revision=\(ticket.lineRevision, privacy: .public)")
            } catch {
                let cleanup = deferCleanup(paths: [outputPath])
                activityMessage = cleanupAwareMessage(
                    "An outdated generation result was discarded.",
                    outcome: cleanup
                )
                logger.info("event=generation_result_discarded code=STALE_RESULT")
            }
        case let .failure(code):
            do {
                _ = try commit {
                    let line = try $0.failGeneration(ticket: ticket, failureCode: code)
                    if code == DialogueVoiceRuntimeError.inferenceUnavailable.safeCode {
                        try $0.setProfileStatus(.unavailable)
                    } else if code == DialogueVoiceRuntimeError.profileRejected.safeCode
                        || code == DialogueVoiceRuntimeError.inputFingerprintMismatch.safeCode {
                        try $0.setProfileStatus(.invalid, invalidatingOutputs: true)
                    }
                    return line
                }
                if code == DialogueVoiceRuntimeError.cancelled.safeCode {
                    activityMessage = "Dialogue generation was cancelled."
                } else if code == DialogueVoiceRuntimeError.profileRejected.safeCode {
                    validatedAssetIdentities = nil
                    activityMessage = "GPT-SoVITS rejected the active profile. Review its inputs, re-import if needed, and save the profile again."
                } else if code == DialogueVoiceRuntimeError.inputFingerprintMismatch.safeCode {
                    validatedAssetIdentities = nil
                    if let profile = library.profile {
                        clearDigestsForActiveProfile(profile)
                    }
                    activityMessage = "The managed voice inputs changed after validation. Re-import them and save the profile again."
                } else if code == DialogueVoiceRuntimeError.requestRejected.safeCode {
                    activityMessage = "GPT-SoVITS rejected this dialogue or language value. Edit the line and try again."
                } else {
                    activityMessage = "Dialogue generation failed. Use Retry after checking the local GPT-SoVITS service."
                }
                logger.error("event=generation_failed line_id=\(ticket.lineID.uuidString, privacy: .public) code=\(code, privacy: .public)")
            } catch {
                activityMessage = "An outdated generation failure was discarded."
            }
        }
        notify()
        processNextQueuedLine()
    }

    private func commit<Value>(
        _ mutation: (inout DialogueVoiceLibrary) throws -> Value
    ) throws -> Value {
        var updated = library
        let value = try mutation(&updated)
        try store.save(updated)
        library = updated
        return value
    }

    private func notify() {
        onChange?(snapshot)
    }

    private func requireLine(_ id: UUID) throws -> DialogueLine {
        guard let line = library.lines.first(where: { $0.id == id }) else {
            throw DialogueVoiceError.lineNotFound
        }
        return line
    }

    private func replaceImportedAsset(kind: DialogueVoiceAssetKind, asset: DialogueVoiceInstalledAsset) {
        let previous: String?
        switch kind {
        case .gptWeight:
            previous = importedAssets.gptWeightRelativePath
            importedAssets.gptWeightRelativePath = asset.relativePath
            importedAssets.gptWeightDigest = asset.contentDigest
        case .sovitsWeight:
            previous = importedAssets.sovitsWeightRelativePath
            importedAssets.sovitsWeightRelativePath = asset.relativePath
            importedAssets.sovitsWeightDigest = asset.contentDigest
        case .referenceAudio:
            previous = importedAssets.referenceAudioRelativePath
            importedAssets.referenceAudioRelativePath = asset.relativePath
            importedAssets.referenceAudioDigest = asset.contentDigest
        }
        let activePaths = Set([
            library.profile?.gptWeightRelativePath,
            library.profile?.sovitsWeightRelativePath,
            library.profile?.referenceAudioRelativePath,
        ].compactMap { $0 })
        if let previous, previous != asset.relativePath, !activePaths.contains(previous) {
            deferCleanup(paths: [previous])
        }
    }

    private func mergeValidatedDigests(
        profile: GPTSoVITSVoiceProfile,
        digests: DialogueVoiceAssetDigests
    ) {
        if importedAssets.gptWeightRelativePath == profile.gptWeightRelativePath {
            importedAssets.gptWeightDigest = digests.gptWeight
        }
        if importedAssets.sovitsWeightRelativePath == profile.sovitsWeightRelativePath {
            importedAssets.sovitsWeightDigest = digests.sovitsWeight
        }
        if importedAssets.referenceAudioRelativePath == profile.referenceAudioRelativePath {
            importedAssets.referenceAudioDigest = digests.referenceAudio
        }
    }

    private func clearDigestsForActiveProfile(_ profile: GPTSoVITSVoiceProfile) {
        if importedAssets.gptWeightRelativePath == profile.gptWeightRelativePath {
            importedAssets.gptWeightDigest = nil
        }
        if importedAssets.sovitsWeightRelativePath == profile.sovitsWeightRelativePath {
            importedAssets.sovitsWeightDigest = nil
        }
        if importedAssets.referenceAudioRelativePath == profile.referenceAudioRelativePath {
            importedAssets.referenceAudioDigest = nil
        }
    }

    private func replacedAssets(
        previousProfile: GPTSoVITSVoiceProfile?,
        activeProfile: GPTSoVITSVoiceProfile
    ) -> [String] {
        guard let previousProfile else { return [] }
        let active = Set([
            activeProfile.gptWeightRelativePath,
            activeProfile.sovitsWeightRelativePath,
            activeProfile.referenceAudioRelativePath,
        ])
        return [
            previousProfile.gptWeightRelativePath,
            previousProfile.sovitsWeightRelativePath,
            previousProfile.referenceAudioRelativePath,
        ].filter { !active.contains($0) }
    }

    @discardableResult
    private func deferCleanup(paths: [String]) -> CleanupOutcome {
        guard !paths.isEmpty else { return .complete }
        var updated = library
        do {
            try updated.enqueueCleanup(paths: paths)
        } catch {
            persistenceBlocked = true
            logger.error("event=cleanup_schedule_rejected code=ACTIVE_REFERENCE_OR_INVALID_PATH")
            return CleanupOutcome(
                remainingCount: paths.count,
                issue: .activeReferenceConflict
            )
        }
        do {
            try store.save(updated)
            library = updated
            return retryPendingCleanup()
        } catch {
            persistenceBlocked = true
            var failedCount = 0
            var referenceConflict = false
            for path in paths {
                guard !library.referencedManagedPaths.contains(path) else {
                    failedCount += 1
                    referenceConflict = true
                    continue
                }
                do {
                    _ = try DialogueVoiceAssetInstaller.removeManagedFile(
                        relativePath: path,
                        root: applicationSupportRoot,
                        maximumBytes: DialogueVoiceAssetKind.gptWeight.maximumBytes
                    )
                } catch {
                    failedCount += 1
                }
            }
            logger.error("event=cleanup_schedule_failed code=STORE_FAILURE")
            return CleanupOutcome(
                remainingCount: failedCount,
                issue: referenceConflict ? .activeReferenceConflict : .metadataPersistenceFailed
            )
        }
    }

    @discardableResult
    private func retryPendingCleanup() -> CleanupOutcome {
        let candidates = library.pendingCleanupPaths
        guard !candidates.isEmpty else { return .complete }
        let referencedPaths = library.referencedManagedPaths
        guard Set(candidates).isDisjoint(with: referencedPaths) else {
            persistenceBlocked = true
            logger.error("event=cleanup_reference_conflict code=INVALID_CLEANUP_STATE")
            return CleanupOutcome(
                remainingCount: candidates.count,
                issue: .activeReferenceConflict
            )
        }
        var remaining: [String] = []
        for path in candidates {
            guard !library.referencedManagedPaths.contains(path) else {
                persistenceBlocked = true
                logger.error("event=cleanup_reference_conflict code=INVALID_CLEANUP_STATE")
                return CleanupOutcome(
                    remainingCount: candidates.count,
                    issue: .activeReferenceConflict
                )
            }
            do {
                _ = try DialogueVoiceAssetInstaller.removeManagedFile(
                    relativePath: path,
                    root: applicationSupportRoot,
                    maximumBytes: DialogueVoiceAssetKind.gptWeight.maximumBytes
                )
            } catch {
                remaining.append(path)
            }
        }
        if remaining != candidates {
            do {
                var updated = library
                try updated.replacePendingCleanupPaths(remaining)
                try store.save(updated)
                library = updated
            } catch {
                persistenceBlocked = true
                logger.error("event=cleanup_state_save_failed code=STORE_FAILURE")
                return CleanupOutcome(
                    remainingCount: candidates.count,
                    issue: .metadataPersistenceFailed
                )
            }
        }
        if !remaining.isEmpty {
            logger.error("event=cleanup_deferred count=\(remaining.count, privacy: .public) code=CLEANUP_RETRY_PENDING")
        }
        return .retryPending(remaining.count)
    }

    private func cleanupAwareMessage(_ message: String, outcome: CleanupOutcome) -> String {
        switch outcome.issue {
        case nil:
            return message
        case .retryPending:
            return "\(message) \(outcome.remainingCount) private voice file(s) could not be removed and will be retried at next launch."
        case .metadataPersistenceFailed:
            if outcome.remainingCount == 0 {
                return "\(message) Voice cleanup completed, but its metadata could not be saved. Restart Statelet before editing voice data."
            }
            return "\(message) \(outcome.remainingCount) private voice file(s) could not be removed or recorded safely; restart Statelet before editing."
        case .activeReferenceConflict:
            return "\(message) Cleanup was stopped because private voice data is still referenced. Restart Statelet before editing voice data."
        }
    }

    private func assetDisplayName(_ kind: DialogueVoiceAssetKind) -> String {
        switch kind {
        case .gptWeight: return "GPT weight"
        case .sovitsWeight: return "SoVITS weight"
        case .referenceAudio: return "Reference audio"
        }
    }

    private func assertMainThread() {
        precondition(Thread.isMainThread, "Dialogue voice state must be mutated on the main thread")
    }
}
