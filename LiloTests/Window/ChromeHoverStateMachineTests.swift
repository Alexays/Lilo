import XCTest
@testable import Lilo

@MainActor
final class ChromeHoverStateMachineTests: XCTestCase {
    func testEnteringChromeArmsTrackingAndTransientState() {
        let machine = ChromeHoverStateMachine()
        let effects = machine.update(isInteractive: true, isMouseDown: false)
        XCTAssertEqual(effects, [
            .setContentTrackingSuspended(true),
            .setChromeTrackingEnabled(true),
        ])
    }

    func testStayingOnContentEmitsNothing() {
        let machine = ChromeHoverStateMachine()
        XCTAssertEqual(machine.update(isInteractive: false, isMouseDown: false), [])
    }

    func testStayingOnChromeForwardsMove() {
        let machine = ChromeHoverStateMachine()
        _ = machine.update(isInteractive: true, isMouseDown: false)
        // An interactive no-transition move must forward a real mouseMoved to chrome so WebKit
        // updates CSS :hover for intra-chrome hover targets (sidebar items, links, the resize
        // handle). This is the hover-SET half of the symmetric global-monitor lifecycle.
        XCTAssertEqual(machine.update(isInteractive: true, isMouseDown: false), [.forwardMoveToChrome])
    }

    // Leaving chrome must clear :hover, or the sidebar resize handle stays stuck in its hover state.
    func testLeavingChromeForContentClearsHoverAndSignalsContentInteraction() {
        let machine = ChromeHoverStateMachine()
        _ = machine.update(isInteractive: true, isMouseDown: false) // enter chrome
        let effects = machine.update(isInteractive: false, isMouseDown: false) // move to content
        XCTAssertEqual(effects, [
            .setContentTrackingSuspended(false),
            .clearChromeHover,
            .setChromeTrackingEnabled(false),
            .emitContentInteraction(isMouseDown: false),
        ])
    }

    func testMouseDownOnContentWithoutPriorChromeStillSignalsContentInteraction() {
        let machine = ChromeHoverStateMachine()
        let effects = machine.update(isInteractive: false, isMouseDown: true)
        XCTAssertEqual(effects, [
            .setContentTrackingSuspended(false),
            .emitContentInteraction(isMouseDown: true),
        ])
    }

    func testContentInteractionFiresOnlyOncePerChromeVisit() {
        let machine = ChromeHoverStateMachine()
        _ = machine.update(isInteractive: true, isMouseDown: false)  // enter
        _ = machine.update(isInteractive: false, isMouseDown: false) // leave: emits contentInteraction, clears transient
        let again = machine.update(isInteractive: false, isMouseDown: false) // still on content
        XCTAssertEqual(again, [])
    }
}
