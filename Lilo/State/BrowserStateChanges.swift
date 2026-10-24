import Foundation

struct BrowserSpaceChange: Sendable {
    let spaceId: UUID
    let state: SpaceTabState
    let projection: SpaceTabProjection

    /// Pre-mutation projection (overlay-applied), captured by `mutateSpaceTab` in the same
    /// synchronous mutation. Present, the presenter can ship a mechanical diff patch; absent (space switch,
    /// session restore, cross-space move), it ships the full state.
    let previousProjection: SpaceTabProjection?
    let previousActiveTabId: UUID?

    init(
        spaceId: UUID,
        state: SpaceTabState,
        projection: SpaceTabProjection,
        previousProjection: SpaceTabProjection? = nil,
        previousActiveTabId: UUID? = nil
    ) {
        self.spaceId = spaceId
        self.state = state
        self.projection = projection
        self.previousProjection = previousProjection
        self.previousActiveTabId = previousActiveTabId
    }

    /// This change as a window whose selection in the space is `activeTabId` sees it.
    func selecting(_ activeTabId: UUID?) -> BrowserSpaceChange {
        var state = state
        state.activeTabId = activeTabId
        return BrowserSpaceChange(
            spaceId: spaceId,
            state: state,
            projection: projection,
            previousProjection: previousProjection,
            previousActiveTabId: activeTabId
        )
    }

    var tabsById: [UUID: Tab] {
        Dictionary(uniqueKeysWithValues: projection.tabs.map { ($0.id, $0) })
    }

    var foldersById: [UUID: TabFolder] {
        Dictionary(uniqueKeysWithValues: projection.folders.map { ($0.id, $0) })
    }
}

struct BrowserChangeSet: Sendable {
    let spaceId: UUID
    let states: [BrowserSpaceChange]
    let transitionId: String?
    let profileId: UUID?

    var changedState: BrowserSpaceChange? {
        states.first { $0.spaceId == spaceId }
    }

    init(
        spaceId: UUID,
        stateChanges: [BrowserSpaceChange],
        transitionId: String? = nil,
        profileId: UUID? = nil
    ) {
        self.spaceId = spaceId
        self.states = stateChanges
        self.transitionId = transitionId
        self.profileId = profileId
    }
}

enum BrowserChangePresenter {
    struct Event {
        let name: String
        let data: [String: Any]
    }

    /// Delegate-side activation (no mutation ran, so no diff to compute): activeTabId plus the
    /// active tab's snapshot so a tab the UI hasn't seen yet renders complete.
    static func activationSidebarEvent(tab: Tab, spaceId: UUID) -> Event {
        patchEvent(
            spaceId: spaceId,
            operation: [
                "kind": "sidebarChanged",
                "spaceId": spaceId.uuidString,
                "activeTabId": tab.id.uuidString,
                "upsertTabs": [tab.snapshotData()]
            ]
        )
    }

    /// The tab payload is built once and shared by every window; only the selection differs.
    static func tabUpdatedEvent(tabPayload: [String: Any], spaceId: UUID, activeTabId: UUID?) -> Event {
        patchEvent(
            spaceId: spaceId,
            operation: [
                "kind": "tabUpdated",
                "spaceId": spaceId.uuidString,
                "activeTabId": activeTabId?.uuidString ?? "",
                "tab": tabPayload
            ]
        )
    }

    /// A mutation that captured its pre-projection ships the diff (nil when nothing observable changed); resync paths ship the full state.
    /// `omitFaviconsForSpaces`: spaces whose favicons the chrome already holds, so their snapshots drop the heavy base64 favicons.
    static func event(for changes: BrowserChangeSet, omitFaviconsForSpaces: Set<UUID> = []) -> Event? {
        if changes.states.count == 1,
           let changedState = changes.changedState,
           let previous = changedState.previousProjection {
            return sidebarChangedEvent(for: changedState, previous: previous)
        }

        return fullStateEvent(for: changes, omitFaviconsForSpaces: omitFaviconsForSpaces)
    }

    private static func sidebarChangedEvent(for change: BrowserSpaceChange, previous: SpaceTabProjection) -> Event? {
        let delta = SidebarDiff.delta(from: previous, to: change.projection)
        let activeTabId = change.state.activeTabId
        if delta.isEmpty && change.previousActiveTabId == activeTabId {
            return nil
        }

        var operation: [String: Any] = [
            "kind": "sidebarChanged",
            "spaceId": change.spaceId.uuidString,
            "activeTabId": activeTabId?.uuidString ?? ""
        ]
        if let treeItems = delta.treeItems {
            operation["treeItems"] = treeItems.map(\.bridgeData)
        }
        if !delta.upsertTreeItems.isEmpty {
            operation["upsertTreeItems"] = delta.upsertTreeItems.map(\.bridgeData)
        }
        if !delta.removedTreeItemIds.isEmpty {
            operation["removedTreeItemIds"] = delta.removedTreeItemIds.map(\.uuidString)
        }
        if !delta.upsertTabs.isEmpty {
            operation["upsertTabs"] = delta.upsertTabs.map { tab in
                delta.unchangedFaviconTabIds.contains(tab.id) ? tab.snapshotData(excluding: [.faviconDataURL]) : tab.snapshotData()
            }
        }
        if !delta.removedTabIds.isEmpty {
            operation["removedTabIds"] = delta.removedTabIds.map(\.uuidString)
        }
        if !delta.upsertFolders.isEmpty {
            operation["upsertFolders"] = delta.upsertFolders.map(\.bridgeData)
        }
        if !delta.removedFolderIds.isEmpty {
            operation["removedFolderIds"] = delta.removedFolderIds.map(\.uuidString)
        }
        return patchEvent(spaceId: change.spaceId, operation: operation)
    }

    /// `changedSpaceId` lets the router merge the buffered patches of one space.
    private static func patchEvent(spaceId: UUID, operation: [String: Any]) -> Event {
        Event(name: "browserStatePatch", data: ["changedSpaceId": spaceId.uuidString, "operations": [operation]])
    }

    private static func fullStateEvent(for changes: BrowserChangeSet, omitFaviconsForSpaces: Set<UUID>) -> Event {
        var data: [String: Any] = [
            "changedSpaceId": changes.spaceId.uuidString,
            "states": changes.states.map { statePayload($0, omitFavicons: omitFaviconsForSpaces.contains($0.spaceId)) }
        ]
        if let transitionId = changes.transitionId {
            data["transitionId"] = transitionId
        }
        if let profileId = changes.profileId {
            data["profileId"] = profileId.uuidString
        }

        return Event(name: "browserStateChanged", data: data)
    }

    private static func statePayload(_ change: BrowserSpaceChange, omitFavicons: Bool) -> [String: Any] {
        return [
            "spaceId": change.spaceId.uuidString,
            "activeTabId": change.state.activeTabId?.uuidString ?? "",
            // Omitting faviconDataURL keeps the base64 payload out of full-state sends for spaces
            // whose favicons the chrome already holds; the UI keeps its existing favicon when the
            // field is absent (see the sidebar store's full-state merge).
            "tabs": change.projection.tabs.map { omitFavicons ? $0.snapshotData(excluding: [.faviconDataURL]) : $0.snapshotData() },
            "folders": change.projection.folders.map(\.bridgeData),
            "treeItems": change.projection.treeItems.map(\.bridgeData)
        ]
    }
}

enum SidebarInsertPosition: Sendable, Equatable {
    case index(Int)
    case anchored(fallbackIndex: Int, insertBeforeId: UUID?, insertAfterId: UUID?)
}

enum BrowserCommand: Sendable {
    case createTab(spaceId: UUID, tab: Tab, activate: Bool)
    case activateTab(spaceId: UUID, tabId: UUID)
    case closeTab(spaceId: UUID, tabId: UUID)
    case setPinned(spaceId: UUID, tabId: UUID, isPinned: Bool)
    case setBookmarked(spaceId: UUID, tabId: UUID, isBookmarked: Bool)
    case setTabHomeURL(spaceId: UUID, tabId: UUID, url: URL?)
    /// With a parent, the folder lands first in it, in the parent's section.
    case createFolder(spaceId: UUID, folder: TabFolder, section: TabTreeItem.Section, parentFolderId: UUID? = nil)
    case updateFolder(spaceId: UUID, folderId: UUID, name: String, color: String, isCollapsed: Bool)
    case setFolderCollapsed(spaceId: UUID, folderId: UUID, isCollapsed: Bool)
    case setFolderLock(spaceId: UUID, folderId: UUID, lock: FolderLock?)
    /// Changes only the Touch ID setting: an unlocked folder stays unlocked.
    case setFolderAllowsBiometrics(spaceId: UUID, folderId: UUID, allowsBiometrics: Bool)
    case setFolderUnlocked(spaceId: UUID, folderId: UUID, isUnlocked: Bool)
    case deleteFolder(spaceId: UUID, folderId: UUID)
    /// Removes the folder with everything inside it, where `deleteFolder` keeps its tabs.
    case deleteFolderWithTabs(spaceId: UUID, folderId: UUID)
    case moveTabToSpace(tabId: UUID, sourceSpaceId: UUID, targetSpaceId: UUID, allowsPinnedTabs: Bool)
    case moveFolderToSpace(folderId: UUID, sourceSpaceId: UUID, targetSpaceId: UUID, allowsPinnedTabs: Bool)
    case moveTabToBookmarked(spaceId: UUID, tabId: UUID, insert: SidebarInsertPosition)
    case groupTabs(spaceId: UUID, sourceTabId: UUID, targetTabId: UUID)
    /// Cuts `targetTabId`'s pane in two, `tabId` on the left or top half when `before`.
    case splitTabs(spaceId: UUID, tabId: UUID, targetTabId: UUID, vertical: Bool, before: Bool)
    case replaceSplitPane(spaceId: UUID, targetTabId: UUID, tabId: UUID)
    case setSplitLayout(spaceId: UUID, folderId: UUID, layout: SplitLayout)
    /// Appends whole imported subtrees (tabs and folders) to a section in one mutation.
    case importSidebarNodes(spaceId: UUID, nodes: [StoredSidebarNode], section: TabTreeItem.Section)
    case moveSidebarItem(
        spaceId: UUID,
        kind: TabTreeItem.Kind,
        itemId: UUID,
        parentFolderId: UUID?,
        section: TabTreeItem.Section,
        insert: SidebarInsertPosition
    )
}
