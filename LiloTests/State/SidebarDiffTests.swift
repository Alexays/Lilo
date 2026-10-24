import XCTest
@testable import Lilo

/// The mechanical sidebar diff must reproduce, from deltas alone, exactly the projection the
/// store holds after any command, including repair-pass side effects no hand-written
/// presentation case would think of.
@MainActor
final class SidebarDiffTests: XCTestCase {

    // MARK: - Harness

    /// Minimal UI-side model: what a client holding (tabsById, foldersById, treeItems) becomes
    /// after applying a delta.
    private struct Mirror {
        var tabsById: [UUID: Tab]
        var foldersById: [UUID: TabFolder]
        var treeItems: [TabTreeItem]

        init(_ projection: SpaceTabProjection) {
            tabsById = Dictionary(uniqueKeysWithValues: projection.tabs.map { ($0.id, $0) })
            foldersById = Dictionary(uniqueKeysWithValues: projection.folders.map { ($0.id, $0) })
            treeItems = projection.treeItems
        }

        mutating func apply(_ delta: SidebarDelta) {
            for tab in delta.upsertTabs { tabsById[tab.id] = tab }
            for id in delta.removedTabIds { tabsById.removeValue(forKey: id) }
            for folder in delta.upsertFolders { foldersById[folder.id] = folder }
            for id in delta.removedFolderIds { foldersById.removeValue(forKey: id) }
            if let treeItems = delta.treeItems {
                self.treeItems = treeItems
            } else {
                // Keyed by itemId, as the chrome patches its tree.
                let removed = Set(delta.removedTreeItemIds)
                var upserts = Dictionary(uniqueKeysWithValues: delta.upsertTreeItems.map { ($0.itemId, $0) })
                treeItems = treeItems.filter { !removed.contains($0.itemId) }.map { upserts.removeValue(forKey: $0.itemId) ?? $0 }
                treeItems += delta.upsertTreeItems.filter { upserts[$0.itemId] != nil }
            }
        }

        func matches(_ projection: SpaceTabProjection) -> Bool {
            let projectionTabs = Dictionary(uniqueKeysWithValues: projection.tabs.map { ($0.id, $0) })
            // Tabs compared by sidebar content (same exclusion the production diff uses): transient
            // lifecycle fields (lastActiveAt / hasUnsavedFormData) never ship, so they must not break parity.
            let tabsMatch = tabsById.count == projectionTabs.count
                && tabsById.allSatisfy { id, tab in projectionTabs[id].map { tab.hasSameSidebarContent(as: $0) } ?? false }
            return tabsMatch
                && foldersById == Dictionary(uniqueKeysWithValues: projection.folders.map { ($0.id, $0) })
                && treeItems.count == projection.treeItems.count
                && treeItems.sorted(by: TabTreeItem.sidebarOrdering)
                    .elementsEqual(projection.treeItems.sorted(by: TabTreeItem.sidebarOrdering)) { $0.hasSameStructure(as: $1) }
        }
    }

    // MARK: - Unit cases

    func testActivationProducesEmptyDelta() throws {
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
        let change = try XCTUnwrap(changes.changedState)
        let delta = SidebarDiff.delta(from: try XCTUnwrap(change.previousProjection), to: change.projection)

        XCTAssertTrue(delta.isEmpty, "activation must not ship tabs or tree")
        XCTAssertEqual(change.previousActiveTabId, first)
        XCTAssertEqual(change.state.activeTabId, second)
    }

    func testTreeIdentityIgnoresSynthesizedIds() {
        let spaceId = UUID(); let itemId = UUID()
        let a = TabTreeItem(spaceId: spaceId, kind: .tab, itemId: itemId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
        let b = TabTreeItem(spaceId: spaceId, kind: .tab, itemId: itemId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertTrue(a.hasSameStructure(as: b))
    }

    // MARK: - Property-style parity

    /// Deterministic generator so failures reproduce.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    func testRandomCommandSequencesKeepMirrorInParity() throws {
        for seed: UInt64 in [11, 42, 1789] {
            var rng = SeededGenerator(state: seed)
            let spaceId = UUID()
            let initialTabs = (0..<5).map { index in
                Tab(id: UUID(), url: URL(string: "https://seed.example/\(index)"), title: "T\(index)", spaceId: spaceId)
            }
            let store = makeBrowserStateStore(
                spaceId: spaceId,
                tabs: initialTabs,
                treeItems: initialTabs.enumerated().map { unpinnedTabItem($0.element.id, spaceId: spaceId, sortOrder: $0.offset) },
                activeTabId: initialTabs.first?.id
            )
            var mirror = Mirror(try XCTUnwrap(store.structuralProjection(forSpace: spaceId)))

            for step in 0..<60 {
                guard let command = randomCommand(spaceId: spaceId, store: store, rng: &rng) else { continue }
                guard let changes = try? store.mutate(command) else { continue }
                let change = try XCTUnwrap(changes.changedState)
                let previous = try XCTUnwrap(change.previousProjection, "mutate must capture the previous projection")
                mirror.apply(SidebarDiff.delta(from: previous, to: change.projection))
                XCTAssertTrue(
                    mirror.matches(change.projection),
                    "mirror diverged at seed \(seed) step \(step) after \(command)"
                )
            }
        }
    }

    private func randomCommand(spaceId: UUID, store: BrowserStateStore, rng: inout SeededGenerator) -> BrowserCommand? {
        let projection = store.structuralProjection(forSpace: spaceId) ?? SpaceTabProjection(tabs: [], folders: [], treeItems: [])
        let openTabs = projection.tabs.filter { !$0.isClosed }
        func randomTab() -> Tab? { openTabs.randomElement(using: &rng) }

        switch Int.random(in: 0..<10, using: &rng) {
        case 0:
            return .createTab(spaceId: spaceId, tab: Tab(url: URL(string: "https://new.example"), spaceId: spaceId), activate: Bool.random(using: &rng))
        case 1:
            guard let tab = randomTab() else { return nil }
            return .closeTab(spaceId: spaceId, tabId: tab.id)
        case 2:
            guard let tab = randomTab() else { return nil }
            return .activateTab(spaceId: spaceId, tabId: tab.id)
        case 3:
            guard let tab = randomTab() else { return nil }
            return .setPinned(spaceId: spaceId, tabId: tab.id, isPinned: !tab.isPinned)
        case 4:
            guard let tab = randomTab() else { return nil }
            return .setBookmarked(spaceId: spaceId, tabId: tab.id, isBookmarked: !tab.isBookmarked)
        case 5:
            return .createFolder(spaceId: spaceId, folder: TabFolder(spaceId: spaceId), section: .unpinned)
        case 6:
            guard let folder = projection.folders.randomElement(using: &rng) else { return nil }
            return .deleteFolder(spaceId: spaceId, folderId: folder.id)
        case 7:
            guard let folder = projection.folders.randomElement(using: &rng) else { return nil }
            return .updateFolder(spaceId: spaceId, folderId: folder.id, name: "Renamed", color: "#112233", isCollapsed: Bool.random(using: &rng))
        case 8:
            guard let source = randomTab(), let target = randomTab(), source.id != target.id else { return nil }
            return .groupTabs(spaceId: spaceId, sourceTabId: source.id, targetTabId: target.id)
        default:
            guard let tab = randomTab() else { return nil }
            let index = Int.random(in: 0...max(0, projection.treeItems.count - 1), using: &rng)
            return .moveSidebarItem(
                spaceId: spaceId,
                kind: .tab,
                itemId: tab.id,
                parentFolderId: nil,
                section: tab.isPinned ? .pinned : .unpinned,
                insert: .index(index)
            )
        }
    }
}
