import XCTest
@testable import Lilo

final class VTTerminalTests: XCTestCase {
    func testABellRingsButTheOSCTerminatorDoesNot() {
        let terminal = VTTerminal(cols: 20, rows: 4, scrollbackBytes: 0)
        var bells = 0
        terminal.onBell = { bells += 1 }
        feed(terminal, "\u{1b}]2;title\u{7}")
        XCTAssertEqual(bells, 0, "BEL ending an OSC sequence is not a bell")
        feed(terminal, "done\u{7}")
        XCTAssertEqual(bells, 1)
    }

    func testDesktopNotificationCarriesTitleAndBody() {
        let terminal = VTTerminal(cols: 20, rows: 4, scrollbackBytes: 0)
        var received: [String] = []
        terminal.onDesktopNotification = { title, body in received.append("\(title)|\(body)") }
        feed(terminal, "\u{1b}]777;notify;Claude;Waiting for input\u{7}")
        XCTAssertEqual(received, ["Claude|Waiting for input"])
    }

    func testTitleAndWorkingDirectoryComeFromOSCSequences() {
        let terminal = VTTerminal(cols: 80, rows: 24, scrollbackBytes: 1_000_000)
        var titleChanges = 0
        var pwdChanges = 0
        terminal.onTitleChanged = { titleChanges += 1 }
        terminal.onPwdChanged = { pwdChanges += 1 }

        feed(terminal, "\u{1b}]2;build\u{7}\u{1b}]7;file://host/tmp/lilo%20dir\u{7}")

        XCTAssertEqual(terminal.title, "build")
        XCTAssertEqual(terminal.pwd, "file://host/tmp/lilo%20dir")
        XCTAssertEqual(titleChanges, 1)
        XCTAssertEqual(pwdChanges, 1)
    }

    func testDeviceStatusQueryIsAnsweredThroughWritePty() {
        let terminal = VTTerminal(cols: 80, rows: 24, scrollbackBytes: 1_000_000)
        var reply: [UInt8] = []
        terminal.onWritePty = { reply += $0 }

        feed(terminal, "\u{1b}[5n")

        XCTAssertEqual(String(decoding: reply, as: UTF8.self), "\u{1b}[0n")
    }

    func testSemanticPromptsReportCommandOutputAndExitCode() {
        let terminal = VTTerminal(cols: 80, rows: 24, scrollbackBytes: 1_000_000)
        var events: [VTTerminal.PromptEvent] = []
        terminal.onPrompt = { events.append($0) }

        feed(terminal, "\u{1b}]133;A\u{7}\u{1b}]133;C\u{7}output\r\n\u{1b}]133;D;3\u{7}")

        XCTAssertEqual(events, [.promptStart, .outputStart(command: nil), .commandEnd(exitCode: 3)])
    }

    func testCommandLineArrivesWithTheOutputStart() {
        let terminal = VTTerminal(cols: 80, rows: 24, scrollbackBytes: 1_000_000)
        var events: [VTTerminal.PromptEvent] = []
        terminal.onPrompt = { events.append($0) }

        feed(terminal, "\u{1b}]133;C;cmdline_url=npm%20run%20d%C3%A9v\u{7}")

        XCTAssertEqual(events, [.outputStart(command: "npm run dév")])
    }

    func testRunningCommandHasNoMarkUntilItFinishes() {
        let terminal = VTTerminal(cols: 20, rows: 10, scrollbackBytes: 1_000_000)
        feed(terminal, "\u{1b}]133;A\u{7}$ ssh host\r\n\u{1b}]133;C\u{7}Last login\r\nhost % ")
        XCTAssertEqual(terminal.visibleCommandMarks(), [])

        feed(terminal, "\u{1b}]133;D;255\u{7}\u{1b}]133;A\u{7}$ ")
        XCTAssertEqual(terminal.visibleCommandMarks(), [TerminalCommandMark(rows: 0...2, exitCode: 255)])
    }

    func testCommandsGetMarksAndTheirOutputCanBeSelected() {
        let terminal = VTTerminal(cols: 20, rows: 10, scrollbackBytes: 1_000_000)
        feed(terminal, "\u{1b}]133;A\u{7}$ ls\r\n\u{1b}]133;C\u{7}out1\r\nout2\r\n\u{1b}]133;D;0\u{7}")
        feed(terminal, "\u{1b}]133;A\u{7}$ false\r\n\u{1b}]133;C\u{7}\u{1b}]133;D;1\u{7}\u{1b}]133;A\u{7}$ ")

        XCTAssertEqual(terminal.visibleCommandMarks(), [
            TerminalCommandMark(rows: 3...3, exitCode: 1),
            TerminalCommandMark(rows: 0...2, exitCode: 0)
        ], "newest first; the prompt still waiting for a command has no mark")
        XCTAssertTrue(terminal.selectCommandOutput(atViewportRow: 1))
        XCTAssertEqual(terminal.selectionText, "out1\nout2")
        XCTAssertFalse(terminal.selectCommandOutput(atViewportRow: 3), "a command that printed nothing has no output to select")
    }

    func testSnapshotRestoresScreenAndHistory() throws {
        let terminal = VTTerminal(cols: 20, rows: 3, scrollbackBytes: 1_000_000)
        feed(terminal, "first\r\nsecond\r\nthird\r\nfourth\r\n\u{1b}[31mred")

        let restored = try XCTUnwrap(VTTerminal(snapshot: try XCTUnwrap(terminal.snapshot()), scrollbackBytes: 1_000_000))

        XCTAssertEqual(restored.line(row: 2)?.text, "red")
        XCTAssertFalse(restored.scrollEdges.atTop, "history came back too")
        XCTAssertNil(VTTerminal(snapshot: Data("not a snapshot".utf8), scrollbackBytes: 1_000_000))
    }

    func testSnapshotTakenMidSequenceStillSaves() throws {
        let terminal = VTTerminal(cols: 20, rows: 3, scrollbackBytes: 1_000_000)
        feed(terminal, "before\u{1b}[3")

        let restored = try XCTUnwrap(VTTerminal(snapshot: try XCTUnwrap(terminal.snapshot()), scrollbackBytes: 1_000_000))
        feed(restored, "1mafter")

        XCTAssertEqual(restored.line(row: 0)?.text, "beforeafter", "the sequence cut at quit finishes after the restart")
    }

    private func feed(_ terminal: VTTerminal, _ text: String) {
        Array(text.utf8).withUnsafeBytes { terminal.write($0) }
    }
}
