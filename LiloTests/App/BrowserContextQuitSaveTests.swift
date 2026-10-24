import XCTest
@testable import Lilo

/// Quitting writes each space's tab tree into its own profile's database, and nothing of private spaces.
@MainActor
final class BrowserContextQuitSaveTests: XCTestCase {
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

    func testQuitSaveWritesEachSpaceIntoItsOwnProfilePool() throws {
        let context = browserContext.context
        let profileA = try context.profileManager.createProfile(name: "A").id
        let profileB = try context.profileManager.createProfile(name: "B").id
        let spaceA = try context.spaceManager.createSpace(name: "A", profileId: profileA)
        let spaceB = try context.spaceManager.createSpace(name: "B", profileId: profileB)
        let privateA = try context.spaceManager.createSpace(name: "P", profileId: profileA, isPrivate: true)
        for space in [spaceA, spaceB, privateA] {
            let state = SpaceTabState(activeTabId: nil, activationHistory: [], tree: .empty)
            context.browserState.storeSpace(id: space.id, snapshot: .init(spaceTab: SpaceTab(spaceId: space.id, state: state), engines: [:]))
        }

        context.saveSpaceStatesBeforeQuit()

        let storeA = SpaceTabStateStore(dbPool: try context.dbManager.pool(for: profileA))
        let storeB = SpaceTabStateStore(dbPool: try context.dbManager.pool(for: profileB))
        XCTAssertNotNil(try storeA.load(spaceId: spaceA.id))
        XCTAssertNil(try storeA.load(spaceId: spaceB.id), "a space must never be written into another profile's database")
        XCTAssertNotNil(try storeB.load(spaceId: spaceB.id))
        XCTAssertNil(try storeA.load(spaceId: privateA.id), "private spaces leave nothing behind")
    }
}
