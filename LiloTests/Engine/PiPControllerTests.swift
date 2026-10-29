import AppKit
import WebKit
import XCTest
@testable import Lilo

/// Every test opening a system PiP window lives here: there is one such window at a time, so tests in parallel
/// processes would take it from each other.
@MainActor
final class PiPControllerTests: XCTestCase {
    /// A still video WebKit passes over (no playback), so PiP goes through the fallback script.
    static let stillVideo = """
    <video id="v" playsinline style="width: 320px; height: 180px"></video>
    <script>
    const canvas = document.createElement('canvas');
    canvas.getContext('2d').fillRect(0, 0, 300, 150);
    v.srcObject = canvas.captureStream(1);
    </script>
    """

    /// `tab` in an on-screen window, its page loaded and its video ready. The page counts as visible even under other
    /// apps' windows: WebKit holds a video's way back from PiP until its page shows.
    private func show(_ tab: WKWebViewTab, _ html: String) async {
        tab.setWindowOcclusionDetection(false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        tab.view.frame = window.contentView!.bounds
        window.contentView!.addSubview(tab.view)
        window.orderFront(nil)
        addTeardownBlock { @MainActor in
            window.orderOut(nil)
            tab.teardown()
        }
        tab.wkWebView.loadHTMLString(html, baseURL: URL(string: "https://video.example/"))
        _ = await pollUntil(timeout: 5) { (try? await tab.wkWebView.evaluateJavaScript("v.readyState >= 1")) as? Bool == true }
    }

    private func makeTab(_ html: String) async -> WKWebViewTab {
        let factory = WKEngineFactory()
        let tab = factory.createTab(configuration: .init(dataStore: factory.createDataStore(persistent: false, identifier: nil)))
        await show(tab, html)
        return tab
    }

    private func presentationMode(of tab: WKWebViewTab) async -> String? {
        (try? await tab.wkWebView.evaluateJavaScript("v.webkitPresentationMode")) as? String
    }

    func testTheFallbackEntersPiPWithoutThePageSeeingIt() async throws {
        let tab = await makeTab(Self.stillVideo + """
        <script>
        window.calls = 0;
        const set = HTMLVideoElement.prototype.webkitSetPresentationMode;
        HTMLVideoElement.prototype.webkitSetPresentationMode = function (mode) { window.calls++; return set.call(this, mode); };
        </script>
        """)
        XCTAssertFalse(tab.pip.canToggle)

        tab.togglePictureInPicture()
        let entered = await pollUntil(timeout: 5) { await self.presentationMode(of: tab) == "picture-in-picture" }
        XCTAssertTrue(entered)

        let calls = try await tab.wkWebView.evaluateJavaScript("window.calls") as? Int
        XCTAssertEqual(calls, 0, "the script runs in an isolated world: the page's own prototype is never called")
    }
}
