import AppKit
import WebKit
import XCTest
@testable import Lilo

/// View > Zoom In, Zoom Out and Actual Size on the active page, and the levels kept per site.
@MainActor
final class PageZoomTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var profileId: UUID!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        profileId = try browserContext.context.profileManager.createProfile(name: "P").id
    }

    override func tearDown() {
        browserContext.context.settingsStore.defaultZoom = 1
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    private var zoomStore: ZoomStore {
        get throws { try browserContext.context.profileContexts.context(for: profileId).zoom }
    }

    private func makeWindow(isPrivate: Bool = false) throws -> MainWindowController {
        let space = try browserContext.context.spaceManager.createSpace(name: "S", profileId: profileId, isPrivate: isPrivate)
        return makeTestWindow(browserContext.context, showing: space.id)
    }

    /// Loads a local page under `baseURL` in the window's active tab, opening one first if needed.
    @discardableResult
    private func load(_ baseURL: String?, in window: MainWindowController) async throws -> WKWebViewTab {
        if window.tabManager.activeEngineTab == nil { _ = try XCTUnwrap(window.createTabStateFirst(url: URL(string: "about:blank"))) }
        let engine = try XCTUnwrap(window.tabManager.activeEngineTab)
        engine.wkWebView.loadHTMLString("<p>page</p>", baseURL: baseURL.flatMap(URL.init(string:)))
        // The blank tab is loaded too: only the new page's URL and text tell it apart.
        await pollUntil(timeout: 5) {
            guard engine.wkWebView.url?.absoluteString == baseURL ?? "about:blank" else { return false }
            return (try? await engine.wkWebView.evaluateJavaScript("document.body?.textContent")) as? String == "page"
        }
        return engine
    }

    func testZoomStepsThroughChromesLevels() async throws {
        let window = try makeWindow()
        let engine = try await load("https://example.com/", in: window)

        window.zoomInCurrentPage(nil)
        XCTAssertEqual(engine.pageZoom, 1.1, accuracy: 0.001)
        window.zoomInCurrentPage(nil)
        XCTAssertEqual(engine.pageZoom, 1.25, accuracy: 0.001)
        for _ in 0..<20 { window.zoomInCurrentPage(nil) }
        XCTAssertEqual(engine.pageZoom, 5, accuracy: 0.001)
        for _ in 0..<20 { window.zoomOutCurrentPage(nil) }
        XCTAssertEqual(engine.pageZoom, 0.25, accuracy: 0.001)
        window.zoomInCurrentPage(nil)
        XCTAssertEqual(engine.pageZoom, 1 / 3, accuracy: 0.001)
    }

    func testAPageWithoutAHostZoomsWithoutKeepingALevel() async throws {
        let window = try makeWindow()
        let engine = try await load(nil, in: window)

        window.zoomInCurrentPage(nil)

        XCTAssertEqual(engine.pageZoom, 1.1, accuracy: 0.001)
        XCTAssertTrue(try zoomStore.allZoomLevels.isEmpty)
    }

    func testActualSizeIsTheDefaultZoomAndOnlyOtherLevelsAreKept() async throws {
        browserContext.context.settingsStore.defaultZoom = 1.25
        let window = try makeWindow()
        let engine = try await load("https://example.com/", in: window)
        XCTAssertEqual(engine.pageZoom, 1.25, accuracy: 0.001)

        window.zoomInCurrentPage(nil)
        XCTAssertEqual(try zoomStore.allZoomLevels["example.com"] ?? 0, 1.5, accuracy: 0.001)
        window.resetCurrentPageZoom(nil)

        XCTAssertEqual(engine.pageZoom, 1.25, accuracy: 0.001)
        XCTAssertNil(try zoomStore.allZoomLevels["example.com"])

        window.zoomOutCurrentPage(nil)
        window.zoomOutCurrentPage(nil)
        try await load("https://example.com/next", in: window)

        XCTAssertEqual(engine.pageZoom, 1, accuracy: 0.001)
        XCTAssertEqual(try zoomStore.allZoomLevels["example.com"] ?? 0, 1, accuracy: 0.001)
    }

    func testAPrivateSpaceKeepsItsZoomInMemoryOverTheProfiles() async throws {
        let window = try makeWindow()
        try await load("https://example.com/", in: window)
        window.zoomInCurrentPage(nil)
        let privateWindow = try makeWindow(isPrivate: true)

        let engine = try await load("https://example.com/", in: privateWindow)
        XCTAssertEqual(engine.pageZoom, 1.1, accuracy: 0.001)
        privateWindow.zoomInCurrentPage(nil)
        try await load("https://example.com/next", in: privateWindow)

        XCTAssertEqual(engine.pageZoom, 1.25, accuracy: 0.001)
        XCTAssertEqual(try zoomStore.allZoomLevels, ["example.com": 1.1])
    }
}
