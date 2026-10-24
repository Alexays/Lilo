import Foundation
import WebKit

/// Wraps a WKWebViewTab so WKWebExtensionController can observe and inject into it.
@MainActor
final class TabExtensionAdapter: NSObject, WKWebExtensionTab {
    /// One identity for the tab's whole life, like Chrome: a discarded tab keeps its extension tab id.
    let tabId: UUID
    /// Nil while the tab is discarded: it stays open to extensions with no page behind it, and holds
    /// no reference to the torn-down engine.
    var engineTab: WKWebViewTab?
    weak var extensionWindow: (any WKWebExtensionWindow)?
    /// The opener extensions see as `openerTabId`; in memory only, like Chrome's.
    weak var parent: TabExtensionAdapter?
    weak var tabManager: TabManager?
    /// Profile this tab belongs to: its extension registry may not be the displayed profile's.
    let profileId: UUID?

    private static let discardedError = NSError(domain: "LiloExtension", code: 0, userInfo: [NSLocalizedDescriptionKey: "The tab is discarded"])
    private static let windowUnavailableError = NSError(domain: "LiloExtension", code: 0, userInfo: [NSLocalizedDescriptionKey: "The tab's window is unavailable"])

    init(engineTab: WKWebViewTab, extensionWindow: (any WKWebExtensionWindow)? = nil, profileId: UUID? = nil) {
        self.tabId = engineTab.id
        self.engineTab = engineTab
        self.extensionWindow = extensionWindow
        self.profileId = profileId
    }

    // MARK: - WKWebExtensionTab

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        extensionWindow
    }

    /// None for a frozen tab: WebKit's `scripting.executeScript` would evaluate in it and raise, crashing the app,
    /// where without a web view the extension gets an error, as Chrome gives for a tab put to sleep.
    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        guard let engineTab, let webView = engineTab.view as? WKWebView, !CompositeFreezer.suspendedWebViews.contains(webView) else { return nil }
        engineTab.lentToExtensionAt = Date()
        return webView
    }

    /// A new tab has no url until its first navigation starts, as Chrome reports none before it.
    func url(for context: WKWebExtensionContext) -> URL? {
        guard let engineTab else { return tabManager?.tab(for: tabId)?.url }
        return engineTab.hasCommittedContent || engineTab.isLoading ? engineTab.currentURL : nil
    }

    func title(for context: WKWebExtensionContext) -> String? {
        engineTab?.currentTitle ?? tabManager?.tab(for: tabId)?.title
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        (extensionWindow as? WindowExtensionAdapter)?.visibleActiveAdapter === self
    }

    // MARK: - Index & Parent

    /// The tab's index in its window, in the visible sidebar order. Returns NSNotFound when the
    /// tab isn't in the current window (per the WKWebExtensionTab contract).
    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        (extensionWindow as? WindowExtensionAdapter)?.index(of: self, for: context) ?? NSNotFound
    }

    func parentTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { parent }

    func setParentTab(_ parentTab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        parent = parentTab as? TabExtensionAdapter
        completionHandler(nil)
    }

    // MARK: - State

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(engineTab?.isLoading ?? false) }
    func pendingURL(for context: WKWebExtensionContext) -> URL? { engineTab?.provisionalURL }
    func size(for context: WKWebExtensionContext) -> CGSize { engineTab?.view.bounds.size ?? .zero }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double((engineTab?.view as? WKWebView)?.pageZoom ?? 1.0) }

    /// Follows the tab's zoom settings, as Chrome's `tabs.setZoom` does.
    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let engine = engineTab ?? tabManager?.ensureLiveEngine(forTabId: tabId) else { completionHandler(nil); return }
        switch engine.zoomSettings.mode {
        case "disabled":
            completionHandler(NSError(domain: "LiloExtension", code: 0, userInfo: [NSLocalizedDescriptionKey: "Cannot zoom a tab in disabled mode."]))
            return
        case "manual": engine.reportZoomChange(from: engine.pageZoom, to: zoomFactor)
        default: engine.setPageZoom(zoomFactor)
        }
        completionHandler(nil)
    }

    // MARK: - Pinned / Muted / Reader Mode

    func isPinned(for context: WKWebExtensionContext) -> Bool {
        tabManager?.tab(for: tabId)?.isPinned ?? false
    }
    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        // Pinning is a browser-state command, applied by the window controller the tab manager reports to.
        guard let window = tabManager?.delegate as? MainWindowController,
              let spaceId = tabManager?.browserStateStore?.owningSpaceId(forTab: tabId) else {
            completionHandler(Self.windowUnavailableError); return
        }
        do {
            try window.applyBrowserCommand(.setPinned(spaceId: spaceId, tabId: tabId, isPinned: pinned))
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
    func isReaderModeAvailable(for context: WKWebExtensionContext) -> Bool { false }
    func isReaderModeActive(for context: WKWebExtensionContext) -> Bool { false }
    func setReaderModeActive(_ active: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) { completionHandler(nil) }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { engineTab?.isPlayingAudio ?? false }
    func isMuted(for context: WKWebExtensionContext) -> Bool {
        tabManager?.tab(for: tabId)?.isMuted ?? false
    }
    func setMuted(_ muted: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        tabManager?.setTabMuted(id: tabId, muted: muted)
        completionHandler(nil)
    }

    // MARK: - Navigation

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        // A panel's tab belongs to no tab manager: its own web view takes the load.
        if let tabManager, tabManager.tab(for: tabId) != nil {
            tabManager.load(url, inTab: tabId)
        } else {
            engineTab?.loadURL(url)
        }
        completionHandler(nil)
    }

    /// Reloading a discarded tab brings it back, which loads its page.
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if let engineTab {
            if fromOrigin { engineTab.reloadFromOrigin() } else { engineTab.reload() }
        } else {
            _ = tabManager?.ensureLiveEngine(forTabId: tabId)
        }
        completionHandler(nil)
    }

    /// A discarded tab lost its session history with its web view: there is nowhere to go.
    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let engineTab else { completionHandler(Self.discardedError); return }
        engineTab.goBack(); completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let engineTab else { completionHandler(Self.discardedError); return }
        engineTab.goForward(); completionHandler(nil)
    }

    // MARK: - Selection / Activation / Close

    /// The window holding this tab, which tab commands go through.
    private var owningWindow: MainWindowController? {
        (tabManager?.delegate as? MainWindowController)?.context.windows.window(forTab: tabId)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window = owningWindow else { completionHandler(Self.windowUnavailableError); return }
        window.activateTabStateFirst(id: tabId)
        completionHandler(nil)
    }

    func setSelected(_ selected: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) { completionHandler(nil) }

    func duplicate(using configuration: WKWebExtension.TabConfiguration, for context: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void) {
        guard let window = tabManager?.delegate as? MainWindowController else {
            completionHandler(nil, Self.windowUnavailableError); return
        }
        guard let url = url(for: context),
              let tab = window.createTabStateFirst(url: nil, activate: configuration.shouldBeActive) else {
            completionHandler(nil, NSError(domain: "LiloExtension", code: 0, userInfo: [NSLocalizedDescriptionKey: "The tab could not be duplicated"]))
            return
        }
        // Loaded after creation: an extension page needs an engine built for its extension.
        window.tabManager.load(url, inTab: tab.id)
        completionHandler(window.tabManager.tabAdapter(for: tab.id), nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window = owningWindow else { completionHandler(Self.windowUnavailableError); return }
        completionHandler(nil)
        // After WebKit's call returns: closing tears down the tab WebKit is still calling into.
        Task { @MainActor [tabId] in window.closeTabStateFirst(id: tabId) }
    }

    // MARK: - Snapshot / Locale

    func detectWebpageLocale(for context: WKWebExtensionContext, completionHandler: @escaping (Locale?, Error?) -> Void) {
        guard let engineTab else { completionHandler(nil, Self.discardedError); return }
        guard engineTab.wake(), let webView = engineTab.view as? WKWebView else { completionHandler(nil, nil); return }
        WebViewPrivateAccessors(webView).evaluateWithoutUserGesture("document.documentElement.lang || navigator.language || ''") { result in
            let tag = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            completionHandler(tag.isEmpty ? nil : Locale(identifier: tag), nil)
        }
    }

    func takeSnapshot(using configuration: WKSnapshotConfiguration, for context: WKWebExtensionContext, completionHandler: @escaping (NSImage?, Error?) -> Void) {
        guard let engineTab, engineTab.wake(), let wv = engineTab.view as? WKWebView else {
            completionHandler(nil, NSError(domain: "LiloExtension", code: 0, userInfo: [NSLocalizedDescriptionKey: "No WKWebView"]))
            return
        }
        // tabs.captureVisibleTab hands an empty rect (WEBKIT-GAPS.md): it means the visible page.
        if configuration.rect.isEmpty { configuration.rect = wv.bounds }
        Task {
            do { completionHandler(try await wv.takeSnapshot(configuration: configuration), nil) } catch { completionHandler(nil, error) }
        }
    }

    // MARK: - Permissions

    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }
    func shouldBypassPermissions(for context: WKWebExtensionContext) -> Bool { false }
}
