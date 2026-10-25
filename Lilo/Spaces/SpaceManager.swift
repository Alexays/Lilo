import Foundation
import GRDB
import os

private enum SpaceManagerError: Error {
    case deleteFailed(UUID)
}

/// Manages Space lifecycle across all profiles.
/// Each space is globally ordered and linked to exactly one profile.
@MainActor
final class SpaceManager {
    private let dbPool: DatabasePool
    nonisolated private static let logger = Logger(liloCategory: "space-manager")

    /// All spaces across every profile, globally ordered by sortOrder.
    private(set) var spaces: [Space] = []

    /// The currently active space ID.
    var activeSpaceId: UUID?

    weak var delegate: BrowserContext?

    /// Spaces whose in-memory activeTabId is ahead of their row.
    private var unpersistedActiveTabSpaceIds: Set<UUID> = []

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - Loading

    /// Call once on startup with the stored spaces.
    func loadSpaces(_ loadedSpaces: [Space]) {
        spaces = loadedSpaces
        normalizeOrdering()
    }

    func space(with id: UUID?) -> Space? {
        guard let id else { return nil }
        return spaces.first { $0.id == id }
    }

    func spaces(for profileId: UUID) -> [Space] {
        spaces.filter { $0.profileId == profileId }
    }

    func hasSpaces(for profileId: UUID) -> Bool {
        spaces.contains { $0.profileId == profileId }
    }

    @discardableResult
    func createHomeSpace(for profileId: UUID) throws -> Space {
        if let existing = persistentSpaces.first(where: { $0.profileId == profileId && $0.name == "Home" }) { return existing }
        return try createSpace(name: "Home", icon: "🏠", profileId: profileId)
    }

    @discardableResult
    func createSpace(
        name: String = "New Space",
        icon: String = "🌐",
        color: String = "#5865f2",
        colorMode: String = Space.fixedColorMode,
        profileId: UUID,
        isPrivate: Bool = false
    ) throws -> Space {
        var space = Space(
            name: name,
            icon: icon,
            color: color,
            profileId: profileId,
            isPrivate: isPrivate,
            sortOrder: isPrivate ? spaces.count : persistentSpaces.count
        )
        space.colorMode = colorMode
        if !isPrivate { try dbPool.write { db in try space.insert(db) } }

        spaces.append(space); normalizeOrdering()
        delegate?.spaceManager(self, didCreateSpace: space)
        if activeSpaceId == nil { activateSpace(id: space.id) }
        return space
    }

    func deleteSpace(id: UUID) throws {
        guard let index = spaceIndex(id: id) else { return }
        let space = spaces[index]

        if !space.isPrivate {
            try dbPool.write { db in
                guard let sortOrder = try Int.fetchOne(
                    db, sql: "DELETE FROM spaces WHERE id = ? RETURNING sortOrder", arguments: [space.id.uuidString]
                ) else {
                    throw SpaceManagerError.deleteFailed(space.id)
                }
                // sortOrder is unique: park the following rows on negative values before moving each down by one.
                try db.execute(sql: "UPDATE spaces SET sortOrder = -sortOrder WHERE sortOrder > ?", arguments: [sortOrder])
                try db.execute(sql: "UPDATE spaces SET sortOrder = -sortOrder - 1 WHERE sortOrder < 0")
            }
        }

        spaces.remove(at: index)
        unpersistedActiveTabSpaceIds.remove(id)
        let replacementIndex = index < spaces.count ? index : max(0, index - 1)
        let replacementSpaceId: UUID? = activeSpaceId == id ? spaces.indices.contains(replacementIndex) ? spaces[replacementIndex].id : nil : nil
        if activeSpaceId == id { activeSpaceId = replacementSpaceId }

        if !space.isPrivate { normalizeOrdering() }

        delegate?.spaceManager(self, didDeleteSpace: space)

        if let replacementSpaceId {
            delegate?.spaceManager(self, didActivateSpace: replacementSpaceId)
        }
    }

    /// Memory first, row written off-main: nothing downstream reads the row back synchronously.
    func updateSpace(id: UUID, mutate: (inout Space) -> Void) throws {
        guard let index = spaceIndex(id: id) else { return }
        mutate(&spaces[index]); spaces[index].modifiedAt = Date()
        let space = spaces[index]
        if !space.isPrivate {
            dbPool.asyncWrite({ db in try space.update(db) }, completion: { _, result in
                if case .failure(let error) = result {
                    Self.logger.error("space update write failed for \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            })
        }
        delegate?.spaceManager(self, didUpdateSpace: space)
    }

    func activateSpace(id: UUID) {
        guard spaceIndex(id: id) != nil else { return }
        activeSpaceId = id; delegate?.spaceManager(self, didActivateSpace: id)
    }

    func moveSpace(id: UUID, toIndex: Int) throws {
        guard let fromIndex = spaceIndex(id: id) else {
            StartupMetrics.trace("space-dnd", "stage=managerMoveSpaceMissing id=\(id.uuidString) toIndex=\(toIndex) order=\(StartupMetrics.spaceOrderDescription(spaces))")
            return
        }
        guard !spaces[fromIndex].isPrivate else {
            StartupMetrics.trace("space-dnd", "stage=managerMoveSpacePrivateIgnored id=\(id.uuidString) fromIndex=\(fromIndex) toIndex=\(toIndex) order=\(StartupMetrics.spaceOrderDescription(spaces))")
            return
        }

        var reorderedPersistentSpaces = persistentSpaces
        guard let persistentFromIndex = reorderedPersistentSpaces.firstIndex(where: { $0.id == id }) else {
            StartupMetrics.trace("space-dnd", "stage=managerMoveSpacePersistentMissing id=\(id.uuidString) fromIndex=\(fromIndex) toIndex=\(toIndex) order=\(StartupMetrics.spaceOrderDescription(spaces))")
            return
        }

        let persistentBefore = reorderedPersistentSpaces
        let space = reorderedPersistentSpaces.remove(at: persistentFromIndex)
        let safeIndex = max(0, min(toIndex, reorderedPersistentSpaces.count))
        StartupMetrics.trace(
            "space-dnd",
            "stage=managerMoveSpaceApply id=\(id.uuidString) fromIndex=\(fromIndex) persistentFromIndex=\(persistentFromIndex) requestedToIndex=\(toIndex) safeIndex=\(safeIndex) before=\(StartupMetrics.spaceOrderDescription(spaces)) persistentBefore=\(StartupMetrics.spaceOrderDescription(persistentBefore))"
        )

        reorderedPersistentSpaces.insert(space, at: safeIndex)

        for i in reorderedPersistentSpaces.indices { reorderedPersistentSpaces[i].sortOrder = i }

        let privateSpaces = spaces.filter(\.isPrivate)
        spaces = reorderedPersistentSpaces + privateSpaces

        let orderedSpaces = reorderedPersistentSpaces
        dbPool.asyncWrite({ db in
            // `spaces.sortOrder` is globally unique in the DB. Reordering rows by
            // updating them one by one with final indices can temporarily collide
            // with existing rows, so write a disjoint temporary ordering first.
            for (index, space) in orderedSpaces.enumerated() {
                try db.execute(
                    sql: "UPDATE spaces SET sortOrder = ? WHERE id = ?",
                    arguments: [-(index + 1), space.id.uuidString]
                )
            }

            for space in orderedSpaces {
                try space.update(db)
            }
        }, completion: { _, result in
            if case .failure(let error) = result {
                Self.logger.error("space reorder write failed: \(error.localizedDescription, privacy: .public)")
            }
        })

        StartupMetrics.trace(
            "space-dnd",
            "stage=managerMoveSpaceDone id=\(id.uuidString) safeIndex=\(safeIndex) after=\(StartupMetrics.spaceOrderDescription(spaces))"
        )
        delegate?.spaceManager(self, didReorderSpaces: spaces)
    }

    /// Activation is the hottest gesture: skip when unchanged, write off-main, and emit nothing, since the activation path already ships
    /// activeTabId and schedules its save. `persist: false` updates memory only; the next persisting call for that space writes the row.
    func setActiveTab(_ tabId: UUID?, forSpace spaceId: UUID, persist: Bool = true) {
        guard let index = spaceIndex(id: spaceId) else { return }
        let changed = spaces[index].activeTabId != tabId
        spaces[index].activeTabId = tabId
        guard !spaces[index].isPrivate else { return }
        guard persist else {
            if changed { unpersistedActiveTabSpaceIds.insert(spaceId) }
            return
        }
        guard unpersistedActiveTabSpaceIds.remove(spaceId) != nil || changed else { return }
        let space = spaces[index]
        dbPool.asyncWrite({ db in try space.update(db) }, completion: loggingPersistenceFailure("space.activeTab[\(spaceId.uuidString)]"))
    }

    private var persistentSpaces: [Space] {
        spaces.filter { !$0.isPrivate }
    }

    private func spaceIndex(id: UUID) -> Int? {
        spaces.firstIndex(where: { $0.id == id })
    }

    private func normalizeOrdering() {
        let orderedPersistentSpaces = spaces.filter { !$0.isPrivate }.sorted { l, r in
            l.sortOrder != r.sortOrder ? l.sortOrder < r.sortOrder :
            l.createdAt != r.createdAt ? l.createdAt < r.createdAt : l.id.uuidString < r.id.uuidString
        }
        let orderedPrivateSpaces = spaces.filter(\.isPrivate)

        spaces = orderedPersistentSpaces + orderedPrivateSpaces

        var nextSortOrder = 0
        for index in spaces.indices where !spaces[index].isPrivate {
            spaces[index].sortOrder = nextSortOrder
            nextSortOrder += 1
        }
    }
}
