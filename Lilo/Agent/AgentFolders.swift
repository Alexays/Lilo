import AppKit
import WebKit

/// Where agent tabs live: the Agents space, one space for every agent's tabs, kept apart from the
/// user's own, with one folder per conversation in it.
extension AgentControl {
    static let agentsSpaceKey = "agentsSpaceId"

    /// The Agents space, and the window showing it if one does. The first agent creates it, in the
    /// agents' own ephemeral profile.
    func agentSpace() throws -> (space: Space, host: MainWindowController?) {
        guard let context, let spaces = context.spaceManager, let settings = context.settingsStore else {
            throw AgentToolError("Lilo is not ready yet")
        }
        // Commands go through a window, whichever space it shows.
        guard let commander = context.windows.activeWindow else { throw AgentToolError("Open a Lilo window so agents can work in it", code: "needs_user") }
        var space = spaces.space(with: settings.agentsSpaceId)
        if space == nil {
            let created = try spaces.createSpace(name: "Agents", icon: "🤖", color: "#d97757", profileId: try agentsProfileId())
            settings.set(Self.agentsSpaceKey, value: created.id.uuidString)
            space = created
        }
        guard let space else { throw AgentToolError("Lilo has no space agents can use") }
        // A space no window has shown since launch has no state loaded yet.
        if context.browserState.space(id: space.id) == nil {
            context.browserState.storeSpace(id: space.id, snapshot: commander.restoredSpaceSnapshot(for: space))
        }
        // Past conversations' folders go before the first agent of this run: each starts in a clean space.
        // So do blank tabs outside them, which no agent opens, unless a window shows one.
        if !agentsSpaceCleaned {
            agentsSpaceCleaned = true
            for folder in context.browserState.structuralProjection(forSpace: space.id)?.folders ?? [] {
                _ = try? commander.applyBrowserCommand(.deleteFolderWithTabs(spaceId: space.id, folderId: folder.id))
            }
            if context.windows.windows(showing: space.id).isEmpty {
                let blank = tabs(inFolder: nil, spaceId: space.id).filter { $0.kind == .web && $0.url == nil && !$0.isPinned }
                context.browserState.discardParkedEngines(Set(blank.map(\.id)), spaceId: space.id) { context.discardEngine($0) }
                for tab in blank { _ = try? commander.applyBrowserCommand(.closeTab(spaceId: space.id, tabId: tab.id)) }
            }
        }
        return (space, context.windows.windows(showing: space.id).first)
    }

    /// The conversation's own folder in the Agents space, created with its first tab.
    func agentFolder(for session: AgentSession, create: Bool) throws -> (folderId: UUID?, space: Space, host: MainWindowController?) {
        let (space, host) = try agentSpace()
        if let id = session.folderId, tabFolder(id, in: space.id) != nil { return (id, space, host) }
        guard create, let commander = host ?? context?.windows.activeWindow else { return (nil, space, host) }
        let folder = TabFolder(spaceId: space.id, name: folderName(for: session), color: "#d97757")
        _ = try commander.applyBrowserCommand(.createFolder(spaceId: space.id, folder: folder, section: .unpinned))
        session.folderId = folder.id
        return (folder.id, space, host)
    }

    /// The conversation's private space, for tabs that share no cookie or storage with any other tab and
    /// leave nothing behind: its data lives in memory and goes with the space when the agent leaves.
    func isolatedSpace(for session: AgentSession, create: Bool) throws -> (space: Space, host: MainWindowController?)? {
        guard let context, let spaces = context.spaceManager else { throw AgentToolError("Lilo is not ready yet") }
        if let space = spaces.space(with: session.isolatedSpaceId) { return (space, context.windows.windows(showing: space.id).first) }
        guard create else { return nil }
        guard let commander = context.windows.activeWindow else { throw AgentToolError("Open a Lilo window so agents can work in it", code: "needs_user") }
        let space = try spaces.createSpace(
            name: folderName(for: session), icon: "🕶️", color: "#d97757", profileId: try agentsProfileId(), isPrivate: true
        )
        context.browserState.storeSpace(id: space.id, snapshot: commander.restoredSpaceSnapshot(for: space))
        session.isolatedSpaceId = space.id
        return (space, nil)
    }

    /// Isolated tabs of the conversation, in sidebar order.
    func isolatedTabs(of session: AgentSession) -> [Tab] {
        session.isolatedSpaceId.map { tabs(inFolder: nil, spaceId: $0) } ?? []
    }

    /// The space manager's delete: it discards the space's engines and releases its in-memory store.
    func dropIsolatedSpace(of session: AgentSession) {
        guard let id = session.isolatedSpaceId else { return }
        session.isolatedSpaceId = nil
        try? context?.spaceManager?.deleteSpace(id: id)
    }

    /// The task the agent gave, else its project with the client's name, else that name and the time it came.
    private func folderName(for session: AgentSession) -> String {
        if let title = session.title { return title }
        let client = Self.displayName(session.clientName)
        if let project = session.projectName { return "\(client) - \(project)" }
        return "\(client) - \(session.connectedAt.formatted(date: .omitted, time: .shortened))"
    }

    /// Follows a new title or project name.
    func renameFolder(of session: AgentSession) {
        guard let context, let folderId = session.folderId, let (space, host) = try? agentSpace(),
              let folder = tabFolder(folderId, in: space.id), let commander = host ?? context.windows.activeWindow else { return }
        _ = try? commander.applyBrowserCommand(.updateFolder(
            spaceId: space.id, folderId: folderId, name: folderName(for: session), color: folder.color, isCollapsed: folder.isCollapsed
        ))
    }

    /// A conversation that ended takes its folder and tabs along: nobody drives them any more. While a
    /// window shows the Agents space they stay under the user's eyes, until the next run's cleanup.
    func dropFolder(of session: AgentSession) {
        guard let context, let folderId = session.folderId,
              let spaceId = context.settingsStore?.agentsSpaceId,
              tabFolder(folderId, in: spaceId) != nil else { return }
        let tabs = tabs(inFolder: folderId, spaceId: spaceId)
        if let host = context.windows.windows(showing: spaceId).first {
            if tabs.isEmpty { _ = try? host.applyBrowserCommand(.deleteFolder(spaceId: spaceId, folderId: folderId)) }
            return
        }
        guard let commander = context.windows.activeWindow else { return }
        context.browserState.discardParkedEngines(Set(tabs.map(\.id)), spaceId: spaceId) { context.discardEngine($0) }
        _ = try? commander.applyBrowserCommand(.deleteFolderWithTabs(spaceId: spaceId, folderId: folderId))
    }

    /// A new tab of the folder: through the window showing the space, else straight into the space's
    /// state with its own engine, which a window showing the space later takes over.
    func createTab(inFolder folderId: UUID?, space: Space, host: MainWindowController?, url: URL? = nil) throws -> Tab {
        let index = tabs(inFolder: folderId, spaceId: space.id).count
        if let host {
            guard let tab = host.createTabStateFirst(
                url: url, activate: false, sidebarParentFolderId: folderId, sidebarSection: .unpinned, sidebarIndex: index
            ) else { throw AgentToolError("Could not create a tab") }
            if let engine = host.tabManager.engineTab(for: tab.id) { attach(engine, to: host) }
            return tab
        }
        guard let commander = context?.windows.activeWindow else { throw AgentToolError("Open a Lilo window so agents can work in it", code: "needs_user") }
        let engine = makeHiddenEngine(tabId: nil, space: space, commander: commander)
        let tab = Tab(id: engine.id, url: url, spaceId: space.id)
        _ = try commander.applyBrowserCommand(.createTab(spaceId: space.id, tab: tab, activate: false))
        if let folderId {
            _ = try commander.applyBrowserCommand(.moveSidebarItem(
                spaceId: space.id, kind: .tab, itemId: tab.id, parentFolderId: folderId, section: .unpinned, insert: .index(index)
            ))
        }
        if let url { engine.loadURL(url) }
        return tab
    }

    /// A link or popup an agent's page opened: a new tab beside the opener, in its folder or its isolated
    /// space, unshown.
    func openTab(from opener: WKWebViewTab, url: URL?) {
        guard let context, let (spaceId, tab) = context.browserState.durableTab(for: opener.id),
              tab.groupId != nil || sessions.contains(where: { $0.isolatedSpaceId == spaceId }),
              let space = context.spaceManager.space(with: spaceId) else { return }
        _ = try? createTab(inFolder: tab.groupId, space: space, host: context.windows.windows(showing: spaceId).first, url: url)
        refreshControlledTabs()
    }

    /// Closes an agent tab through the window showing its space, else straight in its state.
    func closeTab(_ tab: Tab) throws {
        guard let context, let spaceId = context.browserState.owningSpaceId(forTab: tab.id) else { return }
        if let host = context.windows.windows(showing: spaceId).first { return host.closeTabStateFirst(id: tab.id, undoable: false, askingPage: false) }
        guard let commander = context.windows.activeWindow else { throw AgentToolError("Open a Lilo window so agents can work in it", code: "needs_user") }
        context.browserState.discardParkedEngines([tab.id], spaceId: spaceId) { context.discardEngine($0) }
        _ = try commander.applyBrowserCommand(.closeTab(spaceId: spaceId, tabId: tab.id))
    }

    /// An engine for a tab of a space no window shows, kept with the space's others for the window that
    /// shows the space later. Only navigation state goes to `commander`: the rest of a window's wiring
    /// belongs to that window.
    private func makeHiddenEngine(tabId: UUID?, space: Space, commander: MainWindowController) -> WKWebViewTab {
        let context = commander.context
        let dataStore = space.isPrivate
            ? context.profileManager.ephemeralDataStore(for: space.id)
            : context.profileManager.dataStore(for: space.profileId)
        let engine = context.engineFactory.createTab(configuration: .init(
            dataStore: dataStore, tabId: tabId, nativeConfiguration: nil, profileId: space.profileId
        ))
        context.browserState.storeHiddenEngine(engine, tabId: engine.id, spaceId: space.id)
        engine.delegate = commander
        attach(engine, to: nil)
        return engine
    }

    /// Open tabs of a folder, or of the space's top level for nil, in sidebar order.
    func tabs(inFolder folderId: UUID?, spaceId: UUID) -> [Tab] {
        context?.browserState.structuralProjection(forSpace: spaceId)?.tabs.filter { $0.groupId == folderId && !$0.isClosed } ?? []
    }

    func number(for tabId: UUID) -> Int {
        if let number = tabNumbers[tabId] { return number }
        tabNumbers[tabId] = nextTabNumber
        nextTabNumber += 1
        return nextTabNumber - 1
    }

    /// A tab of the session's folder by its number, with a live engine attached to a window.
    /// A tab whose page stopped responding fails at once with `needs_user` (the user waits, reloads or closes
    /// it), unless `evenUnresponsive`.
    func agentTab(_ number: Any?, session: AgentSession, evenUnresponsive: Bool = false) throws -> (tab: Tab, engine: WKWebViewTab) {
        // Stop and disconnect end what is still running too, a batch's next step included.
        guard !session.connection.isClosed else { throw AgentToolError("The agent was stopped") }
        guard let number = (number as? NSNumber)?.intValue ?? (number as? String).flatMap(Int.init) else {
            throw AgentToolError("tabId is required")
        }
        let (folderId, agentsSpace, agentsHost) = try agentFolder(for: session, create: false)
        var (space, host) = (agentsSpace, agentsHost)
        var found = folderId.flatMap { id in tabs(inFolder: id, spaceId: space.id).first { tabNumbers[$0.id] == number } }
        if found == nil, let isolated = try isolatedSpace(for: session, create: false),
           let tab = isolatedTabs(of: session).first(where: { tabNumbers[$0.id] == number }) {
            (found, space, host) = (tab, isolated.space, isolated.host)
        }
        guard let tab = found else { throw AgentToolError("Tab \(number) not found: use tabs_context_mcp to list your tabs") }
        // A tab whose engine was let go (the Agents space moved to another profile) gets a new one, unshown.
        guard let engine = host?.tabManager.ensureLiveEngine(forTabId: tab.id)
            ?? context?.windows.window(forTab: tab.id)?.tabManager.engineTab(for: tab.id)
            ?? context?.browserState.engine(tabId: tab.id, spaceId: space.id)
            ?? context?.windows.activeWindow.map({ commander in
                let engine = makeHiddenEngine(tabId: tab.id, space: space, commander: commander)
                if let url = tab.url { engine.loadURL(url) }
                return engine
            }) else {
            throw AgentToolError("Tab \(number) is unloaded")
        }
        // Every tool reaches a tab through here: none touches the user's private browsing, only the agent's own isolated space.
        guard !engine.isPrivateBrowsing || space.id == session.isolatedSpaceId else {
            throw AgentToolError("Tab \(number) is a private tab: agents never read or act on private browsing")
        }
        // A replacement engine (its page was lost) starts unflagged: the refresh only acts on changes.
        if !engine.isAgentControlled { controlledTabIds.remove(tab.id) }
        refreshControlledTabs()
        attach(engine, to: host)
        session.actedOn[tab.id] = Date()
        guard engine.wake() else { throw AgentToolError("Tab \(number) crashed: close it and open a new one") }
        guard evenUnresponsive || !engine.isUnresponsive else {
            throw AgentToolError("""
                Tab \(number) is not responding: its page is stuck. Ask the user to wait, reload or close it in Lilo, \
                or close it with tabs_close_mcp
                """, code: "needs_user")
        }
        return (tab, engine)
    }

    /// Under the shown tab when a window shows the space; otherwise in the parking window. A view another
    /// window shows stays there. With occlusion detection off, the page renders and runs timers at full
    /// rate though nobody sees it: what the agent measures in it is not the throttling of a hidden page.
    func attach(_ engine: WKWebViewTab, to host: MainWindowController?) {
        let parked = engine.view.window === parkingWindow
        setOcclusionDetection(false, on: engine)
        if let host {
            guard engine.view.window == nil || parked else { return }
            engine.fitView(in: host.contentContainerView.bounds)
            engine.view.isHidden = false
            host.contentContainerView.addSubview(engine.view, positioned: .below, relativeTo: nil)
        } else if engine.view.window == nil {
            engine.fitView(in: parkingWindow.contentView?.bounds ?? .zero)
            engine.view.isHidden = false
            parkingWindow.contentView?.addSubview(engine.view)
        }
    }

    func setOcclusionDetection(_ enabled: Bool, on engine: WKWebViewTab) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard engine.wkWebView.responds(to: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(engine.wkWebView.method(for: selector), to: Setter.self)(engine.wkWebView, selector, enabled)
    }

    /// The name of the agent driving `tabId`, as people know it.
    private func agentName(forTab tabId: UUID) -> String {
        let owner = sessions.first { session in
            guard session.isAuthorized else { return false }
            if isolatedTabs(of: session).contains(where: { $0.id == tabId }) { return true }
            guard let folderId = session.folderId, let spaceId = context?.settingsStore?.agentsSpaceId else { return false }
            return tabs(inFolder: folderId, spaceId: spaceId).contains { $0.id == tabId }
        }
        return owner.map { Self.displayName($0.clientName) } ?? "Agent".localized
    }

    /// Flags every tab in the folder of a connected client, and releases tabs that left one, even when
    /// no window shows the agent space any more.
    func refreshControlledTabs() {
        guard let context else { return }
        // The stored id, not agentSpace(): a refresh must not create the space, nor drop every tab while no window is open.
        let agentsSpaceId = context.settingsStore?.agentsSpaceId
        var controlled: Set<UUID> = []
        for session in sessions where session.isAuthorized {
            controlled.formUnion(isolatedTabs(of: session).map(\.id))
            guard let folderId = session.folderId, let agentsSpaceId else { continue }
            controlled.formUnion(tabs(inFolder: folderId, spaceId: agentsSpaceId).map(\.id))
        }
        for id in controlled.symmetricDifference(controlledTabIds) {
            let isControlled = controlled.contains(id)
            let owner = context.windows.window(forTab: id)
            let engine = owner?.tabManager.engineTab(for: id)
                ?? context.browserState.owningSpaceId(forTab: id).flatMap { context.browserState.engine(tabId: id, spaceId: $0) }
            engine?.isAgentControlled = isControlled
            _ = context.browserState.updateTab(id: id) { $0.isAgentControlled = isControlled }
            captures.removeValue(forKey: id)?.stop()
            if let inspector = inspectors.removeValue(forKey: id) {
                inspectorReleases[id] = Task { [weak self] in
                    await inspector.release()
                    self?.inspectorReleases[id] = nil
                }
            }
            recordings[id] = nil
            recordingTabs.remove(id)
            engine?.agentDialogHandler = nil
            guard let engine else { continue }
            guard isControlled else {
                // Undo resize_window, and stop rendering a page nobody looks at any more.
                setOcclusionDetection(true, on: engine)
                AgentFrameView.remove(from: engine.wkWebView)
                if engine.view.window === parkingWindow { engine.view.removeFromSuperview() }
                engine.agentViewport = nil
                engine.view.autoresizingMask = [.width, .height]
                if let container = engine.view.superview { engine.view.frame = container.bounds }
                if let host = context.windows.windows.first(where: { $0.contentContainerView === engine.view.superview }),
                   !host.displayedTabIds.contains(id) {
                    engine.view.removeFromSuperview()
                }
                continue
            }
            // One size wherever the view goes (the user's window or the parking one): a screenshot's
            // coordinates still hold at the next click.
            if engine.agentViewport == nil {
                engine.agentViewport = parkingWindow.contentView?.bounds.size
                if engine.pageZoom != 1 { engine.setPageZoom(1) }
                if let container = engine.view.superview { engine.fitView(in: container.bounds) }
            }
            AgentFrameView.show(on: engine.wkWebView, agentName: agentName(forTab: id))
            let capture = AgentCapture(webView: engine.wkWebView)
            captures[id] = capture
            // Checked at each dialog: a tab dragged out of its folder must not keep answering for the user.
            engine.agentDialogHandler = { [weak self, weak engine, weak capture] text in
                self?.refreshControlledTabs()
                guard engine?.isAgentControlled == true else { return false }
                capture?.note(text)
                return true
            }
        }
        controlledTabIds = controlled
    }

    /// The session's folder in the Agents space: an agent only connected, idle or not, has none, and one
    /// the user deleted no longer counts.
    func agentsSpaceFolder(of session: AgentSession) -> TabFolder? {
        guard session.isAuthorized, let folderId = session.folderId,
              let spaceId = context?.settingsStore?.agentsSpaceId else { return nil }
        return tabFolder(folderId, in: spaceId)
    }

    private func tabFolder(_ id: UUID, in spaceId: UUID) -> TabFolder? {
        context?.browserState.structuralProjection(forSpace: spaceId)?.folders.first { $0.id == id }
    }
}
