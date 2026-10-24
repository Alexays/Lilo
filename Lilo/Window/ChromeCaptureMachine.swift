import Foundation

/// Ordered side effects of the capture lifecycle for the drag-and-drop relay; `ChromeEventRouter` alone turns them into real calls.
/// Mouse drags and flings need no effect, only the returned `target`.
enum CaptureEffect: Equatable {
    /// Relay a drag *enter* to the chrome / content destination (first time the session
    /// owns that surface).
    case enterChrome
    case enterContent
    /// Relay a drag *update* to a destination the session already owns.
    case updateChrome
    case updateContent
    /// Relay a drag *exit* to a destination the session is leaving (on a cross-surface
    /// transition, or when the whole session exits).
    case exitChrome
    case exitContent
    /// Relay drag *conclude* to the surface that owned the session at drop time.
    case concludeChrome
    case concludeContent
    /// Emitted when a capture *ends* (mouse-up, gesture `.ended`/`.cancelled`, DnD conclude)
    /// after a real grab was held. The window controller's capture applier turns it into a fresh
    /// `updatePointer` at the live location so hover/cursor resync to the release position.
    case resamplePointer
}

/// Single owner of the gestural grab (mouse drags, drag-and-drop sessions, gesture-phase flings), so an inertial scroll never re-routes
/// mid-flight. Pure: the router passes the classification in; `isCapturing` lets the input coordinator skip the hover machine.
@MainActor
final class ChromeCaptureMachine {
    /// The outcome of routing one event: which surface the event must go to, and any
    /// ordered drag-relay effects the edge must apply.
    struct Outcome: Equatable {
        let target: ChromeEventRouter.Target
        let effects: [CaptureEffect]
    }

    enum MousePhase: Equatable { case down, dragged, up }
    /// Mirrors `NSEvent.Phase` collapsed to what matters: a gesture begins, changes,
    /// ends, is cancelled, or carries no phase at all (a classic mouse-wheel line scroll).
    enum GesturePhase: Equatable { case began, changed, ended, cancelled, none }
    enum DragPhase: Equatable { case entered, updated, exited, concluded }

    private var mouseLatch: ChromeEventRouter.Target = .none
    private var gestureLatch: ChromeEventRouter.Target = .none
    private var dragTarget: ChromeEventRouter.Target = .none

    /// True while any of the three lifetimes holds a grab. The coordinator gates hover /
    /// cursor work on this (drags/flings pay zero hover cost: precedence rule 1).
    var isCapturing: Bool {
        mouseLatch != .none || gestureLatch != .none || dragTarget != .none
    }

    /// The surface a held grab is latched to (mouse-drag / fling / DnD, in that precedence),
    /// or `.none` when nothing is captured. Debug-overlay diagnostics only: routing goes through
    /// `routeMouse`/`routeGesture`/`routeDrag`.
    var capturedTarget: ChromeEventRouter.Target {
        if mouseLatch != .none { return mouseLatch }
        if gestureLatch != .none { return gestureLatch }
        return dragTarget
    }

    // MARK: (a) mouse-button drags

    func routeMouse(phase: MousePhase, classification: ChromeEventRouter.Target) -> Outcome {
        switch phase {
        case .down:
            mouseLatch = classification
            return Outcome(target: classification, effects: [])
        case .dragged:
            return Outcome(target: mouseLatch != .none ? mouseLatch : classification, effects: [])
        case .up:
            let effective = mouseLatch != .none ? mouseLatch : classification
            let held = mouseLatch != .none
            mouseLatch = .none
            return Outcome(target: effective, effects: held ? [.resamplePointer] : [])
        }
    }

    // MARK: (c) scroll / magnify / rotate / smartMagnify flings

    func routeGesture(phase: GesturePhase, classification: ChromeEventRouter.Target) -> Outcome {
        switch phase {
        case .began:
            gestureLatch = classification
            return Outcome(target: classification, effects: [])
        case .changed:
            return Outcome(target: gestureLatch != .none ? gestureLatch : classification, effects: [])
        case .ended, .cancelled:
            let effective = gestureLatch != .none ? gestureLatch : classification
            let held = gestureLatch != .none
            gestureLatch = .none
            return Outcome(target: effective, effects: held ? [.resamplePointer] : [])
        case .none:
            // Phaseless scroll never latches: route to wherever the pointer is now.
            return Outcome(target: classification, effects: [])
        }
    }

    // MARK: (b) drag-and-drop sessions

    func routeDrag(phase: DragPhase, classification: ChromeEventRouter.Target) -> Outcome {
        switch phase {
        case .entered, .updated:
            let previous = dragTarget
            dragTarget = classification
            return Outcome(target: classification, effects: enterEffects(from: previous, to: classification))
        case .exited:
            let previous = dragTarget
            dragTarget = .none
            return Outcome(target: previous, effects: exitEffects(for: previous))
        case .concluded:
            let previous = dragTarget
            dragTarget = .none
            return Outcome(target: previous, effects: concludeEffects(for: previous))
        }
    }

    /// On a same-surface update emit the surface's `update*`; on a cross-surface transition
    /// emit the leaving surface's `exit*` then the entering surface's `enter*`.
    private func enterEffects(
        from previous: ChromeEventRouter.Target,
        to next: ChromeEventRouter.Target
    ) -> [CaptureEffect] {
        if previous == next {
            switch next {
            case .chrome: return [.updateChrome]
            case .content: return [.updateContent]
            case .none: return []
            }
        }
        var effects: [CaptureEffect] = []
        effects.append(contentsOf: exitEffects(for: previous))
        switch next {
        case .chrome: effects.append(.enterChrome)
        case .content: effects.append(.enterContent)
        case .none: break
        }
        return effects
    }

    private func exitEffects(for target: ChromeEventRouter.Target) -> [CaptureEffect] {
        switch target {
        case .chrome: return [.exitChrome]
        case .content: return [.exitContent]
        case .none: return []
        }
    }

    private func concludeEffects(for target: ChromeEventRouter.Target) -> [CaptureEffect] {
        switch target {
        case .chrome: return [.concludeChrome]
        case .content: return [.concludeContent]
        case .none: return []
        }
    }

    /// Reset on teardown / window change so a stale latch can't bind the next gesture.
    func reset() {
        mouseLatch = .none
        gestureLatch = .none
        dragTarget = .none
    }
}
