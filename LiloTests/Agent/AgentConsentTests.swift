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

    func testUnknownClientWaitsForConsent() async throws {
        let newcomer = try AgentTestClient(path: socketURL)
        let reply = Task { await newcomer.initialize(name: "Newcomer") }

        try await answerConsent(true)

        let result = await reply.value
        XCTAssertEqual((result?["serverInfo"] as? [String: Any])?["name"] as? String, "lilo")
        XCTAssertEqual(control.allowedClients["Newcomer"], [AgentControl.clientIdentity(peer: getpid()).identity], "asked once, remembered")
    }

    func testRefusedConsentClosesConnection() async throws {
        let newcomer = try AgentTestClient(path: socketURL)
        let reply = Task { await newcomer.initialize(name: "Newcomer") }

        try await answerConsent(false)

        let result = await reply.value
        XCTAssertEqual((result?["error"] as? [String: Any])?["code"] as? Int, -32001)
        let next = await newcomer.receive()
        XCTAssertNil(next, "Lilo hung up")
        XCTAssertFalse(control.allowedClients.keys.contains("Newcomer"))
    }

    func testTwoConnectionsOfOneClientShareOneQuestion() async throws {
        let first = try AgentTestClient(path: socketURL)
        let second = try AgentTestClient(path: socketURL)
        let replies = Task { (await first.initialize(name: "Newcomer"), await second.initialize(name: "Newcomer")) }
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(control.pendingConsentAnswers.count, 1)
        try await answerConsent(true)

        let (one, two) = await replies.value
        XCTAssertNotNil(one?["serverInfo"])
        XCTAssertNotNil(two?["serverInfo"])
    }

    func testLeavingWhileAskedWithdrawsTheQuestion() async throws {
        let first = try AgentTestClient(path: socketURL)
        let second = try AgentTestClient(path: socketURL)
        let replies = [Task { _ = await first.initialize(name: "Newcomer") }, Task { _ = await second.initialize(name: "Newcomer") }]
        let asked = await pollUntil(timeout: 5) { self.control.pendingConsentAnswers.count == 1 }
        XCTAssertTrue(asked)

        first.close()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(control.pendingConsentAnswers.count, 1, "the other connection still waits on it")
        second.close()

        let withdrawn = await pollUntil(timeout: 5) { self.control.pendingConsentAnswers.isEmpty }
        XCTAssertTrue(withdrawn, "nobody is left to approve")
        XCTAssertFalse(control.allowedClients.keys.contains("Newcomer"))
        for reply in replies { await reply.value }
    }

    func testAnApprovedNameFromAnotherProgramIsAskedAgain() async throws {
        context.settingsStore.set("agentAllowedClients", value: #"{"claude-code": ["/usr/local/bin/claude"]}"#)
        let impostor = try AgentTestClient(path: socketURL)
        let reply = Task { await impostor.initialize(name: "claude-code") }

        try await answerConsent(false)

        let result = await reply.value
        XCTAssertEqual((result?["error"] as? [String: Any])?["code"] as? Int, -32001, "the name alone is no approval")
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
