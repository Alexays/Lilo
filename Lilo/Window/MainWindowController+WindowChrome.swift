// Sidebar layout, traffic lights, window chrome, initial state, permissions, external URLs.

import AppKit
import Security
import SecurityInterface
import WebKit

extension MainWindowController {
    // MARK: - Window-level entry points (called by bridge handlers)

    func saveSessionBeforeQuit() {
        syncActiveBrowserState()
        // Terminals of private Spaces leave nothing behind; the others are saved for the next launch.
        let terminals = tabManager.terminalHost
        let privateSpaces = Set((context.spaceManager?.spaces ?? []).filter(\.isPrivate).map(\.id))
        for id in terminals.liveTabIds where context.browserState.durableTab(for: id).map({ privateSpaces.contains($0.spaceId) }) ?? false {
            terminals.forget(id)
        }
        terminals.saveSnapshots(visible: true)
        for space in context.spaceManager?.spaces ?? [] where space.isPrivate {
            context.downloadManager.forgetPrivateDownloads(inSpace: space.id)
        }
        saveWindowFrame()
        if let work = pendingWindowBackgroundPersistWork {
            pendingWindowBackgroundPersistWork = nil
            work.perform()
            work.cancel()
        }
        // Capture the live space's interaction states synchronously so a relaunch restores the active
        // tab and recent tabs to their exact navigation state instead of cold-loading their URLs.
        if let currentSpaceId = tabManager.currentSpaceId {
            persistInteractionStates(forSpace: currentSpaceId, synchronous: true)
        }
    }

    func clearPersistentSiteData() async {
        for profile in context.profileManager?.profiles ?? [] {
            await context.profileManager.dataStore(for: profile.id).removeAllData(modifiedSince: .distantPast)
        }
    }

    /// The press behind an async chrome request. NSApp.currentEvent may have advanced by the time the
    /// IPC call is processed, so the last mouse-down the overlay web view received stands in.
    var chromeLeftMouseEvent: NSEvent? {
        if let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseDragged { return event }
        return chromeWebView.lastMouseDownEvent
    }

    func startWindowDrag() {
        guard let window, let event = chromeLeftMouseEvent else { return }
        window.performDrag(with: event)
    }

    func handleSidebarOverlay(visible: Bool) {
        sidebarOverlayVisible = visible && !sidebarVisible
        syncTrafficLights(animated: true)
    }

    /// The sidebar's width as the window lets it be: it narrows before the content gets under `minimumContentWidth`.
    var fittedSidebarWidth: CGFloat {
        guard sidebarVisible, tabLayout.position.isVertical else { return 0 }
        let room = (window?.contentView?.bounds.width ?? .greatestFiniteMagnitude) - Self.contentInset * 2 - Self.minimumContentWidth
        return min(sidebarExpandedWidth, max(Self.sidebarWidthRange.lowerBound, room))
    }

    func applySidebarLayout(animated: Bool, syncTrafficLights: Bool = false) {
        sidebarWidth = fittedSidebarWidth
        sidePanel.fitToWindow()
        updateContentContainerFrame(animated: animated)
        if syncTrafficLights { self.syncTrafficLights(animated: animated) }
    }

    func applyTabLayout(_ layout: TabLayout, animated: Bool) {
        guard layout != tabLayout else { return }
        tabLayout = layout
        applyTitlebarStyle()
        applySidebarLayout(animated: animated, syncTrafficLights: true)
        bridgeRouter?.send(event: "tabLayoutChanged", data: ["position": layout.position.rawValue, "address": layout.address.rawValue])
    }

    /// The unified style centers the lights in the sidebar's 52pt header; the compact one centers them at 20pt,
    /// on the line of a 40pt page toolbar or strip.
    func applyTitlebarStyle() {
        window?.toolbarStyle = tabLayout == .default ? .unified : .unifiedCompact
    }

    /// The setting is app-wide: every window moves, and the next launch paints the new layout first.
    func applyStoredTabLayoutEverywhere() {
        guard let layout = context.settingsStore?.tabLayout else { return }
        layout.cache()
        let animated = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        context.windows.windows.forEach { $0.applyTabLayout(layout, animated: animated) }
    }

    func setTabPosition(_ position: TabPosition) {
        context.settingsStore?.set("tabPosition", value: position.rawValue)
        applyStoredTabLayoutEverywhere()
    }

    func updateSidebarWidth(_ width: CGFloat) {
        sidebarExpandedWidth = width.clamped(to: Self.sidebarWidthRange)
        applySidebarLayout(animated: false)

        // Persist only after the drag comes to rest (~500ms trailing) to avoid a synchronous
        // SQLite INSERT OR REPLACE + UserDefaults write on every rAF frame during live resize.
        pendingSidebarWidthPersistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            context.settingsStore.sidebarWidth = sidebarExpandedWidth
            UserDefaults.lilo.set(Double(sidebarExpandedWidth), forKey: "cachedSidebarWidth")
        }
        pendingSidebarWidthPersistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func setSidebarCollapseLocked(_ locked: Bool) {
        sidebarCollapseLocked = locked

        if locked && !sidebarVisible {
            sidebarVisible = true
            sidebarOverlayVisible = false
            context.settingsStore.sidebarVisible = true
            UserDefaults.lilo.set(true, forKey: "cachedSidebarVisible")
            applySidebarLayout(animated: true, syncTrafficLights: true)
            bridgeRouter.send(event: "sidebarVisibilityChanged", data: ["visible": true, "width": sidebarExpandedWidth])
        }
    }

    func toggleSidebar() {
        guard !sidebarCollapseLocked else { return }

        sidebarVisible.toggle()
        sidebarOverlayVisible = false
        context.settingsStore.sidebarVisible = sidebarVisible
        UserDefaults.lilo.set(sidebarVisible, forKey: "cachedSidebarVisible")
        applySidebarLayout(animated: true, syncTrafficLights: true)

        bridgeRouter.send(event: "sidebarVisibilityChanged", data: ["visible": sidebarVisible, "width": sidebarExpandedWidth])
    }

    /// A floating overlay covers the lights' top-left corner only when it comes from the left or the top.
    func areTrafficLightsVisible() -> Bool {
        let overlayCoversLights = sidebarOverlayVisible && (tabLayout.position == .left || tabLayout.position == .top)
        return window?.styleMask.contains(.fullScreen) != true && (sidebarVisible || overlayCoversLights)
    }

    func showActiveTabSecurityInfo() {
        guard let window,
              window.attachedSheet == nil,
              let activeTab = tabManager.activeTab,
              activeTab.url?.scheme?.lowercased() == "https",
              let engineTab = tabManager.activeEngineTab,
              let trust = engineTab.wkWebView.serverTrust,
              let panel = SFCertificatePanel.shared() else {
            NSSound.beep()
            return
        }

        panel.beginSheet(
            for: window,
            modalDelegate: nil,
            didEnd: nil,
            contextInfo: nil,
            trust: trust,
            showGroup: true
        )
    }

    /// Shows the traffic lights with the sidebar, and hides them when it is collapsed.
    func syncTrafficLights(animated: Bool) {
        let visible = areTrafficLightsVisible()
        // Skip the bridge send when the visibility hasn't changed (common during live resize).
        if lastSentTrafficLightsVisible != visible {
            lastSentTrafficLightsVisible = visible
            bridgeRouter?.send(event: "windowChromeStateChanged", data: ["trafficLightsVisible": visible])
        }
        guard let window else { return }
        trafficLightAnimator.sync(
            window: window,
            visible: visible,
            animated: animated,
            duration: WindowFrameView.toggleDuration
        )
    }

    func sendInitialState() {
        hasDispatchedChromeInitialState = true
        let data = makeChromeInitialState()
        // initialState re-seeds the chrome from scratch and carries favicons only for the current
        // space's tabs; every other space must ship favicons again on its first full-state emit.
        chromeFaviconSyncedSpaceIds = tabManager.currentSpaceId.map { [$0] } ?? []
        sentTabPatches = [:]
        sentExtensionRows = [:]
        for row in data["extensions"] as? [[String: Any]] ?? [] {
            if let id = row["id"] as? String { sentExtensionRows[id] = row }
        }

        StartupMetrics.mark("chromeInitialStateSent")
        bridgeRouter.send(event: "initialState", data: data)
        sendShortcutKeys()
        if (NSApp.delegate as? AppDelegate)?.readyUpdate != nil { sendUpdateReady() }
        // A reloaded chrome starts blank: it needs the split panes and the placeholder again.
        splitPanes.sentPaneFrames = [:]
        splitPanes.applyFrames(animatesFocus: false)
        if let placeholderTabId {
            let folder = tabManager.tab(for: placeholderTabId).flatMap { tabManager.protectingFolder(of: $0) }
            showContentPlaceholder(for: placeholderTabId, lockedFolderId: folder?.isLocked == true ? folder?.id : nil)
        }
        // The active tab's web view waits for the chrome to apply this state (its initialStateApplied
        // message): the chrome's load and first frames need this thread, which building that view holds.
        // A chrome that never reports back (failed bundle) still gets its tab here.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.activateRestoredActiveRuntimeIfNeeded() }
        // A terminal has no URL either, but it is not a new tab waiting for one. The onboarding opens
        // the bar itself when it ends: shown now, it would stack over the onboarding.
        if !context.settingsStore.shouldShowOnboarding, tabManager.activeTab.map({ $0.url == nil && $0.kind == .web }) ?? false {
            bridgeRouter.send(event: "openCommandBar", data: ["newTab": true])
        }
    }

    func handleChromeReady() {
        didReceiveChromeReady = true
        #if DEBUG
        chromeInput.setDebugOverlayShown(UserDefaults.lilo.bool(forKey: Self.hitboxDebugDefaultsKey))
        #endif
        dispatchChromeInitialStateIfPossible()
    }

    func handleChromeVisualReady(occurredAt epochMilliseconds: Double?) {
        StartupMetrics.mark("chromeVisualReady", occurredAt: epochMilliseconds)
        // Launch benchmark (scripts/bench_startup.sh): dump the marks once the late ones have landed, then quit.
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["LILO_STARTUP_BENCH_OUT"], !path.isEmpty else { return }
        let linger = environment["LILO_STARTUP_BENCH_LINGER"].flatMap(Double.init) ?? 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + linger) {
            if let data = try? JSONSerialization.data(withJSONObject: StartupMetrics.bridgeSnapshot()) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }

    func enqueuePermissionRequest(tabId: UUID, type: String, origin: String, completion: @escaping (Bool) -> Void) {
        let id = UUID()
        let timeoutWork = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                // A released window took its queue along: WebKit still needs its answer.
                guard let self else { return completion(false) }
                self.finishPermissionRequest(id: id, granted: false, answeredByUser: false)
            }
        }
        pendingPermissionRequests.append(PendingPermissionRequest(
            id: id, tabId: tabId, type: type, origin: origin,
            isPrivate: tabManager.engineTab(for: tabId)?.isPrivateBrowsing ?? false,
            completion: completion, timeoutWork: timeoutWork
        ))
        DispatchQueue.main.asyncAfter(deadline: .now() + permissionRequestTimeout, execute: timeoutWork)
        // The chrome UI anchors the prompt to its tab and only renders it while that tab is on
        // screen, so every request ships right away instead of waiting for its turn at the front.
        bridgeRouter.send(event: "permissionRequest", data: [
            "requestId": id.uuidString, "tabId": tabId.uuidString, "type": type, "origin": origin
        ])
    }

    /// The chrome UI names the request it is showing: it can belong to any tab, not just the front.
    /// `remember` false is a dismissal: denied for now, no decision stored, so the site may ask again.
    func resolvePermissionRequest(requestId: UUID, granted: Bool, remember: Bool = true) {
        finishPermissionRequest(id: requestId, granted: granted, answeredByUser: remember)
    }

    /// A closing tab can never receive its answer; deny so the WebKit handlers are still invoked.
    func denyPermissionRequests(forTab tabId: UUID) {
        for request in pendingPermissionRequests.filter({ $0.tabId == tabId }) {
            finishPermissionRequest(id: request.id, granted: false, answeredByUser: false)
        }
    }

    /// A main-frame commit on another origin leaves the requesting page gone; its prompts are
    /// denied without storing a decision.
    func denyPermissionRequests(forTab tabId: UUID, notFromOrigin origin: String) {
        for request in pendingPermissionRequests.filter({ $0.tabId == tabId && $0.origin != origin }) {
            finishPermissionRequest(id: request.id, granted: false, answeredByUser: false)
        }
    }

    /// Sole exit point for a queued request: removal precedes the completion call, so every WebKit
    /// handler runs exactly once and a late resolve for an already-finished id is a no-op.
    private func finishPermissionRequest(id: UUID, granted: Bool, answeredByUser: Bool) {
        guard let index = pendingPermissionRequests.firstIndex(where: { $0.id == id }) else { return }
        let request = pendingPermissionRequests.remove(at: index)
        request.timeoutWork.cancel()
        request.completion(granted)
        if answeredByUser, !request.isPrivate {
            context.sitePermissionStore.upsert(origin: request.origin, type: request.type, granted: granted)
            bridgeRouter.sendSitePermissionsLoaded(from: context.sitePermissionStore)
        } else if !answeredByUser {
            // Tab close or timeout: retract the prompt, nothing can answer it now.
            bridgeRouter.send(event: "permissionRequestClosed", data: ["requestId": id.uuidString])
        }
    }

    func openExternalURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" || scheme == "file" else { return }
        let destination = didCompleteSessionRestore
            ? context.settingsStore.externalLinkDestination(for: url) { [context] in context.spaceManager?.space(with: $0) != nil }
            : .currentSpace
        if destination == .littleWindow {
            openLittleWindow(url: url)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard didCompleteSessionRestore else {
            pendingExternalURLs.append(url)
            return
        }
        if case .space(let spaceId) = destination, spaceId != tabManager.currentSpaceId { switchToSpace(spaceId) }
        bridgeRouter.send(event: "closeCommandBarAfterNavigation")
        if tabManager.activeTab?.url == nil, let engine = tabManager.activeEngineTab {
            engine.loadURL(url)
            return
        }
        createTabStateFirst(url: url)
    }

    func flushPendingExternalURLs() {
        guard didCompleteSessionRestore, !pendingExternalURLs.isEmpty else { return }
        let urls = pendingExternalURLs
        pendingExternalURLs.removeAll()
        urls.forEach { openExternalURL($0) }
    }
}
