import Foundation

// What this window shows: a tab is on screen in one window at a time, so showing it here takes it
// from the window that showed it, which then offers to take it back.

extension MainWindowController {
    /// Records the tabs now in the content area: claims the new ones, releases the ones that left.
    func updateDisplayedTabs(_ ids: Set<UUID>) {
        let registry = context.windows
        for id in displayedTabIds.subtracting(ids) { registry.release(id, by: self) }
        for id in ids.subtracting(displayedTabIds) {
            registry.claim(id, by: self)?.contentWasClaimed(id)
            tabManager.engineTab(for: id)?.runQueuedDialog(presenting: true)
        }
        displayedTabIds = ids
        tabManager.terminalHost.visibleTabIds = context.browserState.displayedTabIds
        if !ids.isEmpty, placeholderTabId != nil { showContentPlaceholder(for: nil) }
    }

    /// Another window shows `tabId` now; its view left this window's content area with it.
    func contentWasClaimed(_ tabId: UUID) {
        displayedTabIds.remove(tabId)
        if tabManager.activeOpenTabId == tabId || tabManager.activeSplit?.layout.paneIds.contains(tabId) == true {
            showContentPlaceholder(for: tabId)
        }
    }

    /// Shows the selected tab here again, taking it from the window that shows it.
    func reclaimDisplayedTab(_ tabId: UUID) {
        guard tabManager.tab(for: tabId) != nil else { return }
        tabManager.activateTabRuntime(id: tabId)
    }

    /// The tab this window shows next in its space: `preferred` unless another window shows it, else
    /// the most recently activated open tab no other window shows.
    func freeTab(preferring preferred: UUID?) -> UUID? {
        guard let spaceId = tabManager.currentSpaceId else { return nil }
        let registry = context.windows
        let openIds = Set(tabManager.openTabs.map(\.id))
        let isFree = { (id: UUID) in openIds.contains(id) && (registry.displayingWindow(ofTab: id).map { $0 === self } ?? true) }
        if let preferred, isFree(preferred) { return preferred }
        let history = context.browserState.spaceTabState(forSpace: spaceId)?.activationHistory ?? []
        return history.first(where: isFree) ?? tabManager.openTabs.first { isFree($0.id) }?.id
    }

    /// Another window closed or moved away the tab this window selects: this window moves on.
    func moveOnIfSelectionLeft() {
        guard let selected = tabManager.activeTabId,
              !tabManager.openTabs.contains(where: { $0.id == selected }) else { return }
        let openIds = Set(tabManager.openTabs.map(\.id))
        updateDisplayedTabs(displayedTabIds.intersection(openIds))
        if placeholderTabId == selected { showContentPlaceholder(for: nil) }
        if let next = freeTab(preferring: nil) {
            tabManager.activateTabRuntime(id: next)
        } else if let shownElsewhere = tabManager.openTabs.first?.id {
            select(shownElsewhere, deferringActivation: false)
        } else {
            tabManager.activeTabId = nil
            clearContentViewIfNoActiveTab()
        }
    }

    /// Shows `tabId` here, or offers it back when another window shows it.
    func select(_ tabId: UUID, deferringActivation: Bool) {
        if let other = context.windows.displayingWindow(ofTab: tabId), other !== self {
            tabManager.activeTabId = tabId
            showContentPlaceholder(for: tabId)
        } else if deferringActivation {
            tabManager.activeTabId = tabId
        } else {
            tabManager.activateTabRuntime(id: tabId)
        }
    }

    func showContentPlaceholder(for tabId: UUID?, lockedFolderId: UUID? = nil) {
        placeholderTabId = tabId
        bridgeRouter?.send(event: "contentPlaceholder", data: [
            "tabId": tabId?.uuidString ?? "",
            "lockedFolderId": lockedFolderId?.uuidString ?? ""
        ])
    }

    /// A locked folder leaves every window: a window on one of its tabs shows the lock placeholder
    /// (automatic lock) or moves to another tab (manual lock), then every engine of the folder goes.
    func hideLockedFolder(_ folderId: UUID, spaceId: UUID, automatic: Bool) {
        guard let ids = context.browserState.space(id: spaceId)?.spaceTab.tabIds(inFolder: folderId),
              !ids.isEmpty else { return }
        let lockedIds = Set(ids)
        // The floating panel, the pip dock and a tab share can host a tab from another space.
        for window in context.windows.windows {
            for id in lockedIds {
                window.floatingTabPanel.dismiss(hosting: id)
                if window.tabDock.engineId == id { window.tabDock.undock() }
                window.tabShareSessions.stop(sharing: id)
            }
        }
        let windows = context.windows.windows.filter { $0.tabManager.currentSpaceId == spaceId }
        for window in windows {
            guard let selected = window.tabManager.activeTabId, lockedIds.contains(selected) else { continue }
            let history = context.browserState.spaceTabState(forSpace: spaceId)?.activationHistory ?? []
            let openIds = Set(window.tabManager.openTabs.map(\.id))
            let next = history.first { openIds.contains($0) && !lockedIds.contains($0) }
                ?? window.tabManager.openTabs.first { !lockedIds.contains($0.id) }?.id
            if !automatic, let next {
                window.activateTabStateFirst(id: next)
            } else {
                window.tabManager.activateTabRuntime(id: selected)
            }
        }
        if let window = windows.first {
            window.tabManager.discardEngines(lockedIds)
            window.syncActiveBrowserState()
        } else {
            context.browserState.discardParkedEngines(lockedIds, spaceId: spaceId, discardEngine: context.discardEngine)
        }
    }

    /// Windows that showed this folder's lock placeholder get their tab back.
    func revealUnlockedFolder(_ folderId: UUID) {
        for window in context.windows.windows {
            guard let id = window.placeholderTabId,
                  window.tabManager.tab(for: id)?.groupId == folderId else { continue }
            window.showContentPlaceholder(for: nil)
            window.tabManager.activateTabRuntime(id: id)
        }
    }
}
