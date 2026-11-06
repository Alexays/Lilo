import AppKit
import WebKit
import os

@MainActor
final class ExtensionControllerDelegate: NSObject, WKWebExtensionControllerDelegate, NSPopoverDelegate {
    private static let logger = Logger(liloCategory: "extension-delegate")

    weak var windowAdapter: WindowExtensionAdapter?
    weak var tabManager: TabManager?
    weak var registry: ProfileExtensionRegistry?
    weak var windowController: MainWindowController?
    /// Every browser window: prompts and options pages open in one showing this profile.
    weak var windows: WindowRegistry?
    /// Button rect in CSS/bridge coordinates (origin top-left). Set before calling performAction(for:).
    var pendingPopupAnchorRect: NSRect?
    private var popupAnchorRectsByExtensionId: [String: NSRect] = [:]
    private struct PopupPresentation {
        weak var popover: NSPopover?
        let action: WKWebExtension.Action
    }
    private var popupPresentationsByPopoverId: [ObjectIdentifier: PopupPresentation] = [:]
    /// True while an action popup popover is on screen. The window controller uses this to keep
    /// reporting the main window as focused while the popover holds key status.
    var hasOpenActionPopover: Bool { !popupPresentationsByPopoverId.isEmpty }
    /// Live chrome.windows.create popups (small windows) in opening order, retained until they close.
    private var windowPopups: [ExtensionPopupWindow] = []
    /// The extension windows of those popups, which contexts loaded after them must know too.
    var popupWindowAdapters: [WindowExtensionAdapter] { windowPopups.map(\.windowAdapter) }

    /// An import's extensions open welcome pages as they start: they must not take the window from the onboarding card.
    private var opensTabsInBackground: Bool {
        windows?.windows.contains(where: \.holdsExtensionTabsInBackground) == true
    }

    private var sidePanelWebViews: [WKWebView] {
        windows?.windows.compactMap { $0.profileContext?.extensions === registry ? $0.sidePanel.webView : nil } ?? []
    }

    /// The extension's pages on screen outside browser tabs, for `runtime.getContexts`: its action
    /// popup, its side panels and the windows it opened with `windows.create`, which hold a tab.
    func extensionViews(of context: WKWebExtensionContext) -> [(contextType: String, url: URL)] {
        let host = context.baseURL.host?.lowercased()
        let popups = popupPresentationsByPopoverId.values
            .filter { $0.action.webExtensionContext === context }
            .compactMap { $0.action.popupWebView?.url }
            .map { (contextType: "POPUP", url: $0) }
        let panels = sidePanelWebViews.compactMap(\.url).filter { $0.host?.lowercased() == host }
            .map { (contextType: "SIDE_PANEL", url: $0) }
        let windows = windowPopups.compactMap { popup -> (contextType: String, url: URL)? in
            guard let url = popup.webView.url, url.host?.lowercased() == host else { return nil }
            return ("TAB", url)
        }
        return popups + panels + windows
    }

    static func extensionError(_ message: String, code: Int = 0) -> NSError {
        NSError(domain: "LiloExtension", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func closeOpenActionPopups(reason: String, extensionId: String?) {
        guard !popupPresentationsByPopoverId.isEmpty else { return }
        let presentations = popupPresentationsByPopoverId.values
        popupPresentationsByPopoverId.removeAll()
        extensionId.map {
            registry?.recordExtensionNativeDiagnostic(
                extensionId: $0,
                level: "info",
                source: "popup.closePrevious",
                message: "Closing previous popup before new action: \(reason)"
            )
        }
        presentations.forEach { presentation in
            presentation.popover?.performClose(nil as Any?)
            presentation.action.closePopup()
        }
    }

    /// Closes the extension's popup when one is on screen, as a second click on its button does. True when one was.
    func closeActionPopup(of extensionId: String) -> Bool {
        guard let shown = popupPresentationsByPopoverId.first(where: {
            $0.value.action.webExtensionContext?.uniqueIdentifier == extensionId
        }) else { return false }
        popupPresentationsByPopoverId[shown.key] = nil
        shown.value.popover?.performClose(nil as Any?)
        shown.value.action.closePopup()
        return true
    }

    /// Closes the context's popups at once, before it unloads: WebKit's popover crashes when it finishes
    /// closing after its context left (WEBKIT-GAPS.md, gap 75).
    func closeActionPopups(of context: WKWebExtensionContext) {
        for (id, presentation) in popupPresentationsByPopoverId where presentation.action.webExtensionContext === context {
            popupPresentationsByPopoverId[id] = nil
            presentation.popover?.animates = false
            presentation.popover?.close()
        }
    }

    // MARK: - Windows

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor context: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        registry?.extensionWindows ?? windowAdapter.map { [$0] } ?? []
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor context: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        windowAdapter
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, Error?) -> Void
    ) {
        guard !configuration.shouldBePrivate || context.hasAccessToPrivateData else {
            completionHandler(nil, Self.extensionError("Extension does not have permission for incognito mode")); return
        }
        // With "Prefer a single window" on, a normal window's tabs open in the current space, unless private, whose window it
        // returns; any other window is a floating panel of its own, so its id never names a window or space of the user's.
        if configuration.windowType == .normal, !configuration.shouldBePrivate,
           let windowController, windowController.prefersSingleWindow, let spaceWindow = windowController.tabManager.windowAdapter,
           !spaceWindow.isPrivateWindow {
            let urls = configuration.tabURLs.isEmpty ? [windowController.profileContext?.extensions.activeNewTabOverrideURL] : configuration.tabURLs.map(Optional.some)
            for (index, url) in urls.enumerated() {
                guard let tab = windowController.createTabStateFirst(url: url, activate: index == 0 && configuration.shouldBeFocused) else { continue }
                spaceWindow.tabIdsOpenedAsWindow.append(tab.id)
            }
            completionHandler(spaceWindow, nil)
            return
        }
        let windowAdapter = presentExtensionPanel(
            url: configuration.tabURLs.first,
            type: configuration.windowType,
            isPrivate: configuration.shouldBePrivate,
            for: context,
            controller: controller,
            size: Self.popupSize(from: configuration.frame)
        )
        if let windowAdapter {
            // `focused: false` hands key status back to the browser window the panel took it from.
            if !configuration.shouldBeFocused { windowController?.window?.makeKeyAndOrderFront(nil) }
            completionHandler(windowAdapter, nil)
        } else {
            completionHandler(nil, Self.extensionError("No active profile"))
        }
    }

    /// Presents an extension URL in a floating mini window hosting a single extension-managed tab;
    /// returns the WKWebExtensionWindow for the extension to track.
    @discardableResult
    func presentExtensionPanel(
        url: URL?,
        type: WKWebExtension.WindowType,
        isPrivate: Bool,
        for context: WKWebExtensionContext,
        controller: WKWebExtensionController,
        size: NSSize
    ) -> WindowExtensionAdapter? {
        guard let profileId = registry?.profileId else { return nil }

        // The extension's configuration loads nothing but its own pages: a web page needs a tab's, in the profile's
        // store or, private, in a store of its own that goes with the panel.
        let isWebPage = url?.scheme?.lowercased() != "chrome-extension"
        let factory = windowController?.context.engineFactory
        let privateStore = isPrivate && isWebPage ? factory?.createDataStore(persistent: false, identifier: nil) : nil
        let engineTab = if isWebPage, let windowController {
            windowController.context.engineFactory.createTab(configuration: .init(
                dataStore: privateStore ?? windowController.context.profileManager?.dataStore(for: profileId),
                tabId: nil, nativeConfiguration: nil, profileId: profileId
            ))
        } else {
            WKWebViewTab(webView: PageWebView(frame: .zero, configuration: context.pageWebViewConfiguration ?? WKWebViewConfiguration()))
        }
        let webView = engineTab.wkWebView

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.contentView = webView
        panel.isReleasedWhenClosed = false

        let windowAdapter = WindowExtensionAdapter(nsWindow: panel, type: type, isPrivate: isPrivate)
        windowAdapter.tabManager = tabManager
        let tabAdapter = TabExtensionAdapter(engineTab: engineTab, extensionWindow: windowAdapter, profileId: profileId)
        tabAdapter.tabManager = tabManager
        windowAdapter.add(tab: tabAdapter)
        windowAdapter.activeAdapter = tabAdapter

        let popup = ExtensionPopupWindow(panel: panel, webView: webView, engineTab: engineTab,
                                         windowAdapter: windowAdapter, tabAdapter: tabAdapter)
        popup.onClose = { [weak self, weak controller, weak popup] in
            guard let self, let popup else { return }
            self.windowPopups.removeAll { $0 === popup }
            if let privateStore { factory?.releaseContentController(for: privateStore) }
            controller?.didCloseWindow(windowAdapter)
        }
        windowPopups.append(popup)

        if let url { engineTab.loadURL(url) }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        controller.didOpenWindow(windowAdapter)
        return windowAdapter
    }

    /// Clamps a requested popup frame to a sane floating size, defaulting when unspecified (NaN).
    private static func popupSize(from frame: CGRect) -> NSSize {
        let width = frame.width.isFinite && frame.width > 0 ? frame.width : 480
        let height = frame.height.isFinite && frame.height > 0 ? frame.height : 640
        return NSSize(width: min(max(width, 320), 1200), height: min(max(height, 240), 1000))
    }

    // MARK: - Tabs

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void
    ) {
        // The tab opens in a space's window the context sees: the one asked for, else the focused one, else the one it saw last.
        let isExtensionPage = configuration.url?.scheme?.lowercased() == "chrome-extension"
        let admits = { (window: WindowExtensionAdapter) in Self.admits(window, extensionPage: isExtensionPage, context: context) }
        guard let space = [configuration.window as? WindowExtensionAdapter, windowAdapter].compactMap({ $0 }).first(where: admits)
                ?? registry?.extensionWindows(for: context).first(where: admits),
              let (target, tab) = openTab(
                  url: configuration.url, activate: configuration.shouldBeActive, in: space, for: context,
                  opener: (configuration.parentTab as? TabExtensionAdapter)?.tabId,
                  index: configuration.shouldBePinned ? nil : configuration.index
              ) else {
            completionHandler(nil, Self.extensionError("Window controller not available")); return
        }
        if configuration.shouldBePinned, let spaceId = space.spaceId {
            _ = try? target.applyBrowserCommand(.setPinned(spaceId: spaceId, tabId: tab.id, isPinned: true))
        }
        if configuration.shouldBeMuted { target.tabManager.setTabMuted(id: tab.id, muted: true) }
        guard let adapter = target.tabManager.tabAdapter(for: tab.id) else {
            completionHandler(nil, Self.extensionError("Tab adapter not found after creation")); return
        }
        adapter.parent = configuration.parentTab as? TabExtensionAdapter
        completionHandler(adapter, nil)
    }

    /// Whether a tab of `context` may open in `window`'s space. An extension page never opens in a private one: its
    /// configuration keeps the profile's store, not the space's.
    private static func admits(_ window: WindowExtensionAdapter, extensionPage: Bool, context: WKWebExtensionContext) -> Bool {
        window.spaceId != nil && (!window.isPrivateWindow || context.hasAccessToPrivateData && !extensionPage)
    }

    /// The browser window for `spaceId`: one showing it, else the one that showed it last, else one of the profile. It shows
    /// the space first when `activate`, unless it shows a private space the tab may not open in: the user stays there.
    private func browserWindow(
        for spaceId: UUID, lastShownIn nsWindow: NSWindow?, activate: Bool, extensionPage: Bool, context: WKWebExtensionContext
    ) -> MainWindowController? {
        guard let target = windows?.windows(showing: spaceId).first
            ?? nsWindow?.windowController as? MainWindowController ?? windows?.window(showingProfileOf: registry) else { return nil }
        let hidesShownSpace = target.tabManager.windowAdapter.map {
            $0.isPrivateWindow && !Self.admits($0, extensionPage: extensionPage, context: context)
        } ?? false
        if activate, !opensTabsInBackground, !hidesShownSpace, target.tabManager.currentSpaceId != spaceId {
            target.switchToSpace(spaceId)
        }
        return target
    }

    /// Opens `url` in `space`, shown first as `browserWindow` allows. In a space no window shows, the tab waits unloaded,
    /// already open to extensions. `index` lands it just before the tab shown there, in that tab's folder.
    private func openTab(
        url: URL?, activate: Bool, in space: WindowExtensionAdapter, for context: WKWebExtensionContext, opener: UUID? = nil, index: Int? = nil
    ) -> (window: MainWindowController, tab: Tab)? {
        guard let registry, let spaceId = space.spaceId,
              let target = browserWindow(
                  for: spaceId, lastShownIn: space.nsWindow, activate: activate,
                  extensionPage: url?.scheme?.lowercased() == "chrome-extension", context: context
              ) else { return nil }
        let tabManager = target.tabManager
        // As in Chrome, an index among the pinned or bookmarked tabs stops at the first unpinned spot instead of pinning it.
        var placement: (folderId: UUID?, section: TabTreeItem.Section, index: Int)?
        let windowTabs = tabManager.tabs(forSpace: spaceId)
        if let index, windowTabs.indices.contains(index) {
            let anchorId = windowTabs[index].id
            let items = tabManager.sidebarTreeItems(forSpace: spaceId)
            if let anchor = items.first(where: { $0.kind == .tab && $0.itemId == anchorId }) {
                if anchor.section != .unpinned {
                    placement = (nil, .unpinned, 0)
                } else {
                    let siblings = items.filter { $0.parentFolderId == anchor.parentFolderId && $0.section == anchor.section }
                        .sorted { $0.sortOrder < $1.sortOrder }
                    placement = siblings.firstIndex { $0.id == anchor.id }.map { (anchor.parentFolderId, anchor.section, $0) }
                }
            }
        }

        guard let tab = target.createTabStateFirst(
            url: url,
            activate: activate && !opensTabsInBackground,
            opener: opener,
            inSpace: spaceId,
            sidebarParentFolderId: placement?.folderId,
            sidebarSection: placement?.section,
            sidebarIndex: placement?.index
        ) else { return nil }
        if tabManager.currentSpaceId != spaceId {
            let adapter = TabExtensionAdapter(tabId: tab.id, engineTab: nil, extensionWindow: space, profileId: registry.profileId)
            adapter.tabManager = tabManager
            space.add(tab: adapter)
            target.context.browserState.storeHiddenTabAdapter(adapter, tabId: tab.id, spaceId: spaceId)
            registry.controller.didOpenTab(adapter)
        }
        return (target, tab)
    }

    // MARK: - Options Page

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let registry, let optionsURL = context.optionsPageURL, let profileWindow = windows?.window(showingProfileOf: registry) else {
            completionHandler(Self.extensionError("The options page could not open")); return
        }
        // As in Chrome, an options page already open in this profile is focused, whatever its query or fragment.
        for space in profileWindow.context.spaceManager?.spaces ?? [] where space.profileId == registry.profileId && !space.isPrivate {
            guard let tab = profileWindow.tabManager.tabs(forSpace: space.id).first(where: {
                !$0.isClosed && $0.url?.scheme == optionsURL.scheme && $0.url?.host == optionsURL.host && $0.url?.path == optionsURL.path
            }) else { continue }
            if !opensTabsInBackground, let window = browserWindow(
                for: space.id, lastShownIn: registry.windowAdapters.first { $0.spaceId == space.id }?.nsWindow,
                activate: true, extensionPage: true, context: context
            ), window.tabManager.currentSpaceId == space.id {
                window.activateTabStateFirst(id: tab.id)
                window.window?.makeKeyAndOrderFront(nil)
            }
            completionHandler(nil); return
        }
        // It opens in a space a window of the profile shows, the active one first, else where `tabs.create` would open it.
        let admits = { (window: WindowExtensionAdapter) in Self.admits(window, extensionPage: true, context: context) }
        let shownSpaces = ([profileWindow] + (windows?.windows ?? []))
            .filter { $0.profileContext?.extensions === registry }.compactMap(\.tabManager.windowAdapter)
        guard let space = shownSpaces.first(where: admits) ?? registry.extensionWindows(for: context).first(where: admits),
              let (window, _) = openTab(url: optionsURL, activate: true, in: space, for: context) else {
            completionHandler(Self.extensionError("The options page could not open")); return
        }
        if !opensTabsInBackground, window.tabManager.currentSpaceId == space.spaceId { window.window?.makeKeyAndOrderFront(nil) }
        completionHandler(nil)
    }

    // MARK: - Permissions

    private func postPermissionRequest(
        _ requestId: String, context: WKWebExtensionContext,
        permissions: [String] = [], origins: [String] = [], type: String
    ) {
        guard let registry else { return }
        guard let window = windows?.window(showingProfileOf: registry) else {
            registry.resolvePermissionRequest(id: requestId, granted: false)
            return
        }
        registry.permissionPromptWindows.setObject(window, forKey: requestId as NSString)
        window.sendExtensionPermissionRequest(
            requestId: requestId,
            extensionId: context.uniqueIdentifier,
            extensionName: context.webExtension.displayName ?? context.uniqueIdentifier,
            permissions: permissions,
            origins: origins,
            type: type
        )
    }

    /// Registers a pending permission request that resolves `completionHandler` when the user responds,
    /// returning the request id (or nil, having already denied, when no registry is available).
    private func beginPermissionPrompt<T>(_ values: Set<T>, completionHandler: @escaping (Set<T>, Date?) -> Void) -> String? {
        guard let registry else { completionHandler([], nil); return nil }
        let id = UUID().uuidString
        registry.pendingPermissionRequests[id] = { completionHandler($0 ? values : [], nil) }
        return id
    }

    /// Asks the user for a `permissions.request` naming permissions WebKit grants no request for
    /// (`PermissionsBridgeHandler`), with the rest of that request, in the prompt WebKit's requests get.
    func promptForPermissions(_ permissions: [String], origins: [String], for context: WKWebExtensionContext) async -> Bool {
        guard let registry else { return false }
        return await withCheckedContinuation { continuation in
            let id = UUID().uuidString
            registry.pendingPermissionRequests[id] = { continuation.resume(returning: $0) }
            postPermissionRequest(id, context: context, permissions: permissions, origins: origins, type: "permissions")
        }
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?,
                                for context: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        guard let id = beginPermissionPrompt(permissions, completionHandler: completionHandler) else { return }
        postPermissionRequest(id, context: context, permissions: permissions.map(\.rawValue), type: "permissions")
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?,
                                for context: WKWebExtensionContext,
                                completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        // WebKit asks here for a page an extension reaches without its host granted (tabs, webNavigation,
        // scripting, a failed CORS fetch). Chrome never asks for those, only for `permissions.request`.
        completionHandler([], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?,
                                for context: WKWebExtensionContext,
                                completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        guard let id = beginPermissionPrompt(matchPatterns, completionHandler: completionHandler) else { return }
        postPermissionRequest(id, context: context, origins: matchPatterns.map(\.description), type: "matchPatterns")
    }

    // MARK: - Popup

    func setPopupAnchorRect(_ rect: NSRect, for extensionId: String) {
        popupAnchorRectsByExtensionId[extensionId] = rect
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Self.logger.debug("Delegate called - presentsPopup: \(action.presentsPopup), popupPopover: \(action.popupPopover != nil)")

        guard action.presentsPopup, let popover = action.popupPopover else {
            pendingPopupAnchorRect = nil
            if action.presentsPopup {
                // presentsPopup == true but WebKit built no popover: the click renders nothing, so
                // surface the failure (error diagnostic + degraded indicator) instead of failing silently.
                registry?.recordExtensionNativeDiagnostic(context: context, level: "error", source: "popup.popover", message: "WebKit did not provide a popup popover")
                registry?.backgrounds.markPopupUnavailable(context.uniqueIdentifier)
            } else {
                // presentsPopup == false: a click-only (onClicked) action with no popup by design. Not
                // a failure: resolve silently without degrading a healthy extension.
                Self.logger.debug("presentActionPopup for non-popup action id=\(context.uniqueIdentifier, privacy: .public)")
            }
            completionHandler(nil); return
        }
        guard let nsWindow = windowAdapter?.nsWindow, let contentView = nsWindow.contentView else {
            pendingPopupAnchorRect = nil
            registry?.recordExtensionNativeDiagnostic(context: context, level: "error", source: "popup.anchor", message: "No anchor view available for popup")
            Self.logger.error("No anchor view available"); completionHandler(Self.extensionError("No anchor view for popup", code: 1)); return
        }
        // A popup `action.openPopup` opened from the worker reaches Lilo only here, once loaded: later frames still wait.
        if let popup = action.popupWebView { registry?.frameCookies.watch(popup) }
        let popupURL = action.popupWebView?.url?.absoluteString ?? ""
        registry?.recordExtensionNativeDiagnostic(
            context: context,
            level: "info",
            source: "popup.present",
            message: action.popupWebView == nil ? "Popup popover will present without exposed popupWebView" : "Popup popover will present with popupWebView",
            url: popupURL
        )
        // Debug level since it runs on every open. WebKit binds the popover web view to the presenting controller itself, so a
        // mismatch is a WebKit fault, not a Lilo ordering bug (`loadBackgroundContent` is awaited before `performAction`).
        let boundController = action.popupWebView?.configuration.webExtensionController
        Self.logger.debug("[lilo-popup-diag] present id=\(context.uniqueIdentifier, privacy: .public) loaded=\(context.isLoaded) hasPopupWebView=\(action.popupWebView != nil) boundCtrlNil=\(boundController == nil) boundCtrlIsPresenting=\(boundController === controller) registryCtrlIsPresenting=\(self.registry?.controller === controller)")

        // Paths that never reach the bridge (a service worker calling chrome.action.openPopup, which
        // WebKit serves natively) leave no pending rect: fall back to the toolbar-icon rect the UI
        // last reported for this extension, so the popover still points at its button.
        let bridgeRect = pendingPopupAnchorRect ?? popupAnchorRectsByExtensionId[context.uniqueIdentifier]
        pendingPopupAnchorRect = nil
        // Convert bridge rect (CSS top-left origin) to AppKit rect (bottom-left origin).
        let anchorRect: NSRect = bridgeRect.map {
            NSRect(x: $0.origin.x, y: contentView.bounds.height - $0.origin.y - $0.height, width: $0.width, height: $0.height)
        } ?? NSRect(x: 0, y: contentView.bounds.height - 40, width: 32, height: 32)
        Self.logger.debug("popup anchor id=\(context.uniqueIdentifier, privacy: .public) hasBridgeRect=\(bridgeRect != nil) rect=\(NSStringFromRect(anchorRect), privacy: .public)")

        popover.delegate = self
        popupPresentationsByPopoverId[ObjectIdentifier(popover)] = PopupPresentation(
            popover: popover,
            action: action
        )
        // Below the button, as Chrome shows it: beside a button at the top of the window, AppKit pins the popover to the
        // screen's top and its arrow lands in the rounded corner.
        popover.show(relativeTo: anchorRect, of: contentView, preferredEdge: contentView.isFlipped ? .maxY : .minY)

        completionHandler(nil)
        // The completion starts WebKit's color scheme check, whose answer writes into the action even once it is freed
        // (WEBKIT-GAPS.md, gap 90). A script evaluated after it answers after it: holding the action until then.
        action.popupWebView?.evaluateJavaScript("0") { _, _ in withExtendedLifetime(action) {} }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        let popover = notification.object as? NSPopover
        DispatchQueue.main.async { [weak self] in
            guard let self, let popover else { return }
            MainActor.assumeIsolated {
                let presentation = popupPresentationsByPopoverId.removeValue(forKey: ObjectIdentifier(popover))
                presentation?.action.closePopup()
                // While the popover was key, windowDidResignKey was suppressed. Re-sync the
                // extension-visible focus to wherever key status actually landed (the main
                // window on a normal dismiss, elsewhere if the user switched app/window).
                if popupPresentationsByPopoverId.isEmpty {
                    registry?.notifyWindowFocused(windowAdapter?.nsWindow?.isKeyWindow ?? false)
                }
            }
        }
    }

    // MARK: - Native Messaging

    private let nativeMessaging = ExtensionNativeMessaging()

    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for context: WKWebExtensionContext,
        replyHandler: @escaping (Any?, Error?) -> Void
    ) {
        guard holdsNativeMessaging(context) else {
            replyHandler(nil, Self.extensionError("Native messaging requires the nativeMessaging permission")); return
        }
        nativeMessaging.send(message, toHost: applicationIdentifier, for: context, replyHandler: replyHandler)
    }

    /// Every extension is granted WebKit's nativeMessaging for its channel to Lilo, so a real host needs it
    /// required by the manifest or granted at Lilo's prompt.
    private func holdsNativeMessaging(_ context: WKWebExtensionContext) -> Bool {
        registry?.heldPermissions(of: context.uniqueIdentifier).contains("nativeMessaging") == true
    }

    /// Reserved host name of the channel extension pages and workers open to Lilo (ipc.ts). Lilo
    /// answers it itself; no native messaging host is involved.
    static let channelHostName = "app.lilo.channel"

    func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let hostName = port.applicationIdentifier else {
            completionHandler(Self.extensionError("No native messaging application specified")); return
        }
        if hostName == Self.channelHostName {
            // Attached first: the completion hands the port the messages its context sent meanwhile, lost without a handler.
            registry?.gapEvents.attach(port, extensionId: context.uniqueIdentifier)
            completionHandler(nil)
            return
        }
        // Without the permission, Chrome has no connectNative to call, so it reports no error. WebKit's, which every
        // extension has for Lilo's channel, opens a port that closes on its first message, as a missing host's.
        guard holdsNativeMessaging(context) else {
            port.messageHandler = { [weak port] _, _ in port?.disconnect() }
            completionHandler(nil)
            return
        }
        nativeMessaging.connect(port, toHost: hostName, for: context, completionHandler: completionHandler)
    }

    // MARK: - Action updates

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        registry?.actionDidChange(for: context.uniqueIdentifier)
    }
}

/// Owns the lifecycle of a `chrome.windows.create` mini popup (the panel, its web view, and the
/// WKWebExtension adapters) and is retained by the delegate until the panel closes.
@MainActor
private final class ExtensionPopupWindow: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    fileprivate let webView: WKWebView
    private let engineTab: WKWebViewTab
    let windowAdapter: WindowExtensionAdapter
    private let tabAdapter: TabExtensionAdapter
    var onClose: (() -> Void)?
    private var didClose = false

    init(panel: NSPanel, webView: WKWebView, engineTab: WKWebViewTab,
         windowAdapter: WindowExtensionAdapter, tabAdapter: TabExtensionAdapter) {
        self.panel = panel
        self.webView = webView
        self.engineTab = engineTab
        self.windowAdapter = windowAdapter
        self.tabAdapter = tabAdapter
        super.init()
        panel.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        guard !didClose else { return }
        didClose = true
        engineTab.teardown()
        onClose?()
    }
}

extension Notification.Name {
    static let extensionRuntimeLoaded = Notification.Name("fr.arouillard.lilo.extensionRuntimeLoaded")
    /// Object: the registry, one of whose extensions' pages or worker added or removed gap event listeners.
    static let extensionGapListenersChanged = Notification.Name("fr.arouillard.lilo.extensionGapListenersChanged")
    /// Object: the registry. userInfo: "extensionId", "profileId" (UUID) and "uninstalled" (Bool).
    static let extensionDidUnload = Notification.Name("fr.arouillard.lilo.extensionDidUnload")
    /// Object: the registry. userInfo: "tabId" (UUID), a tab closed for good.
    static let extensionTabDidClose = Notification.Name("fr.arouillard.lilo.extensionTabDidClose")
    /// Object: the registry, whose profile's data store has new `proxyConfigurations`.
    static let extensionProxyDidChange = Notification.Name("fr.arouillard.lilo.extensionProxyDidChange")
}
