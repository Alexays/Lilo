import XCTest
import GRDB
@testable import Lilo

@MainActor
final class SessionPersistenceTests: XCTestCase {

    private var globalDBPool: DatabasePool!
    private var profileDBPool: DatabasePool!
    private var testDirectory: URL!
    private var profile: Profile!
    private var space: Space!
    private var tabManager: TabManager!
    private var spaceManager: SpaceManager!
    private var persistence: SessionPersistence!

    override func setUpWithError() throws {
        let testsDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("lilo-session-persistence-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: testsDirectory, withIntermediateDirectories: true)

        testDirectory = testsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)

        globalDBPool = try DatabasePool(path: testDirectory.appendingPathComponent("global.db").path)
        profileDBPool = try DatabasePool(path: testDirectory.appendingPathComponent("profile.db").path)
        try Migrations.migrateGlobal(globalDBPool)
        try Migrations.migrateProfile(profileDBPool)

        profile = Profile(name: "Test Profile")
        space = Space(name: "Test Space", profileId: profile.id)

        try globalDBPool.write { db in
            try profile.insert(db)
            try space.insert(db)
        }

        tabManager = TabManager(engineFactory: WKEngineFactory())
        tabManager.currentSpaceId = space.id

        spaceManager = SpaceManager(dbPool: globalDBPool)
        spaceManager.loadSpaces([space])
        spaceManager.activeSpaceId = space.id

        persistence = SessionPersistence(
            tabDBPool: profileDBPool,
            displayedSpaceIds: { [spaceManager] in spaceManager?.activeSpaceId.map { [$0] } ?? [] },
            stateProvider: { [tabManager] spaceId in
                tabManager?.spaceTabState(forSpace: spaceId)
                    ?? SpaceTabState(activeTabId: nil, activationHistory: [], tree: .empty)
            },
            dedupKeyProvider: { _ in nil }
        )
    }

    override func tearDownWithError() throws {
        persistence = nil
        spaceManager = nil
        tabManager = nil
        profile = nil
        space = nil
        try? globalDBPool?.close()
        try? profileDBPool?.close()
        globalDBPool = nil
        profileDBPool = nil

        if let testDirectory {
            try? FileManager.default.removeItem(at: testDirectory)
        }
        testDirectory = nil
    }

    /// Spins the run loop in 10 ms ticks until `condition` returns false or `deadline` is reached.
    private func spin(until deadline: Date, while condition: () -> Bool) {
        while condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Spins the run loop for a fixed `duration` (always burns the full period). Use for grace periods
    /// where no early-exit condition exists and the absence of an event must be verified.
    private func spin(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func waitForStoredFolders(in spaceId: UUID, count: Int, timeout: TimeInterval = 1.0) throws -> [TabFolder] {
        let deadline = Date().addingTimeInterval(timeout)
        var lastFolders: [TabFolder] = []

        repeat {
            lastFolders = try restore(spaceId: spaceId, activeTabId: nil)
                .sidebarOrderedFolders()

            if lastFolders.count == count {
                return lastFolders
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline

        return lastFolders
    }

    /// Loads the persisted state once every write already queued on the serial writer has run.
    /// Reads the store directly: `restoreSpaceTabState` would reseed the dedup cache.
    private func persistedState(of spaceId: UUID) throws -> SpaceTabState? {
        try profileDBPool.writeWithoutTransaction { _ in }
        return try SpaceTabStateStore(dbPool: profileDBPool).load(spaceId: spaceId)
    }

    private func persistedFolderNames(in spaceId: UUID) throws -> [String]? {
        try persistedState(of: spaceId)?
            .browserStateFixture(spaceId: spaceId, preferredActiveTabId: nil)
            .sidebarOrderedFolders()
            .map(\.name)
    }

    /// Makes every write to the space tab state table fail, like a disk or I/O error would.
    private func setStateWritesFailing(_ failing: Bool) throws {
        try profileDBPool.write { db in
            if failing {
                try db.execute(sql: """
                    CREATE TRIGGER failStateWrites BEFORE INSERT ON spaceTabStates
                    BEGIN SELECT RAISE(ABORT, 'simulated failure'); END
                    """)
            } else {
                try db.execute(sql: "DROP TRIGGER failStateWrites")
            }
        }
    }

    private func save(_ state: BrowserStateFixture) throws {
        try persistence.saveSpaceTabState(SpaceTabState(state), spaceId: state.spaceId)
    }

    private func save(_ states: [BrowserStateFixture]) throws {
        try persistence.saveSpaceTabStates(states.map { (spaceId: $0.spaceId, state: SpaceTabState($0)) })
    }

    private func restore(spaceId: UUID, activeTabId: UUID?) throws -> BrowserStateFixture {
        try persistence
            .restoreSpaceTabState(forSpace: spaceId)
            .browserStateFixture(spaceId: spaceId, preferredActiveTabId: activeTabId)
    }

    private func makeTreeItems(spaceId: UUID, folderId: UUID, tabId: UUID) -> [TabTreeItem] {
        [
            TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folderId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
            TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: folderId, section: .unpinned, sortOrder: 0)
        ]
    }

    private func folderedState(tab: Tab, folder: TabFolder) throws -> BrowserStateFixture {
        var folderedTab = tab
        folderedTab.groupId = folder.id
        return try BrowserStateFixture(
            spaceId: space.id,
            activeTabId: tab.id,
            tabs: [folderedTab],
            folders: [folder],
            treeItems: makeTreeItems(spaceId: space.id, folderId: folder.id, tabId: tab.id)
        )
    }

    func testFolderChangesSchedulePersistenceAndSaveToSQLite() throws {
        let folder = try tabManager.installFolderForTests(spaceId: space.id, name: "Pinned", color: "#ff0000")

        persistence.scheduleSave()
        persistence.saveNow()

        let savedFolders = try waitForStoredFolders(in: space.id, count: 1)

        XCTAssertEqual(savedFolders.count, 1)
        XCTAssertEqual(savedFolders.first?.id, folder.id)
        XCTAssertEqual(savedFolders.first?.name, "Pinned")
        XCTAssertEqual(savedFolders.first?.color, "#ff0000")
    }

    func testScheduleSaveSkipsUnchangedSnapshot() throws {
        try tabManager.installFolderForTests(spaceId: space.id, name: "Pinned", color: "#ff0000")

        persistence.scheduleSave()
        persistence.saveNow()
        XCTAssertEqual(try persistedFolderNames(in: space.id), ["Pinned"])

        // Deleting the row behind the cache's back exposes any write: an unchanged snapshot
        // must not be enqueued again, so the flush writes nothing.
        try SpaceTabStateStore(dbPool: profileDBPool).delete(spaceId: space.id)
        persistence.scheduleSave()
        persistence.saveNow()
        XCTAssertNil(try persistedState(of: space.id))
    }

    func testScheduleSaveEnqueuesAfterStateChanges() throws {
        try tabManager.installFolderForTests(spaceId: space.id, name: "Pinned", color: "#ff0000")
        persistence.scheduleSave()
        persistence.saveNow()
        XCTAssertEqual(try persistedFolderNames(in: space.id), ["Pinned"])

        // A real change (new folder) must defeat the dedup cache and enqueue again.
        try tabManager.installFolderForTests(spaceId: space.id, name: "Second", color: "#00ff00")
        persistence.scheduleSave()
        persistence.saveNow()
        XCTAssertEqual(try persistedFolderNames(in: space.id)?.count, 2)
    }

    func testScheduleSaveDedupKeyShortCircuitsBeforeStateProvider() throws {
        let spaceId = UUID()
        let tabId = UUID()
        var tabTitle = "T"
        var revision: UInt64 = 0
        let token = UUID()
        var providerCallCount = 0
        let dedupPersistence = SessionPersistence(
            tabDBPool: profileDBPool,
            displayedSpaceIds: { [spaceId] },
            stateProvider: { _ in
                providerCallCount += 1
                return SpaceTabStateImporter.importState(
                    activeTabId: tabId,
                    activationHistory: [],
                    tabs: [Tab(id: tabId, url: URL(string: "https://example.com"), title: tabTitle, spaceId: spaceId)],
                    folders: [],
                    treeItems: [TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)],
                    spaceId: spaceId
                )
            },
            dedupKeyProvider: { _ in
                SessionPersistence.SaveDedupKey(spaceId: spaceId, structureToken: token, durableRevision: revision)
            }
        )

        // First schedule: the key is unseen, so it falls through, runs the provider and enqueues.
        dedupPersistence.scheduleSave()
        XCTAssertEqual(providerCallCount, 1)
        dedupPersistence.saveNow()
        let persistedTitle = {
            try self.persistedState(of: spaceId)?
                .browserStateFixture(spaceId: spaceId, preferredActiveTabId: tabId)
                .tabsById[tabId]?.title
        }
        XCTAssertEqual(try persistedTitle(), "T")

        // Unchanged revision: the fast path short-circuits BEFORE the state provider is called again,
        // and enqueues nothing (the deleted row stays absent after the flush).
        try SpaceTabStateStore(dbPool: profileDBPool).delete(spaceId: spaceId)
        dedupPersistence.scheduleSave()
        XCTAssertEqual(providerCallCount, 1, "Unchanged dedup key must skip the state-provider rebuild")
        dedupPersistence.saveNow()
        XCTAssertNil(try persistedState(of: spaceId))

        // Bumping the revision alongside a real state change must defeat the fast path and re-enqueue.
        revision += 1
        tabTitle = "Renamed"
        dedupPersistence.scheduleSave()
        XCTAssertEqual(providerCallCount, 2, "A bumped revision must re-run the provider")
        dedupPersistence.saveNow()
        XCTAssertEqual(try persistedTitle(), "Renamed")
    }

    /// A space reloaded into the store (moved between profiles, re-entered) restarts its revision count:
    /// its new structure token keeps the first save of the reloaded space from being skipped.
    func testReloadedSpaceWithARestartedRevisionStillSaves() throws {
        let spaceId = UUID()
        let tabId = UUID()
        var title = "Before"
        var token = UUID()
        let persistence = SessionPersistence(
            tabDBPool: profileDBPool,
            displayedSpaceIds: { [spaceId] },
            stateProvider: { _ in
                SpaceTabStateImporter.importState(
                    activeTabId: tabId,
                    activationHistory: [],
                    tabs: [Tab(id: tabId, url: URL(string: "https://example.com"), title: title, spaceId: spaceId)],
                    folders: [],
                    treeItems: [TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)],
                    spaceId: spaceId
                )
            },
            dedupKeyProvider: { _ in SessionPersistence.SaveDedupKey(spaceId: spaceId, structureToken: token, durableRevision: 3) }
        )
        persistence.scheduleSave()
        persistence.saveNow()

        token = UUID()
        title = "After"
        persistence.scheduleSave()
        persistence.saveNow()

        let saved = try persistedState(of: spaceId)?
            .browserStateFixture(spaceId: spaceId, preferredActiveTabId: tabId)
            .tabsById[tabId]?.title
        XCTAssertEqual(saved, "After")
    }

    func testRestoreFoldersLoadsCollapsedFolderState() throws {
        let folder = TabFolder(
            spaceId: space.id,
            name: "Saved Folder",
            color: "#00ff00",
            isCollapsed: true
        )

        try SpaceTabStateStore(dbPool: profileDBPool).saveMany([(
            spaceId: space.id,
            state: SpaceTabState(
                activeTabId: nil,
                activationHistory: [],
                tree: StoredSidebarTree(
                    pinned: [],
                    unpinned: [.folder(StoredFolder(id: folder.id, name: folder.name, color: folder.color, isCollapsed: true, children: []))],
                    bookmarked: []
                )
            )
        )])

        let restoredState = try restore(spaceId: space.id, activeTabId: nil)
        let restoredFolder = restoredState.foldersById[folder.id]

        XCTAssertEqual(restoredState.foldersById.count, 1)
        XCTAssertEqual(restoredFolder?.id, folder.id)
        XCTAssertEqual(restoredFolder?.name, "Saved Folder")
        XCTAssertTrue(restoredFolder?.isCollapsed ?? false)
    }

    func testSaveAndRestoreSpaceTabStatePersistsActivationHistory() throws {
        let firstTabId = UUID()
        let recentTabId = UUID()
        let activeTabId = UUID()
        let tabs = [
            Tab(id: firstTabId, url: URL(string: "https://first.example"), title: "First", spaceId: space.id),
            Tab(id: recentTabId, url: URL(string: "https://recent.example"), title: "Recent", spaceId: space.id),
            Tab(id: activeTabId, url: URL(string: "https://active.example"), title: "Active", spaceId: space.id)
        ]
        let state = try BrowserStateFixture(
            spaceId: space.id,
            activeTabId: activeTabId,
            tabs: tabs,
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: space.id, kind: .tab, itemId: firstTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: space.id, kind: .tab, itemId: recentTabId, parentFolderId: nil, section: .unpinned, sortOrder: 1),
                TabTreeItem(spaceId: space.id, kind: .tab, itemId: activeTabId, parentFolderId: nil, section: .unpinned, sortOrder: 2)
            ],
            activationHistory: [recentTabId, firstTabId]
        )

        try save(state)
        let restored = try restore(spaceId: space.id, activeTabId: activeTabId)

        XCTAssertEqual(restored.activeTabId, activeTabId)
        XCTAssertEqual(restored.activationHistory, [recentTabId, firstTabId])
    }

    func testRestoreSynthesizesSidebarTreeForImportedTabsWithoutTreeItems() throws {
        let folder = TabFolder(spaceId: space.id, name: "Imported Folder", color: "#123456")
        let pinnedTab = Tab(url: URL(string: "https://pinned.example"), title: "Pinned", isPinned: true, spaceId: space.id)
        let childTab = Tab(url: URL(string: "https://child.example"), title: "Child", groupId: folder.id, spaceId: space.id)
        let rootTab = Tab(url: URL(string: "https://root.example"), title: "Root", spaceId: space.id)

        try SpaceTabStateStore(dbPool: profileDBPool).saveMany([(
            spaceId: space.id,
            state: SpaceTabStateImporter.importState(
                activeTabId: rootTab.id,
                activationHistory: [],
                tabs: [pinnedTab, childTab, rootTab],
                folders: [folder],
                treeItems: [],
                spaceId: space.id
            )
        )])

        let restored = try restore(spaceId: space.id, activeTabId: rootTab.id)

        XCTAssertEqual(restored.sidebar.rootNodeIds(in: .pinned), [pinnedTab.id])
        XCTAssertEqual(restored.sidebar.rootNodeIds(in: .unpinned), [folder.id, rootTab.id])
        XCTAssertEqual(restored.sidebar.childNodeIds(of: folder.id), [childTab.id])
        XCTAssertTrue(restored.invariantsHold())
    }

    func testRestoreSynthesizesSidebarTreeWhenPersistedTreeHasNoUsableRoots() throws {
        let tab = Tab(url: URL(string: "https://root.example"), title: "Root", spaceId: space.id)
        let staleTabId = UUID()

        try SpaceTabStateStore(dbPool: profileDBPool).saveMany([(
            spaceId: space.id,
            state: SpaceTabStateImporter.importState(
                activeTabId: tab.id,
                activationHistory: [],
                tabs: [tab],
                folders: [],
                treeItems: [
                    TabTreeItem(
                        spaceId: space.id,
                        kind: .tab,
                        itemId: staleTabId,
                        parentFolderId: nil,
                        section: .unpinned,
                        sortOrder: 0
                    )
                ],
                spaceId: space.id
            )
        )])

        let restored = try restore(spaceId: space.id, activeTabId: tab.id)

        XCTAssertEqual(restored.sidebar.rootNodeIds(in: .unpinned), [tab.id])
        XCTAssertTrue(restored.invariantsHold())
    }

    func testSaveTreeItemsCanonicalizesDuplicateKindAndItemId() throws {
        let itemId = UUID()
        let folderId = UUID()
        let tab = Tab(id: itemId, title: "Duplicate", groupId: folderId, spaceId: space.id)
        let folder = TabFolder(id: folderId, spaceId: space.id, name: "Folder", color: "#123456")
        let treeItems = [
            TabTreeItem(
                id: UUID(),
                spaceId: space.id,
                kind: .tab,
                itemId: itemId,
                parentFolderId: nil,
                section: .unpinned,
                sortOrder: 0
            ),
            TabTreeItem(
                id: UUID(),
                spaceId: space.id,
                kind: .folder,
                itemId: folderId,
                parentFolderId: nil,
                section: .unpinned,
                sortOrder: 1
            ),
            TabTreeItem(
                id: UUID(),
                spaceId: space.id,
                kind: .tab,
                itemId: itemId,
                parentFolderId: folderId,
                section: .unpinned,
                sortOrder: 0
            )
        ]
        let state = try BrowserStateFixture(
            spaceId: space.id,
            activeTabId: itemId,
            tabs: [tab],
            folders: [folder],
            treeItems: treeItems
        )

        try save(state)

        let restored = try restore(spaceId: space.id, activeTabId: itemId)
        XCTAssertEqual(restored.sidebar.treeItems(spaceId: space.id).filter { $0.itemId == itemId }.count, 1)
    }

    func testBrowserStateStoreRetainsTreeItemsSnapshot() throws {
        let folderId = UUID()
        let tabId = UUID()
        let folder = TabFolder(id: folderId, spaceId: space.id, name: "Folder", color: "#ff0000")
        let tab = Tab(id: tabId, url: URL(string: "https://example.com"), title: "Example", groupId: folderId, spaceId: space.id)
        let treeItems = makeTreeItems(spaceId: space.id, folderId: folderId, tabId: tabId)
        let windowController = MainWindowController()
        windowController.context.browserState.storeSpace(
            id: space.id,
            snapshot: BrowserStateStore.SpaceSnapshot(
                spaceTab: SpaceTab(
                    spaceId: space.id,
                    state: SpaceTabStateImporter.importState(
                        activeTabId: nil,
                        activationHistory: [],
                        tabs: [tab],
                        folders: [folder],
                        treeItems: treeItems,
                        spaceId: space.id
                    )
                ),
                engines: [:]
            )
        )

        let cachedTreeItems = windowController.context.browserState.browserSpaceChange(spaceId: space.id)?.projection.treeItems

        XCTAssertEqual(cachedTreeItems?.map(\.kind), [.folder, .tab])
        XCTAssertEqual(cachedTreeItems?.map(\.itemId), [folderId, tabId])
    }

    func testSaveSpaceTabStatePersistsTabsAndFoldersWithoutDebounce() throws {
        let tab = Tab(url: URL(string: "https://example.com"), spaceId: space.id)
        let folder = TabFolder(spaceId: space.id, name: "Pinned", color: "#ff0000")
        let state = try folderedState(tab: tab, folder: folder)

        try save(state)

        let savedState = try restore(spaceId: space.id, activeTabId: tab.id)

        XCTAssertEqual(savedState.tabsById.count, 1)
        XCTAssertEqual(savedState.tabsById[tab.id]?.id, tab.id)
        XCTAssertEqual(savedState.foldersById.count, 1)
        XCTAssertEqual(savedState.foldersById[folder.id]?.id, folder.id)
        XCTAssertEqual(savedState.foldersById[folder.id]?.name, "Pinned")
    }

    func testSaveAndRestoreSpaceTabStatePersistsTabsFoldersTreeAndActiveTab() throws {
        let folderId = UUID()
        let tabId = UUID()
        let tab = Tab(
            id: tabId,
            url: URL(string: "https://state.example"),
            title: "State",
            groupId: folderId,
            spaceId: space.id,
        )
        let folder = TabFolder(
            id: folderId,
            spaceId: space.id,
            name: "State Folder",
            color: "#123456"
        )
        let treeItems = makeTreeItems(spaceId: space.id, folderId: folderId, tabId: tabId)
        let state = try BrowserStateFixture(
            spaceId: space.id,
            activeTabId: tabId,
            tabs: [tab],
            folders: [folder],
            treeItems: treeItems
        )
        try save(state)
        let restored = try restore(spaceId: space.id, activeTabId: tabId)

        XCTAssertEqual(restored.activeTabId, tabId)
        XCTAssertEqual(restored.tabsById[tabId]?.title, "State")
        XCTAssertEqual(restored.foldersById[folderId]?.name, "State Folder")
        XCTAssertEqual(restored.sidebar.rootNodeIds(in: .unpinned), [folderId])
        XCTAssertEqual(restored.sidebar.childNodeIds(of: folderId), [tabId])
    }

    func testFolderLockPersistsButUnlockedStateDoesNot() throws {
        let folderId = UUID()
        let tabId = UUID()
        let tab = Tab(id: tabId, url: URL(string: "https://bank.example"), title: "Bank", groupId: folderId, spaceId: space.id)
        var folder = TabFolder(id: folderId, spaceId: space.id, name: "Finances", color: "#f06aa6")
        folder.lock = FolderLock(allowsBiometrics: true)
        folder.isUnlocked = true
        let state = try BrowserStateFixture(
            spaceId: space.id,
            activeTabId: nil,
            tabs: [tab],
            folders: [folder],
            treeItems: makeTreeItems(spaceId: space.id, folderId: folderId, tabId: tabId)
        )

        try save(state)
        let restored = try restore(spaceId: space.id, activeTabId: nil)

        let restoredFolder = try XCTUnwrap(restored.foldersById[folderId])
        XCTAssertEqual(restoredFolder.lock, FolderLock(allowsBiometrics: true))
        XCTAssertFalse(restoredFolder.isUnlocked, "a relaunch always starts locked")
        XCTAssertTrue(restoredFolder.isLocked)
    }

    func testFolderWithoutLockKeyDecodesAsUnprotected() throws {
        let json = ##"{"id":"\##(UUID().uuidString)","name":"Old","color":"#5865f2","isCollapsed":false,"children":[]}"##
        let folder = try JSONDecoder().decode(StoredFolder.self, from: Data(json.utf8))
        XCTAssertNil(folder.lock)
        XCTAssertFalse(folder.isUnlocked)
    }

    func testSaveAndRestorePreservesSectionedSidebarRoundTrip() throws {
        let pinnedFolderId = UUID()
        let pinnedTabId = UUID()
        let firstChildTabId = UUID()
        let secondChildTabId = UUID()
        let bookmarkedTabId = UUID()
        let rootTabId = UUID()
        let pinnedFolder = TabFolder(
            id: pinnedFolderId,
            spaceId: space.id,
            name: "Pinned Folder",
            color: "#123456"
        )
        let state = try BrowserStateFixture(
            spaceId: space.id,
            activeTabId: rootTabId,
            tabs: [
                Tab(id: pinnedTabId, url: URL(string: "https://pinned.example"), title: "Pinned", isPinned: true, spaceId: space.id),
                Tab(id: firstChildTabId, url: URL(string: "https://first.example"), title: "First", isPinned: true, groupId: pinnedFolderId, spaceId: space.id),
                Tab(id: secondChildTabId, url: URL(string: "https://second.example"), title: "Second", isPinned: true, groupId: pinnedFolderId, spaceId: space.id),
                Tab(id: bookmarkedTabId, url: URL(string: "https://bookmark.example"), title: "Bookmark", isBookmarked: true, spaceId: space.id),
                Tab(id: rootTabId, url: URL(string: "https://root.example"), title: "Root", spaceId: space.id)
            ],
            folders: [pinnedFolder],
            treeItems: [
                TabTreeItem(spaceId: space.id, kind: .tab, itemId: pinnedTabId, parentFolderId: nil, section: .pinned, sortOrder: 0),
                TabTreeItem(spaceId: space.id, kind: .folder, itemId: pinnedFolderId, parentFolderId: nil, section: .pinned, sortOrder: 1),
                TabTreeItem(spaceId: space.id, kind: .tab, itemId: firstChildTabId, parentFolderId: pinnedFolderId, section: .pinned, sortOrder: 0),
                TabTreeItem(spaceId: space.id, kind: .tab, itemId: secondChildTabId, parentFolderId: pinnedFolderId, section: .pinned, sortOrder: 1),
                TabTreeItem(spaceId: space.id, kind: .tab, itemId: rootTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
            ]
        )

        try save(state)
        let restored = try restore(spaceId: space.id, activeTabId: rootTabId)

        XCTAssertEqual(restored.activeTabId, rootTabId)
        XCTAssertEqual(restored.tabsById[bookmarkedTabId]?.isBookmarked, true)
        XCTAssertEqual(restored.sidebar.node(id: bookmarkedTabId)?.section, .bookmarked)
        XCTAssertEqual(restored.sidebar.rootNodeIds(in: .bookmarked), [bookmarkedTabId])
        XCTAssertEqual(restored.sidebar.rootNodeIds(in: .pinned), [pinnedTabId, pinnedFolderId])
        XCTAssertEqual(restored.sidebar.childNodeIds(of: pinnedFolderId), [firstChildTabId, secondChildTabId])
        XCTAssertEqual(restored.sidebar.rootNodeIds(in: .unpinned), [rootTabId])
        XCTAssertTrue(restored.invariantsHold())
    }

    func testSaveSpaceTabStatesPersistsMultipleSpaces() throws {
        let otherSpace = Space(name: "Other Space", profileId: profile.id, sortOrder: 1)
        try globalDBPool.write { db in try otherSpace.insert(db) }

        let firstTabId = UUID()
        let secondTabId = UUID()
        let firstState = try BrowserStateFixture(
            spaceId: space.id,
            activeTabId: firstTabId,
            tabs: [
                Tab(id: firstTabId, url: URL(string: "https://first.example"), title: "First", spaceId: space.id)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: space.id, kind: .tab, itemId: firstTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
            ]
        )
        let secondFolderId = UUID()
        let secondState = try BrowserStateFixture(
            spaceId: otherSpace.id,
            activeTabId: secondTabId,
            tabs: [
                Tab(id: secondTabId, url: URL(string: "https://second.example"), title: "Second", groupId: secondFolderId, spaceId: otherSpace.id)
            ],
            folders: [
                TabFolder(id: secondFolderId, spaceId: otherSpace.id, name: "Second Folder", color: "#654321")
            ],
            treeItems: makeTreeItems(spaceId: otherSpace.id, folderId: secondFolderId, tabId: secondTabId)
        )
        try save([firstState, secondState])

        let restoredFirst = try restore(spaceId: space.id, activeTabId: firstTabId)
        let restoredSecond = try restore(spaceId: otherSpace.id, activeTabId: secondTabId)
        XCTAssertEqual(restoredFirst.tabsById[firstTabId]?.title, "First")
        XCTAssertEqual(restoredFirst.sidebar.rootNodeIds(in: .unpinned), [firstTabId])
        XCTAssertEqual(restoredSecond.tabsById[secondTabId]?.title, "Second")
        XCTAssertEqual(restoredSecond.foldersById[secondFolderId]?.name, "Second Folder")
        XCTAssertEqual(restoredSecond.sidebar.rootNodeIds(in: .unpinned), [secondFolderId])
        XCTAssertEqual(restoredSecond.sidebar.childNodeIds(of: secondFolderId), [secondTabId])
    }

    func testSaveSpaceTabStatePreservesTabFolderMembershipAcrossRestore() throws {
        let tab = Tab(url: URL(string: "https://example.com/foldered"), spaceId: space.id)
        let folder = TabFolder(spaceId: space.id, name: "Workspace", color: "#92a8ff")
        let state = try folderedState(tab: tab, folder: folder)

        try save(state)

        let restoredState = try restore(spaceId: space.id, activeTabId: tab.id)

        XCTAssertEqual(restoredState.tabsById.count, 1)
        XCTAssertEqual(restoredState.tabsById[tab.id]?.id, tab.id)
        XCTAssertEqual(restoredState.tabsById[tab.id]?.groupId, folder.id)
    }

    func testNestedFoldersSurviveSaveAndRestore() throws {
        let outer = TabFolder(spaceId: space.id, name: "Outer")
        let middle = TabFolder(spaceId: space.id, name: "Middle", isCollapsed: true)
        let inner = TabFolder(spaceId: space.id, name: "Inner")
        let tab = Tab(url: URL(string: "https://example.com/deep"), groupId: inner.id, spaceId: space.id)
        let state = try BrowserStateFixture(
            spaceId: space.id,
            activeTabId: tab.id,
            tabs: [tab],
            folders: [outer, middle, inner],
            treeItems: [
                TabTreeItem(spaceId: space.id, kind: .folder, itemId: outer.id, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: space.id, kind: .folder, itemId: middle.id, parentFolderId: outer.id, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: space.id, kind: .folder, itemId: inner.id, parentFolderId: middle.id, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: space.id, kind: .tab, itemId: tab.id, parentFolderId: inner.id, section: .unpinned, sortOrder: 0)
            ]
        )

        try save(state)
        let restored = try restore(spaceId: space.id, activeTabId: tab.id)

        XCTAssertEqual(restored.sidebar.rootNodeIds(in: .unpinned), [outer.id])
        XCTAssertEqual(restored.sidebar.childNodeIds(of: outer.id), [middle.id])
        XCTAssertEqual(restored.sidebar.childNodeIds(of: middle.id), [inner.id])
        XCTAssertEqual(restored.tabsById[tab.id]?.groupId, inner.id)
        XCTAssertEqual(restored.foldersById[middle.id]?.isCollapsed, true)
    }

    func testSaveSpaceTabStateDoesNotClearPendingDirtyActiveState() throws {
        let otherSpace = Space(name: "Other Space", profileId: profile.id, sortOrder: 1)
        try globalDBPool.write { db in try otherSpace.insert(db) }
        let pendingFolder = TabFolder(spaceId: space.id, name: "Pending", color: "#ff0000")
        let pendingState = try BrowserStateFixture(
            spaceId: space.id,
            activeTabId: nil,
            tabs: tabManager.tabs(forSpace: space.id),
            folders: [pendingFolder],
            treeItems: []
        )
        tabManager.installSpaceTabStateForTests(SpaceTabState(pendingState), spaceId: pendingState.spaceId)
        persistence.scheduleSave()

        let immediateState = try BrowserStateFixture(
            spaceId: otherSpace.id,
            activeTabId: nil,
            tabs: [],
            folders: [],
            treeItems: []
        )
        try save(immediateState)
        XCTAssertTrue(try restore(spaceId: space.id, activeTabId: nil).foldersById.isEmpty)

        persistence.saveNow()

        let savedFolders = try waitForStoredFolders(in: space.id, count: 1)
        XCTAssertEqual(savedFolders.map(\.id), [pendingFolder.id])
    }

    func testRestoredFoldersUseCachedSnapshotWhenStoreIsUnavailable() throws {
        let cachedFolder = TabFolder(
            spaceId: space.id,
            name: "Cached Folder",
            color: "#123456",
            isCollapsed: true
        )
        let windowController = MainWindowController()
        windowController.context.browserState.storeSpace(
            id: space.id,
            snapshot: BrowserStateStore.SpaceSnapshot(
                spaceTab: SpaceTab(
                    spaceId: space.id,
                    state: SpaceTabStateImporter.importState(
                        activeTabId: nil,
                        activationHistory: [],
                        tabs: [],
                        folders: [cachedFolder],
                        treeItems: [],
                        spaceId: space.id
                    )
                ),
                engines: [:]
            )
        )

        let restoredSnapshot = windowController.restoredSpaceSnapshot(for: space)
        let restoredFolders = windowController.context.browserState.projectedSidebar(from: restoredSnapshot).folders

        XCTAssertEqual(restoredFolders.count, 1)
        XCTAssertEqual(restoredFolders.first?.id, cachedFolder.id)
        XCTAssertEqual(restoredFolders.first?.name, "Cached Folder")
        XCTAssertTrue(restoredFolders.first?.isCollapsed ?? false)
    }

    // MARK: - Off-main async flush

    func testSyncFlushPersistsImmediatelyViaSaveSpaceTabStates() throws {
        try tabManager.installFolderForTests(spaceId: space.id, name: "Sync", color: "#112233")

        // saveSpaceTabStates blocks until the write commits, no polling needed.
        let state = tabManager.spaceTabState(forSpace: space.id)
        try persistence.saveSpaceTabStates([(spaceId: space.id, state: state)])

        let savedFolders = try restore(spaceId: space.id, activeTabId: nil)
            .sidebarOrderedFolders()
        XCTAssertEqual(savedFolders.count, 1)
        XCTAssertEqual(savedFolders.first?.name, "Sync")
    }

    func testAsyncWriteFailureRestoresStateForTheNextFlush() throws {
        try tabManager.installFolderForTests(spaceId: space.id, name: "WillFail", color: "#ff0000")
        persistence.scheduleSave()
        try setStateWritesFailing(true)
        persistence.saveNow()

        // The barrier write runs after the failed one, so its completion has queued the restore.
        try setStateWritesFailing(false)
        XCTAssertNil(try persistedState(of: space.id))

        // The restore lands on the main actor; each flush is a no-op until it has re-enqueued the state.
        spin(until: Date().addingTimeInterval(1.0), while: {
            persistence.saveNow()
            return (try? persistedState(of: space.id)) == nil
        })
        XCTAssertEqual(try persistedFolderNames(in: space.id), ["WillFail"],
                       "Failed async write should restore the state to the pending queue")
    }

    func testAsyncWriteFailureDoesNotRestoreStateSupersededByNewerSnapshot() throws {
        try setStateWritesFailing(true)

        // State A is flushed to a failing writer.
        try tabManager.installFolderForTests(spaceId: space.id, name: "StateA", color: "#aaaaaa")
        persistence.scheduleSave()
        persistence.saveNow()

        // A newer state B (A's folder plus a second one) is scheduled before A's failure restore runs.
        try tabManager.installFolderForTests(spaceId: space.id, name: "StateB", color: "#bbbbbb")
        persistence.scheduleSave()

        // B is written once the fault clears, emptying the pending queue.
        try setStateWritesFailing(false)
        persistence.saveNow()
        XCTAssertEqual(try persistedFolderNames(in: space.id)?.count, 2)

        // Fixed grace period for A's failure restore to land: it must see B as the last snapshot
        // and stay out of the queue, or the next flush would overwrite B with A.
        spin(for: 1.0)
        persistence.saveNow()
        XCTAssertEqual(try persistedFolderNames(in: space.id)?.count, 2,
                       "Failed A must not be restored when a newer snapshot (B) already superseded it")
    }

    func testAsyncWriteFailureReArmsTimerForRetry() throws {
        try tabManager.installFolderForTests(spaceId: space.id, name: "WillFail", color: "#cc0000")
        persistence.scheduleSave()
        // A synchronous save cancels the debounce timer armed above, so only a re-armed one can retry.
        try persistence.saveSpaceTabStates([])

        try setStateWritesFailing(true)
        persistence.saveNow()
        try setStateWritesFailing(false)

        // Debounce interval plus its tolerance, with margin.
        spin(until: Date().addingTimeInterval(5.0), while: { (try? persistedState(of: space.id)) == nil })
        XCTAssertEqual(try persistedFolderNames(in: space.id), ["WillFail"],
                       "After a failed async write, the debounce timer must be re-armed for retry")
    }
}
