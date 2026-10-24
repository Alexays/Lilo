import XCTest
@testable import Lilo

final class TabLifecycleIdleTests: XCTestCase {
    private func tab(_ id: UUID) -> Tab { Tab(id: id) }

    func testIdleEngineDroppedFromActiveKeepSet() {
        let active = UUID(); let fresh = UUID(); let stale = UUID()
        let now = Date()
        let coordinator = TabLifecycleCoordinator(policy: .foreground)
        let keep = coordinator.activeSpaceEnginesToKeep(
            tabs: [active, fresh, stale].map(tab),
            availableEngineIds: [active, fresh, stale],
            activeTabId: active,
            activationHistory: [active, fresh, stale],
            maxLiveEngines: 10,
            lastActiveAt: [
                fresh: now.addingTimeInterval(-10),
                stale: now.addingTimeInterval(-3600)
            ],
            discardThreshold: 1800,
            now: now
        )
        XCTAssertEqual(keep, [active, fresh])   // stale (1h idle > 30m) dropped despite free budget
    }

    func testActiveTabNeverIdleDropped() {
        let active = UUID()
        let now = Date()
        let coordinator = TabLifecycleCoordinator(policy: .foreground)
        let keep = coordinator.activeSpaceEnginesToKeep(
            tabs: [active].map(tab),
            availableEngineIds: [active],
            activeTabId: active,
            activationHistory: [active],
            maxLiveEngines: 10,
            lastActiveAt: [active: now.addingTimeInterval(-99999)],
            discardThreshold: 1800,
            now: now
        )
        XCTAssertEqual(keep, [active])
    }

    func testInfiniteThresholdNeverIdleDrops() {
        let active = UUID(); let stale = UUID()
        let now = Date()
        let coordinator = TabLifecycleCoordinator(policy: .foreground)
        let keep = coordinator.activeSpaceEnginesToKeep(
            tabs: [active, stale].map(tab),
            availableEngineIds: [active, stale],
            activeTabId: active,
            activationHistory: [active, stale],
            maxLiveEngines: 10,
            lastActiveAt: [stale: now.addingTimeInterval(-99999)],
            discardThreshold: .infinity,
            now: now
        )
        XCTAssertEqual(keep, [active, stale])
    }

    func testBackgroundOpenedTabKeptWithinBudget() {
        let active = UUID(); let visited = UUID(); let opened = UUID()
        let coordinator = TabLifecycleCoordinator(policy: .foreground)
        let tabs = [active, visited, opened].map(tab)

        let keep = coordinator.activeSpaceEnginesToKeep(
            tabs: tabs,
            availableEngineIds: [active, visited, opened],
            activeTabId: active,
            activationHistory: [active, visited],
            maxLiveEngines: 10
        )
        XCTAssertEqual(keep, [active, visited, opened])

        let tight = coordinator.activeSpaceEnginesToKeep(
            tabs: tabs,
            availableEngineIds: [active, visited, opened],
            activeTabId: active,
            activationHistory: [active, visited],
            maxLiveEngines: 2
        )
        XCTAssertEqual(tight, [active, visited], "recently visited tabs come first")
    }

    func testFrozenEngineReportedAsFrozen() {
        let active = UUID(); let frozen = UUID(); let hidden = UUID()
        let coordinator = TabLifecycleCoordinator(policy: .foreground)
        let states = coordinator.lifecycleStates(
            tabs: [active, frozen, hidden].map(tab),
            availableEngineIds: [active, frozen, hidden],
            activeTabId: active,
            frozenTabIds: [frozen]
        )
        XCTAssertEqual(states[active], .active)
        XCTAssertEqual(states[frozen], .frozen)
        XCTAssertEqual(states[hidden], .loadedHidden)
    }

    func testPinnedTabExemptFromIdleDiscardButNotFreeze() {
        let active = UUID(); let pinned = UUID()
        let now = Date()
        var pinnedTab = Tab(id: pinned)
        pinnedTab.isPinned = true
        let coordinator = TabLifecycleCoordinator(policy: .foreground)

        let keep = coordinator.activeSpaceEnginesToKeep(
            tabs: [Tab(id: active), pinnedTab],
            availableEngineIds: [active, pinned],
            activeTabId: active,
            activationHistory: [active, pinned],
            maxLiveEngines: 10,
            lastActiveAt: [pinned: now.addingTimeInterval(-99999)],
            discardThreshold: 1800,
            now: now
        )
        XCTAssertTrue(keep.contains(pinned))   // pinned survives idle discard

        // pinned is NOT in the always-protected (freeze-protected) set, so freezing it is allowed:
        let frozenProtected = coordinator.protectedEngineIds(
            tabs: [Tab(id: active), pinnedTab],
            availableEngineIds: [active, pinned],
            now: now
        )
        XCTAssertFalse(frozenProtected.contains(pinned))
    }

    func testFormDirtyTabExemptFromIdleDiscard() {
        let active = UUID(); let dirty = UUID()
        let now = Date()
        var dirtyTab = Tab(id: dirty)
        dirtyTab.hasUnsavedFormData = true
        let coordinator = TabLifecycleCoordinator(policy: .foreground)

        let keep = coordinator.activeSpaceEnginesToKeep(
            tabs: [Tab(id: active), dirtyTab],
            availableEngineIds: [active, dirty],
            activeTabId: active,
            activationHistory: [active, dirty],
            maxLiveEngines: 10,
            lastActiveAt: [dirty: now.addingTimeInterval(-99999)],
            discardThreshold: 1800,
            now: now
        )
        XCTAssertTrue(keep.contains(dirty))
    }
}
