import WebKit
import XCTest
@testable import Lilo

@MainActor
final class MinimumFontSizeTests: XCTestCase {
    func testRaisingTheMinimumEnlargesTinyTextInOpenTabs() async throws {
        let factory = WKEngineFactory()
        defer { factory.setMinimumFontSize(0) }
        let tab = factory.createTab(configuration: .init(dataStore: factory.defaultDataStore()))
        defer { tab.teardown() }
        let webView = tab.wkWebView
        webView.loadHTMLString("<span id=s style='font-size:4px'>Tiny text</span>", baseURL: URL(string: "https://example.com/"))
        _ = await pollUntil(timeout: 5) { webView.url != nil && !webView.isLoading }
        let measure = "document.getElementById('s').getBoundingClientRect().height"
        let before = try await webView.evaluateJavaScript(measure) as? Double ?? 0

        factory.setMinimumFontSize(24)

        let grew = await pollUntil(timeout: 3) {
            ((try? await webView.evaluateJavaScript(measure)) as? Double ?? 0) > before * 3
        }
        XCTAssertTrue(grew, "an open tab picks up the new minimum without a reload")
    }
}
