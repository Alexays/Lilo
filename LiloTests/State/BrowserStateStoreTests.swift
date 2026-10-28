import XCTest
import WebKit
@testable import Lilo

private struct SidebarStateFixture {
    let spaceId: UUID
    let movingTabId: UUID
    let firstChildTabId: UUID
    let secondChildTabId: UUID
    let folderId: UUID
    let state: BrowserStateFixture

    static func folderWithTwoChildren() throws -> SidebarStateFixture {
        let spaceId = UUID()
        let movingTabId = UUID()
        let firstChildTabId = UUID()
        let secondChildTabId = UUID()
        let folderId = UUID()
        let folder = TabFolder(id: folderId, spaceId: spaceId, name: "Folder", color: "#111111")
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: movingTabId,
            tabs: [
                Tab(id: movingTabId, url: URL(string: "https://moving.example"), title: "Moving", spaceId: spaceId),
                Tab(id: firstChildTabId, url: URL(string: "https://first.example"), title: "First", groupId: folderId, spaceId: spaceId),
                Tab(id: secondChildTabId, url: URL(string: "https://second.example"), title: "Second", groupId: folderId, spaceId: spaceId)
            ],
            folders: [folder],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: movingTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folderId, parentFolderId: nil, section: .unpinned, sortOrder: 1),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: firstChildTabId, parentFolderId: folderId, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: secondChildTabId, parentFolderId: folderId, section: .unpinned, sortOrder: 1)
            ]
        )
        return SidebarStateFixture(
            spaceId: spaceId,
            movingTabId: movingTabId,
            firstChildTabId: firstChildTabId,
            secondChildTabId: secondChildTabId,
            folderId: folderId,
            state: state
        )
    }
}

@MainActor
private func makeSpaceSnapshot(
    tabs: [Tab],
    folders: [TabFolder],
    treeItems: [TabTreeItem],
    engines: [UUID: WKWebViewTab],
    tabAdapters: [UUID: TabExtensionAdapter] = [:],
    interactionStates: [UUID: Any] = [:],
    restoringTabIds: [UUID: Date] = [:],
    activeTabId: UUID? = nil,
    activationHistory: [UUID] = [],
    viewedAt: [UUID: Date] = [:],
    lastAccessedAt: Date = Date(),
    spaceId: UUID? = nil
) -> BrowserStateStore.SpaceSnapshot {
    let resolvedSpaceId = spaceId ?? tabs.first?.spaceId ?? folders.first?.spaceId ?? treeItems.first?.spaceId ?? UUID()
    return BrowserStateStore.SpaceSnapshot(
        spaceTab: SpaceTab(
            spaceId: resolvedSpaceId,
            state: SpaceTabStateImporter.importState(
                activeTabId: activeTabId,
                activationHistory: activationHistory,
                viewedAt: viewedAt,
                tabs: tabs,
                folders: folders,
                treeItems: treeItems,
                spaceId: resolvedSpaceId
            )
        ),
        engines: engines,
        tabAdapters: tabAdapters,
        interactionStates: interactionStates,
        restoringTabIds: restoringTabIds,
        lastAccessedAt: lastAccessedAt
    )
}

@MainActor
struct BrowserStateStoreHarness {
    private let store = BrowserStateStore()

    init(states: [BrowserStateFixture]) {
        for state in states {
            store.storeSpace(
                id: state.spaceId,
                snapshot: BrowserStateStore.SpaceSnapshot(
                    spaceTab: SpaceTab(spaceId: state.spaceId, state: SpaceTabState(state)),
                    engines: [:]
                )
            )
        }
    }

    func state(spaceId: UUID) -> BrowserStateFixture? {
        store.browserSpaceChange(spaceId: spaceId)?.browserStateFixture()
    }

    func mutate(_ command: BrowserCommand) throws -> BrowserChangeSet {
        try store.mutate(command)
    }

    func unlockedFolders() -> [(spaceId: UUID, folderId: UUID)] {
        store.unlockedFolders()
    }
}

@MainActor
final class BrowserStateStoreTests: XCTestCase {
    func testSetFolderLockLocksAndUnlockOpensTheFolder() throws {
        let spaceId = UUID()
        let folder = TabFolder(spaceId: spaceId, name: "Finances", isCollapsed: true)
        var child = Tab(url: URL(string: "https://bank.example"), spaceId: spaceId)
        child.groupId = folder.id
        let store = BrowserStateStoreHarness(states: [try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: nil,
            tabs: [child],
            folders: [folder],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folder.id, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: child.id, parentFolderId: folder.id, section: .unpinned, sortOrder: 0)
            ]
        )])

        let locked = try store.mutate(.setFolderLock(spaceId: spaceId, folderId: folder.id, lock: FolderLock(allowsBiometrics: false)))
        XCTAssertEqual(locked.changedState?.foldersById[folder.id]?.isLocked, true)
        XCTAssertTrue(store.unlockedFolders().isEmpty)

        let unlocked = try store.mutate(.setFolderUnlocked(spaceId: spaceId, folderId: folder.id, isUnlocked: true))
        XCTAssertEqual(unlocked.changedState?.foldersById[folder.id]?.isLocked, false)
        XCTAssertEqual(unlocked.changedState?.foldersById[folder.id]?.isCollapsed, false, "unlocking opens the folder")
        XCTAssertEqual(store.unlockedFolders().map(\.folderId), [folder.id])

        let removed = try store.mutate(.setFolderLock(spaceId: spaceId, folderId: folder.id, lock: nil))
        XCTAssertNil(removed.changedState?.foldersById[folder.id]?.lock)
        XCTAssertTrue(store.unlockedFolders().isEmpty)
    }

    func testATabOfALockedFolderCannotLeaveIt() throws {
        let spaceId = UUID()
        var folder = TabFolder(spaceId: spaceId, name: "Finances")
        folder.lock = FolderLock(allowsBiometrics: false)
        var bank = Tab(url: URL(string: "https://bank.example"), spaceId: spaceId)
        bank.groupId = folder.id
        let news = Tab(url: URL(string: "https://news.example"), spaceId: spaceId)
        let store = BrowserStateStoreHarness(states: [try BrowserStateFixture(
            spaceId: spaceId, activeTabId: news.id, tabs: [bank, news], folders: [folder],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: news.id, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folder.id, parentFolderId: nil, section: .unpinned, sortOrder: 1),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: bank.id, parentFolderId: folder.id, section: .unpinned, sortOrder: 0)
            ]
        )])

        XCTAssertThrowsError(try store.mutate(.setBookmarked(spaceId: spaceId, tabId: bank.id, isBookmarked: true)))
        XCTAssertThrowsError(try store.mutate(.splitTabs(spaceId: spaceId, tabId: news.id, targetTabId: bank.id, vertical: false, before: false)))
        XCTAssertThrowsError(try store.mutate(.groupTabs(spaceId: spaceId, sourceTabId: bank.id, targetTabId: news.id)))

        XCTAssertEqual(store.state(spaceId: spaceId)?.tabsById[bank.id]?.groupId, folder.id, "the tab never left its locked folder")
    }

    func testUnlockingAnUnprotectedFolderChangesNothing() throws {
        let spaceId = UUID()
        let folder = TabFolder(spaceId: spaceId, name: "Plain")
        let store = BrowserStateStoreHarness(states: [try BrowserStateFixture(
            spaceId: spaceId, activeTabId: nil, tabs: [], folders: [folder],
            treeItems: [TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folder.id, parentFolderId: nil, section: .unpinned, sortOrder: 0)]
        )])

        _ = try store.mutate(.setFolderUnlocked(spaceId: spaceId, folderId: folder.id, isUnlocked: true))

        XCTAssertTrue(store.unlockedFolders().isEmpty)
    }

    func testOwningSpaceIdAndContainsAnswerMembershipViaIndex() {
        let store = BrowserStateStore()
        let spaceId = UUID()
        let tabId = UUID()
        store.storeActiveSpace(
            id: spaceId,
            snapshot: makeSpaceSnapshot(
                tabs: [Tab(id: tabId, url: URL(string: "https://example.com"), title: "T", spaceId: spaceId)],
                folders: [],
                treeItems: [TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)],
                engines: [:],
                activeTabId: tabId,
                spaceId: spaceId
            )
        )

        XCTAssertEqual(store.owningSpaceId(forTab: tabId), spaceId)
        XCTAssertTrue(store.space(spaceId, contains: tabId))
        XCTAssertNil(store.owningSpaceId(forTab: UUID()))
        XCTAssertFalse(store.space(spaceId, contains: UUID()))
    }

    func testStoringIdenticalActiveSpaceStatePreservesStructureToken() {
        let store = BrowserStateStore()
        let spaceId = UUID()
        let tabId = UUID()
        let tab = Tab(id: tabId, url: URL(string: "https://example.com"), title: "T", spaceId: spaceId)
        let treeItems = [TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)]
        let viewedAt = [tabId: Date(timeIntervalSince1970: 0)]

        store.storeActiveSpace(
            id: spaceId,
            snapshot: makeSpaceSnapshot(tabs: [tab], folders: [], treeItems: treeItems, engines: [:], activeTabId: tabId, viewedAt: viewedAt, spaceId: spaceId)
        )
        let tokenBefore = store.space(id: spaceId)?.spaceTab.structureToken

        // Re-syncing a byte-identical state (the syncActiveBrowserState hot path) mints a fresh SpaceTab
        // upstream, but the store must keep the existing one so the projection memo-cache survives.
        store.storeActiveSpace(
            id: spaceId,
            snapshot: makeSpaceSnapshot(tabs: [tab], folders: [], treeItems: treeItems, engines: [:], activeTabId: tabId, viewedAt: viewedAt, spaceId: spaceId)
        )

        XCTAssertNotNil(tokenBefore)
        XCTAssertEqual(store.space(id: spaceId)?.spaceTab.structureToken, tokenBefore, "Identical re-sync must preserve the structure token")
    }

    func testStoringChangedActiveSpaceStateRollsStructureToken() {
        let store = BrowserStateStore()
        let spaceId = UUID()
        let tabId = UUID()
        let secondId = UUID()
        let tab = Tab(id: tabId, url: URL(string: "https://example.com"), title: "T", spaceId: spaceId)
        let tab2 = Tab(id: secondId, url: URL(string: "https://two.com"), title: "Two", spaceId: spaceId)

        store.storeActiveSpace(
            id: spaceId,
            snapshot: makeSpaceSnapshot(
                tabs: [tab],
                folders: [],
                treeItems: [TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)],
                engines: [:], activeTabId: tabId, spaceId: spaceId
            )
        )
        let tokenBefore = store.space(id: spaceId)?.spaceTab.structureToken

        // A real structural change (a new tab) must roll the token so memoized projections invalidate.
        store.storeActiveSpace(
            id: spaceId,
            snapshot: makeSpaceSnapshot(
                tabs: [tab, tab2],
                folders: [],
                treeItems: [
                    TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                    TabTreeItem(spaceId: spaceId, kind: .tab, itemId: secondId, parentFolderId: nil, section: .unpinned, sortOrder: 1)
                ],
                engines: [:], activeTabId: tabId, spaceId: spaceId
            )
        )

        XCTAssertNotNil(tokenBefore)
        XCTAssertNotEqual(store.space(id: spaceId)?.spaceTab.structureToken, tokenBefore, "A structural change must roll the structure token")
    }

    func testContentOnlyUpdateKeepsTokenButRefreshesProjection() {
        let store = BrowserStateStore()
        let spaceId = UUID()
        let tabId = UUID()
        store.storeActiveSpace(
            id: spaceId,
            snapshot: makeSpaceSnapshot(
                tabs: [Tab(id: tabId, url: URL(string: "https://example.com"), title: "Old", spaceId: spaceId)],
                folders: [],
                treeItems: [TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)],
                engines: [:],
                activeTabId: tabId,
                spaceId: spaceId
            )
        )
        // Warm the projection memo so a stale hit would be observable.
        XCTAssertEqual(store.structuralProjection(forSpace: spaceId)?.tabs.first?.title, "Old")
        let tokenBefore = store.space(id: spaceId)?.spaceTab.structureToken
        let revisionBefore = store.space(id: spaceId)?.spaceTab.durableRevision

        store.updateTab(id: tabId) { $0.title = "New" }

        XCTAssertEqual(
            store.space(id: spaceId)?.spaceTab.structureToken, tokenBefore,
            "a title-only update must not re-roll the structure token"
        )
        XCTAssertEqual(
            store.structuralProjection(forSpace: spaceId)?.tabs.first?.title, "New",
            "the next projection must see the content change (memo invalidated via contentRevision)"
        )
        XCTAssertGreaterThan(
            store.space(id: spaceId)!.spaceTab.durableRevision, revisionBefore!,
            "a title-only update must still bump durableRevision (session-save gate)"
        )
    }

    func testTerminalDirectoryChangeIsSavedWithTheTab() throws {
        let store = BrowserStateStore()
        let spaceId = UUID()
        let tabId = UUID()
        store.storeActiveSpace(
            id: spaceId,
            snapshot: makeSpaceSnapshot(
                tabs: [Tab(id: tabId, title: "~", spaceId: spaceId, kind: .terminal, cwd: "/Users/me")],
                folders: [],
                treeItems: [TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)],
                engines: [:],
                activeTabId: tabId,
                spaceId: spaceId
            )
        )
        let revisionBefore = try XCTUnwrap(store.space(id: spaceId)?.spaceTab.durableRevision)

        store.updateTab(id: tabId) { $0.cwd = "/Users/me/project" }

        let spaceTab = try XCTUnwrap(store.space(id: spaceId)?.spaceTab)
        XCTAssertEqual(spaceTab.tab(id: tabId)?.cwd, "/Users/me/project")
        XCTAssertGreaterThan(spaceTab.durableRevision, revisionBefore)
    }

    func testRuntimeOverlayVersionBumpsOnlyOnRealChange() {
        let overlay = RuntimeOverlayStore()
        let tabId = UUID()
        let tab = Tab(id: tabId, url: URL(string: "https://example.com"), title: "T", spaceId: UUID())

        let v0 = overlay.version
        overlay.setRuntimeState(from: tab)
        let v1 = overlay.version
        XCTAssertGreaterThan(v1, v0, "Setting runtime state must bump the version")

        // Removing a present entry bumps; removing an absent entry must not.
        overlay.removeRuntimeState(for: tabId)
        let v2 = overlay.version
        XCTAssertGreaterThan(v2, v1, "Removing a present entry must bump the version")
        overlay.removeRuntimeState(for: UUID())
        XCTAssertEqual(overlay.version, v2, "Removing an absent entry must not bump the version")
    }

    func testDurableTabResolvesSingleTabWithoutFullProjection() {
        let store = BrowserStateStore()
        let spaceId = UUID()
        let tabId = UUID()
        let tab = Tab(id: tabId, url: URL(string: "https://example.com"), title: "Durable", spaceId: spaceId)
        store.storeActiveSpace(
            id: spaceId,
            snapshot: makeSpaceSnapshot(
                tabs: [tab],
                folders: [],
                treeItems: [TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)],
                engines: [:], activeTabId: tabId, spaceId: spaceId
            )
        )

        let resolved = store.durableTab(for: tabId)
        XCTAssertEqual(resolved?.spaceId, spaceId)
        XCTAssertEqual(resolved?.tab.id, tabId)
        XCTAssertEqual(resolved?.tab.title, "Durable")
        XCTAssertNil(store.durableTab(for: UUID()), "Unknown tab id resolves to nil")
    }

    func testSpaceSnapshotSeparatesDurableStateFromRuntimeParking() throws {
        let spaceId = UUID()
        let tabId = UUID()
        let durableTab = Tab(id: tabId, url: URL(string: "https://durable.example"), title: "Durable", spaceId: spaceId)
        var runtimeTab = durableTab
        runtimeTab.isLoading = true
        let snapshot = BrowserStateStore.SpaceSnapshot(
            spaceTab: SpaceTab(
                spaceId: spaceId,
                state: SpaceTabStateImporter.importState(
                    activeTabId: tabId,
                    activationHistory: [],
                    tabs: [durableTab],
                    folders: [],
                    treeItems: [
                        TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
                    ],
                    spaceId: spaceId
                )
            ),
            engines: [:]
        )
        let store = BrowserStateStore()
        store.runtimeOverlay.setRuntimeState(from: runtimeTab)
        store.storeSpace(id: spaceId, snapshot: snapshot)

        XCTAssertEqual(snapshot.spaceTab.state.projectedSidebar(spaceId: spaceId).tabs.first?.title, "Durable")
        XCTAssertEqual(store.browserSpaceChange(spaceId: spaceId)?.tabsById[tabId]?.title, "Durable")
        XCTAssertEqual(store.browserSpaceChange(spaceId: spaceId)?.tabsById[tabId]?.isLoading, true)
    }

    /// The store's copy of the visible space must not keep a closed tab's page alive until the next sync.
    func testClosingATabReleasesItsEngine() throws {
        let spaceId = UUID()
        let tabId = UUID()
        let keptTabId = UUID()
        let tabs = [
            Tab(id: tabId, url: URL(string: "https://closing.example"), title: "Closing", spaceId: spaceId),
            Tab(id: keptTabId, url: URL(string: "https://kept.example"), title: "Kept", spaceId: spaceId)
        ]
        let store = BrowserStateStore()
        weak var weakEngine: WKWebViewTab?
        let keptEngine = WKWebViewTab(configuration: WKWebViewConfiguration())
        defer { keptEngine.teardown() }
        do {
            let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
            weakEngine = engine
            store.storeActiveSpace(
                id: spaceId,
                snapshot: makeSpaceSnapshot(
                    tabs: tabs,
                    folders: [],
                    treeItems: [
                        TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                        TabTreeItem(spaceId: spaceId, kind: .tab, itemId: keptTabId, parentFolderId: nil, section: .unpinned, sortOrder: 1)
                    ],
                    engines: [tabId: engine, keptTabId: keptEngine],
                    activeTabId: keptTabId,
                    spaceId: spaceId
                )
            )
            engine.teardown()
        }

        try store.mutate(.closeTab(spaceId: spaceId, tabId: tabId))

        XCTAssertNil(store.engine(tabId: tabId, spaceId: spaceId))
        XCTAssertNil(weakEngine, "nothing else holds the closed tab's engine")
        XCTAssertTrue(store.engine(tabId: keptTabId, spaceId: spaceId) === keptEngine)
    }

    func testProcessSnapshotGroupsWebKitProcessIdentifiers() throws {
        let spaceId = UUID()
        let tabId = UUID()
        var tab = Tab(id: tabId, url: URL(string: "https://video.example"), title: "Video", spaceId: spaceId)
        tab.isAudioPlaying = true
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        defer { engine.teardown() }
        let store = BrowserStateStore()
        store.storeActiveSpace(
            id: spaceId,
            snapshot: makeSpaceSnapshot(
                tabs: [tab],
                folders: [],
                treeItems: [
                    TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
                ],
                engines: [tabId: engine],
                activeTabId: tabId,
                spaceId: spaceId
            )
        )

        let processes = store.processSnapshot(
            metricsProvider: { pids in
                Dictionary(uniqueKeysWithValues: pids.map { ($0, ProcessResourceMetrics(residentSizeBytes: UInt64($0 * 10), cpuPercent: 1.5)) })
            },
            diagnosticsProvider: { _ in
                WebViewProcessDiagnostics(
                    webProcessIdentifier: 101,
                    networkProcessIdentifier: 202,
                    gpuProcessIdentifier: 303,
                    webProcessIsResponsive: true,
                    webProcessState: 2
                )
            }
        )

        let webProcess = try XCTUnwrap(processes.first { $0.kind == .webContent })
        XCTAssertEqual(webProcess.pid, 101)
        XCTAssertEqual(webProcess.webProcessState, 2)
        XCTAssertEqual(webProcess.webProcessIsResponsive, true)
        XCTAssertEqual(webProcess.metrics?.residentSizeBytes, 1_010)
        XCTAssertEqual(webProcess.tabs.first?.id, tabId)
        XCTAssertEqual(webProcess.tabs.first?.lifecycle, "active")

        let networkProcess = try XCTUnwrap(processes.first { $0.kind == .network })
        XCTAssertEqual(networkProcess.pid, 202)
        XCTAssertEqual(networkProcess.tabs.first?.id, tabId)

        let gpuProcess = try XCTUnwrap(processes.first { $0.kind == .gpu })
        XCTAssertEqual(gpuProcess.pid, 303)
        XCTAssertEqual(gpuProcess.tabs.first?.id, tabId)
    }

    func testBrowserRuntimeCoordinatorAppliesStoreRuntimeBridgeAndSaveSideEffects() throws {
        let spaceId = UUID()
        let firstTabId = UUID()
        let secondTabId = UUID()
        let firstTab = Tab(id: firstTabId, url: URL(string: "https://first.example"), title: "First", spaceId: spaceId)
        let secondTab = Tab(id: secondTabId, url: URL(string: "https://second.example"), title: "Second", spaceId: spaceId)
        let state = SpaceTabStateImporter.importState(
            activeTabId: firstTabId,
            activationHistory: [],
            tabs: [firstTab, secondTab],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: firstTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: secondTabId, parentFolderId: nil, section: .unpinned, sortOrder: 1)
            ],
            spaceId: spaceId
        )
        let store = BrowserStateStore()
        store.storeSpace(
            id: spaceId,
            snapshot: BrowserStateStore.SpaceSnapshot(spaceTab: SpaceTab(spaceId: spaceId, state: state), engines: [:])
        )
        let tabManager = TabManager(engineFactory: WKEngineFactory())
        tabManager.currentSpaceId = spaceId
        tabManager.browserStateStore = store
        tabManager.applyDurableProjectionToRuntime(state, spaceId: spaceId)
        var syncCount = 0
        var emittedChange: BrowserChangeSet?
        var saveCount = 0
        let coordinator = BrowserRuntimeCoordinator(
            tabManager: tabManager,
            browserStateStore: store,
            syncActiveBrowserState: { syncCount += 1 },
            emitBrowserChange: { emittedChange = $0 },
            scheduleSave: { saveCount += 1 }
        )

        let changes = try coordinator.apply(.activateTab(spaceId: spaceId, tabId: secondTabId))

        XCTAssertEqual(changes.changedState?.state.activeTabId, secondTabId)
        XCTAssertEqual(tabManager.activeTabId, secondTabId)
        XCTAssertEqual(emittedChange?.changedState?.state.activeTabId, secondTabId)
        XCTAssertEqual(syncCount, 0)
        XCTAssertEqual(saveCount, 1)
    }

    func testBrowserStateStoreActivateTabMutatesStateAndReturnsChangeSet() throws {
        let spaceId = UUID()
        let firstTabId = UUID()
        let secondTabId = UUID()
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: firstTabId,
            tabs: [
                Tab(id: firstTabId, url: URL(string: "https://first.example"), title: "First", spaceId: spaceId),
                Tab(id: secondTabId, url: URL(string: "https://second.example"), title: "Second", spaceId: spaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: firstTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: secondTabId, parentFolderId: nil, section: .unpinned, sortOrder: 1)
            ]
        )
        let store = BrowserStateStoreHarness(states: [state])

        let changes = try store.mutate(.activateTab(spaceId: spaceId, tabId: secondTabId))

        XCTAssertEqual(store.state(spaceId: spaceId)?.activeTabId, secondTabId)
        XCTAssertEqual(changes.spaceId, spaceId)
        XCTAssertEqual(changes.changedState?.state.activeTabId, secondTabId)
    }

    @MainActor
    func testActivateTabStampsLastActiveAtWithoutTouchingDurableState() throws {
        let spaceId = UUID()
        let firstTabId = UUID()
        let secondTabId = UUID()
        let fixture = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: firstTabId,
            tabs: [
                Tab(id: firstTabId, url: URL(string: "https://first.example"), title: "First", spaceId: spaceId),
                Tab(id: secondTabId, url: URL(string: "https://second.example"), title: "Second", spaceId: spaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: firstTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: secondTabId, parentFolderId: nil, section: .unpinned, sortOrder: 1)
            ]
        )
        let store = BrowserStateStore()
        store.storeSpace(
            id: spaceId,
            snapshot: BrowserStateStore.SpaceSnapshot(
                spaceTab: SpaceTab(spaceId: spaceId, state: SpaceTabState(fixture)),
                engines: [:]
            )
        )

        XCTAssertNil(store.runtimeOverlay.applied(to: Tab(id: secondTabId)).lastActiveAt)
        _ = try store.mutate(.activateTab(spaceId: spaceId, tabId: secondTabId))
        XCTAssertNotNil(store.runtimeOverlay.applied(to: Tab(id: secondTabId)).lastActiveAt)
    }

    @MainActor
    func testUpdateTabPreservesUnrelatedRuntimeFlags() throws {
        // A call's runtime flags must survive an unrelated runtime update: losing them drops the indicator and the capture
        // trim-protection, so memory management discards the live call.
        let spaceId = UUID()
        let tabId = UUID()
        let fixture = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: tabId,
            tabs: [Tab(id: tabId, url: URL(string: "https://meet.example"), title: "Call", spaceId: spaceId)],
            folders: [],
            treeItems: [TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)]
        )
        let store = BrowserStateStore()
        store.storeSpace(
            id: spaceId,
            snapshot: BrowserStateStore.SpaceSnapshot(
                spaceTab: SpaceTab(spaceId: spaceId, state: SpaceTabState(fixture)),
                engines: [:]
            )
        )

        // Capture starts: mic + screen active.
        store.updateTab(id: tabId) { $0.isMicrophoneActive = true; $0.isScreenSharing = true }
        // An unrelated runtime tick (e.g. audio playback state) arrives for the same tab.
        store.updateTab(id: tabId) { $0.isAudioPlaying = true }

        let projected = store.runtimeOverlay.applied(to: Tab(id: tabId))
        XCTAssertTrue(projected.isMicrophoneActive, "mic flag must survive an unrelated runtime update")
        XCTAssertTrue(projected.isScreenSharing, "screen-share flag must survive an unrelated runtime update")
        XCTAssertTrue(projected.isAudioPlaying)
    }

    func testBrowserStateStoreActivateClosedPinnedTabReopensAndActivatesIt() throws {
        let spaceId = UUID()
        let activeTabId = UUID()
        let pinnedTabId = UUID()
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: activeTabId,
            tabs: [
                Tab(id: activeTabId, url: URL(string: "https://active.example"), title: "Active", spaceId: spaceId),
                Tab(id: pinnedTabId, url: URL(string: "https://pinned.example"), title: "Pinned", isPinned: true, isClosed: true, spaceId: spaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: pinnedTabId, parentFolderId: nil, section: .pinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: activeTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
            ]
        )
        let store = BrowserStateStoreHarness(states: [state])

        let changes = try store.mutate(.activateTab(spaceId: spaceId, tabId: pinnedTabId))

        let updatedState = try XCTUnwrap(changes.changedState)
        XCTAssertEqual(updatedState.state.activeTabId, pinnedTabId)
        XCTAssertEqual(changes.changedState?.state.activeTabId, pinnedTabId)
        XCTAssertEqual(updatedState.tabsById[pinnedTabId]?.isClosed, false)
        XCTAssertEqual(updatedState.sidebar.rootNodeIds(in: .pinned), [pinnedTabId])
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStoreActivateClosedBookmarkedTabReopensAndActivatesIt() throws {
        let spaceId = UUID()
        let activeTabId = UUID()
        let bookmarkedTabId = UUID()
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: activeTabId,
            tabs: [
                Tab(id: activeTabId, url: URL(string: "https://active.example"), title: "Active", spaceId: spaceId),
                Tab(id: bookmarkedTabId, url: URL(string: "https://bookmark.example"), title: "Bookmark", isBookmarked: true, isClosed: true, spaceId: spaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: bookmarkedTabId, parentFolderId: nil, section: .bookmarked, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: activeTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
            ]
        )
        let store = BrowserStateStoreHarness(states: [state])

        let changes = try store.mutate(.activateTab(spaceId: spaceId, tabId: bookmarkedTabId))

        let updatedState = try XCTUnwrap(changes.changedState)
        XCTAssertEqual(updatedState.state.activeTabId, bookmarkedTabId)
        XCTAssertEqual(changes.changedState?.state.activeTabId, bookmarkedTabId)
        XCTAssertEqual(updatedState.tabsById[bookmarkedTabId]?.isClosed, false)
        XCTAssertEqual(updatedState.sidebar.rootNodeIds(in: .bookmarked), [bookmarkedTabId])
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStoreCreateTabAddsItToStateSidebarAndMakesItActive() throws {
        let spaceId = UUID()
        let existingTabId = UUID()
        let newTabId = UUID()
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: existingTabId,
            tabs: [
                Tab(id: existingTabId, url: URL(string: "https://existing.example"), title: "Existing", spaceId: spaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: existingTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
            ]
        )
        let store = BrowserStateStoreHarness(states: [state])
        let newTab = Tab(id: newTabId, url: URL(string: "https://new.example"), title: "New", spaceId: spaceId)

        let changes = try store.mutate(.createTab(spaceId: spaceId, tab: newTab, activate: true))

        let updatedState = try XCTUnwrap(changes.changedState)
        XCTAssertEqual(updatedState.state.activeTabId, newTabId)
        XCTAssertEqual(updatedState.tabsById[newTabId]?.title, "New")
        XCTAssertEqual(updatedState.sidebar.rootNodeIds(in: .unpinned), [existingTabId, newTabId])
        XCTAssertEqual(changes.changedState?.state.activeTabId, newTabId)
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStoreCreateBackgroundTabKeepsExistingActiveTab() throws {
        let spaceId = UUID()
        let existingTabId = UUID()
        let newTabId = UUID()
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: existingTabId,
            tabs: [
                Tab(id: existingTabId, url: URL(string: "https://existing.example"), title: "Existing", spaceId: spaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: existingTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
            ]
        )
        let store = BrowserStateStoreHarness(states: [state])
        let newTab = Tab(id: newTabId, url: URL(string: "https://new.example"), title: "New", spaceId: spaceId)

        let changes = try store.mutate(.createTab(spaceId: spaceId, tab: newTab, activate: false))

        let updatedState = try XCTUnwrap(changes.changedState)
        XCTAssertEqual(updatedState.state.activeTabId, existingTabId)
        XCTAssertEqual(updatedState.tabsById[newTabId]?.title, "New")
        XCTAssertEqual(updatedState.sidebar.rootNodeIds(in: .unpinned), [existingTabId, newTabId])
        XCTAssertEqual(changes.changedState?.state.activeTabId, existingTabId)
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStoreCloseTabRemovesInactiveUnpinnedTabFromStateAndSidebar() throws {
        let spaceId = UUID()
        let activeTabId = UUID()
        let closingTabId = UUID()
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: activeTabId,
            tabs: [
                Tab(id: activeTabId, url: URL(string: "https://active.example"), title: "Active", spaceId: spaceId),
                Tab(id: closingTabId, url: URL(string: "https://closing.example"), title: "Closing", spaceId: spaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: activeTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: closingTabId, parentFolderId: nil, section: .unpinned, sortOrder: 1)
            ]
        )
        let store = BrowserStateStoreHarness(states: [state])

        let changes = try store.mutate(.closeTab(spaceId: spaceId, tabId: closingTabId))

        let updatedState = try XCTUnwrap(store.state(spaceId: spaceId))
        XCTAssertNil(updatedState.tabsById[closingTabId])
        XCTAssertNil(updatedState.sidebar.node(id: closingTabId))
        XCTAssertEqual(updatedState.activeTabId, activeTabId)
        XCTAssertEqual(changes.changedState?.state.activeTabId, activeTabId)
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStoreClosingLoadingPinnedTabDropsItsRuntimeState() throws {
        let spaceId = UUID()
        let tabId = UUID()
        var tab = Tab(id: tabId, url: URL(string: "https://pinned.example"), title: "Pinned", isPinned: true, spaceId: spaceId)
        let store = BrowserStateStore()
        store.storeSpace(
            id: spaceId,
            snapshot: makeSpaceSnapshot(
                tabs: [tab],
                folders: [],
                treeItems: [
                    TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .pinned, sortOrder: 0)
                ],
                engines: [:],
                activeTabId: tabId,
                spaceId: spaceId
            )
        )
        tab.isLoading = true
        store.runtimeOverlay.setRuntimeState(from: tab)
        XCTAssertEqual(store.browserSpaceChange(spaceId: spaceId)?.tabsById[tabId]?.isLoading, true)

        let changes = try store.mutate(.closeTab(spaceId: spaceId, tabId: tabId))

        // A pinned tab survives its own close as a closed row, and a closed tab holds no engine, so it
        // cannot still be loading. The close must ship a runtime-clean tab, or the row the UI keeps
        // rendering stays stuck on the loading spinner forever (nothing patches it afterwards).
        let closedTab = try XCTUnwrap(changes.changedState?.tabsById[tabId])
        XCTAssertTrue(closedTab.isClosed)
        XCTAssertFalse(closedTab.isLoading)
        XCTAssertEqual(store.browserSpaceChange(spaceId: spaceId)?.tabsById[tabId]?.isLoading, false)
    }

    func testBrowserStateStoreClosingLastActiveTabClearsActiveTab() throws {
        let spaceId = UUID()
        let activeTabId = UUID()
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: activeTabId,
            tabs: [
                Tab(id: activeTabId, url: URL(string: "https://active.example"), title: "Active", spaceId: spaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: activeTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
            ]
        )
        let store = BrowserStateStoreHarness(states: [state])

        let changes = try store.mutate(.closeTab(spaceId: spaceId, tabId: activeTabId))

        let updatedState = try XCTUnwrap(changes.changedState)
        XCTAssertNil(updatedState.state.activeTabId)
        XCTAssertNil(changes.changedState?.state.activeTabId)
        XCTAssertNil(updatedState.tabsById[activeTabId])
        XCTAssertNil(updatedState.sidebar.node(id: activeTabId))
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStoreClosingActiveTabSelectsNextOpenTab() throws {
        let spaceId = UUID()
        let activeTabId = UUID()
        let nextTabId = UUID()
        let laterTabId = UUID()
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: activeTabId,
            tabs: [
                Tab(id: activeTabId, url: URL(string: "https://active.example"), title: "Active", spaceId: spaceId),
                Tab(id: nextTabId, url: URL(string: "https://next.example"), title: "Next", spaceId: spaceId),
                Tab(id: laterTabId, url: URL(string: "https://later.example"), title: "Later", spaceId: spaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: activeTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: nextTabId, parentFolderId: nil, section: .unpinned, sortOrder: 1),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: laterTabId, parentFolderId: nil, section: .unpinned, sortOrder: 2)
            ]
        )
        let store = BrowserStateStoreHarness(states: [state])

        let changes = try store.mutate(.closeTab(spaceId: spaceId, tabId: activeTabId))

        let updatedState = try XCTUnwrap(changes.changedState)
        XCTAssertEqual(updatedState.state.activeTabId, nextTabId)
        XCTAssertNil(updatedState.tabsById[activeTabId])
        XCTAssertNotNil(updatedState.tabsById[nextTabId])
        XCTAssertNotNil(updatedState.tabsById[laterTabId])
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStoreClosingActiveTabUsesMostRecentActiveTabBeforeSidebarOrder() throws {
        let spaceId = UUID()
        let firstTabId = UUID()
        let recentTabId = UUID()
        let activeTabId = UUID()
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: activeTabId,
            tabs: [
                Tab(id: firstTabId, url: URL(string: "https://first.example"), title: "First", spaceId: spaceId),
                Tab(id: recentTabId, url: URL(string: "https://recent.example"), title: "Recent", spaceId: spaceId),
                Tab(id: activeTabId, url: URL(string: "https://active.example"), title: "Active", spaceId: spaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: firstTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: recentTabId, parentFolderId: nil, section: .unpinned, sortOrder: 1),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: activeTabId, parentFolderId: nil, section: .unpinned, sortOrder: 2)
            ],
            activationHistory: [recentTabId, firstTabId]
        )
        let store = BrowserStateStoreHarness(states: [state])

        let changes = try store.mutate(.closeTab(spaceId: spaceId, tabId: activeTabId))

        let updatedState = try XCTUnwrap(changes.changedState)
        XCTAssertEqual(updatedState.state.activeTabId, recentTabId)
        XCTAssertNil(updatedState.tabsById[activeTabId])
        XCTAssertEqual(updatedState.state.activationHistory, [firstTabId])
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStorePersistsActivationHistoryAcrossMutations() throws {
        let spaceId = UUID()
        let firstTabId = UUID()
        let secondTabId = UUID()
        let thirdTabId = UUID()
        let tabs = [
            Tab(id: firstTabId, url: URL(string: "https://first.example"), title: "First", spaceId: spaceId),
            Tab(id: secondTabId, url: URL(string: "https://second.example"), title: "Second", spaceId: spaceId),
            Tab(id: thirdTabId, url: URL(string: "https://third.example"), title: "Third", spaceId: spaceId)
        ]
        let treeItems = [
            TabTreeItem(spaceId: spaceId, kind: .tab, itemId: firstTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
            TabTreeItem(spaceId: spaceId, kind: .tab, itemId: secondTabId, parentFolderId: nil, section: .unpinned, sortOrder: 1),
            TabTreeItem(spaceId: spaceId, kind: .tab, itemId: thirdTabId, parentFolderId: nil, section: .unpinned, sortOrder: 2)
        ]
        let store = BrowserStateStore()
        store.storeActiveSpace(
            id: spaceId,
            snapshot: makeSpaceSnapshot(tabs: tabs,
                folders: [],
                treeItems: treeItems,
                engines: [:],
                activeTabId: firstTabId
            )
        )

        _ = try store.mutate(.activateTab(spaceId: spaceId, tabId: secondTabId))
        _ = try store.mutate(.activateTab(spaceId: spaceId, tabId: thirdTabId))

        let state = try XCTUnwrap(store.browserSpaceChange(spaceId: spaceId))
        XCTAssertEqual(state.state.activeTabId, thirdTabId)
        XCTAssertEqual(state.state.activationHistory, [secondTabId, firstTabId])
    }

    func testBrowserStateStoreBookmarkTabMovesItToBookmarkedSidebarAndKeepsPinExclusive() throws {
        let spaceId = UUID()
        let tabId = UUID()
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: tabId,
            tabs: [
                Tab(id: tabId, url: URL(string: "https://bookmark.example"), title: "Bookmark", isPinned: true, spaceId: spaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .pinned, sortOrder: 0)
            ]
        )
        let store = BrowserStateStoreHarness(states: [state])

        let changes = try store.mutate(.setBookmarked(spaceId: spaceId, tabId: tabId, isBookmarked: true))

        let updatedState = try XCTUnwrap(changes.changedState)
        XCTAssertTrue(updatedState.tabsById[tabId]?.isBookmarked == true)
        XCTAssertFalse(updatedState.tabsById[tabId]?.isPinned == true)
        XCTAssertEqual(updatedState.sidebar.node(id: tabId)?.section, .bookmarked)
        XCTAssertEqual(updatedState.sidebar.rootNodeIds(in: .bookmarked), [tabId])
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStoreMoveTabToBookmarkedUpdatesOrderAndHomeMetadata() throws {
        let spaceId = UUID()
        let firstBookmarkId = UUID()
        let movingTabId = UUID()
        let lastBookmarkId = UUID()
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: movingTabId,
            tabs: [
                Tab(id: firstBookmarkId, url: URL(string: "https://first.example"), title: "First", isBookmarked: true, spaceId: spaceId),
                Tab(id: movingTabId, url: URL(string: "https://moving.example"), title: "Moving", isPinned: true, spaceId: spaceId),
                Tab(id: lastBookmarkId, url: URL(string: "https://last.example"), title: "Last", isBookmarked: true, spaceId: spaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: firstBookmarkId, parentFolderId: nil, section: .bookmarked, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: lastBookmarkId, parentFolderId: nil, section: .bookmarked, sortOrder: 1),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: movingTabId, parentFolderId: nil, section: .pinned, sortOrder: 0)
            ]
        )
        let store = BrowserStateStoreHarness(states: [state])

        let changes = try store.mutate(.moveTabToBookmarked(spaceId: spaceId, tabId: movingTabId, insert: .index(1)))

        let updatedState = try XCTUnwrap(changes.changedState)
        let updatedTab = try XCTUnwrap(updatedState.tabsById[movingTabId])
        XCTAssertTrue(updatedTab.isBookmarked)
        XCTAssertFalse(updatedTab.isPinned)
        XCTAssertNil(updatedTab.groupId)
        XCTAssertEqual(updatedTab.homeURL, URL(string: "https://moving.example"))
        XCTAssertEqual(updatedTab.homeTitle, "Moving")
        XCTAssertEqual(updatedState.sidebar.node(id: movingTabId)?.section, .bookmarked)
        XCTAssertEqual(updatedState.sidebar.rootNodeIds(in: .bookmarked), [firstBookmarkId, movingTabId, lastBookmarkId])
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStoreMovesClosedPinnedTabToBookmarkedSection() throws {
        let spaceId = UUID()
        let tabId = UUID()
        let tabURL = URL(string: "https://pinned.example")!
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: nil,
            tabs: [
                Tab(id: tabId, url: tabURL, title: "Pinned", isPinned: true, isClosed: true, spaceId: spaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .pinned, sortOrder: 0)
            ]
        )
        let store = BrowserStateStoreHarness(states: [state])

        let changes = try store.mutate(.moveTabToBookmarked(spaceId: spaceId, tabId: tabId, insert: .index(0)))

        let updatedState = try XCTUnwrap(changes.changedState)
        let updatedTab = try XCTUnwrap(updatedState.tabsById[tabId])
        XCTAssertTrue(updatedTab.isBookmarked)
        XCTAssertFalse(updatedTab.isPinned)
        XCTAssertTrue(updatedTab.isClosed)
        XCTAssertEqual(updatedTab.homeURL, tabURL)
        XCTAssertEqual(updatedState.sidebar.rootNodeIds(in: .bookmarked), [tabId])
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStoreSetTabHomeURLUpdatesHomeMetadataOnly() throws {
        let spaceId = UUID()
        let tabId = UUID()
        let tabURL = URL(string: "https://current.example")!
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: tabId,
            tabs: [
                Tab(
                    id: tabId,
                    url: tabURL,
                    title: "Current",
                    isPinned: true,
                    spaceId: spaceId,
                )
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .pinned, sortOrder: 0)
            ]
        )
        let store = BrowserStateStoreHarness(states: [state])

        let changes = try store.mutate(.setTabHomeURL(spaceId: spaceId, tabId: tabId, url: tabURL))

        let updatedState = try XCTUnwrap(changes.changedState)
        let updatedTab = try XCTUnwrap(updatedState.tabsById[tabId])
        XCTAssertEqual(updatedTab.homeURL, tabURL)
        XCTAssertEqual(updatedTab.homeTitle, "Current")
        XCTAssertEqual(updatedState.sidebar.rootNodeIds(in: .pinned), [tabId])
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStorePinTabClearsBookmarkAndAddsItToPinnedSidebar() throws {
        let spaceId = UUID()
        let tabId = UUID()
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: tabId,
            tabs: [
                Tab(id: tabId, url: URL(string: "https://pin.example"), title: "Pin", isBookmarked: true, spaceId: spaceId)
            ],
            folders: [],
            treeItems: []
        )
        let store = BrowserStateStoreHarness(states: [state])

        let changes = try store.mutate(.setPinned(spaceId: spaceId, tabId: tabId, isPinned: true))

        let updatedState = try XCTUnwrap(changes.changedState)
        XCTAssertTrue(updatedState.tabsById[tabId]?.isPinned == true)
        XCTAssertFalse(updatedState.tabsById[tabId]?.isBookmarked == true)
        XCTAssertEqual(updatedState.sidebar.rootNodeIds(in: .pinned), [tabId])
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStoreUnbookmarkClosedBookmarkRemovesItFromSidebarState() throws {
        let spaceId = UUID()
        let tabId = UUID()
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: nil,
            tabs: [
                Tab(id: tabId, url: URL(string: "https://bookmark.example"), title: "Bookmark", isBookmarked: true, isClosed: true, spaceId: spaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .bookmarked, sortOrder: 0)
            ]
        )
        let store = BrowserStateStoreHarness(states: [state])

        let changes = try store.mutate(.setBookmarked(spaceId: spaceId, tabId: tabId, isBookmarked: false))

        let updatedState = try XCTUnwrap(changes.changedState)
        XCTAssertNil(updatedState.tabsById[tabId])
        XCTAssertNil(updatedState.sidebar.node(id: tabId))
        XCTAssertTrue(updatedState.sidebar.rootNodeIds(in: .bookmarked).isEmpty)
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStoreUnpinClosedPinnedTabRemovesItFromSidebarState() throws {
        let spaceId = UUID()
        let tabId = UUID()
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: nil,
            tabs: [
                Tab(id: tabId, url: URL(string: "https://pinned.example"), title: "Pinned", isPinned: true, isClosed: true, spaceId: spaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .pinned, sortOrder: 0)
            ]
        )
        let store = BrowserStateStoreHarness(states: [state])

        let changes = try store.mutate(.setPinned(spaceId: spaceId, tabId: tabId, isPinned: false))

        let updatedState = try XCTUnwrap(changes.changedState)
        XCTAssertNil(updatedState.tabsById[tabId])
        XCTAssertNil(updatedState.sidebar.node(id: tabId))
        XCTAssertTrue(updatedState.sidebar.rootNodeIds(in: .pinned).isEmpty)
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStoreCreateFolderAddsRootNodeInRequestedSection() throws {
        let spaceId = UUID()
        let folderId = UUID()
        let state = try BrowserStateFixture(spaceId: spaceId, activeTabId: nil, tabs: [], folders: [], treeItems: [])
        let store = BrowserStateStoreHarness(states: [state])
        let folder = TabFolder(id: folderId, spaceId: spaceId, name: "Work", color: "#123456")

        let changes = try store.mutate(.createFolder(spaceId: spaceId, folder: folder, section: .pinned))

        let updatedState = try XCTUnwrap(changes.changedState)
        XCTAssertEqual(updatedState.foldersById[folderId]?.name, "Work")
        XCTAssertEqual(updatedState.sidebar.rootNodeIds(in: .pinned), [folderId])
        XCTAssertEqual(updatedState.sidebar.node(id: folderId)?.kind, .folder)
        XCTAssertTrue(updatedState.invariantsHold())
    }

    /// `chain` folders nested each in the previous one (the first at the root), then `roots` root folders.
    private func nestedFolderStore(chain: Int, roots: Int = 0, tabInFirst: UUID? = nil) throws -> (
        store: BrowserStateStoreHarness, spaceId: UUID, chain: [UUID], roots: [UUID]
    ) {
        let spaceId = UUID()
        let chainIds = (0..<chain).map { _ in UUID() }
        let rootIds = (0..<roots).map { _ in UUID() }
        var items: [TabTreeItem] = []
        for (depth, id) in chainIds.enumerated() {
            items.append(TabTreeItem(
                spaceId: spaceId, kind: .folder, itemId: id, parentFolderId: depth == 0 ? nil : chainIds[depth - 1],
                section: .unpinned, sortOrder: depth == 0 ? 0 : 1
            ))
        }
        for (offset, id) in rootIds.enumerated() {
            items.append(TabTreeItem(spaceId: spaceId, kind: .folder, itemId: id, parentFolderId: nil, section: .unpinned, sortOrder: offset + 1))
        }
        var tabs: [Tab] = []
        if let tabInFirst, let first = chainIds.first {
            tabs.append(Tab(id: tabInFirst, url: URL(string: "https://child.example"), groupId: first, spaceId: spaceId))
            items.append(TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabInFirst, parentFolderId: first, section: .unpinned, sortOrder: 0))
        }
        let folders = (chainIds + rootIds).map { TabFolder(id: $0, spaceId: spaceId) }
        let state = try BrowserStateFixture(spaceId: spaceId, activeTabId: nil, tabs: tabs, folders: folders, treeItems: items)
        return (BrowserStateStoreHarness(states: [state]), spaceId, chainIds, rootIds)
    }

    private func moveFolder(_ id: UUID, into parentId: UUID?, spaceId: UUID, before: UUID? = nil, after: UUID? = nil) -> BrowserCommand {
        .moveSidebarItem(
            spaceId: spaceId, kind: .folder, itemId: id, parentFolderId: parentId, section: .unpinned,
            insert: .anchored(fallbackIndex: .max, insertBeforeId: before, insertAfterId: after)
        )
    }

    func testMoveSidebarItemNestsReordersAndUnnestsAFolder() throws {
        let tabId = UUID()
        let (store, spaceId, chain, roots) = try nestedFolderStore(chain: 1, roots: 1, tabInFirst: tabId)
        let outer = chain[0], moved = roots[0]

        _ = try store.mutate(moveFolder(moved, into: outer, spaceId: spaceId, before: tabId))
        var state = try XCTUnwrap(store.state(spaceId: spaceId))
        XCTAssertEqual(state.sidebar.childNodeIds(of: outer), [moved, tabId])
        XCTAssertEqual(state.sidebar.rootNodeIds(in: .unpinned), [outer])

        _ = try store.mutate(moveFolder(moved, into: outer, spaceId: spaceId, after: tabId))
        state = try XCTUnwrap(store.state(spaceId: spaceId))
        XCTAssertEqual(state.sidebar.childNodeIds(of: outer), [tabId, moved])

        _ = try store.mutate(moveFolder(moved, into: nil, spaceId: spaceId, before: outer))
        state = try XCTUnwrap(store.state(spaceId: spaceId))
        XCTAssertEqual(state.sidebar.rootNodeIds(in: .unpinned), [moved, outer])
        XCTAssertEqual(state.sidebar.childNodeIds(of: outer), [tabId])
        XCTAssertTrue(state.invariantsHold())
    }

    func testMoveSidebarItemRefusesAFolderIntoItselfOrItsDescendants() throws {
        let (store, spaceId, chain, _) = try nestedFolderStore(chain: 3)

        _ = try store.mutate(moveFolder(chain[0], into: chain[0], spaceId: spaceId))
        _ = try store.mutate(moveFolder(chain[0], into: chain[2], spaceId: spaceId))
        _ = try store.mutate(moveFolder(chain[1], into: chain[2], spaceId: spaceId))

        let state = try XCTUnwrap(store.state(spaceId: spaceId))
        XCTAssertEqual(state.sidebar.rootNodeIds(in: .unpinned), [chain[0]])
        XCTAssertEqual(state.sidebar.childNodeIds(of: chain[0]), [chain[1]])
        XCTAssertEqual(state.sidebar.childNodeIds(of: chain[1]), [chain[2]])
        XCTAssertEqual(state.sidebar.childNodeIds(of: chain[2]), [])
    }

    func testMoveSidebarItemKeepsFoldersAtMostFiveDeep() throws {
        let (store, spaceId, chain, roots) = try nestedFolderStore(chain: 5, roots: 2)
        let single = roots[0], pair = roots[1]
        _ = try store.mutate(moveFolder(single, into: pair, spaceId: spaceId))

        // `pair` is two folders deep: under the fourth level it would reach a sixth.
        _ = try store.mutate(moveFolder(pair, into: chain[3], spaceId: spaceId))
        var state = try XCTUnwrap(store.state(spaceId: spaceId))
        XCTAssertNil(state.sidebar.node(id: pair)?.parentFolderId)

        _ = try store.mutate(moveFolder(pair, into: chain[2], spaceId: spaceId))
        state = try XCTUnwrap(store.state(spaceId: spaceId))
        XCTAssertEqual(state.sidebar.node(id: pair)?.parentFolderId, chain[2])
        XCTAssertEqual(state.sidebar.node(id: single)?.parentFolderId, pair)

        _ = try store.mutate(moveFolder(single, into: chain[4], spaceId: spaceId))
        state = try XCTUnwrap(store.state(spaceId: spaceId))
        XCTAssertEqual(state.sidebar.node(id: single)?.parentFolderId, pair)
    }

    func testMoveSidebarItemKeepsASplitViewAtTheRoot() throws {
        let spaceId = UUID()
        let folderId = UUID()
        let splitId = UUID()
        let left = Tab(url: URL(string: "https://left.example"), groupId: splitId, spaceId: spaceId)
        let right = Tab(url: URL(string: "https://right.example"), groupId: splitId, spaceId: spaceId)
        let layout = SplitLayout.split(vertical: false, ratio: 0.5, first: .pane(tabId: left.id), second: .pane(tabId: right.id))
        let store = BrowserStateStoreHarness(states: [try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: nil,
            tabs: [left, right],
            folders: [TabFolder(id: folderId, spaceId: spaceId), TabFolder(id: splitId, spaceId: spaceId, splitLayout: layout)],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folderId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .folder, itemId: splitId, parentFolderId: nil, section: .unpinned, sortOrder: 1),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: left.id, parentFolderId: splitId, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: right.id, parentFolderId: splitId, section: .unpinned, sortOrder: 1)
            ]
        )])

        _ = try store.mutate(moveFolder(splitId, into: folderId, spaceId: spaceId))
        _ = try store.mutate(.createFolder(spaceId: spaceId, folder: TabFolder(spaceId: spaceId), section: .unpinned, parentFolderId: splitId))

        let state = try XCTUnwrap(store.state(spaceId: spaceId))
        XCTAssertEqual(state.sidebar.rootNodeIds(in: .unpinned), [folderId, splitId])
        XCTAssertEqual(state.sidebar.childNodeIds(of: splitId), [left.id, right.id])
    }

    func testCreateFolderInsideAFolderLandsFirstInItsSectionUpToFiveDeep() throws {
        let tabId = UUID()
        let (store, spaceId, chain, _) = try nestedFolderStore(chain: 5, tabInFirst: tabId)
        let subfolder = TabFolder(spaceId: spaceId, name: "Sub")

        // The requested section yields to the parent's.
        _ = try store.mutate(.createFolder(spaceId: spaceId, folder: subfolder, section: .pinned, parentFolderId: chain[0]))
        var state = try XCTUnwrap(store.state(spaceId: spaceId))
        XCTAssertEqual(state.sidebar.childNodeIds(of: chain[0]), [subfolder.id, tabId, chain[1]])
        XCTAssertEqual(state.sidebar.node(id: subfolder.id)?.section, .unpinned)

        let tooDeep = TabFolder(spaceId: spaceId)
        _ = try store.mutate(.createFolder(spaceId: spaceId, folder: tooDeep, section: .unpinned, parentFolderId: chain[4]))
        let missingParent = TabFolder(spaceId: spaceId)
        _ = try store.mutate(.createFolder(spaceId: spaceId, folder: missingParent, section: .unpinned, parentFolderId: UUID()))
        state = try XCTUnwrap(store.state(spaceId: spaceId))
        XCTAssertNil(state.foldersById[tooDeep.id])
        XCTAssertNil(state.foldersById[missingParent.id])
        XCTAssertTrue(state.invariantsHold())
    }

    func testBrowserStateStoreUpdateFolderMetadataPreservesChildren() throws {
        let spaceId = UUID()
        let folderId = UUID()
        let childTabId = UUID()
        let folder = TabFolder(id: folderId, spaceId: spaceId, name: "Old", color: "#111111")
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: childTabId,
            tabs: [
                Tab(id: childTabId, url: URL(string: "https://child.example"), title: "Child", isPinned: true, groupId: folderId, spaceId: spaceId)
            ],
            folders: [folder],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folderId, parentFolderId: nil, section: .pinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: childTabId, parentFolderId: folderId, section: .pinned, sortOrder: 0)
            ]
        )
        let store = BrowserStateStoreHarness(states: [state])

        let changes = try store.mutate(.updateFolder(spaceId: spaceId, folderId: folderId, name: "New", color: "#222222", isCollapsed: true))

        let updatedState = try XCTUnwrap(changes.changedState)
        XCTAssertEqual(updatedState.foldersById[folderId]?.name, "New")
        XCTAssertEqual(updatedState.foldersById[folderId]?.color, "#222222")
        XCTAssertEqual(updatedState.foldersById[folderId]?.isCollapsed, true)
        XCTAssertEqual(updatedState.sidebar.childNodeIds(of: folderId), [childTabId])
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStoreDeleteFolderPromotesChildrenToSectionRoot() throws {
        let spaceId = UUID()
        let folderId = UUID()
        let childTabId = UUID()
        let folder = TabFolder(id: folderId, spaceId: spaceId, name: "Folder", color: "#111111")
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: childTabId,
            tabs: [
                Tab(id: childTabId, url: URL(string: "https://child.example"), title: "Child", groupId: folderId, spaceId: spaceId)
            ],
            folders: [folder],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folderId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: childTabId, parentFolderId: folderId, section: .unpinned, sortOrder: 0)
            ]
        )
        let store = BrowserStateStoreHarness(states: [state])

        let changes = try store.mutate(.deleteFolder(spaceId: spaceId, folderId: folderId))

        let updatedState = try XCTUnwrap(changes.changedState)
        XCTAssertNil(updatedState.foldersById[folderId])
        XCTAssertNil(updatedState.sidebar.node(id: folderId))
        XCTAssertNil(updatedState.tabsById[childTabId]?.groupId)
        XCTAssertEqual(updatedState.sidebar.rootNodeIds(in: .unpinned), [childTabId])
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStoreMoveTabToSpaceUpdatesBothStates() throws {
        let sourceSpaceId = UUID()
        let targetSpaceId = UUID()
        let sourceActiveTabId = UUID()
        let movingTabId = UUID()
        let sourceState = try BrowserStateFixture(
            spaceId: sourceSpaceId,
            activeTabId: sourceActiveTabId,
            tabs: [
                Tab(id: sourceActiveTabId, url: URL(string: "https://active.example"), title: "Active", spaceId: sourceSpaceId),
                Tab(id: movingTabId, url: URL(string: "https://moving.example"), title: "Moving", spaceId: sourceSpaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: sourceSpaceId, kind: .tab, itemId: sourceActiveTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: sourceSpaceId, kind: .tab, itemId: movingTabId, parentFolderId: nil, section: .unpinned, sortOrder: 1)
            ]
        )
        let targetState = try BrowserStateFixture(
            spaceId: targetSpaceId,
            activeTabId: nil,
            tabs: [],
            folders: [],
            treeItems: []
        )
        let store = BrowserStateStoreHarness(states: [sourceState, targetState])

        let changes = try store.mutate(.moveTabToSpace(
            tabId: movingTabId,
            sourceSpaceId: sourceSpaceId,
            targetSpaceId: targetSpaceId,
            allowsPinnedTabs: true
        ))

        let updatedSource = try XCTUnwrap(store.state(spaceId: sourceSpaceId))
        let updatedTarget = try XCTUnwrap(store.state(spaceId: targetSpaceId))
        XCTAssertNil(updatedSource.tabsById[movingTabId])
        XCTAssertNil(updatedSource.sidebar.node(id: movingTabId))
        XCTAssertEqual(updatedSource.activeTabId, sourceActiveTabId)
        XCTAssertEqual(updatedTarget.tabsById[movingTabId]?.spaceId, targetSpaceId)
        XCTAssertEqual(updatedTarget.activeTabId, movingTabId)
        XCTAssertEqual(updatedTarget.sidebar.rootNodeIds(in: .unpinned), [movingTabId])
        XCTAssertEqual(Set(changes.states.map(\.spaceId)), [sourceSpaceId, targetSpaceId])
        XCTAssertTrue(updatedSource.invariantsHold())
        XCTAssertTrue(updatedTarget.invariantsHold())
    }

    func testBrowserStateStoreMoveActiveTabToSpaceSelectsNextSourceTabBySidebarOrder() throws {
        let sourceSpaceId = UUID()
        let targetSpaceId = UUID()
        let movingTabId = UUID()
        let nextTabId = UUID()
        let lastTabId = UUID()
        let sourceState = try BrowserStateFixture(
            spaceId: sourceSpaceId,
            activeTabId: movingTabId,
            tabs: [
                Tab(id: movingTabId, url: URL(string: "https://moving.example"), title: "Moving", spaceId: sourceSpaceId),
                Tab(id: nextTabId, url: URL(string: "https://next.example"), title: "Next", spaceId: sourceSpaceId),
                Tab(id: lastTabId, url: URL(string: "https://last.example"), title: "Last", spaceId: sourceSpaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: sourceSpaceId, kind: .tab, itemId: movingTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: sourceSpaceId, kind: .tab, itemId: nextTabId, parentFolderId: nil, section: .unpinned, sortOrder: 1),
                TabTreeItem(spaceId: sourceSpaceId, kind: .tab, itemId: lastTabId, parentFolderId: nil, section: .unpinned, sortOrder: 2)
            ]
        )
        let targetState = try BrowserStateFixture(spaceId: targetSpaceId, activeTabId: nil, tabs: [], folders: [], treeItems: [])
        let store = BrowserStateStoreHarness(states: [sourceState, targetState])

        _ = try store.mutate(.moveTabToSpace(
            tabId: movingTabId,
            sourceSpaceId: sourceSpaceId,
            targetSpaceId: targetSpaceId,
            allowsPinnedTabs: true
        ))

        let updatedSource = try XCTUnwrap(store.state(spaceId: sourceSpaceId))
        let updatedTarget = try XCTUnwrap(store.state(spaceId: targetSpaceId))
        XCTAssertEqual(updatedSource.activeTabId, nextTabId)
        XCTAssertTrue(updatedSource.invariantsHold())
        XCTAssertTrue(updatedTarget.invariantsHold())
    }

    func testBrowserStateStoreMovePinnedTabToSpaceCanClearPinnedForPrivateTargets() throws {
        let sourceSpaceId = UUID()
        let targetSpaceId = UUID()
        let activeTabId = UUID()
        let movingTabId = UUID()
        let targetTabId = UUID()
        let sourceState = try BrowserStateFixture(
            spaceId: sourceSpaceId,
            activeTabId: activeTabId,
            tabs: [
                Tab(id: activeTabId, url: URL(string: "https://active.example"), title: "Active", spaceId: sourceSpaceId),
                Tab(id: movingTabId, url: URL(string: "https://moving.example"), title: "Moving", isPinned: true, spaceId: sourceSpaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: sourceSpaceId, kind: .tab, itemId: activeTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: sourceSpaceId, kind: .tab, itemId: movingTabId, parentFolderId: nil, section: .pinned, sortOrder: 0)
            ]
        )
        let targetState = try BrowserStateFixture(
            spaceId: targetSpaceId,
            activeTabId: targetTabId,
            tabs: [
                Tab(id: targetTabId, url: URL(string: "https://target.example"), title: "Target", spaceId: targetSpaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: targetSpaceId, kind: .tab, itemId: targetTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
            ]
        )
        let store = BrowserStateStoreHarness(states: [sourceState, targetState])

        _ = try store.mutate(.moveTabToSpace(
            tabId: movingTabId,
            sourceSpaceId: sourceSpaceId,
            targetSpaceId: targetSpaceId,
            allowsPinnedTabs: false
        ))

        let updatedTarget = try XCTUnwrap(store.state(spaceId: targetSpaceId))
        XCTAssertFalse(updatedTarget.tabsById[movingTabId]?.isPinned == true)
        XCTAssertEqual(updatedTarget.sidebar.rootNodeIds(in: .pinned), [])
        XCTAssertEqual(updatedTarget.sidebar.rootNodeIds(in: .unpinned), [targetTabId, movingTabId])
        XCTAssertTrue(updatedTarget.invariantsHold())
    }

    func testBrowserChangePresenterBuildsSingleAtomicBridgeEvent() throws {
        let sourceSpaceId = UUID()
        let targetSpaceId = UUID()
        let sourceActiveTabId = UUID()
        let movingTabId = UUID()
        let sourceState = try BrowserStateFixture(
            spaceId: sourceSpaceId,
            activeTabId: sourceActiveTabId,
            tabs: [
                Tab(id: sourceActiveTabId, url: URL(string: "https://active.example"), title: "Active", spaceId: sourceSpaceId),
                Tab(id: movingTabId, url: URL(string: "https://moving.example"), title: "Moving", spaceId: sourceSpaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: sourceSpaceId, kind: .tab, itemId: sourceActiveTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: sourceSpaceId, kind: .tab, itemId: movingTabId, parentFolderId: nil, section: .unpinned, sortOrder: 1)
            ]
        )
        let targetState = try BrowserStateFixture(spaceId: targetSpaceId, activeTabId: nil, tabs: [], folders: [], treeItems: [])
        let store = BrowserStateStoreHarness(states: [sourceState, targetState])
        let changes = try store.mutate(.moveTabToSpace(
            tabId: movingTabId,
            sourceSpaceId: sourceSpaceId,
            targetSpaceId: targetSpaceId,
            allowsPinnedTabs: true
        ))

        let event = try XCTUnwrap(BrowserChangePresenter.event(for: changes))

        XCTAssertEqual(event.name, "browserStateChanged")
        XCTAssertEqual(event.data["changedSpaceId"] as? String, targetSpaceId.uuidString)
        let states = try XCTUnwrap(event.data["states"] as? [[String: Any]])
        XCTAssertEqual(Set(states.compactMap { $0["spaceId"] as? String }), [sourceSpaceId.uuidString, targetSpaceId.uuidString])
        let targetPayload = try XCTUnwrap(states.first { ($0["spaceId"] as? String) == targetSpaceId.uuidString })
        XCTAssertEqual(targetPayload["activeTabId"] as? String, movingTabId.uuidString)
        let treeItems = try XCTUnwrap(targetPayload["treeItems"] as? [[String: Any]])
        XCTAssertEqual(treeItems.compactMap { $0["itemId"] as? String }, [movingTabId.uuidString])
    }

    func testBrowserChangePresenterBuildsActiveTabChangedDeltaForActivation() throws {
        let spaceId = UUID()
        let firstTabId = UUID()
        let secondTabId = UUID()
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: firstTabId,
            tabs: [
                Tab(id: firstTabId, url: URL(string: "https://first.example"), title: "First", spaceId: spaceId),
                Tab(id: secondTabId, url: URL(string: "https://second.example"), title: "Second", spaceId: spaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: firstTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: secondTabId, parentFolderId: nil, section: .unpinned, sortOrder: 1)
            ]
        )
        let store = BrowserStateStoreHarness(states: [state])

        let changes = try store.mutate(.activateTab(spaceId: spaceId, tabId: secondTabId))
        let event = try XCTUnwrap(BrowserChangePresenter.event(for: changes))

        XCTAssertEqual(event.name, "browserStatePatch")
        XCTAssertEqual(event.data["changedSpaceId"] as? String, spaceId.uuidString)
        let operations = try XCTUnwrap(event.data["operations"] as? [[String: Any]])
        XCTAssertEqual(operations.count, 1)
        XCTAssertEqual(operations.first?["kind"] as? String, "sidebarChanged")
        XCTAssertEqual(operations.first?["spaceId"] as? String, spaceId.uuidString)
        XCTAssertEqual(operations.first?["activeTabId"] as? String, secondTabId.uuidString)
        XCTAssertNil(operations.first?["upsertTabs"], "plain activation must not re-ship snapshots")
        XCTAssertNil(event.data["states"])
    }

    func testBrowserChangePresenterBuildsFolderUpdatedDeltaForFolderFieldMutation() throws {
        let spaceId = UUID()
        let folderId = UUID()
        let folder = TabFolder(id: folderId, spaceId: spaceId, name: "Folder", color: "#111111", isCollapsed: false)
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: nil,
            tabs: [],
            folders: [folder],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folderId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
            ]
        )
        let store = BrowserStateStoreHarness(states: [state])

        let changes = try store.mutate(.setFolderCollapsed(spaceId: spaceId, folderId: folderId, isCollapsed: true))
        let event = try XCTUnwrap(BrowserChangePresenter.event(for: changes))

        XCTAssertEqual(event.name, "browserStatePatch")
        XCTAssertEqual(event.data["changedSpaceId"] as? String, spaceId.uuidString)
        let operations = try XCTUnwrap(event.data["operations"] as? [[String: Any]])
        XCTAssertEqual(operations.count, 1)
        XCTAssertEqual(operations.first?["kind"] as? String, "sidebarChanged")
        XCTAssertEqual(operations.first?["spaceId"] as? String, spaceId.uuidString)
        let upsertFolders = try XCTUnwrap(operations.first?["upsertFolders"] as? [[String: Any]])
        XCTAssertEqual(upsertFolders.compactMap { $0["id"] as? String }, [folderId.uuidString])
        XCTAssertEqual(upsertFolders.first?["isCollapsed"] as? Bool, true)
        XCTAssertNil(event.data["states"])
    }

    func testBrowserRuntimeCoordinatorSyncsRuntimeBeforeStructuralMutations() throws {
        let spaceId = UUID()
        let existingTabId = UUID()
        let newTabId = UUID()
        let existingTab = Tab(id: existingTabId, url: URL(string: "https://existing.example"), title: "Existing", spaceId: spaceId)
        let state = SpaceTabStateImporter.importState(
            activeTabId: existingTabId,
            activationHistory: [],
            tabs: [existingTab],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: existingTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
            ],
            spaceId: spaceId
        )
        let store = BrowserStateStore()
        store.storeSpace(
            id: spaceId,
            snapshot: BrowserStateStore.SpaceSnapshot(spaceTab: SpaceTab(spaceId: spaceId, state: state), engines: [:])
        )
        let tabManager = TabManager(engineFactory: WKEngineFactory())
        tabManager.currentSpaceId = spaceId
        tabManager.browserStateStore = store
        tabManager.applyDurableProjectionToRuntime(state, spaceId: spaceId)
        var syncCount = 0
        let coordinator = BrowserRuntimeCoordinator(
            tabManager: tabManager,
            browserStateStore: store,
            syncActiveBrowserState: { syncCount += 1 },
            emitBrowserChange: { _ in },
            scheduleSave: {}
        )

        let newTab = Tab(id: newTabId, url: URL(string: "https://new.example"), title: "New", spaceId: spaceId)
        let changes = try coordinator.apply(.createTab(spaceId: spaceId, tab: newTab, activate: true))

        XCTAssertEqual(syncCount, 1)
        XCTAssertEqual(changes.changedState?.tabsById[newTabId]?.title, "New")
    }

    func testBrowserChangePresenterOrdersTabsFromSidebarTreeItems() throws {
        let spaceId = UUID()
        let firstTabId = UUID()
        let secondTabId = UUID()
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: firstTabId,
            tabs: [
                Tab(id: secondTabId, url: URL(string: "https://second.example"), title: "Second", spaceId: spaceId),
                Tab(id: firstTabId, url: URL(string: "https://first.example"), title: "First", spaceId: spaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: firstTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: secondTabId, parentFolderId: nil, section: .unpinned, sortOrder: 1)
            ]
        )
        let spaceState = SpaceTabState(state)
        let event = try XCTUnwrap(BrowserChangePresenter.event(for: BrowserChangeSet(
            spaceId: spaceId,
            stateChanges: [BrowserSpaceChange(
                spaceId: spaceId,
                state: spaceState,
                projection: spaceState.projectedSidebar(spaceId: spaceId)
            )]
        )))

        let states = try XCTUnwrap(event.data["states"] as? [[String: Any]])
        let payload = try XCTUnwrap(states.first)
        let tabs = try XCTUnwrap(payload["tabs"] as? [[String: Any]])
        XCTAssertEqual(tabs.compactMap { $0["id"] as? String }, [firstTabId.uuidString, secondTabId.uuidString])
    }

    func testBrowserChangePresenterIncludesAudioStateInTabPayload() throws {
        let spaceId = UUID()
        let tabId = UUID()
        var tab = Tab(id: tabId, url: URL(string: "https://call.example"), title: "Call", spaceId: spaceId)
        tab.isAudioPlaying = true
        tab.isMuted = true
        tab.isMicrophoneActive = true
        tab.isMicrophoneMuted = true
        let treeItems = [
            TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
        ]
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: tabId,
            tabs: [tab],
            folders: [],
            treeItems: treeItems
        )
        let event = try XCTUnwrap(BrowserChangePresenter.event(for: BrowserChangeSet(
            spaceId: spaceId,
            stateChanges: [BrowserSpaceChange(
                spaceId: spaceId,
                state: SpaceTabState(state),
                projection: SpaceTabProjection(tabs: [tab], folders: [], treeItems: treeItems)
            )]
        )))

        let states = try XCTUnwrap(event.data["states"] as? [[String: Any]])
        let payload = try XCTUnwrap(states.first)
        let tabs = try XCTUnwrap(payload["tabs"] as? [[String: Any]])
        let tabPayload = try XCTUnwrap(tabs.first)
        XCTAssertEqual(tabPayload["isAudioPlaying"] as? Bool, true)
        XCTAssertEqual(tabPayload["isMuted"] as? Bool, true)
        XCTAssertEqual(tabPayload["isMicrophoneActive"] as? Bool, true)
        XCTAssertEqual(tabPayload["isMicrophoneMuted"] as? Bool, true)
    }

    func testBrowserChangePresenterBuildsSingleTabUpdatedBridgeEvent() throws {
        let spaceId = UUID()
        let tabId = UUID()
        var tab = Tab(id: tabId, url: URL(string: "https://progress.example"), title: "Progress", spaceId: spaceId)
        tab.estimatedProgress = 0.42
        tab.isLoading = true

        let event = BrowserChangePresenter.tabUpdatedEvent(tabPayload: tab.runtimePatchData, spaceId: spaceId, activeTabId: tabId)

        XCTAssertEqual(event.name, "browserStatePatch")
        XCTAssertEqual(event.data["changedSpaceId"] as? String, spaceId.uuidString)
        XCTAssertNil(event.data["tabId"])
        let operations = try XCTUnwrap(event.data["operations"] as? [[String: Any]])
        XCTAssertEqual(operations.count, 1)
        XCTAssertEqual(operations.first?["kind"] as? String, "tabUpdated")
        XCTAssertEqual(operations.first?["spaceId"] as? String, spaceId.uuidString)
        let tabPayload = try XCTUnwrap(operations.first?["tab"] as? [String: Any])
        XCTAssertEqual(tabPayload["id"] as? String, tabId.uuidString)
        XCTAssertEqual(tabPayload["progress"] as? Double, 0.42)
        XCTAssertNil(event.data["states"])
    }

    func testMoveTabToSpaceAppliesOnlySourceStateToCurrentRuntimeMirror() throws {
        let sourceSpaceId = UUID()
        let targetSpaceId = UUID()
        let activeTabId = UUID()
        let movingTabId = UUID()
        let targetTabId = UUID()
        let sourceState = try BrowserStateFixture(
            spaceId: sourceSpaceId,
            activeTabId: activeTabId,
            tabs: [
                Tab(id: activeTabId, url: URL(string: "https://active.example"), title: "Active", spaceId: sourceSpaceId),
                Tab(id: movingTabId, url: URL(string: "https://moving.example"), title: "Moving", spaceId: sourceSpaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: sourceSpaceId, kind: .tab, itemId: activeTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: sourceSpaceId, kind: .tab, itemId: movingTabId, parentFolderId: nil, section: .unpinned, sortOrder: 1)
            ]
        )
        let targetState = try BrowserStateFixture(
            spaceId: targetSpaceId,
            activeTabId: targetTabId,
            tabs: [
                Tab(id: targetTabId, url: URL(string: "https://target.example"), title: "Target", spaceId: targetSpaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: targetSpaceId, kind: .tab, itemId: targetTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
            ]
        )
        let store = BrowserStateStoreHarness(states: [sourceState, targetState])
        let tabManager = TabManager(engineFactory: WKEngineFactory())
        tabManager.currentSpaceId = sourceSpaceId
        tabManager.installSpaceTabStateForTests(SpaceTabState(sourceState), spaceId: sourceState.spaceId)

        let changes = try store.mutate(.moveTabToSpace(
            tabId: movingTabId,
            sourceSpaceId: sourceSpaceId,
            targetSpaceId: targetSpaceId,
            allowsPinnedTabs: true
        ))

        let updatedSource = try XCTUnwrap(changes.states.first { $0.spaceId == sourceSpaceId })
        tabManager.installSpaceTabStateForTests(updatedSource.state, spaceId: updatedSource.spaceId)

        XCTAssertEqual(tabManager.currentTabs.map(\.spaceId), [sourceSpaceId])
        XCTAssertEqual(tabManager.currentTabs.map(\.id), [activeTabId])
        XCTAssertFalse(tabManager.currentTabs.contains { $0.spaceId == targetSpaceId })
    }

    func testBrowserStateStoreMoveSidebarTabIntoFolderUpdatesStateOrder() throws {
        let spaceId = UUID()
        let rootTabId = UUID()
        let childTabId = UUID()
        let folderId = UUID()
        let folder = TabFolder(id: folderId, spaceId: spaceId, name: "Folder", color: "#111111")
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: rootTabId,
            tabs: [
                Tab(id: rootTabId, url: URL(string: "https://root.example"), title: "Root", spaceId: spaceId),
                Tab(id: childTabId, url: URL(string: "https://child.example"), title: "Child", spaceId: spaceId)
            ],
            folders: [folder],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: rootTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folderId, parentFolderId: nil, section: .unpinned, sortOrder: 1),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: childTabId, parentFolderId: nil, section: .unpinned, sortOrder: 2)
            ]
        )
        let store = BrowserStateStoreHarness(states: [state])

        let changes = try store.mutate(.moveSidebarItem(
            spaceId: spaceId,
            kind: .tab,
            itemId: childTabId,
            parentFolderId: folderId,
            section: .unpinned,
            insert: .index(0)
        ))

        let updatedState = try XCTUnwrap(changes.changedState)
        XCTAssertEqual(updatedState.tabsById[childTabId]?.groupId, folderId)
        XCTAssertEqual(updatedState.sidebar.rootNodeIds(in: .unpinned), [rootTabId, folderId])
        XCTAssertEqual(updatedState.sidebar.childNodeIds(of: folderId), [childTabId])
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStoreMovesClosedBookmarkToPinnedSection() throws {
        let spaceId = UUID()
        let tabId = UUID()
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: nil,
            tabs: [
                Tab(id: tabId, url: URL(string: "https://bookmark.example"), title: "Bookmark", isBookmarked: true, isClosed: true, spaceId: spaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .bookmarked, sortOrder: 0)
            ]
        )
        let store = BrowserStateStoreHarness(states: [state])

        let changes = try store.mutate(.moveSidebarItem(
            spaceId: spaceId,
            kind: .tab,
            itemId: tabId,
            parentFolderId: nil,
            section: .pinned,
            insert: .index(0)
        ))

        let updatedState = try XCTUnwrap(changes.changedState)
        let updatedTab = try XCTUnwrap(updatedState.tabsById[tabId])
        XCTAssertFalse(updatedTab.isBookmarked)
        XCTAssertTrue(updatedTab.isPinned)
        XCTAssertTrue(updatedTab.isClosed)
        XCTAssertEqual(updatedState.sidebar.rootNodeIds(in: .pinned), [tabId])
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStoreMovesClosedBookmarkToUnpinnedSectionByReopening() throws {
        let spaceId = UUID()
        let tabId = UUID()
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: nil,
            tabs: [
                Tab(id: tabId, url: URL(string: "https://bookmark.example"), title: "Bookmark", isBookmarked: true, isClosed: true, spaceId: spaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .bookmarked, sortOrder: 0)
            ]
        )
        let store = BrowserStateStoreHarness(states: [state])

        let changes = try store.mutate(.moveSidebarItem(
            spaceId: spaceId,
            kind: .tab,
            itemId: tabId,
            parentFolderId: nil,
            section: .unpinned,
            insert: .index(0)
        ))

        let updatedState = try XCTUnwrap(changes.changedState)
        let updatedTab = try XCTUnwrap(updatedState.tabsById[tabId])
        XCTAssertFalse(updatedTab.isBookmarked)
        XCTAssertFalse(updatedTab.isPinned)
        XCTAssertFalse(updatedTab.isClosed)
        XCTAssertEqual(updatedState.sidebar.rootNodeIds(in: .unpinned), [tabId])
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStoreMoveSidebarTabIntoPopulatedFolderUsesRequestedChildIndex() throws {
        let fixture = try SidebarStateFixture.folderWithTwoChildren()
        let store = BrowserStateStoreHarness(states: [fixture.state])

        let changes = try store.mutate(.moveSidebarItem(
            spaceId: fixture.spaceId,
            kind: .tab,
            itemId: fixture.movingTabId,
            parentFolderId: fixture.folderId,
            section: .unpinned,
            insert: .index(1)
        ))

        let updatedState = try XCTUnwrap(changes.changedState)
        XCTAssertEqual(updatedState.tabsById[fixture.movingTabId]?.groupId, fixture.folderId)
        XCTAssertEqual(updatedState.sidebar.rootNodeIds(in: .unpinned), [fixture.folderId])
        XCTAssertEqual(
            updatedState.sidebar.childNodeIds(of: fixture.folderId),
            [fixture.firstChildTabId, fixture.movingTabId, fixture.secondChildTabId]
        )
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStoreMoveSidebarItemResolvesFolderAnchorsAgainstTargetContainer() throws {
        let fixture = try SidebarStateFixture.folderWithTwoChildren()
        let store = BrowserStateStoreHarness(states: [fixture.state])

        let changes = try store.mutate(.moveSidebarItem(
            spaceId: fixture.spaceId,
            kind: .tab,
            itemId: fixture.movingTabId,
            parentFolderId: fixture.folderId,
            section: .unpinned,
            insert: .anchored(
                fallbackIndex: 99,
                insertBeforeId: fixture.secondChildTabId,
                insertAfterId: fixture.firstChildTabId
            )
        ))

        let updatedState = try XCTUnwrap(changes.changedState)
        XCTAssertEqual(
            updatedState.sidebar.childNodeIds(of: fixture.folderId),
            [fixture.firstChildTabId, fixture.movingTabId, fixture.secondChildTabId]
        )
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStoreUnchangedChangeSetReturnsSingleOriginalState() throws {
        let spaceId = UUID()
        let tabId = UUID()
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: tabId,
            tabs: [Tab(id: tabId, url: URL(string: "https://example.com"), title: "Tab", spaceId: spaceId)],
            folders: [],
            treeItems: [TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)]
        )

        let spaceState = SpaceTabState(state)
        let change = BrowserSpaceChange(
            spaceId: spaceId,
            state: spaceState,
            projection: spaceState.projectedSidebar(spaceId: spaceId)
        )
        let unchanged = BrowserChangeSet(spaceId: spaceId, stateChanges: [change])

        XCTAssertEqual(unchanged.spaceId, spaceId)
        XCTAssertEqual(unchanged.changedState?.state.activeTabId, tabId)
        XCTAssertEqual(unchanged.states.count, 1)
        XCTAssertEqual(unchanged.states.first?.spaceId, spaceId)
    }

    func testBrowserChangeSetChangedStateDoesNotFallbackToUnrelatedSpace() throws {
        let requestedSpaceId = UUID()
        let unrelatedSpaceId = UUID()
        let tabId = UUID()
        let state = try BrowserStateFixture(
            spaceId: unrelatedSpaceId,
            activeTabId: tabId,
            tabs: [Tab(id: tabId, url: URL(string: "https://unrelated.example"), title: "Tab", spaceId: unrelatedSpaceId)],
            folders: [],
            treeItems: [TabTreeItem(spaceId: unrelatedSpaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)]
        )

        let spaceState = SpaceTabState(state)
        let changes = BrowserChangeSet(
            spaceId: requestedSpaceId,
            stateChanges: [BrowserSpaceChange(
                spaceId: unrelatedSpaceId,
                state: spaceState,
                projection: spaceState.projectedSidebar(spaceId: unrelatedSpaceId)
            )]
        )

        XCTAssertNil(changes.changedState)
    }

    func testBrowserStateStoreGroupTabsCreatesFolderWithBothTabs() throws {
        let spaceId = UUID()
        let sourceTabId = UUID()
        let targetTabId = UUID()
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: sourceTabId,
            tabs: [
                Tab(id: sourceTabId, url: URL(string: "https://source.example"), title: "Source", spaceId: spaceId),
                Tab(id: targetTabId, url: URL(string: "https://target.example"), title: "Target", spaceId: spaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: sourceTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: targetTabId, parentFolderId: nil, section: .unpinned, sortOrder: 1)
            ]
        )
        let store = BrowserStateStoreHarness(states: [state])

        let changes = try store.mutate(.groupTabs(spaceId: spaceId, sourceTabId: sourceTabId, targetTabId: targetTabId))

        let updatedState = try XCTUnwrap(changes.changedState)
        let folder = try XCTUnwrap(updatedState.foldersById.values.first)
        XCTAssertEqual(folder.name, "New Folder")
        XCTAssertEqual(folder.color, "#5865f2")
        XCTAssertEqual(updatedState.sidebar.node(id: folder.id)?.section, .unpinned)
        XCTAssertEqual(updatedState.tabsById[sourceTabId]?.groupId, folder.id)
        XCTAssertEqual(updatedState.tabsById[targetTabId]?.groupId, folder.id)
        XCTAssertEqual(updatedState.sidebar.rootNodeIds(in: .unpinned), [folder.id])
        XCTAssertEqual(updatedState.sidebar.childNodeIds(of: folder.id), [sourceTabId, targetTabId])
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStoreMovesBookmarkToLastPosition() throws {
        let spaceId = UUID()
        let ids = (0..<4).map { _ in UUID() }
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: nil,
            tabs: ids.map { Tab(id: $0, url: URL(string: "https://\($0.uuidString).example"), isBookmarked: true, spaceId: spaceId) },
            folders: [],
            treeItems: ids.enumerated().map { offset, id in
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: id, parentFolderId: nil, section: .bookmarked, sortOrder: offset)
            }
        )
        let store = BrowserStateStoreHarness(states: [state])

        let moved = try XCTUnwrap(store.mutate(.moveTabToBookmarked(
            spaceId: spaceId,
            tabId: ids[0],
            insert: .anchored(fallbackIndex: 3, insertBeforeId: nil, insertAfterId: ids[3])
        )).changedState)

        XCTAssertEqual(moved.sidebar.rootNodeIds(in: .bookmarked), [ids[1], ids[2], ids[3], ids[0]])
    }

    func testBrowserStateStoreSplitGridHoldsFourPanesAndShrinksOnClose() throws {
        let spaceId = UUID()
        let ids = (0..<6).map { _ in UUID() }
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: ids[0],
            tabs: ids.map { Tab(id: $0, url: URL(string: "https://\($0.uuidString).example"), spaceId: spaceId) },
            folders: [],
            treeItems: ids.enumerated().map { offset, id in
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: id, parentFolderId: nil, section: .unpinned, sortOrder: offset)
            }
        )
        let store = BrowserStateStoreHarness(states: [state])
        _ = try store.mutate(.splitTabs(spaceId: spaceId, tabId: ids[1], targetTabId: ids[0], vertical: false, before: false))
        _ = try store.mutate(.splitTabs(spaceId: spaceId, tabId: ids[2], targetTabId: ids[0], vertical: true, before: false))
        let full = try XCTUnwrap(store.mutate(.splitTabs(spaceId: spaceId, tabId: ids[3], targetTabId: ids[1], vertical: true, before: false)).changedState)
        let folder = try XCTUnwrap(full.foldersById.values.first)
        XCTAssertEqual(folder.splitLayout?.paneIds, [ids[0], ids[2], ids[1], ids[3]])
        XCTAssertEqual(full.sidebar.childNodeIds(of: folder.id), [ids[0], ids[2], ids[1], ids[3]], "children follow the reading order")
        XCTAssertTrue(full.invariantsHold())

        let refused = try store.mutate(.splitTabs(spaceId: spaceId, tabId: ids[4], targetTabId: ids[0], vertical: false, before: false)).changedState
        XCTAssertNotEqual(refused?.tabsById[ids[4]]?.groupId, folder.id, "a full split takes no fifth pane")

        let replaced = try XCTUnwrap(store.mutate(.replaceSplitPane(spaceId: spaceId, targetTabId: ids[2], tabId: ids[4])).changedState)
        XCTAssertEqual(replaced.foldersById[folder.id]?.splitLayout?.paneIds, [ids[0], ids[4], ids[1], ids[3]])
        XCTAssertEqual(replaced.sidebar.rootNodeIds(in: .unpinned), [folder.id, ids[2], ids[5]], "the replaced tab sits right under the split")

        let shrunk = try XCTUnwrap(store.mutate(.closeTab(spaceId: spaceId, tabId: ids[4])).changedState)
        XCTAssertEqual(shrunk.foldersById[folder.id]?.splitLayout?.paneIds, [ids[0], ids[1], ids[3]])
        XCTAssertTrue(shrunk.invariantsHold())
    }

    func testBrowserStateStoreSplitTabsKeepsPositionAndDissolvesOnClose() throws {
        let spaceId = UUID()
        let firstTabId = UUID()
        let primaryTabId = UUID()
        let middleTabId = UUID()
        let secondaryTabId = UUID()
        let ids = [firstTabId, primaryTabId, middleTabId, secondaryTabId]
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: primaryTabId,
            tabs: ids.map { Tab(id: $0, url: URL(string: "https://\($0.uuidString).example"), spaceId: spaceId) },
            folders: [],
            treeItems: ids.enumerated().map { offset, id in
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: id, parentFolderId: nil, section: .unpinned, sortOrder: offset)
            }
        )
        let store = BrowserStateStoreHarness(states: [state])

        let split = try XCTUnwrap(store.mutate(.splitTabs(
            spaceId: spaceId, tabId: secondaryTabId, targetTabId: primaryTabId, vertical: false, before: false
        )).changedState)
        let folder = try XCTUnwrap(split.foldersById.values.first)
        XCTAssertTrue(folder.isSplit)
        XCTAssertEqual(split.sidebar.rootNodeIds(in: .unpinned), [firstTabId, folder.id, middleTabId])
        XCTAssertEqual(split.sidebar.childNodeIds(of: folder.id), [primaryTabId, secondaryTabId])
        XCTAssertTrue(split.invariantsHold())

        let stacked = SplitLayout.split(
            vertical: true, ratio: 0.62, first: .pane(tabId: primaryTabId), second: .pane(tabId: secondaryTabId)
        )
        let rearranged = try XCTUnwrap(store.mutate(.setSplitLayout(spaceId: spaceId, folderId: folder.id, layout: stacked)).changedState)
        XCTAssertEqual(rearranged.foldersById[folder.id]?.splitLayout, stacked)
        XCTAssertEqual(try SpaceTabStateCodec.decode(SpaceTabStateCodec.encode(rearranged.state)), rearranged.state)

        let closed = try XCTUnwrap(store.mutate(.closeTab(spaceId: spaceId, tabId: secondaryTabId)).changedState)
        XCTAssertTrue(closed.foldersById.isEmpty)
        XCTAssertEqual(closed.sidebar.rootNodeIds(in: .unpinned), [firstTabId, primaryTabId, middleTabId])
        XCTAssertTrue(closed.invariantsHold())
    }

    func testBrowserStateStoreMoveSidebarFolderToPinnedUpdatesChildrenSection() throws {
        let spaceId = UUID()
        let folderId = UUID()
        let childTabId = UUID()
        let folder = TabFolder(id: folderId, spaceId: spaceId, name: "Folder", color: "#111111")
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: childTabId,
            tabs: [
                Tab(id: childTabId, url: URL(string: "https://child.example"), title: "Child", groupId: folderId, spaceId: spaceId)
            ],
            folders: [folder],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folderId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: childTabId, parentFolderId: folderId, section: .unpinned, sortOrder: 0)
            ]
        )
        let store = BrowserStateStoreHarness(states: [state])

        let changes = try store.mutate(.moveSidebarItem(
            spaceId: spaceId,
            kind: .folder,
            itemId: folderId,
            parentFolderId: nil,
            section: .pinned,
            insert: .index(0)
        ))

        let updatedState = try XCTUnwrap(changes.changedState)
        XCTAssertEqual(updatedState.sidebar.node(id: folderId)?.section, .pinned)
        XCTAssertEqual(updatedState.tabsById[childTabId]?.isPinned, true)
        XCTAssertEqual(updatedState.tabsById[childTabId]?.groupId, folderId)
        XCTAssertEqual(updatedState.sidebar.rootNodeIds(in: .pinned), [folderId])
        XCTAssertEqual(updatedState.sidebar.childNodeIds(of: folderId), [childTabId])
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStoreMoveSidebarRootItemToEndUsesVisualOrderAfterRemovingSource() throws {
        let spaceId = UUID()
        let firstTabId = UUID()
        let secondTabId = UUID()
        let thirdTabId = UUID()
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: firstTabId,
            tabs: [
                Tab(id: firstTabId, url: URL(string: "https://first.example"), title: "First", spaceId: spaceId),
                Tab(id: secondTabId, url: URL(string: "https://second.example"), title: "Second", spaceId: spaceId),
                Tab(id: thirdTabId, url: URL(string: "https://third.example"), title: "Third", spaceId: spaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: firstTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: secondTabId, parentFolderId: nil, section: .unpinned, sortOrder: 1),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: thirdTabId, parentFolderId: nil, section: .unpinned, sortOrder: 2)
            ]
        )
        let store = BrowserStateStoreHarness(states: [state])

        let changes = try store.mutate(.moveSidebarItem(
            spaceId: spaceId,
            kind: .tab,
            itemId: firstTabId,
            parentFolderId: nil,
            section: .unpinned,
            insert: .index(2)
        ))

        let updatedState = try XCTUnwrap(changes.changedState)
        XCTAssertEqual(updatedState.sidebar.rootNodeIds(in: .unpinned), [secondTabId, thirdTabId, firstTabId])
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStoreMoveSidebarFolderChildToEndUsesVisualOrderAfterRemovingSource() throws {
        let spaceId = UUID()
        let folderId = UUID()
        let firstTabId = UUID()
        let secondTabId = UUID()
        let thirdTabId = UUID()
        let folder = TabFolder(id: folderId, spaceId: spaceId, name: "Folder", color: "#111111")
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: firstTabId,
            tabs: [
                Tab(id: firstTabId, url: URL(string: "https://first.example"), title: "First", groupId: folderId, spaceId: spaceId),
                Tab(id: secondTabId, url: URL(string: "https://second.example"), title: "Second", groupId: folderId, spaceId: spaceId),
                Tab(id: thirdTabId, url: URL(string: "https://third.example"), title: "Third", groupId: folderId, spaceId: spaceId)
            ],
            folders: [folder],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folderId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: firstTabId, parentFolderId: folderId, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: secondTabId, parentFolderId: folderId, section: .unpinned, sortOrder: 1),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: thirdTabId, parentFolderId: folderId, section: .unpinned, sortOrder: 2)
            ]
        )
        let store = BrowserStateStoreHarness(states: [state])

        let changes = try store.mutate(.moveSidebarItem(
            spaceId: spaceId,
            kind: .tab,
            itemId: firstTabId,
            parentFolderId: folderId,
            section: .unpinned,
            insert: .index(2)
        ))

        let updatedState = try XCTUnwrap(changes.changedState)
        XCTAssertEqual(updatedState.sidebar.childNodeIds(of: folderId), [secondTabId, thirdTabId, firstTabId])
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStoreSetFolderCollapsedOnlyUpdatesFolderMetadata() throws {
        let spaceId = UUID()
        let folderId = UUID()
        let childTabId = UUID()
        let folder = TabFolder(id: folderId, spaceId: spaceId, name: "Folder", color: "#111111", isCollapsed: false)
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: childTabId,
            tabs: [
                Tab(id: childTabId, url: URL(string: "https://child.example"), title: "Child", groupId: folderId, spaceId: spaceId)
            ],
            folders: [folder],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folderId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: childTabId, parentFolderId: folderId, section: .unpinned, sortOrder: 0)
            ]
        )
        let store = BrowserStateStoreHarness(states: [state])

        let changes = try store.mutate(.setFolderCollapsed(spaceId: spaceId, folderId: folderId, isCollapsed: true))

        let updatedState = try XCTUnwrap(changes.changedState)
        XCTAssertEqual(updatedState.foldersById[folderId]?.isCollapsed, true)
        XCTAssertEqual(updatedState.foldersById[folderId]?.name, "Folder")
        XCTAssertEqual(updatedState.foldersById[folderId]?.color, "#111111")
        XCTAssertEqual(updatedState.sidebar.childNodeIds(of: folderId), [childTabId])
        XCTAssertTrue(updatedState.invariantsHold())
    }

    func testBrowserStateStoreMutateAppliesStateChangeToSnapshot() throws {
        let spaceId = UUID()
        let existingTabId = UUID()
        let newTabId = UUID()
        let store = BrowserStateStore()
        store.storeSpace(id: spaceId, snapshot: makeSpaceSnapshot(tabs: [
                Tab(id: existingTabId, url: URL(string: "https://existing.example"), title: "Existing", spaceId: spaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: existingTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
            ],
            engines: [:],
            activeTabId: existingTabId
        ))
        let newTab = Tab(id: newTabId, url: URL(string: "https://new.example"), title: "New", spaceId: spaceId)

        let changes = try store.mutate(.createTab(spaceId: spaceId, tab: newTab, activate: true))

        let snapshot = try XCTUnwrap(store.space(id: spaceId))
        let projection = try XCTUnwrap(store.browserSpaceChange(spaceId: spaceId)).projection
        XCTAssertEqual(changes.changedState?.state.activeTabId, newTabId)
        XCTAssertEqual(snapshot.spaceTab.state.activeTabId, newTabId)
        XCTAssertEqual(projection.tabs.map(\.id), [existingTabId, newTabId])
        XCTAssertEqual(projection.treeItems.map(\.itemId), [existingTabId, newTabId])
    }

    func testBrowserStateStoreMutateStoresTabsInSidebarOrder() throws {
        let spaceId = UUID()
        let firstTabId = UUID()
        let secondTabId = UUID()
        let store = BrowserStateStore()
        store.storeSpace(id: spaceId, snapshot: makeSpaceSnapshot(tabs: [
                Tab(id: secondTabId, url: URL(string: "https://second.example"), title: "Second", spaceId: spaceId),
                Tab(id: firstTabId, url: URL(string: "https://first.example"), title: "First", spaceId: spaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: firstTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: secondTabId, parentFolderId: nil, section: .unpinned, sortOrder: 1)
            ],
            engines: [:],
            activeTabId: secondTabId
        ))

        try store.mutate(.activateTab(spaceId: spaceId, tabId: firstTabId))

        XCTAssertEqual(store.browserSpaceChange(spaceId: spaceId)?.projection.tabs.map(\.id), [firstTabId, secondTabId])
    }

    func testTabManagerFolderMirrorDoesNotDeriveTabFieldsFromTreeItems() throws {
        let spaceId = UUID()
        let tabId = UUID()
        let folderId = UUID()
        let tabManager = TabManager(engineFactory: WKEngineFactory())
        tabManager.currentSpaceId = spaceId
        let tabs = [
            Tab(
                id: tabId,
                url: URL(string: "https://tab.example"),
                title: "Tab",
                isPinned: false,
                isBookmarked: true,
                groupId: nil,
                spaceId: spaceId,
            )
        ]
        let folder = TabFolder(id: folderId, spaceId: spaceId, name: "Folder", color: "#111111")
        let treeItems = [
            TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folderId, parentFolderId: nil, section: .pinned, sortOrder: 0),
            TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: folderId, section: .pinned, sortOrder: 0)
        ]
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: nil,
            tabs: tabs,
            folders: [folder],
            treeItems: treeItems
        )
        tabManager.installSpaceTabStateForTests(SpaceTabState(state), spaceId: spaceId)

        let tab = try XCTUnwrap(tabManager.currentTabs.first(where: { $0.id == tabId }))
        XCTAssertNil(tab.groupId)
        XCTAssertFalse(tab.isPinned)
        XCTAssertTrue(tab.isBookmarked)
    }

    func testTabManagerSidebarTreeItemsAppendVisibleTabsMissingFromRawTree() throws {
        let spaceId = UUID()
        let existingTabId = UUID()
        let activeTabId = UUID()
        let staleFolderId = UUID()
        let tabManager = TabManager(engineFactory: WKEngineFactory())
        tabManager.currentSpaceId = spaceId
        tabManager.activeTabId = activeTabId
        let tabs = [
            Tab(id: existingTabId, url: URL(string: "https://home.example"), title: "Home", spaceId: spaceId),
            Tab(id: activeTabId, url: URL(string: "https://openai.com/fr-FR/codex/"), title: "OpenAI", groupId: staleFolderId, spaceId: spaceId)
        ]
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: activeTabId,
            tabs: tabs,
            folders: [],
            treeItems: [
            TabTreeItem(spaceId: spaceId, kind: .tab, itemId: existingTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
            ]
        )
        tabManager.installSpaceTabStateForTests(SpaceTabState(state), spaceId: spaceId)

        let treeItems = tabManager.sidebarTreeItems(forSpace: spaceId)

        XCTAssertEqual(treeItems.map(\.itemId), [existingTabId, activeTabId])
        XCTAssertEqual(treeItems.map(\.parentFolderId), [nil, nil])
    }

    func testTabManagerApplyBrowserStateFixtureOrdersTabsFromSidebarTreeItems() throws {
        let spaceId = UUID()
        let firstTabId = UUID()
        let secondTabId = UUID()
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: firstTabId,
            tabs: [
                Tab(id: secondTabId, url: URL(string: "https://second.example"), title: "Second", spaceId: spaceId),
                Tab(id: firstTabId, url: URL(string: "https://first.example"), title: "First", spaceId: spaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: firstTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: secondTabId, parentFolderId: nil, section: .unpinned, sortOrder: 1)
            ]
        )
        let tabManager = TabManager(engineFactory: WKEngineFactory())

        tabManager.installSpaceTabStateForTests(SpaceTabState(state), spaceId: state.spaceId)

        XCTAssertEqual(tabManager.currentTabs.map(\.id), [firstTabId, secondTabId])
    }

    func testTabManagerAppliesSpaceTabStateDirectly() throws {
        let spaceId = UUID()
        let firstTabId = UUID()
        let secondTabId = UUID()
        let tabState = SpaceTabState(
            activeTabId: firstTabId,
            activationHistory: [secondTabId],
            tree: StoredSidebarTree(
                pinned: [],
                unpinned: [
                    .tab(StoredTab(Tab(id: firstTabId, url: URL(string: "https://first.example"), title: "First", spaceId: spaceId))),
                    .tab(StoredTab(Tab(id: secondTabId, url: URL(string: "https://second.example"), title: "Second", spaceId: spaceId)))
                ],
                bookmarked: []
            )
        )
        let tabManager = TabManager(engineFactory: WKEngineFactory())
        tabManager.currentSpaceId = spaceId

        tabManager.installSpaceTabStateForTests(tabState, spaceId: spaceId)

        XCTAssertEqual(tabManager.currentTabs.map(\.id), [firstTabId, secondTabId])
        XCTAssertEqual(tabManager.activeTabId, firstTabId)
        XCTAssertEqual(tabManager.spaceTabState(forSpace: spaceId).activationHistory, [secondTabId])
    }

    func testTabManagerApplyDurableProjectionStagesMissingSpaceAndKeepsExistingDurable() throws {
        // The cross-profile move relies on apply to stage captured state back, but an apply for a space the store already
        // owns must not rewrite its durable state.
        let spaceId = UUID()
        let incomingTabId = UUID()
        let store = BrowserStateStore()
        let incomingState = SpaceTabStateImporter.importState(
            activeTabId: incomingTabId,
            activationHistory: [],
            tabs: [
                Tab(id: incomingTabId, url: URL(string: "https://incoming.example"), title: "Incoming", spaceId: spaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: incomingTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
            ],
            spaceId: spaceId
        )
        let tabManager = TabManager(engineFactory: WKEngineFactory())
        tabManager.currentSpaceId = spaceId
        tabManager.browserStateStore = store

        // 1) Space missing from the store: apply stages it (move-to-profile staging).
        XCTAssertNil(store.spaceTabState(forSpace: spaceId))
        tabManager.applyDurableProjectionToRuntime(incomingState, spaceId: spaceId)
        XCTAssertEqual(store.spaceTabState(forSpace: spaceId)?.projectedSidebar(spaceId: spaceId).tabs.map(\.id), [incomingTabId])
        XCTAssertEqual(tabManager.currentTabs.map(\.id), [incomingTabId])
        XCTAssertEqual(tabManager.activeTabId, incomingTabId)

        // 2) Space already owned by the store: re-applying does not rewrite the durable state.
        let durableBefore = store.spaceTabState(forSpace: spaceId)?.projectedSidebar(spaceId: spaceId).tabs.map(\.id)
        tabManager.applyDurableProjectionToRuntime(incomingState, spaceId: spaceId)
        XCTAssertEqual(store.spaceTabState(forSpace: spaceId)?.projectedSidebar(spaceId: spaceId).tabs.map(\.id), durableBefore)
    }

    func testTabManagerRestoreVisibleRuntimeDoesNotOverwriteDurableStore() throws {
        let spaceId = UUID()
        let storedTabId = UUID()
        let incomingTabId = UUID()
        let store = BrowserStateStore()
        store.storeSpace(
            id: spaceId,
            snapshot: makeSpaceSnapshot(
                tabs: [
                    Tab(id: storedTabId, url: URL(string: "https://stored.example"), title: "Stored", spaceId: spaceId)
                ],
                folders: [],
                treeItems: [
                    TabTreeItem(spaceId: spaceId, kind: .tab, itemId: storedTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
                ],
                engines: [:],
                activeTabId: storedTabId
            )
        )
        let tabManager = TabManager(engineFactory: WKEngineFactory())
        tabManager.currentSpaceId = spaceId
        tabManager.browserStateStore = store

        tabManager.restoreVisibleRuntime(
            [Tab(id: incomingTabId, url: URL(string: "https://incoming.example"), title: "Incoming", spaceId: spaceId)],
            activeTabId: incomingTabId,
            activateRestoredTab: false
        )

        XCTAssertEqual(store.spaceTabState(forSpace: spaceId)?.projectedSidebar(spaceId: spaceId).tabs.map(\.id), [storedTabId])
        XCTAssertNotEqual(tabManager.activeOpenTabId, incomingTabId)
    }

    func testTabManagerUpdateTabOnlyUpdatesRuntimeOverlay() throws {
        let spaceId = UUID()
        let tabId = UUID()
        let store = BrowserStateStore()
        store.storeSpace(
            id: spaceId,
            snapshot: makeSpaceSnapshot(
                tabs: [
                    Tab(id: tabId, url: URL(string: "https://stored.example"), title: "Stored", spaceId: spaceId)
                ],
                folders: [],
                treeItems: [
                    TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
                ],
                engines: [:],
                activeTabId: tabId
            )
        )
        let tabManager = TabManager(engineFactory: WKEngineFactory())
        tabManager.currentSpaceId = spaceId
        tabManager.browserStateStore = store

        tabManager.updateTab(id: tabId) { tab in
            tab.isLoading = true
        }

        XCTAssertEqual(tabManager.currentTabs.first(where: { $0.id == tabId })?.isLoading, true)
        let storedTab = store.spaceTabState(forSpace: spaceId)?.projectedSidebar(spaceId: spaceId).tabs.first(where: { $0.id == tabId })
        XCTAssertEqual(storedTab?.title, "Stored")
        XCTAssertEqual(storedTab?.isLoading, false)
    }

    func testTabManagerActivateTabRuntimeDoesNotChangeDurableActiveTab() throws {
        let spaceId = UUID()
        let firstTabId = UUID()
        let secondTabId = UUID()
        let store = BrowserStateStore()
        store.storeSpace(
            id: spaceId,
            snapshot: makeSpaceSnapshot(
                tabs: [
                    Tab(id: firstTabId, url: URL(string: "https://first.example"), title: "First", spaceId: spaceId),
                    Tab(id: secondTabId, url: URL(string: "https://second.example"), title: "Second", spaceId: spaceId)
                ],
                folders: [],
                treeItems: [
                    TabTreeItem(spaceId: spaceId, kind: .tab, itemId: firstTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                    TabTreeItem(spaceId: spaceId, kind: .tab, itemId: secondTabId, parentFolderId: nil, section: .unpinned, sortOrder: 1)
                ],
                engines: [:],
                activeTabId: firstTabId
            )
        )
        let tabManager = TabManager(engineFactory: WKEngineFactory())
        tabManager.currentSpaceId = spaceId
        tabManager.browserStateStore = store

        tabManager.activateTabRuntime(id: secondTabId)

        XCTAssertEqual(tabManager.activeOpenTabId, secondTabId)
        XCTAssertEqual(store.spaceTabState(forSpace: spaceId)?.activeTabId, firstTabId)
    }

    func testBrowserStateStoreTransferTabRuntimeMovesInteractionState() throws {
        let sourceSpaceId = UUID()
        let targetSpaceId = UUID()
        let tabId = UUID()
        let restoringStartedAt = Date(timeIntervalSince1970: 10)
        let interactionState = ["scroll": 12]
        let sourceTab = Tab(id: tabId, url: URL(string: "https://source.example"), title: "Source", spaceId: sourceSpaceId)
        let targetTab = Tab(id: UUID(), url: URL(string: "https://target.example"), title: "Target", spaceId: targetSpaceId)
        let store = BrowserStateStore()
        store.storeSpace(
            id: sourceSpaceId,
            snapshot: makeSpaceSnapshot(tabs: [sourceTab],
                folders: [],
                treeItems: [],
                engines: [:],
                interactionStates: [tabId: interactionState],
                restoringTabIds: [tabId: restoringStartedAt],
                activeTabId: tabId
            )
        )
        store.storeSpace(
            id: targetSpaceId,
            snapshot: makeSpaceSnapshot(tabs: [targetTab],
                folders: [],
                treeItems: [],
                engines: [:],
                activeTabId: targetTab.id
            )
        )

        store.transferTabRuntime(
            tabId: tabId,
            sourceSpaceId: sourceSpaceId,
            targetSpaceId: targetSpaceId,
            engine: nil,
            interactionState: interactionState,
            restoringStartedAt: restoringStartedAt
        )

        XCTAssertNil(store.space(id: sourceSpaceId)?.interactionStates[tabId])
        XCTAssertNil(store.space(id: sourceSpaceId)?.restoringTabIds[tabId])
        XCTAssertEqual(store.space(id: targetSpaceId)?.interactionStates[tabId] as? [String: Int], interactionState)
        XCTAssertNil(store.space(id: targetSpaceId)?.restoringTabIds[tabId])
    }

    func testBrowserStateFixtureSnapshotDerivesSingleSidebarModelFromTabFlags() throws {
        let spaceId = UUID()
        let pinnedFolderId = UUID()
        let pinnedTabId = UUID()
        let bookmarkedTabId = UUID()
        let closedUnpinnedTabId = UUID()
        let childTabId = UUID()
        let activeTabId = UUID()
        let tabs = [
            Tab(id: pinnedTabId, url: URL(string: "https://pinned.example"), title: "Pinned", isPinned: true, spaceId: spaceId),
            Tab(id: bookmarkedTabId, url: URL(string: "https://bookmark.example"), title: "Bookmark", isBookmarked: true, spaceId: spaceId),
            Tab(id: closedUnpinnedTabId, url: URL(string: "https://closed.example"), title: "Closed", isClosed: true, spaceId: spaceId),
            Tab(id: childTabId, url: URL(string: "https://child.example"), title: "Child", isPinned: true, groupId: pinnedFolderId, spaceId: spaceId),
            Tab(id: activeTabId, url: URL(string: "https://active.example"), title: "Active", spaceId: spaceId)
        ]
        let folders = [
            TabFolder(id: pinnedFolderId, spaceId: spaceId, name: "Pinned", color: "#5865f2")
        ]
        let treeItems = [
            TabTreeItem(spaceId: spaceId, kind: .tab, itemId: pinnedTabId, parentFolderId: nil, section: .pinned, sortOrder: 0),
            TabTreeItem(spaceId: spaceId, kind: .folder, itemId: pinnedFolderId, parentFolderId: nil, section: .pinned, sortOrder: 1),
            TabTreeItem(spaceId: spaceId, kind: .tab, itemId: childTabId, parentFolderId: pinnedFolderId, section: .pinned, sortOrder: 0),
            TabTreeItem(spaceId: spaceId, kind: .tab, itemId: bookmarkedTabId, parentFolderId: nil, section: .pinned, sortOrder: 2),
            TabTreeItem(spaceId: spaceId, kind: .tab, itemId: closedUnpinnedTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
            TabTreeItem(spaceId: spaceId, kind: .tab, itemId: activeTabId, parentFolderId: nil, section: .unpinned, sortOrder: 1)
        ]

        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: activeTabId,
            tabs: tabs,
            folders: folders,
            treeItems: treeItems
        )

        XCTAssertEqual(Set(state.tabsById.keys), [pinnedTabId, bookmarkedTabId, childTabId, activeTabId])
        XCTAssertEqual(state.sidebar.node(id: bookmarkedTabId)?.section, .bookmarked)
        XCTAssertNil(state.sidebar.node(id: closedUnpinnedTabId))
        XCTAssertEqual(state.sidebar.rootNodeIds(in: .bookmarked), [bookmarkedTabId])
        XCTAssertEqual(state.sidebar.rootNodeIds(in: .pinned), [pinnedTabId, pinnedFolderId])
        XCTAssertEqual(state.sidebar.childNodeIds(of: pinnedFolderId), [childTabId])
        XCTAssertEqual(state.sidebar.rootNodeIds(in: .unpinned), [activeTabId])
        XCTAssertTrue(state.invariantsHold())
    }

    func testBrowserStateFixtureAppendsVisibleTabsMissingFromSidebarTree() throws {
        let spaceId = UUID()
        let existingTabId = UUID()
        let activeTabId = UUID()
        let staleFolderId = UUID()
        let tabs = [
            Tab(id: existingTabId, url: URL(string: "https://home.example"), title: "Home", spaceId: spaceId),
            Tab(id: activeTabId, url: URL(string: "https://openai.com/fr-FR/codex/"), title: "OpenAI", groupId: staleFolderId, spaceId: spaceId)
        ]
        let treeItems = [
            TabTreeItem(spaceId: spaceId, kind: .tab, itemId: existingTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
        ]

        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: activeTabId,
            tabs: tabs,
            folders: [],
            treeItems: treeItems
        )

        XCTAssertEqual(state.sidebar.rootNodeIds(in: .unpinned), [existingTabId, activeTabId])
        XCTAssertEqual(state.sidebar.treeItems(spaceId: spaceId).map(\.itemId), [existingTabId, activeTabId])
        XCTAssertTrue(state.invariantsHold())
    }

    func testBrowserStateFixtureAppendsBookmarkedTabsMissingFromSidebarTree() throws {
        let spaceId = UUID()
        let existingBookmarkId = UUID()
        let missingBookmarkId = UUID()
        let tabs = [
            Tab(id: existingBookmarkId, url: URL(string: "https://home.example"), title: "Home", isBookmarked: true, spaceId: spaceId),
            Tab(id: missingBookmarkId, url: URL(string: "https://openai.com/fr-FR/codex/"), title: "OpenAI", isBookmarked: true, spaceId: spaceId)
        ]
        let treeItems = [
            TabTreeItem(spaceId: spaceId, kind: .tab, itemId: existingBookmarkId, parentFolderId: nil, section: .bookmarked, sortOrder: 0)
        ]

        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: missingBookmarkId,
            tabs: tabs,
            folders: [],
            treeItems: treeItems
        )

        XCTAssertEqual(state.sidebar.rootNodeIds(in: .bookmarked), [existingBookmarkId, missingBookmarkId])
        XCTAssertEqual(state.sidebar.treeItems(spaceId: spaceId).filter { $0.section == .bookmarked }.map(\.itemId), [existingBookmarkId, missingBookmarkId])
        XCTAssertTrue(state.invariantsHold())
    }

    func testBrowserStateFixtureKeepsClosedPinnedTabsVisibleWithExplicitTreeItems() throws {
        let spaceId = UUID()
        let folderId = UUID()
        let rootTabId = UUID()
        let childTabId = UUID()
        let tabs = [
            Tab(id: rootTabId, url: URL(string: "https://root.example"), title: "Root", isPinned: true, isClosed: true, spaceId: spaceId),
            Tab(id: childTabId, url: URL(string: "https://child.example"), title: "Child", isPinned: true, isClosed: true, groupId: folderId, spaceId: spaceId)
        ]
        let folders = [
            TabFolder(id: folderId, spaceId: spaceId, name: "Pinned", color: "#5865f2")
        ]
        let treeItems = [
            TabTreeItem(spaceId: spaceId, kind: .tab, itemId: rootTabId, parentFolderId: nil, section: .pinned, sortOrder: 0),
            TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folderId, parentFolderId: nil, section: .pinned, sortOrder: 1),
            TabTreeItem(spaceId: spaceId, kind: .tab, itemId: childTabId, parentFolderId: folderId, section: .pinned, sortOrder: 0)
        ]

        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: nil,
            tabs: tabs,
            folders: folders,
            treeItems: treeItems
        )

        XCTAssertEqual(state.sidebar.rootNodeIds(in: .pinned), [rootTabId, folderId])
        XCTAssertEqual(state.sidebar.childNodeIds(of: folderId), [childTabId])
        XCTAssertTrue(state.invariantsHold())
    }

    func testActivatingSpaceKeepsItInStoreAndExposesOnlyOtherSpacesAsInactive() {
        let activeSpaceId = UUID()
        let inactiveSpaceId = UUID()
        let activeTab = Tab(id: UUID(), url: URL(string: "https://active.example"), title: "Active", spaceId: activeSpaceId)
        let inactiveTab = Tab(id: UUID(), url: URL(string: "https://inactive.example"), title: "Inactive", spaceId: inactiveSpaceId)
        let store = BrowserStateStore()

        store.storeSpace(
            id: activeSpaceId,
            snapshot: makeSpaceSnapshot(tabs: [activeTab], folders: [], treeItems: [], engines: [:])
        )
        store.storeSpace(
            id: inactiveSpaceId,
            snapshot: makeSpaceSnapshot(tabs: [inactiveTab], folders: [], treeItems: [], engines: [:])
        )

        let activated = store.activateSpace(id: activeSpaceId) {
            XCTFail("existing spaces must activate from BrowserStateStore without reloading")
            return makeSpaceSnapshot(tabs: [], folders: [], treeItems: [], engines: [:])
        }

        XCTAssertEqual(store.projectedSidebar(from: activated).tabs.first?.id, activeTab.id)
        XCTAssertEqual(store.visibleSpaceIds, [activeSpaceId])
        XCTAssertEqual(store.browserSpaceChange(spaceId: activeSpaceId)?.projection.tabs.first?.id, activeTab.id)
        XCTAssertEqual(store.browserSpaceChange(spaceId: inactiveSpaceId)?.projection.tabs.first?.id, inactiveTab.id)
    }

    func testSpaceSnapshotBuildsStateWithoutRuntimeState() throws {
        let spaceId = UUID()
        let tabId = UUID()
        let tab = Tab(id: tabId, url: URL(string: "https://example.com"), title: "Example", spaceId: spaceId)
        let snapshot = makeSpaceSnapshot(tabs: [tab],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
            ],
            engines: [:],
            interactionStates: [tabId: "runtime"],
            restoringTabIds: [tabId: Date(timeIntervalSince1970: 1)],
            activeTabId: tabId
        )

        let store = BrowserStateStore()
        store.storeSpace(id: spaceId, snapshot: snapshot)
        let state = try XCTUnwrap(store.browserSpaceChange(spaceId: spaceId))

        XCTAssertEqual(state.spaceId, spaceId)
        XCTAssertEqual(state.state.activeTabId, tabId)
        XCTAssertEqual(state.tabsById[tabId]?.title, "Example")
        XCTAssertEqual(state.sidebar.rootNodeIds(in: .unpinned), [tabId])
    }

    func testRuntimeTabUpdateIsProjectedIntoBrowserStateChange() throws {
        let spaceId = UUID()
        let tabId = UUID()
        let tab = Tab(id: tabId, url: URL(string: "https://example.com"), title: "Example", spaceId: spaceId)
        let store = BrowserStateStore()
        store.storeSpace(
            id: spaceId,
            snapshot: makeSpaceSnapshot(
                tabs: [tab],
                folders: [],
                treeItems: [
                    TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
                ],
                engines: [:],
                activeTabId: tabId
            )
        )

        store.updateTab(id: tabId) { updated in
            updated.isLoading = true
            updated.estimatedProgress = 0.4
        }

        let projectedTab = store.browserSpaceChange(spaceId: spaceId)?.tabsById[tabId]
        XCTAssertEqual(projectedTab?.isLoading, true)
        XCTAssertEqual(projectedTab?.estimatedProgress, 0.4)
    }

    func testSpaceSnapshotPrefersSessionTreeOverProjectedSnapshot() throws {
        let spaceId = UUID()
        let tabId = UUID()
        let projectedTab = Tab(id: tabId, url: URL(string: "https://projected.example"), title: "Projected", spaceId: spaceId)
        let canonicalTab = StoredTab(
            id: tabId,
            url: "https://canonical.example",
            title: "Canonical",
            isPinned: false,
            isBookmarked: false,
            isClosed: false
        )
        var snapshot = makeSpaceSnapshot(tabs: [projectedTab],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
            ],
            engines: [:],
            activeTabId: tabId
        )
        snapshot.spaceTab = SpaceTab(
            spaceId: spaceId,
            state: SpaceTabState(
                activeTabId: tabId,
                activationHistory: [tabId],
                tree: StoredSidebarTree(pinned: [], unpinned: [.tab(canonicalTab)], bookmarked: [])
            )
        )

        let store = BrowserStateStore()
        store.storeSpace(id: spaceId, snapshot: snapshot)
        let state = try XCTUnwrap(store.browserSpaceChange(spaceId: spaceId))

        XCTAssertEqual(snapshot.spaceTab.state.projectedSidebar(spaceId: spaceId).tabs.first?.title, "Canonical")
        XCTAssertEqual(state.tabsById[tabId]?.title, "Canonical")
        XCTAssertEqual(state.state.activeTabId, tabId)
        XCTAssertEqual(state.state.activationHistory, [])
        XCTAssertEqual(state.sidebar.rootNodeIds(in: .unpinned), [tabId])
    }

    func testStoreSpaceBuildsCanonicalSessionFromProjectedSnapshot() throws {
        let spaceId = UUID()
        let tabId = UUID()
        let tab = Tab(id: tabId, url: URL(string: "https://example.com"), title: "Example", spaceId: spaceId)
        let store = BrowserStateStore()

        store.storeSpace(
            id: spaceId,
            snapshot: makeSpaceSnapshot(tabs: [tab],
                folders: [],
                treeItems: [
                    TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
                ],
                engines: [:],
                activeTabId: tabId
            )
        )

        XCTAssertEqual(store.space(id: spaceId)?.spaceTab.spaceId, spaceId)
        XCTAssertEqual(store.browserSpaceChange(spaceId: spaceId)?.tabsById[tabId]?.title, "Example")
    }

    func testUpdateTabKeepsCanonicalSessionInSync() throws {
        let spaceId = UUID()
        let tabId = UUID()
        let tab = Tab(id: tabId, url: URL(string: "https://old.example"), title: "Old", spaceId: spaceId)
        let store = BrowserStateStore()

        store.storeSpace(
            id: spaceId,
            snapshot: makeSpaceSnapshot(tabs: [tab],
                folders: [],
                treeItems: [
                    TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
                ],
                engines: [:],
                activeTabId: tabId
            )
        )

        store.updateTab(id: tabId) { tab in
            tab.url = URL(string: "https://new.example")
            tab.title = "New"
        }

        let state = try XCTUnwrap(store.browserSpaceChange(spaceId: spaceId))
        XCTAssertEqual(state.tabsById[tabId]?.url?.absoluteString, "https://new.example")
        XCTAssertEqual(state.tabsById[tabId]?.title, "New")
    }

    func testActivatingMissingSpaceLoadsAndStoresSnapshotOnce() {
        let spaceId = UUID()
        let tab = Tab(id: UUID(), url: URL(string: "https://loaded.example"), title: "Loaded", spaceId: spaceId)
        let store = BrowserStateStore()
        var loadCount = 0

        let activated = store.activateSpace(id: spaceId) {
            loadCount += 1
            return makeSpaceSnapshot(tabs: [tab], folders: [], treeItems: [], engines: [:])
        }

        XCTAssertEqual(store.projectedSidebar(from: activated).tabs.first?.id, tab.id)
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(store.browserSpaceChange(spaceId: spaceId)?.projection.tabs.first?.id, tab.id)

        _ = store.activateSpace(id: spaceId) {
            XCTFail("stored spaces must not reload on repeated activation")
            return makeSpaceSnapshot(tabs: [], folders: [], treeItems: [], engines: [:])
        }
    }

    func testActivatingASnapshotLoadedUnderAnotherIdKeepsItsStashTimes() {
        let spaceId = UUID()
        let tabId = UUID()
        let stashedAt = Date(timeIntervalSince1970: 1_000)
        var loaded = makeSpaceSnapshot(tabs: [], folders: [], treeItems: [], engines: [:], interactionStates: [tabId: "state"], spaceId: UUID())
        loaded.interactionStateStashedAt = [tabId: stashedAt]
        let store = BrowserStateStore()

        let activated = store.activateSpace(id: spaceId) { loaded }

        XCTAssertEqual(activated.spaceTab.spaceId, spaceId)
        XCTAssertEqual(activated.interactionStateStashedAt, [tabId: stashedAt])
    }

    func testStoreActiveSpaceMarksOnlyOtherSnapshotsInactive() {
        let activeSpaceId = UUID()
        let inactiveSpaceId = UUID()
        let store = BrowserStateStore()

        store.storeSpace(
            id: inactiveSpaceId,
            snapshot: makeSpaceSnapshot(tabs: [], folders: [], treeItems: [], engines: [:])
        )
        store.storeActiveSpace(
            id: activeSpaceId,
            snapshot: makeSpaceSnapshot(tabs: [], folders: [], treeItems: [], engines: [:])
        )

        XCTAssertEqual(store.visibleSpaceIds, [activeSpaceId])
        XCTAssertNotNil(store.space(id: activeSpaceId))
        XCTAssertNotNil(store.space(id: inactiveSpaceId))
    }

    func testCachesInactiveRuntimeSnapshotWithoutExposingTabManagerInternals() {
        let spaceId = UUID()
        let otherSpaceId = UUID()
        let tabId = UUID()
        let otherTabId = UUID()
        let tab = Tab(id: tabId, url: URL(string: "https://example.com"), title: "Example", spaceId: spaceId)
        let otherTab = Tab(id: otherTabId, url: URL(string: "https://other.example"), title: "Other", spaceId: otherSpaceId)
        let store = BrowserStateStore()
        let runtime = TabRuntimeSnapshot(
            tabs: [tab, otherTab],
            engines: [:],
            savedInteractionStates: [tabId: "state", otherTabId: "other-state"],
            restoringTabIds: [tabId: Date(timeIntervalSince1970: 10), otherTabId: Date(timeIntervalSince1970: 20)],
            activeTabId: tabId
        )

        store.cacheInactiveSpaceRuntime(
            id: spaceId,
            runtime: runtime,
            folders: [],
            treeItems: []
        )

        let cached = store.space(id: spaceId)
        XCTAssertEqual(store.browserSpaceChange(spaceId: spaceId)?.projection.tabs.map(\.id), [tabId])
        XCTAssertEqual(cached?.spaceTab.state.activeTabId, tabId)
        XCTAssertEqual(cached?.interactionStates[tabId] as? String, "state")
        XCTAssertNil(cached?.interactionStates[otherTabId])
        XCTAssertNil(cached?.restoringTabIds[otherTabId])
    }

    func testCacheInactiveSpaceRuntimePreservesExistingCanonicalSessionTree() throws {
        let spaceId = UUID()
        let tabId = UUID()
        let folderId = UUID()
        let canonicalTab = Tab(
            id: tabId,
            url: URL(string: "https://canonical.example"),
            title: "Canonical",
            groupId: folderId,
            spaceId: spaceId
        )
        let staleRuntimeTab = Tab(
            id: tabId,
            url: URL(string: "https://stale.example"),
            title: "Stale",
            spaceId: spaceId
        )
        let canonicalFolder = TabFolder(id: folderId, spaceId: spaceId, name: "Folder", color: "#111111")
        let store = BrowserStateStore()

        store.storeSpace(
            id: spaceId,
            snapshot: makeSpaceSnapshot(tabs: [canonicalTab],
                folders: [canonicalFolder],
                treeItems: [
                    TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folderId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                    TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: folderId, section: .unpinned, sortOrder: 0)
                ],
                engines: [:],
                activeTabId: tabId
            )
        )

        store.cacheInactiveSpaceRuntime(
            id: spaceId,
            runtime: TabRuntimeSnapshot(
                tabs: [staleRuntimeTab],
                engines: [:],
                savedInteractionStates: [tabId: "state"],
                restoringTabIds: [:],
                activeTabId: tabId
            ),
            folders: [],
            treeItems: []
        )

        let cached = try XCTUnwrap(store.space(id: spaceId))
        let state = try XCTUnwrap(store.browserSpaceChange(spaceId: spaceId))
        XCTAssertEqual(state.tabsById[tabId]?.title, "Canonical")
        XCTAssertEqual(state.tabsById[tabId]?.groupId, folderId)
        XCTAssertEqual(state.sidebar.rootNodeIds(in: .unpinned), [folderId])
        XCTAssertEqual(state.sidebar.childNodeIds(of: folderId), [tabId])
        XCTAssertEqual(cached.interactionStates[tabId] as? String, "state")
    }

    func testUpdatesStoredTabWithoutMainWindowControllerCacheOwnership() {
        let spaceId = UUID()
        let tabId = UUID()
        let store = BrowserStateStore()
        let tab = Tab(id: tabId, url: URL(string: "https://example.com"), title: "Old", spaceId: spaceId)

        store.storeSpace(
            id: spaceId,
            snapshot: makeSpaceSnapshot(tabs: [tab],
                folders: [],
                treeItems: [],
                engines: [:]
            )
        )

        let updated = store.updateTab(id: tabId) { tab in
            tab.title = "New"
        }

        XCTAssertEqual(updated?.new.title, "New")
        XCTAssertEqual(store.browserSpaceChange(spaceId: spaceId)?.projection.tabs.first?.title, "New")
    }

    func testRemovingSpaceRemovesItWithoutRequiringEngineDiscard() {
        let spaceId = UUID()
        let store = BrowserStateStore()

        store.storeSpace(
            id: spaceId,
            snapshot: makeSpaceSnapshot(tabs: [], folders: [], treeItems: [], engines: [:])
        )

        let removed = store.removeSpace(id: spaceId, discardEngine: nil)

        XCTAssertNotNil(removed)
        XCTAssertNil(store.space(id: spaceId))
    }

    func testCacheInactiveSpaceRuntimeRetainsInspectedEngineUntilLifecycleTrim() {
        let spaceId = UUID()
        let tabId = UUID()
        let tab = Tab(id: tabId, url: URL(string: "https://example.com"), title: "Example", spaceId: spaceId)
        let configuration = WKWebViewConfiguration()
        WebInspectorSupport.prepare(configuration: configuration)
        let engine = WKWebViewTab(configuration: configuration)
        let store = BrowserStateStore()
        let runtime = TabRuntimeSnapshot(
            tabs: [tab],
            engines: [tabId: engine],
            savedInteractionStates: [:],
            restoringTabIds: [:],
            activeTabId: nil
        )
        XCTAssertTrue(engine.showWebInspector())
        defer { _ = WebInspectorSupport.close(for: engine.wkWebView) }

        store.cacheInactiveSpaceRuntime(
            id: spaceId,
            runtime: runtime,
            folders: [],
            treeItems: []
        )

        XCTAssertTrue(store.space(id: spaceId)?.engines[tabId] === engine)
    }

    func testCacheInactiveSpaceRuntimeKeepsRuntimeVisualOnlyUntilLifecycleTrim() {
        let spaceId = UUID()
        let tabId = UUID()
        let tab = Tab(id: tabId, url: URL(string: "https://example.com"), title: "Example", spaceId: spaceId)
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let windowAdapter = WindowExtensionAdapter(nsWindow: NSWindow())
        let tabAdapter = TabExtensionAdapter(engineTab: engine, extensionWindow: windowAdapter)
        let store = BrowserStateStore()
        let runtime = TabRuntimeSnapshot(
            tabs: [tab],
            engines: [tabId: engine],
            tabAdapters: [tabId: tabAdapter],
            savedInteractionStates: [:],
            restoringTabIds: [:],
            activeTabId: tabId
        )

        store.cacheInactiveSpaceRuntime(
            id: spaceId,
            runtime: runtime,
            folders: [],
            treeItems: []
        )

        let snapshot = store.space(id: spaceId)
        XCTAssertTrue(snapshot?.engines[tabId] === engine)
        XCTAssertTrue(snapshot?.tabAdapters[tabId] === tabAdapter)
    }

    func testTrimInactiveEnginesDoesNotDiscardInspectedEngines() {
        let activeSpaceId = UUID()
        let hiddenSpaceId = UUID()
        let tabId = UUID()
        let tab = Tab(id: tabId, url: URL(string: "https://example.com"), title: "Example", spaceId: hiddenSpaceId)
        let configuration = WKWebViewConfiguration()
        WebInspectorSupport.prepare(configuration: configuration)
        let engine = WKWebViewTab(configuration: configuration)
        let store = BrowserStateStore()
        var discardCount = 0
        XCTAssertTrue(engine.showWebInspector())
        defer { _ = WebInspectorSupport.close(for: engine.wkWebView) }

        store.storeSpace(
            id: hiddenSpaceId,
            snapshot: makeSpaceSnapshot(tabs: [tab],
                folders: [],
                treeItems: [],
                engines: [tabId: engine],
                activeTabId: tabId,
                lastAccessedAt: Date(timeIntervalSince1970: 1)
            )
        )
        store.storeActiveSpace(
            id: activeSpaceId,
            snapshot: makeSpaceSnapshot(tabs: [], folders: [], treeItems: [], engines: [:])
        )

        store.trimInactiveEngines(
            excluding: nil,
            policy: .foreground,
            maxRetainedEnginesPerHiddenSpace: 0,
            maxHiddenSpacesWithRetainedEngines: 0,
            discardEngine: { _ in discardCount += 1; return nil }
        )

        XCTAssertTrue(store.space(id: hiddenSpaceId)?.engines[tabId] === engine)
        XCTAssertEqual(discardCount, 0)
    }

    func testTrimInactiveEnginesKeepsTheTabAdapterWithoutItsEngine() {
        let activeSpaceId = UUID()
        let hiddenSpaceId = UUID()
        let tabId = UUID()
        let tab = Tab(id: tabId, url: URL(string: "https://example.com"), title: "Example", spaceId: hiddenSpaceId)
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let tabAdapter = TabExtensionAdapter(engineTab: engine)
        let store = BrowserStateStore()

        store.cacheInactiveSpaceRuntime(
            id: hiddenSpaceId,
            runtime: TabRuntimeSnapshot(
                tabs: [tab],
                engines: [tabId: engine],
                tabAdapters: [tabId: tabAdapter],
                savedInteractionStates: [:],
                restoringTabIds: [:],
                activeTabId: tabId
            ),
            folders: [],
            treeItems: []
        )
        store.storeActiveSpace(
            id: activeSpaceId,
            snapshot: makeSpaceSnapshot(tabs: [], folders: [], treeItems: [], engines: [:])
        )

        store.trimInactiveEngines(
            excluding: nil,
            policy: .background,
            maxRetainedEnginesPerHiddenSpace: 0,
            maxHiddenSpacesWithRetainedEngines: 0,
            discardEngine: { _ in nil }
        )

        XCTAssertNil(store.space(id: hiddenSpaceId)?.engines[tabId])
        // Extensions keep the tab under the same id, and the adapter no longer holds the discarded page.
        XCTAssertTrue(store.space(id: hiddenSpaceId)?.tabAdapters[tabId] === tabAdapter)
        XCTAssertNil(tabAdapter.engineTab)
    }

    func testRemoveSpaceDiscardsTabAdapters() {
        let hiddenSpaceId = UUID()
        let tabId = UUID()
        let tab = Tab(id: tabId, url: URL(string: "https://example.com"), title: "Example", spaceId: hiddenSpaceId)
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let tabAdapter = TabExtensionAdapter(engineTab: engine)
        let store = BrowserStateStore()
        var discardedAdapters: [TabExtensionAdapter] = []

        store.storeSpace(
            id: hiddenSpaceId,
            snapshot: makeSpaceSnapshot(
                tabs: [tab],
                folders: [],
                treeItems: [],
                engines: [tabId: engine],
                tabAdapters: [tabId: tabAdapter]
            )
        )

        let removed = store.removeSpace(
            id: hiddenSpaceId,
            discardEngine: { _ in nil },
            discardTabAdapter: { discardedAdapters.append($0) }
        )

        XCTAssertNotNil(removed)
        XCTAssertEqual(discardedAdapters.count, 1)
        XCTAssertTrue(discardedAdapters.first === tabAdapter)
    }

    func testTrimInactiveEnginesDoesNotDiscardCaptureTabs() {
        let activeSpaceId = UUID()
        let hiddenSpaceId = UUID()
        let normal = UUID()
        let microphone = UUID()
        let camera = UUID()
        let screen = UUID()
        let normalEngine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let microphoneEngine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let cameraEngine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let screenEngine = WKWebViewTab(configuration: WKWebViewConfiguration())
        var microphoneTab = Tab(id: microphone, url: URL(string: "https://mic.example"), title: "Mic", spaceId: hiddenSpaceId)
        microphoneTab.isMicrophoneActive = true
        var cameraTab = Tab(id: camera, url: URL(string: "https://camera.example"), title: "Camera", spaceId: hiddenSpaceId)
        cameraTab.isCameraActive = true
        var screenTab = Tab(id: screen, url: URL(string: "https://screen.example"), title: "Screen", spaceId: hiddenSpaceId)
        screenTab.isScreenSharing = true
        let store = BrowserStateStore()
        var discardedTabIds: [UUID] = []

        store.cacheInactiveSpaceRuntime(
            id: hiddenSpaceId,
            runtime: TabRuntimeSnapshot(
                tabs: [
                    Tab(id: normal, url: URL(string: "https://normal.example"), title: "Normal", spaceId: hiddenSpaceId),
                    microphoneTab,
                    cameraTab,
                    screenTab
                ],
                engines: [
                    normal: normalEngine,
                    microphone: microphoneEngine,
                    camera: cameraEngine,
                    screen: screenEngine
                ],
                savedInteractionStates: [:],
                restoringTabIds: [:],
                activeTabId: normal
            ),
            folders: [],
            treeItems: []
        )
        store.storeActiveSpace(
            id: activeSpaceId,
            snapshot: makeSpaceSnapshot(tabs: [], folders: [], treeItems: [], engines: [:])
        )

        store.trimInactiveEngines(
            excluding: nil,
            policy: .background,
            maxRetainedEnginesPerHiddenSpace: 0,
            maxHiddenSpacesWithRetainedEngines: 0,
            discardEngine: { engine in
                if engine === normalEngine { discardedTabIds.append(normal) }
                if engine === microphoneEngine { discardedTabIds.append(microphone) }
                if engine === cameraEngine { discardedTabIds.append(camera) }
                if engine === screenEngine { discardedTabIds.append(screen) }
                return nil
            }
        )

        let engines = store.space(id: hiddenSpaceId)?.engines
        XCTAssertEqual(discardedTabIds, [normal])
        XCTAssertNil(engines?[normal])
        XCTAssertTrue(engines?[microphone] === microphoneEngine)
        XCTAssertTrue(engines?[camera] === cameraEngine)
        XCTAssertTrue(engines?[screen] === screenEngine)
    }

    func testTrimInactiveEnginesRemovesDiscardedRuntimeAndSavesInteractionState() {
        let activeSpaceId = UUID()
        let hiddenSpaceId = UUID()
        let tabId = UUID()
        let tab = Tab(id: tabId, url: URL(string: "https://example.com"), title: "Example", spaceId: hiddenSpaceId)
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let windowAdapter = WindowExtensionAdapter(nsWindow: NSWindow())
        let tabAdapter = TabExtensionAdapter(engineTab: engine, extensionWindow: windowAdapter)
        let savedState = ["scrollY": 120]
        let store = BrowserStateStore()

        store.storeSpace(
            id: hiddenSpaceId,
            snapshot: makeSpaceSnapshot(
                tabs: [tab],
                folders: [],
                treeItems: [],
                engines: [tabId: engine],
                tabAdapters: [tabId: tabAdapter],
                activeTabId: tabId,
                lastAccessedAt: Date(timeIntervalSince1970: 1)
            )
        )
        store.storeActiveSpace(
            id: activeSpaceId,
            snapshot: makeSpaceSnapshot(tabs: [], folders: [], treeItems: [], engines: [:])
        )

        store.trimInactiveEngines(
            excluding: nil,
            policy: .foreground,
            maxRetainedEnginesPerHiddenSpace: 0,
            maxHiddenSpacesWithRetainedEngines: 0,
            discardEngine: { discardedEngine in
                XCTAssertTrue(discardedEngine === engine)
                return savedState
            }
        )

        let snapshot = store.space(id: hiddenSpaceId)
        XCTAssertTrue(snapshot?.engines.isEmpty ?? false)
        // The adapter outlives its engine so extensions keep the tab id, but it lets go of the torn-down
        // page: an adapter still pointing at it would expose a zombie tab.
        XCTAssertTrue(snapshot?.tabAdapters[tabId] === tabAdapter)
        XCTAssertNil(tabAdapter.engineTab)
        XCTAssertEqual(snapshot?.interactionStates[tabId] as? [String: Int], savedState)
        XCTAssertEqual(store.lifecycleDiagnostics().discardedOpenTabCount, 1)
        XCTAssertEqual(store.lifecycleDiagnostics().savedInteractionStateCount, 1)
    }

    func testTrimInactiveEnginesClearsLoadingStateForDiscardedTabs() {
        let activeSpaceId = UUID()
        let hiddenSpaceId = UUID()
        let tabId = UUID()
        var loadingTab = Tab(id: tabId, url: URL(string: "https://loading.example"), title: "Loading", spaceId: hiddenSpaceId)
        loadingTab.isLoading = true
        loadingTab.estimatedProgress = 0.4
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let store = BrowserStateStore()

        store.cacheInactiveSpaceRuntime(
            id: hiddenSpaceId,
            runtime: TabRuntimeSnapshot(
                tabs: [loadingTab],
                engines: [tabId: engine],
                savedInteractionStates: [:],
                restoringTabIds: [:],
                activeTabId: tabId
            ),
            folders: [],
            treeItems: []
        )
        store.storeActiveSpace(
            id: activeSpaceId,
            snapshot: makeSpaceSnapshot(tabs: [], folders: [], treeItems: [], engines: [:])
        )

        store.trimInactiveEngines(
            excluding: nil,
            policy: .background,
            maxRetainedEnginesPerHiddenSpace: 0,
            maxHiddenSpacesWithRetainedEngines: 0,
            discardEngine: { discardedEngine in
                XCTAssertTrue(discardedEngine === engine)
                return nil
            }
        )

        let projectedTab = store.browserSpaceChange(spaceId: hiddenSpaceId)?.tabsById[tabId]
        XCTAssertEqual(projectedTab?.isLoading, false)
        XCTAssertEqual(projectedTab?.estimatedProgress, 0)
    }

    func testAggressiveTrimScalesAcrossManyHiddenSpaces() {
        let activeSpaceId = UUID()
        let activeTabId = UUID()
        let activeEngine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let store = BrowserStateStore()

        store.storeActiveSpace(
            id: activeSpaceId,
            snapshot: makeSpaceSnapshot(
                tabs: [
                    Tab(id: activeTabId, url: URL(string: "https://active.example"), title: "Active", spaceId: activeSpaceId)
                ],
                folders: [],
                treeItems: [],
                engines: [activeTabId: activeEngine],
                activeTabId: activeTabId,
                spaceId: activeSpaceId
            )
        )

        for spaceIndex in 0..<5 {
            let spaceId = UUID()
            var tabs: [Tab] = []
            var engines: [UUID: WKWebViewTab] = [:]
            for tabIndex in 0..<10 {
                let tabId = UUID()
                tabs.append(Tab(
                    id: tabId,
                    url: URL(string: "https://space-\(spaceIndex)-tab-\(tabIndex).example"),
                    title: "Tab \(spaceIndex)-\(tabIndex)",
                    spaceId: spaceId
                ))
                engines[tabId] = WKWebViewTab(configuration: WKWebViewConfiguration())
            }
            store.storeSpace(
                id: spaceId,
                snapshot: makeSpaceSnapshot(
                    tabs: tabs,
                    folders: [],
                    treeItems: [],
                    engines: engines,
                    activeTabId: tabs.first?.id,
                    lastAccessedAt: Date(timeIntervalSince1970: Double(spaceIndex + 1)),
                    spaceId: spaceId
                )
            )
        }

        store.trimInactiveEngines(
            excluding: activeSpaceId,
            policy: .background,
            maxRetainedEnginesPerHiddenSpace: 0,
            maxHiddenSpacesWithRetainedEngines: 0,
            discardEngine: { engine in
                ["discarded": ObjectIdentifier(engine).hashValue]
            }
        )

        let diagnostics = store.lifecycleDiagnostics()
        XCTAssertEqual(diagnostics.activeSpaceEngineCount, 1)
        XCTAssertEqual(diagnostics.hiddenSpaceEngineCount, 0)
        XCTAssertEqual(diagnostics.totalLiveEngineCount, 1)
        XCTAssertEqual(diagnostics.discardedOpenTabCount, 50)
        XCTAssertEqual(diagnostics.savedInteractionStateCount, 50)
        XCTAssertEqual(diagnostics.hiddenSpacesWithNormalRetainedEngines, 0)
    }

    func testTrimInactiveEnginesAppliesPerSpaceEngineBudgetToSurvivorSpace() {
        let activeSpaceId = UUID()
        let hiddenSpaceId = UUID()
        let preferredId = UUID()
        let otherId1 = UUID()
        let otherId2 = UUID()
        let store = BrowserStateStore()
        store.storeActiveSpace(
            id: activeSpaceId,
            snapshot: makeSpaceSnapshot(tabs: [], folders: [], treeItems: [], engines: [:], spaceId: activeSpaceId)
        )
        store.storeSpace(
            id: hiddenSpaceId,
            snapshot: makeSpaceSnapshot(
                tabs: [
                    Tab(id: preferredId, url: URL(string: "https://a.example"), title: "A", spaceId: hiddenSpaceId),
                    Tab(id: otherId1, url: URL(string: "https://b.example"), title: "B", spaceId: hiddenSpaceId),
                    Tab(id: otherId2, url: URL(string: "https://c.example"), title: "C", spaceId: hiddenSpaceId),
                ],
                folders: [],
                treeItems: [],
                engines: [
                    preferredId: WKWebViewTab(configuration: WKWebViewConfiguration()),
                    otherId1: WKWebViewTab(configuration: WKWebViewConfiguration()),
                    otherId2: WKWebViewTab(configuration: WKWebViewConfiguration()),
                ],
                activeTabId: preferredId,
                lastAccessedAt: Date(),
                spaceId: hiddenSpaceId
            )
        )
        var discardCount = 0
        store.trimInactiveEngines(
            excluding: nil,
            policy: .foreground,
            maxRetainedEnginesPerHiddenSpace: 1,
            maxHiddenSpacesWithRetainedEngines: 2,   // the single hidden space stays within budget (not evicted)
            discardEngine: { _ in discardCount += 1; return nil },
            discardThreshold: .infinity              // isolate the per-space budget from the idle pass
        )
        // The within-budget hidden space keeps only its preferred (active) engine; the rest are discarded.
        XCTAssertNotNil(store.space(id: hiddenSpaceId)?.engines[preferredId])
        XCTAssertNil(store.space(id: hiddenSpaceId)?.engines[otherId1])
        XCTAssertNil(store.space(id: hiddenSpaceId)?.engines[otherId2])
        XCTAssertEqual(discardCount, 2)
    }

    func testTrimInactiveEnginesDiscardsIdleEngineBeyondThreshold() {
        let activeSpaceId = UUID()
        let hiddenSpaceId = UUID()
        let tabId = UUID()
        var tab = Tab(id: tabId, url: URL(string: "https://example.com"), title: "Example", spaceId: hiddenSpaceId)
        tab.lastActiveAt = Date(timeIntervalSince1970: 1)   // ancient, so idle beyond any finite threshold
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let store = BrowserStateStore()
        store.runtimeOverlay.setRuntimeState(from: tab)     // stamp lastActiveAt into the overlay
        store.storeSpace(
            id: hiddenSpaceId,
            snapshot: makeSpaceSnapshot(tabs: [tab], folders: [], treeItems: [], engines: [tabId: engine], activeTabId: tabId, lastAccessedAt: Date())
        )
        store.storeActiveSpace(
            id: activeSpaceId,
            snapshot: makeSpaceSnapshot(tabs: [], folders: [], treeItems: [], engines: [:])
        )
        var discardCount = 0
        store.trimInactiveEngines(
            excluding: nil,
            policy: .foreground,
            maxRetainedEnginesPerHiddenSpace: 1,
            maxHiddenSpacesWithRetainedEngines: 2,
            discardEngine: { _ in discardCount += 1; return nil },
            discardThreshold: 60
        )
        XCTAssertNil(store.space(id: hiddenSpaceId)?.engines[tabId])
        XCTAssertEqual(discardCount, 1)
    }

    func testFreezeIdleEnginesFreezesIdleHiddenEngine() {
        let activeSpaceId = UUID()
        let hiddenSpaceId = UUID()
        let tabId = UUID()
        var tab = Tab(id: tabId, url: URL(string: "https://example.com"), title: "Example", spaceId: hiddenSpaceId)
        tab.lastActiveAt = Date(timeIntervalSince1970: 1)   // ancient, so idle beyond threshold
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let store = BrowserStateStore()
        store.runtimeOverlay.setRuntimeState(from: tab)
        store.storeSpace(
            id: hiddenSpaceId,
            snapshot: makeSpaceSnapshot(tabs: [tab], folders: [], treeItems: [], engines: [tabId: engine], activeTabId: tabId, lastAccessedAt: Date())
        )
        store.storeActiveSpace(
            id: activeSpaceId,
            snapshot: makeSpaceSnapshot(tabs: [], folders: [], treeItems: [], engines: [:])
        )
        XCTAssertFalse(engine.isFrozen)
        store.freezeIdleEngines(freezeThreshold: 60)
        XCTAssertTrue(engine.isFrozen)
    }

    func testFreezeIdleEnginesFreezesActiveSpaceBackgroundTabButNotVisibleTab() {
        let activeSpaceId = UUID()
        let visibleTabId = UUID()
        let backgroundTabId = UUID()
        var visible = Tab(id: visibleTabId, url: URL(string: "https://visible.example"), title: "Visible", spaceId: activeSpaceId)
        visible.lastActiveAt = Date(timeIntervalSince1970: 1)   // both idle beyond threshold
        var background = Tab(id: backgroundTabId, url: URL(string: "https://bg.example"), title: "Background", spaceId: activeSpaceId)
        background.lastActiveAt = Date(timeIntervalSince1970: 1)
        let visibleEngine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let backgroundEngine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let store = BrowserStateStore()
        store.runtimeOverlay.setRuntimeState(from: visible)
        store.runtimeOverlay.setRuntimeState(from: background)
        store.storeActiveSpace(
            id: activeSpaceId,
            snapshot: makeSpaceSnapshot(
                tabs: [visible, background], folders: [], treeItems: [],
                engines: [visibleTabId: visibleEngine, backgroundTabId: backgroundEngine],
                activeTabId: visibleTabId, lastAccessedAt: Date()
            )
        )
        store.freezeIdleEngines(freezeThreshold: 60)
        XCTAssertFalse(visibleEngine.isFrozen, "the visible active tab must never be frozen")
        XCTAssertTrue(backgroundEngine.isFrozen, "an idle background tab in the active space should freeze")
    }

    func testFreezeIdleEnginesNeverFreezesATabWhosePiPWindowIsOpen() {
        let activeSpaceId = UUID(), hiddenSpaceId = UUID()
        var opener = Tab(id: UUID(), url: URL(string: "https://timer.example"), title: "Timer", spaceId: hiddenSpaceId)
        opener.lastActiveAt = Date(timeIntervalSince1970: 1)
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let store = BrowserStateStore()
        store.runtimeOverlay.setRuntimeState(from: opener)
        store.storeSpace(
            id: hiddenSpaceId,
            snapshot: makeSpaceSnapshot(tabs: [opener], folders: [], treeItems: [], engines: [opener.id: engine])
        )
        store.storeActiveSpace(id: activeSpaceId, snapshot: makeSpaceSnapshot(tabs: [], folders: [], treeItems: [], engines: [:]))
        store.pictureInPictureOpenerIds = [opener.id]

        store.freezeIdleEngines(freezeThreshold: 60)

        XCTAssertFalse(engine.isFrozen, "its PiP window runs in the opener's page")
    }

    func testFreezeIdleEnginesNeverFreezesAgentTabs() {
        let activeSpaceId = UUID(), hiddenSpaceId = UUID()
        var agent = Tab(id: UUID(), url: URL(string: "https://agent.example"), title: "Agent", spaceId: hiddenSpaceId)
        agent.lastActiveAt = Date(timeIntervalSince1970: 1)
        agent.isAgentControlled = true
        var user = Tab(id: UUID(), url: URL(string: "https://user.example"), title: "User", spaceId: hiddenSpaceId)
        user.lastActiveAt = Date(timeIntervalSince1970: 1)
        let agentEngine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let userEngine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let store = BrowserStateStore()
        store.runtimeOverlay.setRuntimeState(from: agent)
        store.runtimeOverlay.setRuntimeState(from: user)
        store.storeSpace(
            id: hiddenSpaceId,
            snapshot: makeSpaceSnapshot(tabs: [agent, user], folders: [], treeItems: [], engines: [agent.id: agentEngine, user.id: userEngine])
        )
        store.storeActiveSpace(id: activeSpaceId, snapshot: makeSpaceSnapshot(tabs: [], folders: [], treeItems: [], engines: [:]))

        store.freezeIdleEngines(freezeThreshold: 60)

        XCTAssertTrue(userEngine.isFrozen)
        XCTAssertFalse(agentEngine.isFrozen)
    }

    func testAgentTabFreezesAgainOnceReleased() {
        let activeSpaceId = UUID(), hiddenSpaceId = UUID()
        var tab = Tab(id: UUID(), url: URL(string: "https://agent.example"), title: "Agent", spaceId: hiddenSpaceId)
        tab.lastActiveAt = Date(timeIntervalSince1970: 1)
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let store = BrowserStateStore()
        store.runtimeOverlay.setRuntimeState(from: tab)
        store.storeSpace(id: hiddenSpaceId, snapshot: makeSpaceSnapshot(tabs: [tab], folders: [], treeItems: [], engines: [tab.id: engine]))
        store.storeActiveSpace(id: activeSpaceId, snapshot: makeSpaceSnapshot(tabs: [], folders: [], treeItems: [], engines: [:]))
        _ = store.updateTab(id: tab.id) { $0.isAgentControlled = true }
        store.freezeIdleEngines(freezeThreshold: 60)
        XCTAssertFalse(engine.isFrozen)

        _ = store.updateTab(id: tab.id) { $0.isAgentControlled = false }
        store.freezeIdleEngines(freezeThreshold: 60)

        XCTAssertTrue(engine.isFrozen)
    }

    func testFreezeAllEnginesSkipsAgentTabs() {
        let activeSpaceId = UUID()
        let user = Tab(id: UUID(), url: URL(string: "https://user.example"), title: "User", spaceId: activeSpaceId)
        let agent = Tab(id: UUID(), url: URL(string: "https://agent.example"), title: "Agent", spaceId: activeSpaceId)
        let userEngine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let agentEngine = WKWebViewTab(configuration: WKWebViewConfiguration())
        agentEngine.isAgentControlled = true
        let store = BrowserStateStore()
        store.storeActiveSpace(
            id: activeSpaceId,
            snapshot: makeSpaceSnapshot(tabs: [user, agent], folders: [], treeItems: [], engines: [user.id: userEngine, agent.id: agentEngine], activeTabId: user.id)
        )

        let frozen = store.freezeAllEngines()

        XCTAssertTrue(frozen.contains { $0 === userEngine })
        XCTAssertFalse(agentEngine.isFrozen)
    }

    func testFreezeAllEnginesKeepsCallsRunning() {
        let activeSpaceId = UUID()
        let call = Tab(id: UUID(), url: URL(string: "https://call.example"), title: "Call", spaceId: activeSpaceId)
        let callEngine = WKWebViewTab(configuration: WKWebViewConfiguration())
        defer { callEngine.teardown() }
        callEngine.isTabShareSource = true
        let store = BrowserStateStore()
        store.storeActiveSpace(
            id: activeSpaceId,
            snapshot: makeSpaceSnapshot(tabs: [call], folders: [], treeItems: [], engines: [call.id: callEngine], activeTabId: call.id)
        )

        let frozen = store.freezeAllEngines()

        XCTAssertTrue(frozen.isEmpty)
        XCTAssertFalse(callEngine.isFrozen, "a call goes on with the lid closed, through headphones")
    }

    func testFreezeAllEnginesFreezesEveryLiveEngineOnceAndReturnsOnlyThoseItFroze() {
        let activeSpaceId = UUID(), hiddenSpaceId = UUID()
        let visible = Tab(id: UUID(), url: URL(string: "https://visible.example"), title: "Visible", spaceId: activeSpaceId)
        let idle = Tab(id: UUID(), url: URL(string: "https://idle.example"), title: "Idle", spaceId: activeSpaceId)
        let hidden = Tab(id: UUID(), url: URL(string: "https://hidden.example"), title: "Hidden", spaceId: hiddenSpaceId)
        let engines = (0..<3).map { _ in WKWebViewTab(configuration: WKWebViewConfiguration()) }
        let store = BrowserStateStore()
        store.storeActiveSpace(
            id: activeSpaceId,
            snapshot: makeSpaceSnapshot(
                tabs: [visible, idle], folders: [], treeItems: [],
                engines: [visible.id: engines[0], idle.id: engines[1]], activeTabId: visible.id, lastAccessedAt: Date()
            )
        )
        store.storeSpace(
            id: hiddenSpaceId,
            snapshot: makeSpaceSnapshot(tabs: [hidden], folders: [], treeItems: [], engines: [hidden.id: engines[2]], activeTabId: hidden.id, lastAccessedAt: Date())
        )
        engines[1].freeze()

        let frozen = store.freezeAllEngines()

        XCTAssertEqual(Set(frozen.map(ObjectIdentifier.init)), Set([engines[0], engines[2]].map(ObjectIdentifier.init)))
        XCTAssertTrue(engines.allSatisfy(\.isFrozen), "the visible tab too: nobody sees it with the lid closed")
    }

    func testProcessSnapshotReportsFrozenHiddenEngineAsFrozen() throws {
        let activeSpaceId = UUID()
        let hiddenSpaceId = UUID()
        let tabId = UUID()
        let tab = Tab(id: tabId, url: URL(string: "https://example.com"), title: "Example", spaceId: hiddenSpaceId)
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        engine.freeze()
        let store = BrowserStateStore()
        store.storeSpace(
            id: hiddenSpaceId,
            snapshot: makeSpaceSnapshot(tabs: [tab], folders: [], treeItems: [], engines: [tabId: engine], activeTabId: tabId, lastAccessedAt: Date())
        )
        store.storeActiveSpace(
            id: activeSpaceId,
            snapshot: makeSpaceSnapshot(tabs: [], folders: [], treeItems: [], engines: [:])
        )

        let processes = store.processSnapshot(diagnosticsProvider: { _ in WebViewProcessDiagnostics(webProcessIdentifier: 101) })

        let webProcess = try XCTUnwrap(processes.first { $0.kind == .webContent })
        XCTAssertEqual(webProcess.tabs.first?.id, tabId)
        XCTAssertEqual(webProcess.tabs.first?.lifecycle, "frozen")
    }

    func testFrozenHiddenEngineStillCountsAsNormalRetainedEngine() {
        let activeSpaceId = UUID()
        let hiddenSpaceId = UUID()
        let tabId = UUID()
        let tab = Tab(id: tabId, url: URL(string: "https://example.com"), title: "Example", spaceId: hiddenSpaceId)
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        engine.freeze()
        let store = BrowserStateStore()
        store.storeSpace(
            id: hiddenSpaceId,
            snapshot: makeSpaceSnapshot(tabs: [tab], folders: [], treeItems: [], engines: [tabId: engine], activeTabId: tabId, lastAccessedAt: Date())
        )
        store.storeActiveSpace(
            id: activeSpaceId,
            snapshot: makeSpaceSnapshot(tabs: [], folders: [], treeItems: [], engines: [:])
        )

        // A frozen engine is still a live, normally-retained engine, the diagnostic must still count it.
        XCTAssertEqual(store.lifecycleDiagnostics().hiddenSpacesWithNormalRetainedEngines, 1)
    }

    func testLifecycleDiagnosticsCountsActiveHiddenRestoringAndDiscardedTabs() {
        let activeSpaceId = UUID()
        let hiddenSpaceId = UUID()
        let activeTabId = UUID()
        let hiddenLoadedTabId = UUID()
        let hiddenRestoringTabId = UUID()
        let hiddenDiscardedTabId = UUID()
        let restorationStartedAt = Date(timeIntervalSince1970: 10)
        let activeEngine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let hiddenEngine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let store = BrowserStateStore()

        store.storeActiveSpace(
            id: activeSpaceId,
            snapshot: makeSpaceSnapshot(
                tabs: [
                    Tab(id: activeTabId, url: URL(string: "https://active.example"), title: "Active", spaceId: activeSpaceId)
                ],
                folders: [],
                treeItems: [],
                engines: [activeTabId: activeEngine],
                activeTabId: activeTabId,
                spaceId: activeSpaceId
            )
        )
        store.storeSpace(
            id: hiddenSpaceId,
            snapshot: makeSpaceSnapshot(
                tabs: [
                    Tab(id: hiddenLoadedTabId, url: URL(string: "https://loaded.example"), title: "Loaded", spaceId: hiddenSpaceId),
                    Tab(id: hiddenRestoringTabId, url: URL(string: "https://restoring.example"), title: "Restoring", spaceId: hiddenSpaceId),
                    Tab(id: hiddenDiscardedTabId, url: URL(string: "https://discarded.example"), title: "Discarded", spaceId: hiddenSpaceId)
                ],
                folders: [],
                treeItems: [],
                engines: [hiddenLoadedTabId: hiddenEngine],
                interactionStates: [hiddenDiscardedTabId: "state"],
                restoringTabIds: [hiddenRestoringTabId: restorationStartedAt],
                activeTabId: hiddenLoadedTabId,
                spaceId: hiddenSpaceId
            )
        )

        let diagnostics = store.lifecycleDiagnostics()

        XCTAssertEqual(diagnostics.trackedSpaceCount, 2)
        XCTAssertEqual(diagnostics.activeSpaceEngineCount, 1)
        XCTAssertEqual(diagnostics.hiddenSpaceEngineCount, 1)
        XCTAssertEqual(diagnostics.totalLiveEngineCount, 2)
        XCTAssertEqual(diagnostics.restoringTabCount, 1)
        XCTAssertEqual(diagnostics.savedInteractionStateCount, 1)
        XCTAssertEqual(diagnostics.discardedOpenTabCount, 1)
        XCTAssertEqual(diagnostics.hiddenSpacesWithNormalRetainedEngines, 1)
    }

    // MARK: - Busy background engines

    func testBusyBackgroundEngineIsDiscardedOnSecondBusySweepOnly() {
        let store = BrowserStateStore()
        store.storeActiveSpace(id: UUID(), snapshot: makeSpaceSnapshot(tabs: [], folders: [], treeItems: [], engines: [:]))
        let spaceId = UUID()
        let ids = seedIdleHiddenSpace(store, spaceId: spaceId, count: 2)   // ids[0] busy, ids[1] quiet
        let cpu: [UUID: WebContentCPUSampler.EngineUsage] = [
            ids[0]: .init(pid: 10, percent: 80),
            ids[1]: .init(pid: 11, percent: 2)
        ]
        var previouslyBusy: Set<UUID> = []
        var discarded: [WKWebViewTab] = []
        let sweep = {
            store.discardBusyBackgroundEngines(
                maxCPUPercent: 30,
                maxFootprintBytes: .max,
                previouslyBusyTabIds: &previouslyBusy,
                cpuSampler: { _ in cpu },
                discardEngine: { discarded.append($0); return nil }
            )
        }

        sweep()
        XCTAssertTrue(discarded.isEmpty, "one busy sweep may be work the tab did while it was visible")
        sweep()
        XCTAssertNil(store.space(id: spaceId)?.engines[ids[0]], "busy on two sweeps in a row")
        XCTAssertNotNil(store.space(id: spaceId)?.engines[ids[1]])
        XCTAssertEqual(discarded.count, 1)
    }

    func testHeavyBackgroundEngineIsDiscardedOnSecondHeavySweepOnly() {
        let store = BrowserStateStore()
        store.storeActiveSpace(id: UUID(), snapshot: makeSpaceSnapshot(tabs: [], folders: [], treeItems: [], engines: [:]))
        let spaceId = UUID()
        let ids = seedIdleHiddenSpace(store, spaceId: spaceId, count: 2)   // ids[0] heavy, ids[1] light
        let usage: [UUID: WebContentCPUSampler.EngineUsage] = [
            ids[0]: .init(pid: 10, percent: 0, footprint: 3 << 30),
            ids[1]: .init(pid: 11, percent: 0, footprint: 200 << 20)
        ]
        var previouslyBusy: Set<UUID> = []
        var discarded: [WKWebViewTab] = []
        let sweep = {
            store.discardBusyBackgroundEngines(
                maxCPUPercent: 30,
                maxFootprintBytes: 2 << 30,
                previouslyBusyTabIds: &previouslyBusy,
                cpuSampler: { _ in usage },
                discardEngine: { discarded.append($0); return nil }
            )
        }

        sweep()
        XCTAssertTrue(discarded.isEmpty, "one heavy sweep may be a peak of the page's work")
        sweep()
        XCTAssertNil(store.space(id: spaceId)?.engines[ids[0]], "heavy on two sweeps in a row")
        XCTAssertNotNil(store.space(id: spaceId)?.engines[ids[1]])
        XCTAssertEqual(discarded.count, 1)
    }

    func testBusyEngineSharingProcessWithVisibleTabIsKept() {
        let activeSpaceId = UUID()
        let hiddenSpaceId = UUID()
        let visibleTabId = UUID()
        let backgroundTabId = UUID()
        let visible = Tab(id: visibleTabId, url: URL(string: "https://visible.example"), title: "Visible", spaceId: activeSpaceId)
        var background = Tab(id: backgroundTabId, url: URL(string: "https://bg.example"), title: "Background", spaceId: hiddenSpaceId)
        background.lastActiveAt = Date(timeIntervalSince1970: 1)
        let store = BrowserStateStore()
        store.runtimeOverlay.setRuntimeState(from: visible)
        store.runtimeOverlay.setRuntimeState(from: background)
        store.storeActiveSpace(
            id: activeSpaceId,
            snapshot: makeSpaceSnapshot(
                tabs: [visible], folders: [], treeItems: [],
                engines: [visibleTabId: WKWebViewTab(configuration: WKWebViewConfiguration())],
                activeTabId: visibleTabId, lastAccessedAt: Date(), spaceId: activeSpaceId
            )
        )
        store.storeSpace(
            id: hiddenSpaceId,
            snapshot: makeSpaceSnapshot(
                tabs: [background], folders: [], treeItems: [],
                engines: [backgroundTabId: WKWebViewTab(configuration: WKWebViewConfiguration())],
                lastAccessedAt: Date(), spaceId: hiddenSpaceId
            )
        )
        let shared: [UUID: WebContentCPUSampler.EngineUsage] = [
            visibleTabId: .init(pid: 10, percent: 90),
            backgroundTabId: .init(pid: 10, percent: 90)
        ]
        var previouslyBusy: Set<UUID> = []
        for _ in 0..<3 {
            store.discardBusyBackgroundEngines(
                maxCPUPercent: 30,
                maxFootprintBytes: .max,
                previouslyBusyTabIds: &previouslyBusy,
                cpuSampler: { _ in shared },
                discardEngine: { _ in XCTFail("the load of a shared process cannot be pinned on the background tab"); return nil }
            )
        }
        XCTAssertNotNil(store.space(id: hiddenSpaceId)?.engines[backgroundTabId])
        XCTAssertNotNil(store.space(id: activeSpaceId)?.engines[visibleTabId])
    }

    func testStoreDiscardPassesLeaveVisibleSpaceEnginesToTheWindow() {
        let activeSpaceId = UUID()
        let visibleTabId = UUID()
        let backgroundTabId = UUID()
        let visible = Tab(id: visibleTabId, url: URL(string: "https://visible.example"), title: "Visible", spaceId: activeSpaceId)
        var background = Tab(id: backgroundTabId, url: URL(string: "https://bg.example"), title: "Background", spaceId: activeSpaceId)
        background.lastActiveAt = Date(timeIntervalSince1970: 1)
        let store = BrowserStateStore()
        store.runtimeOverlay.setRuntimeState(from: visible)
        store.runtimeOverlay.setRuntimeState(from: background)
        store.storeActiveSpace(
            id: activeSpaceId,
            snapshot: makeSpaceSnapshot(
                tabs: [visible, background], folders: [], treeItems: [],
                engines: [
                    visibleTabId: WKWebViewTab(configuration: WKWebViewConfiguration()),
                    backgroundTabId: WKWebViewTab(configuration: WKWebViewConfiguration())
                ],
                activeTabId: visibleTabId, lastAccessedAt: Date(), spaceId: activeSpaceId
            )
        )
        let cpu: [UUID: WebContentCPUSampler.EngineUsage] = [
            visibleTabId: .init(pid: 10, percent: 1),
            backgroundTabId: .init(pid: 11, percent: 90)
        ]
        var previouslyBusy: Set<UUID> = []
        for _ in 0..<3 {
            store.discardBusyBackgroundEngines(
                maxCPUPercent: 30,
                maxFootprintBytes: .max,
                previouslyBusyTabIds: &previouslyBusy,
                cpuSampler: { _ in cpu },
                discardEngine: { _ in XCTFail("the window's EngineHost still holds a visible space's engines"); return nil }
            )
        }
        let footprintTotals = store.trimEnginesExceedingFootprintCeiling(
            ceilingBytes: 1,
            discardEngine: { _ in XCTFail("the window's EngineHost still holds a visible space's engines"); return nil },
            footprintSampler: { engines in engines.mapValues { _ in UInt64(1_000) } }
        )
        XCTAssertEqual(footprintTotals.remaining, 2_000, "the excess is left for the window's own trim")
        XCTAssertNotNil(store.space(id: activeSpaceId)?.engines[backgroundTabId])
    }

    // MARK: - Footprint ceiling

    /// Builds a hidden space of `count` idle engines with strictly increasing lastActiveAt
    /// (index 0 is the oldest). Returns the ordered tab ids.
    @MainActor
    private func seedIdleHiddenSpace(_ store: BrowserStateStore, spaceId: UUID, count: Int) -> [UUID] {
        var tabs: [Tab] = []
        var engines: [UUID: WKWebViewTab] = [:]
        var ids: [UUID] = []
        for index in 0..<count {
            let tabId = UUID()
            var tab = Tab(id: tabId, url: URL(string: "https://tab-\(index).example"), title: "Tab \(index)", spaceId: spaceId)
            tab.lastActiveAt = Date(timeIntervalSince1970: Double(index + 1))
            store.runtimeOverlay.setRuntimeState(from: tab)
            tabs.append(tab)
            engines[tabId] = WKWebViewTab(configuration: WKWebViewConfiguration())
            ids.append(tabId)
        }
        store.storeSpace(
            id: spaceId,
            snapshot: makeSpaceSnapshot(tabs: tabs, folders: [], treeItems: [], engines: engines, lastAccessedAt: Date(), spaceId: spaceId)
        )
        return ids
    }

    func testFootprintTrimUnderCeilingDiscardsNothing() {
        let store = BrowserStateStore()
        store.storeActiveSpace(id: UUID(), snapshot: makeSpaceSnapshot(tabs: [], folders: [], treeItems: [], engines: [:]))
        let spaceId = UUID()
        let ids = seedIdleHiddenSpace(store, spaceId: spaceId, count: 3)

        var sampleCount = 0
        let footprint = Dictionary(uniqueKeysWithValues: ids.map { ($0, UInt64(100)) })

        var discardCount = 0
        store.trimEnginesExceedingFootprintCeiling(
            ceilingBytes: 1_000,   // sum is 300, well under
            discardEngine: { _ in discardCount += 1; return nil },
            footprintSampler: { _ in sampleCount += 1; return footprint }
        )

        XCTAssertEqual(discardCount, 0)
        XCTAssertEqual(sampleCount, 1, "the sweep must sample at most once")
        for id in ids { XCTAssertNotNil(store.space(id: spaceId)?.engines[id]) }
    }

    func testFootprintTrimOverCeilingEvictsOldestIdleEnginesUntilUnderCeiling() {
        let store = BrowserStateStore()
        store.storeActiveSpace(id: UUID(), snapshot: makeSpaceSnapshot(tabs: [], folders: [], treeItems: [], engines: [:]))
        let spaceId = UUID()
        let ids = seedIdleHiddenSpace(store, spaceId: spaceId, count: 3)   // ids[0] oldest ... ids[2] newest

        var sampleCount = 0
        let footprint = Dictionary(uniqueKeysWithValues: ids.map { ($0, UInt64(100)) })   // total 300

        var discardCount = 0
        let footprintTotals = store.trimEnginesExceedingFootprintCeiling(
            ceilingBytes: 150,   // must drop the two oldest (300 -> 200 -> 100) to fall under
            discardEngine: { _ in discardCount += 1; return nil },
            footprintSampler: { _ in sampleCount += 1; return footprint }
        )

        XCTAssertEqual(footprintTotals.total, 300)
        XCTAssertEqual(footprintTotals.remaining, 100)
        XCTAssertEqual(sampleCount, 1)
        XCTAssertEqual(discardCount, 2)
        XCTAssertNil(store.space(id: spaceId)?.engines[ids[0]], "oldest evicted first")
        XCTAssertNil(store.space(id: spaceId)?.engines[ids[1]])
        XCTAssertNotNil(store.space(id: spaceId)?.engines[ids[2]], "newest kept once under the ceiling")
    }

    func testFootprintTrimNeverDiscardsActivePinnedOrProtectedTabs() {
        let store = BrowserStateStore()
        let activeSpaceId = UUID()
        let hiddenSpaceId = UUID()

        let visibleTabId = UUID()
        var visible = Tab(id: visibleTabId, url: URL(string: "https://visible.example"), title: "Visible", spaceId: activeSpaceId)
        visible.lastActiveAt = Date(timeIntervalSince1970: 1)   // ancient, but the visible active tab is protected
        store.runtimeOverlay.setRuntimeState(from: visible)
        store.storeActiveSpace(
            id: activeSpaceId,
            snapshot: makeSpaceSnapshot(
                tabs: [visible], folders: [], treeItems: [],
                engines: [visibleTabId: WKWebViewTab(configuration: WKWebViewConfiguration())],
                activeTabId: visibleTabId, spaceId: activeSpaceId
            )
        )

        let pinnedTabId = UUID()
        let audioTabId = UUID()
        let normalTabId = UUID()
        var pinned = Tab(id: pinnedTabId, url: URL(string: "https://pinned.example"), title: "Pinned", isPinned: true, spaceId: hiddenSpaceId)
        pinned.lastActiveAt = Date(timeIntervalSince1970: 1)
        var audio = Tab(id: audioTabId, url: URL(string: "https://audio.example"), title: "Audio", spaceId: hiddenSpaceId)
        audio.lastActiveAt = Date(timeIntervalSince1970: 1); audio.isAudioPlaying = true
        var normal = Tab(id: normalTabId, url: URL(string: "https://normal.example"), title: "Normal", spaceId: hiddenSpaceId)
        normal.lastActiveAt = Date(timeIntervalSince1970: 2)
        for tab in [pinned, audio, normal] { store.runtimeOverlay.setRuntimeState(from: tab) }
        store.storeSpace(
            id: hiddenSpaceId,
            snapshot: makeSpaceSnapshot(
                tabs: [pinned, audio, normal], folders: [], treeItems: [],
                engines: [
                    pinnedTabId: WKWebViewTab(configuration: WKWebViewConfiguration()),
                    audioTabId: WKWebViewTab(configuration: WKWebViewConfiguration()),
                    normalTabId: WKWebViewTab(configuration: WKWebViewConfiguration())
                ],
                lastAccessedAt: Date(), spaceId: hiddenSpaceId
            )
        )

        let allIds = [visibleTabId, pinnedTabId, audioTabId, normalTabId]
        let footprint = Dictionary(uniqueKeysWithValues: allIds.map { ($0, UInt64(1_000)) })

        var discardCount = 0
        store.trimEnginesExceedingFootprintCeiling(
            ceilingBytes: 100,   // hugely exceeded: only the unprotected normal tab may be evicted
            discardEngine: { _ in discardCount += 1; return nil },
            footprintSampler: { _ in footprint }
        )

        XCTAssertEqual(discardCount, 1)
        XCTAssertNil(store.space(id: hiddenSpaceId)?.engines[normalTabId])
        XCTAssertNotNil(store.space(id: activeSpaceId)?.engines[visibleTabId], "visible active tab must never be discarded")
        XCTAssertNotNil(store.space(id: hiddenSpaceId)?.engines[pinnedTabId], "pinned tab must never be discarded")
        XCTAssertNotNil(store.space(id: hiddenSpaceId)?.engines[audioTabId], "audio tab must never be discarded")
    }

    func testImportSidebarNodesAppendsSubtreesInOneMutation() throws {
        let spaceId = UUID()
        let store = BrowserStateStore()
        store.storeSpace(
            id: spaceId,
            snapshot: BrowserStateStore.SpaceSnapshot(
                spaceTab: SpaceTab(spaceId: spaceId, state: SpaceTabState(activeTabId: nil, activationHistory: [], tree: .empty)),
                engines: [:]
            )
        )
        let tab = StoredTab(id: UUID(), url: "https://a.example", title: "A", faviconDataURL: nil, faviconDominantColor: nil,
                            isPinned: false, isBookmarked: false, isClosed: true, homeURL: "https://a.example", homeTitle: "A",
                            homeFaviconDataURL: nil, homeFaviconDominantColor: nil)
        let child = StoredTab(id: UUID(), url: "https://b.example", title: "B", faviconDataURL: nil, faviconDominantColor: nil,
                              isPinned: false, isBookmarked: false, isClosed: true, homeURL: "https://b.example", homeTitle: "B",
                              homeFaviconDataURL: nil, homeFaviconDominantColor: nil)
        let folder = StoredFolder(id: UUID(), name: "Work", color: "#6d5ae6", isCollapsed: true, children: [.tab(child)])

        _ = try store.mutate(.importSidebarNodes(spaceId: spaceId, nodes: [.tab(tab), .folder(folder)], section: .pinned))

        let tree = try XCTUnwrap(store.space(id: spaceId)?.spaceTab.state.tree)
        XCTAssertEqual(tree.pinned.map(\.id), [tab.id, folder.id])
        guard case let .tab(stored) = tree.pinned[0] else { return XCTFail("expected a tab") }
        XCTAssertTrue(stored.isPinned)
    }


    func testImportedOpenTabsDoNotBecomeActive() throws {
        let spaceId = UUID()
        let store = BrowserStateStore()
        store.storeSpace(
            id: spaceId,
            snapshot: BrowserStateStore.SpaceSnapshot(
                spaceTab: SpaceTab(spaceId: spaceId, state: SpaceTabState(activeTabId: nil, activationHistory: [], tree: .empty)),
                engines: [:]
            )
        )
        let open = StoredTab(id: UUID(), url: "https://open.example", title: "Open", faviconDataURL: nil, faviconDominantColor: nil,
                             isPinned: false, isBookmarked: false, isClosed: false, homeURL: nil, homeTitle: nil,
                             homeFaviconDataURL: nil, homeFaviconDominantColor: nil)

        _ = try store.mutate(.importSidebarNodes(spaceId: spaceId, nodes: [.tab(open)], section: .unpinned))

        let state = try XCTUnwrap(store.space(id: spaceId)?.spaceTab.state)
        XCTAssertEqual(state.tree.unpinned.map(\.id), [open.id])
        XCTAssertNil(state.activeTabId, "nothing starts loading behind the onboarding")
    }


    // MARK: - Visible spaces

    /// Two windows can each show a space: neither space is trimmed as hidden.
    func testTrimNeverDiscardsAnyVisibleSpace() {
        let spaceA = UUID(), spaceB = UUID(), tabA = UUID(), tabB = UUID()
        let engineA = WKWebViewTab(configuration: WKWebViewConfiguration())
        let engineB = WKWebViewTab(configuration: WKWebViewConfiguration())
        let store = BrowserStateStore()
        store.storeActiveSpace(id: spaceA, snapshot: makeSpaceSnapshot(
            tabs: [Tab(id: tabA, url: URL(string: "https://a.example"), title: "A", spaceId: spaceA)],
            folders: [], treeItems: [], engines: [tabA: engineA], activeTabId: tabA
        ))
        store.storeActiveSpace(id: spaceB, snapshot: makeSpaceSnapshot(
            tabs: [Tab(id: tabB, url: URL(string: "https://b.example"), title: "B", spaceId: spaceB)],
            folders: [], treeItems: [], engines: [tabB: engineB], activeTabId: tabB
        ))

        store.trimInactiveEngines(
            excluding: nil,
            policy: .foreground,
            maxRetainedEnginesPerHiddenSpace: 0,
            maxHiddenSpacesWithRetainedEngines: 0,
            discardEngine: { _ in nil }
        )

        XCTAssertEqual(store.visibleSpaceIds, [spaceA, spaceB])
        XCTAssertTrue(store.space(id: spaceA)?.engines[tabA] === engineA)
        XCTAssertTrue(store.space(id: spaceB)?.engines[tabB] === engineB)
    }

    func testParkingASpaceLeavesTheOtherVisibleSpaces() {
        let spaceA = UUID(), spaceB = UUID()
        let store = BrowserStateStore()
        _ = store.activateSpace(id: spaceA) { makeSpaceSnapshot(tabs: [], folders: [], treeItems: [], engines: [:]) }
        _ = store.activateSpace(id: spaceB) { makeSpaceSnapshot(tabs: [], folders: [], treeItems: [], engines: [:]) }

        store.cacheInactiveSpaceRuntime(
            id: spaceA,
            runtime: TabRuntimeSnapshot(tabs: [], engines: [:], savedInteractionStates: [:], restoringTabIds: [:], activeTabId: nil),
            folders: [],
            treeItems: []
        )

        XCTAssertEqual(store.visibleSpaceIds, [spaceB])
    }


    /// A tab another window displays is on screen even when it is not the space's last activated tab.
    func testFreezeNeverFreezesATabDisplayedInAnyWindow() {
        let spaceId = UUID(), activeTabId = UUID(), displayedTabId = UUID()
        var active = Tab(id: activeTabId, url: URL(string: "https://a.example"), title: "A", spaceId: spaceId)
        active.lastActiveAt = Date(timeIntervalSince1970: 1)
        var displayed = Tab(id: displayedTabId, url: URL(string: "https://b.example"), title: "B", spaceId: spaceId)
        displayed.lastActiveAt = Date(timeIntervalSince1970: 1)
        let displayedEngine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let store = BrowserStateStore()
        store.runtimeOverlay.setRuntimeState(from: active)
        store.runtimeOverlay.setRuntimeState(from: displayed)
        store.storeActiveSpace(id: spaceId, snapshot: makeSpaceSnapshot(
            tabs: [active, displayed], folders: [], treeItems: [],
            engines: [displayedTabId: displayedEngine], activeTabId: activeTabId, lastAccessedAt: Date()
        ))
        store.displayedTabIds = [displayedTabId]

        store.freezeIdleEngines(freezeThreshold: 60)

        XCTAssertFalse(displayedEngine.isFrozen)
    }

}
