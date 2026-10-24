import XCTest
@testable import Lilo

/// `StateSyncBridgeHandler` only parses an optional `spaceId` UUID from the payload and calls the
/// emit closure (no network I/O, no stores), so the closure captures verify the call contract.
@MainActor
final class StateSyncBridgeHandlerTests: XCTestCase {

    func test_validSpaceId_invokesClosureWithUUID() async throws {
        var capturedSpaceId: UUID?
        let handler = StateSyncBridgeHandler { spaceId in capturedSpaceId = spaceId }
        let id = UUID()
        let msg = makeBridgeMessage(action: "requestBrowserStateSync", payload: ["spaceId": id.uuidString])
        _ = await handler.handle(message: msg)
        XCTAssertEqual(capturedSpaceId, id)
    }

    func test_missingSpaceId_invokesClosureWithNil() async throws {
        var called = false
        var capturedSpaceId: UUID? = UUID() // non-nil sentinel
        let handler = StateSyncBridgeHandler { spaceId in
            called = true
            capturedSpaceId = spaceId
        }
        let msg = makeBridgeMessage(action: "requestBrowserStateSync", payload: [:])
        _ = await handler.handle(message: msg)
        XCTAssertTrue(called)
        XCTAssertNil(capturedSpaceId)
    }

    func test_garbageSpaceId_invokesClosureWithNil() async throws {
        var capturedSpaceId: UUID? = UUID() // non-nil sentinel
        let handler = StateSyncBridgeHandler { spaceId in capturedSpaceId = spaceId }
        let msg = makeBridgeMessage(action: "requestBrowserStateSync", payload: ["spaceId": "not-a-uuid"])
        _ = await handler.handle(message: msg)
        XCTAssertNil(capturedSpaceId)
    }

    // MARK: - Helpers

    private func makeBridgeMessage(action: String, payload: [String: Any]) -> BridgeMessage {
        BridgeMessage(dictionary: ["action": action, "payload": payload])!
    }

    // MARK: - resolvedSpaceId

    func test_resolvedSpaceId_nilRequested_returnsActiveSpace() {
        let active = UUID()
        let result = StateSyncBridgeHandler.resolvedSpaceId(
            requested: nil,
            isCached: { _ in true },
            activeSpaceId: active
        )
        XCTAssertEqual(result, active)
    }

    func test_resolvedSpaceId_requestedAndCached_returnsThatSpace() {
        let requested = UUID()
        let active = UUID()
        let result = StateSyncBridgeHandler.resolvedSpaceId(
            requested: requested,
            isCached: { id in id == requested },
            activeSpaceId: active
        )
        XCTAssertEqual(result, requested)
    }

    func test_resolvedSpaceId_requestedButNotCached_fallsBackToActiveSpace() {
        let requested = UUID()
        let active = UUID()
        let result = StateSyncBridgeHandler.resolvedSpaceId(
            requested: requested,
            isCached: { id in id == active }, // requested is not cached; active space is
            activeSpaceId: active
        )
        XCTAssertEqual(result, active)
    }

    func test_resolvedSpaceId_requestedNotCachedNoActiveSpace_returnsNil() {
        let result = StateSyncBridgeHandler.resolvedSpaceId(
            requested: UUID(),
            isCached: { _ in false },
            activeSpaceId: nil
        )
        XCTAssertNil(result)
    }

    func test_resolvedSpaceId_nilRequestedNoActiveSpace_returnsNil() {
        let result = StateSyncBridgeHandler.resolvedSpaceId(
            requested: nil,
            isCached: { _ in true },
            activeSpaceId: nil
        )
        XCTAssertNil(result)
    }

    func test_resolvedSpaceId_requestedNotCachedActiveSpaceNotCached_returnsNil() {
        // Both requested and active space exist but neither is cached (e.g. startup window whose
        // store hasn't loaded yet): must return nil so the caller doesn't silently no-op.
        let result = StateSyncBridgeHandler.resolvedSpaceId(
            requested: UUID(),
            isCached: { _ in false },
            activeSpaceId: UUID()
        )
        XCTAssertNil(result)
    }
}
