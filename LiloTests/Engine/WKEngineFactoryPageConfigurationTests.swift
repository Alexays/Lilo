import os
import WebKit
import XCTest
@testable import Lilo

@MainActor
final class WKEngineFactoryPageConfigurationTests: XCTestCase {
    func testTabsKeepFraudulentWebsiteWarningsAndLeaveScreenTimeToLilo() throws {
        let factory = WKEngineFactory()
        let tab = factory.createTab(configuration: .init(dataStore: factory.defaultDataStore()))
        defer { tab.teardown() }
        let features = (WKPreferences.self as AnyObject).perform(NSSelectorFromString("_internalDebugFeatures"))?.takeUnretainedValue() as? [NSObject]
        let screenTime = try XCTUnwrap(features?.first { $0.value(forKey: "key") as? String == "ScreenTimeEnabled" })
        let preferences = tab.wkWebView.configuration.preferences
        let isEnabled = NSSelectorFromString("_isEnabledForFeature:")
        typealias IsEnabled = @convention(c) (NSObject, Selector, AnyObject) -> ObjCBool

        XCTAssertTrue(preferences.isFraudulentWebsiteWarningEnabled, "Safe Browsing warnings are Lilo's only phishing and malware protection")
        XCTAssertFalse(unsafeBitCast(preferences.method(for: isEnabled), to: IsEnabled.self)(preferences, isEnabled, screenTime).boolValue,
                       "WebKit's own Screen Time client would duplicate Lilo's STWebpageController")
    }

    func testUserAgentAdvertisesTheRunningSafariVersion() {
        let factory = WKEngineFactory()
        let tab = factory.createTab(configuration: .init(dataStore: factory.defaultDataStore()))
        defer { tab.teardown() }

        let safari = Bundle(path: "/Applications/Safari.app")?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let os = ProcessInfo.processInfo.operatingSystemVersion
        XCTAssertEqual(tab.wkWebView.configuration.applicationNameForUserAgent,
                       "Version/\(safari ?? "\(os.majorVersion).\(os.minorVersion)") Safari/605.1.15")
    }

    /// A page's change to navigator.credentials outlives a collection, as in Chrome: WebKit makes a new
    /// object once nothing holds it, which lost a password manager's passkey hooks.
    func testNavigatorCredentialsKeepsWhatThePageSetOnIt() async throws {
        let factory = WKEngineFactory()
        let tab = factory.createTab(configuration: .init(dataStore: factory.defaultDataStore()))
        defer { tab.teardown() }
        tab.wkWebView.loadHTMLString("<p>sign in</p>", baseURL: URL(string: "https://example.com/"))
        _ = await pollUntil { tab.wkWebView.url != nil && !tab.wkWebView.isLoading }

        _ = try await tab.wkWebView.evaluateJavaScript("navigator.credentials.get = function hooked() {}; 1")
        for _ in 0..<20 {
            _ = try await tab.wkWebView.evaluateJavaScript("for (let i = 0; i < 200000; i++) ({ i }); 1")
            try await Task.sleep(for: .milliseconds(50))
        }
        let kept = try await tab.wkWebView.evaluateJavaScript("navigator.credentials.get.name") as? String
        XCTAssertEqual(kept, "hooked")
    }

    /// Third-party cookies follow tracking prevention: off, as by default, a site embedded elsewhere gets the
    /// cookies it set as a first party and keeps the ones it sets there, as in Chrome; on, it gets none.
    func testOnlyTrackingPreventionBlocksThirdPartyCookies() async throws {
        let seen = OSAllocatedUnfairLock<[String]>(initialState: [])
        let embedded = try await TinyHTTPServer { request in
            let cookie = request.split(separator: "\r\n").first { $0.lowercased().hasPrefix("cookie:") }.map(String.init) ?? ""
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            seen.withLock { $0.append("\(path) \(cookie)") }
            return ("200 OK", ["Content-Type: text/html", "Set-Cookie: \(path == "/framed" ? "framed" : "direct")=1; Path=/"], Data("embedded".utf8))
        }
        let embedder = try await TinyHTTPServer { request in
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            return ("200 OK", ["Content-Type: text/html"], Data("<iframe src='http://localhost:\(embedded.port)\(path)'></iframe>".utf8))
        }
        let factory = WKEngineFactory()

        func embeddedCookie(trackingPrevention: Bool) async throws -> String? {
            factory.setTrackingPrevention(trackingPrevention)
            let tab = factory.createTab(configuration: .init(dataStore: factory.createDataStore(persistent: false, identifier: nil)))
            defer { tab.teardown() }
            for url in ["http://localhost:\(embedded.port)/", "http://127.0.0.1:\(embedder.port)/framed", "http://127.0.0.1:\(embedder.port)/echo"] {
                let before = seen.withLock { $0.count }
                tab.wkWebView.load(URLRequest(url: try XCTUnwrap(URL(string: url))))
                _ = await pollUntil(timeout: 10) { seen.withLock { $0.count } > before }
            }
            return seen.withLock { $0.last { $0.hasPrefix("/echo ") }.map { String($0.dropFirst("/echo ".count)) } }
        }

        let off = try await embeddedCookie(trackingPrevention: false)
        let on = try await embeddedCookie(trackingPrevention: true)
        XCTAssertEqual(off.map { Set($0.dropFirst("Cookie: ".count).components(separatedBy: "; ")) }, ["direct=1", "framed=1"])
        XCTAssertEqual(on, "")
    }

    /// A page announcing its next page with `<link rel=prefetch>` gets it fetched ahead, so a click opens it from the cache.
    func testTabsPrefetchTheNextPageASiteAnnounces() async throws {
        let prefetches = OSAllocatedUnfairLock<[String]>(initialState: [])
        let server = try await TinyHTTPServer { request in
            let lines = request.split(separator: "\r\n").map { $0.lowercased() }
            if lines.first?.hasPrefix("get /next ") == true, lines.contains(where: { $0.hasSuffix("purpose: prefetch") }) {
                prefetches.withLock { $0.append("/next") }
            }
            return ("200 OK", ["Content-Type: text/html", "Cache-Control: max-age=300"], Data("<link rel=prefetch href=/next><p>landing</p>".utf8))
        }
        let factory = WKEngineFactory()
        let tab = factory.createTab(configuration: .init(dataStore: factory.createDataStore(persistent: true, identifier: TestProfileIds.next().uuidString)))
        defer { tab.teardown() }

        tab.wkWebView.load(URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/"))))

        let prefetched = await pollUntil(timeout: 10) { !prefetches.withLock { $0 }.isEmpty }
        XCTAssertTrue(prefetched, "the announced next page was prefetched")
    }

    /// A page that asked Lilo something (here notification permission) and then navigates itself must
    /// not be held behind a beforeunload panel: the reply is not the user interacting with the page.
    func testANativeReplyLeavesThePageWithoutUserActivation() async throws {
        let factory = WKEngineFactory()
        let tab = factory.createTab(configuration: .init(dataStore: factory.defaultDataStore()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.wkWebView
        defer {
            window.close()
            tab.teardown()
        }
        // Read through the URL: the test's own evaluateJavaScript would count as a user gesture.
        tab.wkWebView.loadHTMLString("""
            <script>
            addEventListener('beforeunload', event => event.preventDefault());
            Notification.requestPermission().then(() => { location.href = 'about:blank#' + navigator.userActivation.hasBeenActive });
            </script>
            """, baseURL: URL(string: "https://example.com/"))

        let left = await pollUntil(timeout: 5) { tab.wkWebView.url?.absoluteString.hasPrefix("about:blank#") == true }
        XCTAssertTrue(left, "the page's own navigation went through, with no leave prompt holding it")
        XCTAssertEqual(tab.wkWebView.url?.absoluteString, "about:blank#false", "the reply gave the page no user activation")
    }

    func testTrackingPreventionIsOffOnEveryStoreByDefault() {
        let factory = WKEngineFactory()
        let stores = [
            factory.createDataStore(persistent: true, identifier: TestProfileIds.next().uuidString),
            factory.createDataStore(persistent: false, identifier: nil),
            factory.defaultDataStore(),
        ]
        for store in stores {
            XCTAssertEqual(store.backingStore.value(forKey: "resourceLoadStatisticsEnabled") as? Bool, false, store.identifier)
        }
    }

    func testTrackingPreventionSettingReachesExistingStores() async {
        let factory = WKEngineFactory()
        let stores = [
            factory.createDataStore(persistent: true, identifier: TestProfileIds.next().uuidString),
            factory.createDataStore(persistent: false, identifier: nil),
            factory.defaultDataStore(),
        ]
        let enabled = { stores.map { $0.backingStore.value(forKey: "resourceLoadStatisticsEnabled") as? Bool } }

        factory.setTrackingPrevention(true)
        XCTAssertEqual(enabled(), [true, true, true])
        XCTAssertEqual(factory.createDataStore(persistent: false, identifier: nil).backingStore.value(forKey: "resourceLoadStatisticsEnabled") as? Bool, true)

        // Off lands once WebKit has cleared its statistics. The network process answers a store's clears
        // in order, so one sent after the factory's comes back once the factory's completion has run.
        factory.setTrackingPrevention(false)
        let clear = NSSelectorFromString("_clearResourceLoadStatistics:")
        for store in stores.map(\.backingStore) where store.responds(to: clear) {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let cleared: @convention(block) () -> Void = { done.resume() }
                store.perform(clear, with: cleared)
            }
        }
        XCTAssertEqual(enabled(), [false, false, false])
    }
}
