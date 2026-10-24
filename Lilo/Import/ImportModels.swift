import Foundation
import GRDB

enum ImportKind: String, CaseIterable, Sendable, Codable {
    case bookmarks, tabs, history, cookies, extensions
}

/// A bookmark or a folder (`url == nil`).
struct ImportedBookmark: Sendable, Equatable {
    var title: String
    var url: String?
    var children: [ImportedBookmark] = []
    /// Set on an Arc split view, whose children are its panes: stacked when true.
    var splitVertical: Bool?
    /// A folder's "#rrggbb" (a Chromium tab group's color).
    var color: String?
}

struct ImportedSpace: Sendable, Equatable {
    var name: String
    var icon: String?
    /// "#rrggbb".
    var color: String?
    var pinned: [ImportedBookmark]
    var unpinned: [ImportedBookmark]
}

struct ImportedVisit: Sendable, Equatable {
    var url: String
    var title: String
    var visitCount: Int
    var lastVisitedAt: Date
}

struct ImportedCookie: Sendable, Equatable {
    var domain: String
    var name: String
    var value: String
    var path: String
    /// Nil for a session cookie.
    var expires: Date?
    var isSecure: Bool
    var isHTTPOnly: Bool
    /// "lax", "strict", "none" or nil when unspecified.
    var sameSite: String?
}

struct ImportedExtension: Sendable, Equatable, Hashable, Codable {
    var id: String
    var name: String
}

struct ImportBundle: Sendable {
    /// Bookmarks bar, imported as pinned items of the target space.
    var bookmarksBar: [ImportedBookmark] = []
    /// Every other bookmark root, imported as one collapsed pinned folder.
    var otherBookmarks: [ImportedBookmark] = []
    /// Arc favorites, imported into the bookmarked section.
    var favorites: [ImportedBookmark] = []
    /// Arc spaces, each imported as a new Lilo space.
    var spaces: [ImportedSpace] = []
    /// Last session's open tabs (Safari, Firefox, Chromium), imported as unpinned tabs; Chromium tab groups are folders.
    var openTabs: [ImportedBookmark] = []
    /// Last session's pinned tabs (Chromium), imported as pinned tabs.
    var pinnedTabs: [ImportedBookmark] = []
    var history: [ImportedVisit] = []
    var cookies: [ImportedCookie] = []
    var extensions: [ImportedExtension] = []
    var favicons: [FaviconStore.Entry] = []
}

struct ImportReadResult: Sendable {
    var bundle = ImportBundle()
    var errors: [ImportKind: String] = [:]

    /// Runs one kind's read; a failure is recorded for that kind and never stops the others.
    mutating func attempt(_ kind: ImportKind, _ body: (inout ImportBundle) throws -> Void) {
        do { try body(&bundle) } catch { errors[kind] = String(describing: error) }
    }
}

struct ImportProfile: Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var url: URL
    var kinds: [ImportKind]
    var extensions: [ImportedExtension]
}

struct ImportSource: Sendable, Equatable, Identifiable {
    enum Family: String, Sendable { case chromium, safari, firefox }

    var id: String
    var name: String
    var family: Family
    var bundleId: String
    var rootURL: URL
    /// Chromium only: the Keychain service holding the cookie encryption password.
    var keychainService: String?
    var needsFullDiskAccess: Bool
    var profiles: [ImportProfile]
}

enum ImportError: Error, Equatable {
    case missingFile(String)
    case malformed(String)
    case keychain(OSStatus)
    case decryption
}

enum ImportFiles {
    /// Opens a copy of a SQLite database (with its WAL and SHM sidecars, so rows a running
    /// browser has not checkpointed yet are included); the copy is deleted afterwards.
    static func withCopy<T>(_ url: URL, _ body: (Database) throws -> T) throws -> T {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw ImportError.missingFile(url.lastPathComponent) }
        let dir = fm.temporaryDirectory.appendingPathComponent("LiloImport-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let copy = dir.appendingPathComponent(url.lastPathComponent)
        try fm.copyItem(at: url, to: copy)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if fm.fileExists(atPath: sidecar.path) {
                try fm.copyItem(at: sidecar, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }
        let queue = try DatabaseQueue(path: copy.path)
        return try queue.read(body)
    }

    /// Hosts of every bookmark in a tree, to fetch favicons only for sites the import brings in.
    static func hosts(in bookmarks: [ImportedBookmark]) -> Set<String> {
        var hosts = Set<String>()
        func walk(_ items: [ImportedBookmark]) {
            for item in items {
                if let host = item.url.flatMap({ URL(string: $0)?.host?.lowercased() }) { hosts.insert(host) }
                walk(item.children)
            }
        }
        walk(bookmarks)
        return hosts
    }

    /// Chromium timestamps: microseconds since 1601-01-01.
    static func chromiumDate(_ micros: Int64) -> Date {
        Date(timeIntervalSince1970: Double(micros) / 1_000_000 - 11_644_473_600)
    }
}
