import Foundation

public struct PetAppearanceConfiguration: Codable, Equatable, Sendable {
    public enum StateLabelPosition: String, Codable, CaseIterable, Sendable {
        case topLeft = "top_left"
        case topRight = "top_right"
        case bottomLeft = "bottom_left"
        case bottomRight = "bottom_right"
    }

    public enum StateLabelSize: String, Codable, CaseIterable, Sendable {
        case small
        case regular
        case large
    }

    public enum StateLabelColorReplacement: Equatable, Sendable {
        case unchanged
        case automatic
        case custom(String)
    }

    public static let defaultBackgroundColor = "#20242A"
    public static let defaultBorderColor = "#FFFFFF"
    public static let defaultFPSColor = "#00FF00"

    public let backgroundEnabled: Bool
    public let backgroundColor: String
    public let backgroundOpacity: Double
    public let borderEnabled: Bool
    public let borderColor: String
    public let borderOpacity: Double
    public let borderWidth: Double
    public let cornerRadius: Double
    public let showStateLabel: Bool
    public let stateLabelPosition: StateLabelPosition
    public let stateLabelSize: StateLabelSize
    public let stateLabelColor: String?
    public let showFPS: Bool
    public let fpsColor: String
    public let fpsLabelSize: StateLabelSize

    public init(
        backgroundEnabled: Bool = true,
        backgroundColor: String = Self.defaultBackgroundColor,
        backgroundOpacity: Double = 0.28,
        borderEnabled: Bool = true,
        borderColor: String = Self.defaultBorderColor,
        borderOpacity: Double = 0.24,
        borderWidth: Double = 1.0,
        cornerRadius: Double = 22.0,
        showStateLabel: Bool = true,
        stateLabelPosition: StateLabelPosition = .topLeft,
        stateLabelSize: StateLabelSize = .regular,
        stateLabelColor: String? = nil,
        showFPS: Bool = true,
        fpsColor: String = Self.defaultFPSColor,
        fpsLabelSize: StateLabelSize = .small
    ) throws {
        self.backgroundColor = try Self.normalizedColor(backgroundColor, name: "background_color")
        self.borderColor = try Self.normalizedColor(borderColor, name: "border_color")
        self.fpsColor = try Self.normalizedColor(fpsColor, name: "fps_color")
        self.stateLabelColor = try stateLabelColor.map {
            try Self.normalizedColor($0, name: "state_label_color")
        }
        try Self.validate(backgroundOpacity, in: 0...1, name: "background_opacity")
        try Self.validate(borderOpacity, in: 0...1, name: "border_opacity")
        try Self.validate(borderWidth, in: 0...12, name: "border_width")
        try Self.validate(cornerRadius, in: 0...256, name: "corner_radius")

        self.backgroundEnabled = backgroundEnabled
        self.backgroundOpacity = backgroundOpacity
        self.borderEnabled = borderEnabled
        self.borderOpacity = borderOpacity
        self.borderWidth = borderWidth
        self.cornerRadius = cornerRadius
        self.showStateLabel = showStateLabel
        self.stateLabelPosition = stateLabelPosition
        self.stateLabelSize = stateLabelSize
        self.showFPS = showFPS
        self.fpsLabelSize = fpsLabelSize
    }

    private enum CodingKeys: String, CodingKey {
        case backgroundEnabled = "background_enabled"
        case backgroundColor = "background_color"
        case backgroundOpacity = "background_opacity"
        case borderEnabled = "border_enabled"
        case borderColor = "border_color"
        case borderOpacity = "border_opacity"
        case borderWidth = "border_width"
        case cornerRadius = "corner_radius"
        case showStateLabel = "show_state_label"
        case stateLabelPosition = "state_label_position"
        case stateLabelSize = "state_label_size"
        case stateLabelColor = "state_label_color"
        case showFPS = "show_fps"
        case fpsColor = "fps_color"
        case fpsLabelSize = "fps_label_size"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            backgroundEnabled: try container.decodeIfPresent(Bool.self, forKey: .backgroundEnabled) ?? true,
            backgroundColor: try container.decodeIfPresent(String.self, forKey: .backgroundColor) ?? Self.defaultBackgroundColor,
            backgroundOpacity: try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.28,
            borderEnabled: try container.decodeIfPresent(Bool.self, forKey: .borderEnabled) ?? true,
            borderColor: try container.decodeIfPresent(String.self, forKey: .borderColor) ?? Self.defaultBorderColor,
            borderOpacity: try container.decodeIfPresent(Double.self, forKey: .borderOpacity) ?? 0.24,
            borderWidth: try container.decodeIfPresent(Double.self, forKey: .borderWidth) ?? 1.0,
            cornerRadius: try container.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 22.0,
            showStateLabel: try container.decodeIfPresent(Bool.self, forKey: .showStateLabel) ?? true,
            stateLabelPosition: try container.decodeIfPresent(StateLabelPosition.self, forKey: .stateLabelPosition) ?? .topLeft,
            stateLabelSize: try container.decodeIfPresent(StateLabelSize.self, forKey: .stateLabelSize) ?? .regular,
            stateLabelColor: try container.decodeIfPresent(String.self, forKey: .stateLabelColor),
            showFPS: try container.decodeIfPresent(Bool.self, forKey: .showFPS) ?? true,
            fpsColor: try container.decodeIfPresent(String.self, forKey: .fpsColor) ?? Self.defaultFPSColor,
            fpsLabelSize: try container.decodeIfPresent(StateLabelSize.self, forKey: .fpsLabelSize) ?? .small
        )
    }

    public func replacing(
        backgroundEnabled: Bool? = nil,
        backgroundColor: String? = nil,
        backgroundOpacity: Double? = nil,
        borderEnabled: Bool? = nil,
        borderColor: String? = nil,
        borderOpacity: Double? = nil,
        borderWidth: Double? = nil,
        cornerRadius: Double? = nil,
        showStateLabel: Bool? = nil,
        stateLabelPosition: StateLabelPosition? = nil,
        stateLabelSize: StateLabelSize? = nil,
        stateLabelColor: StateLabelColorReplacement = .unchanged,
        showFPS: Bool? = nil,
        fpsColor: String? = nil,
        fpsLabelSize: StateLabelSize? = nil
    ) throws -> PetAppearanceConfiguration {
        let replacementStateLabelColor: String?
        switch stateLabelColor {
        case .unchanged:
            replacementStateLabelColor = self.stateLabelColor
        case .automatic:
            replacementStateLabelColor = nil
        case let .custom(color):
            replacementStateLabelColor = color
        }

        return try PetAppearanceConfiguration(
            backgroundEnabled: backgroundEnabled ?? self.backgroundEnabled,
            backgroundColor: backgroundColor ?? self.backgroundColor,
            backgroundOpacity: backgroundOpacity ?? self.backgroundOpacity,
            borderEnabled: borderEnabled ?? self.borderEnabled,
            borderColor: borderColor ?? self.borderColor,
            borderOpacity: borderOpacity ?? self.borderOpacity,
            borderWidth: borderWidth ?? self.borderWidth,
            cornerRadius: cornerRadius ?? self.cornerRadius,
            showStateLabel: showStateLabel ?? self.showStateLabel,
            stateLabelPosition: stateLabelPosition ?? self.stateLabelPosition,
            stateLabelSize: stateLabelSize ?? self.stateLabelSize,
            stateLabelColor: replacementStateLabelColor,
            showFPS: showFPS ?? self.showFPS,
            fpsColor: fpsColor ?? self.fpsColor,
            fpsLabelSize: fpsLabelSize ?? self.fpsLabelSize
        )
    }

    private static func normalizedColor(_ value: String, name: String) throws -> String {
        let bytes = Array(value.utf8)
        guard bytes.count == 7, bytes.first == 35,
              bytes.dropFirst().allSatisfy({ byte in
                  (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
              }) else {
            throw PetContractError.invalidValue("\(name) must use #RRGGBB format")
        }
        return value.uppercased()
    }

    private static func validate(_ value: Double, in range: ClosedRange<Double>, name: String) throws {
        guard value.isFinite, range.contains(value) else {
            throw PetContractError.invalidValue("\(name) must be between \(range.lowerBound) and \(range.upperBound)")
        }
    }
}

public typealias StateLabelPosition = PetAppearanceConfiguration.StateLabelPosition
public typealias StateLabelSize = PetAppearanceConfiguration.StateLabelSize
