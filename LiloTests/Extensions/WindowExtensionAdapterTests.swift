import AppKit
import WebKit
import XCTest
@testable import Lilo

@MainActor
final class WindowExtensionAdapterTests: XCTestCase {

    func testVisibleActiveAdapterHidesAdapterNoLongerOwnedByTabManager() {
        let tabManager = TabManager(engineFactory: WKEngineFactory())
        tabManager.currentSpaceId = UUID()
        let window = WindowExtensionAdapter(nsWindow: NSWindow())
        window.scopesToCurrentSpace = true
        window.tabManager = tabManager
        let engine = WKWebViewTab(id: UUID(), webView: WKWebView())
        let adapter = TabExtensionAdapter(engineTab: engine, extensionWindow: window)
        window.add(tab: adapter)
        window.activeAdapter = adapter

        // The tab manager does not own this adapter (engine discarded, space deleted): hidden.
        XCTAssertNil(window.visibleActiveAdapter)

        // Once the tab manager owns it (e.g. tab mid-creation, space unresolved), it is exposed.
        tabManager.engineHost.setTabAdapter(adapter, for: engine.id)
        XCTAssertNotNil(window.visibleActiveAdapter)
    }

    func testVisibleActiveAdapterUnaffectedWhenNotScopedToCurrentSpace() {
        let window = WindowExtensionAdapter(nsWindow: NSWindow())
        let engine = WKWebViewTab(id: UUID(), webView: WKWebView())
        let adapter = TabExtensionAdapter(engineTab: engine, extensionWindow: window)
        window.add(tab: adapter)
        window.activeAdapter = adapter

        // Floating panel adapters do not scope to the current space and expose their tab as-is.
        XCTAssertNotNil(window.visibleActiveAdapter)
    }

    func testExposedTabsFollowMovesPinsAndSpaceSwitches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try #"{"manifest_version":3,"name":"Index Test","version":"1.0"}"#
            .write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: directory))

        let tabManager = TabManager(engineFactory: WKEngineFactory())
        let spaceA = UUID(), spaceB = UUID()
        tabManager.currentSpaceId = spaceA
        let window = WindowExtensionAdapter(nsWindow: NSWindow())
        window.scopesToCurrentSpace = true
        window.tabManager = tabManager
        let first = Tab(title: "First", spaceId: spaceA)
        let second = Tab(title: "Second", spaceId: spaceA)
        let other = Tab(title: "Other", spaceId: spaceB)
        func install(_ tabs: [Tab], in spaceId: UUID) throws {
            let items = tabs.enumerated().map { index, tab in
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tab.id, parentFolderId: nil, section: tab.isPinned ? .pinned : .unpinned, sortOrder: index)
            }
            let state = try BrowserStateFixture(spaceId: spaceId, activeTabId: nil, tabs: tabs, folders: [], treeItems: items)
            tabManager.installSpaceTabStateForTests(SpaceTabState(state), spaceId: spaceId)
        }
        try install([first, second], in: spaceA)
        try install([other], in: spaceB)
        var adapters: [UUID: TabExtensionAdapter] = [:]
        for tab in [first, second, other] {
            let adapter = TabExtensionAdapter(engineTab: WKWebViewTab(id: tab.id, webView: WKWebView()), extensionWindow: window)
            tabManager.engineHost.setTabAdapter(adapter, for: tab.id)
            window.add(tab: adapter)
            adapters[tab.id] = adapter
        }
        func exposedIds() -> [UUID] {
            window.tabs(for: context).compactMap { ($0 as? TabExtensionAdapter)?.tabId }
        }

        XCTAssertEqual(exposedIds(), [first.id, second.id])
        XCTAssertEqual(adapters[second.id]?.indexInWindow(for: context), 1)
        XCTAssertEqual(adapters[other.id]?.indexInWindow(for: context), NSNotFound)

        try install([second, first], in: spaceA)
        XCTAssertEqual(exposedIds(), [second.id, first.id])
        XCTAssertEqual(adapters[first.id]?.indexInWindow(for: context), 1)

        var pinnedFirst = first
        pinnedFirst.isPinned = true
        try install([second, pinnedFirst], in: spaceA)
        XCTAssertEqual(exposedIds(), [first.id, second.id])
        XCTAssertEqual(adapters[first.id]?.indexInWindow(for: context), 0)

        tabManager.currentSpaceId = spaceB
        XCTAssertEqual(exposedIds(), [other.id])
        XCTAssertEqual(adapters[other.id]?.indexInWindow(for: context), 0)
        XCTAssertEqual(adapters[first.id]?.indexInWindow(for: context), NSNotFound)
    }
}
