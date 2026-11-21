import XCTest
@testable import Lilo

final class AgentClientConfigTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "agent-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: home)
    }

    private func write(_ text: String, to path: String) throws {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func json(_ path: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: home.appending(path: path))) as? [String: Any])
    }

    func testDesktopConfigMergeKeepsOtherServers() async throws {
        let path = "Library/Application Support/Claude/claude_desktop_config.json"
        try write(#"{"mcpServers": {"other": {"command": "/bin/other"}}, "theme": "dark"}"#, to: path)

        _ = try await AgentClientConfig.connect(.claudeDesktop, home: home)

        let config = try json(path)
        let servers = try XCTUnwrap(config["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(servers["other"]?["command"] as? String, "/bin/other")
        XCTAssertEqual(servers["lilo"]?["command"] as? String, AgentClientConfig.helperPath)
        XCTAssertEqual(config["theme"] as? String, "dark")
    }

    func testConnectedClientsAreTheConfigsNamingLilo() async throws {
        XCTAssertEqual(AgentClientConfig.connectedClients(home: home), [])

        try write(#"{"mcpServers": {"lilo": {"command": "/x/lilo-mcp"}}}"#, to: ".claude.json")
        try write(#"{"mcpServers": {"other": {"command": "/bin/other"}}}"#, to: ".cursor/mcp.json")
        _ = try await AgentClientConfig.connect(.codex, home: home)

        XCTAssertEqual(AgentClientConfig.connectedClients(home: home), [.claudeCode, .codex])
    }

    func testCommandLineClientIsInstalledOnceItsFolderExists() throws {
        try write("{}", to: ".claude/settings.json")

        XCTAssertNotNil(AgentClientConfig.iconApp(of: .claudeCode, home: home))
        XCTAssertEqual(AgentClientConfig.Client(clientName: "claude-ai"), .claudeDesktop)
        XCTAssertEqual(AgentClientConfig.Client(clientName: "local-agent-mode-lilo"), .claudeDesktop)
    }

    @MainActor
    func testHandshakeNamesReadAsPeopleKnowTheAgents() {
        XCTAssertEqual(AgentControl.displayName("local-agent-mode-lilo"), "Claude")
        XCTAssertEqual(AgentControl.displayName("claude-code"), "Claude Code")
        XCTAssertEqual(AgentControl.displayName("gemini-cli-mcp-client"), "Gemini CLI")
        XCTAssertEqual(AgentControl.displayName("my_agent"), "My Agent")
        XCTAssertEqual(AgentControl.displayName("Test Agent"), "Test Agent")
        XCTAssertEqual(AgentControl.displayName("goose"), "goose")
    }

    func testClaudeCodeIsFoundWhereItsInstallerPutsIt() async throws {
        // Claude Code's installer puts it in ~/.local/bin, which a login shell started outside a terminal
        // often has no PATH entry for.
        let log = home.appending(path: "claude-args.txt")
        try write("#!/bin/sh\necho \"$@\" >> '\(log.path)'\n", to: ".local/bin/claude")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appending(path: ".local/bin/claude").path)

        _ = try await AgentClientConfig.connect(.claudeCode, home: home)

        let calls = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(calls.contains("mcp add --scope user lilo -- \(AgentClientConfig.helperPath)"), calls)
    }

    func testUnreadableConfigIsLeftUntouched() async throws {
        let original = "// my servers\n{\"mcpServers\": {\"other\": {\"command\": \"/bin/other\"}},}"
        try write(original, to: ".cursor/mcp.json")

        do {
            _ = try await AgentClientConfig.connect(.cursor, home: home)
            XCTFail("an unreadable file is not rewritten")
        } catch {}

        XCTAssertEqual(try String(contentsOf: home.appending(path: ".cursor/mcp.json"), encoding: .utf8), original)
    }

    func testCodexConfigThatIsNotTextIsLeftUntouched() async throws {
        let original = Data([0x5B, 0xFF, 0xFE, 0x5D])
        try FileManager.default.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        try original.write(to: home.appending(path: ".codex/config.toml"))

        do {
            _ = try await AgentClientConfig.connect(.codex, home: home)
            XCTFail("a file that cannot be read is not rewritten")
        } catch {}

        XCTAssertEqual(try Data(contentsOf: home.appending(path: ".codex/config.toml")), original)
    }

    func testCursorConfigCreatedWhenMissing() async throws {
        _ = try await AgentClientConfig.connect(.cursor, home: home)

        let servers = try XCTUnwrap(try json(".cursor/mcp.json")["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(servers["lilo"]?["command"] as? String, AgentClientConfig.helperPath)
    }

    func testALinkedConfigStaysALinkWithItsPermissions() async throws {
        try write(#"{"mcpServers": {"other": {"command": "/bin/other", "env": {"KEY": "secret"}}}}"#, to: "dotfiles/mcp.json")
        let target = home.appending(path: "dotfiles/mcp.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createDirectory(at: home.appending(path: ".cursor"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appending(path: ".cursor/mcp.json"), withDestinationURL: target)

        _ = try await AgentClientConfig.connect(.cursor, home: home)

        let link = home.appending(path: ".cursor/mcp.json").path
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), target.path, "still the user's link")
        let servers = try XCTUnwrap(try json("dotfiles/mcp.json")["mcpServers"] as? [String: Any])
        XCTAssertEqual(Set(servers.keys), ["lilo", "other"])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int, 0o600)
    }

    func testCodexTableReplacedInPlace() async throws {
        try write("""
            # my settings
            model = "o3"

            [mcp_servers.lilo]
            command = "/old/lilo-mcp"

            [mcp_servers.other]
            command = "/bin/other"
            """, to: ".codex/config.toml")

        _ = try await AgentClientConfig.connect(.codex, home: home)

        let text = try String(contentsOf: home.appending(path: ".codex/config.toml"), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("# my settings\nmodel = \"o3\"\n\n[mcp_servers.lilo]\ncommand = \"\(AgentClientConfig.helperPath)\"\n"), text)
        XCTAssertTrue(text.contains("[mcp_servers.other]\ncommand = \"/bin/other\""), text)
        XCTAssertEqual(text.components(separatedBy: "[mcp_servers.lilo]").count, 2, "one lilo table")
        XCTAssertFalse(text.contains("/old/lilo-mcp"))
    }

    func testMovedConfigIsRepairedAndOthersLeftAlone() throws {
        try write(#"{"mcpServers": {"lilo": {"command": "/gone/Lilo.app/Contents/MacOS/lilo-mcp"}}}"#,
                  to: "Library/Application Support/Claude/claude_desktop_config.json")
        // Another existing binary is the user's own choice, not a moved Lilo.
        try write(#"{"mcpServers": {"lilo": {"command": "/bin/sh"}}}"#, to: ".cursor/mcp.json")

        let repaired = AgentClientConfig.repairMovedConfigs(home: home)

        XCTAssertEqual(repaired, [.claudeDesktop])
        let desktop = try json("Library/Application Support/Claude/claude_desktop_config.json")
        XCTAssertEqual(((desktop["mcpServers"] as? [String: Any])?["lilo"] as? [String: Any])?["command"] as? String, AgentClientConfig.helperPath)
        let cursor = try json(".cursor/mcp.json")
        XCTAssertEqual(((cursor["mcpServers"] as? [String: Any])?["lilo"] as? [String: Any])?["command"] as? String, "/bin/sh")
    }

    /// What each client's file holds right after Connect on an empty home: the refactor of the writers into
    /// a table must keep these bytes.
    func testGoldenOutputOfEveryClient() async throws {
        let helper = AgentClientConfig.helperPath
        // JSONSerialization escapes slashes.
        let escaped = helper.replacingOccurrences(of: "/", with: "\\/")
        let jsonEntry = "{\n  \"mcpServers\" : {\n    \"lilo\" : {\n      \"command\" : \"\(escaped)\"\n    }\n  }\n}"
        let files = [
            ("Library/Application Support/Claude/claude_desktop_config.json", jsonEntry, AgentClientConfig.Client.claudeDesktop),
            (".cursor/mcp.json", jsonEntry, .cursor),
            (".codex/config.toml", "[mcp_servers.lilo]\ncommand = \"\(helper)\"\n", .codex)
        ]
        for (path, golden, client) in files {
            let message = try await AgentClientConfig.connect(client, home: home)
            XCTAssertEqual(try String(contentsOf: home.appending(path: path), encoding: .utf8), golden, path)
            XCTAssertFalse(message.isEmpty)
        }
        XCTAssertEqual(AgentClientConfig.genericConfigJSON, jsonEntry)
    }

    func testGoldenCommandsOfClaudeCode() async throws {
        let log = home.appending(path: "claude-args.txt")
        try write("#!/bin/sh\necho \"$@\" >> '\(log.path)'\n", to: ".local/bin/claude")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appending(path: ".local/bin/claude").path)

        let message = try await AgentClientConfig.connect(.claudeCode, home: home)

        XCTAssertEqual(message, "Added Lilo to Claude Code".localized)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8),
                       "mcp remove --scope user lilo\nmcp add --scope user lilo -- \(AgentClientConfig.helperPath)\n")
    }

    func testRemoveTakesOnlyLiloOutOfAFileClient() async throws {
        try write(#"{"mcpServers": {"other": {"command": "/bin/other"}}, "theme": "dark"}"#, to: ".cursor/mcp.json")
        try write("# my settings\nmodel = \"o3\"\n\n[mcp_servers.other]\ncommand = \"/bin/other\"\n", to: ".codex/config.toml")
        _ = try await AgentClientConfig.connect(.cursor, home: home)
        _ = try await AgentClientConfig.connect(.codex, home: home)
        XCTAssertEqual(AgentClientConfig.connectedClients(home: home), [.codex, .cursor])

        try await AgentClientConfig.remove(.cursor, home: home)
        try await AgentClientConfig.remove(.codex, home: home)

        XCTAssertEqual(AgentClientConfig.connectedClients(home: home), [])
        let cursor = try json(".cursor/mcp.json")
        XCTAssertEqual(Set((cursor["mcpServers"] as? [String: Any] ?? [:]).keys), ["other"])
        XCTAssertEqual(cursor["theme"] as? String, "dark")
        let codex = try String(contentsOf: home.appending(path: ".codex/config.toml"), encoding: .utf8)
        XCTAssertEqual(codex, "# my settings\nmodel = \"o3\"\n\n[mcp_servers.other]\ncommand = \"/bin/other\"\n\n")
    }

    func testRemoveWithoutAConfigDoesNothing() async throws {
        for client in AgentClientConfig.Client.all { try await AgentClientConfig.remove(client, home: home) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appending(path: ".cursor").path))
    }

    func testMovedCodexConfigIsRepaired() throws {
        try write("[mcp_servers.lilo]\ncommand = \"/gone/Lilo.app/Contents/MacOS/lilo-mcp\"\n", to: ".codex/config.toml")

        XCTAssertEqual(AgentClientConfig.repairMovedConfigs(home: home), [.codex])

        XCTAssertEqual(try String(contentsOf: home.appending(path: ".codex/config.toml"), encoding: .utf8),
                       "[mcp_servers.lilo]\ncommand = \"\(AgentClientConfig.helperPath)\"\n")
    }

    /// The preview is made by the code that writes: what it says the file becomes is the file, byte for byte,
    /// for every client of the table that Lilo writes itself.
    func testPreviewIsWhatConnectWritesForEveryClient() async throws {
        let seeds: [(AgentClientConfig.Client, String)] = [
            (.claudeDesktop, #"{"mcpServers": {"other": {"command": "/bin/other"}}, "theme": "dark"}"#),
            (.cursor, ""),
            (.codex, "# my settings\nmodel = \"o3\"\n\n[mcp_servers.other]\ncommand = \"/bin/other\"\n")
        ]
        for (client, seed) in seeds {
            if !seed.isEmpty { try write(seed, to: client.config.path) }
            let preview = AgentClientConfig.preview(client, home: home)
            XCTAssertNil(preview.blocked, client.id)
            XCTAssertEqual(preview.path, "~/" + client.config.path)
            XCTAssertFalse(preview.lines.isEmpty, client.id)

            _ = try await AgentClientConfig.connect(client, home: home)

            XCTAssertEqual(try String(contentsOf: home.appending(path: client.config.path), encoding: .utf8), preview.after, client.id)
            XCTAssertTrue(AgentClientConfig.preview(client, home: home).lines.isEmpty, "connected again: nothing left to change")
        }
    }

    func testPreviewOfAnEmptyHomeIsTheWholeEntry() {
        let preview = AgentClientConfig.preview(.codex, home: home)
        XCTAssertEqual(preview.lines.map(\.text), ["[mcp_servers.lilo]", "command = \"\(AgentClientConfig.helperPath)\"", ""])
        XCTAssertEqual(preview.lines.map(\.number), [1, 2, 3])
        XCTAssertTrue(preview.lines.allSatisfy { !$0.removed })
        XCTAssertEqual(preview.snippet, "[mcp_servers.lilo]\ncommand = \"\(AgentClientConfig.helperPath)\"\n")
    }

    func testPreviewShowsOnlyTheChangedLines() throws {
        // As the writer lays a file out, so only the new entry differs.
        try write("{\n  \"mcpServers\" : {\n    \"other\" : {\n      \"command\" : \"/bin/other\",\n      \"env\" : {\n        \"KEY\" : \"secret\"\n      }\n    }\n  }\n}", to: ".cursor/mcp.json")

        let preview = AgentClientConfig.preview(.cursor, home: home)

        XCTAssertFalse(preview.lines.contains { $0.text.contains("secret") }, "a neighbouring server's values stay off the page")
        XCTAssertTrue(preview.lines.contains { !$0.removed && $0.text.contains("\"lilo\"") })
        XCTAssertTrue(preview.lines.contains { !$0.removed && $0.text.contains(AgentClientConfig.helperPath.replacingOccurrences(of: "/", with: "\\/")) })
    }

    func testPreviewOfARepairShowsTheOldPathReplaced() throws {
        try write("[mcp_servers.lilo]\ncommand = \"/gone/lilo-mcp\"\n", to: ".codex/config.toml")

        let preview = AgentClientConfig.preview(.codex, home: home)

        XCTAssertEqual(preview.lines.map(\.removed), [true, false])
        XCTAssertEqual(preview.lines.map(\.text), ["command = \"/gone/lilo-mcp\"", "command = \"\(AgentClientConfig.helperPath)\""])
        XCTAssertEqual(AgentClientConfig.staleClients(home: home), [.codex])
    }

    func testPreviewOfARemoveIsWhatRemoveWrites() async throws {
        try write(#"{"mcpServers": {"other": {"command": "/bin/other"}}}"#, to: ".cursor/mcp.json")
        try write("# mine\n\n[mcp_servers.other]\ncommand = \"/bin/other\"\n", to: ".codex/config.toml")
        _ = try await AgentClientConfig.connect(.cursor, home: home)
        _ = try await AgentClientConfig.connect(.codex, home: home)

        for client in [AgentClientConfig.Client.cursor, .codex] {
            let preview = AgentClientConfig.preview(client, home: home, remove: true)
            XCTAssertFalse(preview.lines.isEmpty, client.id)
            XCTAssertTrue(preview.lines.allSatisfy(\.removed), "a removal only takes lines away: \(client.id)")

            try await AgentClientConfig.remove(client, home: home)

            XCTAssertEqual(try String(contentsOf: home.appending(path: client.config.path), encoding: .utf8), preview.after, client.id)
        }
        XCTAssertTrue(AgentClientConfig.preview(.cursor, home: home, remove: true).lines.isEmpty, "nothing left to remove")
    }

    func testPreviewOfAnUnreadableFileSaysWhyAndWritesNothing() throws {
        try write("// mine\n{\"mcpServers\": {},}", to: ".cursor/mcp.json")

        let preview = AgentClientConfig.preview(.cursor, home: home)

        XCTAssertNotNil(preview.blocked)
        XCTAssertTrue(preview.lines.isEmpty)
        XCTAssertEqual(preview.snippet, AgentClientConfig.genericConfigJSON)
        XCTAssertNil(AgentClientConfig.preview(.cursor, home: home, remove: true).blocked, "leaving a file it cannot read is not an error")
    }

    func testPreviewOfClaudeCodeIsTheCommandItRuns() {
        let add = AgentClientConfig.preview(.claudeCode, home: home)
        XCTAssertEqual(add.command, "claude mcp add --scope user lilo -- \(AgentClientConfig.helperPath)")
        XCTAssertTrue(add.lines.isEmpty)
        XCTAssertEqual(AgentClientConfig.preview(.claudeCode, home: home, remove: true).command, "claude mcp remove --scope user lilo")
    }

    func testRemoveRunsClaudeCodesOwnCommand() async throws {
        let log = home.appending(path: "claude-args.txt")
        try write("#!/bin/sh\necho \"$@\" >> '\(log.path)'\n", to: ".local/bin/claude")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appending(path: ".local/bin/claude").path)

        try await AgentClientConfig.remove(.claudeCode, home: home)

        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "mcp remove --scope user lilo\n")
    }

    func testLineDiffKeepsMatchingLinesAndOrdersChanges() {
        let lines = AgentClientConfig.diff("a\nb\nc\nd", "a\nB\nc\nd\ne")
        XCTAssertEqual(lines.map { "\($0.removed ? "-" : "+")\($0.number) \($0.text)" }, ["-2 b", "+2 B", "+5 e"])
    }
}
