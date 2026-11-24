import UserNotifications
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
        XCTAssertEqual(result.meta["lilo/consent"] as? String, "denied")
        let title = try await title(tab)
        XCTAssertEqual(title, "Shop")
    }

    /// A second window on a space of its own, with a tab of its own: it holds no page of the agent.
    private func otherWindow() throws -> MainWindowController {
        let profileId = space.profileId
        let other = MainWindowController(context: context)
        let nsWindow = try XCTUnwrap(other.window)
        nsWindow.alphaValue = 0
        nsWindow.orderFrontRegardless()
        nsWindow.setFrame(NSRect(x: -20000, y: -20000, width: 1000, height: 700), display: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 650))
        try XCTUnwrap(nsWindow.contentView).addSubview(container)
        other.contentContainerView = container
        context.windows.add(other)
        other.switchToSpace(try context.spaceManager!.createSpace(name: "Other", profileId: profileId).id)
        other.createTabStateFirst(url: URL(string: "about:blank"))
        addTeardownBlock { @MainActor in nsWindow.close() }
        return other
    }

    func testAnActionQuestionIsShownOnlyInTheWindowHoldingTheAgentsTab() async throws {
        let other = try otherWindow()
        let here = BridgeEventRecorder(window.bridgeRouter)
        let there = BridgeEventRecorder(other.bridgeRouter)
        let tab = try await shopTab()

        let reply = Task { try await click("Place order", tab: tab) }
        let requestId = try await pendingQuestion()

        let holder = try XCTUnwrap(context.windows.window(forTab: try XCTUnwrap(control.pendingConsentAnswers[requestId]?.tabId)))
        let (asked, free, freeWindow) = holder === window ? (here, there, other) : (there, here, window!)
        await pollUntil(timeout: 5) { asked.events.contains { $0.name == "agentControlRequested" } }
        XCTAssertEqual(asked.events.filter { $0.name == "agentControlRequested" }.count, 1)
        XCTAssertTrue(free.events.filter { $0.name == "agentControlRequested" }.isEmpty, "the other window's drawer stays free")

        let handler = SettingsBridgeHandler(
            settingsStore: context.settingsStore!, sitePermissionStoreProvider: { nil }, zoomStoreProvider: { nil },
            historyStoreProvider: { nil }, extensionRegistryProvider: { nil }, dataStoreProvider: { nil }, context: context,
            bridgeRouter: freeWindow.bridgeRouter
        )
        _ = await handler.handle(message: try XCTUnwrap(BridgeMessage(dictionary: ["action": "getAgentActivity", "payload": [:]])))
        await pollUntil(timeout: 1) { free.events.contains { $0.name == "agentControlRequested" } }
        XCTAssertTrue(free.events.filter { $0.name == "agentControlRequested" }.isEmpty, "a reloaded window does not get another window's question")

        control.answerConsent(requestId, granted: true)
        let result = try await reply.value
        XCTAssertFalse(result.isError, result.text)
    }

    func testAConversationsRowTurnsAmberWhileItsAgentsQuestionWaits() async throws {
        let folder = TabFolder(spaceId: space.id, name: "Conversation", color: "#795ceb")
        let conversation = Tab(title: "Conversation", spaceId: space.id, kind: .agent, cwd: NSTemporaryDirectory(), agentId: "test-agent")
        _ = try window.applyBrowserCommand(.createFolder(spaceId: space.id, folder: folder, section: .unpinned))
        _ = try window.applyBrowserCommand(.createTab(spaceId: space.id, tab: conversation, activate: false))
        _ = try window.applyBrowserCommand(.moveSidebarItem(
            spaceId: space.id, kind: .tab, itemId: conversation.id, parentFolderId: folder.id, section: .unpinned, insert: .index(0)
        ))
        context.conversations.register(conversation, folderId: folder.id)
        let session = try XCTUnwrap(control.sessions.first)
        session.conversationSpaceId = space.id
        session.conversationTabId = conversation.id
        session.folders[nil] = folder.id
        let listed = await client.callTool("tabs_context_mcp", ["createIfEmpty": true])
        let tabs = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(listed.text.utf8)) as? [String: Any])
        let tab = try XCTUnwrap((tabs["availableTabs"] as? [[String: Any]])?.first?["tabId"] as? Int, listed.text)
        let navigated = await client.callTool("navigate", ["tabId": tab, "url": "http://127.0.0.1:\(server.port)/"])
        XCTAssertFalse(navigated.isError, navigated.text)
        func awaiting() -> Date? { window.updateRuntimeTab(id: conversation.id) { _ in }?.awaitingInputSince }
        XCTAssertNil(awaiting())

        let reply = Task { try await click("Place order", tab: tab) }
        let requestId = try await pendingQuestion()

        XCTAssertNotNil(awaiting(), "the row turns amber like for an agent's permission")
        control.answerConsent(requestId, granted: false)
        _ = try await reply.value
        XCTAssertNil(awaiting(), "and back once answered")
    }

    /// The question nobody answers is withdrawn, and the agent is told so rather than that the user said no.
    func testAnUnansweredOrderExpiresAndSaysSo() async throws {
        AgentControl.actionConsentTimeout = 0.3
        defer { AgentControl.actionConsentTimeout = 45 }
        let tab = try await shopTab()

        let reply = Task { try await click("Place order", tab: tab) }
        let asked = await pollUntil(timeout: 5) { !self.control.pendingConsentAnswers.isEmpty }
        XCTAssertTrue(asked, "the user is asked")
        let withdrawn = await pollUntil(timeout: 5) { self.control.pendingConsentAnswers.isEmpty }
        XCTAssertTrue(withdrawn, "the question is withdrawn unanswered")

        let result = try await reply.value
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.hasPrefix("[needs_user]"), result.text)
        XCTAssertTrue(result.text.contains("did not answer"), result.text)
        XCTAssertEqual(result.meta["lilo/consent"] as? String, "expired")
        let title = try await title(tab)
        XCTAssertEqual(title, "Shop")
    }

    /// An expired question does not count as an answer: the next call asks again.
    func testAnExpiredOrderIsAskedAgainAtTheNextCall() async throws {
        AgentControl.actionConsentTimeout = 0.3
        defer { AgentControl.actionConsentTimeout = 45 }
        let tab = try await shopTab()

        let first = Task { try await click("Place order", tab: tab) }
        let asked = await pollUntil(timeout: 5) { !self.control.pendingConsentAnswers.isEmpty }
        XCTAssertTrue(asked)
        let withdrawn = await pollUntil(timeout: 5) { self.control.pendingConsentAnswers.isEmpty }
        XCTAssertTrue(withdrawn)
        _ = try await first.value

        let second = Task { try await click("Place order", tab: tab) }
        control.answerConsent(try await pendingQuestion(), granted: false)
        let result = try await second.value
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.meta["lilo/consent"] as? String, "denied")
    }

    /// Records the consent notifications a question posts while no window can ask; `allowed` is
    /// whether the user lets Lilo post notifications.
    private final class PostedNotifications {
        var requests: [UNNotificationRequest] = []
    }

    private func recordNotifications(allowed: Bool = true) -> PostedNotifications {
        let posted = PostedNotifications()
        let post = AgentControl.postConsentNotification
        AgentControl.postConsentNotification = { posted.requests.append($0); return allowed }
        addTeardownBlock { @MainActor in AgentControl.postConsentNotification = post }
        return posted
    }

    /// With no window to ask in, the question waits in a notification; its tap opens a window at it
    /// and the answer there resolves it. No tool call gets this far without a window, so the gate
    /// itself is asked directly.
    func testAnOrderWithNoWindowWaitsInANotification() async throws {
        let posted = recordNotifications()
        let tab = try await shopTab()
        let engine = try engine(forTab: tab)
        let session = try XCTUnwrap(control.sessions.first)
        context.windows.remove(window)
        defer { context.windows.add(window) }

        let approval = Task { try await control.approveConsequentialAction("click", label: "Place order", frame: nil, engine: engine, session: session) }
        let asked = await pollUntil(timeout: 5) { !self.control.pendingConsentAnswers.isEmpty }
        XCTAssertTrue(asked, "the question holds rather than failing")
        let requestId = try XCTUnwrap(control.pendingConsentAnswers.keys.first)
        let notification = try XCTUnwrap(posted.requests.first)
        XCTAssertEqual(notification.identifier, AgentControl.consentNotificationId(requestId))
        XCTAssertEqual(notification.content.userInfo["agentConsentRequestId"] as? String, requestId)
        XCTAssertEqual(notification.content.title, AgentControl.displayName(session.clientName))
        let shown = notification.content.title + notification.content.body
        XCTAssertFalse(shown.contains("Place order"), "the page's labels stay off the lock screen: \(shown)")

        // The notification's tap: a window opens at the held question, which its drawer asks again.
        control.revealConsent(requestId: requestId)
        let answerer = try XCTUnwrap(context.windows.windows.first { $0 !== window })
        addTeardownBlock { @MainActor in answerer.window?.close() }
        control.answerConsent(requestId, granted: true)

        let released = try await approval.value
        XCTAssertTrue(released, "the user's answer releases the held call")
    }

    /// A background host's window is hidden from the user: its question waits in a notification too,
    /// and the tap brings the window back to ask it.
    func testAnOrderInTheBackgroundWaitsInANotification() async throws {
        let posted = recordNotifications()
        let tab = try await shopTab()
        let engine = try engine(forTab: tab)
        let session = try XCTUnwrap(control.sessions.first)
        let hidden = try XCTUnwrap(window.window)
        Headless.enter(concealing: hidden)
        addTeardownBlock { @MainActor in Headless.leave(revealing: [hidden]) }

        let approval = Task { try await control.approveConsequentialAction("click", label: "Place order", frame: nil, engine: engine, session: session) }
        let asked = await pollUntil(timeout: 5) { !self.control.pendingConsentAnswers.isEmpty }
        XCTAssertTrue(asked, "the question holds rather than going to a window nobody sees")
        let requestId = try XCTUnwrap(control.pendingConsentAnswers.keys.first)
        let notification = try XCTUnwrap(posted.requests.first)
        XCTAssertEqual(notification.identifier, AgentControl.consentNotificationId(requestId))

        control.revealConsent(requestId: requestId)
        XCTAssertFalse(Headless.isOn, "the tap leaves the background")
        XCTAssertEqual(hidden.alphaValue, 1)
        XCTAssertFalse(hidden.ignoresMouseEvents)
        control.answerConsent(requestId, granted: true)

        let released = try await approval.value
        XCTAssertTrue(released, "the user's answer releases the held call")
    }

    /// A question nobody answers expires in a notification as it does in a drawer.
    func testAQuestionHeldInANotificationStillExpires() async throws {
        _ = recordNotifications()
        AgentControl.actionConsentTimeout = 0.3
        defer { AgentControl.actionConsentTimeout = 45 }
        let tab = try await shopTab()
        let engine = try engine(forTab: tab)
        let session = try XCTUnwrap(control.sessions.first)
        context.windows.remove(window)
        defer { context.windows.add(window) }

        do {
            _ = try await control.approveConsequentialAction("click", label: "Place order", frame: nil, engine: engine, session: session)
            XCTFail("the order needs the user")
        } catch let error as AgentToolError {
            XCTAssertEqual(error.code, "needs_user")
            XCTAssertEqual(error.consent, .expired)
        }
        XCTAssertTrue(control.pendingConsentAnswers.isEmpty, "the question is withdrawn")
    }

    /// With no window and notifications off, nothing can ask: the agent is told so at once, not after the wait.
    func testAnOrderWithNoWindowAndNotificationsOffSaysSo() async throws {
        _ = recordNotifications(allowed: false)
        let tab = try await shopTab()
        let engine = try engine(forTab: tab)
        let session = try XCTUnwrap(control.sessions.first)
        context.windows.remove(window)
        defer { context.windows.add(window) }

        let started = Date()
        do {
            _ = try await control.approveConsequentialAction("click", label: "Place order", frame: nil, engine: engine, session: session)
            XCTFail("the order needs the user")
        } catch let error as AgentToolError {
            XCTAssertEqual(error.code, "needs_user")
            XCTAssertEqual(error.consent, .unavailable)
            XCTAssertTrue(error.message.contains("notifications are off"), error.message)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "without the wait")
        XCTAssertTrue(control.pendingConsentAnswers.isEmpty, "nothing was asked")
    }

    /// A call the client cancelled withdraws its question from the drawers.
    func testACancelledOrderWithdrawsItsQuestion() async throws {
        let tab = try await shopTab()
        let found = await client.callTool("find", ["tabId": tab, "query": "Place order"])
        let range = try XCTUnwrap(found.text.range(of: #"ref_\d+"#, options: .regularExpression), found.text)
        let recorder = BridgeEventRecorder(window.bridgeRouter)
        client.send(["jsonrpc": "2.0", "id": 999, "method": "tools/call",
                     "params": ["name": "computer", "arguments": ["tabId": tab, "action": "left_click", "ref": String(found.text[range])]]])
        let asked = await pollUntil(timeout: 5) { !self.control.pendingConsentAnswers.isEmpty }
        XCTAssertTrue(asked, "the user is asked")

        client.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 999]])

        let withdrawn = await pollUntil(timeout: 5) { self.control.pendingConsentAnswers.isEmpty }
        XCTAssertTrue(withdrawn, "the question leaves the drawers")
        let closed = await pollUntil(timeout: 5) { recorder.events.contains { $0.name == "permissionRequestClosed" } }
        XCTAssertTrue(closed, "the drawers are told to drop it")
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

    func testAnIconOnlySubmitOfAPaymentFormIsAskedInAnyLanguage() async throws {
        let tab = try await agentTab(showing: """
            <!doctype html><body><form onsubmit="document.title = 'charged'; return false">
            <input autocomplete="cc-number"><button aria-label="Confirmar la compra del carrito">\u{2192}</button></form></body>
            """)

        let reply = Task { try await click("Confirmar", tab: tab) }
        control.answerConsent(try await pendingQuestion(), granted: false)

        let result = try await reply.value
        XCTAssertTrue(result.text.hasPrefix("[needs_user]"), result.text)
        let title = try await title(tab)
        XCTAssertNotEqual(title, "charged")
    }

    func testASignInFormIsAskedWhateverItsButtonSays() async throws {
        let tab = try await agentTab(showing: """
            <!doctype html><body><form onsubmit="document.title = 'in'; return false">
            <input autocomplete="username"><input type="password"><button>Weiter</button></form></body>
            """)

        let reply = Task { try await click("Weiter", tab: tab) }
        control.answerConsent(try await pendingQuestion(), granted: false)

        let result = try await reply.value
        XCTAssertTrue(result.text.hasPrefix("[needs_user]"), result.text)
    }

    func testAFormPostedToAnotherOriginIsAsked() async throws {
        let tab = try await agentTab(showing: """
            <!doctype html><body><form method="post" action="https://example.com/collect" target="_blank" onsubmit="return false">
            <input name="q"><button>Continue</button></form></body>
            """)

        let reply = Task { try await click("Continue", tab: tab) }
        control.answerConsent(try await pendingQuestion(), granted: false)

        let result = try await reply.value
        XCTAssertTrue(result.text.hasPrefix("[needs_user]"), result.text)
    }

    func testSavingAnOrderNoteIsNotAsked() async throws {
        let tab = try await agentTab(showing: """
            <!doctype html><body><form method="post" action="/orders" onsubmit="document.title = 'saved'; return false">
            <input name="note"><button>Save order</button></form><a href="/orders">Order history</a></body>
            """)

        let reply = try await click("Save order", tab: tab)

        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertTrue(control.pendingConsentAnswers.isEmpty)
        let saved = await pollUntil(timeout: 5) { (try? await self.title(tab)) == "saved" }
        XCTAssertTrue(saved)
    }

    func testAButtonThatSaysOnlyOrderIsAsked() async throws {
        let tab = try await agentTab(showing: """
            <!doctype html><body><button onclick="document.title = 'ordered'">Order</button></body>
            """)

        let reply = Task { try await click("Order", tab: tab) }
        control.answerConsent(try await pendingQuestion(), granted: false)

        let result = try await reply.value
        XCTAssertTrue(result.text.hasPrefix("[needs_user]"), result.text)
        let title = try await title(tab)
        XCTAssertNotEqual(title, "ordered")
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

        context.settingsStore!.set(AgentControl.alwaysAllowedSitesKey, value: "[]")
        let third = Task { try await click("Place order", tab: tab) }
        control.answerConsent(try await pendingQuestion(), granted: false)
        _ = try await third.value
    }

    func testTurnedOffNothingIsAsked() async throws {
        context.settingsStore!.set(AgentControl.asksBeforeActionsKey, value: "false")
        let tab = try await shopTab()

        let reply = try await click("Place order", tab: tab)

        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertTrue(control.pendingConsentAnswers.isEmpty)
    }
}
