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
            WKWebViewTab(webView: WKWebView(frame: .zero, configuration: context.pageWebViewConfiguration ?? WKWebViewConfiguration()))
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
        let visible = { (window: WindowExtensionAdapter?) in
            window.flatMap { $0.spaceId != nil && (!$0.isPrivateWindow || context.hasAccessToPrivateData) ? $0 : nil }
        }
        let requested = visible(configuration.window as? WindowExtensionAdapter) ?? visible(windowAdapter)
            ?? registry?.extensionWindows(for: context).first { $0.spaceId != nil }
        // A space in the background is shown first, in the browser window that showed it last.
        guard let spaceId = requested?.spaceId,
              let target = windows?.windows.first(where: { $0.tabManager.currentSpaceId == spaceId })
                ?? requested?.nsWindow?.windowController as? MainWindowController else {
            completionHandler(nil, Self.extensionError("Window controller not available")); return
        }
        if target.tabManager.currentSpaceId != spaceId { target.switchToSpace(spaceId) }
        guard target.tabManager.currentSpaceId == spaceId else {
            completionHandler(nil, Self.extensionError("Window controller not available")); return
        }
        let tabManager = target.tabManager
        // `index` lands the tab just before the one shown there, in that tab's folder. As in Chrome, an
        // index among the pinned or bookmarked tabs stops at the first unpinned spot instead of pinning it.
        var placement: (folderId: UUID?, section: TabTreeItem.Section, index: Int)?
        let windowTabs = tabManager.tabs(forSpace: spaceId)
        if !configuration.shouldBePinned, windowTabs.indices.contains(configuration.index) {
            let anchorId = windowTabs[configuration.index].id
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
            url: configuration.url,
            activate: configuration.shouldBeActive && !opensTabsInBackground,
            opener: (configuration.parentTab as? TabExtensionAdapter)?.tabId,
            sidebarParentFolderId: placement?.folderId,
            sidebarSection: placement?.section,
            sidebarIndex: placement?.index
        ) else {
            completionHandler(nil, Self.extensionError("Window controller not available")); return
        }
        if configuration.shouldBePinned {
            _ = try? target.applyBrowserCommand(.setPinned(spaceId: spaceId, tabId: tab.id, isPinned: true))
        }
        if configuration.shouldBeMuted { tabManager.setTabMuted(id: tab.id, muted: true) }
        guard let adapter = tabManager.tabAdapter(for: tab.id) else {
            completionHandler(nil, Self.extensionError("Tab adapter not found after creation")); return
        }
        adapter.parent = configuration.parentTab as? TabExtensionAdapter
        completionHandler(adapter, nil)
    }

    // MARK: - Options Page

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let optionsURL = context.optionsPageURL else {
            completionHandler(Self.extensionError("The options page could not open")); return
        }
        // As in Chrome, an options page already open in this profile is focused, whatever its query or fragment.
        for window in windows?.windows ?? [] where window.profileContext?.extensions === registry {
            guard let tab = window.tabManager.openTabs.first(where: {
                $0.url?.scheme == optionsURL.scheme && $0.url?.host == optionsURL.host && $0.url?.path == optionsURL.path
            }) else { continue }
            if !opensTabsInBackground {
                window.activateTabStateFirst(id: tab.id)
                window.window?.makeKeyAndOrderFront(nil)
            }
            completionHandler(nil); return
        }
        guard let window = windows?.window(showingProfileOf: registry),
              window.createTabStateFirst(url: optionsURL, activate: !opensTabsInBackground) != nil else {
            completionHandler(Self.extensionError("The options page could not open")); return
        }
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
    /// Object: the registry, whose profile's data store has new `proxyConfigurations`.
    static let extensionProxyDidChange = Notification.Name("fr.arouillard.lilo.extensionProxyDidChange")
}
