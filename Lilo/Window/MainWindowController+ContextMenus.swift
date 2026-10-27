// Tab, folder, sidebar, download and history context menus.

import AppKit

enum TabContextMenuAction: Equatable {
    case createFolderFromTab
    case removeBookmark
    case removePinned
}

enum TabContextMenuActions {
    static func forTab(_ tab: Tab) -> [TabContextMenuAction] {
        var actions: [TabContextMenuAction] = []
        if !tab.isBookmarked {
            actions.append(.createFolderFromTab)
        }
        if tab.isClosed && tab.isBookmarked {
            actions.append(.removeBookmark)
        } else if tab.isClosed && tab.isPinned {
            actions.append(.removePinned)
        }
        return actions
    }

    /// The space's folders in sidebar order with their nesting depth. A locked folder hides its
    /// whole subtree and a split only takes its own panes, so neither can receive a tab.
    static func folderTargets(treeItems: [TabTreeItem], folders: [TabFolder]) -> [(folder: TabFolder, depth: Int)] {
        let foldersById = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        let children = Dictionary(grouping: treeItems.filter { $0.kind == .folder }, by: \.parentFolderId)
        var targets: [(folder: TabFolder, depth: Int)] = []
        func visit(_ items: [TabTreeItem], depth: Int) {
            for item in items.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                guard let folder = foldersById[item.itemId], !folder.isSplit, !folder.isLocked else { continue }
                targets.append((folder, depth))
                visit(children[folder.id] ?? [], depth: depth + 1)
            }
        }
        let roots = children[nil] ?? []
        visit(roots.filter { $0.section == .pinned }, depth: 0)
        visit(roots.filter { $0.section == .unpinned }, depth: 0)
        return targets
    }
}

/// A menu item that runs a closure, so a menu built on the fly needs no selector and payload per entry.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

@MainActor
extension NSMenu {
    @discardableResult
    func addItem(_ title: String, icon: MenuIcon? = nil, handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, handler: handler)
        item.image = icon?.image
        addItem(item)
        return item
    }
}

extension MainWindowController {
    /// Pops `menu` up in the window's content view, anchored to the bridge-provided rect
    /// (or the fallback top-left anchor when nil).
    func presentContextMenu(_ menu: NSMenu, anchorRect: NSRect?) {
        guard let window, let hostView = window.contentView else { return }
        let r = appKitRect(forBridgeRect: anchorRect, in: hostView)
        menu.showItemImages()
        menu.popUp(positioning: nil, at: NSPoint(x: r.minX, y: max(12, r.minY - 6)), in: hostView)
    }

    // MARK: - Tab Context Menu

    func showTabContextMenu(tabId: String, anchorRect: NSRect?) {
        guard let uuid = UUID(uuidString: tabId),
              let context = tabManager.context(for: uuid) else { return }
        let tab = context.tab
        let spaceId = context.spaceId
        let togglePin = { self.applyContextMenuStateCommands([.setPinned(spaceId: spaceId, tabId: uuid, isPinned: !tab.isPinned)]) }
        let toggleBookmark = {
            self.applyContextMenuStateCommands([.setBookmarked(spaceId: spaceId, tabId: uuid, isBookmarked: !tab.isBookmarked)])
        }

        let menu = NSMenu()
        if tab.isPinned || tab.isBookmarked {
            let homeURL = (tab.homeURL ?? tab.url)?.absoluteString ?? ""
            menu.addItem("Edit...".localized, icon: .edit) { self.bridgeRouter.send(event: "beginTabEdit", data: ["id": tabId, "homeURL": homeURL]) }
        }
        let actions = TabContextMenuActions.forTab(tab)
        if actions.contains(.createFolderFromTab) {
            menu.addItem("Create Folder from Tab".localized, icon: .newFolder) { self.createFolder(from: tab, spaceId: spaceId) }
        }
        if !tab.isBookmarked {
            let folderMenu = NSMenu(title: "Move to Folder".localized)
            addMoveToFolderItems(to: folderMenu, tabId: uuid, spaceId: spaceId)
            if !folderMenu.items.isEmpty {
                let item = menu.addItem(withTitle: folderMenu.title, action: nil, keyEquivalent: "")
                item.image = MenuIcon.moveToFolder.image
                item.submenu = folderMenu
            }
        }
        if !tab.isClosed, spaceId == tabManager.currentSpaceId {
            let spaceMenu = NSMenu(title: "Move to Space".localized)
            addMoveToSpaceItems(to: spaceMenu, tabId: uuid)
            if !spaceMenu.items.isEmpty {
                let item = menu.addItem(withTitle: spaceMenu.title, action: nil, keyEquivalent: "")
                item.image = MenuIcon.moveToSpace.image
                item.submenu = spaceMenu
            }
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        if tab.kind == .terminal, tabManager.terminalHost.isBusy(uuid), self.context.settingsStore?.get("terminalPreventSleep") != "false" {
            menu.addItem("Keep Awake Until Done".localized, icon: .keepAwake) { self.context.powerKeeper.keepAwakeUntilDone(uuid) }
            menu.addItem(.separator())
        }
        if tab.isBookmarked && !tab.isPinned {
            menu.addItem("Unbookmark Tab".localized, icon: .unbookmark, handler: toggleBookmark)
            menu.addItem("Pin Tab".localized, icon: .pin, handler: togglePin)
        } else {
            menu.addItem("Bookmark Tab".localized, icon: .bookmark, handler: toggleBookmark)
            menu.addItem((tab.isPinned ? "Unpin Tab" : "Pin Tab").localized, icon: tab.isPinned ? .unpin : .pin, handler: togglePin)
        }
        if let groupId = tab.groupId, let folder = tabManager.folder(id: groupId), folder.isSplit {
            menu.addItem("Separate Split View".localized, icon: .separateSplit) {
                self.applyContextMenuStateCommands([.deleteFolder(spaceId: folder.spaceId, folderId: groupId)])
            }
        } else if !tab.isClosed, !tab.isBookmarked, let active = tabManager.activeTab, active.id != uuid {
            menu.addItem("Open in Split View".localized, icon: .openInSplit) { self.splitTab(uuid, at: nil, vertical: false, before: false) }
        }
        if tab.kind == .web {
            menu.addItem((tab.isMuted ? "Unmute Tab" : "Mute Tab").localized, icon: tab.isMuted ? .unmute : .mute) { self.tabManager.setTabMuted(id: uuid, muted: !tab.isMuted) }
        }
        // An item without an action is greyed out.
        let duplicate = menu.addItem("Duplicate Tab".localized, icon: .duplicate) { self.duplicateTab(tab) }
        if tab.url == nil { duplicate.action = nil }
        if !tab.isClosed, !self.context.settingsStore.singleWindow {
            menu.addItem("Move to New Window".localized, icon: .newWindow) { self.moveTabToNewWindow(uuid) }
        }
        menu.addItem(.separator())
        if actions.contains(.removeBookmark) {
            menu.addItem("Remove Bookmark".localized, icon: .unbookmark, handler: toggleBookmark)
        } else if actions.contains(.removePinned) {
            menu.addItem("Remove Pinned Tab".localized, icon: .unpin, handler: togglePin)
        } else {
            menu.addItem("Close Tab".localized, icon: .close) { self.closeTabStateFirst(id: uuid) }
        }
        let closeOthers = menu.addItem("Close Other Tabs".localized, icon: .closeOthers) { self.closeOtherTabs(keeping: tab) }
        if !tabManager.currentTabs.contains(where: { $0.id != uuid && !$0.isPinned && !$0.isBookmarked }) { closeOthers.action = nil }

        presentContextMenu(menu, anchorRect: anchorRect)
    }

    /// The folder takes the tab's place, inside the tab's folder when there is room for one more level.
    private func createFolder(from tab: Tab, spaceId: UUID) {
        let section: TabTreeItem.Section = tab.isPinned ? .pinned : .unpinned
        let folder = TabFolder(spaceId: spaceId, name: "New Folder", color: "#5865f2")
        var parentFolderId: UUID?
        if let groupId = tab.groupId, let spaceTab = context.browserState.space(id: spaceId)?.spaceTab,
           spaceTab.folder(id: groupId)?.isSplit == false, spaceTab.canNestFolder(height: 1, in: groupId) {
            parentFolderId = groupId
        }
        let folderIndex = tabManager.sidebarTreeItems(forSpace: spaceId)
            .filter { $0.parentFolderId == parentFolderId && $0.section == section }
            .firstIndex { $0.kind == .tab && $0.itemId == tab.id } ?? 0
        applyContextMenuStateCommands([
            .createFolder(spaceId: spaceId, folder: folder, section: section, parentFolderId: parentFolderId),
            .moveSidebarItem(spaceId: spaceId, kind: .folder, itemId: folder.id, parentFolderId: parentFolderId, section: section, insert: .index(folderIndex)),
            .moveSidebarItem(spaceId: spaceId, kind: .tab, itemId: tab.id, parentFolderId: folder.id, section: section, insert: .index(0))
        ])
    }

    /// The folders the tab can move into, then "Remove from Folder" when it sits in one. Nothing for
    /// a pane of a split, which only holds its own panes.
    func addMoveToFolderItems(to folderMenu: NSMenu, tabId uuid: UUID, spaceId: UUID) {
        let treeItems = tabManager.sidebarTreeItems(forSpace: spaceId)
        let parentFolderId = treeItems.first { $0.kind == .tab && $0.itemId == uuid }?.parentFolderId
        guard parentFolderId.flatMap({ tabManager.folder(id: $0) })?.isSplit != true else { return }
        let targets = TabContextMenuActions.folderTargets(treeItems: treeItems, folders: tabManager.folders(forSpace: spaceId))
        for (folder, depth) in targets {
            // Moving into a pinned folder pins the tab, as a drop there does.
            let section = treeItems.first { $0.kind == .folder && $0.itemId == folder.id }?.section ?? .unpinned
            let item = folderMenu.addItem(folder.name) { [weak self] in
                self?.applyContextMenuStateCommands([
                    .moveSidebarItem(spaceId: spaceId, kind: .tab, itemId: uuid, parentFolderId: folder.id, section: section, insert: .index(.max))
                ])
            }
            item.indentationLevel = depth
            if folder.id == parentFolderId {
                item.action = nil
                item.state = .on
            }
        }
        guard let parentFolderId, let folderItem = treeItems.first(where: { $0.kind == .folder && $0.itemId == parentFolderId }) else { return }
        if !targets.isEmpty { folderMenu.addItem(.separator()) }
        folderMenu.addItem("Remove from Folder".localized, icon: .removeFromFolder) { [weak self] in
            self?.applyContextMenuStateCommands([
                .moveSidebarItem(
                    spaceId: spaceId, kind: .tab, itemId: uuid, parentFolderId: folderItem.parentFolderId, section: folderItem.section,
                    insert: .anchored(fallbackIndex: .max, insertBeforeId: nil, insertAfterId: parentFolderId)
                )
            ])
        }
    }

    // MARK: - Download Context Menu

    func showDownloadContextMenu(downloadId: Int, anchorRect: NSRect?, state: String, fileMissing: Bool) {
        let menu = NSMenu()
        func add(_ title: String, _ icon: MenuIcon, _ action: String) {
            menu.addItem(title.localized, icon: icon) { self.bridgeRouter?.send(event: "downloadMenuAction", data: ["id": downloadId, "action": action]) }
        }
        // Copied here: the chrome may only write the pasteboard during a user gesture, and a bridge push is none.
        func addCopyURL() {
            menu.addItem("Copy URL".localized, icon: .copyLink) {
                guard let item = try? self.context.downloadManager.store?.fetch(id: Int64(downloadId)) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url, forType: .string)
            }
        }

        switch state {
        case "inProgress", "paused":
            addCopyURL()
            add("Cancel", .cancel, "cancel")
        case "interrupted":
            add("Retry", .retry, "retry")
            addCopyURL()
            menu.addItem(.separator())
            add("Remove from List", .removeFromList, "removeFromList")
        default: // complete
            if fileMissing {
                addCopyURL()
                menu.addItem(.separator())
                add("Remove from List", .removeFromList, "removeFromList")
            } else {
                add("Open", .open, "open")
                add("Quick Look", .quickLook, "quickLook")
                add("Show in Finder", .showInFinder, "showInFinder")
                if context.settingsStore?.terminalEnabled != false {
                    menu.addItem("Open in Terminal".localized, icon: .openInTerminal) {
                        guard let item = try? self.context.downloadManager.store?.fetch(id: Int64(downloadId)) else { return }
                        self.createTerminalTab(cwd: (item.destinationPath as NSString).deletingLastPathComponent)
                    }
                }
                menu.addItem(.separator())
                addCopyURL()
                add("Delete File", .delete, "deleteFile")
                add("Remove from List", .removeFromList, "removeFromList")
            }
        }

        presentContextMenu(menu, anchorRect: anchorRect)
    }

    func applyContextMenuStateCommands(_ commands: [BrowserCommand]) {
        do {
            for command in commands {
                try applyBrowserCommand(command)
            }
        } catch {
            Self.logger.error("context menu state command failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Folder Context Menu

    func showFolderContextMenu(folderId: String, anchorRect: NSRect?) {
        guard let uuid = UUID(uuidString: folderId),
              let folder = tabManager.folder(id: uuid) else { return }
        let spaceId = folder.spaceId

        let menu = NSMenu()
        if folder.isSplit {
            var stacked = false
            if case let .split(vertical, _, _, _)? = folder.splitLayout { stacked = vertical }
            menu.addItem((stacked ? "Arrange Side by Side" : "Arrange Top and Bottom").localized, icon: stacked ? .arrangeSideBySide : .arrangeTopAndBottom) {
                // Turns the outermost cut, which splits the whole area.
                guard let layout = folder.splitLayout?.updatingCut(at: [], { vertical, _ in vertical.toggle() }) else { return }
                self.applyContextMenuStateCommands([.setSplitLayout(spaceId: spaceId, folderId: uuid, layout: layout)])
                self.layoutSplitContent()
            }
            menu.addItem("Separate Split View".localized, icon: .separateSplit) { self.applyContextMenuStateCommands([.deleteFolder(spaceId: spaceId, folderId: uuid)]) }
            presentContextMenu(menu, anchorRect: anchorRect)
            return
        }
        // Every other entry would reveal or release the tabs, deleting included (they stay in the sidebar).
        if folder.isLocked {
            menu.addItem("Unlock Folder…".localized, icon: .unlock) { self.bridgeRouter.send(event: "beginFolderUnlock", data: ["id": folderId]) }
            presentContextMenu(menu, anchorRect: anchorRect)
            return
        }
        menu.addItem((folder.isCollapsed ? "Open Folder" : "Close Folder").localized, icon: folder.isCollapsed ? .openFolder : .closeFolder) {
            self.applyContextMenuStateCommands([.setFolderCollapsed(spaceId: spaceId, folderId: uuid, isCollapsed: !folder.isCollapsed)])
        }
        menu.addItem("Edit Folder".localized, icon: .edit) { self.bridgeRouter.send(event: "editTabFolder", data: ["id": folderId]) }
        if context.browserState.space(id: spaceId)?.spaceTab.canNestFolder(height: 1, in: uuid) == true {
            menu.addItem("New Folder".localized, icon: .newFolder) { self.createSubfolder(in: folder) }
        }
        menu.addItem(.separator())
        if folder.lock == nil {
            menu.addItem("Lock Folder…".localized, icon: .lock) { self.beginFolderLockSetup(uuid) }
        } else {
            menu.addItem("Change Password…".localized, icon: .changePassword) { Task { await self.changeFolderPassword(folder) } }
            menu.addItem("Remove Lock".localized, icon: .removeLock) { Task { await self.removeFolderLock(folder) } }
        }
        menu.addItem(.separator())
        menu.addItem("Delete Folder".localized, icon: .delete) {
            self.deleteFolderAndContent(folder) { command in
                do {
                    try self.applyBrowserCommand(command)
                    return true
                } catch {
                    Self.logger.error("delete folder failed: \(error.localizedDescription, privacy: .public)")
                    return false
                }
            }
        }
        presentContextMenu(menu, anchorRect: anchorRect)
    }

    /// Opens the parent so the new folder shows, then starts its rename.
    private func createSubfolder(in parent: TabFolder) {
        let folder = TabFolder(spaceId: parent.spaceId, name: "New Folder", color: parent.color)
        var commands: [BrowserCommand] = [.createFolder(spaceId: parent.spaceId, folder: folder, section: .unpinned, parentFolderId: parent.id)]
        if parent.isCollapsed { commands.append(.setFolderCollapsed(spaceId: parent.spaceId, folderId: parent.id, isCollapsed: false)) }
        applyContextMenuStateCommands(commands)
        guard tabManager.folder(id: folder.id) != nil else { return }
        bridgeRouter.send(event: "editTabFolder", data: ["id": folder.id.uuidString])
    }

    /// A folder goes with its tabs and subfolders, their locks' passwords too. A split view only lets its panes go.
    /// `apply` runs the state command, so the bridge and the context menu share one path.
    @discardableResult
    func deleteFolderAndContent(_ folder: TabFolder, apply: (BrowserCommand) -> Bool) -> Bool {
        let spaceTab = context.browserState.space(id: folder.spaceId)?.spaceTab
        let tabCount = spaceTab?.tabIds(inFolder: folder.id).count ?? 0
        let lockedIds = [folder.id] + (spaceTab?.lockedFolderIds(inFolder: folder.id) ?? [])
        guard confirmDeleteFolder(folder, tabs: folder.isSplit ? 0 : tabCount) else { return false }
        let command: BrowserCommand = folder.isSplit
            ? .deleteFolder(spaceId: folder.spaceId, folderId: folder.id)
            : .deleteFolderWithTabs(spaceId: folder.spaceId, folderId: folder.id)
        guard apply(command) else { return false }
        lockedIds.forEach { FolderLockKeychain.remove(folderId: $0) }
        return true
    }

    private func confirmDeleteFolder(_ folder: TabFolder, tabs: Int) -> Bool {
        guard window?.isVisible == true else { return true }
        let alert = NSAlert()
        alert.messageText = tabs == 0
            ? String(format: "Delete %@?".localized, folder.name)
            : String(format: "Delete %@ and %@?".localized, folder.name, tabs == 1 ? "1 tab".localized : String(format: "%d tabs".localized, tabs))
        alert.informativeText = folder.isSplit
            ? "Its tabs stay in the sidebar.".localized
            : "This cannot be undone.".localized
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete".localized)
        alert.addButton(withTitle: "Cancel".localized)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func beginFolderLockSetup(_ folderId: UUID) {
        bridgeRouter.send(event: "beginFolderLockSetup", data: [
            "id": folderId.uuidString, "biometricsAvailable": FolderLockAuth.biometricsAvailable
        ])
    }

    func changeFolderPassword(_ folder: TabFolder) async {
        let reason = String(format: "Change the password of %@".localized, folder.name)
        guard await FolderLockAuth.authenticate(.deviceOwnerAuthentication, reason: reason) else { return }
        beginFolderLockSetup(folder.id)
    }

    func removeFolderLock(_ folder: TabFolder) async {
        let reason = String(format: "Remove the lock of %@".localized, folder.name)
        guard await FolderLockAuth.authenticate(.deviceOwnerAuthentication, reason: reason) else { return }
        FolderLockKeychain.remove(folderId: folder.id)
        applyContextMenuStateCommands([.setFolderLock(spaceId: folder.spaceId, folderId: folder.id, lock: nil)])
    }

    // MARK: - Sidebar Context Menu

    func showSidebarContextMenu(spaceId: String?, anchorRect: NSRect?) {
        guard let targetSpaceId = spaceId.flatMap(UUID.init(uuidString:)) ?? tabManager.currentSpaceId else { return }

        let menu = NSMenu()
        menu.addItem("New Tab".localized, icon: .newTab) {
            self.switchToSpace(targetSpaceId)
            self.createTabStateFirst(url: nil)
        }
        if context.settingsStore?.terminalEnabled != false {
            menu.addItem("New Terminal Tab".localized, icon: .newTerminalTab) {
                self.switchToSpace(targetSpaceId)
                self.createTerminalTab()
            }
        }
        menu.addItem("Create Folder".localized, icon: .newFolder) {
            let folder = TabFolder(spaceId: targetSpaceId, name: "New Folder", color: "#5865f2")
            self.applyContextMenuStateCommands([.createFolder(spaceId: targetSpaceId, folder: folder, section: .unpinned)])
        }
        let positions = NSMenu()
        for (position, title) in [(TabPosition.left, "Left"), (.right, "Right"), (.top, "Top"), (.bottom, "Bottom")] {
            positions.addItem(title.localized) { self.setTabPosition(position) }.state = tabLayout.position == position ? .on : .off
        }
        let positionItem = menu.addItem(withTitle: "Tab Position".localized, action: nil, keyEquivalent: "")
        positionItem.image = MenuIcon.sidebar.image
        positionItem.submenu = positions
        menu.addItem(.separator())
        menu.addItem("Edit Space".localized, icon: .edit) { self.bridgeRouter.send(event: "openSpaceEditor", data: ["id": targetSpaceId.uuidString]) }
        menu.addItem("New Space".localized, icon: .newSpace) { self.bridgeRouter.send(event: "openAddSpaceEditor") }
        if context.spaceManager.spaces.count > 1 {
            menu.addItem("Delete Space…".localized, icon: .delete) {
                guard let space = self.context.spaceManager.space(with: targetSpaceId) else { return }
                let alert = NSAlert()
                alert.messageText = String(format: "Delete %@?".localized, space.name)
                alert.informativeText = "The space and all its tabs are deleted permanently.".localized
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Delete".localized)
                alert.addButton(withTitle: "Cancel".localized)
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                do { try self.deleteSpace(id: targetSpaceId) } catch {
                    Self.logger.error("delete space failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        menu.addItem(.separator())
        let restore = menu.addItem("Restore Closed Tab".localized, icon: .restoreClosedTab) { _ = self.restoreClosedTabStateFirst() }
        if context.recentlyClosed.recentEntries.isEmpty { restore.action = nil }
        if context.settingsStore?.agentsSpaceIds.contains(targetSpaceId) == true, !context.agentControl.sessions.isEmpty {
            menu.addItem(.separator())
            menu.addItem("Stop Agents".localized, icon: .stopAgents) { self.context.agentControl.stopAll() }
        }
        presentContextMenu(menu, anchorRect: anchorRect)
    }

    /// Active-tab bookmark toggle for File menu / Cmd+D / page context menu.
    @objc func bookmarkCurrentTab(_ sender: Any?) {
        guard let tab = tabManager.activeTab,
              let spaceId = tab.spaceId ?? tabManager.currentSpaceId else { return }
        applyContextMenuStateCommands([
            .setBookmarked(spaceId: spaceId, tabId: tab.id, isBookmarked: !tab.isBookmarked)
        ])
    }

    /// Closes every tab of the Space but `target`, its pinned and bookmarked ones aside.
    func closeOtherTabs(keeping target: Tab) {
        let uuid = target.id
        guard let spaceId = tabManager.currentSpaceId else { return }
        let itemById = Dictionary(
            tabManager.sidebarTreeItems(forSpace: spaceId).map { ($0.itemId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Closing the active tab first would activate, and start loading, a tab the loop closes next.
        if !target.isClosed, let active = tabManager.activeTab, active.id != uuid, !active.isPinned, !active.isBookmarked {
            activateTabStateFirst(id: uuid)
        }
        let closing = tabManager.currentTabs.filter { $0.id != uuid && !$0.isPinned && !$0.isBookmarked }
        let closeAll = { [weak self] in
            guard let self else { return }
            var recordedCount = 0
            for tab in closing {
                if recordClosedTabForRestore(id: tab.id, sidebarItemById: itemById) { recordedCount += 1 }
                closeTabStateFirst(id: tab.id, undoable: false)
            }
            if recordedCount > 0 {
                bridgeRouter.send(event: "tabClosedUndoable", data: ["title": "", "count": recordedCount])
            }
        }
        // One question for the whole batch instead of a sheet per running terminal.
        let busy = closing.filter { $0.kind == .terminal && tabManager.terminalHost.isBusy($0.id) }.map(\.id)
        guard !busy.isEmpty, let window else { return closeAll() }
        let alert = NSAlert()
        alert.messageText = String(format: "Close %d terminals?".localized, busy.count)
        let commands = busy.compactMap(tabManager.terminalHost.runningCommand)
        alert.informativeText = commands.count == busy.count
            ? String(format: "These commands will be stopped: %@.".localized, commands.joined(separator: ", "))
            : "Commands are still running in them and will be stopped.".localized
        alert.addButton(withTitle: "Close".localized)
        alert.addButton(withTitle: "Cancel".localized)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            busy.forEach(tabManager.terminalHost.terminate)
            closeAll()
        }
    }

    // MARK: - Navigation History Menus

    func showNavigationHistoryMenu(direction: WKWebViewTab.WebNavigationHistoryDirection, anchorRect: NSRect?) {
        guard let window, window.attachedSheet == nil, window.contentView != nil,
              let engine = tabManager.activeEngineTab else { return NSSound.beep() }
        let historyItems = engine.navigationHistoryItems(for: direction)
        guard !historyItems.isEmpty else { return NSSound.beep() }

        let menu = NSMenu()
        for (index, item) in historyItems.enumerated() {
            menu.addItem(item.title) { self.tabManager.activeEngineTab?.goToHistoryItem(at: index, direction: direction) }
                .toolTip = item.url.absoluteString
        }
        presentContextMenu(menu, anchorRect: anchorRect)
    }

    func appKitRect(forBridgeRect bridgeRect: NSRect?, in hostView: NSView) -> NSRect {
        let margin: CGFloat = 12
        let hostBounds = hostView.bounds

        guard let bridgeRect else {
            return NSRect(
                x: margin,
                y: max(margin, hostBounds.height - 44),
                width: 28,
                height: 28
            )
        }

        return NSRect(
            x: min(
                max(margin, bridgeRect.origin.x),
                max(margin, hostBounds.width - bridgeRect.width - margin)
            ),
            y: hostBounds.height - bridgeRect.origin.y - bridgeRect.height,
            width: bridgeRect.width,
            height: bridgeRect.height
        )
    }
}
