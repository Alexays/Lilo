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

    /// A page at `baseURL` whose data store delegate gives its site `stored`, while the profile now holds `current`.
    private func makeWebView(at baseURL: String, stored: Bool, current: Bool?) throws -> WKWebView {
        let url = try XCTUnwrap(URL(string: baseURL))
        let origin = PermissionOriginKey.build(scheme: try XCTUnwrap(url.scheme), host: try XCTUnwrap(url.host), port: url.port ?? 0)
        let bridge = NotificationBridge()
        bridge.storeDecisionsHandler = { _ in [origin: stored] }
        bridge.decisionHandler = { _, _ in current }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        _ = unsafe configuration.websiteDataStore.perform(NSSelectorFromString("set_delegate:"), with: bridge)
        configuration.userContentController.add(bridge, contentWorld: PageWorld.bridgeWorld, name: NotificationBridge.messageHandlerName)
        PageWorld.install([NotificationBridge.pageModule], on: configuration.userContentController)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<script>window.initial = Notification.permission</script>", baseURL: url)
        return webView
    }

    /// The value `Notification.permission` had for the first script of the page.
    private func initialPermission(of webView: WKWebView) async -> String? {
        var initial: String?
        await pollUntil(timeout: 5) {
            initial = (try? await webView.evaluateJavaScript("window.initial")) as? String
            return initial != nil
        }
        return initial
    }

    func testSecureContextsKnowTheirSitesDecisionAtDocumentStart() async throws {
        for base in ["https://example.com/", "http://app.localhost:3000/", "http://127.0.0.2/"] {
            let permission = try await initialPermission(of: makeWebView(at: base, stored: true, current: true))
            XCTAssertEqual(permission, "granted", base)
        }
    }

    /// WebKit's table is read when the page's process starts, so a decision changed since then reaches the page by the query.
    func testAPageLearnsADecisionChangedSinceItsProcessStarted() async throws {
        let webView = try makeWebView(at: "https://example.com/", stored: true, current: nil)
        let initial = await initialPermission(of: webView)
        XCTAssertEqual(initial, "granted")
        var permission: String?
        await pollUntil(timeout: 5) {
            permission = (try? await webView.evaluateJavaScript("Notification.permission")) as? String
            return permission == "default"
        }
        XCTAssertEqual(permission, "default")
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

    func testABlockedSiteReadsDenied() async throws {
        let permission = try await initialPermission(of: makeWebView(at: "https://example.com/", stored: false, current: false))
        XCTAssertEqual(permission, "denied")
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
