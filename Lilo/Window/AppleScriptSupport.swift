import AppKit

/// AppleScript's `tab` (see Lilo.sdef). `make new tab` instantiates one detached, carrying only its
/// URL, before the window inserts it.
@MainActor
@objc(LiloScriptTab)
final class ScriptTab: NSObject {
    private(set) var tabId: UUID?
    private weak var owner: MainWindowController?
    private(set) var pendingURL: URL?

    nonisolated override init() {
        super.init()
    }

    init(tabId: UUID, owner: MainWindowController) {
        self.tabId = tabId
        self.owner = owner
        super.init()
    }

    func attach(tabId: UUID, owner: MainWindowController) {
        self.tabId = tabId
        self.owner = owner
    }

    private var tab: Tab? { tabId.flatMap { owner?.tabManager.tab(for: $0) } }
    private var engine: WKWebViewTab? { tabId.flatMap { owner?.tabManager.engineTab(for: $0) } }

    nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        // Cocoa scripting runs on the main thread; the specifier is built there and handed straight back.
        nonisolated(unsafe) var specifier: NSScriptObjectSpecifier?
        MainActor.assumeIsolated {
            guard let tabId, let windowSpecifier = owner?.window?.objectSpecifier,
                  let windowClass = windowSpecifier.keyClassDescription else { return }
            specifier = NSUniqueIDSpecifier(containerClassDescription: windowClass, containerSpecifier: windowSpecifier,
                                            key: "scriptTabs", uniqueID: tabId.uuidString)
        }
        return specifier
    }

    @objc var uniqueID: String { tabId?.uuidString ?? "" }
    @objc var scriptTitle: String { tab?.title ?? "" }
    @objc var scriptLoading: Bool { tab?.isLoading ?? false }

    @objc var scriptURL: String {
        get { tab?.url?.absoluteString ?? pendingURL?.absoluteString ?? "" }
        set {
            // Same schemes as URLs handed over by other apps: no javascript: or custom-scheme loads.
            guard let url = URL(string: newValue), let scheme = url.scheme?.lowercased(),
                  ["http", "https", "file"].contains(scheme) else {
                NSScriptCommand.current()?.scriptErrorNumber = errAECoercionFail
                NSScriptCommand.current()?.scriptErrorString = "Lilo only opens http, https and file URLs."
                return
            }
            if let tabId {
                owner?.tabManager.load(url, inTab: tabId)
            } else {
                pendingURL = url
            }
        }
    }

    @objc func handleCloseScriptCommand(_ command: NSScriptCommand) -> Any? {
        if let tabId { owner?.closeTabStateFirst(id: tabId) }
        return nil
    }

    @objc func handleReloadScriptCommand(_ command: NSScriptCommand) -> Any? {
        engine?.reload()
        return nil
    }

    @objc func handleGoBackScriptCommand(_ command: NSScriptCommand) -> Any? {
        engine?.goBack()
        return nil
    }

    @objc func handleGoForwardScriptCommand(_ command: NSScriptCommand) -> Any? {
        engine?.goForward()
        return nil
    }
}

/// The `window` class extension of Lilo.sdef. Windows other than browser windows have no tabs, and
/// neither has a window showing a private space, as for Shortcuts.
extension NSWindow {
    private var browserWindowController: MainWindowController? {
        guard let owner = windowController as? MainWindowController,
              owner.context.spaceManager?.space(with: owner.tabManager.currentSpaceId)?.isPrivate == false else { return nil }
        return owner
    }

    @objc var scriptTabs: [ScriptTab] {
        guard let owner = browserWindowController else { return [] }
        return owner.tabManager.openTabs.map { ScriptTab(tabId: $0.id, owner: owner) }
    }

    @objc func valueInScriptTabsWithUniqueID(_ uniqueID: String) -> ScriptTab? {
        guard let owner = browserWindowController, let id = UUID(uuidString: uniqueID),
              owner.tabManager.openTabs.contains(where: { $0.id == id }) else { return nil }
        return ScriptTab(tabId: id, owner: owner)
    }

    @objc var scriptActiveTab: ScriptTab? {
        guard let owner = browserWindowController, let id = owner.tabManager.activeOpenTabId else { return nil }
        return ScriptTab(tabId: id, owner: owner)
    }

    @objc var scriptActiveTabIndex: Int {
        get {
            guard let owner = browserWindowController, let id = owner.tabManager.activeOpenTabId,
                  let index = owner.tabManager.openTabs.firstIndex(where: { $0.id == id }) else { return 0 }
            return index + 1
        }
        set {
            guard let owner = browserWindowController else { return }
            let tabs = owner.tabManager.openTabs
            guard tabs.indices.contains(newValue - 1) else {
                NSScriptCommand.current()?.scriptErrorNumber = errAENoSuchObject
                return
            }
            owner.activateTabStateFirst(id: tabs[newValue - 1].id)
        }
    }

    /// `make new tab`: always appended to the current space, like a tab opened from the sidebar.
    @objc func insertObject(_ scriptTab: ScriptTab, inScriptTabsAtIndex index: Int) {
        insertInScriptTabs(scriptTab)
    }

    /// KVC only treats `scriptTabs` as mutable when both insert and remove accessors exist.
    @objc func removeObjectFromScriptTabsAtIndex(_ index: Int) {
        guard let owner = browserWindowController else { return }
        let tabs = owner.tabManager.openTabs
        guard tabs.indices.contains(index) else { return }
        owner.closeTabStateFirst(id: tabs[index].id)
    }

    @objc func insertInScriptTabs(_ scriptTab: ScriptTab) {
        guard let owner = browserWindowController, let tab = owner.createTabStateFirst(url: scriptTab.pendingURL) else {
            NSScriptCommand.current()?.scriptErrorNumber = errAEEventFailed
            return
        }
        scriptTab.attach(tabId: tab.id, owner: owner)
    }
}
