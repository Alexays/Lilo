import Foundation
import OSLog
import WebKit

/// Manages the tab lifecycle, including creation, switching, closing, and reordering.
/// Scoped to a single window (not a singleton) for multi-window readiness.
@MainActor
final class TabManager {
    @MainActor
    protocol Delegate: AnyObject {
        func tabManager(_ manager: TabManager, didActivateTab id: UUID)
        func tabManager(_ manager: TabManager, didUpdateTab tab: Tab)
    }

    /// The displayed space's live runtime, shared with every other window showing that space.
    private(set) var engineHost: EngineHost
    private let engineFactory: WKEngineFactory
    static let logger = Logger(liloCategory: "tab-manager")

    /// The data store to use for new tabs (set per-profile or ephemeral for private spaces).
    var dataStore: WKEngineDataStore?
    /// Profile of the displayed space: new engines bind to its extension controller.
    var profileId: UUID?

    /// The space ID to assign to new tabs.
    var currentSpaceId: UUID?

    /// Owns the durable tree and the runtime overlay; tab lists are derived from it on demand (see
    /// `TabManager+StateMirror`), so there is no cached tab index here.
    var browserStateStore: BrowserStateStore? {
        didSet { if let browserStateStore { runtimeOverlay = browserStateStore.runtimeOverlay } }
    }
    /// The store's overlay once a store is attached, so live and parked spaces share one owner.
    var runtimeOverlay = RuntimeOverlayStore()

    /// The currently active tab ID.
    var activeTabId: UUID?

    /// Terminal tabs' shells and views, app-wide like the tabs they serve; web engines live in `engineHost`.
    let terminalHost: TerminalHost
    /// Changes tabs' views, app-wide like the terminals whose repositories they show.
    let changesHost: ChangesHost

    /// Delegate for tab lifecycle events.
    weak var delegate: Delegate?

    /// Delegate wired onto each engine as it is configured (navigation/title/permission callbacks).
    /// The app assigns MainWindowController to both this and `delegate`; lifecycle-only tests leave it nil.
    weak var engineDelegate: WKWebViewTab.Delegate?

    /// Registry for the active profile. When set, tab lifecycle events are forwarded to the extension controller.
    weak var extensionRegistry: ProfileExtensionRegistry?

    /// Adapter for the window containing these tabs.
    weak var windowAdapter: WindowExtensionAdapter?

    /// Tabs whose engine was built for an extension page before that extension loaded (a launch restore
    /// racing the extensions' restore): the page stays blank until the engine is rebuilt.
    var tabsAwaitingTheirExtension: Set<UUID> = []

    /// Visible order of current-space tabs as last reported to extensions,
    /// used to detect reorders and fire `tabs.onMoved`. Maintained only by `emitTabMovedEventsIfNeeded`.
    var lastExtensionTabMoveOrder: [UUID] = []

    init(engineFactory: WKEngineFactory, terminalHost: TerminalHost = TerminalHost(), changesHost: ChangesHost = ChangesHost()) {
        self.engineFactory = engineFactory
        self.terminalHost = terminalHost
        self.changesHost = changesHost
        engineHost = EngineHost(engineFactory: engineFactory)
    }

    /// Shows a space another window already shows: its live runtime is used as is, nothing is restored.
    func adoptSharedRuntime(_ host: EngineHost, spaceId: UUID) {
        engineHost = host
        currentSpaceId = spaceId
        activeTabId = nil
    }

    /// Leaves a space another window still shows: its runtime stays live there, this window starts empty.
    func detachSharedRuntime() {
        engineHost = EngineHost(engineFactory: engineFactory)
        activeTabId = nil
    }

    // MARK: - Accessors

    var activeTab: Tab? {
        guard let id = activeTabId, let tab = tab(for: id), !tab.isClosed else { return nil }
        if let currentSpaceId, tab.spaceId != currentSpaceId { return nil }
        return tab
    }

    var activeEngineTab: WKWebViewTab? {
        guard let activeTab else { return nil }
        return engineHost.engine(for: activeTab.id)
    }

    var activeOpenTabId: UUID? { activeTab?.id }

    /// The split the active tab belongs to, if any: all its panes are on screen.
    var activeSplit: SplitGroup? {
        guard let activeTab, let spaceId = activeTab.spaceId else { return nil }
        return browserStateStore?.space(id: spaceId)?.spaceTab.splitGroup(containing: activeTab.id)
    }

    var openTabs: [Tab] {
        currentTabs.filter { tab in
            !tab.isClosed && currentSpaceId.map { tab.spaceId == $0 } != false
        }
    }

    func engineTab(for id: UUID) -> WKWebViewTab? { engineHost.engine(for: id) }

    /// The view already showing a tab, without starting a shell or reviving a discarded engine.
    func loadedContentView(forTabId id: UUID) -> NSView? {
        terminalHost.view(for: id) ?? changesHost.view(for: id) ?? engineHost.engine(for: id)?.view
    }

    /// The view that shows a tab: its terminal (shell started on first use), its diff, or its live
    /// web engine.
    func contentView(forTabId id: UUID) -> NSView? {
        guard let tab = tab(for: id) else { return nil }
        switch tab.kind {
        case .terminal: return terminalHost.ensureView(for: tab)
        case .changes: return changesHost.ensureView(for: tab)
        case .web: return ensureLiveEngine(forTabId: id)?.view
        }
    }
    func engineTab(forWebView webView: WKWebView) -> WKWebViewTab? { engineHost.engine(forWebView: webView) }
    /// A background space's tab of this window's profile too: it stays open to extensions in its space's window.
    func tabAdapter(for id: UUID) -> TabExtensionAdapter? {
        if let adapter = engineHost.tabAdapter(for: id) { return adapter }
        guard let adapter = browserStateStore?.tabAdapter(forTab: id), adapter.profileId == extensionRegistry?.profileId else { return nil }
        return adapter
    }
    func runtimeSnapshot() -> TabRuntimeSnapshot {
        engineHost.snapshot(tabs: currentTabs, activeTabId: activeTabId)
    }

    /// A failed form submission reloads the page it was sent from: a load of its URL would be a GET without the form.
    func reloadActiveTab(fromOrigin: Bool = false) {
        if let s = activeTab?.navigationErrorURL, !s.isEmpty, let url = URL(string: s), activeEngineTab?.pendingMainFrameSendsBody != true {
            activeEngineTab?.loadURL(url)
        } else if fromOrigin {
            activeEngineTab?.reloadFromOrigin()
        } else {
            activeEngineTab?.reload()
        }
    }

    // MARK: - Lifecycle

    /// `nativeConfiguration` is a popup's, from WebKit, which loads it; otherwise `loadPreparedTab`
    /// loads `url` once the tab is attached.
    func prepareTabRuntime(
        url: URL? = nil,
        isPinned: Bool = false,
        nativeConfiguration: WKWebViewConfiguration? = nil
    ) -> Tab {
        let (engine, url) = makeEngine(tabId: nil, loading: url, nativeConfiguration: nativeConfiguration)

        var tab = Tab(
            id: engine.id,
            url: url,
            title: Tab.fallbackTitle(for: url),
            isPinned: isPinned,
            spaceId: currentSpaceId
        )
        if url != nil { tab.isLoading = true }
        return tab
    }

    /// A tab around a page popup's live engine: its page, history and opener carry over.
    func prepareTabRuntime(adopting engine: WKWebViewTab) -> Tab {
        engineHost.adopt(engine)
        configureEngineRuntime(engine)
        let url = engine.currentURL
        return Tab(id: engine.id, url: url, title: engine.currentTitle ?? Tab.fallbackTitle(for: url), spaceId: currentSpaceId)
    }

    /// Opens `tab` to extensions, loaded or not, as Chrome lists every tab; `opener` is its `openerTabId`.
    func attachPreparedTabRuntime(for tab: Tab, opener: UUID? = nil) {
        guard tab.kind == .web, !tab.isClosed, engineHost.tabAdapter(for: tab.id) == nil,
              let registry = extensionRegistry,
              let window = windowAdapter,
              let adapter = installExtensionAdapter(tabId: tab.id, engine: engineHost.engine(for: tab.id), window: window) else { return }
        adapter.parent = opener.flatMap(engineHost.tabAdapter(for:))
        registry.controller.didOpenTab(adapter)
    }

    func loadPreparedTab(_ tab: Tab, nativeConfiguration: WKWebViewConfiguration?) {
        guard nativeConfiguration == nil, let url = tab.url else { return }
        engineHost.engine(for: tab.id)?.loadURL(url)
    }

    func discardPreparedTabRuntime(for id: UUID) {
        if let adapter = engineHost.removeTabAdapter(for: id), let registry = extensionRegistry {
            registry.controller.didCloseTab(adapter, windowIsClosing: false)
        }
        engineHost.teardown(engineHost.removeEngine(for: id))
        // Close/discard removes the tab from the tree; drop its overlay entry at the source so it can't
        // orphan. This is what lets the post-command projection skip the O(all-tabs) global prune.
        runtimeOverlay.removeRuntimeState(for: id)
    }

    /// The password-protected folder holding `tab` at any depth, locked or not.
    func protectingFolder(of tab: Tab) -> TabFolder? {
        guard let spaceId = tab.spaceId else { return nil }
        return browserStateStore?.space(id: spaceId)?.spaceTab.protectingFolder(of: tab.id)
    }

    /// The active tab unless it sits in a locked folder: what copy, share, duplicate and Handoff may expose.
    var visibleActiveTab: Tab? {
        guard let tab = activeTab, protectingFolder(of: tab)?.isLocked != true else { return nil }
        return tab
    }

    func activateTabRuntime(id: UUID) {
        guard let tab = tab(for: id) else { return }

        // A locked folder's tab can be selected, never loaded: the window shows the lock placeholder.
        // A non-web tab has no engine to wake.
        if tab.kind != .web || protectingFolder(of: tab)?.isLocked == true {
            activeTabId = id
            browserStateStore?.noteTabActivated(id)
            delegate?.tabManager(self, didActivateTab: id)
            // Extensions see the window's stand-in tab active instead.
            if let windowAdapter, let previousAdapter = windowAdapter.activeAdapter, let registry = extensionRegistry {
                windowAdapter.activeAdapter = nil
                guard registry.hasLoadedExtensions, let shown = windowAdapter.activeTab else { return }
                registry.controller.didActivateTab(shown, previousActiveTab: previousAdapter)
                registry.refreshActionsForActiveTabChange()
            }
            return
        }
        if engineHost.engine(for: id)?.isPageLost == true {
            discardEngines([id])
        }
        if engineHost.engine(for: id) == nil {
            createEngine(forTabId: id)
        }
        engineHost.engine(for: id)?.resume()   // no-op if it was never frozen
        activeTabId = id
        // Runtime-path activations (space-switch restore, non-command) must stamp lastActiveAt too,
        // else it stays nil and the tab is never idle-frozen/discarded.
        browserStateStore?.noteTabActivated(id)

        delegate?.tabManager(self, didActivateTab: id)

        if let adapter = engineHost.tabAdapter(for: id), let registry = extensionRegistry {
            let previousAdapter = windowAdapter?.activeTab
            windowAdapter?.activeAdapter = adapter
            guard registry.hasLoadedExtensions else { return }
            // A space shown again keeps its active tab, as a window focused again does in Chrome.
            if previousAdapter !== adapter { registry.controller.didActivateTab(adapter, previousActiveTab: previousAdapter) }
            // The toolbar action icon/badge can be tab-specific; re-render for the new active tab.
            registry.refreshActionsForActiveTabChange()
        }
    }

    /// Update tab metadata (called from engine delegate callbacks).
    @discardableResult
    func updateTab(id: UUID, mutate: (inout Tab) -> Void) -> Tab? {
        // The tab is read once and serves as both the extension-diff baseline and the mutation base.
        guard let oldTab = tab(for: id) else { return nil }
        let updatedTab = applyMutation(to: oldTab, mutate)
        notifyExtensionsOfChanges(from: oldTab, to: updatedTab)
        return updatedTab
    }

    /// Post-mutation bookkeeping for a tab already updated through `BrowserStateStore.updateTab`
    /// (which ran the mutation and wrote the overlay): clears the active id if the active tab just
    /// closed and forwards the changed-properties diff to the extension controller.
    func noteTabUpdated(old: Tab, new: Tab) {
        if activeTabId == new.id, new.isClosed {
            activeTabId = nil
        }
        notifyExtensionsOfChanges(from: old, to: new)
    }

    /// Tells the extension controller which of the tab properties extensions see differ between the two states.
    private func notifyExtensionsOfChanges(from old: Tab, to new: Tab) {
        guard let adapter = tabAdapter(for: new.id), let registry = extensionRegistry, registry.hasLoadedExtensions else { return }
        var changed: WKWebExtension.TabChangedProperties = []
        // WebKit reads the url extensions see, which a navigation's start, redirect and commit may each change, or not.
        let url = adapter.engineTab == nil ? new.url : adapter.extensionURL
        if url != adapter.reportedURL {
            adapter.reportedURL = url
            changed.insert(.URL)
        }
        if new.title != old.title { changed.insert(.title) }
        if new.isLoading != old.isLoading { changed.insert(.loading) }
        if new.isAudioPlaying != old.isAudioPlaying { changed.insert(.playingAudio) }
        if new.isMuted != old.isMuted { changed.insert(.muted) }
        if new.isPinned != old.isPinned { changed.insert(.pinned) }
        if !changed.isEmpty {
            registry.controller.didChangeTabProperties(changed, for: adapter)
        }
    }

    /// Mute or unmute a tab.
    func setTabMuted(id: UUID, muted: Bool) {
        guard let updatedTab = updateTab(id: id, mutate: { $0.isMuted = muted }) else { return }
        (engineHost.engine(for: id) ?? browserStateStore?.liveEngine(forTab: id))?.setMuted(muted)
        delegate?.tabManager(self, didUpdateTab: updatedTab)
    }

    func setTabMicrophoneMuted(id: UUID, muted: Bool) {
        guard let updatedTab = mutateTab(id: id, { $0.isMicrophoneMuted = muted }) else { return }

        engineHost.engine(for: id)?.setMicrophoneMuted(muted)

        delegate?.tabManager(self, didUpdateTab: updatedTab)
    }

    func tabIndex(for id: UUID) -> Int? {
        currentTabs.firstIndex(where: { $0.id == id })
    }

    /// Resolves a tab and its space via the store's O(1) lookup plus this runtime overlay. Current space only: callers assume a visible tab,
    /// so a stale id from another space must no-op rather than mutate a hidden space or trip the last-tab window close.
    func context(for id: UUID) -> (tab: Tab, spaceId: UUID)? {
        guard let resolved = browserStateStore?.durableTab(for: id),
              resolved.spaceId == currentSpaceId else { return nil }
        return (runtimeOverlay.applied(to: resolved.tab), resolved.spaceId)
    }

    @discardableResult
    func mutateTab(id: UUID, _ mutate: (inout Tab) -> Void) -> Tab? {
        guard let tab = tab(for: id) else { return nil }
        return applyMutation(to: tab, mutate)
    }

    /// One runtime-applied tab via the store's O(1) accessors, falling back to the context path without a store. The overlay applies here,
    /// not in the store, because TabManager owns the authoritative overlay.
    func tab(for id: UUID) -> Tab? {
        if let resolved = browserStateStore?.durableTab(for: id) {
            return runtimeOverlay.applied(to: resolved.tab)
        }
        return tabContext(for: id)?.tab
    }

    /// Applies `mutate` to a base tab, writes the result into the flat runtime overlay, and clears the
    /// active id if the active tab just closed. Shared by `mutateTab`/`updateTab` so the tab is read once.
    private func applyMutation(to base: Tab, _ mutate: (inout Tab) -> Void) -> Tab {
        var updatedTab = base
        mutate(&updatedTab)
        runtimeOverlay.setRuntimeState(from: updatedTab)
        if activeTabId == updatedTab.id, updatedTab.isClosed {
            activeTabId = nil
        }
        return updatedTab
    }

    func adjacentOpenTabId(around index: Int, excluding excludedTabId: UUID?) -> UUID? {
        let tabs = currentTabs
        if tabs.indices.contains(index),
           let nextRight = tabs[index...].first(where: { !$0.isClosed && $0.id != excludedTabId }) {
            return nextRight.id
        }

        if index > 0,
           let nextLeft = tabs[..<index].last(where: { !$0.isClosed && $0.id != excludedTabId }) {
            return nextLeft.id
        }

        return tabs.first(where: { !$0.isClosed && $0.id != excludedTabId })?.id
    }

    /// Live engine for a tab-share source: resumes a frozen one, or recreates and reloads a
    /// discarded one, without activating the tab (sharing must not switch the visible tab).
    func ensureLiveEngine(forTabId id: UUID) -> WKWebViewTab? {
        if let tab = tab(for: id), tab.kind != .web || protectingFolder(of: tab)?.isLocked == true { return nil }
        if engineHost.engine(for: id)?.isPageLost == true {
            discardEngines([id])
        }
        if let engine = engineHost.engine(for: id) {
            engine.resume()
            return engine
        }
        return createEngine(forTabId: id)
    }

    /// Loads `url` in the tab, waking a discarded one. Moving between a web page and an extension's
    /// pages, or between two extensions, rebuilds the engine in the configuration `url` needs.
    func load(_ url: URL, inTab id: UUID) {
        guard let tab = tab(for: id), tab.kind == .web, protectingFolder(of: tab)?.isLocked != true else { return }
        if let engine = engineHost.engine(for: id) {
            let host = extensionRegistry?.extensionNavigationTarget(for: url)?.url.host?.lowercased()
            // Another window shows this tab: it keeps its engine.
            guard host != engine.extensionHost, id == activeTabId || browserStateStore?.displayedTabIds.contains(id) != true else {
                engine.loadURL(url)
                return
            }
            discardEngine(id)
        }
        createEngine(forTabId: id, url: url)
        if id == activeTabId { activateTabRuntime(id: id) }
    }

    /// A new engine for `url`, in its extension's configuration when it is an extension page, and the
    /// URL to load, normalized to the running extension's host. A page of an extension not loaded
    /// yet is noted: the tab is rebuilt once it loads.
    private func makeEngine(
        tabId: UUID?,
        loading url: URL?,
        nativeConfiguration: WKWebViewConfiguration? = nil,
        markRestoring: Bool = false
    ) -> (engine: WKWebViewTab, url: URL?) {
        let target = nativeConfiguration == nil ? url.flatMap { extensionRegistry?.extensionNavigationTarget(for: $0) } : nil
        let store = dataStore ?? engineFactory.defaultDataStore()
        let engine = engineHost.createEngine(
            dataStore: store, profileId: profileId, tabId: tabId,
            nativeConfiguration: nativeConfiguration ?? target?.webViewConfiguration, markRestoring: markRestoring
        )
        engine.extensionHost = target?.url.host?.lowercased()
        configureEngineRuntime(engine)
        let scheme = url?.scheme?.lowercased()
        if target == nil, nativeConfiguration == nil, scheme == "chrome-extension" {
            tabsAwaitingTheirExtension.insert(engine.id)
        } else {
            tabsAwaitingTheirExtension.remove(engine.id)
        }
        return (engine, target?.url ?? url)
    }

    /// `url` overrides the tab's own page and its saved history.
    @discardableResult
    private func createEngine(forTabId id: UUID, url requestedURL: URL? = nil) -> WKWebViewTab? {
        guard engineHost.engine(for: id) == nil,
              let tab = tab(for: id) else { return engineHost.engine(for: id) }

        let (engine, loadURL) = makeEngine(
            tabId: id,
            loading: requestedURL ?? ((tab.isPinned || tab.isBookmarked) ? (tab.homeURL ?? tab.url) : tab.url),
            markRestoring: true
        )
        // A rebuilt engine (discard, crash, extension change) takes back what the tab was set to.
        if tab.isMuted { engine.setMuted(true) }
        engine.isAgentControlled = tab.isAgentControlled

        // A discarded tab's adapter takes the new engine, so extensions keep the tab id they hold, as in
        // Chrome. WebKit asks the adapter for its web view on every lookup, so the swap is enough.
        if let existingAdapter = engineHost.tabAdapter(for: id) {
            existingAdapter.engineTab = engine
            windowAdapter?.add(tab: existingAdapter)
        } else if let registry = extensionRegistry, let window = windowAdapter,
                  let adapter = installExtensionAdapter(tabId: id, engine: engine, window: window) {
            registry.controller.didOpenTab(adapter)
        }

        // An extension tab reloads its page fresh: its saved history may name a stale extension host.
        // A state with no page (a blank tab, or a page whose first load failed) loads the tab's URL instead.
        let savedState = engineHost.consumeSavedInteractionState(for: id)
        if let savedState, requestedURL == nil, engine.extensionHost == nil, engine.restoreInteractionState(savedState) {
            updateTab(id: id) { $0.isLoading = engine.isLoading }
        } else if let url = loadURL {
            engine.loadURL(url); updateTab(id: id) { $0.isLoading = true }
        }

        return engine
    }

    private func configureEngineRuntime(_ engine: WKWebViewTab) {
        engine.delegate = engineDelegate
        engine.tabManager = self
        engine.extensionContextMenuItemsProvider = { [weak self, weak engine] in
            guard let self, let engine,
                  let registry = self.extensionRegistry,
                  let adapter = self.engineHost.tabAdapter(for: engine.id) else { return [] }
            return registry.loadedExtensions.flatMap { entry in
                let items = entry.context.menuItems(for: adapter)
                registry.noteUserGestures(choosing: items, extensionId: entry.id)
                return items
            }
        }
    }

    /// Nil for a tab of the other privacy than `window`'s. An unloaded tab (no `engine`) is in the displayed space, whose
    /// privacy the window follows.
    func installExtensionAdapter(tabId: UUID, engine: WKWebViewTab?, window: WindowExtensionAdapter) -> TabExtensionAdapter? {
        // A private tab lives only in the private extension window, which hides it from extensions not allowed there.
        guard engine.map({ $0.isPrivateBrowsing == window.isPrivateWindow }) ?? true else { return nil }
        let adapter = TabExtensionAdapter(tabId: tabId, engineTab: engine, extensionWindow: window, profileId: extensionRegistry?.profileId)
        adapter.tabManager = self
        engineHost.setTabAdapter(adapter, for: tabId)
        window.add(tab: adapter)
        return adapter
    }
}
