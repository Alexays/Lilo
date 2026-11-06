import WebKit
import XCTest
@testable import Lilo

final class ChromeUISchemeHandlerTests: XCTestCase {
    func testAssetPathMapsURLsToEmbeddedKeys() {
        XCTAssertEqual(
            ChromeUISchemeHandler.assetPath(for: URL(string: "lilo-chrome://ui/index.html")!),
            "index.html"
        )
        XCTAssertEqual(
            ChromeUISchemeHandler.assetPath(for: URL(string: "lilo-chrome://ui/")!),
            "index.html"
        )
        XCTAssertEqual(
            ChromeUISchemeHandler.assetPath(for: URL(string: "lilo-chrome://ui/assets/chunk-abc.js")!),
            "assets/chunk-abc.js"
        )
    }

    func testIndexURLResolvesToTheEmbeddedIndex() {
        XCTAssertNotNil(ChromeUIAssets.assets[ChromeUISchemeHandler.assetPath(for: ChromeUISchemeHandler.indexURL)])
    }

    @MainActor
    func testBundledReleaseNotesAreReadableFromTheChromeOrigin() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(ChromeUISchemeHandler(), forURLScheme: ChromeUISchemeHandler.scheme)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let navigation = ChromeResourceNavigation()
        webView.navigationDelegate = navigation
        defer { webView.stopLoading(); webView.navigationDelegate = nil }
        webView.load(URLRequest(url: ChromeUISchemeHandler.indexURL))
        let loaded = await pollUntil(timeout: 5) { navigation.finished }
        XCTAssertTrue(loaded)
        do {
            let version = try await webView.callAsyncJavaScript("""
                const response = await fetch('/release-notes.json');
                if (!response.ok) throw new Error(`Release resource status: ${response.status}`);
                return (await response.json()).version;
                """, arguments: [:], in: nil, contentWorld: .page)
            XCTAssertEqual(version as? String, Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        } catch {
            let error = error as NSError
            XCTFail("\(error.domain) \(error.code): \(error.userInfo)")
        }
    }

    func testServesThePasswordManagerIconsFromTheAppBundle() {
        let handler = ChromeUISchemeHandler()
        let icon = RecordingSchemeTask("lilo-chrome://ui/password-managers/nngceckbapebfimnlniiiahkandclblb.png")
        handler.webView(WKWebView(), start: icon)
        XCTAssertEqual(icon.response?.mimeType, "image/png")
        XCTAssertEqual(icon.data.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))

        let missing = RecordingSchemeTask("lilo-chrome://ui/password-managers/../Info.plist")
        handler.webView(WKWebView(), start: missing)
        XCTAssertNotNil(missing.error)
        XCTAssertNil(missing.response)
    }

    @MainActor
    func testServesConversationImagesInsideOpenProjectsAndDropsStoppedTasks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        try png.write(to: root.appendingPathComponent("shot.png"))
        try Data("example".utf8).write(to: root.appendingPathComponent("notes.txt"))
        let savedRoots = ChromeUISchemeHandler.conversationRoots
        ChromeUISchemeHandler.conversationRoots = [root.path]
        defer {
            ChromeUISchemeHandler.conversationRoots = savedRoots
            try? FileManager.default.removeItem(at: root)
        }
        let handler = ChromeUISchemeHandler()
        let webView = WKWebView()
        let base = "lilo-chrome://ui/conversation-file"

        let stopped = RecordingSchemeTask("\(base)\(root.path)/shot.png")
        handler.webView(webView, start: stopped)
        handler.webView(webView, stop: stopped)
        let image = RecordingSchemeTask("\(base)\(root.path)/shot.png")
        handler.webView(webView, start: image)
        let text = RecordingSchemeTask("\(base)\(root.path)/notes.txt")
        handler.webView(webView, start: text)
        let outside = RecordingSchemeTask("\(base)\(root.path)/../shot.png")
        handler.webView(webView, start: outside)

        let answered = await pollUntil(timeout: 5) { image.finished && text.error != nil && outside.error != nil }
        XCTAssertTrue(answered)
        XCTAssertEqual(image.response?.mimeType, "image/png")
        XCTAssertEqual(image.data, png)
        XCTAssertNil(text.response)
        XCTAssertNil(outside.response)
        let stoppedAnswered = await pollUntil(timeout: 0.3) { stopped.finished || stopped.error != nil }
        XCTAssertFalse(stoppedAnswered)
    }
}

@MainActor
private final class ChromeResourceNavigation: NSObject, WKNavigationDelegate {
    var finished = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
}

private final class RecordingSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var response: URLResponse?
    var data = Data()
    var error: Error?
    var finished = false

    init(_ url: String) { request = URLRequest(url: URL(string: url)!) }

    func didReceive(_ response: URLResponse) { self.response = response }
    func didReceive(_ data: Data) { self.data.append(data) }
    func didFinish() { finished = true }
    func didFailWithError(_ error: Error) { self.error = error }
}
