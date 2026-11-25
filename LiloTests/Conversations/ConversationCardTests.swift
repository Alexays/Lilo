import XCTest
@testable import Lilo

/// An activated start opens as a mini card over the active page, which keeps the focus, unless the
/// placement setting says a tab or there is no page to float over.
@MainActor
final class ConversationCardTests: XCTestCase {
    private var browser: TemporaryBrowserContext!
    private var window: MainWindowController!
    private var pageId: UUID!

    override func setUp() async throws {
        browser = try await TemporaryBrowserContext()
        let context = browser.context
        let space = try context.spaceManager!.createSpace(name: "Work", profileId: try context.profileManager!.createProfile(name: "Test").id)
        window = makeTestWindow(context, showing: space.id)
        context.settingsStore!.set("agentsEnabled", value: "true")
        pageId = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "data:text/html,page"), activate: false)).id
        window.activateTabStateFirst(id: pageId)
    }

    override func tearDown() async throws {
        browser.tearDown()
    }

    private func start() async throws -> Tab {
        let tab = await window.startConversation(agentId: "test-agent", cwd: NSTemporaryDirectory(), activate: true)
        return try XCTUnwrap(tab)
    }

    func testStartOpensACardOverTheActivePage() async throws {
        let recorder = BridgeEventRecorder(window.bridgeRouter)
        let conversation = try await start()

        XCTAssertEqual(window.tabManager.activeTab?.id, pageId)
        let opened = await pollUntil { recorder.events.contains { $0.name == "openConversationCard" } }
        XCTAssertTrue(opened)
        let card = recorder.events.first { $0.name == "openConversationCard" }?.data
        XCTAssertEqual(card?["tabId"] as? String, conversation.id.uuidString)
        XCTAssertEqual(card?["sourceTabId"] as? String, pageId.uuidString)
    }

    func testTabPlacementActivatesTheConversation() async throws {
        browser.context.settingsStore!.set("agentConversationPlacement", value: "tab")
        let conversation = try await start()

        XCTAssertEqual(window.tabManager.activeTab?.id, conversation.id)
    }

    func testAConversationActiveOpensTheNextInATab() async throws {
        browser.context.settingsStore!.set("agentConversationPlacement", value: "tab")
        _ = try await start()
        browser.context.settingsStore!.set("agentConversationPlacement", value: "mini")
        let next = try await start()

        XCTAssertEqual(window.tabManager.activeTab?.id, next.id)
    }
}
