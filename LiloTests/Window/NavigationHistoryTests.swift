import WebKit
import XCTest
@testable import Lilo

/// What a tab's navigations leave in the history and in the tab's title.
@MainActor
final class NavigationHistoryTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!

    override func setUp() async throws {
        browserContext = try await TemporaryBrowserContext()
    }

    override func tearDown() {
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    /// A window's active tab and its web view, in a public space.
    private func makeTab() throws -> (MainWindowController, WKWebViewTab) {
        let context = browserContext.context
        let space = try context.spaceManager.createSpace(name: "S", profileId: context.profileManager.createProfile(name: "P").id)
        let window = makeTestWindow(context, showing: space.id)
        let tab = try XCTUnwrap(window.createTabStateFirst(url: nil))
        return (window, try XCTUnwrap(window.tabManager.engineTab(for: tab.id)))
    }

    private func load(_ html: String, at url: String, in engine: WKWebViewTab) async throws {
        engine.wkWebView.loadHTMLString(html, baseURL: URL(string: url))
        let loaded = await pollUntil(timeout: 10) { engine.currentURL?.absoluteString == url && !engine.isLoading }
        XCTAssertTrue(loaded, "\(url) never loaded")
    }

    func testAPageWithoutTitleShowsItsAddressRatherThanThePreviousPagesTitle() async throws {
        let home = try XCTUnwrap(URL(string: "https://example.com/raw.txt"))
        let (window, engine) = try makeTab()
        window.updateRuntimeTab(id: engine.id) { $0.homeURL = home }
        try await load("<title>Page A</title>", at: "https://example.com/a", in: engine)
        // WebKit reports the title on its own, after the load ends.
        let titled = await pollUntil(timeout: 10) { window.tabManager.tab(for: engine.id)?.title == "Page A" }
        XCTAssertTrue(titled)

        try await load("plain text", at: home.absoluteString, in: engine)
        let tab = try XCTUnwrap(window.tabManager.tab(for: engine.id))
        XCTAssertEqual(tab.title, Tab.fallbackTitle(for: home))
        XCTAssertEqual(tab.homeTitle, Tab.fallbackTitle(for: home), "the home page's title is not the previous page's")
    }
}
