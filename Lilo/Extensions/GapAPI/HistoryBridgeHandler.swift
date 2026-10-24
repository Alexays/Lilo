import Foundation
import WebKit

/// chrome.history gap bridge wrapping HistoryStore.
@MainActor
final class HistoryBridgeHandler: GapHandler {
    /// The calling extension's profile store, resolved from its registry.
    private let storeProvider: (ProfileExtensionRegistry) -> HistoryStore?

    private static let maxSearchResults = 1000

    let gapActions: Set<String> = [
        "history.search", "history.getVisits",
        "history.addUrl", "history.deleteUrl",
        "history.deleteRange", "history.deleteAll"
    ]

    init(storeProvider: @escaping (ProfileExtensionRegistry) -> HistoryStore?) {
        self.storeProvider = storeProvider
    }

    func handle(_ call: GapCall) async -> Any? {
        let registry = call.registry
        guard let store = storeProvider(registry) else { return BridgeError("History store unavailable") }
        switch call.action {
        case "history.search":
            // Chrome's defaults: 100 results from the last 24 hours. A non-positive maxResults falls
            // back to the cap rather than reading the whole table.
            let text = call.string("text") ?? ""
            let maxResults = call.int("maxResults").map { $0 > 0 ? min($0, Self.maxSearchResults) : Self.maxSearchResults } ?? 100
            let nowMs = Date().timeIntervalSince1970 * 1000
            let start = Date(timeIntervalSince1970: (call.double("startTime") ?? nowMs - 86_400_000) / 1000)
            let end = Date(timeIntervalSince1970: (call.double("endTime") ?? nowMs) / 1000)
            do {
                let entries = try await Task.detached {
                    try store.entries(matching: text, from: start, to: end, limit: maxResults)
                }.value
                return entries.map(\.chromeBridgeDict)
            } catch {
                return BridgeError(error.localizedDescription)
            }

        case "history.getVisits":
            let url = call.string("url") ?? ""
            let found = await Task.detached { try store.entry(forURL: url) }.result
            return bridged {
                // Exact-URL lookup. This store is page-grained (one row per URL, last visit only), so
                // it surfaces at most a single synthetic visit; Chrome returns one VisitItem per
                // recorded visit, which we can't reconstruct without a per-visit table.
                guard let entry = try found.get() else {
                    return [[String: Any]]()
                }
                return [[
                    "visitId": "1",
                    "id": entry.id.uuidString,
                    "visitTime": entry.lastVisitedAt.timeIntervalSince1970 * 1000,
                    "referringVisitId": "0",
                    "transition": "link"
                ]]
            }

        case "history.addUrl":
            let url = call.string("url") ?? ""
            return bridged { () throws -> Any? in
                try store.recordVisit(url: url, title: "")
                return nil
            }

        case "history.deleteUrl":
            let url = call.string("url") ?? ""
            let deleted = await Task.detached { try store.deleteURL(url) }.result
            return bridged { () throws -> Any? in
                try deleted.get()
                return nil
            }

        case "history.deleteRange":
            // chrome.history.deleteRange takes startTime/endTime in epoch milliseconds.
            let startMs = call.double("startTime") ?? 0
            let endMs = call.double("endTime") ?? (Date().timeIntervalSince1970 * 1000)
            let deleted = await Task.detached {
                try store.deleteEntries(from: Date(timeIntervalSince1970: startMs / 1000), to: Date(timeIntervalSince1970: endMs / 1000))
            }.result
            return bridged { () throws -> Any? in
                _ = try deleted.get()
                return nil
            }

        case "history.deleteAll":
            let cleared = await Task.detached { try store.clearAll() }.result
            return bridged { () throws -> Any? in
                try cleared.get()
                return nil
            }

        default:
            return nil
        }
    }

    /// Fires `chrome.history.onVisited` for each written page, and `onVisitRemoved`, whose `RemovedResult` lists the removed
    /// urls, none for a full clear.
    static func emit(_ change: HistoryStore.Change, to registry: ProfileExtensionRegistry) {
        switch change {
        case .visited(let entries):
            for entry in entries {
                registry.emitGapEvent("history", "onVisited", args: [entry.chromeBridgeDict], requiredPermission: "history")
            }
        case let .removed(allHistory, urls):
            registry.emitGapEvent("history", "onVisitRemoved", args: [["allHistory": allHistory, "urls": urls]], requiredPermission: "history")
        }
    }
}

// MARK: - HistoryEntry to Chrome bridge dict

private extension HistoryEntry {
    var chromeBridgeDict: [String: Any] {
        [
            "id": id.uuidString,
            "url": url,
            "title": title,
            "lastVisitTime": lastVisitedAt.timeIntervalSince1970 * 1000,
            "visitCount": visitCount,
            "typedCount": 0
        ]
    }
}
