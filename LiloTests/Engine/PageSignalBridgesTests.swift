import WebKit
import XCTest
@testable import Lilo

@MainActor
final class PageSignalBridgesTests: XCTestCase {
    func testASubframeSubmitLeavesTheMainFrameFormDirty() async throws {
        let bridge = FormDirtyBridge()
        var reports: [Bool] = []
        bridge.onChange = { _, dirty in reports.append(dirty) }
        let configuration = WKWebViewConfiguration()
        let controller = configuration.userContentController
        controller.add(bridge, contentWorld: PageWorld.bridgeWorld, name: FormDirtyBridge.messageHandlerName)
        controller.addUserScript(WKUserScript(source: FormDirtyBridge.scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false,
                                              in: PageWorld.bridgeWorld))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<form><input></form><iframe srcdoc='<form><input></form>'></iframe>",
                               baseURL: URL(string: "https://example.com/"))
        _ = await pollUntil(timeout: 5) { webView.url != nil && !webView.isLoading }

        let frameForm = "frames[0].document.querySelector('form')"
        _ = try await webView.evaluateJavaScript("\(frameForm).dispatchEvent(new Event('input', { bubbles: true })); 0")
        _ = await pollUntil(timeout: 5) { reports.count == 1 }
        // The main frame's report comes last: once it is in, the subframe's submit has had its say.
        _ = try await webView.evaluateJavaScript("""
            \(frameForm).dispatchEvent(new Event('submit', { bubbles: true }));
            document.forms[0].dispatchEvent(new Event('input', { bubbles: true }));
            0
            """)
        _ = await pollUntil(timeout: 5) { reports.count >= 2 && reports.last == true }
        XCTAssertEqual(reports, [true, true], "a subframe's submit does not clear the tab")
    }
}
