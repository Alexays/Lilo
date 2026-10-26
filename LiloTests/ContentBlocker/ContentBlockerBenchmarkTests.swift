import WebKit
import XCTest
@testable import Lilo

/// `make blocker-bench`: converts the default lists as FilterListService does, compiles them, and writes what an image load
/// costs a page with and without them to the path in LILO_BLOCKER_BENCH. Skipped otherwise: it needs the network.
@MainActor
final class ContentBlockerBenchmarkTests: XCTestCase {
    func testReportTheCostOfALoadUnderTheDefaultLists() async throws {
        guard let out = ProcessInfo.processInfo.environment["LILO_BLOCKER_BENCH"] else {
            throw XCTSkip("Run by make blocker-bench")
        }
        var texts: [String] = []
        for url in FilterListService.sources(for: .init(languages: Locale.preferredLanguages)) {
            let list = String(decoding: try await URLSession.shared.data(from: url).0, as: UTF8.self)
            texts.append(url.absoluteString.hasPrefix(FilterListService.trustedListPrefix) ? "!#trusted on\n\(list)\n!#trusted off" : list)
        }
        var converted = FilterListConverter.convert(texts.joined(separator: "\n"))
        converted.blocks.insert(["trigger": ["url-filter": ".*", "resource-type": ["ping"]], "action": ["type": "block"]], at: 0)
        let generic = FilterListConverter.genericCosmetics(from: converted.cosmetic, exceptions: converted.cosmeticExceptions,
                                                          cap: FilterListService.maxCosmeticSelectors)
        let rules = FilterListConverter.combinedRules(blocks: converted.blocks, cssRules: generic.cssRules, exceptions: converted.exceptions,
                                                      important: converted.important, limit: FilterListService.maxRules)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)

        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-blocker-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: storeURL))
        let compileStart = Date()
        let compiled = try await store.compileContentRuleList(forIdentifier: "bench", encodedContentRuleList: json)
        let list = try XCTUnwrap(compiled)
        let compileTime = Date().timeIntervalSince(compileStart)

        let without = try await loadCost(ruleList: nil)
        let with = try await loadCost(ruleList: list)
        let report = """
            \(rules.count) rules, compiled in \(Int(compileTime * 1000)) ms
            ms per image load    long URL   short URL
            without the lists    \(without.long)      \(without.short)
            with the lists       \(with.long)      \(with.short)

            """
        try report.write(toFile: out, atomically: true, encoding: .utf8)
    }

    /// Milliseconds per image load from a page, for a long URL (a CDN image with its options and token) and a short one.
    private func loadCost(ruleList: WKContentRuleList?) async throws -> (long: String, short: String) {
        let configuration = WKWebViewConfiguration()
        ruleList.map(configuration.userContentController.add)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.loadHTMLString("<p>bench</p>", baseURL: URL(string: "https://example.com/"))
        let loaded = await pollUntil(timeout: 10) {
            ((try? await webView.evaluateJavaScript("document.readyState === 'complete'")) as? Bool) == true
        }
        XCTAssertTrue(loaded)
        let result = try await webView.callAsyncJavaScript("""
            const long = 'https://cdn.example.net/image/prod/content/app_screens/0a1b2c3d-4e5f-6789-abcd-ef0123456789.png'
                + '?f=webp&w=1920&q=85&fit=shrink-cover&extend-bottom=120&gravity=bottom&v=1.0&token=' + 'L3eFzB3lxatnbfY3HNl8'.repeat(12);
            function time(make, n) {
                const keep = [], start = performance.now();
                for (let i = 0; i < n; i++) { const image = new Image(); image.src = make(i); keep.push(image); }
                return ((performance.now() - start) / n).toFixed(3);
            }
            time(i => long + 'warm' + i, 50);
            return [time(i => long + i, 400), time(i => 'https://example.com/a' + i + '.png', 400)];
            """, contentWorld: .page) as? [String]
        let costs = try XCTUnwrap(result)
        return (costs[0], costs[1])
    }
}
