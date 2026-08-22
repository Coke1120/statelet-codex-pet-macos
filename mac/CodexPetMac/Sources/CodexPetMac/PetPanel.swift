import AppKit

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect, alwaysOnTop: Bool, fullScreenAuxiliary: Bool) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = alwaysOnTop
        level = alwaysOnTop ? .floating : .normal
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        if fullScreenAuxiliary {
            collectionBehavior.insert(.fullScreenAuxiliary)
        }
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
    }

    func apply(alwaysOnTop: Bool, fullScreenAuxiliary: Bool) {
        let wasAlwaysOnTop = isFloatingPanel || level == .floating
        let levelChanged = wasAlwaysOnTop != alwaysOnTop
        isFloatingPanel = alwaysOnTop
        level = alwaysOnTop ? .floating : .normal
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        if fullScreenAuxiliary {
            behavior.insert(.fullScreenAuxiliary)
        }
        if collectionBehavior != behavior {
            collectionBehavior = behavior
        }
        if levelChanged {
            if alwaysOnTop {
                orderFrontRegardless()
            } else {
                orderBack(nil)
            }
        }
    }

}
