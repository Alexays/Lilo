import AppKit
import XCTest
@testable import Lilo

/// A tab reports loading only while its web view loads: a blank tab never does.
@MainActor
final class BlankTabLoadingTests: XCTestCase {
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

    private func makeWindow() throws -> MainWindowController {
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId, isPrivate: false)
        let window = makeTestWindow(context, showing: space.id)
        return window
    }

    private func isLoading(_ window: MainWindowController, _ id: UUID) throws -> Bool {
        try XCTUnwrap(window.tabManager.tab(for: id)).isLoading
    }

    func testANewBlankTabIsNotLoading() throws {
        let window = try makeWindow()
        let tab = try XCTUnwrap(window.createTabStateFirst(url: nil))

        XCTAssertFalse(tab.isLoading)
        XCTAssertFalse(try isLoading(window, tab.id))
    }

    /// The path a relaunch takes too: the blank tab's saved web view state is restored into a new engine.
    func testABlankTabWokenFromItsSavedStateIsNotLoading() throws {
        let window = try makeWindow()
        let tab = try XCTUnwrap(window.createTabStateFirst(url: nil))
        XCTAssertNotNil(window.tabManager.engineTab(for: tab.id)?.interactionState)

        window.tabManager.discardEngine(tab.id)
        window.tabManager.activateTabRuntime(id: tab.id)

        XCTAssertNotNil(window.tabManager.engineTab(for: tab.id))
        XCTAssertFalse(try isLoading(window, tab.id))
    }

    func testAPageWokenFromItsSavedStateIsLoading() throws {
        let window = try makeWindow()
        let tab = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "data:text/html,<p>page</p>")))
        let deadline = Date().addingTimeInterval(10)
        while try window.tabManager.engineTab(for: tab.id)?.hasCommittedContent != true || isLoading(window, tab.id), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        window.tabManager.discardEngine(tab.id)
        window.tabManager.activateTabRuntime(id: tab.id)

        XCTAssertTrue(try isLoading(window, tab.id))
    }

    func testAFailedNavigationLeavesTheTabNotLoading() throws {
        let window = try makeWindow()
        let tab = try XCTUnwrap(window.createTabStateFirst(url: nil))
        // The discard port on the loopback refuses the connection at once.
        window.tabManager.load(try XCTUnwrap(URL(string: "http://127.0.0.1:9/")), inTab: tab.id)
        XCTAssertTrue(try isLoading(window, tab.id))

        let deadline = Date().addingTimeInterval(10)
        while try isLoading(window, tab.id), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertFalse(try isLoading(window, tab.id))
    }
}
