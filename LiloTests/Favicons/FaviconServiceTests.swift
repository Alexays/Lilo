import CoreGraphics
import ImageIO
import XCTest
@testable import Lilo

@MainActor
final class FaviconServiceTests: XCTestCase {
    /// Builds a solid-color square PNG of the given pixel size for resize tests.
    private func makePNG(side: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = try XCTUnwrap(context.makeImage())

        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// Largest pixel dimension of an encoded image, or nil if it can't be decoded.
    private func maxDimension(of data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return max(image.width, image.height)
    }

    func testDownscaleShrinksLargeFaviconToMaxDimension() throws {
        let png = try makePNG(side: 64)
        let resized = try XCTUnwrap(FaviconService.downscaledPNG(data: png, maxPixels: 32))
        let dimension = try XCTUnwrap(maxDimension(of: resized))
        XCTAssertLessThanOrEqual(dimension, 32)
        XCTAssertLessThan(resized.count, png.count)
    }

    func testDownscaleDoesNotUpscaleTinyFavicon() throws {
        let png = try makePNG(side: 16)
        let resized = try XCTUnwrap(FaviconService.downscaledPNG(data: png, maxPixels: 32))
        XCTAssertEqual(try XCTUnwrap(maxDimension(of: resized)), 16)
    }

    func testDownscaleRejectsNonImageData() {
        XCTAssertNil(FaviconService.downscaledPNG(data: Data("not an image".utf8), maxPixels: 32))
    }

    func testDataURLDownscalesLargePNGAndEmitsPNG() throws {
        let bigPNG = try makePNG(side: 128)

        let dataURL = try XCTUnwrap(FaviconService.encodedFavicon(data: bigPNG)).dataURL
        XCTAssertTrue(dataURL.hasPrefix("data:image/png;base64,"))

        let base64 = String(dataURL[dataURL.index(after: try XCTUnwrap(dataURL.firstIndex(of: ",")))...])
        let decoded = try XCTUnwrap(Data(base64Encoded: base64))
        XCTAssertLessThanOrEqual(try XCTUnwrap(maxDimension(of: decoded)), 32)
    }

    func testDataURLKeepsSVGAndRejectsNonImageBytes() throws {
        let svg = Data(#"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"/>"#.utf8)
        let dataURL = try XCTUnwrap(FaviconService.encodedFavicon(data: svg)).dataURL
        XCTAssertTrue(dataURL.hasPrefix("data:image/svg+xml;base64,") || dataURL.hasPrefix("data:image/png;base64,"))
        XCTAssertNil(FaviconService.encodedFavicon(data: Data("<html></html>".utf8)))
    }

    func testOversizedSVGIsNeverKeptAsIs() {
        let padding = String(repeating: " ", count: FaviconService.maxSVGFaviconBytes)
        let svg = Data((#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1">"# + padding + "</svg>").utf8)
        let dataURL = FaviconService.encodedFavicon(data: svg)?.dataURL
        XCTAssertFalse(dataURL?.hasPrefix("data:image/svg+xml") ?? false)
    }

    func testRehydrateFillsRestoredTabsFromCacheByHost() {
        let service = FaviconService()
        service.seed(host: "example.com", dataURL: "data:image/png;base64,QUJD", dominantColor: "#112233", profileId: nil)
        var tabs = [
            Tab(id: UUID(), url: URL(string: "https://Example.com/page"), title: "Page"),
            Tab(id: UUID(), url: nil, title: "Home", homeURL: URL(string: "https://example.com/home")),
            Tab(id: UUID(), url: URL(string: "https://unknown.example/x"), title: "Unknown")
        ]

        service.rehydrateRestoredTabs(&tabs)

        XCTAssertEqual(tabs[0].faviconDataURL, "data:image/png;base64,QUJD")
        XCTAssertEqual(tabs[0].faviconDominantColor, "#112233")
        XCTAssertEqual(tabs[1].homeFaviconDataURL, "data:image/png;base64,QUJD")
        XCTAssertEqual(tabs[1].homeFaviconDominantColor, "#112233")
        XCTAssertNil(tabs[2].faviconDataURL)
    }

    func testRehydrateKeepsBlobDominantColorOverCachedOne() {
        let service = FaviconService()
        service.seed(host: "example.com", dataURL: "data:image/png;base64,QUJD", dominantColor: "#112233", profileId: nil)
        var tabs = [Tab(
            id: UUID(),
            url: URL(string: "https://example.com/"),
            title: "Page",
            faviconDominantColor: "#FF0000"
        )]

        service.rehydrateRestoredTabs(&tabs)

        XCTAssertEqual(tabs[0].faviconDataURL, "data:image/png;base64,QUJD")
        XCTAssertEqual(tabs[0].faviconDominantColor, "#FF0000")
    }
}
