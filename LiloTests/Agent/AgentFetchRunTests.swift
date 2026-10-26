import XCTest
@testable import Lilo

@MainActor
final class AgentFetchRunTests: AgentToolTestCase {
    /// Serves a page, `/api` echoing the Cookie header it got while setting a cookie of its own, and 5000 bytes at `/big`.
    private func makeServer() async throws -> TinyHTTPServer {
        try await TinyHTTPServer { request in
            let cookie = request.split(separator: "\r\n").first { $0.lowercased().hasPrefix("cookie:") }.map { String($0.dropFirst(7)) } ?? ""
            if request.hasPrefix("GET /api ") {
                let body = try! JSONSerialization.data(withJSONObject: ["cookie": cookie.trimmingCharacters(in: .whitespaces)])
                return ("200 OK", ["Content-Type: application/json", "Set-Cookie: server=secret"], body)
            }
            if request.hasPrefix("GET /big ") { return ("200 OK", ["Content-Type: text/plain"], Data(repeating: 0x61, count: 5000)) }
            return ("200 OK", ["Content-Type: text/html"], Data("<!doctype html><title>Home</title><p>home</p>".utf8))
        }
    }

    private func tab(on server: TinyHTTPServer) async throws -> Int {
        let tab = try await newAgentTab()
        let reply = await client.callTool("navigate", ["tabId": tab, "url": "http://127.0.0.1:\(server.port)/"])
        XCTAssertFalse(reply.isError, reply.text)
        return tab
    }

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }

    func testFetchSendsThePagesCookiesAndHidesSetCookie() async throws {
        let server = try await makeServer()
        let tab = try await tab(on: server)
        _ = await client.callTool("javascript_tool", ["tabId": tab, "action": "javascript_exec", "text": "document.cookie = 'sid=abc'"])

        let reply = await client.callTool("fetch", ["tabId": tab, "url": "/api", "responseType": "json"])

        XCTAssertFalse(reply.isError, reply.text)
        let result = try object(reply.text)
        XCTAssertEqual(result["status"] as? Int, 200)
        XCTAssertEqual((result["body"] as? [String: Any])?["cookie"] as? String, "sid=abc", "the page's cookie went along")
        XCTAssertFalse(reply.text.lowercased().contains("set-cookie"), reply.text)
        XCTAssertFalse(reply.text.contains("secret"), reply.text)
    }

    func testAPostWithTheUsersCookiesWaitsForTheUser() async throws {
        let server = try await makeServer()
        let tab = try await tab(on: server)
        let inAgentsProfile = await client.callTool("fetch", ["tabId": tab, "url": "/api", "method": "POST"])
        XCTAssertFalse(inAgentsProfile.isError, inAgentsProfile.text)
        XCTAssertTrue(control.pendingConsentAnswers.isEmpty, "the Agents profile holds none of the user's cookies")
        await switchToUserProfile()

        let post = Task { await client.callTool("fetch", ["tabId": tab, "url": "/api", "method": "POST"]) }
        let asked = await pollUntil { !self.control.pendingConsentAnswers.isEmpty }
        XCTAssertTrue(asked, "the user is asked")
        control.answerConsent(try XCTUnwrap(control.pendingConsentAnswers.keys.first), granted: false)
        let reply = await post.value

        XCTAssertTrue(reply.text.hasPrefix("[needs_user]"), reply.text)
        XCTAssertTrue(reply.text.contains("POST http://127.0.0.1:\(server.port)/api"), reply.text)
    }

    func testFetchSendsAScalarBodyAsJSON() async throws {
        let server = try await makeServer()
        let tab = try await tab(on: server)

        let number = await client.callTool("fetch", ["tabId": tab, "url": "/api", "method": "POST", "body": 5])
        let flag = await client.callTool("fetch", ["tabId": tab, "url": "/api", "method": "POST", "body": true])

        XCTAssertFalse(number.isError, number.text)
        XCTAssertFalse(flag.isError, flag.text)
    }

    func testFetchCutsTheBodyAtMaxBytes() async throws {
        let server = try await makeServer()
        let tab = try await tab(on: server)

        let reply = await client.callTool("fetch", ["tabId": tab, "url": "/big", "maxBytes": 100])

        let result = try object(reply.text)
        XCTAssertEqual(result["truncated"] as? Bool, true)
        XCTAssertEqual(result["bytes"] as? Int, 100)
        XCTAssertEqual((result["body"] as? String)?.count, 100)
    }

    func testFetchFollowsThePagesCORSRules() async throws {
        let server = try await makeServer()
        let other = try await makeServer()
        let tab = try await tab(on: server)

        let reply = await client.callTool("fetch", ["tabId": tab, "url": "http://127.0.0.1:\(other.port)/api"])

        XCTAssertTrue(reply.isError, "another origin without CORS headers refuses the page: \(reply.text)")
        XCTAssertTrue(reply.text.contains("CORS"), reply.text)
    }

    func testRunLoopsOverToolsInOneCall() async throws {
        let tab = try await agentTab(showing: "<p>run</p>")
        let code = """
            const out = []
            for (const n of [1, 2, 3]) {
              out.push(JSON.parse(await tool('javascript_tool', { action: 'javascript_exec', tabId: \(tab), text: `${n} * 2` })))
            }
            return out
            """

        let reply = await client.callTool("run", ["code": code])

        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertTrue(reply.text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "").hasPrefix("[2,4,6]"), reply.text)
        XCTAssertTrue(reply.text.hasSuffix("(3 tool calls)"), reply.text)
    }

    func testRunHandsToolErrorsToTheProgram() async throws {
        let reply = await client.callTool("run", ["code": "try { await tool('get_page_text', { tabId: 9999 }) } catch (e) { return 'caught: ' + e.message }"])

        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertTrue(reply.text.hasPrefix("caught: Tab 9999 not found"), reply.text)
    }

    func testRunStopsAtTheToolCallCap() async throws {
        let reply = await client.callTool("run", ["code": "for (let i = 0; i < 300; i++) await tool('list_connected_browsers')"])

        XCTAssertTrue(reply.isError)
        XCTAssertTrue(reply.text.contains("capped at 200"), reply.text)
        XCTAssertTrue(reply.text.contains("(201 tool calls)"), reply.text)
    }

    func testARunawayRunIsStoppedAndLiloKeepsAnswering() async throws {
        let reply = await client.callTool("run", ["code": "while (true) {}", "timeout": 1])
        let next = await client.callTool("list_connected_browsers")

        XCTAssertTrue(reply.isError)
        XCTAssertTrue(reply.text.contains("did not finish within 1 s"), reply.text)
        XCTAssertFalse(next.isError, next.text)
    }
}
