import XCTest
import WebKit
@testable import Lilo

@MainActor
final class TabDockControllerTests: XCTestCase {

    private func makeHost() -> (contentView: NSView, chromeView: NSView) {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        let chromeView = NSView(frame: contentView.bounds)
        contentView.addSubview(chromeView)
        return (contentView, chromeView)
    }

    /// The dock container is the controller-added sibling of the chrome view; nil while absent or hidden.
    private func visibleDockFrame(in contentView: NSView, chromeView: NSView) -> NSRect? {
        guard let container = contentView.subviews.first(where: { $0 !== chromeView }), !container.isHidden else { return nil }
        return container.frame
    }

    func testClickingTheDockFromAnotherSpaceReturnsToItsTab() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let callSpace = try context.spaceManager.createSpace(name: "Call", profileId: profileId)
        let otherSpace = try context.spaceManager.createSpace(name: "Other", profileId: profileId)
        let window = makeTestWindow(context, showing: callSpace.id)
        window.setupTabDock()
        let call = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "https://call.example/")))
        let engine = try XCTUnwrap(window.tabManager.engineTab(for: call.id))
        window.tabDock.dock(engine, logicalSize: .zero, in: window.contentContainerView, above: nil, chromeView: window.chromeWebView)
        window.switchToSpace(otherSpace.id)

        window.tabDock.onReturnToTab?(call.id)

        XCTAssertEqual(window.tabManager.currentSpaceId, callSpace.id)
        XCTAssertEqual(window.tabManager.activeOpenTabId, call.id)
        XCTAssertFalse(window.tabDock.isDocking)
    }

    func testDockPositionsContainerFromZoneRect() {
        let controller = TabDockController()
        controller.sidebarWidth = 240
        let (contentView, chromeView) = makeHost()
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        controller.dock(engine, logicalSize: NSSize(width: 1200, height: 750), in: contentView, above: nil, chromeView: chromeView)

        XCTAssertNil(visibleDockFrame(in: contentView, chromeView: chromeView))   // no slot streamed yet

        // Viewport coordinates are top-left origin: y 600 with height 150 in an 800pt chrome
        // lands at AppKit y = 800 - (600 + 150) = 50.
        controller.zonesChanged([TabDockController.zoneId: NSRect(x: 8, y: 600, width: 240, height: 150)])
        // x/width come from the sidebar column (240 + the 8pt content inset, minus the 10pt row
        // inset on each side); only the vertical band comes from the zone rect.
        XCTAssertEqual(visibleDockFrame(in: contentView, chromeView: chromeView), NSRect(x: 10, y: 50, width: 228, height: 150))
        XCTAssertTrue(controller.isDocking)
        XCTAssertEqual(controller.engineId, engine.id)
    }

    func testSlotVanishingBeforeFirstRectIsNotSlotLost() {
        let controller = TabDockController()
        controller.sidebarWidth = 240
        let (contentView, chromeView) = makeHost()
        var lost = false
        controller.onSlotLost = { _ in lost = true }
        controller.dock(WKWebViewTab(configuration: WKWebViewConfiguration()), logicalSize: NSSize(width: 1200, height: 750), in: contentView, above: nil, chromeView: chromeView)

        controller.zonesChanged([:])   // chrome has not mounted the slot yet
        XCTAssertFalse(lost)
        XCTAssertTrue(controller.isDocking)
    }

    func testSlotRemovalAfterPlacementFiresSlotLostAndUndocks() {
        let controller = TabDockController()
        controller.sidebarWidth = 240
        let (contentView, chromeView) = makeHost()
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        var lostEngine: WKWebViewTab?
        controller.onSlotLost = { lostEngine = $0 }
        controller.dock(engine, logicalSize: NSSize(width: 1200, height: 750), in: contentView, above: nil, chromeView: chromeView)
        controller.zonesChanged([TabDockController.zoneId: NSRect(x: 8, y: 600, width: 240, height: 150)])

        controller.zonesChanged([:])   // sidebar collapsed
        XCTAssertTrue(lostEngine === engine)
        XCTAssertFalse(controller.isDocking)
        XCTAssertNil(visibleDockFrame(in: contentView, chromeView: chromeView))
        XCTAssertNil(engine.view.superview)
    }

    func testUndockDetachesViewAndReturnsEngine() {
        let controller = TabDockController()
        controller.sidebarWidth = 240
        let (contentView, chromeView) = makeHost()
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        controller.dock(engine, logicalSize: NSSize(width: 1200, height: 750), in: contentView, above: nil, chromeView: chromeView)
        controller.zonesChanged([TabDockController.zoneId: NSRect(x: 8, y: 600, width: 240, height: 150)])

        let undocked = controller.undock()
        XCTAssertTrue(undocked === engine)
        XCTAssertNil(engine.view.superview)
        XCTAssertFalse(controller.isDocking)
        XCTAssertNil(controller.undock())
    }

    func testReattachRestoresAParkDetachedView() {
        let controller = TabDockController()
        controller.sidebarWidth = 240
        let (contentView, chromeView) = makeHost()
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        controller.dock(engine, logicalSize: NSSize(width: 1200, height: 750), in: contentView, above: nil, chromeView: chromeView)
        controller.zonesChanged([TabDockController.zoneId: NSRect(x: 8, y: 600, width: 240, height: 150)])

        engine.view.removeFromSuperview()   // space-switch parking detaches every engine view
        controller.reattachIfNeeded()

        XCTAssertNotNil(engine.view.superview)
        XCTAssertTrue(controller.isDocking)
        XCTAssertNotNil(visibleDockFrame(in: contentView, chromeView: chromeView))
    }

    func testEveryUndockPathReportsTheDockCleared() {
        let controller = TabDockController()
        controller.sidebarWidth = 240
        let (contentView, chromeView) = makeHost()
        var cleared = 0
        controller.onDockCleared = { cleared += 1 }
        controller.onSlotLost = { _ in }

        controller.dock(WKWebViewTab(configuration: WKWebViewConfiguration()), logicalSize: NSSize(width: 1200, height: 750), in: contentView, above: nil, chromeView: chromeView)
        controller.undock()
        XCTAssertEqual(cleared, 1)

        // A second undock with nothing docked must not re-report.
        controller.undock()
        XCTAssertEqual(cleared, 1)

        // Losing the slot clears the dock too.
        controller.dock(WKWebViewTab(configuration: WKWebViewConfiguration()), logicalSize: NSSize(width: 1200, height: 750), in: contentView, above: nil, chromeView: chromeView)
        controller.zonesChanged([TabDockController.zoneId: NSRect(x: 8, y: 600, width: 224, height: 140)])
        controller.zonesChanged([:])
        XCTAssertEqual(cleared, 2)
    }

    func testDockingASecondEngineReplacesTheFirst() {
        let controller = TabDockController()
        controller.sidebarWidth = 240
        let (contentView, chromeView) = makeHost()
        let first = WKWebViewTab(configuration: WKWebViewConfiguration())
        let second = WKWebViewTab(configuration: WKWebViewConfiguration())
        controller.dock(first, logicalSize: NSSize(width: 1200, height: 750), in: contentView, above: nil, chromeView: chromeView)
        controller.dock(second, logicalSize: NSSize(width: 1200, height: 750), in: contentView, above: nil, chromeView: chromeView)

        XCTAssertEqual(controller.engineId, second.id)
        XCTAssertNil(first.view.superview?.superview)   // first view left the dock container
    }
}
