import Foundation
import GRDB

/// Persists download items in the profile GRDB database.
@MainActor
final class DownloadStore {
    let dbPool: DatabasePool
    /// The profile whose database this is, stamped on the items it inserts and fetches.
    let profileId: UUID?

    init(dbPool: DatabasePool, profileId: UUID? = nil) {
        self.dbPool = dbPool
        self.profileId = profileId
    }

    /// Rows kept by the launch prune; the panel lists the newest 500.
    static let maxRows = 1000

    /// Marks downloads left in flight by the last run as interrupted (for Retry) and drops finished rows beyond `maxRows`. resumeData
    /// stays: paused items need it for Resume, and an interrupted row that has it resumes from the partial bytes.
    func recoverFromCrash() throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE downloads SET state = 'interrupted', endedAt = ? WHERE state = 'inProgress'", arguments: [Date()])
            try db.execute(sql: """
                DELETE FROM downloads
                WHERE state IN ('complete', 'interrupted')
                  AND id NOT IN (SELECT id FROM downloads ORDER BY startedAt DESC LIMIT ?)
                """, arguments: [Self.maxRows])
        }
    }

    func insert(_ item: inout DownloadItem) throws {
        item.profileId = profileId
        try dbPool.write { db in
            try item.insert(db)
        }
    }

    func update(_ item: DownloadItem) throws {
        try dbPool.write { db in
            try item.update(db)
        }
    }

    func fetch(id: Int64) throws -> DownloadItem? {
        var item = try dbPool.read { db in
            try DownloadItem.fetchOne(db, key: id)
        }
        item?.profileId = profileId
        return item
    }

    /// Snapshot columns for panel/search reads: everything except `resumeData`, whose blobs
    /// (KBs per paused row) neither the UI nor the Chrome bridge ever reads. Its presence still
    /// travels, as `hasResumeData`, so the bridge can report `canResume`.
    nonisolated private static let snapshotColumns =
        "id, url, filename, destinationPath, bytesReceived, totalBytes, state, error, " +
        "startedAt, endedAt, mimeType, fileMissing, source, (resumeData IS NOT NULL) AS hasResumeData"

    /// `%`, `_` and the escape character itself are literal in the resulting `LIKE ... ESCAPE '\'` pattern.
    nonisolated private static func containsPattern(_ term: String) -> String {
        let escaped = term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    func fetchAll(limit: Int = 500) throws -> [DownloadItem] {
        try dbPool.read { db in
            let sql = "SELECT \(Self.snapshotColumns) FROM downloads ORDER BY startedAt DESC LIMIT ?"
            return try DownloadItem.fetchAll(db, sql: sql, arguments: [limit])
        }
    }

    func delete(id: Int64) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM downloads WHERE id = ?", arguments: [id])
        }
    }

    /// Search with Chrome's DownloadQuery filters: any of `states`, every `query` term in the url or the
    /// destination path (a "-term" in neither), the exact `url` and destination path `filename`, and `id`.
    /// Returns items newest-first, limited to `limit` (default 1000). Safe off the main actor.
    nonisolated func search(states: [DownloadState] = [], query: [String] = [],
                            url: String? = nil, filename: String? = nil,
                            id: Int64? = nil, limit: Int = 1000) throws -> [DownloadItem] {
        try dbPool.read { db in
            var sql = "SELECT \(Self.snapshotColumns) FROM downloads WHERE 1=1"
            var args: [DatabaseValueConvertible] = []
            if let id {
                sql += " AND id = ?"
                args.append(id)
            }
            if !states.isEmpty {
                sql += " AND state IN (\(Array(repeating: "?", count: states.count).joined(separator: ",")))"
                for state in states { args.append(state.rawValue) }
            }
            for term in query where !term.isEmpty && term != "-" {
                let excluded = term.hasPrefix("-")
                let pattern = Self.containsPattern(excluded ? String(term.dropFirst()) : term)
                sql += " AND \(excluded ? "NOT " : "")(url LIKE ? ESCAPE '\\' OR destinationPath LIKE ? ESCAPE '\\')"
                args.append(pattern)
                args.append(pattern)
            }
            if let url {
                sql += " AND url = ?"
                args.append(url)
            }
            if let filename {
                sql += " AND destinationPath = ?"
                args.append(filename)
            }
            sql += " ORDER BY startedAt DESC LIMIT ?"
            args.append(limit)
            return try DownloadItem.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
    }

    func markFileMissing(id: Int64) throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE downloads SET fileMissing = 1 WHERE id = ?", arguments: [id])
        }
    }
}
