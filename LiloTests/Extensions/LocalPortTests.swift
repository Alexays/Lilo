import WebKit
import XCTest
@testable import Lilo

/// Ports between an extension's pages and worker, which Lilo relays as Chrome connects them (WEBKIT-GAPS 60), in the real
/// registry, worker and tabs.
@MainActor
final class LocalPortTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var window: MainWindowController!
    private var registry: ProfileExtensionRegistry!
    private var folder: URL!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        (window, registry) = try browserContext.makeExtensionWindow()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("local-port-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        browserContext.tearDown()
        try? FileManager.default.removeItem(at: folder)
        try await super.tearDown()
    }

    /// Loads an extension whose worker runs `worker` (its `log` array shows on its action's title) and whose pages
    /// `page.html` and `other.html` run `page` and `other`, and returns its id.
    private func load(worker: String, page: String, other: String = "", startWorker: Bool = true) async throws -> String {
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Ports", "version": "1.0", "background": ["service_worker": "bg.js"], "action": [:]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try ("const log = [];\nsetInterval(() => chrome.action.setTitle({ title: JSON.stringify(log) }), 100);\n" + worker)
            .write(to: folder.appendingPathComponent("bg.js"), atomically: true, encoding: .utf8)
        for (name, script) in [("page", page), ("other", other)] {
            try ("window.log = [];\n" + script).write(to: folder.appendingPathComponent("\(name).js"), atomically: true, encoding: .utf8)
            try #"<!doctype html><script src="\#(name).js"></script>"#.write(to: folder.appendingPathComponent("\(name).html"), atomically: true, encoding: .utf8)
        }
        try await registry.load(from: folder)
        let id = try XCTUnwrap(registry.loadedExtensions.last?.id)
        if startWorker {
            _ = await registry.backgrounds.load(id)
            _ = await pollUntil(timeout: 10) { self.registry.gapEvents.reportedListeners(of: id) != nil }
        }
        return id
    }

    private func open(_ page: String, of id: String) throws -> (tab: UUID, webView: WKWebView) {
        let context = try XCTUnwrap(registry.context(for: id))
        let tab = try XCTUnwrap(window.createTabStateFirst(url: context.baseURL.appendingPathComponent(page)))
        return (tab.id, try XCTUnwrap(window.tabManager.engineTab(for: tab.id)?.view as? WKWebView))
    }

    private func log(of webView: WKWebView) async -> [String] {
        let json = try? await webView.evaluateJavaScript("JSON.stringify(window.log ?? [])") as? String
        return json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] } ?? []
    }

    private func workerLog(_ id: String) -> [String] {
        let title = registry.context(for: id)?.action(for: nil)?.label ?? "[]"
        return (try? JSONSerialization.jsonObject(with: Data(title.utf8)) as? [String]) ?? []
    }

    private let echo = """
    chrome.runtime.onConnect.addListener((port) => {
      log.push('connect ' + port.name + ' from ' + port.sender.url.split('/').pop());
      port.onMessage.addListener((message) => port.postMessage(message));
      port.onDisconnect.addListener(() => log.push('disconnect ' + port.name));
    });
    """

    func testAPagesMessagesReachTheWorkerAndComeBackInOrder() async throws {
        let id = try await load(worker: echo, page: """
        const port = chrome.runtime.connect({ name: 'order' });
        const heard = [];
        port.onMessage.addListener((message) => { heard.push(message); if (heard.length === 1005) log.push(JSON.stringify(heard)); });
        for (let i = 0; i < 1000; i++) port.postMessage(i);
        (async () => { for (let i = 1000; i < 1005; i++) { await new Promise((resolve) => setTimeout(resolve, 5)); port.postMessage(i); } })();
        """)
        let (_, page) = try open("page.html", of: id)

        var heard: [String] = []
        _ = await pollUntil(timeout: 20) { heard = await self.log(of: page); return !heard.isEmpty }
        XCTAssertEqual(heard.first, "[" + (0..<1005).map(String.init).joined(separator: ",") + "]")
        _ = await pollUntil(timeout: 5) { !self.workerLog(id).isEmpty }
        XCTAssertEqual(workerLog(id).first, "connect order from page.html", "the worker sees the page as its sender")
    }

    func testAPortNobodyTakesDisconnectsWithChromesError() async throws {
        let id = try await load(worker: "log.push('no listener');", page: """
        const port = chrome.runtime.connect({ name: 'alone' });
        port.postMessage('lost');
        port.onDisconnect.addListener(() => log.push(chrome.runtime.lastError?.message ?? 'no error'));
        """)
        let (_, page) = try open("page.html", of: id)

        var heard: [String] = []
        _ = await pollUntil(timeout: 10) { heard = await self.log(of: page); return !heard.isEmpty }
        XCTAssertEqual(heard, ["Could not establish connection. Receiving end does not exist."])
    }

    func testAPortReachesTheWorkerAndEveryOtherPageAndTheirAnswersComeBack() async throws {
        let id = try await load(
            worker: """
            chrome.runtime.onConnect.addListener((port) => port.onMessage.addListener((message) => { log.push('worker ' + message); port.postMessage('from worker'); }));
            """,
            page: """
            chrome.runtime.onConnect.addListener(() => log.push('the opener hears its own port'));
            window.start = () => {
              const port = chrome.runtime.connect({ name: 'all' });
              port.onMessage.addListener((message) => log.push(message));
              port.postMessage('hi');
            };
            """,
            other: """
            chrome.runtime.onConnect.addListener((port) => port.onMessage.addListener((message) => { log.push('other ' + message); port.postMessage('from other'); }));
            """
        )
        let (_, other) = try open("other.html", of: id)
        _ = await pollUntil(timeout: 10) { (try? await other.evaluateJavaScript("typeof chrome.runtime.onConnect")) as? String == "object" }
        // The other page's listener reaches Lilo with its first call.
        try await Task.sleep(for: .milliseconds(300))
        let (_, page) = try open("page.html", of: id)
        _ = await pollUntil(timeout: 10) { (try? await page.evaluateJavaScript("typeof window.start")) as? String == "function" }
        _ = try await page.evaluateJavaScript("window.start()")

        var heard: [String] = []
        _ = await pollUntil(timeout: 10) { heard = await self.log(of: page); return heard.count >= 2 }
        XCTAssertEqual(Set(heard), ["from worker", "from other"])
        let otherHeard = await log(of: other)
        XCTAssertEqual(otherHeard, ["other hi"])
        _ = await pollUntil(timeout: 5) { !self.workerLog(id).isEmpty }
        XCTAssertEqual(workerLog(id), ["worker hi"])
    }

    func testAPortGoesWithItsPageAndWithItsWorker() async throws {
        let id = try await load(worker: echo, page: """
        const port = chrome.runtime.connect({ name: 'closing' });
        port.postMessage('open');
        """, other: """
        const port = chrome.runtime.connect({ name: 'stopping' });
        port.onMessage.addListener((message) => log.push(message));
        port.onDisconnect.addListener(() => log.push('disconnected ' + (chrome.runtime.lastError?.message ?? '')));
        port.postMessage('open');
        """)
        let (pageTab, _) = try open("page.html", of: id)
        let (_, other) = try open("other.html", of: id)
        _ = await pollUntil(timeout: 10) { await self.log(of: other) == ["open"] }
        window.closeTabStateFirst(id: pageTab, undoable: false)
        _ = await pollUntil(timeout: 10) { self.workerLog(id).contains("disconnect closing") }
        XCTAssertTrue(workerLog(id).contains("disconnect closing"), "a closed page's port disconnects for the worker")

        NotificationCenter.default.post(name: .extensionWorkerDidStop, object: registry.gapEvents, userInfo: [
            "extensionId": id, "instance": registry.gapEvents.workerInstance(of: id) as Any
        ])
        _ = await pollUntil(timeout: 10) { await self.log(of: other).count == 2 }
        let otherHeard = await log(of: other)
        XCTAssertEqual(otherHeard, ["open", "disconnected "], "a stopped worker's port disconnects without an error, as in Chrome")
    }

    func testAPortStartsTheWorker() async throws {
        let id = try await load(worker: echo, page: """
        const port = chrome.runtime.connect({ name: 'wake' });
        port.onMessage.addListener((message) => log.push(message));
        port.postMessage('woken');
        """, startWorker: false)
        let (_, page) = try open("page.html", of: id)

        _ = await pollUntil(timeout: 15) { await self.log(of: page) == ["woken"] }
        let heard = await log(of: page)
        XCTAssertEqual(heard, ["woken"])
    }
}
