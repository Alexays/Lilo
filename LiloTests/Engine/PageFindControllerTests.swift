import AppKit
import WebKit
import XCTest
@testable import Lilo

@MainActor
final class PageFindControllerTests: XCTestCase {
    private static let page = """
    <p id="text">alpha beta gamma beta</p>
    <input id="field" value="needle in a field">
    <iframe id="frame" srcdoc="<p id='inner'>framed words</p>"></iframe>
    """

    private var savedFindString: String?

    override func setUp() async throws {
        savedFindString = NSPasteboard(name: .find).string(forType: .string)
    }

    override func tearDown() async throws {
        let pasteboard = NSPasteboard(name: .find)
        pasteboard.clearContents()
        if let savedFindString { pasteboard.setString(savedFindString, forType: .string) }
    }

    func testSeedsFromThePageSelectionAndCopiesItToTheFindPasteboard() async throws {
        let tab = try await loadedTab()
        defer { tab.teardown() }
        try await select("const r = document.createRange(); r.selectNodeContents(text.firstChild); r.setStart(text.firstChild, 6); r.setEnd(text.firstChild, 10); getSelection().removeAllRanges(); getSelection().addRange(r)", in: tab)

        let seeded = await tab.selectedTextForFind()
        XCTAssertEqual(seeded, "beta")
        XCTAssertEqual(NSPasteboard(name: .find).string(forType: .string), "beta")
    }

    func testSeedsFromATextFieldAndASubframe() async throws {
        let tab = try await loadedTab()
        defer { tab.teardown() }
        try await select("field.focus(); field.setSelectionRange(0, 6)", in: tab)
        let fromField = await tab.selectedTextForFind()
        XCTAssertEqual(fromField, "needle")

        try await select("""
        field.blur(); const doc = frame.contentDocument; frame.contentWindow.focus();
        doc.getSelection().selectAllChildren(doc.getElementById('inner'))
        """, in: tab)
        let fromFrame = await tab.selectedTextForFind()
        XCTAssertEqual(fromFrame, "framed words")
    }

    func testNoSelectionSeedsNothingAndLeavesTheFindPasteboardAlone() async throws {
        let tab = try await loadedTab()
        defer { tab.teardown() }
        let changeCount = NSPasteboard(name: .find).changeCount
        let seeded = await tab.selectedTextForFind()
        XCTAssertNil(seeded)
        XCTAssertEqual(NSPasteboard(name: .find).changeCount, changeCount)
    }

    func testPrivateSpaceSeedsWithoutWritingTheSharedFindPasteboard() async throws {
        let tab = try await loadedTab(dataStore: .nonPersistent())
        defer { tab.teardown() }
        try await select("getSelection().selectAllChildren(text)", in: tab)
        let changeCount = NSPasteboard(name: .find).changeCount

        let seeded = await tab.selectedTextForFind()
        XCTAssertEqual(seeded, "alpha beta gamma beta")
        XCTAssertEqual(NSPasteboard(name: .find).changeCount, changeCount)
    }

    func testFindAgainMovesThroughMatchesAndDismissKeepsTheLastOneSelected() async throws {
        let tab = try await loadedTab()
        defer { tab.teardown() }
        let found = await find("beta", in: tab)
        XCTAssertEqual(found?.matchFound, true)
        let firstOffset = try await selectionOffset(in: tab)
        tab.findNext()
        let moved = await pollUntil(timeout: 5) { (try? await self.selectionOffset(in: tab)) != firstOffset }
        XCTAssertTrue(moved)
        tab.findPrevious()
        let movedBack = await pollUntil(timeout: 5) { (try? await self.selectionOffset(in: tab)) == firstOffset }
        XCTAssertTrue(movedBack)

        // The script reaches the page after `_hideFindUI`, which goes first down the same connection.
        tab.dismissFind()
        let selected = try await tab.wkWebView.evaluateJavaScript("getSelection().toString()") as? String
        XCTAssertEqual(selected, "beta")
    }

    func testReportsTheSelectedMatchAmongAllOfThem() async throws {
        let tab = try await loadedTab()
        defer { tab.teardown() }
        let first = await find("BETA", in: tab)
        XCTAssertEqual(first, PageFindController.Result(query: "BETA", matchFound: true, matchIndex: 1, matchCount: 2))
        let next = await findAgain(in: tab, backwards: false)
        XCTAssertEqual(next, PageFindController.Result(query: "BETA", matchFound: true, matchIndex: 2, matchCount: 2))
        let wrapped = await findAgain(in: tab, backwards: false)
        XCTAssertEqual(wrapped?.matchIndex, 1)
        let previous = await findAgain(in: tab, backwards: true)
        XCTAssertEqual(previous?.matchIndex, 2)

        let caseSensitive = await find("BETA", in: tab, caseSensitive: true)
        XCTAssertEqual(caseSensitive, PageFindController.Result(query: "BETA", matchFound: false, matchCount: 0))
    }

    func testATrailingSpaceIsPartOfTheQuery() async throws {
        let tab = try await loadedTab()
        defer { tab.teardown() }
        let result = await find("beta ", in: tab)
        XCTAssertEqual(result?.matchCount, 1, "the last beta ends the paragraph")
    }

    func testANewSearchCountsFromTheTopWhereverTheSelectionIs() async throws {
        let tab = try await loadedTab()
        defer { tab.teardown() }
        try await select("const r = document.createRange(); r.setStart(text.firstChild, 11); r.setEnd(text.firstChild, 16); getSelection().removeAllRanges(); getSelection().addRange(r)", in: tab)
        let result = await find("beta", in: tab)
        XCTAssertEqual(result?.matchIndex, 1)
        let offset = try await selectionOffset(in: tab)
        XCTAssertEqual(offset, 6, "the selected match is the one counted")
    }

    func testFindNextAfterDismissGoesOnWithTheLastSearch() async throws {
        let tab = try await loadedTab()
        defer { tab.teardown() }
        NSPasteboard(name: .find).clearContents()
        _ = await find("beta", in: tab)
        let firstOffset = try await selectionOffset(in: tab)
        tab.dismissFind()

        XCTAssertTrue(tab.canFindAgain)
        let next = await findAgain(in: tab, backwards: false)
        XCTAssertEqual(next?.query, "beta")
        let nextOffset = try await selectionOffset(in: tab)
        XCTAssertNotEqual(nextOffset, firstOffset)
    }

    func testFindAgainWithoutASearchLooksForTheFindPasteboard() async throws {
        let tab = try await loadedTab()
        defer { tab.teardown() }
        let pasteboard = NSPasteboard(name: .find)
        pasteboard.clearContents()
        XCTAssertFalse(tab.canFindAgain, "nothing to find: Find Next is off")

        pasteboard.setString("gamma", forType: .string)
        XCTAssertTrue(tab.canFindAgain)
        tab.findNext()

        let found = await pollUntil(timeout: 5) {
            (try? await tab.wkWebView.evaluateJavaScript("getSelection().toString()")) as? String == "gamma"
        }
        XCTAssertTrue(found, "as in Safari after Command-E in another app")
        XCTAssertEqual(spy.findResults.last?.query, "gamma")
    }

    private let spy = WKWebViewTabDelegateSpy()

    /// Searches `query` and waits for its result.
    private func find(_ query: String, in tab: WKWebViewTab, caseSensitive: Bool = false) async -> PageFindController.Result? {
        let count = spy.findResults.count
        tab.findInPage(query, caseSensitive: caseSensitive)
        _ = await pollUntil(timeout: 5) { self.spy.findResults.count > count }
        return spy.findResults.last
    }

    private func findAgain(in tab: WKWebViewTab, backwards: Bool) async -> PageFindController.Result? {
        let count = spy.findResults.count
        if backwards { tab.findPrevious() } else { tab.findNext() }
        _ = await pollUntil(timeout: 5) { self.spy.findResults.count > count }
        return spy.findResults.last
    }

    private func loadedTab(dataStore: WKWebsiteDataStore = .default()) async throws -> WKWebViewTab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let tab = WKWebViewTab(configuration: configuration)
        tab.delegate = spy
        tab.wkWebView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        tab.wkWebView.loadHTMLString(Self.page, baseURL: URL(string: "https://example.com/"))
        let loaded = await pollUntil(timeout: 5) {
            let condition = "location.href === 'https://example.com/' && document.readyState === 'complete' && !!frame.contentDocument?.getElementById('inner')"
            return ((try? await tab.wkWebView.evaluateJavaScript(condition)) as? Bool) == true
        }
        XCTAssertTrue(loaded)
        return tab
    }

    /// Runs `script` in the page, then waits for WebKit to report the new range selection to the UI process.
    private func select(_ script: String, in tab: WKWebViewTab) async throws {
        _ = try await tab.wkWebView.evaluateJavaScript(script + "; 0")
        let reported = await pollUntil(timeout: 5) {
            (WebViewPrivateAccessors(tab.wkWebView).int("_selectionAttributes") ?? 2) & 1 << 1 != 0
        }
        XCTAssertTrue(reported)
    }

    private func selectionOffset(in tab: WKWebViewTab) async throws -> Int {
        try await tab.wkWebView.evaluateJavaScript("getSelection().anchorOffset") as? Int ?? -1
    }
}
