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
        XCTAssertEqual(details, #"{"action":"enterpictureinpicture","enterPictureInPictureReason":"useraction"}"#,
                       "the user left the tab with auto PiP on: Meet keeps its automatic path for some accounts only")
    }

    func testALiveWebRTCConnectionMakesThePageACall() async throws {
        let factory = WKEngineFactory()
        var reported: WKWebViewTab.CallControls?
        factory.callControlsHandler = { _, controls in reported = controls }
        let tab = try await loadedTab("<p>call</p>", factory: factory)
        defer { tab.teardown() }

        // A connected peer in a page that registers no Media Session action (Meet's companion mode). The test sets the
        // connection state itself: ICE between two local peers never completes on the CI runners.
        _ = try await tab.wkWebView.callAsyncJavaScript("""
            const a = new RTCPeerConnection(), b = new RTCPeerConnection();
            a.addTransceiver('audio');
            await b.setRemoteDescription(await a.createOffer());
            Object.defineProperty(b, 'connectionState', { value: 'connected', configurable: true });
            b.dispatchEvent(new Event('connectionstatechange'));
            window.peers = [a, b];
            """, contentWorld: .page)

        let connected = await pollUntil(timeout: 10) { reported?.hasLiveConnection == true }
        XCTAssertTrue(connected, "a connected peer is a call, with or without camera and microphone")

        _ = try await tab.wkWebView.evaluateJavaScript("delete window.peers[1].connectionState; window.peers.forEach(p => p.close()); true")

        let ended = await pollUntil(timeout: 10) { reported?.hasLiveConnection == false }
        XCTAssertTrue(ended, "the call ends with its connections")
    }

    /// A page holding one connection, set to `state` as a peer reports it, carrying audio or only data.
    private func connectionPage(audio: Bool) async throws -> (WKWebViewTab, () -> WKWebViewTab.CallControls?) {
        let factory = WKEngineFactory()
        var reported: WKWebViewTab.CallControls?
        factory.callControlsHandler = { _, controls in reported = controls }
        let tab = try await loadedTab("<p>call</p>", factory: factory)
        _ = try await tab.wkWebView.callAsyncJavaScript("""
            const a = new RTCPeerConnection(), b = new RTCPeerConnection();
            if (\(audio)) a.addTransceiver('audio'); else a.createDataChannel('files');
            await b.setRemoteDescription(await a.createOffer());
            window.setState = state => {
              Object.defineProperty(b, 'connectionState', { value: state, configurable: true });
              b.dispatchEvent(new Event('connectionstatechange'));
            };
            window.peers = [a, b];
            """, contentWorld: .page)
        return (tab, { reported })
    }

    func testADataOnlyConnectionIsNoCall() async throws {
        let (tab, reported) = try await connectionPage(audio: false)
        defer { tab.teardown() }

        _ = try await tab.wkWebView.evaluateJavaScript("setState('connected'); true")
        try await Task.sleep(nanoseconds: 1_000_000_000)

        XCTAssertNotEqual(reported()?.hasLiveConnection, true, "a file transfer or a game is no call: its tab may still freeze")
    }

    func testABriefDisconnectionKeepsTheCall() async throws {
        let (tab, reported) = try await connectionPage(audio: true)
        defer { tab.teardown() }
        _ = try await tab.wkWebView.evaluateJavaScript("setState('connected'); true")
        let connected = await pollUntil(timeout: 10) { reported()?.hasLiveConnection == true }
        XCTAssertTrue(connected)

        _ = try await tab.wkWebView.evaluateJavaScript("setState('disconnected'); true")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(reported()?.hasLiveConnection, true, "a network blip neither hides the call card nor lifts the tab's protection")

        _ = try await tab.wkWebView.evaluateJavaScript("setState('failed'); true")
        let ended = await pollUntil(timeout: 10) { reported()?.hasLiveConnection == false }
        XCTAssertTrue(ended)
    }

    func testALiveConnectionKeepsATabInACall() {
        let tab = WKWebViewTab(configuration: WKWebViewConfiguration())
        defer { tab.teardown() }
        XCTAssertFalse(tab.isInCall)

        tab.callControls.hasLiveConnection = true

        XCTAssertTrue(tab.isInCall, "Meet's companion mode: no capture and no Media Session action, a live connection")
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
