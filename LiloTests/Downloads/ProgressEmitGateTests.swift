import XCTest
@testable import Lilo

final class ProgressEmitGateTests: XCTestCase {

    func testImmediateSecondCallRejected() {
        let gate = ProgressEmitGate()
        XCTAssertTrue(gate.pass(interval: 60)) // long interval so the second call can't sneak past it
        XCTAssertFalse(gate.pass(interval: 60))
    }

    func testCallAfterIntervalElapsesPasses() {
        // ProgressEmitGate has no injectable clock: interval 0 is satisfied by any elapsed time
        // (including none), which makes "after the interval" deterministic without a sleep.
        let gate = ProgressEmitGate()
        XCTAssertTrue(gate.pass(interval: 0))
        XCTAssertTrue(gate.pass(interval: 0))
        XCTAssertTrue(gate.pass(interval: 0))
    }

    func testGatesAreIndependentPerInstance() {
        let gate1 = ProgressEmitGate()
        let gate2 = ProgressEmitGate()
        XCTAssertTrue(gate1.pass(interval: 60))
        XCTAssertTrue(gate2.pass(interval: 60)) // separate instance, unaffected by gate1's state
    }
}
