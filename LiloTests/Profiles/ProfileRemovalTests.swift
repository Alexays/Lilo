import AppKit
import XCTest
@testable import Lilo

/// Removing a profile from the chrome: its spaces move to the profile the user picked first.
@MainActor
final class ProfileRemovalTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
    }

    override func tearDown() {
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    private func remove(_ id: UUID, moveTo: UUID) async throws {
        let context = browserContext.context
        let window = MainWindowController(context: context)
        window.bridgeRouter = BridgeRouter(chromeWebView: window.chromeWebView)
        window.contentContainerView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        context.windows.add(window)
        let handler = ProfileBridgeHandler(profileManager: context.profileManager, windowController: window)
        let message = try XCTUnwrap(BridgeMessage(dictionary: [
            "action": "deleteProfile", "payload": ["id": id.uuidString, "moveTo": moveTo.uuidString]
        ]))
        _ = await handler.handle(message: message)
    }

    func testRemovingAProfileMovesItsSpacesToTheChosenOne() async throws {
        let context = browserContext.context
        let work = try context.profileManager.createProfile(name: "Work").id
        let perso = try context.profileManager.createProfile(name: "Perso").id
        let docs = try context.spaceManager.createSpace(name: "Docs", profileId: work)
        let mail = try context.spaceManager.createSpace(name: "Mail", profileId: work)

        try await remove(work, moveTo: perso)

        XCTAssertFalse(context.profileManager.profiles.contains { $0.id == work }, "profile kept")
        XCTAssertEqual(context.spaceManager.space(with: docs.id)?.profileId, perso)
        XCTAssertEqual(context.spaceManager.space(with: mail.id)?.profileId, perso)
        let stored = try await context.dbManager.globalPool.read { try Space.fetchAll($0) }
        XCTAssertFalse(stored.contains { $0.profileId == work }, "stored spaces kept")
    }

    func testRemovingTheDefaultProfileMakesTheChosenOneDefault() async throws {
        let context = browserContext.context
        let defaultId = try XCTUnwrap(context.profileManager.defaultProfile?.id)
        let work = try context.profileManager.createProfile(name: "Work").id

        try await remove(defaultId, moveTo: work)

        XCTAssertEqual(context.profileManager.defaultProfile?.id, work)
        let stored = try await context.dbManager.globalPool.read { try Profile.fetchAll($0) }
        XCTAssertEqual(stored.filter(\.isDefault).map(\.id), [work])
    }
}
