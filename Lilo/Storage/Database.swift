import Foundation
import GRDB
import os

/// Shared logger for the storage layer.
private let storageLogger = Logger(liloCategory: "storage")

/// Runs a fire-and-forget persistence write, logging any error instead of silently
/// swallowing it. Use where propagating the error to the caller isn't practical but
/// silent data loss must stay visible in the logs.
func loggingPersistenceError(_ operation: String, _ body: () throws -> Void) {
    do {
        try body()
    } catch {
        storageLogger.error("persistence \(operation, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
    }
}

/// An `asyncWrite` completion that logs a failed write the way `loggingPersistenceError` does.
func loggingPersistenceFailure(_ operation: String) -> @Sendable (Database, Result<Void, Error>) -> Void {
    { _, result in
        if case let .failure(error) = result {
            storageLogger.error("persistence \(operation, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Manages per-profile GRDB database pools.
final class DatabaseManager: @unchecked Sendable {

    /// The global database for profile-level metadata (which profiles exist, last active, etc.).
    private(set) var globalPool: DatabasePool

    let appSupportDirectory: String

    /// WAL keeps the database consistent under synchronous=NORMAL; only the last commits before a
    /// power loss can roll back, and it removes an fsync from every write.
    private static let configuration: Configuration = {
        var config = Configuration()
        config.prepareDatabase { db in try db.execute(sql: "PRAGMA synchronous = NORMAL") }
        return config
    }()

    /// Per-profile database pools, keyed by profile ID. Locked: the launch preload opens pools off the main thread.
    private let profilePools = OSAllocatedUnfairLock<[UUID: DatabasePool]>(initialState: [:])

    init(appSupportDirectory: String = BuildIdentity.appSupportDirectory) throws {
        self.appSupportDirectory = appSupportDirectory
        let globalPath = (appSupportDirectory as NSString).appendingPathComponent("global.db")
        try FileManager.default.createDirectory(
            atPath: (globalPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        globalPool = try DatabasePool(path: globalPath, configuration: Self.configuration)
        try Migrations.migrateGlobal(globalPool)
    }

    /// Get or create the database pool for a specific profile.
    func pool(for profileId: UUID) throws -> DatabasePool {
        let path = (profileDirectory(profileId: profileId) as NSString).appendingPathComponent("lilo.db")
        // Opening stays inside the lock so two threads never open and migrate the same file at once.
        return try profilePools.withLock { pools in
            if let existing = pools[profileId] { return existing }
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            let pool = try DatabasePool(path: path, configuration: Self.configuration)
            try Migrations.migrateProfile(pool)
            pools[profileId] = pool
            return pool
        }
    }

    /// Clean shutdown: checkpoint WAL and close every pool, each independently so one failing
    /// pool never skips the others.
    func closeForShutdown() {
        var pools: [(name: String, pool: DatabasePool)] = [("global", globalPool)]
        for (profileId, pool) in profilePools.withLock({ $0 }) {
            pools.append(("profile \(profileId.uuidString)", pool))
        }
        for (name, pool) in pools {
            loggingPersistenceError("shutdown.checkpoint[\(name)]") {
                try pool.writeWithoutTransaction { db in
                    try db.execute(sql: "PRAGMA wal_checkpoint(RESTART)")
                }
            }
            loggingPersistenceError("shutdown.close[\(name)]") { try pool.close() }
        }
    }

    /// Delete all data for a profile (database file + directory).
    func deleteProfileData(profileId: UUID) throws {
        // The files go even when the close fails: a deleted profile must not leave its data behind.
        if let pool = profilePools.withLock({ $0.removeValue(forKey: profileId) }) {
            loggingPersistenceError("deleteProfile.close[\(profileId.uuidString)]") { try pool.close() }
        }
        let dir = profileDirectory(profileId: profileId)
        if FileManager.default.fileExists(atPath: dir) {
            try FileManager.default.removeItem(atPath: dir)
        }
    }

    // MARK: - Paths

    private func profileDirectory(profileId: UUID) -> String {
        let base = (appSupportDirectory as NSString).appendingPathComponent("Profiles")
        return (base as NSString).appendingPathComponent(profileId.uuidString)
    }
}
