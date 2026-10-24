import WebKit
import XCTest
@testable import Lilo

/// The user content controller is cached and shared per data store, so one region-selection request must never clobber
/// or orphan another's handler.
@MainActor
final class PageSnapshotServiceRegionSelectionTests: XCTestCase {

    private func makeReadyTab() async throws -> WKWebViewTab {
        let tab = WKWebViewTab(configuration: WKWebViewConfiguration())
        tab.wkWebView.loadHTMLString("<html><body>hello</body></html>", baseURL: nil as URL?)
        try await waitUntilLoaded(tab)
        return tab
    }

    /// Starting a second selection on the same tab must cleanly cancel the first (nil completion),
    /// not silently steal its handler out from under it, and the second selection must still work.
    func testStartingSecondSelectionCancelsFirstAndSecondCompletesNormally() async throws {
        let tab = try await makeReadyTab()
        defer { tab.teardown() }

        var firstResult: CGRect?? // outer optional = "not yet called"
        tab.startRegionSelection { rect in firstResult = rect }

        try await waitForOverlay(tab)

        var secondResult: CGRect?? // outer optional = "not yet called"
        tab.startRegionSelection { rect in secondResult = rect }

        // The first selection must have been cancelled (called back with nil) before the second
        // request's handler is installed, never left dangling.
        try await waitUntil { firstResult != nil }
        XCTAssertEqual(firstResult, .some(nil))

        try await waitForOverlay(tab)
        try await simulateDrag(tab, x1: 10, y1: 20, x2: 110, y2: 220)

        try await waitUntil { secondResult != nil }
        XCTAssertEqual(secondResult, .some(CGRect(x: 10, y: 20, width: 100, height: 200)))
    }

    /// A page navigation must cancel any pending region selection rather than leave its handler
    /// registered forever on the shared, cross-tab controller.
    func testNavigationCancelsPendingRegionSelection() async throws {
        let tab = try await makeReadyTab()
        defer { tab.teardown() }

        var result: CGRect?? // outer optional = "not yet called"
        tab.startRegionSelection { rect in result = rect }
        try await waitForOverlay(tab)

        tab.wkWebView.loadHTMLString("<html><body>elsewhere</body></html>", baseURL: nil as URL?)

        try await waitUntil { result != nil }
        XCTAssertEqual(result, .some(nil))
    }

    /// Tearing down a tab with a pending selection must cancel it rather than leak the handler
    /// registration on the shared controller for the lifetime of the process.
    func testTeardownCancelsPendingRegionSelection() async throws {
        let tab = try await makeReadyTab()

        var result: CGRect?? // outer optional = "not yet called"
        tab.startRegionSelection { rect in result = rect }
        try await waitForOverlay(tab)

        tab.teardown()

        try await waitUntil { result != nil }
        XCTAssertEqual(result, .some(nil))
    }

    /// Two tabs of the same data store share one `WKUserContentController`
    /// (`WKEngineFactory.cachedContentController`). Concurrent selections in different tabs must
    /// resolve independently: neither may clobber or steal the other's result.
    func testConcurrentSelectionsInDifferentTabsDoNotClobberEachOther() async throws {
        let factory = WKEngineFactory()
        let tabA = factory.createTab(configuration: WKEngineFactory.Configuration())
        let tabB = factory.createTab(configuration: WKEngineFactory.Configuration())
        defer { tabA.teardown(); tabB.teardown() }

        tabA.wkWebView.loadHTMLString("<html><body>A</body></html>", baseURL: nil as URL?)
        tabB.wkWebView.loadHTMLString("<html><body>B</body></html>", baseURL: nil as URL?)
        try await waitUntilLoaded(tabA)
        try await waitUntilLoaded(tabB)

        var resultA: CGRect?? // outer optional = "not yet called"
        var resultB: CGRect?? // outer optional = "not yet called"
        tabA.startRegionSelection { rect in resultA = rect }
        tabB.startRegionSelection { rect in resultB = rect }

        try await waitForOverlay(tabA)
        try await waitForOverlay(tabB)

        try await simulateDrag(tabA, x1: 1, y1: 2, x2: 51, y2: 52)
        try await simulateDrag(tabB, x1: 3, y1: 4, x2: 63, y2: 84)

        try await waitUntil { resultA != nil }
        try await waitUntil { resultB != nil }

        XCTAssertEqual(resultA, .some(CGRect(x: 1, y: 2, width: 50, height: 50)))
        XCTAssertEqual(resultB, .some(CGRect(x: 3, y: 4, width: 60, height: 80)))
    }

    /// Cancelling with nothing pending must be a harmless no-op.
    func testCancelWithNoPendingSelectionIsNoOp() async throws {
        let tab = try await makeReadyTab()
        defer { tab.teardown() }

        tab.cancelRegionSelection()
        tab.cancelRegionSelection()
    }

    // MARK: - Helpers

    /// The initial empty about:blank already reads complete, so the loaded page's body must have content;
    /// `!tab.isLoading` waits out the late navigation callback that would cancel a pending selection.
    private func waitUntilLoaded(_ tab: WKWebViewTab, timeout: TimeInterval = 5) async throws {
        let loaded = await pollUntil(timeout: timeout) {
            let condition = "document.readyState === 'complete' && document.body?.hasChildNodes() === true"
            return ((try? await tab.wkWebView.evaluateJavaScript(condition)) as? Bool) == true && !tab.isLoading
        }
        if !loaded { XCTFail("Timed out waiting for tab to finish loading") }
    }

    private func waitForOverlay(_ tab: WKWebViewTab, timeout: TimeInterval = 5) async throws {
        try await waitForJavaScript(tab, "!!document.getElementById('__liloCapture')", timeout: timeout)
    }

    private func simulateDrag(_ tab: WKWebViewTab, x1: Int, y1: Int, x2: Int, y2: Int) async throws {
        _ = try? await tab.wkWebView.evaluateJavaScript("""
        (function() {
          var ov = document.getElementById('__liloCapture');
          if (!ov) return false;
          function fire(type, x, y) {
            ov.dispatchEvent(new PointerEvent(type, {clientX: x, clientY: y, pointerId: 1, button: 0, bubbles: true, cancelable: true}));
          }
          fire('pointerdown', \(x1), \(y1));
          fire('pointermove', \(x2), \(y2));
          fire('pointerup', \(x2), \(y2));
          return true;
        })()
        """)
    }

    /// Polls with real suspensions (not just `Task.yield()`) so a `DispatchQueue.main.async`-deferred
    /// completion (as `PageSnapshotService.cancelRegionSelection` uses) gets a chance to run.
    private func waitUntil(timeout: TimeInterval = 5, _ predicate: @MainActor () -> Bool) async throws {
        await pollUntil(timeout: timeout, predicate)
        XCTAssertTrue(predicate(), "Timed out waiting for condition")
    }

    private func waitForJavaScript(_ tab: WKWebViewTab, _ condition: String, timeout: TimeInterval = 5) async throws {
        let met = await pollUntil(timeout: timeout) {
            ((try? await tab.wkWebView.evaluateJavaScript(condition)) as? Bool) == true
        }
        if !met { XCTFail("Timed out waiting for JavaScript condition: \(condition)") }
    }
}
