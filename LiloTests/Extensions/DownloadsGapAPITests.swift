import XCTest
import GRDB
@testable import Lilo

@MainActor
final class DownloadsGapAPITests: XCTestCase {
    private var handler: DownloadsBridgeHandler!
    private var database: TemporaryProfileDatabase!
    private var store: DownloadStore!
    private var manager: DownloadManager!

    override func setUp() async throws {
        database = try TemporaryProfileDatabase()
        store = DownloadStore(dbPool: database.pool)
        manager = DownloadManager(dockController: nil)
        manager.setStore(store)
        handler = DownloadsBridgeHandler(
            managerProvider: { [weak manager] in manager },
            storeProvider: { [store] _ in store }
        )
    }

    override func tearDown() async throws {
        handler = nil
        manager = nil
        store = nil
        database.tearDown()
        database = nil
    }

    func testHandledActionsContainsDownloadNamespace() {
        XCTAssertTrue(handler.gapActions.contains("downloads.download"))
        XCTAssertTrue(handler.gapActions.contains("downloads.search"))
        XCTAssertTrue(handler.gapActions.contains("downloads.pause"))
        XCTAssertTrue(handler.gapActions.contains("downloads.resume"))
        XCTAssertTrue(handler.gapActions.contains("downloads.cancel"))
        XCTAssertTrue(handler.gapActions.contains("downloads.erase"))
    }

    func testSearchReturnsAllItems() async throws {
        var item = DownloadItem(
            id: nil, url: "https://example.com/test.zip", filename: "test.zip",
            destinationPath: "/tmp/test.zip", bytesReceived: 100, totalBytes: 100,
            state: .complete, startedAt: Date(), fileMissing: false
        )
        try store.insert(&item)

        let msg = makeBridgeMessage(action: "downloads.search", payload: [:])
        let result = await handler.handle(msg)

        let items = result as? [[String: Any]]
        XCTAssertEqual(items?.count, 1)
        XCTAssertEqual(items?.first?["id"] as? Int64, item.id)
        XCTAssertEqual(items?.first?["state"] as? String, "complete")
        XCTAssertEqual(items?.first?["filename"] as? String, "/tmp/test.zip")
        XCTAssertEqual(items?.first?["exists"] as? Bool, true)
        XCTAssertEqual(items?.first?["danger"] as? String, "safe")
    }

    func testSearchFiltersByState() async throws {
        var a = DownloadItem(
            id: nil, url: "https://example.com/a.zip", filename: "a.zip",
            destinationPath: "/tmp/a.zip", bytesReceived: 0, totalBytes: 100,
            state: .inProgress, startedAt: Date(), fileMissing: false
        )
        var b = DownloadItem(
            id: nil, url: "https://example.com/b.zip", filename: "b.zip",
            destinationPath: "/tmp/b.zip", bytesReceived: 100, totalBytes: 100,
            state: .complete, startedAt: Date(), fileMissing: false
        )
        try store.insert(&a)
        try store.insert(&b)

        let msg = makeBridgeMessage(action: "downloads.search", payload: ["state": "complete"])
        let result = await handler.handle(msg)

        let items = result as? [[String: Any]]
        XCTAssertEqual(items?.count, 1)
        let firstId = items?.first?["id"] as? Int64
        XCTAssertEqual(firstId, b.id)
    }

    func testEraseReturnsRemovedIds() async throws {
        var item = DownloadItem(
            id: nil, url: "https://example.com/c.zip", filename: "c.zip",
            destinationPath: "/tmp/c.zip", bytesReceived: 100, totalBytes: 100,
            state: .complete, startedAt: Date(), fileMissing: false
        )
        try store.insert(&item)

        let msg = makeBridgeMessage(action: "downloads.erase", payload: ["id": item.id!])
        let result = await handler.handle(msg)

        XCTAssertEqual(result as? [Int64], [item.id!])
        let fetched = try store.fetch(id: item.id!)
        XCTAssertNil(fetched)
    }

    func testDownloadWithInvalidURLReturnsError() async {
        let msg = makeBridgeMessage(action: "downloads.download", payload: [:])
        let result = await handler.handle(msg)
        XCTAssertEqual((result as? BridgeError)?.message, "Invalid URL")
    }

    func testSearchReportsCanResumeForInterruptedItemWithResumeData() async throws {
        var item = DownloadItem(
            id: nil, url: "https://example.com/e.zip", filename: "e.zip",
            destinationPath: "/tmp/e.zip", bytesReceived: 20, totalBytes: 100,
            state: .interrupted, resumeData: Data([1, 2, 3]), startedAt: Date(), fileMissing: false
        )
        try store.insert(&item)

        let msg = makeBridgeMessage(action: "downloads.search", payload: ["state": "interrupted"])
        let items = await handler.handle(msg) as? [[String: Any]]

        XCTAssertEqual(items?.first?["canResume"] as? Bool, true)
    }

    func testActionsFailWithoutADownloadManager() async {
        let orphan = DownloadsBridgeHandler(managerProvider: { nil }, storeProvider: { [store] _ in store })
        for (action, payload) in [
            ("downloads.download", ["url": "https://example.com/f.zip"]),
            ("downloads.pause", ["id": 1]),
            ("downloads.resume", ["id": 1]),
            ("downloads.cancel", ["id": 1])
        ] as [(String, [String: Any])] {
            let result = await orphan.handle(makeBridgeMessage(action: action, payload: payload))
            XCTAssertNotNil(result as? BridgeError, action)
        }
    }

    func testCancelAcceptsChromeDownloadIdParameter() async throws {
        var item = DownloadItem(
            id: nil, url: "https://example.com/d.zip", filename: "d.zip",
            destinationPath: "/tmp/d.zip", bytesReceived: 20, totalBytes: 100,
            state: .inProgress, startedAt: Date(), fileMissing: false
        )
        try store.insert(&item)

        let msg = makeBridgeMessage(action: "downloads.cancel", payload: ["downloadId": item.id!])
        _ = await handler.handle(msg)

        let updated = try store.fetch(id: item.id!)
        XCTAssertEqual(updated?.state, .interrupted)
    }

    func testPrivateSpaceDownloadsAreHiddenFromExtensions() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gap-downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        manager.downloadsFolderProvider = { folder }
        await manager.saveData(Data([1]), suggestedFilename: "private.bin", mimeType: "", originatingURL: URL(string: "https://example.com/p")!, privateSpaceId: UUID()).value
        let privateId = try XCTUnwrap(store.search().first?.id)

        let found = await handler.handle(makeBridgeMessage(action: "downloads.search", payload: [:]))
        let erased = await handler.handle(makeBridgeMessage(action: "downloads.erase", payload: ["id": privateId]))
        let opened = await handler.handle(makeBridgeMessage(action: "downloads.open", payload: ["downloadId": privateId]))

        XCTAssertEqual((found as? [[String: Any]])?.count, 0)
        XCTAssertEqual(erased as? [Int64], [])
        XCTAssertNotNil(opened as? BridgeError)
        XCTAssertNotNil(try store.fetch(id: privateId))
    }

    func testAnInactiveProfileCanSearchButNotChangeItsDownloads() async throws {
        let otherDatabase = try TemporaryProfileDatabase()
        defer { otherDatabase.tearDown() }
        let otherStore = DownloadStore(dbPool: otherDatabase.pool)
        var item = DownloadItem(
            id: nil, url: "https://example.com/g.zip", filename: "g.zip",
            destinationPath: "/tmp/g.zip", bytesReceived: 100, totalBytes: 100,
            state: .complete, startedAt: Date(), fileMissing: false
        )
        try otherStore.insert(&item)
        let otherHandler = DownloadsBridgeHandler(
            managerProvider: { [manager] in manager },
            storeProvider: { _ in otherStore }
        )

        let found = await otherHandler.handle(makeBridgeMessage(action: "downloads.search", payload: [:]))
        let erased = await otherHandler.handle(makeBridgeMessage(action: "downloads.erase", payload: ["id": item.id!]))

        XCTAssertEqual((found as? [[String: Any]])?.count, 1)
        XCTAssertNotNil(erased as? BridgeError)
        XCTAssertNotNil(try otherStore.fetch(id: item.id!))
    }

    // MARK: - Helpers

    private func makeBridgeMessage(action: String, payload: [String: Any]) -> BridgeMessage {
        BridgeMessage(dictionary: ["action": action, "payload": payload])!
    }

    func testAcceptDangerFailsAsChromeDoesForADownloadThatIsNotDangerous() async throws {
        var running = DownloadItem(
            id: nil, url: "https://example.com/a.zip", filename: "a.zip",
            destinationPath: "/tmp/a.zip", bytesReceived: 1, totalBytes: 100,
            state: .inProgress, startedAt: Date(), fileMissing: false
        )
        var done = running
        done.state = .complete
        try store.insert(&running)
        try store.insert(&done)

        let inProgress = await handler.handle(makeBridgeMessage(action: "downloads.acceptDanger", payload: ["downloadId": running.id ?? 0]))
        let complete = await handler.handle(makeBridgeMessage(action: "downloads.acceptDanger", payload: ["downloadId": done.id ?? 0]))
        let unknown = await handler.handle(makeBridgeMessage(action: "downloads.acceptDanger", payload: ["downloadId": 999]))

        XCTAssertEqual((inProgress as? BridgeError)?.message, "Download must be dangerous")
        XCTAssertEqual((complete as? BridgeError)?.message, "Download must be in progress")
        XCTAssertEqual((unknown as? BridgeError)?.message, "Invalid downloadId")
    }
}
