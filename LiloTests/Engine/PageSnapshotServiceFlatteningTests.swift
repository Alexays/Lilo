import AppKit
import XCTest
@testable import Lilo

/// Covers the opaque backdrop every capture is composited onto: a page that paints no background of
/// its own leaves transparent pixels, and transparent flattens to black once the PNG is written.
@MainActor
final class PageSnapshotServiceFlatteningTests: XCTestCase {

    private let pixelW = 1411
    private let pixelH = 1627

    /// Deliberately not white, so a test can tell "the backdrop showed through" apart from "the
    /// snapshot happened to be light".
    private let backdrop = NSColor.green.cgColor

    func testFlatteningATransparentSnapshotYieldsTheBackdrop() throws {
        let flat = try XCTUnwrap(PageSnapshotService.flattened(makeSnapshot(.clear), over: backdrop))

        let bitmap = try XCTUnwrap(bitmap(of: flat))
        let pixel = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        XCTAssertGreaterThan(pixel.alphaComponent, 0.99)
        XCTAssertGreaterThan(pixel.greenComponent, 0.5, "Expected the backdrop, got \(pixel)")
    }

    // MARK: - Helpers

    /// A viewport snapshot as `WKWebView.takeSnapshot` returns one: a Retina bitmap whose `size` is
    /// in points and whose backing rep is in device pixels. `.clear` models the page painting no
    /// background of its own into the non-opaque web view.
    private func makeSnapshot(_ color: NSColor) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelW, pixelsHigh: pixelH,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: pixelW, height: pixelH).fill()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: Double(pixelW) / 2, height: Double(pixelH) / 2))
        image.addRepresentation(rep)
        return image
    }

    private func bitmap(of image: NSImage) -> NSBitmapImageRep? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg)
    }
}
