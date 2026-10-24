import WebKit
import XCTest
@testable import Lilo

@MainActor
final class WKWebViewTabTeardownTests: XCTestCase {
    func testTeardownCanRunMoreThanOnce() {
        let tab = WKWebViewTab(configuration: WKWebViewConfiguration())

        tab.teardown()
        tab.teardown()
    }

    func testTeardownStopsThePageEvenWhileTheWebViewIsStillHeld() async throws {
        let tab = WKWebViewTab(configuration: WKWebViewConfiguration())
        let webView = tab.wkWebView
        webView.loadHTMLString("<p>live</p>", baseURL: nil)
        // The initial about:blank already reads complete: wait for this page's own content.
        try await waitForJavaScript(tab, "document.readyState === 'complete' && document.body?.textContent === 'live'")

        tab.teardown()

        do {
            _ = try await webView.evaluateJavaScript("1")
            XCTFail("A torn-down page must not run scripts")
        } catch {}
    }

    func testFactoryEnablesPictureInPictureMediaPlaybackForContentTabs() throws {
        let tab = WKEngineFactory().createTab(configuration: WKEngineFactory.Configuration())
        defer { tab.teardown() }

        guard let allowsPictureInPicture = Self.boolPreference("allowsPictureInPictureMediaPlayback", in: tab.wkWebView.configuration.preferences) else {
            throw XCTSkip("WKPreferences does not expose Picture-in-Picture playback state")
        }
        XCTAssertTrue(allowsPictureInPicture)
    }

    func testFactoryEnablesMediaDevicesForContentTabs() throws {
        let tab = WKEngineFactory().createTab(configuration: WKEngineFactory.Configuration())
        defer { tab.teardown() }

        guard let mediaDevicesEnabled = Self.boolPreference("mediaDevicesEnabled", in: tab.wkWebView.configuration.preferences) else {
            throw XCTSkip("WKPreferences does not expose media devices playback state")
        }
        XCTAssertTrue(mediaDevicesEnabled)
    }

    func testSyntheticWarmPoolAboutBlankDoesNotOverwritePendingNavigation() {
        let tab = WKWebViewTab(configuration: WKWebViewConfiguration())
        defer { tab.teardown() }

        let spy = WKWebViewTabDelegateSpy()
        tab.delegate = spy

        let targetURL = URL(string: "https://example.com/page")!
        let aboutBlank = URL(string: "about:blank")!
        let aboutBlankUpdate = expectation(description: "about:blank update should be ignored")
        aboutBlankUpdate.isInverted = true

        spy.onUpdateURL = { url in
            if url == aboutBlank {
                aboutBlankUpdate.fulfill()
            }
        }

        tab.loadURL(targetURL)
        tab.wkWebView.load(URLRequest(url: aboutBlank))

        wait(for: [aboutBlankUpdate], timeout: 0.2)

        XCTAssertFalse(spy.updatedURLs.contains(aboutBlank))
        XCTAssertEqual(tab.currentURL, targetURL)
    }

    func testTogglePictureInPictureUsesPageVideoWhenNativeToggleIsUnavailable() async throws {
        let videoURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/SetupAssistantSupportUI.framework/Versions/A/Resources/newFeaturesVideo-en~mac.mp4")
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw XCTSkip("System sample video is unavailable")
        }

        let htmlURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lilo-pip-\(UUID().uuidString).html")
        try Self.pictureInPictureProbeHTML(videoURL: videoURL).write(to: htmlURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: htmlURL) }

        let tab = WKEngineFactory().createTab(configuration: WKEngineFactory.Configuration())
        tab.view.frame = NSRect(x: 0, y: 0, width: 900, height: 520)
        let window = NSWindow(contentRect: tab.view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = tab.view
        window.makeKeyAndOrderFront(nil)
        defer {
            tab.wkWebView.closeAllMediaPresentations(completionHandler: nil)
            tab.teardown()
            window.close()
        }

        tab.wkWebView.loadFileURL(htmlURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        try await waitForJavaScript(tab, "document.getElementById('v')?.readyState >= 3")
        _ = try await tab.wkWebView.evaluateJavaScript("document.getElementById('v').play(); true")
        try await waitForJavaScript(tab, "!document.getElementById('v').paused")
        let initialMode = try await videoPresentationMode(tab)
        XCTAssertEqual(initialMode, "inline")

        tab.togglePictureInPicture()

        try await waitForJavaScript(tab, "document.getElementById('v').webkitPresentationMode === 'picture-in-picture'")
        let pictureInPictureMode = try await videoPresentationMode(tab)
        XCTAssertEqual(pictureInPictureMode, "picture-in-picture")
    }

    private static func boolPreference(_ key: String, in preferences: WKPreferences) -> Bool? {
        let selector = NSSelectorFromString("_\(key)")
        let object = preferences as NSObject
        guard object.responds(to: selector) else { return nil }
        typealias BoolMethod = @convention(c) (NSObject, Selector) -> Bool
        return unsafeBitCast(object.method(for: selector), to: BoolMethod.self)(object, selector)
    }

    private static func pictureInPictureProbeHTML(videoURL: URL) -> String {
        """
        <!doctype html>
        <body style="margin:0;background:#111">
          <video id="v" src="\(videoURL.absoluteString)" controls muted autoplay playsinline style="width:900px;height:500px"></video>
        </body>
        """
    }

    private func videoPresentationMode(_ tab: WKWebViewTab) async throws -> String? {
        try await tab.wkWebView.evaluateJavaScript("document.getElementById('v').webkitPresentationMode") as? String
    }

    private func waitForJavaScript(_ tab: WKWebViewTab, _ condition: String, timeout: TimeInterval = 5) async throws {
        let met = await pollUntil(timeout: timeout) {
            ((try? await tab.wkWebView.evaluateJavaScript(condition)) as? Bool) == true
        }
        if !met { XCTFail("Timed out waiting for JavaScript condition: \(condition)") }
    }
}
