import AppKit
import XCTest
@testable import Lilo

@MainActor
final class ChromeInputCoordinatorTests: XCTestCase {
    // MARK: Test fixtures: pure, no AppKit/WebKit. The classification is injected via the
    // sample (the edge classifies; the core only consumes the value), so every sequence is
    // deterministic with zero views.

    private func sample(
        _ target: ChromeEventRouter.Target,
        isMouseDown: Bool = false,
        phase: ChromeCaptureMachine.GesturePhase = .none
    ) -> PointerSample {
        PointerSample(target: target, isMouseDown: isMouseDown, scrollPhase: phase)
    }

    private func containsHover(_ effects: [InteractionEffect]) -> Bool {
        effects.contains { if case .hover = $0 { return true } else { return false } }
    }

    // MARK: Construction + shared-empty sentinel.

    // MARK: Rule 3: hover only outside capture; no-transition fast path.

    func testPlainMoveWithNoTransitionReturnsSharedEmpty() {
        let coordinator = ChromeInputCoordinator()
        // Prime: first content move establishes the baseline (may emit; we ignore it).
        _ = coordinator.updatePointer(sample(.content))
        // Second identical content move: no chrome/content transition, not capturing.
        let effects = coordinator.updatePointer(sample(.content))
        XCTAssertEqual(effects, InteractionEffect.none) // zero-allocation identity
    }

    func testEnteringChromeEmitsWrappedHoverEffects() {
        let coordinator = ChromeInputCoordinator()
        _ = coordinator.updatePointer(sample(.content))     // baseline
        let effects = coordinator.updatePointer(sample(.chrome))
        XCTAssertEqual(effects, [
            .hover(.setContentTrackingSuspended(true)),
            .hover(.setChromeTrackingEnabled(true)),
        ])
    }

    func testLeavingChromeForContentEmitsClearHoverWrapped() {
        let coordinator = ChromeInputCoordinator()
        _ = coordinator.updatePointer(sample(.chrome))      // enter chrome
        let effects = coordinator.updatePointer(sample(.content))
        XCTAssertEqual(effects, [
            .hover(.setContentTrackingSuspended(false)),
            .hover(.clearChromeHover),
            .hover(.setChromeTrackingEnabled(false)),
            .hover(.emitContentInteraction(isMouseDown: false)),
        ])
    }

    // Rule 1 + perf: while capturing, the hover machine is NEVER invoked.
    func testHoverIsSuppressedWhileCapturing() {
        let coordinator = ChromeInputCoordinator()
        // Start a mouse-button capture on chrome.
        _ = coordinator.routePositional(sample(.chrome, isMouseDown: true), family: .leftMouseDown)
        XCTAssertTrue(coordinator.isCapturing)
        // A move that drifts onto content while captured.
        let effects = coordinator.updatePointer(sample(.content))
        // No hover transition fires mid-capture.
        XCTAssertFalse(containsHover(effects))
        XCTAssertEqual(effects, InteractionEffect.none)
    }

    // MARK: Rule 1: capture dominates positional (scroll-fling latch).

    func testScrollFlingLatchesToStartSurfaceAcrossBoundary() {
        let coordinator = ChromeInputCoordinator()
        // Fling begins on content.
        let (t0, _) = coordinator.routePositional(
            sample(.content, phase: .began), family: .scrollWheel)
        XCTAssertEqual(t0, .content)
        // Momentum drifts the pointer over the chrome sidebar: classification now says chrome,
        // but the EFFECTIVE target stays content (latched), and NO hover transition fires.
        let driftSample = sample(.chrome, phase: .changed)
        let (t1, driftEffects) = coordinator.routePositional(driftSample, family: .scrollWheel)
        XCTAssertEqual(t1, .content) // Rule 1: latched to start surface
        XCTAssertFalse(containsHover(driftEffects))
        // A hover feed during the fling is suppressed too (Rule 3).
        XCTAssertEqual(coordinator.updatePointer(sample(.chrome)), InteractionEffect.none)
        // Fling ends: capture releases.
        let (_, endEffects) = coordinator.routePositional(
            sample(.content, phase: .ended), family: .scrollWheel)
        XCTAssertFalse(coordinator.isCapturing)
        // Rule 3: capture end emits a resample marker so the edge resyncs hover/cursor.
        XCTAssertTrue(endEffects.contains(.capture(.resamplePointer)))
    }

    // MARK: Rule 2: cursor follows capture, else position.

    func testCursorFollowsCaptureTargetDuringDrag() {
        let coordinator = ChromeInputCoordinator()
        // Mouse-down on chrome (sidebar resize handle) latches capture to chrome.
        _ = coordinator.routePositional(sample(.chrome, isMouseDown: true), family: .leftMouseDown)
        // A cursorUpdate that drifts onto content must resolve to the CAPTURED (chrome) target.
        let (resolved, _) = coordinator.routePositional(sample(.content), family: .cursorUpdate)
        XCTAssertEqual(resolved, .chrome) // col-resize stays through the whole drag
    }

    func testCursorFollowsPositionWhenNotCapturing() {
        let coordinator = ChromeInputCoordinator()
        let (resolved, _) = coordinator.routePositional(sample(.content), family: .cursorUpdate)
        XCTAssertEqual(resolved, .content)
    }

    // MARK: Content click: routePositional drives ONLY capture; the DOM reconcile is
    // owned by the hover feed (updatePointer), not this path. (The content-press hover signal
    // is unit-tested in ChromeHoverStateMachineTests.)

    func testContentClickThroughRoutePositionalDrivesOnlyCapture() {
        let coordinator = ChromeInputCoordinator()
        // Arm transient chrome state, then a content mouse-down through the positional path.
        _ = coordinator.updatePointer(sample(.chrome))      // visit chrome (arms transient)
        let (_, effects) = coordinator.routePositional(
            sample(.content, isMouseDown: true), family: .leftMouseDown)
        // routePositional does not drive hover, that is the monitor hover feeder's.
        XCTAssertFalse(containsHover(effects), "routePositional must not drive the hover machine")
    }

    // The post-capture resample must drive the hover machine, not be swallowed by a .content == .content fast path.
    func testPostCaptureResampleClearsStuckChromeHover() {
        let coordinator = ChromeInputCoordinator()
        // 1. Pointer hovers content.
        _ = coordinator.updatePointer(sample(.content))
        // 2. Mouse-down on chrome. Live, the global monitor (sole hover feeder) arms hover via updatePointer and the shield
        //    latches capture via routePositional, which never drives hover.
        _ = coordinator.updatePointer(sample(.chrome, isMouseDown: true)) // monitor: arms chrome hover
        _ = coordinator.routePositional(sample(.chrome, isMouseDown: true), family: .leftMouseDown) // shield: latch
        XCTAssertTrue(coordinator.isCapturing)
        // 3. Drag to content, then mouse-up: capture releases and emits .resamplePointer.
        _ = coordinator.routePositional(sample(.content), family: .leftMouseDragged)
        let upEffects = coordinator.routePositional(sample(.content), family: .leftMouseUp).1
        XCTAssertFalse(coordinator.isCapturing)
        XCTAssertTrue(upEffects.contains(.capture(.resamplePointer)))
        // 4. Edge re-samples the live pointer over content. The hover machine MUST be driven and
        //    emit clearChromeHover, or the chrome :hover stays stuck.
        let resampleEffects = coordinator.updatePointer(sample(.content))
        XCTAssertTrue(
            resampleEffects.contains(.hover(.clearChromeHover)),
            "post-capture resample over content must clear the stale chrome :hover"
        )
    }

    // reset() must clear hover-target tracking, or a post-reset updatePointer(.chrome) is swallowed as a no-transition.
    func testResetClearsHoverTracking() {
        let coordinator = ChromeInputCoordinator()
        _ = coordinator.updatePointer(sample(.chrome)) // tracked state now interactive
        coordinator.reset()
        // A fresh chrome entry after reset must NOT be swallowed by stale "was interactive".
        let effects = coordinator.updatePointer(sample(.chrome))
        XCTAssertEqual(effects, [
            .hover(.setContentTrackingSuspended(true)),
            .hover(.setChromeTrackingEnabled(true)),
        ])
    }

    // MARK: Perf-contract structural guards.

    // ONE HOVER FEEDER guard: feeding a plain move through updatePointer must not latch
    // capture, proving the hover feeder and the positional feeder are disjoint.
    func testUpdatePointerNeverLatchesCapture() {
        let coordinator = ChromeInputCoordinator()
        _ = coordinator.updatePointer(sample(.chrome))
        _ = coordinator.updatePointer(sample(.content))
        XCTAssertFalse(coordinator.isCapturing)
    }
}
