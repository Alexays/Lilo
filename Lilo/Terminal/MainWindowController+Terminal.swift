import AppKit
import OSLog
import UserNotifications

extension MainWindowController {
    /// Wires the terminal host to tabs: shell status becomes the tab's title and state, background
    /// output marks it unread, and Command-clicked links open next to the terminal.
    func setupTerminalHost() {
        let host = tabManager.terminalHost
        host.setSurface(currentContentSurfaceColor)
        if !ProcessInfo.isRunningUnderXCTest {
            let directory = URL(fileURLWithPath: BuildIdentity.appSupportDirectory).appendingPathComponent("Terminals", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let isFirstWindow = host.snapshotDirectory == nil
            host.snapshotDirectory = directory
            if isFirstWindow { context.restoreClosedTerminals() }
            // Screens of tabs not opened for a month, or closed while their Space was not loaded.
            DispatchQueue.global(qos: .utility).async {
                let expiry = Date().addingTimeInterval(-30 * 24 * 3600)
                let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for file in files where (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).flatMap({ $0 < expiry }) ?? false {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        // The host is shared by every window: each event goes to the window that owns the tab.
        host.savesSnapshot = { [weak context] id in
            guard let spaceId = context?.browserState.durableTab(for: id)?.spaceId else { return false }
            return context?.spaceManager?.space(with: spaceId)?.isPrivate == false
        }
        host.onStatusChange = { [weak context] id, status in
            context?.windows.window(forTab: id)?.terminalStatusChanged(id, status)
            context?.terminalActivityChanged()
        }
        host.onUnreadOutput = { [weak context] id in context?.windows.window(forTab: id)?.terminalPrintedUnseenOutput(id) }
        host.onOpenURL = { [weak context] id, url in context?.windows.window(forTab: id)?.openTerminalLink(url, from: id) }
        host.onCommandFinished = { [weak context] id, status in context?.windows.window(forTab: id)?.notifyCommandFinished(id: id, status: status) }
        host.onDesktopNotification = { [weak context] id, title, body in
            context?.windows.window(forTab: id)?.terminalPostedNotification(id, title: title, body: body)
        }
        // A Ghostty "light:A,dark:B" theme switches with Lilo's appearance, live.
        if context.terminalAppearanceObservation == nil {
            context.terminalAppearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak context] _, _ in
                Task { @MainActor in context?.windows.activeWindow?.applyTerminalSettings() }
            }
        }
    }

    func terminalStatusChanged(_ id: UUID, _ status: TerminalSession.Status) {
        var savesDurableState = false
        var changed = false
        var wasAwaiting = false
        let updated = updateRuntimeTab(id: id) { tab in
            let before = tab
            wasAwaiting = before.awaitingInputSince != nil
            tab.title = Self.terminalTitle(for: status)
            // A running command that prints nothing is waiting, not working: no spinner for it.
            tab.terminalState = status.state == .busy && !status.printing ? "waiting" : status.state.rawValue
            tab.terminalCommand = status.command
            tab.gitBranch = status.gitBranch ?? ""
            tab.diffAdded = status.diffAdded
            tab.diffRemoved = status.diffRemoved
            tab.terminalStartedAt = status.commandStarted
            tab.terminalExitCode = status.lastExitCode ?? 0
            tab.terminalDuration = status.lastDuration ?? 0
            tab.awaitingInputSince = status.awaitingInputSince
            if let cwd = status.cwd, cwd != tab.cwd {
                tab.cwd = cwd
                savesDurableState = true
            }
            // What a restored tab offers to run again: a program that takes input (an agent, an
            // editor) or one that runs for a while (a dev server), never a quick one-off.
            let isInteractive = status.bracketedPaste || status.commandStarted.map { Date().timeIntervalSince($0) >= 60 } == true
            if status.state == .busy, isInteractive, !status.command.isEmpty, status.command != tab.resumeCommand {
                tab.resumeCommand = status.command
                savesDurableState = true
            }
            changed = before != tab
        }
        if changed, let updated { enqueueVisibleTabUpdate(updated) }
        if status.awaitingInputSince != nil, !wasAwaiting { scheduleAttentionNotification(id) }
        if status.awaitingInputSince == nil, wasAwaiting { withdrawAttentionNotification(id) }
        // The directory and the command to run again are what a restored tab reopens with.
        if savesDurableState { profileContext?.sessionPersistence?.scheduleSave() }
    }

    func terminalPrintedUnseenOutput(_ id: UUID) {
        guard let updated = updateRuntimeTab(id: id, mutate: { $0.hasUnreadOutput = true }) else { return }
        enqueueVisibleTabUpdate(updated)
    }

    func terminalPostedNotification(_ id: UUID, title: String, body: String) {
        terminalNotificationTexts[id] = (title, body)
        scheduleAttentionNotification(id)
    }

    /// Types `text` into the terminal, as an answer to what it waits on.
    func answerTerminal(_ id: UUID, with text: String) {
        guard !text.isEmpty else { return }
        tabManager.terminalHost.view(for: id)?.session.write(Array(text.utf8))
    }

    /// A bell and a program's own notification usually come together: one notification covers
    /// both, built once the screen shows what is asked.
    private func scheduleAttentionNotification(_ id: UUID) {
        guard terminalAttentionPending.insert(id).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, terminalAttentionPending.remove(id) != nil else { return }
            let texts = terminalNotificationTexts.removeValue(forKey: id)
            guard !isTerminalInView(id), let status = tabManager.terminalHost.view(for: id)?.session.status,
                  let prompt = tabManager.terminalHost.view(for: id)?.session.prompt() else { return }
            postAttentionNotification(id, status: status, prompt: prompt, texts: texts)
        }
    }

    private func postAttentionNotification(
        _ id: UUID, status: TerminalSession.Status, prompt: TerminalSession.Prompt, texts: (title: String, body: String)?
    ) {
        let content = UNMutableNotificationContent()
        content.title = texts.flatMap { $0.title.isEmpty ? nil : $0.title } ?? Self.terminalTitle(for: status)
        let folder = status.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
        content.subtitle = [folder, status.gitBranch].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let choices = prompt.choices.prefix(3)
        let question = choices.isEmpty ? (texts?.body).flatMap { $0.isEmpty ? nil : $0 } ?? prompt.lines.last : prompt.question
        content.body = ([question ?? "Waiting for your answer".localized] + choices.map { "\($0.key). \($0.label)" })
            .joined(separator: "\n")
        content.sound = .default
        content.threadIdentifier = id.uuidString
        content.categoryIdentifier = choices.count >= 2 ? "\(UNNotificationCategory.terminalAttention).\(choices.count)" : UNNotificationCategory.terminalAttention
        content.userInfo = ["terminalTabId": id.uuidString]
        UNUserNotificationCenter.requestAuthorizationAndAdd(
            UNNotificationRequest(identifier: Self.attentionNotificationId(id), content: content, trigger: nil)
        )
    }

    /// The question is answered or the terminal is on screen: its notification has nothing left to say.
    func withdrawAttentionNotification(_ id: UUID) {
        terminalAttentionPending.remove(id)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.attentionNotificationId(id)])
    }

    private static func attentionNotificationId(_ id: UUID) -> String {
        "\(UNNotificationCategory.terminalAttention).\(id.uuidString)"
    }

    /// The program's own title when it sets one, then the running command, otherwise
    /// "process · folder".
    static func terminalTitle(for status: TerminalSession.Status) -> String {
        if !status.title.isEmpty { return status.title }
        if status.state == .busy, !status.command.isEmpty { return status.command }
        let folder = status.cwd.map(folderLabel) ?? "~"
        guard let process = status.foregroundProcess, !["login", "zsh", "bash", "fish", "sh"].contains(process) else { return folder }
        return "\(process) · \(folder)"
    }

    /// "~" for the home folder, else the folder's own name.
    static func folderLabel(_ path: String) -> String {
        path == NSHomeDirectory() ? "~" : URL(fileURLWithPath: path).lastPathComponent
    }

    /// Opens a terminal tab in `cwd`, else where the tab in front is: the terminal's directory, the
    /// folder of a local file page, or the home folder. The shell runs `command` first when given.
    /// A reopened terminal brings back the screen its closed tab kept and types its last program.
    @discardableResult
    func createTerminalTab(
        activate: Bool = true, command: String? = nil, cwd: String? = nil,
        resumeCommand: String? = nil, screenOf closedId: UUID? = nil
    ) -> Tab? {
        guard context.settingsStore?.terminalEnabled != false, let spaceId = tabManager.currentSpaceId else { return nil }
        let cwd = cwd ?? tabManager.activeTab.flatMap { tab -> String? in
            if tab.kind == .terminal { return tab.cwd }
            guard let url = tab.url, url.isFileURL else { return nil }
            return url.hasDirectoryPath ? url.path : url.deletingLastPathComponent().path
        } ?? NSHomeDirectory()
        let tab = Tab(title: command ?? Self.folderLabel(cwd), kind: .terminal, cwd: cwd, resumeCommand: resumeCommand)
        if let command { tabManager.terminalHost.setInitialCommand(command, for: tab.id) }
        if let closedId { tabManager.terminalHost.adoptScreen(of: closedId, for: tab.id) }
        do {
            try applyBrowserCommand(.createTab(spaceId: spaceId, tab: tab, activate: activate))
            if activate { tabManager.activateTabRuntime(id: tab.id) }
            return tab
        } catch {
            Self.logger.error("create terminal tab failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Runs a command typed after ">" in the command bar in a new terminal tab, or in a split next
    /// to the current tab.
    func runInTerminal(_ command: String, split: Bool) {
        guard split, let spaceId = tabManager.currentSpaceId, let current = tabManager.activeTab, tabManager.activeSplit == nil else {
            createTerminalTab(command: command)
            return
        }
        guard let terminal = createTerminalTab(activate: false, command: command) else { return }
        _ = try? applyBrowserCommand(.splitTabs(spaceId: spaceId, tabId: terminal.id, targetTabId: current.id, vertical: false, before: false))
        tabManager.activateTabRuntime(id: terminal.id)
    }

    /// The terminal on screen when the active tab is one; find and copy go to it instead of a page.
    var activeTerminalView: TerminalView? {
        tabManager.activeTab.flatMap { $0.kind == .terminal ? tabManager.terminalHost.view(for: $0.id) : nil }
    }

    @objc func newTerminalTab(_ sender: Any?) {
        createTerminalTab()
    }

    /// Every started terminal of every window and Space, for the command bar's overview. Private
    /// Spaces other than the current one stay out of it.
    func terminalSummaries() -> [[String: Any]] {
        let host = tabManager.terminalHost
        return host.liveTabIds.compactMap { id -> [String: Any]? in
            guard let status = host.view(for: id)?.session.status,
                  let spaceId = context.browserState.durableTab(for: id)?.spaceId,
                  let space = context.spaceManager?.space(with: spaceId),
                  !space.isPrivate || spaceId == tabManager.currentSpaceId else { return nil }
            return [
                "tabId": id.uuidString,
                "title": Self.terminalTitle(for: status),
                "command": status.command,
                "state": status.state == .busy && !status.printing ? "waiting" : status.state.rawValue,
                "awaitingInputSince": (status.awaitingInputSince?.timeIntervalSince1970 ?? 0) * 1000,
                "startedAt": (status.commandStarted?.timeIntervalSince1970 ?? 0) * 1000,
                "exitCode": Double(status.lastExitCode ?? 0),
                "duration": status.lastDuration ?? 0,
                "gitBranch": status.gitBranch ?? "",
                "spaceId": spaceId.uuidString,
                "spaceName": space.name
            ]
        }
    }

    /// Closed terminals newest first, numbered as `restoreClosedTerminal(at:)` counts them, for the
    /// command bar. Those of private Spaces other than the current one keep their number, unnamed.
    func closedTerminalSummaries() -> [[String: Any]] {
        var index = 0
        return context.recentlyClosed.recentEntries.compactMap { entry -> [String: Any]? in
            guard case .terminal(let closed) = entry.content else { return nil }
            defer { index += 1 }
            let space = context.spaceManager?.space(with: entry.spaceId)
            guard space?.isPrivate != true || entry.spaceId == tabManager.currentSpaceId else { return nil }
            return [
                "index": index,
                "title": closed.title,
                "resumeCommand": closed.resumeCommand ?? "",
                "gitBranch": closed.gitBranch,
                "folder": Self.folderLabel(closed.cwd),
                "closedAt": closed.closedAt.timeIntervalSince1970 * 1000,
                "hasScreen": closed.screenId != nil,
                "spaceName": space?.name ?? ""
            ]
        }
    }

    /// Brings a terminal on screen in the window that owns it.
    func revealTerminal(_ id: UUID) {
        (context.windows.window(forTab: id) ?? self).revealTab(id)
    }

    /// Goes to the terminal that has waited longest for an answer, then to the next one on each
    /// press; beeps when none waits.
    @objc func showNextWaitingTerminal(_ sender: Any?) {
        let host = tabManager.terminalHost
        let waiting = host.liveTabIds
            .compactMap { id in host.view(for: id)?.session.status.awaitingInputSince.map { (id, $0) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        guard !waiting.isEmpty else { return NSSound.beep() }
        let next = tabManager.activeTab.flatMap { waiting.firstIndex(of: $0.id) }.map { waiting[($0 + 1) % waiting.count] } ?? waiting[0]
        revealTerminal(next)
    }

    /// Puts the active terminal on screen, mirroring `showContentView` for web engines.
    func showTerminalView(for tab: Tab) {
        guard let view = tabManager.terminalHost.ensureView(for: tab) else {
            // No Metal device or the shell would not start: say so rather than leave the previous page up.
            contentContainerView.subviews.forEach { $0.removeFromSuperview() }
            updateDisplayedTabs([])
            if let window {
                let alert = NSAlert()
                alert.messageText = "The terminal could not start.".localized
                alert.informativeText = "Close the tab and try again.".localized
                alert.beginSheetModal(for: window)
            }
            return
        }
        showNativeContentView(view, forTabId: tab.id)
        withdrawAttentionNotification(tab.id)
        if tab.hasUnreadOutput, let updated = updateRuntimeTab(id: tab.id, mutate: { $0.hasUnreadOutput = false }) {
            enqueueVisibleTabUpdate(updated)
        }
    }

    /// Puts a tab's native view (a terminal, a diff) on screen in place of the previous content.
    func showNativeContentView(_ view: NSView, forTabId id: UUID) {
        chromeInput.setContentView(view)
        let retained = splitPanes.retainedViews(forTabId: id)
        let outgoing = contentContainerView.subviews.filter { subview in
            subview !== view && !retained.contains { $0 === subview }
        }
        // A split pane joins the container in layoutSplitContent, already at its pane frame.
        if tabManager.activeSplit?.layout.paneIds.contains(id) != true {
            view.frame = contentContainerView.bounds
            view.autoresizingMask = [.width, .height]
            if view.superview !== contentContainerView { contentContainerView.addSubview(view) }
        }
        processOutgoingContentViews(outgoing)
        view.isHidden = false
        layoutSplitContent()
        focusContent(view)
    }

    /// Web links open in a peek over the terminal, whatever the single-window setting: a quick look
    /// that Esc dismisses, or keeps as a tab or a split pane. Files TerminalHost lets through open in their default app.
    func openTerminalLink(_ url: URL, from terminalId: UUID) {
        if url.isFileURL {
            NSWorkspace.shared.open(url)
            return
        }
        openLinkPeek(url, from: terminalId)
    }

    /// The user is looking at this terminal right now: Lilo in front and the tab on screen in its key window.
    private func isTerminalInView(_ id: UUID) -> Bool {
        NSApp.isActive && window?.isKeyWindow == true && displayedTabIds.contains(id)
    }

    /// A command that ran for a while tells when it is done, unless its terminal is in view.
    func notifyCommandFinished(id: UUID, status: TerminalSession.Status) {
        guard context.settingsStore?.get("terminalNotifyLongCommands") != "false",
              let duration = status.lastDuration, duration >= 10, !isTerminalInView(id) else { return }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = duration >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.maximumUnitCount = 2
        let took = formatter.string(from: duration) ?? ""
        let command = status.command.isEmpty ? (tabManager.tab(for: id)?.title ?? "") : status.command
        let failed = status.state == .failed
        postTerminalNotification(
            id: id,
            title: failed ? "Command failed".localized : "Command finished".localized,
            body: failed
                ? String(format: "%@ failed with exit code %d after %@.".localized, command, status.lastExitCode ?? 1, took)
                : String(format: "%@ finished in %@.".localized, command, took)
        )
    }

    private func postTerminalNotification(id: UUID, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = id.uuidString
        content.userInfo = ["terminalTabId": id.uuidString]
        UNUserNotificationCenter.requestAuthorizationAndAdd(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    /// Brings a tab on screen from its notification, switching Space when it lives in another one.
    func revealTab(_ id: UUID) {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        guard let spaceId = context.browserState.durableTab(for: id)?.spaceId else { return }
        if spaceId != tabManager.currentSpaceId { requestSpaceSwitch(id: spaceId) }
        activateTabStateFirst(id: id)
    }

    /// Asks before closing a terminal that is running a command. Returns true when the close
    /// may go ahead now.
    func confirmTerminalClose(id: UUID, undoable: Bool) -> Bool {
        guard tabManager.tab(for: id)?.kind == .terminal, tabManager.terminalHost.isBusy(id),
              let window else { return true }
        let alert = NSAlert()
        alert.messageText = "Close this terminal?".localized
        alert.informativeText = tabManager.terminalHost.runningCommand(id).map {
            String(format: "%@ is still running and will be stopped.".localized, $0)
        } ?? "A command is still running in it and will be stopped.".localized
        alert.addButton(withTitle: "Close".localized)
        alert.addButton(withTitle: "Cancel".localized)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            tabManager.terminalHost.terminate(id)
            closeTabStateFirst(id: id, undoable: undoable)
        }
        return false
    }
}

// MARK: - Appearance

extension MainWindowController {
    private var customTerminalThemes: [TerminalTheme] {
        guard let json = context.settingsStore?.get("terminalCustomThemes") else { return [] }
        return (try? JSONDecoder().decode([TerminalTheme].self, from: Data(json.utf8))) ?? []
    }

    /// Reads the terminal settings (theme, font, size) and applies them to every terminal.
    func applyTerminalSettings() {
        guard let settingsStore = context.settingsStore else { return }
        let ghostty = TerminalTheme.ghosttyConfig(dark: Self.prefersDarkSidebarAppearance())
        let themeId = settingsStore.get("terminalTheme") ?? TerminalTheme.auto.id
        let theme: TerminalTheme? = switch themeId {
        case "ghostty": ghostty?.theme
        case "vscode": TerminalTheme.vscodeTheme(dark: Self.prefersDarkSidebarAppearance())
        default: (TerminalTheme.presets + customTerminalThemes).first { $0.id == themeId }
        }
        let family = settingsStore.get("terminalFontFamily") ?? ""
        let fromGhostty = family == "ghostty"
        let size = settingsStore.get("terminalFontSize").flatMap(Double.init).map { CGFloat($0) }
            ?? (fromGhostty ? ghostty?.fontSize : nil) ?? 13
        tabManager.terminalHost.setAppearance(TerminalHost.Appearance(
            theme: theme ?? .auto,
            fontFamily: fromGhostty ? ghostty?.fontFamily : (family.isEmpty ? nil : family),
            fontSize: size,
            optionAsMeta: TerminalHost.OptionAsMeta(rawValue: settingsStore.get("terminalOptionAsMeta") ?? "") ?? .off,
            scrollbackBytes: (settingsStore.get("terminalScrollbackMB").flatMap(Int.init) ?? 10) * 1_000_000
        ))
        context.powerKeeper.apply(PowerKeeper.Settings(get: settingsStore.get))
    }

    /// Themes with their colors on the current Space, monospaced font families, and what the
    /// user's Ghostty and VS Code configs offer, for the settings page.
    func terminalOptions() -> [String: Any] {
        let ghostty = TerminalTheme.ghosttyConfig(dark: Self.prefersDarkSidebarAppearance())
        var ghosttyTheme = ghostty?.theme
        ghosttyTheme?.name = "Ghostty (\(ghostty?.themeName ?? "config"))"
        let vscodeTheme = TerminalTheme.vscodeTheme(dark: Self.prefersDarkSidebarAppearance())
        let themes = [TerminalTheme.auto] + [ghosttyTheme, vscodeTheme].compactMap { $0 } + TerminalTheme.presets + customTerminalThemes
        let host = tabManager.terminalHost
        let fonts = Set((NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []).compactMap { name -> String? in
            guard let family = NSFont(name: name, size: 12)?.familyName, !family.hasPrefix("."), family != "LastResort" else { return nil }
            return family
        }).sorted()
        return [
            "themes": themes.map { theme -> [String: Any] in
                let colors = host.resolvedColors(for: theme)
                return [
                    "id": theme.id,
                    "name": theme.name,
                    "background": colors.background.hexString,
                    "foreground": colors.foreground.hexString,
                    "palette": colors.palette.map(\.hexString)
                ]
            },
            "fonts": fonts,
            "ghosttyFont": ghostty?.fontFamily ?? ""
        ]
    }

    /// Imports an iTerm2 `.itermcolors` file, a VS Code color theme or a Ghostty theme and makes it the terminal theme.
    func importTerminalTheme() async -> Bool {
        guard let settingsStore = context.settingsStore, let window else { return false }
        let panel = NSOpenPanel()
        panel.message = "Choose an iTerm2 color preset (.itermcolors), a VS Code color theme (.json) or a Ghostty theme file.".localized
        panel.canChooseDirectories = false
        guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return false }
        let name = url.deletingPathExtension().lastPathComponent
        let id = "custom:\(UUID().uuidString)"
        let parsed: TerminalTheme? = switch url.pathExtension.lowercased() {
        case "itermcolors": TerminalTheme.iTerm(data, id: id, name: name)
        case "json", "jsonc": TerminalTheme.vscodeColors(at: url).flatMap { TerminalTheme.vscode($0, id: id, name: name) }
        default: String(data: data, encoding: .utf8).flatMap { TerminalTheme.ghostty($0, id: id, name: name) }
        }
        guard let theme = parsed else {
            let alert = NSAlert()
            alert.messageText = "This file is not a theme Lilo can read.".localized
            alert.informativeText = "Lilo reads iTerm2 color presets, VS Code color themes and Ghostty theme files.".localized
            await alert.beginSheetModal(for: window)
            return false
        }
        // Importing a theme with the same name again replaces it.
        let themes = customTerminalThemes.filter { $0.name != name } + [theme]
        guard let data = try? JSONEncoder().encode(themes), let json = String(bytes: data, encoding: .utf8) else { return false }
        settingsStore.set("terminalCustomThemes", value: json)
        settingsStore.set("terminalTheme", value: id)
        applyTerminalSettings()
        return true
    }
}

extension BrowserContext {
    private var closedTerminalsURL: URL? {
        terminalHost.snapshotDirectory?.appendingPathComponent("closed.json")
    }

    /// Serial, so the writes land in the order they were made.
    private static let closedTerminalsQueue = DispatchQueue(label: "fr.arouillard.lilo.closed-terminals", qos: .utility)

    /// Closed terminals outside private Spaces outlive the launch; closed pages do not. One save per
    /// main-thread turn, however many tabs closed in it.
    func saveClosedTerminals() {
        guard !closedTerminalsSavePending else { return }
        closedTerminalsSavePending = true
        DispatchQueue.main.async { [weak self] in self?.writeClosedTerminals() }
    }

    /// Writes the closed terminals off the main thread when they changed; at quit, waits for the disk.
    func writeClosedTerminals() {
        closedTerminalsSavePending = false
        guard let url = closedTerminalsURL else { return }
        let terminals = Array(recentlyClosed.recentEntries.reversed().filter { entry in
            guard case .terminal = entry.content else { return false }
            return spaceManager?.space(with: entry.spaceId)?.isPrivate == false
        })
        if terminals != savedClosedTerminals {
            savedClosedTerminals = terminals
            Self.closedTerminalsQueue.async { try? JSONEncoder().encode(terminals).write(to: url, options: .atomic) }
        }
        // The process exits right after: a write still queued must land first.
        if isTerminating { Self.closedTerminalsQueue.sync {} }
    }

    /// Their screens are purged after 30 days, and so are they.
    func restoreClosedTerminals() {
        guard let url = closedTerminalsURL, let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([RecentlyClosedStack.Entry].self, from: data) else { return }
        let expiry = Date().addingTimeInterval(-30 * 24 * 3600)
        recentlyClosed.restoreOlder(entries.filter { entry in
            guard case .terminal(let closed) = entry.content else { return false }
            return closed.closedAt > expiry
        })
    }

    /// Sends every window its terminals when they changed and puts the number waiting for an answer
    /// on the Dock icon. One pass per main-thread turn, however many terminals changed in it.
    func terminalActivityChanged() {
        guard !terminalActivityPending else { return }
        terminalActivityPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            terminalActivityPending = false
            let waiting = terminalHost.liveTabIds.count(where: { terminalHost.view(for: $0)?.session.status.awaitingInputSince != nil })
            let badge = waiting > 0 ? String(waiting) : nil
            if NSApp.dockTile.badgeLabel != badge { NSApp.dockTile.badgeLabel = badge }
            var sent: [ObjectIdentifier: NSArray] = [:]
            for window in windows.windows {
                guard let router = window.bridgeRouter else { continue }
                let key = ObjectIdentifier(window)
                let terminals = window.terminalSummaries()
                let bridged = terminals as NSArray
                sent[key] = bridged
                let unchanged = sentTerminalActivity[key]?.isEqual(bridged) == true
                PerfSignposts.energy.emitEvent("terminalActivity", "\(unchanged ? "skipped" : "sent", privacy: .public)")
                guard !unchanged else { continue }
                router.send(event: "terminalActivity", data: ["terminals": terminals])
            }
            sentTerminalActivity = sent
        }
    }
}

extension UNNotificationCategory {
    static let terminalAttention = "lilo.terminal.attention"
    static let terminalChoicePrefix = "lilo.terminal.choice."
    static let terminalReply = "lilo.terminal.reply"

    /// A terminal waiting for an answer takes a typed reply, and the options of its menu by number.
    static var terminalAttentionCategories: Set<UNNotificationCategory> {
        let reply = UNTextInputNotificationAction(
            identifier: terminalReply, title: "Reply".localized, options: [],
            textInputButtonTitle: "Send".localized, textInputPlaceholder: ""
        )
        let choice = { (key: Int) in UNNotificationAction(identifier: "\(terminalChoicePrefix)\(key)", title: String(key), options: []) }
        return [
            UNNotificationCategory(identifier: terminalAttention, actions: [reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: "\(terminalAttention).2", actions: [choice(1), choice(2), reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: "\(terminalAttention).3", actions: [choice(1), choice(2), choice(3), reply], intentIdentifiers: [])
        ]
    }
}
