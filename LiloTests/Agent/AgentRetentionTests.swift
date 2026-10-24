import XCTest
import WebKit
@testable import Lilo

@MainActor
final class AgentRetentionTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var window: MainWindowController!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        window = makeTestWindow(context, showing: space.id)
        window.createTabStateFirst(url: URL(string: "https://example.com"))
    }

    override func tearDown() {
        window = nil
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    private func backgroundTab() throws -> (Tab, WKWebViewTab) {
        let tab = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "https://example.org"), activate: false))
        return (tab, try XCTUnwrap(window.tabManager.engineTab(for: tab.id)))
    }

    func testAgentTabIsProtectedFromDiscard() {
        var agent = Tab(id: UUID())
        agent.isAgentControlled = true
        let user = Tab(id: UUID())
        let coordinator = TabLifecycleCoordinator(policy: .background)

        let protected = coordinator.protectedEngineIds(tabs: [agent, user], availableEngineIds: [agent.id, user.id])
        let keep = coordinator.activeSpaceEnginesToKeep(
            tabs: [agent, user], availableEngineIds: [agent.id, user.id], activeTabId: nil,
            activationHistory: [], maxLiveEngines: 0
        )

        XCTAssertEqual(protected, [agent.id])
        XCTAssertEqual(keep, [agent.id])
    }

    func testAgentTabStaysAttachedWhenSwitchingAway() throws {
        let (_, agentEngine) = try backgroundTab()
        let (_, userEngine) = try backgroundTab()
        agentEngine.isAgentControlled = true
        window.contentContainerView.addSubview(agentEngine.view)
        window.contentContainerView.addSubview(userEngine.view)

        window.processOutgoingContentViews([agentEngine.view, userEngine.view])

        XCTAssertTrue(agentEngine.view.superview === window.contentContainerView)
        XCTAssertFalse(agentEngine.view.isHidden)
        XCTAssertNil(userEngine.view.superview)
    }
}
