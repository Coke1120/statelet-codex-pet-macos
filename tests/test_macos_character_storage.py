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
            "attestRuntimeTransition(",
            "CharacterTransitionRuntimeAttestation",
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
            import CryptoKit
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

                static func sha256(_ data: Data) -> String {
                    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
                        },
                        transitionPlaybackVerifier: { movie, report in
                            guard !(try Data(contentsOf: movie)).isEmpty, !report.isEmpty else {
                                throw HarnessFailure.failed("invalid transition alpha contract")
                            }
                        },
                        transitionDurationVerifier: { _ in }
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

                    // Directional transition assets survive the same secure bundle round trip.
                    let transitionMovie = roundtripRoot.appendingPathComponent("Idle to Running.mov")
                    let transitionReport = roundtripRoot.appendingPathComponent("Idle to Running.report.json")
                    try write(Data("transition".utf8), to: transitionMovie)
                    try write(Data("transition-report".utf8), to: transitionReport)
                    var runtimeAlphaChecks = 0
                    var runtimeDurationChecks = 0
                    let runtimeAttestation = try CharacterLibraryStorage.attestRuntimeTransition(
                        movieURL: transitionMovie,
                        transitionPlaybackVerifier: { movie, report in
                            let movieData = try Data(contentsOf: movie)
                            try require(movieData == Data("transition".utf8), "runtime verifier saw wrong movie")
                            try require(report == Data("transition-report".utf8), "runtime verifier saw wrong report")
                            runtimeAlphaChecks += 1
                        },
                        transitionDurationVerifier: { movie in
                            try require(movie == transitionMovie, "runtime duration verifier saw wrong movie")
                            runtimeDurationChecks += 1
                        }
                    )
                    try require(runtimeAlphaChecks == 1, "runtime alpha verifier was not called exactly once")
                    try require(runtimeDurationChecks == 1, "runtime duration verifier was not called exactly once")
                    try require(
                        runtimeAttestation.movieRevision == LocalFileRevision(url: transitionMovie),
                        "runtime movie revision was not current"
                    )
                    try require(
                        runtimeAttestation.reportRevision == LocalFileRevision(url: transitionReport),
                        "runtime report revision was not current"
                    )
                    try require(
                        runtimeAttestation.movieSHA256 == sha256(Data("transition".utf8)),
                        "runtime movie digest was not current"
                    )
                    try require(
                        runtimeAttestation.reportSHA256 == sha256(Data("transition-report".utf8)),
                        "runtime report digest was not current"
                    )
                    try runtimeAttestation.requireUnchanged(movieURL: transitionMovie)
                    let originalMovieTimes = try FileManager.default.attributesOfItem(atPath: transitionMovie.path)
                    try write(Data("transitioN".utf8), to: transitionMovie)
                    try FileManager.default.setAttributes(
                        [.modificationDate: originalMovieTimes[.modificationDate] as Any],
                        ofItemAtPath: transitionMovie.path
                    )
                    try expectFailure("bind-time attestation accepted digest-changed movie bytes") {
                        try runtimeAttestation.requireUnchanged(movieURL: transitionMovie)
                    }
                    try write(Data("transition".utf8), to: transitionMovie)

                    let runtimeReportlessMovie = roundtripRoot.appendingPathComponent("Runtime Reportless.mov")
                    try write(Data("transition".utf8), to: runtimeReportlessMovie)
                    try expectFailure("runtime attestation accepted a reportless transition") {
                        _ = try CharacterLibraryStorage.attestRuntimeTransition(
                            movieURL: runtimeReportlessMovie,
                            transitionPlaybackVerifier: { _, _ in },
                            transitionDurationVerifier: { _ in }
                        )
                    }
                    try expectFailure("runtime attestation accepted an opaque transition") {
                        _ = try CharacterLibraryStorage.attestRuntimeTransition(
                            movieURL: transitionMovie,
                            transitionPlaybackVerifier: { _, _ in throw HarnessFailure.failed("opaque") },
                            transitionDurationVerifier: { _ in }
                        )
                    }
                    try expectFailure("runtime attestation accepted replaced movie bytes") {
                        _ = try CharacterLibraryStorage.attestRuntimeTransition(
                            movieURL: transitionMovie,
                            transitionPlaybackVerifier: { movie, _ in try write(Data("replacement".utf8), to: movie) },
                            transitionDurationVerifier: { _ in }
                        )
                    }
                    try write(Data("transition".utf8), to: transitionMovie)
                    try expectFailure("runtime attestation accepted replaced report bytes") {
                        _ = try CharacterLibraryStorage.attestRuntimeTransition(
                            movieURL: transitionMovie,
                            transitionPlaybackVerifier: { _, _ in
                                try write(Data("replacement-report".utf8), to: transitionReport)
                            },
                            transitionDurationVerifier: { _ in }
                        )
                    }
                    try write(Data("transition-report".utf8), to: transitionReport)
                    let transitionMap = try (try storage.loadMediaMap(for: sourceEntry).map)
                        .settingTransition(
                            from: .idle,
                            to: .running,
                            entry: try MediaEntry(path: transitionMovie.path, loop: false)
                        )
                    let existingMapData = try storage.loadMediaMap(for: sourceEntry).encodedData
                    _ = try storage.saveMediaMap(transitionMap, for: sourceEntry, expectedData: existingMapData)
                    let recoveryCatalogBootstrap = try storage.loadCatalog()
                    let recoveryLibrary = try recoveryCatalogBootstrap.library
                        .addingCharacter(id: sourceEntry.id, name: sourceEntry.name)
                        .selectingCharacter(id: sourceEntry.id)
                    _ = try storage.saveCatalog(
                        recoveryLibrary,
                        expectedData: recoveryCatalogBootstrap.encodedData
                    )
                    let ownerSnapshot = try storage.loadCatalog()
                    let recoveredTransitionMap = try transitionMap.settingTransition(
                        from: .running,
                        to: .idle,
                        entry: try MediaEntry(path: transitionMovie.path, loop: false)
                    )
                    let recoveredBytes = try storage.saveRecoveredMediaMap(
                        recoveredTransitionMap,
                        for: sourceEntry,
                        expectedData: try storage.loadMediaMap(for: sourceEntry).encodedData,
                        expectedCatalogData: ownerSnapshot.encodedData
                    )
                    try require(!recoveredBytes.isEmpty, "recovery CAS did not publish owner map")
                    let changedCatalog = try ownerSnapshot.library.renamingCharacter(id: sourceEntry.id, to: "Chloe Changed")
                    let changedCatalogBytes = try storage.saveCatalog(changedCatalog, expectedData: ownerSnapshot.encodedData)
                    let currentRecoveredBytes = try storage.loadMediaMap(for: sourceEntry).encodedData
                    try expectFailure("recovery ignored catalog ownership change") {
                        _ = try storage.saveRecoveredMediaMap(
                            transitionMap,
                            for: sourceEntry,
                            expectedData: currentRecoveredBytes,
                            expectedCatalogData: ownerSnapshot.encodedData
                        )
                    }
                    _ = try storage.saveCatalog(ownerSnapshot.library, expectedData: changedCatalogBytes)
                    let restoredCatalog = try storage.loadCatalog()
                    let staleMapBytes = try storage.loadMediaMap(for: sourceEntry).encodedData
                    let externallyChangedMap = try recoveredTransitionMap.settingTransition(
                        from: .idle,
                        to: .waiting,
                        entry: try MediaEntry(path: transitionMovie.path, loop: false)
                    )
                    _ = try storage.saveMediaMap(
                        externallyChangedMap,
                        for: sourceEntry,
                        expectedData: staleMapBytes
                    )
                    try expectFailure("recovery ignored owner map change") {
                        _ = try storage.saveRecoveredMediaMap(
                            transitionMap,
                            for: sourceEntry,
                            expectedData: staleMapBytes,
                            expectedCatalogData: restoredCatalog.encodedData
                        )
                    }
                    let transitionPackage = base.appendingPathComponent("transition.statelet-character", isDirectory: true)
                    try storage.exportCharacter(sourceEntry, to: transitionPackage)
                    let transitionManifest = try CharacterBundleManifest.decode(
                        Data(contentsOf: transitionPackage.appendingPathComponent("manifest.json"))
                    )
                    guard let bundledTransition = transitionManifest.mediaMap.transition(from: .idle, to: .running) else {
                        throw HarnessFailure.failed("export omitted directional transition")
                    }
                    try require(
                        transitionManifest.assets.contains(where: { $0.role == .movie && $0.path == bundledTransition.path }),
                        "transition movie was not declared"
                    )
                    let transitionReportAsset = transitionManifest.assets.first(where: {
                        $0.role == .report && $0.moviePath == bundledTransition.path
                    })
                    try require(transitionReportAsset != nil, "transition report role/movie_path was not preserved")
                    if let transitionReportAsset {
                        let reportBytes = try Data(contentsOf: transitionPackage.appendingPathComponent(transitionReportAsset.path))
                        let reportDigest = SHA256.hash(data: reportBytes).map { String(format: "%02x", $0) }.joined()
                        try require(reportDigest == transitionReportAsset.sha256, "transition report hash did not bind bytes")
                    }
                    let durationRejectingStorage = CharacterLibraryStorage(
                        mediaMapURL: storage.rootMediaMapURL,
                        playbackVerifier: { _, _ in },
                        transitionPlaybackVerifier: { _, _ in },
                        transitionDurationVerifier: { _ in throw HarnessFailure.failed("transition too long") }
                    )
                    let tooLongPackage = base.appendingPathComponent("transition-too-long.statelet-character", isDirectory: true)
                    try expectFailure("transition duration hook was not enforced") {
                        try durationRejectingStorage.exportCharacter(sourceEntry, to: tooLongPackage)
                    }
                    try require(
                        !FileManager.default.fileExists(atPath: tooLongPackage.path),
                        "failed duration verification published a package"
                    )
                    let transitionStage = try storage.stageImport(
                        from: transitionPackage,
                        against: existing,
                        allowLegacyTrust: true
                    )
                    guard let installedTransition = transitionStage.mediaMap.transition(from: .idle, to: .running) else {
                        throw HarnessFailure.failed("import omitted directional transition")
                    }
                    try require(
                        installedTransition.path.hasPrefix(".character-"),
                        "import did not rewrite transition path"
                    )
                    transitionStage.discard()
                    let rejectingImportStorage = CharacterLibraryStorage(
                        mediaMapURL: storage.rootMediaMapURL,
                        playbackVerifier: { _, _ in },
                        transitionPlaybackVerifier: { _, _ in },
                        transitionDurationVerifier: { _ in throw HarnessFailure.failed("transition too long") }
                    )
                    let beforeDurationImport = Set(try FileManager.default.contentsOfDirectory(atPath: roundtripRoot.path))
                    try expectFailure("import ignored transition duration hook") {
                        _ = try rejectingImportStorage.stageImport(
                            from: transitionPackage,
                            against: existing,
                            allowLegacyTrust: true
                        )
                    }
                    let afterDurationImport = Set(try FileManager.default.contentsOfDirectory(atPath: roundtripRoot.path))
                    try require(beforeDurationImport == afterDurationImport, "failed duration import leaked staging or final artifacts")

                    let opaqueRejectingStorage = CharacterLibraryStorage(
                        mediaMapURL: storage.rootMediaMapURL,
                        playbackVerifier: { _, _ in },
                        transitionPlaybackVerifier: { _, _ in
                            throw HarnessFailure.failed("opaque transition")
                        },
                        transitionDurationVerifier: { _ in }
                    )
                    let opaquePackage = base.appendingPathComponent("transition-opaque.statelet-character", isDirectory: true)
                    try expectFailure("export accepted transition rejected by alpha verifier") {
                        try opaqueRejectingStorage.exportCharacter(sourceEntry, to: opaquePackage)
                    }
                    try require(!FileManager.default.fileExists(atPath: opaquePackage.path), "opaque export left a package")
                    try expectFailure("import accepted transition rejected by alpha verifier") {
                        _ = try opaqueRejectingStorage.stageImport(
                            from: transitionPackage,
                            against: existing,
                            allowLegacyTrust: true
                        )
                    }

                    let transitionReportlessPackage = base.appendingPathComponent("transition-reportless.statelet-character", isDirectory: true)
                    try FileManager.default.copyItem(at: transitionPackage, to: transitionReportlessPackage)
                    let transitionReportlessManifest = try CharacterBundleManifest(
                        characterID: transitionManifest.characterID,
                        characterName: transitionManifest.characterName,
                        mediaMap: transitionManifest.mediaMap,
                        assets: transitionManifest.assets.filter {
                            !($0.role == .report && $0.moviePath == bundledTransition.path)
                        }
                    )
                    let transitionEncoder = JSONEncoder()
                    transitionEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try write(
                        try transitionEncoder.encode(transitionReportlessManifest),
                        to: transitionReportlessPackage.appendingPathComponent("manifest.json")
                    )
                    try expectFailure("legacy trust allowed a reportless transition") {
                        _ = try storage.stageImport(
                            from: transitionReportlessPackage,
                            against: existing,
                            allowLegacyTrust: true
                        )
                    }

                    let tamperedTransitionPackage = base.appendingPathComponent("transition-tampered-report.statelet-character", isDirectory: true)
                    try FileManager.default.copyItem(at: transitionPackage, to: tamperedTransitionPackage)
                    guard let transitionReportAsset else {
                        throw HarnessFailure.failed("missing transition report for tamper test")
                    }
                    try write(
                        Data("tampered-transition-report".utf8),
                        to: tamperedTransitionPackage.appendingPathComponent(transitionReportAsset.path)
                    )
                    try expectFailure("tampered transition report imported") {
                        _ = try storage.stageImport(
                            from: tamperedTransitionPackage,
                            against: existing,
                            allowLegacyTrust: true
                        )
                    }

                    try FileManager.default.removeItem(at: transitionReport)
                    let sourceReportlessPackage = base.appendingPathComponent("transition-source-reportless.statelet-character", isDirectory: true)
                    try expectFailure("export accepted a reportless source transition") {
                        try storage.exportCharacter(sourceEntry, to: sourceReportlessPackage)
                    }
                    try require(
                        !FileManager.default.fileExists(atPath: sourceReportlessPackage.path),
                        "reportless transition export left a package"
                    )
                    try write(Data("transition-report".utf8), to: transitionReport)

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
                    let legacyStateStage = try storage.stageImport(
                        from: reportlessPackage,
                        against: existing,
                        allowLegacyTrust: true
                    )
                    legacyStateStage.discard()
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
