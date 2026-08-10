import CoreGraphics
import Foundation

public enum WindowFramePolicy {
    /// Applies the current configured size while retaining the persisted
    /// desktop origin. The caller should clamp the result against live screens.
    public static func applyingConfiguredSize(_ size: CGSize, to storedFrame: CGRect) -> CGRect {
        CGRect(origin: storedFrame.origin, size: size)
    }

    /// Returns a frame that leaves at least `minimumVisible` points visible on
    /// the nearest active display. A frame already visible on any display is
    /// only adjusted when it falls outside all visible frames.
    public static func clamped(
        _ frame: CGRect,
        to visibleFrames: [CGRect],
        minimumVisible: CGFloat = 48
    ) -> CGRect {
        guard !visibleFrames.isEmpty else { return frame }
        guard frame.width > 0, frame.height > 0 else {
            return centeredFrame(in: visibleFrames[0], size: CGSize(width: 320, height: 480))
        }

        let requiredVisible = max(minimumVisible, 0)
        if visibleFrames.contains(where: {
            let intersection = $0.intersection(frame)
            return intersection.width >= requiredVisible && intersection.height >= requiredVisible
        }) {
            return frame
        }

        let target = visibleFrames.min {
            squaredDistance(frame.midX, frame.midY, $0.midX, $0.midY)
                < squaredDistance(frame.midX, frame.midY, $1.midX, $1.midY)
        } ?? visibleFrames[0]

        let horizontalMargin = min(requiredVisible, target.width)
        let verticalMargin = min(requiredVisible, target.height)
        let x: CGFloat
        let y: CGFloat

        // The whole window need not fit on a small display, but at least one
        // reachable square must remain available for dragging it back.
        x = min(max(frame.origin.x, target.minX - frame.width + horizontalMargin), target.maxX - horizontalMargin)
        y = min(max(frame.origin.y, target.minY - frame.height + verticalMargin), target.maxY - verticalMargin)

        return CGRect(x: x, y: y, width: frame.width, height: frame.height)
    }

    public static func centeredFrame(in visibleFrame: CGRect, size: CGSize) -> CGRect {
        CGRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func squaredDistance(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> CGFloat {
        let dx = x1 - x2
        let dy = y1 - y2
        return dx * dx + dy * dy
    }
}
