import XCTest
@testable import Lilo

@MainActor
final class ChromeCaptureMachineTests: XCTestCase {
    // MARK: Mouse-button drag latch (lifetime a)

    func testMouseDownLatchesTargetAndStartsCapturing() {
        let machine = ChromeCaptureMachine()
        XCTAssertFalse(machine.isCapturing)
        let result = machine.routeMouse(phase: .down, classification: .chrome)
        XCTAssertEqual(result.target, .chrome)
        XCTAssertEqual(result.effects, [])
        XCTAssertTrue(machine.isCapturing)
    }

    // A mouse drag that starts on chrome and crosses onto content stays routed to chrome
    // until mouse-up.
    func testMouseDragLatchHoldsOriginTargetAcrossBoundaryUntilUp() {
        let machine = ChromeCaptureMachine()
        XCTAssertEqual(machine.routeMouse(phase: .down, classification: .chrome).target, .chrome)
        // Pointer now classifies as content, but the latch holds chrome.
        XCTAssertEqual(machine.routeMouse(phase: .dragged, classification: .content).target, .chrome)
        XCTAssertEqual(machine.routeMouse(phase: .dragged, classification: .content).target, .chrome)
        XCTAssertTrue(machine.isCapturing)
        // Mouse-up still routes to the latched target, then releases the latch.
        XCTAssertEqual(machine.routeMouse(phase: .up, classification: .content).target, .chrome)
        XCTAssertFalse(machine.isCapturing)
        // A fresh down re-classifies (no stale latch).
        XCTAssertEqual(machine.routeMouse(phase: .down, classification: .content).target, .content)
    }

    func testMouseDragWithoutPriorDownClassifiesPositionally() {
        // Defensive: a stray dragged/up with no active latch falls back to live classification.
        let machine = ChromeCaptureMachine()
        XCTAssertEqual(machine.routeMouse(phase: .dragged, classification: .content).target, .content)
        XCTAssertFalse(machine.isCapturing)
        XCTAssertEqual(machine.routeMouse(phase: .up, classification: .chrome).target, .chrome)
    }

    // Capture end emits .resamplePointer ONLY when a real grab was held, so the input coordinator
    // can resync hover/cursor to the release position.
    func testCaptureEndEmitsResamplePointerWhenHeldAndNotOtherwise() {
        let machine = ChromeCaptureMachine()
        _ = machine.routeMouse(phase: .down, classification: .chrome)
        XCTAssertEqual(machine.routeMouse(phase: .up, classification: .content).effects, [.resamplePointer])
        // A stray up with no prior latch emits nothing.
        XCTAssertEqual(machine.routeMouse(phase: .up, classification: .content).effects, [])
        // Gesture end mirrors this.
        _ = machine.routeGesture(phase: .began, classification: .content)
        XCTAssertEqual(machine.routeGesture(phase: .ended, classification: .chrome).effects, [.resamplePointer])
        XCTAssertEqual(machine.routeGesture(phase: .ended, classification: .chrome).effects, [])
    }

    // MARK: Scroll / gesture fling latch (lifetime c)

    func testGestureBeganLatchesAndPhaseEndedReleases() {
        let machine = ChromeCaptureMachine()
        XCTAssertEqual(machine.routeGesture(phase: .began, classification: .content).target, .content)
        XCTAssertTrue(machine.isCapturing)
        XCTAssertEqual(machine.routeGesture(phase: .changed, classification: .content).target, .content)
        XCTAssertEqual(machine.routeGesture(phase: .ended, classification: .content).target, .content)
        XCTAssertFalse(machine.isCapturing)
    }

    // A scroll fling that BEGAN on content and whose inertial momentum drifts the pointer
    // over the chrome sidebar must keep routing to content until phase .ended: it must NOT
    // bleed onto chrome mid-fling.
    func testScrollFlingThatBeganOnContentStaysOnContentWhenPointerDriftsOverChrome() {
        let machine = ChromeCaptureMachine()
        XCTAssertEqual(machine.routeGesture(phase: .began, classification: .content).target, .content)
        // Inertial momentum: pointer now over the chrome sidebar, classification flips.
        XCTAssertEqual(machine.routeGesture(phase: .changed, classification: .chrome).target, .content)
        XCTAssertEqual(machine.routeGesture(phase: .changed, classification: .chrome).target, .content)
        XCTAssertTrue(machine.isCapturing)
        XCTAssertEqual(machine.routeGesture(phase: .ended, classification: .chrome).target, .content)
        XCTAssertFalse(machine.isCapturing)
        // After the fling ends, a fresh scroll re-classifies to where the pointer is now.
        XCTAssertEqual(machine.routeGesture(phase: .began, classification: .chrome).target, .chrome)
    }

    func testGesturePhaseCancelledReleasesLatch() {
        let machine = ChromeCaptureMachine()
        XCTAssertEqual(machine.routeGesture(phase: .began, classification: .chrome).target, .chrome)
        XCTAssertEqual(machine.routeGesture(phase: .cancelled, classification: .content).target, .chrome)
        XCTAssertFalse(machine.isCapturing)
    }

    func testPhaselessScrollClassifiesPositionallyWithoutLatching() {
        // Legacy line-scroll / Magic Mouse may report .none phase: route positionally, no latch.
        let machine = ChromeCaptureMachine()
        XCTAssertEqual(machine.routeGesture(phase: .none, classification: .content).target, .content)
        XCTAssertFalse(machine.isCapturing)
        XCTAssertEqual(machine.routeGesture(phase: .none, classification: .chrome).target, .chrome)
        XCTAssertFalse(machine.isCapturing)
    }

    // MARK: Drag-and-drop session (lifetime b)

    func testDragEnterContentEmitsEnterContentAndCaptures() {
        let machine = ChromeCaptureMachine()
        let result = machine.routeDrag(phase: .entered, classification: .content)
        XCTAssertEqual(result.target, .content)
        XCTAssertEqual(result.effects, [.enterContent])
        XCTAssertTrue(machine.isCapturing)
    }

    func testDragUpdateWithinSameContentTargetReentersContent() {
        let machine = ChromeCaptureMachine()
        _ = machine.routeDrag(phase: .entered, classification: .content)
        let result = machine.routeDrag(phase: .updated, classification: .content)
        XCTAssertEqual(result.target, .content)
        XCTAssertEqual(result.effects, [.updateContent])
    }

    func testDragUpdateCrossingChromeToContentRelaysChromeExitThenContentEnter() {
        let machine = ChromeCaptureMachine()
        _ = machine.routeDrag(phase: .entered, classification: .chrome)
        let result = machine.routeDrag(phase: .updated, classification: .content)
        XCTAssertEqual(result.target, .content)
        XCTAssertEqual(result.effects, [.exitChrome, .enterContent])
    }

    func testDragUpdateCrossingContentToChromeRelaysContentExitThenChromeEnter() {
        let machine = ChromeCaptureMachine()
        _ = machine.routeDrag(phase: .entered, classification: .content)
        let result = machine.routeDrag(phase: .updated, classification: .chrome)
        XCTAssertEqual(result.target, .chrome)
        XCTAssertEqual(result.effects, [.exitContent, .enterChrome])
    }

    func testDragUpdateStayingOnChromeReentersChrome() {
        let machine = ChromeCaptureMachine()
        _ = machine.routeDrag(phase: .entered, classification: .chrome)
        let result = machine.routeDrag(phase: .updated, classification: .chrome)
        XCTAssertEqual(result.target, .chrome)
        XCTAssertEqual(result.effects, [.updateChrome])
    }

    func testDragExitedFromContentEmitsExitContentAndReleases() {
        let machine = ChromeCaptureMachine()
        _ = machine.routeDrag(phase: .entered, classification: .content)
        let result = machine.routeDrag(phase: .exited, classification: .content)
        XCTAssertEqual(result.effects, [.exitContent])
        XCTAssertFalse(machine.isCapturing)
    }

    func testDragConcludeOnContentEmitsConcludeContentAndReleases() {
        let machine = ChromeCaptureMachine()
        _ = machine.routeDrag(phase: .entered, classification: .content)
        let result = machine.routeDrag(phase: .concluded, classification: .content)
        XCTAssertEqual(result.effects, [.concludeContent])
        XCTAssertFalse(machine.isCapturing)
    }

    func testDragConcludeOnChromeEmitsConcludeChromeAndReleases() {
        let machine = ChromeCaptureMachine()
        _ = machine.routeDrag(phase: .entered, classification: .chrome)
        let result = machine.routeDrag(phase: .concluded, classification: .chrome)
        XCTAssertEqual(result.effects, [.concludeChrome])
        XCTAssertFalse(machine.isCapturing)
    }

    // MARK: reset

    func testResetClearsAllLatches() {
        let machine = ChromeCaptureMachine()
        _ = machine.routeMouse(phase: .down, classification: .chrome)
        XCTAssertTrue(machine.isCapturing)
        machine.reset()
        XCTAssertFalse(machine.isCapturing)
        // After reset a dragged event re-classifies (no stale mouse latch).
        XCTAssertEqual(machine.routeMouse(phase: .dragged, classification: .content).target, .content)
    }
}
