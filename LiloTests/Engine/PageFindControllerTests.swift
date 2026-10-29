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
        let found = await tab.findInPage("beta", caseSensitive: false)
        XCTAssertTrue(found)
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

    private func loadedTab(dataStore: WKWebsiteDataStore = .default()) async throws -> WKWebViewTab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let tab = WKWebViewTab(configuration: configuration)
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
