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

    /// What each client's file holds right after Connect on an empty home.
    func testGoldenOutputOfEveryClient() async throws {
        let helper = AgentClientConfig.helperPath
        let jsonEntry = "{\n  \"mcpServers\": {\n    \"lilo\": {\n      \"command\": \"\(helper)\"\n    }\n  }\n}"
        let files = [
            ("Library/Application Support/Claude/claude_desktop_config.json", jsonEntry + "\n", AgentClientConfig.Client.claudeDesktop),
            (".cursor/mcp.json", jsonEntry + "\n", .cursor),
            (".codex/config.toml", "[mcp_servers.lilo]\ncommand = \"\(helper)\"\n", .codex)
        ]
        for (path, golden, client) in files + discoveredGoldens(helper: helper) {
            let message = try await AgentClientConfig.connect(client, home: home)
            XCTAssertEqual(try String(contentsOf: home.appending(path: path), encoding: .utf8), golden, path)
            XCTAssertFalse(message.isEmpty)
        }
        XCTAssertEqual(AgentClientConfig.genericConfigJSON, jsonEntry)
    }

    /// Each app's own wording of the entry, as its first-party page shows it (see `HarnessDefinition`).
    private func discoveredGoldens(helper: String) -> [(String, String, AgentClientConfig.Client)] {
        let file = { (key: String, fields: String) in "{\n  \"\(key)\": {\n    \"lilo\": {\n\(fields)\n    }\n  }\n}\n" }
        return [
            (".config/zed/settings.json", file("context_servers", "      \"command\": \"\(helper)\""), .zed),
            (".copilot/mcp-config.json",
             file("mcpServers", "      \"type\": \"stdio\",\n      \"command\": \"\(helper)\",\n      \"tools\": [\"*\"]"), .vscode),
            (".config/opencode/opencode.json", file("mcp", "      \"type\": \"local\",\n      \"command\": [\"\(helper)\"]"), .opencode),
            (".gemini/settings.json", file("mcpServers", "      \"command\": \"\(helper)\""), .gemini)
        ]
    }

    func testDiscoveredClientsKeepTheirOtherSettingsAndShowTheSameFileTheyWrite() async throws {
        let seeds: [(AgentClientConfig.Client, String, String)] = [
            (.zed, #"{"theme": "One Dark", "context_servers": {"other": {"command": "/bin/other"}}}"#, "context_servers"),
            (.vscode, #"{"mcpServers": {"other": {"type": "stdio", "command": "/bin/other"}}}"#, "mcpServers"),
            (.opencode, #"{"model": "example/model", "mcp": {"other": {"type": "local", "command": ["/bin/other"]}}}"#, "mcp"),
            (.gemini, #"{"theme": "Default", "mcpServers": {"other": {"command": "/bin/other"}}}"#, "mcpServers")
        ]
        for (client, seed, key) in seeds {
            try write(seed, to: client.config.path)
            let preview = AgentClientConfig.preview(client, home: home)
            XCTAssertNil(preview.blocked, client.id)
            XCTAssertFalse(preview.lines.isEmpty, client.id)

            _ = try await AgentClientConfig.connect(client, home: home)

            XCTAssertEqual(try String(contentsOf: home.appending(path: client.config.path), encoding: .utf8), preview.after, client.id)
            let written = try json(client.config.path)
            let servers = try XCTUnwrap(written[key] as? [String: Any], client.id)
            XCTAssertEqual(Set(servers.keys), ["lilo", "other"], client.id)
            XCTAssertEqual(written.count, (try XCTUnwrap(JSONSerialization.jsonObject(with: Data(seed.utf8)) as? [String: Any])).count, "\(client.id) keeps its other keys")
            XCTAssertEqual(AgentClientConfig.connectedClients(home: home), [client])

            try await AgentClientConfig.remove(client, home: home)
            let left = try XCTUnwrap(try json(client.config.path)[key] as? [String: Any])
            XCTAssertEqual(Set(left.keys), ["other"], client.id)
            try FileManager.default.removeItem(at: home.appending(path: client.config.path))
        }
    }

    /// Zed's and OpenCode's settings take comments: Lilo does not rewrite a file it cannot parse, and says what to paste.
    func testASettingsFileWithCommentsIsNeverRewritten() async throws {
        let original = "// my editor\n{\n  \"theme\": \"One Dark\", // trailing comma next\n}"
        for client in [AgentClientConfig.Client.zed, .opencode] {
            try write(original, to: client.config.path)

            let preview = AgentClientConfig.preview(client, home: home)
            XCTAssertNotNil(preview.blocked, client.id)
            XCTAssertTrue(preview.lines.isEmpty, client.id)
            XCTAssertTrue(preview.snippet.contains(AgentClientConfig.helperPath), client.id)
            do {
                _ = try await AgentClientConfig.connect(client, home: home)
                XCTFail("\(client.id): a file with comments is not rewritten")
            } catch {}
            XCTAssertEqual(try String(contentsOf: home.appending(path: client.config.path), encoding: .utf8), original, client.id)
        }
        XCTAssertTrue(AgentClientConfig.preview(.zed, home: home).snippet.contains("\"context_servers\""))
    }

    func testAMovedOpenCodeEntryIsRepairedInItsOwnShape() throws {
        try write(#"{"mcp": {"lilo": {"type": "local", "command": ["/gone/Lilo.app/Contents/MacOS/lilo-mcp"]}}}"#, to: ".config/opencode/opencode.json")

        XCTAssertEqual(AgentClientConfig.staleClients(home: home), [.opencode])
        XCTAssertEqual(AgentClientConfig.repairMovedConfigs(home: home), [.opencode])

        let server = try XCTUnwrap(((try json(".config/opencode/opencode.json"))["mcp"] as? [String: [String: Any]])?["lilo"])
        XCTAssertEqual(server["command"] as? [String], [AgentClientConfig.helperPath])
        XCTAssertEqual(AgentClientConfig.staleClients(home: home), [])
    }

    /// The scan reads the home only: a folder or a tool an app leaves there is what says it is installed.
    func testAnAppIsDetectedByWhatItLeavesInTheHome() throws {
        let fingerprints: [(AgentClientConfig.Client, String)] = [
            (.zed, ".config/zed/settings.json"), (.vscode, ".vscode/extensions/extensions.json"),
            (.opencode, ".config/opencode/opencode.json"), (.gemini, ".gemini/settings.json")
        ]
        for (client, path) in fingerprints {
            try write("{}", to: path)
            XCTAssertNotNil(AgentClientConfig.iconApp(of: client, home: home), client.id)
        }
        let tool = home.appending(path: ".opencode/bin/opencode")
        try FileManager.default.removeItem(at: home.appending(path: ".config/opencode"))
        try write("#!/bin/sh\n", to: ".opencode/bin/opencode")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        XCTAssertNotNil(AgentClientConfig.iconApp(of: .opencode, home: home), "where OpenCode's installer puts it")
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
        XCTAssertEqual(codex, "# my settings\nmodel = \"o3\"\n\n[mcp_servers.other]\ncommand = \"/bin/other\"\n")
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
        try write("{\n  \"mcpServers\": {\n    \"other\": {\n      \"command\": \"/bin/other\",\n      \"env\": {\n        \"KEY\": \"secret\"\n      }\n    }\n  }\n}\n", to: ".cursor/mcp.json")

        let preview = AgentClientConfig.preview(.cursor, home: home)

        XCTAssertEqual(preview.lines.map { "\($0.removed ? "-" : "+")\($0.number) \($0.text)" }, [
            "+8     },", "+9     \"lilo\": {", "+10       \"command\": \"\(AgentClientConfig.helperPath)\""
        ], "the old closing brace now closes Lilo's entry")
    }

    func testPreviewOfARepairShowsTheOldPathReplaced() throws {
        try write("[mcp_servers.lilo]\ncommand = \"/gone/lilo-mcp\"\n", to: ".codex/config.toml")

        let preview = AgentClientConfig.preview(.codex, home: home)

        XCTAssertEqual(preview.lines.map(\.removed), [true, false])
        XCTAssertEqual(preview.lines.map(\.text), ["command = \"/gone/lilo-mcp\"", "command = \"\(AgentClientConfig.helperPath)\""])
        XCTAssertEqual(AgentClientConfig.staleClients(home: home), [.codex])
    }

    func testPreviewOfARemoveIsWhatRemoveWrites() async throws {
        try write("{\n  \"mcpServers\": {\n    \"other\": {\"command\": \"/bin/other\"}\n  }\n}\n", to: ".cursor/mcp.json")
        try write("# mine\n\n[mcp_servers.other]\ncommand = \"/bin/other\"\n", to: ".codex/config.toml")
        _ = try await AgentClientConfig.connect(.cursor, home: home)
        _ = try await AgentClientConfig.connect(.codex, home: home)

        for client in [AgentClientConfig.Client.cursor, .codex] {
            let preview = AgentClientConfig.preview(client, home: home, remove: true)
            XCTAssertFalse(preview.lines.isEmpty, client.id)
            XCTAssertLessThanOrEqual(preview.lines.filter { !$0.removed }.count, 1, "a removal only takes lines away, and a neighbour's comma: \(client.id)")

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

    /// Made-up files as people keep them: Connect changes only Lilo's lines, and Remove gives back every byte.
    func testConnectThenRemoveGivesBackTheFileByteForByte() async throws {
        let helper = AgentClientConfig.helperPath
        let json = [
            // Key order, spacing and escapes the writer would not choose, another server's env, nested objects.
            "{\n  \"theme\": \"dark\",\n  \"mcpServers\": {\n    \"files\": {\n      \"command\": \"npx\",\n      \"args\": [\"-y\", \"files-mcp\", \"~\\/notes\"],\n      \"env\": {\"TOKEN\": \"example-token\", \"N\": 1.50}\n    }\n  },\n  \"window\": {\"size\": [800, 600], \"nested\": {\"a\": {\"b\": null}}}\n}\n",
            // CRLF, tabs, no final newline.
            "{\r\n\t\"mcpServers\": {\r\n\t\t\"other\": {\"command\": \"/bin/other\"}\r\n\t}\r\n}",
            // Everything on one line.
            #"{"mcpServers":{"a":{"command":"/bin/a"},"b":{"command":"/bin/b"}}}"#,
            // Servers still empty, as an app leaves the file.
            "{\n  \"mcpServers\": {}\n}\n"
        ]
        let toml = [
            "# settings\nmodel = \"o3\"\n\n[mcp_servers.other]\ncommand = \"/bin/other\"\nenv = { KEY = \"example\" }\n",
            "model = \"o3\"\r\n\r\n[mcp_servers.other]\r\ncommand = \"/bin/other\"",
            "model = \"o3\"\n\n\n",
            ""
        ]
        for (client, seeds) in [(AgentClientConfig.Client.cursor, json), (.codex, toml)] {
            for seed in seeds {
                try write(seed, to: client.config.path)
                let url = home.appending(path: client.config.path)

                _ = try await AgentClientConfig.connect(client, home: home)
                let connected = try String(contentsOf: url, encoding: .utf8)
                XCTAssertTrue(connected.contains("\"\(helper)\""), connected)
                XCTAssertEqual(AgentClientConfig.connectedClients(home: home).contains(client), true, seed)
                XCTAssertEqual(AgentClientConfig.diff(seed, connected).filter(\.removed).count <= 1, true, "only a comma at most: \(seed)")

                try await AgentClientConfig.remove(client, home: home)
                XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), seed, "byte for byte: \(client.id)")
            }
        }
    }

    func testConnectMatchesTheFilesLayout() async throws {
        let helper = AgentClientConfig.helperPath
        try write("{\r\n\t\"mcpServers\": {\r\n\t\t\"other\": {\"command\": \"/bin/other\"}\r\n\t}\r\n}", to: ".cursor/mcp.json")
        try write(#"{"mcpServers":{"a":{"command":"/bin/a"}}}"#, to: "Library/Application Support/Claude/claude_desktop_config.json")

        _ = try await AgentClientConfig.connect(.cursor, home: home)
        _ = try await AgentClientConfig.connect(.claudeDesktop, home: home)

        XCTAssertEqual(try String(contentsOf: home.appending(path: ".cursor/mcp.json"), encoding: .utf8),
                       "{\r\n\t\"mcpServers\": {\r\n\t\t\"other\": {\"command\": \"/bin/other\"},\r\n\t\t\"lilo\": {\r\n\t\t\t\"command\": \"\(helper)\"\r\n\t\t}\r\n\t}\r\n}")
        XCTAssertEqual(try String(contentsOf: home.appending(path: "Library/Application Support/Claude/claude_desktop_config.json"), encoding: .utf8),
                       #"{"mcpServers":{"a":{"command":"/bin/a"}, "lilo":{"command":"\#(helper)"}}}"#)
    }

    func testFilesWithoutServersGetThemAndKeepTheRest() async throws {
        let helper = AgentClientConfig.helperPath
        try write("{\n  \"theme\": \"dark\"\n}\n", to: ".cursor/mcp.json")
        try write("", to: "Library/Application Support/Claude/claude_desktop_config.json")

        _ = try await AgentClientConfig.connect(.cursor, home: home)
        _ = try await AgentClientConfig.connect(.claudeDesktop, home: home)
        _ = try await AgentClientConfig.connect(.codex, home: home)

        XCTAssertEqual(try String(contentsOf: home.appending(path: ".cursor/mcp.json"), encoding: .utf8),
                       "{\n  \"theme\": \"dark\",\n  \"mcpServers\": {\n    \"lilo\": {\n      \"command\": \"\(helper)\"\n    }\n  }\n}\n")
        XCTAssertEqual(try String(contentsOf: home.appending(path: "Library/Application Support/Claude/claude_desktop_config.json"), encoding: .utf8),
                       AgentClientConfig.genericConfigJSON + "\n")

        // Removing leaves the servers object empty rather than guessing whether the user wrote it.
        try await AgentClientConfig.remove(.cursor, home: home)
        try await AgentClientConfig.remove(.codex, home: home)
        XCTAssertEqual(try String(contentsOf: home.appending(path: ".cursor/mcp.json"), encoding: .utf8),
                       "{\n  \"theme\": \"dark\",\n  \"mcpServers\": {}\n}\n")
        XCTAssertEqual(try String(contentsOf: home.appending(path: ".codex/config.toml"), encoding: .utf8), "")
    }

    func testAServersValueThatIsNoObjectBlocksTheWrite() {
        let original = #"{"mcpServers": ["not", "an", "object"]}"#
        XCTAssertNoThrow(try write(original, to: ".cursor/mcp.json"))

        XCTAssertNotNil(AgentClientConfig.preview(.cursor, home: home).blocked)
        XCTAssertEqual(try String(contentsOf: home.appending(path: ".cursor/mcp.json"), encoding: .utf8), original)
    }

    func testLiloFirstAmongServersIsRemovedWithItsComma() async throws {
        let rest = "    \"other\": {\"command\": \"/bin/other\"}\n  }\n}\n"
        try write("{\n  \"mcpServers\": {\n    \"lilo\": {\"command\": \"/x/lilo-mcp\"},\n" + rest, to: ".cursor/mcp.json")

        try await AgentClientConfig.remove(.cursor, home: home)

        XCTAssertEqual(try String(contentsOf: home.appending(path: ".cursor/mcp.json"), encoding: .utf8), "{\n  \"mcpServers\": {\n" + rest)
    }

    func testCodexSubTablesGoWithLilosTable() async throws {
        try write("[mcp_servers.lilo]\ncommand = \"/x/lilo-mcp\"\n\n[mcp_servers.lilo.env]\nKEY = \"example\"\n\n[mcp_servers.other]\ncommand = \"/bin/other\"\n", to: ".codex/config.toml")

        try await AgentClientConfig.remove(.codex, home: home)

        XCTAssertEqual(try String(contentsOf: home.appending(path: ".codex/config.toml"), encoding: .utf8), "\n[mcp_servers.other]\ncommand = \"/bin/other\"\n")
    }
}
