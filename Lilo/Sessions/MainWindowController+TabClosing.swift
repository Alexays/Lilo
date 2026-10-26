// State-first tab lifecycle: create, close, reopen and activate.

import AppKit
import os
import WebKit

// MARK: - State-First Tab Lifecycle

extension MainWindowController {
    /// The sidebar row of `tabId` when a tab opened from it goes right below it: only an unpinned row outside a
    /// split, as a pinned or bookmarked spot would pin or bookmark the new tab and a split's folder would add a pane.
    func sidebarItemBeside(_ tabId: UUID) -> TabTreeItem? {
        guard let spaceId = tabManager.context(for: tabId)?.spaceId,
              let item = tabManager.sidebarTreeItems(forSpace: spaceId).first(where: { $0.kind == .tab && $0.itemId == tabId }),
              item.section == .unpinned,
              item.parentFolderId.flatMap({ tabManager.folder(id: $0) })?.isSplit != true else { return nil }
        return item
    }

    /// Opens `tab`'s page again in a new active tab, right below it when the sidebar allows.
    func duplicateTab(_ tab: Tab) {
        guard let url = tab.url else { return }
        let beside = sidebarItemBeside(tab.id)
        createTabStateFirst(
            url: url,
            sidebarParentFolderId: beside?.parentFolderId,
            sidebarSection: beside?.section,
            sidebarIndex: beside.map { $0.sortOrder + 1 }
        )
    }

    /// `opener` is the tab extensions see as the new tab's `openerTabId`.
    @discardableResult
    func createTabStateFirst(
        url: URL?,
        activate: Bool = true,
        opener: UUID? = nil,
        nativeConfiguration: WKWebViewConfiguration? = nil,
        adopting adoptedEngine: WKWebViewTab? = nil,
        sidebarParentFolderId: UUID? = nil,
        sidebarSection: TabTreeItem.Section? = nil,
        sidebarIndex: Int? = nil
    ) -> Tab? {
        guard let spaceId = tabManager.currentSpaceId else { return nil }
        let tab = adoptedEngine.map(tabManager.prepareTabRuntime(adopting:))
            ?? tabManager.prepareTabRuntime(url: url, nativeConfiguration: nativeConfiguration)

        do {
            try applyBrowserCommand(.createTab(spaceId: spaceId, tab: tab, activate: activate))
            if let sidebarSection, let sidebarIndex {
                try applyBrowserCommand(.moveSidebarItem(
                    spaceId: spaceId,
                    kind: .tab,
                    itemId: tab.id,
                    parentFolderId: sidebarParentFolderId,
                    section: sidebarSection,
                    insert: .index(sidebarIndex)
                ))
            }
            tabManager.attachPreparedTabRuntime(for: tab, opener: opener)
            if let engine = tabManager.engineTab(for: tab.id) {
                engine.delegate = self
                configureEngineIfNeeded(engine)
            }
            // An adopted page offered its icons before the tab existed, and WebKit offers them once per load.
            if let adoptedEngine { faviconCoordinator.applyCached(from: adoptedEngine) }
            // Loads ahead of activation so the request is in flight while activation does its UI work.
            if adoptedEngine == nil { tabManager.loadPreparedTab(tab, nativeConfiguration: nativeConfiguration) }
            if activate {
                tabManager.activateTabRuntime(id: tab.id)
            }
            return tab
        } catch {
            tabManager.discardPreparedTabRuntime(for: tab.id)
            Self.logger.error("create tab state command failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    @discardableResult
    func restoreClosedTabStateFirst() -> Tab? {
        context.recentlyClosed.pop().flatMap(reopenClosedTab)
    }

    /// chrome.sessions.restore: the `index`-th newest closed tab outside private spaces, the list
    /// extensions are shown.
    @discardableResult
    func restoreClosedTabForExtension(at index: Int) -> Tab? {
        context.recentlyClosed.pop(at: index, where: isVisibleToExtensions).flatMap(reopenClosedTab)
    }

    /// The `index`-th newest closed terminal, as the command bar lists them.
    @discardableResult
    func restoreClosedTerminal(at index: Int) -> Tab? {
        context.recentlyClosed.pop(at: index) { entry in
            if case .terminal = entry.content { return true }
            return false
        }.flatMap(reopenClosedTab)
    }

    /// Whether this window's extensions may see a closed tab: never a terminal, a private one or
    /// another profile's.
    func isVisibleToExtensions(_ entry: RecentlyClosedStack.Entry) -> Bool {
        guard case .page = entry.content, let space = context.spaceManager?.space(with: entry.spaceId) else { return false }
        return !space.isPrivate && space.profileId == profileContext?.profileId
    }

    func reopenClosedTab(_ entry: RecentlyClosedStack.Entry) -> Tab? {
        // Reopen in the space the tab was closed in (its profile is what the page expects);
        // a deleted space falls back to the current one.
        if entry.spaceId != tabManager.currentSpaceId, context.spaceManager?.space(with: entry.spaceId) != nil {
            requestSpaceSwitch(id: entry.spaceId)
        }
        switch entry.content {
        case .page(let url):
            return createTabStateFirst(
                url: url,
                activate: true,
                sidebarParentFolderId: entry.parentFolderId,
                sidebarSection: entry.section,
                sidebarIndex: entry.sortOrder
            )
        case .terminal(let closed):
            guard let tab = createTerminalTab(cwd: closed.cwd, resumeCommand: closed.resumeCommand, screenOf: closed.screenId) else { return nil }
            if let section = entry.section, let index = entry.sortOrder, let spaceId = tabManager.currentSpaceId {
                _ = try? applyBrowserCommand(.moveSidebarItem(
                    spaceId: spaceId, kind: .tab, itemId: tab.id,
                    parentFolderId: entry.parentFolderId, section: section, insert: .index(index)
                ))
            }
            return tab
        case .savedTab(let stored):
            guard let spaceId = tabManager.currentSpaceId else { return nil }
            let tab = Tab(stored, spaceId: spaceId, groupId: nil)
            let section = entry.section ?? .forTab(isBookmarked: stored.isBookmarked, isPinned: stored.isPinned)
            do {
                try applyBrowserCommand(.createTab(spaceId: spaceId, tab: tab, activate: false))
                if let index = entry.sortOrder {
                    try applyBrowserCommand(section == .bookmarked
                        ? .moveTabToBookmarked(spaceId: spaceId, tabId: tab.id, insert: .index(index))
                        : .moveSidebarItem(
                            spaceId: spaceId, kind: .tab, itemId: tab.id,
                            parentFolderId: entry.parentFolderId, section: section, insert: .index(index)
                        ))
                }
                tabManager.attachPreparedTabRuntime(for: tab)
                return tab
            } catch {
                Self.logger.error("restore removed tab failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    /// `undoable: false` neither records the tab for Cmd+Shift+T nor shows the undo toast; batch
    /// closes use it and record their own entries so a single toast can undo them all.
    /// `askingPage: false` skips the page's beforeunload handler, for a close no one is there to confirm.
    func closeTabStateFirst(id: UUID, undoable: Bool = true, askingPage: Bool = true) {
        guard confirmTerminalClose(id: id, undoable: undoable) else { return }
        // A page with a beforeunload handler gets to object first: WebKit runs the confirm panel
        // and comes back through tabDidRequestClose when the user leaves.
        if askingPage, let engine = tabManager.engineTab(for: id), !engine.pageRequestedClose, !engine.tryClose() { return }
        if context.mediaTabs.removeValue(forKey: id) != nil { context.mediaActivityChanged() }
        pagePopups.values.filter { $0.openerTabId == id }.forEach { $0.close() }
        sidePanel.tabWillClose(id)
        // Detach the out-of-space surfaces first: they can host a tab from another space (the pip
        // dock and the floating panel survive space switches), and the context lookup below is
        // current-space only, so cleanup placed after it would never run for those.
        floatingTabPanel.dismiss(hosting: id)
        if tabDock.engineId == id { tabDock.undock() }
        // Stop the ferry while the engine is still alive, whether the tab is its source or its
        // requester: the page gets its 'ended' event and the capture ends now, not on a watchdog tick.
        let closingView = tabManager.engineTab(for: id)?.view
        if let closingView { cancelTabSharePickers(requestedBy: closingView) }
        tabShareSessions.stop(sharing: id, requestedBy: closingView)

        guard let tabContext = tabManager.context(for: id) else { return }
        denyPermissionRequests(forTab: id)
        let spaceId = tabContext.spaceId
        let previousActiveTabId = tabManager.activeOpenTabId
        let isBlankNewTab = tabContext.tab.kind == .web && tabContext.tab.url == nil && !tabContext.tab.isPinned && !tabContext.tab.isBookmarked
        let isLastOpenTabInSpace = tabManager.openTabs.count == 1
        let shouldOpenReplacementNewTab = isLastOpenTabInSpace && !isBlankNewTab

        if isLastOpenTabInSpace, context.spaceManager?.space(with: spaceId)?.isPrivate == true {
            do {
                try deleteSpace(id: spaceId)
            } catch {
                Self.logger.error("delete private space on last tab close failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }

        // Agents open their tabs in their own folders, so a blank tab there would only sit unused: the
        // window moves to its neighbour, and with no agent connected the bar leaves the space out.
        if isLastOpenTabInSpace, case let agentsSpaceIds = context.settingsStore.agentsSpaceIds, agentsSpaceIds.contains(spaceId),
           let neighbour = context.spaceManager?.spaces.last(where: { !agentsSpaceIds.contains($0.id) && !$0.isPrivate }) {
            _ = try? applyBrowserCommand(.closeTab(spaceId: spaceId, tabId: id))
            tabManager.discardPreparedTabRuntime(for: id)
            switchToSpace(neighbour.id)
            context.agentControl.publishActivity()
            return
        }

        // The last blank tab of a space stays put: other spaces may still hold tabs, and closing
        // the window here would quit the app.
        if isLastOpenTabInSpace && isBlankNewTab { return }

        do {
            let recorded = undoable && recordClosedTabForRestore(id: id)
            let changes = try applyBrowserCommand(.closeTab(spaceId: spaceId, tabId: id))
            tabManager.discardPreparedTabRuntime(for: id)
            readerModeTabs.remove(id)
            if recorded { announceUndoableClose(of: tabContext.tab) }

            if id == previousActiveTabId, !shouldOpenReplacementNewTab,
               let next = freeTab(preferring: changes.changedState?.state.activeTabId) {
                tabManager.activateTabRuntime(id: next)
            } else if shouldOpenReplacementNewTab || id == previousActiveTabId {
                // Without a replacement, every other tab is on screen in another window.
                openBlankTabWithCommandBar()
                return
            }
            clearContentViewIfNoActiveTab()
        } catch {
            Self.logger.error("close tab state command failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func announceUndoableClose(of tab: Tab) {
        let title = tab.customTitle ?? (tab.title.isEmpty ? (tab.url?.host ?? "") : tab.title)
        bridgeRouter.send(event: "tabClosedUndoable", data: ["title": title])
    }

    /// An open pinned or bookmarked tab and a blank tab are not restorable and return false: closing the first keeps it in the
    /// sidebar. A closed one about to be removed is, whole; a terminal is, by its folder. `sidebarItemById`
    /// is a precomputed tree lookup for batch closes; without it every call re-materializes the
    /// whole sidebar tree for one item. Tabs of a password-protected folder are not restorable either.
    @discardableResult
    func recordClosedTabForRestore(id: UUID, sidebarItemById: [UUID: TabTreeItem]? = nil) -> Bool {
        guard let tabContext = tabManager.context(for: id) else { return false }
        let tab = tabContext.tab
        let spaceId = tabContext.spaceId
        guard tabManager.protectingFolder(of: tab) == nil else { return false }
        let content: RecentlyClosedStack.Entry.Content
        if tab.isPinned || tab.isBookmarked {
            guard tab.isClosed else { return false }
            content = .savedTab(StoredTab(tab))
        } else {
            switch tab.kind {
            case .web:
                guard let url = tab.url else { return false }
                content = .page(url)
            case .terminal:
                content = .terminal(.init(
                    cwd: tab.cwd ?? NSHomeDirectory(), title: tab.title, resumeCommand: tab.resumeCommand,
                    gitBranch: tab.gitBranch, screenId: tabManager.terminalHost.keepScreen(of: id) ? id : nil
                ))
            case .changes:
                return false
            }
        }
        let sidebarItem = sidebarItemById?[id]
            ?? tabManager.sidebarTreeItems(forSpace: spaceId).first { $0.kind == .tab && $0.itemId == id }
        context.recentlyClosed.push(
            content,
            spaceId: spaceId,
            parentFolderId: sidebarItem?.parentFolderId,
            section: sidebarItem?.section,
            sortOrder: sidebarItem?.sortOrder
        )
        return true
    }

    func activateTabStateFirst(id: UUID) {
        guard let tabContext = tabManager.context(for: id) else { return }
        let spaceId = tabContext.spaceId
        do {
            try applyBrowserCommand(.activateTab(spaceId: spaceId, tabId: id))
            tabManager.activateTabRuntime(id: id)
        } catch {
            Self.logger.error("activate tab state command failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
