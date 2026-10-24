import Foundation
import GRDB
@testable import Lilo

/// Adds the profile row installed extensions reference; without it a restore finds nothing.
func insertTestProfile(_ profileId: UUID, into dbPool: DatabasePool) throws {
    try dbPool.write { db in
        try db.execute(
            sql: "INSERT INTO profiles (id, name, isDefault, createdAt, modifiedAt) VALUES (?, ?, ?, ?, ?)",
            arguments: [profileId.uuidString, "Test Profile", false, Date(), Date()]
        )
    }
}

/// Extension storage over a migrated global database under `directory`, with its profile row in place.
func makeTestExtensionStorage(profileId: UUID, in directory: URL) throws -> ExtensionStorage {
    let dbPool = try DatabasePool(path: directory.appendingPathComponent("\(profileId.uuidString)-global.db").path)
    try Migrations.migrateGlobal(dbPool)
    try insertTestProfile(profileId, into: dbPool)
    return ExtensionStorage(profileId: profileId, dbPool: dbPool)
}

/// A registry whose database and installed extensions both live under `directory`, never the user's
/// real Application Support.
@MainActor
func makeTestExtensionRegistry(profileId: UUID? = nil, in directory: URL) throws -> ProfileExtensionRegistry {
    let profileId = profileId ?? TestProfileIds.next()
    return ProfileExtensionRegistry(
        profileId: profileId,
        extensionStorage: try makeTestExtensionStorage(profileId: profileId, in: directory),
        extensionsBaseDirectory: directory
    )
}

/// Writes a bare MV3 manifest into `directory/directoryName` and returns that folder.
func createMinimalExtension(named directoryName: String, displayName: String = "Test", in directory: URL) throws -> URL {
    let extDir = directory.appendingPathComponent(directoryName)
    try FileManager.default.createDirectory(at: extDir, withIntermediateDirectories: true)
    let manifest = """
    {"manifest_version":3,"name":"\(displayName)","version":"1.0","description":"Test extension"}
    """
    try manifest.write(to: extDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    return extDir
}
