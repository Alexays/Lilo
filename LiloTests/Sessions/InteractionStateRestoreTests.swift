import XCTest
@testable import Lilo

/// A relaunch brings each tab back with its history, on the page the sidebar shows.
@MainActor
final class InteractionStateRestoreTests: XCTestCase {
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

    private func makeWindow() throws -> (MainWindowController, Space) {
        let context = browserContext.context
        let space = try context.spaceManager.createSpace(name: "S", profileId: try context.profileManager.createProfile(name: "P").id)
        return (makeTestWindow(context, showing: space.id), space)
    }

    private func load(_ page: String, in engine: WKWebViewTab) async throws {
        engine.loadURL(try XCTUnwrap(URL(string: page)))
        let loaded = await pollUntil(timeout: 10) { engine.wkWebView.url?.absoluteString == page && !engine.wkWebView.isLoading }
        XCTAssertTrue(loaded, "\(page) loads")
    }

    func testQuittingSavesTheHistoryOfABackgroundTabWhosePageIsLive() async throws {
        let (window, space) = try makeWindow()
        let background = try XCTUnwrap(window.createTabStateFirst(url: nil))
        let engine = try XCTUnwrap(window.tabManager.engineTab(for: background.id))
        try await load("data:text/html,first", in: engine)
        try await load("data:text/html,second", in: engine)
        window.createTabStateFirst(url: nil)
        XCTAssertNotNil(window.tabManager.engineTab(for: background.id), "the background tab's page is still live")

        window.saveSessionBeforeQuit()

        let pool = try browserContext.context.dbManager.pool(for: space.profileId)
        XCTAssertNotNil(try InteractionStateStore(dbPool: pool).load(spaceId: space.id)[background.id])
    }
}
