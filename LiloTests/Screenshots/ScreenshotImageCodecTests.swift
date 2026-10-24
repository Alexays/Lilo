import AppKit
import XCTest
@testable import Lilo

final class ScreenshotImageCodecTests: XCTestCase {

    func test_decodePNGDataURL_validPrefix_returnsBytes() {
        // "PNG" => UE5H in base64
        let dataURL = "data:image/png;base64,UE5H"
        let data = ScreenshotImageCodec.decodePNGDataURL(dataURL)
        XCTAssertEqual(data.map { String(decoding: $0, as: UTF8.self) }, "PNG")
    }

    func test_decodePNGDataURL_rawBase64_noPrefix_returnsBytes() {
        let data = ScreenshotImageCodec.decodePNGDataURL("UE5H")
        XCTAssertEqual(data.map { String(decoding: $0, as: UTF8.self) }, "PNG")
    }

    func test_decodePNGDataURL_garbage_returnsNil() {
        XCTAssertNil(ScreenshotImageCodec.decodePNGDataURL("data:image/png;base64,@@not base64@@"))
    }

    func test_uniqueURL_noCollision_returnsOriginal() {
        let folder = URL(fileURLWithPath: "/tmp/shots")
        let url = ScreenshotImageCodec.uniqueURL(in: folder, filename: "a.png") { _ in false }
        XCTAssertEqual(url, folder.appendingPathComponent("a.png"))
    }

    func test_uniqueURL_collision_appendsSuffix() {
        let folder = URL(fileURLWithPath: "/tmp/shots")
        let taken: Set<String> = ["a.png", "a (2).png"]
        let url = ScreenshotImageCodec.uniqueURL(in: folder, filename: "a.png") {
            taken.contains($0.lastPathComponent)
        }
        XCTAssertEqual(url.lastPathComponent, "a (3).png")
    }

    func test_croppedPNG_clampsToTheImage_andRejectsACropOutsideIt() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let png = try XCTUnwrap(context.makeImage().flatMap(ScreenshotImageCodec.pngData))

        let clamped = try XCTUnwrap(ScreenshotImageCodec.croppedPNG(png, to: CGRect(x: 30, y: -10, width: 50, height: 20)))
        let image = try XCTUnwrap(NSBitmapImageRep(data: clamped))
        XCTAssertEqual(image.pixelsWide, 10)
        XCTAssertEqual(image.pixelsHigh, 10)
        XCTAssertNil(ScreenshotImageCodec.croppedPNG(png, to: CGRect(x: 50, y: 0, width: 10, height: 10)))
    }
}
