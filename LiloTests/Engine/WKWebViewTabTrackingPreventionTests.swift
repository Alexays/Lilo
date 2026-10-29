import Network
import WebKit
import XCTest
@testable import Lilo

/// Tracking prevention keeps the sign-in of a site the user interacts with, once it classifies that site
/// as a tracker; a classified site left alone loses its cookies.
@MainActor
final class WKWebViewTabTrackingPreventionTests: XCTestCase {
    typealias URLDone = @convention(c) (AnyObject, Selector, NSURL, @escaping @convention(block) () -> Void) -> Void
    typealias Done = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
    typealias Advance = @convention(c) (AnyObject, Selector, Double, @escaping @convention(block) () -> Void) -> Void

    func testAnInteractedSiteKeepsItsSignInWhenClassifiedAsATracker() async throws {
        // WebKit's tracker classification runs on its own schedule: minutes under a full parallel run.
        executionTimeAllowance = 600
        // WebKit's classifier ignores loopback hosts: real-looking ones go through a CONNECT proxy.
        let proxy = try await TinyProxyServer { host in
            ("200 OK", ["Content-Type: text/html", "Set-Cookie: SID=\(host); Path=/; Max-Age=31536000; HttpOnly"], Data("<p>\(host)</p>".utf8))
        }
        let factory = WKEngineFactory()
        factory.setTrackingPrevention(true)
        let id = UUID()
        let dataStore = factory.createDataStore(persistent: true, identifier: id.uuidString)
        let store = dataStore.backingStore
        store.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: proxy.port))))]
        let tab = factory.createTab(configuration: .init(dataStore: dataStore))
        defer { tab.teardown() }
        addTeardownBlock { try? await WKWebsiteDataStore.remove(forIdentifier: id) }

        for host in ["used.test", "unused.test"] {
            tab.wkWebView.load(URLRequest(url: try XCTUnwrap(URL(string: "http://\(host)/"))))
            _ = await pollUntil { tab.wkWebView.url?.host == host && !tab.wkWebView.isLoading }
        }
        tab.wkWebView.load(URLRequest(url: try XCTUnwrap(URL(string: "http://used.test/"))))
        _ = await pollUntil { tab.wkWebView.url?.host == "used.test" && !tab.wkWebView.isLoading }
        tab.logUserInteraction()

        let setPrevalent = NSSelectorFromString("_setPrevalentDomain:completionHandler:")
        for host in ["used.test", "unused.test"] {
            let url = try XCTUnwrap(URL(string: "http://\(host)/"))
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                unsafeBitCast(store.method(for: setPrevalent), to: URLDone.self)(store, setPrevalent, url as NSURL) { done.resume() }
            }
        }
        // 20 days of browsing: inside the 30 days an interaction protects a site for.
        let advance = NSSelectorFromString("_setResourceLoadStatisticsTimeAdvanceForTesting:completionHandler:")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            unsafeBitCast(store.method(for: advance), to: Advance.self)(store, advance, 20 * 86400) { done.resume() }
        }
        let process = NSSelectorFromString("_processStatisticsAndDataRecords:")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            unsafeBitCast(store.method(for: process), to: Done.self)(store, process) { done.resume() }
        }

        var domains: Set<String> = []
        let purged = await pollUntil(timeout: 10) {
            domains = Set(await store.httpCookieStore.allCookies().map(\.domain))
            return !domains.contains("unused.test")
        }
        XCTAssertTrue(purged, "a classified site never interacted with loses its cookies")
        XCTAssertEqual(domains, ["used.test"])
    }
}

/// A CONNECT proxy answering every tunneled request itself with `respond(host)`.
private final class TinyProxyServer: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16

    init(respond: @escaping @Sendable (_ host: String) -> TinyHTTPServer.Response) async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let target = String(decoding: data ?? Data(), as: UTF8.self).split(separator: " ").dropFirst().first ?? ""
                let host = String(target.split(separator: ":").first ?? "")
                connection.send(content: Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8), completion: .contentProcessed { _ in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                        let response = respond(host)
                        let head = (["HTTP/1.1 \(response.status)"] + response.headers + ["Content-Length: \(response.body.count)", "Connection: close", "", ""])
                            .joined(separator: "\r\n")
                        connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
                    }
                })
            }
        }
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state { continuation.yield(listener.port?.rawValue ?? 0); continuation.finish() }
            }
        }
        listener.start(queue: .global())
        var port: UInt16 = 0
        for await value in ready { port = value }
        self.port = port
    }

    deinit { listener.cancel() }
}
