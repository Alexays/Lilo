import AppKit
import WebKit
import XCTest
@testable import Lilo

/// Menu bar items act on the active tab: one that cannot act on it is greyed out.
@MainActor
final class MenuValidationTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var window: MainWindowController!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        let context = browserContext.context
        let space = try context.spaceManager.createSpace(name: "S", profileId: try context.profileManager.createProfile(name: "P").id)
        window = makeTestWindow(context, showing: space.id)
    }

    override func tearDown() {
        window.pagePopups.values.forEach { $0.close() }
        window.littleWindows.values.forEach { $0.window.close() }
        window.tabManager.terminalHost.liveTabIds.forEach(window.tabManager.terminalHost.forget)
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    private func isEnabled(_ action: Selector) -> Bool {
        window.validateUserInterfaceItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
    }

    /// File > Open as Tab, as the menu bar builds it.
    private func openAsTabItem() throws -> NSMenuItem {
        let saved = NSApp.mainMenu
        defer { NSApp.mainMenu = saved }
        AppDelegate().setupMainMenu()
        let file = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "File".localized }?.submenu)
        return try XCTUnwrap(file.items.first { $0.title == "Open as Tab".localized })
    }

    private func pageEngine() -> WKWebViewTab {
        window.context.engineFactory.createTab(configuration: .init(
            dataStore: window.tabManager.dataStore, tabId: nil, nativeConfiguration: nil, profileId: window.tabManager.profileId
        ))
    }

    private let pageActions = [
        #selector(MainWindowController.reloadCurrentPage(_:)),
        #selector(MainWindowController.printCurrentPage(_:)),
        #selector(MainWindowController.toggleReader(_:)),
        #selector(MainWindowController.togglePictureInPicture(_:))
    ]

    func testAppKitKeepsNativeMenuValidationWhenHighlightsAreClosed() {
        let menu = NSMenu()
        let back = NSMenuItem(title: "Back", action: #selector(MainWindowController.goBackInHistory(_:)), keyEquivalent: "")
        let sidebar = NSMenuItem(title: "", action: #selector(MainWindowController.toggleSidebarVisibility(_:)), keyEquivalent: "")
        back.target = window
        sidebar.target = window
        window.sidebarVisible = true
        menu.addItem(back)
        menu.addItem(sidebar)

        menu.update()

        XCTAssertFalse(back.isEnabled)
        XCTAssertEqual(sidebar.title, "Hide Sidebar".localized)
    }

    func testDynamicMenuActionsWaitForTheHighlightsToClose() throws {
        let context = browserContext.context
        let space = try XCTUnwrap(context.spaceManager.space(with: try XCTUnwrap(window.tabManager.currentSpaceId)))
        _ = try context.spaceManager.createSpace(name: "Other", profileId: space.profileId)
        _ = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "about:blank")))
        let delegate = AppDelegate()
        delegate.browserContext.windows.add(window)
        let menu = NSMenu()
        delegate.dynamicMenus[.moveToSpace] = menu
        window.isShowingWhatsNew = true

        delegate.menuNeedsUpdate(menu)
        menu.update()
        XCTAssertFalse(try XCTUnwrap(menu.items.first).isEnabled)

        window.isShowingWhatsNew = false
        delegate.menuNeedsUpdate(menu)
        menu.update()
        XCTAssertTrue(try XCTUnwrap(menu.items.first).isEnabled)
    }

    func testPageActionsAreOffOnATerminal() throws {
        XCTAssertNotNil(window.createTerminalTab(activate: true))

        for action in pageActions { XCTAssertFalse(isEnabled(action), "\(action)") }
        XCTAssertTrue(isEnabled(#selector(MainWindowController.zoomInCurrentPage(_:))), "a terminal zooms its text")
        XCTAssertTrue(isEnabled(#selector(MainWindowController.showFindBar(_:))), "and finds in it")
        XCTAssertTrue(isEnabled(#selector(MainWindowController.findNextMatch(_:))))
    }

    func testPageActionsAreOnForAPage() async throws {
        let tab = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "about:blank")))
        let webView = try XCTUnwrap(window.tabManager.engineTab(for: tab.id)).wkWebView
        webView.loadHTMLString("<p>page</p>", baseURL: URL(string: "https://example.com/"))
        await pollUntil(timeout: 5) { !webView.isLoading && webView.url != nil }

        for action in pageActions { XCTAssertTrue(isEnabled(action), "\(action)") }
    }

    func testFindNextIsOffWithoutAPageOrATerminal() {
        XCTAssertFalse(isEnabled(#selector(MainWindowController.findNextMatch(_:))))
        XCTAssertFalse(isEnabled(#selector(MainWindowController.findPreviousMatch(_:))))
    }

    func testReopenLastClosedTabNeedsAClosedTab() throws {
        let reopen = #selector(MainWindowController.restoreClosedTab(_:))
        XCTAssertFalse(isEnabled(reopen))

        let tab = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "https://example.com/")))
        window.closeTabStateFirst(id: tab.id)

        XCTAssertTrue(isEnabled(reopen))
    }

    func testALongClosedPageTitleEndsWithAnEllipsis() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/" + String(repeating: "a", count: 80)))
        browserContext.context.recentlyClosed.push(.page(url), spaceId: try XCTUnwrap(window.tabManager.currentSpaceId), parentFolderId: nil, section: nil, sortOrder: nil)
        let menu = NSMenu()

        window.populateRecentlyClosedMenu(menu)

        let title = try XCTUnwrap(menu.items.first?.title)
        XCTAssertEqual(title.count, 60)
        XCTAssertTrue(title.hasSuffix("\u{2026}"), title)
    }

    func testTheReaderItemSaysHideInReaderMode() async throws {
        let tab = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "about:blank")))
        let webView = try XCTUnwrap(window.tabManager.engineTab(for: tab.id)).wkWebView
        let paragraph = "<p>" + String(repeating: "A sentence long enough to read as an article, with commas, and more. ", count: 12) + "</p>"
        webView.loadHTMLString("<article><h1>Title</h1>\(paragraph)\(paragraph)\(paragraph)</article>", baseURL: URL(string: "https://example.com/"))
        await pollUntil(timeout: 5) { !webView.isLoading && webView.url?.host() == "example.com" }
        let item = NSMenuItem(title: "", action: #selector(MainWindowController.toggleReader(_:)), keyEquivalent: "")

        window.toggleReader(nil)

        let reading = await pollUntil(timeout: 5) { self.window.readerModeTabs.contains(tab.id) }
        XCTAssertTrue(reading)
        XCTAssertTrue(window.validateUserInterfaceItem(item))
        XCTAssertEqual(item.title, "Hide Reader".localized)

        window.toggleReader(nil)

        XCTAssertTrue(window.validateUserInterfaceItem(item))
        XCTAssertEqual(item.title, "Show Reader".localized)
    }

    func testShowReaderLeavesAPageThatIsNotAnArticleOutOfReaderMode() async throws {
        let tab = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "about:blank")))
        let webView = try XCTUnwrap(window.tabManager.engineTab(for: tab.id)).wkWebView
        webView.loadHTMLString("<input value=typed>", baseURL: URL(string: "https://example.com/"))
        await pollUntil(timeout: 5) { !webView.isLoading && webView.url?.host() == "example.com" }
        let item = NSMenuItem(title: "", action: #selector(MainWindowController.toggleReader(_:)), keyEquivalent: "")

        window.toggleReader(nil)
        // A script in the reader's world runs after the reader's: once it answers, the reader has.
        _ = try await webView.evaluateJavaScript("1", in: nil, contentWorld: ReaderMode.world)

        XCTAssertFalse(window.readerModeTabs.contains(tab.id))
        XCTAssertTrue(window.validateUserInterfaceItem(item))
        XCTAssertEqual(item.title, "Show Reader".localized)
    }

    func testSaveAsOffersAPDFUnderItsOwnNameAndType() async throws {
        let tab = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "about:blank")))
        let webView = try XCTUnwrap(window.tabManager.engineTab(for: tab.id)).wkWebView
        let pdf = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)).dataWithPDF(inside: NSRect(x: 0, y: 0, width: 200, height: 100))
        let pdfURL = try XCTUnwrap(URL(string: "https://example.com/files/report.pdf"))
        webView.load(pdf, mimeType: "application/pdf", characterEncodingName: "", baseURL: pdfURL)
        await pollUntil(timeout: 5) { !webView.isLoading && webView.url == pdfURL }

        window.savePageAs(nil)

        let panel = try XCTUnwrap(window.window?.attachedSheet as? NSSavePanel)
        XCTAssertEqual(panel.nameFieldStringValue, "report.pdf")
        XCTAssertEqual(panel.allowedContentTypes, [.pdf])
        // Saving would write to the panel's last folder, out of the test's reach: the bytes it writes are the main resource's.
        window.window?.endSheet(panel, returnCode: .cancel)
        let original: Data? = await withCheckedContinuation { continuation in
            if !WebViewPrivateAccessors(webView).mainResourceData(completion: { continuation.resume(returning: $0) }) {
                continuation.resume(returning: nil)
            }
        }
        XCTAssertEqual(original, pdf)
    }

    func testTheReaderLeavesThePageNoGlobal() async throws {
        let webView = WKWebView()
        let paragraph = "<p>" + String(repeating: "A sentence long enough to read as an article, with commas, and more. ", count: 12) + "</p>"
        webView.loadHTMLString("<article><h1>Title</h1>\(paragraph)\(paragraph)\(paragraph)</article>", baseURL: URL(string: "https://example.com/"))
        await pollUntil(timeout: 5) { !webView.isLoading && webView.url != nil }

        ReaderMode.apply(to: webView)

        let shown = await pollUntil(timeout: 5) {
            ((try? await webView.evaluateJavaScript("!!document.getElementById('lilo-reader')")) as? Bool) == true
        }
        XCTAssertTrue(shown)
        let readability = try await webView.evaluateJavaScript("typeof Readability")
        XCTAssertEqual(readability as? String, "undefined")
    }

    func testDuplicateTabOpensTheCopyRightBelowTheOriginal() throws {
        let original = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "https://example.com/a")))
        _ = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "https://example.com/b")))
        _ = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "https://example.com/c")))
        window.activateTabStateFirst(id: original.id)

        window.duplicateCurrentTab(nil)

        let copy = try XCTUnwrap(window.tabManager.activeOpenTabId)
        XCTAssertNotEqual(copy, original.id)
        XCTAssertEqual(window.tabManager.tab(for: copy)?.url, original.url)
        let order = window.tabManager.openTabs.map(\.id)
        XCTAssertEqual(order.firstIndex(of: copy), order.firstIndex(of: original.id).map { $0 + 1 })
    }

    func testOpenAsTabIsCommandOAndOffInTheBrowserWindowAlone() throws {
        let item = try openAsTabItem()
        _ = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "https://example.com/")))

        XCTAssertEqual(item.keyEquivalent, "o")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
        XCTAssertFalse(window.validateUserInterfaceItem(item))
    }

    func testOpenAsTabOpensThePeekShownInTheBrowserWindow() throws {
        let item = try openAsTabItem()
        let opener = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "https://example.com/")))
        window.openLinkPeek(try XCTUnwrap(URL(string: "https://other.test/article")), from: opener.id)
        let popup = try XCTUnwrap(window.pagePopups.values.first)

        XCTAssertTrue(window.validateUserInterfaceItem(item))
        XCTAssertTrue(try XCTUnwrap(window.window).tryToPerform(try XCTUnwrap(item.action), with: item))

        XCTAssertTrue(window.pagePopups.isEmpty)
        XCTAssertTrue(window.tabManager.engineTab(for: popup.engine.id) === popup.engine)
        XCTAssertEqual(window.tabManager.activeOpenTabId, popup.engine.id)
    }

    /// Back and Forward act on the shown peek, never on the tab hidden under it.
    func testPageActionsGoToTheShownPeek() async throws {
        let first = try XCTUnwrap(URL(string: "data:text/html,<p>first</p>"))
        let second = try XCTUnwrap(URL(string: "data:text/html,<p>second</p>"))
        let opener = try XCTUnwrap(window.createTabStateFirst(url: first))
        let tab = try XCTUnwrap(window.tabManager.engineTab(for: opener.id))
        let tabLoaded = await pollUntil { tab.wkWebView.backForwardList.currentItem?.url == first }
        XCTAssertTrue(tabLoaded)
        window.openLinkPeek(first, from: opener.id)
        let peek = try XCTUnwrap(window.pagePopups.values.first?.engine)
        for url in [first, second] {
            if peek.wkWebView.backForwardList.currentItem?.url != url { peek.loadURL(url) }
            let committed = await pollUntil { peek.wkWebView.backForwardList.currentItem?.url == url }
            XCTAssertTrue(committed, "\(url) never committed")
        }
        XCTAssertTrue(isEnabled(#selector(MainWindowController.goBackInHistory(_:))), "the peek can go back, the tab cannot")

        window.goBackInHistory(nil)

        let wentBack = await pollUntil { peek.wkWebView.backForwardList.currentItem?.url == first }
        XCTAssertTrue(wentBack)
        XCTAssertFalse(isEnabled(#selector(MainWindowController.goBackInHistory(_:))))
        XCTAssertTrue(isEnabled(#selector(MainWindowController.goForwardInHistory(_:))))
        XCTAssertEqual(tab.wkWebView.backForwardList.backList.count, 0, "the tab under the peek never moved")

        window.zoomInCurrentPage(nil)

        XCTAssertGreaterThan(peek.pageZoom, 1)
        XCTAssertEqual(tab.pageZoom, 1, "zoom acts on the peek, not the tab under it")
    }

    func testOpenAsTabOpensThePageOfAPopupWindow() throws {
        let item = try openAsTabItem()
        let opener = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "https://example.com/")))
        let engine = pageEngine()
        window.presentPagePopup(engine, openerTabId: opener.id, contentSize: NSSize(width: 400, height: 300), topLeft: nil, inPeek: false)
        let popupWindow = try XCTUnwrap(window.pagePopups[engine.id]?.window)

        XCTAssertTrue(popupWindow.tryToPerform(try XCTUnwrap(item.action), with: item))

        XCTAssertTrue(window.pagePopups.isEmpty)
        XCTAssertTrue(window.tabManager.engineTab(for: engine.id) === engine)
    }

    func testOpenAsTabMovesALittleWindowIntoItsSpace() throws {
        let item = try openAsTabItem()
        window.didCompleteSessionRestore = true
        let little = try XCTUnwrap(window.openLittleWindow(url: nil))

        XCTAssertTrue(little.window.tryToPerform(try XCTUnwrap(item.action), with: item))

        XCTAssertTrue(window.littleWindows.isEmpty)
        XCTAssertEqual(window.tabManager.currentSpaceId, little.spaceId)
        XCTAssertEqual(window.tabManager.activeOpenTabId, little.engine.id)
    }
}
