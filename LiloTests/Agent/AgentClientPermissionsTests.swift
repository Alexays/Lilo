import XCTest
@testable import Lilo

/// The decision table: global setting, global sites, sensitive action, the agent's choice and sites.
final class AgentClientPermissionTableTests: XCTestCase {
    private func asks(
        sensitive: Bool = false, site: String = "shop.example.com", globalAsks: Bool = true, globalSites: [String] = [],
        _ client: AgentClientPermission? = nil
    ) -> Bool {
        AgentClientPermission.asks(sensitive: sensitive, site: site, globalAsks: globalAsks, globalSites: globalSites, client: client)
    }

    func testAnUnknownClientGetsTheGlobalDefault() {
        XCTAssertTrue(asks())
        XCTAssertFalse(asks(globalAsks: false))
        XCTAssertFalse(asks(globalSites: ["example.com"]))
        XCTAssertTrue(asks(globalSites: ["other.test"]))
    }

    func testAskFirstAsksAsAnUnknownClientDoes() {
        XCTAssertTrue(asks(AgentClientPermission()))
        XCTAssertTrue(asks(AgentClientPermission(act: .ask, sites: ["example.com"])), "sites count only for On Chosen Sites")
    }

    func testEverywhereSkipsTheQuestionForOrdinaryActions() {
        XCTAssertFalse(asks(AgentClientPermission(act: .always)))
    }

    func testChosenSitesSkipTheQuestionThereAndOnTheirSubdomainsOnly() {
        let client = AgentClientPermission(act: .sites, sites: ["example.com"])
        XCTAssertFalse(asks(site: "example.com", client))
        XCTAssertFalse(asks(site: "shop.example.com", client))
        XCTAssertTrue(asks(site: "notexample.com", client))
        XCTAssertTrue(asks(site: "example.org", client))
    }

    func testASensitiveActionAlwaysAsksWhateverTheAgentMayDo() {
        XCTAssertTrue(asks(sensitive: true, AgentClientPermission(act: .always)))
        XCTAssertTrue(asks(sensitive: true, AgentClientPermission(act: .sites, sites: ["shop.example.com"])))
        XCTAssertTrue(asks(sensitive: true))
    }

    func testTheGlobalSettingAndSiteListDecideBeforeTheAgent() {
        XCTAssertFalse(asks(globalAsks: false, AgentClientPermission()))
        XCTAssertFalse(asks(sensitive: true, globalAsks: false, AgentClientPermission(act: .always)))
        XCTAssertFalse(asks(sensitive: true, globalSites: ["example.com"], AgentClientPermission()))
    }

    func testStoredPermissionsKeepOnlyWhatDiffersFromTheDefault() {
        let json = AgentClientPermission.encode([
            "codex": AgentClientPermission(act: .always), "claudeCode": AgentClientPermission(),
            "zed": AgentClientPermission(act: .sites, sites: ["example.com"])
        ])
        let stored = AgentClientPermission.decode(json)
        XCTAssertEqual(Set(stored.keys), ["codex", "zed"])
        XCTAssertEqual(stored["codex"]?.act, .always)
        XCTAssertEqual(stored["zed"], AgentClientPermission(act: .sites, sites: ["example.com"]))
    }

    /// No stored value, or one that does not parse, leaves every agent at the default.
    func testNoStoredValueOrAnUnreadableOneIsTheGlobalDefault() {
        XCTAssertEqual(AgentClientPermission.decode(nil), [:])
        XCTAssertEqual(AgentClientPermission.decode("not json"), [:])
        XCTAssertEqual(AgentClientPermission.decode(#"{"codex":{"act":"root"}}"#)["codex"], AgentClientPermission())
        XCTAssertEqual(AgentClientPermission.decode(#"{"codex":{"act":"sites","sites":["example.com"]}}"#)["codex"]?.act, .sites)
    }
}

@MainActor
final class AgentClientPermissionsTests: AgentToolTestCase {
    private static let page = """
    <!doctype html><title>Shop</title><body>
    <button onclick="document.title = 'sent'">Send</button>
    <button onclick="document.title = 'ordered'">Place order</button>
    <button onclick="document.title = 'deleted'">Delete</button>
    <form onsubmit="document.title = 'in'; return false"><input type="password"><button>Weiter</button></form>
    <form method="post" action="https://example.com/collect" target="_blank" onsubmit="return false"><input name="q"><button>Continue</button></form>
    </body>
    """

    private var server: TinyHTTPServer!

    override func setUp() async throws {
        try await super.setUp()
        server = try await TinyHTTPServer(index: Self.page)
    }

    override func tearDown() {
        server = nil
        super.tearDown()
    }

    private func shopTab(_ client: AgentTestClient? = nil) async throws -> Int {
        let client = client ?? self.client!
        let created = await client.callTool("tabs_create_mcp")
        let tab = try XCTUnwrap(created.text.split(separator: " ").last.flatMap { Int($0) })
        let reply = await client.callTool("navigate", ["tabId": tab, "url": "http://127.0.0.1:\(server.port)/"])
        XCTAssertFalse(reply.isError, reply.text)
        return tab
    }

    private func click(_ label: String, tab: Int, as client: AgentTestClient? = nil) async -> (text: String, isError: Bool, images: [Data], meta: [String: Any]) {
        let client = client ?? self.client!
        let found = await client.callTool("find", ["tabId": tab, "query": label])
        let ref = found.text.range(of: #"ref_\d+"#, options: .regularExpression).map { String(found.text[$0]) } ?? ""
        return await client.callTool("computer", ["tabId": tab, "action": "left_click", "ref": ref])
    }

    private func answerQuestion(_ granted: Bool) async throws {
        let asked = await pollUntil(timeout: 5) { !self.control.pendingConsentAnswers.isEmpty }
        XCTAssertTrue(asked, "the user is asked")
        control.answerConsent(try XCTUnwrap(control.pendingConsentAnswers.keys.first), granted: granted)
    }

    func testEverywhereSendsUnaskedButItsPeersAreAsked() async throws {
        control.setClientPermission("Test Agent", AgentClientPermission(act: .always))
        let tab = try await shopTab()

        let reply = await click("Send", tab: tab)

        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertTrue(control.pendingConsentAnswers.isEmpty, "not asked")

        let peer = try AgentTestClient(path: socketURL)
        _ = await peer.initialize(name: "Codex")
        let otherTab = try await shopTab(peer)
        let other = Task { await click("Send", tab: otherTab, as: peer) }
        try await answerQuestion(false)
        let refused = await other.value
        XCTAssertTrue(refused.text.hasPrefix("[needs_user]"), refused.text)
    }

    func testAChosenSiteSkipsTheQuestionForThatAgentOnly() async throws {
        control.setClientPermission("Test Agent", AgentClientPermission(act: .sites, sites: ["127.0.0.1"]))
        let tab = try await shopTab()

        let reply = await click("Send", tab: tab)

        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertTrue(control.pendingConsentAnswers.isEmpty)
        XCTAssertTrue(control.alwaysAllowedSites.isEmpty, "the grant is the agent's, not everyone's")
    }

    /// Buttons too, not only forms: an order or a delete button asks as a sign-in form or a post to another origin does.
    func testEverywhereNeverSkipsASensitiveAction() async throws {
        control.setClientPermission("Test Agent", AgentClientPermission(act: .always))
        let tab = try await shopTab()

        for label in ["Place order", "Delete", "Weiter", "Continue"] {
            let reply = Task { await click(label, tab: tab) }
            try await answerQuestion(false)
            let result = await reply.value
            XCTAssertTrue(result.text.hasPrefix("[needs_user]"), "\(label): \(result.text)")
            XCTAssertEqual(result.meta["lilo/consent"] as? String, "denied", label)
        }
    }

    func testAnAppsChoiceCoversTheAgentsItConnectsAs() async throws {
        control.setClientPermission("claudeCode", AgentClientPermission(act: .always))
        let claude = try AgentTestClient(path: socketURL)
        _ = await claude.initialize(name: "claude-code")
        let tab = try await shopTab(claude)

        let reply = await click("Send", tab: tab, as: claude)

        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertTrue(control.pendingConsentAnswers.isEmpty)

        control.revoke("claude-code")
        XCTAssertNil(control.clientPermissions["claudeCode"], "revoking the agent forgets its app's choice")
    }

    func testAlwaysNeverSkipsAClickOnAFrameOfAnotherOrigin() async throws {
        control.setClientPermission("Test Agent", AgentClientPermission(act: .always))
        let framed = try await TinyHTTPServer(index: "<!doctype html><button style='width:200px;height:60px'>Search</button>")
        let tab = try await agentTab(showing: """
            <!doctype html><body style="margin:0">
            <iframe title="Embedded search" src="http://localhost:\(framed.port)/" style="position:absolute;left:0;top:0;width:300px;height:100px;border:0"></iframe>
            </body>
            """)

        let reply = Task { await client.callTool("computer", ["tabId": tab, "action": "left_click", "coordinate": [50, 20]]) }
        try await answerQuestion(false)

        let result = await reply.value
        XCTAssertTrue(result.text.contains("Embedded search"), result.text)
    }

    func testRevokingAClientForgetsWhatItMayDoUnasked() async throws {
        control.setClientPermission("Test Agent", AgentClientPermission(act: .always, sites: ["example.com"]))

        control.revoke("Test Agent")

        XCTAssertNil(control.clientPermissions["Test Agent"])
    }

    func testWithoutPerAgentChoicesTheGlobalSettingDecides() async throws {
        XCTAssertTrue(control.clientPermissions.isEmpty)
        let tab = try await shopTab()
        let reply = Task { await click("Place order", tab: tab) }
        try await answerQuestion(true)
        let result = await reply.value
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.hasSuffix("(the user allowed it in Lilo)"), result.text)
    }
}
