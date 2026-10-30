import WebKit
import XCTest
@testable import Lilo

@MainActor
final class ProfileManagerTests: XCTestCase {
    private var tempDir: URL!
    private var dbManager: DatabaseManager!
    private var manager: ProfileManager!
    private var defaults: UserDefaults!
    private let suiteName = "ProfileManagerTests"

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-manager-tests-\(UUID().uuidString)")
        dbManager = try DatabaseManager(appSupportDirectory: tempDir.path)
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        manager = ProfileManager(dbManager: dbManager, engineFactory: WKEngineFactory(), defaults: defaults)
        let storedProfiles = try await dbManager.globalPool.read { try Profile.fetchAll($0) }
        try manager.loadProfiles(storedProfiles, lastActiveProfileId: nil)
    }

    override func tearDown() async throws {
        manager = nil
        dbManager = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    func testDeleteProfileRemovesTheDatabaseRow() throws {
        let victim = try manager.createProfile(name: "Doomed")

        try manager.deleteProfile(id: victim.id)

        // The row must be gone from the DB, not just from memory: a silent
        // id-encoding mismatch here resurrects the profile on next launch.
        let remaining = try dbManager.globalPool.read { try Profile.fetchAll($0) }
        XCTAssertEqual(remaining.map(\.name), ["Default"])
        XCTAssertEqual(manager.profiles.map(\.name), ["Default"])
    }

    func testDeleteProfileRefusesDefaultAndInUseProfiles() throws {
        let defaultProfile = try XCTUnwrap(manager.defaultProfile)
        XCTAssertThrowsError(try manager.deleteProfile(id: defaultProfile.id))

        let used = try manager.createProfile(name: "Used")
        let space = Space(name: "S", icon: "S", color: "#fff", profileId: used.id)
        try dbManager.globalPool.write { try space.insert($0) }
        XCTAssertThrowsError(try manager.deleteProfile(id: used.id))

        let stillThere = try dbManager.globalPool.read { try Profile.fetchAll($0) }
        XCTAssertEqual(Set(stillThere.map(\.name)), ["Default", "Used"])
    }

    func testProfilesTakeAnUnusedPaletteColorThatPersists() async throws {
        let work = try manager.createProfile(name: "Work")
        let picked = try manager.createProfile(name: "Picked", color: "#123456")
        try manager.updateProfile(id: work.id) { $0.color = "#f0a8c8" }
        let next = try manager.createProfile(name: "Next")

        XCTAssertEqual(manager.defaultProfile?.color, Profile.palette[0])
        XCTAssertEqual(work.color, Profile.palette[1])
        XCTAssertEqual(next.color, Profile.palette[1])
        let stored = try await dbManager.globalPool.read { try Profile.fetchAll($0) }
        let colors = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0.color) })
        XCTAssertEqual(colors[work.id], "#f0a8c8")
        XCTAssertEqual(colors[picked.id], "#123456")
    }

    func testDeletingTheDefaultProfileNeedsASuccessor() throws {
        let defaultProfile = try XCTUnwrap(manager.defaultProfile)
        let heir = try manager.createProfile(name: "Heir")
        manager.activateProfile(id: defaultProfile.id)

        XCTAssertThrowsError(try manager.deleteProfile(id: defaultProfile.id, successor: defaultProfile.id))
        try manager.deleteProfile(id: defaultProfile.id, successor: heir.id)

        XCTAssertEqual(manager.profiles.map(\.id), [heir.id])
        XCTAssertEqual(manager.defaultProfile?.id, heir.id)
        XCTAssertEqual(manager.activeProfileId, heir.id)
    }

    /// Releasing a private space's ephemeral data store must also evict the engine factory's
    /// cached WKUserContentController for it, otherwise the controller (and every
    /// handler/user-script it owns) leaks for the life of the factory.
    func testReleaseEphemeralDataStoreEvictsContentControllerCache() async {
        let engineFactory = WKEngineFactory()
        let scopedManager = ProfileManager(dbManager: dbManager, engineFactory: engineFactory)
        let spaceId = UUID()

        let store = scopedManager.ephemeralDataStore(for: spaceId)
        let controllerBeforeRelease = engineFactory.createTab(configuration: .init(dataStore: store)).wkWebView.configuration.userContentController
        // A warm view carries the controller it was built with; release must drop it along with the cache.
        engineFactory.rearmWarmPool(dataStore: store, profileId: nil)
        _ = await pollUntil { engineFactory.test_warmPoolCount == 1 }

        scopedManager.releaseEphemeralDataStore(for: spaceId)

        let newStore = scopedManager.ephemeralDataStore(for: spaceId)
        XCTAssertFalse(store === newStore, "a fresh ephemeral data store must be created for the space after release")
        let controllerAfterRelease = engineFactory.createTab(configuration: .init(dataStore: newStore)).wkWebView.configuration.userContentController
        XCTAssertFalse(controllerBeforeRelease === controllerAfterRelease,
                       "the cached content controller must be rebuilt, not reused, after the space's data store is released")
    }

    func testDeleteProfileReleasesItsContentController() async throws {
        let engineFactory = WKEngineFactory()
        let scopedManager = ProfileManager(dbManager: dbManager, engineFactory: engineFactory, defaults: defaults)
        try scopedManager.loadProfiles(try await dbManager.globalPool.read { try Profile.fetchAll($0) }, lastActiveProfileId: nil)
        let doomed = try scopedManager.createProfile(name: "Doomed")
        engineFactory.rearmWarmPool(dataStore: scopedManager.dataStore(for: doomed.id), profileId: nil)
        _ = await pollUntil { engineFactory.test_warmPoolCount == 1 }
        XCTAssertEqual(engineFactory.test_warmPoolCount, 1)

        try scopedManager.deleteProfile(id: doomed.id)

        XCTAssertEqual(engineFactory.test_warmPoolCount, 0, "the deleted profile's warm view and controller go")
    }

    func testDeleteProfileRemovesItsWebsiteData() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let context = browserContext.context
        let doomed = try context.profileManager.createProfile(name: "Doomed")
        // Its extension controller shares the store too.
        _ = try context.profileContexts.context(for: doomed.id)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "example.com", .path: "/", .name: "sid", .value: "1", .expires: Date(timeIntervalSinceNow: 3600)
        ]))
        await context.profileManager.dataStore(for: doomed.id).backingStore.httpCookieStore.setCookie(cookie)
        let created = await WKWebsiteDataStore.allDataStoreIdentifiers.contains(doomed.id)
        XCTAssertTrue(created)

        try context.profileManager.deleteProfile(id: doomed.id)

        let removed = await pollUntil(timeout: 70) { await !WKWebsiteDataStore.allDataStoreIdentifiers.contains(doomed.id) }
        XCTAssertTrue(removed, "the deleted profile's cookies and site storage stay on disk")
    }

    func testActivateProfileCachesIdInUserDefaults() throws {
        let profile = try manager.createProfile(name: "Cached")

        manager.activateProfile(id: profile.id)

        XCTAssertEqual(
            defaults.string(forKey: ProfileManager.cachedLastActiveProfileIdKey),
            profile.id.uuidString
        )
    }
}
