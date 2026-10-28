import Foundation
import GRDB
import os

/// Per-profile store of `WKWebView.interactionState` blobs (back/forward list, scroll, form state) keyed by space and tab, so a relaunch
/// restores tabs to their prior navigation state. The caller bounds the scope (active tab plus a capped recent set).
struct InteractionStateStore: Sendable {
    private let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    /// All persisted blobs for a space, keyed by tab id.
    func load(spaceId: UUID) throws -> [UUID: Data] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT tabId, state FROM tabInteractionStates WHERE spaceId = ?",
                arguments: [spaceId.uuidString]
            )
            var result: [UUID: Data] = [:]
            for row in rows {
                guard let tabId = UUID(uuidString: row["tabId"]) else { continue }
                result[tabId] = row["state"]
            }
            return result
        }
    }

    /// Replace every row for a space with `entries`. Tabs absent from `entries` (closed, evicted, or
    /// beyond the persisted budget) are deleted so the table can't accumulate stale blobs.
    func replace(spaceId: UUID, entries: [UUID: Data]) throws {
        try dbPool.write { db in
            try Self.writeReplaceOn(db: db, databasePath: dbPool.path, spaceId: spaceId, entries: entries)
        }
    }

    /// Content hashes of the rows last written per database file and space, so a persist burst whose
    /// blobs did not change (idle sweeps, tab-activation bursts) skips the write entirely. Keyed by
    /// file path: a space moved to another profile writes the same space id into another database.
    private static let lastPersistedHashes = OSAllocatedUnfairLock(initialState: [String: [UUID: [UUID: Int]]]())

    /// Encode-free replace on an already-open writer connection of the database at `databasePath`,
    /// usable from `dbPool.asyncWrite` (space-switch path, kept off the main actor) and `dbPool.write`
    /// (synchronous shutdown path).
    static func writeReplaceOn(db: Database, databasePath: String, spaceId: UUID, entries: [UUID: Data]) throws {
        // Data.hashValue covers only a prefix of the bytes; archived blobs share their header.
        let hashes = entries.mapValues { data in
            var hasher = Hasher()
            data.withUnsafeBytes { hasher.combine(bytes: $0) }
            return hasher.finalize()
        }
        let previous = lastPersistedHashes.withLock { $0[databasePath]?[spaceId] }
        if previous == hashes { return }

        if let previous {
            // tabId alone is the primary key: a tab moved to another space, which persisted it
            // since, now owns the row, so this space's stale key must not delete it.
            for tabId in previous.keys where hashes[tabId] == nil {
                try db.execute(
                    sql: "DELETE FROM tabInteractionStates WHERE tabId = ? AND spaceId = ?",
                    arguments: [tabId.uuidString, spaceId.uuidString]
                )
            }
        } else {
            try db.execute(
                sql: "DELETE FROM tabInteractionStates WHERE spaceId = ?",
                arguments: [spaceId.uuidString]
            )
        }
        let now = Date()
        var writtenTabIds: [UUID] = []
        for (tabId, data) in entries where previous?[tabId] != hashes[tabId] {
            writtenTabIds.append(tabId)
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO tabInteractionStates (tabId, spaceId, state, updatedAt)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [tabId.uuidString, spaceId.uuidString, data, now]
            )
        }
        let movedTabIds = writtenTabIds
        // The cache must only ever describe committed rows: a rollback (statement or commit
        // failure) leaves `previous` on disk, and `previous` is what the cache still holds.
        db.afterNextTransaction(onCommit: { _ in
            lastPersistedHashes.withLock { cache in
                // The rows written here moved to this space: another space's cache must not skip
                // rewriting them once the tab moves back.
                let otherSpaceIds = cache[databasePath].map { Array($0.keys) } ?? []
                for otherSpaceId in otherSpaceIds where otherSpaceId != spaceId {
                    for tabId in movedTabIds { cache[databasePath]?[otherSpaceId]?.removeValue(forKey: tabId) }
                }
                cache[databasePath, default: [:]][spaceId] = hashes
            }
        })
    }

    /// Drops every space's rows but `spaceIds`'s, on an open writer connection to the database at `databasePath`.
    static func deleteAllOn(db: Database, databasePath: String, exceptSpaces spaceIds: Set<UUID>) throws {
        try db.execute(
            sql: "DELETE FROM tabInteractionStates WHERE spaceId NOT IN (\(databaseQuestionMarks(count: spaceIds.count)))",
            arguments: StatementArguments(spaceIds.map(\.uuidString))
        )
        // The deleted rows must not read as still written: a later identical persist rewrites them.
        db.afterNextTransaction(onCommit: { _ in
            lastPersistedHashes.withLock { hashes in
                hashes[databasePath] = hashes[databasePath]?.filter { spaceIds.contains($0.key) }
            }
        })
    }
}

/// A persisted interaction state kept archived until its tab is activated.
struct ArchivedInteractionState: Sendable {
    let data: Data
}

/// (De)serializes the opaque `WKWebView.interactionState` value to/from `Data`. The concrete type is a
/// WebKit-private `NSSecureCoding` class, so secure coding is disabled on the round trip: there is no
/// public class list to allow, and the blob is read back only from our own profile database.
enum InteractionStateCodec {
    static func encode(_ state: Any) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: state, requiringSecureCoding: false)
    }

    static func decode(_ data: Data) -> Any? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        // A corrupt or outdated archive would otherwise raise an exception that `try?` does not catch.
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        defer { unarchiver.finishDecoding() }
        return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
    }

    /// The last archive of each live state per space and tab. A stashed state never changes, so it is
    /// archived once rather than on every space switch; holding the object keeps its identity valid.
    /// Deleting a space drops its entry.
    static let archives = OSAllocatedUnfairLock(uncheckedState: [UUID: [UUID: (state: AnyObject, data: Data)]]())

    /// Archives multiple already-captured snapshots of a space, dropping any that fail to archive.
    /// Deliberately `nonisolated` (this file carries no actor annotation): callers on background
    /// queues (e.g. `pool.asyncWrite`) call this directly without hopping back to the main actor.
    static func encodeAll(_ states: [UUID: Any], spaceId: UUID) -> [UUID: Data] {
        let previous = archives.withLockUnchecked { $0[spaceId] } ?? [:]
        var current: [UUID: (state: AnyObject, data: Data)] = [:]
        var entries: [UUID: Data] = [:]
        for (tabId, state) in states {
            if let archived = state as? ArchivedInteractionState {
                entries[tabId] = archived.data
                continue
            }
            let object = state as AnyObject
            if let memo = previous[tabId], memo.state === object {
                current[tabId] = memo
                entries[tabId] = memo.data
            } else if let data = encode(state) {
                current[tabId] = (object, data)
                entries[tabId] = data
            }
        }
        archives.withLockUnchecked { $0[spaceId] = current }
        return entries
    }
}
