import Foundation
import WebKit

struct TabRuntimeSnapshot {
    let tabs: [Tab]
    let engines: [UUID: WKWebViewTab]
    var tabAdapters: [UUID: TabExtensionAdapter] = [:]
    let savedInteractionStates: [UUID: Any]
    let restoringTabIds: [UUID: Date]
    let activeTabId: UUID?
}

@MainActor
final class EngineHost {
    private let engineFactory: WKEngineFactory
    private var engines: [UUID: WKWebViewTab] = [:]
    private var tabAdapters: [UUID: TabExtensionAdapter] = [:]
    private var savedInteractionStates: [UUID: Any] = [:]
    /// Recency order (most-recent first) over `savedInteractionStates` keys. Caps the retained blobs
    /// (back/forward list, scroll, form state), one per discarded-but-open tab; a tab whose blob is
    /// evicted falls back to a fresh `loadURL` on reactivation instead of a silent restore.
    private var interactionStateLRU: [UUID] = []
    private let maxSavedInteractionStates = 50
    private(set) var restoringTabIds: [UUID: Date] = [:]

    /// Bumped by every mutation of the runtime maps above, so callers that re-snapshot them
    /// (`syncActiveBrowserState` via `browserSnapshot`) can early-return when nothing changed. A no-op
    /// write still ticks it, which costs an extra sync but never skips one.
    private(set) var mutationVersion: UInt64 = 0
    private func didMutate() { mutationVersion &+= 1 }

    init(engineFactory: WKEngineFactory) {
        self.engineFactory = engineFactory
    }

    /// Live engine ids, without materializing a full runtime snapshot.
    var liveEngineIds: Set<UUID> { Set(engines.keys) }

    func engine(for id: UUID) -> WKWebViewTab? {
        engines[id]
    }

    func engine(forWebView webView: WKWebView) -> WKWebViewTab? {
        engines.values.first { $0.ownsWebView(webView) }
    }

    func tabAdapter(for id: UUID) -> TabExtensionAdapter? {
        tabAdapters[id]
    }

    func createEngine(
        dataStore: WKEngineDataStore,
        profileId: UUID?,
        tabId: UUID?,
        nativeConfiguration: WKWebViewConfiguration? = nil,
        markRestoring: Bool = false
    ) -> WKWebViewTab {
        let config = WKEngineFactory.Configuration(
            dataStore: dataStore,
            tabId: tabId,
            nativeConfiguration: nativeConfiguration,
            profileId: profileId,
            refillsWarmPool: !markRestoring
        )
        let engine = engineFactory.createTab(configuration: config)
        engines[engine.id] = engine
        if markRestoring {
            restoringTabIds[engine.id] = Date()
        }
        didMutate()
        return engine
    }

    /// Registers an engine built outside the host (a page popup becoming a tab).
    func adopt(_ engine: WKWebViewTab) {
        engines[engine.id] = engine
        didMutate()
    }

    func removeEngine(for id: UUID) -> WKWebViewTab? {
        let engine = engines.removeValue(forKey: id)
        removeRuntime(for: id)
        return engine
    }

    func teardown(_ engine: WKWebViewTab?) {
        guard let engine else { return }
        // Deferred so the caller's stack unwinds before releasing the WKWebView.
        DispatchQueue.main.async { engine.teardown() }
    }

    func setTabAdapter(_ adapter: TabExtensionAdapter, for id: UUID) {
        tabAdapters[id] = adapter
        didMutate()
    }

    func removeTabAdapter(for id: UUID) -> TabExtensionAdapter? {
        guard let adapter = tabAdapters.removeValue(forKey: id) else { return nil }
        (adapter.extensionWindow as? WindowExtensionAdapter)?.remove(tab: adapter)
        didMutate()
        return adapter
    }

    /// Drops every adapter outside `keptIds` and returns them. A dropped adapter is still registered
    /// with its extension controller, so the caller must retire it (`didCloseTab`) or WebKit keeps an
    /// "open" extension tab over a torn-down web view.
    func pruneTabAdapters(keeping keptIds: Set<UUID>) -> [TabExtensionAdapter] {
        let removedIds = tabAdapters.keys.filter { !keptIds.contains($0) }
        return removedIds.compactMap { removeTabAdapter(for: $0) }
    }

    private func removeRuntime(for id: UUID) {
        savedInteractionStates.removeValue(forKey: id)
        interactionStateLRU.removeAll { $0 == id }
        restoringTabIds.removeValue(forKey: id)
        didMutate()
    }

    /// Stash a discarded engine's interaction state for a later silent restore, marking it most-recently
    /// used and evicting the least-recently-used blob if the cap is exceeded.
    func saveInteractionState(_ state: Any, for id: UUID) {
        savedInteractionStates[id] = state
        interactionStateLRU.removeAll { $0 == id }
        interactionStateLRU.insert(id, at: 0)
        enforceInteractionStateCap()
        didMutate()
    }

    private func enforceInteractionStateCap() {
        guard interactionStateLRU.count > maxSavedInteractionStates else { return }
        for evicted in interactionStateLRU[maxSavedInteractionStates...] {
            savedInteractionStates.removeValue(forKey: evicted)
        }
        interactionStateLRU.removeLast(interactionStateLRU.count - maxSavedInteractionStates)
    }

    /// The most-recently-stashed interaction-state blobs (discarded-but-open tabs), newest first, up to
    /// `limit`. The disk-persistence layer writes this bounded "N recent" set alongside the active tab's
    /// live state: far fewer main-thread archive encodes than persisting the whole LRU.
    func recentSavedInteractionStates(limit: Int) -> [(id: UUID, state: Any)] {
        interactionStateLRU.prefix(limit).compactMap { id in
            savedInteractionStates[id].map { (id, $0) }
        }
    }

    /// The tab's back/forward list, scroll and form state: its live page's, else the one stashed when it was discarded.
    func interactionState(for id: UUID) -> Any? {
        if let engine = engines[id] { return engine.interactionState }
        let state = savedInteractionStates[id]
        if let archived = state as? ArchivedInteractionState { return InteractionStateCodec.decode(archived.data) }
        return state
    }

    func consumeSavedInteractionState(for id: UUID) -> Any? {
        defer { didMutate() }
        interactionStateLRU.removeAll { $0 == id }
        let state = savedInteractionStates.removeValue(forKey: id)
        if let archived = state as? ArchivedInteractionState { return InteractionStateCodec.decode(archived.data) }
        return state
    }

    func replaceSavedInteractionStates(_ states: [UUID: Any], validTabIds: Set<UUID>) {
        savedInteractionStates = states.filter { validTabIds.contains($0.key) }
        // Preserve existing recency order for surviving ids, then append any newly-introduced ones.
        let keys = Set(savedInteractionStates.keys)
        interactionStateLRU = interactionStateLRU.filter { keys.contains($0) }
            + savedInteractionStates.keys.filter { !interactionStateLRU.contains($0) }
        enforceInteractionStateCap()
        didMutate()
    }

    func replaceEngines(
        _ newEngines: [UUID: WKWebViewTab],
        validTabIds: Set<UUID>
    ) -> (engines: [WKWebViewTab], adapters: [TabExtensionAdapter]) {
        let oldEngines = engines
        engines = newEngines
        let droppedAdapters = pruneTabAdapters(keeping: validTabIds)
        restoringTabIds = restoringTabIds.filter { validTabIds.contains($0.key) && newEngines[$0.key] != nil }
        didMutate()
        return (Array(oldEngines.values), droppedAdapters)
    }

    /// Swaps the adapter map, returning every adapter it strands (displaced, absent, or rejected by `validTabIds`): each was announced
    /// via `didOpenTab` and stays registered until closed, so the caller must retire them.
    func restoreTabAdapters(
        _ adapters: [UUID: TabExtensionAdapter],
        validTabIds: Set<UUID>
    ) -> [TabExtensionAdapter] {
        let restored = adapters.filter { validTabIds.contains($0.key) }
        let survivors = Set(restored.values.map(ObjectIdentifier.init))

        // Both the outgoing map and the incoming one can strand an adapter, and the same object can
        // appear in both, so dedupe by identity.
        var stranded: [TabExtensionAdapter] = []
        var seen = Set<ObjectIdentifier>()
        for adapter in Array(tabAdapters.values) + Array(adapters.values) {
            let identity = ObjectIdentifier(adapter)
            guard !survivors.contains(identity), seen.insert(identity).inserted else { continue }
            stranded.append(adapter)
        }

        tabAdapters = restored
        for adapter in stranded {
            (adapter.extensionWindow as? WindowExtensionAdapter)?.remove(tab: adapter)
        }
        didMutate()
        return stranded
    }

    func replaceRestoringTabIds(_ ids: [UUID: Date]) {
        restoringTabIds = ids.filter { engines[$0.key] != nil }
        didMutate()
    }

    func snapshot(tabs: [Tab], activeTabId: UUID?) -> TabRuntimeSnapshot {
        TabRuntimeSnapshot(
            tabs: tabs,
            engines: engines,
            tabAdapters: tabAdapters,
            savedInteractionStates: savedInteractionStates,
            restoringTabIds: restoringTabIds,
            activeTabId: activeTabId
        )
    }

    /// The one place adapters leave this map unretired: the caller's `TabRuntimeSnapshot` keeps them registered for `restoreTabAdapters`.
    /// Anything that drops that snapshot instead of restoring it owes them a `didCloseTab`.
    func parkRuntimeForSpaceSwitch() {
        engines = [:]
        tabAdapters = [:]
        savedInteractionStates = [:]
        interactionStateLRU = []
        restoringTabIds = [:]
        didMutate()
    }

    func markRestorationFinished(for id: UUID) {
        restoringTabIds.removeValue(forKey: id)
        didMutate()
    }
}
