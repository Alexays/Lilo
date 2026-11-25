import XCTest
@testable import Lilo

/// Drives `ConversationHost` against a scripted ACP agent that records what it receives.
@MainActor
final class ConversationHostTests: XCTestCase {
    private static let agentId = "scripted"

    /// Reads the modes and options from a file so the next agent process can offer different ones. With
    /// `ask`, each prompt sends that request first and ends once it is answered.
    private static let agent = #"""
    #!/usr/bin/python3
    import json, os, sys
    state = json.load(open(os.environ["ACP_STATE_PATH"]))
    calls_path = os.environ["ACP_CALLS_PATH"]
    prompt_id = None
    def send(message):
        sys.stdout.write(json.dumps(dict(message, jsonrpc="2.0")) + "\n")
        sys.stdout.flush()
    for line in sys.stdin:
        message = json.loads(line)
        method, msg_id = message.get("method"), message.get("id")
        with open(calls_path, "a") as f:
            f.write(json.dumps({"method": method, "params": message.get("params") or {}, "result": message.get("result")}) + "\n")
        if method is None:
            send({"id": prompt_id, "result": {"stopReason": "end_turn"}})
            continue
        if method == "session/prompt" and state.get("ask"):
            prompt_id = msg_id
            send(dict(state["ask"], id="ask"))
            continue
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
        send({"id": msg_id, "result": result})
    """#

    private var directory: URL!
    private var script: URL!
    private var state: URL!
    /// The requests of the agent process the last host made: each host gets a file of its own.
    private var calls: URL!
    private var hosts: [ConversationHost] = []

    override func setUpWithError() throws {
        UserDefaults.lilo.removeObject(forKey: "agentConfigChoices")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-conversation-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"version":"1.0.0","agents":[]}"#.utf8).write(to: directory.appending(path: "registry.json"))
        script = directory.appending(path: "agent.py")
        try Self.agent.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        state = directory.appending(path: "state.json")
    }

    override func tearDownWithError() throws {
        for host in hosts {
            for tabId in Array(host.conversations.keys) { host.close(tabId) }
        }
        hosts.removeAll()
        UserDefaults.lilo.removeObject(forKey: "agentConfigChoices")
        try? FileManager.default.removeItem(at: directory)
    }

    func testAModelPickedBeforeTheSessionAppliesBeforeTheFirstPromptAndIsRecorded() async throws {
        let model: [String: Any] = ["configId": "model", "name": "Model", "category": "model", "currentValue": "a",
                                    "options": [["value": "a", "name": "A"], ["value": "b", "name": "B"]]]
        try writeState(version: 2, configOptions: [model])
        let host = makeHost()
        host.remember(Self.agentId, "model", "b")
        start(host, register(host))

        let prompted = await waitForCall("session/prompt")
        XCTAssertTrue(prompted)
        let methods = callsMade().compactMap { $0["method"] as? String }
        XCTAssertLessThan(try XCTUnwrap(methods.firstIndex(of: "session/set_config_option")), try XCTUnwrap(methods.firstIndex(of: "session/prompt")))
        XCTAssertEqual(host.readiness.record(for: Self.agentId)?.state, .ready)
        XCTAssertEqual(host.readiness.record(for: Self.agentId)?.modelConfigId, "model")
    }

    func testAURLElicitationOtherThanAWebPageIsCancelledUnseen() async throws {
        for url in ["file:///etc/hosts", "data:text/html,hi", "https://accounts.example.com@evil.example/sign-in"] {
            try writeState(version: 2, ask: Self.urlElicitation(url))
            let host = makeHost()
            let tabId = register(host)
            start(host, tabId)
            let answered = await waitForAnswer()
            XCTAssertEqual(answered?["action"] as? String, "cancel", url)
            XCTAssertFalse(host.conversations[tabId]?.log.contains { $0.value["sessionUpdate"] as? String == "lilo_sign_in_link" } ?? true, url)
            close(host)
        }
    }

    func testAURLElicitationShowsNoQueryAndIsAcceptedOnlyOnceItsTabOpened() async throws {
        try writeState(version: 2, ask: Self.urlElicitation("https://auth.example.com/authorize?state=secret"))
        let host = makeHost()
        let tabId = register(host)
        start(host, tabId)
        var link: [String: Any]?
        let shown = await pollUntil(timeout: 15) {
            link = host.conversations[tabId]?.log.last { $0.value["sessionUpdate"] as? String == "lilo_sign_in_link" }?.value
            return link != nil
        }
        XCTAssertTrue(shown)
        XCTAssertEqual(link?["host"] as? String, "auth.example.com")
        XCTAssertEqual(link?["path"] as? String, "/authorize")
        XCTAssertFalse(String(describing: link ?? [:]).contains("secret"))

        // No window shows this conversation, so no tab opens: the agent hears a cancel.
        host.answerQuestion(tabId, requestId: link?["requestId"] as? String ?? "", action: "accept", content: nil)
        let answered = await waitForAnswer()
        XCTAssertEqual(answered?["action"] as? String, "cancel")
    }

    private static func urlElicitation(_ url: String) -> [String: Any] {
        ["method": "elicitation/create", "params": [
            "sessionId": "session-1", "mode": "url", "elicitationId": "sign-in", "url": url, "message": "Sign in"
        ]]
    }

    /// What Lilo answered the agent's request with.
    private func waitForAnswer() async -> [String: Any]? {
        var answer: [String: Any]?
        _ = await pollUntil(timeout: 15) {
            answer = self.callsMade().last { $0["method"] is NSNull || $0["method"] == nil }?["result"] as? [String: Any]
            return answer != nil
        }
        return answer
    }

    private func makeHost() -> ConversationHost {
        calls = directory.appending(path: "calls-\(hosts.count).jsonl")
        let command: [String: String] = [
            "id": Self.agentId, "name": "Scripted", "executable": script.path, "arguments": "",
            "environment": "ACP_STATE_PATH=\(state.path)\nACP_CALLS_PATH=\(calls.path)"
        ]
        let commands = (try? JSONSerialization.data(withJSONObject: [command])).map { String(decoding: $0, as: UTF8.self) }
        let host = ConversationHost(directory: directory)
        host.catalog.commandsSetting = { commands }
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

    private func writeState(version: Int, configOptions: [[String: Any]]? = nil, ask: [String: Any]? = nil) throws {
        var object: [String: Any] = ["protocol": version]
        if let ask { object["ask"] = ask }
        if let configOptions { object["configOptions"] = configOptions }
        try JSONSerialization.data(withJSONObject: object).write(to: state, options: .atomic)
    }

    private func callsMade() -> [[String: Any]] {
        guard let lines = try? String(contentsOf: calls, encoding: .utf8) else { return [] }
        return lines.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
    }

    private func waitForCall(_ method: String) async -> Bool {
        await pollUntil(timeout: 15) { callsMade().contains { $0["method"] as? String == method } }
    }
}
