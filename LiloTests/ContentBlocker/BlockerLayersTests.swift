import os
import WebKit
import XCTest
@testable import Lilo

/// Every blocker layer on a real page: filter text through FilterListService into a tab, then paused for the site.
@MainActor
final class BlockerLayersTests: XCTestCase {
    /// The page's own !important rule, more specific than the site's, yields to it as to uBO's user-origin CSS.
    private static let page = """
    <style>#site.site-ad { display: block !important }</style><img src="/ad.png"><div id="native" data-native-ad></div><div id="excepted" data-excepted-ad></div>
    <div id="generic" class="generic-ad"></div><div id="site" class="site-ad"></div><div id="styled" class="styled"></div>
    <p id="procedural" class="post">Sponsored</p>
    """
    private static let filters = """
    /ad.png$image
    ##[data-native-ad]
    ##[data-excepted-ad]
    127.0.0.1#@#[data-excepted-ad]
    ##.generic-ad
    127.0.0.1##.site-ad
    127.0.0.1##.styled:style(opacity: 0.5 !important)
    127.0.0.1##.post:has-text(Sponsored)
    127.0.0.1##+js(set-constant, scriptletRan, true)
    """
    /// What the page shows of each layer, once the cosmetics are in.
    private static let probe = """
    (() => {
      const shown = (id) => getComputedStyle(document.getElementById(id)).display !== 'none';
      return [shown('native'), shown('excepted'), shown('generic'), shown('site'),
              getComputedStyle(document.getElementById('styled')).opacity, shown('procedural'), window.scriptletRan === true].join(',');
    })()
    """

    func testEveryLayerAppliesAndAPausedSiteGetsNone() async throws {
        let imageRequests = OSAllocatedUnfairLock(initialState: 0)
        let server = try await TinyHTTPServer { request in
            if request.hasPrefix("GET /ad.png ") { imageRequests.withLock { $0 += 1 } }
            return ("200 OK", ["Content-Type: text/html"], Data(request.hasPrefix("GET / ") ? Self.page.utf8 : "".utf8))
        }
        let factory = WKEngineFactory()
        let service = FilterListService(engineFactory: factory, allowlistProvider: { BlockerAllowlist() })
        let filters = Self.filters
        // One list holds the filters, and a trusted one: the rest come back empty.
        service.fetchList = { url in url.absoluteString.hasSuffix("/quick-fixes.txt") ? filters : "" }
        service.writeExtension = { _, _ in false }
        await service.refreshNow()
        // A later rebuild compiles from the cache once the service let go of the rules.
        _ = await pollUntil { (try? String(contentsOf: FilterListService.cacheURL, encoding: .utf8))?.contains(#"ad\\.png"#) == true }

        func load(expecting expected: String) async throws -> (state: String, imageRequested: Bool) {
            let before = imageRequests.withLock { $0 }
            let tab = factory.createTab(configuration: .init(dataStore: factory.createDataStore(persistent: false, identifier: nil)))
            defer { tab.teardown() }
            tab.wkWebView.load(URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/"))))
            _ = await pollUntil { tab.wkWebView.url != nil && !tab.wkWebView.isLoading }
            var state = ""
            // The generic and procedural passes land shortly after the load.
            _ = await pollUntil(timeout: 5) {
                state = (try? await tab.wkWebView.evaluateJavaScript(Self.probe) as? String) ?? ""
                return state == expected
            }
            return (state, imageRequests.withLock { $0 } > before)
        }

        // Shown: native, excepted, generic, site; the styled opacity; shown: procedural; whether the scriptlet ran.
        let applied = "false,true,false,false,0.5,false,true"
        let blocked = try await load(expecting: applied)
        XCTAssertEqual(blocked.state, applied)
        XCTAssertFalse(blocked.imageRequested)

        // A paused site is its whole host and port: a prefix of them does not pause it.
        let site = "127.0.0.1:\(server.port)"
        await factory.rebuildBlocker(allowlist: BlockerAllowlist(sites: [String(site.dropLast())]))
        let prefix = try await load(expecting: applied)
        XCTAssertEqual(prefix.state, applied)
        XCTAssertFalse(prefix.imageRequested)

        await factory.rebuildBlocker(allowlist: BlockerAllowlist(sites: [site]))
        let none = "true,true,true,true,1,true,false"
        let paused = try await load(expecting: none)
        XCTAssertEqual(paused.state, none)
        XCTAssertTrue(paused.imageRequested)
    }

    /// The built-in extension's declarativeNetRequest rules, written and loaded as the app does, apply in a private space and stand
    /// down for a paused site.
    func testTheBuiltInExtensionStandsDownForAPausedSite() async throws {
        let requests = OSAllocatedUnfairLock(initialState: [String]())
        let server = try await TinyHTTPServer { request in
            let path = String(request.split(separator: " ").dropFirst().first ?? "")
            requests.withLock { $0.append(path) }
            let page = #"<img src="/track.png?utm_source=x&id=1"><script src="/ad.js"></script>"#
            return ("200 OK", ["Content-Type: text/html"], Data(path == "/" ? page.utf8 : "".utf8))
        }
        var allowlist = BlockerAllowlist()
        let service = FilterListService(engineFactory: WKEngineFactory(), allowlistProvider: { allowlist })
        service.fetchList = { url in
            url.absoluteString.hasSuffix("/quick-fixes.txt") ? "||127.0.0.1^*/track.png$image,removeparam=utm_source\n/ad.js$script,redirect=noop.js" : ""
        }
        await service.refreshNow()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = try makeTestExtensionRegistry(in: directory)
        defer { registry.teardown() }

        // What the server saw of the page's subresources once both requests settled the expected way.
        func load(expecting expected: [String]) async throws -> [String] {
            await registry.loadBlockerExtension(at: FilterListService.blockerExtensionURL)
            var seen: [String] = []
            // The rules compile after the extension loads: a load before that is not blocked yet.
            _ = await pollUntil(timeout: 20) {
                requests.withLock { $0 = [] }
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.webExtensionController = registry.controller
                let webView = WKWebView(frame: .zero, configuration: configuration)
                webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/")!))
                _ = await pollUntil(timeout: 5) { !webView.isLoading && requests.withLock { $0.count } > 1 }
                try? await Task.sleep(for: .milliseconds(200))
                seen = requests.withLock { $0.filter { $0 != "/" }.sorted() }
                return seen == expected
            }
            return seen
        }

        let filtered = try await load(expecting: ["/track.png?id=1"])
        XCTAssertEqual(filtered, ["/track.png?id=1"], "the parameter goes, the script is replaced")
        allowlist = BlockerAllowlist(sites: ["127.0.0.1"])
        await service.installBlockerExtension()
        let untouched = ["/ad.js", "/track.png?utm_source=x&id=1"]
        let paused = try await load(expecting: untouched)
        XCTAssertEqual(paused, untouched, "a paused site gets neither rule")
    }
}
