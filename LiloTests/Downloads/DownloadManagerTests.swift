import XCTest
import GRDB
import os
import WebKit
@testable import Lilo

@MainActor
final class DownloadManagerTests: XCTestCase {
    private var db: TemporaryProfileDatabase!
    private var store: DownloadStore!
    private var manager: DownloadManager!

    override func setUp() async throws {
        db = try TemporaryProfileDatabase()
        store = DownloadStore(dbPool: db.pool)
        manager = DownloadManager(dockController: nil)
        manager.attach(store)
    }

    override func tearDown() async throws {
        manager = nil
        store = nil
        db.tearDown()
        db = nil
    }

    func testAttachRunsCrashRecovery() throws {
        // Insert a dangling inProgress item directly in DB before attach
        var item = DownloadItem(
            id: nil, url: "https://example.com/a.zip", filename: "a.zip",
            destinationPath: "/tmp/a.zip", bytesReceived: 0, totalBytes: 100,
            state: .inProgress, startedAt: Date(), fileMissing: false
        )
        item.source = "url"
        try store.insert(&item)

        // A fresh manager given the same store must run crash recovery.
        let manager2 = DownloadManager(dockController: nil)
        manager2.attach(store)

        let fetched = try store.fetch(id: item.id!)
        XCTAssertEqual(fetched?.state, .interrupted)
        XCTAssertNotNil(fetched?.endedAt)
        XCTAssertEqual(try store.fetchAll().count, 1, "the interrupted row waits for Retry instead of restarting as a duplicate")
    }

    func testObserversCalledOnCancel() async throws {
        var item = DownloadItem(
            id: nil, url: "https://example.com/b.zip", filename: "b.zip",
            destinationPath: "/tmp/b.zip", bytesReceived: 10, totalBytes: 100,
            state: .inProgress, startedAt: Date(), fileMissing: false
        )
        try store.insert(&item)

        var received: DownloadItem?
        manager.addObserver { received = $0 }

        await manager.cancel(id: item.id!, in: store)

        XCTAssertNotNil(received)
        XCTAssertEqual(received?.state, .interrupted)
        XCTAssertEqual(received?.error, "Cancelled by user")
        XCTAssertNotNil(received?.endedAt)
    }

    func testErasingAPausedDownloadEndsItForTheObservers() throws {
        var item = DownloadItem(
            id: nil, url: "https://example.com/p.zip", filename: "p.zip",
            destinationPath: "/tmp/p.zip", bytesReceived: 10, totalBytes: 100,
            state: .paused, startedAt: Date(), fileMissing: false
        )
        try store.insert(&item)
        var received: DownloadItem?
        manager.addObserver { received = $0 }

        try manager.erase(id: item.id!, in: store)

        XCTAssertEqual(received?.state, .interrupted, "the Dock drops what it was counting")
        XCTAssertNil(try store.fetch(id: item.id!))
    }

    func testEraseRemovesFromStore() throws {
        var item = DownloadItem(
            id: nil, url: "https://example.com/c.zip", filename: "c.zip",
            destinationPath: "/tmp/c.zip", bytesReceived: 0, totalBytes: 50,
            state: .complete, startedAt: Date(), fileMissing: false
        )
        try store.insert(&item)

        try manager.erase(id: item.id!, in: store)
        let fetched = try store.fetch(id: item.id!)
        XCTAssertNil(fetched)
    }

    // MARK: - Profiles

    /// A tab of a background Space in profile B downloads while its window shows profile A: the row is B's, and only a window
    /// showing B lists it.
    func testADownloadGoesToTheDownloadingTabsProfile() async throws {
        let otherDatabase = try TemporaryProfileDatabase()
        defer { otherDatabase.tearDown() }
        let windowStore = DownloadStore(dbPool: db.pool, profileId: UUID())
        let tabStore = DownloadStore(dbPool: otherDatabase.pool, profileId: UUID())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        manager.downloadsFolderProvider = { folder }
        manager.attach(windowStore)
        let windowRouter = BridgeRouter(chromeWebView: WKWebView())
        let windowEvents = BridgeEventRecorder(windowRouter)
        let windowHandler = DownloadBridgeHandler(downloadManager: manager, bridgeRouter: windowRouter, storeProvider: { windowStore })
        let tabWindowRouter = BridgeRouter(chromeWebView: WKWebView())
        let tabWindowEvents = BridgeEventRecorder(tabWindowRouter)
        let tabWindowHandler = DownloadBridgeHandler(downloadManager: manager, bridgeRouter: tabWindowRouter, storeProvider: { tabStore })
        var finished = false
        manager.addObserver { if $0.state == .complete { finished = true } }

        let webView = WKWebView()
        webView.startDownload(using: URLRequest(url: try XCTUnwrap(URL(string: "data:text/plain;base64,aGVsbG8=")))) { [manager] in
            manager?.startDownload($0, in: tabStore)
        }
        _ = await pollUntil(timeout: 60) { finished }
        let listed = await pollUntil { tabWindowEvents.events.contains { $0.name == "downloadUpdated" } }
        withExtendedLifetime((webView, windowHandler, tabWindowHandler)) {}

        XCTAssertEqual(try tabStore.fetchAll().count, 1)
        XCTAssertEqual(try windowStore.fetchAll().count, 0)
        XCTAssertTrue(listed)
        XCTAssertFalse(windowEvents.events.contains { $0.name == "downloadUpdated" }, "another profile's window does not list it")
        XCTAssertEqual((DownloadBridgeHandler.snapshot(of: windowStore, manager: manager)["items"] as? [Any])?.count, 0)
    }

    /// Each profile's rows number from 1: cancelling one profile's download leaves the other's of the same id alone.
    func testCancellingADownloadLeavesAnotherProfilesOfTheSameId() async throws {
        let otherDatabase = try TemporaryProfileDatabase()
        defer { otherDatabase.tearDown() }
        let otherStore = DownloadStore(dbPool: otherDatabase.pool, profileId: UUID())
        var item = DownloadItem(
            id: nil, url: "https://example.com/p.zip", filename: "p.zip",
            destinationPath: "/tmp/p.zip", bytesReceived: 10, totalBytes: 100,
            state: .paused, startedAt: Date(), fileMissing: false
        )
        var otherItem = item
        try store.insert(&item)
        try otherStore.insert(&otherItem)
        XCTAssertEqual(item.id, otherItem.id)

        await manager.cancel(id: try XCTUnwrap(otherItem.id), in: otherStore)

        XCTAssertEqual(try otherStore.fetch(id: otherItem.id!)?.state, .interrupted)
        XCTAssertEqual(try store.fetch(id: item.id!)?.state, .paused)
    }

    // MARK: - Retry

    func testRetryWithResumeDataResumesInPlace() async throws {
        var item = DownloadItem(
            id: nil, url: "http://127.0.0.1:9/partial.zip", filename: "partial.zip",
            destinationPath: "/tmp/partial-original.zip", bytesReceived: 500, totalBytes: 1000,
            state: .interrupted, startedAt: Date(), fileMissing: false
        )
        item.source = "url"
        item.resumeData = Data("synthetic resume blob".utf8)
        item.error = "network dropped"
        try store.insert(&item)

        var events: [DownloadItem] = []
        manager.addObserver { events.append($0) }

        try await manager.retryDownload(id: item.id!, in: store)

        // Resume path: the same row transitions back to inProgress at its original destination
        // and no second row is inserted (a fresh start would add one with a deduped name).
        XCTAssertEqual(events.first?.id, item.id)
        XCTAssertEqual(events.first?.state, .inProgress)
        XCTAssertEqual(events.first?.destinationPath, "/tmp/partial-original.zip")
        XCTAssertEqual(try store.fetchAll().count, 1)
        let fetched = try store.fetch(id: item.id!)
        XCTAssertEqual(fetched?.state, .inProgress)
        XCTAssertNil(fetched?.resumeData)
        XCTAssertNil(fetched?.error)
    }

    func testRetryWithoutResumeDataRestartsFresh() async throws {
        manager.downloadsFolderProvider = { FileManager.default.temporaryDirectory }
        var item = DownloadItem(
            id: nil, url: "http://127.0.0.1:9/fresh.zip", filename: "fresh.zip",
            destinationPath: "/tmp/fresh.zip", bytesReceived: 0, totalBytes: 1000,
            state: .interrupted, startedAt: Date(), fileMissing: false
        )
        item.source = "url"
        try store.insert(&item)

        try await manager.retryDownload(id: item.id!, in: store)

        let all = try store.fetchAll()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(try store.fetch(id: item.id!)?.state, .interrupted)
    }

    func testRetryWkWithoutWebViewFallsBackToFreshStart() async throws {
        manager.downloadsFolderProvider = { FileManager.default.temporaryDirectory }
        var item = DownloadItem(
            id: nil, url: "http://127.0.0.1:9/page.zip", filename: "page.zip",
            destinationPath: "/tmp/page.zip", bytesReceived: 100, totalBytes: 1000,
            state: .interrupted, startedAt: Date(), fileMissing: false
        )
        item.source = "wk"
        item.resumeData = Data("wk resume blob".utf8)
        try store.insert(&item)

        try await manager.retryDownload(id: item.id!, in: store)

        let all = try store.fetchAll()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(try store.fetch(id: item.id!)?.state, .interrupted)
    }

    func testRetryWkWithoutResumeDataSendsTheSiteCookies() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        manager.downloadsFolderProvider = { folder }
        let requests = OSAllocatedUnfairLock(initialState: [String]())
        let server = try await TinyHTTPServer { request in
            requests.withLock { $0.append(request) }
            return ("200 OK", ["Content-Type: application/octet-stream", #"Content-Disposition: attachment; filename="signed.zip""#], Data("zip".utf8))
        }
        // The download's profile has the session; the active tab browses a private space with its own cookie.
        let profileId = UUID()
        addTeardownBlock { try? await WKWebsiteDataStore.remove(forIdentifier: profileId) }
        store = DownloadStore(dbPool: db.pool, profileId: profileId)
        manager.attach(store)
        let session = try XCTUnwrap(HTTPCookie(properties: [.domain: "localhost", .path: "/", .name: "session", .value: "signed-in"]))
        await WKWebsiteDataStore(forIdentifier: profileId).httpCookieStore.setCookie(session)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let privateCookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "localhost", .path: "/", .name: "private", .value: "yes"]))
        await configuration.websiteDataStore.httpCookieStore.setCookie(privateCookie)
        manager.webView = webView
        var item = DownloadItem(
            id: nil, url: "http://localhost:\(server.port)/signed.zip", filename: "signed.zip",
            destinationPath: folder.appendingPathComponent("signed.zip").path, bytesReceived: 0, totalBytes: 3,
            state: .interrupted, startedAt: Date(), fileMissing: false
        )
        item.source = "wk"
        try store.insert(&item)

        try await manager.retryDownload(id: item.id!, in: store)
        _ = await pollUntil(timeout: 60) { !requests.withLock { $0.isEmpty } }
        withExtendedLifetime(webView) {}

        XCTAssertEqual(try store.fetchAll().count, 2)
        let received = requests.withLock { $0 }
        XCTAssertTrue(received.contains { $0.contains("session=signed-in") }, "\(received)")
        XCTAssertFalse(received.contains { $0.contains("private=yes") }, "\(received)")
        XCTAssertTrue(received.contains { $0.contains(WKEngineFactory.safariApplicationName) }, "the user agent of pages, not CFNetwork's: \(received)")
    }

    func testResumeLeavesAWebViewOfAnotherDataStore() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        manager.webView = webView
        var item = DownloadItem(
            id: nil, url: "http://127.0.0.1:9/paused.zip", filename: "paused.zip",
            destinationPath: "/tmp/paused.zip", bytesReceived: 100, totalBytes: 1000,
            state: .paused, startedAt: Date(), fileMissing: false
        )
        item.source = "wk"
        item.resumeData = Data("wk resume blob".utf8)
        try store.insert(&item)

        await manager.resume(id: item.id!, in: store)
        withExtendedLifetime(webView) {}

        XCTAssertEqual(try store.fetch(id: item.id!)?.state, .interrupted, "a private space's web view never hosts a profile's download")
    }

    // MARK: - Saved data

    func testSavedDataGoesWhereTheUserPicks() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        manager.downloadsFolderProvider = { folder }
        manager.chooseDestination = { proposed, _, _ in proposed.deletingLastPathComponent().appendingPathComponent("picked.pdf") }

        await manager.saveData(Data("pdf".utf8), suggestedFilename: "doc.pdf", mimeType: "application/pdf", originatingURL: URL(string: "https://example.com/doc")!, in: store).value

        XCTAssertEqual(try store.fetchAll().map(\.filename), ["picked.pdf"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("picked.pdf").path))
    }

    func testSavedDataIsNotKeptWhenTheUserCancels() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        manager.downloadsFolderProvider = { folder }
        manager.chooseDestination = { _, _, _ in nil }

        await manager.saveData(Data("pdf".utf8), suggestedFilename: "doc.pdf", mimeType: "application/pdf", originatingURL: URL(string: "https://example.com/doc")!, in: store).value

        XCTAssertEqual(try store.fetchAll().count, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testSavedDataTakesTheExtensionsSuggestedName() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        manager.downloadsFolderProvider = { folder }
        manager.suggestFilename = { _ in ("papers/renamed.pdf", "uniquify") }

        await manager.saveData(Data("pdf".utf8), suggestedFilename: "doc.pdf", mimeType: "application/pdf", originatingURL: URL(string: "https://example.com/doc")!, in: store).value

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("papers/renamed.pdf").path))
    }

    // MARK: - Speed and ETA tracking tests

    func testAugmentedBridgeDataIncludesSpeedAfterTwoSamples() throws {
        var item = DownloadItem(
            id: nil, url: "https://example.com/d.zip", filename: "d.zip",
            destinationPath: "/tmp/d.zip", bytesReceived: 0, totalBytes: 10000,
            state: .inProgress, startedAt: Date(), fileMissing: false
        )
        try store.insert(&item)

        // First sample initializes speedSamples with smoothedSpeed = 0.
        let sampleStart = Date()
        item.bytesReceived = 1000
        manager.updateSpeed(for: item, now: sampleStart)

        // Second sample 0.4s later (past the 0.3s gate) computes speed.
        item.bytesReceived = 2000
        manager.updateSpeed(for: item, now: sampleStart.addingTimeInterval(0.4))

        let data = manager.augmentedBridgeData(for: item)
        XCTAssertNotNil(data["speedBytesPerSec"])
        let speed = data["speedBytesPerSec"] as? Int64
        XCTAssertNotNil(speed)
        XCTAssertGreaterThan(speed!, 0)
    }

    func testAugmentedBridgeDataOmitsSpeedWithOneSample() throws {
        var item = DownloadItem(
            id: nil, url: "https://example.com/e.zip", filename: "e.zip",
            destinationPath: "/tmp/e.zip", bytesReceived: 1000, totalBytes: 10000,
            state: .inProgress, startedAt: Date(), fileMissing: false
        )
        try store.insert(&item)

        // Only one update (smoothedSpeed still 0)
        manager.updateSpeed(for: item)

        let data = manager.augmentedBridgeData(for: item)
        XCTAssertNil(data["speedBytesPerSec"])
        XCTAssertNil(data["eta"])
    }

    func testAugmentedBridgeDataOmitsETAWhenTotalBytesUnknown() throws {
        var item = DownloadItem(
            id: nil, url: "https://example.com/f.zip", filename: "f.zip",
            destinationPath: "/tmp/f.zip", bytesReceived: 0, totalBytes: -1,
            state: .inProgress, startedAt: Date(), fileMissing: false
        )
        try store.insert(&item)

        // Two samples 0.4s apart compute speed, but not ETA since totalBytes = -1.
        let sampleStart = Date()
        item.bytesReceived = 1000
        manager.updateSpeed(for: item, now: sampleStart)

        item.bytesReceived = 2000
        manager.updateSpeed(for: item, now: sampleStart.addingTimeInterval(0.4))

        let data = manager.augmentedBridgeData(for: item)
        XCTAssertNotNil(data["speedBytesPerSec"])
        XCTAssertNil(data["eta"])

        item.totalBytes = 0
        let data2 = manager.augmentedBridgeData(for: item)
        XCTAssertNotNil(data2["speedBytesPerSec"])
        XCTAssertNil(data2["eta"])
    }

    func testSpeedSampleClearedWhenNotInProgress() throws {
        var item = DownloadItem(
            id: nil, url: "https://example.com/g.zip", filename: "g.zip",
            destinationPath: "/tmp/g.zip", bytesReceived: 0, totalBytes: 10000,
            state: .inProgress, startedAt: Date(), fileMissing: false
        )
        try store.insert(&item)

        // Build up speed samples from two timestamps 0.4s apart.
        let sampleStart = Date()
        item.bytesReceived = 1000
        manager.updateSpeed(for: item, now: sampleStart)
        item.bytesReceived = 2000
        manager.updateSpeed(for: item, now: sampleStart.addingTimeInterval(0.4))

        var data = manager.augmentedBridgeData(for: item)
        XCTAssertNotNil(data["speedBytesPerSec"])

        item.state = .paused
        manager.updateSpeed(for: item)

        data = manager.augmentedBridgeData(for: item)
        XCTAssertNil(data["speedBytesPerSec"])

        item.state = .complete
        manager.updateSpeed(for: item)

        data = manager.augmentedBridgeData(for: item)
        XCTAssertNil(data["speedBytesPerSec"])
    }
}
