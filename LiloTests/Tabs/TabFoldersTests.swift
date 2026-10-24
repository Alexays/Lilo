import XCTest
@testable import Lilo

@MainActor
final class TabFoldersTests: XCTestCase {
    private final class CapturedCommand {
        var value: BrowserCommand?
    }

    private var tabManager: TabManager!
    private var bridgeHandler: TabBridgeHandler?

    override func setUp() {
        super.setUp()
        tabManager = TabManager(engineFactory: WKEngineFactory())
    }

    override func tearDown() {
        bridgeHandler = nil
        tabManager = nil
        super.tearDown()
    }

    private func makeStateBridgeHandler(capturedCommand: CapturedCommand? = nil) throws -> TabBridgeHandler {
        let spaceId = try XCTUnwrap(
            tabManager.currentSpaceId ?? tabManager.currentTabs.first?.spaceId ?? tabManager.orderedSidebarSpaceIds().first
        )
        return try makeStateBridgeHandler(
            state: BrowserStateFixture(
                spaceId: spaceId,
                activeTabId: tabManager.activeOpenTabId,
                tabs: tabManager.currentTabs,
                folders: tabManager.folders(forSpace: spaceId),
                treeItems: tabManager.sidebarTreeItems(forSpace: spaceId)
            ),
            capturedCommand: capturedCommand
        )
    }

    private func makeStateBridgeHandler(
        state: BrowserStateFixture,
        capturedCommand: CapturedCommand? = nil
    ) -> TabBridgeHandler {
        let windowController = MainWindowController()
        let store = BrowserStateStoreHarness(states: [state])

        return TabBridgeHandler(
            tabManager: tabManager,
            windowController: windowController,
            stateCommandHandler: { command in
                capturedCommand?.value = command
                let changes = try store.mutate(command)
                if let state = changes.changedState {
                    self.tabManager.installSpaceTabStateForTests(state.state, spaceId: state.spaceId)
                }
                return changes
            }
        )
    }

    private func sidebarDropMessage(_ payload: [String: Any]) -> BridgeMessage {
        BridgeMessage(dictionary: ["action": "commitSidebarDrop", "payload": payload])!
    }

    private func currentState(spaceId: UUID, activeTabId: UUID?) throws -> BrowserStateFixture {
        try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: activeTabId,
            tabs: tabManager.currentTabs,
            folders: tabManager.folders(forSpace: spaceId),
            treeItems: tabManager.sidebarTreeItems(forSpace: spaceId)
        )
    }

    @discardableResult
    private func installTab(url: URL?) throws -> Tab {
        let spaceId = try XCTUnwrap(tabManager.currentSpaceId)
        var tabs = tabManager.tabs(forSpace: spaceId)
        let tab = Tab(url: url, spaceId: spaceId)
        tabs.append(tab)
        let treeItems = tabManager.sidebarTreeItems(forSpace: spaceId) + [
            TabTreeItem(
                spaceId: spaceId,
                kind: .tab,
                itemId: tab.id,
                parentFolderId: nil,
                section: .unpinned,
                sortOrder: tabManager.sidebarTreeItems(forSpace: spaceId)
                    .filter { $0.parentFolderId == nil && $0.section == .unpinned }
                    .count
            )
        ]
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: tabManager.activeOpenTabId,
            tabs: tabs,
            folders: tabManager.folders(forSpace: spaceId),
            treeItems: treeItems
        )
        tabManager.installSpaceTabStateForTests(SpaceTabState(state), spaceId: state.spaceId)
        return tab
    }

    private func makeFolderInsertState(
        spaceId: UUID,
        moving: Tab,
        firstChild: Tab,
        secondChild: Tab,
        folder: TabFolder
    ) throws -> BrowserStateFixture {
        var movingTab = moving
        movingTab.groupId = nil
        var firstChildTab = firstChild
        firstChildTab.groupId = folder.id
        var secondChildTab = secondChild
        secondChildTab.groupId = folder.id
        return try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: moving.id,
            tabs: [movingTab, firstChildTab, secondChildTab],
            folders: [folder],
            treeItems: [
                TabTreeItem(
                    spaceId: spaceId,
                    kind: .tab,
                    itemId: moving.id,
                    parentFolderId: nil,
                    section: .unpinned,
                    sortOrder: 0
                ),
                TabTreeItem(
                    spaceId: spaceId,
                    kind: .folder,
                    itemId: folder.id,
                    parentFolderId: nil,
                    section: .unpinned,
                    sortOrder: 1
                ),
                TabTreeItem(
                    spaceId: spaceId,
                    kind: .tab,
                    itemId: firstChild.id,
                    parentFolderId: folder.id,
                    section: .unpinned,
                    sortOrder: 0
                ),
                TabTreeItem(
                    spaceId: spaceId,
                    kind: .tab,
                    itemId: secondChild.id,
                    parentFolderId: folder.id,
                    section: .unpinned,
                    sortOrder: 1
                )
            ]
        )
    }

    private func installFolderedTab(spaceId: UUID, tab: Tab, folder: TabFolder) throws {
        var folderedTab = tab
        folderedTab.groupId = folder.id
        let section = tabManager.sidebarTreeItems(forSpace: spaceId)
            .first { $0.kind == .folder && $0.itemId == folder.id }?
            .section ?? .unpinned
        folderedTab.isPinned = section == .pinned
        let otherTabs = tabManager.tabs(forSpace: spaceId).filter { $0.id != tab.id }
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: tabManager.activeOpenTabId,
            tabs: otherTabs + [folderedTab],
            folders: tabManager.folders(forSpace: spaceId),
            treeItems: [
                TabTreeItem(
                    spaceId: spaceId,
                    kind: .folder,
                    itemId: folder.id,
                    parentFolderId: nil,
                    section: section,
                    sortOrder: 0
                ),
                TabTreeItem(
                    spaceId: spaceId,
                    kind: .tab,
                    itemId: tab.id,
                    parentFolderId: folder.id,
                    section: section,
                    sortOrder: 0
                )
            ]
        )
        tabManager.installSpaceTabStateForTests(SpaceTabState(state), spaceId: state.spaceId)
    }

    func testBridgeUpdateTabFolderAction() async throws {
        let spaceId = UUID()
        let folder = try tabManager.installFolderForTests(spaceId: spaceId)

        let payload: [String: Any] = [
            "action": "updateTabFolder",
            "payload": ["id": folder.id.uuidString, "name": "Updated", "color": "#00ff00"]
        ]
        let message = BridgeMessage(dictionary: payload)!

        bridgeHandler = try makeStateBridgeHandler()

        _ = await bridgeHandler!.handle(message: message)

        let updated = tabManager.folders(forSpace: spaceId).first(where: { $0.id == folder.id })
        XCTAssertEqual(updated?.name, "Updated")
        XCTAssertEqual(updated?.color, "#00ff00")
    }


    func testBridgeDeleteTabFolderAction() async throws {
        let spaceId = UUID()
        let folder = try tabManager.installFolderForTests(spaceId: spaceId)
        XCTAssertEqual(tabManager.folders(forSpace: spaceId).count, 1)

        let payload: [String: Any] = [
            "action": "deleteTabFolder",
            "payload": ["id": folder.id.uuidString]
        ]
        let message = BridgeMessage(dictionary: payload)!

        bridgeHandler = try makeStateBridgeHandler()

        _ = await bridgeHandler!.handle(message: message)

        XCTAssertEqual(tabManager.folders(forSpace: spaceId).count, 0)
    }

    func testProtectingFolderFindsOnlyAProtectedParent() throws {
        let spaceId = UUID()
        tabManager.currentSpaceId = spaceId
        var folder = TabFolder(spaceId: spaceId, name: "Finances")
        folder.lock = FolderLock(allowsBiometrics: false)
        var inside = Tab(url: URL(string: "https://bank.example"), spaceId: spaceId)
        inside.groupId = folder.id
        let outside = Tab(url: URL(string: "https://news.example"), spaceId: spaceId)
        let state = try BrowserStateFixture(
            spaceId: spaceId, activeTabId: outside.id, tabs: [inside, outside], folders: [folder],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: outside.id, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folder.id, parentFolderId: nil, section: .unpinned, sortOrder: 1),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: inside.id, parentFolderId: folder.id, section: .unpinned, sortOrder: 0)
            ]
        )
        tabManager.installSpaceTabStateForTests(SpaceTabState(state), spaceId: spaceId)

        XCTAssertEqual(tabManager.protectingFolder(of: try XCTUnwrap(tabManager.tab(for: inside.id)))?.id, folder.id)
        XCTAssertNil(tabManager.protectingFolder(of: try XCTUnwrap(tabManager.tab(for: outside.id))))
    }

    func testSetTabFolderLockProtectsAndLocksTheFolder() async throws {
        let spaceId = UUID()
        let folder = try tabManager.installFolderForTests(spaceId: spaceId)
        defer { FolderLockKeychain.remove(folderId: folder.id) }
        bridgeHandler = try makeStateBridgeHandler()

        _ = await bridgeHandler!.handle(message: BridgeMessage(dictionary: [
            "action": "setTabFolderLock",
            "payload": ["id": folder.id.uuidString, "password": "hunter2", "allowsBiometrics": false]
        ])!)

        let updated = try XCTUnwrap(tabManager.folders(forSpace: spaceId).first { $0.id == folder.id })
        XCTAssertEqual(updated.lock, FolderLock(allowsBiometrics: false))
        XCTAssertTrue(updated.isLocked)
        XCTAssertTrue(FolderLockKeychain.verify("hunter2", folderId: folder.id))
    }

    func testSetTabFolderLockRejectsAnEmptyPassword() async throws {
        let spaceId = UUID()
        let folder = try tabManager.installFolderForTests(spaceId: spaceId)
        bridgeHandler = try makeStateBridgeHandler()

        _ = await bridgeHandler!.handle(message: BridgeMessage(dictionary: [
            "action": "setTabFolderLock",
            "payload": ["id": folder.id.uuidString, "password": "", "allowsBiometrics": false]
        ])!)

        XCTAssertNil(tabManager.folders(forSpace: spaceId).first { $0.id == folder.id }?.lock)
    }

    func testUnlockTabFolderNeedsTheRightPassword() async throws {
        let spaceId = UUID()
        let folder = try tabManager.installFolderForTests(spaceId: spaceId)
        defer { FolderLockKeychain.remove(folderId: folder.id) }
        bridgeHandler = try makeStateBridgeHandler()
        _ = await bridgeHandler!.handle(message: BridgeMessage(dictionary: [
            "action": "setTabFolderLock",
            "payload": ["id": folder.id.uuidString, "password": "hunter2", "allowsBiometrics": false]
        ])!)

        _ = await bridgeHandler!.handle(message: BridgeMessage(dictionary: [
            "action": "unlockTabFolder", "payload": ["id": folder.id.uuidString, "password": "wrong"]
        ])!)
        XCTAssertEqual(tabManager.folders(forSpace: spaceId).first { $0.id == folder.id }?.isLocked, true)

        _ = await bridgeHandler!.handle(message: BridgeMessage(dictionary: [
            "action": "unlockTabFolder", "payload": ["id": folder.id.uuidString, "password": "hunter2"]
        ])!)
        XCTAssertEqual(tabManager.folders(forSpace: spaceId).first { $0.id == folder.id }?.isLocked, false)

        _ = await bridgeHandler!.handle(message: BridgeMessage(dictionary: [
            "action": "lockTabFolder", "payload": ["id": folder.id.uuidString]
        ])!)
        XCTAssertEqual(tabManager.folders(forSpace: spaceId).first { $0.id == folder.id }?.isLocked, true)
    }

    func testTouchIDSettingNeedsThePasswordToTurnOnAndKeepsTheFolderOpen() async throws {
        let spaceId = UUID()
        let folder = try tabManager.installFolderForTests(spaceId: spaceId)
        defer { FolderLockKeychain.remove(folderId: folder.id) }
        bridgeHandler = try makeStateBridgeHandler()
        for payload: [String: Any] in [
            ["action": "setTabFolderLock", "payload": ["id": folder.id.uuidString, "password": "hunter2", "allowsBiometrics": false]],
            ["action": "unlockTabFolder", "payload": ["id": folder.id.uuidString, "password": "hunter2"]],
            ["action": "setTabFolderBiometrics", "payload": ["id": folder.id.uuidString, "allowsBiometrics": true, "password": "wrong"]]
        ] {
            _ = await bridgeHandler!.handle(message: BridgeMessage(dictionary: payload)!)
        }
        var updated = try XCTUnwrap(tabManager.folders(forSpace: spaceId).first { $0.id == folder.id })
        XCTAssertEqual(updated.lock, FolderLock(allowsBiometrics: false))

        _ = await bridgeHandler!.handle(message: BridgeMessage(dictionary: [
            "action": "setTabFolderBiometrics", "payload": ["id": folder.id.uuidString, "allowsBiometrics": false]
        ])!)

        updated = try XCTUnwrap(tabManager.folders(forSpace: spaceId).first { $0.id == folder.id })
        XCTAssertEqual(updated.lock, FolderLock(allowsBiometrics: false))
        XCTAssertFalse(updated.isLocked)
    }

    func testDeviceOwnerCannotUnlockAFolderWithoutTouchID() async throws {
        let spaceId = UUID()
        let folder = try tabManager.installFolderForTests(spaceId: spaceId)
        defer { FolderLockKeychain.remove(folderId: folder.id) }
        bridgeHandler = try makeStateBridgeHandler()
        _ = await bridgeHandler!.handle(message: BridgeMessage(dictionary: [
            "action": "setTabFolderLock",
            "payload": ["id": folder.id.uuidString, "password": "hunter2", "allowsBiometrics": false]
        ])!)

        _ = await bridgeHandler!.handle(message: BridgeMessage(dictionary: [
            "action": "unlockTabFolder", "payload": ["id": folder.id.uuidString, "method": "deviceOwner"]
        ])!)

        XCTAssertEqual(tabManager.folders(forSpace: spaceId).first { $0.id == folder.id }?.isLocked, true)
    }

    func testDeletingALockedFolderTakesItsTabsWithIt() async throws {
        let spaceId = UUID()
        tabManager.currentSpaceId = spaceId
        var folder = TabFolder(spaceId: spaceId, name: "Finances")
        folder.lock = FolderLock(allowsBiometrics: false)
        var inside = Tab(url: URL(string: "https://bank.example"), spaceId: spaceId)
        inside.groupId = folder.id
        inside.isPinned = true
        let outside = Tab(url: URL(string: "https://news.example"), spaceId: spaceId)
        let state = try BrowserStateFixture(
            spaceId: spaceId, activeTabId: outside.id, tabs: [inside, outside], folders: [folder],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: outside.id, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folder.id, parentFolderId: nil, section: .pinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: inside.id, parentFolderId: folder.id, section: .pinned, sortOrder: 0)
            ]
        )
        tabManager.installSpaceTabStateForTests(SpaceTabState(state), spaceId: spaceId)
        XCTAssertEqual(tabManager.folders(forSpace: spaceId).first?.isLocked, true)
        bridgeHandler = try makeStateBridgeHandler()

        _ = await bridgeHandler!.handle(message: BridgeMessage(dictionary: [
            "action": "deleteTabFolder", "payload": ["id": folder.id.uuidString]
        ])!)

        XCTAssertTrue(tabManager.folders(forSpace: spaceId).isEmpty)
        XCTAssertNil(tabManager.tab(for: inside.id))
        XCTAssertNotNil(tabManager.tab(for: outside.id))
    }

    func testALockedOuterFolderProtectsTabsOfItsSubfolders() throws {
        let spaceId = UUID()
        tabManager.currentSpaceId = spaceId
        // Built as the bookmark importer builds it: the fixture importer keeps folders at the root.
        let tax = Tab(url: URL(string: "https://taxes.example"), spaceId: spaceId)
        let inner = StoredFolder(id: UUID(), name: "Taxes", color: "#5b7cff", isCollapsed: false, children: [.tab(StoredTab(tax))])
        let outer = StoredFolder(
            id: UUID(), name: "Vault", color: "#f06aa6", isCollapsed: true, children: [.folder(inner)],
            lock: FolderLock(allowsBiometrics: false)
        )
        let state = SpaceTabState(
            activeTabId: nil,
            activationHistory: [],
            tree: StoredSidebarTree(pinned: [], unpinned: [.folder(outer)], bookmarked: [])
        )
        tabManager.installSpaceTabStateForTests(state, spaceId: spaceId)

        let protecting = tabManager.protectingFolder(of: try XCTUnwrap(tabManager.tab(for: tax.id)))
        XCTAssertEqual(protecting?.id, outer.id)
        XCTAssertEqual(protecting?.isLocked, true)
    }

    func testVisibleActiveTabHidesALockedSelection() throws {
        let spaceId = UUID()
        tabManager.currentSpaceId = spaceId
        var folder = TabFolder(spaceId: spaceId, name: "Finances")
        folder.lock = FolderLock(allowsBiometrics: false)
        var bank = Tab(url: URL(string: "https://bank.example"), spaceId: spaceId)
        bank.groupId = folder.id
        let state = try BrowserStateFixture(
            spaceId: spaceId, activeTabId: bank.id, tabs: [bank], folders: [folder],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folder.id, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: bank.id, parentFolderId: folder.id, section: .unpinned, sortOrder: 0)
            ]
        )
        tabManager.installSpaceTabStateForTests(SpaceTabState(state), spaceId: spaceId)
        tabManager.activeTabId = bank.id

        XCTAssertEqual(tabManager.activeTab?.id, bank.id)
        XCTAssertNil(tabManager.visibleActiveTab, "copy, share, duplicate and Handoff must not see a locked selection")
    }

    func testBridgeSetTabFolderCollapsedAction() async throws {
        let spaceId = UUID()
        let folder = try tabManager.installFolderForTests(spaceId: spaceId)

        let payload: [String: Any] = [
            "action": "setTabFolderCollapsed",
            "payload": ["id": folder.id.uuidString, "collapsed": true]
        ]
        let message = BridgeMessage(dictionary: payload)!

        bridgeHandler = try makeStateBridgeHandler()

        _ = await bridgeHandler!.handle(message: message)

        let updated = tabManager.folders(forSpace: spaceId).first(where: { $0.id == folder.id })
        XCTAssertTrue(updated?.isCollapsed ?? false)
    }

    func testApplyBrowserStateFixtureUpdatesTabManagerMetadataWithoutReplacingEngines() throws {
        let spaceId = UUID()
        tabManager.currentSpaceId = spaceId
        let tab = try installTab(url: URL(string: "https://example.com"))
        let folder = try tabManager.installFolderForTests(spaceId: spaceId)
        try installFolderedTab(spaceId: spaceId, tab: tab, folder: folder)
        let originalEngine = tabManager.engineTab(for: tab.id)
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: tab.id,
            tabs: [
                Tab(id: tab.id, url: tab.url, title: tab.title, isPinned: true, groupId: folder.id, spaceId: spaceId)
            ],
            folders: [
                TabFolder(id: folder.id, spaceId: spaceId, name: "Work", color: "#ff0000", isCollapsed: true)
            ],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folder.id, parentFolderId: nil, section: .pinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: tab.id, parentFolderId: folder.id, section: .pinned, sortOrder: 0)
            ]
        )

        tabManager.installSpaceTabStateForTests(SpaceTabState(state), spaceId: state.spaceId)

        XCTAssertTrue(tabManager.folders(forSpace: spaceId).first(where: { $0.id == folder.id })?.isCollapsed ?? false)
        XCTAssertTrue(tabManager.currentTabs.first(where: { $0.id == tab.id })?.isPinned ?? false)
        XCTAssertEqual(tabManager.sidebarTreeItems(forSpace: spaceId).first { $0.kind == .folder && $0.itemId == folder.id }?.section, .pinned)
        XCTAssertTrue(tabManager.sidebarTreeItems(forSpace: spaceId).allSatisfy { $0.section == .pinned })
        XCTAssertTrue(tabManager.engineTab(for: tab.id) === originalEngine)
    }

    func testBridgeUnpinTabUsesStateCommandPipeline() async throws {
        let spaceId = UUID()
        tabManager.currentSpaceId = spaceId
        let tab = try installTab(url: URL(string: "https://example.com"))
        let capturedCommand = CapturedCommand()
        bridgeHandler = makeStateBridgeHandler(
            state: try currentState(spaceId: spaceId, activeTabId: tab.id),
            capturedCommand: capturedCommand
        )
        let message = BridgeMessage(dictionary: [
            "action": "unpinTab",
            "payload": ["id": tab.id.uuidString]
        ])!

        _ = await bridgeHandler!.handle(message: message)

        guard case let .setPinned(commandSpaceId, commandTabId, isPinned)? = capturedCommand.value else {
            return XCTFail("unpinTab should go through BrowserCommand.setPinned")
        }
        XCTAssertEqual(commandSpaceId, spaceId)
        XCTAssertEqual(commandTabId, tab.id)
        XCTAssertFalse(isPinned)
        XCTAssertFalse(tabManager.currentTabs.first(where: { $0.id == tab.id })?.isPinned ?? true)
    }

    func testBridgeCommitSidebarInsertUsesStateCommandPipeline() async throws {
        let spaceId = UUID()
        tabManager.currentSpaceId = spaceId
        let tab = try installTab(url: URL(string: "https://example.com"))
        let folder = try tabManager.installFolderForTests(spaceId: spaceId)
        let capturedCommand = CapturedCommand()
        bridgeHandler = makeStateBridgeHandler(
            state: try currentState(spaceId: spaceId, activeTabId: tab.id),
            capturedCommand: capturedCommand
        )
        let message = BridgeMessage(dictionary: [
            "action": "commitSidebarDrop",
            "payload": [
                "type": "insert",
                "kind": "tab",
                "id": tab.id.uuidString,
                "section": "unpinned",
                "parentFolderId": folder.id.uuidString,
                "fallbackIndex": 0
            ]
        ])!

        _ = await bridgeHandler!.handle(message: message)

        guard case let .moveSidebarItem(commandSpaceId, kind, itemId, parentFolderId, section, insert)? = capturedCommand.value else {
            return XCTFail("commitSidebarDrop insert should go through BrowserCommand.moveSidebarItem")
        }
        XCTAssertEqual(commandSpaceId, spaceId)
        XCTAssertEqual(kind, .tab)
        XCTAssertEqual(itemId, tab.id)
        XCTAssertEqual(parentFolderId, folder.id)
        XCTAssertEqual(section, .unpinned)
        XCTAssertEqual(insert, .anchored(fallbackIndex: 0, insertBeforeId: nil, insertAfterId: nil))
    }

    func testBridgeCommitSidebarInsertNestsAFolderInAFolder() async throws {
        let spaceId = UUID()
        tabManager.currentSpaceId = spaceId
        let tab = try installTab(url: URL(string: "https://example.com"))
        let outer = try tabManager.installFolderForTests(spaceId: spaceId, name: "Outer")
        let inner = try tabManager.installFolderForTests(spaceId: spaceId, name: "Inner")
        bridgeHandler = makeStateBridgeHandler(state: try currentState(spaceId: spaceId, activeTabId: tab.id))

        _ = await bridgeHandler!.handle(message: sidebarDropMessage([
            "type": "insert",
            "kind": "folder",
            "id": inner.id.uuidString,
            "section": "unpinned",
            "parentFolderId": outer.id.uuidString,
            "fallbackIndex": 0
        ]))

        let items = tabManager.sidebarTreeItems(forSpace: spaceId)
        XCTAssertEqual(items.first { $0.itemId == inner.id }?.parentFolderId, outer.id)
        XCTAssertNil(items.first { $0.itemId == outer.id }?.parentFolderId)
    }

    func testSidebarDropInsertParserParsesAnchoredFolderInsert() {
        let tabId = UUID()
        let folderId = UUID()
        let beforeId = UUID()
        let message = sidebarDropMessage([
            "type": "insert",
            "kind": "tab",
            "id": tabId.uuidString,
            "section": "unpinned",
            "parentFolderId": folderId.uuidString,
            "fallbackIndex": 1,
            "insertBeforeId": beforeId.uuidString
        ])

        guard case let .insert(insert)? = SidebarDropInsertParser.parse(message) else {
            return XCTFail("Expected insert payload")
        }

        XCTAssertEqual(insert.kind, .tab)
        XCTAssertEqual(insert.id, tabId)
        XCTAssertEqual(insert.section, .tree(.unpinned))
        XCTAssertEqual(insert.parentFolderId, folderId)
        XCTAssertEqual(insert.fallbackIndex, 1)
        XCTAssertEqual(insert.insertBeforeId, beforeId)
        XCTAssertNil(insert.insertAfterId)
    }

    func testSidebarDropInsertParserRejectsMalformedPayloads() {
        let tabId = UUID()
        let folderId = UUID()

        XCTAssertNil(SidebarDropInsertParser.parse(sidebarDropMessage([
            "type": "insert",
            "kind": "tab",
            "id": tabId.uuidString,
            "section": "unpinned",
            "parentFolderId": folderId.uuidString,
            "index": 0
        ])))

        XCTAssertNil(SidebarDropInsertParser.parse(sidebarDropMessage([
            "type": "insert",
            "kind": "folder",
            "id": folderId.uuidString,
            "section": "bookmarked",
            "fallbackIndex": 0
        ])))

    }

    func testSidebarDropInsertParserParsesAFolderInsertIntoAFolder() {
        let folderId = UUID()
        let parentFolderId = UUID()
        let message = sidebarDropMessage([
            "type": "insert",
            "kind": "folder",
            "id": folderId.uuidString,
            "section": "unpinned",
            "parentFolderId": parentFolderId.uuidString,
            "fallbackIndex": 0
        ])

        guard case let .insert(insert)? = SidebarDropInsertParser.parse(message) else {
            return XCTFail("Expected insert payload")
        }
        XCTAssertEqual(insert.kind, .folder)
        XCTAssertEqual(insert.parentFolderId, parentFolderId)
    }

    func testBridgeCommitSidebarInsertRejectsUnanchoredIndexPayload() async throws {
        let spaceId = UUID()
        tabManager.currentSpaceId = spaceId
        let tab = try installTab(url: URL(string: "https://example.com"))
        let folder = try tabManager.installFolderForTests(spaceId: spaceId)
        let capturedCommand = CapturedCommand()
        bridgeHandler = makeStateBridgeHandler(
            state: try currentState(spaceId: spaceId, activeTabId: tab.id),
            capturedCommand: capturedCommand
        )
        let message = BridgeMessage(dictionary: [
            "action": "commitSidebarDrop",
            "payload": [
                "type": "insert",
                "kind": "tab",
                "id": tab.id.uuidString,
                "section": "unpinned",
                "parentFolderId": folder.id.uuidString,
                "index": 0
            ]
        ])!

        _ = await bridgeHandler!.handle(message: message)

        XCTAssertNil(capturedCommand.value)
        XCTAssertNil(tabManager.currentTabs.first(where: { $0.id == tab.id })?.groupId)
    }

    func testBridgeCommitSidebarInsertUsesNeighborAnchorsWhenIndexIsStale() async throws {
        let spaceId = UUID()
        tabManager.currentSpaceId = spaceId
        let first = try installTab(url: URL(string: "https://first.example"))
        _ = try installTab(url: URL(string: "https://second.example"))
        let third = try installTab(url: URL(string: "https://third.example"))
        let capturedCommand = CapturedCommand()
        bridgeHandler = makeStateBridgeHandler(
            state: try currentState(spaceId: spaceId, activeTabId: first.id),
            capturedCommand: capturedCommand
        )
        let message = BridgeMessage(dictionary: [
            "action": "commitSidebarDrop",
            "payload": [
                "type": "insert",
                "kind": "tab",
                "id": first.id.uuidString,
                "section": "unpinned",
                "parentFolderId": NSNull(),
                "fallbackIndex": 0,
                "insertAfterId": third.id.uuidString
            ]
        ])!

        _ = await bridgeHandler!.handle(message: message)

        guard case let .moveSidebarItem(_, _, itemId, parentFolderId, _, insert)? = capturedCommand.value else {
            return XCTFail("commitSidebarDrop insert should go through BrowserCommand.moveSidebarItem")
        }
        XCTAssertEqual(itemId, first.id)
        XCTAssertNil(parentFolderId)
        XCTAssertEqual(insert, .anchored(fallbackIndex: 0, insertBeforeId: nil, insertAfterId: third.id))
    }

    func testBridgeCommitSidebarInsertIntoFolderUsesNeighborAnchorsWhenIndexIsStale() async throws {
        let spaceId = UUID()
        tabManager.currentSpaceId = spaceId
        let moving = try installTab(url: URL(string: "https://moving.example"))
        let firstChild = try installTab(url: URL(string: "https://first.example"))
        let secondChild = try installTab(url: URL(string: "https://second.example"))
        let folder = TabFolder(spaceId: spaceId, name: "Folder", color: "#111111")
        let initialState = try makeFolderInsertState(
            spaceId: spaceId,
            moving: moving,
            firstChild: firstChild,
            secondChild: secondChild,
            folder: folder
        )
        tabManager.installSpaceTabStateForTests(SpaceTabState(initialState), spaceId: initialState.spaceId)
        let capturedCommand = CapturedCommand()
        bridgeHandler = makeStateBridgeHandler(state: initialState, capturedCommand: capturedCommand)
        let message = BridgeMessage(dictionary: [
            "action": "commitSidebarDrop",
            "payload": [
                "type": "insert",
                "kind": "tab",
                "id": moving.id.uuidString,
                "section": "unpinned",
                "parentFolderId": folder.id.uuidString,
                "fallbackIndex": 2,
                "insertBeforeId": firstChild.id.uuidString
            ]
        ])!

        _ = await bridgeHandler!.handle(message: message)

        guard case let .moveSidebarItem(_, _, itemId, parentFolderId, _, insert)? = capturedCommand.value else {
            return XCTFail("commitSidebarDrop insert should go through BrowserCommand.moveSidebarItem")
        }
        XCTAssertEqual(itemId, moving.id)
        XCTAssertEqual(parentFolderId, folder.id)
        XCTAssertEqual(insert, .anchored(fallbackIndex: 2, insertBeforeId: firstChild.id, insertAfterId: nil))
    }

    func testBridgeCommitSidebarInsertIntoFolderClampsFallbackIndexWhenAnchorsAreMissing() async throws {
        let spaceId = UUID()
        tabManager.currentSpaceId = spaceId
        let moving = try installTab(url: URL(string: "https://moving.example"))
        let firstChild = try installTab(url: URL(string: "https://first.example"))
        let secondChild = try installTab(url: URL(string: "https://second.example"))
        let folder = TabFolder(spaceId: spaceId, name: "Folder", color: "#111111")
        let initialState = try makeFolderInsertState(
            spaceId: spaceId,
            moving: moving,
            firstChild: firstChild,
            secondChild: secondChild,
            folder: folder
        )
        tabManager.installSpaceTabStateForTests(SpaceTabState(initialState), spaceId: initialState.spaceId)
        let capturedCommand = CapturedCommand()
        bridgeHandler = makeStateBridgeHandler(state: initialState, capturedCommand: capturedCommand)
        let missingBeforeId = UUID()
        let missingAfterId = UUID()
        let message = BridgeMessage(dictionary: [
            "action": "commitSidebarDrop",
            "payload": [
                "type": "insert",
                "kind": "tab",
                "id": moving.id.uuidString,
                "section": "unpinned",
                "parentFolderId": folder.id.uuidString,
                "fallbackIndex": 99,
                "insertBeforeId": missingBeforeId.uuidString,
                "insertAfterId": missingAfterId.uuidString
            ]
        ])!

        _ = await bridgeHandler!.handle(message: message)

        guard case let .moveSidebarItem(_, _, itemId, parentFolderId, _, insert)? = capturedCommand.value else {
            return XCTFail("commitSidebarDrop insert should go through BrowserCommand.moveSidebarItem")
        }
        XCTAssertEqual(itemId, moving.id)
        XCTAssertEqual(parentFolderId, folder.id)
        XCTAssertEqual(insert, .anchored(
            fallbackIndex: 99,
            insertBeforeId: missingBeforeId,
            insertAfterId: missingAfterId
        ))
    }

    func testBridgeCommitSidebarInsertIgnoresAnchorsFromAnotherContainer() async throws {
        let spaceId = UUID()
        tabManager.currentSpaceId = spaceId
        let moving = try installTab(url: URL(string: "https://moving.example"))
        let firstChild = try installTab(url: URL(string: "https://first.example"))
        let secondChild = try installTab(url: URL(string: "https://second.example"))
        let otherRoot = try installTab(url: URL(string: "https://root.example"))
        let folder = TabFolder(spaceId: spaceId, name: "Folder", color: "#111111")
        let folderState = try makeFolderInsertState(
            spaceId: spaceId,
            moving: moving,
            firstChild: firstChild,
            secondChild: secondChild,
            folder: folder
        )
        let initialState = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: moving.id,
            tabs: Array(folderState.tabsById.values) + [otherRoot],
            folders: Array(folderState.foldersById.values),
            treeItems: folderState.sidebar.treeItems(spaceId: spaceId) + [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: otherRoot.id, parentFolderId: nil, section: .unpinned, sortOrder: 2)
            ]
        )
        tabManager.installSpaceTabStateForTests(SpaceTabState(initialState), spaceId: initialState.spaceId)
        let capturedCommand = CapturedCommand()
        bridgeHandler = makeStateBridgeHandler(state: initialState, capturedCommand: capturedCommand)
        let message = BridgeMessage(dictionary: [
            "action": "commitSidebarDrop",
            "payload": [
                "type": "insert",
                "kind": "tab",
                "id": moving.id.uuidString,
                "section": "unpinned",
                "parentFolderId": folder.id.uuidString,
                "fallbackIndex": 1,
                "insertAfterId": otherRoot.id.uuidString
            ]
        ])!

        _ = await bridgeHandler!.handle(message: message)

        guard case let .moveSidebarItem(_, _, itemId, parentFolderId, _, insert)? = capturedCommand.value else {
            return XCTFail("commitSidebarDrop insert should go through BrowserCommand.moveSidebarItem")
        }
        XCTAssertEqual(itemId, moving.id)
        XCTAssertEqual(parentFolderId, folder.id)
        XCTAssertEqual(insert, .anchored(fallbackIndex: 1, insertBeforeId: nil, insertAfterId: otherRoot.id))
    }

    func testBridgeCommitSidebarInsertIgnoresAnchorsFromAnotherSection() async throws {
        let spaceId = UUID()
        tabManager.currentSpaceId = spaceId
        let moving = try installTab(url: URL(string: "https://moving.example"))
        let firstChild = try installTab(url: URL(string: "https://first.example"))
        let secondChild = try installTab(url: URL(string: "https://second.example"))
        let pinnedChild = try installTab(url: URL(string: "https://pinned.example"))
        let folder = TabFolder(spaceId: spaceId, name: "Folder", color: "#111111")
        let pinnedFolder = TabFolder(spaceId: spaceId, name: "Pinned", color: "#222222")
        var firstChildTab = firstChild
        firstChildTab.groupId = folder.id
        var secondChildTab = secondChild
        secondChildTab.groupId = folder.id
        var pinnedChildTab = pinnedChild
        pinnedChildTab.groupId = pinnedFolder.id
        pinnedChildTab.isPinned = true
        let initialState = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: moving.id,
            tabs: [moving, firstChildTab, secondChildTab, pinnedChildTab],
            folders: [folder, pinnedFolder],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .folder, itemId: pinnedFolder.id, parentFolderId: nil, section: .pinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: pinnedChild.id, parentFolderId: pinnedFolder.id, section: .pinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: moving.id, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folder.id, parentFolderId: nil, section: .unpinned, sortOrder: 1),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: firstChild.id, parentFolderId: folder.id, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: secondChild.id, parentFolderId: folder.id, section: .unpinned, sortOrder: 1)
            ]
        )
        tabManager.installSpaceTabStateForTests(SpaceTabState(initialState), spaceId: initialState.spaceId)
        let capturedCommand = CapturedCommand()
        bridgeHandler = makeStateBridgeHandler(state: initialState, capturedCommand: capturedCommand)
        let message = BridgeMessage(dictionary: [
            "action": "commitSidebarDrop",
            "payload": [
                "type": "insert",
                "kind": "tab",
                "id": moving.id.uuidString,
                "section": "unpinned",
                "parentFolderId": folder.id.uuidString,
                "fallbackIndex": 1,
                "insertBeforeId": pinnedChild.id.uuidString
            ]
        ])!

        _ = await bridgeHandler!.handle(message: message)

        guard case let .moveSidebarItem(_, _, itemId, parentFolderId, _, insert)? = capturedCommand.value else {
            return XCTFail("commitSidebarDrop insert should go through BrowserCommand.moveSidebarItem")
        }
        XCTAssertEqual(itemId, moving.id)
        XCTAssertEqual(parentFolderId, folder.id)
        XCTAssertEqual(insert, .anchored(fallbackIndex: 1, insertBeforeId: pinnedChild.id, insertAfterId: nil))
    }

    func testBridgeCommitSidebarBookmarkedInsertUsesStateCommandPipeline() async throws {
        let spaceId = UUID()
        tabManager.currentSpaceId = spaceId
        let tab = try installTab(url: URL(string: "https://example.com"))
        let before = try installTab(url: URL(string: "https://before.example"))
        let capturedCommand = CapturedCommand()
        bridgeHandler = makeStateBridgeHandler(
            state: try currentState(spaceId: spaceId, activeTabId: tab.id),
            capturedCommand: capturedCommand
        )
        let message = BridgeMessage(dictionary: [
            "action": "commitSidebarDrop",
            "payload": [
                "type": "insert",
                "kind": "tab",
                "id": tab.id.uuidString,
                "section": "bookmarked",
                "fallbackIndex": 0,
                "insertBeforeId": before.id.uuidString
            ]
        ])!

        _ = await bridgeHandler!.handle(message: message)

        guard case let .moveTabToBookmarked(commandSpaceId, commandTabId, insert)? = capturedCommand.value else {
            return XCTFail("commitSidebarDrop bookmarked insert should go through BrowserCommand.moveTabToBookmarked")
        }
        XCTAssertEqual(commandSpaceId, spaceId)
        XCTAssertEqual(commandTabId, tab.id)
        XCTAssertEqual(insert, .anchored(fallbackIndex: 0, insertBeforeId: before.id, insertAfterId: nil))
        XCTAssertTrue(tabManager.currentTabs.first(where: { $0.id == tab.id })?.isBookmarked ?? false)
    }

    func testBridgeCommitSidebarGroupUsesStateCommandPipeline() async throws {
        let spaceId = UUID()
        tabManager.currentSpaceId = spaceId
        let source = try installTab(url: URL(string: "https://source.example"))
        let target = try installTab(url: URL(string: "https://target.example"))
        let capturedCommand = CapturedCommand()
        bridgeHandler = makeStateBridgeHandler(
            state: try currentState(spaceId: spaceId, activeTabId: source.id),
            capturedCommand: capturedCommand
        )
        let message = BridgeMessage(dictionary: [
            "action": "commitSidebarDrop",
            "payload": [
                "type": "group",
                "sourceTabId": source.id.uuidString,
                "targetTabId": target.id.uuidString
            ]
        ])!

        _ = await bridgeHandler!.handle(message: message)

        guard case let .groupTabs(commandSpaceId, sourceTabId, targetTabId)? = capturedCommand.value else {
            return XCTFail("commitSidebarDrop group should go through BrowserCommand.groupTabs")
        }
        XCTAssertEqual(commandSpaceId, spaceId)
        XCTAssertEqual(sourceTabId, source.id)
        XCTAssertEqual(targetTabId, target.id)
        XCTAssertEqual(tabManager.folders(forSpace: spaceId).count, 1)
        XCTAssertEqual(tabManager.currentTabs.first(where: { $0.id == source.id })?.groupId, tabManager.folders(forSpace: spaceId)[0].id)
        XCTAssertEqual(tabManager.currentTabs.first(where: { $0.id == target.id })?.groupId, tabManager.folders(forSpace: spaceId)[0].id)
    }
}
