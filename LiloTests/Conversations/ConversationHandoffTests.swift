import XCTest
@testable import Lilo

final class ConversationHandoffTests: XCTestCase {
    private func text(_ kind: String, _ text: String) -> [String: Any] {
        ["sessionUpdate": kind, "content": ["type": "text", "text": text]]
    }

    private func turn(_ number: Int, user: String? = nil, reply: String? = nil) -> [[String: Any]] {
        [["sessionUpdate": "lilo_user", "text": user ?? "question \(number)"], text("agent_message_chunk", reply ?? "answer \(number)"),
         ["sessionUpdate": "lilo_turn_end", "stopReason": "end_turn"]]
    }

    func testSummaryHoldsTurnsToolCallsAndTheAgentsName() throws {
        let log: [[String: Any]] = [
            ["sessionUpdate": "lilo_user", "text": "Fix the login bug"],
            ["sessionUpdate": "tool_call", "toolCallId": "a", "title": "Read Login.swift", "kind": "read", "status": "pending"],
            ["sessionUpdate": "tool_call_update", "toolCallId": "a", "status": "completed"],
            ["sessionUpdate": "tool_call", "toolCallId": "b", "title": "Run tests", "kind": "execute"],
            ["sessionUpdate": "tool_call_update", "toolCallId": "b", "status": "failed"],
            text("agent_message_chunk", "The token refresh fails."),
            ["sessionUpdate": "lilo_turn_end", "stopReason": "end_turn"]
        ]
        let summary = try XCTUnwrap(ConversationHandoff.summary(log: log, from: "Claude Agent"))
        XCTAssertTrue(summary.contains("(Claude Agent)"))
        XCTAssertTrue(summary.contains("User: Fix the login bug\nTool calls:\n- Read Login.swift\n- Run tests (failed)\nAgent: The token refresh fails."))
    }

    func testAPromptNoAgentAnsweredYetIsLeftOut() throws {
        let log = turn(1) + [["sessionUpdate": "lilo_user", "text": "the prompt about to be sent"]]
        let summary = try XCTUnwrap(ConversationHandoff.summary(log: log, from: nil))
        XCTAssertTrue(summary.contains("question 1"))
        XCTAssertFalse(summary.contains("about to be sent"))
    }

    func testNoTurnsGiveNoSummary() {
        XCTAssertNil(ConversationHandoff.summary(log: [], from: "Codex"))
        XCTAssertNil(ConversationHandoff.summary(log: [["sessionUpdate": "lilo_user", "text": "first prompt"]], from: nil))
    }

    func testTheNewestTurnsFitTheCaps() throws {
        let log = (1...20).flatMap { turn($0) }
        let byTurns = try XCTUnwrap(ConversationHandoff.summary(log: log, from: nil, maxTurns: 3))
        XCTAssertTrue(byTurns.contains("question 20") && byTurns.contains("question 18"))
        XCTAssertFalse(byTurns.contains("question 17"))
        XCTAssertTrue(byTurns.contains("17 earlier turns left out"))

        let long = (1...5).flatMap { turn($0, reply: String(repeating: "y", count: 1_500)) }
        let byCharacters = try XCTUnwrap(ConversationHandoff.summary(log: long, from: nil, maxCharacters: 4_000))
        XCTAssertTrue(byCharacters.contains("question 5"))
        XCTAssertFalse(byCharacters.contains("question 1\n"))
        XCTAssertLessThan(byCharacters.count, 5_000)
    }

    func testAnAgentsEchoOfLiloPromptAndSubAgentWorkAreNotTurns() throws {
        let log: [[String: Any]] = [
            ["sessionUpdate": "lilo_user", "text": "Explain"],
            text("user_message_chunk", "Explain"),
            ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "from a sub-agent"], "childSession": "child"],
            text("agent_message_chunk", "Here it is."),
            ["sessionUpdate": "lilo_turn_end"]
        ]
        let summary = try XCTUnwrap(ConversationHandoff.summary(log: log, from: nil))
        XCTAssertEqual(summary.components(separatedBy: "User: ").count - 1, 1)
        XCTAssertFalse(summary.contains("sub-agent"))
    }
}
