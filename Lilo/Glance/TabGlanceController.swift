import AppKit
import WebKit

/// Shows a saved tab's live page in the chrome's hover card: the tab's own web view, moved above the chrome over the
/// card's page slot. It keeps the tab's session and takes clicks, scrolls and typing as the tab would. Unlike the call
/// dock, the view is not scaled (a scaled view hit-tests at pre-scale coordinates): the page is zoomed out instead.
@MainActor
final class TabGlanceController {
    static let zoneId = "tab-glance-page"
    /// Narrow cards still get close to a site's desktop layout.
    static let zoomFactor = 0.85

    private let container = GlanceContainerView()
    private var engine: WKWebViewTab?
    private var restoredZoom: CGFloat = 1
    private var slotRect: NSRect?
    private weak var chromeView: NSView?
    private var inputMonitor: Any?
    private var wasUsed = false

    var engineId: UUID? { engine?.id }
    /// The keyboard is in the page in the card.
    var hasFocus: Bool { unsafe (container.window?.firstResponder as? NSView)?.isDescendant(of: container) == true }
    /// The pointer entered or left the page in the card, whose events the chrome below never sees.
    var onPointerInside: ((Bool) -> Void)?
    /// The first click or key press in the page: more than a look.
    var onUsed: (() -> Void)?
    /// Escape in the page closes the card, as it closes a Peek.
    var onDismiss: (() -> Void)?

    init() {
        container.wantsLayer = true
        // Matches the slot's `--radius-sm` in the chrome.
        container.layer?.cornerRadius = 6
        container.layer?.masksToBounds = true
        container.isHidden = true
        container.onPointerInside = { [weak self] in self?.onPointerInside?($0) }
    }

    func show(_ engine: WKWebViewTab, in contentView: NSView, above chromeView: NSView) {
        if self.engine !== engine {
            end()
            self.engine = engine
            restoredZoom = engine.wkWebView.pageZoom
            engine.zoomScale = Self.zoomFactor
            engine.wkWebView.pageZoom = restoredZoom * CGFloat(Self.zoomFactor)
            engine.view.autoresizingMask = [.width, .height]
            engine.view.isHidden = false
            container.addSubview(engine.view)
            wasUsed = false
            // A monitor, as the page takes its events itself: all but the Escape that closes the card go on to it.
            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.handleInput(event) == true } ? nil : event
            }
        }
        self.chromeView = chromeView
        if unsafe container.superview !== contentView {
            contentView.addSubview(container, positioned: .above, relativeTo: chromeView)
        }
        applySlot()
    }

    /// Takes the view out of the card: the tab shows it again once selected. Returns whether the page had the focus.
    @discardableResult
    func end() -> Bool {
        guard let engine else { return false }
        self.engine = nil
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        let hadFocus = hasFocus
        engine.zoomScale = 1
        container.isHidden = true
        // A view another window took meanwhile is that window's now, its zoom included.
        guard unsafe engine.view.superview === container else { return hadFocus }
        engine.view.removeFromSuperview()
        // The exact zoom it had, unless a navigation in the card gave the page another site's.
        let zoom = engine.wkWebView.pageZoom
        engine.wkWebView.pageZoom = zoom == restoredZoom * CGFloat(Self.zoomFactor) ? restoredZoom : zoom / CGFloat(Self.zoomFactor)
        return hadFocus
    }

    /// Whether the event stops here: only the Escape that closes the card does, unless it ends a text composition.
    private func handleInput(_ event: NSEvent) -> Bool {
        guard let window = unsafe container.window, event.window === window else { return false }
        if event.type == .keyDown, event.keyCode == 53, hasFocus, (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true {
            onDismiss?()
            return true
        }
        let inPage = event.type == .keyDown ? hasFocus : container.bounds.contains(container.convert(event.locationInWindow, from: nil))
        if inPage, !wasUsed {
            wasUsed = true
            onUsed?()
        }
        return false
    }

    /// Fed from the interactive-zone stream (chrome viewport coordinates, top-left origin), which follows a resize.
    func zonesChanged(_ zones: [String: NSRect]) {
        guard slotRect != zones[Self.zoneId] else { return }
        slotRect = zones[Self.zoneId]
        applySlot()
    }

    private func applySlot() {
        guard engine != nil, let slotRect, let chromeView, slotRect.width > 10, slotRect.height > 10 else {
            container.isHidden = true
            return
        }
        container.frame = NSRect(
            x: slotRect.minX,
            y: chromeView.bounds.height - slotRect.maxY,
            width: slotRect.width,
            height: slotRect.height
        )
        engine?.view.frame = container.bounds
        container.isHidden = false
    }
}

private final class GlanceContainerView: NSView {
    var onPointerInside: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onPointerInside?(true) }
    override func mouseExited(with event: NSEvent) { onPointerInside?(false) }
}
