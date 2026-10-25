import AppKit
import XCTest
@testable import Lilo

@MainActor
final class AgentComputerToolTests: AgentToolTestCase {
    private static let page = """
    <!doctype html><body style="margin:0;height:3000px">
    <button id="b" style="position:absolute;left:20px;top:20px;width:200px;height:60px" onclick="clicks++">B</button>
    <button id="a" style="position:absolute;left:20px;top:120px;width:200px;height:60px" onclick="alert('hi')">Alert</button>
    <button id="c" style="position:absolute;left:20px;top:400px;width:200px;height:60px">C</button>
    <div id="pad" style="position:absolute;left:300px;top:20px;width:300px;height:200px"></div>
    <script>
    window.clicks = 0; window.drag = []; window.presses = []
    addEventListener('pointerdown', e => presses.push(e.button + ':' + e.buttons))
    const pad = document.getElementById('pad')
    pad.addEventListener('mousedown', e => drag.push('down ' + e.offsetX))
    addEventListener('mouseup', e => drag.push('up ' + (e.clientX - 300)))
    addEventListener('mousemove', e => drag.push('move buttons ' + e.buttons))
    </script></body>
    """

    func testScreenshotMatchesViewportSize() async throws {
        let tab = try await agentTab(showing: Self.page)

        let reply = await client.callTool("computer", ["tabId": tab, "action": "screenshot"])

        let image = try XCTUnwrap(reply.images.first.flatMap(NSBitmapImageRep.init(data:)))
        let bounds = try engine(forTab: tab).view.bounds
        XCTAssertEqual(image.pixelsWide, Int(bounds.width))
        XCTAssertEqual(image.pixelsHigh, Int(bounds.height))
    }

    func testClickByCoordinateAndByRef() async throws {
        let tab = try await agentTab(showing: Self.page)
        _ = await client.callTool("computer", ["tabId": tab, "action": "left_click", "coordinate": [120, 50]])
        let found = await client.callTool("find", ["tabId": tab, "query": "B"]).text
        let ref = try XCTUnwrap(found.range(of: #"ref_\d+"#, options: .regularExpression).map { String(found[$0]) })

        _ = await client.callTool("computer", ["tabId": tab, "action": "left_click", "ref": ref])

        let clicks = try await js("clicks", tab: tab) as? Int
        XCTAssertEqual(clicks, 2)
    }

    func testClickInsideAnIframeLandsOnce() async throws {
        let frame = "<button style='position:absolute;left:0;top:0;width:200px;height:60px' onclick='parent.clicks++'>F</button>"
        let tab = try await agentTab(showing: """
            <!doctype html><body style="margin:0"><script>window.clicks = 0</script>
            <iframe srcdoc="\(frame)" style="position:absolute;left:20px;top:300px;width:300px;height:100px;border:0"></iframe></body>
            """)
        await pollUntil { (try? await self.js("!!document.querySelector('iframe').contentDocument?.querySelector('button')", tab: tab)) as? Bool == true }

        _ = await client.callTool("computer", ["tabId": tab, "action": "left_click", "coordinate": [120, 330]])
        await pollUntil(timeout: 5) { (try? await self.js("clicks", tab: tab)) as? Int == 1 }

        let clicks = try await js("clicks", tab: tab) as? Int
        XCTAssertEqual(clicks, 1)
    }

    func testClickOnAPageThatSwallowsMouseEventsLandsOnce() async throws {
        let tab = try await agentTab(showing: """
            <!doctype html><body style="margin:0"><script>
            window.clicks = 0
            for (const type of ['mousedown', 'mouseup']) addEventListener(type, e => e.stopImmediatePropagation(), true)
            </script><button style="position:absolute;left:20px;top:20px;width:200px;height:60px" onclick="clicks++">B</button></body>
            """)

        _ = await client.callTool("computer", ["tabId": tab, "action": "left_click", "coordinate": [120, 50]])
        await pollUntil(timeout: 5) { (try? await self.js("clicks", tab: tab)) as? Int == 1 }

        let clicks = try await js("clicks", tab: tab) as? Int
        XCTAssertEqual(clicks, 1)
    }

    func testCursorShowsWhereTheAgentClickedUntilItLetsGo() async throws {
        let tab = try await agentTab(showing: Self.page)
        // Shown, the tab outlives its agent for the check below.
        window.switchToSpace(try XCTUnwrap(agentsSpaceId))
        let webView = try engine(forTab: tab).wkWebView

        _ = await client.callTool("computer", ["tabId": tab, "action": "left_click", "coordinate": [120, 50]])
        let cursor = try XCTUnwrap(webView.subviews.first { $0 is AgentCursorView } as? AgentCursorView)
        let arrow = try XCTUnwrap(cursor.subviews.first { $0 is NSImageView }).frame
        control.stopAll()
        await pollUntil { !webView.subviews.contains { $0 is AgentCursorView } }

        XCTAssertEqual(arrow.minX + AgentCursorView.hotSpot.x, 120, accuracy: 0.5)
        XCTAssertEqual(arrow.minY + AgentCursorView.hotSpot.y, 50, accuracy: 0.5)
        XCTAssertFalse(webView.subviews.contains { $0 is AgentCursorView }, "the cursor goes with the agent")
    }

    func testAControlledTabIsFramedAndSaysWhichAgentHasIt() async throws {
        let tab = try await agentTab(showing: Self.page)
        window.switchToSpace(try XCTUnwrap(agentsSpaceId))
        let webView = try engine(forTab: tab).wkWebView

        let frame = try XCTUnwrap(webView.subviews.first { $0 is AgentFrameView } as? AgentFrameView)
        XCTAssertFalse(frame.agentName.isEmpty)
        let badge = frame.subviews.flatMap(\.subviews).compactMap { $0 as? NSTextField }.first
        XCTAssertTrue(badge?.stringValue.contains(frame.agentName) == true)
        // The agent's 1280x800 viewport is larger than the window's content: the badge stays in what it shows.
        let container = try XCTUnwrap(webView.superview)
        let pill = try XCTUnwrap(badge?.superview)
        XCTAssertTrue(container.bounds.contains(pill.convert(pill.bounds, to: container)))

        control.stopAll()
        await pollUntil { !webView.subviews.contains { $0 is AgentFrameView } }
        XCTAssertFalse(webView.subviews.contains { $0 is AgentFrameView }, "the frame goes with the agent")
    }

    func testTheCursorCarriesTheAgentsName() async throws {
        let tab = try await agentTab(showing: Self.page)
        window.switchToSpace(try XCTUnwrap(agentsSpaceId))
        let webView = try engine(forTab: tab).wkWebView

        _ = await client.callTool("computer", ["tabId": tab, "action": "left_click", "coordinate": [120, 150]])
        let cursor = try XCTUnwrap(webView.subviews.first { $0 is AgentCursorView } as? AgentCursorView)
        let frame = try XCTUnwrap(webView.subviews.first { $0 is AgentFrameView } as? AgentFrameView)

        let label = cursor.subviews.flatMap(\.subviews).compactMap { $0 as? NSTextField }.first
        XCTAssertEqual(label?.stringValue, frame.agentName)
    }

    func testStoppedAgentRunsNoFurtherActions() async throws {
        let tab = try await agentTab(showing: Self.page)
        // Shown, the tab outlives its agent for the check below.
        window.switchToSpace(try XCTUnwrap(agentsSpaceId))
        let batch = Task { [client] in
            await client!.callTool("browser_batch", ["actions": [
                ["name": "computer", "input": ["tabId": tab, "action": "wait", "duration": 1]],
                ["name": "computer", "input": ["tabId": tab, "action": "left_click", "coordinate": [120, 50]]]
            ]])
        }
        let session = try XCTUnwrap(control.sessions.first)
        await pollUntil(timeout: 5) { session.activeCalls == 1 }

        control.stopAll()
        _ = await batch.value
        try await Task.sleep(for: .seconds(1))

        let clicks = try await js("clicks", tab: tab) as? Int
        XCTAssertEqual(clicks, 0, "the click after Stop never happens")
    }

    func testScrollMovesPage() async throws {
        let tab = try await agentTab(showing: Self.page)

        _ = await client.callTool("computer", ["tabId": tab, "action": "scroll", "coordinate": [400, 300], "scroll_direction": "down", "scroll_amount": 3])

        let offset = try await js("scrollY", tab: tab) as? Double
        XCTAssertEqual(offset, 300)
    }

    func testDragGoesFromStartToEnd() async throws {
        let tab = try await agentTab(showing: Self.page)

        _ = await client.callTool("computer", ["tabId": tab, "action": "left_click_drag", "start_coordinate": [310, 100], "coordinate": [500, 100]])

        let drag = try await js("drag", tab: tab) as? [String]
        XCTAssertEqual(drag?.first, "down 10")
        XCTAssertEqual(drag?.last, "up 200")
        let moves = drag?.filter { $0.hasPrefix("move") } ?? []
        XCTAssertFalse(moves.isEmpty)
        XCTAssertEqual(Set(moves), ["move buttons 1"], "a drag moves with the left button held, not as a hover")
    }

    func testAPressHoldsItsButton() async throws {
        let tab = try await agentTab(showing: Self.page)

        _ = await client.callTool("computer", ["tabId": tab, "action": "left_click", "coordinate": [400, 100]])

        let presses = try await js("presses", tab: tab) as? [String]
        XCTAssertEqual(presses, ["0:1"], "a pressed button reads as held, like a real press")
    }

    func testClickingAVisibleRefLeavesTheScrollAlone() async throws {
        let tab = try await agentTab(showing: Self.page)
        _ = try await js("scrollTo(0, 50)", tab: tab)
        let found = await client.callTool("find", ["tabId": tab, "query": #"button "C""#]).text
        let ref = try XCTUnwrap(found.range(of: #"ref_\d+"#, options: .regularExpression).map { String(found[$0]) })

        _ = await client.callTool("computer", ["tabId": tab, "action": "left_click", "ref": ref])

        let offset = try await js("scrollY", tab: tab) as? Double
        XCTAssertEqual(offset, 50, "the element was on screen: the page stays where the last screenshot showed it")
    }

    func testViewportKeepsItsSizeWhenTheUserShowsTheAgentsSpace() async throws {
        let tab = try await agentTab(showing: Self.page)
        let parked = await client.callTool("computer", ["tabId": tab, "action": "screenshot"]).text

        window.switchToSpace(try XCTUnwrap(agentsSpaceId))
        let shown = await client.callTool("computer", ["tabId": tab, "action": "screenshot"]).text

        XCTAssertTrue(parked.hasSuffix("1280x800"), parked)
        XCTAssertTrue(shown.hasSuffix("1280x800"), "the user's window is 1000x650: \(shown)")
    }

    func testAgentTabIgnoresTheWindowsDefaultZoom() async throws {
        context.settingsStore.defaultZoom = 0.8
        defer { context.settingsStore.defaultZoom = 1 }
        let tab = try await newAgentTab()

        _ = await client.callTool("navigate", ["tabId": tab, "url": "data:text/html,<p>page</p>"])

        XCTAssertEqual(try engine(forTab: tab).pageZoom, 1, accuracy: 0.001)
        let width = try await js("innerWidth", tab: tab) as? Int
        XCTAssertEqual(width, 1280, "resize_window sizes stay CSS pixels")
    }

    func testClickByRefOnACoveredElementSaysWhatCoversIt() async throws {
        let tab = try await agentTab(showing: """
            <!doctype html><body style="margin:0"><button style="margin:20px" onclick="clicks++">Details</button>
            <div id="consent" style="position:fixed;inset:0;background:#0003"></div><script>window.clicks = 0</script></body>
            """)
        let found = await client.callTool("find", ["tabId": tab, "query": #"button "Details""#]).text
        let ref = try XCTUnwrap(found.range(of: #"ref_\d+"#, options: .regularExpression).map { String(found[$0]) }, found)

        let reply = await client.callTool("computer", ["tabId": tab, "action": "left_click", "ref": ref])

        XCTAssertTrue(reply.isError, reply.text)
        XCTAssertTrue(reply.text.contains("div#consent"), reply.text)
        let clicks = try await js("clicks", tab: tab) as? Int
        XCTAssertEqual(clicks, 0)
    }

    func testClickByRefReachesAnItemAScrolledSidebarCrops() async throws {
        let buttons = (0..<30).map { #"<button id="b\#($0)" style="display:block;height:40px" onclick="hit=this.id">Item \#($0)</button>"# }
        let tab = try await agentTab(showing: """
            <!doctype html><body style="margin:0"><div style="height:300px;overflow:auto">\(buttons.joined())</div>
            <div style="height:600px" onclick="hit='footer'">Footer</div><script>window.hit = ''</script></body>
            """)
        let found = await client.callTool("find", ["tabId": tab, "query": #"button "Item 12""#]).text
        let ref = try XCTUnwrap(found.range(of: #"ref_\d+"#, options: .regularExpression).map { String(found[$0]) }, found)

        _ = await client.callTool("computer", ["tabId": tab, "action": "left_click", "ref": ref])

        let hit = try await js("hit", tab: tab) as? String
        XCTAssertEqual(hit, "b12")
    }

    func testClickThatLeavesThePageWaitsForTheNextOne() async throws {
        let server = try await TinyHTTPServer { request in
            guard request.hasPrefix("GET /next") else {
                return ("200 OK", ["Content-Type: text/html"], Data(#"<body style="margin:0"><a href="/next" style="display:block;width:200px;height:60px">Go</a>"#.utf8))
            }
            // A slow server: the old page stays shown meanwhile.
            Thread.sleep(forTimeInterval: 0.3)
            return ("200 OK", ["Content-Type: text/html"], Data("<button>Arrived</button>".utf8))
        }
        let tab = try await newAgentTab()
        _ = await client.callTool("navigate", ["tabId": tab, "url": "127.0.0.1:\(server.port)/"])

        _ = await client.callTool("computer", ["tabId": tab, "action": "left_click", "coordinate": [100, 30]])
        let found = await client.callTool("find", ["tabId": tab, "query": "Arrived"]).text

        XCTAssertTrue(found.contains(#"button "Arrived""#), found)
    }

    func testCloseSkipsTheBeforeunloadPrompt() async throws {
        let tab = try await agentTab(showing: #"<body style="height:500px"><script>addEventListener('beforeunload', e => e.preventDefault())</script>"#)
        // Only a window showing the tab asks its page before closing it.
        window.switchToSpace(try XCTUnwrap(agentsSpaceId))
        // WebKit runs the handler only on a page the user interacted with.
        _ = await client.callTool("computer", ["tabId": tab, "action": "left_click", "coordinate": [100, 100]])

        let reply = await client.callTool("tabs_close_mcp", ["tabId": tab])

        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertNil(window.window?.attachedSheet, "no leave confirmation waits in the user's window")
    }

    func testParkedTabLeavesWithoutABeforeunloadPrompt() async throws {
        let tab = try await agentTab(showing: """
            <body style="margin:0"><script>addEventListener('beforeunload', e => e.preventDefault())</script>
            <a href="about:blank" style="display:block;width:300px;height:100px">Leave</a></body>
            """)
        let engine = try engine(forTab: tab)
        XCTAssertTrue(engine.view.window === control.parkingWindow)

        _ = await client.callTool("computer", ["tabId": tab, "action": "left_click", "coordinate": [100, 50]])

        let left = await pollUntil { engine.wkWebView.url?.absoluteString == "about:blank" }
        XCTAssertTrue(left, "the link navigation completes instead of waiting on an unseen prompt")
        XCTAssertNil(control.parkingWindow.attachedSheet)
        let console = await client.callTool("read_console_messages", ["tabId": tab])
        XCTAssertTrue(console.text.contains("beforeunload: left the page"), console.text)
    }

    func testOutOfRangeNumbersAreRefusedOrClampedNeverTrapping() async throws {
        let tab = try await agentTab(showing: Self.page)

        let console = await client.callTool("read_console_messages", ["tabId": tab, "limit": -5])
        let network = await client.callTool("read_network_requests", ["tabId": tab, "limit": 1e300])
        let keys = await client.callTool("computer", ["tabId": tab, "action": "key", "text": "a", "repeat": 1e300])
        let wait = await client.callTool("computer", ["tabId": tab, "action": "wait", "duration": "nan"])
        let scroll = await client.callTool("computer", ["tabId": tab, "action": "scroll", "coordinate": [100, 100], "scroll_amount": 1e12])
        let click = await client.callTool("computer", ["tabId": tab, "action": "left_click", "coordinate": [1e300, 10]])
        let resize = await client.callTool("resize_window", ["tabId": tab, "width": 1e300, "height": 600])

        for reply in [console, network, keys, wait, scroll] { XCTAssertFalse(reply.isError, reply.text) }
        XCTAssertTrue(click.isError, click.text)
        XCTAssertTrue(resize.isError, resize.text)
    }

    func testResizeChangesViewportNotWindow() async throws {
        let tab = try await agentTab(showing: Self.page)
        let frame = window.window?.frame

        _ = await client.callTool("resize_window", ["tabId": tab, "width": 375, "height": 600])

        let width = try await js("innerWidth", tab: tab) as? Int
        XCTAssertEqual(width, 375)
        XCTAssertEqual(window.window?.frame, frame)
    }

    func testResizedViewportSurvivesTheViewMovingAndANavigation() async throws {
        let tab = try await agentTab(showing: Self.page)
        _ = await client.callTool("resize_window", ["tabId": tab, "width": 375, "height": 600])

        // As when the window that showed the tab stops showing it: the next call parks the view again.
        try engine(forTab: tab).view.removeFromSuperview()
        _ = await client.callTool("navigate", ["tabId": tab, "url": "reload"])

        let size = try await js("[innerWidth, innerHeight]", tab: tab) as? [Int]
        XCTAssertEqual(size, [375, 600])
    }

    func testResizedViewportAndZoomSurviveTheUserShowingTheTab() async throws {
        let tab = try await agentTab(showing: Self.page)
        try engine(forTab: tab).setPageZoom(0.8)
        _ = await client.callTool("resize_window", ["tabId": tab, "width": 375, "height": 600])

        window.switchToSpace(try XCTUnwrap(agentsSpaceId))
        window.activateTabStateFirst(id: try engine(forTab: tab).id)

        XCTAssertEqual(try engine(forTab: tab).view.frame.size, CGSize(width: 375, height: 600))
        XCTAssertEqual(try engine(forTab: tab).pageZoom, 0.8, accuracy: 0.001)
    }

    func testHoverReachesThePage() async throws {
        let tab = try await agentTab(showing: """
            <!doctype html><body style="margin:0"><div id="t" style="width:200px;height:200px"></div>
            <script>window.seen = []; for (const type of ['mouseover', 'mouseenter', 'mousemove', 'pointerover'])
            t.addEventListener(type, () => seen.includes(type) || seen.push(type))</script></body>
            """)

        // WebKit drops pointer events right after a load: a click waits until the page takes them.
        _ = await client.callTool("computer", ["tabId": tab, "action": "left_click", "coordinate": [400, 400]])
        _ = await client.callTool("computer", ["tabId": tab, "action": "hover", "coordinate": [100, 100]])
        await pollUntil { (try? await self.js("seen.length", tab: tab) as? Int) == 4 }

        let seen = try await js("seen", tab: tab) as? [String]
        XCTAssertEqual(Set(seen ?? []), ["mouseover", "mouseenter", "mousemove", "pointerover"])
    }

    func testTypeReturnsOnceThePageHasEveryKey() async throws {
        let tab = try await agentTab(showing: """
            <!doctype html><body style="margin:0"><input id="f" style="position:absolute;left:20px;top:20px;width:200px;height:30px"></body>
            """)
        _ = await client.callTool("computer", ["tabId": tab, "action": "left_click", "coordinate": [120, 35]])

        _ = await client.callTool("computer", ["tabId": tab, "action": "type", "text": "every key landed"])

        let value = try await js("f.value", tab: tab) as? String
        XCTAssertEqual(value, "every key landed", "read right after the call, with no wait")
    }

    func testSelectAllThenDeleteEmptiesAField() async throws {
        let tab = try await agentTab(showing: """
            <!doctype html><body style="margin:0"><input id="f" value="hello" style="position:absolute;left:20px;top:20px;width:200px;height:30px"></body>
            """)
        _ = await client.callTool("computer", ["tabId": tab, "action": "left_click", "coordinate": [120, 35]])

        _ = await client.callTool("computer", ["tabId": tab, "action": "key", "text": "cmd+a Delete"])

        await pollUntil { (try? await self.js("f.value", tab: tab) as? String) == "" }
        let value = try await js("f.value", tab: tab) as? String
        XCTAssertEqual(value, "")
    }

    func testTimeoutExtendsTheDeadlineOfAScript() async throws {
        let tab = try await newAgentTab()
        AgentMCP.toolDeadline = 1
        defer { AgentMCP.toolDeadline = 60 }

        let reply = await client.callTool("javascript_tool", [
            "tabId": tab, "action": "javascript_exec", "text": "await new Promise(r => setTimeout(() => r('late'), 1500))", "timeout": 5
        ])

        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertEqual(reply.text, "\"late\"")
    }

    func testDialogsNeverOpenSheets() async throws {
        let tab = try await agentTab(showing: Self.page)

        _ = await client.callTool("computer", ["tabId": tab, "action": "left_click", "coordinate": [120, 150]])
        var console = (text: "", isError: false, images: [Data]())
        await pollUntil {
            console = await self.client.callTool("read_console_messages", ["tabId": tab])
            return console.text.contains("alert(hi) dismissed")
        }

        XCTAssertNil(window.window?.attachedSheet)
        XCTAssertTrue(console.text.contains("alert(hi) dismissed"), console.text)
    }

    func testLeavingAPageThatAsksToStayNeverOpensASheet() async throws {
        let tab = try await agentTab(showing: """
            <!doctype html><body style="margin:0;height:100vh"><script>onbeforeunload = e => { e.preventDefault(); return "" }</script></body>
            """)
        // WebKit only asks after a user gesture on the page.
        _ = await client.callTool("computer", ["tabId": tab, "action": "left_click", "coordinate": [100, 100]])

        let reply = await client.callTool("navigate", ["tabId": tab, "url": "data:text/html,<title>Next</title>"])

        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertNil(window.window?.attachedSheet)
        let title = try await js("document.title", tab: tab) as? String
        XCTAssertEqual(title, "Next")
    }

    func testCancelledWaitStopsAndGetsNoReply() async throws {
        let tab = try await newAgentTab()
        let session = try XCTUnwrap(control.sessions.first)
        let started = Date()
        client.send(["jsonrpc": "2.0", "id": 900, "method": "tools/call", "params": [
            "name": "computer", "arguments": ["tabId": tab, "action": "wait", "duration": 10]
        ]])
        await pollUntil(timeout: 5) { session.activeCalls == 1 }

        client.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 900]])
        let stopped = await pollUntil(timeout: 5) { session.activeCalls == 0 }
        let ping = await client.request("ping")

        XCTAssertTrue(stopped)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertNotNil(ping, "the next reply is the ping's: the cancelled call got none")
        XCTAssertTrue(session.requests.isEmpty)
    }

    func testDisconnectStopsCallsInFlight() async throws {
        let tab = try await newAgentTab()
        let session = try XCTUnwrap(control.sessions.first)
        client.send(["jsonrpc": "2.0", "id": 900, "method": "tools/call", "params": [
            "name": "computer", "arguments": ["tabId": tab, "action": "wait", "duration": 10]
        ]])
        await pollUntil(timeout: 5) { session.activeCalls == 1 }

        client.close()

        let stopped = await pollUntil(timeout: 5) { session.activeCalls == 0 }
        XCTAssertTrue(stopped, "the agent reads as idle once it left")
    }

    func testCallPastTheDeadlineReportsAnError() async throws {
        let tab = try await newAgentTab()
        AgentMCP.toolDeadline = 1
        defer { AgentMCP.toolDeadline = 60 }

        let reply = await client.callTool("javascript_tool", ["tabId": tab, "action": "javascript_exec", "text": "await new Promise(() => {})"])

        XCTAssertTrue(reply.isError)
        XCTAssertTrue(reply.text.contains("did not finish within 1 s"), reply.text)
        XCTAssertEqual(control.sessions.first?.activeCalls, 0)
    }

    func testRecordingExportsGIF() async throws {
        let tab = try await agentTab(showing: Self.page)
        let name = "lilo-agent-test-\(UUID().uuidString.prefix(8)).gif"
        _ = await client.callTool("gif_creator", ["tabId": tab, "action": "start_recording"])
        _ = await client.callTool("computer", ["tabId": tab, "action": "left_click", "coordinate": [120, 50]])
        _ = await client.callTool("gif_creator", ["tabId": tab, "action": "stop_recording"])

        let reply = await client.callTool("gif_creator", ["tabId": tab, "action": "export", "filename": name])

        let path = try XCTUnwrap(reply.text.components(separatedBy: " to ").last)
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(reply.text.hasPrefix("Saved 2 frames"), reply.text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }
}
