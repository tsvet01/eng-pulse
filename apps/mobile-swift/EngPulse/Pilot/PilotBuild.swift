import Foundation

enum PilotBuild {
    static var isEnabled: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "PilotAuthEnabled") as? String) == "YES"
    }

    // An unknown/new app identity must never register with the legacy sender.
    static var allowsLegacyServices: Bool {
        allowsLegacyServices(bundleID: Bundle.main.bundleIdentifier, pilotEnabled: isEnabled)
    }

    static func allowsLegacyServices(bundleID: String?, pilotEnabled: Bool) -> Bool {
        !pilotEnabled && bundleID == "org.tsvetkov.EngPulseSwift"
    }
}
