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
        let factory = WKEngineFactory()
        var reported: WKWebViewTab.CallControls?
        factory.callControlsHandler = { _, controls in reported = controls }
        let tab = try await loadedTab(Self.sessionPage, factory: factory)
        defer { tab.teardown() }

        let reportedTracks = await pollUntil(timeout: 5) { reported?.hasTrackControls == true }
        XCTAssertTrue(reportedTracks)
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
        let factory = WKEngineFactory()
        var reported: WKWebViewTab.CallControls?
        factory.callControlsHandler = { _, controls in reported = controls }
        let tab = try await loadedTab("""
        <script>
        for (const action of ['play', 'pause', 'hangup']) navigator.mediaSession.setActionHandler(action, () => {});
        </script>
        """, factory: factory)
        defer { tab.teardown() }

        let reportedHangUp = await pollUntil(timeout: 5) { reported?.actions == ["hangup"] }
        XCTAssertTrue(reportedHangUp)
        XCTAssertEqual(reported?.hasTrackControls, false)
    }

    func testEnterPictureInPictureHandlerIsAcceptedAndReported() async throws {
        let factory = WKEngineFactory()
        var reported: WKWebViewTab.CallControls?
        factory.callControlsHandler = { _, controls in reported = controls }
        let tab = try await loadedTab("""
        <script>
        try { navigator.mediaSession.setActionHandler('enterpictureinpicture', () => {}); window.registered = 'ok'; }
        catch (e) { window.registered = e.name; }
        </script>
        """, factory: factory)
        defer { tab.teardown() }

        let reportedPiP = await pollUntil(timeout: 5) { reported?.hasPictureInPictureAction == true }
        let registered = try await tab.wkWebView.evaluateJavaScript("window.registered") as? String

        XCTAssertTrue(reportedPiP)
        XCTAssertEqual(registered, "ok", "a call page registering it, as Meet does, must not throw")
    }

    func testEnterDocumentPictureInPictureCallsThePageHandler() async throws {
        let factory = WKEngineFactory()
        var reported: WKWebViewTab.CallControls?
        factory.callControlsHandler = { _, controls in reported = controls }
        let tab = try await loadedTab("""
        <script>
        navigator.mediaSession.setActionHandler('enterpictureinpicture', details => { window.details = JSON.stringify(details); });
        </script>
        """, factory: factory)
        defer { tab.teardown() }
        _ = await pollUntil(timeout: 5) { reported?.hasPictureInPictureAction == true }
        tab.callControls = try XCTUnwrap(reported)

        tab.enterDocumentPictureInPicture()

        var details: String?
        let called = await pollUntil(timeout: 5) {
            details = (try? await tab.wkWebView.evaluateJavaScript("window.details")) as? String
            return details != nil
        }
        XCTAssertTrue(called)
        XCTAssertEqual(details, #"{"action":"enterpictureinpicture"}"#, "no useraction reason: Meet takes its automatic path")
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
