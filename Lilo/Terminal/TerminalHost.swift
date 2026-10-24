import AppKit
import OSLog
import Synchronization
import UniformTypeIdentifiers

/// Terminal tabs' sessions and views, keyed by tab id. Kept apart from the web engines on purpose:
/// tab lifecycle, hibernation and memory trimming never see a terminal, so a running shell is never
/// discarded. A shell starts the first time its tab is shown.
@MainActor
final class TerminalHost {
    /// Which Option keys send Meta (Escape-prefixed keys) instead of typing characters.
    enum OptionAsMeta: String {
        case off = "", left, right, both
    }

    /// Everything from the settings that decides how a terminal looks and reads the keyboard.
    struct Appearance: Equatable {
        var theme = TerminalTheme.auto
        var fontFamily: String?
        var fontSize: CGFloat = 13
        var optionAsMeta = OptionAsMeta.off
        var scrollbackBytes = 10_000_000
    }

    /// Status of a tab's shell changed (title, cwd, command state), delivered on the main thread.
    var onStatusChange: ((UUID, TerminalSession.Status) -> Void)?
    /// A background tab printed something or rang the bell.
    var onUnreadOutput: ((UUID) -> Void)?
    var onOpenURL: ((UUID, URL) -> Void)?
    /// A command finished in the tab; the status holds its line, exit code and duration.
    var onCommandFinished: ((UUID, TerminalSession.Status) -> Void)?
    /// A program in the tab asked for a desktop notification: title (may be empty) and body.
    var onDesktopNotification: ((UUID, String, String) -> Void)?
    /// Told every terminal's status, to keep the Mac awake while a command works.
    weak var powerKeeper: PowerKeeper?
    /// Diffs take the terminal theme's colors.
    weak var changesHost: ChangesHost?

    /// Set once a tab's output has been reported, so a flood costs one main-thread hop.
    private final class UnreadFlag: Sendable {
        let reported = Atomic<Bool>(false)
    }

    /// Where each terminal's screen and history are saved for the next launch; nil saves nothing.
    var snapshotDirectory: URL?
    /// False for tabs whose content must not reach the disk (private Spaces).
    var savesSnapshot: (UUID) -> Bool = { _ in true }

    var liveTabIds: [UUID] { Array(views.keys) }

    /// Tabs whose output is on screen; output elsewhere marks the tab unread.
    var visibleTabIds: Set<UUID> = [] {
        didSet {
            guard visibleTabIds != oldValue else { return }
            for flag in unread.values { flag.reported.store(false, ordering: .relaxed) }
            // Hidden terminals read no line counts when their output pauses: shown, they catch up.
            refreshGitStats(visibleTabIds.subtracting(oldValue))
            armHousekeeping()
        }
    }

    private(set) var appearance = Appearance()
    private var surface = VTColor(hex: 0x1E1E1E)
    private var accent = VTColor(NSColor.controlAccentColor)
    private var views: [UUID: TerminalView] = [:]
    private var unread: [UUID: UnreadFlag] = [:]
    private var finishedCommands: [UUID: Int] = [:]
    /// Per hidden terminal: the compression activity seen at the last pass, and the one compressed.
    private var compression: [UUID: (seen: UInt64, compressed: UInt64?)] = [:]
    private var compressionTimer: Timer?
    /// Output count of each terminal at its last saved snapshot, and of each hidden one at the last pass.
    private var savedOutput: [UUID: Int] = [:]
    private var seenOutput: [UUID: Int] = [:]
    /// When a hidden terminal whose output never holds still is saved anyway.
    private var saveDue: [UUID: ContinuousClock.Instant] = [:]
    private static let forcedSaveInterval = Duration.seconds(300)
    private static let compressionQueue = DispatchQueue(label: "fr.arouillard.lilo.terminal.compress", qos: .utility)
    /// Screen saves only, apart from history compression: a reopen or quit waits for these, never for a long compression.
    private static let screenQueue = DispatchQueue(label: "fr.arouillard.lilo.terminal.screen", qos: .utility)
    /// Commands for terminals whose session has not started yet, run once at their first prompt.
    private var initialCommands: [UUID: String] = [:]
    /// Closed terminals whose saved screen stays for a reopen, past the end of their session.
    private var keptScreens = Set<UUID>()

    /// `terminal` is set by `decode` and read only once waiting on it returns.
    private final class Restore: @unchecked Sendable {
        var decode = DispatchWorkItem {}
        var terminal: VTTerminal?
    }

    /// Saved screens decoded off the main thread ahead of their tab's first show.
    private var restores: [UUID: Restore] = [:]

    func view(for id: UUID) -> TerminalView? {
        views[id]
    }

    /// Call before the tab is first shown.
    func setInitialCommand(_ command: String, for id: UUID) {
        initialCommands[id] = command
    }

    /// The tab's terminal, starting its shell in the tab's `cwd` on first use.
    func ensureView(for tab: Tab) -> TerminalView? {
        if let view = views[tab.id] { return view }
        let restored: VTTerminal?
        if let prefetched = restores.removeValue(forKey: tab.id) {
            // Waiting on the work item, unlike on a group, lends it the main thread's priority.
            prefetched.decode.wait()
            restored = prefetched.terminal
        } else {
            restored = Self.restoredTerminal(at: snapshotURL(tab.id), scrollbackBytes: appearance.scrollbackBytes)
        }
        let initialCommand = initialCommands.removeValue(forKey: tab.id)
        let session = TerminalSession(
            cwd: tab.cwd ?? NSHomeDirectory(), initialCommand: initialCommand,
            prefillCommand: initialCommand == nil ? tab.resumeCommand : nil,
            scrollbackBytes: appearance.scrollbackBytes, restored: restored
        )
        guard let view = TerminalView(session: session, fontFamily: appearance.fontFamily, fontSize: appearance.fontSize) else { return nil }
        view.optionAsMeta = appearance.optionAsMeta
        let id = tab.id
        let flag = UnreadFlag()
        unread[id] = flag
        let renderLoop = view.renderLoop
        // Output wakes the renderer; the first batch for a hidden tab also flags it unread, once.
        session.onOutput = { [weak self] in
            renderLoop.wake()
            guard !flag.reported.exchange(true, ordering: .acquiringAndReleasing) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.visibleTabIds.contains(id) else { return }
                    self.onUnreadOutput?(id)
                }
            }
        }
        session.onStatusChange = { [weak self, weak view] status in
            view?.readsPassword = status.readsPassword
            guard let self else { return }
            armHousekeeping()
            onStatusChange?(id, status)
            powerKeeper?.terminalStatusChanged(id, status)
            if status.finishedCommands != finishedCommands[id, default: 0] {
                finishedCommands[id] = status.finishedCommands
                onCommandFinished?(id, status)
            }
        }
        session.onDesktopNotification = { [weak self] title, body in self?.onDesktopNotification?(id, title, body) }
        view.onOpenURL = { [weak self] url in
            // Output picks the link: only folders, text, images, PDFs and media open in their app; anything
            // else (apps, installers, scripts, profiles, archives) is shown in Finder, never run.
            if url.isFileURL {
                let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey])
                let opens = values?.isPackage != true && (values?.isDirectory == true || values?.contentType.map { type in
                    !type.conforms(to: .script) && !type.conforms(to: .executable)
                        && [.text, .image, .pdf, .audiovisualContent].contains { type.conforms(to: $0) }
                } == true)
                if !opens { return NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            self?.onOpenURL?(id, url)
        }
        apply(colors: appearance.theme.resolved(surface: surface, accent: accent), to: view)
        do {
            try session.start()
        } catch {
            session.onOutput = nil
            view.shutdown()
            return nil
        }
        views[id] = view
        saveDue[id] = .now + Self.forcedSaveInterval
        // A shell that changes nothing posts no status, and the tab would still read as never started.
        onStatusChange?(id, session.status)
        armHousekeeping()
        return view
    }

    /// Decodes the saved screen of a terminal about to be shown (its Space shown, its tab hovered) on
    /// a background queue, so its first show skips the decode. Dropped after a minute if not shown.
    func prefetchRestore(of id: UUID) {
        guard views[id] == nil, restores[id] == nil, let url = snapshotURL(id) else { return }
        let restore = Restore()
        let scrollbackBytes = appearance.scrollbackBytes
        // Weak, so a prefetch dropped before its turn decodes nothing, and the item never holds the terminal.
        // @Sendable, so the block is not main-actor isolated: it runs on a global queue.
        restore.decode = DispatchWorkItem { @Sendable [weak restore] in
            restore?.terminal = Self.restoredTerminal(at: url, scrollbackBytes: scrollbackBytes)
        }
        restores[id] = restore
        DispatchQueue.global(qos: .userInitiated).async(execute: restore.decode)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.restores[id] === restore else { return }
                self.restores[id] = nil
            }
        }
    }

    /// The decode, which replays and compresses the history, costs far more than the read and decompression.
    private nonisolated static func restoredTerminal(at url: URL?, scrollbackBytes: Int) -> VTTerminal? {
        url.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? (($0 as NSData).decompressed(using: .lzfse)) as Data }
            .flatMap { VTTerminal(snapshot: $0, scrollbackBytes: scrollbackBytes) }
    }

    /// Every 30 s while a hidden terminal has work; a pass with nothing to do stops the timer, and the
    /// next status or visibility change (new output posts one) restarts it.
    private func armHousekeeping() {
        guard compressionTimer == nil, views.keys.contains(where: { !visibleTabIds.contains($0) }) else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let compressing = self.compressIdleHistory()
                guard !self.saveSnapshots(visible: false), !compressing else { return }
                self.compressionTimer?.invalidate()
                self.compressionTimer = nil
            }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        compressionTimer = timer
    }

    /// Hidden terminals quiet for a whole pass get their history compressed off the main thread, in
    /// bounded steps so output and rendering take the lock in between. True while one still has
    /// history left to compress.
    private func compressIdleHistory() -> Bool {
        var pending = false
        for (id, view) in views where !visibleTabIds.contains(id) {
            let session = view.session
            let activity = session.compressionActivity.load(ordering: .relaxed)
            let previous = compression[id]
            compression[id] = (activity, previous?.compressed)
            guard previous?.compressed != activity else { continue }
            pending = true
            guard previous?.seen == activity else { continue }
            Self.compressionQueue.async { [weak self] in
                while !session.withLockedTerminal({ $0.compressHistoryStep() }) {}
                let compressed = session.withLockedTerminal { terminal in
                    let activity = terminal.compressionActivity
                    session.compressionActivity.store(activity, ordering: .relaxed)
                    return activity
                }
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.compression[id]?.compressed = compressed }
                }
            }
        }
        return pending
    }

    private func snapshotURL(_ id: UUID) -> URL? {
        snapshotDirectory?.appendingPathComponent(id.uuidString + ".snapshot")
    }

    /// Saves terminals with output since their last save. Encoding holds the terminal lock, so on-screen ones save only at quit (`visible`);
    /// hidden ones save in the background once output settles for a pass, or every 5 minutes. True when one was saved or waits to be.
    @discardableResult
    func saveSnapshots(visible: Bool) -> Bool {
        guard snapshotDirectory != nil else { return false }
        // Queued saves land before a quit's: none then overwrites a newer screen or dies with the app.
        if visible { Self.screenQueue.sync {} }
        let signpost = PerfSignposts.energy.beginInterval("saveSnapshots")
        var saved = false, count = 0
        var quitSaves: [@Sendable () -> Void] = []
        let now = ContinuousClock.now
        for (id, view) in views where (visible || !visibleTabIds.contains(id)) && savesSnapshot(id) {
            let session = view.session
            let output = session.outputBatches
            guard savedOutput[id] != output, let url = snapshotURL(id) else { continue }
            saved = true
            guard visible || seenOutput.updateValue(output, forKey: id) == output || saveDue[id, default: now] <= now else { continue }
            savedOutput[id] = output
            saveDue[id] = now + Self.forcedSaveInterval
            count += 1
            let save: @Sendable () -> Void = { Self.writeSnapshot(of: session, to: url) }
            if visible { quitSaves.append(save) } else { Self.screenQueue.async(execute: save) }
        }
        // Each save locks only its own terminal, so a quit encodes and compresses them all at once.
        DispatchQueue.concurrentPerform(iterations: quitSaves.count) { [quitSaves] in quitSaves[$0]() }
        PerfSignposts.energy.endInterval("saveSnapshots", signpost, "\(count) saved")
        return saved
    }

    private nonisolated static func writeSnapshot(of session: TerminalSession, to url: URL) {
        guard let data = session.withLockedTerminal({ $0.snapshot() }),
              let compressed = try? (data as NSData).compressed(using: .lzfse) else { return }
        try? (compressed as Data).write(to: url, options: .atomic)
    }

    /// A tab closed for good: its shell ends and its saved screen goes, whether or not its
    /// terminal was ever shown in this launch, unless the screen is kept for a reopen.
    func forget(_ id: UUID) {
        terminate(id)
        if !keptScreens.contains(id), let url = snapshotURL(id) {
            Self.screenQueue.async { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Saves a closing terminal's screen in the background, and keeps it once the tab is gone. False
    /// when there is nothing to keep: a private Space, or a terminal neither started nor saved before.
    func keepScreen(of id: UUID) -> Bool {
        guard savesSnapshot(id), let url = snapshotURL(id) else { return false }
        if let session = views[id]?.session {
            // The terminal stays readable after its session ends, so the save may outlive the tab.
            Self.screenQueue.async { Self.writeSnapshot(of: session, to: url) }
        } else if !FileManager.default.fileExists(atPath: url.path) {
            return false
        }
        keptScreens.insert(id)
        return true
    }

    /// A reopened terminal starts below the screen its closed tab kept. Call before it is first shown.
    func adoptScreen(of closedId: UUID, for id: UUID) {
        keptScreens.remove(closedId)
        restores[id] = nil
        guard let from = snapshotURL(closedId), let to = snapshotURL(id) else { return }
        // The closed tab's save may still be queued: the move must see the file it writes.
        Self.screenQueue.sync {}
        try? FileManager.default.moveItem(at: from, to: to)
    }

    /// Another app may have committed, stashed or discarded meanwhile: no shell event tells. Only
    /// terminals on screen (`ids`, else every visible one) are read; hidden ones catch up when shown.
    func refreshGitStats(_ ids: Set<UUID>? = nil) {
        for id in ids ?? visibleTabIds {
            guard let session = views[id]?.session, !session.gitStatIsRecent else { continue }
            session.refreshGitBranch(withStat: true)
        }
    }

    /// Whether closing the tab would kill something the user started (not just an idle shell).
    func isBusy(_ id: UUID) -> Bool {
        guard let session = views[id]?.session else { return false }
        return session.status.state == .busy || session.foregroundProgram() != nil
    }

    /// What runs in the tab, for a close confirmation: the command line, else the process name.
    func runningCommand(_ id: UUID) -> String? {
        guard let session = views[id]?.session else { return nil }
        let status = session.status
        return status.command.isEmpty ? session.foregroundProgram() ?? status.foregroundProcess : status.command
    }

    /// What runs in each busy terminal, empty when it cannot tell, for the quit confirmation.
    var busyCommands: [String] {
        views.keys.filter(isBusy).map { runningCommand($0) ?? "" }
    }

    func terminate(_ id: UUID) {
        restores[id] = nil
        guard let view = views.removeValue(forKey: id) else { return }
        powerKeeper?.terminalEnded(id)
        unread[id] = nil
        finishedCommands[id] = nil
        compression[id] = nil
        savedOutput[id] = nil
        seenOutput[id] = nil
        saveDue[id] = nil
        // After any save still queued for it, which would write the file back.
        if !keptScreens.contains(id), let url = snapshotURL(id) {
            Self.screenQueue.async { try? FileManager.default.removeItem(at: url) }
        }
        if views.isEmpty {
            compressionTimer?.invalidate()
            compressionTimer = nil
        }
        view.shutdown()
        view.session.terminate()
        view.removeFromSuperview()
    }

    /// At quit, kills each login group after a short grace for logout records, and leaders by pid too (no group exists before setsid).
    /// Descendants in their own session never get the hangup, so each is signaled, or it outlives Lilo and keeps it in the Dock.
    func terminateAllForQuit() {
        let leaders = views.values.map(\.session).filter { $0.pid > 0 && $0.status.state != .exited }.map(\.pid)
        guard !leaders.isEmpty else { return }
        // Listed before any signal: once a shell dies, its children belong to launchd.
        let descendants = leaders.flatMap { AppFreezer.descendants(of: $0).dropFirst() }
        for pid in leaders { kill(-pid, SIGHUP) }
        for pid in descendants { kill(pid, SIGHUP) }
        usleep(50_000)
        for pid in leaders {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
        var remaining = descendants
        for _ in 0..<45 where !remaining.isEmpty {
            remaining.removeAll { kill($0, 0) != 0 }
            if !remaining.isEmpty { usleep(10_000) }
        }
        for pid in remaining { kill(pid, SIGKILL) }
    }

    /// Ends every session whose tab no longer exists or was closed.
    func prune(keeping isAlive: (UUID) -> Bool) {
        for id in views.keys where !isAlive(id) { terminate(id) }
    }

    /// Theme and font from the settings, applied live to every open terminal.
    func setAppearance(_ appearance: Appearance) {
        guard appearance != self.appearance else { return }
        let fontChanged = appearance.fontFamily != self.appearance.fontFamily || appearance.fontSize != self.appearance.fontSize
        let scrollbackChanged = appearance.scrollbackBytes != self.appearance.scrollbackBytes
        self.appearance = appearance
        if scrollbackChanged { restores = [:] }
        let colors = appearance.theme.resolved(surface: surface, accent: accent)
        changesHost?.useTerminalColors(colors)
        for view in views.values {
            apply(colors: colors, to: view)
            view.optionAsMeta = appearance.optionAsMeta
            if scrollbackChanged { view.session.withLockedTerminal { $0.setScrollbackLimit(appearance.scrollbackBytes) } }
            if fontChanged { view.setFont(family: appearance.fontFamily, size: appearance.fontSize) }
        }
    }

    /// Follows Lilo's themed content surface and accent, which themes leave to Lilo by default.
    func setSurface(_ surface: NSColor) {
        let surface = VTColor(surface)
        let accent = VTColor(NSColor.controlAccentColor)
        guard surface != self.surface || accent != self.accent else { return }
        self.surface = surface
        self.accent = accent
        let colors = appearance.theme.resolved(surface: surface, accent: accent)
        changesHost?.useTerminalColors(colors)
        for view in views.values { apply(colors: colors, to: view) }
    }

    /// Colors of the current appearance on the current surface, for previews.
    func resolvedColors(for theme: TerminalTheme) -> TerminalTheme.Resolved {
        theme.resolved(surface: surface, accent: accent)
    }

    private func apply(colors: TerminalTheme.Resolved, to view: TerminalView) {
        view.session.withLockedTerminal { terminal in
            terminal.setDefaultColors(background: colors.background, foreground: colors.foreground, cursor: colors.cursor)
            terminal.setPalette(colors.palette)
        }
        view.renderLoop.setHighlightColors(
            selection: colors.selection, match: colors.match,
            marks: (success: colors.palette[2], failure: colors.palette[1])
        )
    }
}
