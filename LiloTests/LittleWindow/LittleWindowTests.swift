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
        let profileId = try context.profileManager!.createProfile(name: "P").id
        home = try context.spaceManager!.createSpace(name: "Home", profileId: profileId)
        work = try context.spaceManager!.createSpace(name: "Work", profileId: profileId)
        let otherProfileId = try context.profileManager!.createProfile(name: "Q").id
        otherProfileSpace = try context.spaceManager!.createSpace(name: "Other", profileId: otherProfileId)
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

    private func openPage(_ address: String = "https://example.com/page") throws -> LittleWindowController {
        try XCTUnwrap(controller.openLittleWindow(url: try XCTUnwrap(URL(string: address))))
    }

    private func escape(in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
    }

    func testNewLittleWindowOpensTheStartCardOutsideTheTabList() throws {
        let tabs = controller.tabManager.openTabs.count

        let little = try XCTUnwrap(controller.openLittleWindow(url: nil))

        XCTAssertTrue(controller.littleWindows[little.engine.id] === little)
        XCTAssertEqual(controller.tabManager.openTabs.count, tabs)
        XCTAssertEqual(little.spaceId, home.id)
        XCTAssertNil(little.engine.currentURL)
        XCTAssertEqual(little.mode, .start)
        XCTAssertEqual(little.window.frame.size, LittleWindowController.startSize)
        XCTAssertTrue(little.window.firstResponder is WKWebView, "the command bar's chrome has the keyboard")
        XCTAssertNotIdentical(little.window.firstResponder, little.engine.wkWebView)
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertEqual(little.window.standardWindowButton(type)?.isHidden, true, "the card has no traffic lights")
        }
    }

    func testThePanelJoinsEverySpaceAndSitsBesideAFullScreenWindow() throws {
        let little = try XCTUnwrap(controller.openLittleWindow(url: nil))

        XCTAssertTrue(little.window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(little.window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(little.window.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(little.window.canBecomeKey)
        XCTAssertFalse(little.window.hidesOnDeactivate)
    }

    func testANavigationTurnsTheCardIntoThePageWindow() throws {
        let little = try XCTUnwrap(controller.openLittleWindow(url: nil))

        little.navigate(to: try XCTUnwrap(URL(string: "https://example.com/page")))

        XCTAssertEqual(little.mode, .page)
        XCTAssertEqual(little.window.frame.size, LittleWindowController.defaultSize)
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertEqual(little.window.standardWindowButton(type)?.isHidden, false)
        }
        XCTAssertIdentical(little.window.firstResponder, little.engine.wkWebView)
        XCTAssertEqual(little.window.level, .normal)
        XCTAssertTrue(little.window.isVisible)
    }

    func testOnlyWebPagesAndLocalFilesAreOpenedFromTheBar() throws {
        let little = try XCTUnwrap(controller.openLittleWindow(url: nil))

        for address in ["javascript:alert(1)", "data:text/html,hi", "lilo-chrome://ui/index.html"] {
            little.navigate(to: try XCTUnwrap(URL(string: address)))
            XCTAssertEqual(little.mode, .start, address)
        }
    }

    func testEscapeClosesAPageWindowWhileThePageHasTheKeyboard() throws {
        let little = try openPage()
        little.chromeDidLoad()
        XCTAssertIdentical(little.window.firstResponder, little.engine.wkWebView)

        little.window.sendEvent(try escape(in: little.window))

        XCTAssertFalse(little.window.isVisible)
        XCTAssertTrue(controller.littleWindows.isEmpty)
    }

    func testEscapeInTheStartCardIsTheCommandBarsToHandle() throws {
        let little = try XCTUnwrap(controller.openLittleWindow(url: nil))
        little.chromeDidLoad()

        little.window.sendEvent(try escape(in: little.window))

        XCTAssertTrue(little.window.isVisible, "the chrome's own Escape leaves a scope first, then asks the window to close")
    }

    func testEscapeClosesBeforeTheChromeHasLoaded() throws {
        let little = try XCTUnwrap(controller.openLittleWindow(url: nil))
        XCTAssertFalse(little.isChromeReady)

        little.window.sendEvent(try escape(in: little.window))

        XCTAssertFalse(little.window.isVisible)
    }

    func testTheStartCardClosesWhenTheUserClicksAwayButAPageWindowStays() throws {
        let card = try XCTUnwrap(controller.openLittleWindow(url: nil))
        let page = try openPage()
        for little in [card, page] {
            little.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
            little.chromeDidLoad()
            little.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        }

        XCTAssertFalse(card.window.isVisible)
        XCTAssertTrue(page.window.isVisible)
        XCTAssertTrue(card.engine.currentURL == nil && browserContext.context.recentlyClosed.recentEntries.isEmpty, "an empty card leaves nothing behind")
    }

    func testTheChromeOnlyTakesThePointerWhereItReportsAZone() throws {
        let little = try openPage()
        let host = little.chromeHost
        let inside = NSPoint(x: 100, y: host.bounds.height - 20)
        XCTAssertNil(host.hitTest(inside), "no zone yet: the page and the title bar below take it")

        host.zones.registerZones([(id: "little-bar", rect: NSRect(x: 0, y: 0, width: host.bounds.width, height: 52))])

        XCTAssertNotNil(host.hitTest(inside))
        XCTAssertNil(host.hitTest(NSPoint(x: 100, y: 40)), "the page below the strip is not covered")
    }

    func testTheBarsBridgeNavigatesAndFilesThePage() async throws {
        let little = try XCTUnwrap(controller.openLittleWindow(url: nil))
        let handler = LittleWindowBridgeHandler(little: little)

        _ = await handler.handle(message: try XCTUnwrap(BridgeMessage(dictionary: ["action": "navigate", "payload": ["url": "https://example.com/a"]])))
        XCTAssertEqual(little.mode, .page)

        _ = await handler.handle(message: try XCTUnwrap(BridgeMessage(dictionary: ["action": "littleOpenInSpace", "payload": ["spaceId": work.id.uuidString]])))
        XCTAssertEqual(controller.tabManager.currentSpaceId, work.id)
        XCTAssertTrue(controller.littleWindows.isEmpty)
        XCTAssertFalse(little.window.isVisible)
    }

    func testCommandEnterInTheBarOpensTheAddressAsATabAndClosesTheWindow() async throws {
        let little = try XCTUnwrap(controller.openLittleWindow(url: nil))
        let tabs = controller.tabManager.openTabs.count
        let handler = LittleWindowBridgeHandler(little: little)

        _ = await handler.handle(message: try XCTUnwrap(BridgeMessage(dictionary: ["action": "createTab", "payload": ["url": "https://example.com/b"]])))

        XCTAssertEqual(controller.tabManager.openTabs.count, tabs + 1)
        XCTAssertEqual(controller.tabManager.activeTab?.url, URL(string: "https://example.com/b"))
        XCTAssertFalse(little.window.isVisible)
    }

    func testTheBarsBridgeSharesOnlyTheSearchSettings() async throws {
        let little = try XCTUnwrap(controller.openLittleWindow(url: nil))
        let handler = LittleWindowBridgeHandler(little: little)
        XCTAssertTrue(handler.handledActions.isDisjoint(with: ["setSetting", "closeTab", "createSpace", "toggleSidebar"]))
        XCTAssertTrue(handler.handledActions.contains("getSettings"))
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
        let little = try openPage()
        let other = makeTestWindow(browserContext.context, showing: work.id)
        defer { other.littleWindows.values.forEach { $0.window.close() }; other.window?.close() }

        controller.window?.close()

        XCTAssertTrue(little.window.isVisible)
        XCTAssertTrue(other.littleWindows[little.engine.id] === little)
        XCTAssertTrue(little.owner === other)
        XCTAssertTrue(little.engine.delegate === other, "the other window serves its page now")
    }

    func testTheLastBrowserWindowHidesWhileALittleWindowIsOpen() throws {
        let little = try openPage()
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
        guard case .page(let closedURL, _) = entry.content else { return XCTFail("a page entry") }
        XCTAssertEqual(closedURL, url)
        XCTAssertEqual(entry.spaceId, home.id)
    }

    func testTheTitleBarWearsTheColorOfItsSpace() throws {
        let red = try browserContext.context.spaceManager!.createSpace(name: "Red", color: "#ff0000", profileId: home.profileId)
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
}
