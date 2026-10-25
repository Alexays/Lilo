import AppKit
import XCTest
@testable import Lilo

final class WallpaperColorTests: XCTestCase {
    func testTheWallpaperColorIsItsMostVividColor() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = NSImage(size: NSSize(width: 400, height: 300), flipped: false) { rect in
            NSColor(white: 0.5, alpha: 1).setFill(); rect.fill()
            NSColor(srgbRed: 0, green: 0.6, blue: 1, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 200, height: 300).fill()
            return true
        }
        let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)

        let color = try XCTUnwrap(MainWindowController.wallpaperColor(at: url))
        let rgb = try XCTUnwrap(NSColor(cssHex: color)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(rgb.redComponent, 0.15, color)
        XCTAssertGreaterThan(rgb.blueComponent, 0.8, color)
        XCTAssertNil(MainWindowController.wallpaperColor(at: url.deletingLastPathComponent().appendingPathComponent("missing.png")))
    }
}
