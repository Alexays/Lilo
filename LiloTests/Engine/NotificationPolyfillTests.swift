import WebKit
import XCTest
@testable import Lilo

@MainActor
final class NotificationPolyfillTests: XCTestCase {
    private final class Recorder: NSObject, WKScriptMessageHandler {
        var messages: [[String: Any]] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] { messages.append(body) }
        }
    }

    private func makeWebView(_ recorder: Recorder) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(recorder, name: NotificationBridge.messageHandlerName)
        configuration.userContentController.addUserScript(
            WKUserScript(source: NotificationBridge.polyfillSource, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<html></html>", baseURL: URL(string: "https://example.com"))
        _ = await pollUntil(timeout: 5) { webView.url != nil && !webView.isLoading }
        return webView
    }

    func testClickRunsOnclickAndListenersAndCloseReachesTheHost() async throws {
        let recorder = Recorder()
        let webView = try await makeWebView(recorder)

        _ = try await webView.evaluateJavaScript("""
            window.log = [];
            window.n = new Notification('Hello', { tag: 't' });
            n.onclick = () => log.push('onclick');
            n.addEventListener('click', () => log.push('listener'));
            0
            """)
        _ = await pollUntil { recorder.messages.contains { $0["type"] as? String == "show" } }
        let show = try XCTUnwrap(recorder.messages.first { $0["type"] as? String == "show" })
        let id = try XCTUnwrap(show["id"] as? Int)

        _ = try await webView.evaluateJavaScript("window.__liloNotifyClick(\(id)); 0")
        let log = try await webView.evaluateJavaScript("log.join(',')") as? String
        XCTAssertEqual(log, "onclick,listener")

        _ = try await webView.evaluateJavaScript("window.m = new Notification('Bye'); m.close(); 0")
        _ = await pollUntil { recorder.messages.contains { $0["type"] as? String == "close" } }
        XCTAssertTrue(recorder.messages.contains { $0["type"] as? String == "close" })
    }
}
