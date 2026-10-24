import AppKit
import XCTest
@testable import Lilo

@MainActor
final class ChromeHoverLifecycleCharacterizationTests: XCTestCase {
    private func move(_ controller: MainWindowController, to point: NSPoint) {
        let event = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: controller.window!.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )!
        controller.chromeInput.updatePointer(for: event)
    }

    func testHoverEntryThenExitTogglesInteractiveState() {
        let controller = MainWindowController()
        controller.bridgeRouter = BridgeRouter(chromeWebView: controller.chromeWebView)
        let chromeFrame = NSRect(x: 0, y: 0, width: 400, height: 200)
        controller.chromeWebView.frame = chromeFrame
        // The classifier converts via chromeWebView.convert(_, from: nil), which needs the overlay in the window hierarchy.
        controller.window!.contentView!.addSubview(controller.chromeWebView)
        // Full-height left strip = the sidebar band; x ∈ [0,60) is chrome at any y.
        controller.chromeInteractiveZones.registerZones([
            (id: "sidebar", rect: NSRect(x: 0, y: 0, width: 60, height: chromeFrame.height)),
        ])

        // The hover machine is the single source of truth for the applied interactive state.
        // Asserting through the machine's read-only accessor keeps this a real golden-master: each
        // move() drives the full path from updatePointer through the machine to the applier.

        // Enter the sidebar zone.
        move(controller, to: NSPoint(x: 30, y: 30))
        XCTAssertTrue(controller.chromeInput.coordinator.hover.isInteractive)

        // Move onto content (x beyond the 60pt sidebar).
        move(controller, to: NSPoint(x: 150, y: 30))
        XCTAssertFalse(controller.chromeInput.coordinator.hover.isInteractive)
    }
}
