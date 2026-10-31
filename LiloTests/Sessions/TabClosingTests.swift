import XCTest
@testable import Lilo

/// Removing a pinned tab or a bookmark, and bringing it back through Undo and Reopen Closed Tab.
@MainActor
final class TabClosingTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private let favicon = "data:image/png;base64,AAAA"

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
    }

    override func tearDown() {
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    private func makeWindow() throws -> (MainWindowController, Space) {
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        return (makeTestWindow(context, showing: space.id), space)
    }

    /// A saved tab as it sits in the sidebar while closed: no engine, its home page shown.
    private func addClosedTab(_ window: MainWindowController, _ space: Space, _ url: String, bookmarked: Bool = false) throws -> Tab {
        let tab = Tab(
            url: URL(string: url), title: url, faviconDataURL: favicon,
            isPinned: !bookmarked, isBookmarked: bookmarked, isClosed: true,
            homeURL: URL(string: url), homeTitle: url, homeFaviconDataURL: favicon
        )
        try window.applyBrowserCommand(.createTab(spaceId: space.id, tab: tab, activate: false))
        return tab
    }

    private func sidebarItem(_ window: MainWindowController, _ space: Space, _ id: UUID) -> TabTreeItem? {
        window.tabManager.sidebarTreeItems(forSpace: space.id).first { $0.kind == .tab && $0.itemId == id }
    }

    /// A tab that went through `pages`, one load each, settled on the last.
    private func openTab(_ window: MainWindowController, through pages: [String]) async throws -> Tab {
        let tab = try XCTUnwrap(window.createTabStateFirst(url: URL(string: pages[0])))
        let engine = try XCTUnwrap(window.tabManager.engineTab(for: tab.id))
        for (index, page) in pages.enumerated() {
            if index > 0 { engine.loadURL(try XCTUnwrap(URL(string: page))) }
            let loaded = await pollUntil(timeout: 10) { engine.wkWebView.url?.absoluteString == page && !engine.wkWebView.isLoading }
            XCTAssertTrue(loaded, "\(page) loads")
        }
        return tab
    }

    /// The pages behind `id`'s current one, oldest first, once its engine shows `page`.
    private func backPages(_ window: MainWindowController, _ id: UUID, showing page: String) async throws -> [String] {
        let engine = try XCTUnwrap(window.tabManager.engineTab(for: id))
        let shown = await pollUntil(timeout: 10) { engine.wkWebView.url?.absoluteString == page }
        XCTAssertTrue(shown, "\(page) shows")
        return engine.wkWebView.backForwardList.backList.map(\.url.absoluteString)
    }

    func testReopeningAClosedTabBringsBackItsHistory() async throws {
        let (window, _) = try makeWindow()
        let tab = try await openTab(window, through: ["data:text/html,first", "data:text/html,second"])
        window.createTabStateFirst(url: nil)

        window.closeTabStateFirst(id: tab.id, askingPage: false)
        let reopened = try XCTUnwrap(window.restoreClosedTabStateFirst())

        let back = try await backPages(window, reopened.id, showing: "data:text/html,second")
        XCTAssertEqual(back, ["data:text/html,first"])
    }

    func testADuplicateKeepsTheHistoryOfItsTab() async throws {
        let (window, _) = try makeWindow()
        let tab = try await openTab(window, through: ["data:text/html,first", "data:text/html,second"])

        window.duplicateTab(tab)

        let duplicate = try XCTUnwrap(window.tabManager.activeOpenTabId)
        XCTAssertNotEqual(duplicate, tab.id)
        let back = try await backPages(window, duplicate, showing: "data:text/html,second")
        XCTAssertEqual(back, ["data:text/html,first"])
    }

    func testADuplicateOfADiscardedTabKeepsItsHistory() async throws {
        let (window, _) = try makeWindow()
        let tab = try await openTab(window, through: ["data:text/html,first", "data:text/html,second"])
        window.createTabStateFirst(url: nil)
        window.tabManager.discardEngine(tab.id)

        window.duplicateTab(try XCTUnwrap(window.tabManager.tab(for: tab.id)))

        let duplicate = try XCTUnwrap(window.tabManager.activeOpenTabId)
        let back = try await backPages(window, duplicate, showing: "data:text/html,second")
        XCTAssertEqual(back, ["data:text/html,first"])
    }

    func testRemovingAPinnedTabIsUndonePinnedInItsFolderAtItsPlace() async throws {
        let (window, space) = try makeWindow()
        let events = BridgeEventRecorder(window.bridgeRouter)
        let handler = TabBridgeHandler(tabManager: window.tabManager, windowController: window, stateCommandHandler: window.applyBrowserCommand)
        let folder = TabFolder(spaceId: space.id, name: "Work")
        try window.applyBrowserCommand(.createFolder(spaceId: space.id, folder: folder, section: .pinned))
        let tabs = try ["https://a.example/", "https://b.example/", "https://c.example/"].map { try addClosedTab(window, space, $0) }
        for (index, tab) in tabs.enumerated() {
            try window.applyBrowserCommand(.moveSidebarItem(
                spaceId: space.id, kind: .tab, itemId: tab.id, parentFolderId: folder.id, section: .pinned, insert: .index(index)
            ))
        }
        let removed = tabs[1]
        try window.applyBrowserCommand(.renameTab(spaceId: space.id, tabId: removed.id, title: "Board"))

        // The row's close button on a closed pinned tab.
        _ = await handler.handle(message: try XCTUnwrap(BridgeMessage(dictionary: ["action": "unpinTab", "payload": ["id": removed.id.uuidString]])))

        XCTAssertNil(window.tabManager.tab(for: removed.id))
        // An async test holds the main queue: yield until the router's flush delivers the toast.
        _ = await pollUntil { events.events.contains { $0.name == "tabClosedUndoable" } }
        XCTAssertEqual(events.data("tabClosedUndoable").last?["title"] as? String, "Board", "the toast names the tab by its own name")

        let restored = try XCTUnwrap(window.restoreClosedTabStateFirst())

        XCTAssertEqual(restored.id, removed.id)
        let tab = try XCTUnwrap(window.tabManager.tab(for: removed.id))
        XCTAssertTrue(tab.isPinned)
        XCTAssertTrue(tab.isClosed, "it comes back as it was, asleep")
        XCTAssertEqual(tab.url?.absoluteString, "https://b.example/")
        XCTAssertEqual(tab.homeURL?.absoluteString, "https://b.example/")
        XCTAssertEqual(tab.faviconDataURL, favicon)
        XCTAssertEqual(tab.customTitle, "Board")
        let item = try XCTUnwrap(sidebarItem(window, space, removed.id))
        XCTAssertEqual(item.section, .pinned)
        XCTAssertEqual(item.parentFolderId, folder.id)
        XCTAssertEqual(item.sortOrder, 1)
    }

    func testRemovingABookmarkFromTheContextMenuPathIsUndoneAtItsPlace() throws {
        let (window, space) = try makeWindow()
        let bookmarks = try ["https://a.example/", "https://b.example/"].map { try addClosedTab(window, space, $0, bookmarked: true) }

        window.applyContextMenuStateCommands([.setBookmarked(spaceId: space.id, tabId: bookmarks[0].id, isBookmarked: false)])
        XCTAssertNil(window.tabManager.tab(for: bookmarks[0].id))

        XCTAssertNotNil(window.restoreClosedTabStateFirst())

        let item = try XCTUnwrap(sidebarItem(window, space, bookmarks[0].id))
        XCTAssertEqual(item.section, .bookmarked)
        XCTAssertEqual(item.sortOrder, 0)
        XCTAssertEqual(window.tabManager.tab(for: bookmarks[0].id)?.isBookmarked, true)
    }

    func testUnpinningAnOpenPinnedTabIsNoRemoval() throws {
        let (window, space) = try makeWindow()
        let tab = Tab(url: URL(string: "https://open.example/"), isPinned: true, homeURL: URL(string: "https://open.example/"))
        try window.applyBrowserCommand(.createTab(spaceId: space.id, tab: tab, activate: false))

        try window.applyBrowserCommand(.setPinned(spaceId: space.id, tabId: tab.id, isPinned: false))

        XCTAssertEqual(sidebarItem(window, space, tab.id)?.section, .unpinned)
        XCTAssertTrue(window.context.recentlyClosed.recentEntries.isEmpty)
    }
}
