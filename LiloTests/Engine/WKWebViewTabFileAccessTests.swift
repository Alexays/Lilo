import WebKit
import XCTest
@testable import Lilo

/// A local HTML page shows local assets from any folder, as in Chrome; any other file reads only itself; a folder lists its files.
@MainActor
final class WKWebViewTabFileAccessTests: XCTestCase {
    private static let markupName = #"<b>&"x.txt"#

    /// Opens a folder holding a subfolder, a hidden file and a file named in markup, and returns its tab once it lists them.
    private func openListing() async throws -> (tab: WKWebViewTab, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-listing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        for name in ["a.txt", ".hidden", Self.markupName, "sub/inner.txt"] {
            try "hello".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let factory = WKEngineFactory()
        let tab = factory.createTab(configuration: .init(dataStore: factory.createDataStore(persistent: false, identifier: nil)))
        addTeardownBlock { tab.teardown() }
        tab.loadURL(folder)
        let names = await listedNames(in: tab)
        XCTAssertFalse(names.isEmpty, "the folder lists its files")
        return (tab, folder)
    }

    /// The names a listing links to, once its rows show; empty when they do not.
    private func listedNames(in tab: WKWebViewTab) async -> [String] {
        var names: [String]?
        _ = await pollUntil(timeout: 10) {
            names = try? await tab.wkWebView.evaluateJavaScript(
                "[...document.querySelectorAll('tbody a')].map((a) => a.textContent)"
            ) as? [String]
            return names?.isEmpty == false
        }
        return names ?? []
    }

    func testAFolderListsItsFilesUnderItsOwnAddress() async throws {
        let (tab, folder) = try await openListing()
        let names = await listedNames(in: tab)
        XCTAssertEqual(names.first, "sub")
        XCTAssertEqual(Set(names), ["sub", "a.txt", ".hidden", Self.markupName])
        XCTAssertEqual(tab.wkWebView.url?.path(percentEncoded: false), folder.path(percentEncoded: false))
        let markup = try await tab.wkWebView.evaluateJavaScript(
            "[document.querySelector('tbody b') === null, [...document.querySelectorAll('tbody a')].find((a) => a.textContent.startsWith('<')).href]"
        ) as? [Any]
        XCTAssertEqual(markup?.first as? Bool, true)
        XCTAssertEqual(markup?.last as? String, folder.appendingPathComponent(Self.markupName).absoluteString)
    }

    func testAListingOpensItsFilesAndFolders() async throws {
        let (tab, folder) = try await openListing()
        let webView = tab.wkWebView
        let click: (String) async -> Void = { name in
            _ = try? await webView.evaluateJavaScript("[...document.querySelectorAll('a')].find((a) => a.textContent === '\(name)').click()")
        }

        await click("a.txt")
        let opened = await pollUntil(timeout: 10) { (try? await webView.evaluateJavaScript("document.body.innerText") as? String) == "hello" }
        XCTAssertTrue(opened, "the file opens")
        webView.goBack()
        let names = await listedNames(in: tab)
        XCTAssertEqual(Set(names), ["sub", "a.txt", ".hidden", Self.markupName])

        await click("sub")
        let inSub = await pollUntil(timeout: 10) { (try? await webView.evaluateJavaScript("document.querySelector('tbody a')?.textContent") as? String) == "inner.txt" }
        XCTAssertTrue(inSub, "the subfolder lists its files")
        XCTAssertEqual(webView.url, folder.appendingPathComponent("sub", isDirectory: true))
    }

    func testARestoredListingListsTheFolderAgain() async throws {
        let (tab, _) = try await openListing()
        let factory = WKEngineFactory()
        let restored = factory.createTab(configuration: .init(dataStore: factory.createDataStore(persistent: false, identifier: nil)))
        defer { restored.teardown() }
        XCTAssertTrue(restored.restoreInteractionState(try XCTUnwrap(tab.interactionState)))
        let names = await listedNames(in: restored)
        XCTAssertEqual(names.count, 4)
    }

    func testGoingBackToAListingTheWebViewNoLongerHoldsKeepsTheHistory() async throws {
        let (tab, folder) = try await openListing()
        tab.loadURL(folder.appendingPathComponent("a.txt"))
        _ = await pollUntil(timeout: 10) { (try? await tab.wkWebView.evaluateJavaScript("document.body.innerText") as? String) == "hello" }
        let factory = WKEngineFactory()
        let restored = factory.createTab(configuration: .init(dataStore: factory.createDataStore(persistent: false, identifier: nil)))
        defer { restored.teardown() }
        XCTAssertTrue(restored.restoreInteractionState(try XCTUnwrap(tab.interactionState)))
        _ = await pollUntil(timeout: 10) { (try? await restored.wkWebView.evaluateJavaScript("document.body.innerText") as? String) == "hello" }

        restored.wkWebView.goBack()
        let names = await listedNames(in: restored)
        XCTAssertEqual(names.count, 4)
        XCTAssertEqual(restored.wkWebView.backForwardList.backList.count, 0)
        XCTAssertEqual(restored.wkWebView.backForwardList.forwardList.count, 1)
    }

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
