// Extension system, content scripts, popups.

import AppKit
import WebKit

// MARK: - Extension Context

extension MainWindowController {
    func setupExtensions() {
        // Shared by every window: extensions act on the window the user works in.
        context.engineFactory.tabGroupsContextProvider = { [weak context] registry in
            guard let window = context?.windows.window(showingProfileOf: registry) else { return nil }
            return TabGroupsContext(
                tabManager: window.tabManager,
                applyCommand: { [weak window] command in
                    guard let window else {
                        throw NSError(domain: "Lilo.TabGroups", code: 0, userInfo: [NSLocalizedDescriptionKey: "Window gone"])
                    }
                    return try window.applyBrowserCommand(command)
                }
            )
        }
        // chrome.contentSettings reads the user's own choice for the types Lilo asks about.
        context.engineFactory.contentSettingsHandler.userSetting = { [weak context] registry, type, origin in
            guard let context, ["camera", "microphone", "location", "notifications"].contains(type) else { return nil }
            if let decision = context.profileContexts.existingContext(for: registry.profileId)?.sitePermissions.decision(forOrigin: origin, type: type) {
                return decision ? "allow" : "block"
            }
            return context.settingsStore.refusesPermissionRequests(type) ? "block" : nil
        }
        context.engineFactory.sessionsContextProvider = { [weak context] registry in
            guard let context, let window = context.windows.window(showingProfileOf: registry) else { return nil }
            return SessionsContext(
                recentlyClosed: context.recentlyClosed.recentEntries.filter(window.isVisibleToExtensions),
                restore: { [weak window] index in window?.restoreClosedTabForExtension(at: index) }
            )
        }
    }

    /// The cached registry whose profile has `extensionId` loaded. Used to address app-level events
    /// (e.g. a notification click handled by AppDelegate) to the right profile.
    func registryOwning(extensionId: String) -> ProfileExtensionRegistry? {
        context.profileContexts.allContexts
            .first { $0.extensions.loadedExtensions.contains { $0.id == extensionId } }?
            .extensions
    }

    /// Presents a folder picker and loads the chosen directory as an unpacked extension (must
    /// contain manifest.json), with the same install-consent dialog as any other install. Reached
    /// from the Develop menu and the Extensions panel button.
    @objc func loadUnpackedExtension(_ sender: Any?) {
        guard let registry = profileContext?.extensions, let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Load".localized
        panel.message = "Select an unpacked extension folder (must contain manifest.json)".localized
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let review = try ExtensionInstallReview.load(from: url)
                    guard review.confirmInstall() else { return }
                    try await registry.load(from: url)
                } catch {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Couldn't load extension".localized
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: "OK".localized)
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - Internal wiring

    /// Points the tab manager and `registry`'s delegate at each other on every space or profile activation, so a cached registry
    /// restores a coherent window. Each space is its own extension window; a private one is seen only by extensions allowed there.
    func bindExtensionRegistry(_ registry: ProfileExtensionRegistry, spaceId: UUID) {
        guard let window else { return }
        let windowAdapter = registry.windowAdapter(for: window, spaceId: spaceId, isPrivate: tabManager.dataStore?.backingStore.isPersistent == false)
        windowAdapter.tabManager = tabManager
        tabManager.windowAdapter = windowAdapter

        registry.delegate.tabManager = tabManager
        registry.delegate.windowController = self
        registry.delegate.windows = context.windows
        tabManager.extensionRegistry = registry
        registry.onExtensionsChanged = { [weak context, weak registry] in
            context?.windows.windows.forEach { if $0.profileContext?.extensions === registry { $0.sendExtensionsChangedEvent() } }
        }

        // Another profile's prompts here are denied and closed, so its extensions never wait on a profile the window left.
        for profile in context.profileContexts.allContexts where profile.extensions !== registry {
            for id in profile.extensions.denyPermissionRequests(shownIn: self) {
                bridgeRouter?.send(event: "permissionRequestClosed", data: ["requestId": id])
            }
        }

        registry.notifyWindowOpened()
        // A space or profile switch keeps the same NSWindow key, so windowDidBecomeKey doesn't re-fire: focus
        // the space's window explicitly, which extensions hear as a window focus change.
        registry.notifyWindowFocused(window.isKeyWindow)
    }

    // MARK: - Bridge Events

    /// Ships the full id list plus only the rows that changed since the last send; a row whose icon is
    /// unchanged leaves `iconDataURL` out and the chrome keeps the one it holds.
    func sendExtensionsChangedEvent() {
        guard let bridgeRouter else { return }
        let registry = profileContext?.extensions
        let rows = registry?.extensionBridgePayloads(activeTab: tabManager.activeOpenTabId.flatMap { tabManager.tabAdapter(for: $0) }) ?? []
        var ids: [String] = []
        var changed: [[String: Any]] = []
        var sent: [String: [String: Any]] = [:]
        ids.reserveCapacity(rows.count)
        for row in rows {
            guard let id = row["id"] as? String else { continue }
            ids.append(id)
            sent[id] = row
            guard let previous = sentExtensionRows[id] else {
                changed.append(row)
                continue
            }
            guard previous["rowVersion"] as? Int != row["rowVersion"] as? Int else { continue }
            var delta = row
            if let icon = row["iconDataURL"] as? String, icon == previous["iconDataURL"] as? String {
                delta["iconDataURL"] = nil
            }
            changed.append(delta)
        }
        sentExtensionRows = sent
        bridgeRouter.send(event: "extensionsChanged", data: [
            "ids": ids,
            "extensions": changed,
            "updateCheck": registry?.updater.status ?? [:],
            "downloadUiEnabled": registry?.downloadUiDisabledBy.isEmpty ?? true
        ])
    }

    // MARK: - Extension Context Menu

    /// `pinned` is nil where pinning does not apply (the settings list), else the address-bar pin state.
    /// The settings name `profileId` for a profile the window does not show: its options open in no tab here.
    func showExtensionContextMenu(extensionId: String, anchorRect: NSRect?, pinned: Bool? = nil, profileId: UUID? = nil) {
        let menu = NSMenu()
        let context = profileId == nil || profileId == profileContext?.profileId ? profileContext?.extensions.context(for: extensionId) : nil
        // The extension's own action menu (contextMenus with the "action" context) leads, as in Chrome.
        if pinned != nil, let adapter = tabManager.activeOpenTabId.flatMap({ tabManager.tabAdapter(for: $0) }),
           let actionItems = context?.action(for: adapter)?.menuItems, !actionItems.isEmpty {
            profileContext?.extensions.noteUserGestures(choosing: actionItems, extensionId: extensionId)
            for item in actionItems { menu.addItem(item) }
            menu.addItem(.separator())
        }
        let send = { (action: String) in self.bridgeRouter?.send(event: "extensionMenuAction", data: ["id": extensionId, "action": action]) }
        if let pinned {
            menu.addItem((pinned ? "Unpin from Address Bar" : "Pin to Address Bar").localized, icon: pinned ? .unpin : .pin) { send("togglePin") }
        }
        menu.addItem("Details".localized, icon: .details) { send("details") }
        if let url = context?.optionsPageURL {
            menu.addItem("Options".localized, icon: .options) { self.createTabStateFirst(url: url, activate: true) }
        }
        menu.addItem(.separator())
        menu.addItem("Remove…".localized, icon: .delete) { send("remove") }

        presentContextMenu(menu, anchorRect: anchorRect)
    }

    func extensionDiagnosticsSnapshots() -> [[String: Any]] {
        context.profileContexts.allContexts.flatMap { $0.extensions.backgroundDiagnosticsSnapshots() }
    }

    func sendExtensionPermissionRequest(
        requestId: String,
        extensionId: String,
        extensionName: String,
        permissions: [String],
        origins: [String],
        type: String
    ) {
        bridgeRouter?.send(event: "extensionPermissionRequested", data: [
            "requestId": requestId,
            "extensionId": extensionId,
            "extensionName": extensionName,
            "permissions": permissions,
            "origins": origins,
            "type": type
        ])
    }

    /// Resolves through the registry that asked, only for a prompt this window shows.
    func resolveExtensionPermissionRequest(requestId: String, granted: Bool) {
        context.profileContexts.allContexts
            .first { $0.extensions.permissionPromptWindows.object(forKey: requestId as NSString) === self }?
            .extensions.resolvePermissionRequest(id: requestId, granted: granted)
    }

    // MARK: - Engine Configuration

    func configureEngineIfNeeded(_ engine: WKWebViewTab) {
        // Navigation, dialogs and permission prompts go to the window that shows the page.
        engine.delegate = self
        engine.tabManager = tabManager
        engine.popupWebViewProvider = { [weak self, weak engine] configuration, navigationAction, features in
            guard let self else { return nil }
            return createPopupWebView(
                configuration: configuration, requestedURL: navigationAction.request.url, features: features, opener: engine,
                inBackground: WKWebViewTab.opensNewTabInBackground(navigationAction, after: lastClick)
            )
        }
        engine.documentPiPWebViewProvider = { [weak self, weak engine] configuration, size in
            guard let self, let engine else { return nil }
            let webView = documentPiP.open(configuration: configuration, size: size, opener: engine)
            context.browserState.pictureInPictureOpenerIds.insert(engine.id)
            if awaitingDocumentPiP === engine {
                awaitingDocumentPiP = nil
                documentPiP.wasAutoEntered = true
                // A late answer: the whole page already went to the dock or the panel. It comes back under the shown
                // tab, where it keeps drawing its PiP window.
                floatingTabPanel.dismiss(hosting: engine.id)
                if tabDock.engineId == engine.id { tabDock.undock() }
                if engine.view.superview == nil, tabManager.activeOpenTabId != engine.id {
                    engine.fitView(in: contentContainerView.bounds)
                    contentContainerView.addSubview(engine.view, positioned: .below, relativeTo: nil)
                }
            }
            placeDocumentPiP()
            return webView
        }
    }

    /// Detached popups that WebKit released without a `window.close()`, so their close handlers
    /// can be dropped from `popupCloseHandlersByWebViewId`.
    private static let liveDetachedPopupWebViews = NSHashTable<WKWebView>.weakObjects()
    /// Content controllers already carrying the close bridge. The popup configuration shares its
    /// opener's controller, so installing per popup would stack one more script on every page using it.
    private static let popupCloseBridgeControllers = NSHashTable<WKUserContentController>.weakObjects()

    /// A popup that becomes a tab closes through WebKit's own `webViewDidClose`; only a detached
    /// extension popup, which has no UI delegate, needs the `window.close()` bridge.
    func createPopupWebView(
        configuration: WKWebViewConfiguration,
        requestedURL: URL?,
        features: WKWindowFeatures? = nil,
        opener: WKWebViewTab? = nil,
        inBackground: Bool = false
    ) -> WKWebView? {
        if Self.shouldCreateDetachedExtensionPopup(for: requestedURL) {
            installPopupCloseBridge(on: configuration.userContentController)
            let webView = WKWebView(frame: .zero, configuration: configuration)
            let webViewId = ObjectIdentifier(webView)
            let liveIds = Set(Self.liveDetachedPopupWebViews.allObjects.map { ObjectIdentifier($0) })
            popupCloseHandlersByWebViewId = popupCloseHandlersByWebViewId.filter { liveIds.contains($0.key) }
            Self.liveDetachedPopupWebViews.add(webView)
            popupCloseHandlersByWebViewId[webViewId] = { [weak self, weak webView] in
                webView?.stopLoading()
                self?.popupCloseHandlersByWebViewId.removeValue(forKey: webViewId)
            }
            return webView
        }

        if let features, let opener, Self.requestsPopup(features) {
            return openPagePopup(configuration: configuration, features: features, opener: opener)
        }

        // A Little window's new tab is another Little window, never a tab of the window behind.
        if let opener, let little = littleWindows[opener.id] {
            return openLittleWindow(url: requestedURL, opener: little, configuration: configuration)?.engine.wkWebView
        }

        guard let popupTab = createTabStateFirst(
            url: requestedURL,
            activate: !inBackground,
            nativeConfiguration: configuration
        ) else { return nil }
        if inBackground { noteBackgroundTab(popupTab.id) }
        guard let popupEngine = tabManager.engineTab(for: popupTab.id) else { return nil }
        popupEngine.isOpenedByPage = true
        configureEngineIfNeeded(popupEngine)
        return popupEngine.view as? WKWebView
    }

    static func shouldCreateDetachedExtensionPopup(for requestedURL: URL?) -> Bool {
        requestedURL?.scheme?.lowercased() == "chrome-extension"
    }

    /// The close handler lives in its own world: one in the page world gives every page of the controller `window.webkit`.
    private static let popupCloseWorld = WKContentWorld.world(name: "lilo-popup-close")
    /// Random per launch: the event an extension page's window.close dispatches for `popupCloseWorld` to post.
    private static let popupCloseEvent = "lilo-close-" + UUID().uuidString

    func installPopupCloseBridge(on userContentController: WKUserContentController) {
        guard !Self.popupCloseBridgeControllers.contains(userContentController) else { return }
        Self.popupCloseBridgeControllers.add(userContentController)
        let nativeCloseScript = WKUserScript(
            source: #"""
            (() => {
                // The controller may be a regular tab's (an extension URL opened from a page): its
                // pages keep WebKit's own window.close.
                if (!/^(webkit|chrome)-extension:$/.test(location.protocol)) return;
                if (window.__liloNativePopupCloseInstalled) return;
                window.__liloNativePopupCloseInstalled = true;

                const closePopup = () => {
                    window.__liloPageClosing?.();
                    document.dispatchEvent(new CustomEvent('\#(Self.popupCloseEvent)'));
                };

                window.close = closePopup;
                globalThis.close = closePopup;
            })();
            """#,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        let relayScript = WKUserScript(
            source: #"""
            if (/^(webkit|chrome)-extension:$/.test(location.protocol)) {
                document.addEventListener('\#(Self.popupCloseEvent)', () => {
                    window.webkit.messageHandlers.liloPopupHost.postMessage({ command: 'close' });
                });
            }
            """#,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: Self.popupCloseWorld
        )

        userContentController.removeScriptMessageHandler(forName: "liloPopupHost", contentWorld: Self.popupCloseWorld)
        userContentController.addUserScript(nativeCloseScript)
        userContentController.addUserScript(relayScript)
        userContentController.add(PopupCloseScriptHandler(windows: context.windows), contentWorld: Self.popupCloseWorld, name: "liloPopupHost")
    }
}
