import XCTest
@testable import Lilo

@MainActor
final class WindowStoreTests: XCTestCase {
    private var database: TemporaryProfileDatabase!

    override func setUpWithError() throws {
        database = try TemporaryProfileDatabase(schema: .global)
    }

    override func tearDown() {
        database.tearDown()
        database = nil
        super.tearDown()
    }

    func testWindowsRoundTripInOpeningOrder() throws {
        let store = WindowStore(dbPool: database.pool)
        let first = StoredWindow(frame: NSRect(x: 10, y: 20, width: 1200, height: 800), spaceId: UUID())
        let second = StoredWindow(frame: NSRect(x: 40, y: 0, width: 900, height: 700), spaceId: nil)

        try store.replaceAll([first, second])

        XCTAssertEqual(try database.pool.read(WindowStore.load), [first, second])
    }

    func testReplacingForgetsClosedWindows() throws {
        let store = WindowStore(dbPool: database.pool)
        let kept = StoredWindow(frame: NSRect(x: 0, y: 0, width: 800, height: 600), spaceId: UUID())
        try store.replaceAll([kept, StoredWindow(frame: NSRect(x: 5, y: 5, width: 800, height: 600), spaceId: UUID())])

        try store.replaceAll([kept])

        XCTAssertEqual(try database.pool.read(WindowStore.load), [kept])
    }
}
