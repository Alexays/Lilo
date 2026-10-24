import Foundation
import WebKit

extension TabManager {
    func restoreVisibleRuntime(
        _ restoredTabs: [Tab],
        engines: [UUID: WKWebViewTab] = [:],
        tabAdapters: [UUID: TabExtensionAdapter] = [:],
        savedInteractionStates: [UUID: Any] = [:],
        restoringTabIds: [UUID: Date] = [:],
        activeTabId targetActiveTabId: UUID?,
        activateRestoredTab: Bool = true
    ) {
        let restoredTabIds = Set(restoredTabs.map(\.id))
        engineHost.replaceSavedInteractionStates(savedInteractionStates, validTabIds: restoredTabIds)
        replaceCurrentSpaceState(with: restoredTabs, engines: engines, tabAdapters: tabAdapters)
        engineHost.replaceRestoringTabIds(restoringTabIds)

        let resolvedActiveTabId: UUID?
        if let targetActiveTabId,
           currentTabs.contains(where: { $0.id == targetActiveTabId && !$0.isClosed }) {
            resolvedActiveTabId = targetActiveTabId
        } else {
            resolvedActiveTabId = openTabs.first?.id
        }

        guard let resolvedActiveTabId else { return }
        if activateRestoredTab {
            activateTabRuntime(id: resolvedActiveTabId)
        } else {
            activeTabId = resolvedActiveTabId
        }
    }

    private func replaceCurrentSpaceState(
        with tabs: [Tab],
        engines: [UUID: WKWebViewTab],
        tabAdapters: [UUID: TabExtensionAdapter]
    ) {
        let tabIds = Set(tabs.map(\.id))
        for tab in tabs {
            runtimeOverlay.setRuntimeState(from: tab)
        }

        let retainedRuntimeTabIds = currentSpaceId == nil ? tabIds : runtimeValidTabIds.union(tabIds)
        runtimeOverlay.retainRuntimeStates(validTabIds: retainedRuntimeTabIds)
        let replaced = engineHost.replaceEngines(engines, validTabIds: tabIds)
        retireAdapters(replaced.adapters)
        attachVisibleExtensionAdapters(for: tabIds, tabAdapters: tabAdapters)
        activeTabId = nil
        for engine in replaced.engines { engineHost.teardown(engine) }
    }

    /// Retires the extension identity of adapters the engine host dropped; otherwise the controller keeps an "open" tab over a torn-down
    /// web view that `tabs(for:)` filters out but page-proxy lookups such as `getCurrentTab` still reach.
    private func retireAdapters(_ adapters: [TabExtensionAdapter]) {
        guard let registry = extensionRegistry else { return }
        for adapter in adapters {
            registry.controller.didCloseTab(adapter, windowIsClosing: false)
        }
    }

    private func attachVisibleExtensionAdapters(for tabIds: Set<UUID>, tabAdapters: [UUID: TabExtensionAdapter]) {
        guard let window = windowAdapter else { return }

        retireAdapters(engineHost.restoreTabAdapters(tabAdapters, validTabIds: tabIds))
        for id in tabIds {
            let engine = engineHost.engine(for: id)
            if let adapter = engineHost.tabAdapter(for: id) {
                // A discarded tab has no engine but stays listed, as in Chrome.
                adapter.engineTab = engine
                window.add(tab: adapter)
            } else if let engine, engine.isPrivateBrowsing == window.isPrivateWindow {
                let adapter = TabExtensionAdapter(engineTab: engine, extensionWindow: window, profileId: extensionRegistry?.profileId)
                adapter.tabManager = self
                engineHost.setTabAdapter(adapter, for: id)
                window.add(tab: adapter)
                extensionRegistry?.controller.didOpenTab(adapter)
            }
        }
    }

    func parkCurrentSpaceRuntimeForSwitch() -> TabRuntimeSnapshot {
        let snapshot = runtimeSnapshot()
        snapshot.engines.values.forEach { $0.view.removeFromSuperview() }
        engineHost.parkRuntimeForSpaceSwitch()
        activeTabId = nil
        return snapshot
    }

    @discardableResult
    func discardRuntime(inSpace spaceId: UUID) -> [Tab] {
        let discardedTabs = tabs(forSpace: spaceId)
        let spaceTabIds = discardedTabs.map(\.id)
        Self.logger.info("""
            space runtime discard tabs=\(spaceTabIds.count, privacy: .public) \
            hosts=\(spaceTabIds.compactMap { self.engineHost.engine(for: $0)?.currentURL?.host }.joined(separator: ","), privacy: .private)
            """)
        let didDiscardActiveTab = activeTabId.map(spaceTabIds.contains) ?? false
        for id in spaceTabIds {
            let engine = engineHost.removeEngine(for: id)
            engineHost.teardown(engine)
            if let adapter = engineHost.removeTabAdapter(for: id) {
                extensionRegistry?.controller.didCloseTab(adapter, windowIsClosing: false)
            }
            runtimeOverlay.removeRuntimeState(for: id)
        }

        if didDiscardActiveTab {
            activeTabId = nil
        }

        return discardedTabs
    }

    /// Discards the active space's LRU engines, keeping the active, protected and most recent tabs up to the caller-owned `maxLiveEngines`;
    /// interaction state is stashed for a silent restore. Returns whether anything was discarded.
    @discardableResult
    func trimActiveSpaceEngines(maxLiveEngines: Int, discardThreshold: TimeInterval = .infinity) -> Bool {
        guard let spaceId = currentSpaceId else { return false }
        let availableEngineIds = engineHost.liveEngineIds
        guard !availableEngineIds.isEmpty else { return false }
        let tabs = openTabs
        guard !tabs.isEmpty else { return false }

        let lastActiveAt: [UUID: Date] = tabs.reduce(into: [:]) { dict, tab in
            if let date = tab.lastActiveAt ?? engineHost.engine(for: tab.id)?.createdAt { dict[tab.id] = date }
        }
        // activeSpaceEnginesToKeep reads only the grace periods, identical across every LifecyclePreset, so .default matches the active one;
        // the engine budget comes from the caller.
        let coordinator = TabLifecycleCoordinator(config: .default)
        let keep = coordinator.activeSpaceEnginesToKeep(
            tabs: tabs,
            availableEngineIds: availableEngineIds,
            activeTabId: activeTabId,
            activationHistory: browserStateStore?.spaceTabState(forSpace: spaceId)?.activationHistory ?? [],
            maxLiveEngines: maxLiveEngines,
            restoringTabIds: engineHost.restoringTabIds,
            lastActiveAt: lastActiveAt,
            discardThreshold: discardThreshold
        )
        var toDiscard = availableEngineIds.subtracting(keep)
        if let split = activeSplit { toDiscard.subtract(split.layout.paneIds) }
        guard !toDiscard.isEmpty else { return false }

        Self.logger.info("""
            active-space trim discards=\(toDiscard.count, privacy: .public) \
            budget=\(maxLiveEngines, privacy: .public) live=\(availableEngineIds.count, privacy: .public) \
            hosts=\(toDiscard.compactMap { self.engineHost.engine(for: $0)?.currentURL?.host }.joined(separator: ","), privacy: .private)
            """)

        discardEngines(toDiscard)
        return true
    }

    /// Release the engines of every tab nested in a folder the user just collapsed, instead of waiting
    /// for the idle sweep. The active tab and the idle-discard exemptions (audio/capture/restoring,
    /// pinned, unsaved form data) stay live. Returns whether anything was discarded.
    @discardableResult
    func discardEngines(inFolder folderId: UUID, spaceId: UUID) -> Bool {
        // Engines only ever exist for the visible space; a hidden space's are already parked.
        guard spaceId == currentSpaceId,
              let folderTabIds = browserStateStore?.space(id: spaceId)?.spaceTab.tabIds(inFolder: folderId),
              !folderTabIds.isEmpty else { return false }
        var toDiscard = engineHost.liveEngineIds.intersection(folderTabIds)
        if let activeTabId { toDiscard.remove(activeTabId) }
        guard !toDiscard.isEmpty else { return false }

        // Grace periods are identical across every LifecyclePreset, so .default matches the active one.
        let coordinator = TabLifecycleCoordinator(config: .default)
        toDiscard.subtract(coordinator.idleDiscardProtectedEngineIds(
            tabs: openTabs,
            availableEngineIds: toDiscard,
            restoringTabIds: engineHost.restoringTabIds
        ))
        guard !toDiscard.isEmpty else { return false }

        Self.logger.info("""
            collapsed-folder discard tabs=\(toDiscard.count, privacy: .public) \
            hosts=\(toDiscard.compactMap { self.engineHost.engine(for: $0)?.currentURL?.host }.joined(separator: ","), privacy: .private)
            """)

        discardEngines(toDiscard)
        return true
    }

    /// Drop live engines, stashing each one's interaction state first so a later reactivation restores
    /// it silently instead of cold-loading. The durable tabs stay in the sidebar; only the engines go.
    func discardEngines(_ ids: Set<UUID>) {
        // A tab on screen in any window keeps its engine, whichever window asked for the discard.
        for id in ids.subtracting(browserStateStore?.displayedTabIds ?? []) { discardEngine(id) }
    }

    /// Rebuilds each tab built before its extension loaded, once `extensionRegistry` resolves its page.
    /// A tab another window displays is left to that window's own call.
    func rebuildTabsAwaitingTheirExtension() {
        guard let registry = extensionRegistry else { return }
        let displayed = browserStateStore?.displayedTabIds ?? []
        for id in tabsAwaitingTheirExtension {
            guard let url = tab(for: id)?.url, registry.extensionNavigationTarget(for: url) != nil,
                  id == activeTabId || !displayed.contains(id) else { continue }
            tabsAwaitingTheirExtension.remove(id)
            discardEngine(id)
            if id == activeTabId { activateTabRuntime(id: id) }
        }
    }

    func discardEngine(_ id: UUID) {
        // removeEngine first (it clears any stale saved state for this id); the engine object is still
        // alive until the deferred teardown, so read its live interaction state and stash it now.
        guard let engine = engineHost.removeEngine(for: id) else { return }
        if let state = engine.interactionState {
            engineHost.saveInteractionState(state, for: id)
        }
        engineHost.teardown(engine)
        // The tab stays open to extensions under the same id; reactivation hands it a new engine.
        engineHost.tabAdapter(for: id)?.engineTab = nil
        runtimeOverlay.discardRuntimeState(for: id)
    }

    /// The tab's runtime state stays: a carried engine keeps playing, capturing or being driven in its new space.
    func detachTabForTransfer(id: UUID) -> (tab: Tab, engine: WKWebViewTab?)? {
        guard let context = tabContext(for: id) else { return nil }
        let removedEngine = engineHost.removeEngine(for: id)

        removedEngine?.view.removeFromSuperview()

        if activeTabId == id {
            if let nextId = adjacentOpenTabId(around: context.index, excluding: id) {
                activateTabRuntime(id: nextId)
            } else {
                activeTabId = nil
            }
        }

        return (context.tab, removedEngine)
    }
}
