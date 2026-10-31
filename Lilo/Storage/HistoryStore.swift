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

    private struct Visit {
        let at: Date
        let openedFrom: String?
    }

    /// A page's visits since the last flush, oldest first.
    private struct PendingVisit {
        let url: String
        var title: String
        var visits: [Visit]
    }

    private enum Defaults {
        static let writeDebounceInterval: TimeInterval = 1.0
        /// New rows between two cap prunes; the first flush after launch always prunes.
        static let pruneEveryInserts = 500
    }

    private let dbPool: DatabasePool
    private let writeQueue = DispatchQueue(label: "Lilo.HistoryStore.write", qos: .utility)
    private var pendingVisitsByURL: [String: PendingVisit] = [:]
    /// Titles pages set after their visit was written, by URL.
    private var pendingTitlesByURL: [String: String] = [:]
    private var pendingFlushWorkItem: DispatchWorkItem?
    /// Lets `flushPendingWrites()` (run by every read, per omnibox keystroke) skip the queue hop when nothing is pending. Set before a
    /// visit is enqueued and again when it lands; cleared only inside the flush on the queue.
    private let hasPendingVisits = OSAllocatedUnfairLock(initialState: false)
    /// Touched only inside the pool's write closure, which the writer queue serializes.
    private var insertedSinceLastPrune = Defaults.pruneEveryInserts
    private var insertedVisitsSinceLastPrune = Defaults.pruneEveryInserts

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - Recording

    /// Record a page visit. If the URL already exists, increment visitCount and update title.
    func recordVisit(url: String, title: String) throws {
        try writeVisits([PendingVisit(url: url, title: title, visits: [Visit(at: Date(), openedFrom: nil)])])
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
            let pendingTitle = self.pendingTitlesByURL.removeValue(forKey: normalizedURL)
            self.pendingVisitsByURL[normalizedURL] = PendingVisit(
                url: normalizedURL,
                title: [title, existing?.title ?? "", pendingTitle ?? ""].first { !$0.isEmpty } ?? "",
                visits: (existing?.visits ?? []) + [Visit(at: Date(), openedFrom: openedFrom)]
            )
            self.scheduleFlushLocked()
        }
    }

    /// Gives a visited page the title it set after loading, without counting a visit.
    func scheduleUpdateTitle(url: String, title: String) {
        let normalizedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedURL.isEmpty, !title.isEmpty else { return }
        hasPendingVisits.withLock { $0 = true }
        writeQueue.async {
            self.hasPendingVisits.withLock { $0 = true }
            if self.pendingVisitsByURL[normalizedURL] != nil {
                self.pendingVisitsByURL[normalizedURL]?.title = title
            } else {
                self.pendingTitlesByURL[normalizedURL] = title
            }
            self.scheduleFlushLocked()
        }
    }

    /// Merges visits from another browser: keeps the larger visit count and the latest date, so
    /// importing the same history twice changes nothing. Only the newest `maxRows` are kept.
    func importVisits(_ visits: [ImportedVisit]) throws {
        let newest = visits.sorted { $0.lastVisitedAt > $1.lastVisitedAt }.prefix(Self.maxRows)
        try dbPool.write { db in
            let statement = try db.makeStatement(sql: """
                INSERT INTO history (id, url, title, visitCount, lastVisitedAt, host) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(url) DO UPDATE SET
                    visitCount = max(visitCount, excluded.visitCount),
                    lastVisitedAt = max(lastVisitedAt, excluded.lastVisitedAt),
                    title = CASE WHEN excluded.title = '' THEN title ELSE excluded.title END
                RETURNING id
                """)
            // The other browser's last visit only, once: re-importing finds it already there.
            let visitStatement = try db.makeStatement(sql: """
                INSERT INTO historyVisit (pageId, visitedAt) SELECT ?1, ?2
                WHERE NOT EXISTS (SELECT 1 FROM historyVisit WHERE pageId = ?1 AND visitedAt = ?2)
                """)
            for visit in newest {
                guard let pageId = try UUID.fetchOne(statement, arguments: [
                    UUID(), visit.url, visit.title, max(1, visit.visitCount), visit.lastVisitedAt, Self.siteHost(of: visit.url)
                ]) else { continue }
                try visitStatement.execute(arguments: [pageId, visit.lastVisitedAt])
            }
            try db.execute(sql: Self.pruneSQL, arguments: [Self.maxRows - 1])
            try Self.pruneVisits(db)
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
                WHERE name IN (SELECT name FROM sqlite_schema WHERE tbl_name IN ('history', 'historyVisit') OR tbl_name LIKE 'historyFts%')
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

    /// Deletes the visits in `[startDate, endDate]` (`chrome.history.deleteRange`): a page visited outside it survives with its
    /// other visits. Returns the URLs of the pages removed entirely.
    @discardableResult
    func deleteEntries(from startDate: Date, to endDate: Date) throws -> [String] {
        guard startDate <= endDate else { return [] }
        return try deleteVisits(where: "visitedAt >= ? AND visitedAt <= ?", arguments: [startDate, endDate])
    }

    /// Deletes what History page rows stand for: each page's visits on that row's local day, only `openedFrom`'s when given.
    @discardableResult
    func deleteDayRows(_ rows: [(pageId: UUID, dayStart: Date)], openedFrom: String?, calendar: Calendar = .current) throws -> [String] {
        var removed: [String] = []
        // Three bound values a row: chunks stay far below SQLite's variable limit.
        for chunk in stride(from: 0, to: rows.count, by: 300).map({ rows[$0..<min($0 + 300, rows.count)] }) {
            var arguments: StatementArguments = []
            let clauses = chunk.map { row -> String in
                // The next day's start, not 24 hours on: where DST starts at midnight, a day starts at 01:00.
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: row.dayStart).map(calendar.startOfDay) ?? row.dayStart
                arguments += [row.pageId, row.dayStart, dayEnd]
                return "(pageId = ? AND visitedAt >= ? AND visitedAt < ?)"
            }
            var predicate = "(\(clauses.joined(separator: " OR ")))"
            if let openedFrom {
                predicate += " AND openedFrom = ?"
                arguments += [openedFrom]
            }
            removed += try deleteVisits(where: predicate, arguments: arguments)
        }
        return removed
    }

    /// Deletes every page of a site (`siteHost(of:)`), with their visits. Returns their URLs.
    @discardableResult
    func deleteSite(_ host: String) throws -> [String] {
        flushPendingWrites()
        let urls = try dbPool.write { db in try String.fetchAll(db, sql: "DELETE FROM history WHERE host = ? RETURNING url", arguments: [host]) }
        if !urls.isEmpty { onChange?(.removed(allHistory: false, urls: urls)) }
        return urls
    }

    /// Deletes the visits `predicate` (on `historyVisit`) selects, then settles their pages: a page left without visits goes, the
    /// others fall back to their newest remaining visit. Returns the URLs of the pages removed entirely.
    private func deleteVisits(where predicate: String, arguments: StatementArguments) throws -> [String] {
        flushPendingWrites()
        let urls = try dbPool.write { db -> [String] in
            let deleted = try Row.fetchAll(db, sql: "SELECT pageId, COUNT(*) AS count FROM historyVisit WHERE \(predicate) GROUP BY pageId",
                                           arguments: arguments)
            guard !deleted.isEmpty else { return [] }
            try db.execute(sql: "DELETE FROM historyVisit WHERE \(predicate)", arguments: arguments)
            var urls: [String] = []
            for row in deleted {
                let pageId: UUID = row["pageId"]
                if let latest = try Date.fetchOne(db, sql: "SELECT MAX(visitedAt) FROM historyVisit WHERE pageId = ?", arguments: [pageId]) {
                    // Pages older than the visits table count visits it never held: the count only drops, never below one.
                    try db.execute(sql: """
                        UPDATE history SET lastVisitedAt = ?1, visitCount = max(1, visitCount - ?2), openedFrom = (
                            SELECT openedFrom FROM historyVisit WHERE pageId = ?3 AND openedFrom IS NOT NULL ORDER BY visitedAt DESC LIMIT 1
                        ) WHERE id = ?3
                        """, arguments: [latest, row["count"] as Int, pageId])
                } else if let url = try String.fetchOne(db, sql: "DELETE FROM history WHERE id = ? RETURNING url", arguments: [pageId]) {
                    urls.append(url)
                }
            }
            return urls
        }
        if !urls.isEmpty { onChange?(.removed(allHistory: false, urls: urls)) }
        return urls
    }

    // MARK: - History page

    /// A History page row: one page on one local day, over the visits the filter keeps.
    struct DayRow: Sendable {
        let pageId: UUID
        let url: String
        let title: String
        let host: String
        let lastVisitAt: Date
        let visits: Int
        let dayStart: Date
    }

    enum Period: String, Sendable {
        case all, today, yesterday, last7Days, older
    }

    struct Filter: Sendable {
        var query = ""
        var period = Period.all
        var host: String?
        var openedFrom: String?
    }

    struct SidebarSummary: Sendable {
        let today: Int
        let yesterday: Int
        let last7Days: Int
        let sites: [(host: String, visits: Int)]
        let terminals: [(openedFrom: String, visits: Int)]
    }

    /// Rows of whole local days, newest first, from `before` (exclusive) down until at least `minimumRows`; `nextBefore` continues
    /// the list, nil once nothing older matches. Each day is one bounded range of the `visitedAt` index.
    func dayRows(
        filter: Filter, before: Date?, minimumRows: Int, now: Date = Date(), calendar: Calendar = .current
    ) throws -> (rows: [DayRow], nextBefore: Date?) {
        flushPendingWrites()
        let startOfToday = calendar.startOfDay(for: now)
        let daysAgo = { (days: Int) in calendar.date(byAdding: .day, value: -days, to: startOfToday) ?? startOfToday }
        var lower: Date?
        var upper = before
        switch filter.period {
        case .all: break
        case .today: lower = startOfToday
        case .yesterday: lower = daysAgo(1); upper = min(upper ?? startOfToday, startOfToday)
        case .last7Days: lower = daysAgo(6)
        case .older: upper = min(upper ?? daysAgo(6), daysAgo(6))
        }

        var conditions: [String] = []
        var filterArguments: StatementArguments = []
        if let host = filter.host {
            conditions.append("h.host = ?")
            filterArguments += [host]
        }
        if let openedFrom = filter.openedFrom {
            conditions.append("v.openedFrom = ?")
            filterArguments += [openedFrom]
        }
        if !filter.query.trimmingCharacters(in: .whitespaces).isEmpty {
            conditions.append("h.rowid IN (SELECT rowid FROM historyFts WHERE historyFts MATCH ?)")
            filterArguments += [sanitizeFTSQuery(filter.query)]
        }
        if let lower {
            conditions.append("v.visitedAt >= ?")
            filterArguments += [lower]
        }
        let filterSQL = conditions.map { " AND \($0)" }.joined()

        return try dbPool.read { db in
            var rows: [DayRow] = []
            var cursor = upper
            while rows.count < minimumRows {
                var latestArguments = filterArguments
                if let cursor { latestArguments += [cursor] }
                guard let latest = try Date.fetchOne(db, sql: """
                    SELECT v.visitedAt FROM historyVisit v JOIN history h ON h.id = v.pageId
                    WHERE 1\(filterSQL)\(cursor == nil ? "" : " AND v.visitedAt < ?")
                    ORDER BY v.visitedAt DESC LIMIT 1
                    """, arguments: latestArguments) else { return (rows, nil) }
                let dayStart = calendar.startOfDay(for: latest)
                let dayEnd = min(cursor ?? .distantFuture, calendar.date(byAdding: .day, value: 1, to: dayStart) ?? latest)
                var dayArguments = filterArguments
                dayArguments += [dayStart, dayEnd]
                rows += try Row.fetchAll(db, sql: """
                    SELECT h.id, h.url, h.title, h.host, MAX(v.visitedAt) AS lastVisitAt, COUNT(*) AS visits
                    FROM historyVisit v JOIN history h ON h.id = v.pageId
                    WHERE 1\(filterSQL) AND v.visitedAt >= ? AND v.visitedAt < ?
                    GROUP BY v.pageId ORDER BY lastVisitAt DESC
                    """, arguments: dayArguments).map {
                    DayRow(pageId: $0["id"], url: $0["url"], title: $0["title"], host: $0["host"],
                           lastVisitAt: $0["lastVisitAt"], visits: $0["visits"], dayStart: dayStart)
                }
                cursor = dayStart
            }
            return (rows, cursor)
        }
    }

    /// The History page's sidebar: rows in each recent period, then the top 5 sites and terminals of the last 30 days.
    func sidebarSummary(now: Date = Date(), calendar: Calendar = .current) throws -> SidebarSummary {
        flushPendingWrites()
        let startOfToday = calendar.startOfDay(for: now)
        let dayStarts = (0...7).map { calendar.date(byAdding: .day, value: 1 - $0, to: startOfToday) ?? startOfToday }
        let monthAgo = calendar.date(byAdding: .day, value: -30, to: startOfToday) ?? startOfToday
        return try dbPool.read { db in
            // dayStarts[0] is tomorrow: day i spans [dayStarts[i + 1], dayStarts[i]).
            let perDay = try (0..<7).map { day in
                try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT pageId) FROM historyVisit WHERE visitedAt >= ? AND visitedAt < ?",
                                 arguments: [dayStarts[day + 1], dayStarts[day]]) ?? 0
            }
            let sites = try Row.fetchAll(db, sql: """
                SELECT h.host, COUNT(*) AS visits FROM historyVisit v JOIN history h ON h.id = v.pageId
                WHERE v.visitedAt >= ? AND h.host != '' GROUP BY h.host ORDER BY visits DESC, MAX(v.visitedAt) DESC LIMIT 5
                """, arguments: [monthAgo]).map { (host: $0["host"] as String, visits: $0["visits"] as Int) }
            let terminals = try Row.fetchAll(db, sql: """
                SELECT openedFrom, COUNT(*) AS visits FROM historyVisit
                WHERE visitedAt >= ? AND openedFrom IS NOT NULL GROUP BY openedFrom ORDER BY MAX(visitedAt) DESC LIMIT 5
                """, arguments: [monthAgo]).map { (openedFrom: $0["openedFrom"] as String, visits: $0["visits"] as Int) }
            return SidebarSummary(today: perDay[0], yesterday: perDay[1], last7Days: perDay.reduce(0, +), sites: sites, terminals: terminals)
        }
    }

    /// Every recorded visit to `url`, oldest first (`chrome.history.getVisits`).
    func visits(forURL url: String) throws -> [(id: Int64, visitedAt: Date)] {
        flushPendingWrites()
        return try dbPool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT v.id, v.visitedAt FROM historyVisit v JOIN history h ON h.id = v.pageId WHERE h.url = ? ORDER BY v.visitedAt
                """, arguments: [url]).map { (id: $0["id"] as Int64, visitedAt: $0["visitedAt"] as Date) }
        }
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
        let titles = pendingTitlesByURL
        guard !visits.isEmpty || !titles.isEmpty else {
            hasPendingVisits.withLock { $0 = false }
            return
        }

        pendingVisitsByURL.removeAll()
        pendingTitlesByURL.removeAll()

        do {
            try writeVisits(visits, titles: titles)
            // Cleared only after the commit, so a returned flush means every scheduled visit is queryable; a concurrent set landing in this
            // window is re-asserted by its queued block.
            hasPendingVisits.withLock { $0 = false }
        } catch {
            hasPendingVisits.withLock { $0 = true }
            for (url, title) in titles where pendingTitlesByURL[url] == nil && pendingVisitsByURL[url] == nil {
                pendingTitlesByURL[url] = title
            }
            for visit in visits {
                let existing = pendingVisitsByURL[visit.url]
                pendingVisitsByURL[visit.url] = PendingVisit(
                    url: visit.url,
                    title: visit.title.isEmpty ? existing?.title ?? "" : visit.title,
                    visits: visit.visits + (existing?.visits ?? [])
                )
            }
        }
    }

    /// Bounded like FaviconStore: nothing else ever deletes rows, so an uncapped history would
    /// grow for the profile's lifetime and slow every recent/top-sites query with it.
    static let maxRows = 50_000
    /// The History page's journal, bounded the same way: about a year of heavy browsing.
    static let maxVisits = 250_000
    /// Deletes rows older than the `maxRows`-th newest (offset bound to `maxRows - 1`): one walk of
    /// the lastVisitedAt index, and no row at all under the cap. history_ad keeps historyFts in sync.
    private static let pruneSQL = """
        DELETE FROM history WHERE lastVisitedAt < (
            SELECT lastVisitedAt FROM history ORDER BY lastVisitedAt DESC LIMIT 1 OFFSET ?
        )
        """

    private func writeVisits(_ visits: [PendingVisit], titles: [String: String] = [:]) throws {
        let written = try dbPool.write { db in
            let statement = try db.cachedStatement(sql: """
                INSERT INTO history (id, url, title, visitCount, lastVisitedAt, openedFrom, host) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(url) DO UPDATE SET
                    visitCount = visitCount + excluded.visitCount,
                    lastVisitedAt = max(lastVisitedAt, excluded.lastVisitedAt),
                    title = CASE WHEN excluded.title = '' THEN title ELSE excluded.title END,
                    openedFrom = coalesce(excluded.openedFrom, openedFrom)
                RETURNING id, url, title, visitCount, lastVisitedAt, openedFrom
                """)
            let visitStatement = try db.cachedStatement(sql: "INSERT INTO historyVisit (pageId, visitedAt, openedFrom) VALUES (?, ?, ?)")
            var written: [HistoryEntry] = []
            written.reserveCapacity(visits.count)
            for visit in visits {
                guard let last = visit.visits.last, let entry = try HistoryEntry.fetchOne(statement, arguments: [
                    UUID(), visit.url, visit.title, visit.visits.count, last.at,
                    visit.visits.last(where: { $0.openedFrom != nil })?.openedFrom, Self.siteHost(of: visit.url)
                ]) else { continue }
                // An existing row ends above the visit's own count, so an equal total means a new row.
                if entry.visitCount == visit.visits.count { insertedSinceLastPrune += 1 }
                for pageVisit in visit.visits {
                    try visitStatement.execute(arguments: [entry.id, pageVisit.at, pageVisit.openedFrom])
                }
                insertedVisitsSinceLastPrune += visit.visits.count
                written.append(entry)
            }
            let titleStatement = try db.cachedStatement(sql: "UPDATE history SET title = ? WHERE url = ?")
            for (url, title) in titles {
                try titleStatement.execute(arguments: [title, url])
            }

            if insertedSinceLastPrune >= Defaults.pruneEveryInserts {
                try db.execute(sql: Self.pruneSQL, arguments: [Self.maxRows - 1])
                insertedSinceLastPrune = 0
            }
            if insertedVisitsSinceLastPrune >= Defaults.pruneEveryInserts {
                try Self.pruneVisits(db)
                insertedVisitsSinceLastPrune = 0
            }
            return written
        }
        if !written.isEmpty { onChange?(.visited(written)) }
    }

    /// Keeps the newest `maxVisits` visits, then drops the pages left without any.
    private static func pruneVisits(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM historyVisit WHERE visitedAt < (
                SELECT visitedAt FROM historyVisit ORDER BY visitedAt DESC LIMIT 1 OFFSET ?
            )
            """, arguments: [maxVisits - 1])
        guard db.changesCount > 0 else { return }
        try db.execute(sql: "DELETE FROM history WHERE NOT EXISTS (SELECT 1 FROM historyVisit WHERE pageId = history.id)")
    }

    /// The site a URL belongs to: its host, lowercased, port kept, without a leading `www.` (as `hostOf` in the chrome UI).
    static func siteHost(of url: String) -> String {
        guard let components = URLComponents(string: url), var host = components.host?.lowercased() else { return "" }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return components.port.map { "\(host):\($0)" } ?? host
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
