import Foundation

/// Aggregates the per-OS-process diagnostics shown in the Process Manager panel from the browser's
/// spaces/engines. Pure read-only fan-in (engine to web/network/gpu/model processes, merged by pid);
/// it owns no state and lives outside `BrowserStateStore` so the store stays focused on tab/space state.
enum BrowserProcessSnapshotBuilder {
    private struct ProcessKey: Hashable {
        var kind: BrowserProcessKind
        var pid: Int
    }

    @MainActor
    static func build(
        spaces: [UUID: BrowserStateStore.SpaceSnapshot],
        visibleSpaceIds: Set<UUID>,
        projection: (BrowserStateStore.SpaceSnapshot) -> SpaceTabProjection,
        metricsProvider: (Set<Int>) -> [Int: ProcessResourceMetrics],
        diagnosticsProvider: (WKWebViewTab) -> WebViewProcessDiagnostics
    ) -> [BrowserProcessInfo] {
        var processesByKey: [ProcessKey: BrowserProcessInfo] = [:]

        for (spaceId, snapshot) in spaces.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let projection = projection(snapshot)
            let tabsById = Dictionary(uniqueKeysWithValues: projection.tabs.map { ($0.id, $0) })
            let lifecycleByTabId = snapshot.lifecycleByTabId(spaceId: spaceId, visibleSpaceIds: visibleSpaceIds, tabs: projection.tabs)

            for (tabId, engine) in snapshot.engines.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                let diagnostics = diagnosticsProvider(engine)
                let tab = tabsById[tabId]
                let tabInfo = tab.map {
                    BrowserProcessTabInfo(
                        id: tabId,
                        spaceId: spaceId,
                        title: $0.title,
                        url: $0.url?.absoluteString ?? diagnostics.committedURL ?? diagnostics.mainFrameURL ?? "",
                        lifecycle: processLifecycleLabel(lifecycleByTabId[tabId]),
                        isActiveSpace: visibleSpaceIds.contains(spaceId),
                        isActiveTab: tabId == snapshot.spaceTab.state.activeTabId,
                        isAudioPlaying: $0.isAudioPlaying,
                        isMicrophoneActive: $0.isMicrophoneActive,
                        isCameraActive: $0.isCameraActive,
                        isScreenSharing: $0.isScreenSharing,
                        isPictureInPictureActive: diagnostics.isPictureInPictureActive
                    )
                }

                addProcess(kind: .webContent, pid: diagnostics.webProcessIdentifier, diagnostics: diagnostics, tabInfo: tabInfo, processesByKey: &processesByKey)
                addProcess(kind: .provisionalWebContent, pid: diagnostics.provisionalWebProcessIdentifier, diagnostics: diagnostics, tabInfo: tabInfo, processesByKey: &processesByKey)
                addProcess(kind: .network, pid: diagnostics.networkProcessIdentifier, diagnostics: diagnostics, tabInfo: tabInfo, processesByKey: &processesByKey)
                addProcess(kind: .gpu, pid: diagnostics.gpuProcessIdentifier, diagnostics: diagnostics, tabInfo: tabInfo, processesByKey: &processesByKey)
                addProcess(kind: .model, pid: diagnostics.modelProcessIdentifier, diagnostics: diagnostics, tabInfo: tabInfo, processesByKey: &processesByKey)
            }
        }

        let metricsByPID = metricsProvider(Set(processesByKey.keys.map(\.pid)))
        for key in processesByKey.keys {
            processesByKey[key]?.metrics = metricsByPID[key.pid]
        }

        let kindOrder = BrowserProcessKind.allCases
        return processesByKey.values.sorted {
            $0.kind == $1.kind ? $0.pid < $1.pid : kindOrder.firstIndex(of: $0.kind)! < kindOrder.firstIndex(of: $1.kind)!
        }
    }

    private static func addProcess(
        kind: BrowserProcessKind,
        pid: Int?,
        diagnostics: WebViewProcessDiagnostics,
        tabInfo: BrowserProcessTabInfo?,
        processesByKey: inout [ProcessKey: BrowserProcessInfo]
    ) {
        guard let pid, pid > 0 else { return }

        let key = ProcessKey(kind: kind, pid: pid)
        var process = processesByKey[key] ?? BrowserProcessInfo(kind: kind, pid: pid)

        if let tabInfo,
           !process.tabs.contains(where: { $0.id == tabInfo.id && $0.spaceId == tabInfo.spaceId }) {
            process.tabs.append(tabInfo)
            process.tabs.sort {
                if $0.isActiveTab != $1.isActiveTab { return $0.isActiveTab }
                if $0.isActiveSpace != $1.isActiveSpace { return $0.isActiveSpace }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }

        if kind == .webContent || kind == .provisionalWebContent {
            process.webProcessState = process.webProcessState ?? diagnostics.webProcessState
            if let responsive = diagnostics.webProcessIsResponsive {
                process.webProcessIsResponsive = (process.webProcessIsResponsive ?? true) && responsive
            }
        }

        processesByKey[key] = process
    }

    private static func processLifecycleLabel(_ lifecycle: TabLifecycleCoordinator.LifecycleState?) -> String {
        switch lifecycle {
        case .active:
            return "active"
        case .loadedHidden:
            return "loaded-hidden"
        case .frozen:
            return "frozen"
        case .restoring:
            return "restoring"
        case .discarded:
            return "discarded"
        case nil:
            return "unknown"
        }
    }
}
