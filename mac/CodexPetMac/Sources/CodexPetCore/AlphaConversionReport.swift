import AVFoundation
import CoreMedia
import Foundation

public enum AlphaConversionReportTrust: Equatable, Sendable {
    case legacyPortableClaim
    case portableClaim
    case locallyAttested
}

public struct AlphaConversionToolchainMetadata: Equatable, Sendable {
    public let converterVersion: String
    public let ffmpegVersion: String
    public let ffprobeVersion: String
    public let avconvertVersion: String
    public let macOSBuild: String
}

public struct AlphaConversionToolCapabilitiesMetadata: Equatable, Sendable {
    public let ffmpegEncoder: String
    public let ffmpegFilters: [String]
    public let avconvertPresets: [String]
}

public struct AlphaConversionProfileMetadata: Equatable, Sendable {
    public let name: String
    public let framing: String
    public let keying: String
}

public struct AlphaConversionNormalizationMetadata: Equatable, Sendable {
    public let applied: [String]
    public let warnings: [String]
}

public struct ValidatedAlphaConversionReport: Equatable, Sendable {
    public let reportSchemaVersion: Int
    public let trust: AlphaConversionReportTrust
    public let toolchain: AlphaConversionToolchainMetadata?
    public let toolCapabilities: AlphaConversionToolCapabilitiesMetadata?
    public let profile: AlphaConversionProfileMetadata?
    public let normalization: AlphaConversionNormalizationMetadata?
    public let outputBasename: String
    public let outputSHA256: String
    public let sourceSHA256: String
    public let width: Int
    public let height: Int
    public let frames: Int
    public let fps: String
    public let notices: [AlphaConversionNotice]
}

public enum AlphaConversionNotice: Equatable, Sendable {
    case audioStripped(streamCount: Int)
    case loopMayJump(differingPixels: Int)
    case canvasAdjusted(
        requestedWidth: Int,
        requestedHeight: Int,
        outputWidth: Int,
        outputHeight: Int
    )

    public var message: String {
        switch self {
        case let .audioStripped(streamCount):
            return streamCount == 1 ? "audio removed" : "\(streamCount) audio tracks removed"
        case .loopMayJump:
            return "loop endpoints differ"
        case let .canvasAdjusted(requestedWidth, requestedHeight, outputWidth, outputHeight):
            return "canvas \(requestedWidth)×\(requestedHeight) → \(outputWidth)×\(outputHeight)"
        }
    }
}

public enum AlphaConversionReportValidationError: Error, Equatable, LocalizedError {
    case malformedReport
    case reportTooLarge
    case unsupportedSchemaVersion(Int)
    case invalidMetadata
    case provenanceRequired
    case provenanceMismatch
    case invalidHash(String)
    case outputBasenameMismatch
    case outputHashMismatch
    case sourceChanged
    case unverifiedDelivery
    case invalidDelivery
    case frameMismatch
    case alphaGateFailed
    case compositeGateFailed

    public var errorDescription: String? {
        switch self {
        case .malformedReport: return "Conversion report is malformed"
        case .reportTooLarge: return "Conversion report exceeds the supported size limit"
        case let .unsupportedSchemaVersion(version):
            return "Conversion report schema version \(version) is not supported"
        case .invalidMetadata: return "Conversion report metadata is invalid"
        case .provenanceRequired: return "Conversion report is not bound to this local conversion"
        case .provenanceMismatch: return "Conversion report local provenance does not match"
        case let .invalidHash(name): return "Conversion report contains an invalid \(name) hash"
        case .outputBasenameMismatch: return "Conversion report output name does not match"
        case .outputHashMismatch: return "Converted output hash does not match the report"
        case .sourceChanged: return "Conversion source changed during processing"
        case .unverifiedDelivery: return "Conversion report is not a verified safe delivery"
        case .invalidDelivery: return "Conversion report is not HEVC with alpha"
        case .frameMismatch: return "Conversion report frame or geometry checks do not agree"
        case .alphaGateFailed: return "Conversion report alpha checks did not pass"
        case .compositeGateFailed: return "Conversion report composite checks did not pass"
        }
    }
}

public enum AlphaConversionReportValidator {
    public static let maximumReportBytes = 1_048_576

    public static func validate(
        data: Data,
        expectedOutputBasename: String,
        actualOutputSHA256: String,
        expectedLocalProvenanceChallenge: String? = nil
    ) throws -> ValidatedAlphaConversionReport {
        guard data.count <= maximumReportBytes else {
            throw AlphaConversionReportValidationError.reportTooLarge
        }
        let report: AlphaConversionReport
        do {
            report = try JSONDecoder().decode(AlphaConversionReport.self, from: data)
        } catch {
            throw AlphaConversionReportValidationError.malformedReport
        }

        let schemaVersion = report.reportSchemaVersion ?? 0
        guard !report.hasReportSchemaVersion || schemaVersion == 1 else {
            throw AlphaConversionReportValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        if schemaVersion == 1,
           (report.toolchain == nil || report.profile == nil
               || report.toolCapabilities == nil || report.normalization == nil
               || report.provenance == nil) {
            throw AlphaConversionReportValidationError.invalidMetadata
        }
        let trust = try validatedTrust(
            report: report,
            schemaVersion: schemaVersion,
            expectedChallenge: expectedLocalProvenanceChallenge
        )
        let toolchain = try validatedToolchain(report.toolchain)
        let toolCapabilities = try validatedToolCapabilities(report.toolCapabilities)
        let profile = try validatedProfile(report.profile)
        let normalization = try validatedNormalization(report.normalization)

        guard isBasename(expectedOutputBasename),
              isBasename(report.artifacts.outputName),
              report.artifacts.outputName == expectedOutputBasename else {
            throw AlphaConversionReportValidationError.outputBasenameMismatch
        }
        let reportedOutputHash = try normalizedHash(
            report.artifacts.outputSHA256,
            name: "output"
        )
        let actualOutputHash = try normalizedHash(actualOutputSHA256, name: "actual output")
        guard reportedOutputHash == actualOutputHash else {
            throw AlphaConversionReportValidationError.outputHashMismatch
        }
        let sourceHash = try normalizedHash(report.artifacts.sourceSHA256, name: "source")
        let sourceBeforeProbe = try normalizedHash(
            report.artifacts.sourceSHA256BeforeProbe,
            name: "source before probe"
        )
        let sourceBeforePublication = try normalizedHash(
            report.artifacts.sourceSHA256BeforePublication,
            name: "source before publication"
        )
        guard sourceHash == sourceBeforeProbe,
              sourceBeforeProbe == sourceBeforePublication else {
            throw AlphaConversionReportValidationError.sourceChanged
        }

        let verification = report.verification
        guard report.status == "converted", verification.performed, !verification.unsafe else {
            throw AlphaConversionReportValidationError.unverifiedDelivery
        }
        guard report.codec.delivery.caseInsensitiveCompare("HEVC with alpha") == .orderedSame,
              verification.delivery.codec.caseInsensitiveCompare("hevc") == .orderedSame,
              verification.delivery.qualityPassed,
              verification.roundtrip.codec.caseInsensitiveCompare("prores") == .orderedSame,
              verification.roundtrip.profile.localizedCaseInsensitiveContains("4444"),
              verification.roundtrip.qualityPassed,
              report.geometry.pixelFormat == "straight-rgba" else {
            throw AlphaConversionReportValidationError.invalidDelivery
        }

        let delivery = verification.delivery
        let roundtrip = verification.roundtrip
        guard report.geometry.width > 0,
              report.geometry.height > 0,
              delivery.frames > 0,
              !delivery.fps.isEmpty,
              verification.framesVerified == delivery.frames,
              roundtrip.frames == delivery.frames,
              roundtrip.fps == delivery.fps,
              delivery.width == report.geometry.width,
              delivery.height == report.geometry.height,
              roundtrip.width == delivery.width,
              roundtrip.height == delivery.height else {
            throw AlphaConversionReportValidationError.frameMismatch
        }

        let alpha = verification.alpha
        guard alpha.lostAlphaPixelsTotal == 0,
              isWithin(alpha.meanAbsoluteErrorMax, alpha.tolerances.maxMeanAbsoluteError),
              isWithin(alpha.p95AbsoluteErrorMax, alpha.tolerances.maxP95AbsoluteError),
              alpha.maximumAbsoluteErrorMax >= 0,
              alpha.tolerances.maxAbsoluteError >= 0,
              alpha.maximumAbsoluteErrorMax <= alpha.tolerances.maxAbsoluteError,
              verification.maximumOuterEdgeAlpha >= 0,
              alpha.tolerances.maxBorderAlpha >= 0,
              verification.maximumOuterEdgeAlpha <= alpha.tolerances.maxBorderAlpha else {
            throw AlphaConversionReportValidationError.alphaGateFailed
        }

        let composite = verification.composite
        let requiredBackgrounds = Set(["white", "black", "checkerboard"])
        guard composite.performed,
              composite.referenceComparison,
              composite.qualityPassed,
              composite.framesChecked == verification.framesVerified,
              Set(composite.backgroundNames) == requiredBackgrounds,
              composite.backgroundNames.count == requiredBackgrounds.count,
              isWithin(
                  composite.maximumIntroducedGreenFringeRatio,
                  composite.limits.maxIntroducedGreenFringeRatio
              ),
              isWithin(
                  composite.maximumIntroducedMagentaFringeRatio,
                  composite.limits.maxIntroducedMagentaFringeRatio
              ),
              composite.maximumIntroducedGreenFringeExcess >= 0,
              composite.maximumIntroducedMagentaFringeExcess >= 0,
              composite.limits.maxIntroducedGreenFringeExcess >= 0,
              composite.limits.maxIntroducedMagentaFringeExcess >= 0,
              composite.maximumIntroducedGreenFringeExcess
                  <= composite.limits.maxIntroducedGreenFringeExcess,
              composite.maximumIntroducedMagentaFringeExcess
                  <= composite.limits.maxIntroducedMagentaFringeExcess else {
            throw AlphaConversionReportValidationError.compositeGateFailed
        }

        var notices: [AlphaConversionNotice] = []
        if let audio = report.source?.audio,
           audio.policy == "stripped",
           audio.streamCount > 0 {
            notices.append(.audioStripped(streamCount: audio.streamCount))
        }
        if let seam = report.quality?.loopSeam,
           seam.performed,
           seam.policy == "informational",
           !seam.exactMatch,
           seam.differingPixels > 0 {
            notices.append(.loopMayJump(differingPixels: seam.differingPixels))
        }
        if let alignment = report.geometryAlignment,
           alignment.adjusted,
           alignment.policy == "floor_to_even",
           alignment.requestedWidth > 0,
           alignment.requestedHeight > 0 {
            notices.append(
                .canvasAdjusted(
                    requestedWidth: alignment.requestedWidth,
                    requestedHeight: alignment.requestedHeight,
                    outputWidth: delivery.width,
                    outputHeight: delivery.height
                )
            )
        }

        return ValidatedAlphaConversionReport(
            reportSchemaVersion: schemaVersion,
            trust: trust,
            toolchain: toolchain,
            toolCapabilities: toolCapabilities,
            profile: profile,
            normalization: normalization,
            outputBasename: report.artifacts.outputName,
            outputSHA256: reportedOutputHash,
            sourceSHA256: sourceHash,
            width: delivery.width,
            height: delivery.height,
            frames: delivery.frames,
            fps: delivery.fps,
            notices: notices
        )
    }

    private static func isBasename(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("\0")
    }

    private static func normalizedHash(_ value: String, name: String) throws -> String {
        let normalized = value.lowercased()
        guard normalized.utf8.count == 64,
              normalized.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            throw AlphaConversionReportValidationError.invalidHash(name)
        }
        return normalized
    }

    private static func isWithin(_ value: Double, _ limit: Double) -> Bool {
        value.isFinite && limit.isFinite && value >= 0 && limit >= 0 && value <= limit
    }

    private static func validatedTrust(
        report: AlphaConversionReport,
        schemaVersion: Int,
        expectedChallenge: String?
    ) throws -> AlphaConversionReportTrust {
        if schemaVersion == 1 {
            guard let provenance = report.provenance,
                  provenance.method == "invocation-challenge-v1",
                  provenance.producer == "statelet" else {
                throw AlphaConversionReportValidationError.invalidMetadata
            }
            _ = try normalizedLowercaseHash(
                provenance.challenge,
                name: "provenance challenge"
            )
        }
        guard let expectedChallenge else {
            return schemaVersion == 0 ? .legacyPortableClaim : .portableClaim
        }
        guard schemaVersion == 1, let provenance = report.provenance else {
            throw AlphaConversionReportValidationError.provenanceRequired
        }
        guard provenance.method == "invocation-challenge-v1",
              provenance.producer == "statelet" else {
            throw AlphaConversionReportValidationError.provenanceMismatch
        }
        let expected = try normalizedHash(expectedChallenge, name: "provenance challenge")
        let actual = try normalizedLowercaseHash(
            provenance.challenge,
            name: "provenance challenge"
        )
        guard constantTimeEqual(expected, actual) else {
            throw AlphaConversionReportValidationError.provenanceMismatch
        }
        return .locallyAttested
    }

    private static func validatedToolchain(
        _ value: AlphaConversionReport.Toolchain?
    ) throws -> AlphaConversionToolchainMetadata? {
        guard let value else { return nil }
        return AlphaConversionToolchainMetadata(
            converterVersion: try safeMetadata(value.converterVersion, required: true)!,
            ffmpegVersion: try safeMetadata(value.ffmpegVersion, required: true)!,
            ffprobeVersion: try safeMetadata(value.ffprobeVersion, required: true)!,
            avconvertVersion: try safeMetadata(value.avconvertVersion, required: true)!,
            macOSBuild: try safeMetadata(value.macOSBuild, required: true)!
        )
    }

    private static func validatedToolCapabilities(
        _ value: AlphaConversionReport.ToolCapabilities?
    ) throws -> AlphaConversionToolCapabilitiesMetadata? {
        guard let value else { return nil }
        let expectedFilters = ["scale", "crop", "pad"]
        let expectedPresets = [
            "PresetHEVCHighestQualityWithAlpha",
            "PresetAppleProRes4444LPCM",
        ]
        guard value.passed,
              value.ffmpegEncoder == "prores_ks",
              value.ffmpegFilters == expectedFilters,
              value.avconvertPresets == expectedPresets else {
            throw AlphaConversionReportValidationError.invalidMetadata
        }
        return AlphaConversionToolCapabilitiesMetadata(
            ffmpegEncoder: value.ffmpegEncoder,
            ffmpegFilters: value.ffmpegFilters,
            avconvertPresets: value.avconvertPresets
        )
    }

    private static func validatedProfile(
        _ value: AlphaConversionReport.Profile?
    ) throws -> AlphaConversionProfileMetadata? {
        guard let value else { return nil }
        return AlphaConversionProfileMetadata(
            name: try safeMetadata(value.name, required: true)!,
            framing: try safeMetadata(value.framing, required: true)!,
            keying: try safeMetadata(value.keying, required: true)!
        )
    }

    private static func validatedNormalization(
        _ value: AlphaConversionReport.Normalization?
    ) throws -> AlphaConversionNormalizationMetadata? {
        guard let value else { return nil }
        guard value.applied.count <= 32, value.warnings.count <= 32 else {
            throw AlphaConversionReportValidationError.invalidMetadata
        }
        return AlphaConversionNormalizationMetadata(
            applied: try value.applied.map { try safeMetadata($0, required: true)! },
            warnings: try value.warnings.map { try safeMetadata($0, required: true)! }
        )
    }

    private static func safeMetadata(
        _ value: String?,
        required: Bool = false
    ) throws -> String? {
        guard let value else {
            if required { throw AlphaConversionReportValidationError.invalidMetadata }
            return nil
        }
        guard !value.isEmpty,
              value.utf8.count <= 256,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !value.contains("/"),
              !value.contains("\\") else {
            throw AlphaConversionReportValidationError.invalidMetadata
        }
        return value
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    private static func normalizedLowercaseHash(
        _ value: String,
        name: String
    ) throws -> String {
        guard value == value.lowercased() else {
            throw AlphaConversionReportValidationError.invalidHash(name)
        }
        return try normalizedHash(value, name: name)
    }
}

public struct AlphaPlaybackProbe: Codable, Equatable, Sendable {
    public let isPlayable: Bool
    public let videoTrackCount: Int
    public let audioTrackCount: Int
    public let codec: String
    public let width: Int
    public let height: Int
    public let nominalFrameRate: Double
    public let durationSeconds: Double
    public let decodedFirstFrame: Bool

    public init(
        isPlayable: Bool,
        videoTrackCount: Int,
        audioTrackCount: Int,
        codec: String,
        width: Int,
        height: Int,
        nominalFrameRate: Double,
        durationSeconds: Double,
        decodedFirstFrame: Bool
    ) {
        self.isPlayable = isPlayable
        self.videoTrackCount = videoTrackCount
        self.audioTrackCount = audioTrackCount
        self.codec = codec
        self.width = width
        self.height = height
        self.nominalFrameRate = nominalFrameRate
        self.durationSeconds = durationSeconds
        self.decodedFirstFrame = decodedFirstFrame
    }
}

public enum AlphaPlaybackAcceptanceError: Error, Equatable, LocalizedError {
    case notPlayable
    case invalidVideoTrack
    case audioPresent
    case wrongCodec
    case geometryMismatch
    case frameRateMismatch
    case durationMismatch
    case decodeFailed

    public var errorDescription: String? {
        switch self {
        case .notPlayable: return "Converted movie is not playable"
        case .invalidVideoTrack: return "Converted movie does not contain one playable video track"
        case .audioPresent: return "Converted movie contains audio; Statelet animations must be silent"
        case .wrongCodec: return "Converted movie is not HEVC"
        case .geometryMismatch: return "Converted movie playback geometry does not match its report"
        case .frameRateMismatch: return "Converted movie playback frame rate does not match its report"
        case .durationMismatch: return "Converted movie playback duration does not match its report"
        case .decodeFailed: return "Converted movie could not decode its first frame"
        }
    }
}

public enum AlphaPlaybackAcceptanceValidator {
    /// Runs a macOS AVFoundation smoke probe and compares it with the already
    /// gate-validated report. This proves the installed bytes are playable by
    /// the runtime media stack; it does not replace the converter's all-frame
    /// Apple round-trip, alpha, or composite verification.
    public static func validate(
        url: URL,
        expected report: ValidatedAlphaConversionReport
    ) async throws -> AlphaPlaybackProbe {
        let probe = try await probe(url: url)
        return try validate(probe: probe, expected: report)
    }

    public static func validate(
        probe: AlphaPlaybackProbe,
        expected report: ValidatedAlphaConversionReport
    ) throws -> AlphaPlaybackProbe {
        guard probe.isPlayable else { throw AlphaPlaybackAcceptanceError.notPlayable }
        guard probe.videoTrackCount == 1 else {
            throw AlphaPlaybackAcceptanceError.invalidVideoTrack
        }
        guard probe.audioTrackCount == 0 else {
            throw AlphaPlaybackAcceptanceError.audioPresent
        }
        guard probe.codec.caseInsensitiveCompare("hevc") == .orderedSame else {
            throw AlphaPlaybackAcceptanceError.wrongCodec
        }
        guard probe.width == report.width, probe.height == report.height else {
            throw AlphaPlaybackAcceptanceError.geometryMismatch
        }
        guard let expectedFPS = rationalValue(report.fps),
              probe.nominalFrameRate.isFinite,
              abs(probe.nominalFrameRate - expectedFPS) <= 0.05 else {
            throw AlphaPlaybackAcceptanceError.frameRateMismatch
        }
        let expectedDuration = Double(report.frames) / expectedFPS
        let oneFrame = 1 / expectedFPS
        guard probe.durationSeconds.isFinite,
              abs(probe.durationSeconds - expectedDuration) <= oneFrame else {
            throw AlphaPlaybackAcceptanceError.durationMismatch
        }
        guard probe.decodedFirstFrame else { throw AlphaPlaybackAcceptanceError.decodeFailed }
        return probe
    }

    public static func probe(url: URL) async throws -> AlphaPlaybackProbe {
        let asset = AVURLAsset(url: url)
        let isPlayable = try await asset.load(.isPlayable)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            return AlphaPlaybackProbe(
                isPlayable: isPlayable,
                videoTrackCount: tracks.count,
                audioTrackCount: audioTracks.count,
                codec: "",
                width: 0,
                height: 0,
                nominalFrameRate: 0,
                durationSeconds: 0,
                decodedFirstFrame: false
            )
        }
        async let naturalSize = track.load(.naturalSize)
        async let preferredTransform = track.load(.preferredTransform)
        async let nominalFrameRate = track.load(.nominalFrameRate)
        async let formatDescriptions = track.load(.formatDescriptions)
        async let duration = asset.load(.duration)
        async let timeRange = track.load(.timeRange)

        let transformedRect = CGRect(origin: .zero, size: try await naturalSize)
            .applying(try await preferredTransform)
        let descriptions = try await formatDescriptions
        let codec = descriptions.first.map(codecName) ?? ""
        let range = try await timeRange
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let decodedFirstFrame = (try? generator.copyCGImage(at: range.start, actualTime: nil)) != nil

        return AlphaPlaybackProbe(
            isPlayable: isPlayable,
            videoTrackCount: tracks.count,
            audioTrackCount: audioTracks.count,
            codec: codec,
            width: Int(abs(transformedRect.width).rounded()),
            height: Int(abs(transformedRect.height).rounded()),
            nominalFrameRate: Double(try await nominalFrameRate),
            durationSeconds: CMTimeGetSeconds(try await duration),
            decodedFirstFrame: decodedFirstFrame
        )
    }

    private static func codecName(_ description: CMFormatDescription) -> String {
        switch CMFormatDescriptionGetMediaSubType(description) {
        case kCMVideoCodecType_HEVC: return "hevc"
        default: return "other"
        }
    }

    private static func rationalValue(_ value: String) -> Double? {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let numerator = Double(parts[0]),
              let denominator = Double(parts[1]),
              numerator.isFinite,
              denominator.isFinite,
              numerator > 0,
              denominator > 0 else {
            return nil
        }
        return numerator / denominator
    }
}

private struct AlphaConversionReport: Decodable {
    let hasReportSchemaVersion: Bool
    let reportSchemaVersion: Int?
    let status: String
    let toolchain: Toolchain?
    let toolCapabilities: ToolCapabilities?
    let profile: Profile?
    let normalization: Normalization?
    let provenance: Provenance?
    let source: Source?
    let geometry: Geometry
    let geometryAlignment: GeometryAlignment?
    let quality: Quality?
    let codec: Codec
    let verification: Verification
    let artifacts: Artifacts

    enum CodingKeys: String, CodingKey {
        case reportSchemaVersion = "report_schema_version"
        case status
        case toolchain
        case toolCapabilities = "tool_capabilities"
        case profile
        case normalization
        case provenance
        case source
        case geometry
        case geometryAlignment = "geometry_alignment"
        case quality
        case codec
        case verification
        case artifacts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasReportSchemaVersion = container.contains(.reportSchemaVersion)
        reportSchemaVersion = hasReportSchemaVersion
            ? try container.decode(Int.self, forKey: .reportSchemaVersion)
            : nil
        status = try container.decode(String.self, forKey: .status)
        toolchain = try container.decodeIfPresent(Toolchain.self, forKey: .toolchain)
        toolCapabilities = try container.decodeIfPresent(
            ToolCapabilities.self,
            forKey: .toolCapabilities
        )
        profile = try container.decodeIfPresent(Profile.self, forKey: .profile)
        normalization = try container.decodeIfPresent(Normalization.self, forKey: .normalization)
        provenance = try container.decodeIfPresent(Provenance.self, forKey: .provenance)
        source = try container.decodeIfPresent(Source.self, forKey: .source)
        geometry = try container.decode(Geometry.self, forKey: .geometry)
        geometryAlignment = try container.decodeIfPresent(
            GeometryAlignment.self,
            forKey: .geometryAlignment
        )
        quality = try container.decodeIfPresent(Quality.self, forKey: .quality)
        codec = try container.decode(Codec.self, forKey: .codec)
        verification = try container.decode(Verification.self, forKey: .verification)
        artifacts = try container.decode(Artifacts.self, forKey: .artifacts)
    }

    struct Toolchain: Decodable {
        let converterVersion: String
        let ffmpegVersion: String
        let ffprobeVersion: String
        let avconvertVersion: String
        let macOSBuild: String?

        enum CodingKeys: String, CodingKey {
            case converterVersion = "converter_version"
            case ffmpegVersion = "ffmpeg_version"
            case ffprobeVersion = "ffprobe_version"
            case avconvertVersion = "avconvert_version"
            case macOSBuild = "macos_build"
        }
    }

    struct ToolCapabilities: Decodable {
        let ffmpegEncoder: String
        let ffmpegFilters: [String]
        let avconvertPresets: [String]
        let passed: Bool

        enum CodingKeys: String, CodingKey {
            case ffmpegEncoder = "ffmpeg_encoder"
            case ffmpegFilters = "ffmpeg_filters"
            case avconvertPresets = "avconvert_presets"
            case passed
        }
    }

    struct Profile: Decodable {
        let name: String
        let framing: String
        let keying: String
    }

    struct Normalization: Decodable {
        let applied: [String]
        let warnings: [String]
    }

    struct Provenance: Decodable {
        let method: String
        let producer: String
        let challenge: String
    }

    struct Source: Decodable {
        let audio: Audio?
    }

    struct Audio: Decodable {
        let streamCount: Int
        let policy: String

        enum CodingKeys: String, CodingKey {
            case streamCount = "stream_count"
            case policy
        }
    }

    struct GeometryAlignment: Decodable {
        let requestedWidth: Int
        let requestedHeight: Int
        let policy: String
        let adjusted: Bool

        enum CodingKeys: String, CodingKey {
            case requestedWidth = "requested_width"
            case requestedHeight = "requested_height"
            case policy
            case adjusted
        }
    }

    struct Quality: Decodable {
        let loopSeam: LoopSeam?

        enum CodingKeys: String, CodingKey {
            case loopSeam = "loop_seam"
        }
    }

    struct LoopSeam: Decodable {
        let performed: Bool
        let exactMatch: Bool
        let differingPixels: Int
        let policy: String

        enum CodingKeys: String, CodingKey {
            case performed
            case exactMatch = "exact_match"
            case differingPixels = "differing_pixels"
            case policy
        }
    }

    struct Geometry: Decodable {
        let width: Int
        let height: Int
        let pixelFormat: String

        enum CodingKeys: String, CodingKey {
            case width
            case height
            case pixelFormat = "pixel_format"
        }
    }

    struct Codec: Decodable {
        let delivery: String
    }

    struct Verification: Decodable {
        let performed: Bool
        let unsafe: Bool
        let delivery: Probe
        let roundtrip: Probe
        let framesVerified: Int
        let maximumOuterEdgeAlpha: Int
        let composite: Composite
        let alpha: Alpha

        enum CodingKeys: String, CodingKey {
            case performed
            case unsafe
            case delivery
            case roundtrip
            case framesVerified = "frames_verified"
            case maximumOuterEdgeAlpha = "maximum_outer_edge_alpha"
            case composite
            case alpha
        }
    }

    struct Probe: Decodable {
        let codec: String
        let profile: String
        let width: Int
        let height: Int
        let frames: Int
        let fps: String
        let qualityPassed: Bool

        enum CodingKeys: String, CodingKey {
            case codec
            case profile
            case width
            case height
            case frames
            case fps
            case qualityPassed = "quality_passed"
        }
    }

    struct Alpha: Decodable {
        let meanAbsoluteErrorMax: Double
        let p95AbsoluteErrorMax: Double
        let maximumAbsoluteErrorMax: Int
        let lostAlphaPixelsTotal: Int
        let tolerances: AlphaTolerances

        enum CodingKeys: String, CodingKey {
            case meanAbsoluteErrorMax = "mean_absolute_error_max"
            case p95AbsoluteErrorMax = "p95_absolute_error_max"
            case maximumAbsoluteErrorMax = "maximum_absolute_error_max"
            case lostAlphaPixelsTotal = "lost_alpha_pixels_total"
            case tolerances
        }
    }

    struct AlphaTolerances: Decodable {
        let maxBorderAlpha: Int
        let maxMeanAbsoluteError: Double
        let maxP95AbsoluteError: Double
        let maxAbsoluteError: Int

        enum CodingKeys: String, CodingKey {
            case maxBorderAlpha = "max_border_alpha"
            case maxMeanAbsoluteError = "max_mean_abs_error"
            case maxP95AbsoluteError = "max_p95_abs_error"
            case maxAbsoluteError = "max_abs_error"
        }
    }

    struct Composite: Decodable {
        let performed: Bool
        let backgroundNames: [String]
        let framesChecked: Int
        let maximumIntroducedGreenFringeRatio: Double
        let maximumIntroducedMagentaFringeRatio: Double
        let maximumIntroducedGreenFringeExcess: Int
        let maximumIntroducedMagentaFringeExcess: Int
        let referenceComparison: Bool
        let limits: CompositeLimits
        let qualityPassed: Bool

        enum CodingKeys: String, CodingKey {
            case performed
            case backgroundNames = "background_names"
            case framesChecked = "frames_checked"
            case maximumIntroducedGreenFringeRatio = "maximum_introduced_green_fringe_ratio"
            case maximumIntroducedMagentaFringeRatio = "maximum_introduced_magenta_fringe_ratio"
            case maximumIntroducedGreenFringeExcess = "maximum_introduced_green_fringe_excess"
            case maximumIntroducedMagentaFringeExcess = "maximum_introduced_magenta_fringe_excess"
            case referenceComparison = "reference_comparison"
            case limits
            case qualityPassed = "quality_passed"
        }
    }

    struct CompositeLimits: Decodable {
        let maxIntroducedGreenFringeRatio: Double
        let maxIntroducedMagentaFringeRatio: Double
        let maxIntroducedGreenFringeExcess: Int
        let maxIntroducedMagentaFringeExcess: Int

        enum CodingKeys: String, CodingKey {
            case maxIntroducedGreenFringeRatio = "max_introduced_green_fringe_ratio"
            case maxIntroducedMagentaFringeRatio = "max_introduced_magenta_fringe_ratio"
            case maxIntroducedGreenFringeExcess = "max_introduced_green_fringe_excess"
            case maxIntroducedMagentaFringeExcess = "max_introduced_magenta_fringe_excess"
        }
    }

    struct Artifacts: Decodable {
        let sourceSHA256: String
        let sourceSHA256BeforeProbe: String
        let sourceSHA256BeforePublication: String
        let outputName: String
        let outputSHA256: String

        enum CodingKeys: String, CodingKey {
            case sourceSHA256 = "source_sha256"
            case sourceSHA256BeforeProbe = "source_sha256_before_probe"
            case sourceSHA256BeforePublication = "source_sha256_before_publication"
            case outputName = "output_name"
            case outputSHA256 = "output_sha256"
        }
    }
}

public extension WindowConfiguration {
    func replacing(
        width: Double? = nil,
        height: Double? = nil,
        alwaysOnTop: Bool? = nil,
        clickThrough: Bool? = nil,
        fullScreenAuxiliary: Bool? = nil,
        appearance: PetAppearanceConfiguration? = nil
    ) throws -> WindowConfiguration {
        try WindowConfiguration(
            width: width ?? self.width,
            height: height ?? self.height,
            alwaysOnTop: alwaysOnTop ?? self.alwaysOnTop,
            clickThrough: clickThrough ?? self.clickThrough,
            fullScreenAuxiliary: fullScreenAuxiliary ?? self.fullScreenAuxiliary,
            appearance: appearance ?? self.appearance
        )
    }
}

public extension MediaMap {
    func replacingEntry(for state: PetState, with entry: MediaEntry) throws -> MediaMap {
        var updatedStates = states
        updatedStates[state] = try StateMediaPlaylist(entries: [entry])
        return try MediaMap(
            version: version,
            defaultFormat: defaultFormat,
            window: window,
            states: updatedStates
        )
    }

    func replacingWindow(_ replacement: WindowConfiguration) throws -> MediaMap {
        try MediaMap(
            version: version,
            defaultFormat: defaultFormat,
            window: replacement,
            states: states
        )
    }
}
