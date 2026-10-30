import AppKit
import WebKit

extension MainWindowController {
    /// Whether `window.open` asks for a popup rather than a tab. WebKit answers with the HTML rule
    /// (a `popup` feature, or no toolbar and location bar); without its private key, any size or
    /// position counts.
    static func requestsPopup(_ features: WKWindowFeatures) -> Bool {
        let wantsPopup = NSSelectorFromString("_wantsPopup")
        if features.responds(to: wantsPopup) { return features.value(forKey: "_wantsPopup") as? Bool ?? false }
        return features.width != nil || features.height != nil || features.x != nil || features.y != nil
    }

    /// Opens the popup in its own window, or as a peek over its opener in single-window mode. A popup
    /// opened from another popup belongs to the same opener tab.
    func openPagePopup(configuration: WKWebViewConfiguration, features: WKWindowFeatures, opener: WKWebViewTab) -> WKWebView {
        let engine = context.engineFactory.createTab(configuration: .init(
            dataStore: tabManager.dataStore,
            tabId: nil,
            nativeConfiguration: configuration,
            profileId: tabManager.profileId
        ))
        presentPagePopup(
            engine,
            openerTabId: pagePopups[opener.id]?.openerTabId ?? opener.id,
            contentSize: NSSize(
                width: features.width.map { CGFloat($0.doubleValue) } ?? 500,
                height: features.height.map { CGFloat($0.doubleValue) } ?? 600
            ),
            topLeft: features.x.flatMap { x in features.y.map { NSPoint(x: x.doubleValue, y: $0.doubleValue) } },
            inPeek: context.settingsStore.singleWindow
        )
        return engine.wkWebView
    }

    /// Shows `engine` as a popup of `openerTabId`: its window or peek, its extension window and the
    /// opener's badge.
    @discardableResult
    func presentPagePopup(_ engine: WKWebViewTab, openerTabId: UUID, contentSize: NSSize, topLeft: NSPoint?, inPeek: Bool) -> PagePopupController {
        configureEngineIfNeeded(engine)
        engine.applyPageBackgroundColor(currentContentSurfaceColor)
        let popup = PagePopupController(
            engine: engine,
            openerTabId: openerTabId,
            contentSize: contentSize,
            topLeft: topLeft,
            inPeek: inPeek,
            parent: window
        )
        popup.canOpenInSplit = canSplit(beside: openerTabId)
        popup.onOpenAsTab = { [weak self] popup, inSplit in self?.openPopupAsTab(popup, inSplit: inSplit) }
        popup.onClose = { [weak self] popup in
            guard let self else { return }
            pagePopups[popup.engine.id] = nil
            if let extensionWindow = popup.extensionWindow { tabManager.extensionRegistry?.controller.didCloseWindow(extensionWindow) }
            updateAndEmit(popup.openerTabId) { $0.hasPopup = self.pagePopups.values.contains { $0.openerTabId == popup.openerTabId } }
            // A dismissed peek hands the keyboard back to the page or terminal it covered.
            if popup.peekView != nil, popup.openerTabId == tabManager.activeOpenTabId,
               let view = tabManager.loadedContentView(forTabId: popup.openerTabId) {
                focusContent(view)
            }
        }
        pagePopups[engine.id] = popup
        // Extensions see a popup window holding one tab, so content scripts can message it. Never a
        // private one: no extension is granted private data.
        if let registry = tabManager.extensionRegistry, !engine.isPrivateBrowsing {
            let extensionWindow = WindowExtensionAdapter(nsWindow: popup.window, type: .popup)
            extensionWindow.tabManager = tabManager
            let extensionTab = TabExtensionAdapter(engineTab: engine, extensionWindow: extensionWindow, profileId: registry.profileId)
            extensionTab.tabManager = tabManager
            extensionTab.parent = tabManager.tabAdapter(for: openerTabId)
            extensionWindow.add(tab: extensionTab)
            extensionWindow.activeAdapter = extensionTab
            popup.extensionWindow = extensionWindow
            registry.controller.didOpenWindow(extensionWindow)
        }
        updateAndEmit(openerTabId) { $0.hasPopup = true }
        refreshPagePeeks()
        return popup
    }

    /// Opens `url` in a Peek over `sourceTabId`, in its space's data store. A window shows one link peek
    /// at a time: any other one closes, its page torn down. A page's own popups stay.
    @discardableResult
    func openLinkPeek(_ url: URL, from sourceTabId: UUID) -> PagePopupController {
        pagePopups.values.filter(\.isLinkPeek).forEach { $0.close() }
        let engine = context.engineFactory.createTab(configuration: .init(
            dataStore: tabManager.dataStore,
            tabId: nil,
            nativeConfiguration: nil,
            profileId: tabManager.profileId
        ))
        // As large as the content allows: the peek clamps it to the window.
        let peek = presentPagePopup(engine, openerTabId: sourceTabId, contentSize: NSSize(width: 1600, height: 1200), topLeft: nil, inPeek: true)
        peek.isLinkPeek = true
        engine.loadURL(url)
        return peek
    }

    /// Shift+click peeks any link; a pinned or bookmarked tab peeks a link to another site instead of
    /// leaving its own (unless turned off). A peek's own links stay in the peek.
    func tab(_ tab: WKWebViewTab, peeksLink url: URL, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        guard pagePopups[tab.id] == nil, !tab.isAgentControlled, let source = tabManager.tab(for: tab.id) else { return false }
        guard !modifierFlags.contains(.shift) else {
            openLinkPeek(url, from: tab.id)
            return true
        }
        guard source.isPinned || source.isBookmarked, context.settingsStore.get("peekPinnedTabLinks") != "false",
              let host = url.host?.lowercased(), let pageHost = tab.currentURL?.host?.lowercased() else { return false }
        let pageSite = CookiesBridgeHandler.registrableDomain(of: pageHost)
        guard CookiesBridgeHandler.registrableDomain(of: host) != pageSite else { return false }
        openLinkPeek(url, from: tab.id).openerSite = pageSite
        return true
    }

    /// A pinned or bookmarked tab's peek that comes back to the tab's site hands the page over to the tab, so a
    /// sign-in through another site returns to the page that started it. A POST stays: its body cannot follow.
    func tab(_ tab: WKWebViewTab, returnsPeekToOpener request: URLRequest) -> Bool {
        guard let peek = pagePopups[tab.id], let site = peek.openerSite, let url = request.url, let host = url.host?.lowercased(),
              (request.httpMethod ?? "GET").uppercased() == "GET", CookiesBridgeHandler.registrableDomain(of: host) == site else { return false }
        peek.close()
        tabManager.load(url, inTab: peek.openerTabId)
        return true
    }

    /// The opener is a tab of this space that is not already a pane: a split never grows a third one.
    func canSplit(beside tabId: UUID) -> Bool {
        guard let opener = tabManager.context(for: tabId) else { return false }
        return tabManager.browserStateStore?.space(id: opener.spaceId)?.spaceTab.splitGroup(containing: tabId) == nil
    }

    /// The popup's live page becomes a tab right after its opener, in the opener's folder, or a pane
    /// beside it.
    private func openPopupAsTab(_ popup: PagePopupController, inSplit: Bool) {
        // The popup window leaves extensions before the tab arrives, so they never see the page twice.
        if let extensionWindow = popup.extensionWindow {
            tabManager.extensionRegistry?.controller.didCloseWindow(extensionWindow)
            popup.extensionWindow = nil
        }
        let opener = tabManager.context(for: popup.openerTabId)
        let besideOpener = sidebarItemBeside(popup.openerTabId)
        let split = inSplit && canSplit(beside: popup.openerTabId)
        guard let tab = createTabStateFirst(
            url: nil,
            activate: !split,
            opener: popup.openerTabId,
            adopting: popup.engine,
            sidebarParentFolderId: besideOpener?.parentFolderId,
            sidebarSection: besideOpener?.section,
            sidebarIndex: besideOpener.map { $0.sortOrder + 1 }
        ), split, let spaceId = opener?.spaceId else { return }
        _ = try? applyBrowserCommand(.splitTabs(spaceId: spaceId, tabId: tab.id, targetTabId: popup.openerTabId, vertical: false, before: false))
        tabManager.activateTabRuntime(id: tab.id)
    }

    /// Shows the peeks opened by the active tab over the content, and hides every other one.
    func refreshPagePeeks() {
        guard !pagePopups.isEmpty else { return }
        let activeId = tabManager.activeOpenTabId
        for popup in pagePopups.values {
            guard let peek = popup.peekView else { continue }
            guard popup.openerTabId == activeId else {
                peek.removeFromSuperview()
                continue
            }
            popup.canOpenInSplit = canSplit(beside: popup.openerTabId)
            let isNew = peek.superview == nil
            peek.frame = contentContainerView.bounds
            peek.autoresizingMask = [.width, .height]
            contentContainerView.addSubview(peek, positioned: .above, relativeTo: nil)
            if isNew {
                peek.present()
                popup.engine.runQueuedDialog(presenting: true)
            }
            window?.makeFirstResponder(popup.engine.wkWebView)
        }
    }

    /// The page the window's keys and page actions go to: the shown peek's, else the active tab's.
    var focusedEngineTab: WKWebViewTab? {
        pagePopups.values.first { $0.peekView?.superview != nil }?.engine ?? tabManager.activeEngineTab
    }

    /// File > Open as Tab in the browser window: the shown peek's page, when there is one.
    @objc func openPageAsTab(_ sender: Any?) {
        pagePopups.values.first { $0.peekView?.superview != nil }?.openAsTab()
    }

    /// Brings a popup to the front: its window, or its opener tab with the peek over it.
    func focusPagePopup(_ popup: PagePopupController) {
        if let popupWindow = popup.window {
            popupWindow.makeKeyAndOrderFront(nil)
        } else {
            activateTabStateFirst(id: popup.openerTabId)
            window?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }
}
