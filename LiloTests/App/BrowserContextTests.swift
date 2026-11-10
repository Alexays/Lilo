import WebKit
import XCTest
@testable import Lilo

@MainActor
final class BrowserContextTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("browser-context-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    func testBootstrapOpensTheDatabaseUnderItsDirectoryAndLoadsStores() async throws {
        let context = BrowserContext(appSupportDirectory: tempDir.path, makeProfileId: { TestProfileIds.next() })
        try await context.bootstrap()

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("global.db").path))
        XCTAssertNotNil(context.settingsStore)
        XCTAssertNotNil(context.profileManager)
        XCTAssertNotNil(context.spaceManager)
        XCTAssertNotNil(context.startupSnapshot)
    }

    /// Several windows await the same bootstrap: the database opens once.
    func testConcurrentBootstrapsShareOneDatabaseManager() async throws {
        let context = BrowserContext(appSupportDirectory: tempDir.path, makeProfileId: { TestProfileIds.next() })
        async let first: Void = context.bootstrap()
        async let second: Void = context.bootstrap()
        _ = try await (first, second)
        let manager = context.dbManager
        try await context.bootstrap()
        XCTAssertTrue(context.dbManager === manager)
    }

    /// Closures the context's own objects keep must not keep the context, or it and its pools never go.
    func testContextIsReleasedWithItsWindow() async throws {
        weak var released: BrowserContext?
        do {
            let context = BrowserContext(appSupportDirectory: tempDir.path, makeProfileId: { TestProfileIds.next() })
            try await context.bootstrap()
            let window = MainWindowController(context: context)
            context.windows.add(window)
            context.windows.remove(window)
            released = context
        }
        for _ in 0..<20 where released != nil { await Task.yield() }
        XCTAssertNil(released)
    }

    /// The windows to reopen are read at bootstrap, before any save rewrites the table.
    func testWindowsToReopenAreReadBeforeAnySave() async throws {
        let seed = try DatabaseManager(appSupportDirectory: tempDir.path)
        let stored = [
            StoredWindow(frame: NSRect(x: 0, y: 0, width: 900, height: 700), spaceId: UUID()),
            StoredWindow(frame: NSRect(x: 30, y: 30, width: 900, height: 700), spaceId: UUID())
        ]
        try WindowStore(dbPool: seed.globalPool).replaceAll(stored)
        try seed.globalPool.close()

        let context = BrowserContext(appSupportDirectory: tempDir.path, makeProfileId: { TestProfileIds.next() })
        try await context.bootstrap()
        context.saveWindowsNow()

        XCTAssertEqual(context.startupSnapshot!.windows, stored)
    }

    /// The last active profile's database opens at bootstrap: an unreadable one is replaced instead of stopping the launch.
    func testBootstrapReplacesAnUnreadableProfileDatabase() async throws {
        let first = BrowserContext(appSupportDirectory: tempDir.path, makeProfileId: { TestProfileIds.next() })
        try await first.bootstrap()
        let profileId = try XCTUnwrap(first.profileManager?.defaultProfile?.id)
        first.dbManager!.closeForShutdown()
        let profileDirectory = tempDir.appendingPathComponent("Profiles/\(profileId.uuidString)")
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
        let garbage = Data((0..<8192).map { _ in UInt8.random(in: .min ... .max) })
        try garbage.write(to: profileDirectory.appendingPathComponent("lilo.db"))

        let context = BrowserContext(appSupportDirectory: tempDir.path, makeProfileId: { TestProfileIds.next() })
        try await context.bootstrap()

        XCTAssertEqual(context.startupSnapshot!.storedSpaceIdsByProfile[profileId], [:])
        let files = try FileManager.default.contentsOfDirectory(atPath: profileDirectory.path)
        let movedAside = try XCTUnwrap(files.first { $0.hasPrefix("lilo.db.corrupt-") && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") })
        XCTAssertEqual(try Data(contentsOf: profileDirectory.appendingPathComponent(movedAside)), garbage)
    }

    /// Deleting a space by any path, agents included, drops its saved tab tree and interaction states.
    func testDeletingASpaceDropsItsSavedState() async throws {
        let context = BrowserContext(appSupportDirectory: tempDir.path, makeProfileId: { TestProfileIds.next() })
        try await context.bootstrap()
        let profileId = try context.profileManager!.createProfile(name: "P").id
        let kept = try context.spaceManager!.createSpace(name: "Kept", profileId: profileId)
        let gone = try context.spaceManager!.createSpace(name: "Gone", profileId: profileId)
        let pool = try context.dbManager!.pool(for: profileId)
        let tabStates = SpaceTabStateStore(dbPool: pool)
        let interactionStates = InteractionStateStore(dbPool: pool)
        let empty = SpaceTabState(activeTabId: nil, activationHistory: [], tree: .empty)
        try tabStates.saveMany([(spaceId: kept.id, state: empty), (spaceId: gone.id, state: empty)])
        try interactionStates.replace(spaceId: kept.id, entries: [UUID(): Data([1])])
        try interactionStates.replace(spaceId: gone.id, entries: [UUID(): Data([2])])

        try context.spaceManager!.deleteSpace(id: gone.id)
        // The writer queue is serial, so this empty write lands after the delete's.
        try await pool.write { _ in }

        XCTAssertNil(try tabStates.load(spaceId: gone.id))
        XCTAssertTrue(try interactionStates.load(spaceId: gone.id).isEmpty)
        XCTAssertNotNil(try tabStates.load(spaceId: kept.id))
        XCTAssertEqual(try interactionStates.load(spaceId: kept.id).count, 1)
    }

    /// `clients.openWindow()` from a service worker: a tab in a Space of the worker's profile, and none for a private store.
    func testAServiceWorkerOpensItsWindowInASpaceOfItsProfile() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let context = browserContext.context
        let work = try context.profileManager!.createProfile(name: "Work").id
        let home = try context.profileManager!.createProfile(name: "Home").id
        _ = try context.spaceManager!.createSpace(name: "Office", profileId: work)
        let homeSpace = try context.spaceManager!.createSpace(name: "Family", profileId: home)
        let window = MainWindowController(context: context)
        defer { window.window?.close() }
        window.contentContainerView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        context.windows.add(window)
        window.switchToSpace(homeSpace.id)
        let url = try XCTUnwrap(URL(string: "https://example.com/inbox"))
        let open = try XCTUnwrap(context.engineFactory.notificationBridge.openWindowHandler)

        let webView = try XCTUnwrap(open(WKEngineFactory.persistentDataStore(for: work), url))

        let tabId = try XCTUnwrap(window.tabManager.engineTab(forWebView: webView)?.id)
        XCTAssertEqual(window.tabManager.activeTabId, tabId)
        XCTAssertEqual(window.tabManager.tab(for: tabId)?.url, url)
        XCTAssertEqual(context.spaceManager!.space(with: window.tabManager.currentSpaceId)?.profileId, work)

        XCTAssertNil(open(WKWebsiteDataStore.nonPersistent(), url))
        XCTAssertEqual(window.tabManager.activeTabId, tabId)
    }
}
