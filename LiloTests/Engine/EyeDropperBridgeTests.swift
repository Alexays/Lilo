import AppKit
import WebKit
import XCTest
@testable import Lilo

@MainActor
final class EyeDropperBridgeTests: XCTestCase {
    private func makeWebView(sampled: NSColor?) async -> WKWebView {
        let bridge = EyeDropperBridge()
        bridge.sample = { sampled }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: EyeDropperBridge.messageHandlerName)
        configuration.userContentController.addUserScript(
            WKUserScript(source: EyeDropperBridge.polyfillSource, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<p>pick</p>", baseURL: URL(string: "https://example.com/"))
        _ = await pollUntil(timeout: 5) { webView.url != nil && !webView.isLoading }
        return webView
    }

    func testOpenResolvesWithThePickedColorInHex() async throws {
        let webView = await makeWebView(sampled: NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1))
        let hex = try await webView.callAsyncJavaScript("return (await new EyeDropper().open()).sRGBHex", contentWorld: .page) as? String
        XCTAssertEqual(hex, "#ff8000")
    }

    func testCancelingRejectsWithAbortError() async throws {
        let webView = await makeWebView(sampled: nil)
        let name = try await webView.callAsyncJavaScript(
            "try { await new EyeDropper().open(); return 'resolved'; } catch (e) { return e.name; }", contentWorld: .page) as? String
        XCTAssertEqual(name, "AbortError")
    }
}
