import XCTest
@testable import Lilo

final class ACPAgentCatalogTests: XCTestCase {
    func testParseTakesThisMacsBinaryElseNpxElseUvx() throws {
        let registry = """
        {"version": "1.0.0", "agents": [
          {"id": "claude-acp", "name": "Claude Agent", "version": "1.0.0",
           "distribution": {"npx": {"package": "@agentclientprotocol/claude-agent-acp@1.0.0"}}},
          {"id": "gemini", "name": "Gemini CLI", "distribution": {"npx": {"package": "@google/gemini-cli", "args": ["--acp"]}}},
          {"id": "goose", "name": "goose", "version": "1.2", "distribution": {
            "binary": {
              "darwin-aarch64": {"archive": "https://example.com/goose-arm.tar.bz2", "cmd": "./goose", "args": ["acp"], "sha256": "AB12"},
              "darwin-x86_64": {"archive": "https://example.com/goose-x64.tar.bz2", "cmd": "./goose", "args": ["acp"], "sha256": "CD34"}
            },
            "npx": {"package": "goose"}}},
          {"id": "linux-only", "name": "Linux", "distribution": {"binary": {"linux-x86_64": {"archive": "https://example.com/a", "cmd": "a", "sha256": "00"}}}},
          {"id": "plain-http", "name": "HTTP", "distribution": {"binary": {"darwin-aarch64": {"archive": "http://example.com/a", "cmd": "a", "sha256": "00"},
            "darwin-x86_64": {"archive": "http://example.com/a", "cmd": "a", "sha256": "00"}}}},
          {"id": "fast", "name": "fast-agent", "distribution": {"uvx": {"package": "fast-agent-acp"}}}
        ]}
        """
        let agents = try XCTUnwrap(ACPAgentCatalog.parse(Data(registry.utf8)))
        let byId = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })

        XCTAssertEqual(byId["claude-acp"]?.distribution, .npx(package: "@agentclientprotocol/claude-agent-acp@1.0.0", args: []))
        XCTAssertEqual(byId["gemini"]?.distribution, .npx(package: "@google/gemini-cli", args: ["--acp"]))
        guard case .binary(let archive, let cmd, let args, let sha256)? = byId["goose"]?.distribution else { return XCTFail("goose is a binary") }
        XCTAssertTrue(archive.absoluteString.hasPrefix("https://example.com/goose-"))
        XCTAssertEqual(cmd, "./goose")
        XCTAssertEqual(args, ["acp"])
        XCTAssertTrue(["ab12", "cd34"].contains(sha256))
        XCTAssertNil(byId["linux-only"])
        // An archive fetched over plain HTTP is never installed.
        XCTAssertNil(byId["plain-http"])
        XCTAssertEqual(byId["fast"]?.distribution, .uvx(package: "fast-agent-acp", args: []))
    }

    func testANonRegistryAnswerParsesToNothing() {
        XCTAssertNil(ACPAgentCatalog.parse(Data("<html>".utf8)))
        XCTAssertNil(ACPAgentCatalog.parse(Data("{\"agents\": 3}".utf8)))
    }

    @MainActor
    func testAPinnedNpmAgentStartsItsInstalledCommand() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let modules = directory.appending(path: "npm/claude-acp/1.0.0/node_modules")
        let package = modules.appending(path: "@example/agent-acp")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(#"{"name": "@example/agent-acp", "bin": {"agent-acp": "dist/index.js"}}"#.utf8).write(to: package.appending(path: "package.json"))
        let command = modules.appending(path: ".bin/agent-acp")
        try FileManager.default.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: command.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        let agent = ACPAgentCatalog.Agent(id: "claude-acp", name: "Claude Agent", description: "", version: "1.0.0",
                                          distribution: .npx(package: "@example/agent-acp@1.0.0", args: ["--acp"]))

        let launch = try await ACPAgentCatalog(directory: directory).launch(agent)

        XCTAssertEqual(launch.executable.standardizedFileURL, command.standardizedFileURL)
        XCTAssertEqual(launch.arguments, ["--acp"])
    }

    @MainActor
    func testACustomAgentStartsItsCommandWithItsEnvironment() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let command = directory.appending(path: "my-agent")
        FileManager.default.createFile(atPath: command.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        let catalog = ACPAgentCatalog(directory: directory)
        catalog.instancesSetting = {
            ACPAgentInstance.json([ACPAgentInstance(id: "custom", source: .command, name: "Mine", executable: command.path,
                                                  arguments: "--profile\n\nacp\n", environment: "# for tests\nMODE=a=b\n\nEMPTY=")])
        }

        let agent = try XCTUnwrap(catalog.agent(id: ACPAgentCatalog.customId))
        let launch = try await catalog.launch(agent)

        XCTAssertEqual(agent.name, "Mine")
        XCTAssertEqual(launch.executable.path, command.path)
        XCTAssertEqual(launch.arguments, ["--profile", "acp"])
        XCTAssertEqual(launch.environment["MODE"], "a=b")
        XCTAssertEqual(launch.environment["EMPTY"], "")
        XCTAssertNotNil(launch.environment["PATH"])
    }

    /// The whole way in: the stored setting, the launch, a real process and the ACP handshake over its stdio.
    @MainActor
    func testACustomAgentAnswersInitializeWithItsArgumentsAndEnvironment() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let command = directory.appending(path: "harness")
        let script = """
        #!/usr/bin/python3
        import json, os, sys
        for line in sys.stdin:
            message = json.loads(line)
            info = {"name": " ".join(sys.argv[1:]) + " " + os.environ.get("HARNESS_MODE", "")}
            print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": {"protocolVersion": 1, "agentInfo": info}}), flush=True)
        """
        FileManager.default.createFile(atPath: command.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
        let catalog = ACPAgentCatalog(directory: directory)
        catalog.instancesSetting = {
            ACPAgentInstance.json([ACPAgentInstance(id: "custom", source: .command, executable: command.path,
                                                  arguments: "--profile\nacp", environment: "HARNESS_MODE=demo")])
        }
        let launch = try await catalog.launch(try XCTUnwrap(catalog.agent(id: ACPAgentCatalog.customId)))
        let connection = ACPConnection(executable: launch.executable, arguments: launch.arguments, environment: launch.environment, directory: directory)
        try connection.start()
        defer { connection.terminate() }

        let answer = try await connection.request("initialize", ["protocolVersion": 1])

        XCTAssertEqual((answer["agentInfo"] as? [String: Any])?["name"] as? String, "--profile acp demo")
    }

    @MainActor
    func testACustomAgentNeedsAFullPathToAnExecutableFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plain = directory.appending(path: "plain")
        FileManager.default.createFile(atPath: plain.path, contents: Data(), attributes: [.posixPermissions: 0o644])
        let catalog = ACPAgentCatalog(directory: directory)

        for executable in ["dsh", directory.appending(path: "missing").path, plain.path, directory.path] {
            let agent = try XCTUnwrap(ACPAgentCatalog.customAgent(#"{"executable": "\#(executable)"}"#))
            do {
                _ = try await catalog.launch(agent)
                XCTFail("\(executable) must not start")
            } catch is ACPAgentCatalog.LaunchError {}
        }
        // The name falls back to the command's, and an empty command is no agent.
        XCTAssertEqual(ACPAgentCatalog.customAgent(#"{"executable": "/usr/local/bin/dsh"}"#)?.name, "dsh")
        XCTAssertNil(ACPAgentCatalog.customAgent(#"{"executable": "  "}"#))
        XCTAssertNil(ACPAgentCatalog.customAgent(nil))
        XCTAssertNil(ACPAgentCatalog.customAgent("not json"))
    }

    func testACustomAgentRefusesAnEnvironmentLineThatIsNotAVariable() {
        XCTAssertThrowsError(try ACPAgentCatalog.environment("OK=1\nno equals", agent: "Mine"))
        XCTAssertThrowsError(try ACPAgentCatalog.environment("=value", agent: "Mine"))
        XCTAssertThrowsError(try ACPAgentCatalog.environment("1ST=value", agent: "Mine"))
        XCTAssertThrowsError(try ACPAgentCatalog.environment("A B=value", agent: "Mine"))
    }

    func testAgentFieldsSurviveTheSessionStore() throws {
        var tab = Tab(title: "Fix login", kind: .agent, cwd: "/tmp/acme", agentId: "claude-acp", agentSessionId: "s1")
        tab.spaceId = UUID()
        let data = try PropertyListEncoder().encode(StoredTab(tab))
        let restored = try PropertyListDecoder().decode(StoredTab.self, from: data)
        XCTAssertEqual(restored.kind, .agent)
        XCTAssertEqual(restored.agentId, "claude-acp")
        XCTAssertEqual(restored.agentSessionId, "s1")
        XCTAssertEqual(restored.cwd, "/tmp/acme")
    }
}
