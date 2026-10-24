import WebKit
import XCTest
@testable import Lilo

/// The warm pool must spawn a WebContent process without committing a navigation: a committed about:blank enters the
/// back-forward list, so the back-swipe lands on a blank page that reload cannot leave.
@MainActor
final class WKEngineFactoryWarmHistoryTests: XCTestCase {

    func testWarmPoolTabHasNoBackEntryAfterFirstRealLoad() async {
        let factory = WKEngineFactory()
        let store = factory.defaultDataStore()
        factory.rearmWarmPool(dataStore: store, profileId: nil)
        _ = await pollUntil(timeout: 2) { factory.test_warmPoolCount == 1 }

        let tab = factory.createTab(configuration: .init(dataStore: store))
        defer { tab.teardown() }

        // Wait for any prewarm navigation to COMMIT before the first real load: a committed
        // about:blank is the failure precondition. A correct prewarm commits nothing, so a timeout
        // here is expected and deliberately not a failure.
        await pollUntil(timeout: 2) { tab.wkWebView.backForwardList.currentItem != nil }

        // First real navigation in this tab. Wait for it to COMMIT (currentItem becomes the data URL),
        // not merely for `url` to change: `url` flips during the provisional phase, before the new
        // back-forward entry exists, so checking `canGoBack` then would race ahead of the commit.
        tab.loadURL(URL(string: "data:text/html,<h1>warm</h1>")!)
        await pollUntil(timeout: 5) {
            tab.wkWebView.backForwardList.currentItem?.url.absoluteString.hasPrefix("data:") == true
        }

        XCTAssertFalse(
            tab.wkWebView.canGoBack,
            "A warm-pool tab's first real load must leave no back-forward entry: a leftover prewarm "
                + "about:blank makes the back-swipe land on a blank, unreloadable page"
        )
        XCTAssertFalse(
            tab.wkWebView.backForwardList.backList.contains { $0.url.absoluteString == "about:blank" },
            "the prewarm about:blank must never appear in the back-forward list"
        )
    }

    func testWarmPoolSpawnsWebContentProcessAheadOfDemand() async throws {
        let factory = WKEngineFactory()
        let store = factory.defaultDataStore()
        factory.rearmWarmPool(dataStore: store, profileId: nil)
        _ = await pollUntil(timeout: 2) { factory.test_warmPoolCount == 1 }

        let tab = factory.createTab(configuration: .init(dataStore: store))
        defer { tab.teardown() }

        let accessors = WebViewPrivateAccessors(tab.wkWebView)
        guard tab.wkWebView.responds(to: NSSelectorFromString("_webProcessIdentifier")) else {
            throw XCTSkip("_webProcessIdentifier SPI unavailable on this OS, cannot observe spawn")
        }

        // The whole point of prewarming: the WebContent process is live before the first navigation.
        await pollUntil(timeout: 5) { accessors.pid("_webProcessIdentifier") != nil }
        XCTAssertNotNil(
            accessors.pid("_webProcessIdentifier"),
            "the warm view must pre-spawn its WebContent process ahead of demand"
        )
    }
}
