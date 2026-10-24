import Foundation
import GRDB
import os

struct SpaceTabStateStore: Sendable {
    private let dbPool: DatabasePool

    /// Bumped once a write or delete of a space's row commits, never before: a state read off the
    /// main actor is still current if the space's generation is unchanged from before the read.
    static let writeGenerations = OSAllocatedUnfairLock(initialState: [UUID: UInt64]())

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    /// Nil when the space has no row; throws `SpaceTabStateStoreError` when the row exists but is unreadable (codec, newer Lilo, bad bytes).
    /// Callers must quarantine the row on a throw, then start fresh: never overwrite it.
    func load(spaceId: UUID) throws -> SpaceTabState? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT version, codec, state FROM spaceTabStates WHERE spaceId = ?",
                arguments: [spaceId.uuidString]
            ) else {
                return nil
            }

            let version: Int = row["version"]
            guard version <= SpaceTabState.currentVersion else {
                throw SpaceTabStateStoreError.writtenByNewerVersion(version)
            }

            let codec: String = row["codec"]
            guard codec == SpaceTabStateCodec.codec else {
                throw SpaceTabStateStoreError.unsupportedCodec(codec)
            }

            let data: Data = row["state"]
            do {
                return SpaceTabStateRepair.repaired(try SpaceTabStateCodec.decode(data))
            } catch {
                throw SpaceTabStateStoreError.undecodable(String(describing: error))
            }
        }
    }

    static let maxQuarantinedRows = 20

    /// Move an unreadable row into `spaceTabStatesQuarantine` and delete the original, so later
    /// saves write fresh state without destroying the evidence. Only the newest `maxQuarantinedRows`
    /// are kept. No-op when the row is absent.
    func quarantine(spaceId: UUID) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO spaceTabStatesQuarantine
                (spaceId, version, codec, state, updatedAt, quarantinedAt)
                SELECT spaceId, version, codec, state, updatedAt, ?
                FROM spaceTabStates WHERE spaceId = ?
                """,
                arguments: [Date(), spaceId.uuidString]
            )
            try db.execute(
                sql: "DELETE FROM spaceTabStates WHERE spaceId = ?",
                arguments: [spaceId.uuidString]
            )
            try db.execute(
                sql: "DELETE FROM spaceTabStatesQuarantine WHERE id NOT IN (SELECT id FROM spaceTabStatesQuarantine ORDER BY id DESC LIMIT ?)",
                arguments: [Self.maxQuarantinedRows]
            )
        }
    }

    func saveMany(_ states: [(spaceId: UUID, state: SpaceTabState)]) throws {
        try dbPool.write { db in
            try Self.writeManyOn(db: db, states: states)
        }
    }

    /// Encodes and upserts `states` on an open writer connection, sync or async: encoding runs on the writer queue, never on the main actor.
    static func writeManyOn(db: Database, states: [(spaceId: UUID, state: SpaceTabState)]) throws {
        for (spaceId, state) in states {
            let repaired = SpaceTabStateRepair.repaired(state)
            let data = try SpaceTabStateCodec.encode(repaired)
            // An unchanged blob is left alone: no write, and the generation stays put.
            try db.execute(
                sql: """
                INSERT INTO spaceTabStates (spaceId, version, codec, state, updatedAt) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(spaceId) DO UPDATE SET
                    version = excluded.version, codec = excluded.codec, state = excluded.state, updatedAt = excluded.updatedAt
                WHERE state IS NOT excluded.state
                """,
                arguments: [spaceId.uuidString, repaired.version, SpaceTabStateCodec.codec, data, Date()]
            )
            guard db.changesCount > 0 else { continue }
            db.afterNextTransaction(onCommit: { _ in writeGenerations.withLock { $0[spaceId, default: 0] += 1 } })
        }
    }

    func delete(spaceId: UUID) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM spaceTabStates WHERE spaceId = ?",
                arguments: [spaceId.uuidString]
            )
            db.afterNextTransaction(onCommit: { _ in Self.writeGenerations.withLock { $0[spaceId, default: 0] += 1 } })
        }
    }

    /// Drops every space's row but `spaceIds`'s, on an open writer connection.
    static func deleteAllOn(db: Database, exceptSpaces spaceIds: Set<UUID>) throws {
        try db.execute(
            sql: "DELETE FROM spaceTabStates WHERE spaceId NOT IN (\(databaseQuestionMarks(count: spaceIds.count)))",
            arguments: StatementArguments(spaceIds.map(\.uuidString))
        )
    }
}

/// The persisted row exists but cannot be read. Every case means the same thing to callers:
/// quarantine the row instead of restoring empty over it.
enum SpaceTabStateStoreError: Error, Equatable {
    case unsupportedCodec(String)
    case writtenByNewerVersion(Int)
    case undecodable(String)
}
