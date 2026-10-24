import GRDB
import XCTest
@testable import Lilo

@MainActor
final class OnboardingSettingsTests: XCTestCase {
    private var path: String!

    override func setUp() { path = NSTemporaryDirectory() + UUID().uuidString + ".db" }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    private func makeStore() throws -> SettingsStore {
        let pool = try DatabasePool(path: path)
        try Migrations.migrateGlobal(pool)
        return SettingsStore(dbPool: pool)
    }

    func testFreshInstallShowsOnboardingUntilCompleted() throws {
        let store = try makeStore()
        store.resolveOnboarding(freshInstall: true)
        XCTAssertTrue(store.shouldShowOnboarding)
        store.onboardingStep = 3
        store.resolveOnboarding(freshInstall: false)
        XCTAssertTrue(store.shouldShowOnboarding, "a later launch with spaces keeps an unfinished onboarding")
        store.completeOnboarding()
        XCTAssertFalse(store.shouldShowOnboarding)
        XCTAssertEqual(store.onboardingStep, 0)
    }

    func testExistingInstallIsMarkedCompleted() throws {
        let store = try makeStore()
        store.resolveOnboarding(freshInstall: false)
        XCTAssertFalse(store.shouldShowOnboarding)
        XCTAssertEqual(store.get("onboardingCompleted"), "true")
    }

    func testLoadErrorNeverShowsOnboarding() throws {
        // No settings table: the initial read fails, as it does when the database cannot be loaded.
        let store = SettingsStore(dbPool: try DatabasePool(path: path))
        XCTAssertNotNil(store.initialLoadError)
        store.resolveOnboarding(freshInstall: true)
        XCTAssertFalse(store.shouldShowOnboarding)
    }
}
