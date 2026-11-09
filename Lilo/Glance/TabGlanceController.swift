import AppKit
import WebKit

/// Shows a saved tab's live page in the chrome's hover card: the tab's own web view, moved above the chrome over the
/// card's page slot. It keeps the tab's session and takes clicks, scrolls and typing as the tab would. Unlike the call
/// dock, the view is not scaled (a scaled view hit-tests at pre-scale coordinates): the page is zoomed out instead.
@MainActor
final class TabGlanceController {
    static let zoneId = "tab-glance-page"
    /// Narrow cards still get close to a site's desktop layout.
    static let zoomFactor: CGFloat = 0.85

    private let container = GlanceContainerView()
    private var engine: WKWebViewTab?
    private var restoredZoom: CGFloat = 1
    private var slotRect: NSRect?
    private weak var chromeView: NSView?

    var engineId: UUID? { engine?.id }
    /// The pointer entered or left the page in the card, whose events the chrome below never sees.
    var onPointerInside: ((Bool) -> Void)?

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
            engine.wkWebView.pageZoom = restoredZoom * Self.zoomFactor
            engine.view.autoresizingMask = [.width, .height]
            engine.view.isHidden = false
            container.addSubview(engine.view)
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
        let hadFocus = unsafe (container.window?.firstResponder as? NSView)?.isDescendant(of: container) == true
        engine.view.removeFromSuperview()
        engine.wkWebView.pageZoom = restoredZoom
        container.isHidden = true
        return hadFocus
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
