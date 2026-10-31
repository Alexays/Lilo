import AppKit
import WebKit
import XCTest
@testable import Lilo

@MainActor
final class DocumentPictureInPictureTests: XCTestCase {
    /// Hands the page a real popup web view, as the window controller does, and closes it when the page asks.
    private final class PopupHost: NSObject, WKUIDelegate {
        var popups: [WKWebView] = []

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 300), configuration: configuration)
            popup.uiDelegate = self
            popups.append(popup)
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            webView.perform(NSSelectorFromString("_close"))
        }
    }

    private var bridge: DocumentPiPBridge!
    private var host: PopupHost!
    private var prepared: [NSSize] = []
    private var activations: [Bool] = []

    private func makeWebView(origin: String = "https://example.com/", allow: Bool = true, before: String? = nil) async -> WKWebView {
        bridge = DocumentPiPBridge()
        bridge.onPrepare = { [unowned self] _, size, activated in
            prepared.append(size)
            activations.append(activated)
            return allow
        }
        host = PopupHost()
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: PageWorld.bridgeWorld, name: DocumentPiPBridge.messageHandlerName)
        if let before {
            configuration.userContentController.addUserScript(WKUserScript(source: before, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        PageWorld.install([DocumentPiPBridge.pageModule, DocumentPiPBridge.meetModule], on: configuration.userContentController)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.uiDelegate = host
        webView.loadHTMLString("<p>call</p>", baseURL: URL(string: origin))
        // The URL is set before the document commits: wait for this page's own content, or a commit could follow.
        _ = await pollUntil(timeout: 5) { (try? await webView.evaluateJavaScript("document.body?.textContent === 'call'")) as? Bool == true }
        return webView
    }

    private func run(_ webView: WKWebView, _ body: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, contentWorld: .page)
    }

    func testRequestWindowResolvesASameOriginWindowAndExposesIt() async throws {
        let webView = await makeWebView()

        let result = try await run(webView, """
            const w = await documentPictureInPicture.requestWindow({ width: 300, height: 356 });
            return [w.document.URL, documentPictureInPicture.window === w];
            """) as? [Any]

        XCTAssertEqual(result?.first as? String, "about:blank")
        XCTAssertEqual(result?.last as? Bool, true)
        XCTAssertEqual(prepared, [NSSize(width: 300, height: 356)])
        XCTAssertEqual(host.popups.count, 1)
    }

    func testWindowIsNullAgainAfterThePiPWindowCloses() async throws {
        let webView = await makeWebView()
        _ = try await run(webView, "window.__pip = await documentPictureInPicture.requestWindow({ width: 300, height: 300 }); window.__pip.close(); return 0;")

        let cleared = await pollUntil(timeout: 5) {
            (try? await self.run(webView, "return documentPictureInPicture.window === null;")) as? Bool == true
        }

        XCTAssertTrue(cleared, "the page sees no window once its PiP window is gone")
    }

    func testASecondRequestClosesTheFirstWindow() async throws {
        let webView = await makeWebView()

        let outcome = try await run(webView, """
            const first = documentPictureInPicture.requestWindow({ width: 300, height: 300 }).then(w => 'window', e => e.name);
            const second = await documentPictureInPicture.requestWindow({ width: 320, height: 300 });
            return [await first, documentPictureInPicture.window === second];
            """) as? [Any]

        XCTAssertEqual(outcome?.first as? String, "AbortError", "the replaced request opens nothing")
        XCTAssertEqual(outcome?.last as? Bool, true)
        XCTAssertEqual(host.popups.count, 1, "never two PiP windows")
    }

    func testARefusedRequestKeepsTheOpenWindow() async throws {
        let webView = await makeWebView()
        _ = try await run(webView, "window.__pip = await documentPictureInPicture.requestWindow({ width: 300, height: 300 }); return 0;")
        bridge.onPrepare = { _, _, _ in false }

        let outcome = try await run(webView, """
            const name = await documentPictureInPicture.requestWindow().then(() => 'resolved', e => e.name);
            return [name, documentPictureInPicture.window === window.__pip, window.__pip.closed];
            """) as? [Any]

        XCTAssertEqual(outcome?[0] as? String, "NotAllowedError")
        XCTAssertEqual(outcome?[1] as? Bool, true)
        XCTAssertEqual(outcome?[2] as? Bool, false)
    }

    func testARequestWithoutUserActivationSaysSo() async throws {
        let webView = await makeWebView()

        WebViewPrivateAccessors(webView).evaluateWithoutUserGesture("documentPictureInPicture.requestWindow({ width: 300, height: 300 })")

        let asked = await pollUntil(timeout: 5) { !self.activations.isEmpty }
        XCTAssertTrue(asked)
        XCTAssertEqual(activations, [false], "native refuses a page that opens its PiP window on its own")
    }

    func testRequestWindowRejectsWithNotAllowedErrorWhenNativeRefuses() async throws {
        let webView = await makeWebView(allow: false)

        let name = try await run(webView, "try { await documentPictureInPicture.requestWindow(); return 'resolved'; } catch (e) { return e.name; }") as? String

        XCTAssertEqual(name, "NotAllowedError")
        XCTAssertTrue(host.popups.isEmpty)
    }

    func testMeetSeesChromeOnlyRightAfterTouchingTheAPI() async throws {
        let webView = await makeWebView(origin: "https://meet.google.com/abc-defg-hij")

        let agents = try await run(webView, """
            const before = navigator.userAgent;
            const armed = (window.documentPictureInPicture, navigator.userAgent);
            await Promise.resolve();
            return [before, armed, navigator.userAgent];
            """) as? [String]

        XCTAssertEqual(agents?.count, 3)
        XCTAssertFalse(agents?[0].contains("Chrome/") ?? true, "Meet loads as Safari")
        XCTAssertEqual(agents?[1], ChromeMasquerade.chromeUserAgent)
        XCTAssertFalse(agents?[2].contains("Chrome/") ?? true, "disarmed at the next microtask")
    }

    func testOtherSitesNeverSeeChrome() async throws {
        let webView = await makeWebView(origin: "https://example.com/")

        let agent = try await run(webView, "return (window.documentPictureInPicture, navigator.userAgent);") as? String

        XCTAssertFalse(agent?.contains("Chrome/") ?? true)
    }

    func testTheModuleStepsAsideWhenWebKitShipsTheAPI() async throws {
        let webView = await makeWebView(before: "window.documentPictureInPicture = 1;")

        let value = try await run(webView, "return window.documentPictureInPicture;") as? Int

        XCTAssertEqual(value, 1)
    }
}
