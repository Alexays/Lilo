import AppKit
import XCTest
@testable import Lilo

final class WindowFrameGeometryTests: XCTestCase {
    private let size = CGSize(width: 1280, height: 800)

    func testBandsTileEverythingOutsideTheContentHole() {
        let geometry = WindowFrameGeometry(size: size, sidebarWidth: 260, inset: 8, cornerRadius: 10)

        XCTAssertEqual(geometry.contentHole, CGRect(x: 268, y: 8, width: 1280 - 260 - 16, height: 800 - 16))
        XCTAssertEqual(geometry.leftBand, CGRect(x: 0, y: 0, width: 268, height: 800))
        XCTAssertEqual(geometry.rightBand, CGRect(x: 1272, y: 0, width: 8, height: 800))
        XCTAssertEqual(geometry.bottomBand, CGRect(x: 268, y: 0, width: 1004, height: 8))
        XCTAssertEqual(geometry.topBand, CGRect(x: 268, y: 792, width: 1004, height: 8))

        // Bands + hole partition the window exactly (no gaps, no overlap).
        let bandArea = [geometry.leftBand, geometry.rightBand, geometry.topBand, geometry.bottomBand]
            .map { $0.width * $0.height }
            .reduce(0, +)
        XCTAssertEqual(bandArea + geometry.contentHole.width * geometry.contentHole.height, size.width * size.height)
        for band in [geometry.leftBand, geometry.rightBand, geometry.topBand, geometry.bottomBand] {
            XCTAssertFalse(band.intersects(geometry.contentHole))
        }
    }

    func testCornerSquaresSitInsideTheHoleCorners() {
        let geometry = WindowFrameGeometry(size: size, sidebarWidth: 260, inset: 8, cornerRadius: 10)
        let hole = geometry.contentHole

        XCTAssertEqual(geometry.cornerRadius, 10)
        XCTAssertEqual(geometry.bottomLeftCorner, CGRect(x: hole.minX, y: hole.minY, width: 10, height: 10))
        XCTAssertEqual(geometry.topLeftCorner, CGRect(x: hole.minX, y: hole.maxY - 10, width: 10, height: 10))
        XCTAssertEqual(geometry.bottomRightCorner, CGRect(x: hole.maxX - 10, y: hole.minY, width: 10, height: 10))
        XCTAssertEqual(geometry.topRightCorner, CGRect(x: hole.maxX - 10, y: hole.maxY - 10, width: 10, height: 10))
    }

    func testHiddenSidebarLeavesOnlyTheInsetBand() {
        let geometry = WindowFrameGeometry(size: size, sidebarWidth: 0, inset: 8, cornerRadius: 10)

        XCTAssertEqual(geometry.leftBand.width, 8)
        XCTAssertEqual(geometry.contentHole.minX, 8)
        XCTAssertEqual(geometry.contentHole.width, 1280 - 16)
    }

    func testDegenerateSizesProduceNoNegativeRects() {
        let geometry = WindowFrameGeometry(size: CGSize(width: 10, height: 10), sidebarWidth: 260, inset: 8, cornerRadius: 10)

        XCTAssertEqual(geometry.contentHole.width, 0)
        XCTAssertGreaterThanOrEqual(geometry.rightBand.width, 0)
        XCTAssertGreaterThanOrEqual(geometry.topBand.height, 0)
        XCTAssertGreaterThanOrEqual(geometry.cornerRadius, 0)
    }

    func testCornerRadiusClampsToHoleSize() {
        // Hole height 4: the radius clamps to 2 (half the hole's smaller dimension).
        let geometry = WindowFrameGeometry(size: CGSize(width: 600, height: 20), sidebarWidth: 100, inset: 8, cornerRadius: 10)

        XCTAssertEqual(geometry.cornerRadius, 2)
        XCTAssertEqual(geometry.topLeftCorner.size, CGSize(width: 2, height: 2))
    }
}
