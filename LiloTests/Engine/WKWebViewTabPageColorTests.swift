import AppKit
import XCTest
@testable import Lilo

/// The page bar's color read off the top band of a page WebKit does not sample (a fixed header, an image).
@MainActor
final class WKWebViewTabPageColorTests: XCTestCase {
    /// A 1200 x 16 band in `background`, with `paint` drawing over it (origin bottom left).
    private func band(_ background: NSColor, _ paint: @escaping (CGRect) -> Void = { _ in }) -> NSImage {
        let size = NSSize(width: 1200, height: 16)
        return NSImage(size: size, flipped: false) { rect in
            background.setFill()
            rect.fill()
            paint(rect)
            return true
        }
    }

    func testTextAndALogoInTheHeaderLeaveItsColor() {
        let image = band(.black) { _ in
            NSColor.white.setFill()
            NSRect(x: 20, y: 2, width: 40, height: 12).fill()
            for x in stride(from: 120, to: 600, by: 14) { NSRect(x: x, y: 4, width: 3, height: 8).fill() }
        }
        XCTAssertEqual(WKWebViewTab.edgeStops(image), "#000000")
    }

    func testAThinAccentStripeAtTheTopLeavesThePageColor() {
        let image = band(.white) { rect in
            NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1).setFill()
            NSRect(x: 0, y: rect.height - 3, width: rect.width, height: 3).fill()
        }
        XCTAssertEqual(WKWebViewTab.edgeStops(image), "#ffffff")
    }

    func testATwoToneEdgeKeepsItsStops() throws {
        let image = band(.white) { rect in
            NSColor.black.setFill()
            NSRect(x: 0, y: 0, width: rect.width / 2, height: rect.height).fill()
        }
        let stops = try XCTUnwrap(WKWebViewTab.edgeStops(image)).split(separator: ",")
        XCTAssertEqual(stops.count, 8)
        XCTAssertEqual(stops.first, "#000000")
        XCTAssertEqual(stops.last, "#ffffff")
    }
}
