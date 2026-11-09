import AppKit

extension MainWindowController {
    /// Shows the changes of the active terminal's repository in a peek over it; a second press
    /// closes it.
    @objc func showChanges(_ sender: Any?) {
        guard let tab = tabManager.activeTab, tab.kind == .terminal else { return NSSound.beep() }
        showChanges(for: tab.id)
    }

    /// A terminal's or a conversation's changes; `tree` scopes them to a conversation's own.
    func showChanges(for id: UUID, since tree: String? = nil) {
        if changesPeek?.tabId == id { return dismissChangesPeek() }
        // The click on a chip toggling the peek closed it already, before the chrome reports it.
        if let closed = changesPeekClosedByClick, closed.tabId == id,
           ProcessInfo.processInfo.systemUptime - closed.time < 0.5 { return }
        guard let tab = tabManager.tab(for: id), tab.kind == .terminal || tab.kind == .agent, let cwd = tab.cwd,
              GitDiff.repositoryRoot(containing: cwd) != nil else { return NSSound.beep() }
        dismissChangesPeek()
        if tabManager.activeOpenTabId != id { activateTabStateFirst(id: id) }
        let view = ChangesView(directory: cwd, since: tree)
        view.showsPeekControls = true
        view.onClose = { [weak self] in self?.dismissChangesPeek() }
        view.onOpenInSplit = { [weak self] in self?.openChangesInSplit() }
        // As large as the content allows: the peek clamps it to the window.
        let peek = PagePeekView(header: nil, content: view, preferredSize: NSSize(width: 1600, height: 1200))
        peek.onDismiss = { [weak self] in
            if let event = NSApp.currentEvent, event.type == .leftMouseDown {
                self?.changesPeekClosedByClick = (id, event.timestamp)
            }
            self?.dismissChangesPeek()
        }
        changesPeek = (id, peek, view)
        peek.autoresizingMask = [.width, .height]
        // The chrome draws a conversation over its empty content view: its peek goes above the chrome.
        if tab.kind == .agent, let root = window?.contentView {
            peek.frame = contentContainerView.frame
            root.addSubview(peek, positioned: .above, relativeTo: chromeWebView)
        } else {
            peek.frame = contentContainerView.bounds
            contentContainerView.addSubview(peek, positioned: .above, relativeTo: nil)
        }
        peek.present()
        window?.makeFirstResponder(view.diffView)
    }

    /// Closes the peek and hands the keyboard back to the terminal under it.
    func dismissChangesPeek() {
        guard let (tabId, peek, _) = changesPeek else { return }
        changesPeek = nil
        peek.dismiss {}
        guard tabId == tabManager.activeOpenTabId else { return }
        if tabManager.tab(for: tabId)?.kind == .agent {
            focusChrome()
        } else if let view = tabManager.loadedContentView(forTabId: tabId) {
            focusContent(view)
        }
    }

    /// Keeps the peek's diff as a Changes tab: a pane beside its tab, or a tab of its own when that
    /// tab is in a folder.
    private func openChangesInSplit() {
        guard let (openerId, peek, view) = changesPeek, let spaceId = tabManager.currentSpaceId else { return }
        changesPeek = nil
        // The view leaves the peek first, so the peek's fade-out never takes it along.
        view.removeFromSuperview()
        view.showsPeekControls = false
        peek.dismiss {}
        let tab = Tab(title: "Changes".localized, kind: .changes, cwd: view.repository)
        tabManager.changesHost.adopt(view, for: tab.id)
        let split = canSplit(beside: openerId)
        do {
            try applyBrowserCommand(.createTab(spaceId: spaceId, tab: tab, activate: !split))
            if split {
                try applyBrowserCommand(.splitTabs(spaceId: spaceId, tabId: tab.id, targetTabId: openerId, vertical: false, before: false))
            }
            tabManager.activateTabRuntime(id: tab.id)
        } catch {
            tabManager.changesHost.forget(tab.id)
            Self.logger.error("open changes in split failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Puts a Changes tab's diff on screen, mirroring `showTerminalView`.
    func showChangesTabView(for tab: Tab) {
        guard let view = tabManager.changesHost.ensureView(for: tab) else { return }
        showNativeContentView(view, forTabId: tab.id)
        window?.makeFirstResponder(view.diffView)
    }
}
