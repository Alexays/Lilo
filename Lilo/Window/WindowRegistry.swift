import Foundation
import WebKit

/// The open browser windows, the one the user last worked in, and which window shows each tab:
/// a web view lives in one window at a time, so showing a tab elsewhere takes it from its window.
@MainActor
final class WindowRegistry {
    private(set) var windows: [MainWindowController] = []
    private weak var lastActiveWindow: MainWindowController?
    private var displayingWindowByTab: [UUID: ObjectIdentifier] = [:]
    private let browserState: BrowserStateStore

    init(browserState: BrowserStateStore) {
        self.browserState = browserState
    }

    /// The window menu actions, external URLs and app-level events go to.
    var activeWindow: MainWindowController? { lastActiveWindow ?? windows.last }

    func add(_ window: MainWindowController) {
        guard !windows.contains(where: { $0 === window }) else { return }
        windows.append(window)
    }

    func remove(_ window: MainWindowController) {
        windows.removeAll { $0 === window }
        if lastActiveWindow === window { lastActiveWindow = nil }
        let id = ObjectIdentifier(window)
        for tabId in displayingWindowByTab.filter({ $0.value == id }).keys { release(tabId, by: window) }
        windows.first?.tabManager.terminalHost.visibleTabIds = browserState.displayedTabIds
    }

    func noteActive(_ window: MainWindowController) {
        lastActiveWindow = window
    }

    func windows(showing spaceId: UUID) -> [MainWindowController] {
        windows.filter { $0.tabManager.currentSpaceId == spaceId }
    }

    func displayingWindow(ofTab tabId: UUID) -> MainWindowController? {
        displayingWindowByTab[tabId].flatMap { id in windows.first { ObjectIdentifier($0) == id } }
    }

    /// Where a tab's events go: the window showing it, else one showing its space, else the active one.
    func window(forTab tabId: UUID) -> MainWindowController? {
        displayingWindow(ofTab: tabId)
            ?? browserState.owningSpaceId(forTab: tabId).flatMap { spaceId in windows.first { $0.tabManager.currentSpaceId == spaceId } }
            ?? activeWindow
    }

    /// The window an extension acts on: the active one when it shows the extension's profile, else
    /// another that does. Nil when none does: another profile's window must not serve it.
    func window(showingProfileOf registry: ProfileExtensionRegistry?) -> MainWindowController? {
        guard let registry else { return nil }
        let active = activeWindow
        if active?.profileContext?.extensions === registry { return active }
        return windows.first { $0.profileContext?.extensions === registry }
    }

    /// Where a page's events go, by the tab whose web view it is.
    func window(for webView: WKWebView) -> MainWindowController? {
        windowAndEngine(for: webView)?.window ?? activeWindow
    }

    /// The page's tab and the window its events go to. Windows sharing a space share its engines,
    /// so each runtime is searched once.
    func windowAndEngine(for webView: WKWebView) -> (window: MainWindowController, engine: WKWebViewTab)? {
        var searchedHosts = Set<ObjectIdentifier>()
        for window in windows where searchedHosts.insert(ObjectIdentifier(window.tabManager.engineHost)).inserted {
            if let engine = window.tabManager.engineTab(forWebView: webView) {
                return (self.window(forTab: engine.id) ?? window, engine)
            }
        }
        return nil
    }

    /// Records that `window` shows `tabId` and returns the other window that showed it until now.
    @discardableResult
    func claim(_ tabId: UUID, by window: MainWindowController) -> MainWindowController? {
        let previous = displayingWindow(ofTab: tabId)
        displayingWindowByTab[tabId] = ObjectIdentifier(window)
        browserState.displayedTabIds.insert(tabId)
        return previous === window ? nil : previous
    }

    /// Ends `window`'s display of `tabId`; a no-op when another window has taken it since.
    /// A window waiting for the tab shows it again right away.
    func release(_ tabId: UUID, by window: MainWindowController) {
        guard displayingWindowByTab[tabId] == ObjectIdentifier(window) else { return }
        displayingWindowByTab.removeValue(forKey: tabId)
        browserState.displayedTabIds.remove(tabId)
        windows.first { $0 !== window && $0.placeholderTabId == tabId }?.reclaimDisplayedTab(tabId)
    }
}
