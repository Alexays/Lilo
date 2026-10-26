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

    func testSearchMatchesChromesQueryFilenameAndInProgressState() async throws {
        var paused = DownloadItem(
            id: nil, url: "https://example.com/q3/report.pdf", filename: "report.pdf",
            destinationPath: "/tmp/report.pdf", bytesReceived: 10, totalBytes: 100,
            state: .paused, startedAt: Date(timeIntervalSinceNow: -60), fileMissing: false
        )
        var draft = paused
        draft.url = "https://example.com/q3/report-draft.pdf"
        draft.destinationPath = "/tmp/report-draft.pdf"
        draft.state = .complete
        draft.startedAt = Date()
        try store.insert(&paused)
        try store.insert(&draft)

        func ids(_ payload: [String: Any]) async -> [Int64]? {
            (await handler.handle(makeBridgeMessage(action: "downloads.search", payload: payload)) as? [[String: Any]])?
                .compactMap { $0["id"] as? Int64 }
        }

        let inProgress = await ids(["state": "in_progress", "limit": 1])
        let query = await ids(["query": ["q3", "-draft"]])
        let byPath = await ids(["filename": "/tmp/report-draft.pdf", "query": ["report"]])
        let byBasename = await ids(["filename": "report-draft.pdf"])
        XCTAssertEqual(inProgress, [paused.id!], "a paused download is in_progress, and the limit applies after the state")
        XCTAssertEqual(query, [paused.id!])
        XCTAssertEqual(byPath, [draft.id!])
        XCTAssertEqual(byBasename, [])
    }

    func testDownloadRejectsAFilenameOutsideTheDownloadsFolder() async {
        for filename in ["", "/tmp/x.txt", "../x.txt", "a/../x.txt", "a//x.txt", "./x.txt", "a/", ".hidden"] {
            let result = await handler.handle(makeBridgeMessage(action: "downloads.download", payload: ["url": "data:text/plain,x", "filename": filename]))
            XCTAssertEqual((result as? BridgeError)?.message, "Invalid filename", filename)
        }
    }

    func testDownloadIntoASubfolderCreatesIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gap-downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        manager.downloadsFolderProvider = { folder }

        let result = await handler.handle(makeBridgeMessage(action: "downloads.download", payload: ["url": "data:text/plain,x", "filename": "reports/2026/x.txt"]))
        let id = try XCTUnwrap(result as? Int64)
        await manager.cancel(id: id)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("reports/2026").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try store.fetch(id: id)?.destinationPath, folder.appendingPathComponent("reports/2026/x.txt").path)
    }

    func testAnExtensionsSuggestionRenamesTheDownloadIntoASubfolder() async throws {
        let (folder, registry, extensionId) = try await downloadsFolderAndExtension()
        defer { try? FileManager.default.removeItem(at: folder) }
        registry.gapEvents.listen(["downloads.onDeterminingFilename"], extensionId: extensionId)
        let handler = try XCTUnwrap(self.handler)

        let download = Task {
            await handler.handle(makeBridgeMessage(action: "downloads.download", payload: [
                "url": "data:text/plain,x", "filename": "x.txt", "extensionId": extensionId
            ]), registry: registry) as? Int64
        }
        _ = await pollUntil { !Self.determiningFilenameEvents(in: registry, to: extensionId).isEmpty }
        let event = try XCTUnwrap(Self.determiningFilenameEvents(in: registry, to: extensionId).first)
        let requestId = try XCTUnwrap(event.args.last as? String)
        _ = await handler.handle(makeBridgeMessage(action: "downloads.suggestFilename", payload: [
            "requestId": requestId, "filename": "sorted/x.txt", "extensionId": extensionId
        ]), registry: registry)
        let downloaded = await download.value
        let id = try XCTUnwrap(downloaded)
        await manager.cancel(id: id)

        XCTAssertEqual((event.args.first as? [String: Any])?["filename"] as? String, "x.txt", "Chrome names the file without its folder")
        XCTAssertEqual(try store.fetch(id: id)?.destinationPath, folder.appendingPathComponent("downloads/sorted/x.txt").path)
    }

    func testWithoutAListenerTheDownloadKeepsItsNameAndNothingIsSent() async throws {
        let (folder, registry, extensionId) = try await downloadsFolderAndExtension()
        defer { try? FileManager.default.removeItem(at: folder) }

        let result = await handler.handle(makeBridgeMessage(action: "downloads.download", payload: [
            "url": "data:text/plain,x", "filename": "x.txt", "extensionId": extensionId
        ]), registry: registry)
        let id = try XCTUnwrap(result as? Int64)
        await manager.cancel(id: id)

        XCTAssertEqual(try store.fetch(id: id)?.destinationPath, folder.appendingPathComponent("downloads/x.txt").path)
        XCTAssertTrue(Self.determiningFilenameEvents(in: registry, to: extensionId).isEmpty)
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

    /// A download's events go to the extensions of the profile whose store holds it, never another profile's.
    func testDownloadEventsGoToTheDownloadsOwnProfile() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let context = browserContext.context
        let profileIds = try ["A", "B"].map { try context.profileManager.createProfile(name: $0).id }
        context.profileContexts.pinnedProfileIds = Set(profileIds)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("download-events-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var listeners: [(registry: ProfileExtensionRegistry, extensionId: String)] = []
        for profileId in profileIds {
            let registry = try context.profileContexts.context(for: profileId).extensions
            let directory = folder.appendingPathComponent(profileId.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let manifest: [String: Any] = ["manifest_version": 3, "name": "Downloads", "version": "1.0", "permissions": ["downloads"]]
            try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"))
            try await registry.load(from: directory)
            listeners.append((registry, try XCTUnwrap(registry.loadedExtensions.first?.id)))
        }
        func events(_ index: Int) -> [String] {
            listeners[index].registry.gapEvents.undelivered(to: listeners[index].extensionId)
                .filter { $0.namespace == "downloads" }.map(\.event)
        }
        let store = try context.profileContexts.context(for: profileIds[0]).downloads
        context.downloadManager.setStore(store)
        context.downloadManager.downloadsFolderProvider = { folder }

        await context.downloadManager.saveData(
            Data("x".utf8), suggestedFilename: "x.txt", mimeType: "text/plain", originatingURL: try XCTUnwrap(URL(string: "https://example.com/x"))
        ).value
        let id = try XCTUnwrap(try store.fetchAll().first?.id)
        try context.downloadManager.erase(id: id)

        XCTAssertEqual(events(0), ["onCreated", "onErased"])
        XCTAssertEqual(events(1), [])
    }

    // MARK: - Helpers

    /// A temporary folder holding the downloads folder, now the manager's, and a registry with one loaded extension that
    /// holds the downloads permission.
    private func downloadsFolderAndExtension() async throws -> (folder: URL, registry: ProfileExtensionRegistry, extensionId: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gap-downloads-\(UUID().uuidString)")
        let downloads = folder.appendingPathComponent("downloads")
        let source = folder.appendingPathComponent("extension")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        manager.downloadsFolderProvider = { downloads }
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Downloads", "version": "1.0", "permissions": ["downloads"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: source.appendingPathComponent("manifest.json"))
        let registry = try makeTestExtensionRegistry(in: folder)
        try await registry.load(from: source)
        return (folder, registry, try XCTUnwrap(registry.loadedExtensions.first?.id))
    }

    private static func determiningFilenameEvents(in registry: ProfileExtensionRegistry, to extensionId: String) -> [GapEventEnvelope] {
        registry.gapEvents.undelivered(to: extensionId).filter { $0.namespace == "downloads" && $0.event == "onDeterminingFilename" }
    }

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
