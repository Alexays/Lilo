import AppKit
import WebKit

/// The computer tool's screenshot: the viewport, the whole page or one element, at one pixel per point or at the
/// page's own scale. What lies outside the viewport comes from one WebKit paint of the whole document at its current
/// layout: no scrolled tiles to stitch, fixed and sticky elements once and in place, and a viewport that never
/// changes size, so 100vh stays what it was. That paint is a bitmap of the whole document, or past its budget a PDF
/// of the captured rect, which draws CSS masks as solid shapes.
@MainActor
enum AgentScreenshot {
    /// Tallest capture, in CSS pixels: past it a page is cut, and the reply says so.
    static let maxHeight: CGFloat = 32_000
    /// The bitmap's ceiling, 256 MB at 4 bytes a pixel: past it the scale drops.
    static let maxPixels: CGFloat = 64_000_000
    /// Claude's API refuses an image longer than 8000 pixels on a side: one returned inline stays under it.
    static let maxInlineSide: CGFloat = 8000
    /// The whole-document bitmap's ceiling, 512 MB: WebKit paints all of it, whatever part is kept.
    static let maxContentsPixels: CGFloat = 128_000_000
    /// WebKit makes no PDF page taller than 14400 points.
    static let pdfChunk: CGFloat = 14_000

    static func take(_ arguments: [String: Any], engine: WKWebViewTab, tabId: UUID, control: AgentControl) async throws -> [AgentContent] {
        let webView = engine.wkWebView
        let fullPage = arguments["fullPage"] as? Bool == true
        let fullResolution = arguments["fullResolution"] as? Bool == true
        let ref = (arguments["ref"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let selector = (arguments["selector"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let savePath = (arguments["savePath"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let margin = CGFloat(min(max((arguments["margin"] as? NSNumber)?.doubleValue ?? 0, 0), 1000))
        if let savePath, !savePath.hasPrefix("/") || (savePath as NSString).pathExtension.lowercased() != "png" {
            throw AgentToolError("savePath is an absolute path ending in .png")
        }
        if fullPage, ref != nil || selector != nil { throw AgentToolError("fullPage captures the whole page: leave out ref and selector") }
        if let ref, try await AgentTools.frame(holding: ref, in: engine) != nil {
            throw AgentToolError("\(ref) is inside a frame: capture the frame's element instead")
        }
        let deviceScale = control.inspectors[tabId].map(\.deviceScaleFactor).flatMap { $0 > 0 ? $0 : nil }
            ?? webView.window?.backingScaleFactor ?? 2
        let zoom = CGFloat(engine.pageZoom)
        let viewSize: CGSize
        let image: CGImage
        var requested: CGFloat = fullResolution ? deviceScale : 1
        var scale: CGFloat
        var note = ""

        if !fullPage, ref == nil, selector == nil {
            viewSize = webView.bounds.size
            guard let shot = await engine.takeSnapshot()?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw AgentToolError("The tab could not be captured")
            }
            // The snapshot comes at the page's device pixel ratio; at 1x its pixels are the coordinates clicks take.
            if fullResolution { requested = CGFloat(shot.width) / max(viewSize.width, 1) }
            scale = fitted(requested, viewSize, inline: savePath == nil)
            let pixels = (width: Int((viewSize.width * scale).rounded()), height: Int((viewSize.height * scale).rounded()))
            guard let scaled = await Task.detached(operation: { AgentInteractionTools.scaled(shot, width: pixels.width, height: pixels.height) }).value else {
                throw AgentToolError("The tab could not be captured")
            }
            image = scaled
            if scale != 1 { note = " at \(format(scale))x: clicks take the pixels of a plain screenshot, these divided by \(format(scale))" }
        } else {
            let call: [String: Any] = ["ref": ref ?? NSNull(), "selector": selector ?? NSNull(), "fullPage": fullPage, "maxHeight": maxHeight]
            if fullPage {
                // A page pinned to the viewport scrolls an inner container: it grows to its content for the capture.
                for frame in engine.subframes as [WKFrameInfo?] + [nil] {
                    _ = try? await webView.evaluateJavaScript(PageSnapshotExpansion.installJS, in: frame, contentWorld: PageSnapshotExpansion.world)
                }
                _ = try? await webView.callAsyncJavaScript(PageSnapshotExpansion.expandJS, arguments: [:], in: nil, contentWorld: PageSnapshotExpansion.world)
            }
            var restore: Any?
            do {
                restore = try await AgentTools.page(engine, "captureScroll", call)
                // What scrolling through set loading: lazy images and the fetches behind infinite lists, 3 s at most.
                if restore is [String: Any], let capture = control.captures[tabId] {
                    let deadline = ContinuousClock.now + .seconds(3)
                    while !capture.indexByLoad.isEmpty || ContinuousClock.now - capture.lastNetworkActivity < .milliseconds(300),
                          ContinuousClock.now < deadline, !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
                // Scrolling through can bring in text the guard checked before the capture began.
                try await AgentDevTools.refuseTextLeaks(tabId: tabId, control: control)
                guard let box = try await AgentTools.page(engine, "captureBox", call) as? [String: Any] else {
                    throw AgentToolError("The page could not be measured")
                }
                let value = { (key: String) in CGFloat((box[key] as? NSNumber)?.doubleValue ?? 0) }
                let page = CGRect(x: 0, y: 0, width: value("pageWidth"), height: value("pageHeight"))
                var rect = CGRect(x: value("x"), y: value("y"), width: value("width"), height: value("height"))
                    .insetBy(dx: -margin, dy: -margin).intersection(page)
                if rect.height > maxHeight {
                    note = ", cut at \(Int(maxHeight)) of its \(Int(rect.height)) CSS px"
                    rect.size.height = maxHeight
                }
                guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { throw AgentToolError("Nothing to capture: the element is outside the page") }
                viewSize = CGSize(width: rect.width * zoom, height: rect.height * zoom)
                scale = fitted(requested, viewSize, inline: savePath == nil)
                let viewport = CGRect(x: value("scrollX"), y: value("scrollY"), width: value("innerWidth"), height: value("innerHeight"))
                if viewport.contains(rect) {
                    // On screen: the very pixels the user sees, backdrop filters and video included.
                    let region = rect.offsetBy(dx: -viewport.minX, dy: -viewport.minY)
                    guard let shot = await engine.takeRegionSnapshot(rect: region)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                        throw AgentToolError("The tab could not be captured")
                    }
                    let pixels = (width: Int((viewSize.width * scale).rounded()), height: Int((viewSize.height * scale).rounded()))
                    guard let scaled = await Task.detached(operation: { AgentInteractionTools.scaled(shot, width: pixels.width, height: pixels.height) }).value else {
                        throw AgentToolError("The tab could not be captured")
                    }
                    image = scaled
                    if !fullPage {
                        note += ", its top left at (\(Int(region.minX * zoom)), \(Int(region.minY * zoom))) in click coordinates"
                    }
                } else if let contents = await contentsSnapshot(webView, size: page.size, scale: deviceScale, zoom: zoom) {
                    let crop = CGRect(x: rect.minX * zoom * deviceScale, y: rect.minY * zoom * deviceScale,
                                      width: viewSize.width * deviceScale, height: viewSize.height * deviceScale).integral
                    let pixels = (width: Int((viewSize.width * scale).rounded()), height: Int((viewSize.height * scale).rounded()))
                    guard let cropped = contents.cropping(to: crop),
                          let scaled = await Task.detached(operation: { AgentInteractionTools.scaled(cropped, width: pixels.width, height: pixels.height) }).value else {
                        throw AgentToolError("The page could not be drawn")
                    }
                    image = scaled
                    if !fullPage { note += ", out of the viewport" }
                } else {
                    var chunks: [Data] = []
                    for top in stride(from: rect.minY, to: rect.maxY, by: pdfChunk) {
                        let configuration = WKPDFConfiguration()
                        configuration.rect = CGRect(x: rect.minX * zoom, y: top * zoom, width: rect.width * zoom, height: min(pdfChunk, rect.maxY - top) * zoom)
                        chunks.append(try await webView.pdf(configuration: configuration))
                    }
                    let backdrop = backdrop(of: webView)
                    guard let drawn = await Task.detached(operation: { draw(chunks, size: viewSize, scale: scale, backdrop: backdrop) }).value else {
                        throw AgentToolError("The page could not be drawn")
                    }
                    image = drawn
                    if !fullPage { note += ", out of the viewport" }
                }
                note = (fullPage ? " of the whole page" : " of \(ref ?? selector ?? "")")
                    + ", \(Int(rect.width))x\(Int(rect.height)) CSS px at \(format(scale * zoom))x" + note
                    + ". Clicks still take the pixels of a plain screenshot"
            } catch {
                await finish(engine, restore: restore, expanded: fullPage)
                throw error
            }
            await finish(engine, restore: restore, expanded: fullPage)
        }
        if scale < requested {
            note += scale < fitted(requested, viewSize, inline: false)
                ? " (scaled down: an inline image stops at \(Int(maxInlineSide)) px, savePath keeps more)"
                : " (scaled down: a capture stops at \(Int(maxPixels / 1_000_000)) megapixels)"
        }

        let path = savePath
        let encoded = try await Task.detached { () throws -> (png: Data, base64: String?) in
            guard let png = AgentInteractionTools.png(image) else { throw AgentToolError("The capture could not be encoded") }
            if let path {
                let url = URL(fileURLWithPath: path)
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try png.write(to: url, options: .atomic)
                } catch {
                    throw AgentToolError("Could not write \(path): \(error.localizedDescription)")
                }
                return (png, nil)
            }
            return (png, png.base64EncodedString())
        }.value
        let id = "screenshot_\(control.nextScreenshotNumber)"
        control.nextScreenshotNumber += 1
        control.screenshots.append((id, encoded.png))
        if control.screenshots.count > 20 { control.screenshots.removeFirst() }
        let summary = "Screenshot \(id), \(image.width)x\(image.height)" + note + AgentInteractionTools.zoomNote(engine)
        guard let base64 = encoded.base64 else { return [.text(summary + "\nSaved to \(path ?? "")")] }
        return [.image(base64), .text(summary)]
    }

    /// The whole document in one bitmap at the page's own scale, or nil past the budget or when WebKit lacks the option.
    private static func contentsSnapshot(_ webView: WKWebView, size: CGSize, scale: CGFloat, zoom: CGFloat) async -> CGImage? {
        let option = NSSelectorFromString("_setUsesContentsRect:")
        let configuration = WKSnapshotConfiguration()
        guard size.width * size.height * zoom * zoom * scale * scale <= maxContentsPixels, configuration.responds(to: option) else { return nil }
        // A BOOL argument: perform(_:with:) would pass an object pointer instead.
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(configuration.method(for: option), to: Setter.self)(configuration, option, true)
        return try? await webView.takeSnapshot(configuration: configuration).cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// The scale under the pixel budget, and under the inline limit for an image returned inline.
    private static func fitted(_ scale: CGFloat, _ size: CGSize, inline: Bool) -> CGFloat {
        var fitted = min(scale, (maxPixels / max(size.width * size.height, 1)).squareRoot())
        if inline { fitted = min(fitted, maxInlineSide / max(size.width, size.height, 1)) }
        return fitted
    }

    private static func format(_ scale: CGFloat) -> String { String(format: "%g", (scale * 100).rounded() / 100) }

    /// Puts the page back as it was: its scroll position, then whatever the expansion changed.
    private static func finish(_ engine: WKWebViewTab, restore: Any?, expanded: Bool) async {
        if let restore = restore as? [String: Any] { _ = try? await AgentTools.page(engine, "captureRestore", restore) }
        if expanded { _ = try? await engine.wkWebView.evaluateJavaScript(PageSnapshotExpansion.restoreJS, in: nil, contentWorld: PageSnapshotExpansion.world) }
    }

    /// What shows under a page with no background of its own, so no transparency turns black in the PNG.
    private static func backdrop(of webView: WKWebView) -> CGColor {
        var color = CGColor(gray: 1, alpha: 1)
        webView.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let srgb = (webView.underPageBackgroundColor ?? .white).usingColorSpace(.sRGB) { color = srgb.cgColor }
        }
        return color
    }

    /// The PDF pieces of a capture, top to bottom, in one opaque sRGB bitmap at `scale` pixels per point.
    nonisolated private static func draw(_ chunks: [Data], size: CGSize, scale: CGFloat, backdrop: CGColor) -> CGImage? {
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        canvas.setFillColor(backdrop)
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        canvas.scaleBy(x: scale, y: scale)
        var top: CGFloat = 0
        for chunk in chunks {
            guard let provider = CGDataProvider(data: chunk as CFData), let page = CGPDFDocument(provider)?.page(at: 1) else { return nil }
            let box = page.getBoxRect(.mediaBox)
            // CGContext draws from the bottom left: a piece's offset from the top is flipped. A page draws past its
            // media box (the document's background does), over the pieces above it, unless clipped.
            canvas.saveGState()
            canvas.clip(to: CGRect(x: 0, y: size.height - top - box.height, width: box.width, height: box.height))
            canvas.translateBy(x: -box.minX, y: size.height - top - box.height - box.minY)
            canvas.drawPDFPage(page)
            canvas.restoreGState()
            top += box.height
        }
        return canvas.makeImage()
    }
}
