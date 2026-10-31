import WebKit
import XCTest
@testable import Lilo

@MainActor
final class PageTranslatorTests: XCTestCase {
    /// Italian text, so it differs from the test's language and the page is collected for translation.
    private static let page = """
    <p>Il gatto dorme sul divano tutto il giorno mentre la pioggia cade sulla città.</p>
    <pre><code><span>let gatto = dorme</span></code></pre>
    <svg><text>etichetta del grafico</text></svg>
    <ul id="feed"></ul>
    """

    /// Translation runs in its own world, which the test reads by name: the page cannot.
    private func originals(_ webView: WKWebView) async throws -> [String]? {
        try await webView.evaluateJavaScript("window.__liloTranslation?.originals.map((text) => text.trim())",
                                             in: nil, contentWorld: .world(name: "lilo-translate")) as? [String]
    }

    func testTranslationSkipsCodeAndKeepsUpWithContentAddedLater() async throws {
        let webView = WKWebView()
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://news.example/"))
        let loaded = await pollUntil(timeout: 5) { (try? await webView.evaluateJavaScript("document.readyState === 'complete' && !!document.querySelector('#feed')")) as? Bool == true }
        XCTAssertTrue(loaded)
        let translator = PageTranslator()

        await translator.toggle(in: webView)
        let collected = try await originals(webView)
        XCTAssertEqual(collected, ["Il gatto dorme sul divano tutto il giorno mentre la pioggia cade sulla città."],
                       "text nested in code or an SVG stays as written")

        _ = try await webView.evaluateJavaScript("feed.insertAdjacentHTML('beforeend', '<li>Un nuovo articolo appena arrivato</li>'); 0")
        let followed = await pollUntil(timeout: 5) { (try? await self.originals(webView))?.contains("Un nuovo articolo appena arrivato") == true }
        XCTAssertTrue(followed, "content a page adds while translated is translated too")

        await translator.toggle(in: webView)
        let restored = try await originals(webView)
        XCTAssertNil(restored)
    }
}
