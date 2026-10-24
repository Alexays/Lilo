import Foundation
import GRDB

/// Owns the write path for per-space tab state, routing each write to the profile's live
/// `SessionPersistence` when one exists, or to the profile's pool otherwise.
@MainActor
final class SessionPersistenceCoordinator {
    private let dbManager: DatabaseManager
    private let liveStore: (UUID) -> SessionPersistence?

    init(dbManager: DatabaseManager, liveStore: @escaping (UUID) -> SessionPersistence?) {
        self.dbManager = dbManager
        self.liveStore = liveStore
    }

    func persistSpaceTabState(_ state: SpaceTabState, spaceId: UUID, inProfile profileId: UUID) throws {
        if let persistence = liveStore(profileId) {
            try persistence.saveSpaceTabState(state, spaceId: spaceId)
            return
        }
        let tabPool = try dbManager.pool(for: profileId)
        try SpaceTabStateStore(dbPool: tabPool).saveMany([(spaceId: spaceId, state: state)])
    }

    func persistSpaceTabStates(_ states: [(spaceId: UUID, state: SpaceTabState)], inProfile profileId: UUID) throws {
        if let persistence = liveStore(profileId) {
            try persistence.saveSpaceTabStates(states)
            return
        }
        let tabPool = try dbManager.pool(for: profileId)
        try SpaceTabStateStore(dbPool: tabPool).saveMany(states)
    }

    func persistMovedSpaceTabStates(
        _ sourceState: BrowserSpaceChange,
        sourceProfileId: UUID,
        _ targetState: BrowserSpaceChange,
        targetProfileId: UUID
    ) throws {
        if sourceProfileId == targetProfileId {
            try persistSpaceTabStates(
                [
                    (spaceId: sourceState.spaceId, state: sourceState.state),
                    (spaceId: targetState.spaceId, state: targetState.state)
                ],
                inProfile: sourceProfileId
            )
            return
        }

        try persistSpaceTabState(sourceState.state, spaceId: sourceState.spaceId, inProfile: sourceProfileId)
        try persistSpaceTabState(targetState.state, spaceId: targetState.spaceId, inProfile: targetProfileId)
    }

    func deleteSpaceTabState(forSpace spaceId: UUID, inProfile profileId: UUID) throws {
        let pool = try dbManager.pool(for: profileId)
        try SpaceTabStateStore(dbPool: pool).delete(spaceId: spaceId)
    }
}
