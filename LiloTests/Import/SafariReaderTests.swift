import GRDB
import XCTest
@testable import Lilo

final class SafariReaderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("safari-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testReadsBarMenuAndSkipsReadingList() throws {
        let plist: [String: Any] = ["Children": [
            ["Title": "BookmarksBar", "WebBookmarkType": "WebBookmarkTypeList", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://news.example/", "URIDictionary": ["title": "News"]]]],
            ["Title": "BookmarksMenu", "WebBookmarkType": "WebBookmarkTypeList", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://menu.example/", "URIDictionary": ["title": "Menu"]]]],
            ["Title": "com.apple.ReadingList", "WebBookmarkType": "WebBookmarkTypeList", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://later.example/"]]]
        ]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: dir.appendingPathComponent("Bookmarks.plist"))
        let result = SafariReader.read(safariURL: dir, cookiesURL: dir.appendingPathComponent("none"), kinds: [.bookmarks])
        XCTAssertEqual(result.bundle.bookmarksBar, [ImportedBookmark(title: "News", url: "https://news.example/")])
        XCTAssertEqual(result.bundle.otherBookmarks, [ImportedBookmark(title: "Menu", url: "https://menu.example/")])
    }

    func testParsesBinaryCookiesAndRejectsTruncatedFiles() throws {
        let url = dir.appendingPathComponent("Cookies.binarycookies")
        try Self.binaryCookies(domain: ".example.com", name: "sid", path: "/", value: "v", flags: 5, expiry: 800_000_000).write(to: url)
        let result = SafariReader.read(safariURL: dir, cookiesURL: url, kinds: [.cookies])
        XCTAssertEqual(result.bundle.cookies, [ImportedCookie(domain: ".example.com", name: "sid", value: "v", path: "/",
            expires: Date(timeIntervalSinceReferenceDate: 800_000_000), isSecure: true, isHTTPOnly: true, sameSite: nil)])
        try Data("cook\0\0\0\u{1}".utf8).write(to: url)
        XCTAssertNotNil(SafariReader.read(safariURL: dir, cookiesURL: url, kinds: [.cookies]).errors[.cookies])
    }

    /// Writes a one-page, one-cookie file in Safari's layout.
    static func binaryCookies(domain: String, name: String, path: String, value: String, flags: UInt32, expiry: Double) -> Data {
        func le(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        func be(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
        let strings = [domain, name, path, value].map { Array($0.utf8) + [0] }
        let header = 56
        var offsets: [UInt32] = []
        var cursor = header
        for s in strings { offsets.append(UInt32(cursor)); cursor += s.count }
        var record = le(UInt32(cursor)) + le(0) + le(flags) + le(0)
        record += le(offsets[0]) + le(offsets[1]) + le(offsets[2]) + le(offsets[3])
        record += [UInt8](repeating: 0, count: 8)
        record += withUnsafeBytes(of: expiry.bitPattern.littleEndian, Array.init) + withUnsafeBytes(of: expiry.bitPattern.littleEndian, Array.init)
        record += strings.flatMap { $0 }
        let page = [0, 0, 1, 0] + le(1) + le(16) + le(0) + record
        return Data([UInt8]("cook".utf8) + be(1) + be(UInt32(page.count)) + page)
    }
}
