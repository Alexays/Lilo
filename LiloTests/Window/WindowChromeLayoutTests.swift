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
        for key in ["cachedSidebarWidth", "cachedSidebarVisible"] { savedDefaults[key] = UserDefaults.lilo.object(forKey: key) }
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
