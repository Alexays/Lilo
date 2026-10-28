import AppKit
import WebKit
import XCTest
@testable import Lilo

@MainActor
final class DocumentPiPControllerTests: XCTestCase {
    private var factory: WKEngineFactory!
    private var controller: DocumentPiPController!

    /// A tab wired as the window controller wires it: the factory asks the controller, the tab hands it its popup.
    private func makeTab(origin: String = "https://example.com/", persistent: Bool = true) async -> WKWebViewTab {
        factory = WKEngineFactory()
        controller = DocumentPiPController()
        let tab = factory.createTab(configuration: .init(dataStore: factory.createDataStore(persistent: persistent, identifier: nil)))
        factory.documentPiPHandler = { [unowned self] _, size, activated in
            controller.prepare(tab, size: size, userActivated: activated, automatic: false)
        }
        tab.documentPiPWebViewProvider = { [unowned self] configuration, size in controller.open(configuration: configuration, size: size, opener: tab) }
        tab.wkWebView.loadHTMLString("<p>call</p>", baseURL: URL(string: origin))
        // The URL is set before the document commits: wait for this page's own content, or a commit could follow.
        _ = await pollUntil(timeout: 5) { (try? await tab.wkWebView.evaluateJavaScript("document.body?.textContent === 'call'")) as? Bool == true }
        addTeardownBlock { @MainActor [controller] in
            controller?.close()
            tab.teardown()
        }
        return tab
    }

    /// Asked as from a click: `evaluateJavaScript` runs with a user gesture, which a page needs to open its PiP window.
    private func requestWindow(_ tab: WKWebViewTab, width: Int = 300, height: Int = 356) async throws -> String? {
        _ = try await tab.wkWebView.evaluateJavaScript("""
            window.__state = undefined;
            documentPictureInPicture.requestWindow({ width: \(width), height: \(height) })
              .then(w => { window.__pip = w; window.__state = 'open'; }, e => { window.__state = e.name; });
            true
            """)
        var state: String?
        _ = await pollUntil(timeout: 5) {
            state = (try? await tab.wkWebView.evaluateJavaScript("window.__state")) as? String
            return state != nil
        }
        return state
    }

    private var panel: NSPanel? { controller.webView?.window as? NSPanel }

    func testOpenHostsThePopupInANonActivatingPanelHiddenFromScreenSharing() async throws {
        let tab = await makeTab()

        let state = try await requestWindow(tab)

        XCTAssertEqual(state, "open")
        let panel = try XCTUnwrap(panel)
        panel.alphaValue = 0
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(panel.sharingType, .none, "the PiP window stays out of the user's own screen share")
        XCTAssertEqual(panel.level, .floating)
        XCTAssertEqual(panel.contentLayoutRect.size, NSSize(width: 300, height: 356))
        XCTAssertEqual(controller.openerId, tab.id)
    }

    func testThePanelJoinsEverySpaceAndFullScreenApps() {
        let opener = WKWebViewTab(configuration: WKWebViewConfiguration())
        let controller = DocumentPiPController()
        defer { controller.close(); opener.teardown() }

        let webView = controller.open(configuration: WKWebViewConfiguration(), size: NSSize(width: 300, height: 300), opener: opener)

        // Read before the run loop turns: the test host makes every window transient on each app update.
        let behavior = webView.window?.collectionBehavior ?? []
        webView.window?.alphaValue = 0
        XCTAssertTrue(behavior.contains(.canJoinAllSpaces), "\(behavior.rawValue)")
        XCTAssertTrue(behavior.contains(.fullScreenAuxiliary))
    }

    func testResizeToResizesThePanel() async throws {
        let tab = await makeTab()
        _ = try await requestWindow(tab)

        _ = try await tab.wkWebView.evaluateJavaScript("window.__pip.resizeTo(320, 400); true")

        let resized = await pollUntil(timeout: 5) { self.panel?.frame.size == NSSize(width: 320, height: 400) }
        XCTAssertTrue(resized, "\(String(describing: panel?.frame.size))")
    }

    func testAPageWithoutAGestureIsRefused() async throws {
        let tab = await makeTab()

        WebViewPrivateAccessors(tab.wkWebView).evaluateWithoutUserGesture(
            "documentPictureInPicture.requestWindow({ width: 300, height: 300 }).catch(e => { window.refused = e.name; })")

        let refused = await pollUntil(timeout: 5) {
            (try? await tab.wkWebView.evaluateJavaScript("window.refused")) as? String == "NotAllowedError"
        }
        XCTAssertTrue(refused, "only Lilo's automatic opening needs no gesture: a page never opens a window over everything on its own")
        XCTAssertNil(controller.webView)
    }

    func testTheWindowSizeIsCappedToHalfTheScreen() async throws {
        let tab = await makeTab()
        _ = try await requestWindow(tab, width: 5000, height: 5000)
        let panel = try XCTUnwrap(panel)
        panel.alphaValue = 0
        let visible = try XCTUnwrap(panel.screen?.visibleFrame)
        XCTAssertLessThanOrEqual(panel.frame.width, visible.width / 2)
        XCTAssertLessThanOrEqual(panel.frame.height, visible.height / 2)

        _ = try await tab.wkWebView.evaluateJavaScript("window.__pip.resizeTo(5000, 5000); true")
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertLessThanOrEqual(panel.frame.width, visible.width / 2)
        XCTAssertLessThanOrEqual(panel.frame.height, visible.height / 2)
    }

    func testThePiPWindowCannotLoadAnotherSite() async throws {
        let tab = await makeTab()
        _ = try await requestWindow(tab)
        let popup = try XCTUnwrap(controller.webView)

        _ = try await tab.wkWebView.evaluateJavaScript("window.__pip.location = 'https://example.org/'; true")
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertNotEqual(popup.url?.host, "example.org", "the page fills its PiP window, it never shows another site in it")
    }

    func testAPendingRequestDoesNotOutliveANavigation() async throws {
        let tab = await makeTab()
        XCTAssertTrue(controller.prepare(tab, size: NSSize(width: 300, height: 300), userActivated: true, automatic: false))

        tab.wkWebView.loadHTMLString("<p>next</p>", baseURL: URL(string: "https://example.org/"))
        _ = await pollUntil(timeout: 5) { (try? await tab.wkWebView.evaluateJavaScript("document.body?.textContent === 'next'")) as? Bool == true }

        XCTAssertNil(tab.pendingDocumentPiPSize)
        XCTAssertFalse(tab.wkWebView.configuration.preferences.javaScriptCanOpenWindowsAutomatically, "the next page gets the popup blocker back")
    }

    func testOnlyABlankMainFrameOpenTakesThePendingRequest() async throws {
        let tab = await makeTab()
        XCTAssertTrue(controller.prepare(tab, size: NSSize(width: 300, height: 300), userActivated: true, automatic: false))

        _ = try await tab.wkWebView.evaluateJavaScript("window.open('https://example.org/ad', '_blank'); true")
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertNil(controller.webView, "a link or another frame's popup never lands in the PiP window")
    }

    func testClosingFromLiloFiresPagehideInThePage() async throws {
        let tab = await makeTab()
        _ = try await requestWindow(tab)
        _ = try await tab.wkWebView.evaluateJavaScript("window.__pip.addEventListener('pagehide', () => { window.__hid = true; }); true")

        controller.close()

        let hid = await pollUntil(timeout: 5) {
            (try? await tab.wkWebView.evaluateJavaScript("window.__hid === true && documentPictureInPicture.window === null")) as? Bool == true
        }
        XCTAssertTrue(hid)
        XCTAssertNil(controller.webView)
    }

    func testThePageClosingThePopupClosesThePanel() async throws {
        let tab = await makeTab()
        _ = try await requestWindow(tab)
        let panel = try XCTUnwrap(panel)
        var closedFor: UUID?
        controller.onClosed = { id, _ in closedFor = id }

        _ = try await tab.wkWebView.evaluateJavaScript("window.__pip.close(); true")

        let closed = await pollUntil(timeout: 5) { self.controller.webView == nil }
        XCTAssertTrue(closed)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(closedFor, tab.id)
    }

    func testOpenerNavigationClosesThePiP() async throws {
        let tab = await makeTab()
        _ = try await requestWindow(tab)

        tab.wkWebView.loadHTMLString("<p>elsewhere</p>", baseURL: URL(string: "https://example.org/"))

        let closed = await pollUntil(timeout: 5) { self.controller.webView == nil }
        XCTAssertTrue(closed, "a PiP window never outlives the page that opened it")
    }

    func testOpenerTeardownClosesThePiP() async throws {
        let tab = await makeTab()
        _ = try await requestWindow(tab)

        tab.teardown()

        XCTAssertNil(controller.webView)
    }

    func testAPrivateTabPopupKeepsTheNonPersistentDataStore() async throws {
        let tab = await makeTab(persistent: false)

        _ = try await requestWindow(tab)

        let popup = try XCTUnwrap(controller.webView)
        XCTAssertFalse(popup.configuration.websiteDataStore.isPersistent)
    }

    func testACrashedOpenerClosesItsPiP() async throws {
        let tab = await makeTab()
        _ = try await requestWindow(tab)

        tab.webViewWebContentProcessDidTerminate(tab.wkWebView)

        let closed = await pollUntil(timeout: 5) { self.controller.webView == nil }
        XCTAssertTrue(closed, "a PiP window of a dead page would stay blank over everything")
    }

    func testTheRememberedCornerBelongsToTheDisplayNotItsModelName() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let number = try XCTUnwrap(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
        let uuid = try XCTUnwrap(CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue())
        let identifier = try XCTUnwrap(CFUUIDCreateString(nil, uuid) as String?)

        XCTAssertEqual(DocumentPiPController.frameKey(for: screen), "LiloDocumentPiPFrame." + identifier, "two monitors of one model are two displays")
    }

    func testAgentTabsAreRefused() async throws {
        let tab = await makeTab()
        tab.isAgentControlled = true

        let state = try await requestWindow(tab)

        XCTAssertEqual(state, "NotAllowedError")
        XCTAssertNil(controller.webView)
    }

    // MARK: - In a browser window

    private func makeWindowTab(_ html: String) async throws -> (TemporaryBrowserContext, MainWindowController, WKWebViewTab) {
        let browserContext = try await TemporaryBrowserContext()
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "Call", profileId: profileId)
        let window = makeTestWindow(context, showing: space.id)
        window.setupTabDock()
        let call = try XCTUnwrap(window.createTabStateFirst(url: nil))
        let engine = try XCTUnwrap(window.tabManager.engineTab(for: call.id))
        // As setupBridgeEarly wires it for every window.
        context.engineFactory.documentPiPHandler = { [weak context] webView, size, activated in
            context.map { MainWindowController.prepareDocumentPiP(in: $0, webView: webView, size: size, userActivated: activated) } ?? false
        }
        engine.wkWebView.loadHTMLString(html + "<p>call</p>", baseURL: URL(string: "https://call.example/"))
        _ = await pollUntil(timeout: 5) { (try? await engine.wkWebView.evaluateJavaScript("document.body?.textContent === 'call'")) as? Bool == true }
        addTeardownBlock { @MainActor in
            window.documentPiP.close()
            browserContext.tearDown()
        }
        return (browserContext, window, engine)
    }

    func testACallTabParkedByASpaceSwitchCanStillAnswerTheAutomaticOpening() async throws {
        let (browserContext, window, engine) = try await makeWindowTab("")
        let profileId = try XCTUnwrap(window.tabManager.profileId)
        let other = try browserContext.context.spaceManager.createSpace(name: "Other", profileId: profileId)
        window.switchToSpace(other.id)
        XCTAssertNil(browserContext.context.windows.windowAndEngine(for: engine.wkWebView), "parked: no window shows it")
        window.awaitingDocumentPiP = engine

        let allowed = MainWindowController.prepareDocumentPiP(
            in: browserContext.context, webView: engine.wkWebView, size: NSSize(width: 300, height: 300), userActivated: false)

        XCTAssertTrue(allowed, "a space switch parks the call tab before its page answers")
        XCTAssertEqual(engine.pendingDocumentPiPSize, NSSize(width: 300, height: 300))
    }

    func testReturningToTheTabClosesAnAutoEnteredPiPOnly() async throws {
        let (_, window, engine) = try await makeWindowTab("")
        _ = window.documentPiP.open(configuration: WKWebViewConfiguration(), size: NSSize(width: 300, height: 300), opener: engine)
        window.documentPiP.wasAutoEntered = true

        window.showContentView(for: engine)
        XCTAssertNil(window.documentPiP.webView, "Lilo opened it on leaving the tab: coming back closes it")

        let pip = window.documentPiP.open(configuration: WKWebViewConfiguration(), size: NSSize(width: 300, height: 300), opener: engine)
        window.showContentView(for: engine)
        XCTAssertTrue(window.documentPiP.webView === pip, "the page opened it: it stays")
        XCTAssertTrue(pip.window is NSPanel, "beside its own tab, it floats")
    }

    func testAutoEnterOpensThePageWindowAndMarksItAutomatic() async throws {
        let (_, window, engine) = try await makeWindowTab("""
        <script>
        navigator.mediaSession.setActionHandler('enterpictureinpicture', () => documentPictureInPicture.requestWindow({ width: 300, height: 300 }));
        </script>
        """)
        engine.callControls.hasPictureInPictureAction = true

        window.autoEnterDocumentPiP(engine)

        let opened = await pollUntil(timeout: 5) { window.documentPiP.webView != nil }
        XCTAssertTrue(opened)
        XCTAssertTrue(window.documentPiP.wasAutoEntered)
        XCTAssertNil(window.awaitingDocumentPiP)
    }

    func testAPageAnsweringAfterTheUserCameBackOpensNothing() async throws {
        let (_, window, engine) = try await makeWindowTab("""
        <script>
        navigator.mediaSession.setActionHandler('enterpictureinpicture', () => setTimeout(() => {
          documentPictureInPicture.requestWindow({ width: 300, height: 300 }).catch(e => { window.late = e.name; });
        }, 300));
        </script>
        """)
        engine.callControls.hasPictureInPictureAction = true

        window.autoEnterDocumentPiP(engine)
        window.showContentView(for: engine)

        let answered = await pollUntil(timeout: 5) { (try? await engine.wkWebView.evaluateJavaScript("window.late")) as? String == "NotAllowedError" }
        XCTAssertTrue(answered, "the user is back on the call: a late answer opens no window over it")
        XCTAssertNil(window.documentPiP.webView)
    }

    func testNoWindowWithinTheDelayStopsWaiting() async throws {
        let (_, window, engine) = try await makeWindowTab("""
        <script>navigator.mediaSession.setActionHandler('enterpictureinpicture', () => {});</script>
        """)
        engine.callControls.hasPictureInPictureAction = true

        window.autoEnterDocumentPiP(engine)
        XCTAssertTrue(window.awaitingDocumentPiP === engine)

        let gaveUp = await pollUntil(timeout: MainWindowController.documentPiPFallbackDelay + 2) { window.awaitingDocumentPiP == nil }
        XCTAssertTrue(gaveUp, "after the delay Lilo falls back to the whole page")
        XCTAssertNil(window.documentPiP.webView)
    }

    // MARK: - Placement and controls

    func testSnapPicksTheNearestCorner() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)

        let bottomRight = DocumentPiPController.snappedFrame(NSRect(x: 1200, y: 40, width: 200, height: 120), in: visible)
        let topLeft = DocumentPiPController.snappedFrame(NSRect(x: 40, y: 700, width: 200, height: 120), in: visible)

        XCTAssertEqual(bottomRight, NSRect(x: 1224, y: 16, width: 200, height: 120))
        XCTAssertEqual(topLeft, NSRect(x: 16, y: 764, width: 200, height: 120))
    }

    func testSnapKeepsTheFrameInsideTheScreen() {
        let visible = NSRect(x: 0, y: 25, width: 1440, height: 875)

        let snapped = DocumentPiPController.snappedFrame(NSRect(x: 1400, y: 10, width: 300, height: 200), in: visible)

        XCTAssertTrue(visible.contains(snapped), "\(snapped)")
    }

    func testTheFrameIsRestoredPerScreen() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)
        let key = DocumentPiPController.frameKey(for: screen)
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let tab = await makeTab()
        _ = try await requestWindow(tab, width: 300, height: 300)
        let panel = try XCTUnwrap(panel)
        panel.alphaValue = 0
        let visible = screen.visibleFrame
        XCTAssertEqual(panel.frame.maxX, visible.maxX - 16, "first time: bottom right")
        XCTAssertEqual(panel.frame.minY, visible.minY + 16)

        panel.setFrameOrigin(NSPoint(x: visible.minX + 40, y: visible.maxY - 340))
        controller.endMove()
        controller.close()
        _ = try await requestWindow(tab, width: 300, height: 300)

        let reopened = try XCTUnwrap(self.panel)
        XCTAssertEqual(reopened.frame.minX, visible.minX + 16, "back where the user left it, on this screen")
        XCTAssertEqual(reopened.frame.maxY, visible.maxY - 16)
    }

    func testReturnToTabClosesThePiPAndActivatesTheOpener() async throws {
        let (_, window, engine) = try await makeWindowTab("")
        let opener = try XCTUnwrap(window.tabManager.tab(for: engine.id)?.id)
        _ = try XCTUnwrap(window.createTabStateFirst(url: nil))
        XCTAssertNotEqual(window.tabManager.activeOpenTabId, opener)
        _ = window.documentPiP.open(configuration: WKWebViewConfiguration(), size: NSSize(width: 300, height: 300), opener: engine)

        window.documentPiP.returnToTab()

        XCTAssertNil(window.documentPiP.webView)
        XCTAssertEqual(window.tabManager.activeOpenTabId, opener)
    }
}
