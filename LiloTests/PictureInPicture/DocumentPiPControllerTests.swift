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
        factory.documentPiPHandler = { [unowned self] _, size in controller.prepare(tab, size: size) }
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

    private func requestWindow(_ tab: WKWebViewTab, width: Int = 300, height: Int = 356) async throws -> String? {
        try await tab.wkWebView.callAsyncJavaScript("""
            try { window.__pip = await documentPictureInPicture.requestWindow({ width: \(width), height: \(height) }); return 'open'; }
            catch (e) { return e.name; }
            """, contentWorld: .page) as? String
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
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces), "\(panel.collectionBehavior.rawValue) \(panel === NSApp.windows.first { $0.delegate === controller })")
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertEqual(panel.contentLayoutRect.size, NSSize(width: 300, height: 356))
        XCTAssertEqual(controller.openerId, tab.id)
    }

    func testResizeToResizesThePanel() async throws {
        let tab = await makeTab()
        _ = try await requestWindow(tab)

        _ = try await tab.wkWebView.evaluateJavaScript("window.__pip.resizeTo(320, 400); true")

        let resized = await pollUntil(timeout: 5) { self.panel?.frame.size == NSSize(width: 320, height: 400) }
        XCTAssertTrue(resized, "\(String(describing: panel?.frame.size))")
    }

    func testAPageWithoutAGestureStillOpensItsWindow() async throws {
        let tab = await makeTab()

        WebViewPrivateAccessors(tab.wkWebView).evaluateWithoutUserGesture("documentPictureInPicture.requestWindow({ width: 300, height: 300 })")

        let opened = await pollUntil(timeout: 5) { self.controller.webView != nil }
        XCTAssertTrue(opened, "the automatic opening has no user gesture")
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
        controller.onClosed = { closedFor = $0 }

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
        context.engineFactory.documentPiPHandler = { _, size in window.documentPiP.prepare(engine, size: size) }
        engine.wkWebView.loadHTMLString(html + "<p>call</p>", baseURL: URL(string: "https://call.example/"))
        _ = await pollUntil(timeout: 5) { (try? await engine.wkWebView.evaluateJavaScript("document.body?.textContent === 'call'")) as? Bool == true }
        addTeardownBlock { @MainActor in
            window.documentPiP.close()
            browserContext.tearDown()
        }
        return (browserContext, window, engine)
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
        XCTAssertNil(window.awaitingDocumentPiPId)
    }

    func testNoWindowWithinTheDelayStopsWaiting() async throws {
        let (_, window, engine) = try await makeWindowTab("""
        <script>navigator.mediaSession.setActionHandler('enterpictureinpicture', () => {});</script>
        """)
        engine.callControls.hasPictureInPictureAction = true

        window.autoEnterDocumentPiP(engine)
        XCTAssertEqual(window.awaitingDocumentPiPId, engine.id)

        let gaveUp = await pollUntil(timeout: MainWindowController.documentPiPFallbackDelay + 2) { window.awaitingDocumentPiPId == nil }
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
