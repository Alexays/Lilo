import XCTest
@testable import Lilo

@MainActor
final class AgentIsolationTests: AgentToolTestCase {
    /// A tab of a private space of the user's showing `marker`, and the number an agent would call it by.
    private func privateTab(showing marker: String) async throws -> (tab: Tab, number: Int) {
        let privateSpace = try context.spaceManager.createSpace(name: "Private", profileId: space.profileId, isPrivate: true)
        window.switchToSpace(privateSpace.id)
        let encoded = try XCTUnwrap("<p>\(marker)</p>".addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let tab = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "data:text/html,\(encoded)")))
        return (tab, control.number(for: tab.id))
    }

    func testNoToolReachesAPrivateTab() async throws {
        _ = try await newAgentTab()
        let (_, number) = try await privateTab(showing: "private-marker")
        let calls: [(String, [String: Any])] = [
            ("read_page", [:]), ("get_page_text", [:]), ("find", ["query": "private"]),
            ("javascript_tool", ["action": "javascript_exec", "text": "document.body.innerText"]),
            ("computer", ["action": "screenshot"]), ("cookies", ["action": "get"]), ("read_network_requests", [:]),
            ("read_console_messages", [:]), ("devtools_command", ["method": "Runtime.evaluate"]), ("fetch", ["url": "/"]),
            ("navigate", ["url": "https://example.com"])
        ]

        for (name, arguments) in calls {
            let reply = await client.callTool(name, arguments.merging(["tabId": number]) { $1 })
            XCTAssertTrue(reply.isError, "\(name) reached the private tab: \(reply.text)")
            XCTAssertFalse(reply.text.contains("private-marker"), name)
        }
        let run = await client.callTool("run", ["code": "return await tool('get_page_text', { tabId: \(number) })"])
        XCTAssertTrue(run.isError, run.text)
        let listed = try await availableTabs()
        XCTAssertFalse(listed.contains { $0["tabId"] as? Int == number }, "tabs_context leaves it out")
    }

    func testAPrivateTabMovedIntoTheAgentsFolderStaysOffLimits() async throws {
        let agentTab = try await newAgentTab()
        let (tab, number) = try await privateTab(showing: "private-marker")
        let privateSpaceId = try XCTUnwrap(context.browserState.owningSpaceId(forTab: tab.id))
        let agentsSpace = try XCTUnwrap(agentsSpaceId)
        let folderId = try XCTUnwrap(control.sessions.first { $0.isAuthorized }?.folderId)
        _ = try window.applyBrowserCommand(.moveTabToSpace(tabId: tab.id, sourceSpaceId: privateSpaceId, targetSpaceId: agentsSpace, allowsPinnedTabs: false))
        _ = try window.applyBrowserCommand(.moveSidebarItem(
            spaceId: agentsSpace, kind: .tab, itemId: tab.id, parentFolderId: folderId, section: .unpinned, insert: .index(1)
        ))

        let reply = await client.callTool("get_page_text", ["tabId": number])

        XCTAssertTrue(reply.text.contains("is a private tab"), reply.text)
        XCTAssertFalse(reply.text.contains("private-marker"), reply.text)
        let own = await client.callTool("get_page_text", ["tabId": agentTab])
        XCTAssertFalse(own.isError, own.text)
    }

    func testEightAgentsWorkAtOnceEachInItsOwnGroup() async throws {
        let server = try await TinyHTTPServer { request in
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            return ("200 OK", ["Content-Type: text/html"], Data("<!doctype html><title>Page</title><main>page \(path)</main>".utf8))
        }
        let names = ["Test Agent", "Codex", "claude-code"]
        var agents: [AgentTestClient] = []
        for index in 0..<8 {
            let agent = try AgentTestClient(path: socketURL)
            _ = await agent.initialize(name: names[index % names.count])
            agents.append(agent)
        }

        let results = await withTaskGroup(of: (Int, String, Int).self) { group in
            for (index, agent) in agents.enumerated() {
                group.addTask {
                    let created = await agent.callTool("tabs_create_mcp", ["title": "Agent \(index)"])
                    let tab = created.text.split(separator: " ").last.flatMap { Int($0) } ?? -1
                    for step in 0..<3 {
                        _ = await agent.callTool("navigate", ["tabId": tab, "url": "http://127.0.0.1:\(server.port)/agent\(index)-\(step)"])
                    }
                    let text = await agent.callTool("get_page_text", ["tabId": tab]).text
                    let context = await agent.callTool("tabs_context_mcp").text
                    let listed = ((try? JSONSerialization.jsonObject(with: Data(context.utf8))) as? [String: Any])?["availableTabs"] as? [Any]
                    return (index, text, listed?.count ?? 0)
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(results.count, 8)
        for (index, text, count) in results {
            XCTAssertTrue(text.contains("page /agent\(index)-2"), "agent \(index) sees its own last page: \(text)")
            XCTAssertEqual(count, 1, "agent \(index) sees its own tab only")
        }
        let folders = context.browserState.structuralProjection(forSpace: try XCTUnwrap(agentsSpaceId))?.folders ?? []
        XCTAssertEqual(folders.count, 8, "one group each")
    }
}
