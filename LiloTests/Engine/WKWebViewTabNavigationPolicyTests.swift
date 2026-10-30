import AppKit
import Network
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

    func testAPageThatLosesItsConnectionKeepsWhatItShowed() async throws {
        // Headers announcing more than the body sent, then the connection drops.
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 100000\r\n\r\n<p>partial</p>"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { connection.forceCancel() }
                })
            }
        }
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { if case .ready = $0 { continuation.yield(listener.port?.rawValue ?? 0); continuation.finish() } }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        var port: UInt16 = 0
        for await value in ready { port = value }
        let tab = WKWebViewTab(configuration: WKWebViewConfiguration())
        let spy = WKWebViewTabDelegateSpy()
        tab.delegate = spy

        tab.loadURL(try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/")))

        let ended = await pollUntil(timeout: 10) { spy.events.contains { if case .finished = $0 { true } else { false } } }
        XCTAssertTrue(ended, "the load ends with the part that loaded")
        XCTAssertFalse(spy.events.contains { if case .failed = $0 { true } else { false } }, "no error page over it, as in Chrome")
    }

    /// A tab in an off-screen window, showing a page a form sent with POST; `posts` counts the form's sends.
    private func formResultTab() async throws -> (tab: WKWebViewTab, window: NSWindow, spy: WKWebViewTabDelegateSpy, posts: () -> Int, server: TinyHTTPServer) {
        let posts = OSAllocatedUnfairLock(initialState: 0)
        let server = try await TinyHTTPServer { request in
            guard request.hasPrefix("POST") else {
                return ("200 OK", ["Content-Type: text/html"], Data("<form method=post action=/order><input name=item value=1></form><script>document.forms[0].submit()</script>".utf8))
            }
            posts.withLock { $0 += 1 }
            return ("200 OK", ["Content-Type: text/html"], Data("<p>ordered</p>".utf8))
        }
        let tab = WKWebViewTab(configuration: WKWebViewConfiguration())
        let spy = WKWebViewTabDelegateSpy()
        tab.delegate = spy
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = tab.wkWebView
        window.orderFrontRegardless()
        tab.loadURL(try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/")))
        let ordered = await pollUntil(timeout: 10) { posts.withLock { $0 } == 1 && spy.commits == 2 && !tab.isLoading }
        XCTAssertTrue(ordered)
        return (tab, window, spy, { posts.withLock { $0 } }, server)
    }

    func testReloadingAPageAFormSentAsksBeforeSendingTheFormAgain() async throws {
        let (tab, window, _, posts, server) = try await formResultTab()
        defer { window.close(); _ = server }

        tab.reload()
        let asked = await pollUntil(timeout: 10) { window.attachedSheet != nil }
        XCTAssertTrue(asked, "Chrome's Confirm Form Resubmission")
        XCTAssertEqual(posts(), 1)
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertSecondButtonReturn)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(posts(), 1, "Cancel sends nothing")

        tab.reload()
        _ = await pollUntil(timeout: 10) { window.attachedSheet != nil }
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        let sent = await pollUntil(timeout: 10) { posts() == 2 }
        XCTAssertTrue(sent, "Continue sends the form again")
    }

    func testAPageAFormSentIsNotSentAgainAfterItsProcessEnds() async throws {
        let (tab, window, spy, posts, server) = try await formResultTab()
        defer { window.close(); _ = server }
        let kill = NSSelectorFromString("_killWebContentProcessAndResetState")
        try XCTSkipUnless(tab.wkWebView.responds(to: kill))

        tab.wkWebView.perform(kill)

        let failed = await pollUntil(timeout: 10) { if case .failed = spy.events.last { true } else { false } }
        XCTAssertTrue(failed, "the crash shows, as in Chrome")
        XCTAssertEqual(posts(), 1)
        XCTAssertNil(window.attachedSheet, "nothing is asked until the user tries again")
    }
}
