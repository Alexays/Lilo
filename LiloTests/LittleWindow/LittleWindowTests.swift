import AppKit
import WebKit
import XCTest
@testable import Lilo

/// A Little window holds one page outside the tab list until it moves into a Space or closes.
@MainActor
final class LittleWindowTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var controller: MainWindowController!
    private var home: Space!
    private var work: Space!
    private var otherProfileSpace: Space!

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(LittleWindowController.frameName)")
        browserContext = try await TemporaryBrowserContext()
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        home = try context.spaceManager.createSpace(name: "Home", profileId: profileId)
        work = try context.spaceManager.createSpace(name: "Work", profileId: profileId)
        let otherProfileId = try context.profileManager.createProfile(name: "Q").id
        otherProfileSpace = try context.spaceManager.createSpace(name: "Other", profileId: otherProfileId)
        controller = makeTestWindow(context, showing: home.id, size: NSSize(width: 1000, height: 800))
        controller.didCompleteSessionRestore = true
    }

    override func tearDown() {
        controller.littleWindows.values.forEach { $0.window.close() }
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    private func load(_ little: LittleWindowController, _ url: URL) async throws {
        little.engine.wkWebView.loadHTMLString("<p>page</p>", baseURL: url)
        await pollUntil { !little.engine.wkWebView.isLoading && little.engine.currentURL != nil }
    }

    func testNewLittleWindowOpensBlankOutsideTheTabListWithTheAddressFieldFocused() throws {
        let tabs = controller.tabManager.openTabs.count

        let little = try XCTUnwrap(controller.openLittleWindow(url: nil))

        XCTAssertTrue(controller.littleWindows[little.engine.id] === little)
        XCTAssertEqual(controller.tabManager.openTabs.count, tabs)
        XCTAssertEqual(little.spaceId, home.id)
        XCTAssertNil(little.engine.currentURL)
        XCTAssertEqual(little.window.frame.width, LittleWindowController.defaultSize.width)
        XCTAssertTrue(little.window.firstResponder is NSText, "the address field is being edited")
    }

    func testOpenInSpaceMovesTheLivePageIntoThatSpace() throws {
        let little = try XCTUnwrap(controller.openLittleWindow(url: nil))
        let engine = little.engine

        little.openInSpace(work.id)

        XCTAssertEqual(controller.tabManager.currentSpaceId, work.id)
        XCTAssertEqual(controller.tabManager.activeOpenTabId, engine.id, "the live engine became the active tab")
        XCTAssertTrue(controller.littleWindows.isEmpty)
        XCTAssertFalse(little.window.isVisible)
        XCTAssertTrue(browserContext.context.recentlyClosed.recentEntries.isEmpty, "a moved page is not a closed one")
    }

    func testOpenInASpaceOfAnotherProfileReloadsThePageThere() async throws {
        let little = try XCTUnwrap(controller.openLittleWindow(url: nil))
        let url = try XCTUnwrap(URL(string: "https://example.com/doc"))
        try await load(little, url)

        little.openInSpace(otherProfileSpace.id)

        XCTAssertEqual(controller.tabManager.currentSpaceId, otherProfileSpace.id)
        let active = try XCTUnwrap(controller.tabManager.activeTab)
        XCTAssertNotEqual(active.id, little.engine.id, "another profile's store never takes this engine")
        XCTAssertEqual(active.url, url)
        XCTAssertTrue(controller.littleWindows.isEmpty)
    }

    func testAPageOpeningANewTabGetsAnotherLittleWindowOnItsOwnSpace() async throws {
        let little = try XCTUnwrap(controller.openLittleWindow(url: nil))
        try await load(little, try XCTUnwrap(URL(string: "https://example.com/")))
        controller.switchToSpace(work.id)
        let tabs = controller.tabManager.openTabs.count

        let hasOpener = try await little.engine.wkWebView.evaluateJavaScript("const w = window.open('about:blank'); w.opener === window")

        XCTAssertEqual(hasOpener as? Bool, true)
        XCTAssertEqual(controller.tabManager.openTabs.count, tabs, "no tab in the window behind")
        let opened = try XCTUnwrap(controller.littleWindows.values.first { $0 !== little })
        XCTAssertEqual(opened.spaceId, home.id)
        XCTAssertTrue(opened.dataStore === little.dataStore)
    }

    func testClosingTheBrowserWindowHandsItsLittleWindowsToAnother() throws {
        let little = try XCTUnwrap(controller.openLittleWindow(url: nil))
        let other = makeTestWindow(browserContext.context, showing: work.id)
        defer { other.littleWindows.values.forEach { $0.window.close() }; other.window?.close() }

        controller.window?.close()

        XCTAssertTrue(little.window.isVisible)
        XCTAssertTrue(other.littleWindows[little.engine.id] === little)
        XCTAssertTrue(little.owner === other)
        XCTAssertTrue(little.engine.delegate === other, "the other window serves its page now")
    }

    func testTheLastBrowserWindowHidesWhileALittleWindowIsOpen() throws {
        let little = try XCTUnwrap(controller.openLittleWindow(url: nil))
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)

        XCTAssertFalse(controller.windowShouldClose(window), "closing it would quit the app")
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(little.window.isVisible)
    }

    func testClosingTheWindowSendsItsPageToRecentlyClosed() async throws {
        let little = try XCTUnwrap(controller.openLittleWindow(url: nil))
        let url = try XCTUnwrap(URL(string: "https://example.com/read"))
        try await load(little, url)

        little.closeCurrentTab(nil)

        XCTAssertTrue(controller.littleWindows.isEmpty)
        let entry = try XCTUnwrap(browserContext.context.recentlyClosed.recentEntries.first)
        XCTAssertEqual(entry.content, .page(url))
        XCTAssertEqual(entry.spaceId, home.id)
    }

    func testTheTitleBarWearsTheColorOfItsSpace() throws {
        let red = try browserContext.context.spaceManager.createSpace(name: "Red", color: "#ff0000", profileId: home.profileId)
        let engine = WKWebViewTab(webView: WKWebView(frame: .zero))
        let other = LittleWindowController(engine: engine, spaceId: red.id, dataStore: browserContext.context.engineFactory.defaultDataStore(), owner: controller)
        defer { other.window.close() }
        let expected = MainWindowController.resolvedSidebarBackgroundCSSColor(accentColor: "#ff0000")
        XCTAssertEqual(other.window.backgroundColor.cssHexString, expected, "a Space the window does not show")

        let shown = try XCTUnwrap(controller.openLittleWindow(url: nil))
        controller.applyWindowChromeColors("#841b23")
        controller.pendingWindowBackgroundPersistWork?.cancel()

        XCTAssertEqual(shown.window.backgroundColor.cssHexString, "#841b23", "the shown Space's new color")
        XCTAssertEqual(other.window.backgroundColor.cssHexString, expected)
        let reference = WKWebView(frame: .zero)
        reference.underPageBackgroundColor = NSColor(cssHex: "#841b23")?.contentSurfaceColor
        XCTAssertEqual(shown.engine.wkWebView.underPageBackgroundColor, reference.underPageBackgroundColor, "under its page too")
        reference.underPageBackgroundColor = other.window.backgroundColor.contentSurfaceColor
        XCTAssertEqual(other.engine.wkWebView.underPageBackgroundColor, reference.underPageBackgroundColor)
    }

    func testAtItsSmallestTheWindowKeepsRoomForTheAddress() throws {
        let space = try browserContext.context.spaceManager.createSpace(name: "A Space With A Rather Long Name", profileId: home.profileId)
        controller.switchToSpace(space.id)
        let engine = WKWebViewTab(webView: WKWebView(frame: .zero))
        let little = LittleWindowController(engine: engine, spaceId: space.id, dataStore: browserContext.context.engineFactory.defaultDataStore(), owner: controller)
        defer { little.window.close() }

        little.window.setContentSize(little.window.contentMinSize)
        let titlebar = try XCTUnwrap(little.window.standardWindowButton(.closeButton)?.superview)
        titlebar.layoutSubtreeIfNeeded()

        let pill = try XCTUnwrap(titlebar.subviews.lazy.flatMap(\.subviews).first { $0 is PillView })
        XCTAssertGreaterThanOrEqual(pill.frame.width, 120, "the address field stays usable")
        let controls = try XCTUnwrap(pill.superview).subviews.filter { !$0.isHidden && !($0 is PopupProgressBar) }
        for (index, view) in controls.enumerated() {
            for other in controls[(index + 1)...] { XCTAssertFalse(view.frame.intersects(other.frame), "\(view) overlaps \(other)") }
        }
    }
}
