import os
import WebKit
import XCTest
@testable import Lilo

@MainActor
final class ViewSourceSchemeHandlerTests: XCTestCase {
    /// The re-fetch is the page's own request again: the server sees the user agent its pages get, not CFNetwork's.
    func testTheSourceIsFetchedWithThePagesUserAgent() async throws {
        let requests = OSAllocatedUnfairLock(initialState: [String]())
        let server = try await TinyHTTPServer { request in
            requests.withLock { $0.append(request) }
            return ("200 OK", ["Content-Type: text/html"], Data("<p>source</p>".utf8))
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.applicationNameForUserAgent = WKEngineFactory.safariApplicationName
        let handler = ViewSourceSchemeHandler()
        configuration.setURLSchemeHandler(handler, forURLScheme: ViewSourceSchemeHandler.scheme)
        let webView = WKWebView(frame: .zero, configuration: configuration)

        webView.load(URLRequest(url: try XCTUnwrap(URL(string: "view-source:http://127.0.0.1:\(server.port)/"))))
        _ = await pollUntil(timeout: 60) { !requests.withLock { $0.isEmpty } }
        withExtendedLifetime((webView, handler)) {}

        let request = try XCTUnwrap(requests.withLock { $0.first })
        let userAgent = request.split(separator: "\r\n").first { $0.lowercased().hasPrefix("user-agent:") }
        XCTAssertTrue(userAgent?.hasSuffix(WKEngineFactory.safariApplicationName) == true, "\(userAgent ?? "no user agent")")
    }
}
