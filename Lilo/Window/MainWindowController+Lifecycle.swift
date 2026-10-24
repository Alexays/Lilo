import AppKit

// App-lifecycle engine-trim policy around the HiddenSpaceLifecycleController collaborator.
extension MainWindowController {
    /// The only place `.background` collapses the active space to one engine (occluded window, critical pressure); `.foreground` keeps
    /// the RAM-adaptive budget, optionally capped (soft pressure, constrained power).
    func activeSpaceTrimBudget(policy: TabLifecycleCoordinator.Policy, cap: Int?) -> Int {
        switch policy {
        case .background: return 1
        case .foreground: return min(adaptiveForegroundEngineBudget, cap ?? .max)
        }
    }

    /// Closing a folder means the user is done with what is inside it, so its tabs release their
    /// engines now rather than idling out minutes later.
    func discardCollapsedFolderEngines(after command: BrowserCommand) {
        let collapsed: (spaceId: UUID, folderId: UUID)?
        switch command {
        case let .setFolderCollapsed(spaceId, folderId, isCollapsed):
            collapsed = isCollapsed ? (spaceId, folderId) : nil
        case let .updateFolder(spaceId, folderId, _, _, isCollapsed):
            collapsed = isCollapsed ? (spaceId, folderId) : nil
        default:
            collapsed = nil
        }
        guard let collapsed,
              tabManager.discardEngines(inFolder: collapsed.folderId, spaceId: collapsed.spaceId) else { return }
        // Flush stashed interaction state so a crash after a discard doesn't lose scroll/form state.
        persistInteractionStates(forSpace: collapsed.spaceId)
    }

    /// Trims this window's space to the engine budget of `policy`; the shared lifecycle controller
    /// asks every window in turn.
    func trimActiveSpace(policy: TabLifecycleCoordinator.Policy, cap: Int?) {
        let budget = activeSpaceTrimBudget(policy: policy, cap: cap)
        guard tabManager.trimActiveSpaceEngines(maxLiveEngines: budget, discardThreshold: context.lifecycleConfig.discardThreshold) else { return }
        // The store's runtime maps still hold the discarded engines, and with them their web
        // views and content processes, until the next sync; under memory pressure that
        // could be the next tab switch.
        syncActiveBrowserState()
        // Flush stashed interaction state so a crash after a discard doesn't lose scroll/form state.
        if let spaceId = tabManager.currentSpaceId { persistInteractionStates(forSpace: spaceId) }
    }

    /// The bridge is nil when the initial application (or a power-state change that races startup)
    /// fires before `setupBridgeEarly()` creates it; the optional send keeps that path crash-safe.
    func sendPowerMode(_ constrained: Bool) {
        bridgeRouter?.send(event: "powerModeChanged", data: ["constrained": constrained])
    }

    /// System Settings > Accessibility > Display > Reduce transparency: the chrome drops backdrop blur.
    func sendReduceTransparency() {
        bridgeRouter?.send(event: "reduceTransparencyChanged",
                           data: ["reduce": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency])
    }

    /// The keys of every action, so the chrome's tooltips and command bar show the ones that work.
    func sendShortcutKeys() {
        bridgeRouter?.send(event: "shortcutKeys", data: ["keys": KeyboardShortcuts.displayedKeys])
    }
}

// MARK: - Handoff

extension MainWindowController {
    /// Publishes the active tab to the system: the window title (Window menu, Mission Control, Dock,
    /// VoiceOver; the title bar keeps it hidden) and the Handoff activity, never for private spaces.
    func publishActiveTab() {
        let isPrivate = context.spaceManager?.space(with: tabManager.currentSpaceId)?.isPrivate ?? false
        let tabTitle = isPrivate ? "" : tabManager.visibleActiveTab?.title ?? ""
        let activeTitle = tabTitle == Tab.placeholderTitle ? tabTitle.localized : tabTitle
        let title = activeTitle.isEmpty ? "Lilo" : activeTitle
        if window?.title != title { window?.title = title }
        if let browsingActivity, browsingActivity.title != activeTitle { browsingActivity.title = activeTitle }
        let url = tabManager.visibleActiveTab?.url
        let scheme = url?.scheme?.lowercased()
        let publishable = (!isPrivate && (scheme == "http" || scheme == "https")) ? url : nil
        guard publishable != handoffURL else { return }
        handoffURL = publishable
        if let publishable {
            let activity = browsingActivity ?? NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
            activity.webpageURL = publishable
            activity.title = activeTitle
            activity.becomeCurrent()
            browsingActivity = activity
        } else {
            browsingActivity?.invalidate()
            browsingActivity = nil
        }
    }
}
