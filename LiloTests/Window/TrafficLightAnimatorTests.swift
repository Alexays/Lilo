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

    private func closeButtonFrame(_ controller: MainWindowController, layout: TabLayout) throws -> NSRect {
        let window = try XCTUnwrap(controller.window)
        controller.tabLayout = layout
        controller.placeTrafficLights()
        let button = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let frame = button.convert(button.bounds, to: nil)
        return NSRect(x: frame.minX, y: window.frame.height - frame.maxY, width: frame.width, height: frame.height)
    }

    func testTheLightsLineUpWithTheSidebarOverItAndAreLeftToAppKitElsewhere() throws {
        let controller = MainWindowController(context: browserContext.context)
        let corner = try closeButtonFrame(controller, layout: .default)
        XCTAssertEqual(corner.midY, 22, accuracy: 0.5, "the middle of the default layout's 44pt header")
        XCTAssertEqual(corner.minX, corner.minY, accuracy: 0.5, "as far in from the left as from the top")

        let besidePageToolbar = try closeButtonFrame(controller, layout: TabLayout(position: .left, address: .page))
        XCTAssertEqual(besidePageToolbar.minX, MainWindowController.trafficLightsInset)
        XCTAssertEqual(besidePageToolbar.midY, 26, accuracy: 0.5, "on the page toolbar's line")

        let addressHidden = try closeButtonFrame(controller, layout: TabLayout(position: .left, address: .hidden))
        XCTAssertEqual(addressHidden.minX, MainWindowController.trafficLightsInset)
        XCTAssertEqual(addressHidden.midY, 26, accuracy: 0.5, "on the line of the sidebar header's buttons")

        let strip = try closeButtonFrame(controller, layout: TabLayout(position: .top, address: .page))
        XCTAssertGreaterThan(strip.minX, corner.minX)
        XCTAssertEqual(strip.midY, 26, accuracy: 0.5, "the middle of the 52pt chrome header")

        let compactBar = try closeButtonFrame(controller, layout: TabLayout(position: .bottom, address: .hidden))
        XCTAssertEqual(compactBar, corner, "the bar left without an address holds them as the corner does")

        XCTAssertEqual(try closeButtonFrame(controller, layout: .default), corner)
    }

    /// AppKit's theme frame re-lays the buttons at a smaller size during a live resize; the held
    /// frame restores the standard size along with the place, whatever AppKit's last layout did.
    func testTheHeldLightsKeepTheirStandardSizeWhenAppKitShrinksThem() throws {
        let controller = MainWindowController(context: browserContext.context)
        let window = try XCTUnwrap(controller.window)
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        controller.placeTrafficLights()
        let standard = close.frame.size
        XCTAssertGreaterThan(standard.width, 0)

        close.setFrameSize(NSSize(width: 1, height: 1))
        controller.placeTrafficLights()
        RunLoop.main.run(mode: .default, before: .now)
        XCTAssertEqual(close.frame.size, standard, "back at the standard size after AppKit's move")
    }

    func testTheLightsStayInTheAddressBarsCornerWhenTheTitleChanges() throws {
        let controller = MainWindowController(context: browserContext.context)
        let window = try XCTUnwrap(controller.window)
        let corner = try closeButtonFrame(controller, layout: .default)

        // A terminal program animates its title (a spinner), which the window title follows.
        for title in ["◐ agent", "◓ agent", "◑ agent"] {
            window.title = title
            window.layoutIfNeeded()
            RunLoop.main.run(mode: .default, before: .now)
            XCTAssertEqual(try closeButtonFrame(controller, layout: .default), corner)
        }
    }

    func testTheRailMovesTheLightsOntoTheToolbarRowPastItsColumn() throws {
        let controller = MainWindowController(context: browserContext.context)
        let layout = TabLayout(position: .left, address: .page)

        controller.sidebarVisible = false
        let hidden = try closeButtonFrame(controller, layout: layout)

        controller.sidebarVisible = true
        controller.sidebarRail = true
        XCTAssertTrue(controller.areTrafficLightsVisible(), "the page toolbar still holds them")
        let rail = try closeButtonFrame(controller, layout: layout)
        XCTAssertEqual(rail.minX, MainWindowController.sidebarRailWidth + MainWindowController.contentInset + MainWindowController.trafficLightsInset,
                       "past the rail's column, as far in as they sit over the sidebar")
        XCTAssertEqual(rail.midY, hidden.midY, "the toolbar row, not the rail")

        controller.tabLayout = .default
        XCTAssertFalse(controller.areTrafficLightsVisible(), "no toolbar row holds them, as with the sidebar hidden")
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
        browserContext.context.settingsStore!.sidebarVisible = false

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
