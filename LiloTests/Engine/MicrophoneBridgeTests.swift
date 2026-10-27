import AppKit
import WebKit
import XCTest
@testable import Lilo

@MainActor
final class MicrophoneBridgeTests: XCTestCase {
    private final class GrantingDelegate: NSObject, WKUIDelegate {
        func webView(
            _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            decisionHandler(.grant)
        }
    }

    private let bridge = MicrophoneBridge()
    private let delegate = GrantingDelegate()
    private var headphones = true
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)

    override func tearDown() {
        window.orderOut(nil)
        super.tearDown()
    }

    private func makeWebView() async -> WKWebView {
        bridge.usesHeadphones = { [unowned self] in headphones }
        let configuration = WKWebViewConfiguration()
        WKFeatureFlags.apply(["MockCaptureDevicesEnabled": true], to: configuration.preferences)
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: PageWorld.bridgeWorld, name: MicrophoneBridge.messageHandlerName)
        PageWorld.install([MicrophoneBridge.pageModule], on: configuration.userContentController)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = delegate
        // WebKit holds every getUserMedia after the first until the page's window is key.
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        webView.loadHTMLString("<p>call</p>", baseURL: URL(string: "https://example.com/"))
        _ = await pollUntil(timeout: 5) { webView.url != nil && !webView.isLoading }
        return webView
    }

    private func echoCancellation(_ webView: WKWebView, audio: String) async throws -> Bool? {
        try await webView.callAsyncJavaScript("""
            window.track = (await navigator.mediaDevices.getUserMedia({ audio: \(audio) })).getAudioTracks()[0];
            return window.track.getSettings().echoCancellation;
            """, contentWorld: .page) as? Bool
    }

    func testHeadphonesDropEchoCancellationUnlessThePageChose() async throws {
        let webView = await makeWebView()
        let dropped = try await echoCancellation(webView, audio: "{ echoCancellation: true }")
        XCTAssertEqual(dropped, false)
        headphones = false
        let kept = try await echoCancellation(webView, audio: "true")
        XCTAssertEqual(kept, true)
    }

    func testLeavingHeadphonesEndsTheTrackLikeAnUnpluggedMicrophone() async throws {
        let webView = await makeWebView()
        _ = try await echoCancellation(webView, audio: "true")
        _ = try await webView.callAsyncJavaScript("window.track.onended = () => { window.ended = true; };", contentWorld: .page)
        headphones = false
        bridge.outputDidChange()
        let ended = await pollUntil(timeout: 5) {
            (try? await webView.callAsyncJavaScript("return window.ended === true && window.track.readyState === 'ended';", contentWorld: .page)) as? Bool == true
        }
        XCTAssertTrue(ended)
    }
}
