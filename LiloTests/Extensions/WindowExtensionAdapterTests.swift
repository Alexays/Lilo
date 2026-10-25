import AppKit
import WebKit
import XCTest
@testable import Lilo

@MainActor
final class WindowExtensionAdapterTests: XCTestCase {

    /// A browser window showing a tab always has an active tab, as in Chrome: showing a terminal, it has a stand-in, listed
    /// and selected, with no url or page, until a web tab is active. A space no browser window shows has none.
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
        let window = WindowExtensionAdapter(nsWindow: NSWindow(), spaceId: spaceId)
        window.tabManager = tabManager
        XCTAssertNil(window.activeTab(for: context), "a space no window shows has no stand-in")

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

    private func makeContext() async throws -> WKWebExtensionContext {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try #"{"manifest_version":3,"name":"Index Test","version":"1.0"}"#
            .write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        return WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: directory))
    }

    func testEachSpaceWindowListsItsOwnTabsInSidebarOrder() async throws {
        let context = try await makeContext()
        let tabManager = TabManager(engineFactory: WKEngineFactory())
        let spaceA = UUID(), spaceB = UUID()
        tabManager.currentSpaceId = spaceA
        let nsWindow = NSWindow()
        let windowA = WindowExtensionAdapter(nsWindow: nsWindow, spaceId: spaceA)
        let windowB = WindowExtensionAdapter(nsWindow: nsWindow, spaceId: spaceB)
        windowA.tabManager = tabManager
        windowB.tabManager = tabManager
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
        for (tab, window) in [(second, windowA), (first, windowA), (other, windowB)] {
            let adapter = TabExtensionAdapter(engineTab: WKWebViewTab(id: tab.id, webView: WKWebView()), extensionWindow: window)
            window.add(tab: adapter)
            adapters[tab.id] = adapter
        }
        func exposedIds(_ window: WindowExtensionAdapter) -> [UUID] {
            window.tabs(for: context).compactMap { ($0 as? TabExtensionAdapter)?.tabId }
        }

        XCTAssertEqual(exposedIds(windowA), [first.id, second.id])
        XCTAssertEqual(adapters[second.id]?.indexInWindow(for: context), 1)
        XCTAssertEqual(windowA.index(of: try XCTUnwrap(adapters[other.id])), NSNotFound)

        try install([second, first], in: spaceA)
        XCTAssertEqual(exposedIds(windowA), [second.id, first.id])
        XCTAssertEqual(adapters[first.id]?.indexInWindow(for: context), 1)

        var pinnedFirst = first
        pinnedFirst.isPinned = true
        try install([second, pinnedFirst], in: spaceA)
        XCTAssertEqual(exposedIds(windowA), [first.id, second.id])
        XCTAssertEqual(adapters[first.id]?.indexInWindow(for: context), 0)

        // A switch hides no tab: the space in the background keeps listing its own.
        tabManager.currentSpaceId = spaceB
        XCTAssertEqual(exposedIds(windowA), [first.id, second.id])
        XCTAssertEqual(exposedIds(windowB), [other.id])
        XCTAssertEqual(adapters[other.id]?.indexInWindow(for: context), 0)
    }

    /// A space no browser window shows reads as a normal window with the browser window's frame, and cannot be closed.
    func testABackgroundSpaceReportsItsBrowserWindowAsANormalWindow() async throws {
        let context = try await makeContext()
        let tabManager = TabManager(engineFactory: WKEngineFactory())
        let nsWindow = NSWindow(contentRect: NSRect(x: 10, y: 20, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: true)
        let shown = WindowExtensionAdapter(nsWindow: nsWindow, spaceId: UUID())
        let background = WindowExtensionAdapter(nsWindow: nsWindow, spaceId: UUID())
        shown.tabManager = tabManager
        background.tabManager = tabManager
        tabManager.windowAdapter = shown

        XCTAssertEqual(background.frame(for: context), nsWindow.frame)
        XCTAssertEqual(background.windowState(for: context), .normal)
        var closeError: Error?
        background.close(for: context) { closeError = $0 }
        XCTAssertNotNil(closeError)
    }
}
