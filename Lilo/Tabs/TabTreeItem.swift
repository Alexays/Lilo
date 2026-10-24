import Foundation

struct TabTreeItem: Sendable, Identifiable {
    enum Kind: String, Sendable {
        case tab
        case folder
    }

    enum Section: String, Sendable, Codable {
        case bookmarked
        case pinned
        case unpinned

        /// Single source of the tab-to-section rule: bookmarked wins, then pinned, else unpinned.
        static func forTab(isBookmarked: Bool, isPinned: Bool) -> Section {
            if isBookmarked { return .bookmarked }
            return isPinned ? .pinned : .unpinned
        }
    }

    var id: UUID
    var spaceId: UUID
    var kind: Kind
    var itemId: UUID
    var parentFolderId: UUID?
    var section: Section
    var sortOrder: Int

    init(
        id: UUID = UUID(),
        spaceId: UUID,
        kind: Kind,
        itemId: UUID,
        parentFolderId: UUID?,
        section: Section,
        sortOrder: Int
    ) {
        self.id = id
        self.spaceId = spaceId
        self.kind = kind
        self.itemId = itemId
        self.parentFolderId = parentFolderId
        self.section = section
        self.sortOrder = sortOrder
    }

    var bridgeData: [String: Any] {
        [
            "id": id.uuidString,
            "spaceId": spaceId.uuidString,
            "kind": kind.rawValue,
            "itemId": itemId.uuidString,
            "parentFolderId": parentFolderId?.uuidString as Any,
            "section": section.rawValue,
            "sortOrder": sortOrder
        ]
    }
}

extension TabTreeItem {
    /// Stable sidebar ordering: by section, then parent folder, then sortOrder, then item id.
    static func sidebarOrdering(_ lhs: TabTreeItem, _ rhs: TabTreeItem) -> Bool {
        if lhs.section != rhs.section { return lhs.section.rawValue < rhs.section.rawValue }
        if lhs.parentFolderId != rhs.parentFolderId {
            return (lhs.parentFolderId?.uuidString ?? "") < (rhs.parentFolderId?.uuidString ?? "")
        }
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.itemId.uuidString < rhs.itemId.uuidString
    }

    static func restoredSidebarItems(
        spaceId: UUID,
        tabs: [Tab],
        folders: [TabFolder],
        persistedItems: [TabTreeItem]
    ) -> [TabTreeItem] {
        if hasUsableRootItem(spaceId: spaceId, tabs: tabs, folders: folders, persistedItems: persistedItems) {
            return persistedItems
        }
        return synthesizedSidebarItems(spaceId: spaceId, tabs: tabs, folders: folders)
    }

    static func synthesizedSidebarItems(
        spaceId: UUID,
        tabs: [Tab],
        folders: [TabFolder]
    ) -> [TabTreeItem] {
        var items: [TabTreeItem] = []
        var rootIndexBySection: [Section: Int] = [.bookmarked: 0, .pinned: 0, .unpinned: 0]
        var childIndexByFolderId: [UUID: Int] = [:]
        let foldersById = Dictionary(uniqueKeysWithValues: folders.filter { $0.spaceId == spaceId }.map { ($0.id, $0) })
        let groupedFolderIds = Set(tabs.compactMap(\.groupId))

        for folder in folders where folder.spaceId == spaceId && groupedFolderIds.contains(folder.id) {
            let section = tabs.first { $0.groupId == folder.id }?.isPinned == true ? Section.pinned : .unpinned
            items.append(TabTreeItem(
                spaceId: spaceId,
                kind: .folder,
                itemId: folder.id,
                parentFolderId: nil,
                section: section,
                sortOrder: rootIndexBySection[section, default: 0]
            ))
            rootIndexBySection[section, default: 0] += 1
        }

        for tab in tabs where tab.spaceId == spaceId {
            if tab.isClosed && !tab.isPinned && !tab.isBookmarked {
                continue
            }

            if tab.isBookmarked {
                items.append(TabTreeItem(
                    spaceId: spaceId,
                    kind: .tab,
                    itemId: tab.id,
                    parentFolderId: nil,
                    section: .bookmarked,
                    sortOrder: rootIndexBySection[.bookmarked, default: 0]
                ))
                rootIndexBySection[.bookmarked, default: 0] += 1
                continue
            }

            let section: Section = tab.isPinned ? .pinned : .unpinned
            if let folderId = tab.groupId,
               foldersById[folderId] != nil {
                items.append(TabTreeItem(
                    spaceId: spaceId,
                    kind: .tab,
                    itemId: tab.id,
                    parentFolderId: folderId,
                    section: section,
                    sortOrder: childIndexByFolderId[folderId, default: 0]
                ))
                childIndexByFolderId[folderId, default: 0] += 1
                continue
            }

            items.append(TabTreeItem(
                spaceId: spaceId,
                kind: .tab,
                itemId: tab.id,
                parentFolderId: nil,
                section: section,
                sortOrder: rootIndexBySection[section, default: 0]
            ))
            rootIndexBySection[section, default: 0] += 1
        }

        for folder in folders where folder.spaceId == spaceId && !groupedFolderIds.contains(folder.id) {
            items.append(TabTreeItem(
                spaceId: spaceId,
                kind: .folder,
                itemId: folder.id,
                parentFolderId: nil,
                section: .unpinned,
                sortOrder: rootIndexBySection[.unpinned, default: 0]
            ))
            rootIndexBySection[.unpinned, default: 0] += 1
        }

        return items
    }

    private static func hasUsableRootItem(
        spaceId: UUID,
        tabs: [Tab],
        folders: [TabFolder],
        persistedItems: [TabTreeItem]
    ) -> Bool {
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.filter { $0.spaceId == spaceId }.map { ($0.id, $0) })
        let folderIds = Set(folders.filter { $0.spaceId == spaceId }.map(\.id))
        guard !tabsById.isEmpty || !folderIds.isEmpty else {
            return true
        }

        return persistedItems.contains { item in
            guard item.spaceId == spaceId,
                  item.parentFolderId == nil else {
                return false
            }
            switch item.kind {
            case .folder:
                return item.section != .bookmarked && folderIds.contains(item.itemId)
            case .tab:
                guard let tab = tabsById[item.itemId] else { return false }
                if tab.isBookmarked {
                    return item.section == .bookmarked
                }
                return item.section == (tab.isPinned ? .pinned : .unpinned)
                    && (!tab.isClosed || tab.isPinned)
            }
        }
    }
}
