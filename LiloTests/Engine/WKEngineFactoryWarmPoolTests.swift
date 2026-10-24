import WebKit
import XCTest
@testable import Lilo

@MainActor
final class WKEngineFactoryWarmPoolTests: XCTestCase {

    /// Persistent and ephemeral warm views coexist, so alternating normal and private tabs never
    /// misses the pool or wastes a speculative build.
    func testWarmPoolHoldsOneSlotPerStoreKind() async {
        let factory = WKEngineFactory()
        await warm(factory, factory.defaultDataStore())
        XCTAssertEqual(factory.test_warmPoolCount, 1)

        await warm(factory, factory.createDataStore(persistent: false, identifier: nil))
        XCTAssertEqual(factory.test_warmPoolCount, 2, "an ephemeral warm view must not evict the persistent one")
    }

    func testCreateTabConsumesMatchingWarmSlotOnly() async {
        let factory = WKEngineFactory()
        let persistent = factory.defaultDataStore()
        let ephemeral = factory.createDataStore(persistent: false, identifier: nil)
        await warm(factory, persistent)
        await warm(factory, ephemeral)

        _ = factory.createTab(configuration: .init(dataStore: ephemeral))

        XCTAssertEqual(factory.test_warmPoolCount, 1,
                       "consuming the ephemeral slot must leave the persistent slot warm (refill is deferred)")
    }

    /// Only a tab the user opens predicts another: a restored tab coming back, as at launch, builds no warm view.
    func testOnlyAnOpenedTabRefillsThePool() async {
        let factory = WKEngineFactory()
        _ = factory.createTab(configuration: .init(dataStore: factory.defaultDataStore(), refillsWarmPool: false))
        let refilledByRestore = await pollUntil(timeout: 0.6) { factory.test_warmPoolCount > 0 }
        XCTAssertFalse(refilledByRestore)

        _ = factory.createTab(configuration: .init(dataStore: factory.defaultDataStore()))
        let refilled = await pollUntil(timeout: 2) { factory.test_warmPoolCount == 1 }
        XCTAssertTrue(refilled)
    }

    func testWarmPoolEvictsOldestBeyondCapacity() async {
        let factory = WKEngineFactory()
        await warm(factory, factory.defaultDataStore())
        await warm(factory, factory.createDataStore(persistent: false, identifier: nil))
        await warm(factory, factory.createDataStore(persistent: true, identifier: TestProfileIds.next().uuidString))

        XCTAssertEqual(factory.test_warmPoolCount, 2, "the pool is capped at two slots; the oldest is evicted")
    }

    /// Boot re-applies the persisted override dict, which usually matches what the factory already
    /// has; that re-apply must not cost the pre-spawned warm view.
    func testWarmPoolSurvivesUnchangedFeatureFlagOverrides() async {
        let factory = WKEngineFactory()
        await warm(factory, factory.defaultDataStore())

        factory.setFeatureFlagOverrides([:])
        XCTAssertEqual(factory.test_warmPoolCount, 1, "an unchanged override dict must not drop the warm pool")

        factory.setFeatureFlagOverrides(["FeatureX": true])
        XCTAssertEqual(factory.test_warmPoolCount, 0, "a real change still drops the pool (preferences bind at web-view creation)")
    }

    /// Injection-table updates rescript the live content controllers in place, so the warm view
    /// survives the boot-time cached-table arrival AND a post-refresh table change.
    func testWarmPoolSurvivesInjectionTableArrivalAndChange() async {
        let factory = WKEngineFactory()
        // Built before the warm view, so it consumes no warm slot and its deferred refill finds one in place.
        let controller = factory.createTab(configuration: .init()).wkWebView.configuration.userContentController
        await warm(factory, factory.defaultDataStore())

        factory.setFilterTables(rulesTag: nil, rules: nil, scripts: WKEngineFactory.makeFilterScripts(cosmetic: nil, sites: nil, scriptlets: "{\"example.com\":[[\"json-prune\",[\"a\"]]]}", procedural: nil))
        XCTAssertEqual(factory.test_warmPoolCount, 1, "cached tables arriving at boot must not drop the warm pool")
        XCTAssertTrue(controller.userScripts.contains { $0.source.contains(WKEngineFactory.keyHash("example.com")) },
                      "the live controller must carry the newly arrived table")

        factory.setFilterTables(rulesTag: nil, rules: nil, scripts: WKEngineFactory.makeFilterScripts(cosmetic: nil, sites: nil, scriptlets: "{\"example.com\":[[\"json-prune\",[\"a\"]]]}", procedural: nil))
        XCTAssertEqual(factory.test_warmPoolCount, 1, "re-applying an identical table is a no-op")

        factory.setFilterTables(rulesTag: nil, rules: nil, scripts: WKEngineFactory.makeFilterScripts(cosmetic: nil, sites: nil, scriptlets: "{\"example.org\":[[\"json-prune\",[\"b\"]]]}", procedural: nil))
        XCTAssertEqual(factory.test_warmPoolCount, 1, "a table change rescripts in place instead of dropping the pool")
        let sources = controller.userScripts.map(\.source)
        XCTAssertTrue(sources.contains { $0.contains(WKEngineFactory.keyHash("example.org")) })
        XCTAssertFalse(sources.contains { $0.contains(WKEngineFactory.keyHash("example.com")) }, "the old table must not linger after the rescript")
        let warmTab = factory.createTab(configuration: .init())
        XCTAssertTrue(warmTab.wkWebView.configuration.userContentController === controller,
                      "the warm view carries the rescripted live controller")
    }

    /// A web view binds its extension controller at creation, so a warm view of one profile must
    /// never serve another: that tab would run the wrong profile's extensions.
    func testWarmWebViewIsNeverReusedAcrossProfiles() async throws {
        let (factory, cache, cleanup) = try makeFactoryWithProfiles()
        defer { cleanup() }
        let a = TestProfileIds.next(), b = TestProfileIds.next()
        cache.pinnedProfileIds = [a, b]
        let contextA = try cache.context(for: a), contextB = try cache.context(for: b)
        let store = factory.defaultDataStore()
        await warm(factory, store, profileId: a)

        let tab = factory.createTab(configuration: .init(dataStore: store, profileId: b))

        XCTAssertTrue(tab.wkWebView.configuration.webExtensionController === contextB.extensions.controller)
        XCTAssertFalse(tab.wkWebView.configuration.webExtensionController === contextA.extensions.controller)
        XCTAssertEqual(factory.test_warmPoolCount, 1, "the warm view of A stays available for A")
    }

    func testWarmWebViewOfTheSameProfileIsConsumed() async throws {
        let (factory, cache, cleanup) = try makeFactoryWithProfiles()
        defer { cleanup() }
        let a = TestProfileIds.next()
        cache.pinnedProfileIds = [a]
        let contextA = try cache.context(for: a)
        let store = factory.defaultDataStore()
        await warm(factory, store, profileId: a)

        let tab = factory.createTab(configuration: .init(dataStore: store, profileId: a))

        XCTAssertTrue(tab.wkWebView.configuration.webExtensionController === contextA.extensions.controller)
        XCTAssertEqual(factory.test_warmPoolCount, 0)
    }

    /// An evicted profile is rebuilt with a new extension controller: its old warm view must not serve it.
    func testRebuiltProfileNeverGetsAWarmViewOfItsEvictedController() async throws {
        let (factory, cache, cleanup) = try makeFactoryWithProfiles()
        defer { cleanup() }
        let a = TestProfileIds.next()
        let store = factory.defaultDataStore()
        _ = try cache.context(for: a)
        await warm(factory, store, profileId: a)
        _ = try cache.context(for: TestProfileIds.next())
        _ = try cache.context(for: TestProfileIds.next())
        let rebuiltA = try cache.context(for: a)

        let tab = factory.createTab(configuration: .init(dataStore: store, profileId: a))

        XCTAssertTrue(tab.wkWebView.configuration.webExtensionController === rebuiltA.extensions.controller)
    }

    /// Fills a slot through the factory's real, deferred refill path.
    func testTabsDisablePrivateClickMeasurement() {
        let tab = WKEngineFactory().createTab(configuration: .init(dataStore: nil))
        let enabled = tab.wkWebView.configuration.preferences.value(forKey: "privateClickMeasurementEnabled") as? Bool
        XCTAssertEqual(enabled, false)
    }

    private func warm(_ factory: WKEngineFactory, _ dataStore: WKEngineDataStore, profileId: UUID? = nil) async {
        let before = factory.test_warmPoolCount
        factory.rearmWarmPool(dataStore: dataStore, profileId: profileId)
        _ = await pollUntil(timeout: 1) { factory.test_warmPoolCount != before }
    }

    private func makeFactoryWithProfiles() throws -> (WKEngineFactory, ProfileContextCache, () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("factory-profiles-\(UUID().uuidString)")
        let dbManager = try DatabaseManager(appSupportDirectory: dir.path)
        let factory = WKEngineFactory()
        let cache = ProfileContextCache { profileId in
            try ProfileContext(profileId: profileId, dbManager: dbManager, gapRouter: factory.gapRouter)
        }
        factory.profileContexts = cache
        return (factory, cache, { try? FileManager.default.removeItem(at: dir) })
    }

    func testSuppressWarmPoolDropsAllSlots() async {
        let factory = WKEngineFactory()
        await warm(factory, factory.defaultDataStore())
        await warm(factory, factory.createDataStore(persistent: false, identifier: nil))

        factory.suppressWarmPool = true
        XCTAssertEqual(factory.test_warmPoolCount, 0)

        await warm(factory, factory.defaultDataStore())
        XCTAssertEqual(factory.test_warmPoolCount, 0, "no speculative views while power-constrained")
    }
}
