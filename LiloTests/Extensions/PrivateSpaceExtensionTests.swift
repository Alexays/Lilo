import WebKit
import XCTest
@testable import Lilo

/// Extensions stay out of private spaces unless the user allows one there, as Chrome's incognito.
@MainActor
final class PrivateSpaceExtensionTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var server: TinyHTTPServer!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        server = try await TinyHTTPServer(index: "<title>Page</title><p>page</p>")
    }

    override func tearDown() {
        browserContext.tearDown()
        browserContext = nil
        server = nil
        super.tearDown()
    }

    /// An extension whose content script marks the page and whose worker titles its action with
    /// what it sees: the tabs it can query and the tabs it heard open.
    private func loadWatchingExtension(in registry: ProfileExtensionRegistry) async throws -> WKWebExtensionContext {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("private-space-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Watcher", "version": "1.0", "action": [String: Any](),
            "host_permissions": ["<all_urls>"], "background": ["service_worker": "background.js"],
            "content_scripts": [["matches": ["http://127.0.0.1/*"], "js": ["content.js"]]]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try """
        document.documentElement.dataset.injected = String(chrome.extension.inIncognitoContext);
        """.write(to: folder.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)
        try """
        let opened = 0;
        const report = async () => {
          const query = chrome.tabs.query.__liloUnwrapped ?? chrome.tabs.query;
          const tabs = await query.call(chrome.tabs, {});
          chrome.action.setTitle({ title: `tabs:${tabs.length} opened:${opened}` });
        };
        chrome.tabs.onCreated.addListener(() => { opened += 1; report(); });
        chrome.tabs.onUpdated.addListener(report);
        report();
        """.write(to: folder.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        try await registry.load(from: folder)
        let id = try XCTUnwrap(registry.loadedExtensions.first?.id)
        _ = await registry.backgrounds.load(id)
        return try XCTUnwrap(registry.context(for: id))
    }

    private func openPrivatePage(in window: MainWindowController) async throws -> WKWebViewTab {
        window.newPrivateSpace(nil)
        let tab = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "http://127.0.0.1:\(server.port)/")))
        let engine = try XCTUnwrap(window.tabManager.engineTab(for: tab.id))
        let loaded = await pollUntil { engine.currentTitle == "Page" }
        XCTAssertTrue(loaded, "the private page loads")
        return engine
    }

    private func injected(_ engine: WKWebViewTab) async -> String? {
        try? await engine.wkWebView.evaluateJavaScript("document.documentElement.dataset.injected ?? 'none'") as? String
    }

    func testAnExtensionNotAllowedInPrivateSpacesNeverSeesThem() async throws {
        let (window, registry) = try browserContext.makeExtensionWindow()
        let context = try await loadWatchingExtension(in: registry)
        await pollUntil(timeout: 10) { context.action(for: nil)?.label.hasPrefix("tabs:") == true }
        let before = context.action(for: nil)?.label

        let engine = try await openPrivatePage(in: window)
        try await Task.sleep(for: .milliseconds(500))

        let mark = await injected(engine)
        XCTAssertEqual(mark, "none", "no content script in a private page")
        XCTAssertEqual(context.action(for: nil)?.label, before, "no private tab to query and no event about one")
    }

    func testAnExtensionAllowedInPrivateSpacesRunsThereAndKnowsIt() async throws {
        let (window, registry) = try browserContext.makeExtensionWindow()
        let context = try await loadWatchingExtension(in: registry)
        await registry.access.setPrivateAccess(extensionId: try XCTUnwrap(registry.loadedExtensions.first?.id), allowed: true)
        await pollUntil(timeout: 10) { context.action(for: nil)?.label.hasPrefix("tabs:") == true }

        let engine = try await openPrivatePage(in: window)

        let ran = await pollUntil(timeout: 5) { await self.injected(engine) == "true" }
        let mark = await injected(engine)
        XCTAssertTrue(ran, "the content script runs in the private page and knows it is incognito: \(mark ?? "nil")")
        // The blank tab Cmd+Shift+N opens, then the page.
        let heard = await pollUntil(timeout: 5) { context.action(for: nil)?.label == "tabs:2 opened:2" }
        XCTAssertTrue(heard, "the private tab is announced: \(context.action(for: nil)?.label ?? "nil")")
    }
}
