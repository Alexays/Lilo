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

    /// Frames post `<name>:<code>` to the top page, which collects them in `results`.
    private func frameResults(top: String, baseURL: String, count: Int) async throws -> [String] {
        let frame = "<script>navigator.geolocation.getCurrentPosition(() => parent.postMessage(location.search + ':0', '*'), "
            + "e => parent.postMessage(location.search + ':' + e.code, '*'));</script>"
        let server = try await TinyHTTPServer { _ in ("200 OK", ["Content-Type: text/html"], Data(frame.utf8)) }
        let html = "<script>window.results = []; addEventListener('message', e => results.push(e.data));</script>"
            + top.replacingOccurrences(of: "PORT", with: String(server.port))
        let webView = await makeWebView(html: html, baseURL: baseURL.replacingOccurrences(of: "PORT", with: String(server.port)))
        var results: [String] = []
        await pollUntil(timeout: 5) {
            results = (try? await webView.evaluateJavaScript("results")) as? [String] ?? []
            return results.count >= count
        }
        return results.sorted()
    }

    func testACrossOriginFrameAsksUnderThePagesOriginOnlyWhenAllowed() async throws {
        let results = try await frameResults(top: """
            <iframe src="http://localhost:PORT/?none"></iframe>
            <iframe allow="geolocation" src="http://localhost:PORT/?allowed"></iframe>
            <iframe src="http://127.0.0.1:PORT/?same"></iframe>
            """, baseURL: "http://127.0.0.1:PORT/", count: 3)
        XCTAssertEqual(results, ["?allowed:1", "?none:1", "?same:1"])
        XCTAssertEqual(asked.count, 2, "the frame without allow= is refused without asking")
        XCTAssertTrue(asked.allSatisfy { $0.hasPrefix("http://127.0.0.1:") }, "asked under the page's origin: \(asked)")
    }

    func testAFrameUnderAnInsecurePageIsDeniedWithoutAsking() async throws {
        let results = try await frameResults(top: #"<iframe allow="geolocation" src="http://localhost:PORT/?frame"></iframe>"#,
                                             baseURL: "http://example.com/", count: 1)
        XCTAssertEqual(results, ["?frame:1"])
        XCTAssertEqual(asked, [])
    }

    func testAnInsecureOriginIsDeniedWithoutAsking() async {
        let webView = await makeWebView(html: Self.request, baseURL: "http://example.com/")
        let codes = await codes(webView, count: 1)
        XCTAssertEqual(codes, [1])
        XCTAssertEqual(asked, [])
    }
}
