import AppKit
import XCTest
@testable import Lilo

/// Settings > Extensions acting on a profile its window does not show, through the window's real handler.
@MainActor
final class ExtensionUIBridgeHandlerTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var handler: ExtensionUIBridgeHandler!
    private var shown: [(profileId: UUID, rows: [[String: Any]], live: Bool)] = []
    private var otherProfileId: UUID!
    private var extensionId: String!

    /// A window showing one profile, and another profile with one installed extension and no context built.
    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        let context = browserContext.context
        let windowProfileId = try context.profileManager.createProfile(name: "Window").id
        otherProfileId = try context.profileManager.createProfile(name: "Other").id
        let installing = try context.profileContexts.context(for: otherProfileId).extensions
        let source = try createMinimalExtension(named: "other_profile_extension", displayName: "Other Vault", in: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try await installing.load(from: source)
        extensionId = try XCTUnwrap(installing.loadedExtensions.first?.id)
        context.profileContexts.removeContext(for: otherProfileId)

        let space = try context.spaceManager.createSpace(name: "S", profileId: windowProfileId)
        let window = makeTestWindow(context, showing: space.id)
        window.setupBridgeLate()
        handler = try XCTUnwrap(window.bridgeRouter.handlers["getProfileExtensions"] as? ExtensionUIBridgeHandler)
        handler.onProfileExtensions = { [weak self] profileId, rows, live in self?.shown.append((profileId, rows, live)) }
    }

    override func tearDown() {
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    private func send(_ action: String, _ payload: [String: Any]) async throws {
        _ = await handler.handle(message: try XCTUnwrap(BridgeMessage(dictionary: ["action": action, "payload": payload])))
    }

    func testListingAnotherProfileReadsStorageWithoutLoadingItsExtensions() async throws {
        try await send("getProfileExtensions", ["profileId": otherProfileId.uuidString, "live": false])

        let listed = try XCTUnwrap(shown.last)
        XCTAssertEqual(listed.profileId, otherProfileId)
        XCTAssertFalse(listed.live)
        XCTAssertEqual(listed.rows.map { $0["name"] as? String }, ["Other Vault"])
        XCTAssertEqual(listed.rows.first?["isEnabled"] as? Bool, true)
        let registry = try XCTUnwrap(browserContext.context.profileContexts.existingContext(for: otherProfileId)?.extensions)
        XCTAssertFalse(registry.isRestored)
        XCTAssertFalse(registry.hasLoadedExtensions, "no extension of a profile only listed is loaded, so none of its workers runs")
    }

    func testAnActionNamingAnotherProfileReachesItsRegistry() async throws {
        let windowRegistry = try XCTUnwrap(browserContext.context.windows.windows.first?.profileContext?.extensions)

        try await send("disableExtension", ["id": extensionId!, "profileId": otherProfileId.uuidString])

        let registry = try XCTUnwrap(browserContext.context.profileContexts.existingContext(for: otherProfileId)?.extensions)
        XCTAssertTrue(registry.isRestored)
        XCTAssertEqual(registry.disabledStoredExtensions.map(\.id), [extensionId])
        let stored = try await registry.extensionStorage.load(id: extensionId)
        XCTAssertEqual(stored?.isEnabled, false)
        XCTAssertFalse(windowRegistry.hasLoadedExtensions)
        let refreshed = try XCTUnwrap(shown.last)
        XCTAssertTrue(refreshed.live, "the settings get the profile's rows again after the action")
        XCTAssertEqual(refreshed.rows.first { $0["id"] as? String == extensionId }?["isEnabled"] as? Bool, false)
    }
}
