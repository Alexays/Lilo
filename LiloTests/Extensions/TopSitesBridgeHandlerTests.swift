import XCTest
import GRDB
@testable import Lilo

@MainActor
final class TopSitesBridgeHandlerTests: XCTestCase {
    private var database: TemporaryProfileDatabase!
    private var store: HistoryStore!

    override func setUpWithError() throws {
        database = try TemporaryProfileDatabase()
        store = HistoryStore(dbPool: database.pool)
    }

    override func tearDownWithError() throws {
        store = nil
        database.tearDown()
        database = nil
    }

    func test_get_returns_most_visited_first() async throws {
        // Three visits to popular, one to rare.
        for _ in 0..<3 { try store.recordVisit(url: "https://popular.example", title: "Popular") }
        try store.recordVisit(url: "https://rare.example", title: "Rare")

        let handler = TopSitesBridgeHandler(storeProvider: { [store] _ in store })
        let msg = try XCTUnwrap(BridgeMessage(dictionary: ["action": "topSites.get", "payload": [:]]))
        let result = await handler.handle(msg)
        let sites = try XCTUnwrap(result as? [[String: Any]])

        XCTAssertEqual(sites.first?["url"] as? String, "https://popular.example")
        XCTAssertEqual(sites.first?["title"] as? String, "Popular")
        XCTAssertEqual(sites.count, 2)
    }

    func test_missing_store_returns_error() async throws {
        let handler = TopSitesBridgeHandler(storeProvider: { _ in nil })
        let msg = try XCTUnwrap(BridgeMessage(dictionary: ["action": "topSites.get", "payload": [:]]))
        let result = await handler.handle(msg)
        XCTAssertNotNil(result as? BridgeError)
    }

    /// The service-worker transport passes the caller's registry: its profile's history answers,
    /// whatever profile the window displays.
    func test_get_reads_the_calling_extension_profile_history() async throws {
        let otherDatabase = try TemporaryProfileDatabase()
        let globalDatabase = try TemporaryProfileDatabase(schema: .global)
        defer { otherDatabase.tearDown(); globalDatabase.tearDown() }
        let otherStore = HistoryStore(dbPool: otherDatabase.pool)
        try otherStore.recordVisit(url: "https://other.example", title: "Other")
        try store.recordVisit(url: "https://caller.example", title: "Caller")
        let callerRegistry = ProfileExtensionRegistry(
            profileId: TestProfileIds.next(),
            extensionStorage: ExtensionStorage(profileId: UUID(), dbPool: globalDatabase.pool),
            extensionsBaseDirectory: nil
        )
        let stores = [callerRegistry.profileId: store!]

        let handler = TopSitesBridgeHandler(
            storeProvider: { registry in stores[registry.profileId] ?? otherStore }
        )
        let msg = try XCTUnwrap(BridgeMessage(dictionary: ["action": "topSites.get", "payload": [:]]))
        let result = await handler.handle(msg, registry: callerRegistry)
        let sites = try XCTUnwrap(result as? [[String: Any]])

        XCTAssertEqual(sites.map { $0["url"] as? String }, ["https://caller.example"])
    }
}
