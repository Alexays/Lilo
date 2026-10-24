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
}
