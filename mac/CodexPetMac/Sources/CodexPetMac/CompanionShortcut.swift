import AppKit
import Carbon
import Foundation

struct CompanionShortcut: Codable, Equatable, Sendable {
    enum Key: String, Codable, CaseIterable, Sendable {
        case a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z, space
        var label: String { self == .space ? "Space" : rawValue.uppercased() }
        var keyCode: UInt32 {
            // Stable physical key positions; no event tap or keyboard monitoring.
            let codes: [UInt32] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6, 49]
            return codes[Self.allCases.firstIndex(of: self)!]
        }
    }
    struct Modifiers: OptionSet, Codable, Equatable, Sendable {
        let rawValue: UInt32
        static let control = Self(rawValue: 1)
        static let option = Self(rawValue: 2)
        static let shift = Self(rawValue: 4)
        static let command = Self(rawValue: 8)
        var carbonFlags: UInt32 {
            (contains(.control) ? UInt32(controlKey) : 0) |
            (contains(.option) ? UInt32(optionKey) : 0) |
            (contains(.shift) ? UInt32(shiftKey) : 0) |
            (contains(.command) ? UInt32(cmdKey) : 0)
        }
    }
    let key: Key
    let modifiers: Modifiers
    static let defaultShortcut = Self(key: .j, modifiers: [.control, .option, .command])
    var isValid: Bool {
        guard modifiers.rawValue & ~UInt32(15) == 0,
              [Modifiers.control, .option, .command].filter({ modifiers.contains($0) }).count >= 2 else { return false }
        if key == .space, modifiers == [.command, .option] || modifiers == [.command, .control] { return false }
        return true
    }
    var label: String {
        (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "") +
        (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "") + key.label
    }
}

enum CompanionShortcutFailure: String, Error, Sendable {
    case invalid, conflict, unavailable
    var message: String {
        switch self {
        case .invalid: return "Choose a letter or Space with at least two of Control, Option and Command. Reserved system combinations are unavailable."
        case .conflict: return "That shortcut is already reserved. Choose another combination; your previous setting was kept."
        case .unavailable: return "The shortcut could not be registered. Choose another combination or retry; your previous setting was kept."
        }
    }
}

struct CompanionShortcutSnapshot: Equatable {
    enum Registration: String { case notChecked = "not-checked", active, disabled, unavailable }
    var shortcut: CompanionShortcut? = .defaultShortcut
    var registration: Registration = .notChecked
    var failure: CompanionShortcutFailure?
    var summary: String {
        switch registration {
        case .notChecked: return "Shortcut has not been checked."
        case .active: return "Active: \(shortcut?.label ?? "") · opens or focuses Companion; press again while focused to hide."
        case .disabled: return "Global shortcut is disabled. Companion is still available from the menu bar."
        case .unavailable: return "Global shortcut is unavailable. Choose a combination below or use the menu bar."
        }
    }
}

@MainActor
protocol CompanionHotKeyRegistering: AnyObject {
    func register(_ shortcut: CompanionShortcut, action: @escaping () -> Void) throws -> UInt32
    func unregister(_ id: UInt32) throws
    func shutdown()
}

/// Own registration and preferences together. A new registration must succeed
/// before the previous registration or saved preference can be replaced.
@MainActor
final class CompanionShortcutController {
    static let defaultsKey = "companion.globalShortcut.v1"
    private struct Preference: Codable { let enabled: Bool; let shortcut: CompanionShortcut? }
    private let defaults: UserDefaults
    private let backend: CompanionHotKeyRegistering
    private var registrationID: UInt32?
    private(set) var snapshot = CompanionShortcutSnapshot()
    var onTrigger: (() -> Void)?

    init(defaults: UserDefaults = .standard, backend: CompanionHotKeyRegistering? = nil) {
        self.defaults = defaults
        self.backend = backend ?? CarbonCompanionHotKeys()
        if defaults.object(forKey: Self.defaultsKey) == nil { _ = setShortcut(.defaultShortcut); return }
        guard let data = defaults.data(forKey: Self.defaultsKey), data.count <= 1024,
              let preference = try? JSONDecoder().decode(Preference.self, from: data),
              preference.enabled ? preference.shortcut?.isValid == true : preference.shortcut == nil else {
            snapshot = CompanionShortcutSnapshot(shortcut: nil, registration: .unavailable, failure: .invalid)
            return
        }
        snapshot.shortcut = preference.shortcut
        _ = setShortcut(preference.shortcut)
    }

    @discardableResult
    func setShortcut(_ shortcut: CompanionShortcut?) -> Bool {
        guard shortcut?.isValid != false else { snapshot.failure = .invalid; return false }
        if shortcut == snapshot.shortcut, registrationID != nil { snapshot.failure = nil; return true }
        do {
            let replacement: UInt32?
            if let shortcut { replacement = try backend.register(shortcut) { [weak self] in self?.onTrigger?() } }
            else { replacement = nil }
            do {
                if let previous = registrationID { try backend.unregister(previous) }
            } catch {
                if let replacement { try? backend.unregister(replacement) }
                throw error
            }
            registrationID = replacement
            snapshot = CompanionShortcutSnapshot(shortcut: shortcut, registration: shortcut == nil ? .disabled : .active)
            let preference = Preference(enabled: shortcut != nil, shortcut: shortcut)
            if let data = try? JSONEncoder().encode(preference) { defaults.set(data, forKey: Self.defaultsKey) }
            return true
        } catch {
            snapshot.failure = (error as? CompanionShortcutFailure) ?? .unavailable
            if registrationID == nil { snapshot.registration = .unavailable }
            return false
        }
    }

    func shutdown() { backend.shutdown(); registrationID = nil; onTrigger = nil }
}

/// Carbon's explicit hotkey registration requires no global input monitor.
/// The callback belongs to the main application event loop, and dies with this
/// owner. Use exclusive registration and inspect enabled system shortcuts.
@MainActor
final class CarbonCompanionHotKeys: CompanionHotKeyRegistering {
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 0
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var held: Set<UInt32> = []
    nonisolated private static let signature: OSType = 0x53544C54 // STLT

    func register(_ shortcut: CompanionShortcut, action: @escaping () -> Void) throws -> UInt32 {
        guard try !systemReserves(shortcut) else { throw CompanionShortcutFailure.conflict }
        if handler == nil {
            var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                         EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, UInt32(MemoryLayout<EventHotKeyID>.size), nil, &id)
                guard status == noErr, id.signature == CarbonCompanionHotKeys.signature else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated {
                    let owner = Unmanaged<CarbonCompanionHotKeys>.fromOpaque(userData).takeUnretainedValue()
                    return owner.handle(id: id.id, pressed: GetEventKind(event) == UInt32(kEventHotKeyPressed))
                }
            }, UInt32(types.count), &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard result == noErr, handler != nil else { throw CompanionShortcutFailure.unavailable }
        }
        nextID &+= 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.key.keyCode, shortcut.modifiers.carbonFlags,
            EventHotKeyID(signature: Self.signature, id: nextID), GetApplicationEventTarget(),
            UInt32(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else {
            throw status == eventHotKeyExistsErr ? CompanionShortcutFailure.conflict : .unavailable
        }
        references[nextID] = reference; actions[nextID] = action
        return nextID
    }
    func unregister(_ id: UInt32) throws {
        guard let reference = references[id] else { return }
        guard UnregisterEventHotKey(reference) == noErr else { throw CompanionShortcutFailure.unavailable }
        references.removeValue(forKey: id); actions.removeValue(forKey: id); held.remove(id)
    }
    func shutdown() {
        for reference in references.values { UnregisterEventHotKey(reference) }
        references.removeAll(); actions.removeAll(); held.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
    deinit {
        for reference in references.values { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
    private func handle(id: UInt32, pressed: Bool) -> OSStatus {
        guard let action = actions[id] else { return OSStatus(eventNotHandledErr) }
        if pressed {
            if held.insert(id).inserted { action() }
        } else { held.remove(id) }
        return noErr
    }
    private func systemReserves(_ shortcut: CompanionShortcut) throws -> Bool {
        var values: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&values) == noErr, let values else { throw CompanionShortcutFailure.unavailable }
        let keys = values.takeRetainedValue() as NSArray
        for case let key as NSDictionary in keys {
            if (key[kHISymbolicHotKeyEnabled] as? NSNumber)?.boolValue == true,
               (key[kHISymbolicHotKeyCode] as? NSNumber)?.uint32Value == shortcut.key.keyCode,
               (key[kHISymbolicHotKeyModifiers] as? NSNumber)?.uint32Value == shortcut.modifiers.carbonFlags { return true }
        }
        return false
    }
}

/// Settings owns only an editable draft. The controller above remains the
/// source of truth for the active shortcut and its saved preference.
final class CompanionShortcutSettingsView: NSView {
    var onChange: ((CompanionShortcut?) -> Bool)?
    private let keyPopup = NSPopUpButton()
    private let control = NSButton(checkboxWithTitle: "Control", target: nil, action: nil)
    private let option = NSButton(checkboxWithTitle: "Option", target: nil, action: nil)
    private let shift = NSButton(checkboxWithTitle: "Shift", target: nil, action: nil)
    private let command = NSButton(checkboxWithTitle: "Command", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let failure = NSTextField(wrappingLabelWithString: "")
    private var dirty = false

    init() {
        super.init(frame: .zero)
        keyPopup.addItems(withTitles: CompanionShortcut.Key.allCases.map(\.label))
        keyPopup.setAccessibilityLabel("Companion shortcut key")
        keyPopup.toolTip = "Uses the selected key's US keyboard position; another layout may display a different letter."
        keyPopup.target = self; keyPopup.action = #selector(editDraft)
        for button in [control, option, shift, command] {
            button.target = self; button.action = #selector(editDraft)
            button.setAccessibilityLabel("Companion shortcut \(button.title) modifier")
        }
        let controls = NSStackView(views: [control, option, shift, command, keyPopup])
        controls.orientation = .horizontal; controls.spacing = 8
        let apply = NSButton(title: "Apply Shortcut", target: self, action: #selector(applyShortcut))
        let reset = NSButton(title: "Reset Shortcut", target: self, action: #selector(resetShortcut))
        let disable = NSButton(title: "Disable Shortcut", target: self, action: #selector(disableShortcut))
        let buttons = NSStackView(views: [apply, reset, disable]); buttons.spacing = 8
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        failure.font = status.font; failure.textColor = .systemRed
        let help = NSTextField(wrappingLabelWithString: "Default: Control–Option–Command–J. Choose at least two of Control, Option and Command. Escape closes Companion without clearing your draft.")
        help.font = status.font; help.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [controls, buttons, status, failure, help])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor), failure.widthAnchor.constraint(equalTo: stack.widthAnchor),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        setDraft(.defaultShortcut)
    }
    required init?(coder: NSCoder) { nil }
    func update(_ snapshot: CompanionShortcutSnapshot) {
        status.stringValue = snapshot.summary
        failure.stringValue = snapshot.failure?.message ?? ""
        if !dirty { setDraft(snapshot.shortcut ?? .defaultShortcut) }
    }
    private func setDraft(_ shortcut: CompanionShortcut) {
        keyPopup.selectItem(at: CompanionShortcut.Key.allCases.firstIndex(of: shortcut.key)!)
        for (button, modifier) in [(control, CompanionShortcut.Modifiers.control), (option, .option), (shift, .shift), (command, .command)] {
            button.state = shortcut.modifiers.contains(modifier) ? .on : .off
        }
    }
    @objc private func editDraft() { dirty = true }
    @objc private func applyShortcut() {
        var modifiers: CompanionShortcut.Modifiers = []
        for (button, modifier) in [(control, CompanionShortcut.Modifiers.control), (option, .option), (shift, .shift), (command, .command)] {
            if button.state == .on { modifiers.insert(modifier) }
        }
        let shortcut = CompanionShortcut(key: CompanionShortcut.Key.allCases[keyPopup.indexOfSelectedItem], modifiers: modifiers)
        guard shortcut.isValid else { failure.stringValue = CompanionShortcutFailure.invalid.message; return }
        if onChange?(shortcut) == true { dirty = false }
    }
    @objc private func resetShortcut() {
        if onChange?(.defaultShortcut) == true { dirty = false; setDraft(.defaultShortcut) }
    }
    @objc private func disableShortcut() {
        if onChange?(nil) == true { dirty = false }
    }
}
