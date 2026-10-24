import AppKit
import XCTest
@testable import Lilo

@MainActor
final class MainWindowControllerFocusTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
    }

    override func tearDown() {
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    /// Same harness as ChromeGlobalEventRoutingTests: real controller,
    /// wired bridge, chrome view installed + content sink registered.
    private func makeController() -> (MainWindowController, NSView) {
        let controller = MainWindowController(context: browserContext.context)
        controller.bridgeRouter = BridgeRouter(chromeWebView: controller.chromeWebView)
        let sink = TestFocusContentView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        controller.chromeInput.router.updateContentView(sink)
        controller.chromeWebView.frame = controller.window!.contentView!.bounds
        controller.window?.contentView?.addSubview(controller.chromeWebView)
        controller.window?.contentView?.addSubview(sink)
        // Startup is skipped under XCTest, so what `showContentView` needs is wired by hand.
        controller.contentContainerView = NSView(frame: sink.frame)
        controller.window?.contentView?.addSubview(controller.contentContainerView)
        return (controller, sink)
    }

    func testFocusChromeIntentMovesOwnerToChrome() {
        let (controller, sink) = makeController()
        XCTAssertTrue(controller.window!.makeFirstResponder(sink))
        XCTAssertEqual(controller.focusOwner, .content)
        XCTAssertFalse(controller.isFirstResponderInsideChromeUI())

        controller.focusChrome()

        XCTAssertEqual(controller.focusOwner, .chrome)
        XCTAssertTrue(controller.isFirstResponderInsideChromeUI())
        XCTAssertFalse(controller.isFirstResponderInsideContentView())
    }

    func testFocusContentIntentMovesOwnerToContent() {
        let (controller, sink) = makeController()
        XCTAssertTrue(controller.window!.makeFirstResponder(controller.chromeWebView))
        XCTAssertEqual(controller.focusOwner, .chrome)

        controller.focusContent(sink)

        XCTAssertEqual(controller.focusOwner, .content)
        XCTAssertTrue(controller.isFirstResponderInsideContentView())
        XCTAssertFalse(controller.isFirstResponderInsideChromeUI())
    }

    func testContainsResponderMatchesChromeView() {
        let (controller, sink) = makeController()
        XCTAssertTrue(controller.contains(responder: controller.chromeWebView))
        XCTAssertFalse(controller.contains(responder: sink))
    }

    func testActivatingBlankTabLeavesFocusOnChrome() {
        let (controller, sink) = makeController()
        let tab = installActiveTab(on: controller, url: nil)
        XCTAssertTrue(controller.window!.makeFirstResponder(sink))

        controller.tabManager.activateTabRuntime(id: tab.id)

        XCTAssertEqual(controller.focusOwner, .chrome)
    }

    func testActivatingTabWithURLMovesFocusToContent() {
        let (controller, _) = makeController()
        let tab = installActiveTab(on: controller, url: URL(string: "https://example.com")!)
        XCTAssertTrue(controller.window!.makeFirstResponder(controller.chromeWebView))

        controller.tabManager.activateTabRuntime(id: tab.id)

        XCTAssertEqual(controller.focusOwner, .content)
    }

    func testFocusChromeIsIdempotent() {
        let (controller, _) = makeController()
        controller.focusChrome()
        XCTAssertEqual(controller.focusOwner, .chrome)
        controller.focusChrome() // no crash, stays chrome
        XCTAssertEqual(controller.focusOwner, .chrome)
    }

    /// One tab, active, in a space the manager knows about: the minimum for `activateTabRuntime`.
    private func installActiveTab(on controller: MainWindowController, url: URL?) -> Tab {
        let spaceId = UUID()
        controller.tabManager.currentSpaceId = spaceId
        let tab = controller.tabManager.prepareTabRuntime(url: url)
        let state = try! BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: tab.id,
            tabs: [tab],
            folders: [],
            treeItems: [TabTreeItem(
                spaceId: spaceId,
                kind: .tab,
                itemId: tab.id,
                parentFolderId: nil,
                section: .unpinned,
                sortOrder: 0
            )]
        )
        controller.tabManager.installSpaceTabStateForTests(SpaceTabState(state), spaceId: spaceId)
        return tab
    }
}

@MainActor
private final class TestFocusContentView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
