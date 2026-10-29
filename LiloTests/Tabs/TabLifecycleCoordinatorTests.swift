import WebKit
import XCTest
@testable import Lilo

final class TabLifecycleCoordinatorTests: XCTestCase {
    private func makeTab(
        id: UUID,
        isClosed: Bool = false,
        isAudioPlaying: Bool = false,
        lastAudioStoppedAt: Date? = nil,
        isMicrophoneActive: Bool = false,
        lastCaptureStoppedAt: Date? = nil
    ) -> Tab {
        var tab = Tab(id: id, isClosed: isClosed)
        tab.isAudioPlaying = isAudioPlaying
        tab.lastAudioStoppedAt = lastAudioStoppedAt
        tab.isMicrophoneActive = isMicrophoneActive
        tab.lastCaptureStoppedAt = lastCaptureStoppedAt
        return tab
    }

    func testRetainsRecentlyCapturingTabsDuringGracePeriod() {
        let recentlyCapturing = UUID()
        let silent = UUID()
        let coordinator = TabLifecycleCoordinator(
            maxNormalRetainedEnginesPerHiddenSpace: 1,
            captureGracePeriod: 30
        )

        let retained = coordinator.retainedEngineIds(
            tabs: [
                makeTab(
                    id: recentlyCapturing,
                    lastCaptureStoppedAt: Date(timeIntervalSince1970: 90)
                ),
                makeTab(id: silent)
            ],
            availableEngineIds: [recentlyCapturing, silent],
            preferredTabId: nil,
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(retained, [recentlyCapturing, silent])
    }

    func testDoesNotRetainExpiredRecentlyCapturingTabsBeyondNormalLimit() {
        let expired = UUID()
        let silent = UUID()
        let coordinator = TabLifecycleCoordinator(
            maxNormalRetainedEnginesPerHiddenSpace: 1,
            captureGracePeriod: 30
        )

        let retained = coordinator.retainedEngineIds(
            tabs: [
                makeTab(
                    id: expired,
                    lastCaptureStoppedAt: Date(timeIntervalSince1970: 60)
                ),
                makeTab(id: silent)
            ],
            availableEngineIds: [expired, silent],
            preferredTabId: nil,
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(retained, [expired])
    }

    func testRetainsAudioTabsBeyondNormalHiddenSpaceLimit() {
        let preferred = UUID()
        let audio = UUID()
        let otherAudio = UUID()
        let silent = UUID()
        let coordinator = TabLifecycleCoordinator(maxNormalRetainedEnginesPerHiddenSpace: 1)

        let retained = coordinator.retainedEngineIds(
            tabs: [
                makeTab(id: preferred),
                makeTab(id: audio, isAudioPlaying: true),
                makeTab(id: otherAudio, isAudioPlaying: true),
                makeTab(id: silent)
            ],
            availableEngineIds: [preferred, audio, otherAudio, silent],
            preferredTabId: preferred
        )

        XCTAssertEqual(retained, [preferred, audio, otherAudio])
    }

    func testDoesNotRetainClosedTabs() {
        let closedAudio = UUID()
        let openSilent = UUID()
        let coordinator = TabLifecycleCoordinator(maxNormalRetainedEnginesPerHiddenSpace: 1)

        let retained = coordinator.retainedEngineIds(
            tabs: [
                makeTab(id: closedAudio, isClosed: true, isAudioPlaying: true),
                makeTab(id: openSilent)
            ],
            availableEngineIds: [closedAudio, openSilent],
            preferredTabId: nil
        )

        XCTAssertEqual(retained, [openSilent])
    }

    func testRetainsRecentlyAudibleTabsDuringGracePeriod() {
        let recentlyAudible = UUID()
        let silent = UUID()
        let coordinator = TabLifecycleCoordinator(
            maxNormalRetainedEnginesPerHiddenSpace: 1,
            audioGracePeriod: 30
        )

        let retained = coordinator.retainedEngineIds(
            tabs: [
                makeTab(
                    id: recentlyAudible,
                    lastAudioStoppedAt: Date(timeIntervalSince1970: 90)
                ),
                makeTab(id: silent)
            ],
            availableEngineIds: [recentlyAudible, silent],
            preferredTabId: nil,
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(retained, [recentlyAudible, silent])
    }

    func testDoesNotRetainExpiredRecentlyAudibleTabsBeyondNormalLimit() {
        let expired = UUID()
        let silent = UUID()
        let coordinator = TabLifecycleCoordinator(
            maxNormalRetainedEnginesPerHiddenSpace: 1,
            audioGracePeriod: 30
        )

        let retained = coordinator.retainedEngineIds(
            tabs: [
                makeTab(
                    id: expired,
                    lastAudioStoppedAt: Date(timeIntervalSince1970: 60)
                ),
                makeTab(id: silent)
            ],
            availableEngineIds: [expired, silent],
            preferredTabId: nil,
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(retained, [expired])
    }

    // MARK: - Active-space LRU

    func testActiveSpaceKeepsActiveAndMostRecentUpToBudget() {
        let active = UUID(); let recent1 = UUID(); let recent2 = UUID(); let old = UUID()
        let coordinator = TabLifecycleCoordinator(policy: .foreground)

        let keep = coordinator.activeSpaceEnginesToKeep(
            tabs: [active, recent1, recent2, old].map { makeTab(id: $0) },
            availableEngineIds: [active, recent1, recent2, old],
            activeTabId: active,
            activationHistory: [active, recent1, recent2, old],
            maxLiveEngines: 3
        )

        XCTAssertEqual(keep, [active, recent1, recent2])
    }

    // The caller owns the budget: policy never silently overrides maxLiveEngines. Collapsing
    // .background to 1 lives in MainWindowController.activeSpaceTrimBudget so a stray
    // .background coordinator can't discard a visible space that was handed a real budget.
    func testActiveSpaceBudgetIsCallerOwnedRegardlessOfPolicy() {
        let active = UUID(); let recent = UUID(); let old = UUID()
        let coordinator = TabLifecycleCoordinator(policy: .background)

        let keep = coordinator.activeSpaceEnginesToKeep(
            tabs: [active, recent, old].map { makeTab(id: $0) },
            availableEngineIds: [active, recent, old],
            activeTabId: active,
            activationHistory: [active, recent, old],
            maxLiveEngines: 2
        )

        XCTAssertEqual(keep, [active, recent])
    }

    func testActiveSpaceBudgetOfOneCollapsesToActiveAndProtected() {
        let active = UUID(); let audio = UUID(); let other = UUID()
        let coordinator = TabLifecycleCoordinator(policy: .background)

        let keep = coordinator.activeSpaceEnginesToKeep(
            tabs: [makeTab(id: active), makeTab(id: audio, isAudioPlaying: true), makeTab(id: other)],
            availableEngineIds: [active, audio, other],
            activeTabId: active,
            activationHistory: [active, other, audio],
            maxLiveEngines: 1
        )

        XCTAssertEqual(keep, [active, audio])
    }

    func testActiveSpaceRetainsAudioBeyondBudget() {
        let active = UUID(); let audio = UUID(); let silent = UUID()
        let coordinator = TabLifecycleCoordinator(policy: .foreground)

        let keep = coordinator.activeSpaceEnginesToKeep(
            tabs: [makeTab(id: active), makeTab(id: audio, isAudioPlaying: true), makeTab(id: silent)],
            availableEngineIds: [active, audio, silent],
            activeTabId: active,
            activationHistory: [active, silent, audio],
            maxLiveEngines: 1
        )

        XCTAssertEqual(keep, [active, audio])
    }

    func testEvictsOldestHiddenSpacesWithNormalEnginesButIgnoresAudioOnlySpaces() {
        let oldSpace = UUID()
        let newerSpace = UUID()
        let audioOnlySpace = UUID()
        let oldTab = UUID()
        let newerTab = UUID()
        let audioTab = UUID()
        let coordinator = TabLifecycleCoordinator(maxHiddenSpacesWithNormalRetainedEngines: 1)

        let evicted = coordinator.hiddenSpacesToEvict(
            [
                .init(
                    id: oldSpace,
                    tabs: [makeTab(id: oldTab)],
                    retainedEngineIds: [oldTab],
                    lastAccessedAt: Date(timeIntervalSince1970: 1)
                ),
                .init(
                    id: newerSpace,
                    tabs: [makeTab(id: newerTab)],
                    retainedEngineIds: [newerTab],
                    lastAccessedAt: Date(timeIntervalSince1970: 2)
                ),
                .init(
                    id: audioOnlySpace,
                    tabs: [makeTab(id: audioTab, isAudioPlaying: true)],
                    retainedEngineIds: [audioTab],
                    lastAccessedAt: Date(timeIntervalSince1970: 0)
                )
            ],
            protectedSpaceId: nil
        )

        XCTAssertEqual(evicted, [oldSpace])
    }

    func testEvictionIgnoresRecentlyAudibleOnlySpacesDuringGracePeriod() {
        let recentlyAudibleSpace = UUID()
        let normalSpace = UUID()
        let recentTab = UUID()
        let normalTab = UUID()
        let coordinator = TabLifecycleCoordinator(maxHiddenSpacesWithNormalRetainedEngines: 1)

        let evicted = coordinator.hiddenSpacesToEvict(
            [
                .init(
                    id: recentlyAudibleSpace,
                    tabs: [
                        makeTab(
                            id: recentTab,
                            lastAudioStoppedAt: Date(timeIntervalSince1970: 90)
                        )
                    ],
                    retainedEngineIds: [recentTab],
                    lastAccessedAt: Date(timeIntervalSince1970: 0)
                ),
                .init(
                    id: normalSpace,
                    tabs: [makeTab(id: normalTab)],
                    retainedEngineIds: [normalTab],
                    lastAccessedAt: Date(timeIntervalSince1970: 1)
                )
            ],
            protectedSpaceId: nil,
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(evicted, [])
    }

    func testRetainsRestoringTabsDuringGracePeriod() {
        let restoring = UUID()
        let silent = UUID()
        let coordinator = TabLifecycleCoordinator(
            maxNormalRetainedEnginesPerHiddenSpace: 1,
            restorationGracePeriod: 10
        )

        let retained = coordinator.retainedEngineIds(
            tabs: [
                makeTab(id: restoring),
                makeTab(id: silent)
            ],
            availableEngineIds: [restoring, silent],
            preferredTabId: nil,
            restoringTabIds: [restoring: Date(timeIntervalSince1970: 95)],
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(retained, [restoring, silent])
    }

    func testDoesNotRetainExpiredRestoringTabsBeyondNormalLimit() {
        let expired = UUID()
        let silent = UUID()
        let coordinator = TabLifecycleCoordinator(
            maxNormalRetainedEnginesPerHiddenSpace: 1,
            restorationGracePeriod: 10
        )

        let retained = coordinator.retainedEngineIds(
            tabs: [
                makeTab(id: expired),
                makeTab(id: silent)
            ],
            availableEngineIds: [expired, silent],
            preferredTabId: nil,
            restoringTabIds: [expired: Date(timeIntervalSince1970: 80)],
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(retained, [expired])
    }

    func testBackgroundPolicyDropsNormalHiddenSpaceEnginesButKeepsAudioAndRestoring() {
        let normal = UUID()
        let audio = UUID()
        let restoring = UUID()
        let coordinator = TabLifecycleCoordinator(policy: .background)

        let retained = coordinator.retainedEngineIds(
            tabs: [
                makeTab(id: normal),
                makeTab(id: audio, isAudioPlaying: true),
                makeTab(id: restoring)
            ],
            availableEngineIds: [normal, audio, restoring],
            preferredTabId: normal,
            restoringTabIds: [restoring: Date(timeIntervalSince1970: 95)],
            now: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(retained, [audio, restoring])
    }

    func testPinnedAndBookmarkedTabsDoNotBypassNormalHiddenRetentionLimit() {
        let pinned = UUID()
        let bookmarked = UUID()
        let coordinator = TabLifecycleCoordinator(maxNormalRetainedEnginesPerHiddenSpace: 1)

        var pinnedTab = makeTab(id: pinned)
        pinnedTab.isPinned = true
        var bookmarkedTab = makeTab(id: bookmarked)
        bookmarkedTab.isBookmarked = true

        let retained = coordinator.retainedEngineIds(
            tabs: [pinnedTab, bookmarkedTab],
            availableEngineIds: [pinned, bookmarked],
            preferredTabId: nil
        )

        XCTAssertEqual(retained.count, 1)
        XCTAssertTrue(retained.isSubset(of: [pinned, bookmarked]))
    }

    func testClosedPinnedAndBookmarkedTabsAreNotRetainedAsRuntime() {
        let pinned = UUID()
        let bookmarked = UUID()
        let coordinator = TabLifecycleCoordinator(maxNormalRetainedEnginesPerHiddenSpace: 2)

        var pinnedTab = makeTab(id: pinned)
        pinnedTab.isPinned = true
        pinnedTab.isClosed = true
        var bookmarkedTab = makeTab(id: bookmarked)
        bookmarkedTab.isBookmarked = true
        bookmarkedTab.isClosed = true

        let tabs = [pinnedTab, bookmarkedTab]
        let retained = coordinator.retainedEngineIds(
            tabs: tabs,
            availableEngineIds: [pinned, bookmarked],
            preferredTabId: pinned
        )
        let states = coordinator.lifecycleStates(
            tabs: tabs,
            availableEngineIds: [pinned, bookmarked],
            activeTabId: pinned
        )

        XCTAssertTrue(retained.isEmpty)
        XCTAssertTrue(states.isEmpty)
    }

    func testBackgroundPolicyKeepsTabsUsingCaptureDevices() {
        let normal = UUID()
        let microphone = UUID()
        let camera = UUID()
        let screen = UUID()
        let companion = UUID()
        let coordinator = TabLifecycleCoordinator(policy: .background)

        var microphoneTab = makeTab(id: microphone)
        microphoneTab.isMicrophoneActive = true
        var cameraTab = makeTab(id: camera)
        cameraTab.isCameraActive = true
        var screenTab = makeTab(id: screen)
        screenTab.isScreenSharing = true
        var companionTab = makeTab(id: companion)
        companionTab.isInCall = true

        let retained = coordinator.retainedEngineIds(
            tabs: [
                makeTab(id: normal),
                microphoneTab,
                cameraTab,
                screenTab,
                companionTab
            ],
            availableEngineIds: [normal, microphone, camera, screen, companion],
            preferredTabId: normal
        )

        XCTAssertEqual(retained, [microphone, camera, screen, companion], "a call without capture, like Meet's companion mode, is kept too")
    }

    func testLifecycleStatesExposeActiveRestoringLoadedAndDiscardedTabs() {
        let active = UUID()
        let restoring = UUID()
        let loadedHidden = UUID()
        let discarded = UUID()
        let closed = UUID()
        let restorationStartedAt = Date(timeIntervalSince1970: 10)
        let coordinator = TabLifecycleCoordinator()

        let states = coordinator.lifecycleStates(
            tabs: [
                makeTab(id: active),
                makeTab(id: restoring),
                makeTab(id: loadedHidden),
                makeTab(id: discarded),
                makeTab(id: closed, isClosed: true)
            ],
            availableEngineIds: [active, restoring, loadedHidden],
            activeTabId: active,
            restoringTabIds: [restoring: restorationStartedAt]
        )

        XCTAssertEqual(states[active], .active)
        XCTAssertEqual(states[restoring], .restoring(startedAt: restorationStartedAt))
        XCTAssertEqual(states[loadedHidden], .loadedHidden)
        XCTAssertEqual(states[discarded], .discarded)
        XCTAssertNil(states[closed])
    }

    func testLifecycleDiagnosticsTraceMessageIsStable() {
        let diagnostics = TabLifecycleDiagnostics(
            trackedSpaceCount: 2,
            activeSpaceEngineCount: 1,
            hiddenSpaceEngineCount: 3,
            totalLiveEngineCount: 4,
            restoringTabCount: 1,
            savedInteractionStateCount: 2,
            discardedOpenTabCount: 5,
            hiddenSpacesWithNormalRetainedEngines: 1
        )

        XCTAssertEqual(
            diagnostics.traceMessage,
            "spaces=2 activeEngines=1 hiddenEngines=3 liveEngines=4 restoring=1 interactionStates=2 discardedOpenTabs=5 hiddenSpacesWithNormalEngines=1"
        )
        XCTAssertEqual(diagnostics.bridgeData["trackedSpaceCount"] as? Int, 2)
        XCTAssertEqual(diagnostics.bridgeData["totalLiveEngineCount"] as? Int, 4)
        XCTAssertEqual(diagnostics.bridgeData["discardedOpenTabCount"] as? Int, 5)
    }

    @MainActor
    func testEngineHostReplaceEnginesPrunesAdaptersOutsideVisibleSpace() {
        let removedId = UUID()
        let keptId = UUID()
        let host = EngineHost(engineFactory: WKEngineFactory())
        let windowAdapter = WindowExtensionAdapter(nsWindow: NSWindow())
        let removedEngine = WKWebViewTab(id: removedId, configuration: WKWebViewConfiguration())
        let keptEngine = WKWebViewTab(id: keptId, configuration: WKWebViewConfiguration())
        let removedAdapter = TabExtensionAdapter(engineTab: removedEngine, extensionWindow: windowAdapter)
        let keptAdapter = TabExtensionAdapter(engineTab: keptEngine, extensionWindow: windowAdapter)
        windowAdapter.add(tab: removedAdapter)
        windowAdapter.add(tab: keptAdapter)
        host.setTabAdapter(removedAdapter, for: removedId)
        host.setTabAdapter(keptAdapter, for: keptId)

        let dropped = host.replaceEngines([keptId: keptEngine], validTabIds: [keptId])

        XCTAssertNil(host.tabAdapter(for: removedId))
        XCTAssertNotNil(host.tabAdapter(for: keptId))
        XCTAssertEqual(windowAdapter.extensionTabs.count, 1)
        XCTAssertTrue(windowAdapter.extensionTabs.first as AnyObject === keptAdapter)
        // The pruned adapter must be surfaced so the caller can didCloseTab it. Dropping it silently
        // leaves WebKit holding an "open" extension tab over a torn-down web view.
        XCTAssertEqual(dropped.adapters.count, 1)
        XCTAssertTrue(dropped.adapters.first === removedAdapter)
    }

    @MainActor
    func testEngineHostRestoreTabAdaptersSurfacesDisplacedAdapter() {
        let tabId = UUID()
        let host = EngineHost(engineFactory: WKEngineFactory())
        let windowAdapter = WindowExtensionAdapter(nsWindow: NSWindow())
        let engine = WKWebViewTab(id: tabId, configuration: WKWebViewConfiguration())
        let staleAdapter = TabExtensionAdapter(engineTab: engine, extensionWindow: windowAdapter)
        let freshAdapter = TabExtensionAdapter(engineTab: engine, extensionWindow: windowAdapter)
        windowAdapter.add(tab: staleAdapter)
        host.setTabAdapter(staleAdapter, for: tabId)

        // A wholesale restore that swaps in a different adapter object for the same tab id must not
        // silently strand the previous one, which otherwise stays registered with the controller.
        let displaced = host.restoreTabAdapters([tabId: freshAdapter], validTabIds: [tabId])

        XCTAssertTrue(host.tabAdapter(for: tabId) === freshAdapter)
        XCTAssertEqual(displaced.count, 1)
        XCTAssertTrue(displaced.first === staleAdapter)
        XCTAssertFalse(windowAdapter.extensionTabs.contains { $0 as AnyObject === staleAdapter })
    }

    @MainActor
    func testEngineHostRestoreTabAdaptersSurfacesAdapterOutsideValidIds() {
        let keptId = UUID()
        let strandedId = UUID()
        let host = EngineHost(engineFactory: WKEngineFactory())
        let windowAdapter = WindowExtensionAdapter(nsWindow: NSWindow())
        let keptEngine = WKWebViewTab(id: keptId, configuration: WKWebViewConfiguration())
        let strandedEngine = WKWebViewTab(id: strandedId, configuration: WKWebViewConfiguration())
        let keptAdapter = TabExtensionAdapter(engineTab: keptEngine, extensionWindow: windowAdapter)
        let strandedAdapter = TabExtensionAdapter(engineTab: strandedEngine, extensionWindow: windowAdapter)
        windowAdapter.add(tab: keptAdapter)
        windowAdapter.add(tab: strandedAdapter)
        host.setTabAdapter(strandedAdapter, for: strandedId)

        let displaced = host.restoreTabAdapters(
            [keptId: keptAdapter, strandedId: strandedAdapter],
            validTabIds: [keptId]
        )

        XCTAssertNil(host.tabAdapter(for: strandedId))
        XCTAssertEqual(displaced.count, 1)
        XCTAssertTrue(displaced.first === strandedAdapter)
        XCTAssertFalse(windowAdapter.extensionTabs.contains { $0 as AnyObject === strandedAdapter })
    }

    @MainActor
    func testRestoreTabsAttachesVisibleEnginesToExtensionWindow() {
        let tabId = UUID()
        let manager = TabManager(engineFactory: WKEngineFactory())
        let windowAdapter = WindowExtensionAdapter(nsWindow: NSWindow())
        let engine = WKWebViewTab(id: tabId, configuration: WKWebViewConfiguration())
        let tab = Tab(id: tabId)
        manager.windowAdapter = windowAdapter

        manager.restoreVisibleRuntime([tab], engines: [tabId: engine], activeTabId: tabId, activateRestoredTab: false)

        let adapter = manager.tabAdapter(for: tabId)
        XCTAssertNotNil(adapter)
        XCTAssertTrue(adapter?.engineTab === engine)
        XCTAssertEqual(windowAdapter.extensionTabs.count, 1)
        XCTAssertTrue(windowAdapter.extensionTabs.first as AnyObject === adapter)
    }

    @MainActor
    func testRestoreTabsReusesSnapshotExtensionAdapter() {
        let tabId = UUID()
        let manager = TabManager(engineFactory: WKEngineFactory())
        let windowAdapter = WindowExtensionAdapter(nsWindow: NSWindow())
        let oldEngine = WKWebViewTab(id: tabId, configuration: WKWebViewConfiguration())
        let restoredEngine = WKWebViewTab(id: tabId, configuration: WKWebViewConfiguration())
        let adapter = TabExtensionAdapter(engineTab: oldEngine, extensionWindow: windowAdapter)
        let tab = Tab(id: tabId)
        manager.windowAdapter = windowAdapter

        manager.restoreVisibleRuntime(
            [tab],
            engines: [tabId: restoredEngine],
            tabAdapters: [tabId: adapter],
            activeTabId: tabId,
            activateRestoredTab: false
        )

        XCTAssertTrue(manager.tabAdapter(for: tabId) === adapter)
        XCTAssertTrue(adapter.engineTab === restoredEngine)
        XCTAssertTrue(windowAdapter.extensionTabs.first as AnyObject === adapter)
    }

    /// No extension is granted private data, and WebKit stamps a window's first privacy answer on every
    /// tab, so private tabs are never announced at all.
    @MainActor
    func testPrivateTabsAreNotExposedToExtensions() {
        let tabId = UUID()
        let manager = TabManager(engineFactory: WKEngineFactory())
        let windowAdapter = WindowExtensionAdapter(nsWindow: NSWindow())
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let engine = WKWebViewTab(id: tabId, configuration: configuration)
        defer { engine.teardown() }
        manager.windowAdapter = windowAdapter

        manager.restoreVisibleRuntime([Tab(id: tabId)], engines: [tabId: engine], activeTabId: tabId, activateRestoredTab: false)

        XCTAssertNil(manager.tabAdapter(for: tabId))
        XCTAssertTrue(windowAdapter.extensionTabs.isEmpty)
    }

    @MainActor
    func testSpaceSwitchDetachRemovesCurrentRuntimeWithoutClosingExtensionTab() {
        let manager = TabManager(engineFactory: WKEngineFactory())
        let windowAdapter = WindowExtensionAdapter(nsWindow: NSWindow())
        manager.windowAdapter = windowAdapter
        let tab = manager.prepareTabRuntime()
        manager.attachPreparedTabRuntime(for: tab)
        manager.restoreVisibleRuntime([tab], engines: [tab.id: manager.engineTab(for: tab.id)!], activeTabId: tab.id)

        let adapter = manager.tabAdapter(for: tab.id)
        let snapshot = manager.parkCurrentSpaceRuntimeForSwitch()

        XCTAssertNotNil(snapshot.engines[tab.id])
        XCTAssertTrue(snapshot.tabAdapters[tab.id] === adapter)
        XCTAssertNil(manager.engineTab(for: tab.id))
        XCTAssertNil(manager.tabAdapter(for: tab.id))
        XCTAssertTrue(windowAdapter.extensionTabs.contains { $0 as AnyObject === adapter })
    }
}
