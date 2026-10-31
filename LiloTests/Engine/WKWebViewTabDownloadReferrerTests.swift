import AppKit
import WebKit
import XCTest
@testable import Lilo

/// The Referer of a context-menu download follows the clicked frame's referrer policy, as in Chrome.
@MainActor
final class WKWebViewTabDownloadReferrerTests: XCTestCase {
    /// Stands in for `_WKContextMenuElementInfo` and its `_WKHitTestResult`, read by KVC.
    private final class Element: NSObject {
        final class HitTest: NSObject {
            @objc var absoluteImageURL: URL?
            @objc var absoluteLinkURL: URL?
            @objc var absoluteMediaURL: URL?
            @objc var frameInfo: WKFrameInfo?
        }
        @objc let hitTestResult = HitTest()
    }

    /// Collects each frame's `WKFrameInfo` by its address.
    private final class FrameCollector: NSObject, WKScriptMessageHandler {
        var frames: [String: WKFrameInfo] = [:]
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let href = message.body as? String { frames[href] = message.frameInfo }
        }
    }

    private final class Referers: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ value: String) { lock.withLock { values.append(value) } }
        var all: [String] { lock.withLock { values } }
    }

    /// Pages are served by path: `/<Referrer-Policy>/...` sets that header, `/none/...` none.
    private func pageServer(_ html: @escaping @Sendable (String) -> String) async throws -> TinyHTTPServer {
        try await TinyHTTPServer { request in
            let path = String(request.split(separator: " ").dropFirst().first ?? "/")
            let policy = path.split(separator: "/").first.map(String.init) ?? "none"
            let headers = ["Content-Type: text/html"] + (policy == "none" ? [] : ["Referrer-Policy: \(policy)"])
            return ("200 OK", headers, Data(html(path).utf8))
        }
    }

    private func fileServer(_ referers: Referers) async throws -> TinyHTTPServer {
        try await TinyHTTPServer { request in
            let referer = request.split(separator: "\r\n").first { $0.lowercased().hasPrefix("referer:") }
            referers.append(referer.map { String($0.dropFirst("referer:".count)).trimmingCharacters(in: .whitespaces) } ?? "none")
            return ("200 OK", ["Content-Type: application/octet-stream"], Data("file".utf8))
        }
    }

    /// Loads the page, opens the context menu on `frameURL`'s frame for an image or a link, chooses its download item and
    /// returns the Referer the download sent ("none" without one). `hang` runs in the page just before, without waiting.
    /// Whatever the page does, a download opens no tab or window.
    private func downloadReferer(
        page load: (WKWebView) -> Void, frameURL: String, image: URL? = nil, link: URL? = nil, hang: String? = nil, referers: Referers
    ) async throws -> String? {
        let collector = FrameCollector()
        let configuration = WKWebViewConfiguration()
        let world = WKContentWorld.world(name: "test-frames")
        configuration.userContentController.add(collector, contentWorld: world, name: "frames")
        configuration.userContentController.addUserScript(WKUserScript(
            source: "webkit.messageHandlers.frames.postMessage(location.href)", injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: world
        ))
        let tab = WKWebViewTab(configuration: configuration)
        let spy = WKWebViewTabDelegateSpy()
        tab.delegate = spy
        var popups = 0
        tab.popupWebViewProvider = { _, _, _ in popups += 1; return nil }
        load(tab.wkWebView)
        let framed = await pollUntil(timeout: 10) { collector.frames[frameURL] != nil }
        XCTAssertTrue(framed, "no frame at \(frameURL) among \(collector.frames.keys)")

        let element = Element()
        element.hitTestResult.absoluteImageURL = image
        element.hitTestResult.absoluteLinkURL = link
        element.hitTestResult.frameInfo = collector.frames[frameURL]
        if let hang { tab.wkWebView.evaluateJavaScript(hang, completionHandler: nil) }
        let menu = NSMenu()
        tab.webView(tab.wkWebView, getContextMenuFromProposedMenu: menu, forElement: element, userInfo: nil) { _ in }
        let item = try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString("contextMenuDownload:") })
        NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)

        let sent = await pollUntil(timeout: 10) { !referers.all.isEmpty }
        XCTAssertTrue(sent, "the download never reached the server")
        // Replies once a hung page runs its late probe; a window it opened would come within a second.
        _ = try await tab.wkWebView.evaluateJavaScript("1")
        if hang != nil { _ = await pollUntil(timeout: 1) { popups > 0 || !spy.newTabs.isEmpty } }
        XCTAssertEqual(popups, 0)
        XCTAssertEqual(spy.newTabs, [])
        return referers.all.first
    }

    func testAPageWithNoReferrerPolicySendsNoReferer() async throws {
        let pages = try await pageServer { _ in "<p>page</p>" }
        let referers = Referers()
        let files = try await fileServer(referers)
        let page = "http://127.0.0.1:\(pages.port)/no-referrer/article?token=1"

        let referer = try await downloadReferer(
            page: { $0.load(URLRequest(url: URL(string: page)!)) }, frameURL: page,
            image: URL(string: "http://127.0.0.1:\(files.port)/image.png"), referers: referers
        )

        XCTAssertEqual(referer, "none")
    }

    func testAPageWithUnsafeURLPolicySendsItsFullAddress() async throws {
        let pages = try await pageServer { _ in "<p>page</p>" }
        let referers = Referers()
        let files = try await fileServer(referers)
        let page = "http://127.0.0.1:\(pages.port)/unsafe-url/article?token=1"

        let referer = try await downloadReferer(
            page: { $0.load(URLRequest(url: URL(string: page)!)) }, frameURL: page,
            image: URL(string: "http://127.0.0.1:\(files.port)/image.png"), referers: referers
        )

        XCTAssertEqual(referer, page)
    }

    func testAHungPageGetsItsDownloadWithTheDefaultPolicy() async throws {
        let pages = try await pageServer { _ in "<p>page</p>" }
        let referers = Referers()
        let files = try await fileServer(referers)
        let page = "http://127.0.0.1:\(pages.port)/unsafe-url/article?token=1"

        let referer = try await downloadReferer(
            page: { $0.load(URLRequest(url: URL(string: page)!)) }, frameURL: page,
            image: URL(string: "http://127.0.0.1:\(files.port)/image.png"),
            hang: "const end = Date.now() + 3000; while (Date.now() < end) {}", referers: referers
        )

        XCTAssertEqual(referer, "http://127.0.0.1:\(pages.port)/", "strict-origin-when-cross-origin, without waiting for the page")
    }

    func testAPageWithoutAPolicySendsItsOriginCrossOrigin() async throws {
        let pages = try await pageServer { _ in "<p>page</p>" }
        let referers = Referers()
        let files = try await fileServer(referers)
        let page = "http://127.0.0.1:\(pages.port)/none/article?token=1"

        let referer = try await downloadReferer(
            page: { $0.load(URLRequest(url: URL(string: page)!)) }, frameURL: page,
            image: URL(string: "http://127.0.0.1:\(files.port)/image.png"), referers: referers
        )

        XCTAssertEqual(referer, "http://127.0.0.1:\(pages.port)/")
    }

    func testASecurePageSendsNoRefererToAnInsecureAddress() async throws {
        let referers = Referers()
        let files = try await fileServer(referers)
        let page = "https://example.com/article?token=1"

        let referer = try await downloadReferer(
            page: { $0.loadHTMLString("<p>page</p>", baseURL: URL(string: page)) }, frameURL: page,
            image: URL(string: "http://127.0.0.1:\(files.port)/image.png"), referers: referers
        )

        XCTAssertEqual(referer, "none")
    }

    func testAnImageInAFrameFollowsTheFramesPolicyAndAddress() async throws {
        let pages = try await pageServer { path in
            path.hasPrefix("/no-referrer/") ? "<iframe src='/unsafe-url/frame?id=2'></iframe>" : "<p>frame</p>"
        }
        let referers = Referers()
        let files = try await fileServer(referers)
        let frame = "http://127.0.0.1:\(pages.port)/unsafe-url/frame?id=2"

        let referer = try await downloadReferer(
            page: { $0.load(URLRequest(url: URL(string: "http://127.0.0.1:\(pages.port)/no-referrer/article")!)) }, frameURL: frame,
            image: URL(string: "http://127.0.0.1:\(files.port)/image.png"), referers: referers
        )

        XCTAssertEqual(referer, frame)
    }

    func testANoReferrerLinkSendsNoReferer() async throws {
        let referers = Referers()
        let files = try await fileServer(referers)
        let file = "http://127.0.0.1:\(files.port)/file.zip"
        let pages = try await pageServer { _ in "<a href='\(file)' rel='noreferrer'>file</a>" }
        let page = "http://127.0.0.1:\(pages.port)/unsafe-url/article"

        let referer = try await downloadReferer(
            page: { $0.load(URLRequest(url: URL(string: page)!)) }, frameURL: page, link: URL(string: file), referers: referers
        )

        XCTAssertEqual(referer, "none")
    }
}
