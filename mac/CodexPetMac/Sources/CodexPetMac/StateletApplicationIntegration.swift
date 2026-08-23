import AppKit
import Darwin
import Foundation

enum StateletMainMenu {
    struct Menus {
        let main: NSMenu
        let services: NSMenu
        let windows: NSMenu
    }

    static func install(
        on application: NSApplication,
        settingsTarget: AnyObject,
        settingsAction: Selector
    ) {
        let menus = make(
            application: application,
            settingsTarget: settingsTarget,
            settingsAction: settingsAction
        )
        application.mainMenu = menus.main
        application.servicesMenu = menus.services
        application.windowsMenu = menus.windows
    }

    static func make(
        application: NSApplication,
        settingsTarget: AnyObject,
        settingsAction: Selector
    ) -> Menus {
        let mainMenu = NSMenu(title: "Main Menu")

        let appMenu = NSMenu(title: "Statelet")
        appMenu.addItem(
            item(
                title: "About Statelet",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                target: application
            )
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            item(
                title: "Settings…",
                action: settingsAction,
                keyEquivalent: ",",
                target: settingsTarget
            )
        )
        appMenu.addItem(.separator())

        let servicesMenu = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())
        appMenu.addItem(
            item(
                title: "Hide Statelet",
                action: #selector(NSApplication.hide(_:)),
                keyEquivalent: "h",
                target: application
            )
        )
        let hideOthers = item(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h",
            target: application
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(
            item(
                title: "Show All",
                action: #selector(NSApplication.unhideAllApplications(_:)),
                target: application
            )
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            item(
                title: "Quit Statelet",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q",
                target: application
            )
        )
        addTopLevelMenu(appMenu, to: mainMenu)

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(
            item(
                title: "Close Window",
                action: #selector(NSWindow.performClose(_:)),
                keyEquivalent: "w"
            )
        )
        addTopLevelMenu(fileMenu, to: mainMenu)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(item(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = item(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(item(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(item(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(item(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(item(title: "Delete", action: #selector(NSText.delete(_:))))
        editMenu.addItem(.separator())
        editMenu.addItem(item(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        addTopLevelMenu(editMenu, to: mainMenu)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            item(
                title: "Minimize",
                action: #selector(NSWindow.performMiniaturize(_:)),
                keyEquivalent: "m"
            )
        )
        windowMenu.addItem(item(title: "Zoom", action: #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            item(
                title: "Bring All to Front",
                action: #selector(NSApplication.arrangeInFront(_:)),
                target: application
            )
        )
        addTopLevelMenu(windowMenu, to: mainMenu)

        return Menus(main: mainMenu, services: servicesMenu, windows: windowMenu)
    }

    private static func addTopLevelMenu(_ submenu: NSMenu, to mainMenu: NSMenu) {
        let menuItem = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        menuItem.submenu = submenu
        mainMenu.addItem(menuItem)
    }

    private static func item(
        title: String,
        action: Selector?,
        keyEquivalent: String = "",
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        return item
    }
}

enum StateletShortcutSmokeHelper {
    private final class SettingsTarget: NSObject {
        @objc func showSettings() {}
    }

    static func run() -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let settingsTarget = SettingsTarget()
        StateletMainMenu.install(
            on: application,
            settingsTarget: settingsTarget,
            settingsAction: #selector(SettingsTarget.showSettings)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        application.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        DispatchQueue.main.async {
            deliverShortcuts(
                application: application,
                window: window,
                settingsTarget: settingsTarget,
                readinessDeadline: Date(timeIntervalSinceNow: 5)
            )
        }
        application.run()
        exit(0)
    }

    private static func deliverShortcuts(
        application: NSApplication,
        window: NSWindow,
        settingsTarget: SettingsTarget,
        readinessDeadline: Date
    ) {
        guard application.keyWindow === window else {
            guard Date() < readinessDeadline else { exit(2) }
            application.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                deliverShortcuts(
                    application: application,
                    window: window,
                    settingsTarget: settingsTarget,
                    readinessDeadline: readinessDeadline
                )
            }
            return
        }
        guard let mainMenu = application.mainMenu,
              let commandW = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "w",
                charactersIgnoringModifiers: "w",
                isARepeat: false,
                keyCode: 13
              ),
              mainMenu.performKeyEquivalent(with: commandW) else {
            exit(3)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            _ = settingsTarget
            guard !window.isVisible,
                  let commandQ = NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: .command,
                    timestamp: 0,
                    windowNumber: 0,
                    context: nil,
                    characters: "q",
                    charactersIgnoringModifiers: "q",
                    isARepeat: false,
                    keyCode: 12
                  ) else {
                exit(4)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(6) }
            guard mainMenu.performKeyEquivalent(with: commandQ) else { exit(5) }
        }
    }
}

enum StateletAppRelauncher {
    typealias ProcessLauncher = (URL, [String]) throws -> pid_t

    enum RelaunchError: Error {
        case invalidProcessIdentifier
        case invalidApplicationURL
    }

    private static let helperScript = """
    started=$(/bin/ps -p "$1" -o lstart=)
    if [ -n "$started" ]; then
        attempt=0
        while [ "$(/bin/ps -p "$1" -o lstart=)" = "$started" ]; do
            [ "$attempt" -lt 1200 ] || exit 1
            /bin/sleep 0.1
            attempt=$((attempt + 1))
        done
    fi
    exec /usr/bin/open "$2"
    """

    @discardableResult
    static func scheduleRelaunch(
        afterProcessIdentifier processIdentifier: pid_t = getpid(),
        applicationURL: URL = StateletUpdateInstaller.installedAppURL(),
        launcher: ProcessLauncher? = nil
    ) throws -> pid_t {
        guard processIdentifier > 0 else {
            throw RelaunchError.invalidProcessIdentifier
        }
        let applicationURL = applicationURL.standardizedFileURL
        guard applicationURL.isFileURL,
              applicationURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            throw RelaunchError.invalidApplicationURL
        }
        let executableURL = URL(fileURLWithPath: "/bin/sh")
        let arguments = [
            "-c",
            helperScript,
            "statelet-relaunch",
            String(processIdentifier),
            applicationURL.path,
        ]
        return try (launcher ?? launchProcess)(executableURL, arguments)
    }

    private static func launchProcess(executableURL: URL, arguments: [String]) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        try checkSpawn(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        try "/dev/null".withCString { path in
            try checkSpawn(posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, path, O_RDONLY, 0))
            try checkSpawn(posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, path, O_WRONLY, 0))
            try checkSpawn(posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, path, O_WRONLY, 0))
        }

        var attributes: posix_spawnattr_t?
        try checkSpawn(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
        try checkSpawn(posix_spawnattr_setflags(&attributes, flags))

        let argumentStrings = [executableURL.path] + arguments
        let argumentStorage: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { strdup($0) }
        guard argumentStorage.allSatisfy({ $0 != nil }) else {
            argumentStorage.forEach { free($0) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM))
        }
        defer { argumentStorage.forEach { free($0) } }
        var argumentVector = argumentStorage + [nil]
        var processIdentifier: pid_t = 0
        let result = executableURL.path.withCString { executablePath in
            argumentVector.withUnsafeMutableBufferPointer { buffer in
                posix_spawn(
                    &processIdentifier,
                    executablePath,
                    &fileActions,
                    &attributes,
                    buffer.baseAddress!,
                    environ
                )
            }
        }
        try checkSpawn(result)
        return processIdentifier
    }

    private static func checkSpawn(_ result: Int32) throws {
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(result))
        }
    }
}
