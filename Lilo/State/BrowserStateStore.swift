import Foundation
import OSLog
import WebKit

@MainActor
final class BrowserStateStore {
    private static let logger = Logger(liloCategory: "lifecycle")

    @MainActor
    struct SpaceSnapshot {
        var spaceTab: SpaceTab
        var engines: [UUID: WKWebViewTab]
        var tabAdapters: [UUID: TabExtensionAdapter] = [:]
        var interactionStates: [UUID: Any] = [:]
        /// When `applyEngineDiscard` stashed each blob; bounds `interactionStates` oldest-first.
        var interactionStateStashedAt: [UUID: Date] = [:]
        var restoringTabIds: [UUID: Date] = [:]
        var lastAccessedAt: Date = Date()

        /// Per-tab lifecycle classification (active/loadedHidden/frozen/restoring/discarded) for this
        /// space's projected `tabs`. Shared prelude used by both the lifecycle-diagnostics and the
        /// process-snapshot builders, which each fold the result differently.
        func lifecycleByTabId(
            spaceId: UUID,
            visibleSpaceIds: Set<UUID>,
            tabs: [Tab]
        ) -> [UUID: TabLifecycleCoordinator.LifecycleState] {
            let lifecycleActiveTabId = visibleSpaceIds.contains(spaceId) ? spaceTab.state.activeTabId : nil
            // lifecycleStates is a pure classification projection: it reads none of the coordinator's
            // preset-derived fields, so the preset is irrelevant here. .default names LifecyclePolicyConfig
            // as the source of truth instead of relying on the struct's own literal defaults.
            return TabLifecycleCoordinator(config: .default).lifecycleStates(
                tabs: tabs,
                availableEngineIds: Set(engines.keys),
                activeTabId: lifecycleActiveTabId,
                restoringTabIds: restoringTabIds,
                frozenTabIds: Set(engines.filter { $0.value.isFrozen }.map(\.key))
            )
        }
    }

    private var spaces: [UUID: SpaceSnapshot] = [:]
    /// Spaces some window shows. Their runtime is live, so hidden-space trims never touch them.
    private(set) var visibleSpaceIds: Set<UUID> = []
    /// Tabs on screen in some window, maintained by the window registry: never frozen or discarded.
    var displayedTabIds: Set<UUID> = []
    /// Live runtime of each shown space and how many windows show it; every one of them uses this host.
    private var liveHosts: [UUID: (host: EngineHost, viewers: Int)] = [:]

    func liveHost(for spaceId: UUID) -> EngineHost? { liveHosts[spaceId]?.host }

    func retainLiveHost(_ host: EngineHost, for spaceId: UUID) {
        liveHosts[spaceId] = (host, (liveHosts[spaceId]?.viewers ?? 0) + 1)
    }

    /// True when the last window showing `spaceId` leaves it: that window parks the runtime.
    @discardableResult
    func releaseLiveHost(for spaceId: UUID) -> Bool {
        guard let entry = liveHosts[spaceId] else { return true }
        guard entry.viewers > 1 else {
            liveHosts.removeValue(forKey: spaceId)
            return true
        }
        liveHosts[spaceId] = (entry.host, entry.viewers - 1)
        return false
    }
    /// Same bound as EngineHost's saved-state LRU: a discarded-but-open tab keeps its blob for its
    /// whole life, so a large session would otherwise retain one per tab.
    private static let maxInteractionStatesPerSpace = 50

    /// Single, flat owner of every tab's runtime overlay (keyed by global tab id). Shared by
    /// reference with `TabManager` so runtime state has exactly one home.
    let runtimeOverlay = RuntimeOverlayStore()

    func space(id: UUID) -> SpaceSnapshot? {
        spaces[id]
    }

    func persistableSpaceTabStates() -> [(spaceId: UUID, state: SpaceTabState)] {
        spaces.map { spaceId, snapshot in
            (spaceId: spaceId, state: snapshot.spaceTab.state)
        }
    }

    /// Memoized projections per space, keyed by structureToken, contentRevision (content-only updates keep the token) and overlay version
    /// (runtime ticks change only that), so reads between durable mutations skip the tree walk and Tab-copy pass.
    private struct ProjectionCacheEntry {
        var token: UUID
        var contentRevision: UInt64
        var overlayVersion: UInt64
        var structural: SpaceTabProjection
        var applied: SpaceTabProjection
    }

    private var projectionCache: [UUID: ProjectionCacheEntry] = [:]

    private func cachedProjections(for snapshot: SpaceSnapshot) -> (structural: SpaceTabProjection, applied: SpaceTabProjection) {
        let spaceId = snapshot.spaceTab.spaceId
        let token = snapshot.spaceTab.structureToken
        let contentRevision = snapshot.spaceTab.contentRevision
        let overlayVersion = runtimeOverlay.version
        let structural: SpaceTabProjection
        if let cached = projectionCache[spaceId], cached.token == token, cached.contentRevision == contentRevision {
            if cached.overlayVersion == overlayVersion { return (cached.structural, cached.applied) }
            structural = cached.structural
        } else {
            structural = snapshot.spaceTab.state.projectedSidebar(spaceId: spaceId)
        }
        var applied = structural
        applied.tabs = applied.tabs.map { runtimeOverlay.applied(to: $0) }
        projectionCache[spaceId] = ProjectionCacheEntry(
            token: token,
            contentRevision: contentRevision,
            overlayVersion: overlayVersion,
            structural: structural,
            applied: applied
        )
        return (structural, applied)
    }

    func projectedSidebar(from snapshot: SpaceSnapshot) -> SpaceTabProjection {
        cachedProjections(for: snapshot).applied
    }

    /// Structural projection for a space (no runtime overlay), through the memo cache.
    func structuralProjection(forSpace spaceId: UUID) -> SpaceTabProjection? {
        spaces[spaceId].map { cachedProjections(for: $0).structural }
    }

    func browserSpaceChange(spaceId: UUID) -> BrowserSpaceChange? {
        spaces[spaceId].map { browserSpaceChange(spaceId: spaceId, from: $0) }
    }

    private func browserSpaceChange(
        spaceId: UUID,
        from snapshot: SpaceSnapshot,
        previousProjection: SpaceTabProjection? = nil,
        previousActiveTabId: UUID? = nil
    ) -> BrowserSpaceChange {
        BrowserSpaceChange(
            spaceId: spaceId,
            state: snapshot.spaceTab.state,
            projection: projectedSidebar(from: snapshot),
            previousProjection: previousProjection,
            previousActiveTabId: previousActiveTabId
        )
    }

    func storeSpace(id: UUID, snapshot: SpaceSnapshot) {
        spaces[id] = tokenPreservingNormalizedSnapshot(snapshot, spaceId: id)
    }

    func storeActiveSpace(id: UUID, snapshot: SpaceSnapshot) {
        visibleSpaceIds.insert(id)
        storeSpace(id: id, snapshot: snapshot)
    }

    /// Folds the visible space's live runtime into the store's snapshot: only the active tab and runtime maps can differ, so patching
    /// in place keeps the SpaceTab (token, revisions, index) intact. False when the store does not own the space yet.
    func syncActiveSpaceRuntime(id: UUID, activeTabId: UUID?, runtime: TabRuntimeSnapshot) -> Bool {
        guard var snapshot = spaces[id] else { return false }
        visibleSpaceIds.insert(id)
        let tabIds = snapshot.spaceTab.index.tabIds
        snapshot.engines = runtime.engines.filter { tabIds.contains($0.key) }
        snapshot.tabAdapters = runtime.tabAdapters.filter { tabIds.contains($0.key) }
        snapshot.interactionStates = runtime.savedInteractionStates.filter { tabIds.contains($0.key) }
        snapshot.interactionStateStashedAt = snapshot.interactionStateStashedAt.filter { snapshot.interactionStates[$0.key] != nil }
        snapshot.restoringTabIds = runtime.restoringTabIds.filter { tabIds.contains($0.key) }
        if let activeTabId, activeTabId != snapshot.spaceTab.state.activeTabId,
           snapshot.spaceTab.tab(id: activeTabId)?.isClosed == false {
            snapshot.spaceTab.activateTab(activeTabId)
        }
        snapshot.lastAccessedAt = Date()
        spaces[id] = snapshot
        return true
    }

    /// `normalizedSnapshot`, but if the incoming SpaceTab's state is byte-identical to the one we
    /// already own for this space, keep the existing SpaceTab so its `structureToken` survives, and
    /// with it the projection memo-cache, when a caller re-imports an unchanged state.
    private func tokenPreservingNormalizedSnapshot(_ snapshot: SpaceSnapshot, spaceId: UUID) -> SpaceSnapshot {
        let normalized = normalizedSnapshot(snapshot, spaceId: spaceId)
        guard let existing = spaces[spaceId],
              existing.spaceTab.spaceId == spaceId,
              existing.spaceTab.state == normalized.spaceTab.state else {
            return normalized
        }
        var preserved = normalized
        preserved.spaceTab = existing.spaceTab
        return preserved
    }

    @discardableResult
    func mutate(_ command: BrowserCommand) throws -> BrowserChangeSet {
        // Moving a tab out of a locked folder would reveal it without the password.
        if let (spaceId, tabIds) = Self.tabsMoved(by: command), let spaceTab = spaces[spaceId]?.spaceTab,
           let tabId = tabIds.first(where: { spaceTab.protectingFolder(of: $0)?.isLocked == true }) {
            throw BrowserMutationError.lockedTab(tabId)
        }
        switch command {
        case let .activateTab(spaceId, tabId):
            guard let snapshot = spaces[spaceId] else { throw BrowserMutationError.missingSpace(spaceId) }
            guard let tab = snapshot.spaceTab.tab(id: tabId) else { throw BrowserMutationError.missingTab(tabId) }
            if tab.isClosed {
                guard tab.isPinned || tab.isBookmarked else { throw BrowserMutationError.closedTab(tabId) }
            }
            let result = try mutateSpaceTab(spaceId: spaceId) { session in
                session.activateTab(tabId)
            }
            noteTabActivated(tabId)
            return result
        case let .createTab(spaceId, tab, activate):
            return try mutateSpaceTab(spaceId: spaceId) { session in
                session.createTab(tab, activate: activate)
            }
        case let .closeTab(spaceId, tabId):
            guard let snapshot = spaces[spaceId] else { throw BrowserMutationError.missingSpace(spaceId) }
            let session = snapshot.spaceTab
            guard let tab = session.tab(id: tabId) else { throw BrowserMutationError.missingTab(tabId) }
            guard !tab.isClosed else { throw BrowserMutationError.closedTab(tabId) }
            // Drop the overlay inside the mutation, not after: the change set projects it onto the upserted tab, so a tab closed mid-load
            // would ship `isLoading: true` as its last word, leaving a pinned or bookmarked row's spinner spinning forever.
            runtimeOverlay.removeRuntimeState(for: tabId)
            return try mutateSpaceTab(spaceId: spaceId) { session in
                session.closeTab(tabId)
            }
        case let .setPinned(spaceId, tabId, isPinned):
            return try mutateSpaceTab(spaceId: spaceId) { session in
                guard let tab = session.tab(id: tabId) else { throw BrowserMutationError.missingTab(tabId) }
                guard !tab.isClosed || !isPinned else { return }
                session.setPinned(tabId, pinned: isPinned)
            }
        case let .setBookmarked(spaceId, tabId, isBookmarked):
            return try mutateSpaceTab(spaceId: spaceId) { session in
                guard let tab = session.tab(id: tabId) else { throw BrowserMutationError.missingTab(tabId) }
                guard !tab.isClosed || !isBookmarked else { return }
                session.setBookmarked(tabId, bookmarked: isBookmarked)
            }
        case let .setTabHomeURL(spaceId, tabId, url):
            return try mutateSpaceTab(spaceId: spaceId) { session in
                guard let tab = session.tab(id: tabId) else { throw BrowserMutationError.missingTab(tabId) }
                guard !tab.isClosed else { throw BrowserMutationError.closedTab(tabId) }
                session.setTabHomeURL(tabId, url: url)
            }
        case let .createFolder(spaceId, folder, section, parentFolderId):
            guard section != .bookmarked else { return try unchanged(spaceId: spaceId) }
            if let parentFolderId {
                guard let snapshot = spaces[spaceId] else { throw BrowserMutationError.missingSpace(spaceId) }
                guard snapshot.spaceTab.folder(id: parentFolderId)?.isSplit == false else { return try unchanged(spaceId: spaceId) }
            }
            return try mutateSpaceTab(spaceId: spaceId) { session in
                session.createFolder(folder, section: section, parentFolderId: parentFolderId)
            }
        case let .updateFolder(spaceId, folderId, name, color, isCollapsed):
            return try mutateSpaceTab(spaceId: spaceId) { session in
                guard session.folder(id: folderId) != nil else { throw BrowserMutationError.missingFolder(folderId) }
                session.updateFolder(folderId, name: name, color: color, isCollapsed: isCollapsed)
            }
        case let .setFolderCollapsed(spaceId, folderId, isCollapsed):
            return try mutateSpaceTab(spaceId: spaceId) { session in
                guard session.folder(id: folderId) != nil else { throw BrowserMutationError.missingFolder(folderId) }
                session.setFolderCollapsed(folderId, collapsed: isCollapsed)
            }
        case let .setFolderLock(spaceId, folderId, lock):
            return try mutateSpaceTab(spaceId: spaceId) { session in
                guard session.folder(id: folderId) != nil else { throw BrowserMutationError.missingFolder(folderId) }
                session.setFolderLock(folderId, lock: lock)
            }
        case let .setFolderAllowsBiometrics(spaceId, folderId, allowsBiometrics):
            return try mutateSpaceTab(spaceId: spaceId) { session in
                guard session.folder(id: folderId)?.lock != nil else { throw BrowserMutationError.missingFolder(folderId) }
                session.setFolderAllowsBiometrics(folderId, allowsBiometrics: allowsBiometrics)
            }
        case let .setFolderUnlocked(spaceId, folderId, isUnlocked):
            return try mutateSpaceTab(spaceId: spaceId) { session in
                guard session.folder(id: folderId) != nil else { throw BrowserMutationError.missingFolder(folderId) }
                session.setFolderUnlocked(folderId, unlocked: isUnlocked)
            }
        case let .deleteFolder(spaceId, folderId):
            return try mutateSpaceTab(spaceId: spaceId) { session in
                guard session.folder(id: folderId) != nil else { throw BrowserMutationError.missingFolder(folderId) }
                session.deleteFolder(folderId)
            }
        case let .deleteFolderWithTabs(spaceId, folderId):
            return try mutateSpaceTab(spaceId: spaceId) { session in
                guard session.removeFolder(folderId) != nil else { throw BrowserMutationError.missingFolder(folderId) }
            }
        case let .moveTabToSpace(tabId, sourceSpaceId, targetSpaceId, allowsPinnedTabs):
            return try moveNodeToSpace(kind: .tab, itemId: tabId, sourceSpaceId: sourceSpaceId, targetSpaceId: targetSpaceId, allowsPinnedTabs: allowsPinnedTabs)
        case let .moveFolderToSpace(folderId, sourceSpaceId, targetSpaceId, allowsPinnedTabs):
            return try moveNodeToSpace(kind: .folder, itemId: folderId, sourceSpaceId: sourceSpaceId, targetSpaceId: targetSpaceId, allowsPinnedTabs: allowsPinnedTabs)
        case let .moveTabToBookmarked(spaceId, tabId, insert):
            return try mutateSpaceTab(spaceId: spaceId) { session in
                guard let tab = session.tab(id: tabId) else { throw BrowserMutationError.missingTab(tabId) }
                guard !tab.isClosed || tab.isPinned || tab.isBookmarked else { throw BrowserMutationError.closedTab(tabId) }
                session.moveTabToBookmarked(tabId, insert: insert)
            }
        case let .groupTabs(spaceId, sourceTabId, targetTabId):
            return try mutateSpaceTab(spaceId: spaceId) { session in
                guard let sourceTab = session.tab(id: sourceTabId) else { throw BrowserMutationError.missingTab(sourceTabId) }
                guard let targetTab = session.tab(id: targetTabId) else { throw BrowserMutationError.missingTab(targetTabId) }
                guard !sourceTab.isClosed else { throw BrowserMutationError.closedTab(sourceTabId) }
                guard !targetTab.isClosed else { throw BrowserMutationError.closedTab(targetTabId) }
                session.groupTabs(sourceTabId: sourceTabId, targetTabId: targetTabId)
            }
        case let .setSplitLayout(spaceId, folderId, layout):
            return try mutateSpaceTab(spaceId: spaceId) { session in
                // Only rearranges: panes join and leave through splitTabs and replaceSplitPane.
                guard let current = session.folder(id: folderId)?.splitLayout,
                      Set(current.paneIds) == Set(layout.paneIds) else { throw BrowserMutationError.missingFolder(folderId) }
                session.setSplitLayout(folderId, layout: layout)
            }
        case let .splitTabs(spaceId, tabId, targetTabId, vertical, before):
            return try mutateSpaceTab(spaceId: spaceId) { session in
                guard let tab = session.tab(id: tabId) else { throw BrowserMutationError.missingTab(tabId) }
                guard let target = session.tab(id: targetTabId) else { throw BrowserMutationError.missingTab(targetTabId) }
                guard !tab.isClosed else { throw BrowserMutationError.closedTab(tabId) }
                guard !target.isClosed else { throw BrowserMutationError.closedTab(targetTabId) }
                session.splitTab(tabId, at: targetTabId, vertical: vertical, before: before)
            }
        case let .replaceSplitPane(spaceId, targetTabId, tabId):
            return try mutateSpaceTab(spaceId: spaceId) { session in
                guard let tab = session.tab(id: tabId) else { throw BrowserMutationError.missingTab(tabId) }
                guard session.tab(id: targetTabId) != nil else { throw BrowserMutationError.missingTab(targetTabId) }
                guard !tab.isClosed else { throw BrowserMutationError.closedTab(tabId) }
                session.replaceSplitPane(targetTabId, with: tabId)
            }
        case let .importSidebarNodes(spaceId, nodes, section):
            return try mutateSpaceTab(spaceId: spaceId) { session in
                session.appendImportedNodes(nodes, section: section)
            }
        case let .moveSidebarItem(spaceId, kind, itemId, parentFolderId, section, insert):
            guard let snapshot = spaces[spaceId] else { throw BrowserMutationError.missingSpace(spaceId) }
            guard canMoveSidebarItem(kind: kind, itemId: itemId, parentFolderId: parentFolderId, section: section, spaceTab: snapshot.spaceTab) else { return try unchanged(spaceId: spaceId) }
            return try mutateSpaceTab(spaceId: spaceId) { session in
                session.moveNode(itemId, toFolder: parentFolderId, section: section, insert: insert)
            }
        }
    }

    private func mutateSpaceTab(
        spaceId: UUID,
        mutate: (inout SpaceTab) throws -> Void
    ) throws -> BrowserChangeSet {
        let interval = PerfSignposts.browserState.beginInterval("mutate")
        defer { PerfSignposts.browserState.endInterval("mutate", interval) }
        guard var snapshot = spaces[spaceId] else {
            throw BrowserMutationError.missingSpace(spaceId)
        }
        // Pre-mutation capture for the mechanical diff (structural part is a memo-cache hit).
        let previousProjection = projectedSidebar(from: snapshot)
        let previousActiveTabId = snapshot.spaceTab.state.activeTabId
        var session = snapshot.spaceTab

        try mutate(&session)
        snapshot.spaceTab = session
        // A closed tab's engine leaves the runtime after this mutation, but the copy here would hold it
        // (and its live page) until the next sync, which can be minutes away.
        for tabId in snapshot.engines.keys where session.storedTab(tabId)?.isClosed != false {
            snapshot.engines.removeValue(forKey: tabId)
            snapshot.tabAdapters.removeValue(forKey: tabId)
            snapshot.restoringTabIds.removeValue(forKey: tabId)
        }

        let updatedState = browserSpaceChange(
            spaceId: spaceId,
            from: snapshot,
            previousProjection: previousProjection,
            previousActiveTabId: previousActiveTabId
        )
        snapshot.lastAccessedAt = Date()
        spaces[spaceId] = snapshot

        return BrowserChangeSet(
            spaceId: spaceId,
            stateChanges: [updatedState]
        )
    }

    private func canMoveSidebarItem(
        kind: TabTreeItem.Kind,
        itemId: UUID,
        parentFolderId: UUID?,
        section: TabTreeItem.Section,
        spaceTab: SpaceTab
    ) -> Bool {
        guard spaceTab.containsNode(id: itemId) else { return false }

        switch kind {
        case .tab:
            guard spaceTab.tab(id: itemId) != nil else { return false }
        case .folder:
            // A split stays at the root: its panes tile the page from there.
            guard let folder = spaceTab.folder(id: itemId), section != .bookmarked,
                  parentFolderId == nil || !folder.isSplit else { return false }
        }

        if let parentFolderId {
            guard let parent = spaceTab.folder(id: parentFolderId),
                  spaceTab.section(of: parentFolderId) == section else {
                return false
            }
            // A split only reorders its own two panes; anything else dropped in would dissolve it.
            if parent.isSplit, spaceTab.tab(id: itemId)?.groupId != parentFolderId { return false }
        }

        return true
    }

    private func moveNodeToSpace(
        kind: TabTreeItem.Kind,
        itemId: UUID,
        sourceSpaceId: UUID,
        targetSpaceId: UUID,
        allowsPinnedTabs: Bool
    ) throws -> BrowserChangeSet {
        guard sourceSpaceId != targetSpaceId else { return try unchanged(spaceId: sourceSpaceId) }
        guard var sourceSnapshot = spaces[sourceSpaceId] else { throw BrowserMutationError.missingSpace(sourceSpaceId) }
        guard var targetSnapshot = spaces[targetSpaceId] else { throw BrowserMutationError.missingSpace(targetSpaceId) }

        let sourceSection: TabTreeItem.Section
        let node: StoredSidebarNode
        let preservesBookmark: Bool
        switch kind {
        case .tab:
            guard let tab = sourceSnapshot.spaceTab.tab(id: itemId) else { throw BrowserMutationError.missingTab(itemId) }
            guard !tab.isClosed else { throw BrowserMutationError.closedTab(itemId) }
            sourceSection = sourceSnapshot.spaceTab.section(of: itemId) ?? (tab.isBookmarked ? .bookmarked : (tab.isPinned ? .pinned : .unpinned))
            guard let removed = sourceSnapshot.spaceTab.removeTabForTransfer(itemId) else { throw BrowserMutationError.missingTab(itemId) }
            node = removed
            preservesBookmark = true
        case .folder:
            guard sourceSnapshot.spaceTab.folder(id: itemId) != nil else { throw BrowserMutationError.missingFolder(itemId) }
            sourceSection = sourceSnapshot.spaceTab.section(of: itemId) ?? .unpinned
            guard let removed = sourceSnapshot.spaceTab.removeFolder(itemId) else { throw BrowserMutationError.missingFolder(itemId) }
            node = removed
            preservesBookmark = false
        }
        targetSnapshot.spaceTab.appendTransferredNode(
            node,
            section: sourceSection,
            allowsPinnedTabs: allowsPinnedTabs,
            preservesBookmark: preservesBookmark
        )

        sourceSnapshot.lastAccessedAt = Date()
        targetSnapshot.lastAccessedAt = Date()
        spaces[sourceSpaceId] = sourceSnapshot
        spaces[targetSpaceId] = targetSnapshot

        let updatedSource = browserSpaceChange(spaceId: sourceSpaceId, from: sourceSnapshot)
        let updatedTarget = browserSpaceChange(spaceId: targetSpaceId, from: targetSnapshot)
        return BrowserChangeSet(
            spaceId: targetSpaceId,
            stateChanges: [updatedSource, updatedTarget]
        )
    }

    private func unchanged(spaceId: UUID) throws -> BrowserChangeSet {
        guard let snapshot = spaces[spaceId] else {
            throw BrowserMutationError.missingSpace(spaceId)
        }
        // previous == current: the presenter sees an empty diff and emits nothing.
        let state = browserSpaceChange(
            spaceId: spaceId,
            from: snapshot,
            previousProjection: projectedSidebar(from: snapshot),
            previousActiveTabId: snapshot.spaceTab.state.activeTabId
        )
        return BrowserChangeSet(spaceId: spaceId, stateChanges: [state])
    }

    func activateSpace(id: UUID, loadSnapshot: () -> SpaceSnapshot) -> SpaceSnapshot {
        if spaces[id] == nil {
            spaces[id] = normalizedSnapshot(loadSnapshot(), spaceId: id)
        }
        visibleSpaceIds.insert(id)
        spaces[id]?.lastAccessedAt = Date()
        return spaces[id]!
    }

    @discardableResult
    func removeSpace(
        id: UUID,
        discardEngine: ((WKWebViewTab) -> Any?)?,
        discardTabAdapter: ((TabExtensionAdapter) -> Void)? = nil
    ) -> SpaceSnapshot? {
        visibleSpaceIds.remove(id)
        liveHosts.removeValue(forKey: id)
        guard let snapshot = spaces.removeValue(forKey: id) else { return nil }
        projectionCache.removeValue(forKey: id)
        if let discardEngine {
            snapshot.engines.values.forEach { _ = discardEngine($0) }
        }
        if let discardTabAdapter {
            snapshot.tabAdapters.values.forEach(discardTabAdapter)
        }
        return snapshot
    }

    private static func tabsMoved(by command: BrowserCommand) -> (spaceId: UUID, tabIds: [UUID])? {
        switch command {
        case let .setPinned(spaceId, tabId, _), let .setBookmarked(spaceId, tabId, _),
             let .moveTabToBookmarked(spaceId, tabId, _):
            return (spaceId, [tabId])
        case let .moveTabToSpace(tabId, sourceSpaceId, _, _):
            return (sourceSpaceId, [tabId])
        case let .groupTabs(spaceId, sourceTabId, targetTabId):
            return (spaceId, [sourceTabId, targetTabId])
        case let .splitTabs(spaceId, tabId, targetTabId, _, _), let .replaceSplitPane(spaceId, targetTabId, tabId):
            return (spaceId, [tabId, targetTabId])
        case let .moveSidebarItem(spaceId, .tab, itemId, _, _, _):
            return (spaceId, [itemId])
        default:
            return nil
        }
    }

    /// Every protected folder currently unlocked, in any space.
    func unlockedFolders() -> [(spaceId: UUID, folderId: UUID)] {
        spaces.flatMap { spaceId, snapshot in
            let spaceTab = snapshot.spaceTab
            return spaceTab.index.nodePathById.keys.compactMap { id -> (spaceId: UUID, folderId: UUID)? in
                guard !spaceTab.index.tabIds.contains(id),
                      let folder = spaceTab.folder(id: id), folder.lock != nil, folder.isUnlocked else { return nil }
                return (spaceId, id)
            }
        }
    }

    /// Drops the engines a hidden space keeps parked for `ids`, stashing their interaction state.
    func discardParkedEngines(_ ids: Set<UUID>, spaceId: UUID, discardEngine: (WKWebViewTab) -> Any?) {
        guard var snapshot = spaces[spaceId] else { return }
        for id in ids {
            guard let engine = snapshot.engines[id] else { continue }
            applyEngineDiscard(tabId: id, engine: engine, in: &snapshot, discardEngine: discardEngine)
        }
        spaces[spaceId] = snapshot
    }

    /// Every durable tab id across all spaces, unioned from each space's `SidebarNodeIndex`:
    /// no projection walk, no Tab materialization.
    func allTabIds() -> Set<UUID> {
        var ids = Set<UUID>()
        for snapshot in spaces.values {
            ids.formUnion(snapshot.spaceTab.index.tabIds)
        }
        return ids
    }

    /// O(spaces) hash lookups via each space's `SidebarNodeIndex`, no projection rebuild.
    func owningSpaceId(forTab id: UUID) -> UUID? {
        for (spaceId, snapshot) in spaces where snapshot.spaceTab.containsNode(id: id) {
            return spaceId
        }
        return nil
    }

    /// O(1) membership test for a single space, via its sidebar index.
    func space(_ spaceId: UUID, contains id: UUID) -> Bool {
        spaces[spaceId]?.spaceTab.containsNode(id: id) ?? false
    }

    /// Resolves a single tab's DURABLE projection without materializing the whole space: O(spaces) to
    /// find the owner, then one durable tree read for that tab. The caller applies the runtime overlay
    /// (the overlay is owned/shared by the caller, so we don't apply it here to avoid double-owner skew).
    func durableTab(for id: UUID) -> (spaceId: UUID, tab: Tab)? {
        guard let spaceId = owningSpaceId(forTab: id),
              let storedTab = spaces[spaceId]?.spaceTab.tab(id: id) else { return nil }
        return (spaceId, storedTab)
    }

    func transferTabRuntime(
        tabId: UUID,
        sourceSpaceId: UUID,
        targetSpaceId: UUID,
        engine: WKWebViewTab?,
        interactionState: Any?,
        restoringStartedAt: Date?
    ) {
        guard var sourceSnapshot = spaces[sourceSpaceId],
              var targetSnapshot = spaces[targetSpaceId] else {
            return
        }

        sourceSnapshot.engines.removeValue(forKey: tabId)
        sourceSnapshot.tabAdapters.removeValue(forKey: tabId)
        sourceSnapshot.interactionStates.removeValue(forKey: tabId)
        sourceSnapshot.interactionStateStashedAt.removeValue(forKey: tabId)
        sourceSnapshot.restoringTabIds.removeValue(forKey: tabId)
        // Runtime overlay is flat (keyed by global tab id), so it needs no source-to-target handoff.

        if let engine {
            targetSnapshot.engines[tabId] = engine
            targetSnapshot.tabAdapters.removeValue(forKey: tabId)
            targetSnapshot.interactionStates.removeValue(forKey: tabId)
            targetSnapshot.interactionStateStashedAt.removeValue(forKey: tabId)
            if let restoringStartedAt {
                targetSnapshot.restoringTabIds[tabId] = restoringStartedAt
            }
        } else {
            targetSnapshot.engines.removeValue(forKey: tabId)
            targetSnapshot.tabAdapters.removeValue(forKey: tabId)
            targetSnapshot.restoringTabIds.removeValue(forKey: tabId)
            if let interactionState {
                targetSnapshot.interactionStates[tabId] = interactionState
                targetSnapshot.interactionStateStashedAt[tabId] = Date()
            } else {
                targetSnapshot.interactionStates.removeValue(forKey: tabId)
                targetSnapshot.interactionStateStashedAt.removeValue(forKey: tabId)
            }
        }

        spaces[sourceSpaceId] = sourceSnapshot
        spaces[targetSpaceId] = targetSnapshot
    }

    @discardableResult
    func updateTab(
        id: UUID,
        mutate: (inout Tab) -> Void
    ) -> (old: Tab, new: Tab)? {
        // The owning space comes from the O(1) sidebar index, so the mutation runs outside any loop.
        guard let spaceId = owningSpaceId(forTab: id),
              let durable = spaces[spaceId]?.spaceTab.tab(id: id) else { return nil }

        // Mutate on top of the runtime overlay so earlier runtime flags accumulate: otherwise an unrelated tick clears the capture flags mid-call
        // and memory trim discards the live call. Runtime values written into the durable tree are inert: session save skips them.
        let oldTab = runtimeOverlay.applied(to: durable)
        var updatedTab = oldTab
        mutate(&updatedTab)
        // Mutating through the dictionary keeps the tree buffers uniquely referenced: a copied-out
        // snapshot would duplicate the section array on every title/URL/favicon change.
        spaces[spaceId]?.spaceTab.updateTab(updatedTab)
        runtimeOverlay.setRuntimeState(from: updatedTab)
        return (oldTab, updatedTab)
    }

    /// Stamp the activated tab's runtime `lastActiveAt`. Deliberately bypasses durable state so it
    /// neither bumps durableRevision nor schedules a session save; applies the existing overlay first
    /// so other runtime flags (audio/capture) are preserved rather than reset to defaults.
    func noteTabActivated(_ tabId: UUID) {
        guard let spaceId = owningSpaceId(forTab: tabId),
              let durable = spaces[spaceId]?.spaceTab.tab(id: tabId) else { return }
        var tab = runtimeOverlay.applied(to: durable)
        tab.lastActiveAt = Date()
        runtimeOverlay.setRuntimeState(from: tab)
    }

    func cacheInactiveSpaceRuntime(
        id: UUID,
        runtime: TabRuntimeSnapshot,
        folders: [TabFolder],
        treeItems: [TabTreeItem]
    ) {
        visibleSpaceIds.remove(id)
        let spaceTabs = runtime.tabs.filter { $0.spaceId == id }
        for tab in spaceTabs {
            runtimeOverlay.setRuntimeState(from: tab)
        }
        let tabIds = Set(spaceTabs.map(\.id))
        let interactionStates = runtime.savedInteractionStates.filter { tabIds.contains($0.key) }
        let retainedEngines = runtime.engines.filter { tabIds.contains($0.key) }
        let retainedTabAdapters = runtime.tabAdapters.filter { tabIds.contains($0.key) }

        let runtimeRestoringTabIds = runtime.restoringTabIds.filter { retainedEngines[$0.key] != nil && tabIds.contains($0.key) }
        if var snapshot = spaces[id] {
            snapshot.engines = retainedEngines
            snapshot.tabAdapters = retainedTabAdapters
            snapshot.interactionStates = interactionStates
            snapshot.interactionStateStashedAt = snapshot.interactionStateStashedAt.filter { interactionStates[$0.key] != nil }
            snapshot.restoringTabIds = runtimeRestoringTabIds
            snapshot.lastAccessedAt = Date()
            storeSpace(id: id, snapshot: snapshot)
            return
        }

        storeSpace(
            id: id,
            snapshot: SpaceSnapshot(
                spaceTab: SpaceTab(
                    spaceId: id,
                    state: SpaceTabStateImporter.importState(
                        activeTabId: runtime.activeTabId.flatMap { tabIds.contains($0) ? $0 : nil },
                        activationHistory: [],
                        tabs: spaceTabs,
                        folders: folders,
                        treeItems: treeItems,
                        spaceId: id
                    )
                ),
                engines: retainedEngines,
                tabAdapters: retainedTabAdapters,
                interactionStates: interactionStates,
                restoringTabIds: runtimeRestoringTabIds,
                lastAccessedAt: Date()
            )
        )
    }

    /// Freeze (suspend in place, not discard) idle engines in hidden spaces whose runtime `lastActiveAt`
    /// is older than `freezeThreshold` and which aren't protected (audio/capture/restoration/inspected)
    /// or already frozen. A frozen engine stays in memory (instant resume) but stops spending CPU/energy.
    func freezeIdleEngines(freezeThreshold: TimeInterval, now: Date = Date()) {
        guard freezeThreshold.isFinite else { return }
        let coordinator = TabLifecycleCoordinator(config: .default)   // grace periods are preset-invariant
        // Active space included so idle same-window tabs freeze too; its visible tab is protected below.
        for (spaceId, snapshot) in spaces where !snapshot.engines.isEmpty {
            let tabs = projectedSidebar(from: snapshot).tabs
            var protectedTabIds = coordinator.protectedEngineIds(
                tabs: tabs,
                availableEngineIds: Set(snapshot.engines.keys),
                restoringTabIds: snapshot.restoringTabIds,
                now: now
            ).union(inspectedEngineIds(in: snapshot.engines)).union(displayedTabIds)
            if visibleSpaceIds.contains(spaceId), let visibleTabId = snapshot.spaceTab.state.activeTabId {
                protectedTabIds.insert(visibleTabId)
                if let split = snapshot.spaceTab.splitGroup(containing: visibleTabId) { protectedTabIds.formUnion(split.layout.paneIds) }
            }
            var lastActiveByTab: [UUID: Date] = [:]
            for tab in tabs { if let last = tab.lastActiveAt { lastActiveByTab[tab.id] = last } }
            for (tabId, engine) in snapshot.engines where !protectedTabIds.contains(tabId) && !engine.isFrozen {
                let last = lastActiveByTab[tabId] ?? engine.createdAt
                guard now.timeIntervalSince(last) > freezeThreshold else { continue }
                engine.freeze()
            }
        }
    }

    /// Freezes every live engine of every Space but agent tabs, visible ones included, for a closed lid. Returns
    /// only the engines this call froze, so a resume leaves the idle-frozen ones frozen.
    func freezeAllEngines() -> [WKWebViewTab] {
        var frozen: [WKWebViewTab] = []
        for snapshot in spaces.values {
            for engine in snapshot.engines.values where !engine.isFrozen && !engine.isAgentControlled {
                engine.freeze()
                frozen.append(engine)
            }
        }
        return frozen
    }

    func trimInactiveEngines(
        excluding protectedSpaceId: UUID?,
        policy: TabLifecycleCoordinator.Policy,
        maxRetainedEnginesPerHiddenSpace: Int,
        maxHiddenSpacesWithRetainedEngines: Int,
        discardEngine: (WKWebViewTab) -> Any?,
        discardThreshold: TimeInterval = .infinity
    ) {
        let inactiveSpaces = spaces.filter { !$0.value.engines.isEmpty && !visibleSpaceIds.contains($0.key) }
        guard !inactiveSpaces.isEmpty else { return }

        let coordinator = TabLifecycleCoordinator(
            maxNormalRetainedEnginesPerHiddenSpace: maxRetainedEnginesPerHiddenSpace,
            maxHiddenSpacesWithNormalRetainedEngines: maxHiddenSpacesWithRetainedEngines,
            policy: policy
        )
        var projectedTabsBySpace: [UUID: [Tab]] = [:]
        let hiddenSpaceModels = inactiveSpaces.map { spaceId, snapshot in
            let tabs = projectedSidebar(from: snapshot).tabs
            projectedTabsBySpace[spaceId] = tabs
            return TabLifecycleCoordinator.HiddenSpace(
                id: spaceId,
                tabs: tabs,
                retainedEngineIds: Set(snapshot.engines.keys),
                restoringTabIds: snapshot.restoringTabIds,
                lastAccessedAt: snapshot.lastAccessedAt
            )
        }
        let now = Date()
        let evictedSpaceIds = coordinator.hiddenSpacesToEvict(
            hiddenSpaceModels,
            protectedSpaceId: protectedSpaceId,
            now: now
        )

        for spaceId in evictedSpaceIds {
            guard var snapshot = spaces[spaceId] else { continue }
            let tabs = projectedTabsBySpace[spaceId] ?? projectedSidebar(from: snapshot).tabs
            let protectedTabIds = coordinator.protectedEngineIds(
                tabs: tabs,
                availableEngineIds: Set(snapshot.engines.keys),
                restoringTabIds: snapshot.restoringTabIds,
                now: now
            ).union(inspectedEngineIds(in: snapshot.engines))
            let evictedEngines = snapshot.engines.filter { !protectedTabIds.contains($0.key) }
            for (tabId, engine) in evictedEngines {
                applyEngineDiscard(tabId: tabId, engine: engine, in: &snapshot, discardEngine: discardEngine)
            }
            if snapshot.engines.isEmpty {
                snapshot.lastAccessedAt = now
            }
            spaces[spaceId] = snapshot
        }

        // Enforce `maxRetainedEnginesPerHiddenSpace` on survivor spaces, independent of the idle
        // threshold below.
        for spaceId in inactiveSpaces.keys where !evictedSpaceIds.contains(spaceId) {
            guard var snapshot = spaces[spaceId] else { continue }
            let tabs = projectedTabsBySpace[spaceId] ?? projectedSidebar(from: snapshot).tabs
            let retained = coordinator.retainedEngineIds(
                tabs: tabs,
                availableEngineIds: Set(snapshot.engines.keys),
                preferredTabId: snapshot.spaceTab.state.activeTabId ?? tabs.first(where: { !$0.isClosed })?.id,
                restoringTabIds: snapshot.restoringTabIds,
                now: now
            ).union(inspectedEngineIds(in: snapshot.engines))
            var budgetChanged = false
            for (tabId, engine) in snapshot.engines where !retained.contains(tabId) {
                applyEngineDiscard(tabId: tabId, engine: engine, in: &snapshot, discardEngine: discardEngine)
                budgetChanged = true
            }
            if budgetChanged { spaces[spaceId] = snapshot }
        }

        // Idle-eviction pass: engines in spaces that *survived* the LRU budget are still eligible
        // for eviction if they haven't been active recently. Skipped when the threshold is .infinity
        // (the default).
        guard discardThreshold.isFinite else { return }
        let survivors = inactiveSpaces.keys.filter { !evictedSpaceIds.contains($0) }
        for spaceId in survivors {
            guard var snapshot = spaces[spaceId], !snapshot.engines.isEmpty else { continue }
            let tabs = projectedTabsBySpace[spaceId] ?? projectedSidebar(from: snapshot).tabs
            let protectedTabIds = coordinator.idleDiscardProtectedEngineIds(
                tabs: tabs, availableEngineIds: Set(snapshot.engines.keys),
                restoringTabIds: snapshot.restoringTabIds, now: now
            ).union(inspectedEngineIds(in: snapshot.engines))
            var lastActiveByTab: [UUID: Date] = [:]
            for tab in tabs { if let last = tab.lastActiveAt { lastActiveByTab[tab.id] = last } }
            var changed = false
            for (tabId, engine) in snapshot.engines where !protectedTabIds.contains(tabId) {
                let last = lastActiveByTab[tabId] ?? engine.createdAt
                guard now.timeIntervalSince(last) > discardThreshold else { continue }
                applyEngineDiscard(tabId: tabId, engine: engine, in: &snapshot, discardEngine: discardEngine)
                changed = true
            }
            if changed { spaces[spaceId] = snapshot }
        }
    }

    /// Real footprint sampler: sums each live engine's WebContent physical footprint, split evenly across
    /// tabs that share a process so the same pages aren't counted once per tab. One `proc_pid_rusage`
    /// syscall per unique WebContent pid, so this is called at most once per idle sweep.
    @MainActor
    static func sampleWebContentFootprint(_ engines: [UUID: WKWebViewTab]) -> [UUID: UInt64] {
        var pidByTab: [UUID: Int] = [:]
        for (tabId, engine) in engines {
            if let pid = WebViewPrivateAccessors(engine.wkWebView).pid("_webProcessIdentifier"), pid > 0 {
                pidByTab[tabId] = pid
            }
        }
        var tabsPerPid: [Int: Int] = [:]
        for pid in pidByTab.values { tabsPerPid[pid, default: 0] += 1 }
        var footprintByPid: [Int: UInt64] = [:]
        for pid in Set(pidByTab.values) { footprintByPid[pid] = ProcessTaskInfoSampler.physicalFootprint(pid: pid) ?? 0 }
        var result: [UUID: UInt64] = [:]
        for (tabId, pid) in pidByTab {
            result[tabId] = (footprintByPid[pid] ?? 0) / UInt64(tabsPerPid[pid] ?? 1)
        }
        return result
    }

    /// When the summed WebContent footprint exceeds `ceilingBytes`, discards hidden-space engines oldest-active first, through the coordinator's
    /// idle-discard protections. Returns the sampled total, for hysteresis, and the projected total the caller takes from visible spaces.
    @discardableResult
    func trimEnginesExceedingFootprintCeiling(
        ceilingBytes: UInt64,
        discardEngine: (WKWebViewTab) -> Any?,
        footprintSampler: @MainActor ([UUID: WKWebViewTab]) -> [UUID: UInt64] = BrowserStateStore.sampleWebContentFootprint,
        now: Date = Date()
    ) -> (total: UInt64, remaining: UInt64) {
        guard ceilingBytes > 0 else { return (0, 0) }
        let allEngines = enginesAcrossSpaces
        guard !allEngines.isEmpty else { return (0, 0) }

        let footprintByTab = footprintSampler(allEngines)
        let total = footprintByTab.values.reduce(0, +)
        guard total > ceilingBytes else { return (total, total) }

        struct Candidate { let spaceId: UUID; let tabId: UUID; let engine: WKWebViewTab; let lastActiveAt: Date }
        let coordinator = TabLifecycleCoordinator(config: .default)   // grace periods are preset-invariant
        var candidates: [Candidate] = []
        // Visible spaces are left to the window's own trim: their EngineHost still holds the engine.
        for (spaceId, snapshot) in spaces where !visibleSpaceIds.contains(spaceId) {
            let tabs = projectedSidebar(from: snapshot).tabs
            let protectedTabIds = discardProtectedEngineIds(spaceId: spaceId, snapshot: snapshot, tabs: tabs, coordinator: coordinator, now: now)
            var lastActiveByTab: [UUID: Date] = [:]
            for tab in tabs { if let last = tab.lastActiveAt { lastActiveByTab[tab.id] = last } }
            for (tabId, engine) in snapshot.engines where !protectedTabIds.contains(tabId) {
                candidates.append(Candidate(spaceId: spaceId, tabId: tabId, engine: engine, lastActiveAt: lastActiveByTab[tabId] ?? engine.createdAt))
            }
        }
        // Oldest idle first.
        candidates.sort { $0.lastActiveAt < $1.lastActiveAt }

        var projected = total
        for candidate in candidates {
            guard projected > ceilingBytes else { break }
            guard var snapshot = spaces[candidate.spaceId] else { continue }
            applyEngineDiscard(tabId: candidate.tabId, engine: candidate.engine, in: &snapshot, discardEngine: discardEngine)
            spaces[candidate.spaceId] = snapshot
            projected -= min(projected, footprintByTab[candidate.tabId] ?? 0)
        }
        return (total, projected)
    }

    /// Discards hidden-space engines whose process exceeded `maxCPUPercent` or `maxFootprintBytes` on two sweeps in a row, so a tab busy
    /// just before the user left it is not taken for a runaway. A process also hosting a protected engine is left alone.
    func discardBusyBackgroundEngines(
        maxCPUPercent: Double,
        maxFootprintBytes: UInt64,
        previouslyBusyTabIds: inout Set<UUID>,
        cpuSampler: @MainActor ([UUID: WKWebViewTab]) -> [UUID: WebContentCPUSampler.EngineUsage],
        discardEngine: (WKWebViewTab) -> Any?,
        now: Date = Date()
    ) {
        let allEngines = enginesAcrossSpaces
        let cpuByTab = cpuSampler(allEngines)
        let coordinator = TabLifecycleCoordinator(config: .default)   // grace periods are preset-invariant
        var protectedTabIds: Set<UUID> = []
        var spaceByTab: [UUID: UUID] = [:]
        for (spaceId, snapshot) in spaces where !snapshot.engines.isEmpty {
            let tabs = projectedSidebar(from: snapshot).tabs
            protectedTabIds.formUnion(discardProtectedEngineIds(spaceId: spaceId, snapshot: snapshot, tabs: tabs, coordinator: coordinator, now: now))
            // Visible spaces are left to the window's own trim: their EngineHost still holds the engine.
            guard !visibleSpaceIds.contains(spaceId) else { continue }
            for tabId in snapshot.engines.keys { spaceByTab[tabId] = spaceId }
        }
        let protectedPids = Set(protectedTabIds.compactMap { cpuByTab[$0]?.pid })
        let busy = Set(cpuByTab.compactMap { tabId, cpu in
            spaceByTab[tabId] != nil && !protectedTabIds.contains(tabId) && !protectedPids.contains(cpu.pid)
                && (cpu.percent >= maxCPUPercent || cpu.footprint >= maxFootprintBytes) ? tabId : nil
        })
        let toDiscard = busy.intersection(previouslyBusyTabIds)
        previouslyBusyTabIds = busy.subtracting(toDiscard)
        for tabId in toDiscard {
            guard let spaceId = spaceByTab[tabId], var snapshot = spaces[spaceId], let engine = snapshot.engines[tabId] else { continue }
            Self.logger.info("""
                discarding busy background engine host=\(engine.currentURL?.host ?? "nil", privacy: .private) \
                cpu=\(Int(cpuByTab[tabId]?.percent ?? 0), privacy: .public)% \
                footprint=\((cpuByTab[tabId]?.footprint ?? 0) >> 20, privacy: .public)MB
                """)
            applyEngineDiscard(tabId: tabId, engine: engine, in: &snapshot, discardEngine: discardEngine)
            spaces[spaceId] = snapshot
        }
    }

    /// Engines no discard pass may take: the coordinator's idle-discard protections, inspected
    /// engines, and the tab on screen.
    private func discardProtectedEngineIds(
        spaceId: UUID,
        snapshot: SpaceSnapshot,
        tabs: [Tab],
        coordinator: TabLifecycleCoordinator,
        now: Date
    ) -> Set<UUID> {
        var protectedTabIds = coordinator.idleDiscardProtectedEngineIds(
            tabs: tabs,
            availableEngineIds: Set(snapshot.engines.keys),
            restoringTabIds: snapshot.restoringTabIds,
            now: now
        ).union(inspectedEngineIds(in: snapshot.engines)).union(displayedTabIds)
        if visibleSpaceIds.contains(spaceId), let visibleTabId = snapshot.spaceTab.state.activeTabId {
            protectedTabIds.insert(visibleTabId)
        }
        return protectedTabIds
    }

    /// Live engines across all spaces; the idle sweep's footprint hysteresis keys off it.
    var liveEngineCount: Int { spaces.values.reduce(0) { $0 + $1.engines.count } }

    /// Stashes an engine's interaction state, then drops it and its bookkeeping from `snapshot`; every discard path goes through it.
    /// The tab's adapter stays, emptied, so extensions keep its id across the discard.
    private func applyEngineDiscard(
        tabId: UUID,
        engine: WKWebViewTab,
        in snapshot: inout SpaceSnapshot,
        discardEngine: (WKWebViewTab) -> Any?
    ) {
        if let state = discardEngine(engine) {
            snapshot.interactionStates[tabId] = state
            snapshot.interactionStateStashedAt[tabId] = Date()
            let stashedAt = snapshot.interactionStateStashedAt
            // Blobs handed over by other paths carry no stamp and count as the oldest.
            while snapshot.interactionStates.count > Self.maxInteractionStatesPerSpace,
                  let oldest = snapshot.interactionStates.keys.min(by: { (stashedAt[$0] ?? .distantPast) < (stashedAt[$1] ?? .distantPast) }) {
                snapshot.interactionStates.removeValue(forKey: oldest)
                snapshot.interactionStateStashedAt.removeValue(forKey: oldest)
            }
        }
        snapshot.engines.removeValue(forKey: tabId)
        snapshot.restoringTabIds.removeValue(forKey: tabId)
        runtimeOverlay.discardRuntimeState(for: tabId)
        // The tab stays open to extensions under the same id; reactivation hands it a new engine.
        snapshot.tabAdapters[tabId]?.engineTab = nil
    }

    func lifecycleDiagnostics() -> TabLifecycleDiagnostics {
        BrowserLifecycleDiagnosticsBuilder.build(
            spaces: spaces,
            visibleSpaceIds: visibleSpaceIds,
            projection: { self.projectedSidebar(from: $0) }
        )
    }

    private func inspectedEngineIds(in engines: [UUID: WKWebViewTab]) -> Set<UUID> {
        Set(engines.compactMap { id, engine in
            engine.shouldRetainForWebInspector ? id : nil
        })
    }

    private func normalizedSnapshot(_ snapshot: SpaceSnapshot, spaceId: UUID) -> SpaceSnapshot {
        guard snapshot.spaceTab.spaceId != spaceId else { return snapshot }
        let projection = projectedSidebar(from: snapshot)
        var normalized = snapshot
        normalized.spaceTab = SpaceTab(
            spaceId: spaceId,
            state: SpaceTabStateImporter.importState(
                activeTabId: snapshot.spaceTab.state.activeTabId,
                activationHistory: snapshot.spaceTab.state.activationHistory,
                viewedAt: snapshot.spaceTab.state.viewedAt,
                tabs: projection.tabs,
                folders: projection.folders,
                treeItems: projection.treeItems,
                spaceId: spaceId
            )
        )
        return normalized
    }
}

extension BrowserStateStore {
    /// The engine of a tab created in a space no window shows; a window showing the space takes it over.
    func storeHiddenEngine(_ engine: WKWebViewTab, tabId: UUID, spaceId: UUID) {
        spaces[spaceId]?.engines[tabId] = engine
    }

    func engine(tabId: UUID, spaceId: UUID) -> WKWebViewTab? {
        spaces[spaceId]?.engines[tabId]
    }

    /// A tab's engine wherever it lives: the host of a space some window shows, or parked in a hidden space.
    func liveEngine(forTab id: UUID) -> WKWebViewTab? {
        guard let spaceId = owningSpaceId(forTab: id) else { return nil }
        return liveHost(for: spaceId)?.engine(for: id) ?? engine(tabId: id, spaceId: spaceId)
    }

    /// Tabs whose engine is parked live in a hidden space.
    var parkedEngineTabIds: Set<UUID> { Set(spaces.values.flatMap(\.engines.keys)) }

    /// Every space's live engines, keyed by tab.
    private var enginesAcrossSpaces: [UUID: WKWebViewTab] {
        var engines: [UUID: WKWebViewTab] = [:]
        for snapshot in spaces.values { engines.merge(snapshot.engines) { _, new in new } }
        return engines
    }

    /// The content process a tab's page runs in, and how many loaded tabs share it.
    func webContentProcess(forTab tabId: UUID) -> (pid: Int, sharing: Int)? {
        let webProcessPid = { (engine: WKWebViewTab) in WebViewPrivateAccessors(engine.wkWebView).pid("_webProcessIdentifier") }
        guard let engine = spaces.values.lazy.compactMap({ $0.engines[tabId] }).first,
              let pid = webProcessPid(engine), pid > 0 else { return nil }
        let sharing = spaces.values.reduce(0) { count, space in count + space.engines.values.filter { webProcessPid($0) == pid }.count }
        return (pid, max(sharing, 1))
    }

    func processSnapshot(
        metricsProvider: (Set<Int>) -> [Int: ProcessResourceMetrics] = { _ in [:] },
        diagnosticsProvider: (WKWebViewTab) -> WebViewProcessDiagnostics = { $0.processDiagnostics }
    ) -> [BrowserProcessInfo] {
        BrowserProcessSnapshotBuilder.build(
            spaces: spaces,
            visibleSpaceIds: visibleSpaceIds,
            projection: { self.projectedSidebar(from: $0) },
            metricsProvider: metricsProvider,
            diagnosticsProvider: diagnosticsProvider
        )
    }
}

extension BrowserStateStore {
    func spaceTabState(forSpace spaceId: UUID) -> SpaceTabState? {
        spaces[spaceId]?.spaceTab.state
    }

    func orderedSpaceTabSpaceIds(currentSpaceId: UUID?) -> [UUID] {
        var ids = Array(spaces.keys)
        if let currentSpaceId { ids.removeAll { $0 == currentSpaceId } }
        // Byte order is uuidString order (fixed-width uppercase hex) without a string per comparison.
        ids.sort { lhs, rhs in
            withUnsafeBytes(of: lhs.uuid) { lhsBytes in
                withUnsafeBytes(of: rhs.uuid) { rhsBytes in
                    memcmp(lhsBytes.baseAddress, rhsBytes.baseAddress, lhsBytes.count) < 0
                }
            }
        }
        if let currentSpaceId { ids.insert(currentSpaceId, at: 0) }
        return ids
    }
}

private enum BrowserMutationError: Error, Equatable {
    case missingSpace(UUID)
    case missingTab(UUID)
    case closedTab(UUID)
    case missingFolder(UUID)
    case lockedTab(UUID)
}
