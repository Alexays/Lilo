import XCTest
@testable import Lilo

/// `connect_status`: the allowlist is the whole surface - every key serializes, no other key reads,
/// nothing writes, and the status follows the client file it names.
@MainActor
final class AgentConnectStatusTests: AgentToolTestCase {
    private var home: URL!

    override func setUp() async throws {
        try await super.setUp()
        home = FileManager.default.temporaryDirectory.appending(path: "agent-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        home = nil
        super.tearDown()
    }

    private func session(named name: String = "Test Agent") throws -> AgentSession {
        try XCTUnwrap(control.sessions.first { $0.clientName == name })
    }

    /// The reply `snapshot` builds for the client `name`, against the test's own home.
    private func snapshot(named name: String = "Test Agent") async throws -> [String: Any] {
        try await AgentConnectStatus.snapshot(for: session(named: name), control: control, home: home)
    }

    /// The tool's reply parsed back to an object.
    private func reply() async throws -> [String: Any] {
        let reply = await client.callTool("connect_status")
        XCTAssertFalse(reply.isError, reply.text)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.text.utf8)) as? [String: Any], reply.text)
    }

    /// `object["a"]["b"]` for the "a.b" path, nil when any step is missing.
    private func resolve(_ path: String, in object: [String: Any]) -> Any? {
        var node: Any? = object
        for part in path.split(separator: ".") { node = (node as? [String: Any])?[String(part)] }
        return node
    }

    /// Every "group.name" path a nested object holds; a top-level scalar keeps its own name.
    private func paths(_ object: [String: Any], under prefix: String = "") -> Set<String> {
        object.reduce(into: []) { paths, entry in
            let path = prefix + entry.key
            if let nested = entry.value as? [String: Any] {
                paths.formUnion(self.paths(nested, under: path + "."))
            } else {
                paths.insert(path)
            }
        }
    }

    func testEveryAllowlistedKeySerializes() async throws {
        context.settingsStore!.set(AgentControl.asksBeforeActionsKey, value: "false")
        control.setClientPermission("Test Agent", AgentClientPermission(act: .sites, sites: ["example.com"]))

        let object = try await snapshot()
        let expected: [String: Any] = [
            "client": "other",
            "status": "unknown",
            "fix": AgentClientConfig.genericConfigJSON,
            "consent.askBeforeActions": false,
            "consent.actsOnPages": "sites"
        ]
        XCTAssertEqual(Set(AgentConnectStatus.allowlist), Set(expected.keys), "the test's table must cover the whole allowlist")
        for key in AgentConnectStatus.allowlist {
            let value = try XCTUnwrap(resolve(key, in: object), "\(key) is allowlisted but missing from the reply")
            XCTAssertEqual(AgentTools.json(value), AgentTools.json(expected[key] as Any), key)
        }
    }

    func testNoKeyOutsideTheAllowlistIsExposed() async throws {
        // Keys an agent must not read stay unreadable even when the store holds them.
        context.settingsStore!.set(AgentControl.alwaysAllowedSitesKey, value: #"["example.com"]"#)
        control.setClientPermission("Test Agent", AgentClientPermission(act: .sites, sites: ["example.net"]))
        let object = try await snapshot()
        XCTAssertEqual(paths(object), Set(AgentConnectStatus.allowlist))
        // The sites a client acts on unasked never show: its tier's name does, never the list.
        XCTAssertFalse(AgentTools.json(object).contains("example.com"), "the always-allowed sites never show")
        XCTAssertFalse(AgentTools.json(object).contains("example.net"), "the client's own sites never show")
    }

    func testTheToolHasNoWritePath() async throws {
        let definition = AgentTools.definitions.first { $0["name"] as? String == "connect_status" }
        let schema = try XCTUnwrap(definition?["inputSchema"] as? [String: Any])
        XCTAssertTrue((schema["properties"] as? [String: Any] ?? [:]).isEmpty, "connect_status takes no parameters, not even optional ones")
        XCTAssertTrue((schema["required"] as? [String] ?? []).isEmpty)

        // Setter-shaped arguments are ignored and nothing changes.
        let before = AgentTools.json(try await reply())
        let reply = await client.callTool("connect_status", ["status": "connected", "set": ["consent.actsOnPages": "always"]])
        XCTAssertFalse(reply.isError, reply.text)
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.text.utf8)) as? [String: Any], reply.text)
        XCTAssertEqual(AgentTools.json(after), before)
        XCTAssertNil(context.settingsStore!.get(AgentClientPermission.settingKey))
    }

    func testAClientLiloDoesNotKnowReadsAsOther() async throws {
        let object = try await snapshot()
        XCTAssertEqual(object["client"] as? String, "other")
        XCTAssertEqual(object["status"] as? String, "unknown")
        // The generic entry names Lilo's server so the user can paste it into whatever the client reads.
        let fix = try XCTUnwrap(object["fix"] as? String)
        XCTAssertTrue(fix.contains("\"lilo\""), fix)
        XCTAssertTrue(fix.contains(AgentClientConfig.helperPath), fix)
    }

    func testTheStatusFollowsTheClientConfigFile() async throws {
        let codex = try AgentTestClient(path: socketURL)
        _ = await codex.initialize(name: "Codex")

        // Nothing written: the snippet is the fix the settings page offers.
        var object = try await snapshot(named: "Codex")
        XCTAssertEqual(object["client"] as? String, "codex")
        XCTAssertEqual(object["status"] as? String, "missing")
        XCTAssertEqual(object["fix"] as? String, AgentClientConfig.manualSnippet(.codex))

        // A live entry reads connected and needs no fix.
        _ = try await AgentClientConfig.connect(.codex, home: home)
        object = try await snapshot(named: "Codex")
        XCTAssertEqual(object["status"] as? String, "connected")
        XCTAssertTrue(object["fix"] is NSNull)

        // An entry pointing at a Lilo that moved reads stale, with the same fix as a missing one.
        let url = home.appending(path: ".codex/config.toml")
        let text = try String(contentsOf: url, encoding: .utf8)
        try text.replacingOccurrences(of: AgentClientConfig.helperPath, with: "/moved/lilo-mcp").write(to: url, atomically: true, encoding: .utf8)
        object = try await snapshot(named: "Codex")
        XCTAssertEqual(object["status"] as? String, "stale")
        XCTAssertEqual(object["fix"] as? String, AgentClientConfig.manualSnippet(.codex))
    }

    func testNothingSensitiveIsExposed() async throws {
        _ = try context.spaceManager!.createSpace(name: "Secret Finances", profileId: space.profileId, isPrivate: true)
        let text = AgentTools.json(try await snapshot())
        XCTAssertFalse(text.contains("Secret Finances"), "a private space's name must never show")
        for word in ["token", "secret", "password", "cookie", "sock"] {
            XCTAssertFalse(text.lowercased().contains(word), "\(word) shows: \(text)")
        }
    }
}
