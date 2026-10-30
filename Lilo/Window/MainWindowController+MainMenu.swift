// Menu bar actions on the active tab and Space, and its live lists.

import AppKit

extension MainWindowController {
    /// Tags the Space rows the Spaces menu rebuilds between its fixed items.
    private static let spaceMenuItemTag = 7002

    /// The Spaces the Spaces menu lists and ⌃1 to ⌃9 count: a private or hidden agents one only while it is shown here.
    var switchableSpaces: [Space] {
        let hiddenAgentsSpaceIds = context.agentControl.hiddenAgentsSpaceIds
        return (context.spaceManager?.spaces ?? []).filter {
            $0.id == tabManager.currentSpaceId || (!$0.isPrivate && !hiddenAgentsSpaceIds.contains($0.id))
        }
    }

    func switchToAdjacentSpace(forward: Bool) {
        let spaces = switchableSpaces
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == tabManager.currentSpaceId }) else { return }
        requestSpaceSwitch(id: spaces[(index + (forward ? 1 : spaces.count - 1)) % spaces.count].id)
    }

    /// Selects the Nth Space (1-based); a no-op past the last one.
    func switchToSpace(ordinal: Int) {
        let spaces = switchableSpaces
        guard ordinal <= spaces.count, spaces[ordinal - 1].id != tabManager.currentSpaceId else { return }
        requestSpaceSwitch(id: spaces[ordinal - 1].id)
    }

    @objc func showNextSpace(_ sender: Any?) { switchToAdjacentSpace(forward: true) }
    @objc func showPreviousSpace(_ sender: Any?) { switchToAdjacentSpace(forward: false) }
    @objc func newSpace(_ sender: Any?) { bridgeRouter.send(event: "openAddSpaceEditor") }

    @objc func editCurrentSpace(_ sender: Any?) {
        guard let spaceId = tabManager.currentSpaceId else { return }
        bridgeRouter.send(event: "openSpaceEditor", data: ["id": spaceId.uuidString])
    }

    @objc func switchToSpaceFromMenu(_ sender: NSMenuItem) {
        guard let spaceId = sender.representedObject as? UUID else { return }
        requestSpaceSwitch(id: spaceId)
    }

    @objc func selectTabFromMenu(_ sender: NSMenuItem) { selectTab(ordinal: sender.tag) }

    @objc func openShortcuts(_ sender: Any?) {
        focusChrome()
        bridgeRouter.send(event: "openShortcuts")
    }

    @objc func closeOtherTabs(_ sender: Any?) {
        guard let tab = tabManager.activeTab else { return }
        closeOtherTabs(keeping: tab)
    }

    @objc func pinCurrentTab(_ sender: Any?) {
        guard let tab = tabManager.activeTab, let spaceId = tab.spaceId ?? tabManager.currentSpaceId else { return }
        applyContextMenuStateCommands([.setPinned(spaceId: spaceId, tabId: tab.id, isPinned: !tab.isPinned)])
    }

    @objc func moveCurrentTabToNewWindow(_ sender: Any?) {
        guard let id = tabManager.activeOpenTabId else { return }
        moveTabToNewWindow(id)
    }

    @objc func keepCurrentTabAwakeUntilDone(_ sender: Any?) {
        guard let id = tabManager.activeOpenTabId else { return }
        context.powerKeeper.keepAwakeUntilDone(id)
    }

    /// The page as a Markdown link, its title as the text.
    @objc func copyCurrentURLAsMarkdown(_ sender: Any?) {
        guard let tab = tabManager.visibleActiveTab, let url = tab.url?.absoluteString, !url.isEmpty else {
            bridgeRouter.send(event: "urlCopyFailed")
            return
        }
        let title = (tab.title.isEmpty ? url : tab.title).replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        NSPasteboard.general.clearContents()
        let didCopy = NSPasteboard.general.setString("[\(title)](\(url))", forType: .string)
        bridgeRouter.send(event: didCopy ? "urlCopied" : "urlCopyFailed")
    }

    // MARK: - Live Menus

    func populateSpacesMenu(_ menu: NSMenu) {
        menu.items.filter { $0.tag == Self.spaceMenuItemTag }.forEach(menu.removeItem)
        let agentsSpaceIds = context.settingsStore.agentsSpaceIds
        let agentsProfileId = context.settingsStore.get(AgentControl.agentsProfileKey).flatMap(UUID.init(uuidString:))
        // Below Next Space, Previous Space and their separator.
        for (index, space) in switchableSpaces.enumerated() {
            let item: NSMenuItem
            if agentsSpaceIds.contains(space.id) {
                // Each profile agents work in has its own Agents space: its profile tells them apart.
                let profile = space.profileId == agentsProfileId ? nil : context.profileManager.profiles.first { $0.id == space.profileId }
                item = NSMenuItem(title: profile.map { "\(space.name) · \($0.name)" } ?? space.name, action: #selector(switchToSpaceFromMenu(_:)), keyEquivalent: "")
                item.image = AgentCursorView.menuImage
            } else {
                item = NSMenuItem(title: "\(space.icon)  \(space.name)", action: #selector(switchToSpaceFromMenu(_:)), keyEquivalent: "")
            }
            if index < 9 { KeyboardShortcuts.show("space.select\(index + 1)", on: item) }
            item.tag = Self.spaceMenuItemTag
            item.representedObject = space.id
            item.state = space.id == tabManager.currentSpaceId ? .on : .off
            menu.insertItem(item, at: 3 + index)
        }
    }

    func populateMoveToFolderMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        if let tab = tabManager.activeTab, !tab.isBookmarked, let spaceId = tab.spaceId ?? tabManager.currentSpaceId {
            addMoveToFolderItems(to: menu, tabId: tab.id, spaceId: spaceId)
        }
        if menu.items.isEmpty { menu.addItem(withTitle: "No Folders".localized, action: nil, keyEquivalent: "") }
    }

    func populateMoveToSpaceMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        if let id = tabManager.activeOpenTabId { addMoveToSpaceItems(to: menu, tabId: id) }
        if menu.items.isEmpty { menu.addItem(withTitle: "No Other Spaces".localized, action: nil, keyEquivalent: "") }
    }

    /// The other Spaces a tab of the current Space can move to: the keyboard path for a drop on a Space. Never an
    /// Agents space: its tabs are the agents'.
    func addMoveToSpaceItems(to menu: NSMenu, tabId id: UUID) {
        let agentsSpaceIds = context.settingsStore.agentsSpaceIds
        for space in switchableSpaces where space.id != tabManager.currentSpaceId && !agentsSpaceIds.contains(space.id) {
            menu.addItem("\(space.icon)  \(space.name)") { [weak self] in
                guard let self else { return }
                do { try moveToSpace(.tab, id: id, targetSpaceId: space.id) } catch {
                    Self.logger.error("Failed to move tab \(id.uuidString, privacy: .public) to space \(space.id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Whether a closed tab reopens from this window: never into another window's private Space.
    private func isReopenableHere(_ entry: RecentlyClosedStack.Entry) -> Bool {
        context.spaceManager?.space(with: entry.spaceId).map { !$0.isPrivate || $0.id == tabManager.currentSpaceId } ?? true
    }

    func populateRecentlyClosedMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let entries = context.recentlyClosed.recentEntries.filter(isReopenableHere)
        if entries.isEmpty { menu.addItem(withTitle: "No Closed Tabs".localized, action: nil, keyEquivalent: "") }
        for (index, entry) in entries.enumerated() {
            let title: String
            let symbol: String
            switch entry.content {
            case .page(let url):
                let path = url.path == "/" ? "" : url.path
                title = url.host().map { $0 + path } ?? url.absoluteString
                symbol = "globe"
            case .terminal(let closed):
                title = closed.title.isEmpty ? URL(fileURLWithPath: closed.cwd).lastPathComponent : closed.title
                symbol = "terminal"
            case .savedTab(let tab):
                title = tab.customTitle ?? tab.title
                symbol = tab.isBookmarked ? "bookmark" : "pin"
            }
            let item = menu.addItem(title.count > 60 ? String(title.prefix(59)) + "\u{2026}" : title) { [weak self] in
                guard let self else { return }
                _ = context.recentlyClosed.pop(at: index, where: isReopenableHere).flatMap(reopenClosedTab)
            }
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }

    /// Terminals waiting for an answer first, each named with its Space.
    func populateTerminalsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let terminals = terminalSummaries().sorted { ($0["awaitingInputSince"] as? Double ?? 0) > ($1["awaitingInputSince"] as? Double ?? 0) }
        if terminals.isEmpty { menu.addItem(withTitle: "No Terminals".localized, action: nil, keyEquivalent: "") }
        for terminal in terminals {
            guard let id = (terminal["tabId"] as? String).flatMap(UUID.init(uuidString:)) else { continue }
            let item = menu.addItem(terminal["title"] as? String ?? "") { [weak self] in self?.revealTerminal(id) }
            let waiting = (terminal["awaitingInputSince"] as? Double ?? 0) > 0
            item.subtitle = [waiting ? "Waiting for your answer".localized : "", terminal["spaceName"] as? String ?? ""]
                .filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    /// The last downloads outside private Spaces; Option shows each one in the Finder instead.
    func populateDownloadsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let manager = context.downloadManager
        let items = ((try? manager.store?.fetchAll(limit: 16)) ?? [])
            .filter { $0.id.map { !manager.isPrivateDownload(id: $0) } ?? false }
            .prefix(8)
        if items.isEmpty { menu.addItem(withTitle: "No Downloads".localized, action: nil, keyEquivalent: "") }
        for download in items {
            guard let id = download.id else { continue }
            let progress = download.state == .inProgress && download.totalBytes > 0
                ? " (\(download.bytesReceived * 100 / download.totalBytes)%)" : ""
            // A finished download opens; one still running, paused or failed shows in the downloads panel.
            let open = menu.addItem(download.filename + progress) { [weak self] in
                guard let self else { return }
                guard (try? manager.store?.fetch(id: id))??.state == .complete else { return openDownloads(nil) }
                manager.openFile(id: id)
            }
            open.image = NSWorkspace.shared.icon(forFile: download.destinationPath)
            open.image?.size = NSSize(width: 16, height: 16)
            let reveal = menu.addItem(String(format: "Show %@ in Finder".localized, download.filename)) { manager.showInFinder(id: id) }
            reveal.keyEquivalentModifierMask = .option
            reveal.isAlternate = true
        }
        menu.addItem(.separator())
        menu.addItem("Show Downloads Folder".localized) { manager.showDownloadsFolder() }
    }
}
