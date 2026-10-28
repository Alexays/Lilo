import XCTest
@testable import Lilo

/// What a page of an agent tab would otherwise raise over the user's window: answered at once.
@MainActor
final class AgentUnattendedTests: AgentToolTestCase {
    func testPermissionRequestsAreDeniedWithoutAPrompt() async throws {
        let tab = try await newAgentTab()
        var granted: Bool?

        window.requestSitePermission(type: "location", origin: "http://127.0.0.1", webView: try engine(forTab: tab).wkWebView) { granted = $0 }
        let console = await client.callTool("read_console_messages", ["tabId": tab])

        XCTAssertEqual(granted, false)
        XCTAssertTrue(console.text.contains("denied: agent tabs never ask the user"), console.text)
        XCTAssertTrue(window.pendingPermissionRequests.isEmpty)
    }

    func testHTTPAuthShowsNoSheetAndTakesTheURLCredentials() async throws {
        let expected = "Authorization: Basic \(Data("ann:secret".utf8).base64EncodedString())"
        let server = try await TinyHTTPServer { request in
            request.contains(expected)
                ? ("200 OK", ["Content-Type: text/html"], Data("<p>welcome</p>".utf8))
                : ("401 Unauthorized", ["Content-Type: text/html", #"WWW-Authenticate: Basic realm="dev""#], Data("<p>denied</p>".utf8))
        }
        let tab = try await newAgentTab()

        _ = await client.callTool("navigate", ["tabId": tab, "url": "http://127.0.0.1:\(server.port)/"])
        let refused = await client.callTool("get_page_text", ["tabId": tab])
        let console = await client.callTool("read_console_messages", ["tabId": tab])
        _ = await client.callTool("navigate", ["tabId": tab, "url": "http://ann:secret@127.0.0.1:\(server.port)/"])
        let signedIn = await client.callTool("get_page_text", ["tabId": tab])

        XCTAssertTrue(refused.text.contains("denied"), refused.text)
        XCTAssertTrue(console.text.contains("asks for a sign-in"), console.text)
        XCTAssertNil(window.window?.attachedSheet)
        XCTAssertTrue(signedIn.text.contains("welcome"), signedIn.text)
    }

    func testDownloadsOfAgentTabsSkipTheSavePanel() async throws {
        context.settingsStore.askDownloadLocation = true
        window.setupDownloads()
        let tab = try await newAgentTab()
        let choose = try XCTUnwrap(context.downloadManager.chooseDestination)
        let proposed = URL(fileURLWithPath: "/tmp/report.csv")

        let chosen = await choose(proposed, try engine(forTab: tab).wkWebView, false)
        let console = await client.callTool("read_console_messages", ["tabId": tab])

        XCTAssertEqual(chosen, proposed)
        XCTAssertTrue(console.text.contains("Download saved to /tmp/report.csv"), console.text)
    }
}
