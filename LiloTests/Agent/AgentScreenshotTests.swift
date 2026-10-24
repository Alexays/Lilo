import AppKit
import XCTest
@testable import Lilo

@MainActor
final class AgentScreenshotTests: AgentToolTestCase {
    func testFullResolutionFollowsTheEmulatedDevicePixelRatio() async throws {
        let tab = try await agentTab(showing: """
            <!doctype html><body style="margin:0;height:3000px">
            <div id="box" style="position:absolute;left:100px;top:1500px;width:200px;height:100px;background:#00ff00"></div></body>
            """)
        _ = await client.callTool("emulate", ["tabId": tab, "deviceScaleFactor": 3])
        await pollUntil { (try? await self.js("devicePixelRatio", tab: tab)) as? NSNumber == 3 }

        let plain = await client.callTool("computer", ["tabId": tab, "action": "screenshot"])
        let full = await client.callTool("computer", ["tabId": tab, "action": "screenshot", "fullResolution": true])
        let element = await client.callTool("computer", ["tabId": tab, "action": "screenshot", "selector": "#box", "fullResolution": true])

        XCTAssertEqual(try bitmap(plain).pixelsWide, 1280, "a plain screenshot stays in click coordinates")
        XCTAssertEqual(try bitmap(full).pixelsWide, 1280 * 3, full.text)
        XCTAssertEqual(try bitmap(full).pixelsHigh, 800 * 3)
        XCTAssertEqual(try bitmap(element).pixelsWide, 600, element.text)
        XCTAssertEqual(try bitmap(element).pixelsHigh, 300)
        XCTAssertTrue(full.text.contains("3x"), full.text)
    }

    func testElementCaptureKeepsItsMargin() async throws {
        let tab = try await agentTab(showing: """
            <!doctype html><body style="margin:0;height:3000px;background:#ffffff">
            <button style="position:absolute;left:300px;top:1500px;width:200px;height:100px;background:#00ff00;border:0">Box</button></body>
            """)
        let found = await client.callTool("find", ["tabId": tab, "query": "Box"]).text
        let ref = try XCTUnwrap(found.range(of: #"ref_\d+"#, options: .regularExpression).map { String(found[$0]) }, found)

        let reply = await client.callTool("computer", ["tabId": tab, "action": "screenshot", "ref": ref, "margin": 10])

        let image = try bitmap(reply)
        XCTAssertEqual(image.pixelsWide, 220, reply.text)
        XCTAssertEqual(image.pixelsHigh, 120)
        try assertColor(image, x: 3, y: 3, is: (1, 1, 1), "the margin shows the page")
        try assertColor(image, x: 30, y: 20, is: (0, 1, 0), "the element fills the middle")
        let scrollY = try await js("scrollY", tab: tab) as? Double ?? 0
        XCTAssertTrue(reply.text.contains("its top left at (290, \(Int(1490 - scrollY)))"), reply.text)
    }

    /// An app shell pinned to the viewport: the document never scrolls, its inner container does.
    func testFullPageGrowsAnInnerScrollerAndPutsItBack() async throws {
        let tab = try await agentTab(showing: """
            <!doctype html><body style="margin:0;height:100vh;overflow:hidden">
            <div id="scroller" style="height:100%;overflow-y:auto">
            <div style="height:1500px;background:#ff0000"></div><div style="height:1500px;background:#0000ff"></div></div></body>
            """)
        _ = try await js("document.getElementById('scroller').scrollTop = 700", tab: tab)

        let reply = await client.callTool("computer", ["tabId": tab, "action": "screenshot", "fullPage": true, "savePath": temporaryPNG()])

        let image = try saved(reply)
        XCTAssertEqual(image.pixelsHigh, 3000, reply.text)
        try assertColor(image, x: 640, y: 10, is: (1, 0, 0), "the scroller's top")
        try assertColor(image, x: 640, y: 2990, is: (0, 0, 1), "the scroller's bottom")
        await pollUntil { (try? await self.js("document.getElementById('scroller').scrollTop", tab: tab)) as? Double == 700 }
        let scrollTop = try await js("document.getElementById('scroller').scrollTop", tab: tab) as? Double
        let style = try await js("document.getElementById('scroller').getAttribute('style')", tab: tab) as? String
        XCTAssertEqual(scrollTop, 700)
        XCTAssertEqual(style, "height:100%;overflow-y:auto")
    }

    /// Sticky and fixed bars show once, where they sit on a page scrolled to its top, never in every viewport.
    func testFullPageShowsStickyAndFixedBarsOnce() async throws {
        let tab = try await agentTab(showing: """
            <!doctype html><body style="margin:0">
            <header style="position:sticky;top:0;height:50px;background:#00ff00"></header>
            <div style="height:3000px;background:#0000ff">
            <div class="masked"></div></div><style>.masked { position:relative; top:1500px; width:100px; height:100px; background:#ff0000; mask-image:\(Self.circle); mask-size:100% 100% }</style>
            <footer style="position:fixed;bottom:0;left:0;right:0;height:40px;background:#ff00ff"></footer></body>
            """)
        _ = try await js("scrollTo(0, 1000)", tab: tab)

        let reply = await client.callTool("computer", ["tabId": tab, "action": "screenshot", "fullPage": true, "savePath": temporaryPNG()])

        let image = try saved(reply)
        XCTAssertEqual(image.pixelsHigh, 3050, reply.text)
        try assertColor(image, x: 640, y: 20, is: (0, 1, 0), "the header at the top")
        for y in [790, 830, 1020, 1830] { try assertColor(image, x: 640, y: y, is: (0, 0, 1), "no bar repeats at \(y)") }
        try assertColor(image, x: 640, y: 3030, is: (1, 0, 1), "the fixed footer at the bottom")
        try assertColor(image, x: 50, y: 1600, is: (1, 0, 0), "the masked element's circle")
        try assertColor(image, x: 3, y: 1553, is: (0, 0, 1), "what its mask cuts away")
        let scrollY = try await js("scrollY", tab: tab) as? Double
        XCTAssertEqual(scrollY, 1000, "the page is left where it was")
    }

    /// An image that loads only near the viewport, and content an IntersectionObserver reveals.
    func testFullPageLoadsLazyContent() async throws {
        let red = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 3,
                                                 hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<4 { for y in 0..<4 { red.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1), atX: x, y: y) } }
        let png = try XCTUnwrap(red.representation(using: .png, properties: [:]))
        let page = Data("""
            <!doctype html><body style="margin:0;background:#ffffff">
            <div style="height:4000px"></div>
            <img loading="lazy" src="/red.png" style="display:block;width:200px;height:200px">
            <div id="late" style="height:200px"></div>
            <script>
            new IntersectionObserver(([entry]) => { if (entry.isIntersecting) entry.target.style.background = '#0000ff' })
              .observe(document.getElementById('late'))
            </script></body>
            """.utf8)
        let server = try await TinyHTTPServer { request in
            request.hasPrefix("GET /red.png") ? ("200 OK", ["Content-Type: image/png"], png) : ("200 OK", ["Content-Type: text/html"], page)
        }
        let tab = try await newAgentTab()
        _ = await client.callTool("navigate", ["tabId": tab, "url": "127.0.0.1:\(server.port)/"])
        let loadedBefore = try await js("document.images[0].complete && document.images[0].naturalWidth > 0", tab: tab) as? Bool
        XCTAssertEqual(loadedBefore, false, "the image waits for a scroll")

        let reply = await client.callTool("computer", ["tabId": tab, "action": "screenshot", "fullPage": true, "savePath": temporaryPNG()])

        let image = try saved(reply)
        XCTAssertEqual(image.pixelsHigh, 4400, reply.text)
        try assertColor(image, x: 100, y: 4100, is: (1, 0, 0), "the lazy image")
        try assertColor(image, x: 640, y: 4300, is: (0, 0, 1), "what the observer revealed")
    }

    /// Past the whole-document bitmap's budget at 3x, so drawn from PDF pieces: each one lands whole, none paints over another.
    func testATallPageIsCutAndSaysSo() async throws {
        let tab = try await agentTab(showing: #"<!doctype html><body style="margin:0"><div style="height:40000px;background:#00ff00"></div></body>"#)
        _ = await client.callTool("resize_window", ["tabId": tab, "width": 800, "height": 400])
        _ = await client.callTool("emulate", ["tabId": tab, "deviceScaleFactor": 3])
        await pollUntil { (try? await self.js("devicePixelRatio", tab: tab)) as? NSNumber == 3 }

        let reply = await client.callTool("computer", ["tabId": tab, "action": "screenshot", "fullPage": true, "savePath": temporaryPNG()])

        let image = try saved(reply)
        XCTAssertEqual(image.pixelsHigh, Int(AgentScreenshot.maxHeight), reply.text)
        XCTAssertTrue(reply.text.contains("cut at 32000 of its 40000 CSS px"), reply.text)
        for y in [10, 13_990, 14_010, 27_990, 28_010, 31_990] { try assertColor(image, x: 400, y: y, is: (0, 1, 0), "drawn at \(y)") }
    }

    func testSavePathWritesThePNGInNewFolders() async throws {
        let tab = try await agentTab(showing: #"<!doctype html><body style="margin:0;background:#ff0000"></body>"#)
        let path = temporaryPNG()
        XCTAssertFalse(FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent))

        let reply = await client.callTool("computer", ["tabId": tab, "action": "screenshot", "savePath": path])
        let relative = await client.callTool("computer", ["tabId": tab, "action": "screenshot", "savePath": "shot.png"])

        XCTAssertFalse(reply.isError, reply.text)
        XCTAssertTrue(reply.images.isEmpty, "the image stays on disk")
        XCTAssertTrue(reply.text.hasSuffix("Saved to \(path)"), reply.text)
        XCTAssertEqual(try saved(reply).pixelsWide, 1280)
        XCTAssertTrue(relative.isError, relative.text)
    }

    /// The agent's cursor is a native view over the web view: page snapshots never draw it.
    func testTheAgentCursorNeverShows() async throws {
        let tab = try await agentTab(showing: #"<!doctype html><body style="margin:0;background:#ff0000"></body>"#)
        _ = await client.callTool("computer", ["tabId": tab, "action": "hover", "coordinate": [100, 100]])
        let webView = try engine(forTab: tab).wkWebView
        XCTAssertTrue(webView.subviews.contains { $0 is AgentCursorView }, "the cursor is up")

        let reply = await client.callTool("computer", ["tabId": tab, "action": "screenshot"])

        let image = try bitmap(reply)
        for (x, y) in [(102, 102), (106, 110), (120, 125)] { try assertColor(image, x: x, y: y, is: (1, 0, 0), "under the cursor at \(x),\(y)") }
    }

    // MARK: - Helpers

    private static let circle = #"url('data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><circle cx="5" cy="5" r="5"/></svg>')"#

    private func temporaryPNG() -> String {
        let folder = FileManager.default.temporaryDirectory.appending(path: "lilo-shots-\(UUID().uuidString)/nested")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        return folder.appending(path: "shot.png").path
    }

    private func bitmap(_ reply: (text: String, isError: Bool, images: [Data])) throws -> NSBitmapImageRep {
        try XCTUnwrap(reply.images.first.flatMap(NSBitmapImageRep.init(data:)), reply.text)
    }

    private func saved(_ reply: (text: String, isError: Bool, images: [Data])) throws -> NSBitmapImageRep {
        let path = try XCTUnwrap(reply.text.components(separatedBy: "Saved to ").last, reply.text)
        return try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path))), reply.text)
    }

    private func assertColor(
        _ image: NSBitmapImageRep, x: Int, y: Int, is expected: (CGFloat, CGFloat, CGFloat), _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let color = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), file: file, line: line)
        // Loose: a snapshot comes in the display's color space, where pure sRGB primaries shift a little.
        let close = zip([color.redComponent, color.greenComponent, color.blueComponent], [expected.0, expected.1, expected.2])
            .allSatisfy { abs($0 - $1) < 0.35 }
        XCTAssertTrue(close, "\(message): \(color) at \(x),\(y)", file: file, line: line)
    }
}
