import AppKit
import WebKit

/// `chrome.sidePanel`, which WebKit lacks: panel options, toolbar behavior, and open/close requests for `SidePanelController`.
/// Tabs and windows arrive as `{windowPosition, index}` in WebKit's lists; the integer ids only shape error messages.
@MainActor
final class SidePanelBridgeHandler: GapHandler {
    let gapActions: Set<String> = [
        "sidePanel.setOptions",
        "sidePanel.getOptions",
        "sidePanel.open",
        "sidePanel.close",
        "sidePanel.setPanelBehavior",
        "sidePanel.getPanelBehavior"
    ]

    private struct Options {
        var path: String?
        var enabled: Bool?
        var isAvailable: Bool { enabled == true && path != nil }
    }

    /// Options by "profileId.extensionId", then tab (nil for the extension-wide options), with the
    /// WebKit id of each tab for `getOptions`. Chrome keeps them for the session and drops them when
    /// the extension unloads; only the panel behavior persists, in UserDefaults.
    private var options: [String: [UUID?: (options: Options, webKitTabId: Int?)]] = [:]
    nonisolated(unsafe) private var unloadObserver: Any?

    init() {
        unloadObserver = NotificationCenter.default.addObserver(forName: .extensionDidUnload, object: nil, queue: .main) { [weak self] note in
            guard let profileId = note.userInfo?["profileId"] as? UUID, let extensionId = note.userInfo?["extensionId"] as? String else { return }
            let uninstalled = note.userInfo?["uninstalled"] as? Bool == true
            nonisolated(unsafe) let registry = note.object as? ProfileExtensionRegistry
            MainActor.assumeIsolated {
                self?.options.removeValue(forKey: "\(profileId).\(extensionId)")
                registry?.delegate.windows?.windows.forEach { $0.sidePanel.extensionDidUnload(extensionId) }
            }
            if uninstalled { UserDefaults.lilo.removeObject(forKey: "sidePanel.\(profileId).\(extensionId)") }
        }
    }

    deinit {
        unloadObserver.map { NotificationCenter.default.removeObserver($0) }
    }

    func handle(_ call: GapCall) async -> Any? {
        let extensionId = call.extensionId, registry = call.registry
        let behaviorKey = "sidePanel.\(registry.profileId).\(extensionId)"

        switch call.action {
        case "sidePanel.setOptions":
            var tabId: UUID?
            if call.int("tabId") != nil {
                // An unknown tab never shows a panel: Chrome stores its options, Lilo has no tab to key them by.
                guard let tab = tab(at: call.payload["tab"], call: call) else { return nil }
                tabId = tab.tabId
            }
            setOptions(extensionId: extensionId, tabId: tabId, webKitTabId: call.int("tabId"), path: call.string("path"),
                       enabled: call.payload["enabled"] == nil ? nil : call.bool("enabled"), registry: registry)
            return nil

        case "sidePanel.getOptions":
            let tabId = call.int("tabId") == nil ? nil : tab(at: call.payload["tab"], call: call)?.tabId
            let stored = tabId.flatMap { options[optionsKey(extensionId, registry)]?[$0] }
            var result: [String: Any] = [:]
            let resolved = stored?.options ?? globalOptions(extensionId, registry: registry)
            result["path"] = resolved.path
            result["enabled"] = resolved.enabled
            result["tabId"] = stored?.webKitTabId
            return result

        case "sidePanel.open":
            guard call.bool("userGesture") || registry.hasRecentUserGesture(extensionId: extensionId) else {
                return BridgeError("`sidePanel.open()` may only be called in response to a user gesture.")
            }
            return target(of: call) { window, tabId in
                if let tabId {
                    guard isAvailable(extensionId, forTab: tabId, registry: registry) else {
                        return BridgeError("No active side panel for tabId: \(call.int("tabId") ?? -1)")
                    }
                    window.sidePanel.open(extensionId, tabSpecific: panelURL(extensionId, tabId: tabId, registry: registry) != nil, in: tabId)
                    return nil
                }
                guard panelURL(extensionId, tabId: nil, registry: registry) != nil else {
                    return BridgeError("No active side panel for windowId: \(call.int("windowId") ?? -1)")
                }
                window.sidePanel.open(extensionId, tabSpecific: false, in: nil)
                return nil
            }

        case "sidePanel.close":
            return target(of: call) { window, tabId in
                if let tabId {
                    guard panelURL(extensionId, tabId: tabId, registry: registry) != nil else {
                        return BridgeError("No active tab-specific side panel for tabId: \(call.int("tabId") ?? -1)")
                    }
                    window.sidePanel.close(extensionId, tabId: tabId)
                    return nil
                }
                guard panelURL(extensionId, tabId: nil, registry: registry) != nil else {
                    return BridgeError("No active side panel for windowId: \(call.int("windowId") ?? -1)")
                }
                window.sidePanel.close(extensionId, tabId: nil)
                return nil
            }

        case "sidePanel.setPanelBehavior":
            guard call.payload["openPanelOnActionClick"] != nil else { return nil }
            var stored = UserDefaults.lilo.dictionary(forKey: behaviorKey) ?? [:]
            stored["openPanelOnActionClick"] = call.bool("openPanelOnActionClick")
            UserDefaults.lilo.set(stored, forKey: behaviorKey)
            return nil

        case "sidePanel.getPanelBehavior":
            return ["openPanelOnActionClick": opensOnActionClick(extensionId, registry: registry)]

        default:
            return nil
        }
    }

    // MARK: - Options

    /// The panel that `tabId`'s own options enable, or with a nil `tabId` the extension-wide one:
    /// an extension URL, or an http(s) one as Chrome allows.
    func panelURL(_ extensionId: String, tabId: UUID?, registry: ProfileExtensionRegistry) -> URL? {
        let stored = tabId == nil ? globalOptions(extensionId, registry: registry) : options[optionsKey(extensionId, registry)]?[tabId]?.options
        guard let stored, stored.isAvailable, let path = stored.path, let context = registry.context(for: extensionId) else { return nil }
        if let url = URL(string: path), url.scheme == "http" || url.scheme == "https" { return url }
        return URL(string: path, relativeTo: context.baseURL)?.absoluteURL
    }

    /// Whether the extension has a panel for `tabId`: the tab's own options when it has any, else the
    /// extension-wide ones.
    func isAvailable(_ extensionId: String, forTab tabId: UUID, registry: ProfileExtensionRegistry) -> Bool {
        options[optionsKey(extensionId, registry)]?[tabId].map { $0.options.isAvailable }
            ?? (panelURL(extensionId, tabId: nil, registry: registry) != nil)
    }

    /// Upserts as Chrome does: omitted fields keep their value, `enabled` starts true, and the first
    /// extension-wide options start from the manifest's.
    private func setOptions(extensionId: String, tabId: UUID?, webKitTabId: Int?, path: String?, enabled: Bool?, registry: ProfileExtensionRegistry) {
        let key = optionsKey(extensionId, registry)
        var entry = options[key]?[tabId]?.options
            ?? (tabId == nil ? manifestOptions(extensionId, registry: registry) : Options())
        if options[key]?[tabId] == nil, enabled == nil { entry.enabled = true }
        if let path { entry.path = path }
        if let enabled { entry.enabled = enabled }
        options[key, default: [:]][tabId] = (entry, webKitTabId)
        registry.delegate.windows?.windows.forEach { $0.sidePanel.optionsDidChange(of: extensionId) }
    }

    private func globalOptions(_ extensionId: String, registry: ProfileExtensionRegistry) -> Options {
        options[optionsKey(extensionId, registry)]?[nil]?.options ?? manifestOptions(extensionId, registry: registry)
    }

    private func manifestOptions(_ extensionId: String, registry: ProfileExtensionRegistry) -> Options {
        let sidePanel = registry.context(for: extensionId)?.webExtension.manifest["side_panel"] as? [String: Any]
        guard let path = sidePanel?["default_path"] as? String, !path.isEmpty else { return Options() }
        return Options(path: path, enabled: true)
    }

    private func optionsKey(_ extensionId: String, _ registry: ProfileExtensionRegistry) -> String {
        "\(registry.profileId).\(extensionId)"
    }

    private func opensOnActionClick(_ extensionId: String, registry: ProfileExtensionRegistry) -> Bool {
        UserDefaults.lilo.dictionary(forKey: "sidePanel.\(registry.profileId).\(extensionId)")?["openPanelOnActionClick"] as? Bool ?? false
    }

    // MARK: - Targets

    /// Resolves the call's `tabId` and `windowId` to a browser window and tab, with Chrome's errors,
    /// and runs `body` on them; a nil tab means the window's extension-wide panel.
    private func target(of call: GapCall, _ body: (MainWindowController, UUID?) -> Any?) -> Any? {
        let tabId = call.int("tabId"), windowId = call.int("windowId")
        guard tabId != nil || windowId != nil else {
            return BridgeError("At least one of `tabId` and `windowId` must be provided")
        }
        var window: MainWindowController?
        if let windowId {
            guard let adapter = call.int("windowPosition").flatMap({ call.registry.extensionWindow(at: $0, extensionId: call.extensionId) }) else {
                return BridgeError("No window with id: \(windowId).")
            }
            window = adapter.nsWindow?.windowController as? MainWindowController
            guard window != nil else { return BridgeError("No browser window for windowId: \(windowId)") }
        }
        guard let tabId else { return window.map { body($0, nil) } }
        guard let tab = self.tab(at: call.payload["tab"], call: call) else { return BridgeError("No tab with id: \(tabId).") }
        guard let tabWindow = (tab.extensionWindow as? WindowExtensionAdapter)?.nsWindow?.windowController as? MainWindowController else {
            return BridgeError("No browser window for tabId: \(tabId)")
        }
        if let window, window !== tabWindow { return BridgeError("The specified tab does not belong to the specified window.") }
        return body(tabWindow, tab.tabId)
    }

    private func tab(at position: Any?, call: GapCall) -> TabExtensionAdapter? {
        guard let position = position as? [String: Any] else { return nil }
        return call.registry.tabAdapters(atPositions: [position], extensionId: call.extensionId).first ?? nil
    }

    // MARK: - Toolbar action

    /// Installed at registry build so a toolbar click toggles the panel (with `openPanelOnActionClick`) before any popup or
    /// `onClicked`, as in Chrome. Captured weakly: the per-profile registry and this app-lifetime handler must not retain each other.
    func installActionClickOpener(on registry: ProfileExtensionRegistry) {
        registry.toggleSidePanelOnActionClick = { [weak self, weak registry] extensionId, window in
            guard let self, let registry, self.opensOnActionClick(extensionId, registry: registry),
                  let tabId = window.tabManager.activeOpenTabId,
                  self.isAvailable(extensionId, forTab: tabId, registry: registry) else { return false }
            window.sidePanel.toggle(extensionId, tabSpecific: self.panelURL(extensionId, tabId: tabId, registry: registry) != nil)
            return true
        }
    }
}
