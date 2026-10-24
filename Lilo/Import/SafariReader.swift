import Foundation
import GRDB

enum SafariReader {
    /// `safariURL` is `~/Library/Safari`; `cookiesURL` the `Cookies.binarycookies` file.
    static func read(safariURL: URL, cookiesURL: URL, kinds: Set<ImportKind>) -> ImportReadResult {
        var result = ImportReadResult()
        if kinds.contains(.bookmarks) {
            result.attempt(.bookmarks) { bundle in
                let data = try Data(contentsOf: safariURL.appendingPathComponent("Bookmarks.plist"))
                guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    throw ImportError.malformed("Bookmarks.plist")
                }
                for child in root["Children"] as? [[String: Any]] ?? [] {
                    switch child["Title"] as? String {
                    case "BookmarksBar": bundle.bookmarksBar = items(child)
                    case "com.apple.ReadingList": continue
                    default:
                        if let item = item(child) { bundle.otherBookmarks += item.url == nil ? item.children : [item] }
                    }
                }
            }
        }
        if kinds.contains(.tabs) {
            result.attempt(.tabs) { bundle in
                let data = try Data(contentsOf: safariURL.appendingPathComponent("LastSession.plist"))
                let session = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                bundle.openTabs = (session?["SessionWindows"] as? [[String: Any]] ?? []).flatMap { window in
                    (window["TabStates"] as? [[String: Any]] ?? []).compactMap { tab in
                        guard let url = tab["TabURL"] as? String, url.hasPrefix("http") else { return nil }
                        return ImportedBookmark(title: tab["TabTitle"] as? String ?? "", url: url)
                    }
                }
            }
        }
        if kinds.contains(.history) {
            result.attempt(.history) { bundle in
                bundle.history = try ImportFiles.withCopy(safariURL.appendingPathComponent("History.db")) { db in
                    try Row.fetchAll(db, sql: """
                        SELECT i.url AS url, i.visit_count AS count, MAX(v.visit_time) AS time,
                               (SELECT title FROM history_visits WHERE history_item = i.id ORDER BY visit_time DESC LIMIT 1) AS title
                        FROM history_items i JOIN history_visits v ON v.history_item = i.id
                        GROUP BY i.id ORDER BY time DESC LIMIT ?
                        """, arguments: [HistoryStore.maxRows]).compactMap { row in
                        let url: String = row["url"]
                        guard url.hasPrefix("http") else { return nil }
                        return ImportedVisit(url: url, title: row["title"] ?? "", visitCount: row["count"],
                                             lastVisitedAt: Date(timeIntervalSinceReferenceDate: row["time"]))
                    }
                }
            }
        }
        if kinds.contains(.cookies) {
            result.attempt(.cookies) { bundle in bundle.cookies = try binaryCookies(Data(contentsOf: cookiesURL)) }
        }
        return result
    }

    private static func items(_ list: [String: Any]) -> [ImportedBookmark] {
        (list["Children"] as? [[String: Any]] ?? []).compactMap(item)
    }

    private static func item(_ node: [String: Any]) -> ImportedBookmark? {
        switch node["WebBookmarkType"] as? String {
        case "WebBookmarkTypeLeaf":
            guard let url = node["URLString"] as? String, url.hasPrefix("http") else { return nil }
            let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? url
            return ImportedBookmark(title: title, url: url)
        case "WebBookmarkTypeList":
            return ImportedBookmark(title: node["Title"] as? String ?? "", url: nil, children: items(node))
        default:
            return nil
        }
    }

    /// Format: "cook", page count and sizes (big-endian), then pages of little-endian cookie records
    /// whose strings are addressed by offsets from the record start; dates are seconds since 2001.
    private static func binaryCookies(_ data: Data) throws -> [ImportedCookie] {
        let bytes = [UInt8](data)
        func be32(_ at: Int) throws -> Int {
            guard at + 4 <= bytes.count else { throw ImportError.malformed("Cookies.binarycookies") }
            return Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
        }
        func le32(_ at: Int) throws -> Int {
            guard at + 4 <= bytes.count else { throw ImportError.malformed("Cookies.binarycookies") }
            return Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        func double(_ at: Int) throws -> Double {
            guard at + 8 <= bytes.count else { throw ImportError.malformed("Cookies.binarycookies") }
            return Double(bitPattern: bytes[at..<at + 8].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) })
        }
        func string(_ at: Int) throws -> String {
            guard at < bytes.count, let end = bytes[at...].firstIndex(of: 0),
                  let value = String(bytes: bytes[at..<end], encoding: .utf8) else { throw ImportError.malformed("Cookies.binarycookies") }
            return value
        }
        guard bytes.count >= 8, bytes.starts(with: [UInt8]("cook".utf8)) else { throw ImportError.malformed("Cookies.binarycookies") }
        let pageCount = try be32(4)
        var pageStart = 8 + pageCount * 4
        var cookies: [ImportedCookie] = []
        for page in 0..<pageCount {
            let pageSize = try be32(8 + page * 4)
            let count = try le32(pageStart + 4)
            for index in 0..<count {
                let record = pageStart + (try le32(pageStart + 8 + index * 4))
                let flags = try le32(record + 8)
                let expiry = try double(record + 40)
                cookies.append(ImportedCookie(
                    domain: try string(record + (try le32(record + 16))),
                    name: try string(record + (try le32(record + 20))),
                    value: try string(record + (try le32(record + 28))),
                    path: try string(record + (try le32(record + 24))),
                    expires: expiry == 0 ? nil : Date(timeIntervalSinceReferenceDate: expiry),
                    isSecure: flags & 1 != 0, isHTTPOnly: flags & 4 != 0, sameSite: nil))
            }
            pageStart += pageSize
        }
        return cookies
    }
}
