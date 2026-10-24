import XCTest
import WebKit
@testable import Lilo

/// The presenter has exactly one decision: a change set whose state captured its pre-mutation
/// projection ships a mechanical `sidebarChanged` diff (nil when nothing observable changed);
/// without one (resync paths) it ships the full state. Structural patches are never coalesced.
@MainActor
final class BrowserChangePresenterTests: XCTestCase {

    private func singleOperation(of event: BrowserChangePresenter.Event?) throws -> [String: Any] {
        let event = try XCTUnwrap(event)
        XCTAssertEqual(event.name, "browserStatePatch")
        let operations = try XCTUnwrap(event.data["operations"] as? [[String: Any]])
        XCTAssertEqual(operations.count, 1)
        return try XCTUnwrap(operations.first)
    }

    func testStructuralChangesInALargeSpaceShipTreeDeltasNotTheTree() throws {
        let spaceId = UUID()
        let tabs = (0..<300).map { Tab(url: URL(string: "https://a.example/\($0)"), title: "Tab \($0)", spaceId: spaceId) }
        let store = makeBrowserStateStore(
            spaceId: spaceId,
            tabs: tabs,
            treeItems: tabs.enumerated().map { unpinnedTabItem($0.element.id, spaceId: spaceId, sortOrder: $0.offset) },
            activeTabId: tabs[0].id
        )
        let fullBytes = try JSONSerialization.data(withJSONObject: try XCTUnwrap(
            BrowserChangePresenter.event(for: BrowserChangeSet(spaceId: spaceId, stateChanges: [XCTUnwrap(store.browserSpaceChange(spaceId: spaceId))]))
        ).data).count

        let newTab = Tab(url: URL(string: "https://new.example"), spaceId: spaceId)
        let created = try singleOperation(of: BrowserChangePresenter.event(for: store.mutate(.createTab(spaceId: spaceId, tab: newTab, activate: true))))
        XCTAssertNil(created["treeItems"])
        XCTAssertEqual((created["upsertTreeItems"] as? [[String: Any]])?.compactMap { $0["itemId"] as? String }, [newTab.id.uuidString])

        let closed = try singleOperation(of: BrowserChangePresenter.event(for: store.mutate(.closeTab(spaceId: spaceId, tabId: tabs[290].id))))
        XCTAssertNil(closed["treeItems"])
        XCTAssertEqual(closed["removedTreeItemIds"] as? [String], [tabs[290].id.uuidString])
        // The later siblings move up one: they ship, the 290 before them do not.
        XCTAssertEqual((closed["upsertTreeItems"] as? [[String: Any]])?.count, 10)
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: closed).count * 20, fullBytes)
    }

    func testSnapshotsLeaveDefaultFieldsOutButKeepTheFavicon() throws {
        var tab = Tab(url: URL(string: "https://a.example"), title: "A", isPinned: true, spaceId: UUID())
        tab.estimatedProgress = 1
        let snapshot = tab.snapshotData()
        XCTAssertEqual(Set(snapshot.keys), ["id", "url", "title", "isPinned", "progress", "spaceId", "kind", "faviconDataURL", "faviconDominantColor"])
        XCTAssertEqual(snapshot["faviconDataURL"] as? String, "", "a missing favicon would keep the chrome's old one")
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: snapshot).count * 3, try JSONSerialization.data(withJSONObject: tab.bridgeData).count)
    }

    func testCreateTabEmitsDiffWithUpsertAndTree() throws {
        let spaceId = UUID()
        let existingId = UUID()
        let store = makeBrowserStateStore(
            spaceId: spaceId,
            tabs: [Tab(id: existingId, url: URL(string: "https://a.example"), title: "A", spaceId: spaceId)],
            treeItems: [unpinnedTabItem(existingId, spaceId: spaceId, sortOrder: 0)],
            activeTabId: existingId
        )

        let newTab = Tab(id: UUID(), url: nil, title: "New", spaceId: spaceId)
        let changes = try store.mutate(.createTab(spaceId: spaceId, tab: newTab, activate: true))
        let operation = try singleOperation(of: BrowserChangePresenter.event(for: changes))

        XCTAssertEqual(operation["kind"] as? String, "sidebarChanged")
        XCTAssertEqual(operation["activeTabId"] as? String, newTab.id.uuidString)
        let upserts = try XCTUnwrap(operation["upsertTabs"] as? [[String: Any]])
        XCTAssertEqual(upserts.compactMap { $0["id"] as? String }, [newTab.id.uuidString])
        let treeItems = try XCTUnwrap(operation["treeItems"] as? [[String: Any]])
        XCTAssertEqual(
            Set(treeItems.compactMap { $0["itemId"] as? String }),
            [existingId.uuidString, newTab.id.uuidString]
        )
        XCTAssertNil(operation["removedTabIds"])
    }

    func testCloseTabPrunedEmitsRemoval() throws {
        let spaceId = UUID()
        let doomedId = UUID()
        let survivorId = UUID()
        let store = makeBrowserStateStore(
            spaceId: spaceId,
            tabs: [
                Tab(id: doomedId, url: URL(string: "https://doomed.example"), title: "Doomed", spaceId: spaceId),
                Tab(id: survivorId, url: URL(string: "https://other.example"), title: "Other", spaceId: spaceId)
            ],
            treeItems: [
                unpinnedTabItem(doomedId, spaceId: spaceId, sortOrder: 0),
                unpinnedTabItem(survivorId, spaceId: spaceId, sortOrder: 1)
            ],
            activeTabId: doomedId
        )

        let changes = try store.mutate(.closeTab(spaceId: spaceId, tabId: doomedId))
        let operation = try singleOperation(of: BrowserChangePresenter.event(for: changes))

        XCTAssertEqual(operation["kind"] as? String, "sidebarChanged")
        XCTAssertEqual(operation["removedTabIds"] as? [String], [doomedId.uuidString])
        XCTAssertNil(operation["upsertTabs"], "a pruned tab must not ship a surviving snapshot")
        XCTAssertEqual(operation["activeTabId"] as? String, survivorId.uuidString)
        let treeItems = try XCTUnwrap(operation["treeItems"] as? [[String: Any]])
        XCTAssertEqual(treeItems.compactMap { $0["itemId"] as? String }, [survivorId.uuidString])
    }

    func testCloseTabPinnedShipsSurvivorSnapshot() throws {
        let spaceId = UUID()
        let pinnedId = UUID()
        let otherId = UUID()
        var pinnedTab = Tab(id: pinnedId, url: URL(string: "https://pinned.example"), title: "Pinned", spaceId: spaceId)
        pinnedTab.isPinned = true
        let store = makeBrowserStateStore(
            spaceId: spaceId,
            tabs: [
                pinnedTab,
                Tab(id: otherId, url: URL(string: "https://other.example"), title: "Other", spaceId: spaceId)
            ],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: pinnedId, parentFolderId: nil, section: .pinned, sortOrder: 0),
                unpinnedTabItem(otherId, spaceId: spaceId, sortOrder: 0)
            ],
            activeTabId: otherId
        )

        let changes = try store.mutate(.closeTab(spaceId: spaceId, tabId: pinnedId))
        let operation = try singleOperation(of: BrowserChangePresenter.event(for: changes))

        XCTAssertEqual(operation["kind"] as? String, "sidebarChanged")
        let upserts = try XCTUnwrap(operation["upsertTabs"] as? [[String: Any]])
        XCTAssertEqual(upserts.compactMap { $0["id"] as? String }, [pinnedId.uuidString])
        XCTAssertEqual(upserts.first?["isClosed"] as? Bool, true)
        XCTAssertNil(operation["removedTabIds"])
    }

    func testActivateTabEmitsActiveIdOnlyDiff() throws {
        let spaceId = UUID()
        let first = UUID(); let second = UUID()
        let store = makeBrowserStateStore(
            spaceId: spaceId,
            tabs: [
                Tab(id: first, url: URL(string: "https://a.example"), title: "A", spaceId: spaceId),
                Tab(id: second, url: URL(string: "https://b.example"), title: "B", spaceId: spaceId)
            ],
            treeItems: [unpinnedTabItem(first, spaceId: spaceId, sortOrder: 0), unpinnedTabItem(second, spaceId: spaceId, sortOrder: 1)],
            activeTabId: first
        )

        let changes = try store.mutate(.activateTab(spaceId: spaceId, tabId: second))
        let operation = try singleOperation(of: BrowserChangePresenter.event(for: changes))

        XCTAssertEqual(operation["kind"] as? String, "sidebarChanged")
        XCTAssertEqual(operation["activeTabId"] as? String, second.uuidString)
        XCTAssertNil(operation["upsertTabs"], "plain activation must not re-ship snapshots")
        XCTAssertNil(operation["treeItems"], "plain activation must not re-ship the tree")
    }

    func testSetPinnedEmitsSidebarChangedDiff() throws {
        let spaceId = UUID()
        let tabId = UUID(); let other = UUID()
        let store = makeBrowserStateStore(
            spaceId: spaceId,
            tabs: [
                Tab(id: tabId, url: URL(string: "https://a.example"), title: "A", spaceId: spaceId),
                Tab(id: other, url: URL(string: "https://b.example"), title: "B", spaceId: spaceId)
            ],
            treeItems: [unpinnedTabItem(tabId, spaceId: spaceId, sortOrder: 0), unpinnedTabItem(other, spaceId: spaceId, sortOrder: 1)],
            activeTabId: tabId
        )

        let changes = try store.mutate(.setPinned(spaceId: spaceId, tabId: tabId, isPinned: true))
        let operation = try singleOperation(of: BrowserChangePresenter.event(for: changes))

        XCTAssertEqual(operation["kind"] as? String, "sidebarChanged")
        let upserts = try XCTUnwrap(operation["upsertTabs"] as? [[String: Any]])
        XCTAssertEqual(upserts.compactMap { $0["id"] as? String }, [tabId.uuidString])
        XCTAssertEqual(upserts.first?["isPinned"] as? Bool, true)
        XCTAssertNotNil(operation["treeItems"], "section move must ship the tree")
        XCTAssertNil(operation["removedTabIds"])
    }

    func testMoveSidebarItemEmitsTreeOnlyDiff() throws {
        let spaceId = UUID()
        let first = UUID(); let second = UUID()
        let store = makeBrowserStateStore(
            spaceId: spaceId,
            tabs: [
                Tab(id: first, url: URL(string: "https://a.example"), title: "A", spaceId: spaceId),
                Tab(id: second, url: URL(string: "https://b.example"), title: "B", spaceId: spaceId)
            ],
            treeItems: [unpinnedTabItem(first, spaceId: spaceId, sortOrder: 0), unpinnedTabItem(second, spaceId: spaceId, sortOrder: 1)],
            activeTabId: first
        )

        let changes = try store.mutate(.moveSidebarItem(
            spaceId: spaceId, kind: .tab, itemId: second,
            parentFolderId: nil, section: .unpinned, insert: .index(0)
        ))
        let operation = try singleOperation(of: BrowserChangePresenter.event(for: changes))

        XCTAssertEqual(operation["kind"] as? String, "sidebarChanged")
        XCTAssertNotNil(operation["treeItems"])
        XCTAssertNil(operation["upsertTabs"], "a pure reorder must not re-ship tab snapshots")
        XCTAssertNil(operation["removedTabIds"])
    }

    func testNoOpMutationEmitsNothing() throws {
        let spaceId = UUID()
        let tabId = UUID()
        let store = makeBrowserStateStore(
            spaceId: spaceId,
            tabs: [Tab(id: tabId, url: URL(string: "https://a.example"), title: "A", spaceId: spaceId)],
            treeItems: [unpinnedTabItem(tabId, spaceId: spaceId, sortOrder: 0)],
            activeTabId: tabId
        )

        // createFolder into the bookmarked section is rejected upstream and returns `unchanged`.
        let changes = try store.mutate(.createFolder(spaceId: spaceId, folder: TabFolder(spaceId: spaceId), section: .bookmarked))

        XCTAssertNil(BrowserChangePresenter.event(for: changes), "no-op paths must not emit")
    }

    func testChangeSetWithoutPreviousProjectionShipsFullState() throws {
        let spaceId = UUID()
        let tabId = UUID()
        let store = makeBrowserStateStore(
            spaceId: spaceId,
            tabs: [Tab(id: tabId, url: URL(string: "https://a.example"), title: "A", spaceId: spaceId)],
            treeItems: [unpinnedTabItem(tabId, spaceId: spaceId, sortOrder: 0)],
            activeTabId: tabId
        )
        // Resync paths (space switch, restore, cross-space moves) build the change set through
        // the public browserSpaceChange, which captures no previous projection.
        let change = try XCTUnwrap(store.browserSpaceChange(spaceId: spaceId))

        let event = try XCTUnwrap(BrowserChangePresenter.event(for: BrowserChangeSet(spaceId: spaceId, stateChanges: [change])))

        XCTAssertEqual(event.name, "browserStateChanged")
        XCTAssertNotNil(event.data["states"])
    }

    func testFullStateOmitsFaviconsOnlyForSyncedSpaces() throws {
        let spaceId = UUID()
        let tabId = UUID()
        var tab = Tab(id: tabId, url: URL(string: "https://a.example"), title: "A", spaceId: spaceId)
        tab.faviconDataURL = "data:image/png;base64,AAAA"
        let store = makeBrowserStateStore(
            spaceId: spaceId,
            tabs: [tab],
            treeItems: [unpinnedTabItem(tabId, spaceId: spaceId, sortOrder: 0)],
            activeTabId: tabId
        )
        let change = try XCTUnwrap(store.browserSpaceChange(spaceId: spaceId))
        let changes = BrowserChangeSet(spaceId: spaceId, stateChanges: [change])

        func firstTabPayload(_ event: BrowserChangePresenter.Event?) throws -> [String: Any] {
            let states = try XCTUnwrap(try XCTUnwrap(event).data["states"] as? [[String: Any]])
            return try XCTUnwrap((states.first?["tabs"] as? [[String: Any]])?.first)
        }

        let fresh = try firstTabPayload(BrowserChangePresenter.event(for: changes))
        XCTAssertEqual(fresh["faviconDataURL"] as? String, "data:image/png;base64,AAAA", "first ship must carry the favicon")

        let synced = try firstTabPayload(BrowserChangePresenter.event(for: changes, omitFaviconsForSpaces: [spaceId]))
        XCTAssertNil(synced["faviconDataURL"], "a synced space must not re-ship the favicon")
        XCTAssertEqual(synced["title"] as? String, "A", "the rest of the snapshot must be intact")
    }

    func testUpsertLeavesOutAnUnchangedFavicon() throws {
        let spaceId = UUID()
        let tabId = UUID()
        let store = makeBrowserStateStore(
            spaceId: spaceId,
            tabs: [Tab(id: tabId, url: URL(string: "https://a.example"), title: "A", faviconDataURL: "data:image/png;base64,AAAA", spaceId: spaceId)],
            treeItems: [unpinnedTabItem(tabId, spaceId: spaceId, sortOrder: 0)],
            activeTabId: tabId
        )

        let changes = try store.mutate(.setBookmarked(spaceId: spaceId, tabId: tabId, isBookmarked: true))
        let operation = try singleOperation(of: BrowserChangePresenter.event(for: changes))

        let upsert = try XCTUnwrap((operation["upsertTabs"] as? [[String: Any]])?.first)
        XCTAssertEqual(upsert["isBookmarked"] as? Bool, true)
        XCTAssertNil(upsert["faviconDataURL"], "the chrome already holds this favicon")
    }

    func testActivationSidebarEventCarriesSnapshot() throws {
        let spaceId = UUID()
        let tab = Tab(id: UUID(), url: URL(string: "https://a.example"), title: "A", spaceId: spaceId)

        let event = BrowserChangePresenter.activationSidebarEvent(tab: tab, spaceId: spaceId)
        let operation = try singleOperation(of: event)

        XCTAssertEqual(operation["kind"] as? String, "sidebarChanged")
        XCTAssertEqual(operation["activeTabId"] as? String, tab.id.uuidString)
        let upserts = try XCTUnwrap(operation["upsertTabs"] as? [[String: Any]])
        XCTAssertEqual(upserts.compactMap { $0["id"] as? String }, [tab.id.uuidString])
    }

    func testStructuralOperationsAreNeverCoalesced() {
        let structural: [String: Any] = [
            "operations": [["kind": "sidebarChanged", "spaceId": "s", "activeTabId": "x"]]
        ]
        XCTAssertNil(BridgeEventCoalescer.coalescingTabId(for: "browserStatePatch", data: structural))

        let runtime: [String: Any] = [
            "operations": [["kind": "tabUpdated", "tab": ["id": "x"]]]
        ]
        XCTAssertEqual(BridgeEventCoalescer.coalescingTabId(for: "browserStatePatch", data: runtime), "x")
    }
}
