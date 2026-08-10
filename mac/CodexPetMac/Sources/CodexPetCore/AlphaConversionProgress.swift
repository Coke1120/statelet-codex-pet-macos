import Foundation

public enum AlphaConversionProgressError: Error, Equatable, Sendable {
    case malformedProgressEvent
    case invalidEvent
    case invalidPercent
    case invalidStage
    case invalidMessage
    case invalidFrameCounts
    case regressingPercent(previous: Double, incoming: Double)
}

public struct AlphaConversionProgress: Decodable, Equatable, Sendable {
    public let event: String
    public let percent: Double
    public let stage: String
    public let message: String
    public let completedFrames: Int?
    public let totalFrames: Int?

    private enum CodingKeys: String, CodingKey {
        case event
        case percent
        case stage
        case message
        case completedFrames = "completed_frames"
        case totalFrames = "total_frames"
    }

    public init(
        percent: Double,
        stage: String,
        message: String,
        completedFrames: Int? = nil,
        totalFrames: Int? = nil
    ) throws {
        guard percent.isFinite, (0 ... 100).contains(percent) else {
            throw AlphaConversionProgressError.invalidPercent
        }
        let safeStage = Self.pathSafeText(stage)
        let safeMessage = Self.pathSafeText(message)
        guard !safeStage.isEmpty else { throw AlphaConversionProgressError.invalidStage }
        guard !safeMessage.isEmpty else { throw AlphaConversionProgressError.invalidMessage }
        guard (completedFrames == nil) == (totalFrames == nil) else {
            throw AlphaConversionProgressError.invalidFrameCounts
        }
        if let completedFrames, let totalFrames {
            guard completedFrames >= 0, totalFrames > 0, completedFrames <= totalFrames else {
                throw AlphaConversionProgressError.invalidFrameCounts
            }
        }
        self.event = "progress"
        self.percent = percent
        self.stage = safeStage
        self.message = safeMessage
        self.completedFrames = completedFrames
        self.totalFrames = totalFrames
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
            totalFrames: values.decodeIfPresent(Int.self, forKey: .totalFrames)
        )
    }

    private static func pathSafeText(_ value: String) -> String {
        let flattened = value
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .replacingOccurrences(
                of: #"(?i)(?<![a-z0-9])(?:(?:file://|~)?/[^/\s:'\"<>()\[\]{},;]+(?:/[^/\s:'\"<>()\[\]{},;]+)*)"#,
                with: "<local-file>",
                options: .regularExpression
            )
        return flattened
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .prefix(500)
            .description
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
