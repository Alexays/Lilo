import XCTest
import WebKit
@testable import Lilo

@MainActor
final class CaptureUsageObserverTests: XCTestCase {
    func testNoCaptureMapsToEmptyState() {
        let state = CaptureUsageObserver.compute(camera: .none, microphone: .none, displayCaptureActive: false)
        XCTAssertEqual(state, WKWebViewTab.WebPermissionUsageState.none)
    }

    func testActiveCameraMicAndScreenAreReported() {
        let state = CaptureUsageObserver.compute(camera: .active, microphone: .active, displayCaptureActive: true)
        XCTAssertTrue(state.usesCamera)
        XCTAssertTrue(state.usesMicrophone)
        XCTAssertTrue(state.usesScreen)
        XCTAssertFalse(state.isMicrophoneMuted)
    }

    func testMutedMicrophoneIsStillInUseButFlaggedMuted() {
        let state = CaptureUsageObserver.compute(camera: .none, microphone: .muted, displayCaptureActive: false)
        XCTAssertTrue(state.usesMicrophone)
        XCTAssertTrue(state.isMicrophoneMuted)
        XCTAssertFalse(state.usesCamera)
        XCTAssertFalse(state.usesScreen)
    }
}
