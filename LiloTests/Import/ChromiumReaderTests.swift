import GRDB
import XCTest
@testable import Lilo

final class ChromiumReaderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("chromium-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Network"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private var profile: ImportProfile { ImportProfile(id: "Default", name: "Perso", url: dir, kinds: ImportKind.allCases, extensions: []) }

    func testReadsBookmarkBarAndOtherRoots() throws {
        let json = """
        {"roots": {
          "bookmark_bar": {"children": [
            {"type": "url", "name": "Mail", "url": "https://mail.example/"},
            {"type": "folder", "name": "Work", "children": [{"type": "url", "name": "Docs", "url": "https://docs.example/"}]},
            {"type": "url", "name": "Local", "url": "chrome://settings"}
          ]},
          "other": {"children": [{"type": "url", "name": "Recipe", "url": "https://food.example/"}]},
          "synced": {"children": []}
        }}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("Bookmarks"))
        let result = ChromiumReader.read(profile: profile, kinds: [.bookmarks], arc: nil, password: { "" })
        XCTAssertNil(result.errors[.bookmarks])
        XCTAssertEqual(result.bundle.bookmarksBar, [
            ImportedBookmark(title: "Mail", url: "https://mail.example/"),
            ImportedBookmark(title: "Work", url: nil, children: [ImportedBookmark(title: "Docs", url: "https://docs.example/")])
        ])
        XCTAssertEqual(result.bundle.otherBookmarks.map(\.title), ["Recipe"])
    }

    func testTruncatedBookmarksReportAnErrorWithoutStoppingOtherKinds() throws {
        try Data("{\"roots\": {\"bookmark_bar\":".utf8).write(to: dir.appendingPathComponent("Bookmarks"))
        try makeHistory(rows: [("https://a.example/", "A", 3, 13_300_000_000_000_000)], wal: false)
        let result = ChromiumReader.read(profile: profile, kinds: [.bookmarks, .history], arc: nil, password: { "" })
        XCTAssertNotNil(result.errors[.bookmarks])
        XCTAssertEqual(result.bundle.history.map(\.url), ["https://a.example/"])
    }

    func testHistoryIncludesRowsStillInTheWAL() throws {
        try makeHistory(rows: [("https://wal.example/", "W", 1, 13_300_000_000_000_000)], wal: true)
        let result = ChromiumReader.read(profile: profile, kinds: [.history], arc: nil, password: { "" })
        XCTAssertEqual(result.bundle.history.map(\.url), ["https://wal.example/"])
    }

    func testCookiesDecryptAndKeychainDenialOnlySkipsCookies() throws {
        let pool = try DatabasePool(path: dir.appendingPathComponent("Network/Cookies").path)
        try pool.write { db in
            try db.execute(sql: "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
            try db.execute(sql: "INSERT INTO meta VALUES ('version', '23')")
            try db.execute(sql: """
                CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, path TEXT,
                expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, samesite INTEGER)
                """)
            try db.execute(sql: "INSERT INTO cookies VALUES (?, ?, '', ?, '/', 0, 1, 1, 1)",
                           arguments: [".example.com", "sid", ChromiumCookieDecryptorTests.chromiumEncrypt(Data("42".utf8), password: "pw")])
        }
        let ok = ChromiumReader.read(profile: profile, kinds: [.cookies], arc: nil, password: { "pw" })
        XCTAssertEqual(ok.bundle.cookies, [ImportedCookie(domain: ".example.com", name: "sid", value: "42", path: "/", expires: nil,
                                                          isSecure: true, isHTTPOnly: true, sameSite: "lax")])
        try makeHistory(rows: [("https://a.example/", "A", 1, 13_300_000_000_000_000)], wal: false)
        let denied = ChromiumReader.read(profile: profile, kinds: [.cookies, .history], arc: nil,
                                         password: { throw ImportError.keychain(errSecAuthFailed) })
        XCTAssertNotNil(denied.errors[.cookies])
        XCTAssertEqual(denied.bundle.history.count, 1)
        let wrongKey = ChromiumReader.read(profile: profile, kinds: [.cookies], arc: nil, password: { "other" })
        XCTAssertNotNil(wrongKey.errors[.cookies], "a key that decrypts nothing is an error, not an empty import")
    }

    func testListsOnlyWebStoreExtensionsWithLocalizedNames() throws {
        let id = String(repeating: "a", count: 32)
        let ext = dir.appendingPathComponent("Extensions/\(id)/1.0_0")
        try FileManager.default.createDirectory(at: ext.appendingPathComponent("_locales/en"), withIntermediateDirectories: true)
        try Data(#"{"name": "__MSG_appName__", "default_locale": "en", "update_url": "https://clients2.google.com/service/update2/crx"}"#.utf8)
            .write(to: ext.appendingPathComponent("manifest.json"))
        try Data(#"{"appName": {"message": "Blocker"}}"#.utf8).write(to: ext.appendingPathComponent("_locales/en/messages.json"))
        let unpacked = dir.appendingPathComponent("Extensions/\(String(repeating: "b", count: 32))/2.0")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try Data(#"{"name": "Dev"}"#.utf8).write(to: unpacked.appendingPathComponent("manifest.json"))
        XCTAssertEqual(ChromiumReader.extensions(in: dir), [ImportedExtension(id: id, name: "Blocker")])
    }

    func testAnExtensionIsReadFromItsNewestVersion() throws {
        let id = String(repeating: "c", count: 32)
        for (version, name) in [("9.0_0", "Old"), ("10.0_0", "New")] {
            let folder = dir.appendingPathComponent("Extensions/\(id)/\(version)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"name": "\#(name)", "update_url": "https://clients2.google.com/service/update2/crx"}"#.utf8)
                .write(to: folder.appendingPathComponent("manifest.json"))
        }

        XCTAssertEqual(ChromiumReader.extensions(in: dir), [ImportedExtension(id: id, name: "New")])
    }

    /// `wal: true` leaves the rows in the -wal file by keeping a reader open past the write.
    private func makeHistory(rows: [(String, String, Int, Int64)], wal: Bool) throws {
        let url = dir.appendingPathComponent("History")
        try? FileManager.default.removeItem(at: url)
        let pool = try DatabasePool(path: url.path)
        try pool.write { db in
            try db.execute(sql: "CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, last_visit_time INTEGER, hidden INTEGER DEFAULT 0)")
            for row in rows {
                try db.execute(sql: "INSERT INTO urls (url, title, visit_count, last_visit_time) VALUES (?, ?, ?, ?)", arguments: [row.0, row.1, row.2, row.3])
            }
        }
        if !wal { _ = try pool.writeWithoutTransaction { try $0.checkpoint(.truncate) } }
        // Keep `pool` alive until the read when testing the WAL case.
        if wal { walPool = pool }
    }

    private var walPool: DatabasePool?
}
