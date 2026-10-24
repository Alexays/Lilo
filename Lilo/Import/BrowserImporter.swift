import Foundation
import WebKit

/// Writes what the readers found into Lilo. The first selected profile lands in the active Lilo
/// profile and space; each further profile gets its own Lilo profile and space so sessions stay apart.
@MainActor
final class BrowserImporter {
    struct Selection: Sendable, Equatable {
        var sourceId: String
        var profileId: String
        var kinds: Set<ImportKind>
        var extensionIds: [String]
    }

    /// Sent as each kind of each profile starts, and as each extension install starts: `total` is 0 when the size is unknown.
    struct Progress: Sendable {
        var sourceId: String
        var profileId: String
        var kind: ImportKind
        var done: Int
        var total: Int
    }

    struct SummaryItem: Sendable, Equatable {
        var sourceId: String
        var profileId: String
        var kind: ImportKind
        var imported: Int
        var skipped: Int
        var error: String?
    }

    struct Sink {
        var activeProfileId: () -> UUID?
        var activeSpaceId: () -> UUID?
        var tree: (UUID) -> StoredSidebarTree?
        var apply: (BrowserCommand) throws -> Void
        var findProfile: (_ name: String) -> UUID?
        var createProfile: (String) throws -> UUID
        var findSpace: (_ name: String, _ profileId: UUID) -> UUID?
        var createSpace: (_ name: String, _ icon: String, _ color: String?, _ profileId: UUID) throws -> UUID
        var loadSpaceState: (_ spaceId: UUID, _ profileId: UUID) -> SpaceTabState?
        /// Saves the trees of unloaded spaces of one profile in one transaction.
        var saveSpaceStates: (_ states: [(spaceId: UUID, state: SpaceTabState)], _ profileId: UUID) throws -> Void
        var historyStore: (UUID) throws -> HistoryStore
        var faviconStore: (UUID) throws -> FaviconStore
        var setCookies: (_ cookies: [HTTPCookie], _ profileId: UUID) async -> Void
        var installExtension: (_ id: String, _ profileId: UUID) async throws -> Void
        /// The address bar's pins, and setting them.
        var pinnedExtensions: () -> [String]
        var pinExtensions: (_ ids: [String]) async -> Void
        var otherBookmarksTitle: (_ sourceName: String) -> String
        /// Puts imported favicons in the live cache so the sidebar shows them right away.
        var warmFavicons: ([FaviconStore.Entry]) -> Void
    }

    private let sink: Sink
    private let home: URL

    init(sink: Sink, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.sink = sink
        self.home = home
    }

    func run(_ selections: [Selection], sources: [ImportSource], progress: @escaping @MainActor (Progress) -> Void) async -> [SummaryItem] {
        var summary: [SummaryItem] = []
        // The first selection still found goes to the active space, even when one before it vanished since the scan.
        var isFirst = true
        for selection in selections {
            guard let source = sources.first(where: { $0.id == selection.sourceId }),
                  let profile = source.profiles.first(where: { $0.id == selection.profileId }) else { continue }
            defer { isFirst = false }
            let home = self.home
            let kinds = selection.kinds
            func start(_ kind: ImportKind, done: Int = 0, total: Int = 0) {
                progress(Progress(sourceId: source.id, profileId: profile.id, kind: kind, done: done, total: total))
            }
            // Reading every file comes first and takes long on a big profile: it counts toward the first kind.
            if let first = ImportKind.allCases.first(where: kinds.contains) { start(first) }
            let read = await Task.detached(priority: .userInitiated) {
                Self.read(source: source, profile: profile, kinds: kinds, home: home)
            }.value
            func item(_ kind: ImportKind, imported: Int, skipped: Int = 0, error: String? = nil) {
                summary.append(SummaryItem(sourceId: source.id, profileId: profile.id, kind: kind, imported: imported, skipped: skipped,
                                           error: error ?? read.errors[kind]))
            }

            let lilo: (profileId: UUID, spaceId: UUID)
            do {
                if isFirst, let profileId = sink.activeProfileId(), let spaceId = sink.activeSpaceId() {
                    lilo = (profileId, spaceId)
                } else {
                    // Reusing what an earlier import created keeps a second import from duplicating it.
                    let profileName = "\(source.name) \(profile.name)"
                    let profileId = try sink.findProfile(profileName) ?? sink.createProfile(profileName)
                    lilo = (profileId, try sink.findSpace(profile.name, profileId) ?? sink.createSpace(profile.name, "🌐", nil, profileId))
                }
            } catch {
                for kind in kinds.sorted(by: { $0.rawValue < $1.rawValue }) { item(kind, imported: 0, error: String(describing: error)) }
                continue
            }
            let bundle = read.bundle

            if kinds.contains(.bookmarks) || kinds.contains(.tabs) {
                do {
                    let others = ImportedBookmark(title: sink.otherBookmarksTitle(source.name), url: nil, children: bundle.otherBookmarks)
                    // The bookmarked section holds tabs only: favorite folders are flattened.
                    let icons = Dictionary(bundle.favicons.map { ($0.host, $0.dataURL) }, uniquingKeysWith: { first, _ in first })
                    var targets = [Target(spaceId: lilo.spaceId, bookmarks: bundle.bookmarksBar + [others], pinned: bundle.pinnedTabs,
                                          unpinned: bundle.openTabs, bookmarked: Self.flattened(bundle.favorites), icons: icons)]
                    for space in bundle.spaces {
                        let spaceId = try sink.findSpace(space.name, lilo.profileId)
                            ?? sink.createSpace(space.name, space.icon ?? "🌐", space.color, lilo.profileId)
                        targets.append(Target(spaceId: spaceId, bookmarks: [], pinned: space.pinned, unpinned: space.unpinned, bookmarked: [], icons: icons))
                    }
                    for index in targets.indices {
                        targets[index].tree = sink.tree(targets[index].spaceId) ?? sink.loadSpaceState(targets[index].spaceId, lilo.profileId)?.tree
                    }
                    // Walking every known URL and building thousands of nodes stays off the main actor.
                    let built = await Task.detached(priority: .userInitiated) { [targets] in targets.map(Self.build) }.value
                    var saves: [(spaceId: UUID, state: SpaceTabState)] = []
                    for (target, nodes) in zip(targets, built) {
                        try put(target, nodes, profileId: lilo.profileId, saves: &saves)
                    }
                    if !saves.isEmpty { try sink.saveSpaceStates(saves, lilo.profileId) }
                    let tabs = built.reduce(0) { $0 + Self.count($1.pinned + $1.bookmarked + $1.unpinned) }
                    if kinds.contains(.bookmarks) { item(.bookmarks, imported: Self.count(built[0].bookmarks)) }
                    if kinds.contains(.tabs) { item(.tabs, imported: tabs) }
                } catch {
                    if kinds.contains(.bookmarks) { item(.bookmarks, imported: 0, error: String(describing: error)) }
                    if kinds.contains(.tabs) { item(.tabs, imported: 0, error: String(describing: error)) }
                }
                if !bundle.favicons.isEmpty {
                    (try? sink.faviconStore(lilo.profileId))?.importMissingAsync(bundle.favicons)
                    if lilo.profileId == sink.activeProfileId() { sink.warmFavicons(bundle.favicons) }
                }
            }

            if kinds.contains(.history) {
                start(.history)
                do {
                    let store = try sink.historyStore(lilo.profileId)
                    let visits = bundle.history
                    try await Task.detached(priority: .utility) { try store.importVisits(visits) }.value
                    item(.history, imported: visits.count)
                } catch {
                    item(.history, imported: 0, error: String(describing: error))
                }
            }

            if kinds.contains(.cookies) {
                start(.cookies)
                let imported = bundle.cookies
                let cookies = await Task.detached(priority: .userInitiated) { imported.compactMap(Self.httpCookie) }.value
                await sink.setCookies(cookies, lilo.profileId)
                item(.cookies, imported: cookies.count, skipped: bundle.cookies.count - cookies.count)
            }

            if kinds.contains(.extensions) {
                let wanted = bundle.extensions.filter { selection.extensionIds.contains($0.id) }
                var installed: Set<String> = []
                var lastError: String?
                for (index, ext) in wanted.enumerated() {
                    start(.extensions, done: index, total: wanted.count)
                    do { try await sink.installExtension(ext.id, lilo.profileId); installed.insert(ext.id) } catch { lastError = "\(ext.name): \(error)" }
                }
                // Lilo's own pins stay first; Chrome's follow, in toolbar order.
                let current = sink.pinnedExtensions()
                let pins = current + bundle.pinnedExtensionIds.filter { installed.contains($0) && !current.contains($0) }
                if pins.count > current.count { await sink.pinExtensions(pins) }
                item(.extensions, imported: installed.count, skipped: wanted.count - installed.count, error: lastError)
            }
        }
        return summary
    }

    /// A space loaded in the browser state changes through state commands (its live state would
    /// overwrite a direct save); an unloaded space gets its stored tree extended, saved with the others in one write.
    private func put(_ target: Target, _ nodes: BuiltNodes, profileId: UUID, saves: inout [(spaceId: UUID, state: SpaceTabState)]) throws {
        let spaceId = target.spaceId
        let pinned = nodes.bookmarks + nodes.pinned
        if sink.tree(spaceId) != nil {
            if !pinned.isEmpty { try sink.apply(.importSidebarNodes(spaceId: spaceId, nodes: pinned, section: .pinned)) }
            if !nodes.bookmarked.isEmpty { try sink.apply(.importSidebarNodes(spaceId: spaceId, nodes: nodes.bookmarked, section: .bookmarked)) }
            if !nodes.unpinned.isEmpty { try sink.apply(.importSidebarNodes(spaceId: spaceId, nodes: nodes.unpinned, section: .unpinned)) }
        } else if !(pinned.isEmpty && nodes.unpinned.isEmpty && nodes.bookmarked.isEmpty) || target.tree == nil {
            // Read again: the space may have been loaded and parked while the nodes were built.
            let existing = sink.loadSpaceState(spaceId, profileId)
            saves.append((spaceId, Self.state(merging: existing, pinned: pinned, unpinned: nodes.unpinned, bookmarked: nodes.bookmarked)))
        }
    }

    /// One Lilo space and what the import adds to it: bookmarks and pinned tabs both land in the pinned section.
    /// `tree` is its sidebar before the import, nil when it has none yet.
    private struct Target: Sendable {
        var spaceId: UUID
        var bookmarks: [ImportedBookmark]
        var pinned: [ImportedBookmark]
        var unpinned: [ImportedBookmark]
        var bookmarked: [ImportedBookmark]
        /// The source's favicons by host: an imported tab shows its site's icon before it ever loads.
        var icons: [String: String] = [:]
        var tree: StoredSidebarTree?
    }

    private typealias BuiltNodes = (bookmarks: [StoredSidebarNode], pinned: [StoredSidebarNode], unpinned: [StoredSidebarNode],
                                    bookmarked: [StoredSidebarNode])

    nonisolated private static func build(_ target: Target) -> BuiltNodes {
        var known = urls(in: target.tree)
        let bookmarks = nodes(target.bookmarks, known: &known, open: false, bookmarked: false, icons: target.icons)
        let pinned = nodes(target.pinned, known: &known, open: false, bookmarked: false, icons: target.icons)
        let bookmarked = nodes(target.bookmarked, known: &known, open: false, bookmarked: true, icons: target.icons)
        return (bookmarks, pinned, nodes(target.unpinned, known: &known, open: true, bookmarked: false, icons: target.icons), bookmarked)
    }

    nonisolated private static func read(source: ImportSource, profile: ImportProfile, kinds: Set<ImportKind>, home: URL) -> ImportReadResult {
        switch source.family {
        case .chromium:
            let arc = source.id == "arc" ? (BrowserImportScanner.arcSidebarURL(home: home), source.profiles.map(\.id)) : nil
            return ChromiumReader.read(profile: profile, kinds: kinds, arc: arc) {
                try ChromiumCookieDecryptor.keychainPassword(service: source.keychainService ?? "")
            }
        case .safari:
            return SafariReader.read(safariURL: source.rootURL, cookiesURL: BrowserImportScanner.safariCookiesURL(home: home), kinds: kinds)
        case .firefox:
            return FirefoxReader.read(profile: profile, kinds: kinds)
        }
    }

    /// Persistent tabs are created closed with their home URL, the rest open; none gets an engine before shown. Known URLs are dropped so a
    /// re-import adds nothing twice, nor a folder left empty. Folders keep their nesting down to `SpaceTab.maxFolderDepth`, deeper
    /// content joining the deepest folder; a split inside a folder becomes plain tabs. `depth` counts the enclosing folders.
    nonisolated private static func nodes(_ bookmarks: [ImportedBookmark], known: inout Set<String>, open: Bool, bookmarked: Bool,
                                          icons: [String: String], depth: Int = 0) -> [StoredSidebarNode] {
        func tab(_ url: String, _ title: String, closed: Bool) -> StoredSidebarNode {
            let title = title.isEmpty ? url : title
            let icon = (URL(string: url)?.host?.lowercased()).flatMap { icons[$0] }
            return .tab(StoredTab(id: UUID(), url: url, title: title, faviconDataURL: icon, faviconDominantColor: nil,
                                  isPinned: false, isBookmarked: bookmarked, isClosed: closed,
                                  homeURL: open ? nil : url, homeTitle: open ? nil : title,
                                  homeFaviconDataURL: open ? nil : icon, homeFaviconDominantColor: nil))
        }
        var result: [StoredSidebarNode] = []
        for bookmark in bookmarks {
            if let url = bookmark.url {
                if known.insert(url).inserted { result.append(tab(url, bookmark.title, closed: !open)) }
            } else if let vertical = bookmark.splitVertical {
                guard depth == 0 else {
                    result += nodes(bookmark.children, known: &known, open: open, bookmarked: bookmarked, icons: icons, depth: depth)
                    continue
                }
                let panes = flattened(bookmark.children).compactMap { pane in
                    pane.url.flatMap { known.insert($0).inserted ? tab($0, pane.title, closed: false) : nil }
                }
                guard panes.count >= 2 else { result += panes; continue }
                let ids = panes.prefix(SplitLayout.maxPanes).map(\.id)
                let layout = ids.dropFirst().reduce(SplitLayout.pane(tabId: ids[0])) { layout, id in
                    layout.inserting(id, at: layout.paneIds[layout.paneIds.count - 1], vertical: vertical, before: false)
                }
                result.append(.folder(StoredFolder(id: UUID(), name: "", color: "#5865f2", isCollapsed: false,
                                                   children: Array(panes.prefix(ids.count)), splitLayout: layout)))
                result += panes.dropFirst(ids.count)
            } else {
                let inner = nodes(bookmark.children, known: &known, open: open, bookmarked: bookmarked, icons: icons, depth: depth + 1)
                if depth >= SpaceTab.maxFolderDepth {
                    result += inner
                } else if !inner.isEmpty {
                    result.append(.folder(StoredFolder(id: UUID(), name: bookmark.title, color: bookmark.color ?? "#6d5ae6", isCollapsed: true, children: inner)))
                }
            }
        }
        return result
    }

    nonisolated private static func flattened(_ bookmarks: [ImportedBookmark]) -> [ImportedBookmark] {
        bookmarks.flatMap { $0.url == nil ? flattened($0.children) : [$0] }
    }

    nonisolated private static func urls(in tree: StoredSidebarTree?) -> Set<String> {
        var urls = Set<String>()
        func walk(_ nodes: [StoredSidebarNode]) {
            for node in nodes {
                switch node {
                case let .tab(tab): [tab.url, tab.homeURL].compactMap { $0 }.forEach { urls.insert($0) }
                case let .folder(folder): walk(folder.children)
                }
            }
        }
        if let tree { walk(tree.pinned); walk(tree.unpinned); walk(tree.bookmarked) }
        return urls
    }

    nonisolated private static func count(_ nodes: [StoredSidebarNode]) -> Int {
        nodes.reduce(0) { total, node in
            if case let .folder(folder) = node { return total + count(folder.children) }
            return total + 1
        }
    }

    nonisolated private static func state(merging existing: SpaceTabState?, pinned: [StoredSidebarNode], unpinned: [StoredSidebarNode],
                                          bookmarked: [StoredSidebarNode]) -> SpaceTabState {
        var added = StoredSidebarTree(pinned: pinned, unpinned: unpinned, bookmarked: bookmarked)
        // The section flags `appendTransferredNode` derives on the active space.
        func mark(_ nodes: inout [StoredSidebarNode], pinned: Bool, bookmarked: Bool) {
            for index in nodes.indices {
                switch nodes[index] {
                case var .tab(tab): tab.isPinned = pinned; tab.isBookmarked = bookmarked; nodes[index] = .tab(tab)
                case var .folder(folder): mark(&folder.children, pinned: pinned, bookmarked: bookmarked); nodes[index] = .folder(folder)
                }
            }
        }
        mark(&added.pinned, pinned: true, bookmarked: false)
        mark(&added.bookmarked, pinned: false, bookmarked: true)
        var tree = existing?.tree ?? .empty
        tree.pinned += added.pinned
        tree.unpinned += added.unpinned
        tree.bookmarked += added.bookmarked
        return SpaceTabState(activeTabId: existing?.activeTabId, activationHistory: existing?.activationHistory ?? [], tree: tree)
    }

    nonisolated private static func httpCookie(_ cookie: ImportedCookie) -> HTTPCookie? {
        if let expires = cookie.expires, expires < Date() { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: cookie.domain, .path: cookie.path, .name: cookie.name, .value: cookie.value
        ]
        if let expires = cookie.expires { properties[.expires] = expires }
        if cookie.isSecure { properties[.secure] = "TRUE" }
        if cookie.isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        switch cookie.sameSite {
        case "lax": properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
        case "strict": properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
        default: break
        }
        return HTTPCookie(properties: properties)
    }
}
