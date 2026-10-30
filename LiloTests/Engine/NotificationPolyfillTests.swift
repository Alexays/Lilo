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

    private func makeWebView(_ recorder: Recorder, baseURL: String = "https://example.com", html: String = "<html></html>") async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(recorder, contentWorld: PageWorld.bridgeWorld, name: NotificationBridge.messageHandlerName)
        PageWorld.install([NotificationBridge.pageModule], on: configuration.userContentController)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(html, baseURL: URL(string: baseURL))
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

        _ = try? await webView.evaluateJavaScript(PageWorld.push("notifyClick", [id]), contentWorld: PageWorld.bridgeWorld)
        let log = try await webView.evaluateJavaScript("log.join(',')") as? String
        XCTAssertEqual(log, "onclick,listener")

        _ = try await webView.evaluateJavaScript("window.m = new Notification('Bye'); m.close(); 0")
        _ = await pollUntil { recorder.messages.contains { $0["type"] as? String == "close" } }
        XCTAssertTrue(recorder.messages.contains { $0["type"] as? String == "close" })
    }

    func testAnUntrustworthyOriginSendsNoQuery() async throws {
        let recorder = Recorder()
        let webView = try await makeWebView(recorder, baseURL: "http://example.com")
        // Posted after the document-start query, so its arrival means the query had its chance to arrive too.
        _ = try await webView.evaluateJavaScript("new Notification('Hello'); 0")
        _ = await pollUntil { recorder.messages.contains { $0["type"] as? String == "show" } }
        XCTAssertFalse(recorder.messages.contains { $0["type"] as? String == "query" })
    }

    /// `Notification.permission` once a page at `baseURL` has had the time to learn its site's `decision`.
    private func permission(at baseURL: String, decision: Bool) async -> String? {
        let bridge = NotificationBridge()
        bridge.allowanceHandler = { _, _ in decision }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(bridge, contentWorld: PageWorld.bridgeWorld, name: NotificationBridge.messageHandlerName)
        PageWorld.install([NotificationBridge.pageModule], on: configuration.userContentController)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<p>page</p>", baseURL: URL(string: baseURL))
        let expected = decision ? "granted" : "denied"
        var permission: String?
        await pollUntil(timeout: 5) {
            permission = (try? await webView.evaluateJavaScript("Notification.permission")) as? String
            return permission == expected
        }
        return permission
    }

    func testSecureContextsLearnTheirSitesDecision() async {
        for base in ["https://example.com/", "http://app.localhost:3000/", "http://127.0.0.2/"] {
            let permission = await permission(at: base, decision: true)
            XCTAssertEqual(permission, "granted", base)
        }
    }

    func testASameOriginSubframeTakesTheTopsPermissionWithoutQuerying() async throws {
        let recorder = Recorder()
        let webView = try await makeWebView(recorder)
        _ = try? await webView.evaluateJavaScript(PageWorld.push("notifySetPermission", ["granted"]), contentWorld: PageWorld.bridgeWorld)
        let queries = { recorder.messages.filter { $0["type"] as? String == "query" }.count }
        let before = queries()
        _ = try await webView.evaluateJavaScript("""
            const frame = document.createElement('iframe');
            frame.srcdoc = '<p>frame</p>';
            document.body.append(frame);
            0
            """)
        var permission: String?
        await pollUntil {
            permission = (try? await webView.evaluateJavaScript("frames[0] && frames[0].Notification.permission")) as? String
            return permission == "granted"
        }
        XCTAssertEqual(permission, "granted")
        // Posted after the frame's document start, as the query would have been.
        _ = try await webView.evaluateJavaScript("new frames[0].Notification('Hello'); 0")
        _ = await pollUntil { recorder.messages.contains { $0["type"] as? String == "show" } }
        XCTAssertEqual(queries(), before, "only the top frame asks")
    }

    func testACrossOriginFrameIsDeniedWithoutAsking() async throws {
        let frame = """
            <script>const initial = Notification.permission;
            Notification.requestPermission().then(result => parent.postMessage(initial + ',' + result, '*'));</script>
            """
        let server = try await TinyHTTPServer { _ in ("200 OK", ["Content-Type: text/html"], Data(frame.utf8)) }
        let bridge = NotificationBridge()
        var asked: [String] = []
        bridge.permissionDecisionHandler = { _, _, origin, completion in asked.append(origin); completion(true) }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(bridge, contentWorld: PageWorld.bridgeWorld, name: NotificationBridge.messageHandlerName)
        PageWorld.install([NotificationBridge.pageModule], on: configuration.userContentController)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("""
            <script>window.results = []; addEventListener('message', e => results.push(e.data));</script>
            <iframe src="http://localhost:\(server.port)/"></iframe>
            """, baseURL: URL(string: "http://127.0.0.1:\(server.port)/"))
        var results: [String] = []
        await pollUntil(timeout: 5) {
            results = (try? await webView.evaluateJavaScript("results")) as? [String] ?? []
            return !results.isEmpty
        }
        XCTAssertEqual(results, ["denied,denied"])
        XCTAssertEqual(asked, [])
    }

    func testATaggedNotificationReplacesTheEarlierOneWithItsTag() async throws {
        let recorder = Recorder()
        let webView = try await makeWebView(recorder)

        _ = try await webView.evaluateJavaScript("""
            window.log = [];
            new Notification('First', { tag: 't' }).onclick = () => log.push('first');
            new Notification('Second', { tag: 't' }).onclick = () => log.push('second');
            0
            """)
        _ = await pollUntil { recorder.messages.filter { $0["type"] as? String == "show" }.count == 2 }
        let ids = recorder.messages.filter { $0["type"] as? String == "show" }.compactMap { $0["id"] as? Int }
        XCTAssertEqual(ids.count, 2)

        for id in ids {
            _ = try? await webView.evaluateJavaScript(PageWorld.push("notifyClick", [id]), contentWorld: PageWorld.bridgeWorld)
        }
        let log = try await webView.evaluateJavaScript("log.join(',')") as? String
        XCTAssertEqual(log, "second")
    }
}
