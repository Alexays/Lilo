import WebKit
import XCTest
@testable import Lilo

@MainActor
final class CosmeticStyleSheetsTests: XCTestCase {
    private func load(_ body: String, at url: String, in webView: WKWebView) async {
        webView.loadHTMLString("<!doctype html><html><head></head><body>\(body)</body></html>", baseURL: URL(string: url))
        let loaded = await pollUntil(timeout: 10) {
            let condition = "location.href === '\(url)' && document.readyState === 'complete'"
            return ((try? await webView.callAsyncJavaScript("return " + condition, contentWorld: .page)) as? Bool) == true
        }
        XCTAssertTrue(loaded)
    }

    private func isHidden(_ id: String, in webView: WKWebView) async -> Bool {
        let display = try? await webView.callAsyncJavaScript("return getComputedStyle(document.getElementById(id)).display",
                                                             arguments: ["id": id], contentWorld: .page)
        return display as? String == "none"
    }

    private func sheetCount(in controller: WKUserContentController) -> Int {
        (controller.perform(NSSelectorFromString("_userStyleSheets"))?.takeUnretainedValue() as? NSArray)?.count ?? -1
    }

    func testCosmeticsHideWithSheetsThePageCannotSeeRemoveOrOutrankAndThatLeaveWithIt() async throws {
        try XCTSkipUnless(CosmeticStyleSheets.isSupported, "this WebKit has no user style sheet SPI")
        let factory = WKEngineFactory()
        factory.setFilterTables(rulesTag: nil, rules: nil, scripts: WKEngineFactory.makeFilterScripts(
            cosmetic: #"{"classes":"promo","ids":"","links":{}}"#, sites: #"{"example.com":[".ad"]}"#, scriptlets: nil, procedural: nil
        ))
        let tab = factory.createTab(configuration: .init())
        defer { tab.teardown() }
        let webView = tab.wkWebView, controller = webView.configuration.userContentController
        // The page's own `!important`, in a cascade layer, which outranks unlayered author rules.
        let page = "<style>@layer site { .ad, .promo { display: block !important } }</style><div class=ad id=ad>ad</div>"
        await load(page, at: "https://example.com/", in: webView)
        let siteHidden = await pollUntil(timeout: 10) { await self.isHidden("ad", in: webView) }
        XCTAssertTrue(siteHidden, "a user sheet's !important wins over a layered author one")
        let sheets = try await webView.callAsyncJavaScript("return [document.styleSheets.length, document.adoptedStyleSheets.length]", contentWorld: .page)
        XCTAssertEqual(sheets as? [Int], [1, 0], "the page sees only its own style element")

        // A generic selector found later is one more sheet, the earlier one untouched.
        let before = sheetCount(in: controller)
        _ = try await webView.callAsyncJavaScript(
            "document.body.insertAdjacentHTML('beforeend', '<div class=promo id=promo>promo</div>')", contentWorld: .page
        )
        let genericHidden = await pollUntil(timeout: 10) { await self.isHidden("promo", in: webView) }
        XCTAssertTrue(genericHidden)
        XCTAssertEqual(sheetCount(in: controller), before + 1)

        _ = try await webView.callAsyncJavaScript(
            "document.adoptedStyleSheets = []; document.querySelectorAll('style, link').forEach(node => node.remove())", contentWorld: .page
        )
        let stillHidden = await isHidden("ad", in: webView)
        XCTAssertTrue(stillHidden, "the page cannot remove the sheet")

        // A site without cosmetics: no sheet of the last page follows the tab there.
        await load(page, at: "https://other.example/", in: webView)
        let shown = await isHidden("ad", in: webView)
        XCTAssertFalse(shown)
        XCTAssertEqual(sheetCount(in: controller), 0)
    }

    /// A web view released without a teardown takes its sheets out of the controller its profile's other tabs share.
    func testAReleasedWebViewTakesItsSheetsAlong() async throws {
        try XCTSkipUnless(CosmeticStyleSheets.isSupported, "this WebKit has no user style sheet SPI")
        let factory = WKEngineFactory()
        factory.setFilterTables(rulesTag: nil, rules: nil, scripts: WKEngineFactory.makeFilterScripts(
            cosmetic: nil, sites: #"{"example.com":[".ad"]}"#, scriptlets: nil, procedural: nil
        ))
        var webView: WKWebView? = WKWebView(frame: .zero, configuration: factory.createTab(configuration: .init()).wkWebView.configuration)
        weak let released = webView
        let controller = try XCTUnwrap(webView?.configuration.userContentController)
        await load("<div class=ad id=ad>ad</div>", at: "https://example.com/", in: try XCTUnwrap(webView))
        let hidden = await pollUntil(timeout: 10) { await self.isHidden("ad", in: webView!) }
        XCTAssertTrue(hidden)
        XCTAssertEqual(sheetCount(in: controller), 1)

        webView = nil
        let gone = await pollUntil(timeout: 10) { released == nil }
        XCTAssertTrue(gone)
        XCTAssertEqual(sheetCount(in: controller), 0)
    }

    /// Back to a page from the back/forward cache, its cosmetics still hide what they did. 127.0.0.1 and localhost are two
    /// sites, so the page in between may run in a web process of its own.
    func testCosmeticsStillHideAfterGoingBack() async throws {
        try XCTSkipUnless(CosmeticStyleSheets.isSupported, "this WebKit has no user style sheet SPI")
        let server = try await TinyHTTPServer(index: "<script>addEventListener('pageshow', event => { window.restored = event.persisted })</script>"
                                              + "<div class=ad id=ad>ad</div>")
        let factory = WKEngineFactory()
        factory.setFilterTables(rulesTag: nil, rules: nil, scripts: WKEngineFactory.makeFilterScripts(
            cosmetic: nil, sites: #"{"127.0.0.1":[".ad"]}"#, scriptlets: nil, procedural: nil
        ))
        let tab = factory.createTab(configuration: .init())
        defer { tab.teardown() }
        let webView = tab.wkWebView
        func loaded(_ host: String) async -> Bool {
            await pollUntil(timeout: 10) {
                let condition = "return location.hostname === '\(host)' && document.readyState === 'complete'"
                return ((try? await webView.callAsyncJavaScript(condition, contentWorld: .page)) as? Bool) == true
            }
        }
        tab.loadURL(try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/")))
        let first = await loaded("127.0.0.1")
        XCTAssertTrue(first)
        let hidden = await pollUntil(timeout: 10) { await self.isHidden("ad", in: webView) }
        XCTAssertTrue(hidden)
        tab.loadURL(try XCTUnwrap(URL(string: "http://localhost:\(server.port)/")))
        let second = await loaded("localhost")
        XCTAssertTrue(second)
        let otherHidden = await isHidden("ad", in: webView)
        XCTAssertFalse(otherHidden, "the other site is clean")

        tab.goBack()
        let back = await loaded("127.0.0.1")
        XCTAssertTrue(back)
        let restored = try await webView.callAsyncJavaScript("return window.restored === true", contentWorld: .page) as? Bool
        XCTAssertEqual(restored, true, "the page comes back from the back/forward cache")
        let hiddenAgain = await pollUntil(timeout: 10) { await self.isHidden("ad", in: webView) }
        XCTAssertTrue(hiddenAgain)
    }
}
