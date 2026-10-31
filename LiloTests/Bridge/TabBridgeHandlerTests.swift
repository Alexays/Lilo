import XCTest
@testable import Lilo

/// Destructive and decode paths of `TabBridgeHandler`, with a real `TabManager` wired as `MainWindowController+Setup.swift` does.
@MainActor
final class TabBridgeHandlerTests: XCTestCase {

    // MARK: - Fixtures

    private func makeWindowControllerAndHandler() -> (MainWindowController, TabBridgeHandler) {
        let windowController = MainWindowController()
        // `applyBrowserCommand` emits a bridge event on every mutation, which force-unwraps `bridgeRouter`.
        windowController.bridgeRouter = BridgeRouter(chromeWebView: windowController.chromeWebView)
        let handler = TabBridgeHandler(
            tabManager: windowController.tabManager,
            windowController: windowController,
            stateCommandHandler: windowController.applyBrowserCommand
        )
        return (windowController, handler)
    }

    private func installTabs(
        _ tabs: [Tab],
        activeTabId: UUID?,
        spaceId: UUID,
        in windowController: MainWindowController
    ) throws {
        let treeItems = tabs.enumerated().map { index, tab in
            TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tab.id, parentFolderId: nil, section: .unpinned, sortOrder: index)
        }
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: activeTabId,
            tabs: tabs,
            folders: [],
            treeItems: treeItems
        )
        windowController.tabManager.installSpaceTabStateForTests(SpaceTabState(state), spaceId: spaceId)
        windowController.tabManager.currentSpaceId = spaceId
        windowController.tabManager.activeTabId = activeTabId
    }

    private func bridgeMessage(action: String, payload: [String: Any]) -> BridgeMessage {
        BridgeMessage(dictionary: ["action": action, "payload": payload])!
    }

    // MARK: - closeTab

    func test_closeTab_invalidId_isNoOp() async throws {
        let (windowController, handler) = makeWindowControllerAndHandler()
        let spaceId = UUID()
        let tabA = Tab(url: URL(string: "https://a.example"), spaceId: spaceId)
        let tabB = Tab(url: URL(string: "https://b.example"), spaceId: spaceId)
        try installTabs([tabA, tabB], activeTabId: tabA.id, spaceId: spaceId, in: windowController)

        let message = bridgeMessage(action: "closeTab", payload: ["id": UUID().uuidString])
        _ = await handler.handle(message: message)

        XCTAssertEqual(Set(windowController.tabManager.openTabs.map(\.id)), [tabA.id, tabB.id])
    }

    func test_closeTab_validId_closesTab() async throws {
        let (windowController, handler) = makeWindowControllerAndHandler()
        let spaceId = UUID()
        let tabA = Tab(url: URL(string: "https://a.example"), spaceId: spaceId)
        let tabB = Tab(url: URL(string: "https://b.example"), spaceId: spaceId)
        try installTabs([tabA, tabB], activeTabId: tabA.id, spaceId: spaceId, in: windowController)

        let message = bridgeMessage(action: "closeTab", payload: ["id": tabB.id.uuidString])
        _ = await handler.handle(message: message)

        XCTAssertEqual(windowController.tabManager.openTabs.map(\.id), [tabA.id])
    }

    // MARK: - deleteTabFolder

    func test_deleteTabFolder_validId_deletesFolder() async throws {
        let (windowController, handler) = makeWindowControllerAndHandler()
        let spaceId = UUID()
        let folder = TabFolder(spaceId: spaceId, name: "Work", color: "#ff0000")
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: nil,
            tabs: [],
            folders: [folder],
            treeItems: [TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folder.id, parentFolderId: nil, section: .unpinned, sortOrder: 0)]
        )
        windowController.tabManager.installSpaceTabStateForTests(SpaceTabState(state), spaceId: spaceId)
        windowController.tabManager.currentSpaceId = spaceId

        let message = bridgeMessage(action: "deleteTabFolder", payload: ["id": folder.id.uuidString])
        let result = await handler.handle(message: message)

        XCTAssertNotNil(result)
        XCTAssertNil(windowController.tabManager.folder(id: folder.id))
    }

    func test_deleteTabFolder_invalidId_isNoOp() async throws {
        let (windowController, handler) = makeWindowControllerAndHandler()
        let spaceId = UUID()
        let folder = TabFolder(spaceId: spaceId, name: "Work", color: "#ff0000")
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: nil,
            tabs: [],
            folders: [folder],
            treeItems: [TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folder.id, parentFolderId: nil, section: .unpinned, sortOrder: 0)]
        )
        windowController.tabManager.installSpaceTabStateForTests(SpaceTabState(state), spaceId: spaceId)
        windowController.tabManager.currentSpaceId = spaceId

        let message = bridgeMessage(action: "deleteTabFolder", payload: ["id": UUID().uuidString])
        let result = await handler.handle(message: message)

        XCTAssertNil(result)
        XCTAssertNotNil(windowController.tabManager.folder(id: folder.id))
    }

    // MARK: - commitSidebarDrop

    func test_commitSidebarDrop_insertBeforeAnchor_movesItemBeforeAnchor() async throws {
        let (windowController, handler) = makeWindowControllerAndHandler()
        let spaceId = UUID()
        let tabA = Tab(url: URL(string: "https://a.example"), spaceId: spaceId)
        let tabB = Tab(url: URL(string: "https://b.example"), spaceId: spaceId)
        let tabC = Tab(url: URL(string: "https://c.example"), spaceId: spaceId)
        try installTabs([tabA, tabB, tabC], activeTabId: tabA.id, spaceId: spaceId, in: windowController)

        let message = bridgeMessage(action: "commitSidebarDrop", payload: [
            "type": "insert",
            "kind": "tab",
            "id": tabC.id.uuidString,
            "section": "unpinned",
            "fallbackIndex": 0,
            "insertBeforeId": tabA.id.uuidString
        ])
        let result = await handler.handle(message: message)

        XCTAssertNotNil(result)
        let order = windowController.context.browserState.browserSpaceChange(spaceId: spaceId)?.sidebar.rootNodeIds(in: .unpinned)
        XCTAssertEqual(order, [tabC.id, tabA.id, tabB.id])
    }

    func test_commitSidebarDrop_insertAfterAnchor_movesItemAfterAnchor() async throws {
        let (windowController, handler) = makeWindowControllerAndHandler()
        let spaceId = UUID()
        let tabA = Tab(url: URL(string: "https://a.example"), spaceId: spaceId)
        let tabB = Tab(url: URL(string: "https://b.example"), spaceId: spaceId)
        let tabC = Tab(url: URL(string: "https://c.example"), spaceId: spaceId)
        try installTabs([tabA, tabB, tabC], activeTabId: tabA.id, spaceId: spaceId, in: windowController)

        let message = bridgeMessage(action: "commitSidebarDrop", payload: [
            "type": "insert",
            "kind": "tab",
            "id": tabC.id.uuidString,
            "section": "unpinned",
            "fallbackIndex": 2,
            "insertAfterId": tabA.id.uuidString
        ])
        let result = await handler.handle(message: message)

        XCTAssertNotNil(result)
        let order = windowController.context.browserState.browserSpaceChange(spaceId: spaceId)?.sidebar.rootNodeIds(in: .unpinned)
        XCTAssertEqual(order, [tabA.id, tabC.id, tabB.id])
    }

    /// Unresolvable anchors alone degrade to `fallbackIndex`, so this pins the harder case: an item id that does not exist
    /// must be rejected as a no-op, not crash.
    func test_commitSidebarDrop_garbageItemId_noCrashAndStateUnchanged() async throws {
        let (windowController, handler) = makeWindowControllerAndHandler()
        let spaceId = UUID()
        let tabA = Tab(url: URL(string: "https://a.example"), spaceId: spaceId)
        let tabB = Tab(url: URL(string: "https://b.example"), spaceId: spaceId)
        try installTabs([tabA, tabB], activeTabId: tabA.id, spaceId: spaceId, in: windowController)

        let message = bridgeMessage(action: "commitSidebarDrop", payload: [
            "type": "insert",
            "kind": "tab",
            "id": UUID().uuidString,
            "section": "unpinned",
            "fallbackIndex": 0,
            "insertBeforeId": UUID().uuidString,
            "insertAfterId": UUID().uuidString
        ])
        let result = await handler.handle(message: message)
        _ = result // no crash reaching here is itself part of the assertion

        let order = windowController.context.browserState.browserSpaceChange(spaceId: spaceId)?.sidebar.rootNodeIds(in: .unpinned)
        XCTAssertEqual(order, [tabA.id, tabB.id])
    }

    /// A valid item id with unresolvable anchors is not a no-op: `SpaceTab.resolvedInsertIndex` degrades to `fallbackIndex`,
    /// so tabC moves to the front.
    func test_commitSidebarDrop_garbageAnchorsWithValidItemId_fallsBackToFallbackIndex() async throws {
        let (windowController, handler) = makeWindowControllerAndHandler()
        let spaceId = UUID()
        let tabA = Tab(url: URL(string: "https://a.example"), spaceId: spaceId)
        let tabB = Tab(url: URL(string: "https://b.example"), spaceId: spaceId)
        let tabC = Tab(url: URL(string: "https://c.example"), spaceId: spaceId)
        try installTabs([tabA, tabB, tabC], activeTabId: tabA.id, spaceId: spaceId, in: windowController)

        let message = bridgeMessage(action: "commitSidebarDrop", payload: [
            "type": "insert",
            "kind": "tab",
            "id": tabC.id.uuidString,               // valid item...
            "section": "unpinned",
            "fallbackIndex": 0,
            "insertBeforeId": UUID().uuidString,     // ...but both anchors resolve to nothing
            "insertAfterId": UUID().uuidString
        ])
        let result = await handler.handle(message: message)

        XCTAssertNotNil(result)
        let order = windowController.context.browserState.browserSpaceChange(spaceId: spaceId)?.sidebar.rootNodeIds(in: .unpinned)
        XCTAssertEqual(order, [tabC.id, tabA.id, tabB.id], "garbage anchors fall back to fallbackIndex 0, not a no-op")
    }

    /// A payload whose `type` isn't `"insert"`/`"group"` fails to decode entirely: `handle` must return
    /// nil without ever reaching the state store.
    func test_commitSidebarDrop_malformedType_returnsNilAndStateUnchanged() async throws {
        let (windowController, handler) = makeWindowControllerAndHandler()
        let spaceId = UUID()
        let tabA = Tab(url: URL(string: "https://a.example"), spaceId: spaceId)
        let tabB = Tab(url: URL(string: "https://b.example"), spaceId: spaceId)
        try installTabs([tabA, tabB], activeTabId: tabA.id, spaceId: spaceId, in: windowController)

        let message = bridgeMessage(action: "commitSidebarDrop", payload: [
            "type": "bogus",
            "kind": "tab",
            "id": tabB.id.uuidString,
            "section": "unpinned",
            "fallbackIndex": 0
        ])
        let result = await handler.handle(message: message)

        XCTAssertNil(result)
        let order = windowController.context.browserState.browserSpaceChange(spaceId: spaceId)?.sidebar.rootNodeIds(in: .unpinned)
        XCTAssertEqual(order, [tabA.id, tabB.id])
    }

    // MARK: - createTab (typed)

    func test_createTab_typedBareDomain_opensTheWwwSiteHistoryKnows() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        let history = try context.profileContexts.context(for: profileId).history
        try history.recordVisit(url: "https://www.video.test/watch?v=abc", title: "Video")
        try history.recordVisit(url: "https://bare.test/page", title: "Bare")
        try history.recordVisit(url: "http://www.plain.test/", title: "Plain")
        try history.recordVisit(url: "https://www.short.test.evil/", title: "Lookalike")

        let windowController = makeTestWindow(context, showing: space.id)
        let handler = TabBridgeHandler(
            tabManager: windowController.tabManager,
            windowController: windowController,
            stateCommandHandler: windowController.applyBrowserCommand
        )

        var opened: [String?] = []
        for (url, typed) in [
            ("https://video.test", true), ("https://Video.test/", true), ("https://video.test", false),
            ("https://video.test/feed", true), ("https://video.test/?q=1", true), ("https://bare.test", true),
            ("https://plain.test", true), ("https://short.test", true), ("https://nowhere.test", true),
        ] {
            _ = await handler.handle(message: bridgeMessage(action: "createTab", payload: ["url": url, "typed": typed]))
            opened.append(windowController.tabManager.activeTabId.flatMap { windowController.tabManager.tab(for: $0) }?.url?.absoluteString)
        }
        XCTAssertEqual(opened, [
            "https://www.video.test/",
            "https://www.video.test/",
            "https://video.test/",
            "https://video.test/feed",
            "https://video.test/?q=1",
            "https://bare.test/",
            "https://plain.test/",
            "https://short.test/",
            "https://nowhere.test/",
        ])
    }

    // MARK: - openDroppedLinks

    func test_openDroppedLinks_opensNewTabsInOrderAtTheDropOrLoadsTheTabDroppedOn() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        let windowController = makeTestWindow(context, showing: space.id)
        let handler = TabBridgeHandler(
            tabManager: windowController.tabManager,
            windowController: windowController,
            stateCommandHandler: windowController.applyBrowserCommand
        )
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pages = try ["one", "two", "three", "four"].map { name in
            let url = folder.appendingPathComponent("\(name) page.html")
            try "<p>\(name)</p>".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        _ = try XCTUnwrap(windowController.createTabStateFirst(url: nil))
        _ = try XCTUnwrap(windowController.createTabStateFirst(url: nil))
        func order(_ section: TabTreeItem.Section) -> [UUID] {
            context.browserState.browserSpaceChange(spaceId: space.id)?.sidebar.rootNodeIds(in: section) ?? []
        }
        let (above, below) = (order(.unpinned)[0], order(.unpinned)[1])

        _ = await handler.handle(message: bridgeMessage(action: "openDroppedLinks", payload: [
            "urls": [pages[0].absoluteString, pages[1].absoluteString],
            "section": "unpinned", "parentFolderId": NSNull(), "fallbackIndex": 1,
            "insertBeforeId": below.uuidString, "insertAfterId": above.uuidString,
        ]))
        let unpinned = order(.unpinned)
        XCTAssertEqual(unpinned.count, 4)
        XCTAssertEqual([unpinned[0], unpinned[3]], [above, below])
        XCTAssertEqual(unpinned[1...2].map { windowController.tabManager.tab(for: $0)?.url }, [pages[0], pages[1]])
        XCTAssertEqual(windowController.tabManager.activeTabId, unpinned[1])

        _ = await handler.handle(message: bridgeMessage(action: "openDroppedLinks", payload: [
            "urls": [pages[2].absoluteString], "section": "bookmarked", "parentFolderId": NSNull(), "fallbackIndex": 0,
        ]))
        let bookmarked = order(.bookmarked)
        XCTAssertEqual(bookmarked.map { windowController.tabManager.tab(for: $0)?.url }, [pages[2]])

        _ = await handler.handle(message: bridgeMessage(action: "openDroppedLinks", payload: [
            "urls": [pages[3].absoluteString], "tabId": below.uuidString,
        ]))
        XCTAssertEqual(windowController.tabManager.activeTabId, below)
        let loaded = await pollUntil { windowController.tabManager.engineTab(for: below)?.currentURL == pages[3] }
        XCTAssertTrue(loaded)
        XCTAssertEqual(order(.unpinned).count, 4)
    }
}
