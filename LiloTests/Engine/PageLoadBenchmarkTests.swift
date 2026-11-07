import WebKit
import XCTest
@testable import Lilo

/// `make page-bench`: one round of real pages (the URLs in LILO_PAGE_BENCH_URLS) loaded in a plain WKWebView, in one with only the
/// network rule list compiled from the filter tables in LILO_PAGE_BENCH_TABLES, and in a Lilo tab with that rule list and everything
/// it injects. A table missing from the directory is left out. Appends a line per load to the file in LILO_PAGE_BENCH: round,
/// variant, host, first contentful paint, DOMContentLoaded and load in ms, then the resources the page and its frames fetched
/// and their transferred KB (both as Resource Timing sees them), and the web process's CPU ms, up to the load. Skipped otherwise.
@MainActor
final class PageLoadBenchmarkTests: XCTestCase {
    func testReportRealPageLoadsPlainWithRulesAndWithLilo() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["LILO_PAGE_BENCH"], let tables = env["LILO_PAGE_BENCH_TABLES"], let list = env["LILO_PAGE_BENCH_URLS"] else {
            throw XCTSkip("Run by make page-bench")
        }
        let urls = try list.split(separator: " ").map { try XCTUnwrap(URL(string: String($0))) }
        let round = Int(env["LILO_PAGE_BENCH_ROUND"] ?? "") ?? 0
        func table(_ name: String) -> String? {
            try? String(contentsOf: URL(fileURLWithPath: tables).appendingPathComponent("filter-\(name).json"), encoding: .utf8)
        }
        let scripts = WKEngineFactory.makeFilterScripts(cosmetic: table("generic-cosmetics"), sites: table("site-cosmetics"),
                                                        scriptlets: table("scriptlets"), procedural: table("procedural"))
        let rules = try XCTUnwrap(table("rules"), "no filter-rules.json in \(tables)")
        let rulesTag = WKEngineFactory.stableHash8(rules)
        let factory = WKEngineFactory()
        factory.setFilterTables(rulesTag: rulesTag, rules: rules, scripts: scripts)
        await factory.rebuildBlocker(allowlist: BlockerAllowlist())
        defer { withExtendedLifetime(factory) {} }
        // The lists the factory compiled (or found compiled by an earlier round), for the rules-only variant.
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        let identifiers = await withCheckedContinuation { continuation in
            store.getAvailableContentRuleListIdentifiers { continuation.resume(returning: $0 ?? []) }
        }
        var ruleLists: [WKContentRuleList] = []
        for identifier in identifiers.sorted() where identifier.contains(".ext-\(rulesTag).") {
            let ruleList = try await store.contentRuleList(forIdentifier: identifier)
            ruleLists.append(try XCTUnwrap(ruleList))
        }
        XCTAssertFalse(ruleLists.isEmpty, "the rule list did not compile")

        // Every frame reports what it fetched, from a world of its own the page cannot see.
        let counter = ResourceCounter()
        let world = WKContentWorld.world(name: "page-bench")
        let observer = WKUserScript(source: """
            new PerformanceObserver(list => {
              const entries = list.getEntries()
              webkit.messageHandlers.pageBench.postMessage([entries.length, entries.reduce((sum, e) => sum + e.transferSize, 0)])
            }).observe({ type: 'resource', buffered: true })
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.close() }
        // Each round puts another variant first, so none always pays for the cold DNS of a host.
        let variants = ["plain", "rules", "lilo"]
        let order = variants[(round % 3)...] + variants[..<(round % 3)]
        var lines = ""
        for url in urls {
            for variant in order {
                // A new web view and an empty data store per load: no page in memory, no cache and no cookie from the last one.
                let tab = variant == "lilo"
                    ? factory.createTab(configuration: .init(dataStore: factory.createDataStore(persistent: false, identifier: nil), refillsWarmPool: false))
                    : nil
                let webView: WKWebView
                if let tab {
                    webView = tab.wkWebView
                } else {
                    let configuration = WKWebViewConfiguration()
                    configuration.websiteDataStore = .nonPersistent()
                    // Lilo's user agent, without which sites serve a bare web view another page, and its pool, whose spare
                    // process every variant takes alike.
                    configuration.applicationNameForUserAgent = WKEngineFactory.safariApplicationName
                    if let pool = WKEngineFactory.contentProcessPool { configuration.setValue(pool, forKey: "processPool") }
                    if variant == "rules" { ruleLists.forEach(configuration.userContentController.add) }
                    webView = WKWebView(frame: .zero, configuration: configuration)
                }
                let controller = webView.configuration.userContentController
                controller.addUserScript(observer)
                controller.add(counter, contentWorld: world, name: "pageBench")
                window.contentView = webView
                let timings = try await load(url, in: webView)
                let fetched = counter.totals.removeValue(forKey: ObjectIdentifier(webView)) ?? (0, 0)
                controller.removeScriptMessageHandler(forName: "pageBench", contentWorld: world)
                tab?.teardown()
                lines += "\(round) \(variant) \(url.host() ?? "") \(timings.paint) \(fetched.requests) \(fetched.bytes / 1024) \(timings.cpu)\n"
            }
        }
        if !FileManager.default.fileExists(atPath: out) { FileManager.default.createFile(atPath: out, contents: nil) }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: out))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.utf8))
    }

    /// The paint and load timings, -1 each for a page that never loads, and the web process's CPU ms meanwhile: all the CPU of
    /// the process the page swapped to, if it did, which every variant takes from the same prewarmed pool.
    private func load(_ url: URL, in webView: WKWebView) async throws -> (paint: String, cpu: Int) {
        func cpu(_ pid: Int?) -> UInt64? { pid.flatMap { ProcessTaskInfoSampler.usage(pid: Int32($0)) }.map { ProcessTaskInfoSampler.cpuNanoseconds($0) } }
        webView.load(URLRequest(url: url))
        let pid = WebViewPrivateAccessors(webView).pid("_webProcessIdentifier"), start = cpu(pid)
        var timings: String?
        _ = await pollUntil(timeout: 30) {
            try? await Task.sleep(for: .milliseconds(250))
            timings = (try? await webView.evaluateJavaScript("""
                (() => { const n = performance.getEntriesByType('navigation')[0], p = performance.getEntriesByName('first-contentful-paint')[0];
                  return n && n.loadEventEnd > 0 && p ? [p.startTime, n.domContentLoadedEventEnd, n.loadEventEnd].map(Math.round).join(' ') : null })()
                """)) as? String
            return timings != nil
        }
        let endPid = WebViewPrivateAccessors(webView).pid("_webProcessIdentifier")
        guard let end = cpu(endPid) else { return (timings ?? "-1 -1 -1", -1) }
        return (timings ?? "-1 -1 -1", Int((end - (endPid == pid ? start ?? 0 : 0)) / 1_000_000))
    }
}

/// Sums what the frames of each web view report.
@MainActor
private final class ResourceCounter: NSObject, WKScriptMessageHandler {
    var totals: [ObjectIdentifier: (requests: Int, bytes: Int)] = [:]

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView, let counts = message.body as? [Int], counts.count == 2 else { return }
        let total = totals[ObjectIdentifier(webView)] ?? (0, 0)
        totals[ObjectIdentifier(webView)] = (total.requests + counts[0], total.bytes + counts[1])
    }
}
