import GRDB
import os
import XCTest
@testable import Lilo

/// Real-world sized imports through `BrowserImporter.run` into a live window: what a big Arc sidebar becomes, and what
/// must not grow with the data (transactions, bridge events, main-thread stalls).
@MainActor
final class ImportScaleTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var window: MainWindowController!
    private var home: URL!
    private var profileId: UUID!
    private var activeSpaceId: UUID!
    private let commits = CommitCounter()
    private var bridgeEvents: [(name: String, at: UInt64, bytes: Int)] = []

    override func setUp() async throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("import-scale-\(UUID().uuidString)")
        browserContext = try await TemporaryBrowserContext()
        let context = browserContext.context
        profileId = try context.profileManager.createProfile(name: "P").id
        activeSpaceId = try context.spaceManager.createSpace(name: "Start", profileId: profileId).id
        window = makeTestWindow(context, showing: activeSpaceId)
        window.bridgeRouter.javaScriptSink = { [unowned self] _, arguments, completion in
            let messages = arguments["messages"] as? [[String: Any]] ?? (arguments["message"] as? [String: Any]).map { [$0] } ?? []
            for message in messages {
                let bytes = (try? JSONSerialization.data(withJSONObject: message).count) ?? 0
                bridgeEvents.append((message["event"] as? String ?? "", DispatchTime.now().uptimeNanoseconds, bytes))
            }
            completion()
        }
        // The window's debounced saves (its frame, its Space's tabs) land seconds later, in an import's count if left.
        context.saveWindowsNow()
        window.profileContext?.sessionPersistence?.saveNow()
        try await context.dbManager.pool(for: profileId).barrierWriteWithoutTransaction { _ in }
        context.dbManager.globalPool.add(transactionObserver: commits, extent: .observerLifetime)
        try context.dbManager.pool(for: profileId).add(transactionObserver: commits, extent: .observerLifetime)
        // The window's own startup events must not count as the import's.
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    override func tearDown() async throws {
        browserContext.context.windows.remove(window)
        window = nil
        browserContext.tearDown()
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Arc

    func testABigArcSidebarKeepsItsShapeAndARerunAddsNothing() async throws {
        let arc = try writeArc(spaces: 10, chains: 4, unpinned: 84)
        let selections = Self.arcProfiles.map { BrowserImporter.Selection(sourceId: "arc", profileId: $0, kinds: [.tabs], extensionIds: []) }
        let sources = BrowserImportScanner.scan(home: home)

        let first = await measure("arc 2,000 tabs", selections, sources)
        XCTAssertLessThan(first.longestMainBlock, 1, "no main-thread block of a second")

        let tabs = first.summary.filter { $0.kind == .tabs }
        XCTAssertEqual(tabs.map(\.error), [nil, nil, nil])
        XCTAssertEqual(tabs.map(\.imported).reduce(0, +), arc.tabCount, "every importable tab arrives once")
        XCTAssertGreaterThanOrEqual(arc.tabCount, 2000)
        let context = browserContext.context
        for space in arc.spaces {
            let lilo = try XCTUnwrap(context.spaceManager.spaces.first { $0.name == space.name }, space.name)
            XCTAssertEqual(lilo.icon, space.icon, space.name)
            XCTAssertEqual(lilo.color, space.color, space.name)
            let state = try XCTUnwrap(try SpaceTabStateStore(dbPool: context.dbManager.pool(for: lilo.profileId)).load(spaceId: lilo.id))
            XCTAssertNil(state.activeTabId, "nothing is loaded by the import")
            XCTAssertEqual(Self.outline(state.tree.pinned), space.pinnedOutline, "folder nesting, order and contents in \(space.name)")
            XCTAssertEqual(state.tree.unpinned.map(Self.title), space.unpinnedRoots, space.name)
            XCTAssertEqual(state.tree.unpinned.compactMap(Self.folderTitles), space.unpinnedFolders, space.name)
            var pinned = 0, unpinned = 0
            Self.forEachTab(state.tree.pinned) { tab in
                pinned += 1
                XCTAssertTrue(tab.isPinned && !tab.isBookmarked, "\(tab.title) in \(space.name)")
                XCTAssertEqual(tab.homeURL, tab.url)
            }
            Self.forEachTab(state.tree.unpinned) { tab in
                unpinned += 1
                XCTAssertFalse(tab.isPinned || tab.isClosed || tab.isBookmarked, "\(tab.title) in \(space.name)")
            }
            XCTAssertEqual(pinned + unpinned, space.tabCount, space.name)
            let splits = (state.tree.pinned + state.tree.unpinned).compactMap { node -> SplitLayout? in
                if case let .folder(folder) = node { folder.splitLayout } else { nil }
            }
            XCTAssertEqual(splits.map(\.paneIds.count), [2, 3, 4], "splits in \(space.name)")
        }
        let live = try XCTUnwrap(context.browserState.space(id: activeSpaceId)?.spaceTab.state.tree)
        XCTAssertEqual(live.bookmarked.map(Self.title), arc.favorites["Default"], "favorite folders are flattened into the active space")
        for profile in Self.arcProfiles.dropFirst() {
            let lilo = try XCTUnwrap(context.spaceManager.spaces.first { $0.name == Self.arcProfileNames[profile] })
            XCTAssertEqual(try SpaceTabStateStore(dbPool: context.dbManager.pool(for: lilo.profileId)).load(spaceId: lilo.id)?.tree.bookmarked.map(Self.title),
                           arc.favorites[profile], "\(profile) favorites land in its own profile")
        }

        let spaces = context.spaceManager.spaces.count
        let states = try storedStates()
        let second = await measure("arc rerun", selections, sources)
        XCTAssertEqual(second.summary.filter { $0.kind == .tabs }.map(\.imported), [0, 0, 0])
        XCTAssertEqual(context.spaceManager.spaces.count, spaces, "a rerun reuses every space")
        XCTAssertEqual(try storedStates(), states, "a rerun adds nothing twice")
        XCTAssertEqual(context.browserState.space(id: activeSpaceId)?.spaceTab.state.tree.bookmarked.count, live.bookmarked.count)
    }

    /// Transactions and bridge events must not grow with the tabs, nor main-thread work faster than they do.
    func testArcImportWorkStaysFlatWhenTheSidebarDoubles() async throws {
        let selections = Self.arcProfiles.map { BrowserImporter.Selection(sourceId: "arc", profileId: $0, kinds: [.tabs], extensionIds: []) }
        _ = try writeArc(spaces: 10, chains: 2, unpinned: 40)
        let small = await measure("arc 1x", selections, BrowserImportScanner.scan(home: home))
        // A fresh browser, so the second import creates the same profiles and spaces as the first.
        try await tearDown()
        try await setUp()
        _ = try writeArc(spaces: 10, chains: 4, unpinned: 80)
        let big = await measure("arc 2x", selections, BrowserImportScanner.scan(home: home))
        XCTAssertEqual(big.commits, small.commits, "whatever the tab count")
        // A row per created profile and space, one tree write per profile, and the live Space's session save.
        XCTAssertLessThanOrEqual(big.commits, 10 + 2 + 2 + 3 + 1)
        XCTAssertEqual(big.bridgeEvents, small.bridgeEvents)
        // CPU time, not wall time, so a loaded machine does not fail it: twice the tabs, at most about twice the main-thread work.
        XCTAssertLessThan(big.mainCPU, small.mainCPU * 3 + 0.05, "main-thread work grows linearly at most")
    }

    // MARK: - Chromium, Firefox, Safari

    func testHugeHistoriesAndBookmarksImportOffTheMainThreadInFewTransactions() async throws {
        try writeChrome(bookmarks: 4000, history: 20_000)
        try writeFirefox(bookmarks: 4000, history: 20_000, cookies: 4000)
        try writeSafari(bookmarks: 4000, history: 20_000)
        let sources = BrowserImportScanner.scan(home: home)
        // Chrome hides one row in 50, Firefox never visited its bookmarked places, Safari keeps four visits per item.
        for (source, profile, kinds, visited) in [("chrome", "Default", Set<ImportKind>([.bookmarks, .history]), 19_600),
                                                  ("firefox", "p", [.bookmarks, .history, .cookies], 16_000),
                                                  ("safari", "safari", [.bookmarks, .history], 5000)] {
            let run = await measure("\(source) 4k bookmarks 20k history", [.init(sourceId: source, profileId: profile, kinds: kinds, extensionIds: [])], sources)
            XCTAssertEqual(run.summary.map(\.error), run.summary.map { _ in nil }, source)
            XCTAssertEqual(run.summary.first { $0.kind == .history }?.imported, visited, source)
            XCTAssertGreaterThanOrEqual(run.summary.first { $0.kind == .bookmarks }?.imported ?? 0, 4000, source)
            XCTAssertLessThanOrEqual(run.commits, 8, "\(source): a handful of transactions, not one per row")
            // Relative to the import's own CPU time, so a loaded machine does not fail it: on the main thread, one block would hold it all.
            XCTAssertLessThan(run.longestMainBlock, run.cpu / 2, "\(source): the import runs off the main thread")
            let tree = try XCTUnwrap(browserContext.context.browserState.space(id: activeSpaceId)?.spaceTab.state.tree)
            let folder = try XCTUnwrap(tree.pinned.lazy.compactMap { node -> StoredFolder? in if case let .folder(folder) = node { folder } else { nil } }.first)
            let before = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            _ = try window.applyBrowserCommand(.setFolderCollapsed(spaceId: activeSpaceId, folderId: folder.id, isCollapsed: !folder.isCollapsed))
            let toggle = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - before) / 1e9
            print(String(format: "IMPORT-SCALE %@: folder toggle on the imported space %.0f ms main cpu", source, toggle * 1000))
            XCTAssertLessThan(toggle, run.mainCPU / 2, "\(source): a click on the imported space costs far less than the import")
            let again = await measure("\(source) rerun", [.init(sourceId: source, profileId: profile, kinds: kinds, extensionIds: [])], sources)
            XCTAssertEqual(again.summary.first { $0.kind == .bookmarks }?.imported, 0, "\(source): a rerun adds no bookmark twice")
        }
    }

    func testALargeChromiumSessionKeepsItsPinsGroupsAndOrder() async throws {
        let expected = try writeChromeSession(windows: 3, tabsPerWindow: 1000)
        let selection = BrowserImporter.Selection(sourceId: "chrome", profileId: "Default", kinds: [.tabs], extensionIds: [])
        let sources = BrowserImportScanner.scan(home: home)

        let run = await measure("chrome session 3,000 tabs", [selection], sources)

        XCTAssertEqual(run.summary.map(\.error), [nil])
        XCTAssertEqual(run.summary.first?.imported, expected.tabCount)
        XCTAssertLessThan(run.longestMainBlock, 1, "no main-thread block of a second")
        let tree = try XCTUnwrap(browserContext.context.browserState.space(id: activeSpaceId)?.spaceTab.state.tree)
        XCTAssertEqual(tree.pinned.map(Self.title), expected.pinned)
        XCTAssertEqual(tree.unpinned.map(Self.title), expected.roots, "window order, then tab order, groups in place")
        let groups = tree.unpinned.compactMap { node -> StoredFolder? in if case let .folder(folder) = node { folder } else { nil } }
        XCTAssertEqual(groups.map { $0.children.map(Self.title) }, expected.groups)
        XCTAssertEqual(Set(groups.map(\.color)), ["#5b7cff", "#5fd79a"], "tab group colors become folder colors")
        Self.forEachTab(tree.pinned) { XCTAssertTrue($0.isPinned && $0.isClosed, $0.title) }
        Self.forEachTab(tree.unpinned) { XCTAssertFalse($0.isPinned || $0.isClosed, $0.title) }

        let again = await measure("chrome session rerun", [selection], sources)
        XCTAssertEqual(again.summary.first?.imported, 0, "a rerun adds no tab twice")
        XCTAssertEqual(again.bridgeEvents, 0)
    }

    // MARK: - Measurement

    private struct Run {
        var summary: [BrowserImporter.SummaryItem]
        /// CPU seconds the main thread spent during the import, and the most it spent between two turns of its run loop.
        var mainCPU: Double
        var longestMainBlock: Double
        /// CPU seconds the whole process spent during the import.
        var cpu: Double
        var commits: Int
        var bridgeEvents: Int
    }

    /// Prints wall time, CPU time (process and main thread), the longest main-thread block (CPU time between two ticks of a
    /// 2 ms main-loop timer, so preemption on a loaded machine is not counted), peak footprint, commits and bridge traffic.
    private func measure(_ label: String, _ selections: [BrowserImporter.Selection], _ sources: [ImportSource]) async -> Run {
        let baseline = ProcessTaskInfoSampler.physicalFootprint(pid: Int(getpid())) ?? 0
        let peak = OSAllocatedUnfairLock(initialState: baseline)
        let sampling = OSAllocatedUnfairLock(initialState: true)
        Thread.detachNewThread {
            while sampling.withLock({ $0 }) {
                let now = ProcessTaskInfoSampler.physicalFootprint(pid: Int(getpid())) ?? 0
                peak.withLock { $0 = max($0, now) }
                usleep(2000)
            }
        }
        let mainStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let ticks = OSAllocatedUnfairLock(initialState: (last: mainStart, longest: UInt64(0)))
        let tick: @Sendable () -> Void = {
            let now = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            ticks.withLock { $0 = (now, max($0.longest, now - $0.last)) }
        }
        let ticker = Timer(timeInterval: 0.002, repeats: true) { _ in tick() }
        RunLoop.main.add(ticker, forMode: .common)
        commits.reset()
        bridgeEvents = []
        let processStart = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        let start = DispatchTime.now().uptimeNanoseconds

        let summary = await importer().run(selections, sources: sources) { _ in }
        let end = DispatchTime.now().uptimeNanoseconds
        tick()
        let mainCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - mainStart
        let processCPU = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - processStart
        // The live Space takes its share through its session save, two seconds later: made now, it counts as this run's.
        window.profileContext?.sessionPersistence?.saveNow()
        try? await browserContext.context.dbManager.pool(for: profileId).barrierWriteWithoutTransaction { _ in }
        // Lets the bridge flush what the last turn queued.
        try? await Task.sleep(nanoseconds: 50_000_000)
        ticker.invalidate()
        sampling.withLock { $0 = false }
        let longest = ticks.withLock { $0.longest }

        let firstSidebar = bridgeEvents.first { $0.name.hasPrefix("browserState") }.map { Double($0.at - start) / 1e9 }
        print(String(format: "IMPORT-SCALE %@: wall %.2f s, cpu %.2f s, main cpu %.0f ms, longest main block %.0f ms, peak +%.0f MB, "
                     + "%d commits, %d bridge events (%d KB), first sidebar event %@",
                     label, Double(end - start) / 1e9, Double(processCPU) / 1e9, Double(mainCPU) / 1e6, Double(longest) / 1e6,
                     Double(peak.withLock { $0 } - min(baseline, peak.withLock { $0 })) / 1_048_576, commits.count, bridgeEvents.count,
                     bridgeEvents.map(\.bytes).reduce(0, +) / 1024, firstSidebar.map { String(format: "%.0f ms", $0 * 1000) } ?? "none"))
        return Run(summary: summary, mainCPU: Double(mainCPU) / 1e9, longestMainBlock: Double(longest) / 1e9, cpu: Double(processCPU) / 1e9, commits: commits.count,
                   bridgeEvents: bridgeEvents.count)
    }

    /// The production sink of `MainWindowController.setupBridgeLate`, on this test's window and context.
    private func importer() -> BrowserImporter {
        let context = browserContext.context
        let spaceManager: SpaceManager = context.spaceManager
        return BrowserImporter(sink: .init(
            activeProfileId: { [unowned self] in profileId },
            activeSpaceId: { [unowned self] in window.tabManager.currentSpaceId },
            tree: { context.browserState.space(id: $0)?.spaceTab.state.tree },
            apply: { [unowned self] in _ = try window.applyBrowserCommand($0) },
            findProfile: { name in context.profileManager.profiles.first { $0.name == name }?.id },
            createProfile: { [unowned self] name in
                let id = try context.profileManager.createProfile(name: name).id
                try context.dbManager.pool(for: id).add(transactionObserver: commits, extent: .observerLifetime)
                return id
            },
            findSpace: { name, profileId in spaceManager.spaces(for: profileId).first { $0.name == name }?.id },
            createSpace: { name, icon, color, profileId in
                guard let color else { return try spaceManager.createSpace(name: name, icon: icon, profileId: profileId).id }
                return try spaceManager.createSpace(name: name, icon: icon, color: color, profileId: profileId).id
            },
            loadSpaceState: { spaceId, profileId in
                try? SpaceTabStateStore(dbPool: context.dbManager.pool(for: profileId)).load(spaceId: spaceId)
            },
            saveSpaceStates: { states, profileId in
                try SpaceTabStateStore(dbPool: try context.dbManager.pool(for: profileId)).saveMany(states)
            },
            historyStore: { HistoryStore(dbPool: try context.dbManager.pool(for: $0)) },
            faviconStore: { FaviconStore(dbPool: try context.dbManager.pool(for: $0)) },
            setCookies: { _, _ in },
            installExtension: { _, _ in },
            otherBookmarksTitle: { "Other Bookmarks (\($0))" },
            warmFavicons: { entries in
                entries.forEach { context.faviconService.warmIfAbsent(host: $0.host, dataURL: $0.dataURL, dominantColor: $0.dominantColor) }
            }
        ), home: home)
    }

    private func storedStates() throws -> [UUID: SpaceTabState] {
        let context = browserContext.context
        var states: [UUID: SpaceTabState] = [:]
        for space in context.spaceManager.spaces {
            states[space.id] = try SpaceTabStateStore(dbPool: context.dbManager.pool(for: space.profileId)).load(spaceId: space.id)
        }
        return states
    }

    private static func title(_ node: StoredSidebarNode) -> String {
        switch node {
        case let .tab(tab): tab.title
        case let .folder(folder): folder.name
        }
    }

    /// One line per node, indented two spaces per enclosing folder.
    private static func outline(_ nodes: [StoredSidebarNode], depth: Int = 0) -> [String] {
        nodes.flatMap { node -> [String] in
            let line = String(repeating: "  ", count: depth) + title(node)
            guard case let .folder(folder) = node else { return [line] }
            return [line] + outline(folder.children, depth: depth + 1)
        }
    }

    private static func folderTitles(_ node: StoredSidebarNode) -> [String]? {
        guard case let .folder(folder) = node else { return nil }
        return folder.children.map(title)
    }

    private static func forEachTab(_ nodes: [StoredSidebarNode], _ body: (StoredTab) -> Void) {
        for node in nodes {
            switch node {
            case let .tab(tab): body(tab)
            case let .folder(folder): forEachTab(folder.children, body)
            }
        }
    }

    // MARK: - Fixtures

    private static let arcProfiles = ["Default", "Profile 1", "Profile 2"]
    private static let arcProfileNames = ["Default": "Personnel", "Profile 1": "Travail ✨", "Profile 2": "東京"]

    /// What one Arc space must become in Lilo.
    private struct ExpectedSpace {
        var name: String
        var icon: String
        var color: String
        /// The pinned section as `outline` prints it.
        var pinnedOutline: [String] = []
        var unpinnedRoots: [String] = []
        var unpinnedFolders: [[String]] = []
        var tabCount = 0
    }

    /// `spaces` spaces spread over three profiles, each with `chains` folder chains six levels deep, one past Lilo's cap (a split inside the
    /// second level), a pinned split, `unpinned` open tabs, a stacked split, a five-pane split, and the odd items real
    /// files carry: no URL, arc:// URLs, easels, dangling children, a cycle, duplicates, empty titles, a repeated space
    /// name and a code-point-only icon.
    private func writeArc(spaces: Int, chains: Int, unpinned: Int, spacePrefix: String = "Espace")
        throws -> (spaces: [ExpectedSpace], favorites: [String: [String]], tabCount: Int) {
        var items: [Any] = []
        var counter = 0
        func add(_ id: String, _ title: String?, children: [String] = [], data: [String: Any]) {
            items += [id, ["id": id, "title": title ?? NSNull(), "childrenIds": children, "data": data, "createdAt": 720_000_000] as [String: Any]]
        }
        /// Every seventh tab keeps its title in `savedTitle` only, as Arc does for untouched tabs.
        func tab(_ url: String, _ title: String) -> String {
            counter += 1
            let id = "T\(counter)"
            add(id, counter % 7 == 0 ? nil : title, data: ["tab": ["savedURL": url, "savedTitle": title, "savedMuteStatus": "allowAudio"]])
            return id
        }
        func profileKey(_ profile: String) -> [String: Any] {
            profile == "Default" ? ["default": true] : ["custom": ["_0": ["directoryBasename": profile, "machineID": "C0FFEE00-0000-4000-8000-000000000001"]]]
        }

        var topApps: [Any] = []
        var favorites: [String: [String]] = [:]
        for profile in Self.arcProfiles {
            let favHost = "fav\(favorites.count).\(spacePrefix.lowercased()).example"
            var ids = (0..<10).map { tab("https://\(favHost)/\($0)", "Favori \($0) 🌟") }
            let inner = (0..<3).map { tab("https://\(favHost)/dir/\($0)", "Dans le dossier \($0)") }
            add("FAVDIR-\(profile)", "Groupe", children: inner, data: ["list": [:]])
            ids.append("FAVDIR-\(profile)")
            add("FAV-\(profile)", nil, children: ids, data: ["itemContainer": ["containerType": ["topApps": ["_0": profileKey(profile)]]]])
            topApps += [profileKey(profile), "FAV-\(profile)"]
            favorites[profile] = (0..<10).map { "Favori \($0) 🌟" } + (0..<3).map { "Dans le dossier \($0)" }
        }

        var spaceEntries: [Any] = []
        var expected: [ExpectedSpace] = []
        for index in 0..<spaces {
            let profile = Self.arcProfiles[index % Self.arcProfiles.count]
            // Space 4 shares space 1's name and profile: it must stay a space of its own.
            let title = "\(spacePrefix) \(index == 4 ? 1 : index) ✨"
            let host = "s\(index).\(spacePrefix.lowercased()).example"
            var space = ExpectedSpace(name: index == 4 ? "\(title) 2" : title, icon: "🌐", color: "#5865f2")
            var info: [String: Any] = [:]
            switch index % 3 {
            case 0:
                let red = Double(index) / Double(spaces)
                info = ["iconType": ["emoji_v2": "🚀", "emoji": 128640],
                        "windowTheme": ["primaryColorPalette": ["midTone": ["red": red, "green": 0.5, "blue": 1.2, "alpha": 1, "colorSpace": "extendedSRGB"]]]]
                space.icon = "🚀"
                space.color = String(format: "#%02x%02x%02x", Int(red * 255), Int(0.5 * 255), 255)
            case 1:
                info = ["iconType": ["icon": "briefcase"]]
            default:
                // Older files keep only the code point.
                if index == 5 {
                    info = ["iconType": ["emoji": 128_188]]
                    space.icon = "💼"
                }
            }

            var pinned: [String] = []
            for chain in 0..<chains {
                func folderTitle(_ level: Int) -> String { "Dossier \(chain).\(level) 📁 日本" }
                func page(_ level: Int, _ index: Int) -> String { "Page \(chain).\(level).\(index) café 日本語 🎉" }
                /// Builds the chain from the deepest level up, so each level knows its child folder.
                var child: String?
                for level in stride(from: 6, through: 1, by: -1) {
                    var ids = (0..<4).map { tab("https://\(host)/c\(chain)/l\(level)/\(counter)", page(level, $0)) }
                    if let child { ids.insert(child, at: 2) }
                    if level == 2 {
                        let split = "SPLIT-\(host)-\(chain)"
                        add(split, nil, children: ["Volet A", "Volet B"].map { tab("https://\(host)/split/\(chain)/\(counter)", "\($0) \(chain)") },
                            data: ["splitView": ["layoutOrientation": "horizontal"]])
                        ids.insert(split, at: 3)
                    }
                    if level == 4 { ids.append("MISSING-\(host)-\(chain)") }
                    let folder = "F-\(host)-\(chain)-\(level)"
                    add(folder, folderTitle(level), children: ids, data: ["list": [:]])
                    child = folder
                }
                pinned.append(child!)
                /// A level's children in Lilo: the sixth level is past the depth cap, so its tabs join the fifth in place,
                /// and the split inside the second becomes plain tabs.
                func contents(_ level: Int, depth: Int) -> [String] {
                    let pad = String(repeating: "  ", count: depth)
                    var lines = [page(level, 0), page(level, 1)].map { pad + $0 }
                    if level < 6 {
                        lines += level + 1 > SpaceTab.maxFolderDepth
                            ? contents(level + 1, depth: depth)
                            : [pad + folderTitle(level + 1)] + contents(level + 1, depth: depth + 1)
                    }
                    if level == 2 { lines += ["Volet A", "Volet B"].map { "\(pad)\($0) \(chain)" } }
                    return lines + [page(level, 2), page(level, 3)].map { pad + $0 }
                }
                space.pinnedOutline += [folderTitle(1)] + contents(1, depth: 1)
                space.tabCount += 6 * 4 + 2
            }
            let pinnedPanes = ["Gauche", "Droite"]
            add("PSPLIT-\(host)", nil, children: pinnedPanes.map { tab("https://\(host)/pinned-split/\($0)", $0) },
                data: ["splitView": ["layoutOrientation": "horizontal"]])
            pinned.append("PSPLIT-\(host)")
            space.pinnedOutline += [""] + pinnedPanes.map { "  \($0)" }
            pinned.append(tab("https://\(host)/loose", "Épinglé"))
            space.pinnedOutline.append("Épinglé")
            // Arc keeps an empty title for a tab that never loaded: Lilo shows its URL.
            pinned.append(tab("https://\(host)/untitled", ""))
            space.pinnedOutline.append("https://\(host)/untitled")
            space.tabCount += 4
            // Skipped: no URL, an internal page, an easel, a dangling id, a folder holding itself, a URL already imported.
            add("NOURL-\(host)", "Sans URL", data: ["tab": ["savedTitle": "Sans URL"]])
            add("EASEL-\(host)", "Easel", data: ["easel": ["easelID": "E"]])
            add("CYCLE-\(host)", "Boucle", children: ["CYCLE-\(host)"], data: ["list": [:]])
            pinned += [tab("arc://history", "Historique"), "NOURL-\(host)", "EASEL-\(host)", "DANGLING-\(host)", "CYCLE-\(host)",
                       tab("https://\(host)/loose", "Doublon")]
            add("P-\(host)", nil, children: pinned, data: ["itemContainer": ["containerType": ["spaceItems": ["_0": "S-\(host)"]]]])

            var open = (0..<unpinned).map { tab("https://\(host)/open/\($0)", "Onglet \($0) ü ß 中文") }
            space.unpinnedRoots = (0..<unpinned).map { "Onglet \($0) ü ß 中文" }
            let stacked = ["Haut", "Milieu", "Bas"]
            add("VSPLIT-\(host)", nil, children: stacked.map { tab("https://\(host)/stack/\($0)", $0) },
                data: ["splitView": ["layoutOrientation": "vertical"]])
            let wide = (1...5).map { "Large \($0)" }
            add("WSPLIT-\(host)", nil, children: wide.map { tab("https://\(host)/wide/\($0)", $0) },
                data: ["splitView": ["layoutOrientation": "horizontal"]])
            open += ["VSPLIT-\(host)", "WSPLIT-\(host)"]
            space.unpinnedRoots += ["", "", "Large 5"]
            space.unpinnedFolders = [stacked, Array(wide.prefix(SplitLayout.maxPanes))]
            space.tabCount += unpinned + 8
            add("U-\(host)", nil, children: open, data: ["itemContainer": ["containerType": ["spaceItems": ["_0": "S-\(host)"]]]])

            var entry: [String: Any] = ["id": "S-\(host)", "title": title, "containerIDs": ["unpinned", "U-\(host)", "pinned", "P-\(host)"],
                                        "profile": profileKey(profile)]
            if !info.isEmpty { entry["customInfo"] = info }
            spaceEntries += ["S-\(host)", entry]
            expected.append(space)
        }

        let root: [String: Any] = ["version": 1, "sidebar": ["containers": [["global": [:]], [
            "topAppsContainerIDs": topApps, "spaces": spaceEntries, "items": items
        ]]]]
        let arcRoot = home.appendingPathComponent("Library/Application Support/Arc")
        let userData = arcRoot.appendingPathComponent("User Data")
        for profile in Self.arcProfiles {
            try FileManager.default.createDirectory(at: userData.appendingPathComponent(profile), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: userData.appendingPathComponent("\(profile)/Bookmarks"))
        }
        let cache = Self.arcProfileNames.mapValues { ["name": $0] }
        try JSONSerialization.data(withJSONObject: ["profile": ["info_cache": cache]]).write(to: userData.appendingPathComponent("Local State"))
        try JSONSerialization.data(withJSONObject: root).write(to: arcRoot.appendingPathComponent("StorableSidebar.json"))
        // The first Arc profile's favorites land in the active space, the others in the space named after their profile.
        return (expected, favorites, expected.map(\.tabCount).reduce(0, +) + favorites.values.map(\.count).reduce(0, +))
    }

    /// Folders of 40 bookmarks: a tenth on the bar, nested two deep, the rest under "Other bookmarks".
    private static func chromiumBookmarks(_ count: Int) -> [String: Any] {
        func url(_ index: Int) -> [String: Any] {
            ["type": "url", "name": "Signet \(index) 日本", "url": "https://b\(index / 40).example.com/\(index)"]
        }
        func folder(_ name: String, _ range: Range<Int>) -> [String: Any] {
            ["type": "folder", "name": name, "children": stride(from: range.lowerBound, to: range.upperBound, by: 40).map { start in
                ["type": "folder", "name": "\(name) \(start)", "children": (start..<min(start + 40, range.upperBound)).map(url)] as [String: Any]
            }]
        }
        let bar = count / 10
        return ["roots": ["bookmark_bar": ["children": [folder("Barre", 0..<bar)]], "other": ["children": [folder("Autres", bar..<count)]],
                          "synced": ["children": []]]]
    }

    /// `windows` normal windows of `tabsPerWindow` tabs, each with three navigations (the last one selected): the first 30
    /// pinned, tabs 100 to 599 in groups of ten, every 97th one closed, plus a popup window that is not imported.
    private func writeChromeSession(windows: Int, tabsPerWindow: Int)
        throws -> (pinned: [String], roots: [String], groups: [[String]], tabCount: Int) {
        let profile = home.appendingPathComponent("Library/Application Support/Google/Chrome/Default")
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("Sessions"), withIntermediateDirectories: true)
        var session = SNSSWriter()
        var pinned: [String] = [], roots: [String] = [], groups: [[String]] = []
        var tabCount = 0
        for window in 0..<windows {
            let windowId = Int32(window + 1)
            session.windowType(windowId, 0)
            for index in 0..<tabsPerWindow {
                let tab = Int32(window * tabsPerWindow + index + 1)
                let title = "Onglet \(window).\(index) 日本語 🎉"
                session.tabWindow(windowId, tab: tab, index: Int32(index))
                session.navigations(tab: tab, (0..<3).map { ("https://w\(window).session.example/\(index)/\($0)", $0 == 2 ? title : "Avant \($0)") },
                                    selected: 2)
                if index < 30 {
                    session.pinned(tab)
                    pinned.append(title)
                    tabCount += 1
                    continue
                }
                if index % 97 == 0 {
                    session.tabClosed(tab)
                    continue
                }
                tabCount += 1
                guard (100..<600).contains(index) else {
                    roots.append(title)
                    continue
                }
                let token = UInt64(window * 1000 + (index - 100) / 10 + 1)
                // No group starts on a closed tab, so each one opens on its first index.
                if (index - 100) % 10 == 0 {
                    session.groupMetadata(token, title: "Groupe \(token)", color: Int32(token % 2 == 0 ? 1 : 4))
                    roots.append("Groupe \(token)")
                    groups.append([])
                }
                session.group(tab: tab, token)
                groups[groups.count - 1].append(title)
            }
        }
        session.windowType(99, 1)
        session.tabWindow(99, tab: 99_999, index: 0)
        session.navigations(tab: 99_999, [("https://popup.example/", "Popup")], selected: 0)
        try session.data.write(to: profile.appendingPathComponent("Sessions/Session_13300000000000000"))
        return (pinned, roots, groups, tabCount)
    }

    private func writeChrome(bookmarks: Int, history: Int) throws {
        let profile = home.appendingPathComponent("Library/Application Support/Google/Chrome/Default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: Self.chromiumBookmarks(bookmarks)).write(to: profile.appendingPathComponent("Bookmarks"))
        try DatabaseQueue(path: profile.appendingPathComponent("History").path).write { db in
            try db.execute(sql: """
                CREATE TABLE urls (id INTEGER PRIMARY KEY AUTOINCREMENT, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER DEFAULT 0 NOT NULL,
                    typed_count INTEGER DEFAULT 0 NOT NULL, last_visit_time INTEGER NOT NULL, hidden INTEGER DEFAULT 0 NOT NULL);
                CREATE INDEX urls_url_index ON urls (url);
                CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER NOT NULL, visit_time INTEGER NOT NULL, from_visit INTEGER, transition INTEGER);
                """)
            let urls = try db.makeStatement(sql: "INSERT INTO urls (url, title, visit_count, last_visit_time, hidden) VALUES (?, ?, ?, ?, ?)")
            let visits = try db.makeStatement(sql: "INSERT INTO visits (url, visit_time, transition) VALUES (?, ?, 0)")
            for index in 0..<history {
                let time: Int64 = 13_300_000_000_000_000 + Int64(index) * 1_000_000
                try urls.execute(arguments: ["https://h\(index % 5000).example.com/page/\(index)", "Visite \(index)", index % 9 + 1, time, index % 50 == 0 ? 1 : 0])
                try visits.execute(arguments: [index + 1, time])
            }
        }
        try DatabaseQueue(path: profile.appendingPathComponent("Favicons").path).write { db in
            try db.execute(sql: """
                CREATE TABLE icon_mapping (id INTEGER PRIMARY KEY, page_url LONGVARCHAR NOT NULL, icon_id INTEGER);
                CREATE TABLE favicon_bitmaps (id INTEGER PRIMARY KEY, icon_id INTEGER NOT NULL, last_updated INTEGER DEFAULT 0, image_data BLOB,
                    width INTEGER DEFAULT 0, height INTEGER DEFAULT 0);
                """)
            let png = Data([0x89, 0x50, 0x4E, 0x47] + [UInt8](repeating: 7, count: 600))
            for index in 0..<(bookmarks / 40) {
                try db.execute(sql: "INSERT INTO icon_mapping (page_url, icon_id) VALUES (?, ?)", arguments: ["https://b\(index).example.com/", index])
                try db.execute(sql: "INSERT INTO favicon_bitmaps (icon_id, image_data, width, height) VALUES (?, ?, 32, 32)", arguments: [index, png])
                try db.execute(sql: "INSERT INTO favicon_bitmaps (icon_id, image_data, width, height) VALUES (?, ?, 16, 16)", arguments: [index, png])
            }
        }
    }

    private func writeFirefox(bookmarks: Int, history: Int, cookies: Int) throws {
        let support = home.appendingPathComponent("Library/Application Support/Firefox")
        let profile = support.appendingPathComponent("Profiles/p")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("[Profile0]\nName=p\nIsRelative=1\nPath=Profiles/p\n".utf8).write(to: support.appendingPathComponent("profiles.ini"))
        try DatabaseQueue(path: profile.appendingPathComponent("places.sqlite").path).write { db in
            try db.execute(sql: """
                CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER DEFAULT 0, hidden INTEGER DEFAULT 0,
                    last_visit_date INTEGER);
                CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER DEFAULT NULL, parent INTEGER, position INTEGER,
                    title LONGVARCHAR, guid TEXT);
                CREATE INDEX moz_places_lastvisitdateindex ON moz_places (last_visit_date);
                CREATE INDEX moz_bookmarks_itemindex ON moz_bookmarks (fk, type);
                CREATE INDEX moz_bookmarks_parentindex ON moz_bookmarks (parent, position);
                INSERT INTO moz_bookmarks VALUES (1, 2, NULL, 0, 0, '', 'root________');
                INSERT INTO moz_bookmarks VALUES (2, 2, NULL, 1, 0, 'toolbar', 'toolbar_____');
                INSERT INTO moz_bookmarks VALUES (3, 2, NULL, 1, 1, 'menu', 'menu________');
                """)
            let place = try db.makeStatement(sql: "INSERT INTO moz_places (id, url, title, visit_count, last_visit_date) VALUES (?, ?, ?, ?, ?)")
            for index in 0..<history {
                try place.execute(arguments: [index + 1, "https://f\(index % 5000).example.org/\(index)", "Lieu \(index)", index < bookmarks ? 0 : 1 + index % 5,
                                              index < bookmarks ? nil : 1_700_000_000_000_000 + Int64(index) * 1_000_000])
            }
            let mark = try db.makeStatement(sql: "INSERT INTO moz_bookmarks (id, type, fk, parent, position, title, guid) VALUES (?, ?, ?, ?, ?, ?, ?)")
            var nextId: Int64 = 10
            for start in stride(from: 0, to: bookmarks, by: 40) {
                let folder = nextId
                nextId += 1
                try mark.execute(arguments: [folder, 2, nil, start < bookmarks / 10 ? 2 : 3, start / 40, "Dossier \(start)", "g\(folder)"])
                for index in start..<min(start + 40, bookmarks) {
                    try mark.execute(arguments: [nextId, 1, index + 1, folder, index - start, "Marque \(index)", "g\(nextId)"])
                    nextId += 1
                }
            }
        }
        try DatabaseQueue(path: profile.appendingPathComponent("cookies.sqlite").path).write { db in
            try db.execute(sql: "CREATE TABLE moz_cookies (host TEXT, name TEXT, value TEXT, path TEXT, expiry INTEGER, isSecure INTEGER, isHttpOnly INTEGER, sameSite INTEGER)")
            let cookie = try db.makeStatement(sql: "INSERT INTO moz_cookies VALUES (?, ?, ?, '/', 4102444800000, 1, 0, 1)")
            for index in 0..<cookies { try cookie.execute(arguments: [".c\(index % 2000).example.net", "n\(index)", "v\(index)"]) }
        }
    }

    private func writeSafari(bookmarks: Int, history: Int) throws {
        let safari = home.appendingPathComponent("Library/Safari")
        try FileManager.default.createDirectory(at: safari, withIntermediateDirectories: true)
        func list(_ title: String, _ range: Range<Int>) -> [String: Any] {
            ["Title": title, "WebBookmarkType": "WebBookmarkTypeList", "Children": stride(from: range.lowerBound, to: range.upperBound, by: 40).map { start in
                ["Title": "\(title) \(start)", "WebBookmarkType": "WebBookmarkTypeList", "Children": (start..<min(start + 40, range.upperBound)).map { index in
                    ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://sb\(index / 40).example.com/\(index)",
                     "URIDictionary": ["title": "Favori Safari \(index)"]] as [String: Any]
                }] as [String: Any]
            }]
        }
        let plist: [String: Any] = ["Children": [list("BookmarksBar", 0..<(bookmarks / 10)), list("BookmarksMenu", (bookmarks / 10)..<bookmarks)]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: safari.appendingPathComponent("Bookmarks.plist"))
        try DatabaseQueue(path: safari.appendingPathComponent("History.db").path).write { db in
            try db.execute(sql: """
                CREATE TABLE history_items (id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL UNIQUE, domain_expansion TEXT NULL,
                    visit_count INTEGER NOT NULL);
                CREATE TABLE history_visits (id INTEGER PRIMARY KEY AUTOINCREMENT, history_item INTEGER NOT NULL, visit_time REAL NOT NULL, title TEXT NULL);
                CREATE INDEX history_visits__history_item ON history_visits (history_item);
                CREATE INDEX history_visits__last_visit ON history_visits (visit_time);
                """)
            let items = history / 4
            let item = try db.makeStatement(sql: "INSERT INTO history_items (id, url, visit_count) VALUES (?, ?, 4)")
            let visit = try db.makeStatement(sql: "INSERT INTO history_visits (history_item, visit_time, title) VALUES (?, ?, ?)")
            for index in 0..<items { try item.execute(arguments: [index + 1, "https://sh\(index % 5000).example.com/\(index)"]) }
            for index in 0..<history {
                try visit.execute(arguments: [index % items + 1, 700_000_000 + Double(index), "Visite Safari \(index)"])
            }
        }
    }
}

/// Counts committed transactions on every pool it observes.
private final class CommitCounter: TransactionObserver, @unchecked Sendable {
    private let commits = OSAllocatedUnfairLock(initialState: 0)
    var count: Int { commits.withLock { $0 } }
    func reset() { commits.withLock { $0 = 0 } }
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { false }
    func databaseDidChange(with event: DatabaseEvent) {}
    func databaseDidCommit(_ db: Database) { commits.withLock { $0 += 1 } }
    func databaseDidRollback(_ db: Database) {}
}
