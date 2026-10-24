import Foundation
@testable import Lilo

struct BrowserStateFixture: Sendable {
    enum ValidationError: Error, Equatable {
        case invalidActiveTab(UUID)
        case tabIsPinnedAndBookmarked(UUID)
    }

    var spaceId: UUID
    var activeTabId: UUID?
    var tabsById: [UUID: Tab]
    var foldersById: [UUID: TabFolder]
    var sidebar: SidebarState
    var activationHistory: [UUID]

    init(
        spaceId: UUID,
        activeTabId: UUID?,
        tabs: [Tab],
        folders: [TabFolder],
        treeItems: [TabTreeItem],
        activationHistory: [UUID] = []
    ) throws {
        let stateTabs = try Self.stateTabs(spaceId: spaceId, tabs: tabs)
        if let activeTabId,
           stateTabs[activeTabId]?.isClosed != false {
            throw ValidationError.invalidActiveTab(activeTabId)
        }

        self.spaceId = spaceId
        self.activeTabId = activeTabId
        self.tabsById = stateTabs
        self.foldersById = Dictionary(uniqueKeysWithValues: folders.filter { $0.spaceId == spaceId }.map { ($0.id, $0) })
        self.activationHistory = Self.normalizedActivationHistory(
            activationHistory,
            activeTabId: activeTabId,
            tabsById: stateTabs
        )
        self.sidebar = SidebarState(
            spaceId: spaceId,
            tabsById: stateTabs,
            folders: folders,
            treeItems: treeItems
        )
    }

    func invariantsHold() -> Bool {
        if let activeTabId, tabsById[activeTabId]?.isClosed != false {
            return false
        }

        if tabsById.values.contains(where: { $0.isPinned && $0.isBookmarked }) {
            return false
        }

        return sidebar.invariantsHold(tabsById: tabsById)
    }

    func sidebarOrderedTabs() -> [Tab] {
        let orderedIds = sidebar.treeItems(spaceId: spaceId)
            .filter { $0.kind == .tab }
            .map(\.itemId)
        var seenIds = Set<UUID>()
        var orderedTabs: [Tab] = []
        for tabId in orderedIds where !seenIds.contains(tabId) {
            guard let tab = tabsById[tabId] else { continue }
            orderedTabs.append(tab)
            seenIds.insert(tabId)
        }
        orderedTabs.append(contentsOf: tabsById.values
            .filter { !seenIds.contains($0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString })
        return orderedTabs
    }

    func sidebarOrderedFolders() -> [TabFolder] {
        let orderedIds = sidebar.treeItems(spaceId: spaceId)
            .filter { $0.kind == .folder && $0.parentFolderId == nil }
            .map(\.itemId)
        var seenIds = Set<UUID>()
        var orderedFolders: [TabFolder] = []
        for folderId in orderedIds where !seenIds.contains(folderId) {
            guard let folder = foldersById[folderId] else { continue }
            orderedFolders.append(folder)
            seenIds.insert(folderId)
        }
        orderedFolders.append(contentsOf: foldersById.values
            .filter { !seenIds.contains($0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString })
        return orderedFolders
    }

    private static func stateTabs(spaceId: UUID, tabs: [Tab]) throws -> [UUID: Tab] {
        var result: [UUID: Tab] = [:]
        for tab in tabs where tab.spaceId == spaceId {
            if tab.isPinned && tab.isBookmarked {
                throw ValidationError.tabIsPinnedAndBookmarked(tab.id)
            }
            if tab.isClosed && !tab.isPinned && !tab.isBookmarked {
                continue
            }
            result[tab.id] = tab
        }
        return result
    }

    private static func normalizedActivationHistory(
        _ activationHistory: [UUID],
        activeTabId: UUID?,
        tabsById: [UUID: Tab]
    ) -> [UUID] {
        var seenIds = Set<UUID>()
        var result: [UUID] = []
        for tabId in activationHistory {
            guard tabId != activeTabId,
                  seenIds.insert(tabId).inserted,
                  tabsById[tabId]?.isClosed == false else {
                continue
            }
            result.append(tabId)
        }
        return result
    }
}

@MainActor
func makeBrowserStateStore(
    spaceId: UUID,
    tabs: [Tab],
    folders: [TabFolder] = [],
    treeItems: [TabTreeItem],
    activeTabId: UUID?
) -> BrowserStateStore {
    let store = BrowserStateStore()
    let state = SpaceTabStateImporter.importState(
        activeTabId: activeTabId,
        activationHistory: [],
        tabs: tabs,
        folders: folders,
        treeItems: treeItems,
        spaceId: spaceId
    )
    store.storeSpace(
        id: spaceId,
        snapshot: BrowserStateStore.SpaceSnapshot(spaceTab: SpaceTab(spaceId: spaceId, state: state), engines: [:])
    )
    return store
}

func unpinnedTabItem(_ tabId: UUID, spaceId: UUID, sortOrder: Int) -> TabTreeItem {
    TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .unpinned, sortOrder: sortOrder)
}

@MainActor
extension TabManager {
    func installSpaceTabStateForTests(_ state: SpaceTabState, spaceId: UUID) {
        let store: BrowserStateStore
        if let existing = browserStateStore {
            store = existing
        } else {
            store = BrowserStateStore()
            browserStateStore = store
        }
        store.storeSpace(
            id: spaceId,
            snapshot: BrowserStateStore.SpaceSnapshot(
                spaceTab: SpaceTab(spaceId: spaceId, state: SpaceTabStateRepair.repaired(state)),
                engines: [:]
            )
        )
        applyDurableProjectionToRuntime(state, spaceId: spaceId)
    }

    @discardableResult
    func installFolderForTests(
        spaceId: UUID,
        name: String = "Work",
        color: String = "#ff0000",
        section: TabTreeItem.Section = .unpinned
    ) throws -> TabFolder {
        let folder = TabFolder(spaceId: spaceId, name: name, color: color)
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: activeOpenTabId,
            tabs: tabs(forSpace: spaceId),
            folders: folders(forSpace: spaceId) + [folder],
            treeItems: sidebarTreeItems(forSpace: spaceId) + [
                TabTreeItem(
                    spaceId: spaceId,
                    kind: .folder,
                    itemId: folder.id,
                    parentFolderId: nil,
                    section: section,
                    sortOrder: 0
                )
            ]
        )
        installSpaceTabStateForTests(SpaceTabState(state), spaceId: state.spaceId)
        return folder
    }
}

extension SpaceTabState {
    init(_ state: BrowserStateFixture) {
        self = SpaceTabStateImporter.importState(
            activeTabId: state.activeTabId,
            activationHistory: state.activationHistory,
            tabs: state.sidebarOrderedTabs(),
            folders: state.sidebarOrderedFolders(),
            treeItems: state.sidebar.treeItems(spaceId: state.spaceId),
            spaceId: state.spaceId
        )
    }

    func browserStateFixture(spaceId: UUID, preferredActiveTabId: UUID?) throws -> BrowserStateFixture {
        let projection = projectedSidebar(spaceId: spaceId)

        do {
            return try BrowserStateFixture(
                spaceId: spaceId,
                activeTabId: preferredActiveTabId ?? activeTabId,
                tabs: projection.tabs,
                folders: projection.folders,
                treeItems: projection.treeItems,
                activationHistory: activationHistory
            )
        } catch BrowserStateFixture.ValidationError.invalidActiveTab {
            return try BrowserStateFixture(
                spaceId: spaceId,
                activeTabId: nil,
                tabs: projection.tabs,
                folders: projection.folders,
                treeItems: projection.treeItems,
                activationHistory: activationHistory
            )
        }
    }
}

extension BrowserSpaceChange {
    var sidebar: SidebarState {
        SidebarState(
            spaceId: spaceId,
            tabsById: tabsById,
            folders: projection.folders,
            treeItems: projection.treeItems
        )
    }

    func invariantsHold() -> Bool {
        if let activeTabId = state.activeTabId, tabsById[activeTabId]?.isClosed != false {
            return false
        }

        if tabsById.values.contains(where: { $0.isPinned && $0.isBookmarked }) {
            return false
        }

        return sidebar.invariantsHold(tabsById: tabsById)
    }

    func browserStateFixture() -> BrowserStateFixture {
        do {
            return try BrowserStateFixture(
                spaceId: spaceId,
                activeTabId: state.activeTabId,
                tabs: projection.tabs,
                folders: projection.folders,
                treeItems: projection.treeItems,
                activationHistory: state.activationHistory
            )
        } catch {
            preconditionFailure("BrowserSpaceChange should always contain a valid repaired SpaceTabState")
        }
    }
}
