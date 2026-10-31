import XCTest
@testable import Lilo

@MainActor
final class FolderAutoLockTests: XCTestCase {
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

    func testLockAllLocksEveryUnlockedFolderWithoutAWindow() throws {
        let context = browserContext.context
        try storeUnlockedFolder(in: context)
        XCTAssertEqual(context.browserState.unlockedFolders().count, 1)

        context.folderAutoLock.lockAll()

        XCTAssertTrue(context.browserState.unlockedFolders().isEmpty)
    }

    func testIdleTimerRunsOnlyWhileAFolderIsUnlocked() throws {
        let context = browserContext.context
        context.folderAutoLock.folderWasUnlocked()
        XCTAssertNil(context.folderAutoLock.idleTimer)

        try storeUnlockedFolder(in: context)
        // An idle test machine must not trip the limit and lock straight away.
        context.settingsStore.set("folderAutoLockMinutes", value: "100000")
        context.folderAutoLock.folderWasUnlocked()
        XCTAssertNotNil(context.folderAutoLock.idleTimer)

        context.folderAutoLock.lockAll()
        XCTAssertNil(context.folderAutoLock.idleTimer)
    }

    func testAShorterLimitAppliesToTheFoldersAlreadyUnlocked() async throws {
        let context = browserContext.context
        let space = try context.spaceManager.createSpace(name: "S", profileId: try context.profileManager.createProfile(name: "P").id)
        let window = makeTestWindow(context, showing: space.id)
        defer { window.window?.close() }
        window.setupBridgeLate()
        try storeUnlockedFolder(in: context)
        context.settingsStore.set("folderAutoLockMinutes", value: "100000")
        context.folderAutoLock.folderWasUnlocked()

        let handler = try XCTUnwrap(window.bridgeRouter.handlers["setSetting"])
        _ = await handler.handle(message: try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "setSetting", "payload": ["key": "folderAutoLockMinutes", "value": "1"]
        ])))

        let fireDate = context.folderAutoLock.idleTimer?.fireDate ?? .distantFuture
        XCTAssertTrue(context.browserState.unlockedFolders().isEmpty || fireDate <= Date().addingTimeInterval(61),
                      "locked now, or within the new minute")
    }

    private func storeUnlockedFolder(in context: BrowserContext) throws {
        let spaceId = UUID()
        var folder = TabFolder(spaceId: spaceId, name: "Finances")
        folder.lock = FolderLock(allowsBiometrics: false)
        folder.isUnlocked = true
        let state = try BrowserStateFixture(
            spaceId: spaceId, activeTabId: nil, tabs: [], folders: [folder],
            treeItems: [TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folder.id, parentFolderId: nil, section: .unpinned, sortOrder: 0)]
        )
        context.browserState.storeSpace(
            id: spaceId,
            snapshot: BrowserStateStore.SpaceSnapshot(spaceTab: SpaceTab(spaceId: spaceId, state: SpaceTabState(state)), engines: [:])
        )
    }
}
