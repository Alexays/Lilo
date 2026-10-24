import XCTest
import GRDB
@testable import Lilo

final class ExtensionStorageTests: XCTestCase {

    private var dbPool: DatabasePool!
    private var tempFile: String!
    private var profileId: UUID!
    private var storage: ExtensionStorage!

    override func setUp() {
        super.setUp()
        do {
            let fileName = UUID().uuidString + ".db"
            tempFile = NSTemporaryDirectory() + fileName
            dbPool = try DatabasePool(path: tempFile)
            try Migrations.migrateGlobal(dbPool)

            // Create a test profile
            profileId = UUID()
            try dbPool.write { db in
                try db.execute(
                    sql: "INSERT INTO profiles (id, name, isDefault, createdAt, modifiedAt) VALUES (?, ?, ?, ?, ?)",
                    arguments: [profileId.uuidString, "Test Profile", false, Date(), Date()]
                )
            }

            storage = ExtensionStorage(profileId: profileId, dbPool: dbPool)
        } catch {
            XCTFail("Failed to set up test database: \(error)")
        }
    }

    override func tearDown() {
        storage = nil
        dbPool = nil
        if let tempFile = tempFile {
            try? FileManager.default.removeItem(atPath: tempFile)
            try? FileManager.default.removeItem(atPath: tempFile + "-shm")
            try? FileManager.default.removeItem(atPath: tempFile + "-wal")
        }
        super.tearDown()
    }

    // MARK: - Tests

    func testStoreExtension() async throws {
        let extensionId = "test-ext-1"
        let name = "Test Extension"
        let version = "1.0.0"
        let path = "/path/to/extension"

        try await storage.store(id: extensionId, name: name, version: version, path: path, enabled: true)

        let stored = try await storage.load(id: extensionId)
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.id, extensionId)
        XCTAssertEqual(stored?.name, name)
        XCTAssertEqual(stored?.version, version)
        XCTAssertEqual(stored?.path, path)
        XCTAssertTrue(stored?.isEnabled ?? false)
    }

    func testAccessStateRoundTripsAndClears() async throws {
        try await storage.store(id: "ext-sites", name: "Sites", version: "1.0", path: "/tmp/sites", enabled: true)

        let state = ExtensionStorage.AccessState(
            hosts: ["example.com"], optionalPermissions: ["tabs"], optionalMatchPatterns: ["https://*.example.org/*"], declinedUpdateVersion: "2.0"
        )
        try await storage.setAccessState(id: "ext-sites", state)
        var access = try await storage.loadAccessStates()
        XCTAssertEqual(access["ext-sites"], state)

        try await storage.setAccessState(id: "ext-sites", ExtensionStorage.AccessState())
        access = try await storage.loadAccessStates()
        XCTAssertNil(access["ext-sites"], "an empty state means unrestricted, so the row must not surface")
    }

    func testAccessStateWrittenBeforePrivateAccessAndShortcutsStillReads() async throws {
        try await storage.store(id: "ext-sites", name: "Sites", version: "1.0", path: "/tmp/sites", enabled: true)
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE installed_extensions SET site_access = ? WHERE id = ?",
                arguments: [#"{"hosts":["example.com"],"optionalPermissions":[],"optionalMatchPatterns":[]}"#, "ext-sites"]
            )
        }
        let access = try await storage.loadAccessStates()
        XCTAssertEqual(access["ext-sites"], ExtensionStorage.AccessState(hosts: ["example.com"]))
    }

    func testAccessStateSurvivesAnExtensionUpdate() async throws {
        try await storage.store(id: "ext-sites", name: "Sites", version: "1.0", path: "/tmp/sites", enabled: true)
        try await storage.setAccessState(id: "ext-sites", ExtensionStorage.AccessState(hosts: ["example.com"]))

        try await storage.store(id: "ext-sites", name: "Sites", version: "2.0", path: "/tmp/sites", enabled: true)

        let access = try await storage.loadAccessStates()
        XCTAssertEqual(access["ext-sites"]?.hosts, ["example.com"], "reinstalling must not drop the user's restriction")
    }

    func testStoreUpsertsExistingExtensionMetadata() async throws {
        let extensionId = "test-ext-upsert"

        try await storage.store(id: extensionId, name: "Before", version: "1.0.0", path: "/before", enabled: true)
        try await storage.store(id: extensionId, name: "After", version: "2.0.0", path: "/after", enabled: false)

        let stored = try await storage.load(id: extensionId)
        XCTAssertEqual(stored?.name, "After")
        XCTAssertEqual(stored?.version, "2.0.0")
        XCTAssertEqual(stored?.path, "/after")
        XCTAssertFalse(stored?.isEnabled ?? true)
    }

    func testLoadExtension() async throws {
        let extensionId = "test-ext-2"
        try await storage.store(id: extensionId, name: "Extension 2", version: "2.0.0", path: "/path2", enabled: false)

        let loaded = try await storage.load(id: extensionId)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.id, extensionId)
        XCTAssertEqual(loaded?.name, "Extension 2")
        XCTAssertEqual(loaded?.version, "2.0.0")
        XCTAssertFalse(loaded?.isEnabled ?? true)
    }

    func testLoadNonExistentExtension() async throws {
        let loaded = try await storage.load(id: "non-existent")
        XCTAssertNil(loaded)
    }

    func testLoadAllExtensions() async throws {
        try await storage.store(id: "ext-1", name: "Extension 1", version: "1.0.0", path: "/path1", enabled: true)
        try await storage.store(id: "ext-2", name: "Extension 2", version: "2.0.0", path: "/path2", enabled: false)
        try await storage.store(id: "ext-3", name: "Extension 3", version: "3.0.0", path: "/path3", enabled: true)

        let all = try await storage.loadAll()
        XCTAssertEqual(all.count, 3)
        XCTAssertTrue(all.contains(where: { $0.id == "ext-1" }))
        XCTAssertTrue(all.contains(where: { $0.id == "ext-2" }))
        XCTAssertTrue(all.contains(where: { $0.id == "ext-3" }))
    }

    func testLoadAllEmptyWhenNoExtensions() async throws {
        let all = try await storage.loadAll()
        XCTAssertEqual(all.count, 0)
    }

    func testDeletingAnUnknownExtensionSucceeds() async throws {
        try await storage.delete(id: "non-existent")
    }

    // MARK: - Per-Profile Isolation Tests

    func testPerProfileIsolation() async throws {
        // Create another profile
        let profile2Id = UUID()
        try await dbPool.write { db in
            try db.execute(
                sql: "INSERT INTO profiles (id, name, isDefault, createdAt, modifiedAt) VALUES (?, ?, ?, ?, ?)",
                arguments: [profile2Id.uuidString, "Test Profile 2", false, Date(), Date()]
            )
        }

        let storage2 = ExtensionStorage(profileId: profile2Id, dbPool: dbPool)

        // Store extensions in profile 1
        try await storage.store(id: "ext-profile1", name: "Extension 1", version: "1.0.0", path: "/path1", enabled: true)

        // Store extensions in profile 2
        try await storage2.store(id: "ext-profile2", name: "Extension 2", version: "2.0.0", path: "/path2", enabled: true)

        // Profile 1 should only see ext-profile1
        let profile1All = try await storage.loadAll()
        XCTAssertEqual(profile1All.count, 1)
        XCTAssertEqual(profile1All[0].id, "ext-profile1")

        // Profile 2 should only see ext-profile2
        let profile2All = try await storage2.loadAll()
        XCTAssertEqual(profile2All.count, 1)
        XCTAssertEqual(profile2All[0].id, "ext-profile2")

        // Profile 1 should not be able to load profile 2's extension
        let crossProfile = try await storage.load(id: "ext-profile2")
        XCTAssertNil(crossProfile, "Profile 1 should not see extensions from profile 2")

        // Profile 2 should not be able to load profile 1's extension
        let crossProfile2 = try await storage2.load(id: "ext-profile1")
        XCTAssertNil(crossProfile2, "Profile 2 should not see extensions from profile 1")
    }

    func testPerProfileIsolationDelete() async throws {
        // Create another profile
        let profile2Id = UUID()
        try await dbPool.write { db in
            try db.execute(
                sql: "INSERT INTO profiles (id, name, isDefault, createdAt, modifiedAt) VALUES (?, ?, ?, ?, ?)",
                arguments: [profile2Id.uuidString, "Test Profile 2", false, Date(), Date()]
            )
        }

        let storage2 = ExtensionStorage(profileId: profile2Id, dbPool: dbPool)

        // Store extension in both profiles
        try await storage.store(id: "ext-same-id", name: "Extension 1", version: "1.0.0", path: "/path1", enabled: true)
        try await storage2.store(id: "ext-same-id", name: "Extension 2", version: "2.0.0", path: "/path2", enabled: true)

        // Delete from profile 1
        try await storage.delete(id: "ext-same-id")

        // Verify deleted from profile 1
        let deleted = try await storage.load(id: "ext-same-id")
        XCTAssertNil(deleted)

        // Verify still exists in profile 2
        let exists = try await storage2.load(id: "ext-same-id")
        XCTAssertNotNil(exists)
        XCTAssertEqual(exists?.name, "Extension 2")
    }

    func testPerProfileIsolationSetEnabled() async throws {
        // Create another profile
        let profile2Id = UUID()
        try await dbPool.write { db in
            try db.execute(
                sql: "INSERT INTO profiles (id, name, isDefault, createdAt, modifiedAt) VALUES (?, ?, ?, ?, ?)",
                arguments: [profile2Id.uuidString, "Test Profile 2", false, Date(), Date()]
            )
        }

        let storage2 = ExtensionStorage(profileId: profile2Id, dbPool: dbPool)

        // Store extension in both profiles with same ID
        try await storage.store(id: "ext-same-id", name: "Extension 1", version: "1.0.0", path: "/path1", enabled: true)
        try await storage2.store(id: "ext-same-id", name: "Extension 2", version: "2.0.0", path: "/path2", enabled: false)

        // Disable in profile 1
        try await storage.setEnabled(id: "ext-same-id", enabled: false)

        // Verify disabled in profile 1
        let profile1Ext = try await storage.load(id: "ext-same-id")
        XCTAssertFalse(profile1Ext?.isEnabled ?? true)

        // Verify still disabled in profile 2 (not changed by profile 1 operation)
        let profile2Ext = try await storage2.load(id: "ext-same-id")
        XCTAssertFalse(profile2Ext?.isEnabled ?? true)

        // Enable in profile 2 (should not affect profile 1)
        try await storage2.setEnabled(id: "ext-same-id", enabled: true)

        let profile2ExtAfter = try await storage2.load(id: "ext-same-id")
        XCTAssertTrue(profile2ExtAfter?.isEnabled ?? false)

        // Profile 1 should still be disabled
        let profile1ExtAfter = try await storage.load(id: "ext-same-id")
        XCTAssertFalse(profile1ExtAfter?.isEnabled ?? true)
    }
}
