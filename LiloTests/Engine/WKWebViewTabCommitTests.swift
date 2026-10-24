import WebKit
import XCTest
@testable import Lilo

/// WebKit can commit one navigation twice, the second time as an empty document, when its response swaps
/// the process (COOP) before the web view committed anything.
@MainActor
final class WKWebViewTabCommitTests: XCTestCase {
    func testAnEmptySecondCommitOfTheSameNavigationReloadsOnceInsteadOfShowingABlankPage() throws {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let tab = WKWebViewTab(webView: webView)
        let spy = WKWebViewTabDelegateSpy()
        tab.delegate = spy
        tab.loadURL(URL(string: "https://lilo.invalid/")!)
        let emptyDocument = URLRequest(url: URL(string: "about:blank")!)
        let navigation = try XCTUnwrap(webView.load(emptyDocument))

        tab.webView(webView, didCommit: navigation)
        tab.webView(webView, didCommit: navigation)
        XCTAssertEqual(spy.commits, 1, "the empty second commit is reloaded, not reported as a page")
        XCTAssertEqual(webView.url?.host, "lilo.invalid", "the requested page loads again")

        let next = try XCTUnwrap(webView.load(emptyDocument))
        tab.webView(webView, didCommit: next)
        tab.webView(webView, didCommit: next)
        XCTAssertEqual(spy.commits, 3, "one reload per requested load, so it never loops")
    }

    func testDistinctNavigationsAreEachReported() throws {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let tab = WKWebViewTab(webView: webView)
        let spy = WKWebViewTabDelegateSpy()
        tab.delegate = spy
        tab.loadURL(URL(string: "https://lilo.invalid/")!)
        let emptyDocument = URLRequest(url: URL(string: "about:blank")!)
        let first = try XCTUnwrap(webView.load(emptyDocument))
        let second = try XCTUnwrap(webView.load(emptyDocument))

        tab.webView(webView, didCommit: first)
        tab.webView(webView, didCommit: second)
        XCTAssertEqual(spy.commits, 2)
    }
}
