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
