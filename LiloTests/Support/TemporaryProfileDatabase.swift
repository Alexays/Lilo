import Foundation
import GRDB
@testable import Lilo

/// A migrated GRDB pool at a unique temporary path; `tearDown()` closes it and deletes the
/// .db/-wal/-shm files.
final class TemporaryProfileDatabase {
    enum Schema {
        case profile
        case global
    }

    let pool: DatabasePool
    private let path: String

    init(schema: Schema = .profile) throws {
        path = NSTemporaryDirectory() + UUID().uuidString + ".db"
        pool = try DatabasePool(path: path)
        switch schema {
        case .profile: try Migrations.migrateProfile(pool)
        case .global: try Migrations.migrateGlobal(pool)
        }
    }

    func tearDown() {
        try? pool.close()
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }
}
