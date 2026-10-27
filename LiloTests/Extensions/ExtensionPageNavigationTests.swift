import WebKit
import XCTest
@testable import Lilo

/// An extension page in a tab that sends the tab to a web page, which WebKit drops in the extension's configuration
/// (WEBKIT-GAPS 96).
@MainActor
final class ExtensionPageNavigationTests: XCTestCase {
    func testAnExtensionPageSendsItsTabToAWebPage() async throws {
        let server = try await TinyHTTPServer(index: "<title>web</title><p>web page</p>")
        let web = "http://127.0.0.1:\(server.port)/"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("page-navigation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Redirect", "version": "1.0", "options_ui": ["page": "redirect.html", "open_in_tab": true]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try "document.location = '\(web)';".write(to: folder.appendingPathComponent("redirect.js"), atomically: true, encoding: .utf8)
        try #"<!doctype html><script src="redirect.js"></script>"#.write(to: folder.appendingPathComponent("redirect.html"), atomically: true, encoding: .utf8)
        try #"<!doctype html><a id="go" href="\#(web)">site</a>"#.write(to: folder.appendingPathComponent("link.html"), atomically: true, encoding: .utf8)

        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let (window, registry) = try browserContext.makeExtensionWindow()
        try await registry.load(from: folder)
        let id = try XCTUnwrap(registry.loadedExtensions.last?.id)
        let context = try XCTUnwrap(registry.context(for: id))

        let redirected = try XCTUnwrap(window.createTabStateFirst(url: context.baseURL.appendingPathComponent("redirect.html")))
        _ = await pollUntil(timeout: 10) { window.tabManager.tab(for: redirected.id)?.url?.absoluteString == web }
        XCTAssertEqual(window.tabManager.tab(for: redirected.id)?.url?.absoluteString, web, "a page's own redirect to the web goes through")
        let shown = try XCTUnwrap(window.tabManager.engineTab(for: redirected.id)?.view as? WKWebView)
        _ = await pollUntil(timeout: 10) { shown.title == "web" }
        XCTAssertEqual(shown.title, "web", "the web page loads in a web page's engine")

        let linking = try XCTUnwrap(window.createTabStateFirst(url: context.baseURL.appendingPathComponent("link.html")))
        let page = try XCTUnwrap(window.tabManager.engineTab(for: linking.id)?.view as? WKWebView)
        _ = await pollUntil(timeout: 10) { (try? await page.evaluateJavaScript("!!document.getElementById('go')")) as? Bool == true }
        _ = try await page.evaluateJavaScript("document.getElementById('go').click()")
        _ = await pollUntil(timeout: 10) { window.tabManager.tab(for: linking.id)?.url?.absoluteString == web }
        XCTAssertEqual(window.tabManager.tab(for: linking.id)?.url?.absoluteString, web, "a link on the page goes through")
    }
}
