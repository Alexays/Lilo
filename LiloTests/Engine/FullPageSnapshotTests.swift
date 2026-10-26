import XCTest
import WebKit
@testable import Lilo

@MainActor
final class FullPageSnapshotTests: XCTestCase {

    func testTakeFullPageSnapshotReturnsTheWholeDocumentNotTheViewport() async throws {
        let tab = try await loadedTab(
            width: 800,
            height: 600,
            body: "<div style=\"width:800px;height:2000px;\"></div>",
            settlesWhen: "document.documentElement.scrollHeight", isAtLeast: 2000
        )

        let snapshot = await tab.takeFullPageSnapshot()?.image
        let image = try XCTUnwrap(snapshot, "Expected a non-nil snapshot")
        XCTAssertEqual(image.size.height, 2000, accuracy: 1,
            "Snapshot should span the document, not the 600pt viewport")
    }

    /// Many viewports tall, so the capture is only whole if every scrolled frame lands in order.
    func testTakeFullPageSnapshotStitchesAPageManyViewportsTall() async throws {
        let tab = try await loadedTab(
            width: 200,
            height: 600,
            body: """
                <div style="width:200px;height:8000px;background:#ff0000;"></div>
                <div style="width:200px;height:8000px;background:#0000ff;"></div>
                """,
            settlesWhen: "document.documentElement.scrollHeight", isAtLeast: 16000
        )

        let capture = await tab.takeFullPageSnapshot()
        XCTAssertEqual(capture?.truncated, false)
        let snapshot = capture?.image
        let image = try XCTUnwrap(snapshot, "Expected a non-nil snapshot")
        XCTAssertEqual(image.size.height, 16000, accuracy: 1)
        try assertRedOverBlue(image)
    }

    /// A page past the height limit is captured down to the limit, and the capture says it was cut.
    func testTakeFullPageSnapshotStopsAtTheHeightLimitAndSaysSo() async throws {
        let tab = try await loadedTab(
            width: 200,
            height: 3000,
            body: """
                <div style="width:200px;height:160000px;background:#ff0000;"></div>
                """,
            settlesWhen: "document.documentElement.scrollHeight", isAtLeast: 160_000
        )

        let snapshot = await tab.takeFullPageSnapshot()
        let capture = try XCTUnwrap(snapshot, "Expected a non-nil snapshot")
        XCTAssertTrue(capture.truncated)
        XCTAssertEqual(capture.image.size.height, 150_000, accuracy: 1)
    }

    /// A fixed header belongs at the top of the capture once, not at the top of every scrolled frame.
    func testTakeFullPageSnapshotShowsAFixedHeaderOnlyOnce() async throws {
        let tab = try await loadedTab(
            width: 200,
            height: 600,
            body: """
                <div style="position:fixed;top:0;left:0;width:200px;height:50px;background:#ff0000;"></div>
                <div style="width:200px;height:1800px;background:#0000ff;"></div>
                """,
            settlesWhen: "document.documentElement.scrollHeight", isAtLeast: 1800
        )

        let snapshot = await tab.takeFullPageSnapshot()?.image
        let image = try XCTUnwrap(snapshot, "Expected a non-nil snapshot")
        XCTAssertEqual(image.size.height, 1800, accuracy: 1)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cg)
        let pixelsPerPoint = CGFloat(bitmap.pixelsHigh) / image.size.height
        let header = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: Int(20 * pixelsPerPoint)))
        let secondFrameTop = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: Int(620 * pixelsPerPoint)))
        XCTAssertGreaterThan(header.redComponent, header.blueComponent, "The header is missing from the top")
        XCTAssertGreaterThan(secondFrameTop.blueComponent, secondFrameTop.redComponent,
            "The header repeats at the top of the second frame")
    }

    /// Capturing scrolls the page; the user has to land back where they were.
    func testCaptureRestoresTheScrollPosition() async throws {
        let tab = try await loadedTab(
            width: 200,
            height: 600,
            body: "<div style=\"width:200px;height:3000px;\"></div>",
            settlesWhen: "document.documentElement.scrollHeight", isAtLeast: 3000
        )
        _ = try await tab.wkWebView.evaluateJavaScript("window.scrollTo(0, 1234)")

        _ = await tab.takeFullPageSnapshot()

        let scrollY = (try? await tab.wkWebView.evaluateJavaScript("window.scrollY")) as? NSNumber
        XCTAssertEqual(scrollY?.doubleValue ?? -1, 1234, accuracy: 1)
    }

    /// A document pinned to the viewport that scrolls an inner container: the document's own scroll
    /// extent is one screen, so a capture is only whole if that container is expanded first.
    func testTakeFullPageSnapshotExpandsAnInnerScrollContainer() async throws {
        let tab = try await loadedTab(
            width: 200,
            height: 600,
            bodyStyle: "margin:0;padding:0;overflow:hidden;height:100vh;",
            body: """
                <div id="scroller" style="height:100%;overflow-y:auto;">
                    <div style="height:1500px;background:#ff0000;"></div>
                    <div style="height:1500px;background:#0000ff;"></div>
                </div>
                """,
            settlesWhen: "document.getElementById('scroller').scrollHeight", isAtLeast: 3000
        )

        let snapshot = await tab.takeFullPageSnapshot()?.image
        let image = try XCTUnwrap(snapshot, "Expected a non-nil snapshot")
        XCTAssertEqual(image.size.height, 3000, accuracy: 1,
            "The scroll container should have been expanded to its content height")
        try assertRedOverBlue(image)
    }

    /// A flex scroller that also hides its horizontal overflow: `overflow-y: visible` next to
    /// `overflow-x: hidden` computes back to `auto`, so it stays a scroller its flex column keeps one
    /// screen tall unless its horizontal axis is relaxed too.
    func testTakeFullPageSnapshotExpandsAScrollerThatHidesHorizontalOverflow() async throws {
        let tab = try await loadedTab(
            width: 200,
            height: 600,
            bodyStyle: "margin:0;padding:0;overflow:hidden;height:100vh;display:flex;flex-direction:column;",
            body: """
                <div style="display:flex;flex-direction:column;flex:1 1 0px;min-height:0;">
                    <div id="scroller" style="flex:1 1 auto;min-height:0;overflow-x:hidden;overflow-y:auto;">
                        <div style="height:1500px;background:#ff0000;"></div>
                        <div style="height:1500px;background:#0000ff;"></div>
                    </div>
                </div>
                """,
            settlesWhen: "document.getElementById('scroller').scrollHeight", isAtLeast: 3000
        )

        let snapshot = await tab.takeFullPageSnapshot()?.image
        let image = try XCTUnwrap(snapshot, "Expected a non-nil snapshot")
        XCTAssertEqual(image.size.height, 3000, accuracy: 1,
            "The scroll container should have been expanded to its content height")
        try assertRedOverBlue(image)
    }

    /// The parent must ask the child frame its height and resize the `<iframe>`, since nothing else grows the parent document.
    /// The `data:` child has an opaque origin, so it is reached like a cross-origin frame.
    func testTakeFullPageSnapshotExpandsAScrollingChildFrame() async throws {
        let child = "data:text/html,<body style='margin:0'>"
            + "<div style='height:1250px;background:%23ff0000'></div>"
            + "<div style='height:1250px;background:%230000ff'></div></body>"
        let tab = try await loadedTab(
            width: 200,
            height: 600,
            bodyStyle: "margin:0;padding:0;overflow:hidden;height:100vh;",
            body: "<iframe style=\"width:200px;height:100%;border:0\" src=\"\(child)\""
                + " onload=\"window.__childLoaded=1\"></iframe>",
            settlesWhen: "window.__childLoaded ? 1 : 0",
            isAtLeast: 1
        )

        let snapshot = await tab.takeFullPageSnapshot()?.image
        let image = try XCTUnwrap(snapshot, "Expected a non-nil snapshot")
        XCTAssertEqual(image.size.height, 2500, accuracy: 1,
            "The frame should have been grown to its content height")
        try assertRedOverBlue(image)
    }

    /// A transparent viewport-sized frame behind the page (LinkedIn preloads one) is no candidate, however large.
    func testTakeFullPageSnapshotIgnoresAnInvisibleFrame() async throws {
        let child = "data:text/html,<body style='margin:0'><div style='height:1000px'></div></body>"
        let tab = try await loadedTab(
            width: 200,
            height: 600,
            bodyStyle: "margin:0;padding:0;overflow:hidden;height:100vh;",
            body: """
                <iframe style="opacity:0;z-index:-1;position:absolute;top:0;width:100vw;height:100vh;border:0"
                    src="\(child)" onload="window.__childLoaded=1"></iframe>
                <div id="scroller" style="height:100%;overflow-y:auto;">
                    <div style="height:1500px;background:#ff0000;"></div>
                    <div style="height:1500px;background:#0000ff;"></div>
                </div>
                """,
            settlesWhen: "window.__childLoaded ? document.getElementById('scroller').scrollHeight : 0",
            isAtLeast: 3000
        )

        let snapshot = await tab.takeFullPageSnapshot()?.image
        let image = try XCTUnwrap(snapshot, "Expected a non-nil snapshot")
        XCTAssertEqual(image.size.height, 3000, accuracy: 1, "The visible scroller should have been expanded")
        try assertRedOverBlue(image)
    }

    /// Expansion is for the duration of the capture only: the page the user is looking at must come
    /// back exactly as it was, inline styles included.
    func testCaptureLeavesTheExpandedPageAsItFoundIt() async throws {
        let tab = try await loadedTab(
            width: 200,
            height: 600,
            bodyStyle: "margin:0;padding:0;overflow:hidden;height:100vh;",
            body: """
                <div id="scroller" style="height:100%;overflow-y:auto;">
                    <div style="height:3000px;background:#ff0000;"></div>
                </div>
                """,
            settlesWhen: "document.getElementById('scroller').scrollHeight", isAtLeast: 3000
        )
        _ = await tab.takeFullPageSnapshot()

        // Restore is fire-and-forget, so give it a moment to land.
        let style = "document.getElementById('scroller').getAttribute('style')"
        await pollUntil(timeout: 5) { (try? await tab.wkWebView.evaluateJavaScript(style)) as? String == "height:100%;overflow-y:auto;" }

        let inlineStyle = try await tab.wkWebView.evaluateJavaScript(style) as? String
        XCTAssertEqual(inlineStyle, "height:100%;overflow-y:auto;")
        let height = (try? await tab.wkWebView.evaluateJavaScript("document.documentElement.scrollHeight")) as? NSNumber
        XCTAssertEqual(height?.doubleValue ?? 0, 600, accuracy: 1, "The document is still expanded")
    }

    func testTakeFullPageSnapshotReturnsNilForBlankTab() async {
        let tab = WKWebViewTab(configuration: WKWebViewConfiguration())
        let image = await tab.takeFullPageSnapshot()
        XCTAssertNil(image, "A blank tab has no rendered content to snapshot")
    }

    // MARK: - Helpers

    /// Every page here is red over blue, so a snapshot that lost its bottom half, or stacked its
    /// pieces in the wrong order, shows up as the wrong colour at one end.
    private func assertRedOverBlue(_ image: NSImage, file: StaticString = #filePath, line: UInt = #line) throws {
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cg)
        let top = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 8))
        let bottom = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh - 8))
        XCTAssertGreaterThan(top.redComponent, top.blueComponent,
            "Top of the capture is \(top), not red", file: file, line: line)
        XCTAssertGreaterThan(bottom.blueComponent, bottom.redComponent,
            "Bottom of the capture is \(bottom), not blue", file: file, line: line)
    }

    /// A tab whose document has loaded and laid out.
    private func loadedTab(
        width: Double,
        height: Double,
        bodyStyle: String = "margin:0;padding:0;",
        body: String,
        settlesWhen probe: String,
        isAtLeast minimum: Double
    ) async throws -> WKWebViewTab {
        let tab = WKWebViewTab(configuration: WKWebViewConfiguration())
        tab.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        tab.wkWebView.loadHTMLString(
            "<html><body style=\"\(bodyStyle)\">\(body)</body></html>",
            baseURL: nil as URL?
        )

        var measured: Double?
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let readyState = (try? await tab.wkWebView.evaluateJavaScript("document.readyState")) as? String
            measured = ((try? await tab.wkWebView.evaluateJavaScript(probe)) as? NSNumber)?.doubleValue
            if !tab.isLoading, readyState == "complete", (measured ?? 0) >= minimum { return tab }
            await Task.yield()
        }

        XCTFail("Page never settled: \(probe) is \(measured ?? -1), wanted \(minimum)")
        return tab
    }
}
