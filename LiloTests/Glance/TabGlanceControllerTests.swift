import XCTest
import WebKit
@testable import Lilo

@MainActor
final class TabGlanceControllerTests: XCTestCase {

    private func makeHost() -> (contentView: NSView, chromeView: NSView) {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        let chromeView = NSView(frame: contentView.bounds)
        contentView.addSubview(chromeView)
        return (contentView, chromeView)
    }

    func testThePageFillsTheCardsSlotAndLeavesWithTheCard() {
        let (contentView, chromeView) = makeHost()
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let glance = TabGlanceController()

        glance.show(engine, in: contentView, above: chromeView)
        // Chrome viewport coordinates, top-left origin.
        glance.zonesChanged([TabGlanceController.zoneId: NSRect(x: 280, y: 100, width: 308, height: 362)])

        XCTAssertEqual(glance.engineId, engine.id)
        XCTAssertEqual(engine.view.superview?.frame, NSRect(x: 280, y: 338, width: 308, height: 362))
        XCTAssertEqual(engine.view.frame.size, NSSize(width: 308, height: 362))
        XCTAssertTrue(contentView.subviews.last === engine.view.superview, "above the chrome, which draws the card around it")

        glance.end()
        XCTAssertNil(glance.engineId)
        XCTAssertNil(engine.view.superview)
    }

    func testThePageStaysZoomedOutThroughANavigationAndGetsItsZoomBack() {
        let (contentView, chromeView) = makeHost()
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let glance = TabGlanceController()
        engine.setPageZoom(1.25)

        glance.show(engine, in: contentView, above: chromeView)
        XCTAssertEqual(engine.pageZoom, 1.25 * TabGlanceController.zoomFactor, accuracy: 0.0001)

        // A committed navigation gives the page its site's zoom again.
        engine.setPageZoom(1.5)
        XCTAssertEqual(engine.pageZoom, 1.5 * TabGlanceController.zoomFactor, accuracy: 0.0001)

        glance.end()
        XCTAssertEqual(engine.pageZoom, 1.5, accuracy: 0.0001)
    }

    func testAnUntouchedZoomComesBackExactly() {
        let (contentView, chromeView) = makeHost()
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let glance = TabGlanceController()
        engine.setPageZoom(1.1)

        glance.show(engine, in: contentView, above: chromeView)
        glance.end()

        XCTAssertEqual(engine.pageZoom, 1.1)
    }

    func testAViewAnotherWindowTookStaysThereWhenTheCardEnds() {
        let (contentView, chromeView) = makeHost()
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let glance = TabGlanceController()
        let otherWindowContent = NSView()

        glance.show(engine, in: contentView, above: chromeView)
        otherWindowContent.addSubview(engine.view)
        glance.end()
        engine.setPageZoom(1.25)

        XCTAssertTrue(engine.view.superview === otherWindowContent)
        XCTAssertEqual(engine.pageZoom, 1.25, accuracy: 0.0001, "the other window's zoom, no longer scaled for the card")
    }
}
