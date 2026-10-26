import AppKit
import XCTest
@testable import Lilo

@MainActor
final class ContentContainerViewTests: XCTestCase {
    private final class Page: NSView {
        override func isAccessibilityElement() -> Bool { true }
    }

    private func page(_ frame: NSRect, _ name: String) -> NSView {
        let view = Page(frame: frame)
        view.setAccessibilityLabel(name)
        return view
    }

    private func names(_ container: ContentContainerView) -> [String] {
        // AppKit only builds a view's accessibility children once it sits in a window.
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(container)
        defer { window.close() }
        return (container.accessibilityChildren() ?? []).compactMap { ($0 as? NSView)?.accessibilityLabel() }
    }

    func testAPageCoveredByTheShownOneIsLeftOutOfTheAccessibilityTree() {
        let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
        let container = ContentContainerView(frame: bounds)
        container.addSubview(page(bounds, "shared tab"))
        container.addSubview(page(bounds, "shown tab"))

        XCTAssertEqual(names(container), ["shown tab"])
    }

    func testSplitPanesSideBySideAreAllExposed() {
        let container = ContentContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.addSubview(page(NSRect(x: 0, y: 0, width: 400, height: 600), "left"))
        container.addSubview(page(NSRect(x: 400, y: 0, width: 400, height: 600), "right"))

        XCTAssertEqual(Set(names(container)), ["left", "right"])
    }

    func testAnAgentPageRunningPastTheContainerIsStillCovered() {
        let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
        let container = ContentContainerView(frame: bounds)
        container.addSubview(page(NSRect(x: 0, y: bounds.maxY - 800, width: 1280, height: 800), "agent tab"))
        container.addSubview(page(bounds, "shown tab"))

        XCTAssertEqual(names(container), ["shown tab"])
    }

    func testAShownPageSmallerThanTheContainerHidesThePagesBelowIt() {
        let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
        let container = ContentContainerView(frame: bounds)
        let agentPage = page(NSRect(x: 0, y: bounds.maxY - 800, width: 1280, height: 800), "agent tab")
        let shown = page(NSRect(x: 205, y: 0, width: 390, height: 600), "shown tab")
        container.addSubview(agentPage)
        container.addSubview(shown)

        container.updateStage(under: shown, fixedSize: true)

        let stage = container.subviews.first { $0 !== agentPage && $0 !== shown }
        XCTAssertEqual(container.subviews.count, 3)
        XCTAssertTrue(container.subviews[1] === stage, "between the agent page and the shown one")
        XCTAssertEqual(stage?.frame, bounds)
        XCTAssertNotNil(stage?.layer?.backgroundColor, "opaque")
        XCTAssertEqual(names(container), ["shown tab"])
    }

    func testTheStageGoesWhenTheShownPageFillsTheContainerAgain() {
        let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
        let container = ContentContainerView(frame: bounds)
        let shown = page(NSRect(x: 205, y: 0, width: 390, height: 600), "shown tab")
        container.addSubview(page(bounds, "agent tab"))
        container.addSubview(shown)
        container.updateStage(under: shown, fixedSize: true)

        shown.frame = bounds
        container.updateStage(under: shown, fixedSize: true)
        XCTAssertEqual(container.subviews.count, 2)

        shown.frame = NSRect(x: 205, y: 0, width: 390, height: 600)
        container.updateStage(under: shown, fixedSize: false)
        XCTAssertEqual(container.subviews.count, 2, "a page without a fixed size, a split pane, needs none")
    }

    func testAFixedSizePageBelowTheShownOneLeavesTheStageAlone() {
        let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
        let container = ContentContainerView(frame: bounds)
        let agentPage = page(NSRect(x: 0, y: 0, width: 390, height: 600), "agent tab")
        container.addSubview(agentPage)
        container.addSubview(page(bounds, "shown tab"))

        container.updateStage(under: agentPage, fixedSize: true)

        XCTAssertEqual(container.subviews.count, 2)
    }

    func testThePanesOfASplitCoverThePageBelowThemTogether() {
        let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
        let container = ContentContainerView(frame: bounds)
        container.addSubview(page(bounds, "agent tab"))
        container.addSubview(page(NSRect(x: 0, y: 0, width: 400, height: 600), "left"))
        container.addSubview(page(NSRect(x: 400, y: 0, width: 400, height: 600), "right"))

        XCTAssertEqual(Set(names(container)), ["left", "right"])
    }

    func testTheSplitFocusRingHidesNoPane() {
        let container = ContentContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.addSubview(page(NSRect(x: 0, y: 0, width: 400, height: 600), "left"))
        container.addSubview(page(NSRect(x: 400, y: 0, width: 400, height: 600), "right"))
        container.addSubview(SplitFocusRingView(frame: NSRect(x: 400, y: 0, width: 400, height: 600)))

        XCTAssertEqual(Set(names(container)), ["left", "right"])
    }

    func testAHiddenPageDoesNotHideTheOneBelowIt() {
        let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
        let container = ContentContainerView(frame: bounds)
        container.addSubview(page(bounds, "shown tab"))
        let hidden = page(bounds, "hidden tab")
        hidden.isHidden = true
        container.addSubview(hidden)

        XCTAssertEqual(names(container), ["shown tab"])
    }
}
