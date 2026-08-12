import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT / "mac/CodexPetMac/Sources/CodexPetMac/PetAppDelegate.swift"
PLAYER = ROOT / "mac/CodexPetMac/Sources/CodexPetMac/PetPlayer.swift"


class MacLifecycleTransitionRuntimeSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = APP.read_text()
        cls.player = PLAYER.read_text()

    def test_rapid_authoritative_change_is_token_gated_and_uses_committed_source(self):
        self.assertIn("lastCommittedLifecycleState", self.app)
        self.assertIn('"authoritative_state_changed"', self.app)
        self.assertIn("LifecycleTransitionCompletionDecision.decide", self.app)
        self.assertIn("activeID == callbackID", self.app)

    def test_manual_and_refresh_paths_do_not_start_transition(self):
        for trigger in (
            "initialPresentation", "sameStateHeartbeat", "forcedRefresh",
            "playlistRotation", "nextClip", "playOnce", "temporaryState",
        ):
            self.assertIn(trigger, self.app)
        self.assertIn("trigger == .authoritativeChange", self.app)
        self.assertIn("previousLifecycleState == incomingState", self.app)
        self.assertIn("trigger: presentationTrigger", self.app)

    def test_failure_falls_through_to_current_destination(self):
        self.assertIn("onLifecycleTransitionFailed", self.player)
        self.assertIn('outcome: "failed"', self.app)
        self.assertIn(r'refreshReason: "lifecycle_transition_\(outcome)"', self.app)

    def test_dialogue_only_starts_from_destination_presentation_commit(self):
        finish = self.app.index("private func finishLifecycleTransition")
        destination = self.app.index("startLifecyclePresentation(", finish)
        dialogue = self.app.index("presentStateOwnedDialogueIfNeeded", destination)
        self.assertLess(destination, dialogue)
        self.assertIn("stateDialoguePresentation = nil", self.app[finish - 5000:finish])

    def test_reduce_motion_and_character_change_cancel_transition(self):
        self.assertIn("!reduceMotion", self.app)
        self.assertIn('cancelActiveLifecycleTransition(reason: "character_changed")', self.app)
        self.assertIn("lastCommittedLifecycleState = nil", self.app)

    def test_duration_deadline_starts_after_display_readiness(self):
        show = self.player.index("func showLifecycleTransition")
        end = self.player.index("func setReduceMotion", show)
        source = self.player[show:end]
        self.assertIn("scheduleLifecycleTransitionTimeout", source)
        self.assertIn("startedAt: startedAt", source)
        timeout = self.player.index("private func scheduleLifecycleTransitionTimeout")
        timeout_end = self.player.index("private func abortLifecycleTransition", timeout)
        self.assertIn("LifecycleTransitionDeadline.uptimeNanoseconds", self.player[timeout:timeout_end])

    def test_publisher_rejection_cancels_transition_and_forces_idle_without_transition(self):
        start = self.app.index("private func rejectPublisher")
        end = self.app.index("private func setPublisherHealth", start)
        source = self.app[start:end]
        self.assertIn('cancelActiveLifecycleTransition(reason: "publisher_rejected")', source)
        self.assertIn("apply(state: .idle, forceRefresh: true)", source)

    def test_conversion_journal_preserves_transition_route_and_recovery_duration_gate(self):
        self.assertIn('case transitionFrom = "transition_from"', self.app)
        self.assertIn('case transitionTo = "transition_to"', self.app)
        self.assertIn('case characterID = "character_id"', self.app)
        self.assertIn('case mediaMapBasename = "media_map_basename"', self.app)
        self.assertIn('case mediaMapSHA256 = "media_map_sha256"', self.app)
        self.assertIn("let owner = try? recoveryOwner(for: journal)", self.app)
        self.assertIn("saveRecoveredMediaMap(", self.app)
        self.assertIn("expectedData: owner.encodedData", self.app)
        self.assertIn("expectedCatalogData: owner.catalogEncodedData", self.app)
        self.assertIn('throw PetContractError.invalidValue("legacy recovery owner is ambiguous")', self.app)
        self.assertIn("catalogSnapshot.encodedData == characterLibraryEncodedData", self.app)
        self.assertIn("Self.isValidRecoveryRoute(journal)", self.app)
        self.assertIn("Self.recoveryArtifactStem(journal, state: state)", self.app)
        recovery = self.app.index("private func recoverInterruptedConversionIfPresent")
        recovery_end = self.app.index("private static func isValidInvocationChallenge", recovery)
        recovery_source = self.app[recovery:recovery_end]
        self.assertIn("LifecycleTransitionMediaPolicy.maximumDuration", recovery_source)
        self.assertIn("settingTransition", recovery_source)
        self.assertNotIn("removeItem(at: journalURL)", recovery_source)
        self.assertIn("journal and artifacts were retained for retry", recovery_source)
        self.assertNotIn("quarantineFailedRecoveryArtifacts", recovery_source)
        self.assertIn("requireValidatedFilesUnchanged", recovery_source)

    def test_recovery_updates_journal_owner_without_replacing_different_active_character(self):
        owner = self.app.index("private func recoveryOwner(for journal:")
        owner_end = self.app.index("private static func isValidInvocationChallenge", owner)
        owner_source = self.app[owner:owner_end]
        self.assertIn("let matched = catalog.character(id: characterID)", owner_source)
        self.assertIn("entry = matched", owner_source)
        self.assertIn("entry.id == catalog.activeCharacterID", owner_source)

        recovery = self.app.index("private func recoverInterruptedConversionIfPresent")
        recovery_end = self.app.index("private func recoveryOwner(for journal:", recovery)
        recovery_source = self.app[recovery:recovery_end]
        save = recovery_source.index("saveRecoveredMediaMap(")
        active_branch = recovery_source.index("if owner.isActive", save)
        self.assertLess(save, active_branch)
        self.assertIn("for: owner.entry", recovery_source[save:active_branch])
        self.assertIn("self.mediaMapEncodedData = encoded", recovery_source[active_branch:])
        self.assertIn("self.applyPublishedMediaMap(updated)", recovery_source[active_branch:])
        self.assertIn("self.characterClipCounts[owner.entry.id]", recovery_source[active_branch:])

    def test_malformed_recovery_journal_is_retained_before_async_recovery_starts(self):
        recovery = self.app.index("private func recoverInterruptedConversionIfPresent")
        task = self.app.index("Task { @MainActor", recovery)
        validation_gate = self.app[recovery:task]
        self.assertIn("JSONDecoder().decode(ActiveConversionJournal.self", validation_gate)
        self.assertIn("let owner = try? recoveryOwner(for: journal)", validation_gate)
        self.assertIn("Self.isValidRecoveryRoute(journal)", validation_gate)
        self.assertIn("Self.isValidInvocationChallenge(journal.invocationChallenge)", validation_gate)
        self.assertNotIn("clearConversionJournal", validation_gate)
        self.assertNotIn("removeItem", validation_gate)

    def test_all_cleanup_exclusion_callers_include_transition_entries(self):
        helper_start = self.app.index("private func allMediaEntries(in map:")
        helper_end = self.app.index("private func applyConfiguredWindowSize", helper_start)
        self.assertIn("Array(map.transitions.values)", self.app[helper_start:helper_end])

        for name, end_marker in (
            ("private func isMediaPathReferenced(_ url:", "private func isMediaPathReferencedByInactiveCharacter"),
            ("private func isMediaPathReferencedByInactiveCharacter(_ url:", "private func mediaMap(_ map:"),
            ("private func mediaMap(_ map:", "private func allCharacterMediaMaps"),
            ("private func unusedMediaCandidates()", "private func isInsideManagedMedia"),
        ):
            start = self.app.index(name)
            end = self.app.index(end_marker, start)
            self.assertIn("allMediaEntries(in:", self.app[start:end], name)

    def test_transition_removal_revalidates_character_map_and_route_after_confirmation(self):
        start = self.app.index("private func removeTransition")
        end = self.app.index("private func importMP4s", start)
        source = self.app[start:end]
        capture = source.index("let requestedCharacterID")
        callback = source.index("alert.beginSheetModal", capture)
        mutation = source.index("self.mediaMutationInProgress = true", callback)
        publish = source.index("try self.publishMediaMap(updated)", mutation)
        self.assertIn("self.characterLibrary.activeCharacterID == requestedCharacterID", source[callback:mutation])
        self.assertIn("self.mediaMapURL.standardizedFileURL == requestedMapURL", source[callback:mutation])
        self.assertIn("self.mediaMapEncodedData == requestedMapData", source[callback:mutation])
        self.assertIn("catalogSnapshot?.library == self.characterLibrary", source[callback:mutation])
        self.assertIn("catalogSnapshot?.encodedData == self.characterLibraryEncodedData", source[callback:mutation])
        self.assertIn("self.mediaMap.transition(from: source, to: destination)?.path == path", source[callback:mutation])
        self.assertLess(mutation, publish)

    def test_dialogue_waits_for_destination_visual_commit_on_sync_and_async_paths(self):
        presentation = self.app.index("private func startLifecyclePresentation(")
        presentation_end = self.app.index("private func advancePlaylistAfterClipEnd", presentation)
        presentation_source = self.app[presentation:presentation_end]
        presented = presentation_source.index("case .presented:")
        preparing = presentation_source.index("case .preparing:", presented)
        committed = presentation_source.index("lastCommittedLifecycleState = state", presented)
        dialogue = presentation_source.index("presentStateOwnedDialogueIfNeeded(for: state)", committed)
        self.assertLess(committed, dialogue)
        self.assertLess(dialogue, preparing)
        self.assertNotIn("presentStateOwnedDialogueIfNeeded", presentation_source[preparing:])

        event = self.app.index("private func handlePresentationEvent(")
        event_end = self.app.index("private func presentStateOwnedDialogueIfNeeded", event)
        event_source = self.app[event:event_end]
        ready = event_source.index("case .ready:", event_source.index("switch event"))
        committed = event_source.index("lastCommittedLifecycleState = state", ready)
        dialogue = event_source.index("presentStateOwnedDialogueIfNeeded(for: state)", committed)
        failed = event_source.index("case .failed:", dialogue)
        self.assertLess(committed, dialogue)
        self.assertLess(dialogue, failed)

    def test_missing_preview_media_reports_sanitized_error_and_restores(self):
        preview = self.app.index("private func previewTransition")
        removal = self.app.index("private func removeTransition", preview)
        preview_source = self.app[preview:removal]
        self.assertIn("isReadableFile", preview_source)
        self.assertIn("The transition movie is missing or unreadable.", preview_source)
        self.assertIn("apply(state: currentState, forceRefresh: true)", preview_source)
        self.assertNotIn("/Users/", preview_source)

    def test_portable_transition_cleans_staged_import_on_any_publish_failure(self):
        start = self.app.index("private func importTransitionMovie")
        end = self.app.index("private func importTransitionMP4", start)
        source = self.app[start:end]
        installed = source.index("let installed = try await prepareVerifiedMovie")
        cleanup = source.index("removeItem(at: installed.directory)", installed)
        publish = source.index("try publishMediaMap(updated)", installed)
        nested_catch = source.index("} catch {", publish)
        self.assertLess(publish, nested_catch)
        self.assertLess(nested_catch, cleanup)


if __name__ == "__main__":
    unittest.main()
