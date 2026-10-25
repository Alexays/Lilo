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

    /// A browser window showing a tab always has an active tab, as in Chrome: showing a terminal, it has a stand-in, listed
    /// and selected, with no url or page, until a web tab is active. The extension window it does not show has none.
    func testABrowserWindowShowingATerminalHasAStandInActiveTab() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try #"{"manifest_version":3,"name":"Stand-in Test","version":"1.0"}"#
            .write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: directory))
        let tabManager = TabManager(engineFactory: WKEngineFactory())
        let spaceId = UUID()
        tabManager.currentSpaceId = spaceId
        let terminal = Tab(title: "Terminal", spaceId: spaceId, kind: .terminal, cwd: NSTemporaryDirectory())
        let item = TabTreeItem(spaceId: spaceId, kind: .tab, itemId: terminal.id, parentFolderId: nil, section: .unpinned, sortOrder: 0)
        let state = try BrowserStateFixture(spaceId: spaceId, activeTabId: terminal.id, tabs: [terminal], folders: [], treeItems: [item])
        tabManager.installSpaceTabStateForTests(SpaceTabState(state), spaceId: spaceId)
        tabManager.activeTabId = terminal.id
        let window = WindowExtensionAdapter(nsWindow: NSWindow())
        window.scopesToCurrentSpace = true
        window.tabManager = tabManager
        XCTAssertNil(window.activeTab(for: context), "a window it does not show has no stand-in")

        tabManager.windowAdapter = window
        let standIn = try XCTUnwrap(window.activeTab(for: context) as? TabExtensionAdapter)
        XCTAssertTrue(window.tabs(for: context).first as AnyObject === standIn)
        XCTAssertEqual(standIn.indexInWindow(for: context), 0)
        XCTAssertTrue(standIn.isSelected(for: context))
        XCTAssertNil(standIn.url(for: context))
        XCTAssertNil(standIn.webView(for: context))

        let engine = WKWebViewTab(id: UUID(), webView: WKWebView())
        let adapter = TabExtensionAdapter(engineTab: engine, extensionWindow: window)
        tabManager.engineHost.setTabAdapter(adapter, for: engine.id)
        window.add(tab: adapter)
        window.activeAdapter = adapter
        XCTAssertTrue(window.activeTab(for: context) as AnyObject === adapter)
        XCTAssertFalse(window.tabs(for: context).contains { $0 as AnyObject === standIn })
        XCTAssertFalse(standIn.isSelected(for: context))

        window.activeAdapter = nil
        XCTAssertTrue(window.activeTab(for: context) as AnyObject === standIn, "the stand-in keeps its identity")
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
