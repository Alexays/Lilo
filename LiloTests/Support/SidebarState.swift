import Foundation
@testable import Lilo

private func sidebarSection(forPinned pinned: Bool) -> TabTreeItem.Section {
    pinned ? .pinned : .unpinned
}

private func isVisibleSidebarTab(_ tab: Tab, in section: TabTreeItem.Section) -> Bool {
    switch section {
    case .bookmarked:
        return tab.isBookmarked
    case .pinned, .unpinned:
        return !tab.isBookmarked &&
            sidebarSection(forPinned: tab.isPinned) == section &&
            (!tab.isClosed || tab.isPinned)
    }
}

struct SidebarState: Sendable {
    enum NodeKind: Sendable, Equatable {
        case tab
        case folder
    }

    struct Node: Sendable, Equatable, Identifiable {
        var id: UUID
        var kind: NodeKind
        var section: TabTreeItem.Section
        var parentFolderId: UUID?
        var childIds: [UUID]
    }

    private var nodesById: [UUID: Node]
    private var rootIdsBySection: [TabTreeItem.Section: [UUID]]

    init(
        spaceId: UUID,
        tabsById: [UUID: Tab],
        folders: [TabFolder],
        treeItems: [TabTreeItem]
    ) {
        let foldersById = Dictionary(uniqueKeysWithValues: folders.filter { $0.spaceId == spaceId }.map { ($0.id, $0) })
        let sortedItems = treeItems
            .filter { $0.spaceId == spaceId }
            .sorted(by: TabTreeItem.sidebarOrdering)

        var nodes: [UUID: Node] = [:]
        var rootIds: [TabTreeItem.Section: [UUID]] = [.bookmarked: [], .pinned: [], .unpinned: []]
        var childIdsByFolder: [UUID: [UUID]] = [:]
        let folderItems = Dictionary(
            sortedItems.filter { $0.kind == .folder && $0.section != .bookmarked && foldersById[$0.itemId] != nil }.map { ($0.itemId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // A subfolder counts only under a folder that does, in the same section.
        func reachesRoot(_ item: TabTreeItem, depth: Int = 0) -> Bool {
            guard let parentId = item.parentFolderId else { return true }
            guard depth < folderItems.count, let parent = folderItems[parentId], parent.section == item.section else { return false }
            return reachesRoot(parent, depth: depth + 1)
        }
        let folderSectionById = folderItems.compactMapValues { reachesRoot($0) ? $0.section : nil }

        for item in sortedItems {
            switch item.kind {
            case .folder:
                guard folderSectionById[item.itemId] == item.section, folderItems[item.itemId]?.id == item.id else { continue }
                nodes[item.itemId] = Node(
                    id: item.itemId,
                    kind: .folder,
                    section: item.section,
                    parentFolderId: item.parentFolderId,
                    childIds: []
                )
                if let parentFolderId = item.parentFolderId {
                    childIdsByFolder[parentFolderId, default: []].append(item.itemId)
                } else {
                    rootIds[item.section, default: []].append(item.itemId)
                }
            case .tab:
                guard let tab = tabsById[item.itemId],
                      isVisibleSidebarTab(tab, in: item.section) else {
                    continue
                }
                if item.section == .bookmarked {
                    guard item.parentFolderId == nil else { continue }
                    nodes[item.itemId] = Node(
                        id: item.itemId,
                        kind: .tab,
                        section: item.section,
                        parentFolderId: nil,
                        childIds: []
                    )
                    rootIds[item.section, default: []].append(item.itemId)
                    continue
                }
                if let parentFolderId = item.parentFolderId {
                    guard folderSectionById[parentFolderId] == item.section else {
                        continue
                    }
                    nodes[item.itemId] = Node(
                        id: item.itemId,
                        kind: .tab,
                        section: item.section,
                        parentFolderId: parentFolderId,
                        childIds: []
                    )
                    childIdsByFolder[parentFolderId, default: []].append(item.itemId)
                } else {
                    nodes[item.itemId] = Node(
                        id: item.itemId,
                        kind: .tab,
                        section: item.section,
                        parentFolderId: nil,
                        childIds: []
                    )
                    rootIds[item.section, default: []].append(item.itemId)
                }
            }
        }

        for (folderId, childIds) in childIdsByFolder {
            guard var folderNode = nodes[folderId] else { continue }
            folderNode.childIds = childIds
            nodes[folderId] = folderNode
        }

        for tab in tabsById.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) where nodes[tab.id] == nil {
            let section: TabTreeItem.Section = tab.isBookmarked ? .bookmarked : sidebarSection(forPinned: tab.isPinned)
            guard isVisibleSidebarTab(tab, in: section) else { continue }
            nodes[tab.id] = Node(
                id: tab.id,
                kind: .tab,
                section: section,
                parentFolderId: nil,
                childIds: []
            )
            rootIds[section, default: []].append(tab.id)
        }

        nodesById = nodes
        rootIdsBySection = rootIds
    }

    func node(id: UUID) -> Node? {
        nodesById[id]
    }

    func rootNodeIds(in section: TabTreeItem.Section) -> [UUID] {
        rootIdsBySection[section] ?? []
    }

    func childNodeIds(of folderId: UUID) -> [UUID] {
        nodesById[folderId]?.childIds ?? []
    }

    func treeItems(spaceId: UUID) -> [TabTreeItem] {
        var items: [TabTreeItem] = []
        func appendChildren(of node: Node, section: TabTreeItem.Section) {
            guard node.kind == .folder else { return }
            for (childIndex, childId) in node.childIds.enumerated() {
                guard let child = nodesById[childId] else { continue }
                items.append(TabTreeItem(
                    spaceId: spaceId,
                    kind: child.kind == .folder ? .folder : .tab,
                    itemId: child.id,
                    parentFolderId: node.id,
                    section: section,
                    sortOrder: childIndex
                ))
                appendChildren(of: child, section: section)
            }
        }

        for section in [TabTreeItem.Section.bookmarked, .pinned, .unpinned] {
            for (index, nodeId) in rootNodeIds(in: section).enumerated() {
                guard let node = nodesById[nodeId] else { continue }
                items.append(TabTreeItem(
                    spaceId: spaceId,
                    kind: node.kind == .folder ? .folder : .tab,
                    itemId: node.id,
                    parentFolderId: nil,
                    section: section,
                    sortOrder: index
                ))

                appendChildren(of: node, section: section)
            }
        }

        return items
    }

    func invariantsHold(tabsById: [UUID: Tab]) -> Bool {
        let rootIds = Set(rootIdsBySection.values.flatMap { $0 })
        for rootId in rootIds {
            guard let node = nodesById[rootId], node.parentFolderId == nil else {
                return false
            }
        }

        for node in nodesById.values {
            switch node.kind {
            case .folder:
                if let parentFolderId = node.parentFolderId {
                    guard nodesById[parentFolderId]?.childIds.contains(node.id) == true else { return false }
                }
                for childId in node.childIds {
                    guard let child = nodesById[childId],
                          child.parentFolderId == node.id,
                          child.section == node.section else {
                        return false
                    }
                }
            case .tab:
                guard let tab = tabsById[node.id],
                      isVisibleSidebarTab(tab, in: node.section) else {
                    return false
                }
                if let parentFolderId = node.parentFolderId {
                    guard let parent = nodesById[parentFolderId],
                          parent.kind == .folder,
                          parent.section == node.section,
                          parent.childIds.contains(node.id) else {
                        return false
                    }
                }
            }
        }

        return true
    }
}
