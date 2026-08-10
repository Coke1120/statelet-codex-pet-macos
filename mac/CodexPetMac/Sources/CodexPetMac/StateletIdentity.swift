/// Stable product and compatibility identifiers shared across the macOS app.
///
/// Statelet is the public product name. The legacy executable, bundle ID,
/// Application Support path, LaunchAgent labels, managed keys, and marker
/// remain unchanged so existing installations can be upgraded safely.
enum StateletIdentity {
    static let appBundleName = "Statelet.app"
    static let executableName = "CodexPetMac"
    static let bundleIdentifier = "com.coke1120.CodexPetMac"
    static let applicationSupportRelativePath = "Library/Application Support/CodexPet"
    static let playerLaunchAgentLabel = "com.coke1120.codex-pet.mac-player"
    static let aggregatorLaunchAgentLabel = "com.coke1120.codex-pet.state-aggregator"
    static let appManagedPlistKey = "CodexPetManaged"
    static let launchAgentManagedPlistKey = "CodexPetMacManaged"
    static let managedMarker = "mac-widget-v1"
}
