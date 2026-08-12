#!/usr/bin/env python3
"""Native smoke tests for startup management and diagnostics privacy."""

from __future__ import annotations

import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "mac" / "CodexPetMac" / "Sources" / "CodexPetMac"


class MacPetStartupTests(unittest.TestCase):
    def test_preferences_migrate_before_app_and_defaults_consumers_are_created(self) -> None:
        main = (SOURCES / "main.swift").read_text(encoding="utf-8")
        delegate = (SOURCES / "PetAppDelegate.swift").read_text(encoding="utf-8")
        migration = main.index("let preferencesMigrationStatus = PreferencesMigration().migrate()")
        application = main.index("let application = NSApplication.shared")
        delegate_creation = main.index("let delegate = PetAppDelegate(")
        self.assertLess(migration, application)
        self.assertLess(migration, delegate_creation)
        failure_guard = main.index("guard preferencesMigrationStatus != .failed")
        self.assertLess(failure_guard, application)
        self.assertIn("exit(EXIT_FAILURE)", main[failure_guard:application])
        self.assertIn(
            "PetAppDelegate(preferencesMigrationStatus: preferencesMigrationStatus)",
            main,
        )
        self.assertNotIn("PreferencesMigration().migrate()", delegate.split("init(", 1)[1])

    def test_managed_startup_repair_toggle_and_diagnostics_are_safe(self) -> None:
        swiftc = shutil.which("swiftc")
        self.assertIsNotNone(swiftc, "swiftc is required for the native macOS companion tests")

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            home = root / "home"
            home.mkdir()
            harness = root / "StartupHarness.swift"
            executable = root / "startup-harness"
            harness.write_text(
                textwrap.dedent(
                    r'''
                    import CoreFoundation
                    import Foundation

                    enum HarnessFailure: Error { case failed(String) }

                    @main
                    struct StartupHarness {
                        static func main() throws {
                            if CommandLine.arguments.count == 3,
                               CommandLine.arguments[1] == "--lock-check" {
                                let home = URL(
                                    fileURLWithPath: CommandLine.arguments[2],
                                    isDirectory: true
                                )
                                exit(SingletonLock(homeURL: home) == nil ? 0 : 1)
                            }
                            guard StateletIdentity.appBundleName == "Statelet.app",
                                  StateletIdentity.executableName == "Statelet",
                                  StateletIdentity.bundleIdentifier == "com.coke1120.Statelet",
                                  StateletIdentity.applicationSupportRelativePath
                                      == "Library/Application Support/Statelet",
                                  StateletIdentity.playerLaunchAgentLabel
                                      == "com.coke1120.statelet.mac-player",
                                  StateletIdentity.aggregatorLaunchAgentLabel
                                      == "com.coke1120.statelet.state-aggregator",
                                  StateletIdentity.appManagedPlistKey == "StateletManaged",
                                  StateletIdentity.launchAgentManagedPlistKey == "StateletManaged",
                                  StateletIdentity.managedMarker == "statelet-v2",
                                  StateletIdentity.Legacy.bundleIdentifier == "com.coke1120.CodexPetMac" else {
                                throw HarnessFailure.failed("identity identifiers")
                            }
                            let home = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
                            let fm = FileManager.default
                            let app = home.appendingPathComponent(
                                "Applications/\(StateletIdentity.appBundleName)",
                                isDirectory: true
                            )
                            let contents = app.appendingPathComponent("Contents", isDirectory: true)
                            let executable = contents.appendingPathComponent(
                                "MacOS/\(StateletIdentity.executableName)"
                            )
                            try fm.createDirectory(
                                at: executable.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
                            guard chmod(executable.path, 0o755) == 0 else {
                                throw HarnessFailure.failed("chmod")
                            }
                            let info: [String: Any] = [
                                "CFBundleIdentifier": LaunchAtLoginManager.bundleIdentifier,
                                StateletIdentity.appManagedPlistKey: LaunchAtLoginManager.managedMarker,
                            ]
                            let infoData = try PropertyListSerialization.data(
                                fromPropertyList: info,
                                format: .xml,
                                options: 0
                            )
                            try infoData.write(to: contents.appendingPathComponent("Info.plist"))

                            let launchAgents = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
                            try fm.createDirectory(at: launchAgents, withIntermediateDirectories: true)
                            let plist = launchAgents.appendingPathComponent(
                                "\(LaunchAtLoginManager.playerLabel).plist"
                            )
                            let stale: [String: Any] = [
                                StateletIdentity.launchAgentManagedPlistKey: LaunchAtLoginManager.managedMarker,
                                "Label": LaunchAtLoginManager.playerLabel,
                                "RunAtLoad": false,
                            ]
                            try PropertyListSerialization.data(
                                fromPropertyList: stale,
                                format: .xml,
                                options: 0
                            ).write(to: plist)

                            let manager = LaunchAtLoginManager(homeURL: home)
                            guard manager.status().state == .staleManaged else {
                                throw HarnessFailure.failed("stale classification")
                            }
                            let repaired = try manager.repairStartup()
                            guard repaired.state == .managedDisabled, !repaired.isEnabled else {
                                throw HarnessFailure.failed("disabled repair")
                            }
                            let disabled = try manager.setEnabled(false)
                            guard disabled.state == .managedDisabled else {
                                throw HarnessFailure.failed("disable toggle")
                            }

                            let unmanagedData = try PropertyListSerialization.data(
                                fromPropertyList: ["Label": "someone.else"],
                                format: .xml,
                                options: 0
                            )
                            var injectedRace = false
                            let racingManager = LaunchAtLoginManager(
                                homeURL: home,
                                beforeTransactionSnapshot: {
                                    guard !injectedRace else { return }
                                    injectedRace = true
                                    try? unmanagedData.write(to: plist, options: .atomic)
                                }
                            )
                            do {
                                _ = try racingManager.setEnabled(false)
                                throw HarnessFailure.failed("raced unmanaged mutation was accepted")
                            } catch LaunchAtLoginManager.ManagerError.unmanagedPlist {
                                // Expected fail-closed behavior.
                            }
                            guard try Data(contentsOf: plist) == unmanagedData else {
                                throw HarnessFailure.failed("raced unmanaged plist was overwritten")
                            }

                            try fm.removeItem(at: plist)
                            var partiallyLoaded = false
                            let rollbackManager = LaunchAtLoginManager(
                                homeURL: home,
                                launchctlRunner: { arguments in
                                    switch arguments.first {
                                    case "print":
                                        return (partiallyLoaded, partiallyLoaded ? "partial" : "")
                                    case "bootstrap":
                                        partiallyLoaded = true
                                        return (false, "")
                                    case "bootout":
                                        return (false, "")
                                    default:
                                        return (false, "")
                                    }
                                }
                            )
                            do {
                                _ = try rollbackManager.repairStartup()
                                throw HarnessFailure.failed("partial launchd rollback was accepted")
                            } catch LaunchAtLoginManager.ManagerError.rollbackFailed {
                                // Disk rollback completes, but the simulated loaded job
                                // survives, so the manager must report incomplete rollback.
                            }
                            guard !fm.fileExists(atPath: plist.path), partiallyLoaded else {
                                throw HarnessFailure.failed("partial rollback evidence was lost")
                            }

                            let legacyPlist = launchAgents.appendingPathComponent(
                                "\(StateletIdentity.Legacy.playerLaunchAgentLabel).plist"
                            )
                            try PropertyListSerialization.data(
                                fromPropertyList: [
                                    StateletIdentity.Legacy.launchAgentManagedPlistKey:
                                        StateletIdentity.Legacy.managedMarker,
                                    "Label": StateletIdentity.Legacy.playerLaunchAgentLabel,
                                    "RunAtLoad": true,
                                ],
                                format: .xml,
                                options: 0
                            ).write(to: legacyPlist)
                            guard manager.status().state == .legacyManaged else {
                                throw HarnessFailure.failed("legacy startup classification")
                            }
                            try fm.removeItem(at: legacyPlist)

                            let legacySupport = home.appendingPathComponent(
                                StateletIdentity.Legacy.applicationSupportRelativePath,
                                isDirectory: true
                            )
                            let currentSupport = home.appendingPathComponent(
                                StateletIdentity.applicationSupportRelativePath,
                                isDirectory: true
                            )
                            var freshLock = SingletonLock(homeURL: home)
                            guard freshLock != nil,
                                  fm.fileExists(atPath: currentSupport.path),
                                  !fm.fileExists(atPath: legacySupport.path) else {
                                throw HarnessFailure.failed("fresh singleton identity")
                            }
                            freshLock = nil
                            try fm.createDirectory(at: legacySupport, withIntermediateDirectories: true)
                            guard let firstLock = SingletonLock(homeURL: home) else {
                                throw HarnessFailure.failed("dual identity singleton lock")
                            }
                            let competitor = Process()
                            competitor.executableURL = URL(
                                fileURLWithPath: CommandLine.arguments[0]
                            )
                            competitor.arguments = ["--lock-check", home.path]
                            try competitor.run()
                            competitor.waitUntilExit()
                            guard competitor.terminationStatus == 0 else {
                                throw HarnessFailure.failed("dual identity singleton exclusion")
                            }
                            guard fm.fileExists(
                                atPath: legacySupport.appendingPathComponent(".mac-player.lock").path
                            ), fm.fileExists(
                                atPath: currentSupport.appendingPathComponent(".mac-player.lock").path
                            ) else {
                                throw HarnessFailure.failed("dual identity lock files")
                            }
                            withExtendedLifetime(firstLock) {}

                            let preferences = home.appendingPathComponent("Library/Preferences", isDirectory: true)
                            try fm.createDirectory(at: preferences, withIntermediateDirectories: true)
                            let legacyPreferences = preferences.appendingPathComponent(
                                "\(StateletIdentity.Legacy.bundleIdentifier).plist"
                            )
                            let currentPreferences = preferences.appendingPathComponent(
                                "\(StateletIdentity.bundleIdentifier).plist"
                            )
                            let legacyDefaults: [String: Any] = [
                                "unknown-key": "preserved",
                                "shared-key": "legacy",
                                "CodexPetMac.lastWindowFrame.v2": ["x": 1.0],
                                "CodexPetAlphaConversionProfile": "fit",
                                "CodexPetAlphaPythonPath": "/private/interpreter",
                            ]
                            let currentDefaults: [String: Any] = ["shared-key": "current"]
                            try PropertyListSerialization.data(
                                fromPropertyList: legacyDefaults,
                                format: .binary,
                                options: 0
                            ).write(to: legacyPreferences)
                            try PropertyListSerialization.data(
                                fromPropertyList: currentDefaults,
                                format: .binary,
                                options: 0
                            ).write(to: currentPreferences)
                            let migration = PreferencesMigration(homeURL: home)
                            guard migration.migrate() == .migrated else {
                                throw HarnessFailure.failed("preferences migration")
                            }
                            let migratedData = try Data(contentsOf: currentPreferences)
                            let migrated = try PropertyListSerialization.propertyList(
                                from: migratedData,
                                options: [],
                                format: nil
                            ) as! [String: Any]
                            guard migrated["unknown-key"] as? String == "preserved",
                                  migrated["shared-key"] as? String == "current",
                                  migrated["CodexPetMac.lastWindowFrame.v2"] == nil,
                                  migrated["Statelet.lastWindowFrame.v2"] != nil,
                                  migrated["StateletAlphaConversionProfile"] as? String == "fit",
                                  migrated["StateletAlphaPythonPath"] as? String == "/private/interpreter",
                                  migration.migrate() == .alreadyCurrent,
                                  fm.fileExists(atPath: legacyPreferences.path) else {
                                throw HarnessFailure.failed("preferences preservation")
                            }

                            let nativeLegacyID = "com.coke1120.StateletHarness.Legacy"
                            let nativeDestinationID = "com.coke1120.StateletHarness.Current"
                            CFPreferencesSetValue(
                                "native-key" as CFString,
                                "cfpreferences" as CFString,
                                nativeLegacyID as CFString,
                                kCFPreferencesCurrentUser,
                                kCFPreferencesAnyHost
                            )
                            guard CFPreferencesSynchronize(
                                nativeLegacyID as CFString,
                                kCFPreferencesCurrentUser,
                                kCFPreferencesAnyHost
                            ) else {
                                throw HarnessFailure.failed("native preferences seed")
                            }
                            defer {
                                CFPreferencesSetValue(
                                    "native-key" as CFString,
                                    nil,
                                    nativeLegacyID as CFString,
                                    kCFPreferencesCurrentUser,
                                    kCFPreferencesAnyHost
                                )
                                CFPreferencesSetValue(
                                    "native-key" as CFString,
                                    nil,
                                    nativeDestinationID as CFString,
                                    kCFPreferencesCurrentUser,
                                    kCFPreferencesAnyHost
                                )
                                CFPreferencesSynchronize(
                                    nativeLegacyID as CFString,
                                    kCFPreferencesCurrentUser,
                                    kCFPreferencesAnyHost
                                )
                                CFPreferencesSynchronize(
                                    nativeDestinationID as CFString,
                                    kCFPreferencesCurrentUser,
                                    kCFPreferencesAnyHost
                                )
                            }
                            let nativeMigration = PreferencesMigration(
                                homeURL: home,
                                legacyIdentifier: nativeLegacyID,
                                destinationIdentifier: nativeDestinationID,
                                useNativePreferences: true
                            )
                            guard nativeMigration.migrate() == .migrated,
                                  (CFPreferencesCopyMultiple(
                                      nil,
                                      nativeDestinationID as CFString,
                                      kCFPreferencesCurrentUser,
                                      kCFPreferencesAnyHost
                                  ) as? [String: Any])?["native-key"] as? String
                                      == "cfpreferences",
                                  CFPreferencesSynchronize(
                                      nativeDestinationID as CFString,
                                      kCFPreferencesCurrentUser,
                                      kCFPreferencesAnyHost
                                  ) else {
                                throw HarnessFailure.failed("native preferences publication")
                            }

                            let report = PetDiagnostics(homeURL: home).build(
                                input: PetDiagnosticsInput(
                                    appVersion: "1.1.0",
                                    appBuild: "2",
                                    lifecycleState: "running",
                                    publisherHealth: "live",
                                    publisherSource: "/Users/private/source",
                                    playbackMode: "random",
                                    selectedClipName: "/Users/private/media/clip.mov",
                                    previewStatus: "presented",
                                    toolchainStatus: "ready",
                                    preferencesMigrationStatus: .migrated
                                )
                            )
                            guard !report.contains(home.path),
                                  !report.contains("/Users/private"),
                                  report.contains("playback.media: mov"),
                                  !report.contains("clip.mov"),
                                  report.contains("publisher.source: unavailable") else {
                                throw HarnessFailure.failed("diagnostics privacy")
                            }
                            print("startup and diagnostics self-test passed")
                        }
                    }
                    '''
                ),
                encoding="utf-8",
            )

            compiled = subprocess.run(
                [
                    swiftc,
                    str(SOURCES / "StateletIdentity.swift"),
                    str(SOURCES / "PreferencesMigration.swift"),
                    str(SOURCES / "SingletonLock.swift"),
                    str(SOURCES / "LaunchAtLoginManager.swift"),
                    str(SOURCES / "PetDiagnostics.swift"),
                    str(harness),
                    "-o",
                    str(executable),
                ],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run(
                [str(executable), str(home)],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("startup and diagnostics self-test passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
