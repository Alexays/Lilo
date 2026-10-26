import XCTest
@testable import Lilo

/// A window points at the profile of the space it displays; profiles are no controller-wide state.
@MainActor
final class ProfileSwitchTests: XCTestCase {
    private var tempDir: URL!
    private var controller: MainWindowController!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("profile-switch-\(UUID().uuidString)")
        let context = BrowserContext(appSupportDirectory: tempDir.path, makeProfileId: { TestProfileIds.next() })
        try await context.bootstrap()
        controller = MainWindowController(context: context)
    }

    override func tearDown() {
        controller = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    func testActivatingAProfilePinsItAndReusesItsContext() throws {
        let a = UUID(), b = UUID()
        let first = try controller.activateProfileContext(for: Space(profileId: a))
        _ = try controller.activateProfileContext(for: Space(profileId: b))
        XCTAssertTrue(try controller.activateProfileContext(for: Space(profileId: a)) === first)
        XCTAssertEqual(controller.context.profileContexts.pinnedProfileIds, [a])
        XCTAssertEqual(controller.profileContext?.profileId, a)
    }

    func testSwitchToSpaceWithUnreadableProfileKeepsCurrentSpace() throws {
        let readable = UUID()
        _ = try controller.activateProfileContext(for: Space(profileId: readable))
        let unreadable = Space(profileId: UUID())
        let profileDir = tempDir.appendingPathComponent("Profiles/\(unreadable.profileId.uuidString)")
        try FileManager.default.createDirectory(at: profileDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A plain file where the profile's directory must go makes its pool fail to open.
        FileManager.default.createFile(atPath: profileDir.path, contents: Data())

        XCTAssertThrowsError(try controller.activateProfileContext(for: unreadable))
        XCTAssertEqual(controller.profileContext?.profileId, readable)
        XCTAssertEqual(controller.context.profileContexts.pinnedProfileIds, [readable])
    }
}
