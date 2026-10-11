import Foundation

/// Companion needs its entire composer reachable, including after a display
/// disappears. The desktop pet's partial-visibility policy is intentionally separate.
public enum CompanionFramePolicy {
    public static func beside(_ pet: CGRect, size: CGSize, visibleFrames: [CGRect]) -> CGRect {
        guard let screen = target(for: pet, visibleFrames: visibleFrames) else { return CGRect(origin: pet.origin, size: size) }
        var frame = CGRect(x: pet.maxX + 12, y: pet.midY - size.height / 2, width: size.width, height: size.height)
        if frame.maxX > screen.maxX { frame.origin.x = pet.minX - frame.width - 12 }
        return fit(frame, to: screen)
    }
    public static func fitting(_ frame: CGRect, visibleFrames: [CGRect]) -> CGRect {
        guard let screen = target(for: frame, visibleFrames: visibleFrames) else { return frame }
        return fit(frame, to: screen)
    }
    private static func target(for frame: CGRect, visibleFrames: [CGRect]) -> CGRect? {
        let screens = visibleFrames.filter { !$0.isNull && !$0.isInfinite && $0.width > 0 && $0.height > 0 }
        let overlapping = screens.max { area($0.intersection(frame)) < area($1.intersection(frame)) }
        if let overlapping, area(overlapping.intersection(frame)) > 0 { return overlapping }
        return screens.min { distance(frame, $0) < distance(frame, $1) }
    }
    private static func area(_ frame: CGRect) -> CGFloat { frame.isNull ? 0 : frame.width * frame.height }
    private static func distance(_ frame: CGRect, _ screen: CGRect) -> CGFloat {
        let x = max(screen.minX, min(frame.midX, screen.maxX)) - frame.midX
        let y = max(screen.minY, min(frame.midY, screen.maxY)) - frame.midY
        return x * x + y * y
    }
    private static func fit(_ frame: CGRect, to screen: CGRect) -> CGRect {
        let width = min(max(1, frame.width), screen.width), height = min(max(1, frame.height), screen.height)
        return CGRect(x: max(screen.minX, min(frame.minX, screen.maxX - width)),
                      y: max(screen.minY, min(frame.minY, screen.maxY - height)), width: width, height: height)
    }
}
