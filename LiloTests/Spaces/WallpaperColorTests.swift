import AppKit
import XCTest
@testable import Lilo

final class WallpaperColorTests: XCTestCase {
    func testTheWallpaperGivesItsMostVividColorAndASmallPreview() throws {
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

        let wallpaper = try XCTUnwrap(MainWindowController.wallpaper(at: url))
        XCTAssertTrue(wallpaper.thumbnail.hasPrefix("data:image/jpeg;base64,"))
        XCTAssertLessThan(wallpaper.thumbnail.count, 40_000, "a preview, not the picture")
        let color = try XCTUnwrap(wallpaper.color)
        let rgb = try XCTUnwrap(NSColor(cssHex: color)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(rgb.redComponent, 0.15, color)
        XCTAssertGreaterThan(rgb.blueComponent, 0.8, color)
        XCTAssertNil(MainWindowController.wallpaper(at: url.deletingLastPathComponent().appendingPathComponent("missing.png")))
    }
}
