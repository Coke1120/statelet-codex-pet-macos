import CodexPetCore
import CoreGraphics
import Dispatch
import Foundation

private enum SelfTestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case let .assertion(message): return message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw SelfTestFailure.assertion(message) }
}

private func requiresError(_ message: String, _ operation: () throws -> Void) throws {
    do {
        try operation()
    } catch {
        return
    }
    throw SelfTestFailure.assertion(message)
}

private func hasReachableArea(_ frame: CGRect, displays: [CGRect]) -> Bool {
    displays.contains {
        let intersection = $0.intersection(frame)
        return intersection.width >= 48 && intersection.height >= 48
    }
}

private let sourceHash = String(repeating: "a", count: 64)
private let outputHash = String(repeating: "b", count: 64)
private let provenanceChallenge = String(repeating: "c", count: 64)

private func validAlphaReportJSON() -> String {
    """
    {
      "report_schema_version":1,
      "status":"converted",
      "toolchain":{"converter_version":"1","ffmpeg_version":"ffmpeg version 8.0","ffprobe_version":"ffprobe version 8.0","avconvert_version":"avconvert help","macos_build":"23G93"},
      "tool_capabilities":{"ffmpeg_encoder":"prores_ks","ffmpeg_filters":["scale","crop","pad"],"avconvert_presets":["PresetHEVCHighestQualityWithAlpha","PresetAppleProRes4444LPCM"],"passed":true},
      "profile":{"name":"standard","framing":"fill","keying":"green-screen-continuous-alpha"},
      "normalization":{"applied":["strip-audio","square-pixel-output"],"warnings":["rotation-sar-vfr-hdr-interlace-rejected-before-decode"]},
      "provenance":{"method":"invocation-challenge-v1","producer":"statelet","challenge":"\(provenanceChallenge)"},
      "source":{"audio":{"stream_count":1,"codecs":["aac"],"policy":"stripped"}},
      "geometry":{"width":320,"height":486,"pixel_format":"straight-rgba"},
      "geometry_alignment":{"requested_width":321,"requested_height":487,"policy":"floor_to_even","adjusted":true},
      "quality":{"loop_seam":{"performed":true,"exact_match":false,"differing_pixels":120,"mean_absolute_error":0.5,"maximum_absolute_error":12,"policy":"informational"}},
      "codec":{"delivery":"HEVC with alpha"},
      "verification":{
        "performed":true,
        "unsafe":false,
        "frames_verified":241,
        "maximum_outer_edge_alpha":1,
        "delivery":{"codec":"hevc","profile":"Main","width":320,"height":486,"frames":241,"fps":"24/1","quality_passed":true},
        "roundtrip":{"codec":"prores","profile":"4444","width":320,"height":486,"frames":241,"fps":"24/1","quality_passed":true},
        "alpha":{"mean_absolute_error_max":0.2,"p95_absolute_error_max":1.0,"maximum_absolute_error_max":20,"lost_alpha_pixels_total":0,"tolerances":{"max_border_alpha":8,"max_mean_abs_error":8.0,"max_p95_abs_error":24.0,"max_abs_error":64}},
        "composite":{"performed":true,"background_names":["white","black","checkerboard"],"frames_checked":241,"maximum_introduced_green_fringe_ratio":0.001,"maximum_introduced_magenta_fringe_ratio":0.002,"maximum_introduced_green_fringe_excess":2,"maximum_introduced_magenta_fringe_excess":3,"reference_comparison":true,"quality_passed":true,"limits":{"max_introduced_green_fringe_ratio":0.01,"max_introduced_magenta_fringe_ratio":0.01,"max_introduced_green_fringe_excess":16,"max_introduced_magenta_fringe_excess":16}}
      },
      "artifacts":{"source_sha256":"\(sourceHash)","source_sha256_before_probe":"\(sourceHash)","source_sha256_before_publication":"\(sourceHash)","output_name":"idle.mov","output_sha256":"\(outputHash)"}
    }
    """
}

private func runDialogueVoiceSelfTest() throws {
    let profileID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let lineID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let profile = try GPTSoVITSVoiceProfile(
        id: profileID,
        revision: 1,
        name: "Self-test voice",
        apiBaseURL: URL(string: "http://127.0.0.1:9880")!,
        gptWeightRelativePath: "voice/assets/gpt/model.ckpt",
        sovitsWeightRelativePath: "voice/assets/sovits/model.pth",
        referenceAudioRelativePath: "voice/assets/reference/reference.wav",
        referenceText: "Reference",
        promptLanguage: "en",
        defaultTextLanguage: "en",
        inputFingerprint: String(repeating: "a", count: 64)
    )
    var library = try DialogueVoiceLibrary(profile: profile)
    _ = try library.addLine(text: "Hello", id: lineID)
    try require(
        library.playbackSettings == .defaults
            && library.playbackSettings.automaticPlaybackEnabled
            && library.playbackSettings.volume == 1
            && library.playbackSettings.repeatIntervalSeconds == nil,
        "dialogue playback settings did not preserve existing defaults"
    )
    try requiresError("dialogue playback settings accepted a non-finite volume") {
        _ = try DialogueVoicePlaybackSettings(volume: .nan)
    }
    let playbackSettings = try DialogueVoicePlaybackSettings(
        automaticPlaybackEnabled: false,
        volume: 0.4,
        repeatIntervalSeconds: 30
    )
    let unchangedProfile = library.profile
    let unchangedLines = library.lines
    library.updatePlaybackSettings(playbackSettings)
    try require(
        library.playbackSettings == playbackSettings
            && library.profile == unchangedProfile
            && library.lines == unchangedLines,
        "updating dialogue playback settings changed voice content"
    )
    let roundTripped = try JSONDecoder().decode(
        DialogueVoiceLibrary.self,
        from: JSONEncoder().encode(library)
    )
    try require(roundTripped == library, "dialogue playback settings did not round-trip")
    var legacyObject = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(library)
    ) as! [String: Any]
    legacyObject.removeValue(forKey: "playback_settings")
    let migrated = try JSONDecoder().decode(
        DialogueVoiceLibrary.self,
        from: JSONSerialization.data(withJSONObject: legacyObject)
    )
    try require(
        migrated.version == DialogueVoiceLibrary.schemaVersion
            && migrated.playbackSettings == .defaults,
        "legacy dialogue playback settings did not migrate to defaults"
    )
    let staleTicket = try library.beginGeneration(for: lineID)
    _ = try library.editLine(id: lineID, text: "Hello again")
    try requiresError("late dialogue generation result was accepted") {
        _ = try library.completeGeneration(ticket: staleTicket, outputPath: "voice/generated/late.wav")
    }
    let currentTicket = try library.beginGeneration(for: lineID)
    _ = try library.completeGeneration(
        ticket: currentTicket,
        outputPath: "voice/generated/current.wav"
    )
    try require(library.lines.first?.status == .ready, "dialogue output did not become ready")
    let resolvedOutput = try library.outputURL(
        for: lineID,
        relativeTo: URL(fileURLWithPath: "/managed/root")
    )
    try require(
        resolvedOutput.path == "/managed/root/voice/generated/current.wav",
        "ready dialogue output did not resolve inside the managed root"
    )
    try requiresError("cleanup accepted the active GPT weight") {
        try library.enqueueCleanup(paths: [profile.gptWeightRelativePath])
    }
    try requiresError("cleanup accepted the current dialogue output") {
        try library.enqueueCleanup(paths: ["voice/generated/current.wav"])
    }
    try requiresError("library accepted an overlapping cleanup tombstone") {
        _ = try DialogueVoiceLibrary(
            profile: profile,
            lines: library.lines,
            pendingCleanupPaths: ["voice/generated/current.wav"]
        )
    }

    var collidingOutputLibrary = try DialogueVoiceLibrary(profile: profile)
    _ = try collidingOutputLibrary.addLine(text: "Collision", id: UUID())
    try collidingOutputLibrary.enqueueCleanup(paths: ["voice/generated/collision.wav"])
    let collidingTicket = try collidingOutputLibrary.beginGeneration(
        for: collidingOutputLibrary.lines[0].id
    )
    try requiresError("generation published an output queued for cleanup") {
        _ = try collidingOutputLibrary.completeGeneration(
            ticket: collidingTicket,
            outputPath: "voice/generated/collision.wav"
        )
    }
    try requiresError("remote voice endpoint was accepted") {
        _ = try GPTSoVITSVoiceProfile(
            name: "Remote",
            apiBaseURL: URL(string: "http://example.com:9880")!,
            gptWeightRelativePath: "voice/assets/gpt/model.ckpt",
            sovitsWeightRelativePath: "voice/assets/sovits/model.pth",
            referenceAudioRelativePath: "voice/assets/reference/reference.wav",
            referenceText: "Reference",
            promptLanguage: "en",
            defaultTextLanguage: "en",
            inputFingerprint: String(repeating: "a", count: 64)
        )
    }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("statelet-dialogue-self-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DialogueVoiceStore(rootURL: root)
    try store.save(library)
    let loadedLibrary = try store.load()
    try require(loadedLibrary == library, "dialogue voice store did not round-trip")
    let directoryMode = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions]
        as? NSNumber
    let fileMode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions]
        as? NSNumber
    try require(((directoryMode?.intValue ?? 0) & 0o777) == 0o700, "dialogue store directory is not private")
    try require(((fileMode?.intValue ?? 0) & 0o777) == 0o600, "dialogue store file is not private")
}

private func runSelfTest() throws {
    try runDialogueVoiceSelfTest()
    var progressParser = AlphaConversionProgressParser()
    let noiseProgress = try progressParser.parseLine("converter startup noise")
    try require(noiseProgress == nil, "progress parser accepted noise")
    let finalJSONProgress = try progressParser.parseLine(#"{"status":"converted","output":"idle.mov"}"#)
    try require(
        finalJSONProgress == nil,
        "progress parser accepted final JSON"
    )
    try requiresError("malformed structured progress was accepted") {
        _ = try progressParser.parseLine(
            #"{"event":"progress","percent":25,"stage":"decode","message":"Reading frames""#
        )
    }
    let progress = try progressParser.parseLine(
        #"{"event":"progress","percent":25,"stage":"decode","message":"Reading /Users/person/private/source.mp4","completed_frames":6,"total_frames":24}"#
    )
    try require(progress?.percent == 25, "progress percent was not decoded")
    try require(progress?.message == "Reading <local-file>", "progress message exposed a local path")
    try require(progress?.completedFrames == 6 && progress?.totalFrames == 24, "progress frame counts changed")
    let delimitedProgress = try AlphaConversionProgress(
        percent: 25,
        stage: "decode",
        message: #"source=/secret.mov home=~/secret.mov ("file:///secret.mov") Frame 3/24"#
    )
    try require(
        delimitedProgress.message == #"source=<local-file> home=<local-file> ("<local-file>") Frame 3/24"#,
        "delimited progress paths were not redacted"
    )
    let extensionlessProgress = try AlphaConversionProgress(
        percent: 25,
        stage: "decode",
        message: #"failed /Users/leoho/My Folder/tool and '/Users/leoho/My Folder/tool'"#
    )
    try require(
        !extensionlessProgress.message.contains("/Users/")
            && !extensionlessProgress.message.contains("My Folder"),
        "extensionless spaced progress path leaked"
    )
    try requiresError("regressing progress was accepted") {
        _ = try progressParser.parseLine(
            #"{"event":"progress","percent":24,"stage":"decode","message":"Reading frames"}"#
        )
    }
    let resumedProgress = try progressParser.parseLine(
        #"{"event":"progress","percent":30,"stage":"decode","message":"Reading frames"}"#
    )
    try require(
        resumedProgress?.percent == 30,
        "valid progress after a rejected event was lost"
    )
    let terminalFailure = try progressParser.parseLine(
        #"{"event":"progress","status":"failed","percent":30,"stage":"verify","message":"Failed /Users/leoho/My Videos/foo.mp4","code":"QUALITY_GATE_FAILED","safe_message":"Failed '/Users/leoho/My Videos/foo.mp4'"}"#
    )
    try require(terminalFailure?.isTerminalFailure == true, "terminal failure was not retained")
    try require(terminalFailure?.code == "QUALITY_GATE_FAILED", "failure category changed")
    try require(terminalFailure?.stage == "verify", "failure stage changed")
    try require(terminalFailure?.message == "Failed <local-file>", "failure progress path leaked")
    try require(terminalFailure?.safeMessage == "Failed '<local-file>'", "failure detail path leaked")
    for malformedFailure in [
        #"{"event":"progress","status":"failed","percent":30,"stage":"verify","message":"Failed","code":"UNKNOWN","safe_message":"Failed"}"#,
        #"{"event":"progress","status":"failed","percent":30,"stage":"/Users/private","message":"Failed","code":"CONVERSION_FAILED","safe_message":"Failed"}"#,
        #"{"event":"progress","status":"failed","percent":30,"stage":"verify","message":"Failed","code":"CONVERSION_FAILED"}"#,
        #"{"event":"progress","status":"running","percent":30,"stage":"verify","message":"Working","code":"CONVERSION_FAILED","safe_message":"Failed"}"#,
    ] {
        try requiresError("malformed terminal progress failure was accepted") {
            var malformedParser = AlphaConversionProgressParser()
            _ = try malformedParser.parseLine(malformedFailure)
        }
    }
    try requiresError("oversized terminal safe message was accepted") {
        var malformedParser = AlphaConversionProgressParser()
        _ = try malformedParser.parseLine(
            #"{"event":"progress","status":"failed","percent":30,"stage":"verify","message":"Failed","code":"CONVERSION_FAILED","safe_message":"\#(String(repeating: "x", count: 257))"}"#
        )
    }

    let removalRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-pet-removal-self-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: removalRoot) }
    let removalDirectory = removalRoot.appendingPathComponent("imports/item", isDirectory: true)
    try FileManager.default.createDirectory(at: removalDirectory, withIntermediateDirectories: true)
    let removalMapURL = removalRoot.appendingPathComponent("media-map.json")
    let removalMovieURL = removalDirectory.appendingPathComponent("clip.mov")
    let removalReportURL = removalDirectory.appendingPathComponent("clip.report.json")
    try Data("{}".utf8).write(to: removalMapURL)
    try Data("movie".utf8).write(to: removalMovieURL)
    try Data("report".utf8).write(to: removalReportURL)
    let removalEntry = try MediaEntry(path: "imports/item/clip.mov")
    let removalMap = try MediaMap(states: [.running: removalEntry])
    let removalPlan = try ManagedMediaRemovalPlanner.plan(
        mediaMap: removalMap,
        mapURL: removalMapURL,
        state: .running,
        path: removalEntry.path,
        canonicalRoot: removalRoot
    )
    try require(removalPlan.updatedMap.playlist(for: .running) == nil, "last clip removal kept an empty state")
    try require(
        removalPlan.trashURLs.map(\.lastPathComponent) == ["clip.mov", "clip.report.json"],
        "managed removal did not select the movie and verification report"
    )
    let symlinkURL = removalDirectory.appendingPathComponent("linked.mov")
    try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: removalMovieURL)
    let symlinkEntry = try MediaEntry(path: "imports/item/linked.mov")
    let symlinkMap = try MediaMap(states: [.running: symlinkEntry])
    try requiresError("managed removal accepted a symbolic-link movie") {
        _ = try ManagedMediaRemovalPlanner.plan(
            mediaMap: symlinkMap,
            mapURL: removalMapURL,
            state: .running,
            path: symlinkEntry.path,
            canonicalRoot: removalRoot
        )
    }
    for unsafePath in [
        "media-map.json",
        "imports/item/clip.report.json",
        "imports/item/clip.poster.png",
        "imports/item/clip.mp4",
    ] {
        let unsafeURL = removalRoot.appendingPathComponent(unsafePath)
        if !FileManager.default.fileExists(atPath: unsafeURL.path) {
            try Data("unsafe".utf8).write(to: unsafeURL)
        }
        let unsafeEntry = try MediaEntry(path: unsafePath)
        let unsafeMap = try MediaMap(states: [.running: unsafeEntry])
        try requiresError("managed removal accepted reserved target \(unsafePath)") {
            _ = try ManagedMediaRemovalPlanner.plan(
                mediaMap: unsafeMap,
                mapURL: removalMapURL,
                state: .running,
                path: unsafeEntry.path,
                canonicalRoot: removalRoot
            )
        }
    }
    try FileManager.default.removeItem(at: removalReportURL)
    let missingReportURL = removalRoot.appendingPathComponent("missing-report.json")
    try FileManager.default.createSymbolicLink(
        at: removalReportURL,
        withDestinationURL: missingReportURL
    )
    try requiresError("managed removal accepted a dangling report symlink") {
        _ = try ManagedMediaRemovalPlanner.plan(
            mediaMap: removalMap,
            mapURL: removalMapURL,
            state: .running,
            path: removalEntry.path,
            canonicalRoot: removalRoot
        )
    }

    let macDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let fixtureURL = macDirectory.appendingPathComponent("contracts/current_state-v1.example.json")
    let canonical = try JSONDecoder.codexPet.decode(CurrentState.self, from: Data(contentsOf: fixtureURL))
    try require(canonical.state == .running, "canonical fixture state was not decoded")
    try require(canonical.sourceUpdatedAt == 1_710_000_000, "canonical fixture source timestamp was not decoded")
    try require(canonical.emittedAt == 1_710_000_000.25, "canonical fixture emission timestamp was not decoded")
    try require(canonical.activeSessions == 2, "canonical fixture session count was not decoded")

    let idleJSON = Data(#"{"version":1,"schema_version":1,"state":"idle","source_updated_at":null,"emitted_at":1710000001}"#.utf8)
    let idle = try JSONDecoder.codexPet.decode(CurrentState.self, from: idleJSON)
    try require(idle.sourceUpdatedAt == nil, "idle null source timestamp was not preserved")

    let legacyJSON = Data(#"{"version":1,"state":"review","updated_at":1710000002}"#.utf8)
    let legacy = try JSONDecoder.codexPet.decode(CurrentState.self, from: legacyJSON)
    try require(legacy.emittedAt == 1_710_000_002, "legacy updated_at was not used as publication time")

    let missingTimestamp = Data(#"{"version":1,"state":"idle","source_updated_at":null}"#.utf8)
    try requiresError("state without emitted_at or updated_at was accepted") {
        _ = try JSONDecoder.codexPet.decode(CurrentState.self, from: missingTimestamp)
    }
    try requiresError("infinite updated_at was accepted") {
        _ = try CurrentState(state: .idle, updatedAt: .infinity)
    }
    try requiresError("NaN emitted_at was accepted") {
        _ = try CurrentState(state: .idle, emittedAt: .nan)
    }
    try requiresError("NaN source_updated_at was accepted") {
        _ = try CurrentState(state: .running, sourceUpdatedAt: .nan, emittedAt: 1)
    }

    let freshness = try StateFreshnessPolicy()
    try require(freshness.maximumAge == 150, "production freshness window changed unexpectedly")
    try require(
        freshness.freshness(emittedAt: 850, now: 1_000) == .fresh,
        "publication at maximum age was not accepted"
    )
    try require(
        freshness.freshness(emittedAt: 849.999, now: 1_000) == .stale,
        "publication beyond maximum age was accepted"
    )
    try require(
        freshness.freshness(emittedAt: 1_060, now: 1_000) == .fresh,
        "publication at future-skew boundary was not accepted"
    )
    try require(
        freshness.freshness(emittedAt: 1_060.001, now: 1_000) == .futureSkew,
        "publication beyond future-skew boundary was accepted"
    )
    try requiresError("non-positive state maximum age was accepted") {
        _ = try StateFreshnessPolicy(maximumAge: 0)
    }
    try requiresError("negative state future skew was accepted") {
        _ = try StateFreshnessPolicy(maximumFutureSkew: -1)
    }

    try require(
        StatePresentationDecision.decide(lastPresentedState: nil, incomingState: .idle) == .initial,
        "initial idle presentation was suppressed"
    )
    try require(
        StatePresentationDecision.decide(lastPresentedState: .idle, incomingState: .idle) == .unchanged,
        "same-state heartbeat requested a playback rebuild"
    )
    try require(
        StatePresentationDecision.decide(
            lastPresentedState: nil,
            pendingState: .running,
            incomingState: .running
        ) == .unchanged,
        "same-state heartbeat restarted pending playback"
    )
    try require(
        StatePresentationDecision.decide(lastPresentedState: .idle, incomingState: .running) == .stateChanged,
        "state transition did not request a playback rebuild"
    )
    try require(
        StatePresentationDecision.decide(
            lastPresentedState: .running,
            incomingState: .running,
            forceRefresh: true
        ) == .forcedRefresh,
        "forced same-state refresh was suppressed"
    )

    var readiness = PresentationReadinessTracker()
    try require(readiness.receive(.displayReady) == .noChange, "display-only readiness committed presentation")
    try require(readiness.state == .preparing, "display-only readiness left preparing state")
    try require(readiness.receive(.itemReady) == .becameReady, "two readiness gates did not commit presentation")
    try require(readiness.receive(.itemReady) == .noChange, "duplicate item readiness emitted twice")
    try require(readiness.receive(.failure) == .becameFailed, "post-ready playback failure was ignored")
    try require(readiness.receive(.failure) == .noChange, "duplicate playback failure emitted twice")

    var failedReadiness = PresentationReadinessTracker()
    try require(failedReadiness.receive(.itemReady) == .noChange, "item-only readiness committed presentation")
    try require(failedReadiness.receive(.failure) == .becameFailed, "pre-ready failure was ignored")
    try require(failedReadiness.receive(.displayReady) == .noChange, "failed presentation later became ready")

    let validated = try AlphaConversionReportValidator.validate(
        data: Data(validAlphaReportJSON().utf8),
        expectedOutputBasename: "idle.mov",
        actualOutputSHA256: outputHash.uppercased()
    )
    try require(validated.outputSHA256 == outputHash, "validated output hash was not normalized")
    try require(validated.sourceSHA256 == sourceHash, "validated source hash changed")
    try require(validated.frames == 241, "validated frame count changed")
    try require(validated.width == 320 && validated.height == 486, "validated geometry changed")
    try require(validated.reportSchemaVersion == 1, "report schema version changed")
    try require(validated.trust == .portableClaim, "portable report gained local trust")
    try require(validated.toolchain?.converterVersion == "1", "toolchain metadata changed")
    try require(validated.toolchain?.macOSBuild == "23G93", "macOS build metadata changed")
    try require(
        validated.toolCapabilities?.ffmpegFilters == ["scale", "crop", "pad"],
        "tool capability metadata changed"
    )
    try require(validated.profile?.name == "standard", "profile metadata changed")
    try require(
        validated.normalization?.applied == ["strip-audio", "square-pixel-output"],
        "normalization metadata changed"
    )
    try require(
        validated.notices == [
            .audioStripped(streamCount: 1),
            .loopMayJump(differingPixels: 120),
            .canvasAdjusted(
                requestedWidth: 321,
                requestedHeight: 487,
                outputWidth: 320,
                outputHeight: 486
            ),
        ],
        "validated conversion notices changed"
    )
    let playbackProbe = try AlphaPlaybackAcceptanceValidator.validate(
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
        expected: validated
    )
    try require(playbackProbe.decodedFirstFrame, "playback smoke probe lost decode evidence")
    try requiresError("wrong playback geometry was accepted") {
        _ = try AlphaPlaybackAcceptanceValidator.validate(
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
            expected: validated
        )
    }
    try requiresError("playback delivery with audio was accepted") {
        _ = try AlphaPlaybackAcceptanceValidator.validate(
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
            expected: validated
        )
    }
    guard var legacyReport = try JSONSerialization.jsonObject(
        with: Data(validAlphaReportJSON().utf8)
    ) as? [String: Any] else {
        throw SelfTestFailure.assertion("valid report fixture is not a JSON object")
    }
    legacyReport.removeValue(forKey: "source")
    legacyReport.removeValue(forKey: "geometry_alignment")
    legacyReport.removeValue(forKey: "quality")
    legacyReport.removeValue(forKey: "report_schema_version")
    legacyReport.removeValue(forKey: "toolchain")
    legacyReport.removeValue(forKey: "tool_capabilities")
    legacyReport.removeValue(forKey: "profile")
    legacyReport.removeValue(forKey: "normalization")
    legacyReport.removeValue(forKey: "provenance")
    let legacyValidated = try AlphaConversionReportValidator.validate(
        data: try JSONSerialization.data(withJSONObject: legacyReport),
        expectedOutputBasename: "idle.mov",
        actualOutputSHA256: outputHash
    )
    try require(
        legacyValidated.notices.isEmpty,
        "legacy report gained informational notices"
    )
    try require(legacyValidated.trust == .legacyPortableClaim, "legacy report gained trust")
    let locallyAttested = try AlphaConversionReportValidator.validate(
        data: Data(validAlphaReportJSON().utf8),
        expectedOutputBasename: "idle.mov",
        actualOutputSHA256: outputHash,
        expectedLocalProvenanceChallenge: provenanceChallenge.uppercased()
    )
    try require(locallyAttested.trust == .locallyAttested, "matching local challenge was not attested")
    guard var missingProvenanceReport = try JSONSerialization.jsonObject(
        with: Data(validAlphaReportJSON().utf8)
    ) as? [String: Any] else {
        throw SelfTestFailure.assertion("valid report was not a JSON object")
    }
    missingProvenanceReport.removeValue(forKey: "provenance")
    do {
        _ = try AlphaConversionReportValidator.validate(
            data: try JSONSerialization.data(withJSONObject: missingProvenanceReport),
            expectedOutputBasename: "idle.mov",
            actualOutputSHA256: outputHash,
            expectedLocalProvenanceChallenge: provenanceChallenge
        )
        throw SelfTestFailure.assertion("local report without provenance was accepted")
    } catch let error as AlphaConversionReportValidationError {
        try require(error == .provenanceRequired, "missing local provenance reported the wrong error")
    }
    try requiresError("future report schema was accepted") {
        let report = validAlphaReportJSON().replacingOccurrences(
            of: "\"report_schema_version\":1",
            with: "\"report_schema_version\":2"
        )
        _ = try AlphaConversionReportValidator.validate(
            data: Data(report.utf8),
            expectedOutputBasename: "idle.mov",
            actualOutputSHA256: outputHash
        )
    }
    try requiresError("explicit legacy schema was accepted") {
        let report = validAlphaReportJSON().replacingOccurrences(
            of: "\"report_schema_version\":1",
            with: "\"report_schema_version\":0"
        )
        _ = try AlphaConversionReportValidator.validate(
            data: Data(report.utf8),
            expectedOutputBasename: "idle.mov",
            actualOutputSHA256: outputHash
        )
    }
    try requiresError("mismatched local challenge was accepted") {
        _ = try AlphaConversionReportValidator.validate(
            data: Data(validAlphaReportJSON().utf8),
            expectedOutputBasename: "idle.mov",
            actualOutputSHA256: outputHash,
            expectedLocalProvenanceChallenge: String(repeating: "d", count: 64)
        )
    }
    try requiresError("portable report with malformed provenance method was accepted") {
        let report = validAlphaReportJSON().replacingOccurrences(
            of: "\"method\":\"invocation-challenge-v1\"",
            with: "\"method\":\"self-asserted\""
        )
        _ = try AlphaConversionReportValidator.validate(
            data: Data(report.utf8),
            expectedOutputBasename: "idle.mov",
            actualOutputSHA256: outputHash
        )
    }
    try requiresError("portable report with malformed provenance producer was accepted") {
        let report = validAlphaReportJSON().replacingOccurrences(
            of: "\"producer\":\"statelet\"",
            with: "\"producer\":\"external\""
        )
        _ = try AlphaConversionReportValidator.validate(
            data: Data(report.utf8),
            expectedOutputBasename: "idle.mov",
            actualOutputSHA256: outputHash
        )
    }
    try requiresError("portable report with noncanonical provenance challenge was accepted") {
        let report = validAlphaReportJSON().replacingOccurrences(
            of: "\"challenge\":\"\(provenanceChallenge)\"",
            with: "\"challenge\":\"\(provenanceChallenge.uppercased())\""
        )
        _ = try AlphaConversionReportValidator.validate(
            data: Data(report.utf8),
            expectedOutputBasename: "idle.mov",
            actualOutputSHA256: outputHash
        )
    }
    try requiresError("schema-v1 report without macOS build was accepted") {
        let report = validAlphaReportJSON().replacingOccurrences(
            of: ",\"macos_build\":\"23G93\"",
            with: ""
        )
        _ = try AlphaConversionReportValidator.validate(
            data: Data(report.utf8),
            expectedOutputBasename: "idle.mov",
            actualOutputSHA256: outputHash
        )
    }
    try requiresError("schema-v1 report with oversized macOS build was accepted") {
        let report = validAlphaReportJSON().replacingOccurrences(
            of: "\"macos_build\":\"23G93\"",
            with: "\"macos_build\":\"\(String(repeating: "A", count: 257))\""
        )
        _ = try AlphaConversionReportValidator.validate(
            data: Data(report.utf8),
            expectedOutputBasename: "idle.mov",
            actualOutputSHA256: outputHash
        )
    }
    try requiresError("schema-v1 report without tool capabilities was accepted") {
        guard var report = try JSONSerialization.jsonObject(
            with: Data(validAlphaReportJSON().utf8)
        ) as? [String: Any] else {
            throw SelfTestFailure.assertion("valid report fixture is not a JSON object")
        }
        report.removeValue(forKey: "tool_capabilities")
        _ = try AlphaConversionReportValidator.validate(
            data: try JSONSerialization.data(withJSONObject: report),
            expectedOutputBasename: "idle.mov",
            actualOutputSHA256: outputHash
        )
    }
    for invalidCapability in [
        ("\"ffmpeg_encoder\":\"prores_ks\"", "\"ffmpeg_encoder\":\"prores_aw\""),
        ("[\"scale\",\"crop\",\"pad\"]", "[\"scale\",\"pad\"]"),
        ("[\"PresetHEVCHighestQualityWithAlpha\",\"PresetAppleProRes4444LPCM\"]", "[\"PresetHEVCHighestQualityWithAlpha\"]"),
        ("\"passed\":true", "\"passed\":false"),
    ] {
        try requiresError("malformed schema-v1 tool capability contract was accepted") {
            let report = validAlphaReportJSON().replacingOccurrences(
                of: invalidCapability.0,
                with: invalidCapability.1
            )
            _ = try AlphaConversionReportValidator.validate(
                data: Data(report.utf8),
                expectedOutputBasename: "idle.mov",
                actualOutputSHA256: outputHash
            )
        }
    }
    try requiresError("oversized conversion report was accepted") {
        _ = try AlphaConversionReportValidator.validate(
            data: Data(
                repeating: 0x20,
                count: AlphaConversionReportValidator.maximumReportBytes + 1
            ),
            expectedOutputBasename: "idle.mov",
            actualOutputSHA256: outputHash
        )
    }
    try requiresError("unsafe conversion report was accepted") {
        let report = validAlphaReportJSON().replacingOccurrences(of: "\"unsafe\":false", with: "\"unsafe\":true")
        _ = try AlphaConversionReportValidator.validate(
            data: Data(report.utf8),
            expectedOutputBasename: "idle.mov",
            actualOutputSHA256: outputHash
        )
    }
    try requiresError("source mutation was accepted") {
        let report = validAlphaReportJSON().replacingOccurrences(
            of: "\"source_sha256_before_publication\":\"\(sourceHash)\"",
            with: "\"source_sha256_before_publication\":\"\(String(repeating: "c", count: 64))\""
        )
        _ = try AlphaConversionReportValidator.validate(
            data: Data(report.utf8),
            expectedOutputBasename: "idle.mov",
            actualOutputSHA256: outputHash
        )
    }
    try requiresError("alpha loss was accepted") {
        let report = validAlphaReportJSON().replacingOccurrences(
            of: "\"lost_alpha_pixels_total\":0",
            with: "\"lost_alpha_pixels_total\":1"
        )
        _ = try AlphaConversionReportValidator.validate(
            data: Data(report.utf8),
            expectedOutputBasename: "idle.mov",
            actualOutputSHA256: outputHash
        )
    }
    try requiresError("composite fringe gate failure was accepted") {
        let report = validAlphaReportJSON().replacingOccurrences(
            of: "\"maximum_introduced_green_fringe_ratio\":0.001",
            with: "\"maximum_introduced_green_fringe_ratio\":0.02"
        )
        _ = try AlphaConversionReportValidator.validate(
            data: Data(report.utf8),
            expectedOutputBasename: "idle.mov",
            actualOutputSHA256: outputHash
        )
    }

    let mapJSON = Data(#"{"version":1,"states":{"idle":{"path":"idle.mov","poster_path":"posters/idle.png","playback_rate":0.9583333333333334},"running":{"path":"running.mp4"}}}"#.utf8)
    let mediaMap = try JSONDecoder.codexPet.decode(MediaMap.self, from: mapJSON)
    try require(mediaMap.entry(for: .idle)?.posterPath == "posters/idle.png", "poster_path was not decoded")
    try require(abs((mediaMap.entry(for: .idle)?.playbackRate.value ?? 0) - (23.0 / 24.0)) < 0.000_001, "playback_rate was not decoded")
    let mapURL = URL(fileURLWithPath: "/tmp/codex-pet/media-map.json")
    try require(mediaMap.resolvedPosterURL(for: .idle, relativeTo: mapURL)?.path == "/tmp/codex-pet/posters/idle.png", "poster_path was not resolved relative to the map")
    let defaultAppearance = try PetAppearanceConfiguration()
    try require(mediaMap.window.appearance == defaultAppearance, "legacy media map did not use appearance defaults")
    try require(defaultAppearance.stateLabelColor == nil, "legacy media map did not preserve automatic state label color")
    try require(defaultAppearance.showFPS, "legacy media map did not enable the FPS label")
    try require(defaultAppearance.fpsColor == "#00FF00", "legacy media map did not use the default FPS color")
    try require(defaultAppearance.fpsLabelSize == .small, "legacy media map did not use the default FPS size")

    let legacyLibrary = CharacterLibrary.legacy
    try require(legacyLibrary.activeCharacterID == "default", "legacy character id changed")
    try require(legacyLibrary.activeCharacter.name == "Default", "legacy character name changed")
    try require(legacyLibrary.activeCharacter.mapPath == "media-map.json", "legacy map path changed")
    let customRootLibrary = try CharacterLibrary.legacy(mapPath: "custom.json")
    try require(customRootLibrary.activeCharacter.mapPath == "custom.json", "custom root map did not bootstrap")
    try requiresError("nested custom root map was accepted") {
        _ = try CharacterLibrary.legacy(mapPath: "nested/custom.json")
    }
    let libraryRoundTrip = try JSONDecoder().decode(
        CharacterLibrary.self,
        from: JSONEncoder().encode(legacyLibrary)
    )
    try require(libraryRoundTrip == legacyLibrary, "character library did not round-trip")
    let addedLibrary = try legacyLibrary.addingCharacter(id: "chloe", name: "Chloe")
    try require(
        addedLibrary.character(id: "default")?.mapPath == "media-map.json",
        "adding a character changed the default profile map"
    )
    try require(
        addedLibrary.character(id: "chloe")?.mapPath == ".character-chloe.media-map.json",
        "new character did not receive an isolated profile map"
    )
    let renamedLibrary = try addedLibrary.renamingCharacter(id: "chloe", to: "Chloe Prime")
    try require(addedLibrary.character(id: "chloe")?.name == "Chloe", "rename mutated original library")
    let duplicatedLibrary = try renamedLibrary.duplicatingCharacter(
        id: "chloe",
        as: "chloe-copy",
        name: "Chloe Copy"
    )
    let selectedLibrary = try duplicatedLibrary.selectingCharacter(id: "chloe")
    try require(selectedLibrary.activeCharacterID == "chloe", "character selection failed")
    let removedActiveLibrary = try selectedLibrary.removingCharacter(id: "chloe")
    try require(removedActiveLibrary.activeCharacterID == "default", "active removal did not fall back to default")
    try requiresError("last character removal was accepted") {
        _ = try legacyLibrary.removingCharacter(id: "default")
    }

    let bundleHash = String(repeating: "d", count: 64)
    let bundleMap = try MediaMap(states: [
        .idle: MediaEntry(path: "movies/idle.mov", posterPath: "posters/idle.png"),
    ])
    let bundle = try CharacterBundleManifest(
        characterID: "chloe",
        characterName: "Chloe",
        mediaMap: bundleMap,
        assets: [
            CharacterBundleAsset(role: .movie, path: "movies/idle.mov", size: 100, sha256: bundleHash),
            CharacterBundleAsset(role: .poster, path: "posters/idle.png", size: 50, sha256: bundleHash),
            CharacterBundleAsset(
                role: .report,
                path: "reports/idle.json",
                size: 25,
                sha256: bundleHash,
                moviePath: "movies/idle.mov"
            ),
        ]
    )
    let bundleRoundTrip = try CharacterBundleManifest.decode(JSONEncoder().encode(bundle))
    try require(bundleRoundTrip == bundle, "character bundle did not round-trip")
    let rewrittenBundleMap = try bundle.mediaMap { "imports/\($0)" }
    try require(
        rewrittenBundleMap.entry(for: .idle)?.path == "imports/movies/idle.mov",
        "bundle movie path was not rewritten"
    )
    try require(
        rewrittenBundleMap.entry(for: .idle)?.posterPath == "imports/posters/idle.png",
        "bundle poster path was not rewritten"
    )
    try requiresError("bundle traversal path was accepted") {
        _ = try CharacterBundleManifest(
            characterID: "chloe",
            characterName: "Chloe",
            mediaMap: MediaMap(states: [.idle: MediaEntry(path: "../idle.mov")]),
            assets: [
                CharacterBundleAsset(role: .movie, path: "../idle.mov", size: 1, sha256: bundleHash),
            ]
        )
    }
    try requiresError("bundle control-character path was accepted") {
        _ = try CharacterLibrary.legacy(mapPath: "bad\nmap.json")
    }
    try requiresError("bundle case-colliding paths were accepted") {
        _ = try CharacterBundleManifest(
            characterID: "chloe",
            characterName: "Chloe",
            mediaMap: MediaMap(states: [.idle: MediaEntry(path: "movies/idle.mov")]),
            assets: [
                CharacterBundleAsset(role: .movie, path: "movies/idle.mov", size: 1, sha256: bundleHash),
                CharacterBundleAsset(role: .movie, path: "movies/IDLE.mov", size: 1, sha256: bundleHash),
            ]
        )
    }
    try requiresError("bundle wrong-role reference was accepted") {
        _ = try CharacterBundleManifest(
            characterID: "chloe",
            characterName: "Chloe",
            mediaMap: MediaMap(states: [.idle: MediaEntry(path: "movies/idle.mov")]),
            assets: [
                CharacterBundleAsset(role: .poster, path: "movies/idle.mov", size: 1, sha256: bundleHash),
            ]
        )
    }
    try requiresError("bundle report without movie_path was accepted") {
        _ = try CharacterBundleManifest(
            characterID: "chloe",
            characterName: "Chloe",
            mediaMap: MediaMap(states: [:] as [PetState: StateMediaPlaylist]),
            assets: [
                CharacterBundleAsset(role: .report, path: "reports/idle.json", size: 1, sha256: bundleHash),
            ]
        )
    }
    try requiresError("bundle unreferenced movie was accepted") {
        _ = try CharacterBundleManifest(
            characterID: "chloe",
            characterName: "Chloe",
            mediaMap: bundleMap,
            assets: [
                CharacterBundleAsset(role: .movie, path: "movies/idle.mov", size: 1, sha256: bundleHash),
                CharacterBundleAsset(role: .movie, path: "movies/unused.mov", size: 1, sha256: bundleHash),
                CharacterBundleAsset(role: .poster, path: "posters/idle.png", size: 1, sha256: bundleHash),
            ]
        )
    }
    try requiresError("bundle duplicate reports were accepted") {
        _ = try CharacterBundleManifest(
            characterID: "chloe",
            characterName: "Chloe",
            mediaMap: bundleMap,
            assets: [
                CharacterBundleAsset(role: .movie, path: "movies/idle.mov", size: 1, sha256: bundleHash),
                CharacterBundleAsset(role: .poster, path: "posters/idle.png", size: 1, sha256: bundleHash),
                CharacterBundleAsset(
                    role: .report,
                    path: "reports/first.json",
                    size: 1,
                    sha256: bundleHash,
                    moviePath: "movies/idle.mov"
                ),
                CharacterBundleAsset(
                    role: .report,
                    path: "reports/second.json",
                    size: 1,
                    sha256: bundleHash,
                    moviePath: "movies/idle.mov"
                ),
            ]
        )
    }

    let appearanceJSON = Data(##"{"background_color":"#a1b2c3","border_color":"#dEf012","border_enabled":false,"border_width":4.5,"corner_radius":31,"show_state_label":false,"state_label_position":"bottom_right","state_label_size":"large","state_label_color":"#1a2B3c","show_fps":false,"fps_color":"#00eE77","fps_label_size":"regular"}"##.utf8)
    let appearance = try JSONDecoder.codexPet.decode(PetAppearanceConfiguration.self, from: appearanceJSON)
    try require(appearance.backgroundColor == "#A1B2C3", "background color was not normalized")
    try require(appearance.borderColor == "#DEF012", "border color was not normalized")
    try require(appearance.backgroundOpacity == 0.28, "missing background opacity did not default")
    try require(appearance.borderOpacity == 0.24, "missing border opacity did not default")
    try require(appearance.stateLabelPosition == .bottomRight, "state label position was not decoded")
    try require(appearance.stateLabelSize == .large, "state label size was not decoded")
    try require(appearance.stateLabelColor == "#1A2B3C", "state label color was not normalized")
    try require(!appearance.showFPS, "FPS visibility was not decoded")
    try require(appearance.fpsColor == "#00EE77", "FPS color was not normalized")
    try require(appearance.fpsLabelSize == .regular, "FPS label size was not decoded")
    let roundTrippedAppearance = try JSONDecoder.codexPet.decode(
        PetAppearanceConfiguration.self,
        from: JSONEncoder().encode(appearance)
    )
    try require(roundTrippedAppearance == appearance, "appearance did not round-trip")
    try requiresError("invalid appearance color was accepted") {
        _ = try PetAppearanceConfiguration(backgroundColor: "#GGGGGG")
    }
    try requiresError("invalid FPS color was accepted") {
        _ = try PetAppearanceConfiguration(fpsColor: "#GGGGGG")
    }
    try requiresError("invalid state label color was accepted") {
        _ = try PetAppearanceConfiguration(stateLabelColor: "#GGGGGG")
    }
    try requiresError("non-finite appearance opacity was accepted") {
        _ = try PetAppearanceConfiguration(backgroundOpacity: .infinity)
    }
    try requiresError("out-of-range appearance border width was accepted") {
        _ = try PetAppearanceConfiguration(borderWidth: 12.01)
    }
    try requiresError("out-of-range appearance corner radius was accepted") {
        _ = try PetAppearanceConfiguration(cornerRadius: -0.01)
    }

    let replacement = try MediaEntry(path: "imports/idle-v2.mov", loop: true, playbackRate: 1)
    let updatedMap = try mediaMap.replacingEntry(for: .idle, with: replacement)
    try require(updatedMap.entry(for: .idle) == replacement, "selected media entry was not replaced")
    try require(updatedMap.entry(for: .running) == mediaMap.entry(for: .running), "unrelated media entry changed")
    try require(mediaMap.entry(for: .idle)?.path == "idle.mov", "original media map was mutated")
    let updatedWindow = try mediaMap.window.replacing(width: 400, clickThrough: true)
    try require(updatedWindow.width == 400, "window width was not replaced")
    try require(updatedWindow.height == mediaMap.window.height, "unspecified window height changed")
    try require(updatedWindow.clickThrough, "window click-through was not replaced")
    try require(updatedWindow.appearance == mediaMap.window.appearance, "window replacement changed appearance")
    let replacedAppearance = try appearance.replacing(
        backgroundEnabled: false,
        borderColor: "#abcdef",
        showStateLabel: true,
        stateLabelSize: .small,
        stateLabelColor: .custom("#abcdef"),
        showFPS: true,
        fpsColor: "#12ab34",
        fpsLabelSize: .large
    )
    try require(!replacedAppearance.backgroundEnabled, "appearance background enabled was not replaced")
    try require(replacedAppearance.backgroundColor == appearance.backgroundColor, "unspecified appearance color changed")
    try require(replacedAppearance.borderColor == "#ABCDEF", "replacement border color was not normalized")
    try require(replacedAppearance.borderWidth == appearance.borderWidth, "unspecified appearance border width changed")
    try require(replacedAppearance.stateLabelColor == "#ABCDEF", "replacement state label color was not normalized")
    try require(replacedAppearance.showFPS, "replacement FPS visibility was not applied")
    try require(replacedAppearance.fpsColor == "#12AB34", "replacement FPS color was not normalized")
    try require(replacedAppearance.fpsLabelSize == .large, "replacement FPS label size was not applied")
    let automaticStateLabelAppearance = try replacedAppearance.replacing(stateLabelColor: .automatic)
    try require(automaticStateLabelAppearance.stateLabelColor == nil, "state label color was not cleared to automatic")
    try require(replacedAppearance.stateLabelColor == "#ABCDEF", "state label color replacement mutated the original")
    let preservedAutomaticStateLabelAppearance = try automaticStateLabelAppearance.replacing()
    try require(
        preservedAutomaticStateLabelAppearance.stateLabelColor == nil,
        "unspecified state label color replacement did not preserve automatic mode"
    )
    try requiresError("invalid replacement state label color was accepted") {
        _ = try automaticStateLabelAppearance.replacing(stateLabelColor: .custom("#GGGGGG"))
    }
    let appearanceWindow = try updatedWindow.replacing(appearance: replacedAppearance)
    try require(appearanceWindow.appearance == replacedAppearance, "window appearance was not replaced")
    try require(appearanceWindow.width == updatedWindow.width, "appearance replacement changed window width")
    let windowMap = try mediaMap.replacingWindow(appearanceWindow)
    try require(windowMap.window == appearanceWindow, "media map window was not replaced")
    try require(windowMap.defaultFormat == mediaMap.defaultFormat, "window replacement changed default format")
    try require(windowMap.states == mediaMap.states, "window replacement changed media states")
    try require(
        MediaMapChangeImpact.decide(previous: mediaMap, incoming: mediaMap) == .unchanged,
        "unchanged media map was classified as changed"
    )
    try require(
        MediaMapChangeImpact.decide(previous: mediaMap, incoming: windowMap) == .windowOnly,
        "appearance-only media map change was classified as playback"
    )
    try require(
        MediaMapChangeImpact.decide(previous: mediaMap, incoming: updatedMap) == .playback,
        "media entry change did not request playback refresh"
    )

    let idleOne = try MediaEntry(path: "idle/one.mov")
    let idleTwo = try MediaEntry(path: "idle/two.mov")
    let playlist = try StateMediaPlaylist(
        mode: .sequential,
        advanceOn: .clipEnd,
        fixedPath: idleTwo.path,
        entries: [idleOne, idleTwo]
    )
    let playlistMap = try MediaMap(states: [.idle: playlist])
    let playlistRoundTrip = try JSONDecoder.codexPet.decode(MediaMap.self, from: JSONEncoder().encode(playlistMap))
    try require(playlistRoundTrip == playlistMap, "playlist media map did not round-trip")
    try require(playlistRoundTrip.playlist(for: .idle)?.advanceOn == .clipEnd, "advance_on did not round-trip")
    let defaultAdvanceJSON = Data(#"{"mode":"random","entries":[{"path":"idle/one.mov"},{"path":"idle/two.mov"}]}"#.utf8)
    let defaultAdvance = try JSONDecoder.codexPet.decode(StateMediaPlaylist.self, from: defaultAdvanceJSON)
    try require(defaultAdvance.advanceOn == .stateEntry, "missing advance_on did not use legacy state_entry behavior")
    try require(playlistMap.entry(for: .idle) == idleTwo, "legacy entry accessor did not return fixed entry")
    try requiresError("duplicate normalized playlist path was accepted") {
        _ = try StateMediaPlaylist(entries: [
            MediaEntry(path: "idle/./one.mov"),
            MediaEntry(path: "idle/other/../one.mov"),
        ])
    }

    let appendedMap = try playlistMap.appendingEntry(MediaEntry(path: "idle/three.mov"), for: .idle)
    try require(appendedMap.playlist(for: .idle)?.entries.map(\.path) == ["idle/one.mov", "idle/two.mov", "idle/three.mov"], "playlist append changed order")
    try require(appendedMap.playlist(for: .idle)?.advanceOn == .clipEnd, "playlist append changed advance policy")
    let reorderedMap = try appendedMap.movingEntry(for: .idle, path: "idle/one.mov", to: 2)
    try require(reorderedMap.playlist(for: .idle)?.entries.map(\.path) == ["idle/two.mov", "idle/three.mov", "idle/one.mov"], "playlist reorder produced the wrong order")
    try require(reorderedMap.playlist(for: .idle)?.fixedPath == idleTwo.path, "playlist reorder changed the fixed entry")
    try require(reorderedMap.playlist(for: .idle)?.advanceOn == .clipEnd, "playlist reorder changed advance policy")
    try requiresError("playlist reorder accepted a missing path") {
        _ = try appendedMap.movingEntry(for: .idle, path: "idle/missing.mov", to: 0)
    }
    try requiresError("playlist reorder accepted an out-of-bounds destination") {
        _ = try appendedMap.movingEntry(for: .idle, path: idleOne.path, to: 3)
    }
    let fixedMap = try appendedMap.settingFixedEntry(for: .idle, path: "idle/three.mov")
    try require(fixedMap.playlist(for: .idle)?.fixedPath == "idle/three.mov", "setting fixed entry selected the wrong path")
    try require(fixedMap.playlist(for: .idle)?.mode == .fixed, "setting fixed entry did not switch to fixed mode")
    try require(fixedMap.playlist(for: .idle)?.advanceOn == .clipEnd, "setting fixed entry changed advance policy")
    try require(fixedMap.playlist(for: .idle)?.isContinuousRotationEffective == false, "fixed playlist enabled continuous rotation")
    let randomMap = try appendedMap.changingPlaybackMode(for: .idle, to: .random)
    try require(randomMap.playlist(for: .idle)?.isContinuousRotationEffective == true, "eligible random playlist did not enable continuous rotation")
    let stateEntryMap = try randomMap.settingAdvanceOn(for: .idle, to: .stateEntry)
    try require(stateEntryMap.playlist(for: .idle)?.isContinuousRotationEffective == false, "state_entry playlist enabled continuous rotation")
    let removedMap = try appendedMap.removingEntry(for: .idle, path: "idle/two.mov")
    try require(removedMap.playlist(for: .idle)?.fixedPath == "idle/one.mov", "removing fixed entry did not choose declared first entry")
    try require(removedMap.playlist(for: .idle)?.advanceOn == .clipEnd, "playlist removal changed advance policy")

    var cursor = MediaSelectionCursor()
    try require(cursor.select(for: .idle, from: playlist)?.path == idleOne.path, "sequential selection did not start at first entry")
    try require(cursor.select(for: .idle, from: playlist)?.path == idleTwo.path, "sequential selection did not advance")
    try require(cursor.select(for: .idle, from: playlist, advance: false)?.path == idleTwo.path, "non-advancing selection did not retain active entry")
    let playlistWithoutUnrelated = try StateMediaPlaylist(mode: .sequential, entries: [idleOne, idleTwo])
    try require(
        cursor.select(for: .idle, from: playlistWithoutUnrelated, advance: false)?.path == idleTwo.path,
        "removing an unrelated entry changed the selected clip"
    )
    let playlistWithoutActive = try StateMediaPlaylist(
        mode: .sequential,
        entries: [idleOne, MediaEntry(path: "idle/three.mov")]
    )
    try require(
        cursor.select(for: .idle, from: playlistWithoutActive, advance: false)?.path == idleOne.path,
        "removing the active entry did not choose an eligible replacement"
    )
    let randomPlaylist = try StateMediaPlaylist(mode: .random, entries: [idleOne, idleTwo])
    cursor.reset(state: .running)
    try require(cursor.select(for: .running, from: randomPlaylist, randomIndex: { _ in 0 }) == idleOne, "random injection did not select requested entry")
    try require(cursor.select(for: .running, from: randomPlaylist, randomIndex: { _ in 0 }) == idleTwo, "random selection repeated immediately")
    let fixedPlaylist = try StateMediaPlaylist(
        mode: .fixed,
        fixedPath: idleTwo.path,
        entries: [idleOne, idleTwo]
    )
    var explicitCursor = MediaSelectionCursor()
    try require(explicitCursor.select(for: .review, from: fixedPlaylist) == idleTwo, "fixed selection did not start at fixed_path")
    try require(explicitCursor.selectNextExplicitly(for: .review, from: fixedPlaylist) == idleOne, "explicit fixed advance did not choose the next declared entry")
    try require(explicitCursor.selectNextExplicitly(for: .review, from: fixedPlaylist) == idleTwo, "explicit fixed advance did not wrap")
    try require(fixedPlaylist.fixedPath == idleTwo.path, "explicit fixed advance mutated fixed_path")
    try require(
        MediaSelectionCursor.canSelectNextExplicitly(
            currentPath: idleTwo.path,
            from: fixedPlaylist,
            isEligible: { $0.path == idleOne.path }
        ),
        "missing fixed clip did not expose its one readable alternative"
    )
    try require(
        !MediaSelectionCursor.canSelectNextExplicitly(
            currentPath: idleTwo.path,
            from: fixedPlaylist,
            isEligible: { $0.path == idleTwo.path }
        ),
        "the current clip was treated as an alternative to itself"
    )
    try require(
        !MediaSelectionAdvancePolicy.shouldAdvance(previousLifecycleState: .running, incomingState: .running, forceRefresh: false),
        "same-state lifecycle heartbeat advanced the playlist"
    )
    try require(
        !PlaybackFallbackPolicy.shouldRetainCurrentPresentation(
            hasCurrentMedia: true,
            currentIsOneShot: true,
            requestedState: .waiting
        ),
        "one-shot preview was accepted as lifecycle fallback"
    )

    var arbiter = OneShotPlaybackArbiter()
    let firstShot = try arbiter.start(state: .idle, path: idleOne.path)
    let secondShot = try arbiter.start(state: .idle, path: idleTwo.path)
    try require(arbiter.complete(token: firstShot.token) == nil, "stale one-shot completion cleared superseding playback")
    try require(arbiter.heartbeat(state: .idle) == .continuing(secondShot), "same-state heartbeat preempted one-shot playback")
    try require(arbiter.heartbeat(state: .running) == .preempted(secondShot), "real state change did not preempt one-shot playback")
    try require(arbiter.complete(token: secondShot.token) == nil, "preempted token completed twice")

    for state in PetState.allCases {
        var preview = TemporaryStatePreviewPolicy()
        try require(
            preview.begin(previewState: state, baselineRealState: .idle) == state,
            "manual preview did not present \(state.rawValue)"
        )
        try require(preview.presentedState == state, "manual preview state was not retained in memory")
    }
    var preview = TemporaryStatePreviewPolicy()
    _ = preview.begin(previewState: .review, baselineRealState: .running)
    try require(preview.receiveLifecycleState(.running) == .presentingPreview(.review), "baseline heartbeat relinquished manual preview")
    try require(preview.receiveLifecycleState(.waiting) == .presentingLifecycle(.waiting), "changed lifecycle state did not relinquish manual preview")
    try require(preview.previewState == nil, "relinquished manual preview remained active")
    _ = preview.begin(previewState: .review)
    try require(preview.realState == nil, "manual preview without a baseline invented a real state")
    try require(preview.receiveLifecycleState(.idle) == .presentingLifecycle(.idle), "first lifecycle state did not relinquish baseline-free preview")
    try require(preview.previewState == nil, "baseline-free preview remained active after first lifecycle state")
    _ = preview.begin(previewState: .review, baselineRealState: .idle)
    try require(preview.receiveLifecycleState(.review) == .presentingLifecycle(.review), "real state matching preview was not presented")
    try require(preview.previewState == nil, "changed-to-preview lifecycle state did not relinquish manual preview")
    _ = preview.begin(previewState: .waiting, baselineRealState: .running)
    try require(preview.cancel() == .running, "manual preview cancel did not return the real state")
    let relaunchedPreview = TemporaryStatePreviewPolicy()
    try require(relaunchedPreview.presentedState == nil, "manual preview persisted across policy initialization")
    _ = preview.begin(previewState: .waiting, baselineRealState: .idle)
    try require(preview.begin(previewState: .review, baselineRealState: .running) == .review, "repeated begin did not replace manual preview")
    try require(preview.receiveLifecycleState(.running) == .presentingPreview(.review), "repeated begin did not replace the baseline")

    var suspension = PlaybackSuspensionPolicy()
    try require(suspension.replacePlayback(rate: 0.75) == .resume(rate: 0.75), "initial playback did not resume")
    try require(suspension.setSuspended(true, for: .windowOccluded) == .pause, "occlusion did not pause")
    try require(suspension.setSuspended(true, for: .screenAsleep) == .pause, "screen sleep did not remain paused")
    try require(suspension.setSuspended(false, for: .windowOccluded) == .none, "clearing one reason resumed another")
    try require(suspension.setSuspended(false, for: .screenAsleep) == .resume(rate: 0.75), "final reason did not restore rate")
    try require(
        DisplayWakeRecoveryPolicy.steps == [.clearWindowOcclusion, .clearScreenSleep, .recheckWindowOcclusion],
        "wake recovery can retain stale occlusion"
    )
    var lru = BoundedLRUCache<Int, String>(capacity: 2)
    lru.insert("one", for: 1)
    lru.insert("two", for: 2)
    _ = lru.value(for: 1)
    lru.insert("three", for: 3)
    try require(lru.value(for: 2) == nil && lru.count == 2, "FPS cache did not evict least-recently-used entry")
    try require(
        !LifecycleUIRefreshPolicy.shouldRefresh(
            previousProducerState: .running,
            incomingProducerState: .running,
            presentationWillRefresh: false
        ),
        "unchanged heartbeat refreshed UI"
    )
    try require(
        LifecycleUIRefreshPolicy.shouldRefresh(
            previousProducerState: .running,
            incomingProducerState: .waiting,
            presentationWillRefresh: false
        ),
        "producer change behind stable preview did not refresh UI"
    )

    let runtimeRevisionRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("statelet-runtime-revision-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: runtimeRevisionRoot) }
    try FileManager.default.createDirectory(at: runtimeRevisionRoot, withIntermediateDirectories: true)
    let runtimeRevisionFile = runtimeRevisionRoot.appendingPathComponent("clip.mov")
    try require(LocalFileRevision(url: runtimeRevisionFile) == nil, "missing file had a revision")
    try Data("first".utf8).write(to: runtimeRevisionFile)
    let firstRevision = LocalFileRevision(url: runtimeRevisionFile)
    try FileManager.default.removeItem(at: runtimeRevisionFile)
    try Data("replacement-longer".utf8).write(to: runtimeRevisionFile)
    let replacementRevision = LocalFileRevision(url: runtimeRevisionFile)
    try require(
        firstRevision != nil && replacementRevision != nil && firstRevision != replacementRevision,
        "file replacement did not invalidate revision identity"
    )
    try require(
        LibraryRowRefreshPolicy.shouldRefresh(previous: firstRevision, incoming: replacementRevision),
        "library row policy retained stale file metadata"
    )

    let displays = [
        CGRect(x: -1920, y: -1080, width: 1920, height: 1080),
        CGRect(x: 0, y: 0, width: 1440, height: 900),
        CGRect(x: 0, y: 900, width: 1280, height: 720),
    ]
    let resizedStoredFrame = WindowFramePolicy.applyingConfiguredSize(
        CGSize(width: 320, height: 486),
        to: CGRect(x: 663, y: 336, width: 321, height: 480)
    )
    try require(resizedStoredFrame.origin == CGPoint(x: 663, y: 336), "configured resize changed stored origin")
    try require(resizedStoredFrame.size == CGSize(width: 320, height: 486), "stored size overrode configuration")
    let removedDisplay = WindowFramePolicy.clamped(
        CGRect(x: 5000, y: -2500, width: 320, height: 480),
        to: displays
    )
    try require(hasReachableArea(removedDisplay, displays: displays), "removed-display frame was not made reachable")
    let negativeDisplay = WindowFramePolicy.clamped(
        CGRect(x: -2230, y: -1300, width: 320, height: 480),
        to: displays
    )
    try require(hasReachableArea(negativeDisplay, displays: displays), "negative-display frame was not made reachable")
    let oversized = WindowFramePolicy.clamped(
        CGRect(x: 6000, y: 6000, width: 3000, height: 2400),
        to: displays
    )
    try require(hasReachableArea(oversized, displays: displays), "oversized frame did not retain a 48-point handle")
}

private func runPlaybackSmoke(arguments: [String]) throws {
    guard arguments.count == 5,
          let expectedWidth = Int(arguments[2]),
          let expectedHeight = Int(arguments[3]),
          let expectedFPS = Double(arguments[4]),
          expectedWidth > 0,
          expectedHeight > 0,
          expectedFPS.isFinite,
          expectedFPS > 0 else {
        throw SelfTestFailure.assertion(
            "usage: codex-pet-core-self-test --playback-smoke MOV WIDTH HEIGHT FPS"
        )
    }
    let semaphore = DispatchSemaphore(value: 0)
    let result = LockedPlaybackSmokeResult()
    Task {
        do {
            result.store(.success(try await AlphaPlaybackAcceptanceValidator.probe(
                url: URL(fileURLWithPath: arguments[1])
            )))
        } catch {
            result.store(.failure(error))
        }
        semaphore.signal()
    }
    semaphore.wait()
    let probe = try result.load().get()
    try require(probe.isPlayable, "AVFoundation did not mark the movie playable")
    try require(probe.videoTrackCount == 1, "AVFoundation did not find exactly one video track")
    try require(probe.audioTrackCount == 0, "AVFoundation found an unexpected audio track")
    try require(probe.codec == "hevc", "AVFoundation did not report HEVC")
    try require(
        probe.width == expectedWidth && probe.height == expectedHeight,
        "AVFoundation playback geometry did not match"
    )
    try require(
        abs(probe.nominalFrameRate - expectedFPS) <= 0.05,
        "AVFoundation nominal frame rate did not match"
    )
    try require(probe.decodedFirstFrame, "AVFoundation could not decode the first frame")
}

private final class LockedPlaybackSmokeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<AlphaPlaybackProbe, Error>?

    func store(_ result: Result<AlphaPlaybackProbe, Error>) {
        lock.lock()
        value = result
        lock.unlock()
    }

    func load() -> Result<AlphaPlaybackProbe, Error> {
        lock.lock()
        defer { lock.unlock() }
        return value ?? .failure(SelfTestFailure.assertion("playback smoke produced no result"))
    }
}

do {
    if CommandLine.arguments.dropFirst().first == "--playback-smoke" {
        try runPlaybackSmoke(arguments: Array(CommandLine.arguments.dropFirst()))
        print("CodexPetCore AVFoundation playback smoke passed")
    } else {
        try runSelfTest()
        print("CodexPetCore self-test passed")
    }
} catch {
    FileHandle.standardError.write(Data("CodexPetCore self-test failed: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
