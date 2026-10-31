import WebKit
import XCTest
@testable import Lilo

/// `make page-bench`: real pages (the URLs in LILO_PAGE_BENCH_URLS) loaded in a plain WKWebView and in a tab with everything Lilo
/// injects, from the filter tables in LILO_PAGE_BENCH_TABLES. Appends a line per load to the file in LILO_PAGE_BENCH:
/// round, variant, host, first contentful paint, DOMContentLoaded and load in ms. Skipped otherwise.
@MainActor
final class PageLoadBenchmarkTests: XCTestCase {
    func testReportRealPageLoadsWithAndWithoutLilosScripts() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["LILO_PAGE_BENCH"], let tables = env["LILO_PAGE_BENCH_TABLES"], let list = env["LILO_PAGE_BENCH_URLS"] else {
            throw XCTSkip("Run by make page-bench")
        }
        let urls = try list.split(separator: " ").map { try XCTUnwrap(URL(string: String($0))) }
        let rounds = Int(env["LILO_PAGE_BENCH_ROUNDS"] ?? "") ?? 6
        func table(_ name: String) throws -> String {
            try String(contentsOf: URL(fileURLWithPath: tables).appendingPathComponent("filter-\(name).json"), encoding: .utf8)
        }
        let scripts = WKEngineFactory.makeFilterScripts(cosmetic: try table("generic-cosmetics"), sites: try table("site-cosmetics"),
                                                        scriptlets: try table("scriptlets"), procedural: try table("procedural"))
        let factory = WKEngineFactory()
        factory.setFilterTables(rulesTag: nil, rules: nil, scripts: scripts)
        defer { withExtendedLifetime(factory) {} }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.close() }
        var lines = ""
        // Round 0 fills the cache and is left out; each variant takes its turn first.
        for round in 0...rounds {
            for url in urls {
                for lilo in round % 2 == 0 ? [false, true] : [true, false] {
                    // A new web view per load, as a new tab: no page left in memory from the previous one.
                    let tab = lilo ? factory.createTab(configuration: .init(refillsWarmPool: false)) : nil
                    let webView = tab?.wkWebView ?? WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
                    window.contentView = webView
                    let timings = try await load(url, in: webView)
                    tab?.teardown()
                    if round > 0 { lines += "\(round) \(lilo ? "lilo" : "plain") \(url.host() ?? "") \(timings)\n" }
                }
            }
        }
        if !FileManager.default.fileExists(atPath: out) { FileManager.default.createFile(atPath: out, contents: nil) }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: out))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.utf8))
    }

    private func load(_ url: URL, in webView: WKWebView) async throws -> String {
        webView.load(URLRequest(url: url))
        var timings: String?
        let loaded = await pollUntil(timeout: 30) {
            try? await Task.sleep(for: .milliseconds(250))
            timings = (try? await webView.evaluateJavaScript("""
                (() => { const n = performance.getEntriesByType('navigation')[0], p = performance.getEntriesByName('first-contentful-paint')[0];
                  return n && n.loadEventEnd > 0 && p ? [p.startTime, n.domContentLoadedEventEnd, n.loadEventEnd].map(Math.round).join(' ') : null })()
                """)) as? String
            return timings != nil
        }
        XCTAssertTrue(loaded, "\(url) did not load")
        return timings ?? "-1 -1 -1"
    }
}
