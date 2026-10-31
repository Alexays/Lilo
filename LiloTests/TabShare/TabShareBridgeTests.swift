import XCTest
import WebKit
@testable import Lilo

@MainActor
final class TabShareBridgeTests: XCTestCase {

    func testPickWithoutPresenterFallsBackToSystem() async {
        let bridge = TabShareBridge()
        let reply = await bridge.pick(originHost: "meet.example", requester: WKWebView(frame: .zero))
        XCTAssertEqual(reply["mode"] as? String, "system")
    }

    func testPickMapsPresenterChoices() async {
        let bridge = TabShareBridge()
        let tabId = UUID()
        var started: UUID?
        bridge.sessionStarter = { id, _ in
            started = id
            return ["mode": "tab", "token": "t", "width": 640, "height": 360]
        }

        bridge.pickerPresenter = { _, _, _, _ in .cancel }
        var reply = await bridge.pick(originHost: "a.example", requester: WKWebView(frame: .zero))
        XCTAssertEqual(reply["mode"] as? String, "cancel")

        bridge.pickerPresenter = { _, _, _, _ in .system(audio: false) }
        reply = await bridge.pick(originHost: "a.example", requester: WKWebView(frame: .zero))
        XCTAssertEqual(reply["mode"] as? String, "system")

        bridge.pickerPresenter = { _, _, _, _ in .tab(tabId) }
        reply = await bridge.pick(originHost: "a.example", requester: WKWebView(frame: .zero))
        XCTAssertEqual(reply["mode"] as? String, "tab")
        XCTAssertEqual(reply["token"] as? String, "t")
        XCTAssertEqual(started, tabId)
    }

    func testPickedTabWithoutLiveEngineCancels() async {
        let bridge = TabShareBridge()
        bridge.pickerPresenter = { _, _, _, _ in .tab(UUID()) }
        bridge.sessionStarter = { _, _ in nil }
        let reply = await bridge.pick(originHost: "a.example", requester: WKWebView(frame: .zero))
        XCTAssertEqual(reply["mode"] as? String, "cancel")
    }

    func testAScreenGoesThroughTheFerryWithSoundOnlyWhenBothSidesWantIt() async {
        let bridge = TabShareBridge()
        var sounds: [Bool] = [], sizes: [CGSize] = []
        bridge.screenStarter = { _, audio, maxSize in
            sounds.append(audio)
            sizes.append(maxSize)
            return ["mode": "tab", "token": "s"]
        }
        let requester = WKWebView(frame: .zero)

        bridge.pickerPresenter = { _, _, _, _ in .system(audio: true) }
        var reply = await bridge.pick(originHost: "a.example", requester: requester, wantsAudio: true, maxSize: CGSize(width: 1920, height: 1200))
        XCTAssertEqual(reply["mode"] as? String, "tab")
        XCTAssertEqual(sizes.first, CGSize(width: 1920, height: 1200), "the capture never goes past what the page asked for")
        reply = await bridge.pick(originHost: "a.example", requester: requester, wantsAudio: false)
        XCTAssertEqual(reply["mode"] as? String, "tab", "full resolution and frame rate, with or without sound")

        bridge.pickerPresenter = { _, _, _, _ in .system(audio: false) }
        reply = await bridge.pick(originHost: "a.example", requester: requester, wantsAudio: true)
        XCTAssertEqual(reply["mode"] as? String, "tab")
        XCTAssertEqual(sounds, [true, false, false])

        bridge.pickerPresenter = { _, _, _, _ in .system(audio: true) }
        bridge.screenStarter = { _, _, _ in nil }
        reply = await bridge.pick(originHost: "a.example", requester: requester, wantsAudio: true)
        XCTAssertEqual(reply["mode"] as? String, "cancel", "a cancelled system picker cancels the share")
    }

    func testAScreenShareLeavesTheLegacyConferenceMode() async throws {
        let tab = WKEngineFactory().createTab(configuration: WKEngineFactory.Configuration())
        defer { tab.teardown() }
        tab.wkWebView.loadHTMLString("<p>call</p>", baseURL: URL(string: "https://example.com/"))
        let loaded = await pollUntil(timeout: 5) {
            ((try? await tab.wkWebView.evaluateJavaScript("location.href === 'https://example.com/' && document.readyState === 'complete'")) as? Bool) == true
        }
        XCTAssertTrue(loaded)

        let sdp = try await tab.wkWebView.callAsyncJavaScript("""
            const sender = new RTCPeerConnection(), receiver = new RTCPeerConnection();
            sender.addTransceiver('video');
            await sender.setLocalDescription();
            const flagged = sender.localDescription.sdp.replace(/(a=mid:[^\\r\\n]*\\r\\n)/, '$1a=x-google-flag:conference\\r\\n');
            await receiver.setRemoteDescription({ type: 'offer', sdp: flagged });
            const result = [flagged.includes('x-google-flag:conference'), receiver.remoteDescription.sdp.includes('x-google-flag:conference')];
            sender.close();
            receiver.close();
            return result;
            """, contentWorld: .page) as? [Bool]

        XCTAssertEqual(sdp, [true, false], "the flag would hold a VP8 screen share at 5 fps and 1 Mbps")
    }

    func testThePickerOffersTheCallingTabOnlyWhenThePageAsks() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let context = browserContext.context
        let space = try context.spaceManager.createSpace(name: "S", profileId: try context.profileManager.createProfile(name: "P").id)
        let window = makeTestWindow(context, showing: space.id)
        defer { window.window?.close() }
        var requests: [[String: Any]] = []
        window.bridgeRouter.javaScriptSink = { _, arguments, completion in
            let messages = arguments["messages"] as? [[String: Any]] ?? [arguments["message"] as? [String: Any]].compactMap { $0 }
            requests += messages.filter { $0["event"] as? String == "tabSharePickerRequested" }
            completion()
        }
        let other = try XCTUnwrap(window.createTabStateFirst(url: nil))
        let caller = try XCTUnwrap(window.createTabStateFirst(url: nil))
        let webView = try XCTUnwrap(window.tabManager.engineTab(for: caller.id)).wkWebView
        webView.loadHTMLString("<p>call</p>", baseURL: URL(string: "https://example.com/"))
        await pollUntil { !webView.isLoading && webView.url != nil }

        func offered(_ options: String) async throws -> (shareable: Set<String>, suggested: [String]) {
            requests = []
            _ = try await webView.evaluateJavaScript("window.share = navigator.mediaDevices.getDisplayMedia({ video: true\(options) }).catch(() => {}); true")
            await pollUntil { !requests.isEmpty }
            let request = try XCTUnwrap(requests.first)
            window.resolveTabSharePicker(requestId: try XCTUnwrap(request["requestId"] as? String), choice: .cancel)
            _ = try await webView.callAsyncJavaScript("await window.share", contentWorld: .page)
            return (Set(request["shareableTabIds"] as? [String] ?? []), request["suggestedTabIds"] as? [String] ?? [])
        }

        let plain = try await offered("")
        XCTAssertFalse(plain.shareable.contains(caller.id.uuidString), "Chrome leaves the calling tab out by default")
        XCTAssertTrue(plain.shareable.contains(other.id.uuidString))
        let included = try await offered(", selfBrowserSurface: 'include'")
        XCTAssertTrue(included.shareable.contains(caller.id.uuidString))
        let preferred = try await offered(", preferCurrentTab: true")
        XCTAssertEqual(preferred.suggested.first, caller.id.uuidString, "selected first")

        let contradiction = try await webView.callAsyncJavaScript("""
            try { await navigator.mediaDevices.getDisplayMedia({ video: true, preferCurrentTab: true, selfBrowserSurface: 'exclude' }); } catch (e) { return e.name; }
            """, contentWorld: .page) as? String
        XCTAssertEqual(contradiction, "TypeError")
    }
}

@MainActor
final class TabShareSessionControllerTests: XCTestCase {

    func testStartMarksEngineAndBuildsPayload() {
        let controller = TabShareSessionController()
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        engine.view.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let reply = controller.start(engine: engine, requester: WKWebView(frame: .zero))

        XCTAssertEqual(reply["mode"] as? String, "tab")
        XCTAssertNotNil(reply["token"] as? String)
        // Pixels, under 1080p's width and area: 1440x900 points is 2880x1800 pixels on Retina, sent at 1080p's area.
        let scale = NSScreen.main?.backingScaleFactor ?? 1
        let fit = min(1, TabShareSessionController.maxFrameWidth / (1440 * scale),
                      (TabShareSessionController.maxFramePixels / (1440 * scale * 900 * scale)).squareRoot())
        XCTAssertEqual(reply["width"] as? Int, Int(1440 * scale * fit) & ~1)
        XCTAssertEqual(reply["height"] as? Int, Int(900 * scale * fit) & ~1)
        XCTAssertTrue(engine.isTabShareSource)
        XCTAssertTrue(engine.hasActiveCapture)
        XCTAssertTrue(controller.isSharing(engineId: engine.id))
        controller.stopAll()
    }

    func testStopClearsMarkAndNotifiesOnce() {
        let controller = TabShareSessionController()
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        var endedWith: [UUID?] = []
        controller.onSessionEnded = { endedWith.append($1) }
        _ = controller.start(engine: engine, requester: WKWebView(frame: .zero))

        controller.stopAll()
        controller.stopAll()
        XCTAssertFalse(engine.isTabShareSource)
        XCTAssertFalse(controller.isSharing(engineId: engine.id))
        XCTAssertEqual(endedWith, [engine.id])
    }

    func testATabShareCarriesNoSound() {
        let controller = TabShareSessionController()
        let requester = WKWebView(frame: .zero)
        let reply = controller.start(engine: WKWebViewTab(configuration: WKWebViewConfiguration()), requester: requester)
        XCTAssertNil(reply["audioURL"])
        guard case .gone = controller.audio(token: reply["token"] as? String ?? "", puller: requester) else { return XCTFail("expected gone") }
        controller.stopAll()
    }

    func testStopWithForeignTokenIsIgnored() {
        let controller = TabShareSessionController()
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        _ = controller.start(engine: engine, requester: WKWebView(frame: .zero))

        controller.stop(token: "not-the-token")
        XCTAssertTrue(controller.isSharing(engineId: engine.id))
        controller.stopAll()
    }

    func testSwitchingSourceKeepsTheSessionAndReleasesThePreviousTab() {
        let controller = TabShareSessionController()
        let first = WKWebViewTab(configuration: WKWebViewConfiguration())
        let second = WKWebViewTab(configuration: WKWebViewConfiguration())
        let requester = WKWebView(frame: .zero)
        var released: [UUID] = []
        var changes = 0
        controller.onSourceReleased = { released.append($0) }
        controller.onSharesChanged = { changes += 1 }
        let token = controller.start(engine: first, requester: requester)["token"] as? String ?? ""

        controller.switchSource(token: token, to: second)
        XCTAssertTrue(controller.hasSession(token: token))
        XCTAssertEqual(controller.share(requestedBy: requester)?.engineId, second.id)
        XCTAssertFalse(first.isTabShareSource)
        XCTAssertTrue(second.isTabShareSource)
        XCTAssertEqual(released, [first.id])
        XCTAssertEqual(changes, 2)

        // Onto the tab it already shares, or for a gone session: nothing moves.
        controller.switchSource(token: token, to: second)
        controller.switchSource(token: "gone", to: first)
        XCTAssertEqual(changes, 2)
        controller.stopAll()
        XCTAssertNil(controller.share(requestedBy: requester))
    }

    func testSessionsRunSideBySide() {
        let controller = TabShareSessionController()
        let first = WKWebViewTab(configuration: WKWebViewConfiguration())
        let second = WKWebViewTab(configuration: WKWebViewConfiguration())
        let firstToken = controller.start(engine: first, requester: WKWebView(frame: .zero))["token"] as? String ?? ""
        _ = controller.start(engine: second, requester: WKWebView(frame: .zero))

        XCTAssertTrue(first.isTabShareSource)
        XCTAssertTrue(second.isTabShareSource)
        controller.stop(token: firstToken)
        XCTAssertFalse(first.isTabShareSource)
        XCTAssertFalse(controller.isSharing(engineId: first.id))
        XCTAssertTrue(controller.isSharing(engineId: second.id))
        controller.stopAll()
    }

    func testATabSharedTwiceStaysMarkedUntilItsLastSessionEnds() {
        let controller = TabShareSessionController()
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        var endedWith: [UUID?] = []
        controller.onSessionEnded = { endedWith.append($1) }
        let first = controller.start(engine: engine, requester: WKWebView(frame: .zero))["token"] as? String ?? ""
        _ = controller.start(engine: engine, requester: WKWebView(frame: .zero))

        controller.stop(token: first)
        XCTAssertTrue(engine.isTabShareSource)
        controller.stop(sharing: engine.id)
        XCTAssertFalse(engine.isTabShareSource)
        XCTAssertEqual(endedWith, [nil, engine.id])
    }

    func testTinyDetachedViewFallsBackToDefaultFrameSize() {
        let controller = TabShareSessionController()
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let reply = controller.start(engine: engine, requester: WKWebView(frame: .zero))
        // 1920x1080, just under its area: the encoder's thread count steps up at 1080p.
        XCTAssertEqual(reply["width"] as? Int, 1918)
        XCTAssertEqual(reply["height"] as? Int, 1078)
        controller.stopAll()
    }

    func testStartPayloadCarriesTokenScopedFrameURL() {
        let controller = TabShareSessionController()
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let reply = controller.start(engine: engine, requester: WKWebView(frame: .zero))
        let token = reply["token"] as? String ?? ""
        XCTAssertEqual(reply["frameURL"] as? String, "lilo-capture://frames/frame?token=\(token)")
        controller.stopAll()
    }

    func testFrameReadsPendingThenGone() {
        let controller = TabShareSessionController()
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        let requester = WKWebView(frame: .zero)
        let reply = controller.start(engine: engine, requester: requester)
        let token = reply["token"] as? String ?? ""

        guard case .pending = controller.frame(token: token, afterSeq: 0, wantsKey: false, puller: requester) else {
            return XCTFail("expected .pending before any frame")
        }
        guard case .gone = controller.frame(token: "wrong", afterSeq: 0, wantsKey: false, puller: requester) else {
            return XCTFail("expected .gone for a foreign token")
        }
        guard case .gone = controller.frame(token: token, afterSeq: 0, wantsKey: false, puller: WKWebView(frame: .zero)) else {
            return XCTFail("expected .gone for a web view other than the requester")
        }

        controller.stopAll()
        guard case .gone = controller.frame(token: token, afterSeq: 0, wantsKey: false, puller: requester) else {
            return XCTFail("expected .gone after stop")
        }
    }

    func testTabPayloadReportsBrowserSurface() {
        let controller = TabShareSessionController()
        let reply = controller.start(engine: WKWebViewTab(configuration: WKWebViewConfiguration()), requester: WKWebView(frame: .zero))
        XCTAssertEqual(reply["surface"] as? String, "browser")
        controller.stopAll()
    }
}

final class TabShareEncoderTests: XCTestCase {

    private func image(gray: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        return context.makeImage()!
    }

    func testFirstFrameIsAKeyframeCarryingItsDecoderConfig() throws {
        let encoder = TabShareEncoder(width: 640, height: 360)
        guard case .chunk(let chunk) = encoder.encode(image(gray: 0.2), forceKey: false) else { return XCTFail("expected a chunk") }
        let config = try XCTUnwrap(chunk.config)
        XCTAssertTrue(config.codec.hasPrefix("avc1."))
        XCTAssertEqual(config.codec.count, 11)
        XCTAssertEqual(config.description.first, 1, "avcC configurationVersion")
        XCTAssertFalse(chunk.data.isEmpty)
    }

    func testIdenticalPixelsAreSkippedUnlessAKeyframeIsForced() {
        let encoder = TabShareEncoder(width: 640, height: 360)
        let still = image(gray: 0.5)
        _ = encoder.encode(still, forceKey: false)
        guard case .unchanged = encoder.encode(still, forceKey: false) else { return XCTFail("expected .unchanged") }
        guard case .chunk(let delta) = encoder.encode(image(gray: 0.6), forceKey: false) else { return XCTFail("expected a chunk") }
        XCTAssertNil(delta.config)
        guard case .chunk(let key) = encoder.encode(image(gray: 0.6), forceKey: true) else { return XCTFail("expected a chunk") }
        XCTAssertNotNil(key.config)
    }
}
