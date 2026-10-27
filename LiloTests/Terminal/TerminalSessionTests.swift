import GhosttyVt
import XCTest
@testable import Lilo

@MainActor
final class TerminalSessionTests: XCTestCase {
    private var sessions: [TerminalSession] = []

    override func tearDown() async throws {
        sessions.forEach { $0.terminate() }
        sessions = []
    }

    func testPromptOffersTheMenuAProgramWaitsOn() async throws {
        let session = try launch(["/bin/sh", "-c", """
            printf 'Plan:\\r\\n1. Read the code\\r\\n2. Fix it\\r\\n\\r\\n'
            printf '\\342\\225\\255\\342\\224\\200\\342\\224\\200\\r\\n'
            printf '\\342\\224\\202 Bash command: make validate\\r\\n'
            printf '\\342\\224\\202 Do you want to proceed?\\r\\n'
            printf '\\342\\224\\202 \\342\\235\\257 1. Yes\\r\\n\\342\\224\\202   2. No, and tell me why\\r\\n'
            printf 'Esc to cancel'
            sleep 5
            """])
        try await waitUntil { self.screen(session).contains("Esc to cancel") }

        let prompt = session.prompt()
        XCTAssertEqual(prompt.question, "Do you want to proceed?")
        XCTAssertEqual(prompt.choices, [.init(key: "1", label: "Yes"), .init(key: "2", label: "No, and tell me why")])
        XCTAssertEqual(prompt.lines.last, "Esc to cancel")
        XCTAssertFalse(prompt.lines.contains { $0.hasPrefix("\u{256D}") }, "rules and box corners carry no words")
    }

    func testPromptLeavesANumberedListInTheOutputAlone() async throws {
        let session = try launch(["/bin/sh", "-c", "printf '1. Read the code\\r\\n2. Fix it\\r\\na\\r\\nb\\r\\nc\\r\\nd\\r\\nlast line'; sleep 5"])
        try await waitUntil { self.screen(session).contains("last line") }

        XCTAssertEqual(session.prompt().choices, [])
    }

    func testExitCodeIsReported() async throws {
        let session = try launch(["/bin/sh", "-c", "exit 3"])
        try await waitUntil { session.status.state == .exited }
        XCTAssertEqual(session.status.exitCode, 3)
    }

    func testShellStartsInTheRequestedDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lilo terminal \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = try launch(["/bin/pwd", "-P"], cwd: directory.path)

        let expected = directory.resolvingSymlinksInPath().path
        try await waitUntil { self.screen(session).contains(expected) }
    }

    func testMissingDirectoryFallsBackToHome() async throws {
        let session = try launch(["/bin/pwd", "-P"], cwd: "/nonexistent/lilo-\(UUID().uuidString)")

        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        try await waitUntil { self.screen(session).contains(home) }
    }

    func testResizeReachesTheShell() async throws {
        let session = try launch(["/bin/sh", "-c", "sleep 0.5; stty size"])
        session.resize(cols: 100, rows: 30, cellWidth: 8, cellHeight: 16)
        try await waitUntil { self.screen(session).contains("30 100") }
    }

    func testInputRoundTripsThroughCat() async throws {
        let session = try launch(["/bin/cat"])
        session.write(Array("ping\n".utf8))
        // The tty echoes the line, then cat prints it back.
        try await waitUntil { self.screen(session).components(separatedBy: "ping").count - 1 >= 2 }
    }

    func testBellWaitsForAnAnswerUntilTheUserTypes() async throws {
        let session = try launch(["/bin/sh", "-c", "printf '\\a'; read answer; sleep 5"])
        try await waitUntil { session.status.awaitingInputSince != nil }

        session.write(Array("yes\n".utf8))

        try await waitUntil { session.status.awaitingInputSince == nil }
        XCTAssertNotEqual(session.status.state, .exited)
    }

    func testEnvironmentAdvertisesTheTerminal() async throws {
        let session = try launch(["/bin/sh", "-c", "printf '%s|%s|%s' \"$TERM\" \"$COLORTERM\" \"$TERM_PROGRAM\""])
        try await waitUntil { self.screen(session).contains("xterm-256color|truecolor|Lilo") }
    }

    func testLargeOutputArrivesComplete() async throws {
        let session = try launch(["/bin/sh", "-c", "head -c 8000000 /dev/zero | tr '\\0' x; printf 'END-OF-FLOOD'"])
        try await waitUntil(timeout: 20) { session.status.state == .exited }
        try await waitUntil { self.screen(session).contains("END-OF-FLOOD") }
    }

    func testControlCInterruptsAFlood() async throws {
        let session = try launch(["/usr/bin/yes"])
        try await waitUntil { session.outputBatches > 0 }

        session.write([0x03])

        try await waitUntil(timeout: 2) { session.status.state == .exited }
        XCTAssertEqual(session.status.exitCode, 128 + SIGINT)
    }

    func testTerminateDuringFloodStopsTheShell() async throws {
        let session = try launch(["/usr/bin/yes"])
        try await waitUntil { session.outputBatches > 0 }

        session.terminate()

        try await waitUntil(timeout: 2) { session.status.state == .exited }
        XCTAssertEqual(session.status.exitCode, 128 + SIGHUP)
    }

    func testTerminateRightAfterStartStillEndsTheLoginShell() async throws {
        let session = TerminalSession(cwd: NSTemporaryDirectory())
        sessions.append(session)
        try session.start()

        session.terminate()

        try await waitUntil { session.status.state == .exited }
    }

    func testTerminateAfterTheShellExitedTouchesNoReusedFd() async throws {
        let session = try launch(["/bin/sh", "-c", "exit 0"])
        try await waitUntil { session.status.state == .exited }
        try await Task.sleep(for: .milliseconds(200))
        // Fds are reused lowest-first, so these pipes take over the numbers the session closed.
        var probes: [[Int32]] = []
        for _ in 0..<32 {
            var probe: [Int32] = [-1, -1]
            XCTAssertEqual(pipe(&probe), 0)
            _ = fcntl(probe[0], F_SETFL, O_NONBLOCK)
            probes.append(probe)
        }
        defer { probes.flatMap { $0 }.forEach { close($0) } }

        session.terminate()
        try await Task.sleep(for: .milliseconds(200))

        for probe in probes {
            var byte: UInt8 = 0
            XCTAssertEqual(read(probe[0], &byte, 1), -1, "terminate() wrote into reused fd \(probe[1])")
        }
    }

    func testMissingLangFallsBackToAnInstalledLocale() async throws {
        let previousLANG = ProcessInfo.processInfo.environment["LANG"]
        unsetenv("LANG")
        defer {
            if let previousLANG { setenv("LANG", previousLANG, 1) }
        }

        let session = try launch(["/bin/sh", "-c", "printf 'lang=%s;' \"$LANG\""])

        try await waitUntil { self.screen(session).contains(";") }
        let lang = screen(session).components(separatedBy: "lang=").last?.components(separatedBy: ";").first ?? ""
        XCTAssertTrue(FileManager.default.fileExists(atPath: "/usr/share/locale/\(lang)"), "LANG=\(lang) is not an installed locale")
    }

    func testStatusChangesAreDeliveredOnTheMainThread() async throws {
        var titles: [String] = []
        let session = TerminalSession(
            cwd: NSTemporaryDirectory(), cols: 200, rows: 50,
            command: ["/bin/sh", "-c", "printf '\\033]2;from shell\\007'; sleep 1"]
        )
        session.onStatusChange = { status in
            XCTAssertTrue(Thread.isMainThread)
            titles.append(status.title)
        }
        sessions.append(session)
        try session.start()

        try await waitUntil { titles.last == "from shell" }
    }

    func testTitleDropsTheSpinnerFrameAgentsLeadWith() async throws {
        var titles: [String] = []
        let session = TerminalSession(
            cwd: NSTemporaryDirectory(), cols: 200, rows: 50,
            command: ["/bin/sh", "-c", "printf '\\033]2;\u{2802} Fixing\\007'; sleep 0.2; printf '\\033]2;\u{2810} Fixing\\007'; printf '\\033]2;\u{2733} Done\\007'; sleep 1"]
        )
        session.onStatusChange = { titles.append($0.title) }
        sessions.append(session)
        try session.start()

        try await waitUntil { titles.last == "Done" }
        XCTAssertEqual(Set(titles.filter { !$0.isEmpty }), ["Fixing", "Done"])
    }

    func testShellIntegrationReportsCommandResultsAndDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lilo é dir \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A real user config (async prompts) can swallow typed-ahead input, so the test brings its
        // own ZDOTDIR; it also proves the integration hands control back to the user's config.
        let userConfig = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-zdotdir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: userConfig, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: userConfig) }
        // Some frameworks reset the hook arrays; the integration must survive that.
        try "print USER-ZSHRC-LOADED\nprecmd_functions=()\npreexec_functions=()\n"
            .write(to: userConfig.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let previousZDOTDIR = ProcessInfo.processInfo.environment["ZDOTDIR"]
        setenv("ZDOTDIR", userConfig.path, 1)
        defer {
            if let previousZDOTDIR { setenv("ZDOTDIR", previousZDOTDIR, 1) } else { unsetenv("ZDOTDIR") }
        }

        let session = try launch(["/bin/zsh", "-i"])
        // The first prompt reports the directory, so the integration is loaded once cwd is set.
        try await waitUntil(timeout: 15) { session.status.cwd != nil }
        XCTAssertTrue(screen(session).contains("USER-ZSHRC-LOADED"))
        session.write(Array("print -r -- \"histfile:$HISTFILE\"\n".utf8))
        try await waitUntil { self.screen(session).contains("histfile:\(userConfig.path)/.zsh_history") }

        session.write(Array("false\n".utf8))
        try await waitUntil { session.status.state == .failed }
        session.write(Array("true\n".utf8))
        try await waitUntil { session.status.state == .succeeded }
        session.write(Array("cd '\(directory.path)'\n".utf8))
        try await waitUntil { session.status.cwd == directory.path }
    }

    func testZshRunsTheInitialCommandAtItsFirstPrompt() async throws {
        let userConfig = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-zdotdir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: userConfig, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: userConfig) }
        let previousZDOTDIR = ProcessInfo.processInfo.environment["ZDOTDIR"]
        setenv("ZDOTDIR", userConfig.path, 1)
        defer {
            if let previousZDOTDIR { setenv("ZDOTDIR", previousZDOTDIR, 1) } else { unsetenv("ZDOTDIR") }
        }

        let session = TerminalSession(
            cwd: NSTemporaryDirectory(), cols: 200, rows: 50, command: ["/bin/zsh", "-i"],
            initialCommand: "printf 'ran:%s' \"${LILO_INITIAL_COMMAND:-unset}\""
        )
        sessions.append(session)
        try session.start()

        try await waitUntil(timeout: 15) { self.screen(session).contains("ran:unset") }
        try await waitUntil { session.status.state == .succeeded }
    }

    func testBashIntegrationPreservesPromptHooksAndReportsCommands() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lilo bash é dir \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("bashrc")
        try """
            printf 'USER-BASHRC-LOADED\\n'
            HISTFILE='\(directory.path)/history'
            PS1='bash-test> '
            PROMPT_COMMAND='printf "user-status:%s\\n" "$?"'
            trap '[[ $BASH_COMMAND == false ]] && printf "user-debug-hook\\n"' DEBUG
            source "$LILO_BASH_INTEGRATION"
            """.write(to: config, atomically: true, encoding: .utf8)

        for bash in ["/bin/bash", "/opt/homebrew/bin/bash", "/usr/local/bin/bash"] where FileManager.default.isExecutableFile(atPath: bash) {
            let session = try launch([bash, "--rcfile", config.path, "-i"])
            try await waitUntil(timeout: 5) { session.status.cwd != nil }
            guard session.status.cwd != nil else { return }
            XCTAssertTrue(screen(session).contains("USER-BASHRC-LOADED"))
            XCTAssertEqual(session.status.finishedCommands, 0)

            session.write(Array("false\n".utf8))
            try await waitUntil { session.status.state == .failed && self.screen(session).contains("user-status:1") }
            XCTAssertEqual(session.status.lastExitCode, 1)
            XCTAssertEqual(session.status.command, "false")
            XCTAssertTrue(screen(session).contains("user-debug-hook"))
            XCTAssertEqual(session.status.finishedCommands, 1)

            session.write(Array("sleep 30\n".utf8))
            try await waitUntil { session.status.state == .busy && session.foregroundProgram() == "sleep" }
            XCTAssertEqual(session.status.command, "sleep 30")
            session.write([0x03])
            try await waitUntil { session.status.lastExitCode == 130 }
            XCTAssertNotNil(session.status.lastDuration)

            session.write(Array("cd '\(directory.path)'\n".utf8))
            try await waitUntil { session.status.cwd == directory.path }
            XCTAssertEqual(session.status.state, .succeeded)
            XCTAssertEqual(session.status.finishedCommands, 3)
            let command = "shopt -oq posix; printf 'native-bash:%s' \"$?\""
            session.write(Array((command + "\n").utf8))
            try await waitUntil { self.screen(session).contains("native-bash:1") }
            XCTAssertEqual(session.status.command, command)
            session.terminate()
        }
    }

    func testBashIntegrationKeepsLoginShellSemantics() async throws {
        guard let bash = ["/opt/homebrew/bin/bash", "/usr/local/bin/bash"].first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { throw XCTSkip("Automatic integration needs standard Bash; macOS Bash uses the manual hook") }
        let previousHISTFILE = ProcessInfo.processInfo.environment["HISTFILE"]
        let previousENV = ProcessInfo.processInfo.environment["ENV"]
        setenv("HISTFILE", "/dev/null", 1)
        setenv("ENV", "lilo-user-env", 1)
        defer {
            if let previousHISTFILE { setenv("HISTFILE", previousHISTFILE, 1) } else { unsetenv("HISTFILE") }
            if let previousENV { setenv("ENV", previousENV, 1) } else { unsetenv("ENV") }
        }
        let session = try launch([bash, "--noprofile", "-il"])
        try await waitUntil(timeout: 5) { session.status.cwd != nil }
        guard session.status.cwd != nil else { return }

        session.write(Array("shopt -q login_shell && [[ $ENV == lilo-user-env ]] && printf 'LOGIN-SHELL-PRESERVED\\n'\n".utf8))
        try await waitUntil { session.status.finishedCommands == 1 }
        XCTAssertEqual(session.status.lastExitCode, 0)
        XCTAssertTrue(screen(session).components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "LOGIN-SHELL-PRESERVED" })
    }

    func testZshTypesThePrefilledCommandWithoutRunningIt() async throws {
        let userConfig = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-zdotdir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: userConfig, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: userConfig) }
        let previousZDOTDIR = ProcessInfo.processInfo.environment["ZDOTDIR"]
        setenv("ZDOTDIR", userConfig.path, 1)
        defer {
            if let previousZDOTDIR { setenv("ZDOTDIR", previousZDOTDIR, 1) } else { unsetenv("ZDOTDIR") }
        }

        let session = TerminalSession(
            cwd: NSTemporaryDirectory(), cols: 200, rows: 50, command: ["/bin/zsh", "-i"],
            prefillCommand: "print -r -- prefill-ran"
        )
        sessions.append(session)
        try session.start()

        try await waitUntil(timeout: 15) { self.screen(session).contains("print -r -- prefill-ran") }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(screen(session).components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "prefill-ran" }, "typed, not run")
        XCTAssertEqual(session.status.finishedCommands, 0)
    }

    func testRestoredTerminalKeepsTheLastSessionAboveTheNewShell() async throws {
        let previous = VTTerminal(cols: 200, rows: 50, scrollbackBytes: 1_000_000)
        Array("from before the restart\r\n\u{1b}[?1049h".utf8).withUnsafeBytes { previous.write($0) }
        let snapshot = try XCTUnwrap(previous.snapshot())

        let session = TerminalSession(
            cwd: NSTemporaryDirectory(), cols: 200, rows: 50, command: ["/bin/sh", "-c", "printf 'new shell'; sleep 2"],
            restored: VTTerminal(snapshot: snapshot, scrollbackBytes: 1_000_000)
        )
        sessions.append(session)
        try session.start()

        try await waitUntil { self.screen(session).contains("new shell") }
        let screen = screen(session)
        XCTAssertTrue(screen.contains("from before the restart"), "the full-screen mode it was left in is gone")
        XCTAssertTrue(screen.contains("Restored from the last session"))
    }

    func testRestoredTerminalSendsLegacyKeysToTheNewShell() async throws {
        let previous = VTTerminal(cols: 80, rows: 24, scrollbackBytes: 100_000)
        Array("\u{1b}[>1u".utf8).withUnsafeBytes { previous.write($0) }
        let snapshot = try XCTUnwrap(previous.snapshot())

        let session = TerminalSession(
            cwd: NSTemporaryDirectory(), cols: 80, rows: 24, command: ["/bin/sh", "-c", "printf 'new shell'; sleep 2"],
            restored: VTTerminal(snapshot: snapshot, scrollbackBytes: 100_000)
        )
        sessions.append(session)
        try session.start()

        try await waitUntil { self.screen(session).contains("new shell") }
        let controlC = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{03}", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8
        ))
        XCTAssertEqual(VTInputEncoder().encodeKey(controlC, released: false, text: nil, optionIsMeta: false, terminal: session.terminal), [0x03])
    }

    func testRestoredTerminalDoesNotSendFocusReportsToTheNewShell() async throws {
        let previous = VTTerminal(cols: 80, rows: 24, scrollbackBytes: 100_000)
        Array("\u{1b}[?1004h".utf8).withUnsafeBytes { previous.write($0) }
        let snapshot = try XCTUnwrap(previous.snapshot())

        let session = TerminalSession(
            cwd: NSTemporaryDirectory(), cols: 80, rows: 24, command: ["/bin/sh", "-c", "printf 'new shell'; sleep 2"],
            restored: VTTerminal(snapshot: snapshot, scrollbackBytes: 100_000)
        )
        sessions.append(session)
        try session.start()

        try await waitUntil { self.screen(session).contains("new shell") }
        XCTAssertTrue(session.terminal.encodeFocus(true).isEmpty)
    }

    func testAProgramTurningFocusReportsOnIsToldTheTerminalIsUnfocused() async throws {
        let session = try launch(["/bin/sh", "-c", "stty -icanon -echo min 3; printf '\\033[?1004h'; dd bs=3 count=1 2>/dev/null | od -An -c; sleep 2"])

        try await waitUntil { self.screen(session).contains("033   [   O") }
    }

    func testPrintingFadesOnceOutputStops() async throws {
        let session = try launch(["/bin/sh", "-c", "printf 'working'; sleep 10"])

        try await waitUntil { session.status.printing }
        try await waitUntil(timeout: 6) { !session.status.printing }
    }

    func testForegroundProcessIsReadFromTheKernel() async throws {
        let session = try launch(["/bin/sh", "-i"])
        session.write(Array("sleep 5\n".utf8))

        try await waitUntil {
            session.refreshForegroundProcess()
            return session.status.foregroundProcess == "sleep"
        }
        session.write([0x03])
    }

    func testForegroundProgramIsNilWhileTheShellHoldsTheTerminal() async throws {
        let session = try launch(["/bin/sh", "-i"])
        try await waitUntil { self.screen(session).contains("$") }
        XCTAssertNil(session.foregroundProgram())

        session.write(Array("sleep 5\n".utf8))
        try await waitUntil { session.foregroundProgram() == "sleep" }
        session.write([0x03])
        try await waitUntil { session.foregroundProgram() == nil }
    }

    func testWorkingDirectoryFallsBackToTheKernelWithoutShellIntegration() async throws {
        let session = try launch(["/bin/sh", "-i"])
        session.write(Array("cd /usr\n".utf8))

        try await waitUntil {
            session.refreshForegroundProcess()
            return session.status.cwd == "/usr"
        }
    }

    func testGitBranchIsReadFromTheEnclosingRepository() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lilo git \(UUID().uuidString)")
        let nested = root.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "ref: refs/heads/feat/tabs\n".write(to: root.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        XCTAssertEqual(TerminalSession.gitBranch(in: nested.path), "feat/tabs")

        try "1a7f2923e0c4b1d2\n".write(to: root.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        XCTAssertEqual(TerminalSession.gitBranch(in: root.path), "1a7f292")
    }

    func testGitBranchFollowsAWorktreeLink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lilo worktree \(UUID().uuidString)")
        let gitDirectory = root.appendingPathComponent("main/.git/worktrees/side")
        let worktree = root.appendingPathComponent("side")
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "ref: refs/heads/side\n".write(to: gitDirectory.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "gitdir: ../main/.git/worktrees/side\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        XCTAssertEqual(TerminalSession.gitBranch(in: worktree.path), "side")
    }

    func testGitBranchIsNilOutsideARepository() {
        XCTAssertNil(TerminalSession.gitBranch(in: "/"))
    }

    func testDefaultCommandStartsTheUserLoginShell() async throws {
        let session = TerminalSession(cwd: NSTemporaryDirectory(), cols: 200, rows: 50)
        sessions.append(session)
        try session.start()

        // The user's own config can drop a line typed while its prompt is still busy (async
        // widgets), so each command is typed again until it takes.
        var printed = false
        for _ in 0..<6 where !printed {
            session.write(Array("printf 'shell:%s' \"$TERM\"\n".utf8))
            printed = await pollUntil(timeout: 5) { self.screen(session).contains("shell:xterm-256color") }
        }
        XCTAssertTrue(printed)
        // The user's prompt hooks can briefly run their own programs in the foreground.
        try await waitUntil { session.foregroundProgram() == nil }
        var slept = false
        for _ in 0..<5 where !slept {
            session.write(Array("sleep 5\n".utf8))
            slept = await pollUntil(timeout: 3) { session.foregroundProgram() == "sleep" }
        }
        XCTAssertTrue(slept)
        session.write([0x03])
        let deadline = Date().addingTimeInterval(20)
        while session.status.state != .exited, Date() < deadline {
            session.write(Array("exit 3\n".utf8))
            try await Task.sleep(for: .seconds(1))
        }
        XCTAssertEqual(session.status.state, .exited)
        XCTAssertNil(session.status.exitCode, "login reports success whatever the shell returned")
    }

    private func launch(_ command: [String], cwd: String = NSTemporaryDirectory()) throws -> TerminalSession {
        let session = TerminalSession(cwd: cwd, cols: 200, rows: 50, command: command)
        sessions.append(session)
        try session.start()
        return session
    }

    private func screen(_ session: TerminalSession) -> String {
        session.withLockedTerminal { terminal in
            var options = GhosttyFormatterTerminalOptions()
            options.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
            options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
            options.trim = true
            var formatter: GhosttyFormatter?
            guard ghostty_formatter_terminal_new(nil, &formatter, terminal.handle, options) == GHOSTTY_SUCCESS,
                  let formatter else { return "" }
            defer { ghostty_formatter_free(formatter) }
            var bytes: UnsafeMutablePointer<UInt8>?
            var length = 0
            guard ghostty_formatter_format_alloc(formatter, nil, &bytes, &length) == GHOSTTY_SUCCESS,
                  let bytes else { return "" }
            defer { ghostty_free(nil, bytes, length) }
            return String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
        }
    }

    /// A shell on a machine loaded by parallel test runs can take seconds to start or go.
    private func waitUntil(
        timeout: TimeInterval = 30, file: StaticString = #filePath, line: UInt = #line, _ condition: @MainActor () -> Bool
    ) async throws {
        guard await pollUntil(timeout: timeout, condition) else {
            // Tells a shell that never started or printed from output that never reached the screen.
            let session = sessions.last.map { session in
                let status = session.status
                return "pid \(session.pid), \(status.state), exit \(status.exitCode.map(String.init) ?? "none"), "
                    + "\(session.outputBatches) batches, screen \(screen(session).suffix(300).debugDescription)"
            }
            return XCTFail("Condition not met within \(timeout)s; last session: \(session ?? "none")", file: file, line: line)
        }
    }
}
