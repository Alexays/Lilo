import Foundation

/// What a structural mutation actually changed in a space's sidebar, computed mechanically by
/// diffing the pre- and post-mutation projections: whatever the mutation (including its repair
/// pass) touched is exactly what ships, with no per-command presentation choices.
struct SidebarDelta: Sendable {
    var upsertTabs: [Tab] = []
    /// Upserted tabs whose favicon is unchanged: their snapshots leave the heavy base64 out.
    var unchangedFaviconTabIds: Set<UUID> = []
    var removedTabIds: [UUID] = []
    var upsertFolders: [TabFolder] = []
    var removedFolderIds: [UUID] = []
    /// The whole tree, set only when most of it changed. Without it and without tree upserts or removals the tree is
    /// unchanged: the common case for tab activation, where the whole patch then collapses to `{spaceId, activeTabId}`.
    var treeItems: [TabTreeItem]?
    /// Otherwise the tree items that are new or moved, and the item ids that left: the client keys them by `itemId`.
    var upsertTreeItems: [TabTreeItem] = []
    var removedTreeItemIds: [UUID] = []

    var isEmpty: Bool {
        upsertTabs.isEmpty && removedTabIds.isEmpty
            && upsertFolders.isEmpty && removedFolderIds.isEmpty
            && treeItems == nil && upsertTreeItems.isEmpty && removedTreeItemIds.isEmpty
    }
}

enum SidebarDiff {
    /// Both projections must come from one synchronous main-actor mutation, so the runtime overlay matches and leaks nothing into the delta.
    /// Tabs compare by `hasSameSidebarContent`, which ignores bookkeeping stamped outside this emit cycle (`lastActiveAt`).
    static func delta(from previous: SpaceTabProjection, to current: SpaceTabProjection) -> SidebarDelta {
        var delta = SidebarDelta()
        // Both sides served by one projection memo entry (an activation) share their buffers: equal without a walk.
        func sameStorage<T>(_ lhs: [T], _ rhs: [T]) -> Bool {
            lhs.count == rhs.count && lhs.withUnsafeBufferPointer { lhs in rhs.withUnsafeBufferPointer { lhs.baseAddress == $0.baseAddress } }
        }
        if sameStorage(previous.tabs, current.tabs), sameStorage(previous.folders, current.folders),
           sameStorage(previous.treeItems, current.treeItems) {
            return delta
        }

        // Indexes, not copies: a Tab is large and a big space holds thousands.
        let previousIndexById = Dictionary(uniqueKeysWithValues: previous.tabs.indices.lazy.map { (previous.tabs[$0].id, $0) })
        var unchangedFaviconTabIds: Set<UUID> = []
        delta.upsertTabs = current.tabs.filter { tab in
            guard let index = previousIndexById[tab.id] else { return true }
            guard !tab.hasSameSidebarContent(as: previous.tabs[index]) else { return false }
            if tab.faviconDataURL == previous.tabs[index].faviconDataURL { unchangedFaviconTabIds.insert(tab.id) }
            return true
        }
        delta.unchangedFaviconTabIds = unchangedFaviconTabIds
        let currentTabIds = Set(current.tabs.map(\.id))
        delta.removedTabIds = previous.tabs.map(\.id).filter { !currentTabIds.contains($0) }

        let previousFoldersById = Dictionary(uniqueKeysWithValues: previous.folders.map { ($0.id, $0) })
        delta.upsertFolders = current.folders.filter { previousFoldersById[$0.id] != $0 }
        let currentFolderIds = Set(current.folders.map(\.id))
        delta.removedFolderIds = previous.folders.map(\.id).filter { !currentFolderIds.contains($0) }

        let treeUnchanged = previous.treeItems.count == current.treeItems.count
            && previous.treeItems.elementsEqual(current.treeItems) { $0.hasSameStructure(as: $1) }
        if !treeUnchanged {
            var previousByItemId: [UUID: TabTreeItem] = [:]
            previousByItemId.reserveCapacity(previous.treeItems.count)
            for item in previous.treeItems { previousByItemId[item.itemId] = item }
            var currentItemIds = Set<UUID>(minimumCapacity: current.treeItems.count)
            var upserts: [TabTreeItem] = []
            for item in current.treeItems {
                currentItemIds.insert(item.itemId)
                if previousByItemId[item.itemId]?.hasSameStructure(as: item) != true { upserts.append(item) }
            }
            let removed = previous.treeItems.lazy.map(\.itemId).filter { !currentItemIds.contains($0) }
            // Keyed patching needs unique item ids, and pays off only while it is small next to the tree:
            // a sibling insert shifts the sort order of every later sibling.
            if previousByItemId.count == previous.treeItems.count, currentItemIds.count == current.treeItems.count,
               (upserts.count + removed.count) * 2 < current.treeItems.count {
                delta.upsertTreeItems = upserts
                delta.removedTreeItemIds = Array(removed)
            } else {
                delta.treeItems = current.treeItems
            }
        }

        return delta
    }
}

extension Tab {
    /// Ignores `lastActiveAt` and `hasUnsavedFormData`: the sidebar never renders them and they mutate outside the structural emit cycle,
    /// so comparing them would leak or churn the diff.
    func hasSameSidebarContent(as other: Tab) -> Bool {
        // Most tabs of a diff are untouched: equal as they are, without the two copies below.
        if self == other { return true }
        guard lastActiveAt != other.lastActiveAt || hasUnsavedFormData != other.hasUnsavedFormData else { return false }
        var a = self
        var b = other
        a.lastActiveAt = nil
        b.lastActiveAt = nil
        a.hasUnsavedFormData = false
        b.hasUnsavedFormData = false
        return a == b
    }
}

extension TabTreeItem {
    /// Equality minus `id`: projection builds synthesize a fresh `id` per item, so comparing it
    /// would make every tree look changed. Nothing downstream keys on it.
    func hasSameStructure(as other: TabTreeItem) -> Bool {
        kind == other.kind
            && itemId == other.itemId
            && parentFolderId == other.parentFolderId
            && section == other.section
            && sortOrder == other.sortOrder
            && spaceId == other.spaceId
    }
}
