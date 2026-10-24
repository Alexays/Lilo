import WebKit

/// The `chrome.tabs` calls WebKit lacks besides grouping: zoom settings and split views, which are Lilo's
/// split folders. Tabs arrive as `{windowPosition, index}` pairs (see `TabGroupsBridgeHandler`).
@MainActor
final class TabsBridgeHandler: GapHandler {
    let gapActions: Set<String> = ["tabs.getZoomSettings", "tabs.setZoomSettings", "tabs.createSplit", "tabs.unsplit"]

    /// Chrome's `SPLIT_VIEW_ID_NONE`.
    private static let splitViewIdNone = -1

    /// A window showing the calling extension's profile, from its registry.
    private let contextProvider: (ProfileExtensionRegistry) -> TabGroupsContext?

    // Stable per-session bijection between Chrome split view ids and Lilo split folders.
    private var folderIdBySplitId: [Int: UUID] = [:]
    private var splitIdByFolderId: [UUID: Int] = [:]
    private var nextSplitId = 1

    init(contextProvider: @escaping (ProfileExtensionRegistry) -> TabGroupsContext?) {
        self.contextProvider = contextProvider
    }

    func handle(_ call: GapCall) async -> Any? {
        switch call.action {
        case "tabs.getZoomSettings", "tabs.setZoomSettings":
            let position = call.payload["tab"] as? [String: Any] ?? [:]
            guard let adapter = call.registry.tabAdapters(atPositions: [position], extensionId: call.extensionId).first ?? nil else {
                return BridgeError("Cannot get zoom or zoom settings on this tab.")
            }
            // A discarded tab loads its page again with Chrome's defaults.
            let engine = adapter.engineTab
            let defaultZoom = call.registry.settingsStore?.defaultZoom ?? 1
            guard call.action == "tabs.setZoomSettings" else {
                let settings = engine?.zoomSettings ?? WKWebViewTab.ZoomSettings()
                return ["mode": settings.mode, "scope": settings.scope, "defaultZoomFactor": defaultZoom]
            }
            guard let engine else { return nil }
            let mode = call.string("mode") ?? "automatic"
            // Only automatic mode keeps zoom per origin.
            engine.zoomSettings = WKWebViewTab.ZoomSettings(mode: mode, scope: mode == "automatic" ? call.string("scope") ?? "per-origin" : "per-tab")
            if mode == "disabled" { engine.setPageZoom(defaultZoom) }
            return nil

        case "tabs.createSplit":
            guard let context = contextProvider(call.registry) else { return BridgeError("Failed to create split view.") }
            return createSplit(call, context: context)

        case "tabs.unsplit":
            let splitViewId = call.int("splitViewId") ?? Self.splitViewIdNone
            guard splitViewId != Self.splitViewIdNone else { return BridgeError("Invalid split view id: \(splitViewId).") }
            guard let context = contextProvider(call.registry),
                  let folderId = folderIdBySplitId[splitViewId],
                  let folder = context.tabManager.folder(id: folderId), folder.isSplit,
                  (try? context.applyCommand(.deleteFolder(spaceId: folder.spaceId, folderId: folderId))) != nil else {
                return BridgeError("No split view with id: \(splitViewId).")
            }
            return nil

        default:
            return nil
        }
    }

    /// Chrome's checks, in its order, then the two tabs become a split folder, the first one left.
    private func createSplit(_ call: GapCall, context: TabGroupsContext) -> Any? {
        let positions = call.payload["tabs"] as? [[String: Any]] ?? []
        let chromeIds = call.payload["tabIds"] as? [Int] ?? []
        let ids = call.registry.tabIds(atPositions: positions, extensionId: call.extensionId)
        let tabManager = context.tabManager
        let tabs = ids.compactMap { $0.flatMap(tabManager.tab(for:)) }
        guard tabs.count == 2, positions.count == 2, chromeIds.count == 2, let spaceId = tabs[0].spaceId else {
            return BridgeError("Failed to create split view.")
        }
        for (tab, chromeId) in zip(tabs, chromeIds) where tab.groupId.flatMap(tabManager.folder(id:))?.isSplit == true {
            return BridgeError("Tab ID \(chromeId) is already in a split view.")
        }
        let windows = positions.map { ($0["windowPosition"] as? NSNumber)?.intValue }
        let indices = positions.map { ($0["index"] as? NSNumber)?.intValue ?? 0 }
        for (key, matches) in [("windowId", windows[0] == windows[1]), ("pinned", tabs[0].isPinned == tabs[1].isPinned), ("groupId", tabs[0].groupId == tabs[1].groupId)]
            where !matches {
            return BridgeError("Cannot create split view with tabs of mismatching '\(key)' states.")
        }
        guard abs(indices[0] - indices[1]) == 1 else { return BridgeError("Cannot create split view with non-adjacent tabs.") }
        let command = BrowserCommand.splitTabs(spaceId: spaceId, tabId: tabs[1].id, targetTabId: tabs[0].id, vertical: false, before: indices[1] < indices[0])
        guard (try? context.applyCommand(command)) != nil,
              let folderId = tabManager.tab(for: tabs[0].id)?.groupId,
              tabManager.folder(id: folderId)?.isSplit == true else {
            return BridgeError("Failed to create split view.")
        }
        return splitId(for: folderId)
    }

    private func splitId(for folderId: UUID) -> Int {
        if let id = splitIdByFolderId[folderId] { return id }
        let id = nextSplitId
        nextSplitId += 1
        splitIdByFolderId[folderId] = id
        folderIdBySplitId[id] = folderId
        return id
    }
}
