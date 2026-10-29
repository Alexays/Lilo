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
        try await verifyReleaseResources(handler: ChromeUISchemeHandler())
    }

    @MainActor
    func testApprovedMaintenanceReleaseNotesAreReadableWithoutRecordings() async throws {
        let version = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let notes = try JSONSerialization.data(withJSONObject: ["version": version, "editorial": ["en": NSNull()]])
        try await verifyReleaseResources(handler: ReleaseNotesSchemeHandler(notes: notes))
    }

    @MainActor
    private func verifyReleaseResources(handler: any WKURLSchemeHandler) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: ChromeUISchemeHandler.scheme)
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
                const notes = await response.json();
                if (!notes.editorial || !Object.hasOwn(notes.editorial, 'en') ||
                    (notes.editorial.en !== null && !Array.isArray(notes.editorial.en?.highlights))) {
                    throw new Error('Missing release editorial');
                }
                for (const highlight of notes.editorial?.en?.highlights ?? []) {
                    const media = highlight.media;
                    if (!media) continue;
                    const recording = await fetch(media.recording);
                    if (!recording.ok) throw new Error('Offline recording unavailable');
                    const blob = await recording.blob();
                    for (let replay = 0; replay < 2; replay++) {
                        const url = URL.createObjectURL(blob);
                        try {
                            const image = new Image();
                            image.src = url;
                            await image.decode();
                            if (image.naturalWidth !== media.width || image.naturalHeight !== media.height) throw new Error('Offline recording failed to decode');
                        } finally { URL.revokeObjectURL(url); }
                    }
                }
                return notes.version;
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
    func testReleaseRecordingsAreAvailableOfflineFromTheChromeOrigin() throws {
        let release = try XCTUnwrap(ChromeUIAssets.assets["release-notes.json"])
        let data = Data(release.text.description.utf8)
        let notes = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let editorial = notes["editorial"] as? [String: [String: Any]]
        let highlights = editorial?["en"]?["highlights"] as? [[String: Any]] ?? []
        for highlight in highlights {
            guard let media = highlight["media"] as? [String: Any], let path = media["recording"] as? String else { continue }
            let task = RecordingSchemeTask("lilo-chrome://ui\(path)")
            ChromeUISchemeHandler().webView(WKWebView(), start: task)
            XCTAssertEqual(task.response?.mimeType, "image/webp")
            XCTAssertEqual(task.data.prefix(4), Data("RIFF".utf8))
        }
        let traversal = RecordingSchemeTask("lilo-chrome://ui/release-media/../Info.plist")
        ChromeUISchemeHandler().webView(WKWebView(), start: traversal)
        XCTAssertNotNil(traversal.error)
    }
}

@MainActor
private final class ReleaseNotesSchemeHandler: NSObject, WKURLSchemeHandler {
    let notes: Data
    private let assets = ChromeUISchemeHandler()

    init(notes: Data) { self.notes = notes }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.path == "/release-notes.json" else {
            assets.webView(webView, start: urlSchemeTask)
            return
        }
        urlSchemeTask.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
        urlSchemeTask.didReceive(notes)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        assets.webView(webView, stop: urlSchemeTask)
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

    init(_ url: String) { request = URLRequest(url: URL(string: url)!) }

    func didReceive(_ response: URLResponse) { self.response = response }
    func didReceive(_ data: Data) { self.data.append(data) }
    func didFinish() {}
    func didFailWithError(_ error: Error) { self.error = error }
}
