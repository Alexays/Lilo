import XCTest
import GRDB
@testable import Lilo

final class HistoryImportTests: XCTestCase {
    private var path: String!
    private var pool: DatabasePool!
    private var store: HistoryStore!

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + UUID().uuidString + ".db"
        pool = try DatabasePool(path: path)
        try Migrations.migrateProfile(pool)
        store = HistoryStore(dbPool: pool)
    }

    override func tearDownWithError() throws {
        store = nil; pool = nil
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    func testImportKeepsCountsAndDatesAndIsIdempotent() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let visits = [ImportedVisit(url: "https://a.example/", title: "A", visitCount: 7, lastVisitedAt: date)]
        try store.importVisits(visits)
        try store.importVisits(visits)
        let entry = try XCTUnwrap(try store.entry(forURL: "https://a.example/"))
        XCTAssertEqual(entry.visitCount, 7)
        XCTAssertEqual(entry.lastVisitedAt.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(try store.search(query: "A", limit: 5).count, 1, "FTS triggers index imported rows")
    }

    func testImportKeepsOnlyTheNewestRows() throws {
        let base = Date(timeIntervalSince1970: 1_600_000_000)
        let visits = (0..<(HistoryStore.maxRows + 10)).map {
            ImportedVisit(url: "https://h\($0).example/", title: "", visitCount: 1, lastVisitedAt: base.addingTimeInterval(Double($0)))
        }
        try store.recordVisit(url: "https://local.example/", title: "")
        try store.importVisits(visits)
        XCTAssertNil(try store.entry(forURL: "https://h0.example/"))
        XCTAssertNil(try store.entry(forURL: "https://h10.example/"), "the oldest imported row makes room for the existing one")
        XCTAssertNotNil(try store.entry(forURL: "https://h11.example/"))
        XCTAssertNotNil(try store.entry(forURL: "https://local.example/"))
        XCTAssertNotNil(try store.entry(forURL: "https://h\(HistoryStore.maxRows + 9).example/"))
        XCTAssertEqual(try pool.read { try HistoryEntry.fetchCount($0) }, HistoryStore.maxRows)
    }
}
