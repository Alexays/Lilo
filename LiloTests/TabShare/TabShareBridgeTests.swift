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

        bridge.pickerPresenter = { _, _ in .cancel }
        var reply = await bridge.pick(originHost: "a.example", requester: WKWebView(frame: .zero))
        XCTAssertEqual(reply["mode"] as? String, "cancel")

        bridge.pickerPresenter = { _, _ in .system }
        reply = await bridge.pick(originHost: "a.example", requester: WKWebView(frame: .zero))
        XCTAssertEqual(reply["mode"] as? String, "system")

        bridge.pickerPresenter = { _, _ in .tab(tabId) }
        reply = await bridge.pick(originHost: "a.example", requester: WKWebView(frame: .zero))
        XCTAssertEqual(reply["mode"] as? String, "tab")
        XCTAssertEqual(reply["token"] as? String, "t")
        XCTAssertEqual(started, tabId)
    }

    func testPickedTabWithoutLiveEngineCancels() async {
        let bridge = TabShareBridge()
        bridge.pickerPresenter = { _, _ in .tab(UUID()) }
        bridge.sessionStarter = { _, _ in nil }
        let reply = await bridge.pick(originHost: "a.example", requester: WKWebView(frame: .zero))
        XCTAssertEqual(reply["mode"] as? String, "cancel")
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
        // Pixels, capped at 1080p width: 1440 points is 2880 pixels on Retina, sent as 1920.
        let pixelWidth = 1440 * (NSScreen.main?.backingScaleFactor ?? 1)
        let fit = min(1, TabShareSessionController.maxFrameWidth / pixelWidth)
        XCTAssertEqual(reply["width"] as? Int, Int(pixelWidth * fit) & ~1)
        XCTAssertEqual(reply["height"] as? Int, Int(900 * (NSScreen.main?.backingScaleFactor ?? 1) * fit) & ~1)
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

    func testStopWithForeignTokenIsIgnored() {
        let controller = TabShareSessionController()
        let engine = WKWebViewTab(configuration: WKWebViewConfiguration())
        _ = controller.start(engine: engine, requester: WKWebView(frame: .zero))

        controller.stop(token: "not-the-token")
        XCTAssertTrue(controller.isSharing(engineId: engine.id))
        controller.stopAll()
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
        XCTAssertEqual(reply["width"] as? Int, 1920)
        XCTAssertEqual(reply["height"] as? Int, 1080)
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
