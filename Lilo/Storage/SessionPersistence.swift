import Foundation
import GRDB
import os

/// Debounced session persistence: saves tab & space state to SQLite.
/// Triggers on meaningful state changes with a 2-second debounce.
@MainActor
final class SessionPersistence {

    private static let logger = Logger(liloCategory: "storage")

    /// Dedup key for `scheduleSave`: `durableRevision` bumps on every durable mutation, so an equal key means unchanged bytes. A space
    /// reloaded into the store restarts its count under a new structure token, which keeps keys distinct.
    struct SaveDedupKey: Equatable {
        let spaceId: UUID
        let structureToken: UUID
        let durableRevision: UInt64
    }

    private let tabDBPool: DatabasePool
    /// The profile's spaces shown in some window, whichever window asked for the save.
    private let displayedSpaceIds: () -> [UUID]
    private let stateProvider: (UUID) -> SpaceTabState?
    /// Cheap dedup key per space. When present and unchanged since the last schedule, the
    /// repair + deep-compare prelude is short-circuited. Returning nil (tests) takes the
    /// repair + deep-compare path.
    private let dedupKeyProvider: (UUID) -> SaveDedupKey?
    private var saveTimer: Timer?
    private let debounceInterval: TimeInterval = 2.0
    private var pendingStatesBySpaceId: [UUID: SpaceTabState] = [:]
    /// Snapshot last seen per space, used to short-circuit byte-identical no-op saves and to gate
    /// the error-recovery re-enqueue. Repaired on the keyless path; raw on the fast path (each path
    /// compares against what it stored, so the two never mix).
    private var lastSnapshotsBySpaceId: [UUID: SpaceTabState] = [:]
    /// Last dedup key scheduled per space; short-circuits repair+compare when unchanged.
    private var lastDedupKeysBySpaceId: [UUID: SaveDedupKey] = [:]

    init(
        tabDBPool: DatabasePool,
        displayedSpaceIds: @escaping () -> [UUID],
        stateProvider: @escaping (UUID) -> SpaceTabState?,
        dedupKeyProvider: @escaping (UUID) -> SaveDedupKey?
    ) {
        self.tabDBPool = tabDBPool
        self.displayedSpaceIds = displayedSpaceIds
        self.stateProvider = stateProvider
        self.dedupKeyProvider = dedupKeyProvider
    }

    /// Schedule a debounced save of every displayed space whose durable state changed.
    func scheduleSave() {
        var enqueued = false
        for spaceId in displayedSpaceIds() {
            if let key = dedupKeyProvider(spaceId) {
                // Fast path: the revision is the change-detector. An equal key means nothing durable
                // changed, so skip without deep-comparing the tree. Encode-time repair happens in
                // writeManyOn; lastSnapshots is still recorded for saveNow's error-recovery re-enqueue check.
                if lastDedupKeysBySpaceId[spaceId] == key { continue }
                guard let state = stateProvider(spaceId) else { continue }
                lastDedupKeysBySpaceId[spaceId] = key
                lastSnapshotsBySpaceId[spaceId] = state
                pendingStatesBySpaceId[spaceId] = state
            } else {
                // No dedup key (exercised by tests): repair + deep-compare to skip identical saves.
                guard let state = stateProvider(spaceId) else { continue }
                let snapshot = SpaceTabStateRepair.repaired(state)
                if lastSnapshotsBySpaceId[spaceId] == snapshot { continue }
                lastSnapshotsBySpaceId[spaceId] = snapshot
                pendingStatesBySpaceId[spaceId] = snapshot
            }
            enqueued = true
        }
        if enqueued { armSaveTimer() }
    }

    private func armSaveTimer() {
        saveTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.saveNow() }
        }
        // Lets the system coalesce the fire with other wakeups; the save need not be precise.
        timer.tolerance = debounceInterval / 2
        saveTimer = timer
    }

    /// Async debounced flush: snapshot captured on the main actor, encode + write on GRDB's writer queue.
    /// Durability gap: between the synchronous drain and the async completion, states live only in the
    /// writer queue: a crash in that window loses them; shutdown-class callers must use the synchronous paths.
    func saveNow() {
        guard !pendingStatesBySpaceId.isEmpty else {
            PerfSignposts.energy.emitEvent("sessionSave", "skipped")
            return
        }
        let pendingStates = pendingStatesBySpaceId.map { (spaceId: $0.key, state: $0.value) }
        let count = pendingStates.count
        PerfSignposts.energy.emitEvent("sessionSave", "written: \(count) spaces")
        pendingStatesBySpaceId.removeAll()

        tabDBPool.asyncWrite({ db in
            try SpaceTabStateStore.writeManyOn(db: db, states: pendingStates)
        }, completion: { [weak self] _, result in
            if case .failure(let error) = result {
                Task { @MainActor [weak self] in
                    Self.logger.error("saveNow ERROR: \(error.localizedDescription)")
                    guard let self else { return }
                    var restoredCount = 0
                    for state in pendingStates
                        where self.pendingStatesBySpaceId[state.spaceId] == nil
                        && self.lastSnapshotsBySpaceId[state.spaceId] == state.state {
                        self.pendingStatesBySpaceId[state.spaceId] = state.state
                        restoredCount += 1
                    }
                    if restoredCount > 0 && self.saveTimer?.isValid != true {
                        self.armSaveTimer()
                    }
                }
            }
        })
    }

    func saveSpaceTabState(_ state: SpaceTabState, spaceId: UUID) throws {
        try SpaceTabStateStore(dbPool: tabDBPool).saveMany([(spaceId: spaceId, state: state)])
        pendingStatesBySpaceId.removeValue(forKey: spaceId)
        lastSnapshotsBySpaceId[spaceId] = SpaceTabStateRepair.repaired(state)
    }

    /// Space-switch variant of saveSpaceTabState: bookkeeping and updateActiveTab run on the main
    /// actor, the blob write hops to the writer queue so the transition never blocks on disk.
    /// Shutdown-class callers must keep using the synchronous variant.
    func saveSpaceTabStateAsync(
        _ state: SpaceTabState,
        spaceId: UUID,
        updateActiveTab: ((UUID?, UUID) -> Void)? = nil
    ) {
        let repaired = SpaceTabStateRepair.repaired(state)
        // Nothing pending and an equal last snapshot: the store already holds (or is writing) these bytes.
        let unchanged = pendingStatesBySpaceId[spaceId] == nil
            && lastSnapshotsBySpaceId[spaceId].map { $0 == repaired || $0 == state } == true
        pendingStatesBySpaceId.removeValue(forKey: spaceId)
        lastSnapshotsBySpaceId[spaceId] = repaired
        updateActiveTab?(state.activeTabId, spaceId)
        PerfSignposts.energy.emitEvent("spaceSwitchSave", "\(unchanged ? "skipped" : "written", privacy: .public)")
        if unchanged { return }
        tabDBPool.asyncWrite({ db in
            try SpaceTabStateStore.writeManyOn(db: db, states: [(spaceId: spaceId, state: state)])
        }, completion: { [weak self] _, result in
            if case .failure(let error) = result {
                Task { @MainActor [weak self] in
                    Self.logger.error("space-switch save ERROR: \(error.localizedDescription)")
                    // Forget the unwritten snapshot so the next switch away retries the write.
                    if self?.lastSnapshotsBySpaceId[spaceId] == repaired { self?.lastSnapshotsBySpaceId.removeValue(forKey: spaceId) }
                }
            }
        })
    }

    func saveSpaceTabStates(_ states: [(spaceId: UUID, state: SpaceTabState)]) throws {
        saveTimer?.invalidate()
        saveTimer = nil
        let savedSpaceIds = Set(states.map(\.spaceId))

        try SpaceTabStateStore(dbPool: tabDBPool).saveMany(states)
        for state in states {
            lastSnapshotsBySpaceId[state.spaceId] = SpaceTabStateRepair.repaired(state.state)
        }
        pendingStatesBySpaceId = pendingStatesBySpaceId.filter { !savedSpaceIds.contains($0.key) }
    }

    func restoreSpaceTabState(forSpace spaceId: UUID) throws -> SpaceTabState {
        guard let stored = try SpaceTabStateStore(dbPool: tabDBPool).load(spaceId: spaceId) else {
            // No cached snapshot: the store holds nothing, so a later scheduleSave must run.
            lastSnapshotsBySpaceId.removeValue(forKey: spaceId)
            return SpaceTabState(
                activeTabId: nil,
                activationHistory: [],
                tree: .empty
            )
        }

        // `load` already returns the repaired form the store persisted; seed the cache so an
        // unchanged scheduleSave right after restore is recognized as a no-op.
        lastSnapshotsBySpaceId[spaceId] = stored
        return stored
    }
}
