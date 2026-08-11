#!/usr/bin/env python3
"""Executable filesystem contracts for character catalog and bundle storage."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MAC_SOURCES = ROOT / "mac" / "CodexPetMac" / "Sources"
CORE_SOURCES = sorted((MAC_SOURCES / "CodexPetCore").glob("*.swift"))
STORAGE = MAC_SOURCES / "CodexPetMac" / "CharacterLibraryStorage.swift"
ALPHA = MAC_SOURCES / "CodexPetMac" / "AlphaConversion.swift"
IDENTITY = MAC_SOURCES / "CodexPetMac" / "StateletIdentity.swift"


class CharacterStorageSourceTests(unittest.TestCase):
    def test_storage_exposes_cas_staging_and_secure_open_contracts(self) -> None:
        source = STORAGE.read_text(encoding="utf-8")
        for contract in (
            "O_NOFOLLOW",
            "expectedData: Data?",
            "CharacterLibrary.legacy(mapPath:",
            "func stageImport(",
            "func rollback()",
            "func finalize()",
            "rejectHardLinks: true",
            "maximumAggregateSize",
            "characterLimitReached",
            "AlphaPlaybackProcessValidator",
        ):
            self.assertIn(contract, source)


@unittest.skipUnless(sys.platform == "darwin", "native storage harness requires macOS")
class CharacterStorageHarnessTests(unittest.TestCase):
    def test_catalog_bundle_roundtrip_and_adversarial_filesystem_cases(self) -> None:
        swiftc = shutil.which("swiftc")
        self.assertIsNotNone(swiftc, "swiftc is required")
        harness_source = textwrap.dedent(
            r'''
            import CodexPetCore
            import Darwin
            import Foundation

            enum HarnessFailure: Error { case failed(String) }

            @main
            struct CharacterStorageHarness {
                static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
                    guard value() else { throw HarnessFailure.failed(message) }
                }

                static func expectFailure(_ message: String, _ body: () throws -> Void) throws {
                    do { try body() } catch { return }
                    throw HarnessFailure.failed(message)
                }

                static func write(_ data: Data, to url: URL) throws {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                    try data.write(to: url)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }

                static func makeStorage(_ root: URL) throws -> CharacterLibraryStorage {
                    try FileManager.default.createDirectory(
                        at: root,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700]
                    )
                    return CharacterLibraryStorage(
                        mediaMapURL: root.appendingPathComponent("custom-map.json"),
                        playbackVerifier: { movie, _ in
                            let data = try Data(contentsOf: movie)
                            guard !data.isEmpty else { throw HarnessFailure.failed("empty movie") }
                        }
                    )
                }

                static func makePopulatedCharacter(
                    storage: CharacterLibraryStorage,
                    root: URL,
                    name: String = "Chloe"
                ) throws -> CharacterLibraryEntry {
                    let entry = try CharacterLibraryEntry(id: "source", name: name)
                    let movie = root.appendingPathComponent("My Clip.mov")
                    let poster = root.appendingPathComponent("My Clip.png")
                    let report = root.appendingPathComponent("My Clip.report.json")
                    try write(Data("movie".utf8), to: movie)
                    try write(Data("poster".utf8), to: poster)
                    try write(Data("report".utf8), to: report)
                    let media = try MediaEntry(path: movie.path, posterPath: poster.path)
                    let map = try MediaMap(states: [.idle: try StateMediaPlaylist(entries: [media])])
                    _ = try storage.saveMediaMap(map, for: entry, expectedData: nil)
                    return entry
                }

                static func main() throws {
                    let temporaryRoot = NSTemporaryDirectory().hasPrefix("/var/")
                        ? "/private" + NSTemporaryDirectory()
                        : NSTemporaryDirectory()
                    let base = URL(fileURLWithPath: temporaryRoot)
                        .appendingPathComponent("statelet-storage-harness-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
                    defer { try? FileManager.default.removeItem(at: base) }

                    // Bootstrap uses the configured root-map basename, and catalog writes are CAS.
                    let catalogRoot = base.appendingPathComponent("catalog", isDirectory: true)
                    let catalogStorage = try makeStorage(catalogRoot)
                    let bootstrap = try catalogStorage.loadCatalog()
                    try require(bootstrap.encodedData == nil, "absent catalog did not bootstrap")
                    try require(bootstrap.library.activeCharacter.mapPath == "custom-map.json", "bootstrap map basename changed")
                    let firstData = try catalogStorage.saveCatalog(bootstrap.library, expectedData: nil)
                    try expectFailure("stale catalog CAS succeeded") {
                        _ = try catalogStorage.saveCatalog(bootstrap.library, expectedData: nil)
                    }
                    let persisted = try catalogStorage.loadCatalog()
                    try require(persisted.encodedData == firstData, "catalog bytes did not round trip")
                    let catalogMode = try FileManager.default.attributesOfItem(atPath: catalogStorage.catalogURL.path)[.posixPermissions] as! NSNumber
                    try require(catalogMode.intValue & 0o077 == 0, "catalog is not private")

                    // Creating an owned nested root never chmods a pre-existing ancestor.
                    let permissionParent = base.appendingPathComponent("permission-parent", isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: permissionParent,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o755]
                    )
                    let missingRoot = permissionParent.appendingPathComponent("owned/nested", isDirectory: true)
                    let missingStorage = CharacterLibraryStorage(
                        mediaMapURL: missingRoot.appendingPathComponent("media-map.json"),
                        playbackVerifier: { _, _ in }
                    )
                    let missingBootstrap = try missingStorage.loadCatalog()
                    _ = try missingStorage.saveCatalog(missingBootstrap.library, expectedData: nil)
                    let parentMode = try FileManager.default.attributesOfItem(atPath: permissionParent.path)[.posixPermissions] as! NSNumber
                    let ownedMode = try FileManager.default.attributesOfItem(atPath: missingRoot.path)[.posixPermissions] as! NSNumber
                    try require(parentMode.intValue & 0o777 == 0o755, "pre-existing ancestor permissions changed")
                    try require(ownedMode.intValue & 0o077 == 0, "newly owned directory is not private")

                    // Empty maps export as valid empty packages.
                    let emptyEntry = try CharacterLibraryEntry(id: "empty", name: "Empty")
                    _ = try catalogStorage.saveMediaMap(try MediaMap(), for: emptyEntry, expectedData: nil)
                    let emptyPackage = base.appendingPathComponent("empty.statelet-character", isDirectory: true)
                    try catalogStorage.exportCharacter(emptyEntry, to: emptyPackage)
                    let emptyManifest = try CharacterBundleManifest.decode(Data(contentsOf: emptyPackage.appendingPathComponent("manifest.json")))
                    try require(emptyManifest.assets.isEmpty, "empty export contains assets")
                    try require(emptyManifest.mediaMap.states.isEmpty, "empty export changed map")

                    // Populated export/import preserves bytes and resolves name collisions.
                    let roundtripRoot = base.appendingPathComponent("roundtrip", isDirectory: true)
                    let storage = try makeStorage(roundtripRoot)
                    let sourceEntry = try makePopulatedCharacter(storage: storage, root: roundtripRoot)
                    let package = base.appendingPathComponent("chloe.statelet-character", isDirectory: true)
                    try storage.exportCharacter(sourceEntry, to: package)
                    let exportedManifest = try CharacterBundleManifest.decode(
                        Data(contentsOf: package.appendingPathComponent("manifest.json"))
                    )

                    let lowDiskPackage = base.appendingPathComponent("low-disk.statelet-character", isDirectory: true)
                    let lowDiskStorage = CharacterLibraryStorage(
                        mediaMapURL: storage.rootMediaMapURL,
                        playbackVerifier: { _, _ in },
                        availableDiskBytes: { _ in 0 }
                    )
                    try expectFailure("export ignored disk preflight") {
                        try lowDiskStorage.exportCharacter(sourceEntry, to: lowDiskPackage)
                    }
                    try require(!FileManager.default.fileExists(atPath: lowDiskPackage.path), "low-disk export left a package")

                    let corruptPackage = base.appendingPathComponent("corrupt.statelet-character", isDirectory: true)
                    let corruptStorage = CharacterLibraryStorage(
                        mediaMapURL: storage.rootMediaMapURL,
                        playbackVerifier: { movie, _ in try Data("mutated".utf8).write(to: movie) }
                    )
                    try expectFailure("export published bytes mutated during verification") {
                        try corruptStorage.exportCharacter(sourceEntry, to: corruptPackage)
                    }
                    try require(!FileManager.default.fileExists(atPath: corruptPackage.path), "failed export left a package")
                    let exportedMovie = exportedManifest.assets.first(where: { $0.role == .movie })!
                    try require(
                        URL(fileURLWithPath: exportedMovie.path).lastPathComponent == "My Clip.mov",
                        "export changed a report-bound movie basename"
                    )
                    try require(
                        exportedManifest.assets.filter({ $0.role == .report }).count == 1,
                        "export did not include the sibling report"
                    )
                    let existing = try CharacterLibrary(
                        activeCharacterID: "default",
                        characters: [
                            try CharacterLibraryEntry(id: "default", name: "Default", mapPath: "custom-map.json"),
                            try CharacterLibraryEntry(id: "existing", name: "Chloe"),
                        ]
                    )
                    let staged = try storage.stageImport(from: package, against: existing, allowLegacyTrust: true)
                    try require(staged.entry.name == "Chloe 2", "name collision was not resolved")
                    let installedEntry = try staged.commit()
                    let installed = try storage.loadMediaMap(for: installedEntry).map
                    guard let installedMoviePath = installed.states[.idle]?.entries.first?.path else {
                        throw HarnessFailure.failed("installed movie missing")
                    }
                    let installedMovie = roundtripRoot.appendingPathComponent(installedMoviePath)
                    let installedMovieData = try Data(contentsOf: installedMovie)
                    try require(installedMovieData == Data("movie".utf8), "movie bytes changed")
                    staged.finalize()
                    let reexport = base.appendingPathComponent("chloe-reexport.statelet-character", isDirectory: true)
                    try storage.exportCharacter(installedEntry, to: reexport)
                    let reexportedManifest = try CharacterBundleManifest.decode(
                        Data(contentsOf: reexport.appendingPathComponent("manifest.json"))
                    )
                    try require(
                        reexportedManifest.assets.filter({ $0.role == .report }).count == 1,
                        "import did not retain the report beside its installed movie"
                    )

                    // A committed import can be rolled back when the caller's catalog CAS fails.
                    let rollbackStage = try storage.stageImport(from: package, against: existing, allowLegacyTrust: true)
                    let rollbackEntry = try rollbackStage.commit()
                    let rollbackMap = rollbackEntry.resolvedMapURL(relativeTo: storage.rootMediaMapURL)
                    try require(FileManager.default.fileExists(atPath: rollbackMap.path), "commit did not publish map")
                    rollbackStage.rollback()
                    try require(!FileManager.default.fileExists(atPath: rollbackMap.path), "rollback left the map behind")

                    // Hash mismatch is rejected and private staging is cleaned.
                    let hashPackage = base.appendingPathComponent("hash.statelet-character", isDirectory: true)
                    try FileManager.default.copyItem(at: package, to: hashPackage)
                    let hashManifest = try CharacterBundleManifest.decode(Data(contentsOf: hashPackage.appendingPathComponent("manifest.json")))
                    let hashMovie = hashManifest.assets.first(where: { $0.role == .movie })!
                    try write(Data("tampered".utf8), to: hashPackage.appendingPathComponent(hashMovie.path))
                    let beforeHashFailure = Set(try FileManager.default.contentsOfDirectory(atPath: roundtripRoot.path))
                    try expectFailure("hash mismatch imported") {
                        _ = try storage.stageImport(from: hashPackage, against: existing, allowLegacyTrust: true)
                    }
                    let afterHashFailure = Set(try FileManager.default.contentsOfDirectory(atPath: roundtripRoot.path))
                    try require(beforeHashFailure == afterHashFailure, "failed import leaked staging")

                    // Symlink assets are rejected by component-wise O_NOFOLLOW traversal.
                    let symlinkPackage = base.appendingPathComponent("symlink.statelet-character", isDirectory: true)
                    try FileManager.default.copyItem(at: package, to: symlinkPackage)
                    let symlinkManifest = try CharacterBundleManifest.decode(Data(contentsOf: symlinkPackage.appendingPathComponent("manifest.json")))
                    let symlinkAsset = symlinkManifest.assets.first(where: { $0.role == .movie })!
                    let symlinkURL = symlinkPackage.appendingPathComponent(symlinkAsset.path)
                    try FileManager.default.removeItem(at: symlinkURL)
                    try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: roundtripRoot.appendingPathComponent("idle.mov"))
                    try expectFailure("symlink asset imported") {
                        _ = try storage.stageImport(from: symlinkPackage, against: existing, allowLegacyTrust: true)
                    }
                    let symlinkRoot = base.appendingPathComponent("package-link.statelet-character")
                    try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: package)
                    try expectFailure("symlink package root imported") {
                        _ = try storage.stageImport(from: symlinkRoot, against: existing, allowLegacyTrust: true)
                    }

                    // Traversal and per-role oversize declarations fail at manifest validation.
                    let manifestURL = package.appendingPathComponent("manifest.json")
                    let manifestText = try String(contentsOf: manifestURL, encoding: .utf8)
                    let moviePath = try CharacterBundleManifest.decode(Data(manifestText.utf8)).assets.first(where: { $0.role == .movie })!.path
                    let traversalText = manifestText.replacingOccurrences(of: moviePath, with: "../escape.mov")
                    let traversalPackage = base.appendingPathComponent("traversal.statelet-character", isDirectory: true)
                    try FileManager.default.copyItem(at: package, to: traversalPackage)
                    try write(Data(traversalText.utf8), to: traversalPackage.appendingPathComponent("manifest.json"))
                    try expectFailure("traversal manifest imported") {
                        _ = try storage.stageImport(from: traversalPackage, against: existing, allowLegacyTrust: true)
                    }

                    let declaredSize = try CharacterBundleManifest.decode(Data(manifestText.utf8)).assets.first(where: { $0.role == .movie })!.size
                    let oversizedText = manifestText.replacingOccurrences(
                        of: "\"size\" : \(declaredSize)",
                        with: "\"size\" : \(CharacterBundleManifest.maximumMovieSize + 1)"
                    )
                    let oversizedPackage = base.appendingPathComponent("oversized.statelet-character", isDirectory: true)
                    try FileManager.default.copyItem(at: package, to: oversizedPackage)
                    try write(Data(oversizedText.utf8), to: oversizedPackage.appendingPathComponent("manifest.json"))
                    try expectFailure("oversized declaration imported") {
                        _ = try storage.stageImport(from: oversizedPackage, against: existing, allowLegacyTrust: true)
                    }

                    // Reportless movies are fail-closed unless explicitly trusted.
                    let reportlessPackage = base.appendingPathComponent("reportless.statelet-character", isDirectory: true)
                    try FileManager.default.copyItem(at: package, to: reportlessPackage)
                    let reportlessManifest = try CharacterBundleManifest(
                        characterID: exportedManifest.characterID,
                        characterName: exportedManifest.characterName,
                        mediaMap: exportedManifest.mediaMap,
                        assets: exportedManifest.assets.filter { $0.role != .report }
                    )
                    let reportlessEncoder = JSONEncoder()
                    reportlessEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try write(
                        try reportlessEncoder.encode(reportlessManifest),
                        to: reportlessPackage.appendingPathComponent("manifest.json")
                    )
                    try expectFailure("reportless movie did not require trust") {
                        _ = try storage.stageImport(from: reportlessPackage, against: existing, allowLegacyTrust: false)
                    }
                    print("character-storage-ok")
                }
            }
            '''
        )

        with tempfile.TemporaryDirectory(prefix="statelet-character-storage-") as temporary:
            temporary_path = Path(temporary)
            harness = temporary_path / "CharacterStorageHarness.swift"
            module = temporary_path / "CodexPetCore.swiftmodule"
            library = temporary_path / "libCodexPetCore.dylib"
            executable = temporary_path / "character-storage-harness"
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
            self.assertEqual(result.stdout.strip(), "character-storage-ok")


if __name__ == "__main__":
    unittest.main()
