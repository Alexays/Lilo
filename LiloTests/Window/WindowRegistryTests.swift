import AppKit
import XCTest
@testable import Lilo

/// A tab is on screen in at most one window; the registry records which, and the store protects it.
@MainActor
final class WindowRegistryTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var registry: WindowRegistry { browserContext.context.windows }

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
    }

    override func tearDown() {
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    private func makeWindow() -> MainWindowController {
        let window = MainWindowController(context: browserContext.context)
        registry.add(window)
        return window
    }

    func testClaimHandsTheTabToTheClaimerAndNamesThePreviousWindow() {
        let first = makeWindow(), second = makeWindow(), tab = UUID()

        XCTAssertNil(registry.claim(tab, by: first))
        XCTAssertTrue(registry.claim(tab, by: second) === first)
        XCTAssertTrue(registry.displayingWindow(ofTab: tab) === second)
        XCTAssertNil(registry.claim(tab, by: second), "claiming a tab it already shows names no other window")
    }

    func testReleaseByAWindowThatNoLongerShowsTheTabKeepsTheClaim() {
        let first = makeWindow(), second = makeWindow(), tab = UUID()
        registry.claim(tab, by: first)
        registry.claim(tab, by: second)

        registry.release(tab, by: first)

        XCTAssertTrue(registry.displayingWindow(ofTab: tab) === second)
    }

    func testDisplayedTabsAreMirroredIntoTheStore() {
        let window = makeWindow(), a = UUID(), b = UUID()
        registry.claim(a, by: window)
        registry.claim(b, by: window)
        registry.release(a, by: window)

        XCTAssertEqual(browserContext.context.browserState.displayedTabIds, [b])
    }

    func testNoWindowServesAProfileItDoesNotShow() {
        let window = makeWindow()
        registry.noteActive(window)

        XCTAssertNil(registry.window(showingProfileOf: nil), "the active window must not stand in for another profile")
    }

    func testRemovingAWindowReleasesItsTabsAndActiveWindowFallsBack() {
        let first = makeWindow(), second = makeWindow(), tab = UUID()
        registry.claim(tab, by: second)
        registry.noteActive(second)

        registry.remove(second)

        XCTAssertNil(registry.displayingWindow(ofTab: tab))
        XCTAssertTrue(browserContext.context.browserState.displayedTabIds.isEmpty)
        XCTAssertTrue(registry.activeWindow === first)
    }

    /// One lifecycle controller trims for every window; a window closing never stops it.
    func testWindowsShareOneLifecycleControllerThatOutlivesThem() {
        let first = makeWindow()
        let second = makeWindow()
        let controller = browserContext.context.hiddenSpaceLifecycle

        second.windowWillClose(Notification(name: NSWindow.willCloseNotification))

        XCTAssertTrue(browserContext.context.hiddenSpaceLifecycle === controller)
        XCTAssertTrue(controller.isMonitoringMemoryPressure)
        XCTAssertTrue(registry.windows.contains { $0 === first })
    }
}
