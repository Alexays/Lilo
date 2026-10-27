import WebKit
import XCTest
@testable import Lilo

/// `make script-bench`: what the scripts Lilo injects cost a page, from the filter tables the app last built (the directory in
/// LILO_SCRIPT_BENCH_TABLES), written to the path in LILO_SCRIPT_BENCH. Skipped otherwise.
@MainActor
final class InjectedScriptsBenchmarkTests: XCTestCase {
    private let runs = 12

    func testReportWhatTheInjectedScriptsCostAPage() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["LILO_SCRIPT_BENCH"], let tables = env["LILO_SCRIPT_BENCH_TABLES"] else {
            throw XCTSkip("Run by make script-bench")
        }
        func table(_ name: String) throws -> String {
            try String(contentsOf: URL(fileURLWithPath: tables).appendingPathComponent("filter-\(name).json"), encoding: .utf8)
        }
        let cosmetic = try table("generic-cosmetics"), sites = try table("site-cosmetics"), procedural = try table("procedural")
        let scripts = WKEngineFactory.makeFilterScripts(cosmetic: cosmetic, sites: sites, scriptlets: try table("scriptlets"),
                                                        procedural: procedural)
        // A host with `:has-text()` rules, so the feed also pays for procedural cosmetics, and generic ones on (no `@@`).
        let proceduralHosts = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(procedural.utf8)) as? [String: Any])
        let siteHosts = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sites.utf8)) as? [String: [String]])
        let host = try XCTUnwrap(proceduralHosts.keys.sorted().first {
            !$0.hasSuffix(".*") && String(describing: proceduralHosts[$0]!).contains(":has-text(") && siteHosts[$0]?.contains("@@") != true
        })
        let classes = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(cosmetic.utf8)) as? [String: Any])?["classes"] as? String)
        let adClasses = Array(classes.split(separator: " ").prefix(64).map(String.init))

        let plain = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        // Tabs and factories stay alive for the whole run: the web views go with them.
        let bridgesFactory = WKEngineFactory(), bridgesTab = bridgesFactory.createTab(configuration: .init())
        let factory = WKEngineFactory(), liloTab = factory.createTab(configuration: .init())
        factory.setFilterTables(rulesTag: nil, rules: nil, scripts: scripts)
        let bridges = bridgesTab.wkWebView, lilo = liloTab.wkWebView
        defer { withExtendedLifetime((bridgesFactory, bridgesTab, factory, liloTab)) {} }

        let base = try XCTUnwrap(URL(string: "https://\(host)/"))
        let paragraphs = String(repeating: "<p>Some article text that the page shows, long enough to read.</p>", count: 3000)
        let pages = [
            ("page load, no frame", "<p>bench</p>"),
            ("page load, 30 frames", String(repeating: #"<iframe srcdoc="<p>ad</p>"></iframe>"#, count: 30)),
            ("page load, 3000 nodes", paragraphs)
        ]
        var rows: [(String, [Double])] = pages.map { ($0.0, []) } + [("feed, busy ms", []), ("feed, ad posts hidden", [])]
        for webView in [plain, bridges, lilo] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = webView
            window.orderFrontRegardless()
            defer { window.close() }
            for (row, page) in pages.enumerated() {
                rows[row].1.append(try await trimmedMean { try await self.loadTime(of: page.1, at: base, in: webView) })
            }
            rows[pages.count].1.append(try await trimmedMean {
                _ = try await self.loadTime(of: paragraphs, at: base, in: webView)
                return try await self.feedBusyTime(in: webView, classes: adClasses)
            })
            let hidden = try await webView.evaluateJavaScript(
                "[...document.querySelectorAll('section > div')].filter(post => getComputedStyle(post).display === 'none').length"
            )
            rows[pages.count + 1].1.append(try XCTUnwrap(hidden as? Double))
        }

        let sizes = [scripts.scriptlets, scripts.genericCosmetics, scripts.procedural].map { "\(($0?.utf16.count ?? 0) / 1000)K" }
        var report = "Injected scripts on \(host), trimmed mean of \(runs) runs, ms\n"
        report += "scriptlets \(sizes[0]), generic cosmetics \(sizes[1]), procedural \(sizes[2]) chars\n"
        report += "".padding(toLength: 26, withPad: " ", startingAt: 0) + "   plain bridges    lilo\n"
        for (name, values) in rows {
            report += name.padding(toLength: 26, withPad: " ", startingAt: 0)
                + values.map { String(format: "%8.1f", $0) }.joined() + "\n"
        }
        try report.write(toFile: out, atomically: true, encoding: .utf8)
    }

    /// The mean without the extremes: WebKit rounds `performance.now()` to the millisecond, so a median would too.
    private func trimmedMean(_ measure: () async throws -> Double) async throws -> Double {
        _ = try await measure()
        var values: [Double] = []
        for _ in 0..<runs { values.append(try await measure()) }
        return values.sorted().dropFirst().dropLast().reduce(0, +) / Double(runs - 2)
    }

    /// Navigation start to the load event, which waits for every frame.
    private func loadTime(of body: String, at base: URL, in webView: WKWebView) async throws -> Double {
        // The run's own key: until the new document commits, the old one still answers.
        let run = UUID().uuidString
        webView.loadHTMLString("""
            <!doctype html><html><head><script>addEventListener('load', () => { window['\(run)'] = performance.now() })</script></head>
            <body>\(body)</body></html>
            """, baseURL: base)
        var time: Double?
        let loaded = await pollUntil(timeout: 20) {
            time = (try? await webView.evaluateJavaScript("window['\(run)']")) as? Double
            return time != nil
        }
        XCTAssertTrue(loaded)
        return try XCTUnwrap(time)
    }

    /// An infinite feed: 100 batches of 40 posts, some with ad classes, 16 ms apart. The time the page's timers come back late
    /// is the time the page's thread spent on everything else: observers, cosmetic flushes, procedural passes, style and layout.
    private func feedBusyTime(in webView: WKWebView, classes: [String]) async throws -> Double {
        let result = try await webView.callAsyncJavaScript("""
            const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
            let busy = 0;
            for (let batch = 0; batch < 100; batch++) {
              const start = performance.now();
              const section = document.createElement('section');
              for (let i = 0; i < 40; i++) {
                const post = document.createElement('div');
                post.className = i % 4 ? 'post' : classes[(batch * 10 + i) % classes.length];
                post.innerHTML = '<div><div><span>Post ' + batch + '-' + i + ', Sponsored</span></div></div>';
                section.append(post);
              }
              document.body.append(section);
              await pause(16);
              busy += performance.now() - start - 16;
            }
            return busy;
            """, arguments: ["classes": classes], contentWorld: .page)
        return try XCTUnwrap(result as? Double)
    }
}
