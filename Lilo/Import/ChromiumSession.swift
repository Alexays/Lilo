import Foundation

/// The open tabs of a Chromium profile's last session, replayed from its SNSS command log.
enum ChromiumSession {
    /// The newest `Sessions/Session_<time>`, or the profile root's `Current Session`/`Last Session` of older versions.
    static func file(in profile: URL) -> URL? {
        let sessions = profile.appendingPathComponent("Sessions")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
        if let newest = names.compactMap({ name in name.hasPrefix("Session_") ? Int64(name.dropFirst(8)).map { ($0, name) } : nil }).max(by: { $0.0 < $1.0 }) {
            return sessions.appendingPathComponent(newest.1)
        }
        return ["Current Session", "Last Session"].map { profile.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// "SNSS", an int32 version, then `[uint16 size][uint8 id][payload]` records. Struct payloads are
    /// little-endian; navigations and group metadata are Pickles (4-byte aligned, length-prefixed strings).
    /// A truncated tail (a browser mid-write) ends the replay with what was read.
    static func parse(_ data: Data) throws -> (pinned: [ImportedBookmark], open: [ImportedBookmark]) {
        let bytes = [UInt8](data)
        func int(_ at: Int, _ end: Int) -> Int? {
            guard at >= 0, at + 4 <= end else { return nil }
            return Int(Int32(bitPattern: UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24))
        }
        func uint64(_ at: Int, _ end: Int) -> UInt64? {
            guard at + 8 <= end else { return nil }
            return (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[at + $1]) << (8 * UInt64($1)) }
        }
        /// A Pickle string at `at`: its value and the aligned offset after it. UTF-16 lengths count code units.
        func string(_ at: Int, _ end: Int, utf16: Bool) -> (String, Int)? {
            guard let count = int(at, end), count >= 0 else { return nil }
            let start = at + 4, length = utf16 ? count * 2 : count
            guard start + length <= end else { return nil }
            let value = utf16
                ? String(decoding: stride(from: start, to: start + length, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }, as: UTF16.self)
                : String(bytes: bytes[start..<start + length], encoding: .utf8) ?? ""
            return (value, start + (length + 3) & ~3)
        }

        guard bytes.count >= 8, bytes.starts(with: [UInt8]("SNSS".utf8)), let version = int(4, bytes.count), [1, 3].contains(version) else {
            throw ImportError.malformed("Session")
        }
        struct Group: Hashable { var high: UInt64, low: UInt64 }
        struct Tab {
            var window: Int?
            var index = 0
            var navigations: [Int: (url: String, title: String)] = [:]
            var selected = 0
            var pinned = false
            var group: Group?
        }
        var tabs: [Int: Tab] = [:]
        var windowOrder: [Int] = []
        var windowTypes: [Int: Int] = [:]
        var closedWindows = Set<Int>()
        var groups: [Group: (title: String, color: Int)] = [:]
        func window(_ id: Int) {
            if windowTypes[id] == nil { windowTypes[id] = 0; windowOrder.append(id) }
        }

        var offset = 8
        while offset + 2 <= bytes.count {
            let size = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            let start = offset + 3, end = offset + 2 + size
            guard size > 0, end <= bytes.count else { break }
            offset = end
            // Every struct payload starts with the tab or window id.
            guard let id = int(start, end) else { continue }
            let value = int(start + 4, end)
            switch bytes[start - 1] {
            case 0: // SetTabWindow: window id, tab id.
                guard let tab = value else { continue }
                window(id)
                tabs[tab, default: Tab()].window = id
            case 2: tabs[id, default: Tab()].index = value ?? 0 // SetTabIndexInWindow
            case 5: // TabNavigationPathPrunedFromBack: entries from `count` on go.
                guard let count = value, var tab = tabs[id] else { continue }
                tab.navigations = tab.navigations.filter { $0.key < count }
                tabs[id] = tab
            case 6: // UpdateTabNavigation: a Pickle of tab id, entry index, URL, UTF-16 title, then fields not read.
                guard let tab = int(start + 4, end), let index = int(start + 8, end),
                      let (url, next) = string(start + 12, end, utf16: false) else { continue }
                tabs[tab, default: Tab()].navigations[index] = (url, string(next, end, utf16: true)?.0 ?? "")
            case 7: tabs[id, default: Tab()].selected = value ?? 0 // SetSelectedNavigationIndex
            case 8, 14: window(id) // SetSelectedTabInIndex, SetWindowBounds3
            case 9: // SetWindowType: only normal windows (0) are imported.
                window(id)
                windowTypes[id] = value ?? 0
            case 11: // TabNavigationPathPrunedFromFront: the first `count` entries go, the rest shift down.
                guard let count = value, var tab = tabs[id] else { continue }
                tab.navigations = Dictionary(uniqueKeysWithValues: tab.navigations.filter { $0.key >= count }.map { ($0.key - count, $0.value) })
                tab.selected = max(tab.selected - count, 0)
                tabs[id] = tab
            case 12: tabs[id, default: Tab()].pinned = start + 4 < end && bytes[start + 4] != 0 // SetPinnedState
            case 16: tabs[id] = nil // TabClosed
            case 17: closedWindows.insert(id) // WindowClosed
            case 24: // TabNavigationPathPruned: `count` entries from `index` go, the later ones shift down.
                guard let index = value, let count = int(start + 8, end), var tab = tabs[id] else { continue }
                tab.navigations = Dictionary(uniqueKeysWithValues: tab.navigations.compactMap { key, entry in
                    key < index ? (key, entry) : key >= index + count ? (key - count, entry) : nil
                })
                if tab.selected >= index + count { tab.selected -= count } else if tab.selected >= index { tab.selected = index }
                tabs[id] = tab
            case 25: // SetTabGroup: tab id, padding, token high and low, has-group flag.
                guard let high = uint64(start + 8, end), let low = uint64(start + 16, end) else { continue }
                tabs[id, default: Tab()].group = start + 24 < end && bytes[start + 24] != 0 ? Group(high: high, low: low) : nil
            case 27: // SetTabGroupMetadata2: a Pickle of token high and low, UTF-16 title, color.
                guard let high = uint64(start + 4, end), let low = uint64(start + 12, end),
                      let (title, next) = string(start + 20, end, utf16: true) else { continue }
                groups[Group(high: high, low: low)] = (title, int(next, end) ?? 0)
            default: continue
            }
        }

        // Chromium's TabGroupColorId order, onto Lilo's folder palette: grey, blue, red, yellow, green, pink, purple, cyan, orange.
        let colors = ["#8a9ba8", "#5b7cff", "#ff8a5b", "#ffcc57", "#5fd79a", "#f06aa6", "#9b7cff", "#4ecdc4", "#ff8a5b"]
        let windowIndex = Dictionary(uniqueKeysWithValues: windowOrder.enumerated().map { ($1, $0) })
        var pinned: [ImportedBookmark] = [], open: [ImportedBookmark] = []
        var folders: [Group: Int] = [:]
        let live = tabs.values.compactMap { tab -> (Int, Tab)? in
            guard let window = tab.window, windowTypes[window] == 0, !closedWindows.contains(window), let order = windowIndex[window] else { return nil }
            return (order, tab)
        }
        for (_, tab) in live.sorted(by: { ($0.0, $0.1.index) < ($1.0, $1.1.index) }) {
            // The selected entry, else the nearest one before it (pruning can leave a gap), else the last.
            guard let entry = tab.navigations[tab.selected] ?? tab.navigations.filter({ $0.key < tab.selected }).max(by: { $0.key < $1.key })?.value
                    ?? tab.navigations.max(by: { $0.key < $1.key })?.value,
                  ["http://", "https://", "file://"].contains(where: { entry.url.hasPrefix($0) }) else { continue }
            let bookmark = ImportedBookmark(title: entry.title, url: entry.url)
            if tab.pinned {
                pinned.append(bookmark)
            } else if let group = tab.group {
                if let folder = folders[group] {
                    open[folder].children.append(bookmark)
                } else {
                    folders[group] = open.count
                    let metadata = groups[group]
                    open.append(ImportedBookmark(title: metadata?.title ?? "", url: nil, children: [bookmark],
                                                 color: colors[min(max(metadata?.color ?? 0, 0), colors.count - 1)]))
                }
            } else {
                open.append(bookmark)
            }
        }
        return (pinned, open)
    }
}
