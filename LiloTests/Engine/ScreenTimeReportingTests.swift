import ScreenTime
import WebKit
import XCTest
@testable import Lilo

@MainActor
final class ScreenTimeReportingTests: XCTestCase {
    private func makeTab() -> WKWebViewTab {
        WKWebViewTab.reportsToScreenTime = true
        addTeardownBlock { @MainActor in WKWebViewTab.reportsToScreenTime = false }
        let factory = WKEngineFactory()
        let tab = factory.createTab(configuration: .init(dataStore: factory.defaultDataStore()))
        addTeardownBlock { @MainActor in tab.teardown() }
        return tab
    }

    /// Puts the tab's view in a window, as the content area does when it shows the tab.
    private func show(_ tab: WKWebViewTab) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.wkWebView
        addTeardownBlock { @MainActor in window.close() }
    }

    private func screenTime(of webView: WKWebView) -> STWebpageController? {
        webView.subviews.lazy.compactMap { $0.nextResponder as? STWebpageController }.first
    }

    func testAWebPageGetsTheScreenTimeOverlayWithoutLosingClicks() async {
        let tab = makeTab()
        let webView = tab.wkWebView
        show(tab)

        webView.loadHTMLString("<p>page</p>", baseURL: URL(string: "https://example.com/"))
        let overlaid = await pollUntil(timeout: 5) {
            webView.subviews.contains { String(describing: type(of: $0)).contains("STWebpage") }
        }

        XCTAssertTrue(overlaid, "a committed web page reports to Screen Time through its overlay view")
        XCTAssertIdentical(webView.hitTest(NSPoint(x: 200, y: 150)), webView, "clicks still reach the page")
    }

    func testATabNeverShownReportsItsPageOnceDisplayed() async throws {
        let tab = makeTab()
        let webView = tab.wkWebView
        let spy = WKWebViewTabDelegateSpy()
        tab.delegate = spy

        webView.loadHTMLString("<p>page</p>", baseURL: URL(string: "https://example.com/"))
        let committed = await pollUntil(timeout: 5) { spy.commits >= 1 }
        XCTAssertTrue(committed)
        XCTAssertNil(screenTime(of: webView), "a tab nobody has seen gets no Screen Time view")

        tab.wasDisplayed()
        let controller = try XCTUnwrap(screenTime(of: webView), "showing the tab reports its page")
        XCTAssertEqual(controller.url, URL(string: "https://example.com/"))
    }

    func testAnAgentsBrowsingIsNotRecordedAsTheUsersUsage() async throws {
        let tab = makeTab()
        let webView = tab.wkWebView
        show(tab)
        tab.isAgentControlled = true

        webView.loadHTMLString("<p>page</p>", baseURL: URL(string: "https://example.com/"))
        let overlaid = await pollUntil(timeout: 5) { self.screenTime(of: webView) != nil }
        XCTAssertTrue(overlaid)
        let controller = try XCTUnwrap(screenTime(of: webView))

        XCTAssertTrue(controller.suppressUsageRecording, "a page an agent opens is not the user's usage")
        tab.isAgentControlled = false
        XCTAssertFalse(controller.suppressUsageRecording, "the tab handed back to the user records again")
        tab.isAgentControlled = true
        XCTAssertTrue(controller.suppressUsageRecording, "a tab an agent takes over stops recording")
    }
}
