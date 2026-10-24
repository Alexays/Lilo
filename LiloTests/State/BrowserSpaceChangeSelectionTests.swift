import XCTest
@testable import Lilo

/// A change relayed to another window carries that window's selection, so its sidebar keeps it.
@MainActor
final class BrowserSpaceChangeSelectionTests: XCTestCase {
    func testSelectingReplacesTheActiveTabWithoutAnnouncingAnActivation() throws {
        let spaceId = UUID(), selection = UUID()
        let store = BrowserStateStore()
        store.storeSpace(id: spaceId, snapshot: .init(
            spaceTab: SpaceTab(spaceId: spaceId, state: SpaceTabState(activeTabId: nil, activationHistory: [], tree: .empty)),
            engines: [:]
        ))
        let change = try XCTUnwrap(store.browserSpaceChange(spaceId: spaceId)).selecting(selection)

        XCTAssertEqual(change.state.activeTabId, selection)
        XCTAssertEqual(change.previousActiveTabId, selection)
    }
}
