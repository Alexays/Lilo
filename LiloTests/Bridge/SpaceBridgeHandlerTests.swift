import AppKit
import XCTest
@testable import Lilo

@MainActor
final class SpaceBridgeHandlerTests: XCTestCase {
    func testUpdatingAnUnknownSpaceCreatesNoProfile() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let context = browserContext.context
        let window = MainWindowController(context: context)
        window.bridgeRouter = BridgeRouter(chromeWebView: window.chromeWebView)
        let handler = SpaceBridgeHandler(spaceManager: context.spaceManager, windowController: window)
        let profileCount = context.profileManager.profiles.count

        _ = await handler.handle(message: try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "updateSpace", "payload": ["id": UUID().uuidString, "newProfileName": "Work"]
        ])))

        XCTAssertEqual(context.profileManager.profiles.count, profileCount)
    }
}
