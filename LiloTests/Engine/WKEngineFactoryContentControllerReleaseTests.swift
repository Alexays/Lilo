import WebKit
import XCTest
@testable import Lilo

@MainActor
final class WKEngineFactoryContentControllerReleaseTests: XCTestCase {
    /// The factory caches one WKUserContentController per data-store identifier. Private spaces
    /// create ephemeral data stores that must not leak their controller (and its handlers/warm
    /// view) forever once the space closes.
    func testReleaseContentControllerEvictsCacheEntry() {
        let factory = WKEngineFactory()
        // Every tab builds its own web view from the cached controller, never a pre-built warm one.
        factory.suppressWarmPool = true
        let ephemeral = factory.createDataStore(persistent: false, identifier: UUID().uuidString)

        let first = factory.createTab(configuration: .init(dataStore: ephemeral)).wkWebView.configuration.userContentController
        let second = factory.createTab(configuration: .init(dataStore: ephemeral)).wkWebView.configuration.userContentController
        XCTAssertTrue(first === second, "tabs of the same data store must share the cached controller")

        factory.releaseContentController(for: ephemeral)

        let third = factory.createTab(configuration: .init(dataStore: ephemeral)).wkWebView.configuration.userContentController
        XCTAssertFalse(first === third, "after release, a new tab must get a rebuilt controller rather than the freed one")
    }

    /// Releasing must also drop any warm view built for the same key, otherwise a live
    /// WebContent process keeps the freed data store's controller alive by reference.
    func testReleaseContentControllerDropsWarmView() async {
        let factory = WKEngineFactory()
        let ephemeral = factory.createDataStore(persistent: false, identifier: UUID().uuidString)
        factory.rearmWarmPool(dataStore: ephemeral, profileId: nil)
        _ = await pollUntil { factory.test_warmPoolCount == 1 }
        XCTAssertEqual(factory.test_warmPoolCount, 1)

        factory.releaseContentController(for: ephemeral)

        XCTAssertEqual(factory.test_warmPoolCount, 0, "the warm view keyed to the released data store must be dropped")
    }
}
