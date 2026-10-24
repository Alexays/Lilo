import AppKit
import WebKit
import XCTest
@testable import Lilo

/// The floating panel is titled with the page it hosts.
@MainActor
final class FloatingTabPanelControllerTests: XCTestCase {
    func testThePanelTitleFollowsThePage() async throws {
        let engine = WKWebViewTab(webView: WKWebView(frame: .zero))
        defer { engine.teardown() }
        engine.wkWebView.loadHTMLString("<title>Call</title>", baseURL: URL(string: "https://example.com/"))
        await pollUntil(timeout: 5) { engine.wkWebView.title == "Call" }
        let controller = FloatingTabPanelController()
        defer { controller.dismiss() }

        controller.float(engine)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.delegate === controller })
        // Transparent before it ever draws, so nothing shows to whoever runs the tests.
        panel.alphaValue = 0
        XCTAssertEqual(panel.title, "Call")

        _ = try await engine.wkWebView.evaluateJavaScript("document.title = '(1) Call'; true")

        let followed = await pollUntil(timeout: 5) { panel.title == "(1) Call" }
        XCTAssertTrue(followed, panel.title)
    }
}
