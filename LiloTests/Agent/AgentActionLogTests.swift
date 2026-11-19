import XCTest
@testable import Lilo

@MainActor
final class AgentActionLogTests: AgentToolTestCase {
    private var logDirectory: URL { URL(fileURLWithPath: context.appSupportDirectory).appending(path: "Agents/Actions") }
    private var logFile: URL { logDirectory.appending(path: "client-test-agent.jsonl") }

    private func lines(_ file: URL? = nil) throws -> [[String: Any]] {
        control.actionLog.flush()
        guard let data = try? Data(contentsOf: file ?? logFile) else { return [] }
        return try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func testEachCallAppendsOneLine() async throws {
        let tab = try await agentTab(showing: "<title>t</title><input id=a type=password>")
        _ = await client.callTool("get_page_text", ["tabId": tab])
        _ = await client.callTool("form_input", ["tabId": tab, "ref": "ref_missing", "value": "hunter2-password"])

        let entries = try lines()
        XCTAssertEqual(entries.map { $0["tool"] as? String }, ["tabs_create_mcp", "navigate", "get_page_text", "form_input"])
        let last = try XCTUnwrap(entries.last)
        XCTAssertEqual(last["ok"] as? Bool, false)
        XCTAssertEqual(last["tabId"] as? Int, tab)
        XCTAssertNotNil(last["duration_ms"] as? Int)
        XCTAssertNotNil(last["ts"] as? String)
        XCTAssertEqual((last["args"] as? [String: Any])?["ref"] as? String, "ref_missing")
        let navigate = try XCTUnwrap(entries[1])
        XCTAssertEqual(navigate["ok"] as? Bool, true)
        XCTAssertEqual(navigate["host"] as? String, nil, "a data URL has no host")
        let raw = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertFalse(raw.contains("hunter2"), "typed text is never stored")
    }

    func testAToolThatNeverRanWritesNothing() async throws {
        let unknown = await client.callTool("no_such_tool", [:])
        XCTAssertTrue(unknown.isError)
        let stranger = try AgentTestClient(path: socketURL)
        let refused = await stranger.callTool("tabs_context_mcp")
        XCTAssertTrue(refused.isError, "a client that skipped the handshake is refused: \(refused.text)")

        XCTAssertEqual(try lines().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logDirectory.appending(path: "client-agent.jsonl").path))
    }

    func testTheSettingTurnsItOff() async throws {
        context.settingsStore!.set(AgentActionLog.settingKey, value: "false")
        _ = await client.callTool("tabs_context_mcp")
        XCTAssertEqual(try lines().count, 0)
        context.settingsStore!.set(AgentActionLog.settingKey, value: "true")
        _ = await client.callTool("tabs_context_mcp")
        XCTAssertEqual(try lines().count, 1)
    }

    func testRedactionKeepsStructureAndDropsContent() {
        let redacted = AgentActionLog.redact([
            "tabId": 3, "action": "left_click", "coordinate": [10, 20], "ref": "ref_7",
            "value": 123456, "text": "my password", "cookie": "sid=abc", "body": "{\"token\":1}",
            "headers": ["Authorization": "Bearer x"], "url": "https://example.com/reset?token=abc#frag",
            "selector": "#secret-field", "modifiers": "cmd"
        ])
        XCTAssertEqual(redacted["tabId"] as? Int, 3)
        XCTAssertEqual(redacted["action"] as? String, "left_click")
        XCTAssertEqual(redacted["coordinate"] as? [Int], [10, 20])
        XCTAssertEqual(redacted["ref"] as? String, "ref_7")
        XCTAssertEqual(redacted["modifiers"] as? String, "cmd")
        XCTAssertEqual(redacted["url"] as? String, "example.com", "a URL keeps its host only")
        XCTAssertEqual(redacted["value"] as? [String: Bool], ["redacted": true], "a number value is masked too: it can be a one-time code")
        XCTAssertEqual(redacted["text"] as? [String: Int], ["chars": 11])
        XCTAssertEqual(redacted["cookie"] as? [String: Int], ["chars": 7])
        XCTAssertEqual(redacted["body"] as? [String: Int], ["chars": 11])
        XCTAssertEqual(redacted["headers"] as? [String: Int], ["keys": 1])
        XCTAssertEqual(redacted["selector"] as? [String: Int], ["chars": 13])
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: redacted)) ?? Data(), as: UTF8.self)
        for secret in ["password", "sid=abc", "Bearer", "token", "reset", "123456", "secret-field"] {
            XCTAssertFalse(json.contains(secret), "\(secret) leaked: \(json)")
        }
    }

    func testRotationKeepsOneOlderFileUnderTheCap() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "action-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = AgentActionLog(directory: directory, maxBytes: 600)
        let session = try XCTUnwrap(control.sessions.first)
        for index in 0..<20 {
            log.record(tool: "navigate", arguments: ["tabId": index], session: session, host: "example.com", ok: true, code: nil, possibleCommit: false, startedAt: Date())
        }
        log.flush()

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(names, ["client-test-agent.1.jsonl", "client-test-agent.jsonl"])
        for name in names {
            let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: directory.appending(path: name).path)[.size] as? Int)
            XCTAssertLessThanOrEqual(size, 600)
        }
        let current = try lines(directory.appending(path: "client-test-agent.jsonl"))
        XCTAssertEqual(current.last?["args"] as? [String: Int], ["tabId": 19], "the newest line stays in the current file")
    }

    func testRemoveDeletesTheLogAndItsRotation() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "action-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["conversation-A.jsonl", "conversation-A.1.jsonl", "conversation-B.jsonl"] {
            try Data("{}\n".utf8).write(to: directory.appending(path: name))
        }
        AgentActionLog.remove("conversation-A", in: directory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["conversation-B.jsonl"])
    }

    /// The main thread's added time per call: building the line and queueing it. The disk write is off it.
    func testAddedTimePerCall() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "action-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = AgentActionLog(directory: directory)
        let session = try XCTUnwrap(control.sessions.first)
        let arguments: [String: Any] = ["tabId": 2, "ref": "ref_4", "value": "typed text", "url": "https://example.com/a?b=c"]
        let calls = 2000
        let clock = ContinuousClock()
        let spent = clock.measure {
            for _ in 0..<calls {
                log.record(tool: "form_input", arguments: arguments, session: session, host: "example.com", ok: true, code: nil, possibleCommit: false, startedAt: Date())
            }
        }
        log.flush()
        let micros = Double(spent.components.attoseconds / 1_000_000_000_000 + spent.components.seconds * 1_000_000) / Double(calls)
        print("agent action log: \(Int(micros)) us per call on the main thread")
        XCTAssertLessThan(micros, 500, "a line must stay far below the time of any tool")
        XCTAssertEqual(try lines(directory.appending(path: "client-test-agent.jsonl")).count, calls)
    }
}
