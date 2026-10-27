import WebKit
import XCTest
@testable import Lilo

/// Quitting writes each space's tab tree into its own profile's database, and nothing of private spaces,
/// then closes every page through its handlers.
@MainActor
final class BrowserContextQuitSaveTests: XCTestCase {
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

    func testQuitSaveWritesEachSpaceIntoItsOwnProfilePool() throws {
        let context = browserContext.context
        let profileA = try context.profileManager.createProfile(name: "A").id
        let profileB = try context.profileManager.createProfile(name: "B").id
        let spaceA = try context.spaceManager.createSpace(name: "A", profileId: profileA)
        let spaceB = try context.spaceManager.createSpace(name: "B", profileId: profileB)
        let privateA = try context.spaceManager.createSpace(name: "P", profileId: profileA, isPrivate: true)
        for space in [spaceA, spaceB, privateA] {
            let state = SpaceTabState(activeTabId: nil, activationHistory: [], tree: .empty)
            context.browserState.storeSpace(id: space.id, snapshot: .init(spaceTab: SpaceTab(spaceId: space.id, state: state), engines: [:]))
        }

        context.saveSpaceStatesBeforeQuit()

        let storeA = SpaceTabStateStore(dbPool: try context.dbManager.pool(for: profileA))
        let storeB = SpaceTabStateStore(dbPool: try context.dbManager.pool(for: profileB))
        XCTAssertNotNil(try storeA.load(spaceId: spaceA.id))
        XCTAssertNil(try storeA.load(spaceId: spaceB.id), "a space must never be written into another profile's database")
        XCTAssertNotNil(try storeB.load(spaceId: spaceB.id))
        XCTAssertNil(try storeA.load(spaceId: privateA.id), "private spaces leave nothing behind")
    }

    func testQuitRunsTheBeforeUnloadHandlerOfEveryPageSuspendedOnesIncluded() async throws {
        let page = Data("<script>addEventListener('beforeunload', (event) => event.isTrusted && localStorage.setItem(location.pathname, 'saved'))</script>".utf8)
        let server = try await TinyHTTPServer { _ in ("200 OK", ["Content-Type: text/html"], page) }
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let window = makeTestWindow(context, showing: try context.spaceManager.createSpace(name: "S", profileId: profileId).id)
        var engines: [WKWebViewTab] = []
        for path in ["/suspended", "/shown"] {
            let tab = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "http://127.0.0.1:\(server.port)\(path)")))
            let engine = try XCTUnwrap(window.tabManager.engineTab(for: tab.id))
            let loaded = await pollUntil { engine.wkWebView.url?.path == path && !engine.wkWebView.isLoading }
            XCTAssertTrue(loaded)
            engines.append(engine)
        }
        engines[0].freeze()

        await context.resumePagesBeforeQuit()
        context.closePagesBeforeQuit()

        let reader = context.engineFactory.createTab(configuration: .init(dataStore: context.profileManager.dataStore(for: profileId)))
        defer { reader.teardown() }
        reader.wkWebView.load(URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/reader"))))
        var saved: [String: String] = [:]
        let unloaded = await pollUntil {
            saved = (try? await reader.wkWebView.evaluateJavaScript("({...localStorage})")) as? [String: String] ?? [:]
            return saved["/suspended"] != nil && saved["/shown"] != nil
        }
        XCTAssertTrue(unloaded, "every page ran its beforeunload handler, got \(saved)")
    }
}
