import Compression
import Foundation
import GRDB

enum FirefoxReader {
    static func read(profile: ImportProfile, kinds: Set<ImportKind>) -> ImportReadResult {
        var result = ImportReadResult()
        let dir = profile.url
        // Bookmarks and history share places.sqlite, often large: one copy serves both, each failing alone.
        let placesKinds = kinds.intersection([.bookmarks, .history])
        if !placesKinds.isEmpty {
            do {
                try ImportFiles.withCopy(dir.appendingPathComponent("places.sqlite")) { db in
                    if kinds.contains(.bookmarks) {
                        result.attempt(.bookmarks) { bundle in
                            let rows = try Row.fetchAll(db, sql: """
                                SELECT b.id, b.type, b.parent, b.title, b.guid, p.url FROM moz_bookmarks b
                                LEFT JOIN moz_places p ON p.id = b.fk ORDER BY b.parent, b.position
                                """)
                            var byParent: [Int64: [Row]] = [:]
                            var rootIds: [String: Int64] = [:]
                            for row in rows {
                                guard let parent: Int64 = row["parent"] else { continue }
                                byParent[parent, default: []].append(row)
                                if let guid: String = row["guid"] { rootIds[guid] = row["id"] }
                            }
                            // Depth-capped so a corrupt parent cycle cannot recurse forever.
                            func children(_ id: Int64, depth: Int = 0) -> [ImportedBookmark] {
                                guard depth < 32 else { return [] }
                                return (byParent[id] ?? []).compactMap { row in
                                    let type: Int = row["type"] ?? 0
                                    let title: String = row["title"] ?? ""
                                    if type == 2 { return ImportedBookmark(title: title, url: nil, children: children(row["id"], depth: depth + 1)) }
                                    guard type == 1, let url: String = row["url"], url.hasPrefix("http") else { return nil }
                                    return ImportedBookmark(title: title, url: url)
                                }
                            }
                            bundle.bookmarksBar = rootIds["toolbar_____"].map { children($0) } ?? []
                            bundle.otherBookmarks = ["menu________", "unfiled_____", "mobile______"].flatMap { rootIds[$0].map { children($0) } ?? [] }
                        }
                    }
                    if kinds.contains(.history) {
                        result.attempt(.history) { bundle in
                            bundle.history = try Row.fetchAll(db, sql: """
                                SELECT url, title, visit_count, last_visit_date FROM moz_places
                                WHERE visit_count > 0 AND hidden = 0 AND last_visit_date IS NOT NULL AND url LIKE 'http%'
                                ORDER BY last_visit_date DESC LIMIT ?
                                """, arguments: [HistoryStore.maxRows]).map {
                                let micros: Int64 = $0["last_visit_date"]
                                return ImportedVisit(url: $0["url"], title: $0["title"] ?? "", visitCount: $0["visit_count"] ?? 1,
                                                     lastVisitedAt: Date(timeIntervalSince1970: Double(micros) / 1_000_000))
                            }
                        }
                    }
                }
            } catch {
                let cause = ImportError.cause(of: error, "Reading Firefox places")
                for kind in placesKinds { result.errors[kind] = cause }
            }
        }
        if kinds.contains(.cookies) {
            result.attempt(.cookies) { bundle in
                bundle.cookies = try ImportFiles.withCopy(dir.appendingPathComponent("cookies.sqlite")) { db in
                    try Row.fetchAll(db, sql: "SELECT host, name, value, path, expiry, isSecure, isHttpOnly, sameSite FROM moz_cookies").compactMap {
                        guard let host: String = $0["host"], let name: String = $0["name"] else { return nil }
                        let expiry: Int64 = $0["expiry"] ?? 0
                        // Newer Firefox stores milliseconds, older seconds.
                        let seconds = expiry > 100_000_000_000 ? Double(expiry) / 1000 : Double(expiry)
                        let sameSite: Int = $0["sameSite"] ?? -1
                        return ImportedCookie(domain: host, name: name, value: $0["value"] ?? "", path: $0["path"] ?? "/",
                                              expires: expiry == 0 ? nil : Date(timeIntervalSince1970: seconds),
                                              isSecure: $0["isSecure"] ?? false, isHTTPOnly: $0["isHttpOnly"] ?? false,
                                              sameSite: [0: "none", 1: "lax", 2: "strict"][sameSite])
                    }
                }
            }
        }
        if kinds.contains(.tabs) {
            result.attempt(.tabs) { bundle in
                let candidates = ["sessionstore-backups/recovery.jsonlz4", "sessionstore.jsonlz4"].map { dir.appendingPathComponent($0) }
                guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                    throw ImportError.missingFile("sessionstore")
                }
                let json = try mozLz4(Data(contentsOf: url))
                let session = try JSONSerialization.jsonObject(with: json) as? [String: Any]
                let windows = session?["windows"] as? [[String: Any]] ?? []
                // Zen lists its workspaces in each window's `spaces` and tags each tab with `zenWorkspace`; Firefox has neither.
                // A repeated name gets a number, the same one each time, so two spaces never merge on a rerun.
                var spaceIndex: [String: Int] = [:]
                var names: [String: Int] = [:]
                for space in windows.flatMap({ $0["spaces"] as? [[String: Any]] ?? [] }) {
                    guard let uuid = space["uuid"] as? String, spaceIndex[uuid] == nil else { continue }
                    let title = space["name"] as? String ?? "Zen"
                    let count = names[title, default: 0] + 1
                    names[title] = count
                    // An icon is an emoji, or the path of one of Zen's own SVGs, which Lilo cannot show.
                    let icon = (space["icon"] as? String).flatMap { $0.isEmpty || $0.hasSuffix(".svg") ? nil : $0 }
                    // The theme's primary dot, `c` being [r, g, b] unless the color is a custom CSS string.
                    let colors = (space["theme"] as? [String: Any])?["gradientColors"] as? [[String: Any]] ?? []
                    let rgb = (colors.first { $0["isPrimary"] as? Bool == true } ?? colors.first)?["c"] as? [Int]
                    let color = rgb.flatMap { $0.count == 3 ? "#" + $0.map { unsafe String(format: "%02x", min(max($0, 0), 255)) }.joined() : nil }
                    spaceIndex[uuid] = bundle.spaces.count
                    bundle.spaces.append(ImportedSpace(name: count == 1 ? title : "\(title) \(count)", icon: icon, color: color, pinned: [], unpinned: []))
                }
                for tab in windows.flatMap({ $0["tabs"] as? [[String: Any]] ?? [] }) {
                    let pinned = tab["pinned"] as? Bool ?? false
                    let entries = tab["entries"] as? [[String: Any]] ?? []
                    let index = min(max((tab["index"] as? Int ?? entries.count) - 1, 0), max(entries.count - 1, 0))
                    var entry = entries.indices.contains(index) ? entries[index] : nil
                    // A Zen pin keeps the page it was pinned on, which it returns to, apart from where it was browsed since.
                    if pinned, let initial = (tab["_zenPinnedInitialState"] as? [String: Any])?["entry"] as? [String: Any] { entry = initial }
                    guard let url = entry?["url"] as? String, url.hasPrefix("http") else { continue }
                    let item = ImportedBookmark(title: tab["zenStaticLabel"] as? String ?? entry?["title"] as? String ?? "", url: url)
                    if tab["zenEssential"] as? Bool == true {
                        bundle.favorites.append(item)
                    } else if let space = (tab["zenWorkspace"] as? String).flatMap({ spaceIndex[$0] }) {
                        if pinned { bundle.spaces[space].pinned.append(item) } else { bundle.spaces[space].unpinned.append(item) }
                    } else if pinned {
                        bundle.pinnedTabs.append(item)
                    } else {
                        bundle.openTabs.append(item)
                    }
                }
            }
        }
        let hosts = ImportFiles.hosts(in: result.bundle.bookmarksBar + result.bundle.otherBookmarks + result.bundle.pinnedTabs + result.bundle.openTabs
            + result.bundle.favorites + result.bundle.spaces.flatMap { $0.pinned + $0.unpinned })
        if !hosts.isEmpty {
            result.bundle.favicons = (try? favicons(dir: dir, hosts: hosts)) ?? []
        }
        return result
    }

    /// "mozLz40\0", little-endian decompressed size, then one raw LZ4 block.
    private static func mozLz4(_ data: Data) throws -> Data {
        guard data.count > 12, data.prefix(8) == Data("mozLz40\0".utf8) else { throw ImportError.malformed("jsonlz4") }
        let size = data[8..<12].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        // A session is a few MB at most; a zero or absurd size means a corrupt file.
        guard size > 0, size <= 256 * 1024 * 1024 else { throw ImportError.malformed("jsonlz4") }
        var output = Data(count: size)
        let written = unsafe output.withUnsafeMutableBytes { out in
            unsafe data.dropFirst(12).withUnsafeBytes { input in
                guard let destination = unsafe out.bindMemory(to: UInt8.self).baseAddress,
                      let source = unsafe input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return unsafe compression_decode_buffer(destination, size, source, input.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        guard written == size else { throw ImportError.malformed("jsonlz4") }
        return output
    }

    private static func favicons(dir: URL, hosts: Set<String>) throws -> [FaviconStore.Entry] {
        try ImportFiles.withCopy(dir.appendingPathComponent("favicons.sqlite")) { db in
            var entries: [String: FaviconStore.Entry] = [:]
            let rows = try Row.fetchCursor(db, sql: """
                SELECT p.page_url, i.data FROM moz_pages_w_icons p
                JOIN moz_icons_to_pages ip ON ip.page_id = p.id JOIN moz_icons i ON i.id = ip.icon_id
                WHERE i.width <= 64 ORDER BY i.width DESC
                """)
            while let row = try rows.next(), entries.count < FaviconStore.maxRows {
                guard let host = URL(string: row["page_url"])?.host?.lowercased(), hosts.contains(host), entries[host] == nil,
                      let data: Data = row["data"] else { continue }
                let mime = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : (data.starts(with: [UInt8]("<svg".utf8)) ? "image/svg+xml" : nil)
                guard let mime else { continue }
                entries[host] = FaviconStore.Entry(host: host, dataURL: "data:\(mime);base64,\(data.base64EncodedString())", dominantColor: nil)
            }
            return Array(entries.values)
        }
    }
}
