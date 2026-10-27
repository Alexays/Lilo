// Space create, delete, move and switch, and the space delegate.

import AppKit
import GRDB
import os
import WebKit

// MARK: - Spaces

extension MainWindowController {
    func moveSpaceToProfile(
        id spaceId: UUID,
        targetProfileId: UUID,
        name: String?,
        icon: String?,
        color: String?
    ) async throws {
        guard let spaceManager = context.spaceManager,
              let sourceSpace = spaceManager.space(with: spaceId) else { return }

        if sourceSpace.profileId == targetProfileId {
            try spaceManager.updateSpace(id: spaceId) { space in
                if let name { space.name = name }
                if let icon { space.icon = icon }
                if let color { space.color = color }
            }
            return
        }

        // Moving a private space to another profile would turn it into a persistent one and write
        // its tabs to the target profile's database.
        guard !sourceSpace.isPrivate else {
            bridgeRouter.send(event: "spaceUpdated", data: sourceSpace.bridgeData)
            return
        }

        let sourceProfileId = sourceSpace.profileId
        let wasCurrentSpace = tabManager.currentSpaceId == spaceId
        let currentActiveTabId = tabManager.activeOpenTabId
        var state = try captureSpaceTabState(for: sourceSpace)
        let sourceSpaceTab = SpaceTab(spaceId: spaceId, state: state)
        if let currentActiveTabId,
           sourceSpaceTab.tab(id: currentActiveTabId)?.isClosed == false {
            state.activeTabId = currentActiveTabId
        }
        // Persist into the target profile BEFORE any source-side removal: if this write fails the
        // space is untouched (still in the source, in memory and on disk), so nothing is lost.
        do {
            try context.sessionPersistenceCoordinator.persistSpaceTabState(state, spaceId: spaceId, inProfile: targetProfileId)
        } catch {
            Self.logger.error("move space \(spaceId.uuidString, privacy: .public) to profile \(targetProfileId.uuidString, privacy: .public) failed to persist: \(error.localizedDescription, privacy: .public)")
            // Resync the chrome so any optimistic move in the UI snaps back to the source profile.
            bridgeRouter.send(event: "spaceUpdated", data: sourceSpace.bridgeData)
            throw error
        }
        context.browserState.removeSpace(id: spaceId, discardEngine: context.discardEngine, discardTabAdapter: context.discardTabAdapter)
        context.profileContexts.existingContext(for: sourceProfileId)?.extensions.notifySpaceRemoved(spaceId)
        // The move is already durable target-side; a failed source-row cleanup only leaves a stale
        // row behind, so it must not abort the move.
        loggingPersistenceError("spaceTabStates.moveCleanup[\(spaceId.uuidString)]") {
            try context.sessionPersistenceCoordinator.deleteSpaceTabState(forSpace: spaceId, inProfile: sourceProfileId)
        }

        try spaceManager.updateSpace(id: spaceId) { space in
            space.profileId = targetProfileId
            if let name { space.name = name }
            if let icon { space.icon = icon }
            if let color { space.color = color }
        }

        if wasCurrentSpace,
           let movedSpace = spaceManager.space(with: spaceId) {
            try activateProfileContext(for: movedSpace)
            let restoredTabs = state.projectedSidebar(spaceId: spaceId).tabs
            let restoredActiveTabId = restorableActiveTabId(
                preferred: currentActiveTabId ?? movedSpace.activeTabId,
                in: restoredTabs
            )
            tabManager.restoreVisibleRuntime(restoredTabs, activeTabId: restoredActiveTabId)
            tabManager.applyDurableProjectionToRuntime(state, spaceId: spaceId)
            context.browserState.retainLiveHost(tabManager.engineHost, for: spaceId)
            clearContentViewIfNoActiveTab()
            saveSpaceSelection(movedSpace)
            syncActiveBrowserState()
            emitSpaceBrowserChange(spaceId: spaceId, profileId: targetProfileId)
        }
        // Every other window showing the space was left with its torn-down runtime: it enters it again
        // under the new profile, adopting this window's runtime when there is one.
        for window in context.windows.windows(showing: spaceId) where window !== self {
            window.tabManager.detachSharedRuntime()
            window.tabManager.currentSpaceId = nil
            window.updateDisplayedTabs([])
            window.switchToSpace(spaceId)
        }
    }

    func createSpace(
        name: String,
        icon: String,
        color: String,
        colorMode: String = Space.fixedColorMode,
        isPrivate: Bool,
        targetProfileId: UUID?
    ) throws {
        let profileId = targetProfileId
            ?? context.profileManager.activeProfileId
            ?? context.profileManager.defaultProfile?.id
            ?? context.profileManager.profiles.first?.id

        guard let profileId, let spaceManager = context.spaceManager else { return }

        func trimmed(_ s: String, fallback: String) -> String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? fallback : t
        }
        let resolvedName = trimmed(name, fallback: "New Space")
        let resolvedIcon = trimmed(icon, fallback: "🌐")
        let resolvedColor = trimmed(color, fallback: "#5865f2")

        let newSpace = try spaceManager.createSpace(
            name: resolvedName,
            icon: resolvedIcon,
            color: resolvedColor,
            colorMode: colorMode,
            profileId: profileId,
            isPrivate: isPrivate
        )

        switchToSpace(newSpace.id)
    }

    func deleteSpace(id: UUID) throws {
        guard let spaceManager = context.spaceManager,
              let space = spaceManager.space(with: id) else { return }
        // The window has no empty state, so the last space is never deleted.
        guard spaceManager.spaces.count > 1 else {
            Self.logger.warning("refused to delete the last space \(id.uuidString, privacy: .public)")
            return
        }

        let sourceProfileId = space.profileId
        context.browserState.removeSpace(id: id, discardEngine: context.discardEngine, discardTabAdapter: context.discardTabAdapter)
        context.profileContexts.existingContext(for: sourceProfileId)?.extensions.notifySpaceRemoved(id)
        tabManager.terminalHost.prune { tabId in tabManager.tab(for: tabId).map { !$0.isClosed } ?? false }
        tabManager.changesHost.prune { tabId in tabManager.tab(for: tabId).map { !$0.isClosed } ?? false }
        try context.sessionPersistenceCoordinator.deleteSpaceTabState(forSpace: id, inProfile: sourceProfileId)
        try spaceManager.deleteSpace(id: id)
        InteractionStateCodec.archives.withLockUnchecked { $0[id] = nil }
        // A write queued before the delete would archive the space again: clear once more behind it.
        (try? context.dbManager?.pool(for: sourceProfileId))?.asyncWriteWithoutTransaction { _ in
            InteractionStateCodec.archives.withLockUnchecked { $0[id] = nil }
        }
    }

    func requestSpaceSwitch(id: UUID, transitionId: String? = nil) {
        StartupMetrics.trace(
            "swipe-native",
            "stage=requestSpaceSwitch target=\(id.uuidString) transition=\(transitionId ?? "") current=\(context.spaceManager?.activeSpaceId?.uuidString ?? "")"
        )

        // Targets this window: every other window keeps the space it shows.
        switchToSpace(id, transitionId: transitionId)
    }

    func canCarryTabEngineBetweenSpaces(from sourceSpace: Space, to targetSpace: Space) -> Bool {
        !sourceSpace.isPrivate && !targetSpace.isPrivate && sourceSpace.profileId == targetSpace.profileId
    }

    /// Decides what happens to a detached tab's engine when it crosses spaces: carry it when the
    /// spaces share a (non-private) profile, otherwise discard the engine and keep its interaction state.
    private func resolveTabTransfer(
        engine detachedEngine: WKWebViewTab?,
        from sourceSpace: Space,
        to targetSpace: Space
    ) -> (engine: WKWebViewTab?, interactionState: Any?) {
        if canCarryTabEngineBetweenSpaces(from: sourceSpace, to: targetSpace) {
            return (detachedEngine, nil)
        } else if let engine = detachedEngine {
            return (nil, context.discardEngine(engine))
        } else {
            return (nil, nil)
        }
    }

    func moveToSpace(_ kind: TabTreeItem.Kind, id: UUID, targetSpaceId: UUID) throws {
        guard let spaceManager = context.spaceManager,
              let sourceSpaceId = tabManager.currentSpaceId,
              let sourceSpace = spaceManager.space(with: sourceSpaceId),
              let targetSpace = spaceManager.space(with: targetSpaceId) else {
            return
        }

        guard sourceSpaceId != targetSpaceId else { return }

        if context.browserState.space(id: targetSpaceId) == nil {
            context.browserState.storeSpace(
                id: targetSpaceId,
                snapshot: restoredSpaceSnapshot(for: targetSpace)
            )
        }

        syncActiveBrowserState()
        let tabIds: [UUID]
        switch kind {
        case .tab:
            tabIds = [id]
        case .folder:
            guard let sourceSnapshot = context.browserState.space(id: sourceSpaceId),
                  sourceSnapshot.spaceTab.folder(id: id) != nil else {
                return
            }
            tabIds = sourceSnapshot.spaceTab.tabIds(inFolder: id)
        }

        // A tab keeps its extension identity into a space of its profile and privacy that is already a window to extensions,
        // and moves there (tabs.onDetached and onAttached); otherwise it closes, and opens again once that space is shown.
        let registry = tabManager.extensionRegistry
        let sourceWindow = tabManager.windowAdapter
        let targetWindow = sourceSpace.profileId == targetSpace.profileId && sourceSpace.isPrivate == targetSpace.isPrivate
            ? registry?.windowAdapters.first { $0.spaceId == targetSpaceId } : nil
        var transfers: [UUID: (engine: WKWebViewTab?, interactionState: Any?, restoringStartedAt: Date?, adapter: TabExtensionAdapter?, index: Int)] = [:]
        for tabId in tabIds {
            let restoringStartedAt = context.browserState.space(id: sourceSpaceId)?.restoringTabIds[tabId]
            let index = tabManager.tabAdapter(for: tabId).flatMap { sourceWindow?.index(of: $0) } ?? 0
            guard let detached = tabManager.detachTabForTransfer(id: tabId) else {
                // A folder still moves its other tabs; a lone tab that cannot detach moves nothing.
                if kind == .tab { return }
                continue
            }
            let adapter = tabManager.engineHost.removeTabAdapter(for: tabId)
            if targetWindow == nil, let adapter { registry?.controller.didCloseTab(adapter, windowIsClosing: false) }
            let transfer = resolveTabTransfer(engine: detached.engine, from: sourceSpace, to: targetSpace)
            // Only a carried engine keeps its runtime state; a discarded one's is stale.
            if transfer.engine == nil { tabManager.runtimeOverlay.discardRuntimeState(for: tabId) }
            transfers[tabId] = (
                engine: transfer.engine,
                interactionState: transfer.interactionState,
                restoringStartedAt: transfer.engine == nil ? nil : restoringStartedAt,
                adapter: targetWindow == nil ? nil : adapter,
                index: index
            )
        }

        let allowsPinnedTabs = !targetSpace.isPrivate
        let changes = try context.browserState.mutate(kind == .tab
            ? .moveTabToSpace(tabId: id, sourceSpaceId: sourceSpaceId, targetSpaceId: targetSpaceId, allowsPinnedTabs: allowsPinnedTabs)
            : .moveFolderToSpace(folderId: id, sourceSpaceId: sourceSpaceId, targetSpaceId: targetSpaceId, allowsPinnedTabs: allowsPinnedTabs))
        for (tabId, transfer) in transfers {
            context.browserState.transferTabRuntime(
                tabId: tabId,
                sourceSpaceId: sourceSpaceId,
                targetSpaceId: targetSpaceId,
                engine: transfer.engine,
                interactionState: transfer.interactionState,
                restoringStartedAt: transfer.restoringStartedAt,
                tabAdapter: transfer.adapter
            )
        }
        if let targetWindow, let sourceWindow {
            for (tabId, transfer) in transfers {
                guard let adapter = transfer.adapter else { continue }
                adapter.engineTab = transfer.engine
                adapter.extensionWindow = targetWindow
                targetWindow.add(tab: adapter)
                // A space another window shows looks its tabs up in that window's runtime.
                context.browserState.liveHost(for: targetSpaceId)?.setTabAdapter(adapter, for: tabId)
                registry?.controller.didMoveTab(adapter, from: transfer.index, in: sourceWindow)
            }
        }

        browserRuntimeCoordinator.applyRuntimeProjection(from: changes, currentSpaceOnly: true)
        emitBrowserChange(changes)
        context.agentControl.refreshControlledTabs()

        guard let sourceState = changes.states.first(where: { $0.spaceId == sourceSpaceId }),
              let targetState = changes.states.first(where: { $0.spaceId == targetSpaceId }) else {
            return
        }

        // Private space states never touch disk; a move between a private and a normal space only
        // persists the normal side.
        if sourceSpace.isPrivate || targetSpace.isPrivate {
            if !sourceSpace.isPrivate {
                try context.sessionPersistenceCoordinator.persistSpaceTabState(sourceState.state, spaceId: sourceSpaceId, inProfile: sourceSpace.profileId)
            }
            if !targetSpace.isPrivate {
                try context.sessionPersistenceCoordinator.persistSpaceTabState(targetState.state, spaceId: targetSpaceId, inProfile: targetSpace.profileId)
            }
        } else {
            try context.sessionPersistenceCoordinator.persistMovedSpaceTabStates(
                sourceState,
                sourceProfileId: sourceSpace.profileId,
                targetState,
                targetProfileId: targetSpace.profileId
            )
        }

        spaceManager.setActiveTab(sourceState.state.activeTabId, forSpace: sourceSpaceId)
        spaceManager.setActiveTab(targetState.state.activeTabId, forSpace: targetSpaceId)

        clearContentViewIfNoActiveTab()
    }
}

// MARK: - Space and profile changes

// Relayed by the window registry, which is the single SpaceManager and ProfileManager delegate.
extension MainWindowController {
    func spaceWasCreated(_ space: Space) {
        bridgeRouter?.send(event: "spaceCreated", data: space.bridgeData)
    }

    /// Leaves a deleted space this window shows; its tabs are gone, so nothing is parked.
    func spaceWasDeleted(_ space: Space, by manager: SpaceManager) {
        if tabManager.currentSpaceId == space.id {
            for tab in tabManager.discardRuntime(inSpace: space.id) { denyPermissionRequests(forTab: tab.id) }
            tabManager.detachSharedRuntime()
            tabManager.currentSpaceId = nil
            updateDisplayedTabs([])
        }
        bridgeRouter?.send(event: "spaceDeleted", data: ["id": space.id.uuidString, "activeSpaceId": tabManager.currentSpaceId?.uuidString ?? "", "spaces": manager.spaces.map(\.bridgeData)])
    }

    func spaceWasUpdated(_ space: Space) {
        bridgeRouter?.send(event: "spaceUpdated", data: space.bridgeData)
    }

    func spacesWereReordered(_ spaces: [Space]) {
        bridgeRouter?.send(event: "spacesReordered", data: ["spaces": spaces.map(\.bridgeData)])
    }

    /// Takes this window off `oldSpaceId`: the last window to leave parks its runtime into the store,
    /// any other one only lets go of it.
    func leaveSpace(_ oldSpaceId: UUID, previousActiveTabId: UUID?, nextSpaceId: UUID?) {
        guard let spaceManager = context.spaceManager else { return }
        activeTabBySpace[oldSpaceId] = previousActiveTabId
        if !context.browserState.releaseLiveHost(for: oldSpaceId) {
            // Another window still shows the leaving space: its runtime stays live there, and the
            // page events and extension tabs this window held go to that window.
            // The engine maps alone: materializing the space's tabs would be wasted here.
            let runtime = tabManager.engineHost.snapshot(tabs: [], activeTabId: nil)
            let heir = context.windows.windows(showing: oldSpaceId).first { $0 !== self }
            for engine in runtime.engines.values {
                if engine.view.isDescendant(of: contentContainerView) { engine.view.removeFromSuperview() }
                if let heir, engine.delegate === self {
                    engine.delegate = heir
                    engine.tabManager = heir.tabManager
                }
            }
            // The space stays one window to extensions, now the heir's.
            if let heir, let spaceWindow = tabManager.windowAdapter, spaceWindow === heir.tabManager.windowAdapter {
                spaceWindow.nsWindow = heir.window
                spaceWindow.tabManager = heir.tabManager
                for adapter in runtime.tabAdapters.values { adapter.tabManager = heir.tabManager }
            }
            updateDisplayedTabs([])
            tabManager.detachSharedRuntime()
        } else {
            // Resolved before parking (which empties the live runtime), popped out after it (which
            // detaches every engine view, panel included). A space switch never reaches the
            // tab-switch path, since a parked engine is no longer in the content view.
            let leavingEngine = previousActiveTabId.flatMap { tabManager.engineTab(for: $0) }
            let inactiveTreeItems = tabManager.sidebarTreeItems(forSpace: oldSpaceId)
            let inactiveRuntime = tabManager.parkCurrentSpaceRuntimeForSwitch()
            if let leavingEngine { popOutBackgroundedTab(leavingEngine) }
            // A closing window hands its parked engines to a live one: WebKit callbacks (permission
            // decisions) must not reach a released delegate before the space is shown again.
            if nextSpaceId == nil, let heir = context.windows.windows.first(where: { $0 !== self }) {
                for engine in inactiveRuntime.engines.values where engine.delegate === self {
                    engine.delegate = heir
                    engine.tabManager = heir.tabManager
                }
            }
            // Parking detached every engine view of the old space: re-adopt the ones that live
            // outside the content container (docked call, tab-share source) so they keep rendering.
            tabDock.reattachIfNeeded()
            reattachSharedTabViewIfNeeded()
            let inactiveFolders = tabManager.folders(forSpace: oldSpaceId)
            context.browserState.cacheInactiveSpaceRuntime(
                id: oldSpaceId,
                runtime: inactiveRuntime,
                folders: inactiveFolders,
                treeItems: inactiveTreeItems
            )
            context.hiddenSpaceLifecycle.scheduleTrim(excluding: nextSpaceId)
            spaceManager.setActiveTab(previousActiveTabId, forSpace: oldSpaceId)
            let activeTabId = restorableActiveTabId(preferred: previousActiveTabId, in: inactiveRuntime.tabs)
            let stored = context.browserState.space(id: oldSpaceId)?.spaceTab.state
            let state = SpaceTabStateImporter.importState(
                activeTabId: activeTabId,
                activationHistory: stored?.activationHistory ?? [],
                viewedAt: stored?.viewedAt ?? [:],
                tabs: inactiveRuntime.tabs,
                folders: inactiveFolders,
                treeItems: inactiveTreeItems,
                spaceId: oldSpaceId
            )
            // Private spaces leave no trace on disk.
            if context.spaceManager?.space(with: oldSpaceId)?.isPrivate != true {
                profileContext?.sessionPersistence?.saveSpaceTabStateAsync(state, spaceId: oldSpaceId) { [weak self] activeTabId, spaceId in
                    self?.context.spaceManager?.setActiveTab(activeTabId, forSpace: spaceId)
                }
            }
        }
    }

    /// `forSessionRestore` suppresses the ready event, selection/session persistence, and the
    /// profile-context reconfiguration the restore path already performed. It also postpones window
    /// chrome colors and restored-tab activation until the chrome has navigated.
    func switchToSpace(
        _ spaceId: UUID,
        transitionId: String? = nil,
        forSessionRestore: Bool = false
    ) {
        guard let spaceManager = context.spaceManager,
              let targetSpace = spaceManager.space(with: spaceId) else { return }

        let switchStart = DispatchTime.now().uptimeNanoseconds
        let signpost = PerfSignposts.energy.beginInterval("switchToSpace")
        defer {
            StartupMetrics.recordDurationSample("switchToSpace", startUptime: switchStart)
            PerfSignposts.energy.endInterval("switchToSpace", signpost)
        }

        isPerformingSpaceSwitch = true
        defer {
            isPerformingSpaceSwitch = false
        }

        let previousSpaceId = tabManager.currentSpaceId
        let previousActiveTabId = tabManager.activeOpenTabId

        // Capture the leaving space's interaction states while its runtime is still live (we can only
        // read live engine state for the current space). The relaunch / re-entry path restores them.
        if let previousSpaceId, previousSpaceId != spaceId {
            persistInteractionStates(forSpace: previousSpaceId, debounced: true)
        }

        StartupMetrics.trace("swipe-native",
            "stage=switchToSpaceStart target=\(spaceId.uuidString) transition=\(transitionId ?? "") previous=\(previousSpaceId?.uuidString ?? "") previousActiveTab=\(previousActiveTabId?.uuidString ?? "")")

        // Resolved before parking: a profile that cannot load leaves the current space untouched, and
        // activateProfileContext below then finds it cached.
        guard (try? context.poolReportingFailure(for: targetSpace.profileId)) != nil,
              (try? context.profileContexts.context(for: targetSpace.profileId)) != nil else { return }

        if let oldSpaceId = previousSpaceId, oldSpaceId != spaceId {
            leaveSpace(oldSpaceId, previousActiveTabId: previousActiveTabId, nextSpaceId: spaceId)
        }

        // Activated after parking, so the leaving space is saved through its own profile's persistence.
        guard (try? activateProfileContext(for: targetSpace)) != nil else { return }

        spaceManager.activeSpaceId = spaceId
        tabManager.currentSpaceId = spaceId
        recentSpaceIds.removeAll { $0 == spaceId }
        recentSpaceIds.insert(spaceId, at: 0)
        // The frame takes the color the chrome reports for the space it shows: deriving it here too
        // could paint a different one the chrome then never corrects, its report being unchanged.
        if !forSessionRestore { saveSpaceSelection(targetSpace) }

        if previousSpaceId == spaceId, !tabManager.currentTabs.isEmpty {
            // Keep current tabs in memory when only the space metadata changed.
            _ = context.browserState.activateSpace(id: spaceId) { browserSnapshot(for: spaceId) }
            syncActiveBrowserState()
        } else if let sharedHost = context.browserState.liveHost(for: spaceId) {
            tabManager.adoptSharedRuntime(sharedHost, spaceId: spaceId)
            if previousSpaceId != spaceId { context.browserState.retainLiveHost(sharedHost, for: spaceId) }
            let snapshot = context.browserState.activateSpace(id: spaceId) { restoredSpaceSnapshot(for: targetSpace) }
            let preferred = activeTabBySpace[spaceId] ?? snapshot.spaceTab.state.activeTabId
            if let activeId = freeTab(preferring: preferred) ?? restorableActiveTabId(preferred: preferred, in: tabManager.currentTabs) {
                select(activeId, deferringActivation: forSessionRestore)
            }
            clearContentViewIfNoActiveTab()
            syncActiveBrowserState()
        } else {
            let snapshot = context.browserState.activateSpace(id: spaceId) {
                restoredSpaceSnapshot(for: targetSpace)
            }
            let projection = context.browserState.projectedSidebar(from: snapshot)
            // Store snapshots are sanitized at ingest (restoredSpaceSnapshot); cached ones only
            // ever round-trip the in-memory store, so activation trusts them as-is.
            let restoredTabs = projection.tabs
            faviconCoordinator.warm(from: restoredTabs)
            let restoredIds = Set(restoredTabs.map(\.id))
            let restoredEngines = snapshot.engines.filter { restoredIds.contains($0.key) }
            let restoredTabAdapters = snapshot.tabAdapters.filter { restoredIds.contains($0.key) }
            let restoredInteractionStates = snapshot.interactionStates.filter { restoredIds.contains($0.key) }
            let activeId = restorableActiveTabId(
                preferred: activeTabBySpace[spaceId] ?? snapshot.spaceTab.state.activeTabId ?? targetSpace.activeTabId,
                in: restoredTabs
            )
            let restoredState = SpaceTabStateImporter.importState(
                activeTabId: activeId,
                activationHistory: snapshot.spaceTab.state.activationHistory,
                viewedAt: snapshot.spaceTab.state.viewedAt,
                tabs: restoredTabs,
                folders: projection.folders,
                treeItems: projection.treeItems,
                spaceId: spaceId
            )

            if restoredTabs.isEmpty {
                tabManager.restoreVisibleRuntime([], engines: [:], activeTabId: nil)
            } else {
                tabManager.restoreVisibleRuntime(
                    restoredTabs,
                    engines: restoredEngines,
                    tabAdapters: restoredTabAdapters,
                    savedInteractionStates: restoredInteractionStates,
                    restoringTabIds: snapshot.restoringTabIds.filter { restoredEngines[$0.key] != nil },
                    activeTabId: activeId,
                    activateRestoredTab: !forSessionRestore
                )
            }
            tabManager.applyDurableProjectionToRuntime(restoredState, spaceId: spaceId)
            if previousSpaceId != spaceId { context.browserState.retainLiveHost(tabManager.engineHost, for: spaceId) }
            // Parked engines may still point at the window that parked them, closed since.
            for engine in restoredEngines.values {
                engine.delegate = self
                engine.tabManager = tabManager
            }
            clearContentViewIfNoActiveTab()
            syncActiveBrowserState()
        }

        if !forSessionRestore {
            emitSpaceBrowserChange(spaceId: spaceId, transitionId: transitionId, profileId: targetSpace.profileId)

            StartupMetrics.trace("swipe-native",
                "stage=browserStateChangedSent id=\(spaceId.uuidString) transition=\(transitionId ?? "") tabs=\(tabManager.currentTabs.count) activeTab=\(tabManager.activeOpenTabId?.uuidString ?? "")")

            profileContext?.sessionPersistence?.scheduleSave()
            context.scheduleWindowsSave()
            // Tabs left idle while their Space was away go once it is on screen.
            DispatchQueue.main.async { [weak context] in context?.archiveIdleTabs() }
        }
    }
}
