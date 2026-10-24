import Foundation

struct TabLifecycleDiagnostics: Sendable, Equatable {
    var trackedSpaceCount: Int = 0
    var activeSpaceEngineCount: Int = 0
    var hiddenSpaceEngineCount: Int = 0
    var totalLiveEngineCount: Int = 0
    var restoringTabCount: Int = 0
    var savedInteractionStateCount: Int = 0
    var discardedOpenTabCount: Int = 0
    var hiddenSpacesWithNormalRetainedEngines: Int = 0

    var bridgeData: [String: Any] {
        [
            "trackedSpaceCount": trackedSpaceCount,
            "activeSpaceEngineCount": activeSpaceEngineCount,
            "hiddenSpaceEngineCount": hiddenSpaceEngineCount,
            "totalLiveEngineCount": totalLiveEngineCount,
            "restoringTabCount": restoringTabCount,
            "savedInteractionStateCount": savedInteractionStateCount,
            "discardedOpenTabCount": discardedOpenTabCount,
            "hiddenSpacesWithNormalRetainedEngines": hiddenSpacesWithNormalRetainedEngines
        ]
    }

    var traceMessage: String {
        [
            "spaces=\(trackedSpaceCount)",
            "activeEngines=\(activeSpaceEngineCount)",
            "hiddenEngines=\(hiddenSpaceEngineCount)",
            "liveEngines=\(totalLiveEngineCount)",
            "restoring=\(restoringTabCount)",
            "interactionStates=\(savedInteractionStateCount)",
            "discardedOpenTabs=\(discardedOpenTabCount)",
            "hiddenSpacesWithNormalEngines=\(hiddenSpacesWithNormalRetainedEngines)"
        ].joined(separator: " ")
    }
}

struct TabLifecycleCoordinator {
    enum Policy: Equatable {
        case foreground
        case background
    }

    enum LifecycleState: Sendable, Equatable {
        case active
        case loadedHidden
        case frozen
        case restoring(startedAt: Date)
        case discarded
    }

    struct HiddenSpace {
        var id: UUID
        var tabs: [Tab]
        var retainedEngineIds: Set<UUID>
        var restoringTabIds: [UUID: Date] = [:]
        var lastAccessedAt: Date
    }

    var maxNormalRetainedEnginesPerHiddenSpace = 1
    var maxHiddenSpacesWithNormalRetainedEngines = 2
    var audioGracePeriod: TimeInterval = 30
    var captureGracePeriod: TimeInterval = 30
    var restorationGracePeriod: TimeInterval = 10
    /// A tab paused from the media card keeps its playback session this long, to play again from the card.
    var cardPauseGracePeriod: TimeInterval = 30 * 60
    var policy: Policy = .foreground

    private var effectiveMaxNormalRetainedEnginesPerHiddenSpace: Int {
        switch policy {
        case .foreground:
            return maxNormalRetainedEnginesPerHiddenSpace
        case .background:
            return 0
        }
    }

    private var effectiveMaxHiddenSpacesWithNormalRetainedEngines: Int {
        switch policy {
        case .foreground:
            return maxHiddenSpacesWithNormalRetainedEngines
        case .background:
            return 0
        }
    }

    func retainedEngineIds(
        tabs: [Tab],
        availableEngineIds: Set<UUID>,
        preferredTabId: UUID?,
        restoringTabIds: [UUID: Date] = [:],
        now: Date = Date()
    ) -> Set<UUID> {
        let protectedIds = Set(tabs.lazy.filter { !$0.isClosed && shouldRetainProtected($0, restoringTabIds: restoringTabIds, now: now) }.map(\.id))
        var normalIds: [UUID] = []

        if let preferredTabId,
           availableEngineIds.contains(preferredTabId),
           !protectedIds.contains(preferredTabId),
           tabs.contains(where: { $0.id == preferredTabId && !$0.isClosed }) {
            normalIds.append(preferredTabId)
        }

        if normalIds.count < effectiveMaxNormalRetainedEnginesPerHiddenSpace,
           let firstOpenNormal = tabs.first(where: {
               !$0.isClosed &&
               !shouldRetainProtected($0, restoringTabIds: restoringTabIds, now: now) &&
               availableEngineIds.contains($0.id) &&
               !normalIds.contains($0.id)
           }) {
            normalIds.append(firstOpenNormal.id)
        }

        return protectedIds.union(normalIds.prefix(effectiveMaxNormalRetainedEnginesPerHiddenSpace))
    }

    func hiddenSpacesToEvict(_ spaces: [HiddenSpace], protectedSpaceId: UUID?, now: Date = Date()) -> Set<UUID> {
        let candidates = spaces
            .filter { space in
                guard space.id != protectedSpaceId, !space.retainedEngineIds.isEmpty else { return false }
                var engineTabs: [UUID: Tab] = [:]
                for tab in space.tabs where space.retainedEngineIds.contains(tab.id) { engineTabs[tab.id] = tab }
                return space.retainedEngineIds.contains { engineId in
                    guard let tab = engineTabs[engineId] else {
                        return true
                    }
                    return !shouldRetainProtected(tab, restoringTabIds: space.restoringTabIds, now: now)
                }
            }
            .sorted { $0.lastAccessedAt < $1.lastAccessedAt }

        guard candidates.count > effectiveMaxHiddenSpacesWithNormalRetainedEngines else {
            return []
        }

        return Set(candidates.prefix(candidates.count - effectiveMaxHiddenSpacesWithNormalRetainedEngines).map(\.id))
    }

    func protectedEngineIds(
        tabs: [Tab],
        availableEngineIds: Set<UUID>,
        restoringTabIds: [UUID: Date] = [:],
        now: Date = Date()
    ) -> Set<UUID> {
        engineIds(tabs: tabs, availableEngineIds: availableEngineIds) {
            shouldRetainProtected($0, restoringTabIds: restoringTabIds, now: now)
        }
    }

    /// Open tabs with a live engine that satisfy `shouldRetain`.
    private func engineIds(
        tabs: [Tab],
        availableEngineIds: Set<UUID>,
        matching shouldRetain: (Tab) -> Bool
    ) -> Set<UUID> {
        var ids: Set<UUID> = []
        for tab in tabs where !tab.isClosed && availableEngineIds.contains(tab.id) && shouldRetain(tab) {
            ids.insert(tab.id)
        }
        return ids
    }

    /// Active-space engines to keep: the active tab, protected tabs, then the most recent up to `maxLiveEngines`. That budget is caller-owned
    /// (`activeSpaceTrimBudget`) and `policy` does not override it, so a stray `.background` cannot collapse a budgeted space.
    func activeSpaceEnginesToKeep(
        tabs: [Tab],
        availableEngineIds: Set<UUID>,
        activeTabId: UUID?,
        activationHistory: [UUID],
        maxLiveEngines: Int,
        restoringTabIds: [UUID: Date] = [:],
        lastActiveAt: [UUID: Date] = [:],
        discardThreshold: TimeInterval = .infinity,
        now: Date = Date()
    ) -> Set<UUID> {
        var keep = protectedEngineIds(
            tabs: tabs,
            availableEngineIds: availableEngineIds,
            restoringTabIds: restoringTabIds,
            now: now
        )
        let budget = maxLiveEngines
        if let activeTabId, availableEngineIds.contains(activeTabId),
           tabs.contains(where: { $0.id == activeTabId && !$0.isClosed }) {
            keep.insert(activeTabId)
        }
        let openIds = Set(tabs.lazy.filter { !$0.isClosed }.map(\.id))
        let remaining = budget - keep.count
        if remaining > 0 {
            let mru = activationHistory.filter {
                availableEngineIds.contains($0) && openIds.contains($0) && !keep.contains($0)
            }
            keep.formUnion(mru.prefix(remaining))
        }
        // A tab opened in the background is live but was never activated, so no history lists it:
        // without this the next trim discards the page the user just queued up.
        let unvisitedRemaining = budget - keep.count
        if unvisitedRemaining > 0 {
            let visited = Set(activationHistory)
            // Eager: a lazy filter reading `keep` while formUnion mutates it traps on exclusivity.
            let unvisited = tabs
                .filter { !$0.isClosed && availableEngineIds.contains($0.id) && !visited.contains($0.id) && !keep.contains($0.id) }
                .prefix(unvisitedRemaining)
                .map(\.id)
            keep.formUnion(unvisited)
        }
        guard discardThreshold.isFinite else { return keep }
        // Idle eviction: drop engines idle beyond the threshold, except the active tab and protected ones.
        let mandatory = idleDiscardProtectedEngineIds(
            tabs: tabs, availableEngineIds: availableEngineIds,
            restoringTabIds: restoringTabIds, now: now)
            .union(activeTabId.map { [$0] } ?? [])
        return keep.filter { id in
            if mandatory.contains(id) { return true }
            guard let last = lastActiveAt[id] else { return true }   // unknown idle time: keep
            return now.timeIntervalSince(last) <= discardThreshold
        }
    }

    func lifecycleStates(
        tabs: [Tab],
        availableEngineIds: Set<UUID>,
        activeTabId: UUID?,
        restoringTabIds: [UUID: Date] = [:],
        frozenTabIds: Set<UUID> = []
    ) -> [UUID: LifecycleState] {
        Dictionary(uniqueKeysWithValues: tabs.compactMap { tab in
            guard !tab.isClosed else { return nil }
            if tab.id == activeTabId {
                return (tab.id, .active)
            }
            if let restorationStartedAt = restoringTabIds[tab.id] {
                return (tab.id, .restoring(startedAt: restorationStartedAt))
            }
            if availableEngineIds.contains(tab.id) {
                return (tab.id, frozenTabIds.contains(tab.id) ? .frozen : .loadedHidden)
            }
            return (tab.id, .discarded)
        })
    }

    /// Idle discard also spares pinned tabs and tabs with unsaved form input. They can still be frozen
    /// and stay subject to budget, LRU and memory-pressure eviction, which use `shouldRetainProtected`.
    private func shouldRetainFromIdleDiscard(_ tab: Tab, restoringTabIds: [UUID: Date], now: Date) -> Bool {
        shouldRetainProtected(tab, restoringTabIds: restoringTabIds, now: now) ||
            tab.isPinned ||
            tab.hasUnsavedFormData
    }

    func idleDiscardProtectedEngineIds(
        tabs: [Tab],
        availableEngineIds: Set<UUID>,
        restoringTabIds: [UUID: Date] = [:],
        now: Date = Date()
    ) -> Set<UUID> {
        engineIds(tabs: tabs, availableEngineIds: availableEngineIds) {
            shouldRetainFromIdleDiscard($0, restoringTabIds: restoringTabIds, now: now)
        }
    }

    private func shouldRetainProtected(_ tab: Tab, restoringTabIds: [UUID: Date], now: Date) -> Bool {
        tab.isAgentControlled ||
            shouldRetainForAudio(tab, now: now) ||
            shouldRetainForCapture(tab, now: now) ||
            shouldRetainForRestoration(tab, restoringTabIds: restoringTabIds, now: now)
    }

    private func shouldRetainForAudio(_ tab: Tab, now: Date) -> Bool {
        if tab.isAudioPlaying { return true }
        if let pausedFromCardAt = tab.pausedFromCardAt, now.timeIntervalSince(pausedFromCardAt) <= cardPauseGracePeriod { return true }
        guard let lastAudioStoppedAt = tab.lastAudioStoppedAt else { return false }
        return now.timeIntervalSince(lastAudioStoppedAt) <= audioGracePeriod
    }

    private func shouldRetainForCapture(_ tab: Tab, now: Date) -> Bool {
        if tab.isMicrophoneActive || tab.isCameraActive || tab.isScreenSharing { return true }
        // Mirror the audio grace: WebKit emits a transient `.none` capture state on mute/unmute,
        // device switches and track renegotiation while a call is still live. Without a grace window,
        // a trim scheduled on the very next tab switch would discard the still-in-call engine.
        guard let lastCaptureStoppedAt = tab.lastCaptureStoppedAt else { return false }
        return now.timeIntervalSince(lastCaptureStoppedAt) <= captureGracePeriod
    }

    private func shouldRetainForRestoration(_ tab: Tab, restoringTabIds: [UUID: Date], now: Date) -> Bool {
        guard let restorationStartedAt = restoringTabIds[tab.id] else { return false }
        return now.timeIntervalSince(restorationStartedAt) <= restorationGracePeriod
    }
}

extension TabLifecycleCoordinator {
    // Declared in an extension so Swift still synthesizes the struct's memberwise init.
    init(config: LifecyclePolicyConfig, policy: Policy = .foreground) {
        self.maxNormalRetainedEnginesPerHiddenSpace = config.maxNormalRetainedEnginesPerHiddenSpace
        self.maxHiddenSpacesWithNormalRetainedEngines = config.maxHiddenSpacesWithNormalRetainedEngines
        self.audioGracePeriod = config.audioGracePeriod
        self.captureGracePeriod = config.captureGracePeriod
        self.restorationGracePeriod = config.restorationGracePeriod
        self.policy = policy
    }
}
