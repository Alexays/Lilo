import WebKit
import XCTest
@testable import Lilo

/// What a page may start on its own, against what only the user (through Lilo) may.
@MainActor
final class WKWebViewTabNavigationPolicyTests: XCTestCase {
    func testAnExternalAppLinkInAFrameNamesTheFrameThatFollowedIt() async throws {
        let framed = try await TinyHTTPServer(index: "<script>location = 'zoommtg://join'</script>")
        let tab = WKWebViewTab(configuration: WKWebViewConfiguration())
        let spy = WKWebViewTabDelegateSpy()
        tab.delegate = spy

        tab.wkWebView.loadHTMLString("<iframe src='http://127.0.0.1:\(framed.port)/'></iframe>", baseURL: URL(string: "http://example.com/"))

        let launched = await pollUntil(timeout: 10) { !spy.externalLaunches.isEmpty }
        XCTAssertTrue(launched)
        XCTAssertEqual(spy.externalLaunches.first?.origin, "http://127.0.0.1:\(framed.port)", "the frame's origin, not the page's, as in Chrome")
    }
}
