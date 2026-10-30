import WebKit
import XCTest
import os
@testable import Lilo

/// What a page may start on its own, against what only the user (through Lilo) may.
@MainActor
final class WKWebViewTabNavigationPolicyTests: XCTestCase {
    func testAnExternalAppLinkInAFrameNamesTheFrameThatFollowedIt() async throws {
        let framed = try await TinyHTTPServer(index: "<script>location = 'zoommtg://join'</script>")
        let tab = WKWebViewTab(configuration: WKWebViewConfiguration())
        let spy = WKWebViewTabDelegateSpy()
        tab.delegate = spy

        tab.wkWebView.loadHTMLString("<iframe src='http://127.0.0.1:\(framed.port)/'></iframe>", baseURL: URL(string: "http://example.com/"))

        let launched = await pollUntil(timeout: 10) { !spy.externalLaunches.isEmpty }
        XCTAssertTrue(launched)
        XCTAssertEqual(spy.externalLaunches.first?.origin, "http://127.0.0.1:\(framed.port)", "the frame's origin, not the page's, as in Chrome")
    }

    /// A server whose `/slow` answers after a while, so a navigation to it stays pending meanwhile.
    private func slowServer() async throws -> TinyHTTPServer {
        try await TinyHTTPServer { request in
            if request.hasPrefix("GET /slow") { Thread.sleep(forTimeInterval: 1.5) }
            return ("200 OK", ["Content-Type: text/html"], Data("<p>page</p>".utf8))
        }
    }

    private func loadedTab(_ url: URL) async throws -> (WKWebViewTab, WKWebViewTabDelegateSpy) {
        let tab = WKWebViewTab(configuration: WKWebViewConfiguration())
        let spy = WKWebViewTabDelegateSpy()
        tab.delegate = spy
        tab.loadURL(url)
        let loaded = await pollUntil(timeout: 10) { spy.commits == 1 && !tab.isLoading }
        XCTAssertTrue(loaded)
        return (tab, spy)
    }

    func testANavigationThePageStartsShowsItsAddressOnlyOnceItCommits() async throws {
        let server = try await slowServer()
        let page = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/"))
        let target = try XCTUnwrap(URL(string: "http://localhost:\(server.port)/slow"))
        let (tab, spy) = try await loadedTab(page)

        _ = try await tab.wkWebView.evaluateJavaScript("location = '\(target.absoluteString)'; 1")
        let started = await pollUntil(timeout: 10) { tab.wkWebView.url == target }
        XCTAssertTrue(started)
        XCTAssertEqual(tab.currentURL, page, "the page still showing keeps its address, as in Chrome")
        XCTAssertFalse(spy.updatedURLs.contains(target))

        let committed = await pollUntil(timeout: 10) { spy.commits == 2 }
        XCTAssertTrue(committed)
        XCTAssertEqual(tab.currentURL, target)
        XCTAssertEqual(spy.updatedURLs.last, target)
    }

    func testAPagesSameDocumentNavigationShowsItsAddressAtOnce() async throws {
        let server = try await slowServer()
        let page = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/"))
        let (tab, spy) = try await loadedTab(page)

        _ = try await tab.wkWebView.evaluateJavaScript("location.hash = 'section'; 1")

        let shown = await pollUntil(timeout: 10) { spy.updatedURLs.last == URL(string: "\(page.absoluteString)#section") }
        XCTAssertTrue(shown, "nothing loads: the address changes with the page")
    }

    func testALoadLiloStartsShowsItsAddressAtOnce() async throws {
        let server = try await slowServer()
        let target = try XCTUnwrap(URL(string: "http://localhost:\(server.port)/slow"))
        let (tab, spy) = try await loadedTab(try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/")))

        tab.loadURL(target)

        let started = await pollUntil(timeout: 10) { spy.events.count == 4 }
        XCTAssertTrue(started)
        XCTAssertEqual(tab.currentURL, target, "a typed address shows while it loads")
    }

    func testAFailedNavigationThePageStartedNamesTheAddressThatFailed() async throws {
        let server = try await slowServer()
        let (tab, spy) = try await loadedTab(try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/")))
        // TLS against a plain HTTP server: a failure surfaced at once, without an automatic retry.
        let target = try XCTUnwrap(URL(string: "https://localhost:\(server.port)/"))

        _ = try await tab.wkWebView.evaluateJavaScript("location = '\(target.absoluteString)'; 1")

        let failed = await pollUntil(timeout: 10) {
            if case .failed = spy.events.last { return true } else { return false }
        }
        XCTAssertTrue(failed)
        guard case .failed(let url, _) = spy.events.last else { return }
        XCTAssertEqual(url, target, "the error page names the failed address, as in Chrome")
    }

    func testOnlyTheUserOpensAPagesSource() async throws {
        let requests = OSAllocatedUnfairLock<[String]>(initialState: [])
        let server = try await TinyHTTPServer { request in
            requests.withLock { $0.append(String(request.prefix { $0 != "\r" })) }
            return ("200 OK", ["Content-Type: text/html"], Data("<p>account</p>".utf8))
        }
        let source = try XCTUnwrap(URL(string: "view-source:http://127.0.0.1:\(server.port)/account"))
        let factory = WKEngineFactory()
        let tab = factory.createTab(configuration: .init(dataStore: factory.createDataStore(persistent: false, identifier: nil)))
        defer { tab.teardown() }
        let spy = WKWebViewTabDelegateSpy()
        tab.delegate = spy
        tab.wkWebView.loadHTMLString("<p>page</p>", baseURL: URL(string: "http://example.com/"))
        _ = await pollUntil(timeout: 10) { spy.commits == 1 && !tab.isLoading }

        _ = try await tab.wkWebView.evaluateJavaScript("location = '\(source.absoluteString)'; 1")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(requests.withLock { $0 }, [], "a page cannot open another page's source, as in Chrome")

        tab.loadURL(source)
        let opened = await pollUntil(timeout: 10) { spy.commits == 2 }
        XCTAssertTrue(opened)
        XCTAssertEqual(tab.currentURL, source)
    }
}
