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
        let proxy = try await TinyCONNECTProxy { host, _ in
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
