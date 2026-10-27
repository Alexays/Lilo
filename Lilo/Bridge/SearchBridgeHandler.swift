import Foundation
import os

private let historyLogger = Logger(liloCategory: "history")

/// A history read that logs its failure and answers no rows, so the command bar drops the previous query's results.
private func loggedHistoryRead(_ read: () throws -> [HistoryEntry]) -> [HistoryEntry] {
    do { return try read() } catch {
        historyLogger.error("history read failed: \(error.localizedDescription, privacy: .public)")
        return []
    }
}

/// Handles search-related bridge messages: history and bookmark queries.
@MainActor
final class SearchBridgeHandler: BridgeHandler {

    let handledActions: Set<String> = [
        "searchHistory",
        "getRecentHistory",
        "searchSuggestions",
        "preloadTopHit",
        "deleteHistoryEntry"
    ]

    private let historyStoreProvider: () -> HistoryStore?
    private let suggestionsEnabledProvider: () -> Bool
    private let preconnect: (URL) -> Void
    private let preloadTopHit: (URL?) -> Void
    private var lastEnginePreconnect: (engine: String, at: Date)?
    private weak var bridgeRouter: BridgeRouter?
    /// One suggestion fetch at a time, then the newest query typed meanwhile: on a slow link, cancelling
    /// at each keystroke would leave nothing to show until typing stops. The command bar keeps a
    /// reply to a prefix of what is typed.
    private var inFlightSuggestionsTask: Task<Void, Never>?
    private var queuedSuggestionQuery: (query: String, engine: String)?
    /// Newest query wins: an older search still in flight is cancelled so its stale reply
    /// neither parses nor emits over the newer one.
    private var inFlightHistoryTask: Task<Void, Never>?

    init(
        historyStoreProvider: @escaping () -> HistoryStore?,
        bridgeRouter: BridgeRouter,
        suggestionsEnabledProvider: @escaping () -> Bool,
        preconnect: @escaping (URL) -> Void,
        preloadTopHit: @escaping (URL?) -> Void
    ) {
        self.historyStoreProvider = historyStoreProvider
        self.bridgeRouter = bridgeRouter; self.suggestionsEnabledProvider = suggestionsEnabledProvider
        self.preconnect = preconnect
        self.preloadTopHit = preloadTopHit
    }

    func handle(message: BridgeMessage) async -> Any? {
        switch message.action {

        // History reads run detached: they hit SQLite (plus a possible pending-visit flush) per
        // omnibox keystroke, and GRDB pool reads are thread-safe. Results hop back here (MainActor)
        // for the bridge send.
        case "searchHistory":
            guard let query = message.string("query"), let store = historyStoreProvider() else { break }
            inFlightHistoryTask?.cancel()
            inFlightHistoryTask = Task { [weak self] in
                // A superseded keystroke cancels its read, so a stale query never reaches SQLite.
                let search = Task.detached(priority: .userInitiated) { () -> [HistoryEntry]? in
                    guard !Task.isCancelled else { return nil }
                    // Candidates: the command bar re-ranks them by match quality and frecency, then keeps 8.
                    return loggedHistoryRead { try store.search(query: query, limit: 24) }
                }
                let results = await withTaskCancellationHandler { await search.value } onCancel: { search.cancel() }
                guard !Task.isCancelled else { return }
                if let results { self?.sendHistoryResults(results, query: query) }
            }
            await inFlightHistoryTask?.value

        case "getRecentHistory":
            guard let store = historyStoreProvider() else { break }
            let results = await Task.detached(priority: .userInitiated) {
                loggedHistoryRead { try store.recentEntries(limit: 24) }
            }.value
            sendHistoryResults(results, query: "")

        case "searchSuggestions":
            guard let query = message.string("query") else { break }
            let engine = message.string("engine", default: "google")
            // Typing in the address bar most often ends on the engine's results page: open that
            // connection while the user types. Renewed at most every 30 s, about an idle connection's life.
            if lastEnginePreconnect?.engine != engine || Date().timeIntervalSince(lastEnginePreconnect?.at ?? .distantPast) >= 30,
               let url = Self.searchEngineOrigins[engine] {
                lastEnginePreconnect = (engine, Date())
                preconnect(url)
            }
            queuedSuggestionQuery = (query, engine)
            guard inFlightSuggestionsTask == nil else { break }
            inFlightSuggestionsTask = Task { [weak self] in
                while let self, let next = self.queuedSuggestionQuery {
                    self.queuedSuggestionQuery = nil
                    await self.sendSearchSuggestions(query: next.query, engine: next.engine)
                }
                self?.inFlightSuggestionsTask = nil
            }

        // An empty URL drops the preload: the top hit changed to a row not worth one, or the bar closed.
        case "preloadTopHit":
            preloadTopHit(message.url("url"))

        case "deleteHistoryEntry":
            guard let url = message.string("url"), let store = historyStoreProvider() else { break }
            let query = message.string("query", default: "")
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let results = await Task.detached(priority: .userInitiated) {
                do { try store.deleteURL(url) } catch {
                    historyLogger.error("history delete failed: \(error.localizedDescription, privacy: .public)")
                }
                return loggedHistoryRead {
                    try trimmed.isEmpty ? store.recentEntries(limit: 24) : store.search(query: trimmed, limit: 24)
                }
            }.value
            sendHistoryResults(results, query: query)

        default:
            break
        }

        return nil
    }

    private func sendHistoryResults(_ results: [HistoryEntry], query: String) {
        bridgeRouter?.send(event: "historyResults", data: [
            "query": query,
            "results": results.map(\.searchBridgeData)
        ])
    }

    private func sendSearchSuggestions(query: String, engine: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard suggestionsEnabledProvider(), !trimmed.isEmpty,
              let url = Self.searchSuggestionURL(query: trimmed, engine: engine) else {
            bridgeRouter?.send(event: "searchSuggestions", data: ["query": query, "suggestions": []])
            return
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 4
            let (data, _) = try await Self.suggestionSession.data(for: request)
            bridgeRouter?.send(event: "searchSuggestions", data: [
                "query": query,
                "suggestions": Self.parseSuggestionPayload(data)
            ])
        } catch {
            bridgeRouter?.send(event: "searchSuggestions", data: ["query": query, "suggestions": []])
        }
    }

    /// Ephemeral: the engine's cookies stay out of the app-wide jar, which clearing browsing data
    /// never reaches. One session so keystrokes reuse its connection.
    private static let suggestionSession = URLSession(configuration: .ephemeral)

    private static let searchEngineOrigins: [String: URL] = [
        "google": URL(string: "https://www.google.com")!,
        "bing": URL(string: "https://www.bing.com")!,
        "brave": URL(string: "https://search.brave.com")!,
        "duckduckgo": URL(string: "https://duckduckgo.com")!
    ]

    static func searchSuggestionURL(query: String, engine: String) -> URL? {
        let base: String
        let queryItemName: String

        switch engine {
        case "google":
            base = "https://suggestqueries.google.com/complete/search"
            queryItemName = "q"
        case "bing":
            base = "https://api.bing.com/osjson.aspx"
            queryItemName = "query"
        case "brave":
            base = "https://search.brave.com/api/suggest"
            queryItemName = "q"
        case "duckduckgo":
            base = "https://duckduckgo.com/ac/"
            queryItemName = "q"
        default:
            return nil // custom engine: no known suggestion endpoint
        }

        guard var components = URLComponents(string: base) else { return nil }
        var items = [URLQueryItem(name: queryItemName, value: query)]
        if engine == "google" {
            items.append(URLQueryItem(name: "client", value: "firefox"))
        } else if engine == "duckduckgo" {
            items.append(URLQueryItem(name: "type", value: "list"))
        }
        components.queryItems = items
        return components.url
    }

    static func parseSuggestionPayload(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }

        if let array = json as? [Any],
           array.count > 1,
           let suggestions = array[1] as? [String] {
            return suggestions
        }

        if let objects = json as? [[String: Any]] {
            return objects.compactMap { $0["phrase"] as? String }
        }

        return []
    }
}

private extension HistoryEntry {
    var searchBridgeData: [String: Any] {
        [
            "id": id.uuidString,
            "url": url,
            "title": title,
            "openedFrom": openedFrom ?? "",
            "visitCount": visitCount,
            "lastVisitedAt": lastVisitedAt.timeIntervalSince1970 * 1000
        ]
    }
}
