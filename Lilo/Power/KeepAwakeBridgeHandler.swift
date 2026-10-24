import AppKit
import ServiceManagement

/// The keep-awake state for the chrome, its snooze, and what the settings page needs.
@MainActor
final class KeepAwakeBridgeHandler: BridgeHandler {
    let handledActions: Set<String> = ["getKeepAwakeState", "snoozeKeepAwake", "openLoginItemsSettings", "getRunningApps", "getAppNames"]

    private let powerKeeper: PowerKeeper
    private weak var bridgeRouter: BridgeRouter?
    /// Sends this window its terminals even when unchanged since the last send.
    private let resendTerminals: () -> Void

    init(powerKeeper: PowerKeeper, bridgeRouter: BridgeRouter, resendTerminals: @escaping () -> Void) {
        self.powerKeeper = powerKeeper
        self.bridgeRouter = bridgeRouter
        self.resendTerminals = resendTerminals
    }

    func handle(message: BridgeMessage) async -> Any? {
        switch message.action {
        case "getKeepAwakeState":
            // The window asking is loading: it needs its terminals beside the state.
            resendTerminals()
            powerKeeper.refreshHelperStatus()
            powerKeeper.republish()
        case "snoozeKeepAwake":
            powerKeeper.snooze()
        case "openLoginItemsSettings":
            SMAppService.openSystemSettingsLoginItems()
        case "getRunningApps":
            let apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() && $0.bundleIdentifier?.hasPrefix("com.apple.") == false }
                .compactMap { app in app.bundleIdentifier.map { ["bundleId": $0, "name": app.localizedName ?? $0] } }
            bridgeRouter?.send(event: "runningApps", data: ["apps": apps])
        case "getAppNames":
            // The apps the settings page lists by bundle id, named after their bundle on disk. Every id
            // gets an answer, its own for an app not installed, so the page never asks twice.
            let names = (message.payload["ids"] as? [String] ?? []).reduce(into: [String: String]()) { names, bundleId in
                names[bundleId] = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)?
                    .deletingPathExtension().lastPathComponent ?? bundleId
            }
            bridgeRouter?.send(event: "appNames", data: ["names": names])
        default:
            break
        }
        return nil
    }
}
