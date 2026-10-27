import CryptoKit
import Foundation
import WebKit
import os

@MainActor
final class WKEngineFactory {
    private nonisolated static let logger = Logger(liloCategory: "engine-factory")

    struct Configuration {
        var dataStore: WKEngineDataStore?
        var tabId: UUID?
        var nativeConfiguration: WKWebViewConfiguration?
        /// Profile whose extension controller the web view binds to; nil runs no extension.
        var profileId: UUID?
        /// False for a restored tab coming back: only a tab the user opens predicts another, so only it
        /// refills the warm pool, and a launch spawns no speculative process.
        var refillsWarmPool = true
    }

    private struct ContentControllerKey: Hashable {
        let dataStoreKey: String
        let isPrivate: Bool
    }

    /// A web view binds its extension controller at creation, so a warm view serves its profile only.
    private struct WarmKey: Hashable {
        let content: ContentControllerKey
        let profileId: UUID?
    }

    private lazy var sharedDefaultDataStore = WKEngineDataStore(
        backingStore: applyingTrackingPrevention(to: .default()),
        identifier: "persistent:default"
    )
    /// WebKit's tracking prevention (ITP, resource load statistics), set from the user's setting at
    /// bootstrap. Off, third-party cookies are accepted as in Chrome.
    private var trackingPreventionEnabled = false
    /// Every website data store handed out, so a tracking prevention change reaches all of them.
    private let websiteDataStores = NSHashTable<WKWebsiteDataStore>.weakObjects()

    private var contentControllersByKey: [ContentControllerKey: WKUserContentController] = [:]
    /// Every content controller handed out, cached or since dropped from the cache: a web view keeps
    /// its controller for life, so rule-list and filter-script changes must reach all of them.
    private let liveContentControllers = NSHashTable<WKUserContentController>.weakObjects()
    /// The profile and privacy of each live controller's tabs, for that profile's extension user scripts.
    private final class ContentControllerOwner {
        let profileId: UUID
        let isPrivate: Bool
        init(profileId: UUID, isPrivate: Bool) {
            self.profileId = profileId
            self.isPrivate = isPrivate
        }
    }
    private let contentControllerOwners = NSMapTable<WKUserContentController, ContentControllerOwner>.weakToStrongObjects()
    /// One slot per store kind: with a single shared slot, alternating normal and private tabs would
    /// always miss and waste a speculative build each time.
    private var warmWebViewsByKey: [WarmKey: WKWebView] = [:]
    /// Insertion order of `warmWebViewsByKey` keys (oldest first) for eviction.
    private var warmKeyOrder: [WarmKey] = []
    private static let warmPoolCapacity = 2

    weak var downloadManager: DownloadManager?
    /// Per-profile stores and extension controllers; owned by BrowserContext.
    weak var profileContexts: ProfileContextCache?
    /// Set by MainWindowController so the handler reaches the live TabManager and the sidebar's own
    /// state-mutation path.
    var tabGroupsContextProvider: ((ProfileExtensionRegistry?) -> TabGroupsContext?)?
    /// Set by MainWindowController so chrome.sessions reaches the recently-closed-tab stack.
    var sessionsContextProvider: ((ProfileExtensionRegistry?) -> SessionsContext?)?
    var geolocationPermissionDecisionHandler: GeolocationBridge.PermissionDecisionHandler? {
        didSet { geolocationBridge.permissionDecisionHandler = geolocationPermissionDecisionHandler }
    }
    var notificationPermissionDecisionHandler: NotificationBridge.PermissionDecisionHandler? {
        didSet { notificationBridge.permissionDecisionHandler = notificationPermissionDecisionHandler }
    }
    /// Returns true if the origin already has an "allow" decision for notifications; gates delivery.
    var notificationAllowanceHandler: ((String) -> Bool)? {
        didSet { notificationBridge.allowanceHandler = notificationAllowanceHandler }
    }
    /// Told of each notification a page posts. Set by MainWindowController.
    var notificationShownHandler: ((WKWebView) -> Void)? {
        didSet { notificationBridge.shownHandler = notificationShownHandler }
    }
    /// Reports form-dirty state changes (webView, isDirty) to the window controller. Set by MainWindowController.
    var formDirtyHandler: ((WKWebView, Bool) -> Void)? {
        didSet { formDirtyBridge.onChange = formDirtyHandler }
    }
    /// Reports a page's Media Session call controls to the window controller. Set by MainWindowController.
    var callControlsHandler: ((WKWebView, WKWebViewTab.CallControls) -> Void)? {
        didSet { callControlsBridge.onChange = callControlsHandler }
    }

    /// The compiled filter rules, split in parts when they exceed what one list may hold.
    private var contentRuleLists: [WKContentRuleList] = []
    private var contentBlockerEnabled = true
    /// Bumped by each compile request; a compile that finishes behind a newer one drops its result.
    private var blockerGeneration = 0
    /// Converted remote filter rules (EasyList) from `FilterListService`, replacing the bundled list; `tag` keys the compiled cache.
    /// Held only until the next compile succeeds (the JSON runs to several MB); a later miss re-reads the service's cache file.
    private var externalFilterRulesJSON: String?
    /// Outlives the released JSON: later rebuilds (allowlist edits) must keep compiling the external set.
    private var externalFilterRulesTag = "bundled"
    /// Bundle JS templates are immutable; memoized so rescript passes stop re-reading them from disk.
    private var templateSourceByResource: [String: String] = [:]
    /// Identifies the filter scripts last applied: their multi-MB sources live in `filterUserScripts` only.
    private var filterScriptsHash = FilterScripts().hashValue
    /// The filter scripts with the allowlist spliced in, and the world each runs in.
    private var filterUserScripts: [(script: WKUserScript, world: WKContentWorld)] = []
    /// The filter scripts installed on every live controller (none while the blocker is off), one shared set. A change removes
    /// exactly these, so the rest of a controller's scripts (extension content scripts included) stays put.
    private var installedFilterUserScripts: [WKUserScript] = []
    /// Hosts the blocker stands down for; spliced into the filter scripts, which stand down too.
    private var blockerAllowlist: [String] = []
    /// Read per navigation by every live tab, so a change applies to open tabs without a reload.
    private(set) static var httpsOnlyEnabled = false
    /// Smallest font size pages render with, in points; 0 leaves page fonts alone.
    private(set) static var minimumFontSize: CGFloat = 0
    private(set) static var globalPrivacyControlEnabled = true
    /// Media that waits for a click before it plays; a web view keeps what it was built with.
    private(set) static var autoplayRestriction: WKAudiovisualMediaTypes = .audio
    /// WebKit feature-flag overrides applied to every new web view (the `about:config` page).
    private var featureFlagOverrides: [String: Bool] = [:]

    private lazy var geolocationBridge: GeolocationBridge = {
        let bridge = GeolocationBridge()
        bridge.permissionDecisionHandler = geolocationPermissionDecisionHandler
        return bridge
    }()

    private lazy var notificationBridge: NotificationBridge = {
        let bridge = NotificationBridge()
        bridge.permissionDecisionHandler = notificationPermissionDecisionHandler
        bridge.allowanceHandler = notificationAllowanceHandler
        bridge.shownHandler = notificationShownHandler
        bridge.tabIdResolver = { [weak self] in self?.tabIdByWebView.object(forKey: $0) as UUID? }
        return bridge
    }()

    private let tabIdByWebView = NSMapTable<WKWebView, NSUUID>.weakToStrongObjects()

    private let serialBridge = SerialBridge()
    private let eyeDropperBridge = EyeDropperBridge()

    func dispatchWebNotificationClick(identifier: String) {
        notificationBridge.dispatchClick(identifier: identifier)
    }

    /// Forwarded by the window controller whenever the visible engine view changes, so paused
    /// `watchPosition()` callers resume (and hidden ones release the GPS).
    func reevaluateGeolocationWatchers() {
        geolocationBridge.reevaluateWatchers()
    }

    private lazy var formDirtyBridge: FormDirtyBridge = {
        let bridge = FormDirtyBridge()
        bridge.onChange = formDirtyHandler
        return bridge
    }()

    private lazy var callControlsBridge: CallControlsBridge = {
        let bridge = CallControlsBridge()
        bridge.onChange = callControlsHandler
        return bridge
    }()

    /// getDisplayMedia tab-share surface; the window controller wires its picker and ferry.
    let tabShareBridge = TabShareBridge()

    /// Serves ferry frames to pages over lilo-capture://; the window controller wires its provider.
    let tabShareFrameSchemeHandler = TabShareFrameSchemeHandler()
    /// chrome.tabCapture and chrome.desktopCapture; `BrowserContext` wires its picker and ferry.
    let captureHandler = CaptureBridgeHandler()
    let viewSourceSchemeHandler = ViewSourceSchemeHandler()

    /// A web view's profile registry, from the profile id its extension controller was configured with,
    /// which survives a rebuild of the profile's context. Gap calls authenticate against it, and
    /// data-mutating handlers fire chrome.* events back through it.
    private func resolveRegistry(for webView: WKWebView?) -> ProfileExtensionRegistry? {
        guard let webView else { return nil }
        let profileId: UUID
        if let cached = profileIdByWebView.object(forKey: webView) {
            profileId = cached as UUID
        } else {
            // `configuration` hands out a copy: read it once per web view, whose profile never changes.
            guard let id = webView.configuration.webExtensionController?.configuration.identifier else { return nil }
            profileIdByWebView.setObject(id as NSUUID, forKey: webView)
            profileId = id
        }
        return profileContexts?.existingContext(for: profileId)?.extensions
    }

    private let profileIdByWebView = NSMapTable<WKWebView, NSUUID>.weakToStrongObjects()

    private func profileContext(for registry: ProfileExtensionRegistry) -> ProfileContext? {
        profileContexts?.existingContext(for: registry.profileId)
    }

    private(set) lazy var sidePanelHandler = SidePanelBridgeHandler()
    private(set) lazy var tabGroupsHandler = TabGroupsBridgeHandler(contextProvider: { [weak self] in self?.tabGroupsContextProvider?($0) })
    private lazy var proxyHandler = ProxyBridgeHandler(settingsProvider: { [weak self] in self?.profileContext(for: $0)?.extensionSettings })

    /// A page that could not reach the extension's proxy fires chrome.proxy.onProxyError.
    func reportProxyFailure(_ error: Error, registry: ProfileExtensionRegistry) {
        proxyHandler.reportNavigationFailure(error, registry: registry)
    }

    /// A proxy's challenge to a tab's load goes to webRequest.onAuthRequired; nil when no extension answers it.
    func authenticateProxy(
        _ challenge: URLAuthenticationChallenge, url: URL?, tab: TabExtensionAdapter?, registry: ProfileExtensionRegistry,
        completion: @escaping @MainActor (_ answer: (URLSession.AuthChallengeDisposition, URLCredential?)?) -> Void
    ) {
        proxyHandler.authenticate(challenge, url: url, tab: tab, registry: registry, completion: completion)
    }

    lazy var contentSettingsHandler = ContentSettingsBridgeHandler(settingsProvider: { [weak self] in self?.profileContext(for: $0)?.extensionSettings })
    private lazy var fontSettingsHandler: FontSettingsBridgeHandler = {
        let handler = FontSettingsBridgeHandler(settingsProvider: { [weak self] in self?.profileContext(for: $0)?.extensionSettings })
        handler.onOverridesChanged = { [weak self] in self?.applyFontOverrides(of: $0) }
        return handler
    }()
    private lazy var userScriptsHandler = UserScriptsBridgeHandler(registryResolver: { [weak self] in self?.resolveRegistry(for: $0) })

    /// Wires a freshly built profile registry to the gap handlers that act before any gap call, and
    /// its extensions' user scripts to the content controllers of the profile's tabs.
    func prepareExtensionRegistry(_ registry: ProfileExtensionRegistry) {
        sidePanelHandler.installActionClickOpener(on: registry)
        let profileId = registry.profileId
        registry.userScripts.onChange = { [weak self] removed, added, install in
            guard let self else { return }
            let removeSelector = NSSelectorFromString("_removeUserScript:")
            for controller in self.liveContentControllers.allObjects {
                guard let owner = self.contentControllerOwners.object(forKey: controller), owner.profileId == profileId else { continue }
                if controller.responds(to: removeSelector) {
                    removed.forEach { _ = controller.perform(removeSelector, with: $0) }
                }
                if let install { self.installExtensionUserScripts(added, of: install, on: controller, isPrivate: owner.isPrivate) }
            }
        }
    }

    /// Private spaces get an extension's user scripts only when it may run there.
    private func installExtensionUserScripts(_ scripts: [WKUserScript], of install: ExtensionUserScripts.Install, on controller: WKUserContentController, isPrivate: Bool) {
        guard !isPrivate || install.allowsPrivateAccess else { return }
        scripts.forEach { controller.addUserScript($0) }
        // Adding a handler name twice to one world raises; a reinstall may meet one already there.
        for world in install.messagingWorlds {
            controller.removeScriptMessageHandler(forName: UserScriptsBridgeHandler.messageHandlerName, contentWorld: world)
            controller.addScriptMessageHandler(userScriptsHandler, contentWorld: world, name: UserScriptsBridgeHandler.messageHandlerName)
        }
    }

    /// Answers the gap calls every profile's extension pages and workers send over their channel.
    lazy var gapRouter: GapBridgeRouter = {
        let router = GapBridgeRouter()
        let allRegistries: () -> [ProfileExtensionRegistry] = { [weak self] in self?.profileContexts?.allContexts.map(\.extensions) ?? [] }

        // Gap APIs: WK does not implement these. The router hands each handler the caller's own
        // registry, and stores are resolved from it, so every call reaches its extension's profile.
        router.register(handler: BookmarksBridgeHandler(storeProvider: { [weak self] in self?.profileContext(for: $0)?.bookmarks }))
        router.register(handler: HistoryBridgeHandler(storeProvider: { [weak self] in self?.profileContext(for: $0)?.history }))
        router.register(handler: IdleBridgeHandler(registriesProvider: allRegistries))
        router.register(handler: IdentityBridgeHandler())
        router.register(handler: DownloadsBridgeHandler(
            managerProvider: { [weak self] in self?.downloadManager },
            storeProvider: { [weak self] in self?.profileContext(for: $0)?.downloads }
        ))
        router.register(handler: NotificationsBridgeHandler())
        router.register(handler: TopSitesBridgeHandler(storeProvider: { [weak self] in self?.profileContext(for: $0)?.history }))
        router.register(handler: SessionsBridgeHandler(contextProvider: { [weak self] in self?.sessionsContextProvider?($0) }))
        router.register(handler: CommandsBridgeHandler())
        router.register(handler: ManagementBridgeHandler())
        router.register(handler: RuntimeBridgeHandler())
        router.register(handler: PermissionsBridgeHandler())
        router.register(handler: CookiesBridgeHandler())
        router.register(handler: ActionColorBridgeHandler())
        router.register(handler: sidePanelHandler)
        router.register(handler: OffscreenBridgeHandler())
        router.register(handler: WebSocketBridgeHandler())
        router.register(handler: CredentialedFetchBridgeHandler())
        router.register(handler: captureHandler)
        router.register(handler: userScriptsHandler)
        router.register(handler: SearchQueryBridgeHandler())
        router.register(handler: DeclarativeNetRequestBridgeHandler())
        router.register(handler: I18nBridgeHandler())
        router.register(handler: tabGroupsHandler)
        router.register(handler: BrowsingDataBridgeHandler(contextProvider: { [weak self] in self?.profileContext(for: $0) }, downloadManagerProvider: { [weak self] in self?.downloadManager }))
        router.register(handler: contentSettingsHandler)
        router.register(handler: fontSettingsHandler)
        router.register(handler: proxyHandler)
        router.register(handler: PowerBridgeHandler())
        router.register(handler: SystemBridgeHandler(registriesProvider: allRegistries))
        router.register(handler: TtsBridgeHandler(registriesProvider: allRegistries))
        router.register(handler: TabsBridgeHandler(contextProvider: { [weak self] in self?.tabGroupsContextProvider?($0) }))
        router.register(handler: DebuggerBridgeHandler.shared)
        router.register(handler: PageCaptureBridgeHandler())
        router.register(handler: InstanceIDBridgeHandler(settingsProvider: { [weak self] in self?.profileContext(for: $0)?.extensionSettings }))
        // Registered with the router, before any window: a worker may set its default suggestion at
        // startup. Each window adds its own address-bar handler to the relay.
        router.register(handler: OmniboxGapRelay.shared)
        // Its chrome UI actions (install, uninstall) stay off the extension-facing bridge.
        router.register(handler: ExtensionUIBridgeHandler())

        return router
    }()

    /// Origin-locked transport for the store's `chrome.webstorePrivate` shim. Separate from the
    /// hardened gap router (the store is an https origin with no extension identity).
    private lazy var webstoreInstallHandler: WebstoreInstallHandler = {
        WebstoreInstallHandler(
            registryProvider: { [weak self] in self?.resolveRegistry(for: $0) },
            confirmInstall: { review in review.confirmInstall() }
        )
    }()

    /// Adaptive background color shown before page content renders (avoids white flash in dark mode).
    private static let underPageBackgroundColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 30 / 255, green: 30 / 255, blue: 46 / 255, alpha: 1)  // #1e1e2e
            : .white
    }

    func createTab(configuration: Configuration) -> WKWebViewTab {
        let webView: WKWebView
        if configuration.nativeConfiguration != nil {
            webView = WKWebView(frame: .zero, configuration: configuredWebViewConfiguration(from: configuration, usesNativeConfiguration: true))
        } else {
            let store = configuration.dataStore ?? sharedDefaultDataStore
            let poolKey = WarmKey(content: contentControllerKey(for: store), profileId: configuration.profileId)
            // Consult the warm pool first: a hit skips the config + feature-flag pass entirely.
            webView = takeWarm(key: poolKey)
                ?? WKWebView(frame: .zero, configuration: configuredWebViewConfiguration(from: configuration, usesNativeConfiguration: false))
            if configuration.refillsWarmPool { scheduleWarmRefill(dataStore: store, key: poolKey) }
        }

        let tabId = configuration.tabId ?? UUID()
        tabIdByWebView.setObject(tabId as NSUUID, forKey: webView)
        let tab = WKWebViewTab(id: tabId, webView: webView)
        tab.applyPageBackgroundColor(Self.underPageBackgroundColor)
        return tab
    }

    func createDataStore(persistent: Bool, identifier: String?) -> WKEngineDataStore {
        if persistent, let identifier {
            // Identifiers are profile UUIDs, so a non-UUID means corruption. A random substitute UUID
            // would open a brand-new empty store (the user sees all logins gone); the default store at
            // least surfaces the default profile's data.
            guard let uuid = UUID(uuidString: identifier) else {
                assertionFailure("Non-UUID data store identifier: \(identifier)")
                Self.logger.fault("Non-UUID data store identifier \(identifier, privacy: .public); using the default persistent store")
                return sharedDefaultDataStore
            }
            let store = applyingTrackingPrevention(to: WKWebsiteDataStore(forIdentifier: uuid))
            return WKEngineDataStore(backingStore: store, identifier: "persistent:\(identifier)")
        } else if persistent {
            return sharedDefaultDataStore
        } else {
            let store = applyingTrackingPrevention(to: .nonPersistent())
            return WKEngineDataStore(backingStore: store, identifier: "ephemeral:\(identifier ?? UUID().uuidString)")
        }
    }

    func defaultDataStore() -> WKEngineDataStore { sharedDefaultDataStore }

    @discardableResult
    private func applyingTrackingPrevention(to store: WKWebsiteDataStore) -> WKWebsiteDataStore {
        websiteDataStores.add(store)
        if store.responds(to: NSSelectorFromString("_setResourceLoadStatisticsEnabled:")) {
            store.setValue(trackingPreventionEnabled, forKey: "resourceLoadStatisticsEnabled")
        }
        // Without tracking prevention WebKit refuses every cookie an embedded site sets, partitioned
        // ones too, which breaks frames that sign in with them (claude.ai artifacts).
        let setPolicy = NSSelectorFromString("_setCookieAcceptPolicy:completionHandler:")
        let cookieStore = store.httpCookieStore
        if cookieStore.responds(to: setPolicy) {
            typealias SetPolicy = @convention(c) (AnyObject, Selector, UInt, @escaping @convention(block) () -> Void) -> Void
            let policy: HTTPCookie.AcceptPolicy = trackingPreventionEnabled ? .onlyFromMainDocumentDomain : .always
            unsafeBitCast(cookieStore.method(for: setPolicy), to: SetPolicy.self)(cookieStore, setPolicy, policy.rawValue) {}
        }
        return store
    }

    /// Applies to every live store. Turning it off first clears the statistics WebKit gathered (the
    /// domains it classified as trackers), never the sites' own data.
    func setTrackingPrevention(_ enabled: Bool) {
        let clearsStatistics = trackingPreventionEnabled && !enabled
        trackingPreventionEnabled = enabled
        let clear = NSSelectorFromString("_clearResourceLoadStatistics:")
        for store in websiteDataStores.allObjects {
            guard clearsStatistics, store.responds(to: clear) else {
                applyingTrackingPrevention(to: store)
                continue
            }
            // Turned off once cleared: with tracking prevention off, WebKit ignores the clear.
            let cleared: @convention(block) () -> Void = { [weak self, weak store] in
                guard let self, let store else { return }
                applyingTrackingPrevention(to: store)
            }
            store.perform(clear, with: cleared)
        }
    }

    /// A shared pool keeping a spare WebContent process launched, so cross-site navigations and new views skip the spawn (the default
    /// pool has it off, fixed at creation). Looked up by name since WKProcessPool is deprecated; nil when the SPI is missing.
    private static let contentProcessPool: NSObject? = {
        guard let poolClass: AnyObject = NSClassFromString("WKProcessPool") else { return nil }
        let selector = NSSelectorFromString("_processPoolWithConfiguration:")
        guard poolClass.responds(to: selector),
              let configurationClass = NSClassFromString("_WKProcessPoolConfiguration") as? NSObject.Type
        else { return nil }
        let configuration = configurationClass.init()
        guard configuration.responds(to: NSSelectorFromString("setPrewarmsProcessesAutomatically:")) else { return nil }
        configuration.setValue(true, forKey: "prewarmsProcessesAutomatically")
        return poolClass.perform(selector, with: configuration)?.takeUnretainedValue() as? NSObject
    }()

    /// Removes `old` and adds `new` across every live content controller.
    private func swapRuleLists(old: [WKContentRuleList], new: [WKContentRuleList]) {
        liveContentControllers.allObjects.forEach { c in
            old.forEach(c.remove)
            new.forEach(c.add)
        }
    }

    /// The rule list and the filter scripts swap on every live controller; open pages pick the
    /// scripts up on their next load.
    func applyBlockerChange(enabled: Bool) {
        contentBlockerEnabled = enabled
        swapRuleLists(old: enabled ? [] : contentRuleLists, new: enabled ? contentRuleLists : [])
        reinstallFilterUserScripts()
    }

    /// Applies to web views built afterwards; the warm view is discarded. WebKit binds preferences at
    /// web-view creation, so existing tabs keep theirs until reloaded.
    func setFeatureFlagOverrides(_ overrides: [String: Bool]) {
        guard overrides != featureFlagOverrides else { return }
        featureFlagOverrides = overrides
        dropWarmPool()
    }

    /// The warm pool goes; live tabs pick it up on their next navigation (see the navigation policy).
    func setGlobalPrivacyControl(_ enabled: Bool) {
        guard Self.globalPrivacyControlEnabled != enabled else { return }
        Self.globalPrivacyControlEnabled = enabled
        dropWarmPool()
    }

    /// Drops the warm pool so the next tab is built with the new size, and applies it to every live
    /// tab whose profile has no extension override.
    func setMinimumFontSize(_ size: CGFloat) {
        guard Self.minimumFontSize != size else { return }
        Self.minimumFontSize = size
        dropWarmPool()
        // A profile whose extension sets the minimum keeps it; the others announce the change.
        profileContexts?.allContexts.forEach { fontSettingsHandler.refresh($0.extensions) }
        tabIdByWebView.keyEnumerator().allObjects.compactMap { $0 as? WKWebView }.forEach { webView in
            let registry = profileId(of: webView).flatMap { profileContexts?.existingContext(for: $0)?.extensions }
            webView.configuration.preferences.minimumFontSize = registry.flatMap { fontSettingsHandler.overrides(for: $0).minimumSize }.map { CGFloat($0) } ?? size
        }
    }

    private func profileId(of webView: WKWebView) -> UUID? {
        contentControllerOwners.object(forKey: webView.configuration.userContentController)?.profileId
    }

    /// chrome.fontSettings reaches the profile's open pages at once and its next ones through the
    /// configuration.
    private func applyFontOverrides(of registry: ProfileExtensionRegistry) {
        dropWarmPool()
        let overrides = fontSettingsHandler.overrides(for: registry)
        for case let webView as WKWebView in tabIdByWebView.keyEnumerator().allObjects where profileId(of: webView) == registry.profileId {
            Self.apply(overrides, to: webView.configuration.preferences)
        }
    }

    private static func apply(_ fonts: FontSettingsBridgeHandler.Overrides, to preferences: WKPreferences) {
        preferences.minimumFontSize = fonts.minimumSize.map { CGFloat($0) } ?? minimumFontSize
        // WKPreferencesPrivate setters, WebKit's defaults when no extension sets them.
        let values: [(key: String, value: Any)] = [
            ("standardFontFamily", fonts.standardFamily ?? "Times"), ("fixedPitchFontFamily", fonts.fixedFamily ?? "Courier"),
            ("defaultFontSize", fonts.defaultSize ?? 16), ("defaultFixedPitchFontSize", fonts.defaultFixedSize ?? 13)
        ]
        for (key, value) in values where preferences.responds(to: NSSelectorFromString("_set\(key.prefix(1).uppercased())\(key.dropFirst()):")) {
            preferences.setValue(value, forKey: key)
        }
    }

    /// "audio" (the default: no sound without a click), "all" or "none". Drops the warm pool so
    /// the next tab is built with the new policy.
    func setAutoplayPolicy(_ policy: String) {
        let restriction: WKAudiovisualMediaTypes = policy == "all" ? .all : policy == "none" ? [] : .audio
        guard Self.autoplayRestriction != restriction else { return }
        Self.autoplayRestriction = restriction
        dropWarmPool()
    }

    func setHTTPSOnly(_ enabled: Bool) {
        guard Self.httpsOnlyEnabled != enabled else { return }
        Self.httpsOnlyEnabled = enabled
        dropWarmPool()
    }

    /// First 8 bytes of SHA-256 as hex: a process-stable cache tag (unlike `hashValue`, which is
    /// per-launch randomized and would force a full recompile on every launch).
    nonisolated static func stableHash8(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Ready-to-inject filter user scripts, each nil when its table is absent or empty.
    struct FilterScripts: Hashable, Sendable {
        var genericCosmetics: String?
        var procedural: String?
        var scriptlets: String?
    }

    /// Splices each table into its bundled template as a string literal (far cheaper for JSC than an
    /// object literal). Reads templates and re-encodes a few hundred KB of per-host JSON, so callers run
    /// it off the main actor.
    nonisolated static func makeFilterScripts(cosmetic: String?, sites: String?, scriptlets: String?, procedural: String?) -> FilterScripts {
        func splice(_ values: [String: String]?, into resource: String) -> String? {
            guard let values else { return nil }
            guard let url = Bundle.appResourceURL(resource, extension: "js"),
                  var source = try? String(contentsOf: url, encoding: .utf8) else {
                Self.logger.error("\(resource, privacy: .public).js not found in bundle - injection disabled")
                return nil
            }
            for (placeholder, value) in values {
                source = source.replacingOccurrences(of: placeholder, with: Self.jsStringLiteral(value))
            }
            return source
        }
        // A keyed table spliced as __LILO_<name>_INDEX__, _GROUPS__, _TABLE__ and, for scriptlets, _NAMES__; empty when absent.
        func hostTable(_ json: String?, name: String) -> [String: String]? {
            json.flatMap(Self.hostTable(for:)).map {
                var values = ["__LILO_\(name)_INDEX__": $0.index, "__LILO_\(name)_GROUPS__": $0.groups, "__LILO_\(name)_TABLE__": $0.entries]
                if !$0.names.isEmpty { values["__LILO_\(name)_NAMES__"] = $0.names }
                return values
            }
        }
        // The generic and per-site cosmetics share one script; either table may be missing.
        let generic = cosmetic.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        func json(_ key: String) -> String? {
            (generic?[key] as? [String: [String]]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .flatMap { String(data: $0, encoding: .utf8) }
        }
        // Complex selectors keyed by `.class` or `#id`: buckets tell a token has some, the table lists them.
        let keyedKeys = (generic?["keyed"] as? [String: [String]])?.keys ?? [:].keys
        var cosmeticValues = [
            "__LILO_COSMETIC_CLASSES__": tokenBuckets(generic?["classes"] as? String ?? ""),
            "__LILO_COSMETIC_IDS__": tokenBuckets(generic?["ids"] as? String ?? ""),
            "__LILO_KEYED_CLASSES__": tokenBuckets(keyedKeys.filter { $0.hasPrefix(".") }.map { String($0.dropFirst()) }.joined(separator: " ")),
            "__LILO_KEYED_IDS__": tokenBuckets(keyedKeys.filter { $0.hasPrefix("#") }.map { String($0.dropFirst()) }.joined(separator: " "))
        ]
        for name in ["SITE", "LINK", "KEYED"] {
            for part in ["INDEX", "GROUPS", "TABLE"] { cosmeticValues["__LILO_\(name)_\(part)__"] = "" }
        }
        let siteTable = hostTable(sites, name: "SITE")
        let linkTable = hostTable(json("links"), name: "LINK")
        let keyedTable = hostTable(json("keyed"), name: "KEYED")
        for table in [siteTable, linkTable, keyedTable] { cosmeticValues.merge(table ?? [:]) { $1 } }
        let hasGeneric = !(cosmeticValues["__LILO_COSMETIC_CLASSES__"]!.isEmpty && cosmeticValues["__LILO_COSMETIC_IDS__"]!.isEmpty)
        let cosmetics = hasGeneric || siteTable != nil || linkTable != nil || keyedTable != nil ? cosmeticValues : nil
        return FilterScripts(
            genericCosmetics: splice(cosmetics, into: "GenericCosmetics"),
            procedural: splice(hostTable(procedural, name: "PROCEDURAL"),
                               into: "ProceduralCosmetics"),
            scriptlets: splice(hostTable(scriptlets, name: "SCRIPTLET"),
                               into: "Scriptlets")
        )
    }

    /// `rulesTag` (nil = bundled) keys the compiled cache; with nil `rules` a miss reads `FilterListService.cacheURL`. A script change
    /// rescripts live controllers once, so warm views survive with fresh tables; tabs pick new scripts up on their next navigation.
    func setFilterTables(rulesTag: String?, rules: String?, scripts: FilterScripts) {
        externalFilterRulesJSON = rulesTag == nil ? nil : rules
        externalFilterRulesTag = rulesTag.map { "ext-\($0)" } ?? "bundled"

        let hash = scripts.hashValue
        guard hash != filterScriptsHash else { return }
        filterScriptsHash = hash
        // Cosmetics are main frame only: the network rule list already catches subframe ads, and the
        // ~100 KB procedural table would otherwise be parsed again in every iframe. An isolated world
        // keeps the injected <style> clear of the page's CSP.
        let sources: [(String?, Bool, WKContentWorld)] = [
            (scripts.genericCosmetics, true, .defaultClient), (scripts.procedural, true, .page), (scripts.scriptlets, false, .page)
        ]
        let allowlist = Self.allowlistLiteral(blockerAllowlist)
        filterUserScripts = sources.compactMap { source, mainFrameOnly, world in
            source.map { (WKUserScript(source: Self.splicingAllowlist($0, replacing: "__LILO_ALLOWLIST__", with: allowlist),
                                       injectionTime: .atDocumentStart, forMainFrameOnly: mainFrameOnly, in: world), world) }
        }
        reinstallFilterUserScripts()
    }

    /// Swaps the filter scripts on every live controller. `removeAllUserScripts` would also drop the
    /// content scripts WebKit installed there for extensions, which it never re-adds to a controller
    /// it already knows; it is only the fallback should the SPI go away.
    private func reinstallFilterUserScripts() {
        let previous = installedFilterUserScripts
        installedFilterUserScripts = contentBlockerEnabled ? filterUserScripts.map(\.script) : []
        let removeSelector = NSSelectorFromString("_removeUserScript:")
        for controller in liveContentControllers.allObjects {
            if controller.responds(to: removeSelector) {
                previous.forEach { _ = controller.perform(removeSelector, with: $0) }
                installedFilterUserScripts.forEach { controller.addUserScript($0) }
            } else {
                controller.removeAllUserScripts()
                installUserScripts(on: controller)
            }
        }
    }

    /// The scripts' allowlist is re-spliced into their installed sources, the only copy kept of them.
    private func setBlockerAllowlist(_ allowlist: [String]) {
        guard allowlist != blockerAllowlist else { return }
        let old = Self.allowlistLiteral(blockerAllowlist)
        blockerAllowlist = allowlist
        let new = Self.allowlistLiteral(allowlist)
        filterUserScripts = filterUserScripts.map { script, world in
            (WKUserScript(source: Self.splicingAllowlist(script.source, replacing: old, with: new), injectionTime: .atDocumentStart,
                          forMainFrameOnly: script.isForMainFrameOnly, in: world), world)
        }
        reinstallFilterUserScripts()
    }

    nonisolated private static func allowlistLiteral(_ sites: [String]) -> String {
        jsStringLiteral("|" + sites.joined(separator: "|") + "|")
    }

    /// Every template opens with `var ALLOWLIST = __LILO_ALLOWLIST__;`: no need to scan the tables after it.
    nonisolated private static func splicingAllowlist(_ source: String, replacing old: String, with new: String) -> String {
        guard let range = source.range(of: "var ALLOWLIST = " + old) else { return source }
        return source.replacingCharacters(in: range, with: "var ALLOWLIST = " + new)
    }

    func rebuildBlocker(allowlist: BlockerAllowlist) async {
        blockerGeneration += 1
        setBlockerAllowlist(allowlist.sites)
        guard contentBlockerEnabled else { return }
        // Already attached (launch applies the cached rules ahead of the scripts, then both): a swap
        // would resend the same list to every web process. The source compile would release goes too.
        guard contentRuleLists.first?.identifier != ruleListIdentifier(allowlist: allowlist) + ".p0" else {
            externalFilterRulesJSON = nil
            return
        }
        // Keep the currently applied rules if the new set fails to compile (e.g. a too-large external
        // list hits WebKit's rule limit): never regress to no blocking.
        guard let newLists = await compile(allowlist: allowlist, generation: blockerGeneration) else { return }
        let old = contentRuleLists
        contentRuleLists = newLists
        // Turned off meanwhile (applyBlockerChange): kept for when it comes back on.
        if contentBlockerEnabled { swapRuleLists(old: old, new: newLists) }
    }

    private static let ruleListIdentifierPrefix = "fr.arouillard.lilo.content-blocker."

    private func ruleListIdentifier(allowlist: BlockerAllowlist) -> String {
        let sitesTag = allowlist.sites.isEmpty ? "" : ".al-\(Self.stableHash8(allowlist.sites.sorted().joined(separator: "|")))"
        let domainsTag = allowlist.domains.isEmpty ? "" : ".ad-\(Self.stableHash8(allowlist.domains.sorted().joined(separator: "|")))"
        return "\(Self.ruleListIdentifierPrefix)v4.\(externalFilterRulesTag)\(sitesTag)\(domainsTag)"
    }

    /// WebKit rejects a list past 150,000 rules.
    private nonisolated static let maxRulesPerList = 140_000

    /// The rule lists for the current rules and allowlist, `<id>.p0` onwards. Parts compile last to first,
    /// so a stored `p0` means the whole set is there. nil once a newer compile has been requested.
    private func compile(allowlist: BlockerAllowlist, generation: Int) async -> [WKContentRuleList]? {
        let id = ruleListIdentifier(allowlist: allowlist)
        guard let store = WKContentRuleListStore.default() else { return nil }
        if let first = try? await store.contentRuleList(forIdentifier: id + ".p0") {
            var lists = [first]
            while let next = try? await store.contentRuleList(forIdentifier: id + ".p\(lists.count)") { lists.append(next) }
            guard generation == blockerGeneration else { return nil }
            externalFilterRulesJSON = nil
            return lists
        }

        // Cache miss: the multi-MB JSON is read, split and patched off the main actor; external rules already released from memory
        // come back from FilterListService's cache file.
        let externalJSON = externalFilterRulesJSON
        let externalSourceURL = externalFilterRulesTag == "bundled" ? nil : FilterListService.cacheURL
        let parts = await Task.detached(priority: .utility) { () -> [String]? in
            var external = externalJSON
            if external == nil, let externalSourceURL {
                // Never compile the bundled fallback under an external tag: keep the current list.
                guard let fromDisk = try? String(contentsOf: externalSourceURL, encoding: .utf8),
                      !fromDisk.isEmpty else { return nil }
                external = fromDisk
            }
            guard let json = external
                ?? Bundle.appResourceURL("content-blocker-rules", extension: "json").flatMap({ try? String(contentsOf: $0, encoding: .utf8) }),
                  let parts = Self.ruleListParts(json, limit: Self.maxRulesPerList) else { return nil }
            return parts.compactMap { Self.appendingAllowlistRule($0, allowlist: allowlist) }
        }.value
        guard let parts, !parts.isEmpty else { return nil }

        var lists: [WKContentRuleList] = []
        for (index, json) in parts.enumerated().reversed() {
            guard let list = try? await store.compileContentRuleList(forIdentifier: id + ".p\(index)", encodedContentRuleList: json) else {
                return nil
            }
            lists.insert(list, at: 0)
        }
        guard generation == blockerGeneration else { return nil }
        // The multi-MB source is only needed on a compile cache miss; holding it for the process
        // lifetime wastes memory, so it is released once compiled lists exist.
        externalFilterRulesJSON = nil
        await removeStaleRuleLists(keeping: Set(lists.compactMap(\.identifier)), from: store, generation: generation)
        return generation == blockerGeneration ? lists : nil
    }

    /// Every rules refresh and allowlist edit compiles under a new identifier, and the store keeps
    /// each compiled list on disk until removed: several MB a day otherwise. Stops once a newer compile
    /// starts, whose parts would otherwise look stale.
    private func removeStaleRuleLists(keeping ids: Set<String>, from store: WKContentRuleListStore, generation: Int) async {
        let identifiers = await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            store.getAvailableContentRuleListIdentifiers { continuation.resume(returning: $0 ?? []) }
        }
        for stale in identifiers where stale.hasPrefix(Self.ruleListIdentifierPrefix) && !ids.contains(stale) {
            guard generation == blockerGeneration else { return }
            try? await store.removeContentRuleList(forIdentifier: stale)
        }
    }

    /// Splits a rule array ordered blocks (and cosmetics), then exceptions and `$important` blocks, into
    /// parts of at most `limit` rules. An exception only overrides rules of its own list, so every part
    /// carries the whole exception tail after its share of blocks. nil when the JSON is not a rule array.
    nonisolated static func ruleListParts(_ json: String, limit: Int) -> [String]? {
        guard let rules = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] else { return nil }
        guard rules.count > limit else { return [json] }
        let tailStart = rules.firstIndex { ($0["action"] as? [String: Any])?["type"] as? String == "ignore-previous-rules" } ?? rules.count
        let tail = rules[tailStart...]
        let share = limit - tail.count
        guard share > 0 else { return nil }
        let head = rules[..<tailStart]
        return stride(from: head.startIndex, to: head.endIndex, by: share).compactMap { start in
            let part = Array(head[start..<min(start + share, head.endIndex)]) + tail
            return (try? JSONSerialization.data(withJSONObject: part)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    /// The rule JSON plus trailing allowlist rules: one per allowed request domain (`url-filter` has no
    /// alternation), bot-defense vendors' included, then one for the sites. A per-rule `unless-top-url` fails
    /// to compile next to `if-domain` triggers and makes WebKit rebuild cosmetic rules per page.
    nonisolated static func appendingAllowlistRule(_ json: String, allowlist: BlockerAllowlist) -> String? {
        guard let close = json.lastIndex(of: "]") else { return nil }
        var rules: [[String: Any]] = (allowlist.domains + BlockerAllowlist.botDefenseDomains).map {
            ["trigger": ["url-filter": "^[a-z-]+://([^/]+\\.)?\($0.replacingOccurrences(of: ".", with: "\\."))[/:]"],
             "action": ["type": "ignore-previous-rules"]]
        }
        if !allowlist.sites.isEmpty {
            // Anchored at both ends of the host, or `example.co` would also stand down on example.com and on any page whose
            // URL merely contains the site.
            let patterns = allowlist.sites.map { "^https?://(www\\.)?\($0.replacingOccurrences(of: ".", with: "\\."))[:/]" }
            rules.append(["trigger": ["url-filter": ".*", "if-top-url": patterns], "action": ["type": "ignore-previous-rules"]])
        }
        guard let rulesData = try? JSONSerialization.data(withJSONObject: rules),
              let rulesJSON = String(data: rulesData, encoding: .utf8) else { return nil }
        let head = json[..<close]
        let separator = head.last(where: { !$0.isWhitespace }) == "[" ? "" : ","
        // The rules' own brackets come off: they join the list's array.
        return String(head) + separator + rulesJSON.dropFirst().dropLast() + "]"
    }

    /// Safari's version, which ships with the system WebKit, as Safari states it: a point release (27.0.1) shows, and a user
    /// agent that disagrees with the engine reads as a bot. The OS release stands in where Safari is missing.
    static let safariApplicationName: String = {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let version = Bundle(path: "/Applications/Safari.app")?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "\(os.majorVersion).\(os.minorVersion)"
        return "Version/\(version) Safari/605.1.15"
    }()

    private func configuredWebViewConfiguration(
        from configuration: Configuration,
        usesNativeConfiguration: Bool
    ) -> WKWebViewConfiguration {
        let wkConfig = configuration.nativeConfiguration ?? WKWebViewConfiguration()
        WebInspectorSupport.prepare(configuration: wkConfig)
        // No trailing app token: a "Lilo/1.0" after "Safari/605.1.15" trips strict UA sniffers into a
        // Widevine path WKWebView can't satisfy (it ships only FairPlay), breaking streaming playback.
        wkConfig.applicationNameForUserAgent = Self.safariApplicationName
        // HTTPS-first: http URLs try HTTPS and fall back silently; HTTPS-Only asks before the fallback.
        wkConfig.defaultWebpagePreferences.preferredHTTPSNavigationPolicy =
            Self.httpsOnlyEnabled ? .userMediatedFallbackToHTTP : .automaticFallbackToHTTP
        if #available(macOS 27, *) {
            wkConfig.defaultWebpagePreferences.globalPrivacyControlEnabled = Self.globalPrivacyControlEnabled
        }
        wkConfig.preferences.tabFocusesLinks = true
        wkConfig.preferences.minimumFontSize = Self.minimumFontSize
        let registry = configuration.profileId.flatMap { profileContexts?.existingContext(for: $0)?.extensions }
        if let registry {
            let fonts = fontSettingsHandler.overrides(for: registry)
            if fonts != FontSettingsBridgeHandler.Overrides() { Self.apply(fonts, to: wkConfig.preferences) }
        }
        wkConfig.preferences.isElementFullscreenEnabled = true
        wkConfig.preferences.inactiveSchedulingPolicy = .throttle
        // Off in a bare WKWebView on macOS: no sound without a gesture, unless the
        // user chose otherwise.
        wkConfig.mediaTypesRequiringUserActionForPlayback = Self.autoplayRestriction
        // KVC resolves these keys to private `_set<Key>:` setters; a missing one would raise. Private
        // Click Measurement is ad-click attribution, on by default in WebKit. No autoplay
        // out of view, and hidden pages' timers throttled harder the longer they stay hidden.
        let privateSettings: [(NSObject, String, Bool)] = [
            (wkConfig.preferences, "allowsPictureInPictureMediaPlayback", true), (wkConfig.preferences, "mediaDevicesEnabled", true),
            (wkConfig.preferences, "privateClickMeasurementEnabled", false), (wkConfig, "invisibleAutoplayNotPermitted", true),
            (wkConfig.preferences, "hiddenPageDOMTimerThrottlingAutoIncreases", true)
        ]
        for (object, key, value) in privateSettings where object.responds(to: NSSelectorFromString("_set\(key.prefix(1).uppercased())\(key.dropFirst()):")) {
            object.setValue(value, forKey: key)
        }
        wkConfig.suppressesIncrementalRendering = false
        WKFeatureFlags.apply(featureFlagOverrides, to: wkConfig.preferences)

        // Extension pages must carry the controller binding or their `chrome.runtime` messaging to the
        // background worker is silently dropped. Only set when the native config lacks one.
        let extController = registry?.controller
        if usesNativeConfiguration, wkConfig.webExtensionController == nil, let extController {
            wkConfig.webExtensionController = extController
        }

        guard !usesNativeConfiguration else {
            return wkConfig
        }

        let store = configuration.dataStore ?? sharedDefaultDataStore
        wkConfig.websiteDataStore = store.backingStore
        if let pool = Self.contentProcessPool, wkConfig.responds(to: NSSelectorFromString("setProcessPool:")) {
            wkConfig.setValue(pool, forKey: "processPool")
        }
        // Ferry frames for getDisplayMedia tab sharing; token-gated, so pages without a live
        // session only ever see 410s. Popup configurations inherit the handler via WebKit's copy.
        wkConfig.setURLSchemeHandler(tabShareFrameSchemeHandler, forURLScheme: TabShareFrameSchemeHandler.scheme)
        wkConfig.setURLSchemeHandler(viewSourceSchemeHandler, forURLScheme: ViewSourceSchemeHandler.scheme)

        if let extController {
            wkConfig.webExtensionController = extController
        }

        let key = contentControllerKey(for: store)
        let contentController = cachedContentController(for: key)
        wkConfig.userContentController = contentController
        if let profileId = configuration.profileId, contentControllerOwners.object(forKey: contentController) == nil {
            contentControllerOwners.setObject(ContentControllerOwner(profileId: profileId, isPrivate: key.isPrivate), forKey: contentController)
            for install in (registry?.userScripts.installs ?? [:]).values {
                installExtensionUserScripts(install.scripts, of: install, on: contentController, isPrivate: key.isPrivate)
            }
        }

        return wkConfig
    }

    private func cachedContentController(for key: ContentControllerKey) -> WKUserContentController {
        if let existing = contentControllersByKey[key] { return existing }

        let contentController = WKUserContentController()
        // Never in the page world, which would then expose `window.webkit` to every page.
        let world = PageWorld.bridgeWorld
        contentController.addScriptMessageHandler(webstoreInstallHandler, contentWorld: world, name: WebstoreInstallHandler.messageHandlerName)
        // WKWebView calls the geolocation permission delegate but ships no position provider, so no
        // coordinates ever arrive after granting. A CoreLocation-backed polyfill is required.
        contentController.add(geolocationBridge, contentWorld: world, name: GeolocationBridge.messageHandlerName)
        contentController.add(notificationBridge, contentWorld: world, name: NotificationBridge.messageHandlerName)
        contentController.addScriptMessageHandler(serialBridge, contentWorld: world, name: SerialBridge.messageHandlerName)
        contentController.addScriptMessageHandler(eyeDropperBridge, contentWorld: world, name: EyeDropperBridge.messageHandlerName)
        contentController.add(formDirtyBridge, contentWorld: world, name: FormDirtyBridge.messageHandlerName)
        contentController.add(callControlsBridge, contentWorld: world, name: CallControlsBridge.messageHandlerName)
        contentController.addScriptMessageHandler(tabShareBridge, contentWorld: world, name: TabShareBridge.messageHandlerName)
        installUserScripts(on: contentController)
        if contentBlockerEnabled { contentRuleLists.forEach(contentController.add) }
        contentControllersByKey[key] = contentController
        liveContentControllers.add(contentController)
        return contentController
    }

    /// The full user-script set for a content controller. Also used to rescript a live controller
    /// after an injection-table change (message handlers and the rule list are managed separately).
    private func installUserScripts(on contentController: WKUserContentController) {
        // First, so the store shim below finds the store's transport.
        PageWorld.install([
            GeolocationBridge.pageModule, NotificationBridge.pageModule, SerialBridge.pageModule, EyeDropperBridge.pageModule,
            TabShareBridge.pageModule, WKWebViewTab.mediaControlModule, CooperativeFreezer.pageModule, WebstoreInstallHandler.pageModule
        ], on: contentController)
        contentController.addUserScript(WKUserScript(source: FormDirtyBridge.scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false,
                                                     in: PageWorld.bridgeWorld))
        // Store shim for regular tabs (the store is a normal https tab without ChromeAPIAugmentation.js), top-level only. Injected
        // only into the store when the match-pattern SPI exists; it self-guards on the hostname otherwise.
        if let source = bundledTemplate("ChromeWebStoreShim") {
            let script = ExtensionUserScripts.makeMatchingUserScript?(source, .atDocumentStart, true, ["*://chromewebstore.google.com/*"], [], .page)
                ?? WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
            contentController.addUserScript(script)
        } else {
            Self.logger.error("ChromeWebStoreShim.js not found in bundle: Chrome Web Store install will not work")
        }
        installedFilterUserScripts.forEach { contentController.addUserScript($0) }
    }

    /// Bundle JS templates are immutable; each resource is read once per factory lifetime.
    private func bundledTemplate(_ resource: String) -> String? {
        if let cached = templateSourceByResource[resource] { return cached }
        guard let url = Bundle.appResourceURL(resource, extension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        templateSourceByResource[resource] = source
        return source
    }

    /// U+2028/U+2029 need no escaping: they are legal inside JS string literals since ES2019.
    nonisolated private static func jsStringLiteral(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r") + "\""
    }

    /// Tokens hashed into buckets (`FNV-1a(token) % count` holds `|token|...|`, comma-joined) so a page tests a class or id against
    /// a handful of tokens instead of building huge sets. Only `[A-Za-z0-9_-]` tokens are kept, so the literal needs no escape.
    nonisolated static func tokenBuckets(_ tokens: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-".utf8)
        let list = tokens.split(separator: " ").filter { $0.utf8.allSatisfy(allowed.contains) }
        guard !list.isEmpty else { return "" }
        var count = 16
        while count * 16 < list.count { count *= 2 }
        var buckets = [[Substring]](repeating: [], count: count)
        for token in list {
            var hash: UInt32 = 2_166_136_261
            for unit in token.utf16 { hash = (hash ^ UInt32(unit)) &* 16_777_619 }
            buckets[Int(hash % UInt32(count))].append(token)
        }
        return buckets.map { $0.isEmpty ? "" : "|" + $0.joined(separator: "|") + "|" }.joined(separator: ",")
    }

    /// Sortable base-64 digits: their character codes rise with their values.
    nonisolated private static let sortableDigits = Array("+/0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// A key's 48-bit hash (two FNV-1a passes over its UTF-16 units) in 8 sortable digits, as the
    /// scripts compute it. 48 bits keep a false match among the tables' keys out of reach.
    nonisolated static func keyHash(_ key: String) -> String {
        var a: UInt32 = 2_166_136_261
        var b: UInt32 = 0x9747_B28C
        for unit in key.utf16 {
            a = (a ^ UInt32(unit)) &* 16_777_619
            b = (b ^ UInt32(unit)) &* 16_777_619
        }
        let value = UInt64(a) << 16 | UInt64(b >> 16)
        return String((0..<8).reversed().map { sortableDigits[Int(value >> (6 * UInt64($0)) & 63)] })
    }

    /// A keyed table (hosts, `.class`/`#id`) the injected scripts binary-search: sorted `index` records point into shared `groups`,
    /// which list offsets into `entries`. All escape-free Latin-1 so JSC lexes it fast; non-ASCII keys are dropped (hostname is punycode).
    /// A scriptlet entry names its scriptlet by a base-36 index into `names`, the most used first.
    nonisolated static func hostTable(for tableJSON: String) -> (index: String, groups: String, entries: String, names: String)? {
        guard let table = (try? JSONSerialization.jsonObject(with: Data(tableJSON.utf8))) as? [String: [Any]] else { return nil }
        var uses: [String: Int] = [:]
        for keyEntries in table.values {
            for case let scriptlet as [Any] in keyEntries {
                if let name = (scriptlet.first as? String)?.drop(while: { $0 == "@" }), !name.isEmpty { uses[String(name), default: 0] += 1 }
            }
        }
        let names = uses.keys.sorted { (uses[$0]!, $1) > (uses[$1]!, $0) }
        let nameRefs = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, String($0, radix: 36)) })
        func encoded(_ text: String) -> String {
            var out = String.UnicodeScalarView()
            for unit in text.utf16 {
                switch unit {
                case 0x5C: out.append("¤")
                case 0x22: out.append("¬")
                case 0x0A, 0x0D: out.append("¶")
                case 0x20...0x7E, 0xA0...0xA3, 0xA5, 0xA8...0xAB, 0xAD...0xB4, 0xB7...0xFF: out.append(Unicode.Scalar(UInt8(unit)))
                default: out.append(contentsOf: String(format: "µ%04x", unit).unicodeScalars)
                }
            }
            return String(out)
        }
        var entries = ""
        var entriesLength = 0
        var refByEntry: [String: String] = [:]
        var groups = ""
        var groupOffsetByList: [String: Int] = [:]
        var records: [(hash: String, group: Int)] = []
        for (key, keyEntries) in table where key.allSatisfy(\.isASCII) {
            var refs: [String] = []
            for value in keyEntries {
                let parts: [String]
                if let string = value as? String {
                    parts = [string]
                } else if let scriptlet = value as? [Any], let name = scriptlet.first as? String {
                    // An exception keeps its `@`, and `@` alone excepts every scriptlet.
                    let bare = String(name.drop { $0 == "@" })
                    let ref = bare.isEmpty ? "" : nameRefs[bare]!
                    parts = [(name.hasPrefix("@") ? "@" : "") + ref] + (scriptlet.dropFirst().first as? [String] ?? [])
                } else {
                    continue
                }
                let entry = parts.map(encoded).joined(separator: "¦")
                if let ref = refByEntry[entry] {
                    refs.append(ref)
                    continue
                }
                let ref = String(entriesLength, radix: 36)
                refByEntry[entry] = ref
                refs.append(ref)
                entries += entry + "§"
                entriesLength += entry.utf16.count + 1
            }
            guard !refs.isEmpty else { continue }
            let list = refs.joined(separator: ",")
            let offset = groupOffsetByList[list] ?? groups.utf16.count
            if groupOffsetByList[list] == nil {
                groupOffsetByList[list] = offset
                groups += list + "|"
            }
            records.append((keyHash(key), offset))
        }
        guard !records.isEmpty else { return nil }
        let index = records.sorted { $0.hash < $1.hash }.map { record in
            record.hash + String((0..<4).reversed().map { sortableDigits[record.group >> (6 * $0) & 63] })
        }.joined()
        return (index, groups, entries, names.joined(separator: " "))
    }

    /// Private spaces release their ephemeral data store when the space closes; without this the cache
    /// keeps the controller and its handlers alive. Existing web views hold their own reference.
    func releaseContentController(for dataStore: WKEngineDataStore) {
        let key = contentControllerKey(for: dataStore)
        contentControllersByKey.removeValue(forKey: key)
        for warmKey in warmKeyOrder where warmKey.content == key { warmWebViewsByKey.removeValue(forKey: warmKey) }
        warmKeyOrder.removeAll { $0.content == key }
    }

    private func contentControllerKey(for dataStore: WKEngineDataStore) -> ContentControllerKey {
        ContentControllerKey(
            dataStoreKey: dataStore.identifier,
            isPrivate: !dataStore.backingStore.isPersistent
        )
    }

    private func takeWarm(key: WarmKey) -> WKWebView? {
        guard let webView = warmWebViewsByKey.removeValue(forKey: key) else { return nil }
        warmKeyOrder.removeAll { $0 == key }
        // An evicted profile is rebuilt with a new controller; a view bound to the old one runs no extension.
        let controller = key.profileId.flatMap { profileContexts?.existingContext(for: $0)?.extensions.controller }
        guard webView.configuration.webExtensionController === controller else { return nil }
        return webView
    }

    /// While the system is power-constrained (Low Power Mode, thermal pressure), a speculative
    /// warm WKWebView is a live WebContent process kept around "just in case": not worth it.
    var suppressWarmPool = false {
        didSet {
            guard suppressWarmPool else { return }
            dropWarmPool()
        }
    }

    /// Releases the pre-spawned processes without disabling prewarming, for transient pressure: the pool
    /// refills lazily, unlike `suppressWarmPool` which keeps it off.
    func dropWarmPool() {
        warmWebViewsByKey.removeAll()
        warmKeyOrder.removeAll()
    }

    private var pendingWarmPoolRelease: Task<Void, Never>?
    /// A long absence dropped warm views, which coming back rebuilds.
    private var releasedWarmPool = false

    /// For a stretch in the background: a quick app switch keeps the warm views, a long absence frees them.
    func releaseWarmPool(after delay: Duration) {
        pendingWarmPoolRelease?.cancel()
        pendingWarmPoolRelease = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            releasedWarmPool = releasedWarmPool || !warmWebViewsByKey.isEmpty
            dropWarmPool()
        }
    }

    /// Back in the foreground: cancels a pending release, and rebuilds off the activation path a warm view
    /// a release dropped. A pool that was empty stays empty: the next tab the user opens refills it.
    func resumeWarmPool(dataStore: WKEngineDataStore, profileId: UUID?) {
        pendingWarmPoolRelease?.cancel()
        pendingWarmPoolRelease = nil
        guard releasedWarmPool else { return }
        releasedWarmPool = false
        rearmWarmPool(dataStore: dataStore, profileId: profileId)
    }

    /// Builds a warm view for `dataStore` off the current path.
    func rearmWarmPool(dataStore: WKEngineDataStore, profileId: UUID?) {
        scheduleWarmRefill(dataStore: dataStore, key: WarmKey(content: contentControllerKey(for: dataStore), profileId: profileId))
    }

    /// An immediate refill competes with the navigation that just consumed the warm view.
    private func scheduleWarmRefill(dataStore: WKEngineDataStore, key: WarmKey) {
        Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.prepareWarm(dataStore: dataStore, key: key)
        }
    }

    private func prepareWarm(dataStore: WKEngineDataStore, key: WarmKey) {
        guard !suppressWarmPool, warmWebViewsByKey[key] == nil else { return }
        // A refill can land after its profile was evicted: the view would carry no controller.
        if let profileId = key.profileId, profileContexts?.existingContext(for: profileId) == nil { return }
        let wkConfig = configuredWebViewConfiguration(
            from: Configuration(dataStore: dataStore, profileId: key.profileId),
            usesNativeConfiguration: false
        )
        if warmWebViewsByKey.count >= Self.warmPoolCapacity, let oldest = warmKeyOrder.first {
            warmWebViewsByKey.removeValue(forKey: oldest)
            warmKeyOrder.removeFirst()
        }
        let webView = WKWebView(frame: .zero, configuration: wkConfig)
        // A bare WKWebView is an unspawned shell, and this one carries the right per-data-store config, so
        // the tab that takes it reuses the process. Forced with a trivial script rather than about:blank,
        // which would commit a back-forward entry the back-swipe would land on.
        webView.evaluateJavaScript("0") { _, _ in }
        warmWebViewsByKey[key] = webView
        warmKeyOrder.append(key)
    }

    /// Test-only visibility into the warm pool (count of speculative warm web views).
    var test_warmPoolCount: Int { warmWebViewsByKey.count }
}
