import Foundation
import OSLog

struct SplitGroup: Equatable {
    let folderId: UUID
    let layout: SplitLayout
}

@MainActor
struct SpaceTab {
    let spaceId: UUID
    private(set) var state: SpaceTabState
    private(set) var index: SidebarNodeIndex

    /// Re-rolled by every structural mutation (`finishMutation()`). Lets callers memoize derived
    /// data (sidebar projections) with token equality instead of fragile invalidation hooks,
    /// a UUID (not a counter) so two SpaceTab instances can never collide on the same key.
    private(set) var structureToken = UUID()

    /// Bumped by content-only in-place rewrites (tab fields, folder name/color/collapse): the shape and `structureToken` survive but
    /// projected content changes, so projection memos key on both.
    private(set) var contentRevision: UInt64 = 0

    /// Bumped on every durable mutation for session-save dedup, which `structureToken` cannot drive (it survives activation). Every mutator
    /// goes through `finishMutation()`/`finishContentMutation()` except `activateTab`'s non-reopen path, which bumps it directly.
    private(set) var durableRevision: UInt64 = 0

    init(spaceId: UUID, state: SpaceTabState) {
        self.spaceId = spaceId
        self.state = SpaceTabStateRepair.repaired(state)
        self.index = SidebarNodeIndex(tree: self.state.tree)
    }

    mutating func activateTab(_ tabId: UUID) {
        guard let tab = storedTab(tabId) else { return }
        // Activation only mutates activeTabId / activationHistory, both non-structural (the rendered
        // row set is unchanged), so the structure token must survive. The one exception is reopening a
        // closed pinned/bookmarked tab: flipping `isClosed` adds a row, which IS structural.
        var reopenedClosedTab = false
        if tab.isClosed {
            guard tab.isPinned || tab.isBookmarked,
                  updateTab(tabId, in: &state.tree, mutate: { $0.isClosed = false }) else { return }
            reopenedClosedTab = true
        }
        // Capture before any mutation so the bump guard sees the full activation delta.
        let previousActiveTabId = state.activeTabId
        let previousHistory = state.activationHistory
        promoteActive(tabId)
        if reopenedClosedTab {
            finishMutation()
        } else if state.activeTabId != previousActiveTabId || state.activationHistory != previousHistory {
            // Activation is non-structural (no finishMutation), but activeTabId/activationHistory are
            // durable, bump so the change persists. Guarded so re-activating the already-active tab,
            // which mutates nothing, doesn't trigger a spurious save.
            durableRevision &+= 1
        }
    }

    mutating func createTab(_ tab: Tab, activate: Bool) {
        var storedTab = StoredTab(tab)
        if storedTab.isPinned {
            storedTab.isBookmarked = false
        }
        // A closed pinned or bookmarked tab is a sidebar placeholder, as one comes back from Undo.
        if storedTab.isPinned || storedTab.isBookmarked || !storedTab.isClosed {
            let section = section(for: storedTab)
            insert(.tab(storedTab), toFolder: nil, section: section, index: rootNodes(in: section).count, in: &state.tree)
        }
        if activate {
            promoteActive(storedTab.id)
        }
        finishMutation()
    }

    /// Pushes the current active tab onto the activation history and makes `id` the active tab.
    private mutating func promoteActive(_ id: UUID) {
        if let activeTabId = state.activeTabId, activeTabId != id {
            state.activationHistory.removeAll { $0 == activeTabId }
            state.activationHistory.insert(activeTabId, at: 0)
            if state.viewedAt[activeTabId] != nil { state.viewedAt[activeTabId] = Date() }
        }
        state.activationHistory.removeAll { $0 == id }
        state.activeTabId = id
    }

    mutating func moveNode(_ nodeId: UUID, toFolder parentFolderId: UUID?, section: TabTreeItem.Section, index insertionIndex: Int) {
        moveNode(nodeId, toFolder: parentFolderId, section: section, insert: .index(insertionIndex))
    }

    mutating func moveNode(
        _ nodeId: UUID,
        toFolder parentFolderId: UUID?,
        section: TabTreeItem.Section,
        insert position: SidebarInsertPosition
    ) {
        guard section != .bookmarked else { return }
        if let parentFolderId, parentFolderId == nodeId || isDescendant(parentFolderId, of: nodeId) {
            return
        }
        if let moved = node(nodeId), !canNestFolder(height: Self.folderHeight(moved), in: parentFolderId) { return }
        guard let removed = removeNode(nodeId, from: &state.tree) else { return }
        let targetSection = parentFolderId.flatMap { self.section(of: $0) } ?? section
        var updatedNode = removed
        normalize(&updatedNode, for: targetSection)
        let insertionIndex = resolvedInsertIndex(position, parentFolderId: parentFolderId, section: targetSection, excluding: nodeId)
        insert(updatedNode, toFolder: parentFolderId, section: targetSection, index: insertionIndex, in: &state.tree)
        finishMutation()
    }

    mutating func setPinned(_ tabId: UUID, pinned: Bool) {
        setExclusiveFlag(tabId) { tab in
            tab.isPinned = pinned
            if pinned { tab.isBookmarked = false }
        }
    }

    mutating func setBookmarked(_ tabId: UUID, bookmarked: Bool) {
        setExclusiveFlag(tabId) { tab in
            tab.isBookmarked = bookmarked
            if bookmarked { tab.isPinned = false }
        }
    }

    /// Re-homes a root tab after toggling one of the mutually-exclusive pinned/bookmarked flags:
    /// pull the node out, apply the flag change, then re-insert into its (possibly new) section.
    private mutating func setExclusiveFlag(_ tabId: UUID, _ apply: (inout StoredTab) -> Void) {
        guard case var .tab(tab)? = removeNode(tabId, from: &state.tree) else { return }
        apply(&tab)
        tab.syncHomeSnapshot()
        let section = section(for: tab)
        if tab.isBookmarked || !tab.isClosed {
            insert(.tab(tab), toFolder: nil, section: section, index: rootNodes(in: section).count, in: &state.tree)
        }
        finishMutation()
    }

    mutating func setTabHomeURL(_ tabId: UUID, url: URL?) {
        guard updateTab(tabId, in: &state.tree, mutate: { tab in
            if let url {
                // The current page's title and favicon describe only that page: another home starts
                // bare and takes its own once the tab opens it.
                if tab.url == url.absoluteString { tab.captureHomeSnapshot() } else { tab.clearHomeSnapshot() }
                tab.homeURL = url.absoluteString
                if tab.isClosed { tab.restoreHomeSnapshot() }
            } else {
                tab.clearHomeSnapshot()
            }
        }) else { return }
        finishMutation()
    }

    mutating func renameTab(_ tabId: UUID, title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let customTitle = trimmed?.isEmpty == false ? trimmed : nil
        guard storedTab(tabId)?.customTitle != customTitle,
              updateTab(tabId, in: &state.tree, mutate: { $0.customTitle = customTitle }) else { return }
        finishContentMutation()
    }

    /// A folder created inside another lands first among its children, in the parent's section; a root one lands last.
    mutating func createFolder(_ folder: TabFolder, section: TabTreeItem.Section, parentFolderId: UUID? = nil) {
        guard section != .bookmarked, canNestFolder(height: 1, in: parentFolderId) else { return }
        let targetSection = parentFolderId.flatMap { self.section(of: $0) } ?? section
        insert(
            .folder(StoredFolder(folder, children: [])),
            toFolder: parentFolderId,
            section: targetSection,
            index: parentFolderId == nil ? rootNodes(in: targetSection).count : 0,
            in: &state.tree
        )
        finishMutation()
    }

    mutating func updateFolder(_ folderId: UUID, name: String, color: String, isCollapsed: Bool) {
        guard updateFolder(folderId, in: &state.tree, mutate: {
            $0.name = name
            $0.color = color
            $0.isCollapsed = isCollapsed
        }) else { return }
        finishContentMutation()
    }

    /// Rearranges a split's own panes: ratios, orientations or places.
    mutating func setSplitLayout(_ folderId: UUID, layout: SplitLayout) {
        let previousOrder = folder(id: folderId)?.splitLayout?.paneIds
        guard updateFolder(folderId, in: &state.tree, mutate: { $0.splitLayout = layout }) else { return }
        // A new reading order reorders the children, which repair does.
        if previousOrder == layout.paneIds { finishContentMutation() } else { finishMutation() }
    }

    mutating func setFolderCollapsed(_ folderId: UUID, collapsed: Bool) {
        guard updateFolder(folderId, in: &state.tree, mutate: { $0.isCollapsed = collapsed }) else { return }
        finishContentMutation()
    }

    mutating func setFolderLock(_ folderId: UUID, lock: FolderLock?) {
        guard folder(id: folderId)?.isSplit == false,
              updateFolder(folderId, in: &state.tree, mutate: {
                  $0.lock = lock
                  $0.isUnlocked = false
              }) else { return }
        finishContentMutation()
    }

    mutating func setFolderAllowsBiometrics(_ folderId: UUID, allowsBiometrics: Bool) {
        guard updateFolder(folderId, in: &state.tree, mutate: { $0.lock?.allowsBiometrics = allowsBiometrics }) else { return }
        finishContentMutation()
    }

    mutating func setFolderUnlocked(_ folderId: UUID, unlocked: Bool) {
        guard folder(id: folderId)?.lock != nil,
              updateFolder(folderId, in: &state.tree, mutate: {
                  $0.isUnlocked = unlocked
                  if unlocked { $0.isCollapsed = false }
              }) else { return }
        finishContentMutation()
    }

    mutating func closeTab(_ tabId: UUID) {
        guard let tab = storedTab(tabId),
              updateTab(tabId, in: &state.tree, mutate: { Self.closePersistentTabSnapshot(&$0) }) else { return }

        // A pinned or bookmarked tab stays as a placeholder; any other leaf is dropped by the
        // repair, so a folder it was the last child of goes with it.
        if !tab.isPinned, !tab.isBookmarked,
           let folderId = index.parentFolderId(for: tabId), folderChildCount(folderId) == 1 {
            _ = removeNode(folderId, from: &state.tree)
        }

        reselectActiveTab(excluding: [tabId])
        finishMutation()
    }

    /// Moves the active-tab selection off any excluded tab (most recently activated open tab first,
    /// then sidebar order) and prunes the excluded ids from the activation history.
    private mutating func reselectActiveTab(excluding excludedIds: Set<UUID>) {
        if let activeTabId = state.activeTabId, excludedIds.contains(activeTabId) {
            let orderedOpenIds = orderedOpenTabIds(excluding: excludedIds)
            let openIds = Set(orderedOpenIds)
            state.activeTabId = state.activationHistory.first { openIds.contains($0) } ?? orderedOpenIds.first
        }
        state.activationHistory.removeAll { excludedIds.contains($0) }
    }

    /// The folder's children take its place, in its own parent.
    mutating func deleteFolder(_ folderId: UUID) {
        let parentFolderId = index.parentFolderId(for: folderId)
        guard let section = self.section(of: folderId),
              let position = index.nodePathById[folderId]?.indexes.last,
              let removed = removeNode(folderId, from: &state.tree),
              case let .folder(folder) = removed else {
            return
        }
        for (offset, child) in folder.children.enumerated() {
            var updatedChild = child
            normalize(&updatedChild, for: section)
            insert(updatedChild, toFolder: parentFolderId, section: section, index: position + offset, in: &state.tree)
        }
        finishMutation()
    }

    mutating func moveTabToBookmarked(_ tabId: UUID, insert position: SidebarInsertPosition) {
        let sourceFolderId = index.parentFolderId(for: tabId)
        guard var node = removeNode(tabId, from: &state.tree),
              case var .tab(tab) = node else {
            return
        }
        tab.isBookmarked = true
        tab.isPinned = false
        tab.syncHomeSnapshot()
        node = .tab(tab)

        if let sourceFolderId { removeIfEmptied(sourceFolderId) }

        let insertionIndex = resolvedInsertIndex(position, parentFolderId: nil, section: .bookmarked, excluding: tabId)
        insert(node, toFolder: nil, section: .bookmarked, index: insertionIndex, in: &state.tree)
        finishMutation()
    }

    mutating func groupTabs(sourceTabId: UUID, targetTabId: UUID) {
        guard sourceTabId != targetTabId,
              let sourceTab = storedTab(sourceTabId),
              let targetTab = storedTab(targetTabId),
              !sourceTab.isClosed,
              !targetTab.isClosed,
              !sourceTab.isBookmarked,
              !targetTab.isBookmarked else {
            return
        }
        let folderIds = [index.parentFolderId(for: sourceTabId), index.parentFolderId(for: targetTabId)].compactMap { $0 }
        if folderIds.contains(where: { folder(id: $0)?.isSplit == true }) { return }

        if let targetFolderId = index.parentFolderId(for: targetTabId) {
            moveNode(sourceTabId, toFolder: targetFolderId, section: section(for: targetTab), index: folderChildCount(targetFolderId))
            return
        }

        if let sourceFolderId = index.parentFolderId(for: sourceTabId) {
            moveNode(targetTabId, toFolder: sourceFolderId, section: section(for: sourceTab), index: folderChildCount(sourceFolderId))
            return
        }

        guard var sourceNode = removeNode(sourceTabId, from: &state.tree),
              var targetNode = removeNode(targetTabId, from: &state.tree) else {
            return
        }
        let section = section(for: targetTab)
        normalize(&sourceNode, for: section)
        normalize(&targetNode, for: section)
        let folder = StoredFolder(id: UUID(), name: "New Folder", color: "#5865f2", isCollapsed: false, children: [sourceNode, targetNode])
        insert(.folder(folder), toFolder: nil, section: section, index: rootNodes(in: section).count, in: &state.tree)
        finishMutation()
    }

    /// Puts `tabId` beside `targetTabId` by halving the target's pane (`tabId` first when `before`), or forms a new split. Splits cannot
    /// nest, so a tab from a folder leaves it; bookmarks never join, and a full split takes no new tab.
    mutating func splitTab(_ tabId: UUID, at targetTabId: UUID, vertical: Bool, before: Bool) {
        guard tabId != targetTabId,
              let tab = storedTab(tabId), let target = storedTab(targetTabId),
              !tab.isClosed, !target.isClosed, !tab.isBookmarked, !target.isBookmarked else {
            return
        }
        let section = section(for: target)
        if let folderId = index.parentFolderId(for: targetTabId), let layout = folder(id: folderId)?.splitLayout {
            let joins = !layout.paneIds.contains(tabId)
            guard !joins || layout.paneIds.count < SplitLayout.maxPanes else { return }
            if joins {
                let sourceFolderId = index.parentFolderId(for: tabId)
                guard var node = removeNode(tabId, from: &state.tree) else { return }
                if let sourceFolderId { removeIfEmptied(sourceFolderId) }
                normalize(&node, for: section)
                insert(node, toFolder: folderId, section: section, index: .max, in: &state.tree)
            }
            let arranged = (layout.removing(tabId) ?? layout).inserting(tabId, at: targetTabId, vertical: vertical, before: before)
            _ = updateFolder(folderId, in: &state.tree) { $0.splitLayout = arranged }
            finishMutation()
            return
        }
        let sourceFolderIds = [index.parentFolderId(for: targetTabId), index.parentFolderId(for: tabId)].compactMap { $0 }
        let anchorId = sourceFolderIds.first ?? targetTabId
        let rootIdsBefore = rootNodeIds(in: section)
        guard var targetNode = removeNode(targetTabId, from: &state.tree),
              var tabNode = removeNode(tabId, from: &state.tree) else {
            return
        }
        for folderId in sourceFolderIds { removeIfEmptied(folderId) }
        normalize(&targetNode, for: section)
        normalize(&tabNode, for: section)
        // Lands where the target was, or right after the folder it came from.
        let survivors = Set(rootNodeIds(in: section))
        let anchorIndex = rootIdsBefore.firstIndex(of: anchorId) ?? rootIdsBefore.count
        let insertionIndex = rootIdsBefore.prefix(anchorIndex + 1).filter(survivors.contains).count
        let folder = StoredFolder(
            id: UUID(), name: "", color: "#5865f2", isCollapsed: false, children: [targetNode, tabNode],
            splitLayout: SplitLayout.pane(tabId: targetTabId).inserting(tabId, at: targetTabId, vertical: vertical, before: before)
        )
        insert(.folder(folder), toFolder: nil, section: section, index: insertionIndex, in: &state.tree)
        finishMutation()
    }

    /// Puts `tabId` in the place of the `targetTabId` pane, and the target in the list right under
    /// the split. Two panes of the same split trade places instead.
    mutating func replaceSplitPane(_ targetTabId: UUID, with tabId: UUID) {
        guard tabId != targetTabId,
              let folderId = index.parentFolderId(for: targetTabId),
              let layout = folder(id: folderId)?.splitLayout,
              let tab = storedTab(tabId), !tab.isClosed, !tab.isBookmarked else {
            return
        }
        let arranged = layout.mappingPanes { $0 == targetTabId ? tabId : $0 == tabId ? targetTabId : $0 }
        if !layout.paneIds.contains(tabId) {
            let section = self.section(of: folderId) ?? .unpinned
            let sourceFolderId = index.parentFolderId(for: tabId)
            guard var incoming = removeNode(tabId, from: &state.tree),
                  var outgoing = removeNode(targetTabId, from: &state.tree) else {
                return
            }
            if let sourceFolderId { removeIfEmptied(sourceFolderId) }
            normalize(&incoming, for: section)
            normalize(&outgoing, for: section)
            insert(incoming, toFolder: folderId, section: section, index: .max, in: &state.tree)
            let folderIndex = rootNodeIds(in: section).firstIndex(of: folderId) ?? rootNodes(in: section).count
            insert(outgoing, toFolder: nil, section: section, index: folderIndex + 1, in: &state.tree)
        }
        _ = updateFolder(folderId, in: &state.tree) { $0.splitLayout = arranged }
        finishMutation()
    }

    mutating func removeTabForTransfer(_ tabId: UUID) -> StoredSidebarNode? {
        guard let removed = removeNode(tabId, from: &state.tree) else { return nil }
        reselectActiveTab(excluding: [tabId])
        finishMutation()
        return removed
    }

    mutating func removeFolder(_ folderId: UUID) -> StoredSidebarNode? {
        guard let removed = removeNode(folderId, from: &state.tree) else { return nil }
        reselectActiveTab(excluding: tabIds(in: removed))
        finishMutation()
        return removed
    }

    /// Bulk import: one repair for the whole batch, and no tab becomes active, so nothing starts
    /// loading behind the onboarding.
    mutating func appendImportedNodes(_ nodes: [StoredSidebarNode], section: TabTreeItem.Section) {
        for node in nodes {
            var updatedNode = node
            let targetSection: TabTreeItem.Section = isBookmarkedTab(node) ? .bookmarked : section
            normalizeTransferred(&updatedNode, section: targetSection, allowsPinnedTabs: true, preservesBookmark: true)
            insert(updatedNode, toFolder: nil, section: targetSection, index: rootNodes(in: targetSection).count, in: &state.tree)
        }
        finishMutation()
    }

    mutating func appendTransferredNode(
        _ node: StoredSidebarNode,
        section: TabTreeItem.Section,
        allowsPinnedTabs: Bool,
        preservesBookmark: Bool
    ) {
        var updatedNode = node
        let targetSection: TabTreeItem.Section = preservesBookmark && isBookmarkedTab(node)
            ? .bookmarked
            : (allowsPinnedTabs ? section : .unpinned)
        normalizeTransferred(
            &updatedNode,
            section: targetSection,
            allowsPinnedTabs: allowsPinnedTabs,
            preservesBookmark: preservesBookmark
        )
        insert(updatedNode, toFolder: nil, section: targetSection, index: rootNodes(in: targetSection).count, in: &state.tree)
        if state.activeTabId == nil {
            state.activeTabId = firstOpenTabId(in: updatedNode)
        }
        finishMutation()
    }

    mutating func updateTab(_ updatedTab: Tab) {
        // Runtime fields arrive via the overlay, so a progress tick re-applies identical durable fields: one walk captures the old value and
        // detects a durable change, and finishMutation() (repair plus index rebuild) is skipped when nothing durable changed.
        var durablyChanged = false
        var shapeChanged = false
        guard updateTab(updatedTab.id, in: &state.tree, mutate: { tab in
            let previous = tab
            tab.url = updatedTab.url?.absoluteString
            tab.title = updatedTab.title
            tab.faviconDataURL = updatedTab.faviconDataURL
            tab.faviconDominantColor = updatedTab.faviconDominantColor
            tab.isPinned = updatedTab.isPinned
            tab.isBookmarked = updatedTab.isBookmarked
            tab.isClosed = updatedTab.isClosed
            tab.homeURL = updatedTab.homeURL?.absoluteString
            tab.homeTitle = updatedTab.homeTitle
            tab.homeFaviconDataURL = updatedTab.homeFaviconDataURL
            tab.homeFaviconDominantColor = updatedTab.homeFaviconDominantColor
            tab.cwd = updatedTab.cwd
            durablyChanged = tab != previous
            shapeChanged = tab.isPinned != previous.isPinned
                || tab.isBookmarked != previous.isBookmarked
                || tab.isClosed != previous.isClosed
        }) else { return }
        guard durablyChanged else { return }
        guard shapeChanged else {
            finishContentMutation()
            return
        }
        finishMutation()
    }

    func tab(id tabId: UUID) -> Tab? {
        guard let storedTab = storedTab(tabId) else { return nil }
        return Tab(storedTab, spaceId: spaceId, groupId: index.parentFolderId(for: tabId))
    }

    func folder(id folderId: UUID) -> TabFolder? {
        guard let node = node(folderId),
              case let .folder(folder) = node else {
            return nil
        }
        return TabFolder(folder, spaceId: spaceId)
    }

    /// The split holding `tabId`.
    func splitGroup(containing tabId: UUID) -> SplitGroup? {
        guard let folderId = index.parentFolderId(for: tabId),
              let node = node(folderId), case let .folder(folder) = node,
              let layout = folder.splitLayout else { return nil }
        return SplitGroup(folderId: folderId, layout: layout)
    }

    func containsNode(id nodeId: UUID) -> Bool {
        index.nodePathById[nodeId] != nil
    }

    func rootNodeIds(in section: TabTreeItem.Section) -> [UUID] {
        rootNodes(in: section).map(\.id)
    }

    /// The password-protected folder holding `nodeId` at any depth, a locked one first: a locked
    /// outer folder hides everything inside it, unlocked inner folders included.
    func protectingFolder(of nodeId: UUID) -> TabFolder? {
        var protecting: TabFolder?
        var parentId = index.parentFolderId(for: nodeId)
        while let id = parentId, let folder = folder(id: id) {
            if folder.isLocked { return folder }
            if folder.lock != nil, protecting == nil { protecting = folder }
            parentId = index.parentFolderId(for: id)
        }
        return protecting
    }

    /// Whether a folder subtree `height` folders deep fits under `parentFolderId` (nil: the root)
    /// without passing `maxFolderDepth`, a root folder being at depth 1.
    func canNestFolder(height: Int, in parentFolderId: UUID?) -> Bool {
        let parentDepth = parentFolderId.flatMap { index.nodePathById[$0]?.indexes.count } ?? 0
        return parentDepth + height <= Self.maxFolderDepth
    }

    nonisolated static let maxFolderDepth = 5

    /// How many folders deep `node` goes, itself included: 0 for a tab.
    static func folderHeight(_ node: StoredSidebarNode) -> Int {
        guard case let .folder(folder) = node else { return 0 }
        return 1 + folder.children.reduce(0) { max($0, folderHeight($1)) }
    }

    /// The folders inside `folderId`, at any depth, that have a lock.
    func lockedFolderIds(inFolder folderId: UUID) -> [UUID] {
        guard let node = node(folderId), case let .folder(folder) = node else { return [] }
        var ids: [UUID] = []
        func visit(_ nodes: [StoredSidebarNode]) {
            for case let .folder(child) in nodes {
                if child.lock != nil { ids.append(child.id) }
                visit(child.children)
            }
        }
        visit(folder.children)
        return ids
    }

    func tabIds(inFolder folderId: UUID) -> [UUID] {
        guard let node = node(folderId), case let .folder(folder) = node else { return [] }
        return tabIds(in: folder.children)
    }

    private mutating func finishMutation() {
        let interval = PerfSignposts.browserState.beginInterval("repairAndIndex")
        state = SpaceTabStateRepair.repaired(state)
        index = SidebarNodeIndex(tree: state.tree)
        structureToken = UUID()
        durableRevision &+= 1
        PerfSignposts.browserState.endInterval("repairAndIndex", interval)
    }

    /// Content-only rewrite: the tree shape is untouched, so the index stays valid and state repair would be an identity. Keeps the
    /// structure token and lets contentRevision refresh the projection memos.
    private mutating func finishContentMutation() {
        contentRevision &+= 1
        durableRevision &+= 1
    }

    private func orderedOpenTabIds(excluding excludedIds: Set<UUID> = []) -> [UUID] {
        var result: [UUID] = []
        state.tree.forEachOpenTabId(excluding: excludedIds) { result.append($0) }
        return result
    }

    private func section(for tab: StoredTab) -> TabTreeItem.Section {
        .forTab(isBookmarked: tab.isBookmarked, isPinned: tab.isPinned)
    }

    func section(of nodeId: UUID) -> TabTreeItem.Section? {
        guard let path = index.nodePathById[nodeId] else { return nil }
        switch path.head {
        case .pinned:
            return .pinned
        case .unpinned:
            return .unpinned
        case .bookmarked:
            return .bookmarked
        }
    }

    /// The three root sections of the sidebar tree, in display order. Dispatchers loop this
    /// instead of spelling out the pinned/unpinned/bookmarked triple.
    private static let sectionKeyPaths: [WritableKeyPath<StoredSidebarTree, [StoredSidebarNode]>] = [
        \.pinned, \.unpinned, \.bookmarked
    ]

    private static func sectionKeyPath(for section: TabTreeItem.Section) -> WritableKeyPath<StoredSidebarTree, [StoredSidebarNode]> {
        switch section {
        case .pinned:
            return \.pinned
        case .unpinned:
            return \.unpinned
        case .bookmarked:
            return \.bookmarked
        }
    }

    private func rootNodes(in section: TabTreeItem.Section) -> [StoredSidebarNode] {
        state.tree[keyPath: Self.sectionKeyPath(for: section)]
    }

    /// A folder its last tab left goes too.
    private mutating func removeIfEmptied(_ folderId: UUID) {
        guard folderChildCount(folderId) == 0 else { return }
        _ = removeNode(folderId, from: &state.tree)
    }

    private func folderChildCount(_ folderId: UUID) -> Int {
        guard let node = node(folderId), case let .folder(folder) = node else { return 0 }
        return folder.children.count
    }

    func storedTab(_ tabId: UUID) -> StoredTab? {
        guard let node = node(tabId), case let .tab(tab) = node else { return nil }
        return tab
    }

    /// Descends `index` to the node's recorded path, checking the id at the leaf: the index can be
    /// stale mid-mutation (between a removal and `finishMutation()`), so a miss falls back to a walk.
    private func node(_ nodeId: UUID) -> StoredSidebarNode? {
        if let path = index.nodePathById[nodeId], let node = node(at: path), node.id == nodeId {
            return node
        }
        for keyPath in Self.sectionKeyPaths {
            if let found = node(nodeId, in: state.tree[keyPath: keyPath]) { return found }
        }
        return nil
    }

    private func node(at path: SidebarNodeIndex.NodePath) -> StoredSidebarNode? {
        var siblings: [StoredSidebarNode]
        switch path.head {
        case .pinned:
            siblings = state.tree.pinned
        case .unpinned:
            siblings = state.tree.unpinned
        case .bookmarked:
            siblings = state.tree.bookmarked
        }
        var node: StoredSidebarNode?
        for position in path.indexes {
            if let node {
                guard case let .folder(folder) = node else { return nil }
                siblings = folder.children
            }
            guard position < siblings.count else { return nil }
            node = siblings[position]
        }
        return node
    }

    private func node(_ nodeId: UUID, in nodes: [StoredSidebarNode]) -> StoredSidebarNode? {
        for node in nodes {
            if node.id == nodeId { return node }
            if case let .folder(folder) = node,
               let found = self.node(nodeId, in: folder.children) {
                return found
            }
        }
        return nil
    }

    private func resolvedInsertIndex(
        _ position: SidebarInsertPosition,
        parentFolderId: UUID?,
        section: TabTreeItem.Section,
        excluding excludedId: UUID
    ) -> Int {
        let siblings: [UUID]
        if let parentFolderId {
            siblings = childIds(in: parentFolderId).filter { $0 != excludedId }
        } else {
            siblings = rootNodes(in: section).map(\.id).filter { $0 != excludedId }
        }

        switch position {
        case let .index(index):
            return max(0, min(index, siblings.count))
        case let .anchored(fallbackIndex, insertBeforeId, insertAfterId):
            if let insertBeforeId,
               let beforeIndex = siblings.firstIndex(of: insertBeforeId) {
                return beforeIndex
            }
            if let insertAfterId,
               let afterIndex = siblings.firstIndex(of: insertAfterId) {
                return afterIndex + 1
            }
            return max(0, min(fallbackIndex, siblings.count))
        }
    }

    private func childIds(in folderId: UUID) -> [UUID] {
        guard let node = node(folderId), case let .folder(folder) = node else { return [] }
        return folder.children.map(\.id)
    }

    private func normalize(_ node: inout StoredSidebarNode, for section: TabTreeItem.Section) {
        switch node {
        case var .tab(tab):
            tab.isPinned = section == .pinned
            tab.isBookmarked = section == .bookmarked
            if tab.isClosed && section == .unpinned {
                tab.isClosed = false
            }
            tab.syncHomeSnapshot()
            node = .tab(tab)
        case var .folder(folder):
            for index in folder.children.indices {
                normalize(&folder.children[index], for: section)
            }
            node = .folder(folder)
        }
    }

    private func normalizeTransferred(
        _ node: inout StoredSidebarNode,
        section: TabTreeItem.Section,
        allowsPinnedTabs: Bool,
        preservesBookmark: Bool
    ) {
        switch node {
        case var .tab(tab):
            if !preservesBookmark {
                tab.isBookmarked = false
            }
            if !allowsPinnedTabs {
                tab.isPinned = false
            } else {
                tab.isPinned = !tab.isBookmarked && section == .pinned
            }
            tab.syncHomeSnapshot()
            node = .tab(tab)
        case var .folder(folder):
            for index in folder.children.indices {
                normalizeTransferred(
                    &folder.children[index],
                    section: section,
                    allowsPinnedTabs: allowsPinnedTabs,
                    preservesBookmark: preservesBookmark
                )
            }
            node = .folder(folder)
        }
    }

    private func tabIds(in node: StoredSidebarNode) -> Set<UUID> {
        Set(tabIds(in: [node]))
    }

    private func tabIds(in nodes: [StoredSidebarNode]) -> [UUID] {
        nodes.flatMap { node -> [UUID] in
            switch node {
            case let .tab(tab):
                return [tab.id]
            case let .folder(folder):
                return tabIds(in: folder.children)
            }
        }
    }

    private func isBookmarkedTab(_ node: StoredSidebarNode) -> Bool {
        guard case let .tab(tab) = node else { return false }
        return tab.isBookmarked
    }

    private func firstOpenTabId(in node: StoredSidebarNode) -> UUID? {
        switch node {
        case let .tab(tab):
            return tab.isClosed ? nil : tab.id
        case let .folder(folder):
            return folder.children.lazy.compactMap(firstOpenTabId).first
        }
    }

    private static func closePersistentTabSnapshot(_ tab: inout StoredTab) {
        tab.isClosed = true
        tab.restoreHomeSnapshot()
    }

    private func removeNode(_ nodeId: UUID, from tree: inout StoredSidebarTree) -> StoredSidebarNode? {
        for keyPath in Self.sectionKeyPaths {
            if let removed = removeNode(nodeId, from: &tree[keyPath: keyPath]) { return removed }
        }
        return nil
    }

    private func removeNode(_ nodeId: UUID, from nodes: inout [StoredSidebarNode]) -> StoredSidebarNode? {
        withNode(nodeId, in: &nodes) { siblings, index in (result: siblings.remove(at: index), changed: true) }?.result
    }

    /// Finds `nodeId` at any depth and hands its sibling array and position to `body`, rebuilding folders on the way up when it changes.
    /// `body` returning nil means "keep searching" and MUST leave the array untouched.
    private func withNode<R>(
        _ nodeId: UUID,
        in nodes: inout [StoredSidebarNode],
        body: (inout [StoredSidebarNode], Int) -> (result: R, changed: Bool)?
    ) -> (result: R, changed: Bool)? {
        if let index = nodes.firstIndex(where: { $0.id == nodeId }),
           let outcome = body(&nodes, index) {
            return outcome
        }
        for index in nodes.indices {
            guard case var .folder(folder) = nodes[index] else { continue }
            if let outcome = withNode(nodeId, in: &folder.children, body: body) {
                // Writing an unchanged wrapper back would still copy the shared sibling array.
                if outcome.changed { nodes[index] = .folder(folder) }
                return outcome
            }
        }
        return nil
    }

    private func insert(
        _ node: StoredSidebarNode,
        toFolder parentFolderId: UUID?,
        section: TabTreeItem.Section,
        index insertionIndex: Int,
        in tree: inout StoredSidebarTree
    ) {
        if let parentFolderId {
            for keyPath in Self.sectionKeyPaths {
                if insert(node, intoFolder: parentFolderId, index: insertionIndex, nodes: &tree[keyPath: keyPath]) {
                    return
                }
            }
        }

        insert(node, at: insertionIndex, into: &tree[keyPath: Self.sectionKeyPath(for: section)])
    }

    private func insert(_ node: StoredSidebarNode, intoFolder folderId: UUID, index insertionIndex: Int, nodes: inout [StoredSidebarNode]) -> Bool {
        withNode(folderId, in: &nodes) { siblings, index in
            guard case var .folder(folder) = siblings[index] else { return nil }
            insert(node, at: insertionIndex, into: &folder.children)
            siblings[index] = .folder(folder)
            return (result: true, changed: true)
        }?.result ?? false
    }

    private func insert(_ node: StoredSidebarNode, at insertionIndex: Int, into nodes: inout [StoredSidebarNode]) {
        nodes.insert(node, at: max(0, min(insertionIndex, nodes.count)))
    }

    private func isDescendant(_ candidateId: UUID, of folderId: UUID) -> Bool {
        guard let candidatePath = index.nodePathById[candidateId],
              let folderPath = index.nodePathById[folderId],
              candidatePath.head == folderPath.head,
              candidatePath.indexes.count > folderPath.indexes.count else {
            return false
        }

        return zip(folderPath.indexes, candidatePath.indexes).allSatisfy(==)
    }

    /// Whether the folder was found and `mutate` changed it.
    private func updateFolder(_ folderId: UUID, in tree: inout StoredSidebarTree, mutate: (inout StoredFolder) -> Void) -> Bool {
        for keyPath in Self.sectionKeyPaths {
            if let changed = updateFolder(folderId, in: &tree[keyPath: keyPath], mutate: mutate) { return changed }
        }
        return false
    }

    /// nil when the folder is not under `nodes`, otherwise whether `mutate` changed it.
    private func updateFolder(_ folderId: UUID, in nodes: inout [StoredSidebarNode], mutate: (inout StoredFolder) -> Void) -> Bool? {
        withNode(folderId, in: &nodes) { siblings, index in
            guard case var .folder(folder) = siblings[index] else { return nil }
            let previous = folder
            mutate(&folder)
            guard folder != previous else { return (result: false, changed: false) }
            siblings[index] = .folder(folder)
            return (result: true, changed: true)
        }?.result
    }

    private func updateTab(_ tabId: UUID, in tree: inout StoredSidebarTree, mutate: (inout StoredTab) -> Void) -> Bool {
        for keyPath in Self.sectionKeyPaths {
            if updateTab(tabId, in: &tree[keyPath: keyPath], mutate: mutate) { return true }
        }
        return false
    }

    private func updateTab(_ tabId: UUID, in nodes: inout [StoredSidebarNode], mutate: (inout StoredTab) -> Void) -> Bool {
        withNode(tabId, in: &nodes) { siblings, index in
            guard case var .tab(tab) = siblings[index] else { return nil }
            let previous = tab
            mutate(&tab)
            // Runtime ticks rarely change durable fields; skipping the write-back keeps the
            // shared buffers shared instead of re-copied out on every tick.
            guard tab != previous else { return (result: true, changed: false) }
            siblings[index] = .tab(tab)
            return (result: true, changed: true)
        }?.result ?? false
    }
}
