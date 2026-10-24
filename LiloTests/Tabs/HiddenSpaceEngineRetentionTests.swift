import XCTest
import WebKit
@testable import Lilo

@MainActor
final class HiddenSpaceEngineRetentionTests: XCTestCase {
    func testMainWindowCustomChromeExposesFullBoundsToWebKit() {
        let windowController = MainWindowController()
        guard let window = windowController.window,
              let contentView = window.contentView else {
            XCTFail("Expected main window with content view")
            return
        }

        window.layoutIfNeeded()

        XCTAssertEqual(window.contentLayoutRect, contentView.bounds)
        XCTAssertEqual(contentView.safeAreaInsets.top, 0)
        XCTAssertEqual(contentView.safeAreaInsets.left, 0)
        XCTAssertEqual(contentView.safeAreaInsets.bottom, 0)
        XCTAssertEqual(contentView.safeAreaInsets.right, 0)
        XCTAssertEqual(contentView.safeAreaRect, contentView.bounds)
    }

    private func makeLifecycleController() -> HiddenSpaceLifecycleController {
        HiddenSpaceLifecycleController(
            store: BrowserStateStore(),
            config: .config(for: .balanced),
            discardEngine: { _ in nil },
            syncActiveState: {}
        )
    }

    func testHiddenSpaceTrimSchedulingCoalescesToLatestRequest() {
        let controller = makeLifecycleController()
        let firstSpace = UUID()
        let secondSpace = UUID()

        controller.scheduleTrim(excluding: firstSpace)
        controller.scheduleTrim(excluding: secondSpace)

        XCTAssertTrue(controller.hasPendingTrim)
        XCTAssertEqual(controller.pendingTrimProtectedSpaceId, secondSpace)
    }

    func testRapidMultiSpaceTrimSchedulingKeepsLatestProtectedSpace() {
        let controller = makeLifecycleController()
        let firstSpace = UUID()
        let secondSpace = UUID()
        let thirdSpace = UUID()

        controller.scheduleTrim(excluding: firstSpace)
        controller.scheduleTrim(excluding: secondSpace)
        controller.scheduleTrim(excluding: thirdSpace)
        controller.scheduleTrim(excluding: firstSpace)

        XCTAssertEqual(controller.pendingTrimProtectedSpaceId, firstSpace)
    }

    func testBackgroundTrimIsDelayedAndCancelledWhenAppBecomesActive() {
        let controller = makeLifecycleController()

        controller.handleWillResignActive()

        XCTAssertFalse(controller.isForeground)
        XCTAssertTrue(controller.hasPendingTrim)

        controller.handleDidBecomeActive()

        XCTAssertTrue(controller.isForeground)
        XCTAssertFalse(controller.hasPendingTrim)
    }

    func testMemoryPressureSchedulesAggressiveTrimWithoutStickyPolicy() {
        let controller = makeLifecycleController()
        controller.handleDidBecomeActive()

        controller.handleMemoryPressure()

        XCTAssertTrue(controller.hasPendingTrim)
        XCTAssertEqual(controller.currentPolicy, .foreground)
    }

    func testMemoryPressureSourceIsInstalled() {
        let controller = makeLifecycleController()
        controller.setupObservers()

        XCTAssertTrue(controller.isMonitoringMemoryPressure)
        controller.teardown()
    }

    private struct RecordedTrim: Equatable {
        let policy: TabLifecycleCoordinator.Policy
        let cap: Int?
    }

    func testWarningMemoryPressureCapsEveryTrimUntilNormal() {
        let config = LifecyclePolicyConfig.config(for: .balanced)
        let cap = config.constrainedForegroundEngineBudget
        var recorded: [RecordedTrim] = []
        var trimFired: XCTestExpectation?
        let controller = HiddenSpaceLifecycleController(
            store: BrowserStateStore(),
            config: config,
            discardEngine: { _ in nil },
            syncActiveState: {},
            trimActiveSpaceEngines: { policy, cap in recorded.append(RecordedTrim(policy: policy, cap: cap)); trimFired?.fulfill() }
        )
        controller.handleDidBecomeActive()

        trimFired = expectation(description: "pressure trim")
        controller.handleMemoryPressure(.warning)
        wait(for: [trimFired!], timeout: 1.0)
        trimFired = expectation(description: "post-activation trim")
        controller.scheduleActiveSpaceTrim(delay: 0)
        wait(for: [trimFired!], timeout: 1.0)
        trimFired = nil
        controller.runIdleSweep()
        XCTAssertEqual(recorded, Array(repeating: RecordedTrim(policy: .foreground, cap: cap), count: 3))

        recorded.removeAll()
        controller.handleMemoryPressure(.normal)
        XCTAssertFalse(controller.hasPendingTrim, "a return to normal reclaims nothing")
        trimFired = expectation(description: "relaxed trim")
        controller.scheduleActiveSpaceTrim(delay: 0)
        wait(for: [trimFired!], timeout: 1.0)
        XCTAssertEqual(recorded, [RecordedTrim(policy: .foreground, cap: nil)])
    }

    func testCriticalMemoryPressureCollapsesEveryTrim() {
        var recorded: [RecordedTrim] = []
        var trimFired: XCTestExpectation?
        let controller = HiddenSpaceLifecycleController(
            store: BrowserStateStore(),
            config: .config(for: .balanced),
            discardEngine: { _ in nil },
            syncActiveState: {},
            trimActiveSpaceEngines: { policy, cap in recorded.append(RecordedTrim(policy: policy, cap: cap)); trimFired?.fulfill() }
        )
        controller.handleDidBecomeActive()

        trimFired = expectation(description: "pressure trim")
        controller.handleMemoryPressure(.critical)
        wait(for: [trimFired!], timeout: 1.0)
        trimFired = expectation(description: "post-activation trim")
        controller.scheduleActiveSpaceTrim(delay: 0)
        wait(for: [trimFired!], timeout: 1.0)

        // activeSpaceTrimBudget maps .background to a single engine.
        XCTAssertEqual(recorded, Array(repeating: RecordedTrim(policy: .background, cap: nil), count: 2))
    }

    // MARK: - Occlusion lifecycle

    func testOcclusionHiddenTightensPolicy() {
        let controller = makeLifecycleController()
        // Start foregrounded and visible.
        controller.handleDidBecomeActive()

        controller.windowOcclusionChanged(isVisible: false)

        // Policy must tighten to background and a trim must be scheduled.
        XCTAssertEqual(controller.currentPolicy, .background)
        XCTAssertTrue(controller.hasPendingTrim)
    }

    func testOcclusionVisibleRelaxesPolicyWhenAppIsActive() {
        let controller = makeLifecycleController()
        controller.handleDidBecomeActive()
        controller.windowOcclusionChanged(isVisible: false)

        controller.windowOcclusionChanged(isVisible: true)

        XCTAssertEqual(controller.currentPolicy, .foreground)
        XCTAssertFalse(controller.hasPendingTrim)
    }

    func testOcclusionVisibleWhileAppInactiveRelaxesPolicy() {
        let controller = makeLifecycleController()
        // App resigns active first (window still visible at that point).
        controller.handleWillResignActive()
        // Window also becomes occluded.
        controller.windowOcclusionChanged(isVisible: false)

        // Window becomes visible again, but app is still inactive.
        controller.windowOcclusionChanged(isVisible: true)

        // The user can see the window again, so its engines are kept and the queued collapse goes.
        XCTAssertEqual(controller.currentPolicy, .foreground)
        XCTAssertFalse(controller.hasPendingTrim)
    }

    func testResignActiveWithVisibleWindowKeepsForegroundPolicy() {
        let controller = makeLifecycleController()
        controller.handleDidBecomeActive()

        controller.handleWillResignActive()

        // The window is still on screen: the scheduled trim must resolve to the adaptive budget,
        // not collapse the space to one engine and turn every tab into a cold reload.
        XCTAssertEqual(controller.currentPolicy, .foreground)
        XCTAssertTrue(controller.hasPendingTrim)
    }

    func testRepeatedOcclusionHiddenCallsAreIdempotent() {
        let controller = makeLifecycleController()
        controller.handleDidBecomeActive()
        controller.windowOcclusionChanged(isVisible: false)

        // A second hidden notification (macOS fires them liberally) must leave the same outcome.
        controller.windowOcclusionChanged(isVisible: false)

        XCTAssertEqual(controller.currentPolicy, .background)
        XCTAssertTrue(controller.hasPendingTrim)
    }

    func testAppActiveWhileOccludedDoesNotRelaxPolicy() {
        let controller = makeLifecycleController()
        // Window is occluded while app is active.
        controller.windowOcclusionChanged(isVisible: false)
        // App then resigns active.
        controller.handleWillResignActive()

        // App becomes active again, but window is still occluded.
        controller.handleDidBecomeActive()

        XCTAssertEqual(controller.currentPolicy, .background)
        // The occluded window must also keep the pending trim alive: re-activation may not
        // cancel it (the guard in handleDidBecomeActive, not just the derived policy).
        XCTAssertTrue(controller.hasPendingTrim)
    }

    // MARK: - Active-space trim must not fire in .background after a brief switch-away
    // The trim reads currentPolicy at fire time: firing as .background within the 2s debounce would collapse the visible
    // space to one engine long before the graceful background trim, so tightening transitions must cancel it.

    func testAppResignCancelsPendingActiveSpaceTrim() {
        let controller = makeLifecycleController()
        controller.handleDidBecomeActive()               // foreground + visible
        controller.scheduleActiveSpaceTrim(delay: 60)    // long delay: never fires during the test
        XCTAssertTrue(controller.hasPendingActiveSpaceTrim)

        controller.handleWillResignActive()

        XCTAssertFalse(controller.hasPendingActiveSpaceTrim)
    }

    func testOcclusionCancelsPendingActiveSpaceTrim() {
        let controller = makeLifecycleController()
        controller.handleDidBecomeActive()
        controller.scheduleActiveSpaceTrim(delay: 60)
        XCTAssertTrue(controller.hasPendingActiveSpaceTrim)

        controller.windowOcclusionChanged(isVisible: false)

        XCTAssertFalse(controller.hasPendingActiveSpaceTrim)
    }

    // MARK: - Initial window-visibility sync

    func testSyncWindowVisibilityAdoptsStateWithoutSchedulingTrims() {
        let controller = makeLifecycleController()
        controller.handleDidBecomeActive()           // foreground; isWindowVisible boots as true

        controller.syncWindowVisibility(false)

        // The stale default is corrected, but a pure state sync must not trim anything:
        // transitions (occlusion/app-active changes) own the trim scheduling.
        XCTAssertEqual(controller.currentPolicy, .background)
        XCTAssertFalse(controller.hasPendingTrim)
        XCTAssertFalse(controller.hasPendingActiveSpaceTrim)
    }

    // MARK: - Active-space trim budget (caller-side mapping)

    func testActiveSpaceTrimBudgetCollapsesToOneForBackground() {
        let windowController = MainWindowController()
        XCTAssertEqual(windowController.activeSpaceTrimBudget(policy: .background, cap: nil), 1)
        XCTAssertEqual(windowController.activeSpaceTrimBudget(policy: .background, cap: 6), 1)
    }

    func testActiveSpaceTrimBudgetRespectsCapInForeground() {
        let windowController = MainWindowController()
        XCTAssertEqual(windowController.activeSpaceTrimBudget(policy: .foreground, cap: 2), 2)
        XCTAssertEqual(
            windowController.activeSpaceTrimBudget(policy: .foreground, cap: nil),
            windowController.adaptiveForegroundEngineBudget
        )
    }

    // MARK: - Idle sweep suspension while backgrounded/occluded

    func testIdleSweepSuspendsWhileOccludedAndResumesWhenVisible() {
        let controller = makeLifecycleController()
        controller.setupObservers()
        defer { controller.teardown() }
        controller.handleDidBecomeActive()
        XCTAssertFalse(controller.isIdleSweepSuspended)

        controller.windowOcclusionChanged(isVisible: false)
        XCTAssertTrue(controller.isIdleSweepSuspended)

        controller.windowOcclusionChanged(isVisible: true)
        XCTAssertFalse(controller.isIdleSweepSuspended)
    }

    func testIdleSweepStaysSuspendedWhenActiveButOccluded() {
        let controller = makeLifecycleController()
        controller.setupObservers()
        defer { controller.teardown() }
        controller.handleDidBecomeActive()

        controller.handleWillResignActive()
        // Window still on screen: the sweep keeps running, and it is what bounds memory here.
        XCTAssertFalse(controller.isIdleSweepSuspended)

        controller.windowOcclusionChanged(isVisible: false)
        controller.handleDidBecomeActive()
        // Still occluded: the policy stays tightened, so the sweep must not resume.
        XCTAssertTrue(controller.isIdleSweepSuspended)

        controller.windowOcclusionChanged(isVisible: true)
        XCTAssertFalse(controller.isIdleSweepSuspended)
    }

    func testTeardownWhileIdleSweepSuspendedIsSafe() {
        let controller = makeLifecycleController()
        controller.setupObservers()
        controller.handleDidBecomeActive()
        controller.windowOcclusionChanged(isVisible: false)
        XCTAssertTrue(controller.isIdleSweepSuspended)

        // Cancelling a suspended source requires a balancing resume first; this must not crash.
        controller.teardown()
        XCTAssertFalse(controller.isIdleSweepSuspended)
    }

    func testApplyConfigWhileOccludedRestartsSweepSuspended() {
        let controller = makeLifecycleController()
        controller.setupObservers()
        defer { controller.teardown() }
        controller.handleDidBecomeActive()
        controller.windowOcclusionChanged(isVisible: false)

        controller.applyConfig(.config(for: .conservative))

        XCTAssertTrue(controller.isIdleSweepSuspended, "a sweep source rebuilt while occluded must start suspended")
    }

    // MARK: - Warm-pool drop on backgrounding

    func testResignActiveFiresOnBackgrounded() {
        let controller = makeLifecycleController()
        var fired = 0
        controller.onBackgrounded = { fired += 1 }
        controller.handleDidBecomeActive()

        controller.handleWillResignActive()

        XCTAssertEqual(fired, 1)
    }

    func testOcclusionHiddenFiresOnBackgroundedAndVisibleDoesNot() {
        let controller = makeLifecycleController()
        var fired = 0
        controller.onBackgrounded = { fired += 1 }
        controller.handleDidBecomeActive()

        controller.windowOcclusionChanged(isVisible: false)
        controller.windowOcclusionChanged(isVisible: true)

        XCTAssertEqual(fired, 1)
    }

    func testForegroundReturnFiresOnForegroundedOnlyWhenVisible() {
        let controller = makeLifecycleController()
        var fired = 0
        controller.onForegrounded = { fired += 1 }

        controller.handleDidBecomeActive()
        XCTAssertEqual(fired, 1)

        // Occluded reactivation must not fire: the window is not visible.
        controller.windowOcclusionChanged(isVisible: false)
        controller.handleWillResignActive()
        controller.handleDidBecomeActive()
        XCTAssertEqual(fired, 1)

        // Becoming visible again while active fires.
        controller.windowOcclusionChanged(isVisible: true)
        XCTAssertEqual(fired, 2)
    }

    // MARK: - Constrained power must not collapse the *visible* space to one engine

    private func shortGraceConservativeConfig() -> LifecyclePolicyConfig {
        var config = LifecyclePolicyConfig.config(for: .conservative)
        config.constrainedPowerGracePeriod = 0.05
        return config
    }

    func testIdleSweepKeepsForegroundPolicyForVisibleSpaceUnderConstrainedPower() {
        var recorded: [TabLifecycleCoordinator.Policy] = []
        let controller = HiddenSpaceLifecycleController(
            store: BrowserStateStore(),
            config: shortGraceConservativeConfig(),
            discardEngine: { _ in nil },
            syncActiveState: {},
            trimActiveSpaceEngines: { policy, _ in recorded.append(policy) },
            isPowerConstrained: { true }
        )
        controller.handleDidBecomeActive()          // foreground + visible
        let entered = expectation(description: "constrained state adopted")
        controller.onConstrainedPowerChange = { if $0 { entered.fulfill() } }
        controller.reevaluateConstrainedPower()
        wait(for: [entered], timeout: 1.0)
        recorded.removeAll()

        controller.runIdleSweep()

        // The visible active space stays foreground (capped by constrainedForegroundEngineBudget),
        // NOT collapsed to .background (which hard-codes budget = 1).
        XCTAssertEqual(recorded, [.foreground])
    }

    private func installActiveSpace(in store: BrowserStateStore, spaceId: UUID, engineCount: Int) {
        let tabs = (0..<engineCount).map { i in
            Tab(url: URL(string: "https://x\(i).example"), title: "X\(i)", spaceId: spaceId)
        }
        store.storeActiveSpace(
            id: spaceId,
            snapshot: BrowserStateStore.SpaceSnapshot(
                spaceTab: SpaceTab(
                    spaceId: spaceId,
                    state: SpaceTabStateImporter.importState(
                        activeTabId: tabs[0].id, activationHistory: [], tabs: tabs, folders: [], treeItems: [], spaceId: spaceId
                    )
                ),
                engines: Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, WKWebViewTab(configuration: WKWebViewConfiguration())) })
            )
        )
    }

    func testIdleSweepSamplesFootprintExactlyOnce() {
        let store = BrowserStateStore()
        installActiveSpace(in: store, spaceId: UUID(), engineCount: 1)
        var sampleCount = 0
        let controller = HiddenSpaceLifecycleController(
            store: store,
            config: .config(for: .balanced),
            discardEngine: { _ in nil },
            syncActiveState: {},
            footprintSampler: { _ in sampleCount += 1; return [:] }
        )
        controller.handleDidBecomeActive()   // foreground + visible

        controller.runIdleSweep()

        XCTAssertEqual(sampleCount, 1, "the footprint sampler runs once per sweep, off the hot path")
    }

    // MARK: - Footprint-ceiling hysteresis: a quiet steady state stops paying the sampling syscalls

    func testIdleSweepSkipsFootprintSamplingWhenQuiet() {
        let store = BrowserStateStore()
        installActiveSpace(in: store, spaceId: UUID(), engineCount: 1)
        var sampleCount = 0
        let controller = HiddenSpaceLifecycleController(
            store: store,
            config: .config(for: .balanced),
            discardEngine: { _ in nil },
            syncActiveState: {},
            footprintSampler: { _ in sampleCount += 1; return [:] }
        )
        controller.handleDidBecomeActive()

        controller.runIdleSweep()
        controller.runIdleSweep()

        XCTAssertEqual(sampleCount, 1, "an unchanged engine count with a total well under the ceiling skips re-sampling")
    }

    func testIdleSweepResamplesFootprintWhenEngineCountChanges() {
        let store = BrowserStateStore()
        let spaceId = UUID()
        installActiveSpace(in: store, spaceId: spaceId, engineCount: 1)
        var sampleCount = 0
        let controller = HiddenSpaceLifecycleController(
            store: store,
            config: .config(for: .balanced),
            discardEngine: { _ in nil },
            syncActiveState: {},
            footprintSampler: { _ in sampleCount += 1; return [:] }
        )
        controller.handleDidBecomeActive()
        controller.runIdleSweep()

        installActiveSpace(in: store, spaceId: spaceId, engineCount: 2)
        controller.runIdleSweep()

        XCTAssertEqual(sampleCount, 2, "a live-engine count change must re-sample the footprint")
    }

    func testIdleSweepResamplesFootprintWhileNearCeiling() {
        let store = BrowserStateStore()
        installActiveSpace(in: store, spaceId: UUID(), engineCount: 1)
        var sampleCount = 0
        let controller = HiddenSpaceLifecycleController(
            store: store,
            config: .config(for: .balanced),
            discardEngine: { _ in nil },
            syncActiveState: {},
            // 4 TB per engine: above any real ceiling, so the last total always exceeds the
            // 70% hysteresis threshold. The lone engine is the visible active tab (protected),
            // so the trim itself discards nothing and the count stays stable.
            footprintSampler: { engines in sampleCount += 1; return engines.mapValues { _ in UInt64(1) << 42 } }
        )
        controller.handleDidBecomeActive()

        controller.runIdleSweep()
        controller.runIdleSweep()

        XCTAssertEqual(sampleCount, 2, "a total at or above the ceiling threshold must keep re-sampling")
    }

    func testIdleSweepTrimsVisibleSpaceWhenHiddenSpacesCannotCoverFootprintExcess() {
        let store = BrowserStateStore()
        installActiveSpace(in: store, spaceId: UUID(), engineCount: 3)
        let config = LifecyclePolicyConfig.config(for: .balanced)
        var recorded: [RecordedTrim] = []
        let controller = HiddenSpaceLifecycleController(
            store: store,
            config: config,
            discardEngine: { _ in nil },
            syncActiveState: {},
            trimActiveSpaceEngines: { policy, cap in recorded.append(RecordedTrim(policy: policy, cap: cap)) },
            // 4 TB per engine and no hidden space: the whole excess sits in the visible space.
            footprintSampler: { engines in engines.mapValues { _ in UInt64(1) << 42 } }
        )
        controller.handleDidBecomeActive()

        controller.runIdleSweep()

        XCTAssertEqual(recorded, [
            RecordedTrim(policy: .foreground, cap: nil),
            RecordedTrim(policy: .foreground, cap: config.constrainedForegroundEngineBudget)
        ])
    }

    func testConstrainedPowerTransitionCapsVisibleSpaceInsteadOfCollapsing() {
        let trimFired = expectation(description: "active-space trim fired")
        var recorded: [(policy: TabLifecycleCoordinator.Policy, cap: Int?)] = []
        let controller = HiddenSpaceLifecycleController(
            store: BrowserStateStore(),
            config: shortGraceConservativeConfig(),
            discardEngine: { _ in nil },
            syncActiveState: {},
            trimActiveSpaceEngines: { policy, cap in
                recorded.append((policy, cap)); trimFired.fulfill()
            },
            isPowerConstrained: { true }
        )
        controller.handleDidBecomeActive()          // foreground + visible

        controller.reevaluateConstrainedPower()      // schedules the entry-into-constrained trim

        wait(for: [trimFired], timeout: 1.0)
        XCTAssertEqual(recorded.first?.policy, .foreground)
        XCTAssertEqual(recorded.first?.cap, 6)       // constrainedForegroundEngineBudget for .conservative
    }

    func testConstrainedPowerEntryDebouncedAgainstThermalFlapping() {
        var powerConstrained = true
        var changes: [Bool] = []
        let noTrim = expectation(description: "no trim during a thermal flap")
        noTrim.isInverted = true
        var config = LifecyclePolicyConfig.config(for: .conservative)
        config.constrainedPowerGracePeriod = 0.1
        let controller = HiddenSpaceLifecycleController(
            store: BrowserStateStore(),
            config: config,
            discardEngine: { _ in nil },
            syncActiveState: {},
            trimActiveSpaceEngines: { _, _ in noTrim.fulfill() },
            isPowerConstrained: { powerConstrained }
        )
        controller.onConstrainedPowerChange = { changes.append($0) }
        controller.handleDidBecomeActive()

        controller.reevaluateConstrainedPower()      // thermal flips to .serious...
        powerConstrained = false
        controller.reevaluateConstrainedPower()      // ...and back to .fair before the grace elapses

        wait(for: [noTrim], timeout: 0.4)
        XCTAssertFalse(controller.isConstrainedPower)
        XCTAssertTrue(changes.isEmpty)               // the blip never surfaced (no warm-pool/UI churn)
    }

    func testConstrainedPowerExitAppliesImmediately() {
        var powerConstrained = true
        let controller = HiddenSpaceLifecycleController(
            store: BrowserStateStore(),
            config: shortGraceConservativeConfig(),
            discardEngine: { _ in nil },
            syncActiveState: {},
            isPowerConstrained: { powerConstrained }
        )
        controller.handleDidBecomeActive()
        let entered = expectation(description: "constrained state adopted")
        controller.onConstrainedPowerChange = { if $0 { entered.fulfill() } }
        controller.reevaluateConstrainedPower()
        wait(for: [entered], timeout: 1.0)

        powerConstrained = false
        controller.reevaluateConstrainedPower()

        XCTAssertFalse(controller.isConstrainedPower)   // relaxing is safe: no grace on the way out
    }

    // MARK: - trimActiveSpaceEngines stashes evicted-engine interaction state
    // A fresh `WKWebViewTab` already carries a non-nil `interactionState` (WebKit's empty session history), so real engines
    // need no page load or sleep.

    func testTrimActiveSpaceEnginesStashesEvictedEngineInteractionState() throws {
        let engineFactory = WKEngineFactory()
        let tabManager = TabManager(engineFactory: engineFactory)
        let spaceId = UUID()
        tabManager.currentSpaceId = spaceId

        let activeTab = Tab(url: URL(string: "https://active.example"), spaceId: spaceId)
        let evictedTab = Tab(url: URL(string: "https://evicted.example"), spaceId: spaceId)
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: activeTab.id,
            tabs: [activeTab, evictedTab],
            folders: [],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: activeTab.id, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: evictedTab.id, parentFolderId: nil, section: .unpinned, sortOrder: 1)
            ]
        )
        tabManager.installSpaceTabStateForTests(SpaceTabState(state), spaceId: spaceId)
        tabManager.activeTabId = activeTab.id

        for tab in [activeTab, evictedTab] {
            _ = tabManager.engineHost.createEngine(dataStore: engineFactory.defaultDataStore(), profileId: nil, tabId: tab.id)
        }
        defer {
            tabManager.engineHost.engine(for: activeTab.id)?.teardown()
            tabManager.engineHost.engine(for: evictedTab.id)?.teardown()
        }

        let evictedEngine = try XCTUnwrap(tabManager.engineHost.engine(for: evictedTab.id))
        let preTrimInteractionState = try XCTUnwrap(evictedEngine.interactionState as? Data)

        // Budget of 1 live engine: the active tab is always protected, so the non-active tab is evicted.
        tabManager.trimActiveSpaceEngines(maxLiveEngines: 1)

        XCTAssertNil(tabManager.engineHost.engine(for: evictedTab.id), "the evicted tab's live engine must be removed")
        XCTAssertNotNil(tabManager.engineHost.engine(for: activeTab.id), "the active tab's engine must survive the trim")

        let stashed = tabManager.engineHost.recentSavedInteractionStates(limit: 10)
        let stashedState = try XCTUnwrap(
            stashed.first(where: { $0.id == evictedTab.id })?.state as? Data,
            "evicted engine's interaction state must be stashed during the trim"
        )
        XCTAssertEqual(stashedState, preTrimInteractionState, "the stashed state must match the live engine's state")

        // Statement order inside the eviction loop is deliberately not covered: `EngineHost.teardown`
        // defers `engine.teardown()` with `DispatchQueue.main.async`, so `interactionState` stays
        // readable for the rest of the tick either way. Only a missing stash fails the XCTUnwrap above.
    }

    // MARK: - Collapsing a folder releases its tabs' engines
    // The active tab keeps its engine even inside the folder, and tabs outside the folder are untouched.

    func testActivatingATabInALockedFolderCreatesNoEngine() throws {
        let engineFactory = WKEngineFactory()
        let tabManager = TabManager(engineFactory: engineFactory)
        let spaceId = UUID()
        tabManager.currentSpaceId = spaceId
        var folder = TabFolder(spaceId: spaceId, name: "Finances")
        folder.lock = FolderLock(allowsBiometrics: false)
        var lockedTab = Tab(url: URL(string: "https://bank.example"), spaceId: spaceId)
        lockedTab.groupId = folder.id
        let state = try BrowserStateFixture(
            spaceId: spaceId, activeTabId: nil, tabs: [lockedTab], folders: [folder],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folder.id, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: lockedTab.id, parentFolderId: folder.id, section: .unpinned, sortOrder: 0)
            ]
        )
        tabManager.installSpaceTabStateForTests(SpaceTabState(state), spaceId: spaceId)

        tabManager.activateTabRuntime(id: lockedTab.id)

        XCTAssertEqual(tabManager.activeTabId, lockedTab.id, "the selection moves; only the page stays away")
        XCTAssertNil(tabManager.engineHost.engine(for: lockedTab.id))
        XCTAssertNil(tabManager.ensureLiveEngine(forTabId: lockedTab.id), "tab share cannot wake a locked tab either")
    }

    func testCollapsingFolderDiscardsItsTabsEnginesExceptTheActiveOne() throws {
        let engineFactory = WKEngineFactory()
        let tabManager = TabManager(engineFactory: engineFactory)
        let spaceId = UUID()
        tabManager.currentSpaceId = spaceId

        let folder = TabFolder(spaceId: spaceId, name: "Work")
        let outsideTab = Tab(url: URL(string: "https://outside.example"), spaceId: spaceId)
        var activeTab = Tab(url: URL(string: "https://active.example"), spaceId: spaceId)
        activeTab.groupId = folder.id
        var idleTab = Tab(url: URL(string: "https://idle.example"), spaceId: spaceId)
        idleTab.groupId = folder.id
        let state = try BrowserStateFixture(
            spaceId: spaceId,
            activeTabId: activeTab.id,
            tabs: [outsideTab, activeTab, idleTab],
            folders: [folder],
            treeItems: [
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: outsideTab.id, parentFolderId: nil, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .folder, itemId: folder.id, parentFolderId: nil, section: .unpinned, sortOrder: 1),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: activeTab.id, parentFolderId: folder.id, section: .unpinned, sortOrder: 0),
                TabTreeItem(spaceId: spaceId, kind: .tab, itemId: idleTab.id, parentFolderId: folder.id, section: .unpinned, sortOrder: 1)
            ]
        )
        tabManager.installSpaceTabStateForTests(SpaceTabState(state), spaceId: spaceId)
        tabManager.activeTabId = activeTab.id

        for tab in [outsideTab, activeTab, idleTab] {
            _ = tabManager.engineHost.createEngine(dataStore: engineFactory.defaultDataStore(), profileId: nil, tabId: tab.id)
        }
        defer {
            for tab in [outsideTab, activeTab, idleTab] {
                tabManager.engineHost.engine(for: tab.id)?.teardown()
            }
        }

        XCTAssertTrue(tabManager.discardEngines(inFolder: folder.id, spaceId: spaceId))

        XCTAssertNil(tabManager.engineHost.engine(for: idleTab.id), "an idle tab inside the collapsed folder must lose its engine")
        XCTAssertNotNil(tabManager.engineHost.engine(for: activeTab.id), "the active tab keeps its engine even inside the collapsed folder")
        XCTAssertNotNil(tabManager.engineHost.engine(for: outsideTab.id), "a tab outside the folder must be untouched")

        let stashed = tabManager.engineHost.recentSavedInteractionStates(limit: 10)
        XCTAssertNotNil(
            stashed.first(where: { $0.id == idleTab.id })?.state,
            "the discarded engine's interaction state must be stashed for a silent restore"
        )
    }
}
