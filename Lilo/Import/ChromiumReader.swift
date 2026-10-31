import Foundation
import GRDB

enum ChromiumReader {
    /// `arc` is Arc's sidebar file and the ids of every scanned Arc profile.
    static func read(profile: ImportProfile, kinds: Set<ImportKind>, arc: (sidebar: URL, profiles: [String])?,
                     password: () throws -> String) -> ImportReadResult {
        var result = ImportReadResult()
        let dir = profile.url
        if kinds.contains(.bookmarks) {
            result.attempt(.bookmarks) { bundle in
                let data = try Data(contentsOf: dir.appendingPathComponent("Bookmarks"))
                guard let roots = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["roots"] as? [String: Any] else {
                    throw ImportError.malformed("Bookmarks")
                }
                bundle.bookmarksBar = children(of: roots["bookmark_bar"])
                bundle.otherBookmarks = children(of: roots["other"]) + children(of: roots["synced"])
            }
        }
        if kinds.contains(.tabs) {
            result.attempt(.tabs) { bundle in
                if let arc {
                    let arc = try ArcSidebar.parse(Data(contentsOf: arc.sidebar), profile: profile.id, profiles: arc.profiles)
                    bundle.favorites = arc.favorites
                    bundle.spaces = arc.spaces
                } else {
                    guard let url = ChromiumSession.file(in: dir) else { throw ImportError.missingFile("Sessions") }
                    (bundle.pinnedTabs, bundle.openTabs) = try ChromiumSession.parse(Data(contentsOf: url))
                }
            }
        }
        if kinds.contains(.history) {
            result.attempt(.history) { bundle in
                bundle.history = try ImportFiles.withCopy(dir.appendingPathComponent("History")) { db in
                    try Row.fetchAll(db, sql: """
                        SELECT url, title, visit_count, last_visit_time FROM urls
                        WHERE hidden = 0 AND (url LIKE 'http://%' OR url LIKE 'https://%')
                        ORDER BY last_visit_time DESC LIMIT ?
                        """, arguments: [HistoryStore.maxRows]).map {
                        ImportedVisit(url: $0["url"], title: $0["title"] ?? "", visitCount: $0["visit_count"],
                                      lastVisitedAt: ImportFiles.chromiumDate($0["last_visit_time"]))
                    }
                }
            }
        }
        if kinds.contains(.cookies) {
            result.attempt(.cookies) { bundle in
                let network = dir.appendingPathComponent("Network/Cookies")
                let url = FileManager.default.fileExists(atPath: network.path) ? network : dir.appendingPathComponent("Cookies")
                let decryptor = ChromiumCookieDecryptor(password: try password())
                // A key that opens no encrypted cookie at all is the wrong key, not a few bad rows.
                var encryptedCount = 0, undecryptedCount = 0
                bundle.cookies = try ImportFiles.withCopy(url) { db in
                    let version = Int(try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'version'") ?? "0") ?? 0
                    // A partitioned (CHIPS) cookie would land as a first-party one, possibly over the site's own cookie of the same
                    // name. Profiles from before CHIPS have no partition column.
                    let partitioned = try db.columns(in: "cookies").contains { $0.name == "top_frame_site_key" }
                    return try Row.fetchAll(db, sql: """
                        SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite FROM cookies
                        """ + (partitioned ? " WHERE top_frame_site_key = ''" : "")).compactMap { row -> ImportedCookie? in
                        let host: String = row["host_key"]
                        let plain: String = row["value"] ?? ""
                        let encrypted: Data = row["encrypted_value"] ?? Data()
                        let value = plain.isEmpty ? (try? decryptor.decrypt(encrypted, hostKey: host, stripsDomainHash: version >= 24)) : plain
                        if plain.isEmpty { encryptedCount += 1 }
                        guard let value else {
                            undecryptedCount += 1
                            return nil
                        }
                        let expires: Int64 = row["expires_utc"]
                        let sameSite: Int = row["samesite"]
                        return ImportedCookie(domain: host, name: row["name"], value: value, path: row["path"],
                                              expires: expires == 0 ? nil : ImportFiles.chromiumDate(expires),
                                              isSecure: row["is_secure"], isHTTPOnly: row["is_httponly"],
                                              sameSite: [0: "none", 1: "lax", 2: "strict"][sameSite])
                    }
                }
                if encryptedCount > 0, undecryptedCount == encryptedCount { throw ImportError.decryption }
            }
        }
        if kinds.contains(.extensions) {
            result.attempt(.extensions) { bundle in
                bundle.extensions = extensions(in: dir)
                // Toolbar order; a profile that never pinned one has no Preferences entry.
                let preferences = (try? Data(contentsOf: dir.appendingPathComponent("Preferences")))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                bundle.pinnedExtensionIds = (preferences?["extensions"] as? [String: Any])?["pinned_extensions"] as? [String] ?? []
            }
        }
        let hosts = ImportFiles.hosts(in: result.bundle.bookmarksBar + result.bundle.otherBookmarks + result.bundle.pinnedTabs + result.bundle.openTabs
            + result.bundle.favorites + result.bundle.spaces.flatMap { $0.pinned + $0.unpinned })
        if !hosts.isEmpty {
            result.bundle.favicons = (try? favicons(dir: dir, hosts: hosts)) ?? []
        }
        return result
    }

    /// Web Store extensions only (their manifest keeps Google's update URL): those are the ones
    /// Lilo can reinstall by ID.
    static func extensions(in profileURL: URL) -> [ImportedExtension] {
        let fm = FileManager.default
        let root = profileURL.appendingPathComponent("Extensions")
        let ids = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        return ids.sorted().compactMap { id -> ImportedExtension? in
            guard id.count == 32, id.allSatisfy({ ("a"..."p").contains($0) }) else { return nil }
            // Numeric order: "10.0_0" is newer than "9.0_0".
            let versions = (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(id).path)) ?? []
            guard let version = versions.max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) else { return nil }
            let dir = root.appendingPathComponent(id).appendingPathComponent(version)
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (manifest["update_url"] as? String)?.contains("clients2.google.com") == true,
                  var name = manifest["name"] as? String else { return nil }
            if name.hasPrefix("__MSG_"), name.hasSuffix("__") {
                let key = String(name.dropFirst(6).dropLast(2))
                let locale = manifest["default_locale"] as? String ?? "en"
                let messagesURL = dir.appendingPathComponent("_locales/\(locale)/messages.json")
                if let messagesData = try? Data(contentsOf: messagesURL),
                   let messages = try? JSONSerialization.jsonObject(with: messagesData) as? [String: [String: Any]],
                   let entry = messages.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value,
                   let message = entry["message"] as? String {
                    name = message
                }
            }
            return ImportedExtension(id: id, name: name)
        }
    }

    private static func children(of node: Any?) -> [ImportedBookmark] {
        guard let items = (node as? [String: Any])?["children"] as? [[String: Any]] else { return [] }
        return items.compactMap { child -> ImportedBookmark? in
            let title = child["name"] as? String ?? ""
            switch child["type"] as? String {
            case "url":
                guard let url = child["url"] as? String, url.hasPrefix("http") else { return nil }
                return ImportedBookmark(title: title, url: url)
            case "folder":
                return ImportedBookmark(title: title, url: nil, children: children(of: child))
            default:
                return nil
            }
        }
    }

    private static func favicons(dir: URL, hosts: Set<String>) throws -> [FaviconStore.Entry] {
        try ImportFiles.withCopy(dir.appendingPathComponent("Favicons")) { db in
            var entries: [String: FaviconStore.Entry] = [:]
            let rows = try Row.fetchCursor(db, sql: """
                SELECT m.page_url, b.image_data FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id = m.icon_id
                WHERE b.width <= 64 ORDER BY b.width DESC
                """)
            while let row = try rows.next(), entries.count < FaviconStore.maxRows {
                guard let host = URL(string: row["page_url"])?.host?.lowercased(), hosts.contains(host), entries[host] == nil,
                      let png: Data = row["image_data"] else { continue }
                entries[host] = FaviconStore.Entry(host: host, dataURL: "data:image/png;base64," + png.base64EncodedString(), dominantColor: nil)
            }
            return Array(entries.values)
        }
    }
}

enum ArcSidebar {
    /// The spaces and favorites `profile` owns. Arc names a profile by its directory under
    /// `User Data`; one matching no scanned profile falls to the first of `profiles`.
    static func parse(_ data: Data, profile: String, profiles: [String]) throws -> (favorites: [ImportedBookmark], spaces: [ImportedSpace]) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let containers = (root["sidebar"] as? [String: Any])?["containers"] as? [Any],
              let main = containers.compactMap({ $0 as? [String: Any] }).first(where: { $0["spaces"] != nil }) else {
            throw ImportError.malformed("StorableSidebar.json")
        }
        let items = Dictionary(
            (main["items"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.compactMap { item in
                (item["id"] as? String).map { ($0, item) }
            },
            uniquingKeysWith: { first, _ in first })

        // Depth-capped so a corrupt childrenIds cycle cannot recurse forever.
        func node(_ id: String, depth: Int) -> ImportedBookmark? {
            guard depth < 32, let item = items[id], let data = item["data"] as? [String: Any] else { return nil }
            if let tab = data["tab"] as? [String: Any] {
                guard let url = tab["savedURL"] as? String, url.hasPrefix("http") else { return nil }
                return ImportedBookmark(title: item["title"] as? String ?? tab["savedTitle"] as? String ?? "", url: url)
            }
            if data["list"] != nil {
                return ImportedBookmark(title: item["title"] as? String ?? "", url: nil, children: children(id, depth: depth + 1))
            }
            if let split = data["splitView"] as? [String: Any] {
                return ImportedBookmark(title: "", url: nil, children: children(id, depth: depth + 1),
                                        splitVertical: split["layoutOrientation"] as? String == "vertical")
            }
            return nil
        }
        func children(_ id: String, depth: Int = 0) -> [ImportedBookmark] {
            (items[id]?["childrenIds"] as? [String] ?? []).compactMap { node($0, depth: depth) }
        }
        // `{"default": true}` or `{"custom": {"_0": {"directoryBasename": "Profile 1", ...}}}`.
        func owns(_ key: Any?) -> Bool {
            let owner = (((key as? [String: Any])?["custom"] as? [String: Any])?["_0"] as? [String: Any])?["directoryBasename"] as? String ?? "Default"
            return owner == profile || (!profiles.contains(owner) && profile == profiles.first)
        }

        // Profile keys and container ids alternate: each container belongs to the key before it.
        var favoritesOwner: Any?
        var favorites: [ImportedBookmark] = []
        for entry in main["topAppsContainerIDs"] as? [Any] ?? [] {
            if let id = entry as? String {
                if owns(favoritesOwner) { favorites += children(id) }
            } else {
                favoritesOwner = entry
            }
        }
        // Spaces are matched by name on a rerun: a repeated name gets a number, the same one each time, so two spaces never merge.
        var names: [String: Int] = [:]
        let spaces = (main["spaces"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.filter { owns($0["profile"]) }.map { space in
            let ids = space["containerIDs"] as? [String] ?? []
            func container(_ label: String) -> [ImportedBookmark] {
                guard let index = ids.firstIndex(of: label), index + 1 < ids.count else { return [] }
                return children(ids[index + 1])
            }
            let info = space["customInfo"] as? [String: Any]
            let iconType = info?["iconType"] as? [String: Any]
            // Older files keep only the emoji's code point.
            let icon = iconType?["emoji_v2"] as? String ?? (iconType?["emoji"] as? Int).flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
            let tone = ((info?["windowTheme"] as? [String: Any])?["primaryColorPalette"] as? [String: Any])?["midTone"] as? [String: Any]
            var color: String?
            if let red = tone?["red"] as? Double, let green = tone?["green"] as? Double, let blue = tone?["blue"] as? Double {
                // Extended sRGB components can leave 0...1.
                color = String(format: "#%02x%02x%02x", Int(min(max(red, 0), 1) * 255), Int(min(max(green, 0), 1) * 255), Int(min(max(blue, 0), 1) * 255))
            }
            let title = space["title"] as? String ?? "Arc"
            names[title, default: 0] += 1
            return ImportedSpace(name: names[title] == 1 ? title : "\(title) \(names[title]!)", icon: icon, color: color,
                                 pinned: container("pinned"), unpinned: container("unpinned"))
        }
        return (favorites, spaces)
    }
}
