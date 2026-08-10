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
                    import Foundation

                    enum HarnessFailure: Error { case failed(String) }

                    @main
                    struct StartupHarness {
                        static func main() throws {
                            let home = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
                            let fm = FileManager.default
                            let app = home.appendingPathComponent("Applications/Statelet.app", isDirectory: true)
                            let contents = app.appendingPathComponent("Contents", isDirectory: true)
                            let executable = contents.appendingPathComponent("MacOS/CodexPetMac")
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
                                "CodexPetManaged": LaunchAtLoginManager.managedMarker,
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
                                "CodexPetMacManaged": LaunchAtLoginManager.managedMarker,
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
                                    toolchainStatus: "ready"
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
