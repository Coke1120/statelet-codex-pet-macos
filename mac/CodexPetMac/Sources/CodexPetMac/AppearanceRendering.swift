import AppKit
import CodexPetCore

enum PublisherBadgeVisualStatus: Equatable {
    case checking
    case live
    case manual
    case unavailable

    var title: String {
        switch self {
        case .checking: return "Checking"
        case .live: return "Live"
        case .manual: return "Preview"
        case .unavailable: return "Offline"
        }
    }

    var color: NSColor {
        switch self {
        case .checking: return .systemGray
        case .live: return .systemGreen
        case .manual: return .systemPurple
        case .unavailable: return .systemOrange
        }
    }
}

extension NSColor {
    static func codexPet(hex: String, opacity: Double = 1) -> NSColor {
        let value = String(hex.dropFirst())
        guard hex.hasPrefix("#"), value.count == 6,
              let rgb = UInt32(value, radix: 16) else {
            return NSColor.clear
        }
        let red = CGFloat((rgb >> 16) & 0xff) / 255
        let green = CGFloat((rgb >> 8) & 0xff) / 255
        let blue = CGFloat(rgb & 0xff) / 255
        let alpha = CGFloat(max(0, min(opacity, 1)))
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    var codexPetHex: String {
        guard let color = usingColorSpace(.sRGB) else { return "#000000" }
        return String(
            format: "#%02X%02X%02X",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
        )
    }
}

final class PetStateBadgeView: NSView {
    private let symbolView = NSImageView()
    private let stateLabel = NSTextField(labelWithString: "Idle")
    private let healthLabel = NSTextField(labelWithString: "Checking")
    private let stack = NSStackView()
    private var symbolWidthConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        symbolView.imageScaling = .scaleProportionallyUpOrDown
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        healthLabel.font = .systemFont(ofSize: 9, weight: .medium)
        healthLabel.textColor = .secondaryLabelColor

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.addArrangedSubview(symbolView)
        stack.addArrangedSubview(stateLabel)
        stack.addArrangedSubview(healthLabel)
        addSubview(stack)

        symbolWidthConstraint = symbolView.widthAnchor.constraint(equalToConstant: 14)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            symbolWidthConstraint,
            symbolView.heightAnchor.constraint(equalTo: symbolView.widthAnchor),
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let content = stack.fittingSize
        return NSSize(width: ceil(content.width + 18), height: ceil(max(content.height + 10, 24)))
    }

    func update(
        state: PetState,
        publisherStatus: PublisherBadgeVisualStatus,
        size: StateLabelSize,
        reduceTransparency: Bool,
        increaseContrast: Bool,
        customColor: NSColor? = nil,
        stateTitle: String? = nil
    ) {
        let metrics: (state: CGFloat, health: CGFloat, symbol: CGFloat, spacing: CGFloat)
        switch size {
        case .small: metrics = (10, 8, 12, 5)
        case .regular: metrics = (12, 9, 14, 6)
        case .large: metrics = (14, 10, 17, 7)
        }
        stateLabel.font = .systemFont(ofSize: metrics.state, weight: .semibold)
        healthLabel.font = .systemFont(ofSize: metrics.health, weight: .medium)
        symbolWidthConstraint.constant = metrics.symbol
        stack.spacing = metrics.spacing

        let accentColor = customColor ?? state.badgeAccentColor
        stateLabel.stringValue = stateTitle ?? state.badgeTitle
        stateLabel.textColor = accentColor
        healthLabel.stringValue = publisherStatus.title
        healthLabel.textColor = publisherStatus.color
        symbolView.image = NSImage(
            systemSymbolName: state.badgeSymbolName,
            accessibilityDescription: state.badgeTitle
        )
        symbolView.contentTintColor = accentColor

        let fillOpacity: CGFloat = reduceTransparency ? 1 : 0.88
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(fillOpacity).cgColor
        layer?.borderColor = accentColor.withAlphaComponent(increaseContrast ? 0.95 : 0.55).cgColor
        layer?.borderWidth = increaseContrast ? 2 : 1
        layer?.cornerRadius = max(12, intrinsicContentSize.height / 2)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
}

private extension PetState {
    var badgeTitle: String { rawValue.capitalized }

    var badgeSymbolName: String {
        switch self {
        case .idle: return "moon.stars"
        case .running: return "bolt.fill"
        case .waiting: return "hand.raised.fill"
        case .review: return "checkmark.seal.fill"
        }
    }

    var badgeAccentColor: NSColor {
        switch self {
        case .idle: return .systemTeal
        case .running: return .systemBlue
        case .waiting: return .systemOrange
        case .review: return .systemIndigo
        }
    }
}
