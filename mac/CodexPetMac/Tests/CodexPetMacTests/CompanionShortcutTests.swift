import AppKit
import CodexPetCore
import XCTest
@testable import Statelet

@MainActor
final class CompanionShortcutTests: XCTestCase {
    func testValidationKeepsOfficialAndSystemShortcutsAvailable() {
        XCTAssertTrue(CompanionShortcut.defaultShortcut.isValid)
        let reserved: [CompanionShortcut.Modifiers] = [.option, .command, [.command, .option], [.command, .control]]
        for modifiers in reserved {
            XCTAssertFalse(CompanionShortcut(key: .space, modifiers: modifiers).isValid)
        }
        XCTAssertFalse(CompanionShortcut(key: .j, modifiers: .command).isValid)
        XCTAssertFalse(CompanionShortcut(key: .j, modifiers: [.control, .shift]).isValid)
        XCTAssertFalse(CompanionShortcut(key: .j, modifiers: CompanionShortcut.Modifiers(rawValue: 128)).isValid)
    }

    func testRegistrationConflictKeepsPreviousShortcutActiveAndSaved() throws {
        let suite = "statelet-shortcut-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = FakeHotKeys()
        let controller = CompanionShortcutController(defaults: defaults, backend: backend)
        XCTAssertEqual(controller.snapshot.registration, .active)
        let previous = try XCTUnwrap(defaults.data(forKey: CompanionShortcutController.defaultsKey))
        let candidate = CompanionShortcut(key: .k, modifiers: [.control, .option, .command])
        backend.rejectNext = .conflict
        XCTAssertFalse(controller.setShortcut(candidate))
        XCTAssertEqual(controller.snapshot.shortcut, .defaultShortcut)
        XCTAssertEqual(controller.snapshot.registration, .active)
        XCTAssertEqual(controller.snapshot.failure, .conflict)
        XCTAssertEqual(defaults.data(forKey: CompanionShortcutController.defaultsKey), previous)
        XCTAssertEqual(backend.active.count, 1)
        XCTAssertTrue(controller.setShortcut(candidate))
        XCTAssertEqual(backend.active.count, 1)
        XCTAssertEqual(controller.snapshot.shortcut, candidate)
        controller.shutdown()
        let reloaded = CompanionShortcutController(defaults: defaults, backend: backend)
        XCTAssertEqual(reloaded.snapshot.shortcut, candidate)
        reloaded.shutdown()
    }

    func testDisableResetInvalidPreferenceAndShutdownDoNotLeaveHandlers() throws {
        let suite = "statelet-shortcut-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = FakeHotKeys()
        let controller = CompanionShortcutController(defaults: defaults, backend: backend)
        var triggers = 0
        controller.onTrigger = { triggers += 1 }
        backend.trigger()
        XCTAssertEqual(triggers, 1)
        XCTAssertTrue(controller.setShortcut(nil))
        XCTAssertEqual(controller.snapshot.registration, .disabled)
        XCTAssertTrue(backend.active.isEmpty)
        controller.shutdown()
        let disabled = CompanionShortcutController(defaults: defaults, backend: backend)
        XCTAssertEqual(disabled.snapshot.registration, .disabled)
        XCTAssertTrue(disabled.setShortcut(.defaultShortcut))
        disabled.shutdown()
        XCTAssertTrue(backend.active.isEmpty)
        defaults.set(Data("private-invalid-value".utf8), forKey: CompanionShortcutController.defaultsKey)
        let invalid = CompanionShortcutController(defaults: defaults, backend: backend)
        XCTAssertEqual(invalid.snapshot.registration, .unavailable)
        XCTAssertEqual(invalid.snapshot.failure, .invalid)
        XCTAssertTrue(backend.active.isEmpty)
        XCTAssertTrue(invalid.setShortcut(.defaultShortcut))
        invalid.shutdown()
    }

    func testRepeatedToggleAndRefocusRetainDraftAttachmentsAndMini() throws {
        _ = NSApplication.shared
        let screens = [NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)]
        let controller = CompanionPanelController(visibleFrames: { screens })
        let pet = NSRect(x: screens[0].minX + 40, y: screens[0].minY + 40, width: 100, height: 180)
        controller.model.draft = "private unsent text"
        controller.model.attachments = [CompanionAttachment(name: "context", text: "private attachment")]
        controller.model.setCompact(true)
        controller.toggleShortcut(beside: pet, focused: false)
        let firstRequest = controller.model.composerFocusRequest
        XCTAssertTrue(controller.model.isPanelVisible)
        controller.toggleShortcut(beside: pet, focused: false)
        XCTAssertTrue(controller.model.isPanelVisible)
        XCTAssertGreaterThan(controller.model.composerFocusRequest, firstRequest)
        controller.toggleShortcut(beside: pet, focused: true)
        XCTAssertFalse(controller.model.isPanelVisible)
        controller.toggleShortcut(beside: pet, focused: false)
        XCTAssertTrue(controller.model.compact)
        XCTAssertEqual(controller.model.draft, "private unsent text")
        XCTAssertEqual(controller.model.attachments.first?.text, "private attachment")
        XCTAssertTrue(screens[0].contains(try XCTUnwrap(controller.window).frame))
        controller.window?.cancelOperation(nil)
        XCTAssertFalse(controller.model.isPanelVisible)
        controller.shutdown()
    }

    func testNativeExclusiveRegistrationRejectsCollisionAndReleasesReservation() throws {
        _ = NSApplication.shared
        let first = CarbonCompanionHotKeys(), second = CarbonCompanionHotKeys()
        defer { first.shutdown(); second.shutdown() }
        var reservation: (CompanionShortcut, UInt32)?
        let candidates: [CompanionShortcut.Key] = [.k, .l, .b, .y, .z]
        for key in candidates {
            let shortcut = CompanionShortcut(key: key, modifiers: [.control, .option, .shift, .command])
            if let id = try? first.register(shortcut, action: {}) { reservation = (shortcut, id); break }
        }
        let (shortcut, id) = try XCTUnwrap(reservation, "Native hotkey registration must be available on the macOS runner")
        XCTAssertThrowsError(try second.register(shortcut, action: {})) { error in
            XCTAssertEqual(error as? CompanionShortcutFailure, .conflict)
        }
        try first.unregister(id)
        _ = try second.register(shortcut, action: {})
    }

    func testSettingsKeepAttemptedCombinationAfterConflictAndExposeCurrentStatus() throws {
        _ = NSApplication.shared
        let view = CompanionShortcutSettingsView()
        let old = CompanionShortcutSnapshot(shortcut: .defaultShortcut, registration: .active)
        view.update(old)
        let popup = try XCTUnwrap(descendants(view).compactMap { $0 as? NSPopUpButton }.first)
        popup.selectItem(withTitle: "K")
        NSApp.sendAction(try XCTUnwrap(popup.action), to: popup.target, from: popup)
        var proposed: CompanionShortcut?
        view.onChange = { shortcut in proposed = shortcut; return false }
        let apply = try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first { $0.title == "Apply Shortcut" })
        NSApp.sendAction(try XCTUnwrap(apply.action), to: apply.target, from: apply)
        view.update(CompanionShortcutSnapshot(shortcut: .defaultShortcut, registration: .active, failure: .conflict))
        XCTAssertEqual(proposed?.key, .k)
        XCTAssertEqual(popup.titleOfSelectedItem, "K")
        let labels = descendants(view).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(labels.contains { $0.contains("Active: ⌃⌥⌘J") })
        XCTAssertTrue(labels.contains(CompanionShortcutFailure.conflict.message))
    }

    func testComposerOpeningFromSettingsRestoresThePreviousStateletWindow() throws {
        _ = NSApplication.shared
        let settings = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 400),
                                styleMask: [.titled], backing: .buffered, defer: false)
        defer { settings.close() }
        NSApp.activate(ignoringOtherApps: true)
        settings.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        let controller = CompanionPanelController()
        defer { controller.shutdown() }
        controller.show(beside: settings.frame, focusComposer: true)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        controller.toggleShortcut(beside: settings.frame, focused: true)
        XCTAssertFalse(controller.model.isPanelVisible)
        XCTAssertTrue(settings.isVisible)
        // The requested window is made key synchronously; physical app/Spaces
        // focus remains an installed acceptance item.
        XCTAssertTrue(settings.isKeyWindow)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private final class FakeHotKeys: CompanionHotKeyRegistering {
        var active: [UInt32: () -> Void] = [:]
        var nextID: UInt32 = 0
        var rejectNext: CompanionShortcutFailure?
        func register(_ shortcut: CompanionShortcut, action: @escaping () -> Void) throws -> UInt32 {
            if let failure = rejectNext { rejectNext = nil; throw failure }
            nextID += 1; active[nextID] = action; return nextID
        }
        func unregister(_ id: UInt32) throws { active.removeValue(forKey: id) }
        func shutdown() { active.removeAll() }
        func trigger() { active.values.first?() }
    }
}
