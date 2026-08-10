import Foundation

public struct ValidatedAlphaConversionReport: Equatable, Sendable {
    public let outputBasename: String
    public let outputSHA256: String
    public let sourceSHA256: String
    public let width: Int
    public let height: Int
    public let frames: Int
    public let fps: String
}

public enum AlphaConversionReportValidationError: Error, Equatable, LocalizedError {
    case malformedReport
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
    public static func validate(
        data: Data,
        expectedOutputBasename: String,
        actualOutputSHA256: String
    ) throws -> ValidatedAlphaConversionReport {
        let report: AlphaConversionReport
        do {
            report = try JSONDecoder().decode(AlphaConversionReport.self, from: data)
        } catch {
            throw AlphaConversionReportValidationError.malformedReport
        }

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

        return ValidatedAlphaConversionReport(
            outputBasename: report.artifacts.outputName,
            outputSHA256: reportedOutputHash,
            sourceSHA256: sourceHash,
            width: delivery.width,
            height: delivery.height,
            frames: delivery.frames,
            fps: delivery.fps
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
}

private struct AlphaConversionReport: Decodable {
    let status: String
    let geometry: Geometry
    let codec: Codec
    let verification: Verification
    let artifacts: Artifacts

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
