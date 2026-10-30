import XCTest
@testable import Lilo

/// A tab a page opens from a link sits right after that page, in its folder, consecutive ones in the order they opened.
@MainActor
final class LinkTabPlacementTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
    }

    override func tearDown() {
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    func testLinksOpenInOrderAfterTheirPageInItsFolder() throws {
        let context = browserContext.context
        let space = try context.spaceManager.createSpace(name: "S", profileId: try context.profileManager.createProfile(name: "P").id)
        let window = makeTestWindow(context, showing: space.id)
        let folder = TabFolder(spaceId: space.id, name: "Work")
        try window.applyBrowserCommand(.createFolder(spaceId: space.id, folder: folder, section: .unpinned))
        let pages = try ["data:text/html,opener", "data:text/html,neighbour"].map { try XCTUnwrap(window.createTabStateFirst(url: URL(string: $0))) }
        for (index, page) in pages.enumerated() {
            try window.applyBrowserCommand(.moveSidebarItem(
                spaceId: space.id, kind: .tab, itemId: page.id, parentFolderId: folder.id, section: .unpinned, insert: .index(index)
            ))
        }
        window.activateTabStateFirst(id: pages[0].id)
        let opener = try XCTUnwrap(window.tabManager.engineTab(for: pages[0].id))

        window.tab(opener, didCreateNewTab: URL(string: "data:text/html,one"), inBackground: true)
        window.tab(opener, didCreateNewTab: URL(string: "data:text/html,two"), inBackground: true)

        let folderURLs = window.tabManager.sidebarTreeItems(forSpace: space.id)
            .filter { $0.kind == .tab && $0.parentFolderId == folder.id }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { window.tabManager.tab(for: $0.itemId)?.url?.absoluteString }
        XCTAssertEqual(folderURLs, ["data:text/html,opener", "data:text/html,one", "data:text/html,two", "data:text/html,neighbour"])
    }
}
