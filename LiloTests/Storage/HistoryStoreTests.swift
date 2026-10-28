import XCTest
import GRDB
import os
@testable import Lilo

final class HistoryStoreTests: XCTestCase {
    private var database: TemporaryProfileDatabase!
    private var dbPool: DatabasePool { database.pool }
    private var store: HistoryStore!

    override func setUpWithError() throws {
        database = try TemporaryProfileDatabase()
        store = HistoryStore(dbPool: dbPool)
    }

    override func tearDownWithError() throws {
        store = nil
        database.tearDown()
        database = nil
    }

    // MARK: - Visit upsert (scheduleRecordVisit + flushPendingWrites)
    // `flushPendingWrites()` syncs onto the FIFO `writeQueue`, so it runs after every debounced write: no sleeping or polling.

    func testScheduleRecordVisitInsertsNewEntryWithVisitCountOne() throws {
        let url = "https://example.com/a"
        store.scheduleRecordVisit(url: url, title: "Example A")
        store.flushPendingWrites()

        let entry = try store.entry(forURL: url)
        XCTAssertEqual(entry?.visitCount, 1)
        XCTAssertEqual(entry?.title, "Example A")
    }

    func testAVisitScheduledByAReleasedStoreStillLands() throws {
        let url = "https://example.com/released"
        var released: HistoryStore? = HistoryStore(dbPool: dbPool)
        released?.scheduleRecordVisit(url: url, title: "Released")
        released = nil

        let deadline = Date().addingTimeInterval(5)
        while try store.entry(forURL: url) == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(try store.entry(forURL: url)?.visitCount, 1)
    }

    func testAVisitKeepsTheTerminalThatLastOpenedThePage() throws {
        let url = "http://localhost:5173/"
        store.scheduleRecordVisit(url: url, title: "Dev", openedFrom: "Lilo · fix/sidebar")
        store.flushPendingWrites()
        store.scheduleRecordVisit(url: url, title: "Dev")
        store.flushPendingWrites()
        XCTAssertEqual(try store.entry(forURL: url)?.openedFrom, "Lilo · fix/sidebar", "a plain visit keeps it")

        store.scheduleRecordVisit(url: url, title: "Dev", openedFrom: "site · main")
        store.flushPendingWrites()
        XCTAssertEqual(try store.entry(forURL: url)?.openedFrom, "site · main")
        XCTAssertEqual(try store.search(query: "Dev", limit: 5).first?.openedFrom, "site · main")
    }

    func testScheduleRecordVisitAcrossTwoFlushesIncrementsVisitCountAndUpdatesTitle() throws {
        let url = "https://example.com/b"

        store.scheduleRecordVisit(url: url, title: "First Title")
        store.flushPendingWrites()

        store.scheduleRecordVisit(url: url, title: "Second Title")
        store.flushPendingWrites()

        let entry = try store.entry(forURL: url)
        XCTAssertEqual(entry?.visitCount, 2)
        XCTAssertEqual(entry?.title, "Second Title")
    }

    func testScheduleRecordVisitCoalescesPendingWritesForSameURLBeforeFlush() throws {
        // Two schedules land in the same in-memory batch (no flush between them): the pending
        // merge logic (`(existing?.visitCount ?? 0) + 1`) should still produce visitCount == 2
        // once the single flush lands.
        let url = "https://example.com/c"

        store.scheduleRecordVisit(url: url, title: "First Title")
        store.scheduleRecordVisit(url: url, title: "Second Title")
        store.flushPendingWrites()

        let entry = try store.entry(forURL: url)
        XCTAssertEqual(entry?.visitCount, 2)
        XCTAssertEqual(entry?.title, "Second Title")
    }

    func testScheduleRecordVisitWithEmptyTitlePreservesExistingTitle() throws {
        let url = "https://example.com/d"
        store.scheduleRecordVisit(url: url, title: "Kept Title")
        store.flushPendingWrites()

        store.scheduleRecordVisit(url: url, title: "")
        store.flushPendingWrites()

        let entry = try store.entry(forURL: url)
        XCTAssertEqual(entry?.visitCount, 2)
        XCTAssertEqual(entry?.title, "Kept Title")
    }

    // MARK: - search() and the FTS5 external-content triggers (history_ai / history_au / history_ad)

    func testSearchFindsEntryAfterInsertByTitleToken() throws {
        try store.recordVisit(url: "https://example.com/docs", title: "Swift Programming Guide")

        let results = try store.search(query: "swift", limit: 10)

        XCTAssertEqual(results.map(\.url), ["https://example.com/docs"])
    }

    func testShortQueryMatchesHostAndTitlePrefixesByRank() throws {
        try store.recordVisit(url: "https://www.gizmo.example/", title: "Gizmo")
        try store.recordVisit(url: "https://gimbal.example/", title: "Gimbal")
        try store.recordVisit(url: "https://gimbal.example/", title: "Gimbal")
        try store.recordVisit(url: "https://example.com/", title: "A digit page")
        try store.recordVisit(url: "https://example.org/100%25", title: "Percent")

        XCTAssertEqual(try store.search(query: "gi", limit: 10).map(\.url), ["https://gimbal.example/", "https://www.gizmo.example/"])
        XCTAssertEqual(try store.search(query: "www.", limit: 10).map(\.url), ["https://www.gizmo.example/"])
        XCTAssertEqual(try store.search(query: "www", limit: 10).map(\.url), ["https://www.gizmo.example/"])
        XCTAssertEqual(try store.search(query: "www.Giz", limit: 10).map(\.url), ["https://www.gizmo.example/"])
        XCTAssertTrue(try store.search(query: "%%", limit: 10).isEmpty)
    }

    func testCommonTokenSearchReturnsTheBestRankedMatches() throws {
        let now = Date()
        var visits = (0...HistoryStore.ftsSortLimit).map {
            ImportedVisit(url: "https://github.com/repo\($0)", title: "Repo \($0)", visitCount: 1, lastVisitedAt: now.addingTimeInterval(-Double($0)))
        }
        visits += (0..<50).map {
            ImportedVisit(url: "https://other\($0).example/", title: "Other", visitCount: 100, lastVisitedAt: now)
        }
        visits.append(ImportedVisit(url: "https://github.com/top", title: "Top", visitCount: 9, lastVisitedAt: now.addingTimeInterval(-100_000)))
        visits.append(ImportedVisit(url: "https://github.com/second", title: "Second", visitCount: 5, lastVisitedAt: now.addingTimeInterval(-100_000)))
        try store.importVisits(visits)

        XCTAssertEqual(
            try store.search(query: "github", limit: 4).map(\.url),
            ["https://github.com/top", "https://github.com/second", "https://github.com/repo0", "https://github.com/repo1"]
        )
    }

    func testSearchRanksARecentPageAboveAnOldOneVisitedMoreOften() throws {
        let now = Date()
        try insertHistoryEntry(url: "https://old.example/", title: "Frecency old", visitCount: 20, lastVisitedAt: now.addingTimeInterval(-90 * 86_400))
        try insertHistoryEntry(url: "https://recent.example/", title: "Frecency recent", visitCount: 3, lastVisitedAt: now)
        try insertHistoryEntry(url: "https://stale.example/", title: "Frecency stale", visitCount: 3, lastVisitedAt: now.addingTimeInterval(-7 * 86_400))

        XCTAssertEqual(
            try store.search(query: "frecency", limit: 10).map(\.url),
            ["https://recent.example/", "https://stale.example/", "https://old.example/"]
        )
    }

    func testSearchFindsEntryAfterInsertByURLToken() throws {
        // historyFts indexes both `url` and `title` columns.
        try store.recordVisit(url: "https://uniqueword123.example.com/page", title: "Home")

        let results = try store.search(query: "uniqueword123", limit: 10)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.url, "https://uniqueword123.example.com/page")
    }

    func testSearchFindsUpdatedTitleAndNotStaleTitleAfterUpdate() throws {
        // recordVisit on an existing URL runs the UPDATE path in writeVisits(), which fires
        // history_au: it deletes the old FTS row and re-inserts the new one. If that trigger drifted
        // from the table (e.g. wrong column list), the stale title would remain searchable forever.
        let url = "https://example.com/update-me"
        try store.recordVisit(url: url, title: "OriginalAlphaKeyword")
        try store.recordVisit(url: url, title: "RevisedBetaKeyword")

        let byNewTitle = try store.search(query: "RevisedBetaKeyword", limit: 10)
        XCTAssertEqual(byNewTitle.map(\.url), [url])

        let byOldTitle = try store.search(query: "OriginalAlphaKeyword", limit: 10)
        XCTAssertTrue(byOldTitle.isEmpty, "stale FTS row for the pre-update title must be gone after history_au fires")
    }

    func testSearchDoesNotFindEntryAfterDeleteURL() throws {
        let url = "https://example.com/delete-me"
        try store.recordVisit(url: url, title: "GoneSoonKeyword")
        XCTAssertEqual(try store.search(query: "GoneSoonKeyword", limit: 10).count, 1)

        try store.deleteURL(url)

        XCTAssertTrue(try store.search(query: "GoneSoonKeyword", limit: 10).isEmpty)
    }

    func testSearchDoesNotFindEntryAfterClearAll() throws {
        try store.recordVisit(url: "https://example.com/clear-me", title: "ClearAllKeyword")
        XCTAssertEqual(try store.search(query: "ClearAllKeyword", limit: 10).count, 1)

        try store.clearAll()

        XCTAssertTrue(try store.search(query: "ClearAllKeyword", limit: 10).isEmpty)
    }

    // MARK: - FTS query sanitizing

    func testSearchPrefixMatchesEveryTerm() throws {
        try store.recordVisit(url: "https://example.com/hello", title: "hello world")

        XCTAssertEqual(try store.search(query: "hel wor", limit: 10).map(\.url), ["https://example.com/hello"])
    }

    func testSearchMatchesATermWithEmbeddedDoubleQuotes() throws {
        try store.recordVisit(url: "https://example.com/quoted", title: "say \"hi\" there")

        XCTAssertEqual(try store.search(query: "say \"hi\"", limit: 10).map(\.url), ["https://example.com/quoted"])
    }

    func testSanitizeFTSQuerySpecialCharactersDoNotThrowWhenSearched() throws {
        // `"`, `*`, `-`, `:` are all FTS5 syntax characters; sanitizeFTSQuery must neutralize them
        // (by wrapping every term in an escaped quoted phrase) so search() never surfaces a
        // "malformed MATCH expression" DatabaseError to the omnibox.
        let queries = [
            "\"",
            "*",
            "-",
            ":",
            "🎉",
            "\"*-:🎉 mixed\"bag*-:",
            "site:example.com -exclude \"exact phrase\" wild*card"
        ]

        for query in queries {
            XCTAssertNoThrow(try store.search(query: query, limit: 10), "query \(query) must not throw")
        }
    }

    func testSanitizeFTSQueryFindsTheWordAdjacentToAnEmojiInTitle() throws {
        // A query containing FTS5-special characters alongside a real, indexed word must still
        // find the entry: sanitization shouldn't neuter the query into matching nothing at all.
        try store.recordVisit(url: "https://example.com/emoji", title: "party time 🎉")

        let results = try store.search(query: "party", limit: 10)

        XCTAssertEqual(results.map(\.url), ["https://example.com/emoji"])
    }

    // An emoji-only query finds nothing even though `"🎉"*` is well-formed FTS5: the default
    // `unicode61` tokenizer treats emoji as separators, so they are never indexed. Pinned so a
    // tokenizer change (e.g. `unicode61 categories 'L* N* So'` or ICU) is a deliberate decision.
    func testSanitizeFTSQueryEmojiOnlyQueryDoesNotThrowButFindsNothingDueToTokenizer() throws {
        try store.recordVisit(url: "https://example.com/emoji", title: "party time 🎉")

        // Two characters, so the query reaches FTS instead of the one-character recents shortcut.
        let results = try store.search(query: "🎉🎉", limit: 10)

        XCTAssertTrue(results.isEmpty, "unicode61 does not tokenize emoji as searchable content, this pins that known limitation")
    }

    // MARK: - Change observer

    /// Extensions hear of every visit, with the page's own id and visit count, and of every removal, whoever made it.
    func testEveryWrittenVisitAndRemovalReachesTheObserver() throws {
        let changes = OSAllocatedUnfairLock<[HistoryStore.Change]>(initialState: [])
        store.onChange = { change in changes.withLock { $0.append(change) } }
        let url = "https://example.com/seen"

        store.scheduleRecordVisit(url: url, title: "Seen")
        store.flushPendingWrites()
        try store.recordVisit(url: url, title: "Seen")
        try store.deleteURL("https://example.com/never-visited")
        try store.deleteURL(url)
        try store.clearAll()

        let recorded = changes.withLock { $0 }
        guard recorded.count == 4,
              case let .visited(first) = recorded[0], case let .visited(second) = recorded[1],
              case .removed(false, let removed) = recorded[2], case .removed(true, []) = recorded[3] else {
            return XCTFail("unexpected changes: \(recorded)")
        }
        XCTAssertEqual(first.map(\.visitCount), [1])
        XCTAssertEqual(second.map(\.visitCount), [2])
        XCTAssertEqual(first.first?.id, second.first?.id, "a page keeps its id across visits")
        XCTAssertEqual(removed, [url])
    }

    // MARK: - deleteEntries(from:to:) ("deleteRange")

    func testDeleteEntriesFromToRemovesEntriesWithinRangeInclusive() throws {
        let rangeStart = Date(timeIntervalSince1970: 1_000_000)
        let rangeEnd = Date(timeIntervalSince1970: 2_000_000)

        try insertHistoryEntry(url: "https://before.example.com", lastVisitedAt: rangeStart.addingTimeInterval(-1))
        try insertHistoryEntry(url: "https://at-start.example.com", lastVisitedAt: rangeStart)
        try insertHistoryEntry(url: "https://inside.example.com", lastVisitedAt: rangeStart.addingTimeInterval(500_000))
        try insertHistoryEntry(url: "https://at-end.example.com", lastVisitedAt: rangeEnd)
        try insertHistoryEntry(url: "https://after.example.com", lastVisitedAt: rangeEnd.addingTimeInterval(1))

        let removed = Set(try store.deleteEntries(from: rangeStart, to: rangeEnd))

        XCTAssertEqual(removed, [
            "https://at-start.example.com",
            "https://inside.example.com",
            "https://at-end.example.com"
        ])
        XCTAssertNotNil(try store.entry(forURL: "https://before.example.com"))
        XCTAssertNotNil(try store.entry(forURL: "https://after.example.com"))
    }

    func testDeleteEntriesFromToPreservesURLRevisitedAfterEndDate() throws {
        // HistoryStore keeps one row per URL with only its last visit, so a URL revisited after `endDate` must survive: its
        // lastVisitedAt sits outside the window.
        let rangeStart = Date(timeIntervalSince1970: 1_000_000)
        let rangeEnd = Date(timeIntervalSince1970: 2_000_000)
        let revisitedURL = "https://revisited.example.com"
        let staleURL = "https://stale.example.com"

        try insertHistoryEntry(url: staleURL, lastVisitedAt: rangeStart.addingTimeInterval(1))
        try insertHistoryEntry(url: revisitedURL, lastVisitedAt: rangeEnd.addingTimeInterval(3_600))

        let removed = try store.deleteEntries(from: rangeStart, to: rangeEnd)

        XCTAssertEqual(removed, [staleURL])
        XCTAssertNil(try store.entry(forURL: staleURL))

        let preserved = try XCTUnwrap(try store.entry(forURL: revisitedURL), "URL revisited after endDate must survive deleteEntries(from:to:)")
        XCTAssertEqual(preserved.lastVisitedAt.timeIntervalSince1970, rangeEnd.addingTimeInterval(3_600).timeIntervalSince1970, accuracy: 0.001)
    }

    func testDeleteEntriesFromToWithStartAfterEndIsNoop() throws {
        let url = "https://noop.example.com"
        try insertHistoryEntry(url: url, lastVisitedAt: Date(timeIntervalSince1970: 1_500_000))

        let removed = try store.deleteEntries(
            from: Date(timeIntervalSince1970: 2_000_000),
            to: Date(timeIntervalSince1970: 1_000_000)
        )

        XCTAssertEqual(removed, [])
        XCTAssertNotNil(try store.entry(forURL: url))
    }

    // MARK: - History page

    private let now = Date(timeIntervalSince1970: 1_700_000_000) // Tuesday 2023-11-14 22:13 UTC
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func hoursAgo(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3_600) }

    private func rows(_ filter: HistoryStore.Filter = .init(), before: Date? = nil, minimumRows: Int = 200) throws -> [HistoryStore.DayRow] {
        try store.dayRows(filter: filter, before: before, minimumRows: minimumRows, now: now, calendar: utc).rows
    }

    func testAPageVisitedOnTwoDaysShowsOnBothWithThatDaysCount() throws {
        let url = "https://example.com/a"
        try insertHistoryEntry(url: url, title: "A", lastVisitedAt: hoursAgo(1))
        try insertHistoryEntry(url: url, lastVisitedAt: hoursAgo(2))
        try insertHistoryEntry(url: url, lastVisitedAt: hoursAgo(30))

        let rows = try rows()

        XCTAssertEqual(rows.map(\.url), [url, url])
        XCTAssertEqual(rows.map(\.visits), [2, 1])
        XCTAssertEqual(rows.map(\.dayStart), [utc.startOfDay(for: now), utc.startOfDay(for: hoursAgo(30))])
        XCTAssertEqual(rows[0].lastVisitAt, hoursAgo(1))
    }

    func testRecordedVisitsEachGetARowAndASite() throws {
        let url = "https://www.Example.com:8443/page"
        store.scheduleRecordVisit(url: url, title: "Page")
        store.scheduleRecordVisit(url: url, title: "Page")
        store.flushPendingWrites()

        XCTAssertEqual(try store.visits(forURL: url).count, 2)
        XCTAssertEqual(try rows().first?.host, "example.com:8443")
    }

    func testDayRowsLoadWholeDaysAndContinueFromTheOldestOne() throws {
        try insertHistoryEntry(url: "https://example.com/today-1", lastVisitedAt: hoursAgo(1))
        try insertHistoryEntry(url: "https://example.com/today-2", lastVisitedAt: hoursAgo(2))
        try insertHistoryEntry(url: "https://example.com/older", lastVisitedAt: hoursAgo(80))

        let first = try store.dayRows(filter: .init(), before: nil, minimumRows: 1, now: now, calendar: utc)
        XCTAssertEqual(first.rows.count, 2, "a batch never splits a day")
        XCTAssertEqual(first.nextBefore, utc.startOfDay(for: now))

        let second = try store.dayRows(filter: .init(), before: first.nextBefore, minimumRows: 1, now: now, calendar: utc)
        XCTAssertEqual(second.rows.map(\.url), ["https://example.com/older"])
        let third = try store.dayRows(filter: .init(), before: second.nextBefore, minimumRows: 1, now: now, calendar: utc)
        XCTAssertTrue(third.rows.isEmpty)
        XCTAssertNil(third.nextBefore)
    }

    func testDayRowsFilterByPeriodSiteTerminalAndText() throws {
        try insertHistoryEntry(url: "https://example.com/today", title: "Alpha", lastVisitedAt: hoursAgo(1))
        try insertHistoryEntry(url: "https://example.org/yesterday", title: "Beta", lastVisitedAt: hoursAgo(30))
        try insertHistoryEntry(url: "https://example.org/old", title: "Gamma", lastVisitedAt: hoursAgo(24 * 10))
        store.scheduleRecordVisit(url: "http://localhost:5173/", title: "Dev", openedFrom: "project · main")
        store.flushPendingWrites()
        try dbPool.write { db in
            try db.execute(sql: "UPDATE historyVisit SET visitedAt = ? WHERE openedFrom IS NOT NULL", arguments: [hoursAgo(3)])
        }

        XCTAssertEqual(try rows(.init(period: .yesterday)).map(\.title), ["Beta"])
        XCTAssertEqual(try rows(.init(period: .older)).map(\.title), ["Gamma"])
        XCTAssertEqual(try rows(.init(period: .last7Days)).map(\.title), ["Alpha", "Dev", "Beta"])
        XCTAssertEqual(try rows(.init(host: "example.org")).map(\.title), ["Beta", "Gamma"])
        XCTAssertEqual(try rows(.init(openedFrom: "project · main")).map(\.title), ["Dev"])
        XCTAssertEqual(try rows(.init(query: "gam")).map(\.title), ["Gamma"])
    }

    func testDeletingADayRowKeepsThePageOnItsOtherDays() throws {
        let url = "https://example.com/a"
        try insertHistoryEntry(url: url, visitCount: 5, lastVisitedAt: hoursAgo(1))
        try insertHistoryEntry(url: url, lastVisitedAt: hoursAgo(30))
        let today = try XCTUnwrap(try rows().first)

        let removed = try store.deleteDayRows([(today.pageId, today.dayStart)], openedFrom: nil, calendar: utc)

        XCTAssertEqual(removed, [])
        let entry = try XCTUnwrap(try store.entry(forURL: url))
        XCTAssertEqual(entry.lastVisitedAt, hoursAgo(30))
        XCTAssertEqual(entry.visitCount, 4)
        XCTAssertEqual(try rows().map(\.dayStart), [utc.startOfDay(for: hoursAgo(30))])
    }

    func testDeletingTheLastDayRowRemovesThePage() throws {
        let url = "https://example.com/once"
        try insertHistoryEntry(url: url, lastVisitedAt: hoursAgo(1))
        let row = try XCTUnwrap(try rows().first)

        XCTAssertEqual(try store.deleteDayRows([(row.pageId, row.dayStart)], openedFrom: nil, calendar: utc), [url])
        XCTAssertNil(try store.entry(forURL: url))
    }

    func testDeletingUnderATerminalFilterKeepsTheOtherVisits() throws {
        let url = "http://localhost:5173/"
        store.scheduleRecordVisit(url: url, title: "Dev", openedFrom: "project · main")
        store.flushPendingWrites()
        store.scheduleRecordVisit(url: url, title: "Dev")
        store.flushPendingWrites()
        let row = try XCTUnwrap(try store.dayRows(filter: .init(openedFrom: "project · main"), before: nil, minimumRows: 200).rows.first)
        XCTAssertEqual(row.visits, 1)

        try store.deleteDayRows([(row.pageId, row.dayStart)], openedFrom: "project · main")

        XCTAssertEqual(try store.visits(forURL: url).count, 1)
        XCTAssertNil(try XCTUnwrap(try store.entry(forURL: url)).openedFrom, "no remaining visit came from the terminal")
    }

    func testDeleteSiteRemovesEveryPageOfTheSiteOnly() throws {
        try insertHistoryEntry(url: "https://www.example.com/a", lastVisitedAt: hoursAgo(1))
        try insertHistoryEntry(url: "http://example.com/b", lastVisitedAt: hoursAgo(50))
        try insertHistoryEntry(url: "https://sub.example.com/", lastVisitedAt: hoursAgo(2))

        XCTAssertEqual(Set(try store.deleteSite("example.com")), ["https://www.example.com/a", "http://example.com/b"])
        XCTAssertEqual(try rows().map(\.url), ["https://sub.example.com/"])
    }

    func testDeleteRangeKeepsAPageVisitedBeforeItWithItsOlderDate() throws {
        let url = "https://example.com/a"
        try insertHistoryEntry(url: url, lastVisitedAt: hoursAgo(5))
        try insertHistoryEntry(url: url, lastVisitedAt: hoursAgo(0.5))

        XCTAssertEqual(try store.deleteEntries(from: hoursAgo(1), to: now), [])
        XCTAssertEqual(try store.entry(forURL: url)?.lastVisitedAt, hoursAgo(5))
    }

    func testSidebarSummaryCountsRecentPeriodsAndListsSitesAndTerminals() throws {
        try insertHistoryEntry(url: "https://example.com/a", lastVisitedAt: hoursAgo(1))
        try insertHistoryEntry(url: "https://example.com/a", lastVisitedAt: hoursAgo(2))
        try insertHistoryEntry(url: "https://example.org/b", lastVisitedAt: hoursAgo(30))
        try insertHistoryEntry(url: "https://example.org/c", lastVisitedAt: hoursAgo(24 * 5))
        try insertHistoryEntry(url: "https://example.net/old", lastVisitedAt: hoursAgo(24 * 60))

        let summary = try store.sidebarSummary(now: now, calendar: utc)

        XCTAssertEqual([summary.today, summary.yesterday, summary.last7Days], [1, 1, 3])
        XCTAssertEqual(summary.sites.map(\.host), ["example.com", "example.org"])
        XCTAssertEqual(summary.sites.map(\.visits), [2, 2])
        XCTAssertTrue(summary.terminals.isEmpty)
    }

    func testTheVisitCapPrunesOldVisitsAndThePagesLeftWithout() throws {
        try insertHistoryEntry(url: "https://example.com/oldest", lastVisitedAt: Date(timeIntervalSince1970: 1_000))
        try insertHistoryEntry(url: "https://example.com/kept", lastVisitedAt: now)
        try dbPool.write { db in
            let pageId = try XCTUnwrap(try UUID.fetchOne(db, sql: "SELECT id FROM history WHERE url = 'https://example.com/kept'"))
            try db.execute(sql: """
                WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?)
                INSERT INTO historyVisit (pageId, visitedAt) SELECT ?, datetime(2000000 + i, 'unixepoch') FROM n
                """, arguments: [HistoryStore.maxVisits, pageId])
        }

        store.scheduleRecordVisit(url: "https://example.com/kept", title: "")
        store.flushPendingWrites()

        XCTAssertNil(try store.entry(forURL: "https://example.com/oldest"))
        XCTAssertEqual(try dbPool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM historyVisit") }, HistoryStore.maxVisits)
    }

    // MARK: - Helpers

    /// Goes through the import path to pin an exact `lastVisitedAt`: a recorded visit always gets `Date()`.
    private func insertHistoryEntry(url: String, title: String = "", visitCount: Int = 1, lastVisitedAt: Date) throws {
        try store.importVisits([ImportedVisit(url: url, title: title, visitCount: visitCount, lastVisitedAt: lastVisitedAt)])
    }
}
