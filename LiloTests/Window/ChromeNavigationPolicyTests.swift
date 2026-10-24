import WebKit
import XCTest
@testable import Lilo

@MainActor
final class ChromeNavigationPolicyTests: XCTestCase {
    private func decision(for url: String) throws -> WKNavigationActionPolicy? {
        let controller = MainWindowController()
        var decision: WKNavigationActionPolicy?
        controller.webView(controller.chromeWebView, decidePolicyFor: Navigation(url: try XCTUnwrap(URL(string: url)))) { decision = $0 }
        return decision
    }

    func testTheChromeWebViewOnlyLoadsLilosOwnUI() throws {
        XCTAssertEqual(try decision(for: ChromeUISchemeHandler.indexURL.absoluteString), .allow)
        XCTAssertEqual(try decision(for: "https://example.com/"), .cancel)
        XCTAssertEqual(try decision(for: "file:///etc/hosts"), .cancel)
        XCTAssertEqual(try decision(for: "data:text/html,<p>x</p>"), .cancel)
    }
}

/// A navigation of the chrome web view to `url`, as WebKit reports it.
private final class Navigation: WKNavigationAction {
    private let url: URL

    init(url: URL) {
        self.url = url
        super.init()
    }

    override var request: URLRequest { URLRequest(url: url) }
}
