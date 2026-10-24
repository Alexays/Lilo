import AppKit
import XCTest
@testable import Lilo

/// Windows showing the same space share its live runtime; the last one to leave parks it.
@MainActor
final class SharedSpaceRuntimeTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var spaceS: Space!
    private var spaceT: Space!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        spaceS = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        spaceT = try context.spaceManager.createSpace(name: "T", profileId: profileId)
    }

    override func tearDown() {
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    private func makeWindow() -> MainWindowController {
        let window = MainWindowController(context: browserContext.context)
        window.bridgeRouter = BridgeRouter(chromeWebView: window.chromeWebView)
        window.contentContainerView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        return window
    }

    func testSecondWindowAdoptsTheLiveRuntimeOfAShownSpace() {
        let first = makeWindow(), second = makeWindow()
        first.switchToSpace(spaceS.id)
        second.switchToSpace(spaceS.id)

        XCTAssertTrue(first.tabManager.engineHost === second.tabManager.engineHost)
        XCTAssertEqual(second.tabManager.currentSpaceId, spaceS.id)
    }

    func testLeavingASpaceStillShownElsewhereKeepsItLive() {
        let first = makeWindow(), second = makeWindow()
        first.switchToSpace(spaceS.id)
        second.switchToSpace(spaceS.id)

        first.switchToSpace(spaceT.id)

        let store = browserContext.context.browserState
        XCTAssertTrue(store.visibleSpaceIds.contains(spaceS.id))
        XCTAssertTrue(store.liveHost(for: spaceS.id) === second.tabManager.engineHost)
        XCTAssertFalse(first.tabManager.engineHost === second.tabManager.engineHost)
    }

    /// Two windows on space S select `bank`, inside a protected folder that is unlocked; `news` sits outside.
    private func showUnlockedFolderTabInTwoWindows() throws -> (MainWindowController, MainWindowController, folderId: UUID, bank: UUID, news: UUID) {
        let first = makeWindow(), second = makeWindow()
        browserContext.context.windows.add(first)
        browserContext.context.windows.add(second)
        first.switchToSpace(spaceS.id)
        second.switchToSpace(spaceS.id)
        let news = try XCTUnwrap(first.createTabStateFirst(url: URL(string: "https://news.example")))
        let bank = try XCTUnwrap(first.createTabStateFirst(url: URL(string: "https://bank.example")))
        let statement = try XCTUnwrap(first.createTabStateFirst(url: URL(string: "https://statement.example")))
        try first.applyBrowserCommand(.groupTabs(spaceId: spaceS.id, sourceTabId: statement.id, targetTabId: bank.id))
        let folderId = try XCTUnwrap(first.tabManager.tab(for: bank.id)?.groupId)
        try first.applyBrowserCommand(.setFolderLock(spaceId: spaceS.id, folderId: folderId, lock: FolderLock(allowsBiometrics: false)))
        try first.applyBrowserCommand(.setFolderUnlocked(spaceId: spaceS.id, folderId: folderId, isUnlocked: true))
        first.activateTabStateFirst(id: news.id)
        first.activateTabStateFirst(id: bank.id)
        second.tabManager.activateTabRuntime(id: bank.id)
        XCTAssertEqual(first.tabManager.activeTabId, bank.id)
        XCTAssertEqual(second.tabManager.activeTabId, bank.id)
        return (first, second, folderId, bank.id, news.id)
    }

    func testHidingALockedFolderMovesEveryWindowOffItsTabs() throws {
        let (first, second, folderId, bank, _) = try showUnlockedFolderTabInTwoWindows()
        first.tabManager.updateTab(id: bank) { $0.title = "Bank statements" }

        try first.applyBrowserCommand(.setFolderUnlocked(spaceId: spaceS.id, folderId: folderId, isUnlocked: false))
        first.hideLockedFolder(folderId, spaceId: spaceS.id, automatic: true)

        for window in [first, second] {
            XCTAssertEqual(window.tabManager.activeTabId, bank, "an automatic lock keeps the selection")
            XCTAssertEqual(window.placeholderTabId, bank, "and shows the lock placeholder")
            XCTAssertFalse(window.displayedTabIds.contains(bank))
            XCTAssertEqual(window.window?.title, "Lilo", "the window title reaches the Dock, Mission Control and VoiceOver")
        }
        XCTAssertNil(first.tabManager.engineTab(for: bank))
    }

    func testLockingAFolderByHandMovesEveryWindowToAnotherTab() throws {
        let (first, second, folderId, bank, news) = try showUnlockedFolderTabInTwoWindows()

        try first.applyBrowserCommand(.setFolderUnlocked(spaceId: spaceS.id, folderId: folderId, isUnlocked: false))
        first.hideLockedFolder(folderId, spaceId: spaceS.id, automatic: false)

        for window in [first, second] {
            XCTAssertEqual(window.tabManager.activeTabId, news)
            XCTAssertFalse(window.displayedTabIds.contains(bank))
        }
        XCTAssertNil(first.tabManager.engineTab(for: bank))
    }

    /// A terminal tab's shell belongs to the tab, so every window reaches the same sessions.
    func testWindowsShareOneTerminalHost() {
        XCTAssertTrue(makeWindow().tabManager.terminalHost === makeWindow().tabManager.terminalHost)
    }

    /// One window trimming the shared runtime never discards the tab another window displays.
    func testTrimKeepsATabDisplayedInAnotherWindow() throws {
        let first = makeWindow(), second = makeWindow()
        first.switchToSpace(spaceS.id)
        second.switchToSpace(spaceS.id)
        let shown = first.tabManager.prepareTabRuntime(url: URL(string: "https://shown.example"))
        first.tabManager.attachPreparedTabRuntime(for: shown)
        let engine = try XCTUnwrap(first.tabManager.ensureLiveEngine(forTabId: shown.id))
        browserContext.context.browserState.displayedTabIds = [shown.id]

        first.tabManager.discardEngines([shown.id])

        XCTAssertTrue(second.tabManager.engineTab(for: shown.id) === engine)
    }

    /// Showing a tab another window shows moves its web view; the other window keeps its selection.
    func testShowingATabShownElsewhereTakesItAndTheOtherWindowLetsGo() throws {
        let first = makeWindow(), second = makeWindow()
        browserContext.context.windows.add(first)
        browserContext.context.windows.add(second)
        first.switchToSpace(spaceS.id)
        second.switchToSpace(spaceS.id)
        let shown = try XCTUnwrap(first.createTabStateFirst(url: URL(string: "https://shown.example")))
        let engine = try XCTUnwrap(first.tabManager.engineTab(for: shown.id))
        XCTAssertTrue(browserContext.context.windows.displayingWindow(ofTab: shown.id) === first)

        second.tabManager.activateTabRuntime(id: shown.id)

        XCTAssertTrue(browserContext.context.windows.displayingWindow(ofTab: shown.id) === second)
        XCTAssertTrue(engine.view.isDescendant(of: second.contentContainerView))
        XCTAssertTrue(engine.delegate === second, "navigation and dialogs follow the window that shows the page")
        XCTAssertFalse(first.displayedTabIds.contains(shown.id))
        XCTAssertTrue(browserContext.context.windows.window(for: engine.wkWebView) === second, "page events reach the window that shows the page")
        XCTAssertEqual(first.tabManager.activeTabId, shown.id, "the window that lost the tab keeps its selection")
    }

    func testTheWindowThatLostItsTabOffersItBackAndTakesItOnRequest() throws {
        let first = makeWindow(), second = makeWindow()
        browserContext.context.windows.add(first)
        browserContext.context.windows.add(second)
        first.switchToSpace(spaceS.id)
        second.switchToSpace(spaceS.id)
        let shown = try XCTUnwrap(first.createTabStateFirst(url: URL(string: "https://shown.example")))
        second.tabManager.activateTabRuntime(id: shown.id)
        XCTAssertEqual(first.placeholderTabId, shown.id)

        first.reclaimDisplayedTab(shown.id)

        XCTAssertNil(first.placeholderTabId)
        XCTAssertTrue(browserContext.context.windows.displayingWindow(ofTab: shown.id) === first)
        XCTAssertEqual(second.placeholderTabId, shown.id)
    }

    func testSwitchingSpaceInOneWindowLeavesTheOtherWhereItIs() {
        let first = makeWindow(), second = makeWindow()
        browserContext.context.windows.add(first)
        browserContext.context.windows.add(second)
        first.switchToSpace(spaceS.id)
        second.switchToSpace(spaceS.id)

        first.requestSpaceSwitch(id: spaceT.id)

        XCTAssertEqual(first.tabManager.currentSpaceId, spaceT.id)
        XCTAssertEqual(second.tabManager.currentSpaceId, spaceS.id)
    }

    func testDeletingASpaceShownInTwoWindowsMovesBothAndForgetsIt() throws {
        let first = makeWindow(), second = makeWindow()
        browserContext.context.windows.add(first)
        browserContext.context.windows.add(second)
        first.switchToSpace(spaceS.id)
        second.switchToSpace(spaceS.id)

        try browserContext.context.spaceManager.deleteSpace(id: spaceS.id)

        XCTAssertEqual(first.tabManager.currentSpaceId, spaceT.id)
        XCTAssertEqual(second.tabManager.currentSpaceId, spaceT.id)
        let store = browserContext.context.browserState
        XCTAssertNil(store.space(id: spaceS.id), "a deleted space must not be parked back into the store")
        XCTAssertFalse(store.visibleSpaceIds.contains(spaceS.id))
    }

    func testClosingAWindowGivesItsTabBackToTheWindowWaitingForIt() throws {
        let first = makeWindow(), second = makeWindow()
        browserContext.context.windows.add(first)
        browserContext.context.windows.add(second)
        first.switchToSpace(spaceS.id)
        second.switchToSpace(spaceS.id)
        let shown = try XCTUnwrap(first.createTabStateFirst(url: URL(string: "https://shown.example")))
        second.tabManager.activateTabRuntime(id: shown.id)

        second.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        let registry = browserContext.context.windows
        XCTAssertFalse(registry.windows.contains { $0 === second })
        XCTAssertTrue(registry.displayingWindow(ofTab: shown.id) === first)
        XCTAssertNil(first.placeholderTabId)
        XCTAssertTrue(browserContext.context.browserState.liveHost(for: spaceS.id) === first.tabManager.engineHost)
    }

    func testClosingTheLastWindowOnASpaceParksIt() {
        let window = makeWindow()
        browserContext.context.windows.add(window)
        window.switchToSpace(spaceS.id)

        window.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertNil(browserContext.context.browserState.liveHost(for: spaceS.id))
        XCTAssertFalse(browserContext.context.browserState.visibleSpaceIds.contains(spaceS.id))
    }

    func testWindowsClosedByAppKitAfterTerminationLeaveTheClosedDatabasesAlone() {
        let window = makeWindow()
        let context = browserContext.context
        context.windows.add(window)
        window.switchToSpace(spaceS.id)
        context.isTerminating = true
        context.dbManager.closeForShutdown()

        window.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertTrue(context.windows.windows.contains { $0 === window })
        XCTAssertNotNil(context.browserState.liveHost(for: spaceS.id))
    }

    func testOpenWindowsAreSavedWithTheSpaceEachShows() throws {
        let first = makeWindow(), second = makeWindow()
        browserContext.context.windows.add(first)
        browserContext.context.windows.add(second)
        first.switchToSpace(spaceS.id)
        second.switchToSpace(spaceT.id)

        browserContext.context.saveWindowsNow()

        let stored = try browserContext.context.dbManager.globalPool.read(WindowStore.load)
        XCTAssertEqual(stored.map(\.spaceId), [spaceS.id, spaceT.id])
        XCTAssertEqual(stored.first?.frame, first.window?.frame)
    }

    /// Extensions see one window per browser window showing their profile, and lose it when it closes.
    func testEachWindowIsItsOwnExtensionWindow() throws {
        let first = makeWindow(), second = makeWindow()
        browserContext.context.windows.add(first)
        browserContext.context.windows.add(second)
        first.switchToSpace(spaceS.id)
        second.switchToSpace(spaceT.id)
        let registry = try XCTUnwrap(browserContext.context.profileContexts.existingContext(for: spaceS.profileId)).extensions

        XCTAssertEqual(registry.windowAdapters.count, 2)

        second.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertEqual(registry.windowAdapters.count, 1)
        XCTAssertTrue(registry.windowAdapters.first?.nsWindow === first.window)
    }

    func testMovingATabToANewWindowShowsItThereAndTheSourceMovesOn() throws {
        let source = makeWindow()
        browserContext.context.windows.add(source)
        source.switchToSpace(spaceS.id)
        let staying = try XCTUnwrap(source.createTabStateFirst(url: URL(string: "https://staying.example")))
        let moving = try XCTUnwrap(source.createTabStateFirst(url: URL(string: "https://moving.example")))

        let opened = try XCTUnwrap(source.moveTabToNewWindow(moving.id))
        opened.bridgeRouter = BridgeRouter(chromeWebView: opened.chromeWebView)
        opened.contentContainerView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        opened.openOnSpace(spaceS.id, opening: .tab(moving.id))

        XCTAssertEqual(source.tabManager.activeTabId, staying.id)
        XCTAssertNil(source.placeholderTabId)
        XCTAssertTrue(browserContext.context.windows.displayingWindow(ofTab: moving.id) === opened)
        guard case let .space(spaceId, _, opening) = opened.launch else { return XCTFail("opens on a space") }
        XCTAssertEqual(spaceId, spaceS.id)
        XCTAssertEqual(opening, .tab(moving.id))
    }

    private func twoWindowsOnS() -> (MainWindowController, MainWindowController) {
        let first = makeWindow(), second = makeWindow()
        browserContext.context.windows.add(first)
        browserContext.context.windows.add(second)
        first.switchToSpace(spaceS.id)
        second.switchToSpace(spaceS.id)
        return (first, second)
    }

    /// Review C1: a command in one window keeps that window's own selection.
    func testACommandKeepsTheWindowsOwnSelectionWhenTheOtherWindowSelectedLast() throws {
        let (first, second) = twoWindowsOnS()
        let mine = try XCTUnwrap(first.createTabStateFirst(url: URL(string: "https://mine.example")))
        let theirs = try XCTUnwrap(second.createTabStateFirst(url: URL(string: "https://theirs.example")))
        let other = try XCTUnwrap(first.createTabStateFirst(url: URL(string: "https://other.example"), activate: false))

        try first.applyBrowserCommand(.setPinned(spaceId: spaceS.id, tabId: other.id, isPinned: true))

        XCTAssertEqual(first.tabManager.activeTabId, mine.id)
        XCTAssertEqual(second.tabManager.activeTabId, theirs.id)
    }

    /// Review C1 and I6: closing a tab never hands this window the tab another window shows.
    func testClosingATabNeverTakesTheOtherWindowsTab() throws {
        let (first, second) = twoWindowsOnS()
        let closing = try XCTUnwrap(first.createTabStateFirst(url: URL(string: "https://closing.example")))
        let theirs = try XCTUnwrap(second.createTabStateFirst(url: nil))

        first.closeTabStateFirst(id: closing.id, undoable: false)

        XCTAssertTrue(browserContext.context.windows.displayingWindow(ofTab: theirs.id) === second)
        XCTAssertNotEqual(first.tabManager.activeTabId, theirs.id)
        XCTAssertNotNil(first.tabManager.tab(for: theirs.id), "the other window's blank tab is not swept away")
    }

    /// Review I5: a window whose selected tab another window closed moves on to another tab.
    func testAWindowWhoseTabIsClosedElsewhereMovesOn() throws {
        let (first, second) = twoWindowsOnS()
        let staying = try XCTUnwrap(first.createTabStateFirst(url: URL(string: "https://staying.example")))
        let closing = try XCTUnwrap(second.createTabStateFirst(url: URL(string: "https://closing.example")))
        first.activateTabStateFirst(id: staying.id)

        first.closeTabStateFirst(id: closing.id, undoable: false)

        XCTAssertNotEqual(second.tabManager.activeTabId, closing.id)
        XCTAssertNotNil(second.tabManager.activeTabId)
        XCTAssertFalse(browserContext.context.browserState.displayedTabIds.contains(closing.id))
    }

    /// Review I10: arriving on a shared space never takes the tab another window shows.
    func testArrivingOnASharedSpaceLeavesTheOtherWindowsTabAlone() throws {
        let first = makeWindow(), second = makeWindow()
        browserContext.context.windows.add(first)
        browserContext.context.windows.add(second)
        first.switchToSpace(spaceS.id)
        let free = try XCTUnwrap(first.createTabStateFirst(url: URL(string: "https://free.example")))
        let shown = try XCTUnwrap(first.createTabStateFirst(url: URL(string: "https://shown.example")))

        second.switchToSpace(spaceS.id)

        XCTAssertTrue(browserContext.context.windows.displayingWindow(ofTab: shown.id) === first)
        XCTAssertEqual(second.tabManager.activeTabId, free.id)
    }

    /// Review I11: a window returns to the tab it had in a space.
    func testAWindowReturnsToItsOwnTabInASpace() throws {
        let (first, second) = twoWindowsOnS()
        let mine = try XCTUnwrap(first.createTabStateFirst(url: URL(string: "https://mine.example")))
        first.switchToSpace(spaceT.id)
        _ = try XCTUnwrap(second.createTabStateFirst(url: URL(string: "https://theirs.example")))

        first.switchToSpace(spaceS.id)

        XCTAssertEqual(first.tabManager.activeTabId, mine.id)
    }

    func testAPrivateTabNeverTitlesTheWindow() throws {
        let window = makeWindow()
        browserContext.context.windows.add(window)
        let privateSpace = try browserContext.context.spaceManager.createSpace(name: "P", profileId: spaceS.profileId, isPrivate: true)
        for space in [spaceS.id, privateSpace.id] {
            window.switchToSpace(space)
            let tab = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "https://example.com")))

            window.activateTabStateFirst(id: tab.id)

            if space == privateSpace.id {
                XCTAssertEqual(window.window?.title, "Lilo")
                XCTAssertNil(window.browsingActivity, "no Handoff from a private space")
            } else {
                XCTAssertEqual(window.window?.title, "example.com")
            }
        }
    }

    /// Review I7: a private space shown in another window still opens here on Cmd+Shift+N.
    func testNewPrivateSpaceShowsThePrivateSpaceInThisWindow() throws {
        let first = makeWindow(), second = makeWindow()
        browserContext.context.windows.add(first)
        browserContext.context.windows.add(second)
        first.switchToSpace(spaceS.id)
        let privateSpace = try browserContext.context.spaceManager.createSpace(name: "P", profileId: spaceS.profileId, isPrivate: true)
        second.switchToSpace(privateSpace.id)

        first.newPrivateSpace(nil)

        XCTAssertEqual(first.tabManager.currentSpaceId, privateSpace.id)
    }

    func testCmdShiftNShowsANewPrivateSpaceWithABlankTab() throws {
        let window = makeWindow()
        browserContext.context.windows.add(window)
        window.switchToSpace(spaceS.id)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.shift, .command], timestamp: 0, windowNumber: 0, context: nil,
            characters: "N", charactersIgnoringModifiers: "N", isARepeat: false, keyCode: 45
        ))

        XCTAssertTrue(window.handleKeyboardShortcut(event))

        let privateSpace = try XCTUnwrap(browserContext.context.spaceManager.spaces.first(where: \.isPrivate))
        XCTAssertEqual(window.tabManager.currentSpaceId, privateSpace.id)
        XCTAssertEqual(window.tabManager.openTabs.count, 1)
        XCTAssertEqual(window.tabManager.activeOpenTabId, window.tabManager.openTabs.first?.id)
        XCTAssertNil(window.tabManager.activeTab?.url)
    }

    func testTheFrameKeepsTheColorTheChromeReportsWhateverPathChangesTheSpace() async throws {
        let window = makeWindow()
        browserContext.context.windows.add(window)
        window.switchToSpace(spaceS.id)
        let handler = ChromeBridgeHandler(interactiveZoneStore: ChromeInteractiveZoneStore(), windowController: window)
        func report(_ color: String) async throws {
            _ = await handler.handle(message: try XCTUnwrap(BridgeMessage(dictionary: [
                "action": "updateWindowBackground", "payload": ["color": color]
            ])))
        }
        let shown = { window.window?.backgroundColor.cssHexString }

        try await report("#d8d3ee")
        XCTAssertEqual(shown(), "#d8d3ee")

        window.newPrivateSpace(nil)
        XCTAssertEqual(shown(), "#d8d3ee", "the sidebar still shows that color until the chrome reports the next one")
        window.switchToSpace(spaceT.id)
        XCTAssertEqual(shown(), "#d8d3ee")
        try window.deleteSpace(id: spaceT.id)
        XCTAssertEqual(shown(), "#d8d3ee")

        try await report("#b9bcc4")
        XCTAssertEqual(shown(), "#b9bcc4")
    }

    /// Spaces S, T, then the Agents space, which stays last and hidden while no agent works there.
    private func makeAgentsSpace() throws -> Space {
        let context = browserContext.context
        let agents = try context.spaceManager.createSpace(name: "Agents", profileId: spaceS.profileId)
        context.settingsStore.set(AgentControl.agentsSpaceKey, value: agents.id.uuidString)
        return agents
    }

    func testClosingThePrivateSpacesLastTabGoesBackToTheSpaceTheWindowCameFrom() throws {
        let agents = try makeAgentsSpace()
        let window = makeWindow()
        browserContext.context.windows.add(window)
        window.switchToSpace(spaceT.id)
        window.switchToSpace(spaceS.id)
        window.newPrivateSpace(nil)

        window.closeCurrentTab(nil)

        XCTAssertFalse(browserContext.context.spaceManager.spaces.contains(where: \.isPrivate))
        XCTAssertEqual(window.tabManager.currentSpaceId, spaceS.id)
        XCTAssertNotEqual(window.tabManager.currentSpaceId, agents.id)
    }

    func testEachWindowShowingADeletedPrivateSpaceGoesBackToItsOwnSpace() throws {
        _ = try makeAgentsSpace()
        let first = makeWindow(), second = makeWindow()
        browserContext.context.windows.add(first)
        browserContext.context.windows.add(second)
        first.switchToSpace(spaceS.id)
        second.switchToSpace(spaceT.id)
        first.newPrivateSpace(nil)
        second.switchToSpace(try XCTUnwrap(first.tabManager.currentSpaceId))

        first.closeCurrentTab(nil)

        XCTAssertFalse(browserContext.context.spaceManager.spaces.contains(where: \.isPrivate))
        XCTAssertEqual(first.tabManager.currentSpaceId, spaceS.id)
        XCTAssertEqual(second.tabManager.currentSpaceId, spaceT.id)
    }

    func testDeletingTheShownSpaceNeverFallsBackToTheHiddenAgentsSpace() throws {
        let agents = try makeAgentsSpace()
        let window = makeWindow()
        browserContext.context.windows.add(window)
        window.switchToSpace(spaceS.id)
        window.switchToSpace(spaceT.id)

        try window.deleteSpace(id: spaceT.id)

        XCTAssertEqual(window.tabManager.currentSpaceId, spaceS.id)
        XCTAssertNotEqual(window.tabManager.currentSpaceId, agents.id)
    }

    /// Review I4: a tab's events go to the window showing its space, not to the first window.
    func testEventsForATabGoToTheWindowShowingItsSpace() throws {
        let first = makeWindow(), second = makeWindow()
        browserContext.context.windows.add(first)
        browserContext.context.windows.add(second)
        first.switchToSpace(spaceS.id)
        second.switchToSpace(spaceT.id)
        let background = try XCTUnwrap(second.createTabStateFirst(url: URL(string: "https://bg.example"), activate: false))

        XCTAssertTrue(browserContext.context.windows.window(forTab: background.id) === second)
    }

    /// Review I8: moving a space shown in two windows to another profile keeps both windows on it.
    func testMovingASharedSpaceToAnotherProfileKeepsBothWindowsOnIt() async throws {
        let (first, second) = twoWindowsOnS()
        let target = try browserContext.context.profileManager.createProfile(name: "Q").id

        try await first.moveSpaceToProfile(id: spaceS.id, targetProfileId: target, name: nil, icon: nil, color: nil)

        XCTAssertEqual(second.tabManager.currentSpaceId, spaceS.id)
        XCTAssertEqual(second.profileContext?.profileId, target)
        XCTAssertTrue(first.tabManager.engineHost === second.tabManager.engineHost)
        XCTAssertTrue(browserContext.context.browserState.liveHost(for: spaceS.id) === first.tabManager.engineHost)
    }

    /// Every profile a window shows stays loaded, whatever the other windows switch to.
    func testProfilesShownByEveryWindowStayPinned() throws {
        let first = makeWindow(), second = makeWindow()
        browserContext.context.windows.add(first)
        browserContext.context.windows.add(second)
        let otherProfile = try browserContext.context.profileManager.createProfile(name: "Other").id
        let otherSpace = try browserContext.context.spaceManager.createSpace(name: "O", profileId: otherProfile)
        second.switchToSpace(otherSpace.id)
        first.switchToSpace(spaceS.id)
        first.switchToSpace(spaceT.id)

        XCTAssertEqual(browserContext.context.profileContexts.pinnedProfileIds, [spaceS.profileId, otherProfile])
    }

    func testLastWindowLeavingASpaceParksIt() {
        let window = makeWindow()
        window.switchToSpace(spaceS.id)
        window.switchToSpace(spaceT.id)

        let store = browserContext.context.browserState
        XCTAssertFalse(store.visibleSpaceIds.contains(spaceS.id))
        XCTAssertNil(store.liveHost(for: spaceS.id))
        XCTAssertTrue(store.liveHost(for: spaceT.id) === window.tabManager.engineHost)
    }

    func testTabUpdatesShipOnlyChangedFieldsUntilTabStateIsReseeded() async {
        let window = makeWindow()
        window.switchToSpace(spaceS.id)
        // Not in the tab manager: no engine emits patches of its own for it.
        var tab = Tab(url: URL(string: "https://a.example"), spaceId: spaceS.id)
        var patches: [[String: Any]] = []
        window.bridgeRouter.javaScriptSink = { _, arguments, completion in
            let messages = arguments["messages"] as? [[String: Any]] ?? (arguments["message"] as? [String: Any]).map { [$0] } ?? []
            for message in messages {
                for operation in message["operations"] as? [[String: Any]] ?? [] where operation["kind"] as? String == "tabUpdated" {
                    if let payload = operation["tab"] as? [String: Any], payload["id"] as? String == tab.id.uuidString { patches.append(payload) }
                }
            }
            completion()
        }
        // Patches ship on the bridge's coalescing flush: each emit waits for the patch it sends.
        func emit(shipping count: Int) async {
            window.emitVisibleTabUpdate(tab, spaceId: spaceS.id)
            _ = await pollUntil(timeout: 5) { patches.count >= count }
        }

        await emit(shipping: 1)
        tab.isLoading = true
        await emit(shipping: 2)
        window.emitVisibleTabUpdate(tab, spaceId: spaceS.id)
        // The new tab's structural patch ships whatever the unchanged one queued apart, before the next diff.
        _ = window.createTabStateFirst(url: URL(string: "https://b.example"))
        tab.isLoading = false
        await emit(shipping: 3)
        window.emitSpaceBrowserChange(spaceId: spaceS.id)
        await emit(shipping: 4)

        // A missing patch fails the test; subscripting past it would crash the whole test host.
        guard patches.count == 4 else { return XCTFail("a patch that changes nothing is not sent: got \(patches.count) patches") }
        XCTAssertEqual(patches[0].count, tab.runtimePatchData.count, "the first patch carries every field")
        XCTAssertEqual(Set(patches[1].keys), ["id", "isLoading"])
        XCTAssertEqual(Set(patches[2].keys), ["id", "isLoading"], "a sidebar patch for another tab leaves this one's diff alone")
        XCTAssertEqual(patches[3].count, tab.runtimePatchData.count, "full state reseeds the chrome, so the next patch is complete")
    }

    func testProgressReachesTheActiveTabInVisibleStepsAndABackgroundTabOnlyWhenDone() throws {
        let window = makeWindow()
        window.switchToSpace(spaceS.id)
        let background = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "https://background.example")))
        let backgroundEngine = try XCTUnwrap(window.tabManager.engineTab(for: background.id))
        let active = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "https://active.example")))
        let engine = try XCTUnwrap(window.tabManager.engineTab(for: active.id))
        func progress(_ id: UUID) -> Double? { window.tabManager.tab(for: id)?.estimatedProgress }

        window.tab(engine, didUpdateProgress: 0.3)
        window.tab(engine, didUpdateProgress: 0.32)
        XCTAssertEqual(progress(active.id), 0.3, "a step too small to see is not shipped")
        window.tab(engine, didUpdateProgress: 0.4)
        XCTAssertEqual(progress(active.id), 0.4)
        window.tab(engine, didUpdateProgress: 0.98)
        window.tab(engine, didUpdateProgress: 1)
        XCTAssertEqual(progress(active.id), 1, "the end of a load always ships")
        window.tab(engine, didUpdateProgress: 0)
        XCTAssertEqual(progress(active.id), 0, "the start of a load always ships")

        let backgroundProgress = progress(background.id)
        window.tab(backgroundEngine, didUpdateProgress: 0.5)
        XCTAssertEqual(progress(background.id), backgroundProgress)
        window.tab(backgroundEngine, didUpdateProgress: 1)
        XCTAssertEqual(progress(background.id), 1)
    }
}

