import XCTest
@testable import Lilo

@MainActor
final class ChromeUIAssetsTests: XCTestCase {
    func testIndexHTMLIsEmbedded() throws {
        let html = try XCTUnwrap(ChromeUIAssets.assets["index.html"]).text.description
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
    }

    func testAllEmbeddedAssetsAreNonEmpty() {
        XCTAssertNotNil(ChromeUIAssets.assets["index.html"])
        for (path, asset) in ChromeUIAssets.assets {
            XCTAssertGreaterThan(asset.text.utf8CodeUnitCount, 0, path)
            XCTAssertFalse(asset.mimeType.isEmpty, path)
        }
    }

    /// Build-integrity check: every local `src`/`href` in index.html must resolve to an embedded
    /// asset, otherwise the scheme handler 404s it at runtime.
    func testIndexHTMLLocalReferencesResolveToEmbeddedAssets() throws {
        let html = try XCTUnwrap(ChromeUIAssets.assets["index.html"]).text.description
        let regex = try NSRegularExpression(pattern: #"(?:src|href)="\./([^"]+)""#)
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for match in matches {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let path = String(html[range])
            XCTAssertNotNil(ChromeUIAssets.assets[path], "index.html references \(path) but it is not embedded")
        }
    }

    func testBuildBootstrapScript_embedsSidebarWidth() {
        let script = MainWindowController.buildBootstrapScript(sidebarWidth: 320, windowBackgroundColor: "")
        XCTAssertTrue(script.source.contains("320"), "source should contain sidebar width")
    }

    func testBuildBootstrapScript_embedsBackgroundColor() {
        let script = MainWindowController.buildBootstrapScript(sidebarWidth: 260, windowBackgroundColor: "#aabbcc")
        XCTAssertTrue(script.source.contains("#aabbcc"), "source should contain background color")
    }

    func testBuildBootstrapScript_injectionTime() {
        let script = MainWindowController.buildBootstrapScript(sidebarWidth: 260, windowBackgroundColor: "")
        XCTAssertEqual(script.injectionTime, .atDocumentStart)
        XCTAssertTrue(script.isForMainFrameOnly)
    }
}
