import XCTest
import WebKit
@testable import Lilo

@MainActor
final class AgentFoldersTests: AgentToolTestCase {
    private func tabId(of number: Int) throws -> UUID {
        try XCTUnwrap(control.tabNumbers.first { $0.value == number }?.key)
    }

    private func folderName(of client: AgentTestClient) async throws -> String {
        let reply = await client.callTool("tabs_context_mcp")
        let object = try JSONSerialization.jsonObject(with: Data(reply.text.utf8)) as? [String: Any]
        let id = try XCTUnwrap((object?["tabGroupId"] as? String).flatMap(UUID.init(uuidString:)), reply.text)
        return try XCTUnwrap(context.browserState.structuralProjection(forSpace: XCTUnwrap(agentsSpaceId))?.folders.first { $0.id == id }?.name)
    }

    func testEachConversationGetsItsOwnFolder() async throws {
        let first = try AgentTestClient(path: socketURL)
        _ = await first.initialize(name: "Codex")
        let second = try AgentTestClient(path: socketURL)
        _ = await second.initialize(name: "Codex")
        _ = await first.callTool("tabs_create_mcp")
        _ = await second.callTool("tabs_create_mcp")

        let firstTabs = try await availableTabs(first)
        let secondTabs = try await availableTabs(second)

        XCTAssertEqual(firstTabs.count, 1)
        XCTAssertEqual(secondTabs.count, 1)
        XCTAssertNotEqual(firstTabs.first?["tabId"] as? Int, secondTabs.first?["tabId"] as? Int, "neither sees the other's tabs")
    }

    func testTabsStayTheAgentsWhileNoWindowIsOpen() async throws {
        let tab = try await newAgentTab()
        let engine = try engine(forTab: tab)

        context.windows.remove(window)
        control.refreshControlledTabs()
        context.windows.add(window)

        XCTAssertTrue(engine.isAgentControlled)
        XCTAssertNotNil(control.captures[try XCTUnwrap(control.tabNumbers.first { $0.value == tab }?.key)])
    }

    func testFolderIsNamedAfterTheTask() async throws {
        _ = await client.callTool("tabs_create_mcp", ["title": "Signup flow"])

        let name = try await folderName(of: client)

        XCTAssertEqual(name, "Signup flow")
    }

    func testFolderIsNamedAfterTheProjectWithoutATitle() async throws {
        let agent = try AgentTestClient(path: socketURL)
        agent.roots = ["file:///Users/me/Projects/lilo"]
        _ = await agent.initialize(name: "claude-code")
        _ = await agent.callTool("tabs_create_mcp")

        let name = try await folderName(of: agent)

        XCTAssertEqual(name, "Claude Code - lilo")
    }

    func testFolderNameFallsBackToTheClientAndTime() async throws {
        let agent = try AgentTestClient(path: socketURL)
        _ = await agent.initialize(name: "claude-code")
        _ = await agent.callTool("tabs_create_mcp")

        let name = try await folderName(of: agent)

        XCTAssertTrue(name.hasPrefix("Claude Code - "), name)
    }

    func testAgentsSpaceStartsCleanEachRun() async throws {
        _ = try await newAgentTab()
        client.close()
        control.setEnabled(false)
        let relaunched = AgentControl(context: context, socketURL: socketURL)
        relaunched.setEnabled(true)
        defer { relaunched.setEnabled(false) }
        let agent = try AgentTestClient(path: socketURL)
        _ = await agent.initialize()

        _ = await agent.callTool("tabs_create_mcp")

        let folders = context.browserState.structuralProjection(forSpace: try XCTUnwrap(agentsSpaceId))?.folders ?? []
        XCTAssertEqual(folders.count, 1, "the last run's folder is gone")
    }

    func testResetWipesTheAgentsProfileAndNeverTheUsers() async throws {
        let server = try await TinyHTTPServer(index: "<!doctype html><p>site</p>")
        let site = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/"))
        let userTab = try XCTUnwrap(window.createTabStateFirst(url: site, activate: false))
        let userEngine = try XCTUnwrap(window.tabManager.engineTab(for: userTab.id))
        await pollUntil(timeout: 5) { !userEngine.isLoading && userEngine.currentURL != nil }
        _ = try await userEngine.wkWebView.evaluateJavaScript("localStorage.setItem('mine', 'keep'); 1")
        let number = try await newAgentTab()
        _ = await client.callTool("navigate", ["tabId": number, "url": site.absoluteString])
        _ = await client.callTool("javascript_tool", ["tabId": number, "action": "javascript_exec", "text": "localStorage.setItem('agent', 'x')"])
        let agentStore = context.profileManager.dataStore(for: try control.agentsProfileId()).backingStore
        // The page's write reaches the store on its own: one still on its way would land after the wipe.
        let written = await pollUntil { await !agentStore.dataRecords(ofTypes: [WKWebsiteDataTypeLocalStorage]).isEmpty }
        XCTAssertTrue(written)

        let reply = await client.callTool("reset_profile")

        XCTAssertFalse(reply.isError, reply.text)
        // The reset reloads the agent's tab, which fills the caches again.
        let left = await agentStore.dataRecords(
            ofTypes: WKWebsiteDataStore.testDataTypes.subtracting([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache])
        )
        let userRecords = await context.profileManager.dataStore(for: space.profileId).backingStore.dataRecords(ofTypes: WKWebsiteDataStore.testDataTypes)
        XCTAssertEqual(left.map(\.displayName), [])
        XCTAssertFalse(userRecords.isEmpty, "the user's profile is never reset")
    }

    func testResetWaitsForOtherAgentsInTheAgentsProfile() async throws {
        let other = try AgentTestClient(path: socketURL)
        _ = await other.initialize(name: "Codex")
        _ = await other.callTool("tabs_create_mcp")

        let reset = await client.callTool("reset_profile")

        XCTAssertTrue(reset.text.contains("Another agent is working"), reset.text)
        XCTAssertTrue(reset.text.contains("Codex"), "the refusal names the folder in the way")
        await switchToUserProfile(other)
        let alone = await client.callTool("reset_profile")
        XCTAssertFalse(alone.isError, "an agent in another profile holds none of it: \(alone.text)")
    }

    func testResetWaitsForTheOtherAgentToCloseItsTabs() async throws {
        let other = try AgentTestClient(path: socketURL)
        _ = await other.initialize(name: "Codex")
        let created = await other.callTool("tabs_create_mcp")
        let otherTab = try XCTUnwrap(created.text.split(separator: " ").last.flatMap { Int($0) })

        let reset = Task { [client] in await client!.callTool("reset_profile", ["wait": 10]) }
        try await Task.sleep(for: .milliseconds(500))
        _ = await other.callTool("tabs_close_mcp", ["tabId": otherTab])
        let reply = await reset.value

        XCTAssertFalse(reply.isError, reply.text)
    }

    func testAnAgentWhoseFolderTheUserDeletedDoesNotHoldTheProfile() async throws {
        let other = try AgentTestClient(path: socketURL)
        _ = await other.initialize(name: "Codex")
        _ = await other.callTool("tabs_create_mcp")
        let spaceId = try XCTUnwrap(agentsSpaceId)
        for folder in context.browserState.structuralProjection(forSpace: spaceId)?.folders ?? [] {
            _ = try window.applyBrowserCommand(.deleteFolderWithTabs(spaceId: spaceId, folderId: folder.id))
        }

        let reset = await client.callTool("reset_profile")

        XCTAssertFalse(reset.isError, reset.text)
    }

    func testTheFirstAgentOfARunClosesBlankTabsLeftInTheAgentsSpace() async throws {
        _ = try await newAgentTab()
        let spaceId = try XCTUnwrap(agentsSpaceId)
        let blank = Tab(spaceId: spaceId)
        _ = try window.applyBrowserCommand(.createTab(spaceId: spaceId, tab: blank, activate: false))
        control.cleanedAgentsSpaceIds = []

        _ = await client.callTool("tabs_context_mcp")

        XCTAssertFalse(isOpen(blank.id, in: spaceId))
    }

    func testAnIdleAgentDoesNotHoldTheProfile() async throws {
        let other = try AgentTestClient(path: socketURL)
        _ = await other.initialize(name: "Codex")

        let reset = await client.callTool("reset_profile")

        XCTAssertFalse(reset.isError, reset.text)
    }

    func testResetRefusedInAUserProfile() async throws {
        _ = try await newAgentTab()
        await switchToUserProfile()

        let reply = await client.callTool("reset_profile")

        XCTAssertTrue(reply.isError)
        XCTAssertTrue(reply.text.contains("never reset"), reply.text)
    }

    func testTabsCreatedInBackground() async throws {
        let activeBefore = window.tabManager.activeTabId

        let number = try await newAgentTab()

        XCTAssertEqual(window.tabManager.activeTabId, activeBefore, "the user's tab stays the shown one")
        XCTAssertTrue(try engine(forTab: number).isAgentControlled)
        XCTAssertTrue(try engine(forTab: number).view.window === control.parkingWindow, "rendering off screen, in no window of the user's")
        XCTAssertEqual(control.parkingWindow.title, "Agent Tabs".localized, "VoiceOver names the window")
    }

    func testClosedTabReportsNotFound() async throws {
        let number = try await newAgentTab()
        _ = try window.applyBrowserCommand(.closeTab(spaceId: try XCTUnwrap(agentsSpaceId), tabId: try tabId(of: number)))

        let reply = await client.callTool("navigate", ["tabId": number, "url": "about:blank"])

        XCTAssertTrue(reply.isError)
        XCTAssertTrue(reply.text.contains("not found"), reply.text)
    }

    func testHandedTabJoinsFolder() async throws {
        _ = try await newAgentTab()
        let agentsSpace = try XCTUnwrap(agentsSpaceId)
        let folderId = try XCTUnwrap(control.agentFolder(for: XCTUnwrap(control.sessions.first), create: false).folderId)
        let userTab = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "about:blank"), activate: false))
        _ = try window.applyBrowserCommand(.moveTabToSpace(tabId: userTab.id, sourceSpaceId: space.id, targetSpaceId: agentsSpace, allowsPinnedTabs: false))
        _ = try window.applyBrowserCommand(.moveSidebarItem(
            spaceId: agentsSpace, kind: .tab, itemId: userTab.id, parentFolderId: folderId, section: .unpinned, insert: .index(1)
        ))

        let tabs = try await availableTabs()

        XCTAssertEqual(tabs.count, 2, "a tab moved into the agent's folder is handed to it")
    }

    func testNavigateLoadsLocalDevServerOverHTTP() async throws {
        let number = try await newAgentTab()

        _ = await client.callTool("navigate", ["tabId": number, "url": "localhost:9"])

        XCTAssertEqual(try engine(forTab: number).currentURL?.scheme, "http")
    }

    func testReleaseOfAHiddenAgentSpaceClearsAgentState() async throws {
        let number = try await newAgentTab()
        let engine = try engine(forTab: number)
        let other = try context.spaceManager.createSpace(name: "Other", profileId: space.profileId)
        window.switchToSpace(other.id)

        client.close()
        await pollUntil(timeout: 5) { self.control.sessions.isEmpty }

        XCTAssertFalse(engine.isAgentControlled)
        XCTAssertNil(engine.agentDialogHandler, "the user's own use of the tab gets its dialogs back")
    }

    func testReleasedViewStopsRenderingUnderTheShownTab() async throws {
        let number = try await newAgentTab()
        let engine = try engine(forTab: number)
        XCTAssertNotNil(engine.view.superview)

        client.close()
        await pollUntil(timeout: 5) { !engine.isAgentControlled }

        XCTAssertFalse(engine.isAgentControlled, "a folder nobody drives goes back to normal lifecycle")
        XCTAssertNil(engine.view.superview)
    }

    func testTabMovedOutOfFolderIsNoLongerVisibleAndShowsItsOwnDialogs() async throws {
        let number = try await newAgentTab()
        let engine = try engine(forTab: number)
        _ = try window.applyBrowserCommand(.moveSidebarItem(
            spaceId: try XCTUnwrap(agentsSpaceId), kind: .tab, itemId: try tabId(of: number), parentFolderId: nil, section: .unpinned, insert: .index(0)
        ))

        XCTAssertNil(engine.agentDialogHandler, "a tab no agent drives answers no dialog by itself")
        XCTAssertFalse(engine.isAgentControlled)
        let tabs = try await availableTabs()
        XCTAssertTrue(tabs.isEmpty)
    }

    func testAFolderTheUserMovesToTheirSpaceFillsTheWindowAgainWithoutAnAgentCall() async throws {
        let number = try await newAgentTab()
        await switchToUserProfile()
        _ = await client.callTool("resize_window", ["tabId": number, "width": 2000, "height": 400])
        let engine = try engine(forTab: number)
        let agentsSpace = try XCTUnwrap(context.browserState.owningSpaceId(forTab: tabId(of: number)))
        let folderId = try XCTUnwrap(control.agentFolder(for: XCTUnwrap(control.sessions.first), create: false).folderId)
        window.switchToSpace(agentsSpace)

        try window.moveToSpace(.folder, id: folderId, targetSpaceId: space.id)
        XCTAssertTrue(engine === (try self.engine(forTab: number)), "the page moves with its engine within its profile")
        window.switchToSpace(space.id)
        window.activateTabStateFirst(id: try tabId(of: number))

        XCTAssertFalse(engine.isAgentControlled)
        XCTAssertNil(engine.agentViewport)
        XCTAssertEqual(engine.view.frame, window.contentContainerView.bounds, "the page keeps the agent's viewport and runs past the window")
    }

    func testAgentLeavesAViewShownInAnotherWindowWhereItIs() async throws {
        let number = try await newAgentTab()
        let engine = try engine(forTab: number)
        let other = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        other.contentView?.addSubview(engine.view)

        _ = await client.callTool("read_page", ["tabId": number])

        XCTAssertTrue(engine.view.window === other)
    }

    func testNewTabsAndPopupsFromAnAgentTabStayInItsFolderInTheBackground() async throws {
        let number = try await agentTab(showing: """
            <!doctype html><body style="margin:0">
            <a href="about:blank#tab" target="_blank" style="position:absolute;left:20px;top:20px;width:200px;height:40px;display:block">Tab</a>
            <button style="position:absolute;left:20px;top:100px;width:200px;height:40px" onclick="window.open('about:blank#popup', 'p', 'width=300,height=200')">Popup</button>
            </body>
            """)
        let activeBefore = window.tabManager.activeTabId

        _ = await client.callTool("computer", ["tabId": number, "action": "left_click", "coordinate": [120, 40]])
        _ = await client.callTool("computer", ["tabId": number, "action": "left_click", "coordinate": [120, 120]])
        // Both opened once the folder holds them: a wrong placement would have happened by then too.
        let opened = await pollUntil(timeout: 10) { (try? await self.availableTabs().count) == 3 }

        XCTAssertTrue(opened, "the link and the popup open as tabs of the agent's folder")
        XCTAssertEqual(window.tabManager.activeTabId, activeBefore, "the user's tab stays the shown one")
        XCTAssertTrue(window.pagePopups.isEmpty, "no popup window opens over the user's")
    }

    func testAgentTabCannotPullItsWindowForward() async throws {
        let number = try await newAgentTab()
        let activeBefore = window.tabManager.activeTabId

        window.tabRequestsForeground(try engine(forTab: number))

        XCTAssertEqual(window.tabManager.activeTabId, activeBefore)
    }

    func testAgentWorksAtFullRateWhileTheUserStaysInTheirSpace() async throws {
        let number = try await agentTab(showing: "<title>Kept</title><button onclick='clicks++'>B</button><script>window.clicks = 0</script>")

        let text = await client.callTool("get_page_text", ["tabId": number])
        let visibility = await client.callTool("javascript_tool", ["tabId": number, "action": "javascript_exec", "text": "document.visibilityState"])
        let animating = await client.callTool("javascript_tool", [
            "tabId": number, "action": "javascript_exec", "text": "await new Promise(r => requestAnimationFrame(() => r(true)))"
        ])

        XCTAssertEqual(window.tabManager.currentSpaceId, space.id, "the user never left their space")
        XCTAssertTrue(text.text.contains("Kept"), text.text)
        XCTAssertEqual(visibility.text, "\"visible\"", "not throttled as a hidden page")
        XCTAssertEqual(animating.text, "true", "animation frames still run")
    }

    func testATabUnderTheShownTabRunsAtFullRate() async throws {
        let number = try await newAgentTab()
        window.switchToSpace(try XCTUnwrap(agentsSpaceId))

        let visibility = await client.callTool("javascript_tool", ["tabId": number, "action": "javascript_exec", "text": "document.visibilityState"])

        XCTAssertTrue(try engine(forTab: number).view.superview === window.contentContainerView)
        XCTAssertEqual(visibility.text, "\"visible\"", "an occluded window must not throttle what the agent measures")
    }

    func testTabTheUserPicksInTheAgentsSpaceShowsAboveTheOthers() async throws {
        let first = try tabId(of: try await newAgentTab())
        let second = try tabId(of: try await newAgentTab())
        window.switchToSpace(try XCTUnwrap(agentsSpaceId))
        window.activateTabStateFirst(id: first)
        window.activateTabStateFirst(id: second)

        window.activateTabStateFirst(id: first)

        let shown = try XCTUnwrap(window.tabManager.engineTab(for: first)).view
        XCTAssertTrue(window.contentContainerView.subviews.last === shown, "the other agent tab stays rendered, under it")
    }

    func testABridgeThatReconnectsKeepsItsTabsAndTheirSettings() async throws {
        AgentControl.reconnectGrace = .seconds(10)
        let number = try await newAgentTab()
        _ = await client.callTool("resize_window", ["tabId": number, "width": 500, "height": 400])
        client.close()
        await pollUntil(timeout: 5) { self.control.sessions.first?.connection.isClosed == true }

        let again = try AgentTestClient(path: socketURL)
        defer { again.close() }
        _ = await again.initialize(name: "Test Agent")

        let tabs = try await availableTabs(again)
        XCTAssertEqual(tabs.map { $0["tabId"] as? Int }, [number])
        XCTAssertEqual(try engine(forTab: number).agentViewport, NSSize(width: 500, height: 400))
        XCTAssertEqual(control.sessions.count, 1, "the dropped session gave way to the new one")
    }

    func testAnAgentRelaunchedThroughANewLauncherKeepsItsTabs() async throws {
        AgentControl.reconnectGrace = .seconds(10)
        let number = try await newAgentTab()
        let dropped = try XCTUnwrap(control.sessions.first)
        XCTAssertFalse(dropped.identity.isEmpty, "the test client is signed")
        // Claude Desktop starts lilo-mcp through a `disclaimer` launcher: a new one, with a new pid, each time.
        dropped.clientPID = 99_999
        client.close()
        await pollUntil(timeout: 5) { dropped.connection.isClosed }

        let again = try AgentTestClient(path: socketURL)
        defer { again.close() }
        _ = await again.initialize(name: "Test Agent")

        let tabs = try await availableTabs(again)
        XCTAssertEqual(tabs.map { $0["tabId"] as? Int }, [number])
        XCTAssertEqual(control.sessions.count, 1, "the dropped session gave way to the new one")
    }

    func testAnotherLiveConversationOfTheSameAgentKeepsToItsOwnTabs() async throws {
        AgentControl.reconnectGrace = .seconds(10)
        _ = try await newAgentTab()
        let first = try XCTUnwrap(control.sessions.first)
        // Another Claude Code conversation: the same signed app, in a process of its own that still runs.
        first.clientPID = 1
        client.close()
        await pollUntil(timeout: 5) { first.connection.isClosed }

        let other = try AgentTestClient(path: socketURL)
        defer { other.close() }
        _ = await other.initialize(name: "Test Agent")

        let context = await other.callTool("tabs_context_mcp", [:])
        XCTAssertTrue(context.text.contains("No tab group exists yet"), context.text)
    }

    func testAgentConnectingAgainBeforeItsOldConnectionClosesKeepsItsTabs() async throws {
        AgentControl.reconnectGrace = .seconds(10)
        let number = try await newAgentTab()
        let again = try AgentTestClient(path: socketURL)
        defer { again.close() }
        _ = await again.initialize(name: "Test Agent")

        client.close()
        await pollUntil(timeout: 5) { self.control.sessions.count == 1 }

        let tabs = try await availableTabs(again)
        XCTAssertEqual(tabs.map { $0["tabId"] as? Int }, [number])
    }

    func testTabClosedWithItsConversationSaysWhy() async throws {
        let number = try await newAgentTab()
        client.close()
        await pollUntil(timeout: 5) { self.control.sessions.isEmpty }
        let again = try AgentTestClient(path: socketURL)
        defer { again.close() }
        _ = await again.initialize(name: "Test Agent")

        let reply = await again.callTool("navigate", ["tabId": number, "url": "about:blank"])

        XCTAssertTrue(reply.isError)
        XCTAssertTrue(reply.text.contains("closed with the conversation"), reply.text)
    }

    func testTwoAgentsWorkInDifferentProfilesAtOnce() async throws {
        let mine = try await agentTab(showing: "<title>Mine</title>")
        let other = try AgentTestClient(path: socketURL)
        _ = await other.initialize(name: "Codex")
        await switchToUserProfile(other)
        let created = await other.callTool("tabs_create_mcp")
        let theirs = try XCTUnwrap(created.text.split(separator: " ").last.flatMap { Int($0) })

        let mineSpace = try XCTUnwrap(context.browserState.owningSpaceId(forTab: try tabId(of: mine)).flatMap(context.spaceManager.space(with:)))
        let theirSpace = try XCTUnwrap(context.browserState.owningSpaceId(forTab: try tabId(of: theirs)).flatMap(context.spaceManager.space(with:)))
        XCTAssertEqual(mineSpace.profileId, try control.agentsProfileId())
        XCTAssertEqual(theirSpace.profileId, space.profileId)
        XCTAssertNotEqual(theirSpace.id, space.id, "never in the user's own space")
        XCTAssertEqual(Set(context.settingsStore.agentsSpaceIds), [mineSpace.id, theirSpace.id])
        let text = await client.callTool("get_page_text", ["tabId": mine])
        XCTAssertFalse(text.isError, "the other agent's switch left this one alone: \(text.text)")
        XCTAssertTrue(text.text.contains("Mine"), text.text)
    }

    func testSwitchingProfileMovesOnlyTheCallersFolder() async throws {
        let mine = try await agentTab(showing: "<title>Mine</title>")
        let other = try AgentTestClient(path: socketURL)
        _ = await other.initialize(name: "Codex")
        let created = await other.callTool("tabs_create_mcp")
        let theirs = try XCTUnwrap(created.text.split(separator: " ").last.flatMap { Int($0) })
        let theirEngine = try engine(forTab: theirs)

        let reply = await switchToUserProfile()

        XCTAssertFalse(reply.isError, reply.text)
        let moved = try XCTUnwrap(context.browserState.owningSpaceId(forTab: try tabId(of: mine)).flatMap(context.spaceManager.space(with:)))
        XCTAssertEqual(moved.profileId, space.profileId)
        XCTAssertEqual(context.browserState.owningSpaceId(forTab: try tabId(of: theirs)), agentsSpaceId, "the other agent's tab stays")
        XCTAssertTrue(try engine(forTab: theirs) === theirEngine, "and keeps its page")
        let text = await client.callTool("get_page_text", ["tabId": mine])
        XCTAssertFalse(text.isError, "the tab came back in the new profile: \(text.text)")
        let theirText = await other.callTool("get_page_text", ["tabId": theirs])
        XCTAssertFalse(theirText.isError, theirText.text)
    }

    func testDeletingAProfileSendsItsAgentsBackToTheAgentsProfile() async throws {
        let number = try await newAgentTab()
        await switchToUserProfile()
        let userAgentsSpace = try XCTUnwrap(context.browserState.owningSpaceId(forTab: try tabId(of: number)))

        try control.returnAgents(from: try XCTUnwrap(context.spaceManager.space(with: userAgentsSpace)))

        XCTAssertNil(context.spaceManager.space(with: userAgentsSpace))
        XCTAssertEqual(context.browserState.owningSpaceId(forTab: try tabId(of: number)), agentsSpaceId)
        let list = await client.callTool("list_profiles")
        let profiles = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(list.text.utf8)) as? [[String: Any]])
        XCTAssertEqual(profiles.first { $0["current"] as? Bool == true }?["ephemeral"] as? Bool, true)
    }

    func testATabWhoseEngineWasReplacedStaysTheAgents() async throws {
        let number = try await newAgentTab()
        let id = try tabId(of: number)
        window.switchToSpace(try XCTUnwrap(agentsSpaceId))
        window.tabManager.discardEngines([id])

        _ = await client.callTool("navigate", ["tabId": number, "url": "data:text/html,<p>back</p>"])

        XCTAssertTrue(try engine(forTab: number).isAgentControlled, "the new engine keeps the agent's lifecycle and dialogs")
    }

    func testAgentsWorkInTheirOwnSpaceAndEphemeralProfile() async throws {
        let id = try tabId(of: try await newAgentTab())

        let agentsSpace = try XCTUnwrap(context.spaceManager.space(with: agentsSpaceId))
        XCTAssertEqual(context.browserState.owningSpaceId(forTab: id), agentsSpace.id)
        XCTAssertNotEqual(agentsSpace.id, space.id, "never in the user's space")
        XCTAssertEqual(agentsSpace.profileId, try control.agentsProfileId())
        XCTAssertNotEqual(agentsSpace.profileId, space.profileId, "none of the user's sign-ins by default")
    }

    func testListProfilesSaysWhichTheAgentsAndTheUserUse() async throws {
        _ = try await newAgentTab()

        let reply = await client.callTool("list_profiles")

        let profiles = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(reply.text.utf8)) as? [[String: Any]])
        let agents = try XCTUnwrap(profiles.first { $0["ephemeral"] as? Bool == true })
        let user = try XCTUnwrap(profiles.first { $0["id"] as? String == space.profileId.uuidString })
        XCTAssertEqual(agents["current"] as? Bool, true)
        XCTAssertEqual(user["usedByUser"] as? Bool, true)
        XCTAssertEqual(user["current"] as? Bool, false)
    }

    func testSwitchingToAUserProfileAsksOnceThenMovesTheTabs() async throws {
        let number = try await agentTab(showing: "<title>Moved</title>")
        let userProfile = try XCTUnwrap(context.profileManager.profiles.first { $0.id == space.profileId })

        let switching = Task { [client] in await client!.callTool("switch_profile", ["profile": userProfile.name]) }
        await pollUntil(timeout: 5) { !self.control.pendingConsentAnswers.isEmpty }
        control.answerConsent(try XCTUnwrap(control.pendingConsentAnswers.keys.first), granted: true)
        let reply = await switching.value

        XCTAssertFalse(reply.isError, reply.text)
        let moved = context.browserState.owningSpaceId(forTab: try tabId(of: number)).flatMap(context.spaceManager.space(with:))
        XCTAssertEqual(moved?.profileId, userProfile.id)
        let text = await client.callTool("get_page_text", ["tabId": number])
        XCTAssertFalse(text.isError, "the tab came back in the new profile: \(text.text)")

        _ = await client.callTool("switch_profile", ["profile": "Agents"])
        let again = await client.callTool("switch_profile", ["profile": userProfile.name])
        XCTAssertFalse(again.isError, again.text)
        XCTAssertTrue(control.pendingConsentAnswers.isEmpty, "asked once per profile")
    }

    func testLastAgentLeavingWipesTheAgentsProfile() async throws {
        let server = try await TinyHTTPServer(index: "<!doctype html><p>site</p>")
        let number = try await newAgentTab()
        _ = await client.callTool("navigate", ["tabId": number, "url": "127.0.0.1:\(server.port)/"])
        _ = await client.callTool("javascript_tool", ["tabId": number, "action": "javascript_exec", "text": "localStorage.setItem('left', 'behind'); document.cookie = 'k=v; max-age=3600'"])
        let store = context.profileManager.dataStore(for: try control.agentsProfileId())
        // The page's writes reach the store on their own time: a write landing after the wipe would outlive it.
        let written = await pollUntil(timeout: 10) {
            let types = await store.backingStore.dataRecords(ofTypes: WKWebsiteDataStore.testDataTypes).reduce(into: Set<String>()) { $0.formUnion($1.dataTypes) }
            return types.isSuperset(of: [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeCookies])
        }
        XCTAssertTrue(written)
        let idle = try AgentTestClient(path: socketURL)
        _ = await idle.initialize(name: "Codex")

        client.close()

        // WebKit takes up to 9 s to remove a profile's data on a loaded runner.
        var left: [WKWebsiteDataRecord] = []
        let wiped = await pollUntil {
            left = await store.backingStore.dataRecords(ofTypes: WKWebsiteDataStore.testDataTypes)
            return left.isEmpty
        }
        XCTAssertTrue(wiped, "nothing an agent left reaches the next one: \(left.map { "\($0.displayName) \($0.dataTypes.sorted())" })")
    }

    func testTheWipeLeavesAUserProfilesAgentsSpaceAlone() async throws {
        let server = try await TinyHTTPServer(index: "<!doctype html><p>site</p>")
        let number = try await newAgentTab()
        await switchToUserProfile()
        _ = await client.callTool("navigate", ["tabId": number, "url": "127.0.0.1:\(server.port)/"])
        _ = await client.callTool("javascript_tool", ["tabId": number, "action": "javascript_exec", "text": "localStorage.setItem('mine', 'keep')"])
        let userStore = context.profileManager.dataStore(for: space.profileId).backingStore
        let written = await pollUntil { await !userStore.dataRecords(ofTypes: [WKWebsiteDataTypeLocalStorage]).isEmpty }
        XCTAssertTrue(written)
        let userAgentsSpace = try XCTUnwrap(context.browserState.owningSpaceId(forTab: try tabId(of: number)))

        let wiped = await control.wipeAgentsProfile()

        XCTAssertTrue(wiped, "an agent in a user profile does not hold the agents' one")
        XCTAssertNotNil(context.spaceManager.space(with: userAgentsSpace))
        XCTAssertEqual(context.browserState.owningSpaceId(forTab: try tabId(of: number)), userAgentsSpace)
        let left = await userStore.dataRecords(ofTypes: [WKWebsiteDataTypeLocalStorage])
        XCTAssertFalse(left.isEmpty, "the user's profile is never wiped")
    }

    func testAgentActionsRecordTheTabActedOn() async throws {
        let number = try await newAgentTab()
        let session = try XCTUnwrap(control.sessions.first)

        _ = await client.callTool("get_page_text", ["tabId": number])

        XCTAssertNotNil(session.actedOn[try tabId(of: number)], "the activity dot follows the tab the agent works on")
        XCTAssertEqual(session.activeCalls, 0)
    }

    func testIsolatedTabsShareNoCookieAndLeaveWithTheAgent() async throws {
        let server = try await TinyHTTPServer(index: "<!doctype html><p>site</p>")
        let url = "127.0.0.1:\(server.port)/"
        let normal = try await newAgentTab()
        _ = await client.callTool("navigate", ["tabId": normal, "url": url])
        _ = await client.callTool("javascript_tool", ["tabId": normal, "action": "javascript_exec", "text": "document.cookie = 'who=agent; max-age=600'"])
        let created = await client.callTool("tabs_create_mcp", ["isolated": true])
        let isolated = try XCTUnwrap(created.text.split(separator: " ").last.flatMap { Int($0) }, created.text)
        _ = await client.callTool("navigate", ["tabId": isolated, "url": url])

        let cookie = await client.callTool("javascript_tool", ["tabId": isolated, "action": "javascript_exec", "text": "document.cookie"])
        let listed = try await availableTabs()
        let isolatedSpace = try XCTUnwrap(context.spaceManager.spaces.first { $0.isPrivate })
        let isPrivate = try engine(forTab: isolated).isPrivateBrowsing
        client.close()
        await pollUntil(timeout: 5) { self.context.spaceManager.space(with: isolatedSpace.id) == nil }

        XCTAssertEqual(cookie.text, #""""#)
        XCTAssertTrue(isPrivate)
        XCTAssertEqual(listed.first { $0["tabId"] as? Int == isolated }?["isolated"] as? Bool, true)
        XCTAssertNil(listed.first { $0["tabId"] as? Int == normal }?["isolated"])
        XCTAssertNil(context.spaceManager.space(with: isolatedSpace.id), "the private space goes with the agent")
    }

    func testClosingTheLastIsolatedTabDropsItsSpace() async throws {
        let first = await client.callTool("tabs_create_mcp", ["isolated": true])
        let second = await client.callTool("tabs_create_mcp", ["isolated": true])
        let tabIds = try [first, second].map { try XCTUnwrap($0.text.split(separator: " ").last.flatMap { Int($0) }, $0.text) }
        for tabId in tabIds { _ = await client.callTool("navigate", ["tabId": tabId, "url": "data:text/html,<p>page</p>"]) }
        let isolatedSpace = try XCTUnwrap(context.spaceManager.spaces.first { $0.isPrivate })

        _ = await client.callTool("tabs_close_mcp", ["tabId": tabIds[0]])
        let keptWithATab = context.spaceManager.space(with: isolatedSpace.id) != nil
        let closed = await client.callTool("tabs_close_mcp", ["tabId": tabIds[1]])

        XCTAssertFalse(closed.isError, closed.text)
        XCTAssertTrue(keptWithATab, "the space stays while one of its tabs is open")
        XCTAssertNil(context.spaceManager.space(with: isolatedSpace.id), "an empty private space goes at once")
    }

    func testAgentLeavingGivesSleepBack() async throws {
        _ = try await newAgentTab()
        XCTAssertFalse(context.powerKeeper.state.working.isEmpty, "a tool call holds the Mac awake")

        client.close()
        await pollUntil(timeout: 5) { self.control.sessions.isEmpty }

        XCTAssertTrue(context.powerKeeper.state.working.isEmpty, "not for the quiet limit after the agent left")
    }

    func testAgentsSpaceStaysLastAfterANewSpace() async throws {
        _ = try await newAgentTab()
        let id = try XCTUnwrap(agentsSpaceId)

        _ = try context.spaceManager.createSpace(name: "Later", profileId: space.profileId)
        let other = try XCTUnwrap(context.spaceManager.spaces.first { $0.id != id && !$0.isPrivate })
        try context.spaceManager.moveSpace(id: other.id, toIndex: .max)

        XCTAssertEqual(context.spaceManager.spaces.last { !$0.isPrivate }?.id, id)
    }

    private func disconnect() async throws {
        client.close()
        await pollUntil(timeout: 5) { self.control.sessions.isEmpty }
    }

    private func isOpen(_ id: UUID, in spaceId: UUID) -> Bool {
        context.browserState.structuralProjection(forSpace: spaceId)?.tabs.contains { $0.id == id && !$0.isClosed } ?? false
    }

    func testAgentLeavingClosesItsTabs() async throws {
        let id = try tabId(of: try await newAgentTab())
        let spaceId = try XCTUnwrap(agentsSpaceId)

        try await disconnect()

        XCTAssertFalse(isOpen(id, in: spaceId))
        XCTAssertNil(context.browserState.engine(tabId: id, spaceId: spaceId))
        XCTAssertTrue(context.browserState.structuralProjection(forSpace: spaceId)?.folders.isEmpty ?? true)
    }

    func testAgentLeavingKeepsTheTabsTheUserWatches() async throws {
        let id = try tabId(of: try await newAgentTab())
        let spaceId = try XCTUnwrap(agentsSpaceId)
        window.switchToSpace(spaceId)

        try await disconnect()

        XCTAssertTrue(isOpen(id, in: spaceId))
    }

    func testClosingTheLastAgentTabLeavesTheAgentsSpace() async throws {
        let id = try tabId(of: try await newAgentTab())
        let spaceId = try XCTUnwrap(agentsSpaceId)
        window.switchToSpace(spaceId)

        window.closeTabStateFirst(id: id, undoable: false)

        XCTAssertFalse(isOpen(id, in: spaceId))
        XCTAssertFalse(context.browserState.structuralProjection(forSpace: spaceId)?.tabs.contains { !$0.isClosed } ?? false, "no blank tab left behind")
        XCTAssertNotEqual(window.tabManager.currentSpaceId, spaceId)
        XCTAssertNotNil(context.spaceManager.space(with: spaceId), "hidden, not deleted: it keeps its profile")
    }

    func testFaviconLoadedWhileTheSpaceIsHiddenShowsOnceTheWindowShowsIt() async throws {
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="))
        let server = try await TinyHTTPServer { request in
            request.hasPrefix("GET /icon.png ")
                ? ("200 OK", ["Content-Type: image/png"], png)
                : ("200 OK", ["Content-Type: text/html"], Data(#"<!doctype html><link rel="icon" href="/icon.png"><p>page</p>"#.utf8))
        }
        let tab = try await newAgentTab()
        let id = try tabId(of: tab)
        let spaceId = try XCTUnwrap(agentsSpaceId)
        // The chrome already got the space's tabs once: its later full states of it leave out the favicons it holds.
        window.switchToSpace(spaceId)
        window.switchToSpace(space.id)

        _ = await client.callTool("navigate", ["tabId": tab, "url": "http://localhost:\(server.port)/"])
        let loaded = await pollUntil { self.context.browserState.durableTab(for: id)?.tab.faviconDataURL != nil }
        XCTAssertTrue(loaded)
        let recorder = BridgeEventRecorder(window.bridgeRouter)
        window.switchToSpace(spaceId)

        let sent = await pollUntil { recorder.events.contains { $0.name == "browserStateChanged" } }
        XCTAssertTrue(sent)
        let states = recorder.events.filter { $0.name == "browserStateChanged" }.flatMap { $0.data["states"] as? [[String: Any]] ?? [] }
        let shipped = states.first { $0["spaceId"] as? String == spaceId.uuidString }?["tabs"] as? [[String: Any]]
        let favicon = shipped?.first { $0["id"] as? String == id.uuidString }?["faviconDataURL"] as? String
        XCTAssertEqual(favicon, context.browserState.durableTab(for: id)?.tab.faviconDataURL)
    }
}
