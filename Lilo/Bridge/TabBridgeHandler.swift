import AppKit
import Foundation
import ImageIO
import LocalAuthentication
import OSLog
import UniformTypeIdentifiers

struct SidebarDropInsertParser {
    enum Parsed {
        case group(sourceTabId: UUID, targetTabId: UUID)
        case insert(Insert)
    }

    enum Section: Equatable {
        case tree(TabTreeItem.Section)
        case bookmarked
    }

    struct Insert: Equatable {
        let kind: TabTreeItem.Kind
        let id: UUID
        let section: Section
        let parentFolderId: UUID?
        let fallbackIndex: Int
        let insertBeforeId: UUID?
        let insertAfterId: UUID?
    }

    static func parse(_ message: BridgeMessage) -> Parsed? {
        switch message.string("type", default: "") {
        case "group":
            guard let sourceTabId = message.uuid("sourceTabId"),
                  let targetTabId = message.uuid("targetTabId") else {
                return nil
            }
            return .group(sourceTabId: sourceTabId, targetTabId: targetTabId)

        case "insert":
            return parseInsert(message).map(Parsed.insert)

        default:
            return nil
        }
    }

    private static func parseInsert(_ message: BridgeMessage) -> Insert? {
        guard let rawKind = message.string("kind"),
              let kind = TabTreeItem.Kind(rawValue: rawKind),
              let id = message.uuid("id"),
              let rawSection = message.string("section"),
              let fallbackIndex = message.int("fallbackIndex") else {
            return nil
        }

        let parentFolderId = message.uuid("parentFolderId")
        let section: Section
        if rawSection == "bookmarked" {
            guard kind == .tab, parentFolderId == nil else { return nil }
            section = .bookmarked
        } else {
            guard let treeSection = TabTreeItem.Section(rawValue: rawSection) else { return nil }
            section = .tree(treeSection)
        }
        return Insert(
            kind: kind,
            id: id,
            section: section,
            parentFolderId: parentFolderId,
            fallbackIndex: fallbackIndex,
            insertBeforeId: message.uuid("insertBeforeId"),
            insertAfterId: message.uuid("insertAfterId")
        )
    }
}

/// Handles all tab-related bridge messages from the Svelte chrome UI.
@MainActor
final class TabBridgeHandler: BridgeHandler {
    private static let logger = Logger(liloCategory: "tab-bridge")

    let handledActions: Set<String> = [
        "createTab",
        "closeTab",
        "switchTab",
        "switchToRecentTab",
        "claimTab",
        "moveTabToNewWindow",
        "unpinTab",
        "bookmarkTab",
        "unbookmarkTab",
        "renameTab",
        "setTabHomeURL",
        "returnTabHome",
        "muteTab",
        "unmuteTab",
        "controlMedia",
        "controlCall",
        "shareTabInstead",
        "stopTabShare",
        "getMediaActivity",
        "restoreClosedTab",
        "clearUnpinnedTabs",
        "loadArchivedTabs",
        "restoreArchivedTabs",
        "clearArchivedTabs",
        "navigate",
        "goBack",
        "goForward",
        "openHistoryInNewTab",
        "reload",
        "showCachedCopy",
        "reportUnresponsivePage",
        "stopLoading",
        "screenshotPage",
        "editCapture",
        "releaseCapture",
        "openPasswordsApp",
        "translatePage",
        "showFindBar",
        "toggleReader",
        "copyPageURL",
        "togglePinActiveTab",
        "duplicateActiveTab",
        "viewPageSource",
        "savePageAs",
        "newSplitView",
        "newTerminal",
        "runInTerminal",
        "terminalCompletions",
        "revealTerminal",
        "answerTerminal",
        "restoreClosedTerminal",
        "showNextWaitingTerminal",
        "showChanges",
        "splitTab",
        "splitURL",
        "peekURL",
        "closeSplitView",
        "zoomIn",
        "zoomOut",
        "zoomReset",
        "findInPage",
        "findNext",
        "findPrevious",
        "dismissFind",
        "updateTabFolder",
        "deleteTabFolder",
        "setTabFolderCollapsed",
        "setTabFolderLock",
        "unlockTabFolder",
        "lockTabFolder",
        "beginTabFolderLockSetup",
        "changeTabFolderPassword",
        "removeTabFolderLock",
        "setTabFolderBiometrics",
        "commitSidebarDrop",
        "requestTabPreview"
    ]

    private weak var tabManager: TabManager?
    private weak var windowController: MainWindowController?
    private let stateCommandHandler: (BrowserCommand) throws -> BrowserChangeSet
    /// Newest query wins: a superseded keystroke's completions never reach the chrome.
    private var inFlightCompletionsTask: Task<Void, Never>?

    init(
        tabManager: TabManager,
        windowController: MainWindowController,
        stateCommandHandler: @escaping (BrowserCommand) throws -> BrowserChangeSet
    ) {
        self.tabManager = tabManager
        self.windowController = windowController
        self.stateCommandHandler = stateCommandHandler
    }

    func handle(message: BridgeMessage) async -> Any? {
        guard let tabManager else { return nil }

        switch message.action {

        case "createTab":
            windowController?.createTabStateFirst(url: typedURL(message), activate: !message.bool("background"))

        case "closeTab":
            if let id = message.uuid("id") { windowController?.closeTabStateFirst(id: id) }

        case "switchTab":
            withTabContext(message) { tab, spaceId in
                guard tryApplyStateCommand(.activateTab(spaceId: spaceId, tabId: tab.id)) != nil else { return }
                tabManager.activateTabRuntime(id: tab.id)
            }

        case "switchToRecentTab":
            if let id = message.uuid("id") { windowController?.switchToRecentTab(id) }

        case "claimTab":
            withTabContext(message) { tab, _ in windowController?.reclaimDisplayedTab(tab.id) }

        case "moveTabToNewWindow":
            withTabContext(message) { tab, _ in
                let point = message.double("screenX").flatMap { x in message.double("screenY").map { NSPoint(x: x, y: $0) } }
                windowController?.moveTabToNewWindow(tab.id, droppedAt: point)
            }

        case "unpinTab":
            withTabContext(message) { tab, spaceId in
                _ = tryApplyStateCommand(.setPinned(spaceId: spaceId, tabId: tab.id, isPinned: false))
            }

        case "bookmarkTab", "unbookmarkTab":
            withTabContext(message) { tab, spaceId in
                _ = tryApplyStateCommand(.setBookmarked(spaceId: spaceId, tabId: tab.id, isBookmarked: message.action == "bookmarkTab"))
            }

        case "renameTab":
            withTabContext(message) { tab, spaceId in
                _ = tryApplyStateCommand(.renameTab(spaceId: spaceId, tabId: tab.id, title: message.string("title", default: "")))
            }

        case "setTabHomeURL":
            withTabContext(message) { tab, spaceId in
                guard tab.isPinned || tab.isBookmarked,
                      let url = message.string("url").flatMap(URL.init(string:)),
                      ["http", "https", "file"].contains(url.scheme?.lowercased()) else { return }
                let wasHome = !tab.isClosed && tab.matchesHomeURL(tab.url)
                guard tryApplyStateCommand(.setTabHomeURL(spaceId: spaceId, tabId: tab.id, url: url)) != nil else { return }
                // A tab sitting at its home page follows it there; one away from home stays on its page.
                if wasHome, url != tab.url { tabManager.load(url, inTab: tab.id) }
            }

        case "returnTabHome":
            withTabContext(message) { tab, _ in
                guard tab.isPinned || tab.isBookmarked, let home = tab.homeURL else { return }
                tabManager.load(home, inTab: tab.id)
            }

        case "muteTab", "unmuteTab":
            if let id = message.uuid("id") { tabManager.setTabMuted(id: id, muted: message.action == "muteTab") }

        case "controlMedia":
            if let id = message.uuid("id") { windowController?.controlMedia(tabId: id, action: message.string("action", default: "")) }

        case "shareTabInstead":
            if let id = message.uuid("tabId") { windowController?.shareTabInstead(token: message.string("token", default: ""), tabId: id) }

        case "stopTabShare":
            windowController?.stopTabShare(token: message.string("token", default: ""))

        case "controlCall":
            if let id = message.uuid("id") { windowController?.controlCall(tabId: id, action: message.string("action", default: "")) }

        case "getMediaActivity":
            // A loading window has nothing yet: forget what it was sent so it gets the list.
            if let windowController {
                windowController.context.sentMediaActivity[ObjectIdentifier(windowController)] = nil
                windowController.context.mediaActivityChanged()
            }

        case "restoreClosedTab":
            _ = windowController?.restoreClosedTabStateFirst()

        case "clearUnpinnedTabs":
            windowController?.clearUnpinnedTabs(nil)

        case "loadArchivedTabs":
            windowController?.sendArchivedTabs()

        case "restoreArchivedTabs":
            let ids = (message.payload["ids"] as? [String])?.compactMap(UUID.init(uuidString:)) ?? []
            windowController?.restoreArchivedTabs(Set(ids))

        case "clearArchivedTabs":
            windowController?.clearArchivedTabs()

        case "navigate":
            navigate(to: typedURL(message), with: tabManager)

        case "goBack":
            tabManager.activeEngineTab?.goBack()

        case "goForward":
            tabManager.activeEngineTab?.goForward()

        case "openHistoryInNewTab":
            windowController?.openHistoryInNewTab(forward: message.bool("forward"), inBackground: !message.bool("foreground"))

        case "reload":
            tabManager.reloadActiveTab()

        case "showCachedCopy":
            if let s = tabManager.activeTab?.navigationErrorURL, let url = URL(string: s) {
                tabManager.activeEngineTab?.loadCachedCopy(of: url)
            }

        case "reportUnresponsivePage":
            windowController?.reportUnresponsivePage()

        case "stopLoading":
            tabManager.activeEngineTab?.stopLoading()

        case "openPasswordsApp":
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Passwords") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            }

        case "translatePage":
            windowController?.translatePage(nil)

        case "showFindBar":
            windowController?.presentFindBar()

        case "toggleReader":
            windowController?.toggleReader(nil)

        case "copyPageURL":
            windowController?.copyCurrentURL(nil)

        case "togglePinActiveTab":
            windowController?.pinCurrentTab(nil)

        case "duplicateActiveTab":
            windowController?.duplicateCurrentTab(nil)

        case "viewPageSource":
            windowController?.viewPageSource(nil)

        case "savePageAs":
            windowController?.savePageAs(nil)

        case "newSplitView":
            windowController?.newSplitView(nil)

        case "newTerminal":
            windowController?.newTerminalTab(nil)

        case "runInTerminal":
            if let command = message.string("command"), !command.isEmpty {
                windowController?.runInTerminal(command, split: message.bool("split"))
            }

        case "terminalCompletions":
            let query = message.string("query", default: "")
            inFlightCompletionsTask?.cancel()
            inFlightCompletionsTask = Task { [weak self] in
                let items = await TerminalCompletions.shared.complete(query)
                // The empty query carries the terminal lists, so a newer keystroke never drops it.
                guard query.isEmpty || !Task.isCancelled, let windowController = self?.windowController else { return }
                var data: [String: Any] = [
                    "query": query,
                    "items": items.map { ["command": $0.command, "source": $0.source.rawValue] }
                ]
                // The chrome asks for the terminal lists once per opening, with an empty query, and
                // filters them itself while the user types.
                if query.isEmpty {
                    data["terminals"] = windowController.terminalSummaries()
                    data["closedTerminals"] = windowController.closedTerminalSummaries()
                }
                windowController.bridgeRouter.send(event: "terminalCompletionResults", data: data)
            }
            await inFlightCompletionsTask?.value

        case "revealTerminal":
            if let id = message.uuid("tabId") { windowController?.revealTerminal(id) }

        case "restoreClosedTerminal":
            windowController?.restoreClosedTerminal(at: message.int("index") ?? 0)

        case "answerTerminal":
            if let id = message.uuid("tabId") { windowController?.answerTerminal(id, with: message.string("text", default: "")) }

        case "showNextWaitingTerminal":
            windowController?.showNextWaitingTerminal(nil)

        case "showChanges":
            if let id = message.uuid("tabId") { windowController?.showChanges(forTerminal: id) } else { windowController?.showChanges(nil) }

        case "splitURL":
            if let url = message.string("url").flatMap(URL.init(string:)), url.scheme == "http" || url.scheme == "https",
               let side = SplitDropSide(message.string("side")) {
                windowController?.splitURL(url, at: message.uuid("targetTabId"), side: side)
            }

        case "peekURL":
            if let url = message.string("url").flatMap(URL.init(string:)), url.scheme == "http" || url.scheme == "https",
               let windowController, let tabId = windowController.tabManager.activeOpenTabId {
                windowController.openLinkPeek(url, from: tabId)
            }

        case "splitTab":
            if let tabId = message.uuid("tabId"), let side = SplitDropSide(message.string("side")) {
                windowController?.dropTab(tabId, at: message.uuid("targetTabId"), side: side)
            }

        case "closeSplitView":
            windowController?.closeSplitView(nil)

        case "screenshotPage":
            switch message.string("mode") {
            case "viewport": windowController?.takeViewportScreenshot()
            case "region":   windowController?.startRegionSelection()
            default:         windowController?.takeFullPageScreenshot()
            }

        case "editCapture":
            if let captureId = message.string("captureId") { windowController?.editCopiedCapture(captureId: captureId) }

        case "releaseCapture":
            if let captureId = message.string("captureId") { windowController?.releaseCopiedCapture(captureId: captureId) }

        case "requestTabPreview":
            if let tabId = message.uuid("tabId") { await publishTabPreview(for: tabId) }

        case "zoomIn":
            windowController?.zoomActiveTab(by: 0.1)

        case "zoomOut":
            windowController?.zoomActiveTab(by: -0.1)

        case "zoomReset":
            windowController?.resetActiveTabZoom()

        case "findInPage":
            PerfSignposts.energy.emitEvent("findRequest")
            if let query = message.string("query"), let terminal = windowController?.activeTerminalView {
                // A newer keystroke already replaced this query; its own reply will follow.
                guard let count = await terminal.find(query) else { return nil }
                windowController?.bridgeRouter.send(event: "findInPageResult", data: ["query": query, "matchFound": count > 0])
                return nil
            }
            if let query = message.string("query"),
               let engine = windowController?.focusedEngineTab ?? tabManager.activeEngineTab {
                let found = await engine.findInPage(query, caseSensitive: message.bool("caseSensitive"))
                windowController?.bridgeRouter.send(event: "findInPageResult", data: ["query": query, "matchFound": found])
            }

        case "findNext":
            if let terminal = windowController?.activeTerminalView { terminal.findAgain(older: true) } else { (windowController?.focusedEngineTab ?? tabManager.activeEngineTab)?.findNext() }

        case "findPrevious":
            if let terminal = windowController?.activeTerminalView { terminal.findAgain(older: false) } else { (windowController?.focusedEngineTab ?? tabManager.activeEngineTab)?.findPrevious() }

        case "dismissFind":
            if let terminal = windowController?.activeTerminalView { terminal.endFind() } else { (windowController?.focusedEngineTab ?? tabManager.activeEngineTab)?.dismissFind() }

        case "updateTabFolder":
            guard let id = message.uuid("id"),
                  let name = message.string("name"),
                  let color = message.string("color") else { return nil }
            if let folder = tabManager.folder(id: id) {
                _ = tryApplyStateCommand(.updateFolder(
                    spaceId: folder.spaceId,
                    folderId: id,
                    name: name,
                    color: color,
                    isCollapsed: folder.isCollapsed
                ))
            }

        case "deleteTabFolder":
            return withFolder(message) { folder in
                windowController?.deleteFolderAndContent(folder) { tryApplyStateCommand($0) != nil } ?? false
            }

        case "setTabFolderCollapsed":
            let collapsed = message.bool("collapsed")
            return withFolder(message) { folder in
                tryApplyStateCommand(.setFolderCollapsed(spaceId: folder.spaceId, folderId: folder.id, isCollapsed: collapsed)) != nil
            }

        case "setTabFolderLock":
            guard let id = message.uuid("id"), let folder = tabManager.folder(id: id), !folder.isSplit,
                  let password = message.string("password") else { return nil }
            // 600k PBKDF2 rounds take a noticeable fraction of a second: keep them off the main thread.
            guard await Task.detached(operation: { FolderLockKeychain.setPassword(password, folderId: id) }).value else { return nil }
            let lock = FolderLock(allowsBiometrics: message.bool("allowsBiometrics") && FolderLockAuth.biometricsAvailable)
            await leaveFolderBeforeLock(folder)
            guard tryApplyStateCommand(.setFolderLock(spaceId: folder.spaceId, folderId: id, lock: lock)) != nil else { return nil }
            return [:]

        case "unlockTabFolder":
            guard let id = message.uuid("id"), let folder = tabManager.folder(id: id), let lock = folder.lock else { return nil }
            let method = message.string("method")
            let reason = String(format: "Unlock %@".localized, folder.name)
            let granted: Bool
            switch method {
            case "biometrics", "deviceOwner":
                // The Mac account also answers to Touch ID: without it, only the folder password opens.
                let policy: LAPolicy = method == "biometrics" ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
                granted = lock.allowsBiometrics ? await FolderLockAuth.authenticate(policy, reason: reason) : false
            default:
                let password = message.string("password") ?? ""
                granted = await Task.detached(operation: { FolderLockKeychain.verify(password, folderId: id) }).value
            }
            guard granted,
                  tryApplyStateCommand(.setFolderUnlocked(spaceId: folder.spaceId, folderId: id, isUnlocked: true)) != nil else {
                windowController?.bridgeRouter?.send(event: "folderUnlockFailed", data: ["id": id.uuidString])
                return nil
            }
            windowController?.revealUnlockedFolder(id)
            windowController?.context.folderAutoLock.folderWasUnlocked()
            if method == "deviceOwner" { windowController?.beginFolderLockSetup(id) }
            return [:]

        // The edit panel's lock controls: only for an unlocked folder, as in the context menu.
        case "beginTabFolderLockSetup", "changeTabFolderPassword", "removeTabFolderLock":
            guard let id = message.uuid("id"), let folder = tabManager.folder(id: id),
                  !folder.isSplit, !folder.isLocked, let windowController else { return nil }
            switch message.action {
            case "beginTabFolderLockSetup": windowController.beginFolderLockSetup(id)
            case "changeTabFolderPassword": await windowController.changeFolderPassword(folder)
            default: await windowController.removeFolderLock(folder)
            }
            return [:]

        case "setTabFolderBiometrics":
            guard let id = message.uuid("id"), let folder = tabManager.folder(id: id),
                  let lock = folder.lock, !folder.isLocked else { return nil }
            let allows = message.bool("allowsBiometrics")
            // Touch ID opens the folder to every enrolled finger: turning it on takes the folder password.
            if allows, !lock.allowsBiometrics {
                let password = message.string("password") ?? ""
                guard FolderLockAuth.biometricsAvailable,
                      await Task.detached(operation: { FolderLockKeychain.verify(password, folderId: id) }).value else {
                    windowController?.bridgeRouter?.send(event: "folderPasswordRejected", data: ["id": id.uuidString])
                    return nil
                }
            }
            let command = BrowserCommand.setFolderAllowsBiometrics(spaceId: folder.spaceId, folderId: id, allowsBiometrics: allows)
            guard tryApplyStateCommand(command) != nil else { return nil }
            return [:]

        case "lockTabFolder":
            guard let id = message.uuid("id"), let folder = tabManager.folder(id: id), folder.lock != nil else { return nil }
            await leaveFolderBeforeLock(folder)
            guard tryApplyStateCommand(.setFolderUnlocked(spaceId: folder.spaceId, folderId: id, isUnlocked: false)) != nil
            else { return nil }
            return [:]

        case "commitSidebarDrop":
            if let command = sidebarDropStateCommand(message: message, tabManager: tabManager),
               tryApplyStateCommand(command) != nil {
                return [:]
            }
            return nil

        default:
            break
        }

        return nil
    }

    /// Leaves the folder's tabs before it locks: that main-thread work, done after, stalls the chrome
    /// right as the sidebar collapses the folder, and the collapse never shows.
    private func leaveFolderBeforeLock(_ folder: TabFolder) async {
        windowController?.hideLockedFolder(folder.id, spaceId: folder.spaceId, automatic: false)
        // The teardowns are queued on the main queue: yielding lets them run before the lock lands.
        await Task.yield()
    }

    /// Resolve the message's `id` to its tab and owning space, then run `body`.
    private func withTabContext(_ message: BridgeMessage, _ body: (Tab, UUID) -> Void) {
        guard let id = message.uuid("id"), let (tab, spaceId) = tabManager?.context(for: id) else { return }
        body(tab, spaceId)
    }

    /// Resolve the folder named by the message's `id` and run `body` (which applies the state
    /// command and returns whether it succeeded); returns `[:]` on success, nil otherwise.
    private func withFolder(_ message: BridgeMessage, _ body: (TabFolder) -> Bool) -> Any? {
        guard let id = message.uuid("id"), let folder = tabManager?.folder(id: id), body(folder) else { return nil }
        return [:]
    }

    private func tryApplyStateCommand(_ command: BrowserCommand) -> BrowserChangeSet? {
        do {
            return try stateCommandHandler(command)
        } catch {
            let commandDescription = String(describing: command)
            let errorDescription = String(describing: error)
            Self.logger.error("State command failed command=\(commandDescription, privacy: .public) error=\(errorDescription, privacy: .public)")
            return nil
        }
    }

    private func sidebarDropStateCommand(
        message: BridgeMessage,
        tabManager: TabManager
    ) -> BrowserCommand? {
        switch SidebarDropInsertParser.parse(message) {
        case let .group(sourceTabId, targetTabId):
            guard let sourceSpaceId = spaceId(forSidebarItem: sourceTabId, kind: .tab, tabManager: tabManager),
                  sourceSpaceId == spaceId(forSidebarItem: targetTabId, kind: .tab, tabManager: tabManager) else {
                return nil
            }
            return .groupTabs(spaceId: sourceSpaceId, sourceTabId: sourceTabId, targetTabId: targetTabId)

        case let .insert(insert):
            switch insert.section {
            case .bookmarked:
                guard let spaceId = spaceId(forSidebarItem: insert.id, kind: insert.kind, tabManager: tabManager) else {
                    return nil
                }
                return .moveTabToBookmarked(
                    spaceId: spaceId,
                    tabId: insert.id,
                    insert: .anchored(
                        fallbackIndex: insert.fallbackIndex,
                        insertBeforeId: insert.insertBeforeId,
                        insertAfterId: insert.insertAfterId
                    )
                )

            case let .tree(section):
                guard let spaceId = spaceId(forSidebarItem: insert.id, kind: insert.kind, tabManager: tabManager) else {
                    return nil
                }
                return .moveSidebarItem(
                    spaceId: spaceId,
                    kind: insert.kind,
                    itemId: insert.id,
                    parentFolderId: insert.parentFolderId,
                    section: section,
                    insert: .anchored(
                        fallbackIndex: insert.fallbackIndex,
                        insertBeforeId: insert.insertBeforeId,
                        insertAfterId: insert.insertAfterId
                    )
                )
            }

        case nil:
            return nil
        }
    }

    private func spaceId(
        forSidebarItem id: UUID,
        kind: TabTreeItem.Kind,
        tabManager: TabManager
    ) -> UUID? {
        switch kind {
        case .tab:
            return tabManager.context(for: id)?.spaceId ?? tabManager.currentSpaceId
        case .folder:
            return tabManager.folder(id: id)?.spaceId
        }
    }

    /// The command bar marks the URL the user typed: a bare domain goes to the site history knows.
    private func typedURL(_ message: BridgeMessage) -> URL? {
        guard let url = message.url("url") else { return nil }
        guard message.bool("typed"), let history = windowController?.profileContext?.history else { return url }
        return history.knownSiteURL(forTyped: url)
    }

    private func navigate(to url: URL?, with tabManager: TabManager) {
        guard let url else { return }
        // about:config (with any trailing slash, query, or fragment) opens the in-app
        // feature-flags overlay; never hand it to WebKit.
        if url.scheme?.lowercased() == "about" {
            let page = url.absoluteString.lowercased()
                .dropFirst("about:".count)
                .prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            if page == "config" {
                windowController?.bridgeRouter.send(event: "openConfig")
                return
            }
        }
        // A terminal has no page to navigate: the URL opens in a new tab.
        if let id = tabManager.activeTabId, tabManager.activeEngineTab != nil {
            tabManager.load(url, inTab: id)
        } else {
            windowController?.createTabStateFirst(url: url)
        }
    }

    // MARK: - Hover previews

    /// CGImage is immutable and thread-safe but not Sendable-annotated; the box carries the
    /// snapshot to the encode task, its only consumer.
    private struct PreviewBox: @unchecked Sendable { let image: CGImage }

    /// Snapshots the tab's live engine (any space, never reviving a discarded one) and replies with
    /// a small JPEG over `tabPreviewReady`. Absent `image` means no preview is available.
    private func publishTabPreview(for tabId: UUID) async {
        guard let windowController else { return }
        // A terminal shows its screen as text, with the options of a menu it waits on.
        if let session = tabManager?.terminalHost.view(for: tabId)?.session {
            let prompt = session.prompt()
            windowController.bridgeRouter.send(event: "tabPreviewReady", data: [
                "tabId": tabId.uuidString,
                "lines": prompt.lines,
                "question": prompt.question,
                "choices": session.status.awaitingInputSince == nil ? [] : prompt.choices.map { ["key": $0.key, "label": $0.label] }
            ])
            return
        }
        // A restored terminal not shown yet: decode its screen now, off main, so opening it is instant.
        if tabManager?.tab(for: tabId)?.kind == .terminal { tabManager?.terminalHost.prefetchRestore(of: tabId) }
        let engine = tabManager?.engineTab(for: tabId) ?? windowController.context.browserState.liveEngine(forTab: tabId)

        var dataURL: String?
        if let cgImage = await engine?.takePreviewSnapshot()?.snapshotPixels {
            let box = PreviewBox(image: cgImage)
            dataURL = await Task.detached(priority: .userInitiated) { Self.previewDataURL(from: box.image) }.value
        }
        var payload: [String: Any] = ["tabId": tabId.uuidString]
        if let dataURL { payload["image"] = dataURL }
        windowController.bridgeRouter.send(event: "tabPreviewReady", data: payload)
    }

    /// 480px-wide JPEG (2x of the ~240pt hover card) as a data URL.
    nonisolated private static func previewDataURL(from image: CGImage) -> String? {
        let targetWidth = 480
        let scale = Double(targetWidth) / Double(max(image.width, 1))
        let targetHeight = max(1, Int(Double(image.height) * scale))
        guard scale < 1 else { return jpegDataURL(from: image) }
        guard let context = CGContext(
            data: nil, width: targetWidth, height: targetHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let scaled = context.makeImage() else { return nil }
        return jpegDataURL(from: scaled)
    }

    nonisolated private static func jpegDataURL(from image: CGImage) -> String? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return "data:image/jpeg;base64," + (data as Data).base64EncodedString()
    }
}
