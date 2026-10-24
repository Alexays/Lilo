import Foundation
import WebKit

/// Gap API handler for `chrome.search.query`: builds the results URL of Lilo's default search
/// engine. The JS side opens it through WebKit's chrome.tabs/chrome.windows.
@MainActor
final class SearchQueryBridgeHandler: GapHandler {
    let gapActions: Set<String> = ["search.url"]

    /// Mirrors BUILTIN_SEARCH_ENGINES in lilo-ui/src/lib/searchEngineModel.ts, the fallback when
    /// the `searchEngines` setting is unset or invalid.
    private static let builtinTemplates = [
        "google": "https://www.google.com/search?q=%s",
        "duckduckgo": "https://duckduckgo.com/?q=%s",
        "bing": "https://www.bing.com/search?q=%s",
        "brave": "https://search.brave.com/search?q=%s"
    ]

    func handle(_ call: GapCall) async -> Any? {
        Self.searchURL(for: call.string("text") ?? "", settings: call.registry.settingsStore)
    }

    /// The results page of the user's default search engine for `text`.
    static func searchURL(for text: String, settings: SettingsStore?) -> String {
        let engineId = settings?.searchEngine ?? "google"
        let custom = settings?.get("searchEngines")
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [[String: Any]] } ?? []
        let template = custom.first { $0["id"] as? String == engineId }?["urlTemplate"] as? String
            ?? builtinTemplates[engineId]
            ?? custom.first?["urlTemplate"] as? String
            ?? builtinTemplates["google"]!
        // encodeURIComponent's unreserved set, as the omnibox encodes queries.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return template.contains("%s") ? template.replacingOccurrences(of: "%s", with: encoded) : template + encoded
    }
}
