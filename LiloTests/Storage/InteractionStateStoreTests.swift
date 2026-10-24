import XCTest
import GRDB
@testable import Lilo

final class InteractionStateStoreTests: XCTestCase {
    private var database: TemporaryProfileDatabase!
    private var dbPool: DatabasePool { database.pool }

    override func setUpWithError() throws {
        database = try TemporaryProfileDatabase()
    }

    override func tearDownWithError() throws {
        database.tearDown()
        database = nil
    }

    // MARK: - InteractionStateCodec

    func testCodecDecodeOfGarbageDataReturnsNil() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03])
        XCTAssertNil(InteractionStateCodec.decode(garbage))
    }

    // MARK: - InteractionStateStore

    func testReplaceAndLoadRoundTrip() throws {
        let spaceId = UUID()
        let tabA = UUID()
        let tabB = UUID()
        let entries: [UUID: Data] = [
            tabA: InteractionStateCodec.encode("state-a" as NSString)!,
            tabB: InteractionStateCodec.encode("state-b" as NSString)!
        ]

        let store = InteractionStateStore(dbPool: dbPool)
        try store.replace(spaceId: spaceId, entries: entries)

        let loaded = try store.load(spaceId: spaceId)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(InteractionStateCodec.decode(loaded[tabA]!) as? NSString, "state-a" as NSString)
        XCTAssertEqual(InteractionStateCodec.decode(loaded[tabB]!) as? NSString, "state-b" as NSString)
    }

    func testReplaceDropsEntriesMissingFromTheNewSet() throws {
        let spaceId = UUID()
        let staleTabId = UUID()
        let keptTabId = UUID()
        let store = InteractionStateStore(dbPool: dbPool)

        try store.replace(spaceId: spaceId, entries: [
            staleTabId: InteractionStateCodec.encode("stale" as NSString)!,
            keptTabId: InteractionStateCodec.encode("kept" as NSString)!
        ])
        try store.replace(spaceId: spaceId, entries: [
            keptTabId: InteractionStateCodec.encode("kept" as NSString)!
        ])

        let loaded = try store.load(spaceId: spaceId)
        XCTAssertEqual(Set(loaded.keys), [keptTabId])
    }

    func testDeleteAllExceptSpacesDropsOnlyOtherSpaces() throws {
        let kept = UUID()
        let orphan = UUID()
        let store = InteractionStateStore(dbPool: dbPool)
        try store.replace(spaceId: kept, entries: [UUID(): InteractionStateCodec.encode("kept" as NSString)!])
        try store.replace(spaceId: orphan, entries: [UUID(): InteractionStateCodec.encode("orphan" as NSString)!])

        try dbPool.write { try InteractionStateStore.deleteAllOn(db: $0, databasePath: dbPool.path, exceptSpaces: [kept]) }

        XCTAssertEqual(try store.load(spaceId: kept).count, 1)
        XCTAssertTrue(try store.load(spaceId: orphan).isEmpty)
    }

    func testReplaceLeavesARowNowOwnedByAnotherSpace() throws {
        let spaceA = UUID()
        let spaceB = UUID()
        let movedTabId = UUID()
        let stayingTabId = UUID()
        let store = InteractionStateStore(dbPool: dbPool)

        try store.replace(spaceId: spaceA, entries: [
            movedTabId: InteractionStateCodec.encode("a" as NSString)!,
            stayingTabId: InteractionStateCodec.encode("a" as NSString)!
        ])
        try store.replace(spaceId: spaceB, entries: [movedTabId: InteractionStateCodec.encode("b" as NSString)!])
        try store.replace(spaceId: spaceA, entries: [stayingTabId: InteractionStateCodec.encode("a" as NSString)!])

        XCTAssertEqual(Set(try store.load(spaceId: spaceB).keys), [movedTabId])
        XCTAssertEqual(Set(try store.load(spaceId: spaceA).keys), [stayingTabId])
    }

    func testTabMovedAwayAndBackIsRewrittenUnderItsSpace() throws {
        let spaceA = UUID()
        let spaceB = UUID()
        let tabId = UUID()
        let state = InteractionStateCodec.encode("a" as NSString)!
        let store = InteractionStateStore(dbPool: dbPool)

        try store.replace(spaceId: spaceA, entries: [tabId: state])
        try store.replace(spaceId: spaceB, entries: [tabId: state])
        try store.replace(spaceId: spaceA, entries: [tabId: state])
        try store.replace(spaceId: spaceB, entries: [:])

        XCTAssertEqual(try store.load(spaceId: spaceA), [tabId: state])
    }

    func testIdenticalReplaceIntoAnotherDatabaseWritesThere() throws {
        let spaceId = UUID()
        let entries: [UUID: Data] = [UUID(): InteractionStateCodec.encode("state" as NSString)!]
        let target = try TemporaryProfileDatabase()
        defer { target.tearDown() }

        try InteractionStateStore(dbPool: dbPool).replace(spaceId: spaceId, entries: entries)
        try InteractionStateStore(dbPool: target.pool).replace(spaceId: spaceId, entries: entries)

        XCTAssertEqual(try InteractionStateStore(dbPool: target.pool).load(spaceId: spaceId), entries)
    }

    func testIdenticalReplaceAfterDeleteAllWritesAgain() throws {
        let spaceId = UUID()
        let entries: [UUID: Data] = [UUID(): InteractionStateCodec.encode("state" as NSString)!]
        let store = InteractionStateStore(dbPool: dbPool)

        try store.replace(spaceId: spaceId, entries: entries)
        try dbPool.write { try InteractionStateStore.deleteAllOn(db: $0, databasePath: dbPool.path, exceptSpaces: []) }
        try store.replace(spaceId: spaceId, entries: entries)

        XCTAssertEqual(try store.load(spaceId: spaceId), entries)
    }

    func testLoadForUnknownSpaceReturnsEmpty() throws {
        let loaded = try InteractionStateStore(dbPool: dbPool).load(spaceId: UUID())
        XCTAssertTrue(loaded.isEmpty)
    }

    func testDeleteAllWithNoSpacesLeftRemovesEveryRow() throws {
        let spaceId = UUID()
        let tabId = UUID()
        let store = InteractionStateStore(dbPool: dbPool)
        try store.replace(spaceId: spaceId, entries: [tabId: InteractionStateCodec.encode("state" as NSString)!])

        try dbPool.write { try InteractionStateStore.deleteAllOn(db: $0, databasePath: dbPool.path, exceptSpaces: []) }

        XCTAssertTrue(try store.load(spaceId: spaceId).isEmpty)
    }
}
