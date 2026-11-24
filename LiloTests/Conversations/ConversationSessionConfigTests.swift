import XCTest
@testable import Lilo

/// Drives `ConversationHost` against a scripted ACP agent that records its requests, so a choice made in
/// one conversation can be checked against the session opened for the next.
@MainActor
final class ConversationSessionConfigTests: XCTestCase {
    private static let agentId = "scripted"

    /// Reads the modes and options from a file so the next agent process can offer different ones, and
    /// starts each process with an empty call log: the last conversation's requests are the ones under test.
    private static let agent = #"""
    #!/usr/bin/python3
    import json, os, sys
    state = json.load(open(os.environ["ACP_STATE_PATH"]))
    calls_path = os.environ["ACP_CALLS_PATH"]
    open(calls_path, "w").close()
    def send(result, msg_id):
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg_id, "result": result}) + "\n")
        sys.stdout.flush()
    for line in sys.stdin:
        message = json.loads(line)
        method, msg_id = message.get("method"), message.get("id")
        with open(calls_path, "a") as f:
            f.write(json.dumps({"method": method, "params": message.get("params") or {}}) + "\n")
        if method == "initialize":
            if state["protocol"] >= 2:
                result = {"protocolVersion": 2, "capabilities": {"session": {}}}
            else:
                result = {"protocolVersion": 1, "agentCapabilities": {"loadSession": False}}
        elif method == "session/new":
            result = {"sessionId": "session-1"}
            if state["protocol"] >= 2:
                result["configOptions"] = state.get("configOptions", [])
            else:
                result["modes"] = state.get("modes", {})
        elif method == "session/set_config_option":
            result = {"configOptions": state.get("configOptions", [])}
        elif method == "session/prompt":
            result = {"stopReason": "end_turn"}
        else:
            result = {}
        send(result, msg_id)
    """#

    private var directory: URL!
    private var script: URL!
    private var state: URL!
    private var calls: URL!
    private var commands: String?
    private var hosts: [ConversationHost] = []

    override func setUpWithError() throws {
        UserDefaults.lilo.removeObject(forKey: "agentConfigChoices")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-session-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"version":"1.0.0","agents":[]}"#.utf8).write(to: directory.appending(path: "registry.json"))
        script = directory.appending(path: "agent.py")
        try Self.agent.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        state = directory.appending(path: "state.json")
        calls = directory.appending(path: "calls.jsonl")
        try writeState(version: 1, modes: [])
        let command: [String: String] = [
            "id": Self.agentId, "name": "Scripted", "executable": script.path, "arguments": "",
            "environment": "ACP_STATE_PATH=\(state.path)\nACP_CALLS_PATH=\(calls.path)"
        ]
        commands = String(decoding: try JSONSerialization.data(withJSONObject: [command]), as: UTF8.self)
    }

    override func tearDownWithError() throws {
        for host in hosts {
            for tabId in Array(host.conversations.keys) { host.close(tabId) }
        }
        hosts.removeAll()
        UserDefaults.lilo.removeObject(forKey: "agentConfigChoices")
        try? FileManager.default.removeItem(at: directory)
    }

    func testV1ModeIsReappliedWhenANewConversationOpens() async throws {
        try writeState(version: 1, modes: [
            ["id": "default", "name": "Default"], ["id": "acceptEdits", "name": "Accept edits"]
        ])
        let first = makeHost()
        let firstTab = register(first)
        start(first, firstTab)
        let ok87 = await waitForCall("session/new")
        XCTAssertTrue(ok87)
        first.setMode(firstTab, modeId: "acceptEdits")
        let applied = await waitForCall("session/set_mode", field: "modeId", value: "acceptEdits")
        XCTAssertTrue(applied)
        let stored = await waitForChoice("lilo:mode", value: "acceptEdits")
        XCTAssertTrue(stored)
        close(first)

        let second = makeHost()
        start(second, register(second))
        let ok97 = await waitForCall("session/set_mode", field: "modeId", value: "acceptEdits")
        XCTAssertTrue(ok97)
        XCTAssertFalse(callsMade().contains { $0["method"] as? String == "session/set_config_option" })
    }

    func testV2ModeIsReappliedWhenANewConversationOpens() async throws {
        try writeState(version: 2, configOptions: [modeOption()])
        let first = makeHost()
        let firstTab = register(first)
        start(first, firstTab)
        let ok106 = await waitForCall("session/new")
        XCTAssertTrue(ok106)
        first.setConfigOption(firstTab, configId: "mode", value: "acceptEdits")
        let ok108 = await waitForCall("session/set_config_option", field: "configId", value: "mode")
        XCTAssertTrue(ok108)
        let ok109 = await waitForChoice("mode", value: "acceptEdits")
        XCTAssertTrue(ok109)
        close(first)

        let second = makeHost()
        start(second, register(second))
        let ok114 = await waitForCall("session/set_config_option", field: "configId", value: "mode")
        XCTAssertTrue(ok114)
        let applied = callsMade().first { $0["method"] as? String == "session/set_config_option" }
        XCTAssertEqual((applied?["params"] as? [String: Any])?["value"] as? String, "acceptEdits")
    }

    func testSetModeStoresTheV2ModeConfigId() async throws {
        try writeState(version: 2, configOptions: [modeOption()])
        let host = makeHost()
        let tabId = register(host)
        start(host, tabId)
        let ok124 = await waitForCall("session/new")
        XCTAssertTrue(ok124)
        host.setMode(tabId, modeId: "acceptEdits")

        let ok127 = await waitForChoice("mode", value: "acceptEdits")
        XCTAssertTrue(ok127)
        XCTAssertNil(choices()?["lilo:mode"])
    }

    func testAModeTheAgentNoLongerOffersIsForgotten() async throws {
        UserDefaults.lilo.set([Self.agentId: ["lilo:mode": "acceptEdits"]], forKey: "agentConfigChoices")
        try writeState(version: 1, modes: [["id": "default", "name": "Default"]])
        let host = makeHost()
        start(host, register(host))

        let ok137 = await waitForCall("session/prompt")
        XCTAssertTrue(ok137)
        XCTAssertFalse(callsMade().contains { $0["method"] as? String == "session/set_mode" })
        XCTAssertNil(choices()?["lilo:mode"])
    }

    func testAnUnavailableV2ModeIsForgotten() async throws {
        UserDefaults.lilo.set([Self.agentId: ["mode": "acceptEdits"]], forKey: "agentConfigChoices")
        try writeState(version: 2, configOptions: [["configId": "model", "currentValue": "a"]])
        let host = makeHost()
        start(host, register(host))

        let ok148 = await waitForCall("session/prompt")
        XCTAssertTrue(ok148)
        XCTAssertFalse(callsMade().contains { $0["method"] as? String == "session/set_config_option" })
        XCTAssertNil(choices()?["mode"])
    }

    func testANonModeChoiceStillCarriesToANewConversation() async throws {
        let model: [String: Any] = ["configId": "model", "name": "Model", "category": "model", "currentValue": "a"]
        try writeState(version: 2, configOptions: [model])
        let first = makeHost()
        let firstTab = register(first)
        start(first, firstTab)
        let ok159 = await waitForCall("session/new")
        XCTAssertTrue(ok159)
        first.setConfigOption(firstTab, configId: "model", value: "b")
        let ok161 = await waitForChoice("model", value: "b")
        XCTAssertTrue(ok161)
        close(first)

        let second = makeHost()
        start(second, register(second))
        let ok166 = await waitForCall("session/set_config_option", field: "value", value: "b")
        XCTAssertTrue(ok166)
    }

    private func makeHost() -> ConversationHost {
        let host = ConversationHost(directory: directory)
        host.catalog.commandsSetting = { [weak self] in self?.commands }
        hosts.append(host)
        return host
    }

    private func register(_ host: ConversationHost) -> UUID {
        let tab = Tab(title: "Config test", kind: .agent, cwd: directory.path, agentId: Self.agentId)
        host.register(tab, folderId: nil)
        return tab.id
    }

    private func start(_ host: ConversationHost, _ tabId: UUID) {
        host.send(tabId, blocks: [["type": "text", "text": "hi"]], interrupt: false)
    }

    private func close(_ host: ConversationHost) {
        for tabId in Array(host.conversations.keys) { host.close(tabId) }
    }

    private func choices() -> [String: Any]? {
        UserDefaults.lilo.dictionary(forKey: "agentConfigChoices")?[Self.agentId] as? [String: Any]
    }

    private func modeOption() -> [String: Any] {
        ["configId": "mode", "name": "Mode", "category": "mode", "currentValue": "default",
         "options": [["value": "default", "name": "Default"], ["value": "acceptEdits", "name": "Accept edits"]]]
    }

    private func writeState(version: Int, modes: [[String: Any]]? = nil, configOptions: [[String: Any]]? = nil) throws {
        var object: [String: Any] = ["protocol": version]
        if let modes { object["modes"] = ["currentModeId": "default", "availableModes": modes] }
        if let configOptions { object["configOptions"] = configOptions }
        try JSONSerialization.data(withJSONObject: object).write(to: state, options: .atomic)
    }

    private func callsMade() -> [[String: Any]] {
        guard let lines = try? String(contentsOf: calls, encoding: .utf8) else { return [] }
        return lines.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
    }

    private func waitForCall(_ method: String, field: String? = nil, value: String? = nil) async -> Bool {
        await pollUntil(timeout: 15) {
            callsMade().contains { call in
                guard call["method"] as? String == method else { return false }
                guard let field else { return true }
                return (call["params"] as? [String: Any])?[field] as? String == value
            }
        }
    }

    private func waitForChoice(_ configId: String, value: String) async -> Bool {
        await pollUntil(timeout: 15) { choices()?[configId] as? String == value }
    }
}
