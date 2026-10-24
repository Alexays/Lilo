import Foundation
import GRDB
import WebKit

/// Everything Lilo keeps per profile: its database and the stores and extension registry built on it.
@MainActor
final class ProfileContext {
    let profileId: UUID
    let pool: DatabasePool
    let history: HistoryStore
    let bookmarks: BookmarkStore
    private let bookmarkSpotlight: BookmarkSpotlightIndexer
    let downloads: DownloadStore
    let favicons: FaviconStore
    let zoom = ZoomStore()
    let extensions: ProfileExtensionRegistry
    let extensionSettings: ExtensionSettingsStore
    /// Built when a window first shows the profile; it saves whichever of its spaces windows display.
    var sessionPersistence: SessionPersistence?

    init(
        profileId: UUID, dbManager: DatabaseManager, gapRouter: GapBridgeRouter?,
        tabShare: (bridge: TabShareBridge, frames: TabShareFrameSchemeHandler)? = nil
    ) throws {
        self.profileId = profileId
        pool = try dbManager.pool(for: profileId)
        history = HistoryStore(dbPool: pool)
        bookmarks = BookmarkStore(dbPool: pool)
        bookmarkSpotlight = BookmarkSpotlightIndexer(dbPool: pool, profileId: profileId)
        downloads = DownloadStore(dbPool: pool, profileId: profileId)
        favicons = FaviconStore(dbPool: pool)
        zoom.useDatabase(pool)
        extensionSettings = ExtensionSettingsStore(pool: pool, profileId: profileId)
        extensions = ProfileExtensionRegistry(
            profileId: profileId,
            extensionStorage: ExtensionStorage(profileId: profileId, dbPool: dbManager.globalPool, profilePool: pool),
            gapRouter: gapRouter,
            tabShare: tabShare,
            extensionsBaseDirectory: URL(fileURLWithPath: dbManager.appSupportDirectory)
        )
        history.onChange = { [weak registry = extensions] change in
            Task { @MainActor in if let registry { HistoryBridgeHandler.emit(change, to: registry) } }
        }
    }
}

/// Profile contexts built on demand. Displayed profiles are pinned; of the others only the most
/// recently requested one is kept, because every live registry keeps extension workers resident.
@MainActor
final class ProfileContextCache {
    private let makeContext: (UUID) throws -> ProfileContext
    private var contexts: [UUID: ProfileContext] = [:]
    private var mostRecentUnpinned: UUID?
    var pinnedProfileIds: Set<UUID> = []

    init(makeContext: @escaping (UUID) throws -> ProfileContext) {
        self.makeContext = makeContext
    }

    var allContexts: [ProfileContext] { Array(contexts.values) }

    func existingContext(for profileId: UUID) -> ProfileContext? { contexts[profileId] }

    /// Drops a deleted profile's context and tears its registry down.
    func removeContext(for profileId: UUID) {
        pinnedProfileIds.remove(profileId)
        if mostRecentUnpinned == profileId { mostRecentUnpinned = nil }
        guard let removed = contexts.removeValue(forKey: profileId) else { return }
        removed.extensions.teardown()
    }

    func context(for profileId: UUID) throws -> ProfileContext {
        let context: ProfileContext
        if let cached = contexts[profileId] {
            context = cached
        } else {
            context = try makeContext(profileId)
            contexts[profileId] = context
        }
        if !pinnedProfileIds.contains(profileId) { mostRecentUnpinned = profileId }
        for (id, evicted) in contexts where !pinnedProfileIds.contains(id) && id != mostRecentUnpinned {
            evicted.extensions.teardown()
            contexts.removeValue(forKey: id)
        }
        return context
    }
}
