import XCTest
import WebKit
@testable import Lilo

@MainActor
final class TabExtensionAdapterTests: XCTestCase {

    func testIsPrivateFalseForNonPrivateTab() {
        let webView = WKWebView()
        let engineTab = WKWebViewTab(id: UUID(), webView: webView)
        let adapter = TabExtensionAdapter(engineTab: engineTab)
        // A web view on the default (non-private) data store is not private browsing.
        XCTAssertEqual(adapter.engineTab?.isPrivateBrowsing, false)
    }

    func testANewTabHasNoURLUntilItsFirstNavigationStarts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tab-url-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try JSONSerialization.data(withJSONObject: ["manifest_version": 3, "name": "Tab", "version": "1.0"])
            .write(to: folder.appendingPathComponent("manifest.json"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        let server = try await TinyHTTPServer(index: "<p>page</p>")
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/"))
        let engineTab = WKWebViewTab(id: UUID(), webView: WKWebView())
        let adapter = TabExtensionAdapter(engineTab: engineTab)

        XCTAssertNil(adapter.url(for: context), "Chrome reports no url before a tab's first navigation")
        engineTab.loadURL(url)
        XCTAssertEqual(adapter.url(for: context), url)
        let committed = await pollUntil { engineTab.hasCommittedContent && !engineTab.isLoading }
        XCTAssertTrue(committed)
        XCTAssertEqual(adapter.url(for: context), url)
    }
}
