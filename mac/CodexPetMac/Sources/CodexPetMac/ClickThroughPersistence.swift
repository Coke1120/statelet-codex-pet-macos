import Foundation

enum ClickThroughPersistenceTransaction {
    static func apply(
        current: Bool,
        updateRuntime: (Bool) -> Void,
        persist: (Bool) throws -> Void
    ) throws -> Bool {
        let desired = !current
        updateRuntime(desired)
        do {
            try persist(desired)
            return desired
        } catch {
            updateRuntime(current)
            throw error
        }
    }
}
