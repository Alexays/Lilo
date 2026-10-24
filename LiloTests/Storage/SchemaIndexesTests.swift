import XCTest
import GRDB
@testable import Lilo

@MainActor
final class SchemaIndexesTests: XCTestCase {

    private var database: TemporaryProfileDatabase!
    private var dbPool: DatabasePool { database.pool }

    override func setUpWithError() throws {
        database = try TemporaryProfileDatabase()
    }

    override func tearDownWithError() throws {
        database.tearDown()
        database = nil
    }

    private func indexExists(_ name: String, in db: Database) throws -> Bool {
        try String.fetchOne(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?",
            arguments: [name]
        ) != nil
    }

    func testHistoryRecentIndexIsCompositeDescending() throws {
        try dbPool.read { db in
            // index_xinfo columns: seqno, cid, name, desc, coll, key.
            // Only the two key columns have key=1; the rowid trailer has key=0.
            let keyColumns = try Row
                .fetchAll(db, sql: "PRAGMA index_xinfo(idx_history_visitCount_lastVisitedAt)")
                .filter { ($0["key"] as Int64) == 1 }
            let names = keyColumns.map { $0["name"] as String }
            let descFlags = keyColumns.map { ($0["desc"] as Int64) == 1 }
            XCTAssertEqual(names, ["visitCount", "lastVisitedAt"],
                           "leading sort key must be visitCount, then lastVisitedAt")
            XCTAssertEqual(descFlags, [true, true], "both columns must be DESC to serve the ORDER BY")
        }
    }

    func testDownloadsStartedAtIndexExists() throws {
        try dbPool.read { db in
            XCTAssertTrue(try indexExists("idx_downloads_startedAt", in: db),
                          "downloads startedAt index must exist")
        }
    }
}
