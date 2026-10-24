import AppKit
import WebKit
import XCTest
@testable import Lilo

/// A page dialog never waits where nobody can see it: a tab off screen leaves without a beforeunload
/// prompt, and holds its alert until the tab shows.
@MainActor
final class WKWebViewTabDialogTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var controller: MainWindowController!
    private var profileId: UUID!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        let context = browserContext.context
        profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        controller = MainWindowController(context: context)
        controller.bridgeRouter = BridgeRouter(chromeWebView: controller.chromeWebView)
        // Transparent, off screen and never key, so nothing shows to whoever runs the tests.
        let window = try XCTUnwrap(controller.window)
        window.alphaValue = 0
        window.orderFrontRegardless()
        window.setFrame(NSRect(x: -20000, y: -20000, width: 1000, height: 700), display: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 650))
        try XCTUnwrap(window.contentView).addSubview(container)
        controller.contentContainerView = container
        context.windows.add(controller)
        controller.switchToSpace(space.id)
        controller.createTabStateFirst(url: nil)
    }

    override func tearDown() {
        if let window = controller.window, let sheet = window.attachedSheet { window.endSheet(sheet) }
        controller.window?.close()
        controller = nil
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    private func load(_ html: String, in engine: WKWebViewTab) async {
        engine.wkWebView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        _ = await pollUntil { !engine.wkWebView.isLoading && engine.wkWebView.url != nil }
    }

    func testTabOfABackgroundSpaceLeavesWithoutABeforeunloadPrompt() async throws {
        let tab = try XCTUnwrap(controller.createTabStateFirst(url: nil))
        let engine = try XCTUnwrap(controller.tabManager.engineTab(for: tab.id))
        await load("<script>addEventListener('beforeunload', e => e.preventDefault())</script>", in: engine)
        // A script run by the app counts as a user gesture: WebKit asks only a page the user used.
        _ = try await engine.wkWebView.evaluateJavaScript("document.body.click(); true")
        controller.switchToSpace(try browserContext.context.spaceManager.createSpace(name: "Other", profileId: profileId).id)
        XCTAssertNil(engine.view.window)

        _ = try await engine.wkWebView.evaluateJavaScript("setTimeout(() => location.href = 'about:blank'); true")

        let left = await pollUntil { engine.wkWebView.url?.absoluteString == "about:blank" }
        XCTAssertTrue(left, "the page-initiated navigation completes")
    }

    func testAlertOfABackgroundTabWaitsForTheTabToShow() async throws {
        let window = try XCTUnwrap(controller.window)
        let tab = try XCTUnwrap(controller.createTabStateFirst(url: nil, activate: false))
        let engine = try XCTUnwrap(controller.tabManager.engineTab(for: tab.id))
        await load("<p>page</p>", in: engine)
        XCTAssertNil(engine.view.window)

        _ = try await engine.wkWebView.evaluateJavaScript("setTimeout(() => window.answered = alert('hi') ?? true); true")

        let marked = await pollUntil { self.controller.tabManager.tab(for: tab.id)?.awaitingInputSince != nil }
        XCTAssertTrue(marked, "the sidebar marks the tab as waiting for the user")
        XCTAssertNil(window.attachedSheet, "no alert opens over another tab")

        controller.activateTabStateFirst(id: tab.id)

        let shown = await pollUntil { window.attachedSheet != nil }
        XCTAssertTrue(shown, "the alert shows with its tab")
        XCTAssertNil(controller.tabManager.tab(for: tab.id)?.awaitingInputSince)
        window.endSheet(try XCTUnwrap(window.attachedSheet))
        let answered = await pollUntil { (try? await engine.wkWebView.evaluateJavaScript("window.answered === true")) as? Bool == true }
        XCTAssertTrue(answered, "the page runs on once the alert is answered")
    }
}
