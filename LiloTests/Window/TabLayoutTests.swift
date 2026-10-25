import XCTest
@testable import Lilo

/// Where the tabs sit, and where the address goes when nobody chose.
@MainActor
final class TabLayoutTests: XCTestCase {
    private var database: TemporaryProfileDatabase?
    private var savedDefaults: [String: Any?] = [:]
    private let cacheKeys = ["cachedTabPosition", "cachedAddressPlacement"]

    override func setUp() {
        super.setUp()
        for key in cacheKeys { savedDefaults[key] = UserDefaults.lilo.object(forKey: key) }
    }

    override func tearDown() {
        for (key, value) in savedDefaults { UserDefaults.lilo.set(value, forKey: key) }
        database?.tearDown()
        database = nil
        super.tearDown()
    }

    func testDefaultsToLeftWithTheAddressInTheTabs() throws {
        XCTAssertEqual(try makeSettingsStore().tabLayout, TabLayout(position: .left, address: .tabs))
    }

    func testAddressFollowsThePositionUntilChosen() throws {
        let store = try makeSettingsStore()
        let expected: [TabPosition: AddressPlacement] = [.left: .tabs, .right: .page, .top: .tabs, .bottom: .page]
        for (position, address) in expected {
            store.set("tabPosition", value: position.rawValue)
            XCTAssertEqual(store.tabLayout, TabLayout(position: position, address: address))
        }
    }

    func testAChosenAddressStays() throws {
        let store = try makeSettingsStore()
        store.set("tabPosition", value: "bottom")
        store.set("addressPlacement", value: "tabs")
        XCTAssertEqual(store.tabLayout.address, .tabs)
    }

    func testOnTheRightTheAddressStaysAboveThePage() throws {
        let store = try makeSettingsStore()
        store.set("tabPosition", value: "right")
        store.set("addressPlacement", value: "tabs")
        XCTAssertEqual(store.tabLayout.address, .page)
    }

    func testUnknownValuesFallBack() throws {
        let store = try makeSettingsStore()
        store.set("tabPosition", value: "diagonal")
        store.set("addressPlacement", value: "nowhere")
        XCTAssertEqual(store.tabLayout, .default)
    }

    func testCacheRoundTrips() {
        let layout = TabLayout(position: .bottom, address: .tabs)
        layout.cache()
        XCTAssertEqual(TabLayout.cached, layout)
    }

    private func makeSettingsStore() throws -> SettingsStore {
        let database = try TemporaryProfileDatabase(schema: .global)
        self.database = database
        return SettingsStore(dbPool: database.pool)
    }
}
