import AppKit
import WebKit

/// Native source of truth for chrome-owned interactive rects.
final class ChromeInteractiveZoneStore {
    private var zones: [String: NSRect] = [:]
    var onZonesChanged: (([String: NSRect]) -> Void)?

    /// One frame's worth of moved zones (a window or sidebar resize moves them all): one fanout.
    func registerZones(_ batch: [(id: String, rect: NSRect)]) {
        assert(Thread.isMainThread)
        var changed = false
        for zone in batch where zones[zone.id] != zone.rect {
            zones[zone.id] = zone.rect
            changed = true
        }
        if changed { onZonesChanged?(zones) }
    }

    func removeZone(id: String) {
        assert(Thread.isMainThread)
        zones.removeValue(forKey: id)
        onZonesChanged?(zones)
    }

    func currentZones() -> [String: NSRect] {
        assert(Thread.isMainThread)
        return zones
    }

    func isInteractive(_ point: NSPoint, in bounds: NSRect, isFlipped: Bool = false) -> Bool {
        assert(Thread.isMainThread)
        let viewportPoint = viewportPoint(from: point, in: bounds, isFlipped: isFlipped)
        // O(zones): ~6 rects, linear contains. Deliberately not spatially indexed
        // (YAGNI at this size). Do not "optimize" blindly.
        return zones.values.contains { $0.contains(viewportPoint) }
    }

    func zoneId(at point: NSPoint, in bounds: NSRect, isFlipped: Bool = false) -> String? {
        assert(Thread.isMainThread)
        let viewportPoint = viewportPoint(from: point, in: bounds, isFlipped: isFlipped)
        return zones.first { $0.value.contains(viewportPoint) }?.key
    }

    @MainActor
    func isInteractive(windowPoint: NSPoint, in chromeView: NSView) -> Bool {
        isInteractive(chromeView.convert(windowPoint, from: nil), in: chromeView.bounds, isFlipped: chromeView.isFlipped)
    }

    func viewportPoint(from point: NSPoint, in bounds: NSRect, isFlipped: Bool) -> NSPoint {
        isFlipped ? point : NSPoint(x: point.x, y: bounds.height - point.y)
    }
}

@MainActor
final class TrackingAreaSuspender {
    enum RestoreBehavior {
        case reattach
        case reattachNonTooltipAreas
    }

    private struct SuspendedTrackingArea {
        weak var view: NSView?
        let area: NSTrackingArea
    }

    private weak var rootView: NSView?
    private var suspendedTrackingAreas: [SuspendedTrackingArea] = []
    private var restoreBehavior: RestoreBehavior = .reattach

    // Removing tracking areas is the only reliable way to stop WKWebView hover/cursor churn behind chrome.
    func setSuspended(_ suspended: Bool, in rootView: NSView?, restoreBehavior: RestoreBehavior = .reattach) {
        guard let rootView else {
            restore()
            return
        }

        if self.rootView !== rootView {
            restore()
        }

        switch (suspended, suspendedTrackingAreas.isEmpty) {
        case (true, true):
            self.rootView = rootView
            self.restoreBehavior = restoreBehavior
            suspend(from: rootView)
        case (false, false):
            restore()
        default:
            break
        }
    }

    private func suspend(from view: NSView) {
        for area in view.trackingAreas {
            view.removeTrackingArea(area)
            suspendedTrackingAreas.append(SuspendedTrackingArea(view: view, area: area))
        }

        for subview in view.subviews {
            suspend(from: subview)
        }
    }

    private func restore() {
        let suspended = suspendedTrackingAreas
        suspendedTrackingAreas.removeAll(keepingCapacity: true)

        var restoredAny = false
        for item in suspended {
            if restoreBehavior == .reattach || (restoreBehavior == .reattachNonTooltipAreas && !item.area.isTooltipTrackingArea) {
                item.view?.addTrackingArea(item.area)
                restoredAny = true
            }
        }

        // Nothing reattached means no tracking state changed, so the recursive update +
        // window-wide cursor invalidation would be pure churn.
        if restoredAny, let rootView {
            updateTrackingAreasRecursively(in: rootView)
            rootView.window?.invalidateCursorRects(for: rootView)
            rootView.window?.resetCursorRects()
        }

        rootView = nil
        restoreBehavior = .reattach
    }

    private func updateTrackingAreasRecursively(in view: NSView) {
        view.updateTrackingAreas()
        for subview in view.subviews {
            updateTrackingAreasRecursively(in: subview)
        }
    }
}

private extension NSTrackingArea {
    var isTooltipTrackingArea: Bool {
        guard let owner else { return false }
        return String(describing: type(of: owner)).localizedCaseInsensitiveContains("tooltip")
    }
}

/// Owns the pixels where the chrome overlaps content and forwards each event to the surface the input
/// coordinator picks. Hover is deliberately not overridden: the global monitor and
/// `ChromeHoverStateMachine` set and clear chrome `:hover` symmetrically.
final class ChromeInteractionShieldView: NSView {
    weak var input: ChromeInputController?
    private var isRoutingCursorUpdate = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinates, and the chrome web view that hosts the shield is flipped.
        guard input?.router.target(forWindowPoint: superview?.convert(point, to: nil) ?? point) == .chrome else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) { route(event, .leftMouseDown) { $0.mouseDown(with: $1) } }
    override func mouseDragged(with event: NSEvent) { route(event, .leftMouseDragged) { $0.mouseDragged(with: $1) } }
    override func mouseUp(with event: NSEvent) { route(event, .leftMouseUp) { $0.mouseUp(with: $1) } }
    override func rightMouseDown(with event: NSEvent) { route(event, .rightMouseDown) { $0.rightMouseDown(with: $1) } }
    override func rightMouseDragged(with event: NSEvent) { route(event, .rightMouseDragged) { $0.rightMouseDragged(with: $1) } }
    override func rightMouseUp(with event: NSEvent) { route(event, .rightMouseUp) { $0.rightMouseUp(with: $1) } }
    override func otherMouseDown(with event: NSEvent) { route(event, .otherMouseDown) { $0.otherMouseDown(with: $1) } }
    override func otherMouseDragged(with event: NSEvent) { route(event, .otherMouseDragged) { $0.otherMouseDragged(with: $1) } }
    override func otherMouseUp(with event: NSEvent) { route(event, .otherMouseUp) { $0.otherMouseUp(with: $1) } }
    override func scrollWheel(with event: NSEvent) { route(event, .scrollWheel) { $0.scrollWheel(with: $1) } }
    override func magnify(with event: NSEvent) { route(event, .magnify) { $0.magnify(with: $1) } }
    override func rotate(with event: NSEvent) { route(event, .rotate) { $0.rotate(with: $1) } }
    override func swipe(with event: NSEvent) { route(event, .swipe) { $0.swipe(with: $1) } }
    override func smartMagnify(with event: NSEvent) { route(event, .smartMagnify) { $0.smartMagnify(with: $1) } }

    override func cursorUpdate(with event: NSEvent) {
        guard !isRoutingCursorUpdate else { return }
        isRoutingCursorUpdate = true
        defer { isRoutingCursorUpdate = false }
        route(event, .cursorUpdate) { $0.cursorUpdate(with: $1) }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        input?.router.chromeView?.draggingEntered(sender) ?? []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        input?.router.chromeView?.draggingUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        input?.router.chromeView?.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        input?.router.chromeView?.prepareForDragOperation(sender) ?? false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        input?.router.chromeView?.performDragOperation(sender) ?? false
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        input?.router.chromeView?.concludeDragOperation(sender)
    }

    override func wantsPeriodicDraggingUpdates() -> Bool {
        true
    }

    /// The shield is the sole feeder of the capture machine: it sees the whole chrome-owned
    /// down/drag/up sequence, which the monitor's mask excludes, so it returns capture effects only.
    private func route(_ event: NSEvent, _ family: ChromeEventRouter.EventFamily, forward: (NSView, NSEvent) -> Void) {
        guard let input else { return }
        let sample = PointerSample(
            target: input.router.target(forWindowPoint: event.locationInWindow) == .chrome ? .chrome : .content,
            isMouseDown: event.isMouseDown,
            scrollPhase: event.captureGesturePhase(for: family)
        )
        let (target, effects) = input.coordinator.routePositional(sample, family: family)
        switch target {
        case .chrome: input.router.chromeView.map { forward($0, event) }
        case .content: (input.controller.splitPanes.view(for: event) ?? input.router.currentContentView()).map { forward($0, event) }
        case .none: break
        }
        // After the forward: a release over the page resamples into a chrome hover clear, which WebKit turns into a
        // buttonless move that cancels the chrome's pointer drag before its mouse-up lands.
        input.apply(effects, for: event)
    }
}

/// Routes the pointer between the chrome overlay and the content area. Owns the event router, the
/// shield, the input coordinator and the hover monitor, and is the only place their effects apply.
@MainActor
final class ChromeInputController {
    unowned let controller: MainWindowController
    let coordinator = ChromeInputCoordinator()
    lazy var router = ChromeEventRouter(zoneStore: controller.chromeInteractiveZones, captureMachine: coordinator.capture)
    /// Takes the pointer over chrome zones, inside the chrome web view so WebKit applies the chrome's cursor.
    let shield = ChromeInteractionShieldView()
    private let contentHoverSuspender = TrackingAreaSuspender()
    private var keyMonitor: Any?
    private var hoverMonitor: Any?
    /// Last drag-type set applied to the shield; registerForDraggedTypes only runs on change.
    private var shieldDragTypes: Set<NSPasteboard.PasteboardType> = []
    private(set) var debugOverlay: HitboxDebugOverlayView?

    /// What the shield registers for before the chrome web view reports its own drag types, file URLs
    /// included, so a file dropped on page content always reaches the shield.
    private static let fallbackDragTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, .URL, .string, .png, .tiff, .pdf, .rtf, .html,
        NSPasteboard.PasteboardType("NSFilenamesPboardType")
    ]

    init(controller: MainWindowController) {
        self.controller = controller
        shield.input = self
    }

    /// Hands every key to the window's shortcuts and every mouse move and press to `updatePointer(for:)`.
    /// Local monitors run on the main thread.
    func startMonitoring() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated { self?.controller.handleMonitoredKeyboardEvent(event) == true } ? nil : event
        }
        controller.window?.acceptsMouseMovedEvents = true
        // No .cursorUpdate: real mouseMoved events already carry every positional change, and
        // feeding cursor updates too doubles the synthetic moves into WebKit while hovering chrome.
        hoverMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                // Every window sees each move: reject other windows' events before allocating anything.
                if let self, event.window === self.controller.window { self.updatePointer(for: event) }
            }
            return event
        }
    }

    /// Stops the monitors and clears the hover transition and the capture latch, so a reused window
    /// can't start with a stale hover that suppresses the next chrome entry, or a grab that binds the next gesture.
    func stop() {
        for monitor in [keyMonitor, hoverMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        (keyMonitor, hoverMonitor) = (nil, nil)
        coordinator.reset()
    }

    /// Points the router at what the content area shows. The chrome web view's `registeredDraggedTypes`
    /// is empty before its first load, so the shield registers a file-capable set of its own until then.
    func setContentView(_ contentView: NSView?) {
        router.updateContentView(contentView)
        let chromeTypes = controller.chromeWebView.registeredDraggedTypes
        let targetTypes = Set(chromeTypes.isEmpty ? Self.fallbackDragTypes : chromeTypes)
        guard targetTypes != shieldDragTypes else { return }
        shieldDragTypes = targetTypes
        shield.registerForDraggedTypes(Array(targetTypes))
    }

    func setDebugOverlayShown(_ shown: Bool) {
        guard let contentView = controller.window?.contentView else { return }
        guard shown else {
            debugOverlay?.removeFromSuperview()
            debugOverlay = nil
            return
        }
        let overlay = debugOverlay ?? HitboxDebugOverlayView(frame: contentView.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.clear.cgColor
        overlay.zones = controller.chromeInteractiveZones.currentZones()
        if overlay.superview == nil {
            contentView.addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        debugOverlay = overlay
        // Seeds the ownership legend before the first mouse move; zone updates reach the overlay through
        // the fanout installed in setupTabDock.
        overlay.ownership = InteractionOwnershipSnapshot(
            capture: coordinator.isCapturing ? coordinator.effectiveCaptureTarget : nil,
            hover: .none,
            focus: controller.focusOwner
        )
    }

    /// The global monitor is the sole caller of `updatePointer`, so one physical move is never classified
    /// and run through the machines twice.
    func updatePointer(for event: NSEvent) {
        let target: ChromeEventRouter.Target = router.target(forWindowPoint: event.locationInWindow) == .chrome ? .chrome : .content
        // The debug overlay reflects every sampled point, even on the no-op fast path; redraw is change-only.
        if let debugOverlay {
            let chrome = controller.chromeWebView
            debugOverlay.testedPoint = controller.chromeInteractiveZones.viewportPoint(
                from: chrome.convert(event.locationInWindow, from: nil), in: chrome.bounds, isFlipped: chrome.isFlipped
            )
            debugOverlay.testedPointIsInteractive = target == .chrome
            debugOverlay.ownership = InteractionOwnershipSnapshot(
                capture: coordinator.isCapturing ? coordinator.effectiveCaptureTarget : nil,
                hover: target,
                focus: controller.focusOwner
            )
        }
        // Presses go through here too, because a content press never reaches the shield: its hitTest returns
        // nil over content. `updatePointer` self-gates, returning `.none` while a grab is held. The monitor
        // never sees scroll or zoom gestures (those reach the shield), so this feed carries no fling phase.
        let sample = PointerSample(target: target, isMouseDown: event.isMouseDown, scrollPhase: .none)
        apply(coordinator.updatePointer(sample), for: event)
        // A press on a pane goes straight to its view, never through the shield: this is where it
        // makes that pane's tab the active one.
        if event.isMouseDown, target == .content {
            _ = controller.splitPanes.view(for: event)
            controller.tabManager.activeEngineTab?.logUserInteraction()
        }
    }

    /// The single impure sink, executing in the order the coordinator already merged. The only place that
    /// forwards chrome moves, toggles tracking and sends `contentInteraction`.
    func apply(_ effects: [InteractionEffect], for event: NSEvent?) {
        for effect in effects {
            switch effect {
            case .hover(let hoverEffect):
                applyHoverEffect(hoverEffect, for: event)
            case .capture(.resamplePointer):
                // A grab just ended: resample the live pointer so hover and cursor resync to the release
                // position. No NSEvent on a resample: the hover applier's move and clear paths guard on it.
                guard let window = controller.window else { continue }
                let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
                let target: ChromeEventRouter.Target = router.target(forWindowPoint: windowPoint) == .chrome ? .chrome : .content
                apply(coordinator.updatePointer(PointerSample(target: target, isMouseDown: false, scrollPhase: .none)), for: nil)
            case .capture:
                // Drag and drop is relayed by ChromeEventRouter; the mouse and gesture paths only emit `.resamplePointer`.
                break
            }
        }
    }

    private func applyHoverEffect(_ effect: ChromeHoverEffect, for event: NSEvent?) {
        let chrome = controller.chromeWebView
        switch effect {
        case .setContentTrackingSuspended(let suspended):
            // The whole content container: every split pane sits under the chrome overlay.
            contentHoverSuspender.setSuspended(
                suspended,
                in: controller.contentContainerView,
                restoreBehavior: .reattachNonTooltipAreas
            )
            // Suspending tracking only freezes the content page's `:hover`, since removing the tracking areas
            // kills WebKit's natural mouseExited, so the clear is driven explicitly.
            if suspended {
                for id in controller.displayedTabIds {
                    (controller.tabManager.engineTab(for: id)?.view as? WKWebView)?.liloClearPageHover()
                }
                // The hovered-link readout needs the same explicit clear: WebKit stops reporting the
                // element under the pointer for a view it no longer tracks, so the bar would keep
                // showing the last link the pointer crossed on its way out.
                controller.sendHoveredLink("")
            }
        case .setChromeTrackingEnabled(let enabled):
            chrome.setMouseTrackingEnabled(enabled)
        case .clearChromeHover:
            // Re-hit-test at the now-content point, where `#chrome-root` is pointer-events:none, so `:hover`
            // clears and mouseleave fires. A capture-end resample has no event and maps the live pointer.
            let windowPoint = event?.locationInWindow ?? chrome.window?.convertPoint(fromScreen: NSEvent.mouseLocation) ?? .zero
            chrome.liloSimulateMouseExit(atWindowPoint: windowPoint)
        case .emitContentInteraction(let isMouseDown):
            // Native focus is already AppKit's, so this only blurs `document.activeElement` inside `#chrome-root`.
            // Emitted once, on the hover feed.
            controller.bridgeRouter.send(event: "contentInteraction", data: ["isMouseDown": isMouseDown])
        case .forwardMoveToChrome:
            // Refreshes `:hover` for intra-chrome targets. A capture-end resample has no NSEvent, it only clears.
            guard let event else { return }
            chrome.liloSimulateMouseMove(event)
        }
    }
}

extension MainWindowController {
    /// Which surface owns keyboard focus, read from `window.firstResponder`; never read on a hover move.
    var focusOwner: ChromeEventRouter.Target {
        if isFirstResponderInsideChromeUI() { return .chrome }
        if isFirstResponderInsideContentView() { return .content }
        return .none
    }

    func isFirstResponderInsideChromeUI() -> Bool {
        contains(responder: window?.firstResponder)
    }

    func isFirstResponderInsideContentView() -> Bool {
        chromeInput.router.containsContentResponder(window?.firstResponder)
    }

    /// True if `responder` is the chrome web view or a descendant of it.
    func contains(responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView else { return false }
        return view === chromeWebView || view.isDescendant(of: chromeWebView)
    }

    /// Click-less request to give the chrome keyboard focus (command bar, new tab, history).
    func focusChrome() {
        guard focusOwner != .chrome else { return }
        window?.makeFirstResponder(chromeWebView)
    }

    /// Gives `contentView` keyboard focus (tab activation), and always blurs the chrome DOM, which may
    /// still hold `activeElement` from a prior chrome visit (`blurChromeFocus` in App.svelte).
    func focusContent(_ contentView: NSView) {
        if focusOwner != .content {
            window?.makeFirstResponder(contentView)
        }
        bridgeRouter?.send(event: "contentInteraction", data: ["isMouseDown": true])
    }
}

private extension NSEvent {
    var isMouseDown: Bool {
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return true
        default:
            return false
        }
    }
}
