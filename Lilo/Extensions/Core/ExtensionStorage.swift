import Foundation
import GRDB

private struct StoredExtension: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "installed_extensions"

    var id: String
    var profileId: String
    var name: String
    var version: String
    var enabled: Int  // Store as Int (0 or 1) in database
    var installType: String
    var installDate: Date
    var path: String

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let profileId = Column(CodingKeys.profileId)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case profileId = "profile_id"
        case name
        case version
        case enabled
        case installType = "install_type"
        case installDate = "install_date"
        case path
    }

    // MARK: - Custom initializer for convenience

    init(id: String, profileId: String, name: String, version: String, enabled: Bool, installType: String, installDate: Date, path: String) {
        self.id = id
        self.profileId = profileId
        self.name = name
        self.version = version
        self.enabled = enabled ? 1 : 0
        self.installType = installType
        self.installDate = installDate
        self.path = path
    }

    var installedExtension: ExtensionStorage.InstalledExtension {
        ExtensionStorage.InstalledExtension(
            id: id,
            name: name,
            version: version,
            path: path,
            isEnabled: enabled != 0
        )
    }
}

/// Manages storage of installed extensions with per-profile isolation.
final class ExtensionStorage: @unchecked Sendable {
    struct InstalledExtension: Sendable, Equatable {
        let id: String
        let name: String
        let version: String
        let path: String
        let isEnabled: Bool
    }

    private let profileId: UUID
    private let dbPool: DatabasePool
    /// The profile's own database, which holds its `chrome.userScripts` registrations; without it they
    /// last for the session only.
    private let profilePool: DatabasePool?

    init(profileId: UUID, dbPool: DatabasePool, profilePool: DatabasePool? = nil) {
        self.profileId = profileId
        self.dbPool = dbPool
        self.profilePool = profilePool
    }

    // MARK: - CRUD Operations

    /// Store a new extension in the database.
    func store(id: String, name: String, version: String, path: String, enabled: Bool) async throws {
        try await dbPool.write { db in
            let ext = StoredExtension(
                id: id,
                profileId: self.profileId.uuidString,
                name: name,
                version: version,
                enabled: enabled,
                installType: "normal",
                installDate: Date(),
                path: path
            )
            try ext.save(db)
        }
    }

    /// Load a specific extension by ID for the current profile.
    func load(id: String) async throws -> InstalledExtension? {
        try await dbPool.read { db in
            try StoredExtension
                .filter(StoredExtension.Columns.id == id && StoredExtension.Columns.profileId == self.profileId.uuidString)
                .fetchOne(db)
                .map(\.installedExtension)
        }
    }

    /// Load all extensions for the current profile.
    func loadAll() async throws -> [InstalledExtension] {
        try await dbPool.read { db in
            try StoredExtension
                .filter(StoredExtension.Columns.profileId == self.profileId.uuidString)
                .fetchAll(db)
                .map(\.installedExtension)
        }
    }

    /// Delete an extension by ID from the current profile, with its user scripts.
    func delete(id: String) async throws {
        try await dbPool.write { db in
            _ = try StoredExtension
                .filter(StoredExtension.Columns.id == id && StoredExtension.Columns.profileId == self.profileId.uuidString)
                .deleteAll(db)
        }
        try await profilePool?.write { db in
            try db.execute(sql: "DELETE FROM registeredUserScripts WHERE extensionId = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM userScriptWorldConfigs WHERE extensionId = ?", arguments: [id])
        }
    }

    /// Update the enabled flag for an extension.
    func setEnabled(id: String, enabled: Bool) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE installed_extensions SET enabled = ? WHERE id = ? AND profile_id = ?",
                arguments: [enabled ? 1 : 0, id, self.profileId.uuidString]
            )
        }
    }

    // MARK: - Access state

    /// What the user decided about one extension (access, shortcuts), kept in the `site_access` column
    /// next to the row rather than in the Codable record, so an install or update never rewrites it.
    struct AccessState: Codable, Equatable, Sendable {
        /// Hosts the extension is restricted to; empty keeps every host its manifest asks for.
        var hosts: [String] = []
        /// Optional permissions and match patterns granted at runtime through `permissions.request`.
        var optionalPermissions: [String] = []
        var optionalMatchPatterns: [String] = []
        /// Optional permissions WebKit grants no request for (Gap API ones, `nativeMessaging`), granted at
        /// Lilo's prompt (`PermissionsBridgeHandler`); nil stays out of the stored JSON.
        var gapPermissions: [String]?
        /// An update version whose added permissions the user declined, so it is not offered again.
        var declinedUpdateVersion: String?
        /// nil is "not allowed" / "no override", and stays out of the stored JSON.
        var allowsPrivateAccess: Bool?
        /// User-rebound command shortcuts by command id; a nil key removes the shortcut.
        var commandShortcuts: [String: CommandShortcut]?
        /// "Allow user scripts": `chrome.userScripts` works and its scripts run only with it, as in Chrome.
        var allowsUserScripts: Bool?

        var isEmpty: Bool { self == AccessState() }
    }

    struct CommandShortcut: Codable, Equatable, Sendable {
        var key: String?
        /// `NSEvent.ModifierFlags` raw value.
        var modifiers: UInt
    }

    func loadAccessStates() async throws -> [String: AccessState] {
        try await dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, site_access FROM installed_extensions WHERE profile_id = ? AND site_access <> ''",
                arguments: [self.profileId.uuidString]
            )
            let decoder = JSONDecoder()
            return rows.reduce(into: [:]) { map, row in
                guard let id: String = row["id"], let raw: String = row["site_access"],
                      let state = try? decoder.decode(AccessState.self, from: Data(raw.utf8)) else { return }
                map[id] = state
            }
        }
    }

    func setAccessState(id: String, _ state: AccessState) async throws {
        let encoded = state.isEmpty ? "" : (String(data: try JSONEncoder().encode(state), encoding: .utf8) ?? "")
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE installed_extensions SET site_access = ? WHERE id = ? AND profile_id = ?",
                arguments: [encoded, id, self.profileId.uuidString]
            )
        }
    }

    // MARK: - User scripts

    /// One `chrome.userScripts` registration, in Chrome's `RegisteredUserScript` shape. Every field but
    /// `id` is optional so an `update` can name only what changes; stored registrations are complete.
    struct UserScript: Codable, Equatable, Sendable {
        struct Source: Codable, Equatable, Sendable {
            var code: String?
            var file: String?
        }

        var id: String
        var matches: [String]?
        var excludeMatches: [String]?
        var includeGlobs: [String]?
        var excludeGlobs: [String]?
        var js: [Source]?
        var allFrames: Bool?
        var runAt: String?
        var world: String?
        var worldId: String?
    }

    /// A `chrome.userScripts.configureWorld` configuration; a nil `worldId` is the default world.
    struct UserScriptWorld: Codable, Equatable, Sendable {
        var worldId: String?
        var csp: String?
        var messaging: Bool?
    }

    /// Registration order is kept: each change rewrites the extension's rows in order.
    func loadUserScripts(extensionId: String) async throws -> (scripts: [UserScript], worlds: [UserScriptWorld]) {
        guard let profilePool else { return ([], []) }
        return try await profilePool.read { db in
            func strings(_ raw: String?) -> [String]? {
                raw.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }
            }
            let scripts = try Row.fetchAll(
                db,
                sql: "SELECT * FROM registeredUserScripts WHERE extensionId = ? ORDER BY rowid",
                arguments: [extensionId]
            ).map { row in
                let js: String = row["js"]
                return UserScript(
                    id: row["id"],
                    matches: strings(row["matches"]),
                    excludeMatches: strings(row["excludeMatches"]),
                    includeGlobs: strings(row["includeGlobs"]),
                    excludeGlobs: strings(row["excludeGlobs"]),
                    js: try? JSONDecoder().decode([UserScript.Source].self, from: Data(js.utf8)),
                    allFrames: row["allFrames"],
                    runAt: row["runAt"],
                    world: row["world"],
                    worldId: (row["worldId"] as String?).flatMap { $0.isEmpty ? nil : $0 }
                )
            }
            let worlds = try Row.fetchAll(
                db,
                sql: "SELECT * FROM userScriptWorldConfigs WHERE extensionId = ? ORDER BY rowid",
                arguments: [extensionId]
            ).map { row in
                UserScriptWorld(
                    worldId: (row["worldId"] as String?).flatMap { $0.isEmpty ? nil : $0 },
                    csp: row["csp"],
                    messaging: row["messaging"]
                )
            }
            return (scripts, worlds)
        }
    }

    func setUserScripts(_ scripts: [UserScript], extensionId: String) async throws {
        try await profilePool?.write { db in
            func json(_ value: some Encodable) -> String? {
                (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
            }
            try db.execute(sql: "DELETE FROM registeredUserScripts WHERE extensionId = ?", arguments: [extensionId])
            for script in scripts {
                try db.execute(
                    sql: """
                        INSERT INTO registeredUserScripts
                            (id, extensionId, matches, excludeMatches, includeGlobs, excludeGlobs, js, allFrames, runAt, world, worldId)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        script.id, extensionId, json(script.matches ?? []), script.excludeMatches.flatMap { json($0) },
                        script.includeGlobs.flatMap { json($0) }, script.excludeGlobs.flatMap { json($0) }, json(script.js ?? []),
                        script.allFrames ?? false, script.runAt ?? "document_idle", script.world ?? "USER_SCRIPT", script.worldId ?? ""
                    ]
                )
            }
        }
    }

    func setUserScriptWorlds(_ worlds: [UserScriptWorld], extensionId: String) async throws {
        try await profilePool?.write { db in
            try db.execute(sql: "DELETE FROM userScriptWorldConfigs WHERE extensionId = ?", arguments: [extensionId])
            for world in worlds {
                try db.execute(
                    sql: "INSERT INTO userScriptWorldConfigs (extensionId, worldId, csp, messaging) VALUES (?, ?, ?, ?)",
                    arguments: [extensionId, world.worldId ?? "", world.csp, world.messaging ?? false]
                )
            }
        }
    }
}
