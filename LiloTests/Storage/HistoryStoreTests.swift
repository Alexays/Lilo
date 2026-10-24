import XCTest
import GRDB
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

    // MARK: - Helpers

    /// Goes through the import path to pin an exact `lastVisitedAt`: a recorded visit always gets `Date()`.
    private func insertHistoryEntry(url: String, title: String = "", visitCount: Int = 1, lastVisitedAt: Date) throws {
        try store.importVisits([ImportedVisit(url: url, title: title, visitCount: visitCount, lastVisitedAt: lastVisitedAt)])
    }
}
