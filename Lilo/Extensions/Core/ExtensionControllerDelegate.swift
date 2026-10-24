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
        // A normal window is a browser window on the current space; popups and private windows stay panels.
        if configuration.windowType == .normal, !configuration.shouldBePrivate,
           let windowController, let registry, let spaceId = windowController.tabManager.currentSpaceId {
            if windowController.context.settingsStore.singleWindow, let nsWindow = windowController.window {
                if configuration.tabURLs.isEmpty { windowController.newTab(nil) }
                for (index, url) in configuration.tabURLs.enumerated() {
                    windowController.createTabStateFirst(url: url, activate: index == 0 && configuration.shouldBeFocused)
                }
                completionHandler(registry.windowAdapter(for: nsWindow), nil)
                return
            }
            let opened = windowController.context.openWindow(on: spaceId, opening: .urls(configuration.tabURLs))
            guard let nsWindow = opened.window else {
                completionHandler(nil, Self.extensionError("The window could not open"))
                return
            }
            if !configuration.shouldBeFocused { windowController.window?.makeKeyAndOrderFront(nil) }
            completionHandler(registry.windowAdapter(for: nsWindow), nil)
            return
        }
        let windowAdapter = presentExtensionPanel(
            url: configuration.tabURLs.first,
            type: configuration.windowType,
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
        for context: WKWebExtensionContext,
        controller: WKWebExtensionController,
        size: NSSize
    ) -> WindowExtensionAdapter? {
        guard let profileId = registry?.profileId else { return nil }

        // The extension's configuration loads nothing but its own pages: a web page needs a tab's.
        let engineTab = if url?.scheme?.lowercased() != "chrome-extension", let windowController {
            windowController.context.engineFactory.createTab(configuration: .init(
                dataStore: windowController.tabManager.dataStore, tabId: nil, nativeConfiguration: nil, profileId: profileId
            ))
        } else {
            WKWebViewTab(webView: WKWebView(frame: .zero, configuration: context.webViewConfiguration ?? WKWebViewConfiguration()))
        }
        let webView = engineTab.wkWebView

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.contentView = webView
        panel.isReleasedWhenClosed = false

        let windowAdapter = WindowExtensionAdapter(nsWindow: panel, type: type)
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
        // `windowId` names one of this profile's browser windows; a panel or unknown window falls back.
        let requestedWindow = (configuration.window as? WindowExtensionAdapter)?.nsWindow?.windowController as? MainWindowController
        guard let target = requestedWindow?.profileContext?.extensions === registry ? requestedWindow : windowController,
              let spaceId = target.tabManager.currentSpaceId else {
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
        guard let optionsURL = context.optionsPageURL,
              let window = windows?.window(showingProfileOf: registry),
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
        // The answer resolves through the prompting window's registry, so it must show this profile.
        guard let window = windows?.window(showingProfileOf: registry) else {
            registry.resolvePermissionRequest(id: requestId, granted: false)
            return
        }
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
        popover.show(relativeTo: anchorRect, of: contentView, preferredEdge: .maxX)

        completionHandler(nil)
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
            completionHandler(nil)
            registry?.gapEvents.attach(port, extensionId: context.uniqueIdentifier)
            return
        }
        guard holdsNativeMessaging(context) else {
            completionHandler(Self.extensionError("Native messaging requires the nativeMessaging permission")); return
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
}
