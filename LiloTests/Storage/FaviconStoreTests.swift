import GRDB
import XCTest
@testable import Lilo

final class FaviconStoreTests: XCTestCase {
    private var database: TemporaryProfileDatabase!
    private var store: FaviconStore!

    override func setUpWithError() throws {
        database = try TemporaryProfileDatabase()
        store = FaviconStore(dbPool: database.pool)
    }

    override func tearDownWithError() throws {
        database.tearDown()
        database = nil
        store = nil
    }

    private func persist(_ entries: [FaviconStore.Entry]) throws {
        store.upsertManyAsync(entries)
        // The writer queue is serial, so this empty write lands after the async upsert.
        try database.pool.write { _ in }
    }

    func testUpsertAndAllRoundTrip() throws {
        try persist([
            FaviconStore.Entry(host: "Example.COM", dataURL: "data:one", dominantColor: "#112233"),
            FaviconStore.Entry(host: "example.org", dataURL: "data:two", dominantColor: nil)
        ])

        let all = try store.all()

        XCTAssertEqual(Set(all.map(\.host)), ["example.com", "example.org"])
        XCTAssertEqual(all.first(where: { $0.host == "example.com" })?.dataURL, "data:one")
        XCTAssertEqual(all.first(where: { $0.host == "example.com" })?.dominantColor, "#112233")
        XCTAssertNil(all.first(where: { $0.host == "example.org" })?.dominantColor)
    }

    func testUpsertReplacesExistingHost() throws {
        try persist([FaviconStore.Entry(host: "example.com", dataURL: "data:old", dominantColor: nil)])
        try persist([FaviconStore.Entry(host: "example.com", dataURL: "data:new", dominantColor: "#000000")])

        let all = try store.all()

        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].dataURL, "data:new")
        XCTAssertEqual(all[0].dominantColor, "#000000")
    }

    func testCapEvictsOldestBeyondMaxRows() throws {
        try persist([
            FaviconStore.Entry(host: "old1.example", dataURL: "data:old1", dominantColor: nil),
            FaviconStore.Entry(host: "old2.example", dataURL: "data:old2", dominantColor: nil)
        ])

        try persist((0..<FaviconStore.maxRows).map {
            FaviconStore.Entry(host: "site\($0).example", dataURL: "data:\($0)", dominantColor: nil)
        })

        let hosts = Set(try store.all().map(\.host))
        XCTAssertEqual(hosts.count, FaviconStore.maxRows)
        XCTAssertFalse(hosts.contains("old1.example"))
        XCTAssertFalse(hosts.contains("old2.example"))
        XCTAssertTrue(hosts.contains("site0.example"))
        XCTAssertTrue(hosts.contains("site\(FaviconStore.maxRows - 1).example"))
    }

    func testEntriesForHostsReturnsOnlyThoseHosts() throws {
        try persist([
            FaviconStore.Entry(host: "a.example", dataURL: "data:a", dominantColor: nil),
            FaviconStore.Entry(host: "b.example", dataURL: "data:b", dominantColor: "#010203")
        ])

        XCTAssertEqual(try store.entries(forHosts: ["b.example", "missing.example"]), [
            FaviconStore.Entry(host: "b.example", dataURL: "data:b", dominantColor: "#010203")
        ])
        XCTAssertTrue(try store.entries(forHosts: []).isEmpty)
    }

    @MainActor
    func testRehydrateReadsHostsTheCacheMissesFromTheStore() throws {
        try persist([FaviconStore.Entry(host: "example.com", dataURL: "data:image/png;base64,QUJD", dominantColor: "#112233")])
        var tabs = [Tab(id: UUID(), url: URL(string: "https://example.com/a"), title: "A")]

        FaviconService().rehydrateRestoredTabs(&tabs, store: store)

        XCTAssertEqual(tabs[0].faviconDataURL, "data:image/png;base64,QUJD")
        XCTAssertEqual(tabs[0].faviconDominantColor, "#112233")
    }

    /// The cap evicts by updatedAt, so an icon still in use must refresh its row even when unchanged.
    @MainActor
    func testUnchangedRefetchOfAWarmedFaviconRefreshesItsRow() throws {
        let store = self.store!
        store.importMissingAsync([FaviconStore.Entry(host: "used.example", dataURL: "data:used", dominantColor: nil)])
        let service = FaviconService()
        service.storeForProfile = { _ in store }
        service.warmIfAbsent(host: "used.example", dataURL: "data:used", dominantColor: nil)

        service.seed(host: "used.example", dataURL: "data:used", dominantColor: nil, profileId: UUID())
        try database.pool.write { _ in }

        let updatedAt = try database.pool.read { db in
            try Date.fetchOne(db, sql: "SELECT updatedAt FROM favicons WHERE host = 'used.example'")
        }
        XCTAssertGreaterThan(try XCTUnwrap(updatedAt), Date(timeIntervalSince1970: 0))
    }

    /// The cache is shared by every profile: serving its icon to another profile stores it there too.
    @MainActor
    func testCachedFaviconServedToAnotherProfileLandsInThatProfilesStore() throws {
        let other = try TemporaryProfileDatabase()
        defer { other.tearDown() }
        let otherStore = FaviconStore(dbPool: other.pool)
        let firstProfile = UUID(), secondProfile = UUID()
        let stores = [firstProfile: store!, secondProfile: otherStore]
        let service = FaviconService()
        service.storeForProfile = { stores[$0] }

        service.seed(host: "shared.example", dataURL: "data:shared", dominantColor: "#010203", profileId: firstProfile)
        service.persistCachedIfUnwritten(host: "shared.example", profileId: firstProfile)
        service.persistCachedIfUnwritten(host: "Shared.Example", profileId: secondProfile)
        try database.pool.write { _ in }
        try other.pool.write { _ in }

        XCTAssertEqual(try store.all().map(\.host), ["shared.example"])
        let copied = try otherStore.all()
        XCTAssertEqual(copied.map(\.host), ["shared.example"])
        XCTAssertEqual(copied.first?.dataURL, "data:shared")
        XCTAssertEqual(copied.first?.dominantColor, "#010203")
    }

    func testImportNeverReplacesOrEvictsTheUsersFavicons() throws {
        try persist((0..<FaviconStore.maxRows).map {
            FaviconStore.Entry(host: "site\($0).example", dataURL: "data:\($0)", dominantColor: nil)
        })

        store.importMissingAsync([
            FaviconStore.Entry(host: "site0.example", dataURL: "data:imported", dominantColor: nil),
            FaviconStore.Entry(host: "new.example", dataURL: "data:new", dominantColor: nil)
        ])
        try database.pool.write { _ in }

        let all = try store.all()
        XCTAssertEqual(all.count, FaviconStore.maxRows)
        XCTAssertEqual(all.first { $0.host == "site0.example" }?.dataURL, "data:0", "an existing favicon is kept")
        XCTAssertNil(all.first { $0.host == "new.example" }, "an imported favicon is the first to go at the cap")
    }

}
