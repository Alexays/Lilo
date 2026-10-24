import Foundation
import GRDB

struct ChromeBookmarkRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "chromeBookmarks"

    var id: String
    var parentId: String?
    var index_: Int?
    var url: String?
    var title: String
    var dateAdded: Int?
    var dateGroupModified: Int?
}

/// Manages Chrome-compatible bookmarks stored in the profile database.
final class BookmarkStore: @unchecked Sendable {

    /// The folders the schema seeds: the tree root, the bookmarks bar and other bookmarks.
    private static let rootIds: Set<String> = ["0", "1", "2"]

    private let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - Read

    func get(id: String) throws -> ChromeBookmarkRecord? {
        try dbPool.read { db in
            try ChromeBookmarkRecord.fetchOne(db, key: id)
        }
    }

    func get(ids: [String]) throws -> [ChromeBookmarkRecord] {
        try dbPool.read { db in
            try ChromeBookmarkRecord.fetchAll(db, keys: ids)
        }
    }

    /// Returns all bookmark records flat, siblings in index order; callers nest them.
    func getTree() throws -> [ChromeBookmarkRecord] {
        try dbPool.read { db in
            try ChromeBookmarkRecord.order(Column("index_")).fetchAll(db)
        }
    }

    func getChildren(parentId: String) throws -> [ChromeBookmarkRecord] {
        try dbPool.read { db in
            try ChromeBookmarkRecord
                .filter(Column("parentId") == parentId)
                .order(Column("index_"))
                .fetchAll(db)
        }
    }

    /// Returns the most recently added bookmarks with a URL (excludes folders).
    func getRecent(count: Int) throws -> [ChromeBookmarkRecord] {
        try dbPool.read { db in
            try ChromeBookmarkRecord
                .filter(Column("url") != nil)
                .order(Column("dateAdded").desc)
                .limit(count)
                .fetchAll(db)
        }
    }

    func search(url: String?, title: String?, query: String?) throws -> [ChromeBookmarkRecord] {
        // The text matches literally: `%` and `_` are escaped, not LIKE wildcards.
        func contains(_ text: String) -> String {
            "%" + text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
        }
        return try dbPool.read { db in
            var request = ChromeBookmarkRecord.all()
            if let url { request = request.filter(Column("url").like(contains(url), escape: "\\")) }
            if let title { request = request.filter(Column("title").like(contains(title), escape: "\\")) }
            if let query {
                let pattern = contains(query)
                request = request.filter(Column("url").like(pattern, escape: "\\") || Column("title").like(pattern, escape: "\\"))
            }
            return try request.fetchAll(db)
        }
    }

    // MARK: - Write

    func create(parentId: String?, title: String, url: String?) throws -> ChromeBookmarkRecord {
        try dbPool.write { db in
            let now = Int(Date().timeIntervalSince1970 * 1000)

            let nextIndex: Int
            if let parentId {
                // remove() leaves gaps, so the child count can collide with an existing index.
                nextIndex = try Int.fetchOne(
                    db,
                    sql: "SELECT COALESCE(MAX(index_), -1) + 1 FROM chromeBookmarks WHERE parentId = ?",
                    arguments: [parentId]
                ) ?? 0
            } else {
                nextIndex = 0
            }

            let record = ChromeBookmarkRecord(
                id: UUID().uuidString,
                parentId: parentId,
                index_: nextIndex,
                url: url,
                title: title,
                dateAdded: now,
                dateGroupModified: url == nil ? now : nil
            )
            try record.insert(db)

            if let parentId,
               var parent = try ChromeBookmarkRecord.fetchOne(db, key: parentId) {
                parent.dateGroupModified = now
                try parent.update(db)
            }

            return record
        }
    }

    func move(id: String, parentId: String?, index: Int?) throws -> ChromeBookmarkRecord {
        try dbPool.write { db in
            guard var record = try ChromeBookmarkRecord.fetchOne(db, key: id) else {
                throw DatabaseError(resultCode: .SQLITE_NOTFOUND)
            }

            let oldParentId = record.parentId
            let newParentId = parentId ?? record.parentId
            let targetIndex = index

            if let parentId {
                // UNION (not UNION ALL) so a corrupt parent cycle terminates.
                let movesIntoOwnSubtree = try Bool.fetchOne(
                    db,
                    sql: """
                        WITH RECURSIVE ancestors(id) AS (
                            VALUES(?)
                            UNION
                            SELECT b.parentId FROM chromeBookmarks b JOIN ancestors a ON b.id = a.id
                            WHERE b.parentId IS NOT NULL
                        )
                        SELECT EXISTS(SELECT 1 FROM ancestors WHERE id = ?)
                        """,
                    arguments: [parentId, id]
                ) ?? false
                if movesIntoOwnSubtree {
                    throw DatabaseError(message: "Can't move a bookmark into itself or its own descendant")
                }
            }

            // Renumber by fetch order rather than shifting stored indices: `remove`/`removeTree`
            // leave gaps (and the seeded root has a NULL index_), so stored positions are not dense
            // and a set-based +-1 shift would silently misplace the moved node.
            let oldSiblings = try ChromeBookmarkRecord
                .filter(Column("parentId") == oldParentId)
                .filter(Column("id") != id)
                .order(Column("index_").asc)
                .fetchAll(db)
            for (i, var sibling) in oldSiblings.enumerated() where sibling.index_ != i {
                sibling.index_ = i
                try sibling.update(db)
            }

            var newSiblings = try ChromeBookmarkRecord
                .filter(Column("parentId") == newParentId)
                .filter(Column("id") != id)
                .order(Column("index_").asc)
                .fetchAll(db)
            let insertAt = targetIndex.map { min($0, newSiblings.count) } ?? newSiblings.count
            for i in insertAt..<newSiblings.count where newSiblings[i].index_ != i + 1 {
                newSiblings[i].index_ = i + 1
                try newSiblings[i].update(db)
            }

            record.parentId = newParentId
            record.index_ = insertAt
            try record.update(db)

            return record
        }
    }

    func update(id: String, title: String?, url: String?) throws -> ChromeBookmarkRecord {
        try dbPool.write { db in
            guard var record = try ChromeBookmarkRecord.fetchOne(db, key: id) else {
                throw DatabaseError(message: "Bookmark not found: \(id)")
            }

            if let title { record.title = title }
            if let url { record.url = url }
            try record.update(db)
            return record
        }
    }

    /// Removes a bookmark or an empty folder; like Chrome, refuses a root or a folder with children.
    func remove(id: String) throws {
        guard !Self.rootIds.contains(id) else { throw DatabaseError(message: "Can't modify the root bookmark folders") }
        _ = try dbPool.write { db in
            guard try ChromeBookmarkRecord.filter(Column("parentId") == id).isEmpty(db) else {
                throw DatabaseError(message: "Can't remove non-empty folder (use recursive to force)")
            }
            try ChromeBookmarkRecord.deleteOne(db, key: id)
        }
    }

    /// Removes the node and all its descendants in one recursive-CTE delete.
    func removeTree(id: String) throws {
        guard !Self.rootIds.contains(id) else { throw DatabaseError(message: "Can't modify the root bookmark folders") }
        try dbPool.write { db in
            // Anchor on the literal id (VALUES) so children are deleted even when the root row is
            // already gone. UNION (not UNION ALL) so a corrupt parent cycle terminates.
            try db.execute(
                sql: """
                    WITH RECURSIVE subtree(id) AS (
                        VALUES(?)
                        UNION
                        SELECT b.id FROM chromeBookmarks b JOIN subtree s ON b.parentId = s.id
                    )
                    DELETE FROM chromeBookmarks WHERE id IN (SELECT id FROM subtree)
                    """,
                arguments: [id]
            )
        }
    }
}
