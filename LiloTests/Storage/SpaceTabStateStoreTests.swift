import XCTest
import GRDB
import os
@testable import Lilo

final class SpaceTabStateStoreTests: XCTestCase {
    private var database: TemporaryProfileDatabase!
    private var dbPool: DatabasePool { database.pool }

    override func setUpWithError() throws {
        database = try TemporaryProfileDatabase()
    }

    override func tearDownWithError() throws {
        database.tearDown()
        database = nil
    }

    func testSpaceTabStatesSchema() throws {
        try dbPool.read { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(spaceTabStates)")
                .map { $0["name"] as String }

            XCTAssertEqual(Set(columns), Set(["spaceId", "version", "codec", "state", "updatedAt"]))
        }
    }

    func testFreshProfileSchemaDoesNotCreateOldTabStateTables() throws {
        try dbPool.read { db in
            XCTAssertFalse(try db.tableExists("tabs"))
            XCTAssertFalse(try db.tableExists("tabTreeItems"))
            XCTAssertFalse(try db.tableExists("tabActivationHistory"))
        }
    }

    func testSaveAndLoadTreeState() throws {
        let spaceId = UUID()
        let tabId = UUID()
        let state = SpaceTabState(
            activeTabId: tabId,
            activationHistory: [],
            tree: StoredSidebarTree(
                pinned: [],
                unpinned: [
                    .tab(Self.storedTab(id: tabId, url: "https://example.com", title: "Example"))
                ],
                bookmarked: []
            ),
            viewedAt: [tabId: Date(timeIntervalSince1970: 0)]
        )

        let store = SpaceTabStateStore(dbPool: dbPool)
        try store.saveMany([(spaceId: spaceId, state: state)])

        XCTAssertEqual(try store.load(spaceId: spaceId), state)
    }

    func testUnsupportedCodecThrows() throws {
        let spaceId = UUID()
        try dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO spaceTabStates (spaceId, version, codec, state, updatedAt)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [spaceId.uuidString, 1, "json", Data(), Date()]
            )
        }

        let store = SpaceTabStateStore(dbPool: dbPool)

        XCTAssertThrowsError(try store.load(spaceId: spaceId)) { error in
            XCTAssertEqual(error as? SpaceTabStateStoreError, .unsupportedCodec("json"))
        }
    }

    func testIdenticalSaveDoesNotUpdateTimestamp() throws {
        let spaceId = UUID()
        let state = SpaceTabState(
            activeTabId: nil,
            activationHistory: [],
            tree: .empty
        )
        let store = SpaceTabStateStore(dbPool: dbPool)

        try store.saveMany([(spaceId: spaceId, state: state)])
        let firstTimestamp = try updatedAt(spaceId: spaceId)
        try store.saveMany([(spaceId: spaceId, state: state)])

        XCTAssertEqual(try updatedAt(spaceId: spaceId), firstTimestamp)
    }

    func testDeleteRemovesState() throws {
        let spaceId = UUID()
        let store = SpaceTabStateStore(dbPool: dbPool)

        try store.saveMany([(spaceId: spaceId, state: SpaceTabState(activeTabId: nil, activationHistory: [], tree: .empty))])
        try store.delete(spaceId: spaceId)

        XCTAssertNil(try store.load(spaceId: spaceId))
    }

    func testIdenticalSaveAfterDeleteWritesAgain() throws {
        let spaceId = UUID()
        let state = SpaceTabState(activeTabId: nil, activationHistory: [], tree: .empty)
        let store = SpaceTabStateStore(dbPool: dbPool)

        try store.saveMany([(spaceId: spaceId, state: state)])
        try store.delete(spaceId: spaceId)
        try store.saveMany([(spaceId: spaceId, state: state)])

        XCTAssertEqual(try store.load(spaceId: spaceId), state)
    }

    func testIdenticalSaveIntoAnotherDatabaseWritesThere() throws {
        let spaceId = UUID()
        let state = SpaceTabState(activeTabId: nil, activationHistory: [], tree: .empty)
        let target = try TemporaryProfileDatabase()
        defer { target.tearDown() }

        try SpaceTabStateStore(dbPool: dbPool).saveMany([(spaceId: spaceId, state: state)])
        try SpaceTabStateStore(dbPool: target.pool).saveMany([(spaceId: spaceId, state: state)])

        XCTAssertEqual(try SpaceTabStateStore(dbPool: target.pool).load(spaceId: spaceId), state)
    }

    func testWriteGenerationMovesOnlyWhenARowChanges() throws {
        let spaceId = UUID()
        let store = SpaceTabStateStore(dbPool: dbPool)
        let generation = { SpaceTabStateStore.writeGenerations.withLock { $0[spaceId] ?? 0 } }
        let state = SpaceTabState(activeTabId: nil, activationHistory: [], tree: .empty)

        try store.saveMany([(spaceId: spaceId, state: state)])
        let written = generation()
        XCTAssertGreaterThan(written, 0)
        try store.saveMany([(spaceId: spaceId, state: state)])
        XCTAssertEqual(generation(), written)

        try store.delete(spaceId: spaceId)
        XCTAssertGreaterThan(generation(), written)
    }

    func testCorruptBlobQuarantineFlow() throws {
        let spaceId = UUID()
        let corruptBytes = Data("not a plist".utf8)
        try insertRow(spaceId: spaceId, version: SpaceTabState.currentVersion, codec: "bplist", state: corruptBytes)

        let store = SpaceTabStateStore(dbPool: dbPool)

        XCTAssertThrowsError(try store.load(spaceId: spaceId)) { error in
            guard case .undecodable = error as? SpaceTabStateStoreError else {
                return XCTFail("expected undecodable, got \(error)")
            }
        }

        try store.quarantine(spaceId: spaceId)

        XCTAssertEqual(try quarantinedStates(spaceId: spaceId), [corruptBytes])
        XCTAssertEqual(try rowCount(spaceId: spaceId), 0)
        XCTAssertNil(try store.load(spaceId: spaceId))

        // An empty state never overwrites the recoverable blob: a fresh save persists and
        // round-trips while the quarantined blob still holds the original bytes.
        let tabId = UUID()
        let fresh = SpaceTabState(
            activeTabId: tabId,
            activationHistory: [],
            tree: StoredSidebarTree(
                pinned: [],
                unpinned: [.tab(Self.storedTab(id: tabId, url: "https://example.com", title: "Example"))],
                bookmarked: []
            ),
            viewedAt: [tabId: Date(timeIntervalSince1970: 0)]
        )
        try store.saveMany([(spaceId: spaceId, state: fresh)])
        XCTAssertEqual(try store.load(spaceId: spaceId), fresh)
        XCTAssertEqual(try quarantinedStates(spaceId: spaceId), [corruptBytes])
    }

    func testNewerVersionRowIsUnreadableAndQuarantinable() throws {
        let spaceId = UUID()
        let newerVersion = SpaceTabState.currentVersion + 1
        let validBytes = try SpaceTabStateCodec.encode(SpaceTabState(activeTabId: nil, activationHistory: [], tree: .empty))
        try insertRow(spaceId: spaceId, version: newerVersion, codec: "bplist", state: validBytes)

        let store = SpaceTabStateStore(dbPool: dbPool)

        XCTAssertThrowsError(try store.load(spaceId: spaceId)) { error in
            XCTAssertEqual(error as? SpaceTabStateStoreError, .writtenByNewerVersion(newerVersion))
        }

        try store.quarantine(spaceId: spaceId)

        XCTAssertEqual(try quarantinedStates(spaceId: spaceId), [validBytes])
        XCTAssertEqual(try rowCount(spaceId: spaceId), 0)
        XCTAssertNil(try store.load(spaceId: spaceId))
    }

    func testHealthyBlobIsNotQuarantinedByLoad() throws {
        let spaceId = UUID()
        let state = SpaceTabState(activeTabId: nil, activationHistory: [], tree: .empty)
        let store = SpaceTabStateStore(dbPool: dbPool)

        try store.saveMany([(spaceId: spaceId, state: state)])
        XCTAssertEqual(try store.load(spaceId: spaceId), state)
        XCTAssertEqual(try quarantinedStates(spaceId: spaceId), [])
        XCTAssertEqual(try rowCount(spaceId: spaceId), 1)
    }

    func testQuarantineWithoutRowIsNoOp() throws {
        let store = SpaceTabStateStore(dbPool: dbPool)
        try store.quarantine(spaceId: UUID())
        try dbPool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM spaceTabStatesQuarantine"), 0)
        }
    }

    private func insertRow(spaceId: UUID, version: Int, codec: String, state: Data) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO spaceTabStates (spaceId, version, codec, state, updatedAt)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [spaceId.uuidString, version, codec, state, Date()]
            )
        }
    }

    private func rowCount(spaceId: UUID) throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM spaceTabStates WHERE spaceId = ?",
                arguments: [spaceId.uuidString]
            ) ?? 0
        }
    }

    private func quarantinedStates(spaceId: UUID) throws -> [Data] {
        try dbPool.read { db in
            try Data.fetchAll(
                db,
                sql: "SELECT state FROM spaceTabStatesQuarantine WHERE spaceId = ? ORDER BY quarantinedAt",
                arguments: [spaceId.uuidString]
            )
        }
    }

    private func updatedAt(spaceId: UUID) throws -> Date? {
        try dbPool.read { db in
            try Date.fetchOne(
                db,
                sql: "SELECT updatedAt FROM spaceTabStates WHERE spaceId = ?",
                arguments: [spaceId.uuidString]
            )
        }
    }

    func testDeleteAllExceptSpacesDropsOnlyOtherSpaces() throws {
        let kept = UUID()
        let orphan = UUID()
        let store = SpaceTabStateStore(dbPool: dbPool)
        try store.saveMany([
            (spaceId: kept, state: SpaceTabState(activeTabId: nil, activationHistory: [], tree: .empty)),
            (spaceId: orphan, state: SpaceTabState(activeTabId: nil, activationHistory: [], tree: .empty))
        ])

        try dbPool.write { try SpaceTabStateStore.deleteAllOn(db: $0, exceptSpaces: [kept]) }

        XCTAssertNotNil(try store.load(spaceId: kept))
        XCTAssertNil(try store.load(spaceId: orphan))
    }

    private static func storedTab(id: UUID, url: String?, title: String) -> StoredTab {
        StoredTab(
            id: id,
            url: url,
            title: title,
            faviconDataURL: nil,
            faviconDominantColor: nil,
            isPinned: false,
            isBookmarked: false,
            isClosed: false,
            homeURL: nil,
            homeTitle: nil,
            homeFaviconDataURL: nil,
            homeFaviconDominantColor: nil
        )
    }
}
