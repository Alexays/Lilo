import WebKit

/// Window context for `TabGroupsBridgeHandler`, supplied lazily by `MainWindowController`: the handler is created in the
/// per-window gap router before any window state exists.
@MainActor
struct TabGroupsContext {
    let tabManager: TabManager
    let applyCommand: (BrowserCommand) throws -> BrowserChangeSet
    /// The active profile's registry, for firing `chrome.tabGroups.on*` events to extensions.
    let registry: ProfileExtensionRegistry?
}

/// `chrome.tabGroups`, `tabs.group`/`ungroup` and `tabs.discard` onto Lilo folders: group ids map to folder UUIDs per session, colors
/// by nearest RGB; a tab arrives as its window position and index in WebKit's ordered lists, which round-trip to its UUID. Also
/// `tabs.details`, the `Tab` fields WebKit lacks, which every tab result asks for.
@MainActor
final class TabGroupsBridgeHandler: GapHandler {
    let gapActions: Set<String> = [
        "tabGroups.query",
        "tabGroups.get",
        "tabGroups.update",
        "tabGroups.move",
        "tabs.group",
        "tabs.ungroup",
        "tabs.discard",
        "tabs.details"
    ]

    /// A window showing the calling extension's profile, from its registry.
    private let contextProvider: (ProfileExtensionRegistry) -> TabGroupsContext?

    /// Chrome's `TAB_GROUP_ID_NONE`. Reported for ungrouped tabs.
    private static let tabGroupIdNone = -1
    /// What Chrome reports for an empty tab, its new tab page.
    private static let newTabURL = "chrome://newtab/"
    private static let newTabTitle = "New Tab"

    // Stable per-session bijection between Chrome integer group ids and Lilo folder UUIDs.
    private var folderIdByGroupId: [Int: UUID] = [:]
    private var groupIdByFolderId: [UUID: Int] = [:]
    private var nextGroupId = 1

    init(
        contextProvider: @escaping (ProfileExtensionRegistry) -> TabGroupsContext?
    ) {
        self.contextProvider = contextProvider
    }

    func handle(_ call: GapCall) async -> Any? {
        let registry = call.registry
        if call.action == "tabs.details" { return tabDetails(call) }
        guard let context = contextProvider(registry) else {
            return BridgeError("No active window for tabGroups")
        }
        let tabManager = context.tabManager

        switch call.action {
        case "tabGroups.query":
            return queryGroups(call, tabManager: tabManager)

        case "tabGroups.get":
            guard let groupId = call.int("groupId"),
                  let folder = folder(forGroup: groupId, tabManager: tabManager) else {
                return BridgeError("No tab group with id \(call.int("groupId") ?? -1)")
            }
            return ["group": groupDict(folder)]

        case "tabGroups.update":
            return updateGroup(call, context: context)

        case "tabGroups.move":
            // Reordering a folder maps onto Lilo's sectioned sidebar tree, which has no single linear
            // index, so the move is a no-op that echoes the group back rather than erroring.
            guard let groupId = call.int("groupId"),
                  let folder = folder(forGroup: groupId, tabManager: tabManager) else {
                return BridgeError("No tab group with id \(call.int("groupId") ?? -1)")
            }
            return ["group": groupDict(folder)]

        case "tabs.group":
            return groupTabs(call, context: context, uuids: tabUUIDs(call, registry: registry).compactMap { $0 })

        case "tabs.ungroup":
            return ungroupTabs(context: context, uuids: tabUUIDs(call, registry: registry).compactMap { $0 })

        case "tabs.discard":
            guard let id = tabUUIDs(call, registry: registry).first ?? nil, tabManager.engineTab(for: id) != nil else {
                return BridgeError("Cannot discard a tab that is not loaded")
            }
            tabManager.discardEngines([id])
            return tabManager.engineTab(for: id) == nil ? nil : BridgeError("Cannot discard a tab on screen")

        default:
            return BridgeError("Unhandled tabGroups action \(call.action)")
        }
    }

    // MARK: - tabGroups.query

    private func queryGroups(_ call: GapCall, tabManager: TabManager) -> [String: Any] {
        guard let spaceId = tabManager.currentSpaceId else { return ["groups": []] }
        let titleFilter = call.string("title")
        let colorFilter = call.string("color")
        let collapsedFilter = call.payload["collapsed"] != nil ? call.bool("collapsed") : nil

        let groups = tabManager.folders(forSpace: spaceId)
            .filter { folder in
                if let titleFilter, folder.name != titleFilter { return false }
                if let colorFilter, Self.chromeColor(forHex: folder.color) != colorFilter { return false }
                if let collapsedFilter, folder.isCollapsed != collapsedFilter { return false }
                return true
            }
            .map { groupDict($0) }
        return ["groups": groups]
    }

    // MARK: - tabGroups.update

    private func updateGroup(_ call: GapCall, context: TabGroupsContext) -> Any? {
        guard let groupId = call.int("groupId"),
              let folder = folder(forGroup: groupId, tabManager: context.tabManager) else {
            return BridgeError("No tab group with id \(call.int("groupId") ?? -1)")
        }
        let newName = call.string("title") ?? folder.name
        let newColor = call.string("color").flatMap { Self.hex(forChromeColor: $0) } ?? folder.color
        let newCollapsed = call.payload["collapsed"] != nil ? call.bool("collapsed") : folder.isCollapsed

        if let updated = applied(
            .updateFolder(spaceId: folder.spaceId, folderId: folder.id, name: newName, color: newColor, isCollapsed: newCollapsed),
            context: context
        )?.foldersById[folder.id] {
            let dict = groupDict(updated)
            emitGroupEvent("onUpdated", group: dict, context: context)
            return ["group": dict]
        }
        return BridgeError("Failed to update tab group")
    }

    // MARK: - tabs.group / ungroup

    private func groupTabs(_ call: GapCall, context: TabGroupsContext, uuids: [UUID]) -> Any? {
        let tabManager = context.tabManager
        guard let spaceId = tabManager.currentSpaceId else { return BridgeError("No active space") }
        guard !uuids.isEmpty else { return BridgeError("No tabs to group") }
        let sourceFolderIds = currentFolderIds(of: uuids, spaceId: spaceId, tabManager: tabManager)

        // Resolve the destination folder: an existing group, or a freshly minted one.
        let folderId: UUID
        var createdFolder: TabFolder?
        if let groupId = call.int("groupId"), groupId != Self.tabGroupIdNone {
            guard let resolved = folder(forGroup: groupId, tabManager: tabManager)?.id else {
                return BridgeError("No tab group with id \(groupId)")
            }
            folderId = resolved
        } else {
            let folder = TabFolder(spaceId: spaceId, name: "", color: Self.hex(forChromeColor: "grey") ?? "#9aa0a6")
            guard let created = applied(.createFolder(spaceId: spaceId, folder: folder, section: .unpinned), context: context)?
                .foldersById[folder.id] else {
                return BridgeError("Failed to create tab group")
            }
            folderId = folder.id
            createdFolder = created
        }

        moveTabs(uuids, toFolder: folderId, spaceId: spaceId, context: context)
        // Chrome auto-removes a group once its last tab leaves it.
        deleteEmptyFolders(sourceFolderIds.subtracting([folderId]), spaceId: spaceId, context: context)
        if let createdFolder {
            // Report the new group with its post-grouping state (name/color may be defaults).
            let latest = tabManager.folder(id: folderId) ?? createdFolder
            emitGroupEvent("onCreated", group: groupDict(latest), context: context)
        }
        return ["groupId": groupId(forFolder: folderId)]
    }

    private func moveTabs(_ uuids: [UUID], toFolder folderId: UUID?, spaceId: UUID, context: TabGroupsContext) {
        for uuid in uuids {
            _ = applied(
                .moveSidebarItem(
                    spaceId: spaceId,
                    kind: .tab,
                    itemId: uuid,
                    parentFolderId: folderId,
                    section: .unpinned,
                    insert: .anchored(fallbackIndex: Int.max, insertBeforeId: nil, insertAfterId: nil)
                ),
                context: context
            )
        }
    }

    private func ungroupTabs(context: TabGroupsContext, uuids: [UUID]) -> Any? {
        let tabManager = context.tabManager
        guard let spaceId = tabManager.currentSpaceId else { return BridgeError("No active space") }
        let sourceFolderIds = currentFolderIds(of: uuids, spaceId: spaceId, tabManager: tabManager)
        moveTabs(uuids, toFolder: nil, spaceId: spaceId, context: context)
        // Chrome auto-removes a group once its last tab leaves it.
        deleteEmptyFolders(sourceFolderIds, spaceId: spaceId, context: context)
        return [:]
    }

    /// The set of folders the given tabs currently belong to (their Chrome "source groups").
    private func currentFolderIds(of tabIds: [UUID], spaceId: UUID, tabManager: TabManager) -> Set<UUID> {
        let tabs = tabManager.tabs(forSpace: spaceId)
        return Set(tabIds.compactMap { id in tabs.first { $0.id == id }?.groupId })
    }

    /// Delete any of `folderIds` that no longer contain a tab, matching Chrome's empty-group cleanup.
    private func deleteEmptyFolders(_ folderIds: Set<UUID>, spaceId: UUID, context: TabGroupsContext) {
        guard !folderIds.isEmpty else { return }
        let remaining = context.tabManager.tabs(forSpace: spaceId)
        for folderId in folderIds where !remaining.contains(where: { $0.groupId == folderId }) {
            // Build the removed-group payload before the folder is gone, then fire onRemoved.
            let removed = context.tabManager.folder(id: folderId).map { groupDict($0) }
            if applied(.deleteFolder(spaceId: spaceId, folderId: folderId), context: context) != nil, let removed {
                emitGroupEvent("onRemoved", group: removed, context: context)
            }
        }
    }

    // MARK: - tabs.details

    /// For each `{windowPosition, index}` of `tabs`: its `groupId`, `discarded`, `frozen` and `lastAccessed`, null for a tab Lilo
    /// does not hold, and with `tabs`, the url and title of the tabs `reveal` lists, which WebKit leaves empty for hosts the
    /// extension may not access. An empty tab reads as Chrome's new tab page.
    private func tabDetails(_ call: GapCall) -> [Any] {
        let positions = call.payload["tabs"] as? [[String: Any]] ?? []
        let reveal = Set(call.payload["reveal"] as? [Int] ?? [])
        let context = reveal.isEmpty ? nil : call.context.flatMap { $0.hasPermission(.tabs) ? $0 : nil }
        return call.registry.tabAdapters(atPositions: positions, extensionId: call.extensionId).enumerated().map { index, adapter -> Any in
            guard let adapter, let tab = adapter.tabManager?.tab(for: adapter.tabId) else { return NSNull() }
            let engine = adapter.engineTab
            var details: [String: Any] = [
                "groupId": tab.groupId.map(groupId(forFolder:)) ?? Self.tabGroupIdNone,
                "discarded": engine == nil,
                "frozen": engine?.isFrozen ?? false
            ]
            if let accessed = tab.lastActiveAt ?? engine?.createdAt { details["lastAccessed"] = accessed.timeIntervalSince1970 * 1000 }
            if let context, reveal.contains(index) {
                let title = adapter.title(for: context) ?? ""
                let url = adapter.url(for: context)
                details["url"] = url?.absoluteString ?? Self.newTabURL
                details["title"] = url == nil && title.isEmpty ? Self.newTabTitle : title
            }
            return details
        }
    }

    // MARK: - State command plumbing

    private func applied(_ command: BrowserCommand, context: TabGroupsContext) -> BrowserSpaceChange? {
        do {
            return try context.applyCommand(command).changedState
        } catch {
            return nil
        }
    }

    /// Fire a `chrome.tabGroups.*` event to every extension holding the `tabGroups` permission. Note:
    /// the payload's `windowId` is `-1` for pushed events (WebKit's window id isn't known natively and
    /// can't be JS-stamped on a push the way `query`/`get` results are).
    private func emitGroupEvent(_ event: String, group: [String: Any], context: TabGroupsContext) {
        context.registry?.emitGapEvent("tabGroups", event, args: [group], requiredPermission: "tabGroups")
    }

    // MARK: - Identity translation

    /// The Lilo tab behind each `{windowPosition, index}` pair of `message["tabs"]`, nil when unknown.
    private func tabUUIDs(_ call: GapCall, registry: ProfileExtensionRegistry) -> [UUID?] {
        let positions = call.payload["tabs"] as? [[String: Any]] ?? []
        return registry.tabIds(atPositions: positions, extensionId: call.extensionId)
    }

    private func groupId(forFolder folderId: UUID) -> Int {
        if let existing = groupIdByFolderId[folderId] { return existing }
        let id = nextGroupId
        nextGroupId += 1
        groupIdByFolderId[folderId] = id
        folderIdByGroupId[id] = folderId
        return id
    }

    private func folder(forGroup groupId: Int, tabManager: TabManager) -> TabFolder? {
        guard let folderId = folderIdByGroupId[groupId] else { return nil }
        return tabManager.folder(id: folderId)
    }

    /// Chrome `TabGroup` shape. `windowId` is a placeholder: the JS augmentation overwrites it with
    /// the live `chrome.windows.getCurrent().id`, which only the WebKit side knows.
    private func groupDict(_ folder: TabFolder) -> [String: Any] {
        [
            "id": groupId(forFolder: folder.id),
            "title": folder.name,
            "color": Self.chromeColor(forHex: folder.color),
            "collapsed": folder.isCollapsed,
            "windowId": -1
        ]
    }

    // MARK: - Color mapping

    /// Chrome's fixed tab-group palette to representative hex (Chromium's group color values).
    private static let palette: [(name: String, rgb: (Int, Int, Int))] = [
        ("grey", (0x9a, 0xa0, 0xa6)),
        ("blue", (0x1a, 0x73, 0xe8)),
        ("red", (0xd9, 0x30, 0x25)),
        ("yellow", (0xf9, 0xab, 0x00)),
        ("green", (0x18, 0x80, 0x38)),
        ("pink", (0xd0, 0x18, 0x84)),
        ("purple", (0xa1, 0x42, 0xf4)),
        ("cyan", (0x00, 0x7b, 0x83)),
        ("orange", (0xfa, 0x90, 0x3e))
    ]

    static func hex(forChromeColor name: String) -> String? {
        guard let rgb = palette.first(where: { $0.name == name.lowercased() })?.rgb else { return nil }
        return String(format: "#%02x%02x%02x", rgb.0, rgb.1, rgb.2)
    }

    /// Nearest Chrome palette color to an arbitrary folder hex (squared RGB distance). Folders can
    /// hold any hex (e.g. the default folder color `#5865f2`), so we always answer with a valid name.
    static func chromeColor(forHex hex: String) -> String {
        guard let rgb = parseHex(hex) else { return "grey" }
        return palette.min(by: { distance($0.rgb, rgb) < distance($1.rgb, rgb) })?.name ?? "grey"
    }

    private static func parseHex(_ hex: String) -> (Int, Int, Int)? {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let value = Int(s, radix: 16) else { return nil }
        return ((value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff)
    }

    private static func distance(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
        let dr = a.0 - b.0, dg = a.1 - b.1, db = a.2 - b.2
        return dr * dr + dg * dg + db * db
    }
}
