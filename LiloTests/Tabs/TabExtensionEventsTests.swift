import WebKit
import XCTest
@testable import Lilo

/// The tab events a worker hears from WebKit for what the user does to tabs: as many as Chrome sends, not one per bookkeeping step.
@MainActor
final class TabExtensionEventsTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var window: MainWindowController!
    private var registry: ProfileExtensionRegistry!
    private var context: WKWebExtensionContext!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        (window, registry) = try browserContext.makeExtensionWindow()

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tab-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Tab events", "version": "1.0", "action": [String: Any](),
            "host_permissions": ["<all_urls>"], "background": ["service_worker": "background.js"]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try """
        const moves = [];
        let urls = 0, pins = 0, loaded = false;
        const report = () => chrome.action.setTitle({ title: JSON.stringify({ moves, urls, pins, loaded }) });
        chrome.tabs.onMoved.addListener((id, info) => { moves.push([info.fromIndex, info.toIndex]); report(); });
        chrome.tabs.onUpdated.addListener((id, info, tab) => {
          if (info.url?.endsWith('/target')) urls += 1;
          if (info.pinned !== undefined) pins += 1;
          if (info.status === 'complete' && tab.url?.endsWith('/target')) loaded = true;
          report();
        });
        report();
        """.write(to: folder.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        try await registry.load(from: folder)
        let id = try XCTUnwrap(registry.loadedExtensions.first?.id)
        _ = await registry.backgrounds.load(id)
        context = try XCTUnwrap(registry.context(for: id))
        let ready = await pollUntil(timeout: 10) { self.heard != nil }
        XCTAssertTrue(ready, "the worker reports")
    }

    override func tearDown() async throws {
        window.close()
        window = nil
        registry = nil
        context = nil
        browserContext.tearDown()
        browserContext = nil
        try await super.tearDown()
    }

    private struct Heard: Decodable, Equatable {
        var moves: [[Int]]
        var urls: Int
        var pins: Int
        var loaded: Bool
    }

    private var heard: Heard? {
        context.action(for: nil)?.label.data(using: .utf8).flatMap { try? JSONDecoder().decode(Heard.self, from: $0) }
    }

    /// Lets events WebKit would still send arrive before the counts are read.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    func testMovingOneTabFiresOneOnMoved() async throws {
        let spaceId = try XCTUnwrap(window.tabManager.currentSpaceId)
        for _ in 0..<4 { _ = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "about:blank"))) }
        let order = window.tabManager.tabs(forSpace: spaceId).map(\.id)
        XCTAssertGreaterThanOrEqual(order.count, 4)
        let last = try XCTUnwrap(order.last)

        _ = try window.applyBrowserCommand(.moveSidebarItem(
            spaceId: spaceId, kind: .tab, itemId: last, parentFolderId: nil, section: .unpinned, insert: .index(0)
        ))

        let moved = await pollUntil(timeout: 5) { self.heard?.moves.isEmpty == false }
        XCTAssertTrue(moved, "the move is reported")
        try await settle()
        XCTAssertEqual(heard?.moves, [[order.count - 1, 0]], "only the dragged tab moved, not the tabs it shifted")
    }
}
