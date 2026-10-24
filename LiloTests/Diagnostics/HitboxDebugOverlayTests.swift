import AppKit
import XCTest
@testable import Lilo

@MainActor
final class HitboxDebugOverlayTests: XCTestCase {

    // MARK: - Formatting helper (the pure render surface)

    func testLinesRenderAllThreeLifetimes() {
        let snapshot = InteractionOwnershipSnapshot(capture: .chrome, hover: .content, focus: .none)
        let lines = InteractionOwnershipSnapshot.lines(snapshot)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].label, "capture: chrome")
        XCTAssertEqual(lines[1].label, "hover: content")
        XCTAssertEqual(lines[2].label, "focus: none")
    }

    func testNilCaptureRendersAsNone() {
        let snapshot = InteractionOwnershipSnapshot(capture: nil, hover: .chrome, focus: .chrome)
        let lines = InteractionOwnershipSnapshot.lines(snapshot)
        XCTAssertEqual(lines[0].label, "capture: none")
    }

    func testLineColorMatchesTarget() {
        let snapshot = InteractionOwnershipSnapshot(capture: .chrome, hover: .content, focus: .none)
        let lines = InteractionOwnershipSnapshot.lines(snapshot)
        XCTAssertEqual(lines[0].color, NSColor.systemGreen)   // chrome
        XCTAssertEqual(lines[1].color, NSColor.systemRed)     // content
        XCTAssertEqual(lines[2].color, NSColor.systemGray)    // none / inactive
    }
}
