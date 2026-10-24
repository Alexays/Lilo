import XCTest
@testable import Lilo

@MainActor
final class TabContextMenuActionsTests: XCTestCase {
    func testCreateFolderActionAppearsForNormalTab() {
        let tab = Tab(url: URL(string: "https://example.com")!, title: "Example")

        let actions = TabContextMenuActions.forTab(tab)

        XCTAssertTrue(actions.contains(.createFolderFromTab))
    }

    func testCreateFolderActionIsHiddenForBookmarkedTab() {
        let tab = Tab(
            url: URL(string: "https://example.com")!,
            title: "Example",
            isBookmarked: true
        )

        let actions = TabContextMenuActions.forTab(tab)

        XCTAssertFalse(actions.contains(.createFolderFromTab))
    }

    func testClosedBookmarkContextMenuRemovesBookmarkInsteadOfClosingTab() {
        let tab = Tab(
            url: URL(string: "https://example.com")!,
            title: "Example",
            isBookmarked: true,
            isClosed: true
        )

        let actions = TabContextMenuActions.forTab(tab)

        XCTAssertEqual(actions, [.removeBookmark])
    }

    func testClosedPinnedContextMenuRemovesPinnedTabInsteadOfClosingTab() {
        let tab = Tab(
            url: URL(string: "https://example.com")!,
            title: "Example",
            isPinned: true,
            isClosed: true
        )

        let actions = TabContextMenuActions.forTab(tab)

        XCTAssertEqual(actions, [.createFolderFromTab, .removePinned])
    }

    func testFolderTargetsListPinnedThenUnpinnedFoldersInSidebarOrderWithDepth() {
        let spaceId = UUID()
        let work = TabFolder(spaceId: spaceId, name: "Work")
        let docs = TabFolder(spaceId: spaceId, name: "Docs")
        let pinned = TabFolder(spaceId: spaceId, name: "Pinned")
        let later = TabFolder(spaceId: spaceId, name: "Later")
        let treeItems = [
            folderItem(later, spaceId: spaceId, section: .unpinned, sortOrder: 1),
            folderItem(work, spaceId: spaceId, section: .unpinned, sortOrder: 0),
            folderItem(docs, spaceId: spaceId, parent: work.id, section: .unpinned, sortOrder: 0),
            folderItem(pinned, spaceId: spaceId, section: .pinned, sortOrder: 5)
        ]

        let targets = TabContextMenuActions.folderTargets(treeItems: treeItems, folders: [work, docs, pinned, later])

        XCTAssertEqual(targets.map(\.folder.name), ["Pinned", "Work", "Docs", "Later"])
        XCTAssertEqual(targets.map(\.depth), [0, 0, 1, 0])
    }

    func testFolderTargetsSkipLockedSubtreesAndSplits() {
        let spaceId = UUID()
        let locked = TabFolder(spaceId: spaceId, name: "Locked", lock: FolderLock(allowsBiometrics: false))
        let inner = TabFolder(spaceId: spaceId, name: "Inner")
        let split = TabFolder(spaceId: spaceId, name: "Split", splitLayout: .pane(tabId: UUID()))
        let open = TabFolder(spaceId: spaceId, name: "Open")
        let treeItems = [
            folderItem(locked, spaceId: spaceId, section: .unpinned, sortOrder: 0),
            folderItem(inner, spaceId: spaceId, parent: locked.id, section: .unpinned, sortOrder: 0),
            folderItem(split, spaceId: spaceId, section: .unpinned, sortOrder: 1),
            folderItem(open, spaceId: spaceId, section: .unpinned, sortOrder: 2)
        ]

        let targets = TabContextMenuActions.folderTargets(treeItems: treeItems, folders: [locked, inner, split, open])

        XCTAssertEqual(targets.map(\.folder.name), ["Open"])
    }

    private func folderItem(
        _ folder: TabFolder, spaceId: UUID, parent: UUID? = nil, section: TabTreeItem.Section, sortOrder: Int
    ) -> TabTreeItem {
        TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folder.id, parentFolderId: parent, section: section, sortOrder: sortOrder)
    }
}
