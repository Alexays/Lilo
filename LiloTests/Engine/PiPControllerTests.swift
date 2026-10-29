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

    /// A video playing audio once `play()` runs (as from a click), silent to the ear: WebKit's own PiP controls handle it.
    static let playingVideo = """
    <video id="v" playsinline style="width: 320px; height: 180px"></video>
    <script>
    const canvas = document.createElement('canvas');
    const context = canvas.getContext('2d');
    setInterval(() => { context.fillStyle = `hsl(${Date.now() % 360}, 80%, 50%)`; context.fillRect(0, 0, 300, 150); }, 50);
    window.play = () => {
      const audio = new AudioContext(), tone = audio.createOscillator(), out = audio.createMediaStreamDestination();
      const silent = audio.createGain();
      silent.gain.value = 0;
      tone.connect(silent);
      silent.connect(out);
      tone.start();
      const stream = canvas.captureStream(20);
      stream.addTrack(out.stream.getAudioTracks()[0]);
      v.srcObject = stream;
      return v.play().then(() => 'playing', (error) => error.name);
    };
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

    private func makeTab(_ html: String = stillVideo) async -> WKWebViewTab {
        let factory = WKEngineFactory()
        let tab = factory.createTab(configuration: .init(dataStore: factory.createDataStore(persistent: false, identifier: nil)))
        await show(tab, html)
        return tab
    }

    /// Starts playback and waits for WebKit to pick the video for its controls, which the app's activation does
    /// in Lilo and nothing does in the test host.
    private func play(_ tab: WKWebViewTab) async throws {
        let played = try await tab.wkWebView.callAsyncJavaScript("return await play()", contentWorld: .page) as? String
        XCTAssertEqual(played, "playing")
        let controlled = await pollUntil(timeout: 5) {
            tab.wkWebView.perform(NSSelectorFromString("_updateMediaPlaybackControlsManager"))
            return tab.pip.canToggle && tab.isPlayingAudio
        }
        XCTAssertTrue(controlled)
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

    func testLeavingTheAppFromAPlayingVideoOpensItsPiPAndComingBackEndsIt() async throws {
        let browserContext = try await TemporaryBrowserContext()
        addTeardownBlock { @MainActor in browserContext.tearDown() }
        let context = browserContext.context
        let space = try context.spaceManager.createSpace(name: "Video", profileId: context.profileManager.createProfile(name: "P").id)
        let window = makeTestWindow(context, showing: space.id)
        let engine = try XCTUnwrap(window.createTabStateFirst(url: nil).flatMap { window.tabManager.engineTab(for: $0.id) })
        await show(engine, Self.playingVideo)
        try await play(engine)

        context.hiddenSpaceLifecycle.handleWillResignActive()
        let entered = await pollUntil(timeout: 5) { engine.pip.isActive }
        XCTAssertTrue(entered, "leaving Lilo from a playing video keeps it in view, as leaving its tab does")
        try await Task.sleep(for: .seconds(2))

        context.hiddenSpaceLifecycle.handleDidBecomeActive()
        let exited = await pollUntil(timeout: 5) { !engine.pip.isActive }
        XCTAssertTrue(exited, "back in Lilo, the video is in its tab again")
    }

    func testLeavingAndComingBackLeaveAPiPTheUserOpened() async throws {
        let tab = await makeTab(Self.playingVideo)
        try await play(tab)
        tab.togglePictureInPicture()
        let entered = await pollUntil(timeout: 5) { tab.pip.isActive }
        XCTAssertTrue(entered)

        tab.autoEnterPictureInPictureIfEligible()
        tab.restoreFromAutoPictureInPicture()

        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(tab.pip.isActive)
    }

    func testThePiPWindowsReturnButtonShowsATabOfAnotherSpace() async throws {
        let browserContext = try await TemporaryBrowserContext()
        addTeardownBlock { @MainActor in browserContext.tearDown() }
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        let videoSpace = try context.spaceManager.createSpace(name: "Video", profileId: profileId)
        let otherSpace = try context.spaceManager.createSpace(name: "Other", profileId: profileId)
        let window = makeTestWindow(context, showing: videoSpace.id)
        let tab = try XCTUnwrap(window.createTabStateFirst(url: nil))
        let engine = try XCTUnwrap(window.tabManager.engineTab(for: tab.id))
        await show(engine, Self.playingVideo)
        let host = try XCTUnwrap(engine.view.window)
        window.contentContainerView.frame = host.contentView!.bounds
        host.contentView!.addSubview(window.contentContainerView)
        window.showContentView(for: engine)
        try await play(engine)
        engine.togglePictureInPicture()
        let entered = await pollUntil(timeout: 5) { engine.pip.isActive }
        XCTAssertTrue(entered)
        try await Task.sleep(for: .seconds(2))
        window.switchToSpace(otherSpace.id)
        XCTAssertNil(engine.view.window)

        // What the PiP window's return button does: AVKit asks WebKit's presentation interface whether it may close.
        func presentation(_ controller: NSViewController?) -> NSObject? {
            guard let controller else { return nil }
            if NSStringFromClass(type(of: controller)).contains("PIP") { return controller.value(forKey: "delegate") as? NSObject }
            return controller.children.lazy.compactMap { presentation($0) }.first ?? presentation(controller.presentedViewControllers?.first)
        }
        let interface = try XCTUnwrap(NSApp.windows.lazy.compactMap { presentation($0.contentViewController) }.first)
        _ = interface.perform(NSSelectorFromString("pipShouldClose:"), with: nil)

        let returned = await pollUntil(timeout: 5) { !engine.pip.isActive }
        XCTAssertTrue(returned, "the video goes back into its tab")
        XCTAssertEqual(window.tabManager.currentSpaceId, videoSpace.id)
        XCTAssertEqual(window.tabManager.activeOpenTabId, tab.id)
    }
}
