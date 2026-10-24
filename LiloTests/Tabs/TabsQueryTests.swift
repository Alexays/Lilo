import WebKit
import XCTest
@testable import Lilo

@MainActor
final class TabsQueryTests: XCTestCase {
    private var tabManager: TabManager!
    private var spaceId: UUID!

    override func setUp() {
        super.setUp()
        let engineFactory = WKEngineFactory()
        tabManager = TabManager(engineFactory: engineFactory)
        spaceId = UUID()
        tabManager.currentSpaceId = spaceId
    }

    override func tearDown() {
        tabManager = nil
        spaceId = nil
        super.tearDown()
    }

    private func makeTab(
        url: URL? = nil,
        title: String? = nil,
        isPinned: Bool = false,
        isBookmarked: Bool = false,
        isClosed: Bool = false,
        groupId: UUID? = nil
    ) -> Tab {
        Tab(
            url: url,
            title: title ?? Tab.fallbackTitle(for: url),
            isPinned: isPinned,
            isBookmarked: isBookmarked,
            isClosed: isClosed,
            groupId: groupId,
            spaceId: spaceId
        )
    }

    private func installTabs(_ inputTabs: [Tab], activeTabId: UUID? = nil) {
        let treeItems = inputTabs.enumerated().compactMap { index, tab -> TabTreeItem? in
            guard !tab.isBookmarked, !tab.isClosed || tab.isPinned else { return nil }
            let section: TabTreeItem.Section = tab.isPinned ? .pinned : .unpinned
            return TabTreeItem(
                spaceId: spaceId,
                kind: .tab,
                itemId: tab.id,
                parentFolderId: tab.groupId,
                section: section,
                sortOrder: index
            )
        }
        let state = try! BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: activeTabId,
            tabs: inputTabs,
            folders: [],
            treeItems: treeItems
        )
        tabManager.installSpaceTabStateForTests(SpaceTabState(state), spaceId: state.spaceId)
    }

    private func installRuntimeTabs(_ tabs: [Tab], activeTabId: UUID? = nil) {
        installTabs(tabs, activeTabId: activeTabId)
        if let activeTabId {
            tabManager.activateTabRuntime(id: activeTabId)
        }
    }

    private func makeRuntimeTab(url: URL? = nil, isPinned: Bool = false) -> Tab {
        tabManager.prepareTabRuntime(url: url, isPinned: isPinned)
    }

    private func closeWithBrowserStateStore(_ tabId: UUID) throws {
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: tabManager.activeOpenTabId,
            tabs: tabManager.currentTabs,
            folders: tabManager.folders(forSpace: spaceId),
            treeItems: tabManager.sidebarTreeItems(forSpace: spaceId)
        )
        let store = BrowserStateStoreHarness(states: [state])
        let changes = try store.mutate(.closeTab(spaceId: spaceId, tabId: tabId))
        if let changedState = changes.changedState {
            tabManager.installSpaceTabStateForTests(changedState.state, spaceId: changedState.spaceId)
        }
    }

    func testTabQueriesReflectLiveDurableStore() throws {
        let otherSpaceId = UUID()
        let currentTab = makeTab(url: URL(string: "https://current.example"), title: "Current")
        let otherTab = Tab(url: URL(string: "https://other.example"), title: "Other", spaceId: otherSpaceId)
        let currentState = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: currentTab.id,
            tabs: [currentTab],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: currentTab.id, parentFolderId: nil, section: .unpinned, sortOrder: 0)
            ]
        )
        let otherState = try BrowserStateFixture(
            spaceId: otherSpaceId,
            activeTabId: otherTab.id,
            tabs: [otherTab],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: otherSpaceId, kind: .tab, itemId: otherTab.id, parentFolderId: nil, section: .unpinned, sortOrder: 0)
            ]
        )
        let store = BrowserStateStore()
        store.storeSpace(
            id: spaceId,
            snapshot: BrowserStateStore.SpaceSnapshot(
                spaceTab: SpaceTab(spaceId: spaceId, state: SpaceTabState(currentState)),
                engines: [:]
            )
        )
        store.storeSpace(
            id: otherSpaceId,
            snapshot: BrowserStateStore.SpaceSnapshot(
                spaceTab: SpaceTab(spaceId: otherSpaceId, state: SpaceTabState(otherState)),
                engines: [:]
            )
        )
        tabManager.browserStateStore = store
        tabManager.applyDurableProjectionToRuntime(SpaceTabState(currentState), spaceId: spaceId)

        let replacementOtherTab = Tab(url: URL(string: "https://replacement.example"), title: "Replacement", spaceId: otherSpaceId)
        let replacementOtherState = try BrowserStateFixture(
            spaceId: otherSpaceId,
            activeTabId: replacementOtherTab.id,
            tabs: [replacementOtherTab],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: otherSpaceId, kind: .tab, itemId: replacementOtherTab.id, parentFolderId: nil, section: .unpinned, sortOrder: 0)
            ]
        )
        store.storeSpace(
            id: otherSpaceId,
            snapshot: BrowserStateStore.SpaceSnapshot(
                spaceTab: SpaceTab(spaceId: otherSpaceId, state: SpaceTabState(replacementOtherState)),
                engines: [:]
            )
        )

        // The runtime tab projection is a live view of the durable store: replacing the other
        // space's durable state (above) is reflected immediately, with no manual index rebuild.
        XCTAssertEqual(tabManager.currentTabs.map(\.id), [currentTab.id])
        XCTAssertEqual(tabManager.allTabs.map(\.id), [currentTab.id, replacementOtherTab.id])
        XCTAssertNil(tabManager.tab(for: otherTab.id))
        XCTAssertEqual(tabManager.tab(for: replacementOtherTab.id)?.id, replacementOtherTab.id)
        XCTAssertEqual(tabManager.tabIndex(for: currentTab.id), 0)
    }

    /// Extensions keep one tab id for a tab's whole life: a discard empties the adapter instead of closing
    /// it, and reactivation hands the same adapter the new engine.
    func testDiscardKeepsTheExtensionTabAcrossReactivation() throws {
        let windowAdapter = WindowExtensionAdapter(nsWindow: NSWindow())
        tabManager.windowAdapter = windowAdapter
        let discarded = makeRuntimeTab(url: URL(string: "https://example.com"))
        let active = makeRuntimeTab(url: URL(string: "https://example.net"))
        installRuntimeTabs([discarded, active], activeTabId: active.id)
        let snapshot = tabManager.parkCurrentSpaceRuntimeForSwitch()
        tabManager.restoreVisibleRuntime(snapshot.tabs, engines: snapshot.engines, activeTabId: active.id)
        let adapter = try XCTUnwrap(tabManager.tabAdapter(for: discarded.id))

        XCTAssertTrue(tabManager.trimActiveSpaceEngines(maxLiveEngines: 1))

        XCTAssertNil(tabManager.engineTab(for: discarded.id))
        XCTAssertTrue(tabManager.tabAdapter(for: discarded.id) === adapter)
        XCTAssertNil(adapter.engineTab, "a discarded tab's adapter must not hold the torn-down page")
        XCTAssertTrue(windowAdapter.extensionTabs.contains { $0 as AnyObject === adapter }, "a discarded tab stays listed")

        tabManager.activateTabRuntime(id: discarded.id)

        let revived = try XCTUnwrap(tabManager.engineTab(for: discarded.id))
        XCTAssertTrue(tabManager.tabAdapter(for: discarded.id) === adapter)
        XCTAssertTrue(adapter.engineTab === revived)
    }

    func testOffScreenTabWhoseProcessDiesIsRebuiltOnActivation() async throws {
        let background = makeRuntimeTab()
        let active = makeRuntimeTab()
        installRuntimeTabs([background, active], activeTabId: active.id)
        let engine = try XCTUnwrap(tabManager.engineTab(for: background.id))
        engine.wkWebView.loadHTMLString("<html><body>lost</body></html>", baseURL: nil as URL?)
        let loaded = await pollUntil { (try? await engine.wkWebView.evaluateJavaScript("document.body.textContent")) as? String == "lost" }
        XCTAssertTrue(loaded)
        let pid = try XCTUnwrap(WebViewPrivateAccessors(engine.wkWebView).pid("_webProcessIdentifier"))

        kill(pid_t(pid), SIGKILL)
        let lost = await pollUntil { engine.isPageLost }
        XCTAssertTrue(lost, "a page in no window must wait for activation instead of reloading")
        XCTAssertFalse(engine.isFrozen)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(WebViewPrivateAccessors(engine.wkWebView).pid("_webProcessIdentifier"), "no content process was respawned")

        tabManager.activateTabRuntime(id: background.id)

        let rebuilt = try XCTUnwrap(tabManager.engineTab(for: background.id))
        XCTAssertFalse(rebuilt === engine)
        XCTAssertFalse(rebuilt.isPageLost)
    }

    func testRestoreTabsCreatesActiveEngine() {
        let first = makeRuntimeTab(url: URL(string: "https://example.com"))
        let second = makeRuntimeTab(url: URL(string: "https://example.net"))
        installRuntimeTabs([first, second], activeTabId: first.id)
        let snapshot = tabManager.parkCurrentSpaceRuntimeForSwitch()

        tabManager.restoreVisibleRuntime(snapshot.tabs, activeTabId: first.id)

        XCTAssertEqual(tabManager.activeOpenTabId, first.id)
        XCTAssertNotNil(tabManager.engineTab(for: first.id))
    }

    func testRestoreTabsCanDeferActiveEngineCreation() {
        let first = makeRuntimeTab(url: URL(string: "https://example.com"))
        let second = makeRuntimeTab(url: URL(string: "https://example.net"))
        installRuntimeTabs([first, second], activeTabId: first.id)
        let snapshot = tabManager.parkCurrentSpaceRuntimeForSwitch()

        tabManager.restoreVisibleRuntime(snapshot.tabs, activeTabId: first.id, activateRestoredTab: false)

        XCTAssertEqual(tabManager.activeOpenTabId, first.id)
        XCTAssertNil(tabManager.engineTab(for: first.id))
    }

    func testRuntimeSnapshotDoesNotDetachTabsOrEngines() {
        let first = makeRuntimeTab(url: URL(string: "https://example.com"))
        let second = makeRuntimeTab(url: URL(string: "https://example.net"))
        installRuntimeTabs([first, second], activeTabId: first.id)

        let snapshot = tabManager.runtimeSnapshot()

        XCTAssertEqual(snapshot.tabs.map(\.id), [first.id, second.id])
        XCTAssertEqual(snapshot.activeTabId, first.id)
        XCTAssertNotNil(snapshot.engines[first.id])
        XCTAssertNotNil(snapshot.engines[second.id])
        XCTAssertEqual(tabManager.currentTabs.map(\.id), [first.id, second.id])
        XCTAssertNotNil(tabManager.engineTab(for: first.id))
        XCTAssertNotNil(tabManager.engineTab(for: second.id))
    }

    func testDetachTabForTransferClearsEngineHostRuntimeState() throws {
        let tab = makeRuntimeTab(url: URL(string: "https://example.com"))
        let engine = try XCTUnwrap(tabManager.engineTab(for: tab.id))
        let restoringStartedAt = Date(timeIntervalSince1970: 10)
        installTabs([tab], activeTabId: tab.id)
        tabManager.restoreVisibleRuntime(
            [tab],
            engines: [tab.id: engine],
            savedInteractionStates: [tab.id: "scroll-state"],
            restoringTabIds: [tab.id: restoringStartedAt],
            activeTabId: tab.id,
            activateRestoredTab: false
        )

        let detached = try XCTUnwrap(tabManager.detachTabForTransfer(id: tab.id))

        XCTAssertTrue(detached.engine === engine)
        XCTAssertNil(tabManager.engineHost.consumeSavedInteractionState(for: tab.id))
        XCTAssertNil(tabManager.engineHost.restoringTabIds[tab.id])
    }

    func testADiscardedTabKeepsItsMuteAndAgentControlForItsNextEngine() throws {
        let tab = makeRuntimeTab(url: URL(string: "https://example.com"))
        let other = makeRuntimeTab(url: URL(string: "https://example.net"))
        installRuntimeTabs([tab, other], activeTabId: tab.id)
        tabManager.setTabMuted(id: tab.id, muted: true)
        tabManager.mutateTab(id: tab.id) { $0.isAgentControlled = true; $0.isLoading = true }
        tabManager.activateTabRuntime(id: other.id)

        tabManager.discardEngine(tab.id)

        let discarded = try XCTUnwrap(tabManager.tab(for: tab.id))
        XCTAssertTrue(discarded.isMuted)
        XCTAssertTrue(discarded.isAgentControlled)
        XCTAssertFalse(discarded.isLoading, "the engine's own state goes with it")
        tabManager.activateTabRuntime(id: tab.id)
        XCTAssertEqual(tabManager.engineTab(for: tab.id)?.isAgentControlled, true)
    }

    func testDetachTabForTransferKeepsTheCarriedEnginesRuntimeState() throws {
        let tab = makeRuntimeTab(url: URL(string: "https://example.com"))
        installTabs([tab], activeTabId: tab.id)
        tabManager.mutateTab(id: tab.id) { $0.isAudioPlaying = true }

        _ = try XCTUnwrap(tabManager.detachTabForTransfer(id: tab.id))

        XCTAssertEqual(tabManager.tab(for: tab.id)?.isAudioPlaying, true)
    }

    func testRestoreVisibleRuntimeReplacesSavedInteractionStates() throws {
        let staleTab = makeRuntimeTab(url: URL(string: "https://stale.example"))
        let restoredTab = makeRuntimeTab(url: URL(string: "https://restored.example"))
        installTabs([staleTab, restoredTab], activeTabId: staleTab.id)
        tabManager.restoreVisibleRuntime(
            [staleTab],
            savedInteractionStates: [staleTab.id: "stale-state"],
            activeTabId: staleTab.id,
            activateRestoredTab: false
        )

        tabManager.restoreVisibleRuntime(
            [restoredTab],
            savedInteractionStates: [restoredTab.id: "restored-state"],
            activeTabId: restoredTab.id,
            activateRestoredTab: false
        )

        XCTAssertNil(tabManager.engineHost.consumeSavedInteractionState(for: staleTab.id))
        XCTAssertEqual(tabManager.engineHost.consumeSavedInteractionState(for: restoredTab.id) as? String, "restored-state")
    }

    func testCurrentSpaceAccessorsIgnoreTabsFromOtherSpaces() throws {
        let currentSpaceId = UUID()
        let otherSpaceId = UUID()
        let currentTabId = UUID()
        let otherTabId = UUID()
        let currentState = try BrowserStateFixture(
            spaceId: currentSpaceId,
            activeTabId: currentTabId,
            tabs: [
                Tab(id: currentTabId, url: URL(string: "https://current.example"), title: "Current", spaceId: currentSpaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: currentSpaceId, kind: .tab, itemId: currentTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
            ]
        )
        let otherState = try BrowserStateFixture(
            spaceId: otherSpaceId,
            activeTabId: otherTabId,
            tabs: [
                Tab(id: otherTabId, url: URL(string: "https://other.example"), title: "Other", spaceId: otherSpaceId)
            ],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: otherSpaceId, kind: .tab, itemId: otherTabId, parentFolderId: nil, section: .unpinned, sortOrder: 0)
            ]
        )

        tabManager.currentSpaceId = currentSpaceId
        tabManager.installSpaceTabStateForTests(SpaceTabState(currentState), spaceId: currentState.spaceId)
        tabManager.installSpaceTabStateForTests(SpaceTabState(otherState), spaceId: otherState.spaceId)
        tabManager.activeTabId = otherTabId

        XCTAssertEqual(tabManager.currentTabs.map(\.id), [currentTabId])
        XCTAssertEqual(tabManager.openTabs.map(\.id), [currentTabId])
        XCTAssertNil(tabManager.activeTab)
    }

    func testActivatingColdTabRecreatesEngineWithoutTabLifecycleState() {
        let tab = makeTab(url: URL(string: "https://example.com"))
        installTabs([tab])
        tabManager.restoreVisibleRuntime(tabManager.currentTabs, engines: [:], activeTabId: nil)

        tabManager.activateTabRuntime(id: tab.id)

        XCTAssertNotNil(tabManager.engineTab(for: tab.id))
        XCTAssertNil(tabManager.currentTabs.first(where: { $0.id == tab.id })?.bridgeData["lifecycleState"])
    }

    func testClosingPinnedTabRestoresHomeURLFavicon() throws {
        let homeURL = URL(string: "https://example.com")!
        let currentURL = URL(string: "https://example.org/news")!
        let homeTitle = "Example Home"
        let currentTitle = "News"
        var tab = makeTab(url: currentURL)
        tab.isPinned = true
        tab.title = currentTitle
        tab.faviconDataURL = "data:image/png;base64,current"
        tab.faviconDominantColor = "#222222"
        tab.homeURL = homeURL
        tab.homeTitle = homeTitle
        tab.homeFaviconDataURL = "data:image/png;base64,home"
        tab.homeFaviconDominantColor = "#111111"
        installTabs([tab])

        try closeWithBrowserStateStore(tab.id)

        let closedTab = tabManager.currentTabs.first { $0.id == tab.id }
        XCTAssertNotNil(closedTab)
        XCTAssertEqual(closedTab?.url, homeURL)
        XCTAssertEqual(closedTab?.title, homeTitle)
        XCTAssertEqual(closedTab?.faviconDataURL, "data:image/png;base64,home")
        XCTAssertEqual(closedTab?.faviconDominantColor, "#111111")
        XCTAssertTrue(closedTab?.isClosed ?? false)
    }

    func testClosingBookmarkedTabRestoresHomeURLFavicon() throws {
        let homeURL = URL(string: "https://example.com/docs")!
        let currentURL = URL(string: "https://example.net")!
        let homeTitle = "Docs Home"
        let currentTitle = "Repository"
        var tab = makeTab(url: currentURL)
        tab.isBookmarked = true
        tab.title = currentTitle
        tab.faviconDataURL = "data:image/png;base64,current-bookmark"
        tab.faviconDominantColor = "#FAFAFA"
        tab.homeURL = homeURL
        tab.homeTitle = homeTitle
        tab.homeFaviconDataURL = "data:image/png;base64,home-bookmark"
        tab.homeFaviconDominantColor = "#0A0A0A"
        installTabs([tab])

        try closeWithBrowserStateStore(tab.id)

        let closedTab = tabManager.currentTabs.first { $0.id == tab.id }
        XCTAssertNotNil(closedTab)
        XCTAssertEqual(closedTab?.url, homeURL)
        XCTAssertEqual(closedTab?.title, homeTitle)
        XCTAssertEqual(closedTab?.faviconDataURL, "data:image/png;base64,home-bookmark")
        XCTAssertEqual(closedTab?.faviconDominantColor, "#0A0A0A")
        XCTAssertTrue(closedTab?.isClosed ?? false)
    }

    func testClosingPinnedTabDoesNotOverwriteHomeMetadataFromSameHostDifferentPath() throws {
        let homeURL = URL(string: "https://example.com")!
        let currentURL = URL(string: "https://example.com/news")!
        var tab = makeTab(url: currentURL)
        tab.isPinned = true
        tab.title = "Example News"
        tab.faviconDataURL = "data:image/png;base64,news"
        tab.faviconDominantColor = "#EFEFEF"
        tab.homeURL = homeURL
        tab.homeTitle = "Example Home"
        tab.homeFaviconDataURL = "data:image/png;base64,home-root"
        tab.homeFaviconDominantColor = "#101010"
        installTabs([tab])

        try closeWithBrowserStateStore(tab.id)

        let closedTab = tabManager.currentTabs.first { $0.id == tab.id }
        XCTAssertNotNil(closedTab)
        XCTAssertEqual(closedTab?.url, homeURL)
        XCTAssertEqual(closedTab?.title, "Example Home")
        XCTAssertEqual(closedTab?.faviconDataURL, "data:image/png;base64,home-root")
        XCTAssertEqual(closedTab?.faviconDominantColor, "#101010")
    }

    func testMatchesHomeURLDoesNotMatchDifferentPathOnSameHost() {
        let tab = Tab(url: URL(string: "https://example.com")!, homeURL: URL(string: "https://example.com")!)
        XCTAssertFalse(tab.matchesHomeURL(URL(string: "https://example.com/news")!))
    }

    func testMatchesHomeURLMatchesEquivalentRootURLs() {
        let tab = Tab(url: URL(string: "https://example.com")!, homeURL: URL(string: "https://example.com")!)
        XCTAssertTrue(tab.matchesHomeURL(URL(string: "https://example.com/")!))
    }
}
