import AppKit
import WebKit
import XCTest
@testable import Lilo

/// `window.open` with a size or position opens a popup outside the tab list; without one, a tab.
@MainActor
final class PagePopupTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var controller: MainWindowController!
    private var opener: Tab!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        controller = makeTestWindow(context, showing: space.id, size: NSSize(width: 1000, height: 800))
        opener = try XCTUnwrap(controller.createTabStateFirst(url: nil))
        let webView = try XCTUnwrap(controller.tabManager.engineTab(for: opener.id)).wkWebView
        webView.loadHTMLString("<p>opener</p>", baseURL: URL(string: "https://example.com/"))
        await pollUntil { !webView.isLoading && webView.url != nil }
    }

    override func tearDown() {
        controller.pagePopups.values.forEach { $0.close() }
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    private func openFromPage(_ features: String) async throws {
        let webView = try XCTUnwrap(controller.tabManager.engineTab(for: opener.id)).wkWebView
        _ = try await webView.evaluateJavaScript("window.popup = window.open('about:blank', '', '\(features)'); true")
    }

    private var openTabCount: Int { controller.tabManager.openTabs.count }

    func testThePopupHeaderNamesASecureLockAndLeavesNotSecureToTheHost() throws {
        let header = PopupHeaderView(inWindow: true)
        let icon = { () throws -> NSImageView in
            try XCTUnwrap(header.subviews.flatMap(\.subviews).compactMap { $0 as? NSImageView }.first)
        }

        header.setHost("example.com", insecure: false)
        XCTAssertTrue(try icon().isAccessibilityElement())
        XCTAssertEqual(try icon().image?.accessibilityDescription, "Secure Connection".localized)

        header.setHost("example.com", insecure: true)
        XCTAssertFalse(try icon().isAccessibilityElement(), "the host label says it already")
    }

    func testWindowOpenWithoutSizeOpensATab() async throws {
        let tabs = openTabCount
        try await openFromPage("")

        XCTAssertTrue(controller.pagePopups.isEmpty)
        XCTAssertEqual(openTabCount, tabs + 1)
    }

    func testAWindowOpenWithoutAUserActivationIsBlocked() async throws {
        let tabs = openTabCount
        let webView = try XCTUnwrap(controller.tabManager.engineTab(for: opener.id)).wkWebView

        WebViewPrivateAccessors(webView).evaluateWithoutUserGesture("window.open('about:blank', '')")
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(openTabCount, tabs)
    }

    /// A key press in the opener's page: the page has a user activation for a few seconds.
    private func pressKeyInOpener() async throws -> NSWindow {
        let webView = try XCTUnwrap(controller.tabManager.engineTab(for: opener.id)).wkWebView
        let window = NSWindow(contentRect: controller.contentContainerView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.contentContainerView
        XCTAssertTrue(window.makeFirstResponder(webView))
        let keyPress = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a",
            isARepeat: false, keyCode: 0
        ))
        NSApp.sendEvent(keyPress)
        try await Task.sleep(nanoseconds: 100_000_000)
        return window
    }

    func testAWindowOpenAfterTheClickTaskButSoonAfterAKeyPressOpensATab() async throws {
        let tabs = openTabCount
        let webView = try XCTUnwrap(controller.tabManager.engineTab(for: opener.id)).wkWebView
        let window = try await pressKeyInOpener()
        defer { window.close() }

        WebViewPrivateAccessors(webView).evaluateWithoutUserGesture("window.open('about:blank', '')")

        let opened = await pollUntil(timeout: 5) { self.openTabCount == tabs + 1 }
        XCTAssertTrue(opened, "a page may open a window a few seconds after the user's key press, as in Chrome")
    }

    func testAFrameMayOpenOneWindowSoonAfterTheUserActivatedItsPage() async throws {
        let frame = try await openerSubframe()
        let webView = try XCTUnwrap(controller.tabManager.engineTab(for: opener.id)).wkWebView
        let tabs = openTabCount
        let window = try await pressKeyInOpener()
        defer { window.close() }

        WebViewPrivateAccessors(webView).evaluateWithoutUserGesture("window.open('about:blank', '')", in: frame)
        let opened = await pollUntil(timeout: 5) { self.openTabCount == tabs + 1 }
        XCTAssertTrue(opened, "a widget may open its window after a request, as in Chrome")

        WebViewPrivateAccessors(webView).evaluateWithoutUserGesture("window.open('about:blank', '')", in: frame)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(openTabCount, tabs + 1, "the open uses up the activation, as in Chrome")
    }

    func testABackgroundNewTabLinkLeavesTheOpenerActive() throws {
        let tabs = openTabCount
        let engine = try XCTUnwrap(controller.tabManager.engineTab(for: opener.id))

        let webView = controller.createPopupWebView(
            configuration: engine.wkWebView.configuration,
            requestedURL: URL(string: "https://example.com/next"),
            opener: engine,
            inBackground: true
        )

        XCTAssertNotNil(webView)
        XCTAssertEqual(openTabCount, tabs + 1)
        XCTAssertEqual(controller.tabManager.activeTabId, opener.id)
    }

    /// A real press on the opener's page, whose own click handlers open a tab as X's trending list does. Sent to the web
    /// view directly, the press never reaches the window's monitor: the test records the release it would have.
    private func clickOpener(_ button: AgentInput.MouseButton, modifiers: NSEvent.ModifierFlags = []) async throws {
        let engine = try XCTUnwrap(controller.tabManager.engineTab(for: opener.id))
        let window = try XCTUnwrap(controller.window)
        if engine.view.window == nil {
            window.alphaValue = 0
            window.orderFrontRegardless()
            window.setFrame(NSRect(x: -20000, y: -20000, width: 800, height: 600), display: false)
            engine.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            window.contentView?.addSubview(engine.view)
        }
        _ = try await engine.wkWebView.evaluateJavaScript("document.documentElement.style.height = '100%'; onclick = onauxclick = () => open(''); true")
        let tabs = openTabCount
        controller.lastClick = WKWebViewTab.Click(
            uptime: ProcessInfo.processInfo.systemUptime, buttonNumber: button == .middle ? 2 : 0, modifierFlags: modifiers
        )
        await AgentInput.click(engine.wkWebView, at: CGPoint(x: 100, y: 100), button: button, modifiers: modifiers)
        await pollUntil { self.openTabCount > tabs }
    }

    func testATabAPageOpensFromAMiddleOrCommandClickOpensBehind() async throws {
        try await clickOpener(.middle)
        XCTAssertEqual(controller.tabManager.activeTabId, opener.id)

        try await clickOpener(.left, modifiers: .command)
        XCTAssertEqual(controller.tabManager.activeTabId, opener.id)
    }

    func testATabAPageOpensFromAPlainClickOrOutsideAClickHandlerComesForward() async throws {
        try await clickOpener(.left)
        XCTAssertNotEqual(controller.tabManager.activeTabId, opener.id)

        controller.tabManager.activateTabRuntime(id: opener.id)
        controller.lastClick = WKWebViewTab.Click(uptime: ProcessInfo.processInfo.systemUptime, buttonNumber: 2, modifierFlags: [])
        try await openFromPage("")
        XCTAssertNotEqual(controller.tabManager.activeTabId, opener.id, "the page handles no click: the open is its own, not the user's")
    }

    func testSizedWindowOpenOpensAPopupOutsideTheTabList() async throws {
        let tabs = openTabCount
        try await openFromPage("width=400,height=300")

        let popup = try XCTUnwrap(controller.pagePopups.values.first)
        XCTAssertEqual(popup.openerTabId, opener.id)
        XCTAssertNil(popup.peekView)
        XCTAssertEqual(openTabCount, tabs)
    }

    func testPopupFeatureWithoutSizeOpensAPopup() async throws {
        try await openFromPage("popup")

        XCTAssertEqual(controller.pagePopups.count, 1)
    }

    func testOpenerTabShowsAPopupBadgeWhileItsPopupIsOpen() async throws {
        try await openFromPage("width=400,height=300")
        XCTAssertEqual(controller.tabManager.tab(for: opener.id)?.hasPopup, true)

        try XCTUnwrap(controller.pagePopups.values.first).close()

        XCTAssertEqual(controller.tabManager.tab(for: opener.id)?.hasPopup, false)
    }

    func testThePopupWindowFollowsTheColorOfItsOpenersSpace() async throws {
        try await openFromPage("width=400,height=300")
        let popupWindow = try XCTUnwrap(controller.pagePopups.values.first?.window)

        controller.applyWindowChromeColors("#841b23")
        controller.pendingWindowBackgroundPersistWork?.cancel()

        XCTAssertEqual(popupWindow.backgroundColor.cssHexString, "#841b23")
        let reference = WKWebView(frame: .zero)
        reference.underPageBackgroundColor = NSColor(cssHex: "#841b23")?.contentSurfaceColor
        XCTAssertEqual(controller.pagePopups.values.first?.engine.wkWebView.underPageBackgroundColor, reference.underPageBackgroundColor, "under its page too")
    }

    func testAPeekShowsTheSpaceSurfaceUnderItsPage() async throws {
        controller.context.settingsStore.set("singleWindow", value: "true")
        try await openFromPage("width=400,height=300")
        let peek = try XCTUnwrap(controller.pagePopups.values.first)
        XCTAssertNotNil(peek.peekView)

        let reference = WKWebView(frame: .zero)
        reference.underPageBackgroundColor = controller.currentContentSurfaceColor
        XCTAssertEqual(peek.engine.wkWebView.underPageBackgroundColor, reference.underPageBackgroundColor)
    }

    func testClosingThePopupWindowClosesThePopup() async throws {
        try await openFromPage("width=400,height=300")
        let popupWindow = try XCTUnwrap(controller.pagePopups.values.first?.window)

        popupWindow.performClose(nil)

        XCTAssertTrue(controller.pagePopups.isEmpty)
    }

    func testCloseTabInThePopupWindowClosesOnlyThePopup() async throws {
        let tabs = openTabCount
        try await openFromPage("width=400,height=300")

        try XCTUnwrap(controller.pagePopups.values.first).closeCurrentTab(nil)

        XCTAssertTrue(controller.pagePopups.isEmpty)
        XCTAssertEqual(openTabCount, tabs)
    }

    func testCloseTabWithAPeekClosesThePeekNotTheTab() async throws {
        controller.context.settingsStore.set("singleWindow", value: "true")
        let tabs = openTabCount
        try await openFromPage("width=400,height=300")

        controller.closeCurrentTab(nil)

        XCTAssertTrue(controller.pagePopups.isEmpty)
        XCTAssertEqual(openTabCount, tabs)
    }

    func testClickOutsideThePeekCardDismissesIt() async throws {
        controller.context.settingsStore.set("singleWindow", value: "true")
        let window = NSWindow(contentRect: controller.contentContainerView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = controller.contentContainerView
        try await openFromPage("width=400,height=300")
        let peek = try XCTUnwrap(controller.pagePopups.values.first?.peekView)
        XCTAssertTrue(peek.window === window)
        peek.layoutSubtreeIfNeeded()
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 4, y: 4), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))

        NSApp.sendEvent(click)

        XCTAssertTrue(controller.pagePopups.isEmpty)
    }

    func testSingleWindowModeShowsThePopupOverItsOpenerOnly() async throws {
        controller.context.settingsStore.set("singleWindow", value: "true")
        try await openFromPage("width=400,height=300")

        let peek = try XCTUnwrap(controller.pagePopups.values.first?.peekView)
        XCTAssertTrue(peek.superview === controller.contentContainerView)

        let other = try XCTUnwrap(controller.createTabStateFirst(url: nil))
        XCTAssertNil(peek.superview)
        controller.closeTabStateFirst(id: other.id, undoable: false)
        controller.tabManager.activateTabRuntime(id: opener.id)
        XCTAssertTrue(peek.superview === controller.contentContainerView)
    }

    func testOpeningAPopupAsATabKeepsItsPageAndOpener() async throws {
        let tabs = openTabCount
        try await openFromPage("width=400,height=300")
        let popup = try XCTUnwrap(controller.pagePopups.values.first)

        popup.openAsTab()

        XCTAssertTrue(controller.pagePopups.isEmpty)
        XCTAssertEqual(openTabCount, tabs + 1)
        XCTAssertTrue(controller.tabManager.engineTab(for: popup.engine.id) === popup.engine)
        let order = controller.tabManager.openTabs.map(\.id)
        XCTAssertEqual(order.firstIndex(of: popup.engine.id), order.firstIndex(of: opener.id).map { $0 + 1 })
        let webView = try XCTUnwrap(controller.tabManager.engineTab(for: opener.id)).wkWebView
        let closed = try await webView.evaluateJavaScript("window.popup.closed") as? Bool
        XCTAssertEqual(closed, false)
    }

    func testATerminalLinkOpensInAPeekEvenWithoutSingleWindowMode() throws {
        let tabs = openTabCount
        controller.openTerminalLink(try XCTUnwrap(URL(string: "https://example.com/docs")), from: opener.id)

        let popup = try XCTUnwrap(controller.pagePopups.values.first)
        XCTAssertEqual(popup.openerTabId, opener.id)
        XCTAssertTrue(popup.peekView?.superview === controller.contentContainerView)
        XCTAssertEqual(openTabCount, tabs)
    }

    func testOpeningAPopupInSplitMakesItAPaneBesideItsOpener() async throws {
        try await openFromPage("width=400,height=300")
        let popup = try XCTUnwrap(controller.pagePopups.values.first)
        XCTAssertTrue(popup.canOpenInSplit)

        popup.openAsTab(inSplit: true)

        XCTAssertEqual(Set(controller.tabManager.activeSplit?.layout.paneIds ?? []), [opener.id, popup.engine.id])
    }

    func testClosingTheOpenerTabClosesItsPopup() async throws {
        try await openFromPage("width=400,height=300")
        XCTAssertEqual(controller.pagePopups.count, 1)

        controller.closeTabStateFirst(id: opener.id, undoable: false)

        XCTAssertTrue(controller.pagePopups.isEmpty)
    }

    // MARK: - Link peek

    private func pinOpener() throws {
        let spaceId = try XCTUnwrap(controller.tabManager.currentSpaceId)
        _ = try controller.applyBrowserCommand(.setPinned(spaceId: spaceId, tabId: opener.id, isPinned: true))
    }

    /// Clicks a link to `href` in the opener's page, then waits until a peek opens or the tab leaves.
    private func clickLink(_ href: String) async throws {
        let engine = try XCTUnwrap(controller.tabManager.engineTab(for: opener.id))
        _ = try await engine.wkWebView.evaluateJavaScript("""
            const link = document.createElement('a');
            link.href = '\(href)';
            document.body.appendChild(link);
            link.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
            true
            """)
        await pollUntil { !self.controller.pagePopups.isEmpty || engine.currentURL?.host != "example.com" }
    }

    func testALinkToAnotherSiteFromAPinnedTabOpensInAPeek() async throws {
        try pinOpener()
        let tabs = openTabCount

        try await clickLink("https://other.test/article")

        let popup = try XCTUnwrap(controller.pagePopups.values.first)
        XCTAssertEqual(popup.openerTabId, opener.id)
        XCTAssertTrue(popup.peekView?.superview === controller.contentContainerView)
        XCTAssertEqual(popup.engine.currentURL?.host, "other.test")
        XCTAssertEqual(controller.tabManager.engineTab(for: opener.id)?.currentURL?.host, "example.com")
        XCTAssertEqual(openTabCount, tabs)
    }

    func testALinkWithinTheSiteOfAPinnedTabStaysInTheTab() async throws {
        try pinOpener()

        try await clickLink("https://www.example.com/next")

        XCTAssertTrue(controller.pagePopups.isEmpty)
        XCTAssertEqual(controller.tabManager.engineTab(for: opener.id)?.currentURL?.host, "www.example.com")
    }

    /// The opener's policy for a click on `href`, handed over as WebKit does: a page cannot fake a
    /// click's modifiers, and a link to an unreachable host may never move the tab.
    private func decidePolicy(
        forClickOn href: String, modifierFlags: NSEvent.ModifierFlags = [], in frame: WKFrameInfo? = nil, downloads: Bool = false
    ) throws -> WKNavigationActionPolicy? {
        let engine = try XCTUnwrap(controller.tabManager.engineTab(for: opener.id))
        var decision: WKNavigationActionPolicy?
        engine.webView(
            engine.wkWebView,
            decidePolicyFor: LinkClick(url: try XCTUnwrap(URL(string: href)), modifierFlags: modifierFlags, targetFrame: frame, downloads: downloads),
            preferences: WKWebpagePreferences()
        ) { policy, _ in decision = policy }
        return decision
    }

    /// An iframe of the opener's page, as WebKit reports it.
    private func openerSubframe() async throws -> WKFrameInfo {
        let engine = try XCTUnwrap(controller.tabManager.engineTab(for: opener.id))
        engine.wkWebView.loadHTMLString(#"<iframe src="https://widget.test/frame"></iframe>"#, baseURL: URL(string: "https://example.com/"))
        await pollUntil { !engine.subframes.isEmpty && !engine.wkWebView.isLoading }
        return try XCTUnwrap(engine.subframes.last)
    }

    func testCommandClickInAFrameOpensABackgroundTab() async throws {
        let frame = try await openerSubframe()
        let tabs = openTabCount

        XCTAssertEqual(try decidePolicy(forClickOn: "https://widget.test/next", modifierFlags: .command, in: frame), .cancel)

        XCTAssertEqual(openTabCount, tabs + 1)
        XCTAssertEqual(controller.tabManager.activeTabId, opener.id)
    }

    func testCommandClickOnADownloadLinkDownloadsIt() throws {
        let tabs = openTabCount

        XCTAssertEqual(try decidePolicy(forClickOn: "https://example.com/report.csv", modifierFlags: .command, downloads: true), .download)

        XCTAssertEqual(openTabCount, tabs)
    }

    func testPinnedTabsFollowLinksWhenPeekingIsTurnedOff() throws {
        controller.context.settingsStore.set("peekPinnedTabLinks", value: "false")
        try pinOpener()

        XCTAssertEqual(try decidePolicy(forClickOn: "https://other.test/article"), .allow)
        XCTAssertTrue(controller.pagePopups.isEmpty)
    }

    func testOptionClickDownloadsTheLink() throws {
        XCTAssertEqual(try decidePolicy(forClickOn: "https://example.com/file.pdf", modifierFlags: .option), .download)
        XCTAssertNotEqual(try decidePolicy(forClickOn: "https://example.com/file.pdf", modifierFlags: [.option, .command]), .download)
    }

    func testShiftClickPeeksAnyLink() throws {
        XCTAssertEqual(try decidePolicy(forClickOn: "https://example.com/next", modifierFlags: .shift), .cancel)

        let popup = try XCTUnwrap(controller.pagePopups.values.first)
        XCTAssertEqual(popup.openerTabId, opener.id)
        XCTAssertEqual(popup.engine.currentURL?.path, "/next")
        XCTAssertEqual(controller.tabManager.engineTab(for: opener.id)?.currentURL?.path, "/")
    }

    func testALinkInAPeekStaysInThePeek() throws {
        _ = try decidePolicy(forClickOn: "https://example.com/next", modifierFlags: .shift)
        let popup = try XCTUnwrap(controller.pagePopups.values.first)
        var decision: WKNavigationActionPolicy?

        popup.engine.webView(
            popup.engine.wkWebView,
            decidePolicyFor: LinkClick(url: try XCTUnwrap(URL(string: "https://other.test/")), modifierFlags: .shift),
            preferences: WKWebpagePreferences()
        ) { policy, _ in decision = policy }

        XCTAssertEqual(decision, .allow)
        XCTAssertEqual(controller.pagePopups.count, 1)
    }

    func testCommandShiftClickOpensAForegroundTabNotAPeek() throws {
        let tabs = openTabCount

        XCTAssertEqual(try decidePolicy(forClickOn: "https://example.com/next", modifierFlags: [.command, .shift]), .cancel)

        XCTAssertTrue(controller.pagePopups.isEmpty)
        XCTAssertEqual(openTabCount, tabs + 1)
        XCTAssertNotEqual(controller.tabManager.activeTabId, opener.id, "Shift brings it forward, as in Chrome and Safari")
    }

    func testAWindowShowsOneLinkPeekAtATime() async throws {
        try pinOpener()
        try await clickLink("https://other.test/first")
        let first = try XCTUnwrap(controller.pagePopups.values.first)

        controller.openLinkPeek(try XCTUnwrap(URL(string: "https://other.test/second")), from: opener.id)

        XCTAssertEqual(controller.pagePopups.count, 1)
        XCTAssertFalse(controller.pagePopups.values.first === first)
    }

    func testALinkPeekLeavesAPopupPeekOpen() async throws {
        controller.context.settingsStore.set("singleWindow", value: "true")
        try await openFromPage("width=400,height=300")
        let popup = try XCTUnwrap(controller.pagePopups.values.first)

        XCTAssertEqual(try decidePolicy(forClickOn: "https://example.com/next", modifierFlags: .shift), .cancel)

        XCTAssertEqual(controller.pagePopups.count, 2)
        XCTAssertTrue(controller.pagePopups[popup.engine.id] === popup)
    }

    func testALinkPeekComingBackToThePinnedTabsSiteGoesBackToTheTab() async throws {
        try pinOpener()
        try await clickLink("https://other.test/sign-in")
        let peek = try XCTUnwrap(controller.pagePopups.values.first)

        _ = try await peek.engine.wkWebView.evaluateJavaScript("location.href = 'https://www.example.com/callback?code=1'; true")
        await pollUntil { self.controller.pagePopups.isEmpty }

        XCTAssertTrue(controller.pagePopups.isEmpty)
        XCTAssertEqual(controller.tabManager.engineTab(for: opener.id)?.currentURL?.absoluteString, "https://www.example.com/callback?code=1")
    }

    func testAPopupWindowAsksBeforeOpeningAnExternalApp() async throws {
        try await openFromPage("width=400,height=300")
        let popup = try XCTUnwrap(controller.pagePopups.values.first)
        let popupWindow = try XCTUnwrap(popup.window)

        controller.tab(popup.engine, launchExternalURL: try XCTUnwrap(URL(string: "zoommtg://join")), fromOrigin: "https://example.com")

        let sheet = try XCTUnwrap(popupWindow.attachedSheet)
        popupWindow.endSheet(sheet, returnCode: .alertSecondButtonReturn)
    }

    func testAnExternalAppDecisionHoldsForItsSchemeOnly() async throws {
        try await openFromPage("width=400,height=300")
        let popup = try XCTUnwrap(controller.pagePopups.values.first)
        let popupWindow = try XCTUnwrap(popup.window)
        try XCTUnwrap(controller.profileContext).sitePermissions.upsert(origin: "https://example.com", type: "external-scheme:zoommtg", granted: false)

        controller.tab(popup.engine, launchExternalURL: try XCTUnwrap(URL(string: "zoommtg://join")), fromOrigin: "https://example.com")
        XCTAssertNil(popupWindow.attachedSheet, "the site's answer for Zoom links holds")

        controller.tab(popup.engine, launchExternalURL: try XCTUnwrap(URL(string: "slack://open")), fromOrigin: "https://example.com")
        let sheet = try XCTUnwrap(popupWindow.attachedSheet, "another app is asked for, as in Chrome")
        popupWindow.endSheet(sheet, returnCode: .alertSecondButtonReturn)
    }

    func testExpandingALinkPeekKeepsItsPageAsAnUnpinnedTab() async throws {
        try pinOpener()
        try await clickLink("https://other.test/article")
        let popup = try XCTUnwrap(controller.pagePopups.values.first)

        popup.openAsTab()

        XCTAssertTrue(controller.pagePopups.isEmpty)
        XCTAssertTrue(controller.tabManager.engineTab(for: popup.engine.id) === popup.engine)
        XCTAssertEqual(controller.tabManager.activeOpenTabId, popup.engine.id)
        XCTAssertEqual(controller.tabManager.tab(for: popup.engine.id)?.isPinned, false)
    }

    func testExpandingALinkPeekKeepsTheFaviconItsPageLoaded() async throws {
        try pinOpener()
        try await clickLink("https://other.test/article")
        let popup = try XCTUnwrap(controller.pagePopups.values.first)
        controller.context.faviconService.seed(host: "other.test", dataURL: "data:image/png;base64,QUJD", dominantColor: "#112233", profileId: nil)

        popup.openAsTab()

        let tab = try XCTUnwrap(controller.tabManager.tab(for: popup.engine.id))
        XCTAssertEqual(tab.faviconDataURL, "data:image/png;base64,QUJD")
        XCTAssertEqual(tab.faviconDominantColor, "#112233")
    }

    func testEscClosesALinkPeek() async throws {
        let window = NSWindow(contentRect: controller.contentContainerView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = controller.contentContainerView
        try pinOpener()
        try await clickLink("https://other.test/article")
        XCTAssertTrue(controller.pagePopups.values.first?.peekView?.window === window)
        let esc = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))

        NSApp.sendEvent(esc)

        XCTAssertTrue(controller.pagePopups.isEmpty)
    }
}

/// A link click, as WebKit reports it: in the main frame unless `targetFrame` names another.
private final class LinkClick: WKNavigationAction {
    private let url: URL
    private let flags: NSEvent.ModifierFlags
    private let frame: WKFrameInfo?
    private let downloads: Bool

    init(url: URL, modifierFlags: NSEvent.ModifierFlags, targetFrame: WKFrameInfo? = nil, downloads: Bool = false) {
        self.url = url
        flags = modifierFlags
        frame = targetFrame
        self.downloads = downloads
        super.init()
    }

    override var request: URLRequest { URLRequest(url: url) }
    override var navigationType: WKNavigationType { .linkActivated }
    override var modifierFlags: NSEvent.ModifierFlags { flags }
    override var targetFrame: WKFrameInfo? { frame }
    override var shouldPerformDownload: Bool { downloads }
}

@MainActor
final class PopupHeaderViewTests: XCTestCase {
    func testThePeekHostPillFitsTheWholeHostWhenThereIsRoom() throws {
        let header = PopupHeaderView(inWindow: false)
        header.frame = NSRect(x: 0, y: 0, width: 600, height: 44)
        header.setHost("github.com", insecure: false)
        header.layoutSubtreeIfNeeded()

        let label = try XCTUnwrap(header.subviews.flatMap(\.subviews).compactMap { $0 as? NSTextField }.first)
        XCTAssertGreaterThanOrEqual(label.frame.width, try XCTUnwrap(label.cell).cellSize.width, "the host is drawn without truncation")
    }

    func testANarrowPeekKeepsTheRegistrableDomainAndButtonsAtTheirSize() throws {
        let header = PopupHeaderView(inWindow: false)
        header.frame = NSRect(x: 0, y: 0, width: 320, height: 44)
        header.showsSplitButton = true
        header.setHost("accounts.some-very-long-domain-name.example.co.uk", insecure: false)
        header.layoutSubtreeIfNeeded()

        let pill = try XCTUnwrap(header.subviews.first { $0 is PillView })
        let label = try XCTUnwrap(pill.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertTrue(label.stringValue.hasPrefix("acc"), label.stringValue)
        XCTAssertTrue(label.stringValue.hasSuffix("\u{2026}example.co.uk"), label.stringValue)
        XCTAssertGreaterThanOrEqual(label.frame.width, try XCTUnwrap(label.cell).cellSize.width.rounded(.up), "shown whole")
        for case let button as NSButton in header.subviews where !button.isHidden {
            XCTAssertGreaterThanOrEqual(button.frame.width, button.intrinsicContentSize.width, "\(button.toolTip ?? "") at its size")
        }
    }

    /// The narrowest peek, 240 points: the host keeps its room and nothing overlaps.
    func testANarrowPeekKeepsTheHostInItsPill() throws {
        let header = PopupHeaderView(inWindow: false)
        header.frame = NSRect(x: 0, y: 0, width: 240, height: 44)
        header.showsSplitButton = true
        header.setHost("accounts.example.com", insecure: false)
        header.layoutSubtreeIfNeeded()

        let pill = try XCTUnwrap(header.subviews.first { $0 is PillView })
        XCTAssertGreaterThanOrEqual(pill.frame.width, 80, "room for the lock and part of the host")
        let label = try XCTUnwrap(pill.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertTrue(label.stringValue.hasSuffix("example.com"), label.stringValue)
        XCTAssertFalse(label.stringValue.hasPrefix("\u{2026}"), "the label's own truncation adds the one ellipsis")
        for view in pill.subviews { XCTAssertTrue(pill.bounds.contains(view.frame), "\(view) inside the pill") }
        let shown = header.subviews.filter { !$0.isHidden && !($0 is PopupProgressBar) }
        for (index, view) in shown.enumerated() {
            XCTAssertTrue(header.bounds.contains(view.frame), "\(view) inside the bar")
            for other in shown[(index + 1)...] { XCTAssertFalse(view.frame.intersects(other.frame), "\(view) overlaps \(other)") }
        }
    }
}
