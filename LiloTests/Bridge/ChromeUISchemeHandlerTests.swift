import XCTest
@testable import Lilo

final class ChromeUISchemeHandlerTests: XCTestCase {
    func testAssetPathMapsURLsToEmbeddedKeys() {
        XCTAssertEqual(
            ChromeUISchemeHandler.assetPath(for: URL(string: "lilo-chrome://ui/index.html")!),
            "index.html"
        )
        XCTAssertEqual(
            ChromeUISchemeHandler.assetPath(for: URL(string: "lilo-chrome://ui/")!),
            "index.html"
        )
        XCTAssertEqual(
            ChromeUISchemeHandler.assetPath(for: URL(string: "lilo-chrome://ui/assets/chunk-abc.js")!),
            "assets/chunk-abc.js"
        )
    }

    func testIndexURLResolvesToTheEmbeddedIndex() {
        XCTAssertNotNil(ChromeUIAssets.assets[ChromeUISchemeHandler.assetPath(for: ChromeUISchemeHandler.indexURL)])
    }
}
