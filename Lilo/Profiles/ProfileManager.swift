import Foundation
import GRDB
import os
import WebKit

/// Manages Profile lifecycle with isolated persistent WebKit data stores,
/// separate GRDB databases, and per-profile extension state.
@MainActor
final class ProfileManager {
    private let dbManager: DatabaseManager
    private let engineFactory: WKEngineFactory
    private let defaults: UserDefaults
    /// Tests recycle a few ids: WebKit serves only about 188 persistent data stores per app launch.
    private let makeProfileId: @MainActor () -> UUID
    nonisolated private static let logger = Logger(liloCategory: "profile-manager")

    private(set) var profiles: [Profile] = []

    private(set) var activeProfileId: UUID?

    private var restoredLastActiveProfileId: UUID?
    private var hasLoadedLastActiveProfileId = false

    /// Per-profile data stores (cookies, cache, local storage).
    private var dataStores: [UUID: WKEngineDataStore] = [:]
    private var privateDataStores: [UUID: WKEngineDataStore] = [:]

    weak var delegate: BrowserContext?

    /// UserDefaults cache of the last active profile id, written on every activation. Read at
    /// window init, before the database opens, to pre-spawn the content WebContent process
    /// for the profile the session restore will almost certainly need.
    nonisolated static let cachedLastActiveProfileIdKey = "cachedLastActiveProfileId"

    init(dbManager: DatabaseManager, engineFactory: WKEngineFactory, defaults: UserDefaults = .lilo, makeProfileId: @escaping @MainActor () -> UUID = UUID.init) {
        self.dbManager = dbManager
        self.engineFactory = engineFactory
        self.defaults = defaults
        self.makeProfileId = makeProfileId
    }

    // MARK: - Loading

    func loadProfiles(_ loadedProfiles: [Profile], lastActiveProfileId: UUID?) throws {
        restoredLastActiveProfileId = lastActiveProfileId; hasLoadedLastActiveProfileId = true
        profiles = loadedProfiles
        if profiles.isEmpty { let p = try createProfile(name: "Default", isDefault: true); activateProfile(id: p.id) }
    }

    var defaultProfile: Profile? {
        profiles.first { $0.isDefault }
    }

    func dataStore(for profileId: UUID) -> WKEngineDataStore {
        if let store = dataStores[profileId] { return store }
        let store = engineFactory.createDataStore(persistent: true, identifier: profileId.uuidString)
        dataStores[profileId] = store
        return store
    }

    func ephemeralDataStore(for spaceId: UUID) -> WKEngineDataStore {
        if let store = privateDataStores[spaceId] { return store }
        let store = engineFactory.createDataStore(persistent: false, identifier: spaceId.uuidString)
        privateDataStores[spaceId] = store
        return store
    }

    func releaseEphemeralDataStore(for spaceId: UUID) {
        guard let store = privateDataStores.removeValue(forKey: spaceId) else { return }
        engineFactory.releaseContentController(for: store)
    }

    @discardableResult
    /// Without a color, the profile takes the first palette color no other profile has, else the next in turn.
    func createProfile(name: String = "New Profile", isDefault: Bool = false, color: String? = nil) throws -> Profile {
        let color = color ?? Profile.palette.first { color in !profiles.contains { $0.color == color } }
            ?? Profile.palette[profiles.count % Profile.palette.count]
        let profile = Profile(id: makeProfileId(), name: name, isDefault: isDefault, color: color)
        try dbManager.globalPool.write { try profile.insert($0) }
        profiles.append(profile); delegate?.profileManager(self, didCreateProfile: profile); return profile
    }

    /// The default profile is where a space with no profile lands: deleting it hands that role to `successor`.
    func deleteProfile(id: UUID, successor: UUID? = nil) throws {
        guard let index = profileIndex(id: id) else { return }
        let profile = profiles[index]
        let heir = successor == id ? nil : successor.flatMap(profileIndex(id:))
        guard !profile.isDefault || heir != nil else { throw ProfileManagerError.defaultProfileDeletionForbidden }
        // The id column stores uuidString: deleteOne(id:) would match a UUID blob, find nothing and let the profile resurrect at next launch.
        // Checked inside the write, which waits for queued space writes (a move to another profile among them).
        try dbManager.globalPool.write { db in
            guard try Space.filter(Space.Columns.profileId == id.uuidString).fetchCount(db) == 0 else {
                throw ProfileManagerError.profileHasSpaces
            }
            let deletedCount = try Profile
                .filter(Column("id") == profile.id.uuidString)
                .deleteAll(db)
            guard deletedCount == 1 else { throw ProfileManagerError.deleteFailed(profile.id) }
            if profile.isDefault, let heir {
                try db.execute(sql: "UPDATE profiles SET isDefault = 1 WHERE id = ?", arguments: [profiles[heir].id.uuidString])
            }
        }
        if profile.isDefault, let heir {
            profiles[heir].isDefault = true
            delegate?.profileManager(self, didUpdateProfile: profiles[heir])
        }
        profiles.remove(at: index)
        if let store = dataStores.removeValue(forKey: id) {
            engineFactory.releaseContentController(for: store)
        }
        delegate?.profileManager(self, didDeleteProfile: profile)
        if activeProfileId == id, let next = profiles.first(where: { $0.id == successor }) ?? defaultProfile ?? profiles.first {
            activateProfile(id: next.id)
        }
        BookmarkSpotlightIndexer.removeAll(profileId: id)
        // The row is gone and the UI is told either way; leftover files are not worth a failed delete.
        do { try dbManager.deleteProfileData(profileId: id) } catch {
            Self.logger.error("profile data removal failed for \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        // WebKit keeps each extension controller's chrome.storage under its configuration identifier,
        // the profile id; nothing else ever removes it.
        if let bundleId = Bundle.main.bundleIdentifier {
            let extensionData = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("WebKit/\(bundleId)/WebExtensions/\(id.uuidString)", isDirectory: true)
            try? FileManager.default.removeItem(at: extensionData)
        }
        // Cookies, caches and site storage. WebKit refuses to remove a store still in use: its last references go with this turn,
        // and the network process lets go of it a moment later.
        Task {
            // Up to a minute: a busy network process can hold the store well past the first seconds.
            for delay in [1, 2, 4, 8, 16, 32] {
                do { return try await WKWebsiteDataStore.remove(forIdentifier: id) } catch {
                    guard delay < 32 else {
                        return Self.logger.error("website data removal failed for \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
    }

    func updateProfile(id: UUID, mutate: (inout Profile) -> Void) throws {
        guard let index = profileIndex(id: id) else { return }
        var profile = profiles[index]
        mutate(&profile); profile.modifiedAt = Date()
        try dbManager.globalPool.write { db in try profile.update(db) }
        profiles[index] = profile
        delegate?.profileManager(self, didUpdateProfile: profile)
    }

    func activateProfile(id: UUID) {
        guard profileIndex(id: id) != nil else { return }
        guard activeProfileId != id else { return }
        activeProfileId = id; restoredLastActiveProfileId = id; hasLoadedLastActiveProfileId = true
        defaults.set(id.uuidString, forKey: Self.cachedLastActiveProfileIdKey)
        dbManager.globalPool.asyncWrite({ db in
            try db.execute(sql: "INSERT OR REPLACE INTO appState (key, value) VALUES (?, ?)", arguments: ["lastActiveProfileId", id.uuidString])
        }, completion: { _, result in loggingPersistenceError("profile.lastActive") { try result.get() } })
        delegate?.profileManager(self, didActivateProfile: id)
    }

    func restoreLastActiveProfileId() -> UUID? {
        if hasLoadedLastActiveProfileId { return restoredLastActiveProfileId }
        restoredLastActiveProfileId = try? dbManager.globalPool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT value FROM appState WHERE key = ?", arguments: ["lastActiveProfileId"])
            return row.flatMap { UUID(uuidString: $0["value"]) }
        }
        hasLoadedLastActiveProfileId = true; return restoredLastActiveProfileId
    }

    /// Installed extensions per profile id, for the profile pickers.
    func extensionCounts() async throws -> [String: Int] {
        try await dbManager.globalPool.read { db in
            try Row.fetchAll(db, sql: "SELECT profile_id, COUNT(*) AS count FROM installed_extensions GROUP BY profile_id")
                .reduce(into: [String: Int]()) { counts, row in counts[row["profile_id"] as String] = row["count"] as Int }
        }
    }

    private func profileIndex(id: UUID) -> Int? {
        profiles.firstIndex(where: { $0.id == id })
    }
}

private enum ProfileManagerError: Error {
    case defaultProfileDeletionForbidden
    case profileHasSpaces
    case deleteFailed(UUID)
}
