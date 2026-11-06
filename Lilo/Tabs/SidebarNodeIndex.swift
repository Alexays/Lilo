import Foundation

struct SidebarNodeIndex: Sendable, Equatable {
    enum PathHead: Sendable, Equatable {
        case pinned
        case unpinned
        case bookmarked
    }

    struct NodePath: Sendable, Equatable {
        var head: PathHead
        var indexes: [Int]
    }

    var nodePathById: [UUID: NodePath]
    var parentFolderIdById: [UUID: UUID?]
    var tabIds: Set<UUID>

    /// `capacity` sizes the maps up front, usually the node count of the index this one replaces.
    init(tree: StoredSidebarTree, capacity: Int = 0) {
        var builder = Builder()
        builder.nodePathById.reserveCapacity(capacity)
        builder.parentFolderIdById.reserveCapacity(capacity)
        builder.tabIds.reserveCapacity(capacity)
        builder.index(nodes: tree.pinned, head: .pinned, parentFolderId: nil, indexes: [])
        builder.index(nodes: tree.unpinned, head: .unpinned, parentFolderId: nil, indexes: [])
        builder.index(nodes: tree.bookmarked, head: .bookmarked, parentFolderId: nil, indexes: [])

        nodePathById = builder.nodePathById
        parentFolderIdById = builder.parentFolderIdById
        tabIds = builder.tabIds
    }

    func parentFolderId(for nodeId: UUID) -> UUID? {
        parentFolderIdById[nodeId] ?? nil
    }

    private struct Builder {
        var nodePathById: [UUID: NodePath] = [:]
        var parentFolderIdById: [UUID: UUID?] = [:]
        var tabIds = Set<UUID>()

        mutating func index(
            nodes: [StoredSidebarNode],
            head: PathHead,
            parentFolderId: UUID?,
            indexes: [Int]
        ) {
            for (index, node) in nodes.enumerated() {
                guard nodePathById[node.id] == nil else { continue }

                var pathIndexes = indexes
                pathIndexes.reserveCapacity(indexes.count + 1)
                pathIndexes.append(index)
                nodePathById[node.id] = NodePath(head: head, indexes: pathIndexes)
                parentFolderIdById[node.id] = parentFolderId

                switch node {
                case .tab:
                    tabIds.insert(node.id)
                case let .folder(folder):
                    self.index(
                        nodes: folder.children,
                        head: head,
                        parentFolderId: folder.id,
                        indexes: pathIndexes
                    )
                }
            }
        }
    }
}
