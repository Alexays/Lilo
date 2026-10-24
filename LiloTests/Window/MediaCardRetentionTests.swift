import WebKit
import XCTest
@testable import Lilo

@MainActor
final class MediaCardRetentionTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var window: MainWindowController!
    private var profileId: UUID!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        let context = browserContext.context
        profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId)
        window = makeTestWindow(context, showing: space.id)
        window.createTabStateFirst(url: URL(string: "https://example.com"))
    }

    override func tearDown() {
        window = nil
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    /// A background tab paused from the media card, its Space then hidden so its engine is parked.
    private func tabPausedFromCard() async throws -> WKWebViewTab {
        let tab = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "https://media.example"), activate: false))
        let engine = try XCTUnwrap(window.tabManager.engineTab(for: tab.id))
        window.tab(engine, didUpdateAudioPlaying: true)
        window.controlMedia(tabId: tab.id, action: "pause")
        window.tab(engine, didUpdateAudioPlaying: false)
        let context = window.context
        let other = try context.spaceManager.createSpace(name: "Other", profileId: profileId)
        window.switchToSpace(other.id)
        XCTAssertTrue(context.browserState.liveEngine(forTab: tab.id) === engine, "a tab paused from the card keeps its engine")
        await scriptsSettled(engine)
        return engine
    }

    /// WebKit raises on a script reply to a suspended page: the media scripts must answer before a freeze.
    private func scriptsSettled(_ engine: WKWebViewTab) async {
        await Task.yield()
        _ = await engine.hasMediaTrackControls()
    }

    func testTabPausedFromCardFreezesOnlyAfterItsGrace() async throws {
        let engine = try await tabPausedFromCard()
        XCTAssertNotNil(window.context.mediaTabs[engine.id], "the card keeps a tab paused from it")

        window.context.browserState.freezeIdleEngines(freezeThreshold: 60, now: Date().addingTimeInterval(10 * 60))
        XCTAssertFalse(engine.isFrozen)

        window.context.browserState.freezeIdleEngines(freezeThreshold: 60, now: Date().addingTimeInterval(31 * 60))
        XCTAssertTrue(engine.isFrozen)
        engine.resume()   // the context's teardown cannot touch a suspended page
    }

    func testPausingFromThePageEndsTheCardPause() async throws {
        let engine = try await tabPausedFromCard()
        window.tab(engine, didUpdateAudioPlaying: true)
        window.tab(engine, didUpdateAudioPlaying: false)
        await scriptsSettled(engine)

        XCTAssertNil(window.context.mediaTabs[engine.id], "a pause from the page takes the tab off the card")
        window.context.browserState.freezeIdleEngines(freezeThreshold: 60, now: Date().addingTimeInterval(10 * 60))
        // Passes everywhere but sometimes on CI: the message says what kept the engine awake there.
        let state = window.context.browserState
        let tab = state.updateTab(id: engine.id) { _ in }?.new
        XCTAssertTrue(engine.isFrozen, """
            live: \(state.liveEngine(forTab: engine.id) === engine), displayed: \(state.displayedTabIds.contains(engine.id)), \
            lent: \(engine.lentToExtensionAt.map { "\(Date().timeIntervalSince($0))s ago" } ?? "never"), \
            inspector: \(engine.shouldRetainForWebInspector), audio: \(tab?.isAudioPlaying ?? false), \
            paused from card: \(tab?.pausedFromCardAt?.description ?? "no"), audio stopped: \(tab?.lastAudioStoppedAt?.description ?? "no"), \
            capture: \(tab.map { $0.isMicrophoneActive || $0.isCameraActive || $0.isScreenSharing } ?? false)
            """)
        engine.resume()
    }
}
