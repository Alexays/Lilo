import XCTest
@testable import Lilo

/// `IdleBridgeHandler` has no dependencies. The real system idle clock can't be controlled, but an
/// unreachable threshold is never met (active). Chrome's minimum detection interval is 15s, so
/// sub-minimum thresholds are clamped and a 0s threshold cannot trivially report "idle".
@MainActor
final class IdleBridgeHandlerTests: XCTestCase {

    func test_handledActions() {
        XCTAssertEqual(IdleBridgeHandler().gapActions, ["idle.queryState", "idle.setDetectionInterval"])
    }

    func test_clampInterval_enforcesChromeMinimum() {
        XCTAssertEqual(IdleBridgeHandler.clampInterval(0), 15)
        XCTAssertEqual(IdleBridgeHandler.clampInterval(-5), 15)
        XCTAssertEqual(IdleBridgeHandler.clampInterval(14.9), 15)
        XCTAssertEqual(IdleBridgeHandler.clampInterval(30), 30)
        XCTAssertEqual(IdleBridgeHandler.clampInterval(.greatestFiniteMagnitude), .greatestFiniteMagnitude)
        XCTAssertEqual(IdleBridgeHandler.clampInterval(.nan), 60) // non-finite falls back to a safe default
    }

    // The effect of clamping a 0s threshold can't be asserted deterministically: it depends on the
    // real HID idle clock (a machine idle >= 15s still reports "idle"), hence the pure clamp test above.

    func test_queryState_reportsActive_whenThresholdIsUnreachable() async throws {
        let handler = IdleBridgeHandler()
        let msg = try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "idle.queryState",
            "payload": ["detectionIntervalInSeconds": Double.greatestFiniteMagnitude] as [String: Any]
        ]))
        let result = await handler.handle(msg)
        XCTAssertEqual(result as? String, "active")
    }

    func test_setDetectionInterval_changesTheDefaultThreshold() async throws {
        let handler = IdleBridgeHandler()
        let queryWithDefault = try XCTUnwrap(BridgeMessage(dictionary: ["action": "idle.queryState"]))

        // With an unreachable default threshold, an unparameterized query reports active.
        let setHigh = try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "idle.setDetectionInterval",
            "payload": ["intervalInSeconds": Double.greatestFiniteMagnitude] as [String: Any]
        ]))
        let setHighResult = await handler.handle(setHigh)
        XCTAssertNil(setHighResult)
        let activeResult = await handler.handle(queryWithDefault)
        XCTAssertEqual(activeResult as? String, "active")
    }

    // MARK: - Lazy polling lifecycle

    func test_init_doesNotStartPolling() {
        XCTAssertFalse(IdleBridgeHandler(registriesProvider: { [] }).isPolling)
    }

    func test_queryState_startsPolling() async throws {
        let handler = IdleBridgeHandler(registriesProvider: { [] })
        let msg = try XCTUnwrap(BridgeMessage(dictionary: ["action": "idle.queryState"]))
        _ = await handler.handle(msg)
        XCTAssertTrue(handler.isPolling)
    }

    func test_setDetectionInterval_startsPolling() async throws {
        let handler = IdleBridgeHandler(registriesProvider: { [] })
        let msg = try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "idle.setDetectionInterval",
            "payload": ["intervalInSeconds": 60.0] as [String: Any]
        ]))
        _ = await handler.handle(msg)
        XCTAssertTrue(handler.isPolling)
    }

    func test_nilRegistryProvider_neverPolls() async throws {
        let handler = IdleBridgeHandler()
        let msg = try XCTUnwrap(BridgeMessage(dictionary: ["action": "idle.queryState"]))
        _ = await handler.handle(msg)
        XCTAssertFalse(handler.isPolling)
    }

    func test_unknownAction_returnsNil() async throws {
        let handler = IdleBridgeHandler()
        let msg = try XCTUnwrap(BridgeMessage(dictionary: ["action": "idle.bogus"]))
        let result = await handler.handle(msg)
        XCTAssertNil(result)
    }
}
