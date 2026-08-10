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
