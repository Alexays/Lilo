import XCTest
@testable import Lilo

/// `TabGroupsBridgeHandler` bridges chrome.tabGroups onto Lilo's tab-folder model: the Chrome color palette mapping,
/// the fail-closed behavior when no window context is available, and the window each group names.
@MainActor
final class TabGroupsBridgeHandlerTests: XCTestCase {

    func test_handledActions() {
        let handler = TabGroupsBridgeHandler(contextProvider: { _ in nil })
        XCTAssertEqual(handler.gapActions, [
            "tabGroups.query", "tabGroups.get", "tabGroups.update", "tabGroups.move",
            "tabs.group", "tabs.ungroup", "tabs.discard", "tabs.details"
        ])
    }

    func test_hexForChromeColor_knownNames() {
        XCTAssertEqual(TabGroupsBridgeHandler.hex(forChromeColor: "cyan"), "#007b83")
        XCTAssertEqual(TabGroupsBridgeHandler.hex(forChromeColor: "RED"), "#d93025") // case-insensitive
        XCTAssertNil(TabGroupsBridgeHandler.hex(forChromeColor: "mauve"))            // not a Chrome color
    }

    func test_chromeColorForHex_nearestMatch() {
        XCTAssertEqual(TabGroupsBridgeHandler.chromeColor(forHex: "#d93025"), "red")    // exact palette hit
        XCTAssertEqual(TabGroupsBridgeHandler.chromeColor(forHex: "#ff0000"), "red")    // nearest to pure red
        XCTAssertEqual(TabGroupsBridgeHandler.chromeColor(forHex: "#00ff00"), "green")  // nearest to pure green
        XCTAssertEqual(TabGroupsBridgeHandler.chromeColor(forHex: "garbage"), "grey")   // unparseable falls back to a safe default
    }

    func test_chromeColorForHex_liloDefaultFolderColorMapsToAValidName() {
        // Lilo's default folder color sits between blue and purple; it must still map to a real Chrome color name.
        let name = TabGroupsBridgeHandler.chromeColor(forHex: "#5865f2")
        XCTAssertTrue(["blue", "purple"].contains(name), "expected blue/purple, got \(name)")
    }

    func test_colorRoundTripsThroughTheChromePalette() {
        for color in ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"] {
            let hex = try? XCTUnwrap(TabGroupsBridgeHandler.hex(forChromeColor: color))
            XCTAssertEqual(TabGroupsBridgeHandler.chromeColor(forHex: hex ?? ""), color, "round-trip failed for \(color)")
        }
    }

    func test_noWindowContext_failsClosed() async throws {
        let handler = TabGroupsBridgeHandler(contextProvider: { _ in nil })
        let msg = try XCTUnwrap(BridgeMessage(dictionary: ["action": "tabGroups.query"]))
        let result = await handler.handle(msg)
        XCTAssertTrue(result is BridgeError, "expected a BridgeError when no window is active")
    }

    /// Each group names its own space's window by its place in the caller's `windows.getAll()`, the window focused last
    /// first, in `query` answers, which cover every window, and in events alike.
    func test_groupsNameTheWindowOfTheirSpace() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        let registry = try context.profileContexts.context(for: profileId).extensions
        let window = makeTestWindow(context, showing: space.id)
        defer { window.close() }
        window.setupExtensions()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tab-groups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Groups", "version": "1.0", "permissions": ["tabGroups"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"))
        try await registry.load(from: directory)
        let extensionId = try XCTUnwrap(registry.loadedExtensions.first?.id)

        try window.applyBrowserCommand(.createFolder(spaceId: space.id, folder: TabFolder(spaceId: space.id, name: "First", color: "#1a73e8"), section: .unpinned))
        let other = try context.spaceManager.createSpace(name: "T", profileId: profileId)
        window.switchToSpace(other.id)
        try window.applyBrowserCommand(.createFolder(spaceId: other.id, folder: TabFolder(spaceId: other.id, name: "Shown", color: "#1a73e8"), section: .unpinned))
        try window.applyBrowserCommand(.createFolder(spaceId: space.id, folder: TabFolder(spaceId: space.id, name: "Behind", color: "#1a73e8"), section: .unpinned))
        let answer = await context.engineFactory.gapRouter.route(
            namespace: "tabGroups", method: "query", params: [:], extensionId: extensionId, fromWorker: true, registry: registry
        )

        let positions = { (groups: [[String: Any]]) in
            Dictionary(uniqueKeysWithValues: groups.map { ($0["title"] as? String ?? "", $0["windowPosition"] as? Int ?? -9) })
        }
        let groups = try XCTUnwrap((answer.result as? [String: Any])?["groups"] as? [[String: Any]])
        let created = registry.gapEvents.undelivered(to: extensionId).filter { $0.event == "onCreated" }.compactMap { $0.args.first as? [String: Any] }
        XCTAssertEqual(positions(groups), ["Shown": 0, "First": 1, "Behind": 1])
        XCTAssertEqual(positions(created), ["First": 0, "Shown": 0, "Behind": 1])
        XCTAssertNil(groups.first?["windowId"], "only WebKit knows window ids")
    }

    @MainActor
    private struct GroupsCaller {
        let window: MainWindowController
        let registry: ProfileExtensionRegistry
        let extensionId: String
        let spaceId: UUID

        func call(_ namespace: String, _ method: String, _ params: [String: Any] = [:]) async -> (result: Any?, error: String?) {
            await window.context.engineFactory.gapRouter.route(
                namespace: namespace, method: method, params: params, extensionId: extensionId, fromWorker: true, registry: registry
            )
        }
    }

    /// A window on a new space of a new profile, whose extension holds `tabGroups`.
    private func groupsCaller(in browserContext: TemporaryBrowserContext) async throws -> GroupsCaller {
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        let registry = try context.profileContexts.context(for: profileId).extensions
        let window = makeTestWindow(context, showing: space.id)
        window.setupExtensions()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tab-groups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Groups", "version": "1.0", "permissions": ["tabGroups"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"))
        try await registry.load(from: directory)
        return GroupsCaller(window: window, registry: registry, extensionId: try XCTUnwrap(registry.loadedExtensions.first?.id), spaceId: space.id)
    }

    /// A group id names a folder of the caller's windows only, never one of another profile, whose ids count from the same 1.
    func test_aGroupOfAnotherProfileIsNoGroupOfTheCaller() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let mine = try await groupsCaller(in: browserContext)
        let other = try await groupsCaller(in: browserContext)
        try other.window.applyBrowserCommand(.createFolder(
            spaceId: other.spaceId, folder: TabFolder(spaceId: other.spaceId, name: "Theirs", color: "#1a73e8"), section: .unpinned
        ))
        let theirs = await other.call("tabGroups", "query")
        let groupId = try XCTUnwrap(((theirs.result as? [String: Any])?["groups"] as? [[String: Any]])?.first?["id"] as? Int)

        let read = await mine.call("tabGroups", "get", ["groupId": groupId])
        let renamed = await mine.call("tabGroups", "update", ["groupId": groupId, "title": "Mine"])

        XCTAssertEqual(read.error, "No tab group with id \(groupId)")
        XCTAssertEqual(renamed.error, "No tab group with id \(groupId)")
        XCTAssertEqual(other.window.tabManager.folders(forSpace: other.spaceId).map(\.name), ["Theirs"])
    }

    /// `tabs.group` and `ungroup` act in the space of the tabs, shown or not, and tabs of two spaces make no group.
    func test_tabsGroupAndUngroupActInTheSpaceOfTheTabs() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let caller = try await groupsCaller(in: browserContext)
        let window = caller.window
        let behind = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "about:blank")))
        let shown = try browserContext.context.spaceManager.createSpace(name: "T", profileId: try XCTUnwrap(window.profileContext?.profileId))
        window.switchToSpace(shown.id)
        let front = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "about:blank")))
        let position = { (id: UUID) throws -> [String: Int] in
            let adapter = try XCTUnwrap(window.tabManager.browserStateStore?.tabAdapter(forTab: id))
            return try XCTUnwrap(caller.registry.tabPosition(of: adapter, extensionId: caller.extensionId))
        }

        let mixed = await caller.call("tabs", "group", ["tabs": [try position(behind.id), try position(front.id)]])
        let grouped = await caller.call("tabs", "group", ["tabs": [try position(behind.id)]])
        let groupId = try XCTUnwrap((grouped.result as? [String: Any])?["groupId"] as? Int)

        XCTAssertNotNil(mixed.error, "tabs of two windows make no group")
        XCTAssertEqual(window.tabManager.folders(forSpace: shown.id), [], "nothing lands in the space shown")
        let folder = try XCTUnwrap(window.tabManager.folders(forSpace: caller.spaceId).first)
        XCTAssertEqual(window.tabManager.tabs(forSpace: caller.spaceId).first { $0.id == behind.id }?.groupId, folder.id)

        let regrouped = await caller.call("tabs", "group", ["tabs": [try position(front.id)], "groupId": groupId])
        let ungrouped = await caller.call("tabs", "ungroup", ["tabs": [try position(behind.id)]])

        XCTAssertNotNil(regrouped.error, "a tab joins no group of another window")
        XCTAssertNil(ungrouped.error)
        XCTAssertEqual(window.tabManager.folders(forSpace: caller.spaceId), [], "the emptied group goes")
        XCTAssertNil(window.tabManager.tabs(forSpace: caller.spaceId).first { $0.id == behind.id }?.groupId)
    }
}
