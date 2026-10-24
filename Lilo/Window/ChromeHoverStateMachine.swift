import Foundation

/// Ordered side effects of the hover lifecycle; the machine is pure and `MainWindowController` alone turns them into real calls.
enum ChromeHoverEffect: Equatable {
    /// Pointer entered/left interactive chrome: suspend content-tab tracking areas while true.
    case setContentTrackingSuspended(Bool)
    /// Enable/disable the chrome web view's own tracking areas.
    case setChromeTrackingEnabled(Bool)
    /// Re-hit-test chrome at the now-content point so WebKit drops any stale CSS :hover
    /// (e.g. the sidebar resize handle) and fires mouseleave. The applier drives this via the
    /// WebKit `_impl` SPI (`_simulateMouseExit:`).
    case clearChromeHover
    /// Notify chrome JS that interaction moved to content (clears focus/popups).
    case emitContentInteraction(isMouseDown: Bool)
    /// Refresh CSS :hover for intra-chrome targets on a no-transition interactive move, via the
    /// WebKit `_impl` SPI (`_simulateMouseMove:`). The global monitor owns hover-SET as well as
    /// the clear, a symmetric lifecycle.
    case forwardMoveToChrome
}

/// Single owner of the chrome/content pointer transition lifecycle. Driven by the global
/// hover monitor; no other type tracks the hover transition.
@MainActor
final class ChromeHoverStateMachine {
    private var wasInteractive = false
    /// Set on chrome entry; cleared the first time the pointer leaves to content (or on a
    /// content mouse-down). Gates the one-shot `contentInteraction` signal.
    private var hasTransientPointerState = false

    /// The single source of truth for "is the pointer on chrome": the input coordinator reads it rather than a shadow copy that could
    /// desync across a capture and leave `:hover` stuck.
    var isInteractive: Bool { wasInteractive }

    /// Returns the ordered effects for this pointer sample. `isInteractive` is the single
    /// classification (see `ChromeEventRouter.target`); `isMouseDown` distinguishes a
    /// press from a hover move.
    func update(isInteractive: Bool, isMouseDown: Bool) -> [ChromeHoverEffect] {
        let wasInteractivePrev = wasInteractive

        // No transition on a plain move. On content there is nothing to do; on chrome we must
        // keep forwarding the move so WebKit refreshes CSS :hover for intra-chrome targets
        // (the hover-SET half of the symmetric lifecycle the global monitor owns).
        if !isMouseDown, isInteractive == wasInteractivePrev {
            return isInteractive ? [.forwardMoveToChrome] : []
        }

        wasInteractive = isInteractive
        var effects: [ChromeHoverEffect] = [.setContentTrackingSuspended(isInteractive)]

        if isInteractive {
            hasTransientPointerState = true
            effects.append(.setChromeTrackingEnabled(true))
            return effects
        }

        if wasInteractivePrev {
            effects.append(.clearChromeHover)
            effects.append(.setChromeTrackingEnabled(false))
        }
        if hasTransientPointerState || isMouseDown {
            hasTransientPointerState = false
            effects.append(.emitContentInteraction(isMouseDown: isMouseDown))
        }
        return effects
    }

    /// Reset on teardown / window change so a stale `wasInteractive` can't suppress the
    /// next entry's effects.
    func reset() {
        wasInteractive = false
        hasTransientPointerState = false
    }
}
