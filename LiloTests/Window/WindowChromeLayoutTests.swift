import AppKit
import XCTest
@testable import Lilo

/// The sidebar gives way before the content gets too narrow to use, and full screen leaves the chrome uncovered.
@MainActor
final class WindowChromeLayoutTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var savedDefaults: [String: Any?] = [:]

    override func setUp() async throws {
        try await super.setUp()
        for key in ["cachedSidebarWidth", "cachedSidebarVisible", "cachedToolbarVisible", "cachedTabPosition", "cachedAddressPlacement"] { savedDefaults[key] = UserDefaults.lilo.object(forKey: key) }
        browserContext = try await TemporaryBrowserContext()
    }

    override func tearDown() {
        for (key, value) in savedDefaults { UserDefaults.lilo.set(value, forKey: key) }
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    func testAWideSidebarNarrowsInTheSmallestWindowAndComesBack() throws {
        let context = browserContext.context
        let space = try context.spaceManager.createSpace(name: "S", profileId: try context.profileManager.createProfile(name: "P").id)
        let window = makeTestWindow(context, showing: space.id)
        let nsWindow = try XCTUnwrap(window.window)
        nsWindow.setContentSize(NSSize(width: 1200, height: 800))
        window.updateSidebarWidth(480)
        window.pendingSidebarWidthPersistWork?.cancel()
        XCTAssertEqual(window.sidebarWidth, 480)

        nsWindow.setContentSize(nsWindow.minSize)

        XCTAssertEqual(window.contentFrameRect().width, MainWindowController.minimumContentWidth, "the content keeps room")
        XCTAssertEqual(window.contentContainerView.frame, window.contentFrameRect())
        nsWindow.setContentSize(NSSize(width: 1200, height: 800))
        XCTAssertEqual(window.sidebarWidth, 480, "its width once there is room")
    }

    func testRightPositionPutsTheContentLeftOfTheSidebar() throws {
        let window = try makeSizedWindow()
        window.updateSidebarWidth(300)
        window.pendingSidebarWidthPersistWork?.cancel()

        layOut(window, .right)

        XCTAssertEqual(window.contentFrameRect(), NSRect(x: 8, y: 8, width: 1200 - 300 - 16, height: 800 - 40 - 8))
        XCTAssertEqual(window.contentContainerView.frame, window.contentFrameRect())
    }

    func testTopStripAndBottomDockReserveTheirHeight() throws {
        let window = try makeSizedWindow()

        layOut(window, .top)
        XCTAssertEqual(window.contentFrameRect(), NSRect(x: 8, y: 8, width: 1200 - 16, height: 800 - 40 - 8))

        layOut(window, .top, address: .page)
        XCTAssertEqual(window.contentFrameRect().height, 800 - 40 - 40 - 8, "the address row sits under the strip")

        layOut(window, .bottom)
        XCTAssertEqual(window.contentFrameRect(), NSRect(x: 8, y: 72, width: 1200 - 16, height: 800 - 72 - 40))
    }

    func testHidingTheAddressReclaimsItsRowButKeepsNavigation() throws {
        let window = try makeSizedWindow()
        for position in TabPosition.allCases {
            layOut(window, position, address: .hidden)
            XCTAssertEqual(window.tabLayout.address, .hidden)
            XCTAssertEqual(window.contentEdges().top, position == .left ? 8 : 40, "\(position)")
        }
    }

    func testTheRightSidebarNarrowsLikeTheLeftOne() throws {
        let window = try makeSizedWindow()
        let nsWindow = try XCTUnwrap(window.window)
        window.updateSidebarWidth(480)
        window.pendingSidebarWidthPersistWork?.cancel()
        layOut(window, .right)

        nsWindow.setContentSize(nsWindow.minSize)

        XCTAssertEqual(window.contentFrameRect().width, MainWindowController.minimumContentWidth, "the content keeps room")
        XCTAssertEqual(window.contentContainerView.frame, window.contentFrameRect())
        nsWindow.setContentSize(NSSize(width: 1200, height: 800))
        XCTAssertEqual(window.sidebarWidth, 480, "its width once there is room")
    }

    func testHiddenTabsGiveThePageEveryEdge() throws {
        let window = try makeSizedWindow()
        window.toggleSidebar()
        for position in TabPosition.allCases {
            layOut(window, position)
            XCTAssertEqual(window.contentEdges(), .uniform(8), "\(position)")
        }
    }

    func testTheAddressToolbarHidesApartFromTheTabs() throws {
        let window = try makeSizedWindow()
        layOut(window, .left, address: .page)
        let sidebar = window.contentEdges().left

        window.toggleToolbar()
        XCTAssertEqual(window.contentEdges(), ContentEdges(left: sidebar, right: 8, top: 8, bottom: 8), "the sidebar stays")
        XCTAssertEqual(window.window?.toolbarStyle, .unified, "the lights go back to the sidebar's 52pt header")
        window.toggleToolbar()
        window.toggleSidebar()
        XCTAssertEqual(window.contentEdges(), ContentEdges(left: 8, right: 8, top: 40, bottom: 8), "the toolbar stays")
        XCTAssertTrue(window.areTrafficLightsVisible(), "on the toolbar's line")

        layOut(window, .top, address: .page)
        XCTAssertEqual(window.contentEdges().top, 40, "the address row without the strip")
        window.toggleSidebar()
        window.toggleToolbar()
        XCTAssertEqual(window.contentEdges().top, 40, "the strip without the address row")
        window.toggleToolbar()
    }

    func testTheTabsOwnToolbarGoesWithThem() throws {
        let window = try makeSizedWindow()
        for position in [TabPosition.right, .bottom] {
            layOut(window, position, address: .page)
            let edges = window.contentEdges()
            window.toggleToolbar()
            XCTAssertTrue(window.toolbarVisible, "\(position): it holds the traffic lights")
            XCTAssertEqual(window.contentEdges(), edges, "\(position)")
        }
    }

    func testMovingToAnAddressToolbarShowsIt() throws {
        let window = try makeSizedWindow()
        layOut(window, .left, address: .page)
        window.toggleToolbar()

        window.applyTabLayout(.default, animated: false)
        window.applyTabLayout(TabLayout(position: .left, address: .page), animated: false)

        XCTAssertTrue(window.toolbarVisible)
        XCTAssertEqual(window.contentEdges().top, 40)
    }

    func testFullScreenKeepsTheToolbarRow() throws {
        let window = try makeSizedWindow()
        layOut(window, .bottom)
        let edges = window.contentEdges()

        window.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification))

        XCTAssertEqual(window.contentEdges(), edges, "navigation stays reachable over the page")
    }

    func testTheLightsShareTheLineOfAToolbarOrStrip() throws {
        let window = try makeSizedWindow()
        XCTAssertEqual(window.window?.toolbarStyle, .unified, "today's left layout keeps its 52pt header")

        window.applyTabLayout(TabLayout(position: .right, storedAddress: nil), animated: false)
        XCTAssertEqual(window.window?.toolbarStyle, .unifiedCompact, "centered on the 40pt page toolbar")

        window.applyTabLayout(.default, animated: false)
        XCTAssertEqual(window.window?.toolbarStyle, .unified)
    }

    func testSettingThePositionMovesEveryWindow() async throws {
        let first = try makeSizedWindow()
        let second = try makeSizedWindow()
        first.setupBridgeLate()
        let handler = try XCTUnwrap(first.bridgeRouter.handlers["setSetting"])

        _ = await handler.handle(message: try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "setSetting", "payload": ["key": "tabPosition", "value": "bottom"]
        ])))

        for window in [first, second] {
            XCTAssertEqual(window.tabLayout, TabLayout(position: .bottom, address: .page))
            XCTAssertEqual(window.contentFrameRect().minY, 72, "the page sits above the dock")
        }
        XCTAssertEqual(TabLayout.cached.position, .bottom, "the next launch paints it first")
    }

    func testBootstrapScriptCarriesTheCachedLayout() {
        let script = MainWindowController.buildBootstrapScript(
            sidebarWidth: 260,
            windowBackgroundColor: "",
            tabLayout: TabLayout(position: .right, address: .page)
        )

        XCTAssertTrue(script.source.contains("root.dataset.tabPosition = 'right'"))
        XCTAssertTrue(script.source.contains("root.dataset.address = 'page'"))
    }

    func testTheLightsStayHiddenWhileTheTabsFloatInFromTheRightOrBottom() throws {
        let window = try makeSizedWindow()
        window.toggleSidebar()
        for position in TabPosition.allCases {
            layOut(window, position)
            window.handleSidebarOverlay(visible: true)
            XCTAssertEqual(window.areTrafficLightsVisible(), position == .left || position == .top, "\(position): the overlay covers the lights' corner only on the left and top")
            window.handleSidebarOverlay(visible: false)
        }
    }

    func testAnAnimatedSwitchNeverUncoversThePage() throws {
        let window = try makeSizedWindow()
        window.contentContainerView.wantsLayer = true
        // The animated path runs only with the native frame curtain in place.
        window.windowFrameView = WindowFrameView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), edges: window.contentEdges())
        layOut(window, .top)

        window.applyTabLayout(TabLayout(position: .left, storedAddress: nil), animated: true)

        let target = window.contentFrameRect()
        let frame = window.contentContainerView.frame
        XCTAssertGreaterThanOrEqual(frame.width, target.width, "wide enough for the new hole while it slides")
        XCTAssertGreaterThanOrEqual(frame.height, target.height, "tall enough for the new hole while it slides")
    }

    private func makeSizedWindow() throws -> MainWindowController {
        let context = browserContext.context
        let space = try context.spaceManager.createSpace(name: "S", profileId: try context.profileManager.createProfile(name: "P").id)
        let window = makeTestWindow(context, showing: space.id)
        try XCTUnwrap(window.window).setContentSize(NSSize(width: 1200, height: 800))
        return window
    }

    private func layOut(_ window: MainWindowController, _ position: TabPosition, address: AddressPlacement? = nil) {
        window.tabLayout = TabLayout(position: position, storedAddress: address?.rawValue)
        window.applySidebarLayout(animated: false)
    }

    func testFullScreenLeavesTheTopOfTheChromeUncovered() throws {
        let controller = MainWindowController(context: browserContext.context)
        let nsWindow = try XCTUnwrap(controller.window)
        let proposed: NSApplication.PresentationOptions = [.fullScreen, .autoHideMenuBar, .autoHideDock]

        let options = controller.window(nsWindow, willUseFullScreenPresentationOptions: proposed)

        XCTAssertTrue(options.isSuperset(of: proposed))
        XCTAssertTrue(options.contains(.autoHideToolbar), "the toolbar comes down with the menu bar, over the sidebar header otherwise")

        // AppKit hands the revealed title bar's height to the web view under it; WebKit would paint a pocket that tall.
        let overlay = controller.chromeWebView
        overlay.setFullScreenTitlebarOverlayHeight(66)
        let key = "fullScreenTitlebarOverlayHeight"
        if overlay.responds(to: NSSelectorFromString(key)) {
            XCTAssertEqual(overlay.value(forKey: key) as? CGFloat, 0)
        }
    }
}
