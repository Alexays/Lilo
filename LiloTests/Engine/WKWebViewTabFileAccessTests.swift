import WebKit
import XCTest
@testable import Lilo

/// A local HTML page shows local assets from any folder, as in Chrome; any other file reads only itself.
@MainActor
final class WKWebViewTabFileAccessTests: XCTestCase {
    /// Opens `name` holding `document`, in or below the folder of a picture it shows, and returns whether the picture loaded.
    private func loadsSiblingPicture(_ name: String, _ document: String) async throws -> String? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="
        try XCTUnwrap(Data(base64Encoded: pixel)).write(to: folder.appendingPathComponent("pic.png"))
        let file = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try document.write(to: file, atomically: true, encoding: .utf8)
        let factory = WKEngineFactory()
        let tab = factory.createTab(configuration: .init(dataStore: factory.createDataStore(persistent: false, identifier: nil)))
        defer { tab.teardown() }

        tab.loadURL(file)
        var state: String?
        _ = await pollUntil(timeout: 10) {
            state = try? await tab.wkWebView.evaluateJavaScript("document.documentElement.getAttribute('data-picture')") as? String
            return state != nil
        }
        return state
    }

    func testAnHTMLPageShowsTheAssetsBesideIt() async throws {
        let page = #"<html><body><img src="pic.png" onload="document.documentElement.setAttribute('data-picture','loaded')" onerror="document.documentElement.setAttribute('data-picture','blocked')"></body></html>"#
        let state = try await loadsSiblingPicture("page.html", page)
        XCTAssertEqual(state, "loaded")
    }

    func testAnHTMLPageShowsAssetsOutsideItsFolder() async throws {
        let page = #"<html><body><img src="../pic.png" onload="document.documentElement.setAttribute('data-picture','loaded')" onerror="document.documentElement.setAttribute('data-picture','blocked')"></body></html>"#
        let state = try await loadsSiblingPicture("docs/page.html", page)
        XCTAssertEqual(state, "loaded")
    }

    func testAnHTMLPageCannotFetchAnotherFile() async throws {
        let page = #"<html><body><script>fetch("../pic.png").then(() => "loaded", () => "blocked").then((s) => document.documentElement.setAttribute('data-picture', s))</script></body></html>"#
        let state = try await loadsSiblingPicture("docs/page.html", page)
        XCTAssertEqual(state, "blocked")
    }

    func testAnotherFileReadsNothingBesideIt() async throws {
        let svg = #"""
            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="10" height="10">
            <image xlink:href="pic.png" width="1" height="1" onload="document.documentElement.setAttribute('data-picture','loaded')" onerror="document.documentElement.setAttribute('data-picture','blocked')"/>
            </svg>
            """#
        let state = try await loadsSiblingPicture("drawing.svg", svg)
        XCTAssertEqual(state, "blocked")
    }
}
