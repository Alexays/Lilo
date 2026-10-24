import XCTest
@testable import Lilo

/// Covers `SearchBridgeHandler`'s pure, side-effect-free helpers: the per-engine
/// suggestion-URL builder and the suggestion-response parser. The message-handling
/// paths depend on a live `TabManager`/`BridgeRouter` and belong in integration tests.
@MainActor
final class SearchBridgeHandlerTests: XCTestCase {

    // MARK: - searchSuggestionURL

    func test_searchSuggestionURL_googleIsDefault() throws {
        let url = try XCTUnwrap(SearchBridgeHandler.searchSuggestionURL(query: "hello world", engine: "google"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "suggestqueries.google.com")
        XCTAssertEqual(url.path, "/complete/search")
        let items = try queryItems(url)
        XCTAssertEqual(items["q"], "hello world")
        XCTAssertEqual(items["client"], "firefox")
    }

    func test_searchSuggestionURL_unknownEngineHasNoSuggestEndpoint() {
        // Custom user engines have no known suggest endpoint: return nil (no network call) rather
        // than leaking the query to Google's suggest API.
        XCTAssertNil(SearchBridgeHandler.searchSuggestionURL(query: "x", engine: "totally-unknown"))
    }

    func test_searchSuggestionURL_bingUsesQueryParam() throws {
        let url = try XCTUnwrap(SearchBridgeHandler.searchSuggestionURL(query: "swift", engine: "bing"))
        XCTAssertEqual(url.host, "api.bing.com")
        XCTAssertEqual(try queryItems(url)["query"], "swift")
    }

    func test_searchSuggestionURL_braveUsesQParam() throws {
        let url = try XCTUnwrap(SearchBridgeHandler.searchSuggestionURL(query: "swift", engine: "brave"))
        XCTAssertEqual(url.host, "search.brave.com")
        XCTAssertEqual(try queryItems(url)["q"], "swift")
    }

    func test_searchSuggestionURL_duckduckgoAddsTypeList() throws {
        let url = try XCTUnwrap(SearchBridgeHandler.searchSuggestionURL(query: "swift", engine: "duckduckgo"))
        XCTAssertEqual(url.host, "duckduckgo.com")
        let items = try queryItems(url)
        XCTAssertEqual(items["q"], "swift")
        XCTAssertEqual(items["type"], "list")
    }

    func test_searchSuggestionURL_encodesSpecialCharacters() throws {
        let url = try XCTUnwrap(SearchBridgeHandler.searchSuggestionURL(query: "a b&c", engine: "google"))
        // The "&" must be percent-encoded so it isn't read as a query separator...
        XCTAssertFalse(try XCTUnwrap(url.query).contains("a b&c"))
        // ...and the value must still decode back to the original.
        XCTAssertEqual(try queryItems(url)["q"], "a b&c")
    }

    // MARK: - parseSuggestionPayload

    func test_parseSuggestionPayload_opensearchArrayShape() throws {
        // ["query", ["s1", "s2"]]: Google/Bing/Firefox opensearch response.
        let data = try JSONSerialization.data(withJSONObject: ["hel", ["hello", "help"]])
        XCTAssertEqual(SearchBridgeHandler.parseSuggestionPayload(data), ["hello", "help"])
    }

    func test_parseSuggestionPayload_phraseObjectShape() throws {
        // [{"phrase": "..."}]: DuckDuckGo response.
        let data = try JSONSerialization.data(withJSONObject: [["phrase": "hello"], ["phrase": "help"]])
        XCTAssertEqual(SearchBridgeHandler.parseSuggestionPayload(data), ["hello", "help"])
    }

    func test_parseSuggestionPayload_malformedReturnsEmpty() {
        XCTAssertEqual(SearchBridgeHandler.parseSuggestionPayload(Data("not json".utf8)), [])
    }

    // MARK: - Helpers

    private func queryItems(_ url: URL) throws -> [String: String] {
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return (components.queryItems ?? []).reduce(into: [:]) { $0[$1.name] = $1.value }
    }
}
