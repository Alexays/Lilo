import WebKit
import XCTest
@testable import Lilo

@MainActor
final class MediaControlTests: XCTestCase {
    private static let sessionPage = """
    <script>
    window.calls = [];
    for (const action of ['play', 'pause', 'nexttrack', 'previoustrack']) {
      navigator.mediaSession.setActionHandler(action, () => window.calls.push(action));
    }
    </script>
    """

    func testControlsGoToThePageMediaSessionHandlers() async throws {
        let tab = try await loadedTab(Self.sessionPage)
        defer { tab.teardown() }

        let hasTrackControls = await tab.hasMediaTrackControls()
        XCTAssertTrue(hasTrackControls)
        for action in ["pause", "play", "nexttrack", "previoustrack", "unknown"] { tab.controlMedia(action) }

        let met = await pollUntil(timeout: 5) {
            ((try? await tab.wkWebView.evaluateJavaScript("window.calls.join()")) as? String) == "pause,play,nexttrack,previoustrack"
        }
        XCTAssertTrue(met)
    }

    func testCallControlsReachTheCallCardAndItsTogglesReachThePage() async throws {
        let factory = WKEngineFactory()
        var reported: WKWebViewTab.CallControls?
        factory.callControlsHandler = { _, controls in reported = controls }
        let tab = try await loadedTab("""
        <script>
        window.calls = [];
        for (const action of ['togglemicrophone', 'hangup']) {
          navigator.mediaSession.setActionHandler(action, () => window.calls.push(action));
        }
        navigator.mediaSession.setMicrophoneActive(false);
        </script>
        """, factory: factory)
        defer { tab.teardown() }

        let expected = WKWebViewTab.CallControls(microphoneActive: false, cameraActive: nil, actions: ["togglemicrophone", "hangup"])
        let reportedAll = await pollUntil(timeout: 5) { reported == expected }
        XCTAssertTrue(reportedAll, "\(String(describing: reported))")
        tab.controlMedia("togglecamera")
        tab.callControls = expected
        for action in ["togglemicrophone", "togglecamera", "hangup"] { tab.controlMedia(action) }

        let met = await pollUntil(timeout: 5) {
            ((try? await tab.wkWebView.evaluateJavaScript("window.calls.join()")) as? String) == "togglemicrophone,hangup"
        }
        XCTAssertTrue(met)
    }

    func testAPageWithoutTrackHandlersOffersNoTrackControls() async throws {
        let tab = try await loadedTab("<p>no session</p>")
        defer { tab.teardown() }

        let hasTrackControls = await tab.hasMediaTrackControls()
        XCTAssertFalse(hasTrackControls)
    }

    private func loadedTab(_ html: String, factory: WKEngineFactory? = nil) async throws -> WKWebViewTab {
        let tab = (factory ?? WKEngineFactory()).createTab(configuration: WKEngineFactory.Configuration())
        tab.wkWebView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        // The initial about:blank already reads complete, without the user scripts: wait for this page.
        let loaded = await pollUntil(timeout: 5) {
            let condition = "location.href === 'https://example.com/' && document.readyState === 'complete'"
            return ((try? await tab.wkWebView.evaluateJavaScript(condition)) as? Bool) == true
        }
        XCTAssertTrue(loaded)
        let hasSession = (try? await tab.wkWebView.evaluateJavaScript("'mediaSession' in navigator")) as? Bool ?? false
        if !hasSession {
            tab.teardown()
            throw XCTSkip("This WebKit has no Media Session API")
        }
        return tab
    }
}
