import AppKit
import WebKit

extension WKWebViewTab {
    /// Lets the user point at an element of the page over a native overlay, so the page sees neither the pointer nor the
    /// clicks. A click hides the element at once and gives its selector; Escape, a navigation or the view leaving its window
    /// gives nil.
    func pickElementToHide(completion: @escaping (String?) -> Void) {
        cancelElementPicker()
        let overlay = ElementPickerOverlay(webView: wkWebView, completion: completion)
        // The overlay keeps page hover from following the pointer; this drops the hover already there.
        wkWebView.liloClearPageHover()
        wkWebView.addSubview(overlay)
    }

    func cancelElementPicker() {
        (wkWebView.subviews.first { $0 is ElementPickerOverlay } as? ElementPickerOverlay)?.finish(nil)
    }
}

/// Covers the web view while picking: highlights the element under the pointer, which a script of the bridge world finds.
final class ElementPickerOverlay: NSView {
    /// Body of an async function of `x` and `y` in CSS pixels, and `pick`. Without `pick`, the element's viewport rect;
    /// with it, a selector matching that element alone, after hiding it. Nil over the page's root or body.
    private static let script = """
    var el = document.elementFromPoint(x, y);
    if (!el || el === document.documentElement || el === document.body) return null;
    if (!pick) { var r = el.getBoundingClientRect(); return [r.left, r.top, r.width, r.height]; }
    // Generated names (digit runs, CSS-in-JS hashes) change with the site's next deploy: the selector keeps readable ones.
    var stable = function (name) {
      return name.length <= 40 && /^[A-Za-z_-][\\w-]*$/.test(name) && !/\\d{3}/.test(name) && !/^(css|jsx|sc|svelte|emotion)-/.test(name);
    };
    var parts = [], selector = null;
    for (var node = el; node && node !== document.body && node !== document.documentElement; node = node.parentElement) {
      var part;
      if (node.id && stable(node.id) && document.querySelectorAll('#' + node.id).length === 1) {
        part = '#' + node.id;
      } else {
        part = /^[a-z][a-z0-9-]*$/i.test(node.localName) ? node.localName : '*';
        var classes = Array.prototype.filter.call(node.classList, stable).slice(0, 3);
        if (classes.length) part += '.' + classes.join('.');
        var position = 1, ambiguous = false, before = true;
        for (var sibling = node.parentElement && node.parentElement.firstElementChild; sibling; sibling = sibling.nextElementSibling) {
          if (sibling === node) { before = false; continue; }
          if (before && sibling.localName === node.localName) position++;
          if (sibling.matches(part)) ambiguous = true;
        }
        if (ambiguous) part += ':nth-of-type(' + position + ')';
      }
      parts.unshift(part);
      if (part[0] === '#' || document.querySelectorAll(parts.join(' > ')).length === 1) { selector = parts.join(' > '); break; }
    }
    selector = selector || 'body > ' + parts.join(' > ');
    // As GenericCosmetics.js does: a user sheet the page cannot see, else an adopted one.
    var css = selector + '{display:none!important}\\n';
    var sheets = self.webkit && self.webkit.messageHandlers && self.webkit.messageHandlers.liloCosmetics;
    if (sheets) {
      sheets.postMessage(css);
    } else {
      var sheet = new CSSStyleSheet();
      sheet.replaceSync('@layer{' + css + '}');
      document.adoptedStyleSheets = document.adoptedStyleSheets.concat(sheet);
    }
    return selector;
    """

    private weak var webView: WKWebView?
    private var completion: ((String?) -> Void)?
    private var keyMonitor: Any?
    private let highlight = CALayer()
    private let hint = NSVisualEffectView()
    /// The pointer's last point; one probe runs at a time, and the latest point goes next.
    private var pointer: NSPoint?
    private var isProbing = false
    private var isPicking = false

    init(webView: WKWebView, completion: @escaping (String?) -> Void) {
        self.webView = webView
        self.completion = completion
        super.init(frame: webView.bounds)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        let accent = NSColor.controlAccentColor
        highlight.backgroundColor = accent.withAlphaComponent(0.15).cgColor
        highlight.borderColor = accent.withAlphaComponent(0.9).cgColor
        highlight.borderWidth = 2
        highlight.cornerRadius = 4
        highlight.isHidden = true
        layer?.addSublayer(highlight)

        let label = NSTextField(labelWithString: "Click an element to hide it on this site. Press Esc to cancel.".localized)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        hint.material = .hudWindow
        hint.state = .active
        hint.wantsLayer = true
        hint.layer?.cornerRadius = 8
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.addSubview(label)
        addSubview(hint)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: hint.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: hint.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: hint.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: hint.bottomAnchor, constant: -6),
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.topAnchor.constraint(equalTo: topAnchor, constant: 12)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Removes the overlay and reports `selector`, once.
    func finish(_ selector: String?) {
        guard let completion else { return }
        self.completion = nil
        removeFromSuperview()
        DispatchQueue.main.async { completion(selector) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        // As RegionSelectionOverlay: a move hit-testing outside the web view never reaches the page's hover and cursor.
        if let type = NSApp.currentEvent?.type, type == .mouseMoved || type == .mouseEntered { return unsafe window?.contentView }
        return self
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Leaving the window it was shown in means the tab is gone from view: the pick ends with it.
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
            finish(nil)
            return
        }
        guard let window = unsafe window else { return }
        // The element under the pointer is highlighted at once: from the context menu, the one that was clicked.
        probe(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        // A monitor, as key focus is usually in the chrome; an IME composition keeps its Escape.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let eventWindow = event.window
            let cancelled = MainActor.assumeIsolated {
                guard let self, unsafe eventWindow === self.window,
                      unsafe (self.window?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return false }
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

    override func mouseMoved(with event: NSEvent) {
        probe(at: convert(event.locationInWindow, from: nil))
    }

    /// The web view scrolls as usual; the element under the pointer may have changed.
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        if let pointer { probe(at: pointer) }
    }

    override func mouseDown(with event: NSEvent) {
        guard !isPicking else { return }
        isPicking = true
        let point = convert(event.locationInWindow, from: nil)
        Task { @MainActor in finish(await run(at: point, pick: true) as? String) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Swallowed, so no page menu or middle click acts under the overlay.
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}

    private func probe(at point: NSPoint) {
        pointer = point
        guard !isProbing else { return }
        isProbing = true
        Task { @MainActor in
            let rect = await run(at: point, pick: false) as? [Double]
            isProbing = false
            guard completion != nil else { return }
            let zoom = webView?.pageZoom ?? 1
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            highlight.isHidden = rect?.count != 4
            if let rect, rect.count == 4 {
                highlight.frame = CGRect(x: rect[0] * zoom, y: rect[1] * zoom, width: rect[2] * zoom, height: rect[3] * zoom)
            }
            CATransaction.commit()
            if let pointer, pointer != point { probe(at: pointer) }
        }
    }

    private func run(at point: NSPoint, pick: Bool) async -> Any? {
        guard let webView else { return nil }
        let zoom = webView.pageZoom
        return try? await webView.callAsyncJavaScript(Self.script, arguments: ["x": Double(point.x / zoom), "y": Double(point.y / zoom), "pick": pick],
                                                      in: nil, contentWorld: PageWorld.bridgeWorld)
    }
}
