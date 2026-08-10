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
      "toolchain":{"converter_version":"1","ffmpeg_version":"ffmpeg version 8.0","ffprobe_version":"ffprobe version 8.0","avconvert_version":"avconvert help"},
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
    }

    func testPetAppearanceDecodesDefaultsNormalizesAndRoundTrips() throws {
        let json = ##"{"background_color":"#a1b2c3","border_color":"#dEf012","border_enabled":false,"border_width":4.5,"corner_radius":31,"show_state_label":false,"state_label_position":"bottom_right","state_label_size":"large","state_label_color":"#1a2B3c","show_fps":false,"fps_color":"#00eE77","fps_label_size":"regular"}"##.data(using: .utf8)!
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

        let encoded = try JSONEncoder().encode(appearance)
        XCTAssertEqual(try JSONDecoder.codexPet.decode(PetAppearanceConfiguration.self, from: encoded), appearance)
    }

    func testPetAppearanceRejectsInvalidColorsAndRanges() throws {
        for color in ["20242A", "#FFF", "#GGGGGG", "#1234567", "#12345Z"] {
            XCTAssertThrowsError(try PetAppearanceConfiguration(backgroundColor: color), "accepted \(color)")
            XCTAssertThrowsError(try PetAppearanceConfiguration(borderColor: color), "accepted \(color)")
            XCTAssertThrowsError(try PetAppearanceConfiguration(fpsColor: color), "accepted \(color)")
            XCTAssertThrowsError(try PetAppearanceConfiguration(stateLabelColor: color), "accepted \(color)")
        }
        for opacity in [-0.01, 1.01, .infinity, .nan] {
            XCTAssertThrowsError(try PetAppearanceConfiguration(backgroundOpacity: opacity))
            XCTAssertThrowsError(try PetAppearanceConfiguration(borderOpacity: opacity))
        }
        for width in [-0.01, 12.01, .infinity, .nan] {
            XCTAssertThrowsError(try PetAppearanceConfiguration(borderWidth: width))
        }
        for radius in [-0.01, 256.01, .infinity, .nan] {
            XCTAssertThrowsError(try PetAppearanceConfiguration(cornerRadius: radius))
        }
        XCTAssertNoThrow(try PetAppearanceConfiguration(backgroundOpacity: 0, borderOpacity: 1, borderWidth: 12, cornerRadius: 256))
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
                of: "\"toolchain\":{\"converter_version\":\"1\",\"ffmpeg_version\":\"ffmpeg version 8.0\",\"ffprobe_version\":\"ffprobe version 8.0\",\"avconvert_version\":\"avconvert help\"},",
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
        let original = try MediaMap(
            defaultFormat: "mov",
            window: originalWindow,
            states: [.idle: idle, .running: running]
        )
        let imported = try MediaEntry(path: "imports/idle-v2.mov", loop: true)
        let withImport = try original.replacingEntry(for: .idle, with: imported)
        XCTAssertEqual(withImport.entry(for: .idle), imported)
        XCTAssertEqual(withImport.entry(for: .running), running)
        XCTAssertEqual(withImport.window, originalWindow)
        XCTAssertEqual(withImport.defaultFormat, original.defaultFormat)
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
        XCTAssertEqual(original.window, originalWindow)

        XCTAssertEqual(MediaMapChangeImpact.decide(previous: original, incoming: original), .unchanged)
        XCTAssertEqual(MediaMapChangeImpact.decide(previous: original, incoming: withWindow), .windowOnly)
        XCTAssertFalse(MediaMapChangeImpact.decide(previous: original, incoming: withWindow).shouldRefreshPlayback)
        XCTAssertEqual(MediaMapChangeImpact.decide(previous: original, incoming: withImport), .playback)
        XCTAssertTrue(MediaMapChangeImpact.decide(previous: original, incoming: withImport).shouldRefreshPlayback)
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
