import XCTest
@testable import Lilo

final class SidebarNodeIndexTests: XCTestCase {
    func testTabInsideFolderResolvesParent() {
        let folderId = UUID()
        let tabId = UUID()
        let index = SidebarNodeIndex(tree: StoredSidebarTree(
            pinned: [],
            unpinned: [
                .folder(StoredFolder(id: folderId, name: "Folder", color: "#123456", isCollapsed: false, children: [
                    .tab(Self.tab(id: tabId))
                ]))
            ],
            bookmarked: []
        ))

        XCTAssertEqual(index.parentFolderId(for: tabId), folderId)
        XCTAssertEqual(index.parentFolderId(for: folderId), nil)
        XCTAssertEqual(index.tabIds, [tabId])
    }

    func testBookmarkedRootGetsBookmarkedSection() {
        let tabId = UUID()
        let index = SidebarNodeIndex(tree: StoredSidebarTree(
            pinned: [],
            unpinned: [],
            bookmarked: [.tab(Self.tab(id: tabId, isBookmarked: true))]
        ))

        XCTAssertEqual(index.nodePathById[tabId]?.head, .bookmarked)
    }

    private static func tab(id: UUID, isBookmarked: Bool = false) -> StoredTab {
        StoredTab(
            id: id,
            url: nil,
            title: "Tab",
            faviconDataURL: nil,
            faviconDominantColor: nil,
            isPinned: false,
            isBookmarked: isBookmarked,
            isClosed: false,
            homeURL: nil,
            homeTitle: nil,
            homeFaviconDataURL: nil,
            homeFaviconDominantColor: nil
        )
    }
}
