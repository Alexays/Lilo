import XCTest
import GRDB
@testable import Lilo

final class LifecyclePolicyTests: XCTestCase {
    func testBalancedConstants() {
        let c = LifecyclePolicyConfig.config(for: .balanced)
        XCTAssertEqual(c.maxNormalRetainedEnginesPerHiddenSpace, 1)
        XCTAssertEqual(c.maxHiddenSpacesWithNormalRetainedEngines, 2)
        XCTAssertEqual(c.audioGracePeriod, 30)
        XCTAssertEqual(c.restorationGracePeriod, 10)
        XCTAssertEqual(c.backgroundTrimGracePeriod, 120)
        XCTAssertEqual(c.constrainedForegroundEngineBudget, 6)
        XCTAssertEqual(c.foregroundEngineBudgetMultiplier, 1.0)
    }

    func testBalancedFreezeFiveMinutesDiscardThirtyMinutes() {
        let c = LifecyclePolicyConfig.config(for: .balanced)
        XCTAssertEqual(c.freezeThreshold, 300)
        XCTAssertEqual(c.discardThreshold, 1800)
    }

    func testAggressiveIsTighter() {
        let c = LifecyclePolicyConfig.config(for: .aggressive)
        XCTAssertEqual(c.freezeThreshold, 120)
        XCTAssertEqual(c.discardThreshold, 600)
        XCTAssertEqual(c.foregroundEngineBudgetMultiplier, 0.5)
    }

    func testConservativeNeverIdleDiscards() {
        let c = LifecyclePolicyConfig.config(for: .conservative)
        XCTAssertEqual(c.freezeThreshold, 900)
        XCTAssertEqual(c.discardThreshold, .infinity)
        XCTAssertEqual(c.foregroundEngineBudgetMultiplier, 1.0)
    }

    func testBatteryPowerCapsIdleDiscard() {
        XCTAssertEqual(LifecyclePolicyConfig.config(for: .balanced, onBatteryPower: true).discardThreshold, 600)
        XCTAssertEqual(LifecyclePolicyConfig.config(for: .aggressive, onBatteryPower: true).discardThreshold, 600)
        XCTAssertEqual(LifecyclePolicyConfig.config(for: .conservative, onBatteryPower: true).discardThreshold, .infinity)
        XCTAssertEqual(LifecyclePolicyConfig.config(for: .balanced, onBatteryPower: false).discardThreshold, 1800)
    }

    func testBatteryPowerCapsIdleFreeze() {
        XCTAssertEqual(LifecyclePolicyConfig.config(for: .balanced, onBatteryPower: true).freezeThreshold, 60)
        XCTAssertEqual(LifecyclePolicyConfig.config(for: .conservative, onBatteryPower: true).freezeThreshold, 60)
        XCTAssertEqual(LifecyclePolicyConfig.config(for: .aggressive, onBatteryPower: true).freezeThreshold, 60)
        XCTAssertEqual(LifecyclePolicyConfig.config(for: .balanced, onBatteryPower: false).freezeThreshold, 300)
    }

    func testBatteryPowerTightensIdleSweep() {
        XCTAssertEqual(LifecyclePolicyConfig.config(for: .balanced, onBatteryPower: true).idleSweepInterval, 30)
        XCTAssertEqual(LifecyclePolicyConfig.config(for: .conservative, onBatteryPower: true).idleSweepInterval, 30)
        XCTAssertEqual(LifecyclePolicyConfig.config(for: .aggressive, onBatteryPower: true).idleSweepInterval, 30)
        XCTAssertEqual(LifecyclePolicyConfig.config(for: .balanced, onBatteryPower: false).idleSweepInterval, 60)
    }

    @MainActor
    func testSettingsStoreDefaultsToBalanced() throws {
        let store = try makeSettingsStore()
        XCTAssertEqual(store.lifecyclePreset, .balanced)
    }

    @MainActor
    func testSettingsStorePersistsPreset() throws {
        let store = try makeSettingsStore()
        store.lifecyclePreset = .aggressive
        XCTAssertEqual(store.lifecyclePreset, .aggressive)
    }

    func testCoordinatorAdoptsConfigValues() {
        let coordinator = TabLifecycleCoordinator(config: .config(for: .aggressive))
        XCTAssertEqual(coordinator.maxHiddenSpacesWithNormalRetainedEngines, 1)
        XCTAssertEqual(coordinator.audioGracePeriod, 30)
    }

    @MainActor
    func testRuntimeOverlayPreservesLastActiveAt() {
        let store = RuntimeOverlayStore()
        let id = UUID()
        var tab = Tab(id: id)
        let stamp = Date(timeIntervalSince1970: 1_000)
        tab.lastActiveAt = stamp
        store.setRuntimeState(from: tab)
        let applied = store.applied(to: Tab(id: id))
        XCTAssertEqual(applied.lastActiveAt, stamp)
    }

    @MainActor
    func testRuntimeOverlayPreservesFormDirty() {
        let store = RuntimeOverlayStore()
        let id = UUID()
        var tab = Tab(id: id)
        tab.hasUnsavedFormData = true
        store.setRuntimeState(from: tab)
        XCTAssertTrue(store.applied(to: Tab(id: id)).hasUnsavedFormData)
    }

    private var database: TemporaryProfileDatabase?

    override func tearDown() {
        database?.tearDown()
        database = nil
        super.tearDown()
    }

    @MainActor
    private func makeSettingsStore() throws -> SettingsStore {
        let database = try TemporaryProfileDatabase(schema: .global)
        self.database = database
        return SettingsStore(dbPool: database.pool)
    }
}
