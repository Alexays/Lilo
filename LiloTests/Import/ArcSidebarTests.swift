import XCTest
@testable import Lilo

final class ArcSidebarTests: XCTestCase {
    func testParsesSpacesPinnedFoldersAndFavorites() throws {
        let json = """
        {"sidebar": {"containers": [{"global": {}}, {
          "topAppsContainerIDs": ["fav", {"default": true}],
          "spaces": ["s1", {"id": "s1", "title": "Work", "containerIDs": ["pinned", "p1", "unpinned", "u1"],
                            "customInfo": {"iconType": {"emoji_v2": "💼"}}}],
          "items": [
            "fav", {"id": "fav", "childrenIds": ["f1"], "data": {"itemContainer": {}}},
            "f1", {"id": "f1", "title": null, "data": {"tab": {"savedURL": "https://mail.example/", "savedTitle": "Mail"}}},
            "p1", {"id": "p1", "childrenIds": ["folder", "t1"], "data": {"itemContainer": {}}},
            "folder", {"id": "folder", "title": "Docs", "childrenIds": ["t2"], "data": {"list": {}}},
            "t1", {"id": "t1", "title": "Board", "data": {"tab": {"savedURL": "https://board.example/"}}},
            "t2", {"id": "t2", "title": "Spec", "data": {"tab": {"savedURL": "https://spec.example/"}}},
            "u1", {"id": "u1", "childrenIds": ["t3"], "data": {"itemContainer": {}}},
            "t3", {"id": "t3", "title": "Search", "data": {"tab": {"savedURL": "https://search.example/"}}}
          ]}]}}
        """
        let arc = try ArcSidebar.parse(Data(json.utf8), profile: "Default", profiles: ["Default"])
        XCTAssertEqual(arc.favorites, [ImportedBookmark(title: "Mail", url: "https://mail.example/")])
        XCTAssertEqual(arc.spaces, [ImportedSpace(
            name: "Work", icon: "💼",
            pinned: [ImportedBookmark(title: "Docs", url: nil, children: [ImportedBookmark(title: "Spec", url: "https://spec.example/")]),
                     ImportedBookmark(title: "Board", url: "https://board.example/")],
            unpinned: [ImportedBookmark(title: "Search", url: "https://search.example/")])])
    }

    func testUnexpectedShapeThrows() {
        XCTAssertThrowsError(try ArcSidebar.parse(Data(#"{"sidebar": {"containers": [{"global": {}}]}}"#.utf8), profile: "Default", profiles: []))
    }
}
