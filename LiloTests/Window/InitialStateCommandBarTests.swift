import AppKit
import XCTest
@testable import Lilo

/// A launch on a blank tab opens the command bar, unless the onboarding shows: it opens the bar when it ends.
@MainActor
final class InitialStateCommandBarTests: XCTestCase {
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

    private func launchOnABlankTab(onboarding: Bool) throws -> BridgeEventRecorder {
        let context = browserContext.context
        context.settingsStore.resolveOnboarding(freshInstall: onboarding)
        let profileId = try context.profileManager.createProfile(name: "P").id
        let space = try context.spaceManager.createSpace(name: "S", profileId: profileId, isPrivate: false)
        let window = makeTestWindow(context, showing: space.id)
        XCTAssertNotNil(window.createTabStateFirst(url: nil))
        let events = BridgeEventRecorder(window.bridgeRouter)

        window.finishSessionRestore()
        window.handleChromeReady()

        XCTAssertEqual(events.data("initialState").count, 1)
        return events
    }

    func testABlankTabOpensTheCommandBar() throws {
        let events = try launchOnABlankTab(onboarding: false)

        XCTAssertEqual(events.data("openCommandBar").count, 1)
    }

    func testTheOnboardingHoldsTheCommandBar() throws {
        let events = try launchOnABlankTab(onboarding: true)

        // Sent in the same turn as the initial state, the command bar would have shipped with it.
        XCTAssertFalse(events.events.contains { $0.name == "openCommandBar" })
    }
}
