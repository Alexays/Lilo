import AppKit
import XCTest
@testable import Lilo

/// Links from other apps follow Settings > Links from other apps: the first matching rule, else the default.
@MainActor
final class ExternalLinkRoutingTests: XCTestCase {
    private var browserContext: TemporaryBrowserContext!
    private var controller: MainWindowController!
    private var home: Space!
    private var work: Space!

    override func setUp() async throws {
        try await super.setUp()
        browserContext = try await TemporaryBrowserContext()
        let context = browserContext.context
        let profileId = try context.profileManager.createProfile(name: "P").id
        home = try context.spaceManager.createSpace(name: "Home", profileId: profileId)
        work = try context.spaceManager.createSpace(name: "Work", profileId: profileId)
        controller = makeTestWindow(context, showing: home.id, size: NSSize(width: 1000, height: 800))
        controller.didCompleteSessionRestore = true
    }

    override func tearDown() {
        controller.littleWindows.values.forEach { $0.window.close() }
        controller.window?.orderOut(nil)
        browserContext.tearDown()
        browserContext = nil
        super.tearDown()
    }

    private func setRules(_ rules: [[String: String]]) throws {
        let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: rules), encoding: .utf8))
        browserContext.context.settingsStore.set("externalLinkRules", value: json)
    }

    private func open(_ string: String) throws -> URL {
        let url = try XCTUnwrap(URL(string: string))
        controller.openExternalURL(url)
        return url
    }

    func testWithoutRulesALinkOpensInTheCurrentSpace() throws {
        let url = try open("https://example.com/")

        XCTAssertEqual(controller.tabManager.currentSpaceId, home.id)
        XCTAssertEqual(controller.tabManager.activeTab?.url, url)
        XCTAssertTrue(controller.littleWindows.isEmpty)
    }

    func testAHostRuleSendsTheHostAndItsSubdomainsToItsSpace() throws {
        try setRules([["match": "host", "pattern": "github.com", "destination": work.id.uuidString]])

        let url = try open("https://gist.github.com/someone")

        XCTAssertEqual(controller.tabManager.currentSpaceId, work.id)
        XCTAssertEqual(controller.tabManager.activeTab?.url, url)
    }

    func testAHostRuleLeavesOtherHostsToTheDefault() throws {
        try setRules([["match": "host", "pattern": "github.com", "destination": work.id.uuidString]])

        _ = try open("https://notgithub.com/")

        XCTAssertEqual(controller.tabManager.currentSpaceId, home.id)
    }

    func testTheFirstMatchingRuleWins() throws {
        try setRules([
            ["match": "contains", "pattern": "/pull/", "destination": "little"],
            ["match": "host", "pattern": "github.com", "destination": work.id.uuidString]
        ])

        let url = try open("https://github.com/org/repo/pull/1")

        XCTAssertEqual(controller.littleWindows.count, 1)
        XCTAssertEqual(controller.littleWindows.values.first?.engine.currentURL, url)
        XCTAssertEqual(controller.tabManager.currentSpaceId, home.id)
    }

    func testARuleToADeletedSpaceFallsBackToTheDefault() throws {
        try setRules([["match": "host", "pattern": "example.com", "destination": UUID().uuidString]])
        browserContext.context.settingsStore.set("externalLinkDefault", value: work.id.uuidString)

        _ = try open("https://example.com/")

        XCTAssertEqual(controller.tabManager.currentSpaceId, work.id)
        XCTAssertTrue(controller.littleWindows.isEmpty)
    }

    func testAnEmptyPatternNeverMatches() throws {
        try setRules([["match": "contains", "pattern": "  ", "destination": "little"]])

        _ = try open("https://example.com/")

        XCTAssertTrue(controller.littleWindows.isEmpty)
        XCTAssertEqual(controller.tabManager.currentSpaceId, home.id)
    }

    func testTheDefaultCanBeTheLittleWindow() throws {
        browserContext.context.settingsStore.set("externalLinkDefault", value: "little")

        _ = try open("https://example.com/")

        XCTAssertEqual(controller.littleWindows.count, 1)
        XCTAssertEqual(controller.littleWindows.values.first?.spaceId, home.id)
    }
}
