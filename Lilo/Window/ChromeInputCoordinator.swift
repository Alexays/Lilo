import AppKit

/// Pointer input packed at the edge. The coordinator and machines read nothing live: injecting the
/// impurity is what makes the precedence rules testable.
struct PointerSample: Equatable {
    /// The single classification for this event, computed ONCE at the edge (classify-once).
    let target: ChromeEventRouter.Target
    let isMouseDown: Bool
    /// Scroll / magnify / rotate / smartMagnify gesture phase, or `.none` for plain moves.
    let scrollPhase: ChromeCaptureMachine.GesturePhase
}

/// The one type the applier switches over; each machine keeps its own focused enum.
enum InteractionEffect: Equatable {
    case hover(ChromeHoverEffect)
    case capture(CaptureEffect)

    /// Callers must return this constant, never a fresh `[]`: the fast path allocates nothing.
    static let none: [InteractionEffect] = []
}

/// Pure decision core composing the hover and capture machines. Precedence:
/// 1. capture dominates positional, 2. cursor follows capture else position, 3. hover fires only
/// outside capture, and capture-end emits `.resamplePointer` so the edge resyncs hover and cursor.
@MainActor
final class ChromeInputCoordinator {
    typealias EventFamily = ChromeEventRouter.EventFamily
    typealias Target = ChromeEventRouter.Target

    let hover = ChromeHoverStateMachine()
    /// Shared with the window's `ChromeEventRouter`, whose drag relay latches through it too.
    let capture = ChromeCaptureMachine()

    /// The capture machine is the single source of capture state.
    var isCapturing: Bool { capture.isCapturing }

    /// Diagnostics only (debug overlay); never consulted on the routing hot path.
    var effectiveCaptureTarget: ChromeEventRouter.Target { capture.capturedTarget }

    func reset() {
        hover.reset()
        capture.reset()
    }

    // MARK: - Hover / cursor feeder

    /// Hover and cursor feeder, fed only by the global monitor. While capturing, the hover machine is
    /// not invoked at all; a plain move with an unchanged target returns the shared empty list.
    func updatePointer(_ sample: PointerSample) -> [InteractionEffect] {
        // Rules 1 and 3: capture dominates, so no hover transitions mid-gesture.
        if capture.isCapturing {
            return InteractionEffect.none
        }

        let isInteractive = (sample.target == .chrome)

        // An interactive no-transition move must NOT be short-circuited: the hover machine still has to
        // emit `.forwardMoveToChrome` so WebKit keeps refreshing CSS `:hover` inside the chrome.
        if !sample.isMouseDown, isInteractive == hover.isInteractive, !isInteractive {
            return InteractionEffect.none
        }

        let hoverEffects = hover.update(isInteractive: isInteractive, isMouseDown: sample.isMouseDown)
        if hoverEffects.isEmpty { return InteractionEffect.none }
        return hoverEffects.map(InteractionEffect.hover)
    }

    // MARK: - Positional routing

    /// Positional routing, fed only by the shield. Drives the capture machine and returns the effective
    /// captured-or-position target. Hover and focus belong to `updatePointer`, the single hover feeder.
    @discardableResult
    func routePositional(_ sample: PointerSample, family: EventFamily) -> (Target, [InteractionEffect]) {
        // Driving hover or focus here would be a second mutation of state the global monitor already owns:
        // it sees every move and every press, including content presses that never reach the shield.
        let outcome = captureOutcome(for: family, sample: sample)
        return (outcome.target, outcome.effects.map(InteractionEffect.capture))
    }

    // MARK: - Helpers

    /// Mouse-button families latch via `routeMouse`, phased gestures via `routeGesture`; everything else
    /// is non-latching and resolves to the captured target if a grab is held, else the live one.
    private func captureOutcome(
        for family: EventFamily,
        sample: PointerSample
    ) -> ChromeCaptureMachine.Outcome {
        switch family {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return capture.routeMouse(phase: .down, classification: sample.target)
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return capture.routeMouse(phase: .dragged, classification: sample.target)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return capture.routeMouse(phase: .up, classification: sample.target)
        // `.swipe` is latched deliberately: a three-finger swipe is phased and would otherwise bleed across
        // the chrome/content boundary mid-flight.
        case .scrollWheel, .magnify, .rotate, .swipe, .smartMagnify:
            return capture.routeGesture(phase: sample.scrollPhase, classification: sample.target)
        default:
            // A held grab reports the latched target without mutating the latch, so no new lifetime starts.
            if capture.isCapturing {
                return capture.routeMouse(phase: .dragged, classification: sample.target)
            }
            return ChromeCaptureMachine.Outcome(target: sample.target, effects: [])
        }
    }
}
