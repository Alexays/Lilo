import AppKit
import WebKit

/// Encapsulates page-snapshot concerns for a single web view: viewport snapshots,
/// full-page capture, and interactive region selection.
@MainActor
final class PageSnapshotService {
    private let webView: WKWebView
    private weak var regionOverlay: RegionSelectionOverlay?
    private var isCapturingFullPage = false

    init(webView: WKWebView) {
        self.webView = webView
    }

    /// The viewport, rendered straight to `width` points when given. The hover preview only ever
    /// shows a ~240pt card, and a full-size capture of a full-screen window is a ~17 MB bitmap per
    /// refresh that then has to be scaled down anyway.
    func takeSnapshot(width: CGFloat? = nil) async -> NSImage? {
        let configuration = WKSnapshotConfiguration()
        if let width { configuration.snapshotWidth = NSNumber(value: Double(width)) }
        return Self.flattened(try? await webView.takeSnapshot(configuration: configuration), over: backdrop)
    }

    /// Full-page capture, scrolled a viewport at a time and stitched so lazy content is included. `PageSnapshotExpansion` first makes
    /// a pinned page's document scrollable; `truncated` means the page ran past `maxFullPageHeight` and only its top was captured.
    func takeFullPageSnapshot(subframes: [WKFrameInfo] = []) async -> (image: NSImage, truncated: Bool)? {
        // A view that never navigated has no web process to answer, and WebKit never completes the
        // script calls below. A second capture would fight the first one over the scroll position.
        guard webView.url != nil, !isCapturingFullPage else { return nil }
        isCapturingFullPage = true
        defer { isCapturingFullPage = false }

        // Injected only now, so browsing a page leaves no capture machinery behind. A subframe that
        // has gone away since it was recorded just throws WKErrorJavaScriptInvalidFrameTarget.
        for frame in subframes as [WKFrameInfo?] + [nil] {
            _ = try? await webView.evaluateJavaScript(PageSnapshotExpansion.installJS, in: frame, contentWorld: PageSnapshotExpansion.world)
        }
        _ = try? await webView.callAsyncJavaScript(
            PageSnapshotExpansion.expandJS, arguments: [:], in: nil, contentWorld: PageSnapshotExpansion.world
        )
        let image = await scrollAndStitch()
        // Scroll capture first: it restores the scroll position against the still-expanded layout.
        _ = try? await webView.evaluateJavaScript(
            PageScrollCapture.endJS, in: nil, contentWorld: PageScrollCapture.world
        )
        _ = try? await webView.evaluateJavaScript(PageSnapshotExpansion.restoreJS, in: nil, contentWorld: PageSnapshotExpansion.world)
        return image
    }

    /// Scrolls the document top to bottom and draws each viewport snapshot at its scroll offset.
    private func scrollAndStitch() async -> (image: NSImage, truncated: Bool)? {
        let world = PageScrollCapture.world
        guard let layout = try? await webView.callAsyncJavaScript(
                  PageScrollCapture.beginJS, arguments: [:], in: nil, contentWorld: world
              ) as? [String: Any],
              let documentHeight = (layout["height"] as? NSNumber).map({ CGFloat($0.doubleValue) }),
              let viewportHeight = (layout["viewport"] as? NSNumber).map({ CGFloat($0.doubleValue) }),
              viewportHeight > 0
        else { return nil }

        // Scroll offsets come back in CSS pixels; snapshots are in view points. They differ under page zoom.
        let viewSize = webView.bounds.size
        let zoom = viewSize.height / viewportHeight
        let width = viewSize.width
        let height = min(documentHeight * zoom, Self.maxFullPageHeight)
        guard width > 0, height > 0 else { return nil }

        // Display scale, unless that overruns the pixel budget, which leaves a page within the height
        // limit at 1x or better at common window widths.
        var scale = webView.window?.backingScaleFactor ?? 2
        if width * height * scale * scale > Self.maxSnapshotPixels {
            scale = (Self.maxSnapshotPixels / (width * height)).squareRoot()
        }
        guard let canvas = Self.opaqueCanvas(
            width: Int((width * scale).rounded()),
            height: Int((height * scale).rounded()),
            backdrop: backdrop
        ) else { return nil }
        canvas.scaleBy(x: scale, y: scale)
        canvas.interpolationQuality = .high

        // The frame script has already waited for paint, and a presentation update never comes for a
        // view that is off screen.
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        var covered: CGFloat = 0
        var target: CGFloat = 0
        var isFirst = true
        while covered < height {
            guard let offset = (try? await webView.callAsyncJavaScript(
                      PageScrollCapture.frameJS,
                      arguments: ["y": Double(target), "hidePinned": !isFirst],
                      in: nil,
                      contentWorld: world
                  ) as? NSNumber).map({ CGFloat($0.doubleValue) }),
                  let frame = try? await webView.takeSnapshot(configuration: configuration),
                  let pixels = frame.snapshotPixels
            else { return nil }

            let top = offset * zoom
            // The page stopped scrolling short of its measured height (it shrank, or a script pins it).
            if !isFirst && top + viewSize.height <= covered { break }
            // CGContext draws from the bottom-left, so an offset from the top is flipped.
            canvas.draw(pixels, in: CGRect(x: 0, y: height - top - viewSize.height, width: width, height: viewSize.height))
            covered = top + viewSize.height
            target = offset + viewportHeight
            isFirst = false
        }

        let capturedHeight = min(covered, height)
        guard let full = canvas.makeImage(),
              let image = full.cropping(to: CGRect(
                  x: 0, y: 0, width: full.width, height: Int((capturedHeight * scale).rounded())
              ))
        else { return nil }
        return (
            NSImage(cgImage: image, size: NSSize(width: width, height: capturedHeight)),
            documentHeight * zoom > Self.maxFullPageHeight
        )
    }

    /// Longest page a capture scrolls through, in points: past this it takes too long and the pixel
    /// budget leaves too little resolution for the result to be readable.
    private static let maxFullPageHeight: CGFloat = 150_000

    /// Ceiling on the rendered bitmap, in device pixels. 200 MP is 800 MB at 4 bytes per pixel.
    private static let maxSnapshotPixels: CGFloat = 200_000_000

    /// Composited under every snapshot: a capture racing a navigation can return transparent pixels, which turn black in a PNG,
    /// while on screen those gaps show `underPageBackgroundColor`.
    private var backdrop: CGColor {
        var color = CGColor(gray: 1, alpha: 1)
        let underPage = webView.underPageBackgroundColor ?? .white
        webView.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let srgb = underPage.usingColorSpace(.sRGB) { color = srgb.cgColor }
        }
        return color
    }

    /// Composites `image` onto an opaque `backdrop`, so no transparency survives into the PNG.
    static func flattened(_ image: NSImage?, over backdrop: CGColor) -> NSImage? {
        guard let image,
              let pixels = image.snapshotPixels,
              let canvas = opaqueCanvas(width: pixels.width, height: pixels.height, backdrop: backdrop)
        else { return image }

        canvas.draw(pixels, in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        guard let flat = canvas.makeImage() else { return image }
        return NSImage(cgImage: flat, size: image.size)
    }

    /// An alpha-less bitmap context, pre-filled with `backdrop`. Alpha-less so no transparency can
    /// leak into the result at all; pre-filled because such a context starts out zeroed, i.e. black.
    private static func opaqueCanvas(width: Int, height: Int, backdrop: CGColor) -> CGContext? {
        guard width > 0, height > 0,
              let canvas = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }

        canvas.setFillColor(backdrop)
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return canvas
    }

    /// Lets the user drag out a region of the viewport over a native overlay, so the page never sees it. `completion` gets
    /// the region in CSS pixels, or nil once cancelled (Escape, a click without a drag, or the view leaving its window).
    func startRegionSelection(completion: @escaping (CGRect?) -> Void) {
        regionOverlay?.finish(nil)
        let overlay = RegionSelectionOverlay(frame: webView.bounds) { [weak webView] rect in
            completion(rect.map { rect in
                let zoom = webView?.pageZoom ?? 1
                return CGRect(x: rect.minX / zoom, y: rect.minY / zoom, width: rect.width / zoom, height: rect.height / zoom)
            })
        }
        regionOverlay = overlay
        // The overlay keeps page hover from following the pointer; this drops the hover already there.
        webView.liloClearPageHover()
        webView.addSubview(overlay)
    }

    /// Cancels this tab's region selection, calling its completion with nil. Runs on navigation and teardown.
    func cancelRegionSelection() {
        regionOverlay?.finish(nil)
    }

    /// `rect` is in CSS pixels; the snapshot wants view points.
    func takeRegionSnapshot(rect: CGRect) async -> NSImage? {
        let zoom = webView.pageZoom
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom)
        return Self.flattened(try? await webView.takeSnapshot(configuration: config), over: backdrop)
    }
}

// MARK: - RegionSelectionOverlay

/// Covers the web view during a region selection: dims it, draws the dragged rectangle and reports it in view points.
private final class RegionSelectionOverlay: NSView {
    private var completion: ((CGRect?) -> Void)?
    private var keyMonitor: Any?
    private var origin: NSPoint?
    private var selection = CGRect.zero
    /// Dims everything around its hole, as a border at least as wide as the view, like CSS's `box-shadow: 0 0 0 100vmax`.
    private let dim = CALayer()
    private let outline = CALayer()

    init(frame: NSRect, completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.masksToBounds = true
        dim.borderColor = CGColor(gray: 0, alpha: 0.25)
        outline.borderWidth = 2
        outline.borderColor = CGColor(srgbRed: 74 / 255, green: 158 / 255, blue: 1, alpha: 0.9)
        outline.isHidden = true
        layer?.addSublayer(dim)
        layer?.addSublayer(outline)
        updateLayers()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Removes the overlay and reports `rect`, once.
    func finish(_ rect: CGRect?) {
        guard let completion else { return }
        self.completion = nil
        removeFromSuperview()
        DispatchQueue.main.async { completion(rect) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // WebKit only passes a move on to the page when this hit test lands inside the web view: landing outside keeps
        // hover and cursor changes off the page under the overlay, as when the overlay was a page element.
        if let type = NSApp.currentEvent?.type, type == .mouseMoved || type == .mouseEntered { return window?.contentView }
        return hit
    }

    // A cursor rect, as WebKit never sets the page's cursor over one.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func layout() {
        super.layout()
        updateLayers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Leaving the window it was shown in means the tab is gone from view: the selection ends with it.
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
            finish(nil)
            return
        }
        guard window != nil else { return }
        // A monitor, as key focus is usually in the chrome; an IME composition keeps its Escape.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let eventWindow = event.window
            let cancelled = MainActor.assumeIsolated {
                guard let self, eventWindow === self.window,
                      (self.window?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return false }
                self.finish(nil)
                return true
            }
            return cancelled ? nil : event
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        finish(nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        origin = point
        selection = CGRect(origin: point, size: .zero)
        outline.isHidden = false
        updateLayers()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y), width: abs(point.x - origin.x), height: abs(point.y - origin.y))
            .intersection(bounds)
        updateLayers()
    }

    override func mouseUp(with event: NSEvent) {
        guard origin != nil else { return }
        mouseDragged(with: event)
        finish(selection.width < 4 || selection.height < 4 ? nil : selection.integral)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Swallowed, so no page menu or middle click acts under the overlay.
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}

    private func updateLayers() {
        let reach = max(bounds.width, bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dim.frame = selection.insetBy(dx: -reach, dy: -reach)
        dim.borderWidth = reach
        outline.frame = selection
        CATransaction.commit()
    }
}

// MARK: - PageScrollCapture

/// Scripts driving a scrolled full-page capture. They run in their own content world: they share the
/// DOM with the page but none of its globals, so the page can neither call nor tamper with them.
@MainActor
private enum PageScrollCapture {
    static let world = WKContentWorld.world(name: "LiloPageCapture")

    /// Body of an async function. Pins scrolling to instant, blocks the user's wheel so it cannot
    /// shift a frame mid-capture, turns sticky elements back into in-flow ones so they do not repeat
    /// down the image, and reports the document height and viewport height in CSS pixels.
    static let beginJS = """
    var root = document.documentElement;
    var capture = window.__liloScrollCapture = { x: window.scrollX, y: window.scrollY, styles: new Map() };
    function force(el, prop, value) {
      // setProperty re-serialises the style attribute, so the original text is put back verbatim.
      if (!capture.styles.has(el)) capture.styles.set(el, el.getAttribute('style'));
      el.style.setProperty(prop, value, 'important');
    }
    capture.block = function (event) { event.preventDefault(); };
    window.addEventListener('wheel', capture.block, { capture: true, passive: false });
    force(root, 'scroll-behavior', 'auto');
    force(root, 'scrollbar-width', 'none');
    // Fixed elements show once, in the first frame. One covering most of the viewport is a
    // backdrop rather than a header or a banner, and belongs in every frame.
    capture.pin = function (hideFixed) {
      var all = document.querySelectorAll('body *'), backdrop = window.innerWidth * window.innerHeight / 2;
      for (var i = 0; i < all.length; i++) {
        var el = all[i], position = getComputedStyle(el).position;
        if (position === 'sticky') {
          force(el, 'position', 'relative');
          force(el, 'top', 'auto'); force(el, 'bottom', 'auto');
          force(el, 'left', 'auto'); force(el, 'right', 'auto');
        } else if (hideFixed && position === 'fixed') {
          var rect = el.getBoundingClientRect();
          if (rect.width * rect.height < backdrop) force(el, 'opacity', '0');
        }
      }
    };
    capture.pin(false);
    var scroller = document.scrollingElement || root;
    return { height: scroller.scrollHeight, viewport: window.innerHeight };
    """

    /// Body of an async function taking `y` and `hidePinned`: scrolls there, gives the page a frame
    /// to paint and the images now on screen a moment to load, and returns the offset reached.
    static let frameJS = """
    var capture = window.__liloScrollCapture;
    window.scrollTo(capture.x, y);
    \(PageSnapshotExpansion.waitForPaintJS)
    var pending = [];
    for (var i = 0; i < document.images.length; i++) {
      var img = document.images[i];
      if (img.complete) continue;
      var rect = img.getBoundingClientRect();
      if (rect.bottom <= 0 || rect.top >= window.innerHeight) continue;
      pending.push(new Promise(function (resolve) {
        img.addEventListener('load', resolve, { once: true });
        img.addEventListener('error', resolve, { once: true });
      }));
    }
    if (pending.length) {
      await Promise.race([Promise.all(pending), new Promise(function (resolve) { setTimeout(resolve, 500); })]);
    }
    // After the scroll, so an element that only turns fixed once scrolled is caught too.
    if (hidePinned) capture.pin(true);
    return window.scrollY;
    """

    /// Puts back the scroll position and every style the capture touched. Safe to run when idle.
    static let endJS = """
    (function () {
      var capture = window.__liloScrollCapture;
      if (!capture) return;
      delete window.__liloScrollCapture;
      window.removeEventListener('wheel', capture.block, true);
      // Before the styles come back, while scroll-behavior is still forced to instant.
      window.scrollTo(capture.x, capture.y);
      capture.styles.forEach(function (style, el) {
        if (style === null) el.removeAttribute('style');
        else el.setAttribute('style', style);
      });
    })();
    """
}

extension NSImage {
    /// The bitmap a WebKit snapshot holds: `cgImage(forProposedRect:)` redraws it for the screen,
    /// a half-float copy in the display profile on an EDR screen that costs ~16 ms at 1080p.
    var snapshotPixels: CGImage? {
        representations.first?.cgImage(forProposedRect: nil, context: nil, hints: nil) ?? cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
