import Foundation

struct StoredTab: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var url: String?
    var title: String
    var faviconDataURL: String?
    var faviconDominantColor: String?
    var isPinned: Bool
    var isBookmarked: Bool
    var isClosed: Bool
    var homeURL: String?
    var homeTitle: String?
    var homeFaviconDataURL: String?
    var homeFaviconDominantColor: String?
    var kind = Tab.Kind.web
    var cwd: String?
    var resumeCommand: String?
    /// The name the user gave a pinned or bookmarked tab, shown in the sidebar instead of the page title.
    var customTitle: String?
    /// The page's color for the bars over it, so a tab shown before it loads has it at once.
    var pageColor: String?
    var agentId: String?
    var agentSessionId: String?
}

extension StoredTab {
    private enum CodingKeys: String, CodingKey {
        case id, url, title, faviconDominantColor
        case isPinned, isBookmarked, isClosed
        case homeURL, homeTitle, homeFaviconDominantColor
        case kind, cwd, resumeCommand, customTitle, pageColor, agentId, agentSessionId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        title = try container.decode(String.self, forKey: .title)
        faviconDominantColor = try container.decodeIfPresent(String.self, forKey: .faviconDominantColor)
        isPinned = try container.decode(Bool.self, forKey: .isPinned)
        isBookmarked = try container.decode(Bool.self, forKey: .isBookmarked)
        isClosed = try container.decode(Bool.self, forKey: .isClosed)
        homeURL = try container.decodeIfPresent(String.self, forKey: .homeURL)
        homeTitle = try container.decodeIfPresent(String.self, forKey: .homeTitle)
        homeFaviconDominantColor = try container.decodeIfPresent(String.self, forKey: .homeFaviconDominantColor)
        // Absent in web tabs.
        kind = try container.decodeIfPresent(String.self, forKey: .kind).flatMap(Tab.Kind.init(rawValue:)) ?? .web
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        resumeCommand = try container.decodeIfPresent(String.self, forKey: .resumeCommand)
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        pageColor = try container.decodeIfPresent(String.self, forKey: .pageColor)
        agentId = try container.decodeIfPresent(String.self, forKey: .agentId)
        agentSessionId = try container.decodeIfPresent(String.self, forKey: .agentSessionId)
    }

    /// Favicon data URLs (~800 B of base64 each) are deliberately not encoded: they persist in
    /// the per-profile favicons table keyed by host, and restore fills them back in from there.
    /// Only the tiny dominant colors stay in the blob so the sidebar tint never flickers.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(faviconDominantColor, forKey: .faviconDominantColor)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(isBookmarked, forKey: .isBookmarked)
        try container.encode(isClosed, forKey: .isClosed)
        try container.encodeIfPresent(homeURL, forKey: .homeURL)
        try container.encodeIfPresent(homeTitle, forKey: .homeTitle)
        try container.encodeIfPresent(homeFaviconDominantColor, forKey: .homeFaviconDominantColor)
        if kind != .web { try container.encode(kind.rawValue, forKey: .kind) }
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(resumeCommand, forKey: .resumeCommand)
        try container.encodeIfPresent(customTitle, forKey: .customTitle)
        try container.encodeIfPresent(pageColor, forKey: .pageColor)
        try container.encodeIfPresent(agentId, forKey: .agentId)
        try container.encodeIfPresent(agentSessionId, forKey: .agentSessionId)
    }
}

extension StoredTab {
    /// Snapshot the current url/title/favicon as the "home" base. Pinned and bookmarked
    /// tabs share this contract: the snapshot is what `restoreHomeSnapshot()` returns to
    /// when the tab is closed.
    mutating func captureHomeSnapshot() {
        homeURL = url
        homeTitle = title
        homeFaviconDataURL = faviconDataURL
        homeFaviconDominantColor = faviconDominantColor
    }

    /// Drop the home base, used when a tab reverts to a regular (ephemeral) tab.
    mutating func clearHomeSnapshot() {
        homeURL = nil
        homeTitle = nil
        homeFaviconDataURL = nil
        homeFaviconDominantColor = nil
    }

    /// Restore the live url/title/favicon from the home snapshot. No-op for tabs without
    /// a home base (regular tabs), which keeps their last-navigated state.
    mutating func restoreHomeSnapshot() {
        guard let homeURL else { return }
        url = homeURL
        title = homeTitle ?? Tab.fallbackTitle(for: URL(string: homeURL))
        faviconDataURL = homeFaviconDataURL
        faviconDominantColor = homeFaviconDominantColor
    }

    /// Pinned and bookmarked tabs keep a home URL to restore on close, captured once and kept across pinned/bookmarked transitions.
    /// Call after any change to `isPinned`/`isBookmarked` so every pin path stays consistent.
    mutating func syncHomeSnapshot() {
        if isPinned || isBookmarked {
            if homeURL == nil { captureHomeSnapshot() }
        } else {
            clearHomeSnapshot()
            // A regular tab has no rename entry to change it back.
            customTitle = nil
        }
    }
}

struct StoredFolder: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var color: String
    var isCollapsed: Bool
    var children: [StoredSidebarNode]
    /// Set on a split view, whose children are exactly its panes: two to four open tabs, in the
    /// layout's reading order. Repair restores that or dissolves the split.
    var splitLayout: SplitLayout?
    var lock: FolderLock?
    /// Runtime only: never encoded, so every launch starts with protected folders locked.
    var isUnlocked = false

    var isSplit: Bool { splitLayout != nil }
}

extension StoredFolder {
    private enum CodingKeys: String, CodingKey {
        case id, name, color, isCollapsed, children, splitLayout, lock
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        color = try container.decode(String.self, forKey: .color)
        isCollapsed = try container.decode(Bool.self, forKey: .isCollapsed)
        children = try container.decode([StoredSidebarNode].self, forKey: .children)
        splitLayout = try container.decodeIfPresent(SplitLayout.self, forKey: .splitLayout)
        lock = try container.decodeIfPresent(FolderLock.self, forKey: .lock)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(color, forKey: .color)
        try container.encode(isCollapsed, forKey: .isCollapsed)
        try container.encode(children, forKey: .children)
        try container.encodeIfPresent(splitLayout, forKey: .splitLayout)
        try container.encodeIfPresent(lock, forKey: .lock)
    }
}

indirect enum StoredSidebarNode: Codable, Sendable, Equatable, Identifiable {
    case tab(StoredTab)
    case folder(StoredFolder)

    var id: UUID {
        switch self {
        case let .tab(tab):
            tab.id
        case let .folder(folder):
            folder.id
        }
    }
}

struct StoredSidebarTree: Codable, Sendable, Equatable {
    var pinned: [StoredSidebarNode]
    var unpinned: [StoredSidebarNode]
    var bookmarked: [StoredSidebarNode]

    static let empty = StoredSidebarTree(pinned: [], unpinned: [], bookmarked: [])

    /// Depth-first walk of every section, invoking `visit` with the id of each open
    /// (non-closed) tab not present in `excludedIds`, in pinned, unpinned, then bookmarked order.
    func forEachOpenTabId(excluding excludedIds: Set<UUID> = [], _ visit: (UUID) -> Void) {
        StoredSidebarNode.forEachOpenTabId(in: pinned, excluding: excludedIds, visit)
        StoredSidebarNode.forEachOpenTabId(in: unpinned, excluding: excludedIds, visit)
        StoredSidebarNode.forEachOpenTabId(in: bookmarked, excluding: excludedIds, visit)
    }
}

extension StoredSidebarNode {
    /// Depth-first walk of `nodes`, invoking `visit` for each open (non-closed) tab id not in `excludedIds`.
    static func forEachOpenTabId(
        in nodes: [StoredSidebarNode],
        excluding excludedIds: Set<UUID> = [],
        _ visit: (UUID) -> Void
    ) {
        for node in nodes {
            switch node {
            case let .tab(tab):
                if !tab.isClosed && !excludedIds.contains(tab.id) {
                    visit(tab.id)
                }
            case let .folder(folder):
                forEachOpenTabId(in: folder.children, excluding: excludedIds, visit)
            }
        }
    }
}

struct SpaceTabState: Codable, Sendable, Equatable {
    /// Blobs carry no favicon data URLs: they live in the favicons table.
    static let currentVersion = 1

    var version: Int
    var activeTabId: UUID?
    var activationHistory: [UUID]
    var tree: StoredSidebarTree
    /// When each open top-level unpinned tab was last left, or became one: the auto-archive clock.
    /// Repair keeps exactly those tabs, a new one starting now.
    var viewedAt: [UUID: Date]

    init(
        version: Int = Self.currentVersion,
        activeTabId: UUID?,
        activationHistory: [UUID],
        tree: StoredSidebarTree,
        viewedAt: [UUID: Date] = [:]
    ) {
        self.version = version
        self.activeTabId = activeTabId
        self.activationHistory = activationHistory
        self.tree = tree
        self.viewedAt = viewedAt
    }
}

struct SpaceTabProjection: Sendable {
    var tabs: [Tab]
    var folders: [TabFolder]
    var treeItems: [TabTreeItem]
}

enum SpaceTabStateImporter {
    static func importState(
        activeTabId: UUID?,
        activationHistory: [UUID],
        viewedAt: [UUID: Date] = [:],
        tabs: [Tab],
        folders: [TabFolder],
        treeItems: [TabTreeItem],
        spaceId: UUID
    ) -> SpaceTabState {
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.filter { $0.spaceId == spaceId }.map { ($0.id, $0) })
        let foldersById = Dictionary(uniqueKeysWithValues: folders.filter { $0.spaceId == spaceId }.map { ($0.id, $0) })
        let restoredItems = TabTreeItem.restoredSidebarItems(
            spaceId: spaceId,
            tabs: tabs,
            folders: folders,
            persistedItems: treeItems
        )
        let items = restoredItems
            .filter { $0.spaceId == spaceId }
            .sorted(by: TabTreeItem.sidebarOrdering)

        var seenNodeIds = Set<UUID>()
        var tree = StoredSidebarTree(
            pinned: importedNodes(
                parentFolderId: nil,
                section: .pinned,
                items: items,
                tabsById: tabsById,
                foldersById: foldersById,
                seenNodeIds: &seenNodeIds
            ),
            unpinned: importedNodes(
                parentFolderId: nil,
                section: .unpinned,
                items: items,
                tabsById: tabsById,
                foldersById: foldersById,
                seenNodeIds: &seenNodeIds
            ),
            bookmarked: importedNodes(
                parentFolderId: nil,
                section: .bookmarked,
                items: items,
                tabsById: tabsById,
                foldersById: foldersById,
                seenNodeIds: &seenNodeIds
            )
        )

        appendMissingVisibleNodes(
            to: &tree,
            spaceId: spaceId,
            tabs: tabs,
            folders: folders,
            seenNodeIds: &seenNodeIds
        )

        return SpaceTabStateRepair.repaired(SpaceTabState(
            activeTabId: activeTabId,
            activationHistory: activationHistory,
            tree: tree,
            viewedAt: viewedAt
        ))
    }

    private static func importedNodes(
        parentFolderId: UUID?,
        section: TabTreeItem.Section,
        items: [TabTreeItem],
        tabsById: [UUID: Tab],
        foldersById: [UUID: TabFolder],
        seenNodeIds: inout Set<UUID>
    ) -> [StoredSidebarNode] {
        var result: [StoredSidebarNode] = []

        for item in items where item.parentFolderId == parentFolderId && item.section == section {
            guard seenNodeIds.insert(item.itemId).inserted else { continue }

            switch item.kind {
            case .tab:
                guard let tab = tabsById[item.itemId] else { continue }
                result.append(.tab(StoredTab(tab)))
            case .folder:
                guard section != .bookmarked,
                      let folder = foldersById[item.itemId] else {
                    continue
                }
                let children = importedNodes(
                    parentFolderId: folder.id,
                    section: section,
                    items: items,
                    tabsById: tabsById,
                    foldersById: foldersById,
                    seenNodeIds: &seenNodeIds
                )
                result.append(.folder(StoredFolder(folder, children: children)))
            }
        }

        return result
    }

    private static func appendMissingVisibleNodes(
        to tree: inout StoredSidebarTree,
        spaceId: UUID,
        tabs: [Tab],
        folders: [TabFolder],
        seenNodeIds: inout Set<UUID>
    ) {
        let synthesizedItems = TabTreeItem.synthesizedSidebarItems(spaceId: spaceId, tabs: tabs, folders: folders)
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.filter { $0.spaceId == spaceId }.map { ($0.id, $0) })
        let foldersById = Dictionary(uniqueKeysWithValues: folders.filter { $0.spaceId == spaceId }.map { ($0.id, $0) })

        for item in synthesizedItems where item.parentFolderId == nil {
            guard !seenNodeIds.contains(item.itemId) else { continue }

            switch item.kind {
            case .tab:
                guard let tab = tabsById[item.itemId],
                      seenNodeIds.insert(tab.id).inserted else {
                    continue
                }
                append(.tab(StoredTab(tab)), section: item.section, to: &tree)
            case .folder:
                guard item.section != .bookmarked,
                      let folder = foldersById[item.itemId],
                      seenNodeIds.insert(folder.id).inserted else {
                    continue
                }
                append(.folder(StoredFolder(folder, children: [])), section: item.section, to: &tree)
            }
        }
    }

    private static func append(_ node: StoredSidebarNode, section: TabTreeItem.Section, to tree: inout StoredSidebarTree) {
        switch section {
        case .pinned:
            tree.pinned.append(node)
        case .unpinned:
            tree.unpinned.append(node)
        case .bookmarked:
            tree.bookmarked.append(node)
        }
    }
}

extension SpaceTabState {
    func projectedSidebar(spaceId: UUID) -> SpaceTabProjection {
        var projection = SpaceTabProjection(tabs: [], folders: [], treeItems: [])
        appendProjectedSidebar(from: tree.pinned, spaceId: spaceId, section: .pinned, parentFolderId: nil, into: &projection)
        appendProjectedSidebar(from: tree.unpinned, spaceId: spaceId, section: .unpinned, parentFolderId: nil, into: &projection)
        appendProjectedSidebar(from: tree.bookmarked, spaceId: spaceId, section: .bookmarked, parentFolderId: nil, into: &projection)
        return projection
    }

    private func appendProjectedSidebar(
        from nodes: [StoredSidebarNode],
        spaceId: UUID,
        section: TabTreeItem.Section,
        parentFolderId: UUID?,
        into projection: inout SpaceTabProjection
    ) {
        for (index, node) in nodes.enumerated() {
            switch node {
            case let .tab(tab):
                projection.tabs.append(Tab(tab, spaceId: spaceId, groupId: parentFolderId))
                projection.treeItems.append(TabTreeItem(
                    spaceId: spaceId,
                    kind: .tab,
                    itemId: tab.id,
                    parentFolderId: parentFolderId,
                    section: section,
                    sortOrder: index
                ))
            case let .folder(folder):
                projection.folders.append(TabFolder(folder, spaceId: spaceId))
                projection.treeItems.append(TabTreeItem(
                    spaceId: spaceId,
                    kind: .folder,
                    itemId: folder.id,
                    parentFolderId: parentFolderId,
                    section: section,
                    sortOrder: index
                ))
                appendProjectedSidebar(
                    from: folder.children,
                    spaceId: spaceId,
                    section: section,
                    parentFolderId: folder.id,
                    into: &projection
                )
            }
        }
    }
}

extension StoredTab {
    init(_ tab: Tab) {
        self.init(
            id: tab.id,
            url: tab.url?.absoluteString,
            title: tab.title,
            faviconDataURL: tab.faviconDataURL,
            faviconDominantColor: tab.faviconDominantColor,
            isPinned: tab.isPinned,
            isBookmarked: tab.isBookmarked,
            isClosed: tab.isClosed,
            homeURL: tab.homeURL?.absoluteString,
            homeTitle: tab.homeTitle,
            homeFaviconDataURL: tab.homeFaviconDataURL,
            homeFaviconDominantColor: tab.homeFaviconDominantColor,
            kind: tab.kind,
            cwd: tab.cwd,
            resumeCommand: tab.resumeCommand,
            customTitle: tab.customTitle,
            pageColor: tab.pageColor,
            agentId: tab.agentId,
            agentSessionId: tab.agentSessionId
        )
    }
}

extension StoredFolder {
    init(_ folder: TabFolder, children: [StoredSidebarNode]) {
        self.init(
            id: folder.id,
            name: folder.name,
            color: folder.color,
            isCollapsed: folder.isCollapsed,
            children: children,
            splitLayout: folder.splitLayout,
            lock: folder.lock,
            isUnlocked: folder.isUnlocked
        )
    }
}

extension Tab {
    init(_ storedTab: StoredTab, spaceId: UUID, groupId: UUID?) {
        self.init(
            id: storedTab.id,
            url: storedTab.url.flatMap(URL.init(string:)),
            title: storedTab.title,
            faviconDataURL: storedTab.faviconDataURL,
            faviconDominantColor: storedTab.faviconDominantColor,
            isPinned: storedTab.isPinned,
            isBookmarked: storedTab.isBookmarked,
            isClosed: storedTab.isClosed,
            homeURL: storedTab.homeURL.flatMap(URL.init(string:)),
            homeTitle: storedTab.homeTitle,
            homeFaviconDataURL: storedTab.homeFaviconDataURL,
            homeFaviconDominantColor: storedTab.homeFaviconDominantColor,
            groupId: groupId,
            spaceId: spaceId,
            kind: storedTab.kind,
            cwd: storedTab.cwd,
            resumeCommand: storedTab.resumeCommand,
            customTitle: storedTab.customTitle,
            agentId: storedTab.agentId,
            agentSessionId: storedTab.agentSessionId
        )
        pageColor = storedTab.pageColor
    }
}

extension TabFolder {
    init(_ storedFolder: StoredFolder, spaceId: UUID) {
        self.init(
            id: storedFolder.id,
            spaceId: spaceId,
            name: storedFolder.name,
            color: storedFolder.color,
            isCollapsed: storedFolder.isCollapsed,
            splitLayout: storedFolder.splitLayout,
            lock: storedFolder.lock,
            isUnlocked: storedFolder.isUnlocked
        )
    }
}

enum SpaceTabStateCodec {
    static let codec = "bplist"

    static func encode(_ state: SpaceTabState) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(state)
    }

    static func decode(_ data: Data) throws -> SpaceTabState {
        try PropertyListDecoder().decode(SpaceTabState.self, from: data)
    }
}

enum SpaceTabStateRepair {
    static func repaired(_ state: SpaceTabState) -> SpaceTabState {
        var seenNodeIds = Set<UUID>()
        var tree = StoredSidebarTree(
            pinned: repairedNodes(state.tree.pinned, section: .pinned, seenNodeIds: &seenNodeIds),
            unpinned: repairedNodes(state.tree.unpinned, section: .unpinned, seenNodeIds: &seenNodeIds),
            bookmarked: repairedNodes(state.tree.bookmarked, section: .bookmarked, seenNodeIds: &seenNodeIds)
        )

        redistributeRootTabs(in: &tree)
        let openTabIds = openTabIds(in: tree)
        let activeTabId = state.activeTabId.flatMap { openTabIds.contains($0) ? $0 : nil }
        let activationHistory = normalizedActivationHistory(
            state.activationHistory,
            activeTabId: activeTabId,
            openTabIds: openTabIds
        )

        let now = Date()
        var viewedAt: [UUID: Date] = [:]
        for case let .tab(tab) in tree.unpinned where !tab.isClosed {
            viewedAt[tab.id] = state.viewedAt[tab.id] ?? now
        }

        return SpaceTabState(
            version: SpaceTabState.currentVersion,
            activeTabId: activeTabId,
            activationHistory: activationHistory,
            tree: tree,
            viewedAt: viewedAt
        )
    }

    private static func repairedNodes(
        _ nodes: [StoredSidebarNode],
        section: TabTreeItem.Section,
        seenNodeIds: inout Set<UUID>
    ) -> [StoredSidebarNode] {
        var result: [StoredSidebarNode] = []

        for node in nodes {
            guard seenNodeIds.insert(node.id).inserted else { continue }

            switch node {
            case let .tab(tab):
                guard isVisible(tab) else { continue }
                result.append(.tab(tab))
            case var .folder(folder):
                guard section != .bookmarked else { continue }
                folder.children = repairedNodes(folder.children, section: section, seenNodeIds: &seenNodeIds)
                if folder.isSplit {
                    result.append(contentsOf: repairedSplit(folder))
                } else {
                    result.append(.folder(folder))
                }
            }
        }

        return result
    }

    private static func redistributeRootTabs(in tree: inout StoredSidebarTree) {
        var pinned: [StoredSidebarNode] = []
        var unpinned: [StoredSidebarNode] = []
        var bookmarked: [StoredSidebarNode] = []

        // One pass over each source section, in order, classifies folders by the section they come from.
        func classify(_ nodes: [StoredSidebarNode], sourceIsPinned: Bool) {
            for node in nodes {
                switch node {
                case let .tab(tab):
                    switch TabTreeItem.Section.forTab(isBookmarked: tab.isBookmarked, isPinned: tab.isPinned) {
                    case .bookmarked: bookmarked.append(node)
                    case .pinned: pinned.append(node)
                    case .unpinned: unpinned.append(node)
                    }
                case .folder:
                    if sourceIsPinned {
                        pinned.append(node)
                    } else {
                        unpinned.append(node)
                    }
                }
            }
        }

        classify(tree.pinned, sourceIsPinned: true)
        classify(tree.unpinned, sourceIsPinned: false)
        classify(tree.bookmarked, sourceIsPinned: false)

        tree = StoredSidebarTree(pinned: pinned, unpinned: unpinned, bookmarked: bookmarked)
    }

    /// Matches the layout to the panes the split still holds: a pane that left (closed, dragged
    /// out, moved to another space) gives its place up. Anything that cannot be a pane, and every
    /// pane once fewer than two remain, falls back to the list.
    private static func repairedSplit(_ folder: StoredFolder) -> [StoredSidebarNode] {
        var panes: [UUID: StoredSidebarNode] = [:]
        var paneOrder: [UUID] = []
        var spilled: [StoredSidebarNode] = []
        for child in folder.children {
            if case let .tab(tab) = child, !tab.isClosed, paneOrder.count < SplitLayout.maxPanes {
                panes[tab.id] = child
                paneOrder.append(tab.id)
            } else {
                spilled.append(child)
            }
        }
        var layout = folder.splitLayout
        for id in layout?.paneIds ?? [] where panes[id] == nil { layout = layout?.removing(id) }
        for id in paneOrder where layout?.paneIds.contains(id) != true {
            layout = layout.map { $0.inserting(id, at: $0.paneIds[$0.paneIds.count - 1], vertical: false, before: false) } ?? .pane(tabId: id)
        }
        guard let layout, paneOrder.count >= 2 else { return folder.children }
        var split = folder
        split.splitLayout = layout
        split.children = layout.paneIds.compactMap { panes[$0] }
        return [.folder(split)] + spilled
    }

    private static func isVisible(_ tab: StoredTab) -> Bool {
        !tab.isClosed || tab.isPinned || tab.isBookmarked
    }

    private static func openTabIds(in tree: StoredSidebarTree) -> Set<UUID> {
        var result = Set<UUID>()
        tree.forEachOpenTabId { result.insert($0) }
        return result
    }

    private static func normalizedActivationHistory(
        _ activationHistory: [UUID],
        activeTabId: UUID?,
        openTabIds: Set<UUID>
    ) -> [UUID] {
        var seenIds = Set<UUID>()
        var result: [UUID] = []
        for tabId in activationHistory {
            guard tabId != activeTabId,
                  openTabIds.contains(tabId),
                  seenIds.insert(tabId).inserted else {
                continue
            }
            result.append(tabId)
        }
        return result
    }
}
