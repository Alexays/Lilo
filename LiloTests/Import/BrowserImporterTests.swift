import GRDB
import XCTest
@testable import Lilo

@MainActor
final class BrowserImporterTests: XCTestCase {
    private var home: URL!
    private var spaceId = UUID()
    private var profileId = UUID()
    private var tree = StoredSidebarTree.empty
    private var loadedTrees: [UUID: StoredSidebarTree] = [:]
    private var applied: [BrowserCommand] = []
    private var createdSpaces: [String] = []
    private var spaceIds: [String: UUID] = [:]
    private var spaceColors: [String: String] = [:]
    private var spaceProfiles: [String: UUID] = [:]
    private var profileIds: [String: UUID] = [:]
    private var savedStates: [UUID: SpaceTabState] = [:]
    private var cookies: [HTTPCookie] = []
    private var history: HistoryStore!
    private var dbPath: String!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)")
        let profile = home.appendingPathComponent("Library/Application Support/Google/Chrome/Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("""
        {"roots": {"bookmark_bar": {"children": [{"type": "url", "name": "Mail", "url": "https://mail.example/"},
          {"type": "folder", "name": "Work", "children": [{"type": "url", "name": "Docs", "url": "https://docs.example/"}]}]},
          "other": {"children": [{"type": "url", "name": "Recipe", "url": "https://food.example/"}]}}}
        """.utf8).write(to: profile.appendingPathComponent("Bookmarks"))
        dbPath = NSTemporaryDirectory() + UUID().uuidString + ".db"
        let pool = try DatabasePool(path: dbPath)
        try Migrations.migrateProfile(pool)
        history = HistoryStore(dbPool: pool)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: dbPath + suffix) }
    }

    private func importer() -> BrowserImporter {
        BrowserImporter(sink: .init(
            activeProfileId: { [unowned self] in profileId },
            activeSpaceId: { [unowned self] in spaceId },
            tree: { [unowned self] id in id == spaceId ? tree : loadedTrees[id] },
            apply: { [unowned self] command in
                applied.append(command)
                guard case let .importSidebarNodes(id, nodes, section) = command else { return }
                var target = id == spaceId ? tree : loadedTrees[id] ?? .empty
                switch section {
                case .pinned: target.pinned += nodes
                case .bookmarked: target.bookmarked += nodes
                case .unpinned: target.unpinned += nodes
                }
                if id == spaceId { tree = target } else { loadedTrees[id] = target }
            },
            findProfile: { [unowned self] name in profileIds[name] },
            createProfile: { [unowned self] name in
                let id = UUID()
                profileIds[name] = id
                return id
            },
            findSpace: { [unowned self] name, _ in spaceIds[name] },
            createSpace: { [unowned self] name, _, color, owner in
                createdSpaces.append(name)
                let id = UUID()
                spaceIds[name] = id
                spaceColors[name] = color
                spaceProfiles[name] = owner
                return id
            },
            loadSpaceState: { [unowned self] id, _ in savedStates[id] },
            saveSpaceStates: { [unowned self] states, _ in for (id, state) in states { savedStates[id] = state } },
            historyStore: { [unowned self] _ in history },
            faviconStore: { _ in throw ImportError.missingFile("favicons") },
            setCookies: { [unowned self] list, _ in cookies += list },
            installExtension: { _, _ in },
            otherBookmarksTitle: { "Other Bookmarks (\($0))" },
            warmFavicons: { _ in }
        ), home: home)
    }

    func testImportsBarAndOtherBookmarksIntoTheActiveSpaceOnce() async {
        let sources = BrowserImportScanner.scan(home: home)
        let selection = BrowserImporter.Selection(sourceId: "chrome", profileId: "Default", kinds: [.bookmarks], extensionIds: [])
        let summary = await importer().run([selection], sources: sources) { _ in }
        XCTAssertEqual(summary.first?.imported, 3, "Mail, Docs inside Work, Recipe inside Other Bookmarks")
        XCTAssertEqual(tree.pinned.count, 3, "Mail, Work, Other Bookmarks")
        guard case let .folder(other) = tree.pinned[2] else { return XCTFail("expected the other-bookmarks folder") }
        XCTAssertEqual(other.name, "Other Bookmarks (Chrome)")

        _ = await importer().run([selection], sources: sources) { _ in }
        XCTAssertEqual(tree.pinned.count, 3, "a second import adds nothing")
    }

    func testFoldersNestedPastFiveLevelsHandTheirContentToTheFifth() async throws {
        // Seven folders deep, each holding one bookmark.
        func level(_ depth: Int) -> String {
            let link = #"{"type": "url", "name": "L\#(depth)", "url": "https://l\#(depth).example/"}"#
            let inner = depth < 7 ? ", " + level(depth + 1) : ""
            return #"{"type": "folder", "name": "F\#(depth)", "children": [\#(link)\#(inner)]}"#
        }
        let bookmarks = home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Bookmarks")
        try Data(#"{"roots": {"bookmark_bar": {"children": [\#(level(1))]}}}"#.utf8).write(to: bookmarks)
        let selection = BrowserImporter.Selection(sourceId: "chrome", profileId: "Default", kinds: [.bookmarks], extensionIds: [])

        _ = await importer().run([selection], sources: BrowserImportScanner.scan(home: home)) { _ in }

        var folder = try XCTUnwrap(tree.pinned.first.flatMap { if case let .folder(folder) = $0 { folder } else { nil } })
        for depth in 1..<5 {
            XCTAssertEqual(folder.children.map(Self.title), ["L\(depth)", "F\(depth + 1)"])
            guard case let .folder(next) = folder.children[1] else { return XCTFail("expected F\(depth + 1)") }
            folder = next
        }
        XCTAssertEqual(folder.children.map(Self.title), ["L5", "L6", "L7"])
    }

    func testAVanishedFirstSelectionLeavesTheActiveSpaceToTheNext() async {
        let sources = BrowserImportScanner.scan(home: home)
        let summary = await importer().run([
            .init(sourceId: "chrome", profileId: "Gone", kinds: [.bookmarks], extensionIds: []),
            .init(sourceId: "chrome", profileId: "Default", kinds: [.bookmarks], extensionIds: [])
        ], sources: sources) { _ in }

        XCTAssertTrue(createdSpaces.isEmpty)
        XCTAssertEqual(summary.first?.imported, 3)
        XCTAssertEqual(tree.pinned.count, 3, "the active space takes the import")
    }

    func testSecondProfileGetsItsOwnSpaceAndFailuresStayIsolated() async throws {
        let chrome = home.appendingPathComponent("Library/Application Support/Google/Chrome")
        try Data(#"{"profile": {"info_cache": {"Default": {"name": "Perso"}, "Profile 1": {"name": "Travail"}}}}"#.utf8)
            .write(to: chrome.appendingPathComponent("Local State"))
        try FileManager.default.createDirectory(at: chrome.appendingPathComponent("Profile 1"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: chrome.appendingPathComponent("Default/Bookmarks"), to: chrome.appendingPathComponent("Profile 1/Bookmarks"))
        let sources = BrowserImportScanner.scan(home: home)
        let summary = await importer().run([
            .init(sourceId: "chrome", profileId: "Default", kinds: [.bookmarks, .history], extensionIds: []),
            .init(sourceId: "chrome", profileId: "Profile 1", kinds: [.bookmarks], extensionIds: [])
        ], sources: sources) { _ in }
        XCTAssertEqual(createdSpaces, ["Travail"])
        XCTAssertEqual(savedStates.count, 1)
        XCTAssertNotNil(summary.first { $0.kind == .history }?.error, "no History file: history fails alone")
        XCTAssertEqual(summary.filter { $0.kind == .bookmarks }.map(\.imported), [3, 3])
    }

    func testExpiredCookiesAreSkipped() async throws {
        let profile = home.appendingPathComponent("Library/Application Support/Firefox/Profiles/p")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("[Profile0]\nName=p\nIsRelative=1\nPath=Profiles/p\n".utf8)
            .write(to: home.appendingPathComponent("Library/Application Support/Firefox/profiles.ini"))
        let queue = try DatabaseQueue(path: profile.appendingPathComponent("cookies.sqlite").path)
        try await queue.write { db in
            try db.execute(sql: "CREATE TABLE moz_cookies (host TEXT, name TEXT, value TEXT, path TEXT, expiry INTEGER, isSecure INTEGER, isHttpOnly INTEGER, sameSite INTEGER)")
            try db.execute(sql: "INSERT INTO moz_cookies VALUES ('.a.example', 'old', '1', '/', 1000, 0, 0, 0)")
            try db.execute(sql: "INSERT INTO moz_cookies VALUES ('.a.example', 'new', '2', '/', 4102444800, 1, 1, 1)")
        }
        let summary = await importer().run([.init(sourceId: "firefox", profileId: "p", kinds: [.cookies], extensionIds: [])],
                                           sources: BrowserImportScanner.scan(home: home)) { _ in }
        XCTAssertEqual(cookies.map(\.name), ["new"])
        XCTAssertEqual(summary.first?.skipped, 1)
    }

    func testArcFavoritesStayBookmarkedAndReimportAddsNoSpace() async throws {
        let arcRoot = home.appendingPathComponent("Library/Application Support/Arc")
        try FileManager.default.createDirectory(at: arcRoot.appendingPathComponent("User Data/Default"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: arcRoot.appendingPathComponent("User Data/Default/Bookmarks"))
        try Data("""
        {"sidebar": {"containers": [{"global": {}}, {
          "topAppsContainerIDs": ["fav"],
          "spaces": ["s1", {"id": "s1", "title": "Work", "containerIDs": ["pinned", "p1", "unpinned", "u1"]}],
          "items": [
            "fav", {"id": "fav", "childrenIds": ["f1", "ff"], "data": {"itemContainer": {}}},
            "f1", {"id": "f1", "title": "Mail", "data": {"tab": {"savedURL": "https://mail.example/"}}},
            "ff", {"id": "ff", "title": "Group", "childrenIds": ["f2"], "data": {"list": {}}},
            "f2", {"id": "f2", "title": "Cal", "data": {"tab": {"savedURL": "https://cal.example/"}}},
            "p1", {"id": "p1", "childrenIds": ["t1"], "data": {"itemContainer": {}}},
            "t1", {"id": "t1", "title": "Board", "data": {"tab": {"savedURL": "https://board.example/"}}},
            "u1", {"id": "u1", "childrenIds": [], "data": {"itemContainer": {}}}
          ]}]}}
        """.utf8).write(to: arcRoot.appendingPathComponent("StorableSidebar.json"))
        let sources = BrowserImportScanner.scan(home: home)
        let selection = BrowserImporter.Selection(sourceId: "arc", profileId: "Default", kinds: [.tabs], extensionIds: [])

        _ = await importer().run([selection], sources: sources) { _ in }
        _ = await importer().run([selection], sources: sources) { _ in }

        let favorites = applied.compactMap { command -> [StoredSidebarNode]? in
            guard case let .importSidebarNodes(_, nodes, section) = command, section == .bookmarked else { return nil }
            return nodes
        }.flatMap { $0 }
        XCTAssertEqual(favorites.count, 2, "favorite folders are flattened")
        for node in favorites {
            guard case let .tab(tab) = node else { return XCTFail("the bookmarked section holds tabs only") }
            XCTAssertTrue(tab.isBookmarked, "a closed favorite must stay bookmarked or repair drops it")
        }
        XCTAssertEqual(createdSpaces, ["Work"], "a second import reuses the Arc space")
        let work = try XCTUnwrap(spaceIds["Work"].flatMap { savedStates[$0] })
        XCTAssertEqual(work.tree.pinned.count, 1, "and adds nothing twice to it")
    }

    func testArcImportKeepsProfilesFoldersSplitsAndColorsAndRerunsAddNothing() async throws {
        let arcRoot = home.appendingPathComponent("Library/Application Support/Arc")
        let userData = arcRoot.appendingPathComponent("User Data")
        for profile in ["Default", "Profile 1"] {
            try FileManager.default.createDirectory(at: userData.appendingPathComponent(profile), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: userData.appendingPathComponent("\(profile)/Bookmarks"))
        }
        try Data(#"{"profile": {"info_cache": {"Default": {"name": "Personal"}, "Profile 1": {"name": "Freelance"}}}}"#.utf8)
            .write(to: userData.appendingPathComponent("Local State"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("arc-storable-sidebar.json"),
                                         to: arcRoot.appendingPathComponent("StorableSidebar.json"))
        let sources = BrowserImportScanner.scan(home: home)
        let selections: [BrowserImporter.Selection] = [
            .init(sourceId: "arc", profileId: "Default", kinds: [.tabs], extensionIds: []),
            .init(sourceId: "arc", profileId: "Profile 1", kinds: [.tabs], extensionIds: [])
        ]

        let first = await importer().run(selections, sources: sources) { _ in }

        let tabs = first.filter { $0.kind == .tabs }
        XCTAssertEqual(tabs.map(\.error), [nil, nil])
        XCTAssertEqual(tabs.map(\.imported), [14, 4], "favorites and space tabs; the easel and the arc:// tab are skipped")

        let arcProfile = try XCTUnwrap(profileIds["Arc Freelance"], "a second Arc profile gets its own Lilo profile")
        XCTAssertEqual(createdSpaces, ["Work", "Home", "Lab", "Freelance", "Acme"])
        XCTAssertEqual(["Work", "Home", "Lab"].map { spaceProfiles[$0] }, [profileId, profileId, profileId],
                       "a space of an unknown Arc profile falls to the first one")
        XCTAssertEqual(spaceProfiles["Acme"], arcProfile)
        XCTAssertEqual(spaceColors, ["Work": "#5b6bf2", "Acme": "#ff7f00"])
        XCTAssertEqual(tree.bookmarked.map(Self.title), ["Inbox", "Chat"], "only the first profile's favorites land in the active space")
        XCTAssertEqual(savedStates[spaceIds["Freelance"]!]?.tree.bookmarked.map(Self.title), ["Acme Mail"])

        let work = try XCTUnwrap(savedStates[spaceIds["Work"]!])
        XCTAssertNil(work.activeTabId, "nothing is loaded by the import")
        XCTAssertEqual(work.tree.pinned.map(Self.title), ["Projects", "", "Calendar"])
        guard case let .folder(projects) = work.tree.pinned[0], case let .folder(specs) = projects.children[1],
              case let .folder(archive) = specs.children[1], case let .folder(pinnedSplit) = work.tree.pinned[1],
              case let .tab(calendar) = work.tree.pinned[2] else { return XCTFail("expected nested folders, a split and a tab") }
        XCTAssertEqual(projects.children.map(Self.title), ["Roadmap", "Specs"], "a subfolder stays inside its folder")
        XCTAssertEqual(specs.children.map(Self.title), ["API spec", "Archive"])
        XCTAssertEqual(archive.children.map(Self.title), ["API v1"])
        XCTAssertTrue(calendar.isClosed && calendar.isPinned && calendar.homeURL == calendar.url, "a pinned tab comes in asleep")
        let panes = pinnedSplit.children.compactMap { node -> StoredTab? in if case let .tab(tab) = node { tab } else { nil } }
        XCTAssertEqual(panes.map(\.title), ["Design", "Issues"])
        XCTAssertTrue(panes.allSatisfy { !$0.isClosed && $0.isPinned }, "split panes are open tabs, loaded only once shown")
        XCTAssertEqual(pinnedSplit.splitLayout, .split(vertical: false, ratio: 0.5, first: .pane(tabId: panes[0].id), second: .pane(tabId: panes[1].id)))
        XCTAssertEqual(work.tree.unpinned.map(Self.title), ["lilo - Search", ""])
        guard case let .folder(stack) = work.tree.unpinned[1] else { return XCTFail("expected the stacked split") }
        XCTAssertEqual(stack.splitLayout?.paneIds.count, 3)
        if case let .split(vertical, _, _, _) = stack.splitLayout { XCTAssertTrue(vertical) } else { XCTFail("expected a stacked layout") }

        let acme = try XCTUnwrap(savedStates[spaceIds["Acme"]!])
        XCTAssertEqual(acme.tree.pinned.map(Self.title), ["Portal", "Billing"])
        guard case let .folder(billing) = acme.tree.pinned[1] else { return XCTFail("expected the Billing folder") }
        XCTAssertNil(billing.splitLayout)
        XCTAssertEqual(billing.children.map(Self.title), ["Invoices", "Ledger"], "a split inside a folder becomes plain tabs")

        let before = savedStates
        let second = await importer().run(selections, sources: sources) { _ in }
        XCTAssertEqual(second.filter { $0.kind == .tabs }.map(\.imported), [0, 0])
        XCTAssertEqual(createdSpaces.count, 5)
        XCTAssertEqual(savedStates, before, "a second import adds nothing")
        XCTAssertEqual(tree.bookmarked.count, 2)
    }

    func testChromiumSessionKeepsPinnedTabsAndGroupsAndRerunsAddNothing() async throws {
        var session = SNSSWriter()
        session.tabWindow(1, tab: 1, index: 0)
        session.navigations(tab: 1, [("https://chat.example/", "Chat")], selected: 0)
        session.pinned(1)
        session.tabWindow(1, tab: 2, index: 1)
        session.navigations(tab: 2, [("https://mail.example/", "Mail")], selected: 0)
        session.tabWindow(1, tab: 3, index: 2)
        session.navigations(tab: 3, [("https://docs.example/", "Docs"), ("https://sheet.example/", "Sheet")], selected: 1)
        session.group(tab: 3, 7)
        session.groupMetadata(7, title: "Q3", color: 4)
        session.tabWindow(2, tab: 4, index: 0)
        session.navigations(tab: 4, [("https://news.example/", "News")], selected: 0)
        let sessions = home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try session.data.write(to: sessions.appendingPathComponent("Session_13300000000000000"))
        let sources = BrowserImportScanner.scan(home: home)
        XCTAssertEqual(sources.first?.profiles.first?.kinds, [.bookmarks, .tabs])
        let selection = BrowserImporter.Selection(sourceId: "chrome", profileId: "Default", kinds: [.bookmarks, .tabs], extensionIds: [])

        let first = await importer().run([selection], sources: sources) { _ in }

        XCTAssertEqual(first.first { $0.kind == .tabs }?.imported, 3, "Mail is already a bookmark")
        XCTAssertEqual(tree.pinned.map(Self.title), ["Mail", "Work", "Other Bookmarks (Chrome)", "Chat"])
        guard case let .tab(chat) = tree.pinned[3] else { return XCTFail("expected the pinned tab") }
        XCTAssertTrue(chat.isClosed && chat.homeURL == chat.url, "a pinned tab comes in asleep, like a bookmark")
        XCTAssertEqual(tree.unpinned.map(Self.title), ["Q3", "News"], "windows follow each other in the space")
        guard case let .folder(group) = tree.unpinned[0], case let .tab(sheet) = group.children.first else { return XCTFail("expected the group") }
        XCTAssertEqual(group.color, "#5fd79a")
        XCTAssertEqual(sheet.url, "https://sheet.example/")
        XCTAssertFalse(sheet.isClosed)

        let second = await importer().run([selection], sources: sources) { _ in }
        XCTAssertEqual(second.first { $0.kind == .tabs }?.imported, 0)
        XCTAssertEqual(tree.pinned.count + tree.unpinned.count, 6)
    }

    private static func title(_ node: StoredSidebarNode) -> String {
        switch node {
        case let .tab(tab): tab.title
        case let .folder(folder): folder.name
        }
    }

    func testLoadedSpaceIsExtendedThroughLiveStateNotOverwrittenOnDisk() async throws {
        let arcRoot = home.appendingPathComponent("Library/Application Support/Arc")
        try FileManager.default.createDirectory(at: arcRoot.appendingPathComponent("User Data/Default"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: arcRoot.appendingPathComponent("User Data/Default/Bookmarks"))
        try Data("""
        {"sidebar": {"containers": [{"global": {}}, {
          "spaces": ["s1", {"id": "s1", "title": "Work", "containerIDs": ["pinned", "p1", "unpinned", "u1"]}],
          "items": [
            "p1", {"id": "p1", "childrenIds": ["t1"], "data": {"itemContainer": {}}},
            "t1", {"id": "t1", "title": "Board", "data": {"tab": {"savedURL": "https://board.example/"}}},
            "u1", {"id": "u1", "childrenIds": [], "data": {"itemContainer": {}}}
          ]}]}}
        """.utf8).write(to: arcRoot.appendingPathComponent("StorableSidebar.json"))
        let workId = UUID()
        spaceIds["Work"] = workId
        loadedTrees[workId] = .empty

        _ = await importer().run([.init(sourceId: "arc", profileId: "Default", kinds: [.tabs], extensionIds: [])],
                                 sources: BrowserImportScanner.scan(home: home)) { _ in }
        XCTAssertNil(savedStates[workId], "a loaded space's live state would overwrite a direct save")
        XCTAssertEqual(loadedTrees[workId]?.pinned.count, 1)
    }

    func testExtensionsOfASecondProfileInstallIntoItsOwnLiloProfile() async throws {
        let chrome = home.appendingPathComponent("Library/Application Support/Google/Chrome")
        try Data(#"{"profile": {"info_cache": {"Default": {"name": "Perso"}, "Profile 1": {"name": "Travail"}}}}"#.utf8)
            .write(to: chrome.appendingPathComponent("Local State"))
        let id = String(repeating: "c", count: 32)
        let ext = chrome.appendingPathComponent("Profile 1/Extensions/\(id)/1.0")
        try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
        try Data(#"{"name": "Work tool", "update_url": "https://clients2.google.com/service/update2/crx"}"#.utf8)
            .write(to: ext.appendingPathComponent("manifest.json"))
        var installed: [(String, UUID)] = []
        let travailId = UUID()
        let summary = await BrowserImporter(sink: .init(
            activeProfileId: { [unowned self] in profileId }, activeSpaceId: { [unowned self] in spaceId },
            tree: { _ in nil }, apply: { _ in }, findProfile: { _ in nil }, createProfile: { name in name.hasSuffix(" Travail") ? travailId : UUID() },
            findSpace: { _, _ in nil }, createSpace: { _, _, _, _ in UUID() }, loadSpaceState: { _, _ in nil },
            saveSpaceStates: { _, _ in }, historyStore: { [unowned self] _ in history },
            faviconStore: { _ in throw ImportError.missingFile("favicons") }, setCookies: { _, _ in },
            installExtension: { installed.append(($0, $1)) }, otherBookmarksTitle: { $0 }, warmFavicons: { _ in }
        ), home: home).run([
            .init(sourceId: "chrome", profileId: "Default", kinds: [.bookmarks], extensionIds: []),
            .init(sourceId: "chrome", profileId: "Profile 1", kinds: [.extensions], extensionIds: [id])
        ], sources: BrowserImportScanner.scan(home: home)) { _ in }
        XCTAssertEqual(installed.map(\.0), [id])
        XCTAssertEqual(installed.map(\.1), [travailId], "a second profile's extensions land in its own Lilo profile, not the active one")
        XCTAssertEqual(summary.first { $0.kind == .extensions }?.imported, 1)
    }

    func testProgressNamesEachKindAsItStartsAndEachExtensionInstall() async throws {
        let ids = ["a", "b"].map { String(repeating: $0, count: 32) }
        for id in ids {
            let ext = home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Extensions/\(id)/1.0")
            try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
            try Data(#"{"name": "Tool", "update_url": "https://clients2.google.com/service/update2/crx"}"#.utf8)
                .write(to: ext.appendingPathComponent("manifest.json"))
        }
        var steps: [String] = []
        _ = await importer().run([.init(sourceId: "chrome", profileId: "Default", kinds: [.extensions, .history, .bookmarks], extensionIds: ids)],
                                 sources: BrowserImportScanner.scan(home: home)) { steps.append("\($0.kind.rawValue) \($0.done)/\($0.total)") }
        XCTAssertEqual(steps, ["bookmarks 0/0", "history 0/0", "extensions 0/2", "extensions 1/2"])
    }

}
