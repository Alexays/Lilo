import XCTest
@testable import Lilo

/// The cache keeps displayed profiles plus the most recently left one; anything older is torn down.
@MainActor
final class ProfileContextCacheTests: XCTestCase {
    private var tempDir: URL!
    private var dbManager: DatabaseManager!
    private var builds: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-context-cache-\(UUID().uuidString)")
        dbManager = try DatabaseManager(appSupportDirectory: tempDir.path)
        builds = []
    }

    override func tearDown() {
        dbManager = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    private func makeCache() -> ProfileContextCache {
        ProfileContextCache { [unowned self] profileId in
            builds.append(profileId)
            return try ProfileContext(profileId: profileId, dbManager: dbManager, gapRouter: nil)
        }
    }

    func testCacheKeepsPinnedAndMostRecentAndDeallocatesEvicted() async throws {
        let cache = makeCache()
        let a = TestProfileIds.next(), b = TestProfileIds.next(), c = TestProfileIds.next()
        cache.pinnedProfileIds = [a]
        _ = try cache.context(for: a)
        weak let registryB = try cache.context(for: b).extensions
        _ = try cache.context(for: c)

        XCTAssertEqual([a, b, c].map { cache.existingContext(for: $0) != nil }, [true, false, true])
        for _ in 0..<20 where registryB != nil { await Task.yield() }
        XCTAssertNil(registryB, "an evicted registry must deallocate, or its controller and workers stay resident")
    }

    func testRoundTripWithinCapReusesContext() throws {
        let cache = makeCache()
        let a = TestProfileIds.next(), b = TestProfileIds.next()
        cache.pinnedProfileIds = [a]
        let first = try cache.context(for: b)
        _ = try cache.context(for: a)
        XCTAssertTrue(try cache.context(for: b) === first)
        XCTAssertEqual(builds.filter { $0 == b }.count, 1, "a cached profile never rebuilds its stores or reopens its pool")
    }

    func testRevisitAfterEvictionBuildsFreshContext() throws {
        let cache = makeCache()
        let a = TestProfileIds.next(), b = TestProfileIds.next(), c = TestProfileIds.next()
        let original = try cache.context(for: a)
        _ = try cache.context(for: b)
        _ = try cache.context(for: c)
        XCTAssertFalse(try cache.context(for: a) === original)
    }

    func testExistingContextNeverBuilds() {
        let cache = makeCache()
        XCTAssertNil(cache.existingContext(for: UUID()))
        XCTAssertTrue(builds.isEmpty)
    }

    func testPinnedProfilesSurviveAnyNumberOfVisits() throws {
        let cache = makeCache()
        let a = TestProfileIds.next(), b = TestProfileIds.next()
        cache.pinnedProfileIds = [a, b]
        _ = try cache.context(for: a)
        _ = try cache.context(for: b)
        for _ in 0..<3 { _ = try cache.context(for: UUID()) }
        XCTAssertNotNil(cache.existingContext(for: a))
        XCTAssertNotNil(cache.existingContext(for: b))
    }

    /// A deleted profile's context goes at once: its pool points at a removed directory.
    func testDeletedProfileContextIsDroppedAndItsRegistryReleased() async throws {
        let cache = makeCache()
        let deleted = UUID()
        cache.pinnedProfileIds = [deleted]
        weak let registry = try cache.context(for: deleted).extensions

        cache.removeContext(for: deleted)

        XCTAssertNil(cache.existingContext(for: deleted))
        XCTAssertFalse(cache.pinnedProfileIds.contains(deleted))
        for _ in 0..<20 where registry != nil { await Task.yield() }
        XCTAssertNil(registry)
    }

    func testRegistryKeepsInstalledExtensionsUnderTheDatabaseDirectory() throws {
        let context = try makeCache().context(for: UUID())
        XCTAssertEqual(
            context.extensions.extensionsBaseDirectory?.standardizedFileURL.path,
            tempDir.standardizedFileURL.path,
            "extension files must follow the database directory, never the user's real Application Support"
        )
    }
}
