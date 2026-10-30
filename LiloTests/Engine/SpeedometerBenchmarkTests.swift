import WebKit
import XCTest
@testable import Lilo

/// `make speedometer-bench`: one round of Speedometer in a plain WKWebView, one with Lilo's page bridges and one with everything
/// Lilo injects, from the filter tables in LILO_SPEEDOMETER_BENCH_TABLES. Appends the three scores to the file in
/// LILO_SPEEDOMETER_BENCH; LILO_SPEEDOMETER_ROUND rotates their order. Skipped otherwise.
@MainActor
final class SpeedometerBenchmarkTests: XCTestCase {
    func testReportSpeedometerWithAndWithoutLilosScripts() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["LILO_SPEEDOMETER_BENCH"], let tables = env["LILO_SPEEDOMETER_BENCH_TABLES"] else {
            throw XCTSkip("Run by make speedometer-bench")
        }
        func table(_ name: String) throws -> String {
            try String(contentsOf: URL(fileURLWithPath: tables).appendingPathComponent("filter-\(name).json"), encoding: .utf8)
        }
        let scripts = WKEngineFactory.makeFilterScripts(cosmetic: try table("generic-cosmetics"), sites: try table("site-cosmetics"),
                                                        scriptlets: try table("scriptlets"), procedural: try table("procedural"))
        let plain = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let bridgesFactory = WKEngineFactory(), bridgesTab = bridgesFactory.createTab(configuration: .init())
        let factory = WKEngineFactory(), liloTab = factory.createTab(configuration: .init())
        factory.setFilterTables(rulesTag: nil, rules: nil, scripts: scripts)
        defer { withExtendedLifetime((bridgesFactory, bridgesTab, factory, liloTab)) {} }

        // Each takes its turn first, then the drift of a long run weighs on all three alike.
        let shift = Int(env["LILO_SPEEDOMETER_ROUND"] ?? "") ?? 0
        let order = (0..<3).map { ($0 + shift) % 3 }
        let webViews = [plain, bridgesTab.wkWebView, liloTab.wkWebView]
        var scores = [Double](repeating: 0, count: 3)
        for index in order {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = webViews[index]
            window.orderFrontRegardless()
            defer { window.close() }
            scores[index] = try await score(in: webViews[index])
        }
        let line = scores.map { String(format: "%.1f", $0) }.joined(separator: " ") + "\n"
        if !FileManager.default.fileExists(atPath: out) { FileManager.default.createFile(atPath: out, contents: nil) }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: out))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }

    /// Five iterations instead of ten keep a round of three inside the test runner's time allowance.
    private func score(in webView: WKWebView) async throws -> Double {
        webView.load(URLRequest(url: try XCTUnwrap(URL(string: "https://browserbench.org/Speedometer3.1/?startAutomatically=true&iterationCount=5"))))
        var score: Double?
        let finished = await pollUntil(timeout: 170) {
            // A script in the page every 20 ms would weigh on the score it reads.
            try? await Task.sleep(for: .seconds(5))
            let text = (try? await webView.evaluateJavaScript("(document.querySelector('#result-number') || {}).textContent || ''")) as? String
            score = text.flatMap(Double.init)
            return score != nil
        }
        XCTAssertTrue(finished)
        return try XCTUnwrap(score)
    }
}
