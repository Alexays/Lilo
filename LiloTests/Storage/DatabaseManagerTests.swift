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
}
