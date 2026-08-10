import Foundation

public enum AlphaConversionProgressError: Error, Equatable, Sendable {
    case malformedProgressEvent
    case invalidEvent
    case invalidStatus
    case invalidPercent
    case invalidStage
    case invalidMessage
    case invalidCode
    case invalidSafeMessage
    case invalidFrameCounts
    case regressingPercent(previous: Double, incoming: Double)
}

public struct AlphaConversionProgress: Decodable, Equatable, Sendable {
    public let event: String
    public let status: String?
    public let percent: Double
    public let stage: String
    public let message: String
    public let completedFrames: Int?
    public let totalFrames: Int?
    public let code: String?
    public let safeMessage: String?

    public var isTerminalFailure: Bool { status == "failed" }

    private enum CodingKeys: String, CodingKey {
        case event
        case status
        case percent
        case stage
        case message
        case completedFrames = "completed_frames"
        case totalFrames = "total_frames"
        case code
        case safeMessage = "safe_message"
    }

    public init(
        percent: Double,
        stage: String,
        message: String,
        completedFrames: Int? = nil,
        totalFrames: Int? = nil,
        status: String? = nil,
        code: String? = nil,
        safeMessage: String? = nil
    ) throws {
        guard percent.isFinite, (0 ... 100).contains(percent) else {
            throw AlphaConversionProgressError.invalidPercent
        }
        guard Self.isSafeStage(stage) else { throw AlphaConversionProgressError.invalidStage }
        let safeProgressMessage = try Self.pathSafeText(
            message,
            maximumUTF8Bytes: 500,
            error: .invalidMessage
        )
        guard !safeProgressMessage.isEmpty else {
            throw AlphaConversionProgressError.invalidMessage
        }
        guard status == nil || ["running", "completed", "failed"].contains(status!) else {
            throw AlphaConversionProgressError.invalidStatus
        }
        let safeFailureMessage: String?
        if status == "failed" {
            guard let code, Self.allowedFailureCodes.contains(code) else {
                throw AlphaConversionProgressError.invalidCode
            }
            guard let safeMessage else {
                throw AlphaConversionProgressError.invalidSafeMessage
            }
            safeFailureMessage = try Self.pathSafeText(
                safeMessage,
                maximumUTF8Bytes: 256,
                error: .invalidSafeMessage
            )
            guard safeFailureMessage?.isEmpty == false else {
                throw AlphaConversionProgressError.invalidSafeMessage
            }
        } else {
            guard code == nil else { throw AlphaConversionProgressError.invalidCode }
            guard safeMessage == nil else {
                throw AlphaConversionProgressError.invalidSafeMessage
            }
            safeFailureMessage = nil
        }
        guard (completedFrames == nil) == (totalFrames == nil) else {
            throw AlphaConversionProgressError.invalidFrameCounts
        }
        if let completedFrames, let totalFrames {
            guard completedFrames >= 0, totalFrames > 0, completedFrames <= totalFrames else {
                throw AlphaConversionProgressError.invalidFrameCounts
            }
        }
        self.event = "progress"
        self.status = status
        self.percent = percent
        self.stage = stage
        self.message = safeProgressMessage
        self.completedFrames = completedFrames
        self.totalFrames = totalFrames
        self.code = code
        self.safeMessage = safeFailureMessage
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(String.self, forKey: .event) == "progress" else {
            throw AlphaConversionProgressError.invalidEvent
        }
        try self.init(
            percent: values.decode(Double.self, forKey: .percent),
            stage: values.decode(String.self, forKey: .stage),
            message: values.decode(String.self, forKey: .message),
            completedFrames: values.decodeIfPresent(Int.self, forKey: .completedFrames),
            totalFrames: values.decodeIfPresent(Int.self, forKey: .totalFrames),
            status: values.decodeIfPresent(String.self, forKey: .status),
            code: values.decodeIfPresent(String.self, forKey: .code),
            safeMessage: values.decodeIfPresent(String.self, forKey: .safeMessage)
        )
    }

    private static let allowedFailureCodes: Set<String> = [
        "TOOL_MISSING",
        "DEPENDENCY_MISSING",
        "SOURCE_UNSUPPORTED",
        "QUALITY_GATE_FAILED",
        "PROCESS_TIMEOUT",
        "RESOURCE_LIMIT",
        "PUBLICATION_FAILED",
        "CANCELLED",
        "CONVERSION_FAILED",
    ]

    private static func isSafeStage(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        return value.range(
            of: #"^[a-z][a-z0-9_-]*$"#,
            options: .regularExpression
        ) != nil
    }

    private static func pathSafeText(
        _ value: String,
        maximumUTF8Bytes: Int,
        error: AlphaConversionProgressError
    ) throws -> String {
        guard value.utf8.count <= maximumUTF8Bytes else { throw error }
        let flattened = value
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .replacingOccurrences(
                of: #"(?i)/(?:Users|Volumes|private|tmp|var|Applications|Library)/[^\r\n\"']*?\.(?:mp4|mov|m4v|json|py|png|jpe?g|heic|webm|mkv)"#,
                with: "<local-file>",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)/(?:Users|Volumes|private|tmp|var|Applications|Library)/[^\r\n\"']+"#,
                with: "<local-file>",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)(?<![a-z0-9])(?:(?:file://|~)?/[^/\s:'\"<>()\[\]{},;]+(?:/[^/\s:'\"<>()\[\]{},;]+)*)"#,
                with: "<local-file>",
                options: .regularExpression
            )
        return flattened
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

public struct AlphaConversionProgressParser: Sendable {
    private var lastPercent: Double?

    public init() {}

    public mutating func parseLine(_ line: String) throws -> AlphaConversionProgress? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            guard Self.looksLikeProgressEnvelope(trimmed) else { return nil }
            throw AlphaConversionProgressError.malformedProgressEvent
        }
        guard let dictionary = object as? [String: Any],
              dictionary["event"] as? String == "progress" else {
            return nil
        }
        let progress = try JSONDecoder().decode(AlphaConversionProgress.self, from: data)
        if let lastPercent, progress.percent < lastPercent {
            throw AlphaConversionProgressError.regressingPercent(
                previous: lastPercent,
                incoming: progress.percent
            )
        }
        lastPercent = progress.percent
        return progress
    }

    private static func looksLikeProgressEnvelope(_ line: String) -> Bool {
        guard line.first == "{" else { return false }
        return line.range(of: #"[\"']event[\"']\s*:\s*[\"']progress(?:[\"']|\z)"#, options: .regularExpression) != nil
    }
}
