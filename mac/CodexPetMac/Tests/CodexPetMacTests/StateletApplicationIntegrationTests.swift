import AppKit
import Darwin
import XCTest
@testable import Statelet

final class StateletApplicationIntegrationTests: XCTestCase {
    private final class SettingsTarget: NSObject {
        @objc func showSettings() {}
    }

    @MainActor
    func testMainMenuProvidesStandardMacOSCommands() throws {
        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        let previousServicesMenu = application.servicesMenu
        let previousWindowsMenu = application.windowsMenu
        defer {
            application.mainMenu = previousMainMenu
            application.servicesMenu = previousServicesMenu
            application.windowsMenu = previousWindowsMenu
        }
        let target = SettingsTarget()
        StateletMainMenu.install(
            on: application,
            settingsTarget: target,
            settingsAction: #selector(SettingsTarget.showSettings)
        )
        let menus = StateletMainMenu.Menus(
            main: try XCTUnwrap(application.mainMenu),
            services: try XCTUnwrap(application.servicesMenu),
            windows: try XCTUnwrap(application.windowsMenu)
        )

        XCTAssertEqual(menus.main.items.compactMap(\.submenu?.title), ["Statelet", "File", "Edit", "Window"])
        XCTAssertTrue(try XCTUnwrap(menu(named: "Statelet", in: menus.main)).items.contains {
            $0.submenu === menus.services
        })
        XCTAssertEqual(shortcut("Settings…", in: menus.main), Shortcut(key: ",", modifiers: [.command]))
        XCTAssertEqual(shortcut("Quit Statelet", in: menus.main), Shortcut(key: "q", modifiers: [.command]))
        XCTAssertEqual(shortcut("Close Window", in: menus.main), Shortcut(key: "w", modifiers: [.command]))
        XCTAssertEqual(shortcut("Undo", in: menus.main), Shortcut(key: "z", modifiers: [.command]))
        XCTAssertEqual(shortcut("Redo", in: menus.main), Shortcut(key: "z", modifiers: [.command, .shift]))
        XCTAssertEqual(shortcut("Cut", in: menus.main), Shortcut(key: "x", modifiers: [.command]))
        XCTAssertEqual(shortcut("Copy", in: menus.main), Shortcut(key: "c", modifiers: [.command]))
        XCTAssertEqual(shortcut("Paste", in: menus.main), Shortcut(key: "v", modifiers: [.command]))
        XCTAssertEqual(shortcut("Select All", in: menus.main), Shortcut(key: "a", modifiers: [.command]))
        XCTAssertEqual(shortcut("Minimize", in: menus.main), Shortcut(key: "m", modifiers: [.command]))

        let close = try XCTUnwrap(item(named: "Close Window", in: menus.main))
        XCTAssertEqual(close.action, #selector(NSWindow.performClose(_:)))
        XCTAssertNil(close.target, "Close Window must follow the active window responder chain")
        let quit = try XCTUnwrap(item(named: "Quit Statelet", in: menus.main))
        XCTAssertEqual(quit.action, #selector(NSApplication.terminate(_:)))
        XCTAssertTrue(quit.target === NSApplication.shared)
        XCTAssertTrue(menus.windows.items.contains { $0.title == "Bring All to Front" })

    }

    func testAccessoryApplicationDeliversCommandWAndCommandQThroughInstalledMainMenu() throws {
        let productsDirectory = Bundle(for: StateletApplicationIntegrationTests.self)
            .bundleURL
            .deletingLastPathComponent()
        let executableURL = productsDirectory.appendingPathComponent("statelet")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executableURL.path))

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--statelet-shortcut-smoke-helper"]
        let completed = expectation(description: "shortcut smoke helper completed")
        process.terminationHandler = { _ in completed.fulfill() }
        try process.run()
        wait(for: [completed], timeout: 10)
        if process.isRunning { process.terminate() }
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testRelauncherWaitsForCurrentProcessAndKeepsPathOutOfShellSource() throws {
        let applicationURL = URL(fileURLWithPath: "/tmp/Statelet $USER; safe.app", isDirectory: true)
        var launchedExecutable: URL?
        var launchedArguments: [String] = []

        try StateletAppRelauncher.scheduleRelaunch(
            afterProcessIdentifier: 42_424,
            applicationURL: applicationURL
        ) { executable, arguments in
            launchedExecutable = executable
            launchedArguments = arguments
            return 12_345
        }

        XCTAssertEqual(launchedExecutable?.path, "/bin/sh")
        XCTAssertEqual(launchedArguments.count, 5)
        XCTAssertEqual(launchedArguments[0], "-c")
        XCTAssertEqual(launchedArguments[2], "statelet-relaunch")
        XCTAssertEqual(launchedArguments[3], "42424")
        XCTAssertEqual(launchedArguments[4], applicationURL.standardizedFileURL.path)
        XCTAssertTrue(launchedArguments[1].contains("/bin/ps -p \"$1\" -o lstart="))
        XCTAssertTrue(launchedArguments[1].contains("\"$attempt\" -lt 1200"))
        XCTAssertTrue(launchedArguments[1].contains("/usr/bin/open \"$2\""))
        XCTAssertFalse(launchedArguments[1].contains(applicationURL.path))
        XCTAssertFalse(launchedArguments[1].contains("42424"))
    }

    func testRelauncherRejectsInvalidInputsBeforeLaunching() {
        var launchCount = 0
        let launcher: StateletAppRelauncher.ProcessLauncher = { _, _ in
            launchCount += 1
            return 1
        }

        XCTAssertThrowsError(
            try StateletAppRelauncher.scheduleRelaunch(
                afterProcessIdentifier: 0,
                applicationURL: URL(fileURLWithPath: "/tmp/Statelet.app"),
                launcher: launcher
            )
        )
        XCTAssertThrowsError(
            try StateletAppRelauncher.scheduleRelaunch(
                afterProcessIdentifier: 1,
                applicationURL: URL(string: "https://example.com/Statelet.app")!,
                launcher: launcher
            )
        )
        XCTAssertThrowsError(
            try StateletAppRelauncher.scheduleRelaunch(
                afterProcessIdentifier: 1,
                applicationURL: URL(fileURLWithPath: "/tmp/Statelet.zip"),
                launcher: launcher
            )
        )
        XCTAssertEqual(launchCount, 0)
    }

    func testDefaultRelauncherSpawnsDetachedHelperAndWaitsForObservedProcess() throws {
        let observed = Process()
        observed.executableURL = URL(fileURLWithPath: "/bin/sleep")
        observed.arguments = ["0.4"]
        try observed.run()

        let start = Date()
        let helperPID = try StateletAppRelauncher.scheduleRelaunch(
            afterProcessIdentifier: observed.processIdentifier,
            applicationURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("Missing Statelet \(UUID().uuidString).app", isDirectory: true)
        )
        XCTAssertEqual(getsid(helperPID), helperPID, "The helper must survive a launchd-managed parent exit")
        usleep(100_000)
        var earlyStatus: Int32 = 0
        XCTAssertEqual(
            waitpid(helperPID, &earlyStatus, WNOHANG),
            0,
            "The helper must not exit while the observed process is still alive"
        )
        observed.waitUntilExit()

        var status: Int32 = 0
        var reaped = false
        let deadline = Date(timeIntervalSinceNow: 5)
        while Date() < deadline {
            let result = waitpid(helperPID, &status, WNOHANG)
            if result == helperPID {
                reaped = true
                break
            }
            if result == -1, errno != EINTR {
                break
            }
            usleep(20_000)
        }
        if !reaped {
            _ = Darwin.kill(helperPID, SIGKILL)
            _ = waitpid(helperPID, &status, 0)
        }

        XCTAssertTrue(reaped, "The relaunch helper should finish promptly after the observed process exits")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.25)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testDefaultRelauncherOpensPromptlyWhenObservedProcessAlreadyExited() throws {
        let observed = Process()
        observed.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try observed.run()
        observed.waitUntilExit()

        let helperPID = try StateletAppRelauncher.scheduleRelaunch(
            afterProcessIdentifier: observed.processIdentifier,
            applicationURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("Missing Statelet \(UUID().uuidString).app", isDirectory: true)
        )
        var status: Int32 = 0
        let deadline = Date(timeIntervalSinceNow: 2)
        var reaped = false
        while Date() < deadline {
            if waitpid(helperPID, &status, WNOHANG) == helperPID {
                reaped = true
                break
            }
            usleep(20_000)
        }
        if !reaped {
            _ = Darwin.kill(helperPID, SIGKILL)
            _ = waitpid(helperPID, &status, 0)
        }
        XCTAssertTrue(reaped, "An already-exited parent must not strand the relaunch helper")
    }

    private struct Shortcut: Equatable {
        let key: String
        let modifiers: NSEvent.ModifierFlags
    }

    private func shortcut(_ title: String, in mainMenu: NSMenu) -> Shortcut? {
        guard let item = item(named: title, in: mainMenu) else { return nil }
        return Shortcut(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
    }

    private func menu(named title: String, in mainMenu: NSMenu) -> NSMenu? {
        mainMenu.items.lazy.compactMap(\.submenu).first { $0.title == title }
    }

    private func item(named title: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title { return item }
            if let submenu = item.submenu, let match = self.item(named: title, in: submenu) {
                return match
            }
        }
        return nil
    }
}
