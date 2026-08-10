import AppKit

guard let singletonLock = SingletonLock() else {
    FileHandle.standardError.write(Data("Statelet is already running or its lock cannot be created.\n".utf8))
    exit(EXIT_FAILURE)
}
withExtendedLifetime(singletonLock) {
    let application = NSApplication.shared
    let delegate = PetAppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
