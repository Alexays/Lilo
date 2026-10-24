import XCTest
import GRDB
@testable import Lilo

final class BookmarkStoreTests: XCTestCase {
    private var database: TemporaryProfileDatabase!
    private var store: BookmarkStore!

    override func setUpWithError() throws {
        database = try TemporaryProfileDatabase()
        store = BookmarkStore(dbPool: database.pool)
    }

    override func tearDownWithError() throws {
        store = nil
        database.tearDown()
        database = nil
    }

    private func childTitlesAndIndexes(of parentId: String) throws -> [(String, Int?)] {
        try store.getChildren(parentId: parentId).map { ($0.title, $0.index_) }
    }

    // "1" is the seeded Bookmarks bar folder; children created here get indexes 0...n-1.

    func testMoveWithinSameParentReindexesSiblingsExactly() throws {
        _ = try store.create(parentId: "1", title: "a", url: "https://a.test")
        _ = try store.create(parentId: "1", title: "b", url: "https://b.test")
        let c = try store.create(parentId: "1", title: "c", url: "https://c.test")
        _ = try store.create(parentId: "1", title: "d", url: "https://d.test")

        let moved = try store.move(id: c.id, parentId: nil, index: 0)

        XCTAssertEqual(moved.parentId, "1")
        XCTAssertEqual(moved.index_, 0)
        let children = try childTitlesAndIndexes(of: "1")
        XCTAssertEqual(children.map(\.0), ["c", "a", "b", "d"])
        XCTAssertEqual(children.map(\.1), [0, 1, 2, 3])
    }

    func testMoveToOtherParentClosesSourceGapAndShiftsDestination() throws {
        _ = try store.create(parentId: "1", title: "a", url: "https://a.test")
        let b = try store.create(parentId: "1", title: "b", url: "https://b.test")
        _ = try store.create(parentId: "1", title: "c", url: "https://c.test")
        _ = try store.create(parentId: "2", title: "x", url: "https://x.test")

        let moved = try store.move(id: b.id, parentId: "2", index: 0)

        XCTAssertEqual(moved.parentId, "2")
        XCTAssertEqual(moved.index_, 0)
        let source = try childTitlesAndIndexes(of: "1")
        XCTAssertEqual(source.map(\.0), ["a", "c"])
        XCTAssertEqual(source.map(\.1), [0, 1])
        let destination = try childTitlesAndIndexes(of: "2")
        XCTAssertEqual(destination.map(\.0), ["b", "x"])
        XCTAssertEqual(destination.map(\.1), [0, 1])
    }

    func testMoveWithoutIndexAppendsToDestination() throws {
        let a = try store.create(parentId: "1", title: "a", url: "https://a.test")
        _ = try store.create(parentId: "2", title: "x", url: "https://x.test")

        let moved = try store.move(id: a.id, parentId: "2", index: nil)

        XCTAssertEqual(moved.parentId, "2")
        XCTAssertEqual(moved.index_, 1)
        let destination = try childTitlesAndIndexes(of: "2")
        XCTAssertEqual(destination.map(\.0), ["x", "a"])
        XCTAssertEqual(destination.map(\.1), [0, 1])
    }

    func testMoveClampsOversizedIndexToEnd() throws {
        let a = try store.create(parentId: "1", title: "a", url: "https://a.test")
        _ = try store.create(parentId: "1", title: "b", url: "https://b.test")

        let moved = try store.move(id: a.id, parentId: nil, index: 99)

        XCTAssertEqual(moved.index_, 1)
        let children = try childTitlesAndIndexes(of: "1")
        XCTAssertEqual(children.map(\.0), ["b", "a"])
        XCTAssertEqual(children.map(\.1), [0, 1])
    }

    func testMoveAfterRemoveCompactsSparseIndexes() throws {
        let a = try store.create(parentId: "1", title: "a", url: "https://a.test")
        let b = try store.create(parentId: "1", title: "b", url: "https://b.test")
        _ = try store.create(parentId: "1", title: "c", url: "https://c.test")
        _ = try store.create(parentId: "1", title: "d", url: "https://d.test")

        // remove() leaves a gap at index 1; move must reason in positions, not stored indexes.
        try store.remove(id: b.id)
        let moved = try store.move(id: a.id, parentId: nil, index: 1)

        XCTAssertEqual(moved.index_, 1)
        let children = try childTitlesAndIndexes(of: "1")
        XCTAssertEqual(children.map(\.0), ["c", "a", "d"])
        XCTAssertEqual(children.map(\.1), [0, 1, 2])
    }

    func testRemoveTreeDeletesNodeAndDescendantsOnly() throws {
        let folder = try store.create(parentId: "1", title: "folder", url: nil)
        let child = try store.create(parentId: folder.id, title: "child", url: "https://child.test")
        let grandchild = try store.create(parentId: child.id, title: "grandchild", url: "https://gc.test")
        let sibling = try store.create(parentId: "1", title: "sibling", url: "https://s.test")

        try store.removeTree(id: folder.id)

        XCTAssertNil(try store.get(id: folder.id))
        XCTAssertNil(try store.get(id: child.id))
        XCTAssertNil(try store.get(id: grandchild.id))
        XCTAssertEqual(try store.get(id: sibling.id)?.title, "sibling")
        XCTAssertEqual(try store.get(id: "1")?.title, "Bookmarks bar")
    }

    func testRemoveRefusesANonEmptyFolderAndTheRoots() throws {
        let folder = try store.create(parentId: "1", title: "folder", url: nil)
        let child = try store.create(parentId: folder.id, title: "child", url: "https://child.test")

        XCTAssertThrowsError(try store.remove(id: folder.id))
        XCTAssertThrowsError(try store.remove(id: "2"))
        XCTAssertThrowsError(try store.removeTree(id: "1"))
        XCTAssertEqual(try store.get(id: child.id)?.parentId, folder.id)
        XCTAssertEqual(try store.get(id: "1")?.title, "Bookmarks bar")

        try store.remove(id: child.id)
        try store.remove(id: folder.id)
        XCTAssertNil(try store.get(id: folder.id))
    }

    func testSearchMatchesWildcardCharactersLiterally() throws {
        let literal = try store.create(parentId: "1", title: "a_b 100%", url: "https://a.test")
        _ = try store.create(parentId: "1", title: "axb 1000", url: "https://b.test")

        XCTAssertEqual(try store.search(url: nil, title: "a_b", query: nil).map(\.id), [literal.id])
        XCTAssertEqual(try store.search(url: nil, title: nil, query: "0%").map(\.id), [literal.id])
    }

    func testRemoveTreeOfLeafDeletesJustThatNode() throws {
        let a = try store.create(parentId: "1", title: "a", url: "https://a.test")
        let b = try store.create(parentId: "1", title: "b", url: "https://b.test")

        try store.removeTree(id: a.id)

        XCTAssertNil(try store.get(id: a.id))
        XCTAssertEqual(try store.get(id: b.id)?.title, "b")
    }

    func testCreateAfterRemoveAppendsPastTheHighestIndex() throws {
        let a = try store.create(parentId: "1", title: "a", url: "https://a.test")
        _ = try store.create(parentId: "1", title: "b", url: "https://b.test")
        try store.remove(id: a.id)

        let c = try store.create(parentId: "1", title: "c", url: "https://c.test")

        XCTAssertEqual(c.index_, 2)
        XCTAssertEqual(try childTitlesAndIndexes(of: "1").map(\.0), ["b", "c"])
    }

    func testMoveIntoOwnDescendantThrowsAndLeavesTreeUnchanged() throws {
        let folder = try store.create(parentId: "1", title: "folder", url: nil)
        let child = try store.create(parentId: folder.id, title: "child", url: nil)

        XCTAssertThrowsError(try store.move(id: folder.id, parentId: child.id, index: nil))
        XCTAssertThrowsError(try store.move(id: folder.id, parentId: folder.id, index: nil))

        XCTAssertEqual(try store.get(id: folder.id)?.parentId, "1")
        XCTAssertEqual(try store.get(id: child.id)?.parentId, folder.id)
    }
}
