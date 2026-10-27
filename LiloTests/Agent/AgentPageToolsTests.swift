import XCTest
@testable import Lilo

@MainActor
final class AgentPageToolsTests: AgentToolTestCase {
    private static let page = """
    <!doctype html><title>Form</title><body>
    <nav><a href="/menu">Menu</a></nav>
    <main><h1>Hello main</h1>
    <button id="save">Save</button>
    <select id="pick"><option value="1">One</option><option value="2">Two</option></select>
    <label><input type="checkbox" id="agree"> Agree</label>
    </main>
    <script>window.changes = 0; document.addEventListener('change', () => changes++)</script>
    </body>
    """

    private func ref(_ text: String, in output: String) throws -> String {
        let line = try XCTUnwrap(output.split(separator: "\n").first { $0.contains(text) && $0.contains("ref_") }, "\(text) not in \(output)")
        let range = try XCTUnwrap(line.range(of: #"(f[a-z0-9]+_)?ref_\d+"#, options: .regularExpression))
        return String(line[range])
    }

    func testReadPageInteractiveListsButtonWithRef() async throws {
        let tab = try await agentTab(showing: Self.page)

        let reply = await client.callTool("read_page", ["tabId": tab, "filter": "interactive"])

        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertTrue(reply.text.contains(#"button "Save" [ref_"#), reply.text)
        XCTAssertTrue(reply.text.contains(#"link "Menu""#), reply.text)
        XCTAssertFalse(reply.text.contains("Hello main"), "headings are not interactive")
    }

    func testNavigateWaitsForAnAppThatBootsInSteps() async throws {
        AgentTools.settleQuiet = productSettle
        let server = try await TinyHTTPServer { request in
            guard request.hasPrefix("GET /config") else {
                return ("200 OK", ["Content-Type: text/html"], Data("""
                    <p id="splash">Loading</p><main></main>
                    <script>setTimeout(() => fetch('/config').then(r => r.text()).then(text => {
                      document.getElementById('splash').remove(); document.querySelector('main').textContent = text
                    }), 300)</script>
                    """.utf8))
            }
            Thread.sleep(forTimeInterval: 0.2)
            return ("200 OK", ["Content-Type: text/plain"], Data("App ready".utf8))
        }
        let tab = try await newAgentTab()

        _ = await client.callTool("navigate", ["tabId": tab, "url": "127.0.0.1:\(server.port)/"])

        let text = await client.callTool("get_page_text", ["tabId": tab]).text
        XCTAssertTrue(text.contains("App ready"), text)
        XCTAssertFalse(text.contains("Loading"), text)
    }

    func testFindReachesIntoShadowRoots() async throws {
        let tab = try await agentTab(showing: """
            <!doctype html><body><date-picker></date-picker>
            <script>document.querySelector('date-picker').attachShadow({ mode: 'open' }).innerHTML = '<button>Pick a day</button>'</script></body>
            """)

        let found = await client.callTool("find", ["tabId": tab, "query": "Pick a day"])

        XCTAssertTrue(found.text.contains(#"button "Pick a day" [ref_"#), found.text)
    }

    func testReadPageInteractiveListsTheControlsOfAFocusableAppRoot() async throws {
        let tab = try await agentTab(showing: """
            <!doctype html><body><div role="group" tabindex="0"><div contenteditable aria-label="Post text"></div>
            <button>Post</button></div></body>
            """)

        let reply = await client.callTool("read_page", ["tabId": tab, "filter": "interactive"])

        XCTAssertTrue(reply.text.contains(#"textbox "Post text""#), reply.text)
        XCTAssertTrue(reply.text.contains(#"button "Post""#), reply.text)
    }

    func testFindReachesTextNoNamedElementHolds() async throws {
        let tab = try await agentTab(showing: """
            <!doctype html><body><comment-box></comment-box>
            <script>document.querySelector('comment-box').attachShadow({ mode: 'open' }).innerHTML =
              '<div onclick="this.dataset.open = 1"><span>Join the conversation</span></div>'</script></body>
            """)

        let found = await client.callTool("find", ["tabId": tab, "query": "join the conversation"])

        XCTAssertTrue(found.text.contains(#""Join the conversation" [ref_"#), found.text)
    }

    func testWaitForSeesTextShowAndAButtonTurnEnabled() async throws {
        let tab = try await agentTab(showing: """
            <!doctype html><body><button id="post" disabled>Post</button>
            <script>setTimeout(() => { document.body.append('Upload ready'); post.disabled = false }, 600)</script></body>
            """)

        let text = await client.callTool("wait_for", ["tabId": tab, "text": "upload ready"])
        let enabled = await client.callTool("wait_for", ["tabId": tab, "selector": "#post", "state": "enabled"])

        XCTAssertFalse(text.isError, text.text)
        XCTAssertTrue(text.text.hasPrefix(#""upload ready" shows after"#), text.text)
        XCTAssertTrue(enabled.text.hasPrefix(#"button "Post" [ref_"#), enabled.text)
    }

    func testWaitForSaysWhatNeverShowed() async throws {
        let tab = try await agentTab(showing: Self.page)

        let reply = await client.callTool("wait_for", ["tabId": tab, "text": "Never here", "timeout": 0.5])

        XCTAssertTrue(reply.isError, reply.text)
        XCTAssertTrue(reply.text.contains(#""Never here" does not show after 0.5 s"#), reply.text)
    }

    func testRefsStayStableAcrossCalls() async throws {
        let tab = try await agentTab(showing: Self.page)

        let first = try ref(#"button "Save""#, in: await client.callTool("read_page", ["tabId": tab]).text)
        let second = try ref(#"button "Save""#, in: await client.callTool("read_page", ["tabId": tab, "filter": "interactive"]).text)

        XCTAssertEqual(first, second)
    }

    func testFindMatchesCaseInsensitively() async throws {
        let tab = try await agentTab(showing: Self.page)

        let reply = await client.callTool("find", ["tabId": tab, "query": "save"])

        XCTAssertTrue(reply.text.contains(#"button "Save""#), reply.text)
    }

    func testGetPageTextPrefersMain() async throws {
        let tab = try await agentTab(showing: Self.page)

        let reply = await client.callTool("get_page_text", ["tabId": tab])

        XCTAssertTrue(reply.text.contains("Hello main"), reply.text)
        XCTAssertFalse(reply.text.components(separatedBy: "\n\n").dropFirst().joined().contains("Menu"), "the nav is outside main")
    }

    func testFormInputSetsSelectAndCheckbox() async throws {
        let tab = try await agentTab(showing: Self.page)
        let tree = await client.callTool("read_page", ["tabId": tab, "filter": "interactive"]).text

        _ = await client.callTool("form_input", ["tabId": tab, "ref": try ref("combobox", in: tree), "value": "Two"])
        _ = await client.callTool("form_input", ["tabId": tab, "ref": try ref("checkbox", in: tree), "value": true])

        let pick = try await js("document.getElementById('pick').value", tab: tab) as? String
        let agree = try await js("document.getElementById('agree').checked", tab: tab) as? Bool
        let changes = try await js("changes", tab: tab) as? Int
        XCTAssertEqual(pick, "2")
        XCTAssertEqual(agree, true)
        XCTAssertEqual(changes, 2)
    }

    func testJavascriptToolReturnsTheValueOfTheLastStatement() async throws {
        let tab = try await agentTab(showing: Self.page)
        let run = { (text: String) in await self.client.callTool("javascript_tool", ["tabId": tab, "action": "javascript_exec", "text": text]).text }
        let cases: [(code: String, value: String)] = [
            ("1 + 1", "2"),
            ("const a = 2\na * 3", "6"),
            ("await Promise.resolve(5)", "5"),
            ("document.title", "\"Form\""),
            // The last statement of a line.
            ("window.a = 1; 'ok'", "\"ok\""),
            ("const x = 4; x * 2", "8"),
            ("[1, 2]\n  .map(x => x * 2)\n  .length", "2"),
            ("1 + 2 // the sum", "3"),
            ("const y = 1", "undefined"),
            // The statement after a block.
            ("let r = 'no'; if (true) { r = 'yes' } else { r = 'never' } r", "\"yes\""),
            ("function three() { return 3 } three()", "3"),
            ("window.literalRuns = (window.literalRuns || 0) + 1; window.k = { a: 2 }.a * 3", "6"),
            ("literalRuns", "1"),
            // The value after a loop with regexes and templates.
            ("""
            const report = []
            for (const s of ['a"b', "c'd"]) {
              if (/["']/.test(s)) report.push(`${s.length} ${`nested ${s[0]}`}`)
            }
            report.length
            """, "2"),
            ("const total = 6, parts = 3\nconst half = total / parts / 2\nhalf", "1"),
            ("const returned = 4\nreturned", "4"),
        ]

        for (code, value) in cases {
            let result = await run(code)
            XCTAssertEqual(result, value, code)
        }
        let endsWithBlock = await run("try { 1 } catch (e) {}")
        XCTAssertTrue(endsWithBlock.hasPrefix("undefined (the code ends with a block statement"), endsWithBlock)
    }

    func testACallOnATabStillBusyWithAnotherSaysSo() async throws {
        let tab = try await agentTab(showing: Self.page)
        // Sent without waiting, as by a client that gave up on it: its reply comes after the next one's.
        client.send(["jsonrpc": "2.0", "id": 900, "method": "tools/call", "params": [
            "name": "javascript_tool", "arguments": ["tabId": tab, "action": "javascript_exec", "text": "await new Promise(r => setTimeout(r, 1500)); 'slow'"]
        ]])
        let session = try XCTUnwrap(control.sessions.first)
        await pollUntil(timeout: 5) { session.activeCalls == 1 }

        let next = await client.callTool("get_page_text", ["tabId": tab])
        let slow = await client.receive()
        let after = await client.callTool("get_page_text", ["tabId": tab])

        XCTAssertTrue(next.text.hasPrefix("Warning: javascript_tool, called 0 s ago"), next.text)
        XCTAssertEqual(slow?["id"] as? Int, 900)
        XCTAssertFalse(after.text.contains("Warning"), "once the slow call ended: \(after.text)")
    }

    func testNavigateThatLeavesTheURLUnchangedSaysSo() async throws {
        let tab = try await newAgentTab()

        let back = await client.callTool("navigate", ["tabId": tab, "url": "back"])
        let reload = await client.callTool("navigate", ["tabId": tab, "url": "reload"])

        XCTAssertTrue(back.text.contains("Warning: the URL did not change"), back.text)
        XCTAssertFalse(reload.text.contains("Warning"), reload.text)
    }

    func testNavigateReturnsAJSONBody() async throws {
        let tab = try await newAgentTab()

        let reply = await client.callTool("navigate", ["tabId": tab, "url": #"data:application/json,{"answer":42}"#])

        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertTrue(reply.text.hasSuffix(#"{"answer":42}"#), reply.text)
    }

    func testJavascriptToolReportsExceptionsAndRunsTheCodeOnce() async throws {
        let tab = try await agentTab(showing: Self.page)

        let thrown = await client.callTool("javascript_tool", ["tabId": tab, "action": "javascript_exec", "text": "throw new Error('boom')"])
        let syntax = await client.callTool("javascript_tool", [
            "tabId": tab, "action": "javascript_exec", "text": "window.runs = (window.runs || 0) + 1\nJSON.parse('{')"
        ])

        XCTAssertTrue(thrown.isError)
        XCTAssertTrue(thrown.text.contains("boom"), thrown.text)
        XCTAssertTrue(syntax.isError)
        let runs = try await js("runs", tab: tab) as? Int
        XCTAssertEqual(runs, 1, "a runtime syntax error runs the code once")
    }

    func testFramesAreReadFoundFilledAndClicked() async throws {
        // The frame comes from localhost, the page from 127.0.0.1: another origin.
        let server = try await TinyHTTPServer { request in
            let port = request.split(separator: "\r\n").first { $0.lowercased().hasPrefix("host:") }?.split(separator: ":").last ?? ""
            if request.hasPrefix("GET /frame ") {
                return ("200 OK", ["Content-Type: text/html"], Data("""
                    <!doctype html><input id="name" aria-label="Inner name">
                    <button onclick="document.getElementById('out').textContent = 'pressed ' + document.getElementById('name').value">Inner button</button>
                    <p id="out">idle</p>
                    """.utf8))
            }
            return ("200 OK", ["Content-Type: text/html"], Data(#"<!doctype html><h1>Outer</h1><iframe src="http://localhost:\#(port)/frame"></iframe>"#.utf8))
        }
        let tab = try await newAgentTab()
        _ = await client.callTool("navigate", ["tabId": tab, "url": "127.0.0.1:\(server.port)/"])

        let page = await client.callTool("read_page", ["tabId": tab]).text
        let found = await client.callTool("find", ["tabId": tab, "query": "inner"]).text
        let field = try ref("Inner name", in: found)
        let button = try ref("Inner button", in: found)
        let filled = await client.callTool("form_input", ["tabId": tab, "ref": field, "value": "Ann"])
        let clicked = await client.callTool("computer", ["tabId": tab, "action": "left_click", "ref": button])
        let after = await client.callTool("read_page", ["tabId": tab, "ref_id": button]).text
        let frameText = await client.callTool("read_page", ["tabId": tab]).text

        XCTAssertTrue(page.contains("Outer") && page.contains("Frame: "), page)
        XCTAssertTrue(button.hasPrefix("f"), button)
        XCTAssertFalse(filled.isError, filled.text)
        XCTAssertFalse(clicked.isError, clicked.text)
        XCTAssertTrue(after.contains("Inner button"), after)
        XCTAssertTrue(frameText.contains("pressed Ann"), frameText)
    }

    func testNavigateFollowsServerAndScriptRedirectsToTheFinalPage() async throws {
        AgentTools.settleQuiet = productSettle
        let server = try await TinyHTTPServer { request in
            if request.hasPrefix("GET /start ") { return ("302 Found", ["Location: /signin"], Data()) }
            if request.hasPrefix("GET /check ") {
                Thread.sleep(forTimeInterval: 0.3)
                return ("200 OK", ["Content-Type: text/plain"], Data("no".utf8))
            }
            if request.hasPrefix("GET /signin ") {
                return ("200 OK", ["Content-Type: text/html"], Data("""
                    <title>Sign in</title><script>fetch('/check').then(() => location.replace('/unauthorized'))</script>
                    """.utf8))
            }
            return ("200 OK", ["Content-Type: text/html"], Data("<title>Unauthorized</title><p>No access</p>".utf8))
        }
        let tab = try await newAgentTab()

        let reply = await client.callTool("navigate", ["tabId": tab, "url": "127.0.0.1:\(server.port)/start"])

        XCTAssertEqual(reply.text, "Navigated to http://127.0.0.1:\(server.port)/unauthorized - Unauthorized")
    }

    func testNavigateWaitsForAPageRenderedByScript() async throws {
        AgentTools.settleQuiet = productSettle
        let server = try await TinyHTTPServer { request in
            if request.hasPrefix("GET /data ") {
                Thread.sleep(forTimeInterval: 0.6)
                return ("200 OK", ["Content-Type: text/plain"], Data("Account details".utf8))
            }
            return ("200 OK", ["Content-Type: text/html"], Data("""
                <title>Account</title><body><div class="spinner">Loading</div>
                <script>setTimeout(async () => { document.body.textContent = await (await fetch('/data')).text() }, 100)</script>
                """.utf8))
        }
        let tab = try await newAgentTab()

        _ = await client.callTool("navigate", ["tabId": tab, "url": "127.0.0.1:\(server.port)/"])
        let text = await client.callTool("get_page_text", ["tabId": tab]).text

        XCTAssertTrue(text.hasSuffix("Account details"), text)
    }

    func testNavigateToAStaticPageReturnsQuickly() async throws {
        let server = try await TinyHTTPServer(index: "<title>Static</title><p>plain</p>")
        let tab = try await newAgentTab()

        let reply = await client.callTool("navigate", ["tabId": tab, "url": "127.0.0.1:\(server.port)/"])

        // A page still changing at the 5 s cap gets a warning line after the title.
        XCTAssertTrue(reply.text.hasSuffix("- Static"), reply.text)
    }

    func testFindLeavesOutHiddenElements() async throws {
        let tab = try await agentTab(showing: """
            <button>Shown action</button>
            <div style="display:none"><button>Undisplayed action</button></div>
            <div style="visibility:hidden"><button>Invisible action</button></div>
            <div aria-hidden="true"><div><button>Unannounced action</button></div></div>
            <div style="height:0;overflow:hidden"><button>Collapsed action</button></div>
            <details><summary>More</summary><button>Folded action</button></details>
            <select aria-label="Kind"><option>Humanoid</option><option>Robot</option></select>
            """)

        let actions = await client.callTool("find", ["tabId": tab, "query": "action"]).text
        let options = await client.callTool("find", ["tabId": tab, "query": "robot"]).text
        // Past the header, whose URL holds the whole page.
        let tree = await client.callTool("read_page", ["tabId": tab]).text.components(separatedBy: "\n").dropFirst(3).joined(separator: "\n")

        XCTAssertEqual(actions.split(separator: "\n").count, 1, actions)
        XCTAssertTrue(actions.hasPrefix(#"button "Shown action""#), actions)
        XCTAssertEqual(options, #"No element matches "robot""#)
        for hidden in ["Undisplayed", "Invisible", "Unannounced", "Collapsed", "Folded", "Robot"] {
            XCTAssertFalse(tree.contains(hidden), "\(hidden) in \(tree)")
        }
    }

    func testTextLeavesOutIconFontCharacters() async throws {
        let tab = try await agentTab(showing: "<main><button>\u{100188} Share</button><p>Price\u{E001}: 3</p></main>")

        let text = await client.callTool("get_page_text", ["tabId": tab]).text
        let found = await client.callTool("find", ["tabId": tab, "query": "share"]).text

        XCTAssertTrue(text.hasSuffix("Share\n\nPrice: 3"), text)
        XCTAssertTrue(found.hasPrefix(#"button "Share""#), found)
    }

    func testHungTabAsksForTheUserUntilAReloadBringsItBack() async throws {
        let tab = try await agentTab(showing: Self.page)
        let engine = try engine(forTab: tab)

        engine.webViewWebProcessDidBecomeUnresponsive(engine.wkWebView)
        await pollUntil { engine.isUnresponsive }
        let stuck = await client.callTool("read_page", ["tabId": tab])
        engine.reload()
        let back = await pollUntil { !engine.isUnresponsive }
        let read = await client.callTool("get_page_text", ["tabId": tab])

        XCTAssertTrue(stuck.isError && stuck.text.hasPrefix("[needs_user] Tab \(tab) is not responding"), stuck.text)
        XCTAssertTrue(back, "the reload replaces the hung process and the page commits again")
        XCTAssertTrue(read.text.contains("Hello main"), read.text)
    }
}
