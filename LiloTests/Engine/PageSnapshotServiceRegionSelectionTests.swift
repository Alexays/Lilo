import WebKit
import XCTest
@testable import Lilo

/// Region selection is a native overlay over the web view: driven by real mouse and key events, it reports the dragged
/// region in CSS pixels, leaves nothing in the page and nothing behind once it ends.
@MainActor
final class PageSnapshotServiceRegionSelectionTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows = []
        try await super.tearDown()
    }

    func testADragReportsTheRegionInCSSPixelsAndRemovesTheOverlay() async throws {
        let tab = try await makeShownTab()
        defer { tab.teardown() }
        let subviews = tab.wkWebView.subviews.count

        var result: CGRect?? // outer optional = "not yet called"
        tab.startRegionSelection { rect in result = rect }
        XCTAssertEqual(tab.wkWebView.subviews.count, subviews + 1)
        drag(tab, from: NSPoint(x: 10, y: 20), to: NSPoint(x: 110, y: 220))

        try await waitUntil { result != nil }
        XCTAssertEqual(result, .some(CGRect(x: 10, y: 20, width: 100, height: 200)))
        XCTAssertEqual(tab.wkWebView.subviews.count, subviews)
    }

    /// The page can tell nothing is going on: no element, no handler, no `window.webkit`.
    func testThePageSeesNothingOfASelection() async throws {
        let tab = try await makeShownTab()
        defer { tab.teardown() }
        let probe = "document.querySelectorAll('*').length + ':' + typeof window.webkit"
        let before = try await tab.wkWebView.evaluateJavaScript(probe) as? String

        tab.startRegionSelection { _ in }
        let during = try await tab.wkWebView.evaluateJavaScript(probe) as? String

        XCTAssertEqual(during, before)
        XCTAssertEqual(during?.hasSuffix(":undefined"), true)
    }

    func testStartingSecondSelectionCancelsFirstAndSecondCompletesNormally() async throws {
        let tab = try await makeShownTab()
        defer { tab.teardown() }

        var firstResult: CGRect?? // outer optional = "not yet called"
        tab.startRegionSelection { rect in firstResult = rect }
        var secondResult: CGRect?? // outer optional = "not yet called"
        tab.startRegionSelection { rect in secondResult = rect }

        try await waitUntil { firstResult != nil }
        XCTAssertEqual(firstResult, .some(nil))

        drag(tab, from: NSPoint(x: 10, y: 20), to: NSPoint(x: 110, y: 220))
        try await waitUntil { secondResult != nil }
        XCTAssertEqual(secondResult, .some(CGRect(x: 10, y: 20, width: 100, height: 200)))
    }

    func testEscapeCancelsAndRemovesTheOverlay() async throws {
        let tab = try await makeShownTab()
        defer { tab.teardown() }
        let subviews = tab.wkWebView.subviews.count

        var result: CGRect?? // outer optional = "not yet called"
        tab.startRegionSelection { rect in result = rect }
        let window = try XCTUnwrap(tab.wkWebView.window)
        NSApp.sendEvent(try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53
        )))

        try await waitUntil { result != nil }
        XCTAssertEqual(result, .some(nil))
        XCTAssertEqual(tab.wkWebView.subviews.count, subviews)
    }

    func testAClickWithoutADragCancels() async throws {
        let tab = try await makeShownTab()
        defer { tab.teardown() }

        var result: CGRect?? // outer optional = "not yet called"
        tab.startRegionSelection { rect in result = rect }
        drag(tab, from: NSPoint(x: 50, y: 50), to: NSPoint(x: 52, y: 52))

        try await waitUntil { result != nil }
        XCTAssertEqual(result, .some(nil))
    }

    /// Switching tabs takes the web view out of the window or hides it: either ends the selection.
    func testLeavingTheWindowOrHidingCancels() async throws {
        let tab = try await makeShownTab()
        defer { tab.teardown() }
        let superview = try XCTUnwrap(tab.view.superview)

        var removed: CGRect?? // outer optional = "not yet called"
        tab.startRegionSelection { rect in removed = rect }
        tab.view.removeFromSuperview()
        try await waitUntil { removed != nil }
        XCTAssertEqual(removed, .some(nil))

        superview.addSubview(tab.view)
        var hidden: CGRect?? // outer optional = "not yet called"
        tab.startRegionSelection { rect in hidden = rect }
        tab.view.isHidden = true
        try await waitUntil { hidden != nil }
        XCTAssertEqual(hidden, .some(nil))
    }

    func testNavigationCancelsPendingRegionSelection() async throws {
        let tab = try await makeShownTab()
        defer { tab.teardown() }

        var result: CGRect?? // outer optional = "not yet called"
        tab.startRegionSelection { rect in result = rect }
        tab.wkWebView.loadHTMLString("<html><body>elsewhere</body></html>", baseURL: nil as URL?)

        try await waitUntil { result != nil }
        XCTAssertEqual(result, .some(nil))
    }

    func testTeardownCancelsPendingRegionSelection() async throws {
        let tab = try await makeShownTab()

        var result: CGRect?? // outer optional = "not yet called"
        tab.startRegionSelection { rect in result = rect }
        tab.teardown()

        try await waitUntil { result != nil }
        XCTAssertEqual(result, .some(nil))
    }

    func testConcurrentSelectionsInDifferentTabsDoNotClobberEachOther() async throws {
        let factory = WKEngineFactory()
        let tabA = try await makeShownTab(factory.createTab(configuration: WKEngineFactory.Configuration()))
        let tabB = try await makeShownTab(factory.createTab(configuration: WKEngineFactory.Configuration()))
        defer { tabA.teardown(); tabB.teardown() }

        var resultA: CGRect?? // outer optional = "not yet called"
        var resultB: CGRect?? // outer optional = "not yet called"
        tabA.startRegionSelection { rect in resultA = rect }
        tabB.startRegionSelection { rect in resultB = rect }
        drag(tabA, from: NSPoint(x: 1, y: 2), to: NSPoint(x: 51, y: 52))
        drag(tabB, from: NSPoint(x: 3, y: 4), to: NSPoint(x: 63, y: 84))

        try await waitUntil { resultA != nil && resultB != nil }
        XCTAssertEqual(resultA, .some(CGRect(x: 1, y: 2, width: 50, height: 50)))
        XCTAssertEqual(resultB, .some(CGRect(x: 3, y: 4, width: 60, height: 80)))
    }

    func testCancelWithNoPendingSelectionIsNoOp() async throws {
        let tab = try await makeShownTab()
        defer { tab.teardown() }

        tab.cancelRegionSelection()
        tab.cancelRegionSelection()
    }

    /// The capture holds exactly what was under the dragged rectangle, at the display's scale, on a zoomed and scrolled page:
    /// a red box drawn at view points (100, 50) and 80 x 60, on blue.
    func testTheCaptureIsWhatWasSelectedOnAZoomedScrolledPage() async throws {
        for (zoom, scroll) in [(1.0, 0.0), (2.0, 0.0), (1.5, 300.0)] {
            let tab = try await makeShownTab(body: """
                <div style="position:absolute;left:\(100 / zoom)px;top:\(scroll + 50 / zoom)px;width:\(80 / zoom)px;\
                height:\(60 / zoom)px;background:#f00"></div><div style="height:3000px"></div>
                """)
            defer { tab.teardown() }
            tab.wkWebView.pageZoom = zoom
            // Polled, not awaited on a frame: a window kept out of sight gets no animation frames.
            _ = try await tab.wkWebView.evaluateJavaScript("scrollTo(0, \(scroll))")
            let scrolled = await pollUntil(timeout: 5) {
                ((try? await tab.wkWebView.evaluateJavaScript("scrollY")) as? NSNumber)?.doubleValue == scroll
            }
            XCTAssertTrue(scrolled, "zoom \(zoom)")

            var result: CGRect?? // outer optional = "not yet called"
            tab.startRegionSelection { rect in result = rect }
            drag(tab, from: NSPoint(x: 90, y: 40), to: NSPoint(x: 190, y: 120))
            try await waitUntil { result != nil }
            let rect = try XCTUnwrap(result ?? nil, "zoom \(zoom)")

            // Out of the window, as an off-screen window never presents the update the snapshot waits for.
            let scale = try XCTUnwrap(tab.wkWebView.window).backingScaleFactor
            tab.view.removeFromSuperview()
            var snapshot: NSImage?? // outer optional = "not yet returned"
            Task { snapshot = await tab.takeRegionSnapshot(rect: rect) }
            try await waitUntil(timeout: 10) { snapshot != nil }
            let image = try XCTUnwrap(snapshot ?? nil, "zoom \(zoom)")
            XCTAssertEqual(image.size, NSSize(width: 100, height: 80), "zoom \(zoom)")
            let pixels = try XCTUnwrap(image.snapshotPixels)
            XCTAssertEqual(CGFloat(pixels.width), 100 * scale, "zoom \(zoom)")
            let bitmap = NSBitmapImageRep(cgImage: pixels)
            // Image points: the box spans 10...90 across and 10...70 down.
            for (x, y, red) in [(12, 12, true), (88, 68, true), (5, 5, false), (95, 75, false), (50, 75, false)] {
                let color = try XCTUnwrap(bitmap.colorAt(x: Int(CGFloat(x) * scale), y: Int(CGFloat(y) * scale)))
                XCTAssertEqual(color.redComponent > 0.5 && color.blueComponent < 0.5, red, "zoom \(zoom) at (\(x), \(y))")
            }
        }
    }

    // MARK: - Helpers

    private func makeShownTab(
        _ existing: WKWebViewTab? = nil,
        body: String = "hello"
    ) async throws -> WKWebViewTab {
        let tab = existing ?? WKWebViewTab(configuration: WKWebViewConfiguration())
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.orderFrontRegardless()
        windows.append(window)
        tab.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(tab.view)
        tab.wkWebView.loadHTMLString("<html><body style=\"margin:0;background:#00f\">\(body)</body></html>", baseURL: nil as URL?)
        // The initial empty about:blank already reads complete, so the loaded page's body must have content;
        // `!tab.isLoading` waits out the late navigation callback that would cancel a pending selection.
        let loaded = await pollUntil(timeout: 5) {
            let condition = "document.readyState === 'complete' && document.body?.hasChildNodes() === true"
            return ((try? await tab.wkWebView.evaluateJavaScript(condition)) as? Bool) == true && !tab.isLoading
        }
        if !loaded { XCTFail("Timed out waiting for tab to finish loading") }
        return tab
    }

    /// A press, a move and a release, in the web view's top-left points, through the window as AppKit delivers them.
    private func drag(_ tab: WKWebViewTab, from start: NSPoint, to end: NSPoint) {
        guard let window = tab.wkWebView.window else { return XCTFail("The tab is not in a window") }
        for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
            let flipped = NSPoint(x: point.x, y: tab.wkWebView.isFlipped ? point.y : tab.wkWebView.bounds.height - point.y)
            guard let event = NSEvent.mouseEvent(
                with: type, location: tab.wkWebView.convert(flipped, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else { return XCTFail("Could not make a \(type) event") }
            window.sendEvent(event)
        }
    }

    /// Polls with real suspensions so the main-queue completion of a selection gets a chance to run.
    private func waitUntil(timeout: TimeInterval = 5, _ predicate: @MainActor () -> Bool) async throws {
        await pollUntil(timeout: timeout, predicate)
        XCTAssertTrue(predicate(), "Timed out waiting for condition")
    }
}
