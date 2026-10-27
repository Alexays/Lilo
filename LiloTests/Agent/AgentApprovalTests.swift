import XCTest
@testable import Lilo

@MainActor
final class AgentApprovalTests: AgentToolTestCase {
    private static let page = """
    <!doctype html><title>Shop</title><body>
    <button onclick="document.title = 'searched'">Search</button>
    <button onclick="document.title = 'ordered'">Place order</button>
    <form onsubmit="document.title = 'sent'; return false"><input id="message"><button>Envoyer</button></form>
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

    private func shopTab() async throws -> Int {
        let tab = try await newAgentTab()
        let reply = await client.callTool("navigate", ["tabId": tab, "url": "http://127.0.0.1:\(server.port)/"])
        XCTAssertFalse(reply.isError, reply.text)
        return tab
    }

    /// Clicks the button labelled `label` through its ref, as an agent does.
    private func click(_ label: String, tab: Int) async throws -> (text: String, isError: Bool, images: [Data], meta: [String: Any]) {
        let found = await client.callTool("find", ["tabId": tab, "query": label])
        let range = try XCTUnwrap(found.text.range(of: #"ref_\d+"#, options: .regularExpression), found.text)
        return await client.callTool("computer", ["tabId": tab, "action": "left_click", "ref": String(found.text[range])])
    }

    private func title(_ tab: Int) async throws -> String? {
        try await js("document.title", tab: tab) as? String
    }

    /// The question the drawers show for the agent's action, once it is asked.
    private func pendingQuestion() async throws -> String {
        let asked = await pollUntil(timeout: 5) { !self.control.pendingConsentAnswers.isEmpty }
        XCTAssertTrue(asked, "the user is asked")
        return try XCTUnwrap(control.pendingConsentAnswers.keys.first)
    }

    func testAnOrdinaryClickIsNotAsked() async throws {
        let tab = try await shopTab()

        let reply = try await click("Search", tab: tab)

        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertFalse(reply.text.contains("allowed"), reply.text)
        XCTAssertTrue(control.pendingConsentAnswers.isEmpty)
        let searched = await pollUntil(timeout: 5) { (try? await self.title(tab)) == "searched" }
        XCTAssertTrue(searched)
    }

    func testAnOrderWaitsForTheUsersAllow() async throws {
        let tab = try await shopTab()

        let reply = Task { try await click("Place order", tab: tab) }
        control.answerConsent(try await pendingQuestion(), granted: true)

        let result = try await reply.value
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.hasPrefix(#"Clicked button "Place order""#), result.text)
        XCTAssertTrue(result.text.hasSuffix("(the user allowed it in Lilo)"), result.text)
        let ordered = await pollUntil(timeout: 5) { (try? await self.title(tab)) == "ordered" }
        XCTAssertTrue(ordered)
    }

    func testADeniedOrderNeedsTheUserAndDoesNothing() async throws {
        let tab = try await shopTab()

        let reply = Task { try await click("Place order", tab: tab) }
        control.answerConsent(try await pendingQuestion(), granted: false)

        let result = try await reply.value
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.hasPrefix("[needs_user]"), result.text)
        XCTAssertTrue(result.text.contains("Place order"), result.text)
        let title = try await title(tab)
        XCTAssertEqual(title, "Shop")
    }

    func testPostingButtonsAreAsked() async throws {
        let tab = try await agentTab(showing: """
            <!doctype html><body><div role="button">Tout poster</div><button>Post all</button><button>Reply</button><button>Répondre</button></body>
            """)
        for label in ["Tout poster", "Post all", "Reply", "Répondre"] {
            let reply = Task { try await click(label, tab: tab) }
            control.answerConsent(try await pendingQuestion(), granted: false)

            let result = try await reply.value
            XCTAssertTrue(result.text.hasPrefix("[needs_user]"), "\(label): \(result.text)")
        }
    }

    func testEnterInAFormThatSendsIsAsked() async throws {
        let tab = try await shopTab()
        _ = try await js("document.getElementById('message').focus(); 1", tab: tab)

        let reply = Task { await client.callTool("computer", ["tabId": tab, "action": "key", "text": "Return"]) }
        control.answerConsent(try await pendingQuestion(), granted: false)

        let result = await reply.value
        XCTAssertTrue(result.text.contains("Envoyer"), result.text)
    }

    func testEnterInAFramedPaymentFormIsAsked() async throws {
        let tab = try await agentTab(showing: """
            <!doctype html><body><iframe srcdoc="<form onsubmit='return false'><input id='card'><button>Pay now</button></form>"></iframe></body>
            """)
        await pollUntil { (try? await self.js("!!document.querySelector('iframe').contentDocument?.getElementById('card')", tab: tab)) as? Bool == true }
        _ = try await js("document.querySelector('iframe').contentDocument.getElementById('card').focus(); 1", tab: tab)

        let reply = Task { await client.callTool("computer", ["tabId": tab, "action": "key", "text": "Return"]) }
        control.answerConsent(try await pendingQuestion(), granted: false)

        let result = await reply.value
        XCTAssertTrue(result.text.hasPrefix("[needs_user]"), result.text)
        XCTAssertTrue(result.text.contains("Pay now"), result.text)
    }

    func testAClickByCoordinateOnAFramedOrderButtonIsAsked() async throws {
        // Scrolled, nested and bordered: the point is followed through both frames to the button.
        let inner = "<body style=&quot;margin:0&quot;><button style=&quot;width:200px;height:60px&quot;>Place order</button></body>"
        let tab = try await agentTab(showing: """
            <!doctype html><body style="margin:0;height:3000px">
            <iframe style="position:absolute;left:20px;top:900px;width:400px;height:200px;border:7px solid;padding:3px"
              srcdoc="<body style='margin:0'><iframe style='margin-left:30px;border:2px solid;width:300px;height:100px' srcdoc='\(inner)'></iframe></body>"></iframe>
            </body>
            """)
        await pollUntil {
            (try? await self.js("!!document.querySelector('iframe').contentDocument?.querySelector('iframe')?.contentDocument?.querySelector('button')", tab: tab)) as? Bool == true
        }
        _ = try await js("scrollTo(0, 800); 1", tab: tab)

        // The button's center: 20 + 7 + 3 + 30 + 2 + 100 across, 900 - 800 + 7 + 3 + 2 + 30 down.
        let reply = Task { await client.callTool("computer", ["tabId": tab, "action": "left_click", "coordinate": [162, 142]]) }
        control.answerConsent(try await pendingQuestion(), granted: false)

        let result = await reply.value
        XCTAssertTrue(result.text.hasPrefix("[needs_user]"), result.text)
        XCTAssertTrue(result.text.contains("Place order"), result.text)
    }

    func testAClickOnAFrameOfAnotherOriginIsAsked() async throws {
        let framed = try await TinyHTTPServer(index: "<!doctype html><button style='width:200px;height:60px'>Search</button>")
        let tab = try await agentTab(showing: """
            <!doctype html><body style="margin:0">
            <iframe title="Embedded search" src="http://localhost:\(framed.port)/" style="position:absolute;left:0;top:0;width:300px;height:100px;border:0"></iframe>
            </body>
            """)

        let reply = Task { await client.callTool("computer", ["tabId": tab, "action": "left_click", "coordinate": [50, 20]]) }
        control.answerConsent(try await pendingQuestion(), granted: false)

        let result = await reply.value
        XCTAssertTrue(result.text.contains("Embedded search"), result.text)
    }

    func testAlwaysAllowedSitesSkipTheQuestionUntilForgotten() async throws {
        let tab = try await shopTab()
        let first = Task { try await click("Place order", tab: tab) }
        control.answerConsent(try await pendingQuestion(), granted: true, alwaysAllowSite: "127.0.0.1")
        _ = try await first.value

        let second = try await click("Place order", tab: tab)

        XCTAssertFalse(second.isError, second.text)
        XCTAssertTrue(control.pendingConsentAnswers.isEmpty, "not asked again")
        XCTAssertEqual(control.alwaysAllowedSites, ["127.0.0.1"])

        context.settingsStore.set(AgentControl.alwaysAllowedSitesKey, value: "[]")
        let third = Task { try await click("Place order", tab: tab) }
        control.answerConsent(try await pendingQuestion(), granted: false)
        _ = try await third.value
    }

    func testTurnedOffNothingIsAsked() async throws {
        context.settingsStore.set(AgentControl.asksBeforeActionsKey, value: "false")
        let tab = try await shopTab()

        let reply = try await click("Place order", tab: tab)

        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertTrue(control.pendingConsentAnswers.isEmpty)
    }
}
