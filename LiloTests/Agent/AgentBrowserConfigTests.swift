import XCTest
@testable import Lilo

/// `browser_config`: the allowlist is the whole surface - every key serializes, no other key reads,
/// nothing writes, nothing sensitive shows.
@MainActor
final class AgentBrowserConfigTests: AgentToolTestCase {
    /// The tool's reply parsed back to an object.
    private func snapshot() async throws -> [String: Any] {
        let reply = await client.callTool("browser_config")
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
        context.settingsStore!.set(AgentActionLog.settingKey, value: "false")
        context.settingsStore!.set("contentBlockerEnabled", value: "false")
        context.settingsStore!.set("defaultZoom", value: "1.25")

        let reply = await client.callTool("browser_config")
        XCTAssertFalse(reply.isError, reply.text)
        let object = try JSONSerialization.jsonObject(with: Data(reply.text.utf8)) as? [String: Any] ?? [:]
        // The table the allowlist is checked against: a key added to one but not the other fails.
        let expected: [String: Any] = [
            "lilo": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            "features.contentBlocker": false,
            "features.defaultZoom": 1.25,
            "agent.profile": "Agents",
            "agent.askBeforeActions": false,
            "agent.actionLog": false,
            "agent.idlePosture": "full-rate"
        ]
        XCTAssertEqual(Set(AgentBrowserConfig.allowlist), Set(expected.keys), "the test's table must cover the whole allowlist")
        for key in AgentBrowserConfig.allowlist {
            let value = try XCTUnwrap(resolve(key, in: object), "\(key) is allowlisted but missing from the reply")
            XCTAssertEqual(AgentTools.json(value), AgentTools.json(expected[key] as Any), key)
        }
    }

    func testNoKeyOutsideTheAllowlistIsExposed() async throws {
        // Keys an agent must not read stay unreadable even when the store holds them.
        context.settingsStore!.set("customAgent", value: #"{"executable":"/secret/path/agent"}"#)
        context.settingsStore!.set(AgentControl.alwaysAllowedSitesKey, value: #"["example.com"]"#)
        let object = try await snapshot()
        XCTAssertEqual(paths(object), Set(AgentBrowserConfig.allowlist))
        XCTAssertNil(resolve("agent.customAgent", in: object))
        XCTAssertFalse(AgentTools.json(object).contains("example.com"), "the always-allowed sites never show")
    }

    func testTheToolHasNoWritePath() async throws {
        let definition = AgentTools.definitions.first { $0["name"] as? String == "browser_config" }
        let schema = try XCTUnwrap(definition?["inputSchema"] as? [String: Any])
        XCTAssertTrue((schema["properties"] as? [String: Any] ?? [:]).isEmpty, "browser_config takes no parameters, not even optional ones")
        XCTAssertTrue((schema["required"] as? [String] ?? []).isEmpty)

        // Setter-shaped arguments are ignored and nothing changes.
        let before = try await snapshot()
        let reply = await client.callTool("browser_config", [
            "lilo": "0.0.0", "agent": ["askBeforeActions": true], "set": ["agent.actionLog": "false"]
        ])
        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertEqual(reply.text, AgentTools.json(before))
        let after = AgentTools.json(try await snapshot())
        XCTAssertEqual(after, AgentTools.json(before))
        XCTAssertNil(context.settingsStore!.get(AgentControl.asksBeforeActionsKey))
    }

    func testNothingSensitiveIsExposed() async throws {
        // Give Lilo something private to leak: a private space with a telling name.
        _ = try context.spaceManager!.createSpace(name: "Secret Finances", profileId: space.profileId, isPrivate: true)
        let text = AgentTools.json(try await snapshot())
        XCTAssertFalse(text.contains("Secret Finances"), "a private space's name must never show")
        XCTAssertFalse(text.contains("/"), "no path or URL shows: \(text)")
        XCTAssertFalse(text.contains("\\"), text)
        XCTAssertFalse(text.contains("~"), text)
        for word in ["token", "secret", "password", "cookie", "key", "path", "sock"] {
            XCTAssertFalse(text.lowercased().contains(word), "\(word) shows: \(text)")
        }
    }
}
