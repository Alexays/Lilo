import XCTest
import WebKit
@testable import Lilo

@MainActor
final class AgentDevToolsTests: AgentToolTestCase {
    func testCommandRunsAProtocolCommandOnABlankTabThenOnAPage() async throws {
        let tab = try await newAgentTab()
        let blank = await client.callTool("devtools_command", [
            "tabId": tab, "method": "Runtime.evaluate", "params": ["expression": "1+1", "returnByValue": true]
        ])
        _ = await client.callTool("navigate", ["tabId": tab, "url": "data:text/html,%3Ctitle%3ET%3C/title%3E%3Cp%3Ex%3C/p%3E"])

        let reply = await client.callTool("devtools_command", [
            "tabId": tab, "method": "Runtime.evaluate", "params": ["expression": "6*7", "returnByValue": true]
        ])

        XCTAssertFalse(blank.isError, blank.text)
        XCTAssertTrue(blank.text.contains("2"), blank.text)
        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertTrue(reply.text.contains("42"), reply.text)
    }

    func testCommandWithoutMethodListsCommands() async throws {
        let tab = try await agentTab(showing: "<p>x</p>")

        let reply = await client.callTool("devtools_command", ["tabId": tab])

        XCTAssertTrue(reply.text.contains("Network.addInterception"), reply.text)
        XCTAssertTrue(reply.text.contains("Page.getCookies"), reply.text)
    }

    func testProtocolErrorReachesTheAgent() async throws {
        let tab = try await agentTab(showing: "<p>x</p>")

        let reply = await client.callTool("devtools_command", ["tabId": tab, "method": "Page.nope"])

        XCTAssertTrue(reply.isError)
        XCTAssertTrue(reply.text.contains("Page.nope"), reply.text)
    }

    func testEventsKeepOnlyTrackedDomains() async throws {
        let tab = try await agentTab(showing: "<p>x</p>")
        _ = await client.callTool("devtools_command", ["tabId": tab, "method": "Console.enable"])

        _ = try await js("console.log('hi from page')", tab: tab)
        await pollUntil { await self.client.callTool("devtools_events", ["tabId": tab, "prefix": "Console."]).text.contains("hi from page") }
        let console = await client.callTool("devtools_events", ["tabId": tab, "prefix": "Console."])
        let network = await client.callTool("devtools_events", ["tabId": tab, "prefix": "Network."])

        XCTAssertTrue(console.text.contains("hi from page"), console.text)
        XCTAssertEqual(network.text, "No events")
    }

    func testNoInspectorWithoutDevtoolsTools() async throws {
        let tab = try await agentTab(showing: "<button>B</button>")
        _ = await client.callTool("read_page", ["tabId": tab])
        _ = await client.callTool("computer", ["tabId": tab, "action": "screenshot"])

        XCTAssertTrue(control.inspectors.isEmpty)
        XCTAssertFalse(try isConnected(tab))
    }

    func testReleaseClosesTheInspector() async throws {
        let tab = try await agentTab(showing: "<p>x</p>")
        _ = await client.callTool("devtools_command", ["tabId": tab, "method": "Console.enable"])
        XCTAssertTrue(try isConnected(tab))

        try await release(tab)

        XCTAssertTrue(control.inspectors.isEmpty)
        XCTAssertFalse(try isConnected(tab))
    }

    func testReleaseKeepsAnInspectorTheUserOpened() async throws {
        let tab = try await agentTab(showing: "<p>x</p>")
        _ = await client.callTool("devtools_command", ["tabId": tab, "method": "Console.enable"])
        let inspected = try engine(forTab: tab)
        XCTAssertTrue(inspected.showWebInspector())
        defer { _ = WebInspectorSupport.close(for: inspected.wkWebView) }
        _ = await pollUntil { inspected.isWebInspectorVisible }

        try await release(tab)

        XCTAssertTrue(control.inspectors.isEmpty)
        XCTAssertTrue(try isConnected(tab))
    }

    // MARK: - Cookies and emulation

    func testCookiesSetAndGetHttpOnly() async throws {
        let (tab, server) = try await served("<p>index</p>")

        let set = await client.callTool("cookies", ["tabId": tab, "action": "set",
                                                    "cookie": ["name": "secret", "value": "42", "domain": "127.0.0.1", "httpOnly": true]])
        let got = await client.callTool("cookies", ["tabId": tab, "action": "get", "url": "http://127.0.0.1:\(server.port)/"])
        _ = await client.callTool("navigate", ["tabId": tab, "url": "127.0.0.1:\(server.port)/"])
        let pageCookies = try await js("document.cookie", tab: tab) as? String

        XCTAssertFalse(set.isError, set.text)
        XCTAssertTrue(got.text.contains(#""name":"secret""#), got.text)
        XCTAssertTrue(got.text.contains(#""httpOnly":true"#), got.text)
        XCTAssertFalse(pageCookies?.contains("secret") ?? true, "an HttpOnly cookie stays out of document.cookie")
    }

    func testCookiesReachOnlyTheSitesOfTheAgentsTabs() async throws {
        let (tab, _) = try await served("<p>index</p>")
        _ = await client.callTool("cookies", ["tabId": tab, "action": "set", "cookie": ["name": "other", "value": "1", "domain": "example.org"]])

        let got = await client.callTool("cookies", ["tabId": tab, "action": "get", "domain": "example.org"])
        let cleared = await client.callTool("cookies", ["tabId": tab, "action": "clear", "domain": "example.org"])

        XCTAssertFalse(got.text.contains("other"), got.text)
        XCTAssertEqual(cleared.text, "Deleted 0 cookies")
    }

    func testCookiesClearNeedsADomain() async throws {
        let tab = try await newAgentTab()

        let reply = await client.callTool("cookies", ["tabId": tab, "action": "clear"])

        XCTAssertTrue(reply.isError)
    }

    /// Each override reaches the page, the user agent from the next load on, and a reset undoes them all.
    func testEmulateAppliesEachOverrideAndResetRestoresEverything() async throws {
        let (tab, server) = try await served("<p>index</p>")
        let userAgent = try await js("navigator.userAgent", tab: tab) as? String
        let ratio = try await js("devicePixelRatio", tab: tab) as? NSNumber

        let emulated = await client.callTool("emulate", [
            "tabId": tab, "userAgent": "AgentUA/1", "deviceScaleFactor": 3, "colorScheme": "dark", "media": "print"
        ])
        await pollUntil { (try? await self.js("devicePixelRatio", tab: tab)) as? NSNumber == 3 }

        let emulatedRatio = try await js("devicePixelRatio", tab: tab) as? NSNumber
        let prefersDark = try await js("matchMedia('(prefers-color-scheme: dark)').matches", tab: tab) as? Bool
        let printsAsPrint = try await js("matchMedia('print').matches", tab: tab) as? Bool
        _ = await client.callTool("navigate", ["tabId": tab, "url": "127.0.0.1:\(server.port)/"])
        let emulatedUserAgent = try await js("navigator.userAgent", tab: tab) as? String
        XCTAssertTrue(emulated.text.contains(#""deviceScaleFactor":3"#), emulated.text)
        XCTAssertEqual(emulatedRatio?.doubleValue, 3)
        XCTAssertEqual(prefersDark, true)
        XCTAssertEqual(printsAsPrint, true)
        XCTAssertEqual(emulatedUserAgent, "AgentUA/1")

        let reply = await client.callTool("emulate", ["tabId": tab, "reset": true])
        _ = await client.callTool("navigate", ["tabId": tab, "url": "127.0.0.1:\(server.port)/"])

        XCTAssertEqual(reply.text, "No emulation")
        let shownUserAgent = try await js("navigator.userAgent", tab: tab) as? String
        XCTAssertEqual(shownUserAgent, userAgent)
        let shownRatio = try await js("devicePixelRatio", tab: tab) as? NSNumber
        XCTAssertEqual(shownRatio, ratio)
        let printsAfterReset = try await js("matchMedia('print').matches", tab: tab) as? Bool
        XCTAssertEqual(printsAfterReset, false)
    }

    func testEmulationEndsWithTheTab() async throws {
        let tab = try await agentTab(showing: "<p>x</p>")
        let ratio = try await js("devicePixelRatio", tab: tab) as? NSNumber
        _ = await client.callTool("emulate", ["tabId": tab, "deviceScaleFactor": 3, "media": "print"])

        try await release(tab)

        let shownRatio = try await js("devicePixelRatio", tab: tab) as? NSNumber
        XCTAssertEqual(shownRatio, ratio)
        let printsAsPrint = try await js("matchMedia('print').matches", tab: tab) as? Bool
        XCTAssertEqual(printsAsPrint, false)
    }

    func testEmulationStaysOffUserTabs() async throws {
        let user = try XCTUnwrap(window.tabManager.activeEngineTab)
        let ratio = try await user.wkWebView.evaluateJavaScript("devicePixelRatio") as? NSNumber
        let tab = try await agentTab(showing: "<p>x</p>")

        _ = await client.callTool("emulate", ["tabId": tab, "deviceScaleFactor": 3, "media": "print"])

        let shownRatio = try await user.wkWebView.evaluateJavaScript("devicePixelRatio") as? NSNumber
        XCTAssertEqual(shownRatio, ratio)
        let printsAsPrint = try await user.wkWebView.evaluateJavaScript("matchMedia('print').matches") as? Bool
        XCTAssertEqual(printsAsPrint, false)
    }

    // MARK: - Performance

    func testMetricsBreakTheMemoryDown() async throws {
        let tab = try await agentTab(showing: "<p>one</p><p>two</p>")

        let reply = await client.callTool("performance", ["tabId": tab, "action": "metrics"])

        XCTAssertFalse(reply.isError, reply.text)
        for key in ["navigation", "domNodes", "memoryFootprintMB", "memoryMB", "javascript"] {
            XCTAssertTrue(reply.text.contains(#""\#(key)""#), reply.text)
        }
        XCTAssertTrue(reply.text.contains(#""visibility":"visible""#), reply.text)
        XCTAssertFalse(reply.text.contains(#""longTasks":{"count":0"#), "WebKit has no long task entries: \(reply.text)")
    }

    func testMetricsSayWhichEntriesWebKitNeverReports() async throws {
        let tab = try await agentTab(showing: "<p>one</p>")
        let supported = try await js("PerformanceObserver.supportedEntryTypes", tab: tab) as? [String] ?? []

        let reply = await client.callTool("performance", ["tabId": tab, "action": "metrics"])

        XCTAssertFalse(reply.isError, reply.text)
        for type in ["layout-shift", "longtask"] where !supported.contains(type) {
            XCTAssertTrue(reply.text.contains(#""\#(type)""#), "a null metric comes with its reason: \(reply.text)")
        }
    }

    func testProfileWritesFileAndSummary() async throws {
        let tab = try await agentTab(showing: """
            <script>function hotLoop() { const t = performance.now(); while (performance.now() - t < 200) {} }</script>
            """)
        _ = await client.callTool("performance", ["tabId": tab, "action": "start"])

        _ = try await js("window.ran = false; setTimeout(() => { hotLoop(); window.ran = true }, 0); 0", tab: tab)
        await pollUntil { (try? await self.js("window.ran", tab: tab)) as? Bool == true }
        let reply = await client.callTool("performance", ["tabId": tab, "action": "stop"])

        XCTAssertFalse(reply.isError, reply.text)
        let path = try XCTUnwrap(reply.text.split(separator: "\n").first?.components(separatedBy: " to ").last)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), path)
        XCTAssertTrue(reply.text.contains("hotLoop"), reply.text)
    }

    func testStopWithoutStartFails() async throws {
        let tab = try await agentTab(showing: "<p>x</p>")

        let reply = await client.callTool("performance", ["tabId": tab, "action": "stop"])

        XCTAssertTrue(reply.isError)
        XCTAssertTrue(reply.text.contains("start"), reply.text)
    }

    func testHeapSnapshotWritesFile() async throws {
        let tab = try await agentTab(showing: "<script>window.kept = Array.from({ length: 1000 }, (_, i) => ({ i }))</script>")

        let reply = await client.callTool("performance", ["tabId": tab, "action": "heap_snapshot"])

        XCTAssertFalse(reply.isError, reply.text)
        let path = try XCTUnwrap(reply.text.split(separator: "\n").first?.components(separatedBy: " to ").last)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
        XCTAssertNotNil(saved?["nodes"], "the whole snapshot, put back together from its pieces")
        XCTAssertTrue(reply.text.contains(#""class":"Object""#), reply.text)
    }

    func testHeapSnapshotCollectsGarbageFirst() async throws {
        let tab = try await agentTab(showing: "<p>x</p>")
        _ = try await js("for (let i = 0; i < 500; i++) document.createComment('gone'); 0", tab: tab)

        let reply = await client.callTool("performance", ["tabId": tab, "action": "heap_snapshot", "className": "Comment"])

        // One may stay: the structure of the last one created caches it.
        let json = try XCTUnwrap(reply.text.split(separator: "\n", maxSplits: 1).last)
        let summary = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let retainers = (summary?["retainers"] as? [String: Any])?["byRetainer"] as? [[String: Any]] ?? []
        XCTAssertLessThanOrEqual(retainers.reduce(0) { $0 + ($1["count"] as? Int ?? 0) }, 1, reply.text)
    }

    func testHeapSnapshotFindsADetachedTreeAndWhatKeepsIt() async throws {
        let tab = try await agentTab(showing: """
            <p>x</p><script>
            (() => {
              const removed = document.createElement('div')
              removed.id = 'panel'
              removed.innerHTML = '<h2>a</h2><ul><li>1</li><li>2</li></ul>'
              window.cache = { heading: removed.firstChild }
            })()
            </script>
            """)

        let reply = await client.callTool("performance", ["tabId": tab, "action": "heap_snapshot"])

        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertTrue(reply.text.contains(#""root":"<div#panel>""#), reply.text)
        XCTAssertTrue(reply.text.contains(#""nodes":5"#), "the div, the heading, the list and its items: \(reply.text)")
        XCTAssertTrue(reply.text.contains("Object heading"), reply.text)
        XCTAssertTrue(reply.text.contains("cache"), "the path from a root goes through window.cache: \(reply.text)")
    }

    func testRetainersNameTheClosureKeepingAnObject() async throws {
        let tab = try await agentTab(showing: """
            <script>
            class Leak {}
            function makeKeeper() { const leak = new Leak(); return function keeper() { return leak } }
            window.keep = makeKeeper()
            </script>
            """)

        let reply = await client.callTool("performance", ["tabId": tab, "action": "heap_snapshot", "className": "Leak"])

        XCTAssertTrue(reply.text.contains("scope of keeper"), reply.text)
    }

    func testPerformanceRefusesAPageAScriptHolds() async throws {
        let tab = try await agentTab(showing: "<p>x</p>")
        // Sent without waiting: the page's thread stays busy for 4 s.
        client.send(["jsonrpc": "2.0", "id": 900, "method": "tools/call", "params": [
            "name": "javascript_tool", "arguments": ["tabId": tab, "action": "javascript_exec", "text": "const t = Date.now(); while (Date.now() - t < 4000) {}; 1"]
        ]])
        let session = try XCTUnwrap(control.sessions.first)
        await pollUntil { session.activeCalls == 1 }

        let reply = await client.callTool("performance", ["tabId": tab, "action": "gc"])
        _ = await client.receive()

        XCTAssertTrue(reply.isError && reply.text.contains("thread is busy"), reply.text)
        XCTAssertTrue(reply.text.hasPrefix("Warning: javascript_tool"), reply.text)
    }

    func testGarbageCollect() async throws {
        let tab = try await agentTab(showing: "<p>x</p>")

        let reply = await client.callTool("performance", ["tabId": tab, "action": "gc"])

        XCTAssertFalse(reply.isError, reply.text)
    }

    // MARK: - Lifecycle edges

    func testCallRacingReleaseLeavesNoOverride() async throws {
        let tab = try await agentTab(showing: "<p>x</p>")
        let ratio = try await js("devicePixelRatio", tab: tab) as? NSNumber

        async let reply = client.callTool("emulate", ["tabId": tab, "deviceScaleFactor": 3])
        try await Task.sleep(for: .milliseconds(20))
        try await release(tab)
        let finished = await reply

        XCTAssertTrue(finished.isError, finished.text)
        XCTAssertTrue(control.inspectors.isEmpty)
        XCTAssertFalse(try isConnected(tab))
        let shownRatio = try await js("devicePixelRatio", tab: tab) as? NSNumber
        XCTAssertEqual(shownRatio, ratio)
    }

    func testDevtoolsKeepWorkingAfterTheUserClosesTheInspector() async throws {
        let tab = try await agentTab(showing: "<p>x</p>")
        _ = await client.callTool("devtools_command", ["tabId": tab, "method": "Console.enable"])

        _ = WebInspectorSupport.close(for: try engine(forTab: tab).wkWebView)
        let reply = await client.callTool("devtools_command", [
            "tabId": tab, "method": "Runtime.evaluate", "params": ["expression": "6*7", "returnByValue": true]
        ])

        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertTrue(reply.text.contains("42"), reply.text)
    }

    // MARK: - Edge inputs

    func testEmulateRejectsBeforeApplying() async throws {
        let tab = try await agentTab(showing: "<p>x</p>")
        let ratio = try await js("devicePixelRatio", tab: tab) as? NSNumber

        let reply = await client.callTool("emulate", ["tabId": tab, "deviceScaleFactor": 3, "media": "print", "colorScheme": "blue"])

        XCTAssertTrue(reply.isError, reply.text)
        let shownRatio = try await js("devicePixelRatio", tab: tab) as? NSNumber
        let printsAsPrint = try await js("matchMedia('print').matches", tab: tab) as? Bool
        XCTAssertEqual(shownRatio, ratio)
        XCTAssertEqual(printsAsPrint, false)
    }

    func testNullLimitsKeepTheDefaults() async throws {
        let (tab, server) = try await served("<p>hello index</p>")
        _ = await client.callTool("devtools_command", ["tabId": tab, "method": "Console.enable"])
        _ = await client.callTool("navigate", ["tabId": tab, "url": "127.0.0.1:\(server.port)/"])

        let response = await client.callTool("network_response", ["tabId": tab, "url": "http://127.0.0.1:\(server.port)/", "max_chars": NSNull()])
        _ = try await js("console.log('logged')", tab: tab)
        await pollUntil {
            await self.client.callTool("devtools_events", ["tabId": tab, "prefix": "Console.", "limit": NSNull()]).text.contains("logged")
        }
        let events = await client.callTool("devtools_events", ["tabId": tab, "prefix": "Console.", "limit": NSNull()])

        XCTAssertTrue(response.text.contains("hello index"), response.text)
        XCTAssertTrue(events.text.contains("logged"), events.text)
    }

    func testCookiesClearRefusesATopLevelDomain() async throws {
        let tab = try await newAgentTab()

        let reply = await client.callTool("cookies", ["tabId": tab, "action": "clear", "domain": "com"])

        XCTAssertTrue(reply.isError, reply.text)
    }

    func testReleaseWithTheUserInspectorOpenDropsAgentRules() async throws {
        let (tab, server) = try await served("<p>index</p>")
        _ = await mock(tab, ["urlPattern": "/api/user", "response": ["body": "mocked"]])
        _ = await client.callTool("emulate", ["tabId": tab, "media": "print"])
        let inspected = try engine(forTab: tab)
        XCTAssertTrue(inspected.showWebInspector())
        defer { _ = WebInspectorSupport.close(for: inspected.wkWebView) }
        _ = await pollUntil { inspected.isWebInspectorVisible }

        try await release(tab)
        let body = try await page("return await (await fetch('/api/user')).text()", tab: tab)
        let printsAsPrint = try await js("matchMedia('print').matches", tab: tab) as? Bool

        XCTAssertTrue(try isConnected(tab), "the inspector the user looks at stays open")
        XCTAssertEqual(body as? String, "missing")
        XCTAssertEqual(printsAsPrint, false)
        _ = server
    }

    func testInitScriptRunsBeforeThePageScripts() async throws {
        let (tab, server) = try await served("<script>window.seen = typeof window.early</script>")

        let set = await client.callTool("emulate", ["tabId": tab, "initScript": "window.early = 1"])
        _ = await client.callTool("navigate", ["tabId": tab, "url": "reload"])

        let seen = try await js("window.seen", tab: tab) as? String
        _ = await client.callTool("emulate", ["tabId": tab, "initScript": NSNull()])
        _ = await client.callTool("navigate", ["tabId": tab, "url": "reload"])
        let seenAfterRemoval = try await js("window.seen", tab: tab) as? String

        XCTAssertFalse(set.isError, set.text)
        XCTAssertEqual(seen, "number")
        XCTAssertEqual(seenAfterRemoval, "undefined")
        _ = server
    }

    private static let namedPage = """
        <title>Jane Doe - Admin</title>
        <p id=name>Jane Doe</p><p id=other>Janet Doerr</p>
        <input id=field value="Jane Doe" placeholder="Search Jane Doe"><img id=pic alt="Photo of Jane Doe" title="jane doe">
        <div id=open></div><div id=closed></div>
        <iframe id=frame srcdoc="<p>Jane Doe</p>"></iframe>
        <script>
          document.getElementById('open').attachShadow({ mode: 'open' }).innerHTML = '<b>Jane Doe</b>'
          window.closedRoot = document.getElementById('closed').attachShadow({ mode: 'closed' })
          window.closedRoot.innerHTML = '<b>Jane Doe</b>'
        </script>
        """

    private static let shownNames = """
        const frame = document.getElementById('frame').contentDocument?.body?.textContent ?? ''
        const field = document.getElementById('field')
        const pic = document.getElementById('pic')
        return [
          document.title, document.getElementById('name').textContent, document.getElementById('other').textContent, field.value,
          field.placeholder, pic.alt, pic.title, document.getElementById('open').shadowRoot.textContent, frame
        ].join('|')
        """

    func testTextReplaceKeepsUpWithThePageAndEachLoad() async throws {
        let (tab, server) = try await served(Self.namedPage)
        let set = await client.callTool("emulate", ["tabId": tab, "textReplace": [["Jane Doe", "Alex Smith"]]])
        XCTAssertFalse(set.isError, set.text)
        let expected = "Alex Smith - Admin|Alex Smith|Janet Doerr|Alex Smith|Search Alex Smith|Photo of Alex Smith|Alex Smith|Alex Smith|Alex Smith"
        let replaced = await pollUntil { (try? await self.page(Self.shownNames, tab: tab)) as? String == expected }
        let shown = try await page(Self.shownNames, tab: tab)
        XCTAssertTrue(replaced, "\(shown ?? "")")

        let field = try await page("""
            document.getElementById('name').textContent = 'Hello Jane Doe'
            document.body.append(Object.assign(document.createElement('p'), { id: 'late', textContent: 'JANE DOE' }))
            const field = document.getElementById('field')
            field.value = 'Jane Doe again'
            return field.value
            """, tab: tab)
        let rendered = await pollUntil {
            (try? await self.page("return document.getElementById('name').textContent + '|' + document.getElementById('late').textContent", tab: tab))
                as? String == "Hello Alex Smith|Alex Smith"
        }
        _ = await client.callTool("navigate", ["tabId": tab, "url": "reload"])
        let reloaded = await pollUntil {
            (try? await self.page("return document.getElementById('name').textContent + '|' + window.closedRoot.textContent", tab: tab))
                as? String == "Alex Smith|Alex Smith"
        }

        XCTAssertEqual(field as? String, "Alex Smith again", "a value the page sets is replaced at once")
        XCTAssertTrue(rendered, "a node the page rewrites or adds is replaced too")
        XCTAssertTrue(reloaded, "the next load is replaced, its closed shadow root included")
        _ = server
    }

    func testTextReplaceResetPutsThePageTextBack() async throws {
        let (tab, server) = try await served(Self.namedPage)
        _ = await client.callTool("emulate", ["tabId": tab, "textReplace": [["/jane\\s+(doe)/i", "Alex $1"]]])
        let replaced = await pollUntil { (try? await self.page("return document.getElementById('name').textContent", tab: tab)) as? String == "Alex Doe" }

        let reply = await client.callTool("emulate", ["tabId": tab, "reset": true])
        let restored = try await page(Self.shownNames, tab: tab)
        _ = try await page("document.getElementById('name').textContent = 'Jane Doe again'", tab: tab)
        try await Task.sleep(for: .milliseconds(300))
        let rendered = try await page("return document.getElementById('name').textContent", tab: tab)

        XCTAssertTrue(replaced)
        XCTAssertEqual(reply.text, "No emulation")
        XCTAssertEqual(restored as? String, "Jane Doe - Admin|Jane Doe|Janet Doerr|Jane Doe|Search Jane Doe|Photo of Jane Doe|jane doe|Jane Doe|Jane Doe")
        XCTAssertEqual(rendered as? String, "Jane Doe again", "nothing replaces the page's text any more")
        _ = server
    }

    func testTextReplaceRejectsAReplacementItsPatternMatches() async throws {
        let (tab, server) = try await served("<p>Ann</p>")

        let reply = await client.callTool("emulate", ["tabId": tab, "textReplace": [["/Ann/", "Anna"]]])

        XCTAssertTrue(reply.isError, reply.text)
        _ = server
    }

    func testTextReplaceGuardRefusesAScreenshotWhileANameShows() async throws {
        let (tab, server) = try await served("<p>Jane <b>Doe</b></p><input value=Doe>")
        _ = await client.callTool("emulate", ["tabId": tab, "textReplaceGuard": ["Jane Doe", "Doe"]])

        let refused = await client.callTool("computer", ["tabId": tab, "action": "screenshot"])
        _ = await client.callTool("emulate", ["tabId": tab, "textReplace": [["Jane", "Alex"], ["Doe", "Smith"]]])
        let taken = await client.callTool("computer", ["tabId": tab, "action": "screenshot"])
        _ = await client.callTool("emulate", ["tabId": tab, "textReplaceGuard": NSNull()])
        let unguarded = await client.callTool("computer", ["tabId": tab, "action": "screenshot"])

        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.images.isEmpty)
        XCTAssertTrue(refused.text.contains(#"Jane Doe in the text "Jane Doe""#), "a name split by markup counts: \(refused.text)")
        XCTAssertTrue(refused.text.contains("Doe in a field value"), refused.text)
        XCTAssertFalse(taken.isError, taken.text)
        XCTAssertEqual(taken.images.count, 1)
        XCTAssertFalse(unguarded.isError, unguarded.text)
        _ = server
    }

    func testProfileListsLongTasksAndTheSectionsBetweenMarks() async throws {
        let tab = try await agentTab(showing: """
            <script>function busy() { const t = performance.now(); while (performance.now() - t < 150) {} }</script>
            """)
        _ = await client.callTool("performance", ["tabId": tab, "action": "start"])
        _ = try await js("window.ran = false; console.timeStamp('before'); setTimeout(() => { busy(); console.timeStamp('after'); window.ran = true }, 0); 0", tab: tab)
        await pollUntil { (try? await self.js("window.ran", tab: tab)) as? Bool == true }

        let reply = await client.callTool("performance", ["tabId": tab, "action": "stop"])

        let json = try XCTUnwrap(reply.text.split(separator: "\n", maxSplits: 1).last)
        let summary = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], reply.text)
        let longTasks = try XCTUnwrap(summary["longTasks"] as? [String: Any], reply.text)
        let longest = try XCTUnwrap((longTasks["longest"] as? [[String: Any]])?.first, reply.text)
        XCTAssertGreaterThanOrEqual(longest["durationMs"] as? Int ?? 0, 140, reply.text)
        XCTAssertTrue("\(longest["topFunctions"] ?? "")".contains("busy"), reply.text)
        let marks = try XCTUnwrap(summary["markers"] as? [[String: Any]], reply.text)
        XCTAssertEqual(marks.compactMap { $0["label"] as? String }, ["before", "after"])
        XCTAssertTrue("\(marks[0]["topFunctions"] ?? "")".contains("busy"), reply.text)
        // WebKit samples less often on a busy machine: the summary is checked against the raw profile, not a rate.
        let saved = try XCTUnwrap(reply.text.split(separator: "\n").first?.replacingOccurrences(of: "Saved the profile to ", with: ""))
        let messages = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: saved))) as? [[String: Any]])
        let sampled = messages.filter { $0["method"] as? String == "ScriptProfiler.trackingComplete" }.flatMap { message in
            (((message["params"] as? [String: Any])?["samples"] as? [String: Any])?["stackTraces"] as? [[String: Any]] ?? [])
                .filter { !($0["stackFrames"] as? [Any] ?? []).isEmpty }
        }
        XCTAssertEqual(summary["samples"] as? Int, sampled.count, "the samples WebKit sends without a time count too: \(reply.text)")
    }

    func testProfileSummaryNamesCallersAndFocusesOnAFunction() async throws {
        let tab = try await agentTab(showing: """
            <script>
            function hotLoop() { const t = performance.now(); while (performance.now() - t < 200) {} }
            function caller() { hotLoop() }
            </script>
            """)
        _ = await client.callTool("performance", ["tabId": tab, "action": "start"])
        _ = try await js("window.ran = false; setTimeout(() => { caller(); window.ran = true }, 0); 0", tab: tab)
        await pollUntil { (try? await self.js("window.ran", tab: tab)) as? Bool == true }
        let stopped = await client.callTool("performance", ["tabId": tab, "action": "stop"])

        let focused = await client.callTool("performance", ["tabId": tab, "action": "summary", "focus": "hotLoop"])
        let empty = await client.callTool("performance", ["tabId": tab, "action": "summary", "fromMs": 100_000])
        let unmatched = await client.callTool("performance", ["tabId": tab, "action": "summary", "focus": "noSuchFunction"])

        XCTAssertTrue(stopped.text.contains(#""callers""#), stopped.text)
        XCTAssertTrue(stopped.text.contains(#""byOrigin""#), stopped.text)
        XCTAssertTrue(focused.text.contains("hotLoop") && focused.text.contains("<- caller"), focused.text)
        XCTAssertTrue(empty.text.contains(#""samples":0"#), empty.text)
        XCTAssertTrue(unmatched.text.contains("No sample ran a function or file matching"), "a focus that matched nothing says so: \(unmatched.text)")
    }

    func testHeapSnapshotGrowthAndRetainers() async throws {
        let tab = try await agentTab(showing: "<script>class Leak {}; window.kept = []</script>")
        _ = await client.callTool("performance", ["tabId": tab, "action": "heap_snapshot"])
        _ = try await js("for (let i = 0; i < 500; i++) kept.push(new Leak()); 0", tab: tab)

        let reply = await client.callTool("performance", ["tabId": tab, "action": "heap_snapshot", "className": "Leak"])

        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertTrue(reply.text.contains(#""class":"Leak","count":500"#), reply.text)
        XCTAssertTrue(reply.text.contains("kept"), "the path from a root goes through window.kept: \(reply.text)")
    }

    func testProfileFollowsACrossSiteNavigation() async throws {
        AgentTools.settleQuiet = productSettle
        let server = try await TinyHTTPServer(index: """
            <script>function hotLoop() { const t = performance.now(); while (performance.now() - t < 300) {} }</script>
            """)
        let tab = try await newAgentTab()
        _ = await client.callTool("navigate", ["tabId": tab, "url": "127.0.0.1:\(server.port)/"])
        _ = await client.callTool("performance", ["tabId": tab, "action": "start"])

        _ = await client.callTool("navigate", ["tabId": tab, "url": "http://localhost:\(server.port)/"])
        // Run on the loaded page: samples taken before the profile follows it into its new process are lost.
        let arrived = await pollUntil { (try? await self.js("location.hostname + ' ' + document.readyState", tab: tab)) as? String == "localhost complete" }
        XCTAssertTrue(arrived)
        _ = try await js("hotLoop()", tab: tab)
        let reply = await client.callTool("performance", ["tabId": tab, "action": "stop"])

        XCTAssertTrue(reply.text.contains("hotLoop"), "\(reply.isError) \(reply.text)")
        let json = try XCTUnwrap(reply.text.split(separator: "\n", maxSplits: 1).last)
        let summary = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let duration = try XCTUnwrap(summary["durationMs"] as? Int)
        for case let (type, record as [String: Any]) in summary["records"] as? [String: Any] ?? [:] {
            XCTAssertLessThanOrEqual(record["totalMs"] as? Int ?? 0, duration, "\(type) covers no more than the profile")
        }
    }
}

/// The network tools: mocks, held requests and the responses an agent reads back.
@MainActor
final class AgentNetworkToolsTests: AgentToolTestCase {
    private static let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    func testMockAnswersFetch() async throws {
        let (tab, server) = try await served("<p>index</p>")
        let added = await mock(tab, ["urlPattern": "/api/user", "response": ["status": 201, "body": #"{"name":"mock"}"#, "mimeType": "application/json"]])
        XCTAssertFalse(added.isError, added.text)

        let result = try await page("const r = await fetch('/api/user'); return r.status + ' ' + await r.text()", tab: tab)

        XCTAssertEqual(result as? String, #"201 {"name":"mock"}"#)
        _ = server
    }

    func testMockAnswersAnImage() async throws {
        let (tab, server) = try await served("<p>index</p>")
        _ = await mock(tab, ["urlPattern": #"/pic\.png$"#, "response": ["bodyBase64": Self.png, "mimeType": "image/png"]])

        let width = try await page("""
            return await new Promise(done => { const i = new Image(); i.onload = () => done(i.naturalWidth); i.onerror = () => done(-1); i.src = '/pic.png' })
            """, tab: tab)

        XCTAssertEqual((width as? NSNumber)?.intValue, 1)
        _ = server
    }

    func testMockErrorFailsTheRequest() async throws {
        let (tab, server) = try await served("<p>index</p>")
        _ = await mock(tab, ["urlPattern": "/api/broken", "error": "General"])

        let result = try await page("try { await fetch('/api/broken'); return 'loaded' } catch { return 'failed' }", tab: tab)

        XCTAssertEqual(result as? String, "failed")
        _ = server
    }

    func testModifyRewritesTheRequest() async throws {
        let (tab, server) = try await served("<p>the index</p>")
        _ = await mock(tab, ["urlPattern": "/nope$", "modify": ["url": "http://127.0.0.1:\(server.port)/"]])

        let result = try await page("return await (await fetch('/nope')).text()", tab: tab)

        XCTAssertEqual(result as? String, "<p>the index</p>")
    }

    func testResponseStageReplacesRealResponse() async throws {
        let (tab, server) = try await served("<p>index</p>")
        _ = await mock(tab, ["urlPattern": "/real$", "stage": "response", "response": ["status": 200, "body": "replaced"]])

        let result = try await page("const r = await fetch('/real'); return r.status + ' ' + await r.text()", tab: tab)

        XCTAssertEqual(result as? String, "200 replaced")
        _ = server
    }

    func testDelayHoldsTheRequest() async throws {
        let (tab, server) = try await served("<p>index</p>")
        _ = await mock(tab, ["urlPattern": "/slow$", "delayMs": 400])

        let result = try await page("const t = performance.now(); const r = await fetch('/slow'); return [r.status, performance.now() - t]", tab: tab)

        let values = try XCTUnwrap(result as? [NSNumber])
        XCTAssertEqual(values[0].intValue, 404, "the real response comes through")
        XCTAssertGreaterThanOrEqual(values[1].doubleValue, 400)
        _ = server
    }

    func testMockMatchesOnlyItsMethods() async throws {
        let (tab, server) = try await served("<p>index</p>")
        _ = await mock(tab, ["urlPattern": "/api/search", "methods": ["post"]])
        _ = await mock(tab, ["urlPattern": "/api/", "methods": ["POST", "DELETE"], "error": "AccessControl"])
        let status = "try { return (await fetch(path, { method })).status } catch { return 'blocked' }"
        let run = { (path: String, method: String) in
            try await self.engine(forTab: tab).wkWebView.callAsyncJavaScript(status, arguments: ["path": path, "method": method], contentWorld: .page)
        }

        let read = try await run("/api/items", "GET")
        let write = try await run("/api/items", "POST")
        let allowed = try await run("/api/search", "POST")

        XCTAssertEqual("\(read ?? "")", "404", "a GET reaches the server")
        XCTAssertEqual(write as? String, "blocked")
        XCTAssertEqual("\(allowed ?? "")", "404", "the rule before lets this POST through")
        _ = server
    }

    func testBodyJsonMocksOneGraphQLOperation() async throws {
        let (tab, server) = try await served("<p>index</p>")
        let added = await mock(tab, [
            "urlPattern": "/graphql$", "bodyJson": ["operationName": "^GetUser$"], "response": ["body": #"{"data":{"user":"mock"}}"#, "mimeType": "application/json"]
        ])
        XCTAssertFalse(added.isError, added.text)
        let post = "return await (await fetch('/graphql', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body })).text()"
        let run = { (body: String) in
            try await self.engine(forTab: tab).wkWebView.callAsyncJavaScript(post, arguments: ["body": body], contentWorld: .page)
        }

        let mocked = try await run(#"{"operationName":"GetUser","query":"query GetUser { user { name } }"}"#)
        let other = try await run(#"{"operationName":"GetUsers","query":"query GetUsers { users { name } }"}"#)
        let batch = try await run(#"[{"operationName":"GetTeam"},{"operationName":"GetUser"}]"#)

        XCTAssertEqual(mocked as? String, #"{"data":{"user":"mock"}}"#)
        XCTAssertEqual(other as? String, "missing", "another operation reaches the server")
        XCTAssertEqual(batch as? String, #"{"data":{"user":"mock"}}"#, "a batch matches by any of its operations")
        _ = server
    }

    func testBodyJsonBlocksMutationsWhileQueriesPassOverFetchAndXHR() async throws {
        let (tab, server) = try await served("<p>index</p>")
        _ = await mock(tab, ["urlPattern": "/graphql$", "bodyJson": ["query": #"^\s*mutation\b"#], "error": "AccessControl"])

        let result = try await page("""
            const send = (via, query) => via === 'fetch'
              ? fetch('/graphql', { method: 'POST', body: JSON.stringify({ query }) }).then(r => r.status, () => 'blocked')
              : new Promise(done => {
                  const xhr = new XMLHttpRequest()
                  xhr.open('POST', '/graphql')
                  xhr.onload = () => done(xhr.status)
                  xhr.onerror = () => done('blocked')
                  xhr.send(JSON.stringify({ query }))
                })
            return [
              await send('fetch', '  mutation Rename { rename(name: "x") }'), await send('fetch', 'query Me { me }'),
              await send('xhr', 'mutation Delete { delete }'), await send('xhr', '{ me }')
            ].join(' ')
            """, tab: tab)

        XCTAssertEqual(result as? String, "blocked 404 blocked 404")
        _ = server
    }

    func testBodyPatternMatchesXHRBeaconsAndFormPosts() async throws {
        let (tab, server) = try await served("<iframe name=target></iframe>")
        _ = await mock(tab, ["urlPattern": "/track$", "bodyPattern": #"event\W{1,3}signup"#, "response": ["body": "seen"]])

        let result = try await page("""
            const xhr = body => new Promise(done => {
              const request = new XMLHttpRequest()
              request.open('POST', '/track')
              request.onload = () => done(request.responseText)
              request.send(body)
            })
            const signup = await xhr('{"event":"signup"}')
            const view = await xhr('{"event":"view"}')
            navigator.sendBeacon('/track', '{"event":"signup"}')
            const form = Object.assign(document.createElement('form'), { method: 'post', action: '/track', target: 'target' })
            form.append(Object.assign(document.createElement('input'), { name: 'event', value: 'signup' }))
            document.body.append(form)
            const frame = document.querySelector('iframe')
            await new Promise(done => { frame.onload = done; form.submit() })
            return [signup, view, frame.contentDocument.body.textContent].join(' ')
            """, tab: tab)
        let counted = await pollUntil {
            await self.client.callTool("network_mock", ["tabId": tab, "action": "list"]).text.contains(#""hits":3"#)
        }

        XCTAssertEqual(result as? String, "seen missing seen")
        XCTAssertTrue(counted, "the XHR, the beacon and the form post each hit the rule")
        _ = server
    }

    func testInvalidRegexIsRejected() async throws {
        let (tab, server) = try await served("<p>index</p>")

        let reply = await mock(tab, ["urlPattern": "(", "response": ["body": "x"]])

        XCTAssertTrue(reply.isError, reply.text)
        _ = server
    }

    func testListAndRemoveRules() async throws {
        let (tab, server) = try await served("<p>index</p>")
        _ = await mock(tab, ["urlPattern": "/first", "response": ["body": "1"]])
        _ = await mock(tab, ["urlPattern": "/second", "error": "Timeout"])
        _ = try await page("await fetch('/first'); return 1", tab: tab)

        let listed = await client.callTool("network_mock", ["tabId": tab, "action": "list"])
        _ = await client.callTool("network_mock", ["tabId": tab, "action": "remove", "id": 1])
        let afterRemove = await client.callTool("network_mock", ["tabId": tab, "action": "list"])
        _ = await client.callTool("network_mock", ["tabId": tab, "action": "clear"])
        let afterClear = await client.callTool("network_mock", ["tabId": tab, "action": "list"])

        XCTAssertTrue(listed.text.contains("/first") && listed.text.contains("/second"), listed.text)
        XCTAssertTrue(listed.text.contains(#""hits":1"#), listed.text)
        XCTAssertFalse(afterRemove.text.contains("/first"), afterRemove.text)
        XCTAssertEqual(afterClear.text, "[]")
        _ = server
    }

    func testReleaseContinuesHeldRequests() async throws {
        let (tab, server) = try await served("<p>index</p>")
        _ = await mock(tab, ["urlPattern": "/held$", "delayMs": 10000])
        _ = try await js("window.done = null; fetch('/held').then(r => { window.done = r.status }); 0", tab: tab)
        try await Task.sleep(for: .milliseconds(300))

        try await release(tab)
        // Well under the mock's 10 s delay: only the release answers this soon.
        await pollUntil(timeout: 5) { (try? await self.js("window.done", tab: tab)) is NSNumber }

        let status = try await js("window.done", tab: tab)
        XCTAssertEqual((status as? NSNumber)?.intValue, 404, "released with the tab, not after the 10 s delay")
        _ = server
    }

    func testResponseReturnsHeadersAndBody() async throws {
        let (tab, server) = try await served("<p>hello index</p>")
        _ = await client.callTool("devtools_command", ["tabId": tab, "method": "Console.enable"])
        _ = await client.callTool("navigate", ["tabId": tab, "url": "127.0.0.1:\(server.port)/"])

        let reply = await client.callTool("network_response", ["tabId": tab, "url": "http://127.0.0.1:\(server.port)/"])

        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertTrue(reply.text.contains(#""status": 200"#), reply.text)
        XCTAssertTrue(reply.text.contains("Content-Type"), reply.text)
        XCTAssertTrue(reply.text.contains("hello index"), reply.text)
    }

    func testResponseGivesTheShapeOfALongJSONBody() async throws {
        let server = try await TinyHTTPServer { _ in
            ("200 OK", ["Content-Type: application/json"], Data(#"{"items":[{"id":1,"name":"a"},{"id":2,"name":"b"}],"total":2}"#.utf8))
        }
        let tab = try await newAgentTab()
        _ = await client.callTool("navigate", ["tabId": tab, "url": "127.0.0.1:\(server.port)/"])
        _ = await client.callTool("devtools_command", ["tabId": tab, "method": "Console.enable"])
        _ = try await page("await fetch('/list'); return 1", tab: tab)

        let reply = await client.callTool("network_response", ["tabId": tab, "url": "/list", "max_chars": 10])

        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(reply.text.utf8)) as? [String: Any], reply.text)
        let shape = try XCTUnwrap(object["bodyShape"] as? [String: Any], reply.text)
        XCTAssertEqual(shape["total"] as? String, "number")
        let items = try XCTUnwrap(shape["items"] as? [Any], reply.text)
        XCTAssertEqual(items.first as? String, "2 items")
        XCTAssertEqual((items.last as? [String: Any])?["name"] as? String, "string (1)")
    }

    func testResponseCutsLongBodies() async throws {
        let (tab, server) = try await served(String(repeating: "a", count: 5000))
        _ = await client.callTool("devtools_command", ["tabId": tab, "method": "Console.enable"])
        _ = await client.callTool("navigate", ["tabId": tab, "url": "127.0.0.1:\(server.port)/"])

        let reply = await client.callTool("network_response", ["tabId": tab, "url": "http://127.0.0.1:\(server.port)/", "max_chars": 10])

        XCTAssertTrue(reply.text.contains("10 of 5000"), reply.text)
        XCTAssertFalse(reply.text.contains(String(repeating: "a", count: 11)), reply.text)
    }

    func testResponseBeforeConnectAsksToReload() async throws {
        let (tab, server) = try await served("<p>index</p>")

        let reply = await client.callTool("network_response", ["tabId": tab, "url": "http://127.0.0.1:\(server.port)/"])

        XCTAssertTrue(reply.isError)
        XCTAssertTrue(reply.text.contains("reload"), reply.text)
        _ = server
    }

    func testMocksAndEmulationSurviveCrossSiteNavigation() async throws {
        let (tab, server) = try await served("<p>index</p>")
        _ = await mock(tab, ["urlPattern": "/api/user", "response": ["body": "mocked"]])
        _ = await client.callTool("emulate", ["tabId": tab, "media": "print"])

        _ = await client.callTool("navigate", ["tabId": tab, "url": "localhost:\(server.port)/"])
        let body = try await page("return await (await fetch('/api/user')).text()", tab: tab)
        let printsAsPrint = try await js("matchMedia('print').matches", tab: tab) as? Bool

        XCTAssertEqual(body as? String, "mocked")
        XCTAssertEqual(printsAsPrint, true)
    }

    func testResponseReportsSizeAndDecodesItsCharset() async throws {
        let server = try await TinyHTTPServer(index: "<p>caf\u{e9}</p>", contentType: "text/html; charset=iso-8859-1", encoding: .isoLatin1)
        let tab = try await newAgentTab()
        _ = await client.callTool("devtools_command", ["tabId": tab, "method": "Console.enable"])
        _ = await client.callTool("navigate", ["tabId": tab, "url": "127.0.0.1:\(server.port)/"])

        let reply = await client.callTool("network_response", ["tabId": tab, "url": "http://127.0.0.1:\(server.port)/"])

        XCTAssertTrue(reply.text.contains("caf\u{e9}"), reply.text)
        XCTAssertTrue(reply.text.contains(#""sizeBytes""#), reply.text)
    }

    func testResponseReportsABinaryBody() async throws {
        let (tab, server) = try await served("<p>index</p>")
        _ = await mock(tab, ["urlPattern": #"/pic\.png$"#, "response": ["bodyBase64": Self.png, "mimeType": "image/png"]])
        _ = try await page("""
            return await new Promise(done => { const i = new Image(); i.onload = i.onerror = () => done(1); i.src = '/pic.png' })
            """, tab: tab)

        let reply = await client.callTool("network_response", ["tabId": tab, "url": "pic.png"])

        XCTAssertTrue(reply.text.contains("(binary, 70 bytes)"), reply.text)
        _ = server
    }

    func testResponseListsEveryMatchingRequestWithTimingsAndBodies() async throws {
        let (tab, server) = try await served("<p>index</p>")
        _ = await client.callTool("devtools_command", ["tabId": tab, "method": "Console.enable"])
        _ = try await page("for (const id of [1, 2]) await fetch('/resolve', { method: 'POST', body: `widget-${id}` }); return 1", tab: tab)

        let reply = await client.callTool("network_response", ["tabId": tab, "url": "/resolve", "method": "post", "all": true])

        let list = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(reply.text.utf8)) as? [[String: Any]], reply.text)
        XCTAssertEqual(list.map { $0["requestBody"] as? String }, ["widget-1", "widget-2"])
        // The inspector hears of the last request a moment after the page: the first one is complete.
        XCTAssertNotNil(list.first?["ttfbMs"] as? Int, reply.text)
        XCTAssertNotNil(list.first?["durationMs"] as? Int, reply.text)
        XCTAssertNotNil(list.last?["startMs"] as? Int, reply.text)
        XCTAssertEqual(list.first?["body"] as? String, "missing")
        _ = server
    }

    func testResponseSavesAHar() async throws {
        let (tab, server) = try await served("<p>index</p>")
        _ = await client.callTool("devtools_command", ["tabId": tab, "method": "Console.enable"])
        _ = try await page("await fetch('/one'); return 1", tab: tab)

        let reply = await client.callTool("network_response", ["tabId": tab, "har": true])

        let path = try XCTUnwrap(reply.text.components(separatedBy: " to ").last)
        let har = try JSONSerialization.jsonObject(with: try Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
        let entries = (har?["log"] as? [String: Any])?["entries"] as? [[String: Any]] ?? []
        XCTAssertTrue(entries.contains { ($0["request"] as? [String: Any])?["url"] as? String == "http://127.0.0.1:\(server.port)/one" }, reply.text)
    }

    func testAMethodRuleOnEveryURLWarnsThatGetsAreInterceptedToo() async throws {
        let tab = try await agentTab(showing: "<p>page</p>")

        let broad = await client.callTool("network_mock", ["tabId": tab, "action": "add", "urlPattern": ".*", "methods": ["PUT"], "error": "AccessControl"])
        let narrow = await client.callTool("network_mock", ["tabId": tab, "action": "add", "urlPattern": "/api/", "methods": ["PUT"], "error": "AccessControl"])

        XCTAssertTrue(broad.text.contains("Warning"), broad.text)
        XCTAssertFalse(narrow.text.contains("Warning"), narrow.text)
    }

    func testNetworkTimingsHoldWhileThePageIsBusy() async throws {
        let server = try await TinyHTTPServer { request in
            if request.hasPrefix("GET /slow") { Thread.sleep(forTimeInterval: 0.15) }
            return ("200 OK", ["Content-Type: text/plain"], Data(String(repeating: "x", count: 100_000).utf8))
        }
        let tab = try await newAgentTab()
        _ = await client.callTool("navigate", ["tabId": tab, "url": "127.0.0.1:\(server.port)/"])
        _ = await client.callTool("devtools_command", ["tabId": tab, "method": "Console.enable"])
        // The page's thread stays busy while the response comes: its event reaches the inspector late.
        _ = try await page("fetch('/slow'); const t = performance.now(); while (performance.now() - t < 400) {}; return 1", tab: tab)
        await pollUntil {
            let text = await self.client.callTool("network_response", ["tabId": tab, "url": "/slow", "max_chars": 10]).text
            return ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])?["durationMs"] is Int
        }

        let reply = await client.callTool("network_response", ["tabId": tab, "url": "/slow", "max_chars": 10])

        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(reply.text.utf8)) as? [String: Any], reply.text)
        let ttfb = try XCTUnwrap(object["ttfbMs"] as? Int, reply.text)
        let duration = try XCTUnwrap(object["durationMs"] as? Int, reply.text)
        XCTAssertGreaterThanOrEqual(ttfb, 140, reply.text)
        XCTAssertLessThanOrEqual(ttfb, duration, reply.text)
        XCTAssertLessThan(duration, 380, "the network's end, not when the busy page heard of it: \(reply.text)")
    }

    func testRequestListTurnsToTheInspectorsOnceConnected() async throws {
        let (tab, server) = try await served("<p>index</p>")
        _ = await client.callTool("devtools_command", ["tabId": tab, "method": "Console.enable"])
        for path in ["/first", "/second", "/third"] { _ = try await page("await fetch('\(path)'); return 1", tab: tab) }
        await pollUntil { await self.client.callTool("read_network_requests", ["tabId": tab, "urlPattern": "/second"]).text.contains("7 B") }

        let list = await client.callTool("read_network_requests", ["tabId": tab, "urlPattern": "/second"])
        let line = try XCTUnwrap(list.text.split(separator: "\n").first { $0.contains("/second") }, list.text)
        let id = try XCTUnwrap(line.split(separator: " ").first.map(String.init), list.text)
        let detail = await client.callTool("read_network_requests", ["tabId": tab, "requestId": id])
        let same = await client.callTool("network_response", ["tabId": tab, "requestId": id])

        XCTAssertTrue(list.text.contains("7 B"), "the body's size: \(list.text)")
        XCTAssertTrue(detail.text.contains("/second") && detail.text.contains(#""body": "missing""#), detail.text)
        XCTAssertEqual(detail.text, same.text)
        _ = server
    }

    func testRequestListMarksEachPageLoad() async throws {
        let (tab, server) = try await served("<iframe src='/frame'></iframe>")
        _ = await client.callTool("devtools_command", ["tabId": tab, "method": "Console.enable"])
        _ = await client.callTool("navigate", ["tabId": tab, "url": "reload"])
        _ = try await page("await fetch('/after-first'); return 1", tab: tab)
        _ = await client.callTool("navigate", ["tabId": tab, "url": "localhost:\(server.port)/"])
        _ = try await page("await fetch('/after-second'); return 1", tab: tab)
        await pollUntil { await self.client.callTool("read_network_requests", ["tabId": tab]).text.contains("/after-second") }

        let list = await client.callTool("read_network_requests", ["tabId": tab]).text

        let loads = list.split(separator: "\n").filter { $0.hasPrefix("-- Page load:") }
        XCTAssertEqual(loads, ["-- Page load: http://127.0.0.1:\(server.port)/", "-- Page load: http://localhost:\(server.port)/"], list)
        let first = try XCTUnwrap(list.range(of: "/after-first")), second = try XCTUnwrap(list.range(of: "-- Page load: http://localhost"))
        XCTAssertLessThan(first.lowerBound, second.lowerBound, list)
    }

    func testResponseCanLeaveTheResponseBodyOut() async throws {
        let (tab, server) = try await served("<p>index</p>")
        _ = await client.callTool("devtools_command", ["tabId": tab, "method": "Console.enable"])
        _ = try await page("await fetch('/save', { method: 'POST', body: 'payload' }); return 1", tab: tab)

        let reply = await client.callTool("network_response", ["tabId": tab, "url": "/save", "responseBody": false])

        XCTAssertTrue(reply.text.contains(#""requestBody": "payload""#), reply.text)
        XCTAssertFalse(reply.text.contains("missing"), reply.text)
        _ = server
    }

    func testRedirectKeepsItsHopListed() async throws {
        let server = try await TinyHTTPServer { request in
            request.hasPrefix("GET /old") ? ("302 Found", ["Location: /new"], Data()) : ("200 OK", ["Content-Type: text/plain"], Data("new".utf8))
        }
        let tab = try await newAgentTab()
        _ = await client.callTool("navigate", ["tabId": tab, "url": "127.0.0.1:\(server.port)/"])
        _ = await client.callTool("devtools_command", ["tabId": tab, "method": "Console.enable"])
        _ = try await page("await fetch('/old'); return 1", tab: tab)

        let list = await client.callTool("read_network_requests", ["tabId": tab, "urlPattern": "/old"]).text
        let final = await client.callTool("network_response", ["tabId": tab, "url": "/new"]).text

        XCTAssertTrue(list.contains("GET 302 http://127.0.0.1:\(server.port)/old"), list)
        XCTAssertTrue(final.contains(#""body": "new""#), final)
    }

    func testMockListsWhyARuleFellThrough() async throws {
        let (tab, server) = try await served("<p>index</p>")
        let dist = FileManager.default.temporaryDirectory.appending(path: "lilo-dist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dist) }
        _ = try await mockFile(tab, ["urlPattern": "/assets/(.*)", "response": ["path": dist.path + "/$1"]])

        _ = try await page("await fetch('/assets/gone.js'); return 1", tab: tab)
        let rules = await client.callTool("network_mock", ["tabId": tab, "action": "list"]).text

        XCTAssertTrue(rules.contains(#""lastError":"No file at"#) && rules.contains(#"gone.js""#), rules)
        _ = server
    }

    func testMockServesAFolderFreshOnEachRequest() async throws {
        let (tab, server) = try await served("<p>index</p>")
        let dist = FileManager.default.temporaryDirectory.appending(path: "lilo-dist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dist.appending(path: "assets"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dist) }
        try Data("one()".utf8).write(to: dist.appending(path: "assets/app.js"))
        let added = try await mockFile(tab, ["urlPattern": "/assets/([^?]*)", "response": ["path": dist.path + "/assets/$1"]])
        XCTAssertFalse(added.isError, added.text)
        let fetch = "const r = await fetch(path); return r.status + ' ' + r.headers.get('Content-Type') + ' ' + await r.text()"

        let first = try await engine(forTab: tab).wkWebView.callAsyncJavaScript(fetch, arguments: ["path": "/assets/app.js?v=1"], contentWorld: .page)
        try Data("two()".utf8).write(to: dist.appending(path: "assets/app.js"))
        let rebuilt = try await engine(forTab: tab).wkWebView.callAsyncJavaScript(fetch, arguments: ["path": "/assets/app.js"], contentWorld: .page)
        let missing = try await engine(forTab: tab).wkWebView.callAsyncJavaScript(fetch, arguments: ["path": "/assets/gone.js"], contentWorld: .page)
        let outside = try await engine(forTab: tab).wkWebView.callAsyncJavaScript(fetch, arguments: ["path": "/assets/..%2F..%2Fsecret"], contentWorld: .page)

        XCTAssertEqual(first as? String, "200 text/javascript one()")
        XCTAssertEqual(rebuilt as? String, "200 text/javascript two()")
        XCTAssertTrue((missing as? String)?.hasPrefix("404") == true, "\(missing ?? "")")
        XCTAssertEqual(outside as? String, "404 text/html missing", "a path out of the folder reaches the network, not the disk")
        _ = server
    }

    func testADeniedMockFileNeedsTheUserAndServesNothing() async throws {
        let (tab, server) = try await served("<p>index</p>")
        let file = FileManager.default.temporaryDirectory.appending(path: "lilo-secret-\(UUID().uuidString.prefix(6)).txt")
        try Data("secret".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let added = try await mockFile(tab, ["urlPattern": "/leak", "response": ["path": file.path]], granted: false)
        let result = try await page("const r = await fetch('/leak'); return await r.text()", tab: tab)

        XCTAssertTrue(added.text.hasPrefix("[needs_user]"), added.text)
        XCTAssertNotEqual(result as? String, "secret")
        _ = server
    }
}

private extension AgentToolTestCase {
    func tabId(of number: Int) throws -> UUID {
        try XCTUnwrap(control.tabNumbers.first { $0.value == number }?.key)
    }

    func isConnected(_ tab: Int) throws -> Bool {
        let inspector = try XCTUnwrap(engine(forTab: tab).wkWebView.value(forKey: "_inspector") as? NSObject)
        return inspector.value(forKey: "isConnected") as? Bool ?? false
    }

    /// Moves the tab out of the agent's folder, and waits for its inspector to go.
    func release(_ tab: Int) async throws {
        let id = try tabId(of: tab)
        _ = try window.applyBrowserCommand(.moveSidebarItem(
            spaceId: try XCTUnwrap(agentsSpaceId), kind: .tab, itemId: id, parentFolderId: nil, section: .unpinned, insert: .index(0)
        ))
        control.refreshControlledTabs()
        await control.inspectorReleases[id]?.value
    }

    /// An agent tab showing `index` from a local server, kept alive by the caller.
    func served(_ index: String) async throws -> (tab: Int, server: TinyHTTPServer) {
        let server = try await TinyHTTPServer(index: index)
        let tab = try await newAgentTab()
        _ = await client.callTool("navigate", ["tabId": tab, "url": "127.0.0.1:\(server.port)/"])
        return (tab, server)
    }

    /// Runs `body` as an async function in the page, awaiting what it returns.
    func page(_ body: String, tab: Int) async throws -> Any? {
        try await engine(forTab: tab).wkWebView.callAsyncJavaScript(body, arguments: [:], contentWorld: .page)
    }

    func mock(_ tab: Int, _ rule: [String: Any]) async -> (text: String, isError: Bool, images: [Data]) {
        await client.callTool("network_mock", rule.merging(["tabId": tab, "action": "add"]) { $1 })
    }

    /// Adds a rule whose body comes from a local file, answering the user's question with `granted`.
    func mockFile(_ tab: Int, _ rule: [String: Any], granted: Bool = true) async throws -> (text: String, isError: Bool, images: [Data]) {
        let adding = Task { await mock(tab, rule) }
        let asked = await pollUntil { !self.control.pendingConsentAnswers.isEmpty }
        XCTAssertTrue(asked, "the user allows the file first")
        control.answerConsent(try XCTUnwrap(control.pendingConsentAnswers.keys.first), granted: granted)
        return await adding.value
    }
}
