import CoreGraphics
import Foundation
import XCTest
@testable import CodexPetCore

private let reportSourceHash = String(repeating: "a", count: 64)
private let reportOutputHash = String(repeating: "b", count: 64)
private let reportProvenanceChallenge = String(repeating: "c", count: 64)

private func validAlphaReportJSON() -> String {
    """
    {
      "report_schema_version":1,
      "status":"converted",
      "toolchain":{"converter_version":"1","ffmpeg_version":"ffmpeg version 8.0","ffprobe_version":"ffprobe version 8.0","avconvert_version":"avconvert help","macos_build":"23G93"},
      "tool_capabilities":{"ffmpeg_encoder":"prores_ks","ffmpeg_filters":["scale","crop","pad"],"avconvert_presets":["PresetHEVCHighestQualityWithAlpha","PresetAppleProRes4444LPCM"],"passed":true},
      "profile":{"name":"standard","framing":"fill","keying":"green-screen-continuous-alpha"},
      "normalization":{"applied":["strip-audio","square-pixel-output"],"warnings":["rotation-sar-vfr-hdr-interlace-rejected-before-decode"]},
      "provenance":{"method":"invocation-challenge-v1","producer":"statelet","challenge":"\(reportProvenanceChallenge)"},
      "source":{"audio":{"stream_count":1,"codecs":["aac"],"policy":"stripped"}},
      "geometry":{"width":320,"height":486,"pixel_format":"straight-rgba"},
      "geometry_alignment":{"requested_width":321,"requested_height":487,"policy":"floor_to_even","adjusted":true},
      "quality":{"loop_seam":{"performed":true,"exact_match":false,"differing_pixels":120,"mean_absolute_error":0.5,"maximum_absolute_error":12,"policy":"informational"}},
      "codec":{"delivery":"HEVC with alpha"},
      "verification":{
        "performed":true,"unsafe":false,"frames_verified":241,"maximum_outer_edge_alpha":1,
        "delivery":{"codec":"hevc","profile":"Main","width":320,"height":486,"frames":241,"fps":"24/1","quality_passed":true},
        "roundtrip":{"codec":"prores","profile":"4444","width":320,"height":486,"frames":241,"fps":"24/1","quality_passed":true},
        "alpha":{"mean_absolute_error_max":0.2,"p95_absolute_error_max":1.0,"maximum_absolute_error_max":20,"lost_alpha_pixels_total":0,"tolerances":{"max_border_alpha":8,"max_mean_abs_error":8.0,"max_p95_abs_error":24.0,"max_abs_error":64}},
        "composite":{"performed":true,"background_names":["white","black","checkerboard"],"frames_checked":241,"maximum_introduced_green_fringe_ratio":0.001,"maximum_introduced_magenta_fringe_ratio":0.002,"maximum_introduced_green_fringe_excess":2,"maximum_introduced_magenta_fringe_excess":3,"reference_comparison":true,"quality_passed":true,"limits":{"max_introduced_green_fringe_ratio":0.01,"max_introduced_magenta_fringe_ratio":0.01,"max_introduced_green_fringe_excess":16,"max_introduced_magenta_fringe_excess":16}}
      },
      "artifacts":{"source_sha256":"\(reportSourceHash)","source_sha256_before_probe":"\(reportSourceHash)","source_sha256_before_publication":"\(reportSourceHash)","output_name":"idle.mov","output_sha256":"\(reportOutputHash)"}
    }
    """
}

final class CodexPetCoreTests: XCTestCase {
    func testInStateTransitionRoundTripIsIndependentAndOneShot() throws {
        let transition = try MediaEntry(path: "media/idle-handoff.mov", loop: true)
        let map = try MediaMap(
            states: [.idle: try MediaEntry(path: "media/idle.mov")],
            inStateTransitions: [.idle: transition]
        )

        XCTAssertFalse(try XCTUnwrap(map.inStateTransition(for: .idle)).loop)
        XCTAssertNil(map.transitionPlaylist(from: .idle, to: .idle))
        XCTAssertEqual(try JSONDecoder().decode(MediaMap.self, from: JSONEncoder().encode(map)), map)
        XCTAssertNil(try map.removingInStateTransition(for: .idle).inStateTransition(for: .idle))
    }

    func testLayeredLifecycleHandoffKeepsAVisibleThenPrerollsBUnderTransition() {
        var handoff = LayeredLifecycleHandoff(id: 7, source: .idle, destination: .running)
        XCTAssertEqual(handoff.lowerLayer, .outgoing(.idle))
        XCTAssertTrue(handoff.preservesVisibleContent)
        XCTAssertFalse(handoff.transitionVisible)

        XCTAssertEqual(handoff.transitionBecameReady(id: 7), .revealTransition)
        XCTAssertTrue(handoff.transitionVisible)
        XCTAssertEqual(handoff.lowerLayer, .outgoing(.idle))
        XCTAssertEqual(handoff.visibleLayers, [.outgoing(.idle), .transitionForeground])

        XCTAssertEqual(handoff.destinationBecameReady(id: 7), .none)
        XCTAssertEqual(handoff.destinationPrerollCueReached(id: 7), .startDestinationPreroll(.running))
        XCTAssertEqual(handoff.destinationBecameReady(id: 7), .none)
        XCTAssertEqual(handoff.lowerLayer, .outgoing(.idle))
        XCTAssertTrue(handoff.transitionVisible)
        XCTAssertTrue(handoff.destinationPrerollStarted)
        XCTAssertEqual(handoff.visibleLayers, [.outgoing(.idle), .transitionForeground])

        XCTAssertEqual(handoff.transitionFinished(id: 7), .finish(.running))
        XCTAssertFalse(handoff.transitionVisible)
        XCTAssertEqual(handoff.lowerLayer, .destination(.running))
        XCTAssertTrue(handoff.preservesVisibleContent)
    }

    func testLayeredLifecycleHandoffRejectsStaleCallbacksAndKeepsFallbackVisible() {
        var handoff = LayeredLifecycleHandoff(id: 12, source: .running, destination: .review)
        XCTAssertEqual(handoff.transitionBecameReady(id: 11), .none)
        XCTAssertEqual(handoff.destinationPrerollCueReached(id: 11), .none)
        XCTAssertEqual(handoff.destinationBecameReady(id: 11), .none)
        XCTAssertEqual(handoff.transitionFinished(id: 11), .none)
        XCTAssertEqual(handoff.lowerLayer, .outgoing(.running))

        XCTAssertEqual(handoff.transitionBecameReady(id: 12), .revealTransition)
        XCTAssertEqual(handoff.destinationPrerollCueReached(id: 12), .startDestinationPreroll(.review))
        XCTAssertEqual(handoff.destinationFailed(id: 12), .none)
        XCTAssertEqual(handoff.lowerLayer, .outgoing(.running))
        XCTAssertEqual(handoff.transitionFailed(id: 12), .fallBack(.review))
        XCTAssertFalse(handoff.transitionVisible)
        XCTAssertTrue(handoff.preservesVisibleContent)
    }

    func testLayeredSameStateHandoffPrerollsAndFallsBackWithoutClearingVisibleLayer() {
        var handoff = LayeredLifecycleHandoff(id: 41, source: .running, destination: .running)
        XCTAssertEqual(handoff.lowerLayer, .outgoing(.running))
        XCTAssertEqual(handoff.transitionBecameReady(id: 41), .revealTransition)
        XCTAssertEqual(handoff.destinationPrerollCueReached(id: 41), .startDestinationPreroll(.running))
        XCTAssertEqual(handoff.destinationBecameReady(id: 41), .none)
        XCTAssertEqual(handoff.lowerLayer, .outgoing(.running))
        XCTAssertEqual(handoff.visibleLayers, [.outgoing(.running), .transitionForeground])
        XCTAssertEqual(handoff.transitionFinished(id: 41), .finish(.running))

        var failed = LayeredLifecycleHandoff(id: 42, source: .running, destination: .running)
        XCTAssertEqual(failed.transitionBecameReady(id: 42), .revealTransition)
        XCTAssertEqual(failed.destinationPrerollCueReached(id: 42), .startDestinationPreroll(.running))
        XCTAssertEqual(failed.transitionFailed(id: 42), .fallBack(.running))
        XCTAssertEqual(failed.lowerLayer, .outgoing(.running))
        XCTAssertTrue(failed.preservesVisibleContent)
        XCTAssertEqual(failed.destinationBecameReady(id: 41), .none)
    }

    func testLayeredHandoffKeepsForegroundUntilLateDestinationBecomesVisible() {
        var handoff = LayeredLifecycleHandoff(id: 43, source: .running, destination: .running)
        XCTAssertEqual(handoff.transitionBecameReady(id: 43), .revealTransition)
        XCTAssertEqual(handoff.destinationPrerollCueReached(id: 43), .startDestinationPreroll(.running))
        XCTAssertEqual(handoff.transitionFinished(id: 43), .none)
        XCTAssertTrue(handoff.transitionVisible)
        XCTAssertEqual(handoff.destinationBecameReady(id: 43), .finish(.running))
        XCTAssertFalse(handoff.transitionVisible)
        XCTAssertTrue(handoff.preservesVisibleContent)
    }

    func testLayeredHandoffPromotesReadyDestinationWhenTransitionFails() {
        var handoff = LayeredLifecycleHandoff(id: 44, source: .idle, destination: .review)
        XCTAssertEqual(handoff.transitionBecameReady(id: 44), .revealTransition)
        XCTAssertEqual(handoff.destinationPrerollCueReached(id: 44), .startDestinationPreroll(.review))
        XCTAssertEqual(handoff.destinationBecameReady(id: 44), .none)
        XCTAssertEqual(handoff.lowerLayer, .outgoing(.idle))

        XCTAssertEqual(handoff.transitionFailed(id: 44), .finish(.review))
        XCTAssertEqual(handoff.lowerLayer, .destination(.review))
        XCTAssertEqual(handoff.visibleLayers, [.destination(.review)])
        XCTAssertTrue(handoff.preservesVisibleContent)
    }

    func testSameStateFallbackReusesSelectedPlaylistEntryWithoutDoubleAdvancingCursor() throws {
        let first = try MediaEntry(path: "running-first.mov")
        let second = try MediaEntry(path: "running-second.mov")
        let playlist = try StateMediaPlaylist(mode: .sequential, entries: [first, second])
        var cursor = MediaSelectionCursor()

        XCTAssertEqual(cursor.select(for: .running, from: playlist)?.path, first.path)
        let selectedDestination = cursor.select(for: .running, from: playlist)?.path
        XCTAssertEqual(selectedDestination, second.path)
        XCTAssertEqual(
            cursor.select(for: .running, from: playlist, advance: false)?.path,
            selectedDestination
        )
        XCTAssertEqual(cursor.select(for: .running, from: playlist)?.path, first.path)
    }

    func testMediaSelectionRequestCancellationAndDirectFailureDoNotSkipAndSuccessCommitsOnce() throws {
        let first = try MediaEntry(path: "running-first.mov")
        let second = try MediaEntry(path: "running-second.mov")
        let playlist = try StateMediaPlaylist(mode: .sequential, entries: [first, second])
        var cursor = MediaSelectionCursor(selectedPaths: [.running: first.path])

        let cancelled = try XCTUnwrap(cursor.request(for: .running, from: playlist))
        XCTAssertEqual(cancelled.entry, second)
        XCTAssertEqual(cursor.selectedPath(for: .running), first.path)

        let directFailure = try XCTUnwrap(cursor.request(for: .running, from: playlist))
        XCTAssertEqual(directFailure.entry, second)
        XCTAssertEqual(cursor.selectedPath(for: .running), first.path)

        var accepted = try XCTUnwrap(cursor.request(for: .running, from: playlist))
        XCTAssertEqual(accepted.entry, second)
        XCTAssertTrue(accepted.commit(to: &cursor))
        XCTAssertFalse(accepted.commit(to: &cursor))
        XCTAssertEqual(cursor.selectedPath(for: .running), second.path)
        XCTAssertEqual(cursor.request(for: .running, from: playlist)?.entry, first)
    }

    func testMediaSelectionRequestAttestationAndBindingFallbackCommitOnlyWhenAccepted() throws {
        let first = try MediaEntry(path: "running-first.mov")
        let second = try MediaEntry(path: "running-second.mov")
        let playlist = try StateMediaPlaylist(mode: .sequential, entries: [first, second])
        var cursor = MediaSelectionCursor(selectedPaths: [.running: first.path])

        let attestationFailure = try XCTUnwrap(cursor.request(for: .running, from: playlist))
        XCTAssertEqual(attestationFailure.entry, second)
        XCTAssertEqual(cursor.selectedPath(for: .running), first.path)

        let bindingFailure = try XCTUnwrap(cursor.request(for: .running, from: playlist))
        XCTAssertEqual(bindingFailure.entry, second)
        XCTAssertEqual(cursor.selectedPath(for: .running), first.path)

        var acceptedFallback = try XCTUnwrap(cursor.request(for: .running, from: playlist))
        XCTAssertTrue(acceptedFallback.commit(to: &cursor))
        XCTAssertFalse(acceptedFallback.commit(to: &cursor))
        XCTAssertEqual(cursor.selectedPath(for: .running), second.path)
    }

    func testLayeredLifecycleHandoffUsesDeterministicBoundedOverlap() {
        XCTAssertEqual(LayeredLifecycleHandoffPolicy.destinationPrerollTime(duration: 1.5), 1.15, accuracy: 0.0001)
        XCTAssertEqual(LayeredLifecycleHandoffPolicy.destinationPrerollTime(duration: 0.2), 0.1, accuracy: 0.0001)
        XCTAssertEqual(LayeredLifecycleHandoffPolicy.destinationPrerollTime(duration: 0), 0)
    }

    func testSameStateLifecycleTimelineFitsActualPresentationAndNeverOverlapsStates() {
        for duration in [0.6, 1.0, 1.5, 4.0] {
            let timeline = LayeredLifecycleHandoffPolicy.sameStateTimeline(
                presentationDuration: duration
            )
            XCTAssertLessThanOrEqual(
                timeline.presentationDuration,
                LifecycleTransitionMediaPolicy.maximumPresentationDuration
            )
            XCTAssertEqual(
                timeline.incomingFadeStartTime + timeline.incomingFadeDuration,
                timeline.presentationDuration,
                accuracy: 0.0001
            )
            for step in 0...120 {
                let time = timeline.presentationDuration * Double(step) / 120
                let opacities = timeline.opacities(at: time)
                XCTAssertFalse(
                    opacities.outgoing > 0.0001 && opacities.destination > 0.0001,
                    "state layers overlap at \(time)s for \(duration)s timeline"
                )
            }
        }
        let normal = LayeredLifecycleHandoffPolicy.sameStateTimeline(
            presentationDuration: 1.5
        )
        XCTAssertEqual(normal.outgoingFadeDuration, 0.5, accuracy: 0.0001)
        XCTAssertEqual(normal.incomingFadeStartTime, 1.0, accuracy: 0.0001)
        XCTAssertEqual(normal.incomingFadeDuration, 0.5, accuracy: 0.0001)
        XCTAssertEqual(LayeredLifecycleHandoffPolicy.sameStatePreparationLeadTime, 3.0)
    }

    func testAlphaConversionProgressParserAcceptsMonotonicPathSafeJSONL() throws {
        var parser = AlphaConversionProgressParser()
        let first = try XCTUnwrap(parser.parseLine(
            #"{"event":"progress","percent":12.5,"stage":"decode","message":"Reading /Users/person/private/source.mp4","completed_frames":3,"total_frames":24}"#
        ))
        XCTAssertEqual(first.event, "progress")
        XCTAssertEqual(first.percent, 12.5)
        XCTAssertEqual(first.stage, "decode")
        XCTAssertEqual(first.message, "Reading <local-file>")
        XCTAssertEqual(first.completedFrames, 3)
        XCTAssertEqual(first.totalFrames, 24)

        let second = try XCTUnwrap(parser.parseLine(
            #"{"event":"progress","percent":12.5,"stage":"decode","message":"Frame 3/24"}"#
        ))
        XCTAssertEqual(second.percent, first.percent)
        XCTAssertEqual(second.message, "Frame 3/24")
    }

    func testAlphaConversionProgressParserIgnoresNoiseAndFinalJSON() throws {
        var parser = AlphaConversionProgressParser()
        XCTAssertNil(try parser.parseLine("ffmpeg diagnostic output"))
        XCTAssertNil(try parser.parseLine(#"{"status":"converted","output":"idle.mov"}"#))
        XCTAssertNil(try parser.parseLine(#"{"event":"complete","percent":100}"#))
    }

    func testAlphaConversionProgressParserRejectsInvalidAndRegressingProgress() throws {
        XCTAssertThrowsError(try AlphaConversionProgress(percent: .infinity, stage: "encode", message: "Encoding"))
        XCTAssertThrowsError(try AlphaConversionProgress(percent: .nan, stage: "encode", message: "Encoding"))
        for line in [
            #"{"event":"progress","percent":-1,"stage":"decode","message":"Starting"}"#,
            #"{"event":"progress","percent":101,"stage":"decode","message":"Starting"}"#,
            #"{"event":"progress","percent":10,"stage":"","message":"Starting"}"#,
            #"{"event":"progress","percent":10,"stage":"decode","message":"Starting","completed_frames":3}"#,
            #"{"event":"progress","percent":10,"stage":"decode","message":"Starting","completed_frames":4,"total_frames":3}"#,
        ] {
            var parser = AlphaConversionProgressParser()
            XCTAssertThrowsError(try parser.parseLine(line), "accepted \(line)")
        }

        var parser = AlphaConversionProgressParser()
        _ = try parser.parseLine(#"{"event":"progress","percent":60,"stage":"encode","message":"Encoding"}"#)
        XCTAssertThrowsError(try parser.parseLine(
            #"{"event":"progress","percent":59.9,"stage":"encode","message":"Encoding"}"#
        ))
        XCTAssertEqual(
            try parser.parseLine(#"{"event":"progress","percent":61,"stage":"encode","message":"Encoding"}"#)?.percent,
            61
        )
    }

    func testAlphaConversionProgressParserRejectsMalformedProgressButIgnoresMalformedNoise() throws {
        var parser = AlphaConversionProgressParser()
        XCTAssertNil(try parser.parseLine(#"{not converter JSON"#))
        XCTAssertThrowsError(try parser.parseLine(
            #"{"event":"progress","percent":25,"stage":"decode","message":"Reading frames""#
        )) { error in
            XCTAssertEqual(error as? AlphaConversionProgressError, .malformedProgressEvent)
        }
    }

    func testAlphaConversionProgressParserAcceptsSafeTerminalFailure() throws {
        var parser = AlphaConversionProgressParser()
        let failure = try XCTUnwrap(parser.parseLine(
            #"{"event":"progress","status":"failed","percent":42,"stage":"verify","message":"Failed /Users/leoho/My Videos/foo.mp4","code":"QUALITY_GATE_FAILED","safe_message":"Failed '/Users/leoho/My Videos/foo.mp4'"}"#
        ))
        XCTAssertTrue(failure.isTerminalFailure)
        XCTAssertEqual(failure.code, "QUALITY_GATE_FAILED")
        XCTAssertEqual(failure.stage, "verify")
        XCTAssertEqual(failure.message, "Failed <local-file>")
        XCTAssertEqual(failure.safeMessage, "Failed '<local-file>'")
    }

    func testAlphaConversionProgressParserRejectsMalformedTerminalFailureFields() throws {
        for line in [
            #"{"event":"progress","status":"failed","percent":42,"stage":"verify","message":"Failed","code":"UNKNOWN","safe_message":"Failed"}"#,
            #"{"event":"progress","status":"failed","percent":42,"stage":"/Users/private","message":"Failed","code":"CONVERSION_FAILED","safe_message":"Failed"}"#,
            #"{"event":"progress","status":"failed","percent":42,"stage":"verify","message":"Failed","code":"CONVERSION_FAILED"}"#,
            #"{"event":"progress","status":"running","percent":42,"stage":"verify","message":"Working","code":"CONVERSION_FAILED","safe_message":"Failed"}"#,
            #"{"event":"progress","status":"failed","percent":42,"stage":"verify","message":"Failed","code":"CONVERSION_FAILED","safe_message":"/Users/private/source.mp4 \#(String(repeating: "x", count: 257))"}"#,
        ] {
            var parser = AlphaConversionProgressParser()
            XCTAssertThrowsError(try parser.parseLine(line), "accepted \(line)")
        }
    }

    func testAlphaConversionProgressRedactsPathsAfterAdversarialDelimiters() throws {
        for (message, expected) in [
            ("source=/Users/person/private/source.mp4", "source=<local-file>"),
            (#"reading ("/Users/person/private/source.mp4")"#, #"reading ("<local-file>")"#),
            (#"reading 'file:///Users/person/private/source.mp4'"#, #"reading '<local-file>'"#),
            ("source=/secret.mov", "source=<local-file>"),
            ("source=~/secret.mov", "source=<local-file>"),
            (#"reading "file:///secret.mov""#, #"reading "<local-file>""#),
            ("reading /Users/leoho/My Videos/foo.mp4", "reading <local-file>"),
            (#"reading '/Users/leoho/My Videos/foo.mp4'"#, #"reading '<local-file>'"#),
            ("reading /Users/leoho/My Folder/tool", "reading <local-file>"),
            (#"reading '/Users/leoho/My Folder/tool'"#, #"reading '<local-file>'"#),
            ("Frame 3/24", "Frame 3/24"),
        ] {
            let progress = try AlphaConversionProgress(percent: 10, stage: "decode", message: message)
            XCTAssertEqual(progress.message, expected)
        }
    }

    func testSharedCanonicalProducerFixtureDecodes() throws {
        let macDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureURL = macDirectory.appendingPathComponent("contracts/current_state-v1.example.json")
        let decoded = try JSONDecoder.codexPet.decode(CurrentState.self, from: Data(contentsOf: fixtureURL))
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.state, .running)
        XCTAssertEqual(decoded.sourceUpdatedAt, 1710000000.0)
        XCTAssertEqual(decoded.activeSessions, 2)
        XCTAssertTrue(decoded.emittedAt.isFinite)
    }

    func testCurrentStateDecodesEveryStateWithoutPriorityCoupling() throws {
        for (index, state) in PetState.allCases.enumerated() {
            let json = """
            {"version":1,"schema_version":1,"state":"\(state.rawValue)","priority":\(index),"active_sessions":1,"source_updated_at":1710000000.5,"emitted_at":1710000000.6,"forced":false}
            """.data(using: .utf8)!
            let decoded = try JSONDecoder.codexPet.decode(CurrentState.self, from: json)
            XCTAssertEqual(decoded.state, state)
            XCTAssertEqual(decoded.priority, index)
            XCTAssertEqual(decoded.sourceUpdatedAt, 1710000000.5)
            XCTAssertEqual(decoded.emittedAt, 1710000000.6)
        }
    }

    func testCurrentStateRejectsUnknownStateAndNegativeSessionCount() throws {
        let unknown = #"{"version":1,"schema_version":1,"state":"paused","updated_at":1}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder.codexPet.decode(CurrentState.self, from: unknown))

        let negative = #"{"version":1,"schema_version":1,"state":"idle","active_sessions":-1,"updated_at":1}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder.codexPet.decode(CurrentState.self, from: negative))
    }

    func testPythonProducerIdleSnapshotDecodesNullSourceTimestamp() throws {
        let json = #"{"active_sessions":0,"emitted_at":1710000000.25,"forced":false,"priority":0,"schema_version":1,"source":"aggregate","source_updated_at":null,"state":"idle","updated_at":1710000000.25,"version":1}"#.data(using: .utf8)!
        let decoded = try JSONDecoder.codexPet.decode(CurrentState.self, from: json)
        XCTAssertEqual(decoded.state, .idle)
        XCTAssertNil(decoded.sourceUpdatedAt)
        XCTAssertEqual(decoded.emittedAt, 1710000000.25)
        XCTAssertEqual(decoded.updatedAt, 1710000000.25)
    }

    func testCurrentStateRequiresFinitePublicationTimestamp() throws {
        let missing = #"{"version":1,"schema_version":1,"state":"idle","source_updated_at":null}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder.codexPet.decode(CurrentState.self, from: missing))
        XCTAssertThrowsError(try CurrentState(state: .idle))
        XCTAssertThrowsError(try CurrentState(state: .idle, updatedAt: .infinity))
        XCTAssertThrowsError(try CurrentState(state: .idle, emittedAt: .nan))
        XCTAssertThrowsError(try CurrentState(state: .running, sourceUpdatedAt: .nan, emittedAt: 1))

        let legacy = #"{"version":1,"state":"running","updated_at":1710000001}"#.data(using: .utf8)!
        let decoded = try JSONDecoder.codexPet.decode(CurrentState.self, from: legacy)
        XCTAssertEqual(decoded.emittedAt, 1710000001)
        XCTAssertEqual(decoded.updatedAt, 1710000001)
        XCTAssertNil(decoded.sourceUpdatedAt)
    }

    func testSessionActivitySnapshotDecodesBoundedActiveAndCompletedGroups() throws {
        let json = """
        {
          "version": 1,
          "schema_version": 1,
          "emitted_at": 1710000000.5,
          "active": [
            {"id":"aaaaaaaaaaaaaaaaaaaaaaaa","state":"running","event":"UserPromptSubmit","event_at":1710000000.0,"terminal":false}
          ],
          "completed": [
            {"id":"bbbbbbbbbbbbbbbbbbbbbbbb","state":"idle","event":"SessionEnd","event_at":1709999999.0,"terminal":true}
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder.codexPet.decode(SessionActivitySnapshot.self, from: json)
        XCTAssertEqual(decoded.active.count, 1)
        XCTAssertEqual(decoded.active[0].state, .running)
        XCTAssertEqual(decoded.active[0].provider, .codex)
        XCTAssertEqual(decoded.completed.count, 1)
        XCTAssertTrue(decoded.completed[0].terminal)
    }

    func testSessionActivityDecodesExplicitGrokProviderAndAgentSourceModes() throws {
        let json = #"{"version":1,"schema_version":1,"emitted_at":20,"active":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","state":"running","event":"UserPromptSubmit","event_at":10,"provider":"grok","terminal":false}],"completed":[]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder.codexPet.decode(SessionActivitySnapshot.self, from: json)
        XCTAssertEqual(decoded.active.first?.provider, .grok)
        XCTAssertEqual(AgentProvider.grok.displayName, "Grok")
        XCTAssertEqual(AgentSourceMode.allCases, [.combined, .codex, .grok])
    }

    func testSessionActivityDecodesRunningNonterminalGrokStopForBackgroundTasksOnly() throws {
        let projected = #"{"version":1,"schema_version":1,"emitted_at":20,"active":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","state":"running","event":"Stop","event_at":10,"started_at":9,"category":"codex","provider":"grok","terminal":false}],"completed":[]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder.codexPet.decode(SessionActivitySnapshot.self, from: projected)
        XCTAssertEqual(decoded.active.first?.provider, .grok)
        XCTAssertEqual(decoded.active.first?.event, .stop)
        XCTAssertEqual(decoded.active.first?.state, .running)
        XCTAssertEqual(decoded.active.first?.terminal, false)

        let invalidItems = [
            #"{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","state":"running","event":"Stop","event_at":10,"category":"codex","provider":"codex","terminal":false}"#,
            #"{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","state":"review","event":"Stop","event_at":10,"category":"codex","provider":"grok","terminal":false}"#,
            #"{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","state":"waiting","event":"Stop","event_at":10,"category":"codex","provider":"grok","terminal":false}"#,
            #"{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","state":"running","event":"SessionEnd","event_at":10,"category":"codex","provider":"grok","terminal":false}"#,
        ]
        for item in invalidItems {
            let json = "{\"version\":1,\"schema_version\":1,\"emitted_at\":20,\"active\":[\(item)],\"completed\":[]}".data(using: .utf8)!
            XCTAssertThrowsError(
                try JSONDecoder.codexPet.decode(SessionActivitySnapshot.self, from: json),
                item
            )
        }
    }

    func testSessionActivitySnapshotRejectsInvalidIdentifiersDuplicatesAndGroups() throws {
        let invalidID = try? SessionActivityItem(
            id: "not-a-session-id",
            state: .running,
            event: .userPromptSubmit,
            eventAt: 1,
            terminal: false
        )
        XCTAssertNil(invalidID)

        let active = try SessionActivityItem(
            id: String(repeating: "a", count: 24),
            state: .running,
            event: .userPromptSubmit,
            eventAt: 1,
            terminal: false
        )
        let duplicate = try SessionActivityItem(
            id: String(repeating: "a", count: 24),
            state: .review,
            event: .preCompact,
            eventAt: 2,
            terminal: false
        )
        XCTAssertThrowsError(
            try SessionActivitySnapshot(
                emittedAt: 3,
                active: [active, duplicate]
            )
        )
        XCTAssertThrowsError(
            try SessionActivitySnapshot(
                emittedAt: 3,
                active: [active],
                completed: [active]
            )
        )
    }

    func testSessionActivityRejectsSemanticallyMalformedJSON() throws {
        let malformedItems = [
            #"{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","state":"running","event":"SessionEnd","event_at":10,"terminal":false}"#,
            #"{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","state":"running","event":"UserPromptSubmit","event_at":10,"terminal":true}"#,
            #"{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","state":"idle","event":"SessionStart","event_at":10,"terminal":false}"#,
            #"{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","state":"running","event":"UserPromptSubmit","event_at":10,"started_at":11,"terminal":false}"#,
            #"{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","state":"idle","event":"SessionEnd","event_at":10,"completed_at":9,"terminal":true}"#,
            #"{"id":"aaaaaaaaaaaaaaaaaaaaaaaa","state":"running","event":"PermissionRequest","event_at":10,"category":"tool","terminal":false}"#,
        ]
        for item in malformedItems {
            let json = "{\"version\":1,\"schema_version\":1,\"emitted_at\":20,\"active\":[\(item)],\"completed\":[]}".data(using: .utf8)!
            XCTAssertThrowsError(try JSONDecoder.codexPet.decode(SessionActivitySnapshot.self, from: json), item)
        }
        let nonIdleTerminal = #"{"version":1,"schema_version":1,"emitted_at":20,"active":[],"completed":[{"id":"bbbbbbbbbbbbbbbbbbbbbbbb","state":"running","event":"SessionEnd","event_at":10,"terminal":true}]}"#.data(using: .utf8)!
        XCTAssertThrowsError(
            try JSONDecoder.codexPet.decode(SessionActivitySnapshot.self, from: nonIdleTerminal)
        )
    }

    func testSessionActivityAcceptanceRejectsStaleFutureRollbackAndTimestampConflict() throws {
        let freshness = try StateFreshnessPolicy(maximumAge: 10, maximumFutureSkew: 2)
        let accepted = try SessionActivitySnapshot(emittedAt: 100)
        let newer = try SessionActivitySnapshot(emittedAt: 101)
        let rollback = try SessionActivitySnapshot(emittedAt: 99)
        let stale = try SessionActivitySnapshot(emittedAt: 80)
        let future = try SessionActivitySnapshot(emittedAt: 103)
        let conflicting = try SessionActivitySnapshot(
            emittedAt: 100,
            completed: [
                SessionActivityItem(
                    id: String(repeating: "b", count: 24),
                    state: .idle,
                    event: .sessionEnd,
                    eventAt: 100,
                    terminal: true
                )
            ]
        )

        XCTAssertEqual(
            SessionActivityAcceptancePolicy.decide(
                lastAccepted: nil,
                incoming: accepted,
                now: 100,
                freshnessPolicy: freshness
            ),
            .acceptInitial
        )
        XCTAssertEqual(
            SessionActivityAcceptancePolicy.decide(lastAccepted: accepted, incoming: newer, now: 101, freshnessPolicy: freshness),
            .acceptNewer
        )
        XCTAssertEqual(
            SessionActivityAcceptancePolicy.decide(lastAccepted: accepted, incoming: rollback, now: 100, freshnessPolicy: freshness),
            .rejectRollback
        )
        XCTAssertEqual(
            SessionActivityAcceptancePolicy.decide(lastAccepted: accepted, incoming: stale, now: 100, freshnessPolicy: freshness),
            .rejectStale
        )
        XCTAssertEqual(
            SessionActivityAcceptancePolicy.decide(lastAccepted: accepted, incoming: future, now: 100, freshnessPolicy: freshness),
            .rejectFutureSkew
        )
        XCTAssertEqual(
            SessionActivityAcceptancePolicy.decide(lastAccepted: accepted, incoming: conflicting, now: 100, freshnessPolicy: freshness),
            .rejectEqualTimestampConflict
        )
    }

    func testStateFreshnessUsesHeartbeatBudgetAndRejectsFutureSkew() throws {
        let policy = try StateFreshnessPolicy()
        XCTAssertEqual(policy.maximumAge, 150)
        XCTAssertEqual(policy.maximumFutureSkew, 60)
        XCTAssertEqual(policy.freshness(emittedAt: 850, now: 1_000), .fresh)
        XCTAssertEqual(policy.freshness(emittedAt: 849.999, now: 1_000), .stale)
        XCTAssertEqual(policy.freshness(emittedAt: 1_060, now: 1_000), .fresh)
        XCTAssertEqual(policy.freshness(emittedAt: 1_060.001, now: 1_000), .futureSkew)
        XCTAssertThrowsError(try StateFreshnessPolicy(maximumAge: 0))
        XCTAssertThrowsError(try StateFreshnessPolicy(maximumAge: .infinity))
        XCTAssertThrowsError(try StateFreshnessPolicy(maximumFutureSkew: -1))
        XCTAssertThrowsError(try StateFreshnessPolicy(maximumFutureSkew: .nan))
    }

    func testCurrentStateDecodesPublicationDiagnosticsAndRejectsInvalidBounds() throws {
        let json = #"{"version":1,"state":"running","emitted_at":10,"publication_revision":7,"recovery":true,"latest_event":"PostToolUse","latest_event_at":9.5,"rejection_diagnostics":{"count":2,"reasons":{"stale_event":2}}}"#.data(using: .utf8)!
        let decoded = try JSONDecoder.codexPet.decode(CurrentState.self, from: json)
        XCTAssertEqual(decoded.publicationRevision, 7)
        XCTAssertTrue(decoded.recovery)
        XCTAssertEqual(decoded.latestEvent, "PostToolUse")
        XCTAssertEqual(decoded.latestEventAt, 9.5)
        XCTAssertEqual(decoded.rejectionDiagnostics.reasons, ["stale_event": 2])

        let unknownEvent = #"{"version":1,"state":"idle","emitted_at":11,"publication_revision":8,"latest_event":"unknown"}"#.data(using: .utf8)!
        XCTAssertEqual(
            try JSONDecoder.codexPet.decode(CurrentState.self, from: unknownEvent).latestEvent,
            "unknown"
        )

        let quiescentExpiry = #"{"version":1,"state":"idle","emitted_at":12,"publication_revision":9,"rejection_diagnostics":{"count":1,"reasons":{"quiescent_expired":1}}}"#.data(using: .utf8)!
        XCTAssertEqual(
            try JSONDecoder.codexPet.decode(CurrentState.self, from: quiescentExpiry)
                .rejectionDiagnostics.reasons,
            ["quiescent_expired": 1]
        )

        XCTAssertThrowsError(try CurrentState(state: .idle, emittedAt: 1, publicationRevision: 0))
        XCTAssertThrowsError(try CurrentState(state: .idle, emittedAt: 1, latestEventAt: .infinity))
        XCTAssertThrowsError(try CurrentStateRejectionDiagnostics(count: -1))
        XCTAssertThrowsError(try CurrentStateRejectionDiagnostics(count: 1, reasons: ["private-error": 1]))
    }

    func testPublicationOrderPolicyIsMonotonicAndLegacyCompatible() throws {
        let legacy = try CurrentState(state: .idle, emittedAt: 10)
        let newerLegacy = try CurrentState(state: .running, emittedAt: 11)
        let revisioned = try CurrentState(state: .running, emittedAt: 11, publicationRevision: 2)
        let metadataRepair = try CurrentState(
            state: .running,
            activeSessions: 2,
            emittedAt: 12,
            publicationRevision: 3,
            latestEvent: "PostToolUse",
            latestEventAt: 12
        )
        let lower = try CurrentState(state: .review, emittedAt: 13, publicationRevision: 2)
        let conflict = try CurrentState(state: .review, emittedAt: 13, publicationRevision: 3)

        XCTAssertEqual(StatePublicationOrderPolicy.decide(lastAccepted: nil, incoming: legacy), .acceptInitial)
        XCTAssertEqual(StatePublicationOrderPolicy.decide(lastAccepted: legacy, incoming: newerLegacy), .acceptNewerLegacyTimestamp)
        XCTAssertEqual(StatePublicationOrderPolicy.decide(lastAccepted: newerLegacy, incoming: revisioned), .acceptNewerRevision)
        XCTAssertEqual(StatePublicationOrderPolicy.decide(lastAccepted: revisioned, incoming: metadataRepair), .acceptNewerRevision)
        XCTAssertEqual(StatePublicationOrderPolicy.decide(lastAccepted: metadataRepair, incoming: lower), .rejectLowerRevision)
        XCTAssertEqual(StatePublicationOrderPolicy.decide(lastAccepted: metadataRepair, incoming: conflict), .rejectEqualRevisionConflict)
        XCTAssertEqual(StatePublicationOrderPolicy.decide(lastAccepted: metadataRepair, incoming: newerLegacy), .rejectRevisionlessRollback)
        XCTAssertEqual(StatePublicationOrderPolicy.decide(lastAccepted: legacy, incoming: legacy), .rejectLegacyTimestampDuplicate)
    }

    func testStatePresentationDecisionSuppressesHeartbeatButAllowsForcedRefresh() {
        XCTAssertEqual(
            StatePresentationDecision.decide(lastPresentedState: nil, incomingState: .idle),
            .initial
        )
        XCTAssertTrue(
            StatePresentationDecision.decide(lastPresentedState: nil, incomingState: .idle).shouldRefresh
        )
        XCTAssertEqual(
            StatePresentationDecision.decide(lastPresentedState: .idle, incomingState: .idle),
            .unchanged
        )
        XCTAssertFalse(
            StatePresentationDecision.decide(lastPresentedState: .idle, incomingState: .idle).shouldRefresh
        )
        XCTAssertEqual(
            StatePresentationDecision.decide(
                lastPresentedState: nil,
                pendingState: .running,
                incomingState: .running
            ),
            .unchanged
        )
        XCTAssertEqual(
            StatePresentationDecision.decide(lastPresentedState: .idle, incomingState: .running),
            .stateChanged
        )
        XCTAssertEqual(
            StatePresentationDecision.decide(
                lastPresentedState: .idle,
                pendingState: .running,
                incomingState: .idle
            ),
            .stateChanged
        )
        XCTAssertEqual(
            StatePresentationDecision.decide(
                lastPresentedState: .running,
                incomingState: .running,
                forceRefresh: true
            ),
            .forcedRefresh
        )
    }

    func testPresentationReadinessRequiresItemAndDisplayInEitherOrder() {
        var itemFirst = PresentationReadinessTracker()
        XCTAssertEqual(itemFirst.receive(.itemReady), .noChange)
        XCTAssertEqual(itemFirst.state, .preparing)
        XCTAssertEqual(itemFirst.receive(.displayReady), .becameReady)
        XCTAssertEqual(itemFirst.state, .ready)

        var displayFirst = PresentationReadinessTracker()
        XCTAssertEqual(displayFirst.receive(.displayReady), .noChange)
        XCTAssertEqual(displayFirst.receive(.itemReady), .becameReady)
        XCTAssertEqual(displayFirst.receive(.displayReady), .noChange)
    }

    func testPresentationReadinessFailureIsTerminalAndCanRevokeReady() {
        var preparing = PresentationReadinessTracker()
        XCTAssertEqual(preparing.receive(.itemReady), .noChange)
        XCTAssertEqual(preparing.receive(.failure), .becameFailed)
        XCTAssertEqual(preparing.receive(.displayReady), .noChange)
        XCTAssertEqual(preparing.receive(.failure), .noChange)
        XCTAssertEqual(preparing.state, .failed)

        var presented = PresentationReadinessTracker()
        XCTAssertEqual(presented.receive(.itemReady), .noChange)
        XCTAssertEqual(presented.receive(.displayReady), .becameReady)
        XCTAssertEqual(presented.receive(.failure), .becameFailed)
        XCTAssertEqual(presented.state, .failed)
    }

    func testMediaMapDecodesHEVCAlphaMOVAndSourcePlaybackRate() throws {
        let json = """
        {
          "version": 1,
          "default_format": "mov",
          "window": {"width": 320, "height": 480, "always_on_top": true, "click_through": false},
          "states": {
            "idle": {"path": "idle-hevc-alpha.mov", "loop": true, "playback_rate": 23.0/24.0},
            "running": {"path": "running-hevc-alpha.mov", "playback_rate": 1.0}
          }
        }
        """.replacingOccurrences(of: "23.0/24.0", with: "0.9583333333333334").data(using: .utf8)!
        let map = try JSONDecoder.codexPet.decode(MediaMap.self, from: json)
        XCTAssertEqual(map.defaultFormat, "mov")
        XCTAssertEqual(map.entry(for: .idle)?.path, "idle-hevc-alpha.mov")
        XCTAssertEqual(try XCTUnwrap(map.entry(for: .idle)?.playbackRate.value), 23.0 / 24.0, accuracy: 0.000001)
        XCTAssertFalse(map.window.fullScreenAuxiliary)
    }

    func testLegacyMediaMapUsesDefaultPetAppearance() throws {
        let json = #"{"version":1,"window":{"width":360},"states":{"idle":{"path":"idle.mov"}}}"#.data(using: .utf8)!
        let map = try JSONDecoder.codexPet.decode(MediaMap.self, from: json)

        XCTAssertEqual(map.window.appearance, try PetAppearanceConfiguration())
        XCTAssertTrue(map.window.appearance.backgroundEnabled)
        XCTAssertEqual(map.window.appearance.backgroundColor, "#20242A")
        XCTAssertEqual(map.window.appearance.backgroundOpacity, 0.28)
        XCTAssertTrue(map.window.appearance.borderEnabled)
        XCTAssertEqual(map.window.appearance.borderColor, "#FFFFFF")
        XCTAssertEqual(map.window.appearance.borderOpacity, 0.24)
        XCTAssertEqual(map.window.appearance.borderWidth, 1.0)
        XCTAssertEqual(map.window.appearance.cornerRadius, 22.0)
        XCTAssertTrue(map.window.appearance.showStateLabel)
        XCTAssertEqual(map.window.appearance.stateLabelPosition, .topLeft)
        XCTAssertEqual(map.window.appearance.stateLabelSize, .regular)
        XCTAssertNil(map.window.appearance.stateLabelColor)
        XCTAssertTrue(map.window.appearance.showFPS)
        XCTAssertEqual(map.window.appearance.fpsColor, "#00FF00")
        XCTAssertEqual(map.window.appearance.fpsLabelSize, .small)
        XCTAssertEqual(map.window.appearance.dialogueBackgroundColor, "#20242A")
        XCTAssertEqual(map.window.appearance.dialogueTextColor, "#FFFFFF")
        XCTAssertEqual(map.window.appearance.dialogueBackgroundOpacity, 0.88)
        XCTAssertEqual(map.window.appearance.dialogueContrastMode, .automatic)
    }

    func testMalformedAppearanceFailsClosedToReadableDefaultsWithoutDroppingMap() throws {
        let json = ##"{"version":1,"window":{"appearance":{"background_color":"#ABCDEF","background_opacity":0.61,"border_width":4,"show_fps":false,"dialogue_background_color":"#FFFFFF","dialogue_text_color":"#FFFFFF","dialogue_background_opacity":99,"dialogue_contrast_mode":"custom"}},"states":{"idle":{"path":"idle.mov"}}}"##.data(using: .utf8)!
        let map = try JSONDecoder.codexPet.decode(MediaMap.self, from: json)
        XCTAssertEqual(map.entry(for: .idle)?.path, "idle.mov")
        XCTAssertEqual(map.window.appearance.backgroundColor, "#ABCDEF")
        XCTAssertEqual(map.window.appearance.backgroundOpacity, 0.61)
        XCTAssertEqual(map.window.appearance.borderWidth, 4)
        XCTAssertFalse(map.window.appearance.showFPS)
        XCTAssertEqual(map.window.appearance.dialogueBackgroundColor, "#FFFFFF")
        XCTAssertEqual(map.window.appearance.dialogueTextColor, "#FFFFFF")
        XCTAssertEqual(map.window.appearance.dialogueBackgroundOpacity, 0.88)
        XCTAssertEqual(map.window.appearance.dialogueContrastMode, .custom)
    }

    func testPetAppearanceDecodesDefaultsNormalizesAndRoundTrips() throws {
        let json = ##"{"background_color":"#a1b2c3","border_color":"#dEf012","border_enabled":false,"border_width":4.5,"corner_radius":31,"show_state_label":false,"state_label_position":"bottom_right","state_label_size":"large","state_label_color":"#1a2B3c","show_fps":false,"fps_color":"#00eE77","fps_label_size":"regular","dialogue_background_color":"#FfFfFf","dialogue_text_color":"#aBc123","dialogue_background_opacity":0.64,"dialogue_contrast_mode":"custom"}"##.data(using: .utf8)!
        let appearance = try JSONDecoder.codexPet.decode(PetAppearanceConfiguration.self, from: json)

        XCTAssertEqual(appearance.backgroundColor, "#A1B2C3")
        XCTAssertEqual(appearance.borderColor, "#DEF012")
        XCTAssertEqual(appearance.backgroundOpacity, 0.28)
        XCTAssertEqual(appearance.borderOpacity, 0.24)
        XCTAssertFalse(appearance.borderEnabled)
        XCTAssertEqual(appearance.borderWidth, 4.5)
        XCTAssertEqual(appearance.cornerRadius, 31)
        XCTAssertFalse(appearance.showStateLabel)
        XCTAssertEqual(appearance.stateLabelPosition, .bottomRight)
        XCTAssertEqual(appearance.stateLabelSize, .large)
        XCTAssertEqual(appearance.stateLabelColor, "#1A2B3C")
        XCTAssertFalse(appearance.showFPS)
        XCTAssertEqual(appearance.fpsColor, "#00EE77")
        XCTAssertEqual(appearance.fpsLabelSize, .regular)
        XCTAssertEqual(appearance.dialogueBackgroundColor, "#FFFFFF")
        XCTAssertEqual(appearance.dialogueTextColor, "#ABC123")
        XCTAssertEqual(appearance.dialogueBackgroundOpacity, 0.64)
        XCTAssertEqual(appearance.dialogueContrastMode, .custom)

        let encoded = try JSONEncoder().encode(appearance)
        XCTAssertEqual(try JSONDecoder.codexPet.decode(PetAppearanceConfiguration.self, from: encoded), appearance)
    }

    func testPetAppearanceRejectsInvalidColorsAndRanges() throws {
        for color in ["20242A", "#FFF", "#GGGGGG", "#1234567", "#12345Z"] {
            XCTAssertThrowsError(try PetAppearanceConfiguration(backgroundColor: color), "accepted \(color)")
            XCTAssertThrowsError(try PetAppearanceConfiguration(borderColor: color), "accepted \(color)")
            XCTAssertThrowsError(try PetAppearanceConfiguration(fpsColor: color), "accepted \(color)")
            XCTAssertThrowsError(try PetAppearanceConfiguration(stateLabelColor: color), "accepted \(color)")
            XCTAssertThrowsError(try PetAppearanceConfiguration(dialogueBackgroundColor: color), "accepted \(color)")
            XCTAssertThrowsError(try PetAppearanceConfiguration(dialogueTextColor: color), "accepted \(color)")
        }
        for opacity in [-0.01, 1.01, .infinity, .nan] {
            XCTAssertThrowsError(try PetAppearanceConfiguration(backgroundOpacity: opacity))
            XCTAssertThrowsError(try PetAppearanceConfiguration(borderOpacity: opacity))
            XCTAssertThrowsError(try PetAppearanceConfiguration(dialogueBackgroundOpacity: opacity))
        }
        for width in [-0.01, 12.01, .infinity, .nan] {
            XCTAssertThrowsError(try PetAppearanceConfiguration(borderWidth: width))
        }
        for radius in [-0.01, 256.01, .infinity, .nan] {
            XCTAssertThrowsError(try PetAppearanceConfiguration(cornerRadius: radius))
        }
        XCTAssertNoThrow(try PetAppearanceConfiguration(backgroundOpacity: 0, borderOpacity: 1, borderWidth: 12, cornerRadius: 256, dialogueBackgroundOpacity: 0))
    }

    func testPlaybackRateValidation() throws {
        XCTAssertNoThrow(try PlaybackRate(23.0 / 24.0))
        XCTAssertNoThrow(try PlaybackRate(4.0))
        XCTAssertThrowsError(try PlaybackRate(0))
        XCTAssertThrowsError(try PlaybackRate(4.01))
        XCTAssertThrowsError(try PlaybackRate(.infinity))
        XCTAssertThrowsError(try MediaEntry(path: "idle.mov", playbackRate: 0))
    }

    func testMediaMapDecodesAndResolvesOptionalPoster() throws {
        let json = #"{"version":1,"states":{"idle":{"path":"idle.mov","poster_path":"posters/idle.png"},"running":{"path":"running.mov"}}}"#.data(using: .utf8)!
        let map = try JSONDecoder.codexPet.decode(MediaMap.self, from: json)
        let mapURL = URL(fileURLWithPath: "/tmp/codex-pet/media-map.json")
        XCTAssertEqual(map.entry(for: .idle)?.posterPath, "posters/idle.png")
        XCTAssertEqual(map.resolvedPosterURL(for: .idle, relativeTo: mapURL)?.path, "/tmp/codex-pet/posters/idle.png")
        XCTAssertNil(map.resolvedPosterURL(for: .running, relativeTo: mapURL))
        XCTAssertThrowsError(try MediaEntry(path: "idle.mov", posterPath: ""))
        let unknown = #"{"version":1,"states":{"paused":{"path":"paused.mov"}}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder.codexPet.decode(MediaMap.self, from: unknown))
    }

    func testVerifiedAlphaConversionReportIsAcceptedAndNormalized() throws {
        let validated = try AlphaConversionReportValidator.validate(
            data: Data(validAlphaReportJSON().utf8),
            expectedOutputBasename: "idle.mov",
            actualOutputSHA256: reportOutputHash.uppercased()
        )
        XCTAssertEqual(validated.outputBasename, "idle.mov")
        XCTAssertEqual(validated.outputSHA256, reportOutputHash)
        XCTAssertEqual(validated.sourceSHA256, reportSourceHash)
        XCTAssertEqual(validated.width, 320)
        XCTAssertEqual(validated.height, 486)
        XCTAssertEqual(validated.frames, 241)
        XCTAssertEqual(validated.fps, "24/1")
        XCTAssertEqual(validated.reportSchemaVersion, 1)
        XCTAssertEqual(validated.trust, .portableClaim)
        XCTAssertEqual(validated.toolchain?.converterVersion, "1")
        XCTAssertEqual(validated.toolchain?.ffmpegVersion, "ffmpeg version 8.0")
        XCTAssertEqual(validated.toolchain?.macOSBuild, "23G93")
        XCTAssertEqual(validated.toolCapabilities?.ffmpegEncoder, "prores_ks")
        XCTAssertEqual(validated.profile?.name, "standard")
        XCTAssertEqual(validated.profile?.framing, "fill")
        XCTAssertEqual(validated.normalization?.applied, ["strip-audio", "square-pixel-output"])
        XCTAssertEqual(
            validated.normalization?.warnings,
            ["rotation-sar-vfr-hdr-interlace-rejected-before-decode"]
        )
        XCTAssertEqual(
            validated.notices,
            [
                .audioStripped(streamCount: 1),
                .loopMayJump(differingPixels: 120),
                .canvasAdjusted(
                    requestedWidth: 321,
                    requestedHeight: 487,
                    outputWidth: 320,
                    outputHeight: 486
                ),
            ]
        )
    }

    func testInformationalConversionNoticesDoNotOverrideVerificationGates() {
        assertReportError(
            validAlphaReportJSON().replacingOccurrences(
                of: "\"lost_alpha_pixels_total\":0",
                with: "\"lost_alpha_pixels_total\":1"
            ),
            actualOutputSHA256: reportOutputHash,
            equals: .alphaGateFailed
        )
        assertReportError(
            validAlphaReportJSON().replacingOccurrences(
                of: "\"quality_passed\":true,\"limits\"",
                with: "\"quality_passed\":false,\"limits\""
            ),
            actualOutputSHA256: reportOutputHash,
            equals: .compositeGateFailed
        )
    }

    func testLegacyAlphaReportWithoutInformationalSectionsRemainsAccepted() throws {
        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(validAlphaReportJSON().utf8))
                as? [String: Any]
        )
        legacy.removeValue(forKey: "source")
        legacy.removeValue(forKey: "geometry_alignment")
        legacy.removeValue(forKey: "quality")
        legacy.removeValue(forKey: "report_schema_version")
        legacy.removeValue(forKey: "toolchain")
        legacy.removeValue(forKey: "profile")
        legacy.removeValue(forKey: "normalization")
        legacy.removeValue(forKey: "provenance")

        let validated = try AlphaConversionReportValidator.validate(
            data: try JSONSerialization.data(withJSONObject: legacy),
            expectedOutputBasename: "idle.mov",
            actualOutputSHA256: reportOutputHash
        )

        XCTAssertTrue(validated.notices.isEmpty)
        XCTAssertEqual(validated.reportSchemaVersion, 0)
        XCTAssertEqual(validated.trust, .legacyPortableClaim)
        XCTAssertNil(validated.toolchain)
    }

    func testAlphaConversionReportRejectsUnsupportedFutureSchema() {
        assertReportError(
            validAlphaReportJSON().replacingOccurrences(
                of: "\"report_schema_version\":1",
                with: "\"report_schema_version\":2"
            ),
            actualOutputSHA256: reportOutputHash,
            equals: .unsupportedSchemaVersion(2)
        )
    }

    func testAlphaConversionReportRejectsExplicitLegacySchemaAndIncompleteV1Metadata() {
        assertReportError(
            validAlphaReportJSON().replacingOccurrences(
                of: "\"report_schema_version\":1",
                with: "\"report_schema_version\":0"
            ),
            actualOutputSHA256: reportOutputHash,
            equals: .unsupportedSchemaVersion(0)
        )
        assertReportError(
            validAlphaReportJSON().replacingOccurrences(
                of: "\"toolchain\":{\"converter_version\":\"1\",\"ffmpeg_version\":\"ffmpeg version 8.0\",\"ffprobe_version\":\"ffprobe version 8.0\",\"avconvert_version\":\"avconvert help\",\"macos_build\":\"23G93\"},",
                with: ""
            ),
            actualOutputSHA256: reportOutputHash,
            equals: .invalidMetadata
        )
    }

    func testLocalProvenanceRequiresMatchingFreshChallenge() throws {
        let attested = try AlphaConversionReportValidator.validate(
            data: Data(validAlphaReportJSON().utf8),
            expectedOutputBasename: "idle.mov",
            actualOutputSHA256: reportOutputHash,
            expectedLocalProvenanceChallenge: reportProvenanceChallenge.uppercased()
        )
        XCTAssertEqual(attested.trust, .locallyAttested)

        assertReportError(
            validAlphaReportJSON(),
            actualOutputSHA256: reportOutputHash,
            expectedLocalProvenanceChallenge: String(repeating: "d", count: 64),
            equals: .provenanceMismatch
        )
        assertReportError(
            validAlphaReportJSON().replacingOccurrences(
                of: "\"provenance\":{\"method\":\"invocation-challenge-v1\",\"producer\":\"statelet\",\"challenge\":\"\(reportProvenanceChallenge)\"},",
                with: ""
            ),
            actualOutputSHA256: reportOutputHash,
            expectedLocalProvenanceChallenge: reportProvenanceChallenge,
            equals: .provenanceRequired
        )
    }

    func testPortableSchemaV1RejectsMalformedProvenanceWithoutExpectedChallenge() {
        assertReportError(
            validAlphaReportJSON().replacingOccurrences(
                of: "\"method\":\"invocation-challenge-v1\"",
                with: "\"method\":\"self-asserted\""
            ),
            actualOutputSHA256: reportOutputHash,
            equals: .invalidMetadata
        )
        assertReportError(
            validAlphaReportJSON().replacingOccurrences(
                of: "\"producer\":\"statelet\"",
                with: "\"producer\":\"external\""
            ),
            actualOutputSHA256: reportOutputHash,
            equals: .invalidMetadata
        )
        assertReportError(
            validAlphaReportJSON().replacingOccurrences(
                of: "\"challenge\":\"\(reportProvenanceChallenge)\"",
                with: "\"challenge\":\"\(reportProvenanceChallenge.uppercased())\""
            ),
            actualOutputSHA256: reportOutputHash,
            equals: .invalidHash("provenance challenge")
        )
        assertReportError(
            validAlphaReportJSON().replacingOccurrences(
                of: "\"challenge\":\"\(reportProvenanceChallenge)\"",
                with: "\"challenge\":\"short\""
            ),
            actualOutputSHA256: reportOutputHash,
            equals: .invalidHash("provenance challenge")
        )
    }

    func testAlphaConversionReportRejectsOversizedDataBeforeDecoding() {
        let oversized = Data(
            repeating: 0x20,
            count: AlphaConversionReportValidator.maximumReportBytes + 1
        )
        XCTAssertThrowsError(try AlphaConversionReportValidator.validate(
            data: oversized,
            expectedOutputBasename: "idle.mov",
            actualOutputSHA256: reportOutputHash
        )) { error in
            XCTAssertEqual(error as? AlphaConversionReportValidationError, .reportTooLarge)
        }
    }

    func testPlaybackAcceptanceRequiresPlayableDecodedMatchingHEVC() throws {
        let report = try AlphaConversionReportValidator.validate(
            data: Data(validAlphaReportJSON().utf8),
            expectedOutputBasename: "idle.mov",
            actualOutputSHA256: reportOutputHash
        )
        let accepted = try AlphaPlaybackAcceptanceValidator.validate(
            probe: AlphaPlaybackProbe(
                isPlayable: true,
                videoTrackCount: 1,
                audioTrackCount: 0,
                codec: "hevc",
                width: 320,
                height: 486,
                nominalFrameRate: 24,
                durationSeconds: 241.0 / 24.0,
                decodedFirstFrame: true
            ),
            expected: report
        )
        XCTAssertEqual(accepted.width, 320)
        XCTAssertTrue(accepted.decodedFirstFrame)

        XCTAssertThrowsError(try AlphaPlaybackAcceptanceValidator.validate(
            probe: AlphaPlaybackProbe(
                isPlayable: true,
                videoTrackCount: 1,
                audioTrackCount: 0,
                codec: "hevc",
                width: 320,
                height: 480,
                nominalFrameRate: 24,
                durationSeconds: 241.0 / 24.0,
                decodedFirstFrame: true
            ),
            expected: report
        )) { error in
            XCTAssertEqual(error as? AlphaPlaybackAcceptanceError, .geometryMismatch)
        }

        XCTAssertThrowsError(try AlphaPlaybackAcceptanceValidator.validate(
            probe: AlphaPlaybackProbe(
                isPlayable: true,
                videoTrackCount: 1,
                audioTrackCount: 1,
                codec: "hevc",
                width: 320,
                height: 486,
                nominalFrameRate: 24,
                durationSeconds: 241.0 / 24.0,
                decodedFirstFrame: true
            ),
            expected: report
        )) { error in
            XCTAssertEqual(error as? AlphaPlaybackAcceptanceError, .audioPresent)
        }
    }

    func testAlphaConversionReportRejectsIdentityAndSourceFailures() {
        assertReportError(
            validAlphaReportJSON(),
            expectedOutputBasename: "running.mov",
            actualOutputSHA256: reportOutputHash,
            equals: .outputBasenameMismatch
        )
        assertReportError(
            validAlphaReportJSON(),
            actualOutputSHA256: String(repeating: "c", count: 64),
            equals: .outputHashMismatch
        )
        assertReportError(
            validAlphaReportJSON().replacingOccurrences(
                of: "\"source_sha256_before_publication\":\"\(reportSourceHash)\"",
                with: "\"source_sha256_before_publication\":\"\(String(repeating: "c", count: 64))\""
            ),
            actualOutputSHA256: reportOutputHash,
            equals: .sourceChanged
        )
        assertReportError(
            validAlphaReportJSON(),
            actualOutputSHA256: "not-a-sha256",
            equals: .invalidHash("actual output")
        )
    }

    func testAlphaConversionReportRejectsUnverifiedOrWrongCodec() {
        assertReportError(
            validAlphaReportJSON().replacingOccurrences(of: "\"unsafe\":false", with: "\"unsafe\":true"),
            actualOutputSHA256: reportOutputHash,
            equals: .unverifiedDelivery
        )
        assertReportError(
            validAlphaReportJSON().replacingOccurrences(
                of: "\"delivery\":\"HEVC with alpha\"",
                with: "\"delivery\":\"H.264\""
            ),
            actualOutputSHA256: reportOutputHash,
            equals: .invalidDelivery
        )
        assertReportError(
            validAlphaReportJSON().replacingOccurrences(
                of: "\"profile\":\"4444\"",
                with: "\"profile\":\"422\""
            ),
            actualOutputSHA256: reportOutputHash,
            equals: .invalidDelivery
        )
    }

    func testAlphaConversionReportRejectsFrameAlphaAndCompositeFailures() {
        assertReportError(
            validAlphaReportJSON().replacingOccurrences(
                of: "\"frames_verified\":241",
                with: "\"frames_verified\":240"
            ),
            actualOutputSHA256: reportOutputHash,
            equals: .frameMismatch
        )
        assertReportError(
            validAlphaReportJSON().replacingOccurrences(
                of: "\"lost_alpha_pixels_total\":0",
                with: "\"lost_alpha_pixels_total\":1"
            ),
            actualOutputSHA256: reportOutputHash,
            equals: .alphaGateFailed
        )
        assertReportError(
            validAlphaReportJSON().replacingOccurrences(
                of: "\"maximum_outer_edge_alpha\":1",
                with: "\"maximum_outer_edge_alpha\":9"
            ),
            actualOutputSHA256: reportOutputHash,
            equals: .alphaGateFailed
        )
        assertReportError(
            validAlphaReportJSON().replacingOccurrences(
                of: "\"maximum_introduced_green_fringe_ratio\":0.001",
                with: "\"maximum_introduced_green_fringe_ratio\":0.02"
            ),
            actualOutputSHA256: reportOutputHash,
            equals: .compositeGateFailed
        )
        assertReportError(
            validAlphaReportJSON().replacingOccurrences(
                of: "[\"white\",\"black\",\"checkerboard\"]",
                with: "[\"white\",\"black\"]"
            ),
            actualOutputSHA256: reportOutputHash,
            equals: .compositeGateFailed
        )
    }

    func testMediaMapAndWindowReplacementAreImmutable() throws {
        let appearance = try PetAppearanceConfiguration(
            backgroundColor: "#112233",
            borderWidth: 2,
            stateLabelPosition: .bottomLeft,
            stateLabelColor: "#445566"
        )
        let originalWindow = try WindowConfiguration(
            width: 320,
            height: 486,
            alwaysOnTop: true,
            clickThrough: false,
            fullScreenAuxiliary: false,
            appearance: appearance
        )
        let idle = try MediaEntry(path: "idle.mov", posterPath: "idle.png")
        let running = try MediaEntry(path: "running.mov", playbackRate: 1.25)
        let idleHandoff = try MediaEntry(path: "idle-handoff.mov", loop: false)
        let original = try MediaMap(
            defaultFormat: "mov",
            window: originalWindow,
            states: [.idle: idle, .running: running],
            inStateTransitions: [.idle: idleHandoff]
        )
        let imported = try MediaEntry(path: "imports/idle-v2.mov", loop: true)
        let withImport = try original.replacingEntry(for: .idle, with: imported)
        XCTAssertEqual(withImport.entry(for: .idle), imported)
        XCTAssertEqual(withImport.entry(for: .running), running)
        XCTAssertEqual(withImport.window, originalWindow)
        XCTAssertEqual(withImport.defaultFormat, original.defaultFormat)
        XCTAssertEqual(withImport.inStateTransition(for: .idle), idleHandoff)
        XCTAssertEqual(original.entry(for: .idle), idle)

        let replacementWindow = try originalWindow.replacing(width: 400, clickThrough: true)
        XCTAssertEqual(replacementWindow.width, 400)
        XCTAssertEqual(replacementWindow.height, 486)
        XCTAssertTrue(replacementWindow.alwaysOnTop)
        XCTAssertTrue(replacementWindow.clickThrough)
        XCTAssertFalse(replacementWindow.fullScreenAuxiliary)
        XCTAssertEqual(replacementWindow.appearance, appearance)
        XCTAssertThrowsError(try originalWindow.replacing(width: -1))

        let replacementAppearance = try appearance.replacing(
            backgroundEnabled: false,
            borderColor: "#abcdef",
            showStateLabel: false,
            stateLabelSize: .small,
            stateLabelColor: .custom("#abcdef"),
            showFPS: false,
            fpsColor: "#12ab34",
            fpsLabelSize: .large
        )
        XCTAssertFalse(replacementAppearance.backgroundEnabled)
        XCTAssertEqual(replacementAppearance.backgroundColor, appearance.backgroundColor)
        XCTAssertEqual(replacementAppearance.borderColor, "#ABCDEF")
        XCTAssertEqual(replacementAppearance.borderWidth, appearance.borderWidth)
        XCTAssertFalse(replacementAppearance.showStateLabel)
        XCTAssertEqual(replacementAppearance.stateLabelPosition, appearance.stateLabelPosition)
        XCTAssertEqual(replacementAppearance.stateLabelSize, .small)
        XCTAssertEqual(replacementAppearance.stateLabelColor, "#ABCDEF")
        XCTAssertFalse(replacementAppearance.showFPS)
        XCTAssertEqual(replacementAppearance.fpsColor, "#12AB34")
        XCTAssertEqual(replacementAppearance.fpsLabelSize, .large)

        let automaticStateLabelColor = try replacementAppearance.replacing(stateLabelColor: .automatic)
        XCTAssertNil(automaticStateLabelColor.stateLabelColor)
        XCTAssertEqual(replacementAppearance.stateLabelColor, "#ABCDEF")
        XCTAssertNil(try automaticStateLabelColor.replacing().stateLabelColor)
        XCTAssertThrowsError(
            try automaticStateLabelColor.replacing(stateLabelColor: .custom("#GGGGGG"))
        )

        let appearanceWindow = try originalWindow.replacing(appearance: replacementAppearance)
        XCTAssertEqual(appearanceWindow.appearance, replacementAppearance)
        XCTAssertEqual(appearanceWindow.width, originalWindow.width)
        XCTAssertEqual(appearanceWindow.height, originalWindow.height)
        XCTAssertEqual(appearanceWindow.alwaysOnTop, originalWindow.alwaysOnTop)
        XCTAssertEqual(appearanceWindow.clickThrough, originalWindow.clickThrough)
        XCTAssertEqual(appearanceWindow.fullScreenAuxiliary, originalWindow.fullScreenAuxiliary)

        let withWindow = try original.replacingWindow(appearanceWindow)
        XCTAssertEqual(withWindow.window, appearanceWindow)
        XCTAssertEqual(withWindow.defaultFormat, original.defaultFormat)
        XCTAssertEqual(withWindow.states, original.states)
        XCTAssertEqual(withWindow.inStateTransition(for: .idle), idleHandoff)
        XCTAssertEqual(original.window, originalWindow)

        XCTAssertEqual(MediaMapChangeImpact.decide(previous: original, incoming: original), .unchanged)
        XCTAssertEqual(MediaMapChangeImpact.decide(previous: original, incoming: withWindow), .windowOnly)
        XCTAssertFalse(MediaMapChangeImpact.decide(previous: original, incoming: withWindow).shouldRefreshPlayback)
        XCTAssertEqual(MediaMapChangeImpact.decide(previous: original, incoming: withImport), .playback)
        XCTAssertTrue(MediaMapChangeImpact.decide(previous: original, incoming: withImport).shouldRefreshPlayback)

        let withTransition = try original.settingTransition(
            from: .idle,
            to: .running,
            entry: try MediaEntry(path: "idle-running.mov", loop: false)
        )
        XCTAssertEqual(MediaMapChangeImpact.decide(previous: original, incoming: withTransition), .playback)
        let withInStateTransition = try MediaMap(
            defaultFormat: original.defaultFormat,
            window: original.window,
            states: original.states,
            transitions: original.transitions,
            inStateTransitions: [.idle: try MediaEntry(path: "idle-handoff-v2.mov", loop: false)]
        )
        XCTAssertEqual(MediaMapChangeImpact.decide(previous: original, incoming: withInStateTransition), .playback)
        XCTAssertEqual(try withTransition.replacingWindow(appearanceWindow).transitions, withTransition.transitions)
        XCTAssertEqual(
            try withTransition.replacingEntry(for: .idle, with: try MediaEntry(path: "replacement.mov")).transitions,
            withTransition.transitions
        )
    }

    func testMediaPlaylistLegacyDecodeAndNewShapeRoundTrip() throws {
        let legacy = #"{"version":1,"states":{"idle":{"path":"idle.mov","poster_path":"idle.png"}}}"#.data(using: .utf8)!
        let legacyMap = try JSONDecoder.codexPet.decode(MediaMap.self, from: legacy)
        XCTAssertEqual(legacyMap.playlist(for: .idle)?.mode, .fixed)
        XCTAssertEqual(legacyMap.playlist(for: .idle)?.advanceOn, .stateEntry)
        XCTAssertEqual(legacyMap.playlist(for: .idle)?.fixedPath, "idle.mov")
        XCTAssertEqual(legacyMap.playlist(for: .idle)?.entries.map(\.path), ["idle.mov"])
        XCTAssertEqual(legacyMap.entry(for: .idle)?.path, "idle.mov")

        let first = try MediaEntry(path: "idle/one.mov", posterPath: "posters/one.png")
        let second = try MediaEntry(path: "idle/two.mov", playbackRate: 1.25)
        let playlist = try StateMediaPlaylist(
            mode: .sequential,
            advanceOn: .clipEnd,
            fixedPath: second.path,
            entries: [first, second]
        )
        let map = try MediaMap(states: [.idle: playlist])
        let data = try JSONEncoder().encode(map)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let states = try XCTUnwrap(object["states"] as? [String: Any])
        let idle = try XCTUnwrap(states["idle"] as? [String: Any])
        XCTAssertEqual(idle["mode"] as? String, "sequential")
        XCTAssertEqual(idle["advance_on"] as? String, "clip_end")
        XCTAssertEqual(idle["fixed_path"] as? String, second.path)
        XCTAssertEqual((idle["entries"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(try JSONDecoder.codexPet.decode(MediaMap.self, from: data), map)

        let playlistWithoutPolicy = #"{"mode":"random","fixed_path":"one.mov","entries":[{"path":"one.mov"},{"path":"two.mov"}]}"#.data(using: .utf8)!
        XCTAssertEqual(
            try JSONDecoder.codexPet.decode(StateMediaPlaylist.self, from: playlistWithoutPolicy).advanceOn,
            .stateEntry
        )
    }

    func testDirectionalTransitionsRoundTripAndLegacyMapsRemainEmpty() throws {
        let forward = try MediaEntry(path: "transitions/idle-running.mov", loop: false)
        let reverse = try MediaEntry(path: "transitions/running-idle.mov", loop: false)
        let map = try MediaMap()
            .settingTransition(from: .idle, to: .running, entry: forward)
            .settingTransition(from: .running, to: .idle, entry: reverse)

        XCTAssertEqual(map.transition(from: .idle, to: .running), forward)
        XCTAssertEqual(map.transition(from: .running, to: .idle), reverse)
        XCTAssertNil(map.transition(from: .idle, to: .idle))
        XCTAssertEqual(LifecycleTransitionMediaPolicy.maximumDuration, 4)
        XCTAssertEqual(LifecycleTransitionMediaPolicy.maximumPresentationDuration, 1.5)
        XCTAssertEqual(
            LifecycleTransitionMediaPolicy.presentationPlaybackRate(
                sourceDuration: 4,
                requestedRate: 1
            ),
            4 / 1.5,
            accuracy: 0.0001
        )
        XCTAssertFalse(
            try MediaMap().settingTransition(
                from: .idle,
                to: .review,
                entry: try MediaEntry(path: "transition.mov", loop: true)
            ).transition(from: .idle, to: .review)!.loop
        )

        let decoded = try JSONDecoder.codexPet.decode(MediaMap.self, from: JSONEncoder().encode(map))
        XCTAssertEqual(decoded, map)
        XCTAssertEqual(
            try decoded.removingTransition(from: .idle, to: .running)
                .transition(from: .running, to: .idle),
            reverse
        )
        XCTAssertThrowsError(try decoded.settingTransition(from: .idle, to: .idle, entry: forward))

        let legacy = #"{"version":1,"states":{}}"#.data(using: .utf8)!
        XCTAssertTrue(try JSONDecoder.codexPet.decode(MediaMap.self, from: legacy).transitions.isEmpty)
    }

    func testTransitionPlaylistMigratesEditsAndPreservesSettings() throws {
        let legacy = Data(#"""
        {
          "version": 1,
          "states": {},
          "transitions": {
            "idle_to_running": {"path":"one.mov","loop":true,"playback_rate":1}
          }
        }
        """#.utf8)
        var map = try JSONDecoder.codexPet.decode(MediaMap.self, from: legacy)
        let migrated = try XCTUnwrap(map.transitionPlaylist(from: .idle, to: .running))
        XCTAssertEqual(migrated.mode, .fixed)
        XCTAssertEqual(migrated.fixedPath, "one.mov")
        XCTAssertFalse(migrated.entries[0].loop)

        map = try map.appendingTransitionEntry(
            MediaEntry(path: "two.mov", loop: true),
            from: .idle,
            to: .running
        )
        map = try map.changingTransitionPlaybackMode(from: .idle, to: .running, to: .sequential)
        map = try map.settingFixedTransitionEntry(from: .idle, to: .running, path: "two.mov")
        map = try map.movingTransitionEntry(from: .idle, to: .running, path: "two.mov", to: 0)
        let playlist = try XCTUnwrap(map.transitionPlaylist(from: .idle, to: .running))
        XCTAssertEqual(playlist.entries.map(\.path), ["two.mov", "one.mov"])
        XCTAssertEqual(playlist.mode, .sequential)
        XCTAssertEqual(playlist.fixedPath, "two.mov")
        XCTAssertTrue(playlist.entries.allSatisfy { !$0.loop })

        let roundTrip = try JSONDecoder.codexPet.decode(MediaMap.self, from: JSONEncoder().encode(map))
        XCTAssertEqual(roundTrip, map)
        XCTAssertEqual(roundTrip.allTransitionEntries.map(\.path), ["two.mov", "one.mov"])

        map = try map.removingTransitionEntry(from: .idle, to: .running, path: "two.mov")
        XCTAssertEqual(map.transitionEntries(from: .idle, to: .running).map(\.path), ["one.mov"])
        map = try map.removingTransitionEntry(from: .idle, to: .running, path: "one.mov")
        XCTAssertNil(map.transitionPlaylist(from: .idle, to: .running))
    }

    func testTransitionSelectionCursorIsRouteIndependentAndCommitsOnce() throws {
        let one = try MediaEntry(path: "one.mov", loop: false)
        let two = try MediaEntry(path: "two.mov", loop: false)
        let three = try MediaEntry(path: "three.mov", loop: false)
        let random = try StateMediaPlaylist(mode: .random, entries: [one, two, three])
        let sequential = try StateMediaPlaylist(mode: .sequential, entries: [one, two, three])
        var cursor = TransitionSelectionCursor()

        var first = try cursor.request(from: .idle, to: .running, playlist: random, randomIndex: { _ in 0 })
        XCTAssertEqual(first.next()?.path, "one.mov")
        XCTAssertTrue(first.commit(to: &cursor))
        XCTAssertFalse(first.commit(to: &cursor))

        var second = try cursor.request(from: .idle, to: .running, playlist: random, randomIndex: { _ in 0 })
        XCTAssertEqual(second.next()?.path, "two.mov", "random must avoid an immediate repeat")
        XCTAssertTrue(second.commit(to: &cursor))

        var fallback = try cursor.request(from: .idle, to: .running, playlist: random, randomIndex: { _ in 0 })
        XCTAssertEqual(fallback.next()?.path, "one.mov")
        XCTAssertEqual(fallback.next()?.path, "three.mov")
        XCTAssertEqual(fallback.next()?.path, "two.mov")
        XCTAssertNil(fallback.next(), "each variant is tried at most once per request")

        var reverse = try cursor.request(from: .running, to: .idle, playlist: sequential)
        XCTAssertEqual(reverse.next()?.path, "one.mov", "reverse direction owns an independent cursor")
        XCTAssertTrue(reverse.commit(to: &cursor))
        var forward = try cursor.request(from: .idle, to: .running, playlist: sequential)
        XCTAssertEqual(forward.next()?.path, "three.mov")
    }

    func testUniversalTransitionSelectionSharesCursorAcrossLifecycleRoutes() throws {
        let one = try MediaEntry(path: "global-one.mov", loop: false)
        let two = try MediaEntry(path: "global-two.mov", loop: false)
        let playlist = try StateMediaPlaylist(mode: .sequential, entries: [one, two])
        var cursor = TransitionSelectionCursor()

        var first = try cursor.requestGlobal(from: .idle, to: .running, playlist: playlist)
        XCTAssertEqual(first.next()?.path, "global-one.mov")
        XCTAssertTrue(first.commit(to: &cursor))
        XCTAssertEqual(cursor.globalSelectedPath, "global-one.mov")

        var second = try cursor.requestGlobal(from: .waiting, to: .review, playlist: playlist)
        XCTAssertEqual(second.next()?.path, "global-two.mov")
        XCTAssertTrue(second.commit(to: &cursor))

        var third = try cursor.requestGlobal(from: .review, to: .idle, playlist: playlist)
        XCTAssertEqual(third.next()?.path, "global-one.mov")
    }

    func testCharacterBundleTransitionsRewriteAndRequireReferencedAssets() throws {
        let hash = String(repeating: "a", count: 64)
        let transition = try MediaEntry(
            path: "movies/idle-running.mov",
            posterPath: "posters/idle-running.png",
            loop: false
        )
        let alternate = try MediaEntry(
            path: "movies/idle-running-alt.mov",
            posterPath: "posters/idle-running-alt.png",
            loop: false
        )
        let map = try MediaMap()
            .settingTransition(from: .idle, to: .running, entry: transition)
            .appendingTransitionEntry(alternate, from: .idle, to: .running)
            .changingTransitionPlaybackMode(from: .idle, to: .running, to: .random)
            .settingFixedTransitionEntry(from: .idle, to: .running, path: alternate.path)
        let manifest = try CharacterBundleManifest(
            characterID: "transition-character",
            characterName: "Transition Character",
            mediaMap: map,
            assets: [
                CharacterBundleAsset(role: .movie, path: transition.path, size: 1, sha256: hash),
                CharacterBundleAsset(role: .poster, path: transition.posterPath!, size: 1, sha256: hash),
                CharacterBundleAsset(role: .movie, path: alternate.path, size: 1, sha256: hash),
                CharacterBundleAsset(role: .poster, path: alternate.posterPath!, size: 1, sha256: hash),
            ]
        )
        let rewritten = try manifest.mediaMap(rewritingPaths: { "installed/\($0)" })
        XCTAssertEqual(rewritten.transition(from: .idle, to: .running)?.path, "installed/movies/idle-running-alt.mov")
        XCTAssertEqual(rewritten.transition(from: .idle, to: .running)?.posterPath, "installed/posters/idle-running-alt.png")
        let rewrittenPlaylist = try XCTUnwrap(rewritten.transitionPlaylist(from: .idle, to: .running))
        XCTAssertEqual(rewrittenPlaylist.entries.map(\.path), [
            "installed/movies/idle-running.mov",
            "installed/movies/idle-running-alt.mov",
        ])
        XCTAssertEqual(rewrittenPlaylist.mode, .random)
        XCTAssertEqual(rewrittenPlaylist.fixedPath, "installed/movies/idle-running-alt.mov")

        XCTAssertThrowsError(try CharacterBundleManifest(
            characterID: "transition-character",
            characterName: "Transition Character",
            mediaMap: map,
            assets: [CharacterBundleAsset(role: .poster, path: transition.posterPath!, size: 1, sha256: hash)]
        ))
        XCTAssertThrowsError(try CharacterBundleManifest(
            characterID: "transition-character",
            characterName: "Transition Character",
            mediaMap: map,
            assets: [
                CharacterBundleAsset(role: .movie, path: transition.path, size: 1, sha256: hash),
                CharacterBundleAsset(role: .movie, path: alternate.path, size: 1, sha256: hash),
                CharacterBundleAsset(role: .movie, path: "movies/unused.mov", size: 1, sha256: hash),
                CharacterBundleAsset(role: .poster, path: transition.posterPath!, size: 1, sha256: hash),
                CharacterBundleAsset(role: .poster, path: alternate.posterPath!, size: 1, sha256: hash),
            ]
        ))
    }

    func testCharacterBundleSameStateTransitionRewriteRequiresAndPreservesAssets() throws {
        let hash = String(repeating: "b", count: 64)
        let handoff = try MediaEntry(
            path: "movies/idle-handoff.mov",
            posterPath: "posters/idle-handoff.png",
            loop: true
        )
        let map = try MediaMap(
            states: [.idle: try MediaEntry(path: "movies/idle.mov")],
            inStateTransitions: [.idle: handoff]
        )
        let manifest = try CharacterBundleManifest(
            characterID: "same-state-character",
            characterName: "Same State Character",
            mediaMap: map,
            assets: [
                CharacterBundleAsset(role: .movie, path: "movies/idle.mov", size: 1, sha256: hash),
                CharacterBundleAsset(role: .movie, path: handoff.path, size: 1, sha256: hash),
                CharacterBundleAsset(role: .poster, path: handoff.posterPath!, size: 1, sha256: hash),
            ]
        )
        let rewritten = try manifest.mediaMap(rewritingPaths: { "installed/\($0)" })
        XCTAssertEqual(rewritten.inStateTransition(for: .idle)?.path, "installed/movies/idle-handoff.mov")
        XCTAssertEqual(rewritten.inStateTransition(for: .idle)?.posterPath, "installed/posters/idle-handoff.png")
        XCTAssertFalse(try XCTUnwrap(rewritten.inStateTransition(for: .idle)).loop)
        XCTAssertThrowsError(try CharacterBundleManifest(
            characterID: "same-state-character",
            characterName: "Same State Character",
            mediaMap: map,
            assets: [CharacterBundleAsset(role: .movie, path: "movies/idle.mov", size: 1, sha256: hash)]
        ))
    }

    func testMediaPlaylistValidationAndNormalizedPaths() throws {
        let first = try MediaEntry(path: "clips/./idle.mov")
        let duplicate = try MediaEntry(path: "clips/other/../idle.mov")
        XCTAssertThrowsError(try StateMediaPlaylist(entries: []))
        XCTAssertThrowsError(try StateMediaPlaylist(entries: [first, duplicate]))
        XCTAssertThrowsError(try StateMediaPlaylist(fixedPath: "missing.mov", entries: [first]))

        let normalizedReference = try StateMediaPlaylist(
            fixedPath: "clips/other/../idle.mov",
            entries: [first]
        )
        XCTAssertEqual(normalizedReference.fixedPath, first.path)
        XCTAssertEqual(normalizedReference.fixedEntry, first)
    }

    func testMediaMapPlaylistEditingIsImmutableAndPreservesOrder() throws {
        let idle1 = try MediaEntry(path: "idle-1.mov", posterPath: "idle-1.png")
        let idle2 = try MediaEntry(path: "idle-2.mov")
        let idle3 = try MediaEntry(path: "idle-3.mov")
        let running = try MediaEntry(path: "running.mov")
        let window = try WindowConfiguration(width: 444, height: 555)
        let original = try MediaMap(window: window, states: [.idle: idle1, .running: running])

        let appended = try original.appendingEntry(idle2, for: .idle)
        let sequenced = try appended.changingPlaybackMode(for: .idle, to: .sequential)
        let fixed = try sequenced.settingFixedEntry(for: .idle, path: idle2.path)
        let replaced = try fixed.replacingEntry(for: .idle, path: idle1.path, with: idle3)
        XCTAssertEqual(replaced.playlist(for: .idle)?.entries.map(\.path), [idle3.path, idle2.path])
        XCTAssertEqual(replaced.playlist(for: .idle)?.fixedEntry, idle2)
        XCTAssertEqual(replaced.playlist(for: .idle)?.mode, .fixed)
        XCTAssertEqual(replaced.entry(for: .running), running)
        XCTAssertEqual(replaced.window, window)
        XCTAssertEqual(original.playlist(for: .idle)?.entries, [idle1])
        XCTAssertEqual(MediaMapChangeImpact.decide(previous: original, incoming: appended), .playback)

        let removedFixed = try replaced.removingEntry(for: .idle, path: idle2.path)
        XCTAssertEqual(removedFixed.playlist(for: .idle)?.entries, [idle3])
        XCTAssertEqual(removedFixed.playlist(for: .idle)?.fixedEntry, idle3)
        let removedLast = try removedFixed.removingEntry(for: .idle, path: idle3.path)
        XCTAssertNil(removedLast.playlist(for: .idle))
        XCTAssertEqual(removedLast.entry(for: .running), running)

        let singletonReplacement = try appended.replacingEntry(for: .idle, with: idle3)
        XCTAssertEqual(singletonReplacement.playlist(for: .idle)?.entries, [idle3])
        XCTAssertEqual(singletonReplacement.playlist(for: .idle)?.mode, .fixed)
    }

    func testPlaylistAdvancePolicyIsPreservedByAllMutations() throws {
        let one = try MediaEntry(path: "one.mov")
        let two = try MediaEntry(path: "two.mov")
        let three = try MediaEntry(path: "three.mov")
        let replacement = try MediaEntry(path: "replacement.mov")
        let original = try StateMediaPlaylist(
            mode: .sequential,
            advanceOn: .clipEnd,
            fixedPath: two.path,
            entries: [one, two]
        )

        XCTAssertEqual(try original.appending(three).advanceOn, .clipEnd)
        XCTAssertEqual(try original.replacing(path: one.path, with: replacement).advanceOn, .clipEnd)
        XCTAssertEqual(try XCTUnwrap(original.removing(path: one.path)).advanceOn, .clipEnd)
        XCTAssertEqual(try original.changingMode(to: .random).advanceOn, .clipEnd)
        XCTAssertEqual(try original.settingFixed(path: one.path).advanceOn, .clipEnd)
        XCTAssertEqual(try original.movingEntry(path: one.path, to: 1).advanceOn, .clipEnd)

        let map = try MediaMap(states: [.idle: original])
        let changed = try map.settingAdvanceOn(for: .idle, to: .stateEntry)
        XCTAssertEqual(changed.playlist(for: .idle)?.advanceOn, .stateEntry)
        XCTAssertEqual(map.playlist(for: .idle)?.advanceOn, .clipEnd)
        XCTAssertThrowsError(try map.settingAdvanceOn(for: .running, to: .clipEnd))
    }

    func testPlaylistReorderByPathPreservesFixedEntryAndValidatesInputs() throws {
        let one = try MediaEntry(path: "clips/one.mov")
        let two = try MediaEntry(path: "clips/two.mov")
        let three = try MediaEntry(path: "clips/three.mov")
        let playlist = try StateMediaPlaylist(
            mode: .sequential,
            advanceOn: .clipEnd,
            fixedPath: two.path,
            entries: [one, two, three]
        )

        let movedDown = try playlist.movingEntry(path: "clips/./one.mov", to: 2)
        XCTAssertEqual(movedDown.entries.map(\.path), [two.path, three.path, one.path])
        XCTAssertEqual(movedDown.fixedPath, two.path)
        XCTAssertEqual(movedDown.fixedEntry, two)
        XCTAssertEqual(movedDown.mode, .sequential)
        XCTAssertEqual(movedDown.advanceOn, .clipEnd)

        let movedUp = try movedDown.movingEntry(path: one.path, to: 0)
        XCTAssertEqual(movedUp.entries, [one, two, three])
        XCTAssertEqual(try playlist.movingEntry(path: two.path, to: 1), playlist)
        XCTAssertThrowsError(try playlist.movingEntry(path: "missing.mov", to: 0))
        XCTAssertThrowsError(try playlist.movingEntry(path: one.path, to: -1))
        XCTAssertThrowsError(try playlist.movingEntry(path: one.path, to: playlist.entries.count))

        let map = try MediaMap(states: [.idle: playlist])
        let reorderedMap = try map.movingEntry(for: .idle, path: three.path, to: 0)
        XCTAssertEqual(reorderedMap.playlist(for: .idle)?.entries, [three, one, two])
        XCTAssertEqual(reorderedMap.playlist(for: .idle)?.fixedEntry, two)
        XCTAssertEqual(map.playlist(for: .idle)?.entries, [one, two, three])
        XCTAssertThrowsError(try map.movingEntry(for: .running, path: one.path, to: 0))
    }

    func testContinuousRotationPolicyRequiresClipEndNonFixedMultipleEntries() throws {
        let one = try MediaEntry(path: "one.mov")
        let two = try MediaEntry(path: "two.mov")

        XCTAssertFalse(try StateMediaPlaylist(mode: .random, entries: [one, two]).isContinuousRotationEffective)
        XCTAssertFalse(try StateMediaPlaylist(mode: .fixed, advanceOn: .clipEnd, entries: [one, two]).isContinuousRotationEffective)
        XCTAssertFalse(try StateMediaPlaylist(mode: .sequential, advanceOn: .clipEnd, entries: [one]).isContinuousRotationEffective)
        XCTAssertTrue(try StateMediaPlaylist(mode: .random, advanceOn: .clipEnd, entries: [one, two]).isContinuousRotationEffective)
        XCTAssertTrue(try StateMediaPlaylist(mode: .sequential, advanceOn: .clipEnd, entries: [one, two]).isContinuousRotationEffective)
    }

    func testEntrySpecificURLResolution() throws {
        let entry = try MediaEntry(path: "clips/two.mov", posterPath: "/tmp/two.png")
        let map = try MediaMap(states: [.idle: entry])
        let mapURL = URL(fileURLWithPath: "/tmp/pet/media-map.json")
        XCTAssertEqual(map.resolvedURL(for: entry, relativeTo: mapURL).path, "/tmp/pet/clips/two.mov")
        XCTAssertEqual(map.resolvedPosterURL(for: entry, relativeTo: mapURL)?.path, "/tmp/two.png")
    }

    func testMediaSelectionCursorModesEligibilityAndStateHistory() throws {
        let one = try MediaEntry(path: "one.mov")
        let two = try MediaEntry(path: "two.mov")
        let three = try MediaEntry(path: "three.mov")

        var cursor = MediaSelectionCursor()
        let fixed = try StateMediaPlaylist(mode: .fixed, fixedPath: two.path, entries: [one, two])
        XCTAssertEqual(cursor.select(for: .idle, from: fixed, isEligible: { _ in false }), two)
        XCTAssertEqual(cursor.selectNextExplicitly(for: .idle, from: fixed), one)
        XCTAssertEqual(cursor.selectNextExplicitly(for: .idle, from: fixed), two)
        XCTAssertEqual(fixed.fixedPath, two.path)
        XCTAssertEqual(cursor.select(for: .idle, from: fixed, advance: false), two)

        let fixedWithMissingMiddle = try StateMediaPlaylist(
            mode: .fixed,
            fixedPath: one.path,
            entries: [one, two, three]
        )
        XCTAssertTrue(MediaSelectionCursor.canSelectNextExplicitly(
            currentPath: one.path,
            from: fixedWithMissingMiddle,
            isEligible: { $0.path == three.path }
        ))
        XCTAssertFalse(MediaSelectionCursor.canSelectNextExplicitly(
            currentPath: one.path,
            from: fixedWithMissingMiddle,
            isEligible: { $0.path == one.path }
        ))
        XCTAssertTrue(MediaSelectionCursor.canSelectNextExplicitly(
            currentPath: nil,
            from: fixedWithMissingMiddle,
            isEligible: { $0.path == three.path }
        ))
        cursor.reset(state: .review)
        XCTAssertEqual(
            cursor.selectNextExplicitly(
                for: .review,
                from: fixedWithMissingMiddle,
                isEligible: { $0.path != two.path }
            ),
            three
        )

        let sequential = try StateMediaPlaylist(mode: .sequential, entries: [one, two, three])
        XCTAssertEqual(cursor.select(for: .running, from: sequential)?.path, one.path)
        XCTAssertEqual(cursor.select(for: .running, from: sequential)?.path, two.path)
        XCTAssertEqual(cursor.select(for: .running, from: sequential, advance: false)?.path, two.path)
        XCTAssertEqual(
            cursor.select(for: .running, from: sequential, isEligible: { $0.path != three.path })?.path,
            one.path
        )
        XCTAssertEqual(cursor.select(for: .review, from: sequential)?.path, one.path)

        var removalCursor = MediaSelectionCursor()
        _ = removalCursor.select(for: .running, from: sequential)
        _ = removalCursor.select(for: .running, from: sequential)
        let sequentialWithoutUnrelated = try StateMediaPlaylist(mode: .sequential, entries: [one, two])
        XCTAssertEqual(
            removalCursor.select(for: .running, from: sequentialWithoutUnrelated, advance: false)?.path,
            two.path
        )
        let sequentialWithoutActive = try StateMediaPlaylist(mode: .sequential, entries: [one, three])
        XCTAssertEqual(
            removalCursor.select(for: .running, from: sequentialWithoutActive, advance: false)?.path,
            one.path
        )

        let random = try StateMediaPlaylist(mode: .random, entries: [one, two, three])
        cursor.reset(state: .waiting)
        XCTAssertEqual(cursor.select(for: .waiting, from: random, randomIndex: { _ in 1 })?.path, two.path)
        XCTAssertEqual(cursor.select(for: .waiting, from: random, randomIndex: { _ in 0 })?.path, one.path)
        XCTAssertEqual(cursor.select(for: .waiting, from: random, advance: false, randomIndex: { _ in 1 })?.path, one.path)
        XCTAssertEqual(
            cursor.select(
                for: .waiting,
                from: random,
                isEligible: { $0.path == three.path },
                randomIndex: { _ in 999 }
            )?.path,
            three.path
        )
        XCTAssertNil(cursor.select(for: .waiting, from: random, isEligible: { _ in false }))

        var randomRemovalCursor = MediaSelectionCursor()
        _ = randomRemovalCursor.select(for: .waiting, from: random, randomIndex: { _ in 1 })
        let randomWithoutUnrelated = try StateMediaPlaylist(mode: .random, entries: [one, two])
        XCTAssertEqual(
            randomRemovalCursor.select(for: .waiting, from: randomWithoutUnrelated, advance: false)?.path,
            two.path
        )
        let randomWithoutActive = try StateMediaPlaylist(mode: .random, entries: [one, three])
        XCTAssertEqual(
            randomRemovalCursor.select(
                for: .waiting,
                from: randomWithoutActive,
                advance: false,
                randomIndex: { _ in 0 }
            )?.path,
            one.path
        )
    }

    func testLifecycleAdvanceAndPlaybackFallbackPolicies() {
        XCTAssertTrue(MediaSelectionAdvancePolicy.shouldAdvance(
            previousLifecycleState: nil,
            incomingState: .running,
            forceRefresh: false
        ))
        XCTAssertFalse(MediaSelectionAdvancePolicy.shouldAdvance(
            previousLifecycleState: .running,
            incomingState: .running,
            forceRefresh: false
        ))
        XCTAssertFalse(MediaSelectionAdvancePolicy.shouldAdvance(
            previousLifecycleState: .idle,
            incomingState: .running,
            forceRefresh: true
        ))
        XCTAssertTrue(MediaSelectionAdvancePolicy.shouldAdvance(
            previousLifecycleState: .running,
            incomingState: .waiting,
            forceRefresh: false
        ))

        XCTAssertTrue(PlaybackFallbackPolicy.shouldRetainCurrentPresentation(
            hasCurrentMedia: true,
            currentIsOneShot: false,
            requestedState: .waiting
        ))
        XCTAssertFalse(PlaybackFallbackPolicy.shouldRetainCurrentPresentation(
            hasCurrentMedia: true,
            currentIsOneShot: true,
            requestedState: .waiting
        ))
        XCTAssertFalse(PlaybackFallbackPolicy.shouldRetainCurrentPresentation(
            hasCurrentMedia: true,
            currentIsOneShot: false,
            requestedState: .idle
        ))
    }

    func testOneShotPlaybackArbiterSupersedesPreemptsAndRejectsStaleTokens() throws {
        var arbiter = OneShotPlaybackArbiter()
        XCTAssertEqual(arbiter.heartbeat(state: .idle), .inactive)

        let first = try arbiter.start(state: .idle, path: "one.mov")
        XCTAssertEqual(arbiter.heartbeat(state: .idle), .continuing(first))
        let second = try arbiter.start(state: .idle, path: "two.mov")
        XCTAssertEqual(arbiter.active, second)
        XCTAssertNil(arbiter.complete(token: first.token))
        XCTAssertEqual(arbiter.active, second)
        XCTAssertEqual(arbiter.cancel(token: second.token), second)
        XCTAssertNil(arbiter.active)
        XCTAssertNil(arbiter.cancel(token: second.token))

        let third = try arbiter.start(state: .running, path: "run-once.mov")
        XCTAssertEqual(arbiter.heartbeat(state: .waiting), .preempted(third))
        XCTAssertNil(arbiter.active)
        XCTAssertNil(arbiter.complete(token: third.token))
        XCTAssertThrowsError(try arbiter.start(state: .idle, path: ""))
    }

    func testTemporaryStatePreviewBeginsForEveryLifecycleState() {
        for state in PetState.allCases {
            var policy = TemporaryStatePreviewPolicy()
            XCTAssertEqual(policy.begin(previewState: state, baselineRealState: .idle), state)
            XCTAssertEqual(policy.previewState, state)
            XCTAssertEqual(policy.realState, .idle)
            XCTAssertEqual(policy.presentedState, state)
        }
    }

    func testTemporaryStatePreviewRetainsSameValueLifecycleHeartbeats() {
        var policy = TemporaryStatePreviewPolicy()
        policy.begin(previewState: .review, baselineRealState: .running)

        XCTAssertEqual(policy.receiveLifecycleState(.running), .presentingPreview(.review))
        XCTAssertEqual(policy.receiveLifecycleState(.running), .presentingPreview(.review))
        XCTAssertEqual(policy.previewState, .review)
        XCTAssertEqual(policy.realState, .running)
    }

    func testTemporaryStatePreviewWithoutBaselineRelinquishesOnFirstLifecycleState() {
        var policy = TemporaryStatePreviewPolicy()
        XCTAssertEqual(policy.begin(previewState: .review), .review)
        XCTAssertNil(policy.realState)

        XCTAssertEqual(policy.receiveLifecycleState(.idle), .presentingLifecycle(.idle))
        XCTAssertNil(policy.previewState)
        XCTAssertEqual(policy.realState, .idle)
        XCTAssertEqual(policy.presentedState, .idle)
    }

    func testTemporaryStatePreviewRelinquishesOnChangedLifecycleStateIncludingPreviewValue() {
        var policy = TemporaryStatePreviewPolicy()
        policy.begin(previewState: .review, baselineRealState: .idle)

        XCTAssertEqual(policy.receiveLifecycleState(.waiting), .presentingLifecycle(.waiting))
        XCTAssertNil(policy.previewState)
        XCTAssertEqual(policy.presentedState, .waiting)

        policy.begin(previewState: .review, baselineRealState: .idle)
        XCTAssertEqual(policy.receiveLifecycleState(.review), .presentingLifecycle(.review))
        XCTAssertNil(policy.previewState)
        XCTAssertEqual(policy.realState, .review)
    }

    func testTemporaryStatePreviewCancelReturnsRealState() {
        var policy = TemporaryStatePreviewPolicy()
        policy.begin(previewState: .waiting, baselineRealState: .running)

        XCTAssertEqual(policy.cancel(), .running)
        XCTAssertNil(policy.previewState)
        XCTAssertEqual(policy.presentedState, .running)
        XCTAssertEqual(policy.cancel(), .running)
    }

    func testTemporaryStatePreviewHasNoRelaunchOverride() {
        var previousProcessPolicy = TemporaryStatePreviewPolicy()
        previousProcessPolicy.begin(previewState: .review, baselineRealState: .idle)

        let relaunchedPolicy = TemporaryStatePreviewPolicy()
        XCTAssertNil(relaunchedPolicy.previewState)
        XCTAssertNil(relaunchedPolicy.realState)
        XCTAssertNil(relaunchedPolicy.presentedState)
    }

    func testTemporaryStatePreviewRepeatedBeginReplacesPreviewAndBaseline() {
        var policy = TemporaryStatePreviewPolicy()
        policy.begin(previewState: .waiting, baselineRealState: .idle)

        XCTAssertEqual(policy.begin(previewState: .review, baselineRealState: .running), .review)
        XCTAssertEqual(policy.previewState, .review)
        XCTAssertEqual(policy.realState, .running)
        XCTAssertEqual(policy.receiveLifecycleState(.running), .presentingPreview(.review))
        XCTAssertEqual(policy.receiveLifecycleState(.idle), .presentingLifecycle(.idle))
        XCTAssertNil(policy.previewState)
    }

    func testWindowFrameClampingKeepsFrameReachableAcrossDisplays() {
        let displays = [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: 1440, y: 0, width: 1920, height: 1080),
        ]
        let lostFrame = CGRect(x: 5000, y: 5000, width: 320, height: 480)
        let clamped = WindowFramePolicy.clamped(lostFrame, to: displays)
        XCTAssertTrue(displays.contains(where: { $0.intersects(clamped) }))
        XCTAssertEqual(clamped.width, lostFrame.width)
        XCTAssertEqual(clamped.height, lostFrame.height)

        let partiallyVisible = CGRect(x: -300, y: 120, width: 320, height: 480)
        let repaired = WindowFramePolicy.clamped(partiallyVisible, to: displays)
        let intersection = displays[0].intersection(repaired)
        XCTAssertGreaterThanOrEqual(intersection.width, 48)
        XCTAssertGreaterThanOrEqual(intersection.height, 48)

        let aboveDisplays = CGRect(x: 100, y: 1200, width: 320, height: 480)
        let belowRepaired = WindowFramePolicy.clamped(aboveDisplays, to: displays)
        XCTAssertTrue(displays.contains(where: { $0.intersects(belowRepaired) }))
    }

    func testConfiguredWindowSizeReplacesStalePersistedDimensionsOnly() {
        let stored = CGRect(x: 663, y: 336, width: 321, height: 480)
        let configured = CGSize(width: 320, height: 486)
        let restored = WindowFramePolicy.applyingConfiguredSize(configured, to: stored)
        XCTAssertEqual(restored.origin, stored.origin)
        XCTAssertEqual(restored.size, configured)
    }

    func testAlphaAuthoringCanvasDoesNotFollowResizableWindow() throws {
        let resizedWindow = try WindowConfiguration(width: 341, height: 511)

        XCTAssertEqual(resizedWindow.width, 341)
        XCTAssertEqual(resizedWindow.height, 511)
        XCTAssertEqual(AlphaAuthoringCanvas.width, 320)
        XCTAssertEqual(AlphaAuthoringCanvas.height, 480)
        XCTAssertEqual(AlphaAuthoringCanvas.width % 2, 0)
        XCTAssertEqual(AlphaAuthoringCanvas.height % 2, 0)
    }

    func testWindowFrameClampingHandlesNegativeVerticalAndRemovedDisplays() {
        let displays = [
            CGRect(x: -1920, y: -1080, width: 1920, height: 1080),
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: 0, y: 900, width: 1280, height: 720),
        ]
        let savedOnRemovedDisplay = CGRect(x: 4000, y: -2500, width: 320, height: 480)
        let clamped = WindowFramePolicy.clamped(savedOnRemovedDisplay, to: displays)
        XCTAssertTrue(displays.contains { visibleArea(of: clamped, in: $0) })

        let mostlyOffNegativeDisplay = CGRect(x: -2230, y: -1300, width: 320, height: 480)
        let repaired = WindowFramePolicy.clamped(mostlyOffNegativeDisplay, to: displays)
        XCTAssertTrue(displays.contains { visibleArea(of: repaired, in: $0) })

        let oversized = CGRect(x: 6000, y: 6000, width: 3000, height: 2400)
        let oversizedRepaired = WindowFramePolicy.clamped(oversized, to: displays)
        XCTAssertTrue(displays.contains { visibleArea(of: oversizedRepaired, in: $0) })
    }

    func testPlaybackSuspensionComposesReasonsAndPreservesResumeRate() {
        var policy = PlaybackSuspensionPolicy()
        XCTAssertEqual(policy.replacePlayback(rate: 0.75), .resume(rate: 0.75))
        XCTAssertEqual(policy.setSuspended(true, for: .windowOccluded), .pause)
        XCTAssertEqual(policy.setSuspended(true, for: .screenAsleep), .pause)
        XCTAssertEqual(policy.setSuspended(false, for: .windowOccluded), .none)
        XCTAssertFalse(policy.canStartReadinessDeadline)
        XCTAssertEqual(policy.setSuspended(false, for: .screenAsleep), .resume(rate: 0.75))
        XCTAssertTrue(policy.canStartReadinessDeadline)

        XCTAssertEqual(policy.setSuspended(true, for: .screenAsleep), .pause)
        XCTAssertEqual(policy.replacePlayback(rate: 1.25), .pause)
        XCTAssertEqual(policy.setSuspended(false, for: .screenAsleep), .resume(rate: 1.25))
        policy.clearPlayback()
        XCTAssertEqual(policy.setSuspended(true, for: .windowOccluded), .pause)
        XCTAssertEqual(policy.setSuspended(false, for: .windowOccluded), .none)
    }

    func testDisplayWakeRecoveryClearsStaleOcclusionBeforeRechecking() {
        XCTAssertEqual(
            DisplayWakeRecoveryPolicy.steps,
            [.clearWindowOcclusion, .clearScreenSleep, .recheckWindowOcclusion]
        )
    }

    func testBoundedLRUCacheEvictsLeastRecentlyUsedAndFileRevisionInvalidates() throws {
        var cache = BoundedLRUCache<Int, String>(capacity: 2)
        cache.insert("one", for: 1)
        cache.insert("two", for: 2)
        XCTAssertEqual(cache.value(for: 1), "one")
        cache.insert("three", for: 3)
        XCTAssertNil(cache.value(for: 2))
        XCTAssertEqual(cache.count, 2)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-runtime-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("clip.mov")
        XCTAssertNil(LocalFileRevision(url: file))
        try Data("first".utf8).write(to: file)
        let first = try XCTUnwrap(LocalFileRevision(url: file))
        try FileManager.default.removeItem(at: file)
        try Data("replacement-longer".utf8).write(to: file)
        let replacement = try XCTUnwrap(LocalFileRevision(url: file))
        XCTAssertNotEqual(first, replacement)
        XCTAssertTrue(LibraryRowRefreshPolicy.shouldRefresh(previous: [first], incoming: [replacement]))
    }

    func testLifecycleUIRefreshSkipsHeartbeatButTracksProducerBehindPreview() {
        XCTAssertFalse(LifecycleUIRefreshPolicy.shouldRefresh(
            previousProducerState: .running,
            incomingProducerState: .running,
            presentationWillRefresh: false
        ))
        XCTAssertTrue(LifecycleUIRefreshPolicy.shouldRefresh(
            previousProducerState: .running,
            incomingProducerState: .waiting,
            presentationWillRefresh: false
        ))
        XCTAssertTrue(LifecycleUIRefreshPolicy.shouldRefresh(
            previousProducerState: .running,
            incomingProducerState: .running,
            presentationWillRefresh: true
        ))
    }

    func testCharacterLibraryLegacyFallbackAndRoundTripKeepMediaMapUnchanged() throws {
        let library = CharacterLibrary.legacy
        XCTAssertEqual(library.activeCharacterID, "default")
        XCTAssertEqual(library.activeCharacter.name, "Default")
        XCTAssertEqual(library.activeCharacter.mapPath, "media-map.json")

        let encoded = try JSONEncoder().encode(library)
        XCTAssertEqual(try JSONDecoder().decode(CharacterLibrary.self, from: encoded), library)

        let legacyMap = try MediaMap(states: [.idle: MediaEntry(path: "idle.mov")])
        let mapObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyMap)) as? [String: Any]
        )
        XCTAssertNil(mapObject["characters"])
        XCTAssertNil(mapObject["active_character_id"])
        XCTAssertNotNil(mapObject["states"])
    }

    func testCharacterLibraryBootstrapsCustomRootMapBasename() throws {
        let library = try CharacterLibrary.legacy(mapPath: "custom.json")
        XCTAssertEqual(library.activeCharacter.mapPath, "custom.json")
        XCTAssertEqual(
            library.activeCharacter.resolvedMapURL(relativeTo: URL(fileURLWithPath: "/tmp/maps/custom.json")).path,
            "/tmp/maps/custom.json"
        )
        XCTAssertThrowsError(try CharacterLibrary.legacy(mapPath: "nested/custom.json"))
        XCTAssertThrowsError(try CharacterLibrary.legacy(mapPath: ".."))
        XCTAssertThrowsError(try CharacterLibrary.legacy(mapPath: "custom\\map.json"))
    }

    func testCharacterLibraryImmutableProfileIsolationSwitchAndDeleteGuard() throws {
        let original = CharacterLibrary.legacy
        let added = try original.addingCharacter(id: "chloe", name: "Chloe")
        XCTAssertEqual(original.characters.count, 1)
        XCTAssertEqual(added.character(id: "default")?.mapPath, "media-map.json")
        XCTAssertEqual(added.character(id: "chloe")?.mapPath, ".character-chloe.media-map.json")

        let renamed = try added.renamingCharacter(id: "chloe", to: "Chloe Prime")
        XCTAssertEqual(added.character(id: "chloe")?.name, "Chloe")
        XCTAssertEqual(renamed.character(id: "chloe")?.name, "Chloe Prime")
        let duplicated = try renamed.duplicatingCharacter(id: "chloe", as: "chloe-copy", name: "Chloe Copy")
        XCTAssertEqual(duplicated.character(id: "chloe-copy")?.mapPath, ".character-chloe-copy.media-map.json")

        let selected = try duplicated.selectingCharacter(id: "chloe")
        XCTAssertEqual(selected.activeCharacterID, "chloe")
        XCTAssertEqual(selected.activeCharacter.mapPath, ".character-chloe.media-map.json")
        let removedActive = try selected.removingCharacter(id: "chloe")
        XCTAssertEqual(removedActive.activeCharacterID, "default")
        XCTAssertNotNil(removedActive.character(id: "chloe-copy"))
        XCTAssertThrowsError(try CharacterLibrary.legacy.removingCharacter(id: "default"))
        XCTAssertThrowsError(try added.addingCharacter(id: "other", name: "CHLOE"))
        XCTAssertThrowsError(try added.addingCharacter(id: "../escape", name: "Escape"))
    }

    func testCharacterBundleRoundTripAndImportPathRewritePreserveGlobalMapSettings() throws {
        let window = try WindowConfiguration(width: 444, height: 555, clickThrough: true)
        let entry = try MediaEntry(
            path: "movies/idle.mov",
            posterPath: "posters/idle.png",
            playbackRate: 1.25
        )
        let map = try MediaMap(defaultFormat: "mov", window: window, states: [.idle: entry])
        let hash = String(repeating: "a", count: 64)
        let manifest = try CharacterBundleManifest(
            characterID: "chloe",
            characterName: "Chloe",
            mediaMap: map,
            assets: [
                CharacterBundleAsset(role: .movie, path: "movies/idle.mov", size: 1024, sha256: hash),
                CharacterBundleAsset(role: .poster, path: "posters/idle.png", size: 256, sha256: hash),
                CharacterBundleAsset(
                    role: .report,
                    path: "reports/idle.json",
                    size: 128,
                    sha256: hash,
                    moviePath: "movies/idle.mov"
                ),
            ]
        )
        let decoded = try CharacterBundleManifest.decode(JSONEncoder().encode(manifest))
        XCTAssertEqual(decoded, manifest)

        let imported = try decoded.mediaMap { "installed/\($0)" }
        XCTAssertEqual(imported.entry(for: .idle)?.path, "installed/movies/idle.mov")
        XCTAssertEqual(imported.entry(for: .idle)?.posterPath, "installed/posters/idle.png")
        XCTAssertEqual(imported.window, window)
        XCTAssertEqual(imported.defaultFormat, map.defaultFormat)
    }

    func testCharacterBundleRejectsTraversalCaseCollisionAndOversizedManifest() throws {
        let hash = String(repeating: "a", count: 64)
        let traversalMap = try MediaMap(states: [.idle: MediaEntry(path: "../idle.mov")])
        XCTAssertThrowsError(try CharacterBundleManifest(
            characterID: "chloe",
            characterName: "Chloe",
            mediaMap: traversalMap,
            assets: [CharacterBundleAsset(role: .movie, path: "../idle.mov", size: 1, sha256: hash)]
        ))

        let map = try MediaMap(states: [.idle: MediaEntry(path: "movies/idle.mov")])
        XCTAssertThrowsError(try CharacterBundleManifest(
            characterID: "chloe",
            characterName: "Chloe",
            mediaMap: map,
            assets: [
                CharacterBundleAsset(role: .movie, path: "movies/idle.mov", size: 1, sha256: hash),
                CharacterBundleAsset(role: .movie, path: "movies/IDLE.mov", size: 1, sha256: hash),
            ]
        ))
        XCTAssertThrowsError(try CharacterBundleManifest.decode(
            Data(repeating: 0x20, count: Int(CharacterBundleManifest.maximumManifestSize) + 1)
        ))
        XCTAssertThrowsError(try CharacterLibrary.legacy(mapPath: "bad\nmap.json"))
        XCTAssertThrowsError(try CharacterLibrary.legacy(
            mapPath: String(repeating: "a", count: CharacterBundlePath.maximumComponentBytes + 1)
        ))
    }

    func testCharacterBundleRejectsAbsentAndWrongRoleReferences() throws {
        let hash = String(repeating: "a", count: 64)
        let map = try MediaMap(states: [
            .idle: MediaEntry(path: "movies/idle.mov", posterPath: "posters/idle.png"),
        ])
        XCTAssertThrowsError(try CharacterBundleManifest(
            characterID: "chloe",
            characterName: "Chloe",
            mediaMap: map,
            assets: [
                CharacterBundleAsset(role: .poster, path: "movies/idle.mov", size: 1, sha256: hash),
                CharacterBundleAsset(role: .poster, path: "posters/idle.png", size: 1, sha256: hash),
            ]
        ))
        XCTAssertThrowsError(try CharacterBundleManifest(
            characterID: "chloe",
            characterName: "Chloe",
            mediaMap: map,
            assets: [
                CharacterBundleAsset(role: .movie, path: "movies/idle.mov", size: 1, sha256: hash),
                CharacterBundleAsset(role: .poster, path: "posters/idle.png", size: 1, sha256: hash),
                CharacterBundleAsset(role: .report, path: "reports/idle.json", size: 1, sha256: hash),
            ]
        ))
        XCTAssertThrowsError(try CharacterBundleManifest(
            characterID: "chloe",
            characterName: "Chloe",
            mediaMap: map,
            assets: [
                CharacterBundleAsset(role: .movie, path: "movies/idle.mov", size: 1, sha256: hash),
                CharacterBundleAsset(role: .poster, path: "posters/idle.png", size: 1, sha256: hash),
                CharacterBundleAsset(
                    role: .report,
                    path: "reports/idle.json",
                    size: 1,
                    sha256: hash,
                    moviePath: "movies/missing.mov"
                ),
            ]
        ))
        XCTAssertThrowsError(try CharacterBundleManifest(
            characterID: "chloe",
            characterName: "Chloe",
            mediaMap: map,
            assets: [
                CharacterBundleAsset(role: .movie, path: "movies/idle.mov", size: 1, sha256: hash),
                CharacterBundleAsset(role: .movie, path: "movies/unused.mov", size: 1, sha256: hash),
                CharacterBundleAsset(role: .poster, path: "posters/idle.png", size: 1, sha256: hash),
            ]
        ))
        XCTAssertThrowsError(try CharacterBundleManifest(
            characterID: "chloe",
            characterName: "Chloe",
            mediaMap: map,
            assets: [
                CharacterBundleAsset(role: .movie, path: "movies/idle.mov", size: 1, sha256: hash),
                CharacterBundleAsset(role: .poster, path: "posters/idle.png", size: 1, sha256: hash),
                CharacterBundleAsset(
                    role: .report,
                    path: "reports/first.json",
                    size: 1,
                    sha256: hash,
                    moviePath: "movies/idle.mov"
                ),
                CharacterBundleAsset(
                    role: .report,
                    path: "reports/second.json",
                    size: 1,
                    sha256: hash,
                    moviePath: "movies/idle.mov"
                ),
            ]
        ))
    }

    private func visibleArea(of frame: CGRect, in display: CGRect) -> Bool {
        let intersection = frame.intersection(display)
        return intersection.width >= 48 && intersection.height >= 48
    }

    private func assertReportError(
        _ json: String,
        expectedOutputBasename: String = "idle.mov",
        actualOutputSHA256: String,
        expectedLocalProvenanceChallenge: String? = nil,
        equals expected: AlphaConversionReportValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try AlphaConversionReportValidator.validate(
                data: Data(json.utf8),
                expectedOutputBasename: expectedOutputBasename,
                actualOutputSHA256: actualOutputSHA256,
                expectedLocalProvenanceChallenge: expectedLocalProvenanceChallenge
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? AlphaConversionReportValidationError,
                expected,
                file: file,
                line: line
            )
        }
    }
}
