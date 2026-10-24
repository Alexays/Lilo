import Darwin
import Foundation
import os
import Synchronization

/// A shell on a pty, parsed by libghostty-vt. A gather thread drains the pty into a ring of
/// buffers, a parse thread feeds the terminal, and a serial queue writes input.
/// Owners must call `terminate()`: the threads keep the session alive until the shell is gone.
final class TerminalSession: @unchecked Sendable {
    enum State: String, Sendable {
        case idle, busy, succeeded, failed, exited
    }

    struct Status: Equatable, Sendable {
        var title = ""
        var cwd: String?
        /// The branch checked out in `cwd`'s repository, or a short commit when detached.
        var gitBranch: String?
        /// Lines added and removed in that repository against HEAD, untracked files included.
        var diffAdded = 0
        var diffRemoved = 0
        var foregroundProcess: String?
        var state = State.idle
        /// Nil for the login shell: login reports success whatever the shell returned.
        var exitCode: Int32?
        /// The tty reads a line without echoing it: a password prompt (sudo, ssh, gpg).
        var readsPassword = false
        /// The running command line, or the last one; empty when the shell does not report it.
        var command = ""
        /// When the running command started; nil at the prompt.
        var commandStarted: Date?
        var lastExitCode: Int32?
        var lastDuration: TimeInterval?
        /// Counts finished commands, so a listener tells a new result from a repeated status.
        var finishedCommands = 0
        /// Output arrived in the last few seconds. A running command that stays quiet (an editor,
        /// an assistant waiting at its prompt) is running, not working.
        var printing = false
        /// When the running program rang the bell or asked for a notification with no input since:
        /// an agent waiting for an answer.
        var awaitingInputSince: Date?
        /// The running program turned bracketed paste on: an interactive prompt (an agent, an editor,
        /// a REPL). Shells turn it off before running a command, so a quiet one is waiting, not working.
        var bracketedPaste = false
    }

    private static let slotSize = 64 * 1024
    private static let slotCount = 4

    /// Set before `start()`. Delivered on the main thread, coalesced.
    @MainActor var onStatusChange: ((Status) -> Void)?
    /// A program asked for a desktop notification: title (may be empty) and body, on the main thread.
    @MainActor var onDesktopNotification: ((String, String) -> Void)?
    /// Set before `start()`. Called on the parse thread after each batch, outside the terminal lock.
    var onOutput: (@Sendable () -> Void)?

    let terminal: VTTerminal
    private(set) var pid: pid_t = 0
    /// Mouse tracking and key-release reporting as of the last parsed batch, so input events skip
    /// the terminal lock while the program asked for neither.
    let tracksMouse = Atomic<Bool>(false)
    let reportsKeyReleases = Atomic<Bool>(false)
    /// History compression activity as of the last parsed batch or compression pass, read without the lock.
    let compressionActivity = Atomic<UInt64>(0)
    /// No view shows the terminal: the IO threads drop to utility at their next batch.
    let inBackground = Atomic<Bool>(false)

    private let command: [String]
    private let reportsExitCode: Bool
    private let shellName: String
    private let initialCwd: String
    private let initialCommand: String?
    private let prefillCommand: String?
    /// The terminal starts from a snapshot of the last session's screen and history.
    private let restoredContent: Bool
    private var windowSize: winsize
    // Both fds are only touched on `writeQueue` once the session has started, so neither is used
    // after close.
    private var ptyFD: Int32 = -1
    private var quitPipe: [Int32] = [-1, -1]
    private var processSource: DispatchSourceProcess?

    private let ring = UnsafeMutableRawPointer.allocate(byteCount: TerminalSession.slotSize * TerminalSession.slotCount, alignment: 16)
    private let slotLengths = UnsafeMutablePointer<Int>.allocate(capacity: TerminalSession.slotCount)
    /// Starts at zero and is signalled up in init: libdispatch traps when a semaphore is freed
    /// below its initial value, which the gather thread's last held slot would cause.
    private let freeSlots = DispatchSemaphore(value: 0)
    private let filledSlots = DispatchSemaphore(value: 0)

    private let lock = OSAllocatedUnfairLock()
    private let renderDemand = Atomic<Int>(0)
    private let parserYielding = Atomic<Bool>(false)
    private let rendererDone = DispatchSemaphore(value: 0)

    private let writeQueue = DispatchQueue(label: "fr.arouillard.lilo.terminal.write", qos: .userInteractive)
    // Serial, so a slow read for an old directory never lands after the current one.
    private let gitQueue = DispatchQueue(label: "fr.arouillard.lilo.terminal.git", qos: .utility)
    private let gitRefreshPending = Atomic<Bool>(false)
    private let gitStatRequested = Atomic<Bool>(false)
    /// Uptime of the last line count, and whether a deferred one is queued: one stat per interval.
    private let lastGitStat = Atomic<UInt64>(0)
    private let gitStatDeferred = Atomic<Bool>(false)
    /// Directory of the last line count; only touched on gitQueue.
    private var lastGitStatCwd: String?
    private static let gitStatInterval: UInt64 = 5_000_000_000
    private let statusLock = OSAllocatedUnfairLock(initialState: Status())
    private let statusPostPending = Atomic<Bool>(false)
    private let terminated = Atomic<Bool>(false)
    private let shellReportsCwd = Atomic<Bool>(false)
    private let shellReportsPrompts = Atomic<Bool>(false)
    private let readsPassword = Atomic<Bool>(false)
    /// Mirrors `status.awaitingInputSince != nil`, so a keystroke checks it without the status lock.
    private let awaitingInput = Atomic<Bool>(false)
    private let parsedBatches = Atomic<Int>(0)
    /// The view has keyboard focus: the IO threads rise to user-interactive at their next batch.
    private let focused = Atomic<Bool>(false)
    /// Mode 1004 as of the last parsed batch. Parse thread only.
    private var reportsFocus = false
    /// Mode 2004 as of the last parsed batch. Parse thread only.
    private var bracketedPaste = false
    private static let quietAfter: UInt64 = 3_000_000_000
    private let lastOutput = Atomic<UInt64>(0)
    private let quietCheckPending = Atomic<Bool>(false)

    /// `command` defaults to the user's login shell; the shell runs `initialCommand` at its first prompt.
    /// zsh types `prefillCommand` at its first prompt without running it. `restored` is the terminal
    /// decoded from the screen and history a previous session saved.
    init(
        cwd: String, cols: UInt16 = 80, rows: UInt16 = 24, command: [String]? = nil, initialCommand: String? = nil,
        prefillCommand: String? = nil, scrollbackBytes: Int = 10_000_000, restored: VTTerminal? = nil
    ) {
        self.initialCommand = initialCommand
        self.prefillCommand = prefillCommand
        let account = getpwuid(getuid())
        let shell = account.map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        reportsExitCode = command != nil
        if let command {
            self.command = command
        } else {
            let user = account.map { String(cString: $0.pointee.pw_name) } ?? NSUserName()
            // login records the session and keeps our environment (-p) and cwd (-l); bash then
            // replaces itself with the user's shell as a login shell.
            self.command = ["/usr/bin/login", "-flp", user, "/bin/bash", "--noprofile", "--norc", "-c", "exec -l '\(shell)'"]
        }
        shellName = URL(fileURLWithPath: command?.first ?? shell).lastPathComponent
        var isDirectory: ObjCBool = false
        initialCwd = FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory) && isDirectory.boolValue
            ? cwd : NSHomeDirectory()
        windowSize = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        for _ in 0..<Self.slotCount { freeSlots.signal() }
        restoredContent = restored != nil
        terminal = restored ?? VTTerminal(cols: cols, rows: rows, scrollbackBytes: scrollbackBytes)
        compressionActivity.store(terminal.compressionActivity, ordering: .relaxed)
        terminal.onWritePty = { [unowned self] bytes in send(Array(bytes)) }
        terminal.onTitleChanged = { [unowned self] in
            // Agents lead their title with a spinner frame: without it, the status changes only
            // when the text does.
            let title = String(String.UnicodeScalarView(terminal.title.unicodeScalars.drop {
                $0.properties.generalCategory == .otherSymbol || $0.properties.isWhitespace
            }))
            updateStatus { $0.title = title }
        }
        terminal.onPwdChanged = { [unowned self] in
            let raw = terminal.pwd
            // OSC 7 carries a file:// URL with a percent-encoded path.
            let path = URL(string: raw).flatMap { $0.isFileURL ? $0.path(percentEncoded: false) : nil } ?? raw
            shellReportsCwd.store(true, ordering: .relaxed)
            // Shells report the directory at every prompt: the line counts follow a move only.
            let moved = status.cwd != path
            updateStatus { $0.cwd = path }
            refreshGitBranch(withStat: moved)
        }
        terminal.onDesktopNotification = { [weak self] title, body in
            self?.noteAwaitingInput()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onDesktopNotification?(title, body) } }
        }
        terminal.onBell = { [weak self] in self?.noteAwaitingInput() }
        terminal.onPrompt = { [unowned self] event in
            shellReportsPrompts.store(true, ordering: .relaxed)
            updateStatus { status in
                guard status.state != .exited else { return }
                switch event {
                case .promptStart:
                    if status.state == .busy { status.state = .idle }
                    // A title belongs to the program that set it, not to the next command.
                    status.title = ""
                    status.commandStarted = nil
                    status.awaitingInputSince = nil
                    awaitingInput.store(false, ordering: .relaxed)
                case .outputStart(let command):
                    status.state = .busy
                    status.command = command ?? ""
                    status.commandStarted = Date()
                case .commandEnd(let exitCode):
                    status.state = exitCode.map { $0 == 0 ? .succeeded : .failed } ?? .idle
                    status.lastExitCode = exitCode
                    status.lastDuration = status.commandStarted.map { Date().timeIntervalSince($0) }
                    status.commandStarted = nil
                    status.awaitingInputSince = nil
                    awaitingInput.store(false, ordering: .relaxed)
                    status.finishedCommands += 1
                }
            }
            // A command can switch branches (checkout, rebase) without leaving the directory.
            if case .commandEnd = event { refreshGitBranch(withStat: true) }
        }
    }

    deinit {
        ring.deallocate()
        slotLengths.deallocate()
    }

    var status: Status { statusLock.withLock { $0 } }

    /// Grows with every batch of output parsed: a terminal whose count has not moved has nothing
    /// new to save.
    var outputBatches: Int { parsedBatches.load(ordering: .relaxed) }

    /// Call once, on the main thread; later calls do nothing.
    func start() throws {
        guard pid == 0 else { return }
        var spawnAttributes = posix_spawnattr_t(bitPattern: 0)
        posix_spawnattr_init(&spawnAttributes)
        defer { posix_spawnattr_destroy(&spawnAttributes) }
        // SETEXEC turns the forked child into the program in one call, so nothing allocates after fork.
        posix_spawnattr_setflags(&spawnAttributes, Int16(POSIX_SPAWN_SETEXEC | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&spawnAttributes, &defaultSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&spawnAttributes, &noSignals)

        var actions = posix_spawn_file_actions_t(bitPattern: 0)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // forkpty wires the tty to 0, 1 and 2; CLOEXEC_DEFAULT closes every other inherited fd.
        for fd: Int32 in 0...2 { posix_spawn_file_actions_addinherit_np(&actions, fd) }
        posix_spawn_file_actions_addchdir(&actions, initialCwd)

        let argv = command.map { strdup($0) } + [nil]
        let envp = environment().map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        guard pipe(&quitPipe) == 0 else { throw Self.posixError(errno) }
        var execPipe: [Int32] = [-1, -1]
        guard pipe(&execPipe) == 0 else {
            let error = errno
            quitPipe.forEach { close($0) }
            throw Self.posixError(error)
        }
        // Lilo spawns other programs too; neither pipe may leak into them.
        for fd in quitPipe + execPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        // posix_spawn alone cannot give the child a controlling tty (setsid, then TIOCSCTTY), so
        // forkpty does that in the child before it execs.
        var pty: Int32 = -1
        let child = forkpty(&pty, nil, nil, &windowSize)
        if child == 0 {
            posix_spawn(nil, argv[0], &actions, &spawnAttributes, argv, envp)
            _exit(127)
        }
        let error = errno
        // Before the child execs, a hangup is lost: it has no group yet and the tty is not its own,
        // so closing the pty hangs up no one. Its exec closes the pipe's last write end.
        close(execPipe[1])
        var byte: UInt8 = 0
        while read(execPipe[0], &byte, 1) < 0, errno == EINTR {}
        close(execPipe[0])
        guard child > 0 else {
            close(quitPipe[0])
            close(quitPipe[1])
            throw Self.posixError(error)
        }
        var attributes = termios()
        tcgetattr(pty, &attributes)
        attributes.c_iflag |= tcflag_t(IUTF8)
        tcsetattr(pty, TCSANOW, &attributes)
        _ = fcntl(pty, F_SETFD, FD_CLOEXEC)
        _ = fcntl(pty, F_SETFL, fcntl(pty, F_GETFL) | O_NONBLOCK)
        let fd = pty
        writeQueue.sync { ptyFD = fd }
        pid = child

        if restoredContent {
            // A new shell under the last session's output: whatever mode a program had left on
            // (full screen, kitty keyboard, mouse, focus reports, bracketed paste) went with it.
            let reset = "\u{1b}[?1049l\u{1b}[<99u\u{1b}[!p\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006l\u{1b}[?1004l\u{1b}[?2004l\r\n\u{1b}[2m"
                + "Restored from the last session".localized + "\u{1b}[0m\r\n"
            let bytes = Array(reset.utf8)
            withLockedTerminal { terminal in bytes.withUnsafeBytes { terminal.write($0) } }
        }

        let source = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .main)
        // Holds the session until the child is reaped: `reapChild` cancels the source.
        source.setEventHandler { [self] in
            // The exit event can come a moment before the child is waitable: that wait blocks off the main thread,
            // which still reaps, so the pid never names another process while the session holds it.
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                var info = siginfo_t()
                while waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) < 0, errno == EINTR {}
                DispatchQueue.main.async { [self] in reapChild() }
            }
        }
        source.resume()
        processSource = source
        // The child may have exited before the source was armed.
        reapChild()

        let gather = Thread { [self] in gatherLoop(fd: fd) }
        gather.name = "lilo.terminal.gather"
        gather.qualityOfService = .userInitiated
        gather.start()
        let parse = Thread { [self] in parseLoop() }
        parse.name = "lilo.terminal.parse"
        parse.qualityOfService = .userInitiated
        parse.start()
        // zsh takes it from the environment at its first prompt (see .zshrc); other shells read it as typed input.
        if let initialCommand, shellName != "zsh" { write(Array((initialCommand + "\r").utf8)) }
    }

    /// Queues what the user typed or pasted for the shell; it answers a program waiting for input.
    /// Safe from any thread.
    func write(_ bytes: [UInt8]) {
        if awaitingInput.exchange(false, ordering: .relaxed) { updateStatus { $0.awaitingInputSince = nil } }
        send(bytes)
    }

    /// What a program shows at the bottom of its screen: its last eight lines and, when it offers
    /// a numbered menu ("1. Yes", "> 2. No"), the menu's options and the line that asks.
    struct Prompt: Equatable, Sendable {
        struct Choice: Equatable, Sendable {
            let key: String
            let label: String
        }
        var lines: [String] = []
        var question = ""
        var choices: [Choice] = []
    }

    func prompt() -> Prompt {
        guard let text = withLockedTerminal({ $0.activeScreenText }) else { return Prompt() }
        // Box borders and rules carry no words: drop them, and the frame around boxed lines.
        let frame = CharacterSet(charactersIn: "│┃║|╭╮╰╯─━═┌┐└┘├┤┬┴┼╔╗╚╝").union(.whitespaces)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: frame) }
            .filter { !$0.isEmpty }
        var prompt = Prompt(lines: Array(lines.suffix(8)))
        // The menu is the last run of options numbered from 1, a cursor marker allowed before it.
        var choices: [(index: Int, choice: Prompt.Choice)] = []
        for (index, line) in lines.enumerated() {
            let item = line.drop { "›❯>▶ ".contains($0) }
            guard let digit = item.first, digit.isNumber, let number = digit.wholeNumberValue,
                  item.dropFirst().first.map({ $0 == "." || $0 == ")" }) == true else { continue }
            let label = item.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            if number == 1 { choices = [] }
            guard number == choices.count + 1 else { continue }
            choices.append((index, Prompt.Choice(key: String(digit), label: label)))
        }
        // A numbered list higher up is prose; a menu sits at the bottom, a hint line or two below it.
        guard choices.count >= 2, let first = choices.first?.index, let last = choices.last?.index,
              lines.count - 1 - last <= 3 else { return prompt }
        prompt.choices = choices.map(\.choice)
        prompt.question = lines[..<first].last(where: { $0.hasSuffix("?") }) ?? lines[..<first].last ?? ""
        return prompt
    }

    /// Tells a program that asked for focus reports (mode 1004) that the view gained or lost focus.
    func reportFocus(_ gained: Bool) {
        focused.store(gained, ordering: .relaxed)
        let bytes = withLockedTerminal { $0.encodeFocus(gained) }
        if !bytes.isEmpty { write(bytes) }
    }

    /// Queues bytes for the shell, including the terminal's own replies to queries.
    private func send(_ bytes: [UInt8]) {
        writeQueue.async { [self] in
            var offset = 0
            while offset < bytes.count, ptyFD >= 0, !terminated.load(ordering: .relaxed) {
                let count = bytes.withUnsafeBytes { Darwin.write(ptyFD, $0.baseAddress! + offset, bytes.count - offset) }
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EAGAIN {
                    var output = pollfd(fd: ptyFD, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&output, 1, 100)
                } else if count >= 0 || errno != EINTR {
                    return
                }
            }
        }
    }

    /// Resizes the grid and tells the shell (SIGWINCH). Meant for the end of a live resize.
    func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {
        withLockedTerminal { $0.resize(cols: cols, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight) }
        windowSize = winsize(
            ws_row: rows, ws_col: cols,
            ws_xpixel: UInt16(clamping: UInt32(cols) * cellWidth),
            ws_ypixel: UInt16(clamping: UInt32(rows) * cellHeight)
        )
        let size = windowSize
        writeQueue.async { [self] in
            var size = size
            if ptyFD >= 0 { _ = ioctl(ptyFD, TIOCSWINSZ, &size) }
        }
    }

    /// Exclusive access to the terminal. The parse thread steps aside after its current batch
    /// while a caller waits here.
    @discardableResult
    func withLockedTerminal<R>(_ body: (VTTerminal) -> R) -> R {
        renderDemand.add(1, ordering: .acquiringAndReleasing)
        defer {
            renderDemand.subtract(1, ordering: .acquiringAndReleasing)
            if parserYielding.exchange(false, ordering: .acquiringAndReleasing) { rendererDone.signal() }
        }
        return lock.withLockUnchecked { body(terminal) }
    }

    /// Hangs up the shell and stops the IO threads. The session cannot be restarted.
    func terminate() {
        guard pid > 0, !terminated.exchange(true, ordering: .acquiringAndReleasing) else { return }
        // Once reaped, the leader's pid may already belong to another process group.
        if status.state != .exited { kill(-pid, SIGHUP) }
        killUntilReaped()
        writeQueue.async { [self] in
            var byte: UInt8 = 0
            if quitPipe[1] >= 0 { _ = Darwin.write(quitPipe[1], &byte, 1) }
        }
    }

    /// Backs up the hangup for a shell that survives it. Until reaped, the leader keeps its pid, so
    /// the group cannot be someone else's.
    private func killUntilReaped() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            guard status.state != .exited else { return }
            kill(-pid, SIGKILL)
            killUntilReaped()
        }
    }

    /// Reads the foreground process and its cwd from the kernel. Cheap, but meant for events
    /// (Enter, focus, close), never a timer: there is no change notification to rely on.
    func refreshForegroundProcess() {
        writeQueue.async { [self] in
            guard ptyFD >= 0 else { return }
            let group = tcgetpgrp(ptyFD)
            guard group > 0, let process = Self.processName(group) else { return }
            var info = proc_vnodepathinfo()
            let infoSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            let cwd = proc_pidinfo(group, PROC_PIDVNODEPATHINFO, 0, &info, infoSize) == infoSize
                ? withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                : nil
            let isShell = process == shellName || process == "login"
            updateStatus { status in
                status.foregroundProcess = process
                // Shell integration is authoritative; the kernel fills in for shells without it.
                if !shellReportsCwd.load(ordering: .relaxed), let cwd { status.cwd = cwd }
                if !shellReportsPrompts.load(ordering: .relaxed), status.state != .exited {
                    status.state = isShell ? .idle : .busy
                }
            }
            if !shellReportsCwd.load(ordering: .relaxed) { refreshGitBranch(withStat: true) }
        }
    }

    /// The program holding the terminal right now, nil while the shell does: asked of the kernel
    /// through the child's pid, since prompt marks miss shells without integration and nested
    /// shells (ssh) reporting their own prompts, and the write queue can be stuck on a full pty.
    func foregroundProgram() -> String? {
        guard pid > 0, status.state != .exited else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let group = info.kp_eproc.e_tpgid
        guard group > 0, group != pid else { return nil }
        // Under login, the shell is login's child; anything it runs is further down.
        if !reportsExitCode {
            mib[3] = group
            size = MemoryLayout<kinfo_proc>.size
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_eproc.e_ppid != pid else { return nil }
        }
        return Self.processName(group)
    }

    private static func processName(_ pid: pid_t) -> String? {
        var name = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
        return name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// The line counts were read less than an interval ago.
    var gitStatIsRecent: Bool {
        DispatchTime.now().uptimeNanoseconds - lastGitStat.load(ordering: .relaxed) < Self.gitStatInterval
    }

    /// Reads the branch, and with `withStat` runs git for the line counts. Requests made while one
    /// waits on the queue ride along with it; a stat within the interval of the last one is
    /// deferred to a single run at its end.
    func refreshGitBranch(withStat: Bool) {
        if withStat { gitStatRequested.store(true, ordering: .relaxed) }
        guard !gitRefreshPending.exchange(true, ordering: .acquiringAndReleasing) else { return }
        gitQueue.async { [self] in
            gitRefreshPending.store(false, ordering: .releasing)
            let statRequested = gitStatRequested.exchange(false, ordering: .relaxed)
            var withStat = statRequested
            guard let cwd = status.cwd else { return }
            let branch = Self.gitBranch(in: cwd)
            // A new directory is a new repository's counts: never throttled behind the old one's.
            if withStat, branch != nil, gitStatIsRecent, cwd == lastGitStatCwd {
                withStat = false
                if !gitStatDeferred.exchange(true, ordering: .relaxed) {
                    let due = lastGitStat.load(ordering: .relaxed) + Self.gitStatInterval
                    gitQueue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: due)) { [weak self] in
                        guard let self, !terminated.load(ordering: .relaxed) else { return }
                        gitStatDeferred.store(false, ordering: .relaxed)
                        refreshGitBranch(withStat: true)
                    }
                }
            }
            PerfSignposts.energy.emitEvent("gitRefresh", "withStat: \(withStat), deferred: \(statRequested && branch != nil && !withStat)")
            let counts = branch != nil && withStat ? GitDiff.stat(in: cwd) : nil
            // Stamped once git returns: the interval starts at the end of a slow run, not before it.
            if branch != nil, withStat {
                lastGitStat.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)
                lastGitStatCwd = cwd
            }
            updateStatus { status in
                status.gitBranch = branch
                if branch == nil {
                    status.diffAdded = 0
                    status.diffRemoved = 0
                } else if let counts {
                    status.diffAdded = counts.added
                    status.diffRemoved = counts.removed
                }
            }
        }
    }

    /// The branch checked out in the repository holding `directory`, or a short commit when
    /// detached; nil outside a repository. Reads `.git/HEAD` directly: no git process per prompt.
    static func gitBranch(in directory: String) -> String? {
        var folder = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        while true {
            var gitDirectory = folder.appendingPathComponent(".git", isDirectory: true)
            // A linked worktree or a submodule has a .git file naming its real git directory.
            if let link = try? String(contentsOf: gitDirectory, encoding: .utf8), link.hasPrefix("gitdir: ") {
                let path = link.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
                gitDirectory = URL(fileURLWithPath: path, isDirectory: true, relativeTo: folder)
            }
            if let head = try? String(contentsOf: gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8) {
                let head = head.trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = "ref: refs/heads/"
                return head.hasPrefix(prefix) ? String(head.dropFirst(prefix.count)) : String(head.prefix(7))
            }
            if folder.path == "/" { return nil }
            folder.deleteLastPathComponent()
        }
    }

    private func gatherLoop(fd: Int32) {
        var fds = [
            pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
            pollfd(fd: quitPipe[0], events: Int16(POLLIN), revents: 0)
        ]
        var slot = 0
        var qos = QOS_CLASS_USER_INITIATED
        while true {
            freeSlots.wait()
            fds[0].revents = 0
            fds[1].revents = 0
            guard poll(&fds, 2, -1) >= 0 || errno == EINTR || errno == EAGAIN, fds[1].revents == 0 else { break }
            let wanted = inBackground.load(ordering: .relaxed) ? QOS_CLASS_UTILITY
                : focused.load(ordering: .relaxed) ? QOS_CLASS_USER_INTERACTIVE : QOS_CLASS_USER_INITIATED
            if wanted != qos {
                qos = wanted
                pthread_set_qos_class_self_np(qos, 0)
            }

            let buffer = ring + slot * Self.slotSize
            var filled = 0
            var hangup = false
            let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            while filled < Self.slotSize {
                let count = read(fd, buffer + filled, Self.slotSize - filled)
                if count > 0 {
                    filled += count
                    continue
                }
                if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    hangup = true
                    break
                }
                // A pty read returns about 1 KiB at most: a small burst (an echo) ships now, a
                // saturated stream keeps gathering for up to 3 ms so the parser gets full batches.
                let elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started
                if filled < 1024 || elapsed > 3_000_000 { break }
                var input = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                _ = poll(&input, 1, Int32((3_000_000 - elapsed + 999_999) / 1_000_000))
            }
            if filled > 0 {
                // Programs turn echo off before printing their password prompt, so output is when to look.
                // A prompt ends a batch without a newline: lines of a flood skip the syscall, unless a password read may be ending.
                var attributes = termios()
                if filled < 1024 || buffer.load(fromByteOffset: filled - 1, as: UInt8.self) != 0x0A || readsPassword.load(ordering: .relaxed), tcgetattr(fd, &attributes) == 0 {
                    let secret = attributes.c_lflag & tcflag_t(ECHO) == 0 && attributes.c_lflag & tcflag_t(ICANON) != 0
                    if readsPassword.exchange(secret, ordering: .relaxed) != secret { updateStatus { $0.readsPassword = secret } }
                }
                slotLengths[slot] = filled
                filledSlots.signal()
                slot = (slot + 1) % Self.slotCount
                continue // A hangup shows up again on the next pass, after this batch is queued.
            }
            if hangup { break }
            freeSlots.signal()
        }
        // The slot taken at the top of the loop carries the end marker.
        slotLengths[slot] = -1
        filledSlots.signal()
    }

    private func parseLoop() {
        var slot = 0
        var qos = QOS_CLASS_USER_INITIATED
        while true {
            filledSlots.wait()
            let length = slotLengths[slot]
            if length < 0 { break }
            let wanted = inBackground.load(ordering: .relaxed) ? QOS_CLASS_UTILITY
                : focused.load(ordering: .relaxed) ? QOS_CLASS_USER_INTERACTIVE : QOS_CLASS_USER_INITIATED
            if wanted != qos {
                qos = wanted
                pthread_set_qos_class_self_np(qos, 0)
            }
            let bytes = UnsafeRawBufferPointer(start: ring + slot * Self.slotSize, count: length)
            let (focusReport, pastesBracketed) = lock.withLockUnchecked {
                terminal.write(bytes)
                tracksMouse.store(terminal.tracksMouse, ordering: .relaxed)
                reportsKeyReleases.store(terminal.reportsKeyReleases, ordering: .relaxed)
                compressionActivity.store(terminal.compressionActivity, ordering: .relaxed)
                // A program turning focus reports on gets the current state at once: until a
                // report comes it assumes focus, and agents animate twice as fast for it.
                let reports = terminal.mode(1004)
                defer { reportsFocus = reports }
                return (reports && !reportsFocus ? terminal.encodeFocus(focused.load(ordering: .relaxed)) : [], terminal.mode(2004))
            }
            if !focusReport.isEmpty { send(focusReport) }
            if pastesBracketed != bracketedPaste {
                bracketedPaste = pastesBracketed
                updateStatus { $0.bracketedPaste = pastesBracketed }
            }
            parsedBatches.add(1, ordering: .relaxed)
            notePrinting()
            freeSlots.signal()
            slot = (slot + 1) % Self.slotCount
            onOutput?()
            // Unfair locks let this thread retake the lock ahead of a waiting renderer during a flood.
            // A waiter starved of CPU may miss a 1 ms slice: keep stepping aside until one gets through, up to 10 ms.
            if renderDemand.load(ordering: .acquiring) > 0 {
                let deadline = DispatchTime.now() + .milliseconds(10)
                var served = false
                repeat {
                    parserYielding.store(true, ordering: .releasing)
                    served = rendererDone.wait(timeout: min(.now() + .milliseconds(1), deadline)) == .success
                    parserYielding.store(false, ordering: .releasing)
                } while !served && renderDemand.load(ordering: .acquiring) > 0 && DispatchTime.now() < deadline
            }
        }
        // The callback holds the view's render loop, which holds this session. Only this thread
        // reads it, so it can go now.
        onOutput = nil
        // Queued behind pending writes, so no write ever lands on a closed or reused fd.
        writeQueue.async { [self] in
            close(ptyFD)
            close(quitPipe[0])
            close(quitPipe[1])
            ptyFD = -1
            quitPipe = [-1, -1]
        }
    }

    private func reapChild() {
        var status: Int32 = 0
        guard pid > 0, waitpid(pid, &status, WNOHANG) == pid else { return }
        processSource?.cancel()
        // Shell convention: 128 + signal number for a process killed by a signal.
        let signal = status & 0x7f
        let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        let reportsExitCode = reportsExitCode
        updateStatus {
            $0.state = .exited
            $0.exitCode = reportsExitCode ? code : nil
            $0.awaitingInputSince = nil
        }
        awaitingInput.store(false, ordering: .relaxed)
    }

    /// A bell or a notification from a running program, not from a shell at its prompt (a failed
    /// completion), means it waits for an answer.
    private func noteAwaitingInput() {
        let reportsPrompts = shellReportsPrompts.load(ordering: .relaxed)
        updateStatus { status in
            guard status.awaitingInputSince == nil, status.state != .exited,
                  !reportsPrompts || status.state == .busy else { return }
            status.awaitingInputSince = Date()
            awaitingInput.store(true, ordering: .relaxed)
        }
    }

    /// Marks output as recent, and arranges one check that clears it once output stops: a check
    /// per quiet period, not per batch.
    private func notePrinting() {
        lastOutput.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)
        guard !quietCheckPending.exchange(true, ordering: .acquiringAndReleasing) else { return }
        updateStatus { $0.printing = true }
        scheduleQuietCheck(after: Self.quietAfter)
    }

    private func scheduleQuietCheck(after delay: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) { [weak self] in
            guard let self else { return }
            let quiet = DispatchTime.now().uptimeNanoseconds - lastOutput.load(ordering: .relaxed)
            if quiet < Self.quietAfter { return scheduleQuietCheck(after: Self.quietAfter - quiet) }
            quietCheckPending.store(false, ordering: .releasing)
            updateStatus { $0.printing = false }
            // A program that goes quiet (an agent between edits) may have changed files. A hidden
            // terminal skips it: the host reads its counts once it is shown.
            if status.state == .busy, !inBackground.load(ordering: .relaxed) { refreshGitBranch(withStat: true) }
        }
    }

    private func updateStatus(_ change: (inout Status) -> Void) {
        let changed = statusLock.withLockUnchecked { status in
            let previous = status
            change(&status)
            return status != previous
        }
        // One main-thread hop per burst: later changes ride along with the pending one.
        guard changed, !statusPostPending.exchange(true, ordering: .acquiringAndReleasing) else { return }
        DispatchQueue.main.async { [self] in
            statusPostPending.store(false, ordering: .releasing)
            let current = status
            MainActor.assumeIsolated { onStatusChange?(current) }
        }
    }

    private func environment() -> [String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Lilo"
        // Apps launched from the Finder get no LANG, which leaves shells and tools in the C locale.
        if environment["LANG"] == nil {
            var lang = "en_US.UTF-8"
            let locale = Locale.current
            if let language = locale.language.languageCode?.identifier, let region = locale.region?.identifier {
                // UI language and region do not always form a shipped locale (English UI in France).
                let candidate = "\(language)_\(region).UTF-8"
                if FileManager.default.fileExists(atPath: "/usr/share/locale/\(candidate)") { lang = candidate }
            }
            environment["LANG"] = lang
        }
        #if SWIFT_PACKAGE
        let integration = Bundle.module.url(forResource: "shell-integration", withExtension: nil, subdirectory: "Resources")
        #else
        let integration = Bundle.main.url(forResource: "shell-integration", withExtension: nil)
        #endif
        if let integration {
            // zsh reads $ZDOTDIR/.zshenv first; ours restores the user's ZDOTDIR before their config.
            if let original = environment["ZDOTDIR"] { environment["LILO_ORIG_ZDOTDIR"] = original }
            environment["ZDOTDIR"] = integration.appendingPathComponent("zsh").path
            if shellName == "zsh", let initialCommand { environment["LILO_INITIAL_COMMAND"] = initialCommand }
            if shellName == "zsh", let prefillCommand { environment["LILO_PREFILL_COMMAND"] = prefillCommand }
        }
        return environment.map { "\($0.key)=\($0.value)" }
    }

    private static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
