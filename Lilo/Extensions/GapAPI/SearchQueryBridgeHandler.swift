import Foundation
import WebKit

/// Gap API handler for `chrome.search.query`: builds the results URL of Lilo's default search
/// engine. The JS side opens it through WebKit's chrome.tabs/chrome.windows.
@MainActor
final class SearchQueryBridgeHandler: GapHandler {
    let gapActions: Set<String> = ["search.url"]

    /// Mirrors BUILTIN_SEARCH_ENGINES in lilo-ui/src/lib/searchEngineModel.ts, the list when the
    /// `searchEngines` setting is unset or holds no valid engine.
    private static let builtinEngines = [
        (id: "google", name: "Google", urlTemplate: "https://www.google.com/search?q=%s"),
        (id: "duckduckgo", name: "DuckDuckGo", urlTemplate: "https://duckduckgo.com/?q=%s"),
        (id: "bing", name: "Bing", urlTemplate: "https://www.bing.com/search?q=%s"),
        (id: "brave", name: "Brave Search", urlTemplate: "https://search.brave.com/search?q=%s")
    ]

    func handle(_ call: GapCall) async -> Any? {
        Self.searchURL(for: call.string("text") ?? "", settings: call.registry.settingsStore)
    }

    /// The user's default search engine.
    static func searchEngine(settings: SettingsStore?) -> (name: String, urlTemplate: String) {
        // Parsed and chosen as the omnibox does: the engine by id, else the first of the list.
        let custom = (settings?.get("searchEngines")
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [Any] } ?? [])
            .compactMap { raw -> (id: String, name: String, urlTemplate: String)? in
                let engine = raw as? [String: Any]
                let fields = ["id", "name", "urlTemplate"].map { (engine?[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
                return fields.contains("") ? nil : (fields[0], fields[1], fields[2])
            }
        let engines = custom.isEmpty ? builtinEngines : custom
        let engineId = settings?.searchEngine ?? "google"
        let engine = engines.first { $0.id == engineId } ?? engines[0]
        return (engine.name, engine.urlTemplate)
    }

    /// The engine searching by image URL: Bing's own when it is the default engine, else Google Lens, as most engines have none.
    static func imageSearchEngine(settings: SettingsStore?) -> (name: String, urlTemplate: String) {
        searchEngine(settings: settings).urlTemplate.hasPrefix("https://www.bing.com/")
            ? ("Bing", "https://www.bing.com/images/search?view=detailv2&iss=sbi&q=imgurl:%s")
            : ("Google Lens", "https://lens.google.com/uploadbyurl?url=%s")
    }

    /// The results page of the user's default search engine for `text`.
    static func searchURL(for text: String, settings: SettingsStore?) -> String {
        searchURL(for: text, template: searchEngine(settings: settings).urlTemplate)
    }

    static func searchURL(for text: String, template: String) -> String {
        // encodeURIComponent's unreserved set, as the omnibox encodes queries.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return template.contains("%s") ? template.replacingOccurrences(of: "%s", with: encoded) : template + encoded
    }
}
