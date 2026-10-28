import Foundation
import GRDB
import os

/// Persistent history entry for navigation history.
struct HistoryEntry: Sendable, Identifiable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "history"

    let id: UUID
    var url: String
    var title: String
    var visitCount: Int
    var lastVisitedAt: Date
    /// The terminal whose link last opened the page ("folder · branch"), nil otherwise.
    var openedFrom: String?

    enum Columns: String, ColumnExpression {
        case id, url, title, visitCount, lastVisitedAt, openedFrom
    }
}

/// Manages browsing history with GRDB and FTS5 full-text search.
final class HistoryStore: @unchecked Sendable {

    enum Change: Sendable {
        /// Each page's row once its visits are written.
        case visited([HistoryEntry])
        case removed(allHistory: Bool, urls: [String])
    }

    /// Told of every visit written and every removal, whoever made it, on the thread that wrote it. Set once, before any use.
    var onChange: (@Sendable (Change) -> Void)?

    private struct PendingVisit {
        let url: String
        var title: String
        var visitCount: Int
        var lastVisitedAt: Date
        var openedFrom: String?
    }

    private enum Defaults {
        static let writeDebounceInterval: TimeInterval = 1.0
        /// New rows between two cap prunes; the first flush after launch always prunes.
        static let pruneEveryInserts = 500
    }

    private let dbPool: DatabasePool
    private let writeQueue = DispatchQueue(label: "Lilo.HistoryStore.write", qos: .utility)
    private var pendingVisitsByURL: [String: PendingVisit] = [:]
    private var pendingFlushWorkItem: DispatchWorkItem?
    /// Lets `flushPendingWrites()` (run by every read, per omnibox keystroke) skip the queue hop when nothing is pending. Set before a
    /// visit is enqueued and again when it lands; cleared only inside the flush on the queue.
    private let hasPendingVisits = OSAllocatedUnfairLock(initialState: false)
    /// Touched only inside the pool's write closure, which the writer queue serializes.
    private var insertedSinceLastPrune = Defaults.pruneEveryInserts

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - Recording

    /// Record a page visit. If the URL already exists, increment visitCount and update title.
    func recordVisit(url: String, title: String) throws {
        try writeVisits([PendingVisit(url: url, title: title, visitCount: 1, lastVisitedAt: Date())])
    }

    func scheduleRecordVisit(url: String, title: String, openedFrom: String? = nil) {
        let normalizedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedURL.isEmpty else { return }

        hasPendingVisits.withLock { $0 = true }
        // Strong captures: a profile context evicted from its cache still lands its last visits.
        writeQueue.async {
            // Re-assert on the queue: a flush racing between the pre-enqueue set and this block
            // may have cleared the flag before the visit landed.
            self.hasPendingVisits.withLock { $0 = true }
            let existing = self.pendingVisitsByURL[normalizedURL]
            self.pendingVisitsByURL[normalizedURL] = PendingVisit(
                url: normalizedURL,
                title: title.isEmpty ? existing?.title ?? "" : title,
                visitCount: (existing?.visitCount ?? 0) + 1,
                lastVisitedAt: Date(),
                openedFrom: openedFrom ?? existing?.openedFrom
            )
            self.scheduleFlushLocked()
        }
    }

    /// Merges visits from another browser: keeps the larger visit count and the latest date, so
    /// importing the same history twice changes nothing. Only the newest `maxRows` are kept.
    func importVisits(_ visits: [ImportedVisit]) throws {
        let newest = visits.sorted { $0.lastVisitedAt > $1.lastVisitedAt }.prefix(Self.maxRows)
        try dbPool.write { db in
            let statement = try db.makeStatement(sql: """
                INSERT INTO history (id, url, title, visitCount, lastVisitedAt) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(url) DO UPDATE SET
                    visitCount = max(visitCount, excluded.visitCount),
                    lastVisitedAt = max(lastVisitedAt, excluded.lastVisitedAt),
                    title = CASE WHEN excluded.title = '' THEN title ELSE excluded.title END
                """)
            for visit in newest {
                try statement.execute(arguments: [UUID(), visit.url, visit.title, max(1, visit.visitCount), visit.lastVisitedAt])
            }
            try db.execute(sql: Self.pruneSQL, arguments: [Self.maxRows - 1])
        }
    }

    // MARK: - Search

    /// Best-ranked rows a two-character query is matched against.
    static let shortQueryScanLimit = 5000

    /// Most FTS matches a search sorts directly; beyond it, the ranking index is walked instead.
    static let ftsSortLimit = 5000

    /// Search history using FTS5 full-text search.
    /// Returns entries matching the query, by frecency: visits divided by one plus the weeks since the
    /// last one (the command bar's term). Index walks over huge match sets keep the visit-count order.
    func search(query: String, limit: Int) throws -> [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        // A one-character prefix matches most of the table before sorting; the recent list is
        // what the omnibox shows for an empty query anyway.
        if trimmed.count < 2 { return try recentEntries(limit: limit) }
        flushPendingWrites()

        // Short or scheme-like prefixes match nearly every FTS row (https/www/com tokens), and a "www." query ranks most of the table:
        // walking the ranking index stops at the first `limit` hits, and the URL prefix match stays exact.
        let lowered = trimmed.lowercased()
        if lowered.count < 3 || "https://www.".hasPrefix(lowered) || "http://www.".hasPrefix(lowered)
            || "www.".hasPrefix(lowered) || lowered.hasPrefix("www.") {
            let escaped = lowered.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            // Two rare characters can match almost no row, so the walk would cover the whole table:
            // it stops at the best-ranked rows instead. Longer prefixes stop early or name a host: exact.
            let rows = lowered.count < 3
                ? "(SELECT * FROM history INDEXED BY idx_history_visitCount_lastVisitedAt ORDER BY visitCount DESC, lastVisitedAt DESC LIMIT \(Self.shortQueryScanLimit))"
                : "history INDEXED BY idx_history_visitCount_lastVisitedAt"
            return try dbPool.read { db in
                try HistoryEntry.fetchAll(db, sql: """
                    SELECT * FROM \(rows)
                    WHERE url LIKE :prefix ESCAPE '\\' OR url LIKE '%://' || :prefix ESCAPE '\\'
                       OR url LIKE '%://www.' || :prefix ESCAPE '\\'
                       OR title LIKE :prefix ESCAPE '\\' OR title LIKE '% ' || :prefix ESCAPE '\\'
                    ORDER BY visitCount DESC, lastVisitedAt DESC
                    LIMIT :limit
                    """, arguments: ["prefix": escaped + "%", "limit": limit])
            }
        }

        let sanitized = sanitizeFTSQuery(query)

        return try dbPool.read { db in
            let matchCount = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM (SELECT rowid FROM historyFts WHERE historyFts MATCH ? LIMIT \(Self.ftsSortLimit + 1))
                """, arguments: [sanitized]) ?? 0
            // A common token ("git") matches a large share of the table: walking the ranking index
            // stops at the first `limit` matches instead of sorting every matching row.
            let sql = matchCount > Self.ftsSortLimit
                ? """
                SELECT * FROM history INDEXED BY idx_history_visitCount_lastVisitedAt
                WHERE rowid IN (SELECT rowid FROM historyFts WHERE historyFts MATCH ?)
                ORDER BY visitCount DESC, lastVisitedAt DESC
                LIMIT ?
                """
                : """
                SELECT history.*
                FROM history
                JOIN historyFts ON historyFts.rowid = history.rowid
                WHERE historyFts MATCH ?
                ORDER BY history.visitCount / (1.0 + (julianday('now') - julianday(history.lastVisitedAt)) / 7) DESC
                LIMIT ?
                """
            return try HistoryEntry.fetchAll(db, sql: sql, arguments: [sanitized, limit])
        }
    }

    /// Pages in the history and the bytes their table, indexes and full-text index take in the profile database.
    func usage() throws -> (entries: Int, bytes: Int64) {
        flushPendingWrites()
        return try dbPool.read { db in
            let entries = try HistoryEntry.fetchCount(db)
            let bytes = try Int64.fetchOne(db, sql: """
                SELECT COALESCE(SUM(pgsize), 0) FROM dbstat
                WHERE name IN (SELECT name FROM sqlite_schema WHERE tbl_name = 'history' OR tbl_name LIKE 'historyFts%')
                """) ?? 0
            return (entries, bytes)
        }
    }

    /// No flush: it would run a write on the caller (the History menu, on main) for visits under a second old.
    func recentEntries(limit: Int) throws -> [HistoryEntry] {
        try dbPool.read { db in try HistoryEntry.order(HistoryEntry.Columns.lastVisitedAt.desc).limit(limit).fetchAll(db) }
    }

    /// Backs chrome.history.search: entries last visited within `[startDate, endDate]`, newest first,
    /// narrowed by full-text `text` unless it is blank.
    func entries(matching text: String, from startDate: Date, to endDate: Date, limit: Int) throws -> [HistoryEntry] {
        flushPendingWrites()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let match = trimmed.isEmpty ? nil : sanitizeFTSQuery(trimmed)
        return try dbPool.read { db in
            guard let match else {
                return try HistoryEntry
                    .filter(HistoryEntry.Columns.lastVisitedAt >= startDate && HistoryEntry.Columns.lastVisitedAt <= endDate)
                    .order(HistoryEntry.Columns.lastVisitedAt.desc)
                    .limit(limit)
                    .fetchAll(db)
            }
            return try HistoryEntry.fetchAll(db, sql: """
                SELECT history.* FROM history
                JOIN historyFts ON historyFts.rowid = history.rowid
                WHERE historyFts MATCH ? AND history.lastVisitedAt >= ? AND history.lastVisitedAt <= ?
                ORDER BY history.lastVisitedAt DESC
                LIMIT ?
                """, arguments: [match, startDate, endDate, limit])
        }
    }

    /// Most-visited entries first (recency breaks ties). Backs chrome.topSites.get.
    func topVisited(limit: Int) throws -> [HistoryEntry] {
        flushPendingWrites()
        return try dbPool.read { db in
            try HistoryEntry
                .order(HistoryEntry.Columns.visitCount.desc, HistoryEntry.Columns.lastVisitedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Exact-URL lookup (no FTS), backs `chrome.history.getVisits`, which addresses a single URL.
    func entry(forURL url: String) throws -> HistoryEntry? {
        flushPendingWrites()
        return try dbPool.read { db in
            try HistoryEntry.filter(HistoryEntry.Columns.url == url).fetchOne(db)
        }
    }

    /// A typed bare domain goes to the https www site history knows: it skips the
    /// redirect, which WebKit can lose the page on when served from cache to a site with a service worker.
    func knownSiteURL(forTyped url: URL) -> URL {
        guard url.scheme == "https", url.port == nil, url.user() == nil, url.query() == nil, url.fragment() == nil,
              url.path().isEmpty || url.path() == "/",
              let host = url.host()?.lowercased(), !host.hasPrefix("www.") else { return url }
        let site = "https://www.\(host)/"
        // A range on the unique url index ('0' sorts right after '/'); no flush: a pending visit is under a second old.
        let known = (try? dbPool.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM history WHERE url >= ? AND url < ?)",
                              arguments: [site, "https://www.\(host)0"])
        }) ?? false
        return known ? URL(string: site) ?? url : url
    }

    func deleteURL(_ url: String) throws {
        flushPendingWrites()
        let deleted = try dbPool.write { db in try HistoryEntry.filter(HistoryEntry.Columns.url == url).deleteAll(db) }
        if deleted > 0 { onChange?(.removed(allHistory: false, urls: [url])) }
    }

    func clearAll() throws {
        flushPendingWrites()
        _ = try dbPool.write { db in try HistoryEntry.deleteAll(db) }
        onChange?(.removed(allHistory: true, urls: []))
    }

    /// Deletes history entries last visited on or after `date` (for "clear last hour/day/week").
    /// Returns the removed URLs.
    @discardableResult
    func deleteEntries(since date: Date) throws -> [String] {
        try deleteEntries(from: date, to: .distantFuture)
    }

    /// Deletes entries whose last visit falls in `[startDate, endDate]` (`chrome.history.deleteRange`). The store keeps one row per URL,
    /// so a URL revisited after `endDate` survives, matching Chrome's observable effect without a per-visit table.
    @discardableResult
    func deleteEntries(from startDate: Date, to endDate: Date) throws -> [String] {
        flushPendingWrites()
        guard startDate <= endDate else { return [] }
        let urls = try dbPool.write { db in
            let predicate = HistoryEntry.Columns.lastVisitedAt >= startDate && HistoryEntry.Columns.lastVisitedAt <= endDate
            let urls = try String.fetchAll(db, HistoryEntry.filter(predicate).select(HistoryEntry.Columns.url))
            try HistoryEntry.filter(predicate).deleteAll(db)
            return urls
        }
        if !urls.isEmpty { onChange?(.removed(allHistory: false, urls: urls)) }
        return urls
    }

    func flushPendingWrites() {
        guard hasPendingVisits.withLock({ $0 }) else { return }
        writeQueue.sync { flushPendingWritesLocked() }
    }

    private func scheduleFlushLocked() {
        pendingFlushWorkItem?.cancel()
        let workItem = DispatchWorkItem { self.flushPendingWritesLocked() }
        pendingFlushWorkItem = workItem
        writeQueue.asyncAfter(deadline: .now() + Defaults.writeDebounceInterval, execute: workItem)
    }

    private func flushPendingWritesLocked() {
        pendingFlushWorkItem?.cancel()
        pendingFlushWorkItem = nil

        let visits = Array(pendingVisitsByURL.values)
        guard !visits.isEmpty else {
            hasPendingVisits.withLock { $0 = false }
            return
        }

        pendingVisitsByURL.removeAll()

        do {
            try writeVisits(visits)
            // Cleared only after the commit, so a returned flush means every scheduled visit is queryable; a concurrent set landing in this
            // window is re-asserted by its queued block.
            hasPendingVisits.withLock { $0 = false }
        } catch {
            hasPendingVisits.withLock { $0 = true }
            for visit in visits {
                let existing = pendingVisitsByURL[visit.url]
                pendingVisitsByURL[visit.url] = PendingVisit(
                    url: visit.url,
                    title: visit.title.isEmpty ? existing?.title ?? "" : visit.title,
                    visitCount: visit.visitCount + (existing?.visitCount ?? 0),
                    lastVisitedAt: max(visit.lastVisitedAt, existing?.lastVisitedAt ?? .distantPast),
                    openedFrom: existing?.openedFrom ?? visit.openedFrom
                )
            }
        }
    }

    /// Bounded like FaviconStore: nothing else ever deletes rows, so an uncapped history would
    /// grow for the profile's lifetime and slow every recent/top-sites query with it.
    static let maxRows = 50_000
    /// Deletes rows older than the `maxRows`-th newest (offset bound to `maxRows - 1`): one walk of
    /// the lastVisitedAt index, and no row at all under the cap. history_ad keeps historyFts in sync.
    private static let pruneSQL = """
        DELETE FROM history WHERE lastVisitedAt < (
            SELECT lastVisitedAt FROM history ORDER BY lastVisitedAt DESC LIMIT 1 OFFSET ?
        )
        """

    private func writeVisits(_ visits: [PendingVisit]) throws {
        let written = try dbPool.write { db in
            let statement = try db.cachedStatement(sql: """
                INSERT INTO history (id, url, title, visitCount, lastVisitedAt, openedFrom) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(url) DO UPDATE SET
                    visitCount = visitCount + excluded.visitCount,
                    lastVisitedAt = max(lastVisitedAt, excluded.lastVisitedAt),
                    title = CASE WHEN excluded.title = '' THEN title ELSE excluded.title END,
                    openedFrom = coalesce(excluded.openedFrom, openedFrom)
                RETURNING id, url, title, visitCount, lastVisitedAt, openedFrom
                """)
            var written: [HistoryEntry] = []
            written.reserveCapacity(visits.count)
            for visit in visits {
                guard let entry = try HistoryEntry.fetchOne(
                    statement, arguments: [UUID(), visit.url, visit.title, visit.visitCount, visit.lastVisitedAt, visit.openedFrom]
                ) else { continue }
                // An existing row ends above the visit's own count, so an equal total means a new row.
                if entry.visitCount == visit.visitCount { insertedSinceLastPrune += 1 }
                written.append(entry)
            }

            guard insertedSinceLastPrune >= Defaults.pruneEveryInserts else { return written }
            try db.execute(sql: Self.pruneSQL, arguments: [Self.maxRows - 1])
            insertedSinceLastPrune = 0
            return written
        }
        onChange?(.visited(written))
    }

    /// Each term becomes a quoted prefix phrase, so FTS5 syntax characters in a query match literally.
    private func sanitizeFTSQuery(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " ")
    }
}
