import Foundation
import XCTest
@testable import CodexPetCore

final class ManagedMediaTrashRevalidationTests: XCTestCase {
    func testRejectsStalePlannedMapAtCapture() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let externalEdit = try MediaMap(
            states: [
                .running: try MediaEntry(path: fixture.relativeMoviePath),
                .review: try MediaEntry(path: fixture.relativeMoviePath),
            ]
        )
        try writeMap(externalEdit, to: fixture.mapURL)

        XCTAssertThrowsError(
            try ManagedMediaTrashRevalidator.capture(
                targetURLs: [fixture.movieURL, fixture.reportURL],
                plannedMediaMap: fixture.map,
                mapURL: fixture.mapURL,
                canonicalRoot: fixture.root
            )
        ) { error in
            XCTAssertEqual(
                error as? ManagedMediaTrashRevalidationError,
                .mediaMapChangedBeforePublish
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.movieURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.reportURL.path))
    }

    func testAcceptsUnreferencedUnchangedTargets() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try ManagedMediaTrashRevalidator.capture(
            targetURLs: [fixture.movieURL, fixture.reportURL],
            plannedMediaMap: fixture.map,
            mapURL: fixture.mapURL,
            canonicalRoot: fixture.root
        )

        try writeMap(
            try MediaMap(states: [PetState: StateMediaPlaylist]()),
            to: fixture.mapURL
        )

        XCTAssertEqual(
            try ManagedMediaTrashRevalidator.revalidate(
                snapshot: snapshot,
                mapURL: fixture.mapURL,
                canonicalRoot: fixture.root
            ),
            [fixture.movieURL, fixture.reportURL]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.movieURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.reportURL.path))
    }

    func testRejectsReferenceAddedBetweenMapPublishAndTrash() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try ManagedMediaTrashRevalidator.capture(
            targetURLs: [fixture.movieURL, fixture.reportURL],
            plannedMediaMap: fixture.map,
            mapURL: fixture.mapURL,
            canonicalRoot: fixture.root
        )
        try writeMap(
            try MediaMap(states: [PetState: StateMediaPlaylist]()),
            to: fixture.mapURL
        )
        let restored = try MediaMap(
            states: [.review: try MediaEntry(path: fixture.relativeMoviePath)]
        )
        try writeMap(restored, to: fixture.mapURL)

        XCTAssertThrowsError(
            try ManagedMediaTrashRevalidator.revalidate(
                snapshot: snapshot,
                mapURL: fixture.mapURL,
                canonicalRoot: fixture.root
            )
        ) { error in
            XCTAssertEqual(error as? ManagedMediaTrashRevalidationError, .stillReferenced)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.movieURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.reportURL.path))
    }

    func testRejectsExternalMapEditBeforePublish() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try ManagedMediaTrashRevalidator.capture(
            targetURLs: [fixture.movieURL, fixture.reportURL],
            plannedMediaMap: fixture.map,
            mapURL: fixture.mapURL,
            canonicalRoot: fixture.root
        )
        let externalEdit = try MediaMap(
            states: [
                .running: try MediaEntry(path: fixture.relativeMoviePath),
                .review: try MediaEntry(path: fixture.relativeMoviePath),
            ]
        )
        try writeMap(externalEdit, to: fixture.mapURL)

        XCTAssertThrowsError(
            try ManagedMediaTrashRevalidator.validateMapUnchanged(
                snapshot: snapshot,
                mapURL: fixture.mapURL,
                canonicalRoot: fixture.root
            )
        ) { error in
            XCTAssertEqual(
                error as? ManagedMediaTrashRevalidationError,
                .mediaMapChangedBeforePublish
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.movieURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.reportURL.path))
    }

    func testRejectsTargetIdentityChangedAfterCapture() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try ManagedMediaTrashRevalidator.capture(
            targetURLs: [fixture.movieURL],
            plannedMediaMap: fixture.map,
            mapURL: fixture.mapURL,
            canonicalRoot: fixture.root
        )
        try writeMap(
            try MediaMap(states: [PetState: StateMediaPlaylist]()),
            to: fixture.mapURL
        )
        try FileManager.default.removeItem(at: fixture.movieURL)
        try Data("replacement".utf8).write(to: fixture.movieURL)

        XCTAssertThrowsError(
            try ManagedMediaTrashRevalidator.revalidate(
                snapshot: snapshot,
                mapURL: fixture.mapURL,
                canonicalRoot: fixture.root
            )
        ) { error in
            XCTAssertEqual(error as? ManagedMediaTrashRevalidationError, .targetChanged)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.movieURL.path))
    }

    func testRejectsTargetModifiedInPlaceAfterCapture() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try ManagedMediaTrashRevalidator.capture(
            targetURLs: [fixture.movieURL],
            plannedMediaMap: fixture.map,
            mapURL: fixture.mapURL,
            canonicalRoot: fixture.root
        )
        try writeMap(
            try MediaMap(states: [PetState: StateMediaPlaylist]()),
            to: fixture.mapURL
        )
        try Data("movie modified in place".utf8).write(to: fixture.movieURL)

        XCTAssertThrowsError(
            try ManagedMediaTrashRevalidator.revalidate(
                snapshot: snapshot,
                mapURL: fixture.mapURL,
                canonicalRoot: fixture.root
            )
        ) { error in
            XCTAssertEqual(error as? ManagedMediaTrashRevalidationError, .targetChanged)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.movieURL.path))
    }

    func testLibrarySnapshotRejectsInactiveMapChangedAfterActivePublish() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inactiveURL = fixture.root.appendingPathComponent(".character-other.media-map.json")
        let inactive = try MediaMap(states: [PetState: StateMediaPlaylist]())
        try writeMap(inactive, to: inactiveURL)
        let snapshot = try ManagedMediaTrashRevalidator.captureLibrary(
            targetURLs: [fixture.movieURL],
            maps: [
                ManagedMediaTrashMap(url: fixture.mapURL, map: fixture.map),
                ManagedMediaTrashMap(url: inactiveURL, map: inactive),
            ],
            catalogURL: nil,
            canonicalRoot: fixture.root
        )
        let published = try MediaMap(states: [PetState: StateMediaPlaylist]())
        try writeMap(published, to: fixture.mapURL)
        try writeMap(
            try MediaMap(states: [.review: try MediaEntry(path: fixture.relativeMoviePath)]),
            to: inactiveURL
        )

        XCTAssertThrowsError(
            try ManagedMediaTrashRevalidator.quarantineLibraryAfterPublish(
                snapshot: snapshot,
                publishedMap: ManagedMediaTrashMap(url: fixture.mapURL, map: published),
                canonicalRoot: fixture.root
            )
        ) { error in
            XCTAssertEqual(error as? ManagedMediaTrashRevalidationError, .mediaMapChangedBeforePublish)
        }
    }

    func testLibrarySnapshotRejectsCatalogMutation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let catalogURL = fixture.root.appendingPathComponent("character-library.json")
        try Data("catalog-a".utf8).write(to: catalogURL)
        let snapshot = try ManagedMediaTrashRevalidator.captureLibrary(
            targetURLs: [fixture.movieURL],
            maps: [ManagedMediaTrashMap(url: fixture.mapURL, map: fixture.map)],
            catalogURL: catalogURL,
            canonicalRoot: fixture.root
        )
        try Data("catalog-b".utf8).write(to: catalogURL, options: .atomic)

        XCTAssertThrowsError(
            try ManagedMediaTrashRevalidator.validateLibraryUnchanged(
                snapshot: snapshot,
                canonicalRoot: fixture.root
            )
        ) { error in
            XCTAssertEqual(error as? ManagedMediaTrashRevalidationError, .mediaMapChangedBeforePublish)
        }
    }

    func testLibrarySnapshotRejectsCatalogCreatedAfterAbsentCapture() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let catalogURL = fixture.root.appendingPathComponent("character-library.json")
        let snapshot = try ManagedMediaTrashRevalidator.captureLibrary(
            targetURLs: [fixture.movieURL],
            maps: [ManagedMediaTrashMap(url: fixture.mapURL, map: fixture.map)],
            catalogURL: catalogURL,
            canonicalRoot: fixture.root
        )
        try Data("new catalog".utf8).write(to: catalogURL)

        XCTAssertThrowsError(
            try ManagedMediaTrashRevalidator.validateLibraryUnchanged(
                snapshot: snapshot,
                canonicalRoot: fixture.root
            )
        ) { error in
            XCTAssertEqual(error as? ManagedMediaTrashRevalidationError, .mediaMapChangedBeforePublish)
        }
    }

    func testLibrarySnapshotRejectsSymlinkedMap() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let realURL = fixture.root.appendingPathComponent("real-map.json")
        let linkURL = fixture.root.appendingPathComponent("linked-map.json")
        try writeMap(fixture.map, to: realURL)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: realURL)

        XCTAssertThrowsError(
            try ManagedMediaTrashRevalidator.captureLibrary(
                targetURLs: [fixture.movieURL],
                maps: [ManagedMediaTrashMap(url: linkURL, map: fixture.map)],
                catalogURL: nil,
                canonicalRoot: fixture.root
            )
        ) { error in
            XCTAssertEqual(error as? ManagedMediaTrashRevalidationError, .unsafeConfiguration)
        }
    }

    func testQuarantineAtomicallyStagesVerifiedTargets() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try ManagedMediaTrashRevalidator.captureLibrary(
            targetURLs: [fixture.movieURL, fixture.reportURL],
            maps: [ManagedMediaTrashMap(url: fixture.mapURL, map: fixture.map)],
            catalogURL: nil,
            canonicalRoot: fixture.root
        )
        let published = try MediaMap(states: [PetState: StateMediaPlaylist]())
        try writeMap(published, to: fixture.mapURL)

        let quarantine = try ManagedMediaTrashRevalidator.quarantineLibraryAfterPublish(
            snapshot: snapshot,
            publishedMap: ManagedMediaTrashMap(url: fixture.mapURL, map: published),
            canonicalRoot: fixture.root
        )

        XCTAssertEqual(quarantine.itemCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.movieURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.reportURL.path))
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: quarantine.directoryURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(quarantined.count, 2)
    }

    func testQuarantineRollsBackEarlierTargetsAndPreservesLaterReplacement() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let originalMovie = try Data(contentsOf: fixture.movieURL)
        let snapshot = try ManagedMediaTrashRevalidator.captureLibrary(
            targetURLs: [fixture.movieURL, fixture.reportURL],
            maps: [ManagedMediaTrashMap(url: fixture.mapURL, map: fixture.map)],
            catalogURL: nil,
            canonicalRoot: fixture.root
        )
        let published = try MediaMap(states: [PetState: StateMediaPlaylist]())
        try writeMap(published, to: fixture.mapURL)
        let replacement = Data("replacement report".utf8)
        var replacementWasCreated = false

        XCTAssertThrowsError(
            try ManagedMediaTrashRevalidator.quarantineLibraryAfterPublish(
                snapshot: snapshot,
                publishedMap: ManagedMediaTrashMap(url: fixture.mapURL, map: published),
                canonicalRoot: fixture.root,
                beforeStagingTarget: { index, _ in
                    guard index == 1 else { return }
                    try FileManager.default.removeItem(at: fixture.reportURL)
                    try replacement.write(to: fixture.reportURL)
                    replacementWasCreated = true
                }
            )
        ) { error in
            XCTAssertEqual(error as? ManagedMediaTrashRevalidationError, .targetChanged)
        }

        XCTAssertTrue(replacementWasCreated)
        XCTAssertEqual(try Data(contentsOf: fixture.movieURL), originalMovie)
        XCTAssertEqual(try Data(contentsOf: fixture.reportURL), replacement)
        let quarantineNames = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            .filter { $0.hasPrefix("Statelet Removed Media ") }
        XCTAssertTrue(quarantineNames.isEmpty)
    }

    func testQuarantineRollbackPreservesReplacementCreatedAtAlreadyStagedPath() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let originalMovie = try Data(contentsOf: fixture.movieURL)
        let snapshot = try ManagedMediaTrashRevalidator.captureLibrary(
            targetURLs: [fixture.movieURL, fixture.reportURL],
            maps: [ManagedMediaTrashMap(url: fixture.mapURL, map: fixture.map)],
            catalogURL: nil,
            canonicalRoot: fixture.root
        )
        let published = try MediaMap(states: [PetState: StateMediaPlaylist]())
        try writeMap(published, to: fixture.mapURL)
        let replacement = Data("concurrent replacement".utf8)
        var replacementWasCreated = false

        XCTAssertThrowsError(
            try ManagedMediaTrashRevalidator.quarantineLibraryAfterPublish(
                snapshot: snapshot,
                publishedMap: ManagedMediaTrashMap(url: fixture.mapURL, map: published),
                canonicalRoot: fixture.root,
                beforeStagingTarget: { index, _ in
                    guard index == 1 else { return }
                    try replacement.write(to: fixture.movieURL)
                    replacementWasCreated = true
                    try FileManager.default.removeItem(at: fixture.reportURL)
                    try Data("changed report".utf8).write(to: fixture.reportURL)
                }
            )
        )
        XCTAssertTrue(replacementWasCreated)
        XCTAssertEqual(try Data(contentsOf: fixture.movieURL), originalMovie)
        let siblingNames = try FileManager.default.contentsOfDirectory(
            atPath: fixture.movieURL.deletingLastPathComponent().path
        )
        let preserved = try XCTUnwrap(
            siblingNames.first { $0.hasPrefix("Statelet Preserved Replacement ") }
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.movieURL.deletingLastPathComponent().appendingPathComponent(preserved)),
            replacement
        )
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-pet-trash-revalidation-\(UUID().uuidString)", isDirectory: true)
        let imports = root.appendingPathComponent("imports/item", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let mapURL = root.appendingPathComponent("media-map.json")
        let movieURL = imports.appendingPathComponent("clip.mov")
        let reportURL = imports.appendingPathComponent("clip.report.json")
        try Data("movie".utf8).write(to: movieURL)
        try Data("report".utf8).write(to: reportURL)
        let relativeMoviePath = "imports/item/clip.mov"
        let map = try MediaMap(states: [.running: try MediaEntry(path: relativeMoviePath)])
        try writeMap(map, to: mapURL)
        return Fixture(
            root: root,
            mapURL: mapURL,
            movieURL: movieURL,
            reportURL: reportURL,
            relativeMoviePath: relativeMoviePath,
            map: map
        )
    }

    private func writeMap(_ map: MediaMap, to url: URL) throws {
        try JSONEncoder().encode(map).write(to: url, options: .atomic)
    }

    private struct Fixture {
        let root: URL
        let mapURL: URL
        let movieURL: URL
        let reportURL: URL
        let relativeMoviePath: String
        let map: MediaMap
    }
}
