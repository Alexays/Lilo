import AppKit
import WebKit

/// Classifies window points between the chrome overlay and the content area, relays drag and drop
/// to the surface that owns it, and hands unhandled keys to the content.
@MainActor
final class ChromeEventRouter {
    enum Target: Equatable {
        case chrome
        case content
        case none
    }

    enum EventFamily {
        case leftMouseDown
        case leftMouseDragged
        case leftMouseUp
        case rightMouseDown
        case rightMouseDragged
        case rightMouseUp
        case otherMouseDown
        case otherMouseDragged
        case otherMouseUp
        case cursorUpdate
        case scrollWheel
        case magnify
        case rotate
        case swipe
        case smartMagnify
    }

    /// Set by the overlay when it takes this router.
    weak var chromeView: OverlayWebView?
    /// What the content area shows (a page, a terminal, a diff); nil between tabs.
    private weak var contentView: NSView?
    let zoneStore: ChromeInteractiveZoneStore
    /// The input coordinator's capture machine, so one grab is visible to the drag relay too.
    let captureMachine: ChromeCaptureMachine

    /// The machine tracks only the abstract `.content` target; the concrete view is resolved here.
    /// Written only by the effect applier, read by prepare, perform and conclude.
    private weak var contentDragDestination: NSView?

    /// Lets the window hand a drag over the page to the chrome instead (a link aimed at a split side).
    var routesDragToChrome: ((any NSDraggingInfo) -> Bool)?
    /// Called as a drag enters the chrome, before WebKit sees it, so the window can tell the chrome what it carries,
    /// and with nil as it leaves.
    var chromeDragChanged: (((any NSDraggingInfo)?) -> Void)?

    init(zoneStore: ChromeInteractiveZoneStore, captureMachine: ChromeCaptureMachine) {
        self.zoneStore = zoneStore
        self.captureMachine = captureMachine
    }

    func updateContentView(_ contentView: NSView?) {
        self.contentView = contentView
        if contentView == nil {
            // Tab teardown / window close: drop any held latch so a stale grab can't bind
            // the next gesture in a freshly-attached content view.
            captureMachine.reset()
        }
    }

    /// The single point classification for the chrome and content boundary: `.chrome` inside a zone
    /// the chrome registered, else `.content`, or `.none` with nothing in the content area.
    func target(forWindowPoint windowPoint: NSPoint) -> Target {
        if let chromeView, zoneStore.isInteractive(windowPoint: windowPoint, in: chromeView) { return .chrome }
        return currentContentView() == nil ? .none : .content
    }

    /// The content view, except the chrome view itself, which is never its own content destination.
    func currentContentView() -> NSView? {
        guard let contentView, contentView !== chromeView else { return nil }
        return contentView
    }

    @discardableResult
    func routeUnhandledGlobalEvent(_ event: NSEvent) -> Bool {
        guard let contentView = currentContentView() else { return false }
        // A page under its tab-modal dialog takes no keys.
        if contentView.subviews.contains(where: { $0 is TabModalDialogView }) { return false }

        switch event.type {
        case .keyDown:
            contentView.keyDown(with: event)
        case .keyUp:
            contentView.keyUp(with: event)
        case .flagsChanged:
            contentView.flagsChanged(with: event)
        default:
            return false
        }

        return true
    }

    func containsContentResponder(_ responder: NSResponder?) -> Bool {
        guard let responder = responder as? NSView,
              let contentView = currentContentView() else { return false }
        return responder === contentView || responder.isDescendant(of: contentView)
    }

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let outcome = captureMachine.routeDrag(phase: .entered, classification: dragTarget(for: sender))
        return applyDragEffects(outcome.effects, sender: sender)
    }

    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let outcome = captureMachine.routeDrag(phase: .updated, classification: dragTarget(for: sender))
        return applyDragEffects(outcome.effects, sender: sender)
    }

    func draggingExited(_ sender: (any NSDraggingInfo)?) {
        let outcome = captureMachine.routeDrag(
            phase: .exited,
            classification: sender.map(dragTarget(for:)) ?? .none
        )
        guard let sender else {
            contentDragDestination = nil
            return
        }
        _ = applyDragEffects(outcome.effects, sender: sender)
    }

    func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        // Reconcile-only: a same-destination update must not fire `draggingUpdated`, since the prepare call
        // follows immediately.
        let outcome = captureMachine.routeDrag(phase: .updated, classification: dragTarget(for: sender))
        _ = applyDragEffects(outcome.effects, sender: sender, reconcileOnly: true)
        switch outcome.target {
        case .chrome:
            return chromeView?.receiveChromePrepareForDragOperation(sender) ?? false
        case .content:
            return contentDragDestination?.prepareForDragOperation(sender) ?? false
        case .none:
            return false
        }
    }

    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let outcome = captureMachine.routeDrag(phase: .updated, classification: dragTarget(for: sender))
        _ = applyDragEffects(outcome.effects, sender: sender, reconcileOnly: true)
        switch outcome.target {
        case .chrome:
            return chromeView?.receiveChromePerformDragOperation(sender) ?? false
        case .content:
            return contentDragDestination?.performDragOperation(sender) ?? false
        case .none:
            return false
        }
    }

    func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        // Conclude acts on the surface the session already owns, not the drop location, so the passed
        // classification is ignored by the machine's `.concluded` branch.
        let outcome = captureMachine.routeDrag(phase: .concluded, classification: .none)
        for effect in outcome.effects {
            switch effect {
            case .concludeChrome:
                chromeView?.receiveChromeConcludeDragOperation(sender)
            case .concludeContent:
                contentDragDestination?.concludeDragOperation(sender)
                contentDragDestination = nil
            default:
                break
            }
        }
    }

    private func dragTarget(for sender: any NSDraggingInfo) -> Target {
        guard target(forWindowPoint: sender.draggingLocation) != .chrome,
              routesDragToChrome?(sender) != true else {
            return .chrome
        }
        // A page under its tab-modal dialog takes no drop.
        guard let content = currentContentView(), !content.subviews.contains(where: { $0 is TabModalDialogView }) else { return .none }
        return .content
    }

    /// Turn the machine's ordered `CaptureEffect`s into real chrome / content-destination
    /// calls and maintain the concrete `contentDragDestination` cache. Returns the resolved
    /// `NSDragOperation` for the surface the event entered/updated (enter/update only).
    @discardableResult
    private func applyDragEffects(
        _ effects: [CaptureEffect],
        sender: any NSDraggingInfo,
        reconcileOnly: Bool = false
    ) -> NSDragOperation {
        var operation: NSDragOperation = []
        for effect in effects {
            switch effect {
            case .exitChrome:
                chromeView?.receiveChromeDraggingExited(sender)
                chromeDragChanged?(nil)
            case .exitContent:
                contentDragDestination?.draggingExited(sender)
                contentDragDestination = nil
            case .enterChrome:
                contentDragDestination = nil
                chromeDragChanged?(sender)
                operation = chromeView?.receiveChromeDraggingEntered(sender) ?? []
            case .enterContent:
                let destination = currentContentView()
                if contentDragDestination !== destination {
                    contentDragDestination?.draggingExited(sender)
                }
                contentDragDestination = destination
                operation = destination?.draggingEntered(sender) ?? []
            case .updateChrome:
                // In reconcile-only mode (prepare/perform) chrome needs no relay update:
                // the prepare/perform call follows directly.
                if !reconcileOnly {
                    operation = chromeView?.receiveChromeDraggingUpdated(sender) ?? []
                }
            case .updateContent:
                // The content view may have been swapped mid-drag (tab change); if so the
                // machine still reports .content but the concrete destination changed, so
                // re-enter the new one.
                let destination = currentContentView()
                if contentDragDestination !== destination {
                    contentDragDestination?.draggingExited(sender)
                    contentDragDestination = destination
                    operation = destination?.draggingEntered(sender) ?? []
                } else if !reconcileOnly {
                    // Same destination: a real `.updated` fires draggingUpdated, but reconcile-only
                    // mode must NOT: the prepare/perform call follows directly (no duplicate update).
                    operation = contentDragDestination?.draggingUpdated(sender) ?? []
                }
            case .concludeChrome, .concludeContent:
                break // handled in concludeDragOperation
            case .resamplePointer:
                break // not applied on the DnD relay; hover resyncs on the next global-monitor move
            }
        }
        return operation
    }
}

extension NSEvent {
    /// The single NSEvent-to-phase mapping; the capture machine never reads NSEvent. Only scroll,
    /// zoom, rotate and swipe carry a phase, so no other family ever latches. Momentum arrives after
    /// `phase` has ended, so its .began and .changed must hold the latch and only its .ended releases.
    func captureGesturePhase(for family: ChromeEventRouter.EventFamily) -> ChromeCaptureMachine.GesturePhase {
        switch family {
        case .scrollWheel, .magnify, .rotate, .swipe, .smartMagnify:
            break
        default:
            return .none
        }
        switch phase {
        case .began:
            return .began
        case .changed, .stationary:
            return .changed
        case .ended:
            return .ended
        case .cancelled:
            return .cancelled
        default:
            switch momentumPhase {
            case .began, .changed, .stationary:
                return .changed
            case .ended, .cancelled:
                return .ended
            default:
                return .none
            }
        }
    }
}
