import WebKit
import XCTest
@testable import Lilo

/// `make port-bench`: times a page's `runtime.connect` port to its extension's worker (first answer, round trips, a burst,
/// large messages) and writes the report to the path in LILO_PORT_BENCH. Skipped otherwise.
@MainActor
final class PortBenchmarkTests: XCTestCase {
    private let worker = """
    chrome.runtime.onConnect.addListener((port) => port.onMessage.addListener((message) => port.postMessage(message)));
    """

    private let page = """
    const now = () => performance.now();
    (async () => {
      const started = now();
      const port = chrome.runtime.connect({ name: 'bench' });
      let waiting;
      port.onMessage.addListener((message) => waiting?.(message));
      const next = () => new Promise((resolve) => { waiting = resolve; });
      port.postMessage(0);
      await next();
      const first = now() - started;
      window.__partial = { first };
      // The page's clock counts whole milliseconds: a round trip is timed as the mean of 300.
      const tripsStart = now();
      for (let i = 0; i < 300; i++) {
        port.postMessage(i);
        await next();
      }
      const trip = (now() - tripsStart) / 300;
      window.__partial.trip = trip;
      const burstStart = now();
      let left = 2000;
      const burstDone = new Promise((resolve) => { waiting = () => { if (--left === 0) resolve(); }; });
      for (let i = 0; i < 2000; i++) port.postMessage({ i, text: 'message' });
      await burstDone;
      const burst = now() - burstStart;
      window.__partial.burst = burst;
      const big = { text: 'x'.repeat(100 * 1024) };
      const bigStart = now();
      left = 100;
      const bigDone = new Promise((resolve) => { waiting = () => { if (--left === 0) resolve(); }; });
      for (let i = 0; i < 100; i++) port.postMessage(big);
      await bigDone;
      const large = now() - bigStart;
      window.__partial.large = large;
      // One call through Lilo's native channel, for scale: a port native relays crosses it twice.
      const callsStart = now();
      for (let i = 0; i < 300; i++) await chrome.idle.queryState(60);
      const call = (now() - callsStart) / 300;
      window.__bench = { first, trip, burst, large, call };
    })().catch((error) => { window.__bench = { error: String(error) }; });
    """

    func testReportTheCostOfAPortToTheWorker() async throws {
        guard let out = ProcessInfo.processInfo.environment["LILO_PORT_BENCH"] else {
            throw XCTSkip("Run by make port-bench")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("port-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Port bench", "version": "1.0", "background": ["service_worker": "bg.js"], "permissions": ["idle"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try worker.write(to: folder.appendingPathComponent("bg.js"), atomically: true, encoding: .utf8)
        try page.write(to: folder.appendingPathComponent("page.js"), atomically: true, encoding: .utf8)
        try #"<!doctype html><script src="page.js"></script>"#.write(to: folder.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)

        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let (window, registry) = try browserContext.makeExtensionWindow()
        var lines: [String] = []
        for run in 1...5 {
            try await registry.load(from: folder)
            let id = try XCTUnwrap(registry.loadedExtensions.last?.id)
            _ = await registry.backgrounds.load(id)
            _ = await pollUntil(timeout: 10) { registry.lifecycle.worker(of: id) == .running }
            let context = try XCTUnwrap(registry.context(for: id))
            let tab = try XCTUnwrap(window.createTabStateFirst(url: context.baseURL.appendingPathComponent("page.html")))
            let webView = try XCTUnwrap(window.tabManager.engineTab(for: tab.id)?.view as? WKWebView)
            var result: [String: Any]?
            _ = await pollUntil(timeout: 60) {
                result = try? await webView.evaluateJavaScript("JSON.stringify(window.__bench ?? null)").flatMap { $0 as? String }
                    .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                return result != nil
            }
            if result == nil {
                result = try? await webView.evaluateJavaScript("JSON.stringify(window.__partial ?? {})").flatMap { $0 as? String }
                    .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            }
            let ms = { (key: String) in String(format: "%.2f", (result?[key] as? Double) ?? .nan) }
            lines.append(result?["error"].map { "run \(run): error \($0)" }
                ?? "run \(run): first \(ms("first")) ms, round trip \(ms("trip")) ms, 2000 burst \(ms("burst")) ms, 100 x 100 KB \(ms("large")) ms, native call \(ms("call")) ms")
            window.closeTabStateFirst(id: tab.id, undoable: false)
            await registry.unload(extensionId: id)
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
    }
}
