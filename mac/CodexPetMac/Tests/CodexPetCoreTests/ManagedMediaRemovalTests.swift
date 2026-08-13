import Foundation
import XCTest
@testable import CodexPetCore

final class ManagedMediaRemovalTests: XCTestCase {
    func testPlansMovieAndSiblingReportAndRemovesLibraryEntry() throws {
        let fixture = try makeFixture(includeSecondEntry: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let plan = try ManagedMediaRemovalPlanner.plan(
            mediaMap: fixture.map,
            mapURL: fixture.mapURL,
            state: .running,
            path: fixture.relativeMoviePath,
            canonicalRoot: fixture.root
        )

        XCTAssertEqual(plan.trashURLs.map(\.lastPathComponent), ["clip.mov", "clip.report.json"])
        XCTAssertNil(plan.updatedMap.playlist(for: .running)?.entry(path: fixture.relativeMoviePath))
        XCTAssertEqual(plan.updatedMap.playlist(for: .running)?.entries.count, 1)
    }

    func testRemovingLastEntryDropsStateMapping() throws {
        let fixture = try makeFixture(includeSecondEntry: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let plan = try ManagedMediaRemovalPlanner.plan(
            mediaMap: fixture.map,
            mapURL: fixture.mapURL,
            state: .running,
            path: fixture.relativeMoviePath,
            canonicalRoot: fixture.root
        )

        XCTAssertNil(plan.updatedMap.playlist(for: .running))
    }

    func testRejectsMovieOutsideCanonicalRoot() throws {
        let fixture = try makeFixture(includeSecondEntry: false)
        let external = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).mov")
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: external)
        }
        try Data("movie".utf8).write(to: external)
        let externalEntry = try MediaEntry(path: external.path)
        let map = try MediaMap(states: [.running: externalEntry])

        XCTAssertThrowsError(
            try ManagedMediaRemovalPlanner.plan(
                mediaMap: map,
                mapURL: fixture.mapURL,
                state: .running,
                path: external.path,
                canonicalRoot: fixture.root
            )
        ) { error in
            XCTAssertEqual(error as? ManagedMediaRemovalError, .unmanagedMovie)
        }
    }

    func testRejectsSymlinkedMovie() throws {
        let fixture = try makeFixture(includeSecondEntry: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.movieURL)
        let target = fixture.root.appendingPathComponent("target.mov")
        try Data("movie".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: fixture.movieURL,
            withDestinationURL: target
        )

        XCTAssertThrowsError(
            try ManagedMediaRemovalPlanner.plan(
                mediaMap: fixture.map,
                mapURL: fixture.mapURL,
                state: .running,
                path: fixture.relativeMoviePath,
                canonicalRoot: fixture.root
            )
        ) { error in
            XCTAssertEqual(error as? ManagedMediaRemovalError, .unsafeTarget)
        }
    }

    func testRejectsDanglingSiblingReportSymlink() throws {
        let fixture = try makeFixture(includeSecondEntry: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reportURL = fixture.movieURL.deletingPathExtension().appendingPathExtension("report.json")
        try FileManager.default.removeItem(at: reportURL)
        let missingTarget = fixture.root.appendingPathComponent("missing-report.json")
        try FileManager.default.createSymbolicLink(
            at: reportURL,
            withDestinationURL: missingTarget
        )

        XCTAssertThrowsError(
            try ManagedMediaRemovalPlanner.plan(
                mediaMap: fixture.map,
                mapURL: fixture.mapURL,
                state: .running,
                path: fixture.relativeMoviePath,
                canonicalRoot: fixture.root
            )
        ) { error in
            XCTAssertEqual(error as? ManagedMediaRemovalError, .unsafeTarget)
        }
    }

    func testRejectsMovieStillReferencedByAnotherState() throws {
        let fixture = try makeFixture(includeSecondEntry: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let entry = try MediaEntry(path: fixture.relativeMoviePath)
        let map = try MediaMap(states: [.running: entry, .review: entry])

        XCTAssertThrowsError(
            try ManagedMediaRemovalPlanner.plan(
                mediaMap: map,
                mapURL: fixture.mapURL,
                state: .running,
                path: fixture.relativeMoviePath,
                canonicalRoot: fixture.root
            )
        ) { error in
            XCTAssertEqual(error as? ManagedMediaRemovalError, .stillReferenced)
        }
    }

    func testRejectsMovieStillReferencedByTransition() throws {
        let fixture = try makeFixture(includeSecondEntry: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transition = try MediaEntry(path: fixture.relativeMoviePath, loop: false)
        let map = try fixture.map.settingTransition(from: .idle, to: .running, entry: transition)

        XCTAssertThrowsError(
            try ManagedMediaRemovalPlanner.plan(
                mediaMap: map,
                mapURL: fixture.mapURL,
                state: .running,
                path: fixture.relativeMoviePath,
                canonicalRoot: fixture.root
            )
        ) { error in
            XCTAssertEqual(error as? ManagedMediaRemovalError, .stillReferenced)
        }
    }

    func testPlansTransitionRemovalWithoutChangingStatePlaylist() throws {
        let fixture = try makeFixture(includeSecondEntry: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transitionMap = try MediaMap().settingTransition(
            from: .idle,
            to: .running,
            entry: try MediaEntry(path: fixture.relativeMoviePath, loop: false)
        )

        let plan = try ManagedMediaRemovalPlanner.plan(
            mediaMap: transitionMap,
            mapURL: fixture.mapURL,
            transitionFrom: .idle,
            transitionTo: .running,
            canonicalRoot: fixture.root
        )

        XCTAssertNil(plan.updatedMap.transition(from: .idle, to: .running))
        XCTAssertTrue(plan.updatedMap.states.isEmpty)
        XCTAssertEqual(plan.trashURLs.map(\.lastPathComponent), ["clip.mov", "clip.report.json"])
    }

    func testPlansOneTransitionVariantRemovalAndRetainsRoute() throws {
        let fixture = try makeFixture(includeSecondEntry: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let retainedURL = fixture.root.appendingPathComponent("imports/item/retained.mov")
        try Data("retained".utf8).write(to: retainedURL)
        let map = try MediaMap()
            .settingTransition(
                from: .idle,
                to: .running,
                entry: try MediaEntry(path: fixture.relativeMoviePath, loop: false)
            )
            .appendingTransitionEntry(
                try MediaEntry(path: "imports/item/retained.mov", loop: false),
                from: .idle,
                to: .running
            )

        let plan = try ManagedMediaRemovalPlanner.plan(
            mediaMap: map,
            mapURL: fixture.mapURL,
            transitionFrom: .idle,
            transitionTo: .running,
            path: fixture.relativeMoviePath,
            canonicalRoot: fixture.root
        )

        XCTAssertEqual(plan.updatedMap.transitionEntries(from: .idle, to: .running).map(\.path), ["imports/item/retained.mov"])
        XCTAssertEqual(plan.trashURLs.map(\.lastPathComponent), ["clip.mov", "clip.report.json"])
    }

    func testPlansTransitionRemovalForNonDefaultCharacterMap() throws {
        let fixture = try makeFixture(includeSecondEntry: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let characterMapURL = fixture.root.appendingPathComponent(
            ".character-chloe.media-map.json"
        )
        try FileManager.default.moveItem(at: fixture.mapURL, to: characterMapURL)
        let transitionMap = try MediaMap().settingTransition(
            from: .idle,
            to: .running,
            entry: try MediaEntry(path: fixture.relativeMoviePath, loop: false)
        )

        let plan = try ManagedMediaRemovalPlanner.plan(
            mediaMap: transitionMap,
            mapURL: characterMapURL,
            transitionFrom: .idle,
            transitionTo: .running,
            canonicalRoot: fixture.root
        )

        XCTAssertNil(plan.updatedMap.transition(from: .idle, to: .running))
        XCTAssertEqual(plan.trashURLs.map(\.lastPathComponent), ["clip.mov", "clip.report.json"])
    }

    func testAcceptsUppercaseMOVExtension() throws {
        let fixture = try makeFixture(includeSecondEntry: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let uppercaseURL = fixture.movieURL.deletingPathExtension().appendingPathExtension("MOV")
        try FileManager.default.moveItem(at: fixture.movieURL, to: uppercaseURL)
        let uppercasePath = "imports/item/clip.MOV"
        let map = try MediaMap(states: [.running: try MediaEntry(path: uppercasePath)])

        let plan = try ManagedMediaRemovalPlanner.plan(
            mediaMap: map,
            mapURL: fixture.mapURL,
            state: .running,
            path: uppercasePath,
            canonicalRoot: fixture.root
        )

        XCTAssertEqual(plan.trashURLs.map(\.lastPathComponent), ["clip.MOV", "clip.report.json"])
    }

    func testRejectsConfiguredMediaMapAsTrashTarget() throws {
        let fixture = try makeFixture(includeSecondEntry: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try assertUnsafeTarget(path: "media-map.json", fixture: fixture)
    }

    func testRejectsReportJSONPosterAndOtherNonMovieTargets() throws {
        let fixture = try makeFixture(includeSecondEntry: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let unsafePaths = [
            "imports/item/clip.report.json",
            "imports/item/clip.json",
            "imports/item/clip.poster.png",
            "imports/item/clip.mp4",
            "imports/item/clip.txt",
        ]
        for path in unsafePaths {
            let url = fixture.root.appendingPathComponent(path)
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data("reserved".utf8).write(to: url)
            }
            try assertUnsafeTarget(path: path, fixture: fixture)
        }
    }

    private func assertUnsafeTarget(path: String, fixture: Fixture) throws {
        let map = try MediaMap(states: [.running: try MediaEntry(path: path)])
        XCTAssertThrowsError(
            try ManagedMediaRemovalPlanner.plan(
                mediaMap: map,
                mapURL: fixture.mapURL,
                state: .running,
                path: path,
                canonicalRoot: fixture.root
            ),
            "Expected \(path) to be rejected"
        ) { error in
            XCTAssertEqual(error as? ManagedMediaRemovalError, .unsafeTarget)
        }
    }

    private func makeFixture(includeSecondEntry: Bool) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-pet-managed-removal-\(UUID().uuidString)", isDirectory: true)
        let imports = root.appendingPathComponent("imports/item", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let mapURL = root.appendingPathComponent("media-map.json")
        try Data("{}".utf8).write(to: mapURL)
        let movieURL = imports.appendingPathComponent("clip.mov")
        let reportURL = imports.appendingPathComponent("clip.report.json")
        try Data("movie".utf8).write(to: movieURL)
        try Data("report".utf8).write(to: reportURL)
        let relativeMoviePath = "imports/item/clip.mov"
        var entries = [try MediaEntry(path: relativeMoviePath)]
        if includeSecondEntry {
            let secondURL = imports.appendingPathComponent("second.mov")
            try Data("movie-2".utf8).write(to: secondURL)
            entries.append(try MediaEntry(path: "imports/item/second.mov"))
        }
        let playlist = try StateMediaPlaylist(mode: .sequential, entries: entries)
        let map = try MediaMap(states: [.running: playlist])
        return Fixture(
            root: root,
            mapURL: mapURL,
            movieURL: movieURL,
            relativeMoviePath: relativeMoviePath,
            map: map
        )
    }

    private struct Fixture {
        let root: URL
        let mapURL: URL
        let movieURL: URL
        let relativeMoviePath: String
        let map: MediaMap
    }
}
