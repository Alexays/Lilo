import XCTest
@testable import Lilo

@MainActor
final class AgentConsentTests: AgentToolTestCase {
    /// Answers the question the drawers show, as a click on Allow or Deny does.
    private func answerConsent(_ granted: Bool) async throws {
        await pollUntil(timeout: 5) { !self.control.pendingConsentAnswers.isEmpty }
        let requestId = try XCTUnwrap(control.pendingConsentAnswers.keys.first, "the question reaches the drawers")
        XCTAssertNil(window.window?.attachedSheet, "nothing modal over the user's window")
        control.answerConsent(requestId, granted: granted)
    }

    func testAnUnknownClientIsAnsweredAtOnceAndItsToolsWaitForConsent() async throws {
        let newcomer = try AgentTestClient(path: socketURL)

        let result = await newcomer.initialize(name: "Newcomer")
        XCTAssertEqual((result?["serverInfo"] as? [String: Any])?["name"] as? String, "lilo", "a client never times out on its handshake")
        let waiting = await newcomer.callTool("tabs_context_mcp")
        XCTAssertTrue(waiting.isError)
        XCTAssertTrue(waiting.text.hasPrefix("[needs_user] Lilo is waiting for the user to allow Newcomer"), waiting.text)

        try await answerConsent(true)
        let allowed = await pollUntil(timeout: 5) { self.control.sessions.contains { $0.clientName == "Newcomer" && $0.isAuthorized } }
        XCTAssertTrue(allowed)
        let call = await newcomer.callTool("tabs_context_mcp")
        XCTAssertFalse(call.isError, call.text)
        XCTAssertEqual(control.allowedClients["Newcomer"], [AgentControl.clientIdentity(peer: getpid()).identity], "asked once, remembered")
    }

    func testARefusedClientIsToldAtEachToolCall() async throws {
        let newcomer = try AgentTestClient(path: socketURL)
        _ = await newcomer.initialize(name: "Newcomer")

        try await answerConsent(false)
        let refused = await pollUntil(timeout: 5) { self.control.sessions.contains { $0.clientName == "Newcomer" && $0.isRefused } }
        XCTAssertTrue(refused)

        let call = await newcomer.callTool("tabs_context_mcp")
        XCTAssertTrue(call.text.hasPrefix("[needs_user] The user did not allow Newcomer"), call.text)
        XCTAssertTrue(control.pendingConsentAnswers.isEmpty, "a refusal is not asked again until the client reconnects")
        XCTAssertFalse(control.allowedClients.keys.contains("Newcomer"))
    }

    func testTwoConnectionsOfOneClientShareOneQuestion() async throws {
        let first = try AgentTestClient(path: socketURL)
        let second = try AgentTestClient(path: socketURL)
        _ = await first.initialize(name: "Newcomer")
        _ = await second.initialize(name: "Newcomer")
        let asked = await pollUntil(timeout: 5) { !self.control.pendingConsentAnswers.isEmpty }
        XCTAssertTrue(asked)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(control.pendingConsentAnswers.count, 1)
        try await answerConsent(true)

        let both = await pollUntil(timeout: 5) { self.control.sessions.filter { $0.clientName == "Newcomer" && $0.isAuthorized }.count == 2 }
        XCTAssertTrue(both)
    }

    /// An agent app's local mode connects, tries a tool and leaves while the user is still on the way.
    func testAQuestionOutlivesItsConnectionsAndLetsTheNextOneIn() async throws {
        let first = try AgentTestClient(path: socketURL)
        _ = await first.initialize(name: "Newcomer")
        let asked = await pollUntil(timeout: 5) { self.control.pendingConsentAnswers.count == 1 }
        XCTAssertTrue(asked)

        first.close()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(control.pendingConsentAnswers.count, 1, "the question stays up once its client left")
        try await answerConsent(true)
        let remembered = await pollUntil(timeout: 5) { self.control.allowedClients["Newcomer"] != nil }
        XCTAssertTrue(remembered)

        let next = try AgentTestClient(path: socketURL)
        _ = await next.initialize(name: "Newcomer")
        let call = await next.callTool("tabs_context_mcp")
        XCTAssertFalse(call.isError, call.text)
        XCTAssertTrue(control.pendingConsentAnswers.isEmpty, "not asked again")
    }

    func testAnApprovedNameFromAnotherProgramIsAskedAgain() async throws {
        context.settingsStore.set("agentAllowedClients", value: #"{"claude-code": ["/usr/local/bin/claude"]}"#)
        let impostor = try AgentTestClient(path: socketURL)
        _ = await impostor.initialize(name: "claude-code")

        try await answerConsent(false)

        let refused = await pollUntil(timeout: 5) { self.control.sessions.contains { $0.clientName == "claude-code" && $0.isRefused } }
        XCTAssertTrue(refused, "the name alone is no approval")
        XCTAssertEqual(control.allowedClients["claude-code"], ["/usr/local/bin/claude"])
    }

    func testToolsNeedInitialize() async throws {
        let stranger = try AgentTestClient(path: socketURL)

        let reply = await stranger.request("tools/list")

        XCTAssertEqual((reply?["error"] as? [String: Any])?["code"] as? Int, -32002)
    }

    func testRevokingAClientDisconnectsItAndKeepsTheOthers() async throws {
        XCTAssertFalse(control.sessions.isEmpty)
        control.revoke("Test Agent")

        let disconnected = await pollUntil(timeout: 5) { !self.control.sessions.contains { $0.clientName == "Test Agent" } }
        XCTAssertTrue(disconnected)
        XCTAssertEqual(control.allowedClients.keys.sorted(), ["Codex", "claude-code"])
    }
}
