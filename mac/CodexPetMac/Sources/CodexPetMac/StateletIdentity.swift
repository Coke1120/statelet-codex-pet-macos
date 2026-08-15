/// Canonical product identifiers shared across the macOS app.
///
/// Legacy values are intentionally isolated in `Legacy` so upgrade code can
/// recognize an installation without letting the old identity leak back into
/// fresh-install behavior.
enum StateletIdentity {
    static let appBundleName = "Statelet.app"
    static let executableName = "Statelet"
    static let bundleIdentifier = "com.coke1120.Statelet"
    static let applicationSupportRelativePath = "Library/Application Support/Statelet"
    static let playerLaunchAgentLabel = "com.coke1120.statelet.mac-player"
    static let aggregatorLaunchAgentLabel = "com.coke1120.statelet.state-aggregator"
    static let appManagedPlistKey = "StateletManaged"
    static let updateSigningTeamIdentifierKey = "StateletUpdateSigningTeamIdentifier"
    static let launchAgentManagedPlistKey = "StateletManaged"
    static let managedMarker = "statelet-v2"

    enum Legacy {
        static let executableName = "CodexPetMac"
        static let bundleIdentifier = "com.coke1120.CodexPetMac"
        static let applicationSupportRelativePath = "Library/Application Support/CodexPet"
        static let playerLaunchAgentLabel = "com.coke1120.codex-pet.mac-player"
        static let aggregatorLaunchAgentLabel = "com.coke1120.codex-pet.state-aggregator"
        static let appManagedPlistKey = "CodexPetManaged"
        static let launchAgentManagedPlistKey = "CodexPetMacManaged"
        static let managedMarker = "mac-widget-v1"
    }
}
