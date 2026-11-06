import Foundation
import WebKit

/// chrome.bookmarks gap bridge wrapping BookmarkStore.
@MainActor
final class BookmarksBridgeHandler: GapHandler {
    /// The calling extension's profile store, resolved from its registry.
    private let storeProvider: (ProfileExtensionRegistry) -> BookmarkStore?
    private let storeQueue = DispatchQueue(label: "fr.arouillard.lilo.bookmarks")

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
        do {
            switch call.action {
            case "bookmarks.get":
                // Chrome's bookmarks.get always resolves with an array, even for a single id.
                if let ids = call.payload["ids"] as? [String] {
                    return try await onStore { try store.get(ids: ids) }.map(\.dict)
                } else if let id = call.string("id") {
                    guard let node = try await onStore({ try store.get(id: id) }) else {
                        return BridgeError("Bookmark not found: \(id)")
                    }
                    return [node.dict]
                }
                return []

            case "bookmarks.getChildren":
                let parentId = call.string("id") ?? ""
                return try await onStore { try store.getChildren(parentId: parentId) }.map(\.dict)

            case "bookmarks.getRecent":
                let count = call.payload["numberOfItems"] as? Int ?? 5
                return try await onStore { try store.getRecent(count: count) }.map(\.dict)

            case "bookmarks.getTree", "bookmarks.getSubTree":
                let rootId = call.action == "bookmarks.getSubTree" ? call.string("id") ?? "" : nil
                let records = try await onStore { try store.getTree() }
                return Self.tree(records, rootId: rootId)

            case "bookmarks.search":
                let params = call.payload
                let url   = params["url"] as? String
                let title = params["title"] as? String
                let query = params["query"] as? String
                return try await onStore { try store.search(url: url, title: title, query: query) }.map(\.dict)

            case "bookmarks.create":
                let parentId = call.string("parentId")
                let title    = call.string("title") ?? ""
                let url      = call.string("url")
                let node = try await onStore { try store.create(parentId: parentId, title: title, url: url) }
                emit("onCreated", args: [node.id, node.dict], registry: registry)
                return node.dict

            case "bookmarks.move":
                let id       = call.string("id") ?? ""
                let parentId = call.string("parentId")
                let index    = call.payload["index"] as? Int
                // Snapshot the old position BEFORE the move: store.move reindexes siblings and the
                // returned record carries only the NEW parentId/index.
                let (before, moved) = try await onStore { () throws -> (ChromeBookmarkRecord?, ChromeBookmarkRecord) in
                    let before = try? store.get(id: id)
                    return (before, try store.move(id: id, parentId: parentId, index: index))
                }
                emit("onMoved", args: [id, [
                    "parentId": moved.parentId ?? "",
                    "index": moved.index_ ?? 0,
                    "oldParentId": before?.parentId ?? "",
                    "oldIndex": before?.index_ ?? 0
                ]], registry: registry)
                return moved.dict

            case "bookmarks.update":
                let id    = call.string("id") ?? ""
                let title = call.string("title")
                let url   = call.string("url")
                let node = try await onStore { try store.update(id: id, title: title, url: url) }
                // ChangeInfo carries only title and (for non-folders) url.
                var info: [String: Any] = ["title": node.title]
                if let u = node.url { info["url"] = u }
                emit("onChanged", args: [id, info], registry: registry)
                return node.dict

            case "bookmarks.remove", "bookmarks.removeTree":
                let id = call.string("id") ?? ""
                let tree = call.action == "bookmarks.removeTree"
                let snap = try await onStore { () throws -> ChromeBookmarkRecord? in
                    let snap = try? store.get(id: id)   // capture before the destructive delete
                    if tree { try store.removeTree(id: id) } else { try store.remove(id: id) }
                    return snap
                }
                emitRemoved(id: id, node: snap, registry: registry)
                return nil

            default:
                return nil
            }
        } catch {
            return BridgeError(error.localizedDescription)
        }
    }

    /// Runs store work off the main actor on one serial queue, entered before any suspension, so calls
    /// reach the store and fire their events in the order the extension made them, as in Chrome.
    private func onStore<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            storeQueue.async { continuation.resume(with: Result(catching: work)) }
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
