import Compression
import GRDB
import XCTest
@testable import Lilo

final class FirefoxReaderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("firefox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sessionstore-backups"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private var profile: ImportProfile { ImportProfile(id: "x.default", name: "default", url: dir, kinds: ImportKind.allCases, extensions: []) }

    func testReadsToolbarBookmarksAndHistory() throws {
        let queue = try DatabaseQueue(path: dir.appendingPathComponent("places.sqlite").path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, hidden INTEGER, last_visit_date INTEGER)")
            try db.execute(sql: "CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER, title TEXT, guid TEXT)")
            try db.execute(sql: "INSERT INTO moz_places VALUES (1, 'https://dev.example/', 'Dev', 4, 0, 1700000000000000)")
            try db.execute(sql: "INSERT INTO moz_bookmarks VALUES (1, 2, NULL, 0, 0, '', 'root________')")
            try db.execute(sql: "INSERT INTO moz_bookmarks VALUES (2, 2, NULL, 1, 0, 'toolbar', 'toolbar_____')")
            try db.execute(sql: "INSERT INTO moz_bookmarks VALUES (3, 1, 1, 2, 0, 'Dev', 'aaaaaaaaaaaa')")
        }
        let result = FirefoxReader.read(profile: profile, kinds: [.bookmarks, .history])
        XCTAssertEqual(result.bundle.bookmarksBar, [ImportedBookmark(title: "Dev", url: "https://dev.example/")])
        XCTAssertEqual(result.bundle.history.first?.visitCount, 4)
    }

    func testReadsOpenTabsFromMozLz4Session() throws {
        try writeSession(#"{"windows": [{"tabs": [{"index": 2, "entries": [{"url": "https://old.example/"}, {"url": "https://now.example/", "title": "Now"}]}]}]}"#)
        let result = FirefoxReader.read(profile: profile, kinds: [.tabs])
        XCTAssertEqual(result.bundle.openTabs, [ImportedBookmark(title: "Now", url: "https://now.example/")])
    }

    func testPinnedTabsStayPinned() throws {
        try writeSession(#"""
            {"windows": [{"tabs": [
                {"pinned": true, "index": 1, "entries": [{"url": "https://mail.example/", "title": "Mail"}]},
                {"index": 1, "entries": [{"url": "https://news.example/", "title": "News"}]}
            ]}]}
            """#)
        let bundle = FirefoxReader.read(profile: profile, kinds: [.tabs]).bundle
        XCTAssertEqual(bundle.pinnedTabs, [ImportedBookmark(title: "Mail", url: "https://mail.example/")])
        XCTAssertEqual(bundle.openTabs, [ImportedBookmark(title: "News", url: "https://news.example/")])
        XCTAssertEqual(bundle.spaces, [])
    }

    func testZenWorkspacesBecomeSpacesAndEssentialsFavorites() throws {
        try writeSession(#"""
            {"windows": [{
                "spaces": [
                    {"uuid": "{w1}", "name": "Work", "icon": "💼",
                     "theme": {"gradientColors": [{"c": [0, 0, 0]}, {"c": [255, 128, 0], "isPrimary": true}]}},
                    {"uuid": "{w2}", "name": "Work", "icon": "chrome://browser/skin/zen-icons/selectable/star.svg"}
                ],
                "tabs": [
                    {"pinned": true, "zenEssential": true, "index": 1, "entries": [{"url": "https://chat.example/", "title": "Chat"}]},
                    {"pinned": true, "zenWorkspace": "{w1}", "zenStaticLabel": "Board", "index": 1,
                     "entries": [{"url": "https://board.example/item/7", "title": "Item 7"}],
                     "_zenPinnedInitialState": {"entry": {"url": "https://board.example/", "title": "Board home"}}},
                    {"zenWorkspace": "{w1}", "index": 1, "entries": [{"url": "https://docs.example/", "title": "Docs"}]},
                    {"zenWorkspace": "{w2}", "index": 1, "entries": [{"url": "https://read.example/", "title": "Read"}]},
                    {"zenWorkspace": "{gone}", "index": 1, "entries": [{"url": "https://loose.example/", "title": "Loose"}]}
                ]
            }]}
            """#)
        let bundle = FirefoxReader.read(profile: profile, kinds: [.tabs]).bundle
        XCTAssertEqual(bundle.favorites, [ImportedBookmark(title: "Chat", url: "https://chat.example/")])
        XCTAssertEqual(bundle.spaces, [
            ImportedSpace(name: "Work", icon: "💼", color: "#ff8000",
                          pinned: [ImportedBookmark(title: "Board", url: "https://board.example/")],
                          unpinned: [ImportedBookmark(title: "Docs", url: "https://docs.example/")]),
            ImportedSpace(name: "Work 2", icon: nil, color: nil, pinned: [],
                          unpinned: [ImportedBookmark(title: "Read", url: "https://read.example/")])
        ])
        XCTAssertEqual(bundle.pinnedTabs, [])
        XCTAssertEqual(bundle.openTabs, [ImportedBookmark(title: "Loose", url: "https://loose.example/")])
    }

    private func writeSession(_ string: String) throws {
        let json = Data(string.utf8)
        var compressed = [UInt8](repeating: 0, count: json.count + 64)
        let size = json.withUnsafeBytes { compression_encode_buffer(&compressed, compressed.count, $0.bindMemory(to: UInt8.self).baseAddress!, json.count, nil, COMPRESSION_LZ4_RAW) }
        var file = Data("mozLz40\0".utf8)
        file += withUnsafeBytes(of: UInt32(json.count).littleEndian, Array.init)
        file += compressed.prefix(size)
        try file.write(to: dir.appendingPathComponent("sessionstore-backups/recovery.jsonlz4"))
    }

    func testZeroSizeSessionIsAnErrorNotACrash() throws {
        var file = Data("mozLz40\0".utf8)
        file += [0, 0, 0, 0, 1, 2, 3]
        try file.write(to: dir.appendingPathComponent("sessionstore-backups/recovery.jsonlz4"))
        XCTAssertNotNil(FirefoxReader.read(profile: profile, kinds: [.tabs]).errors[.tabs])
    }

    func testMissingPlacesFailsBookmarksAndHistoryWithACause() {
        let errors = FirefoxReader.read(profile: profile, kinds: [.bookmarks, .history]).errors
        XCTAssertEqual(errors[.bookmarks], "other")
        XCTAssertEqual(errors[.history], "other")
    }

    func testNullCookieColumnsAreSkippedNotFatal() throws {
        let queue = try DatabaseQueue(path: dir.appendingPathComponent("cookies.sqlite").path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE moz_cookies (host TEXT, name TEXT, value TEXT, path TEXT, expiry INTEGER, isSecure INTEGER, isHttpOnly INTEGER, sameSite INTEGER)")
            try db.execute(sql: "INSERT INTO moz_cookies VALUES (NULL, 'a', '1', '/', 4102444800, 0, 0, 0)")
            try db.execute(sql: "INSERT INTO moz_cookies VALUES ('.b.example', 'b', NULL, NULL, NULL, NULL, NULL, NULL)")
        }
        let result = FirefoxReader.read(profile: profile, kinds: [.cookies])
        XCTAssertNil(result.errors[.cookies])
        XCTAssertEqual(result.bundle.cookies.map(\.name), ["b"])
    }

}
