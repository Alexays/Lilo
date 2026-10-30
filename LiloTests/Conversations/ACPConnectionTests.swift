import XCTest
@testable import Lilo

/// Drives `ACPConnection` against a small agent written in Python that speaks ACP over stdio.
@MainActor
final class ACPConnectionTests: XCTestCase {
    private var script: URL!

    private static let agent = #"""
    import json, sys
    def send(message):
        sys.stdout.write(json.dumps(message) + "\n"); sys.stdout.flush()
    for line in sys.stdin:
        message = json.loads(line)
        method, id = message.get("method"), message.get("id")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": id, "result": {"protocolVersion": 1, "agentCapabilities": {"loadSession": True}}})
        elif method == "session/new":
            send({"jsonrpc": "2.0", "id": id, "result": {"sessionId": "s1"}})
        elif method == "session/prompt":
            for word in ["Hello", " there"]:
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": word}}}})
            send({"jsonrpc": "2.0", "id": "p1", "method": "session/request_permission", "params": {"sessionId": "s1", "options": [{"optionId": "yes", "name": "Allow", "kind": "allow_once"}], "toolCall": {"toolCallId": "t1", "title": "Run tests"}}})
            answer = json.loads(sys.stdin.readline())
            send({"jsonrpc": "2.0", "id": id, "result": {"stopReason": "end_turn" if answer["result"]["outcome"]["optionId"] == "yes" else "refusal"}})
        elif method == "fail":
            send({"jsonrpc": "2.0", "id": id, "error": {"code": -32000, "message": "auth_required"}})
        elif method == "exit":
            sys.stderr.write("bye\n"); sys.exit(3)
    """#

    override func setUpWithError() throws {
        script = FileManager.default.temporaryDirectory.appendingPathComponent("lilo-agent-\(UUID().uuidString).py")
        try Self.agent.write(to: script, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: script)
    }

    private func connect() throws -> ACPConnection {
        let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3"].first(where: FileManager.default.isExecutableFile(atPath:))
        let connection = ACPConnection(executable: URL(fileURLWithPath: try XCTUnwrap(python)), arguments: [script.path],
                                       environment: ProcessInfo.processInfo.environment, directory: FileManager.default.temporaryDirectory)
        try connection.start()
        return connection
    }

    func testATurnStreamsUpdatesAndWaitsOnThePermissionAnswer() async throws {
        let connection = try connect()
        defer { connection.terminate() }
        var chunks: [String] = []
        let asked = expectation(description: "permission asked")
        connection.onMessages = { messages in
            for message in messages {
                switch message {
                case .notification(_, let params):
                    let content = (params["update"] as? [String: Any])?["content"] as? [String: Any]
                    if let text = content?["text"] as? String { chunks.append(text) }
                case .request(let id, let method, _):
                    XCTAssertEqual(method, "session/request_permission")
                    connection.respond(id: id, result: ["outcome": ["outcome": "selected", "optionId": "yes"]])
                    asked.fulfill()
                }
            }
        }
        let initialized = try await connection.request("initialize", ["protocolVersion": 1])
        XCTAssertEqual((initialized["agentCapabilities"] as? [String: Any])?["loadSession"] as? Bool, true)
        let session = try await connection.request("session/new", ["cwd": "/tmp", "mcpServers": [Any]()])
        XCTAssertEqual(session["sessionId"] as? String, "s1")
        let result = try await connection.request("session/prompt", ["sessionId": "s1", "prompt": [["type": "text", "text": "hi"]]])
        await fulfillment(of: [asked], timeout: 5)
        XCTAssertEqual(result["stopReason"] as? String, "end_turn")
        XCTAssertEqual(chunks.joined(), "Hello there")
    }

    func testAnErrorReplyThrowsWithItsCode() async throws {
        let connection = try connect()
        defer { connection.terminate() }
        do {
            _ = try await connection.request("fail", [:])
            XCTFail("expected an error")
        } catch let error as ACPConnection.RPCError {
            XCTAssertEqual(error.code, -32000)
            XCTAssertEqual(error.message, "auth_required")
        }
    }

    func testAnAgentThatExitsFailsWhatWaitsAndSaysWhy() async throws {
        let connection = try connect()
        let exited = expectation(description: "exited")
        connection.onExit = { status, errors in
            XCTAssertEqual(status, 3)
            XCTAssertEqual(errors, "bye\n")
            exited.fulfill()
        }
        connection.notify("exit", [:])
        await fulfillment(of: [exited], timeout: 5)
        do {
            _ = try await connection.request("initialize", [:])
            XCTFail("expected an error")
        } catch {}
    }
}
