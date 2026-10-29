import AppKit
import XCTest
@testable import Lilo

/// The command bar's top hit loads out of sight in a blank tab, and Enter on it swaps that page in.
@MainActor
final class TopHitPreloadTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var server: TinyHTTPServer!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        server = try await TinyHTTPServer(index: "<title>Videos</title><p>videos</p>")
    }

    override func tearDown() {
        browserContext.tearDown()
        browserContext = nil
        server = nil
        super.tearDown()
    }

    private var page: URL { URL(string: "http://127.0.0.1:\(server.port)/")! }

    private func makeWindow() throws -> (MainWindowController, TabBridgeHandler) {
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId, isPrivate: false)
        let window = makeTestWindow(context, showing: space.id)
        window.setupBridgeLate()
        let tabs = TabBridgeHandler(tabManager: window.tabManager, windowController: window, stateCommandHandler: window.applyBrowserCommand)
        return (window, tabs)
    }

    private func send(_ action: String, _ payload: [String: Any], to handler: any BridgeHandler) async throws {
        _ = await handler.handle(message: try XCTUnwrap(BridgeMessage(dictionary: ["action": action, "payload": payload])))
    }

    /// Straight to the tab manager: the bridge skips preloads in Low Power Mode, which would make these tests follow the Mac's power state.
    private func preload(_ url: String, in window: MainWindowController) {
        window.tabManager.preloadTopHit(URL(string: url))
    }

    func testEnterOnThePreloadedTopHitShowsThePageAlreadyLoadedAndRecordsTheVisit() async throws {
        let (window, tabs) = try makeWindow()
        let tab = try XCTUnwrap(window.createTabStateFirst(url: nil))
        let blank = try XCTUnwrap(window.tabManager.engineTab(for: tab.id))

        preload(page.absoluteString, in: window)
        let preloaded = try XCTUnwrap(window.tabManager.topHitPreload?.engine)
        let loaded = await pollUntil { preloaded.hasCommittedContent && !preloaded.isLoading && preloaded.currentTitle == "Videos" }
        XCTAssertTrue(loaded)
        XCTAssertNil(window.tabManager.tab(for: tab.id)?.url, "the blank tab shows nothing of the page loading out of sight")

        try await send("navigate", ["url": page.absoluteString], to: tabs)

        let shown = try XCTUnwrap(window.tabManager.engineTab(for: tab.id))
        XCTAssertTrue(shown === preloaded)
        XCTAssertFalse(blank === shown)
        XCTAssertNil(window.tabManager.topHitPreload)
        XCTAssertFalse(shown.isLoading, "Enter started no new load")
        XCTAssertTrue(shown.view.isDescendant(of: try XCTUnwrap(window.contentContainerView)))
        let updated = try XCTUnwrap(window.tabManager.tab(for: tab.id))
        XCTAssertEqual(updated.url, page)
        XCTAssertEqual(updated.title, "Videos")
        XCTAssertFalse(updated.isLoading)
        let history = try XCTUnwrap(window.profileContext?.history)
        history.flushPendingWrites()
        XCTAssertEqual(try history.search(query: "Videos", limit: 5).map(\.url), [page.absoluteString])
    }

    func testATabShowingAPageGetsNoPreloadSinceASwapWouldLoseItsBackList() async throws {
        let (window, _) = try makeWindow()
        let tab = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "data:text/html,<p>page</p>")))
        let loaded = await pollUntil { window.tabManager.engineTab(for: tab.id)?.hasCommittedContent == true }
        XCTAssertTrue(loaded)

        preload(page.absoluteString, in: window)

        XCTAssertNil(window.tabManager.topHitPreload)
    }

    func testAnotherTopHitOrTheBarClosingDropsThePreloadAndEnterElsewhereLoadsNormally() async throws {
        let (window, tabs) = try makeWindow()
        let tab = try XCTUnwrap(window.createTabStateFirst(url: nil))
        preload(page.absoluteString, in: window)
        let first = try XCTUnwrap(window.tabManager.topHitPreload?.engine)

        let other = page.appendingPathComponent("other")
        preload(other.absoluteString, in: window)
        XCTAssertEqual(window.tabManager.topHitPreload?.url, other)
        XCTAssertFalse(window.tabManager.topHitPreload?.engine === first)

        try await send("navigate", ["url": page.absoluteString], to: tabs)
        XCTAssertNotNil(window.tabManager.topHitPreload, "the preload of another page stays until the bar closes")
        XCTAssertFalse(window.tabManager.engineTab(for: tab.id) === window.tabManager.topHitPreload?.engine)

        preload("", in: window)
        XCTAssertNil(window.tabManager.topHitPreload)
    }
}
