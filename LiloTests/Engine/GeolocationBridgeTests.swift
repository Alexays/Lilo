import WebKit
import XCTest
@testable import Lilo

@MainActor
final class GeolocationBridgeTests: XCTestCase {
    private var asked: [String] = []
    private var bridge: GeolocationBridge!

    override func setUp() async throws {
        asked = []
        bridge = GeolocationBridge()
        bridge.permissionDecisionHandler = { [weak self] _, _, origin, completion in
            self?.asked.append(origin)
            completion(false)
        }
    }

    private func makeWebView(html: String, baseURL: String) async -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(bridge, contentWorld: PageWorld.bridgeWorld, name: GeolocationBridge.messageHandlerName)
        PageWorld.install([GeolocationBridge.pageModule], on: configuration.userContentController)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(html, baseURL: URL(string: baseURL))
        _ = await pollUntil(timeout: 5) { webView.url != nil && !webView.isLoading }
        return webView
    }

    /// Error codes the page's requests got, in arrival order.
    private func codes(_ webView: WKWebView, count: Int) async -> [Int] {
        var codes: [Int] = []
        await pollUntil(timeout: 5) {
            codes = (try? await webView.evaluateJavaScript("window.codes || []")) as? [Int] ?? []
            return codes.count >= count
        }
        return codes
    }

    private static let request = """
        <script>window.codes = []; navigator.geolocation.getCurrentPosition(() => codes.push(0), e => codes.push(e.code));</script>
        """

    func testLoopbackAndFileOriginsMayAsk() async {
        for (base, origin) in [("http://app.localhost:3000/", "http://app.localhost:3000"), ("http://127.0.0.2/", "http://127.0.0.2"),
                               ("file:///tmp/page.html", "file://")] {
            asked = []
            let webView = await makeWebView(html: Self.request, baseURL: base)
            let codes = await codes(webView, count: 1)
            XCTAssertEqual(asked, [origin], base)
            XCTAssertEqual(codes, [1], base)
        }
    }

    func testAnInsecureOriginIsDeniedWithoutAsking() async {
        let webView = await makeWebView(html: Self.request, baseURL: "http://example.com/")
        let codes = await codes(webView, count: 1)
        XCTAssertEqual(codes, [1])
        XCTAssertEqual(asked, [])
    }
}
