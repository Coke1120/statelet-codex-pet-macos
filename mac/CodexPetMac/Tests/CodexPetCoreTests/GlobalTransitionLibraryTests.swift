import Foundation
import XCTest
@testable import CodexPetCore

final class GlobalTransitionLibraryTests: XCTestCase {
    func testNormalizesTransitionPlaybackAndRoundTripsSchema() throws {
        let key = try StateTransitionKey(from: .idle, to: .running)
        let entry = try MediaEntry(path: "transitions/start.mov", loop: true)
        let playlist = try StateMediaPlaylist(
            mode: .random,
            advanceOn: .clipEnd,
            entries: [entry]
        )
        let library = try GlobalTransitionLibrary(transitions: [key: playlist])

        let normalized = try XCTUnwrap(library.transitionPlaylist(from: .idle, to: .running))
        XCTAssertEqual(normalized.mode, .random)
        XCTAssertEqual(normalized.advanceOn, .stateEntry)
        XCTAssertFalse(normalized.fixedEntry.loop)

        let data = try JSONEncoder().encode(library)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["schema_version"] as? Int, 1)
        XCTAssertNotNil((object["transitions"] as? [String: Any])?["idle_to_running"])
        XCTAssertEqual(try JSONDecoder().decode(GlobalTransitionLibrary.self, from: data), library)
    }

    func testMutationOperationsMatchMediaMapTransitionSemantics() throws {
        let first = try MediaEntry(path: "one.mov", loop: true)
        let second = try MediaEntry(path: "two.mov", loop: true)
        var library = try GlobalTransitionLibrary()
        library = try library.settingTransition(from: .idle, to: .running, entry: first)
        library = try library.appendingTransitionEntry(second, from: .idle, to: .running)
        library = try library.changingTransitionPlaybackMode(from: .idle, to: .running, to: .sequential)
        library = try library.settingFixedTransitionEntry(from: .idle, to: .running, path: "two.mov")
        library = try library.movingTransitionEntry(from: .idle, to: .running, path: "two.mov", to: 0)

        let playlist = try XCTUnwrap(library.transitionPlaylist(from: .idle, to: .running))
        XCTAssertEqual(playlist.entries.map(\.path), ["two.mov", "one.mov"])
        XCTAssertEqual(playlist.fixedPath, "two.mov")
        XCTAssertEqual(playlist.mode, .sequential)
        XCTAssertTrue(library.allEntries.allSatisfy { !$0.loop })

        library = try library.removingTransitionEntry(from: .idle, to: .running, path: "two.mov")
        XCTAssertEqual(library.transition(from: .idle, to: .running)?.path, "one.mov")
        library = try library.removingTransition(from: .idle, to: .running)
        XCTAssertNil(library.transitionPlaylist(from: .idle, to: .running))
    }

    func testResolverPrefersCharacterThenFallsBackToGlobal() throws {
        let localEntry = try MediaEntry(path: "local.mov")
        let globalEntry = try MediaEntry(path: "global.mov")
        let local = try MediaMap().settingTransition(from: .idle, to: .running, entry: localEntry)
        let global = try GlobalTransitionLibrary()
            .settingTransition(from: .idle, to: .running, entry: globalEntry)
            .settingTransition(from: .running, to: .review, entry: globalEntry)

        let override = try XCTUnwrap(TransitionLibraryResolver.resolve(
            from: .idle, to: .running, character: local, global: global
        ))
        XCTAssertEqual(override.scope, .character)
        XCTAssertEqual(override.playlist.fixedEntry.path, "local.mov")

        let fallback = try XCTUnwrap(TransitionLibraryResolver.resolve(
            from: .running, to: .review, character: local, global: global
        ))
        XCTAssertEqual(fallback.scope, .global)
        XCTAssertEqual(fallback.playlist.fixedEntry.path, "global.mov")
        XCTAssertNil(TransitionLibraryResolver.resolve(
            from: .review, to: .waiting, character: local, global: global
        ))
    }

    func testResolvedURLUsesGlobalLibrarySiblingDirectory() throws {
        let library = try GlobalTransitionLibrary()
        let relative = try MediaEntry(
            path: "Transitions/idle-running.mov",
            posterPath: "Posters/idle-running.png"
        )
        let absolute = try MediaEntry(path: "/tmp/absolute.mov")
        let libraryURL = URL(fileURLWithPath: "/tmp/statelet/global-transitions.json")
        XCTAssertEqual(
            library.resolvedURL(for: relative, relativeTo: libraryURL).path,
            "/tmp/statelet/Transitions/idle-running.mov"
        )
        XCTAssertEqual(library.resolvedURL(for: absolute, relativeTo: libraryURL).path, "/tmp/absolute.mov")
        XCTAssertEqual(
            library.resolvedPosterURL(for: relative, relativeTo: libraryURL)?.path,
            "/tmp/statelet/Posters/idle-running.png"
        )
    }
}
