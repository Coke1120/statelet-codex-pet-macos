#!/usr/bin/env python3
"""App integration contracts for Statelet character profiles and bundles."""

from __future__ import annotations

import plistlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MAC_ROOT = ROOT / "mac" / "CodexPetMac"
MAC_SOURCES = MAC_ROOT / "Sources"
CORE_SOURCES = sorted((MAC_SOURCES / "CodexPetCore").glob("*.swift"))
APP_DELEGATE = MAC_SOURCES / "CodexPetMac" / "PetAppDelegate.swift"
SETTINGS = MAC_SOURCES / "CodexPetMac" / "SettingsWindowController.swift"
SELECTOR = MAC_SOURCES / "CodexPetMac" / "CharacterProfileSelectorView.swift"
STORAGE = MAC_SOURCES / "CodexPetMac" / "CharacterLibraryStorage.swift"
ALPHA = MAC_SOURCES / "CodexPetMac" / "AlphaConversion.swift"
IDENTITY = MAC_SOURCES / "CodexPetMac" / "StateletIdentity.swift"
INFO_PLIST = MAC_ROOT / "Resources" / "Info.plist"


def swift_function(source: str, signature: str) -> str:
    """Return one Swift function/property body using balanced braces."""
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 0
    for offset in range(opening, len(source)):
        if source[offset] == "{":
            depth += 1
        elif source[offset] == "}":
            depth -= 1
            if depth == 0:
                return source[start : offset + 1]
    raise AssertionError(f"unterminated Swift declaration: {signature}")


class CharacterProfileAppSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.delegate = APP_DELEGATE.read_text(encoding="utf-8")
        cls.settings = SETTINGS.read_text(encoding="utf-8")
        cls.selector = SELECTOR.read_text(encoding="utf-8")
        cls.storage = STORAGE.read_text(encoding="utf-8")
        cls.alpha = ALPHA.read_text(encoding="utf-8")

    def test_settings_forwards_every_character_command(self) -> None:
        for callback in (
            "onCharacterSelection",
            "onCreateCharacter",
            "onRenameCharacter",
            "onDuplicateCharacter",
            "onDeleteCharacter",
            "onImportCharacterBundle",
            "onExportCharacterBundle",
        ):
            self.assertIn(callback, self.settings)
            self.assertIn(f"controller.{callback}", self.delegate)
        self.assertIn("characterSelector.update(", self.settings)
        self.assertIn("characterProfiles: characterLibrary.characters.map", self.delegate)
        self.assertIn("activeCharacterID: characterLibrary.activeCharacterID", self.delegate)

    def test_status_menu_lists_profiles_and_persists_selection(self) -> None:
        character_menu = swift_function(self.delegate, "private func makeCharacterMenu()")
        self.assertIn("for character in characterLibrary.characters", character_menu)
        self.assertIn("representedObject = character.id", character_menu)
        self.assertIn("character.id == characterLibrary.activeCharacterID", character_menu)
        self.assertIn("Manage Characters…", character_menu)

        selection = swift_function(self.delegate, "private func selectCharacter(id: String)")
        self.assertLess(selection.index("loadMediaMap(for: entry)"), selection.index("persistCharacterLibrary(updated)"))
        self.assertLess(selection.index("persistCharacterLibrary(updated)"), selection.index("activateCharacter("))
        self.assertIn("The previous character remains active.", selection)

    def test_activation_applies_the_selected_profiles_complete_window_configuration(self) -> None:
        activation = swift_function(self.delegate, "private func activateCharacter(")
        self.assertLess(activation.index("mediaMap = map"), activation.index("applyConfiguredWindowSize()"))
        self.assertLess(activation.index("installMapWatcher()"), activation.index("_ = loadMediaMap()"))
        self.assertIn("apply(state: currentState, forceRefresh: true)", activation)

        window_apply = swift_function(self.delegate, "private func applyConfiguredWindowSize()")
        for contract in (
            "mediaMap.window.width",
            "mediaMap.window.height",
            "clickThrough = options.clickThroughOverride ?? mediaMap.window.clickThrough",
            "panel.ignoresMouseEvents = clickThrough",
            "alwaysOnTop: options.alwaysOnTopOverride ?? mediaMap.window.alwaysOnTop",
            "fullScreenAuxiliary: mediaMap.window.fullScreenAuxiliary",
            "player?.applyAppearance(mediaMap.window.appearance)",
        ):
            self.assertIn(contract, window_apply)

    def test_cleanup_fails_closed_for_inactive_profile_references(self) -> None:
        all_maps = swift_function(self.delegate, "private func allCharacterMediaMaps()")
        self.assertIn("characterLibrary.characters.map", all_maps)
        removal = swift_function(self.delegate, "private func removeMedia(")
        self.assertIn("let libraryMaps = try allCharacterMediaMaps()", removal)
        self.assertIn("character.id != characterLibrary.activeCharacterID", removal)
        self.assertIn("ManagedMediaTrashRevalidator.captureLibrary(", removal)
        self.assertIn("catalogURL: characterLibraryStorage.catalogURL", removal)
        self.assertIn("ManagedMediaTrashRevalidator.validateLibraryUnchanged(", removal)
        self.assertIn("ManagedMediaTrashRevalidator.quarantineLibraryAfterPublish(", removal)
        self.assertIn("ManagedMediaTrashRevalidator.validateLibraryReadyForMapRestore(", removal)
        self.assertIn("at: quarantine.directoryURL", removal)
        self.assertNotIn("trashItem(at: target", removal)
        self.assertLess(
            removal.index("ManagedMediaTrashRevalidator.validateLibraryUnchanged("),
            removal.index("try publishMediaMap(plan.updatedMap)"),
        )
        self.assertLess(
            removal.index("ManagedMediaTrashRevalidator.validateLibraryReadyForMapRestore("),
            removal.index("try self.publishMediaMap(originalMap)"),
        )
        self.assertIn("characterLibraryStorage.loadMediaMap(for: entry)", all_maps)

    def test_crud_rolls_back_new_map_when_catalog_save_fails(self) -> None:
        for signature in (
            "private func createCharacter(name: String)",
            "private func duplicateCharacter(id: String, name: String)",
        ):
            body = swift_function(self.delegate, signature)
            self.assertLess(body.index("saveMediaMap("), body.index("persistCharacterLibrary(selected)"))
            self.assertIn("FileManager.default.removeItem(", body)
        deletion = swift_function(self.delegate, "private func deleteCharacter(id: String)")
        for guard in (
            "!mediaMutationInProgress",
            "characterLibrary.characters.count > 1",
            "characterLibrary.activeCharacterID == id",
            "characterLibrary.character(id: id) != nil",
        ):
            self.assertIn(guard, deletion)
        self.assertIn("characterLibrary.removingCharacter(id: id)", deletion)
        self.assertIn("action=retain_current", deletion)

    def test_profile_delete_routes_through_one_confirmation_and_revalidates(self) -> None:
        self.assertIn(
            "characterSelector.onDeleteActive = { [weak self] id in self?.confirmCharacterDeletion(id: id) }",
            self.settings,
        )
        confirmation = swift_function(
            self.settings,
            "private func confirmCharacterDeletion(id: String)",
        )
        for contract in (
            "CharacterProfileDeletionRequest(",
            "requestedProfileID: id",
            "alert.addButton(withTitle: \"Delete Character\")",
            "alert.addButton(withTitle: \"Cancel\")",
            "request.confirmedProfileID(",
            "response: response",
            "profiles: snapshot.characterProfiles",
            "activeProfileID: snapshot.activeCharacterID",
            "busy: self.activity.isBusy",
            "self.onDeleteCharacter?(confirmedID)",
        ):
            self.assertIn(contract, confirmation)
        self.assertEqual(confirmation.count("NSAlert()"), 1)

    def test_bundle_type_and_panels_use_the_registered_package_uti(self) -> None:
        with INFO_PLIST.open("rb") as handle:
            info = plistlib.load(handle)
        identifier = "com.coke1120.statelet.character-bundle"
        declaration = info["UTExportedTypeDeclarations"][0]
        self.assertEqual(declaration["UTTypeIdentifier"], identifier)
        self.assertIn("com.apple.package", declaration["UTTypeConformsTo"])
        self.assertIn(
            "statelet-character",
            declaration["UTTypeTagSpecification"]["public.filename-extension"],
        )
        document_type = info["CFBundleDocumentTypes"][0]
        self.assertIn(identifier, document_type["LSItemContentTypes"])
        self.assertTrue(document_type["LSTypeIsPackage"])
        self.assertIn(f'exportedAs: "{identifier}"', self.delegate)
        self.assertEqual(self.delegate.count("allowedContentTypes = [Self.characterBundleType]"), 2)

    def test_finder_open_routes_exactly_one_bundle_through_deferred_trust_confirmation(self) -> None:
        handler = swift_function(
            self.delegate,
            "func application(_ sender: NSApplication, openFiles filenames: [String])",
        )
        self.assertIn(
            '$0.pathExtension.caseInsensitiveCompare("statelet-character") == .orderedSame',
            handler,
        )
        self.assertIn("guard bundles.count == 1, pendingCharacterBundleOpenURL == nil", handler)
        self.assertIn("sender.reply(toOpenOrPrint: .failure)", handler)
        self.assertIn("pendingCharacterBundleOpenURL = bundles[0]", handler)
        self.assertIn("sender.reply(toOpenOrPrint: .success)", handler)
        self.assertIn("processPendingCharacterBundleOpenIfPossible()", handler)

        deferred = swift_function(
            self.delegate,
            "private func processPendingCharacterBundleOpenIfPossible()",
        )
        for readiness_guard in (
            "characterLibraryStorage != nil",
            "panel != nil",
            "!mediaMutationInProgress",
            "let url = pendingCharacterBundleOpenURL",
        ):
            self.assertIn(readiness_guard, deferred)
        self.assertLess(deferred.index("pendingCharacterBundleOpenURL = nil"), deferred.index("confirmCharacterBundleImport(url)"))
        self.assertIn("showSettings()", deferred)
        self.assertIn("confirmCharacterBundleImport(url)", deferred)
        mutation_observer = self.delegate[
            self.delegate.index("private var mediaMutationInProgress = false") :
            self.delegate.index("func applicationDidFinishLaunching", self.delegate.index("private var mediaMutationInProgress = false"))
        ]
        self.assertIn("processPendingCharacterBundleOpenIfPossible()", mutation_observer)

    def test_bundle_import_rolls_back_committed_files_on_catalog_failure(self) -> None:
        body = swift_function(
            self.delegate,
            "private func importCharacterBundle(_ url: URL, allowLegacyTrust: Bool)",
        )
        self.assertIn("let baselineLibrary = characterLibrary", body)
        self.assertIn("against: baselineLibrary", body)
        self.assertIn("let entry = try staged.commit()", body)
        self.assertIn("staged.rollback()", body)
        self.assertIn("staged.finalize()", body)
        self.assertIn("The library was not changed.", body)

    def test_bundle_file_work_is_owned_through_main_thread_finalization(self) -> None:
        for signature in (
            "private func importCharacterBundle(_ url: URL, allowLegacyTrust: Bool)",
            "private func exportCharacterBundle(id: String)",
        ):
            body = swift_function(self.delegate, signature)
            self.assertIn("mediaMutationActivities.begin()", body)
            self.assertIn("Task.detached(priority: .userInitiated)", body)
            self.assertIn("mediaMutationFinalizations.enqueue", body)
            self.assertIn("activity.setCancellation", body)
            self.assertIn("defer { activity.finish() }", body)

        termination = swift_function(
            self.delegate,
            "func applicationWillTerminate(_ notification: Notification)",
        )
        self.assertIn("mediaMutationActivities", termination)
        self.assertIn("cancelAndWaitForQuiescence", termination)
        self.assertIn("mainThreadWork: mediaMutationFinalizations.drain", termination)
        self.assertIn("&& mediaMutationQuiescent", termination)
        self.assertIn("&& !mediaMutationInProgress", termination)

    def test_every_async_media_mutation_call_site_is_termination_owned(self) -> None:
        for signature in (
            "private func importTransitionMovies(",
            "private func importTransitionMP4(",
            "private func convertNextMP4(",
            "private func recoverInterruptedConversionIfPresent()",
            "private func importVerifiedMovies(",
        ):
            body = swift_function(self.delegate, signature)
            self.assertIn("mediaMutationActivities.begin()", body, signature)
            self.assertIn("activity.setCancellation", body, signature)
            self.assertIn("defer { activity.finish() }", body, signature)

    def test_termination_enters_closed_state_before_draining_and_shuts_player_down_last(self) -> None:
        enter = swift_function(self.delegate, "private func enterTerminationState()")
        self.assertLess(enter.index("isTerminating = true"), enter.index("discardDeferredMediaWorkForTermination()"))
        discard = swift_function(
            self.delegate,
            "private func discardDeferredMediaWorkForTermination()",
        )
        for pending_work in (
            "mediaMapReloadDeferred = false",
            "characterLibraryReloadDeferred = false",
            "globalTransitionLibraryReloadDeferred = false",
            "pendingCharacterBundleOpenURL = nil",
        ):
            self.assertIn(pending_work, discard)

        termination = swift_function(
            self.delegate,
            "func applicationWillTerminate(_ notification: Notification)",
        )
        entered = termination.index("enterTerminationState()")
        conversion = termination.index("conversionCoordinator.terminateAndWait()")
        drain = termination.index("let mediaMutationDrainQuiescent")
        finalization_drain = termination.index("let mediaMutationFinalizationQuiescent")
        player = termination.index("player?.shutdownForTermination()")
        conversion_final_check = termination.index("let conversionFinallyQuiescent")
        final_check = termination.index("let mediaMutationFinallyQuiescent")
        updater_gate = termination.index("let updaterWorkQuiescent")
        commit = termination.index("commitScheduledUpdateAtTermination")
        self.assertLess(entered, conversion)
        self.assertLess(conversion, drain)
        self.assertLess(drain, finalization_drain)
        self.assertLess(finalization_drain, player)
        self.assertLess(player, conversion_final_check)
        self.assertLess(conversion_final_check, final_check)
        self.assertLess(player, final_check)
        self.assertLess(final_check, updater_gate)
        self.assertLess(updater_gate, commit)
        self.assertIn("mediaMutationDrainQuiescent", termination)
        self.assertIn("mediaMutationFinalizationQuiescent", termination)
        self.assertIn("mediaMutationFinallyQuiescent", termination)
        self.assertIn("mediaMutationActivities.isQuiescent", termination)
        self.assertIn("conversionCoordinator.isQuiescentForTermination", termination)
        self.assertIn("conversionDrainQuiescent && conversionFinallyQuiescent", termination)
        self.assertIn("&& mediaMutationQuiescent", termination)

    def test_conversion_shutdown_is_irreversible_and_recursive_callbacks_are_closed(self) -> None:
        coordinator = self.alpha[self.alpha.index("final class AlphaConversionCoordinator") :]
        convert = coordinator[
            coordinator.index("func convert(") : coordinator.index("private func deliverCompletion")
        ]
        shutdown = swift_function(coordinator, "func terminateAndWait(")
        final_snapshot = swift_function(coordinator, "var isQuiescentForTermination: Bool")
        self.assertIn("guard !terminationRequested", convert)
        self.assertLess(convert.index("guard !terminationRequested"), convert.index("guard activeProcess == nil"))
        self.assertIn("terminationRequested = true", shutdown)
        self.assertIn("return isQuiescentForTermination", shutdown)
        for locked_state in (
            "activeProcess == nil",
            "activeProcessGroupPID == nil",
            "pendingCompletionCount == 0",
        ):
            self.assertIn(locked_state, final_snapshot)
        self.assertIn("lock.lock()", final_snapshot)

        convert_next = swift_function(self.delegate, "private func convertNextMP4(")
        self.assertIn("guard !isTerminating", convert_next)
        self.assertGreaterEqual(convert_next.count("self.isTerminating"), 3)
        transition_batch = swift_function(self.delegate, "private func importTransitionMP4s(")
        transition_conversion = swift_function(self.delegate, "private func importTransitionMP4(")
        self.assertIn("guard !isTerminating", transition_batch)
        self.assertIn("abandonTransitionConversionForTermination", transition_conversion)
        self.assertGreaterEqual(transition_conversion.count("self.isTerminating"), 4)

    def test_system_and_settings_callbacks_cannot_restart_work_during_termination_pumps(self) -> None:
        for signature in (
            "func windowDidChangeOcclusionState(_ notification: Notification)",
            "@objc private func accessibilityDisplayOptionsChanged()",
            "@objc private func screensDidWake()",
            "private func updateWindowOcclusionSuspension()",
            "func applicationShouldHandleReopen(",
            "@objc private func showSettings()",
            "private func checkConversionTools()",
            "private func choosePythonRuntime()",
        ):
            self.assertIn("isTerminating", swift_function(self.delegate, signature), signature)

        launch = swift_function(
            self.delegate,
            "func applicationDidFinishLaunching(_ notification: Notification)",
        )
        open_settings = launch[launch.index("if options.openSettings") :]
        self.assertLess(open_settings.index("!self.isTerminating"), open_settings.index("self.showSettings()"))
        enter = swift_function(self.delegate, "private func enterTerminationState()")
        self.assertIn("toolchainDiscoveryCancellation?.cancel()", enter)
        termination = swift_function(
            self.delegate,
            "func applicationWillTerminate(_ notification: Notification)",
        )
        self.assertIn("toolchainDiscoveryQuiescent", termination)
        self.assertIn("cancelAndWaitForQuiescence(timeout: 2)", termination)
        self.assertIn("&& toolchainDiscoveryQuiescent", termination)

        toolchain_cancellation = swift_function(
            self.alpha,
            "final class AlphaToolchainDiscoveryCancellation",
        )
        self.assertIn("guard !cancelled", toolchain_cancellation)
        self.assertIn("func cancelAndWaitForQuiescence", toolchain_cancellation)
        self.assertIn("activeDiscoveryCount", toolchain_cancellation)

    def test_queued_character_bundle_confirmation_rechecks_termination(self) -> None:
        confirmation = swift_function(
            self.delegate,
            "private func confirmCharacterBundleImport(_ url: URL)",
        )
        self.assertIn("guard !isTerminating", confirmation)
        deferred = swift_function(
            self.delegate,
            "private func processPendingCharacterBundleOpenIfPossible()",
        )
        queued_confirmation = deferred[deferred.index("DispatchQueue.main.async") :]
        self.assertLess(
            queued_confirmation.index("!self.isTerminating"),
            queued_confirmation.index("self.confirmCharacterBundleImport(url)"),
        )

    def test_termination_gate_blocks_deferred_reload_open_mutation_and_playback_reentry(self) -> None:
        mutation_observer = swift_function(
            self.delegate,
            "private var mediaMutationInProgress = false",
        )
        self.assertIn("guard !isTerminating", mutation_observer)
        self.assertLess(
            mutation_observer.index("discardDeferredMediaWorkForTermination()"),
            mutation_observer.index("applyDeferredMediaMapReloadIfNeeded()"),
        )

        for signature in (
            "private func handleMediaMapReloadRequest()",
            "private func handleCharacterLibraryReloadRequest()",
            "private func handleGlobalTransitionLibraryReloadRequest()",
            "private func processPendingCharacterBundleOpenIfPossible()",
            "private func apply(state: PetState, forceRefresh: Bool = false)",
            "private func beginLifecycleTransition(",
            "private func finishLifecycleTransitionAttestation(",
            "private func startLifecyclePresentation(",
            "private func beginInStateTransitionPrewarm(",
            "private func finishInStateTransitionPrewarm(",
            "private func handlePresentationEvent(",
            "private func presentStateOwnedDialogueIfNeeded(for state: PetState)",
            "private func refreshStateOwnedDialogue(using snapshot: DialogueVoiceCoordinatorSnapshot)",
            "private func ensureStateOwnedDialoguePlayback()",
            "private func previewTransition(",
            "private func playOnce(state libraryState: PetState, path: String)",
            "private func chooseVoiceAsset(",
            "private func persistVoiceProfile(_ draft: DialogueVoiceProfileDraft)",
            "private func chooseQwenPythonRuntime(for packageURL: URL)",
            "private func chooseVoxCPM2Python(",
            "private func selectVoiceProvider(_ provider: DialogueVoiceProviderKind)",
            "private func previewDialogueLine(_ line: DialogueLine)",
            "private func retryDialogueLine(_ line: DialogueLine)",
            "private func regenerateDialogueLine(_ line: DialogueLine)",
            "private func importCharacterBundle(_ url: URL, allowLegacyTrust: Bool)",
            "private func exportCharacterBundle(id: String)",
            "private func importTransitionMovies(",
            "private func importTransitionMP4(",
            "private func startConversionBatch(",
            "private func recoverInterruptedConversionIfPresent()",
            "private func importVerifiedMovies(",
            "private func choosePoster(for state: PetState, path: String)",
            "private func removeMedia(",
            "private func cleanUnusedMedia()",
        ):
            self.assertIn("isTerminating", swift_function(self.delegate, signature), signature)

        finder_open = swift_function(
            self.delegate,
            "func application(_ sender: NSApplication, openFiles filenames: [String])",
        )
        self.assertIn("guard !isTerminating", finder_open)
        self.assertIn("sender.reply(toOpenOrPrint: .failure)", finder_open)

    def test_character_import_recovery_only_targets_reserved_uuid_staging(self) -> None:
        recovery = swift_function(self.storage, "func recoverInterruptedImports()")
        self.assertIn('let prefix = ".character-import-"', recovery)
        self.assertIn("UUID(uuidString: token) != nil", recovery)
        self.assertIn("Darwin.lstat", recovery)
        self.assertIn("S_IFDIR", recovery)
        self.assertIn("status.st_uid == Darwin.geteuid()", recovery)
        self.assertIn("FileManager.default.removeItem(at: url)", recovery)

    def test_catalog_reload_validates_new_active_map_before_publishing_library(self) -> None:
        body = swift_function(self.delegate, "private func handleCharacterLibraryReloadRequest()")
        self.assertIn(
            "snapshot.library.activeCharacter.mapPath != characterLibrary.activeCharacter.mapPath",
            body,
        )
        assignment = body.index("characterLibrary = snapshot.library")
        load = body.index("characterLibraryStorage.loadMediaMap(for: entry)")
        self.assertLess(
            load,
            assignment,
            "external catalog reload must load the candidate active map before replacing the live library",
        )
        launch = swift_function(self.delegate, "func applicationDidFinishLaunching(_ notification: Notification)")
        watched_startup = launch[launch.index("installWatchers()") :]
        self.assertLess(
            watched_startup.index("handleCharacterLibraryReloadRequest()"),
            watched_startup.index("if loadMediaMap().didChange"),
            "startup must close the catalog watch race before confirming the selected map",
        )

    def test_bundle_import_validates_committed_map_before_catalog_persistence(self) -> None:
        body = swift_function(
            self.delegate,
            "private func importCharacterBundle(_ url: URL, allowLegacyTrust: Bool)",
        )
        persist = body.index("persistCharacterLibrary(selected)")
        uses_staged_map = "map: staged.mediaMap" in body
        loads_before_persist = (
            "characterLibraryStorage.loadMediaMap(for: entry)" in body
            and body.index("characterLibraryStorage.loadMediaMap(for: entry)") < persist
        )
        self.assertTrue(
            uses_staged_map or loads_before_persist,
            "bundle map must be validated before the catalog can reference committed files",
        )


@unittest.skipUnless(sys.platform == "darwin", "native profile harness requires macOS")
class CharacterProfilePersistenceHarnessTests(unittest.TestCase):
    def test_custom_root_switch_survives_relaunch_and_stale_cas_keeps_baseline(self) -> None:
        swiftc = shutil.which("swiftc")
        self.assertIsNotNone(swiftc, "swiftc is required")
        harness_source = textwrap.dedent(
            r'''
            import CodexPetCore
            import Foundation

            enum HarnessFailure: Error { case failed(String) }

            @main
            struct CharacterProfilePersistenceHarness {
                static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
                    guard value() else { throw HarnessFailure.failed(message) }
                }

                static func main() throws {
                    let temporaryRoot = NSTemporaryDirectory().hasPrefix("/var/")
                        ? "/private" + NSTemporaryDirectory()
                        : NSTemporaryDirectory()
                    let root = URL(fileURLWithPath: temporaryRoot)
                        .appendingPathComponent("statelet-profile-harness-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: root,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700]
                    )
                    defer { try? FileManager.default.removeItem(at: root) }

                    let customMap = root.appendingPathComponent("custom-root.json")
                    let storage = CharacterLibraryStorage(
                        mediaMapURL: customMap,
                        playbackVerifier: { _, _ in }
                    )
                    let bootstrap = try storage.loadCatalog()
                    try require(bootstrap.encodedData == nil, "legacy catalog was not bootstrapped")
                    try require(bootstrap.library.activeCharacter.mapPath == "custom-root.json", "custom root basename was lost")
                    _ = try storage.saveMediaMap(try MediaMap(), for: bootstrap.library.activeCharacter, expectedData: nil)

                    let added = try bootstrap.library.addingCharacter(id: "chloe", name: "Chloe")
                    guard let chloe = added.character(id: "chloe") else {
                        throw HarnessFailure.failed("new profile missing")
                    }
                    _ = try storage.saveMediaMap(
                        try MediaMap(defaultFormat: "character-mov"),
                        for: chloe,
                        expectedData: nil
                    )
                    let selected = try added.selectingCharacter(id: "chloe")
                    let savedCatalog = try storage.saveCatalog(selected, expectedData: nil)

                    let relaunched = CharacterLibraryStorage(
                        mediaMapURL: customMap,
                        playbackVerifier: { _, _ in }
                    )
                    let snapshot = try relaunched.loadCatalog()
                    try require(snapshot.encodedData == savedCatalog, "catalog bytes changed across relaunch")
                    try require(snapshot.library.activeCharacterID == "chloe", "active profile did not persist")
                    let activeMap = try relaunched.loadMediaMap(for: snapshot.library.activeCharacter).map
                    try require(activeMap.defaultFormat == "character-mov", "relaunch loaded the legacy map instead of the active map")

                    let liveLibrary = snapshot.library
                    let liveMap = activeMap
                    do {
                        let renamed = try liveLibrary.renamingCharacter(id: "chloe", to: "Changed")
                        _ = try relaunched.saveCatalog(renamed, expectedData: nil)
                        throw HarnessFailure.failed("stale catalog CAS unexpectedly succeeded")
                    } catch CharacterLibraryStorageError.catalogConflict {
                        // The app publishes only after saveCatalog succeeds, so this baseline stays live.
                    }
                    try require(liveLibrary.activeCharacter.name == "Chloe", "failed CAS mutated the live library")
                    try require(liveMap.defaultFormat == "character-mov", "failed CAS mutated the live map")

                    var deletionRejected = false
                    do {
                        _ = try CharacterLibrary.legacy.removingCharacter(id: "default")
                    } catch {
                        deletionRejected = true
                    }
                    try require(deletionRejected, "last profile deletion unexpectedly succeeded")
                    print("character-profile-persistence-ok")
                }
            }
            '''
        )

        with tempfile.TemporaryDirectory(prefix="statelet-character-profile-") as temporary:
            temporary_path = Path(temporary)
            harness = temporary_path / "CharacterProfilePersistenceHarness.swift"
            module = temporary_path / "CodexPetCore.swiftmodule"
            library = temporary_path / "libCodexPetCore.dylib"
            executable = temporary_path / "character-profile-persistence-harness"
            harness.write_text(harness_source, encoding="utf-8")

            compile_core = subprocess.run(
                [
                    swiftc,
                    "-parse-as-library",
                    "-emit-library",
                    "-emit-module",
                    "-module-name",
                    "CodexPetCore",
                    *map(str, CORE_SOURCES),
                    "-emit-module-path",
                    str(module),
                    "-o",
                    str(library),
                ],
                capture_output=True,
                text=True,
                timeout=90,
                check=False,
            )
            self.assertEqual(compile_core.returncode, 0, compile_core.stderr)
            compile_harness = subprocess.run(
                [
                    swiftc,
                    "-parse-as-library",
                    "-I",
                    str(temporary_path),
                    "-L",
                    str(temporary_path),
                    "-lCodexPetCore",
                    str(IDENTITY),
                    str(ALPHA),
                    str(STORAGE),
                    str(harness),
                    "-Xlinker",
                    "-rpath",
                    "-Xlinker",
                    str(temporary_path),
                    "-o",
                    str(executable),
                ],
                capture_output=True,
                text=True,
                timeout=90,
                check=False,
            )
            self.assertEqual(compile_harness.returncode, 0, compile_harness.stderr)
            result = subprocess.run(
                [str(executable)], capture_output=True, text=True, timeout=30, check=False
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout.strip(), "character-profile-persistence-ok")


if __name__ == "__main__":
    unittest.main()
