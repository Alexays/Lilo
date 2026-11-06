import GRDB
import os
import XCTest
@testable import Lilo

final class DatabaseManagerTests: XCTestCase {
    func testConcurrentPoolLookupsOpenEachProfileOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("db-manager-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = try DatabaseManager(appSupportDirectory: dir.path)
        let profileIds = (0..<4).map { _ in UUID() }

        let opened = OSAllocatedUnfairLock<[UUID: Set<ObjectIdentifier>]>(initialState: [:])

        DispatchQueue.concurrentPerform(iterations: 32) { index in
            let profileId = profileIds[index % profileIds.count]
            guard let pool = try? manager.pool(for: profileId) else { return }
            opened.withLock { _ = $0[profileId, default: []].insert(ObjectIdentifier(pool)) }
        }

        XCTAssertEqual(opened.withLock { $0.mapValues(\.count) }, Dictionary(uniqueKeysWithValues: profileIds.map { ($0, 1) }))
        manager.closeForShutdown()
    }

    func testADeletedProfileFolderGoesAtOnceAndALeftoverOneAtTheNextLaunch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("db-manager-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let profileId = UUID()
        let manager = try DatabaseManager(appSupportDirectory: dir.path)
        _ = try manager.pool(for: profileId)

        try manager.deleteProfileData(profileId: profileId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Profiles/\(profileId.uuidString)").path))

        let leftover = dir.appendingPathComponent("Profiles/.deleted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        manager.closeForShutdown()
        let relaunched = try DatabaseManager(appSupportDirectory: dir.path)
        for _ in 0..<200 where FileManager.default.fileExists(atPath: leftover.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        relaunched.closeForShutdown()
    }

    @MainActor
    func testAnExistingProfileKeepsTheAppWideSitePermissionsAndANewOneStartsWithout() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("db-manager-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = try DatabaseManager(appSupportDirectory: dir.path)
        try manager.globalPool.write { db in
            try db.execute(sql: "INSERT INTO sitePermissions (id, origin, type, decision, updatedAt) VALUES (?, ?, ?, ?, ?)",
                           arguments: [UUID().uuidString, "https://maps.example", "location", "allow", Date()])
        }
        let existing = UUID(), created = UUID()
        let existingDirectory = dir.appendingPathComponent("Profiles/\(existing.uuidString)")
        try FileManager.default.createDirectory(at: existingDirectory, withIntermediateDirectories: true)
        // A profile database from before: an SQLite file without the table.
        _ = try DatabasePool(path: existingDirectory.appendingPathComponent("lilo.db").path)

        let existingPermissions = SitePermissionStore(dbPool: try manager.pool(for: existing))
        let createdPermissions = SitePermissionStore(dbPool: try manager.pool(for: created))

        XCTAssertEqual(existingPermissions.decision(forOrigin: "https://maps.example", type: "location"), true)
        XCTAssertNil(createdPermissions.decision(forOrigin: "https://maps.example", type: "location"))
        manager.closeForShutdown()
    }

    func testAnUnreadableDatabaseIsMovedAsideWithItsWalAndReplaced() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("db-manager-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let garbage = Data((0..<8192).map { _ in UInt8.random(in: .min ... .max) })
        try garbage.write(to: dir.appendingPathComponent("global.db"))
        try garbage.write(to: dir.appendingPathComponent("global.db-wal"))

        let manager = try DatabaseManager(appSupportDirectory: dir.path)

        let movedAside = manager.takeMovedAsideDatabases()
        XCTAssertEqual(movedAside.count, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: movedAside[0])), garbage)
        // SQLite empties a WAL whose header is invalid when the failed connection closes: only the file moves.
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedAside[0] + "-wal"))
        XCTAssertTrue(try manager.globalPool.read { try $0.tableExists("profiles") })
        XCTAssertEqual(manager.takeMovedAsideDatabases(), [])
        manager.closeForShutdown()
    }
}
