import AppKit
import WebKit
import XCTest
@testable import Lilo

/// Sites read `outerWidth - innerWidth` or `outerHeight - innerHeight` over 160 as open devtools, and some then
/// drop their sign-in: the sidebar beside a page must never count as browser chrome.
@MainActor
final class WKWebViewTabWindowFrameTests: XCTestCase {
    func testTheSidebarBesideThePageNeverReadsAsOpenDevTools() async throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let tab = WKEngineFactory().createTab(configuration: WKEngineFactory.Configuration())
        defer { tab.teardown() }
        let webView = tab.wkWebView
        let content = try XCTUnwrap(window.contentView)
        webView.frame = NSRect(x: 300, y: 0, width: 900, height: content.bounds.height - 40)
        content.addSubview(webView)
        window.orderFront(nil)
        webView.loadHTMLString("<p>page</p>", baseURL: URL(string: "https://example.com/"))

        /// The page's [innerWidth, outerWidth - innerWidth, outerHeight - innerHeight], once at `innerWidth` with no devtools-sized gap.
        func chrome(innerWidth: Double) async -> [Double] {
            var read: [Double] = []
            _ = await pollUntil(timeout: 5) {
                read = ((try? await webView.evaluateJavaScript("[innerWidth, outerWidth - innerWidth, outerHeight - innerHeight]")) as? [Double]) ?? []
                return read.count == 3 && read[0] == innerWidth && read[1] < 160 && read[2] < 160
            }
            return read
        }
        var gaps = await chrome(innerWidth: 900)
        XCTAssertEqual(gaps.dropFirst().map { $0 < 160 }, [true, true], "the sidebar counts as chrome: \(gaps)")

        webView.frame = NSRect(x: 0, y: 0, width: 1200, height: content.bounds.height - 40)
        _ = await chrome(innerWidth: 1200)
        webView.frame = NSRect(x: 300, y: 0, width: 900, height: content.bounds.height - 40)
        gaps = await chrome(innerWidth: 900)
        XCTAssertEqual(gaps.dropFirst().map { $0 < 160 }, [true, true], "a sidebar shown again counts as chrome: \(gaps)")
    }
}
