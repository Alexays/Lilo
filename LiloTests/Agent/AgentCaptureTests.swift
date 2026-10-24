import XCTest
@testable import Lilo

@MainActor
final class AgentCaptureTests: AgentToolTestCase {
    private static let page = """
    <!doctype html><body>
    <button style="position:absolute;left:20px;top:20px;width:200px;height:60px" onclick="fail()">Fail</button>
    <input type="file" id="file" style="position:absolute;left:20px;top:120px">
    <script>
    function fail() { console.error('bad thing'); console.log('fine thing'); Promise.reject(new Error('rejected')) }
    </script></body>
    """

    func testConsoleCapturesErrorsAndRejections() async throws {
        let tab = try await agentTab(showing: Self.page)
        _ = await client.callTool("read_console_messages", ["tabId": tab])

        _ = await client.callTool("computer", ["tabId": tab, "action": "left_click", "coordinate": [120, 50]])
        var errors = (text: "", isError: false, images: [Data]())
        await pollUntil {
            errors = await self.client.callTool("read_console_messages", ["tabId": tab, "onlyErrors": true])
            return errors.text.contains("rejected")
        }

        XCTAssertTrue(errors.text.contains("bad thing"), errors.text)
        XCTAssertTrue(errors.text.contains("rejected"), errors.text)
        XCTAssertFalse(errors.text.contains("fine thing"))
    }

    func testRejectionsOfOtherFramesAndNonErrorsReadUsefully() async throws {
        let tab = try await agentTab(showing: "<!doctype html><body><iframe srcdoc='<p>frame</p>'></iframe></body>")
        _ = await client.callTool("read_console_messages", ["tabId": tab])
        await pollUntil { (try? await self.js("!!document.querySelector('iframe').contentWindow?.Error", tab: tab)) as? Bool == true }

        _ = try await js("""
            Promise.reject(new (document.querySelector('iframe').contentWindow.Error)('from the frame'))
            Promise.reject(new (class Custom {})())
            Promise.reject(undefined)
            1
            """, tab: tab)
        var errors = (text: "", isError: false, images: [Data]())
        await pollUntil {
            errors = await self.client.callTool("read_console_messages", ["tabId": tab, "onlyErrors": true])
            return errors.text.components(separatedBy: "Unhandled rejection").count > 3
        }

        XCTAssertTrue(errors.text.contains("Error: from the frame"), errors.text)
        XCTAssertTrue(errors.text.contains("[object Custom]"), errors.text)
        XCTAssertTrue(errors.text.contains("Unhandled rejection: undefined"), errors.text)
        XCTAssertFalse(errors.text.contains("{}"), errors.text)
    }

    func testConsoleHookNotInstalledOnUserTabs() async throws {
        _ = try await agentTab(showing: Self.page)
        let user = try XCTUnwrap(window.tabManager.activeEngineTab)

        let hooked = try await user.wkWebView.evaluateJavaScript("typeof window.__liloConsole") as? String

        XCTAssertEqual(hooked, "undefined")
    }

    func testNetworkLists404WithStatus() async throws {
        let server = try await TinyHTTPServer(index: #"<!doctype html><img src="/missing.png"><p>served</p>"#)
        let tab = try await newAgentTab()
        _ = await client.callTool("navigate", ["tabId": tab, "url": "127.0.0.1:\(server.port)/"])
        var reply = (text: "", isError: false, images: [Data]())
        await pollUntil {
            reply = await self.client.callTool("read_network_requests", ["tabId": tab])
            return reply.text.contains(" 404 ")
        }

        let missing = try XCTUnwrap(reply.text.split(separator: "\n").first { $0.contains("missing.png") }, reply.text)
        XCTAssertTrue(missing.contains(" 404 "), String(missing))
        XCTAssertTrue(reply.text.contains("GET 200 http://127.0.0.1:\(server.port)/"), reply.text)
    }

    func testNetworkLeavesOutExcludedURLs() async throws {
        let server = try await TinyHTTPServer(index: #"<!doctype html><img src="/node_modules/.vite/dep.png"><img src="/api/data.png"><p>served</p>"#)
        let tab = try await newAgentTab()
        _ = await client.callTool("navigate", ["tabId": tab, "url": "127.0.0.1:\(server.port)/"])
        var reply = (text: "", isError: false, images: [Data]())
        await pollUntil {
            reply = await self.client.callTool("read_network_requests", ["tabId": tab, "exclude": ["/node_modules/"]])
            return reply.text.contains("/api/data.png")
        }

        XCTAssertTrue(reply.text.contains("/api/data.png"), reply.text)
        XCTAssertFalse(reply.text.contains("/node_modules/"), reply.text)
    }

    func testInspectorRequestIdWithoutTheInspectorSaysSo() async throws {
        let tab = try await newAgentTab()

        let reply = await client.callTool("read_network_requests", ["tabId": tab, "requestId": "0.16620"])

        XCTAssertTrue(reply.text.contains("No request 0.16620: the inspector"), reply.text)
    }

    func testFileUploadFillsInputWithoutPanel() async throws {
        let tab = try await agentTab(showing: Self.page)
        let file = FileManager.default.temporaryDirectory.appending(path: "agent-upload-\(UUID().uuidString.prefix(6)).txt")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let found = await client.callTool("find", ["tabId": tab, "query": "file"]).text
        let ref = try XCTUnwrap(found.range(of: #"ref_\d+"#, options: .regularExpression).map { String(found[$0]) }, found)

        let upload = Task { await client.callTool("file_upload", ["tabId": tab, "ref": ref, "paths": [file.path]]) }
        let asked = await pollUntil(timeout: 5) { !self.control.pendingConsentAnswers.isEmpty }
        XCTAssertTrue(asked, "the user allows the file first")
        control.answerConsent(try XCTUnwrap(control.pendingConsentAnswers.keys.first), granted: true)
        let reply = await upload.value

        XCTAssertFalse(reply.isError, reply.text)
        // The chosen files reach the page's input after the tool answers.
        let filled = await pollUntil { (try? await self.js("document.getElementById('file').files[0]?.name", tab: tab)) as? String == file.lastPathComponent }
        XCTAssertTrue(filled)
        XCTAssertNil(window.window?.attachedSheet)
    }

    func testADeniedUploadNeedsTheUserAndLeavesTheInputEmpty() async throws {
        let tab = try await agentTab(showing: Self.page)
        let file = FileManager.default.temporaryDirectory.appending(path: "agent-upload-\(UUID().uuidString.prefix(6)).png")
        try Data("secret".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let found = await client.callTool("find", ["tabId": tab, "query": "file"]).text
        let ref = try XCTUnwrap(found.range(of: #"ref_\d+"#, options: .regularExpression).map { String(found[$0]) }, found)

        let upload = Task { await client.callTool("upload_image", ["tabId": tab, "ref": ref, "path": file.path]) }
        let asked = await pollUntil(timeout: 5) { !self.control.pendingConsentAnswers.isEmpty }
        XCTAssertTrue(asked, "the user is asked")
        control.answerConsent(try XCTUnwrap(control.pendingConsentAnswers.keys.first), granted: false)
        let reply = await upload.value

        XCTAssertTrue(reply.text.hasPrefix("[needs_user]"), reply.text)
        let count = try await js("document.getElementById('file').files.length", tab: tab) as? Int
        XCTAssertEqual(count, 0)
    }

    func testBatchStopsAtFirstError() async throws {
        let tab = try await agentTab(showing: Self.page)

        let reply = await client.callTool("browser_batch", ["actions": [
            ["name": "find", "input": ["tabId": tab, "query": "Fail"]],
            ["name": "no_such_tool", "input": [:]],
            ["name": "computer", "input": ["tabId": tab, "action": "left_click", "coordinate": [120, 50]]]
        ]])

        XCTAssertTrue(reply.isError)
        XCTAssertTrue(reply.text.contains("Action 2 (no_such_tool) failed"), reply.text)
        XCTAssertTrue(reply.text.contains(#"button "Fail""#), "the first action's result is kept")
        let errors = await client.callTool("read_console_messages", ["tabId": tab, "onlyErrors": true])
        XCTAssertFalse(errors.text.contains("bad thing"), "the third action never ran")
    }

    func testEveryEmulationFieldTakesNullToResetIt() async throws {
        let tools = (await client.request("tools/list"))?["tools"] as? [[String: Any]] ?? []
        let schema = tools.first { $0["name"] as? String == "emulate" }?["inputSchema"] as? [String: Any]
        let fields = try XCTUnwrap(schema?["properties"] as? [String: [String: Any]]).filter { !["tabId", "reset"].contains($0.key) }

        // A client checks arguments against the schema: a type without null refuses the reset before Lilo sees it.
        for (name, field) in fields {
            XCTAssertTrue((field["type"] as? [String])?.contains("null") == true, name)
            if let choices = field["enum"] as? [Any] { XCTAssertTrue(choices.contains { $0 is NSNull }, name) }
        }
    }

    func testToolsAreListed() async throws {
        let tools = (await client.request("tools/list"))?["tools"] as? [[String: Any]] ?? []

        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), [
            "tabs_context_mcp", "tabs_create_mcp", "tabs_close_mcp", "navigate", "computer", "read_page", "find", "form_input",
            "get_page_text", "javascript_tool", "read_console_messages", "read_network_requests", "resize_window", "file_upload",
            "upload_image", "gif_creator", "browser_batch", "list_connected_browsers", "select_browser", "switch_browser",
            "list_profiles", "switch_profile", "reset_profile", "fetch", "run",
            "devtools_command", "devtools_events", "network_mock", "network_response", "cookies", "emulate", "performance"
        ])
    }
}
