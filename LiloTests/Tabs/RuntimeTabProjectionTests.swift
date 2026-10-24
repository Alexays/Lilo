import XCTest
@testable import Lilo

/// `tabs(forSpace:)`, `allTabs` and `tabContext(for:)` derive on demand from the durable store and the runtime overlay,
/// so runtime-field and durable-structure changes both show up with no manual index rebuild.
@MainActor
final class RuntimeTabProjectionTests: XCTestCase {
    private var tabManager: TabManager!
    private var spaceId: UUID!

    override func setUp() {
        super.setUp()
        tabManager = TabManager(engineFactory: WKEngineFactory())
        spaceId = UUID()
        tabManager.currentSpaceId = spaceId
    }

    override func tearDown() {
        tabManager = nil
        spaceId = nil
        super.tearDown()
    }

    private func makeTab(_ title: String) -> Tab {
        Tab(url: URL(string: "https://\(title).example"), title: title, spaceId: spaceId)
    }

    private func install(_ tabs: [Tab], activeTabId: UUID? = nil) {
        let treeItems = tabs.enumerated().compactMap { index, tab -> TabTreeItem? in
            guard !tab.isBookmarked, !tab.isClosed || tab.isPinned else { return nil }
            return TabTreeItem(
                spaceId: spaceId,
                kind: .tab,
                itemId: tab.id,
                parentFolderId: tab.groupId,
                section: tab.isPinned ? .pinned : .unpinned,
                sortOrder: index
            )
        }
        let fixture = try! BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: activeTabId,
            tabs: tabs,
            folders: [],
            treeItems: treeItems
        )
        tabManager.installSpaceTabStateForTests(SpaceTabState(fixture), spaceId: spaceId)
    }

    func testProjectionReflectsDurableStructureAndOrder() {
        let a = makeTab("a"), b = makeTab("b"), c = makeTab("c")
        install([a, b, c])

        XCTAssertEqual(tabManager.tabs(forSpace: spaceId).map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(tabManager.allTabs.map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(tabManager.tabContext(for: b.id)?.index, 1)
        XCTAssertEqual(tabManager.tabContext(for: b.id)?.spaceId, spaceId)
        XCTAssertEqual(tabManager.tab(for: c.id)?.id, c.id)
    }

    func testRuntimeMutationIsReflectedWithoutManualRebuild() {
        let a = makeTab("a"), b = makeTab("b")
        install([a, b])

        // A runtime-only mutation writes the shared overlay; every read path must reflect it on
        // demand, with no index rebuild.
        tabManager.mutateTab(id: b.id) {
            $0.isLoading = true
            $0.isAudioPlaying = true
        }

        let fromSpace = tabManager.tabs(forSpace: spaceId).first { $0.id == b.id }
        XCTAssertEqual(fromSpace?.isLoading, true)
        XCTAssertEqual(fromSpace?.isAudioPlaying, true)
        XCTAssertEqual(tabManager.tab(for: b.id)?.isLoading, true)
        XCTAssertEqual(tabManager.tabContext(for: b.id)?.tab.isAudioPlaying, true)
        XCTAssertEqual(tabManager.allTabs.first { $0.id == b.id }?.isLoading, true)

        // The untouched tab keeps its default runtime state.
        XCTAssertEqual(tabManager.tab(for: a.id)?.isLoading, false)
    }

    func testDiscardPreparedTabRuntimeDropsOverlayEntryAtSource() {
        let a = makeTab("a"), b = makeTab("b")
        install([a, b])

        // Give b a runtime overlay entry, then discard its runtime (the close/discard path).
        tabManager.mutateTab(id: b.id) { $0.isAudioPlaying = true }
        let versionAfterSet = tabManager.runtimeOverlay.version

        tabManager.discardPreparedTabRuntime(for: b.id)

        // The overlay entry must be removed at the source (version bumped by the removal), so the
        // post-command projection does not need the O(all-tabs) global prune to clean it up.
        XCTAssertGreaterThan(tabManager.runtimeOverlay.version, versionAfterSet, "Discarding runtime must drop the overlay entry")

        // Re-installing b without the audio flag must show clean state: no stale overlay survives.
        install([a, b])
        XCTAssertEqual(tabManager.tab(for: b.id)?.isAudioPlaying, false, "No stale overlay must survive a discard")
    }

    func testCommandPathProjectionSkipsGlobalPruneButKeepsValidOverlay() {
        let a = makeTab("a"), b = makeTab("b")
        install([a, b])
        tabManager.mutateTab(id: b.id) { $0.isAudioPlaying = true }

        // A command-path projection (prunesStaleOverlay: false) must NOT drop a still-valid overlay
        // entry: b is still in the tree, so its runtime audio flag must survive the projection.
        tabManager.applyDurableProjectionToRuntime(
            tabManager.spaceTabState(forSpace: spaceId),
            spaceId: spaceId,
            prunesStaleOverlay: false
        )

        XCTAssertEqual(tabManager.tab(for: b.id)?.isAudioPlaying, true, "Valid overlay entries must survive a command-path projection")
    }

    func testReinstallingDurableStateUpdatesProjection() {
        let a = makeTab("a"), b = makeTab("b")
        install([a, b])
        XCTAssertEqual(tabManager.tabs(forSpace: spaceId).count, 2)

        let c = makeTab("c")
        install([c])

        XCTAssertEqual(tabManager.tabs(forSpace: spaceId).map(\.id), [c.id])
        XCTAssertNil(tabManager.tabContext(for: a.id))
        XCTAssertNil(tabManager.tab(for: b.id))
    }
}
