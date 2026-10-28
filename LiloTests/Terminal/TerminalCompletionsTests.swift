import XCTest
@testable import Lilo

final class TerminalCompletionsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-completions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("bin"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testZshExtendedHistoryIsDecoded() {
        // "café" with its é (0xC3 0xA9) as zsh writes it: 0xA9 is metafied to 0x83 0x89.
        var data = Data(": 1700000000:0;echo caf".utf8) + Data([0xC3, 0x83, 0x89]) + Data("\n".utf8)
        data += Data(": 1700000001:0;for f in *; do \\\n  echo $f\\\ndone\n: 1700000002:0;ls -la\n".utf8)

        XCTAssertEqual(TerminalCompletions.parseHistory(data, zsh: true), ["echo café", "ls -la"])
    }

    func testBashHistorySkipsTimestamps() {
        let data = Data("#1700000000\ngit status\n\nmake\n".utf8)

        XCTAssertEqual(TerminalCompletions.parseHistory(data, zsh: false), ["git status", "make"])
    }

    func testFishHistoryOffersCommandsWithoutMetadataOrMultilineEntries() async throws {
        let history = directory.appendingPathComponent("fish_history")
        try #"""
            - cmd: echo café
              when: 1700000000
              paths:
                - /example/project
            - cmd: printf '\\n'
              when: 1700000001
            - cmd: echo first\necho second
              when: 1700000002
            - cmd: git status
              when: 1700000003
            """#.write(to: history, atomically: true, encoding: .utf8)
        let completions = TerminalCompletions(historyFiles: [history], pathDirectories: [])

        let recent = await completions.complete("")

        XCTAssertEqual(recent, [
            .init(command: "git status", source: .history),
            .init(command: #"printf '\n'"#, source: .history),
            .init(command: "echo café", source: .history),
        ])
    }

    func testHistoryComesFirstMostRecentFirstThenPrograms() async throws {
        let history = directory.appendingPathComponent(".zsh_history")
        try ": 1:0;echo old\n: 2:0;git status\n: 3:0;echo new\n: 4:0;echo old\n".write(to: history, atomically: true, encoding: .utf8)
        let bin = directory.appendingPathComponent("bin")
        for name in ["echo", "ech-tool", "notes.txt"] {
            FileManager.default.createFile(atPath: bin.appendingPathComponent(name).path, contents: Data())
        }
        for name in ["echo", "ech-tool"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent(name).path)
        }
        let completions = TerminalCompletions(historyFiles: [history], pathDirectories: [bin.path])

        let results = await completions.complete("ech")
        XCTAssertEqual(results, [
            .init(command: "echo old", source: .history),
            .init(command: "echo new", source: .history),
            .init(command: "ech-tool", source: .command),
            .init(command: "echo", source: .command),
        ])
        let recent = await completions.complete("")
        XCTAssertEqual(recent.map(\.command), ["echo old", "echo new", "git status"])
        let arguments = await completions.complete("echo ")
        XCTAssertEqual(arguments.map(\.source), [.history, .history], "programs only complete the first word")
    }
}
