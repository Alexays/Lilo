import Foundation
import GRDB

/// Per-profile persisted favicons keyed by lowercased host. Bounded: every upsert batch evicts
/// rows beyond the newest `maxRows` (by updatedAt), so the table never grows past the cap.
struct FaviconStore: Sendable {
    struct Entry: Equatable, Sendable {
        var host: String
        var dataURL: String
        var dominantColor: String?
    }

    static let maxRows = 500

    private let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    /// Fire-and-forget batch write on the pool's writer queue; a failure only costs a re-download.
    func upsertManyAsync(_ entries: [Entry]) {
        guard !entries.isEmpty else { return }
        dbPool.asyncWrite({ db in
            try Self.upsertOn(db: db, entries: entries)
        }, completion: loggingPersistenceFailure("favicons.upsert"))
    }

    /// Every persisted favicon, oldest-first so LRU cache warming leaves the newest at the head.
    func all() throws -> [Entry] {
        try dbPool.read { db in
            try Row.fetchAll(db, sql: "SELECT host, dataURL, dominantColor FROM favicons ORDER BY updatedAt").map {
                Entry(host: $0["host"], dataURL: $0["dataURL"], dominantColor: $0["dominantColor"])
            }
        }
    }

    /// The persisted favicons of `hosts` (lowercased), in no particular order.
    func entries(forHosts hosts: Set<String>) throws -> [Entry] {
        guard !hosts.isEmpty else { return [] }
        return try dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT host, dataURL, dominantColor FROM favicons WHERE host IN (\(databaseQuestionMarks(count: hosts.count)))",
                arguments: StatementArguments(Array(hosts))
            ).map {
                Entry(host: $0["host"], dataURL: $0["dataURL"], dominantColor: $0["dominantColor"])
            }
        }
    }

    /// Favicons from another browser: never replace one Lilo already has, and dated oldest so the
    /// cap evicts them before any favicon the user's own browsing saved.
    func importMissingAsync(_ entries: [Entry]) {
        guard !entries.isEmpty else { return }
        dbPool.asyncWrite({ db in
            for entry in entries {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO favicons (host, dataURL, dominantColor, updatedAt) VALUES (?, ?, ?, ?)",
                    arguments: [entry.host.lowercased(), entry.dataURL, entry.dominantColor, Date(timeIntervalSince1970: 0)]
                )
            }
            try Self.pruneOn(db: db)
        }, completion: loggingPersistenceFailure("favicons.import"))
    }

    private static func upsertOn(db: Database, entries: [Entry]) throws {
        let now = Date()
        for entry in entries {
            try db.execute(
                sql: "INSERT OR REPLACE INTO favicons (host, dataURL, dominantColor, updatedAt) VALUES (?, ?, ?, ?)",
                arguments: [entry.host.lowercased(), entry.dataURL, entry.dominantColor, now]
            )
        }
        try pruneOn(db: db)
    }

    private static func pruneOn(db: Database) throws {
        guard try (Int.fetchOne(db, sql: "SELECT COUNT(*) FROM favicons") ?? 0) > maxRows else { return }
        // rowid tie-break keeps insertion order stable when a batch shares one timestamp.
        try db.execute(
            sql: """
            DELETE FROM favicons WHERE rowid NOT IN
            (SELECT rowid FROM favicons ORDER BY updatedAt DESC, rowid DESC LIMIT ?)
            """,
            arguments: [maxRows]
        )
    }
}
