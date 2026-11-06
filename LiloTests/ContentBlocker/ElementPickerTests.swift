import WebKit
import XCTest
@testable import Lilo

@MainActor
final class ElementPickerTests: XCTestCase {
    private func makeTab(hidden: [String: [String]] = [:]) -> WKWebViewTab {
        let factory = WKEngineFactory()
        factory.setFilterTables(rulesTag: nil, rules: nil, scripts: WKEngineFactory.makeFilterScripts(
            cosmetic: nil, sites: #"{"ads.example":[".ad"]}"#, scriptlets: nil, procedural: nil
        ))
        factory.setHiddenElements(hidden)
        let tab = factory.createTab(configuration: .init())
        tab.wkWebView.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        return tab
    }

    private func load(_ body: String, at url: String, in webView: WKWebView) async {
        webView.loadHTMLString("<!doctype html><html><head></head><body>\(body)</body></html>", baseURL: URL(string: url))
        let loaded = await pollUntil(timeout: 10) {
            let condition = "location.href === '\(url)' && document.readyState === 'complete'"
            return ((try? await webView.callAsyncJavaScript("return " + condition, contentWorld: .page)) as? Bool) == true
        }
        XCTAssertTrue(loaded)
    }

    private func display(of selector: String, in webView: WKWebView) async -> String? {
        try? await webView.callAsyncJavaScript("return getComputedStyle(document.querySelector(selector)).display",
                                               arguments: ["selector": selector], contentWorld: .page) as? String
    }

    func testTheElementsTheUserHidStayHiddenOnTheirHost() async throws {
        let tab = makeTab(hidden: ["example.com": ["#banner", "body > aside"]])
        defer { tab.teardown() }
        let webView = tab.wkWebView
        await load("<div id=banner>banner</div><aside>aside</aside><main>main</main>", at: "https://www.example.com/", in: webView)
        let hidden = await pollUntil(timeout: 10) {
            let banner = await self.display(of: "#banner", in: webView), aside = await self.display(of: "aside", in: webView)
            return banner == "none" && aside == "none"
        }
        XCTAssertTrue(hidden)
        let main = await display(of: "main", in: webView)
        XCTAssertEqual(main, "block")

        await load("<div id=banner>banner</div>", at: "https://other.example/", in: webView)
        let shown = await display(of: "#banner", in: webView)
        XCTAssertEqual(shown, "block", "another host keeps its elements")
    }

    /// A click picks the element under it: generated names are left out, and twins are told apart by position.
    func testAClickHidesTheElementAndGivesASelectorForItAlone() async throws {
        let tab = makeTab()
        defer { tab.teardown() }
        let webView = tab.wkWebView
        let page = "<style>body{margin:0}#slot123456{position:absolute;left:100px;top:100px;width:200px;height:200px}</style>"
            + "<section><div class=card>first</div><div class='card css-1x2y3z' id=slot123456>second</div></section>"
        await load(page, at: "https://example.com/", in: webView)

        var picked: String??
        tab.pickElementToHide { picked = .some($0) }
        let overlay = try XCTUnwrap(webView.subviews.last as? ElementPickerOverlay)
        // The middle of the view, which is the same point whether the view is flipped or not.
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 200, y: 200), modifierFlags: [], timestamp: 0,
                                                     windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        overlay.mouseDown(with: click)
        let done = await pollUntil(timeout: 10) { picked != nil }
        XCTAssertTrue(done)
        XCTAssertEqual(picked, "div.card:nth-of-type(2)")
        XCTAssertNil(overlay.superview, "the overlay leaves once the element is picked")
        if CosmeticStyleSheets.isSupported {
            let hidden = await pollUntil(timeout: 10) { await self.display(of: "#slot123456", in: webView) == "none" }
            XCTAssertTrue(hidden, "the element hides at once")
        }
        let first = await display(of: ".card", in: webView)
        XCTAssertEqual(first, "block")
    }

    func testANavigationCancelsThePick() async {
        let tab = makeTab()
        defer { tab.teardown() }
        await load("<p>page</p>", at: "https://example.com/", in: tab.wkWebView)
        var picked: String??
        tab.pickElementToHide { picked = .some($0) }
        tab.wkWebView.loadHTMLString("<p>next</p>", baseURL: URL(string: "https://example.org/"))
        let cancelled = await pollUntil(timeout: 10) { picked != nil }
        XCTAssertTrue(cancelled)
        XCTAssertEqual(picked, .some(nil))
        XCTAssertFalse(tab.wkWebView.subviews.contains { $0 is ElementPickerOverlay })
    }
}
