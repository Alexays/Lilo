import Foundation

@MainActor
final class WhatsNewState {
    private let defaults: UserDefaults
    private let key = "whatsNewHighestPresentedVersion"
    private var checkedAutomatic = false
    private var reservedVersion: String?

    init(defaults: UserDefaults = .lilo) { self.defaults = defaults }

    func reserveAutomatic(version: String, freshInstall: Bool) -> Bool {
        guard !checkedAutomatic else { return false }
        checkedAutomatic = true
        guard Self.isVersion(version) else { return false }
        if freshInstall {
            remember(version)
            return false
        }
        if let previous = defaults.string(forKey: key), Self.isVersion(previous),
           version.compare(previous, options: .numeric) != .orderedDescending { return false }
        reservedVersion = version
        return true
    }

    func acknowledge(version: String) {
        guard Self.isVersion(version), reservedVersion == nil || reservedVersion == version else { return }
        remember(version)
    }

    private func remember(_ version: String) {
        if let previous = defaults.string(forKey: key), Self.isVersion(previous),
           version.compare(previous, options: .numeric) != .orderedDescending { return }
        defaults.set(version, forKey: key)
    }

    private static func isVersion(_ version: String) -> Bool {
        version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil
    }
}
