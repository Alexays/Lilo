import WebKit
import XCTest
@testable import Lilo

/// A pinned tab's own name, set from the chrome's rename editor, and the cue of a saved tab away from its home page.
@MainActor
final class TabRenameTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
    }

    override func tearDown() {
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    private func makePinnedTab() throws -> (MainWindowController, TabBridgeHandler, UUID, Tab) {
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        let window = makeTestWindow(context, showing: space.id)
        let handler = TabBridgeHandler(tabManager: window.tabManager, windowController: window, stateCommandHandler: window.applyBrowserCommand)
        let home = URL(string: "https://mail.example/inbox")
        let tab = Tab(url: home, title: "Inbox (3)", isPinned: true, homeURL: home, homeTitle: "Inbox (3)")
        try window.applyBrowserCommand(.createTab(spaceId: space.id, tab: tab, activate: false))
        return (window, handler, profileId, tab)
    }

    private func send(_ handler: TabBridgeHandler, _ action: String, _ payload: [String: Any]) async throws {
        _ = await handler.handle(message: try XCTUnwrap(BridgeMessage(dictionary: ["action": action, "payload": payload])))
    }

    func testANameOutlivesTitleChangesNavigationsAndARelaunch() async throws {
        let (window, handler, profileId, tab) = try makePinnedTab()

        try await send(handler, "renameTab", ["id": tab.id.uuidString, "title": "  Mail  "])
        window.updateRuntimeTab(id: tab.id) { $0.title = "Inbox (4)" }
        window.updateRuntimeTab(id: tab.id) {
            $0.url = URL(string: "https://docs.other.example/file")
            $0.title = "A shared file"
        }

        let renamed = try XCTUnwrap(window.tabManager.tab(for: tab.id))
        XCTAssertEqual(renamed.customTitle, "Mail")
        XCTAssertEqual(renamed.title, "A shared file", "the window title, history and extensions keep the page title")
        XCTAssertEqual(renamed.homeURL?.absoluteString, "https://mail.example/inbox", "renaming leaves the home page alone")
        XCTAssertEqual(renamed.bridgeData["customTitle"] as? String, "Mail")
        XCTAssertEqual(renamed.bridgeData["homeTitle"] as? String, "Inbox (3)", "away from home, the row shows the slash")

        let spaceId = try XCTUnwrap(renamed.spaceId)
        let state = try XCTUnwrap(window.context.browserState.spaceTabState(forSpace: spaceId))
        let store = try SpaceTabStateStore(dbPool: window.context.dbManager.pool(for: profileId))
        try store.saveMany([(spaceId: spaceId, state: state)])
        let relaunched = try XCTUnwrap(store.load(spaceId: spaceId))
        XCTAssertEqual(SpaceTab(spaceId: spaceId, state: relaunched).tab(id: tab.id)?.customTitle, "Mail")
    }

    func testAnEmptyNameGivesThePageTitleBack() async throws {
        let (window, handler, _, tab) = try makePinnedTab()
        try await send(handler, "renameTab", ["id": tab.id.uuidString, "title": "Mail"])

        try await send(handler, "renameTab", ["id": tab.id.uuidString, "title": " "])

        let named = try XCTUnwrap(window.tabManager.tab(for: tab.id))
        XCTAssertNil(named.customTitle)
        XCTAssertEqual(named.bridgeData["customTitle"] as? String, "")
        XCTAssertEqual(named.title, "Inbox (3)")
    }

    func testOnlySavedTabsTakeAName() async throws {
        let (window, handler, _, tab) = try makePinnedTab()
        let spaceId = try XCTUnwrap(window.tabManager.currentSpaceId)
        let plain = Tab(url: URL(string: "https://plain.example/"), title: "Plain")
        try window.applyBrowserCommand(.createTab(spaceId: spaceId, tab: plain, activate: false))
        try await send(handler, "renameTab", ["id": plain.id.uuidString, "title": "Nope"])
        XCTAssertNil(window.tabManager.tab(for: plain.id)?.customTitle)

        try await send(handler, "renameTab", ["id": tab.id.uuidString, "title": "Mail"])
        try window.applyBrowserCommand(.setPinned(spaceId: spaceId, tabId: tab.id, isPinned: false))
        XCTAssertNil(window.tabManager.tab(for: tab.id)?.customTitle, "an unpinned tab has no rename entry to change it back")
    }

    func testSetAsPinnedPageMovesHomeAndTheSlashGoes() throws {
        let (window, _, _, tab) = try makePinnedTab()
        let spaceId = try XCTUnwrap(window.tabManager.currentSpaceId)
        window.updateRuntimeTab(id: tab.id) {
            $0.url = URL(string: "https://mail.example/sent")
            $0.title = "Sent"
        }
        XCTAssertEqual(window.tabManager.tab(for: tab.id)?.bridgeData["homeTitle"] as? String, "Inbox (3)")

        try window.applyBrowserCommand(.setTabHomeURL(spaceId: spaceId, tabId: tab.id, url: URL(string: "https://mail.example/sent")))

        let moved = try XCTUnwrap(window.tabManager.tab(for: tab.id))
        XCTAssertEqual(moved.homeURL?.absoluteString, "https://mail.example/sent")
        XCTAssertEqual(moved.bridgeData["homeTitle"] as? String, "")
    }

    func testReturningHomeLoadsTheHomePage() async throws {
        let (window, handler, _, tab) = try makePinnedTab()
        window.updateRuntimeTab(id: tab.id) { $0.url = URL(string: "https://other.example/") }

        try await send(handler, "returnTabHome", ["id": tab.id.uuidString])

        let engine = try XCTUnwrap(window.tabManager.engineTab(for: tab.id), "the home page loads in the tab")
        let loading = await pollUntil(timeout: 10) { (engine.view as? WKWebView)?.url?.host == "mail.example" }
        XCTAssertTrue(loading)
        window.updateRuntimeTab(id: tab.id) { $0.url = tab.homeURL }
        XCTAssertEqual(window.tabManager.tab(for: tab.id)?.bridgeData["homeTitle"] as? String, "", "back home, the slash goes")
    }

    func testATypedHomeURLTakesATabAtHomeThereWithoutThePreviousTitle() async throws {
        let (window, handler, _, tab) = try makePinnedTab()

        try await send(handler, "setTabHomeURL", ["id": tab.id.uuidString, "url": "https://calendar.example/week"])

        let moved = try XCTUnwrap(window.tabManager.tab(for: tab.id))
        XCTAssertEqual(moved.homeURL?.absoluteString, "https://calendar.example/week")
        XCTAssertNil(moved.homeTitle, "the inbox's title does not name the calendar")
        let engine = try XCTUnwrap(window.tabManager.engineTab(for: tab.id), "the tab follows its home")
        let loading = await pollUntil(timeout: 10) { (engine.view as? WKWebView)?.url?.host == "calendar.example" }
        XCTAssertTrue(loading)
    }

    func testATypedHomeURLLeavesATabAwayFromHomeOnItsPage() async throws {
        let (window, handler, _, tab) = try makePinnedTab()
        window.updateRuntimeTab(id: tab.id) { $0.url = URL(string: "https://other.example/") }

        try await send(handler, "setTabHomeURL", ["id": tab.id.uuidString, "url": "https://calendar.example/week"])

        XCTAssertEqual(window.tabManager.tab(for: tab.id)?.homeURL?.absoluteString, "https://calendar.example/week")
        XCTAssertNil(window.tabManager.engineTab(for: tab.id), "nothing loads")
    }

    func testAHomeURLMustBeAWebOrFileAddress() async throws {
        let (window, handler, _, tab) = try makePinnedTab()

        try await send(handler, "setTabHomeURL", ["id": tab.id.uuidString, "url": "javascript:alert(1)"])

        XCTAssertEqual(window.tabManager.tab(for: tab.id)?.homeURL, tab.homeURL)
    }
}
