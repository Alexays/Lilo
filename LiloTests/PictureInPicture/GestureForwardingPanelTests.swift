import AppKit
import XCTest
@testable import Lilo

/// Trackpad gestures stay in the hosted page: the panel hands them to the view under the pointer
/// rather than letting AppKit read them as a window move or resize.
@MainActor
final class GestureForwardingPanelTests: XCTestCase {
    func testAScrollOverTheContentReachesTheViewUnderThePointer() throws {
        let panel = GestureForwardingPanel(
            contentRect: NSRect(x: 200, y: 200, width: 320, height: 200),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        defer { panel.orderOut(nil) }
        let spy = GestureSpy(frame: NSRect(origin: .zero, size: NSSize(width: 320, height: 200)))
        panel.contentView?.addSubview(spy)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        // A scroll CGEvent over the panel, as AgentInput.scroll makes one. Its NSEvent has no
        // window, so `locationInWindow` carries the flipped global point as-is: give it the point
        // a real event would read in the window's coordinates.
        let inside = NSPoint(x: 160, y: 100)
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -8, wheel2: 0, wheel3: 0
        ), let screen = NSScreen.screens.first else { return XCTFail("no scroll event") }
        cgEvent.location = CGPoint(x: inside.x, y: screen.frame.height - inside.y)
        cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(panel.windowNumber))
        guard let event = NSEvent(cgEvent: cgEvent) else { return XCTFail("no NSEvent") }

        panel.sendEvent(event)

        XCTAssertTrue(spy.scrolled, "a scroll over the panel scrolls the hosted view")
        XCTAssertEqual(panel.frame, NSRect(x: 200, y: 200, width: 320, height: 200), "the panel never moves on a gesture")
    }
}

/// Opaque as the hosted web view is: the view a trackpad scroll would drag the window from.
private final class GestureSpy: NSView {
    private(set) var scrolled = false
    override var isOpaque: Bool { true }
    override func scrollWheel(with event: NSEvent) { scrolled = true }
}
