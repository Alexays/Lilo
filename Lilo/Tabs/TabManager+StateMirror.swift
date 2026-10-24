import Foundation

extension TabManager {
    var currentTabs: [Tab] {
        guard let currentSpaceId else { return allTabs }
        return tabs(forSpace: currentSpaceId)
    }

    /// All runtime tabs across spaces, in sidebar order. Derived on demand; there is no cached copy.
    var allTabs: [Tab] {
        orderedSidebarSpaceIds().flatMap { tabs(forSpace: $0) }
    }

    /// Empty when the store doesn't (yet) own the space.
    private func durableProjection(forSpace spaceId: UUID) -> SpaceTabProjection {
        browserStateStore?.structuralProjection(forSpace: spaceId)
            ?? SpaceTabProjection(tabs: [], folders: [], treeItems: [])
    }

    /// The durable projection with the runtime overlay applied, memoized by the store.
    func tabs(forSpace spaceId: UUID) -> [Tab] {
        guard let store = browserStateStore, let snapshot = store.space(id: spaceId) else { return [] }
        return store.projectedSidebar(from: snapshot).tabs
    }

    func folders(forSpace spaceId: UUID) -> [TabFolder] {
        durableProjection(forSpace: spaceId).folders
    }

    func folder(id folderId: UUID) -> TabFolder? {
        orderedSidebarSpaceIds().lazy
            .compactMap { spaceId in self.folders(forSpace: spaceId).first { $0.id == folderId } }
            .first
    }

    func sidebarTreeItems(forSpace spaceId: UUID) -> [TabTreeItem] {
        durableProjection(forSpace: spaceId).treeItems
    }

    /// The store owns the durable tree and the runtime overlay never touches its serialized
    /// fields, so only `activeTabId` can differ from what this mirror resolves: take the stored
    /// state and patch just that instead of rebuilding the whole tree via importState.
    func spaceTabState(forSpace spaceId: UUID, activationHistory: [UUID]? = nil) -> SpaceTabState {
        guard var state = browserStateStore?.spaceTabState(forSpace: spaceId) else {
            return SpaceTabState(activeTabId: nil, activationHistory: [], tree: .empty)
        }
        if let activationHistory { state.activationHistory = activationHistory }
        let activeTabIdInSpace = activeTabId.flatMap { activeId in
            tabs(forSpace: spaceId).contains { $0.id == activeId && !$0.isClosed } ? activeId : nil
        }
        if state.activeTabId != activeTabIdInSpace { state.activeTabId = activeTabIdInSpace }
        return state
    }

    /// `prunesStaleOverlay` (an O(all-tabs) sweep) and `repairsState` are false on command paths: close/discard drop overlays at the source
    /// and the store's pipeline already repaired the state. `emitsTabMoves` is false for commands that change neither the tab set nor its order.
    func applyDurableProjectionToRuntime(
        _ state: SpaceTabState,
        spaceId: UUID,
        prunesStaleOverlay: Bool = true,
        repairsState: Bool = true,
        emitsTabMoves: Bool = true
    ) {
        let repaired = repairsState ? SpaceTabStateRepair.repaired(state) : state

        // Tab lists are derived from the durable store, so the store must own this space's state.
        // Most callers commit it first; the cross-profile move removes the space from the store and
        // relies on this to stage it back, keeping the store the single source of truth (no index).
        if let store = browserStateStore, store.space(id: spaceId) == nil {
            store.storeSpace(
                id: spaceId,
                snapshot: BrowserStateStore.SpaceSnapshot(spaceTab: SpaceTab(spaceId: spaceId, state: repaired), engines: [:])
            )
        }

        if prunesStaleOverlay {
            runtimeOverlay.retainRuntimeStates(validTabIds: runtimeValidTabIds)
        }

        // The store's active tab is the one any window activated last: a window keeps its own
        // selection while that tab is still open in the space.
        if currentSpaceId == spaceId,
           activeTabId.map({ id in !tabs(forSpace: spaceId).contains { $0.id == id && !$0.isClosed } }) ?? true {
            activeTabId = repaired.activeTabId
        }

        if emitsTabMoves { emitTabMovedEventsIfNeeded() }
    }

    /// Ids of every runtime tab across all spaces, used to prune overlay states for closed tabs.
    /// Reads the store's per-space sidebar indexes directly: same id set as walking `allTabs`, but
    /// with no projection walk or per-tab overlay apply (this runs on every space switch).
    var runtimeValidTabIds: Set<UUID> {
        browserStateStore?.allTabIds() ?? []
    }

    /// Fires `tabs.onMoved` for the current-space tabs a reorder moved: as Chrome reports a drag, the tabs outside
    /// the longest run that kept its order, so the tabs merely shifted by a move hear nothing. Tabs that came or went
    /// (space switch, open/close) are left to onCreated/onRemoved/onActivated: the others keep their order then.
    func emitTabMovedEventsIfNeeded() {
        guard let registry = extensionRegistry, registry.hasLoadedExtensions,
              let windowAdapter, let spaceId = currentSpaceId else {
            lastExtensionTabMoveOrder = []
            return
        }
        let newOrder = tabs(forSpace: spaceId).map(\.id)
        let oldOrder = lastExtensionTabMoveOrder
        lastExtensionTabMoveOrder = newOrder
        guard newOrder != oldOrder else { return }

        // Indices count the tabs WebKit sees, those with an adapter, which a new tab gets after the command that placed it.
        var oldIndexById: [UUID: Int] = [:]
        for id in oldOrder where tabAdapter(for: id) != nil { oldIndexById[id] = oldIndexById.count }
        let stayed = newOrder.compactMap { id in oldIndexById[id].map { (id: id, oldIndex: $0) } }

        // Longest increasing run of old indices (patience sort): `tails[k]` ends the best run of length k + 1.
        var tails: [Int] = []
        var previous = [Int](repeating: -1, count: stayed.count)
        for (position, tab) in stayed.enumerated() {
            var low = 0, high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if stayed[tails[mid]].oldIndex < tab.oldIndex { low = mid + 1 } else { high = mid }
            }
            if low > 0 { previous[position] = tails[low - 1] }
            if low == tails.count { tails.append(position) } else { tails[low] = position }
        }
        var kept = [Bool](repeating: false, count: stayed.count)
        var position = tails.last ?? -1
        while position >= 0 {
            kept[position] = true
            position = previous[position]
        }
        for (position, tab) in stayed.enumerated() where !kept[position] {
            guard let adapter = tabAdapter(for: tab.id) else { continue }
            registry.controller.didMoveTab(adapter, from: tab.oldIndex, in: windowAdapter)
        }
    }

    func tabContext(for id: UUID) -> (spaceId: UUID, tab: Tab, index: Int)? {
        guard let spaceId = browserStateStore?.owningSpaceId(forTab: id) else { return nil }
        let spaceTabs = tabs(forSpace: spaceId)
        guard let index = spaceTabs.firstIndex(where: { $0.id == id }) else { return nil }
        return (spaceId, spaceTabs[index], index)
    }

    func orderedSidebarSpaceIds() -> [UUID] {
        browserStateStore?.orderedSpaceTabSpaceIds(currentSpaceId: currentSpaceId) ??
            currentSpaceId.map { [$0] } ?? []
    }
}
