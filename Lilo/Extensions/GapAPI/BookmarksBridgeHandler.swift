import Foundation
import WebKit

/// chrome.bookmarks gap bridge wrapping BookmarkStore.
@MainActor
final class BookmarksBridgeHandler: GapHandler {
    /// The calling extension's profile store, resolved from its registry.
    private let storeProvider: (ProfileExtensionRegistry) -> BookmarkStore?

    let gapActions: Set<String> = [
        "bookmarks.get", "bookmarks.getChildren", "bookmarks.getRecent",
        "bookmarks.getTree", "bookmarks.getSubTree", "bookmarks.search",
        "bookmarks.create", "bookmarks.move", "bookmarks.update",
        "bookmarks.remove", "bookmarks.removeTree"
    ]

    init(storeProvider: @escaping (ProfileExtensionRegistry) -> BookmarkStore?) {
        self.storeProvider = storeProvider
    }

    func handle(_ call: GapCall) async -> Any? {
        let registry = call.registry
        guard let store = storeProvider(registry) else { return BridgeError("Bookmarks store unavailable") }
        switch call.action {
        case "bookmarks.get":
            // Chrome's bookmarks.get always resolves with an array, even for a single id.
            return bridged { () throws -> Any? in
                if let ids = call.payload["ids"] as? [String] {
                    return try store.get(ids: ids).map(\.dict)
                } else if let id = call.string("id") {
                    guard let node = try store.get(id: id) else {
                        return BridgeError("Bookmark not found: \(id)")
                    }
                    return [node.dict]
                }
                return []
            }

        case "bookmarks.getChildren":
            let parentId = call.string("id") ?? ""
            return bridged { try store.getChildren(parentId: parentId).map(\.dict) }

        case "bookmarks.getRecent":
            let count = call.payload["numberOfItems"] as? Int ?? 5
            return bridged { try store.getRecent(count: count).map(\.dict) }

        case "bookmarks.getTree", "bookmarks.getSubTree":
            // Every row is read, so the read runs off the main actor.
            let rootId = call.action == "bookmarks.getSubTree" ? call.string("id") ?? "" : nil
            do {
                let records = try await Task.detached { try store.getTree() }.value
                return Self.tree(records, rootId: rootId)
            } catch {
                return BridgeError(error.localizedDescription)
            }

        case "bookmarks.search":
            let params = call.payload
            let url   = params["url"] as? String
            let title = params["title"] as? String
            let query = params["query"] as? String
            return bridged { try store.search(url: url, title: title, query: query).map(\.dict) }

        case "bookmarks.create":
            let parentId = call.string("parentId")
            let title    = call.string("title") ?? ""
            let url      = call.string("url")
            return bridged {
                let node = try store.create(parentId: parentId, title: title, url: url)
                emit("onCreated", args: [node.id, node.dict], registry: registry)
                return node.dict
            }

        case "bookmarks.move":
            let id       = call.string("id") ?? ""
            let parentId = call.string("parentId")
            let index    = call.payload["index"] as? Int
            return bridged {
                // Snapshot the old position BEFORE the move: store.move reindexes siblings and the
                // returned record carries only the NEW parentId/index.
                let before = try? store.get(id: id)
                let moved = try store.move(id: id, parentId: parentId, index: index)
                emit("onMoved", args: [id, [
                    "parentId": moved.parentId ?? "",
                    "index": moved.index_ ?? 0,
                    "oldParentId": before?.parentId ?? "",
                    "oldIndex": before?.index_ ?? 0
                ]], registry: registry)
                return moved.dict
            }

        case "bookmarks.update":
            let id    = call.string("id") ?? ""
            let title = call.string("title")
            let url   = call.string("url")
            return bridged {
                let node = try store.update(id: id, title: title, url: url)
                // ChangeInfo carries only title and (for non-folders) url.
                var info: [String: Any] = ["title": node.title]
                if let u = node.url { info["url"] = u }
                emit("onChanged", args: [id, info], registry: registry)
                return node.dict
            }

        case "bookmarks.remove":
            let id = call.string("id") ?? ""
            return bridged { () throws -> Any? in
                let snap = try? store.get(id: id)   // capture before the destructive delete
                try store.remove(id: id)
                emitRemoved(id: id, node: snap, registry: registry)
                return nil
            }

        case "bookmarks.removeTree":
            let id = call.string("id") ?? ""
            return bridged { () throws -> Any? in
                let snap = try? store.get(id: id)
                try store.removeTree(id: id)
                emitRemoved(id: id, node: snap, registry: registry)
                return nil
            }

        default:
            return nil
        }
    }

    /// Fire a chrome.bookmarks.* event to extensions holding the `bookmarks` permission. Chrome
    /// delivers these for every change, including the initiating extension's own writes.
    private func emit(_ event: String, args: [Any], registry: ProfileExtensionRegistry) {
        registry.emitGapEvent("bookmarks", event, args: args, requiredPermission: "bookmarks")
    }

    private func emitRemoved(id: String, node: ChromeBookmarkRecord?, registry: ProfileExtensionRegistry) {
        // RemoveInfo = { parentId, index, node }. `node` is the removed BookmarkTreeNode, flat: a folder
        // removed by removeTree does not carry its nested subtree.
        emit("onRemoved", args: [id, [
            "parentId": node?.parentId ?? "",
            "index": node?.index_ ?? 0,
            "node": node?.dict ?? ["id": id]
        ]], registry: registry)
    }

    /// Nests index-ordered rows into Chrome BookmarkTreeNodes: `[node rootId]`, or the parentless
    /// root when `rootId` is nil. Folders (no url) always carry `children`.
    private static func tree(_ records: [ChromeBookmarkRecord], rootId: String?) -> [[String: Any]] {
        var childrenByParent: [String: [ChromeBookmarkRecord]] = [:]
        var root: ChromeBookmarkRecord?
        for record in records {
            if let parentId = record.parentId { childrenByParent[parentId, default: []].append(record) }
            if rootId.map({ record.id == $0 }) ?? (record.parentId == nil) { root = record }
        }
        func node(_ record: ChromeBookmarkRecord) -> [String: Any] {
            var dict = record.dict
            if record.url == nil { dict["children"] = (childrenByParent[record.id] ?? []).map(node) }
            return dict
        }
        return root.map { [node($0)] } ?? []
    }
}

// MARK: - ChromeBookmarkRecord to bridge dict

private extension ChromeBookmarkRecord {
    var dict: [String: Any] {
        var d: [String: Any] = ["id": id, "title": title]
        if let p = parentId { d["parentId"] = p }
        if let i = index_ { d["index"] = i }
        if let u = url { d["url"] = u }
        if let da = dateAdded { d["dateAdded"] = da }
        if let dgm = dateGroupModified { d["dateGroupModified"] = dgm }
        return d
    }
}
