import XCTest
import GRDB
@testable import Lilo

@MainActor
final class DownloadStoreTests: XCTestCase {
    private var database: TemporaryProfileDatabase!
    private var store: DownloadStore!

    override func setUp() async throws {
        database = try TemporaryProfileDatabase()
        store = DownloadStore(dbPool: database.pool)
    }

    override func tearDown() async throws {
        store = nil
        database.tearDown()
        database = nil
    }

    func makeItem(url: String = "https://example.com/f.zip") -> DownloadItem {
        DownloadItem(
            id: nil,
            url: url,
            filename: "f.zip",
            destinationPath: "/tmp/f.zip",
            bytesReceived: 0,
            totalBytes: 1024,
            state: .inProgress,
            startedAt: Date(),
            fileMissing: false
        )
    }

    func testInsertAssignsId() throws {
        var item = makeItem()
        XCTAssertNil(item.id)
        try store.insert(&item)
        XCTAssertNotNil(item.id)
    }

    func testFetchReturnsInsertedItem() throws {
        var item = makeItem()
        try store.insert(&item)
        let fetched = try store.fetch(id: item.id!)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.url, "https://example.com/f.zip")
    }

    func testUpdatePersistsChanges() throws {
        var item = makeItem()
        try store.insert(&item)
        item.bytesReceived = 512
        item.state = .complete
        try store.update(item)
        let fetched = try store.fetch(id: item.id!)
        XCTAssertEqual(fetched?.bytesReceived, 512)
        XCTAssertEqual(fetched?.state, .complete)
    }

    func testDeleteRemovesItem() throws {
        var item = makeItem()
        try store.insert(&item)
        try store.delete(id: item.id!)
        let fetched = try store.fetch(id: item.id!)
        XCTAssertNil(fetched)
    }

    func testFetchAllReturnsAllItems() throws {
        var a = makeItem(url: "https://a.example/a.zip")
        var b = makeItem(url: "https://b.example/b.zip")
        try store.insert(&a)
        try store.insert(&b)
        let all = try store.fetchAll()
        XCTAssertEqual(all.count, 2)
    }

    func testRecoverFromCrashKeepsTheNewestFinishedRowsAndEveryPausedOne() throws {
        var paused = makeItem()
        paused.state = .paused
        paused.startedAt = .distantPast
        try store.insert(&paused)
        try database.pool.write { db in
            for offset in 0...DownloadStore.maxRows {
                var item = makeItem()
                item.state = .complete
                item.startedAt = Date(timeIntervalSince1970: TimeInterval(offset))
                try item.insert(db)
            }
        }

        try store.recoverFromCrash()

        let remaining = try store.search(limit: DownloadStore.maxRows * 2)
        XCTAssertEqual(remaining.filter { $0.state == .complete }.count, DownloadStore.maxRows)
        XCTAssertFalse(remaining.contains { $0.startedAt == Date(timeIntervalSince1970: 0) }, "the oldest finished row goes first")
        XCTAssertNotNil(try store.fetch(id: paused.id!), "a paused download outlives the cap")
    }

    func testCrashRecoveryMarksInProgressAsInterrupted() throws {
        var inProgress = makeItem()
        inProgress.state = .inProgress
        try store.insert(&inProgress)

        var paused = makeItem()
        paused.state = .paused
        try store.insert(&paused)

        var complete = makeItem()
        complete.state = .complete
        try store.insert(&complete)

        try store.recoverFromCrash()

        let all = try store.fetchAll()
        let states = Dictionary(grouping: all, by: { $0.state })
        XCTAssertEqual(states[.interrupted]?.count, 1)
        XCTAssertEqual(states[.paused]?.count, 1)
        XCTAssertEqual(states[.complete]?.count, 1)
        let fetchedPaused = try store.fetch(id: paused.id!)
        XCTAssertEqual(fetchedPaused?.state, .paused)
    }

    func testRecoverFromCrashPreservesResumeData() throws {
        var wkItem = makeItem(url: "https://a.example/partial.zip")
        wkItem.source = "wk"
        wkItem.state = .inProgress
        wkItem.resumeData = Data([1, 2, 3])
        try store.insert(&wkItem)

        var pausedItem = makeItem(url: "https://b.example/paused.zip")
        pausedItem.source = "url"
        pausedItem.state = .paused
        pausedItem.resumeData = Data([4, 5, 6])
        try store.insert(&pausedItem)

        try store.recoverFromCrash()

        let fetchedWk = try store.fetch(id: wkItem.id!)
        XCTAssertEqual(fetchedWk?.state, .interrupted)
        XCTAssertEqual(fetchedWk?.resumeData, Data([1, 2, 3]))
        let fetchedPaused = try store.fetch(id: pausedItem.id!)
        XCTAssertEqual(fetchedPaused?.state, .paused)
        XCTAssertEqual(fetchedPaused?.resumeData, Data([4, 5, 6]))
    }

    func testSearchByState() throws {
        var a = makeItem()
        a.state = .complete
        var b = makeItem()
        b.state = .interrupted
        try store.insert(&a)
        try store.insert(&b)

        let completed = try store.search(state: .complete)
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.state, .complete)
    }

    func testSearchByFilename() throws {
        var a = makeItem(url: "https://example.com/report.pdf")
        a.filename = "report.pdf"
        var b = makeItem(url: "https://example.com/photo.jpg")
        b.filename = "photo.jpg"
        try store.insert(&a)
        try store.insert(&b)

        let results = try store.search(filename: "report")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.filename, "report.pdf")
    }

    func testMarkFileMissing() throws {
        var item = makeItem()
        try store.insert(&item)
        try store.markFileMissing(id: item.id!)
        let fetched = try store.fetch(id: item.id!)
        XCTAssertEqual(fetched?.fileMissing, true)
    }

    func testSearchByURLFindsOnlyTheMatchingDownload() throws {
        var a = makeItem(url: "https://files.example.com/archive.tar.gz")
        var b = makeItem(url: "https://other.example/readme.txt")
        try store.insert(&a)
        try store.insert(&b)
        let results = try store.search(url: "files.example.com")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.url, "https://files.example.com/archive.tar.gz")
    }

    func testSearchTreatsLikeWildcardsAsLiterals() throws {
        var literal = makeItem(url: "https://example.com/100%25.zip")
        literal.filename = "report_2024.pdf"
        var other = makeItem(url: "https://example.com/1000.zip")
        other.filename = "reportX2024.pdf"
        try store.insert(&literal)
        try store.insert(&other)

        XCTAssertEqual(try store.search(filename: "report_2024").map(\.id), [literal.id])
        XCTAssertEqual(try store.search(url: "100%").map(\.id), [literal.id])
        XCTAssertEqual(try store.search(query: "_2024").map(\.id), [literal.id])
    }

    func testSearchReportsResumeDataPresenceWithoutTheBlob() throws {
        var resumable = makeItem()
        resumable.state = .interrupted
        resumable.resumeData = Data([1, 2, 3])
        var plain = makeItem()
        plain.state = .interrupted
        try store.insert(&resumable)
        try store.insert(&plain)

        let byId = try Dictionary(uniqueKeysWithValues: store.search(state: .interrupted).map { ($0.id!, $0) })
        XCTAssertEqual(byId[resumable.id!]?.hasResumeData, true)
        XCTAssertNil(byId[resumable.id!]?.resumeData)
        XCTAssertEqual(byId[resumable.id!]?.canResume, true)
        XCTAssertEqual(byId[plain.id!]?.hasResumeData, false)
        XCTAssertEqual(byId[plain.id!]?.canResume, false)
        XCTAssertNil(try store.fetch(id: resumable.id!)?.hasResumeData)
    }

    func testSearchByIdFindsThatDownload() throws {
        var item = makeItem()
        try store.insert(&item)
        let results = try store.search(id: item.id!)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, item.id)
    }
}
