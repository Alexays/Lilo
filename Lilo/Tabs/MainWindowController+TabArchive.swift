import AppKit

extension MainWindowController {
    /// Archives the top-level unpinned web tabs of this window's Space, the ones on screen (docked or
    /// floating included) and busy ones aside; the undo toast puts them back where they were.
    @objc func clearUnpinnedTabs(_ sender: Any?) {
        guard let spaceId = tabManager.currentSpaceId,
              let unpinned = context.browserState.spaceTabState(forSpace: spaceId)?.tree.unpinned else { return }
        let shown = context.browserState.displayedTabIds.union([tabManager.activeTabId, tabDock.engineId, floatingTabPanel.hostedEngineId, documentPiP.openerId].compactMap { $0 })
        var archivedIds: [String] = []
        var lastTitle = ""
        for (index, node) in unpinned.enumerated() {
            guard case let .tab(tab) = node, !tab.isClosed, tab.kind == .web,
                  let url = tab.url.flatMap(URL.init(string:)), !shown.contains(tab.id),
                  let runtimeTab = tabManager.tab(for: tab.id),
                  !context.isBusy(runtimeTab, engine: tabManager.engineTab(for: tab.id)) else { continue }
            let entry = TabArchive.Entry(spaceId: spaceId, url: url, title: tab.title, index: index)
            context.tabArchive.add(entry)
            closeTabStateFirst(id: tab.id, undoable: false, askingPage: false)
            archivedIds.append(entry.id.uuidString)
            lastTitle = tab.title
        }
        guard !archivedIds.isEmpty else { return }
        bridgeRouter.send(event: "tabClosedUndoable", data: ["title": lastTitle, "count": archivedIds.count, "archivedIds": archivedIds])
    }

    @objc func showArchivedTabs(_ sender: Any?) {
        focusChrome()
        bridgeRouter.send(event: "openCommandBar", data: ["prefill": "<"])
    }

    /// This window's Space's archived tabs, newest first, for the command bar.
    func archivedTabSummaries() -> [[String: Any]] {
        guard let spaceId = tabManager.currentSpaceId else { return [] }
        return context.tabArchive.entries.reversed().filter { $0.spaceId == spaceId }.map { entry in
            [
                "id": entry.id.uuidString,
                "url": entry.url.absoluteString,
                "title": entry.title,
                "archivedAt": entry.archivedAt.timeIntervalSince1970 * 1000
            ]
        }
    }

    /// Reopens archived tabs unloaded in their Space's unpinned list, at the end or where a Clear took
    /// them from; a single one is shown.
    func restoreArchivedTabs(_ ids: Set<UUID>) {
        let entries = context.tabArchive.remove(ids).sorted { ($0.index ?? .max) < ($1.index ?? .max) }
        guard let first = entries.first else { return }
        if first.spaceId != tabManager.currentSpaceId, context.spaceManager?.space(with: first.spaceId) != nil {
            requestSpaceSwitch(id: first.spaceId)
        }
        guard let spaceId = tabManager.currentSpaceId else { return }
        var restoredId: UUID?
        for entry in entries {
            let tab = Tab(url: entry.url, title: entry.title, spaceId: spaceId)
            guard (try? applyBrowserCommand(.createTab(spaceId: spaceId, tab: tab, activate: false))) != nil else { continue }
            if let index = entry.index {
                _ = try? applyBrowserCommand(.moveSidebarItem(
                    spaceId: spaceId, kind: .tab, itemId: tab.id, parentFolderId: nil, section: .unpinned, insert: .index(index)
                ))
            }
            tabManager.attachPreparedTabRuntime(for: tab)
            restoredId = tab.id
        }
        if entries.count == 1, let restoredId { activateTabStateFirst(id: restoredId) }
    }

    func clearArchivedTabs() {
        guard let spaceId = tabManager.currentSpaceId else { return }
        context.tabArchive.entries.removeAll { $0.spaceId == spaceId }
    }
}
