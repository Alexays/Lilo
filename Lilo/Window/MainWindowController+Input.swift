// Keyboard shortcuts and menu actions.

import AppKit
import WebKit

extension MainWindowController {
    // MARK: - Menu Actions

    @objc func newTab(_ sender: Any?) {
        // A chrome_url_overrides.newtab extension replaces the blank new tab (only this user-facing
        // path, never session-restore or programmatic tab creation).
        createTabStateFirst(url: profileContext?.extensions.activeNewTabOverrideURL)
    }

    func openBlankTabWithCommandBar() {
        createTabStateFirst(url: nil)
        bridgeRouter.send(event: "openCommandBar", data: ["newTab": true])
    }
    @objc func newPrivateSpace(_ sender: Any?) {
        // An agent's isolated tabs live in a private space too: that one is the agent's, never reused here.
        let agentSessions = context.agentControl.sessions
        if let existingPrivateSpace = context.spaceManager?.spaces.first(where: { space in
            space.isPrivate && !agentSessions.contains { $0.isolatedSpaceId == space.id }
        }) {
            if tabManager.currentSpaceId != existingPrivateSpace.id {
                switchToSpace(existingPrivateSpace.id)
            }
            openBlankTabWithCommandBar()
            return
        }

        do {
            try createSpace(
                name: "Private",
                icon: "🔒",
                color: "#3f4656",
                isPrivate: true,
                targetProfileId: nil
            )
            openBlankTabWithCommandBar()
        } catch {
            Self.logger.error("Failed to create private space: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc func closeCurrentTab(_ sender: Any?) {
        if let popup = pagePopups.values.first(where: { $0.window?.isKeyWindow == true }) {
            popup.requestClose()
        } else if changesPeek != nil {
            dismissChangesPeek()
        } else if let peek = pagePopups.values.first(where: { $0.peekView?.superview != nil }) {
            peek.requestClose()
        } else if let id = tabManager.activeOpenTabId {
            closeTabStateFirst(id: id)
        }
    }

    @objc func toggleReader(_ sender: Any?) {
        guard let id = tabManager.activeOpenTabId, let engine = tabManager.activeEngineTab else { return }
        if readerModeTabs.contains(id) {
            readerModeTabs.remove(id)
            tabManager.reloadActiveTab()
        } else {
            ReaderMode.apply(to: engine.wkWebView)
            readerModeTabs.insert(id)
        }
    }
    @objc func openSettings(_ sender: Any?) { bridgeRouter.send(event: "openSettings") }
    @objc func clearBrowsingData(_ sender: Any?) { bridgeRouter.send(event: "openClearBrowsingData") }
    @objc func replayOnboarding(_ sender: Any?) { bridgeRouter.send(event: "startOnboarding") }
    @objc func openDesignSystem(_ sender: Any?) { bridgeRouter.send(event: "openDesignSystem") }
    @objc func openDiagnostics(_ sender: Any?) { bridgeRouter.send(event: "openDiagnostics") }
    @objc func togglePerfRecording(_ sender: Any?) { context.togglePerfRecording() }
    @objc func openProcessManager(_ sender: Any?) { bridgeRouter.send(event: "openProcessManager") }
    @objc func openDownloads(_ sender: Any?) { bridgeRouter.send(event: "openDownloads") }
    @objc func openFeatureFlags(_ sender: Any?) { bridgeRouter.send(event: "openConfig") }
    @objc func togglePictureInPicture(_ sender: Any?) { tabManager.activeEngineTab?.togglePictureInPicture() }
    @objc func openHistory(_ sender: Any?) {
        focusChrome()
        bridgeRouter.send(event: "openHistory")
    }
    @objc func addExtension(_ sender: Any?) { createTabStateFirst(url: URL(string: "https://chromewebstore.google.com")) }
    @objc func manageExtensions(_ sender: Any?) { bridgeRouter.send(event: "openExtensions") }

    @objc func toggleHitboxDebug(_ sender: NSMenuItem?) {
        let enabled = !UserDefaults.lilo.bool(forKey: Self.hitboxDebugDefaultsKey)
        UserDefaults.lilo.set(enabled, forKey: Self.hitboxDebugDefaultsKey)
        sender?.state = enabled ? .on : .off
        chromeInput.setDebugOverlayShown(enabled)
    }

    @objc func openExtensionFromMenu(_ sender: NSMenuItem) {
        guard let extensionId = sender.representedObject as? String else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  let registry = self.profileContext?.extensions,
                  registry.context(for: extensionId) != nil else { return }
            if registry.toggleSidePanelOnActionClick?(extensionId, self) == true { return }
            registry.noteUserGesture(extensionId: extensionId)
            registry.delegate.closeOpenActionPopups(reason: "menu open", extensionId: extensionId)
            let actionTabAdapter = self.tabManager.activeOpenTabId.flatMap { self.tabManager.tabAdapter(for: $0) }
            if let actionTabAdapter {
                registry.delegate.windowAdapter?.activeAdapter = actionTabAdapter
            }
            await registry.backgrounds.ensureResponsive(extensionId)
            // Re-fetch: a stale worker is reloaded into a new context (see handleOpenExtensionPopup).
            guard let context = registry.context(for: extensionId) else { return }
            let tab = actionTabAdapter ?? registry.delegate.windowAdapter?.activeTab
            // Reading the popup creates it: watched before its first frame loads.
            if let popup = context.action(for: tab)?.popupWebView { registry.frameCookies.watch(popup) }
            context.performAction(for: tab)
        }
    }

    /// Copies the shown peek's page when there is one, else the active tab's.
    @objc func copyCurrentURL(_ sender: Any?) {
        let peekURL = pagePopups.values.first { $0.peekView?.superview != nil }?.engine.currentURL
        guard let url = (peekURL ?? tabManager.visibleActiveTab?.url)?.absoluteString,
              !url.isEmpty else {
            bridgeRouter.send(event: "urlCopyFailed")
            return
        }

        NSPasteboard.general.clearContents()
        let didCopy = NSPasteboard.general.setString(url, forType: .string)
        bridgeRouter.send(event: didCopy ? "urlCopied" : "urlCopyFailed")
    }

    @objc func printCurrentPage(_ sender: Any?) { tabManager.activeEngineTab?.printPage(in: window) }

    @objc func savePageAs(_ sender: Any?) {
        guard let window, let webView = tabManager.activeEngineTab?.wkWebView, webView.url != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.webArchive, .pdf]
        panel.showsContentTypes = true
        let title = (webView.title?.isEmpty == false ? webView.title : webView.url?.host()) ?? "Page"
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let asPDF = panel.currentContentType == .pdf
            Task { @MainActor in
                do {
                    let data: Data
                    if asPDF {
                        data = try await webView.pdf()
                    } else {
                        data = try await withCheckedThrowingContinuation { continuation in
                            webView.createWebArchiveData { continuation.resume(with: $0) }
                        }
                    }
                    try data.write(to: url, options: .atomic)
                } catch {
                    NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
                }
            }
        }
    }

    @objc func translatePage(_ sender: Any?) {
        guard let webView = tabManager.activeEngineTab?.wkWebView else { return }
        if pageTranslator.hostView.superview == nil { window?.contentView?.addSubview(pageTranslator.hostView) }
        Task { await pageTranslator.toggle(in: webView) }
    }

    @objc func viewPageSource(_ sender: Any?) {
        guard let url = tabManager.visibleActiveTab?.url, url.scheme == "http" || url.scheme == "https",
              let source = URL(string: "\(ViewSourceSchemeHandler.scheme):\(url.absoluteString)") else { return }
        // The markup the tab already loaded: a re-fetch costs a slow link the whole page, and may get another one.
        let handedOver = tabManager.activeEngineTab.map { engine in
            WebViewPrivateAccessors(engine.wkWebView).mainResourceData { [weak self] data in
                guard let self else { return }
                if let data, engine.currentURL == url { context.engineFactory.viewSourceSchemeHandler.handOver(data, of: url) }
                createTabStateFirst(url: source)
            }
        } ?? false
        if !handedOver { createTabStateFirst(url: source) }
    }
    @objc func duplicateCurrentTab(_ sender: Any?) { if let tab = tabManager.visibleActiveTab { duplicateTab(tab) } }
    @objc func restoreClosedTab(_ sender: Any?) { _ = restoreClosedTabStateFirst() }

    /// During a call, toggles the call's microphone instead: muting the call's tab would silence the others.
    @objc func toggleMuteCurrentTab(_ sender: Any?) {
        if let call = shownCallTab { return controlCall(tabId: call.id, action: "togglemicrophone") }
        if let id = tabManager.activeOpenTabId, let tab = tabManager.activeTab { tabManager.setTabMuted(id: id, muted: !tab.isMuted) }
    }

    @objc func showWebInspector(_ sender: Any?) { tabManager.activeEngineTab?.showWebInspector() }
    @objc func showChromeWebInspector(_ sender: Any?) { _ = WebInspectorSupport.show(for: chromeWebView) }
    @objc func inspectElement(_ sender: Any?) { tabManager.activeEngineTab?.toggleWebInspectorElementSelection() }
    @objc func showWebInspectorConsole(_ sender: Any?) { tabManager.activeEngineTab?.showWebInspectorConsole() }
    @objc func showWebInspectorResources(_ sender: Any?) { tabManager.activeEngineTab?.showWebInspectorResources() }
    @objc func toggleWebInspectorPageProfiling(_ sender: Any?) { tabManager.activeEngineTab?.toggleWebInspectorPageProfiling() }

    @objc func reloadCurrentPageFromOrigin(_ sender: Any?) {
        if let host = tabManager.activeTab?.url?.host { context.faviconService.clear(for: host) }
        tabManager.reloadActiveTab(fromOrigin: true)
    }

    // MARK: - Menu-bar navigation / zoom / find actions
    //
    // Shared with the keyboard shortcuts below: menu items carry the key equivalents (so the combos
    // show in the menu), and these actions back both the menu and the chrome's own controls.

    @objc func goBackInHistory(_ sender: Any?) { tabManager.activeEngineTab?.goBack() }
    @objc func goForwardInHistory(_ sender: Any?) { tabManager.activeEngineTab?.goForward() }

    /// The active tab's previous or next page in a new tab, as Cmd- or middle-clicking Back and Forward does in Chrome and Safari.
    func openHistoryInNewTab(forward: Bool, inBackground: Bool) {
        guard let engine = tabManager.activeEngineTab else { return }
        let list = engine.wkWebView.backForwardList
        guard let item = forward ? list.forwardItem : list.backItem,
              let created = createTabStateFirst(url: item.url, activate: !inBackground, opener: engine.id) else { return }
        if inBackground { noteBackgroundTab(created.id) }
    }
    @objc func reloadCurrentPage(_ sender: Any?) { tabManager.reloadActiveTab() }
    @objc func stopLoadingCurrentPage(_ sender: Any?) { tabManager.activeEngineTab?.stopLoading() }
    @objc func zoomInCurrentPage(_ sender: Any?) { zoomActiveTab(by: 0.1) }
    @objc func zoomOutCurrentPage(_ sender: Any?) { zoomActiveTab(by: -0.1) }
    @objc func resetCurrentPageZoom(_ sender: Any?) { resetActiveTabZoom() }
    @objc func showFindBar(_ sender: Any?) { presentFindBar() }
    @objc func openLocation(_ sender: Any?) {
        focusChrome()
        bridgeRouter.send(event: "toggleCommandBar", data: ["prefill": tabManager.visibleActiveTab?.url?.absoluteString ?? "", "selectAll": true])
    }
    @objc func toggleSidebarVisibility(_ sender: Any?) { toggleSidebar() }
    @objc func toggleToolbarVisibility(_ sender: Any?) { toggleToolbar() }
    @objc func showNextTab(_ sender: Any?) { switchToAdjacentTab(forward: true) }
    @objc func showPreviousTab(_ sender: Any?) { switchToAdjacentTab(forward: false) }
    /// A page picked in the History menu loads in the current tab.
    @objc func openHistoryItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if tabManager.activeTab?.kind == .web, let engine = tabManager.activeEngineTab { engine.loadURL(url) } else { createTabStateFirst(url: url) }
    }
    @objc func openHelp(_ sender: Any?) { createTabStateFirst(url: URL(string: "https://github.com/Alexays/Lilo#readme")) }
    @objc func reportIssue(_ sender: Any?) {
        createTabStateFirst(url: URL(string: "https://github.com/Alexays/Lilo/issues/new?template=bug_report.yml"))
    }
    /// The bug report form, filled in about the active page freezing; the user reviews it and sends it, or not.
    func reportUnresponsivePage() {
        let page = tabManager.activeEngineTab?.currentURL
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let extensions = profileContext?.extensions.loadedExtensions.map { $0.context.webExtension.displayName ?? $0.id } ?? []
        var form = URLComponents(string: "https://github.com/Alexays/Lilo/issues/new")
        form?.queryItems = [
            URLQueryItem(name: "template", value: "bug_report.yml"),
            URLQueryItem(name: "title", value: "[Bug] \(page?.host() ?? "A page") keeps freezing"),
            URLQueryItem(name: "lilo-version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String),
            URLQueryItem(name: "macos-version", value: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
            URLQueryItem(name: "actual", value: """
                The page stopped responding twice in a row.

                URL: \(page?.absoluteString ?? "")
                Enabled extensions: \(extensions.isEmpty ? "none" : extensions.joined(separator: ", "))
                """)
        ]
        createTabStateFirst(url: form?.url)
    }
    @objc func findNextMatch(_ sender: Any?) {
        if let terminal = activeTerminalView { terminal.findAgain(older: true) } else { tabManager.activeEngineTab?.findNext() }
    }

    @objc func findPreviousMatch(_ sender: Any?) {
        if let terminal = activeTerminalView { terminal.findAgain(older: false) } else { tabManager.activeEngineTab?.findPrevious() }
    }

    /// Adjust the active tab's zoom by `delta`, clamped, persisted per host, and reflected in the chrome.
    func zoomActiveTab(by delta: Double) {
        if let terminal = activeTerminalView {
            bridgeRouter.send(event: "zoomChanged", data: ["level": terminal.setZoom(by: delta > 0 ? 1 : -1)])
            return
        }
        guard let engine = tabManager.activeEngineTab else { return }
        applyUserZoom(min(3.0, max(0.5, engine.pageZoom + delta)), to: engine)
    }

    func resetActiveTabZoom() {
        if let terminal = activeTerminalView {
            bridgeRouter.send(event: "zoomChanged", data: ["level": terminal.setZoom(by: nil)])
            return
        }
        guard let engine = tabManager.activeEngineTab else { return }
        applyUserZoom(1.0, to: engine, isReset: true)
    }

    /// A zoom the user asked for, as the tab's extension zoom settings allow: a disabled tab ignores
    /// it and a manual one only tells its extension. A per-origin reset forgets the host's level.
    private func applyUserZoom(_ zoom: Double, to engine: WKWebViewTab, isReset: Bool = false) {
        guard let host = tabManager.activeTab?.url?.host else { return }
        switch engine.zoomSettings.mode {
        case "disabled": return
        case "manual": return engine.reportZoomChange(from: engine.pageZoom, to: zoom)
        default: engine.setPageZoom(zoom)
        }
        if !engine.isPrivateBrowsing, engine.zoomSettings.scope == "per-origin" {
            if isReset { profileContext?.zoom.removeZoom(forHost: host) } else { profileContext?.zoom.setZoom(zoom, forHost: host) }
        }
        bridgeRouter.send(event: "zoomChanged", data: ["level": zoom])
        if let adapter = tabManager.tabAdapter(for: engine.id), let registry = tabManager.extensionRegistry, registry.hasLoadedExtensions {
            registry.controller.didChangeTabProperties(.zoomFactor, for: adapter)
        }
    }

    func presentFindBar() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let selectedText = if let terminal = activeTerminalView {
                terminal.session.withLockedTerminal { $0.selectionText }
            } else {
                await tabManager.activeEngineTab?.selectedTextForFind()
            }
            focusChrome()
            if let selectedText {
                bridgeRouter.send(event: "toggleFindBar", data: ["query": selectedText])
            } else {
                bridgeRouter.send(event: "toggleFindBar")
            }
        }
    }

    // MARK: - Keyboard Shortcuts

    func handleMonitoredKeyboardEvent(_ event: NSEvent) -> Bool {
        // Every window's monitor sees every key: a browser window handles its own, and the
        // active one also those of floating panels (extension popovers, panels). Page popups,
        // the detached inspector, sheets and modal panels keep their keys.
        let target = event.window
        guard target === window
            || (context.windows.activeWindow === self
                && (target == nil || (target is NSPanel && !(target is NSSavePanel)
                    && target?.sheetParent == nil && NSApp.modalWindow == nil)))
        else { return false }
        if isShowingWhatsNew { return false }
        if event.type == .flagsChanged {
            // Pushes Command-key state to the chrome so the hover-link pill can flag "open in background tab".
            let down = event.modifierFlags.contains(.command)
            if down != lastCommandKeyDown {
                lastCommandKeyDown = down
                bridgeRouter?.send(event: "commandKeyChanged", data: ["down": down])
            }
        }
        if event.type == .keyDown, let id = recordingShortcutId {
            recordShortcut(event, for: id)
            return true
        }
        if handleTabSwitcherEvent(event) { return true }
        // ⌘← and ⌘→ go through history as in Chrome, while the focused page has no caret or selection for them to move:
        // WebKit would scroll with them otherwise, so the page never lets them go.
        if event.type == .keyDown, event.keyCode == 123 || event.keyCode == 124,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]) == .command,
           let webView = window?.firstResponder as? WKWebView, webView !== chromeWebView,
           WebViewPrivateAccessors(webView).int("_selectionAttributes") == 0 {
            if event.keyCode == 123 { goBackInHistory(nil) } else { goForwardInHistory(nil) }
            return true
        }
        // Escape while a press is held in the chrome (a sidebar drag) belongs to that drag,
        // wherever key focus is.
        if event.type == .keyDown, event.keyCode == 53, chromeInput.coordinator.isCapturing,
           chromeInput.coordinator.effectiveCaptureTarget == .chrome {
            bridgeRouter?.send(event: "cancelDrag")
            return true
        }
        return (event.type == .keyDown && handleKeyboardShortcut(event))
            || (event.type == .keyDown && profileContext?.extensions.handleExtensionKeyDown(event) == true)
            || routeUnhandledGlobalEvent(event)
    }

    /// The shortcuts Lilo takes ahead of the page; the other actions reach their menu item once the
    /// page let the key go.
    func handleKeyboardShortcut(_ event: NSEvent) -> Bool {
        guard let id = KeyboardShortcuts.action(for: event) else { return false }
        switch id {
        case "tab.new":
            // The chrome knows whether the command bar is open, so it toggles the blank new tab.
            if profileContext?.extensions.activeNewTabOverrideURL != nil {
                newTab(nil)
            } else if let activeTab = tabManager.activeTab, activeTab.url == nil, activeTab.kind == .web {
                bridgeRouter.send(event: "toggleNewTab")
            } else {
                openBlankTabWithCommandBar()
            }
        case "space.newPrivate": newPrivateSpace(nil)
        case "tab.close": closeCurrentTab(nil)
        case "window.close": window?.performClose(nil)
        case "location.open": openLocation(nil)
        case "devtools.inspector": showWebInspector(nil)
        case "page.reload": reloadCurrentPage(nil)
        case "page.reloadFromOrigin": reloadCurrentPageFromOrigin(nil)
        case "history.back": goBackInHistory(nil)
        case "history.forward": goForwardInHistory(nil)
        case "tab.reopenClosed": _ = restoreClosedTabStateFirst()
        case "sidebar.toggle": toggleSidebar()
        case "toolbar.toggle": toggleToolbar()
        case "tabs.positionLeft": setTabPosition(.left)
        case "tabs.positionRight": setTabPosition(.right)
        case "tabs.positionTop": setTabPosition(.top)
        case "tabs.positionBottom": setTabPosition(.bottom)
        case "page.copyURL": copyCurrentURL(nil)
        case "tab.mute": toggleMuteCurrentTab(nil)
        case "zoom.in": zoomInCurrentPage(nil)
        case "zoom.out": zoomOutCurrentPage(nil)
        case "zoom.reset": resetCurrentPageZoom(nil)
        case "terminal.newTab": createTerminalTab()
        case "tab.next", "tab.previous": switchToAdjacentTab(forward: id == "tab.next")
        case "tab.recentNext", "tab.recentPrevious": openTabSwitcher(holding: event.modifierFlags, backwards: id == "tab.recentPrevious")
        case "find.show": presentFindBar()
        case "find.next": findNextMatch(nil)
        case "find.previous": findPreviousMatch(nil)
        case "page.print": printCurrentPage(nil)
        case "page.save": savePageAs(nil)
        case "page.viewSource": viewPageSource(nil)
        case "app.settings": openSettings(nil)
        // The Spaces menu is rebuilt on open, so it never answers a key: every item of it is matched here.
        case "space.next", "space.previous": switchToAdjacentSpace(forward: id == "space.next")
        case "space.new": newSpace(nil)
        case "space.edit": editCurrentSpace(nil)
        default:
            if id.hasPrefix("tab.select"), let ordinal = Int(id.dropFirst(10)) {
                selectTab(ordinal: ordinal)
            } else if id.hasPrefix("space.select"), let ordinal = Int(id.dropFirst(12)) {
                switchToSpace(ordinal: ordinal)
            } else {
                return false
            }
        }
        return true
    }

    /// Settings records the shortcut `id`: Escape cancels, Delete unbinds, and keys another action
    /// holds go back to Settings to confirm.
    private func recordShortcut(_ event: NSEvent, for id: String) {
        let bare = event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift])
        if bare, event.keyCode == 53 {
            recordingShortcutId = nil
        } else if bare, event.keyCode == 51 || event.keyCode == 117 {
            recordingShortcutId = nil
            KeyboardShortcuts.set(id, to: [], store: context.settingsStore)
        } else if let combo = KeyboardShortcuts.combo(for: event) {
            recordingShortcutId = nil
            if let owner = KeyboardShortcuts.owner(of: combo), owner.id != id {
                bridgeRouter?.send(event: "shortcutConflict", data: [
                    "id": id, "combo": combo, "keys": KeyboardShortcuts.display(combo), "owner": owner.title
                ])
                return
            }
            KeyboardShortcuts.set(id, to: [combo], store: context.settingsStore)
        } else {
            // Typing keys never bind: one needs ⌘, ⌃ or ⌥, unless it is a function key.
            NSSound.beep()
            return
        }
        bridgeRouter?.send(event: "shortcutsLoaded", data: KeyboardShortcuts.bridgePayload)
    }

    @discardableResult
    func routeUnhandledGlobalEvent(_ event: NSEvent) -> Bool {
        guard let window else { return false }
        guard event.windowNumber == 0 || event.windowNumber == window.windowNumber else { return false }
        // Only forward to content when focus is nowhere (the window itself or nil). Any focused view
        // keeps its own keys, such as a WKWebExtension popup web view, which would type them twice.
        let responder = window.firstResponder
        guard responder == nil || responder === window else { return false }
        return chromeInput.router.routeUnhandledGlobalEvent(event)
    }

    func switchToAdjacentTab(forward: Bool) {
        let tabs = tabManager.currentTabs
        guard tabs.count > 1, let activeId = tabManager.activeOpenTabId,
              let idx = tabs.firstIndex(where: { $0.id == activeId }) else { return }
        let next = forward ? (idx + 1) % tabs.count : (idx - 1 + tabs.count) % tabs.count
        activateTabStateFirst(id: tabs[next].id)
    }

    /// Selects the Nth open tab in the active space (1-based). `9` always selects the last tab;
    /// `1` to `8` are no-ops when fewer tabs are open.
    func selectTab(ordinal: Int) {
        let openTabs = tabManager.currentTabs.filter { !$0.isClosed }
        guard !openTabs.isEmpty else { return }
        let index = ordinal == 9 ? openTabs.count - 1 : ordinal - 1
        guard index >= 0, index < openTabs.count else { return }
        activateTabStateFirst(id: openTabs[index].id)
    }
}

extension MainWindowController: NSUserInterfaceValidations {
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        let action = item.action
        if isShowingWhatsNew && action != #selector(showWhatsNew(_:)) { return false }

        if action == #selector(closeCurrentTab(_:)) { return tabManager.activeTab != nil }
        if action == #selector(openPageAsTab(_:)) { return pagePopups.values.contains { $0.peekView?.superview != nil } }
        if action == #selector(goBackInHistory(_:)) { return tabManager.activeEngineTab?.wkWebView.canGoBack == true }
        if action == #selector(goForwardInHistory(_:)) { return tabManager.activeEngineTab?.wkWebView.canGoForward == true }
        if action == #selector(stopLoadingCurrentPage(_:)) { return tabManager.activeTab?.isLoading == true }
        if action == #selector(showNextTab(_:)) || action == #selector(showPreviousTab(_:)) { return tabManager.currentTabs.count > 1 }
        if action == #selector(togglePerfRecording(_:)) {
            (item as? NSMenuItem)?.title = PerfRecorder.isRecording ? "Stop Performance Recording".localized : "Record Performance Session".localized
            return true
        }
        if action == #selector(toggleSidebarVisibility(_:)) {
            (item as? NSMenuItem)?.title = sidebarVisible ? "Hide Sidebar".localized : "Show Sidebar".localized
            return !sidebarCollapseLocked
        }
        if action == #selector(toggleToolbarVisibility(_:)) {
            (item as? NSMenuItem)?.title = toolbarVisible ? "Hide Toolbar".localized : "Show Toolbar".localized
            return tabLayout.canHideToolbar
        }
        if action == #selector(toggleMuteCurrentTab(_:)), let call = shownCallTab {
            let muted = call.isMicrophoneMuted || context.browserState.liveEngine(forTab: call.id)?.callControls.microphoneActive == false
            (item as? NSMenuItem)?.title = muted ? "Unmute Microphone".localized : "Mute Microphone".localized
            (item as? NSMenuItem)?.image = (muted ? MenuIcon.unmute : .mute).image
            return true
        }
        if action == #selector(toggleMuteCurrentTab(_:)) {
            let muted = tabManager.activeTab?.isMuted == true
            (item as? NSMenuItem)?.title = muted ? "Unmute Tab".localized : "Mute Tab".localized
            (item as? NSMenuItem)?.image = (muted ? MenuIcon.unmute : .mute).image
            return tabManager.activeTab != nil
        }
        if action == #selector(copyCurrentURL(_:)) || action == #selector(copyCurrentURLAsMarkdown(_:)) || action == #selector(duplicateCurrentTab(_:)) {
            return tabManager.visibleActiveTab?.url != nil
        }
        if action == #selector(closeOtherTabs(_:)) { return tabManager.currentTabs.count > 1 }
        if action == #selector(restoreClosedTab(_:)) { return !context.recentlyClosed.recentEntries.isEmpty }
        if action == #selector(showNextSpace(_:)) || action == #selector(showPreviousSpace(_:)) { return switchableSpaces.count > 1 }
        if action == #selector(pinCurrentTab(_:)) {
            let pinned = tabManager.activeTab?.isPinned == true
            (item as? NSMenuItem)?.title = pinned ? "Unpin Tab".localized : "Pin Tab".localized
            (item as? NSMenuItem)?.image = (pinned ? MenuIcon.unpin : .pin).image
            return tabManager.activeTab != nil
        }
        if action == #selector(bookmarkCurrentTab(_:)) {
            (item as? NSMenuItem)?.state = tabManager.activeTab?.isBookmarked == true ? .on : .off
            return tabManager.activeTab != nil
        }
        if action == #selector(moveCurrentTabToNewWindow(_:)) { return context.settingsStore?.singleWindow == false && tabManager.activeOpenTabId != nil }
        if action == #selector(keepCurrentTabAwakeUntilDone(_:)) {
            guard let tab = tabManager.activeTab, tab.kind == .terminal else { return false }
            return tabManager.terminalHost.isBusy(tab.id) && context.settingsStore?.get("terminalPreventSleep") != "false"
        }
        if action == #selector(takeViewportScreenshot(_:)) || action == #selector(takeFullPageScreenshot(_:))
            || action == #selector(startRegionSelection(_:)) {
            return tabManager.activeEngineTab != nil
        }
        if action == #selector(reloadCurrentPageFromOrigin(_:)) { return tabManager.activeTab?.url != nil }
        // A terminal or Changes tab has no page for these.
        if action == #selector(reloadCurrentPage(_:)) || action == #selector(togglePictureInPicture(_:)) { return tabManager.activeEngineTab != nil }
        if action == #selector(printCurrentPage(_:)) { return tabManager.activeEngineTab?.wkWebView.url != nil }
        if action == #selector(toggleReader(_:)) {
            let reading = tabManager.activeOpenTabId.map(readerModeTabs.contains) == true
            (item as? NSMenuItem)?.title = reading ? "Hide Reader".localized : "Show Reader".localized
            return tabManager.activeEngineTab?.wkWebView.url != nil
        }
        if action == #selector(shareCurrentPage(_:)) || action == #selector(showQRCode(_:)) { return shareableURL() != nil }
        if action == #selector(savePageAs(_:)) || action == #selector(translatePage(_:)) { return tabManager.activeEngineTab?.wkWebView.url != nil }
        if action == #selector(newSplitView(_:)) {
            return tabManager.activeTab != nil && (tabManager.activeSplit?.layout.paneIds.count ?? 0) < SplitLayout.maxPanes
        }
        if action == #selector(closeSplitView(_:)) { return tabManager.activeSplit != nil }
        if action == #selector(showChanges(_:)) { return tabManager.activeTab.map { $0.kind == .terminal && !$0.gitBranch.isEmpty } ?? false }
        if action == #selector(newTerminalBeside(_:)) || action == #selector(newTerminalBelow(_:)) || action == #selector(newTerminalTab(_:))
            || action == #selector(showNextWaitingTerminal(_:)) {
            return context.settingsStore?.terminalEnabled != false
        }
        if action == #selector(viewPageSource(_:)) { return ["http", "https"].contains(tabManager.visibleActiveTab?.url?.scheme) }

        if action == #selector(showWebInspector(_:))
            || action == #selector(inspectElement(_:))
            || action == #selector(showWebInspectorConsole(_:))
            || action == #selector(showWebInspectorResources(_:))
            || action == #selector(toggleWebInspectorPageProfiling(_:)) {
            guard let engine = tabManager.activeEngineTab,
                  engine.supportsWebInspector else {
                if let menuItem = item as? NSMenuItem {
                    menuItem.state = .off
                }
                return false
            }

            if let menuItem = item as? NSMenuItem {
                if action == #selector(inspectElement(_:)) {
                    menuItem.state = engine.isWebInspectorElementSelectionActive ? .on : .off
                } else if action == #selector(toggleWebInspectorPageProfiling(_:)) {
                    menuItem.state = engine.isWebInspectorPageProfilingActive ? .on : .off
                } else {
                    menuItem.state = .off
                }
            }

            return true
        }

        return true
    }
}
