import AppKit
import XCTest
@testable import Lilo

@MainActor
final class TabArchiveTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private let hour: TimeInterval = 3600

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
    }

    override func tearDown() {
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    private func makeWindow(isPrivate: Bool = false) throws -> (MainWindowController, Space) {
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId, isPrivate: isPrivate)
        let window = makeTestWindow(context, showing: space.id)
        return (window, space)
    }

    private func openTab(_ window: MainWindowController, _ url: String, activate: Bool = false) throws -> Tab {
        try XCTUnwrap(window.createTabStateFirst(url: URL(string: url), activate: activate))
    }

    private func openTabIds(_ window: MainWindowController) -> Set<UUID> {
        Set(window.tabManager.openTabs.map(\.id))
    }

    private func unpinnedURLs(_ window: MainWindowController, _ space: Space) -> [String] {
        let tree = window.context.browserState.spaceTabState(forSpace: space.id)?.tree.unpinned ?? []
        return tree.compactMap { node in
            guard case let .tab(tab) = node, !tab.isClosed else { return nil }
            return tab.url
        }
    }

    func testAnUnpinnedTabLeftAloneLongerThanItsSpaceDelayIsArchived() throws {
        let (window, space) = try makeWindow()
        let active = try openTab(window, "https://active.example/", activate: true)
        let idle = try openTab(window, "https://idle.example/")

        window.context.archiveIdleTabs(now: Date().addingTimeInterval(11 * hour))
        XCTAssertTrue(openTabIds(window).contains(idle.id), "12 hours by default: not yet")

        window.context.archiveIdleTabs(now: Date().addingTimeInterval(13 * hour))
        XCTAssertFalse(openTabIds(window).contains(idle.id))
        XCTAssertTrue(openTabIds(window).contains(active.id), "the tab on screen stays")
        XCTAssertEqual(window.context.tabArchive.entries.map(\.url.absoluteString), ["https://idle.example/"])
        XCTAssertEqual(window.archivedTabSummaries().compactMap { $0["url"] as? String }, ["https://idle.example/"])

        try window.context.spaceManager.updateSpace(id: space.id) { $0.archiveAfterHours = 168 }
        let weekly = try openTab(window, "https://weekly.example/")
        window.context.archiveIdleTabs(now: Date().addingTimeInterval(13 * hour))
        XCTAssertTrue(openTabIds(window).contains(weekly.id), "the space's own delay applies")
        window.context.archiveIdleTabs(now: Date().addingTimeInterval(169 * hour))
        XCTAssertFalse(openTabIds(window).contains(weekly.id))
    }

    func testPinnedFolderedPlayingCallingAgentShownAndNeverTabsAreNotArchived() throws {
        let (window, space) = try makeWindow()
        _ = try openTab(window, "https://active.example/", activate: true)
        let pinned = try openTab(window, "https://pinned.example/")
        let grouped = try openTab(window, "https://grouped.example/")
        let groupedPeer = try openTab(window, "https://peer.example/")
        let playing = try openTab(window, "https://playing.example/")
        let calling = try openTab(window, "https://calling.example/")
        let driven = try openTab(window, "https://agent.example/")
        let shown = try openTab(window, "https://shown.example/")
        try window.applyBrowserCommand(.setPinned(spaceId: space.id, tabId: pinned.id, isPinned: true))
        try window.applyBrowserCommand(.groupTabs(spaceId: space.id, sourceTabId: grouped.id, targetTabId: groupedPeer.id))
        window.tabManager.updateTab(id: playing.id) { $0.isAudioPlaying = true }
        window.tabManager.updateTab(id: calling.id) { $0.isMicrophoneActive = true }
        window.tabManager.updateTab(id: driven.id) { $0.isAgentControlled = true }
        window.context.browserState.displayedTabIds.insert(shown.id)
        let kept = [pinned, grouped, groupedPeer, playing, calling, driven, shown].map(\.id)

        window.context.archiveIdleTabs(now: Date().addingTimeInterval(30 * 24 * hour))
        XCTAssertTrue(Set(kept).isSubset(of: openTabIds(window)))
        XCTAssertTrue(window.context.tabArchive.entries.isEmpty)

        window.context.browserState.displayedTabIds.remove(shown.id)
        try window.context.spaceManager.updateSpace(id: space.id) { $0.archiveAfterHours = 0 }
        window.context.archiveIdleTabs(now: Date().addingTimeInterval(30 * 24 * hour))
        XCTAssertTrue(openTabIds(window).contains(shown.id), "Never keeps every tab")
    }

    func testAPrivateSpaceArchivesTooButKeepsItsArchiveOffTheDisk() async throws {
        let (window, space) = try makeWindow(isPrivate: true)
        _ = try openTab(window, "https://active.example/", activate: true)
        let idle = try openTab(window, "https://secret.example/")

        window.context.archiveIdleTabs(now: Date().addingTimeInterval(13 * hour))

        XCTAssertFalse(openTabIds(window).contains(idle.id))
        XCTAssertEqual(window.context.tabArchive.entries.map(\.spaceId), [space.id])
        let file = URL(fileURLWithPath: window.context.appSupportDirectory).appendingPathComponent("ArchivedTabs.json")
        let written = await pollUntil(timeout: 5) { (try? Data(contentsOf: file)) != nil }
        XCTAssertTrue(written)
        let onDisk = try JSONDecoder().decode([TabArchive.Entry].self, from: Data(contentsOf: file))
        XCTAssertTrue(onDisk.isEmpty)
    }

    func testReopeningAnArchivedTabPutsItBackInTheUnpinnedListAndShowsIt() throws {
        let (window, space) = try makeWindow()
        _ = try openTab(window, "https://active.example/", activate: true)
        _ = try openTab(window, "https://idle.example/")
        window.context.archiveIdleTabs(now: Date().addingTimeInterval(13 * hour))
        let entry = try XCTUnwrap(window.context.tabArchive.entries.first)

        window.restoreArchivedTabs([entry.id])

        XCTAssertEqual(unpinnedURLs(window, space), ["https://active.example/", "https://idle.example/"])
        XCTAssertEqual(window.tabManager.activeTab?.url?.absoluteString, "https://idle.example/")
        XCTAssertTrue(window.context.tabArchive.entries.isEmpty)
    }

    func testClearArchivesTheUnpinnedTabsAndUndoPutsThemBackInOrder() throws {
        let (window, space) = try makeWindow()
        let events = BridgeEventRecorder(window.bridgeRouter)
        _ = try openTab(window, "https://a.example/", activate: true)
        _ = try openTab(window, "https://b.example/")
        _ = try openTab(window, "https://c.example/")
        let pinned = try openTab(window, "https://pinned.example/")
        try window.applyBrowserCommand(.setPinned(spaceId: space.id, tabId: pinned.id, isPinned: true))
        _ = try openTab(window, "https://d.example/")
        let ordered = ["https://a.example/", "https://b.example/", "https://c.example/", "https://d.example/"]
        XCTAssertEqual(unpinnedURLs(window, space), ordered)

        window.clearUnpinnedTabs(nil)

        XCTAssertEqual(unpinnedURLs(window, space), ["https://a.example/"], "the tab on screen stays")
        XCTAssertTrue(openTabIds(window).contains(pinned.id))
        let toast = try XCTUnwrap(events.data("tabClosedUndoable").last)
        let ids = try XCTUnwrap(toast["archivedIds"] as? [String])
        XCTAssertEqual(ids.count, 3)

        window.restoreArchivedTabs(Set(ids.compactMap(UUID.init(uuidString:))))

        XCTAssertEqual(unpinnedURLs(window, space), ordered)
        XCTAssertEqual(window.tabManager.activeTab?.url?.absoluteString, "https://a.example/", "an undo shows nothing new")
        XCTAssertTrue(window.context.tabArchive.entries.isEmpty)
    }

    func testClearKeepsPlayingCallingAndAgentTabs() throws {
        let (window, space) = try makeWindow()
        _ = try openTab(window, "https://active.example/", activate: true)
        let playing = try openTab(window, "https://playing.example/")
        let calling = try openTab(window, "https://calling.example/")
        let driven = try openTab(window, "https://agent.example/")
        let idle = try openTab(window, "https://idle.example/")
        window.tabManager.updateTab(id: playing.id) { $0.isAudioPlaying = true }
        window.tabManager.updateTab(id: calling.id) { $0.isMicrophoneActive = true }
        window.tabManager.updateTab(id: driven.id) { $0.isAgentControlled = true }

        window.clearUnpinnedTabs(nil)

        XCTAssertEqual(unpinnedURLs(window, space), ["https://active.example/", "https://playing.example/", "https://calling.example/", "https://agent.example/"])
        XCTAssertFalse(openTabIds(window).contains(idle.id))
    }

    func testClearKeepsTheDockedTab() throws {
        let (window, space) = try makeWindow()
        let docked = try openTab(window, "https://call.example/", activate: true)
        let engine = try XCTUnwrap(window.tabManager.engineTab(for: docked.id))
        _ = try openTab(window, "https://active.example/", activate: true)
        window.tabDock.dock(engine, logicalSize: .zero, in: window.contentContainerView, above: nil, chromeView: window.chromeWebView)

        window.clearUnpinnedTabs(nil)

        XCTAssertEqual(unpinnedURLs(window, space), ["https://call.example/", "https://active.example/"])
    }

    func testTheArchiveOutlivesTheLaunchForThirtyDays() async throws {
        let (window, space) = try makeWindow()
        let context = window.context
        let file = URL(fileURLWithPath: context.appSupportDirectory).appendingPathComponent("ArchivedTabs.json")
        let old = TabArchive.Entry(spaceId: space.id, url: URL(string: "https://old.example/")!, title: "Old", archivedAt: Date().addingTimeInterval(-31 * 24 * hour))
        let recent = TabArchive.Entry(spaceId: space.id, url: URL(string: "https://recent.example/")!, title: "Recent")
        try JSONEncoder().encode([old, recent]).write(to: file)

        context.restoreTabArchive()

        XCTAssertEqual(context.tabArchive.entries.map(\.title), ["Recent"])
        let onDisk = { (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([TabArchive.Entry].self, from: $0) } }
        let rewritten = await pollUntil(timeout: 5) { onDisk()?.map(\.title) == ["Recent"] }
        XCTAssertTrue(rewritten, "the file follows the archive")

        window.clearArchivedTabs()
        let cleared = await pollUntil(timeout: 5) { onDisk()?.isEmpty == true }
        XCTAssertTrue(cleared)
    }

    func testTheArchiveDelayIsSavedWithTheSpace() async throws {
        let (window, space) = try makeWindow()
        let handler = SpaceBridgeHandler(spaceManager: window.context.spaceManager, windowController: window)

        _ = await handler.handle(message: BridgeMessage(dictionary: [
            "action": "updateSpace", "payload": ["id": space.id.uuidString, "archiveAfterHours": 720]
        ])!)

        XCTAssertEqual(window.context.spaceManager.space(with: space.id)?.archiveAfterHours, 720)
        let pool = window.context.dbManager.globalPool
        let saved = await pollUntil(timeout: 5) {
            (try? pool.read { db in try Space.fetchOne(db, key: space.id.uuidString) })?.archiveAfterHours == 720
        }
        XCTAssertTrue(saved)
    }
}

@MainActor
final class SpaceTabArchiveClockTests: XCTestCase {
    func testLeavingATabRestartsItsClockAndOnlyTopLevelUnpinnedTabsHaveOne() {
        let spaceId = UUID()
        var session = SpaceTab(spaceId: spaceId, state: SpaceTabState(activeTabId: nil, activationHistory: [], tree: .empty))
        let a = Tab(url: URL(string: "https://a.example/"), title: "A", spaceId: spaceId)
        let b = Tab(url: URL(string: "https://b.example/"), title: "B", spaceId: spaceId)
        let c = Tab(url: URL(string: "https://c.example/"), title: "C", spaceId: spaceId)
        session.createTab(a, activate: true)
        session.createTab(b, activate: false)
        session.createTab(c, activate: false)
        XCTAssertEqual(Set(session.state.viewedAt.keys), [a.id, b.id, c.id])

        let old = Date(timeIntervalSince1970: 0)
        var state = session.state
        state.viewedAt[b.id] = old
        session = SpaceTab(spaceId: spaceId, state: state)
        XCTAssertEqual(session.state.viewedAt[b.id], old, "a saved clock survives the load")
        session.activateTab(b.id)
        session.activateTab(a.id)
        XCTAssertGreaterThan(session.state.viewedAt[b.id] ?? old, old, "leaving b restarts its clock")

        session.setPinned(c.id, pinned: true)
        XCTAssertNil(session.state.viewedAt[c.id], "pinned tabs are never archived")
        session.groupTabs(sourceTabId: a.id, targetTabId: b.id)
        XCTAssertTrue(session.state.viewedAt.isEmpty, "nor are tabs in folders")
    }

    func testATabWithoutAClockStartsItsClockOnLoad() throws {
        let spaceId = UUID()
        var session = SpaceTab(spaceId: spaceId, state: SpaceTabState(activeTabId: nil, activationHistory: [], tree: .empty))
        let tab = Tab(url: URL(string: "https://t.example/"), title: "T", spaceId: spaceId)
        session.createTab(tab, activate: false)
        var state = session.state
        state.viewedAt = [:]

        let loadedAt = Date()
        let loaded = SpaceTab(spaceId: spaceId, state: state)

        XCTAssertGreaterThanOrEqual(loaded.state.viewedAt[tab.id] ?? .distantPast, loadedAt)
    }
}
