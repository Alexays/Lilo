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
        let json = Data(#"{"windows": [{"tabs": [{"index": 2, "entries": [{"url": "https://old.example/"}, {"url": "https://now.example/", "title": "Now"}]}]}]}"#.utf8)
        var compressed = [UInt8](repeating: 0, count: json.count + 64)
        let size = json.withUnsafeBytes { compression_encode_buffer(&compressed, compressed.count, $0.bindMemory(to: UInt8.self).baseAddress!, json.count, nil, COMPRESSION_LZ4_RAW) }
        var file = Data("mozLz40\0".utf8)
        file += withUnsafeBytes(of: UInt32(json.count).littleEndian, Array.init)
        file += compressed.prefix(size)
        try file.write(to: dir.appendingPathComponent("sessionstore-backups/recovery.jsonlz4"))
        let result = FirefoxReader.read(profile: profile, kinds: [.tabs])
        XCTAssertEqual(result.bundle.openTabs, [ImportedBookmark(title: "Now", url: "https://now.example/")])
    }

    func testZeroSizeSessionIsAnErrorNotACrash() throws {
        var file = Data("mozLz40\0".utf8)
        file += [0, 0, 0, 0, 1, 2, 3]
        try file.write(to: dir.appendingPathComponent("sessionstore-backups/recovery.jsonlz4"))
        XCTAssertNotNil(FirefoxReader.read(profile: profile, kinds: [.tabs]).errors[.tabs])
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
