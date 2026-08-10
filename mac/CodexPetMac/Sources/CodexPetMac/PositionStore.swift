import AppKit
import CodexPetCore
import CoreGraphics

final class PositionStore {
    private let defaults: UserDefaults
    private let key = "CodexPetMac.windowFrames.v2"
    private let lastFrameKey = "CodexPetMac.lastWindowFrame.v2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func frame(for screen: NSScreen?, screens: [NSScreen] = NSScreen.screens) -> NSRect? {
        let records = defaults.dictionary(forKey: key) ?? [:]
        // The global record is the authoritative last position, even when the
        // app was last dragged to a non-main display.
        if let frame = decodeFrame(defaults.dictionary(forKey: lastFrameKey)) {
            return frame
        }
        let orderedScreens = ([screen].compactMap { $0 } + screens).reduce(into: [NSScreen]()) { result, candidate in
            if !result.contains(where: { $0 === candidate }) { result.append(candidate) }
        }
        for candidate in orderedScreens {
            if let displayKey = displayKey(for: candidate),
               let frame = decodeFrame(records[displayKey]) {
                return frame
            }
        }
        return nil
    }

    func save(frame: NSRect, on screen: NSScreen?) {
        guard let screen, let displayKey = displayKey(for: screen) else { return }
        var records = defaults.dictionary(forKey: key) ?? [:]
        let encoded = [
            "x": Double(frame.origin.x),
            "y": Double(frame.origin.y),
            "width": Double(frame.size.width),
            "height": Double(frame.size.height),
        ]
        records[displayKey] = encoded
        defaults.set(records, forKey: key)
        defaults.set(encoded, forKey: lastFrameKey)
    }

    func clampedFrame(_ frame: NSRect, screens: [NSScreen] = NSScreen.screens) -> NSRect {
        let visibleFrames = screens.map(\.visibleFrame)
        return WindowFramePolicy.clamped(frame, to: visibleFrames)
    }

    private func displayKey(for screen: NSScreen) -> String? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        let displayID = CGDirectDisplayID(number.uint32Value)
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            return "uuid:\(CFUUIDCreateString(nil, uuid) as String)"
        }
        return "id:\(number.stringValue)"
    }

    private func decodeFrame(_ value: Any?) -> NSRect? {
        guard let values = value as? [String: Double],
              let x = values["x"], let y = values["y"],
              let width = values["width"], let height = values["height"],
              x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width > 0, height > 0 else { return nil }
        return NSRect(x: x, y: y, width: width, height: height)
    }
}
