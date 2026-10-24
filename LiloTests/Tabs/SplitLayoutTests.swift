import XCTest
@testable import Lilo

final class SplitLayoutTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    func testCuttingPanesBuildsAGridInReadingOrder() {
        let grid = SplitLayout.pane(tabId: a)
            .inserting(b, at: a, vertical: false, before: false)
            .inserting(c, at: a, vertical: true, before: false)
            .inserting(d, at: b, vertical: true, before: true)
        XCTAssertEqual(grid.paneIds, [a, c, d, b])
        XCTAssertEqual(grid, .split(
            vertical: false, ratio: 0.5,
            first: .split(vertical: true, ratio: 0.5, first: .pane(tabId: a), second: .pane(tabId: c)),
            second: .split(vertical: true, ratio: 0.5, first: .pane(tabId: d), second: .pane(tabId: b))
        ))
    }

    func testRemovingAPaneHandsItsPlaceToTheOtherSideOfItsCut() {
        let grid = SplitLayout.split(
            vertical: false, ratio: 0.3,
            first: .pane(tabId: a),
            second: .split(vertical: true, ratio: 0.7, first: .pane(tabId: b), second: .pane(tabId: c))
        )
        XCTAssertEqual(grid.removing(b), .split(vertical: false, ratio: 0.3, first: .pane(tabId: a), second: .pane(tabId: c)))
        XCTAssertEqual(grid.removing(a), .split(vertical: true, ratio: 0.7, first: .pane(tabId: b), second: .pane(tabId: c)))
        XCTAssertNil(SplitLayout.pane(tabId: a).removing(a))
    }

    func testUpdatingACutByItsPathLeavesTheOthersAlone() {
        let grid = SplitLayout.pane(tabId: a)
            .inserting(b, at: a, vertical: false, before: false)
            .inserting(c, at: b, vertical: true, before: false)
        let resized = grid.updatingCut(at: [true]) { vertical, ratio in
            vertical = false
            ratio = 0.25
        }
        XCTAssertEqual(resized, .split(
            vertical: false, ratio: 0.5,
            first: .pane(tabId: a),
            second: .split(vertical: false, ratio: 0.25, first: .pane(tabId: b), second: .pane(tabId: c))
        ))
        XCTAssertEqual(resized.subtree(at: [true, false]), .pane(tabId: b))
    }
}
