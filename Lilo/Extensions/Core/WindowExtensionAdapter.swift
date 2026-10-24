import AppKit
import WebKit

/// WKWebExtensionWindow wrapper: a space to extensions, or a floating panel or page popup.
@MainActor
final class WindowExtensionAdapter: NSObject, WKWebExtensionWindow {
    /// The browser window that shows the space, or showed it last: a background space reports its frame.
    weak var nsWindow: NSWindow?
    weak var tabManager: TabManager?
    private(set) var extensionTabs: [any WKWebExtensionTab] = []
    private var extensionTabIdentifiers: Set<ObjectIdentifier> = []
    weak var activeAdapter: TabExtensionAdapter?

    /// The space this window is to extensions; nil for a floating panel or a page popup, whose tab belongs to no space.
    let spaceId: UUID?

    private static let windowUnavailableError = NSError(domain: "LiloExtension", code: 1, userInfo: [NSLocalizedDescriptionKey: "Window is no longer available"])

    /// `.popup` for a page popup; its window is nil when it shows as a peek inside the browser window.
    let type: WKWebExtension.WindowType

    /// A private space is a private window, as Chrome's incognito window: WebKit hides it and its tabs
    /// from every extension without private access.
    let isPrivateWindow: Bool

    init(nsWindow: NSWindow?, spaceId: UUID? = nil, type: WKWebExtension.WindowType = .normal, isPrivate: Bool = false) {
        self.nsWindow = nsWindow
        self.spaceId = spaceId
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

    /// A space no browser window shows now.
    private var isBackgroundSpace: Bool { spaceId != nil && tabManager?.windowAdapter !== self }

    /// Stands for the active tab a browser window shows when extensions see no web tab active (a terminal, a diff, a locked
    /// folder, a restored tab not yet activated), as Chrome shows its own pages as tabs: it has no url, title or page to script.
    private lazy var contentTab = TabExtensionAdapter(tabId: UUID(), engineTab: nil, extensionWindow: self)

    /// Whether the space on screen shows a tab no adapter stands for. Never for a background space, a panel, a page popup
    /// or a space with no tab at all.
    private var showsContentTab: Bool {
        guard spaceId != nil, let tabManager, tabManager.windowAdapter === self, tabManager.activeOpenTabId != nil else { return false }
        return activeAdapter == nil
    }

    /// The tab extensions see active: a browser window showing a tab always has one, as in Chrome.
    var activeTab: TabExtensionAdapter? {
        activeAdapter ?? (showsContentTab ? contentTab : nil)
    }

    // MARK: - Exposed tab cache

    /// Every input of the exposed list: the space's tree shape (content and runtime overlay changes
    /// never reorder a tab), this window's tab set and its active tab. Any change rebuilds the list.
    private struct ExposedTabsKey: Equatable {
        var structureToken: UUID?
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
        let store = tabManager?.browserStateStore
        let key = ExposedTabsKey(
            structureToken: spaceId.flatMap { store?.space(id: $0)?.spaceTab.structureToken },
            membershipVersion: membershipVersion,
            activeAdapter: activeAdapter.map { ObjectIdentifier($0) },
            showsContentTab: showsContentTab
        )
        guard key != exposedTabsKey else { return }

        var positionById: [UUID: Int] = [:]
        if let tabManager, let spaceId {
            for (index, tab) in tabManager.tabs(forSpace: spaceId).enumerated() { positionById[tab.id] = index }
        }
        var ranked: [(offset: Int, position: Int, tab: any WKWebExtensionTab)] = []
        ranked.reserveCapacity(extensionTabs.count)
        for (offset, tab) in extensionTabs.enumerated() {
            let position = (tab as? TabExtensionAdapter).flatMap { positionById[$0.tabId] } ?? Int.max
            ranked.append((offset, position, tab))
        }
        ranked.sort { $0.position == $1.position ? $0.offset < $1.offset : $0.position < $1.position }
        var tabs = ranked.map(\.tab)
        var indexByTab: [ObjectIdentifier: Int] = [:]
        indexByTab.reserveCapacity(tabs.count + 1)
        for (index, tab) in tabs.enumerated() { indexByTab[ObjectIdentifier(tab as AnyObject)] = index }
        if let active = activeAdapter ?? (key.showsContentTab ? contentTab : nil), indexByTab[ObjectIdentifier(active)] == nil {
            indexByTab[ObjectIdentifier(active)] = tabs.count
            tabs.append(active)
        }
        exposedTabs = tabs
        exposedIndexByTab = indexByTab
        exposedTabsKey = key
    }

    /// The index of `tab` in `tabs(for:)`, so it satisfies the `WKWebExtensionTab` contract
    /// (`tabs(for:)[tab.indexInWindow(for:)] == tab`); `NSNotFound` when the tab is not in this window.
    func index(of tab: any WKWebExtensionTab) -> Int {
        refreshExposedTabs()
        return exposedIndexByTab[ObjectIdentifier(tab as AnyObject)] ?? NSNotFound
    }

    // MARK: - WKWebExtensionWindow

    /// Exposed tabs in visible sidebar order, so the order matches `TabExtensionAdapter.indexInWindow`.
    /// Tabs whose position is unknown keep their relative order at the end (stable).
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        refreshExposedTabs()
        return exposedTabs
    }

    /// WebKit drops every tab of a window whose active tab its list lacks: the space on screen showing a tab no adapter stands
    /// for names its stand-in, any other window its first tab.
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        activeTab ?? tabs(for: context).first
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { type }
    /// WebKit caches the answer for the window's lifetime and stamps it on every tab: a window never
    /// changes it, so private tabs live in their own window.
    func isPrivate(for context: WKWebExtensionContext) -> Bool { isPrivateWindow }

    /// A background space reads as a normal window behind the one shown, as Chrome has no hidden window state.
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = nsWindow, !isBackgroundSpace else { return .normal }
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

    /// Focusing a background space shows it in the browser window that showed it last.
    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window = nsWindow else { completionHandler(Self.windowUnavailableError); return }
        if isBackgroundSpace, let spaceId { (window.windowController as? MainWindowController)?.switchToSpace(spaceId) }
        window.makeKeyAndOrderFront(nil); completionHandler(nil)
    }

    /// Closing a space's window closes the browser window showing it; a background space has none to close.
    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window = nsWindow, !isBackgroundSpace else { completionHandler(Self.windowUnavailableError); return }
        window.close(); completionHandler(nil)
    }
}
