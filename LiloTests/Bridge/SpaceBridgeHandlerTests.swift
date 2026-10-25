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

    func testTheColorModeIsSavedAndAnUnknownOneIgnored() async throws {
        let browserContext = try await TemporaryBrowserContext()
        defer { browserContext.tearDown() }
        let context = browserContext.context
        let window = MainWindowController(context: context)
        window.bridgeRouter = BridgeRouter(chromeWebView: window.chromeWebView)
        let handler = SpaceBridgeHandler(spaceManager: context.spaceManager, windowController: window)
        let profileId = try XCTUnwrap(context.profileManager.profiles.first?.id)
        let space = try context.spaceManager.createSpace(profileId: profileId)
        XCTAssertEqual(space.colorMode, Space.fixedColorMode)

        for (mode, expected) in [("time", "time"), ("sepia", "time"), ("wallpaper", "wallpaper")] {
            _ = await handler.handle(message: try XCTUnwrap(BridgeMessage(dictionary: [
                "action": "updateSpace", "payload": ["id": space.id.uuidString, "colorMode": mode]
            ])))
            XCTAssertEqual(context.spaceManager.space(with: space.id)?.colorMode, expected, mode)
        }
        let pool = context.dbManager.globalPool
        let saved = await pollUntil(timeout: 5) {
            (try? pool.read { db in try Space.fetchOne(db, key: space.id.uuidString) })?.colorMode == "wallpaper"
        }
        XCTAssertTrue(saved)
        XCTAssertEqual(space.bridgeData["colorMode"] as? String, Space.fixedColorMode)
    }
}
