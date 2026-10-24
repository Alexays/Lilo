import XCTest
import WebKit
@testable import Lilo

@MainActor
final class WebInspectorRecoveryTests: XCTestCase {
    func testShowingTheInspectorRetainsTheTab() {
        let configuration = WKWebViewConfiguration()
        WebInspectorSupport.prepare(configuration: configuration)
        let tab = WKWebViewTab(configuration: configuration)
        defer { _ = WebInspectorSupport.close(for: tab.wkWebView) }
        XCTAssertFalse(tab.shouldRetainForWebInspector)

        XCTAssertTrue(tab.showWebInspector())

        XCTAssertTrue(tab.shouldRetainForWebInspector)
    }
}
