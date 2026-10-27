import AppKit
import XCTest
@testable import Lilo

@MainActor
final class AppIconPreferenceTests: XCTestCase {
    override func setUpWithError() throws {
        #if SWIFT_PACKAGE
        throw XCTSkip("app icons are compiled only in the Xcode-built app")
        #endif
    }

    func testPixelIsTheBundledIconBeforeLaunch() throws {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String, "Pixel")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String, "Pixel")
        let icon = try XCTUnwrap(Bundle.main.url(forResource: "Pixel", withExtension: "icns"))
        XCTAssertNotNil(NSImage(contentsOf: icon))
    }

    func testEveryIconHasAPreviewAndClassicIsDistinctFromPixel() throws {
        let previews = AppIconPreference.previews
        XCTAssertEqual(Set(previews.compactMap { $0["id"] }), Set(AppIconPreference.variants))
        let classic = try XCTUnwrap(previews.first { $0["id"] == "classic" }?["dataURL"])
        let pixel = try XCTUnwrap(previews.first { $0["id"] == "pixel" }?["dataURL"])
        XCTAssertNotEqual(classic, pixel)
    }
}
