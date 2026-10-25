import AppKit
import WebKit

/// WKWebExtensionWindow wrapper for an NSWindow.
@MainActor
final class WindowExtensionAdapter: NSObject, WKWebExtensionWindow {
    weak var nsWindow: NSWindow?
    weak var tabManager: TabManager?
    private(set) var extensionTabs: [any WKWebExtensionTab] = []
    private var extensionTabIdentifiers: Set<ObjectIdentifier> = []
    weak var activeAdapter: TabExtensionAdapter?

    /// When true, the window exposes only the current space's tabs (each space is a separate window
    /// to extensions). The per-registry main window adapter sets this; floating panel adapters leave
    /// it false so their single panel tab (which belongs to no space) stays visible.
    var scopesToCurrentSpace = false

    private static let windowUnavailableError = NSError(domain: "LiloExtension", code: 1, userInfo: [NSLocalizedDescriptionKey: "Window is no longer available"])

    /// `.popup` for a page popup; its window is nil when it shows as a peek inside the browser window.
    let type: WKWebExtension.WindowType

    /// A browser window has a second extension window for its private spaces, as Chrome's incognito
    /// window: WebKit hides it and its tabs from every extension without private access.
    let isPrivateWindow: Bool

    init(nsWindow: NSWindow?, type: WKWebExtension.WindowType = .normal, isPrivate: Bool = false) {
        self.nsWindow = nsWindow
        self.type = type
        self.isPrivateWindow = isPrivate
    }

    func add(tab: any WKWebExtensionTab) {
        guard extensionTabIdentifiers.insert(ObjectIdentifier(tab as AnyObject)).inserted else { return }
        extensionTabs.append(tab)
        membershipVersion &+= 1
    }

    func remove(tab: any WKWebExtensionTab) {
        let identifier = ObjectIdentifier(tab as AnyObject)
        if extensionTabIdentifiers.remove(identifier) != nil {
            extensionTabs.removeAll { ObjectIdentifier($0 as AnyObject) == identifier }
            membershipVersion &+= 1
        }
        if let activeAdapter, ObjectIdentifier(activeAdapter) == identifier {
            self.activeAdapter = nil
        }
    }

    // MARK: - Current-space scoping

    /// Resolved live against the tab manager so new current-space tabs appear at once; an unresolvable space (panel tab, mid-creation)
    /// counts as visible but returns nil so it is not cached. Adapters the tab manager no longer owns are never exposed (zombie tabs).
    private func isInCurrentSpace(_ tab: any WKWebExtensionTab) -> Bool? {
        guard scopesToCurrentSpace,
              let tabManager,
              let adapter = tab as? TabExtensionAdapter else { return true }
        let id = adapter.tabId
        guard tabManager.tabAdapter(for: id) === adapter else { return false }
        guard let currentSpaceId = tabManager.currentSpaceId,
              let store = tabManager.browserStateStore else { return nil }
        if store.space(currentSpaceId, contains: id) { return true }
        guard let spaceId = store.owningSpaceId(forTab: id) else { return nil }
        return spaceId == currentSpaceId
    }

    /// The active tab, but only when it belongs to the current space.
    var visibleActiveAdapter: TabExtensionAdapter? {
        guard let activeAdapter, isInCurrentSpace(activeAdapter) != false else { return nil }
        return activeAdapter
    }

    /// Stands for the active tab a browser window shows when extensions see no web tab active (a terminal, a diff, a locked
    /// folder, a restored tab not yet activated), as Chrome shows its own pages as tabs: it has no url, title or page to script.
    private lazy var contentTab = TabExtensionAdapter(tabId: UUID(), engineTab: nil, extensionWindow: self)

    /// Whether the window shows a tab of its tab manager that no visible adapter stands for. Never for the extension window
    /// (normal or private) the browser window does not show at the moment, nor for a window with no tab at all.
    private var showsContentTab: Bool {
        guard scopesToCurrentSpace, let tabManager, tabManager.windowAdapter === self, tabManager.activeOpenTabId != nil else { return false }
        return visibleActiveAdapter == nil
    }

    /// The tab extensions see active: a browser window showing a tab always has one, as in Chrome.
    var activeTab: TabExtensionAdapter? {
        visibleActiveAdapter ?? (showsContentTab ? contentTab : nil)
    }

    // MARK: - Exposed tab cache

    /// Every input of the exposed list: the current space's tree shape (content and runtime overlay
    /// changes never reorder or hide a tab), the tab manager's adapter map, this window's tab set and
    /// its active tab. Any change rebuilds the list.
    private struct ExposedTabsKey: Equatable {
        var scopesToCurrentSpace: Bool
        var tabManager: ObjectIdentifier?
        var currentSpaceId: UUID?
        var structureToken: UUID?
        var engineHost: ObjectIdentifier?
        var engineHostVersion: UInt64
        var membershipVersion: UInt64
        var activeAdapter: ObjectIdentifier?
        var showsContentTab: Bool
    }

    private var membershipVersion: UInt64 = 0
    private var exposedTabsKey: ExposedTabsKey?
    private var exposedTabs: [any WKWebExtensionTab] = []
    private var exposedIndexByTab: [ObjectIdentifier: Int] = [:]

    /// WebKit asks for each tab's index (tabs.query over N tabs asks N times), so the ordered list
    /// and its index map are built once per change of their inputs.
    private func refreshExposedTabs() {
        let spaceId = tabManager?.currentSpaceId
        let structureToken = spaceId.flatMap { tabManager?.browserStateStore?.space(id: $0)?.spaceTab.structureToken }
        let engineHost = tabManager?.engineHost
        let key = ExposedTabsKey(
            scopesToCurrentSpace: scopesToCurrentSpace,
            tabManager: tabManager.map { ObjectIdentifier($0) },
            currentSpaceId: spaceId,
            structureToken: structureToken,
            engineHost: engineHost.map { ObjectIdentifier($0) },
            engineHostVersion: engineHost?.mutationVersion ?? 0,
            membershipVersion: membershipVersion,
            activeAdapter: activeAdapter.map { ObjectIdentifier($0) },
            showsContentTab: showsContentTab
        )
        guard key != exposedTabsKey else { return }

        var positionById: [UUID: Int] = [:]
        if let tabManager, let spaceId {
            for (index, tab) in tabManager.tabs(forSpace: spaceId).enumerated() { positionById[tab.id] = index }
        }
        var cacheable = true
        var ranked: [(offset: Int, position: Int, tab: any WKWebExtensionTab)] = []
        ranked.reserveCapacity(extensionTabs.count)
        for (offset, tab) in extensionTabs.enumerated() {
            let visible = isInCurrentSpace(tab)
            if visible == nil { cacheable = false }
            guard visible != false else { continue }
            let position = (tab as? TabExtensionAdapter).flatMap { positionById[$0.tabId] } ?? Int.max
            ranked.append((offset, position, tab))
        }
        ranked.sort { $0.position == $1.position ? $0.offset < $1.offset : $0.position < $1.position }
        var tabs = ranked.map(\.tab)
        var indexByTab: [ObjectIdentifier: Int] = [:]
        indexByTab.reserveCapacity(tabs.count + 1)
        for (index, tab) in tabs.enumerated() { indexByTab[ObjectIdentifier(tab as AnyObject)] = index }
        var active: TabExtensionAdapter?
        if let activeAdapter {
            let visible = indexByTab[ObjectIdentifier(activeAdapter)] != nil ? true : isInCurrentSpace(activeAdapter)
            if visible == nil { cacheable = false }
            if visible != false { active = activeAdapter }
        }
        if active == nil, key.showsContentTab { active = contentTab }
        if let active, indexByTab[ObjectIdentifier(active)] == nil {
            indexByTab[ObjectIdentifier(active)] = tabs.count
            tabs.append(active)
        }
        exposedTabs = tabs
        exposedIndexByTab = indexByTab
        exposedTabsKey = cacheable ? key : nil
    }

    // MARK: - WKWebExtensionWindow

    /// Exposed tabs in visible sidebar order, so the order matches `TabExtensionAdapter.indexInWindow`.
    /// Tabs whose position is unknown keep their relative order at the end (stable).
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        refreshExposedTabs()
        return exposedTabs
    }

    /// The index of `tab` within this window's exposed list for `context`, so it satisfies the
    /// `WKWebExtensionTab` contract (`tabs(for:)[tab.indexInWindow(for:)] == tab`).
    /// Returns `NSNotFound` when the tab isn't exposed to the context.
    func index(of tab: any WKWebExtensionTab, for context: WKWebExtensionContext) -> Int {
        refreshExposedTabs()
        return exposedIndexByTab[ObjectIdentifier(tab as AnyObject)] ?? NSNotFound
    }

    /// WebKit drops every tab of a window whose active tab its list lacks: a browser window showing a tab no visible adapter
    /// stands for (a terminal, a restored tab not yet activated) names its stand-in, any other window its first tab.
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        activeTab ?? tabs(for: context).first
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { type }
    /// WebKit caches the answer for the window's lifetime and stamps it on every tab: a window never
    /// changes it, so private tabs live in their own window.
    func isPrivate(for context: WKWebExtensionContext) -> Bool { isPrivateWindow }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = nsWindow else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        if window.isZoomed { return .maximized }
        return .normal
    }

    func setWindowState(_ state: WKWebExtension.WindowState, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window = nsWindow else { completionHandler(Self.windowUnavailableError); return }
        switch state {
        case .minimized:
            window.miniaturize(nil)
        case .maximized:
            if !window.isZoomed { window.zoom(nil) }
        case .fullscreen:
            if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        case .normal:
            if window.isMiniaturized { window.deminiaturize(nil) } else if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) } else if window.isZoomed { window.zoom(nil) }
        @unknown default:
            break
        }
        completionHandler(nil)
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.screen?.frame ?? .zero }
    func frame(for context: WKWebExtensionContext) -> CGRect { nsWindow?.frame ?? .zero }

    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window = nsWindow else { completionHandler(Self.windowUnavailableError); return }
        window.setFrame(frame, display: true, animate: false); completionHandler(nil)
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window = nsWindow else { completionHandler(Self.windowUnavailableError); return }
        window.makeKeyAndOrderFront(nil); completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window = nsWindow else { completionHandler(Self.windowUnavailableError); return }
        window.close(); completionHandler(nil)
    }
}
