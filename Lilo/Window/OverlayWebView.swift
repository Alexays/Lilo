import AppKit
import WebKit

/// Private WebKit SPI reaching `_impl` past `WKMouseTrackingObserver`'s topmost gate: WKWebView does not override mouseMoved/Entered/
/// Exited, so these selectors are the only native way to drive page hover. _simulateMouseMove: needs 13.0+, _simulateMouseExit: 14.0+.
@objc private protocol WKMouseSimSPI {
    @objc(_simulateMouseMove:) func _simulateMouseMove(_ event: NSEvent)
    @objc(_simulateMouseExit:) func _simulateMouseExit(_ event: NSEvent)
}

extension WKWebView {
    /// Clears stuck :hover by re-hit-testing at `windowPoint` (WebKit maps the exit to a buttonless move). `_simulateMouseExit:` has no
    /// firstResponder/visibleRect guard, unlike the move path, so it fires even when this view is first responder.
    func liloSimulateMouseExit(atWindowPoint windowPoint: NSPoint) {
        guard let window,
              let event = NSEvent.enterExitEvent(
                with: .mouseExited, location: windowPoint, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
        else { return }
        let sel = #selector(WKMouseSimSPI._simulateMouseExit(_:))
        guard responds(to: sel) else { return }
        unsafeBitCast(self, to: WKMouseSimSPI.self)._simulateMouseExit(event)
    }

    /// Drive the page's hover/cursor from a real move event via the genuine `_impl` path.
    func liloSimulateMouseMove(_ event: NSEvent) {
        let sel = #selector(WKMouseSimSPI._simulateMouseMove(_:))
        guard responds(to: sel) else { return }
        unsafeBitCast(self, to: WKMouseSimSPI.self)._simulateMouseMove(event)
    }

    /// Clears all stale :hover by re-hit-testing a point outside the viewport: an edge point rounds back onto an edge-spanning element,
    /// while 200pt past the top-left corner is far enough that WebKit does not clamp it in.
    func liloClearPageHover() {
        let outsideWindowPoint = convert(NSPoint(x: -200, y: -200), to: nil)
        liloSimulateMouseExit(atWindowPoint: outsideWindowPoint)
    }
}

/// Transparent WKWebView overlay for the browser chrome (Svelte UI).
final class OverlayWebView: WKWebView {
    var maximizeWindow: (() -> Void)?
    var performWindowDrag: ((NSEvent) -> Void)?
    var eventRouter: ChromeEventRouter? {
        didSet { eventRouter?.chromeView = self }
    }

    /// The most recent left-mouse-down event received by this view.
    /// Used by startWindowDrag since NSApp.currentEvent may have advanced by the time the async IPC message is processed.
    private(set) var lastMouseDownEvent: NSEvent?
    private var mouseTrackingEnabled = true
    private let trackingAreaSuspender = TrackingAreaSuspender()

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        setupTransparency()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTransparency()
    }

    private func setupTransparency() {
        // KVC resolves this key to the private `_setDrawsBackground:`; without it the KVC write raises.
        if responds(to: NSSelectorFromString("_setDrawsBackground:")) { setValue(false, forKey: "drawsBackground") }
        layer?.isOpaque = false
    }

    /// AppKit hands the revealed full-screen title bar's height to the web view under it, and WebKit paints an
    /// opaque scroll edge pocket that tall over the sidebar. The chrome does not scroll, so it takes none.
    @objc(setFullScreenTitlebarOverlayHeight:)
    func setFullScreenTitlebarOverlayHeight(_ height: CGFloat) {}

    func setMouseTrackingEnabled(_ enabled: Bool) {
        guard enabled != mouseTrackingEnabled else { return }
        mouseTrackingEnabled = enabled

        trackingAreaSuspender.setSuspended(!enabled, in: self)
    }

    override func mouseDown(with event: NSEvent) {
        lastMouseDownEvent = event
        if shouldMaximizeWindow(for: event) {
            if let maximizeWindow {
                maximizeWindow()
            } else {
                window?.zoom(nil)
            }
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let dragStartEvent = windowDragStartEvent(for: event) {
            if let performWindowDrag {
                performWindowDrag(dragStartEvent)
            } else {
                window?.performDrag(with: dragStartEvent)
            }
            return
        }
        super.mouseDragged(with: event)
    }

    // The shield's forwarding target: these MUST go through the router, never super, or the chrome web view swallows files dropped on
    // page content. Without a router they decline (fail closed).
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        eventRouter?.draggingEntered(sender) ?? []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        eventRouter?.draggingUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        eventRouter?.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        eventRouter?.prepareForDragOperation(sender) ?? false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        eventRouter?.performDragOperation(sender) ?? false
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        eventRouter?.concludeDragOperation(sender)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinates, and this view is flipped while its superview is not.
        if let eventRouter, eventRouter.target(forWindowPoint: superview?.convert(point, to: nil) ?? point) != .chrome {
            return nil
        }
        return super.hitTest(point)
    }

    func receiveChromeDraggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        super.draggingEntered(sender)
    }

    func receiveChromeDraggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        super.draggingUpdated(sender)
    }

    func receiveChromeDraggingExited(_ sender: (any NSDraggingInfo)?) {
        if let sender {
            super.draggingExited(sender)
        }
    }

    func receiveChromePrepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        super.prepareForDragOperation(sender)
    }

    func receiveChromePerformDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        super.performDragOperation(sender)
    }

    func receiveChromeConcludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        super.concludeDragOperation(sender)
    }

    private func shouldMaximizeWindow(for event: NSEvent) -> Bool {
        guard event.clickCount == 2 else { return false }
        return isContentInsetZone(event)
    }

    private func windowDragStartEvent(for event: NSEvent) -> NSEvent? {
        guard event.type == .leftMouseDragged,
              let lastMouseDownEvent,
              lastMouseDownEvent.clickCount == 1 else { return nil }
        guard isContentInsetZone(lastMouseDownEvent) else { return nil }
        return lastMouseDownEvent
    }

    private func isContentInsetZone(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        return eventRouter?.zoneStore.zoneId(at: point, in: bounds, isFlipped: isFlipped) == "content-inset-zone"
    }
}
