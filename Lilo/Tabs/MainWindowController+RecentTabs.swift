// The recent tabs switcher: Control-Tab walks the window's tabs by last use, across its Spaces.

import AppKit

extension MainWindowController {
    /// Rows the switcher lists; the panel shows about ten and scrolls through the rest.
    static let recentTabsLimit = 20
    private static let recentTabsKept = 100

    /// Moves `id` to the front of the window's recent tabs, dating the tab it replaces.
    func noteRecentTab(_ id: UUID) {
        guard recentTabs.first?.id != id else { return }
        let now = Date()
        if !recentTabs.isEmpty { recentTabs[0].leftAt = now }
        recentTabs.removeAll { $0.id == id }
        recentTabs.insert((id, now), at: 0)
        if recentTabs.count > Self.recentTabsKept { recentTabs.removeLast() }
    }

    /// The switcher's rows, current tab first: the window's recent tabs, then the current Space's others by last use and in
    /// sidebar order. Closed tabs are left out, and so are other Spaces' tabs from a private Space, and private and Agents
    /// Space tabs from elsewhere.
    func recentTabRows() -> [[String: Any]] {
        guard let currentSpaceId = tabManager.currentSpaceId, let spaceManager = context.spaceManager else { return [] }
        let spaces = Dictionary(spaceManager.spaces.map { ($0.id, $0) }) { first, _ in first }
        let agentsSpaceId = context.settingsStore?.agentsSpaceId
        let inPrivateSpace = spaces[currentSpaceId]?.isPrivate == true
        var rows: [[String: Any]] = []
        var seen = Set<UUID>()

        func add(_ id: UUID, leftAt: Date?) {
            guard rows.count < Self.recentTabsLimit, seen.insert(id).inserted,
                  let stored = context.browserState.durableTab(for: id), !stored.tab.isClosed,
                  let space = spaces[stored.spaceId],
                  space.id == currentSpaceId || (!inPrivateSpace && !space.isPrivate && space.id != agentsSpaceId) else { return }
            let tab = context.browserState.runtimeOverlay.applied(to: stored.tab)
            rows.append([
                "id": id.uuidString, "title": tab.customTitle ?? tab.title, "url": tab.url?.absoluteString ?? "",
                "faviconDataURL": tab.faviconDataURL ?? "", "kind": tab.kind.rawValue,
                "cwd": tab.cwd ?? "", "terminalState": tab.terminalState, "terminalCommand": tab.terminalCommand,
                "spaceName": space.name, "leftAt": (leftAt?.timeIntervalSince1970 ?? 0) * 1000
            ])
        }

        if let activeId = tabManager.activeOpenTabId { add(activeId, leftAt: nil) }
        for entry in recentTabs { add(entry.id, leftAt: entry.leftAt) }
        for id in context.browserState.spaceTabState(forSpace: currentSpaceId)?.activationHistory ?? [] { add(id, leftAt: nil) }
        for tab in tabManager.currentTabs { add(tab.id, leftAt: nil) }
        return rows
    }

    /// Opens the switcher on the previous tab, or on the oldest one going backwards. It stays open while `modifiers` are held.
    func openTabSwitcher(holding modifiers: NSEvent.ModifierFlags, backwards: Bool) {
        let rows = recentTabRows()
        guard rows.count > 1 else { return }
        tabSwitcherModifiers = modifiers.intersection([.control, .option, .command])
        bridgeRouter.send(event: "tabSwitcherOpened", data: ["tabs": rows, "selected": backwards ? rows.count - 1 : 1])
    }

    /// The chrome activates the selected tab when `commit`, else only hides the panel.
    func closeTabSwitcher(commit: Bool) {
        tabSwitcherModifiers = nil
        bridgeRouter.send(event: "tabSwitcherClosed", data: ["commit": commit])
    }

    /// Keys while the switcher is open: its shortcuts and the arrows move the selection, Return opens it, Escape cancels, and
    /// letting go of the held modifiers opens it. Every key press stays out of the page meanwhile.
    func handleTabSwitcherEvent(_ event: NSEvent) -> Bool {
        guard let held = tabSwitcherModifiers else { return false }
        if !event.modifierFlags.contains(held) {
            // A keyDown without them means their release never came: settle it first, the key then goes on as usual.
            closeTabSwitcher(commit: true)
            return false
        }
        guard event.type == .keyDown else { return event.type == .keyUp }
        switch KeyboardShortcuts.action(for: event) {
        case "tab.recentNext": bridgeRouter.send(event: "tabSwitcherMoved", data: ["by": 1])
        case "tab.recentPrevious": bridgeRouter.send(event: "tabSwitcherMoved", data: ["by": -1])
        default:
            switch event.keyCode {
            case 125: bridgeRouter.send(event: "tabSwitcherMoved", data: ["by": 1])
            case 126: bridgeRouter.send(event: "tabSwitcherMoved", data: ["by": -1])
            case 36, 76: closeTabSwitcher(commit: true)
            case 53: closeTabSwitcher(commit: false)
            default: break
            }
        }
        return true
    }

    /// Shows a tab the switcher picked, switching Space when it lives in another one.
    func switchToRecentTab(_ id: UUID) {
        guard let spaceId = context.browserState.durableTab(for: id)?.spaceId else { return }
        if spaceId != tabManager.currentSpaceId {
            // The Space switch first shows that Space's own tab, which the user never meant to visit.
            let recent = recentTabs
            requestSpaceSwitch(id: spaceId)
            recentTabs = recent
        }
        activateTabStateFirst(id: id)
        if tabManager.activeOpenTabId == id { noteRecentTab(id) }
    }
}
