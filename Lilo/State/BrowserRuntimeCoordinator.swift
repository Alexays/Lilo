import Foundation

/// The command, mutate, project, emit, save pipeline: applies a `BrowserCommand` to `BrowserStateStore`, projects it onto `TabManager`,
/// emits it to the UI and schedules a session save.
@MainActor
final class BrowserRuntimeCoordinator {
    private let tabManager: TabManager
    private let browserStateStore: BrowserStateStore
    private let syncActiveBrowserState: () -> Void
    private let emitBrowserChange: (BrowserChangeSet) -> Void
    private let scheduleSave: () -> Void

    init(
        tabManager: TabManager,
        browserStateStore: BrowserStateStore,
        syncActiveBrowserState: @escaping () -> Void,
        emitBrowserChange: @escaping (BrowserChangeSet) -> Void,
        scheduleSave: @escaping () -> Void
    ) {
        self.tabManager = tabManager
        self.browserStateStore = browserStateStore
        self.syncActiveBrowserState = syncActiveBrowserState
        self.emitBrowserChange = emitBrowserChange
        self.scheduleSave = scheduleSave
    }

    @discardableResult
    func apply(_ command: BrowserCommand) throws -> BrowserChangeSet {
        if shouldSyncActiveBrowserState(before: command) {
            syncActiveBrowserState()
        }
        let changes = try browserStateStore.mutate(command)
        applyRuntimeProjection(from: changes, emitsTabMoves: canReorderTabs(command))
        // The window that activates a tab selects it; any other command leaves its selection alone.
        switch command {
        case let .activateTab(spaceId, tabId) where tabManager.currentSpaceId == spaceId:
            tabManager.activeTabId = tabId
        case let .createTab(spaceId, tab, true) where tabManager.currentSpaceId == spaceId:
            tabManager.activeTabId = tab.id
        default:
            break
        }
        emitBrowserChange(changes)
        scheduleSave()
        return changes
    }

    /// Whether the command can change the current space's tab set or order, which is what
    /// `tabs.onMoved` detection keys off.
    private func canReorderTabs(_ command: BrowserCommand) -> Bool {
        switch command {
        case .activateTab,
             .setTabHomeURL,
             .renameTab,
             .createFolder,
             .updateFolder,
             .setFolderCollapsed,
             .setFolderLock,
             .setFolderAllowsBiometrics,
             .setFolderUnlocked,
             .setSplitLayout:
            return false
        case .createTab,
             .closeTab,
             .setPinned,
             .setBookmarked,
             .deleteFolder,
             .deleteFolderWithTabs,
             .moveTabToSpace,
             .moveFolderToSpace,
             .moveTabToBookmarked,
             .groupTabs,
             .splitTabs,
             .replaceSplitPane,
             .importSidebarNodes,
             .moveSidebarItem:
            return true
        }
    }

    private func shouldSyncActiveBrowserState(before command: BrowserCommand) -> Bool {
        switch command {
        case .activateTab,
             .renameTab,
             .updateFolder,
             .setFolderCollapsed,
             .setFolderLock,
             .setFolderAllowsBiometrics,
             .setFolderUnlocked,
             .setSplitLayout:
            return false
        case .createTab,
             .closeTab,
             .setPinned,
             .setBookmarked,
             .setTabHomeURL,
             .createFolder,
             .deleteFolder,
             .deleteFolderWithTabs,
             .moveTabToSpace,
             .moveFolderToSpace,
             .moveTabToBookmarked,
             .groupTabs,
             .splitTabs,
             .replaceSplitPane,
             .importSidebarNodes,
             .moveSidebarItem:
            return true
        }
    }

    func applyRuntimeProjection(from changes: BrowserChangeSet, currentSpaceOnly: Bool = false, emitsTabMoves: Bool = true) {
        for state in changes.states {
            if currentSpaceOnly, state.spaceId != tabManager.currentSpaceId { continue }
            // Command paths can't orphan an overlay entry (close/discard drops it at the source), so the
            // O(all-tabs) global prune is skipped.
            tabManager.applyDurableProjectionToRuntime(
                state.state,
                spaceId: state.spaceId,
                prunesStaleOverlay: false,
                repairsState: false,
                emitsTabMoves: emitsTabMoves
            )
        }
    }
}
