import AppKit
import WebKit

/// Encapsulates page-snapshot concerns for a single web view: viewport snapshots,
/// full-page capture, and interactive region selection.
@MainActor
final class PageSnapshotService {
    private let webView: WKWebView
    /// Unique per request ("liloCapture_<uuid>"): the user content controller is shared by every tab of a data store, so a fixed
    /// name would let one tab's `add(_:name:)` steal another's in-flight handler.
    private var regionCaptureHandlerName: String?
    private var pendingRegionCompletion: ((CGRect?) -> Void)?
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

    func startRegionSelection(completion: @escaping (CGRect?) -> Void) {
        // Any selection still pending on THIS tab (an abandoned overlay, or a rapid second call)
        // must be cancelled first so its handler is never orphaned on the shared controller.
        cancelRegionSelection()

        // Hyphen-free so it can be spliced into `messageHandlers.<name>` dot-notation JS below.
        let handlerName = "liloCapture_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        pendingRegionCompletion = completion
        regionCaptureHandlerName = handlerName

        let handler = RegionCaptureScriptHandler { [weak self] rect in
            self?.finishRegionSelection(handlerName: handlerName, rect: rect)
        }
        webView.configuration.userContentController.add(handler, name: handlerName)

        let js = """
        (function() {
          if (document.getElementById('__liloCapture')) return;
          var ov = document.createElement('div');
          ov.id = '__liloCapture';
          ov.style.cssText = 'position:fixed;inset:0;z-index:2147483647;cursor:crosshair;' +
            'background:rgba(0,0,0,0.25);';
          // The shadow dims everything but the selection, so the overlay itself goes clear once it shows.
          var sel = document.createElement('div');
          sel.style.cssText = 'position:absolute;border:2px solid rgba(74,158,255,0.9);' +
            'box-shadow:0 0 0 100vmax rgba(0,0,0,0.25);pointer-events:none;display:none;box-sizing:border-box;';
          ov.appendChild(sel);
          document.documentElement.appendChild(ov);
          var sx = 0, sy = 0, dragging = false;
          function finish(msg) {
            document.removeEventListener('keydown', onKey, true);
            ov.remove();
            window.webkit.messageHandlers.\(handlerName).postMessage(msg);
          }
          function onKey(e) {
            // Cancelled from the native side, which only removes the overlay.
            if (!ov.isConnected) { document.removeEventListener('keydown', onKey, true); return; }
            if (e.key !== 'Escape') return;
            e.preventDefault(); e.stopPropagation();
            finish({cancelled:true});
          }
          function box(e) {
            return {x:Math.min(e.clientX,sx), y:Math.min(e.clientY,sy),
                    width:Math.abs(e.clientX-sx), height:Math.abs(e.clientY-sy)};
          }
          ov.addEventListener('pointerdown', function(e) {
            if (e.button !== 0) return;
            e.preventDefault(); sx = e.clientX; sy = e.clientY; dragging = true;
            // Captured, so a release outside the page still ends the drag. Throws for a pointer that is
            // no longer active, which only costs that guarantee.
            try { ov.setPointerCapture(e.pointerId); } catch (_) {}
            ov.style.background = 'transparent';
            sel.style.display = 'block';
            sel.style.left = sx+'px'; sel.style.top = sy+'px';
            sel.style.width = '0'; sel.style.height = '0';
          });
          ov.addEventListener('pointermove', function(e) {
            if (!dragging) return;
            var b = box(e);
            sel.style.left=b.x+'px'; sel.style.top=b.y+'px';
            sel.style.width=b.width+'px'; sel.style.height=b.height+'px';
          });
          ov.addEventListener('pointerup', function(e) {
            if (!dragging) return;
            dragging = false;
            var b = box(e);
            finish((b.width < 4 || b.height < 4) ? {cancelled:true} : b);
          });
          document.addEventListener('keydown', onKey, true);
        })();
        """
        // Escape only reaches the page if it has focus, and the capture is usually started from the chrome.
        webView.window?.makeFirstResponder(webView)
        webView.evaluateJavaScript(js)
    }

    /// Cancels this tab's region selection: removes the overlay and this request's handler from the shared controller, and calls
    /// the completion with nil. Must run before a new selection, on navigation and on teardown: the controller outlives page loads.
    func cancelRegionSelection() {
        guard let handlerName = regionCaptureHandlerName else { return }
        webView.evaluateJavaScript(
            "(function(){var o=document.getElementById('__liloCapture');if(o)o.remove();})()"
        )
        let completion = pendingRegionCompletion
        removeRegionCaptureHandler(named: handlerName)
        DispatchQueue.main.async { completion?(nil) }
    }

    /// Routes a result from the in-page overlay. Ignores messages tied to a handler name that has
    /// since been superseded (e.g. a stale in-flight message racing a `cancelRegionSelection()`).
    private func finishRegionSelection(handlerName: String, rect: CGRect?) {
        guard handlerName == regionCaptureHandlerName else { return }
        let completion = pendingRegionCompletion
        removeRegionCaptureHandler(named: handlerName)
        DispatchQueue.main.async { completion?(rect) }
    }

    private func removeRegionCaptureHandler(named handlerName: String) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: handlerName)
        regionCaptureHandlerName = nil
        pendingRegionCompletion = nil
    }

    /// `rect` is in CSS pixels, as the overlay measured it; the snapshot wants view points.
    func takeRegionSnapshot(rect: CGRect) async -> NSImage? {
        let zoom = webView.pageZoom
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom)
        return Self.flattened(try? await webView.takeSnapshot(configuration: config), over: backdrop)
    }
}

// MARK: - RegionCaptureScriptHandler

private final class RegionCaptureScriptHandler: NSObject, WKScriptMessageHandler {
    private let completion: (CGRect?) -> Void

    init(completion: @escaping (CGRect?) -> Void) { self.completion = completion }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { completion(nil); return }
        if let cancelled = body["cancelled"] as? Bool, cancelled { completion(nil); return }
        guard let x = (body["x"] as? NSNumber)?.doubleValue,
              let y = (body["y"] as? NSNumber)?.doubleValue,
              let w = (body["width"] as? NSNumber)?.doubleValue,
              let h = (body["height"] as? NSNumber)?.doubleValue else { completion(nil); return }
        completion(CGRect(x: x, y: y, width: w, height: h))
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
