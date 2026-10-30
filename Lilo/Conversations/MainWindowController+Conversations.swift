import AppKit

/// Agent tabs: a conversation is a folder of the Space it was started in, the agent tab first, then the
/// pages the agent opens. The chrome draws the conversation over the tab's empty native view.
extension MainWindowController {
    var agentsEnabled: Bool { context.settingsStore?.get("agentsEnabled") == "true" }

    /// Starts a conversation in the current Space, which a private Space never hosts.
    @discardableResult
    func startConversation(agentId: String, cwd: String, ownCopy: Bool, activate: Bool) -> Tab? {
        guard agentsEnabled, let spaceId = tabManager.currentSpaceId,
              context.spaceManager?.space(with: spaceId)?.isPrivate == false else { return nil }
        var directory = cwd
        if ownCopy, let worktree = Self.makeWorktree(of: cwd) { directory = worktree }
        let folder = TabFolder(spaceId: spaceId, name: "New Conversation".localized, color: "#795ceb", isCollapsed: true)
        let tab = Tab(title: "New Conversation".localized, spaceId: spaceId, kind: .agent, cwd: directory, agentId: agentId)
        do {
            try applyBrowserCommand(.createFolder(spaceId: spaceId, folder: folder, section: .unpinned))
            try applyBrowserCommand(.createTab(spaceId: spaceId, tab: tab, activate: activate))
            try applyBrowserCommand(.moveSidebarItem(
                spaceId: spaceId, kind: .tab, itemId: tab.id, parentFolderId: folder.id, section: .unpinned, insert: .index(0)
            ))
            context.conversations.register(tab, folderId: folder.id)
            if activate { tabManager.activateTabRuntime(id: tab.id) }
            return tab
        } catch {
            Self.logger.error("start conversation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// A git worktree on a branch of its own, in Lilo's support folder, so agents never edit each
    /// other's files; nil outside a repository.
    private static func makeWorktree(of directory: String) -> String? {
        guard GitDiff.repositoryRoot(containing: directory) != nil else { return nil }
        let id = UUID().uuidString.prefix(8).lowercased()
        let path = URL(fileURLWithPath: BuildIdentity.appSupportDirectory).appending(path: "Worktrees/\(id)").path
        return GitDiff.run(["worktree", "add", "-b", "lilo/\(id)", path], in: directory) != nil ? path : nil
    }

    func showAgentChatView(for tab: Tab) {
        context.conversations.register(tab, folderId: tabManager.sidebarTreeItems(forSpace: tab.spaceId ?? tabManager.currentSpaceId ?? UUID())
            .first { $0.kind == .tab && $0.itemId == tab.id }?.parentFolderId)
        let view = tabManager.agentChatHost.ensureView(for: tab.id)
        showNativeContentView(view, forTabId: tab.id)
        // The composer is in the chrome: typing goes there, not to the empty view under it.
        focusChrome()
    }

    /// The conversations of the restored Spaces, so the Agents badge knows them before they are opened.
    /// Their agents start only when needed.
    func registerRestoredConversations() {
        guard agentsEnabled, let spaces = context.spaceManager?.spaces else { return }
        for space in spaces where !space.isPrivate {
            let items = tabManager.sidebarTreeItems(forSpace: space.id)
            for tab in tabManager.tabs(forSpace: space.id) where tab.kind == .agent {
                context.conversations.register(tab, folderId: items.first { $0.kind == .tab && $0.itemId == tab.id }?.parentFolderId)
            }
        }
    }

    /// The agent tab heading `folder` when it is a conversation's.
    func conversationTab(inFolder folder: TabFolder) -> Tab? {
        guard let first = tabManager.sidebarTreeItems(forSpace: folder.spaceId)
            .filter({ $0.kind == .tab && $0.parentFolderId == folder.id })
            .min(by: { $0.sortOrder < $1.sortOrder }),
            let tab = tabManager.tab(for: first.itemId), tab.kind == .agent else { return nil }
        return tab
    }

    /// A conversation is one row, so its menu is a conversation's, not a folder's.
    func showConversationContextMenu(_ tab: Tab, folder: TabFolder, anchorRect: NSRect?) {
        let menu = NSMenu()
        let conversation = context.conversations.conversations[tab.id]
        if conversation?.state == .busy {
            menu.addItem("Stop".localized, icon: .stopAgents) { self.context.conversations.cancel(tab.id) }
        }
        if let cwd = conversation?.cwd ?? tab.cwd, GitDiff.repositoryRoot(containing: cwd) != nil {
            menu.addItem("Review Changes".localized, icon: .showChanges) { self.openChanges(forConversation: tab.id) }
        }
        if tabManager.sidebarTreeItems(forSpace: folder.spaceId).contains(where: { $0.parentFolderId == folder.id && $0.itemId != tab.id }) {
            menu.addItem((folder.isCollapsed ? "Show Pages" : "Hide Pages").localized, icon: folder.isCollapsed ? .openFolder : .closeFolder) {
                self.applyContextMenuStateCommands([.setFolderCollapsed(spaceId: folder.spaceId, folderId: folder.id, isCollapsed: !folder.isCollapsed)])
            }
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem("Close Conversation".localized, icon: .close) { self.closeTabStateFirst(id: tab.id) }
        presentContextMenu(menu, anchorRect: anchorRect)
    }

    /// The folder takes the conversation's title: the tab strip and extensions' tab groups show it.
    func renameConversationFolder(_ conversation: ConversationHost.Conversation) {
        guard let folderId = conversation.folderId, let spaceId = conversation.spaceId,
              let folder = tabManager.folders(forSpace: spaceId).first(where: { $0.id == folderId }) else { return }
        _ = try? applyBrowserCommand(.updateFolder(
            spaceId: spaceId, folderId: folderId, name: conversation.title, color: folder.color, isCollapsed: folder.isCollapsed
        ))
    }

    /// A conversation's agent tab closed: its agent stops, and the folder goes with the pages it held.
    func pruneConversations() {
        for (id, conversation) in context.conversations.conversations where context.browserState.durableTab(for: id).map({ $0.tab.isClosed }) ?? true {
            context.conversations.close(id)
            tabManager.agentChatHost.forget(id)
            if let folderId = conversation.folderId, let spaceId = conversation.spaceId,
               tabManager.sidebarTreeItems(forSpace: spaceId).contains(where: { $0.kind == .folder && $0.itemId == folderId }) {
                _ = try? applyBrowserCommand(.deleteFolderWithTabs(spaceId: spaceId, folderId: folderId))
            }
        }
    }

    /// A closed conversation reopened with ⇧⌘T: a new folder, the same agent session.
    func reopenConversation(_ stored: StoredTab, spaceId: UUID) -> Tab? {
        let tab = Tab(stored, spaceId: spaceId, groupId: nil)
        let folder = TabFolder(spaceId: spaceId, name: tab.title, color: "#795ceb", isCollapsed: true)
        do {
            try applyBrowserCommand(.createFolder(spaceId: spaceId, folder: folder, section: .unpinned))
            try applyBrowserCommand(.createTab(spaceId: spaceId, tab: tab, activate: true))
            try applyBrowserCommand(.moveSidebarItem(
                spaceId: spaceId, kind: .tab, itemId: tab.id, parentFolderId: folder.id, section: .unpinned, insert: .index(0)
            ))
            context.conversations.register(tab, folderId: folder.id)
            tabManager.activateTabRuntime(id: tab.id)
            return tab
        } catch {
            Self.logger.error("reopen conversation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The conversation's project in Changes, beside it.
    func openChanges(forConversation tabId: UUID) {
        guard let cwd = context.conversations.conversations[tabId]?.cwd, let spaceId = tabManager.currentSpaceId else { return }
        let tab = Tab(title: "Changes".localized, kind: .changes, cwd: cwd)
        do {
            let split = canSplit(beside: tabId)
            try applyBrowserCommand(.createTab(spaceId: spaceId, tab: tab, activate: !split))
            if split {
                try applyBrowserCommand(.splitTabs(spaceId: spaceId, tabId: tab.id, targetTabId: tabId, vertical: false, before: false))
            }
            tabManager.activateTabRuntime(id: tab.id)
        } catch {
            Self.logger.error("open conversation changes failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Opens the Ask bar with the active page's selection, so it offers one only when there is one.
    /// An HTML or SVG block of the thread, rendered as what it is: a page, opened among the conversation's
    /// pages. Written to Lilo's support folder, so it loads as a file like any local page.
    func previewArtifact(_ code: String, language: String, forConversation tabId: UUID) {
        let folder = URL(fileURLWithPath: BuildIdentity.appSupportDirectory).appending(path: "Agents/Artifacts")
        let file = folder.appending(path: "\(UUID().uuidString).\(language == "svg" ? "svg" : "html")")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try code.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return Self.logger.error("artifact preview failed: \(error.localizedDescription, privacy: .public)")
        }
        let conversation = context.conversations.conversations[tabId]
        let index = conversation?.folderId.map { folderId in
            tabManager.sidebarTreeItems(forSpace: conversation?.spaceId ?? UUID()).filter { $0.parentFolderId == folderId }.count
        }
        guard let tab = createTabStateFirst(url: file, activate: false, sidebarParentFolderId: conversation?.folderId,
                                            sidebarSection: .unpinned, sidebarIndex: index) else { return }
        tabManager.activateTabRuntime(id: tab.id)
    }

    @objc func askAgent(_ sender: Any?) {
        guard agentsEnabled else { return NSSound.beep() }
        guard let tab = tabManager.activeTab, tab.kind == .web, let engine = tabManager.engineTab(for: tab.id) else {
            return bridgeRouter.send(event: "openAskBar", data: ["selection": ""])
        }
        Task {
            let selection = (try? await engine.wkWebView.callAsyncJavaScript(
                "return String(getSelection()).trim()", arguments: [:], in: nil, contentWorld: AgentInput.world
            )) as? String ?? ""
            bridgeRouter.send(event: "openAskBar", data: ["selection": String(selection.prefix(200))])
        }
    }
}

/// The native side of agent tabs: an empty view per tab, which keeps the content area's layout and
/// split panes working while the chrome draws the conversation over it.
@MainActor
final class AgentChatHost {
    private var views: [UUID: NSView] = [:]

    func view(for id: UUID) -> NSView? { views[id] }

    func ensureView(for id: UUID) -> NSView {
        if let view = views[id] { return view }
        let view = NSView()
        views[id] = view
        return view
    }

    func forget(_ id: UUID) {
        views.removeValue(forKey: id)?.removeFromSuperview()
    }
}
