import Foundation
import WebKit

/// Gap API handler for `chrome.topSites`, backed by the history store's visit ranking. Read-only:
/// Chrome exposes only `get()`, returning the most-visited pages as `{url, title}`.
@MainActor
final class TopSitesBridgeHandler: GapHandler {
    let gapActions: Set<String> = ["topSites.get"]

    private static let resultCount = 20

    /// The calling extension's profile history, resolved from its registry.
    private let storeProvider: (ProfileExtensionRegistry) -> HistoryStore?

    init(
        storeProvider: @escaping (ProfileExtensionRegistry) -> HistoryStore?
    ) {
        self.storeProvider = storeProvider
    }

    func handle(_ call: GapCall) async -> Any? {
        guard let store = storeProvider(call.registry) else { return BridgeError("History store unavailable") }
        let limit = Self.resultCount
        let top = await Task.detached { try store.topVisited(limit: limit) }.result
        return bridged {
            try top.get().map { ["url": $0.url, "title": $0.title] }
        }
    }
}
