import WebKit
import XCTest
@testable import Lilo

/// chrome.tabCapture and chrome.desktopCapture through the real gap router, registry and window,
/// down to an offscreen document decoding frames of a captured tab.
@MainActor
final class CaptureBridgeHandlerTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var window: MainWindowController!
    private var registry: ProfileExtensionRegistry!
    private var extensionDirectory: URL!

    private var context: BrowserContext { browserContext.context }
    private var router: GapBridgeRouter { context.engineFactory.gapRouter }
    private var capture: CaptureBridgeHandler { context.engineFactory.captureHandler }

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        registry = try context.profileContexts.context(for: profileId).extensions
        window = MainWindowController(context: context)
        window.bridgeRouter = BridgeRouter(chromeWebView: window.chromeWebView)
        // Transparent and off screen, as AgentToolTestCase: the captured tab must render to be snapshotted.
        let nsWindow = try XCTUnwrap(window.window)
        nsWindow.alphaValue = 0
        nsWindow.orderFrontRegardless()
        nsWindow.setFrame(NSRect(x: -20000, y: -20000, width: 1000, height: 700), display: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 650))
        try XCTUnwrap(nsWindow.contentView).addSubview(container)
        window.contentContainerView = container
        context.windows.add(window)
        window.switchToSpace(space.id)
        window.setupExtensions()
        window.setupTabShare()
    }

    override func tearDown() {
        window.window?.close()
        window = nil
        registry = nil
        if let extensionDirectory { try? FileManager.default.removeItem(at: extensionDirectory) }
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    private func loadExtension(permissions: [String], files: [String: String] = [:]) async throws -> (id: String, context: WKWebExtensionContext) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID().uuidString)", isDirectory: true)
        extensionDirectory = dir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Recorder", "version": "1.0", "permissions": permissions]
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))
        for (name, contents) in files {
            try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try await registry.load(from: dir)
        let id = try XCTUnwrap(registry.loadedExtensions.first?.id)
        return (id, try XCTUnwrap(registry.context(for: id)))
    }

    /// Opens `url` in a tab and returns its engine's web view once WebKit's tabs list it.
    private func openTab(_ url: URL, extensionId: String) async throws -> (tabId: UUID, webView: WKWebView) {
        let tab = try XCTUnwrap(window.createTabStateFirst(url: url))
        var webView: WKWebView?
        let listed = await pollUntil(timeout: 10) {
            webView = self.window.tabManager.engineTab(for: tab.id)?.view as? WKWebView
            return webView.flatMap { self.registry.tabPosition(of: $0, extensionId: extensionId) } != nil
        }
        XCTAssertTrue(listed, "the tab is listed to the extension")
        return (tab.id, try XCTUnwrap(webView))
    }

    private func position(of webView: WKWebView, extensionId: String) throws -> [String: Int] {
        try XCTUnwrap(registry.tabPosition(of: webView, extensionId: extensionId))
    }

    private func invoke(_ extensionContext: WKWebExtensionContext, on webView: WKWebView, extensionId: String) throws {
        let adapter = try XCTUnwrap(registry.tabAdapters(atPositions: [position(of: webView, extensionId: extensionId)], extensionId: extensionId).first ?? nil)
        extensionContext.userGesturePerformed(in: adapter)
    }

    private func route(_ namespace: String, _ method: String, _ params: [String: Any], extensionId: String) async -> (result: Any?, error: String?) {
        await router.route(namespace: namespace, method: method, params: params, extensionId: extensionId, fromWorker: true, registry: registry)
    }

    /// FireShot: WebKit asks the tab for tabs.captureVisibleTab's snapshot with an empty rect.
    func testCaptureVisibleTabSnapshotsTheVisiblePage() async throws {
        let (id, extensionContext) = try await loadExtension(permissions: ["activeTab"])
        let (_, webView) = try await openTab(try XCTUnwrap(URL(string: "data:text/html,<body style='background:red'>page")), extensionId: id)
        let adapter = try XCTUnwrap(registry.tabAdapters(atPositions: [position(of: webView, extensionId: id)], extensionId: id).first ?? nil)

        let configuration = WKSnapshotConfiguration()
        configuration.rect = .zero
        let image: NSImage? = await withCheckedContinuation { done in
            adapter.takeSnapshot(using: configuration, for: extensionContext) { image, _ in done.resume(returning: image) }
        }

        XCTAssertEqual(image?.size, webView.bounds.size)
    }

    func testTabCaptureNeedsItsPermission() async throws {
        let (id, _) = try await loadExtension(permissions: ["tabs"])
        let (_, error) = await route("tabCapture", "getMediaStreamId", [:], extensionId: id)
        XCTAssertEqual(error, "Permission 'tabCapture' is required for tabCapture.getMediaStreamId")
    }

    func testGetMediaStreamIdNeedsTheExtensionInvokedOnTheTargetTab() async throws {
        let (id, extensionContext) = try await loadExtension(permissions: ["tabCapture"])
        let (_, target) = try await openTab(URL(string: "about:blank")!, extensionId: id)
        let params: [String: Any] = ["tabId": 4, "target": try position(of: target, extensionId: id)]

        var reply = await route("tabCapture", "getMediaStreamId", params, extensionId: id)
        XCTAssertEqual(reply.error, "Extension has not been invoked for the current page (see activeTab permission). Chrome pages cannot be captured.")

        try invoke(extensionContext, on: target, extensionId: id)
        reply = await route("tabCapture", "getMediaStreamId", params, extensionId: id)
        XCTAssertNil(reply.error)
        XCTAssertFalse((reply.result as? String ?? "").isEmpty)

        reply = await route("tabCapture", "getMediaStreamId", params, extensionId: id)
        XCTAssertEqual(reply.error, "Cannot capture a tab with an active stream.")

        reply = await route("tabCapture", "getMediaStreamId", ["tabId": 9, "target": ["windowPosition": 0, "index": 99]], extensionId: id)
        XCTAssertEqual(reply.error, "Invalid tab specified.")
    }

    func testAStreamIdIsSpentOnceByTheOriginItNames() async throws {
        let (id, extensionContext) = try await loadExtension(permissions: ["tabCapture"])
        let (tabId, target) = try await openTab(URL(string: "about:blank")!, extensionId: id)
        try invoke(extensionContext, on: target, extensionId: id)
        let reply = await route("tabCapture", "getMediaStreamId", ["tabId": 4, "target": try position(of: target, extensionId: id)], extensionId: id)
        let streamId = try XCTUnwrap(reply.result as? String)
        let origin = "\(extensionContext.baseURL.scheme!)://\(extensionContext.baseURL.host!)"

        XCTAssertNil(capture.redeem(streamId, mediaSource: "tab", origin: "https://evil.example"))
        XCTAssertNil(capture.redeem(streamId, mediaSource: "desktop", origin: origin))
        let grant = try XCTUnwrap(capture.redeem(streamId, mediaSource: "tab", origin: origin))
        guard case .tab(let captured) = grant.source else { return XCTFail("expected a tab source") }
        XCTAssertEqual(captured, tabId)
        XCTAssertNil(capture.redeem(streamId, mediaSource: "tab", origin: origin), "single use")
    }

    func testCapturedTabsAreListedUntilTheirSessionEnds() async throws {
        let (id, extensionContext) = try await loadExtension(permissions: ["tabCapture"])
        let (_, target) = try await openTab(URL(string: "about:blank")!, extensionId: id)
        try invoke(extensionContext, on: target, extensionId: id)
        let reply = await route("tabCapture", "getMediaStreamId", ["tabId": 4, "target": try position(of: target, extensionId: id)], extensionId: id)
        let origin = "\(extensionContext.baseURL.scheme!)://\(extensionContext.baseURL.host!)"
        let grant = try XCTUnwrap(capture.redeem(try XCTUnwrap(reply.result as? String), mediaSource: "tab", origin: origin))

        capture.captureStarted(token: "token", grant: grant)
        let listed = await route("tabCapture", "getCapturedTabs", [:], extensionId: id).result as? [[String: Any]]
        XCTAssertEqual(listed?.count, 1)
        XCTAssertEqual(listed?.first?["tabId"] as? Int, 4)
        XCTAssertEqual(listed?.first?["status"] as? String, "active")
        XCTAssertEqual(listed?.first?["fullscreen"] as? Bool, false)

        capture.sessionEnded(token: "token")
        let afterEnd = await route("tabCapture", "getCapturedTabs", [:], extensionId: id).result as? [Any]
        XCTAssertEqual(afterEnd?.count, 0)
    }

    func testChooseDesktopMediaHandsOutThePickAndCancels() async throws {
        let (id, extensionContext) = try await loadExtension(permissions: ["desktopCapture"])
        let pickedTab = UUID()
        var pickerTitle: String?
        capture.picker = { title, _ in
            pickerTitle = title
            return .tab(pickedTab)
        }
        var reply = await route("desktopCapture", "chooseDesktopMedia", ["requestId": 1, "sources": ["tab", "audio"]], extensionId: id)
        let result = try XCTUnwrap(reply.result as? [String: Any])
        XCTAssertEqual(pickerTitle, "Recorder")
        XCTAssertEqual(result["canRequestAudioTrack"] as? Bool, false)
        let origin = "\(extensionContext.baseURL.scheme!)://\(extensionContext.baseURL.host!)"
        XCTAssertNil(capture.redeem(try XCTUnwrap(result["streamId"] as? String), mediaSource: "tab", origin: origin))
        XCTAssertNotNil(capture.redeem(try XCTUnwrap(result["streamId"] as? String), mediaSource: "desktop", origin: origin))

        reply = await route("desktopCapture", "chooseDesktopMedia", ["requestId": 2, "sources": ["audio"]], extensionId: id)
        XCTAssertEqual(reply.error, "At least one source type must be specified.")

        capture.picker = { _, _ in
            try? await Task.sleep(for: .seconds(30))
            return Task.isCancelled ? nil : .tab(pickedTab)
        }
        async let pending = route("desktopCapture", "chooseDesktopMedia", ["requestId": 3, "sources": ["screen"]], extensionId: id)
        try await Task.sleep(for: .milliseconds(100))
        _ = await route("desktopCapture", "cancelChooseDesktopMedia", ["requestId": 3], extensionId: id)
        let cancelled = await pending
        XCTAssertEqual((cancelled.result as? [String: Any])?["streamId"] as? String, "")
    }

    func testOffscreenDocumentReceivesFramesOfACapturedTab() async throws {
        let offscreenScript = """
        chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
          (async () => {
            const stream = await navigator.mediaDevices.getUserMedia({
              audio: false,
              video: { mandatory: { chromeMediaSource: 'tab', chromeMediaSourceId: message.streamId } }
            });
            // Recorders consume the stream with MediaRecorder; a window-less offscreen page plays no <video>. What it
            // encodes is WebKit's affair (CI's virtual machines encode nothing): the frames it pulls are Lilo's.
            const [track] = stream.getVideoTracks();
            const settings = track.getSettings();
            const recorder = new MediaRecorder(stream);
            recorder.start(250);
            await new Promise((resolve) => setTimeout(resolve, 1500));
            recorder.stop();
            await new Promise((resolve) => { recorder.onstop = resolve; });
            track.stop();
            return { width: settings.width, height: settings.height, surface: settings.displaySurface };
          })().then(sendResponse, (error) => sendResponse({ error: String(error) }));
          return true;
        });
        """
        let (id, extensionContext) = try await loadExtension(
            permissions: ["tabCapture", "offscreen", "tabs"],
            files: [
                "page.html": "<!doctype html><title>page</title>",
                "offscreen.html": "<!doctype html><script src=\"offscreen.js\"></script>",
                "offscreen.js": offscreenScript
            ]
        )
        // A changing page: the ferry skips identical frames, so a still one would send a single frame.
        let red = "data:text/html,<body style='margin:0'><script>let i = 0; setInterval(() => document.body.style.background = `rgb(${200 + i++ % 50},0,0)`, 50)</script></body>"
        let (_, page) = try await openTab(extensionContext.baseURL.appendingPathComponent("page.html"), extensionId: id)
        let (_, target) = try await openTab(try XCTUnwrap(URL(string: red.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)), extensionId: id)
        try invoke(extensionContext, on: target, extensionId: id)
        let animating = await pollUntil(timeout: 5) {
            let first = try? await target.evaluateJavaScript("document.body.style.background") as? String
            try? await Task.sleep(for: .milliseconds(120))
            let second = try? await target.evaluateJavaScript("document.body.style.background") as? String
            return first != nil && first != second
        }
        XCTAssertTrue(animating, "the captured tab changes")
        let ready = await pollUntil(timeout: 10) {
            (try? await page.evaluateJavaScript("typeof chrome?.tabCapture?.getMediaStreamId")) as? String == "function"
        }
        XCTAssertTrue(ready, "the extension page has chrome.tabCapture")

        // The ferry stores a frame only once the page took the previous one.
        var storedFrames = 0
        let flush = window.tabShareSessions.onFrameStored
        window.tabShareSessions.onFrameStored = {
            storedFrames += 1
            flush?()
        }
        let result = try await page.callAsyncJavaScript("""
            let stage = 'query';
            const run = async () => {
              const tabs = await chrome.tabs.query({});
              const target = tabs.find((tab) => !tab.url?.startsWith(chrome.runtime.getURL('')));
              if (!target) return { error: 'no target tab in ' + JSON.stringify(tabs) };
              stage = 'getMediaStreamId';
              const streamId = await chrome.tabCapture.getMediaStreamId({ targetTabId: target.id });
              stage = 'createDocument';
              await chrome.offscreen.createDocument({ url: 'offscreen.html', reasons: ['USER_MEDIA'], justification: 'test' });
              stage = 'sendMessage';
              return await chrome.runtime.sendMessage({ streamId });
            };
            const timeout = new Promise((resolve) => setTimeout(() => resolve({ error: 'timed out at ' + stage }), 20000));
            return await Promise.race([run().catch((error) => ({ error: stage + ': ' + error })), timeout]);
            """, contentWorld: .page) as? [String: Any]

        XCTAssertNil(result?["error"], "\(result ?? [:])")
        XCTAssertEqual(result?["surface"] as? String, "browser")
        XCTAssertGreaterThan(result?["width"] as? Int ?? 0, 0)
        XCTAssertGreaterThanOrEqual(storedFrames, 3, "the offscreen document pulled frames of the tab")
        let stopped = await pollUntil(timeout: 5) { self.window.tabShareSessions.sharedEngines.isEmpty }
        XCTAssertTrue(stopped, "stopping the tracks ends the ferry")
    }
}
