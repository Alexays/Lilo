// Views, database, bridge and chrome loading.

import AppKit
import GRDB
import OSLog
import QuickLookUI
import UserNotifications
import WebKit

extension MainWindowController {
    func setupViews() {
        guard let contentView = window?.contentView else { return }

        contentContainerView = ContentContainerView(frame: contentFrameRect())
        contentContainerView.autoresizingMask = [.width, .height]
        contentContainerView.wantsLayer = true
        contentView.addSubview(contentContainerView)

        let frameView = WindowFrameView(frame: contentView.bounds, edges: contentEdges())
        frameView.autoresizingMask = [.width, .height]
        contentView.addSubview(frameView, positioned: .above, relativeTo: contentContainerView)
        windowFrameView = frameView

        applyWindowChromeColors(currentWindowBackgroundCSSColor())

        chromeWebView.frame = contentView.bounds
        chromeWebView.autoresizingMask = [.width, .height]

        chromeInput.shield.frame = chromeWebView.bounds
        chromeInput.shield.autoresizingMask = [.width, .height]
        chromeInput.setContentView(tabManager.activeEngineTab?.view)

        contentView.addSubview(chromeWebView, positioned: .above, relativeTo: windowFrameView)
        chromeWebView.addSubview(chromeInput.shield)
    }

    /// The chrome keeps no data (its CSP loads nothing remote), so it need not open a store on disk. One store for
    /// every window: WebKit shares a related web view's process only within the same store.
    private static let chromeDataStore = WKWebsiteDataStore.nonPersistent()
    /// The last chrome made, so the next window's chrome joins its process instead of launching and warming its own.
    private static weak var lastChromeWebView: OverlayWebView?

    static func makeChromeWebView(frame: CGRect) -> OverlayWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = chromeDataStore
        let setRelatedWebView = NSSelectorFromString("_setRelatedWebView:")
        if let lastChromeWebView, config.responds(to: setRelatedWebView) {
            config.perform(setRelatedWebView, with: lastChromeWebView)
        }
        config.userContentController = WKUserContentController()
        config.setURLSchemeHandler(ChromeUISchemeHandler(), forURLScheme: ChromeUISchemeHandler.scheme)
        WebInspectorSupport.prepare(configuration: config)
        // The chrome draws with system fonts only. Allowed user-installed fonts make WebKit enumerate every
        // installed font on this thread before it launches the chrome's process. KVC resolves this key to
        // the private `_setShouldAllowUserInstalledFonts:`; without it the write raises.
        if config.preferences.responds(to: NSSelectorFromString("_setShouldAllowUserInstalledFonts:")) {
            config.preferences.setValue(false, forKey: "shouldAllowUserInstalledFonts")
        }
        let webView = OverlayWebView(frame: frame, configuration: config)
        WebInspectorSupport.enable(for: webView)
        lastChromeWebView = webView
        return webView
    }

    // MARK: - Chrome Preload

    static var _preloadedWebView: OverlayWebView?

    static func preloadChromeWebView() {
        guard _preloadedWebView == nil else { return }
        let webView = makeChromeWebView(frame: .zero)
        let cachedWidth = UserDefaults.lilo.double(forKey: "cachedSidebarWidth")
        let sidebarWidth = cachedWidth > 0 ? CGFloat(cachedWidth).clamped(to: sidebarWidthRange) : defaultSidebarWidth
        let bgColor = UserDefaults.lilo.string(forKey: cachedWindowBgColorKey) ?? ""
        webView.configuration.userContentController.addUserScript(
            buildBootstrapScript(
                sidebarWidth: sidebarWidth, windowBackgroundColor: bgColor,
                tabLayout: TabLayout.cached.shown(toolbarVisible: UserDefaults.lilo.object(forKey: "cachedToolbarVisible") as? Bool ?? true)
            )
        )
        webView.load(URLRequest(url: ChromeUISchemeHandler.indexURL))
        _preloadedWebView = webView
        StartupMetrics.mark("chromePreloadIssued")
    }

    func restoreWindowChromeState() {
        let cachedWidth = UserDefaults.lilo.double(forKey: "cachedSidebarWidth")
        let cachedBgColor = UserDefaults.lilo.string(forKey: Self.cachedWindowBgColorKey)

        sidebarVisible = UserDefaults.lilo.object(forKey: "cachedSidebarVisible") as? Bool ?? true
        toolbarVisible = UserDefaults.lilo.object(forKey: "cachedToolbarVisible") as? Bool ?? true
        sidebarOverlayVisible = false
        sidebarExpandedWidth = cachedWidth > 0 ? CGFloat(cachedWidth).clamped(to: Self.sidebarWidthRange) : Self.defaultSidebarWidth
        sidebarWidth = fittedSidebarWidth
        // Every layout keeps the lights where the 52pt sidebar header centers them.
        window?.toolbarStyle = .unified
        storedWindowBackgroundColor = cachedBgColor
        applyWindowChromeColors(currentWindowBackgroundCSSColor())
    }

    func reconcileBootstrapCacheWithDB() {
        // The window shows before the database opens, laid out from the UserDefaults mirror.
        if let settings = context.settingsStore {
            let dbVisible = settings.sidebarVisible
            let dbToolbarVisible = settings.toolbarVisible
            let dbWidth = CGFloat(settings.sidebarWidth).clamped(to: Self.sidebarWidthRange)
            if sidebarVisible != dbVisible || toolbarVisible != dbToolbarVisible || sidebarExpandedWidth != dbWidth {
                sidebarVisible = dbVisible
                toolbarVisible = dbToolbarVisible
                sidebarExpandedWidth = dbWidth
                UserDefaults.lilo.set(dbVisible, forKey: "cachedSidebarVisible")
                UserDefaults.lilo.set(dbToolbarVisible, forKey: "cachedToolbarVisible")
                UserDefaults.lilo.set(Double(dbWidth), forKey: "cachedSidebarWidth")
                applySidebarLayout(animated: false, syncTrafficLights: true)
            }
            let dbLayout = settings.tabLayout
            if dbLayout != tabLayout {
                dbLayout.cache()
                applyTabLayout(dbLayout, animated: false)
            }
        }

        // The database keeps one color for both appearances: it only fills a missing mirror.
        let cacheKey = Self.cachedWindowBgColorKey
        if UserDefaults.lilo.string(forKey: cacheKey) == nil, let dbBgColor = storedWindowBackgroundColor {
            UserDefaults.lilo.set(dbBgColor, forKey: cacheKey)
            applyWindowChromeColors(currentWindowBackgroundCSSColor())
        }
    }

    // MARK: - Window Chrome Colors

    static func defaultSidebarBackgroundColor() -> NSColor {
        return prefersDarkSidebarAppearance()
            ? NSColor(cssHex: "#1a1a2e") ?? .windowBackgroundColor
            : NSColor(cssHex: "#e2daf1") ?? .windowBackgroundColor
    }

    static func prefersDarkSidebarAppearance() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// The first frame's color mirror, one per appearance: the cached color is resolved for light or dark.
    static var cachedWindowBgColorKey: String {
        prefersDarkSidebarAppearance() ? "cachedWindowBgColor.dark" : "cachedWindowBgColor.light"
    }

    nonisolated static func normalizedCSSColor(_ cssColor: String?) -> String? {
        let trimmedColor = cssColor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedColor.isEmpty ? nil : trimmedColor
    }

    static func resolvedSidebarBackgroundCSSColor(accentColor: String?) -> String? {
        let fallbackAccentColor = prefersDarkSidebarAppearance() ? "#1a1a2e" : "#e2daf1"
        let resolvedAccentColor = NSColor(cssHex: accentColor ?? fallbackAccentColor)
            ?? NSColor(cssHex: fallbackAccentColor)

        return resolvedAccentColor?
            .sidebarBackgroundColor(prefersDark: prefersDarkSidebarAppearance())
            .cssHexString
    }

    func applyWindowChromeColors(_ cssColor: String?) {
        let trimmedColor = Self.normalizedCSSColor(cssColor)
        let resolvedColor = NSColor(cssHex: trimmedColor ?? "") ?? Self.defaultSidebarBackgroundColor()

        if let trimmedColor, trimmedColor != storedWindowBackgroundColor {
            storedWindowBackgroundColor = trimmedColor
            // Persist only once the color settles (~500ms trailing): the UI samples this at ~10Hz
            // during space swipes and each write is a synchronous SQLite round trip.
            pendingWindowBackgroundPersistWork?.cancel()
            let cacheKey = Self.cachedWindowBgColorKey
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                context.settingsStore?.windowBackgroundColor = trimmedColor
                UserDefaults.lilo.set(trimmedColor, forKey: cacheKey)
            }
            pendingWindowBackgroundPersistWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        // Swipes resend the same color at ~10Hz; views shown later read the current color themselves.
        guard resolvedColor != lastAppliedWindowChromeColor else { return }

        // Over glass the glass itself carries the Space's tint; the frame adds only a hint, so the desktop shows through.
        let frameColor = glassView == nil ? resolvedColor : resolvedColor.withAlphaComponent(0.15)
        window?.backgroundColor = glassView == nil ? resolvedColor : .clear
        glassView?.tintColor = resolvedColor.withAlphaComponent(0.4)
        let surfaceColor = resolvedColor.contentSurfaceColor
        // The popups, peeks and Little windows of this Space wear its color in their title bar and under their page.
        for popup in pagePopups.values where context.browserState.owningSpaceId(forTab: popup.openerTabId) == tabManager.currentSpaceId {
            popup.window?.backgroundColor = resolvedColor
            popup.engine.applyPageBackgroundColor(surfaceColor)
        }
        for little in littleWindows.values where little.spaceId == tabManager.currentSpaceId {
            little.window.backgroundColor = resolvedColor
            little.engine.applyPageBackgroundColor(surfaceColor)
        }
        // The visible frame paint: fades over ~0.34s to match the chrome sidebar's own
        // background-color transition (the UI throttles updateWindowBackground to ~10Hz
        // during space swipes; the native fade smooths between samples).
        windowFrameView?.setFrameColor(frameColor)
        syncPageBar()
        (contentContainerView as? ContentContainerView)?.stageColor = resolvedColor
        for divider in splitPanes.dividers.values { divider.setFrameColor(resolvedColor, animated: true) }
        sidePanel.setFrameColor(resolvedColor)
        // A Changes view paints the frame color under its cards.
        for case let view as ChangesView in contentContainerView?.subviews ?? [] { view.needsDisplay = true }
        changesPeek?.view.needsDisplay = true

        guard let contentLayer = contentContainerView?.layer else { return }
        contentLayer.backgroundColor = surfaceColor.cgColor
        contentLayer.borderColor = resolvedColor.contentSurfaceBorderColor.cgColor

        // Only the visible engines (the active tab, or every pane of its split) need the new surface color now;
        // every other engine picks it up from showContentView (via currentContentSurfaceColor) the next time it becomes visible.
        tabManager.activeEngineTab?.applyPageBackgroundColor(surfaceColor)
        for id in displayedTabIds { tabManager.engineTab(for: id)?.applyPageBackgroundColor(surfaceColor) }
        tabManager.terminalHost.setSurface(surfaceColor)
        // Recorded only once the window, frame view and content layer all took it.
        if window != nil, windowFrameView != nil { lastAppliedWindowChromeColor = resolvedColor }
    }

    /// One frame of a Space swipe: only the frame around the page follows the finger, at once. The swipe's end
    /// brings the full update (page surfaces, popups, the saved color).
    func applySwipeFrameColor(_ cssColor: String) {
        guard let color = NSColor(cssHex: cssColor) else { return }
        if glassView == nil {
            window?.backgroundColor = color
        } else {
            glassView?.tintColor = color.withAlphaComponent(0.4)
        }
        windowFrameView?.setFrameColor(glassView == nil ? color : color.withAlphaComponent(0.15), animated: false)
        lastAppliedWindowChromeColor = nil
    }

    /// Puts the window on glass, or back on its solid color. Changes only when the shown Space's material does.
    func applyWindowMaterial(_ material: String?) {
        windowFrameView?.setGrain(material == "grain")
        let glass = material == "glass"
        guard glass != (glassView != nil), let window, let contentView = window.contentView else { return }
        // The glass fades with the frame and the sidebar, over the same time.
        let fade = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : WindowFrameView.colorFadeDuration
        if glass {
            let view = NSGlassEffectView(frame: contentView.bounds)
            view.autoresizingMask = [.width, .height]
            view.alphaValue = 0
            contentView.addSubview(view, positioned: .below, relativeTo: nil)
            glassView = view
            window.isOpaque = false
            NSAnimationContext.runAnimationGroup { $0.duration = fade; view.animator().alphaValue = 1 }
        } else if let view = glassView {
            // The solid color goes under the glass at once; the glass then fades off it.
            glassView = nil
            NSAnimationContext.runAnimationGroup({ $0.duration = fade; view.animator().alphaValue = 0 }, completionHandler: { [weak self] in
                view.removeFromSuperview()
                guard let self, glassView == nil else { return }
                self.window?.isOpaque = true
                contentContainerView?.layer?.cornerRadius = 0
                contentContainerView?.layer?.masksToBounds = false
            })
        }
        // The frame's corner bites go translucent over glass, so the page rounds its own corners until they are opaque again.
        if glass {
            contentContainerView?.layer?.cornerRadius = WindowFrameView.contentCornerRadius
            contentContainerView?.layer?.masksToBounds = true
        }
        lastAppliedWindowChromeColor = nil
        applyWindowChromeColors(storedWindowBackgroundColor)
    }

    /// The frame color of a window showing Space `id`: this window's own when it shows that Space.
    func frameColor(forSpace id: UUID) -> NSColor {
        if id == tabManager.currentSpaceId, let color = window?.backgroundColor { return color }
        let css = Self.resolvedSidebarBackgroundCSSColor(accentColor: context.spaceManager?.space(with: id)?.color)
        return css.flatMap(NSColor.init(cssHex:)) ?? Self.defaultSidebarBackgroundColor()
    }

    /// Themed color painted under web content (see `showContentView`), so any moment without committed content shows the theme, not
    /// WebKit's default white.
    var currentContentSurfaceColor: NSColor {
        (NSColor(cssHex: storedWindowBackgroundColor ?? "") ?? Self.defaultSidebarBackgroundColor()).contentSurfaceColor
    }

    // MARK: - Database Init

    func setupDatabase() async {
        do {
            try await context.bootstrap()
        } catch {
            BrowserContext.logger.critical("Database setup failed: \(error)")
            context.showFatalDatabaseAlert(error)
            return
        }
        let startupSnapshot: BrowserContext.StartupSnapshot = context.startupSnapshot
        // Decode the space this window shows first off the main actor while the extension, download
        // and bridge wiring runs; the startup sequence awaits it before restoring.
        let dbManager: DatabaseManager = context.dbManager
        let preloadSpace: Space? = switch launch {
        case .restoreSession: Self.predictedInitialSpace(from: startupSnapshot)
        // A space another window already shows is restored from its live state.
        case let .space(spaceId, _, _): context.browserState.space(id: spaceId) == nil ? context.spaceManager?.space(with: spaceId) : nil
        }
        if let preloadSpace {
            let loadsFavicons = context.lastFaviconWarmProfileId != preloadSpace.profileId
            preloadedSpaceRestoreTask = Task {
                guard let loaded = try? await BrowserContext.StartupBackgroundWork.runBlocking({
                    Self.loadPreloadedSpaceRestoreState(from: dbManager, space: preloadSpace, loadsFavicons: loadsFavicons)
                }) else { return nil }
                for entry in loaded.favicons {
                    self.context.faviconService.warmIfAbsent(host: entry.host, dataURL: entry.dataURL, dominantColor: entry.dominantColor)
                }
                if loadsFavicons { self.context.lastFaviconWarmProfileId = preloadSpace.profileId }
                return loaded.state
            }
        }
        context.applyLifecyclePreset(context.settingsStore.lifecyclePreset)
        applyTerminalSettings()
        Task { @MainActor [context] in await context.startContentBlocker() }
        let permissionDecisionHandler: GeolocationBridge.PermissionDecisionHandler = { [weak context] webView, type, origin, completion in
            guard let windows = context?.windows, let window = webView.flatMap(windows.window(for:)) ?? windows.activeWindow else {
                completion(false)
                return
            }
            window.requestSitePermission(type: type, origin: origin, webView: webView, completion: completion)
        }
        context.engineFactory.geolocationPermissionDecisionHandler = permissionDecisionHandler
        context.engineFactory.notificationPermissionDecisionHandler = permissionDecisionHandler
        context.engineFactory.notificationDecisionHandler = { [weak context] webView, origin in
            guard let context, let webView, let window = context.windows.window(for: webView) else { return nil }
            return window.storedPermissionDecision(type: "notifications", origin: origin, tabId: window.tabManager.engineTab(forWebView: webView)?.id)
                ?? (context.settingsStore.refusesPermissionRequests("notifications") ? false : nil)
        }
        setupTabShare()
        setupTabDock()
        restoredStartupSpaceIdsByProfile = startupSnapshot.storedSpaceIdsByProfile
        // The database keeps one color for both appearances: it stands in for a missing mirror only in the appearance it was picked in.
        if storedWindowBackgroundColor == nil, let color = startupSnapshot.windowBackgroundColor,
           NSColor(cssHex: color)?.isPerceptuallyDark == Self.prefersDarkSidebarAppearance() {
            storedWindowBackgroundColor = color
        }
    }

    /// Pre-decodes the initial space's tab tree and raw blobs on the bootstrap queue (blob unarchiving stays on main, at use; a failure
    /// means a synchronous restore). Favicons ride along unless already cached, so the restore skips a main-actor table read.
    nonisolated private static func loadPreloadedSpaceRestoreState(
        from dbManager: DatabaseManager,
        space: Space,
        loadsFavicons: Bool
    ) -> (state: PreloadedSpaceRestoreState?, favicons: [FaviconStore.Entry]) {
        guard let pool = try? dbManager.pool(for: space.profileId) else { return (nil, []) }
        let favicons = loadsFavicons ? (try? FaviconStore(dbPool: pool).all()) ?? [] : []
        // An unreadable row must NOT be handled here: returning nil sends the restore through
        // loadedOrQuarantinedSpaceTabState, the one place that quarantines and surfaces it.
        guard let tabState = try? SpaceTabStateStore(dbPool: pool).load(spaceId: space.id) else { return (nil, favicons) }
        let interactionStates = space.isPrivate
            ? [:]
            : ((try? InteractionStateStore(dbPool: pool).load(spaceId: space.id)) ?? [:])
        let state = PreloadedSpaceRestoreState(
            profileId: space.profileId,
            spaceId: space.id,
            tabState: tabState,
            interactionStates: interactionStates
        )
        return (state, favicons)
    }

    /// Pure boot-time mirror of resolveInitialSpace + restorePreferredSpaceId. Divergence is safe:
    /// the preload is only consumed on an exact (profile, space) match.
    nonisolated static func predictedInitialSpace(from snapshot: BrowserContext.StartupSnapshot) -> Space? {
        guard let profileId = BrowserContext.preferredProfileId(from: snapshot), !snapshot.spaces.isEmpty else { return nil }
        let profileSpaces = snapshot.spaces.filter { $0.profileId == profileId }
        guard !profileSpaces.isEmpty else { return snapshot.spaces.first }
        let storedIds = snapshot.storedSpaceIdsByProfile[profileId] ?? [:]
        if let id = storedIds["lastActiveSpaceId"],
           let space = profileSpaces.first(where: { $0.id == id }) {
            return space
        }
        if let id = storedIds["lastPersistentSpaceId"],
           let space = profileSpaces.first(where: { $0.id == id && !$0.isPrivate }) {
            return space
        }
        return profileSpaces.first
    }

    // MARK: - Bridge Setup

    func setupBridgeEarly() {
        chromeWebView.navigationDelegate = self
        bridgeRouter = BridgeRouter(chromeWebView: chromeWebView)
        // Factory handlers are shared by every window: each resolves the window that shows the page.
        context.engineFactory.formDirtyHandler = { [weak context] webView, dirty in
            guard let tab = context?.windows.windowAndEngine(for: webView)?.engine else { return }
            tab.isFormDirty = dirty
            tab.delegate?.tab(tab, didUpdateFormDirty: dirty)
        }
        context.engineFactory.callControlsHandler = { [weak context] webView, controls in
            guard let tab = context?.windows.windowAndEngine(for: webView)?.engine, tab.callControls != controls else { return }
            tab.callControls = controls
            tab.delegate?.tab(tab, didUpdateCallControls: controls)
        }
        context.engineFactory.documentPiPHandler = { [weak context] webView, size, activated in
            context.map { Self.prepareDocumentPiP(in: $0, webView: webView, size: size, userActivated: activated) } ?? false
        }
        context.engineFactory.notificationShownHandler = { [weak context] webView in
            guard let (window, engine) = context?.windows.windowAndEngine(for: webView),
                  window.tabManager.activeEngineTab !== engine,
                  window.tabManager.tab(for: engine.id)?.hasUnreadNotification == false,
                  let updated = window.updateRuntimeTab(id: engine.id, mutate: { $0.hasUnreadNotification = true })
            else { return }
            window.enqueueVisibleTabUpdate(updated)
        }

        // Register handlers that have no DB/extension dependencies
        bridgeRouter.register(handler: ChromeBridgeHandler(
            interactiveZoneStore: chromeInteractiveZones,
            windowController: self
        ))
        bridgeRouter.register(handler: TabBridgeHandler(
            tabManager: tabManager,
            windowController: self,
            // Weak capture: the userContentController retains this handler for the app's lifetime,
            // so a bound-method reference would close a retain cycle onto the window controller.
            stateCommandHandler: { [weak self] command in
                guard let self else {
                    throw NSError(
                        domain: "Lilo.TabBridge",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "window controller deallocated"]
                    )
                }
                return try self.applyBrowserCommand(command)
            }
        ))
        bridgeRouter.register(handler: TabShareBridgeHandler(resolve: { [weak self] requestId, choice in
            self?.resolveTabSharePicker(requestId: requestId, choice: choice)
        }))

        chromeWebView.configuration.userContentController.add(bridgeRouter, name: "lilo")

        // Lifecycle observers (and any initial Low-Power-Mode application) run before the bridge
        // exists, so deliver the current constrained-power state now that the chrome can receive it.
        if context.hiddenSpaceLifecycle.isConstrainedPower { sendPowerMode(true) }
        sendReduceTransparency()
    }

    func setupBridgeLate() {
        // Runs after bootstrap: the context's stores are open.
        let spaceManager: SpaceManager = context.spaceManager
        let settingsStore: SettingsStore = context.settingsStore
        let engineFactory = context.engineFactory

        bridgeRouter.register(handler: SpaceBridgeHandler(
            spaceManager: spaceManager,
            windowController: self
        ))

        bridgeRouter.register(handler: ProfileBridgeHandler(
            profileManager: context.profileManager,
            windowController: self
        ))

        bridgeRouter.register(handler: KeepAwakeBridgeHandler(powerKeeper: context.powerKeeper, bridgeRouter: bridgeRouter) { [weak self] in
            guard let self else { return }
            context.sentTerminalActivity[ObjectIdentifier(self)] = nil
            context.terminalActivityChanged()
        })

        bridgeRouter.register(handler: SearchBridgeHandler(
            historyStoreProvider: { [weak self] in self?.profileContext?.history },
            bridgeRouter: bridgeRouter,
            suggestionsEnabledProvider: { settingsStore.searchSuggestions },
            preconnect: { [weak self] url in self?.tabManager.activeEngineTab?.preconnect(to: url) },
            // Low Power Mode or a hot Mac: no page loads on a guess.
            preloadTopHit: { [weak self] url in
                guard let self else { return }
                tabManager.preloadTopHit(context.hiddenSpaceLifecycle.isConstrainedPower ? nil : url)
            }
        ))

        bridgeRouter.register(handler: HistoryPageBridgeHandler(
            profileContextProvider: { [weak self] in self?.profileContext },
            bridgeRouter: bridgeRouter
        ))

        // chrome.omnibox spans both bridges: the address bar sends omniboxInput* here, and the
        // extension's suggest()/setDefaultSuggestion replies arrive via the app-wide gap relay, which
        // routes each reply to the window owning its request.
        let omniboxHandler = OmniboxBridgeHandler(
            registryProvider: { [weak self] in self?.profileContext?.extensions },
            bridgeRouter: bridgeRouter
        )
        bridgeRouter.register(handler: omniboxHandler)
        OmniboxGapRelay.shared.add(omniboxHandler)

        let extensionUIHandler = ExtensionUIBridgeHandler(
            extensionRegistryProvider: { [weak self] in self?.profileContext?.extensions }
        )
        extensionUIHandler.onActionCompleted = { [weak self] id, action, success, error in
            var data: [String: Any] = ["id": id, "action": action, "success": success]
            if let error { data["error"] = error }
            self?.bridgeRouter.send(event: "extensionActionCompleted", data: data)
        }
        extensionUIHandler.onLoadUnpacked = { [weak self] in self?.loadUnpackedExtension(nil) }
        // Only a known profile: the cache would create a database for any other id.
        extensionUIHandler.profileRegistryProvider = { [weak self] profileId in
            guard let context = self?.context, context.profileManager?.profiles.contains(where: { $0.id == profileId }) == true else { return nil }
            return try? context.profileContexts.context(for: profileId).extensions
        }
        extensionUIHandler.onProfileExtensions = { [weak self] profileId, rows, live in
            self?.bridgeRouter.send(event: "profileExtensionsLoaded", data: ["profileId": profileId.uuidString, "extensions": rows, "live": live])
        }
        bridgeRouter.register(handler: extensionUIHandler)
        DebuggerBridgeHandler.shared.attach(to: bridgeRouter)

        bridgeRouter.register(handler: ProcessManagerBridgeHandler(
            browserStateStore: context.browserState,
            tabManager: tabManager,
            windowController: self,
            bridgeRouter: bridgeRouter
        ))

        let settingsHandler = SettingsBridgeHandler(
            settingsStore: settingsStore,
            sitePermissionStoreProvider: { [weak self] in self?.profileContext?.sitePermissions },
            zoomStoreProvider: { [weak self] in self?.profileContext?.zoom },
            historyStoreProvider: { [weak self] in self?.profileContext?.history },
            extensionRegistryProvider: { [weak self] in self?.profileContext?.extensions },
            // The profile's own store, never a private space's ephemeral one: the clear-data page acts on the profile.
            dataStoreProvider: { [weak self] in
                guard let self, let profileId = profileContext?.profileId else { return nil }
                return context.profileManager.dataStore(for: profileId)
            },
            lifecycleDiagnosticsProvider: { [weak self] in self?.context.browserState.lifecycleDiagnostics() },
            extensionDiagnosticsProvider: { [weak self] in self?.extensionDiagnosticsSnapshots() ?? [] },
            forceLifecycleTrimHandler: { [weak self] in self?.context.hiddenSpaceLifecycle.forceTrim() },
            bridgeRouter: bridgeRouter
        )
        bridgeRouter.register(handler: settingsHandler)
        bridgeRouter.register(handler: OnboardingBridgeHandler(settingsStore: settingsStore, bridgeRouter: bridgeRouter))
        bridgeRouter.register(handler: WhatsNewBridgeHandler(windowController: self))

        bridgeRouter.register(handler: ImportBridgeHandler(bridgeRouter: bridgeRouter, holdExtensionTabs: { [weak self] in
            self?.holdsExtensionTabsInBackground = $0
        }, makeImporter: { [weak self] in
            BrowserImporter(sink: .init(
                activeProfileId: { [weak self] in self?.profileContext?.profileId },
                activeSpaceId: { [weak self] in self?.tabManager.currentSpaceId },
                tree: { [weak self] spaceId in self?.context.browserState.space(id: spaceId)?.spaceTab.state.tree },
                apply: { [weak self] command in _ = try self?.applyBrowserCommand(command) },
                findProfile: { [weak self] name in self?.context.profileManager.profiles.first { $0.name == name }?.id },
                createProfile: { [weak self] name in
                    guard let self else { throw ImportError.malformed("window closed") }
                    return try self.context.profileManager.createProfile(name: name).id
                },
                findSpace: { name, profileId in spaceManager.spaces(for: profileId).first { $0.name == name }?.id },
                createSpace: { name, icon, color, profileId in
                    guard let color else { return try spaceManager.createSpace(name: name, icon: icon, profileId: profileId).id }
                    return try spaceManager.createSpace(name: name, icon: icon, color: color, profileId: profileId).id
                },
                loadSpaceState: { [weak self] spaceId, profileId in
                    guard let self, let pool = try? self.context.dbManager.pool(for: profileId) else { return nil }
                    return try? SpaceTabStateStore(dbPool: pool).load(spaceId: spaceId)
                },
                saveSpaceStates: { [weak self] states, profileId in
                    guard let self else { return }
                    // Space tab trees live in the owning profile's database (see SessionPersistence's tabDBPool).
                    try SpaceTabStateStore(dbPool: try self.context.dbManager.pool(for: profileId)).saveMany(states)
                },
                historyStore: { [weak self] profileId in
                    guard let self else { throw ImportError.malformed("window closed") }
                    if let store = self.context.profileContexts.existingContext(for: profileId)?.history { return store }
                    return HistoryStore(dbPool: try self.context.dbManager.pool(for: profileId))
                },
                faviconStore: { [weak self] profileId in
                    guard let self else { throw ImportError.malformed("window closed") }
                    return FaviconStore(dbPool: try self.context.dbManager.pool(for: profileId))
                },
                setCookies: { [weak self] cookies, profileId in
                    guard let self else { return }
                    let store = self.context.profileManager.dataStore(for: profileId).backingStore.httpCookieStore
                    // All writes are queued at once; WebKit applies them in order and we wait for the last.
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        let group = DispatchGroup()
                        for cookie in cookies {
                            group.enter()
                            store.setCookie(cookie) { group.leave() }
                        }
                        group.notify(queue: .main) { done.resume() }
                    }
                },
                installExtension: { [weak self] id, profileId in
                    // A profile no window shows gets its registry built; showing it later restores the rest beside this one.
                    guard let registry = try self?.context.profileContexts.context(for: profileId).extensions else {
                        throw ImportError.malformed("window closed")
                    }
                    let dir = try await ChromeWebStoreInstaller.downloadAndExtract(extensionId: id)
                    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
                    try await registry.load(from: dir)
                },
                // Ids of uninstalled extensions hold no slot, as in the address bar.
                pinnedExtensions: { [weak self] in
                    (settingsStore.get("pinnedExtensions") ?? "").split(separator: ",").map(String.init)
                        .filter { self?.profileContext?.extensions.context(for: $0) != nil }
                },
                // As the address bar pins: its menu updates and the extensions hear of it.
                pinExtensions: { ids in
                    let message = BridgeMessage(dictionary: ["action": "setSetting", "payload": ["key": "pinnedExtensions", "value": ids.joined(separator: ",")]])
                    if let message { _ = await settingsHandler.handle(message: message) }
                },
                otherBookmarksTitle: { String(format: "Other Bookmarks (%@)".localized, $0) },
                warmFavicons: { [weak self] entries in
                    entries.forEach { self?.context.faviconService.warmIfAbsent(host: $0.host, dataURL: $0.dataURL, dominantColor: $0.dominantColor) }
                }
            ))
        }))
        // As in Chrome, a revoked permission stops what the origin's pages in this profile use: capture, location watches.
        settingsHandler.onSitePermissionRevoked = { [weak self] origin, type in
            guard let self, let profileId = profileContext?.profileId else { return }
            let dataStore = context.profileManager.dataStore(for: profileId).backingStore
            if type == "location" { return context.engineFactory.revokeGeolocation(origin: origin, in: dataStore) }
            for tabId in context.browserState.allTabIds() {
                guard let webView = context.browserState.liveEngine(forTab: tabId)?.wkWebView, webView.configuration.websiteDataStore === dataStore,
                      let url = webView.url, let scheme = url.scheme, let host = url.host,
                      PermissionOriginKey.build(scheme: scheme, host: host, port: url.port ?? 0) == origin else { continue }
                if type.contains("camera"), webView.cameraCaptureState != .none { webView.setCameraCaptureState(.none) }
                if type.contains("microphone"), webView.microphoneCaptureState != .none { webView.setMicrophoneCaptureState(.none) }
            }
        }
        settingsHandler.onHistoryCleared = { [weak self] cutoff in
            guard let self, let profileId = profileContext?.profileId, let spaceManager = context.spaceManager else { return }
            context.recentlyClosed.removePages(closedSince: cutoff) { spaceManager.space(with: $0)?.profileId == profileId }
        }
        settingsHandler.onZoomLevelReset = { [weak self] host in
            guard let self, let engine = tabManager.activeEngineTab,
                  engine.currentURL?.host?.lowercased() == host.lowercased() else { return }
            engine.setPageZoom(settingsStore.defaultZoom)
            bridgeRouter.send(event: "zoomChanged", data: ["level": settingsStore.defaultZoom])
        }
        let deviceSetup = context.deviceSetupController
        settingsHandler.onAutoDeviceSwitchingChanged = { [weak deviceSetup] in deviceSetup?.enabledDidChange() }
        settingsHandler.deviceSetupState = { [weak deviceSetup] in deviceSetup?.bridgeState ?? [:] }
        settingsHandler.onForgetDeviceSetup = { [weak deviceSetup] in deviceSetup?.forgetCurrentSetup() }
        settingsHandler.onTogglePerfRecording = { [weak self] in self?.context.togglePerfRecording() }
        settingsHandler.onRecordShortcut = { [weak self] in self?.recordingShortcutId = $0 }
        settingsHandler.onContentBlockerToggled = { [weak self] enabled in
            guard let self else { return }
            engineFactory.applyBlockerChange(enabled: enabled)
            // Allowlist edits made while the blocker was off were never compiled.
            if enabled { Task { await engineFactory.rebuildBlocker(allowlist: settingsStore.blockerAllowlist) } }
            context.reloadBlockerExtension()
            if enabled, context.filterListService == nil {
                Task { await self.context.startContentBlocker() }
            }
        }
        settingsHandler.contentBlockerStatus = { [weak self] in self?.context.contentBlockerStatus ?? [:] }
        settingsHandler.onUpdateFilterLists = { [weak self] in await self?.context.updateFilterLists() }
        settingsHandler.agentControl = { [weak self] in self?.context.agentControl }
        settingsHandler.onBlockerAllowlistChanged = { [weak self] reloadTabId in
            Task {
                await engineFactory.rebuildBlocker(allowlist: settingsStore.blockerAllowlist)
                if let reloadTabId { self?.tabManager.engineTab(for: reloadTabId)?.reload() }
            }
            Task { await self?.context.filterListService?.installBlockerExtension() }
        }
        settingsHandler.onSendGPCChanged = { enabled in
            engineFactory.setGlobalPrivacyControl(enabled)
        }
        engineFactory.setGlobalPrivacyControl(settingsStore.sendGPC)
        settingsHandler.onTrackingPreventionChanged = { engineFactory.setTrackingPrevention($0) }
        settingsHandler.onHTTPSOnlyChanged = { enabled in
            engineFactory.setHTTPSOnly(enabled)
        }
        engineFactory.setHTTPSOnly(settingsStore.httpsOnly)
        settingsHandler.onMinimumFontSizeChanged = { engineFactory.setMinimumFontSize($0) }
        engineFactory.setMinimumFontSize(settingsStore.minimumFontSize)
        settingsHandler.onAutoplayPolicyChanged = { engineFactory.setAutoplayPolicy($0) }
        engineFactory.setAutoplayPolicy(settingsStore.get("autoplayPolicy") ?? "audio")
        settingsHandler.onTerminalSettingsChanged = { [weak self] in self?.applyTerminalSettings() }
        settingsHandler.terminalOptionsProvider = { [weak self] in self?.terminalOptions() ?? [:] }
        settingsHandler.terminalThemeImporter = { [weak self] in await self?.importTerminalTheme() ?? false }
        settingsHandler.onTabLayoutChanged = { [weak self] in self?.applyStoredTabLayoutEverywhere() }
        settingsHandler.onLifecyclePresetChanged = { [weak self] raw in
            guard let self else { return }
            self.context.applyLifecyclePreset(LifecyclePreset(rawValue: raw) ?? .default)
            // Reclaim promptly under the new (possibly tighter) policy.
            self.context.hiddenSpaceLifecycle.scheduleActiveSpaceTrim(delay: 0)
            self.context.hiddenSpaceLifecycle.scheduleTrim()
        }

        let featureFlagsHandler = FeatureFlagsBridgeHandler(
            settingsStore: settingsStore,
            bridgeRouter: bridgeRouter
        )
        bridgeRouter.register(handler: featureFlagsHandler)
        featureFlagsHandler.onOverridesChanged = { overrides in
            engineFactory.setFeatureFlagOverrides(overrides)
        }
        // Apply persisted feature flags to the engine at startup.
        engineFactory.setFeatureFlagOverrides(settingsStore.featureFlagOverrides)

        let downloadHandler = DownloadBridgeHandler(
            downloadManager: context.downloadManager,
            bridgeRouter: bridgeRouter,
            storeProvider: { [weak self] in self?.profileContext?.downloads }
        )
        downloadHandler.onQuickLookRequested = { QLPreviewPanel.shared().makeKeyAndOrderFront(nil) }
        downloadHandler.onDragRequested = { [weak self] url in self?.beginDownloadFileDrag(fileURL: url) }
        bridgeRouter.register(handler: downloadHandler)

        // A plain NSSavePanel: the "Copy" action lives in the Svelte editor overlay.
        let screenshotHandler = ScreenshotBridgeHandler(
            downloadsFolderProvider: { settingsStore.downloadsFolder },
            asksWhereToSave: { settingsStore.askDownloadLocation },
            writeFile: { data, url in try data.write(to: url) },
            presentSaveAs: { [weak self] suggestedName, data in
                // Next main-loop turn, with begin(completionHandler:) rather than runModal(): neither presents reliably from inside the
                // WKScriptMessage handler stack. Cancel leaves the editor open so the user can keep editing.
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.png]
                    panel.nameFieldStringValue = suggestedName
                    panel.begin { response in
                        guard response == .OK, let url = panel.url else { return }
                        do {
                            try data.write(to: url)
                            self?.bridgeRouter?.send(event: "screenshotSaved", data: ["path": url.path])
                        } catch {
                            self?.bridgeRouter?.send(
                                event: "screenshotError",
                                data: ["message": String(format: "Could not save the screenshot: %@".localized, error.localizedDescription)]
                            )
                        }
                    }
                }
            },
            copyToPasteboard: { data in
                // The PNG as is: an NSImage would also put a raw TIFF of the whole capture there.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(data, forType: .png)
            },
            onSaved: { [weak self] path in
                self?.bridgeRouter?.send(event: "screenshotSaved", data: ["path": path])
            },
            onError: { [weak self] message in
                self?.bridgeRouter?.send(event: "screenshotError", data: ["message": message])
            },
            capture: { ChromeUISchemeHandler.screenshot(id: $0) },
            discardCapture: { ChromeUISchemeHandler.discardScreenshot(id: $0) }
        )
        bridgeRouter.register(handler: screenshotHandler)

        bridgeRouter.register(handler: StateSyncBridgeHandler { [weak self] spaceId in
            guard let self else { return }
            guard let resolvedSpaceId = StateSyncBridgeHandler.resolvedSpaceId(
                requested: spaceId,
                isCached: { [weak self] id in self?.context.browserState.space(id: id) != nil },
                activeSpaceId: self.tabManager.currentSpaceId
            ) else { return }
            // A resync request means the chrome lost this space's state (fresh reload or a lost
            // delivery), so the response must ship favicons again.
            self.chromeFaviconSyncedSpaceIds.remove(resolvedSpaceId)
            self.emitSpaceBrowserChange(spaceId: resolvedSpaceId)
        })
    }

    // MARK: - Chrome UI Loading

    func loadChromeUI() {
        guard !didStartChromeUILoad else { return }
        didStartChromeUILoad = true

        installChromeBootstrapScript()

        chromeWebView.load(URLRequest(url: chromeUIDevServerURL() ?? ChromeUISchemeHandler.indexURL))
    }

    func chromeUIDevServerURL() -> URL? {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let rawValue = environment["LILO_UI_DEV_SERVER"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawValue.isEmpty else { return nil }

        let normalizedValue: String
        if rawValue.contains("://") {
            normalizedValue = rawValue
        } else {
            normalizedValue = "http://\(rawValue)"
        }

        guard let url = URL(string: normalizedValue),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            return nil
        }

        return url
        #else
        return nil
        #endif
    }

    func makeChromeInitialState() -> [String: Any] {
        let currentSpaceId = tabManager.currentSpaceId
        let currentTreeItems = currentSpaceId.map { tabManager.sidebarTreeItems(forSpace: $0) } ?? []
        var data: [String: Any] = [
            "tabs": currentSpaceId.map { tabManager.tabs(forSpace: $0).map(\.bridgeData) } ?? [],
            "folders": currentSpaceId.map { tabManager.folders(forSpace: $0).map(\.bridgeData) } ?? [],
            "treeItems": currentTreeItems.map(\.bridgeData),
            "activeTabId": tabManager.activeOpenTabId?.uuidString ?? "",
            "sidebarWidth": sidebarExpandedWidth,
            "sidebarVisible": sidebarVisible,
            "toolbarVisible": toolbarVisible,
            "trafficLightsVisible": areTrafficLightsVisible(),
            "tabPosition": tabLayout.position.rawValue,
            "addressPlacement": tabLayout.address.rawValue,
            "isFullscreen": window?.styleMask.contains(.fullScreen) == true
        ]
        if let color = currentWindowBackgroundCSSColor(), !color.isEmpty {
            data["windowBackgroundColor"] = color
        }
        if let spaceManager = context.spaceManager {
            data["spaces"] = spaceManager.spaces.map(\.bridgeData)
            data["activeSpaceId"] = tabManager.currentSpaceId?.uuidString ?? ""
        }
        data["profiles"] = context.profileManager.profiles.map(\.bridgeData)
        data["activeProfileId"] = context.profileManager.activeProfileId?.uuidString ?? ""
        data["extensions"] = profileContext?.extensions.extensionBridgePayloads(activeTab: tabManager.activeOpenTabId.flatMap { tabManager.tabAdapter(for: $0) }) ?? []
        data["tracingEnabled"] = StartupMetrics.tracingEnabled
        return data
    }

    func currentWindowBackgroundCSSColor() -> String? {
        let activeSpace = context.spaceManager?.space(with: tabManager.currentSpaceId)
        // A color that follows the time, page or wallpaper is only known to the UI: its last report stands in until the next.
        if activeSpace?.colorMode != Space.fixedColorMode, let storedWindowBackgroundColor { return storedWindowBackgroundColor }
        if let activeSpaceColor = Self.normalizedCSSColor(activeSpace?.color) {
            return Self.resolvedSidebarBackgroundCSSColor(accentColor: activeSpaceColor)
        }

        return storedWindowBackgroundColor
    }

    func installChromeBootstrapScript() {
        let controller = chromeWebView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(Self.buildBootstrapScript(
            sidebarWidth: sidebarExpandedWidth,
            windowBackgroundColor: storedWindowBackgroundColor ?? "",
            tabLayout: shownTabLayout
        ))
    }

    static func buildBootstrapScript(sidebarWidth: CGFloat, windowBackgroundColor: String, tabLayout: TabLayout) -> WKUserScript {
        let source = """
                (() => {
                    window.__liloBootstrapEvents = [];
                    const root = document.documentElement;
                    if (!root) {
                        return;
                    }

                    root.dataset.booting = 'true';
                    root.dataset.tabPosition = '\(tabLayout.position.rawValue)';
                    root.dataset.address = '\(tabLayout.address.rawValue)';

                    if (\(sidebarWidth) > 0) {
                        root.style.setProperty('--sidebar-width', `${\(sidebarWidth)}px`);
                    }

                    if ('\(windowBackgroundColor)') {
                        root.style.setProperty('--sidebar-bg', '\(windowBackgroundColor)');
                    }

                    window.webkit?.messageHandlers?.lilo?.postMessage({
                        action: 'ready',
                        payload: { at: performance.timeOrigin + performance.now() }
                    });
                })();
                """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    func dispatchChromeInitialStateIfPossible() {
        guard didCompleteSessionRestore, didReceiveChromeReady, !hasDispatchedChromeInitialState else { return }
        sendInitialState()
    }
}

// MARK: - Content Frame & Content View Management

extension MainWindowController {
    // MARK: - Content Frame

    var shownTabLayout: TabLayout { tabLayout.shown(toolbarVisible: toolbarVisible) }

    /// Right and bottom always keep a toolbar over the page: the traffic lights stay top-left.
    var hasPageToolbar: Bool {
        switch tabLayout.position {
        case .left: shownTabLayout.address == .page
        case .right, .bottom: true
        case .top: false
        }
    }

    /// Where the page sits, side panel excluded. Hidden tabs leave the page every edge but the address's own
    /// toolbar, which hides on its own; an overlay floats over it.
    func pageEdges() -> ContentEdges {
        var edges = ContentEdges.uniform(Self.contentInset)
        if tabLayout.canHideToolbar && toolbarVisible { edges.top = Self.pageToolbarHeight }
        guard sidebarVisible else { return edges }
        switch tabLayout.position {
        case .left: edges.left += sidebarWidth
        case .right: edges.right += sidebarWidth
        case .top: edges.top = Self.topStripHeight + (shownTabLayout.address == .page ? Self.pageToolbarHeight : 0)
        case .bottom: edges.bottom = Self.bottomDockHeight + Self.bottomDockMargin * 2
        }
        if hasPageToolbar { edges.top = Self.pageToolbarHeight }
        return edges
    }

    func contentEdges() -> ContentEdges {
        var edges = pageEdges()
        edges.right += sidePanel.reservedWidth
        return edges
    }

    func contentFrameRect() -> NSRect {
        guard let contentView = window?.contentView else { return .zero }
        let edges = contentEdges()
        return NSRect(
            x: edges.left,
            y: edges.bottom,
            width: max(0, contentView.bounds.width - edges.left - edges.right),
            height: max(0, contentView.bounds.height - edges.top - edges.bottom)
        )
    }

    func updateContentContainerFrame(animated: Bool) {
        tabDock.sidebarWidth = sidebarWidth
        tabDock.sidebarOnRight = tabLayout.position == .right
        let targetFrame = contentFrameRect()
        let edges = contentEdges()
        guard animated, let windowFrameView, let layer = contentContainerView.layer else {
            contentContainerView.layer?.removeAnimation(forKey: "sidebarSlide")
            contentContainerView.frame = targetFrame
            windowFrameView?.setEdges(edges, animated: false)
            return
        }

        // The opaque frame view sweeps as a curtain in sync with the tabs' slide, and the content
        // follows its edge with a layer translation. It takes the larger of both sizes on each axis at
        // once, so the new hole is never uncovered, and its exact size at the end; the curtain hides
        // whatever overhangs meanwhile.
        let current = contentContainerView.frame
        let inFlightOffset = (layer.presentation()?.value(forKeyPath: "transform.translation") as? NSValue)?.sizeValue ?? .zero
        let visibleOrigin = CGPoint(x: current.minX + inFlightOffset.width, y: current.minY + inFlightOffset.height)
        contentContainerView.frame = NSRect(
            origin: targetFrame.origin,
            size: NSSize(width: max(current.width, targetFrame.width), height: max(current.height, targetFrame.height))
        )
        let origin = contentContainerView.frame.origin
        let slide = CABasicAnimation(keyPath: "transform.translation")
        slide.fromValue = NSValue(size: NSSize(width: visibleOrigin.x - origin.x, height: visibleOrigin.y - origin.y))
        slide.toValue = NSValue(size: NSSize(width: targetFrame.minX - origin.x, height: targetFrame.minY - origin.y))
        slide.duration = WindowFrameView.toggleDuration
        slide.timingFunction = WindowFrameView.toggleTiming
        slide.fillMode = .forwards
        slide.isRemovedOnCompletion = false
        let slideId = UUID()
        slide.setValue(slideId, forKey: "slideID")
        layer.add(slide, forKey: "sidebarSlide")
        windowFrameView.setEdges(edges, animated: true) { [weak self] in
            // A re-toggle mid-animation fires this completion early; the newer toggle owns the slide then.
            guard let self, let layer = contentContainerView.layer,
                  layer.animation(forKey: "sidebarSlide")?.value(forKey: "slideID") as? UUID == slideId else { return }
            contentContainerView.frame = contentFrameRect()
            layer.removeAnimation(forKey: "sidebarSlide")
        }
    }

    // MARK: - Content View Management

    /// The bar over the page takes the active page's color, drawn with the frame so it slides with the page exactly.
    /// A page loading before it has one shows the surface under it, which the bar takes meanwhile.
    func syncPageBar() {
        let tab = tabManager.activeTab
        let colors = tab?.pageColor?.split(separator: ",").compactMap { NSColor(cssHex: String($0))?.cgColor } ?? []
        let loading = tab?.kind == .web && tab?.url != nil
        windowFrameView?.setBarColors(colors.isEmpty ? (loading ? [currentContentSurfaceColor.cgColor] : nil) : colors)
    }

    func showContentView(for engine: WKWebViewTab) {
        let nextView = engine.view
        // A freshly created engine otherwise paints WebKit's default white in the gap before content
        // commits, which reads as a broken tab.
        engine.applyPageBackgroundColor(currentContentSurfaceColor)
        engine.restoreFromAutoPictureInPicture()  // a tab auto-PiP'd on leaving comes back inline
        floatingTabPanel.dismiss(hosting: engine.id)
        if tabDock.engineId == engine.id { tabDock.undock() }
        if awaitingDocumentPiP === engine { awaitingDocumentPiP = nil }
        if documentPiP.openerId == engine.id {
            if documentPiP.wasAutoEntered { documentPiP.close() } else { placeDocumentPiP() }
        }
        chromeInput.setContentView(nextView)
        syncPageBar()
        let retainedSplitViews = splitPanes.retainedViews(forTabId: engine.id)
        let outgoingViews = contentContainerView.subviews.filter { view in view !== nextView && !retainedSplitViews.contains { $0 === view } }

        // A split pane joins the container in layoutSplitContent, already at its pane frame.
        let isSplitPane = tabManager.activeSplit?.layout.paneIds.contains(engine.id) == true
        if !engine.shouldRetainForWebInspector && !isSplitPane {
            engine.fitView(in: contentContainerView.bounds)
        }
        // Agent tabs stay shown in the container, under the shown tab or attached below it: an incoming
        // view already there may sit under the outgoing one, so it goes on top.
        if !isSplitPane, contentContainerView.subviews.last !== nextView {
            contentContainerView.addSubview(nextView, positioned: .above, relativeTo: nil)
        }
        (contentContainerView as? ContentContainerView)?.updateStage(under: nextView, fixedSize: !isSplitPane && engine.agentViewport != nil)

        processOutgoingContentViews(outgoingViews)
        nextView.isHidden = false
        if tabManager.tab(for: engine.id)?.hasUnreadNotification == true {
            enqueueVisibleTabUpdate(updateRuntimeTab(id: engine.id) { $0.hasUnreadNotification = false })
        }
        // After outgoing views are hidden or removed, so the watcher check sees final visibility.
        context.engineFactory.reevaluateGeolocationWatchers()
        layoutSplitContent()
        StartupMetrics.markOnce("firstContentViewShown")
        // An agent tab may live in another profile than this window's: its zoom stays what the agent measures with.
        if !engine.isAgentControlled {
            profileContext?.zoom.applyZoom(to: engine, forURL: engine.currentURL, default: context.settingsStore.defaultZoom)
        }
    }

    /// Keep a backgrounded tab watchable. A call pops out whole (tiles and controls) into the floating
    /// panel; playback keeps the system PiP window, the better surface for a single video. Returns true
    /// when the view moved into the panel and must be left where it is.
    @discardableResult
    func popOutBackgroundedTab(_ engine: WKWebViewTab) -> Bool {
        // A tab-share source stays attached under the active view (retained below): the ferry
        // needs the full-size page layout, which a panel-sized reparent would destroy.
        if engine.isTabShareSource || engine.isAgentControlled { return false }
        // Its page's own PiP window stands in for the whole page.
        if documentPiP.openerId == engine.id {
            placeDocumentPiP()
            return false
        }
        guard context.settingsStore.autoPictureInPicture else { return false }
        if engine.isInCall, engine.callControls.hasPictureInPictureAction, !engine.shouldRetainForWebInspector {
            autoEnterDocumentPiP(engine)
            return false
        }
        return popOutWholePage(engine)
    }

    /// The whole page in the sidebar dock or the floating panel, for a call; the system PiP window for playback.
    @discardableResult
    func popOutWholePage(_ engine: WKWebViewTab) -> Bool {
        if engine.isInCall, !engine.shouldRetainForWebInspector, NSApp.isActive {
            dockInCallTab(engine)
            return true
        }
        guard engine.isInCall, !engine.shouldRetainForWebInspector else {
            engine.autoEnterPictureInPictureIfEligible()
            return false
        }
        floatingTabPanel.float(engine)
        return true
    }

    func processOutgoingContentViews(_ outgoingViews: [NSView]) {
        for view in outgoingViews {
            // A terminal leaves the window; its shell keeps running in TerminalHost.
            if view is TerminalView || view is ChangesView {
                view.removeFromSuperview()
                continue
            }
            guard let webView = view as? WKWebView else {
                view.isHidden = false
                continue
            }

            guard let outgoingEngine = tabManager.engineTab(forWebView: webView) else {
                // Web Inspector views are WKWebView subclasses with no engine tab of their own;
                // they stay attached and shown under the incoming view, never torn out of the hierarchy.
                if String(describing: type(of: webView)).contains("Inspector") {
                    view.isHidden = false
                    continue
                }
                view.removeFromSuperview()
                continue
            }

            if popOutBackgroundedTab(outgoingEngine) { continue }

            // Tab-share sources, agent tabs and the page of a PiP window (open or on its way) stay in-window like
            // inspector-retained views: WebKit keeps rendering a covered view, which the frame ferry snapshots and
            // the PiP window's page needs to draw it.
            let drawsPiP = documentPiP.openerId == outgoingEngine.id || awaitingDocumentPiP === outgoingEngine
            guard outgoingEngine.shouldRetainForWebInspector || outgoingEngine.isTabShareSource || outgoingEngine.isAgentControlled || drawsPiP else {
                view.removeFromSuperview()
                continue
            }

            // WebKit renders a covered visible view at full rate, so only an open inspector, a share, an agent or a
            // PiP window keeps it shown.
            view.isHidden = !outgoingEngine.isWebInspectorVisible && !outgoingEngine.isTabShareSource && !outgoingEngine.isAgentControlled && !drawsPiP
            if !outgoingEngine.isWebInspectorVisible { outgoingEngine.fitView(in: contentContainerView.bounds) }
        }
    }
}

// MARK: - Profile changes

// Relayed by the browser context, which is the single ProfileManager delegate.
extension MainWindowController {
    func profileWasCreated(_ profile: Profile) {
        bridgeRouter?.send(event: "profileCreated", data: profile.bridgeData)
    }

    func profileWasDeleted(_ profile: Profile) {
        bridgeRouter?.send(event: "profileDeleted", data: ["id": profile.id.uuidString])
    }

    func profileWasUpdated(_ profile: Profile) {
        bridgeRouter?.send(event: "profileUpdated", data: profile.bridgeData)
    }

    func profileWasActivated(_ id: UUID) {
        bridgeRouter?.send(event: "profileActivated", data: ["id": id.uuidString])
    }
}
