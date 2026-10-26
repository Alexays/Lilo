import XCTest
import WebKit
@testable import Lilo

/// A Lilo window showing a space, agent control on a private socket, and one connected MCP client.
@MainActor
class AgentToolTestCase: XCTestCase {
    /// The clients the tests connect as, allowed for this process as the user allowing each once would.
    static var allowedClientsJSON: String {
        let identity = AgentControl.clientIdentity(peer: getpid()).identity
        return #"{"Test Agent": ["\#(identity)"], "Codex": ["\#(identity)"], "claude-code": ["\#(identity)"]}"#
    }

    var browserContext: TemporaryBrowserContext!
    var window: MainWindowController!
    var control: AgentControl!
    var client: AgentTestClient!
    var space: Space!
    // sun_path holds 104 bytes: the test temporary directory is too deep for it.
    let socketURL = URL(fileURLWithPath: "/tmp/lilo-agent-\(UUID().uuidString.prefix(8)).sock")

    var context: BrowserContext { browserContext.context }
    /// The app's settle times, for a test of the settling itself: the others settle in a fraction of them.
    let productSettle = AgentTools.settleQuiet

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        let profileId = try context.profileManager.createProfile(name: "P").id
        space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        window = MainWindowController(context: context)
        window.bridgeRouter = BridgeRouter(chromeWebView: window.chromeWebView)
        // Transparent, off screen and never key: nothing shows to whoever runs the tests, and their
        // keyboard stays theirs. A titled window ordered in is pulled on screen, so it moves out after.
        let nsWindow = try XCTUnwrap(window.window)
        nsWindow.alphaValue = 0
        nsWindow.orderFrontRegardless()
        nsWindow.setFrame(NSRect(x: -20000, y: -20000, width: 1000, height: 700), display: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 650))
        try XCTUnwrap(nsWindow.contentView).addSubview(container)
        window.contentContainerView = container
        context.windows.add(window)
        window.switchToSpace(space.id)
        window.createTabStateFirst(url: URL(string: "about:blank"))
        context.settingsStore.set("agentAllowedClients", value: Self.allowedClientsJSON)
        // A disconnect ends the session at once, as when no bridge reconnects.
        AgentControl.reconnectGrace = .zero
        AgentTools.settleQuiet = (dom: .milliseconds(20), network: .milliseconds(50))
        control = AgentControl(context: context, socketURL: socketURL)
        control.setEnabled(true)
        client = try AgentTestClient(path: socketURL)
        _ = await client.initialize(name: "Test Agent")
    }

    override func tearDown() {
        AgentTools.settleQuiet = productSettle
        client = nil
        control.setEnabled(false)
        // A real close: leaving the registry, its space and its event monitors lets the window go.
        window.window?.close()
        control = nil
        window = nil
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    /// Creates an agent tab and returns its number.
    func newAgentTab() async throws -> Int {
        let reply = await client.callTool("tabs_create_mcp")
        XCTAssertFalse(reply.isError, reply.text)
        return try XCTUnwrap(reply.text.split(separator: " ").last.flatMap { Int($0) })
    }

    /// Creates an agent tab showing `html`, and returns its number.
    func agentTab(showing html: String) async throws -> Int {
        let tabId = try await newAgentTab()
        let encoded = try XCTUnwrap(html.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let reply = await client.callTool("navigate", ["tabId": tabId, "url": "data:text/html;charset=utf-8,\(encoded)"])
        XCTAssertFalse(reply.isError, reply.text)
        return tabId
    }

    func engine(forTab number: Int) throws -> WKWebViewTab {
        let id = try XCTUnwrap(control.tabNumbers.first { $0.value == number }?.key)
        return try XCTUnwrap(window.tabManager.engineTab(for: id)
            ?? context.browserState.owningSpaceId(forTab: id).flatMap { context.browserState.engine(tabId: id, spaceId: $0) })
    }

    /// The Agents space of the agents' own profile, where agents work by default, once the first one opened a tab.
    var agentsSpaceId: UUID? {
        context.settingsStore.get(AgentControl.agentsProfileKey).flatMap(UUID.init(uuidString:)).flatMap { control.agentsSpace(in: $0)?.id }
    }

    /// Switches `client` to the user's profile P, allowing it as the user would.
    @discardableResult
    func switchToUserProfile(_ client: AgentTestClient? = nil) async -> (text: String, isError: Bool, images: [Data]) {
        let client = client ?? self.client!
        let switching = Task { await client.callTool("switch_profile", ["profile": "P"]) }
        await pollUntil(timeout: 5) { !self.control.pendingConsentAnswers.isEmpty }
        if let request = control.pendingConsentAnswers.keys.first { control.answerConsent(request, granted: true) }
        return await switching.value
    }

    func js(_ script: String, tab: Int) async throws -> Any? {
        try await engine(forTab: tab).wkWebView.evaluateJavaScript(script)
    }

    func availableTabs(_ client: AgentTestClient? = nil) async throws -> [[String: Any]] {
        let reply = await (client ?? self.client).callTool("tabs_context_mcp")
        let object = try JSONSerialization.jsonObject(with: Data(reply.text.utf8)) as? [String: Any]
        return object?["availableTabs"] as? [[String: Any]] ?? []
    }
}
