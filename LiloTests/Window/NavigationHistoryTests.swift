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

    private func entry(_ url: String, in window: MainWindowController) throws -> HistoryEntry? {
        try XCTUnwrap(window.profileContext?.history).entry(forURL: url)
    }

    func testEveryCommittedPageAndEveryAddressWithinItIsOneVisit() async throws {
        let (window, engine) = try makeTab()
        try await load("<title>A</title><p>a</p>", at: "https://example.com/a", in: engine)
        let page = try entry("https://example.com/a", in: window)
        XCTAssertEqual(page?.visitCount, 1, "commit and load are one visit")

        _ = try await engine.wkWebView.evaluateJavaScript("history.pushState({}, '', '/b'); 0")
        let pushed = await pollUntil(timeout: 5) { (try? self.entry("https://example.com/b", in: window)) != nil }
        XCTAssertTrue(pushed, "a route the page pushed is a visit")
        _ = try await engine.wkWebView.evaluateJavaScript("location.hash = 'c'; 0")
        let fragment = await pollUntil(timeout: 5) { (try? self.entry("https://example.com/b#c", in: window)) != nil }
        XCTAssertTrue(fragment, "a fragment is a visit")

        _ = try await engine.wkWebView.evaluateJavaScript("history.replaceState({}, '', location.href); location.hash = 'c'; 0")
        _ = try await engine.wkWebView.evaluateJavaScript("history.pushState({}, '', '/d'); 0")
        let pushedAgain = await pollUntil(timeout: 5) { (try? self.entry("https://example.com/d", in: window)) != nil }
        XCTAssertTrue(pushedAgain)
        XCTAssertEqual(try entry("https://example.com/b#c", in: window)?.visitCount, 1, "staying at the same address is no visit")
        XCTAssertEqual(try entry("https://example.com/b#c", in: window)?.title, "A")
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
