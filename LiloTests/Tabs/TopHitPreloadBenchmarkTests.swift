import AppKit
import Network
import WebKit
import XCTest
@testable import Lilo

/// `make preload-bench`: Enter to first paint of a page whose server pauses before its body, the way a signed-in
/// video home page builds its feed, without a preload and with one started at a given lead (typing time
/// left before Enter). Written to the path in LILO_PRELOAD_BENCH; skipped otherwise.
@MainActor
final class TopHitPreloadBenchmarkTests: XCTestCase {
    private let runs = 7
    /// The measured page: 750 KB of head in 100 ms, a 1.3 s pause, then 1.6 MB of body.
    private let headBytes = 750_000, headMs = 100, pauseMs = 1300, bodyBytes = 1_600_000

    func testReportEnterToFirstPaintWithAndWithoutPreload() async throws {
        guard let out = ProcessInfo.processInfo.environment["LILO_PRELOAD_BENCH"] else { throw XCTSkip("Run by make preload-bench") }
        let server = try await PausingServer(head: head(), headMs: headMs, pauseMs: pauseMs, body: body())
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId, isPrivate: false)
        let window = makeTestWindow(context, showing: space.id, size: NSSize(width: 1200, height: 800))
        window.setupBridgeLate()
        let tabs = TabBridgeHandler(tabManager: window.tabManager, windowController: window, stateCommandHandler: window.applyBrowserCommand)
        let preload = try XCTUnwrap(window.bridgeRouter.handlers["preloadTopHit"])
        // Each run closes its tab: this one keeps the window from closing with it.
        _ = window.createTabStateFirst(url: nil)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: .borderless, backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = window.contentContainerView
        host.orderFrontRegardless()
        defer { host.close() }

        let url = "http://127.0.0.1:\(server.port)/"
        func send(_ action: String, _ payload: [String: Any], to handler: any BridgeHandler) async throws {
            _ = await handler.handle(message: try XCTUnwrap(BridgeMessage(dictionary: ["action": action, "payload": payload])))
        }
        /// Enter to the page's first frame with its main content, and to its largest contentful paint when WebKit reports one.
        func run(leadMs: Int?) async throws -> (paint: Double, lcp: Double?) {
            let tab = try XCTUnwrap(window.createTabStateFirst(url: nil))
            defer { window.closeTabStateFirst(id: tab.id, undoable: false) }
            if let leadMs {
                try await send("preloadTopHit", ["url": url], to: preload)
                try await Task.sleep(for: .milliseconds(leadMs))
            }
            let enter = Date().timeIntervalSince1970 * 1000
            try await send("navigate", ["url": url], to: tabs)
            if leadMs != nil { try await send("preloadTopHit", ["url": ""], to: preload) }
            let webView = try XCTUnwrap(window.tabManager.engineTab(for: tab.id)).wkWebView
            var marks: [String: Double]?
            let painted = await pollUntil(timeout: 20) {
                marks = (try? await webView.evaluateJavaScript("window.__marks")) as? [String: Double]
                return marks?["paint"] != nil
            }
            XCTAssertTrue(painted)
            // LCP settles after the paint that produced it.
            try await Task.sleep(for: .milliseconds(300))
            marks = (try? await webView.evaluateJavaScript("window.__marks")) as? [String: Double]
            return (try XCTUnwrap(marks?["paint"]) - enter, marks?["lcp"].map { $0 - enter })
        }

        // The leads: what typing leaves between the top hit turning confident (plus the 100 ms search debounce)
        // and Enter, at 180 ms a keystroke.
        let cases: [(String, Int?)] = [
            ("no preload", nil),
            ("lead 150 ms (fast \"yo\" + Enter)", 150),
            ("lead 440 ms (\"y\" then \"ou\" + Enter)", 440),
            ("lead 980 ms (\"yo\" then \"utube\" + Enter)", 980),
            ("lead 2000 ms (pause before Enter)", 2000)
        ]
        _ = try await run(leadMs: nil)
        var report = "Enter to first paint, median of \(runs) runs, ms. Page: \(headBytes / 1000) KB head in \(headMs) ms, "
        report += "\(pauseMs) ms server pause, \(bodyBytes / 1000) KB body\n"
        report += "".padding(toLength: 40, withPad: " ", startingAt: 0) + "   paint     lcp\n"
        for (name, lead) in cases {
            var paints: [Double] = [], lcps: [Double] = []
            for _ in 0..<runs {
                let result = try await run(leadMs: lead)
                paints.append(result.paint)
                if let lcp = result.lcp { lcps.append(lcp) }
            }
            let median = { (values: [Double]) in values.isEmpty ? "     n/a" : String(format: "%8.0f", values.sorted()[values.count / 2]) }
            report += name.padding(toLength: 40, withPad: " ", startingAt: 0) + median(paints) + median(lcps) + "\n"
        }
        try report.write(toFile: out, atomically: true, encoding: .utf8)
        withExtendedLifetime(server) {}
    }

    /// Inline scripts, as a feed page's head carries its config and data; the observer dates the largest paint.
    private func head() -> Data {
        let script = "<script>var config = '\(String(repeating: "x", count: 50_000))';</script>"
        return Data(("""
            <!doctype html><html><head><title>Videos</title>
            <script>
            window.__marks = {};
            try {
              new PerformanceObserver(list => { const last = list.getEntries().at(-1); window.__marks.lcp = performance.timeOrigin + last.startTime; })
                .observe({ type: 'largest-contentful-paint', buffered: true });
            } catch {}
            </script>
            """ + String(repeating: script, count: headBytes / script.utf8.count)).utf8)
    }

    /// The feed: a heading and a grid, then the frame after it is in the document dates its paint, then more data.
    private func body() -> Data {
        let card = "<div style=\"display:inline-block;width:280px;height:200px;margin:8px;background:#ddd\">A video title</div>"
        let filler = "<script>var data = '\(String(repeating: "y", count: 50_000))';</script>"
        var html = "</head><body><h1 style=\"font-size:64px\">Recommended for you</h1>" + String(repeating: card, count: 60)
        html += "<script>requestAnimationFrame(() => requestAnimationFrame(() => { window.__marks.paint = performance.timeOrigin + performance.now(); }));</script>"
        html += String(repeating: filler, count: (bodyBytes - html.utf8.count) / filler.utf8.count) + "</body></html>"
        return Data(html.utf8)
    }
}

/// Serves `/` as `head` spread over `headMs`, nothing for `pauseMs`, then `body`; anything else is a 404.
private final class PausingServer: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16

    init(head: Data, headMs: Int, pauseMs: Int, body: Data) async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { connection in
            let queue = DispatchQueue(label: "pausing-server")
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                guard String(decoding: data ?? Data(), as: UTF8.self).hasPrefix("GET / ") else {
                    let missing = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    return connection.send(content: Data(missing.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
                let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(headers.utf8), completion: .idempotent)
                let pieces = 10, size = (head.count + pieces - 1) / pieces
                for piece in 0..<pieces {
                    queue.asyncAfter(deadline: .now() + .milliseconds(headMs * piece / pieces)) {
                        connection.send(content: head.subdata(in: piece * size ..< min(head.count, (piece + 1) * size)), completion: .idempotent)
                    }
                }
                queue.asyncAfter(deadline: .now() + .milliseconds(headMs + pauseMs)) {
                    connection.send(content: body, completion: .contentProcessed { _ in connection.cancel() })
                }
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
