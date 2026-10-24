import ScreenTime
import WebKit
import XCTest
@testable import Lilo

@MainActor
final class ScreenTimeReportingTests: XCTestCase {
    func testAWebPageGetsTheScreenTimeOverlayWithoutLosingClicks() async {
        WKWebViewTab.reportsToScreenTime = true
        defer { WKWebViewTab.reportsToScreenTime = false }
        let factory = WKEngineFactory()
        let tab = factory.createTab(configuration: .init(dataStore: factory.defaultDataStore()))
        defer { tab.teardown() }
        let webView = tab.wkWebView
        webView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)

        webView.loadHTMLString("<p>page</p>", baseURL: URL(string: "https://example.com/"))
        let overlaid = await pollUntil(timeout: 5) {
            webView.subviews.contains { String(describing: type(of: $0)).contains("STWebpage") }
        }

        XCTAssertTrue(overlaid, "a committed web page reports to Screen Time through its overlay view")
        XCTAssertIdentical(webView.hitTest(NSPoint(x: 200, y: 150)), webView, "clicks still reach the page")
    }

    func testAnAgentsBrowsingIsNotRecordedAsTheUsersUsage() async throws {
        WKWebViewTab.reportsToScreenTime = true
        defer { WKWebViewTab.reportsToScreenTime = false }
        let factory = WKEngineFactory()
        let tab = factory.createTab(configuration: .init(dataStore: factory.defaultDataStore()))
        defer { tab.teardown() }
        let webView = tab.wkWebView
        tab.isAgentControlled = true

        webView.loadHTMLString("<p>page</p>", baseURL: URL(string: "https://example.com/"))
        let overlaid = await pollUntil(timeout: 5) { webView.subviews.contains { $0.nextResponder is STWebpageController } }
        XCTAssertTrue(overlaid)
        let controller = try XCTUnwrap(webView.subviews.lazy.compactMap { $0.nextResponder as? STWebpageController }.first)

        XCTAssertTrue(controller.suppressUsageRecording, "a page an agent opens is not the user's usage")
        tab.isAgentControlled = false
        XCTAssertFalse(controller.suppressUsageRecording, "the tab handed back to the user records again")
        tab.isAgentControlled = true
        XCTAssertTrue(controller.suppressUsageRecording, "a tab an agent takes over stops recording")
    }
}
