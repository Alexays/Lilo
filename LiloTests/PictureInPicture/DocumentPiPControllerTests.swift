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
        _ = await pollUntil(timeout: 5) { tab.wkWebView.url != nil && !tab.wkWebView.isLoading }
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
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
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
}
