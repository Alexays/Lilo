import AppKit
import Foundation
import WebKit
import os

/// Manages a WKWebExtensionController scoped to one profile and the lifecycle of its extensions.
@MainActor
final class ProfileExtensionRegistry {
    struct ExtensionNavigationTarget {
        let url: URL
        let webViewConfiguration: WKWebViewConfiguration
    }

    let profileId: UUID
    let controller: WKWebExtensionController
    let delegate: ExtensionControllerDelegate
    /// One extension window per space of this profile a browser window showed, in opening order: a space
    /// keeps its window id across switches. Held strongly; the delegate and tabManager keep weak references.
    private(set) var windowAdapters: [WindowExtensionAdapter] = []
    let extensionStorage: ExtensionStorage
    private var openedWindowAdapters: Set<ObjectIdentifier> = []

    private struct LoadedExtensionRuntime {
        let context: WKWebExtensionContext
        let id: String
        /// The folder WebKit loads, which preparation writes into.
        let sourcePath: String
        /// The folder the installed record names: `sourcePath`, or the unpacked folder it is a clone of.
        let installPath: String
        /// Manifest permissions plus the optional ones granted at Lilo's prompt, cached as a set so
        /// per-event permission scoping is a lookup.
        var permissions: Set<String>
        /// The manifest's required and optional permissions WebKit knows, whose grants the context tracks.
        let webKitPermissions: Set<String>
        /// Manifest facts read on every keyDown, omnibox keystroke or payload build, cached at load.
        let declaresCommands: Bool
        let omniboxKeyword: String?
        let hasContentScripts: Bool
        var actionColors = ActionColors()
        /// Colors set for one tab, by Lilo tab id; they win over `actionColors` while that tab is active.
        var tabActionColors: [UUID: ActionColors] = [:]
        var iconVersion = 0
        /// Error and permission-change notifications of this context.
        var contextObserver: NSObjectProtocol?
        var pageDiagnostics: [ExtensionPageDiagnostic] = []
        /// The row's fields no tab changes; nil once one of them may have.
        var staticBridgePayload: [String: Any]?
        /// Whole rows by the active tab whose action they show: windows of the profile each show their own.
        var bridgePayloads: [UUID?: [String: Any]] = [:]
        /// The row last built, whose `rowVersion` a rebuilt identical row keeps.
        var lastBridgePayload: [String: Any]?
    }

    struct ExtensionPageDiagnostic {
        let id: String
        let timestamp: Date
        let level: String
        let source: String
        let url: String
        let message: String

        var bridgePayload: [String: Any] {
            [
                "id": id,
                "timestamp": timestamp.timeIntervalSince1970,
                "level": level,
                "source": source,
                "url": url,
                "message": message
            ]
        }
    }

    private var loadedRuntimes: [LoadedExtensionRuntime] = []
    /// The content blocker's built-in extension: loaded beside the user's, never listed among them.
    private var blockerContext: WKWebExtensionContext?
    /// Installed but disabled records, so the UI can list them and re-enable; a load removes its entry.
    private(set) var disabledStoredExtensions: [ExtensionStorage.InstalledExtension] = []
    /// Enabled records that failed to load at restore, listed with the error instead of vanishing.
    private var failedRestores: [(stored: ExtensionStorage.InstalledExtension, error: String)] = []

    /// Rendered-icon cache keyed by the action's icon image, the appearance and the scale it is drawn at:
    /// WebKit hands back the same image until the icon changes, so tabs sharing an icon share one PNG pass.
    private struct IconCacheKey: Hashable {
        let image: ObjectIdentifier
        let appearance: NSAppearance.Name
        let scale: CGFloat
    }
    /// Holds each image strongly so its ObjectIdentifier cannot be reused by a different image.
    private var iconDataURLCache: [IconCacheKey: (image: NSImage, dataURL: String)] = [:]
    /// Insertion order of `iconDataURLCache` keys, so overflow evicts the oldest half, not everything.
    private var iconDataURLCacheKeys: [IconCacheKey] = []
    /// A disabled extension's manifest icon and store page, by `id@version`: read from disk once, as it has no WKWebExtension.
    private var storedManifestFacts: [String: (iconDataURL: String, webStoreURL: String)] = [:]
    /// Holds the "Update extensions automatically" setting and what the lifecycle keeps across
    /// launches; set when the profile context is built.
    weak var settingsStore: SettingsStore?

    var loadedExtensions: [(context: WKWebExtensionContext, id: String, sourcePath: String)] {
        loadedRuntimes.map { (context: $0.context, id: $0.id, sourcePath: $0.sourcePath) }
    }

    var hasLoadedExtensions: Bool { !loadedRuntimes.isEmpty }

    /// The tab state last sent to the contexts with private access (true) and without, once one asked for it.
    var sentTabStates: [Bool: ExtensionTabState] = [:]
    /// Keeps `sentTabStates` true to the tabs WebKit reports.
    weak var tabStateKeeper: TabGroupsBridgeHandler?

    private nonisolated static let logger = Logger(liloCategory: "profile-extension-registry")

    /// Called when extensions load/unload so the UI can refresh.
    var onExtensionsChanged: (() -> Void)?
    private var extensionsChangedFlushPending = false
    /// Row versions as of the last `onExtensionsChanged`; a flush whose rows keep theirs stays silent.
    private var lastNotifiedRowVersions: [Int] = []

    /// Coalesces to one `onExtensionsChanged` per main-actor turn: badge updates and tab activations
    /// arrive in bursts, and each callback rebuilds and pushes every bridge payload to the chrome UI.
    func notifyExtensionsChanged() {
        guard !extensionsChangedFlushPending else { return }
        extensionsChangedFlushPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.extensionsChangedFlushPending = false
            guard self.onExtensionsChanged != nil else { return }
            let versions = self.extensionBridgePayloads(activeTab: self.delegate.windowAdapter?.activeAdapter).map { $0["rowVersion"] as? Int ?? 0 }
            guard self.updater.statusChanged || versions != self.lastNotifiedRowVersions else { return }
            self.updater.statusChanged = false
            self.lastNotifiedRowVersions = versions
            self.onExtensionsChanged?()
        }
    }

    /// The extension's row, or every row when nil, shows something new.
    func extensionDidChange(_ extensionId: String?) {
        for index in loadedRuntimes.indices where extensionId == nil || loadedRuntimes[index].id == extensionId {
            loadedRuntimes[index].staticBridgePayload = nil
            loadedRuntimes[index].bridgePayloads = [:]
        }
        notifyExtensionsChanged()
    }

    /// Installed by `SidePanelBridgeHandler`. A toolbar-action click consults it before the popup and
    /// `action.onClicked`: it toggles the extension's side panel in the window and returns true when the
    /// extension set `openPanelOnActionClick` and has a panel for the active tab.
    var toggleSidePanelOnActionClick: ((String, MainWindowController) -> Bool)?

    /// When the user last acted on each extension: a toolbar click, a keyboard command or a context
    /// menu item. Calls that need a user gesture accept those that follow one closely, as Chrome
    /// accepts them from that event's listener.
    private var userGestureTimes: [String: TimeInterval] = [:]
    private static let userGestureLifetime: TimeInterval = 5
    private let gestureMenuItems = NSMapTable<NSMenuItem, NSString>.weakToStrongObjects()
    nonisolated(unsafe) private var menuActionObserver: Any?

    deinit {
        menuActionObserver.map { NotificationCenter.default.removeObserver($0) }
    }

    func noteUserGesture(extensionId: String) {
        userGestureTimes[extensionId] = ProcessInfo.processInfo.systemUptime
    }

    func hasRecentUserGesture(extensionId: String) -> Bool {
        userGestureTimes[extensionId].map { ProcessInfo.processInfo.systemUptime - $0 < Self.userGestureLifetime } ?? false
    }

    /// Choosing one of `items` (or of their submenus), the extension's own menu items, counts as a
    /// user gesture for it.
    func noteUserGestures(choosing items: [NSMenuItem], extensionId: String) {
        for item in items {
            gestureMenuItems.setObject(extensionId as NSString, forKey: item)
            noteUserGestures(choosing: item.submenu?.items ?? [], extensionId: extensionId)
        }
        guard menuActionObserver == nil else { return }
        menuActionObserver = NotificationCenter.default.addObserver(forName: NSMenu.didSendActionNotification, object: nil, queue: .main) { [weak self] note in
            guard let item = note.userInfo?["MenuItem"] as? NSMenuItem else { return }
            nonisolated(unsafe) let chosen = item
            MainActor.assumeIsolated {
                guard let self, let id = self.gestureMenuItems.object(forKey: chosen) else { return }
                self.noteUserGesture(extensionId: id as String)
            }
        }
    }

    /// The new-tab page an extension overrides via `chrome_url_overrides.newtab`; the last loaded wins, as Chrome's last install
    /// does. Resolve it through `extensionNavigationTarget(for:)` to get the extension's `nativeConfiguration`.
    var activeNewTabOverrideURL: URL? {
        let overriding = loadedRuntimes.filter { $0.context.webExtension.hasOverrideNewTabPage }
        guard let winner = overriding.last else { return nil }
        if overriding.count > 1 {
            let ignored = overriding.dropLast().map(\.id).joined(separator: ", ")
            Self.logger.log("multiple newtab overrides; \(winner.id, privacy: .public) wins, ignoring: \(ignored, privacy: .public)")
        }
        return winner.context.overrideNewTabPageURL
    }

    struct ActionColors {
        var badgeColor: String = ""
        var badgeTextColor: String = ""
    }

    /// The extension-wide badge colors from chrome.action, which WebKit does not expose.
    func actionColors(of extensionId: String) -> ActionColors? {
        runtimeIndex(for: extensionId).map { loadedRuntimes[$0].actionColors }
    }

    private func runtimeIndex(for extensionId: String) -> Int? {
        loadedRuntimes.firstIndex { $0.id == extensionId }
    }

    private func containsRuntime(extensionId: String) -> Bool {
        runtimeIndex(for: extensionId) != nil
    }

    private func containsRuntimeInstallPath(_ installPath: String) -> Bool {
        loadedRuntimes.contains { $0.installPath == installPath }
    }

    @discardableResult
    private func updateRuntime(extensionId: String, _ update: (inout LoadedExtensionRuntime) -> Void) -> Bool {
        guard let index = runtimeIndex(for: extensionId) else { return false }
        update(&loadedRuntimes[index])
        return true
    }

    /// Updates the extension-wide colors, or those of `tab` when given.
    func updateActionColor(for extensionId: String, tab: UUID? = nil, _ update: (inout ActionColors) -> Void) {
        guard updateRuntime(extensionId: extensionId, {
            if let tab {
                update(&$0.tabActionColors[tab, default: ActionColors()])
                $0.bridgePayloads[tab] = nil
            } else {
                update(&$0.actionColors)
                $0.bridgePayloads = [:]
            }
        }) else { return }
        notifyExtensionsChanged()
    }

    func actionDidChange(for extensionId: String) {
        guard updateRuntime(extensionId: extensionId, {
            $0.iconVersion += 1
            $0.bridgePayloads = [:]
        }) else { return }
        notifyExtensionsChanged()
    }

    /// The action fields are re-rendered for the new active tab: what it shows (its host access request)
    /// may have changed while it was not.
    func refreshActionsForActiveTabChange() {
        guard !loadedRuntimes.isEmpty else { return }
        for index in loadedRuntimes.indices {
            loadedRuntimes[index].bridgePayloads = [:]
        }
        notifyExtensionsChanged()
    }

    // MARK: - Persistence

    let extensionsBaseDirectory: URL?

    /// The copies of extensions Lilo installed for this profile.
    private(set) lazy var files = ExtensionFiles(
        directory: extensionsBaseDirectory?.appendingPathComponent("Profiles/\(profileId.uuidString)/Extensions", isDirectory: true)
    )

    // MARK: - Permission Requests

    /// Pending permission request handlers awaiting UI resolution, keyed by requestId.
    internal var pendingPermissionRequests: [String: (Bool) -> Void] = [:]

    func resolvePermissionRequest(id: String, granted: Bool) {
        guard let handler = pendingPermissionRequests.removeValue(forKey: id) else { return }
        handler(granted)
    }

    /// Answers the gap calls of this profile's workers; the page transport shares it.
    private weak var gapRouter: GapBridgeRouter?
    /// The scripts every extension page of the profile runs, the augmentation's among them.
    let pageScripts: WKUserContentController

    /// Workers' channels and the events of the APIs Lilo adds. Owned here so undelivered events
    /// survive a worker's death.
    private(set) lazy var gapEvents: GapEvents = GapEvents(
        wake: { [weak self] in self?.lifecycle.wake($0) },
        workerChannel: { [weak self] in self?.lifecycle.workerChannel($0, $1) },
        route: { @MainActor [weak self] namespace, method, params, extensionId, fromWorker in
            guard let self, let router = self.gapRouter else { return (nil, "Gap router unavailable") }
            return await router.route(
                namespace: namespace, method: method, params: params,
                extensionId: extensionId, fromWorker: fromWorker, registry: self
            )
        }
    )

    /// The profile's cookies, which `cookies.onChanged` reports on.
    private let cookieStore: WKHTTPCookieStore
    /// Watches `cookieStore` only while an extension may hear `cookies.onChanged`.
    private var cookieTracker: CookieChangeTracker?

    /// The profile's extension service workers.
    private(set) lazy var backgrounds: BackgroundSupervisor = BackgroundSupervisor(
        context: { [weak self] in self?.context(for: $0) },
        worker: { [weak self] in self?.lifecycle.worker(of: $0) },
        reload: { [weak self] in await self?.reloadFromDisk($0) },
        didChange: { [weak self] in self?.extensionDidChange($0) }
    )

    /// Each extension's lifecycle state, the one source of the runtime events Chrome sends for it.
    private(set) lazy var lifecycle: ExtensionLifecycle = ExtensionLifecycle(
        profileId: profileId,
        gapEvents: gapEvents,
        backgrounds: backgrounds,
        settings: { [weak self] in self?.settingsStore },
        applyUpdate: { [weak self] in self?.updater.applyWaitingUpdate($0, from: $1) }
    )

    private(set) lazy var updater: ExtensionUpdater = ExtensionUpdater(registry: self)

    private(set) lazy var access: ExtensionAccess = ExtensionAccess(
        storage: extensionStorage,
        context: { [weak self] in self?.context(for: $0) },
        didChange: { [weak self] extensionId in
            self?.userScripts.reinstall(for: extensionId)
            self?.extensionDidChange(extensionId)
        }
    )

    private(set) lazy var userScripts: ExtensionUserScripts = ExtensionUserScripts(
        storage: extensionStorage,
        access: access,
        pageScripts: pageScripts,
        runtime: { [weak self] id in
            guard let self, let index = self.runtimeIndex(for: id) else { return nil }
            return (self.loadedRuntimes[index].context, self.loadedRuntimes[index].sourcePath)
        }
    )

    // MARK: - Window Lifecycle

    /// The extension window of `spaceId`, created on first use, now shown in `nsWindow`. It becomes the
    /// focused one: windows bind their registry when they show a space of its profile or take focus.
    @discardableResult
    func windowAdapter(for nsWindow: NSWindow, spaceId: UUID, isPrivate: Bool = false) -> WindowExtensionAdapter {
        let adapter = windowAdapters.first { $0.spaceId == spaceId } ?? {
            let adapter = WindowExtensionAdapter(nsWindow: nsWindow, spaceId: spaceId, isPrivate: isPrivate)
            windowAdapters.append(adapter)
            return adapter
        }()
        adapter.nsWindow = nsWindow
        delegate.windowAdapter = adapter
        return adapter
    }

    /// Call when the NSWindow hosting this registry becomes key (focused).
    func notifyWindowFocused(_ focused: Bool) {
        controller.didFocusWindow(focused ? delegate.windowAdapter : nil)
    }

    func notifyWindowOpened() {
        guard let window = delegate.windowAdapter,
              openedWindowAdapters.insert(ObjectIdentifier(window)).inserted else { return }
        controller.didOpenWindow(window)
    }

    /// A closing browser window hands the spaces it showed last to another browser window, where they stay
    /// background windows; with none left, or no window named (teardown), they close.
    func notifyWindowClosed(for nsWindow: NSWindow? = nil) {
        let heir = nsWindow.flatMap { closing in delegate.windows?.windows.first { $0.window != nil && $0.window !== closing } }
        for window in windowAdapters where nsWindow == nil || window.nsWindow === nsWindow {
            if let heir {
                window.nsWindow = heir.window
                window.tabManager = heir.tabManager
            } else {
                closeWindow(window)
            }
        }
    }

    /// Closes the window of a space deleted or moved to another profile.
    func notifySpaceRemoved(_ spaceId: UUID) {
        windowAdapters.first { $0.spaceId == spaceId }.map(closeWindow)
    }

    private func closeWindow(_ window: WindowExtensionAdapter) {
        windowAdapters.removeAll { $0 === window }
        if delegate.windowAdapter === window { delegate.windowAdapter = nil }
        guard openedWindowAdapters.remove(ObjectIdentifier(window)) != nil else { return }
        controller.didCloseWindow(window)
    }

    // MARK: - Tab positions

    /// The Lilo tab at each `{windowPosition, index}` pair (the window's place in `windows.getAll()` and
    /// the tab's index in it), which is how the bridge resolves WebKit's integer tab ids; nil when unknown.
    func tabIds(atPositions positions: [[String: Any]], extensionId: String) -> [UUID?] {
        tabAdapters(atPositions: positions, extensionId: extensionId).map { $0?.tabId }
    }

    func tabAdapters(atPositions positions: [[String: Any]], extensionId: String) -> [TabExtensionAdapter?] {
        guard let context = context(for: extensionId) else { return positions.map { _ in nil } }
        let windows = extensionWindows(for: context)
        var tabsByWindow: [Int: [any WKWebExtensionTab]] = [:]
        return positions.map { position in
            guard let window = (position["windowPosition"] as? NSNumber)?.intValue,
                  let index = (position["index"] as? NSNumber)?.intValue,
                  windows.indices.contains(window) else { return nil }
            let tabs = tabsByWindow[window] ?? windows[window].tabs(for: context)
            tabsByWindow[window] = tabs
            return tabs.indices.contains(index) ? tabs[index] as? TabExtensionAdapter : nil
        }
    }

    /// The `{windowPosition, index}` of the tab showing `webView`, the inverse of `tabIds(atPositions:)`.
    func tabPosition(of webView: WKWebView, extensionId: String) -> [String: Int]? {
        guard let context = context(for: extensionId) else { return nil }
        for (position, window) in extensionWindows(for: context).enumerated() {
            if let index = window.tabs(for: context).firstIndex(where: { ($0 as? TabExtensionAdapter)?.webView(for: context) === webView }) {
                return ["windowPosition": position, "index": index]
            }
        }
        return nil
    }

    /// The `{windowPosition, index}` of `adapter` as the extension sees it.
    func tabPosition(of adapter: TabExtensionAdapter, extensionId: String) -> [String: Int]? {
        guard let context = context(for: extensionId),
              let window = adapter.extensionWindow as? WindowExtensionAdapter,
              let position = extensionWindows(for: context).firstIndex(where: { $0 === window }) else { return nil }
        let index = window.index(of: adapter)
        return index == NSNotFound ? nil : ["windowPosition": position, "index": index]
    }

    /// The place of `window` in the extension's `windows.getAll()`.
    func windowPosition(of window: WindowExtensionAdapter, extensionId: String) -> Int? {
        context(for: extensionId).flatMap { extensionWindows(for: $0).firstIndex { $0 === window } }
    }

    /// The window at `position` in the extension's `windows.getAll()`.
    func extensionWindow(at position: Int, extensionId: String) -> WindowExtensionAdapter? {
        guard let context = context(for: extensionId) else { return nil }
        let windows = extensionWindows(for: context)
        return windows.indices.contains(position) ? windows[position] : nil
    }

    /// WebKit's open windows: the registry's adapters, or the delegate's own window when none.
    var extensionWindows: [WindowExtensionAdapter] {
        (windowAdapters.isEmpty ? [delegate.windowAdapter].compactMap { $0 } : windowAdapters) + delegate.popupWindowAdapters
    }

    /// The windows `context` sees, in its `windows.getAll()` order, which its positions index. WebKit keeps that order per
    /// context, the window opened or focused last first, and hides private windows from an extension without private access.
    func extensionWindows(for context: WKWebExtensionContext) -> [WindowExtensionAdapter] {
        let windows = context.openWindows.compactMap { $0 as? WindowExtensionAdapter }
        return context.hasAccessToPrivateData ? windows : windows.filter { !$0.isPrivateWindow }
    }

    /// Sends an event whose details hold window or tab positions to `ids`. The details are built once per
    /// window list, the only thing positions depend on, for the first extension seeing it; extensions whose
    /// `details` is nil (the tab is hidden from them) get nothing.
    func emitPositioned(_ namespace: String, _ event: String, to ids: [String], details: (_ extensionId: String) -> [String: Any]?) {
        var classes: [(windows: [ObjectIdentifier], details: [String: Any]?, ids: [String])] = []
        for id in ids {
            guard let context = context(for: id) else { continue }
            let windows = extensionWindows(for: context).map { ObjectIdentifier($0) }
            if let index = classes.firstIndex(where: { $0.windows == windows }) {
                classes[index].ids.append(id)
            } else {
                classes.append((windows, details(id), [id]))
            }
        }
        for group in classes {
            if let details = group.details { gapEvents.emit(namespace, event, args: [details], to: group.ids) }
        }
    }

    // MARK: - Init

    init(
        profileId: UUID,
        extensionStorage: ExtensionStorage,
        gapRouter: GapBridgeRouter? = nil,
        tabShare: (bridge: TabShareBridge, frames: TabShareFrameSchemeHandler)? = nil,
        // Injectable so tests keep their installed-extension copies out of the user's real
        // Application Support; the default follows BuildIdentity, LILO_APP_SUPPORT_DIR included.
        extensionsBaseDirectory: URL? = URL(fileURLWithPath: BuildIdentity.appSupportDirectory)
    ) {
        self.profileId = profileId
        self.extensionStorage = extensionStorage
        self.extensionsBaseDirectory = extensionsBaseDirectory
        let config = WKWebExtensionController.Configuration(identifier: profileId)
        let userContentController = config.webViewConfiguration.userContentController
        // Extension pages, workers and the cookies API see this profile's data, not the app default
        // store. Returns the same store the profile's tabs use (WebKit keys stores by identifier).
        let profileDataStore = WKWebsiteDataStore(forIdentifier: profileId)
        config.defaultWebsiteDataStore = profileDataStore
        config.webViewConfiguration.websiteDataStore = profileDataStore
        // Workers, popups and panels WebKit creates read Chrome in their user agent, as extensions expect.
        config.webViewConfiguration.applicationNameForUserAgent = ChromeMasquerade.chromeApplicationName
        // Without a pool, each extension's views get one of their own, which lists every installed font on the main thread as it
        // starts its first process: about 15 ms per extension at launch.
        if let pool = WKEngineFactory.contentProcessPool, config.webViewConfiguration.responds(to: NSSelectorFromString("setProcessPool:")) {
            config.webViewConfiguration.setValue(pool, forKey: "processPool")
        }
        cookieStore = profileDataStore.httpCookieStore

        // WebKit snapshots the configuration at controller-creation time: set everything up first.

        // A background web view whose process launch is deferred takes WebKit's keep-awake activity on
        // the placeholder process, which drops it once the real one starts: the process then suspends
        // and WebKit terminates the service worker ~5s after load while still reporting it loaded.
        let delaysLaunch = NSSelectorFromString("_setDelaysWebProcessLaunchUntilFirstLoad:")
        if config.webViewConfiguration.responds(to: delaysLaunch) {
            typealias SetBool = @convention(c) (NSObject, Selector, Bool) -> Void
            unsafeBitCast(config.webViewConfiguration.method(for: delaysLaunch), to: SetBool.self)(config.webViewConfiguration, delaysLaunch, false)
        }

        // Injected into every frame of the WebViews the controller manages but web pages', where it would only exit.
        if let url = Bundle.appResourceURL("ChromeAPIAugmentation", extension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            let webPages = ["http://*/*", "https://*/*"]
            userContentController.addUserScript(
                ExtensionUserScripts.makeMatchingUserScript?(source, .atDocumentStart, false, [], webPages, .page)
                    ?? WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
            )
        } else {
            Self.logger.error("ChromeAPIAugmentation.js not found in bundle: Chrome API bridge will be absent")
        }

        // Extension pages and offscreen documents consume tabCapture and desktopCapture stream ids
        // through the tab-share shim's getUserMedia, fed over the ferry's frame scheme.
        if let tabShare {
            config.webViewConfiguration.setURLSchemeHandler(tabShare.frames, forURLScheme: TabShareFrameSchemeHandler.scheme)
            userContentController.addScriptMessageHandler(tabShare.bridge, contentWorld: PageWorld.bridgeWorld, name: TabShareBridge.messageHandlerName)
            PageWorld.install([TabShareBridge.pageModule], on: userContentController)
        }

        self.pageScripts = userContentController
        self.controller = WKWebExtensionController(configuration: config)
        self.delegate = ExtensionControllerDelegate()
        self.controller.delegate = self.delegate

        self.gapRouter = gapRouter
        delegate.registry = self
    }

    // MARK: - Gap event emission (native to extension)

    /// The extension's manifest permissions, read once at load, plus the optional ones WebKit grants no
    /// request for that the user granted at Lilo's prompt.
    func heldPermissions(of extensionId: String) -> Set<String> {
        runtimeIndex(for: extensionId).map { loadedRuntimes[$0].permissions } ?? []
    }

    /// Grants or removes optional permissions WebKit grants no request for, kept across relaunches.
    func setGapPermissions(_ names: Set<String>, granted: Bool, extensionId: String) async {
        guard !names.isEmpty, updateRuntime(extensionId: extensionId, { granted ? $0.permissions.formUnion(names) : $0.permissions.subtract(names) }) else { return }
        await access.update(extensionId) { state in
            let kept = Set(state.gapPermissions ?? [])
            let held = (granted ? kept.union(names) : kept.subtracting(names)).sorted()
            state.gapPermissions = held.isEmpty ? nil : held
        }
    }

    /// Scopes a gap event to the extensions Chrome would actually deliver it to.
    func extensionIds(withPermission permission: String) -> [String] {
        loadedRuntimes.compactMap { $0.permissions.contains(permission) ? $0.id : nil }
    }

    /// The loaded extensions that may hear an event Chrome sends without a permission.
    func listeningExtensionIds(_ namespace: String, _ event: String) -> [String] {
        gapEvents.listeners(among: loadedRuntimes.map(\.id), namespace: namespace, event: event)
    }

    /// The loaded extension that registered `keyword` as its omnibox keyword (case-insensitive).
    func extensionId(forOmniboxKeyword keyword: String) -> String? {
        let needle = keyword.lowercased()
        return loadedRuntimes.first { $0.omniboxKeyword?.lowercased() == needle }?.id
    }

    /// Sends each loaded extension with private access or without, as `hasPrivateAccess`, its `message` at once over its open channels.
    func sendToOpenChannels(hasPrivateAccess: Bool, _ message: (WKWebExtensionContext) -> [String: Any]) {
        for runtime in loadedRuntimes where runtime.context.hasAccessToPrivateData == hasPrivateAccess {
            gapEvents.send(message(runtime.context), toOpenChannelsOf: runtime.id)
        }
    }

    /// Fire a gap event to every loaded extension holding `requiredPermission`.
    func emitGapEvent(_ namespace: String, _ event: String, args: [Any], requiredPermission: String) {
        gapEvents.emit(namespace, event, args: args, to: extensionIds(withPermission: requiredPermission))
    }

    /// Extensions that hid the download UI through `downloads.setUiOptions`; it shows while none has.
    private(set) var downloadUiDisabledBy: Set<String> = []

    /// False when the UI stays hidden for another extension, which Chrome reports as an error.
    func setDownloadUiEnabled(_ enabled: Bool, by extensionId: String) -> Bool {
        let wasHidden = !downloadUiDisabledBy.isEmpty
        if enabled { downloadUiDisabledBy.remove(extensionId) } else { downloadUiDisabledBy.insert(extensionId) }
        if wasHidden != !downloadUiDisabledBy.isEmpty { onExtensionsChanged?() }
        return !enabled || downloadUiDisabledBy.isEmpty
    }

    /// `action.onUserSettingsChanged` for each loaded extension pinned to or unpinned from the address
    /// bar, given the old and new comma-separated pin lists.
    func pinnedExtensionsChanged(from old: String?, to new: String) {
        let before = Set((old ?? "").split(separator: ",").map(String.init))
        let after = Set(new.split(separator: ",").map(String.init))
        for id in before.symmetricDifference(after) where containsRuntime(extensionId: id) {
            gapEvents.emit("action", "onUserSettingsChanged", args: [["isOnToolbar": after.contains(id)]], to: [id])
        }
    }

    /// Gap events a page or the worker of a loaded extension listens to: `GapEvents` keeps a page's itself,
    /// the worker's are kept across launches. A cookies.onChanged listener hears of it once the cookies
    /// are read, so a change its context makes next is reported.
    func addGapListeners(_ events: [String], extensionId: String, fromWorker: Bool) async {
        guard let context = context(for: extensionId) else { return }
        if fromWorker { lifecycle.listen(events, extensionId: extensionId, version: context.webExtension.version) }
        gapListenersChanged()
        if events.contains("cookies.onChanged") { await cookieTracker?.catchUp() }
    }

    /// Gap events a page or the worker no longer listens to: its last listener for each went.
    func removeGapListeners(_ events: [String], extensionId: String, fromWorker: Bool) {
        guard let context = context(for: extensionId) else { return }
        if fromWorker { lifecycle.listen(events, extensionId: extensionId, removed: true, version: context.webExtension.version) }
        gapListenersChanged()
    }

    private func gapListenersChanged() {
        syncCookieTracking()
        NotificationCenter.default.post(name: .extensionGapListenersChanged, object: self)
    }

    /// Returns once the cookie changes made so far are reported to the extensions that listen.
    func cookieChangesReported() async {
        await cookieTracker?.catchUp()
    }

    private var cookieChangeListenerIds: [String] {
        gapEvents.listeners(among: extensionIds(withPermission: "cookies"), namespace: "cookies", event: "onChanged")
    }

    /// Called whenever extensions load, unload or report their listeners.
    private func syncCookieTracking() {
        let wanted = !cookieChangeListenerIds.isEmpty
        if wanted, cookieTracker == nil {
            cookieTracker = CookieChangeTracker(store: cookieStore) { [weak self] in self?.emitCookieChanges($0) }
        } else if !wanted, let cookieTracker {
            cookieTracker.stop()
            self.cookieTracker = nil
        }
    }

    /// Each change reaches the listening extensions with host access to the cookie's domain, as in Chrome.
    private func emitCookieChanges(_ changes: [CookieChangeTracker.Change]) {
        let contexts = cookieChangeListenerIds.compactMap { id in context(for: id).map { (id, $0) } }
        for change in changes {
            guard let url = change.originURL else { continue }
            let ids = contexts.filter { $0.1.hasAccess(to: url) }.map(\.0)
            if !ids.isEmpty { gapEvents.emit("cookies", "onChanged", args: [change.changeInfo], to: ids) }
        }
    }

    // MARK: - Load / Unload

    /// Load an extension from a URL (permanent or temp). Copies temp URLs to permanent location.
    /// `extensionId` keeps a known id (enable, reload, update); a new install derives one. Without
    /// `load`, a new id is an install and a known one a reload.
    func load(from url: URL, extensionId knownId: String? = nil, as load: ExtensionLifecycle.Load? = nil) async throws {
        try await files.whileWriting {
            let permanentURL = try files.permanentCopy(of: url, isInUse: containsRuntimeInstallPath)
            // Reinstalling a folder keeps the id it already had, so its storage follows it.
            let stored = if let knownId { try? await extensionStorage.load(id: knownId) } else {
                (try? await extensionStorage.loadAll())?.first { $0.path == permanentURL.path }
            }
            let allowsUserScripts = (knownId ?? stored?.id).map { access.states[$0]?.allowsUserScripts == true } ?? false
            let files = files
            let (sourceURL, isPreparationDegraded) = try await Task.detached(priority: .userInitiated) {
                let sourceURL = try files.workingCopy(of: permanentURL)
                return (sourceURL, Self.prepareForWebKit(at: sourceURL, allowsUserScripts: allowsUserScripts))
            }.value
            let webExtension = try await WKWebExtension(resourceBaseURL: sourceURL)
            let extensionId = knownId ?? stored?.id ?? ExtensionFiles.makeExtensionId(
                for: permanentURL,
                managedDirectory: files.directory,
                manifestKey: webExtension.manifest["key"] as? String
            )
            try await activate(
                webExtension, id: extensionId, sourcePath: sourceURL.path, installPath: permanentURL.path,
                isPreparationDegraded: isPreparationDegraded, stored: stored, as: load ?? (knownId == nil ? .install : .reload)
            )
        }
    }

    /// Manifest parsing and file writes, safe off the main thread. True when the extension must load
    /// degraded: `.skipped` and a thrown error both mean the manifest may still point at the unwrapped
    /// vendor worker.
    nonisolated static func prepareForWebKit(at url: URL, allowsUserScripts: Bool) -> Bool {
        do {
            guard try prepareBackgroundServiceWorkerForWKIfNeeded(at: url, allowsUserScripts: allowsUserScripts) == .skipped else { return false }
            logger.warning("Background service worker preparation skipped for \(url.lastPathComponent, privacy: .public); extension will load degraded")
        } catch {
            logger.error("Failed to prepare background service worker for WK compatibility: \(ExtensionDiagnostics.diagnosticDescription(for: error), privacy: .public); extension will load degraded")
        }
        return true
    }

    /// Creates, grants and loads the context. `stored` is the record as persisted, so a restore that
    /// changes nothing skips the database write; nil makes a new install.
    private func activate(
        _ webExtension: WKWebExtension,
        id extensionId: String,
        sourcePath: String,
        installPath: String,
        isPreparationDegraded: Bool,
        stored: ExtensionStorage.InstalledExtension?,
        as load: ExtensionLifecycle.Load
    ) async throws {
        guard !containsRuntime(extensionId: extensionId) else { notifyExtensionsChanged(); return }

        let context = WKWebExtensionContext(for: webExtension)
        // Stable across updates: WebKit keys the extension's storage by it.
        context.uniqueIdentifier = extensionId
        // WebKit's default host is a fresh UUID per launch, which strands restored extension tabs and
        // their pages' origin storage.
        context.baseURL = URL(string: "chrome-extension://\(extensionId)")!

        #if DEBUG
        // Attaching Web Inspector to extension internals must stay out of release builds.
        context.isInspectable = true
        context.inspectionName = "\(webExtension.displayName ?? extensionId) - Background"
        #endif

        access.apply(to: context, extensionId: extensionId)
        try controller.load(context)
        let optional = Set(webExtension.manifest["optional_permissions"] as? [String] ?? [])
        let granted = (access.states[extensionId]?.gapPermissions ?? []).filter(optional.contains)
        let permissions = Set(webExtension.manifest["permissions"] as? [String] ?? []).union(granted)
        loadedRuntimes.append(LoadedExtensionRuntime(
            context: context,
            id: extensionId,
            sourcePath: sourcePath,
            installPath: installPath,
            permissions: permissions,
            webKitPermissions: Set(webExtension.requestedPermissions.union(webExtension.optionalPermissions).map(\.rawValue)),
            declaresCommands: !((webExtension.manifest["commands"] as? [String: Any])?.isEmpty ?? true),
            omniboxKeyword: (webExtension.manifest["omnibox"] as? [String: Any])?["keyword"] as? String,
            hasContentScripts: !((webExtension.manifest["content_scripts"] as? [[String: Any]])?.isEmpty ?? true)
        ))
        lifecycle.loaded(
            extensionId, load, version: webExtension.version, storedVersion: stored?.version,
            hasBackground: webExtension.hasBackgroundContent, preparationDegraded: isPreparationDegraded
        )
        syncCookieTracking()
        updateRuntime(extensionId: extensionId) { $0.contextObserver = makeContextObserver(for: context, extensionId: extensionId) }
        disabledStoredExtensions.removeAll { $0.id == extensionId }
        failedRestores.removeAll { $0.stored.id == extensionId }
        for adapter in windowAdapters where adapter.tabManager?.windowAdapter === adapter { adapter.tabManager?.rebuildTabsAwaitingTheirExtension() }
        let record = ExtensionStorage.InstalledExtension(
            id: extensionId, name: webExtension.displayName ?? extensionId, version: webExtension.version ?? "", path: installPath, isEnabled: true
        )
        if record != stored {
            try? await extensionStorage.store(id: record.id, name: record.name, version: record.version, path: record.path, enabled: true)
        }
        if permissions.contains("userScripts") {
            await userScripts.loaded(extensionId)
        } else if webExtension.manifest["externally_connectable"] != nil {
            userScripts.reinstall(for: extensionId)
        }
        notifyExtensionsChanged()
        // Wakes lazy pollers (chrome.idle): a listener-only extension is invisible to the gap bridge.
        NotificationCenter.default.post(name: .extensionRuntimeLoaded, object: self)
        // No background load here: WebKit starts it for runtime.onStartup/onInstalled listeners and on
        // demand (popup, command, event), so a restore never forces every worker awake.
    }

    /// Uninstalls the extension, or with `removePersistedRecord` false unloads it and keeps it installed
    /// but disabled, as a reload or an update does before loading it again.
    func unload(extensionId: String, removePersistedRecord: Bool = true) async {
        await unload(extensionId: extensionId, removePersistedRecord: removePersistedRecord, purge: removePersistedRecord)
    }

    /// `purge` drops the events its worker has not received yet, as an uninstall or a disable does.
    private func unload(extensionId: String, removePersistedRecord: Bool, purge: Bool) async {
        guard let index = runtimeIndex(for: extensionId) else {
            guard removePersistedRecord,
                  let stored = disabledStoredExtensions.first(where: { $0.id == extensionId })
                    ?? failedRestores.first(where: { $0.stored.id == extensionId })?.stored else { return }
            disabledStoredExtensions.removeAll { $0.id == extensionId }
            failedRestores.removeAll { $0.stored.id == extensionId }
            lifecycle.uninstalled(extensionId)
            await removePersistedExtension(extensionId: extensionId)
            await removeExtensionData(extensionId: extensionId)
            files.remove(stored.path)
            postDidUnload(extensionId: extensionId, uninstalled: true)
            notifyExtensionsChanged()
            return
        }
        let runtime = loadedRuntimes.remove(at: index)
        if removePersistedRecord {
            lifecycle.uninstalled(extensionId)
        } else {
            lifecycle.unloaded(extensionId, disabled: true, purge: purge)
        }
        _ = setDownloadUiEnabled(true, by: extensionId)
        access.unloaded(extensionId)
        syncCookieTracking()
        delegate.closeActionPopups(of: runtime.context)
        _ = try? controller.unload(runtime.context)
        runtime.contextObserver.map { NotificationCenter.default.removeObserver($0) }
        userScripts.unloaded(extensionId)
        postDidUnload(extensionId: extensionId, uninstalled: removePersistedRecord)
        if removePersistedRecord {
            await removePersistedExtension(extensionId: extensionId)
            await removeExtensionData(extensionId: extensionId)
            scheduleUninstallFileCleanup(extensionId: extensionId, installPath: runtime.installPath)
        } else {
            await persistInstalledExtension(id: runtime.id, context: runtime.context, installPath: runtime.installPath, enabled: false)
            if let stored = try? await extensionStorage.load(id: runtime.id) { disabledStoredExtensions.append(stored) }
        }
        notifyExtensionsChanged()
    }

    /// Lets gap handlers drop what they hold for the extension (`uninstalled` also clears what they
    /// persisted). Also posted for a reload or an update, which unload the context first.
    private func postDidUnload(extensionId: String, uninstalled: Bool) {
        NotificationCenter.default.post(
            name: .extensionDidUnload,
            object: self,
            userInfo: ["extensionId": extensionId, "profileId": profileId, "uninstalled": uninstalled]
        )
    }

    func enable(extensionId: String) async throws {
        guard let stored = try await extensionStorage.load(id: extensionId) else { return }
        do {
            try await load(from: URL(fileURLWithPath: stored.path, isDirectory: true), extensionId: extensionId, as: .enable)
        } catch {
            // A retried failed row shows the latest error, not the one from launch.
            if let index = failedRestores.firstIndex(where: { $0.stored.id == extensionId }) {
                failedRestores[index].error = ExtensionDiagnostics.diagnosticDescription(for: error)
                notifyExtensionsChanged()
            }
            throw error
        }
    }

    func disable(extensionId: String) async {
        if containsRuntime(extensionId: extensionId) {
            await unload(extensionId: extensionId, removePersistedRecord: false, purge: true)
        } else {
            lifecycle.unloaded(extensionId, disabled: true, purge: true)
            try? await extensionStorage.setEnabled(id: extensionId, enabled: false)
            notifyExtensionsChanged()
        }
    }

    func context(for extensionId: String) -> WKWebExtensionContext? {
        runtimeIndex(for: extensionId).map { loadedRuntimes[$0].context }
    }

    /// What a gap call of the loaded extension is checked against: its context, the permissions WebKit
    /// tracks the grants of, and `heldPermissions`.
    func gapCaller(_ extensionId: String) -> (context: WKWebExtensionContext, webKitPermissions: Set<String>, held: Set<String>)? {
        runtimeIndex(for: extensionId).map { (loadedRuntimes[$0].context, loadedRuntimes[$0].webKitPermissions, loadedRuntimes[$0].permissions) }
    }

    /// Tears the registry down for cache eviction, unloading every context but never the persisted list or on-disk state.
    /// Pending permission prompts are denied first: WebKit's checked completion handlers crash if dropped uninvoked.
    func teardown() {
        restoring = nil
        updater.stop()
        onExtensionsChanged = nil
        for id in Array(pendingPermissionRequests.keys) {
            resolvePermissionRequest(id: id, granted: false)
        }
        // Close the window while the contexts still exist, so they observe it before unloading.
        notifyWindowClosed()
        for runtime in loadedRuntimes {
            runtime.contextObserver.map { NotificationCenter.default.removeObserver($0) }
            delegate.closeActionPopups(of: runtime.context)
            _ = try? controller.unload(runtime.context)
        }
        if let blockerContext { _ = try? controller.unload(blockerContext) }
        blockerContext = nil
        let ids = loadedRuntimes.map(\.id)
        loadedRuntimes = []
        ids.forEach { lifecycle.unloaded($0, disabled: false, purge: false) }
        syncCookieTracking()
        for id in ids {
            userScripts.unloaded(id)
            postDidUnload(extensionId: id, uninstalled: false)
        }
    }

    /// Replaces the content blocker's built-in extension with the one at `url`; nil leaves none.
    func loadBlockerExtension(at url: URL?) async {
        if let blockerContext { _ = try? controller.unload(blockerContext) }
        blockerContext = nil
        guard let url, let webExtension = try? await WKWebExtension(resourceBaseURL: url) else { return }
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = "lilo-content-blocker"
        context.baseURL = URL(string: "chrome-extension://lilo-content-blocker")!
        webExtension.requestedPermissions.forEach { context.setPermissionStatus(.grantedExplicitly, for: $0) }
        webExtension.allRequestedMatchPatterns.forEach { context.setPermissionStatus(.grantedExplicitly, for: $0) }
        // The content blocker filters private spaces too: WebKit applies no rule of a context without this to an ephemeral store.
        context.hasAccessToPrivateData = true
        do {
            try controller.load(context)
            blockerContext = context
        } catch {
            Self.logger.error("content blocker extension failed to load: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Unloads and reloads the extension from its on-disk source, for a worker nothing else revives.
    private func reloadFromDisk(_ extensionId: String) async {
        guard let installPath = runtimeIndex(for: extensionId).map({ loadedRuntimes[$0].installPath }) else { return }
        await unload(extensionId: extensionId, removePersistedRecord: false)
        do {
            try await load(from: URL(fileURLWithPath: installPath), extensionId: extensionId)
        } catch {
            Self.logger.error("background reload failed for \(extensionId, privacy: .public): \(ExtensionDiagnostics.diagnosticDescription(for: error), privacy: .public)")
            // `unload` flipped the persisted record to disabled; a failed internal restart must not leave the
            // extension skipped on next launch, and the panel lists it as failed rather than disabled.
            try? await extensionStorage.setEnabled(id: extensionId, enabled: true)
            if let index = disabledStoredExtensions.firstIndex(where: { $0.id == extensionId }) {
                failedRestores.append((disabledStoredExtensions.remove(at: index), ExtensionDiagnostics.diagnosticDescription(for: error)))
                notifyExtensionsChanged()
            }
        }
    }

    // MARK: - Keyboard Commands

    /// Dispatches a keyDown to the first loaded extension command whose shortcut matches. Returns true
    /// when one matched, so the caller swallows the event.
    func handleExtensionKeyDown(_ event: NSEvent) -> Bool {
        let inPrivateWindow = delegate.windowAdapter?.isPrivateWindow == true
        for runtime in loadedRuntimes where !inPrivateWindow || runtime.context.hasAccessToPrivateData {
            // Most installs declare no commands; skip the WebKit event-matching call for them.
            guard runtime.declaresCommands,
                  // `command(for:)` rather than `performCommand(for:)`: the background must be awake first.
                  let command = runtime.context.command(for: event) else { continue }
            let extensionId = runtime.id
            let commandId = command.id
            noteUserGesture(extensionId: extensionId)
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.backgrounds.ensureResponsive(extensionId)
                // Re-fetch: a stale worker may have been reloaded into a new context.
                guard let context = self.context(for: extensionId),
                      let command = context.commands.first(where: { $0.id == commandId }) else { return }
                context.performCommand(command)
            }
            return true
        }
        return false
    }

    func extensionNavigationTarget(for url: URL) -> ExtensionNavigationTarget? {
        guard url.scheme?.lowercased() == "chrome-extension", let host = url.host,
              let webViewConfiguration = loadedRuntimes.first(where: { $0.id == host })?.context.webViewConfiguration else {
            return nil
        }
        return ExtensionNavigationTarget(url: url, webViewConfiguration: webViewConfiguration)
    }

    /// Shared by every registry: a window showing another profile's row of the same id must not find its version.
    private static var lastRowVersion = 0

    /// Gives `row` the `rowVersion` of `last` when they are equal, else a new one: rows compare by version alone.
    private static func setRowVersion(_ row: inout [String: Any], after last: [String: Any]?) {
        row["rowVersion"] = last?["rowVersion"]
        if let last, (row as NSDictionary).isEqual(to: last) { return }
        lastRowVersion += 1
        row["rowVersion"] = lastRowVersion
    }

    /// The disabled and failed rows as last built, by id: built on every call, they keep their version while equal.
    private var storedBridgePayloads: [String: [String: Any]] = [:]

    /// Returns fully-populated bridge payloads for each extension, reading real values from WebKit, each with a
    /// `rowVersion` that changes with its fields. The action (icon, badge, enabled state) is the one `activeTab`
    /// shows: each window passes its own.
    func extensionBridgePayloads(activeTab: TabExtensionAdapter?) -> [[String: Any]] {
        var payloads: [[String: Any]] = []
        payloads.reserveCapacity(loadedRuntimes.count + disabledStoredExtensions.count + failedRestores.count)
        let tabId = activeTab?.tabId
        for index in loadedRuntimes.indices {
            if let cached = loadedRuntimes[index].bridgePayloads[tabId] {
                payloads.append(cached)
                continue
            }
            var payload = loadedRuntimes[index].staticBridgePayload ?? buildStaticBridgePayload(at: index)
            loadedRuntimes[index].staticBridgePayload = payload
            addActionFields(to: &payload, at: index, activeTab: activeTab)
            Self.setRowVersion(&payload, after: loadedRuntimes[index].lastBridgePayload)
            loadedRuntimes[index].lastBridgePayload = payload
            loadedRuntimes[index].bridgePayloads[tabId] = payload
            payloads.append(payload)
        }
        let loadedCount = payloads.count
        // A disabled extension has no WKWebExtension to read from; the row carries what storage kept.
        for stored in disabledStoredExtensions {
            let facts = storedManifestFacts(for: stored)
            payloads.append([
                "id": stored.id,
                "name": stored.name,
                "version": stored.version,
                "isEnabled": false,
                "runtimeStatus": "loaded",
                "iconDataURL": facts.iconDataURL,
                "webStoreURL": facts.webStoreURL,
                "availableUpdate": updater.availableUpdates[stored.id]?.latest ?? "",
                "declinedUpdate": access.states[stored.id]?.declinedUpdateVersion ?? "",
                "allowsPrivateAccess": access.states[stored.id]?.allowsPrivateAccess == true,
                "allowsUserScripts": access.states[stored.id]?.allowsUserScripts == true
            ] as [String: Any])
        }
        // Enabling a failed row retries the load.
        for (stored, error) in failedRestores {
            payloads.append([
                "id": stored.id,
                "name": stored.name,
                "version": stored.version,
                "isEnabled": false,
                "runtimeStatus": "failed",
                "error": error
            ] as [String: Any])
        }
        var stored: [String: [String: Any]] = [:]
        for index in payloads.indices.dropFirst(loadedCount) {
            guard let id = payloads[index]["id"] as? String else { continue }
            Self.setRowVersion(&payloads[index], after: storedBridgePayloads[id])
            stored[id] = payloads[index]
        }
        storedBridgePayloads = stored
        return payloads
    }

    func backgroundDiagnosticsSnapshots() -> [[String: Any]] {
        loadedRuntimes.map { runtime in
            var payload: [String: Any] = [
                "id": runtime.id,
                "name": runtime.context.webExtension.displayName ?? runtime.id,
                "runtimeStatus": backgrounds.health(for: runtime.id)?.bridgeStatus ?? "loaded",
                "hasBackground": runtime.context.webExtension.hasBackgroundContent,
                "errorCount": runtime.context.errors.count,
                "lastBackgroundErrorCount": backgrounds.health(for: runtime.id)?.lastErrorCount ?? 0
            ]
            payload["contextErrors"] = runtime.context.errors.enumerated().map { index, error in
                let nsError = error as NSError
                return [
                    "index": index,
                    "domain": nsError.domain,
                    "code": nsError.code,
                    "description": ExtensionDiagnostics.diagnosticDescription(for: error)
                ] as [String: Any]
            }
            payload["pageDiagnostics"] = runtime.pageDiagnostics.map(\.bridgePayload)
            return payload
        }
    }

    func clearBackgroundDiagnostics() {
        backgrounds.clearErrorCounts()
        for index in loadedRuntimes.indices {
            loadedRuntimes[index].pageDiagnostics = []
        }
    }

    func recordExtensionNativeDiagnostic(
        context: WKWebExtensionContext,
        level: String,
        source: String,
        message: String,
        url: String = ""
    ) {
        guard let extensionId = loadedRuntimes.first(where: { $0.context === context })?.id else { return }
        recordExtensionNativeDiagnostic(extensionId: extensionId, level: level, source: source, message: message, url: url)
    }

    func recordExtensionNativeDiagnostic(
        extensionId: String,
        level: String,
        source: String,
        message: String,
        url: String = ""
    ) {
        guard containsRuntime(extensionId: extensionId) else { return }
        let diagnostic = ExtensionPageDiagnostic(
            id: UUID().uuidString,
            timestamp: Date(),
            level: level,
            source: source,
            url: url,
            message: message
        )
        updateRuntime(extensionId: extensionId) {
            $0.pageDiagnostics.append(diagnostic)
            if $0.pageDiagnostics.count > 50 {
                $0.pageDiagnostics.removeFirst($0.pageDiagnostics.count - 50)
            }
        }
        if level == "error" {
            Self.logger.error("Extension page diagnostic for \(extensionId, privacy: .public): \(diagnostic.source, privacy: .public) \(message, privacy: .public)")
        } else {
            Self.logger.info("Extension page diagnostic for \(extensionId, privacy: .public): \(diagnostic.source, privacy: .public) \(message, privacy: .public)")
        }
    }

    /// The row's fields that no tab changes.
    private func buildStaticBridgePayload(at index: Int) -> [String: Any] {
        let runtime = loadedRuntimes[index]
        let ext = runtime.context.webExtension
        let health = backgrounds.health(for: runtime.id)
        let accessState = access.states[runtime.id]
        return [
            "id": runtime.id,
            "name": ext.displayName ?? runtime.id,
            "version": ext.displayVersion ?? "",
            "description": ext.displayDescription ?? "",
            "isEnabled": true,
            "hasBackground": ext.hasBackgroundContent,
            "runtimeStatus": health?.bridgeStatus ?? "loaded",
            "hasContentScripts": runtime.hasContentScripts,
            "permissions": ext.manifest["permissions"] as? [String] ?? [],
            "hostPermissions": ext.manifest["host_permissions"] as? [String] ?? [],
            "siteAccess": accessState?.hosts ?? [],
            "error": health.flatMap { $0.failed ? $0.failureReason ?? "" : nil } ?? "",
            "omniboxKeyword": runtime.omniboxKeyword ?? "",
            "availableUpdate": updater.availableUpdates[runtime.id]?.latest ?? "",
            "webStoreURL": updater.isStoreCopy(id: runtime.id, path: runtime.installPath, manifest: ext.manifest)
                ? "https://chromewebstore.google.com/detail/\(runtime.id)" : "",
            "declinedUpdate": accessState?.declinedUpdateVersion ?? "",
            "allowsPrivateAccess": runtime.context.hasAccessToPrivateData,
            "allowsUserScripts": accessState?.allowsUserScripts == true,
            "commands": runtime.declaresCommands ? runtime.context.commands.map { command in
                [
                    "id": command.id,
                    "title": command.title,
                    "key": command.activationKey ?? "",
                    "modifiers": command.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
                ] as [String: Any]
            } : []
        ] as [String: Any]
    }

    /// Adds the row's fields the action `activeTab` shows sets: WebKit overlays per-tab properties on the default.
    private func addActionFields(to payload: inout [String: Any], at index: Int, activeTab: TabExtensionAdapter?) {
        let runtime = loadedRuntimes[index]
        let action = runtime.context.action(for: activeTab)
        let tabColors = activeTab.flatMap { runtime.tabActionColors[$0.tabId] }
        payload["hasPopup"] = action?.presentsPopup ?? false
        payload["actionEnabled"] = action?.isEnabled ?? true
        payload["actionLabel"] = action?.label ?? ""
        payload["iconDataURL"] = cachedIconDataURL(for: action)
        payload["iconVersion"] = runtime.iconVersion
        payload["badgeText"] = action?.badgeText ?? ""
        payload["badgeColor"] = tabColors.map(\.badgeColor).flatMap { $0.isEmpty ? nil : $0 } ?? runtime.actionColors.badgeColor
        payload["badgeTextColor"] = tabColors.map(\.badgeTextColor).flatMap { $0.isEmpty ? nil : $0 } ?? runtime.actionColors.badgeTextColor
        payload["hostAccessRequest"] = access.showsHostAccessRequest(extensionId: runtime.id, context: runtime.context, on: activeTab)
    }

    /// The manifest's toolbar or extension icon nearest 32 px as a data URL, and the store page of a Web Store copy; each empty when absent.
    private func storedManifestFacts(for stored: ExtensionStorage.InstalledExtension) -> (iconDataURL: String, webStoreURL: String) {
        let key = "\(stored.id)@\(stored.version)"
        if let cached = storedManifestFacts[key] { return cached }
        let folder = URL(fileURLWithPath: stored.path)
        var dataURL = ""
        var webStoreURL = ""
        if let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
           let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let action = (manifest["action"] ?? manifest["browser_action"]) as? [String: Any]
            let icons = (action?["default_icon"] as? [String: String]) ?? (manifest["icons"] as? [String: String]) ?? [:]
            let sized = icons.compactMap { size, file in Int(size).map { ($0, file) } }
            let file = sized.min { abs($0.0 - 32) < abs($1.0 - 32) }?.1 ?? (action?["default_icon"] as? String)
            if let file, let png = try? Data(contentsOf: folder.appendingPathComponent(file)) {
                dataURL = "data:image/png;base64,\(png.base64EncodedString())"
            }
            if updater.isStoreCopy(id: stored.id, path: stored.path, manifest: manifest) {
                webStoreURL = "https://chromewebstore.google.com/detail/\(stored.id)"
            }
        }
        storedManifestFacts[key] = (dataURL, webStoreURL)
        return (dataURL, webStoreURL)
    }

    private func cachedIconDataURL(for action: WKWebExtension.Action?) -> String {
        let size = CGSize(width: 16, height: 16)
        guard let image = action?.icon(for: size) else { return "" }
        let appearance = NSApp.effectiveAppearance
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let key = IconCacheKey(image: ObjectIdentifier(image), appearance: appearance.name, scale: scale)
        if let cached = iconDataURLCache[key] { return cached.dataURL }
        // Drawn at the sharpest screen's scale: the image holds a representation per scale, and its TIFF all of them.
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return "" }
        // The context takes its scale from the rep's size when it is made: sized after, the icon fills one corner.
        rep.size = size
        guard let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return "" }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        appearance.performAsCurrentDrawingAppearance { image.draw(in: NSRect(origin: .zero, size: size)) }
        NSGraphicsContext.restoreGraphicsState()
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return "" }
        let dataURL = "data:image/png;base64,\(pngData.base64EncodedString())"
        if iconDataURLCacheKeys.count >= 128 {
            for evicted in iconDataURLCacheKeys.prefix(64) { iconDataURLCache.removeValue(forKey: evicted) }
            iconDataURLCacheKeys.removeFirst(64)
        }
        iconDataURLCache[key] = (image, dataURL)
        iconDataURLCacheKeys.append(key)
        return dataURL
    }

    // MARK: - Persistence

    private var restoring: Task<Void, Never>?
    /// Until a restore starts, the registry knows only the extensions loaded since it was built.
    var isRestored: Bool { restoring != nil }

    /// Runs once, for the first window to show the profile or the settings acting on it; a later call waits for that one.
    func restore() async {
        if restoring == nil {
            restoring = Task {
                await restoreStoredExtensions()
                StartupMetrics.markOnce("extensionsRestored")
                notifyExtensionsChanged()
                updater.start()
            }
        }
        await restoring?.value
    }

    /// The rows of every installed extension from storage alone, for a profile no window shows: listing it loads none.
    func storedBridgePayloads() async -> [[String: Any]] {
        let states = (try? await extensionStorage.loadAccessStates()) ?? [:]
        return ((try? await extensionStorage.loadAll()) ?? []).map { stored in
            let facts = storedManifestFacts(for: stored)
            return [
                "id": stored.id,
                "name": stored.name,
                "version": stored.version,
                "isEnabled": stored.isEnabled,
                "runtimeStatus": "loaded",
                "iconDataURL": facts.iconDataURL,
                "webStoreURL": facts.webStoreURL,
                "declinedUpdate": states[stored.id]?.declinedUpdateVersion ?? "",
                "allowsPrivateAccess": states[stored.id]?.allowsPrivateAccess == true,
                "allowsUserScripts": states[stored.id]?.allowsUserScripts == true
            ] as [String: Any]
        }
    }

    // MARK: - User scripts

    /// The per-extension "Allow user scripts" switch. Registrations are kept while it is off.
    func setUserScriptsAllowed(extensionId: String, allowed: Bool) async {
        await access.update(extensionId) { $0.allowsUserScripts = allowed ? true : nil }
        userScripts.reinstall(for: extensionId)
        extensionDidChange(extensionId)
        userScripts.publishSwitches()
        // The worker reads the switch from its prelude: rewrite it, then restart a running worker on it.
        guard let sourcePath = runtimeIndex(for: extensionId).map({ loadedRuntimes[$0].sourcePath }) else { return }
        _ = await Task.detached(priority: .userInitiated) {
            Self.prepareForWebKit(at: URL(fileURLWithPath: sourcePath, isDirectory: true), allowsUserScripts: allowed)
        }.value
        await backgrounds.restartIfRunning(extensionId)
    }

    /// Prepares and opens every enabled extension at once off the main actor, then loads them back to back in their stored
    /// order: WebKit fires `runtime.onStartup` only for contexts loaded shortly after the controller exists.
    private func restoreStoredExtensions() async {
        await access.restore()
        guard let storedExtensions = try? await extensionStorage.loadAll() else { return }
        disabledStoredExtensions = storedExtensions.filter { !$0.isEnabled }
        lifecycle.restoreDisabled(disabledStoredExtensions.map(\.id))
        let enabled = storedExtensions.filter { $0.isEnabled && !containsRuntime(extensionId: $0.id) }
        let allowsUserScripts = Set(access.states.compactMap { $0.value.allowsUserScripts == true ? $0.key : nil })
        userScripts.publishSwitches()

        let files = files
        let opened = await withTaskGroup(of: (Int, Result<(WKWebExtension, String, Bool), Error>).self) { group in
            for (index, stored) in enabled.enumerated() {
                let url = URL(fileURLWithPath: stored.path, isDirectory: true)
                let allowed = allowsUserScripts.contains(stored.id)
                group.addTask {
                    do {
                        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else {
                            throw ExtensionError.manifestNotFound(stored.path)
                        }
                        let sourceURL = try files.workingCopy(of: url)
                        let isDegraded = Self.prepareForWebKit(at: sourceURL, allowsUserScripts: allowed)
                        let signpost = PerfSignposts.extensions.beginInterval("createExtension", id: PerfSignposts.extensions.makeSignpostID(), "\(stored.id)")
                        let webExtension = try await WKWebExtension(resourceBaseURL: sourceURL)
                        PerfSignposts.extensions.endInterval("createExtension", signpost)
                        return (index, .success((webExtension, sourceURL.path, isDegraded)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var results = [Result<(WKWebExtension, String, Bool), Error>?](repeating: nil, count: enabled.count)
            for await (index, result) in group { results[index] = result }
            return results
        }

        for (stored, result) in zip(enabled, opened) {
            do {
                guard let result else { continue }
                let (webExtension, sourcePath, isDegraded) = try result.get()
                let signpost = PerfSignposts.extensions.beginInterval("activate", id: PerfSignposts.extensions.makeSignpostID(), "\(stored.id)")
                defer { PerfSignposts.extensions.endInterval("activate", signpost) }
                try await activate(
                    webExtension, id: stored.id, sourcePath: sourcePath, installPath: stored.path, isPreparationDegraded: isDegraded, stored: stored,
                    as: .startup
                )
            } catch {
                recordFailedRestore(stored, error: error)
            }
        }
        // Runtimes cover an extension installed while this restore ran, after `storedExtensions` was read.
        let keptPaths = storedExtensions.map(\.path) + loadedRuntimes.flatMap { [$0.installPath, $0.sourcePath] }
        files.sweep(keeping: Set(keptPaths.map { ($0 as NSString).lastPathComponent }))
    }

    private func recordFailedRestore(_ stored: ExtensionStorage.InstalledExtension, error: Error) {
        Self.logger.error("Failed to restore stored extension \(stored.id, privacy: .public): \(ExtensionDiagnostics.diagnosticDescription(for: error), privacy: .public)")
        failedRestores.append((stored, ExtensionDiagnostics.diagnosticDescription(for: error)))
    }

    /// Records the files an update installed for a disabled extension, and lists them.
    func storeDisabledRecord(id: String, name: String, version: String, path: String) async throws {
        try await extensionStorage.store(id: id, name: name, version: version, path: path, enabled: false)
        if let index = disabledStoredExtensions.firstIndex(where: { $0.id == id }),
           let stored = try await extensionStorage.load(id: id) {
            disabledStoredExtensions[index] = stored
            notifyExtensionsChanged()
        }
    }

    private func persistInstalledExtension(id: String, context: WKWebExtensionContext, installPath: String, enabled: Bool) async {
        let webExtension = context.webExtension
        try? await extensionStorage.store(
            id: id,
            name: webExtension.displayName ?? id,
            version: webExtension.version ?? "",
            path: installPath,
            enabled: enabled
        )
    }

    private func removePersistedExtension(extensionId: String) async {
        try? await extensionStorage.delete(id: extensionId)
        access.uninstalled(extensionId)
    }

    /// Clears the extension's `chrome.storage` (keyed by its unique identifier), loaded or not.
    private func removeExtensionData(extensionId: String) async {
        let allTypes: Set<WKWebExtension.DataType> = [.local, .session, .synchronized]
        let matching = await controller.dataRecords(ofTypes: allTypes).filter { $0.uniqueIdentifier == extensionId }
        if !matching.isEmpty { await controller.removeData(ofTypes: allTypes, from: matching) }
    }

    /// Deferred so the dying worker releases its files first. A quit before it runs leaves an
    /// unreferenced folder that the next restore sweeps.
    private func scheduleUninstallFileCleanup(extensionId: String, installPath: String) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !self.containsRuntime(extensionId: extensionId), !self.containsRuntimeInstallPath(installPath) else { return }
            self.files.remove(installPath)
        }
    }

    // MARK: - Helpers

    /// Only a thrown error means the extension cannot run; `.skipped` is knowingly unprepared. `allowsUserScripts` is baked into
    /// the prelude: `chrome.userScripts` throws at once when off, and a worker has no synchronous way to ask.
    nonisolated static func prepareBackgroundServiceWorkerForWKIfNeeded(
        at extensionURL: URL,
        allowsUserScripts: Bool
    ) throws -> ExtensionBackgroundPreparer.PreparationResult {
        guard let preludeSource = backgroundPreludeSource else {
            Self.logger.warning("ChromeAPIBackgroundPrelude.js not found in bundle; background compatibility prelude will be skipped")
            return .notNeeded
        }
        // Content scripts run in WebKit's isolated world, which the page-world augmentation never reaches.
        if contentCompatSource == nil {
            Self.logger.warning("ChromeContentCompat.js not found in bundle; content-script compat will be skipped")
        }
        return try ExtensionBackgroundPreparer.prepare(
            extensionURL: extensionURL,
            preludeSource: "globalThis.__liloUserScriptsAllowed = \(allowsUserScripts);\n" + preludeSource,
            compatSource: contentCompatSource
        )
    }

    /// Read once: preparation runs per extension on every launch and every background reload.
    private nonisolated static let backgroundPreludeSource: String? = Bundle.appResourceURL("ChromeAPIBackgroundPrelude", extension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    private nonisolated static let contentCompatSource: String? = Bundle.appResourceURL("ChromeContentCompat", extension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    // MARK: - Context Observation

    /// Observes one context's notifications: errors (logged, and a background that failed to load is
    /// revived) and permission changes (optional grants are persisted).
    private func makeContextObserver(for context: WKWebExtensionContext, extensionId: String) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: nil, object: context, queue: .main) { [weak self, weak context] notification in
            let name = notification.name
            MainActor.assumeIsolated {
                guard let self, let context, self.context(for: extensionId) === context else { return }
                switch name {
                case WKWebExtensionContext.errorsDidUpdateNotification:
                    self.backgrounds.contextErrorsChanged(extensionId)
                case WKWebExtensionContext.permissionsWereGrantedNotification,
                     WKWebExtensionContext.grantedPermissionsWereRemovedNotification,
                     WKWebExtensionContext.permissionMatchPatternsWereGrantedNotification,
                     WKWebExtensionContext.grantedPermissionMatchPatternsWereRemovedNotification:
                    self.access.recordOptionalGrants(for: extensionId)
                default:
                    break
                }
            }
        }
    }
}
