import Foundation

/// Computes the read-only tab-lifecycle diagnostics (live/restoring/discarded engine counts, hidden
/// spaces still holding engines) from the browser's spaces. Pure aggregation that owns no state,
/// kept out of `BrowserStateStore` so the store stays focused on tab/space state + engine lifecycle.
enum BrowserLifecycleDiagnosticsBuilder {
    @MainActor
    static func build(
        spaces: [UUID: BrowserStateStore.SpaceSnapshot],
        visibleSpaceIds: Set<UUID>,
        projection: (BrowserStateStore.SpaceSnapshot) -> SpaceTabProjection
    ) -> TabLifecycleDiagnostics {
        var diagnostics = TabLifecycleDiagnostics(trackedSpaceCount: spaces.count)

        for (spaceId, snapshot) in spaces {
            let engineCount = snapshot.engines.count
            diagnostics.totalLiveEngineCount += engineCount
            diagnostics.restoringTabCount += snapshot.restoringTabIds.count
            diagnostics.savedInteractionStateCount += snapshot.interactionStates.count

            let projection = projection(snapshot)
            let lifecycleByTabId = snapshot.lifecycleByTabId(spaceId: spaceId, visibleSpaceIds: visibleSpaceIds, tabs: projection.tabs)
            diagnostics.discardedOpenTabCount += lifecycleByTabId.values.filter {
                if case .discarded = $0 { return true }
                return false
            }.count

            if visibleSpaceIds.contains(spaceId) {
                diagnostics.activeSpaceEngineCount += engineCount
            } else {
                diagnostics.hiddenSpaceEngineCount += engineCount
                guard engineCount > 0 else { continue }
                var engineTabs: [UUID: Tab] = [:]
                for tab in projection.tabs where snapshot.engines[tab.id] != nil { engineTabs[tab.id] = tab }
                let hasNormalRetainedEngine = snapshot.engines.keys.contains { engineId in
                    guard let tab = engineTabs[engineId] else {
                        return true
                    }
                    // A frozen engine is still a live, normally-retained engine, just suspended.
                    return (lifecycleByTabId[engineId] == .loadedHidden || lifecycleByTabId[engineId] == .frozen) &&
                        !tab.isAudioPlaying &&
                        tab.lastAudioStoppedAt == nil &&
                        !tab.isMicrophoneActive && !tab.isCameraActive && !tab.isScreenSharing &&
                        tab.lastCaptureStoppedAt == nil &&
                        snapshot.restoringTabIds[engineId] == nil
                }
                if hasNormalRetainedEngine {
                    diagnostics.hiddenSpacesWithNormalRetainedEngines += 1
                }
            }
        }

        return diagnostics
    }
}
