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
}
