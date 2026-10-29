import AppKit
import Foundation
import Sparkle
import WebKit

/// Handles settings-related bridge messages.
@MainActor
final class SettingsBridgeHandler: BridgeHandler {

    let handledActions: Set<String> = [
        "getSettings",
        "setSetting",
        "getSitePermissions",
        "revokeSitePermission",
        "setSitePermission",
        "toggleBlockerAllowlist",
        "getContentBlockerStatus",
        "updateFilterLists",
        "clearBrowsingData",
        "getBrowsingDataSizes",
        "getWebsiteData",
        "removeWebsiteData",
        "getZoomLevels",
        "resetZoomLevel",
        "getDeviceSetup",
        "forgetDeviceSetup",
        "getExtensionDiagnostics",
        "getStartupMetrics",
        "clearExtensionDiagnostics",
        "copyExtensionDiagnostics",
        "copyDiagnosticsReport",
        "togglePerfRecording",
        "forceLifecycleTrim",
        "chooseDownloadsFolder",
        "getDefaultBrowserStatus",
        "setDefaultBrowser",
        "dismissDefaultBrowserInvite",
        "getAppIcons",
        "getTerminalOptions",
        "importTerminalTheme",
        "connectAgentClient",
        "getAgentClients",
        "revokeAgentClient",
        "getUpdaterStatus",
        "checkForUpdates",
        "installUpdate",
        "dismissUpdate",
        "unlockDeveloperTools",
        "setAutomaticUpdates",
        "getShortcuts",
        "recordShortcut",
        "setShortcut",
        "resetShortcut",
        "applyShortcutPreset",
        "setControlTabOrder",
        "getAgentActivity",
        "agentControlResponse"
    ]

    private weak var settingsStore: SettingsStore?
    private let sitePermissionStore: SitePermissionStore
    private let zoomStoreProvider: @MainActor () -> ZoomStore?
    private let historyStoreProvider: @MainActor () -> HistoryStore?
    private let extensionRegistryProvider: @MainActor () -> ProfileExtensionRegistry?
    private let dataStoreProvider: @MainActor () -> WKEngineDataStore?
    private let lifecycleDiagnosticsProvider: @MainActor () -> TabLifecycleDiagnostics?
    private let extensionDiagnosticsProvider: @MainActor () -> [[String: Any]]
    private let forceLifecycleTrimHandler: @MainActor () -> Void
    private weak var bridgeRouter: BridgeRouter?
    var onContentBlockerToggled: ((Bool) -> Void)?
    var onBlockerAllowlistChanged: (() -> Void)?
    /// The content blocker's lists and counts, for the settings page.
    var contentBlockerStatus: (() -> [String: Any])?
    /// Fetches and converts the filter lists now.
    var onUpdateFilterLists: (() async -> Void)?
    var onSendGPCChanged: ((Bool) -> Void)?
    var onTrackingPreventionChanged: ((Bool) -> Void)?
    /// Agent control: the opt-in switch, and the actions of its settings section.
    var agentControl: (() -> AgentControl?)?
    var onHTTPSOnlyChanged: ((Bool) -> Void)?
    var onMinimumFontSizeChanged: ((CGFloat) -> Void)?
    var onAutoplayPolicyChanged: ((String) -> Void)?
    var onLifecyclePresetChanged: ((String) -> Void)?
    var onTabLayoutChanged: (() -> Void)?
    /// Any `terminal*` setting changed: theme, font, size or imported themes.
    var onTerminalSettingsChanged: (() -> Void)?
    /// Themes (with preview colors), fonts and what Ghostty's config provides, for the settings page.
    var terminalOptionsProvider: (() -> [String: Any])?
    /// Picks a theme file and imports it; true when a theme was added.
    var terminalThemeImporter: (() async -> Bool)?
    /// A host's stored zoom was reset; open pages of that host fall back to the default zoom.
    var onZoomLevelReset: ((String) -> Void)?
    var onAutoDeviceSwitchingChanged: (() -> Void)?
    /// What the device-setup row shows; nil when no window owns a device setup controller.
    var deviceSetupState: (() -> [String: Any])?
    var onForgetDeviceSetup: (() -> Void)?
    var onTogglePerfRecording: (() -> Void)?
    /// Settings records a shortcut for this action id, or stops recording (nil).
    var onRecordShortcut: ((String?) -> Void)?

    init(
        settingsStore: SettingsStore,
        sitePermissionStore: SitePermissionStore,
        zoomStoreProvider: @escaping @MainActor () -> ZoomStore?,
        historyStoreProvider: @escaping @MainActor () -> HistoryStore?,
        extensionRegistryProvider: @escaping @MainActor () -> ProfileExtensionRegistry?,
        dataStoreProvider: @escaping @MainActor () -> WKEngineDataStore?,
        lifecycleDiagnosticsProvider: @escaping @MainActor () -> TabLifecycleDiagnostics?,
        extensionDiagnosticsProvider: @escaping @MainActor () -> [[String: Any]],
        forceLifecycleTrimHandler: @escaping @MainActor () -> Void,
        bridgeRouter: BridgeRouter
    ) {
        self.settingsStore = settingsStore; self.sitePermissionStore = sitePermissionStore
        self.zoomStoreProvider = zoomStoreProvider
        self.historyStoreProvider = historyStoreProvider
        self.extensionRegistryProvider = extensionRegistryProvider
        self.dataStoreProvider = dataStoreProvider; self.lifecycleDiagnosticsProvider = lifecycleDiagnosticsProvider
        self.extensionDiagnosticsProvider = extensionDiagnosticsProvider
        self.forceLifecycleTrimHandler = forceLifecycleTrimHandler
        self.bridgeRouter = bridgeRouter
    }

    /// Clears the chosen kinds of the window's profile in one pass, so the sizes and site lists are measured once afterwards.
    private func clearBrowsingData(kinds: Set<String>, range: String) async {
        let cutoff = Self.historyCutoff(for: range)
        let since = cutoff ?? .distantPast
        var failure: String?
        if kinds.contains("history") {
            if let historyStore = historyStoreProvider() {
                do {
                    try await Task.detached {
                        if let cutoff { try historyStore.deleteEntries(since: cutoff) } else { try historyStore.clearAll() }
                    }.value
                } catch {
                    failure = String(format: "Could not clear browsing history: %@".localized, error.localizedDescription)
                }
            } else {
                failure = "No history store available".localized
            }
        }
        if !kinds.isDisjoint(with: ["cookies", "cache", "siteData"]) {
            if let dataStore = dataStoreProvider() {
                if kinds.contains("siteData") {
                    await dataStore.removeAllData(modifiedSince: since)
                    // Permissions carry no timestamp, so only an all-time clear drops them.
                    if cutoff == nil {
                        sitePermissionStore.clearAll()
                        publishSitePermissions()
                    }
                } else {
                    if kinds.contains("cookies") { await dataStore.removeCookies(modifiedSince: since) }
                    if kinds.contains("cache") { await dataStore.removeCache(modifiedSince: since) }
                }
                await publishWebsiteData()
            } else {
                failure = "No active profile data store".localized
            }
        }
        await publishBrowsingDataSizes()
        bridgeRouter?.sendActionCompleted(
            "settingsActionCompleted",
            action: "clearBrowsingData",
            message: failure ?? "Browsing data cleared".localized,
            level: failure == nil ? "info" : "error"
        )
    }

    /// Bytes per kind the clear-data page offers; a kind WebKit cannot measure is left out.
    private func publishBrowsingDataSizes() async {
        var sizes: [String: Any] = [:]
        if let historyStore = historyStoreProvider(), let usage = try? await Task.detached(operation: { try historyStore.usage() }).value {
            sizes["history"] = usage.bytes
            sizes["historyEntries"] = usage.entries
        }
        if let dataSizes = await dataStoreProvider()?.dataSizes() {
            var siteSizes: [String: Int64] = ["cache": 0, "cookies": 0, "storage": 0]
            for (type, bytes) in dataSizes {
                siteSizes[type == WKWebsiteDataTypeCookies ? "cookies" : type.contains("Cache") ? "cache" : "storage", default: 0] += bytes
            }
            sizes.merge(siteSizes) { $1 }
        }
        bridgeRouter?.send(event: "browsingDataSizesLoaded", data: sizes)
    }

    func handle(message: BridgeMessage) async -> Any? {
        guard let store = settingsStore else { return nil }
        switch message.action {

        case "getSettings":
            publishSettings(using: store)

        case "setSetting":
            if let key = message.string("key"), let value = message.string("value") {
                if key == "pinnedExtensions" { extensionRegistryProvider()?.pinnedExtensionsChanged(from: store.get(key), to: value) }
                store.set(key, value: value)
                if key == "contentBlockerEnabled" { onContentBlockerToggled?(value == "true") }
                if key == "contentBlockerAllowedDomains" { onBlockerAllowlistChanged?() }
                if key == "sendGPC" { onSendGPCChanged?(value == "true") }
                if key == "preventCrossSiteTracking" { onTrackingPreventionChanged?(value == "true") }
                if key == "httpsOnly" { onHTTPSOnlyChanged?(value == "true") }
                if key == "minimumFontSize" { onMinimumFontSizeChanged?(CGFloat(Double(value) ?? 0)) }
                if key == "autoplayPolicy" { onAutoplayPolicyChanged?(value) }
                if key == "lifecyclePreset" { onLifecyclePresetChanged?(value) }
                if key == "tabPosition" || key == "addressPlacement" { onTabLayoutChanged?() }
                if key == DeviceSetupController.enabledKey { onAutoDeviceSwitchingChanged?() }
                // Mirror the UI language choice so native menus/dialogs follow it on next launch.
                if key == "locale" { Localization.persistOverride(value) }
                // apply() also caches the appearance for next-launch first paint.
                if key == "theme" { ThemePreference(stored: value).apply() }
                if key == "appIcon" { AppIconPreference.apply(value) }
                if key == AppDelegate.showDevelopMenuKey {
                    UserDefaults.lilo.set(value == "true", forKey: key)
                    NSApp.mainMenu?.item(withTag: AppDelegate.developMenuTag)?.isHidden = value != "true"
                }
                if key == "littleWindowHotKey" { (NSApp.delegate as? AppDelegate)?.applyLittleWindowHotKey() }
                if key.hasPrefix("terminal") { onTerminalSettingsChanged?() }
                if key == "agentControlEnabled" { agentControl?()?.setEnabled(value == "true") }
                publishSettings(using: store)
                if Self.filterListKeys.contains(key) { await updateFilterLists() }
            }

        case "getAppIcons":
            bridgeRouter?.send(event: "appIconsLoaded", data: ["icons": AppIconPreference.previews])

        case "getTerminalOptions":
            if let options = terminalOptionsProvider?() { bridgeRouter?.send(event: "terminalOptions", data: options) }

        case "connectAgentClient":
            var text = "Copied the MCP configuration".localized
            var level = "info"
            if let client = message.string("client").flatMap(AgentClientConfig.Client.init(rawValue:)) {
                do {
                    text = try await AgentClientConfig.connect(client, home: FileManager.default.homeDirectoryForCurrentUser)
                } catch {
                    text = error.localizedDescription
                    level = "error"
                }
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(AgentClientConfig.genericConfigJSON, forType: .string)
            }
            bridgeRouter?.sendActionCompleted("settingsActionCompleted", action: "connectAgentClient", message: text, level: level)
            await publishAgentClients()

        case "getAgentClients":
            await publishAgentClients()

        case "revokeAgentClient":
            if let name = message.string("name") {
                agentControl?()?.revoke(name)
                await publishAgentClients()
            }

        case "getUpdaterStatus":
            publishUpdaterStatus()

        case "checkForUpdates":
            updaterController?.checkForUpdates(nil)
            publishUpdaterStatus()

        case "installUpdate":
            (NSApp.delegate as? AppDelegate)?.readyUpdate?.install()

        case "dismissUpdate":
            // Sparkle still installs it on quit.
            guard let delegate = NSApp.delegate as? AppDelegate else { break }
            delegate.readyUpdate = nil
            delegate.browserContext.windows.windows.forEach { $0.sendUpdateReady() }

        case "unlockDeveloperTools":
            UserDefaults.lilo.set(true, forKey: AppDelegate.developerToolsKey)
            for item in NSApp.mainMenu?.item(withTag: AppDelegate.developMenuTag)?.submenu?.items ?? [] where item.tag == AppDelegate.developerToolsTag {
                item.isHidden = false
            }

        case "setAutomaticUpdates":
            if let updater = updaterController?.updater {
                // Checking without downloading would only nag: the switch moves both.
                updater.automaticallyChecksForUpdates = message.bool("enabled")
                updater.automaticallyDownloadsUpdates = message.bool("enabled")
            }
            publishUpdaterStatus()

        case "getShortcuts":
            publishShortcuts()

        case "recordShortcut":
            onRecordShortcut?(message.string("id"))

        case "setShortcut":
            if let id = message.string("id"), let combo = message.string("combo") {
                KeyboardShortcuts.set(id, to: [combo], store: store)
            }
            publishShortcuts()

        case "resetShortcut":
            if let id = message.string("id") { KeyboardShortcuts.set(id, to: nil, store: store) }
            publishShortcuts()

        case "applyShortcutPreset":
            if let preset = message.string("preset") { KeyboardShortcuts.applyPreset(preset, store: store) }
            publishShortcuts()

        case "setControlTabOrder":
            KeyboardShortcuts.setControlTabOrder(recent: message.string("order") == "recent", store: store)
            publishShortcuts()

        case "getAgentActivity":
            agentControl?()?.publishActivity()
            agentControl?()?.resendPendingConsents(to: bridgeRouter)

        case "agentControlResponse":
            if let requestId = message.string("requestId") {
                let site = message.string("alwaysAllowSite")
                agentControl?()?.answerConsent(requestId, granted: message.bool("granted"), alwaysAllowSite: site)
                if site != nil { publishSettings(using: store) }
            }

        case "importTerminalTheme":
            if await terminalThemeImporter?() == true {
                publishSettings(using: store)
                if let options = terminalOptionsProvider?() { bridgeRouter?.send(event: "terminalOptions", data: options) }
            }

        case "toggleBlockerAllowlist":
            if let host = message.string("host") {
                var list = store.contentBlockerAllowlist
                if let idx = list.firstIndex(of: host) { list.remove(at: idx) } else { list.append(host) }
                store.contentBlockerAllowlist = list
                onBlockerAllowlistChanged?()
                bridgeRouter?.send(event: "blockerAllowlistChanged", data: ["allowlist": list])
                publishSettings(using: store)
            }

        case "getContentBlockerStatus":
            publishContentBlockerStatus()

        case "updateFilterLists":
            await updateFilterLists()

        case "getSitePermissions":
            publishSitePermissions()

        case "revokeSitePermission":
            if let id = message.uuid("id") { sitePermissionStore.revoke(id: id); publishSitePermissions(); bridgeRouter?.sendActionCompleted("settingsActionCompleted", action: "revokeSitePermission", message: "Site permission revoked".localized) }

        case "setSitePermission":
            if let origin = message.string("origin"), let type = message.string("type") {
                sitePermissionStore.upsert(origin: origin, type: type, granted: message.bool("allow"))
                publishSitePermissions()
            }

        case "clearBrowsingData":
            await clearBrowsingData(kinds: Set(message.payload["kinds"] as? [String] ?? []), range: message.string("range", default: "all"))

        case "getBrowsingDataSizes":
            await publishBrowsingDataSizes()

        case "getWebsiteData":
            await publishWebsiteData()

        case "removeWebsiteData":
            if let name = message.string("name"), let backingStore = dataStoreProvider()?.backingStore {
                let types = WKEngineDataStore.siteDataTypes
                let records = await backingStore.dataRecords(ofTypes: types).filter { $0.displayName == name }
                await backingStore.removeData(ofTypes: types, for: records)
                await publishWebsiteData()
            }

        case "getZoomLevels":
            publishZoomLevels()

        case "getDeviceSetup":
            if let state = deviceSetupState?() { bridgeRouter?.send(event: "deviceSetupLoaded", data: state) }

        case "forgetDeviceSetup":
            onForgetDeviceSetup?()

        case "resetZoomLevel":
            if let host = message.string("host") {
                zoomStoreProvider()?.removeZoom(forHost: host)
                onZoomLevelReset?(host)
                publishZoomLevels()
            }

        case "getStartupMetrics":
            publishStartupMetrics()

        case "getExtensionDiagnostics":
            publishExtensionDiagnostics()

        case "clearExtensionDiagnostics":
            extensionRegistryProvider()?.clearBackgroundDiagnostics()
            publishExtensionDiagnostics()
            bridgeRouter?.sendActionCompleted("settingsActionCompleted", action: "clearExtensionDiagnostics", message: "Extension diagnostics cleared".localized)

        case "copyExtensionDiagnostics":
            let text: String = extensionDiagnosticsEntries()
                .map { entry in
                    let extensionId = entry["extensionId"] as? String ?? ""
                    let extensionName = entry["extensionName"] as? String ?? ""
                    let extensionLabel = extensionName.isEmpty || extensionName == extensionId
                        ? extensionId
                        : "\(extensionName) (\(extensionId))"
                    let level = entry["level"] as? String ?? ""
                    let message = entry["message"] as? String ?? ""
                    return "[\(level)] \(extensionLabel): \(message)"
                }
                .joined(separator: "\n")
            let didCopy = copyToPasteboard(text)
            bridgeRouter?.sendActionCompleted("settingsActionCompleted", action: "copyExtensionDiagnostics", message: (didCopy ? "Extension diagnostics copied" : "Unable to copy extension diagnostics").localized, level: didCopy ? "info" : "error")

        case "copyDiagnosticsReport":
            var report = StartupMetrics.exportText()
            if let diagnostics = lifecycleDiagnosticsProvider() {
                report += "\n\n" + lifecycleDiagnosticsReportText(diagnostics)
            }
            let didCopy = copyToPasteboard(report)
            bridgeRouter?.sendActionCompleted("settingsActionCompleted", action: "copyDiagnosticsReport", message: (didCopy ? "Diagnostics report copied" : "Unable to copy diagnostics report").localized, level: didCopy ? "info" : "error")

        case "togglePerfRecording":
            onTogglePerfRecording?()

        case "forceLifecycleTrim":
            forceLifecycleTrimHandler()
            publishStartupMetrics()
            bridgeRouter?.sendActionCompleted("settingsActionCompleted", action: "forceLifecycleTrim", message: "Memory trim completed".localized)

        case "chooseDownloadsFolder":
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.prompt = "Select".localized
            if panel.runModal() == .OK, let url = panel.url { store.downloadsFolder = url; publishSettings(using: store) }

        case "getDefaultBrowserStatus":
            publishDefaultBrowserStatus(using: store)

        case "setDefaultBrowser":
            DefaultBrowserService.requestDefault { [weak self] isDefault in
                guard let self, let store = self.settingsStore else { return }
                store.didPromptDefaultBrowser = true
                self.publishDefaultBrowserStatus(using: store)
                self.bridgeRouter?.sendActionCompleted(
                    "settingsActionCompleted",
                    action: "setDefaultBrowser",
                    message: (isDefault ? "Lilo is now your default browser" : "Lilo was not set as the default browser").localized,
                    level: isDefault ? "info" : "error")
            }

        case "dismissDefaultBrowserInvite":
            store.didPromptDefaultBrowser = true
            publishDefaultBrowserStatus(using: store)

        default:
            break
        }

        return nil
    }

    /// Settings choosing which filter lists the content blocker merges.
    private static let filterListKeys: Set<String> = [
        "blockerTrackers", "blockerCookieNotices", "blockerAnnoyances", "blockerBadware", "blockerRegional"
    ]

    /// Reports the update as running, then its outcome.
    private func updateFilterLists() async {
        guard let onUpdateFilterLists else { return }
        var updating = contentBlockerStatus?() ?? [:]
        updating["updating"] = true
        bridgeRouter?.send(event: "contentBlockerStatus", data: updating)
        await onUpdateFilterLists()
        publishContentBlockerStatus()
    }

    private func publishContentBlockerStatus() {
        if let status = contentBlockerStatus?() { bridgeRouter?.send(event: "contentBlockerStatus", data: status) }
    }

    private func publishSettings(using store: SettingsStore) {
        bridgeRouter?.send(event: "settingsLoaded", data: ["settings": store.allSettings()])
    }

    /// Nil in builds without a Sparkle key (local and debug builds), which never update.
    private var updaterController: SPUStandardUpdaterController? {
        (NSApp.delegate as? AppDelegate)?.updaterController
    }

    private func publishUpdaterStatus() {
        let updater = updaterController?.updater
        bridgeRouter?.send(event: "updaterStatus", data: [
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "available": updater != nil,
            "automatic": updater.map { $0.automaticallyChecksForUpdates && $0.automaticallyDownloadsUpdates } ?? false,
            "lastCheck": updater?.lastUpdateCheckDate?.timeIntervalSince1970 ?? NSNull()
        ])
    }

    /// The agent apps installed or naming Lilo in their configuration (read off the main thread), and the
    /// agents allowed in.
    private func publishAgentClients() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let found = await Task.detached {
            let connected = AgentClientConfig.connectedClients(home: home)
            return AgentClientConfig.Client.allCases.compactMap { client -> (AgentClientConfig.Client, Bool, URL?)? in
                let app = AgentClientConfig.iconApp(of: client, home: home)
                return app != nil || connected.contains(client) ? (client, connected.contains(client), app) : nil
            }
        }.value
        let clients = found.map { client, configured, app in
            ["id": client.rawValue, "configured": configured, "icon": app.flatMap(Self.appIconDataURL) ?? NSNull()] as [String: Any]
        }
        let control = agentControl?()
        let lastSeen = control?.lastSeen ?? [:]
        let allowed = (control?.allowedClients ?? [:]).keys.sorted().map {
            ["name": $0, "displayName": AgentControl.displayName($0), "lastSeen": lastSeen[$0] ?? NSNull(),
             "client": AgentClientConfig.Client(clientName: $0)?.rawValue ?? NSNull()] as [String: Any]
        }
        bridgeRouter?.send(event: "agentClientsLoaded", data: ["clients": clients, "allowed": allowed])
    }

    private static var appIconDataURLs: [URL: String] = [:]

    /// A 64 px PNG of the app's Finder icon, rendered once per app.
    private static func appIconDataURL(_ app: URL) -> String? {
        if let cached = appIconDataURLs[app] { return cached }
        let rect = NSRect(x: 0, y: 0, width: 64, height: 64)
        guard let png = NSWorkspace.shared.icon(forFile: app.path).bestRepresentation(for: rect, context: nil, hints: nil)
            .flatMap({ $0.cgImage(forProposedRect: nil, context: nil, hints: nil) })
            .flatMap({ NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }) else { return nil }
        let url = "data:image/png;base64," + png.base64EncodedString()
        appIconDataURLs[app] = url
        return url
    }

    private func publishShortcuts() {
        bridgeRouter?.send(event: "shortcutsLoaded", data: KeyboardShortcuts.bridgePayload)
    }

    private func publishDefaultBrowserStatus(using store: SettingsStore) {
        let isDefault = DefaultBrowserService.isDefault()
        bridgeRouter?.send(event: "defaultBrowserStatusLoaded", data: [
            "isDefault": isDefault,
            "shouldInvite": !isDefault && !store.didPromptDefaultBrowser
        ])
    }

    private func publishSitePermissions() {
        bridgeRouter?.sendSitePermissionsLoaded(from: sitePermissionStore)
    }

    private func publishWebsiteData() async {
        guard let backingStore = dataStoreProvider()?.backingStore else { return }
        let records = await backingStore.dataRecords(ofTypes: WKEngineDataStore.siteDataTypes)
        let sites = records.sorted { $0.displayName < $1.displayName }.map { record in
            let kinds = Set(record.dataTypes.map { type in
                type == WKWebsiteDataTypeCookies ? "cookies" : type.contains("Cache") ? "cache" : "storage"
            })
            return ["name": record.displayName, "kinds": kinds.sorted()] as [String: Any]
        }
        bridgeRouter?.send(event: "websiteDataLoaded", data: ["sites": sites])
    }

    private func publishZoomLevels() {
        let levels = (zoomStoreProvider()?.allZoomLevels ?? [:]).sorted { $0.key < $1.key }.map { ["host": $0.key, "zoom": $0.value] as [String: Any] }
        bridgeRouter?.send(event: "zoomLevelsLoaded", data: ["levels": levels])
    }

    private func publishStartupMetrics() {
        var snapshot = StartupMetrics.bridgeSnapshot()
        if let diagnostics = lifecycleDiagnosticsProvider() {
            snapshot["lifecycleDiagnostics"] = diagnostics.bridgeData
        }
        snapshot["perfRecordingStartedAt"] = PerfRecorder.startedAt.map { $0.timeIntervalSince1970 * 1000 } as Any
        bridgeRouter?.send(event: "startupMetricsLoaded", data: snapshot)
    }

    private func lifecycleDiagnosticsReportText(_ diagnostics: TabLifecycleDiagnostics) -> String {
        """
        Tab Lifecycle Diagnostics
        - Tracked Spaces: \(diagnostics.trackedSpaceCount)
        - Active Space Engines: \(diagnostics.activeSpaceEngineCount)
        - Hidden Space Engines: \(diagnostics.hiddenSpaceEngineCount)
        - Total Live Engines: \(diagnostics.totalLiveEngineCount)
        - Restoring Tabs: \(diagnostics.restoringTabCount)
        - Saved Interaction States: \(diagnostics.savedInteractionStateCount)
        - Discarded Open Tabs: \(diagnostics.discardedOpenTabCount)
        - Hidden Spaces With Normal Retained Engines: \(diagnostics.hiddenSpacesWithNormalRetainedEngines)
        """
    }

    private func publishExtensionDiagnostics() {
        bridgeRouter?.send(event: "extensionDiagnosticsLoaded", data: ["entries": extensionDiagnosticsEntries()])
    }

    private func extensionDiagnosticsEntries() -> [[String: Any]] {
        Self.extensionDiagnosticsEntries(from: extensionDiagnosticsProvider())
    }

    static func extensionDiagnosticsEntries(
        from snapshots: [[String: Any]],
        now: () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) -> [[String: Any]] {
        snapshots.flatMap { snapshot -> [[String: Any]] in
            guard let extensionId = snapshot["id"] as? String else { return [] }
            let extensionName = snapshot["name"] as? String ?? extensionId
            let status = snapshot["runtimeStatus"] as? String ?? ""
            let errorCount = snapshot["lastBackgroundErrorCount"] as? Int ?? snapshot["errorCount"] as? Int ?? 0
            let timestamp = now()
            var entries: [[String: Any]] = []

            let contextErrors = snapshot["contextErrors"] as? [[String: Any]] ?? []
            for error in contextErrors {
                let index = error["index"] as? Int ?? entries.count
                let description = error["description"] as? String ?? "Unknown extension context error"
                entries.append([
                    "id": "context-\(extensionId)-\(index)",
                    "timestamp": timestamp,
                    "level": "error",
                    "source": "context",
                    "extensionId": extensionId,
                    "extensionName": extensionName,
                    "message": "Extension context error: \(description)",
                    "metadata": [
                        "runtimeStatus": status,
                        "errorCount": "\(errorCount)",
                        "domain": error["domain"] as? String ?? "",
                        "code": String(describing: error["code"] ?? "")
                    ]
                ] as [String: Any])
            }
            let pageDiagnostics = snapshot["pageDiagnostics"] as? [[String: Any]] ?? []
            for diagnostic in pageDiagnostics {
                let id = diagnostic["id"] as? String ?? "\(extensionId)-page-\(entries.count)"
                let source = diagnostic["source"] as? String ?? "page"
                let url = diagnostic["url"] as? String ?? ""
                entries.append([
                    "id": "page-\(extensionId)-\(id)",
                    "timestamp": diagnostic["timestamp"] as? TimeInterval ?? timestamp,
                    "level": diagnostic["level"] as? String ?? "error",
                    "source": "page",
                    "extensionId": extensionId,
                    "extensionName": extensionName,
                    "message": "Extension page diagnostic: \(diagnostic["message"] as? String ?? "Unknown extension page diagnostic")",
                    "metadata": [
                        "runtimeStatus": status,
                        "pageSource": source,
                        "url": url
                    ]
                ] as [String: Any])
            }
            return entries
        }
    }

    /// Cutoff date for "clear history" ranges; `nil` means clear everything.
    private static func historyCutoff(for range: String) -> Date? {
        let now = Date()
        switch range {
        case "hour": return now.addingTimeInterval(-3_600)
        case "day":  return now.addingTimeInterval(-86_400)
        case "week": return now.addingTimeInterval(-604_800)
        default:     return nil
        }
    }

    private func copyToPasteboard(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
}
