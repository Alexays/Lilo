import Foundation

/// Serves the WebKit feature-flag list to the chrome UI and persists per-flag overrides: the
/// backend for the `about:config` page. Toggling re-applies flags to newly created web views.
@MainActor
final class FeatureFlagsBridgeHandler: BridgeHandler {

    let handledActions: Set<String> = ["getFeatureFlags", "setFeatureFlag", "resetFeatureFlags"]

    private weak var settingsStore: SettingsStore?
    private weak var bridgeRouter: BridgeRouter?
    /// Notifies the engine that overrides changed so it re-applies them to new web views.
    var onOverridesChanged: (([String: Bool]) -> Void)?

    private static let featuresByKey: [String: WKFeatureFlags.Feature] =
        Dictionary(WKFeatureFlags.all.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

    init(settingsStore: SettingsStore, bridgeRouter: BridgeRouter) {
        self.settingsStore = settingsStore
        self.bridgeRouter = bridgeRouter
    }

    func handle(message: BridgeMessage) async -> Any? {
        guard let store = settingsStore else { return nil }
        switch message.action {

        case "getFeatureFlags":
            publish(using: store)

        case "setFeatureFlag":
            if let key = message.string("key"), let feature = Self.featuresByKey[key] {
                let enabled = message.bool("enabled", default: feature.defaultValue)
                var overrides = store.featureFlagOverrides
                // Persist only values that differ from the default so the set stays minimal.
                if enabled == feature.defaultValue { overrides[key] = nil } else { overrides[key] = enabled }
                store.featureFlagOverrides = overrides
                onOverridesChanged?(overrides)
                publish(using: store)
            }

        case "resetFeatureFlags":
            store.featureFlagOverrides = [:]
            onOverridesChanged?([:])
            publish(using: store)

        default:
            break
        }
        return nil
    }

    private func publish(using store: SettingsStore) {
        let overrides = store.featureFlagOverrides
        let flags: [[String: Any]] = WKFeatureFlags.all.map { feature in
            [
                "key": feature.key,
                "name": feature.name,
                "details": feature.details,
                "kind": feature.kind.rawValue,
                "enabled": overrides[feature.key] ?? feature.defaultValue,
                "modified": overrides[feature.key] != nil
            ]
        }
        bridgeRouter?.send(event: "featureFlagsLoaded", data: ["flags": flags])
    }
}
