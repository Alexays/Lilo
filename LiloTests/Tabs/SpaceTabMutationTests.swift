import XCTest
@testable import Lilo

@MainActor
final class SpaceTabMutationTests: XCTestCase {
    func testActivateUpdatesActiveTabAndMRU() {
        let firstId = UUID()
        let secondId = UUID()
        var session = SpaceTab(spaceId: UUID(), state: SpaceTabState(
            activeTabId: firstId,
            activationHistory: [],
            tree: StoredSidebarTree(
                pinned: [],
                unpinned: [.tab(Self.tab(id: firstId)), .tab(Self.tab(id: secondId))],
                bookmarked: []
            )
        ))

        session.activateTab(secondId)

        XCTAssertEqual(session.state.activeTabId, secondId)
        XCTAssertEqual(session.state.activationHistory, [firstId])
    }

    func testActivatingOpenTabPreservesStructureToken() {
        let firstId = UUID()
        let secondId = UUID()
        var session = SpaceTab(spaceId: UUID(), state: SpaceTabState(
            activeTabId: firstId,
            activationHistory: [],
            tree: StoredSidebarTree(
                pinned: [],
                unpinned: [.tab(Self.tab(id: firstId)), .tab(Self.tab(id: secondId))],
                bookmarked: []
            )
        ))

        let tokenBefore = session.structureToken
        // Activating an already-open tab changes only activeTabId/activationHistory: the rendered
        // row set is identical, so the structure token (memo-cache key) must survive untouched.
        session.activateTab(secondId)

        XCTAssertEqual(session.structureToken, tokenBefore, "Activating an open tab must not re-roll the structure token")
        XCTAssertEqual(session.state.activeTabId, secondId)
    }

    func testActivatingClosedPinnedTabRollsStructureToken() {
        let openId = UUID()
        let closedPinnedId = UUID()
        var session = SpaceTab(spaceId: UUID(), state: SpaceTabState(
            activeTabId: openId,
            activationHistory: [],
            tree: StoredSidebarTree(
                pinned: [.tab(Self.tab(id: closedPinnedId, isPinned: true, isClosed: true))],
                unpinned: [.tab(Self.tab(id: openId))],
                bookmarked: []
            )
        ))

        let tokenBefore = session.structureToken
        // Reopening a closed pinned tab flips isClosed and adds a rendered row: a structural change.
        session.activateTab(closedPinnedId)

        XCTAssertNotEqual(session.structureToken, tokenBefore, "Reopening a closed pinned tab must roll the structure token")
        XCTAssertEqual(session.state.activeTabId, closedPinnedId)
        guard case let .tab(reopened)? = session.state.tree.pinned.first else {
            return XCTFail("Expected reopened pinned tab")
        }
        XCTAssertFalse(reopened.isClosed, "Activated pinned tab must be reopened")
    }

    func testCreatingForegroundTabRecordsPreviousTabForMRU() {
        let spaceId = UUID()
        let firstId = UUID()
        let secondId = UUID()
        let newId = UUID()
        var session = SpaceTab(spaceId: spaceId, state: SpaceTabState(
            activeTabId: secondId,
            activationHistory: [firstId],
            tree: StoredSidebarTree(
                pinned: [],
                unpinned: [.tab(Self.tab(id: firstId)), .tab(Self.tab(id: secondId))],
                bookmarked: []
            )
        ))

        // Opening a link in a foreground tab must push the tab we came from onto the MRU stack...
        session.createTab(Tab(id: newId, title: "New", spaceId: spaceId), activate: true)
        XCTAssertEqual(session.state.activeTabId, newId)
        XCTAssertEqual(session.state.activationHistory, [secondId, firstId])

        // ...so closing it returns to that tab, not the left-most fallback.
        session.closeTab(newId)
        XCTAssertEqual(session.state.activeTabId, secondId)
    }

    func testMoveChildIntoFolderChangesTreeShape() {
        let tabId = UUID()
        let folderId = UUID()
        var session = SpaceTab(spaceId: UUID(), state: SpaceTabState(
            activeTabId: nil,
            activationHistory: [],
            tree: StoredSidebarTree(
                pinned: [],
                unpinned: [
                    .tab(Self.tab(id: tabId)),
                    .folder(StoredFolder(id: folderId, name: "Folder", color: "#123456", isCollapsed: false, children: []))
                ],
                bookmarked: []
            )
        ))

        session.moveNode(tabId, toFolder: folderId, section: .unpinned, index: 0)

        guard case let .folder(folder)? = session.state.tree.unpinned.first else {
            return XCTFail("Expected folder after repair")
        }
        XCTAssertEqual(folder.children.map(\.id), [tabId])
        XCTAssertEqual(session.index.parentFolderId(for: tabId), folderId)
    }

    func testMoveFolderIntoOwnDescendantIsIgnored() {
        let folderId = UUID()
        let childFolderId = UUID()
        let grandchildFolderId = UUID()
        let tabId = UUID()
        var session = SpaceTab(spaceId: UUID(), state: SpaceTabState(
            activeTabId: nil,
            activationHistory: [],
            tree: StoredSidebarTree(
                pinned: [],
                unpinned: [
                    .folder(StoredFolder(id: folderId, name: "Root", color: "#123456", isCollapsed: false, children: [
                        .folder(StoredFolder(id: childFolderId, name: "Child", color: "#654321", isCollapsed: false, children: [
                            .folder(StoredFolder(id: grandchildFolderId, name: "Grandchild", color: "#abcdef", isCollapsed: false, children: [
                                .tab(Self.tab(id: tabId))
                            ]))
                        ]))
                    ]))
                ],
                bookmarked: []
            )
        ))

        session.moveNode(childFolderId, toFolder: grandchildFolderId, section: .unpinned, index: 0)

        XCTAssertEqual(session.state.tree.unpinned.map(\.id), [folderId])
        XCTAssertEqual(session.index.parentFolderId(for: childFolderId), folderId)
        XCTAssertEqual(session.index.parentFolderId(for: grandchildFolderId), childFolderId)
        XCTAssertEqual(session.index.parentFolderId(for: tabId), grandchildFolderId)
    }

    func testCloseActiveChoosesMRUFallback() {
        let activeId = UUID()
        let fallbackId = UUID()
        var session = SpaceTab(spaceId: UUID(), state: SpaceTabState(
            activeTabId: activeId,
            activationHistory: [fallbackId],
            tree: StoredSidebarTree(
                pinned: [],
                unpinned: [.tab(Self.tab(id: activeId)), .tab(Self.tab(id: fallbackId))],
                bookmarked: []
            )
        ))

        session.closeTab(activeId)

        XCTAssertEqual(session.state.activeTabId, fallbackId)
        XCTAssertNil(session.index.nodePathById[activeId])
    }

    func testCloseLastChildPrunesEmptiedFolder() {
        let tabId = UUID()
        let folderId = UUID()
        let siblingId = UUID()
        var session = SpaceTab(spaceId: UUID(), state: SpaceTabState(
            activeTabId: tabId,
            activationHistory: [],
            tree: StoredSidebarTree(
                pinned: [],
                unpinned: [
                    .folder(StoredFolder(id: folderId, name: "Folder", color: "#123456", isCollapsed: false, children: [.tab(Self.tab(id: tabId))])),
                    .tab(Self.tab(id: siblingId))
                ],
                bookmarked: []
            )
        ))

        session.closeTab(tabId)

        XCTAssertNil(session.index.nodePathById[folderId], "Closing the last child removes the folder")
        XCTAssertEqual(session.state.tree.unpinned.map(\.id), [siblingId])
        XCTAssertEqual(session.state.activeTabId, siblingId)
    }

    func testDeletingAFolderLeavesItsChildrenInItsPlace() {
        let (a, b, c, d, e) = (UUID(), UUID(), UUID(), UUID(), UUID())
        let (outerId, innerId) = (UUID(), UUID())
        let inner = StoredFolder(id: innerId, name: "Inner", color: "#123456", isCollapsed: false, children: [.tab(Self.tab(id: c)), .tab(Self.tab(id: d))])
        var session = SpaceTab(spaceId: UUID(), state: SpaceTabState(
            activeTabId: a,
            activationHistory: [],
            tree: StoredSidebarTree(
                pinned: [],
                unpinned: [
                    .tab(Self.tab(id: a)),
                    .folder(StoredFolder(id: outerId, name: "Outer", color: "#123456", isCollapsed: false, children: [.tab(Self.tab(id: b)), .folder(inner)])),
                    .tab(Self.tab(id: e))
                ],
                bookmarked: []
            )
        ))

        session.deleteFolder(innerId)
        guard case let .folder(outer) = session.state.tree.unpinned[1] else { return XCTFail("the outer folder stays in place") }
        XCTAssertEqual(outer.children.map(\.id), [b, c, d], "a nested folder's children stay in its parent")

        session.deleteFolder(outerId)
        XCTAssertEqual(session.state.tree.unpinned.map(\.id), [a, b, c, d, e])
    }

    func testClosePinnedChildKeepsFolder() {
        let tabId = UUID()
        let folderId = UUID()
        var session = SpaceTab(spaceId: UUID(), state: SpaceTabState(
            activeTabId: tabId,
            activationHistory: [],
            tree: StoredSidebarTree(
                pinned: [
                    .folder(StoredFolder(id: folderId, name: "Folder", color: "#123456", isCollapsed: false, children: [.tab(Self.tab(id: tabId, isPinned: true))]))
                ],
                unpinned: [],
                bookmarked: []
            )
        ))

        session.closeTab(tabId)

        XCTAssertEqual(session.index.parentFolderId(for: tabId), folderId, "A closed pinned tab stays as a placeholder in its folder")
    }

    func testRenameFolderDoesNotTouchTabs() {
        let tabId = UUID()
        let folderId = UUID()
        var session = SpaceTab(spaceId: UUID(), state: SpaceTabState(
            activeTabId: nil,
            activationHistory: [],
            tree: StoredSidebarTree(
                pinned: [],
                unpinned: [
                    .folder(StoredFolder(id: folderId, name: "Old", color: "#123456", isCollapsed: false, children: [
                        .tab(Self.tab(id: tabId, title: "Tab"))
                    ]))
                ],
                bookmarked: []
            )
        ))

        session.updateFolder(folderId, name: "New", color: "#123456", isCollapsed: false)

        guard case let .folder(folder)? = session.state.tree.unpinned.first,
              case let .tab(tab)? = folder.children.first else {
            return XCTFail("Expected folder with child tab")
        }
        XCTAssertEqual(folder.name, "New")
        XCTAssertEqual(tab.title, "Tab")
    }

    func testUpdateTabWithIdenticalDurableFieldsLeavesTreeUntouched() {
        let spaceId = UUID()
        let tabId = UUID()
        var session = SpaceTab(spaceId: spaceId, state: SpaceTabState(
            activeTabId: tabId,
            activationHistory: [],
            tree: StoredSidebarTree(
                pinned: [],
                unpinned: [.tab(StoredTab(
                    id: tabId,
                    url: "https://example.com/page",
                    title: "Example",
                    faviconDataURL: "data:image/png;base64,AAAA",
                    faviconDominantColor: "#abcdef",
                    isPinned: false,
                    isBookmarked: false,
                    isClosed: false,
                    homeURL: "https://example.com/",
                    homeTitle: "Home",
                    homeFaviconDataURL: nil,
                    homeFaviconDominantColor: nil
                ))],
                bookmarked: []
            )
        ))

        let treeBefore = session.state.tree
        // A progress/runtime tick re-delivers the same durable fields; round-tripping the projected
        // Tab back through updateTab must be a true no-op (no state-repair rewrite, no index rebuild).
        guard let unchanged = session.tab(id: tabId) else { return XCTFail("Expected tab projection") }
        session.updateTab(unchanged)

        XCTAssertEqual(session.state.tree, treeBefore, "No-op durable update must leave the tree byte-identical")

        // A real durable change (new title) must still apply and rebuild the tree.
        var renamed = unchanged
        renamed.title = "Renamed"
        session.updateTab(renamed)

        guard case let .tab(stored)? = session.state.tree.unpinned.first else {
            return XCTFail("Expected tab after durable update")
        }
        XCTAssertEqual(stored.title, "Renamed")
        XCTAssertNotEqual(session.state.tree, treeBefore, "A durable change must mutate the tree")
    }

    func testContentOnlyUpdatePreservesStructureTokenAndBumpsRevisions() {
        let spaceId = UUID()
        let tabId = UUID()
        var session = SpaceTab(spaceId: spaceId, state: SpaceTabState(
            activeTabId: tabId,
            activationHistory: [],
            tree: StoredSidebarTree(
                pinned: [],
                unpinned: [.tab(Self.tab(id: tabId))],
                bookmarked: []
            )
        ))

        let tokenBefore = session.structureToken
        let contentBefore = session.contentRevision
        let durableBefore = session.durableRevision

        // Title/url/favicon rewrite an existing node in place: the tree shape is unchanged, so the
        // structure token (memo key) must survive while both revisions record the durable change.
        var edited = session.tab(id: tabId)!
        edited.title = "Renamed"
        edited.url = URL(string: "https://renamed.example")
        session.updateTab(edited)

        XCTAssertEqual(session.structureToken, tokenBefore, "content-only update must not re-roll the structure token")
        XCTAssertGreaterThan(session.contentRevision, contentBefore, "content-only update must bump contentRevision")
        XCTAssertGreaterThan(session.durableRevision, durableBefore, "content-only update must bump durableRevision (session-save gate)")
        XCTAssertEqual(session.tab(id: tabId)?.title, "Renamed")
        XCTAssertNotNil(session.index.nodePathById[tabId], "the index must stay valid without a rebuild")

        // Flipping a section flag through the same entry point IS structural (repair re-homes the
        // node), so the token must roll.
        var pinned = session.tab(id: tabId)!
        pinned.isPinned = true
        session.updateTab(pinned)

        XCTAssertNotEqual(session.structureToken, tokenBefore, "a section-flag change must roll the structure token")
        XCTAssertEqual(session.state.tree.pinned.map(\.id), [tabId], "repair must re-home the pinned tab")
    }

    func testDurableRevisionBumpsOnContentAndActivation() {
        let firstId = UUID()
        let secondId = UUID()
        var session = SpaceTab(spaceId: UUID(), state: SpaceTabState(
            activeTabId: firstId,
            activationHistory: [],
            tree: StoredSidebarTree(
                pinned: [],
                unpinned: [.tab(Self.tab(id: firstId)), .tab(Self.tab(id: secondId))],
                bookmarked: []
            )
        ))
        XCTAssertEqual(session.durableRevision, 0, "fresh SpaceTab starts at revision 0")

        // Content-only field change.
        var before = session.durableRevision
        var edited = session.tab(id: firstId)!
        edited.title = "Changed Title"
        session.updateTab(edited)
        XCTAssertGreaterThan(session.durableRevision, before, "a durable content change must bump the revision")

        // Activation (non-structural; does not call finishMutation).
        before = session.durableRevision
        session.activateTab(secondId)
        XCTAssertGreaterThan(session.durableRevision, before, "activation changes activeTabId/activationHistory, so must bump")

        // No-op content write (identical fields) must NOT bump.
        before = session.durableRevision
        let unchanged = session.tab(id: secondId)!
        session.updateTab(unchanged)
        XCTAssertEqual(session.durableRevision, before, "a byte-identical update must not bump the revision")
    }

    private static func tab(
        id: UUID,
        title: String = "Tab",
        isPinned: Bool = false,
        isClosed: Bool = false
    ) -> StoredTab {
        StoredTab(
            id: id,
            url: nil,
            title: title,
            faviconDataURL: nil,
            faviconDominantColor: nil,
            isPinned: isPinned,
            isBookmarked: false,
            isClosed: isClosed,
            homeURL: nil,
            homeTitle: nil,
            homeFaviconDataURL: nil,
            homeFaviconDominantColor: nil
        )
    }
}
