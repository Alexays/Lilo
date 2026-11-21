import XCTest
@testable import Lilo

/// The decision table: global setting, global sites, structural hit, client default, client sites.
final class AgentClientPermissionTableTests: XCTestCase {
    private func asks(
        structural: Bool = false, site: String = "shop.example.com", globalAsks: Bool = true, globalSites: [String] = [],
        _ client: AgentClientPermission? = nil
    ) -> Bool {
        AgentClientPermission.asks(structural: structural, site: site, globalAsks: globalAsks, globalSites: globalSites, client: client)
    }

    func testAnUnknownClientGetsTheGlobalDefault() {
        XCTAssertTrue(asks())
        XCTAssertFalse(asks(globalAsks: false))
        XCTAssertFalse(asks(globalSites: ["example.com"]))
        XCTAssertTrue(asks(globalSites: ["other.test"]))
    }

    func testAClientAtTheDefaultAsksAsAnUnknownOneDoes() {
        XCTAssertTrue(asks(AgentClientPermission()))
        XCTAssertTrue(asks(AgentClientPermission(act: .ask, sites: ["other.test"])))
    }

    func testAlwaysSkipsTheQuestionForOrdinaryActions() {
        XCTAssertFalse(asks(AgentClientPermission(act: .always)))
    }

    func testAClientsSiteSkipsTheQuestionThereAndOnItsSubdomainsOnly() {
        let client = AgentClientPermission(sites: ["example.com"])
        XCTAssertFalse(asks(site: "example.com", client))
        XCTAssertFalse(asks(site: "shop.example.com", client))
        XCTAssertTrue(asks(site: "notexample.com", client))
        XCTAssertTrue(asks(site: "example.org", client))
    }

    func testAStructuralHitAlwaysAsksWhateverTheClientMayDo() {
        let always = AgentClientPermission(act: .always, sites: ["example.com"])
        XCTAssertTrue(asks(structural: true, site: "shop.example.com", always))
        XCTAssertTrue(asks(structural: true, AgentClientPermission(sites: ["shop.example.com"])))
        XCTAssertTrue(asks(structural: true))
    }

    func testTheGlobalSettingAndSiteListDecideBeforeTheClient() {
        XCTAssertFalse(asks(globalAsks: false, AgentClientPermission()))
        XCTAssertFalse(asks(structural: true, globalAsks: false, AgentClientPermission(act: .always)))
        XCTAssertFalse(asks(structural: true, globalSites: ["example.com"], AgentClientPermission()))
    }

    func testStoredPermissionsKeepOnlyWhatDiffersFromTheDefault() {
        let json = AgentClientPermission.encode([
            "Codex": AgentClientPermission(act: .always), "Claude Code": AgentClientPermission(),
            "Zed": AgentClientPermission(sites: ["example.com"])
        ])
        let stored = AgentClientPermission.decode(json)
        XCTAssertEqual(Set(stored.keys), ["Codex", "Zed"])
        XCTAssertEqual(stored["Codex"]?.act, .always)
        XCTAssertEqual(stored["Zed"]?.sites, ["example.com"])
    }

    /// Settings from before the per-client keys, and a value that does not parse, leave every client at the default.
    func testNoStoredValueOrAnUnreadableOneIsTheGlobalDefault() {
        XCTAssertEqual(AgentClientPermission.decode(nil), [:])
        XCTAssertEqual(AgentClientPermission.decode("not json"), [:])
        XCTAssertEqual(AgentClientPermission.decode(#"{"Codex":{"act":"root"}}"#)["Codex"], AgentClientPermission())
        XCTAssertEqual(AgentClientPermission.decode(#"{"Codex":{"act":"always"}}"#)["Codex"]?.act, .always)
    }
}

@MainActor
final class AgentClientPermissionsTests: AgentToolTestCase {
    private static let page = """
    <!doctype html><title>Shop</title><body>
    <button onclick="document.title = 'ordered'">Place order</button>
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

    func testAClientSetToAlwaysActsUnaskedOnAnOrderButItsPeersAreAsked() async throws {
        control.setClientPermission("Test Agent", AgentClientPermission(act: .always))
        let tab = try await shopTab()

        let reply = await click("Place order", tab: tab)

        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertTrue(control.pendingConsentAnswers.isEmpty, "not asked")

        let codex = try AgentTestClient(path: socketURL)
        _ = await codex.initialize(name: "Codex")
        let codexTab = try await shopTab(codex)
        let other = Task { await click("Place order", tab: codexTab, as: codex) }
        try await answerQuestion(false)
        let refused = await other.value
        XCTAssertTrue(refused.text.hasPrefix("[needs_user]"), refused.text)
    }

    func testAClientsSiteSkipsTheQuestionForThatClientOnly() async throws {
        control.setClientPermission("Test Agent", AgentClientPermission(sites: ["127.0.0.1"]))
        let tab = try await shopTab()

        let reply = await click("Place order", tab: tab)

        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertTrue(control.pendingConsentAnswers.isEmpty)
        XCTAssertTrue(control.alwaysAllowedSites.isEmpty, "the grant is the client's, not everyone's")
    }

    func testAlwaysNeverSkipsASignInFormAPostToAnotherOriginOrAFrameItCannotRead() async throws {
        control.setClientPermission("Test Agent", AgentClientPermission(act: .always, sites: ["127.0.0.1"]))
        let tab = try await shopTab()

        for label in ["Weiter", "Continue"] {
            let reply = Task { await click(label, tab: tab) }
            try await answerQuestion(false)
            let result = await reply.value
            XCTAssertTrue(result.text.hasPrefix("[needs_user]"), "\(label): \(result.text)")
            XCTAssertEqual(result.meta["lilo/consent"] as? String, "denied", label)
        }
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

    func testWithoutPerClientSettingsTheGlobalOnesDecideAsBefore() async throws {
        XCTAssertTrue(control.clientPermissions.isEmpty)
        let tab = try await shopTab()
        let reply = Task { await click("Place order", tab: tab) }
        try await answerQuestion(true)
        let result = await reply.value
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.hasSuffix("(the user allowed it in Lilo)"), result.text)
    }
}
