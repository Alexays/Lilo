import AppKit
import XCTest
@testable import Lilo

@MainActor
final class TrafficLightAnimatorTests: XCTestCase {
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

    private func closeButtonCenterFromTop(_ window: NSWindow) throws -> NSPoint {
        let button = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let frame = button.convert(button.bounds, to: nil)
        return NSPoint(x: frame.midX, y: window.frame.height - frame.midY)
    }

    func testTrafficLightsStayCenteredInTheHeaderWhenTheTitleChanges() throws {
        let window = try XCTUnwrap(MainWindowController(context: browserContext.context).window)
        let centered = try closeButtonCenterFromTop(window)
        XCTAssertEqual(centered.y, 26, accuracy: 0.5, "the middle of the 52pt chrome header")

        // A terminal program animates its title (a spinner), which the window title follows.
        for title in ["◐ agent", "◓ agent", "◑ agent"] {
            window.title = title
            XCTAssertEqual(try closeButtonCenterFromTop(window), centered)
        }
    }

    func testCollapsedSidebarHidesTheTrafficLightsAndShowingItBringsThemBack() throws {
        let controller = MainWindowController(context: browserContext.context)
        let buttons = try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map {
            try XCTUnwrap(controller.window?.standardWindowButton($0))
        }

        controller.sidebarVisible = false
        controller.syncTrafficLights(animated: false)
        XCTAssertTrue(buttons.allSatisfy(\.isHidden), "a transparent button would still take clicks")

        controller.sidebarOverlayVisible = true
        controller.syncTrafficLights(animated: false)
        XCTAssertTrue(buttons.allSatisfy { !$0.isHidden && $0.alphaValue == 1 })
    }

    func testAHiddenSidebarStaysHiddenAfterRelaunch() throws {
        let keys = ["cachedSidebarVisible", "cachedSidebarWidth"]
        let saved = keys.map { UserDefaults.lilo.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.lilo.set(value, forKey: key) } }
        keys.forEach(UserDefaults.lilo.removeObject(forKey:))
        browserContext.context.settingsStore.sidebarVisible = false

        let controller = MainWindowController(context: browserContext.context)
        // Startup is skipped under XCTest: its two sidebar steps run by hand around the database.
        controller.contentContainerView = NSView()
        controller.window?.contentView?.addSubview(controller.contentContainerView)
        controller.restoreWindowChromeState()
        controller.reconcileBootstrapCacheWithDB()

        XCTAssertFalse(controller.sidebarVisible)
        XCTAssertEqual(controller.sidebarWidth, 0)
        XCTAssertEqual(controller.contentContainerView.frame.minX, MainWindowController.contentInset)
        XCTAssertEqual(UserDefaults.lilo.object(forKey: "cachedSidebarVisible") as? Bool, false, "the next launch lays out hidden from the start")
    }
}
