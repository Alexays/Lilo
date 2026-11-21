import AppKit

/// A floating panel hosting a web view. AppKit turns a trackpad scroll or pinch starting over a
/// view that answers `mouseDownCanMoveWindow` (an opaque view, like the hosted web view) into a
/// window move — and over a resizable panel's edge into a resize — so a two-finger scroll meant
/// for the page would fling the panel across the screen or stretch it. The gesture goes to the
/// view under the pointer instead: moving stays a press-drag, resizing a drag on the edges.
@MainActor
class GestureForwardingPanel: NSPanel {
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .scrollWheel: forwardGesture(event) { $0.scrollWheel(with: $1) }
        case .magnify: forwardGesture(event) { $0.magnify(with: $1) }
        case .swipe: forwardGesture(event) { $0.swipe(with: $1) }
        case .rotate: forwardGesture(event) { $0.rotate(with: $1) }
        case .smartMagnify: forwardGesture(event) { $0.smartMagnify(with: $1) }
        default: super.sendEvent(event)
        }
    }

    /// Delivers to the view under the pointer what AppKit would first test for a window move or
    /// resize. Outside the content — a titled panel's frame — AppKit dispatches as usual.
    private func forwardGesture(_ event: NSEvent, _ deliver: (NSResponder, NSEvent) -> Void) {
        guard let contentView,
              let view = contentView.hitTest(contentView.convert(event.locationInWindow, from: nil))
        else { return super.sendEvent(event) }
        deliver(view, event)
    }
}
