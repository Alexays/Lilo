import WebKit
import XCTest
@testable import Lilo

@MainActor
final class KeepAwakeBridgeHandlerTests: XCTestCase {
    func testAKeepAwakeChangeLeavesTheUnchangedTerminalListUnsent() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let context = browserContext.context
        let space = try context.spaceManager.createSpace(name: "S", profileId: try context.profileManager.createProfile(name: "P").id)
        let window = makeTestWindow(context, showing: space.id)
        let events = BridgeEventRecorder(window.bridgeRouter)
        context.terminalActivityChanged()
        let sent = await pollUntil(timeout: 2) { events.events.contains { $0.name == "terminalActivity" } }
        XCTAssertTrue(sent)

        context.powerKeeper.republish()
        await pollUntil(timeout: 0.3) { false }

        XCTAssertEqual(events.events.count { $0.name == "terminalActivity" }, 1)
    }

    func testAskingForTheStateResendsTheTerminals() async throws {
        var resent = 0
        let handler = KeepAwakeBridgeHandler(powerKeeper: PowerKeeper(), bridgeRouter: BridgeRouter(chromeWebView: WKWebView())) { resent += 1 }

        _ = await handler.handle(message: try XCTUnwrap(BridgeMessage(dictionary: ["action": "getKeepAwakeState", "payload": [:]])))

        XCTAssertEqual(resent, 1)
    }
}
