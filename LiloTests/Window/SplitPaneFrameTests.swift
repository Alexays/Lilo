import AppKit
import XCTest
@testable import Lilo

/// The pure tiling behind `SplitPanesController.applyFrames`: panes and divider frames for a
/// layout inside a rectangle, whichever way the container counts y.
@MainActor
final class SplitPaneFrameTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()
    private typealias Cuts = [[Bool]: (divider: NSRect, bounds: NSRect, vertical: Bool)]

    private func tile(_ layout: SplitLayout, in rect: NSRect, flipped: Bool = false)
        -> (panes: [UUID: NSRect], cuts: Cuts) {
        var panes: [UUID: NSRect] = [:]
        var cuts = Cuts()
        SplitPanesController.frames(layout, in: rect, flipped: flipped, path: [], panes: &panes, cuts: &cuts)
        return (panes, cuts)
    }

    private func tiledArea(_ result: (panes: [UUID: NSRect], cuts: Cuts)) -> NSRect {
        result.cuts.values.reduce(result.panes.values.reduce(NSRect.null) { $0.union($1) }) { $0.union($1.divider) }
    }

    func testNeighborPaneFindsTheAbuttingPaneOnEachSide() {
        // Shares of a 2x2 grid, y counting from the top as sendPaneFrames reports.
        let frames: [UUID: NSRect] = [
            a: NSRect(x: 0, y: 0, width: 0.5, height: 0.5),
            b: NSRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
            c: NSRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        ]
        XCTAssertEqual(SplitPanesController.neighborPane(of: a, in: frames, direction: .right), b)
        XCTAssertEqual(SplitPanesController.neighborPane(of: a, in: frames, direction: .down), c)
        XCTAssertEqual(SplitPanesController.neighborPane(of: b, in: frames, direction: .left), a)
        XCTAssertEqual(SplitPanesController.neighborPane(of: b, in: frames, direction: .up), nil)
        XCTAssertEqual(SplitPanesController.neighborPane(of: c, in: frames, direction: .up), a)
    }

    func testNeighborPaneSkipsPanesThatDoNotShareTheEdge() {
        // a is a full-height left column; b and c stack on its right.
        let frames: [UUID: NSRect] = [
            a: NSRect(x: 0, y: 0, width: 0.5, height: 1),
            b: NSRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
            c: NSRect(x: 0.5, y: 0.5, width: 0.5, height: 1)
        ]
        XCTAssertEqual(SplitPanesController.neighborPane(of: a, in: frames, direction: .right), b)
        XCTAssertEqual(SplitPanesController.neighborPane(of: c, in: frames, direction: .up), b)
        XCTAssertEqual(SplitPanesController.neighborPane(of: b, in: frames, direction: .left), a)
        XCTAssertEqual(SplitPanesController.neighborPane(of: a, in: frames, direction: .up), nil)
    }

    func testASideBySideSplitLeavesTheGapToTheDivider() {
        let rect = NSRect(x: 4, y: 4, width: 400, height: 300)
        let (panes, cuts) = tile(
            .split(vertical: false, ratio: 0.25, first: .pane(tabId: a), second: .pane(tabId: b)),
            in: rect
        )
        let root: [Bool] = []
        XCTAssertEqual(panes[a], NSRect(x: 4, y: 4, width: 98, height: 300))
        XCTAssertEqual(panes[b], NSRect(x: 110, y: 4, width: 294, height: 300))
        XCTAssertEqual(cuts[root]?.divider, NSRect(x: 102, y: 4, width: 8, height: 300))
        XCTAssertEqual(cuts[root]?.bounds, rect)
        XCTAssertEqual(cuts[root]?.vertical, false)
        XCTAssertEqual(tiledArea((panes, cuts)), rect)
    }

    func testAStackedSplitKeepsFirstOnTopEitherYDirection() {
        let rect = NSRect(x: 0, y: 0, width: 300, height: 200)
        let layout = SplitLayout.split(vertical: true, ratio: 0.5, first: .pane(tabId: a), second: .pane(tabId: b))
        let unflipped = tile(layout, in: rect, flipped: false)
        let flipped = tile(layout, in: rect, flipped: true)
        // Unflipped counts y from the bottom: the top half starts at the divider's top.
        XCTAssertEqual(unflipped.panes[a], NSRect(x: 0, y: 104, width: 300, height: 96))
        XCTAssertEqual(unflipped.panes[b], NSRect(x: 0, y: 0, width: 300, height: 96))
        // Flipped, from the top: the first half takes the top, same divider position.
        XCTAssertEqual(flipped.panes[a], NSRect(x: 0, y: 0, width: 300, height: 96))
        XCTAssertEqual(flipped.panes[b], NSRect(x: 0, y: 104, width: 300, height: 96))
        let root: [Bool] = []
        for result in [unflipped, flipped] {
            XCTAssertEqual(result.cuts[root]?.divider, NSRect(x: 0, y: 96, width: 300, height: 8))
            XCTAssertEqual(tiledArea(result), rect)
        }
    }

    func testNestedCutsTileTheRectAtTheirPaths() {
        let rect = NSRect(x: 0, y: 0, width: 600, height: 400)
        let (panes, cuts) = tile(
            .split(
                vertical: false, ratio: 0.5,
                first: .pane(tabId: a),
                second: .split(vertical: true, ratio: 0.25, first: .pane(tabId: b), second: .pane(tabId: c))
            ),
            in: rect
        )
        XCTAssertEqual(cuts.count, 2)
        XCTAssertEqual(cuts[[Bool]()]?.divider, NSRect(x: 296, y: 0, width: 8, height: 400))
        XCTAssertEqual(cuts[[true]]?.divider, NSRect(x: 304, y: 294, width: 296, height: 8))
        XCTAssertEqual(cuts[[true]]?.bounds, NSRect(x: 304, y: 0, width: 296, height: 400))
        XCTAssertEqual(panes[a], NSRect(x: 0, y: 0, width: 296, height: 400))
        XCTAssertEqual(panes[b], NSRect(x: 304, y: 302, width: 296, height: 98))
        XCTAssertEqual(panes[c], NSRect(x: 304, y: 0, width: 296, height: 294))
        XCTAssertEqual(tiledArea((panes, cuts)), rect)
    }

    func testASinglePaneTakesTheWholeRect() {
        let rect = NSRect(x: 8, y: 8, width: 320, height: 240)
        let (panes, cuts) = tile(.pane(tabId: a), in: rect)
        XCTAssertEqual(panes[a], rect)
        XCTAssertTrue(cuts.isEmpty)
    }

    func testTheMarginBandRingsItsFrameAndBitesItsCorners() {
        let margin = SplitMarginView()
        margin.frame = NSRect(x: 4, y: 4, width: 400, height: 300)
        guard let layer = margin.layer?.sublayers?.first as? CAShapeLayer, let path = layer.path else {
            return XCTFail("the margin band has no path")
        }
        XCTAssertEqual(layer.fillRule, .evenOdd)
        // The ring paints the margin outside the panes' rectangle; the crescents bite inside.
        let w = SplitMarginView.width
        XCTAssertEqual(path.boundingBoxOfPath, CGRect(x: -w, y: -w, width: 400 + 2 * w, height: 300 + 2 * w))
        XCTAssertNil(margin.hitTest(NSPoint(x: 200, y: 150)))
    }
}
