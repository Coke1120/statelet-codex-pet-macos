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

    def test_failure_tries_each_transition_variant_before_destination_fallback(self):
        self.assertIn("onLifecycleTransitionFailed", self.player)
        self.assertIn('outcome: "failed"', self.app)
        retry = self.player.index("private func retryLifecycleDestination")
        cancel = self.player.index("private func cancelLifecycleHandoff", retry)
        retry_source = self.player[retry:cancel]
        self.assertIn("destinationRetryCount == 0", retry_source)
        self.assertIn("view.destinationPlayerLayer.player = nil", retry_source)
        self.assertIn("observeLifecycleDestinationCurrentItem", retry_source)
        self.assertIn("cancelLifecycleHandoff(notifyFailure: true)", self.player)
        self.assertIn("view.cancelLifecycleHandoffLayers()", self.player)
        finish = self.app.index("private func finishLifecycleTransition")
        finish_end = self.app.index("private func cancelActiveLifecycleTransition", finish)
        finish_source = self.app[finish:finish_end]
        self.assertNotIn("player.clearTransientPresentation()", finish_source)
        self.assertIn('reason: "playback_failed"', finish_source)
        self.assertIn(
            "var selectionRequest = active.transitionSelectionRequest",
            finish_source,
        )
        self.assertIn("selectionRequest.commit(to: &cursor)", finish_source)
        self.assertIn("setTransitionSelectionCursor(cursor, for: active.transitionScope)", finish_source)

        retry = self.app.index("private func retryLifecycleTransition(")
        retry_end = self.app.index("private func finishLifecycleTransition(", retry)
        retry_source = self.app[retry:retry_end]
        self.assertIn("var selectionRequest = request.transitionSelectionRequest", retry_source)
        self.assertIn("selectionRequest.next()", retry_source)
        self.assertIn('refreshReason: "layered_handoff_variants_exhausted"', retry_source)
        self.assertIn("preselectedEntry: request.destinationEntry", retry_source)
        self.assertIn("advanceSelection: false", retry_source)
        self.assertIn("selectionRequest: request.destinationSelectionRequest", retry_source)
        self.assertIn("transitionSelectionRequest: selectionRequest", retry_source)

    def test_same_state_clip_end_uses_layered_handoff_and_direct_fallback(self):
        advance = self.app.index("private func advancePlaylistAfterClipEnd")
        begin = self.app.index("private func beginInStateTransition", advance)
        advance_source = self.app[advance:begin]
        self.assertIn("InStateTransitionPolicy.shouldTrigger", advance_source)
        self.assertIn("beginInStateTransition(state: state)", advance_source)
        self.assertIn('refreshReason: "clip_end"', advance_source)
        self.assertIn("mediaSelectionRequest(", advance_source)
        self.assertIn("useManualPreviewCursor: useManualPreviewCursor", advance_source)
        self.assertIn("preselectedEntry: selectionRequest.entry", advance_source)
        self.assertIn("selectionRequest: selectionRequest", advance_source)
        self.assertLess(
            advance_source.index("mediaSelectionRequest("),
            advance_source.index("startLifecyclePresentation("),
        )

        begin_end = self.app.index("private func handlePresentationEvent", begin)
        begin_source = self.app[begin:begin_end]
        self.assertIn("destination: state", begin_source)
        self.assertIn("mediaSelectionRequest(", begin_source)
        self.assertIn("destinationSelectionRequest: destinationSelectionRequest", begin_source)
        self.assertNotIn("selectedEntry(", begin_source)
        self.assertIn("attestRuntimeTransition", begin_source)
        request_helper = begin_source.index("private func mediaSelectionRequest(")
        helper_source = begin_source[request_helper:]
        self.assertIn("return cursor.request(", helper_source)
        self.assertIn("request.commit(to: &mediaSelectionCursor)", helper_source)
        self.assertIn("request.commit(to: &manualPreviewSelectionCursor)", helper_source)

        cancel = self.app.index("private func cancelActiveLifecycleTransition")
        cancel_end = self.app.index("private func startLifecyclePresentation", cancel)
        cancel_source = self.app[cancel:cancel_end]
        self.assertIn("pendingLifecycleTransitionAttestation = nil", cancel_source)
        self.assertNotIn("destinationSelectionRequest.commit", cancel_source)

        finish = self.app.index("private func finishLifecycleTransition")
        finish_end = self.app.index("private static func attestRuntimeTransition", finish)
        finish_source = self.app[finish:finish_end]
        self.assertIn("if active.isInState", finish_source)
        self.assertIn('refreshReason: "in_state_handoff_failed"', finish_source)
        self.assertIn("preselectedEntry: active.destinationEntry", finish_source)
        self.assertIn("advanceSelection: false", finish_source)
        self.assertIn("selectionRequest: active.destinationSelectionRequest", finish_source)
        self.assertIn("selectionRequest.commit(to: &mediaSelectionCursor)", finish_source)

        presentation = self.app.index("private func startLifecyclePresentation(")
        presentation_end = self.app.index("private func advancePlaylistAfterClipEnd", presentation)
        presentation_source = self.app[presentation:presentation_end]
        self.assertIn("pendingMediaSelectionCommit", presentation_source)
        self.assertIn("commitMediaSelectionRequest(", presentation_source)

        active = self.app.index("private struct ActiveLifecycleTransition")
        active_end = self.app.index("enum LifecycleTransitionCompletionDecision", active)
        active_source = self.app[active:active_end]
        self.assertIn("let destinationEntry: MediaEntry", active_source)
        self.assertIn("var transitionSelectionRequest: TransitionSelectionRequest?", active_source)
        self.assertIn("var destinationSelectionRequest: MediaSelectionRequest?", active_source)

        transition = self.app.index("private func beginLifecycleTransition(")
        transition_end = self.app.index("private func finishLifecycleTransitionAttestation", transition)
        transition_source = self.app[transition:transition_end]
        self.assertIn("transitionSelectionCursor(", transition_source)
        self.assertIn("for: resolvedTransition.scope", transition_source)
        self.assertIn("selectionRequest = try? selectionCursor.request", transition_source)
        self.assertIn("selectionCursor.requestGlobal(", transition_source)
        self.assertIn("selectionRequest.next()", transition_source)
        self.assertIn("destinationEntry: destinationEntry", transition_source)
        self.assertLess(
            transition_source.index("selectionRequest.next()"),
            transition_source.index("selectedEntry("),
        )
        self.assertIn("Task.detached(priority: .userInitiated)", transition_source)
        self.assertIn("finishLifecycleTransitionAttestation", transition_source)
        self.assertIn("pendingLifecycleTransitionAttestationTask = verifier", transition_source)
        self.assertLess(
            transition_source.index("Task.detached(priority: .userInitiated)"),
            transition_source.index("Self.attestRuntimeTransition"),
        )
        timeout_helper = self.app.index("private static func attestRuntimeTransition(")
        timeout_helper_end = self.app.index("private func cancelActiveLifecycleTransition", timeout_helper)
        timeout_source = self.app[timeout_helper:timeout_helper_end]
        self.assertIn("PortableMediaOperationRunner.run(", timeout_source)
        self.assertIn("timeoutSeconds: timeoutSeconds", timeout_source)
        self.assertIn("CharacterLibraryStorage.attestRuntimeTransition", timeout_source)
        attestation_finish = self.app.index("private func finishLifecycleTransitionAttestation")
        attestation_finish_end = self.app.index("private func finishLifecycleTransition(", attestation_finish)
        self.assertIn(
            "transitionAttestation: attestation",
            self.app[attestation_finish:attestation_finish_end],
        )

        self.assertIn("let entry = preselectedEntry ?? selectedEntry(", presentation_source)

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
        self.assertIn("transitionSelectionCursorsByCharacterAndScope", self.app)
        self.assertIn(
            '"\\(characterLibrary.activeCharacterID):\\(scope.rawValue)"',
            self.app,
        )
        activate = self.app.index("private func activateCharacter(")
        activate_end = self.app.index("private func refreshCharacterClipCounts", activate)
        self.assertNotIn(
            "transitionSelectionCursor = TransitionSelectionCursor()",
            self.app[activate:activate_end],
        )

    def test_lifecycle_route_availability_uses_character_first_global_fallback_resolver(self):
        start = self.app.index("private func apply(state:")
        end = self.app.index("private func beginLifecycleTransition(", start)
        source = self.app[start:end]
        resolver = source.index("TransitionLibraryResolver.resolve(")
        policy = source.index("LifecycleTransitionPolicy.source(", resolver)
        self.assertIn("character: mediaMap", source[resolver:policy])
        self.assertIn("global: globalTransitionLibrary", source[resolver:policy])
        self.assertIn("hasConfiguredMedia: configuredTransition != nil", source[policy:])

    def test_lifecycle_playback_uses_resolved_character_or_global_route(self):
        start = self.app.index("private func beginLifecycleTransition(")
        end = self.app.index("private func finishLifecycleTransitionAttestation", start)
        source = self.app[start:end]
        resolver = source.index("TransitionLibraryResolver.resolve(")
        playlist = source.index("let transitionPlaylist = resolvedTransition.playlist", resolver)
        self.assertIn("character: mediaMap", source[resolver:playlist])
        self.assertIn("global: globalTransitionLibrary", source[resolver:playlist])
        self.assertIn("playlist: transitionPlaylist", source[playlist:])

    def test_transition_file_resolution_uses_the_resolved_library_root(self):
        start = self.app.index("private func beginLifecycleTransition(")
        end = self.app.index("private func finishLifecycleTransitionAttestation", start)
        source = self.app[start:end]
        root = source.index("let transitionLibraryURL = resolvedTransition.scope == .character")
        request = source.index("let request = PendingLifecycleTransitionAttestation(", root)
        root_source = source[root:request]
        self.assertIn("? mediaMapURL", root_source)
        self.assertIn(": characterLibraryStorage.globalTransitionLibraryURL", root_source)
        self.assertGreaterEqual(root_source.count("relativeTo: transitionLibraryURL"), 2)
        self.assertIn("transitionScope: resolvedTransition.scope", source[request:])

    def test_transition_retry_preserves_scope_and_reuses_its_library_root(self):
        start = self.app.index("private func retryLifecycleTransition(")
        end = self.app.index("private func finishLifecycleTransition(", start)
        source = self.app[start:end]
        root = source.index("let transitionLibraryURL = request.transitionScope == .character")
        retry = source.index("let retry = PendingLifecycleTransitionAttestation(", root)
        self.assertIn("? mediaMapURL!", source[root:retry])
        self.assertIn(": characterLibraryStorage.globalTransitionLibraryURL", source[root:retry])
        self.assertIn("relativeTo: transitionLibraryURL", source[root:retry])
        self.assertIn("transitionScope: request.transitionScope", source[retry:])

    def test_global_transition_watcher_triggers_reload(self):
        start = self.app.index("private func installWatchers()")
        end = self.app.index("private func installMapWatcher()", start)
        source = self.app[start:end]
        self.assertIn("fileURL: characterLibraryStorage.globalTransitionLibraryURL", source)
        self.assertIn("handleGlobalTransitionLibraryReloadRequest()", source)

    def test_startup_closes_global_library_race_before_first_state_read(self):
        start = self.app.index("if let forcedState = options.forcedState")
        end = self.app.index("installHealthCheckTimer()", start)
        source = self.app[start:end]
        watchers = source.index("installWatchers()")
        global_reload = source.index("handleGlobalTransitionLibraryReloadRequest()", watchers)
        state_read = source.index("readState(from: options.stateURL)", global_reload)
        self.assertLess(watchers, global_reload)
        self.assertLess(global_reload, state_read)

    def test_health_check_reloads_global_transition_library(self):
        start = self.app.index("private func installHealthCheckTimer()")
        end = self.app.index("private func handleMediaMapReloadRequest()", start)
        source = self.app[start:end]
        character_reload = source.index("self.handleCharacterLibraryReloadRequest()")
        global_reload = source.index("self.handleGlobalTransitionLibraryReloadRequest()")
        state_read = source.index("self.readState(", global_reload)
        self.assertLess(character_reload, global_reload)
        self.assertLess(global_reload, state_read)

    def test_global_transition_reload_refreshes_playback_only_when_changed(self):
        start = self.app.index("private func handleGlobalTransitionLibraryReloadRequest()")
        end = self.app.index("private func applyDeferredGlobalTransitionLibraryReloadIfNeeded", start)
        source = self.app[start:end]
        self.assertIn("let previous = globalTransitionLibrary", source)
        self.assertIn("guard loadGlobalTransitionLibrary() else { return }", source)
        changed = source.index("if previous != globalTransitionLibrary")
        self.assertIn("apply(state: currentState, forceRefresh: true)", source[changed:])

    def test_transition_selection_history_is_isolated_by_library_scope(self):
        storage_start = self.app.index("private var transitionSelectionCursorsByCharacterAndScope")
        storage_end = self.app.index("private var pendingRecoveryNotice", storage_start)
        storage = self.app[storage_start:storage_end]
        self.assertIn("TransitionLibraryScope", storage)
        self.assertIn("private func transitionSelectionCursor(", storage)
        self.assertIn("for scope: TransitionLibraryScope", storage)
        self.assertIn("setTransitionSelectionCursor(", storage)

        begin = self.app.index("private func beginLifecycleTransition(")
        begin_end = self.app.index("private func finishLifecycleTransitionAttestation", begin)
        begin_source = self.app[begin:begin_end]
        self.assertIn("transitionSelectionCursor(", begin_source)
        self.assertIn("for: resolvedTransition.scope", begin_source)

        finish = self.app.index("private func finishLifecycleTransition(")
        finish_end = self.app.index("private static func attestRuntimeTransition", finish)
        finish_source = self.app[finish:finish_end]
        self.assertIn("active.transitionSelectionRequest", finish_source)
        self.assertIn("selectionRequest.commit(to: &cursor)", finish_source)
        self.assertIn("setTransitionSelectionCursor(", finish_source)
        self.assertIn("for: active.transitionScope", finish_source)

    def test_app_replacement_paths_keep_visible_content_until_authoritative_commit(self):
        self.assertIn("let hasVisiblePresentation = currentURL != nil || view.hasVisiblePoster", self.player)
        self.assertIn("if !hasVisiblePresentation", self.player)
        self.assertNotIn("clearTransientPresentation()", self.app)
        self.assertNotIn("clearOneShotPresentation()", self.app)
        self.assertIn("pendingLifecycleTransitionAttestationTask?.cancel()", self.app)
        self.assertIn("pendingLifecycleTransitionAttestationTask = nil", self.app)
        self.assertIn("cancelActiveOneShotWithoutRestore", self.app)
        self.assertIn("startLifecyclePresentation(", self.app)

    def test_readiness_timeout_pauses_and_overlap_uses_media_time(self):
        show = self.player.index("func showLifecycleTransition")
        end = self.player.index("func setReduceMotion", show)
        source = self.player[show:end]
        self.assertIn("cancelDirectReplacement()", source)
        self.assertIn("scheduleLifecycleReadinessTimeout", source)
        self.assertIn("addBoundaryTimeObserver", self.player)
        self.assertIn("lifecycleReadinessTimeoutWorkItem?.cancel()", self.player)
        self.assertIn("lifecyclePlaybackStallTimeoutWorkItem?.cancel()", self.player)
        self.assertIn("handleLifecyclePlaybackStallTimeout", self.player)
        self.assertIn("let reasonsBefore = suspensionPolicy.reasons", self.player)
        self.assertIn("guard suspensionPolicy.reasons != reasonsBefore else", self.player)
        self.assertNotIn("LifecycleTransitionDeadline", self.player)
        self.assertNotIn("scheduleLifecycleTransitionTimeout", self.player)

    def test_layered_handoff_keeps_explicit_lower_and_foreground_layers(self):
        self.assertIn("destinationPlayerLayer", self.player)
        self.assertIn("lifecycleTransitionPlayerLayer", self.player)
        prepare = self.player.index("func prepareLifecycleHandoff")
        promote = self.player.index("func promoteLifecycleDestination", prepare)
        source = self.player[prepare:promote]
        self.assertIn("destinationPlayerLayer.player = destinationPlayer", source)
        self.assertIn("lifecycleTransitionPlayerLayer.player = transitionPlayer", source)
        self.assertIn("playerLayer.isHidden = false", source)
        self.assertIn("view.revealLifecycleTransition()", self.player)
        self.assertIn("view.revealLifecycleDestination()", self.player)
        self.assertIn("LayeredLifecycleHandoffPolicy.destinationPrerollTime", self.player)
        self.assertIn("CharacterLibraryStorage.attestRuntimeTransition", self.app)
        self.assertIn("transitionAttestation.requireUnchanged", self.player)

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
        self.assertIn('case transitionScope = "transition_scope"', self.app)
        self.assertIn(
            'case globalTransitionLibrarySHA256 = "global_transition_library_sha256"',
            self.app,
        )
        self.assertIn("let owner = try? recoveryOwner(for: journal)", self.app)
        self.assertIn("saveRecoveredMediaMap(", self.app)
        self.assertIn("expectedData: characterOwner.encodedData", self.app)
        self.assertIn("expectedCatalogData: characterOwner.catalogEncodedData", self.app)
        self.assertIn('throw PetContractError.invalidValue("legacy recovery owner is ambiguous")', self.app)
        self.assertIn("catalogSnapshot.encodedData == characterLibraryEncodedData", self.app)
        self.assertIn("Self.isValidRecoveryRoute(journal)", self.app)
        self.assertIn("Self.recoveryArtifactStem(journal, state: state)", self.app)
        recovery = self.app.index("private func recoverInterruptedConversionIfPresent")
        recovery_end = self.app.index("private static func isValidInvocationChallenge", recovery)
        recovery_source = self.app[recovery:recovery_end]
        self.assertIn("LifecycleTransitionMediaPolicy.maximumDuration", recovery_source)
        self.assertIn("appendingTransitionEntry", recovery_source)
        self.assertIn(".entry(path: journal.outputBasename) == nil", recovery_source)
        self.assertNotIn("removeItem(at: journalURL)", recovery_source)
        self.assertIn("journal and artifacts were retained for retry", recovery_source)
        self.assertNotIn("quarantineFailedRecoveryArtifacts", recovery_source)
        self.assertIn("requireValidatedFilesUnchanged", recovery_source)

    def test_global_transition_conversion_journal_carries_scope_and_expected_digest(self):
        start = self.app.index("private func importTransitionMP4")
        end = self.app.index("private func previewTransition", start)
        source = self.app[start:end]
        journal = source.index("ActiveConversionJournal(")
        conversion = source.index("conversionCoordinator.convert(", journal)
        journal_source = source[journal:conversion]
        self.assertIn("transitionScope: scope", journal_source)
        self.assertIn("globalTransitionLibrarySHA256:", journal_source)
        self.assertNotIn("if scope == .character", source[:conversion])

    def test_conflicting_global_legacy_data_has_an_explicit_migration_action(self):
        self.assertIn("onMigrateGlobalTransitionLegacy", self.app)
        self.assertIn("migrateGlobalTransitionLegacy()", self.app)
        self.assertIn("migratingLegacyToUniversal(using: route)", self.app)
        self.assertIn("All legacy route-specific playlists and their media remain", self.app)

    def test_recovery_publishes_transition_to_recorded_scope_with_digest_barrier(self):
        start = self.app.index("private func recoverInterruptedConversionIfPresent")
        end = self.app.index("private func recoveryOwner(for journal:", start)
        source = self.app[start:end]
        self.assertIn("case let .global(globalOwner)", source)
        self.assertIn("globalOwner.encodedData", source)
        self.assertIn("saveRecoveredGlobalTransitionLibrary", source)
        self.assertIn("saveRecoveredMediaMap", source)
        self.assertIn("applyPublishedGlobalTransitionLibrary", source)

    def test_recovery_rejects_incomplete_or_changed_global_scope_ownership(self):
        start = self.app.index("private func recoveryOwner(for journal:")
        end = self.app.index("private static func isValidInvocationChallenge", start)
        source = self.app[start:end]
        self.assertIn("journal.transitionScope", source)
        self.assertIn("globalTransitionLibrarySHA256", source)
        self.assertIn("loadGlobalTransitionLibrary", source)
        self.assertIn("sha256Hex", source)
        self.assertIn("conversion recovery", source)

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
        active_branch = recovery_source.index("if characterOwner.isActive", save)
        self.assertLess(save, active_branch)
        self.assertIn("for: characterOwner.entry", recovery_source[save:active_branch])
        self.assertIn("self.mediaMapEncodedData = encoded", recovery_source[active_branch:])
        self.assertIn("self.applyPublishedMediaMap(updated)", recovery_source[active_branch:])
        self.assertIn("self.characterClipCounts[characterOwner.entry.id]", recovery_source[active_branch:])

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
        self.assertIn("map.allMediaEntries", self.app[helper_start:helper_end])

        for name, end_marker in (
            ("private func isMediaPathReferenced(_ url:", "private func isMediaPathReferencedByInactiveCharacter"),
            ("private func isMediaPathReferencedByInactiveCharacter(_ url:", "private func mediaMap(_ map:"),
            ("private func mediaMap(_ map:", "private func allCharacterMediaMaps"),
            ("private func unusedMediaCandidates()", "private func isInsideManagedMedia"),
        ):
            start = self.app.index(name)
            end = self.app.index(end_marker, start)
            self.assertIn("allMediaEntries(in:", self.app[start:end], name)

    def test_global_transition_references_are_checked_before_character_cleanup_references(self):
        start = self.app.index("private func isMediaPathReferenced(_ url:")
        end = self.app.index("private func isMediaPathReferencedByInactiveCharacter", start)
        source = self.app[start:end]
        global_check = source.index("globalTransitionLibraryReferences(url)")
        character_check = source.index("allCharacterMediaMaps()", global_check)
        self.assertLess(global_check, character_check)

    def test_unused_media_cleanup_includes_global_transition_references(self):
        start = self.app.index("private func unusedMediaCandidates()")
        end = self.app.index("private func isInsideManagedMedia", start)
        source = self.app[start:end]
        self.assertIn("characterLibraryStorage.globalTransitionLibraryURL", source)
        self.assertIn("globalTransitionLibrary.allEntries", source)

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
        self.assertIn(
            "self.characterRouteContains(route, path: path)",
            source[callback:mutation],
        )
        self.assertLess(mutation, publish)

    def test_observed_publication_is_separate_from_accepted_rollback_barrier(self):
        start = self.app.index("private func applyLifecycleState(_ state:")
        end = self.app.index("private func recordPublicationRejection", start)
        source = self.app[start:end]
        observed = source.index("lastPublishedSnapshot = state")
        ordering = source.index("StatePublicationOrderPolicy.decide(")
        accepted = source.index("lastAcceptedPublishedSnapshot = state")
        self.assertLess(observed, ordering)
        self.assertLess(ordering, accepted)
        self.assertIn("lastAccepted: lastAcceptedPublishedSnapshot", source)
        self.assertIn("guard ordering.shouldAccept else", source)
        self.assertIn('recordPublicationRejection(ordering.rejectionReason ?? "order_rejected")', source)

    def test_transient_missing_or_corrupt_reads_preserve_accepted_revision_barrier(self):
        start = self.app.index("private func applyLifecycleStateReadResult(")
        end = self.app.index("private func applyLifecycleState(_ state:", start)
        source = self.app[start:end]
        self.assertIn("retryLifecycleStateReadOrReject(.missing", source)
        self.assertIn("retryLifecycleStateReadOrReject(.corrupt", source)
        self.assertIn("guard retryAttempt < 2 else", source)
        self.assertNotIn("lastAcceptedPublishedSnapshot = nil", source)

    def test_same_state_newer_publication_updates_metadata_without_forced_playback(self):
        start = self.app.index("private func applyLifecycleState(_ state:")
        end = self.app.index("private func recordPublicationRejection", start)
        source = self.app[start:end]
        accepted = source.index("lastAcceptedPublishedSnapshot = state")
        playback = source.index("apply(state: state.state)", accepted)
        self.assertLess(accepted, playback)
        self.assertNotIn("forceRefresh: true", source[accepted:playback + 32])
        self.assertIn("previousLifecycleState == incomingState", self.app)
        self.assertIn("? .sameStateHeartbeat", self.app)

    def test_duplicate_publication_recovers_only_while_snapshot_is_fresh(self):
        start = self.app.index("private func applyLifecycleState(_ state:")
        end = self.app.index("private func recordPublicationRejection", start)
        source = self.app[start:end]
        freshness = source.index("let freshness = freshnessPolicy.freshness(")
        duplicate = source.index("ordering == .rejectEqualRevisionDuplicate", freshness)
        fresh_gate = source.index("freshness == .fresh", duplicate)
        reject = source.index("rejectPublisher(freshness == .futureSkew ? .futureSkew : .stale)")
        self.assertLess(freshness, duplicate)
        self.assertLess(duplicate, fresh_gate)
        self.assertLess(fresh_gate, reject)

    def test_return_to_live_presents_current_accepted_real_state(self):
        start = self.app.index("private func stopTemporaryStatePreview(")
        end = self.app.index("private func relinquishTemporaryStatePreview", start)
        source = self.app[start:end]
        self.assertIn("temporaryStatePreviewPolicy.cancel()", source)
        self.assertIn("state: currentState", source)
        self.assertIn('refreshReason: "follow_codex"', source)
        self.assertIn("advanceSelection: false", source)

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
        publish = source.index("try updateTransitionLibrary(", installed)
        nested_catch = source.index("} catch {", publish)
        self.assertLess(publish, nested_catch)
        self.assertLess(nested_catch, cleanup)

    def test_transition_mp4_conversion_has_distinct_token_gated_cancellation(self):
        start = self.app.index("private func importTransitionMP4")
        end = self.app.index("private func previewTransition", start)
        source = self.app[start:end]
        mutation_guard = source.index("guard !mediaMutationInProgress")
        toolchain_guard = source.index("guard case let .ready(toolchain)")
        conversion_token = source.index("let conversionID = UUID()")
        journal = source.index("writeConversionJournal")
        self.assertLess(mutation_guard, toolchain_guard)
        self.assertLess(mutation_guard, conversion_token)
        self.assertLess(mutation_guard, journal)
        self.assertIn("wait for the current media operation to finish", source[:toolchain_guard])
        self.assertIn("let conversionID = UUID()", source)
        self.assertIn("activeTransitionConversionID = conversionID", source)
        self.assertGreaterEqual(
            source.count("activeTransitionConversionID == conversionID"),
            3,
        )
        self.assertGreaterEqual(
            source.count("!self.transitionConversionCancellationRequested"),
            2,
        )
        stale = source.index("guard self.activeTransitionConversionID == conversionID else")
        stale_source = source[
            stale:source.index("if self.transitionConversionCancellationRequested", stale)
        ]
        self.assertIn("removeItem(at: outputURL)", stale_source)
        self.assertIn("removeItem(at: reportURL)", stale_source)
        self.assertNotIn("clearConversionJournal", stale_source)

        cancel = self.app.index("private func cancelMP4ImportBatch")
        retry = self.app.index("private func retryLastFailedMP4Batch", cancel)
        cancel_source = self.app[cancel:retry]
        transition = cancel_source.index("activeTransitionConversionID")
        batch = cancel_source.index("activeMP4BatchID")
        self.assertLess(transition, batch)
        self.assertIn("cancelTransitionConversion(conversionID)", cancel_source)
        self.assertIn("transitionConversionCancellationRequested = true", cancel_source)
        self.assertIn("conversionCoordinator.cancel()", cancel_source)
        self.assertIn('.working(destination, "Cancelling transition conversion…")', cancel_source)
        self.assertNotIn("activeTransitionConversionID = nil", cancel_source)
        self.assertNotIn("clearConversionJournal()", cancel_source)
        self.assertNotIn("mediaMutationInProgress = false", cancel_source)

        cancellation_completion = source.index("if self.transitionConversionCancellationRequested")
        cancellation_source = source[
            cancellation_completion:source.index("do {", cancellation_completion)
        ]
        self.assertIn("removeCancelledTransitionArtifact(outputURL)", cancellation_source)
        self.assertIn("removeCancelledTransitionArtifact(reportURL)", cancellation_source)
        cleanup_guard = cancellation_source.index("guard outputAbsent, reportAbsent")
        clear_journal_call = cancellation_source.index(
            "removeCancelledTransitionArtifact(self.conversionJournalURL)"
        )
        clear_journal = cancellation_source.rindex("guard self.removeCancelledTransitionArtifact")
        self.assertLess(cleanup_guard, clear_journal)
        blocked_source = cancellation_source[cleanup_guard:clear_journal]
        self.assertIn("cleanup could not be verified", blocked_source)
        self.assertIn("Restart Statelet to recover safely.", blocked_source)
        self.assertNotIn("mediaMutationInProgress = false", blocked_source)
        journal_guard_source = cancellation_source[
            clear_journal:cancellation_source.index("self.activeTransitionConversionID = nil", clear_journal)
        ]
        self.assertIn("self.removeCancelledTransitionArtifact", journal_guard_source)
        self.assertIn("recovery record could not be cleared", journal_guard_source)
        self.assertNotIn("mediaMutationInProgress = false", journal_guard_source)
        self.assertIn("activeTransitionConversionID = nil", cancellation_source)
        self.assertIn("transitionConversionCancellationRequested = false", cancellation_source)
        self.assertIn("mediaMutationInProgress = false", cancellation_source)

        helper = self.app.index("private func removeCancelledTransitionArtifact")
        retry = self.app.index("private func retryLastFailedMP4Batch", helper)
        helper_source = self.app[helper:retry]
        self.assertIn("standardizedArtifact.deletingLastPathComponent() == mediaRoot", helper_source)
        self.assertIn("O_NOFOLLOW", helper_source)
        self.assertIn("O_CLOEXEC", helper_source)
        self.assertIn("AT_SYMLINK_NOFOLLOW", helper_source)
        self.assertIn("Darwin.fstatat", helper_source)
        self.assertIn("Darwin.unlinkat", helper_source)
        self.assertIn("Darwin.fsync(rootDescriptor)", helper_source)
        self.assertGreaterEqual(helper_source.count("errno == ENOENT"), 2)

    def test_transition_mp4_batch_continues_after_individual_failure(self):
        start = self.app.index("private func importTransitionMP4s(")
        end = self.app.index("private func importTransitionMP4(", start)
        source = self.app[start:end]
        self.assertIn("Array(orderedURLs.dropFirst())", source)
        self.assertIn("guard replacingPath == nil else { return }", source)
        self.assertNotIn("guard succeeded", source)


if __name__ == "__main__":
    unittest.main()
