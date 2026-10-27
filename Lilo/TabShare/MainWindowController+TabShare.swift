import AppKit
import WebKit

// getDisplayMedia tab sharing: the page shim asks for a pick, the chrome UI presents the tab
// picker, and a "tab" choice starts the frame ferry (TabShareSessionController).
extension MainWindowController {

    /// Wires this window's share session; the shared bridge routes each request to the window
    /// holding the requesting page (`BrowserContext.installTabShareRouting`).
    func setupTabShare() {
        tabShareSessions.hasParkedPull = { [weak self] token in
            self?.context.engineFactory.tabShareFrameSchemeHandler.hasWaiter(token: token) ?? false
        }
        tabShareSessions.onFrameStored = { [weak self] in
            self?.context.engineFactory.tabShareFrameSchemeHandler.flushWaiters()
        }
        tabShareSessions.onSessionEnded = { [weak self] token, engineId in
            guard let self else { return }
            context.engineFactory.captureHandler.sessionEnded(token: token)
            guard let engineId else { return }
            let engine = tabManager.engineTab(for: engineId) ?? context.browserState.liveEngine(forTab: engineId)
            // Detach a share-retained background view; the visible tab keeps its view, and a tab
            // still in a real call (hasActiveCapture with the share flag already cleared) keeps
            // rendering for its own capture machinery.
            guard let engine, !engine.hasActiveCapture,
                  engine.view.superview === contentContainerView,
                  tabManager.activeOpenTabId != engineId else { return }
            engine.view.removeFromSuperview()
        }
    }

    func startTabShare(tabId: UUID, requester: WKWebView) -> [String: Any]? {
        guard let engine = liveEngineForSharing(tabId: tabId) else { return nil }
        // A backgrounded tab's view is detached and stops rendering: re-attach it below the
        // active view at full content size so it lays out and renders like a visible tab.
        if engine.view.window == nil { attachBelowContent(engine) }
        return tabShareSessions.start(engine: engine, requester: requester)
    }

    /// Re-attaches the shared tab's view under the active view after a space switch: parking
    /// detaches every engine view of the leaving space, share-retained ones included.
    func reattachSharedTabViewIfNeeded() {
        for engine in tabShareSessions.sharedEngines where engine.view.window == nil { attachBelowContent(engine) }
    }

    private func attachBelowContent(_ engine: WKWebViewTab) {
        engine.view.frame = contentContainerView.bounds
        engine.view.autoresizingMask = [.width, .height]
        engine.view.isHidden = false
        contentContainerView.addSubview(engine.view, positioned: .below, relativeTo: nil)
    }

    /// The picker lists tabs of every hydrated space, so resolution must reach beyond the current
    /// space: the TabManager path also revives a discarded current-space engine; a hidden-space tab
    /// is shareable when its parked engine is still live (the floating panel keeps it rendering).
    private func liveEngineForSharing(tabId: UUID) -> WKWebViewTab? {
        if let engine = tabManager.ensureLiveEngine(forTabId: tabId) { return engine }
        guard let engine = context.browserState.liveEngine(forTab: tabId) else { return nil }
        engine.resume()
        return engine
    }

    /// One row of the picker's grid.
    static let suggestedShareTabCount = 4

    /// Cancelling the calling task takes the picker off screen and returns `.cancel`.
    func presentTabSharePicker(origin: String, requester: WKWebView?, allowsSystem: Bool = true, wantsAudio: Bool = false) async -> TabSharePickerChoice {
        let requestId = UUID().uuidString
        // Only tabs `liveEngineForSharing` can resolve: every current-space tab (revived on pick)
        // and the hidden-space tabs whose parked engine is still live.
        // The requesting tab is left out: sharing a call's own tab shows the call back to itself.
        let requesterTabId = requester.flatMap { context.windows.windowAndEngine(for: $0)?.engine.id }
        let shareableTabIds = Set(tabManager.openTabs.map(\.id)).union(context.browserState.parkedEngineTabIds)
            .filter { id in
                id != requesterTabId
                    && context.browserState.durableTab(for: id).map { tabManager.protectingFolder(of: $0.tab)?.isLocked != true } ?? true
            }
        // Tabs playing sound first, then the most recently shown: what a call usually goes on to share.
        let suggestedTabIds = shareableTabIds.compactMap { tabManager.tab(for: $0) }
            .sorted { ($0.isAudioPlaying ? 1 : 0, $0.lastActiveAt ?? .distantPast) > ($1.isAudioPlaying ? 1 : 0, $1.lastActiveAt ?? .distantPast) }
            .prefix(Self.suggestedShareTabCount)
            .map(\.id.uuidString)
        var data: [String: Any] = [
            "requestId": requestId,
            "origin": origin,
            "shareableTabIds": shareableTabIds.map(\.uuidString),
            "suggestedTabIds": suggestedTabIds,
            "allowsSystem": allowsSystem
        ]
        if wantsAudio {
            // Screen sound must leave out Lilo's GPU process, which plays every page and so the call itself.
            let excludable = requester.map { WebViewPrivateAccessors($0).pid("_gpuProcessIdentifier") != nil } ?? false
            data["audio"] = [
                "system": excludable ? SystemAudioAccess.current.rawValue : "unsupported",
                "systemOn": context.settingsStore.get(Self.systemAudioSetting) != "false"
            ]
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingTabSharePickerRequests[requestId] = (requester, wantsAudio, continuation)
                bridgeRouter.send(event: "tabSharePickerRequested", data: data)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.dismissTabSharePicker(requestId: requestId) }
        }
    }

    private func dismissTabSharePicker(requestId: String) {
        guard let pending = pendingTabSharePickerRequests.removeValue(forKey: requestId) else { return }
        pending.continuation.resume(returning: .cancel)
        bridgeRouter.send(event: "tabSharePickerDismissed", data: ["requestId": requestId])
    }

    static let systemAudioSetting = "tabShareSystemAudio"

    /// Remembers the screen sound toggle for the next share.
    func resolveTabSharePicker(requestId: String, choice: TabSharePickerChoice) {
        guard let pending = pendingTabSharePickerRequests.removeValue(forKey: requestId) else { return }
        if pending.wantsAudio, case .system(let audio) = choice {
            context.settingsStore.set(Self.systemAudioSetting, value: String(audio))
        }
        pending.continuation.resume(returning: choice)
    }

    /// Cancels the picks a closing tab is waiting on and takes their picker off screen.
    func cancelTabSharePickers(requestedBy view: NSView) {
        for (requestId, pending) in pendingTabSharePickerRequests where pending.requester === view {
            dismissTabSharePicker(requestId: requestId)
        }
    }

    /// Ends the ferry and unblocks every pending pick; the shim promises must never outlive the window.
    func teardownTabShare() {
        tabShareSessions.stopAll()
        let pending = pendingTabSharePickerRequests
        pendingTabSharePickerRequests.removeAll()
        pending.values.forEach { $0.continuation.resume(returning: .cancel) }
    }
}
