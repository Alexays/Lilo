import Foundation
import WebKit

/// Handles the chrome.action badge color methods. WebKit does not expose badgeBackgroundColor to
/// Swift, so these go through the gap bridge. A tab-specific color is kept for that tab's getters, and
/// the toolbar shows it while that tab is active. It also answers `action.getUserSettings` from the
/// address bar's pins, which `action.onUserSettingsChanged` reports changes of.
@MainActor
final class ActionColorBridgeHandler: GapHandler {
    let gapActions: Set<String> = [
        "action.setBadgeBackgroundColor",
        "action.getBadgeBackgroundColor",
        "action.setBadgeTextColor",
        "action.getBadgeTextColor",
        "action.getUserSettings"
    ]

    /// Tab-specific colors by "profileId/extensionId", then WebKit tab id.
    private var tabColors: [String: [Int: ProfileExtensionRegistry.ActionColors]] = [:]
    nonisolated(unsafe) private var unloadObserver: Any?

    init() {
        unloadObserver = NotificationCenter.default.addObserver(forName: .extensionDidUnload, object: nil, queue: .main) { [weak self] note in
            guard let profileId = note.userInfo?["profileId"] as? UUID, let extensionId = note.userInfo?["extensionId"] as? String else { return }
            MainActor.assumeIsolated { _ = self?.tabColors.removeValue(forKey: "\(profileId)/\(extensionId)") }
        }
    }

    deinit {
        unloadObserver.map { NotificationCenter.default.removeObserver($0) }
    }

    func handle(_ call: GapCall) async -> Any? {
        switch call.action {
        case "action.setBadgeBackgroundColor":
            return handleSet(call, keyPath: \.badgeColor)
        case "action.getBadgeBackgroundColor":
            return handleGet(call, keyPath: \.badgeColor)
        case "action.setBadgeTextColor":
            return handleSet(call, keyPath: \.badgeTextColor)
        case "action.getBadgeTextColor":
            return handleGet(call, keyPath: \.badgeTextColor)
        case "action.getUserSettings":
            let pinned = call.registry.settingsStore?.get("pinnedExtensions") ?? ""
            return ["isOnToolbar": pinned.split(separator: ",").contains { $0 == call.extensionId }]
        default:
            return nil
        }
    }

    private func handleSet(_ call: GapCall, keyPath: WritableKeyPath<ProfileExtensionRegistry.ActionColors, String>) -> Any? {
        let extensionId = call.extensionId, registry = call.registry
        let color = call.string("color") ?? ""
        guard let tabId = call.int("tabId") else {
            registry.updateActionColor(for: extensionId) { $0[keyPath: keyPath] = color }
            return nil
        }
        tabColors["\(registry.profileId)/\(extensionId)", default: [:]][tabId, default: .init()][keyPath: keyPath] = color
        // The toolbar knows Lilo tabs, not WebKit's ids: the caller sends the tab's position too.
        let positions = call.payload["tabs"] as? [[String: Any]] ?? []
        if let tab = registry.tabIds(atPositions: positions, extensionId: extensionId).first ?? nil {
            registry.updateActionColor(for: extensionId, tab: tab) { $0[keyPath: keyPath] = color }
        }
        return nil
    }

    private func handleGet(_ call: GapCall, keyPath: KeyPath<ProfileExtensionRegistry.ActionColors, String>) -> String? {
        let extensionId = call.extensionId, registry = call.registry
        if let tabId = call.int("tabId"),
           let color = tabColors["\(registry.profileId)/\(extensionId)"]?[tabId]?[keyPath: keyPath], !color.isEmpty {
            return color
        }
        return registry.actionColors(of: extensionId)?[keyPath: keyPath] ?? ""
    }
}
