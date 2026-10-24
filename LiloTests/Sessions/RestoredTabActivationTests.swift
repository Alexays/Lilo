import XCTest
@testable import Lilo

/// The restored active tab's web view is built only once the chrome reports it applied its initial
/// state: built during the restore, its content process launch delays the chrome's first paint.
@MainActor
final class RestoredTabActivationTests: XCTestCase {

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

    private func makeRestoredController() throws -> (MainWindowController, UUID) {
        let windowController = MainWindowController(context: browserContext.context)
        windowController.bridgeRouter = BridgeRouter(chromeWebView: windowController.chromeWebView)
        // Startup is skipped under XCTest, so what showing a tab needs is wired by hand.
        windowController.contentContainerView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        windowController.window?.contentView?.addSubview(windowController.contentContainerView)
        let spaceId = UUID()
        let tab = Tab(url: URL(string: "https://restored.example"), spaceId: spaceId)
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: tab.id,
            tabs: [tab],
            folders: [],
            treeItems: [TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tab.id, parentFolderId: nil, section: .unpinned, sortOrder: 0)]
        )
        windowController.tabManager.installSpaceTabStateForTests(SpaceTabState(state), spaceId: spaceId)
        windowController.tabManager.currentSpaceId = spaceId
        windowController.tabManager.activeTabId = tab.id
        return (windowController, tab.id)
    }

    func testRestoreLeavesTheActiveTabUnbuiltUntilTheChromeIsReady() throws {
        let (windowController, tabId) = try makeRestoredController()

        windowController.finishSessionRestore()

        XCTAssertTrue(windowController.didCompleteSessionRestore)
        XCTAssertNil(windowController.tabManager.engineTab(for: tabId))
    }

    func testChromeInitialStateAppliedBuildsTheActiveTab() async throws {
        let (windowController, tabId) = try makeRestoredController()
        windowController.finishSessionRestore()
        let handler = ChromeBridgeHandler(interactiveZoneStore: ChromeInteractiveZoneStore(), windowController: windowController)

        XCTAssertTrue(handler.handledActions.contains("initialStateApplied"), "the router only delivers declared actions")
        _ = await handler.handle(message: try XCTUnwrap(BridgeMessage(dictionary: ["action": "initialStateApplied", "payload": [:]])))

        XCTAssertNotNil(windowController.tabManager.engineTab(for: tabId))
    }
}
